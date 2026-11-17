import Foundation
import RuneRef

/// The non-generic session retained by a mounted browser reactor.
@MainActor
final class WebBrowserSession {
    private struct Event: Decodable {
        var kind: String
        var id, token: String?
        var clipboard: WebClipboardContent?
        var key, code, pointerType, text, expected: String?
        var pointerId: Int32?
        var button: PointerButton?
        var base, anchor, focus: Int?
        var x, y, dx, dy, scale: Float?
        var insets: [Float]?
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
    private(set) var cpuCanvas: WebCPUCanvas?
    private let paintCPU: (Double, WebCPUCanvas?, Bool) throws -> WebCPUCanvas
    private var gpuTracker: ResidentLayerTracker?
    private let route: (Event, Double) -> Bool
    private let paintDelay: (Double) -> Double
    private let textIdleReady: () -> Bool
    private let textIdleTurn: () -> Bool
    let cancelPreparedText: () -> Void
    let waker: Waker
    let spellingChanged: () -> Void
    let fontsChanged: () -> Void
    private let paint: (Double) throws -> Frame
    private let paintGPU: (Double, Bool) throws -> RenderFrame
    let cycles: () -> (paint: CyclePaint?, sampled: Bool)
    let config: WebAppConfig
    let takeWindowTitle: () -> String?
    let takeWindowHeight: () -> Float?
    let pageMetrics: () -> SIMD3<Float>
    let fullWindow: Bool
    let uiPasses: () -> Int
    let takeCursor: () -> Data?
    let takePopup: () -> Data?
    let cancelPopups: () -> Void
    let secondaryClaim: () -> Data?
    let takeClipboard: () -> Data?
    let deferredAccessibility: () -> Int
    let enableAccessibilityPatches: () -> Void
    let takeAccessibility: () -> Data?

