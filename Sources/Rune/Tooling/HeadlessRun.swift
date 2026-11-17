import Foundation
import RuneMotion

/// What one headless run did, available to tests and hooks (`tooling::headless_run`).
public final class HeadlessRun: @unchecked Sendable {
    public var scriptPath: String?
    public var events: [HeadlessTimedEvent]
    public var scale: Float
    public var fps: Float
    public var size: Vec2
    public var start: Double
    public var frames: Int
    public var end: Double
    public var desktopPath: String?

    private let lock = NSLock()
    private var _windows: [HeadlessWindowFrame] = []

    public init(
        scriptPath: String? = nil,
        events: [HeadlessTimedEvent] = [],
        scale: Float = 2.0,
        fps: Float = 60.0,
        size: Vec2 = Vec2(800, 600),
        start: Double = 0.0,
        frames: Int = 1,
        end: Double = 0.0,
        desktopPath: String? = nil,
        windows: [HeadlessWindowFrame] = []
    ) {
        self.scriptPath = scriptPath
        self.events = events
        self.scale = scale
        self.fps = fps
        self.size = size
        self.start = start
        self.frames = frames
        self.end = end
        self.desktopPath = desktopPath
        self._windows = windows
    }

    public var windows: [HeadlessWindowFrame] {
        lock.lock()
        let copy = _windows
        lock.unlock()
        return copy
    }

    public func appendWindowFrame(_ frame: HeadlessWindowFrame) {
        lock.lock()
        _windows.append(frame)
        lock.unlock()
    }

    public func setWindowFrames(_ frames: [HeadlessWindowFrame]) {
        lock.lock()
        _windows = frames
        lock.unlock()
    }

    /// Snapshot of every window's latest frame at or before `t` seconds.
    public func windowsAt(_ t: Double) -> [HeadlessWindowFrame] {
        lock.lock()
        let snapshot = _windows
        lock.unlock()

        var latest: [String: HeadlessWindowFrame] = [:]
        var order: [String] = []
        for f in snapshot where f.t <= t + 1e-9 {
            if latest[f.key] == nil {
                order.append(f.key)
            }
            latest[f.key] = f
        }
        return order.compactMap { latest[$0] }
    }

    /// Script marks in time order `(name, t)`.
    public func marks() -> [(name: String, t: Double)] {
        events.compactMap { ev in
            if case .mark(let name) = ev.event {
                return (name, ev.t)
            }
            return nil
        }
    }

    /// Time in seconds of the first script mark named `name`.
    public func mark(_ name: String) -> Double? {
        marks().first(where: { $0.name == name })?.t
    }

    /// The time of the script's last event (marks included), or 0 without one (`headless_run.rs::script_end`).
    public func scriptEnd() -> Double {
        events.last?.t ?? 0.0
    }

    // MARK: - Process-Global Registry

    private static let globalLock = NSLock()
    nonisolated(unsafe) private static var _current: HeadlessRun? = nil

    /// Current published headless run, if running headlessly.
    public static var current: HeadlessRun? {
        globalLock.lock()
        let run = _current
        globalLock.unlock()
        return run
    }

    /// Publishes `run` as the current headless run snapshot (for tests/hooks).
    @discardableResult
    public static func publish(_ run: HeadlessRun) -> HeadlessRun {
        globalLock.lock()
        _current = run
        globalLock.unlock()
        return run
    }

    /// Clears the published headless run snapshot (intended for test isolation).
    public static func clearCurrent() {
        globalLock.lock()
        _current = nil
        globalLock.unlock()
    }
}

/// One window's state in a headless desktop/multi-window run (`tooling::headless_run::WindowFrame`).
public struct HeadlessWindowFrame: Sendable, Equatable {
    public var t: Double
    public var key: String
    /// `[x, y, width, height]` in desktop output points.
    public var frame: [Float]
    public var visible: Bool
    public var focused: Bool

    public init(t: Double, key: String, frame: [Float], visible: Bool, focused: Bool) {
        self.t = t
        self.key = key
        self.frame = frame
        self.visible = visible
        self.focused = focused
    }
}

/// Script event timestamped for `HeadlessRun` introspection.
public struct HeadlessTimedEvent: Sendable, Equatable {
    public var t: Double
    public var position: HeadlessScriptPoint
    public var event: HeadlessScriptEvent

