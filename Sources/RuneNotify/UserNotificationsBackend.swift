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

#if os(Linux)
/// Linux `notify-send` CLI notification backend.
public final class LinuxNotifySendBackend: NotificationBackend, @unchecked Sendable {
    public static let shared = LinuxNotifySendBackend()

    private init() {}

    public var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/notify-send")
            || FileManager.default.isExecutableFile(atPath: "/bin/notify-send")
    }

    public var isAppFocused: Bool { false }

    public func post(_ notification: Notification) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = ["notify-send"]
        switch notification.urgency {
        case .passive: args += ["-u", "low"]
        case .active: args += ["-u", "normal"]
        case .timeSensitive: args += ["-u", "critical"]
        }
        args.append(notification.title)
        if !notification.body.isEmpty {
            args.append(notification.body)
        }
        process.arguments = args
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    public func remove(ids: [String]) {}
    public func setClickHandler(_ handler: (@Sendable (NotificationClick) -> Void)?) {}
    public func bringToFront() {}
}
#endif

#if os(Windows)
/// Windows PowerShell WinRT toast notification backend.
public final class WindowsToastBackend: NotificationBackend, @unchecked Sendable {
    public static let shared = WindowsToastBackend()

    private init() {}

    public var isAvailable: Bool { true }
    public var isAppFocused: Bool { false }

    public func post(_ notification: Notification) -> Bool {
        let escapedTitle = notification.title.replacingOccurrences(of: "'", with: "''")
        let escapedBody = notification.body.replacingOccurrences(of: "'", with: "''")
        let script = """
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $nodes = $xml.GetElementsByTagName('text')
        $nodes.Item(0).AppendChild($xml.CreateTextNode('\(escapedTitle)')) | Out-Null
        $nodes.Item(1).AppendChild($xml.CreateTextNode('\(escapedBody)')) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Rune').Show($toast)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "powershell.exe")
        process.arguments = ["-NoProfile", "-NonInteractive", "-Command", script]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    public func remove(ids: [String]) {}
    public func setClickHandler(_ handler: (@Sendable (NotificationClick) -> Void)?) {}
    public func bringToFront() {}
}
#endif

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
