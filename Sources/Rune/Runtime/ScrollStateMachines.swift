import Foundation
import RuneMotion

// MARK: - Scroll Axis & Pixel Grid Helpers (`rune_motion::snap::grid`, `types.rs::AxisScroll`)

/// Direction flow and horizontal axis scroll helpers (`el::Flow`, `types.rs::AxisScroll`).
public enum ScrollAxisHelper: Sendable {
    public enum Flow: Sendable, Equatable, Hashable {
        case ltr
        case rtl
    }

    /// Horizontal scroll state (`types.rs::AxisScroll`).
    public struct AxisScroll: Sendable, Equatable {
        public var offset: Double
        public var v: Float
        public var max: Double
        public var glide: Float?
        public var aim: Double
        public var flow: Flow

        public init(
            offset: Double = 0.0,
            v: Float = 0.0,
            max: Double = 0.0,
            glide: Float? = nil,
            aim: Double = 0.0,
            flow: Flow = .ltr
        ) {
            self.offset = offset
            self.v = v
            self.max = max
            self.glide = glide
            self.aim = aim
            self.flow = flow
        }

        /// How far left the content draws, in points.
        public var shift: Double {
            switch flow {
            case .ltr: return offset
            case .rtl: return -offset
            }
        }

        /// `delta` points of physical movement (positive moving content right) as a change of `offset`.
        public func toward(_ delta: Double) -> Double {
            switch flow {
            case .ltr: return -delta
            case .rtl: return delta
            }
        }
    }

    /// Rounds `value` points to the 1/64 device-pixel grid at `scale` device pixels per point.
    @inlinable
    public static func grid(_ value: Float, scale: Float) -> Float {
        Snap.grid(value, scale: scale)
    }

    /// Clamps retarget velocity so a critically-damped glide redirected nearer mid-flight
    /// stops cleanly at `to` without overshooting (`offset.rs::retarget_v`).
    @inlinable
    public static func retargetV(spring: Spring, offset: Double, v: Float, to: Double) -> Float {
        let d = Float(offset - to)
        let most = spring.omega * abs(d)
        if v * d < 0 && abs(v) > most {
            return -(d >= 0 ? Float(1) : Float(-1)) * most
        }
        return v
    }
}

// MARK: - Drawn Offset Hold (`crates/rune/src/runtime/scroll/drawn.rs`)

/// Where a scroll viewport drew its content's vertical offset last frame, and the hold that
/// keeps a pinned end's pixel through a sub-pixel reversal (`drawn.rs::PixelHold`).
public enum PixelHold: Sendable, Equatable {
    /// Nothing drawn yet.
    case unseen
    /// Drawn at `drawn`, stepping `dir` (-1, 0 or 1), with `pinned` the mode it stepped in.
    case stepping(drawn: Float, dir: Int8, pinned: Bool)
    /// Held at `drawn` through a reversal at a pinned end, last stepping `dir`.
    case holding(drawn: Float, dir: Int8)

    public static let `default`: PixelHold = .unseen

    /// The vertical offset the last frame drew at, in points.
    public var y: Float {
        switch self {
        case .unseen:
            return 0.0
        case .stepping(let drawn, _, _), .holding(let drawn, _):
            return drawn
        }
    }

    /// The offset to draw this frame's `exact` content offset at, and the hold after it.
    /// `offset` is the viewport's layout offset, which a held step never draws away from.
    public func draw(exact: Float, offset: Float, pinned: Bool, scale s: Float) -> (Float, PixelHold) {
        let rounded = Snap.grid(exact, scale: s)
        let (drawn, dir, steppedPinned): (Float, Int8, Bool)
        switch self {
        case .unseen:
            (drawn, dir, steppedPinned) = (0.0, 0, false)
        case .stepping(let d, let dr, let p):
            (drawn, dir, steppedPinned) = (d, dr, p)
        case .holding(let d, let dr):
            (drawn, dir, steppedPinned) = (d, dr, true)
        }
        let diff = rounded - drawn
        // Match Rust's `(rounded - drawn).signum() as i8` (0.0 -> +1, -0.0 -> -1, NaN -> 0).
        let step: Int8 = diff.isNaN ? 0 : (diff.sign == .minus ? -1 : 1)
        let back = pinned
            && steppedPinned
            && rounded != Snap.grid(offset, scale: s)
            && step == -dir
            && abs((exact - drawn) * s) < (1.0 / 64.0)
        if back {
            return (drawn, .holding(drawn: drawn, dir: dir))
        }
        let nextDir = (rounded == drawn) ? dir : step
        let nextSteppedPinned = (rounded == drawn) ? steppedPinned : pinned
        return (rounded, .stepping(drawn: rounded, dir: nextDir, pinned: nextSteppedPinned))
    }
}

