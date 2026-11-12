import Foundation

/// High-level notification service wrapping a `NotificationBackend`.
public final class NotificationService: Sendable {
    public let backend: any NotificationBackend

    public init(backend: any NotificationBackend = PlatformDefaultNotificationBackend.shared) {
        self.backend = backend
    }

    /// Whether notifications can be posted in the current process environment.
    public var isAvailable: Bool {
        backend.isAvailable
    }

    /// Whether the application is currently active and focused.
    public var isAppFocused: Bool {
        backend.isAppFocused
    }

    /// Registers an application identity (no-op on Apple platforms where identity comes from the bundle).
    public func register(_ identity: NotificationIdentity) {
        _ = backend.register(identity)
    }

    /// Registers an application identity, returning `Result` parity with upstream `rune-notify::register`.
    @discardableResult
    public func registerWithResult(_ identity: NotificationIdentity) -> Result<Void, NotificationError> {
        backend.register(identity)
    }

    /// Adopts a pre-registered application identity (no-op on Apple platforms).
    public func adopt(_ identity: NotificationIdentity) {
        _ = backend.adopt(identity)
    }

    /// Adopts a pre-registered application identity, returning `Result` parity with upstream `rune-notify::adopt`.
    @discardableResult
    public func adoptWithResult(_ identity: NotificationIdentity) -> Result<Void, NotificationError> {
        backend.adopt(identity)
    }

    /// Parses an activation URL (`<scheme>://notification/<id>?...`) into a click when supported.
    public func clickFromURL(_ url: String) -> NotificationClick? {
        backend.clickFromURL(url)
    }

    /// Serves toast activations for `clsid` on Windows; no-op returning `.success(())` elsewhere.
    @discardableResult
    public func serveActivations(_ clsid: String) -> Result<Void, NotificationError> {
        backend.serveActivations(clsid)
    }

    /// Waits up to `timeout` for a COM activation for `clsid` on Windows; returns `nil` elsewhere.
    public func waitActivation(_ clsid: String, timeout: TimeInterval) -> NotificationClick? {
        backend.waitActivation(clsid, timeout: timeout)
    }

    /// Posts a notification, returning `false` if unavailable.
    @discardableResult
    public func post(_ notification: Notification) -> Bool {
        backend.post(notification)
    }

    /// Removes delivered and pending notifications with the given identifiers.
    public func remove(ids: [String]) {
        backend.remove(ids: ids)
    }

    /// Installs a callback invoked when the user clicks a notification or action.
    public func onClick(_ handler: @escaping @Sendable (NotificationClick) -> Void) {
        backend.setClickHandler(handler)
    }

    /// Clears the click callback.
    public func clearClickHandler() {
        backend.setClickHandler(nil)
    }

    /// Brings the application's main window forward and activates the app.
    public func bringToFront() {
        backend.bringToFront()
    }
}

/// Top-level convenience namespace matching upstream `rune-notify`.
public enum RuneNotify {
    public static let shared = NotificationService(backend: PlatformDefaultNotificationBackend.shared)

    public static var isAvailable: Bool { shared.isAvailable }
    public static var isAppFocused: Bool { shared.isAppFocused }

    public static func register(_ identity: NotificationIdentity) {
        shared.register(identity)
    }

    @discardableResult
    public static func registerWithResult(_ identity: NotificationIdentity) -> Result<Void, NotificationError> {
        shared.registerWithResult(identity)
    }

    public static func adopt(_ identity: NotificationIdentity) {
        shared.adopt(identity)
    }

    @discardableResult
    public static func adoptWithResult(_ identity: NotificationIdentity) -> Result<Void, NotificationError> {
        shared.adoptWithResult(identity)
    }

    public static func clickFromURL(_ url: String) -> NotificationClick? {
        shared.clickFromURL(url)
    }

    @discardableResult
    public static func serveActivations(_ clsid: String) -> Result<Void, NotificationError> {
        shared.serveActivations(clsid)
    }

    public static func waitActivation(_ clsid: String, timeout: TimeInterval) -> NotificationClick? {
        shared.waitActivation(clsid, timeout: timeout)
    }

    @discardableResult
    public static func post(_ notification: Notification) -> Bool {
        shared.post(notification)
    }

    public static func remove(ids: [String]) {
        shared.remove(ids: ids)
    }

    public static func onClick(_ handler: @escaping @Sendable (NotificationClick) -> Void) {
        shared.onClick(handler)
    }

    public static func bringToFront() {
        shared.bringToFront()
    }
}
