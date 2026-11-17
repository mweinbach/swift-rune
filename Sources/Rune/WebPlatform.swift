import Foundation
#if os(Android)
import Android
#endif
import RuneMotion
import RuneRef

#if os(WASI)
import WASILibc
#if RUNE_BROWSER_TEXT
import CRuneDesktopText
#endif
#endif

// MARK: - 1. Web Math (platform/web_math.rs)

/// Browser canvas sizing, surface reconfiguration, and wheel delta normalization (`rune::platform::web_math`).
public enum WebMath {
    /// CSS `WheelEvent.deltaMode` values.
    public enum WheelDeltaMode: UInt32, Sendable, Equatable {
        case pixel = 0
        case line = 1
        case page = 2
    }

    /// Computes the canvas's size in device pixels.
    ///
    /// Matches upstream `web_math::fix_canvas_size`: where `reported` disagrees with `css * scale`
    /// by more than `scale.ceil() + 1.0`, `css * scale` wins (unless `fitHeight` is true, in which
    /// case the app-measured height is preserved).
    public static func fixCanvasSize(
        css: (Float, Float),
        reported: (UInt32, UInt32),
        spec: (Float, Float),
        scale: Float,
        fitHeight: Bool
    ) -> (UInt32, UInt32) {
        let s = max(1e-3, scale)
        func want(_ v: Float) -> UInt32 {
            UInt32(max(1.0, (v * s).rounded()))
        }
        func fixed(_ got: UInt32, _ cssVal: Float) -> UInt32 {
            if cssVal > 0.0 && abs(Float(got) - Float(want(cssVal))) > ceil(s) + 1.0 {
                return want(cssVal)
            }
            return got
        }

        let (w, h) = css
        var size = reported
        if w > 0.0 {
            size.0 = fixed(size.0, w)
        }
        if !fitHeight && h > 0.0 {
            size.1 = fixed(size.1, h)
        }
        if size.0 == 0 {
            size.0 = w > 0.0 ? want(w) : want(spec.0)
        }
        if size.1 == 0 {
            size.1 = (!fitHeight && h > 0.0) ? want(h) : want(spec.1)
        }
        return size
    }

    /// Returns the next surface size and whether it needs reconfiguring.
    ///
    /// Matches upstream `web_math::should_reconfigure_surface`: a `document` page never shrinks its
    /// surface height alone (prevents mobile browser toolbar expand/collapse thrashing).
    public static func shouldReconfigureSurface(
        current: (UInt32, UInt32),
        next: (UInt32, UInt32),
        document: Bool
    ) -> ((UInt32, UInt32), Bool) {
        if next.0 == 0 || next.1 == 0 || next == current {
            return (current, false)
        }
        if document && next.0 == current.0 && next.1 < current.1 {
            return (current, false)
        }
        return (next, true)
    }

    /// Normalizes a DOM `WheelEvent` delta into logical CSS pixels.
    public static func normalizeWheelDelta(
        _ delta: Vec2,
        mode: WheelDeltaMode,
        lineHeightPx: Float = 20.0,
        pageHeightPx: Float = 800.0
    ) -> Vec2 {
        switch mode {
        case .pixel: return delta
        case .line: return Vec2(delta.x * lineHeightPx, delta.y * lineHeightPx)
        case .page: return Vec2(delta.x * pageHeightPx, delta.y * pageHeightPx)
        }
    }
}

// MARK: - 2. DOM KeyboardEvent Mapping (platform/web/input.rs)

/// Translates DOM `KeyboardEvent.code` / `KeyboardEvent.key` into `Rune.Key`.
public enum WebKeyMap {
    static func physical(_ code: String) -> PhysicalKeyCode? {
        switch code {
        case "MetaLeft", "OSLeft": return .superLeft
        case "MetaRight", "OSRight": return .superRight
        default:
            guard let first = code.first else { return nil }
            return PhysicalKeyCode(rawValue: first.lowercased() + code.dropFirst())
        }
    }

