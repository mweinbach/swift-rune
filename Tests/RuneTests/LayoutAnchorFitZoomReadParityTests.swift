import Foundation
import Testing
@testable import Rune
@testable import RuneMotion

@Suite("AnchorFit, Zoom & LayoutRead Parity")
struct LayoutAnchorFitZoomReadParityTests {

    // MARK: - crates/rune/src/runtime/zoom.rs (`input_scale`)

    @Test("zoom: inputScale equals windowScale * zoom across scale and zoom changes")
    func zoomInputScaleParity() {
        struct S {
            var zoom: Float = 1.0
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(800, 600), pixelScale: 1.5) { s, cx in
            cx.zoom(s.zoom)
            return col().wFull().hFull()
        }
        _ = rt.frame(at: 0.0)
        #expect(abs(rt.windowScale() - 1.5) < 1e-6)
        #expect(abs(rt.zoom() - 1.0) < 1e-6)
        #expect(abs(rt.inputScale() - 1.5) < 1e-6)

        rt.update(at: 0.01) { st, _ in st.zoom = 1.6 }
        _ = rt.frame(at: 0.02)
        #expect(abs(rt.windowScale() - 1.5) < 1e-6)
        #expect(abs(rt.zoom() - 1.6) < 1e-5)
        #expect(abs(rt.inputScale() - 1.5 * 1.6) < 1e-5)
        #expect(rt.viewport == Vec2(800.0 / 1.6, 600.0 / 1.6))
        let win = rt.toWindow([10.0, 20.0, 30.0, 40.0])
        #expect(abs(win[0] - 16.0) < 1e-4 && abs(win[1] - 32.0) < 1e-4)
        #expect(abs(win[2] - 48.0) < 1e-4 && abs(win[3] - 64.0) < 1e-4)
    }

    // MARK: - crates/rune/src/runtime/anchor_fit_tests.rs

    private struct AnchorFitState {
        var top: Float
        var rows: Int
        var fit: Bool
    }

    private func runAnchorFit(_ s: AnchorFitState) -> [Float] {
        let rt = Runtime<AnchorFitState>(state: s, viewport: Vec2(400, 300), pixelScale: 1.0) { st, _ in
            let rowEls: [El<AnchorFitState>] = (0..<st.rows).map { i in
                el().key("row\(i)").w(100).h(20)
            }
            let rows = col().key("rows").children(rowEls)
            let list = col().key("scroll").shrink().minH(0).scroll(ScrollSpec(stickBottom: false)).child(rows)
            var menu = col().key("menu").w(100).child(list)
            if st.fit {
                menu = menu.anchoredFit("target", side: .bottom, align: .start, gap: 4.0)
            } else {
                menu = menu.anchored("target", side: .bottom, align: .start, gap: 4.0)
            }
            return col()
                .size(400, 300)
                .child(el().key("target").absolute(x: 20.0, y: st.top).size(100, 30))
                .child(menu)
        }
        var t = 0.0
        _ = rt.frame(at: t)
        for _ in 0..<120 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        return rt.element(byKey: "menu")?.rect ?? []
    }

    @Test("a_list_that_fits_below_is_left_alone")
    func listThatFitsBelowIsLeftAlone() {
        let r = runAnchorFit(AnchorFitState(top: 20.0, rows: 5, fit: true))
        #expect(r.count == 4)
        #expect(abs(r[1] - 54.0) < 0.01 && abs(r[3] - 100.0) < 0.01)
    }

    @Test("a_list_that_fits_above_flips_whole")
    func listThatFitsAboveFlipsWhole() {
        let r = runAnchorFit(AnchorFitState(top: 200.0, rows: 8, fit: true))
        #expect(r.count == 4)
        #expect(abs(r[1] - 36.0) < 0.01 && abs(r[3] - 160.0) < 0.01)
    }

