#if canImport(CRuneDesktopText) && !canImport(CoreText) && (os(Linux) || os(Windows))
import Testing
@testable import Rune

@Suite("Native paragraph shape reuse")
struct NativeParagraphReuseTests {
    @Test func intactNoWrapParagraphsUseTheirNativeWidthAndKeepTheirCarets() throws {
        let system = TextSystem()
        let spans = [TextSpan("let value =\t"), TextSpan("אבג", weight: 700), TextSpan("  \nCafé  ")]
        let style = TextStyle(size: 16, letterSpacing: 0.25, family: .monospace, wrap: .noWrap)
        // A nonbinding line limit exercises the existing per-character width calculation.
        var limited = style
        limited.maxLines = 3
        for paint in [false, true] {
            func shape(_ style: TextStyle) -> ShapedText {
                system.shapePortable(text: "", spans: spans, style: style, maxWidth: nil, pixelScale: 2,
                                     emitGlyphs: paint, nativeFonts: true, retain: .cached)
            }
            let actual = shape(style)
            let reference = shape(limited)
            let paragraph = try #require(actual.desktopParagraph)
            #expect(actual.lineCount == 2)
            for (index, fragment) in paragraph.fragments.enumerated() {
                let line = try #require(fragment)
                #expect(actual.lineAdvancesPx[index].widthPx == line.width * 2)
            }
            #expect(actual.size == reference.size)
            #expect(actual.lineBaselinesPx == reference.lineBaselinesPx)
            #expect(actual.portableLines.map(\.charOffsets) == reference.portableLines.map(\.charOffsets))
            #expect(actual.glyphs == reference.glyphs)
        }
    }

    @Test func changingWidthReusesTheParagraphAndPaintingReusesItsLines() throws {
        let system = TextSystem()
        let text = "Café au lait and freshly baked bread"
        let style = TextStyle(size: 18, wrap: .wrap)
        let wide = system.layoutKeyed(text: text, style: style, maxWidth: 800, pixelScale: 2,
                                      emitGlyphs: false, keep: .owned)
        let original = try #require(wide.shaped.desktopParagraph)
        let originalLine = try #require(original.linesByStart[0])
        #expect(wide.shaped.lineCount == 1)

        let width: Float = 95
        let narrow = try #require(system.rebreakOwned(wide, maxWidth: width, emitGlyphs: false))
        let measured = try #require(narrow.shaped.desktopParagraph)
        let measuredLine = try #require(measured.linesByStart[0])
        #expect(measuredLine === originalLine)
        #expect(narrow.shaped.lineCount > 1)
        #expect(measured.fragments.count == narrow.shaped.lineCount)
        #expect(narrow.shaped.glyphs.isEmpty)

        let painted = try #require(system.rebreakOwned(narrow, maxWidth: width, emitGlyphs: true))
        let replay = try #require(painted.shaped.desktopParagraph)
        let replayLine = try #require(replay.linesByStart[0])
        #expect(replayLine === originalLine)
        #expect(replay.fragments.count == measured.fragments.count)
        for (before, after) in zip(measured.fragments, replay.fragments) {
            let fragment = try #require(before)
            #expect(after === fragment)
        }
        // The first "a" after "Café " starts at UTF-8 byte 6. Byte 4 is inside "é".
        let ink = painted.shaped.glyphs.filter { $0.rect.z > 0 && $0.rect.w > 0 }
        #expect(ink.contains { $0.utf8Offset == 6 })
        #expect(!ink.contains { $0.utf8Offset == 4 })

        let fresh = system.layoutKeyed(text: text, style: style, maxWidth: width, pixelScale: 2,
                                       emitGlyphs: true, keep: .owned)
        #expect(painted.shaped.size == fresh.shaped.size)
        #expect(painted.shaped.portableLines.map(\.utf8Start) == fresh.shaped.portableLines.map(\.utf8Start))
        #expect(painted.shaped.portableLines.map(\.charOffsets) == fresh.shaped.portableLines.map(\.charOffsets))
        #expect(painted.shaped.glyphs == fresh.shaped.glyphs)
    }