    init<State>(_ host: WebAppHost<State>) {
        waker = host.runtime.waker
        let config = host.config
        self.config = config
        var lastTitle: String?
        takeWindowTitle = {
            guard let title = host.runtime.windowTitle, title != lastTitle else { return nil }
            lastTitle = title
            return title
        }
        var firstFit = config.fitContentHeight && !config.webDocument
        takeWindowHeight = {
            let runtime = host.runtime
            let request = runtime.hasPendingWindowFrame ? runtime.takeWindowFrameRequest() : nil
            guard !config.webDocument else { return nil }
            defer { firstFit = false }
            if let height = request?.size?.1 { return height }
            // The browser has supplied the embedded canvas width before the first draw.
            return firstFit ? runtime.contentHeight() : nil
        }
        pageMetrics = { SIMD3(host.runtime.pageHeight, host.runtime.pageOffset, host.runtime.focusedPath == nil ? 0 : 1) }
        fullWindow = !config.webDocument && (config.canvasId == nil || (config.fullViewport && !config.fitContentHeight))
        uiPasses = { host.uiPasses }
        textIdleReady = {
            let runtime = host.runtime
            return runtime.textIdleOwed && !runtime.hasPendingCommit && !runtime.livePending &&
                MainQueueDispatcher.shared.pendingCount == 0
        }
        textIdleTurn = { host.runtime.textIdleTurn() }
        cancelPreparedText = { host.runtime.cancelPreparedText() }
        spellingChanged = { host.runtime.markNeedsCommit() }
        fontsChanged = {
            host.runtime.textSystem.invalidateWindowFontFaces()
            host.runtime.invalidateFontFamilyLayout(at: host.runtime.currentTime)
        }
        let popup = WebPopupSession(host)
        takePopup = popup.take
        secondaryClaim = popup.secondaryClaim
        cancelPopups = { host.runtime.cancelPopups() }
        let clipboard = WebClipboardSession(host)
        takeClipboard = clipboard.takeRequests
        var cursor = WebCursorProjection()
        takeCursor = { cursor.update(host.runtime.currentCursor()) }
        let accessibility = WebAccessibilityProjection()
        deferredAccessibility = { accessibility.deferredPull(host.runtime) }
        enableAccessibilityPatches = accessibility.enablePatches
        takeAccessibility = { accessibility.update(host.runtime) }
        route = { event, now in
            let key = event.key ?? ""
            switch event.kind {
            case "menu":
                return popup.answer(event.id, token: event.token)
            case "secondaryBrowser":
                host.runtime.secondaryAbandon()
                return false
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
                let handled = WebAccessibilityDocument(host.runtime)?.performLinkAction(path, action: action, at: now)
                    ?? host.runtime.accessibilityAction(path, action, value: value, at: now)
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
            case "pointerdown", "pointerup", "pointermove", "pointercancel":
                guard let x = event.x, let y = event.y else { return false }
                let phase: TouchPhase
                switch event.kind {
                case "pointerdown": phase = .started
                case "pointerup": phase = .ended
                case "pointercancel": phase = .cancelled
                default: phase = .moved
                }
                host.handlePointer(phase, x: x, y: y, button: event.button ?? .primary,
                                   pointerType: event.pointerType ?? "mouse",
                                   pointerID: UInt64(bitPattern: Int64(event.pointerId ?? 1)),
                                   mods: Mods(shift: event.shift == true, ctrl: event.ctrl == true, alt: event.alt == true,
                                              cmd: event.cmd == true, logo: event.cmd == true), at: now)
                return true
            case "preferences":
                guard let dark = event.dark, let motion = event.reducedMotion, let contrast = event.contrast,
                      let hover = event.hover, let coarse = event.coarse else { return false }
                host.updatePreferences(dark: dark, reducedMotion: motion, increasedContrast: contrast, hover: hover, coarse: coarse)
                return true
            case "pageScroll":
                guard host.config.webDocument, let y = event.y else { return false }
                let runtime = host.runtime
                let oldWindow = runtime.pageWindow.start
                let moved = runtime.setPageScroll(y, at: now)
                let delta = runtime.pageWindow.start - oldWindow
                let pointer = runtime.pointerPosition
                if delta != 0, !runtime.isTouching, pointer.x >= 0, pointer.y >= 0, pointer.y < runtime.viewport.y {
                    runtime.pointerMove(to: Vec2(pointer.x, pointer.y + delta), at: now)
                }
                return moved
            case "pageScrollX":
                guard host.config.webDocument, let path = event.key, let x = event.x else { return false }
                let moved = host.runtime.setPageScrollX(path, x: x)
                if moved, let offset = host.runtime.scrollOffsets[path], abs(offset.x - x) < 0.5 {
                    accessibility.acknowledgeDocumentScroll(path, x: offset.x)
                }
                return moved
            case "resize":
                guard let width = event.x, let height = event.y, let scale = event.scale,
                      width > 0, height > 0, scale >= 0.5,
                      width * scale <= 16384, height * scale <= 16384 else { return false }
                let resized = host.resize(cssSize: (width, height),
                                   reportedPixels: (UInt32((width * scale).rounded()), UInt32((height * scale).rounded())),
                                   scale: scale)
                var insetsChanged = false
                if let insets = event.insets, insets.count == 4 {
                    insetsChanged = host.runtime.setSafeAreaInsets(SIMD4(insets[0], insets[1], insets[2], insets[3]))
                }
                if host.config.webDocument, let view = event.dy {
                    return host.runtime.setPageBand(host.runtime.viewport.y, view: view) || resized || insetsChanged
                }
                return resized || insetsChanged
            case "wheel":
                guard let x = event.x, let y = event.y, let dx = event.dx, let dy = event.dy,
                      let mode = WebMath.WheelDeltaMode(rawValue: event.deltaMode ?? 0) else { return false }
                let delta = WebMath.normalizeWheelDelta(Vec2(dx, dy), mode: mode, pageHeightPx: host.runtime.viewport.y)
                // Native scrolling uses positive deltas towards the top of the content.
                if event.ctrl == true { return false } // Browser pinch-zoom.
                if (host.config.webDocument || host.config.fitContentHeight) && abs(delta.y) >= abs(delta.x) { return false }
                let mods = Mods(shift: event.shift == true, ctrl: false, alt: event.alt == true,
                                cmd: event.cmd == true, logo: event.cmd == true)
                host.runtime.hostInput(.wheel) {
                    host.runtime.wheel(WheelEvent(dx: -delta.x, dy: -delta.y, precise: mode == .pixel, mods: mods),
                                       at: Vec2(x, y), now: now)
                }
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
        paintDelay = { now in
            let rt = host.runtime
            if host.compositor?.isAnimating == true || MainQueueDispatcher.shared.pendingCount > 0 ||
                rt.hasPendingCommit || rt.isAnimating || rt.livePending { return 0 }
            let due = rt.wakeDeadline() ?? .infinity
            let delay = max(0, due - now)
            if delay <= CyclePaint.displayTolerance, host.recordedCyclePaint != nil,
               due == rt.activePaintedLoopWake, (rt.pollWakeDeadline() ?? .infinity) > due {
                return 0
            }
            return delay
        }
        paintCPU = { now, previous, force in
            let atlas = host.runtime.textSystem.glyphAtlas
            let canvas = previous ?? WebCPUCanvas(glyphAtlas: atlas)
            let start = atlas.outlineFillStats.elapsedNs
            let frame = try host.renderGPUFrame(at: now)
            try canvas.paint(frame, smoothing: host.runtime.fontSmoothing, compositor: host.compositor != nil,
                             force: force, fillNs: atlas.outlineFillStats.elapsedNs &- start)
            return canvas
        }
        paint = { try host.renderFrame(at: $0) }
        paintGPU = { try host.renderGPUFrame(at: $0, allowCycle: $1) }
        cycles = { (host.recordedCyclePaint, host.sampledCycleFrame) }
        currentField = { host.fieldMirror }
        host.onFieldChange = { [weak self] field, activate in
            self?.fieldUpdate = FieldUpdate(field: field, activate: activate)
        }
    }

    private let currentField: () -> WebFieldMirror?

    func requestPaint() { drawAfterInput = true }

    func nextDelay(at now: Double) -> Double { drawAfterInput ? 0 : paintDelay(now) }

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
        if handled || (event.kind != "pageScroll" && event.kind != "pageScrollX" && event.kind != "wheel") {
            drawAfterInput = true
        }
        return handled
    }

    func takeField() -> Data? {
        guard let update = fieldUpdate else { return nil }
        fieldUpdate = nil
        return try? JSONEncoder().encode(update)
    }

    func renderFrame(at now: Double, force: Bool = false) throws -> RenderFrame? {
        guard force || drawAfterInput || paintDelay(now) <= 0 else { return nil }
        cpuCanvas = nil
        let allowCycle = !force && !drawAfterInput
        drawAfterInput = false
        // The WebGL context can be restored between frames. Rebuild any subtree the old
        // texture cache had allowed the runtime to omit.
        if force { discardGPUCache() }
        let frame = try paintGPU(now, allowCycle)
        if gpuTracker !== frame.residentTracker {
            discardGPUCache()
            gpuTracker = frame.residentTracker
            _ = gpuTracker?.acquire(for: self)
        }
        return frame
    }

    func cpuFrame(at now: Double, force: Bool) throws -> WebCPUCanvas? {
        guard force || drawAfterInput || paintDelay(now) <= 0 else { return nil }
        drawAfterInput = false
        discardGPUCache()
        cpuCanvas = try paintCPU(now, cpuCanvas, force)
        return cpuCanvas
    }

    func publishCachedLayers(_ entries: [UInt64: UInt64]) {
        gpuTracker?.publish(entries, from: self)
    }

    func resetRenderer() {
        discardGPUCache()
        cpuCanvas = nil
        requestPaint()
    }

    func discardGPUCache() {
        gpuTracker?.release(self)
        gpuTracker = nil
    }

    func frame(at now: Double) throws -> Frame? {
        guard drawAfterInput || paintDelay(now) <= 0 else { return nil }
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
    static var surfaceCache = WebSurfacePacket.Cache()
    static var atlasPatches = false
    static var atlasHistory = WebAtlasHistory()
    static var cyclePatches = false
    static var supportsImagePages = false
    static var supportsGlyphPages = false

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

@MainActor @_cdecl("rune_web_enable_cycle_patches")
func runeWebEnableCyclePatches() { RuneWebReactor.cyclePatches = true }

/// Negotiates page-local glyph UVs and independently retained R8 textures in RSG3.
@MainActor @_cdecl("rune_web_enable_glyph_pages")
func runeWebEnableGlyphPages() {
    RuneWebReactor.supportsGlyphPages = true
    RuneWebReactor.supportsImagePages = true
    RuneWebReactor.atlasPatches = true
}

/// Enables the independent image textures in the RSG3 scene format.
@MainActor @_cdecl("rune_web_enable_image_pages")
func runeWebEnableImagePages() {
    RuneWebReactor.supportsImagePages = true
    RuneWebReactor.atlasPatches = true
}

/// A selected Hunspell dictionary finished fetching; previously unmarked fields recheck.
@MainActor @_cdecl("rune_web_spelling_changed")
func runeWebSpellingChanged() { RuneWebReactor.session?.spellingChanged() }

@MainActor @_cdecl("rune_web_fonts_changed")
func runeWebFontsChanged() {
    RuneWebReactor.session?.fontsChanged()
    RuneWebReactor.session?.requestPaint()
}

@MainActor @_cdecl("rune_web_config")
func runeWebConfig() -> Int {
    guard let config = RuneWebReactor.session?.config, let data = try? JSONEncoder().encode(config),
          let bytes = RuneWebReactor.reserve(data.count) else { return 0 }
    data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: data.count)
    return data.count
}

/// Returns a changed UTF-8 title length, including an empty title, or -1 when unchanged.
@MainActor @_cdecl("rune_web_window_title")
func runeWebWindowTitle() -> Int {
    guard let title = RuneWebReactor.session?.takeWindowTitle() else { return -1 }
    let data = Data(title.utf8)
    if !data.isEmpty {
        guard let bytes = RuneWebReactor.reserve(data.count) else { return -1 }
        data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: data.count)
    }
    return data.count
}

/// CSS height requested by the app, or -1 if the browser has no resize to apply.
@MainActor @_cdecl("rune_web_window_height")
func runeWebWindowHeight() -> Float { RuneWebReactor.session?.takeWindowHeight() ?? -1 }

/// Document height, rendered band offset and whether a Rune control owns keyboard navigation.
@MainActor @_cdecl("rune_web_page")
func runeWebPage() -> Int {
    guard let session = RuneWebReactor.session, session.config.webDocument, let bytes = RuneWebReactor.reserve(12) else { return 0 }
    let metrics = session.pageMetrics()
    for i in 0..<3 { bytes.storeBytes(of: metrics[i], toByteOffset: i * 4, as: Float.self) }
    return 12
}

@MainActor @_cdecl("rune_web_full_window")
func runeWebFullWindow() -> Int32 { RuneWebReactor.session?.fullWindow == true ? 1 : 0 }

/// Switching back to the CPU requires repainting subtrees the lost GPU had cached.
@MainActor @_cdecl("rune_web_reset_renderer")
func runeWebResetRenderer() {
    RuneWebReactor.session?.resetRenderer()
}

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

@MainActor @_cdecl("rune_web_cursor")
func runeWebCursor() -> Int {
    guard let data = RuneWebReactor.session?.takeCursor(), let bytes = RuneWebReactor.reserve(data.count) else { return 0 }
    data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: data.count)
    return data.count
}

@MainActor @_cdecl("rune_web_popup")
func runeWebPopup() -> Int {
    guard let data = RuneWebReactor.session?.takePopup(), let bytes = RuneWebReactor.reserve(data.count) else { return 0 }
    data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: data.count)
    return data.count
}

