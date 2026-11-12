import Foundation
import RuneMotion
import RuneRef
#if canImport(simd)
import simd
#endif
#if canImport(CoreText)
import CoreText
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Declarative application specification (`rune::App<State>`).
public struct AppSpec<State> {
    public var title: String
    public var size: Vec2
    public var minSize: Vec2?
    public var dark: Bool?
    public var srgbBlend: Bool
    public var makeState: () -> State
    /// Named scene presets invokable via `--scene <name>` for instant visual QA snapshots.
    public var scenes: [String: (inout State, inout Tx) -> Void]
    public var fonts: [Data]
    public var families: [String]
    public var setup: ((Waker) -> Void)?
    public var poll: ((inout State, Double, inout Tx) -> Bool)?
    public var onKey: ((inout State, KeyEvent, inout Tx) -> Bool)?
    public var view: (State, inout Cx<State>) -> El<State>

    public init(
        title: String = "Rune",
        size: Vec2 = Vec2(800, 600),
        minSize: Vec2? = nil,
        dark: Bool? = nil,
        srgbBlend: Bool = true,
        state: @autoclosure @escaping () -> State,
        scenes: [String: (inout State, inout Tx) -> Void] = [:],
        fonts: [Data] = [],
        families: [String] = [],
        setup: ((Waker) -> Void)? = nil,
        poll: ((inout State, Double, inout Tx) -> Bool)? = nil,
        onKey: ((inout State, KeyEvent, inout Tx) -> Bool)? = nil,
        view: @escaping (State, inout Cx<State>) -> El<State>
    ) {
        self.title = title
        self.size = size
        self.minSize = minSize
        self.dark = dark
        self.srgbBlend = srgbBlend
        self.makeState = state
        self.scenes = scenes
        self.fonts = fonts
        self.families = families
        self.setup = setup
        self.poll = poll
        self.onKey = onKey
        self.view = view
    }

    public func scene(_ name: String, _ apply: @escaping (inout State) -> Void) -> Self {
        var copy = self
        copy.scenes[name] = { s, _ in apply(&s) }
        return copy
    }

    public func scene(_ name: String, _ apply: @escaping (inout State, inout Tx) -> Void) -> Self {
        var copy = self
        copy.scenes[name] = apply
        return copy
    }

    public func srgbBlend(_ enabled: Bool) -> Self {
        var copy = self
        copy.srgbBlend = enabled
        return copy
    }

    public func font(_ data: Data) -> Self {
        var copy = self
        copy.fonts.append(data)
        return copy
    }

    public func fonts(_ data: [Data]) -> Self {
        var copy = self
        copy.fonts.append(contentsOf: data)
        return copy
    }

    public func family(_ name: String) -> Self {
        var copy = self
        copy.families.append(name)
        return copy
    }

    public func families(_ names: [String]) -> Self {
        var copy = self
        copy.families.append(contentsOf: names)
        return copy
    }

    public func setup(_ hook: @escaping (Waker) -> Void) -> Self {
        var copy = self
        copy.setup = hook
        return copy
    }

    public func poll(_ hook: @escaping (inout State, Double, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.poll = hook
        return copy
    }
}

/// Parsed headless CLI arguments (`rune::tooling::Args`).
public struct ToolingArgs: Sendable, Equatable {
    public var snapPath: String? = nil
    public var treePath: String? = nil
    public var sceneName: String? = nil
    public var scriptArg: String? = nil
    public var framesDir: String? = nil
    public var stripPath: String? = nil
    public var fps: Double = 60.0
    public var pixelScale: Float = 2.0
    public var viewportOverride: Vec2? = nil
    public var darkOverride: Bool? = nil
    public var reducedMotion: Bool = false
    public var timeScale: Double = 1.0
    public var forceCPU: Bool = false
    public var durationOverride: Double? = nil
    public var atTime: Double? = nil
    public var startTime: Double = 0.0
    public var cropKey: String? = nil
    public var stripEvery: Int? = nil
    public var listScenes: Bool = false

    public init() {}

    public var isHeadlessRequested: Bool {
        snapPath != nil || treePath != nil || scriptArg != nil || framesDir != nil || stripPath != nil || listScenes
    }

