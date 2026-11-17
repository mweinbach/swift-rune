import Foundation

// MARK: - Wheel Lock (`runtime/scroll/x.rs` `WheelLock` / `WheelRun` / `WheelPhase`)
//
// A gesture moves one axis, picked by its first delta, as AppKit's predominant-axis scrolling
// does: mostly horizontal goes to the innermost horizontal viewport under the pointer, else to
// the innermost vertical one, and a diagonal never moves both. The gesture keeps that axis
// wherever the pointer ends up. Without phases (a mouse wheel), only a pause or a delta wholly
// on the other axis ends the lock, so Shift + wheel and then the plain wheel each scroll at once.
//
// Upstream r241 / r382 (`3ceb02f9`, `248a84c7`, `0edeaa53`, `f1608482`): the lock's owner and
// the gesture it belongs to are one `WheelRun`, so a delta of an older gesture still waiting for
// `on_wheel` handlers keeps that gesture's owner (and axis policy) while a newer one arrives.

/// Who has the gesture `WheelLock` runs (`scroll/x.rs` `WheelOwner`).
internal enum WheelOwner: Equatable {
    /// Nobody yet: its first delta picks.
    case unpicked
    /// The `onWheel` element that took the gesture's first delta and hears the rest.
    case handler(String)
    /// Scrolling vertically.
    case vertical
    /// Scrolling the horizontal viewport the gesture began on, latched through the gesture
    /// and its momentum.
    case horizontal(String)

    /// Horizontal (`true`) or vertical, once a delta picked an axis (`WheelOwner::horizontal`).
    var isHorizontalAxis: Bool? {
        switch self {
        case .vertical: return false
        case .horizontal: return true
        case .unpicked, .handler: return nil
        }
    }
}

/// Who has the deltas still to run, keyed by the gesture each belongs to: the gesture arriving
/// now, and, until they run, the older gesture whose queued deltas already had an owner
/// (`scroll/x.rs` `WheelRun`).
internal enum WheelRun: Equatable {
    /// The arriving gesture has `owner`: its deltas go to it, and its first delta picks it afresh.
    case arriving(WheelOwner)
    /// Deltas of `gesture` still wait: `owner` takes them. The gesture arriving now has
    /// `arriving` of its own, which it picks when one of its deltas scrolls before those queued
    /// ones run.
    case waiting(gesture: AttemptToken, owner: WheelOwner, arriving: WheelOwner)

    /// Who has the gesture arriving now.
    var arriving: WheelOwner {
        get {
            switch self {
            case .arriving(let owner): return owner
            case .waiting(_, _, let arriving): return arriving
            }
        }
        set {
            switch self {
            case .arriving: self = .arriving(newValue)
            case .waiting(let g, let owner, _): self = .waiting(gesture: g, owner: owner, arriving: newValue)
            }
        }
    }

    /// Who has `gesture`'s queued deltas, while the lock holds them.
    func waiting(_ gesture: AttemptToken) -> WheelOwner? {
        if case .waiting(let g, let owner, _) = self, g == gesture { return owner }
        return nil
    }

    /// Replaces the owner of `gesture`'s queued deltas, when the lock holds them.
    mutating func setWaiting(_ gesture: AttemptToken, _ owner: WheelOwner) {
        if case .waiting(let g, _, let arriving) = self, g == gesture {
            self = .waiting(gesture: g, owner: owner, arriving: arriving)
        }
    }

    /// `std::mem::take(run.arriving_mut())`: the arriving owner, leaving `.unpicked`.
    mutating func takeArriving() -> WheelOwner {
        let owner = arriving
        arriving = .unpicked
        return owner
    }

    /// `run.waiting_mut(gesture).map(std::mem::take)`.
    mutating func takeWaiting(_ gesture: AttemptToken) -> WheelOwner? {
        guard let owner = waiting(gesture) else { return nil }
        setWaiting(gesture, .unpicked)
        return owner
    }
}

/// The phase a gesture had when the platform ended it (`scroll/x.rs` `GestureKind`).
internal enum WheelGestureKind: Equatable {
    case unphased
    case phased
    case momentum
}