    @Test("a_long_list_takes_the_larger_room_and_scrolls")
    func longListTakesLargerRoomAndScrolls() {
        // Below has 300 - 8 - 234 = 58 pt, above 200 - 4 - 8 = 188 pt.
        let fitted = runAnchorFit(AnchorFitState(top: 200.0, rows: 40, fit: true))
        #expect(fitted.count == 4)
        #expect(abs(fitted[3] - 187.0) < 0.01, "bounded to room above: \(fitted)")
        #expect(fitted[1] >= 8.0 && fitted[1] + fitted[3] <= 196.0, "above anchor inside window: \(fitted)")

        // Without fit it stays below and runs off the window.
        let unfitted = runAnchorFit(AnchorFitState(top: 200.0, rows: 40, fit: false))
        #expect(unfitted.count == 4)
        #expect(abs(unfitted[1] - 234.0) < 0.01 && abs(unfitted[3] - 800.0) < 0.01)
    }

    @Test("a_long_list_with_more_room_below_stays_below")
    func longListWithMoreRoomBelowStaysBelow() {
        // Below has 300 - 8 - 84 = 208 pt, above 50 - 4 - 8 = 38 pt.
        let r = runAnchorFit(AnchorFitState(top: 50.0, rows: 40, fit: true))
        #expect(r.count == 4)
        #expect(abs(r[1] - 84.0) < 0.01 && abs(r[3] - 207.0) < 0.01)
    }

    // MARK: - crates/rune/src/runtime/tests/layout_reads.rs:51

    @Test("a_virtual_row_reads_where_it_draws_with_rows_culled_above")
    func virtualRowReadsWhereItDrawsWithRowsCulledAbove() {
        final class SeenBox {
            var rects: [[Float]?] = [nil, nil]
        }
        let seen = SeenBox()
        let rt = Runtime<SeenBox>(state: seen, viewport: Vec2(300, 300), pixelScale: 1.0) { s, cx in
            s.rects = [cx.windowLayout("r27"), cx.windowLayout("r27/label")]
            let rows: El<SeenBox> = col().key("rows").wFull().growth(GrowthSpec())
                .virtualRows(
                    count: 100,
                    estimatedRowHeight: 40.0,
                    key: { (_: SeenBox, i: Int) in "r\(i)" }
                ) { (_: SeenBox, _: Int) in
                    col().wFull().h(40.0).pt(5.0).child(el().key("label").w(10.0).h(10.0))
                }
            return col().wFull().hFull().child(
                col().key("list").wFull().h(200.0).scroll(ScrollSpec(stickBottom: false)).child(rows)
            )
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.01) { _, tx in
            tx.scrollToInstant("list", x: 0.0, y: 1000.0)
        }
        for step in 1...4 {
            _ = rt.frame(at: Double(step) / 60.0)
        }
        let hasCulledBefore = rt.virtualLists.values.contains { $0.lastMountedRange.lowerBound > 0 }
        #expect(hasCulledBefore, "rows above the window are culled")
        let rowDrawn: [Float]? = rt.element(byKey: "r27")?.rect
        #expect(rowDrawn != nil)
        if let rowDrawn {
            #expect(abs(rowDrawn[1] - 80.0) < 0.5, "row 27 draws 1080 pt down, scrolled 1000: \(rowDrawn)")
        }
        #expect(seen.rects[0] == rowDrawn, "the row reads where it draws")
        let labelDrawn: [Float]? = rt.elements().first { $0.path.contains("@r27/") && $0.key == "label" }?.rect
        #expect(labelDrawn != nil)
        #expect(seen.rects[1] == labelDrawn, "so does an element inside it")
    }

    // MARK: - crates/rune/tests/layout_read.rs:473 & :496