    public static func parse(_ arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> ToolingArgs {
        var out = ToolingArgs()
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--snap":
                if i + 1 < arguments.count { out.snapPath = arguments[i + 1]; i += 1 }
            case "--tree":
                if i + 1 < arguments.count { out.treePath = arguments[i + 1]; i += 1 }
            case "--scene":
                if i + 1 < arguments.count { out.sceneName = arguments[i + 1]; i += 1 }
            case "--script":
                if i + 1 < arguments.count { out.scriptArg = arguments[i + 1]; i += 1 }
            case "--frames":
                if i + 1 < arguments.count { out.framesDir = arguments[i + 1]; i += 1 }
            case "--strip":
                if i + 1 < arguments.count { out.stripPath = arguments[i + 1]; i += 1 }
            case "--fps":
                if i + 1 < arguments.count, let v = Double(arguments[i + 1]) { out.fps = max(1, v); i += 1 }
            case "--scale":
                if i + 1 < arguments.count, let v = Float(arguments[i + 1]) { out.pixelScale = max(0.5, v); i += 1 }
            case "--time-scale":
                if i + 1 < arguments.count, let v = Double(arguments[i + 1]) { out.timeScale = max(0.01, v); i += 1 }
            case "--duration":
                if i + 1 < arguments.count, let v = Double(arguments[i + 1]) { out.durationOverride = max(0, v); i += 1 }
            case "--at":
                if i + 1 < arguments.count, let v = Double(arguments[i + 1]) { out.atTime = max(0, v); i += 1 }
            case "--start":
                if i + 1 < arguments.count, let v = Double(arguments[i + 1]) { out.startTime = max(0, v); i += 1 }
            case "--crop":
                if i + 1 < arguments.count { out.cropKey = arguments[i + 1]; i += 1 }
            case "--every":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { out.stripEvery = max(1, v); i += 1 }
            case "--list-scenes":
                out.listScenes = true
            case "--theme":
                if i + 1 < arguments.count {
                    let t = arguments[i + 1].lowercased()
                    if t == "dark" { out.darkOverride = true }
                    else if t == "light" { out.darkOverride = false }
                    i += 1
                }
            case "--size":
                if i + 1 < arguments.count {
                    let parts = arguments[i + 1].lowercased().split(separator: "x")
                    if parts.count == 2, let w = Float(parts[0]), let h = Float(parts[1]) {
                        out.viewportOverride = Vec2(max(1, w), max(1, h))
                    }
                    i += 1
                }
            case "--dark":
                out.darkOverride = true
            case "--light":
                out.darkOverride = false
            case "--reduced-motion":
                out.reducedMotion = true
            case "--cpu":
                out.forceCPU = true
            default:
                break
            }
            i += 1
        }
        return out
    }
}

/// Synthetic input event parsed from `--script` JSON.
public struct ScriptStep: Sendable {
    public enum Position: Sendable {
        case key(String)
        case xy(Float, Float)
        case relative(Float, Float)
    }

    public enum Action: Sendable {
        case move
        case down(PointerButton, Mods)
        case up(PointerButton, Mods)
        case keyDown(KeyEvent)
        case shortcut(Chord)
        case paste(ClipboardContent)
        case wheel(WheelEvent)
        case fling(vx: Float, vy: Float)
        case resize(Vec2)
        case windowFocus(Bool)
    }

    public var t: Double
    public var position: Position
    public var action: Action
}

/// Headless virtual-clock runner for `--snap`, `--tree`, `--script`, `--frames`, and `--strip`.
public enum HeadlessRunner {
    public struct Output: Sendable {
        public var finalFrame: Frame
        public var treeJSON: Data
    }

