import Foundation
import Testing
@testable import Rune

/// Upstream r241 / r382 / #856 wheel parity (`3ceb02f9`, `248a84c7`, `0edeaa53`, `f1608482`,
/// `74a3c8d4`, `3ea2344e`): `runtime/input/gesture.rs` and `runtime/scroll/x.rs` tests.
///
/// Upstream queues a delta offered to `on_wheel` handlers and runs it when the frame drains the
/// queue; the Swift runtime runs `onWheel` at the event. The scenarios below replay the same
/// platform event order (deltas, `wheel_began`, `wheel_ended`, frames) and assert the same
/// handler calls and scroll offsets.
@Suite("Wheel owner handoff & native wheel distance parity (r241, r382, #856)")
struct WheelOwnerHandoffParityTests {

    // MARK: - `runtime/input/gesture.rs` tests

    struct Wheeled { var heard: [Float] = [] }

    @MainActor
    static func wheeling() -> Runtime<Wheeled> {
        Runtime(
            state: Wheeled(),
            viewport: Vec2(300, 300),
            pixelScale: 1.0,
            view: { _, _ in
                el().wFull().hFull()
                    .child(el().key("list").wFull().h(300).scroll(ScrollSpec(stickBottom: false))
                        .child(el().wFull().h(1000)
                            .child(el().key("takes").absolute(x: 100, y: 40).size(40, 40)
                                .onWheel { s, e, _ in s.heard.append(e.x); return true })))
            }
        )
    }

    struct Two { var heard: [String] = [] }

    @MainActor
    static func twoHandlers() -> Runtime<Two> {
        Runtime(
            state: Two(),
            viewport: Vec2(300, 300),
            pixelScale: 1.0,
            view: { _, _ in
                el().wFull().hFull()
                    .child(el().key("list").wFull().h(300).scroll(ScrollSpec(stickBottom: false))
                        .child(el().wFull().h(1000)
                            .child(el().key("a").absolute(x: 20, y: 40).size(40, 40)
                                .onWheel { s, _, _ in s.heard.append("a"); return true })
                            .child(el().key("b").absolute(x: 200, y: 40).size(40, 40)
                                .onWheel { s, _, _ in s.heard.append("b"); return true })))
            }
        )
    }

    static let t: Double = 1.0 / 60.0

    @MainActor
    static func wheelEvent<S>(_ rt: Runtime<S>, dx: Float = 0, dy: Float, x: Float, y: Float, now: Double = t) {
        rt.wheel(WheelEvent(dx: dx, dy: dy, x: x, y: y), at: Vec2(x, y), now: now)
    }

