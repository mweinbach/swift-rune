#if os(Windows)
import CRuneWin32
import Foundation

/// Identifies one displayed Runtime request across Win32's nested menu message loop.
@MainActor
private final class WindowsPopupOperation {
    struct Command {
        let id: String
        let chord: Chord?
        let enabled: Bool
    }

    let request: ErasedPopupRequest
    private var commands: [Command] = []
    let complete: (WindowsPopupOperation, String?) -> Void

    init(request: ErasedPopupRequest, complete: @escaping (WindowsPopupOperation, String?) -> Void) {
        self.request = request
        self.complete = complete
    }

    func populate(_ native: OpaquePointer, from menu: PopupMenu, enabled: Bool = true) -> Bool {
        for entry in menu.entries {
            switch entry {
            case .separator:
                guard rune_win_popup_item(native, 0, nil, 0, 0) != 0 else { return false }
            case .submenu(let title, let submenu, let canOpen):
                guard !title.utf8.contains(0) else { return false }
                let label = Array(title.replacingOccurrences(of: "\t", with: " ").utf16) + [0]
                let child = label.withUnsafeBufferPointer { rune_win_popup_submenu(native, $0.baseAddress, canOpen ? 1 : 0) }
                guard let child, populate(child, from: submenu, enabled: enabled && canOpen) else { return false }
            case .item(let item):
                guard let command = UInt32(exactly: commands.count + 1), !item.title.utf8.contains(0) else { return false }
                let chord = item.keyEquivalent.flatMap(Chord.init(parsing:))
                var label = item.title.replacingOccurrences(of: "\t", with: " ")
                if let chord {
                    label += "\t" + chord.menuKeycaps(on: .windows).joined(separator: "+")
                }
                let title = Array(label.utf16) + [0]
                let added = title.withUnsafeBufferPointer {
                    rune_win_popup_item(native, command, $0.baseAddress, item.enabled ? 1 : 0, item.checked ? 1 : 0)
                }
                guard added != 0 else { return false }
                commands.append(Command(id: item.id, chord: chord, enabled: enabled && item.enabled))
            }
        }
        return true
    }

    func positioned(_ id: String?) -> UInt32 {
        guard let id, let index = commands.firstIndex(where: { $0.id == id }) else { return 0 }
        return UInt32(index + 1)
    }

    func command(vk: UInt32, modifiers: UInt32, scalar: UInt32) -> UInt32 {
        // Right Alt with synthetic Control is AltGr text input.
        let rightAltWithControl: UInt32 = 16 | 2
        guard modifiers & rightAltWithControl != rightAltWithControl else { return 0 }
        let mods = Win32KeyMap.modifiers(modifiers)
        guard let key = Win32KeyMap.shortcutKey(virtualKey: vk, scalar: UnicodeScalar(scalar), mods: mods) else { return 0 }
        let event = KeyEvent(key: key, mods: mods)
        guard let index = commands.firstIndex(where: { $0.enabled && $0.chord?.matches(event, on: .windows) == true })
        else { return 0 }
        return UInt32(index + 1)
    }

    func finish(_ command: UInt32) {
        if command != 0, let index = Int(exactly: command - 1), commands.indices.contains(index) {
            let item = commands[index]
            complete(self, item.enabled ? item.id : nil)
        } else {
            complete(self, nil)
        }
    }
}

private func win32PopupKey(_ context: UnsafeMutableRawPointer?, _ vk: UInt32, _ mods: UInt32, _ scalar: UInt32) -> UInt32 {
    guard let context else { return 0 }
    let operation = Unmanaged<WindowsPopupOperation>.fromOpaque(context).takeUnretainedValue()
    return MainActor.assumeIsolated { operation.command(vk: vk, modifiers: mods, scalar: scalar) }
}

private func win32PopupDone(_ context: UnsafeMutableRawPointer?, _ command: UInt32) {
    guard let context else { return }
    let operation = Unmanaged<WindowsPopupOperation>.fromOpaque(context).takeRetainedValue()
    MainActor.assumeIsolated { operation.finish(command) }
}

@MainActor
final class WindowsPopup<State> {
    private let window: OpaquePointer
    private let runtime: Runtime<State>
    private let lock: NSRecursiveLock?
    private var active: WindowsPopupOperation?
    private var closed = false

    init(window: OpaquePointer, runtime: Runtime<State>, lock: NSRecursiveLock? = nil) {
        self.window = window
        self.runtime = runtime
        self.lock = lock
    }

    func pump() {
        guard !closed else { return }
        if runtime.windowFocused { syncScheme() }
        if let active, runtime.popupQueue.front !== active.request {
            rune_win_popup_cancel(rune_win_hwnd(window))
            return
        }
        guard active == nil else { return }
        // takePopup answers malformed or missing-anchor requests. Continue to the next queued request.
        for _ in 0..<64 {
            guard let result = runtime.takePopup() else { return }
            guard case .success(let show) = result, let request = runtime.popupQueue.front else { continue }
            let operation = WindowsPopupOperation(request: request) { [weak self] operation, picked in
                guard let self, self.active === operation else { return }
                self.active = nil
                // An overlay may also be updated by the application from another thread.
                self.lock?.lock()
                defer { self.lock?.unlock() }
                if self.runtime.popupIsOpen, self.runtime.popupQueue.front === operation.request {
                    try? self.runtime.resolvePopup(picked)
                }
                self.runtime.waker.wake()
            }
            active = operation
            if !post(show, operation: operation) { operation.finish(0) }
            return
        }
        runtime.waker.wake()
    }

    private func post(_ show: PopupShow, operation: WindowsPopupOperation) -> Bool {
        syncScheme()
        guard let native = rune_win_popup_create() else { return false }
        guard operation.populate(native, from: show.menu) else {
            rune_win_popup_dispose(native)
            return false
        }
        let x, y, width, height: Float
        let isRect: Int32
        switch show.anchor {
        case .point(let px, let py):
            (x, y, width, height, isRect) = (px, py, 0, 0, 0)
        case .rect(let rect):
            (x, y, width, height, isRect) = (rect.left, rect.top, rect.width, rect.height, 1)
        }
        let rtl: Int32 = runtime.flatNodes.first?.flow == .rtl ? 1 : -1
        let retained = Unmanaged.passRetained(operation)
        let posted = rune_win_popup_show(rune_win_hwnd(window), native, Double(x), Double(y), Double(width), Double(height),
                                         isRect, rtl, operation.positioned(show.menu.selectedId),
                                         retained.toOpaque(), win32PopupKey, win32PopupDone)
        if posted == 0 {
            retained.release()
            rune_win_popup_dispose(native)
        }
        return posted != 0
    }

    private func syncScheme() {
        let dark = runtime.backdropDark() ?? runtime.systemDark
        rune_win_menu_scheme(dark ? RuneWinMenuDark : RuneWinMenuLight)
    }

    func cancel() {
        // A native cancellation delivers a callback synchronously. The runtime owns all remaining dismissals.
        active = nil
        rune_win_popup_cancel(rune_win_hwnd(window))
        runtime.cancelPopups()
    }

    func close() {
        guard !closed else { return }
        closed = true
        cancel()
    }
}
#endif
