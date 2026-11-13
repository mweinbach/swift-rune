import Foundation
import Testing
@testable import Rune
@testable import RuneMotion

/// Full 1:1 port of upstream `crates/rune/src/frame/clock.rs` (all 8 `#[test]`s).
@Suite("FrameClock Parity Tests (8/8)", .serialized)
struct FrameClockParityTests {

    private static let frame: Double = 0.016667
    private static let late: Double = 6.0 * frame + 0.0493

    private struct Pair {
        var a: Float = 12.0
        var b: Float = 12.0
        var polls: UInt32 = 0
    }

    private func makeRuntime() -> Runtime<Pair> {
        let rt = Runtime<Pair>(
            state: Pair(),
            viewport: Vec2(400, 50),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col().children([
                el().key("a").size(s.a, 8.0).animateLayout(),
                el().key("b").size(s.b, 8.0).animateLayout(),
            ])
        }
        rt.poll = { s, _, _ in
            s.polls &+= 1
            return false
        }
        return rt
    }

    private func width(_ rt: Runtime<Pair>, _ key: String) -> Float {
        rt.element(byKey: key)!.rect[2]
    }

    private func cadence() -> [Double] {
        (0...6).map { Double($0) * Self.frame }
    }

    private func run(
        times: [Double],
        at triggerTime: Double,
        onTrigger: (Runtime<Pair>) -> Void
    ) -> [(Double, Float, Float)] {
        let start = 100.0
        let clock = FrameClock(start: start)
        let rt = makeRuntime()
        return times.map { t in
            if t == Self.frame {
                rt.update { s, _ in s.a = 212.0 }
            }
            if t == triggerTime {
                onTrigger(rt)
            }
            _ = clock.advance(rt, at: start + t, compositing: false)
            return (t, width(rt, "a"), width(rt, "b"))
        }
    }

    private func at(_ frames: [(Double, Float, Float)], _ t: Double) -> (Float, Float) {
        let match = frames.first { $0.0 == t }!
        return (match.1, match.2)
    }

    // 1. running_motion_keeps_real_time_and_new_motion_takes_one_small_step
    @Test func runningMotionKeepsRealTimeAndNewMotionTakesOneSmallStep() {
        let start = 100.0
        let ms: (Double) -> Double = { $0 / 1000.0 }
        let clock = FrameClock(start: start)
        let fresh = FrameClockStep(catchUp: 0.0, dt: FrameClock.resumeStep)

        #expect(clock.frameStep(at: start + ms(5), running: false) == fresh, "first frame")
        #expect(clock.frameStep(at: start + ms(2005), running: false) == fresh, "after idle, however long")

        let late = clock.frameStep(at: start + ms(2054), running: true)
        #expect(abs(late.total - 0.049) < 1e-9 && late.dt == FrameClock.resumeStep)

        let short = clock.frameStep(at: start + ms(2058), running: true)
        #expect(abs(short.dt - 0.004) < 1e-9 && short.catchUp == 0.0)

        let suspended = clock.frameStep(at: start + ms(5058), running: true)
        #expect(abs(suspended.total - FrameClock.maxGap) < 1e-9 && suspended.dt == FrameClock.resumeStep)

        clock.hold(at: start + ms(6000))
        #expect(clock.frameStep(at: start + ms(6000), running: true) == FrameClockStep(catchUp: 0.0, dt: 0.0))

        clock.hold(at: start + ms(6010))
        clock.hold(at: start + ms(6002))
        let next = clock.frameStep(at: start + ms(6018), running: true)
        #expect(abs(next.total - 0.008) < 1e-9)
    }

    // 2. window_late_frame_lands_where_an_unbroken_cadence_would
    @Test func windowLateFrameLandsWhereAnUnbrokenCadenceWould() {
        let after = [Self.late, Self.late + Self.frame, Self.late + 2.0 * Self.frame]
        var steadyTimes = (0...8).map { Double($0) * Self.frame }
        steadyTimes.append(contentsOf: after)
        var hitchedTimes = cadence()
        hitchedTimes.append(contentsOf: after)

        let steady = run(times: steadyTimes, at: .greatestFiniteMagnitude) { _ in }
        let hitched = run(times: hitchedTimes, at: .greatestFiniteMagnitude) { _ in }

        for t in after {
            let (expected, _) = at(steady, t)
            let (got, _) = at(hitched, t)
            #expect(expected < 211.0, "the spring must still be moving at \(t): \(expected)")
            #expect(abs(got - expected) < 0.01, "at \(t) width=\(got), unbroken cadence=\(expected)")
        }
    }

