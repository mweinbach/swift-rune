import Foundation

// MARK: - Window Sight & Cover (`window/sight.rs`)

/// What says a shown window can no longer be seen (`window/sight.rs::Cover`).
public enum WindowCover: UInt8, Sendable {
    case system = 1
    case surface = 2
    case windows = 4
}

/// Whether a shown window is seen or covered by one or more reasons (`window/sight.rs::Sight`).
public enum WindowSight: Equatable, Sendable {
    case seen
    case covered(UInt8)

    public var isCovered: Bool {
        if case .covered = self { return true }
        return false
    }

    /// Steps sight when `cover` starts (`on: true`) or stops (`on: false`) covering the window.
    /// System and OS-specific occlusion reports supersede a refused-drawable guess (`.surface`).
    public func step(_ cover: WindowCover, on: Bool) -> WindowSight {
        var bits: UInt8
        switch self {
        case .seen: bits = 0
        case .covered(let raw): bits = raw
        }
        if cover != .surface {
            bits &= ~WindowCover.surface.rawValue
        }
        if on {
            bits |= cover.rawValue
        } else {
            bits &= ~cover.rawValue
        }
        return bits == 0 ? .seen : .covered(bits)
    }
}

// MARK: - Window Life (`window/life.rs`)

/// A window's complete lifecycle (`window/life.rs::Life`).
public enum WindowLife: Equatable, Sendable {
    case unopened
    case shown(sight: WindowSight)
    case hidden(at: UInt64)
    case finished

    public var isShown: Bool {
        if case .shown = self { return true }
        return false
    }

    public var isUncovered: Bool {
        self == .shown(sight: .seen)
    }

    public var isCovered: Bool {
        if case .shown(let sight) = self {
            return sight.isCovered
        }
        return false
    }

    public var isFinished: Bool {
        self == .finished
    }

    public var hiddenAt: UInt64? {
        if case .hidden(let at) = self { return at }
        return nil
    }

    @discardableResult
    public mutating func show() -> Bool {
        if isFinished { return false }
        self = .shown(sight: .seen)
        return true
    }

    public mutating func hide(_ stamp: () -> UInt64) {
        if isShown {
            self = .hidden(at: stamp())
        }
    }

    /// Marks or clears a cover source on a shown window, returning whether it was previously covered.
    @discardableResult
    public mutating func cover(_ cover: WindowCover, on: Bool) -> Bool {
        guard case .shown(let sight) = self else { return false }
        let was = sight.isCovered
        self = .shown(sight: sight.step(cover, on: on))
        return was
    }

    public mutating func finish() {
        self = .finished
    }

    public func closes(keepRunning: Bool, exists: Bool) -> Bool {
        switch self {
        case .shown:
            return true
        case .hidden:
            return !keepRunning
        case .unopened:
            return exists && !keepRunning
        case .finished:
            return false
        }
    }
}

// MARK: - Window Reveal (`window/reveal.rs`)

public enum WindowReveal: Equatable, Sendable {
    case show
    case open
    case cached
}

public enum WindowFound: Equatable, Sendable {
    case missing
    case hidden(minimized: Bool)
    case shown(covered: Bool, minimized: Bool)
}

public enum RevealEffect: Equatable, Sendable {
    case readSystem
    case build
    case place
    case create
    case orderIn(focus: Bool)
    case unminimize
    case settle
    case shown(live: Bool)
    case cancelTimerFrame
    case number
    case focus
    case redraw
    case redrawIfMoving
}

extension WindowReveal {
    public static var defaultIsMacOS: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    public func effects(found: WindowFound, isMacOS: Bool = Self.defaultIsMacOS) -> [RevealEffect] {
        var out: [RevealEffect] = []
        let hidden: Bool
        let covered: Bool
        let minimized: Bool
        switch found {
        case .missing:
            if self != .cached {
                out.append(contentsOf: [.readSystem, .create])
            }
            return out
        case .hidden(let min):
            hidden = true
            covered = false
            minimized = min
        case .shown(let cov, let min):
            hidden = false
            covered = cov
            minimized = min
        }
        if self == .cached {
            return [.orderIn(focus: true), .shown(live: true), .cancelTimerFrame, .number, .redrawIfMoving]
        }
        let restores = (self == .open) && minimized
        out.append(.readSystem)
        if hidden || restores {
            out.append(.build)
        }
        out.append(.place)
        if hidden {
            out.append(.orderIn(focus: false))
        }
        if restores {
            out.append(.unminimize)
        }
        if hidden || covered || restores {
            out.append(.settle)
        }
        let staysMinimized = minimized && !restores && !isMacOS
        out.append(contentsOf: [.shown(live: !staysMinimized), .cancelTimerFrame, .number])
        if self == .open {
            out.append(.focus)
        }
        out.append(.redraw)
        return out
    }
}