/// Whether the platform reports the gesture's phases, and when it last moved or ended
/// (`scroll/x.rs` `WheelPhase`).
internal enum WheelPhaseState: Equatable {
    /// No phases (a mouse wheel): a pause or a delta wholly on the other axis ends it. `at` is
    /// when its last delta came, `nil` before the first.
    case unphased(at: Double?)
    /// The platform began it at `at`: it holds the axis until it ends, however slowly it moves.
    case phased(at: Double)
    /// The momentum of a phased gesture that ended, last moving at `at`.
    case momentum(at: Double)
    /// The platform ended it at `at`; `from` is the phase it had then.
    case ended(at: Double, from: WheelGestureKind)

    /// Whether the platform reports its phases: it has begun it, or it ended one that had.
    var isPhased: Bool {
        switch self {
        case .unphased, .ended(_, .unphased): return false
        case .phased, .momentum, .ended(_, .phased), .ended(_, .momentum): return true
        }
    }

    /// The gesture is the momentum of one that ended, or ended as momentum.
    var isMomentum: Bool {
        switch self {
        case .momentum, .ended(_, .momentum): return true
        default: return false
        }
    }

    /// When its last delta came.
    var at: Double? {
        switch self {
        case .unphased(let t): return t
        case .phased(let t), .momentum(let t), .ended(let t, _): return t
        }
    }

    /// When the platform ended it, while that is what happened last.
    var endedAt: Double? {
        if case .ended(let t, _) = self { return t }
        return nil
    }

    /// The same live phase, with its last delta at `now`.
    func moving(to now: Double) -> WheelPhaseState {
        switch self {
        case .unphased: return .unphased(at: now)
        case .phased: return .phased(at: now)
        case .momentum: return .momentum(at: now)
        case .ended: return self
        }
    }
}

/// The wheel or trackpad gesture in progress, and who has it. Its phase carries when its last
/// delta came and, once the platform ended it, when that was (`scroll/x.rs` `WheelLock`).
internal struct WheelLock {
    /// Seconds without a delta after which the next one starts a new gesture, where the platform
    /// reports no phases (a mouse wheel, most trackpads off macOS).
    static let wheelIdle: Double = 0.1
    /// Seconds without a delta after which a gesture the platform began counts as over, should
    /// its end never come.
    static let phasedIdle: Double = 1.0
    /// A gesture that begins within this many seconds of one ending is its momentum.
    static let momentumGap: Double = 0.05

    private var seq = Seq()
    /// The gesture deltas arriving now belong to: a new one whenever a gesture starts or the
    /// window loses the gesture.
    private(set) var gesture = AttemptToken()
    /// Who has the gesture's deltas: the arriving gesture's owner, or the previous gesture's
    /// while deltas of it still wait for `onWheel` handlers.
    private(set) var run: WheelRun = .arriving(.unpicked)
    var phase: WheelPhaseState = .unphased(at: nil)

    /// Who has the gesture arriving now: deltas of older gestures don't reach it.
    var owner: WheelOwner { run.arriving }

    /// Who has `gesture`'s deltas: the arriving gesture's own, or an older gesture's while its
    /// queued deltas still run.
    func ownerOf(_ gesture: AttemptToken) -> WheelOwner? {
        gesture == self.gesture ? run.arriving : run.waiting(gesture)
    }

    /// Who has `gesture`'s deltas becomes `owner`, giving a gesture the lock doesn't hold a
    /// fresh start of its own beside the arriving one's.
    mutating func setOwner(_ gesture: AttemptToken, _ owner: WheelOwner) {
        if gesture == self.gesture {
            run.arriving = owner
        } else {
            syncGesture(gesture)
            run.setWaiting(gesture, owner)
        }
    }

    /// Whether the platform reports the phases of the gesture the lock runs.
    var phased: Bool { phase.isPhased }

    /// The gesture is the momentum of one that ended (`WheelEvent.momentum`).
    var momentum: Bool { phase.isMomentum }