// MARK: - Instant Scroll Hover Hold (`crates/rune/src/runtime/scroll/nudge.rs`)

/// A viewport's instant-scroll hover hold (`nudge.rs::Nudge`).
public struct ScrollNudge: Sendable, Equatable {
    /// How long an instant scroll holds hover: two frames at 60 Hz.
    public static let nudgeHold: Double = 2.0 / 60.0
    private static let slack: Double = 1e-6

    /// Where the hold stands (`nudge.rs::Hold`).
    public enum Hold: Sendable, Equatable {
        /// Nothing holds hover.
        case free
        /// An instant scroll landed, and hover holds until this clock time, as `attempt`.
        case held(attempt: AttemptToken, due: Double)
    }

    /// Input events for `ScrollNudge.step` (`nudge.rs::Event`).
    public enum Event: Sendable, Equatable {
        /// An app's instant scroll landed at this clock time.
        case arm(now: Double)
        /// A frame at `now`, carrying the `attempt` its arm asked for.
        case due(attempt: AttemptToken, now: Double)
    }

    /// Output effects from `ScrollNudge.step` (`nudge.rs::Effect`).
    public enum Effect: Sendable, Equatable {
        /// Wake at this clock time, when the hold is due.
        case wakeAt(Double)
    }

    public var seq: Seq
    public var state: Hold

    public init(seq: Seq = Seq(), state: Hold = .free) {
        self.seq = seq
        self.state = state
    }

    @discardableResult
    public static func step(seq: inout Seq, state: inout Hold, event: Event) -> Effects<Effect> {
        switch event {
        case .arm(let now):
            let attempt = seq.nextAttempt()
            let due = now + nudgeHold
            state = .held(attempt: attempt, due: due)
            return .one(.wakeAt(due))
        case .due(let attempt, let now):
            if case .held(let armed, let due) = state, armed == attempt, due <= now + slack {
                state = .free
            }
            return .none
        }
    }

    /// An instant scroll landed at `now`: hover holds, and this returns the wake request.
    @discardableResult
    public mutating func arm(now: Double) -> Effects<Effect> {
        Self.step(seq: &seq, state: &state, event: .arm(now: now))
    }

    /// A frame at `now`: a hold that came due ends.
    public mutating func tick(now: Double) {
        if case .held(let attempt, _) = state {
            _ = Self.step(seq: &seq, state: &state, event: .due(attempt: attempt, now: now))
        }
    }

    /// Hover holds at `now`.
    public func holdAt(now: Double) -> Bool {
        if case .held(_, let due) = state {
            return now + Self.slack < due
        }
        return false
    }

    /// The clock time a pending hold ends.
    public func due() -> Double? {
        if case .held(_, let due) = state {
            return due
        }
        return nil
    }
}

// MARK: - Scroll Mode & Hand Latches (`crates/rune/src/runtime/scroll/mode.rs`, `types.rs::GlideTo`)

/// Where a scroll glide goes (`types.rs::GlideTo`).
public enum GlideTo: Sendable, Equatable {
    /// The content's bottom, as it moves (`Tx::scroll_to_bottom`).
    case bottom
    /// An offset an app or a reveal asked for (`Tx::scroll_to`), while the content reaches it.
    case offset(Double)
    /// The end a growth stack shrinks to under a reader who scrolled up (`ease_to_shrunk_end`).
    case shrunkEnd(Double)

    /// The offset it heads for, `nil` for the bottom.
    public var offset: Double? {
        switch self {
        case .bottom:
            return nil
        case .offset(let to), .shrunkEnd(let to):
            return to
        }
    }
}