    @Test func cachedRichTextReflowsAndPaintsFromTheMeasuredShape() throws {
        let spans = [TextSpan("Café au lait and freshly baked bread.\n"),
                     TextSpan("Crème brûlée with berries.", weight: 700)]
        let text = spans.map(\.text).joined()
        let style = TextStyle(size: 17, wrap: .wrap)
        func layout(_ system: TextSystem, width: Float, paint: Bool) -> TextLayoutBox {
            system.layoutKeyed(text: text, spans: spans, style: style, maxWidth: width,
                               pixelScale: 2, emitGlyphs: paint, keep: .cached)
        }

        let cached = TextSystem()
        let wide = layout(cached, width: 700, paint: false)
        let shapeCalls = cached.shapedCallCount
        #expect(shapeCalls > 0)
        #expect(wide.shaped.lineCount == 2)

        let narrow = layout(cached, width: 95, paint: false)
        #expect(narrow.shaped.lineCount > wide.shaped.lineCount)
        #expect(narrow.shaped.glyphs.isEmpty)
        #expect(cached.shapedCallCount == shapeCalls)
        let painted = layout(cached, width: 95, paint: true)
        #expect(cached.shapedCallCount == shapeCalls)
        #expect(!painted.shaped.glyphs.isEmpty)

        let uncached = TextSystem()
        let fresh = layout(uncached, width: 95, paint: true)
        #expect(painted.shaped.portableLines.map(\.utf8Start) == fresh.shaped.portableLines.map(\.utf8Start))
        #expect(painted.shaped.lineGlyphRanges == fresh.shaped.lineGlyphRanges)
        #expect(painted.shaped.glyphs == fresh.shaped.glyphs)
        for page in Set(painted.shaped.glyphs.map(\.atlasPage)) {
            let bytes = try #require(cached.glyphAtlas.pageData(Int(page)))
            let samePixels = bytes == uncached.glyphAtlas.pageData(Int(page))
            #expect(samePixels, "Glyph atlas page \(page) differs after reflow")
        }
    }

    @Test func intrinsicAndGlidingProbesPreserveTheDrawnLayout() {
        let system = TextSystem()
        let style = TextStyle(size: 16, wrap: .wrap)
        func probe(_ text: String, gliding: Bool) -> TextLayoutBox {
            system.layoutKeyed(text: text, style: style, maxWidth: 85, pixelScale: 1,
                               emitGlyphs: gliding, glidePx: gliding ? .init(0, 0.25) : .zero,
                               keep: .cached, countAsRebreak: gliding)
        }
        for gliding in [false, true] {
            _ = probe("A new paragraph to measure", gliding: gliding)
            #expect(system.cachedLayoutCount == 0)
            #expect(system.cachedShapeCount == 0)
        }

        let text = "Several words to wrap across the narrow measure."
        let drawn = system.layoutKeyed(text: text, style: style, maxWidth: 600, pixelScale: 1,
                                       emitGlyphs: true, keep: .cached)
        let height = drawn.shaped.size.y
        let calls = system.shapedCallCount
        let rebreaks = system.rebrokenCount
        let sameWidth = system.layoutKeyed(text: text, style: style, maxWidth: 600.05, pixelScale: 1,
                                           emitGlyphs: true, keep: .cached)
        #expect(sameWidth === drawn)
        for gliding in [false, true] {
            let narrow = probe(text, gliding: gliding)
            #expect(narrow.shaped.size.y > height)
            #expect(system.shapedCallCount == calls)
            #expect(system.rebrokenCount == rebreaks)
            #expect(system.cachedLayoutBox(for: drawn.shapeKey) === drawn)
            #expect(drawn.maxWidth == 600 && drawn.shaped.size.y == height)
        }

        let measured = system.layoutKeyed(text: text, style: style, maxWidth: 85, pixelScale: 1,
                                          emitGlyphs: false, keep: .cached, countAsRebreak: true)
        #expect(system.cachedLayoutBox(for: drawn.shapeKey) === measured)
        #expect(system.shapedCallCount == calls)
        #expect(system.rebrokenCount == rebreaks + 1)
    }

    @Test func retentionAppliesToOwnedPlainParagraphs() {
        let system = TextSystem()
        let style = TextStyle(size: 16, wrap: .wrap)
        let secret = system.layoutKeyed(text: "private words", style: style, maxWidth: 100,
                                        pixelScale: 1, emitGlyphs: true, keep: .secret)
        let cached = system.layoutKeyed(text: "shared text", style: style, maxWidth: 100,
                                        pixelScale: 1, emitGlyphs: false, keep: .cached)
        let chip = system.layoutKeyed(text: "link to source", pills: [PillChip(0..<4)], style: style,
                                      maxWidth: 100, pixelScale: 1, emitGlyphs: false, keep: .owned)
        let rich = system.layoutKeyed(text: "", spans: [TextSpan("rich words", weight: 700)],
                                      style: style, maxWidth: 100, pixelScale: 1,
                                      emitGlyphs: false, keep: .owned)
        let multiline = system.layoutKeyed(text: "first\nsecond", style: style, maxWidth: 100,
                                           pixelScale: 1, emitGlyphs: false, keep: .owned)
        var bounded = style
        bounded.maxLines = 1
        let limited = system.layoutKeyed(text: "a paragraph limited to one line", style: bounded,
                                         maxWidth: 50, pixelScale: 1, emitGlyphs: false, keep: .owned)

        for layout in [secret, cached, chip, rich, multiline, limited] {
            #expect(layout.shaped.desktopParagraph == nil)
            #expect(system.rebreakOwned(layout, maxWidth: 50, emitGlyphs: true) == nil)
        }
    }
}
#endif