    public static func translate(code: String, key: String = "") -> Key? {
        switch code {
        case "Enter", "NumpadEnter": return .enter
        case "Tab": return .tab
        case "Escape": return .escape
        case "Backspace": return .backspace
        case "Delete": return .delete
        case "Space": return .space
        case "ArrowLeft": return .arrowLeft
        case "ArrowRight": return .arrowRight
        case "ArrowUp": return .arrowUp
        case "ArrowDown": return .arrowDown
        case "Home": return .home
        case "End": return .end
        case "PageUp": return .pageUp
        case "PageDown": return .pageDown
        default:
            if code.hasPrefix("F"), let num = UInt8(code.dropFirst()), (1...24).contains(num) {
                return .f(num)
            }
            if key.count == 1 {
                return .text(key)
            }
            return Key.named(key)
        }
    }
}

// MARK: - 3. Web App Configuration & Host Driver (app/web.rs & platform/web/)

/// Browser/WASI mounting configuration (`rune::app::web`).
public struct WebAppConfig: Sendable, Equatable, Encodable {
    public var canvasId: String?
    public var fullViewport: Bool
    public var webDocument: Bool
    public var fitContentHeight: Bool
    public var fontUrls: [String]
    public var lateFontUrls: [String]

    public init(
        canvasId: String? = nil,
        fullViewport: Bool = false,
        webDocument: Bool = false,
        fitContentHeight: Bool = false,
        fontUrls: [String] = [],
        lateFontUrls: [String] = []
    ) {
        self.canvasId = canvasId
        self.fullViewport = fullViewport
        self.webDocument = webDocument
        self.fitContentHeight = fitContentHeight || webDocument
        self.fontUrls = fontUrls
        self.lateFontUrls = lateFontUrls
    }
}

/// Browser text selection offsets are UTF-16 units relative to this slice. The base is
/// a UTF-8 byte offset in Rune's model. Secure fields never export model text.
public struct WebFieldMirror: Sendable, Equatable, Encodable {
    public let key: String
    public let text: String
    public let base: Int
    public let anchor: Int
    public let focus: Int
    public let secure: Bool
    public let label: String?
    /// The one-pixel browser input must expose hard lines to a screen reader.
    public let wrap = "off"

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && lhs.label == rhs.label && lhs.base == rhs.base && lhs.anchor == rhs.anchor
            && lhs.focus == rhs.focus && lhs.secure == rhs.secure && lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }

    internal init(key: String, edit: TextEdit, secure: Bool, label: String? = nil) {
        self.key = key
        self.label = label
        self.secure = secure
        if secure {
            text = ""
            base = 0
            anchor = 0
            focus = 0
            return
        }
        let value = edit.text
        let utf8 = value.utf8
        let scalars = value.unicodeScalars
        let a = utf8.index(utf8.startIndex, offsetBy: edit.anchor)
        let f = utf8.index(utf8.startIndex, offsetBy: edit.cursor)

        // The selection itself and at most 512 units on either side are always available.
        var head = min(a, f)
        var tail = max(a, f)
        var units = 0
        while head > scalars.startIndex {
            let prev = scalars.index(before: head)
            units += scalars[prev].utf16.count
            if units > 512 { break }
            head = prev
        }
        units = 0
        while tail < scalars.endIndex {
            units += scalars[tail].utf16.count
            if units > 512 { break }
            scalars.formIndex(after: &tail)
        }
        // Grow cut lines by up to 2048 additional units to a newline or document edge.
        var cursor = head
        units = 0
        while cursor > scalars.startIndex {
            let prev = scalars.index(before: cursor)
            if scalars[prev] == "\n" { break }
            units += scalars[prev].utf16.count
            if units > 2048 { break }
            cursor = prev
        }
        if units <= 2048 { head = cursor }
        cursor = tail
        units = 0
        while cursor < scalars.endIndex, scalars[cursor] != "\n" {
            units += scalars[cursor].utf16.count
            if units > 2048 { break }
            scalars.formIndex(after: &cursor)
        }
        if units <= 2048 { tail = cursor }
        text = String(decoding: utf8[head..<tail], as: UTF8.self)
        base = utf8.distance(from: utf8.startIndex, to: head)
        anchor = value.utf16.distance(from: head, to: a)
        focus = value.utf16.distance(from: head, to: f)
    }
}

