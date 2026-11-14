import Foundation
import RuneMotion
import RuneRef
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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
    public var sceneOrder: [String] = []
    public var fonts: [Data]
    public var families: [String]
    public var setup: ((Waker) -> Void)?
    public var poll: ((inout State, Double, inout Tx) -> Bool)?
    public var onKey: ((inout State, KeyEvent, inout Tx) -> Bool)?
    public var onFileDrop: ((inout State, [URL], inout Tx) -> Void)?
    public var onFileDropPhase: ((inout State, FileDropPhase, inout Tx) -> Void)?
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
        onFileDrop: ((inout State, [URL], inout Tx) -> Void)? = nil,
        onFileDropPhase: ((inout State, FileDropPhase, inout Tx) -> Void)? = nil,
        view: @escaping (State, inout Cx<State>) -> El<State>
    ) {
        self.title = title
        self.size = size
        self.minSize = minSize
        self.dark = dark
        self.srgbBlend = srgbBlend
        self.makeState = state
        self.scenes = scenes
        self.sceneOrder = scenes.keys.sorted()
        self.fonts = fonts
        self.families = families
        self.setup = setup
        self.poll = poll
        self.onKey = onKey
        self.onFileDrop = onFileDrop
        self.onFileDropPhase = onFileDropPhase
        self.view = view
    }

    public func scene(_ name: String, _ apply: @escaping (inout State) -> Void) -> Self {
        var copy = self
        copy.scenes[name] = { s, _ in apply(&s) }
        if !copy.sceneOrder.contains(name) {
            copy.sceneOrder.append(name)
        }
        return copy
    }

    public func scene(_ name: String, _ apply: @escaping (inout State, inout Tx) -> Void) -> Self {
        var copy = self
        copy.scenes[name] = apply
        if !copy.sceneOrder.contains(name) {
            copy.sceneOrder.append(name)
        }
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

    public func onFileDrop(_ hook: @escaping (inout State, [URL], inout Tx) -> Void) -> Self {
        var copy = self
        copy.onFileDrop = hook
        return copy
    }

    public func onFileDropPhase(_ hook: @escaping (inout State, FileDropPhase, inout Tx) -> Void) -> Self {
        var copy = self
        copy.onFileDropPhase = hook
        return copy
    }
}

/// Parsed `mark:NAME[+|-SECONDS]` reference (`tooling/args.rs`).
public struct ToolingMarkOffset: Sendable, Equatable {
    public var name: String
    public var offset: Double

    public init(name: String, offset: Double = 0.0) {
        self.name = name
        self.offset = offset
    }
}

/// Parsed headless CLI arguments (`rune::tooling::Args`).
public struct ToolingArgs: Sendable, Equatable {
    public var snapPath: String? = nil
    public var treePath: String? = nil
    public var sceneName: String? = nil
    public var scriptArg: String? = nil
    public var framesDir: String? = nil
    public var outDir: String? = nil
    public var frameCount: Int? = nil
    public var stripPath: String? = nil
    public var stripCols: Int = 10
    public var fps: Double = 60.0
    public var pixelScale: Float = 2.0
    public var viewportOverride: Vec2? = nil
    public var darkOverride: Bool? = nil
    public var reducedMotion: Bool = false
    public var timeScale: Double = 1.0
    public var forceCPU: Bool = false
    public var durationOverride: Double? = nil
    public var durationAuto: Bool = false
    public var atTime: Double? = nil
    public var atMark: ToolingMarkOffset? = nil
    public var atMarkExpr: String? = nil
    public var startTime: Double = 0.0
    public var startMark: ToolingMarkOffset? = nil
    public var startMarkExpr: String? = nil
    public var cropKey: String? = nil
    public var cropRects: [[Float]] = []
    public var stripEvery: Int? = nil
    public var listScenes: Bool = false
    public var hasPlayground: Bool = false
    public var playgroundName: String? = nil
    public var playgroundVariant: String? = nil
    public var wholeWindow: Bool = false
    public var scrollBars: ScrollBars? = nil
    public var windowName: String? = nil
    public var listWindows: Bool = false
    public var chromeOverlay: Bool = false
    public var realtime: Bool = false
    public var tracePath: String? = nil
    public var traceAll: Bool = false
    public var isNative: Bool = false
    public var keysCorner: KeycapsCorner? = nil
    public var keysThemeDark: Bool? = nil
    public var showPointer: Bool = false
    public var firstPixels: Bool = false
    public var desktopPath: String? = nil
    public var videoPath: String? = nil
    public var htmlPath: String? = nil
    public var htmlTemplatePath: String? = nil
    public var htmlWidths: [Float] = []
    public var extraArgs: [String] = []

    public init() {}

    public var isHeadlessRequested: Bool {
        snapPath != nil
            || treePath != nil
            || htmlPath != nil
            || (!isNative && (
                scriptArg != nil
                    || tracePath != nil
                    || frameCount != nil
                    || durationOverride != nil
                    || durationAuto
                    || outDir != nil
                    || framesDir != nil
            ))
            || videoPath != nil
            || stripPath != nil
            || listScenes
            || firstPixels
            || listWindows
            || desktopPath != nil
    }

    public static func parseMarkTime(_ raw: String) -> ToolingMarkOffset? {
        guard raw.hasPrefix("mark:") else { return nil }
        let rest = String(raw.dropFirst("mark:".count))
        guard !rest.isEmpty else { return nil }
        if let plusIdx = rest.lastIndex(of: "+"), plusIdx > rest.startIndex,
           let offset = Double(rest[rest.index(after: plusIdx)...]), offset.isFinite {
            return ToolingMarkOffset(name: String(rest[..<plusIdx]), offset: offset)
        }
        if let minusIdx = rest.lastIndex(of: "-"), minusIdx > rest.startIndex,
           let offset = Double(rest[rest.index(after: minusIdx)...]), offset.isFinite {
            return ToolingMarkOffset(name: String(rest[..<minusIdx]), offset: -offset)
        }
        return ToolingMarkOffset(name: rest, offset: 0.0)
    }

    /// Resolves a `mark:` expression (without the `mark:` prefix) against loaded script marks.
    /// Exact mark names win before splitting trailing `+SECONDS` / `-SECONDS` offsets (`headless.rs`).
    public static func resolveMarkTime(_ spec: String, marks: [String: Double]) throws -> Double {
        if let exact = marks[spec] {
            return max(0.0, exact)
        }
        let known = Array(marks.keys).sorted()
        var idx = spec.index(after: spec.startIndex)
        while idx < spec.endIndex {
            let ch = spec[idx]
            if ch == "+" || ch == "-" {
                if let offset = Double(spec[idx...]), offset.isFinite {
                    let name = String(spec[..<idx])
                    guard let base = marks[name] else {
                        throw ToolingError.unknownMark(name: name, known: known)
                    }
                    return max(0.0, base + offset)
                }
            }
            idx = spec.index(after: idx)
        }
        if spec.contains("+") || spec.contains("-") {
            throw ToolingError.invalidMarkTime(spec: spec, known: known)
        }
        throw ToolingError.unknownMark(name: spec, known: known)
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
                if i + 1 < arguments.count {
                    let v = arguments[i + 1]
                    if let n = Int(v) {
                        out.frameCount = max(1, n)
                    } else {
                        out.framesDir = v
                    }
                    i += 1
                }
            case "--out":
                if i + 1 < arguments.count { out.outDir = arguments[i + 1]; i += 1 }
            case "--strip":
                if i + 1 < arguments.count { out.stripPath = arguments[i + 1]; i += 1 }
            case "--cols":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { out.stripCols = max(1, v); i += 1 }
            case "--fps":
                if i + 1 < arguments.count, let v = Double(arguments[i + 1]) { out.fps = max(1, v); i += 1 }
            case "--scale":
                if i + 1 < arguments.count, let v = Float(arguments[i + 1]), v.isFinite && v > 0 {
                    out.pixelScale = v
                }
                if i + 1 < arguments.count { i += 1 }
            case "--time-scale":
                if i + 1 < arguments.count, let v = Double(arguments[i + 1]) { out.timeScale = max(0.01, v); i += 1 }
            case "--duration":
                if i + 1 < arguments.count {
                    let v = arguments[i + 1]
                    if v == "auto" {
                        out.durationAuto = true
                    } else if let d = Double(v) {
                        out.durationOverride = max(0, d)
                    }
                    i += 1
                }
            case "--at":
                if i + 1 < arguments.count {
                    let v = arguments[i + 1]
                    if v.hasPrefix("mark:") {
                        let expr = String(v.dropFirst("mark:".count))
                        if !expr.isEmpty {
                            out.atMarkExpr = expr
                        }
                        out.atMark = parseMarkTime(v)
                    } else if let d = Double(v) {
                        out.atTime = max(0, d)
                    }
                    i += 1
                }
            case "--start":
                if i + 1 < arguments.count {
                    let v = arguments[i + 1]
                    if v.hasPrefix("mark:") {
                        let expr = String(v.dropFirst("mark:".count))
                        if !expr.isEmpty {
                            out.startMarkExpr = expr
                        }
                        out.startMark = parseMarkTime(v)
                    } else if let d = Double(v) {
                        out.startTime = max(0, d)
                    }
                    i += 1
                }
            case "--crop":
                if i + 1 < arguments.count {
                    let v = arguments[i + 1]
                    let parts = v.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
                    if parts.count == 4 {
                        out.cropRects.append(parts)
                    } else {
                        out.cropKey = v
                    }
                    i += 1
                }
            case "--every":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { out.stripEvery = max(1, v); i += 1 }
            case "--list-scenes":
                out.listScenes = true
            case "--playground":
                out.hasPlayground = true
                if i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-") {
                    out.playgroundName = arguments[i + 1]
                    i += 1
                }
            case "--variant":
                if i + 1 < arguments.count { out.playgroundVariant = arguments[i + 1]; i += 1 }
            case "--whole-window":
                out.wholeWindow = true
            case "--scroll-bars":
                if i + 1 < arguments.count {
                    switch arguments[i + 1].lowercased() {
                    case "automatic", "auto": out.scrollBars = .automatic
                    case "when-scrolling", "whenscrolling": out.scrollBars = .whenScrolling
                    case "always": out.scrollBars = .always
                    default: break
                    }
                    i += 1
                }
            case "--window":
                if i + 1 < arguments.count { out.windowName = arguments[i + 1]; i += 1 }
            case "--list-windows":
                out.listWindows = true
            case "--chrome":
                out.chromeOverlay = true
            case "--realtime":
                out.realtime = true
            case "--native":
                out.isNative = true
            case "--keys":
                if i + 1 < arguments.count, let corner = KeycapsCorner.parse(arguments[i + 1]) {
                    out.keysCorner = corner
                    i += 1
                } else {
                    out.keysCorner = .bottomLeft
                }
            case "--keys-theme":
                if i + 1 < arguments.count {
                    if let parsedTheme = Keycaps.parseTheme(arguments[i + 1]) {
                        out.keysThemeDark = parsedTheme
                    }
                    i += 1
                }
            case "--pointer":
                out.showPointer = true
            case "--first-pixels":
                out.firstPixels = true
            case "--desktop":
                if i + 1 < arguments.count { out.desktopPath = arguments[i + 1]; i += 1 }
            case "--trace":
                if i + 1 < arguments.count { out.tracePath = arguments[i + 1]; i += 1 }
            case "--trace-all":
                out.traceAll = true
            case "--video":
                if i + 1 < arguments.count { out.videoPath = arguments[i + 1]; i += 1 }
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
                    if parts.count == 2,
                       let w = Float(parts[0]), w.isFinite && w > 0,
                       let h = Float(parts[1]), h.isFinite && h > 0 {
                        out.viewportOverride = Vec2(w, h)
                    }
                    i += 1
                }
            case "--dark":
                out.darkOverride = true
            case "--light":
                out.darkOverride = false
            case "--reduced-motion":
                out.reducedMotion = true
            case "--cpu", "--force-cpu":
                out.forceCPU = true
            case "--html":
                if i + 1 < arguments.count { out.htmlPath = arguments[i + 1]; i += 1 }
            case "--html-template":
                if i + 1 < arguments.count { out.htmlTemplatePath = arguments[i + 1]; i += 1 }
            case "--html-widths":
                if i + 1 < arguments.count {
                    out.htmlWidths = arguments[i + 1]
                        .split(separator: ",")
                        .compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
                        .filter { $0 > 0 }
                    i += 1
                }
            default:
                out.extraArgs.append(arg)
            }
            i += 1
        }
        return out
    }

    /// Validated variant of `parse(_:)` that throws `ToolingError.invalidArgument` for invalid CLI flags (`args.rs`).
    public static func parseChecked(_ arguments: [String]) throws -> ToolingArgs {
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            func nextVal() throws -> String {
                guard i + 1 < arguments.count else {
                    throw ToolingError.invalidArgument("\(arg) needs a value")
                }
                i += 1
                return arguments[i]
            }
            switch arg {
            case "--size":
                let v = try nextVal()
                let parts = v.lowercased().split(separator: "x", omittingEmptySubsequences: false)
                guard parts.count == 2,
                      let w = Float(parts[0].trimmingCharacters(in: .whitespaces)), w.isFinite && w > 0,
                      let h = Float(parts[1].trimmingCharacters(in: .whitespaces)), h.isFinite && h > 0 else {
                    throw ToolingError.invalidArgument("--size is WxH, both above 0: \(v)")
                }
            case "--scale":
                let v = try nextVal()
                guard let s = Float(v.trimmingCharacters(in: .whitespaces)), s.isFinite && s > 0 else {
                    throw ToolingError.invalidArgument("--scale is a number above 0: \(v)")
                }
            case "--keys-theme":
                let v = try nextVal()
                guard Keycaps.parseTheme(v) != nil else {
                    throw ToolingError.invalidArgument("--keys-theme is auto, light or dark")
                }
            case "--scroll-bars":
                let v = try nextVal().lowercased()
                guard ["always", "when-scrolling", "whenscrolling", "automatic", "auto"].contains(v) else {
                    throw ToolingError.invalidArgument("--scroll-bars is when-scrolling, always or automatic: \(v)")
                }
            case "--keys":
                if i + 1 < arguments.count, KeycapsCorner.parse(arguments[i + 1]) != nil {
                    i += 1
                }
            case "--playground":
                if i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-") {
                    i += 1
                }
            case "--snap", "--tree", "--scene", "--script", "--frames", "--out", "--strip",
                 "--cols", "--fps", "--time-scale", "--duration", "--at", "--start",
                 "--crop", "--every", "--variant", "--window", "--trace", "--video",
                 "--theme", "--desktop", "--html", "--html-template", "--html-widths":
                _ = try nextVal()
            default:
                break
            }
            i += 1
        }
        let parsed = parse(arguments)
        if parsed.playgroundVariant != nil && !parsed.hasPlayground {
            throw ToolingError.invalidArgument("--variant needs --playground")
        }
        if parsed.cropKey != nil && parsed.snapPath == nil {
            throw ToolingError.invalidArgument("--crop KEY needs --snap")
        }
        if parsed.wholeWindow && (!parsed.hasPlayground || parsed.snapPath == nil) {
            throw ToolingError.invalidArgument("--whole-window needs --playground and --snap")
        }
        return parsed
    }
}

