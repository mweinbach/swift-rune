import Foundation
import Testing
@testable import Rune
@testable import RuneRef

@Suite("El Slice AutoGrow and TerminalGrid Paint Parity")
struct ElSliceAutoGrowAndGridPaintTests {
    private static let lineH: Float = 20.0

    private struct AutoGrowState {
        var draft: TextEdit
    }

    private func autoGrowView(_ s: AutoGrowState, _: inout Cx<AutoGrowState>) -> El<AutoGrowState> {
        let field = textInput(key: "input", \AutoGrowState.draft)
            .font(TextStyle(size: 14.0, weight: 400.0, lineHeight: Self.lineH))
            .wFull()
            .focused(true)

        return col()
            .wFull()
            .hFull()
            .p(20.0)
            .child(
                col()
                    .key("composer")
                    .wFull()
                    .child(autoGrow(field, minLines: 2, maxLines: 4))
            )
    }

    private func find(_ rt: Runtime<AutoGrowState>, _ key: String) -> ElementInfo {
        guard let el = rt.element(byKey: key) else {
            fatalError("Missing element with key \(key)")
        }
        return el
    }

    private func newline(_ rt: Runtime<AutoGrowState>, _ text: String, t: inout Double) {
        let dt = 1.0 / 60.0
        _ = rt.keyDown(KeyEvent(key: .enter, mods: Mods(shift: true)), at: t)
        _ = rt.dispatchImeEvent(.commit(text), at: t)
        t += dt
        _ = rt.frame(at: t)
    }

    private func settle(_ rt: Runtime<AutoGrowState>, t: inout Double) {
        let dt = 1.0 / 60.0
        for _ in 0..<90 {
            t += dt
            _ = rt.frame(at: t)
        }
    }

    @Test("auto_grow: plain field fits lines, springs between heights, and scrolls with caret in view")
    func autoGrowFitsLinesSpringsAndScrollsWithCaretInView() {
        let draft = TextEdit("one", multiline: true)
        let rt = Runtime(
            state: AutoGrowState(draft: draft),
            viewport: Vec2(400.0, 400.0),
            pixelScale: 2.0,
            systemDark: true,
            view: autoGrowView
        )
        var t = 0.0
        _ = rt.frame(at: t)
        let inp = find(rt, "input")
        let clickPt = Vec2(inp.rect[0] + 5.0, inp.rect[1] + 5.0)
        t += 1.0 / 60.0
        rt.pointerDown(at: clickPt, at: t)
        rt.pointerUp(at: clickPt, at: t + 0.001)
        settle(rt, t: &t)
        #expect(find(rt, "composer").rect[3] == 2.0 * Self.lineH)

        newline(rt, "two", t: &t)
        newline(rt, "three", t: &t)
        let shell = find(rt, "composer")
        #expect(shell.target[3] == 3.0 * Self.lineH)
        #expect(shell.rect[3] > 2.0 * Self.lineH + 0.5 && shell.rect[3] < 3.0 * Self.lineH - 0.5)

        for n in 4...7 {
            newline(rt, "line \(n)", t: &t)
        }
        settle(rt, t: &t)
        #expect(find(rt, "composer").rect[3] == 4.0 * Self.lineH)

        let viewport = find(rt, "scroll")
        let input = find(rt, "input")
        let caret = input.caret
        #expect(caret != nil)
        if let caret {
            #expect(
                caret[1] >= viewport.rect[1] - 0.01 &&
                caret[1] + caret[3] <= viewport.rect[1] + viewport.rect[3] + 0.01
            )
        }
    }

    @Test("TerminalGrid paints fills and glyphs and reuses per-row drawn cache across unchanged frames")
    func terminalGridPaintsPrimitivesAndReusesCache() {
        struct GridState {
            var row1Text: String = "done   "
        }

        let style = TextStyle(size: 12, weight: 400, lineHeight: 16, wrap: .noWrap)
        let row0 = TerminalGridRow(text: "ls -la", style: style)
            .fill(start: 0, end: 2, color: Color(r: 0, g: 0, b: 1, a: 1))
            .cell(column: 8, width: 2, text: "🚀", style: style, color: .white)

        let rt = Runtime<GridState>(state: GridState(), viewport: Vec2(300, 200), pixelScale: 2.0) { s, _ in
            let row1 = TerminalGridRow(text: s.row1Text, style: style)
            return col().itemsStart().child(
                terminalGrid(columns: 12, cellWidth: 8, cellHeight: 16, rows: [row0, row1])
                    .key("term")
            )
        }

        let scene0 = rt.frame(at: 0.0)
        let glyphs0 = scene0.primitives.filter { $0.kind == .glyph }
        let fills0 = scene0.primitives.filter { $0.kind == .roundedRect && $0.fill.z > 0.9 && $0.fill.x < 0.1 }
        #expect(!glyphs0.isEmpty, "TerminalGrid should emit glyph primitives")
        #expect(!fills0.isEmpty, "TerminalGrid row fill should emit a fill primitive")

        let stats0 = FrameStatsSidecar.get(rt)
        #expect(stats0.glyphs >= glyphs0.count)
        #expect(stats0.shaped > 0)

        let scene1 = rt.frame(at: 1.0 / 60.0)
        #expect(scene1.primitives == scene0.primitives)
        let stats1 = FrameStatsSidecar.get(rt)
        #expect(stats1.shaped == 0)

        rt.update(at: 2.0 / 60.0) { st, _ in
            st.row1Text = "updated"
        }
        let scene2 = rt.frame(at: 3.0 / 60.0)
        #expect(scene2.primitives != scene1.primitives)
        let fills2 = scene2.primitives.filter { $0.kind == .roundedRect && $0.fill.z > 0.9 && $0.fill.x < 0.1 }
        #expect(fills2 == fills0)

        // Copying and extending/mutating a previously painted TerminalGridRow must not return stale cached primitives.
        var extendedRow = row0.fill(start: 3, end: 5, color: Color(r: 0, g: 1, b: 0, a: 1))
        let rtCopy = Runtime<Bool>(state: false, viewport: Vec2(300, 200), pixelScale: 2.0) { useTextMutated, _ in
            let row = useTextMutated ? { var r = row0; r.text = "mutated"; return r }() : extendedRow
            return col().itemsStart().child(
                terminalGrid(columns: 12, cellWidth: 8, cellHeight: 16, rows: [row]).key("term")
            )
        }
        let copyScene0 = rtCopy.frame(at: 0.0)
        let greenFills = copyScene0.primitives.filter { $0.kind == .roundedRect && $0.fill.y > 0.9 && $0.fill.x < 0.1 }
        #expect(!greenFills.isEmpty, "extended row copy must not reuse stale unextended drawn cache")
        extendedRow.text = "unused"
        rtCopy.update(at: 1.0 / 60.0) { flag, _ in flag = true }
        let copyScene1 = rtCopy.frame(at: 1.0 / 60.0)
        #expect(copyScene1.primitives != copyScene0.primitives, "direct row struct mutation must invalidate row cache")
    }
}
