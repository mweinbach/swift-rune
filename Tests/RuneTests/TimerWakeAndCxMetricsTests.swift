import Testing
import Foundation
@testable import Rune

@Suite("El & Runtime Item 3: Cx Scroll/Geometry Metrics & TimerWake")
struct TimerWakeAndCxMetricsTests {

    private static let timerPeriod = 0.02

    @Test("Cx scroll/geometry metric helpers expose layout, scrollAtBottom, progress, remaining, canScroll")
    func cxScrollAndGeometryMetrics() {
        var sawLayoutWidth: Float? = nil
        var sawWindowWidth: Float? = nil
        var sawBottomMounted: Bool? = nil
        var sawBottomMissing: Bool? = true
        var sawProgress: Vec2 = .zero
        var sawRemaining: Vec2 = .zero
        var sawCanScroll: (horizontal: Bool, vertical: Bool) = (false, false)

        let cx = Cx<Int>(
            viewport: Vec2(400, 300),
            pixelScale: 2.0,
            systemDark: true,
            reducedMotion: true,
            scrollLookup: { key in key == "scroller" ? Vec2(0, 140) : .zero },
            scrollMaxLookup: { key in key == "scroller" ? Vec2(0, 140) : .zero },
            viewportSizeLookup: { key in key == "scroller" ? Vec2(300, 160) : .zero },
            contentSizeLookup: { key in key == "scroller" ? Vec2(300, 300) : .zero },
            layoutRectLookup: { key in
                key == "scroller" ? MotionRect.fromXYWH(10, 20, 300, 160) : nil
            }
        )

        sawLayoutWidth = cx.layoutRect(of: "scroller")?.width
        sawWindowWidth = cx.windowLayoutWith("scroller") { $0.width }
        sawBottomMounted = cx.scrollAtBottom(of: "scroller")
        sawBottomMissing = cx.scrollAtBottom(of: "missing")
        sawProgress = cx.scrollProgress(of: "scroller")
        sawRemaining = cx.scrollRemaining(of: "scroller")
        sawCanScroll = cx.canScroll(of: "scroller")

        #expect(sawLayoutWidth == 300)
        #expect(sawWindowWidth == 300)
        #expect(cx.windowLayout("scroller") == MotionRect.fromXYWH(10, 20, 300, 160))
        #expect(cx.layoutSize(of: "scroller") == Vec2(300, 160))
        #expect(sawBottomMounted == true)
        #expect(sawBottomMissing == nil)
        #expect(sawProgress == Vec2(0, 1))
        #expect(sawRemaining == Vec2(0, 0))
        #expect(sawCanScroll.horizontal == false && sawCanScroll.vertical == true)
    }

