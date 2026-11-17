import Foundation
import Testing
@testable import Rune
import RuneMotion

@Suite("Scroll State Machines Parity Tests")
struct ScrollStateMachinesParityTests {

    // MARK: - 1. PixelHold (`drawn.rs`, 6 tests)

    private func drawn(_ dir: Int8) -> PixelHold {
        .stepping(drawn: 100.0, dir: dir, pinned: true)
    }

    @Test("drawn: a_pinned_end_holds_its_pixel_through_a_reversal")
    func drawnAPinnedEndHoldsItsPixelThroughAReversal() {
        let (at, next) = drawn(-1).draw(exact: 100.006, offset: 100.0, pinned: true, scale: 2.0)
        #expect(at == 100.0, "held where it drew")
        #expect(next == .holding(drawn: 100.0, dir: -1))
    }

    @Test("drawn: a_direction_from_another_mode_does_not_hold")
    func drawnADirectionFromAnotherModeDoesNotHold() {
        let carried = PixelHold.stepping(drawn: 100.0, dir: -1, pinned: false)
        let (at, next) = carried.draw(exact: 100.006, offset: 100.0, pinned: true, scale: 2.0)
        let g = Snap.grid(100.006, scale: 2.0)
        #expect(at == g, "the step drew, not held")
        #expect(next == .stepping(drawn: g, dir: 1, pinned: true))
    }

    @Test("drawn: a_stationary_pinned_frame_keeps_the_mode_that_stepped")
    func drawnAStationaryPinnedFrameKeepsTheModeThatStepped() {
        let carried = PixelHold.stepping(drawn: 100.0, dir: -1, pinned: false)
        let (still, next1) = carried.draw(exact: 100.0, offset: 100.0, pinned: true, scale: 2.0)
        #expect(still == 100.0)
        #expect(next1 == .stepping(drawn: 100.0, dir: -1, pinned: false))
        let (at, next2) = next1.draw(exact: 100.006, offset: 100.0, pinned: true, scale: 2.0)
        let g = Snap.grid(100.006, scale: 2.0)
        #expect(at == g, "the first real step drew, not held")
        #expect(next2 == .stepping(drawn: g, dir: 1, pinned: true))
    }

    @Test("drawn: motion_one_way_rounds_as_before")
    func drawnMotionOneWayRoundsAsBefore() {
        let (at, next) = drawn(1).draw(exact: 100.013, offset: 100.0, pinned: true, scale: 2.0)
        let g = Snap.grid(100.013, scale: 2.0)
        #expect(at == g)
        #expect(next == .stepping(drawn: g, dir: 1, pinned: true))
    }

    @Test("drawn: the_layout_offset_always_lands")
    func drawnTheLayoutOffsetAlwaysLands() {
        let (at, _) = drawn(-1).draw(exact: 100.006, offset: 100.006, pinned: true, scale: 2.0)
        #expect(at == Snap.grid(100.006, scale: 2.0))
    }

    @Test("drawn: a_held_pixel_let_go_lands_where_the_content_is")
    func drawnAHeldPixelLetGoLandsWhereTheContentIs() {
        let held = PixelHold.holding(drawn: 100.0, dir: 1)
        let (at, next) = held.draw(exact: 100.02, offset: 100.0, pinned: true, scale: 2.0)
        let g = Snap.grid(100.02, scale: 2.0)
        #expect(at == g, "past one quantum, it steps")
        #expect(next == .stepping(drawn: g, dir: 1, pinned: true))
    }

    // MARK: - 2. ScrollNudge (`nudge_tests.rs`, 4 tests)

    private struct DevNudge {
        var nudged: UInt8 = 0

        mutating func arm() {
            nudged = 2
        }

        mutating func frame() -> Bool {
            if nudged > 0 { nudged -= 1 }
            return nudged > 0
        }

        var held: Bool { nudged > 0 }
    }

    private enum NudgeAct: CaseIterable {
        case arm
        case frame
    }

    private static let sixtyHzFrame: Double = 1.0 / 60.0

    @Test("nudge: the_hold_matches_the_countdown_at_sixty_hertz")
    func nudgeTheHoldMatchesTheCountdownAtSixtyHertz() {
        func walk(_ acts: [NudgeAct]) {
            var nudge = ScrollNudge()
            var dev = DevNudge()
            var now = 0.0
            for (at, act) in acts.enumerated() {
                switch act {
                case .arm:
                    let effects = nudge.arm(now: now)
                    dev.arm()
                    #expect(effects == .one(.wakeAt(now + ScrollNudge.nudgeHold)), "\(acts) at \(at): the arm asks for its due time")
                case .frame:
                    now += Self.sixtyHzFrame
                    nudge.tick(now: now)
                    _ = dev.frame()
                }
                #expect(nudge.holdAt(now: now) == dev.held, "\(acts): held after event \(at), at \(now)")
            }
        }

        func enumerate(_ acts: inout [NudgeAct], _ len: Int) {
            if acts.count == len {
                walk(acts)
                return
            }
            for act in NudgeAct.allCases {
                acts.append(act)
                enumerate(&acts, len)
                acts.removeLast()
            }
        }

        var acts: [NudgeAct] = []
        for len in 0...6 {
            acts.removeAll(keepingCapacity: true)
            enumerate(&acts, len)
        }
    }

    @Test("nudge: the_hold_covers_the_landing_frame_and_the_next")
    func nudgeTheHoldCoversTheLandingFrameAndTheNext() {
        var nudge = ScrollNudge()
        let landed = 4.5
        _ = nudge.arm(now: landed)
        #expect(nudge.holdAt(now: landed), "the frame it landed holds")
        nudge.tick(now: landed + Self.sixtyHzFrame)
        #expect(nudge.holdAt(now: landed + Self.sixtyHzFrame), "so does the next")
        nudge.tick(now: landed + 2.0 * Self.sixtyHzFrame)
        #expect(!nudge.holdAt(now: landed + 2.0 * Self.sixtyHzFrame), "and it is over on the third")
        #expect(nudge.state == .free)
        nudge.tick(now: landed + 3.0 * Self.sixtyHzFrame)
        #expect(!nudge.holdAt(now: landed + 3.0 * Self.sixtyHzFrame), "a spent hold stays free")
    }

    @Test("nudge: the_hold_ends_a_fixed_time_after_the_land")
    func nudgeTheHoldEndsAFixedTimeAfterTheLand() {
        for rate in [30.0, 120.0] {
            var nudge = ScrollNudge()
            var now = 0.0
            _ = nudge.arm(now: now)
            var freed: Double? = nil
            for _ in 0..<10 {
                now += 1.0 / rate
                nudge.tick(now: now)
                if !nudge.holdAt(now: now) {
                    freed = now
                    break
                }
            }
            guard let f = freed else {
                Issue.record("\(rate) fps: the hold ends")
                return
            }
            #expect(f >= ScrollNudge.nudgeHold - 1e-9 && f < ScrollNudge.nudgeHold + 1.0 / rate + 1e-9, "\(rate) fps: held \(f) seconds")
        }
    }

