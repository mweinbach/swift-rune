import Foundation
import Testing
@testable import Rune
@testable import RuneMotion

/// Ports `crates/rune/src/runtime/tests/scroll_hover.rs` (upstream `anomalyco/rune` `dev`): hover
/// under a still pointer while a glide, a hand, a press or a modal moves or freezes the rows
/// under it (`runtime/input/hover.rs::HoverHold`, `scroll_carries`). The nudge tests
/// (`:197`, `:215`, `:235`, `:257`) live in `HoverRuntimeParityTests`.
@Suite("Scroll hover parity (tests/scroll_hover.rs)", .serialized)
struct ScrollHoverParityTests {
    static let dt: Double = 1.0 / 120.0

    /// Forty 20-point rows in a 200-point viewport, each revealing an action on hover
    /// (`scroll_hover.rs:5` `view`).
    static func view(_: Int, _: inout Cx<Int>) -> El<Int> {
        let rows: El<Int> = col().key("rows").wFull().children((0..<40).map { k in
            row().key("r\(k)").wFull().h(20.0).hoverGroup()
                .child(el().key("a\(k)").size(10.0, 10.0).bg(Color.white).groupOpacity(0.0, 1.0))
        })
        return col().size(200.0, 200.0).child(
            col().key("scroll").size(200.0, 200.0).scroll(ScrollSpec(stickBottom: false)).child(rows)
        )
    }

    /// The rows whose action shows at all this frame (`scroll_hover.rs:12` `shown`).
    static func shown<S>(_ rt: Runtime<S>) -> [String] {
        rt.elements().compactMap { e in
            guard let k = e.key, k.hasPrefix("a"), e.opacity > 0.0 else { return nil }
            return k
        }
    }

