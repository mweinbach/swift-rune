import Foundation
import Testing
@testable import Rune

@Suite("PaintGrid & PaintBands Parity Tests", .serialized)
struct PaintGridAndBandsParityTests {
    private static func bandWindows(_ instances: [RenderInstance], grow: Float) -> [SIMD4<Float>] {
        instances.map { i in
            #expect(i.uv.z < 0, "every band carries negative uv.z mark")
            let x = i.rect.x
            let y = i.rect.y
            let w = i.rect.z
            let h = i.rect.w
            return SIMD4<Float>(
                max(x - grow, x + i.uv.x),
                max(y - grow, y + i.uv.y),
                min(x + w + grow, x - i.uv.z),
                min(y + h + grow, y + i.uv.w)
            )
        }
    }

    private static func rectArea(_ r: SIMD4<Float>) -> Float {
        max(0, r.z - r.x) * max(0, r.w - r.y)
    }

    private static func gridRow(_ text: String, index: Int) -> TerminalGridRow {
        let style = TextStyle(size: 14, weight: 400).lh(18)
        let red = Color(r: 0.8, g: 0.1, b: 0.1, a: 1.0)
        let prefixCount = min(text.count, 4)
        let prefix = String(text.prefix(prefixCount))
        let rest = String(text.dropFirst(prefixCount))
        return TerminalGridRow(
            text: text,
            spans: [TextSpan(prefix, color: red), TextSpan(rest)],
            style: style
        )
        .fill(start: 0, end: 3 + index, color: Color(r: 0.1, g: 0.2, b: 0.3, a: 1.0))
        .cell(column: 20, width: 2, text: "日", style: style, color: .white)
    }

    @Test("bands_tests: large shadow, small shadow, pre-hole shadow, and border ring bands match upstream")
    func bandsParityTests() {
        func makeShadow(_ rect: SIMD4<Float>, sigma: Float) -> RenderInstance {
            RenderInstance(
                rect: rect,
                radii: SIMD4<Float>(repeating: 16),
                fill: SIMD4<Float>(0, 0, 0, 0.3),
                border: .zero,
                params: SIMD4<Float>(0, KIND_SHADOW, sigma, 1),
                uv: .zero,
                clip: NO_CLIP,
                fade: .zero
            )
        }

        // 1. a_big_shadow_draws_as_four_bands_around_the_box
        var bigOut: [RenderInstance] = []
        var bigMarks: [UInt32] = []
        let whole = makeShadow(SIMD4<Float>(100, 104, 1000, 600), sigma: 4)
        let caster = SIMD4<Float>(100, 100, 1000, 600)
        PaintBands.pushShadow(into: &bigOut, marks: &bigMarks, inst: whole, caster: caster, radii: SIMD4<Float>(repeating: 16))
        #expect(bigOut.count == 4)
        let shadowGrow: Float = 4.0 * 3.0 + 1.0
        let shadowBands = Self.bandWindows(bigOut, grow: shadowGrow)
        let quad = SIMD4<Float>(100 - shadowGrow, 104 - shadowGrow, 1100 + shadowGrow, 704 + shadowGrow)
        let hole = SIMD4<Float>(117, 117, 1083, 683)
        let totalArea = shadowBands.map(Self.rectArea).reduce(0, +)
        #expect(abs(totalArea - (Self.rectArea(quad) - Self.rectArea(hole))) < 0.5)
        for aIdx in 0..<shadowBands.count {
            for bIdx in (aIdx + 1)..<shadowBands.count {
                let a = shadowBands[aIdx], b = shadowBands[bIdx]
                let inter = SIMD4<Float>(max(a.x, b.x), max(a.y, b.y), min(a.z, b.z), min(a.w, b.w))
                #expect(Self.rectArea(inter) == 0)
            }
            let b = bigOut[aIdx]
            #expect(b.rect == whole.rect && b.radii == whole.radii && b.fill == whole.fill && b.params == whole.params && b.clip == whole.clip)
        }

        // 2. a_small_shadow_stays_one_quad
        var smallOut: [RenderInstance] = []
        var smallMarks: [UInt32] = []
        PaintBands.pushShadow(
            into: &smallOut,
            marks: &smallMarks,
            inst: makeShadow(SIMD4<Float>(0, 2, 120, 80), sigma: 4),
            caster: SIMD4<Float>(0, 0, 120, 80),
            radii: SIMD4<Float>(repeating: 8)
        )
        #expect(smallOut.count == 1)
        #expect(smallOut[0].uv == .zero)

        // 3. a_shadow_with_a_hole_already_stays_one_quad
        var holedOut: [RenderInstance] = []
        var holedMarks: [UInt32] = []
        var preHoled = makeShadow(SIMD4<Float>(0, 0, 1000, 600), sigma: 4)
        preHoled.uv = SIMD4<Float>(0, 0, 1000, 600)
        PaintBands.pushShadow(
            into: &holedOut,
            marks: &holedMarks,
            inst: preHoled,
            caster: SIMD4<Float>(0, 0, 1000, 600),
            radii: SIMD4<Float>(repeating: 8)
        )
        #expect(holedOut.count == 1)

        // 4. a_big_border_ring_draws_as_bands_and_a_filled_box_never_asks
        var ringOut: [RenderInstance] = []
        var ringMarks: [UInt32] = []
        let ring = RenderInstance(
            rect: SIMD4<Float>(10, 10, 800, 500),
            radii: SIMD4<Float>(repeating: -16),
            fill: .zero,
            border: .one,
            params: SIMD4<Float>(1, KIND_RECT, 0, 1),
            uv: .zero,
            clip: NO_CLIP,
            fade: .zero
        )
        PaintBands.pushRing(into: &ringOut, marks: &ringMarks, inst: ring)
        #expect(ringOut.count == 4)
        let ringBands = Self.bandWindows(ringOut, grow: 1.0)
        let e = 16.0 * CONTINUOUS_K + 1.0 + 0.5 + 1.0
        let ringHole = SIMD4<Float>(10 + e, 10 + e, 810 - e, 510 - e)
        let ringTotal = ringBands.map(Self.rectArea).reduce(0, +)
        let fullQuadArea = Self.rectArea(SIMD4<Float>(9, 9, 811, 511))
        #expect(abs(ringTotal - (fullQuadArea - Self.rectArea(ringHole))) < 1.0)

        // Verify Runtime.renderFrame splits a big unfilled border ring into 4 bands,
        // while a filled bordered box stays 1 rect quad.
        let rtBorder = Runtime<Bool>(state: false, viewport: Vec2(900, 600), pixelScale: 1.0) { filled, _ in
            let box = El<Bool>().size(800, 500).border(1, .white).rounded(16)
            return filled ? box.bg(.srgb(0.2, 0.2, 0.2)) : box
        }
        let rfUnfilled = rtBorder.renderFrame(at: 0)
        let unfilledBands = rfUnfilled.instances.filter { $0.params.y == KIND_RECT && $0.uv.z < 0 }
        #expect(unfilledBands.count == 4)

        rtBorder.update(at: 0.02) { s, _ in s = true }
        let rfFilled = rtBorder.renderFrame(at: 0.03)
        let filledQuads = rfFilled.instances.filter { $0.params.y == KIND_RECT }
        #expect(filledQuads.count == 1)
        #expect(filledQuads[0].uv == .zero)
    }

