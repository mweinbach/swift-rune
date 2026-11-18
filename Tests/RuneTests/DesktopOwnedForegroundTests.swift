#if os(Linux)
import CRuneDesktopText
import Testing
@testable import Rune

@Suite("Pango foreground coverage")
struct DesktopOwnedForegroundTests {
    private typealias Coverage = [SIMD2<Int>: UInt8]

    /// Read the exact A8 texels and screen rectangles that Rune gives its renderer.
    private func coverage(_ glyphs: [PositionedGlyph], at pen: Float, in atlas: GlyphAtlas) throws -> Coverage {
        let size = atlas.pagePixelSize
        var result: Coverage = [:]
        for glyph in glyphs {
            let page = try #require(atlas.pageData(Int(glyph.atlasPage)))
            let u = Int((glyph.uv.x * Float(size.x)).rounded())
            let v = Int((glyph.uv.y * Float(size.y)).rounded())
            let left = Int((glyph.rect.x + pen).rounded()), top = Int(glyph.rect.y.rounded())
            for y in 0..<Int(glyph.rect.w.rounded()) {
                for x in 0..<Int(glyph.rect.z.rounded()) {
                    let alpha = page[(v + y) * size.x + u + x]
                    if alpha > 0 { result[SIMD2(left + x, top + y)] = alpha }
                }
            }
        }
        return result
    }

