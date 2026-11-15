import Testing
import Foundation
@testable import Rune
import RuneMotion

// Faithful ports of upstream `crates/rune/tests/selection_toolbar.rs:81`
// (`selection_rects_are_the_selected_lines_and_follow_scrolling`) and
// `crates/rune/tests/selection_rects_memo.rs:51/:56` (`selection_rects_find_text_in_a_reused_memo`
// and `..._under_hover_motion_within`). Both read `Cx.selectionRects()` (`src/runtime/selection/rects.rs:26`)
// from the view on every run and assert on the boxes the last run saw.

/// What each view run read from `Cx.selectionRects()` (upstream `thread_local! RECTS`).
private final class RectsLog: @unchecked Sendable {
    var runs: [[[Float]]] = []
    var last: [[Float]] { runs.last ?? [] }
}

/// Monotonic frame clock (upstream `tick` at 60 Hz).
private final class Clock: @unchecked Sendable {
    var t: Double = 0
}

// MARK: - selection_toolbar.rs

private struct ToolbarS {
    var heard: [(String?, Bool)] = []
    var presses: UInt32 = 0
    var readRects = false
    var field = TextEdit("")
    var backward: Bool? = nil
}

private let LONG = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu"

@Suite("selection_toolbar.rs / selection_rects_memo.rs: Cx.selectionRects parity", .serialized)
struct SelectionRectsParityTests {

    private func toolbarRuntime(_ log: RectsLog) -> Runtime<ToolbarS> {
        let rt = Runtime(state: ToolbarS(), viewport: Vec2(500, 500), pixelScale: 2.0, systemDark: true) {
            (s: ToolbarS, cx: inout Cx<ToolbarS>) -> El<ToolbarS> in
            if s.readRects { log.runs.append(cx.selectionRects()) }
            let style = TextStyle(size: 14, weight: 400).lh(20)
            func t(_ content: String, _ key: String) -> El<ToolbarS> {
                text(content).key(key).font(style).wFull().wrap(.wrap).selectable(true)
            }
            return col().wFull().hFull().p(10).gap(12)
                .child(
                    col().key("scroller").w(300).h(200).scroll(ScrollSpec(stickBottom: false)).child(
                        col().key("doc").w(280).gap(12).selectionGroup(true)
                            .onSelectionChange { st, c, _ in
                                st.heard.append((c.selection?.text, c.isDragging))
                                st.backward = c.selection?.backward
                            }
                            .child(t("first paragraph", "a"))
                            .child(t(LONG, "b"))
                            .child(col().wFull().h(400))
                    )
                )
                .child(
                    col().key("toolbar").w(80).h(24).keepsTextSelection().focusable(true)
                        .onClick { (st: inout ToolbarS) in st.presses += 1 }
                )
                .child(textInput(key: "field", \ToolbarS.field).font(style).singleLine().w(300))
        }
        _ = rt.frame(at: 0)
        return rt
    }

    private func tick<S>(_ rt: Runtime<S>, _ clock: Clock) {
        clock.t += 1.0 / 60.0
        _ = rt.frame(at: clock.t)
    }

    /// Code's selection is heard, and read, the frame after the handler's commit.
    private func act<S>(_ rt: Runtime<S>, _ clock: Clock, _ f: (inout Tx) -> Void) {
        rt.update { _, tx in f(&tx) }
        tick(rt, clock)
        tick(rt, clock)
    }

    private func rect<S>(_ rt: Runtime<S>, _ key: String) throws -> [Float] {
        try #require(rt.elements().first(where: { $0.key == key })?.rect)
    }