// MARK: - Window WakeWork (`window/wake.rs`)

public enum WakeWork: Equatable, Sendable {
    case nothing
    case hiddenFrame
    case coveredFrame
    case paint
}

public struct WakeFacts: Equatable, Sendable {
    public var window: Bool
    public var launcher: Bool
    public var visible: Bool
    public var wasShown: Bool
    public var changed: Bool
    public var quiet: Bool
    public var covered: Bool

    public init(
        window: Bool = false,
        launcher: Bool = false,
        visible: Bool = false,
        wasShown: Bool = false,
        changed: Bool = false,
        quiet: Bool = false,
        covered: Bool = false
    ) {
        self.window = window
        self.launcher = launcher
        self.visible = visible
        self.wasShown = wasShown
        self.changed = changed
        self.quiet = quiet
        self.covered = covered
    }
}

extension WakeWork {
    public static func of(_ facts: WakeFacts, minimized: () -> Bool) -> WakeWork {
        if !facts.window { return .nothing }
        if facts.launcher && !facts.visible {
            return facts.changed ? .hiddenFrame : .nothing
        }
        if facts.quiet { return .nothing }
        let asked = facts.launcher ? (facts.changed || (facts.wasShown && facts.visible)) : facts.visible
        if !asked { return .nothing }
        if (!facts.launcher && facts.covered) || minimized() {
            return .coveredFrame
        }
        return .paint
    }
}

// MARK: - Window Minimize (`window/minimize.rs`)

public enum WindowMinimize: Equatable, Sendable {
    case none
    case asked
    case held(field: Bool)

    public var latched: Bool {
        self != .none
    }

    public var field: Bool {
        switch self {
        case .none: return false
        case .asked: return true
        case .held(let field): return field
        }
    }

    public static func step(_ state: inout WindowMinimize, event: MinimizeEvent) -> [MinimizeEffect] {
        switch (state, event) {
        case (.none, .asked):
            state = .asked
            return []
        case (.none, _):
            return []
        case (.asked, .asked):
            return []
        case (.asked, .heldForShow):
            state = .held(field: false)
            return []
        case (.held(field: true), .heldForShow):
            state = .held(field: false)
            return []
        case (.held(field: false), .heldForShow):
            state = .none
            return []
        case (.held(let field), .asked):
            _ = field
            state = .held(field: true)
            return []
        case (.asked, .taken):
            state = .none
            return [.minimize]
        case (.held(field: true), .taken):
            state = .held(field: false)
            return [.minimize]
        case (.held(field: false), .taken):
            return []
        case (.held, .returned):
            state = .asked
            return []
        case (.asked, .returned):
            return []
        case (.asked, .lost):
            state = .none
            return []
        case (.held, .lost):
            state = .held(field: false)
            return []
        }
    }
}

public enum MinimizeEvent: Equatable, Sendable {
    case asked
    case heldForShow
    case returned
    case taken
    case lost
}

public enum MinimizeEffect: Equatable, Sendable {
    case minimize
}

/// Guards a hidden poll's minimize ask across its shell in a show turn (`window/minimize.rs::HiddenPoll`).
public struct WindowHiddenPoll: Sendable {
    public let shows: Bool

    public init(shows: Bool) {
        self.shows = shows
    }

    public func enter<S>(_ runtime: Runtime<S>) {
        if shows {
            _ = runtime.minimizeStep(.heldForShow)
        }
    }

    public func leave<S>(_ runtime: Runtime<S>) {
        if shows {
            _ = runtime.minimizeStep(.returned)
        }
    }
}