    @Test("nudge: a_due_from_an_earlier_arm_changes_nothing")
    func nudgeADueFromAnEarlierArmChangesNothing() {
        var nudge = ScrollNudge()
        var now = 0.0
        _ = nudge.arm(now: now)
        guard case .held(let first, let firstDue) = nudge.state else {
            Issue.record("armed")
            return
        }
        now += Self.sixtyHzFrame
        _ = nudge.arm(now: now)
        guard case .held(let second, let due) = nudge.state else {
            Issue.record("armed")
            return
        }
        #expect(second != first)
        #expect(due == now + ScrollNudge.nudgeHold)
        _ = ScrollNudge.step(seq: &nudge.seq, state: &nudge.state, event: .due(attempt: first, now: firstDue + 1.0))
        #expect(nudge.holdAt(now: now), "the newer arm still holds")
        #expect(nudge.state == .held(attempt: second, due: due))
    }

    // MARK: - 3. ScrollMode (`mode.rs`, 4 tests)

    private struct TestScrollState {
        var offset: Double = 0.0
        var max: Double = 0.0
        var mode: ScrollMode = .default

        mutating func moved() { _ = ScrollMode.step(&mode, .moved) }
        mutating func pin() { _ = ScrollMode.step(&mode, .pin) }
        mutating func unpin() { _ = ScrollMode.step(&mode, .unpin) }
        mutating func halt() { _ = ScrollMode.step(&mode, .halt) }
        mutating func land(_ stick: Bool) {
            if stick && offset >= max - 0.5 {
                pin()
            } else {
                _ = ScrollMode.step(&mode, .rest)
            }
        }
    }

    private enum DevModeKind: Equatable {
        case rest
        case pinned
        case momentum(Float)
        case glide(Float)
    }

    private struct DevModeState {
        var direct: Bool = false
        var scrolling: Bool = false
        var byHand: Bool = false
        var shrinkCut: Bool = false
        var laid: Double? = nil
        var mode: DevModeKind = .rest
        var writes: Int = 0

        func coast() -> Float {
            if case .momentum(let v) = mode { return v }
            return 0.0
        }

        mutating func step(_ xV: Float) {
            scrolling = direct || abs(coast()) > 1.0 || abs(xV) > 1.0
            byHand = byHand || scrolling
            direct = false
        }

        mutating func growth(_ moving: Bool) {
            shrinkCut = moving && (shrinkCut || direct || abs(coast()) > 1.0)
        }

        mutating func write(_ m: DevModeKind) {
            mode = m
            writes += 1
        }

        mutating func pin() {
            if mode != .pinned { write(.pinned) }
        }

        mutating func halt() {
            if mode != .pinned { write(.rest) }
        }

        mutating func unpin() {
            if mode == .pinned { write(.rest) }
        }

        mutating func land(offset: Double, max: Double, stick: Bool) {
            if stick && offset >= max - 0.5 { pin() } else { write(.rest) }
        }
    }

    private enum ModeAct {
        case moved
        case hold
        case coast(Bool)
        case still
        case growth(Bool)
        case step(xV: Float)
        case laid(Bool)
        case take
        case rest
        case halt
        case pin
        case unpin
        case land(offset: Double, max: Double, stick: Bool)
        case momentum(Float)
        case glide
    }

    private static func productionMode(_ mode: ScrollMode) -> DevModeKind {
        switch mode {
        case .rest: return .rest
        case .pinned: return .pinned
        case .momentum(let v, _): return .momentum(v)
        case .glide(let v, _, _): return .glide(v)
        }
    }

    @Test("mode: the_latches_match_devs_fields_over_every_order")
    func modeTheLatchesMatchDevsFieldsOverEveryOrder() {
        let acts: [ModeAct] = [
            .moved, .hold, .coast(true), .coast(false), .still,
            .growth(true), .growth(false), .step(xV: 4.0), .step(xV: 0.0),
            .laid(true), .laid(false), .take, .rest, .halt, .pin,
            .unpin, .land(offset: 100.0, max: 100.0, stick: true),
            .land(offset: 0.0, max: 100.0, stick: true),
            .land(offset: 100.0, max: 100.0, stick: false),
            .momentum(2.0), .glide,
        ]

        func walk(_ seq: [ModeAct]) {
            var st = TestScrollState()
            var dev = DevModeState()
            for (i, act) in seq.enumerated() {
                dev.writes = 0
                switch act {
                case .moved:
                    st.moved()
                    dev.direct = true
                case .hold:
                    _ = ScrollMode.step(&st.mode, .hold)
                    dev.scrolling = true
                    dev.byHand = true
                case .coast(let moving):
                    _ = ScrollMode.step(&st.mode, .coast(moving: moving))
                    dev.scrolling = moving
                    dev.byHand = dev.byHand || moving
                    dev.direct = false
                case .still:
                    _ = ScrollMode.step(&st.mode, .still)
                    dev.scrolling = false
                case .growth(let moving):
                    _ = ScrollMode.step(&st.mode, .growth(moving: moving))
                    dev.growth(moving)
                case .step(let xV):
                    _ = ScrollMode.step(&st.mode, .step(xV: xV))
                    dev.step(xV)
                case .laid(let has):
                    let end: Double? = has ? 120.0 : nil
                    _ = ScrollMode.step(&st.mode, .laid(end))
                    dev.laid = end
                case .take:
                    let effects = ScrollMode.step(&st.mode, .take)
                    let was = dev.byHand
                    dev.byHand = false
                    if was {
                        #expect(effects == .one(.tell), "\(seq), event \(i): the take")
                    } else {
                        #expect(effects.isEmpty, "\(seq), event \(i): the take")
                    }
                case .rest:
                    st.mode = st.mode.toRest()
                    dev.write(.rest)
                case .halt:
                    st.halt()
                    dev.halt()
                case .pin:
                    st.pin()
                    dev.pin()
                case .unpin:
                    st.unpin()
                    dev.unpin()
                case .land(let offset, let max, let stick):
                    st.offset = offset
                    st.max = max
                    st.land(stick)
                    dev.land(offset: offset, max: max, stick: stick)
                case .momentum(let v):
                    st.mode = st.mode.toMomentum(v)
                    dev.write(.momentum(v))
                case .glide:
                    st.mode = st.mode.toGlide(2.0, to: .bottom)
                    dev.write(.glide(2.0))
                }
                let hand = st.mode.hand
                let writes = ScrollMode.takeWriteCount()
                let prod = Self.productionMode(st.mode)
                if hand.direct != dev.direct
                    || hand.scrolling != dev.scrolling
                    || hand.byHand != dev.byHand
                    || hand.shrinkCut != dev.shrinkCut
                    || hand.laid != dev.laid
                    || prod != dev.mode
                    || writes != dev.writes {
                    #expect(hand.direct == dev.direct, "direct: \(seq), event \(i)")
                    #expect(hand.scrolling == dev.scrolling, "scrolling: \(seq), event \(i)")
                    #expect(hand.byHand == dev.byHand, "by_hand: \(seq), event \(i)")
                    #expect(hand.shrinkCut == dev.shrinkCut, "shrink_cut: \(seq), event \(i)")
                    #expect(hand.laid == dev.laid, "laid: \(seq), event \(i)")
                    #expect(prod == dev.mode, "mode: \(seq), event \(i)")
                    #expect(writes == dev.writes, "mode writes: \(seq), event \(i)")
                    return
                }
            }
        }

        func walkAll(_ len: Int, _ prefix: inout [ModeAct]) {
            if prefix.count == len {
                walk(prefix)
                return
            }
            for act in acts {
                prefix.append(act)
                walkAll(len, &prefix)
                prefix.removeLast()
            }
        }

        ScrollMode.withWriteCounting {
            var prefix: [ModeAct] = []
            for len in 0...4 {
                walkAll(len, &prefix)
            }
        }
    }

