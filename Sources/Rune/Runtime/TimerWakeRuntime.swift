import Foundation
import RuneMotion

extension Runtime {
    /// Fixed 60 Hz timer floor matching `crate::window::TIMER_FRAME` (`1 / 60` s).
    public static var timerFrameInterval: Double {
        1.0 / 60.0
    }

    /// Host wall time elapsed since `wallStart` (`Runtime::wall_clock`), or `nil` headless.
    internal func wallClock() -> Double? {
        wallStart.map { ProcessInfo.processInfo.systemUptime - $0 }
    }

    /// Current logical clock in seconds: real elapsed wall clock when driven by `wallStart`,
    /// otherwise the virtual headless `currentTime` (`Runtime::now_clock`).
    public func nowClock() -> Double {
        wallClock() ?? currentTime
    }

    /// Shifts `wallStart` backward by `seconds` so elapsed wall time moves forward deterministically.
    public func advanceWallStart(by seconds: Double) {
        if let start = wallStart {
            wallStart = start - seconds
        }
    }

    /// Native surface frame counts when attached to a live view (`Runtime::surface_stats`), or `nil` headless.
    public func surfaceStats() -> SurfaceStats? {
        surfaceMeter?.currentStats()
    }

    /// When the timer poll that stands for the current frame ran, or `currentTime` (`Runtime::polled_at`).
    public func polledAt() -> Double {
        timerWake.takenPolledAt ?? currentTime
    }

    /// Earliest scheduled wake on the unscaled app clock (`Runtime::logical_wake_deadline`).
    internal func logicalWakeDeadline() -> Double? {
        // An instant scroll's hold draws nothing until it ends: wake for the one frame that
        // resolves hover then (`frame.rs` `wake_for_clock(hold_wake)`).
        [wakeDeadlines.first, nextLoopWakeDeadline(after: currentTime), scrollNudgeWakeDeadline(after: currentTime)]
            .compactMap { $0 }.min()
    }

    /// Next due timer deadline scheduled by `Tx.wakeAfter` (`Runtime::poll_wake_deadline`).
    public func pollWakeDeadline() -> Double? {
        wakeDeadlines.first
    }

    /// Next frame deadline requested by active motion cadences (`Runtime::motion_wake_deadline`).
    public func motionWakeDeadline() -> Double? {
        nextLoopWakeDeadline(after: currentTime)
    }

    /// Next headless substep deadline before `target` when `frameStep`/`frameSplit` spans timer wakes (`Runtime::timer_step`).
    internal func nextTimerStepDeadline(before target: Double) -> Double? {
        guard let deadline = logicalWakeDeadline() else { return nil }
        let at = max(deadline, currentTime + Self.timerFrameInterval)
        return at < target ? at : nil
    }

    /// Schedules a direct deadline in `wakeDeadlines` (`Runtime::wake_at`).
    public func wakeAt(_ due: Double) {
        scheduleWakes(from: due, delays: [0.0])
    }

    /// Schedules `delays` relative to `base` into sorted, deduplicated `wakeDeadlines` (`Runtime::schedule_wakes_from`).
    public func scheduleWakes(from base: Double, delays: [Double]) {
        for delay in delays where delay.isFinite {
            let deadline = base + max(0.0, delay)
            if let existingIdx = wakeDeadlines.firstIndex(where: { $0 >= deadline }) {
                if wakeDeadlines[existingIdx] != deadline {
                    wakeDeadlines.insert(deadline, at: existingIdx)
                }
            } else {
                wakeDeadlines.append(deadline)
            }
        }
    }

    /// Promotes any queued out-of-frame `wakeAfter` delays relative to `nowClock()` (`Runtime::schedule_pending_wakes`).
    public func schedulePendingWakes() {
        schedulePendingWakes(from: nowClock())
    }

    internal func schedulePendingWakes(from base: Double) {
        guard !pendingUpdateWakes.isEmpty else { return }
        let delays = pendingUpdateWakes.map(\.delay)
        pendingUpdateWakes.removeAll(keepingCapacity: true)
        scheduleWakes(from: base, delays: delays)
    }