@MainActor @_cdecl("rune_web_secondary_claim")
func runeWebSecondaryClaim() -> Int {
    guard let data = RuneWebReactor.session?.secondaryClaim(), let bytes = RuneWebReactor.reserve(data.count) else { return 0 }
    data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: data.count)
    return data.count
}

@MainActor @_cdecl("rune_web_clipboard")
func runeWebClipboard() -> Int {
    guard let data = RuneWebReactor.session?.takeClipboard(), let bytes = RuneWebReactor.reserve(data.count) else { return 0 }
    data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: data.count)
    return data.count
}

/// Incremental CPU-first windows pull the rectangles and then copy each in bounded strips.
/// Older hosts can continue to request a complete reference frame via rune_web_frame.
@MainActor @_cdecl("rune_web_cpu_frame")
func runeWebCPUFrame(_ time: Double, _ force: Int32) -> Int {
    WASIEventLoop.poll()
    guard let session = RuneWebReactor.session else { return -1 }
    do {
        guard let canvas = try session.cpuFrame(at: time, force: force != 0) else { return 0 }
        guard let output = RuneWebReactor.reserve(canvas.byteCount) else { return -1 }
        canvas.writeHeader(to: output)
        return canvas.byteCount
    } catch {
        return RuneWebReactor.report(error)
    }
}