    @Test("Cx scrollAtBottom tracks real Runtime scroll position transitions")
    func runtimeCxScrollAtBottomTracksScroll() {
        struct S {
            var lastAtBottom: Bool? = nil
        }

        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 100),
            view: { (_, cx) -> El<S> in
                let atBottom = cx.scrollAtBottom(of: "list")
                return col()
                    .key("list")
                    .w(200)
                    .h(100)
                    .scrollY()
                    .child(text(atBottom.map { $0 ? "bottom" : "not-bottom" } ?? "init").key("status"))
                    .child(el().key("tall").w(200).h(300))
            }
        )
        _ = rt.frame(at: 0.0)
        rt.update { _, _ in }
        _ = rt.frame(at: 0.01)
        #expect(rt.elements().first(where: { $0.key == "status" })?.text == "not-bottom")

        rt.update { _, tx in
            tx.scrollTo("list", offset: Vec2(0, 1000), animated: false)
        }
        _ = rt.frame(at: 0.016)
        // Next view build observes the updated scroll offset at the bottom (max = 200).
        rt.update { _, _ in }
        _ = rt.frame(at: 0.032)
        let statusInfo = rt.elements().first(where: { $0.key == "status" })
        #expect(statusInfo?.text == "bottom")
    }

    @Test("TimerWake state machine mirrors timer_wake.rs transitions")
    func timerWakeStateTransitions() {
        var tw = TimerWake()
        #expect(tw.restingWake() == nil)
        #expect(tw.rests)
        #expect(tw.polledAt == nil)

        tw.restingWakeFrame(true, at: 1.5)
        #expect(tw.restingWake() == true)
        #expect(!tw.rests)
        #expect(tw.polledAt == 1.5)

        #expect(tw.takeFrame() == true)
        #expect(tw.restingWake() == false)
        #expect(tw.rests)
        #expect(tw.polledAt == 1.5)

        #expect(tw.takeFrame() == false)
        tw.resetToIdle()
        #expect(tw.restingWake() == nil)

        // Hidden poll consumes asked -> taken
        tw.restingWakeFrame(true, at: 2.0)
        #expect(tw.pollHidden() == true)
        #expect(tw.restingWake() == false)
        #expect(tw.pollHidden() == false)

        // Cancel clears asked -> idle
        tw.restingWakeFrame(true, at: 3.0)
        tw.cancelTimerFrame()
        #expect(tw.restingWake() == nil)
        #expect(tw.rests)
    }

    @Test("TimerWakeScheduler: timer poll that changes state stands for its frame and paces from poll")
    func timerPollThatChangesStateStandsForItsFrame() {
        var changeAtPoll = 1
        let sched = TimerWakeScheduler(clock: 0.0) { _, delays in
            delays.append(Self.timerPeriod)
            return changeAtPoll > 0
        }
        sched.frame(dt: 0.0)
        let initialPolls = sched.pollCount
        changeAtPoll = 1
        sched.advance(by: 0.005)
        let asked = sched.hostWake { $0 }
        #expect(asked)
        let polled = sched.polledAt()
        #expect(polled != nil)
        sched.frame(dt: 1.0 / 120.0)
        #expect(sched.pollCount == initialPolls + 1, "frame must not poll a second time")
        let next = sched.wakeDeadline()!
        #expect(abs(next - (polled! + Self.timerPeriod)) < 1e-9, "timer paces from poll instant, not frame")
    }

    @Test("TimerWakeScheduler: poll leaving work for frame, hidden window, and covered wake")
    func timerWakeHiddenAndCoveredScenarios() {
        // 1. Poll hides the window -> asks no frame, schedules next timer, showing frame polls.
        let shouldChange = true
        let hiddenSched = TimerWakeScheduler(clock: 0.0) { _, delays in
            delays.append(Self.timerPeriod)
            return shouldChange
        }
        hiddenSched.frame(dt: 0.0)
        let p0 = hiddenSched.pollCount
        let asked = hiddenSched.hostWake { _ in false }
        #expect(!asked)
        let polled = hiddenSched.clock
        #expect(abs(hiddenSched.wakeDeadline()! - (polled + Self.timerPeriod)) < 1e-9)
        hiddenSched.frame(dt: 1.0 / 120.0)
        #expect(hiddenSched.pollCount == p0 + 2, "frame that shows hidden window polls again")

        // 2. Covered wake: poll's change stands, timers count from poll, second due timer still polls.
        let coveredSched = TimerWakeScheduler(clock: 0.0) { _, delays in
            delays.append(Self.timerPeriod)
            return true
        }
        coveredSched.frame(dt: 0.0)
        let p1 = coveredSched.pollCount
        #expect(coveredSched.hostWake { _ in true })
        let coveredPollTime = coveredSched.clock
        #expect(coveredSched.hiddenWake())
        #expect(coveredSched.pollCount == p1 + 1)
        #expect(abs(coveredSched.wakeDeadline()! - (coveredPollTime + Self.timerPeriod)) < 1e-9)
        coveredSched.scheduleWakes(from: coveredPollTime, delays: [0.002])
        coveredSched.advance(by: 0.005)
        _ = coveredSched.hiddenWake()
        #expect(coveredSched.pollCount == p1 + 2, "due second timer still polls while covered")
        _ = shouldChange
    }
}
