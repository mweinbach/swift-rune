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
}