    @Test("selection_toolbar.rs:81 selection_rects_are_the_selected_lines_and_follow_scrolling")
    func selectionRectsAreTheSelectedLinesAndFollowScrolling() throws {
        let log = RectsLog()
        let clock = Clock()
        let rt = toolbarRuntime(log)
        rt.update { s, _ in s.readRects = true }
        tick(rt, clock)
        #expect(!log.runs.isEmpty, "the view reads the rects")
        #expect(log.last.isEmpty, "nothing selected")

        act(rt, clock) { $0.selectText("a", range: 0..<5) }
        let a = try rect(rt, "a")
        let one = log.last
        #expect(one.count == 1, "one line: \(one)")
        let r = try #require(one.first)
        #expect(abs(r[0] - a[0]) < 1.0 && r[2] > 10.0 && r[2] < a[2], "\(r) in \(a)")
        #expect(r[1] >= a[1] - 0.5 && r[1] + r[3] <= a[1] + a[3] + 0.5, "\(r) in \(a)")

        // Across texts: a box per line, in reading order.
        act(rt, clock) { $0.selectAllText("doc") }
        let boxes = log.last
        let b = try rect(rt, "b")
        #expect(boxes.count >= 3, "a's line and b's wrapped lines: \(boxes)")
        #expect(zip(boxes, boxes.dropFirst()).allSatisfy { $0[1] <= $1[1] }, "\(boxes)")
        #expect(boxes.last.map { $0[1] + $0[3] <= b[1] + b[3] + 0.5 } == true, "\(boxes)")

        // Scrolling moves them, and re-runs the view.
        let before = log.last
        let s = try rect(rt, "scroller")
        rt.wheel(WheelEvent(dx: 0, dy: -40), at: Vec2(s[0] + 10, s[1] + 10), now: clock.t)
        for _ in 0..<30 { tick(rt, clock) }
        let after = log.last
        #expect(after.count == before.count, "\(before) -> \(after)")
        let first = try #require(before.first)
        let firstAfter = try #require(after.first)
        let dy = first[1] - firstAfter[1]
        #expect(
            abs(dy) > 5.0 && zip(after, before).allSatisfy { abs($1[1] - $0[1] - dy) < 0.5 },
            "\(before) -> \(after)"
        )

        // Clearing empties them.
        act(rt, clock) { $0.clearTextSelection() }
        #expect(log.last.isEmpty)
    }

    // MARK: - selection_rects_memo.rs

    private struct MemoS {
        var within: Bool
        var other: UInt32 = 0
    }

    private func doc() -> El<MemoS> {
        let style = TextStyle(size: 14, weight: 400).lh(20)
        func t(_ content: String, _ key: String) -> El<MemoS> {
            text(content).key(key).font(style).wFull().wrap(.wrap).selectable(true)
        }
        return col().key("doc").w(280).gap(12).selectionGroup(true)
            .child(t("first paragraph", "a"))
            .child(t("second paragraph", "b"))
    }

    private func selectedThenRecommitted(within: Bool) {
        let log = RectsLog()
        let cache = MemoCache()
        let build: () -> El<MemoS> = { self.doc() }
        let rt = Runtime(state: MemoS(within: within), viewport: Vec2(400, 300), pixelScale: 2.0, systemDark: true) {
            (s: MemoS, cx: inout Cx<MemoS>) -> El<MemoS> in
            log.runs.append(cx.selectionRects())
            let root = col().key("root").wFull().hFull().p(10).gap(12)
                .child(memo("doc", 0, cache: cache, build: build))
                .child(text("\(s.other)").key("other"))
            // A view builds a new pair each run, as an app's root does.
            return s.within ? root.hoverMotionWithin(Anim<Float>.instant, Anim<Float>.instant) : root
        }
        let clock = Clock()
        tick(rt, clock)
        rt.update { _, tx in tx.selectText("a", range: 0..<5) }
        tick(rt, clock)
        tick(rt, clock)
        #expect(log.last.count == 1, "after the commit that selects: \(log.last)")
        rt.update { s, _ in s.other += 1 }
        tick(rt, clock)
        tick(rt, clock)
        #expect(log.last.count == 1, "after a later commit: \(log.last)")
    }

    @Test("selection_rects_memo.rs:51 selection_rects_find_text_in_a_reused_memo")
    func selectionRectsFindTextInAReusedMemo() {
        selectedThenRecommitted(within: false)
    }

    @Test("selection_rects_memo.rs:56 selection_rects_find_text_in_a_reused_memo_under_hover_motion_within")
    func selectionRectsFindTextInAReusedMemoUnderHoverMotionWithin() {
        selectedThenRecommitted(within: true)
    }
}