/// The hand latches a mode carries from frame to frame (`mode.rs::Hand`).
public struct ScrollHand: Sendable, Equatable {
    /// A hand (wheel, keys, drag, touch) or an app's instant jump moved the offset since the last step.
    public var direct: Bool
    /// It moved in the last step: a hand, its momentum or a glide.
    public var scrolling: Bool
    /// A hand or an app's instant jump moved it since `El::onScrollOffset` was last told.
    public var byHand: Bool
    /// A hand scrolled while the growth stack moved: no shrink glide until it settles.
    public var shrinkCut: Bool
    /// The growth stack's layout end while its rows still move.
    public var laid: Double?

    public init(
        direct: Bool = false,
        scrolling: Bool = false,
        byHand: Bool = false,
        shrinkCut: Bool = false,
        laid: Double? = nil
    ) {
        self.direct = direct
        self.scrolling = scrolling
        self.byHand = byHand
        self.shrinkCut = shrinkCut
        self.laid = laid
    }
}

/// What moves a viewport's vertical offset, one motion at a time, with its hand latches (`mode.rs::ScrollMode`).
public enum ScrollMode: Sendable, Equatable {
    /// At rest where a hand, an app or a glide left it.
    case rest(ScrollHand)
    /// A stick-to-bottom viewport following its content's end.
    case pinned(ScrollHand)
    /// Coasting from a fling, keys or wheel momentum at `v` points a second, decaying.
    case momentum(v: Float, hand: ScrollHand)
    /// Gliding on a spring at `v` points a second.
    case glide(v: Float, to: GlideTo, hand: ScrollHand)

    public enum Event: Sendable, Equatable {
        case moved
        case hold
        case coast(moving: Bool)
        case still
        case growth(moving: Bool)
        case step(xV: Float)
        case laid(Double?)
        case take
        case halt
        case rest
        case pin
        case unpin
    }

    public enum Effect: Sendable, Equatable {
        case tell
    }

    // Task-local write counter for deterministic parity testing without cross-task races.
    internal final class WriteCounterBox: @unchecked Sendable {
        var count: Int = 0
    }

    @TaskLocal
    private static var writeCounter: WriteCounterBox? = nil

    internal static func withWriteCounting<T>(_ operation: () -> T) -> T {
        let box = WriteCounterBox()
        return $writeCounter.withValue(box, operation: operation)
    }

    internal static func takeWriteCount() -> Int {
        guard let box = writeCounter else { return 0 }
        let out = box.count
        box.count = 0
        return out
    }

    private static func noteWrite() {
        writeCounter?.count += 1
    }

    public static var `default`: ScrollMode { .rest(ScrollHand()) }

    /// At rest, with no hand data.
    public static func rest() -> ScrollMode { .rest(ScrollHand()) }

    /// Following its content's end, with no hand data.
    public static func following() -> ScrollMode { .pinned(ScrollHand()) }

    /// The hand latches this mode carries.
    public var hand: ScrollHand {
        get {
            switch self {
            case .rest(let hand), .pinned(let hand),
                 .momentum(_, let hand), .glide(_, _, let hand):
                return hand
            }
        }
        set {
            switch self {
            case .rest:
                self = .rest(newValue)
            case .pinned:
                self = .pinned(newValue)
            case .momentum(let v, _):
                self = .momentum(v: v, hand: newValue)
            case .glide(let v, let to, _):
                self = .glide(v: v, to: to, hand: newValue)
            }
        }
    }

    /// The same mode at rest, keeping the hand's latches.
    public func toRest() -> ScrollMode {
        Self.noteWrite()
        return .rest(hand)
    }

    /// The same mode following its bottom, keeping the hand's latches.
    public func toPinned() -> ScrollMode {
        Self.noteWrite()
        return .pinned(hand)
    }

    /// The same mode coasting at `v`, keeping the hand's latches.
    public func toMomentum(_ v: Float) -> ScrollMode {
        Self.noteWrite()
        return .momentum(v: v, hand: hand)
    }

    /// The same mode gliding at `v` toward `to`, keeping the hand's latches.
    public func toGlide(_ v: Float, to: GlideTo) -> ScrollMode {
        Self.noteWrite()
        return .glide(v: v, to: to, hand: hand)
    }

    /// Its momentum (points a second), 0 unless coasting.
    public func coast() -> Float {
        if case .momentum(let v, _) = self {
            return v
        }
        return 0.0
    }

