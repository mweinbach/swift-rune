import Foundation
import Testing
@testable import Rune
@testable import RuneMotion

@Suite("TimerWake Runtime Full Parity (runtime/timer_wake_tests.rs)")
@MainActor
struct TimerWakeFullParityTests {

    /// The poll's timer. Long enough that real wall-clock jitter on CI never trips a timer early.
    private static let period: Double = 5.0

    private struct TimerApp {
        var polls: UInt32 = 0
        /// The poll that reports a change; none at 0.
        var changeAt: UInt32 = 0
        /// Asks for the next frame (`wakeAfter(0.0)`) instead of `period`.
        var step: Bool = false
        var width: Float = 0.0
    }

    private func makeRuntime(_ app: TimerApp = TimerApp()) -> Runtime<TimerApp> {
        let rt = Runtime<TimerApp>(
            state: app,
            viewport: Vec2(200, 50),
            pixelScale: 1.0
        ) { s, _ in
            col().children([
                el().key("box").size(10.0 + s.width, 8.0).animateLayout(MotionTokens.DEFAULT)
            ])
        }
        rt.poll = { s, _, tx in
            s.polls += 1
            tx.wakeAfter(s.step ? 0.0 : Self.period)
            return s.step || s.polls == s.changeAt
        }
        rt.wallStart = ProcessInfo.processInfo.systemUptime
        rt.frameStep(dt: 0.0)
        rt.frameStep(dt: FrameClock.resumeStep)
        #expect(!rt.isAnimating)
        return rt
    }

    private func advance(_ rt: Runtime<TimerApp>, by secs: Double) {
        rt.advanceWallStart(by: secs)
    }

    private func reachTimer(_ rt: Runtime<TimerApp>) {
        guard let due = rt.wakeDeadlines.last else {
            Issue.record("a timer is armed")
            return
        }
        let now = rt.nowClock()
        advance(rt, by: max(0.0, due - now) + 1e-4)
    }

    private func hostWake(_ rt: Runtime<TimerApp>, shell: (Runtime<TimerApp>) -> Bool) -> Bool {
        reachTimer(rt)
        guard let stale = rt.restingWake() else { return true }
        let visible = shell(rt)
        let askFrame = (stale || rt.isStale) && visible
        rt.restingWakeFrame(askFrame)
        return askFrame
    }

    private func timerWake(_ rt: Runtime<TimerApp>) -> Bool {
        if !hostWake(rt, shell: { _ in true }) { return false }
        rt.frameStep(dt: FrameClock.resumeStep)
        return true
    }

    @Test("timer_wake_tests.rs:74 - a resting window's timer draws only for a poll that changed something")
    func aRestingWindowsTimerDrawsOnlyForAPollThatChangedSomething() {
        let rt = makeRuntime()
        let commits = rt.viewCommitCount
        let polls = rt.state.polls
        rt.state.changeAt = polls + 9

        for _ in 0..<8 {
            #expect(!timerWake(rt), "a poll that returns false builds and draws nothing")
        }
        #expect(rt.state.polls == polls + 8, "each timer still polls")
        #expect(rt.viewCommitCount == commits, "and runs no view")

        let deadline = rt.wakeDeadline()
        #expect(deadline != nil)
        if let deadline {
            #expect(deadline > rt.currentTime, "the poll's next timer is armed: \(deadline) after \(rt.currentTime)")
        }

        let frames = (0..<6).filter { _ in timerWake(rt) }.count
        #expect(frames == 1, "the poll that returns true gets exactly one frame")
        #expect(rt.viewCommitCount == commits + 1)
        #expect(rt.state.polls == polls + 14, "one poll a wake: the frame doesn't poll again")
    }

    @Test("timer_wake_tests.rs:91 - a poll stepping every frame still draws every frame")
    func aPollSteppingEveryFrameStillDrawsEveryFrame() {
        let rt = makeRuntime(TimerApp(step: true))
        let polls = rt.state.polls
        for _ in 0..<10 {
            #expect(timerWake(rt), "`wakeAfter(0)` steps on frames")
        }
        #expect(rt.state.polls - polls == 10, "the frames poll; the wakes don't poll first")

        // Steps reported as no change still take their frames, as before.
        rt.poll = { s, _, tx in
            s.polls += 1
            tx.wakeAfter(0.0)
            return false
        }
        rt.frameStep(dt: FrameClock.resumeStep)
        for _ in 0..<5 {
            #expect(timerWake(rt))
        }

        // A resting window's poll that starts stepping takes the next frame.
        let rt2 = makeRuntime()
        #expect(!timerWake(rt2))
        rt2.poll = { s, _, tx in
            s.polls += 1
            tx.wakeAfter(0.0)
            return false
        }
        let polls2 = rt2.state.polls
        #expect(timerWake(rt2), "its first step draws")
        #expect(timerWake(rt2), "and so does every one after")
        #expect(rt2.state.polls == polls2 + 2, "one step each")
    }

    @Test("timer_wake_tests.rs:111 - motion in flight takes the timer's frame")
    func motionInFlightTakesTheTimersFrame() {
        let rt = makeRuntime()
        rt.update { s, _ in s.width = 120.0 }
        rt.frameStep(dt: FrameClock.resumeStep)
        #expect(rt.isAnimating, "the box springs to its new width")
        let polls = rt.state.polls
        #expect(rt.restingWake() == nil)
        #expect(rt.state.polls == polls, "the frame polls, not the wake")
    }