    /// `deltas_queued_before_a_new_gesture_began_finish_with_the_gesture_s_owner`
    @Test("deltas queued before a new gesture began finish with the gesture's owner")
    @MainActor
    func deltasQueuedBeforeANewGestureBeganFinishWithTheGesturesOwner() {
        let rt = Self.wheeling()
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: Self.t)
        Self.wheelEvent(rt, dy: -10, x: 110, y: 50)
        Self.wheelEvent(rt, dy: -10, x: 290, y: 50)
        rt.wheelBegan(now: Self.t)
        _ = rt.frame(at: 2 * Self.t)
        #expect(rt.state.heard == [10.0, 190.0], "both deltas in the handler's own points")
        #expect(rt.scrollOffset(forKey: "list").y == 0.0, "the whole gesture stays with the handler")
    }

    /// `a_queued_delta_picks_its_handler_before_a_newer_gesture_s_scroll`
    @Test("a queued delta picks its handler before a newer gesture's scroll")
    @MainActor
    func aQueuedDeltaPicksItsHandlerBeforeANewerGesturesScroll() {
        let rt = Self.wheeling()
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: Self.t)
        Self.wheelEvent(rt, dy: -10, x: 110, y: 50)
        rt.wheelBegan(now: Self.t)
        Self.wheelEvent(rt, dy: -10, x: 290, y: 50)
        _ = rt.frame(at: 2 * Self.t)
        #expect(rt.state.heard == [10.0], "the queued delta reaches the handler it was offered to")
        #expect(rt.scrollOffset(forKey: "list").y == 10.0, "only the newer gesture's own delta scrolled")
    }

    /// `a_queued_delta_keeps_its_owner_when_the_next_gesture_scrolls_first`
    @Test("a queued delta keeps its owner when the next gesture scrolls first")
    @MainActor
    func aQueuedDeltaKeepsItsOwnerWhenTheNextGestureScrollsFirst() {
        let rt = Self.wheeling()
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: Self.t)
        // The handler takes the gesture.
        Self.wheelEvent(rt, dy: -10, x: 110, y: 50)
        _ = rt.frame(at: Self.t)
        #expect(rt.state.heard == [10.0])
        // A delta outside it is queued for that owner; the gesture ends, and the next one
        // scrolls at once outside every handler.
        Self.wheelEvent(rt, dy: -10, x: 290, y: 50)
        rt.wheelEnded(now: Self.t)
        Self.wheelEvent(rt, dy: -10, x: 290, y: 50)
        _ = rt.frame(at: 2 * Self.t)
        #expect(rt.state.heard == [10.0, 190.0], "the queued delta still reaches the gesture's owner")
        #expect(rt.scrollOffset(forKey: "list").y == 10.0, "only the newer gesture's own delta scrolled")
    }

    /// `a_drained_gesture_gives_its_owner_up_to_the_next_queued_one`
    @Test("a drained gesture gives its owner up to the next queued one")
    @MainActor
    func aDrainedGestureGivesItsOwnerUpToTheNextQueuedOne() {
        let rt = Self.twoHandlers()
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: Self.t)
        // A delta over `a`, then a gesture begins and a delta over `b`: each reaches its own.
        Self.wheelEvent(rt, dy: -10, x: 30, y: 50)
        rt.wheelBegan(now: Self.t)
        Self.wheelEvent(rt, dy: -10, x: 210, y: 50)
        _ = rt.frame(at: Self.t)
        #expect(rt.state.heard == ["a", "b"])
        // `b` owns the gesture now; a delta outside it is queued for `b`, and the next gesture
        // begins before the frame drains it.
        Self.wheelEvent(rt, dy: -10, x: 290, y: 50)
        rt.wheelBegan(now: Self.t)
        _ = rt.frame(at: 2 * Self.t)
        #expect(rt.state.heard == ["a", "b", "b"], "the queued delta still reaches b")
        #expect(rt.scrollOffset(forKey: "list").y == 0.0, "every delta reached a handler")
    }

    /// `a_delta_queued_for_each_of_two_gestures_reaches_its_own_handler`
    @Test("a delta queued for each of two gestures reaches its own handler")
    @MainActor
    func aDeltaQueuedForEachOfTwoGesturesReachesItsOwnHandler() {
        let rt = Self.twoHandlers()
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: Self.t)
        Self.wheelEvent(rt, dy: -10, x: 30, y: 50)
        rt.wheelBegan(now: Self.t)
        Self.wheelEvent(rt, dy: -10, x: 210, y: 50)
        rt.wheelBegan(now: Self.t)
        _ = rt.frame(at: 2 * Self.t)
        #expect(rt.state.heard == ["a", "b"], "each delta goes to the handler its own gesture found")
    }

    /// `three_gestures_queued_before_one_frame_each_reach_their_own_handler` (r406, `74a3c8d4`)
    @Test("three gestures queued before one frame each reach their own handler")
    @MainActor
    func threeGesturesQueuedBeforeOneFrameEachReachTheirOwnHandler() {
        let rt = Self.twoHandlers()
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: Self.t)
        Self.wheelEvent(rt, dy: -10, x: 30, y: 50)
        rt.wheelBegan(now: Self.t)
        Self.wheelEvent(rt, dy: -10, x: 210, y: 50)
        rt.wheelBegan(now: Self.t)
        Self.wheelEvent(rt, dy: -10, x: 30, y: 50)
        _ = rt.frame(at: 2 * Self.t)
        #expect(rt.state.heard == ["a", "b", "a"], "each delta goes to the handler its own gesture found")
        #expect(rt.scrollOffset(forKey: "list").y == 0.0, "every delta reached a handler")
    }

    /// `a_third_gesture_scrolling_before_the_frame_keeps_both_queued_owners` (r406, `74a3c8d4`)
    @Test("a third gesture scrolling before the frame keeps both queued owners")
    @MainActor
    func aThirdGestureScrollingBeforeTheFrameKeepsBothQueuedOwners() {
        let rt = Self.twoHandlers()
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: Self.t)
        Self.wheelEvent(rt, dy: -10, x: 30, y: 50)
        rt.wheelBegan(now: Self.t)
        Self.wheelEvent(rt, dy: -10, x: 210, y: 50)
        rt.wheelBegan(now: Self.t)
        Self.wheelEvent(rt, dy: -10, x: 290, y: 50)
        _ = rt.frame(at: 2 * Self.t)
        #expect(rt.state.heard == ["a", "b"], "the first two gestures' deltas still reach their handlers")
        #expect(rt.scrollOffset(forKey: "list").y == 10.0, "only the third gesture's own delta scrolled")
    }

    // MARK: - `runtime/scroll/x.rs` tests

    /// `a_gesture_begun_as_one_ends_is_its_momentum_once`
    @Test("a gesture begun as one ends is its momentum once")
    @MainActor
    func aGestureBegunAsOneEndsIsItsMomentumOnce() {
        let rt = Runtime(
            state: (),
            viewport: Vec2(300, 300),
            pixelScale: 1.0,
            view: { _, _ in
                col().wFull().hFull().child(col().wFull().h(300)
                    .scroll(ScrollSpec(stickBottom: false)).child(el().wFull().h(2000)))
            }
        )
        _ = rt.frame(at: 0.0)
        func wheel(_ phase: GesturePhase) {
            rt.wheel(WheelEvent(dx: 0, dy: -10, phase: phase, x: 100, y: 100), at: Vec2(100, 100), now: 0.0)
        }
        wheel(.began)
        let first = rt.inputMachines.wheelLock.gesture
        #expect(rt.inputMachines.wheelLock.owner == .vertical)
        #expect(rt.inputMachines.wheelLock.momentum == false)
        wheel(.ended)
        wheel(.began)
        #expect(rt.inputMachines.wheelLock.momentum, "began right as one ended: its momentum")
        #expect(rt.inputMachines.wheelLock.gesture == first, "keeping the gesture")
        #expect(rt.inputMachines.wheelLock.owner == .vertical, "keeping the gesture")
        wheel(.ended)
        wheel(.began)
        #expect(!rt.inputMachines.wheelLock.momentum, "a finger caught the momentum: a new gesture")
        let second = rt.inputMachines.wheelLock.gesture
        #expect(second != first)

        rt.wheelLost()
        #expect(rt.inputMachines.wheelLock.gesture != second)
        #expect(rt.inputMachines.wheelLock.owner == .unpicked)
        #expect(rt.inputMachines.wheelLock.momentum == false)
        rt.wheel(WheelEvent(dx: 0, dy: -10, x: 100, y: 100), at: Vec2(100, 100), now: 0.0)
        let wheelGesture = rt.inputMachines.wheelLock.gesture
        rt.wheel(WheelEvent(dx: -10, dy: 0, x: 100, y: 100), at: Vec2(100, 100), now: 0.0)
        #expect(rt.inputMachines.wheelLock.gesture != wheelGesture, "without phases, a delta wholly on the other axis starts another")
    }

    @MainActor
    static func sectionsView() -> Runtime<Void> {
        Runtime(
            state: (),
            viewport: Vec2(300, 300),
            pixelScale: 1.0,
            view: { _, _ in
                let fits: El<Void> = col().key("section").wFull().h(200).scroll(ScrollSpec(stickBottom: false))
                    .child(el().wFull().h(200))
                let fitsX: El<Void> = row().key("chips").wFull().h(40).scrollX().child(el().w(100).h(40))
                let list: El<Void> = col().wFull().child(fitsX).child(fits).child(el().wFull().h(2000))
                return col().key("list").wFull().h(300).scroll(ScrollSpec(stickBottom: false)).child(list)
            }
        )
    }

    /// `the_wheel_over_a_viewport_with_nothing_to_scroll_scrolls_the_one_around_it` (#1021,
    /// `5dabf425`): a viewport whose content fits is passed over: the wheel over a section that
    /// is its own viewport, as tall as its rows, scrolls the list around it, on either axis.
    @Test("the wheel over a viewport with nothing to scroll scrolls the one around it")
    @MainActor
    func theWheelOverAViewportWithNothingToScrollScrollsTheOneAroundIt() {
        let rt = Self.sectionsView()
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: Self.t)
        func path(_ key: String) -> String? { rt.flatNodes.first(where: { $0.key == key })?.path }
        let list = path("list")
        #expect(list != nil && path("section") != nil && path("chips") != nil)
        // The strip that fits sideways is no horizontal viewport for the wheel, and over it the list scrolls.
        #expect(rt.scrollAtAxis(100, 20, horizontal: true) == nil)
        #expect(rt.scrollAt(100, 20) == list)
        rt.wheelXY(100, 100, 0, -30, now: Self.t)
        #expect(rt.scrollOffset(forKey: "list").y == 30.0)
        #expect(rt.scrollOffset(forKey: "section").y == 0.0)
    }

    @MainActor
    private func nestedLists() -> Runtime<Void> {
        let runtime = Runtime<Void>(state: (), viewport: Vec2(200, 120), pixelScale: 1) { _, _ in
            let inner: El<Void> = col().key("inner").size(200, 80).scrollY()
                .child(el().size(200, 180))
            return col().key("outer").size(200, 120).scrollY()
                .child(inner)
                .child(el().size(200, 300))
        }
        _ = runtime.frame(at: 0)
        return runtime
    }

    @MainActor
    @Test("a nested wheel run stays at its edge until 0.5 seconds after the last delta")
    func verticalRunKeepsItsViewport() {
        let rt = nestedLists()
        rt.wheelXY(60, 50, 0, -150, now: 1)
        #expect(rt.scrollOffset(forKey: "inner").y == 100)
        #expect(rt.scrollOffset(forKey: "outer").y == 0)
        rt.wheelXY(60, 50, 0, -15, now: 1.5)
        rt.wheelXY(60, 50, 0, -15, now: 2)
        #expect(rt.scrollOffset(forKey: "outer").y == 0)
        rt.wheelXY(60, 50, 0, -15, now: 2.501)
        #expect(rt.scrollOffset(forKey: "outer").y == 15)
        // Reversing a run that moved keeps it on the same viewport.
        rt.wheelXY(60, 50, 0, 10, now: 2.55)
        #expect(rt.scrollOffset(forKey: "outer").y == 5)
        #expect(rt.scrollOffset(forKey: "inner").y == 100)
    }

    @MainActor
    @Test("a vertical run measures pointer slop from its first delta")
    func verticalRunPointerSlop() {
        let rt = nestedLists()
        rt.wheelXY(60, 50, 0, -150, now: 1)
        rt.wheelXY(66, 57, 0, -10, now: 1.01)
        #expect(rt.scrollOffset(forKey: "outer").y == 0)
        rt.wheelXY(66, 58, 0, -10, now: 1.02)
        #expect(rt.scrollOffset(forKey: "outer").y == 10)
    }

    @Test("a vertical run whose initial delta was too small to move releases on reversal")
    func verticalRunWithoutMovement() {
        var lock = WheelLock()
        lock.ranVertical(path: "list", at: 1, x: 5, y: 10, dy: -0.001, moved: false, continued: false)
        #expect(lock.verticalTarget(at: 1.1, x: 5, y: 10, dy: -1) == "list")
        #expect(lock.verticalTarget(at: 1.1, x: 5, y: 10, dy: 1) == nil)
    }

    @MainActor
    @Test("trackpad momentum keeps its viewport, a new touch and a lost pointer repick")
    func verticalRunPhaseAndPointerLoss() {
        let rt = nestedLists()
        rt.wheelBegan(now: 1)
        rt.wheelXY(60, 50, 0, -150, now: 1.01)
        rt.wheelEnded(now: 1.02)
        rt.wheelBegan(now: 1.03)
        rt.wheelXY(60, 50, 0, -10, now: 1.04)
        #expect(rt.scrollOffset(forKey: "outer").y == 0)
        rt.wheelEnded(now: 1.05)
        rt.wheelBegan(now: 1.06)
        rt.wheelXY(60, 50, 0, -10, now: 1.07)
        #expect(rt.scrollOffset(forKey: "outer").y == 10)
        rt.pointerExit(at: 1.075)
        rt.wheelXY(60, 50, 0, 5, now: 1.08)
        #expect(rt.scrollOffset(forKey: "inner").y == 95)
        #expect(rt.scrollOffset(forKey: "outer").y == 10)
    }

    /// #1021 through `fling` / `fling_xy` (`pointer.rs` `fling` on `scroll_at`, `scroll/x.rs`
    /// `fling_xy` on `scroll_at_axis`): a fling over a viewport whose content fits releases into
    /// the one around it, and a mostly sideways fling over a strip that fits is the vertical one.
    @Test("a fling over a viewport with nothing to scroll moves the one around it")
    @MainActor
    func aFlingOverAViewportWithNothingToScrollMovesTheOneAroundIt() {
        let rt = Self.sectionsView()
        var t = 0.0
        _ = rt.frame(at: t)
        t += Self.t
        _ = rt.frame(at: t)
        let list = rt.flatNodes.first(where: { $0.key == "list" })?.path
        #expect(list != nil)
        // `fling_xy`: `vx.abs() > vy.abs()` but no horizontal viewport with room there -> `fling` on `scroll_at`.
        let sideways = rt.flingTarget(at: Vec2(100, 20), vx: -400, vy: -100)
        #expect(sideways?.path == list && sideways?.horizontal == false)
        let overSection = rt.flingTarget(at: Vec2(100, 100), vx: 0, vy: -400)
        #expect(overSection?.path == list && overSection?.horizontal == false)

        rt.fling(vx: 0, vy: -400, at: Vec2(100, 100), now: t)
        var frames = 0
        while rt.scrollStore.isAnimating && frames < 720 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            frames += 1
        }
        #expect(rt.scrollOffset(forKey: "list").y > 0.0, "the fling over the section moves the list")
        #expect(rt.scrollOffset(forKey: "section").y == 0.0)
    }

    /// `the_phase_carries_when_the_gesture_last_moved_and_when_it_ended`
    @Test("the phase carries when the gesture last moved and when it ended")
    func thePhaseCarriesWhenTheGestureLastMovedAndWhenItEnded() {
        var lock = WheelLock()
        lock.delta(at: 1.0, dx: 0, dy: -10, pending: nil)
        #expect(lock.phase == .unphased(at: 1.0), "a delta starts it, timed")
        lock.delta(at: 1.05, dx: 0, dy: -10, pending: nil)
        #expect(lock.phase == .unphased(at: 1.05), "a pause under the idle keeps the gesture")
        let gesture = lock.gesture
        lock.delta(at: 1.05 + WheelLock.wheelIdle + 0.01, dx: 0, dy: -10, pending: nil)
        #expect(lock.gesture != gesture, "a longer pause starts another")
        #expect(lock.phase == .unphased(at: 1.05 + WheelLock.wheelIdle + 0.01), "timed from the new delta")
        lock.setOwner(lock.gesture, .vertical)
        lock.ended(at: 2.0)
        #expect(lock.phase == .ended(at: 2.0, from: .unphased), "an unphased end keeps its phase")
        let ended = lock.gesture
        lock.delta(at: 2.001, dx: 0, dy: -10, pending: nil)
        #expect(lock.gesture != ended, "a delta after the end starts another gesture at once")
        lock.lost(pending: nil)
        #expect(lock.phase == .unphased(at: nil), "the loss forgets when it last moved")
    }

    /// `an_ended_gestures_momentum_has_the_gap_its_end_time_measures`
    @Test("an ended gesture's momentum has the gap its end time measures")
    func anEndedGesturesMomentumHasTheGapItsEndTimeMeasures() {
        var lock = WheelLock()
        lock.delta(at: 0.0, dx: 0, dy: -10, pending: nil)
        lock.setOwner(lock.gesture, .vertical)
        lock.ended(at: 1.0)
        let gesture = lock.gesture
        let soon = 1.0 + WheelLock.momentumGap * 0.5
        lock.began(at: soon, active: true, queued: false, pending: nil)
        #expect(lock.phase == .momentum(at: soon), "within the gap: its momentum")
        #expect(lock.gesture == gesture, "keeping the gesture")
        #expect(lock.momentum)
        lock.ended(at: 2.0)
        #expect(lock.phase == .ended(at: 2.0, from: .momentum))
        lock.began(at: 2.0 + WheelLock.momentumGap * 0.5, active: true, queued: false, pending: nil)
        if case .phased = lock.phase {} else { Issue.record("one that ended as momentum is a new touch") }
        #expect(!lock.momentum)

        var lock2 = WheelLock()
        lock2.delta(at: 0.0, dx: 0, dy: -10, pending: nil)
        lock2.setOwner(lock2.gesture, .vertical)
        lock2.ended(at: 1.0)
        let gesture2 = lock2.gesture
        lock2.began(at: 1.0 + WheelLock.momentumGap + 0.01, active: true, queued: false, pending: nil)
        #expect(lock2.gesture != gesture2, "after the gap it is its own gesture")
    }

    @MainActor
    static func xyView() -> Runtime<Void> {
        Runtime(
            state: (),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            view: { _, _ in
                col().size(200, 200)
                    .child(col().key("xy").size(200, 200).scrollXY()
                        .onWheel { _, _, _ in false }
                        .child(el().key("content").w(1000).h(1000)))
            }
        )
    }

    /// `a_queued_cross_axis_delta_after_an_unphased_end_picks_its_axis`
    @Test("a queued cross-axis delta after an unphased end picks its axis")
    @MainActor
    func aQueuedCrossAxisDeltaAfterAnUnphasedEndPicksItsAxis() {
        let rt = Self.xyView()
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: Self.t)
        Self.wheelEvent(rt, dx: -10, dy: 0, x: 100, y: 100)
        Self.wheelEvent(rt, dx: 0, dy: -20, x: 100, y: 100)
        rt.wheelEnded(now: Self.t)
        _ = rt.frame(at: 2 * Self.t)
        let off = rt.scrollOffset(forKey: "xy")
        #expect(off.x == 10.0 && off.y == 20.0, "each queued delta scrolls the axis it picks")
    }

    /// `a_delta_queued_before_a_phased_gesture_began_keeps_its_own_axis_policy`
    @Test("a delta queued before a phased gesture began keeps its own axis policy")
    @MainActor
    func aDeltaQueuedBeforeAPhasedGestureBeganKeepsItsOwnAxisPolicy() {
        let rt = Self.xyView()
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: Self.t)
        Self.wheelEvent(rt, dx: -10, dy: 0, x: 100, y: 100)
        Self.wheelEvent(rt, dx: 0, dy: -20, x: 100, y: 100)
        rt.wheelBegan(now: Self.t)
        _ = rt.frame(at: 2 * Self.t)
        let off = rt.scrollOffset(forKey: "xy")
        #expect(off.x == 10.0 && off.y == 20.0, "the queued cross-axis delta keeps its own policy")
    }

    // MARK: origin/dev's wheel lock, transcribed (`DevLock`)

    /// origin/dev's wheel lock, transcribed: when its last delta came (`at`), whether the gesture
    /// was phased and momentum, and when the platform ended it (`ended`), beside the owner, in
    /// place of the phase that carries them.
    struct DevLock {
        enum Owner: Equatable { case unpicked, vertical, horizontal }
        var gesture: UInt32 = 0
        var runGesture: UInt32 = 0
        var owner: Owner = .unpicked
        var at: Double? = nil
        var phased = false
        var momentum = false
        var ended: Double? = nil

        mutating func restart(queued: Bool) {
            gesture += 1
            phased = false
            momentum = false
            ended = nil
            if !queued {
                runGesture = gesture
                owner = .unpicked
            }
        }

        mutating func delta(now: Double, dx: Float, dy: Float, queued: Bool) {
            let idle = phased ? WheelLock.phasedIdle : WheelLock.wheelIdle
            let flipped: Bool
            if !phased && runGesture == gesture {
                switch owner {
                case .horizontal: flipped = dx == 0
                case .vertical: flipped = dy == 0
                case .unpicked: flipped = false
                }
            } else {
                flipped = false
            }
            let stale = ended != nil || at.map { now - $0 > idle } ?? true || flipped
            if stale { restart(queued: queued) }
            at = now
        }

        mutating func began(now: Double, active: Bool, queued: Bool, anyQueued: Bool) {
            let isMomentum = !momentum && (active || queued) && ended.map { now - $0 <= WheelLock.momentumGap } == true
            if !isMomentum { restart(queued: anyQueued) }
            phased = true
            momentum = isMomentum
            ended = nil
            at = now
        }

        mutating func lost(queued: Bool) {
            restart(queued: queued)
            at = nil
        }

        var horizontal: Bool? {
            switch owner {
            case .unpicked: return nil
            case .vertical: return false
            case .horizontal: return true
            }
        }

        mutating func scroll(dx: Float, dy: Float, across: Bool) -> Bool {
            if let h = horizontal, phased || (h ? dx != 0 : dy != 0) { return h }
            owner = across ? .horizontal : .vertical
            return across
        }
    }

    /// The gesture dev's `run_gesture` mirrors: the older one whose queued deltas still wait,
    /// else the arriving one.
    static func running(_ lock: WheelLock) -> AttemptToken {
        if case .waiting(let gesture, _, _) = lock.run { return gesture }
        return lock.gesture
    }

    /// Who dev's single `owner` mirrors: the owner of the gesture it runs.
    static func runningOwner(_ lock: WheelLock) -> WheelOwner {
        switch lock.run {
        case .waiting(_, let owner, _): return owner
        case .arriving(let owner): return owner
        }
    }

    static func ownerKind(_ owner: WheelOwner) -> DevLock.Owner? {
        switch owner {
        case .unpicked: return .unpicked
        case .vertical: return .vertical
        case .horizontal: return .horizontal
        // A handler owns the gesture only after `run_wheel` took a delta, which this walk
        // never drives.
        case .handler: return nil
        }
    }

    enum WAct: CustomStringConvertible {
        case delta(dx: Float, dy: Float, gap: Double, queued: Bool)
        case began(gap: Double, queued: Bool)
        case ended(gap: Double)
        case lost(queued: Bool)
        case scroll(dx: Float, dy: Float, across: Bool)

        var description: String {
            switch self {
            case .delta(let dx, let dy, let gap, let q): return "Delta(\(dx),\(dy),gap \(gap),queued \(q))"
            case .began(let gap, let q): return "Began(gap \(gap),queued \(q))"
            case .ended(let gap): return "Ended(gap \(gap))"
            case .lost(let q): return "Lost(queued \(q))"
            case .scroll(let dx, let dy, let a): return "Scroll(\(dx),\(dy),across \(a))"
            }
        }
    }

    /// Drives a sequence through the lock and through dev's fields, one event at a time,
    /// comparing the phase's facts, the owner and the axis each delta scrolls after every event.
    /// Returns the first mismatch, if any.
    static func wheelWalk(_ acts: [WAct]) -> String? {
        var lock = WheelLock()
        var dev = DevLock()
        var now = 0.0
        for (i, act) in acts.enumerated() {
            let before = lock.gesture
            let devBefore = dev.gesture
            switch act {
            case .delta(let dx, let dy, let gap, let queued):
                now += gap
                let pending = queued ? running(lock) : nil
                lock.delta(at: now, dx: dx, dy: dy, pending: pending)
                dev.delta(now: now, dx: dx, dy: dy, queued: queued)
            case .began(let gap, let queued):
                now += gap
                let active = lock.owner != .unpicked
                let pending = queued ? running(lock) : nil
                lock.began(at: now, active: active, queued: queued, pending: pending)
                let devActive = dev.runGesture == dev.gesture && dev.owner != .unpicked
                dev.began(now: now, active: devActive, queued: queued, anyQueued: queued)
            case .ended(let gap):
                now += gap
                lock.ended(at: now)
                dev.ended = now
            case .lost(let queued):
                let pending = queued ? running(lock) : nil
                lock.lost(pending: pending)
                dev.lost(queued: queued)
            case .scroll(let dx, let dy, let across):
                // A delta of the gesture dev runs: the older one while its deltas wait, else
                // the arriving one. It carries that gesture's own policy.
                let gesture = running(lock)
                let h = lock.keepsAxis(gesture, dx: dx, dy: dy, phased: lock.phased)
                    ?? lock.repick(gesture, acrossPath: across ? "1" : nil)
                if h != dev.scroll(dx: dx, dy: dy, across: across) { return "\(acts), event \(i): axis" }
            }
            let at = "\(acts), event \(i) (\(act))"
            if (lock.gesture != before) != (dev.gesture != devBefore) { return "gesture: \(at)" }
            if lock.phase.isPhased != dev.phased { return "phased: \(at)" }
            if lock.phase.isMomentum != dev.momentum { return "momentum: \(at)" }
            // An ended phase keeps its end time where dev kept a separate `ended`: the last
            // delta's time is no longer read, so only a live phase's is compared.
            if dev.ended == nil && lock.phase.at != dev.at { return "at: \(at)" }
            if lock.phase.endedAt != dev.ended { return "ended: \(at)" }
            if ownerKind(runningOwner(lock)) != dev.owner { return "owner: \(at)" }
        }
        return nil
    }

    /// `the_phase_matches_devs_fields_over_every_order`: every order of deltas, platform phases,
    /// losses and the deltas that later scroll, up to five long, including an unphased gesture
    /// that ends with a cross-axis delta queued.
    @Test("the phase matches dev's fields over every order")
    func thePhaseMatchesDevsFieldsOverEveryOrder() {
        let acts: [WAct] = [
            .delta(dx: -10, dy: 0, gap: 0.0, queued: false),
            .delta(dx: -10, dy: 0, gap: 0.0, queued: true),
            .delta(dx: 0, dy: -20, gap: 0.0, queued: false),
            .delta(dx: 0, dy: -20, gap: 0.0, queued: true),
            .delta(dx: -10, dy: 0, gap: 0.2, queued: false),
            .ended(gap: 0.0),
            .ended(gap: 0.2),
            .began(gap: 0.02, queued: false),
            .began(gap: 0.02, queued: true),
            .lost(queued: false),
            .lost(queued: true),
            .scroll(dx: -10, dy: 0, across: true),
            .scroll(dx: 0, dy: -20, across: true),
            .scroll(dx: 0, dy: -20, across: false),
        ]
        var failure: String? = nil
        var walked = 0
        func walkAll(_ prefix: inout [WAct], _ len: Int) {
            if failure != nil { return }
            if prefix.count == len {
                walked += 1
                failure = Self.wheelWalk(prefix)
                return
            }
            for act in acts {
                prefix.append(act)
                walkAll(&prefix, len)
                prefix.removeLast()
                if failure != nil { return }
            }
        }
        for len in 0...5 {
            var prefix: [WAct] = []
            walkAll(&prefix, len)
        }
        #expect(failure == nil, "\(failure ?? "")")
        // 14^0 + 14^1 + ... + 14^5 sequences.
        #expect(failure != nil || walked == 1 + 14 + 196 + 2_744 + 38_416 + 537_824)
    }

    // MARK: - #856 native wheel distance (`shift_turns_only_a_purely_vertical_wheel`)

    @Test("shift turns only a purely vertical wheel (LINE_POINTS, SHIFT_TURNS_WHEEL)")
    func shiftTurnsOnlyAPurelyVerticalWheel() {
        let linePoints = WheelDistance.linePoints
        func wheelDelta(_ delta: MouseScrollDelta, _ scale: Float, _ shift: Bool) -> (Float, Float) {
            WheelDistance.wheelDelta(delta, scale: scale, shift: shift, linePoints: linePoints)
        }
        var d = wheelDelta(.line(x: 0, y: -1), 2, false)
        #expect(d.0 == 0 && d.1 == -linePoints)
        d = wheelDelta(.line(x: 0, y: -1), 2, true)
        #expect(d.0 == -linePoints && d.1 == 0, "Shift + mouse wheel")
        d = wheelDelta(.line(x: 0.5, y: 0), 2, false)
        #expect(d.0 == linePoints / 2 && d.1 == 0, "a fractional horizontal scroll increment")
        d = wheelDelta(.pixel(x: -8, y: 20), 2, true)
        #expect(d.0 == -4 && d.1 == 10, "a delta with a horizontal part stays as it is")
        #if os(macOS)
        #expect(WheelDistance.shiftTurnsWheel == false)
        #else
        #expect(WheelDistance.shiftTurnsWheel == true)
        #endif
        // Chromium 152: Linux kWheelDelta 120; macOS kScrollbarPixelsPerCocoaTick / web
        // kPixelsPerLineStep 40.
        #if os(Linux)
        #expect(linePoints == 120.0)
        #else
        #expect(linePoints == 40.0)
        #endif
    }
}