    @Test("a_key_unread_on_one_settling_pass_keeps_its_rect_for_the_next")
    func keyUnreadOnOneSettlingPassKeepsRectForNext() {
        final class Counter { var views = 0 }
        struct Gate {
            var width: Float = 100.0
        }
        let counter = Counter()
        let rt = Runtime<Gate>(state: Gate(), viewport: Vec2(300, 200), pixelScale: 2.0) { s, cx in
            counter.views += 1
            let ready = cx.layout("a").map { abs($0[2] - s.width) < 0.01 } ?? false
            let b = ready ? cx.layout("b") : nil
            return col().wFull().itemsStart()
                .child(el().key("a").w(s.width).h(10.0))
                .child(el().key("b").w(50.0).h(10.0))
                .child(el().key("echo").w(b?[2] ?? 0.0).h(5.0))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        for _ in 0..<10 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        let viewsBefore = counter.views
        rt.update(at: t) { s, _ in s.width = 200.0 }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let echoTarget = rt.element(byKey: "echo")?.target
        #expect(echoTarget?[2] == 50.0)
        #expect(counter.views - viewsBefore == 2, "one pass with a stale, one to settle")
    }

    @Test("moving_an_element_does_not_change_the_size_a_read_sees")
    func movingElementDoesNotChangeSizeAReadSees() {
        final class Counter { var views = 0 }
        struct Bar {
            var top: Float = 0.0
        }
        let counter = Counter()
        let rt = Runtime<Bar>(state: Bar(), viewport: Vec2(300, 400), pixelScale: 2.0) { s, cx in
            counter.views += 1
            let h = cx.layoutSize("third")?[1] ?? 0.0
            return col().wFull().itemsStart()
                .child(el().key("gap").w(10.0).h(s.top))
                .child(el().key("third").w(10.0).h(100.0 / 3.0))
                .child(el().key("echo").w(10.0).h(h))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        for top: Float in [33.4, 50.0, 31.0, 64.1] {
            let viewsBefore = counter.views
            rt.update(at: t) { s, _ in s.top = top }
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            #expect(counter.views - viewsBefore == 1, "a move to \(top) re-ran the size read")
        }
    }

    // MARK: - crates/rune/src/el/anchor.rs (`Anchor`, `above`, `anchored_unscaled`, `anchored_round`)

    @Test("Page scroll moves both the document and its anchored text overlay by the snapped band offset")
    func fractionalPageScrollCarriesAnchoredGlyphs() throws {
        let scale: Float = 2
        let top: Float = 40.1875
        let rt = Runtime<Void>(state: (), viewport: Vec2(200, 100), pixelScale: scale) { _, _ in
            col().size(200, 300).children([
                text("A").key("trigger").size(50, 18).absolute(x: 20, y: top).bg(.white),
                text("B").key("tip").size(50, 18).above("trigger", gutter: 4).bg(.white),
            ])
        }
        rt.pageMode()

        func quads(at time: Double) -> (reference: [SIMD4<Float>], native: [SIMD4<Float>]) {
            let reference = rt.frame(at: time).primitives
            let native = rt.renderFrame(at: time).instances
            let kinds = [KIND_RECT, KIND_GLYPH, KIND_RECT, KIND_GLYPH]
            #expect(reference.map(\.params.y) == kinds)
            #expect(native.map(\.params.y) == kinds)
            return (reference.map(\.rect), native.map(\.rect))
        }

        let rest = quads(at: 0)
        for (step, y) in [Float(3.3125), 3.25, 3.1875, 0].enumerated() {
            let time = Double(step + 1) / 120
            rt.setPageScroll(y, at: time)
            let scrolled = quads(at: time)
            // web/page.rs snaps the positive band offset before root_inh gives it a minus sign.
            // At 2×, 3.3125 pt and 3.25 pt both move the page up 7 px, and 3.1875 moves it 6.
            let pixels = (y * scale).rounded()
            let shift = SIMD4<Float>(0, pixels, 0, 0)
            #expect(scrolled.reference == rest.reference.map { $0 - shift })
            #expect(scrolled.native == rest.native.map { $0 - shift })
            let trigger = try #require(rt.element(byKey: "trigger"))
            let tip = try #require(rt.element(byKey: "tip"))
            #expect(trigger.rect[1] == top - pixels / scale)
            #expect(tip.rect[1] + tip.rect[3] == trigger.rect[1] - 4)
        }
    }

    @Test("Anchor struct, El.above, anchoredUnscaled, and anchoredRound parity")
    func anchorModifiersParity() {
        let manual = Anchor(key: "trg", side: .top, align: .center, gap: 4, fit: false, unscaled: false, round: true)
        let pos = anchorPosition(manual, trigger: [20.3, 100.4, 51.0, 120.4], size: (40.0, 20.0), viewport: (300.0, 200.0))
        // center x = (20.3 + 51.0 - 40.0) * 0.5 = 15.65 -> rounded 16; top y = 100.4 - 20.0 - 4.0 = 76.4 -> rounded 76
        #expect(pos.0 == 16.0 && pos.1 == 76.0)

        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 200), pixelScale: 1.0) { _, _ in
            col().size(300, 200).children([
                col().scale(2.0).size(60, 20).ml(50).mt(50).children([
                    el().key("scaled-trg").size(40, 20),
                ]),
                el().key("fractional-trg").absolute(x: 20.4, y: 100.3).size(31, 20),
                el().key("above-tip").w(40).h(18).above("fractional-trg", gutter: 6),
                el().key("round-tip").w(40).h(18).anchored("fractional-trg", side: .bottom, align: .center, gap: 4).anchoredRound(),
                el().key("unscaled-tip").w(50).h(20).anchored("scaled-trg", side: .bottom, align: .start, gap: 4).anchoredUnscaled(),
            ])
        }
        _ = rt.frame(at: 0.0)
        if let trg = rt.element(byKey: "fractional-trg"),
           let above = rt.element(byKey: "above-tip"),
           let rounded = rt.element(byKey: "round-tip") {
            #expect(abs((above.rect[1] + above.rect[3]) - (trg.rect[1] - 6.0)) < 0.01)
            #expect(rounded.rect[0] == rounded.rect[0].rounded() && rounded.rect[1] == rounded.rect[1].rounded())
        } else {
            Issue.record("missing fractional-trg / above-tip / round-tip elements")
        }
        if let unscaled = rt.element(byKey: "unscaled-tip") {
            // Unscaled overlay keeps its own 50x20 size instead of inheriting the trigger's 2x scale
            #expect(abs(unscaled.rect[2] - 50.0) < 0.01 && abs(unscaled.rect[3] - 20.0) < 0.01)
        } else {
            Issue.record("missing unscaled-tip element")
        }
    }

