#if os(Linux) || os(Windows)
import CRuneDesktopText
import Testing
@testable import Rune

@Suite("Native desktop text")
struct DesktopTextRenderingTests {
    @Test func measuresKernedRunsAndReusesCoverage() {
        let text = TextSystem()
        let style = TextStyle(size: 28)
        func measure(_ string: String) -> Float {
            text.measure(string, style: style, maxWidth: nil, pixelScale: 1).x
        }
        let advance = measure("AV")
        #expect(advance < measure("A") + measure("V"))
        let unkerned = text.measure("AV", style: style.features("'kern' 0"), maxWidth: nil, pixelScale: 1)
        #expect(unkerned.x > advance)
        let inkWidth = text.ink("AV", style: style)?.bounds.z ?? 0
        #expect(inkWidth > 0)
        #expect(!text.glyphAtlas.hasAllocatedBacking)
        let shaped = text.shape(text: "AV", style: style, maxWidth: nil, pixelScale: 1)
        #expect(shaped.size.x == advance)
        #expect(!shaped.glyphs.isEmpty)
        let texels = text.glyphAtlas.pageData(0) ?? []
        #expect(texels.contains { $0 > 0 && $0 < 255 })
        let allocated = text.glyphAtlas.rasterized
        let again = text.shape(text: "AV", style: style, maxWidth: nil, pixelScale: 1)
        #expect(again.glyphs == shaped.glyphs)
        #expect(text.glyphAtlas.rasterized == allocated)
    }

    @Test func rtlFallbackPreservesVisualCaretAndUTF8Offsets() {
        let text = TextSystem()
        let string = "مرحبا"
        let shaped = text.shape(text: string, style: TextStyle(size: 22, direction: .rtl),
                                maxWidth: nil, pixelScale: 2)
        let start = text.caretRect(in: shaped, utf8Offset: 0, pixelScale: 2)
        let end = text.caretRect(in: shaped, utf8Offset: string.utf8.count, pixelScale: 2)
        #expect(start.x > end.x)
        #expect(text.hitTestUTF8Offset(in: shaped, localX: end.x, localY: 0, pixelScale: 2) == string.utf8.count)
        #expect(shaped.glyphs.contains { $0.utf8Offset > 1 })
    }

    #if os(Windows)
    @Test func longDirectWriteCellsFollowNativeAdvances() throws {
        try #require(DefaultFonts.registerIfNeeded())
        let halfRTL = String(repeating: "א", count: 4_000)
        let halfLTR = String(repeating: "A", count: 4_000)
        let cases: [(String, Float, Bool)] = [
            (halfLTR + halfLTR, 20, false), (halfRTL + halfRTL, 19.7, true), (halfRTL + halfLTR, 19.7, false)
        ]
        for (string, em, checkRTLMidpoint) in cases {
            let byteCount = Int32(string.utf8.count)
            let line = try #require(rune_desktop_line_create(string, byteCount, "Inter", em, 400, 0, 0, 0))
            defer { rune_desktop_line_destroy(line) }
            let width = rune_desktop_line_metrics(line).advance
            var sum = 0.0
            var start: Int32 = 0
            for character in string {
                let end = start + Int32(character.utf8.count)
                var left: Float = 0, advance: Float = 0
                _ = rune_desktop_line_cell(line, start, end, &left, &advance)
                sum += Double(advance)
                start = end
            }
            #expect(abs(sum - Double(width)) < 0.02)
            if checkRTLMidpoint {
                let half = try #require(rune_desktop_line_create(halfRTL, byteCount / 2, "Inter", em, 400, 0, 0, 0))
                defer { rune_desktop_line_destroy(half) }
                let caret = rune_desktop_line_caret(line, byteCount / 2)
                #expect(abs(caret - (width - rune_desktop_line_metrics(half).advance)) < 0.02)
            }
        }
    }
    #endif

