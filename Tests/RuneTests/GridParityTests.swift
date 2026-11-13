import Foundation
import Testing
@testable import Rune
import RuneMotion
#if canImport(simd)
import simd
#endif

@Suite("TerminalGrid Paint Parity (crates/rune/src/runtime/grid_tests.rs)")
struct GridParityTests {
    private struct Screen {
        var rows: [TerminalGridRow]
    }

    private static func makeRow(_ text: String, _ k: Int) -> TerminalGridRow {
        let style = TextStyle(size: 14.0, weight: 400.0, lineHeight: 18.0)
        let splitIdx = text.index(text.startIndex, offsetBy: min(4, text.count))
        let head = String(text[..<splitIdx])
        let tail = String(text[splitIdx...])
        var spans: [TextSpan] = []
        if !head.isEmpty {
            spans.append(TextSpan(head, color: Color(r: 0.8, g: 0.1, b: 0.1, a: 1.0)))
        }
        if !tail.isEmpty {
            spans.append(TextSpan(tail))
        }
        return TerminalGridRow(text: text, spans: spans, style: style)
            .fill(start: 0, end: 3 + k, color: Color(r: 0.1, g: 0.2, b: 0.3, a: 1.0))
            .cell(column: 20, width: 2, text: "日", style: style, color: .white)
    }

    private static func makeView(_ s: Screen, _: inout Cx<Screen>) -> El<Screen> {
        col().wFull().hFull().child(
            terminalGrid(columns: 24, cellWidth: 8.0, cellHeight: 18.0, rows: s.rows)
                .w(192.0)
                .h(18.0 * Float(s.rows.count))
        )
    }

    private struct PlacedPrimitive: Equatable {
        var kind: Float
        var rect: SIMD4<Float>
        var fill: SIMD4<Float>
        var border: SIMD4<Float>
        var params: SIMD4<Float>
        var clip: SIMD4<Float>
        var fade: SIMD4<Float>
        var uvSize: SIMD2<Float>

        init(_ p: Primitive) {
            self.kind = p.params.y
            self.rect = p.rect
            self.fill = p.fill
            self.border = p.border
            self.params = p.params
            self.clip = p.clip
            self.fade = p.fade
            self.uvSize = SIMD2<Float>(p.uv.z - p.uv.x, p.uv.w - p.uv.y)
        }
    }

    private static func placed(_ scene: RefScene) -> [PlacedPrimitive] {
        scene.primitives.map(PlacedPrimitive.init)
    }

    @Test("an_unchanged_screen_draws_what_it_drew")
    func unchangedScreenDrawsWhatItDrew() {
        let rows = (0..<6).map { k in
            Self.makeRow("row \(k)    the prompt", k)
        }
        let rt = Runtime<Screen>(
            state: Screen(rows: rows),
            viewport: Vec2(240.0, 140.0),
            pixelScale: 1.5,
            view: Self.makeView
        )

        let first = rt.frame(at: 0.0)
        #expect(first.primitives.count > 6 * 4)

        rt.markNeedsCommit()
        let second = rt.frame(at: 1.0 / 60.0)
        #expect(second.primitives == first.primitives)
        #expect(rt.renderFrame(at: 1.0 / 60.0).instances == rt.renderFrame(at: 0.0).instances)
    }

    @Test("one_changed_row_draws_as_a_fresh_screen_would")
    func oneChangedRowDrawsAsFreshScreenWould() {
        let rows = (0..<6).map { k in
            Self.makeRow("row \(k)    the prompt", k)
        }
        let rt = Runtime<Screen>(
            state: Screen(rows: rows),
            viewport: Vec2(240.0, 140.0),
            pixelScale: 1.5,
            view: Self.makeView
        )
        _ = rt.frame(at: 0.0)

        var updatedRows = rows
        updatedRows[2] = Self.makeRow("a new third line", 9)
        rt.update(at: 1.0 / 60.0) { s, _ in
            s.rows[2] = Self.makeRow("a new third line", 9)
        }
        let updatedScene = rt.frame(at: 1.0 / 60.0)

        let fresh = Runtime<Screen>(
            state: Screen(rows: updatedRows),
            viewport: Vec2(240.0, 140.0),
            pixelScale: 1.5,
            view: Self.makeView
        )
        let freshScene = fresh.frame(at: 0.0)

        #expect(Self.placed(updatedScene) == Self.placed(freshScene))
    }
}