    // MARK: - crates/rune/src/runtime/tests/layout_reads.rs (`few_and_many_reads_see_the_same_rects`)

    @Test("few_and_many_reads_see_the_same_rects")
    func fewAndManyReadsSeeTheSameRects() {
        final class SeenBox {
            var seen: [[Float]?] = []
        }
        struct Cells {
            var width: Float
            var reads: Int
            var seen: SeenBox
        }

        for reads in [2, 12] {
            let box = SeenBox()
            let rt = Runtime<Cells>(
                state: Cells(width: 20.0, reads: reads, seen: box),
                viewport: Vec2(400.0, 200.0),
                pixelScale: 1.0
            ) { s, cx in
                var seen: [[Float]?] = (0..<s.reads).map { i in cx.layoutSize("cell\(i)") }
                seen.append(cx.layoutSize("panel/cell3"))
                seen.append(cx.layoutSize("missing"))
                s.seen.seen = seen
                func makeCells(_ w: Float) -> [El<Cells>] {
                    (0..<12).map { i in el().key("cell\(i)").w(w + Float(i)).h(10.0) }
                }
                return col()
                    .child(row().key("other").children(makeCells(1.0)))
                    .child(row().key("panel").children(makeCells(s.width)))
            }
            _ = rt.frame(at: 0.0)
            _ = rt.frame(at: 1.0 / 60.0)
            rt.update(at: 2.0 / 60.0) { s, _ in s.width = 30.0 }
            for step in 0..<3 {
                _ = rt.frame(at: Double(step + 3) / 60.0)
            }
            let seen = box.seen
            #expect(seen.count == reads + 2)
            for i in 0..<reads {
                #expect(seen[i] == [1.0 + Float(i), 10.0], "\(reads) reads: cell\(i) resolves first keyed sibling")
            }
            #expect(seen[reads] == [33.0, 10.0], "\(reads) reads: scoped selector finds panel cell")
            #expect(seen[reads + 1] == nil, "\(reads) reads: missing returns nil")
        }
    }
}
