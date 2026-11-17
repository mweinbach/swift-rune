import Testing
@testable import Rune

#if canImport(CoreText) && canImport(CoreGraphics)
@Suite("Retained glyph pen placements")
struct TextPlacementReuseTests {
    @Test("A translated fractional pen reuses its mask until its shelf is recycled")
    func translated() throws {
        let system = TextSystem()
        let atlas = system.glyphAtlas
        let scale: Float = 1.25
        let shaped = system.shape(text: "Ag", style: TextStyle(size: 16).smoothing(.windfoilChromium),
                                  maxWidth: nil, pixelScale: scale, emitGlyphs: true)
        let glyph = try #require(shaped.glyphs.first)
        let pen = try #require(shaped.glyphPens.first)
        func place(_ x: Float, using batch: TextBoxGeometry.GlyphPlacementBatch?) -> (Float, PositionedGlyph) {
            TextBoxGeometry.placedGlyph(glyph, pen: pen, originXPx: x, shapeScale: scale, atlas: atlas,
                                        placements: batch, index: 0)
        }
        let first = try #require(TextBoxGeometry.GlyphPlacementBatch(shaped: shaped, atlas: atlas, exact: true))
        let original = place(0, using: first)
        #expect(original.1.uv == glyph.uv)
        #expect(first.reusedTexels != .zero)
        let fractional = place(0.25, using: first)
        first.finish()
        let next = try #require(TextBoxGeometry.GlyphPlacementBatch(shaped: shaped, atlas: atlas, exact: true))
        let shifted = place(2.25, using: next)
        let expected = place(2.25, using: nil)
        #expect(shifted.0 == fractional.0 + 2)
        #expect(shifted.0 == expected.0 && shifted.1 == expected.1)
        #expect(shifted.1.uv == fractional.1.uv && next.reusedTexels != .zero)
        next.finish()
        atlas.evictPage(Int(glyph.atlasPage))
        #expect(TextBoxGeometry.GlyphPlacementBatch(shaped: shaped, atlas: atlas, exact: true) == nil)
    }

    @Test("Magnified outline placements require the same ppem and pen phase")
    func rasterBucket() throws {
        let system = TextSystem()
        let atlas = system.glyphAtlas
        let shaped = system.shape(text: "Ag", style: TextStyle(size: 16).smoothing(.windfoilChromium),
                                  maxWidth: nil, pixelScale: 1, emitGlyphs: true)
        let glyph = try #require(shaped.glyphs.first)
        func place(_ k: Float) throws -> (SIMD4<Float>, SIMD8<UInt32>) {
            let batch = try #require(TextBoxGeometry.GlyphPlacementBatch(shaped: shaped, atlas: atlas, exact: true))
            let raster = try #require(TextBoxGeometry.ScaledGlyphRaster(scale: k, still: false))
            var line = 0
            let (_, rect) = TextBoxGeometry.paintGlyph(glyph, index: 0, shaped: shaped, origin: .zero,
                scale: SIMD2(repeating: k), pixelScale: 1, restsExact: false, baselines: [], line: &line,
                atlas: atlas, raster: raster, placements: batch)
            batch.finish()
            return (rect, batch.reusedTexels)
        }
        let first = try place(1.4142)
        let same = try place(1.4142)
        let different = try place(1.6818)
        #expect(first.1 == .zero && same.1 != .zero && different.1 == .zero)
        #expect(first.0 == same.0 && first.0 != different.0)
    }

    @Test("A fresh paint independently resolves a retained pen against the resident atlas")
    func freshRaster() throws {
        let label: El<Int> = text("Ag").noWrap().selectable().size(120, 40).color(.white)
        let runtime = Runtime<Int>(state: 0, viewport: Vec2(160, 80), pixelScale: 1) { _, _ in label }
        runtime.setFontSmoothing(.off)
        let original = RasterCheck.glyphs(in: runtime.renderFrame(at: 0).instances)
        let frame = try #require(runtime.lastFrameOutput)
        let layout = runtime.textSystem.layoutKeyed(text: "Ag", style: label.textStyle, maxWidth: nil,
                                                     pixelScale: 1, emitGlyphs: true)
        #expect(original.count == 2)
        try #require(layout.shaped.glyphPens.count == 2)
        // The fresh path must resolve the bearing from the mask even when the shelf is still valid.
        layout.shaped.glyphPens[0].bearingX += 3
        let atlas = runtime.textSystem.glyphAtlas
        let placed = atlas.rasterized
        let settled = RasterCheck.glyphs(in: runtime.buildRenderFrame(frameOut: frame, now: 0).instances)
        let fresh = RasterCheck.glyphs(in: runtime.buildRenderFrame(frameOut: frame, now: 0, freshRaster: true).instances)
        #expect(settled.first?.rect.x == original.first.map { $0.rect.x + 3 })
        #expect(fresh == original)
        #expect(atlas.rasterized == placed)
    }
}
#endif