    @Test("mode: a_landing_on_a_pinned_viewport_writes_nothing")
    func modeALandingOnAPinnedViewportWritesNothing() {
        ScrollMode.withWriteCounting {
            var st = TestScrollState(offset: 100.0, max: 100.0)
            st.pin()
            _ = ScrollMode.takeWriteCount()
            st.land(true)
            #expect(ScrollMode.takeWriteCount() == 0, "already at the pinned end, the landing writes nothing")
            st.land(false)
            #expect(ScrollMode.takeWriteCount() == 1, "off the end it writes the rest")
            st.offset = 0.0
            st.land(true)
            #expect(ScrollMode.takeWriteCount() == 1, "short of the end it writes the rest")
        }
    }

    @Test("mode: a_hand_move_is_told_once_and_the_steps_keep_growing_it")
    func modeAHandMoveIsToldOnceAndTheStepsKeepGrowingIt() {
        var mode = ScrollMode.default
        _ = ScrollMode.step(&mode, .moved)
        _ = ScrollMode.step(&mode, .step(xV: 0.0))
        #expect(mode.hand.scrolling && mode.hand.byHand && !mode.hand.direct)
        _ = ScrollMode.step(&mode, .step(xV: 0.0))
        #expect(!mode.hand.scrolling, "the step moved nothing")
        #expect(mode.hand.byHand, "the watcher still has to hear it")
        #expect(ScrollMode.step(&mode, .take).array == [.tell])
        #expect(ScrollMode.step(&mode, .take).array == [])
    }

    @Test("mode: a_motion_change_keeps_the_hands_latches")
    func modeAMotionChangeKeepsTheHandsLatches() {
        var mode = ScrollMode.default
        _ = ScrollMode.step(&mode, .moved)
        _ = ScrollMode.step(&mode, .laid(300.0))
        for changed in [
            mode.toGlide(1.0, to: .offset(40.0)),
            mode.toMomentum(2.0),
            mode.toPinned(),
            mode.toRest(),
        ] {
            #expect(changed.hand.direct && changed.hand.laid == 300.0, "\(changed)")
            mode = changed
        }
        #expect(mode.hand.direct && mode.hand.laid == 300.0)
    }

    // MARK: - 4. TouchScrollMachine (`touch.rs`, 6 pure tests)

    private func runTouch(_ state: inout TouchScroll?, _ event: TouchEvent) -> [TouchEffect] {
        TouchScrollMachine.step(&state, event).array
    }

    @Test("touch: edge_return_is_frame_rate_independent")
    func touchEdgeReturnIsFrameRateIndependent() {
        let one = TouchScrollMachine.rebound(offset: -50.0, velocity: -400.0, target: 0.0, dt: 0.5)
        var many: (Double, Float) = (-50.0, -400.0)
        for _ in 0..<60 {
            many = TouchScrollMachine.rebound(offset: many.0, velocity: many.1, target: 0.0, dt: 0.5 / 60.0)
        }
        #expect(abs(one.0 - many.0) < 0.001)
        #expect(abs(one.1 - many.1) < 0.01)
        #expect(one.0 < 0.0 && one.0 > -1.0)
    }

    @Test("touch: a_down_holds_the_viewport_under_it_and_stops_its_motion")
    func touchADownHoldsTheViewportUnderItAndStopsItsMotion() {
        let (page, strip) = (NodeId(1), NodeId(2))
        var state: TouchScroll? = nil
        let effects = runTouch(&state, .down(across: (strip, 5.0), vertical: (page, 7.0)))
        #expect(state == .held(id: page, origin: 7.0, horizontal: false))
        #expect(effects == [.stopAcross(strip), .halt(page)])

        // A horizontal viewport still settling is caught where the finger lands on it.
        var state2: TouchScroll? = .coasting(id: strip, horizontal: true)
        _ = runTouch(&state2, .down(across: (strip, -20.0), vertical: (page, 7.0)))
        #expect(state2 == .held(id: strip, origin: -20.0, horizontal: true), "caught, not handed to the page")

        // A touch outside every viewport leaves the settling one alone.
        var state3: TouchScroll? = .coasting(id: strip, horizontal: false)
        _ = runTouch(&state3, .down(across: nil, vertical: nil))
        #expect(state3 == .coasting(id: strip, horizontal: false))
    }

    @Test("touch: a_pan_turns_a_held_viewport_into_a_drag_with_the_offset_it_was_caught_at")
    func touchAPanTurnsAHeldViewportIntoADragWithTheOffsetItWasCaughtAt() {
        let (page, strip) = (NodeId(1), NodeId(2))
        var state: TouchScroll? = .held(id: page, origin: 7.0, horizontal: false)
        _ = runTouch(&state, .pan(horizontal: false, across: nil, vertical: (page, 9.0)))
        #expect(state == .dragging(id: page, origin: 7.0, horizontal: false), "keeps the offset the finger went down at")

        // A horizontal pan takes the horizontal viewport under the finger, from its offset now.
        var state2: TouchScroll? = .held(id: page, origin: 7.0, horizontal: false)
        _ = runTouch(&state2, .pan(horizontal: true, across: (strip, 4.0), vertical: (page, 9.0)))
        #expect(state2 == .dragging(id: strip, origin: 4.0, horizontal: true))

        // A finger down on a horizontal viewport with no vertical one still pans it.
        var state3: TouchScroll? = nil
        _ = runTouch(&state3, .pan(horizontal: true, across: (strip, 4.0), vertical: nil))
        #expect(state3 == .dragging(id: strip, origin: 4.0, horizontal: true))

        // A vertical pan lets a caught horizontal viewport go to the vertical one.
        var state4: TouchScroll? = .held(id: strip, origin: -20.0, horizontal: true)
        _ = runTouch(&state4, .pan(horizontal: false, across: (strip, -20.0), vertical: (page, 9.0)))
        #expect(state4 == .dragging(id: page, origin: 9.0, horizontal: false))

        // With no vertical viewport under it, the horizontal one is left settling.
        var state5: TouchScroll? = .held(id: strip, origin: -20.0, horizontal: true)
        _ = runTouch(&state5, .pan(horizontal: false, across: nil, vertical: nil))
        #expect(state5 == .coasting(id: strip, horizontal: true))
    }

