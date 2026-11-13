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
    public var startTime: Double = 0.0
    public var startMark: ToolingMarkOffset? = nil
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
    public var videoPath: String? = nil
    public var extraArgs: [String] = []

    public init() {}

    public var isHeadlessRequested: Bool {
        snapPath != nil
            || treePath != nil
            || scriptArg != nil
            || framesDir != nil
            || outDir != nil
            || frameCount != nil
            || stripPath != nil
            || videoPath != nil
            || tracePath != nil
            || listScenes
            || listWindows
    }

    public static func parseMarkTime(_ raw: String) -> ToolingMarkOffset? {
        guard raw.hasPrefix("mark:") else { return nil }
        let rest = String(raw.dropFirst("mark:".count))
        guard !rest.isEmpty else { return nil }
        if let plusIdx = rest.lastIndex(of: "+"), plusIdx > rest.startIndex,
           let offset = Double(rest[rest.index(after: plusIdx)...]) {
            return ToolingMarkOffset(name: String(rest[..<plusIdx]), offset: offset)
        }
        if let minusIdx = rest.lastIndex(of: "-"), minusIdx > rest.startIndex,
           let offset = Double(rest[rest.index(after: minusIdx)...]) {
            return ToolingMarkOffset(name: String(rest[..<minusIdx]), offset: -offset)
        }
        return ToolingMarkOffset(name: rest, offset: 0.0)
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
                if i + 1 < arguments.count, let v = Float(arguments[i + 1]) { out.pixelScale = max(0.5, v); i += 1 }
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
                    if let m = parseMarkTime(v) {
                        out.atMark = m
                    } else if let d = Double(v) {
                        out.atTime = max(0, d)
                    }
                    i += 1
                }
            case "--start":
                if i + 1 < arguments.count {
                    let v = arguments[i + 1]
                    if let m = parseMarkTime(v) {
                        out.startMark = m
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
            case "--trace":
                if i + 1 < arguments.count { out.tracePath = arguments[i + 1]; i += 1 }
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
            case "--cpu", "--force-cpu":
                out.forceCPU = true
            default:
                out.extraArgs.append(arg)
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
        case keyUp(KeyEvent)
        case shortcut(Chord)
        case paste(ClipboardContent)
        case ime(Ime)
        case wheel(WheelEvent)
        case fling(vx: Float, vy: Float)
        case resize(Vec2)
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

/// Headless virtual-clock runner for `--snap`, `--tree`, `--script`, `--frames`, `--out`, and `--strip`.
public enum HeadlessRunner {
    public struct Output: Sendable {
        public var finalFrame: Frame
        public var treeJSON: Data
        public var frameCount: Int = 0
        public var marks: [String: Double] = [:]
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
                let html = pasteObj["html"] as? String
                let rtf = pasteObj["rtf"] as? String
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .paste(ClipboardContent(txt, html: html, rtf: rtf))))
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
                let pos: ScriptStep.Position = (e["key"] as? String).map { .key($0) }
                    ?? ((e["x"] as? NSNumber).flatMap { x in (e["y"] as? NSNumber).map { y in .xy(x.floatValue, y.floatValue) } })
                    ?? .relative(0, 0)
                out.append(ScriptStep(t: t, position: pos, action: .dragFiles(dragPaths.map { URL(fileURLWithPath: $0) })))
                continue
            }
            if let dropPaths = e["drop_files"] as? [String] {
                let pos: ScriptStep.Position = (e["key"] as? String).map { .key($0) }
                    ?? ((e["x"] as? NSNumber).flatMap { x in (e["y"] as? NSNumber).map { y in .xy(x.floatValue, y.floatValue) } })
                    ?? .relative(0, 0)
                out.append(ScriptStep(t: t, position: pos, action: .dropFiles(dropPaths.map { URL(fileURLWithPath: $0) })))
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
                let html = e["html"] as? String
                let rtf = e["rtf"] as? String
                out.append(ScriptStep(t: t, position: .relative(0, 0), action: .paste(ClipboardContent(txt, html: html, rtf: rtf))))

            case "key-up":
                let name = (e["name"] as? String) ?? ""
                if let named = Key.named(name) {
                    out.append(ScriptStep(t: t, position: .relative(0, 0), action: .keyUp(KeyEvent(key: named, mods: mods))))
                } else if mods.cmd, name.count == 1, let c = name.lowercased().first {
                    out.append(ScriptStep(t: t, position: .relative(0, 0), action: .keyUp(KeyEvent(key: .command(c), mods: mods))))
                }

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
                    out.append(ScriptStep(t: t, position: pos, action: .dropFiles(paths.map { URL(fileURLWithPath: $0) })))
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
                if let pg = app.playgroundHost {
                    pg.bindScenes(app.intoSpec().scenes, view: app.view)
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
        runtime.onAppFileDrop = spec.onFileDrop
        runtime.onFileDrop = spec.onFileDropPhase
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

        // Collect script marks and resolve `--at mark:...` / `--start mark:...`
        var marks: [String: Double] = [:]
        for step in steps {
            if case .mark(let name) = step.action, !name.isEmpty {
                marks[name] = step.t
            }
        }
        let resolvedAtTime: Double? = {
            if let m = args.atMark {
                return max(0.0, (marks[m.name] ?? 0.0) + m.offset)
            }
            return args.atTime
        }()
        let resolvedStartTime: Double = {
            if let m = args.startMark {
                return max(0.0, (marks[m.name] ?? 0.0) + m.offset)
            }
            return args.startTime
        }()
        if args.hasPlayground, let pg = runtime.playgroundHost {
            try? pg.openAt(story: args.playgroundName, variant: args.playgroundVariant)
        }

        // Initial settled frame at t = 0 (or `--at` if specified)
        let initialT = (resolvedAtTime ?? 0.0) * args.timeScale
        var lastRefScene = runtime.frame(at: initialT)
        var capturedStripFrames: [Frame] = []
        var dumpedFrameCount = 0
        let dumpDir = args.outDir ?? args.framesDir

        let needsLoop = !steps.isEmpty
            || args.durationOverride != nil
            || args.durationAuto
            || args.frameCount != nil
            || dumpDir != nil
            || args.stripPath != nil

        if needsLoop {
            let dt = 1.0 / max(1.0, args.fps)
            let lastEventTime = steps.last?.t ?? 0.0
            let framesDuration: Double? = args.frameCount.map { count in
                resolvedStartTime + Double(max(0, count - 1)) * dt + dt * 0.25
            }
            let maxSimTime = args.durationOverride
                ?? resolvedAtTime
                ?? framesDuration
                ?? (lastEventTime + 1.5)
            var simTime: Double = 0.0
            var stepCursor = 0
            var anchorPos = Vec2(vp.x * 0.5, vp.y * 0.5)
            var frameIndex = 0
            let stripStride = args.stripEvery ?? max(1, Int(args.fps / 12.0))

            if let dumpDir {
                try FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true)
            }

            while simTime <= maxSimTime || (args.frameCount != nil && dumpedFrameCount < (args.frameCount ?? 0)) {
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
                    case .keyUp:
                        break
                    case .shortcut(let chord):
                        runtime.keyDown(KeyEvent(key: chord.key, mods: chord.mods), at: animNow)
                    case .paste(let clip):
                        runtime.paste(clip, at: animNow)
                    case .ime(let imeEv):
                        _ = runtime.dispatchIme(imeEv, at: animNow)
                    case .wheel(let wev):
                        runtime.wheel(wev, at: resolvedPos, now: animNow)
                    case let .fling(vx, vy):
                        runtime.fling(vx: vx, vy: vy, at: resolvedPos, now: animNow)
                    case .resize(let newVP):
                        runtime.viewport = newVP
                    case .windowFocus(let foc):
                        runtime.windowFocused = foc
                    case .mark:
                        break
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
                lastRefScene = runtime.frame(at: animNow)

                if simTime + 1e-6 >= resolvedStartTime {
                    if let targetCount = args.frameCount, dumpedFrameCount >= targetCount {
                        break
                    }
                    let needRender = (dumpDir != nil) || (args.stripPath != nil && (frameIndex % stripStride == 0))
                    if needRender {
                        var f = try renderScene(lastRefScene)
                        if !args.cropRects.isEmpty {
                            f = tileCrops(f, cropRectsPt: args.cropRects, scale: args.pixelScale)
                        }
                        if let dumpDir {
                            let outURL = URL(fileURLWithPath: dumpDir).appendingPathComponent(String(format: "frame_%04d.png", frameIndex))
                            try f.writePNG(to: outURL)
                            dumpedFrameCount += 1
                        } else if args.frameCount != nil {
                            dumpedFrameCount += 1
                        }
                        if args.stripPath != nil && (frameIndex % stripStride == 0) {
                            capturedStripFrames.append(f)
                        }
                    }
                    frameIndex += 1
                }

                // Stop early once all script events have fired and all animations have settled (unless `--frames` or explicit `--duration` awaits more frames).
                let doneTargetFrames = args.frameCount == nil || dumpedFrameCount >= (args.frameCount ?? 0)
                if args.durationOverride == nil && resolvedAtTime == nil && args.frameCount == nil && doneTargetFrames
                    && stepCursor >= steps.count && !runtime.isAnimating && simTime >= lastEventTime + dt {
                    break
                }
                if args.frameCount != nil && dumpedFrameCount >= (args.frameCount ?? 0) {
                    break
                }
                simTime += dt
            }
        }

        var finalFrame = try renderAndReport(lastRefScene, at: runtime.currentTime)
        if !args.cropRects.isEmpty {
            finalFrame = tileCrops(finalFrame, cropRectsPt: args.cropRects, scale: args.pixelScale)
        } else if let cropKey = args.cropKey, let elInfo = runtime.element(byKey: cropKey) {
            finalFrame = cropFrame(finalFrame, rectPt: elInfo.rect, scale: args.pixelScale)
        } else if args.hasPlayground && !args.wholeWindow, let stageEl = runtime.elements().first(where: { $0.key == "playground-stage" }) {
            finalFrame = cropFrame(finalFrame, rectPt: stageEl.rect, scale: args.pixelScale)
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
            let useGutter = (frames.count > args.stripCols) || !args.cropRects.isEmpty
            let strip = stitchGridStrip(frames: frames, cols: args.stripCols, gap: useGutter ? 4 : 0)
            try strip.writePNG(to: URL(fileURLWithPath: stripPath))
        }

        return Output(finalFrame: finalFrame, treeJSON: treeData, frameCount: dumpedFrameCount, marks: marks)
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
}