/// Synthetic input event parsed from `--script` JSON.
public struct ScriptStep: Sendable, Equatable {
    public enum Position: Sendable, Equatable {
        case key(String)
        case xy(Float, Float)
        case relative(Float, Float)
    }

    public enum Action: Sendable, Equatable {
        case move
        case down(PointerButton, Mods)
        case up(PointerButton, Mods)
        case keyDown(KeyEvent)
        case keyRepeat(KeyEvent)
        case keyUp(KeyEvent)
        case physical(PhysicalInput)
        case physicalKey(PhysicalInput, KeyEvent, Character?)
        case shortcut(Chord)
        case paste(ClipboardContent)
        case ime(Ime)
        case wheel(WheelEvent)
        case magnify(MagnifyEvent)
        case fling(vx: Float, vy: Float)
        case resize(Vec2)
        case resizeDelta(dw: Float, dh: Float)
        case windowFocus(Bool)
        case mark(String)
        case reopen
        case openUrl(String)
        case dragFiles([URL])
        case dropFiles([URL])
        case dragFilesLeave
        case popupPick(String?)
        case fileDialogAnswer(URL?)
    }

    public var t: Double
    public var position: Position
    public var action: Action
}

/// Errors thrown by `HeadlessRunner` and CLI tooling validation.
public enum ToolingError: Error, LocalizedError, Equatable, Sendable {
    case unknownWindow(name: String, available: [String])
    case unknownMark(name: String, known: [String])
    case invalidMarkTime(spec: String, known: [String])
    case playgroundNotConfigured
    case unsupportedVideoContainer(ext: String)
    case ffmpegUnavailable
    case ffmpegFailed(status: Int32)
    case encoderError(message: String)
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .unknownWindow(let name, let available):
            if available == ["main"] {
                return "no such window \"\(name)\"; this app has only 'main'"
            }
            return "no such window \"\(name)\"; available: \(available.joined(separator: ", "))"
        case .unknownMark(let name, let known):
            let list = known.isEmpty ? "none" : known.joined(separator: ", ")
            return "no mark \"\(name)\" in the script (marks: \(list))"
        case .invalidMarkTime(let spec, let known):
            let list = known.isEmpty ? "none" : known.joined(separator: ", ")
            return "invalid mark time \"\(spec)\": expected an exact mark name or NAME+SECONDS/NAME-SECONDS (marks: \(list))"
        case .playgroundNotConfigured:
            return "--playground requested, but app has no PlaygroundHost configured"
        case .unsupportedVideoContainer(let ext):
            return "unsupported video container .\(ext) (expected .mp4, .mov, or .webm)"
        case .ffmpegUnavailable:
            return "--video needs ffmpeg on PATH (macOS: brew install ffmpeg; Debian/Ubuntu: apt install ffmpeg)"
        case .ffmpegFailed(let status):
            return "ffmpeg failed writing video (exit status \(status))"
        case .encoderError(let message):
            return message
        case .invalidArgument(let message):
            return message
        }
    }
}

/// Headless virtual-clock runner for `--snap`, `--tree`, `--script`, `--frames`, `--out`, and `--strip`.
public enum HeadlessRunner {
    /// Unpremultiplies premultiplied sRGB pixel bytes in linear space (`tooling/headless.rs::straight_alpha`).
    public static func straightAlpha(_ pixels: inout [UInt8]) {
        let count = pixels.count - (pixels.count % 4)
        for i in stride(from: 0, to: count, by: 4) {
            let a = Float(pixels[i + 3]) / 255.0
            if a == 0.0 {
                pixels[i] = 0
                pixels[i + 1] = 0
                pixels[i + 2] = 0
            } else if a < 1.0 {
                for c in 0..<3 {
                    let encoded = Float(pixels[i + c]) / 255.0
                    let linear = DragImage.srgbDecode(encoded) / a
                    let reencoded = DragImage.srgbEncode(min(1.0, max(0.0, linear)))
                    pixels[i + c] = UInt8((reencoded * 255.0).rounded())
                }
            }
        }
    }

    public struct Output: Sendable {
        public var finalFrame: Frame
        public var treeJSON: Data
        public var frameCount: Int = 0
        public var marks: [String: Double] = [:]
        public var windowKeys: [String] = []
        public var tracePath: String? = nil
        public var videoPath: String? = nil
        public var chromeOverlaps: [String] = []
    }

    private static func resolveScriptPosition(from e: [String: Any]) -> ScriptStep.Position {
        if let k = e["key"] as? String {
            return .key(k)
        }
        if let at = e["at"] as? [Any], at.count == 2,
           let x = (at[0] as? NSNumber)?.floatValue,
           let y = (at[1] as? NSNumber)?.floatValue {
            return .xy(x, y)
        }
        if let x = (e["x"] as? NSNumber)?.floatValue, let y = (e["y"] as? NSNumber)?.floatValue {
            return .xy(x, y)
        }
        return .relative(0, 0)
    }

    private static func parseScriptMods(from e: [String: Any]) -> Mods {
        let cmd = (e["cmd"] as? Bool) ?? false
        #if os(macOS)
        let isMac = true
        #else
        let isMac = false
        #endif
        return Mods(
            shift: (e["shift"] as? Bool) ?? false,
            ctrl: ((e["ctrl"] as? Bool) ?? false) || (cmd && !isMac),
            alt: (e["alt"] as? Bool) ?? false,
            cmd: cmd,
            logo: ((e["logo"] as? Bool) ?? false) || (cmd && isMac)
        )
    }

    private static func parseScriptPaste(from dict: [String: Any]) -> ClipboardContent {
        let txt = (dict["text"] as? String) ?? ""
        let rawHTML = dict["html"] as? String
        let html = rawHTML.map { RichClipboardPayload.sanitizeHTML($0) }
        let rtf = dict["rtf"] as? String
        var image: ClipboardImage? = nil
        if let pngPath = dict["png"] as? String,
           let raw = try? Data(contentsOf: URL(fileURLWithPath: pngPath)),
           let decoded = ClipboardImage.decodeImageDataToRGBA(raw) {
            image = ClipboardImage(width: UInt32(decoded.width), height: UInt32(decoded.height), pngData: raw)
        }
        return ClipboardContent(txt, html: html, rtf: rtf, image: image)
    }

