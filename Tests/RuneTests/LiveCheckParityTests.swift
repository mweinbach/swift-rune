import Foundation
import Testing
@testable import Rune
import RuneMotion

/// Direct port of `crates/rune/src/runtime/live_check_tests.rs`.
@Suite("Rune Live Check Parity Tests (live_check_tests.rs)")
struct LiveCheckParityTests {
    private enum Side {
        case old
        case new
    }

    private struct RowsState {
        var copy: Side = .new
        var hovered: [Int] = []
        var changes: Int = 0
        var selections: Int = 0
    }

    private static let rowH: Float = 20.0
    private static func side(_ i: Int) -> Side { i % 4 == 3 ? .old : .new }
    private static func rowY(_ i: Int) -> Float { Float(i + 1) * rowH + rowH * 0.5 }

    private static func rowsApp() -> (rt: Runtime<RowsState>, now: Double) {
        let rt = Runtime<RowsState>(
            state: RowsState(),
            viewport: Vec2(400, 600),
            pixelScale: 2.0,
            systemDark: true
        ) { s, _ in
            let rows: [El<RowsState>] = (0..<24).map { i -> El<RowsState> in
                let sd = Self.side(i)
                let copy = s.copy == sd
                var t: El<RowsState> = text("let value_\(i) = compute(\(i));").key("text")
                if copy {
                    t = t.selectable(true).selectionStyle(SelectionStyle(highlight: .white))
                }
                let code = col().key("code").grow(1.0).minH(Self.rowH).child(t)
                    .onHover { state, inside, tx in
                        if inside {
                            state.hovered.append(i)
                        } else {
                            state.hovered.removeAll { $0 == i }
                        }
                        if inside && state.copy != sd {
                            state.copy = sd
                            state.changes += 1
                        } else {
                            tx.liveOnly()
                        }
                    }
                return row().key("r\(i)").wFull().minH(Self.rowH)
                    .bg(copy ? .black : .transparent)
                    .hover(Color.white.alpha(0.06)).hoverGroup()
                    .child(el().key("gutter").w(40).h(Self.rowH).child(text("\(i)").key("n").groupColor(.white)))
                    .child(code)
            }
            return col().wFull().hFull().scrollY(stickBottom: false)
                .child(text("\(s.selections) selections").key("selections"))
                .child(
                    col().key("rows").wFull().selectionGroup().children(rows)
                        .onSelectionChange { state, _, _ in
                            state.selections += 1
                        }
                )
        }
        var t = 0.0
        for _ in 0..<60 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        return (rt, t)
    }

    @Test("live_check_tests::hover_rows_at_rest_are_not_a_view_change")
    func hoverRowsAtRestAreNotAViewChange() {
        var (rt, t) = Self.rowsApp()
        for (n, i) in [0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14].enumerated() {
            t += (n < 6) ? 0.3 : (1.0 / 60.0)
            rt.pointerMove(to: Vec2(200, Self.rowY(i)), at: t)
            for _ in 0..<3 {
                t += 1.0 / 60.0
                _ = rt.frame(at: t)
            }
        }
        #expect(rt.liveChecks >= 6)
        #expect(rt.state.changes == 0)
        #expect(rt.liveOnlyWarnings.isEmpty, "\(rt.liveOnlyWarnings)")
    }

    @Test("live_check_tests::a_leave_and_an_enter_in_one_frame_blame_neither_when_the_enter_changes_state")
    func aLeaveAndAnEnterInOneFrameBlameNeitherWhenTheEnterChangesState() throws {
        var (rt, t) = Self.rowsApp()
        t += 0.3
        rt.pointerMove(to: Vec2(200, Self.rowY(2)), at: t)
        for _ in 0..<30 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        t += 0.3
        let checks = rt.liveChecks
        rt.pointerMove(to: Vec2(200, Self.rowY(3)), at: t)
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(rt.state.copy == .old)
        #expect(rt.state.changes == 1)
        #expect(rt.liveChecks - checks == 1)
        #expect(rt.liveOnlyWarnings.isEmpty, "\(rt.liveOnlyWarnings)")
        let r3 = try #require(rt.elements().first { $0.key == "r3" })
        let r3Bg = try #require(rt.nodeByPath[r3.path].map { rt.flatNodes[$0].el.background })
        #expect(r3Bg == .black)

        t += 0.3
        rt.pointerMove(to: Vec2(200, Self.rowY(4)), at: t)
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(rt.state.copy == .new)
        #expect(rt.state.changes == 2)
        #expect(rt.liveOnlyWarnings.isEmpty, "\(rt.liveOnlyWarnings)")
        let r4 = try #require(rt.elements().first { $0.key == "r4" })
        let r4Bg = try #require(rt.nodeByPath[r4.path].map { rt.flatNodes[$0].el.background })
        #expect(r4Bg == .black)
    }

