import Foundation

/// Counts a run of presses on a single element path (`crates/rune/src/runtime/input/press_run.rs`),
/// mirroring AppKit's `clickCount` across primary clicks, double-press pairing, and text selection.
public struct PressRun: Sendable {
    /// Maximum per-axis travel (points) allowed between consecutive clicks in a run (`CLICK_SLOP`).
    public static let clickSlop: Float = 4.0

    public struct Last: Sendable, Equatable {
        public var path: String
        public var at: Double
        public var point: Vec2
        public var count: UInt32
    }

    public private(set) var last: Last? = nil

    public init() {}

    /// `b` is within `clickSlop` of `a` on each axis.
    public static func withinSlop(_ a: Vec2, _ b: Vec2) -> Bool {
        abs(b.x - a.x) <= clickSlop && abs(b.y - a.y) <= clickSlop
    }

    /// Whether a press at `point` and `now` follows a press at `was` and `then` within `interval` and slop.
    public static func follows(then: Double, was: Vec2, now: Double, point: Vec2, interval: Double) -> Bool {
        (now - then) <= interval && withinSlop(was, point)
    }

    /// Counts a press on `path` at `now`: increments if it is the same path and follows the previous press,
    /// otherwise resets the run to 1.
    @discardableResult
    public mutating func press(path: String, at now: Double, point: Vec2, interval: Double) -> UInt32 {
        if var cur = last,
           cur.path == path,
           Self.follows(then: cur.at, was: cur.point, now: now, point: point, interval: interval) {
            cur.at = now
            cur.point = point
            cur.count &+= 1
            last = cur
            return cur.count
        }
        last = Last(path: path, at: now, point: point, count: 1)
        return 1
    }

    /// Ends the current run of clicks (on drag, secondary/other button, cancel, blur, or key reset).
    public mutating func clear() {
        last = nil
    }

    /// Ends the run unless its last press was on `path`.
    public mutating func keepOn(_ path: String?) {
        if let cur = last, cur.path != path {
            last = nil
        }
    }
}

/// First click of a potential `onDoubleClick` (`on_double_press`) pair (`capture::FirstClick`).
internal struct FirstDoubleClick: Sendable {
    var path: String
    var at: Double
    var point: Vec2
}

/// Held state for a secondary gesture (`capture::Secondary`).
internal enum SecondaryCapture: Equatable {
    case up
    case held(path: String, link: Int?, left: Bool)

    var isHeld: Bool {
        if case .held = self { return true }
        return false
    }
}

/// Consolidated runtime state for Slice 4 input state machines so `Runtime.swift` stores a single field.
internal struct RuntimeInputMachines {
    var pressClicks = PressRun()
    var firstDoubleClick: FirstDoubleClick? = nil
    var currentDoubleClickPair: (downAt: Double, downPoint: Vec2, isSecond: Bool, moved: Bool, left: Bool)? = nil
    var keyReleases = KeyReleases()
    var physicalLogicalKeys: [PhysicalKeyCode: Key] = [:]
    var activePhysicalKey: PhysicalKeyCode? = nil
    var modifierKeys = ModifierKeysState()
    var focusMachine = FocusMachine()
    var appIme = AppImeState()
    var pressedWindowPoint: Vec2? = nil
    var pressedStillInside: Bool = true
    var pressedLeft: Bool = false
    var pressedButton: PointerButton = .primary
    var pendingKeysLost: Bool = false
    var pendingKeysLostTime: Double? = nil
    var secondaryCapture: SecondaryCapture = .up
    var events: [String] = []
    var recordEvents: Bool = true
    var traceChannelsActive: Bool = false
    var osDragSupported: Bool = true
    var currentMods: Mods = .none
    var fieldMenus: [UInt64: FieldMenuContext] = [:]
    var nextFieldMenuId: UInt64 = 1
    var wheelLock = WheelLock()
    var touchState = TouchInputState()
    var inputScroll: [String: Float] = [:]
    var untakenDragOuts: [(id: UInt64, path: String, key: String?, start: DragOutStart, cancelledByHost: Bool, sawFrame: Bool, onEnd: ((inout Any, DragOutcome, inout Tx) -> Void)?)] = []
    var activeDragOuts: [(id: UInt64, path: String, key: String?, onEnd: ((inout Any, DragOutcome, inout Tx) -> Void)?)] = []
    var nextDragOutId: UInt64 = 1
}