    /// Pango's retained glyphs remain in line coordinates, with their italic bearings,
    /// ligatures and fallback faces intact. Shift that native mask to the tested pen.
    private func reference(_ line: OpaquePointer, left: Int, top: Int, phase: Int) throws -> Coverage {
        let bounds = rune_desktop_line_metrics(line)
        let width = Int(bounds.ink_width), height = Int(bounds.ink_height)
        guard width > 0, height > 0 else { return [:] }
        var mask = Array(repeating: UInt8(0), count: width * height)
        try #require(rune_desktop_line_mask(line, bounds.ink_x, bounds.ink_y,
                                            bounds.ink_width, bounds.ink_height, &mask) != 0)
        var result: Coverage = [:]
        for y in 0..<height {
            for x in 0...width {
                let current = x < width ? Int(mask[y * width + x]) : 0
                let previous = x > 0 ? Int(mask[y * width + x - 1]) : 0
                let alpha = UInt8((current * (60 - phase) + previous * phase + 30) / 60)
                if alpha > 0 { result[SIMD2(left + Int(bounds.ink_x) + x, top + Int(bounds.ink_y) + y)] = alpha }
            }
        }
        return result
    }

    @Test(arguments: ["fX", "لَب"])
    func foregroundFollowsOwnedGlyphPixelsThroughRecolorAndPlacement(_ value: String) throws {
        try withFontFamilies(sans: "", mono: "") {
            try checkForeground(value, size: 36)
            try checkForeground(value, size: 16)
        }
    }

    private func checkForeground(_ value: String, size: Float) throws {
        let system = TextSystem()
        let rtl = value != "fX"
        let style = TextStyle(size: size, italic: true, family: .custom(rtl ? "Inter" : "DejaVu Sans"),
                              fontSmoothing: .off, features: "liga=0", direction: rtl ? .rtl : .ltr)
        let red = Color.rgba8(196, 24, 35), blue = Color.rgba8(14, 58, 201)
        let first = String(value.prefix(1)), second = String(value.dropFirst())
        func shape(_ spans: [TextSpan]?) -> ShapedText {
            system.layoutKeyed(text: value, spans: spans, style: style, maxWidth: nil,
                               pixelScale: 1, emitGlyphs: true).shaped
        }
        let plain = shape(nil)
        let count = system.shapedCount
        let uniform = shape([TextSpan(first, color: red), TextSpan(second, color: red)])
        let firstPalette = shape([TextSpan(first, color: red), TextSpan(second, color: blue)])
        let secondPalette = shape([TextSpan(first, color: blue), TextSpan(second)])
        #expect(system.shapedCount == count)
        #expect(plain.size == firstPalette.size)
        #expect(plain.size == secondPalette.size)
        for (original, inks) in [(plain, [Color?]()), (uniform, [red]), (firstPalette, [red, blue]),
                                 (secondPalette, [blue, nil]), (firstPalette, [red, blue])] {
            let resting = try #require(original.desktopRestingText)
            let line = try #require(resting.qualityLine(at: 0))
            let firstCell = try #require(line.native.cells[0])
            let source = firstCell.qualityGlyphSource
            let runX = line.native.runOriginPx(for: firstCell, originX: line.originX)
            let top = Int((line.baselineY - source.ascent).rounded())
            for pen: Float in [0, 0.25, 0.75] {
                var placed = original
                let changed = resting.place(&placed, at: pen, atlas: system.glyphAtlas)
                let placement = changed ? TextBoxGeometry.glyphPen(at: runX + pen, ppem: style.size,
                                                                    glide: 0, smoothing: style.fontSmoothing)
                                        : (pixel: (runX + pen).rounded(), phase: 0)
                func compare(_ expected: OpaquePointer, against glyphs: [PositionedGlyph]) throws {
                    let wanted = try reference(expected, left: Int(placement.pixel), top: top, phase: Int(placement.phase))
                    let actual = try coverage(glyphs, at: pen, in: system.glyphAtlas)
                    let different = Set(wanted.keys).union(actual.keys).count { wanted[$0] != actual[$0] }
                    #expect(!wanted.isEmpty)
                    #expect(different == 0, "\(value), size \(size), pen \(pen), ink \(String(describing: glyphs.first?.color))")
                }
                if inks.count < 2 {
                    let ink = inks.first ?? nil
                    #expect(placed.glyphs.allSatisfy { $0.color == ink })
                    try compare(source.handle, against: placed.glyphs)
                } else {
                    for (byte, ink) in zip([0, first.utf8.count], inks) {
                        let cell = try #require(line.native.cells[byte])
                        let native = cell.qualityGlyphSource
                        let owned = try #require(rune_desktop_line_extract_ink(native.handle, native.bytes.lowerBound,
                                                                               native.bytes.upperBound))
                        defer { rune_desktop_line_destroy(owned) }
                        try compare(owned, against: placed.glyphs.filter { $0.color == ink })
                    }
                }
            }
        }
    }

    @Test func recoversAnOwnedMaskAfterOnlyItsAtlasPageWasReused() throws {
        let atlas = GlyphAtlas(width: 48, height: 36)
        let system = TextSystem(glyphAtlas: atlas)
        let style = TextStyle(size: 36, italic: true, family: .custom("DejaVu Sans"),
                              fontSmoothing: .off, features: "liga=0")
        let measured = system.layoutKeyed(text: "fX", style: style, maxWidth: nil, pixelScale: 1, emitGlyphs: true)
        let spans = [TextSpan("f", color: .white), TextSpan("X", color: .black)]
        let first = system.presentedLayout(measured, spans: spans)
        let neutralPages = Set(measured.shaped.glyphs.map(\.atlasPage))
        let ownedOnlyPages = Set(first.shaped.glyphs.map(\.atlasPage)).subtracting(neutralPages)
        try #require(!neutralPages.isEmpty && !ownedOnlyPages.isEmpty)
        let neutral = try coverage(measured.shaped.glyphs, at: 0, in: atlas)
        let expected = try spans.map { span in
            try coverage(first.shaped.glyphs.filter { $0.color == span.color }, at: 0, in: atlas)
        }

        let pinned = neutralPages.reduce(UInt32(0)) { $0 | (1 << $1) }
        let before = atlas.resets
        atlas.beginFrame(pinnedMask: pinned)
        atlas.beginFrame(pinnedMask: pinned)
        let overwritten = try #require(atlas.placeMask(width: 46, height: 34, bitmap: Array(repeating: 219, count: 46 * 34)))
        try #require(ownedOnlyPages.contains(overwritten.page) && atlas.resets > before)
        #expect(try coverage(measured.shaped.glyphs, at: 0, in: atlas) == neutral)
        let recovered = system.presentedLayout(measured, spans: spans)
        for (index, span) in spans.enumerated() {
            let pixels = try coverage(recovered.shaped.glyphs.filter { $0.color == span.color }, at: 0, in: atlas)
            let different = Set(expected[index].keys).union(pixels.keys).count { expected[index][$0] != pixels[$0] }
            #expect(!pixels.isEmpty && different == 0)
        }
    }

    @Test func scrolledFieldUsesDocumentInkAndKeepsParagraphGlyphOverhangs() throws {
        let system = TextSystem()
        let style = TextStyle(size: 36, italic: true, family: .custom("DejaVu Sans"), wrap: .wrap,
                              fontSmoothing: .off, features: "liga=0")
        let prefix = "é\n", suffix = "\nunseen"
        let ink = Color.rgba8(192, 28, 72)
        let request = ParagraphRequest(field: 7, forced: .ltr, startFlow: .ltr)
        func field(_ f: Color?, _ x: Color?) -> TextLayoutBox {
            system.layoutInput(text: prefix + "fX" + suffix,
                spans: [TextSpan(prefix), TextSpan("f", color: f), TextSpan("X", color: x), TextSpan(suffix)],
                pills: [], style: style, maxWidth: 240, pixelScale: 1, emitGlyphs: false, request: request)
        }
        let first = field(ink, nil), second = field(nil, ink)
        let layout = try #require(first.paragraphs)
        #expect(second.paragraphs === layout)
        let visible = layout.paragraphs[1]
        let center = visible.y + visible.height / 2
        for (box, markedByte) in [(first, 0), (second, 1), (first, 0)] {
            let drawn = layout.glyphs(top: center, bottom: center, using: system, inks: box.spanInks)
            #expect(Set(drawn.map(\.utf8Offset)) == [prefix.utf8.count, prefix.utf8.count + 1])
            let line = try #require(layout.paragraphs[1].layout.shaped.desktopRestingText?.qualityLine(at: 0))
            for byte in 0...1 {
                let cell = try #require(line.native.cells[byte])
                let native = cell.qualityGlyphSource
                let owned = try #require(rune_desktop_line_extract_ink(native.handle, native.bytes.lowerBound,
                                                                       native.bytes.upperBound))
                defer { rune_desktop_line_destroy(owned) }
                let wanted = try reference(owned, left: Int(line.native.runOriginPx(for: cell, originX: line.originX).rounded()),
                                           top: Int((visible.y + line.baselineY - native.ascent).rounded()), phase: 0)
                let color = byte == markedByte ? ink : nil
                let actual = try coverage(drawn.filter { $0.color == color }, at: 0, in: system.glyphAtlas)
                let different = Set(wanted.keys).union(actual.keys).count { wanted[$0] != actual[$0] }
                #expect(!wanted.isEmpty)
                #expect(different == 0, "document byte \(prefix.utf8.count + byte)")
            }
        }
        #expect(!layout.paragraphs[0].layout.hasGlyphs && !layout.paragraphs[2].layout.hasGlyphs)
    }
}
#endif