    /// It follows its content's bottom.
    public func pinned() -> Bool {
        if case .pinned = self {
            return true
        }
        return false
    }

    /// The running glide's speed (points a second), while one runs.
    public func glide() -> Float? {
        if case .glide(let v, _, _) = self {
            return v
        }
        return nil
    }

    /// Folds `event` into `mode`, returning what the caller should carry out.
    @discardableResult
    public static func step(_ mode: inout ScrollMode, _ event: Event) -> Effects<Effect> {
        switch event {
        case .moved:
            mode.hand.direct = true
        case .hold:
            mode.hand.scrolling = true
            mode.hand.byHand = true
        case .coast(let moving):
            mode.hand.scrolling = moving
            mode.hand.byHand = mode.hand.byHand || moving
            mode.hand.direct = false
        case .still:
            mode.hand.scrolling = false
        case .growth(let moving):
            let c = mode.coast()
            mode.hand.shrinkCut = moving && (mode.hand.shrinkCut || mode.hand.direct || abs(c) > 1.0)
        case .step(let xV):
            let c = mode.coast()
            let scrolling = mode.hand.direct || abs(c) > 1.0 || abs(xV) > 1.0
            mode.hand.scrolling = scrolling
            mode.hand.byHand = mode.hand.byHand || scrolling
            mode.hand.direct = false
        case .laid(let laid):
            mode.hand.laid = laid
        case .take:
            let was = mode.hand.byHand
            mode.hand.byHand = false
            return was ? .one(.tell) : .none
        case .halt:
            if !mode.pinned() {
                mode = mode.toRest()
            }
        case .pin:
            if !mode.pinned() {
                mode = mode.toPinned()
            }
        case .unpin:
            if mode.pinned() {
                mode = mode.toRest()
            }
        case .rest:
            mode = mode.toRest()
        }
        return .none
    }
}

// MARK: - Horizontal Wheel Lock & Delta (`crates/rune/src/runtime/scroll/x.rs`)

/// Who has the gesture `WheelLock.runGesture` (`x.rs::WheelOwner`).
public enum WheelOwner: Sendable, Equatable {
    /// Nobody yet: its first delta picks.
    case unpicked
    /// The `onWheel` element that took the gesture's first delta and hears the rest.
    case handler(String)
    /// Scrolling vertically.
    case vertical
    /// Scrolling the horizontal viewport the gesture began on, latched through the gesture and its momentum.
    case horizontal(NodeId)

    /// Horizontal (`true`) or vertical, once a delta picked an axis.
    public func horizontalAxis() -> Bool? {
        switch self {
        case .vertical: return false
        case .horizontal: return true
        case .unpicked, .handler: return nil
        }
    }
}

/// The phase a gesture had when the platform ended it (`x.rs::GestureKind`).
public enum WheelGestureKind: Sendable, Equatable {
    case unphased
    case phased
    case momentum
}

/// Whether the platform reports the gesture's phases, and when it last moved or ended (`x.rs::WheelPhase`).
public enum WheelPhase: Sendable, Equatable {
    case unphased(at: Double?)
    case phased(at: Double)
    case momentum(at: Double)
    case ended(at: Double, from: WheelGestureKind)

    public static let `default`: WheelPhase = .unphased(at: nil)

    /// The gesture is the momentum of one that ended, or ended as momentum.
    public var isMomentum: Bool {
        switch self {
        case .momentum, .ended(_, .momentum):
            return true
        case .unphased, .phased, .ended:
            return false
        }
    }

    /// Whether the platform reports its phases: it has begun it, or it ended one that had.
    public var isPhased: Bool {
        switch self {
        case .unphased, .ended(_, .unphased):
            return false
        case .phased, .momentum, .ended:
            return true
        }
    }

    /// When its last delta came.
    public var at: Double? {
        switch self {
        case .unphased(let at):
            return at
        case .phased(let at), .momentum(let at), .ended(let at, _):
            return at
        }
    }

    /// When the platform ended it, while that is what happened last.
    public var ended: Double? {
        if case .ended(let at, _) = self {
            return at
        }
        return nil
    }

    /// The same live phase, with its last delta at `now`.
    public func moving(at now: Double) -> WheelPhase {
        switch self {
        case .unphased:
            return .unphased(at: now)
        case .phased:
            return .phased(at: now)
        case .momentum:
            return .momentum(at: now)
        case .ended:
            return self
        }
    }
}