    @Test func longLinesRetainLigatureAndCombiningMarkCaretPositions() {
        let text = TextSystem()
        let phrases: [(String, TextFlow)] = [
            ("office / e\u{301} / ", .ltr), ("مَرْحَبًا ", .rtl), ("हिन्दी भाषा ", .ltr)
        ]
        for (phrase, flow) in phrases {
            let style = TextStyle(size: 19, direction: flow)
            let short = text.shape(text: phrase, style: style, maxWidth: nil, pixelScale: 1, emitGlyphs: false)
            let long = text.shape(text: String(repeating: phrase, count: 48), style: style, maxWidth: nil,
                                  pixelScale: 1, emitGlyphs: false)
            let shortStart = text.caretRect(in: short, utf8Offset: 0, pixelScale: 1).x
            let longStart = text.caretRect(in: long, utf8Offset: 0, pixelScale: 1).x
            var byte = 0
            for character in phrase {
                let expected = text.caretRect(in: short, utf8Offset: byte, pixelScale: 1).x - shortStart
                let actual = text.caretRect(in: long, utf8Offset: byte, pixelScale: 1).x - longStart
                #expect(abs(actual - expected) < 0.02)
                byte += character.utf8.count
            }
        }
        #expect(!text.glyphAtlas.hasAllocatedBacking)
    }

    @Test func fontChangesKeepBidiRunOrderAndGraphemeColor() throws {
        let ink = Color(r: 1, g: 0.25, b: 0.1, a: 1)
        let spans = [TextSpan("abc "), TextSpan("אב", color: ink), TextSpan("גד", weight: 600), TextSpan(" z")]
        let text = TextSystem()
        let shaped = text.shape(text: "", spans: spans, style: TextStyle(size: 24),
                                maxWidth: nil, pixelScale: 1)
        let alef = try #require(shaped.glyphs.first { $0.utf8Offset == 4 })
        let dalet = try #require(shaped.glyphs.first { $0.utf8Offset == 10 })
        #expect(dalet.rect.x < alef.rect.x)
        #expect(alef.color == ink)
    }

    @Test func longRunFitsSmallAtlasAndKeepsSecretTextOutOfLookup() {
        let atlas = GlyphAtlas(width: 64, height: 64)
        let text = TextSystem(glyphAtlas: atlas)
        let line = String(repeating: "W", count: 44)
        let shaped = text.shape(text: line, style: TextStyle(size: 16), maxWidth: nil,
                                pixelScale: 1, bypassCache: true)
        #expect(shaped.glyphs.last?.utf8Offset == line.utf8.count - 1)
        #expect(atlas.rasterized < UInt64(line.utf8.count))
        #expect(atlas.cachedEntryCount == 0)
    }

    #if os(Linux)
    @Test func reportedInkBoundsContainCairoCoverage() throws {
        try #require(DefaultFonts.registerIfNeeded())
        let cases: [(text: String, family: String, size: Float)] = [
            ("qygjÉÍÅ", DefaultFonts.sansFamily, 29.75),
            ("Hello 0123 ffi", DefaultFonts.sansFamily, 58.625),
            ("qygjÉÍÅ", DefaultFonts.monoFamily, 25.375)
        ]
        for item in cases {
            let line = try #require(rune_desktop_line_create(item.text, Int32(item.text.utf8.count), item.family,
                item.size, 400, 0, item.family == DefaultFonts.monoFamily ? 1 : 0, 1))
            defer { rune_desktop_line_destroy(line) }
            let ink = rune_desktop_line_metrics(line)
            let border: Int32 = 8
            let width = ink.ink_width + 2 * border, height = ink.ink_height + 2 * border
            var pixels = [UInt8](repeating: 0, count: Int(width * height))
            let ok = pixels.withUnsafeMutableBufferPointer {
                rune_desktop_line_mask(line, ink.ink_x - border, ink.ink_y - border, width, height, $0.baseAddress)
            }
            try #require(ok != 0)
            #expect(pixels.contains { $0 != 0 })
            let outside = pixels.indices.first { i in
                guard pixels[i] != 0 else { return false }
                let x = Int32(i) % width - border, y = Int32(i) / width - border
                return x < 0 || y < 0 || x >= ink.ink_width || y >= ink.ink_height
            }
            #expect(outside == nil, "\(item.family) at \(item.size) px: Cairo painted past the advertised ink bounds")
        }
    }
    #endif
}
#endif
