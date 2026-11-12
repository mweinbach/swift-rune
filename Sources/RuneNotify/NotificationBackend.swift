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
}

/// Deterministic headless notification backend for unit tests and non-bundled environments.
public final class MockNotificationBackend: NotificationBackend, @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var available: Bool = true
        var appFocused: Bool = false
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