/// The wheel or trackpad gesture in progress, and who has it (`x.rs::WheelLock`).
public struct WheelLock: Sendable, Equatable {
    /// Seconds without a delta after which the next one starts a new unphased gesture.
    public static let wheelIdle: Double = 0.1
    /// Seconds without a delta after which a phased gesture counts as over if its end never comes.
    public static let phasedIdle: Double = 1.0
    /// A gesture that begins within this many seconds of one ending is its momentum.
    public static let momentumGap: Double = 0.05

    #if os(macOS)
    public static let shiftTurnsWheel: Bool = false
    #else
    public static let shiftTurnsWheel: Bool = true
    #endif

    private var seq: Seq
    public var gesture: AttemptToken
    public var runGesture: AttemptToken
    public var owner: WheelOwner
    public var phase: WheelPhase

    public init(
        seq: Seq = Seq(),
        gesture: AttemptToken = AttemptToken(0),
        runGesture: AttemptToken = AttemptToken(0),
        owner: WheelOwner = .unpicked,
        phase: WheelPhase = .default
    ) {
        self.seq = seq
        self.gesture = gesture
        self.runGesture = runGesture
        self.owner = owner
        self.phase = phase
    }

    public mutating func syncGesture(_ gesture: AttemptToken) {
        if runGesture != gesture {
            runGesture = gesture
            owner = .unpicked
        }
    }

    /// The gesture is the momentum of one that ended.
    public func momentum() -> Bool {
        phase.isMomentum
    }

    private mutating func restart(queued: Bool) {
        gesture = seq.nextAttempt()
        phase = .unphased(at: nil)
        if !queued {
            runGesture = gesture
            owner = .unpicked
        }
    }

    /// The axis the gesture's owner keeps for a delta `(dx, dy)`: horizontal (`true`) or vertical,
    /// or `nil` when it picks afresh.
    public func keepsAxis(dx: Float, dy: Float) -> Bool? {
        guard let h = owner.horizontalAxis() else { return nil }
        return (phase.isPhased || (h ? dx != 0.0 : dy != 0.0)) ? h : nil
    }

    /// A delta picked afresh: the horizontal viewport under it (`across`), else vertical.
    /// Returns whether it scrolls horizontally.
    @discardableResult
    public mutating func repick(across: NodeId?) -> Bool {
        owner = across.map { .horizontal($0) } ?? .vertical
        return across != nil
    }

    /// A delta arrived at `now`, on `(dx, dy)` points.
    public mutating func delta(now: Double, dx: Float, dy: Float, queued: Bool) {
        let phased = phase.isPhased
        let idle = phased ? Self.phasedIdle : Self.wheelIdle
        let flipped = !phased
            && runGesture == gesture
            && (owner.horizontalAxis().map { h in h ? dx == 0.0 : dy == 0.0 } ?? false)
        let timedOut = phase.at.map { now - $0 > idle } ?? true
        let stale = phase.ended != nil || timedOut || flipped
        if stale {
            restart(queued: queued)
        }
        phase = phase.moving(at: now)
    }

    /// The platform began a gesture at `now`.
    public mutating func began(now: Double, active: Bool, queued: Bool, anyQueued: Bool) {
        let withinGap = phase.ended.map { now - $0 <= Self.momentumGap } ?? false
        let isMomentum = !phase.isMomentum && (active || queued) && withinGap
        if !isMomentum {
            restart(queued: anyQueued)
        }
        phase = isMomentum ? .momentum(at: now) : .phased(at: now)
    }

    /// The platform ended the gesture at `now`, keeping the phase it had.
    public mutating func endedAt(_ now: Double) {
        let from: WheelGestureKind
        switch phase {
        case .unphased: from = .unphased
        case .phased: from = .phased
        case .momentum: from = .momentum
        case .ended(_, let f): from = f
        }
        phase = .ended(at: now, from: from)
    }

    /// The window lost the pointer or focus: a gesture in progress won't report its end here.
    public mutating func lost(queued: Bool) {
        restart(queued: queued)
    }
}

