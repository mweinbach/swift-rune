import Foundation
import Testing
@testable import Rune
@testable import RuneMotion
@testable import RuneRef

/// Ports `crates/rune/src/runtime/hover_tests.rs` (upstream `anomalyco/rune` `dev`): hover
/// trajectories through scroll and reversal, pose dirtiness for unchanged targets, inherited
/// hover curves, `hover_alone`, and the `HoverHold` transition table (`runtime/input/hover.rs`).
@Suite("Hover runtime parity (hover_tests.rs)", .serialized)
struct HoverRuntimeParityTests {
    struct HoverState {
        var custom: Bool
        var growth: Bool
        var rows: Int
    }

    /// `hover_tests.rs:6` `view`.
    static func view(_ s: HoverState, _ cx: inout Cx<HoverState>) -> El<HoverState> {
        let rows: [El<HoverState>] = (0..<s.rows).map { i in
            let row = el().key("row-\(i)").wFull().h(30.0)
                .hover(Color.white).onClick { (_: inout HoverState) in }
            let group = col().key("group-\(i)").wFull().hoverGroup()
                .child(row)
                .child(el().key("action").size(10.0, 10.0).bg(Color.white).groupOpacity(0.0, 1.0))
            if s.custom {
                // Explicit animations take the original, unconditional update path.
                return group.hoverMotionWithin(.instant, Anim<Float>(curve: .tween(duration: 0.1, easing: .easeOut)))
            }
            return group
        }
        var stack = col().key("rows").wFull().children(rows)
        if s.growth { stack = stack.growth(GrowthSpec()) }
        return col().wFull().hFull().child(
            col().key("scroll").wFull().hFull().scroll(ScrollSpec(stickBottom: false))
                .child(stack)
        )
    }

    static func make(custom: Bool, growth: Bool, rows: Int, size: Vec2, scale: Float) -> Runtime<HoverState> {
        Runtime<HoverState>(
            state: HoverState(custom: custom, growth: growth, rows: rows),
            viewport: size,
            pixelScale: scale,
            systemDark: true,
            view: view
        )
    }