    internal func promotePendingWakes(at now: Double) {
        if !pendingUpdateWakes.isEmpty {
            let delays = pendingUpdateWakes.map(\.delay)
            pendingUpdateWakes.removeAll(keepingCapacity: true)
            scheduleWakes(from: now, delays: delays)
        }
        if !pendingFrameWakes.isEmpty {
            let delays = pendingFrameWakes.map(\.delay)
            pendingFrameWakes.removeAll(keepingCapacity: true)
            scheduleWakes(from: now, delays: delays)
        }
    }

    internal func drainDueWakeDeadlines(through now: Double) {
        guard let firstFuture = wakeDeadlines.firstIndex(where: { $0 > now }) else {
            wakeDeadlines.removeAll(keepingCapacity: true)
            return
        }
        if firstFuture > 0 {
            wakeDeadlines.removeFirst(firstFuture)
        }
    }

    /// Builds stale content for a `fitHeight` window before ordering it in (`Runtime::build_for_show`).
    @discardableResult
    public func buildForShow() -> Bool {
        guard fitHeight, viewCommitCount > 0, isStale else { return false }
        settleAll()
        _ = frame(at: nowClock())
        return true
    }

    /// Runs `poll` while hidden using the runtime clock (`Runtime::poll_hidden`).
    @discardableResult
    public func pollHidden() -> Bool {
        let now = nowClock()
        if timerWake.isAsked && (wakeDeadlines.first.map { $0 > now } ?? true) {
            cancelTimerFrame()
            return hasPendingHiddenWork
        }
        let stale = pollAlone(at: now)
        schedulePendingWakes(from: now)
        return stale
    }

    /// Executes `poll` alone without scheduling its new `wakeAfter` delays yet (`Runtime::poll_alone`).
    internal func pollAlone(at now: Double) -> Bool {
        _ = timerWake.step(.pollAlone)
        let clock = wallClock() ?? now
        currentTime = clock
        schedulePendingWakes(from: clock)
        drainDueWakeDeadlines(through: clock)
        let changed = runPoll(at: clock)
        // The tree this change builds hasn't committed: input before the next frame commits it
        // apart (`self.pending.polled_change |= changed`).
        polledChange = polledChange || changed
        return changed || hasPendingHiddenWork
    }

    private var stepsFrames: Bool {
        wakeDeadlines.first.map { $0 <= currentTime } ?? false
    }

    /// True when nothing other than a scheduled timer wake asks for a frame (`Runtime::rests`).
    public func rests() -> Bool {
        !isAnimating
            && !isStale
            && !forceInitialSettle
            && nextLoopWakeDeadline(after: currentTime) == nil
            && pendingWindowFrame == nil
            && hoverDelays.isEmpty
            && !isTooltipWaiting
            && kitHooks.pressRepeat.nextWakeDeadline(after: currentTime) == nil
            && !filesHeld
            && !livePending
            && surfaces.isEmpty
            && !stepsFrames
    }

    /// Runs a due timer while resting (`Runtime::resting_wake`), returning whether the poll wants a frame,
    /// or `nil` when active work will drive the frame itself.
    public func restingWake() -> Bool? {
        guard rests() else { return nil }
        let stale = pollAlone(at: currentTime)
        let steps = pendingUpdateWakes.contains { $0.delay == 0.0 }
        return stale || pendingWindowFrame != nil || steps || virtualFill.resuming(at: currentTime)
    }

    /// Records whether the host requested a frame after `restingWake()` (`Runtime::resting_wake_frame`).
    public func restingWakeFrame(_ frame: Bool) {
        if frame {
            timerWake.restingWakeFrame(true, at: currentTime)
        } else {
            schedulePendingWakes(from: currentTime)
        }
    }

    /// Cancels a pending timer-requested frame and schedules its wakes from the poll timestamp (`Runtime::cancel_timer_frame`).
    public func cancelTimerFrame() {
        guard let polled = timerWake.cancelTimerFrame() else { return }
        schedulePendingWakes(from: polled)
    }
}