    /// A delta of `gesture` runs: an owner the lock already holds for that gesture takes it, and
    /// any other queued gesture starts afresh, beside the arriving gesture's own owner.
    mutating func syncGesture(_ gesture: AttemptToken) {
        if gesture == self.gesture || run.waiting(gesture) != nil { return }
        let arriving = run.takeArriving()
        run = .waiting(gesture: gesture, owner: .unpicked, arriving: arriving)
    }

    /// The next gesture starts, unphased. Only an owner whose gesture still has a delta waiting
    /// for `onWheel` handlers keeps its place: `pending` is the gesture the oldest queued delta
    /// belongs to, so one that has run its last delta gives its owner up.
    mutating func restart(pending: AttemptToken?) {
        let arriving = gesture
        var old = run
        gesture = seq.nextAttempt()
        phase = .unphased(at: nil)
        if let next = pending {
            if next == arriving {
                run = .waiting(gesture: next, owner: old.takeArriving(), arriving: .unpicked)
            } else {
                run = .waiting(gesture: next, owner: old.takeWaiting(next) ?? .unpicked, arriving: .unpicked)
            }
        } else {
            run = .arriving(.unpicked)
        }
    }

    /// The axis `gesture`'s owner keeps for a delta (dx, dy): horizontal (`true`) or vertical, or
    /// `nil` when it picks afresh. `phased` is the delta's own gesture's policy: without phases,
    /// a delta wholly on the other axis is another wheel turning (Shift let go, a tilt, a second
    /// device).
    func keepsAxis(_ gesture: AttemptToken, dx: Float, dy: Float, phased: Bool) -> Bool? {
        guard let h = ownerOf(gesture)?.isHorizontalAxis else { return nil }
        return (phased || (h ? dx != 0 : dy != 0)) ? h : nil
    }

    /// A delta picked afresh: the horizontal viewport under it (`acrossPath`), else vertical.
    /// Returns whether it scrolls horizontally.
    @discardableResult
    mutating func repick(_ gesture: AttemptToken, acrossPath: String?) -> Bool {
        setOwner(gesture, acrossPath.map { .horizontal($0) } ?? .vertical)
        return acrossPath != nil
    }

    /// A delta arrived at `now`, on (dx, dy) points: a gesture idle too long, ended, or wholly
    /// on the other axis (Shift let go, a tilt, a second wheel), is over, and this delta starts
    /// the next.
    mutating func delta(at now: Double, dx: Float, dy: Float, pending: AttemptToken?) {
        let phased = phase.isPhased
        let idle = phased ? Self.phasedIdle : Self.wheelIdle
        let flipped = !phased && run.arriving.isHorizontalAxis.map { $0 ? dx == 0 : dy == 0 } == true
        let stale = phase.endedAt != nil || phase.at.map { now - $0 > idle } ?? true || flipped
        if stale { restart(pending: pending) }
        phase = phase.moving(to: now)
    }

    /// The platform began a gesture at `now`: its first delta picks the axis afresh, unless it
    /// is the momentum of one that just ended. `active`: the arriving gesture has an owner;
    /// `queued`: a delta of it still waits for `onWheel` handlers.
    mutating func began(at now: Double, active: Bool, queued: Bool, pending: AttemptToken?) {
        let isMomentum = !phase.isMomentum && (active || queued)
            && phase.endedAt.map { now - $0 <= Self.momentumGap } == true
        if !isMomentum { restart(pending: pending) }
        phase = isMomentum ? .momentum(at: now) : .phased(at: now)
    }

    /// The platform ended the gesture at `now`, keeping the phase it had.
    mutating func ended(at now: Double) {
        let from: WheelGestureKind
        switch phase {
        case .unphased: from = .unphased
        case .phased: from = .phased
        case .momentum: from = .momentum
        case .ended(_, let kind): from = kind
        }
        phase = .ended(at: now, from: from)
    }

    /// The window lost the pointer or focus: a gesture in progress won't report its end here.
    mutating func lost(pending: AttemptToken?) {
        restart(pending: pending)
    }
}
