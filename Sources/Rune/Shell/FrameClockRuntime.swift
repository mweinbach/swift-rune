import Foundation
import RuneMotion

extension Runtime {
    /// Advances logical time by `dt`, evaluates one frame pass, and steps animations by `dt`
    /// (`Runtime::frame(dt)` / `frame_split(0.0, dt)`).
    @discardableResult
    public func frameStep(dt: Double) -> Bool {
        runFrameSplit(catchUp: 0.0, dt: dt, hostDelta: dt)
    }

    /// Advances running motion by `catchUp` before poll/commit, then steps all motion (including
    /// newly started tracks) by `dt` in a single frame pass (`Runtime::frame_split`).
    @discardableResult
    public func frameSplit(catchUp: Double, dt: Double, hostDelta: Double? = nil) -> Bool {
        runFrameSplit(catchUp: catchUp, dt: dt, hostDelta: hostDelta ?? (catchUp + dt))
    }
}

extension FrameClock {
    /// Steps `rt` to the frame presented at `target` in one runtime pass (`FrameClock::advance`).
    @discardableResult
    public func advance<State>(
        _ rt: Runtime<State>,
        at target: Double,
        compositing: Bool = false
    ) -> (animating: Bool, stepped: Double) {
        let prev = lastTarget
        let hostDelta = max(0.0, target - prev)
        let step = frameStep(at: target, running: rt.isAnimating || compositing)
        let animating = rt.runFrameSplit(catchUp: step.catchUp, dt: step.dt, hostDelta: hostDelta)
        recordStepStarts(rt.scene.store.started())
        return (animating, step.total)
    }

    /// Delays animations started on the last stepped frame when presentation finished late at `done`
    /// (`FrameClock::presented`).
    public func presented<State>(_ rt: Runtime<State>, done: Double) {
        var (late, starts) = takePresentedDelay(done: done)
        guard late > 0.0, !starts.isEmpty else { return }
        rt.delayStartedTracks(&starts, by: late * Double(rt.timeScale))
    }

    /// Steps `rt` by `gap` seconds without a wall presentation clock (`frame::clock::advance_by`).
    @discardableResult
    public static func advanceBy<State>(_ rt: Runtime<State>, gap: Double) -> Bool {
        let step = FrameClockStep.split(gap: gap, running: rt.isAnimating)
        let effectiveGap = max(0.0, gap)
        return rt.runFrameSplit(catchUp: step.catchUp, dt: step.dt, hostDelta: effectiveGap)
    }
}