    private static func physicalKeyCode(forName raw: String) -> PhysicalKeyCode? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 1, let ch = trimmed.first {
            if let k = Key.named(String(ch)), let code = PhysicalKeyCode.from(k) {
                return code
            }
            if ch == " " { return .space }
        }
        let lower = trimmed.lowercased()
        switch lower {
        case "enter", "return": return .enter
        case "tab": return .tab
        case "escape", "esc": return .escape
        case "backspace": return .backspace
        case "delete", "del": return .delete
        case "space": return .space
        case "left": return .arrowLeft
        case "right": return .arrowRight
        case "up": return .arrowUp
        case "down": return .arrowDown
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        case "minus": return .minus
        case "equal": return .equal
        case "bracketleft": return .bracketLeft
        case "bracketright": return .bracketRight
        case "backslash": return .backslash
        case "semicolon": return .semicolon
        case "quote": return .quote
        case "backquote": return .backquote
        case "comma": return .comma
        case "period": return .period
        case "slash": return .slash
        default:
            if lower.hasPrefix("f"), let n = Int(lower.dropFirst()), (1...24).contains(n) {
                return PhysicalKeyCode.from(.f(UInt8(n)))
            }
            return Key.named(trimmed).flatMap(PhysicalKeyCode.from)
        }
    }

    private static func parsePhysicalChord(_ raw: String) -> (code: PhysicalKeyCode, mods: Mods)? {
        #if os(macOS)
        let isMac = true
        #else
        let isMac = false
        #endif
        if let parsed = try? ParsedShortcut.parseOn(raw),
           let code = physicalKeyCode(forName: parsed.keyName) {
            let superHeld = (parsed.mods & ParsedShortcut.superBit) != 0
            let ctrlHeld = (parsed.mods & ParsedShortcut.ctrlBit) != 0
            let altHeld = (parsed.mods & ParsedShortcut.altBit) != 0
            let shiftHeld = (parsed.mods & ParsedShortcut.shiftBit) != 0
            let mods = Mods(
                shift: shiftHeld,
                ctrl: ctrlHeld || (!isMac && superHeld),
                alt: altHeld,
                cmd: superHeld,
                logo: superHeld
            )
            return (code, mods)
        }
        if let code = physicalKeyCode(forName: raw) {
            return (code, .none)
        }
        return nil
    }

    private static func scriptKeyBase(from e: [String: Any], name: String, mods: Mods) -> Character? {
        if let base = e["base"] as? String {
            return base.count == 1 ? base.first : nil
        }
        guard name.count == 1, !mods.shift, !mods.alt else { return nil }
        return name.lowercased().first
    }

    private static func parseGesturePhase(_ raw: String?) -> GesturePhase {
        switch raw?.lowercased() {
        case "began": return .began
        case "changed": return .changed
        case "ended": return .ended
        case "cancelled": return .cancelled
        default: return .changed
        }
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
            if let physStr = e["physical"] as? String, let (code, physMods) = parsePhysicalChord(physStr) {
                let rep = (e["repeat"] as? Bool) ?? false
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .physical(.key(key: code, mods: physMods, pressed: true, repeat: rep))))
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .physical(.key(key: code, mods: physMods, pressed: false, repeat: false))))
                if physMods != .none {
                    out.append(ScriptStep(t: t, position: .relative(0, 0), action: .physical(.modifiers(.none))))
                }
                continue
            }
            if let pasteStr = e["paste"] as? String {
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .paste(ClipboardContent(pasteStr))))
                continue
            } else if let pasteObj = e["paste"] as? [String: Any] {
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .paste(parseScriptPaste(from: pasteObj))))
                continue
            }
            if let reopen = e["reopen"] as? Bool, reopen {
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .reopen))
                continue
            }
            if let openUrl = e["open_url"] as? String {
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .openUrl(openUrl)))
                continue
            }
            if let dragStr = e["drag_files"] as? String, dragStr == "leave" {
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .dragFilesLeave))
                continue
            } else if let dragPaths = e["drag_files"] as? [String] {
                let pos = resolveScriptPosition(from: e)
                out.append(ScriptStep(t: t, position: pos, action: .dragFiles(dragPaths.map { URL(fileURLWithPath: $0) })))
                continue
            } else if let dragObj = e["drag_files"] as? [String: Any], let paths = dragObj["paths"] as? [String] {
                let innerPos = resolveScriptPosition(from: dragObj)
                let pos: ScriptStep.Position = if case .relative = innerPos { resolveScriptPosition(from: e) } else { innerPos }
                out.append(ScriptStep(t: t, position: pos, action: .dragFiles(paths.map { URL(fileURLWithPath: $0) })))
                continue
            }
            if let dropPaths = e["drop_files"] as? [String] {
                let pos = resolveScriptPosition(from: e)
                out.append(ScriptStep(t: t, position: pos, action: .dropFiles(dropPaths.map { URL(fileURLWithPath: $0) })))
                continue
            } else if let dropObj = e["drop_files"] as? [String: Any], let paths = dropObj["paths"] as? [String] {
                let innerPos = resolveScriptPosition(from: dropObj)
                let pos: ScriptStep.Position = if case .relative = innerPos { resolveScriptPosition(from: e) } else { innerPos }
                let urls = paths.map { URL(fileURLWithPath: $0) }
                if let hover = (dropObj["hover"] as? NSNumber)?.doubleValue, hover > 0 {
                    out.append(ScriptStep(t: t, position: pos, action: .dragFiles(urls)))
                    out.append(ScriptStep(t: t + hover, position: pos, action: .dropFiles(urls)))
                } else {
                    out.append(ScriptStep(t: t, position: pos, action: .dropFiles(urls)))
                }
                continue
            }

            let pos = resolveScriptPosition(from: e)
            let mods = parseScriptMods(from: e)
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

            case "key", "key-up":
                let name = (e["name"] as? String) ?? ""
                let key: Key
                if mods.cmd, name.count == 1, let c = name.lowercased().first {
                    key = .command(c)
                } else if let named = Key.named(name) {
                    key = named
                } else {
                    continue
                }
                let kev = KeyEvent(key: key, mods: mods)
                let rep = (e["repeat"] as? Bool) ?? false
                if let codeStr = e["code"] as? String, let phys = physicalKeyCode(forName: codeStr) {
                    let base = scriptKeyBase(from: e, name: name, mods: mods)
                    if ty == "key-up" {
                        out.append(ScriptStep(t: t, position: .relative(0, 0), action: .physicalKey(.key(key: phys, mods: mods, pressed: false, repeat: false), kev, base)))
                    } else {
                        out.append(ScriptStep(t: t, position: .relative(0, 0), action: .physicalKey(.key(key: phys, mods: mods, pressed: true, repeat: rep), kev, base)))
                        out.append(ScriptStep(t: t, position: .relative(0, 0), action: .physical(.key(key: phys, mods: mods, pressed: false, repeat: false))))
                    }
                } else if ty == "key-up" {
                    out.append(ScriptStep(t: t, position: .relative(0, 0), action: .keyUp(kev)))
                } else {
                    out.append(ScriptStep(t: t, position: .relative(0, 0), action: rep ? .keyRepeat(kev) : .keyDown(kev)))
                }

            case "shortcut":
                if let chordStr = e["chord"] as? String, let chord = Chord(parsing: chordStr) {
                    out.append(ScriptStep(t: t, position: .relative(0, 0), action: .shortcut(chord)))
                }

            case "paste":
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .paste(parseScriptPaste(from: e))))

            case "ime":
                if let commit = e["commit"] as? String {
                    out.append(ScriptStep(t: t, position: .relative(0, 0), action: .ime(.commit(commit))))
                } else if let preedit = e["preedit"] as? String {
                    let cursorArr = e["cursor"] as? [Int]
                    let range: Range<Int>? = (cursorArr?.count == 2) ? (cursorArr![0]..<cursorArr![1]) : nil
                    out.append(ScriptStep(t: t, position: .relative(0, 0), action: .ime(.preedit(ImePreedit(text: preedit, cursorUTF8: range)))))
                } else {
                    out.append(ScriptStep(t: t, position: .relative(0, 0), action: .ime(.cancel)))
                }

            case "reopen":
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .reopen))

            case "open_url", "open-url":
                if let u = e["url"] as? String {
                    out.append(ScriptStep(t: t, position: .relative(0, 0), action: .openUrl(u)))
                }

            case "drag_files", "drag-files":
                if let paths = e["paths"] as? [String] {
                    out.append(ScriptStep(t: t, position: pos, action: .dragFiles(paths.map { URL(fileURLWithPath: $0) })))
                } else {
                    out.append(ScriptStep(t: t, position: .relative(0, 0), action: .dragFilesLeave))
                }

            case "drop_files", "drop-files":
                if let paths = e["paths"] as? [String] {
                    let urls = paths.map { URL(fileURLWithPath: $0) }
                    if let hover = (e["hover"] as? NSNumber)?.doubleValue, hover > 0 {
                        out.append(ScriptStep(t: t, position: pos, action: .dragFiles(urls)))
                        out.append(ScriptStep(t: t + hover, position: pos, action: .dropFiles(urls)))
                    } else {
                        out.append(ScriptStep(t: t, position: pos, action: .dropFiles(urls)))
                    }
                }

            case "menu-pick", "popup-pick":
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .popupPick(e["id"] as? String)))

            case "menu-cancel", "popup-cancel":
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .popupPick(nil)))

            case "file-dialog":
                let url = (e["path"] as? String).map { URL(fileURLWithPath: $0) }
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .fileDialogAnswer(url)))

            case "file-dialog-cancel":
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .fileDialogAnswer(nil)))

            case "wheel":
                let dx = (e["dx"] as? NSNumber)?.floatValue ?? 0
                let dy = (e["dy"] as? NSNumber)?.floatValue ?? 0
                let phase = parseGesturePhase(e["phase"] as? String)
                if case .relative = pos {} else {
                    out.append(ScriptStep(t: t, position: pos, action: .move))
                }
                out.append(ScriptStep(t: t, position: pos, action: .wheel(WheelEvent(dx: dx, dy: dy, precise: true, phase: phase, mods: mods))))

            case "magnify":
                let delta = (e["delta"] as? NSNumber)?.floatValue ?? 0
                let phase = parseGesturePhase(e["phase"] as? String)
                if case .relative = pos {} else {
                    out.append(ScriptStep(t: t, position: pos, action: .move))
                }
                out.append(ScriptStep(t: t, position: pos, action: .magnify(MagnifyEvent(delta: delta, phase: phase))))

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

            case "resize", "resize_delta":
                if ty == "resize_delta" || e["dw"] != nil || e["dh"] != nil || (e["w"] == nil && e["h"] == nil) {
                    let dw = (e["dw"] as? NSNumber)?.floatValue ?? 0
                    let dh = (e["dh"] as? NSNumber)?.floatValue ?? 0
                    let defaultDur: Double = (ty == "resize_delta") ? 0.01 : 0.3
                    let dur = max(0.01, (e["dur"] as? NSNumber)?.doubleValue ?? defaultDur)
                    let steps = max(1, Int(ceil(dur * 120.0)))
                    for s in 0...steps {
                        let f = Float(s) / Float(steps)
                        let eased = f * f * (3.0 - 2.0 * f)
                        out.append(ScriptStep(
                            t: t + dur * Double(s) / Double(steps),
                            position: .relative(0, 0),
                            action: .resizeDelta(dw: dw * eased, dh: dh * eased)
                        ))
                    }
                } else {
                    let w = (e["w"] as? NSNumber)?.floatValue ?? 800
                    let h = (e["h"] as? NSNumber)?.floatValue ?? 600
                    out.append(ScriptStep(t: t, position: .relative(0, 0), action: .resize(Vec2(w, h))))
                }

            case "wait":
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .move))

            case "mark":
                let markName = (e["name"] as? String) ?? ""
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .mark(markName)))

            default:
                break
            }
        }

        out.sort { $0.t < $1.t }
        return out
    }

    /// Runs `spec` deterministically under `args`, writing `--snap`, `--tree`, `--frames`, and `--strip` files if specified.
    @discardableResult
    public static func run<State>(
        _ spec: AppSpec<State>,
        args: ToolingArgs,
        chrome: Chrome = .standard,
        windowKey: String = "main",
        availableWindows: [String] = ["main"],
        shortcutRegistry: ShortcutRegistry? = nil
    ) throws -> Output {
        try runWithHooks(
            spec: spec,
            args: args,
            chrome: chrome,
            windowKey: windowKey,
            availableWindows: availableWindows,
            shortcutRegistry: shortcutRegistry
        )
    }

    internal static func runHostedWindowSpec<State>(
        _ spec: AppSpec<State>,
        args: ToolingArgs,
        chrome: Chrome = .standard,
        windowKey: String = "main",
        availableWindows: [String] = ["main"],
        onReady: ((WindowHandle) -> Void)? = nil,
        appShared: AppShared<State>? = nil,
        windowOptions: WindowOptions? = nil,
        menuItems: [NativeMenuItem<State>] = [],
        fitContentHeight: Bool = false,
        onQuit: ((inout State, inout Tx) -> Void)? = nil,
        onReopen: ((inout State, Bool, inout Tx) -> Bool)? = nil,
        onOpenUrl: ((inout State, String, inout Tx) -> Void)? = nil,
        shortcutRegistry: ShortcutRegistry? = nil,
        extraConfigure: ((Runtime<State>, Waker) -> Void)? = nil
    ) throws -> Output {
        try runWithHooks(
            spec: spec,
            args: args,
            chrome: chrome,
            windowKey: windowKey,
            availableWindows: availableWindows,
            onReady: onReady,
            appShared: appShared,
            windowOptions: windowOptions,
            menuItems: menuItems,
            shortcutRegistry: shortcutRegistry,
            extraConfigure: { runtime, waker in
                runtime.fitHeight = fitContentHeight
                runtime.windowResting = true
                runtime.onQuit = onQuit
                runtime.onReopen = onReopen
                runtime.onOpenUrl = onOpenUrl
                extraConfigure?(runtime, waker)
            }
        )
    }

    /// Runs `app` deterministically under `args` (including `compositor`, `setup`, `poll`, `AppHandle` updates, and frame reports).
    @discardableResult
    public static func run<State>(_ app: App<State>, args: ToolingArgs, shortcutRegistry: ShortcutRegistry? = nil) throws -> Output {
        var effectiveArgs = args
        if app.gpuBackendPreference == .software {
            effectiveArgs.forceCPU = true
        }
        if !app.childWindows.isEmpty {
            var rootApp = app
            rootApp.childWindows = []
            var rootSpec = AppWindowSpec.fromApp("main", rootApp)
            rootSpec.childWindows = app.childWindows
            return try RuneMultiWindow.runHeadless([rootSpec.boxed()], args: effectiveArgs)
        }
        let resolvedChrome = app.customTitlebar?.macChrome(app.chromeStyle) ?? app.chromeStyle
        let reports: FrameReports<State>? = (app.onFrameEncodedHook != nil || app.onFrameDrawnHook != nil || app.onFrameInspectHook != nil)
            ? FrameReports<State>(
                onFrameEncoded: app.onFrameEncodedHook,
                onFrameDrawn: app.onFrameDrawnHook,
                onInspectDrawn: app.onFrameInspectHook,
                drawnInterval: 0.0,
                windowKey: "main"
            )
            : nil
        return try runWithHooks(
            spec: app.intoSpec(),
            args: effectiveArgs,
            chrome: resolvedChrome,
            windowKey: "main",
            availableWindows: ["main"],
            onReady: app.onReadyHook,
            playgroundHost: app.playgroundHost,
            compositor: app.compositorValue,
            reports: reports,
            appShared: app.sharedHandle.shared,
            windowOptions: app.windowOptionsValue,
            menuItems: app.menuItems,
            shortcutRegistry: shortcutRegistry,
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
                runtime.fitHeight = app.isFitContentHeight
                runtime.windowResting = true
                AppRuntimeConfigurer.configureShortcuts(
                    runtime: runtime,
                    entries: app.globalShortcuts,
                    allowUnmodified: app.allowUnmodifiedShortcutsEnabled,
                    sharedHandle: app.sharedHandle
                )
                if let pg = app.playgroundHost {
                    let spec = app.intoSpec()
                    pg.bindScenes(spec.scenes, sceneOrder: spec.sceneOrder, view: app.view)
                    runtime.playgroundHost = pg
                }
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

    internal static func runWithHooks<State>(
        spec: AppSpec<State>,
        args: ToolingArgs,
        chrome: Chrome = .standard,
        windowKey: String = "main",
        availableWindows: [String] = ["main"],
        onReady: ((WindowHandle) -> Void)? = nil,
        playgroundHost: PlaygroundHost<State>? = nil,
        compositor: AnyCompositor<State>? = nil,
        reports: FrameReports<State>? = nil,
        appShared: AppShared<State>? = nil,
        windowOptions: WindowOptions? = nil,
        menuItems: [NativeMenuItem<State>] = [],
        shortcutRegistry: ShortcutRegistry? = nil,
        extraConfigure: ((Runtime<State>, Waker) -> Void)? = nil
    ) throws -> Output {
        if args.listWindows {
            for key in availableWindows {
                print(key)
            }
            return Output(
                finalFrame: Frame(width: 1, height: 1, rgba: [0, 0, 0, 255]),
                treeJSON: Data("{}".utf8),
                windowKeys: availableWindows
            )
        }
        if let requestedWindow = args.windowName, !availableWindows.contains(requestedWindow) {
            throw ToolingError.unknownWindow(name: requestedWindow, available: availableWindows)
        }
        if args.listScenes {
            for name in spec.scenes.keys.sorted() {
                print(name)
            }
            return Output(finalFrame: Frame(width: 1, height: 1, rgba: [0, 0, 0, 255]), treeJSON: Data("{}".utf8))
        }
        if let htmlPath = args.htmlPath {
            registerFonts(spec.fonts)
            _ = try ToolingHTML.exportToFile(
                spec: spec,
                outputPath: htmlPath,
                widths: args.htmlWidths,
                height: args.viewportOverride?.y,
                scale: args.pixelScale,
                dark: args.darkOverride ?? spec.dark ?? true,
                templatePath: args.htmlTemplatePath,
                sceneName: args.sceneName
            )
            let vp = args.viewportOverride ?? spec.size
            let w = max(1, Int((vp.x * args.pixelScale).rounded()))
            let h = max(1, Int((vp.y * args.pixelScale).rounded()))
            return Output(
                finalFrame: Frame(width: w, height: h, rgba: [UInt8](repeating: 0, count: w * h * 4)),
                treeJSON: Data("{}".utf8),
                windowKeys: availableWindows
            )
        }

        registerFonts(spec.fonts)

        // Load script steps upfront so `HeadlessRun.current` is populated before `spec.makeState()`.
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

        let initialPublishedRun = HeadlessRun(
            scriptPath: args.scriptArg,
            events: steps.map(Self.headlessEvent(from:)),
            scale: args.pixelScale,
            fps: Float(args.fps),
            size: args.viewportOverride ?? spec.size,
            start: args.startTime,
            frames: args.frameCount ?? 1,
            end: steps.last?.t ?? 0.0,
            desktopPath: args.desktopPath
        )
        HeadlessRun.publish(initialPublishedRun)

        var initTx = Tx()
        let initialState = withSceneClock(SceneClock(now: 0.0, dt: 0.0)) {
            var s = spec.makeState()
            if let sceneName = args.sceneName, let applyScene = spec.scenes[sceneName] {
                applyScene(&s, &initTx)
            }
            return s
        }

        let waker = Waker()
        var vp = args.viewportOverride ?? spec.size
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
        runtime.onAppFileDrop = spec.onFileDrop
        runtime.onFileDrop = spec.onFileDropPhase
        runtime.shortcutRegistry = shortcutRegistry
        if args.tracePath != nil {
            runtime.traceChannels = [:]
        }
        runtime.applyTx(initTx, at: 0.0, markDirtyIfNotLiveOnly: false)
        extraConfigure?(runtime, waker)
        if let appShared {
            AppMenuBridge.markRunning(appShared, running: true, headless: true)
            if !menuItems.isEmpty {
                do {
                    try AppMenuBridge.setMenu(menuItems, for: appShared)
                } catch let err as MenuError {
                    AppMenuBridge.recordError(err, for: appShared)
                } catch {
                    AppMenuBridge.recordError(.unsupported, for: appShared)
                }
            }
        }
        defer {
            if let appShared {
                AppMenuBridge.markRunning(appShared, running: false, headless: false)
            }
        }
        appShared?.setWaker(waker)
        withSceneClock(SceneClock(now: 0.0, dt: 0.0)) {
            spec.setup?(waker)
        }
        _ = appShared?.applyStateUpdates(to: runtime, at: 0.0)
        let minSizeLimit = windowOptions?.minSize ?? spec.minSize ?? .zero
        let limits: ((Float, Float), (Float, Float)?) = (
            (minSizeLimit.x, minSizeLimit.y),
            windowOptions?.maxSize.map { ($0.x, $0.y) }
        )
        vp = runtime.viewport
        if runtime.fitHeight {
            let fitted = WindowFrame.clampSize((vp.x, runtime.contentHeight()), min: limits.0, max: limits.1)
            runtime.setViewport(Vec2(fitted.0, fitted.1), pixelScale: args.pixelScale)
            vp = runtime.viewport
        }
        initialPublishedRun.size = vp

        let surfaceW = max(1, Int((vp.x * args.pixelScale).rounded()))
        let surfaceH = max(1, Int((vp.y * args.pixelScale).rounded()))

        #if canImport(Metal)
        let metalRenderer: MetalRenderer? = args.forceCPU ? nil : (try? MetalRenderer())
        func captureFrame(at now: Double) -> (refScene: RefScene?, renderFrame: RenderFrame?) {
            if metalRenderer != nil {
                return (nil, runtime.renderFrame(at: now))
            }
            return (runtime.frame(at: now), nil)
        }
        func renderCaptured(_ cap: (refScene: RefScene?, renderFrame: RenderFrame?)) throws -> Frame {
            if let gpu = metalRenderer, let rf = cap.renderFrame {
                return try gpu.renderOffscreen(rf)
            }
            return try RuneRef.render(cap.refScene ?? runtime.frame(at: runtime.currentTime))
        }
        let devKey = metalRenderer.map { DeviceKey(rawValue: $0.device.registryID) } ?? DeviceKey(rawValue: 0)
        #else
        func captureFrame(at now: Double) -> (refScene: RefScene?, renderFrame: RenderFrame?) {
            (runtime.frame(at: now), nil)
        }
        func renderCaptured(_ cap: (refScene: RefScene?, renderFrame: RenderFrame?)) throws -> Frame {
            return try RuneRef.render(cap.refScene!)
        }
        let devKey = DeviceKey(rawValue: 0)
        #endif

        func renderAndReport(_ cap: (refScene: RefScene?, renderFrame: RenderFrame?), at now: Double, reportEncoded: Bool = true) throws -> Frame {
            let commitsBefore = runtime.viewCommitCount
            var rendered: Frame? = nil
            var drawCount = 0
            if let comp = compositor {
                #if canImport(Metal)
                let compFrame = CompositorFrame<State>(
                    deviceKey: devKey,
                    pixelSize: (surfaceW, surfaceH),
                    dt: 1.0 / 60.0,
                    updateMilliseconds: 0.0,
                    srgbBlend: runtime.srgbBlend,
                    runtime: runtime,
                    device: metalRenderer?.device,
                    commandQueue: metalRenderer?.commandQueue,
                    pixelFormat: runtime.srgbBlend ? .bgra8Unorm : .bgra8Unorm_srgb,
                    renderer: metalRenderer,
                    drawUI: {
                        drawCount += 1
                        rendered = try? renderCaptured(cap)
                    }
                )
                #else
                let compFrame = CompositorFrame<State>(
                    deviceKey: devKey,
                    pixelSize: (surfaceW, surfaceH),
                    dt: 1.0 / 60.0,
                    updateMilliseconds: 0.0,
                    srgbBlend: runtime.srgbBlend,
                    runtime: runtime,
                    drawUI: {
                        drawCount += 1
                        rendered = try? renderCaptured(cap)
                    }
                )
                #endif
                comp.render(frame: compFrame)
                if !comp.drawsOwnContent && compFrame.uiDrawCount == 0 {
                    compFrame.drawUI()
                }
            }
            let outFrame = try rendered ?? {
                drawCount = 1
                return try renderCaptured(cap)
            }()
            if reportEncoded, let reports {
                let primCount = cap.renderFrame?.instances.count ?? cap.refScene?.primitives.count ?? 0
                let glyphCount: Int
                if let rf = cap.renderFrame {
                    glyphCount = rf.instances.count(where: { $0.params.y == KIND_GLYPH })
                } else if let rs = cap.refScene {
                    glyphCount = rs.primitives.count(where: { $0.kind == .glyph })
                } else {
                    glyphCount = 0
                }
                let encoded = FrameEncoded(
                    outcome: .drawn,
                    frameMs: 0.0,
                    updateMs: 0.0,
                    encodeMs: 0.0,
                    committed: runtime.viewCommitCount != commitsBefore,
                    primitives: primCount,
                    glyphs: glyphCount,
                    animating: runtime.isAnimating,
                    compositorAnimating: compositor?.isAnimating ?? false,
                    drawCount: drawCount,
                    compositorSummary: compositor?.summary(),
                    at: now,
                    window: reports.windowKey ?? windowKey,
                    started: now,
                    refreshHz: args.fps
                )
                reports.record(encoded)
                runtime.updateIf(at: now) { s, tx in
                    reports.flush(state: &s, tx: &tx, at: now, force: true)
                }
                reports.inspect(runtime)
            }
            return outFrame
        }

        // Collect script marks and resolve `--at mark:...` / `--start mark:...`
        var marks: [String: Double] = [:]
        for step in steps {
            if case .mark(let name) = step.action, !name.isEmpty {
                marks[name] = step.t
            }
        }
        let resolvedAtTime: Double? = try {
            if let expr = args.atMarkExpr {
                return try ToolingArgs.resolveMarkTime(expr, marks: marks)
            }
            if let m = args.atMark {
                guard let base = marks[m.name] else {
                    throw ToolingError.unknownMark(name: m.name, known: Array(marks.keys).sorted())
                }
                return max(0.0, base + m.offset)
            }
            return args.atTime
        }()
        let resolvedStartTime: Double = try {
            if let expr = args.startMarkExpr {
                return try ToolingArgs.resolveMarkTime(expr, marks: marks)
            }
            if let m = args.startMark {
                guard let base = marks[m.name] else {
                    throw ToolingError.unknownMark(name: m.name, known: Array(marks.keys).sorted())
                }
                return max(0.0, base + m.offset)
            }
            return args.startTime
        }()

        if args.hasPlayground {
            let pg = playgroundHost ?? runtime.playgroundHost
            if pg == nil && spec.scenes.isEmpty {
                throw ToolingError.playgroundNotConfigured
            }
            if let pg, pg.stories.isEmpty && pg.liveSpec.orderedPages.isEmpty && spec.scenes.isEmpty {
                throw ToolingError.playgroundNotConfigured
            }
            _ = try PlaygroundAttach.attach(
                runtime: runtime,
                host: pg,
                scenes: spec.scenes,
                sceneOrder: spec.sceneOrder,
                makeState: spec.makeState,
                open: args.playgroundName,
                openRequested: true,
                variant: args.playgroundVariant,
                windowed: false
            )
        }

        let dumpDir = args.outDir ?? args.framesDir
        let videoEncoder: ToolingVideoEncoder? = try args.videoPath.map {
            try ToolingVideoEncoder(outputPath: $0, width: surfaceW, height: surfaceH, fps: args.fps)
        }
        let traceWriter: ToolingTraceWriter? = args.tracePath.map {
            ToolingTraceWriter(path: $0, viewport: vp, fps: args.fps, scale: args.pixelScale, traceAll: args.traceAll)
        }
        let chromeLights: [[Float]]? = args.chromeOverlay ? chrome.trafficLightRects() : nil
        var screencastKeycaps = Keycaps()
        var pointerRipples: [(x: Float, y: Float, t: Double)] = []
        func applyChromeOverlay(_ frame: Frame, at simT: Double = runtime.currentTime) -> Frame {
            var out = frame
            if let lights = chromeLights {
                out = Self.paintTrafficLights(out, scale: args.pixelScale, lights: lights)
            }
            if args.showPointer {
                out = Self.paintPointerRipples(out, scale: args.pixelScale, presses: pointerRipples, at: simT)
            }
            if let corner = args.keysCorner {
                let caps = screencastKeycaps.visible(at: simT)
                if !caps.isEmpty {
                    let darkCaps = args.keysThemeDark ?? runtime.backdropDark() ?? isDark
                    out = Self.paintKeycapsOverlay(out, scale: args.pixelScale, caps: caps, corner: corner, dark: darkCaps)
                }
            }
            return out
        }

        // Initial settled frame at t = 0 (or `--at` if specified)
        var windowFrameMove: WindowFrameMove? = nil
        var currentOuterFrame: [Float] = [0, 0, vp.x, vp.y]
        var scriptedResizeFrom: Vec2 = vp
        func stepWindowFrame(at now: Double) {
            if case .moving(let anim, _, _) = windowFrameMove {
                let (pos, _) = anim.sample(at: now)
                let snapped = WindowFrame.snap(pos, scale: args.pixelScale)
                let w = max(1.0, snapped[2])
                let h = max(1.0, snapped[3])
                currentOuterFrame = [snapped[0], snapped[1], w, h]
                runtime.stepViewport(Vec2(w, h), pixelScale: args.pixelScale)
                if anim.isDone(at: now) {
                    windowFrameMove = nil
                }
            }
        }
        func applyPendingWindowFrame(at now: Double) {
            guard let req = runtime.takeWindowFrameRequest() else { return }
            guard let reqSize = req.size else { return }
            let clamped = WindowFrame.clampSize(reqSize, min: limits.0, max: limits.1)
            let from: [Float] = [0, 0, runtime.viewport.x, runtime.viewport.y]
            let snappedTarget = WindowFrame.snap([0, 0, clamped.0, clamped.1], scale: args.pixelScale)
            if req.animate, let spring = req.spring {
                let prev = WindowFrameMove.takeMoving(&windowFrameMove)
                let anim = WindowFrameAnim.retarget(
                    previous: prev,
                    spring: spring,
                    now: now,
                    from: from,
                    to: snappedTarget
                )
                windowFrameMove = .moving(anim, origin: (0, 0))
            } else {
                currentOuterFrame = snappedTarget
                windowFrameMove = nil
                runtime.stepViewport(
                    Vec2(max(1.0, snappedTarget[2]), max(1.0, snappedTarget[3])),
                    pixelScale: args.pixelScale
                )
            }
        }

        let initialT = (resolvedAtTime ?? 0.0) * args.timeScale
        var lastCaptured = captureFrame(at: initialT)
        if runtime.hasPendingWindowFrame {
            _ = runtime.takeFitWindowHeld()
            applyPendingWindowFrame(at: initialT)
        }
        if runtime.viewport != vp {
            lastCaptured = captureFrame(at: initialT)
        }
        var capturedStripFrames: [Frame] = []
        var dumpedFrameCount = 0
        var didFireReady = false
        var lastRenderedLoopFrame: Frame? = nil

        let needsLoop = !steps.isEmpty
            || resolvedAtTime != nil
            || args.durationOverride != nil
            || args.durationAuto
            || args.frameCount != nil
            || (resolvedAtTime ?? 0.0) > 0.0
            || dumpDir != nil
            || args.stripPath != nil
            || args.tracePath != nil
            || args.videoPath != nil
        var reportedInLoop = false

        if needsLoop {
            let fps = max(1.0, args.fps)
            let dt = 1.0 / fps
            let startFrame = max(0, Int((resolvedStartTime * fps).rounded()))
            let lastEventTime = steps.last?.t ?? 0.0
            let endMarkOrTail = marks["end"] ?? (lastEventTime + 1.0)
            let autoFrameCount = max(0, Int((endMarkOrTail * fps).rounded()) - startFrame) + 1
            let hasOutput = dumpDir != nil || args.videoPath != nil
            let targetOutputFrames: Int? = {
                if let n = args.frameCount { return n }
                if let d = args.durationOverride { return max(1, Int((d * fps).rounded())) }
                if args.durationAuto || hasOutput { return autoFrameCount }
                return nil
            }()
            let snapT: Double = resolvedAtTime ?? {
                if let count = targetOutputFrames, count > 0 {
                    return Double(startFrame + count - 1) * dt
                }
                return steps.isEmpty ? 0.0 : (lastEventTime + 1.0)
            }()
            let snapFrame = max(0, Int((snapT * fps).rounded()))
            let lastOutputFrame = targetOutputFrames.map { startFrame + max(1, $0) - 1 } ?? 0
            let lastFrame = max(snapFrame, lastOutputFrame)
            initialPublishedRun.start = resolvedStartTime
            initialPublishedRun.frames = targetOutputFrames ?? max(1, lastFrame + 1)
            initialPublishedRun.end = endMarkOrTail
            let maxSimTime = Double(lastFrame) * dt + dt * 0.25

            var simStep = 0
            var simTime: Double = 0.0
            var stepCursor = 0
            var anchorPos = Vec2(vp.x * 0.5, vp.y * 0.5)
            var frameIndex = 0
            let stripStride = args.stripEvery ?? max(1, Int(fps / 12.0))
            let wallStart = Date()

            if let dumpDir {
                try FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true)
            }

            while simTime <= maxSimTime || (targetOutputFrames != nil && dumpedFrameCount < (targetOutputFrames ?? 0)) {
                if args.realtime {
                    let ahead = simTime - Date().timeIntervalSince(wallStart)
                    if ahead > 0 {
                        Thread.sleep(forTimeInterval: ahead)
                    }
                }
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
                        pointerRipples.append((resolvedPos.x, resolvedPos.y, simTime))
                        runtime.pointerDown(at: resolvedPos, button: btn, mods: mods, at: animNow)
                    case let .up(btn, mods):
                        runtime.pointerUp(at: resolvedPos, button: btn, mods: mods, at: animNow)
                    case .keyDown(let kev):
                        screencastKeycaps.key(at: s.t, event: kev)
                        runtime.keyDown(kev, at: animNow)
                    case .keyRepeat(let kev):
                        screencastKeycaps.key(at: s.t, event: kev)
                        runtime.keyDown(kev, isRepeat: true, at: animNow)
                    case .keyUp(let kev):
                        _ = runtime.keyUp(kev, at: animNow)
                    case .physical(let phys):
                        if case let .key(code, physMods, true, _) = phys {
                            if let mappedKey = Self.keyForPhysicalCode(code, mods: physMods) {
                                screencastKeycaps.key(at: s.t, event: KeyEvent(key: mappedKey, mods: physMods))
                            }
                        }
                        _ = runtime.physicalInput(phys, at: animNow)
                    case let .physicalKey(phys, fallback, baseChar):
                        screencastKeycaps.key(at: s.t, event: fallback)
                        _ = runtime.physicalInput(phys, fallbackKey: fallback, baseChar: baseChar, at: animNow)
                    case .shortcut(let chord):
                        let sev = KeyEvent(key: chord.key, mods: chord.mods)
                        screencastKeycaps.key(at: s.t, event: sev)
                        if runtime.activeModalPath == nil, let registry = runtime.shortcutRegistry {
                            if registry.dispatch(sev) != .unhandled {
                                runtime.dirtyCommit(at: animNow)
                            }
                        }
                    case .paste(let clip):
                        runtime.paste(clip, at: animNow)
                    case .ime(let imeEv):
                        _ = runtime.dispatchIme(imeEv, at: animNow)
                    case .wheel(let wev):
                        runtime.wheel(wev, at: resolvedPos, now: animNow)
                    case .magnify(let mev):
                        runtime.magnify(mev, at: resolvedPos, now: animNow)
                    case let .fling(vx, vy):
                        runtime.fling(vx: vx, vy: vy, at: resolvedPos, now: animNow)
                    case .resize(let newVP):
                        windowFrameMove = nil
                        scriptedResizeFrom = newVP
                        currentOuterFrame = [currentOuterFrame[0], currentOuterFrame[1], newVP.x, newVP.y]
                        runtime.setViewport(newVP, pixelScale: args.pixelScale)
                    case let .resizeDelta(dw, dh):
                        if dw == 0.0 && dh == 0.0 {
                            scriptedResizeFrom = runtime.viewport
                        }
                        let nextVP = Vec2(
                            max(1.0, scriptedResizeFrom.x + dw),
                            max(1.0, scriptedResizeFrom.y + dh)
                        )
                        windowFrameMove = nil
                        currentOuterFrame = [currentOuterFrame[0], currentOuterFrame[1], nextVP.x, nextVP.y]
                        runtime.setViewport(nextVP, pixelScale: args.pixelScale)
                    case .windowFocus(let foc):
                        runtime.windowFocused = foc
                    case .mark(let markName):
                        if args.realtime {
                            print("rune-mark \(markName) \(s.t)")
                            #if canImport(Darwin)
                            Darwin.fflush(stdout)
                            #elseif canImport(Glibc)
                            Glibc.fflush(stdout)
                            #endif
                        }
                    case .reopen:
                        _ = runtime.dispatchReopen(hasVisibleWindows: true, at: animNow)
                    case .openUrl(let url):
                        runtime.dispatchOpenUrl(url, at: animNow)
                    case .dragFiles(let urls):
                        runtime.dragFiles(urls, at: resolvedPos, at: animNow)
                    case .dropFiles(let urls):
                        runtime.dropFiles(urls, at: resolvedPos, at: animNow)
                    case .dragFilesLeave:
                        runtime.fileDrop(.exited, at: animNow)
                    case .popupPick(let id):
                        try? runtime.resolvePopup(id)
                    case .fileDialogAnswer(let url):
                        if let pending = runtime.takeFileDialog() {
                            runtime.answerFileDialog(pending.id, .success(url))
                        }
                    }
                }

                let animNow = simTime * args.timeScale
                _ = appShared?.applyStateUpdates(to: runtime, at: animNow)
                stepWindowFrame(at: animNow)
                runtime.windowResting = (windowFrameMove == nil && !runtime.hasPendingWindowFrame)
                let frameClockStart = Date()
                lastCaptured = captureFrame(at: animNow)
                if runtime.hasPendingWindowFrame {
                    let shown = (frameIndex == 0 || runtime.takeFitWindowHeld()) ? 0.0 : (dt * args.timeScale)
                    applyPendingWindowFrame(at: animNow - shown)
                }
                let frameCpuMs = Date().timeIntervalSince(frameClockStart) * 1000.0
                traceWriter?.recordFrame(runtime: runtime, tMs: simTime * 1000.0, cpuMs: frameCpuMs)

                if args.realtime && !didFireReady {
                    didFireReady = true
                    onReady?(WindowHandle(key: windowKey))
                }

                if simTime + 1e-6 >= resolvedStartTime {
                    if let targetCount = targetOutputFrames, dumpedFrameCount >= targetCount {
                        break
                    }
                    let needDump = dumpDir != nil
                    let needVideo = videoEncoder != nil
                    let needStrip = args.stripPath != nil && (frameIndex % stripStride == 0)
                    let hasFrameObservers = compositor != nil
                        || (reports?.wanted ?? false)
                        || (reports?.onFrameDrawn != nil)
                        || (reports?.onInspectDrawn != nil)
                    let needRender = needDump || needVideo || needStrip || (args.frameCount != nil && hasFrameObservers)
                    if needRender {
                        let renderedBase = try renderAndReport(lastCaptured, at: animNow, reportEncoded: true)
                        reportedInLoop = true
                        let baseFrame = applyChromeOverlay(renderedBase, at: simTime)
                        lastRenderedLoopFrame = baseFrame
                        if needVideo {
                            try videoEncoder?.writeFrame(baseFrame)
                        }
                        var f = baseFrame
                        if !args.cropRects.isEmpty {
                            f = tileCrops(f, cropRectsPt: args.cropRects, scale: args.pixelScale)
                        }
                        if let dumpDir {
                            let outURL = URL(fileURLWithPath: dumpDir).appendingPathComponent(String(format: "frame_%04d.png", frameIndex))
                            try f.writePNG(to: outURL)
                            dumpedFrameCount += 1
                        } else if needVideo || targetOutputFrames != nil {
                            dumpedFrameCount += 1
                        }
                        if needStrip {
                            capturedStripFrames.append(f)
                        }
                    } else {
                        if reports != nil {
                            _ = try renderAndReport(lastCaptured, at: animNow, reportEncoded: true)
                            reportedInLoop = true
                        }
                        if targetOutputFrames != nil {
                            dumpedFrameCount += 1
                        }
                    }
                    frameIndex += 1
                }

                let explicitLengthRequested = args.durationAuto
                    || args.durationOverride != nil
                    || resolvedAtTime != nil
                    || args.frameCount != nil
                    || hasOutput
                    || args.tracePath != nil
                if !explicitLengthRequested && stepCursor >= steps.count && !runtime.isAnimating && windowFrameMove == nil && simTime >= lastEventTime + dt {
                    break
                }
                if let targetCount = targetOutputFrames, dumpedFrameCount >= targetCount {
                    break
                }
                simStep += 1
                simTime = Double(simStep) * dt
            }
        } else if args.realtime && !didFireReady {
            didFireReady = true
            onReady?(WindowHandle(key: windowKey))
        }

        var finalFrame = if let lastRenderedLoopFrame {
            lastRenderedLoopFrame
        } else {
            applyChromeOverlay(
                try renderAndReport(lastCaptured, at: runtime.currentTime, reportEncoded: !reportedInLoop),
                at: runtime.currentTime
            )
        }
        if args.firstPixels {
            FileHandle.standardError.write(Data("rune: first pixels \(finalFrame.width)x\(finalFrame.height)\n".utf8))
        }
        if !args.cropRects.isEmpty {
            finalFrame = tileCrops(finalFrame, cropRectsPt: args.cropRects, scale: args.pixelScale)
        } else if let cropKey = args.cropKey {
            if args.hasPlayground && !args.wholeWindow {
                let all = runtime.elements()
                if let idx = Runtime<State>.stageElementIndex(in: all, key: cropKey) {
                    finalFrame = cropFrame(finalFrame, rectPt: all[idx].rect, scale: args.pixelScale)
                }
            } else if let elInfo = runtime.element(byKey: cropKey) {
                finalFrame = cropFrame(finalFrame, rectPt: elInfo.rect, scale: args.pixelScale)
            }
        } else if args.hasPlayground && !args.wholeWindow,
                  let stageEl = runtime.elements().first(where: { Runtime<State>.isPlaygroundStageKey($0.key) }) {
            finalFrame = cropFrame(finalFrame, rectPt: stageEl.rect, scale: args.pixelScale)
        }
        let chromeOverlaps: [String] = chromeLights.map {
            Self.findTrafficLightOverlaps(runtime: runtime, lights: $0)
        } ?? []
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
            let useGutter = (frames.count > args.stripCols) || !args.cropRects.isEmpty
            let strip = stitchGridStrip(frames: frames, cols: args.stripCols, gap: useGutter ? 4 : 0)
            try strip.writePNG(to: URL(fileURLWithPath: stripPath))
        }
        try traceWriter?.finish()
        try videoEncoder?.finish()
        // Headless runs open no links (`Tx::open_url`): say which URLs handlers asked to open.
        for req in runtime.urlOpener.takeRequests() {
            FileHandle.standardError.write(Data("rune: open_url \(req.url) (headless: not opened)\n".utf8))
        }

        return Output(
            finalFrame: finalFrame,
            treeJSON: treeData,
            frameCount: dumpedFrameCount,
            marks: marks,
            windowKeys: [windowKey],
            tracePath: args.tracePath,
            videoPath: args.videoPath,
            chromeOverlaps: chromeOverlaps
        )
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

    private static func tileCrops(_ frame: Frame, cropRectsPt: [[Float]], scale: Float, gap: Int = 4) -> Frame {
        let cropped = cropRectsPt.map { cropFrame(frame, rectPt: $0, scale: scale) }
        guard !cropped.isEmpty else { return frame }
        if cropped.count == 1 { return cropped[0] }
        let tw = cropped.map(\.width).max() ?? frame.width
        let th = cropped.map(\.height).reduce(0, +) + gap * (cropped.count - 1)
        var out = [UInt8](repeating: 0, count: tw * th * 4)
        for idx in stride(from: 0, to: out.count, by: 4) {
            out[idx] = 128; out[idx + 1] = 128; out[idx + 2] = 128; out[idx + 3] = 255
        }
        var oy = 0
        for part in cropped {
            for row in 0..<part.height {
                let srcStart = row * part.width * 4
                let dstStart = ((oy + row) * tw) * 4
                out.replaceSubrange(dstStart..<(dstStart + part.width * 4), with: part.rgba[srcStart..<(srcStart + part.width * 4)])
            }
            oy += part.height + gap
        }
        return Frame(width: tw, height: th, rgba: out)
    }

    private static func stitchGridStrip(frames: [Frame], cols: Int, gap: Int) -> Frame {
        guard let first = frames.first else {
            return Frame(width: 1, height: 1, rgba: [0, 0, 0, 255])
        }
        let w = first.width
        let h = first.height
        let colCount = max(1, min(frames.count, cols))
        let rowCount = (frames.count + colCount - 1) / colCount
        let totalW = colCount * w + max(0, colCount - 1) * gap
        let totalH = rowCount * h + max(0, rowCount - 1) * gap
        var out = [UInt8](repeating: 0, count: totalW * totalH * 4)
        if gap > 0 {
            for idx in stride(from: 0, to: out.count, by: 4) {
                out[idx] = 128; out[idx + 1] = 128; out[idx + 2] = 128; out[idx + 3] = 255
            }
        }
        for (idx, frame) in frames.enumerated() where frame.width == w && frame.height == h {
            let cx = (idx % colCount) * (w + gap)
            let cy = (idx / colCount) * (h + gap)
            for row in 0..<h {
                let srcStart = row * w * 4
                let dstStart = ((cy + row) * totalW + cx) * 4
                out.replaceSubrange(dstStart..<(dstStart + w * 4), with: frame.rgba[srcStart..<(srcStart + w * 4)])
            }
        }
        return Frame(width: totalW, height: totalH, rgba: out)
    }

    private static func paintTrafficLights(_ frame: Frame, scale: Float, lights: [[Float]]) -> Frame {
        guard lights.count >= 3 else { return frame }
        var px = frame.rgba
        let w = frame.width
        let h = frame.height
        let colors: [[Float]] = [
            [255.0, 95.0, 87.0],
            [254.0, 188.0, 46.0],
            [40.0, 200.0, 64.0],
        ]
        func blend(_ x: Int, _ y: Int, _ c: [Float], _ a: Float) {
            guard x >= 0, y >= 0, x < w, y < h, a > 0 else { return }
            let i = (y * w + x) * 4
            for k in 0..<3 {
                let blended = Float(px[i + k]) * (1.0 - a) + c[k] * a
                px[i + k] = UInt8(max(0, min(255, Int(blended.rounded()))))
            }
        }
        for (r, c) in zip(lights, colors) where r.count == 4 {
            let cx = (r[0] + r[2] * 0.5) * scale
            let cy = (r[1] + r[3] * 0.5) * scale
            let rad = (r[2] * 0.5) * scale
            for y in Int((cy - rad - 1.0).rounded(.down))...Int((cy + rad + 1.0).rounded(.up)) {
                for x in Int((cx - rad - 1.0).rounded(.down))...Int((cx + rad + 1.0).rounded(.up)) {
                    let dx = Float(x) + 0.5 - cx
                    let dy = Float(y) + 0.5 - cy
                    let dist = sqrt(dx * dx + dy * dy)
                    let alpha = max(0.0, min(1.0, rad - dist + 0.5))
                    blend(x, y, c, alpha)
                }
            }
        }
        let m: Float = 4.0
        let x0 = Int(((lights[0][0] - m) * scale).rounded(.down))
        let y0 = Int(((lights[0][1] - m) * scale).rounded(.down))
        let x1 = Int(((lights[2][0] + lights[2][2] + m) * scale).rounded(.up))
        let y1 = Int(((lights[2][1] + lights[2][3] + m) * scale).rounded(.up))
        let cyan: [Float] = [0.0, 200.0, 255.0]
        if x0 <= x1 {
            for x in x0...x1 {
                blend(x, y0, cyan, 0.8)
                blend(x, y1, cyan, 0.8)
            }
        }
        if y0 <= y1 {
            for y in y0...y1 {
                blend(x0, y, cyan, 0.8)
                blend(x1, y, cyan, 0.8)
            }
        }
        return Frame(width: w, height: h, rgba: px)
    }

    private static func findTrafficLightOverlaps<State>(runtime: Runtime<State>, lights: [[Float]]) -> [String] {
        guard lights.count >= 3 else { return [] }
        let m: Float = 4.0
        let zx0 = lights[0][0] - m
        let zy0 = lights[0][1] - m
        let zx1 = lights[2][0] + lights[2][2] + m
        let zy1 = lights[2][1] + lights[2][3] + m
        var overlaps: [String] = []
        for e in runtime.elements() {
            let drawn = e.text != nil || e.role == .icon || e.role == .button || e.role == .textInput
            let v = e.visible
            guard drawn, e.opacity > 0.01, v.count == 4, v[2] > 0.0, v[3] > 0.0 else { continue }
            if v[0] < zx1 && (v[0] + v[2]) > zx0 && v[1] < zy1 && (v[1] + v[3]) > zy0 {
                overlaps.append(e.key ?? e.path)
                FileHandle.standardError.write(Data("rune: chrome: \(e.path) overlaps the traffic lights at \(v)\n".utf8))
            }
        }
        return overlaps
    }

    internal static func headlessEvents(from steps: [ScriptStep]) -> [HeadlessTimedEvent] {
        steps.map(headlessEvent(from:))
    }

    private static func headlessEvent(from step: ScriptStep) -> HeadlessTimedEvent {
        let pos: HeadlessScriptPoint
        switch step.position {
        case .key(let k): pos = .key(k)
        case .xy(let x, let y): pos = .xy(x, y)
        case .relative(let dx, let dy): pos = .relative(dx, dy)
        }
        let ev: HeadlessScriptEvent
        switch step.action {
        case .move: ev = .pointer(.move)
        case let .down(btn, mods): ev = .pointer(.down, button: btn, mods: mods)
        case let .up(btn, mods): ev = .pointer(.up, button: btn, mods: mods)
        case .keyDown(let kev), .keyRepeat(let kev): ev = .keyDown(kev)
        case .keyUp(let kev): ev = .keyUp(kev)
        case let .physicalKey(_, kev, _): ev = .keyDown(kev)
        case let .physical(.key(code, mods, pressed, _)):
            let k = keyForPhysicalCode(code, mods: mods) ?? .text("")
            ev = pressed ? .keyDown(KeyEvent(key: k, mods: mods)) : .keyUp(KeyEvent(key: k, mods: mods))
        case .physical: ev = .mark("physical")
        case .shortcut(let chord): ev = .shortcut(chord.description)
        case .paste(let c): ev = .paste(c.text)
        case .ime: ev = .mark("ime")
        case .wheel(let w): ev = .wheel(dx: w.dx, dy: w.dy, mods: w.mods)
        case .magnify: ev = .mark("magnify")
        case let .fling(vx, vy): ev = .fling(vx: vx, vy: vy)
        case .resize(let sz): ev = .resize(sz)
        case let .resizeDelta(dw, dh): ev = .resize(Vec2(dw, dh))
        case .windowFocus(let foc): ev = .focus(foc)
        case .mark(let m): ev = .mark(m)
        case .reopen: ev = .reopen
        case .openUrl(let u): ev = .openURL(u)
        case .dragFiles(let urls):
            let dropAt: Vec2 = if case let .xy(x, y) = step.position { Vec2(x, y) } else { .zero }
            ev = .fileDrop(.entered(urls.map { DroppedFile(url: $0) }, at: dropAt))
        case .dropFiles(let urls):
            let dropAt: Vec2 = if case let .xy(x, y) = step.position { Vec2(x, y) } else { .zero }
            ev = .fileDrop(.dropped(urls.map { DroppedFile(url: $0) }, at: dropAt))
        case .dragFilesLeave: ev = .fileDrop(.exited)
        case .popupPick(let id): ev = .popupMenu(id)
        case .fileDialogAnswer(let u): ev = .fileDialog(u?.path)
        }
        return HeadlessTimedEvent(t: step.t, position: pos, event: ev)
    }

    private static func keyForPhysicalCode(_ code: PhysicalKeyCode, mods: Mods) -> Key? {
        switch code {
        case .space: return .space
        case .enter: return .enter
        case .tab: return .tab
        case .escape: return .escape
        case .backspace: return .backspace
        case .delete: return .delete
        case .arrowLeft: return .arrowLeft
        case .arrowRight: return .arrowRight
        case .arrowUp: return .arrowUp
        case .arrowDown: return .arrowDown
        case .home: return .home
        case .end: return .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .f1: return .f(1); case .f2: return .f(2); case .f3: return .f(3); case .f4: return .f(4)
        case .f5: return .f(5); case .f6: return .f(6); case .f7: return .f(7); case .f8: return .f(8)
        case .f9: return .f(9); case .f10: return .f(10); case .f11: return .f(11); case .f12: return .f(12)
        case .keyA: return mods.cmd ? .command("a") : .text("a")
        case .digit0: return .text("0"); case .digit1: return .text("1"); case .digit2: return .text("2")
        case .digit3: return .text("3"); case .digit4: return .text("4"); case .digit5: return .text("5")
        case .digit6: return .text("6"); case .digit7: return .text("7"); case .digit8: return .text("8")
        case .digit9: return .text("9")
        default: return nil
        }
    }

    private static func paintPointerRipples(
        _ frame: Frame,
        scale: Float,
        presses: [(x: Float, y: Float, t: Double)],
        at now: Double
    ) -> Frame {
        let active = presses.filter { now >= $0.t - 1e-6 && (now - $0.t) <= 0.35 }
        guard !active.isEmpty else { return frame }
        var px = frame.rgba
        let w = frame.width
        let h = frame.height
        for p in active {
            let age = Float(max(0.0, min(1.0, (now - p.t) / 0.35)))
            let cx = p.x * scale
            let cy = p.y * scale
            let outerR = (8.0 + 18.0 * age) * scale
            let innerR = max(0.0, outerR - 2.5 * scale)
            let alpha = (1.0 - age) * 0.72
            let minX = max(0, Int((cx - outerR - 1).rounded(.down)))
            let maxX = min(w - 1, Int((cx + outerR + 1).rounded(.up)))
            let minY = max(0, Int((cy - outerR - 1).rounded(.down)))
            let maxY = min(h - 1, Int((cy + outerR + 1).rounded(.up)))
            guard minX <= maxX, minY <= maxY else { continue }
            for y in minY...maxY {
                for x in minX...maxX {
                    let dx = Float(x) + 0.5 - cx
                    let dy = Float(y) + 0.5 - cy
                    let dist = sqrt(dx * dx + dy * dy)
                    if dist >= innerR && dist <= outerR {
                        let edge = min(1.0, min(outerR - dist + 0.5, dist - innerR + 0.5))
                        let a = max(0.0, min(1.0, alpha * edge))
                        let idx = (y * w + x) * 4
                        px[idx] = UInt8(max(0, min(255, Int((Float(px[idx]) * (1 - a) + 96.0 * a).rounded()))))
                        px[idx + 1] = UInt8(max(0, min(255, Int((Float(px[idx + 1]) * (1 - a) + 178.0 * a).rounded()))))
                        px[idx + 2] = UInt8(max(0, min(255, Int((Float(px[idx + 2]) * (1 - a) + 255.0 * a).rounded()))))
                    }
                }
            }
        }
        return Frame(width: w, height: h, rgba: px)
    }

    private static func paintKeycapsOverlay(
        _ frame: Frame,
        scale: Float,
        caps: [Keycap],
        corner: KeycapsCorner,
        dark: Bool
    ) -> Frame {
        guard !caps.isEmpty else { return frame }
        var px = frame.rgba
        let w = frame.width
        let h = frame.height
        let marginPx = Int((16.0 * scale).rounded())
        let gapPx = Int((8.0 * scale).rounded())
        let pillH = max(12, Int((26.0 * scale).rounded()))
        let widths: [Int] = caps.map { cap in
            max(Int((28.0 * scale).rounded()), Int((Float(cap.label.count * 10 + 18) * scale).rounded()))
        }
        let totalW = widths.reduce(0, +) + max(0, widths.count - 1) * gapPx
        let startY: Int
        switch corner {
        case .topLeft, .top, .topRight:
            startY = min(max(0, marginPx), max(0, h - pillH))
        case .bottomLeft, .bottom, .bottomRight:
            startY = max(0, h - marginPx - pillH)
        }
        var curX: Int
        switch corner {
        case .topLeft, .bottomLeft:
            curX = min(max(0, marginPx), max(0, w - totalW))
        case .top, .bottom:
            curX = max(0, (w - totalW) / 2)
        case .topRight, .bottomRight:
            curX = max(0, w - marginPx - totalW)
        }

        let fill: [Float] = dark ? [24.0, 26.0, 32.0] : [245.0, 246.0, 250.0]
        let border: [Float] = dark ? [88.0, 94.0, 110.0] : [188.0, 194.0, 208.0]
        let ink: [Float] = dark ? [240.0, 243.0, 250.0] : [26.0, 28.0, 34.0]
        let fillAlpha: Float = 0.88
        for (idx, pillW) in widths.enumerated() {
            let x0 = max(0, curX)
            let x1 = min(w - 1, curX + pillW - 1)
            let y0 = max(0, startY)
            let y1 = min(h - 1, startY + pillH - 1)
            if x0 <= x1 && y0 <= y1 {
                for y in y0...y1 {
                    for x in x0...x1 {
                        let isBorder = (x == x0 || x == x1 || y == y0 || y == y1)
                        let c = isBorder ? border : fill
                        let pIdx = (y * w + x) * 4
                        for k in 0..<3 {
                            let blended = Float(px[pIdx + k]) * (1.0 - fillAlpha) + c[k] * fillAlpha
                            px[pIdx + k] = UInt8(max(0, min(255, Int(blended.rounded()))))
                        }
                    }
                }
                let barY0 = min(y1, y0 + pillH / 2 - max(1, Int(scale.rounded())))
                let barY1 = min(y1, y0 + pillH / 2 + max(1, Int(scale.rounded())))
                let barX0 = min(x1, x0 + max(3, Int((6.0 * scale).rounded())))
                let barX1 = max(barX0, x1 - max(3, Int((6.0 * scale).rounded())))
                if barX0 <= barX1 && barY0 <= barY1 && idx < caps.count {
                    for y in barY0...barY1 {
                        for x in barX0...barX1 where ((x - barX0) / max(2, Int((2.0 * scale).rounded()))) % 2 == 0 {
                            let pIdx = (y * w + x) * 4
                            for k in 0..<3 {
                                px[pIdx + k] = UInt8(max(0, min(255, Int(ink[k].rounded()))))
                            }
                        }
                    }
                }
            }
            curX += pillW + gapPx
        }
        return Frame(width: w, height: h, rgba: px)
    }
}