// MARK: - Window Pacing, Missed, Backoff & TimerFrame (`window/pacing.rs`, `window/backoff.rs`)

public enum WindowPacingConstants {
    public static let occludedRetry: Double = 0.250
    public static let occludedMax: Double = 2.0
    public static let timeoutRetry: Double = 0.016
    public static let timerFrame: Double = 0.016_667
    public static let timerFrameStall: Double = occludedRetry
}

public enum WindowMissed: Equatable, Sendable {
    case occluded
    case timeout
    case outdated
    case unconfigured

    public func retry(paced: Bool, now: Double, occludedWait: inout Double) -> Double? {
        switch self {
        case .occluded:
            let clamped = min(max(occludedWait, WindowPacingConstants.occludedRetry), WindowPacingConstants.occludedMax)
            let at = now + clamped
            occludedWait = min(occludedWait * 2.0, WindowPacingConstants.occludedMax)
            return at
        case .timeout where paced:
            return nil
        case .timeout:
            return now + WindowPacingConstants.timeoutRetry
        case .outdated, .unconfigured:
            return now + WindowPacingConstants.occludedRetry
        }
    }
}

public enum BackoffEvent: Equatable, Sendable {
    case missed(WindowMissed, paced: Bool, now: Double)
    case hiddenMissed(preparing: Bool, now: Double)
    case at(Double)
    case lapsed
    case uncovered
    case revealed
    case presented
}

public enum BackoffEffect: Equatable, Sendable {
    case stopPacing
}

public struct WindowBackoff: Equatable, Sendable {
    public private(set) var at: Double?
    public private(set) var occluded: Double
    public private(set) var hidden: Double

    public init(
        at: Double? = nil,
        occluded: Double = WindowPacingConstants.occludedRetry,
        hidden: Double = WindowPacingConstants.timeoutRetry
    ) {
        self.at = at
        self.occluded = occluded
        self.hidden = hidden
    }

    public static func seeded(occluded: Double, hidden: Double) -> WindowBackoff {
        WindowBackoff(at: nil, occluded: occluded, hidden: hidden)
    }

    public var deadline: Double? { at }

    public func waiting(now: Double) -> Bool {
        at.map { $0 > now } ?? false
    }

    @discardableResult
    public mutating func step(_ event: BackoffEvent) -> [BackoffEffect] {
        switch event {
        case .missed(let missed, let paced, let now):
            at = missed.retry(paced: paced, now: now, occludedWait: &occluded)
            return at != nil ? [.stopPacing] : []
        case .hiddenMissed(let preparing, let now):
            at = preparing ? nil : (now + hidden)
            if !preparing {
                hidden = min(hidden * 2.0, WindowPacingConstants.occludedMax)
            }
            return []
        case .at(let target):
            at = target
            return []
        case .lapsed:
            at = nil
            return []
        case .uncovered:
            at = nil
            occluded = WindowPacingConstants.occludedRetry
            return []
        case .revealed:
            occluded = WindowPacingConstants.occludedRetry
            return []
        case .presented:
            at = nil
            occluded = WindowPacingConstants.occludedRetry
            hidden = WindowPacingConstants.timeoutRetry
            return []
        }
    }
}

public struct WindowTimerFrame: Equatable, Sendable {
    public private(set) var owed: Double?
    public private(set) var isQuiet: Bool

    public init(owed: Double? = nil, isQuiet: Bool = false) {
        self.owed = owed
        self.isQuiet = isQuiet
    }

    public mutating func askedQuiet(now: Double) {
        if owed == nil { owed = now }
        isQuiet = true
    }

    public mutating func stalledAgain(now: Double) {
        owed = now
    }

    public mutating func drawn() {
        owed = nil
    }

    public mutating func noLongerQuiet() {
        isQuiet = false
    }

    public mutating func takeQuiet() -> Bool {
        let was = isQuiet
        isQuiet = false
        return was
    }

    public func stalled(now: Double) -> Bool {
        guard let asked = owed else { return false }
        return now >= asked + WindowPacingConstants.timerFrameStall
    }

    public func wait(due: Double?, now: Double) -> Double? {
        if let due, let asked = owed, due <= now {
            return asked + WindowPacingConstants.timerFrameStall
        }
        return due
    }
}