    // 3. window_motion_starting_after_idle_takes_one_frame_step
    @Test func windowMotionStartingAfterIdleTakesOneFrameStep() {
        let firstPose: (Double) -> Float = { idle in
            let start = 100.0
            let clock = FrameClock(start: start)
            let rt = makeRuntime()
            _ = clock.advance(rt, at: start, compositing: false)
            #expect(!clock.advance(rt, at: start + Self.frame, compositing: false).animating)
            rt.update { s, _ in s.b = 212.0 }
            _ = clock.advance(rt, at: start + Self.frame + idle, compositing: false)
            return width(rt, "b")
        }
        let short = firstPose(Self.frame)
        let long = firstPose(2.0)
        #expect(short > 12.0 && short < 20.0, "the first frame shows one step of motion: \(short)")
        #expect(abs(long - short) < 0.001, "idle time must not age motion that starts after it: \(long) vs \(short)")
    }

    // 4. motion_starting_on_a_late_frame_takes_one_small_step_while_running_motion_catches_up
    @Test func motionStartingOnALateFrameTakesOneSmallStepWhileRunningMotionCatchesUp() {
        let fresh: Float = {
            let start = 100.0
            let clock = FrameClock(start: start)
            let rt = makeRuntime()
            _ = clock.advance(rt, at: start, compositing: false)
            rt.update { s, _ in s.b = 212.0 }
            _ = clock.advance(rt, at: start + Self.frame, compositing: false)
            return width(rt, "b")
        }()

        var plain = cadence()
        plain.append(Self.late)
        let (expected, _) = at(run(times: plain, at: .greatestFiniteMagnitude) { _ in }, Self.late)
        let (a, b) = at(run(times: plain, at: Self.late) { rt in rt.update { s, _ in s.b = 212.0 } }, Self.late)
        #expect(expected < 211.0 && abs(a - expected) < 0.01, "running motion catches up the whole gap: a=\(a), expected=\(expected)")
        #expect(abs(b - fresh) < 0.01, "new motion takes one 1/120 s step, not the 49 ms gap: b=\(b), one step=\(fresh)")
    }

    // 5. motion_a_frame_starts_and_runs_late_on_moves_one_frame_next_while_running_motion_keeps_time
    @Test func motionAFrameStartsAndRunsLateOnMovesOneFrameNextWhileRunningMotionKeepsTime() {
        let overrun = 0.050
        let starts = 3.0 * Self.frame
        let next = starts + overrun + Self.frame

        let poses: (Bool) -> (Float, Float) = { late in
            let start = 100.0
            let clock = FrameClock(start: start)
            let rt = makeRuntime()
            for t in [0.0, Self.frame, 2.0 * Self.frame, starts, next] {
                if t == Self.frame { rt.update { s, _ in s.a = 212.0 } }
                if t == starts { rt.update { s, _ in s.b = 212.0 } }
                _ = clock.advance(rt, at: start + t, compositing: false)
                clock.presented(rt, done: start + t + ((late && t == starts) ? overrun : 0.0))
            }
            return (width(rt, "a"), width(rt, "b"))
        }

        let oneFrameOn: Float = {
            let start = 100.0
            let clock = FrameClock(start: start)
            let rt = makeRuntime()
            _ = clock.advance(rt, at: start, compositing: false)
            rt.update { s, _ in s.b = 212.0 }
            _ = clock.advance(rt, at: start + Self.frame, compositing: false)
            _ = clock.advance(rt, at: start + 2.0 * Self.frame, compositing: false)
            return width(rt, "b")
        }()

        let (a, b) = poses(true)
        let (onTimeA, onTimeB) = poses(false)
        #expect(abs(b - oneFrameOn) < 0.01, "b moved one frame from its first pose: b=\(b), oneFrameOn=\(oneFrameOn)")
        #expect(onTimeB - b > 5.0, "without the overrun, b moves the whole gap: \(onTimeB) vs \(b)")
        #expect(a < 211.0 && abs(a - onTimeA) < 0.01, "running motion keeps real time: a=\(a), onTime=\(onTimeA)")
    }