/// Cross-platform WebAssembly/WASI event & frame driver (`rune::platform::web`).
@MainActor
public final class WebAppHost<State> {
    public let runtime: Runtime<State>
    private var appShared: AppShared<State>?
    private var gpuFrames = false
    private var cycleFrame: RenderFrame?
    private var cycleFrameSerial: UInt64 = 0
    private var cycleFrameCommit = 0
    private(set) var sampledCycleFrame = false
    var recordedCyclePaint: CyclePaint? { cycleFrame == nil ? nil : runtime.cyclePaint }
    private var compositorAllowsCyclePaint: Bool {
        compositor?.isAnimating != true && compositor?.drawsOwnContent != true
    }
    let compositor: AnyCompositor<State>?
    private let compositorDevice = DeviceKey.next()
    private var previousCompositorTime: Double?
    private(set) var uiPasses = 1
    private let followsSystemAppearance: Bool
    private let forceReducedMotion: Bool
    /// Receives field changes for the page's textarea or password input. An activating
    /// input event requests browser focus even if the mirrored value stayed the same.
    public var onFieldChange: ((WebFieldMirror?, _ activate: Bool) -> Void)?
    public private(set) var fieldMirror: WebFieldMirror?
    public let config: WebAppConfig
    public private(set) var surfaceSize: (UInt32, UInt32)
    public private(set) var devicePixelRatio: Float

    public convenience init(
        spec: AppSpec<State>,
        config: WebAppConfig = WebAppConfig(),
        viewport: Vec2? = nil,
        devicePixelRatio: Float = 1.0,
        dark: Bool? = nil,
        forceReducedMotion: Bool = false
    ) {
        let vp = viewport ?? spec.size
        let dpr = max(0.5, devicePixelRatio)
        HeadlessRunner.registerFonts(spec.fonts)
        let waker = Waker()
        spec.setup?(waker)
        let runtime = Runtime<State>(
            state: spec.makeState(),
            viewport: vp,
            pixelScale: dpr,
            systemDark: dark ?? spec.dark ?? true,
            reducedMotion: forceReducedMotion,
            waker: waker,
            onKey: spec.onKey,
            view: spec.view
        )
        runtime.windowTitle = spec.title
        runtime.srgbBlend = spec.srgbBlend
        runtime.poll = spec.poll
        runtime.onAppFileDrop = spec.onFileDrop
        runtime.onFileDrop = spec.onFileDropPhase
        self.init(runtime: runtime, compositor: nil, config: config, requestedSize: spec.size,
                  followsSystemAppearance: dark == nil && spec.dark == nil, forceReducedMotion: forceReducedMotion)
    }

    public convenience init(app: App<State>, viewport: Vec2? = nil, devicePixelRatio: Float = 1.0,
                            dark: Bool? = nil, forceReducedMotion: Bool = false, sceneName: String? = nil) {
        HeadlessRunner.registerFonts(app.fontData)
        let runtime = app.makeRuntime(viewport: viewport, pixelScale: max(0.5, devicePixelRatio),
                                      systemDark: dark, reducedMotion: forceReducedMotion, sceneName: sceneName)
        self.init(runtime: runtime, compositor: app.compositorValue, config: app.webAppConfig, requestedSize: app.size,
                  followsSystemAppearance: dark == nil && app.dark == nil, forceReducedMotion: forceReducedMotion)
        appShared = app.sharedHandle.shared
    }

    private init(runtime: Runtime<State>, compositor: AnyCompositor<State>?, config: WebAppConfig,
                 requestedSize: Vec2, followsSystemAppearance: Bool, forceReducedMotion: Bool) {
        self.runtime = runtime
        runtime.recordEvents = false
        self.compositor = compositor
        self.followsSystemAppearance = followsSystemAppearance
        self.forceReducedMotion = forceReducedMotion
        self.config = config
        if config.webDocument { runtime.pageMode() }
        else if config.fitContentHeight { runtime.fitHeight = true }
        let vp = runtime.viewport
        let dpr = runtime.pixelScale
        self.devicePixelRatio = dpr
        self.surfaceSize = WebMath.fixCanvasSize(
            css: (vp.x, vp.y),
            reported: (UInt32((vp.x * dpr).rounded()), UInt32((vp.y * dpr).rounded())),
            spec: (requestedSize.x, requestedSize.y),
            scale: dpr,
            fitHeight: config.fitContentHeight
        )
        // The capture presets as `tooling::runtime_for` applies them (#981); a browser has no machine settings to read here.
        self.runtime.applyCapturePresets()
    }