public enum TraceClockMode: String, Sendable {
    case virtual
    case wall
}

/// Source reporting drawable presentation timestamps for trace timing (`frame::present_time::Source`).
public protocol TracePresentSource: AnyObject, Sendable {
    func take() -> [(seq: UInt64, atNs: UInt64?)]
}

/// Per-frame display target and drawable correlation metadata (`tooling::trace::FrameTiming`).
public struct TraceFrameTiming: Sendable, Equatable {
    public var targetMs: Double?
    public var drawable: UInt64?
    public var continuous: Bool

    public init(targetMs: Double? = nil, drawable: UInt64? = nil, continuous: Bool = false) {
        self.targetMs = targetMs
        self.drawable = drawable
        self.continuous = continuous
    }
}

/// Nearest-rank percentiles over a sample (`frame::present_time::Spread`).
public struct TracePresentSpread: Sendable, Equatable {
    public var p50: Double
    public var p95: Double
    public var max: Double

    public static func of(_ values: [Double]) -> TracePresentSpread? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func rank(_ p: Double) -> Double {
            let idx = Swift.max(1, Swift.min(sorted.count, Int((p * Double(sorted.count)).rounded(.up)))) - 1
            return sorted[idx]
        }
        return TracePresentSpread(p50: rank(0.5), p95: rank(0.95), max: sorted[sorted.count - 1])
    }
}

