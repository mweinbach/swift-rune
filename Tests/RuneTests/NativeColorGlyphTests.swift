import Foundation
import Testing
@testable import Rune

@Suite("Native color glyphs")
struct NativeColorGlyphTests {
    #if os(Linux)
    private static let emojiFont = ProcessInfo.processInfo.environment["RUNE_COLOR_EMOJI_FONT"]
        ?? "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf"
    private static let supportsColor = FileManager.default.fileExists(atPath: emojiFont)
    #elseif canImport(CoreText) || os(Windows)
    private static let supportsColor = true
    #else
    private static let supportsColor = false
    #endif

    @Test(.enabled(if: supportsColor, "Requires a native color emoji font"))
    func mixedInkSurvivesAtlasEviction() throws {
        #if os(Linux)
        HeadlessRunner.registerFonts([try Data(contentsOf: URL(fileURLWithPath: Self.emojiFont))])
        #endif
        let atlas = GlyphAtlas(width: 256, height: 256, maxCachedEntries: 32, colorGlyphBudget: 1)
        let text = TextSystem(glyphAtlas: atlas)
        let style = TextStyle(size: 32)
        let tint = Color(r: 0, g: 1, b: 0, a: 0.75)
        let shaped = text.shape(text: "A🌈B", spans: [TextSpan("A🌈B", color: tint)],
                                style: style, maxWidth: nil, pixelScale: 1)
        let a = try #require(shaped.glyphs.first { $0.utf8Offset == 0 && text.colorGlyph(for: $0) == nil })
        #expect(a.color == tint)
        let rainbow = try #require(shaped.glyphs.first { $0.utf8Offset == 1 && text.colorGlyph(for: $0) != nil })
        let original = try #require(text.colorGlyph(for: rainbow))
        #expect(rainbow.uv == .zero)
        #expect(stride(from: 0, to: original.rgba.count, by: 4).contains { pixel in
            let rgba = original.rgba
            return rgba[pixel + 3] >= 128 && abs(Int(rgba[pixel]) - Int(rgba[pixel + 1])) > 48
        })

        _ = text.shape(text: "🎉🚀", style: style, maxWidth: nil, pixelScale: 1)
        #expect(atlas.colorGlyphEntryCount <= 1)
        #expect(original.index != 0)
        #expect(text.colorGlyph(original.index) == nil)
        #expect(text.colorGlyph(for: rainbow) == original)
        let ink = try #require(text.ink("🌈", style: style))
        #expect(ink.bounds.z > 1 && ink.bounds.w > 1)
    }
}
