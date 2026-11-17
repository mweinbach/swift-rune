import Foundation
import RuneRef

/// The non-generic session retained by a mounted browser reactor.
@MainActor
final class WebBrowserSession {
    private struct Event: Decodable {
        var kind: String
        var key, code, pointerType, text, expected: String?
        var button: PointerButton?
        var base, anchor, focus: Int?
        var x, y: Float?
        var shift, ctrl, alt, cmd, field: Bool?
    }

    private struct FieldUpdate: Encodable {
        var field: WebFieldMirror?
        var activate: Bool
    }

    private var fieldUpdate: FieldUpdate?
    private var drawAfterInput = true
    private let route: (Event, Double) -> Bool
    private let paint: (Double, Bool) throws -> Frame?

    init<State>(_ host: WebAppHost<State>) {
        route = { event, now in
            let key = event.key ?? ""
            switch event.kind {
            case "key":
                var mods = Mods(shift: event.shift == true, ctrl: event.ctrl == true,
                                alt: event.alt == true, cmd: event.cmd == true, logo: event.cmd == true)
                #if os(WASI)
                // The portable editor uses Ctrl as its primary modifier. Browsers on macOS
                // report Command as Meta; map it to the same primary editor chord.
                if mods.logo && !mods.ctrl {
                    mods.ctrl = true
                    mods.logo = false
                }
                #endif
                return host.handleKeyDown(code: event.code ?? "", key: key, mods: mods, fromField: event.field == true, at: now)
            case "pointerdown", "pointerup", "pointermove":
                guard let x = event.x, let y = event.y else { return false }
                let phase: WebAppHost<State>.PointerPhase
                switch event.kind {
                case "pointerdown": phase = .down
                case "pointerup": phase = .up
                default: phase = .move
                }
                host.handlePointer(phase, x: x, y: y, button: event.button ?? .primary,
                                   pointerType: event.pointerType ?? "mouse", at: now)
                return true
            case "pointercancel":
                host.runtime.cancelPointerForTouchHold(at: now)
                return true
            case "insert":
                guard let text = event.text else { return false }
                return host.handleSecureFieldInsert(key: key, text: text, at: now)
            case "edit", "selection":
                guard let base = event.base, let expected = event.expected,
                      let anchor = event.anchor, let focus = event.focus else { return false }
                if event.kind == "edit" {
                    guard let text = event.text else { return false }
                    return host.handleFieldEdit(key: key, base: base, expected: expected, text: text,
                                                anchor: anchor, focus: focus, at: now)
                }
                return host.handleFieldSelection(key: key, base: base, expected: expected,
                                                 anchor: anchor, focus: focus, at: now)
            default: return false
            }
        }
        paint = { now, force in
            let rt = host.runtime
            guard force || MainQueueDispatcher.shared.pendingCount > 0 || rt.hasPendingCommit || rt.isAnimating || rt.livePending ||
                  rt.poll != nil || (rt.nextWakeDeadline.map { $0 <= now } ?? false) else { return nil }
            return try host.renderFrame(at: now)
        }
        currentField = { host.fieldMirror }
        host.onFieldChange = { [weak self] field, activate in
            self?.fieldUpdate = FieldUpdate(field: field, activate: activate)
        }
    }

    private let currentField: () -> WebFieldMirror?

    func send(_ json: Data, at now: Double) -> Bool {
        guard let event = try? JSONDecoder().decode(Event.self, from: json) else { return false }
        let handled = route(event, now)
        // A rejected or normalised native edit must put the model back into the DOM, even when
        // the framework's mirror has the exact same value as before the event.
        if event.kind == "edit" || event.kind == "selection" || event.kind == "insert", fieldUpdate == nil {
            fieldUpdate = FieldUpdate(field: currentField(), activate: false)
        }
        drawAfterInput = true
        return handled
    }

    func takeField() -> Data? {
        guard let update = fieldUpdate else { return nil }
        fieldUpdate = nil
        return try? JSONEncoder().encode(update)
    }

    func frame(at now: Double) throws -> Frame? {
        defer { drawAfterInput = false }
        return try paint(now, drawAfterInput)
    }
}

#if os(WASI)
/// Only the browser reactor enables a persistent session. The standard WASI command renders once.
@MainActor
enum RuneWebReactor {
    static var enabled = false
    static var session: WebBrowserSession?
    static var buffer: UnsafeMutableRawPointer?
    static var capacity = 0

    static func reserve(_ count: Int) -> UnsafeMutableRawPointer? {
        guard count >= 0 else { return nil }
        if count > capacity {
            buffer?.deallocate()
            buffer = .allocate(byteCount: count, alignment: MemoryLayout<UInt32>.alignment)
            capacity = count
        }
        return buffer
    }
}

@MainActor @_cdecl("rune_web_enable")
func runeWebEnable() { RuneWebReactor.enabled = true }

@MainActor @_cdecl("rune_web_buffer")
func runeWebBuffer(_ length: Int) -> UnsafeMutableRawPointer? { RuneWebReactor.reserve(length) }

@MainActor @_cdecl("rune_web_event")
func runeWebEvent(_ length: Int, _ time: Double) -> Int32 {
    guard length > 0, length <= RuneWebReactor.capacity, let bytes = RuneWebReactor.buffer,
          let session = RuneWebReactor.session else { return 0 }
    defer { bytes.initializeMemory(as: UInt8.self, repeating: 0, count: length) }
    return session.send(Data(bytes: bytes, count: length), at: time) ? 1 : 0
}

@MainActor @_cdecl("rune_web_field")
func runeWebField() -> Int {
    guard let data = RuneWebReactor.session?.takeField(), let bytes = RuneWebReactor.reserve(data.count) else { return 0 }
    data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: data.count)
    return data.count
}

@MainActor @_cdecl("rune_web_frame")
func runeWebFrame(_ time: Double) -> Int {
    guard let session = RuneWebReactor.session else { return -1 }
    do {
        guard let frame = try session.frame(at: time) else { return 0 }
        let length = 8 + frame.rgba.count
        guard let bytes = RuneWebReactor.reserve(length) else { return -1 }
        bytes.storeBytes(of: UInt32(frame.width).littleEndian, as: UInt32.self)
        bytes.storeBytes(of: UInt32(frame.height).littleEndian, toByteOffset: 4, as: UInt32.self)
        frame.rgba.withUnsafeBytes { source in
            if let base = source.baseAddress { (bytes + 8).copyMemory(from: base, byteCount: source.count) }
        }
        return length
    } catch {
        return -1
    }
}

@MainActor @_cdecl("rune_web_dispose")
func runeWebDispose() {
    RuneWebReactor.session = nil
    RuneWebReactor.enabled = false
    RuneWebReactor.buffer?.deallocate()
    RuneWebReactor.buffer = nil
    RuneWebReactor.capacity = 0
}
#endif