/// Summary of drawable present cadence in a wall-clock trace (`frame::present_time::Summary`).
public struct TracePresentSummary: Sendable, Equatable {
    public static let bunchedMs: Double = 2.0

    public var hz: Double
    public var frames: Int
    public var presented: Int
    public var skipped: Int
    public var interval: TracePresentSpread?
    public var bunched: Int
    public var missed: Int
    public var lag: TracePresentSpread?

    public static func ofTrace(_ text: String) -> TracePresentSummary? {
        var dicts: [[String: Any]] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let data = rawLine.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            dicts.append(obj)
        }
        guard let header = dicts.first else { return nil }
        let rawHz = (header["hz"] as? NSNumber)?.doubleValue
        let hz = (rawHz.map { $0 > 0 ? $0 : nil } ?? nil) ?? 60.0
        var frames = 0
        var presented = 0
        var skipped = 0
        var timed = false
        var intervals: [Double] = []
        var lags: [Double] = []
        for frame in dicts.dropFirst() where frame["t"] != nil {
            frames += 1
            guard let rawPresent = frame["present_ms"] else { continue }
            timed = true
            guard let presentNum = rawPresent as? NSNumber, !(rawPresent is NSNull) else {
                skipped += 1
                continue
            }
            let present = presentNum.doubleValue
            presented += 1
            if let dtNum = frame["present_dt_ms"] as? NSNumber, !(frame["present_dt_ms"] is NSNull) {
                intervals.append(dtNum.doubleValue)
            }
            if let targetNum = frame["target_ms"] as? NSNumber, !(frame["target_ms"] is NSNull) {
                lags.append(present - targetNum.doubleValue)
            }
        }
        guard timed else { return nil }
        let missedMs = 1.5 * 1000.0 / hz
        return TracePresentSummary(
            hz: hz,
            frames: frames,
            presented: presented,
            skipped: skipped,
            interval: TracePresentSpread.of(intervals),
            bunched: intervals.filter { $0 < bunchedMs }.count,
            missed: intervals.filter { $0 > missedMs }.count,
            lag: TracePresentSpread.of(lags)
        )
    }
}