@MainActor @_cdecl("rune_web_cpu_rect")
func runeWebCPURect(_ index: Int, _ row: Int, _ count: Int) -> Int {
    RuneWebReactor.session?.cpuCanvas?.copyRGBA(rect: index, row: row, count: count, reserve: RuneWebReactor.reserve) ?? 0
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

/// Seconds until another display frame is needed. Infinity lets the browser sleep until woken.
@MainActor @_cdecl("rune_web_next_wake")
func runeWebNextWake(_ now: Double) -> Double {
    min(WASIEventLoop.nextDelay(), RuneWebReactor.session?.nextDelay(at: now) ?? .infinity)
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
        guard var scene = try session.renderFrame(at: time, force: force != 0) else { return 0 }
        if !RuneWebReactor.supportsGlyphPages && !scene.baseGlyphPages.isEmpty {
            scene = try scene.flattenedGlyphPages()
        }
        if !RuneWebReactor.supportsImagePages && !scene.imagePages.isEmpty {
            scene = try scene.packedForLegacyWebPacket()
        }
        let cycles = RuneWebReactor.cyclePatches ? session.cycles() : (paint: nil, sampled: false)
        if cycles.sampled, let paint = cycles.paint {
            let length = WebCyclePacket.size(slotCount: paint.slots.count)
            guard let buffer = RuneWebReactor.reserve(length) else { return -1 }
            WebCyclePacket.write(scene: scene, paint: paint, to: buffer)
            return length
        }
        let transfer = RuneWebReactor.atlasHistory.prepare(scene, force: force != 0, patches: RuneWebReactor.atlasPatches)
        guard let packet = try WebScenePacket(scene: scene, glyphUpdate: transfer.glyph, imageUpdate: transfer.image,
                sequence: transfer.sequence, pageUpdates: transfer.images, glyphTransfers: transfer.glyphs,
                surfaceCache: force != 0 ? .init() : RuneWebReactor.surfaceCache),
              let buffer = RuneWebReactor.reserve(packet.byteCount + (cycles.paint == nil ? 0 : 4)) else { return -1 }
        packet.write(to: buffer)
        RuneWebReactor.surfaceCache = packet.surfaces.next
        RuneWebReactor.atlasHistory.record(scene, transfer)
        if let paint = cycles.paint {
            WebCyclePacket.markFullPaint(buffer, byteCount: packet.byteCount, serial: paint.serial)
            return packet.byteCount + 4
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
    RuneWebReactor.session?.waker.setCallback {}
    RuneWebReactor.session?.cancelPopups()
    RuneWebReactor.session?.cancelPreparedText()
    RuneWebReactor.session?.discardGPUCache()
    BrowserImageCodec.reset()
    WebSystemClipboard.shared.mount(false)
    WASIBrowserExecutor.shared.uninstall()
    WASIEventLoop.reset()
    RuneWebReactor.session = nil
    RuneWebReactor.enabled = false
    RuneWebReactor.atlasPatches = false
    RuneWebReactor.atlasHistory = .init()
    RuneWebReactor.supportsImagePages = false
    RuneWebReactor.supportsGlyphPages = false
    RuneWebReactor.cyclePatches = false
    RuneWebReactor.surfaceCache = .init()
    RuneWebReactor.buffer?.deallocate()
    RuneWebReactor.buffer = nil
    RuneWebReactor.capacity = 0
}
#endif
