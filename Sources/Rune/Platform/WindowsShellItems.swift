#if os(Windows)
import CRuneWin32
import Foundation

private final class WindowsTrayEvents {
    let send: @Sendable (TrayEvent) -> Void

    init(_ send: @escaping @Sendable (TrayEvent) -> Void) {
        self.send = send
    }
}

final class WindowsSystemTray {
    private let handle: OpaquePointer
    private var icon: TrayIcon?

    init(_ spec: TraySpec, onEvent: @escaping @Sendable (TrayEvent) -> Void) throws {
        let model = try Self.nativeModel(spec)
        let context = Unmanaged.passRetained(WindowsTrayEvents(onEvent)).toOpaque()
        var error: UInt32 = 0
        guard let handle = rune_win_tray_open(model, context, { raw, id in
            guard let raw else { return }
            let events = Unmanaged<WindowsTrayEvents>.fromOpaque(raw).takeUnretainedValue()
            if let id {
                events.send(.menu(String(decodingCString: id, as: UTF16.self)))
            } else {
                events.send(.activate(token: nil))
            }
        }, { raw in
            if let raw { Unmanaged<WindowsTrayEvents>.fromOpaque(raw).release() }
        }, &error) else {
            throw TrayError.backend("Shell_NotifyIconW failed (Win32 \(error))")
        }
        self.handle = handle
        self.icon = spec.icon
    }

    deinit { rune_win_tray_close(handle) }

    func update(_ spec: TraySpec) throws {
        rune_win_tray_update(handle, try Self.nativeModel(spec, keepIcon: icon == spec.icon))
        icon = spec.icon
    }

    static func removeAll() { rune_win_trays_remove_all() }

    private static func nativeModel(_ spec: TraySpec, keepIcon: Bool = false) throws -> OpaquePointer {
        let icon = try spec.icon?.validated()
        var tooltipUnits = TrayLabelFormatting.truncateUTF16(spec.tooltip, maxUnits: 127)
        tooltipUnits.append(0)
        let model = tooltipUnits.withUnsafeBufferPointer { buf -> OpaquePointer? in
            let tooltip = buf.baseAddress!
            if keepIcon { return rune_win_tray_spec_keeping_icon(tooltip) }
            guard let icon else { return rune_win_tray_spec(tooltip, nil, 0, 0) }
            return icon.rgba.withUnsafeBytes { bytes in
                rune_win_tray_spec(tooltip, bytes.bindMemory(to: UInt8.self).baseAddress, icon.width, icon.height)
            }
        }
        guard let model else { throw TrayError.backend("Could not create the Windows tray icon") }
        for item in spec.menu {
            switch item {
            case .separator:
                rune_win_tray_item(model, nil, nil, 0)
            case let .action(id, label, enabled):
                let escaped = TrayLabelFormatting.win32MenuLabel(label)
                id.withCString(encodedAs: UTF16.self) { id in
                    escaped.withCString(encodedAs: UTF16.self) { label in
                        rune_win_tray_item(model, id, label, enabled ? 1 : 0)
                    }
                }
            }
        }
        return model
    }
}

final class WindowsJumpListWorker: @unchecked Sendable {
    static let shared = WindowsJumpListWorker()
    private let condition = NSCondition()
    private var pending: JumpList?
    private var started = false

    func submit(_ list: JumpList) {
        condition.lock()
        pending = list
        if !started {
            started = true
            let thread = Thread { self.run() }
            thread.name = "rune-jump-list"
            thread.start()
        }
        condition.signal()
        condition.unlock()
    }

    private func run() {
        while true {
            condition.lock()
            while pending == nil { condition.wait() }
            let list = pending!
            pending = nil
            condition.unlock()
            let status = commit(list)
            if status < 0 {
                let error = String(UInt32(bitPattern: status), radix: 16)
                FileHandle.standardError.write(Data("rune: jump list HRESULT 0x\(error)\n".utf8))
            }
        }
    }

    private func commit(_ list: JumpList) -> Int32 {
        var draft: OpaquePointer?
        let status = list.lead.map { lead in
            lead.withCString(encodedAs: UTF16.self) { rune_win_jump_begin(&draft, $0) }
        } ?? rune_win_jump_begin(&draft, nil)
        guard status >= 0, let draft else { return status }
        defer { rune_win_jump_dispose(draft) }

        func append(_ items: [JumpItem]) -> Int32 {
            for item in items {
                let status = item.title.withCString(encodedAs: UTF16.self) { title in
                    item.argument.withCString(encodedAs: UTF16.self) { argument in
                        item.description.withCString(encodedAs: UTF16.self) { description in
                            rune_win_jump_item(draft, title, argument, description)
                        }
                    }
                }
                if status < 0 { return status }
            }
            return 0
        }

        let tasks = append(list.tasks)
        if tasks < 0 { return tasks }
        for category in list.categories {
            let status = category.name.withCString(encodedAs: UTF16.self) { rune_win_jump_category(draft, $0) }
            if status < 0 { return status }
            let items = append(category.items)
            if items < 0 { return items }
        }
        return rune_win_jump_commit(draft)
    }
}
#endif
