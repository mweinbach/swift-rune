import Foundation

// MARK: - Wheel Gesture Runtime (`runtime/scroll/x.rs` `wheel_began` / `wheel_ended` / `wheel_lost`)

extension Runtime {
    /// The gesture the oldest wheel delta still waiting for `onWheel` handlers belongs to
    /// (`scroll/x.rs` `Runtime::wheel_pending`): the only owner a new gesture can hand over to.
    ///
    /// Upstream queues a delta offered to `on_wheel` handlers as `Action::Wheel` and runs it
    /// when the next frame drains the queue. The Swift runtime runs `onWheel` handlers at the
    /// event (`runWheel`, called from `dispatchLockedWheel`), so by the time the next delta or
    /// phase arrives every earlier delta has already run under its own gesture: no delta waits,
    /// and the lock always hands over from an empty queue.
    internal var wheelPending: AttemptToken? { nil }

    /// `scroll/x.rs` `wheel_delta_arrived`: a gesture idle too long, or ended and not followed
    /// by its momentum, is over, and this delta starts the next. Without phases, a delta wholly
    /// on the other axis (Shift let go, a tilt, a second wheel) also starts a new gesture.
    internal func wheelDeltaArrived(dx: Float, dy: Float, now: Double) {
        inputMachines.wheelLock.delta(at: now, dx: dx, dy: dy, pending: wheelPending)
    }

    /// The platform began a trackpad gesture (`GesturePhase.began` on a wheel event): its first
    /// delta picks the axis afresh, unless it is the momentum of one that just ended
    /// (`Runtime::wheel_began`).
    public func wheelBegan(now: Double) {
        let pending = wheelPending
        // A delta of the arriving gesture queued for `onWheel` handlers hasn't picked who has
        // the gesture yet (`wheel_queued(Some(gesture))`).
        let queued = pending == inputMachines.wheelLock.gesture
        let active = inputMachines.wheelLock.owner != .unpicked
        inputMachines.wheelLock.began(at: now, active: active, queued: queued, pending: pending)
    }

    /// The platform ended a trackpad gesture (`GesturePhase.ended` or `.cancelled`)
    /// (`Runtime::wheel_ended`).
    public func wheelEnded(now: Double) {
        inputMachines.wheelLock.ended(at: now)
    }

    /// The window lost the pointer or focus: a gesture in progress won't report its end here
    /// (`Runtime::wheel_lost`).
    public func wheelLost() {
        inputMachines.wheelLock.lost(pending: wheelPending)
    }
}