    // 6. a_spring_retargeted_on_a_late_frame_turns_from_its_pose_at_that_time
    @Test func aSpringRetargetedOnALateFrameTurnsFromItsPoseAtThatTime() {
        let back: (Runtime<Pair>) -> Void = { rt in rt.update { s, _ in s.a = 12.0 } }
        var hitchedTimes = cadence()
        hitchedTimes.append(contentsOf: [Self.late, Self.late + Self.frame, Self.late + 2.0 * Self.frame])

        let turn = Self.late - FrameClock.resumeStep
        var referenceTimes = cadence()
        referenceTimes.append(contentsOf: [turn, Self.late, Self.late + Self.frame, Self.late + 2.0 * Self.frame])

        let hitched = run(times: hitchedTimes, at: Self.late, onTrigger: back)
        let reference = run(times: referenceTimes, at: Self.late, onTrigger: back)

        for t in [Self.late, Self.late + Self.frame, Self.late + 2.0 * Self.frame] {
            let (got, _) = at(hitched, t)
            let (expected, _) = at(reference, t)
            #expect(abs(got - expected) < 0.01, "at \(t) a=\(got), turning on its old curve gives \(expected)")
        }
    }

    // 7. one_presented_frame_is_one_runtime_pass
    @Test func onePresentedFrameIsOneRuntimePass() throws {
        let start = 100.0
        let clock = FrameClock(start: start)
        let rt = makeRuntime()
        let buffer = SharedBuffer()
        let trace = MotionTrace.inMemory(
            header: TraceHeader(launch: "frames", width: 400.0, height: 50.0, hz: 60.0, scale: 1.0),
            buffer: buffer
        )
        rt.setTrace(trace)

        _ = clock.advance(rt, at: start, compositing: false)
        rt.update { s, _ in s.a = 212.0 }
        for k in 1...3 {
            _ = clock.advance(rt, at: start + Double(k) * Self.frame, compositing: false)
        }
        let polls = rt.state.polls
        rt.settleAll()
        #expect(rt.isAnimating)
        _ = clock.advance(rt, at: start + 3.0 * Self.frame + 0.049, compositing: false)
        #expect(rt.state.polls - polls == 1, "poll runs once per presented frame")
        #expect(rt.settled, "the settle cut must survive into the presented frame")

        let taken = rt.takeTrace()
        taken?.flush()
        let frames = buffer.contents().split(separator: "\n").filter { $0.hasPrefix("{\"t\":") }.count
        #expect(frames == 5, "the motion trace records one frame per presented frame")
    }

    // 8. headless_frames_start_new_motion_with_a_small_step_after_idle
    @Test func headlessFramesStartNewMotionWithASmallStepAfterIdle() {
        let rt = makeRuntime()
        _ = rt.frameStep(dt: 0.0)
        let clock = rt.currentTime
        rt.update { s, _ in s.b = 212.0 }
        _ = FrameClock.advanceBy(rt, gap: 1.0)
        let b = width(rt, "b")
        #expect(b > 12.0 && b < 20.0, "a tap after a second of idle starts with one small step: \(b)")
        #expect(abs((rt.currentTime - clock) - 1.0) < 1e-9, "timers still see the whole second: \(rt.currentTime - clock)")

        let steady = makeRuntime()
        _ = steady.frameStep(dt: 0.0)
        steady.update { s, _ in s.b = 212.0 }
        _ = steady.frameStep(dt: FrameClock.resumeStep)
        _ = steady.frameStep(dt: 0.049)
        _ = FrameClock.advanceBy(rt, gap: 0.049)
        #expect(abs(width(rt, "b") - width(steady, "b")) < 0.01, "a late headless frame keeps its time")
    }
}