private final class TracePresentsQueue {
    private static let waitFrames: UInt32 = 32

    private enum Present {
        case noDrawable
        case waiting(seq: UInt64)
        case landed(seq: UInt64, at: Double)
        case skipped(seq: UInt64)

        var seq: UInt64? {
            switch self {
            case .noDrawable: return nil
            case .waiting(let seq), .landed(let seq, _), .skipped(let seq): return seq
            }
        }
    }

    private struct Pending {
        var lineWithoutBrace: String
        var present: Present
        var continuous: Bool
        var age: UInt32
    }

    private enum Cadence {
        case broken
        case after(Double)
    }

    private let source: any TracePresentSource
    private let startNs: UInt64
    private var pending: [Pending] = []
    private var cadence: Cadence = .broken

    init(source: any TracePresentSource, startNs: UInt64) {
        self.source = source
        self.startNs = startNs
    }

    private static func r3(_ v: Double) -> Double {
        (v * 1000.0).rounded() / 1000.0
    }

    private static func msSince(startNs: UInt64, atNs: UInt64) -> Double {
        let diff = Int64(bitPattern: atNs) &- Int64(bitPattern: startNs)
        return r3(Double(diff) / 1_000_000.0)
    }

    func push(lineWithoutBrace: String, seq: UInt64?, continuous: Bool, into out: inout [String]) {
        for i in pending.indices {
            pending[i].age &+= 1
        }
        let present: Present = seq.map { .waiting(seq: $0) } ?? .noDrawable
        pending.append(Pending(lineWithoutBrace: lineWithoutBrace, present: present, continuous: continuous, age: 0))
        poll()
        writeReady(into: &out, all: false)
    }

