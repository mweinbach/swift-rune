import Testing
@testable import Rune
#if canImport(CoreText) && canImport(CoreGraphics)
import CoreText
import CoreGraphics
#endif

@Suite struct GlyphAtlasLRUTests {
    @Test func iconsAndGlyphsShareRecencyAcrossHitsAndReclaims() {
        let atlas = GlyphAtlas(width: 512, height: 512, maxCachedEntries: 6)
        let icon = SVGIcon(viewBox: 16, paths: ["M0 0 L16 0 L16 16 L0 16 Z"])
        var recent: [Int] = []

        func read(_ key: Int) {
            let oldRasterized = atlas.rasterized
            let index = recent.firstIndex(of: key)
            if key.isMultiple(of: 2) {
                _ = atlas.rasterizePortableGlyph(scalar: "A", fontSizePx: Float(10 + key))
            } else {
                #expect(atlas.rasterizeIconIfPlaced(icon, pixelSize: 10 + key) != nil)
            }
            #expect(atlas.rasterized == oldRasterized + (index == nil ? 1 : 0))
            if let index { recent.remove(at: index) }
            recent.append(key)
            if recent.count > 6 { recent.removeFirst() }
            #expect(atlas.cachedEntryCount == recent.count)
        }

        for key in [0, 1, 2, 3, 4, 5, 6, 1, 2, 0, 3, 1, 7, 4, 0, 8] { read(key) }

        atlas.beginFrame()
        read(7)
        atlas.beginFrame()
        read(8)
        atlas.dropOrphans()
        recent = [7, 8]
        for key in [0, 1, 2, 3, 4, 8, 7, 5, 0, 2] { read(key) }

        atlas.evictPage(0)
        recent.removeAll()
        for key in [4, 3, 2, 1, 0, 7, 8, 3, 9, 4] { read(key) }
    }

    #if canImport(CoreText) && canImport(CoreGraphics)
    @Test func globalEvictionRetiresColorIndicesAndTheirBytes() throws {
        let atlas = GlyphAtlas(width: 256, height: 256, maxCachedEntries: 2)
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, 16, nil)
        var character: UniChar = 65
        var glyph: CGGlyph = 0
        try #require(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
        func color() throws -> GlyphAtlas.ColorGlyphEntry {
            try #require(atlas.rasterizeColorGlyph(font: font, glyph: glyph, fontSizePx: 16))
        }
        func mask(_ scalar: Unicode.Scalar) {
            _ = atlas.rasterizePortableGlyph(scalar: scalar, fontSizePx: 14)
        }

        let first = try color()
        mask("A")
        mask("B")
        #expect(atlas.colorGlyph(first.index) == nil)
        #expect(atlas.currentColorGlyphBytes == 0)

        let second = try color()
        #expect(second.index != first.index)
        mask("C")
        #expect(try color().index == second.index)
        mask("D")
        #expect(atlas.colorGlyph(second.index) == second)
        #expect(atlas.currentColorGlyphBytes == second.rgba.count)
        mask("E")
        #expect(atlas.colorGlyph(second.index) == nil)
        #expect(atlas.currentColorGlyphBytes == 0)
    }
    #endif
}
