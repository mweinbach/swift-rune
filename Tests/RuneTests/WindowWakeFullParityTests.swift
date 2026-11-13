import Foundation
import Testing
@testable import Rune

@Suite("Window Wake & SurfaceStats Full Parity (runtime/tests/window_wake.rs + frame.rs)")
@MainActor
struct WindowWakeFullParityTests {

    private struct HiddenFitState {
        var count: Int
        var growOnPoll: Bool
    }

    @Test("window_wake.rs:78 - a hidden window that fits its content learns its height before it shows")
    func aHiddenWindowThatFitsItsContentLearnsItsHeightBeforeItShows() {
        let rt = Runtime<HiddenFitState>(
            state: HiddenFitState(count: 1, growOnPoll: false),
            viewport: Vec2(300, 400),
            pixelScale: 1.0
        ) { s, _ in
            let items: [El<HiddenFitState>] = (0..<s.count).map { _ in el().size(100, 40) }
            return col().key("root").wFull().children(items)
        }
        rt.fitHeight = true
        let height = rt.contentHeight()
        rt.setViewport(Vec2(300, height), pixelScale: 1.0)
        _ = rt.frame(at: 0.0)
        _ = rt.takeWindowFrameRequest()
        #expect(!rt.buildForShow(), "unchanged, the last frame still shows it")

        rt.poll = { s, _, _ in
            guard s.growOnPoll else { return false }
            s.growOnPoll = false
            s.count += 1
            return true
        }
        rt.state.growOnPoll = true
        let commits = rt.viewCommitCount
        #expect(rt.pollHidden())
        #expect(rt.pendingWindowFrame == nil && rt.viewCommitCount == commits, "hidden, nothing builds yet")
        #expect(rt.buildForShow())

        let request = rt.takeWindowFrameRequest()
        #expect(request != nil, "the new height, before the window shows")
        #expect(request?.size?.0 == 300.0)
        #expect(request?.size?.1 == 80.0)
        #expect(request?.animate == false, "it opens at that height")

        rt.setViewport(Vec2(300, 80), pixelScale: 1.0)
        _ = rt.frame(at: 0.0)
        #expect(rt.viewCommitCount == commits + 1, "the first frame shown has nothing left to build")
        #expect(rt.pendingWindowFrame == nil)
    }

    @Test("window_wake.rs:109 - timed wakes are exact, coalesced, and do not commit or animate")
    func timedWakesAreExactCoalescedAndDoNotCommitOrAnimate() {
        final class SeenBox: @unchecked Sendable {
            var seen: [Double] = []
        }
        let box = SeenBox()
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(100, 100),
            pixelScale: 1.0
        ) { _, cx in
            cx.timeScale(0.1)
            return el()
        }
        rt.poll = { _, clock, tx in
            box.seen.append(clock)
            if clock == 0.0 {
                tx.wakeAfter(0.250)
                tx.wakeAfter(0.250)
                tx.wakeAfter(0.375)
            }
            return false
        }

        #expect(!rt.frameStep(dt: 0.0))
        #expect(rt.wakeDeadlines == [0.25, 0.375])
        #expect(!rt.frameStep(dt: 0.5))
        #expect(box.seen == [0.0, 0.25, 0.375, 0.5])
        #expect(rt.viewCommitCount == 1)
        #expect(rt.wakeDeadline() == nil)
        #expect(abs(rt.lastScaledAnimNow - 0.05) < 1e-8)
    }

    @Test("window_wake.rs:136 - wakes a poll keeps asking for collapse to one poll a frame")
    func wakesAPollKeepsAskingForCollapseToOnePollAFrame() {
        struct PollCollapseState {
            var pollsThisFrame: Int
            var delay: Double
        }

        for delay in [0.0, 1.0 / 60.0, 1.0 / 120.0, 0.505, 0.5] {
            let rt = Runtime<PollCollapseState>(
                state: PollCollapseState(pollsThisFrame: 0, delay: delay),
                viewport: Vec2(100, 100),
                pixelScale: 1.0
            ) { _, _ in el() }
            rt.poll = { s, _, tx in
                s.pollsThisFrame += 1
                tx.wakeAfter(s.delay)
                return false
            }

            for frame in 0..<1000 {
                rt.state.pollsThisFrame = 0
                rt.frameStep(dt: 1.0 / 60.0)
                #expect(rt.state.pollsThisFrame == 1, "delay \(delay): frame \(frame) polled \(rt.state.pollsThisFrame) times")
            }
            #expect(rt.wakeDeadlines.count <= 32, "delay \(delay): \(rt.wakeDeadlines.count) deadlines pending")
        }
    }

    @Test("window_wake.rs:160 - a zero wake does not hide a later wake in a coarse frame")
    func aZeroWakeDoesNotHideALaterWakeInACoarseFrame() {
        final class SeenBox: @unchecked Sendable {
            var seen: [Double] = []
        }
        let box = SeenBox()
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(100, 100),
            pixelScale: 1.0
        ) { _, _ in el() }
        rt.poll = { _, now, tx in
            box.seen.append((now * 1000.0).rounded() / 1000.0)
            if box.seen.count == 1 {
                tx.wakeAfter(0.0)
                tx.wakeAfter(0.050)
            }
            return false
        }

        rt.frameStep(dt: 0.0)
        rt.frameStep(dt: 0.1)
        #expect(box.seen == [0.0, 0.017, 0.05, 0.1])
    }

    @Test("window_wake.rs:179 - timed wakes from handlers survive transaction merging")
    func timedWakesFromHandlersSurviveTransactionMerging() {
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(100, 100),
            pixelScale: 1.0
        ) { _, _ in
            el().key("button").size(100, 100).onClick { _, tx in
                tx.wakeAfter(0.250)
            }
        }
        rt.frameStep(dt: 0.0)
        rt.pointerDown(at: Vec2(10, 10), at: rt.currentTime)
        rt.pointerUp(at: Vec2(10, 10), at: rt.currentTime)
        rt.frameStep(dt: 0.1)
        if let deadline = rt.wakeDeadline() {
            #expect(abs(deadline - 0.35) < 1e-9)
        } else {
            Issue.record("Expected wakeDeadline == 0.35 after frameStep(0.1)")
        }
        rt.frameStep(dt: 0.25)
        #expect(rt.wakeDeadline() == nil)
    }

    @Test("frame.rs:312 - Runtime.surfaceStats returns nil headless and live counts when SurfaceMeter is bound")
    func runtimeSurfaceStatsParity() {
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(100, 100),
            pixelScale: 1.0
        ) { _, _ in el().size(20, 20) }
        #expect(rt.surfaceStats() == nil)

        let meter = SurfaceMeter(name: "main", now: 10.0)
        rt.surfaceMeter = meter
        meter.setPacing(.paced)
        _ = meter.redraw(paced: true, now: 10.2)
        _ = meter.presented(now: 10.21)

        let stats = rt.surfaceStats()
        #expect(stats?.name == "main")
        #expect(stats?.totals.redraws == 1)
        #expect(stats?.totals.presents == 1)
        #expect(stats?.pacing == .paced)
    }
}