/// Raw mouse scroll delta matching `winit::event::MouseScrollDelta`.
public enum MouseScrollDelta: Sendable, Equatable {
    case lineDelta(Float, Float)
    case pixelDelta(x: Double, y: Double)
}

/// Converts a raw mouse/trackpad scroll delta into points `(dx, dy)` (`x.rs::wheel_delta`).
public func wheelDelta(_ delta: MouseScrollDelta, scale: Float, shift: Bool) -> (Float, Float) {
    let (dx, dy): (Float, Float)
    switch delta {
    case .pixelDelta(let x, let y):
        dx = Float(x) / scale
        dy = Float(y) / scale
    case .lineDelta(let x, let y):
        dx = x * 40.0
        dy = y * 40.0
    }
    if shift && dx == 0.0 {
        return (dy, 0.0)
    }
    return (dx, dy)
}

// MARK: - Touch Scrolling State Machine (`crates/rune/src/runtime/scroll/touch.rs`)

/// What a touch holds: the viewport its finger went down on, one it pans, or one it let go
/// that is still settling (`touch.rs::TouchScroll`).
public enum TouchScroll: Sendable, Equatable {
    case held(id: NodeId, origin: Double, horizontal: Bool)
    case dragging(id: NodeId, origin: Double, horizontal: Bool)
    case coasting(id: NodeId, horizontal: Bool)

    public var id: NodeId {
        switch self {
        case .held(let id, _, _), .dragging(let id, _, _), .coasting(let id, _):
            return id
        }
    }

    public var horizontal: Bool {
        switch self {
        case .held(_, _, let horizontal), .dragging(_, _, let horizontal), .coasting(_, let horizontal):
            return horizontal
        }
    }

    public var origin: Double? {
        switch self {
        case .held(_, let origin, _), .dragging(_, let origin, _):
            return origin
        case .coasting:
            return nil
        }
    }

    public var coasting: Bool {
        if case .coasting = self {
            return true
        }
        return false
    }
}

/// What happens to a touch's pan (`touch.rs::TouchEvent`).
public enum TouchEvent: Sendable, Equatable {
    case down(across: (NodeId, Double)?, vertical: (NodeId, Double)?)
    case pan(horizontal: Bool, across: (NodeId, Double)?, vertical: (NodeId, Double)?)
    case up(id: NodeId?, velocity: Float)
    case move(id: NodeId, d: Float)
    case tick(id: NodeId, horizontal: Bool, overflow: Double, dt: Float)
    case settled(moving: Bool)

    public static func == (lhs: TouchEvent, rhs: TouchEvent) -> Bool {
        switch (lhs, rhs) {
        case (.down(let la, let lv), .down(let ra, let rv)):
            return la?.0 == ra?.0 && la?.1 == ra?.1 && lv?.0 == rv?.0 && lv?.1 == rv?.1
        case (.pan(let lh, let la, let lv), .pan(let rh, let ra, let rv)):
            return lh == rh && la?.0 == ra?.0 && la?.1 == ra?.1 && lv?.0 == rv?.0 && lv?.1 == rv?.1
        case (.up(let li, let lv), .up(let ri, let rv)):
            return li == ri && lv == rv
        case (.move(let li, let ld), .move(let ri, let rd)):
            return li == ri && ld == rd
        case (.tick(let li, let lh, let lo, let ldt), .tick(let ri, let rh, let ro, let rdt)):
            return li == ri && lh == rh && lo == ro && ldt == rdt
        case (.settled(let lm), .settled(let rm)):
            return lm == rm
        default:
            return false
        }
    }
}

/// What carrying out a touch transition does to the scroll viewports (`touch.rs::TouchEffect`).
public enum TouchEffect: Sendable, Equatable {
    case halt(NodeId)
    case stopAcross(NodeId)
    case fling(id: NodeId, horizontal: Bool, velocity: Float)
    case pan(id: NodeId, origin: Double, horizontal: Bool, d: Float)
    case hold(id: NodeId, horizontal: Bool, overflow: Double)
    case coast(id: NodeId, horizontal: Bool, overflow: Double, dt: Float)
}

