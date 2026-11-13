import Foundation
import Testing
@testable import Rune
@testable import RuneMotion

@Suite("AnchoredGrow Parity (anchored_grow_tests.rs)")
struct AnchoredGrowParityTests {

    private struct AnchorGrowState {
        var label: String
        var side: Side
        var align: Align
        var w: Float
        var h: Float
        var depth: Float? = nil
    }

    private let shortLabel = "1 subagent"
    private let longLabel = "2 subagents and 1 shell"

    private func buildView(_ s: AnchorGrowState) -> El<AnchorGrowState> {
        let vertical = s.side == .top || s.side == .bottom
        let cap: El<AnchorGrowState>
        if let d = s.depth {
            cap = (vertical ? el().key("cap").w(40.0).h(d) : el().key("cap").w(d).h(40.0)).animateLayout()
        } else if vertical {
            cap = row().key("cap").h(28.0).pl(10.0).pr(10.0).itemsCenter().child(text(s.label)).animateLayout()
        } else {
            cap = el().key("cap").w(40.0).h(s.h).animateLayout()
        }
        return col().size(800.0, 600.0).itemsCenter().justifyCenter()
            .child(el().key("target").size(s.w, 100.0).animateLayout())
            .child(cap.anchored("target", side: s.side, align: s.align, gap: 10.0))
    }

    private func startRuntime(_ s: AnchorGrowState) -> (Runtime<AnchorGrowState>, Double) {
        let rt = Runtime<AnchorGrowState>(state: s, viewport: Vec2(800.0, 600.0), pixelScale: 1.0) { st, _ in
            buildView(st)
        }
        var t = 0.0
        _ = rt.frame(at: t)
        for _ in 0..<240 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        return (rt, t)
    }

    private func runSide(_ side: Side, align: Align) -> (Runtime<AnchorGrowState>, Double) {
        startRuntime(AnchorGrowState(label: shortLabel, side: side, align: align, w: 600.0, h: 40.0, depth: nil))
    }

    private func rect(_ rt: Runtime<AnchorGrowState>, _ key: String) -> [Float] {
        rt.element(byKey: key)?.rect ?? []
    }

