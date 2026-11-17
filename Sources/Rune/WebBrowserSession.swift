import Foundation
import RuneRef

/// The non-generic session retained by a mounted browser reactor.
@MainActor
final class WebBrowserSession {
    private struct Event: Decodable {
        var kind: String
        var clipboard: WebClipboardContent?
        var key, code, pointerType, text, expected: String?
        var button: PointerButton?
        var base, anchor, focus: Int?
        var x, y, dx, dy, scale: Float?
        var repeated: Bool?
        var deltaMode: UInt32?
        var dark, reducedMotion, contrast, hover, coarse: Bool?
        var shift, ctrl, alt, cmd, field: Bool?
        var action: AccessibilityAction?
        var number: Double?
    }

    private struct FieldUpdate: Encodable {
        var field: WebFieldMirror?
        var activate: Bool
    }

    private var fieldUpdate: FieldUpdate?
    private var drawAfterInput = true
    private var gpuTracker: ResidentLayerTracker?
    private let route: (Event, Double) -> Bool
    private let shouldPaint: (Double) -> Bool
    private let textIdleReady: () -> Bool
    private let textIdleTurn: () -> Bool
    let cancelPreparedText: () -> Void
    private let paint: (Double) throws -> Frame
    private let paintGPU: (Double) throws -> RenderFrame
    let uiPasses: () -> Int
    let takeClipboard: () -> Data?
    let takeAccessibility: () -> Data?