    @Test("touch: a_lift_starts_the_coast_and_flings_only_the_viewport_it_held")
    func touchALiftStartsTheCoastAndFlingsOnlyTheViewportItHeld() {
        let (page, strip) = (NodeId(1), NodeId(2))
        var state: TouchScroll? = .dragging(id: page, origin: 0.0, horizontal: false)
        let effects = runTouch(&state, .up(id: page, velocity: -1200.0))
        #expect(state == .coasting(id: page, horizontal: false))
        #expect(effects == [.fling(id: page, horizontal: false, velocity: -1200.0)])

        // A lift from another viewport still lets this one go, without a fling.
        var state2: TouchScroll? = .dragging(id: page, origin: 0.0, horizontal: false)
        #expect(runTouch(&state2, .up(id: strip, velocity: 0.0)) == [])
        #expect(state2 == .coasting(id: page, horizontal: false))
    }

    @Test("touch: a_move_and_a_frame_tick_go_through_step")
    func touchAMoveAndAFrameTickGoThroughStep() {
        let page = NodeId(1)
        var state: TouchScroll? = .dragging(id: page, origin: 5.0, horizontal: false)
        #expect(
            runTouch(&state, .move(id: page, d: -30.0))
                == [.pan(id: page, origin: 5.0, horizontal: false, d: -30.0)]
        )
        #expect(
            runTouch(&state, .tick(id: page, horizontal: false, overflow: 40.0, dt: 1.0 / 60.0))
                == [.hold(id: page, horizontal: false, overflow: 40.0)],
            "a held viewport only has its bounds set"
        )

        var state2: TouchScroll? = .coasting(id: page, horizontal: false)
        #expect(
            runTouch(&state2, .tick(id: page, horizontal: false, overflow: 40.0, dt: 1.0 / 60.0))
                == [.coast(id: page, horizontal: false, overflow: 40.0, dt: 1.0 / 60.0)],
            "a coasting one is stepped"
        )

        // A move of a viewport the finger no longer drags, or a tick for another axis, asks for nothing.
        var state3: TouchScroll? = .held(id: page, origin: 5.0, horizontal: false)
        #expect(runTouch(&state3, .move(id: page, d: -30.0)) == [])
        #expect(runTouch(&state3, .tick(id: page, horizontal: true, overflow: 40.0, dt: 0.1)) == [])
    }

    @Test("touch: a_coast_reaches_rest_and_nothing_else_is_cleared")
    func touchACoastReachesRestAndNothingElseIsCleared() {
        let page = NodeId(1)
        var state: TouchScroll? = .coasting(id: page, horizontal: false)
        _ = runTouch(&state, .settled(moving: true))
        #expect(state == .coasting(id: page, horizontal: false), "still moving")
        _ = runTouch(&state, .settled(moving: false))
        #expect(state == nil, "came to rest")

        var state2: TouchScroll? = .dragging(id: page, origin: 0.0, horizontal: false)
        _ = runTouch(&state2, .settled(moving: false))
        #expect(state2 == .dragging(id: page, origin: 0.0, horizontal: false), "a drag never settles itself")
    }

    // MARK: - 5. ScrollWatch (`watch.rs`, 2 pure Watch tests + TaskLocal isolation)

    private struct DevWatch {
        var told: ScrollPos? = nil
        weak var toldBy: ScrollWatch.Handler? = nil

        mutating func seen(y: Float, handler: ScrollWatch.Handler?, byHand: Bool) -> (ScrollPos, Bool)? {
            guard let f = handler else { return nil }
            let at = Self.pos(y)
            let prev = told
            told = at
            let changed = prev != at
            let newHandler = toldBy !== f
            if newHandler {
                toldBy = f
            }
            if !changed && !newHandler {
                return nil
            }
            let scrolled = byHand && (prev.map { old in
                abs(old.offset.x - at.offset.x) > 0.01 || abs(old.offset.y - at.offset.y) > 0.01
            } ?? false)
            return (at, scrolled)
        }

        static func pos(_ y: Float) -> ScrollPos {
            ScrollPos(
                offset: Vec2(0.0, y),
                max: Vec2(0.0, 800.0),
                viewport: Vec2(300.0, 200.0),
                drawn: Vec2(300.0, 200.0)
            )
        }
    }

    @Test("watch: two_handlers_at_the_same_offset_each_hear_the_first_time")
    func watchTwoHandlersAtTheSameOffsetEachHearTheFirstTime() {
        let first = ScrollWatch.Handler()
        let second = ScrollWatch.Handler()
        var watch = ScrollWatch.Watch()
        let at = DevWatch.pos(0.0)
        func told(_ handler: ScrollWatch.Handler) -> [ScrollWatch.Effect] {
            ScrollWatch.step(&watch, .seen(at: at, handler: handler, byHand: false)).array
        }
        #expect(told(first) == [.tell(at: at, scrolled: false)])
        #expect(told(first) == [], "the same handler hears it once")
        #expect(told(second) == [.tell(at: at, scrolled: false)], "a second handler is new, even with the same value")
    }

    @Test("watch: the_watcher_matches_devs_told_offset_and_handler_over_every_order")
    func watchTheWatcherMatchesDevsToldOffsetAndHandlerOverEveryOrder() {
        struct WatchAct {
            var y: Float
            var handler: Int // 0 = nil, 1 = handlers[0], 2 = handlers[1]
            var byHand: Bool
        }

        var acts: [WatchAct] = []
        for y in [Float(0.0), Float(12.0)] {
            for h in 0...2 {
                for byHand in [false, true] {
                    acts.append(WatchAct(y: y, handler: h, byHand: byHand))
                }
            }
        }

        let handlers = [ScrollWatch.Handler(), ScrollWatch.Handler()]

        func walk(_ seq: [WatchAct]) {
            var watch = ScrollWatch.Watch()
            var dev = DevWatch()
            for (i, act) in seq.enumerated() {
                let handler: ScrollWatch.Handler? = act.handler == 0 ? nil : handlers[act.handler - 1]
                let effects = ScrollWatch.step(&watch, .seen(at: DevWatch.pos(act.y), handler: handler, byHand: act.byHand))
                let expected = dev.seen(y: act.y, handler: handler, byHand: act.byHand)
                let matchedEffect: Bool
                if let (at, scrolled) = expected {
                    matchedEffect = (effects == .one(.tell(at: at, scrolled: scrolled)))
                } else {
                    matchedEffect = effects.isEmpty
                }
                if !matchedEffect || watch.told != dev.told || watch.handler !== dev.toldBy {
                    #expect(matchedEffect, "\(seq), event \(i)")
                    #expect(watch.told == dev.told, "\(seq), event \(i)")
                    #expect(watch.handler === dev.toldBy, "\(seq), event \(i): the handler told")
                    return
                }
            }
        }

        func forEachWalk(_ len: Int, _ prefix: inout [WatchAct]) {
            if prefix.count == len {
                walk(prefix)
                return
            }
            for act in acts {
                prefix.append(act)
                forEachWalk(len, &prefix)
                prefix.removeLast()
            }
        }

        var prefix: [WatchAct] = []
        for len in 0...5 {
            forEachWalk(len, &prefix)
        }
    }

    @Test("watch: scrollWatchState uses TaskLocal isolation")
    func watchTaskLocalStateIsIsolatedAcrossTasks() async {
        let initial = scrollWatchState()
        #expect(initial.scrolled == false && initial.instant == false && initial.now == 0.0)
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                ScrollWatch.withState(scrolled: true, instant: false, now: 1.5) {
                    let s = scrollWatchState()
                    return s.scrolled == true && s.instant == false && s.now == 1.5
                }
            }
            group.addTask {
                ScrollWatch.withState(scrolled: false, instant: true, now: 9.25) {
                    let s = scrollWatchState()
                    return s.scrolled == false && s.instant == true && s.now == 9.25
                }
            }
            for await ok in group {
                #expect(ok)
            }
        }
        let after = scrollWatchState()
        #expect(after.scrolled == false && after.instant == false && after.now == 0.0)
    }

    // MARK: - 6. ScrollSlack (`bottom.rs`, 1 pure Slack test)

    @Test("bottom: slack_waits_out_growth_then_closes_and_slack_after_that_closes_at_once")
    func bottomSlackWaitsOutGrowthThenClosesAndSlackAfterThatClosesAtOnce() {
        let spec = GrowthSpec.default
        let dt: Float = 1.0 / 120.0
        var s = ScrollSlack()
        s.track.h = 40.0
        s.settle(growing: true, now: 1.0, dt: dt, spec: spec)
        #expect(s.phase == .held(grewAt: 1.0))
        s.settle(growing: false, now: 1.0 + ScrollSlack.slackWait * 0.9, dt: dt, spec: spec)
        #expect(s.phase == .held(grewAt: 1.0) && s.track.h == 40.0, "held through the wait")
        s.settle(growing: false, now: 1.0 + ScrollSlack.slackWait, dt: dt, spec: spec)
        let closing1: Bool = if case .closing = s.phase { true } else { false }
        #expect(closing1 && s.track.h < 40.0)
        let h = s.track.h
        s.settle(growing: true, now: 1.2, dt: dt, spec: spec)
        #expect(s.phase == .held(grewAt: 1.2) && s.track.h == h, "growth holds it again")

        var now = 1.2
        while s.phase != .waited {
            now += Double(dt)
            s.settle(growing: false, now: now, dt: dt, spec: spec)
            #expect(now < 3.0, "closes: \(s)")
            if now >= 3.0 { break }
        }
        #expect(s.track.h == 0.0)
        s.track.h = 10.0
        s.settle(growing: false, now: now + Double(dt), dt: dt, spec: spec)
        let closing2: Bool = if case .closing = s.phase { true } else { false }
        #expect(closing2, "the wait was already over")
    }

    // MARK: - 7. WheelLock & wheelDelta (`x.rs`, 4 pure unit tests)

    private enum DevWheelOwner: Equatable {
        case unpicked
        case vertical
        case horizontal
    }

    private struct DevWheelLock {
        var gesture: UInt32 = 0
        var runGesture: UInt32 = 0
        var owner: DevWheelOwner = .unpicked
        var at: Double? = nil
        var phased: Bool = false
        var momentum: Bool = false
        var ended: Double? = nil

        mutating func restart(queued: Bool) {
            gesture &+= 1
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
                case .horizontal: flipped = dx == 0.0
                case .vertical: flipped = dy == 0.0
                case .unpicked: flipped = false
                }
            } else {
                flipped = false
            }
            let timedOut = at.map { now - $0 > idle } ?? true
            let stale = ended != nil || timedOut || flipped
            if stale { restart(queued: queued) }
            at = now
        }

        mutating func began(now: Double, active: Bool, queued: Bool, anyQueued: Bool) {
            let withinGap = ended.map { now - $0 <= WheelLock.momentumGap } ?? false
            let isMomentum = !momentum && (active || queued) && withinGap
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

        func horizontalAxis() -> Bool? {
            switch owner {
            case .unpicked: return nil
            case .vertical: return false
            case .horizontal: return true
            }
        }

        mutating func scroll(dx: Float, dy: Float, across: Bool) -> Bool {
            if let h = horizontalAxis(), phased || (h ? dx != 0.0 : dy != 0.0) {
                return h
            }
            owner = across ? .horizontal : .vertical
            return across
        }
    }

    private enum WheelAct {
        case delta(dx: Float, dy: Float, gap: Double, queued: Bool)
        case began(gap: Double, queued: Bool)
        case ended(gap: Double)
        case lost(queued: Bool)
        case scroll(dx: Float, dy: Float, across: Bool)
    }

    private static func wheelOwnerKind(_ owner: WheelOwner) -> DevWheelOwner? {
        switch owner {
        case .unpicked: return .unpicked
        case .vertical: return .vertical
        case .horizontal: return .horizontal
        case .handler: return nil
        }
    }

    @Test("wheel: the_phase_carries_when_the_gesture_last_moved_and_when_it_ended")
    func wheelThePhaseCarriesWhenTheGestureLastMovedAndWhenItEnded() {
        var lock = WheelLock()
        lock.delta(at: 1.0, dx: 0.0, dy: -10.0, pending: nil)
        #expect(lock.phase == .unphased(at: 1.0), "a delta starts it, timed")
        lock.delta(at: 1.05, dx: 0.0, dy: -10.0, pending: nil)
        #expect(lock.phase == .unphased(at: 1.05), "a pause under the idle keeps the gesture")
        let gesture = lock.gesture
        lock.delta(at: 1.05 + WheelLock.wheelIdle + 0.01, dx: 0.0, dy: -10.0, pending: nil)
        #expect(lock.gesture != gesture, "a longer pause starts another")
        #expect(lock.phase == .unphased(at: 1.05 + WheelLock.wheelIdle + 0.01), "timed from the new delta")
        lock.setOwner(lock.gesture, .vertical)
        lock.ended(at: 2.0)
        #expect(lock.phase == .ended(at: 2.0, from: .unphased), "an unphased end keeps its phase")
        let ended = lock.gesture
        lock.delta(at: 2.001, dx: 0.0, dy: -10.0, pending: nil)
        #expect(lock.gesture != ended, "a delta after the end starts another gesture at once")
        lock.lost(pending: nil)
        #expect(lock.phase == .unphased(at: nil), "the loss forgets when it last moved")
    }

    @Test("wheel: an_ended_gestures_momentum_has_the_gap_its_end_time_measures")
    func wheelAnEndedGesturesMomentumHasTheGapItsEndTimeMeasures() {
        var lock = WheelLock()
        lock.delta(at: 0.0, dx: 0.0, dy: -10.0, pending: nil)
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
        let isPhased: Bool = if case .phased = lock.phase { true } else { false }
        #expect(isPhased, "one that ended as momentum is a new touch")
        #expect(!lock.momentum)

        var lock2 = WheelLock()
        lock2.delta(at: 0.0, dx: 0.0, dy: -10.0, pending: nil)
        lock2.setOwner(lock2.gesture, .vertical)
        lock2.ended(at: 1.0)
        let gesture2 = lock2.gesture
        lock2.began(at: 1.0 + WheelLock.momentumGap + 0.01, active: true, queued: false, pending: nil)
        #expect(lock2.gesture != gesture2, "after the gap it is its own gesture")
    }

    @Test("wheel: the_phase_matches_devs_fields_over_every_order")
    func wheelThePhaseMatchesDevsFieldsOverEveryOrder() {
        let acts: [WheelAct] = [
            .delta(dx: -10.0, dy: 0.0, gap: 0.0, queued: false),
            .delta(dx: -10.0, dy: 0.0, gap: 0.0, queued: true),
            .delta(dx: 0.0, dy: -20.0, gap: 0.0, queued: false),
            .delta(dx: 0.0, dy: -20.0, gap: 0.0, queued: true),
            .delta(dx: -10.0, dy: 0.0, gap: 0.2, queued: false),
            .ended(gap: 0.0),
            .ended(gap: 0.2),
            .began(gap: 0.02, queued: false),
            .began(gap: 0.02, queued: true),
            .lost(queued: false),
            .lost(queued: true),
            .scroll(dx: -10.0, dy: 0.0, across: true),
            .scroll(dx: 0.0, dy: -20.0, across: true),
            .scroll(dx: 0.0, dy: -20.0, across: false),
        ]

        func walk(_ seq: [WheelAct]) {
            var lock = WheelLock()
            var dev = DevWheelLock()
            var now = 0.0
            for (i, act) in seq.enumerated() {
                let before = lock.gesture
                let devBefore = dev.gesture
                switch act {
                case .delta(let dx, let dy, let gap, let queued):
                    now += gap
                    lock.delta(at: now, dx: dx, dy: dy, pending: queued ? WheelOwnerHandoffParityTests.running(lock) : nil)
                    dev.delta(now: now, dx: dx, dy: dy, queued: queued)
                case .began(let gap, let queued):
                    now += gap
                    let active = lock.owner != .unpicked
                    lock.began(at: now, active: active, queued: queued, pending: queued ? WheelOwnerHandoffParityTests.running(lock) : nil)
                    let devActive = dev.runGesture == dev.gesture && dev.owner != .unpicked
                    dev.began(now: now, active: devActive, queued: queued, anyQueued: queued)
                case .ended(let gap):
                    now += gap
                    lock.ended(at: now)
                    dev.ended = now
                case .lost(let queued):
                    lock.lost(pending: queued ? WheelOwnerHandoffParityTests.running(lock) : nil)
                    dev.lost(queued: queued)
                case .scroll(let dx, let dy, let across):
                    let gesture = WheelOwnerHandoffParityTests.running(lock)
                    let h = lock.keepsAxis(gesture, dx: dx, dy: dy, phased: lock.phased) ?? lock.repick(gesture, acrossPath: across ? "1" : nil)
                    let expectedH = dev.scroll(dx: dx, dy: dy, across: across)
                    if h != expectedH {
                        #expect(h == expectedH, "\(seq), event \(i): axis")
                        return
                    }
                }
                let gestureChanged = (lock.gesture != before) == (dev.gesture != devBefore)
                let atMatches = dev.ended != nil || lock.phase.at == dev.at
                let ownerMatches = Self.wheelOwnerKind(WheelOwnerHandoffParityTests.runningOwner(lock)) == dev.owner
                if !gestureChanged
                    || lock.phase.isPhased != dev.phased
                    || lock.phase.isMomentum != dev.momentum
                    || !atMatches
                    || lock.phase.endedAt != dev.ended
                    || !ownerMatches {
                    #expect((lock.gesture != before) == (dev.gesture != devBefore), "gesture: \(seq), event \(i)")
                    #expect(lock.phase.isPhased == dev.phased, "phased: \(seq), event \(i)")
                    #expect(lock.phase.isMomentum == dev.momentum, "momentum: \(seq), event \(i)")
                    if dev.ended == nil {
                        #expect(lock.phase.at == dev.at, "at: \(seq), event \(i)")
                    }
                    #expect(lock.phase.endedAt == dev.ended, "ended: \(seq), event \(i)")
                    #expect(Self.wheelOwnerKind(WheelOwnerHandoffParityTests.runningOwner(lock)) == dev.owner, "owner: \(seq), event \(i)")
                    return
                }
            }
        }

        func walkAll(_ len: Int, _ prefix: inout [WheelAct]) {
            if prefix.count == len {
                walk(prefix)
                return
            }
            for act in acts {
                prefix.append(act)
                walkAll(len, &prefix)
                prefix.removeLast()
            }
        }

        var prefix: [WheelAct] = []
        for len in 0...5 {
            walkAll(len, &prefix)
        }
    }

    @Test("wheel: shift_turns_only_a_purely_vertical_wheel")
    func wheelShiftTurnsOnlyAPurelyVerticalWheel() {
        #expect(wheelDelta(.lineDelta(0.0, -1.0), scale: 2.0, shift: false) == (0.0, -40.0))
        #expect(wheelDelta(.lineDelta(0.0, -1.0), scale: 2.0, shift: true) == (-40.0, 0.0), "Shift + mouse wheel")
        #expect(wheelDelta(.lineDelta(1.0, 0.0), scale: 2.0, shift: false) == (40.0, 0.0), "a horizontal wheel")
        let trackpad = MouseScrollDelta.pixelDelta(x: -8.0, y: 20.0)
        #expect(wheelDelta(trackpad, scale: 2.0, shift: true) == (-4.0, 10.0), "a delta with a horizontal part stays as it is")
        #if os(macOS)
        #expect(!WheelDistance.shiftTurnsWheel)
        #else
        #expect(WheelDistance.shiftTurnsWheel)
        #endif
    }

    // MARK: - 8. ScrollRequestsState (`requests_tests.rs`, 2 exhaustive sequence & release fuzz tests)

    private struct RequestScene {
        var mounted: String?
        var viewport: Bool
        var pinned: Bool
        var top: Float
    }

    private enum RequestInput {
        case captureKey(viewport: String, virtualized: Bool, header: String?)
        case fold
        case foldOpen(viewport: String, mounted: String?, end: Int)
        case place(viewport: String, first: Bool, to: Double, atEnd: Bool)
        case tail
        case endGives(header: String, pinned: String)
        case endClamp(RequestScene)
        case frame(glide: String, moving: String, mounted: Bool)
        case inputScroll
        case destination
    }

    private struct OldRequestsState {
        var keeps: [ScrollKeep] = []
        var reveals: [ScrollRevealTarget] = []

        mutating func apply(_ input: RequestInput) -> ScrollRequestEffect? {
            switch input {
            case .captureKey(let viewport, let virtualized, let header):
                keeps.removeAll { $0.viewport == viewport }
                reveals.removeAll { $0.viewport == viewport }
                let row: (listPath: String, rowKey: String, yInRow: Float)? = virtualized ? ("list", "row", 3.0) : nil
                keeps.append(ScrollKeep(
                    path: "item",
                    viewport: viewport,
                    was: 7.0,
                    virtualRow: row,
                    hold: header.map { ScrollKeepHold(path: $0, inset: 1.0) }
                ))
            case .fold:
                keeps.removeAll { $0.viewport == "a" }
                keeps.append(ScrollKeep(path: "below", viewport: "a", was: 7.0, virtualRow: nil, hold: nil))
            case .foldOpen(let viewport, let mounted, let end):
                let nodes = ["root", mounted ?? "absent"]
                keeps.removeAll { k in
                    guard k.viewport == viewport else { return false }
                    guard let idx = nodes.firstIndex(of: k.path) else { return false }
                    return idx < end
                }
            case .place(let viewport, let first, let to, let atEnd):
                if first {
                    reveals.removeAll { $0.viewport == viewport }
                    reveals.append(ScrollRevealTarget(
                        scope: "scope",
                        key: "mark",
                        viewport: viewport,
                        center: viewport == "a",
                        atEnd: atEnd
                    ))
                } else if let idx = reveals.firstIndex(where: { $0.viewport == viewport }) {
                    reveals[idx].atEnd = reveals[idx].atEnd || atEnd
                }
                if abs(to - 5.0) < 0.5 {
                    return first ? .rest : nil
                }
                return .move(to)
            case .tail:
                for i in reveals.indices where reveals[i].viewport == "a" && reveals[i].atEnd {
                    reveals[i].scope = nil
                    reveals[i].key = "new"
                }
            case .endGives(let header, let on):
                var drop: [Int] = []
                for (i, k) in keeps.enumerated() {
                    if let h = k.hold, h.path == header && k.viewport == on {
                        drop.append(i)
                    }
                }
                for i in drop.reversed() {
                    keeps.remove(at: i)
                }
            case .endClamp(let scene):
                let nodes = [scene.mounted ?? "absent", "viewport"]
                let drawn: [Float] = [scene.top, 0.0]
                let oldKeeps = keeps
                keeps = oldKeeps.filter { k in
                    guard let i = nodes.firstIndex(of: k.path) else { return true }
                    guard scene.viewport else { return false }
                    return !(scene.pinned && drawn[i] - drawn[1] > k.was + 0.5)
                }
            case .frame(let glide, let moving, let mounted):
                if keeps.isEmpty && reveals.isEmpty { return nil }
                keeps.removeAll { $0.viewport != moving }
                reveals.removeAll { !($0.viewport == glide || ($0.viewport == moving && mounted)) }
            case .inputScroll:
                keeps.removeAll()
                reveals.removeAll()
            case .destination:
                reveals.removeAll()
            }
            return nil
        }
    }

    private func driveRequests(_ requests: inout ScrollRequestsState, _ input: RequestInput) -> ScrollRequestEffect? {
        func anchor(_ v: String, _ p: String, _ header: String?) -> ScrollKeep {
            ScrollKeep(
                path: p,
                viewport: v,
                was: 7.0,
                virtualRow: nil,
                hold: header.map { ScrollKeepHold(path: $0, inset: 1.0) }
            )
        }
        switch input {
        case .captureKey(let viewport, let virtualized, let header):
            var k = anchor(viewport, "item", header)
            if virtualized {
                k.virtualRow = ("list", "row", 3.0)
            }
            requests.arriveCapture(k)
            return nil
        case .fold:
            requests.arriveFoldAnchor(anchor("a", "below", nil))
            return nil
        case .foldOpen(let viewport, let mounted, let end):
            requests.stepFoldOpens(viewport: viewport, end: end) { path in
                path == mounted ? 1 : nil
            }
            return nil
        case .place(let viewport, let first, let to, let atEnd):
            return requests.stepPlace(
                first: first,
                scope: "scope",
                key: "mark",
                viewport: viewport,
                center: viewport == "a",
                atEnd: atEnd,
                from: 5.0,
                to: to
            )
        case .tail:
            requests.stepNewTail(viewport: "a", key: "new")
            return nil
        case .endGives(let header, let pinned):
            requests.stepEndTakesOver(givingHeaders: [header]) { $0 == pinned }
            return nil
        case .endClamp(let scene):
            requests.stepEndClamps { k in
                if scene.mounted != k.path { return .unmounted }
                if !scene.viewport { return .loose }
                if !scene.pinned { return .free }
                return .pinned(scene.top)
            }
            return nil
        case .frame(let glide, let moving, let mounted):
            requests.stepFinish(
                gliding: { $0 == glide },
                animating: { $0 == moving },
                mounted: { _ in mounted }
            )
            return nil
        case .inputScroll:
            requests.stepCancel()
            return nil
        case .destination:
            requests.stepDestination()
            return nil
        }
    }

    private func walkRequests(
        _ inputs: [RequestInput],
        _ old: OldRequestsState,
        _ real: ScrollRequestsState,
        _ sequence: inout [RequestInput]
    ) {
        if sequence.count == 5 { return }
        for input in inputs {
            sequence.append(input)
            var nextOld = old
            var nextReal = real
            let realEff = driveRequests(&nextReal, input)
            let oldEff = nextOld.apply(input)
            if realEff != oldEff || nextReal.keeps != nextOld.keeps || nextReal.reveals != nextOld.reveals {
                #expect(realEff == oldEff, "\(sequence)")
                #expect(nextReal.keeps == nextOld.keeps, "\(sequence)")
                #expect(nextReal.reveals == nextOld.reveals, "\(sequence)")
                sequence.removeLast()
                return
            }
            walkRequests(inputs, nextOld, nextReal, &sequence)
            sequence.removeLast()
        }
    }

    @Test("requests: every_request_sequence_matches_the_separate_keep_and_reveal_lists")
    func requestsEveryRequestSequenceMatchesTheSeparateKeepAndRevealLists() {
        let heldA = RequestInput.captureKey(viewport: "a", virtualized: false, header: "header")
        let pinnedPast = RequestScene(mounted: "below", viewport: true, pinned: true, top: 7.75)
        let inputs: [RequestInput] = [
            heldA,
            .captureKey(viewport: "b", virtualized: true, header: "header"),
            .fold,
            .place(viewport: "a", first: true, to: 4.5, atEnd: false),
            .place(viewport: "b", first: true, to: 5.25, atEnd: true),
            .place(viewport: "a", first: false, to: 5.0, atEnd: true),
            .tail,
            .endGives(header: "header", pinned: "a"),
            .endClamp(pinnedPast),
            .frame(glide: "b", moving: "", mounted: false),
            .frame(glide: "", moving: "a", mounted: false),
            .frame(glide: "", moving: "a", mounted: true),
            .frame(glide: "a", moving: "b", mounted: true),
            .inputScroll,
            .destination,
        ]
        var seq: [RequestInput] = []
        walkRequests(inputs, OldRequestsState(), ScrollRequestsState(), &seq)
    }

    @Test("requests: every_keep_release_matches_the_old_conditions")
    func requestsEveryKeepReleaseMatchesTheOldConditions() {
        let heldA = RequestInput.captureKey(viewport: "a", virtualized: false, header: "header")
        let pinnedPast = RequestScene(mounted: "below", viewport: true, pinned: true, top: 7.75)
        let inputs: [RequestInput] = [
            heldA,
            .captureKey(viewport: "a", virtualized: false, header: nil),
            .captureKey(viewport: "b", virtualized: false, header: "header"),
            .fold,
            .place(viewport: "a", first: true, to: 4.5, atEnd: false),
            .endGives(header: "header", pinned: "a"),
            .endGives(header: "header", pinned: ""),
            .endGives(header: "other", pinned: "a"),
            .endClamp(RequestScene(mounted: nil, viewport: true, pinned: true, top: 9.0)),
            .endClamp(RequestScene(mounted: "item", viewport: false, pinned: false, top: 7.0)),
            .endClamp(RequestScene(mounted: "item", viewport: true, pinned: false, top: 9.0)),
            .endClamp(RequestScene(mounted: "below", viewport: true, pinned: true, top: 7.5)),
            .endClamp(pinnedPast),
            .foldOpen(viewport: "a", mounted: "item", end: 2),
            .foldOpen(viewport: "a", mounted: "item", end: 1),
            .foldOpen(viewport: "a", mounted: nil, end: 2),
            .foldOpen(viewport: "b", mounted: "item", end: 2),
        ]
        var seq: [RequestInput] = []
        walkRequests(inputs, OldRequestsState(), ScrollRequestsState(), &seq)
    }

    // MARK: - 9. ScrollEdgeMath (`edge.rs`, 2 unit tests)

    @Test("edge: partial_ramp_starts_at_one_minus_strength_and_ends_at_the_full_width")
    func edgePartialRampStartsAtOneMinusStrengthAndEndsAtTheFullWidth() {
        func smooth(_ x: Float) -> Float {
            let c = min(max(x, 0.0), 1.0)
            return c * c * (3.0 - 2.0 * c)
        }
        #expect(ScrollEdgeMath.partial(width: 24.0, strength: 0.0) == (0.0, 0.0), "nothing hidden: a hard edge")
        #expect(ScrollEdgeMath.partial(width: 24.0, strength: 1.0) == (24.0, 0.0), "fully hidden: the plain ramp")
        for s: Float in [0.1, 0.25, 0.5, 0.75, 0.9] {
            let (w, o) = ScrollEdgeMath.partial(width: 24.0, strength: s)
            #expect(abs(smooth(o) - (1.0 - s)) < 1e-4, "edge alpha \(smooth(o)) at strength \(s)")
            #expect(abs((1.0 - o) * w - 24.0) < 1e-3, "full alpha 24 in at strength \(s)")
        }
    }

    @Test("edge: reveal_leaves_the_margin_unless_the_row_cannot_fit_it")
    func edgeRevealLeavesTheMarginUnlessTheRowCannotFitIt() {
        #expect(ScrollEdgeMath.reveal(offset: 100.0, top: 300.0, height: 20.0, viewport: 200.0, margin: 0.0) == 120.0, "flush below")
        #expect(ScrollEdgeMath.reveal(offset: 100.0, top: 300.0, height: 20.0, viewport: 200.0, margin: 24.0) == 144.0, "clear of a 24pt fade below")
        #expect(ScrollEdgeMath.reveal(offset: 100.0, top: 90.0, height: 20.0, viewport: 200.0, margin: 24.0) == 66.0, "and above")
        #expect(ScrollEdgeMath.reveal(offset: 100.0, top: 150.0, height: 20.0, viewport: 200.0, margin: 24.0) == 100.0, "already clear: no move")
        #expect(ScrollEdgeMath.reveal(offset: 100.0, top: 300.0, height: 180.0, viewport: 200.0, margin: 24.0) == 290.0, "a tall row splits what space is left")
        #expect(ScrollEdgeMath.reveal(offset: 100.0, top: 300.0, height: 500.0, viewport: 200.0, margin: 24.0) == 600.0, "a row taller than the viewport, below: its end")
        #expect(ScrollEdgeMath.reveal(offset: 600.0, top: 300.0, height: 500.0, viewport: 200.0, margin: 24.0) == 600.0, "and placing it again leaves it there")
        #expect(ScrollEdgeMath.reveal(offset: 400.0, top: 300.0, height: 500.0, viewport: 200.0, margin: 24.0) == 400.0, "a row filling the viewport: no move")
        #expect(ScrollEdgeMath.reveal(offset: 700.0, top: 300.0, height: 500.0, viewport: 200.0, margin: 24.0) == 300.0, "its end in view: its start")
    }
}