    func flush(into out: inout [String]) {
        poll()
        writeReady(into: &out, all: true)
    }

    private func poll() {
        for (seq, atNs) in source.take() {
            guard let idx = pending.firstIndex(where: { $0.present.seq == seq }) else { continue }
            if let atNs {
                pending[idx].present = .landed(seq: seq, at: Self.msSince(startNs: startNs, atNs: atNs))
            } else {
                pending[idx].present = .skipped(seq: seq)
            }
        }
    }

    private func writeReady(into out: inout [String], all: Bool) {
        while let first = pending.first {
            let ready: Bool
            if all || first.age >= Self.waitFrames {
                ready = true
            } else if case .waiting = first.present {
                ready = false
            } else {
                ready = true
            }
            guard ready else { break }
            let item = pending.removeFirst()
            out.append(finishLine(item))
        }
    }

    private func finishLine(_ item: Pending) -> String {
        var line = item.lineWithoutBrace
        let last: Double?
        if case .after(let prev) = cadence, item.continuous {
            last = prev
        } else {
            last = nil
        }
        switch item.present {
        case .landed(_, let at):
            cadence = .after(at)
            line.append(",\"present_ms\":\(at)")
            if let last {
                line.append(",\"present_dt_ms\":\(Self.r3(at - last))")
            }
        case .skipped:
            cadence = .broken
            line.append(",\"present_ms\":null")
        case .noDrawable, .waiting:
            cadence = .broken
        }
        line.append("}")
        return line
    }
}

internal final class ToolingTraceWriter {
    private let path: String
    private let traceAll: Bool
    private var lines: [String] = []
    private var ids: [String: UInt32] = [:]
    private var described: [UInt32: (String, String, String, String)] = [:]
    private var states: [UInt32: [Int]] = [:]
    private var scrolled: [UInt32: [Int]] = [:]
    private var effects: [UInt32: [String]] = [:]
    private var goals: [UInt32: [Int64]] = [:]
    private var channels = TraceChannels()
    private var presents: TracePresentsQueue?

    convenience init(path: String, viewport: Vec2, fps: Double, scale: Float, traceAll: Bool) {
        self.init(path: path, viewport: viewport, fps: fps, scale: scale, traceAll: traceAll, clock: .virtual)
    }

    static func openClock(
        path: String,
        viewport: Vec2,
        fps: Double,
        scale: Float,
        traceAll: Bool = false,
        clock: TraceClockMode = .wall
    ) -> ToolingTraceWriter {
        ToolingTraceWriter(path: path, viewport: viewport, fps: fps, scale: scale, traceAll: traceAll, clock: clock)
    }

    init(path: String, viewport: Vec2, fps: Double, scale: Float, traceAll: Bool, clock: TraceClockMode) {
        self.path = path
        self.traceAll = traceAll
        var header: [String: Any] = [
            "type": "header",
            "launch": "rune",
            "width": viewport.x,
            "height": viewport.y,
            "hz": fps,
            "scale": scale,
            "platform": "rune",
            "units": "pt",
            "clock": clock.rawValue,
        ]
        if clock != .virtual {
            header["timestamp"] = "cpu-submit"
        }
        if let json = Self.encodeJSONLine(header) {
            lines.append(json)
        }
    }