/// Pure transition & edge-return math for touch scrolling (`touch.rs::step`, `touch.rs::rebound`).
public enum TouchScrollMachine: Sendable {
    @discardableResult
    public static func step(_ state: inout TouchScroll?, _ event: TouchEvent) -> Effects<TouchEffect> {
        switch (state, event) {
        case (let current, .down(let across, let vertical)):
            let caught: Bool
            if let t = current, let (id, _) = across, t.horizontal && t.id == id {
                caught = true
            } else {
                caught = false
            }
            if caught {
                state = across.map { .held(id: $0.0, origin: $0.1, horizontal: true) }
            } else if let (id, at) = vertical {
                state = .held(id: id, origin: at, horizontal: false)
            }
            var effects = Effects<TouchEffect>.none
            if let (id, _) = across {
                effects.push(.stopAcross(id))
            }
            if let (id, _) = vertical {
                effects.push(.halt(id))
            }
            return effects

        case (_, .pan(horizontal: true, across: .some((let id, let at)), vertical: _)):
            state = .dragging(id: id, origin: at, horizontal: true)
            return .none

        case (.some(let t), .pan(horizontal: _, across: _, vertical: .some((let id, let at)))):
            let origin = t.horizontal ? at : (t.origin ?? at)
            state = .dragging(id: id, origin: origin, horizontal: false)
            return .none

        case (.some(let t), .pan) where t.horizontal:
            state = .coasting(id: t.id, horizontal: true)
            return .none

        case (_, .pan):
            return .none

        case (.some(let t), .up(let id, let velocity)):
            state = .coasting(id: t.id, horizontal: t.horizontal)
            if t.id == id {
                return .one(.fling(id: t.id, horizontal: t.horizontal, velocity: velocity))
            } else {
                return .none
            }

        case (.some(.dragging(let held, let origin, let horizontal)), .move(let id, let d)) where held == id:
            return .one(.pan(id: id, origin: origin, horizontal: horizontal, d: d))

        case (.some(let t), .tick(let id, let horizontal, let overflow, let dt))
            where t.id == id && t.horizontal == horizontal:
            if t.coasting {
                return .one(.coast(id: id, horizontal: horizontal, overflow: overflow, dt: dt))
            } else {
                return .one(.hold(id: id, horizontal: horizontal, overflow: overflow))
            }

        case (.some(let t), .settled(moving: false)) where t.coasting:
            state = nil
            return .none

        default:
            return .none
        }
    }

    /// A critically damped edge return, integrated exactly for variable frame times (`touch.rs::rebound`).
    public static func rebound(offset: Double, velocity: Float, target: Double, dt: Float) -> (Double, Float) {
        let dt64 = Double(dt)
        let displacement = offset - target
        let b = Double(velocity) + 14.0 * displacement
        let decay = exp(-14.0 * dt64)
        return (
            target + (displacement + b * dt64) * decay,
            Float((Double(velocity) - 14.0 * b * dt64) * decay)
        )
    }
}

// MARK: - Scroll Offset Watcher (`crates/rune/src/runtime/scroll/watch.rs`)

/// Scroll watcher state machine (`watch.rs::Watch`, `watch.rs::step`, `@TaskLocal` state).
public enum ScrollWatch: Sendable {
    /// Runs `operation` with task-local `scrollWatchState()` bound to `(scrolled, instant, now)`.
    public static func withState<T>(
        scrolled: Bool,
        instant: Bool,
        now: Double,
        operation: () throws -> T
    ) rethrows -> T {
        try ScrollWatchTLS.$current.withValue(
            ScrollWatchState(active: true, scrolled: scrolled, instant: instant, now: now),
            operation: operation
        )
    }

    /// Identity-tracked callback wrapper analogous to `Rc<dyn Fn(ScrollPos)>`.
    public final class Handler: @unchecked Sendable {
        public let call: (ScrollPos) -> Void

        public init(_ call: @escaping (ScrollPos) -> Void = { _ in }) {
            self.call = call
        }
    }

    /// What a viewport's `El.onScrollOffset` has been told, and which of its handlers heard it (`watch.rs::Watch`).
    public struct Watch: Sendable {
        public var told: ScrollPos?
        public weak var handler: Handler?

        public init(told: ScrollPos? = nil, handler: Handler? = nil) {
            self.told = told
            self.handler = handler
        }
    }

    public enum Event: Sendable {
        case seen(at: ScrollPos, handler: Handler?, byHand: Bool)
    }