    @discardableResult
    public func resize(cssSize: (Float, Float), reportedPixels: (UInt32, UInt32), scale: Float) -> Bool {
        let nextScale = max(0.5, scale)
        let scaleChanged = devicePixelRatio != nextScale
        devicePixelRatio = nextScale
        let fixed = WebMath.fixCanvasSize(
            css: cssSize,
            reported: reportedPixels,
            spec: (runtime.viewport.x, runtime.viewport.y),
            scale: devicePixelRatio,
            fitHeight: config.fitContentHeight
        )
        let (nextSize, shouldReconfig) = WebMath.shouldReconfigureSurface(
            current: surfaceSize,
            next: fixed,
            document: config.webDocument
        )
        surfaceSize = nextSize
        // The GPU may retain a taller backing allocation across mobile toolbar movement.
        // Layout, hit testing and the band still use the canvas's measured CSS size.
        let layoutSize = config.webDocument ? fixed : nextSize
        let points = Vec2(Float(layoutSize.0) / devicePixelRatio, Float(layoutSize.1) / devicePixelRatio)
        let layoutChanged = runtime.viewport != points
        if shouldReconfig || scaleChanged || layoutChanged {
            if config.webDocument {
                runtime.setViewport(points, pixelScale: devicePixelRatio)
            } else {
                runtime.setWindowViewport(points, pixelScale: devicePixelRatio)
            }
        }
        return shouldReconfig || scaleChanged || layoutChanged
    }

    func syncField(activate: Bool) {
        let next = runtime.focusedPath.flatMap { path -> WebFieldMirror? in
            guard let el = runtime.focusedInputElement(at: path), el.hasEditAccess,
                  let lens = el.handlers.editLens else { return nil }
            let edit = lens.get(runtime.state)
            return WebFieldMirror(key: path, edit: edit, secure: el.isSecure || edit.isSecure,
                                  label: el.a11yLabel ?? el.placeholder)
        }
        if next != fieldMirror || (activate && next != nil) {
            fieldMirror = next
            onFieldChange?(next, activate)
        }
    }

    public func renderScene(at now: Double) -> RefScene {
        cycleFrame = nil
        _ = MainQueueDispatcher.shared.drain()
        appShared?.applyStateUpdates(to: runtime, at: now)
        let scene = runtime.frame(at: now)
        syncField(activate: false)
        return scene
    }

    private func compose(at now: Double, started: Double, width: Int, height: Int) throws {
        guard let compositor else { return }
        guard !compositor.features.contains(.requiresMetal) else { throw CompositorError.nativeCompositorInBrowser }
        let dt = Float(max(0, now - (previousCompositorTime ?? now)))
        previousCompositorTime = now
        var passes = 0
        let frame = CompositorFrame(deviceKey: compositorDevice, pixelSize: (width, height), dt: dt,
                                    updateMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000,
                                    srgbBlend: runtime.srgbBlend, runtime: runtime, drawUI: { passes += 1 })
        // The browser executes each requested UI pass and calls the JS drawEffect for its effect slots.
        frame.drawUIWithEffects = { _ in throw CompositorError.nativeCompositorInBrowser }
        defer { frame.endFrame() }
        compositor.render(frame: frame)
        if passes == 0 && !compositor.drawsOwnContent { frame.drawUI() }
        uiPasses = passes
    }