    /// Parses a `--script` JSON array (or `{"events": [...]}` object) into sorted `ScriptStep`s.
    public static func parseScript(jsonData: Data) throws -> [ScriptStep] {
        let raw = try JSONSerialization.jsonObject(with: jsonData, options: [])
        let items: [[String: Any]]
        if let arr = raw as? [[String: Any]] {
            items = arr
        } else if let dict = raw as? [String: Any], let arr = dict["events"] as? [[String: Any]] {
            items = arr
        } else {
            throw CocoaError(.coderReadCorrupt)
        }

        var out: [ScriptStep] = []
        for e in items {
            let t = (e["t"] as? NSNumber)?.doubleValue ?? 0.0

            if let focused = e["focus"] as? Bool {
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .windowFocus(focused)))
                continue
            }
            if let shortcutStr = e["shortcut"] as? String, let chord = Chord(parsing: shortcutStr) {
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .shortcut(chord)))
                continue
            }
            if let pasteStr = e["paste"] as? String {
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .paste(ClipboardContent(pasteStr))))
                continue
            } else if let pasteObj = e["paste"] as? [String: Any] {
                let txt = (pasteObj["text"] as? String) ?? ""
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .paste(ClipboardContent(txt))))
                continue
            }

            let pos: ScriptStep.Position
            if let k = e["key"] as? String {
                pos = .key(k)
            } else if let x = (e["x"] as? NSNumber)?.floatValue, let y = (e["y"] as? NSNumber)?.floatValue {
                pos = .xy(x, y)
            } else {
                pos = .relative(0, 0)
            }

            let mods = Mods(
                shift: (e["shift"] as? Bool) ?? false,
                ctrl: (e["ctrl"] as? Bool) ?? false,
                alt: (e["alt"] as? Bool) ?? false,
                cmd: (e["cmd"] as? Bool) ?? false,
                logo: (e["logo"] as? Bool) ?? false
            )
            let button = PointerButton(rawValue: (e["button"] as? String) ?? "primary") ?? .primary
            let ty = (e["type"] as? String) ?? "tap"

            switch ty {
            case "move":
                out.append(ScriptStep(t: t, position: pos, action: .move))

            case "down":
                out.append(ScriptStep(t: t, position: pos, action: .move))
                out.append(ScriptStep(t: t, position: pos, action: .down(button, mods)))

            case "up":
                out.append(ScriptStep(t: t, position: pos, action: .up(button, mods)))

            case "secondary-click":
                let hold = (e["hold"] as? NSNumber)?.doubleValue ?? 0.08
                out.append(ScriptStep(t: t, position: pos, action: .move))
                out.append(ScriptStep(t: t, position: pos, action: .down(.secondary, mods)))
                out.append(ScriptStep(t: t + hold, position: pos, action: .up(.secondary, mods)))

            case "tap", "click":
                let hold = (e["hold"] as? NSNumber)?.doubleValue ?? 0.08
                out.append(ScriptStep(t: t, position: pos, action: .move))
                out.append(ScriptStep(t: t, position: pos, action: .down(button, mods)))
                out.append(ScriptStep(t: t + hold, position: .relative(0, 0), action: .up(button, mods)))

            case "double-click", "double-tap", "triple-click":
                let hold = (e["hold"] as? NSNumber)?.doubleValue ?? 0.06
                let gap = max(hold + 0.01, (e["gap"] as? NSNumber)?.doubleValue ?? 0.15)
                let count = (ty == "triple-click") ? 3 : 2
                for k in 0..<count {
                    let start = t + gap * Double(k)
                    out.append(ScriptStep(t: start, position: pos, action: .move))
                    out.append(ScriptStep(t: start, position: pos, action: .down(.primary, mods)))
                    out.append(ScriptStep(t: start + hold, position: .relative(0, 0), action: .up(.primary, mods)))
                }

            case "drag":
                let dx = (e["dx"] as? NSNumber)?.floatValue ?? 0
                let dy = (e["dy"] as? NSNumber)?.floatValue ?? 0
                let dur = max(0.02, (e["dur"] as? NSNumber)?.doubleValue ?? 0.3)
                out.append(ScriptStep(t: t, position: pos, action: .move))
                out.append(ScriptStep(t: t, position: pos, action: .down(button, mods)))
                let steps = max(2, Int(ceil(dur * 60.0)))
                for s in 1...steps {
                    let f = Float(s) / Float(steps)
                    let eased = f * f * (3.0 - 2.0 * f)
                    out.append(ScriptStep(
                        t: t + dur * Double(s) / Double(steps),
                        position: .relative(dx * eased, dy * eased),
                        action: .move
                    ))
                }
                out.append(ScriptStep(t: t + dur + 0.02, position: .relative(dx, dy), action: .up(button, mods)))

            case "type":
                let text = (e["text"] as? String) ?? ""
                let every = (e["every"] as? NSNumber)?.doubleValue ?? 0.035
                for (k, ch) in text.enumerated() {
                    let ev = KeyEvent(key: .text(String(ch)), mods: .none)
                    out.append(ScriptStep(t: t + every * Double(k), position: .relative(0, 0), action: .keyDown(ev)))
                }

            case "key":
                let name = (e["name"] as? String) ?? ""
                let key: Key
                if mods.cmd, name.count == 1, let c = name.lowercased().first {
                    key = .command(c)
                } else if let named = Key.named(name) {
                    key = named
                } else {
                    continue
                }
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .keyDown(KeyEvent(key: key, mods: mods))))

            case "shortcut":
                if let chordStr = e["chord"] as? String, let chord = Chord(parsing: chordStr) {
                    out.append(ScriptStep(t: t, position: .relative(0, 0), action: .shortcut(chord)))
                }

            case "paste":
                let txt = (e["text"] as? String) ?? ""
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .paste(ClipboardContent(txt))))

            case "wheel":
                let dx = (e["dx"] as? NSNumber)?.floatValue ?? 0
                let dy = (e["dy"] as? NSNumber)?.floatValue ?? 0
                if case .relative = pos {} else {
                    out.append(ScriptStep(t: t, position: pos, action: .move))
                }
                out.append(ScriptStep(t: t, position: pos, action: .wheel(WheelEvent(dx: dx, dy: dy, mods: mods))))

            case "scroll":
                let dx = (e["dx"] as? NSNumber)?.floatValue ?? 0
                let dy = (e["dy"] as? NSNumber)?.floatValue ?? 0
                let dur = max(0.02, (e["dur"] as? NSNumber)?.doubleValue ?? 0.24)
                if case .relative = pos {} else {
                    out.append(ScriptStep(t: t, position: pos, action: .move))
                }
                let steps = max(2, Int(ceil(dur * 60.0)))
                var prevF: Float = 0
                for s in 1...steps {
                    let f = Float(s) / Float(steps)
                    let eased = f * f * (3.0 - 2.0 * f)
                    let df = eased - prevF
                    prevF = eased
                    out.append(ScriptStep(
                        t: t + dur * Double(s) / Double(steps),
                        position: .relative(0, 0),
                        action: .wheel(WheelEvent(dx: dx * df, dy: dy * df, mods: mods))
                    ))
                }

            case "fling":
                let vx = (e["vx"] as? NSNumber)?.floatValue ?? 0
                let vy = (e["v"] as? NSNumber)?.floatValue ?? (e["vy"] as? NSNumber)?.floatValue ?? 0
                out.append(ScriptStep(t: t, position: pos, action: .fling(vx: vx, vy: vy)))

            case "resize":
                let w = (e["w"] as? NSNumber)?.floatValue ?? 800
                let h = (e["h"] as? NSNumber)?.floatValue ?? 600
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .resize(Vec2(w, h))))

            case "wait", "mark":
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .move))

            default:
                break
            }
        }

        out.sort { $0.t < $1.t }
        return out
    }

    /// Runs `spec` deterministically under `args`, writing `--snap`, `--tree`, `--frames`, and `--strip` files if specified.
    @discardableResult
    public static func run<State>(_ spec: AppSpec<State>, args: ToolingArgs) throws -> Output {
        try runWithHooks(spec: spec, args: args)
    }

    /// Runs `app` deterministically under `args` (including `compositor`, `setup`, `poll`, `AppHandle` updates, and frame reports).
    @discardableResult
    public static func run<State>(_ app: App<State>, args: ToolingArgs) throws -> Output {
        var effectiveArgs = args
        if app.gpuBackendPreference == .software {
            effectiveArgs.forceCPU = true
        }
        let reports = FrameReports<State>(
            onFrameEncoded: app.onFrameEncodedHook,
            onFrameDrawn: app.onFrameDrawnHook,
            drawnInterval: 0.0
        )
        return try runWithHooks(
            spec: app.intoSpec(),
            args: effectiveArgs,
            compositor: app.compositorValue,
            reports: reports,
            appShared: app.sharedHandle.shared,
            extraConfigure: { runtime, _ in
                runtime.fontSmoothing = app.fontSmoothingMode
                runtime.onFocus = app.onFocusHook
                runtime.onModifiers = app.onModifiersHook
                runtime.onVisibility = app.onVisibilityHook
                runtime.onIme = app.onImeHook
                runtime.onClose = app.onCloseHook
                runtime.onQuit = app.onQuitHook
                runtime.turnScope = app.turnScopeHook
                runtime.onReopen = app.onReopenHook
                runtime.onOpenUrl = app.onOpenUrlHook
                runtime.tabVisitsControls = app.tabVisitsControlsEnabled
            }
        )
    }

    internal static func registerFonts(_ fonts: [Data]) {
        #if canImport(CoreText) && canImport(CoreGraphics)
        for data in fonts {
            guard let provider = CGDataProvider(data: data as CFData),
                  let cgFont = CGFont(provider) else { continue }
            CTFontManagerRegisterGraphicsFont(cgFont, nil)
        }
        #endif
    }

    private static func runWithHooks<State>(
        spec: AppSpec<State>,
        args: ToolingArgs,
        compositor: AnyCompositor<State>? = nil,
        reports: FrameReports<State>? = nil,
        appShared: AppShared<State>? = nil,
        extraConfigure: ((Runtime<State>, Waker) -> Void)? = nil
    ) throws -> Output {
        if args.listScenes {
            for name in spec.scenes.keys.sorted() {
                print(name)
            }
            return Output(finalFrame: Frame(width: 1, height: 1, rgba: [0, 0, 0, 255]), treeJSON: Data("{}".utf8))
        }

        registerFonts(spec.fonts)

        var initialState = spec.makeState()
        var initTx = Tx()
        if let sceneName = args.sceneName, let applyScene = spec.scenes[sceneName] {
            applyScene(&initialState, &initTx)
        }

        let waker = Waker()
        let vp = args.viewportOverride ?? spec.size
        let isDark = args.darkOverride ?? spec.dark ?? true
        let runtime = Runtime<State>(
            state: initialState,
            viewport: vp,
            pixelScale: args.pixelScale,
            systemDark: isDark,
            reducedMotion: args.reducedMotion,
            waker: waker,
            onKey: spec.onKey,
            view: spec.view
        )
        runtime.windowTitle = spec.title
        runtime.srgbBlend = spec.srgbBlend
        runtime.poll = spec.poll
        runtime.applyTx(initTx, at: 0.0, markDirtyIfNotLiveOnly: false)
        extraConfigure?(runtime, waker)
        appShared?.setWaker(waker)
        spec.setup?(waker)
        _ = appShared?.applyStateUpdates(to: runtime, at: 0.0)

        // Load script steps if `--script` was passed (supports file path OR inline JSON string)
        var steps: [ScriptStep] = []
        if let scriptArg = args.scriptArg {
            let data: Data
            let trimmed = scriptArg.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
                data = Data(trimmed.utf8)
            } else {
                data = try Data(contentsOf: URL(fileURLWithPath: scriptArg))
            }
            steps = try parseScript(jsonData: data)
        }

        let surfaceW = max(1, Int((vp.x * args.pixelScale).rounded()))
        let surfaceH = max(1, Int((vp.y * args.pixelScale).rounded()))

        #if canImport(Metal)
        let metalRenderer: MetalRenderer? = args.forceCPU ? nil : (try? MetalRenderer())
        func renderScene(_ refScene: RefScene) throws -> Frame {
            if let gpu = metalRenderer {
                return try gpu.renderOffscreen(refScene)
            }
            return try RuneRef.render(refScene)
        }
        let devKey = metalRenderer.map { DeviceKey(rawValue: $0.device.registryID) } ?? DeviceKey(rawValue: 0)
        #else
        func renderScene(_ refScene: RefScene) throws -> Frame {
            return try RuneRef.render(refScene)
        }
        let devKey = DeviceKey(rawValue: 0)
        #endif

        func renderAndReport(_ refScene: RefScene, at now: Double) throws -> Frame {
            let commitsBefore = runtime.viewCommitCount
            var rendered: Frame? = nil
            var drawCount = 0
            if let comp = compositor {
                let compFrame = CompositorFrame<State>(
                    deviceKey: devKey,
                    pixelSize: (surfaceW, surfaceH),
                    dt: 1.0 / 60.0,
                    updateMilliseconds: 0.0,
                    srgbBlend: runtime.srgbBlend,
                    runtime: runtime,
                    drawUI: {
                        drawCount += 1
                        rendered = try? renderScene(refScene)
                    }
                )
                comp.render(frame: compFrame)
                if !comp.drawsOwnContent && compFrame.uiDrawCount == 0 {
                    compFrame.drawUI()
                }
            }
            let outFrame = try rendered ?? {
                drawCount = 1
                return try renderScene(refScene)
            }()
            if let reports {
                let encoded = FrameEncoded(
                    outcome: .drawn,
                    frameMs: 0.0,
                    updateMs: 0.0,
                    encodeMs: 0.0,
                    committed: runtime.viewCommitCount != commitsBefore,
                    primitives: refScene.primitives.count,
                    glyphs: refScene.primitives.reduce(0) { $0 + ($1.kind == .glyph ? 1 : 0) },
                    animating: runtime.isAnimating,
                    compositorAnimating: compositor?.isAnimating ?? false,
                    drawCount: drawCount,
                    compositorSummary: compositor?.summary()
                )
                reports.record(encoded)
                runtime.updateIf(at: now) { s, tx in
                    reports.flush(state: &s, tx: &tx, at: now, force: true)
                }
            }
            return outFrame
        }

        // Initial settled frame at t = 0 (or `--at` if specified)
        let initialT = (args.atTime ?? 0.0) * args.timeScale
        var lastRefScene = runtime.frame(at: initialT)
        var capturedStripFrames: [Frame] = []

        if !steps.isEmpty || args.durationOverride != nil || args.framesDir != nil || args.stripPath != nil {
            let dt = 1.0 / max(1.0, args.fps)
            let lastEventTime = steps.last?.t ?? 0.0
            let maxSimTime = args.durationOverride ?? (args.atTime ?? (lastEventTime + 1.5))
            var simTime: Double = 0.0
            var stepCursor = 0
            var anchorPos = Vec2(vp.x * 0.5, vp.y * 0.5)
            var frameIndex = 0
            let stripStride = args.stripEvery ?? max(1, Int(args.fps / 12.0))

            if let framesDir = args.framesDir {
                try FileManager.default.createDirectory(atPath: framesDir, withIntermediateDirectories: true)
            }

            while simTime <= maxSimTime {
                while stepCursor < steps.count && steps[stepCursor].t <= simTime + 1e-6 {
                    let s = steps[stepCursor]
                    stepCursor += 1

                    let resolvedPos: Vec2
                    switch s.position {
                    case .key(let k):
                        if let elInfo = runtime.element(byKey: k) {
                            let cx = elInfo.rect[0] + elInfo.rect[2] * 0.5
                            let cy = elInfo.rect[1] + elInfo.rect[3] * 0.5
                            resolvedPos = Vec2(cx, cy)
                            anchorPos = resolvedPos
                        } else {
                            resolvedPos = anchorPos
                        }
                    case let .xy(x, y):
                        resolvedPos = Vec2(x, y)
                        anchorPos = resolvedPos
                    case let .relative(dx, dy):
                        resolvedPos = Vec2(anchorPos.x + dx, anchorPos.y + dy)
                    }

                    let animNow = simTime * args.timeScale
                    switch s.action {
                    case .move:
                        runtime.pointerMove(to: resolvedPos, at: animNow)
                    case let .down(btn, mods):
                        runtime.pointerDown(at: resolvedPos, button: btn, mods: mods, at: animNow)
                    case let .up(btn, mods):
                        runtime.pointerUp(at: resolvedPos, button: btn, mods: mods, at: animNow)
                    case .keyDown(let kev):
                        runtime.keyDown(kev, at: animNow)
                    case .shortcut(let chord):
                        runtime.keyDown(KeyEvent(key: chord.key, mods: chord.mods), at: animNow)
                    case .paste(let clip):
                        runtime.paste(clip, at: animNow)
                    case .wheel(let wev):
                        runtime.wheel(wev, at: resolvedPos, now: animNow)
                    case let .fling(vx, vy):
                        runtime.fling(vx: vx, vy: vy, at: resolvedPos, now: animNow)
                    case .resize(let newVP):
                        runtime.viewport = newVP
                    case .windowFocus(let foc):
                        runtime.windowFocused = foc
                    }
                }

                let animNow = simTime * args.timeScale
                lastRefScene = runtime.frame(at: animNow)

                if simTime + 1e-6 >= args.startTime {
                    if let framesDir = args.framesDir {
                        let f = try renderScene(lastRefScene)
                        let outURL = URL(fileURLWithPath: framesDir).appendingPathComponent(String(format: "frame_%04d.png", frameIndex))
                        try f.writePNG(to: outURL)
                    }
                    if args.stripPath != nil && (frameIndex % stripStride == 0) {
                        capturedStripFrames.append(try renderScene(lastRefScene))
                    }
                    frameIndex += 1
                }

                // Stop early once all script events have fired and all animations have settled!
                if args.durationOverride == nil && args.atTime == nil && stepCursor >= steps.count && !runtime.isAnimating && simTime >= lastEventTime + dt {
                    break
                }
                simTime += dt
            }
        }

        var finalFrame = try renderAndReport(lastRefScene, at: runtime.currentTime)
        if let cropKey = args.cropKey, let elInfo = runtime.element(byKey: cropKey) {
            finalFrame = cropFrame(finalFrame, rectPt: elInfo.rect, scale: args.pixelScale)
        }
        let treeData = try runtime.treeJSONData(pretty: true, realTime: runtime.currentTime)

        if let snapPath = args.snapPath {
            try finalFrame.writePNG(to: URL(fileURLWithPath: snapPath))
        }
        if let treePath = args.treePath {
            let url = URL(fileURLWithPath: treePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try treeData.write(to: url, options: .atomic)
        }
        if let stripPath = args.stripPath {
            let frames = capturedStripFrames.isEmpty ? [finalFrame] : capturedStripFrames
            let strip = stitchHorizontalStrip(frames: frames)
            try strip.writePNG(to: URL(fileURLWithPath: stripPath))
        }

        return Output(finalFrame: finalFrame, treeJSON: treeData)
    }

    private static func cropFrame(_ frame: Frame, rectPt: [Float], scale: Float) -> Frame {
        guard rectPt.count == 4 else { return frame }
        let x0 = max(0, Int((rectPt[0] * scale).rounded(.down)))
        let y0 = max(0, Int((rectPt[1] * scale).rounded(.down)))
        let x1 = min(frame.width, Int(((rectPt[0] + rectPt[2]) * scale).rounded(.up)))
        let y1 = min(frame.height, Int(((rectPt[1] + rectPt[3]) * scale).rounded(.up)))
        let cw = x1 - x0
        let ch = y1 - y0
        guard cw > 0 && ch > 0 else { return frame }
        var out = Array<UInt8>(repeating: 0, count: cw * ch * 4)
        for row in 0..<ch {
            let srcStart = ((y0 + row) * frame.width + x0) * 4
            let dstStart = row * cw * 4
            out.replaceSubrange(dstStart..<(dstStart + cw * 4), with: frame.rgba[srcStart..<(srcStart + cw * 4)])
        }
        return Frame(width: cw, height: ch, rgba: out)
    }

    private static func stitchHorizontalStrip(frames: [Frame]) -> Frame {
        guard let first = frames.first else {
            return Frame(width: 1, height: 1, rgba: [0, 0, 0, 255])
        }
        let w = first.width
        let h = first.height
        let totalW = w * frames.count
        var out = Array<UInt8>(repeating: 0, count: totalW * h * 4)
        for (idx, frame) in frames.enumerated() where frame.width == w && frame.height == h {
            for row in 0..<h {
                let srcStart = row * w * 4
                let dstStart = (row * totalW + idx * w) * 4
                out.replaceSubrange(dstStart..<(dstStart + w * 4), with: frame.rgba[srcStart..<(srcStart + w * 4)])
            }
        }
        return Frame(width: totalW, height: h, rgba: out)
    }
}