    public init(t: Double, position: HeadlessScriptPoint = .relative(0, 0), event: HeadlessScriptEvent) {
        self.t = t
        self.position = position
        self.event = event
    }
}

public enum HeadlessScriptPoint: Sendable, Equatable {
    case xy(Float, Float)
    case key(String)
    case relative(Float, Float)
}

public enum HeadlessPointerAction: String, Sendable, Equatable {
    case move
    case down
    case up
}

public enum HeadlessScriptEvent: Sendable, Equatable {
    case pointer(HeadlessPointerAction, button: PointerButton = .primary, mods: Mods = .none)
    case keyDown(KeyEvent)
    case keyUp(KeyEvent)
    case shortcut(String)
    case menu(String)
    case popupMenu(String?)
    case fileDialog(String?)
    case paste(String)
    case scroll(dx: Float, dy: Float)
    case wheel(dx: Float, dy: Float, mods: Mods = .none)
    case magnify(MagnifyEvent)
    case rotate(RotateEvent)
    case smartMagnify
    case fling(vx: Float, vy: Float)
    case resize(Vec2)
    case focus(Bool)
    case reopen
    case openURL(String)
    case fileDrop(FileDropPhase)
    case mark(String)
}

/// Process-level CLI introspection (`rune::extra_args`, `rune::is_headless`).
public enum ToolingProcessArgs {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _extraArgs: [String] = []
    nonisolated(unsafe) private static var _didSetExtra = false

    private static let knownValueFlags: Set<String> = [
        "--snap", "--scene", "--playground", "--variant", "--crop", "--at", "--size", "--scale",
        "--theme", "--script", "--frames", "--out", "--every", "--fps", "--strip", "--cols",
        "--tree", "--trace", "--video", "--window", "--desktop", "--html", "--html-widths",
        "--html-template", "--duration", "--start", "--keys-theme", "--scroll-bars",
        "--time-scale", "--cpu-boot", "--cpu-boot-threads",
    ]

    private static let knownBoolFlags: Set<String> = [
        "--list-scenes", "--list-windows", "--whole-window", "--trace-all", "--chrome",
        "--realtime", "--cpu", "--force-cpu", "--gpu", "--dark", "--light", "--reduced-motion",
        "--first-pixels", "--native", "--pointer", "--help", "-h",
    ]

    /// Extracts unrecognised CLI arguments while mirroring `Args::parse_from`.
    @discardableResult
    public static func parseSplit(_ argv: [String]) -> (known: ToolingArgs, extra: [String]) {
        let parsed = ToolingArgs.parse(argv)
        var extra: [String] = []
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "--keys" {
                if i + 1 < argv.count, KeycapsCorner.parse(argv[i + 1]) != nil {
                    i += 2
                } else {
                    i += 1
                }
            } else if a == "--playground" {
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("-") {
                    i += 2
                } else {
                    i += 1
                }
            } else if knownValueFlags.contains(a) {
                i += 2
            } else if knownBoolFlags.contains(a) {
                i += 1
            } else if a.hasPrefix("--") && a.contains("=") {
                let prefix = String(a.prefix(while: { $0 != "=" }))
                if knownValueFlags.contains(prefix) || prefix == "--keys" || prefix == "--playground" {
                    i += 1
                } else {
                    extra.append(a)
                    i += 1
                }
            } else {
                extra.append(a)
                i += 1
            }
        }
        lock.lock()
        _extraArgs = extra
        _didSetExtra = true
        lock.unlock()
        return (parsed, extra)
    }

    /// Unrecognised arguments passed to `parseSplit` (or parsed from `CommandLine.arguments`).
    public static func extraArgs(argv: [String]? = nil) -> [String] {
        if let argv {
            return parseSplit(argv).extra
        }
        lock.lock()
        let hasSet = _didSetExtra
        let cached = _extraArgs
        lock.unlock()
        if hasSet { return cached }
        return parseSplit(Array(CommandLine.arguments.dropFirst())).extra
    }

    /// Whether the process (or supplied `argv`) asks for an offscreen/headless tooling run.
    public static func isHeadless(argv: [String]? = nil) -> Bool {
        let tokens = argv ?? Array(CommandLine.arguments.dropFirst())
        return ToolingArgs.parse(tokens).isHeadlessRequested
    }

    /// Resets cached extra args (for unit tests).
    public static func resetForTesting() {
        lock.lock()
        _extraArgs = []
        _didSetExtra = false
        lock.unlock()
    }
}