    private func springStep(
        _ rt: Runtime<AnchorGrowState>,
        t: inout Double,
        vertical: Bool,
        held: (Runtime<AnchorGrowState>) -> (Float, Float)
    ) -> [Float] {
        var sizes: [Float] = []
        for frame in 0..<240 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            let (got, want) = held(rt)
            #expect(abs(got - want) < 0.5, "frame \(frame): the aligned edge is at \(got), wanted \(want)")
            let r = rect(rt, "cap")
            sizes.append(vertical ? r[3] : r[2])
        }
        return sizes
    }

    private func assertSmooth(_ sizes: [Float], from: Float, to: Float) {
        let step = abs(to - from) * 0.1
        for i in 1..<sizes.count {
            #expect(abs(sizes[i] - sizes[i - 1]) < step, "size stepped \(sizes[i - 1]) -> \(sizes[i])")
        }
        #expect(abs(sizes[0] - from) < step, "first frame size \(sizes[0]) is near \(from)")
        #expect(abs((sizes.last ?? 0) - to) < 0.5, "settles at \(to), not \(sizes.last ?? 0)")
        let mid = (from + to) * 0.5
        #expect(sizes.contains { abs($0 - mid) < abs(to - from) * 0.25 }, "the size springs through \(mid)")
    }

    @Test("an_end_aligned_box_keeps_its_end_edge_while_its_width_springs")
    func endAlignedBoxKeepsEndEdgeWhileWidthSprings() {
        var (rt, t) = runSide(.top, align: .end)
        let r0 = rect(rt, "cap")
        #expect(abs(r0[0] + r0[2] - 700.0) < 0.5, "settled at anchor right edge: \(r0)")
        let short = r0[2]
        rt.update(at: t) { s, _ in s.label = longLabel }
        let right: (Runtime<AnchorGrowState>) -> (Float, Float) = { rt in
            let r = self.rect(rt, "cap")
            return (r[0] + r[2], 700.0)
        }
        let grow = springStep(rt, t: &t, vertical: false, held: right)
        let long = grow.last ?? 0
        #expect(long > short + 40.0, "\(long) grows from \(short)")
        assertSmooth(grow, from: short, to: long)

        rt.update(at: t) { s, _ in s.label = shortLabel }
        let shrink = springStep(rt, t: &t, vertical: false, held: right)
        assertSmooth(shrink, from: long, to: short)
    }

    @Test("a_centred_box_keeps_its_centre_and_a_start_aligned_box_its_start")
    func centredAndStartAlignedHoldEdge() {
        do {
            var (rt, t) = runSide(.bottom, align: .center)
            rt.update(at: t) { s, _ in s.label = longLabel }
            _ = springStep(rt, t: &t, vertical: false) { rt in
                let r = self.rect(rt, "cap")
                return (r[0] + r[2] * 0.5, 400.0)
            }
        }
        do {
            var (rt, t) = runSide(.top, align: .start)
            rt.update(at: t) { s, _ in s.label = longLabel }
            _ = springStep(rt, t: &t, vertical: false) { rt in
                (self.rect(rt, "cap")[0], 100.0)
            }
        }
    }

    @Test("a_box_beside_its_anchor_keeps_its_vertical_alignment_while_its_height_springs")
    func boxBesideAnchorKeepsVerticalAlignment() {
        let cases: [(Side, Align, Float)] = [
            (.right, .end, 1.0),
            (.left, .center, 0.5),
            (.right, .start, 0.0),
        ]
        for (side, align, heldFrac) in cases {
            var (rt, t) = runSide(side, align: align)
            rt.update(at: t) { s, _ in s.h = 90.0 }
            let edge: (Runtime<AnchorGrowState>) -> (Float, Float) = { rt in
                let r = self.rect(rt, "cap")
                return (r[1] + r[3] * heldFrac, 250.0 + 100.0 * heldFrac)
            }
            let grow = springStep(rt, t: &t, vertical: true, held: edge)
            assertSmooth(grow, from: 40.0, to: 90.0)

            rt.update(at: t) { s, _ in s.h = 20.0 }
            let shrink = springStep(rt, t: &t, vertical: true, held: edge)
            assertSmooth(shrink, from: 90.0, to: 20.0)
        }
    }

    @Test("an_anchored_box_follows_its_resizing_anchor_frame_by_frame")
    func anchoredBoxFollowsResizingAnchorFrameByFrame() {
        var (rt, t) = runSide(.top, align: .end)
        rt.update(at: t) { s, _ in s.w = 400.0 }
        var moved = false
        for frame in 0..<240 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            let cap = rect(rt, "cap")
            let target = rect(rt, "target")
            moved = moved || (abs(target[0] + target[2] - 700.0) > 1.0 && abs(target[0] + target[2] - 600.0) > 1.0)
            #expect(
                abs((cap[0] + cap[2]) - (target[0] + target[2])) < 0.5,
                "frame \(frame): box ends at \(cap[0] + cap[2]), anchor at \(target[0] + target[2])"
            )
        }
        #expect(moved, "the anchor springs to its new width")
        let finalCap = rect(rt, "cap")
        #expect(abs(finalCap[0] + finalCap[2] - 600.0) < 0.5)
    }

    @Test("the_edge_facing_the_anchor_holds_while_the_box_springs_away_from_it")
    func edgeFacingAnchorHoldsWhileBoxSpringsAway() {
        func near(_ side: Side, _ r: [Float]) -> (Float, Float) {
            switch side {
            case .top: return (r[1] + r[3], 240.0)
            case .bottom: return (r[1], 360.0)
            case .left: return (r[0] + r[2], 240.0)
            case .right: return (r[0], 560.0)
            }
        }
        for side in [Side.top, .bottom, .left, .right] {
            let vertical = side == .top || side == .bottom
            var (rt, t) = startRuntime(
                AnchorGrowState(label: shortLabel, side: side, align: .start, w: 300.0, h: 40.0, depth: 180.0)
            )
            let held: (Runtime<AnchorGrowState>) -> (Float, Float) = { rt in near(side, self.rect(rt, "cap")) }
            let (got, want) = held(rt)
            #expect(abs(got - want) < 0.5, "\(side) settles \(want), not \(got)")
            rt.update(at: t) { s, _ in s.depth = 57.0 }
            let shrink = springStep(rt, t: &t, vertical: vertical, held: held)
            assertSmooth(shrink, from: 180.0, to: 57.0)
            rt.update(at: t) { s, _ in s.depth = 180.0 }
            let grow = springStep(rt, t: &t, vertical: vertical, held: held)
            assertSmooth(grow, from: 57.0, to: 180.0)
        }
    }

    @Test("an_anchored_box_inside_a_moving_or_offset_parent_holds_its_anchor_gap")
    func anchoredBoxInsideMovingOrOffsetParentHoldsGap() {
        struct Dock {
            var composerH: Float
            var capW: Float
            var open: Bool
        }
        let rt = Runtime<Dock>(
            state: Dock(composerH: 40.0, capW: 100.0, open: false),
            viewport: Vec2(800.0, 600.0),
            pixelScale: 1.0
        ) { s, _ in
            var wrap: El<Dock> = col().key("wrap").w(600.0).offset(15.0, -8.0)
                .child(el().key("composer").wFull().h(s.composerH))
            if s.open {
                let pill = el().key("pill")
                    .size(s.capW, 28.0)
                    .offset(6.0, -4.0)
                    .raise()
                    .transition(
                        Transition.offset(x: 0.0, y: 10.0)
                            .combined(with: Transition.scale(0.8, anchor: Vec2(1.0, 1.0)))
                    )
                    .onClick { (st: inout Dock) in st.capW = 180.0 }
                    .anchored("composer", side: .top, align: .end, gap: 10.0)
                wrap = wrap.child(pill)
            }
            return col().size(800.0, 600.0).itemsCenter()
                .child(el().wFull().grow(1.0))
                .child(wrap)
        }
        var t = 0.0
        _ = rt.frame(at: t)
        for _ in 0..<240 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }

        rt.update(at: t) { s, _ in s.open = true }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let comp0 = rt.element(byKey: "composer")!.rect
        let pill0 = rt.element(byKey: "pill")!.rect
        #expect(pill0[2] < 98.0 && pill0[2] > 75.0, "entering pill scales from 0.8: \(pill0)")
        #expect(pill0[1] + pill0[3] > comp0[1] - 10.0 - 4.0 + 2.0, "entering pill starts shifted down by transition offset: \(pill0)")
        for _ in 0..<240 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        let comp = rt.element(byKey: "composer")!.rect
        let pill = rt.element(byKey: "pill")!.rect
        #expect(abs((pill[0] + pill[2]) - (comp[0] + comp[2] + 6.0)) < 0.5, "settled x includes pill offset(6): \(pill) vs \(comp)")
        #expect(abs((pill[1] + pill[3]) - (comp[1] - 10.0 - 4.0)) < 0.5, "settled y includes pill offset(-4): \(pill) vs \(comp)")

        let cx = pill[0] + pill[2] * 0.5
        let cy = pill[1] + pill[3] * 0.5
        rt.pointerDown(at: Vec2(cx, cy), at: t)
        rt.pointerUp(at: Vec2(cx, cy), at: t)
        rt.update(at: t) { s, _ in s.composerH = 100.0 }
        for frame in 0..<240 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            let c = rt.element(byKey: "composer")!.rect
            let p = rt.element(byKey: "pill")!.rect
            let info = rt.elements().first { $0.key == "pill" }!
            #expect(info.rect == p, "frame \(frame): elements() agrees with presented")
            #expect(
                abs((p[0] + p[2]) - (c[0] + c[2] + 6.0)) < 0.5,
                "frame \(frame): pill right \(p[0] + p[2]) stays aligned to composer right + 6 (\(c[0] + c[2] + 6.0))"
            )
            #expect(
                abs((p[1] + p[3]) - (c[1] - 10.0 - 4.0)) < 0.5,
                "frame \(frame): pill bottom \(p[1] + p[3]) stays 14pt above composer top \(c[1])"
            )
        }
        #expect(abs(rt.element(byKey: "pill")!.rect[2] - 180.0) < 0.5)
    }

    @Test("animate_layout_and_scrolled_sticky_subtree_agree_across_paint_caret_and_layout")
    func animateLayoutAndScrolledStickySubtreeAgree() {
        struct Sub {
            var popSize: (Float, Float)
            var edit: TextEdit
            var seenLayout: [Float]? = nil
        }
        let initialEdit = TextEdit("hi")
        let rt = Runtime<Sub>(
            state: Sub(popSize: (120.0, 50.0), edit: initialEdit, seenLayout: nil),
            viewport: Vec2(400.0, 300.0),
            pixelScale: 1.0
        ) { s, cx in
            let seen = cx.layout("pop")
            var input = textInput(key: "field", \Sub.edit).autofocus(true).size(s.popSize.0, 22.0)
            if let r = seen {
                input = input.label(String(format: "%.0f,%.0f", r[0], r[1]))
            }
            return col().size(400.0, 300.0)
                .child(
                    col().key("scroll").size(400.0, 300.0).scroll(ScrollSpec(stickBottom: false)).scrollXY()
                        .child(
                            col().w(900.0).growth(GrowthSpec())
                                .child(
                                    row().key("hdr").w(900.0).h(40.0).stickyTop(0.0)
                                        .child(el().key("anchor").size(100.0, 30.0).stickyLeft(0.0))
                                        .child(
                                            col().key("pop").size(s.popSize.0, s.popSize.1).animateLayout()
                                                .onLayout { st, r in st.seenLayout = r }
                                                .child(input)
                                                .anchored("anchor", side: .bottom, align: .end, gap: 6.0)
                                        )
                                )
                                .child(el().size(900.0, 800.0))
                        )
                )
        }
        var t = 0.0
        _ = rt.frame(at: t)
        for _ in 0..<120 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }

        rt.wheel(WheelEvent(dx: -200.0, dy: -120.0), at: Vec2(200.0, 150.0), now: t)
        for _ in 0..<60 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        let anc = rt.element(byKey: "anchor")!.rect
        let pop = rt.element(byKey: "pop")!.rect
        #expect(abs(anc[0]) < 0.5 && abs(anc[1]) < 0.5, "anchor stuck at top-left: \(anc)")
        #expect(abs(pop[0] - 8.0) < 0.5 && abs(pop[1] - 36.0) < 0.5, "popover sits below stuck anchor (clamped to 8pt left margin): \(pop)")
        let fieldEl = rt.elements().first { $0.key == "field" }!
        let caret = fieldEl.caret
        #expect(caret != nil, "focused field inside anchored popover has caret")
        if let caret {
            #expect(caret[0] >= pop[0] && caret[0] <= pop[0] + pop[2] && abs(caret[1] - pop[1]) < 8.0, "caret \(caret) sits inside drawn popover \(pop)")
        }
        let laid = rt.state.seenLayout
        #expect(laid != nil, "on_layout reported")
        if let laid {
            #expect(abs(laid[0] - pop[0]) < 0.5 && abs(laid[1] - pop[1]) < 0.5, "on_layout \(laid) agrees with drawn popover \(pop)")
        }

        rt.update(at: t) { s, _ in s.popSize = (180.0, 90.0) }
        var heights: [Float] = []
        var widths: [Float] = []
        for _ in 0..<240 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            let p = rt.element(byKey: "pop")!.rect
            widths.append(p[2])
            heights.append(p[3])
            #expect(abs(p[1] - 36.0) < 0.5, "top edge holds at 36 while height springs: \(p)")
        }
        assertSmooth(widths, from: 120.0, to: 180.0)
        assertSmooth(heights, from: 50.0, to: 90.0)
    }
}
