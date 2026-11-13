import Foundation
#if canImport(UserNotifications)
import os
import UserNotifications
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Native Apple `UNUserNotificationCenter` backend.
///
/// On macOS, `UNUserNotificationCenter.current()` throws an Objective-C exception if accessed
/// from an unbundled executable (such as `swift test` or `swift run`). This backend checks
/// `isBundledApp` before touching `UNUserNotificationCenter` and safely degrades to no-ops when
/// unbundled.
public final class UserNotificationsBackend: NSObject, NotificationBackend, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = UserNotificationsBackend()

    private struct State: Sendable {
        var clickHandler: (@Sendable (NotificationClick) -> Void)?
        var registeredCategories: [String: [NotificationAction]] = [:]
        var delegateInstalled: Bool = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    public override init() {
        super.init()
    }

    /// True when running inside a `.app` bundle with a valid bundle identifier.
    public static var isBundledApp: Bool {
        let bundle = Bundle.main
        guard let id = bundle.bundleIdentifier, !id.isEmpty else {
            return false
        }
        #if os(macOS)
        return bundle.bundlePath.hasSuffix(".app")
        #else
        return true
        #endif
    }

    public var isAvailable: Bool {
        Self.isBundledApp
    }

    public var isAppFocused: Bool {
        #if os(macOS)
        if !Self.isBundledApp {
            return false
        }
        let check: @MainActor () -> Bool = {
            NSApplication.shared.isActive && NSApplication.shared.keyWindow != nil
        }
        if Thread.isMainThread {
            return MainActor.assumeIsolated(check)
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated(check)
        }
        #else
        return false
        #endif
    }

    public func post(_ notification: Notification) -> Bool {
        guard isAvailable else { return false }

        let center = UNUserNotificationCenter.current()
        var options: UNAuthorizationOptions = [.alert]
        if notification.sound != .none {
            options.insert(.sound)
        }

        center.requestAuthorization(options: options) { [weak self] granted, _ in
            guard granted, let self else { return }
            self.enqueue(notification, on: UNUserNotificationCenter.current())
        }
        return true
    }

    public func remove(ids: [String]) {
        guard !ids.isEmpty, isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    public func setClickHandler(_ handler: (@Sendable (NotificationClick) -> Void)?) {
        let shouldInstall = lock.withLock { state -> Bool in
            state.clickHandler = handler
            if handler != nil, !state.delegateInstalled, isAvailable {
                state.delegateInstalled = true
                return true
            }
            return false
        }
        if shouldInstall {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    public func bringToFront() {
        #if os(macOS)
        let activate: @MainActor () -> Void = {
            let app = NSApplication.shared
            let window = app.mainWindow ?? app.windows.first
            if let window {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
            }
            app.activate(ignoringOtherApps: true)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(activate)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated(activate)
            }
        }
        #endif
    }

    private func enqueue(_ notification: Notification, on center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        if let subtitle = notification.subtitle {
            content.subtitle = subtitle
        }
        content.body = notification.body

        var userInfo: [String: String] = [:]
        userInfo.reserveCapacity(notification.info.count)
        for (key, value) in notification.info {
            userInfo[key] = value
        }
        content.userInfo = userInfo

        switch notification.sound {
        case .none:
            content.sound = nil
        case .default:
            content.sound = .default
        case .named(let name):
            content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: name))
        }

        switch notification.urgency {
        case .passive:
            content.interruptionLevel = .passive
        case .active:
            content.interruptionLevel = .active
        case .timeSensitive:
            content.interruptionLevel = .timeSensitive
        case .critical:
            content.interruptionLevel = .critical
        }

        if let categoryId = registerCategoryIfNeeded(for: notification, on: center) {
            content.categoryIdentifier = categoryId
        }

        let request = UNNotificationRequest(
            identifier: notification.id,
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    private func registerCategoryIfNeeded(
        for notification: Notification,
        on center: UNUserNotificationCenter
    ) -> String? {
        if notification.actions.isEmpty {
            return notification.categoryIdentifier
        }

        let categoryId = notification.categoryIdentifier
            ?? NotificationCategoryHasher.identifier(for: notification.actions)

        let allCategories: [String: [NotificationAction]]? = lock.withLock { state in
            if state.registeredCategories[categoryId] != nil {
                return nil
            }
            state.registeredCategories[categoryId] = Array(notification.actions.prefix(10))
            return state.registeredCategories
        }

        if let allCategories {
            let unCategories = Set(allCategories.map { catId, actions in
                let unActions: [UNNotificationAction] = actions.map { action in
                    switch action {
                    case .button(let id, let label):
                        return UNNotificationAction(identifier: id, title: label, options: [])
                    case .reply(let id, let placeholder, let label):
                        return UNTextInputNotificationAction(
                            identifier: id,
                            title: label,
                            options: [],
                            textInputButtonTitle: label,
                            textInputPlaceholder: placeholder
                        )
                    }
                }
                return UNNotificationCategory(
                    identifier: catId,
                    actions: unActions,
                    intentIdentifiers: [],
                    options: []
                )
            })
            center.setNotificationCategories(unCategories)
        }
        return categoryId
    }

    /// Parses a `NotificationClick` from raw notification response components.
    public static func parseClick(
        identifier: String,
        userInfo: [AnyHashable: Any],
        actionIdentifier: String,
        userText: String? = nil
    ) -> NotificationClick {
        var pairs: [(String, String)] = []
        for (rawKey, rawValue) in userInfo {
            if let key = rawKey as? String, let value = rawValue as? String {
                pairs.append((key, value))
            }
        }
        pairs.sort { $0.0 < $1.0 }

        if !actionIdentifier.isEmpty, !actionIdentifier.hasPrefix("com.apple.UNNotification") {
            if let userText {
                pairs.append((RuneNotifyConstants.inputPrefix + actionIdentifier, userText))
            }
            pairs.append((RuneNotifyConstants.actionKey, actionIdentifier))
        }

        return NotificationClick(id: identifier, info: pairs)
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        let userText = (response as? UNTextInputNotificationResponse)?.userText
        let click = Self.parseClick(
            identifier: request.identifier,
            userInfo: request.content.userInfo,
            actionIdentifier: response.actionIdentifier,
            userText: userText
        )
        let handler = lock.withLock { $0.clickHandler }
        handler?(click)
        completionHandler()
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        var options: UNNotificationPresentationOptions = [.list, .banner]
        if notification.request.content.sound != nil {
            options.insert(.sound)
        }
        completionHandler(options)
    }
}
#endif

#if os(macOS) || os(Linux) || os(Windows)
private func defaultNotificationCommandRunner(executableURL: URL, arguments: [String]) throws {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    try process.run()
}
#else
private func defaultNotificationCommandRunner(executableURL: URL, arguments: [String]) throws {
    throw NotificationError.message("Process execution is unavailable on this platform")
}
#endif

/// Injectable subprocess runner used by `LinuxNotifySendBackend` and `WindowsToastBackend`.
public typealias NotificationCommandRunner = @Sendable (_ executableURL: URL, _ arguments: [String]) throws -> Void

/// Linux `notify-send` CLI notification backend.
///
/// Note: Live `notify-send` binary execution and D-Bus daemon delivery are `N/A-platform` on Darwin/iOS/Windows.
public final class LinuxNotifySendBackend: NotificationBackend, @unchecked Sendable {
    public static let shared = LinuxNotifySendBackend()

    private struct State: Sendable {
        var identity: NotificationIdentity?
    }

    private let lock = NotifyLock(initialState: State())
    private let availableOverride: Bool?
    private let runner: NotificationCommandRunner

    public init(isAvailable: Bool? = nil, runner: NotificationCommandRunner? = nil) {
        self.availableOverride = isAvailable
        self.runner = runner ?? defaultNotificationCommandRunner
    }

    public var isAvailable: Bool {
        if let availableOverride {
            return availableOverride
        }
        return FileManager.default.isExecutableFile(atPath: "/usr/bin/notify-send")
            || FileManager.default.isExecutableFile(atPath: "/bin/notify-send")
    }

    public var isAppFocused: Bool { false }

    public func register(_ identity: NotificationIdentity) -> Result<Void, NotificationError> {
        adopt(identity)
    }

    public func adopt(_ identity: NotificationIdentity) -> Result<Void, NotificationError> {
        guard !identity.id.isEmpty else {
            return .failure(.message("not an app id: \(identity.id)"))
        }
        lock.withLock { $0.identity = identity }
        return .success(())
    }

    /// Builds the `notify-send` CLI argument list for `notification`.
    public func buildArguments(for notification: Notification) -> [String] {
        let identity = lock.withLock { $0.identity }
        var args = ["notify-send"]
        switch notification.urgency {
        case .passive:
            args.append("--urgency=low")
        case .active:
            args.append("--urgency=normal")
        case .timeSensitive, .critical:
            args.append("--urgency=critical")
        }
        if let identity {
            let appName = identity.name.isEmpty ? identity.id : identity.name
            if !appName.isEmpty {
                args.append("--app-name=\(appName)")
            }
            if let iconPath = identity.iconPath, !iconPath.isEmpty {
                args.append("--icon=\(iconPath)")
            }
        }
        if !notification.id.isEmpty {
            args.append("--replace-id=\(Self.replaceIdentifier(for: notification.id))")
        }
        for action in notification.actions {
            switch action {
            case .button(let id, let label), .reply(let id, _, let label):
                args.append("--action=\(id)=\(label)")
            }
        }
        args.append("--")
        args.append(notification.title)
        if !notification.body.isEmpty {
            args.append(notification.body)
        }
        return args
    }

    public func post(_ notification: Notification) -> Bool {
        guard isAvailable else { return false }
        let args = buildArguments(for: notification)
        do {
            try runner(URL(fileURLWithPath: "/usr/bin/env"), args)
            return true
        } catch {
            return false
        }
    }

    public func remove(ids: [String]) {}
    public func setClickHandler(_ handler: (@Sendable (NotificationClick) -> Void)?) {}
    public func bringToFront() {}

    private static func replaceIdentifier(for id: String) -> UInt32 {
        if let numeric = UInt32(id), numeric > 0 {
            return numeric
        }
        var hash: UInt32 = 0x811c9dc5
        for byte in id.utf8 {
            hash ^= UInt32(byte)
            hash &*= 0x01000193
        }
        return hash == 0 ? 1 : hash
    }
}

/// Windows PowerShell WinRT toast notification backend.
///
/// Note: Live WinRT COM activation (`serveActivations`/`waitActivation`) and Windows Registry
/// (`HKCU\Software\Classes\AppUserModelId`) calls are `N/A-platform` on Darwin/Linux.
public final class WindowsToastBackend: NotificationBackend, @unchecked Sendable {
    public static let shared = WindowsToastBackend()

    private struct State: Sendable {
        var identity: NotificationIdentity?
    }

    private let lock = NotifyLock(initialState: State())
    private let availableOverride: Bool?
    private let runner: NotificationCommandRunner

    public init(isAvailable: Bool? = nil, runner: NotificationCommandRunner? = nil) {
        self.availableOverride = isAvailable
        self.runner = runner ?? defaultNotificationCommandRunner
    }

    public var isAvailable: Bool {
        availableOverride ?? true
    }

    public var isAppFocused: Bool { false }

    public func register(_ identity: NotificationIdentity) -> Result<Void, NotificationError> {
        adopt(identity)
    }

    public func adopt(_ identity: NotificationIdentity) -> Result<Void, NotificationError> {
        guard !identity.id.isEmpty, !identity.id.contains("\\") else {
            return .failure(.message("not an app id: \(identity.id)"))
        }
        var normalized = identity
        if let scheme = identity.activationScheme {
            guard let valid = Self.validScheme(scheme) else {
                return .failure(.message("not a URL scheme: \(scheme)"))
            }
            normalized.activationScheme = valid
        }
        lock.withLock { $0.identity = normalized }
        return .success(())
    }

    public func clickFromURL(_ url: String) -> NotificationClick? {
        guard let scheme = lock.withLock({ $0.identity?.activationScheme }), !scheme.isEmpty else {
            return nil
        }
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

    public func post(_ notification: Notification) -> Bool {
        guard isAvailable else { return false }
        let appId = lock.withLock { $0.identity?.id } ?? "Rune"
        let escapedApp = Self.escapePowerShellSingleQuoted(appId)
        let escapedTitle = Self.escapePowerShellSingleQuoted(Self.escapeXML(notification.title))
        let escapedBody = Self.escapePowerShellSingleQuoted(Self.escapeXML(notification.body))
        let script = """
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $nodes = $xml.GetElementsByTagName('text')
        $nodes.Item(0).AppendChild($xml.CreateTextNode('\(escapedTitle)')) | Out-Null
        $nodes.Item(1).AppendChild($xml.CreateTextNode('\(escapedBody)')) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('\(escapedApp)').Show($toast)
        """
        do {
            try runner(
                URL(fileURLWithPath: "powershell.exe"),
                ["-NoProfile", "-NonInteractive", "-Command", script]
            )
            return true
        } catch {
            return false
        }
    }

    public func remove(ids: [String]) {}
    public func setClickHandler(_ handler: (@Sendable (NotificationClick) -> Void)?) {}
    public func bringToFront() {}

    private static func validScheme(_ scheme: String) -> String? {
        guard scheme.count >= 2, let first = scheme.first, first.isASCII && first.isLetter else {
            return nil
        }
        guard scheme.allSatisfy({ ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "+" || ch == "-" || ch == ".")
        }) else {
            return nil
        }
        return scheme.lowercased()
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func escapePowerShellSingleQuoted(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }
}

public enum PlatformDefaultNotificationBackend {
    public static var shared: any NotificationBackend {
        #if canImport(UserNotifications)
        return UserNotificationsBackend.shared
        #elseif os(Linux)
        return LinuxNotifySendBackend.shared
        #elseif os(Windows)
        return WindowsToastBackend.shared
        #else
        return MockNotificationBackend(available: false)
        #endif
    }
}