    func renderGPUFrame(at now: Double, allowCycle: Bool = false) throws -> RenderFrame {
        gpuFrames = true
        sampledCycleFrame = false
        let drained = MainQueueDispatcher.shared.drain()
        let sharedWork = appShared?.applyStateUpdates(to: runtime, at: now)
        if allowCycle, drained == 0, sharedWork?.isEmpty != false, compositorAllowsCyclePaint, cycleFrame != nil,
           runtime.paintCycleTick(frame: &cycleFrame!, serial: cycleFrameSerial, commit: cycleFrameCommit, at: now) {
            sampledCycleFrame = true
            if compositor != nil {
                try compose(at: now, started: ProcessInfo.processInfo.systemUptime,
                            width: cycleFrame!.width, height: cycleFrame!.height)
            }
            return cycleFrame!
        }
        cycleFrame = nil
        let started = ProcessInfo.processInfo.systemUptime
        var frame = runtime.renderFrame(at: now)
        syncField(activate: false)
        try compose(at: now, started: started, width: frame.width, height: frame.height)
        if uiPasses == 0 {
            frame.instances = []
            frame.marks = []
            frame.surfaces = []
            frame.materials = []
            frame.elidedLayers = []
            frame.residentTracker = nil
        }
        try frame.validateForGL()
        if compositorAllowsCyclePaint, runtime.cyclePaint.interval != nil, runtime.restsExceptLoop(),
           !runtime.hasOtherPaintDeadline, !runtime.isTracing, runtime.rewindRecorder == nil,
           runtime.cyclePaint.slots.count == runtime.loopRuntime.tracks.count,
           frame.elidedLayers.isEmpty, frame.surfaces.isEmpty {
            cycleFrame = frame
            cycleFrameSerial = runtime.cyclePaint.serial
            cycleFrameCommit = runtime.viewCommitCount
        }
        return frame
    }

    public func renderFrame(at now: Double) throws -> Frame {
        gpuFrames = false
        let started = ProcessInfo.processInfo.systemUptime
        var scene = renderScene(at: now)
        try compose(at: now, started: started, width: scene.width, height: scene.height)
        if uiPasses == 0 {
            scene.primitives = []
            return try RuneRef.render(scene)
        }
        let surfaces = try NativeSurfaceReference.capture(runtime.surfaces, srgbBlend: runtime.srgbBlend)
        return try RuneRef.render(scene, surfaces: surfaces)
    }

    /// A shortcut can mount a field and request focus in one transaction. Apply that frame
    /// while the browser still grants keyboard/IME activation for the originating event.
    private func finishActivation(at now: Double) {
        if gpuFrames { _ = runtime.renderFrame(at: now) }
        else { _ = runtime.frame(at: now) }
        syncField(activate: true)
    }

    public func handleKeyDown(code: String, key: String, mods: Mods = .none, at now: Double) -> Bool {
        handleKeyDown(code: code, key: key, mods: mods, fromField: false, at: now)
    }

    func handleKeyDown(code: String, key: String, mods: Mods, fromField: Bool, at now: Double) -> Bool {
        handleKey(code: code, key: key, mods: mods, fromField: fromField, pressed: true, repeated: false, at: now)
    }

    func handleKey(code: String, key: String, mods: Mods, fromField: Bool,
                   pressed: Bool, repeated: Bool, at now: Double) -> Bool {
        defer { if pressed { finishActivation(at: now) } }
        func dispatch() -> Bool {
            var mapped = WebKeyMap.translate(code: code, key: key)
            if mods.ctrl || mods.cmd, case .text(let value) = mapped, let letter = value.lowercased().first {
                mapped = .command(letter)
            }
            let fallback = mapped.map { KeyEvent(key: $0, mods: mods) }
            if !fromField, let physical = WebKeyMap.physical(code) {
                return runtime.physicalInput(.key(key: physical, mods: mods, pressed: pressed, repeat: repeated),
                                             fallbackKey: fallback, at: now)
            }
            guard let fallback else { return false }
            return pressed ? runtime.keyDown(fallback, isRepeat: repeated, at: now) : runtime.keyUp(fallback, at: now)
        }
        if fromField {
            // The page's own key event counts as typing; winit supplies arrival scopes for canvas keys.
            InputTime.noteDispatched()
            return dispatch()
        }
        return runtime.hostInput(pressed ? .keyPress : .keyRelease, dispatch)
    }

