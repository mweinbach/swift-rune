import Testing
@testable import Rune

@Suite("Deferred desktop glyph tiles")
struct DesktopOutlineTileTests {
    @Test("A mixed native tile selects the general curve shader")
    func unitWindfoilProfile() throws {
        let store = OutlineStore()
        let found = store.glyph(.init(font: 1, glyph: 1)) {
            OutlineBuilder.build(commands: [.moveTo(.zero), .lineTo(SIMD2(1, 0)),
                                            .lineTo(SIMD2(1, 1)), .close], upem: 1)
        }
        guard case let .outline(record) = found else { Issue.record("Fixture produced no curves"); return }
        let base = GlyphOutline(pen: SIMD2(1.25, 2.5), scale: 1, zoom: 1, record: record.record)
        var scaled = base, dilated = base, slug = base, hinted = base
        scaled.scale = 0.5
        dilated.radius = 0.1
        slug.coverage = 1
        hinted.hint = 1
        for other in [base, scaled, dilated, slug, hinted] {
            let glyphs = [base, other].map { TextOutlineGlyph(rect: SIMD4(0, 0, 3, 3), outline: $0) }
            let group = TextOutlineGroup(size: SIMD2(3, 3), glyphs: glyphs, smoothing: .windfoil, generation: store.generation)
            let tile = try #require(DesktopOutlineTile(group: group, width: 3, height: 3))
            let fill = try #require(store.fill(for: tile))
            let snapshot = try #require(store.snapshot())
            let queued = QueuedOutlineFill(rect: SIMD4(1, 1, 3, 3), fill: fill)
            #expect(queued.isUnitWindfoil(in: snapshot) == (other == base))
        }
    }

    @Test("Cell bounds retain a thin Slug feature whose box-filter fallback rounds to zero")
    func slugFringe() throws {
        let store = OutlineStore()
        let found = store.glyph(.init(font: 1, glyph: 1)) {
            OutlineBuilder.build(commands: [.moveTo(.zero), .lineTo(SIMD2(1, 0)), .lineTo(SIMD2(1, 1)),
                                            .lineTo(SIMD2(0, 1)), .close], upem: 1)
        }
        guard case let .outline(record) = found else { Issue.record("Fixture produced no curves"); return }
        let glyph = GlyphOutline(pen: SIMD2(2.49, 3.51), scale: 0.02, zoom: 1, record: record.record, coverage: 1)
        let part = TextOutlineGlyph(rect: SIMD4(2, 3, 1, 1), outline: glyph)
        let group = TextOutlineGroup(size: SIMD2(5, 6), glyphs: [part], smoothing: .slug, generation: store.generation)
        let tile = try #require(DesktopOutlineTile(group: group, width: 5, height: 6))
        let fill = try #require(tile.components.first?.fill)
        #expect(OutlineMaskFiller.fillMask(store: store, fill: fill, atX: 0, atY: 0, width: 1, height: 1) == [0])
        #expect(tile.coveredRows(columns: 2..<3, store: store) == 3..<4)
        #expect(tile.coveredRows(columns: 4..<5, store: store) == nil)
    }

    @Test("Combining glyphs preserve rounded source-over and exact rows of each cell")
    func croppedOverlappingGlyphs() throws {
        let store = OutlineStore(), width = 33, height = 19
        let found = store.glyph(.init(font: 1, glyph: 1)) {
            OutlineBuilder.build(commands: [.moveTo(SIMD2(0, 0)), .quadTo(SIMD2(8.5, 0.5), SIMD2(12, 8)),
                                            .lineTo(SIMD2(3.8, 11.5)), .close], upem: 12)
        }
        guard case let .outline(record) = found else { Issue.record("Fixture produced no curves"); return }
        func shape(_ pen: SIMD2<Float>, _ crop: SIMD4<Float>) -> TextOutlineGlyph {
            .init(rect: crop, outline: .init(pen: pen, scale: 1, zoom: 1, record: record.record))
        }
        let glyphs = [shape(SIMD2(1.25, 13.2), SIMD4(0, 1, 14, 14)),
                      shape(SIMD2(5.75, 14.5), SIMD4(6, 4, 10, 11)),
                      shape(SIMD2(21.6, 16.0), SIMD4(22, 4, 10, 13))]
        for count in 1...glyphs.count {
            let group = TextOutlineGroup(size: SIMD2(Float(width), Float(height)),
                                         glyphs: Array(glyphs.prefix(count)), smoothing: .windfoil, generation: store.generation)
            let tile = try #require(DesktopOutlineTile(group: group, width: width, height: height))
            let fill = try #require(store.fill(for: tile))
            var queued = QueuedOutlineFill(rect: SIMD4(1, 1, UInt32(width), UInt32(height)), fill: fill)
            if count == 1 { queued.crop = tile.components[0].rect }
            var expected = [UInt8](repeating: 0, count: width * height)
            var translucentOverlap = 0
            for part in tile.components {
                let r = part.rect
                let source = OutlineMaskFiller.fillMask(store: store, fill: part.fill, atX: 0, atY: 0,
                                                        width: UInt32(r.z), height: UInt32(r.w))
                for y in 0..<r.w {
                    for x in 0..<r.z {
                        let dst = (r.y + y) * width + r.x + x
                        let a = Int(source[y * r.z + x]), previous = Int(expected[dst])
                        if a > 0 && a < 255 && previous > 0 && previous < 255 { translucentOverlap += 1 }
                        expected[dst] = UInt8(a + (previous * (255 - a) + 127) / 255)
                    }
                }
            }
            #expect(queued.mask(in: store) == expected)
            if count > 1 { #expect(translucentOverlap > 0) }
            for start in 0..<width {
                for end in [start + 1, min(width, start + 7), width] {
                    let columns = start..<end
                    let occupied = (0..<height).filter { row in
                        expected[(row * width + start)..<(row * width + end)].contains { $0 != 0 }
                    }
                    let rows = occupied.first.map { $0..<(occupied.last! + 1) }
                    #expect(tile.coveredRows(columns: columns, store: store) == rows)
                }
            }
        }
    }
}