    public enum Effect: Sendable, Equatable {
        case tell(at: ScrollPos, scrolled: Bool)
    }

    /// Calls the handler when where the viewport stands changed, or when it is a new one that
    /// has not heard it (`watch.rs::step`).
    @discardableResult
    public static func step(_ watch: inout Watch, _ event: Event) -> Effects<Effect> {
        switch event {
        case .seen(let at, let f, let byHand):
            guard let f else { return .none }
            let prev = watch.told
            watch.told = at
            let changed = prev != at
            let newHandler = watch.handler !== f
            if newHandler {
                watch.handler = f
            }
            if !changed && !newHandler {
                return .none
            }
            let scrolled = byHand && (prev.map { old in
                abs(old.offset.x - at.offset.x) > 0.01 || abs(old.offset.y - at.offset.y) > 0.01
            } ?? false)
            return .one(.tell(at: at, scrolled: scrolled))
        }
    }
}

// MARK: - Bottom Slack State Machine (`crates/rune/src/runtime/scroll/bottom.rs`)

/// Whether the slack waits under the rows or closes on the growth spring (`bottom.rs::SlackPhase`).
public enum SlackPhase: Sendable, Equatable {
    /// Held while the stack grows, and for `slackWait` after a row last grew (`grewAt`).
    case held(grewAt: Double)
    /// Closing, with `acc` seconds of frame time not yet stepped in `Growth.substep`s.
    case closing(acc: Float)

    public static let `default`: SlackPhase = .held(grewAt: 0.0)
    /// Done closing without the stack growing again: the wait is already over.
    public static let waited: SlackPhase = .held(grewAt: -.infinity)
}

/// Room a pinned viewport gains at its bottom (`bottom.rs::Slack`).
public struct ScrollSlack: Sendable, Equatable {
    /// A glide starts at most this many viewports above the bottom.
    public static let glideReach: Double = 2.0
    /// Within this many points of the bottom a viewport counts as showing it.
    public static let atBottom: Double = 1.0
    /// Slack starts closing once its stack has stopped growing for this long (seconds).
    public static let slackWait: Double = 0.12

    public var track: GrowTrack
    public var phase: SlackPhase
    public var stepped: Bool
    public var edges: SIMD2<Float>?
    public var window: (Float, Float)
    public var follow: Bool

    public init(
        track: GrowTrack = GrowTrack(),
        phase: SlackPhase = .default,
        stepped: Bool = false,
        edges: SIMD2<Float>? = nil,
        window: (Float, Float) = (0.0, 0.0),
        follow: Bool = false
    ) {
        self.track = track
        self.phase = phase
        self.stepped = stepped
        self.edges = edges
        self.window = window
        self.follow = follow
    }

    public static func == (lhs: ScrollSlack, rhs: ScrollSlack) -> Bool {
        lhs.track == rhs.track
            && lhs.phase == rhs.phase
            && lhs.stepped == rhs.stepped
            && lhs.edges == rhs.edges
            && lhs.window.0 == rhs.window.0
            && lhs.window.1 == rhs.window.1
            && lhs.follow == rhs.follow
    }

    public var height: Float { track.h }

    public var moving: Bool { track.h > 0.0 || stepped }

    /// No slack, in a window of this size.
    public static func landed(window: (Float, Float)) -> ScrollSlack {
        ScrollSlack(window: window)
    }

    /// Moves the phase on at `now` with `dt` of frame time (`bottom.rs::Slack::settle`).
    public mutating func settle(growing: Bool, now: Double, dt: Float, spec: GrowthSpec) {
        if growing {
            phase = .held(grewAt: now)
            track.v = 0.0
        }
        if track.h <= 1.0 / 128.0 {
            track = GrowTrack()
            if case .closing = phase {
                phase = .waited
            }
        } else if case .held(let grewAt) = phase, now - grewAt >= Self.slackWait {
            phase = .closing(acc: 0.0)
            track.age = 0.0
            track.v = 0.0
        }
        if case .closing(var acc) = phase {
            acc += dt
            while acc >= Growth.substep {
                track.step(spring: spec.spring, edge: spec.edge, carryingTail: false)
                acc -= Growth.substep
            }
            if track.moving {
                phase = .closing(acc: acc)
            } else {
                track = GrowTrack()
                phase = .waited
            }
        }
    }
}
