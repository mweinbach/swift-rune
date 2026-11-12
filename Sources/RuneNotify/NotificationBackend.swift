import Foundation

/// Cross-platform state lock backed by `NSLock`.
final class NotifyLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(initialState: State) {
        self.state = initialState
    }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

/// Abstraction over a platform notification delivery backend.
public protocol NotificationBackend: Sendable {
    var isAvailable: Bool { get }
    var isAppFocused: Bool { get }
    func post(_ notification: Notification) -> Bool
    func remove(ids: [String])
    func setClickHandler(_ handler: (@Sendable (NotificationClick) -> Void)?)
    func bringToFront()
    func register(_ identity: NotificationIdentity) -> Result<Void, NotificationError>
    func adopt(_ identity: NotificationIdentity) -> Result<Void, NotificationError>
    func clickFromURL(_ url: String) -> NotificationClick?
    func serveActivations(_ clsid: String) -> Result<Void, NotificationError>
    func waitActivation(_ clsid: String, timeout: TimeInterval) -> NotificationClick?
}

public extension NotificationBackend {
    func register(_ identity: NotificationIdentity) -> Result<Void, NotificationError> {
        .success(())
    }

    func adopt(_ identity: NotificationIdentity) -> Result<Void, NotificationError> {
        .success(())
    }

    func clickFromURL(_ url: String) -> NotificationClick? {
        nil
    }

    func serveActivations(_ clsid: String) -> Result<Void, NotificationError> {
        .success(())
    }

    func waitActivation(_ clsid: String, timeout: TimeInterval) -> NotificationClick? {
        nil
    }
}

/// Deterministic headless notification backend for unit tests and non-bundled environments.
public final class MockNotificationBackend: NotificationBackend, @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var available: Bool = true
        var appFocused: Bool = false
        var registeredIdentity: NotificationIdentity?
        var activeNotifications: [Notification] = []
        var postedHistory: [Notification] = []
        var removedIds: [String] = []
        var registeredCategories: [String: [NotificationAction]] = [:]
        var deliveredClicks: [NotificationClick] = []
        var clickHandler: (@Sendable (NotificationClick) -> Void)?
        var bringToFrontCount: Int = 0
    }

    private let lock = NotifyLock(initialState: State())

    public init(available: Bool = true, appFocused: Bool = false) {
        lock.withLock { state in
            state.available = available
            state.appFocused = appFocused
        }
    }

    public var isAvailable: Bool {
        lock.withLock { $0.available }
    }

    public var isAppFocused: Bool {
        lock.withLock { $0.appFocused }
    }

    public func setAvailable(_ available: Bool) {
        lock.withLock { $0.available = available }
    }

    public func setAppFocused(_ focused: Bool) {
        lock.withLock { $0.appFocused = focused }
    }

    public func post(_ notification: Notification) -> Bool {
        lock.withLock { state in
            guard state.available else { return false }
            if !notification.actions.isEmpty {
                let categoryId = notification.categoryIdentifier
                    ?? NotificationCategoryHasher.identifier(for: notification.actions)
                state.registeredCategories[categoryId] = Array(notification.actions.prefix(10))
            }
            if let existingIndex = state.activeNotifications.firstIndex(where: { $0.id == notification.id }) {
                state.activeNotifications[existingIndex] = notification
            } else {
                state.activeNotifications.append(notification)
            }
            state.postedHistory.append(notification)
            return true
        }
    }

    public func remove(ids: [String]) {
        guard !ids.isEmpty else { return }
        lock.withLock { state in
            guard state.available else { return }
            let idSet = Set(ids)
            state.activeNotifications.removeAll { idSet.contains($0.id) }
            state.removedIds.append(contentsOf: ids)
        }
    }

    public func setClickHandler(_ handler: (@Sendable (NotificationClick) -> Void)?) {
        lock.withLock { $0.clickHandler = handler }
    }

    public func bringToFront() {
        lock.withLock { $0.bringToFrontCount += 1 }
    }

    /// Simulates a user clicking a notification or one of its actions.
    @discardableResult
    public func simulateClick(
        notificationId: String,
        actionId: String? = nil,
        inputText: String? = nil
    ) -> NotificationClick {
        let (click, handler) = lock.withLock { state -> (NotificationClick, (@Sendable (NotificationClick) -> Void)?) in
            var pairs = state.activeNotifications.first(where: { $0.id == notificationId })?.info ?? []
            pairs.sort { $0.0 < $1.0 }
            if let actionId {
                if let inputText {
                    pairs.append((RuneNotifyConstants.inputPrefix + actionId, inputText))
                }
                pairs.append((RuneNotifyConstants.actionKey, actionId))
            }
            let click = NotificationClick(id: notificationId, info: pairs)
            state.deliveredClicks.append(click)
            return (click, state.clickHandler)
        }
        handler?(click)
        return click
    }

    public var activeNotifications: [Notification] {
        lock.withLock { $0.activeNotifications }
    }

    public var postedHistory: [Notification] {
        lock.withLock { $0.postedHistory }
    }

    public var removedIds: [String] {
        lock.withLock { $0.removedIds }
    }

    public var registeredCategories: [String: [NotificationAction]] {
        lock.withLock { $0.registeredCategories }
    }

    public var deliveredClicks: [NotificationClick] {
        lock.withLock { $0.deliveredClicks }
    }

    public var bringToFrontCount: Int {
        lock.withLock { $0.bringToFrontCount }
    }

    public var registeredIdentity: NotificationIdentity? {
        lock.withLock { $0.registeredIdentity }
    }

    public func register(_ identity: NotificationIdentity) -> Result<Void, NotificationError> {
        lock.withLock { $0.registeredIdentity = identity }
        return .success(())
    }

    public func adopt(_ identity: NotificationIdentity) -> Result<Void, NotificationError> {
        lock.withLock { $0.registeredIdentity = identity }
        return .success(())
    }

    public func clickFromURL(_ url: String) -> NotificationClick? {
        let scheme = lock.withLock { $0.registeredIdentity?.activationScheme }
        guard let scheme, !scheme.isEmpty else { return nil }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeSplit = trimmed.range(of: "://") else { return nil }
        let head = String(trimmed[..<schemeSplit.lowerBound])
        guard head.caseInsensitiveCompare(scheme) == .orderedSame else { return nil }
        let rest = String(trimmed[schemeSplit.upperBound...])
        guard rest.hasPrefix("notification/") else { return nil }
        let afterHost = String(rest.dropFirst("notification/".count))
        let parts = afterHost.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawId = String(parts[0]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let id = rawId.removingPercentEncoding ?? rawId
        var info: [(String, String)] = []
        if parts.count > 1, !parts[1].isEmpty {
            for item in parts[1].split(separator: "&") {
                let kv = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let k = String(kv[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[0])
                let v = kv.count > 1
                    ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1]))
                    : ""
                info.append((k, v))
            }
        }
        return NotificationClick(id: id, info: info)
    }
}

/// Deterministic FNV-1a 64-bit category identifier for a list of actions.
public enum NotificationCategoryHasher {
    public static func identifier(for actions: [NotificationAction]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        func mix(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash &*= prime
            }
            hash ^= 0xff
            hash &*= prime
        }
        for action in actions {
            switch action {
            case .button(let id, let label):
                mix("button")
                mix(id)
                mix(label)
            case .reply(let id, let placeholder, let label):
                mix("reply")
                mix(id)
                mix(placeholder)
                mix(label)
            }
        }
        return String(format: "rune.%016llx", hash)
    }
}
