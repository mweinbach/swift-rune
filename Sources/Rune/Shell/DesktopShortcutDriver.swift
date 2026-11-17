#if (os(Linux) || os(Windows)) && canImport(CRuneDesktopServices)
import CRuneDesktopServices

private final class DesktopShortcutReceiver: Sendable {
    let sink: ShortcutSink
    init(sink: @escaping ShortcutSink) { self.sink = sink }
}

private func receiveDesktopShortcut(_ context: UnsafeMutableRawPointer?, _ id: UInt32,
                                    _ token: UnsafePointer<CChar>?) {
    guard let context else { return }
    let receiver = Unmanaged<DesktopShortcutReceiver>.fromOpaque(context).takeUnretainedValue()
    receiver.sink(id, token.map { String(cString: $0) })
}

/// Runs on the shortcut service's owner thread. Native listeners deliver through
/// the shared sink, which enqueues state changes on the owning window's turn.
final class DesktopShortcutDriver: ShortcutBackendDriver {
    private let manager: UnsafeMutableRawPointer
    private let receiver: DesktopShortcutReceiver
    private let bind: (UnsafeMutableRawPointer?, UInt32, UInt8, UnsafePointer<CChar>?) -> Int32
    private let unbind: (UnsafeMutableRawPointer?, UInt32) -> Int32
    private let close: (UnsafeMutableRawPointer?) -> Void

    init(wayland: Bool, sink: @escaping ShortcutSink) throws(ShortcutError) {
        let open: (RuneHotkeySink?, UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>?) -> UnsafeMutableRawPointer?
        #if os(Windows)
        open = rune_win_hotkeys_open
        bind = rune_win_hotkeys_register
        unbind = rune_win_hotkeys_unregister
        close = rune_win_hotkeys_close
        #else
        if wayland {
            open = rune_portal_hotkeys_open
            bind = rune_portal_hotkeys_register
            unbind = rune_portal_hotkeys_unregister
            close = rune_portal_hotkeys_close
        } else {
            open = rune_x11_hotkeys_open
            bind = rune_x11_hotkeys_register
            unbind = rune_x11_hotkeys_unregister
            close = rune_x11_hotkeys_close
        }
        #endif
        let receiver = DesktopShortcutReceiver(sink: sink)
        self.receiver = receiver
        var status = Int32(RUNE_HOTKEY_FAILED)
        guard let manager = open(receiveDesktopShortcut, Unmanaged.passUnretained(receiver).toOpaque(), &status) else {
            throw Self.error(status, id: 0, accelerator: "")
        }
        self.manager = manager
    }

    deinit {
        // close joins the listener before its borrowed Swift context can go away.
        withExtendedLifetime(receiver) { close(manager) }
    }

    func register(id: UInt32, shortcut: ParsedShortcut) -> Result<Void, ShortcutError> {
        let status = shortcut.keyName.withCString { bind(manager, id, shortcut.mods & 0x0f, $0) }
        return status == RUNE_HOTKEY_OK ? .success(()) : .failure(Self.error(status, id: id, accelerator: shortcut.description))
    }

    func unregister(id: UInt32) -> Result<Void, ShortcutError> {
        let status = unbind(manager, id)
        return status == RUNE_HOTKEY_OK ? .success(()) : .failure(Self.error(status, id: id, accelerator: ""))
    }

    private static func error(_ status: Int32, id: UInt32, accelerator: String) -> ShortcutError {
        switch Int(status) {
        case RUNE_HOTKEY_CONFLICT: .alreadyInUse(owner: nil)
        case RUNE_HOTKEY_INVALID: .invalidAccelerator(accelerator)
        case RUNE_HOTKEY_UNKNOWN_ID: .unknownId(String(id))
        case RUNE_HOTKEY_UNSUPPORTED: .unsupported
        case RUNE_HOTKEY_DENIED: .permissionDenied
        default: .rejectedByOS("The desktop shortcut service could not complete its request.")
        }
    }

    static var usesWayland: Bool {
        #if os(Linux)
        rune_hotkeys_uses_wayland() != 0
        #else
        false
        #endif
    }
}
#endif
