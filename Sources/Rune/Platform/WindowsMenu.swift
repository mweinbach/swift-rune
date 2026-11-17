#if os(Windows)
import CRuneWin32
import Foundation

@MainActor
private final class Win32MenuSelection {
    var select: (UInt32, UInt64) -> Void = { _, _ in }
}

private func win32MenuSelected(_ context: UnsafeMutableRawPointer?, _ command: UInt32, _ revision: UInt64) {
    guard let context else { return }
    let selection = Unmanaged<Win32MenuSelection>.fromOpaque(context).takeUnretainedValue()
    // WM_MENUCOMMAND runs in the thread that owns this window and its Rune runtime.
    MainActor.assumeIsolated { selection.select(command, revision) }
}

/// Each window owns its native menu handles. Replacement builds an independent tree and
/// swaps it atomically once the native menu loop releases its active popup.
@MainActor
final class WindowsMenu<State> {
    private let window: OpaquePointer
    private let shared: AppShared<State>
    private let appTitle: String
    private let selection = Win32MenuSelection()
    private var native: OpaquePointer?
    private var snapshot: DesktopMenuSnapshot?
    private var lastAttempt: UInt64?
    private var commands: [String] = []
    private var consumedScans: Set<UInt32> = []

    init(window: OpaquePointer, shared: AppShared<State>, title: String) {
        self.window = window
        self.shared = shared
        self.appTitle = title
        selection.select = { [weak self] command, revision in
            guard let self, snapshot?.revision == revision, command > 0, Int(command) <= commands.count else { return }
            _ = AppMenuBridge.fireIfCurrent(id: commands[Int(command) - 1], revision: revision, for: shared)
        }
    }

    func close() {
        rune_win_menu_close(native)
        native = nil
    }

    func synchronize() {
        guard rune_win_menu_tracking(native) == 0,
              let next = AppMenuBridge.desktopSnapshot(for: shared, applicationTitle: appTitle, after: lastAttempt) else { return }
        lastAttempt = next.revision
        do {
            if !next.sections.isEmpty { try install(next) }
            else if let native, rune_win_menu_install(native, nil, next.revision) == 0 {
                throw MenuError.backend("SetMenu could not remove the window menu")
            } else { commands.removeAll() }
            snapshot = next
        } catch {
            AppMenuBridge.recordError((error as? MenuError) ?? .backend(String(describing: error)), for: shared)
        }
    }

    private func install(_ next: DesktopMenuSnapshot) throws {
        if native == nil {
            native = rune_win_menu_open(rune_win_hwnd(window), Unmanaged.passUnretained(selection).toOpaque(), win32MenuSelected)
        }
        guard let native, let draft = rune_win_menu_begin() else { throw MenuError.backend("Cannot create Windows menu") }
        defer { rune_win_menu_dispose(draft) }
        var ids: [String] = []
        for section in next.sections {
            let top = try label(section.title)
            guard top.withUnsafeBufferPointer({ rune_win_menu_section(draft, $0.baseAddress) }) != 0 else {
                throw MenuError.backend("Cannot create menu \(section.title)")
            }
            for item in section.items {
                var command: UInt32 = 0
                var line = [UInt16]()
                if !item.isSeparator {
                    ids.append(item.id)
                    guard let id = UInt32(exactly: ids.count) else { throw MenuError.invalid("too many Windows menu items") }
                    command = id
                    let keys = item.accelerator?.menuKeycaps(on: .windows).joined(separator: "+") ?? ""
                    line = try label(item.title, keys: keys)
                }
                guard line.withUnsafeBufferPointer({
                    rune_win_menu_item(draft, command, $0.baseAddress, item.enabled ? 1 : 0, item.checked ? 1 : 0)
                }) != 0 else { throw MenuError.backend("Cannot insert menu item \(item.id)") }
            }
        }
        guard rune_win_menu_install(native, draft, next.revision) != 0 else {
            throw MenuError.backend("SetMenu could not install the window menu")
        }
        commands = ids
    }

    private func label(_ title: String, keys: String = "") throws -> [UInt16] {
        guard !title.utf8.contains(0) else { throw MenuError.invalid("NUL in Windows menu label") }
        let escaped = title.replacingOccurrences(of: "&", with: "&&").replacingOccurrences(of: "\t", with: " ")
        return Array((keys.isEmpty ? escaped : escaped + "\t" + keys).utf16) + [0]
    }

    func lostFocus() { consumedScans.removeAll() }

    func takeRelease(scan: UInt32) -> Bool { consumedScans.remove(scan) != nil }

    /// Named keys and Ctrl shortcuts carry their logical event at WM_KEYDOWN. Ordinary
    /// printable input receives its layout-dependent logical event later at WM_CHAR.
    func keyDown(vk: UInt32, scan: UInt32, shortcut: UnicodeScalar?, mods: Mods, altGr: Bool,
                 deliver: () -> Bool) -> Bool {
        guard !altGr else { return deliver() }
        let mapped = Win32KeyMap.translate(virtualKey: vk, shift: mods.shift)
        let char = shortcut.flatMap { $0.value >= 32 && $0.value != 127 ? String($0) : nil }
        let candidate: Key?
        let waitsForChar: Bool
        switch mapped {
        case .text, nil:
            candidate = char.map(Key.text) ?? mapped
            waitsForChar = !mods.ctrl
        case .space:
            candidate = mapped
            waitsForChar = !(mods.ctrl || mods.alt || mods.logo)
        default:
            candidate = mapped
            waitsForChar = false
        }
        guard let key = candidate, let snap = snapshot,
              let item = snap.matching(KeyEvent(key: key, mods: mods), on: .windows) else { return deliver() }
        if item.keysFirst {
            if deliver() { return true }
            return !waitsForChar && AppMenuBridge.fireIfCurrent(id: item.id, revision: snap.revision, for: shared)
        }
        if AppMenuBridge.fireIfCurrent(id: item.id, revision: snap.revision, for: shared) {
            consumedScans.insert(scan)
            return true
        }
        return deliver()
    }

    func character(_ event: KeyEvent, deliver: () -> Bool) -> Bool {
        guard let snap = snapshot, let item = snap.matching(event, on: .windows) else { return deliver() }
        if item.keysFirst { return deliver() || AppMenuBridge.fireIfCurrent(id: item.id, revision: snap.revision, for: shared) }
        return AppMenuBridge.fireIfCurrent(id: item.id, revision: snap.revision, for: shared) || deliver()
    }
}
#endif