    @Test("live_check_tests::dragging_a_text_selection_across_hover_rows_blames_no_hover_handler")
    func draggingATextSelectionAcrossHoverRowsBlamesNoHoverHandler() {
        var (rt, t) = Self.rowsApp()
        rt.pointerMove(to: Vec2(60, Self.rowY(0)), at: t)
        rt.pointerDown(at: Vec2(60, Self.rowY(0)), at: t)
        for _ in 0..<30 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        for i in [1, 2, 4, 5] {
            t += 0.3
            rt.pointerMove(to: Vec2(200, Self.rowY(i)), at: t)
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        rt.pointerUp(at: Vec2(200, Self.rowY(5)), at: t)
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(rt.state.selections > 1 && rt.liveChecks >= 4)
        #expect(rt.liveOnlyWarnings.isEmpty, "\(rt.liveOnlyWarnings)")
    }

    private struct CaseState {
        var kind: Int
        var changed: Bool = false
    }

    private static func caseApp(_ kind: Int) -> Runtime<CaseState> {
        let rt = Runtime<CaseState>(
            state: CaseState(kind: kind),
            viewport: Vec2(400, 400),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            let on = s.changed
            var c: El<CaseState> = col().key("list").w(200)
                .child(
                    el().key("box").w(on && s.kind == 0 ? 60 : 40).h(20)
                        .bg(on && s.kind == 1 ? .white : .black)
                )
                .child(
                    text(on && s.kind == 2 ? "a much longer label than the one before it, cut short" : "label")
                        .key("label").w(200).h(20)
                )
            if on && s.kind == 3 { c = c.child(el().key("extra").size(10, 10)) }
            if !(on && s.kind == 4) { c = c.child(el().key("tail").size(10, 10)) }
            return c
        }
        rt.globalOnKey = { (s: inout CaseState, _: KeyEvent, tx: inout Tx) in
            s.changed.toggle()
            tx.liveOnly()
            return true
        }
        _ = rt.frame(at: 0.0)
        return rt
    }

    @Test("live_check_tests::the_warning_names_the_element_and_property_that_differed")
    func theWarningNamesTheElementAndPropertyThatDiffered() throws {
        let wants = [
            #"layout rect of "{list}/@box" went from [0.0, 0.0, 40.0, 20.0] to [0.0, 0.0, 60.0, 20.0]"#,
            #"fill of "{list}/@box" went from #000000ff to #ffffffff"#,
            #"text of "{list}/@label" went from "label" to "a much longer label than the one before …""#,
            #"added element of "{list}/@extra""#,
            #"removed element of "{list}/@tail""#,
        ]
        for (kind, template) in wants.enumerated() {
            let rt = Self.caseApp(kind)
            let listPath = try #require(rt.elements().first { $0.key == "list" }).path
            let want = template.replacingOccurrences(of: "{list}", with: listPath)
            _ = rt.frame(at: 0.5)
            _ = rt.keyDown(KeyEvent(key: .arrowRight), at: 0.5)
            _ = rt.frame(at: 0.5 + 1.0 / 60.0)
            #expect(rt.liveOnlyWarnings.count == 1, "case \(kind): \(rt.liveOnlyWarnings)")
            let w = rt.liveOnlyWarnings[0]
            #expect(w.contains("called Tx::liveOnly, but the view built something else after it: "), "\(w)")
            #expect(w.contains(want), "case \(kind): \(w) | wanted \(want)")
        }
    }

    @Test("live_check_tests::the_warning_repeats_only_for_another_element_or_property")
    func theWarningRepeatsOnlyForAnotherElementOrProperty() throws {
        let rt = Self.caseApp(1)
        var t = 0.0
        for _ in 0..<4 {
            t += 0.5
            _ = rt.keyDown(KeyEvent(key: .arrowRight), at: t)
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        #expect(rt.liveChecks == 4)
        #expect(rt.liveOnlyWarnings.count == 1)
        rt.state.kind = 0
        t += 0.5
        _ = rt.keyDown(KeyEvent(key: .arrowRight), at: t)
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(rt.liveOnlyWarnings.count == 2)
        let listPath = try #require(rt.elements().first { $0.key == "list" }).path
        #expect(rt.liveOnlyWarnings[1].contains(#"layout rect of "\#(listPath)/@box""#))
    }

    @Test("live_check_tests::a_selection_handler_after_a_checked_event_is_not_blamed_on_it")
    func aSelectionHandlerAfterACheckedEventIsNotBlamedOnIt() throws {
        struct SelState { var heard: UInt32 = 0 }
        let rt = Runtime<SelState>(
            state: SelState(),
            viewport: Vec2(400, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col().w(400)
                .child(
                    text("some selectable words to drag across").key("t").w(400).selectable()
                        .onSelectionChange { state, _, _ in state.heard += 1 }
                )
                .child(text("\(s.heard)").key("heard"))
        }
        rt.globalOnKey = { _, _, tx in
            tx.liveOnly()
            return true
        }
        var t = 0.0
        _ = rt.frame(at: t)
        let elT = try #require(rt.elements().first { $0.key == "t" })
        let cx = elT.rect[0] + elT.rect[2] * 0.5
        let cy = elT.rect[1] + elT.rect[3] * 0.5
        rt.pointerDown(at: Vec2(cx - 150, cy), at: t)
        rt.pointerMove(to: Vec2(cx - 100, cy), at: t)
        for _ in 0..<30 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        t += 0.5
        let heard = rt.state.heard
        let checks = rt.liveChecks
        _ = rt.keyDown(KeyEvent(key: .f(5)), at: t)
        rt.pointerMove(to: Vec2(cx + 100, cy), at: t)
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(rt.liveChecks - checks == 1)
        #expect(rt.state.heard > heard)
        #expect(rt.liveOnlyWarnings.isEmpty, "\(rt.liveOnlyWarnings)")
    }

    private struct LongState {
        var hovers: UInt32 = 0
        var staleFrom: Int
    }

    private static func longApp(staleFrom: Int) -> (rt: Runtime<LongState>, now: Double) {
        let rt = Runtime<LongState>(
            state: LongState(staleFrom: staleFrom),
            viewport: Vec2(400, 300),
            pixelScale: 2.0,
            systemDark: true
        ) { _, _ in
            let list: El<LongState> = col().key("rows").wFull().growth(.default)
                .virtualRows(count: 2000, estimatedRowHeight: Self.rowH, key: { _, i in "r\(i)" }) { s, i in
                    let label = i >= s.staleFrom ? "\(i): \(s.hovers)" : "\(i)"
                    return col().wFull().h(Self.rowH).child(
                        text(label).key("cell").wFull().h(Self.rowH)
                            .onHover { st, _, tx in
                                if st.staleFrom < 2000 { st.hovers += 1 }
                                tx.liveOnly()
                            }
                    )
                }
            return col().wFull().hFull()
                .child(col().key("scroll").wFull().grow(1.0).minH(0.0).scrollY(stickBottom: false).child(list))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        for _ in 0..<60 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        return (rt, t)
    }

    @Test("live_check_tests::a_grown_viewport_does_not_make_the_overscan_a_view_change")
    func aGrownViewportDoesNotMakeTheOverscanAViewChange() {
        var (rt, t) = Self.longApp(staleFrom: .max)
        for (row, h) in [Float(310), 330, 360, 400].enumerated() {
            let checks = rt.liveChecks
            rt.setViewport(Vec2(400, h), pixelScale: 2.0)
            for _ in 0..<10 {
                t += 1.0 / 60.0
                _ = rt.frame(at: t)
            }
            t += 0.3
            rt.pointerMove(to: Vec2(200, (Float(row) + 0.5) * Self.rowH), at: t)
            for _ in 0..<3 {
                t += 1.0 / 60.0
                _ = rt.frame(at: t)
            }
            #expect(rt.liveChecks > checks, "viewport \(h): the hover was checked")
        }
        #expect(rt.liveOnlyWarnings.isEmpty, "\(rt.liveOnlyWarnings)")
    }

    @Test("live_check_tests::a_stale_row_mounted_below_the_viewport_still_warns_after_the_viewport_grows")
    func aStaleRowMountedBelowTheViewportStillWarnsAfterTheViewportGrows() {
        var (rt, t) = Self.longApp(staleFrom: 30)
        rt.setViewport(Vec2(400, 360), pixelScale: 2.0)
        for _ in 0..<10 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        t += 0.3
        rt.pointerMove(to: Vec2(200, 45), at: t)
        for _ in 0..<3 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        #expect(rt.liveOnlyWarnings.count == 1, "\(rt.liveOnlyWarnings)")
        let w = rt.liveOnlyWarnings[0]
        #expect(w.contains("text of") && w.contains("/@rows/@r30/@cell"), "\(w)")
    }
}