    func handlePointer(_ phase: TouchPhase, x: Float, y: Float, button: PointerButton,
                       pointerType: String, pointerID: UInt64 = 1, mods: Mods = .none, at now: Double) {
        let point = Vec2(x, y)
        if pointerType == "touch" {
            runtime.touch(id: pointerID, phase: phase, at: point, time: now)
            if phase == .ended { finishActivation(at: now) }
            return
        }
        guard !runtime.touching(), phase != .cancelled else { return }
        runtime.hostInput(.pointer) {
            switch phase {
            case .started where button == .secondary: runtime.secondaryDown(at: point, at: now)
            case .ended where button == .secondary: runtime.secondaryUp(at: point, mods: mods, at: now)
            case .started: runtime.pressDown(at: point, button: button, mods: mods, at: now, mouse: true)
            case .moved: runtime.pointerMove(to: point, mods: mods, at: now)
            case .ended: runtime.pointerUp(at: point, button: button, mods: mods, at: now)
            case .cancelled: break
            }
        }
        if phase != .moved { finishActivation(at: now) }
    }

    public func handlePointerMove(x: Float, y: Float, at now: Double) {
        handlePointer(.moved, x: x, y: y, button: .primary,
                      pointerType: runtime.touching() ? "touch" : "mouse", at: now)
    }

    public func handlePointerDown(x: Float, y: Float, button: PointerButton = .primary, at now: Double) {
        handlePointer(.started, x: x, y: y, button: button,
                      pointerType: runtime.touchControls() && button == .primary ? "touch" : "mouse", at: now)
    }

    /// The event's DOM pointerType distinguishes the active device on hybrid mouse/touch systems.
    public func handlePointerDown(x: Float, y: Float, button: PointerButton = .primary, pointerType: String, at now: Double) {
        handlePointer(.started, x: x, y: y, button: button, pointerType: pointerType, at: now)
    }

    public func handlePointerUp(x: Float, y: Float, button: PointerButton = .primary, at now: Double) {
        handlePointer(.ended, x: x, y: y, button: button,
                      pointerType: runtime.touching() ? "touch" : "mouse", at: now)
    }

    func updatePreferences(dark: Bool, reducedMotion: Bool, increasedContrast: Bool, hover: Bool, coarse: Bool) {
        if followsSystemAppearance { runtime.systemDark = dark }
        runtime.setSystemReducedMotion(forceReducedMotion || reducedMotion)
        runtime.setSystemIncreasedContrast(increasedContrast)
        _ = handlePrimaryPointer(hover: hover, coarse: coarse)
    }

    @discardableResult
    public func handlePrimaryPointer(hover: Bool, coarse: Bool) -> Bool {
        runtime.setWebPointerCapability(hover: hover, coarse: coarse)
    }
}

#if os(WASI)
/// WebAssembly/WASI application host called by `RuneApp.run(spec)`.
public enum WebApp {
    /// Fetches a TrueType or OpenType face once the first frame is presented. Relative URLs use the page URL.
    public static func fontUrlNow(_ url: String) {
        #if RUNE_BROWSER_TEXT
        rune_browser_font_url(url, 1)
        #endif
    }

    @MainActor
    public static func run<State>(_ spec: AppSpec<State>, parsed: ToolingArgs) throws {
        let vp = parsed.viewportOverride ?? spec.size
        let host = WebAppHost(
            spec: spec,
            viewport: vp,
            devicePixelRatio: 1.0,
            dark: parsed.darkOverride ?? spec.dark,
            forceReducedMotion: parsed.reducedMotion
        )
        try run(host)
    }

    @MainActor
    public static func run<State>(_ app: App<State>, parsed: ToolingArgs) throws {
        try run(WebAppHost(app: app, viewport: parsed.viewportOverride, dark: parsed.darkOverride,
                           forceReducedMotion: parsed.reducedMotion, sceneName: parsed.sceneName))
    }

    @MainActor
    private static func run<State>(_ host: WebAppHost<State>) throws {
        if RuneWebReactor.enabled {
            RuneWebReactor.session = WebBrowserSession(host)
            host.runtime.waker.setCallback { WASIEventLoop.wakeApp() }
            #if RUNE_BROWSER_TEXT
            for url in host.config.fontUrls { rune_browser_font_url(url, 0) }
            for url in host.config.lateFontUrls { fontUrlNow(url) }
            #endif
        } else {
            _ = try host.renderFrame(at: 0.0)
        }
        ReadySignal.ready()
    }
}
#endif
