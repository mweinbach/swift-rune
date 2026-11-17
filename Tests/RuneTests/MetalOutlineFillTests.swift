import Testing
@testable import Rune

#if canImport(Metal)
@preconcurrency import Metal

@Suite("Metal resting glyph atlas")
struct MetalOutlineFillTests {
    @Test("An atlas tile composes cropped, partially overlapping glyphs in shaping order")
    func overlappingGlyphs() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let renderer = try MetalRenderer(), atlas = GlyphAtlas(width: 32, height: 32)
        atlas.defersOutlineMasks = true
        let size = SIMD2<Float>(18, 14)
        let fill = try #require(atlas.withOutlineStore { store -> OutlineFillParams? in
            let curve = store.glyph(.init(font: 1, glyph: 1)) {
                OutlineBuilder.build(commands: [
                    .moveTo(.zero), .lineTo(SIMD2(10, 0)), .quadTo(SIMD2(10, 9), SIMD2(0, 10)), .close
                ], upem: 12)
            }
            guard case let .outline(record) = curve else { return nil }
            let glyphs = [
                TextOutlineGlyph(rect: SIMD4(1, 1, 13, 12),
                    outline: GlyphOutline(pen: SIMD2(2.28, 11.63), scale: 1, zoom: 1, record: record.record)),
                TextOutlineGlyph(rect: SIMD4(3, 2, 8, 9),
                    outline: GlyphOutline(pen: SIMD2(2.64, 12.07), scale: 1, zoom: 1, record: record.record)),
            ]
            let group = TextOutlineGroup(size: size, glyphs: glyphs, smoothing: .windfoil, generation: store.generation)
            guard let tile = DesktopOutlineTile(group: group, width: Int(size.x), height: Int(size.y)) else { return nil }
            return store.fill(for: tile)
        })
        #expect(fill.coverage == 4)
        let entry = try #require(atlas.placeOutlineMask(width: Int(size.x), height: Int(size.y), fill: fill))
        let snapshot = atlas.framePages()
        let quad = RenderInstance(rect: SIMD4(0, 0, size.x, size.y), fill: SIMD4(repeating: 1),
            params: SIMD4(0, KIND_GLYPH, 0, 1), uv: SIMD4(Float(entry.pixelOrigin.x), Float(entry.pixelOrigin.y), 0, 0))
        var frame = RenderFrame(width: Int(size.x), height: Int(size.y), srgbBlend: true,
                                glyphs: snapshot.bases[0], instances: [quad])
        frame.glyphPageFills = snapshot.fills
        let actual = try renderer.renderOffscreen(frame).rgba
        let cpu = frame.glyphs
        let expected = (0..<Int(size.y)).flatMap { y in
            let row = (Int(entry.pixelOrigin.y) + y) * cpu.width + Int(entry.pixelOrigin.x)
            return cpu.texels[row..<(row + Int(size.x))]
        }
        let red = stride(from: 0, to: actual.count, by: 4).map { actual[$0] }
        #expect(expected.contains { $0 > 0 && $0 < 255 })
        #expect(zip(red, expected).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    }

    @Test("Replacing a frame's direct outlines preserves already placed resting masks")
    func replaceDirectOutlines() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let renderer = try MetalRenderer()
        let glyphs = GlyphAtlas(width: 32, height: 32)
        glyphs.defersOutlineMasks = true
        func box(_ store: OutlineStore, x: Double) -> OutlineStore.Glyph? {
            let shape = store.glyph(.init(font: 1, glyph: 1)) {
                OutlineBuilder.build(commands: [
                    .moveTo(SIMD2(x, 0)), .lineTo(SIMD2(x + 6, 0)),
                    .lineTo(SIMD2(x + 6, 8)), .lineTo(SIMD2(x, 8)), .close,
                ], upem: 12)
            }
            guard case let .outline(record) = shape else { return nil }
            return record
        }
        let record = try #require(glyphs.withOutlineStore { box($0, x: 0) })
        let entry = try #require(glyphs.placeOutlineMask(width: 12, height: 12,
            fill: .init(record: record.record, scale: 1, pen: SIMD2(1, 10))))
        let snap = glyphs.framePages()
        let external = OutlineStore()
        let other = try #require(box(external, x: 4))
        let mask = RenderInstance(rect: SIMD4(0, 0, 12, 12), fill: SIMD4(repeating: 1),
            params: SIMD4(0, KIND_GLYPH, 0, 1), uv: SIMD4(Float(entry.pixelOrigin.x), Float(entry.pixelOrigin.y), 0, 0))
        let direct = RenderInstance(rect: SIMD4(12, 0, 12, 12), radii: SIMD4(13, 10, 1, 1),
            fill: SIMD4(repeating: 1), border: SIMD4(Float(other.record), 0, 0, 0), params: SIMD4(0, KIND_GLYPH, 0, 1))
        var frame = RenderFrame(width: 24, height: 12, srgbBlend: true, glyphs: snap.bases[0],
                                instances: [mask, direct])
        frame.glyphPageFills = snap.fills
        frame.outlines = external.snapshot()
        let pixels = try renderer.renderOffscreen(frame)
        // The mask begins at x=1; the external shape begins at x=17.
        func red(_ x: Int) -> UInt8 { pixels.rgba[(5 * 24 + x) * 4] }
        #expect(red(2) == 255 && red(9) == 0 && red(14) == 0 && red(19) == 255)
    }
    @Test("An appended glyph fills once and separated mask pages match the CPU fallback")
    func fillsOnlyNewGlyphs() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let gpu = try MetalRenderer(), reference = try MetalRenderer()
        let atlas = GlyphAtlas(width: 26, height: 30)
        atlas.defersOutlineMasks = true
        let found = atlas.withOutlineStore { store in
            store.glyph(.init(font: 1, glyph: 1)) {
                OutlineBuilder.build(commands: [
                    .moveTo(SIMD2(0, 0)), .lineTo(SIMD2(9, 0)),
                    .quadTo(SIMD2(12, 6), SIMD2(5, 11)), .close,
                ], upem: 12)
            }
        }
        guard case let .outline(record) = found else { Issue.record("Fixture produced no curves"); return }
        var elements: [RenderInstance] = []
        for index in 0..<6 {
            if index == 1 {
                // A bitmap uploaded between deferred frames shares a row with the first
                // glyph. Its exact patch must preserve that already filled mask.
                let entry = try #require(atlas.placeMask(width: 6, height: 3, bitmap: Array(repeating: 173, count: 18)))
                elements.append(RenderInstance(rect: SIMD4(2, 13, 6, 3), fill: SIMD4(repeating: 1),
                                               params: SIMD4(0, KIND_GLYPH, Float(entry.page), 1),
                                               uv: SIMD4(Float(entry.pixelOrigin.x), Float(entry.pixelOrigin.y), 0, 0)))
            }
            if index == 5 {
                #expect(atlas.pageCount == 3)
                atlas.evictPage(0)
                elements.removeAll { $0.params.z == 0 }
            }
            let entry = try #require(atlas.placeOutlineMask(width: 15, height: 13, fill: .init(
                record: record.record, scale: 1, pen: SIMD2(2 + Float(index) * 0.1, 12.1)
            )))
            let p = entry.pixelOrigin
            elements.append(RenderInstance(rect: SIMD4(Float((index % 5) * 16), 0, 15, 13),
                                           fill: SIMD4(repeating: 1), params: SIMD4(0, KIND_GLYPH, Float(entry.page), 1),
                                           uv: SIMD4(Float(p.x), Float(p.y), 0, 0)))
            let snapshot = atlas.framePages()
            var frame = RenderFrame(width: 80, height: 16, srgbBlend: true, glyphs: snapshot.bases[0],
                                    glyphPages: snapshot.bases.count > 1 ? snapshot.bases : [],
                                    glyphGeneration: snapshot.generation, instances: elements)
            frame.glyphPageFills = snapshot.fills
            frame.glyphPageRevisions = snapshot.revisions
            frame.rawGlyphPageRevisions = snapshot.rawRevisions
            frame.glyphPagePatches = snapshot.patches
            frame.rawGlyphPagePatches = snapshot.rawPatches
            if index == 0 {
                var moving = frame
                moving.outlines = atlas.withOutlineStore { $0.snapshot() }
                moving.instances = [RenderInstance(rect: SIMD4(0, 0, 15, 13), radii: SIMD4(2, 12.1, 1, 1),
                                                   fill: SIMD4(repeating: 1), border: SIMD4(Float(record.record), 0, 0, 0),
                                                   params: SIMD4(0, KIND_GLYPH, 0, 1))]
                let direct = try gpu.renderOffscreen(moving)
                #expect(stride(from: 0, to: direct.rgba.count, by: 4).contains { direct.rgba[$0] == 255 })
                #expect(gpu.renderEngine.maskFill.maskCount == 0)
            }
            let pixels = try gpu.renderOffscreen(frame)
            let cold = RenderFrame(width: frame.width, height: frame.height, srgbBlend: true,
                                   glyphs: frame.glyphs, glyphPages: frame.glyphPages,
                                   glyphGeneration: frame.glyphGeneration, instances: elements)
            let cpuMasks = try reference.renderOffscreen(cold)
            let peak = zip(pixels.rgba, cpuMasks.rgba).map { abs(Int($0) - Int($1)) }.max()
            #expect((peak ?? 256) <= 1)
            #expect(stride(from: 0, to: pixels.rgba.count, by: 4).contains { pixels.rgba[$0] == 255 })
            #expect(gpu.renderEngine.maskFill.maskCount == UInt64(index + 1))
            _ = try gpu.renderOffscreen(frame)
            #expect(gpu.renderEngine.maskFill.maskCount == UInt64(index + 1))
        }
        #expect(atlas.pageCount == 3)
    }

    @Test("A 64-glyph fill uses the buffered upload and clears gutters around cropped ink")
    func fillsBufferedBatch() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let gpu = try MetalRenderer(), reference = try MetalRenderer(), store = OutlineStore()
        let resolved = store.glyph(.init(font: 1, glyph: 1)) {
            OutlineBuilder.build(commands: [.moveTo(SIMD2(0, 0)), .lineTo(SIMD2(10, 0)),
                                            .quadTo(SIMD2(13, 6), SIMD2(5, 11)), .close], upem: 12)
        }
        guard case let .outline(record) = resolved else { Issue.record("Fixture produced no curves"); return }
        let curves = try #require(store.snapshot())
        let base = R8Atlas(width: 288, height: 64, texels: Array(repeating: 173, count: 288 * 64))
        var jobs: [QueuedOutlineFill] = [], elements: [RenderInstance] = []
        for index in 0..<64 {
            let x = Float((index % 16) * 18 + 1), y = Float((index / 16) * 16 + 1)
            let width: UInt32 = index.isMultiple(of: 2) ? 7 : 15
            jobs.append(.init(rect: SIMD4(UInt32(x), UInt32(y), width, 13),
                              fill: .init(record: record.record, scale: 1, pen: SIMD2(1.5, 12))))
            // Magnifying each mask samples its one-texel transparent border.
            elements.append(RenderInstance(rect: SIMD4(x * 2, y * 2, Float(width) * 2, 26),
                                           fill: SIMD4(repeating: 1), params: SIMD4(0, KIND_GLYPH, 0, 1),
                                           uv: SIMD4(x, y, Float(width), 13)))
        }
        var frame = RenderFrame(width: base.width * 2, height: base.height * 2, srgbBlend: true,
                                glyphs: base, instances: elements)
        frame.maskFills = OutlineMaskPlan(base: base, curves: curves, fills: jobs, baseGeneration: 1, epoch: 0)
        let pixels = try gpu.renderOffscreen(frame)
        let raster = try reference.renderOffscreen(RenderFrame(width: frame.width, height: frame.height,
                                                               srgbBlend: true, glyphs: frame.glyphs, instances: elements))
        let peak = zip(pixels.rgba, raster.rgba).lazy.map { abs(Int($0) - Int($1)) }.max()
        #expect((peak ?? 256) <= 1)
        #expect(gpu.renderEngine.maskFill.maskCount == 64)
        #expect(gpu.renderEngine.maskFill.passes == 1)
        _ = try gpu.renderOffscreen(frame)
        #expect(gpu.renderEngine.maskFill.passes == 1)
    }
}
#endif