    init<State>(_ host: WebAppHost<State>) {
        uiPasses = { host.uiPasses }
        textIdleReady = {
            let runtime = host.runtime
            return runtime.textIdleOwed && !runtime.hasPendingCommit && !runtime.livePending &&
                MainQueueDispatcher.shared.pendingCount == 0
        }
        textIdleTurn = { host.runtime.textIdleTurn() }
        cancelPreparedText = { host.runtime.cancelPreparedText() }
        let clipboard = WebClipboardSession(host)
        takeClipboard = clipboard.takeRequests
        let accessibility = WebAccessibilityProjection()
        takeAccessibility = { accessibility.update(host.runtime) }
        route = { event, now in
            let key = event.key ?? ""
            switch event.kind {
            case "clipboardCopy", "clipboardCut":
                return clipboard.copySelection(forCut: event.kind == "clipboardCut")
            case "clipboardCommitCut":
                return clipboard.finishCut(at: now)
            case "clipboardCancelCut":
                clipboard.cancelCut()
                return true
            case "clipboardPaste":
                guard let value = event.clipboard else { return false }
                return clipboard.paste(value, at: now)
            case "clipboardPrepareImagePaste":
                return clipboard.prepareImagePaste()
            case "clipboardReply":
                return clipboard.finishRead(key, value: event.clipboard)
            case "accessibility":
                guard let action = event.action, let path = event.key else { return false }
                let value = event.number.map(AccessibilityActionValue.number) ?? event.text.map(AccessibilityActionValue.text)
                let handled = host.runtime.accessibilityAction(path, action, value: value, at: now)
                if handled { host.syncField(activate: true) }
                return handled
            case "key", "keyup":
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
                return host.handleKey(code: event.code ?? "", key: key, mods: mods, fromField: event.field == true,
                                      pressed: event.kind == "key", repeated: event.repeated == true, at: now)
            case "focuslost":
                _ = host.runtime.physicalInput(.focusLost, at: now)
                return true
            case "pointerdown", "pointerup", "pointermove":
                guard let x = event.x, let y = event.y else { return false }
                let phase: WebAppHost<State>.PointerPhase
                switch event.kind {
                case "pointerdown": phase = .down
                case "pointerup": phase = .up
                default: phase = .move
                }
                host.handlePointer(phase, x: x, y: y, button: event.button ?? .primary,
                                   pointerType: event.pointerType ?? "mouse",
                                   mods: Mods(shift: event.shift == true, ctrl: event.ctrl == true, alt: event.alt == true,
                                              cmd: event.cmd == true, logo: event.cmd == true), at: now)
                return true
            case "preferences":
                guard let dark = event.dark, let motion = event.reducedMotion, let contrast = event.contrast,
                      let hover = event.hover, let coarse = event.coarse else { return false }
                host.updatePreferences(dark: dark, reducedMotion: motion, increasedContrast: contrast, hover: hover, coarse: coarse)
                return true
            case "resize":
                guard let width = event.x, let height = event.y, let scale = event.scale,
                      width > 0, height > 0, scale >= 0.5,
                      width * scale <= 16384, height * scale <= 16384 else { return false }
                return host.resize(cssSize: (width, height),
                                   reportedPixels: (UInt32((width * scale).rounded()), UInt32((height * scale).rounded())),
                                   scale: scale)
            case "wheel":
                guard let x = event.x, let y = event.y, let dx = event.dx, let dy = event.dy,
                      let mode = WebMath.WheelDeltaMode(rawValue: event.deltaMode ?? 0) else { return false }
                let delta = WebMath.normalizeWheelDelta(Vec2(dx, dy), mode: mode, pageHeightPx: host.runtime.viewport.y)
                // Native scrolling uses positive deltas towards the top of the content.
                if event.ctrl == true { return false } // Browser pinch-zoom.
                if host.config.webDocument && abs(delta.y) >= abs(delta.x) { return false }
                let mods = Mods(shift: event.shift == true, ctrl: false, alt: event.alt == true,
                                cmd: event.cmd == true, logo: event.cmd == true)
                host.runtime.hostInput(.wheel) {
                    host.runtime.wheel(WheelEvent(dx: -delta.x, dy: -delta.y, precise: mode == .pixel, mods: mods),
                                       at: Vec2(x, y), now: now)
                }
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
        shouldPaint = { now in
            let rt = host.runtime
            return host.compositor?.isAnimating == true || MainQueueDispatcher.shared.pendingCount > 0 || rt.hasPendingCommit || rt.isAnimating || rt.livePending ||
                rt.poll != nil || (rt.nextWakeDeadline(after: rt.currentTime).map { $0 <= now } ?? false)
        }
        paint = { try host.renderFrame(at: $0) }
        paintGPU = { try host.renderGPUFrame(at: $0) }
        currentField = { host.fieldMirror }
        host.onFieldChange = { [weak self] field, activate in
            self?.fieldUpdate = FieldUpdate(field: field, activate: activate)
        }
    }

    private let currentField: () -> WebFieldMirror?

    func requestPaint() { drawAfterInput = true }

    func idleText(perform: Bool) -> Bool {
        guard !drawAfterInput, textIdleReady() else { return false }
        return perform ? textIdleTurn() : true
    }

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

    func renderFrame(at now: Double, force: Bool = false) throws -> RenderFrame? {
        guard force || drawAfterInput || shouldPaint(now) else { return nil }
        drawAfterInput = false
        // The WebGL context can be restored between frames. Rebuild any subtree the old
        // texture cache had allowed the runtime to omit.
        if force { discardGPUCache() }
        let frame = try paintGPU(now).preparedForGL()
        if gpuTracker !== frame.residentTracker {
            discardGPUCache()
            gpuTracker = frame.residentTracker
            _ = gpuTracker?.acquire(for: self)
        }
        return frame
    }

    func publishCachedLayers(_ entries: [UInt64: UInt64]) {
        gpuTracker?.publish(entries, from: self)
    }

    func discardGPUCache() {
        gpuTracker?.release(self)
        gpuTracker = nil
    }

    func frame(at now: Double) throws -> Frame? {
        guard drawAfterInput || shouldPaint(now) else { return nil }
        drawAfterInput = false
        return try paint(now)
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
    static var lastGlyphGeneration: UInt64?
    static var lastImageRevision: UInt64?
    static var lastAtlasSizes: SIMD4<Int>?
    static var surfaceCache = WebSurfacePacket.Cache()
    static var atlasPatches = false
    static var atlasSequence: UInt32 = 0
    static var previousGlyphs: [UInt8]?
    static var previousImages: [UInt8]?

    static func report(_ error: any Error) -> Int {
        let reason = Data(String(describing: error).utf8)
        guard let bytes = reserve(reason.count) else { return -1 }
        reason.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: reason.count)
        return -reason.count - 1
    }

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
func runeWebEnable() {
    WASIBrowserExecutor.shared.install()
    RuneWebReactor.enabled = true
}

/// Older browser hosts consume the original full-atlas RSG2 packet layout.
@MainActor @_cdecl("rune_web_enable_atlas_patches")
func runeWebEnableAtlasPatches() { RuneWebReactor.atlasPatches = true }

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

@MainActor @_cdecl("rune_web_clipboard")
func runeWebClipboard() -> Int {
    guard let data = RuneWebReactor.session?.takeClipboard(), let bytes = RuneWebReactor.reserve(data.count) else { return 0 }
    data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: data.count)
    return data.count
}

@MainActor @_cdecl("rune_web_frame")
func runeWebFrame(_ time: Double) -> Int {
    WASIEventLoop.poll()
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
        return RuneWebReactor.report(error)
    }
}

/// The DOM host queries after presentation and performs one pass at browser idle priority.
@MainActor @_cdecl("rune_web_idle_text")
func runeWebIdleText(_ perform: Int32) -> Int32 {
    RuneWebReactor.session?.idleText(perform: perform != 0) == true ? 1 : 0
}

/// A nonzero force also reuploads the atlases after WebGL restores a lost context.
@MainActor @_cdecl("rune_web_scene")
func runeWebScene(_ time: Double, _ force: Int32) -> Int {
    WASIEventLoop.poll()
    guard let session = RuneWebReactor.session else { return -1 }
    do {
        guard let scene = try session.renderFrame(at: time, force: force != 0) else { return 0 }
        let sizes = SIMD4(scene.glyphs.width, scene.glyphs.height, scene.images.width, scene.images.height)
        let previous = RuneWebReactor.lastAtlasSizes
        let fullGlyphs = force != 0 || sizes.x != previous?.x || sizes.y != previous?.y
        let fullImages = force != 0 || sizes.z != previous?.z || sizes.w != previous?.w
        let changedGlyphs = scene.glyphGeneration != RuneWebReactor.lastGlyphGeneration
        let changedImages = scene.imageRevision != RuneWebReactor.lastImageRevision
        var glyphUpdate: WebAtlasUpdate = fullGlyphs || changedGlyphs ? .full : .none
        var imageUpdate: WebAtlasUpdate = fullImages || changedImages ? .full : .none
        var sequence: SIMD2<UInt32>?
        if RuneWebReactor.atlasPatches {
            if !fullGlyphs {
                glyphUpdate = .update(width: sizes.x, height: sizes.y, channels: 1, texels: scene.glyphs.texels,
                                      previous: RuneWebReactor.previousGlyphs, changed: changedGlyphs)
            }
            if !fullImages {
                let patch = scene.imagePatch
                let edges = patch?.fromRevision == RuneWebReactor.lastImageRevision ? patch?.edges : nil
                imageUpdate = .update(width: sizes.z, height: sizes.w, channels: 4, texels: scene.images.texels,
                                      previous: RuneWebReactor.previousImages, changed: changedImages, knownEdges: edges)
            }
            let base = RuneWebReactor.atlasSequence
            sequence = SIMD2(base, glyphUpdate == .none && imageUpdate == .none ? base : base &+ 1)
        }
        guard let packet = try WebScenePacket(scene: scene, glyphUpdate: glyphUpdate, imageUpdate: imageUpdate, sequence: sequence,
                surfaceCache: force != 0 ? .init() : RuneWebReactor.surfaceCache),
              let buffer = RuneWebReactor.reserve(packet.byteCount) else { return -1 }
        packet.write(to: buffer)
        RuneWebReactor.surfaceCache = packet.surfaces.next
        RuneWebReactor.lastGlyphGeneration = scene.glyphGeneration
        RuneWebReactor.lastImageRevision = scene.imageRevision
        RuneWebReactor.lastAtlasSizes = sizes
        if let sequence {
            RuneWebReactor.previousGlyphs = scene.glyphs.texels
            RuneWebReactor.previousImages = scene.images.texels
            RuneWebReactor.atlasSequence = sequence.y
        }
        return packet.byteCount
    } catch {
        return RuneWebReactor.report(error)
    }
}

/// Complete UI submissions requested for the last scene, including a compositor that hides the UI.
@MainActor @_cdecl("rune_web_ui_passes")
func runeWebUIPasses() -> Int { RuneWebReactor.session?.uiPasses() ?? 1 }

/// Publish textures still owned by the active WebGL context after the draw succeeds.
@MainActor @_cdecl("rune_web_cached_layers")
func runeWebCachedLayers(_ count: Int) {
    guard let session = RuneWebReactor.session, count >= 0, count <= RuneWebReactor.capacity / 16 else { return }
    var entries: [UInt64: UInt64] = [:]
    if count > 0, let buffer = RuneWebReactor.buffer {
        let words = buffer.assumingMemoryBound(to: UInt32.self)
        for index in 0..<count {
            let i = index * 4
            let key = UInt64(words[i]) | (UInt64(words[i + 1]) << 32)
            entries[key] = UInt64(words[i + 2]) | (UInt64(words[i + 3]) << 32)
        }
    }
    session.publishCachedLayers(entries)
}

@MainActor @_cdecl("rune_web_dispose")
func runeWebDispose() {
    RuneWebReactor.session?.cancelPreparedText()
    RuneWebReactor.session?.discardGPUCache()
    BrowserImageCodec.reset()
    WebSystemClipboard.shared.mount(false)
    WASIBrowserExecutor.shared.uninstall()
    WASIEventLoop.reset()
    RuneWebReactor.session = nil
    RuneWebReactor.enabled = false
    RuneWebReactor.lastGlyphGeneration = nil
    RuneWebReactor.lastImageRevision = nil
    RuneWebReactor.lastAtlasSizes = nil
    RuneWebReactor.previousGlyphs = nil
    RuneWebReactor.previousImages = nil
    RuneWebReactor.atlasSequence = 0
    RuneWebReactor.atlasPatches = false
    RuneWebReactor.surfaceCache = .init()
    RuneWebReactor.buffer?.deallocate()
    RuneWebReactor.buffer = nil
    RuneWebReactor.capacity = 0
}
#endif
