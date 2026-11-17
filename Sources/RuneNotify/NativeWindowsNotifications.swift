#if os(Windows)
import Foundation
import CRuneNotify

/// Desktop notifications for unpackaged Win32 apps that register or adopt an AppUserModelID.
final class NativeWindowsNotifications: NotificationBackend, @unchecked Sendable {
    static let shared = NativeWindowsNotifications()

    private struct State {
        var identity: NotificationIdentity?
        var handler: (@Sendable (NotificationClick) -> Void)?
    }
    private let lock = NotifyLock(initialState: State())

    var isAvailable: Bool { lock.withLock { $0.identity != nil } }
    var isAppFocused: Bool { rune_notify_win_focused() != 0 }

    func register(_ identity: NotificationIdentity) -> Result<Void, NotificationError> {
        configure(identity, write: true)
    }

    func adopt(_ identity: NotificationIdentity) -> Result<Void, NotificationError> {
        configure(identity, write: false)
    }

    private func configure(_ identity: NotificationIdentity, write: Bool) -> Result<Void, NotificationError> {
        var normalized = identity
        guard !identity.id.isEmpty, identity.id.utf16.count <= 128,
              !identity.id.contains("\\"), !identity.id.utf8.contains(0),
              !identity.name.utf8.contains(0), !(identity.iconPath?.utf8.contains(0) ?? false) else {
            return .failure(.message("Invalid Windows notification identity"))
        }
        if let scheme = identity.activationScheme {
            guard let valid = WindowsToastContent.validScheme(scheme) else {
                return .failure(.message("Invalid notification activation scheme: \(scheme)"))
            }
            normalized.activationScheme = valid
        }
        return lock.withLock { state in
            let result = normalized.id.withCString(encodedAs: UTF16.self) { id in
                normalized.name.withCString(encodedAs: UTF16.self) { name in
                    (normalized.iconPath ?? "").withCString(encodedAs: UTF16.self) { icon in
                        (normalized.activationScheme ?? "").withCString(encodedAs: UTF16.self) { scheme in
                            rune_notify_win_identity(id, name, icon, scheme, write ? 1 : 0)
                        }
                    }
                }
            }
            guard result >= 0 else { return .failure(Self.error("Registering the Windows notification identity", result)) }
            state.identity = normalized
            return .success(())
        }
    }

    func clickFromURL(_ url: String) -> NotificationClick? {
        WindowsToastContent.click(url: url, scheme: lock.withLock { $0.identity?.activationScheme })
    }

    func post(_ notification: Notification) -> Bool {
        guard let identity = lock.withLock({ $0.identity }) else { return false }
        let presentation: Int32 = switch notification.urgency {
        case .active: 0
        case .passive: 1
        case .timeSensitive, .critical: 2
        }
        return identity.id.withCString(encodedAs: UTF16.self) { app in
            let xml = WindowsToastContent.xml(notification, scheme: identity.activationScheme,
                                              background: rune_notify_win_has_activator(app) != 0)
            return xml.withCString(encodedAs: UTF16.self) { content in
                WindowsToastContent.tag(for: notification.id).withCString(encodedAs: UTF16.self) { tag in
                    rune_notify_windows_show(app, content, tag, presentation,
                                             Self.activation, nil) >= 0
                }
            }
        }
    }

    func remove(ids: [String]) {
        guard let identity = lock.withLock({ $0.identity }) else { return }
        identity.id.withCString(encodedAs: UTF16.self) { app in
            for id in ids {
                _ = WindowsToastContent.tag(for: id).withCString(encodedAs: UTF16.self) {
                    rune_notify_windows_remove(app, $0)
                }
            }
        }
    }

    func bringToFront() { rune_notify_win_front() }

    func setClickHandler(_ handler: (@Sendable (NotificationClick) -> Void)?) {
        lock.withLock { $0.handler = handler }
    }

    func serveActivations(_ clsid: String) -> Result<Void, NotificationError> {
        guard !clsid.utf8.contains(0) else { return .failure(.message("Invalid activator class ID")) }
        let hr = clsid.withCString(encodedAs: UTF16.self) { rune_notify_serve_activations($0, Self.activation, nil) }
        return hr >= 0 ? .success(()) : .failure(Self.error("Serving Windows toast activations", hr))
    }

    func waitActivation(_ clsid: String, timeout: TimeInterval) -> NotificationClick? {
        guard !timeout.isNaN, timeout >= 0, !clsid.utf8.contains(0) else { return nil }
        let milliseconds = UInt32(min(timeout * 1000, Double(UInt32.max - 1)).rounded(.up))
        let box = NotifyLock<NotificationClick?>(initialState: nil)
        return withExtendedLifetime(box) {
            let context = Unmanaged.passUnretained(box).toOpaque()
            let hr = clsid.withCString(encodedAs: UTF16.self) {
                rune_notify_wait_activation($0, milliseconds, Self.activation, context)
            }
            return hr == 0 ? box.withLock { $0 } : nil
        }
    }

    private static let activation: RuneNotifyActivation = { context, args, inputs, count in
        guard let args else { return }
        let arguments = String(decodingCString: args, as: UTF16.self)
        var values: [(String, String)] = []
        if let inputs {
            for pair in UnsafeBufferPointer(start: inputs, count: count) {
                if let key = pair.key, let value = pair.value {
                    values.append((String(decodingCString: key, as: UTF16.self),
                                   String(decodingCString: value, as: UTF16.self)))
                }
            }
        }
        guard let click = WindowsToastContent.click(arguments: arguments, inputs: values) else { return }
        if let context {
            // A wait invokes this callback synchronously before it returns to Swift.
            let box = Unmanaged<NotifyLock<NotificationClick?>>.fromOpaque(context).takeUnretainedValue()
            box.withLock { $0 = click }
        } else {
            let handler = shared.lock.withLock { $0.handler }
            handler?(click)
        }
    }

    private static func error(_ operation: String, _ hr: Int32) -> NotificationError {
        .message("\(operation) failed (HRESULT 0x" + String(UInt32(bitPattern: hr), radix: 16) + ")")
    }
}
#endif