    func recordPresents(source: any TracePresentSource, startNs: UInt64) {
        presents = TracePresentsQueue(source: source, startNs: startNs)
    }

    func recordFrame<State>(runtime: Runtime<State>, tMs: Double, cpuMs: Double) {
        frameTimed(runtime: runtime, tMs: tMs, cpuMs: cpuMs, timing: TraceFrameTiming())
    }

    func frameTimed<State>(runtime: Runtime<State>, tMs: Double, cpuMs: Double, timing: TraceFrameTiming = TraceFrameTiming()) {
        let els = runtime.elements()
        func isTraced(_ e: ElementInfo) -> Bool {
            (traceAll || e.key != nil || e.traceName != nil) && !e.virtualExtent
        }
        func idFor(_ path: String) -> UInt32 {
            if let existing = ids[path] { return existing }
            let next = UInt32(ids.count + 1)
            ids[path] = next
            return next
        }

        let blank = runtime.blankLeaves()
        var metas: [[String: Any]] = []
        var changed: [[Any]] = []
        var scrolledRows: [[Any]] = []
        var seen = Set<UInt32>()

        for e in els where isTraced(e) {
            let id = idFor(e.path)
            let name = e.traceName ?? e.path
            let cls = e.traceNamespace?.className ?? "rune"
            let host = e.traceNamespace?.host ?? "rune"
            seen.insert(id)
            if described[id] == nil
                || described[id]?.0 != name
                || described[id]?.1 != cls
                || described[id]?.2 != host
                || described[id]?.3 != e.role.rawValue {
                described[id] = (name, cls, host, e.role.rawValue)
                var meta: [String: Any] = [
                    "id": id,
                    "cls": cls,
                    "nm": name,
                    "host": host,
                    "role": e.role.rawValue,
                ]
                if let pIdx = e.parentIndex, els.indices.contains(pIdx), isTraced(els[pIdx]) {
                    meta["pv"] = idFor(els[pIdx].path)
                }
                metas.append(meta)
            }

            let effNames = ["\(name).scale", "\(name).blur"]
            channels.sample(name: effNames[0], kind: .position, value: e.scale)
            channels.owner(name: effNames[0], owner: id, unit: "ratio")
            channels.sample(name: effNames[1], kind: .position, value: e.blur)
            channels.owner(name: effNames[1], owner: id, unit: "pt")
            if let prevEff = effects.updateValue(effNames, forKey: id) {
                for oldName in prevEff where !effNames.contains(oldName) {
                    channels.remove(name: oldName)
                }
            }

            let r = e.rect.count == 4 ? e.rect : [Float](repeating: 0, count: 4)
            let v = e.visible.count == 4 ? e.visible : r
            let clipped = zip(r, v).contains { abs($0 - $1) > 0.5 }
            let flags = (e.moving ? Int(TraceFlags.animated) : 0)
                | (clipped ? Int(TraceFlags.clipped) : 0)
                | (blank.contains(e.path) ? Int(TraceFlags.blank) : 0)
            let q = [
                Int((Double(r[0]) * 100.0).rounded()),
                Int((Double(r[1]) * 100.0).rounded()),
                Int((Double(r[2]) * 100.0).rounded()),
                Int((Double(r[3]) * 100.0).rounded()),
                Int((Double(e.opacity) * 1000.0).rounded()),
                Int((Double(e.radius) * 100.0).rounded()),
                flags,
                Int((Double(v[0]) * 100.0).rounded()),
                Int((Double(v[1]) * 100.0).rounded()),
                Int((Double(v[2]) * 100.0).rounded()),
                Int((Double(v[3]) * 100.0).rounded()),
            ]
            if states[id] != q {
                states[id] = q
                var row: [Any] = [
                    id,
                    Self.r2(r[0]),
                    Self.r2(r[1]),
                    Self.r2(r[2]),
                    Self.r2(r[3]),
                    Self.r3(e.opacity),
                    Self.r2(e.radius),
                    flags,
                ]
                if clipped {
                    row.append(contentsOf: [Self.r2(v[0]), Self.r2(v[1]), Self.r2(v[2]), Self.r2(v[3])])
                }
                changed.append(row)
            }
            let sc = e.carriedScrolled.count == 2 ? e.carriedScrolled : [0, 0]
            let qsc = [Int((Double(sc[0]) * 100.0).rounded()), Int((Double(sc[1]) * 100.0).rounded())]
            if (scrolled[id] ?? [0, 0]) != qsc {
                scrolledRows.append([id, Self.r2(sc[0]), Self.r2(sc[1])])
                if qsc == [0, 0] {
                    scrolled.removeValue(forKey: id)
                } else {
                    scrolled[id] = qsc
                }
            }
        }

        let gone = states.keys.filter { !seen.contains($0) }.sorted()
        for id in gone {
            states.removeValue(forKey: id)
            scrolled.removeValue(forKey: id)
            if let oldNames = effects.removeValue(forKey: id) {
                for n in oldNames {
                    channels.remove(name: n)
                }
            }
        }

        var retargetRows: [[Any]] = []
        for (path, goal) in runtime.traceGoals() {
            guard let id = ids[path], goal.count == 7 else { continue }
            let q = goal.map { Int64((Double($0) * 10000.0).rounded()) }
            if let old = goals.updateValue(q, forKey: id), old.count == 7 {
                let scaleBit = (old[6] != q[6]) ? 15 : 0
                let posBits = ((old[0] != q[0] || old[4] != q[4]) ? 1 : 0)
                    | ((old[1] != q[1] || old[5] != q[5]) ? 2 : 0)
                let ownBits = posBits | scaleBit | ((old[2] != q[2]) ? 4 : 0) | ((old[3] != q[3]) ? 8 : 0)
                if ownBits != 0 {
                    retargetRows.append([id, ownBits, posBits | scaleBit])
                }
            }
        }
        goals = goals.filter { seen.contains($0.key) }

        let (edges, positionError) = runtime.scene.samplingError()
        let retargetAudit = runtime.takeRetargetAudit()
        let why = AnimSource.names(runtime.isAnimating ? runtime.animSources : 0)

        var line: [String: Any] = [
            "t": (tMs * 1000.0).rounded() / 1000.0,
            "n": 1,
            "quality": [
                "cpu_ms": (cpuMs * 1000.0).rounded() / 1000.0,
                "scene_edges": edges,
                "position_error_px": Self.r3(positionError),
                "retarget_lanes": retargetAudit.lanes,
                "velocity_error_pt_s": Self.r3(retargetAudit.maxVelocityError),
                "animating": runtime.isAnimating,
                "why": why,
            ],
        ]
        if let targetMs = timing.targetMs {
            line["target_ms"] = (targetMs * 1000.0).rounded() / 1000.0
        }
        if runtime.pressedPath != nil {
            line["k"] = 1
        }
        if !retargetRows.isEmpty {
            line["retarget"] = retargetRows
        }
        let touched = runtime.touchedTracks()
        if !touched.isEmpty {
            line["tk"] = touched.map { (path, prop, active) -> [Any] in
                let who: Any = ids[path] ?? path
                return [who, prop, active ? 1 : 0]
            }
        }
        if !runtime.traceEvents.isEmpty {
            line["ev"] = runtime.traceEvents
            runtime.traceEvents.removeAll()
        }
        if !metas.isEmpty { line["m"] = metas }
        if !changed.isEmpty { line["e"] = changed }
        if !gone.isEmpty { line["g"] = gone }
        if !scrolledRows.isEmpty { line["sc"] = scrolledRows }

        if let runtimeChannels = runtime.traceChannels {
            for (name, sample) in runtimeChannels {
                channels.sample(name: name, kind: sample.kind, value: sample.value)
            }
        }

        if var json = Self.encodeJSONLine(line) {
            if json.hasSuffix("}") {
                json.removeLast()
                channels.writeJSON(into: &json)
                if let presents {
                    presents.push(
                        lineWithoutBrace: json,
                        seq: timing.drawable,
                        continuous: timing.continuous,
                        into: &lines
                    )
                    return
                }
                json.append("}")
            }
            lines.append(json)
        }
    }

    func finish() throws {
        presents?.flush(into: &lines)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try Data(body.utf8).write(to: url, options: .atomic)
    }

    private static func r2(_ v: Float) -> Double {
        (Double(v) * 100.0).rounded() / 100.0
    }

    private static func r3(_ v: Float) -> Double {
        (Double(v) * 1000.0).rounded() / 1000.0
    }

    private static func encodeJSONLine(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

internal final class ToolingVideoEncoder {
    private let width: Int
    private let height: Int
    private let outputPath: String
    #if os(macOS) || os(Linux)
    private let process: Process
    private let stdinPipe: Pipe
    private var finished = false
    #endif

    static func ffmpegArgs(outputPath: String, width: Int, height: Int, fps: Double) throws -> [String] {
        let url = URL(fileURLWithPath: outputPath)
        let ext = url.pathExtension.lowercased()
        let codecArgs: [String]
        let evenFilter = "pad=ceil(iw/2)*2:ceil(ih/2)*2,scale=out_color_matrix=bt709:out_range=tv,format=yuv420p"
        let colorTags = ["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]
        switch ext {
        case "mp4":
            codecArgs = ["-c:v", "libx264", "-preset", "medium", "-crf", "18", "-vf", evenFilter] + colorTags + ["-movflags", "+faststart"]
        case "mov":
            codecArgs = ["-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le", "-vf", "scale=out_color_matrix=bt709:out_range=tv", "-vendor", "apl0"] + colorTags
        case "webm":
            codecArgs = ["-c:v", "libvpx-vp9", "-crf", "30", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-vf", evenFilter] + colorTags
        default:
            throw ToolingError.unsupportedVideoContainer(ext: ext)
        }
        let safeOutput = (!outputPath.hasPrefix("/") && outputPath.hasPrefix("-")) ? "./\(outputPath)" : outputPath
        let fpsString = fps.rounded() == fps ? String(Int(fps)) : String(fps)
        return [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-f", "rawvideo", "-pix_fmt", "rgba",
            "-s", "\(width)x\(height)", "-r", fpsString, "-i", "-",
        ] + codecArgs + [safeOutput]
    }

    static func unpad(_ data: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> [UInt8] {
        let rowBytes = width * 4
        var out: [UInt8] = []
        out.reserveCapacity(rowBytes * height)
        for row in 0..<height {
            let start = row * bytesPerRow
            out.append(contentsOf: data[start..<(start + rowBytes)])
        }
        return out
    }

    #if os(macOS) || os(Linux)
    convenience init(outputPath: String, width: Int, height: Int, fps: Double) throws {
        let args = try Self.ffmpegArgs(outputPath: outputPath, width: width, height: height, fps: fps)
        guard let ffmpegPath = Self.findFFmpegOnPath() else {
            throw ToolingError.ffmpegUnavailable
        }
        let url = URL(fileURLWithPath: outputPath)
        let parent = url.deletingLastPathComponent()
        if !parent.path.isEmpty {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardInput = pipe
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        self.init(process: proc, stdinPipe: pipe, outputPath: outputPath, width: width, height: height)
    }
    #else
    init(outputPath: String, width: Int, height: Int, fps: Double) throws {
        self.width = width
        self.height = height
        self.outputPath = outputPath
        let _ = try Self.ffmpegArgs(outputPath: outputPath, width: width, height: height, fps: fps)
        throw ToolingError.ffmpegUnavailable
    }
    #endif

    #if os(macOS) || os(Linux)
    init(process: Process, stdinPipe: Pipe, outputPath: String, width: Int, height: Int) {
        self.width = width
        self.height = height
        self.outputPath = outputPath
        self.process = process
        self.stdinPipe = stdinPipe
        #if canImport(Darwin)
        _ = Darwin.fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
    }
    #endif

    func writeFrame(_ frame: Frame) throws {
        #if os(macOS) || os(Linux)
        guard frame.width == width, frame.height == height else { return }
        if !process.isRunning {
            process.waitUntilExit()
            throw ToolingError.encoderError(message: "video encoder stopped reading (status \(process.terminationStatus))")
        }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: frame.rgba)
        } catch {
            try? stdinPipe.fileHandleForWriting.close()
            finished = true
            process.waitUntilExit()
            throw ToolingError.encoderError(message: "video encoder stopped reading (status \(process.terminationStatus)): \(error.localizedDescription)")
        }
        #endif
    }

    @discardableResult
    func finish() throws -> String? {
        #if os(macOS) || os(Linux)
        guard !finished else { return nil }
        finished = true
        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ToolingError.encoderError(message: "failed writing video (status \(process.terminationStatus))")
        }
        return outputPath
        #else
        return nil
        #endif
    }

    deinit {
        #if os(macOS) || os(Linux)
        if !finished {
            try? stdinPipe.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        #endif
    }

    private static func findFFmpegOnPath() -> String? {
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in envPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("ffmpeg").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