    @Test("paint/grid.rs & grid_tests: unchanged screen redraws identically and changed row matches fresh runtime")
    func paintGridCachingAndRowParity() {
        let initialRows = (0..<6).map { Self.gridRow("line \($0) of output", index: $0) }
        let rt = Runtime<[TerminalGridRow]>(state: initialRows, viewport: Vec2(240, 140), pixelScale: 1.5) { rows, _ in
            col().wFull().hFull().child(
                terminalGrid(columns: 24, cellWidth: 8.0, cellHeight: 18.0, rows: rows)
                    .w(192.0)
                    .h(18.0 * Float(rows.count))
            )
        }

        let firstFrame = rt.renderFrame(at: 0.0)
        let firstGlyphs = firstFrame.instances.filter { $0.params.y == KIND_GLYPH }
        let firstRects = firstFrame.instances.filter { $0.params.y == KIND_RECT }
        #expect(firstRects.count >= 6)
        #expect(firstGlyphs.count > 6 * 4)

        // 1. an_unchanged_screen_draws_what_it_drew
        rt.invalidate()
        let secondFrame = rt.renderFrame(at: 1.0 / 60.0)
        #expect(secondFrame.instances == firstFrame.instances)

        // 2. one_changed_row_draws_as_a_fresh_screen_would
        let replacement = Self.gridRow("a new third line", index: 9)
        rt.update(at: 1.0 / 60.0) { rows, _ in
            rows[2] = replacement
        }
        let updatedFrame = rt.renderFrame(at: 2.0 / 60.0)

        var freshRows = (0..<6).map { Self.gridRow("line \($0) of output", index: $0) }
        freshRows[2] = Self.gridRow("a new third line", index: 9)
        let freshRt = Runtime<[TerminalGridRow]>(state: freshRows, viewport: Vec2(240, 140), pixelScale: 1.5) { rows, _ in
            col().wFull().hFull().child(
                terminalGrid(columns: 24, cellWidth: 8.0, cellHeight: 18.0, rows: rows)
                    .w(192.0)
                    .h(18.0 * Float(rows.count))
            )
        }
        let freshFrame = freshRt.renderFrame(at: 0.0)

        struct Placed: Equatable {
            var rect: SIMD4<Float>
            var fill: SIMD4<Float>
            var kind: Float
            var clip: SIMD4<Float>
        }
        let placedUpdated = updatedFrame.instances.map { Placed(rect: $0.rect, fill: $0.fill, kind: $0.params.y, clip: $0.clip) }
        let placedFresh = freshFrame.instances.map { Placed(rect: $0.rect, fill: $0.fill, kind: $0.params.y, clip: $0.clip) }
        #expect(placedUpdated == placedFresh)

        // 3. Overlay shape & viewport culling work on terminalGrid rows
        var shapedRow = Self.gridRow("shaped", index: 1)
            .shape(Shape().line(Vec2(0, 17), Vec2(48, 17), width: 1.5, cap: .round, color: .white))
        shapedRow.fills = [TerminalGridFill(startColumn: 0, endColumn: 2, color: .srgb(0, 0.5, 0))]
        let rtShaped = Runtime<Int>(state: 0, viewport: Vec2(200, 40), pixelScale: 1.0) { _, _ in
            terminalGrid(columns: 24, cellWidth: 8.0, cellHeight: 18.0, rows: [shapedRow]).w(192).h(18)
        }
        let shapedFrame = rtShaped.renderFrame(at: 0.0)
        #expect(shapedFrame.instances.contains { $0.params.y == KIND_SEGMENT })
    }
}