    /// A runtime hovering row 5 under a still pointer, and its clock (`scroll_hover.rs:17` `hovering`).
    static func hovering() -> (Runtime<Int>, Double) {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true, view: Self.view)
        var t = 0.0
        _ = rt.frame(at: t)
        rt.pointerMove(to: Vec2(100.0, 110.0), at: t)
        t += dt
        _ = rt.frame(at: t)
        #expect(Self.shown(rt) == ["a5"])
        return (rt, t)
    }

    @Test("a pinned viewport carries hover until its bottom slack finishes stepping")
    func bottomSlackCarriesHover() throws {
        let (rt, t) = Self.hovering()
        let path = try #require(rt.flatNodes.first(where: { $0.key == "scroll" })?.path)
        var slack = ScrollSlack.landed(window: (200, 200))
        slack.track.h = 12
        rt.slice2State.scrollSlacks[path] = slack
        #expect(rt.scrollCarries(path: path, at: t))
        #expect(rt.anyScrollCarries(at: t))
        #expect(!rt.scrollCarries(path: "other", at: t))

        slack.track.h = 0
        slack.stepped = true
        rt.slice2State.scrollSlacks[path] = slack
        #expect(rt.scrollCarries(path: path, at: t))
        slack.stepped = false
        rt.slice2State.scrollSlacks[path] = slack
        #expect(!rt.anyScrollCarries(at: t))
    }

    /// No viewport glides (`rt.scrolls.values().all(|s| s.glide().is_none())`).
    static func noGlide<S>(_ rt: Runtime<S>) -> Bool { rt.scrollGlidingPaths.isEmpty }

    /// The offset of the viewport keyed `key` (`rt.scrolls.values().next().unwrap().offset`).
    static func offset<S>(_ rt: Runtime<S>, _ key: String = "scroll") -> Float {
        guard let n = rt.flatNodes.first(where: { $0.key == key }) else { return .nan }
        return rt.scrollOffsets[n.path]?.y ?? 0.0
    }

    /// `scroll_hover.rs:27` `a_glide_holds_a_still_pointers_hover_until_it_stops`.
    @Test("a glide holds a still pointer's hover until it stops")
    func aGlideHoldsAStillPointersHoverUntilItStops() {
        var (rt, t) = Self.hovering()
        rt.update(at: t) { _, tx in tx.scrollTo("scroll", x: 0.0, y: 400.0) }
        var frames = 0
        for f in 0..<600 {
            t += Self.dt
            _ = rt.frame(at: t)
            if Self.noGlide(rt) { break }
            frames += 1
            #expect(Self.shown(rt) == ["a5"], "frame \(f): no row passing under the pointer takes its hover")
        }
        #expect(frames > 5, "it glided")
        for _ in 0..<30 { t += Self.dt; _ = rt.frame(at: t) }
        #expect(Self.shown(rt) == ["a25"], "once it stops, the row under the pointer has it")
    }

    /// `scroll_hover.rs:43` `moving_the_pointer_during_a_glide_hovers_again`.
    @Test("moving the pointer during a glide hovers again")
    func movingThePointerDuringAGlideHoversAgain() {
        var (rt, t) = Self.hovering()
        rt.update(at: t) { _, tx in tx.scrollToBottom("scroll") }
        for _ in 0..<4 { t += Self.dt; _ = rt.frame(at: t) }
        #expect(Self.shown(rt) == ["a5"])
        rt.pointerMove(to: Vec2(100.0, 111.0), at: t)
        t += Self.dt
        _ = rt.frame(at: t)
        t += Self.dt
        _ = rt.frame(at: t)
        // Hover paints a frame behind the moving rows, as with a wheel scroll.
        let under = Int((Self.offset(rt) + 111.0) / 20.0)
        let rows: [Int] = Self.shown(rt).compactMap { Int($0.dropFirst()) }
        #expect(rows.contains { k in k != 5 && k + 2 >= under && k <= under },
                "the moved pointer hovers near row \(under): \(rows)")
    }

    /// `scroll_hover.rs:59` `a_wheel_scroll_still_hovers_each_row_it_brings_under_the_pointer`.
    @Test("a wheel scroll still hovers each row it brings under the pointer")
    func aWheelScrollStillHoversEachRowItBringsUnderThePointer() {
        var (rt, t) = Self.hovering()
        rt.wheel(WheelEvent(dx: 0.0, dy: -40.0), at: Vec2(100.0, 110.0), now: t)
        // Hover retargets from the frame's drawn rows and paints on the next.
        t += Self.dt
        _ = rt.frame(at: t)
        t += Self.dt
        _ = rt.frame(at: t)
        let offset = Self.offset(rt)
        #expect(offset > 0.0)
        let under = "a\(Int((offset + 110.0) / 20.0))"
        #expect(Self.shown(rt).contains(under), "\(under): \(Self.shown(rt))")
    }

    /// `scroll_hover.rs:72` `a_hover_a_glide_carried_out_of_view_lets_go_at_once`.
    @Test("a hover a glide carried out of view lets go at once")
    func aHoverAGlideCarriedOutOfViewLetsGoAtOnce() {
        var (rt, t) = Self.hovering()
        guard let r5 = rt.flatNodes.first(where: { $0.key == "r5" }) else {
            Issue.record("r5 is in the tree")
            return
        }
        let track = Runtime<Int>.hoverTrackId(r5.nodeId)
        rt.update(at: t) { _, tx in tx.scrollTo("scroll", x: 0.0, y: 400.0) }
        for f in 0..<600 {
            t += Self.dt
            _ = rt.frame(at: t)
            if rt.liveStore.target(track, Runtime<Int>.hoverProp) == 0.0 {
                #expect(Self.noGlide(rt), "frame \(f): the hold kept r5's hover through the glide")
                #expect(!rt.liveStore.isAnimating(track, Runtime<Int>.hoverProp),
                        "r5, out of view, lands its leave instead of fading it unseen")
                return
            }
        }
        Issue.record("r5 never let go of its hover")
    }

    /// Forty rows, each darkening while pressed and gliding twenty rows on when pressed
    /// (`scroll_hover.rs:88` `pressing`).
    static func pressing(_: Int, _: inout Cx<Int>) -> El<Int> {
        let rows: El<Int> = col().key("rows").wFull().children((0..<40).map { k in
            row().key("r\(k)").wFull().h(20.0)
                .press(Color.white).pressScale(0.9)
                .onClick { (_: inout Int, tx: inout Tx) in tx.scrollTo("scroll", x: 0.0, y: 400.0) }
        })
        return col().size(200.0, 200.0).child(
            col().key("scroll").size(200.0, 200.0).scroll(ScrollSpec(stickBottom: false)).child(rows)
        )
    }

    /// `scroll_hover.rs:95` `a_press_that_starts_a_glide_still_lets_go`.
    @Test("a press that starts a glide still lets go")
    func aPressThatStartsAGlideStillLetsGo() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true, view: Self.pressing)
        var t = 0.0
        _ = rt.frame(at: t)
        rt.pointerMove(to: Vec2(100.0, 110.0), at: t)
        t += Self.dt
        _ = rt.frame(at: t)
        rt.pointerDown(at: Vec2(100.0, 110.0), at: t)
        t += Self.dt
        _ = rt.frame(at: t)
        guard let r5 = rt.flatNodes.first(where: { $0.key == "r5" }) else {
            Issue.record("r5 is in the tree")
            return
        }
        let press = Runtime<Int>.pressTrackId(r5.nodeId)
        #expect(rt.liveStore.target(press, Runtime<Int>.pressProp) == 1.0)
        #expect(rt.scene.store.target(r5.nodeId, Props.PRESS_SCALE) == 0.9)
        rt.pointerUp(at: Vec2(100.0, 110.0), at: t)
        t += Self.dt
        _ = rt.frame(at: t)
        t += Self.dt
        _ = rt.frame(at: t)
        #expect(rt.hoverHold.held, "the press's glide holds hover")
        #expect(rt.liveStore.target(press, Runtime<Int>.pressProp) == 0.0, "the press lets go mid-glide")
        #expect(rt.scene.store.target(r5.nodeId, Props.PRESS_SCALE) == 1.0, "the press scale springs back mid-glide")
    }

    /// `scroll_hover.rs:114` `the_hold_ends_with_its_glide`.
    @Test("the hold ends with its glide")
    func theHoldEndsWithItsGlide() {
        var (rt, t) = Self.hovering()
        rt.update(at: t) { _, tx in tx.scrollTo("scroll", x: 0.0, y: 400.0) }
        var held = false
        for _ in 0..<600 {
            t += Self.dt
            _ = rt.frame(at: t)
            held = held || rt.hoverHold.held
            if Self.noGlide(rt) { break }
        }
        #expect(held, "the glide held hover")
        #expect(!rt.hoverHold.held && !rt.hoverHold.released, "no stale hold is left for a later glide")
    }

    /// Two viewports side by side, and a modal over both while `open` (`scroll_hover.rs:128` `pair`).
    static func pair(_ open: Bool, _: inout Cx<Bool>) -> El<Bool> {
        func side(_ key: String) -> El<Bool> {
            col().key(key).size(100.0, 200.0).scroll(ScrollSpec(stickBottom: false))
                .child(col().wFull().children((0..<40).map { k in
                    row().key("\(key)\(k)").wFull().h(20.0).hoverGroup()
                        .child(el().key("a\(key)\(k)").size(10.0, 10.0).bg(Color.white).groupOpacity(0.0, 1.0))
                }))
        }
        let root: El<Bool> = row().size(200.0, 200.0).child(side("l")).child(side("r"))
        if open {
            return root.child(col().key("sheet").absolute(x: 150.0, y: 150.0).size(40.0, 40.0)
                .modal(clickOutside: true) { (s: inout Bool) in s = false })
        }
        return root
    }

    /// `scroll_hover.rs:136` `gliding_pair`: both viewports glide, until a row other than the
    /// hovered one glides under the pointer and hover holds.
    static func glidingPair() -> (Runtime<Bool>, Double)? {
        let rt = Runtime<Bool>(state: false, viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true, view: Self.pair)
        var t = 0.0
        _ = rt.frame(at: t)
        rt.pointerMove(to: Vec2(50.0, 110.0), at: t)
        t += dt
        _ = rt.frame(at: t)
        rt.update(at: t) { _, tx in
            tx.scrollTo("l", x: 0.0, y: 400.0)
            tx.scrollTo("r", x: 0.0, y: 400.0)
        }
        for _ in 0..<30 {
            t += dt
            _ = rt.frame(at: t)
            if rt.hoverHold.held { return (rt, t) }
        }
        Issue.record("the glides held hover")
        return nil
    }

    /// `scroll_hover.rs:151` `a_hand_scroll_anywhere_lets_go_of_the_hold`.
    @Test("a hand scroll anywhere lets go of the hold")
    func aHandScrollAnywhereLetsGoOfTheHold() {
        guard let pair = Self.glidingPair() else { return }
        let rt = pair.0
        var t = pair.1
        rt.wheel(WheelEvent(dx: 0.0, dy: -10.0), at: Vec2(150.0, 110.0), now: t)
        t += Self.dt
        _ = rt.frame(at: t)
        #expect(!Self.noGlide(rt), "the viewport under the pointer still glides")
        #expect(rt.hoverHold.released && !rt.hoverHold.held,
                "a wheel over the other viewport lets hover follow the pointer again")
    }

    /// `scroll_hover.rs:160` `a_viewport_under_a_modal_holds_no_hover`.
    @Test("a viewport under a modal holds no hover")
    func aViewportUnderAModalHoldsNoHover() {
        guard let pair = Self.glidingPair() else { return }
        let rt = pair.0
        var t = pair.1
        rt.update(at: t) { s, _ in s = true }
        t += Self.dt
        _ = rt.frame(at: t)
        #expect(!Self.noGlide(rt))
        #expect(!rt.hoverHold.held, "a modal makes the gliding viewport inert")
    }

    struct LoggedHover: Equatable, CustomStringConvertible {
        var row: Int
        var inside: Bool
        var description: String { "(\(row), \(inside))" }
    }

    /// Two hundred virtual rows, each recording its `onHoverChange` (`scroll_hover.rs:169` `hover_rows`).
    static func hoverRows(_: [LoggedHover], _: inout Cx<[LoggedHover]>) -> El<[LoggedHover]> {
        let rows: El<[LoggedHover]> = col().key("rows").wFull().growth(GrowthSpec()).virtualize(20.0)
            .children((0..<200).map { k in
                row().key("r\(k)").wFull().h(20.0)
                    .onHoverChange { s, inside, _ in s.append(LoggedHover(row: k, inside: inside)) }
            })
        return col().size(200.0, 200.0).child(
            col().key("scroll").size(200.0, 200.0).scroll(ScrollSpec(stickBottom: false)).child(rows)
        )
    }

    /// `scroll_hover.rs:176` `a_row_leaving_the_tree_under_a_held_glide_hears_the_pointer_leave`.
    @Test("a row leaving the tree under a held glide hears the pointer leave")
    func aRowLeavingTheTreeUnderAHeldGlideHearsThePointerLeave() {
        let rt = Runtime<[LoggedHover]>(state: [], viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true, view: Self.hoverRows)
        var t = 0.0
        _ = rt.frame(at: t)
        rt.pointerMove(to: Vec2(100.0, 110.0), at: t)
        t += Self.dt
        _ = rt.frame(at: t)
        t += Self.dt
        _ = rt.frame(at: t)
        #expect(rt.state == [LoggedHover(row: 5, inside: true)])
        rt.update(at: t) { _, tx in tx.scrollTo("scroll", x: 0.0, y: 3000.0) }
        t += Self.dt
        _ = rt.frame(at: t)
        #expect(rt.hoverHold.held)
        #expect(!rt.flatNodes.indices.contains { rt.flatNodes[$0].key == "r5" && !rt.hoverIsExiting($0) },
                "the glide's cut unmounts the row")
        for _ in 0..<120 {
            t += Self.dt
            _ = rt.frame(at: t)
            if rt.state.contains(LoggedHover(row: 5, inside: false)) { break }
        }
        #expect(rt.state.contains(LoggedHover(row: 5, inside: false)), "the row heard the leave before it was pruned: \(rt.state)")
        #expect(rt.hoverHold.held, "while the glide still holds hover")
    }

    /// What forty rows' hover handlers heard: `onHoverChange` and `onHover` (`scroll_hover.rs:283` `Heard`).
    struct Heard {
        var changes: [LoggedHover] = []
        var enters: [Int] = []
    }

    /// `scroll_hover.rs:288` `heard_rows`.
    static func heardRows(_: Heard, _: inout Cx<Heard>) -> El<Heard> {
        let rows: El<Heard> = col().key("rows").wFull().children((0..<40).map { k in
            row().key("r\(k)").wFull().h(20.0)
                .onHoverChange { s, inside, _ in s.changes.append(LoggedHover(row: k, inside: inside)) }
                // `on_hover` runs when the element becomes the hovered one.
                .onHover { s, entered, _ in if entered { s.enters.append(k) } }
        })
        return col().size(200.0, 200.0).child(
            col().key("scroll").size(200.0, 200.0).scroll(ScrollSpec(stickBottom: false)).child(rows)
        )
    }

    /// `scroll_hover.rs:296` `a_glide_to_an_offset_runs_no_hover_handler_under_a_still_pointer_until_it_lands`.
    @Test("a glide to an offset runs no hover handler under a still pointer until it lands")
    func aGlideToAnOffsetRunsNoHoverHandlerUnderAStillPointerUntilItLands() {
        for spring in [nil, Spring(duration: 0.18, bounce: 0.0)] as [Spring?] {
            let rt = Runtime<Heard>(state: Heard(), viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true, view: Self.heardRows)
            var t = 0.0
            _ = rt.frame(at: t)
            rt.pointerMove(to: Vec2(100.0, 110.0), at: t)
            t += Self.dt
            _ = rt.frame(at: t)
            t += Self.dt
            _ = rt.frame(at: t)
            #expect(rt.state.changes == [LoggedHover(row: 5, inside: true)] && rt.state.enters == [5])
            _ = rt.updateIf(at: t) { _, tx in
                if let spring {
                    tx.scrollToWith("scroll", x: 0.0, y: 400.0, spring: spring)
                } else {
                    tx.scrollTo("scroll", x: 0.0, y: 400.0)
                }
                return false
            }
            let commits = rt.stats.commits
            var frames = 0
            for _ in 0..<600 {
                t += Self.dt
                _ = rt.frame(at: t)
                if Self.noGlide(rt) { break }
                frames += 1
            }
            let label = spring.map { "\($0)" } ?? "nil"
            #expect(frames > 5, "\(label): it glided")
            #expect(rt.stats.commits == commits, "\(label): no hover handler ran mid-glide: \(rt.state.changes)")
            for _ in 0..<30 { t += Self.dt; _ = rt.frame(at: t) }
            #expect(rt.state.changes == [LoggedHover(row: 5, inside: true), LoggedHover(row: 5, inside: false), LoggedHover(row: 25, inside: true)],
                    "\(label): once it lands, hover resolves once at the pointer")
            #expect(rt.state.enters == [5, 25], "\(label)")
            #expect(!rt.hoverHold.held)
        }
    }

    // MARK: - `scroll/offset.rs::scroll_to_offsets` / `apply_jumps` (no upstream test file of its own)

    /// A 200-point viewport scrolling both ways over 2000 × 4000 points of content.
    static func plane(_: Int, _: inout Cx<Int>) -> El<Int> {
        col().size(200.0, 200.0).child(
            col().key("plane").size(200.0, 200.0).scrollXY()
                .child(el().key("content").size(2000.0, 4000.0))
        )
    }

    static func planeRuntime() -> (Runtime<Int>, String, Double) {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true, view: Self.plane)
        _ = rt.frame(at: 0.0)
        let path = rt.flatNodes.first(where: { $0.key == "plane" })?.path ?? ""
        return (rt, path, 0.0)
    }

    /// `offset.rs:44-73`: glide or jump is decided per axis. An axis with half a point or less
    /// to go jumps (and the jump arms the nudge, `apply_jumps`), while the other glides.
    @Test("offset requests glide or jump per axis, and a jumped axis arms the nudge")
    func offsetRequestsGlideOrJumpPerAxis() {
        var (rt, path, t) = Self.planeRuntime()
        rt.update(at: t) { _, tx in tx.scrollToInstant("plane", x: 100.0, y: 0.0) }
        t += Self.dt
        _ = rt.frame(at: t)
        #expect(rt.scrollOffsets[path] == Vec2(100.0, 0.0))
        for _ in 0..<10 { t += Self.dt; _ = rt.frame(at: t) }
        #expect(rt.scrollNudges[path] == nil, "the first jump's hold is spent")

        rt.update(at: t) { _, tx in tx.scrollTo("plane", x: 100.4, y: 300.0) }
        t += Self.dt
        _ = rt.frame(at: t)
        let off = rt.scrollOffsets[path] ?? .zero
        #expect(off.x == 100.4, "x, 0.4 points from its target, jumps there")
        #expect(off.y > 0.0 && off.y < 300.0, "y glides: \(off.y)")
        #expect(rt.scrollGlidingPaths.contains(path))
        #expect(rt.scrollNudges[path]?.holdAt(now: rt.currentTime) == true, "the jumped axis armed the hover hold")

        // Both axes far: both glide, and nothing jumped to arm a hold.
        for _ in 0..<120 { t += Self.dt; _ = rt.frame(at: t) }
        #expect(rt.scrollOffsets[path] == Vec2(100.4, 300.0))
        rt.update(at: t) { _, tx in tx.scrollTo("plane", x: 300.0, y: 500.0) }
        t += Self.dt
        _ = rt.frame(at: t)
        let both = rt.scrollOffsets[path] ?? .zero
        #expect(both.x > 100.4 && both.x < 300.0 && both.y > 300.0 && both.y < 500.0, "both glide: \(both)")
        #expect(rt.scrollNudges[path] == nil, "a glide arms no hold")
    }

    /// `offset.rs:44-73` with motion off (`animate = !reduced_motion && !settled`): every axis
    /// jumps, and a jump that moved arms the nudge; a jump that didn't move arms nothing
    /// (`apply_jumps`' 1e-3).
    @Test("with reduced motion an offset request jumps, and only a moving jump arms the nudge")
    func reducedMotionOffsetRequestsJump() {
        var (rt, path, t) = Self.planeRuntime()
        rt.setSystemReducedMotion(true)
        rt.update(at: t) { _, tx in tx.scrollTo("plane", x: 0.0, y: 300.0) }
        t += Self.dt
        _ = rt.frame(at: t)
        #expect(rt.scrollOffsets[path] == Vec2(0.0, 300.0))
        #expect(!rt.scrollGlidingPaths.contains(path))
        #expect(rt.scrollNudges[path]?.holdAt(now: rt.currentTime) == true)
        for _ in 0..<10 { t += Self.dt; _ = rt.frame(at: t) }
        rt.update(at: t) { _, tx in tx.scrollTo("plane", x: 0.0, y: 300.0) }
        t += Self.dt
        _ = rt.frame(at: t)
        #expect(rt.scrollNudges[path] == nil, "a jump to where it stands moves nothing and holds nothing")
    }

    /// `offset.rs:49-52,63-66` (`bottom.rs::GLIDE_REACH = 2.0`): a glide farther than two
    /// viewports cuts to two viewports out first, then glides the rest.
    @Test("a long glide cuts to two viewports out first")
    func aLongGlideCutsToTwoViewportsOutFirst() {
        #expect(ScrollSlack.glideReach == 2.0)
        var (rt, path, t) = Self.planeRuntime()
        rt.update(at: t) { _, tx in tx.scrollTo("plane", x: 0.0, y: 3000.0) }
        t += Self.dt
        _ = rt.frame(at: t)
        let y = rt.scrollOffsets[path]?.y ?? 0.0
        #expect(y >= 3000.0 - 2.0 * 200.0 && y < 3000.0, "it starts within two viewports of the end: \(y)")
        #expect(rt.scrollGlidingPaths.contains(path), "and glides the rest")
        for _ in 0..<240 { t += Self.dt; _ = rt.frame(at: t) }
        #expect(rt.scrollOffsets[path]?.y == 3000.0)
    }

    /// `offset.rs:33-38`: an anchored request (`Tx.scrollKeyTo`) always jumps, halting any glide,
    /// and the jump arms the nudge.
    @Test("an anchored request jumps, halts a glide, and arms the nudge")
    func anAnchoredRequestJumpsAndArmsTheNudge() {
        var (rt, t) = Self.hovering()
        let path = rt.flatNodes.first(where: { $0.key == "scroll" })?.path ?? ""
        rt.update(at: t) { _, tx in tx.scrollTo("scroll", x: 0.0, y: 400.0) }
        t += Self.dt
        _ = rt.frame(at: t)
        #expect(rt.scrollGlidingPaths.contains(path), "a glide runs")
        rt.update(at: t) { _, tx in tx.scrollKeyTo("r20", at: 10.0) }
        t += Self.dt
        _ = rt.frame(at: t)
        #expect(!rt.scrollGlidingPaths.contains(path), "the anchored jump halted the glide")
        #expect(abs((rt.scrollOffsets[path]?.y ?? 0.0) - 390.0) < 1e-3, "r20's top lands 10 points below the top")
        #expect(rt.scrollNudges[path]?.holdAt(now: rt.currentTime) == true, "the jump armed the hover hold")
    }

    /// Upstream has one offset path (`requests.rs::finish_scroll_requests` -> `scroll_to_offsets`
    /// + `apply_jumps`), whether or not the transaction commits: an instant request from a
    /// transaction that commits nothing (`updateIf { ...; return false }`, or `liveOnly`) arms
    /// the hold, holds hover under the still pointer, and the hold's wake resolves it.
    @Test("an instant offset request from a non-committing transaction arms the nudge")
    func anInstantOffsetRequestFromANonCommittingTransactionArmsTheNudge() {
        for liveOnly in [false, true] {
            var (rt, t) = Self.hovering()
            let path = rt.flatNodes.first(where: { $0.key == "scroll" })?.path ?? ""
            _ = rt.updateIf(at: t) { _, tx in
                if liveOnly { tx.liveOnly() }
                tx.scrollToInstant("scroll", x: 0.0, y: 400.0)
                return false
            }
            t += Self.dt
            _ = rt.frame(at: t)
            #expect(rt.scrollOffsets[path]?.y == 400.0, "liveOnly=\(liveOnly): it jumped")
            #expect(rt.scrollNudges[path]?.holdAt(now: rt.currentTime) == true, "liveOnly=\(liveOnly): the jump armed the hold")
            #expect(Self.shown(rt) == ["a5"], "liveOnly=\(liveOnly): hover holds under the still pointer")
            guard let due = rt.nextWakeDeadline(after: rt.currentTime) else {
                Issue.record("liveOnly=\(liveOnly): the hold wakes a frame")
                continue
            }
            _ = rt.frame(at: due)
            #expect(Self.shown(rt) == ["a25"], "liveOnly=\(liveOnly): the wake's frame resolves hover at the pointer")
        }
    }

    /// The same single path for a glide from a transaction that commits nothing: the long trip
    /// cuts to two viewports out first (`GLIDE_REACH`), and the axes split glide and jump.
    @Test("a glide from a non-committing transaction cuts and splits per axis")
    func aGlideFromANonCommittingTransactionCutsAndSplitsPerAxis() {
        var (rt, path, t) = Self.planeRuntime()
        _ = rt.updateIf(at: t) { _, tx in tx.scrollTo("plane", x: 0.3, y: 3000.0); return false }
        t += Self.dt
        _ = rt.frame(at: t)
        let off = rt.scrollOffsets[path] ?? .zero
        #expect(off.y >= 3000.0 - 2.0 * 200.0 && off.y < 3000.0, "it starts within two viewports of the end: \(off.y)")
        #expect(abs(off.x - 0.3) < 1e-6, "x, 0.3 points away, jumps: \(off.x)")
        #expect(rt.scrollGlidingPaths.contains(path))
        #expect(rt.scrollNudges[path]?.holdAt(now: rt.currentTime) == true, "the jumped axis armed the hold")
    }

    /// `hover.rs:384-385` (`if held && !f.now { continue; }`): a held flip waits whatever the
    /// motion setting. Under Reduce Motion an instant scroll's hold keeps r5's hover track lit
    /// and r25's dark until the hold's wake, which then lands both at once.
    @Test("reduce motion still holds hover tracks under an instant scroll's hold")
    func reduceMotionStillHoldsHoverTracks() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true, view: Self.view)
        rt.setSystemReducedMotion(true)
        var t = 0.0
        _ = rt.frame(at: t)
        rt.pointerMove(to: Vec2(100.0, 110.0), at: t)
        t += Self.dt
        _ = rt.frame(at: t)
        #expect(Self.shown(rt) == ["a5"])
        func lit(_ key: String) -> Float? {
            guard let n = rt.flatNodes.first(where: { $0.key == key }) else { return nil }
            return rt.liveStore.target(Runtime<Int>.hoverTrackId(n.nodeId), Runtime<Int>.hoverProp) ?? 0.0
        }
        rt.update(at: t) { _, tx in tx.scrollToInstant("scroll", x: 0.0, y: 400.0) }
        t += Self.dt
        _ = rt.frame(at: t)
        #expect(rt.hoverHold.held, "the nudge holds hover")
        #expect(lit("r5") == 1.0 && lit("r25") == 0.0, "held, neither track moves: r5 \(String(describing: lit("r5"))), r25 \(String(describing: lit("r25")))")
        #expect(Self.shown(rt) == ["a5"])
        guard let due = rt.nextWakeDeadline(after: rt.currentTime) else {
            Issue.record("the hold wakes a frame")
            return
        }
        _ = rt.frame(at: due)
        #expect(lit("r5") == 0.0 && lit("r25") == 1.0, "the wake's frame resolves hover at the pointer")
        #expect(Self.shown(rt) == ["a25"])
    }

    /// `offset.rs:281-308,331-338`: a request touches only the axes it names. A jump on x while y
    /// glides lands x and leaves the y glide running to its end; a jump on y while x glides does
    /// the same the other way. Both from a committing and a non-committing transaction.
    @Test("an offset request leaves an axis it doesn't name alone, glide and all")
    func anOffsetRequestLeavesAnUnnamedAxisAlone() {
        for committing in [true, false] {
            // y glides, x jumps.
            var (rt, path, t) = Self.planeRuntime()
            rt.update(at: t) { _, tx in tx.scrollTo("plane", x: 0.0, y: 300.0) }
            t += Self.dt
            _ = rt.frame(at: t)
            let yStart = rt.scrollOffsets[path]?.y ?? 0.0
            #expect(yStart > 0.0 && yStart < 300.0 && rt.scrollGlidingPaths.contains(path), "committing=\(committing): y glides")
            if committing {
                rt.update(at: t) { _, tx in tx.scrollToX("plane", 100.0) }
            } else {
                _ = rt.updateIf(at: t) { _, tx in tx.scrollToX("plane", 100.0); return false }
            }
            t += Self.dt
            _ = rt.frame(at: t)
            let mid = rt.scrollOffsets[path] ?? .zero
            #expect(mid.x == 100.0, "committing=\(committing): x jumped: \(mid)")
            #expect(mid.y > yStart && mid.y < 300.0, "committing=\(committing): y carries on gliding: \(mid.y)")
            #expect(rt.scrollGlidingPaths.contains(path), "committing=\(committing): the y glide still runs")
            #expect(rt.scrollNudges[path]?.holdAt(now: rt.currentTime) == true, "committing=\(committing): the x jump armed the hold")
            for _ in 0..<120 { t += Self.dt; _ = rt.frame(at: t) }
            #expect(rt.scrollOffsets[path] == Vec2(100.0, 300.0), "committing=\(committing): y reached its end: \(String(describing: rt.scrollOffsets[path]))")

            // x glides, y jumps.
            var (rt2, path2, t2) = Self.planeRuntime()
            rt2.update(at: t2) { _, tx in tx.scrollTo("plane", x: 300.0, y: 0.0) }
            t2 += Self.dt
            _ = rt2.frame(at: t2)
            let xStart = rt2.scrollOffsets[path2]?.x ?? 0.0
            if committing {
                rt2.update(at: t2) { _, tx in tx.scrollToY("plane", 50.0) }
            } else {
                _ = rt2.updateIf(at: t2) { _, tx in tx.scrollToY("plane", 50.0); return false }
            }
            t2 += Self.dt
            _ = rt2.frame(at: t2)
            let mid2 = rt2.scrollOffsets[path2] ?? .zero
            #expect(mid2.y == 50.0 && mid2.x > xStart && mid2.x < 300.0, "committing=\(committing): y jumped, x glides on: \(mid2)")
            for _ in 0..<120 { t2 += Self.dt; _ = rt2.frame(at: t2) }
            #expect(rt2.scrollOffsets[path2] == Vec2(300.0, 50.0), "committing=\(committing): x reached its end")
        }
    }

    /// `offset.rs` / `apply_jumps`: a jump on one axis that lands where that axis already is
    /// moves nothing and arms no hold, whatever the other axis stands at.
    @Test("a jump that doesn't move its own axis arms nothing")
    func aJumpThatDoesntMoveItsOwnAxisArmsNothing() {
        var (rt, path, t) = Self.planeRuntime()
        rt.update(at: t) { _, tx in tx.scrollToInstant("plane", x: 0.0, y: 200.0) }
        t += Self.dt
        _ = rt.frame(at: t)
        for _ in 0..<10 { t += Self.dt; _ = rt.frame(at: t) }
        #expect(rt.scrollNudges[path] == nil)
        rt.update(at: t) { _, tx in tx.scrollToX("plane", 0.0) }
        t += Self.dt
        _ = rt.frame(at: t)
        #expect(rt.scrollOffsets[path] == Vec2(0.0, 200.0))
        #expect(rt.scrollNudges[path] == nil, "x stood at 0 already: nothing moved, nothing holds")
    }
}
