import Testing
@testable import Rune

#if canImport(CoreText) && canImport(CoreGraphics)
@Suite("Retained glyph pen placements")
struct TextPlacementReuseTests {
    @Test("A raw text layout keeps neutral masks after the renderer supplies explicit glyph inks")
    func coreTextPaintScopesRespectNeutralGlyphGeometry() throws {
        for mode in [FontSmoothing.on, .windfoil] where mode.pipeline.dilate {
            for keyed in [false, true] {
                let system = TextSystem()
                let style = TextStyle(size: 18, family: .monospace).smoothing(mode)
                let spans = [TextSpan("T", color: .white), TextSpan("T", color: .black)]
                func glyphs(_ spans: [TextSpan]?) -> [PositionedGlyph] {
                    if keyed {
                        return system.layoutKeyed(text: "TT", spans: spans, style: style, maxWidth: nil,
                                                  pixelScale: 1, emitGlyphs: true).shaped.glyphs
                    }
                    return system.shape(text: "TT", spans: spans, style: style, maxWidth: nil, pixelScale: 1).glyphs
                }
                let painted = GlyphAtlas.withBaseInk(.black, mode: mode) { glyphs(spans) }
                let plain = glyphs(nil)
                let neutral = glyphs(spans)
                try #require(painted.count == 2 && plain.count == 2 && neutral.count == 2)
                #expect(painted[0].uv != plain[0].uv)
                #expect(painted[1].uv == plain[1].uv)
                #expect(neutral.map(\.uv) == plain.map(\.uv))
                #expect(neutral.map(\.rect) == plain.map(\.rect))
                #expect(neutral.map(\.color) == [.white, .black])
                let (white, rect) = system.glyphAtlas.outlineInk(neutral[0], rect: neutral[0].rect, bucket: 4)
                #expect(white.uv == painted[0].uv && rect == painted[0].rect)
            }
        }
    }

    @Test("Warmed layout and fractional placement track changes to the scoped base and span inks")
    func alternatingPaintScopes() throws {
        for mode in [FontSmoothing.on, .windfoil] where mode.pipeline.dilate {
            let system = TextSystem()
            let atlas = system.glyphAtlas
            let style = TextStyle(size: 18, family: .monospace).smoothing(mode)
            func layout(_ explicit: Color?) -> ShapedText {
                system.layoutKeyed(text: "TT", spans: [TextSpan("T"), TextSpan("T", color: explicit)],
                                   style: style, maxWidth: nil, pixelScale: 1, emitGlyphs: true).shaped
            }
            let raw = layout(nil)
            try #require(raw.glyphs.count == 2 && raw.glyphPens.count == 2)
            let count = system.shapedCount
            for (base, span) in [(Color.white, Color.black), (.black, .white), (.white, .black)] {
                let painted = GlyphAtlas.withBaseInk(base, mode: mode) { layout(span) }
                let batch = try #require(TextBoxGeometry.GlyphPlacementBatch(shaped: painted, atlas: atlas, exact: true))
                defer { batch.finish() }
                for (index, ink) in [base, span].enumerated() {
                    let bucket: UInt8 = ink == .white ? 4 : 0
                    let original = raw.glyphs[index]
                    let (expected, rect) = atlas.outlineInk(original, rect: original.rect, bucket: bucket)
                    #expect(painted.glyphs[index].uv == expected.uv)
                    #expect(painted.glyphs[index].rect == rect)
                    let rawPlaced = TextBoxGeometry.placedGlyph(original, pen: raw.glyphPens[index],
                        originXPx: 0.25, shapeScale: 1, atlas: atlas)
                    var bounds = rawPlaced.glyph.rect
                    bounds.x = rawPlaced.xPx
                    let (shifted, shiftedRect) = atlas.outlineInk(rawPlaced.glyph, rect: bounds, bucket: bucket)
                    let placed = TextBoxGeometry.placedGlyph(painted.glyphs[index], pen: painted.glyphPens[index],
                        originXPx: 0.25, shapeScale: 1, atlas: atlas, placements: batch, index: index)
                    #expect(placed.glyph.uv == shifted.uv)
                    #expect(placed.xPx == shiftedRect.x)
                }
                #expect(layout(span).glyphs.map(\.uv) == raw.glyphs.map(\.uv))
                #expect(layout(nil).glyphs.map(\.rect) == raw.glyphs.map(\.rect))
            }
            #expect(system.shapedCount == count)
        }
    }

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
