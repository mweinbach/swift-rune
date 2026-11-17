import Foundation
import RuneMotion
import RuneRef

#if os(WASI)
import WASILibc
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
public struct WebAppConfig: Sendable, Equatable {
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

/// Cross-platform WebAssembly/WASI event & frame driver (`rune::platform::web`).
@MainActor
public final class WebAppHost<State> {
    public let runtime: Runtime<State>
    public let config: WebAppConfig
    public private(set) var surfaceSize: (UInt32, UInt32)
    public private(set) var devicePixelRatio: Float

    public init(
        spec: AppSpec<State>,
        config: WebAppConfig = WebAppConfig(),
        viewport: Vec2? = nil,
        devicePixelRatio: Float = 1.0,
        dark: Bool? = nil
    ) {
        let vp = viewport ?? spec.size
        let dpr = max(0.5, devicePixelRatio)
        self.config = config
        self.devicePixelRatio = dpr
        self.surfaceSize = WebMath.fixCanvasSize(
            css: (vp.x, vp.y),
            reported: (UInt32((vp.x * dpr).rounded()), UInt32((vp.y * dpr).rounded())),
            spec: (spec.size.x, spec.size.y),
            scale: dpr,
            fitHeight: config.fitContentHeight
        )
        HeadlessRunner.registerFonts(spec.fonts)
        let waker = Waker()
        spec.setup?(waker)
        self.runtime = Runtime<State>(
            state: spec.makeState(),
            viewport: vp,
            pixelScale: dpr,
            systemDark: dark ?? spec.dark ?? true,
            reducedMotion: false,
            waker: waker,
            onKey: spec.onKey,
            view: spec.view
        )
        self.runtime.windowTitle = spec.title
        self.runtime.srgbBlend = spec.srgbBlend
        self.runtime.poll = spec.poll
        self.runtime.onAppFileDrop = spec.onFileDrop
        self.runtime.onFileDrop = spec.onFileDropPhase
        // The capture presets as `tooling::runtime_for` applies them (#981); a browser has no machine settings to read here.
        self.runtime.applyCapturePresets()
    }

    @discardableResult
    public func resize(cssSize: (Float, Float), reportedPixels: (UInt32, UInt32), scale: Float) -> Bool {
        devicePixelRatio = max(0.5, scale)
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
        if shouldReconfig {
            surfaceSize = nextSize
            runtime.pixelScale = devicePixelRatio
            runtime.viewport = Vec2(Float(nextSize.0) / devicePixelRatio, Float(nextSize.1) / devicePixelRatio)
        }
        return shouldReconfig
    }

    public func renderFrame(at now: Double) throws -> Frame {
        _ = MainQueueDispatcher.shared.drain()
        let scene = runtime.frame(at: now)
        return try RuneRef.render(scene)
    }

    public func handleKeyDown(code: String, key: String, mods: Mods = .none, at now: Double) -> Bool {
        guard let mapped = WebKeyMap.translate(code: code, key: key) else { return false }
        return runtime.keyDown(KeyEvent(key: mapped, mods: mods), at: now)
    }

    public func handlePointerMove(x: Float, y: Float, at now: Double) {
        runtime.pointerMove(to: Vec2(x, y), mods: .none, at: now)
    }

    public func handlePointerDown(x: Float, y: Float, button: PointerButton = .primary, at now: Double) {
        runtime.pressDown(at: Vec2(x, y), button: button, at: now, mouse: !runtime.touchControls())
    }

    /// The event's DOM pointerType distinguishes the active device on hybrid mouse/touch systems.
    public func handlePointerDown(x: Float, y: Float, button: PointerButton = .primary, pointerType: String, at now: Double) {
        runtime.pressDown(at: Vec2(x, y), button: button, at: now, mouse: pointerType == "mouse")
    }

    public func handlePointerUp(x: Float, y: Float, button: PointerButton = .primary, at now: Double) {
        runtime.pointerUp(at: Vec2(x, y), button: button, mods: .none, at: now)
    }

    @discardableResult
    public func handlePrimaryPointer(hover: Bool, coarse: Bool) -> Bool {
        runtime.setWebPointerCapability(hover: hover, coarse: coarse)
    }
}

#if os(WASI)
/// WebAssembly/WASI application host called by `RuneApp.run(spec)`.
public enum WebApp {
    @MainActor
    public static func run<State>(_ spec: AppSpec<State>, parsed: ToolingArgs) throws {
        let vp = parsed.viewportOverride ?? spec.size
        let host = WebAppHost(
            spec: spec,
            viewport: vp,
            devicePixelRatio: 1.0,
            dark: parsed.darkOverride ?? spec.dark
        )
        _ = try host.renderFrame(at: 0.0)
        ReadySignal.ready()
    }
}
#endif