    /// `hover_tests.rs:27` `default_hover_matches_explicit_trajectories_through_scroll_and_reversal`.
    @Test("default hover matches explicit trajectories through scroll and reversal")
    func defaultHoverMatchesExplicitTrajectoriesThroughScrollAndReversal() {
        for (reduced, growth) in [(false, false), (true, false), (false, true), (true, true)] {
            let fast = Self.make(custom: false, growth: growth, rows: 30, size: Vec2(240, 150), scale: 2.0)
            let reference = Self.make(custom: true, growth: growth, rows: 30, size: Vec2(240, 150), scale: 2.0)
            var t = 0.0
            for rt in [fast, reference] {
                rt.setSystemReducedMotion(reduced)
                _ = rt.frame(at: t)
            }
            let p = Vec2(60, 65)
            for frame in 0..<120 {
                t += 1.0 / 120.0
                var scenes: [RefScene] = []
                for rt in [fast, reference] {
                    if growth && frame % 12 == 0 { rt.update(at: t) { s, _ in s.rows += 1 } }
                    if frame == 0 { rt.pointerMove(to: p, at: t) }
                    if frame < 60 { rt.wheel(WheelEvent(dx: 0, dy: frame < 30 ? -7.0 : 7.0), at: p, now: t) }
                    if frame == 15 { rt.pointerDown(at: p, at: t) }
                    if frame == 18 { rt.pointerUp(at: p, at: t) }
                    if frame == 65 { rt.pointerLeave(at: t) }
                    if frame == 67 { rt.pointerMove(to: p, at: t) }
                    if frame == 90 { rt.pointerLeave(at: t) }
                    scenes.append(rt.frame(at: t))
                }
                #expect(scenes[0].primitives == scenes[1].primitives,
                        "same painted hover at frame \(frame), reduced=\(reduced), growth=\(growth)")
            }
        }
    }

    /// `hover_tests.rs:55` `unchanged_default_hover_does_not_dirty_scene_poses`.
    @Test("unchanged default hover does not dirty scene poses")
    func unchangedDefaultHoverDoesNotDirtyScenePoses() {
        for custom in [false, true] {
            let rt = Self.make(custom: custom, growth: false, rows: 30, size: Vec2(240, 150), scale: 1.0)
            _ = rt.frame(at: 0.0)
            // Drain any requests made by the initial paint's interaction update.
            rt.liveStore.tick()
            rt.syncHoverTracks(at: rt.cxSettings.scaledTime(at: 0.0), cut: false, held: false)
            rt.liveStore.tick()
            // Hover, press and press-scale tracks all live in `liveStore`; any track the pass
            // touched (of any prop) counts, as `scene.frame().changed` does upstream.
            let dirtied = !rt.liveStore.touchedTracks().isEmpty
            #expect(dirtied == custom, "only explicit animations may dirty poses for unchanged targets")
        }
    }

    /// `hover_tests.rs:68` `inherited_hover_curves_leave_descendants_visuals_shared`.
    @Test("inherited hover curves leave descendants' visuals shared")
    func inheritedHoverCurvesLeaveDescendantsVisualsShared() {
        let rt = Self.make(custom: true, growth: false, rows: 3, size: Vec2(240, 150), scale: 1.0)
        _ = rt.frame(at: 0.0)
        rt.update(at: 1.0 / 120.0) { s, _ in s.rows += 1 }
        _ = rt.frame(at: 1.0 / 120.0)
        let rows = rt.flatNodes.filter { ($0.key ?? "").hasPrefix("row-") }
        #expect(rows.count == 4)
        for n in rows {
            #expect(rt.hoverMotion(of: n) != nil, "\(n.path) goes by its group's curves")
            // Upstream `n.vis.cold.is_empty()`: inherited curves stay with the group, not copied
            // into the node's own visuals. Swift resolves inheritance into the runtime's side
            // tables (`hoverCurvesById`, `inheritedHoverCurvesByPath`); writing them onto the
            // row's `El` instead would materialize its cold box (`El.hoverMotionSpec` lives
            // there), so the row's own specs must stay empty while the side tables carry the
            // group's pair.
            #expect(n.el.hoverMotionSpec == nil && n.el.hoverWithinSpec == nil, "\(n.path) keeps no cold visuals of its own")
            #expect(rt.inheritedHoverCurvesByPath[n.path] != nil, "\(n.path)'s curves come from the inherited side table")
            guard let parent = n.parentIndex, let groupSpec = rt.flatNodes[parent].el.hoverWithinSpec,
                  let curves = rt.hoverMotion(of: n) else {
                Issue.record("\(n.path) sits in a group with hoverMotionWithin")
                continue
            }
            #expect(curves.enter.curve == groupSpec.enter.curve && curves.exit.curve == groupSpec.exit.curve,
                    "\(n.path) shares its group's pair")
        }
    }

    /// `hover_tests.rs:85` `a_hover_alone_child_keeps_the_row_around_it_unlit`: a face in a
    /// hoverable row: on the face only the face shows hover, and the row's wash and its group
    /// styles rest; back on the row they light again. The pointer moving between them only paints.
    @Test("a hover_alone child keeps the row around it unlit")
    func aHoverAloneChildKeepsTheRowAroundItUnlit() {
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(240, 100), pixelScale: 1.0, systemDark: true) { _, _ in
            let face: El<S> = el().key("face").size(20.0, 20.0).hover(Color.white).hoverAlone()
            let r: El<S> = row().key("row").size(200.0, 30.0).hover(Color.white)
                .child(el().key("label").size(100.0, 30.0))
                .child(el().key("dot").size(4.0, 4.0).bg(Color.white).groupOpacity(0.0, 1.0))
                .child(face)
            return col().wFull().hFull().child(r)
        }
        var t = 0.0
        _ = rt.frame(at: t)
        func lit(_ key: String) -> Float {
            guard let n = rt.flatNodes.first(where: { $0.key == key }) else { return -1 }
            return rt.liveStore.target(Runtime<S>.hoverTrackId(n.nodeId), Runtime<S>.hoverProp) ?? 0.0
        }
        let commits = rt.stats.commits

        t += 1.0 / 120.0
        rt.pointerMove(to: Vec2(50, 15), at: t)
        _ = rt.frame(at: t)
        #expect(lit("row") == 1.0 && lit("face") == 0.0, "on the label the row lights")

        t += 1.0 / 120.0
        rt.pointerMove(to: Vec2(114, 10), at: t)
        _ = rt.frame(at: t)
        #expect(lit("row") == 0.0 && lit("face") == 1.0, "on the face only the face lights")

        t += 1.0 / 120.0
        rt.pointerMove(to: Vec2(50, 15), at: t)
        _ = rt.frame(at: t)
        #expect(lit("row") == 1.0 && lit("face") == 0.0, "back on the label the row lights again")
        #expect(rt.stats.commits == commits, "hover between them never commits")
    }

    /// The rule behind `hover_tests.rs:85` (`hover.rs::hover_flip`): without `hoverAlone`, every
    /// hover element whose drawn rect holds the pointer lights, so on the face both the row and
    /// the face show hover. This is what makes the `hoverAlone` test above meaningful.
    @Test("without hover_alone the row around a hovered child stays lit")
    func withoutHoverAloneTheRowAroundAHoveredChildStaysLit() {
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(240, 100), pixelScale: 1.0, systemDark: true) { _, _ in
            let face: El<S> = el().key("face").size(20.0, 20.0).hover(Color.white)
            let r: El<S> = row().key("row").size(200.0, 30.0).hover(Color.white)
                .child(el().key("label").size(100.0, 30.0))
                .child(el().key("dot").size(4.0, 4.0).bg(Color.white).groupOpacity(0.0, 1.0))
                .child(face)
            return col().wFull().hFull().child(r)
        }
        var t = 0.0
        _ = rt.frame(at: t)
        func lit(_ key: String) -> Float {
            guard let n = rt.flatNodes.first(where: { $0.key == key }) else { return -1 }
            return rt.liveStore.target(Runtime<S>.hoverTrackId(n.nodeId), Runtime<S>.hoverProp) ?? 0.0
        }
        t += 1.0 / 120.0
        rt.pointerMove(to: Vec2(114, 10), at: t)
        _ = rt.frame(at: t)
        #expect(lit("row") == 1.0 && lit("face") == 1.0, "nothing shadows the row: both light")
    }

    /// `hover_tests.rs:116` `a_released_hold_holds_nothing_until_layout_settles`.
    @Test("a released hold holds nothing until layout settles")
    func aReleasedHoldHoldsNothingUntilLayoutSettles() {
        var h = HoverHold()
        h.setHeld(true)
        #expect(h.held)
        h.release(moving: true)
        #expect(h.released && !h.held, "the hand let go of the hold while layout moves")
        h.setHeld(true)
        #expect(h.released && !h.held, "released, a pass can't hold hover")
        h.release(moving: true)
        #expect(h.released, "a second move keeps it released")
        h.settled()
        h.setHeld(true)
        #expect(h.held && !h.released)
        h.release(moving: false)
        #expect(!h.held && !h.released, "with layout still, a move just ends the hold")
    }

    // MARK: - `scroll_carries`: an app's instant scroll (`scroll/nudge_tests.rs`, `tests/scroll_hover.rs`)

    /// origin/dev's countdown, transcribed from `runtime/scroll/offset.rs`: a jump armed two
    /// frames, and each frame took one off and reported whether one still held (`nudge_tests.rs::Dev`).
    private struct DevNudge {
        var nudged: UInt8 = 0
        mutating func arm() { nudged = 2 }
        mutating func frame() { nudged = nudged > 0 ? nudged - 1 : 0 }
        var held: Bool { nudged > 0 }
    }

    private enum NudgeAct: CaseIterable { case arm, frame }

    /// One 60 Hz frame: the rate dev's two-frame countdown and this hold are the same at.
    private static let frame60: Double = 1.0 / 60.0

    /// `nudge_tests.rs:62` `the_hold_matches_the_countdown_at_sixty_hertz`.
    @Test("nudge: the hold matches the countdown at sixty hertz")
    func nudgeHoldMatchesTheCountdownAtSixtyHertz() {
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
                    now += Self.frame60
                    nudge.tick(now: now)
                    dev.frame()
                }
                #expect(nudge.holdAt(now: now) == dev.held, "\(acts): held after event \(at), at \(now)")
            }
        }
        func enumerate(_ acts: inout [NudgeAct], _ len: Int) {
            if acts.count == len { walk(acts); return }
            for act in NudgeAct.allCases {
                acts.append(act)
                enumerate(&acts, len)
                acts.removeLast()
            }
        }
        var acts: [NudgeAct] = []
        for len in 0...6 {
            acts.removeAll()
            enumerate(&acts, len)
        }
    }

    /// `nudge_tests.rs:85` `the_hold_covers_the_landing_frame_and_the_next`.
    @Test("nudge: the hold covers the landing frame and the next")
    func nudgeHoldCoversTheLandingFrameAndTheNext() {
        var nudge = ScrollNudge()
        let landed = 4.5
        nudge.arm(now: landed)
        #expect(nudge.holdAt(now: landed), "the frame it landed holds")
        nudge.tick(now: landed + Self.frame60)
        #expect(nudge.holdAt(now: landed + Self.frame60), "so does the next")
        nudge.tick(now: landed + 2.0 * Self.frame60)
        #expect(!nudge.holdAt(now: landed + 2.0 * Self.frame60), "and it is over on the third")
        #expect(nudge.state == .free)
        nudge.tick(now: landed + 3.0 * Self.frame60)
        #expect(!nudge.holdAt(now: landed + 3.0 * Self.frame60), "a spent hold stays free")
    }

    /// `nudge_tests.rs:103` `the_hold_ends_a_fixed_time_after_the_land`.
    @Test("nudge: the hold ends a fixed time after the land")
    func nudgeHoldEndsAFixedTimeAfterTheLand() {
        for rate in [30.0, 120.0] {
            var nudge = ScrollNudge()
            var now = 0.0
            nudge.arm(now: now)
            var freed: Double? = nil
            for _ in 0..<10 {
                now += 1.0 / rate
                nudge.tick(now: now)
                if !nudge.holdAt(now: now) { freed = now; break }
            }
            guard let freed else { Issue.record("\(rate) fps: the hold ends"); continue }
            #expect(freed >= ScrollNudge.nudgeHold - 1e-9 && freed < ScrollNudge.nudgeHold + 1.0 / rate + 1e-9,
                    "\(rate) fps: held \(freed) seconds")
        }
    }

    /// `nudge_tests.rs:123` `a_due_from_an_earlier_arm_changes_nothing`.
    @Test("nudge: a due from an earlier arm changes nothing")
    func nudgeADueFromAnEarlierArmChangesNothing() {
        var nudge = ScrollNudge()
        var now = 0.0
        nudge.arm(now: now)
        guard case .held(let first, let firstDue) = nudge.state else { Issue.record("armed"); return }
        now += Self.frame60
        nudge.arm(now: now)
        guard case .held(let second, let due) = nudge.state else { Issue.record("armed"); return }
        #expect(second != first)
        #expect(due == now + ScrollNudge.nudgeHold)
        ScrollNudge.step(seq: &nudge.seq, state: &nudge.state, event: .due(attempt: first, now: firstDue + 1.0))
        #expect(nudge.holdAt(now: now), "the newer arm still holds")
        #expect(nudge.state == .held(attempt: second, due: due))
    }

    /// Forty 20-point rows in a 200-point viewport, each revealing an action on hover
    /// (`tests/scroll_hover.rs:5` `view`).
    static func scrollHoverView(_: Int, _: inout Cx<Int>) -> El<Int> {
        let rows: El<Int> = col().key("rows").wFull().children((0..<40).map { k in
            row().key("r\(k)").wFull().h(20.0).hoverGroup()
                .child(el().key("a\(k)").size(10.0, 10.0).bg(Color.white).groupOpacity(0.0, 1.0))
        })
        return col().size(200.0, 200.0).child(
            col().key("scroll").size(200.0, 200.0).scroll(ScrollSpec(stickBottom: false)).child(rows)
        )
    }

    /// The rows whose action shows at all this frame (`tests/scroll_hover.rs:12` `shown`).
    static func shown(_ rt: Runtime<Int>) -> [String] {
        (0..<40).compactMap { k in
            guard let e = rt.element(byKey: "a\(k)"), e.opacity > 0.0 else { return nil }
            return "a\(k)"
        }
    }

    /// An instant scroll holds hover for the same time whether frames come at 30 or 240 a second
    /// (`tests/scroll_hover.rs:198` `an_instant_scroll_holds_hover_for_a_time_not_a_frame_count`).
    @Test("an instant scroll holds hover for a time, not a frame count")
    func anInstantScrollHoldsHoverForATimeNotAFrameCount() {
        for rate in [30.0, 60.0, 120.0, 240.0] {
            let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true, view: Self.scrollHoverView)
            var t = 0.0
            _ = rt.frame(at: t)
            t += 1.0 / 120.0
            rt.pointerMove(to: Vec2(100, 110), at: t)
            _ = rt.frame(at: t)
            #expect(Self.shown(rt) == ["a5"])
            let start = t
            rt.update(at: t) { _, tx in tx.scrollToInstant("scroll", x: 0.0, y: 400.0) }
            var freed: Double? = nil
            for _ in 0..<60 {
                t += 1.0 / rate
                _ = rt.frame(at: t)
                if rt.scrollNudges.values.allSatisfy({ !$0.holdAt(now: rt.currentTime) }) {
                    freed = t - start
                    break
                }
            }
            guard let held = freed else { Issue.record("\(rate) fps: the hold ends"); continue }
            #expect(held >= ScrollNudge.nudgeHold - 1e-9 && held <= ScrollNudge.nudgeHold + 2.0 / rate + 1e-9,
                    "\(rate) fps: held \(held) seconds")
            #expect(Self.shown(rt) == ["a25"], "\(rate) fps: once the hold is over hover resolves at the pointer")
        }
    }

    /// A runtime hovering row 5 under a still pointer (`tests/scroll_hover.rs:17` `hovering`).
    static func hovering() -> (Runtime<Int>, Double) {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true, view: Self.scrollHoverView)
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 120.0
        rt.pointerMove(to: Vec2(100, 110), at: t)
        _ = rt.frame(at: t)
        #expect(Self.shown(rt) == ["a5"])
        return (rt, t)
    }

    /// A held nudge draws nothing while it waits: the frame the jump lands in holds hover and asks
    /// for no next frame, and the wake it armed brings the one frame that resolves hover
    /// (`tests/scroll_hover.rs:216` `a_held_nudge_draws_no_frames_until_its_wake`).
    @Test("a held nudge draws no frames until its wake")
    func aHeldNudgeDrawsNoFramesUntilItsWake() {
        let (rt, start) = Self.hovering()
        var t = start
        rt.update(at: t) { _, tx in tx.scrollToInstant("scroll", x: 0.0, y: 400.0) }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(!rt.isAnimating, "the landing frame asks for no next frame")
        #expect(Self.shown(rt) == ["a5"], "and hover holds under it")
        guard let due = rt.nextWakeDeadline(after: rt.currentTime) else {
            Issue.record("the hold wakes a frame")
            return
        }
        #expect(abs(due - rt.currentTime - ScrollNudge.nudgeHold) < 1e-6, "due one hold after the land: \(due) at \(rt.currentTime)")
        #expect(rt.logicalWakeDeadline() == due, "the logical wake deadline is the hold's due")
        _ = rt.frame(at: t)
        #expect(!rt.isAnimating, "a frame while it waits still asks for none")
        #expect(Self.shown(rt) == ["a5"])
        #expect(rt.nextWakeDeadline(after: rt.currentTime) == due, "and the wake still stands")
        _ = rt.frame(at: due)
        #expect(Self.shown(rt) == ["a25"], "the wake's frame resolves hover once, at the pointer")
        #expect(!rt.hoverHold.held)
    }

    /// A second instant scroll before the hold's due moves the wake to its own due: nothing is
    /// left holding hover past it waiting for some other frame to come
    /// (`tests/scroll_hover.rs:236` `a_scroll_again_before_the_hold_ends_still_wakes_at_its_own_due`).
    @Test("a scroll again before the hold ends still wakes at its own due")
    func aScrollAgainBeforeTheHoldEndsStillWakesAtItsOwnDue() {
        let (rt, start) = Self.hovering()
        var t = start
        rt.update(at: t) { _, tx in tx.scrollToInstant("scroll", x: 0.0, y: 200.0) }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        rt.update(at: t) { _, tx in tx.scrollToInstant("scroll", x: 0.0, y: 400.0) }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(Self.shown(rt) == ["a5"], "both holds keep hover where it was")
        guard let due = rt.nextWakeDeadline(after: rt.currentTime) else {
            Issue.record("the second hold wakes a frame")
            return
        }
        #expect(abs(due - rt.currentTime - ScrollNudge.nudgeHold) < 1e-6,
                "due one hold after the second scroll, not the first: \(due) at \(rt.currentTime)")
        _ = rt.frame(at: due)
        #expect(Self.shown(rt) == ["a25"], "its frame resolves hover once, at the pointer")
    }

    /// Forty 20-point rows, each revealing an action on hover and recording its
    /// `onHoverChange` (`tests/scroll_hover.rs:250` `logged_rows`).
    static func loggedRows(_: [LoggedHover], _: inout Cx<[LoggedHover]>) -> El<[LoggedHover]> {
        let rows: El<[LoggedHover]> = col().key("rows").wFull().children((0..<40).map { k in
            row().key("r\(k)").wFull().h(20.0).hoverGroup()
                .onHoverChange { s, inside, _ in s.append(LoggedHover(row: k, inside: inside)) }
                .child(el().key("a\(k)").size(10.0, 10.0).bg(Color.white).groupOpacity(0.0, 1.0))
        })
        return col().size(200.0, 200.0).child(
            col().key("scroll").size(200.0, 200.0).scroll(ScrollSpec(stickBottom: false)).child(rows)
        )
    }

    struct LoggedHover: Equatable, CustomStringConvertible {
        var row: Int
        var inside: Bool
        var description: String { "(\(row), \(inside))" }
    }

    /// `tests/scroll_hover.rs:258` `an_app_stepping_its_own_glide_holds_a_still_pointers_hover_until_it_stops`.
    @Test("an app stepping its own glide holds a still pointer's hover until it stops")
    func anAppSteppingItsOwnGlideHoldsAStillPointersHoverUntilItStops() {
        let rt = Runtime<[LoggedHover]>(state: [], viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true, view: Self.loggedRows)
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 120.0
        rt.pointerMove(to: Vec2(100, 110), at: t)
        _ = rt.frame(at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(rt.state == [LoggedHover(row: 5, inside: true)])
        // The app glides 400 points itself, an instant scroll each frame.
        var flashes = 0
        for f in 1...100 {
            rt.update(at: t) { _, tx in tx.scrollToInstant("scroll", x: 0.0, y: 4.0 * Float(f)) }
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            let shown: [String] = (0..<40).compactMap { k in
                guard let e = rt.element(byKey: "a\(k)"), e.opacity > 0.0 else { return nil }
                return "a\(k)"
            }
            flashes += shown != ["a5"] ? 1 : 0
        }
        let commits = rt.state.count - 1
        #expect(commits == 0 && flashes == 0, "no hover commits or chrome under the still pointer mid-scroll: \(rt.state)")
        for _ in 0..<30 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        #expect(rt.state == [LoggedHover(row: 5, inside: true), LoggedHover(row: 5, inside: false), LoggedHover(row: 25, inside: true)],
                "once it stops, hover resolves once at the pointer")
        #expect(!rt.hoverHold.held, "and lets go")
    }

    /// While moving layout holds hover, the cursor and tooltip see the held element, not what slid
    /// under the pointer (`hover.rs::held_hover`, `pointer.rs::cursor`).
    @Test("held hover keeps the cursor on the element the pointer was over")
    func heldHoverKeepsTheCursor() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true) { _, _ in
            let rows: El<Int> = col().key("rows").wFull().children((0..<40).map { k in
                row().key("r\(k)").wFull().h(20.0).hover(Color.white).cursor(k == 5 ? .pointer : .text)
            })
            return col().size(200.0, 200.0).child(
                col().key("scroll").size(200.0, 200.0).scroll(ScrollSpec(stickBottom: false)).child(rows)
            )
        }
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 120.0
        rt.pointerMove(to: Vec2(100, 110), at: t)
        _ = rt.frame(at: t)
        #expect(rt.hoveredKey == "r5")
        #expect(rt.heldHover() == nil, "nothing holds hover at rest")
        #expect(rt.currentCursor() == .pointer)
        rt.update(at: t) { _, tx in tx.scrollToInstant("scroll", x: 0.0, y: 400.0) }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(rt.hoverHold.held)
        #expect(rt.heldHover().flatMap { $0 }.map { rt.flatNodes[$0].key } == "r5", "the held element is what the pointer was over")
        #expect(rt.currentCursor() == .pointer, "the cursor stays with the held row, not r25 under the pointer")
        t += 0.05
        _ = rt.frame(at: t)
        #expect(rt.heldHover() == nil)
        #expect(rt.hoveredKey == "r25")
        #expect(rt.currentCursor() == .text)
    }
}