    @Test("timer_wake_tests.rs:122 - a wake before the timer's frame gets a poll")
    func aWakeBeforeTheTimersFrameGetsAPoll() {
        let rt = makeRuntime()
        let polls = rt.state.polls
        rt.state.changeAt = polls + 1
        #expect(hostWake(rt, shell: { _ in true }))

        rt.cancelTimerFrame()
        let armed = rt.wakeDeadline()
        #expect(armed != nil, "the timer poll's own timer counts from it")
        rt.frameStep(dt: FrameClock.resumeStep)
        #expect(rt.state.polls == polls + 2, "the frame polls for the wake")
        #expect(rt.wakeDeadlines.first == armed)
    }

    @Test("timer_wake_tests.rs:136 - a timer due between the poll and its frame gets the frame's poll")
    func aTimerDueBetweenThePollAndItsFrameGetsTheFramesPoll() {
        let rt = makeRuntime()
        let polls = rt.state.polls
        rt.state.changeAt = polls + 1
        #expect(hostWake(rt, shell: { _ in true }))
        let polled = rt.currentTime
        rt.scheduleWakes(from: polled, delays: [0.002])
        advance(rt, by: 0.005)
        rt.frameStep(dt: FrameClock.resumeStep)
        #expect(rt.state.polls == polls + 2, "the later timer polls")
        #expect(rt.wakeDeadlines.allSatisfy { $0 > rt.currentTime }, "nothing due is left behind: \(rt.wakeDeadlines)")
        #expect(rt.restingWake() != nil, "and the window rests again")
    }

    @Test("timer_wake_tests.rs:151 - the timer's frame keeps the poll's time")
    func theTimersFrameKeepsThePollsTime() {
        let rt = makeRuntime()
        let polls = rt.state.polls
        rt.state.changeAt = polls + 1
        #expect(hostWake(rt, shell: { _ in true }))
        let polled = rt.currentTime
        advance(rt, by: 0.004)
        rt.frameStep(dt: FrameClock.resumeStep)
        #expect(rt.state.polls == polls + 1)
        #expect(rt.currentTime > polled)
        #expect(rt.polledAt() == polled, "timers pace from the poll, not the frame")
        if let next = rt.wakeDeadline() {
            #expect(abs(next - (rt.currentTime + Self.period)) < 1e-9, "the poll's timer counts from the frame that took it")
        } else {
            Issue.record("Expected next wakeDeadline after frame")
        }
    }

    @Test("timer_wake_tests.rs:167 - a timer poll that leaves work for the frame is its only poll")
    func aTimerPollThatLeavesWorkForTheFrameIsItsOnlyPoll() {
        let rt = makeRuntime()
        let polls = rt.state.polls
        #expect(hostWake(rt, shell: { rt in
            rt.update { s, _ in s.width = 4.0 }
            return true
        }))
        rt.frameStep(dt: FrameClock.resumeStep)
        #expect(rt.state.polls == polls + 1, "the frame doesn't poll a second time")
    }

    @Test("timer_wake_tests.rs:177 - a timer poll that hides the window asks no frame")
    func aTimerPollThatHidesTheWindowAsksNoFrame() {
        let rt = makeRuntime()
        let polls = rt.state.polls
        rt.state.changeAt = polls + 1
        #expect(!hostWake(rt, shell: { _ in false }), "a keep-running window the poll closed")
        let polled = rt.currentTime
        if let next = rt.wakeDeadline() {
            #expect(abs(next - (polled + Self.period)) < 1e-9, "its timer still runs, hidden")
        } else {
            Issue.record("Expected hidden wakeDeadline")
        }
        rt.frameStep(dt: FrameClock.resumeStep)
        #expect(rt.state.polls == polls + 2, "the frame that shows it polls")

        // Hidden or shown after the frame was asked for: the next frame polls, and the timer runs.
        let rt2 = makeRuntime()
        let polls2 = rt2.state.polls
        rt2.state.changeAt = polls2 + 1
        #expect(hostWake(rt2, shell: { _ in true }))
        let polled2 = rt2.currentTime
        rt2.cancelTimerFrame()
        if let next2 = rt2.wakeDeadline() {
            #expect(abs(next2 - (polled2 + Self.period)) < 1e-9)
        } else {
            Issue.record("Expected wakeDeadline after cancelTimerFrame")
        }
        rt2.frameStep(dt: FrameClock.resumeStep)
        #expect(rt2.state.polls == polls2 + 2)
    }

    @Test("timer_wake_tests.rs:202 - a timer frame that runs covered does not poll again")
    func aTimerFrameThatRunsCoveredDoesNotPollAgain() {
        let rt = makeRuntime()
        let polls = rt.state.polls
        rt.state.changeAt = polls + 1
        #expect(hostWake(rt, shell: { _ in true }))
        let polled = rt.currentTime
        #expect(rt.hiddenWake(), "the poll's change is still to draw")
        #expect(rt.state.polls == polls + 1, "one poll for the wake")
        if let next = rt.wakeDeadline() {
            #expect(abs(next - (polled + Self.period)) < 1e-9, "its timer counts from the poll")
        } else {
            Issue.record("Expected wakeDeadline after hiddenWake")
        }
        rt.frameStep(dt: FrameClock.resumeStep)
        #expect(rt.state.polls == polls + 2, "the frame that draws next polls")

        // Another timer due by then still polls.
        let rt2 = makeRuntime()
        let polls2 = rt2.state.polls
        rt2.state.changeAt = polls2 + 1
        #expect(hostWake(rt2, shell: { _ in true }))
        let polled2 = rt2.currentTime
        rt2.scheduleWakes(from: polled2, delays: [0.002])
        advance(rt2, by: 0.005)
        _ = rt2.hiddenWake()
        #expect(rt2.state.polls == polls2 + 2)
    }
}
