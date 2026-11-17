import Foundation
import Testing
@testable import Rune

@Suite("PaintGrid & PaintBands Parity Tests", .serialized)
struct PaintGridAndBandsParityTests {
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

    @Test("A large gradient border draws a single ring of bands")
    func runtimeBorderBands() {
        let rtGradient = Runtime<Bool>(state: false, viewport: Vec2(900, 600), pixelScale: 1) { _, _ in
            El<Bool>().size(800, 500).border(1, .white).rounded(16).gradient(.black, .white)
        }
        let gradient = rtGradient.renderFrame(at: 0)
        let border = gradient.instances.filter { $0.params.y == KIND_RECT && $0.params.x > 0 }
        #expect(border.count == 4)
        #expect(border.allSatisfy { $0.uv.z < 0 })
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

    @Test("A fresh raster checks the same frame state and honors the requested font smoothing")
    func restingRasterCheck() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(160, 80), pixelScale: 1) { _, _ in
            text("Probe").size(120, 40).color(.white)
        }
        rt.setFontSmoothing(.off)
        #expect(rt.textSystem.smoothing == .off)
        _ = rt.renderFrame(at: 0)
        let revision = rt.textSystem.rasterRevision
        let existingLayouts = rt.textSystem.layoutKeys()
        let report = rt.checkRestingRaster(at: 0)
        #expect(report.isClean)
        #expect(report.freshGlyphCount > 0)
        #expect(rt.textSystem.rasterRevision > revision)
        #expect(rt.textSystem.layoutKeys() == existingLayouts)
        #expect(!RasterCheck.isEnabled(environment: ["RUNE_RASTER_CHECK": "0"]))
        #if DEBUG
        #expect(RasterCheck.isEnabled(environment: ["RUNE_RASTER_CHECK": "1"]))
        #endif
        let stretched = RenderInstance(
            rect: SIMD4<Float>(0, 0, 24, 16), radii: .zero, fill: .one, border: .zero,
            params: SIMD4<Float>(0, KIND_GLYPH, 0, 1), uv: SIMD4<Float>(0, 0, 12, 8),
            clip: NO_CLIP, fade: .zero
        )
        #expect(RasterCheck.magnifies(stretched))
        rt.setFontSmoothing(.systemDefault)
        #expect(rt.textSystem.smoothing == .platformDefault)
    }

    @Test("A fresh raster rebuilds placed glyphs in a full label and a clipped document")
    func freshPlacedGlyphs() throws {
        let system = TextSystem()
        system.smoothing = .off
        let style = TextStyle(size: 13)
        let lines = Array(repeating: "Probe", count: 36).joined(separator: "\n")
        let clipped = TextRasterWindow(lowerY: 96, upperY: 144)
        for (content, window) in [("Probe", nil as TextRasterWindow?), (lines, clipped)] {
            func layout(_ draw: Bool) -> TextLayoutBox {
                system.layoutKeyed(text: content, style: style, maxWidth: 80, pixelScale: 1,
                                   emitGlyphs: draw, rasterWindow: draw ? window : nil)
            }
            let previous = layout(true)
            let original = try #require(previous.shaped.glyphs.first).rect
            let shaped = system.shapedCount
            let prepared = system.cachedShapeCount
            let atlas = system.glyphAtlas.resets
            previous.shaped.glyphs[0].rect.x += 71
            #expect(layout(true) === previous)

            system.forgetRasterState()
            let measured = layout(false)
            #expect(!measured.hasGlyphs && measured.shaped.glyphs.isEmpty)
            #expect(measured.shaped.lineBaselinesPx == previous.shaped.lineBaselinesPx)
            let fresh = layout(true)
            #expect(fresh.shaped.glyphs.first?.rect == original)
            #expect(previous.shaped.glyphs[0].rect.x == original.x + 71)
            #expect(system.shapedCount == shaped && system.cachedShapeCount == prepared)
            #expect(system.glyphAtlas.resets == atlas)
        }
        system.beginOutlineFrame()
        #expect(system.outlinePaths.step(node: 1, frame: .moving).0 == .moving)
        system.forgetRasterState()
        system.beginOutlineFrame()
        #expect(system.outlinePaths.step(node: 1, frame: .resting).0 == .still)
    }
}
