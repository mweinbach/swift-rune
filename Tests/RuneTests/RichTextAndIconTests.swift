import Testing
@testable import Rune

@Suite("Rich Text, TextCase, FontEpoch, and Multi-Color SVG Icon Tests")
struct RichTextAndIconTests {

    @Test("fontEpoch bumps when FontFamiliesRegistry or TextSystem.setFamilies changes")
    func fontEpochAndFamilies() {
        let initial = fontEpoch()
        let ts = TextSystem()
        #expect(ts.currentFontEpoch == initial)

        // Setting same empty families does nothing
        #expect(ts.setFamilies(sans: "", mono: "") == false)
        #expect(fontEpoch() == initial)

        // Switching families bumps epoch
        #expect(ts.setFamilies(sans: "Helvetica Neue, Inter", mono: "Menlo") == true)
        let afterSet = fontEpoch()
        #expect(afterSet > initial)
        #expect(ts.families().sans == "Helvetica Neue, Inter")
        #expect(ts.families().mono == "Menlo")

        // Scoped withFontFamilies bumps on entry and restores on exit
        withFontFamilies(sans: "Avenir", mono: "Courier") {
            #expect(FontFamiliesRegistry.currentFamilies().sans == "Avenir")
            #expect(fontEpoch() > afterSet)
        }
        #expect(FontFamiliesRegistry.currentFamilies().sans == "Helvetica Neue, Inter")
        #expect(fontEpoch() > afterSet + 1)

        // Restore clean defaults
        _ = FontFamiliesRegistry.setFamilies(sans: "", mono: "")
    }

    @Test("TextCaseMapping preserves UTF-8 byte offsets across Unicode case expansions")
    func textCaseByteMapping() {
        // 'ß' (2 UTF-8 bytes at 1..<3) expands to "SS" (2 bytes), 'i' -> 'I'
        let src = "aß b"
        let mapped = TextCaseMapping(source: src, textCase: .uppercase)
        #expect(mapped.displayed == "ASS B")
        #expect(mapped.displayedRange(forSourceUTF8Range: 1..<3) == 1..<3)
        #expect(mapped.displayedRange(forSourceUTF8Range: 4..<5) == 4..<5)

        // Greek uppercase -> lowercase
        let greek = "ΟΔΟΣ Ω"
        let lower = TextCaseMapping(source: greek, textCase: .lowercase)
        #expect(lower.displayed == "οδος ω")
    }

    @Test("RichSpanFlattener splits and merges overlapping spans into contiguous TextSpans")
    func richSpanFlattening() {
        let text = "Hello Rune World"
        let spans = [
            RichSpan(0..<10).color(.srgb(1, 0, 0)).bold(),
            RichSpan(6..<16).bg(.srgb(0, 0, 1, 0.2)).underline(),
        ]
        let flat = RichSpanFlattener.flatten(spans, in: text, base: TextStyle())
        #expect(flat.map(\.text) == ["Hello ", "Rune", " World"])
        #expect(flat[0].weight == 700 && flat[0].underline == false)
        #expect(flat[1].weight == 700 && flat[1].underline == true && flat[1].background != nil)
        #expect(flat[2].weight == nil && flat[2].underline == true)
    }

    @Test("TextLink effectivePaint prioritizes pressed over hover and merges focused")
    func textLinkAndHighlights() {
        let link = TextLink(0..<5, id: "docs", label: "Docs")
            .hover(LinkPaint().color(.srgb(0, 0.5, 1)).underline())
            .pressed(LinkPaint().color(.srgb(0, 0.2, 0.8)))
            .focused(LinkPaint().ring(.srgb(0.2, 0.6, 1), width: 1.5))

        let hovered = link.effectivePaint(hovered: true, pressed: false, focused: true)
        #expect(hovered.underline == true)
        #expect(hovered.ring?.width == 1.5)

        let pressed = link.effectivePaint(hovered: true, pressed: true, focused: false)
        #expect(pressed.color == .srgb(0, 0.2, 0.8))
        #expect(pressed.underline == true)

        // TextHighlightPainter emits merged highlight quad
        let ts = TextSystem()
        let shaped = ts.shape(text: "Hello highlight", style: TextStyle(), maxWidth: nil, pixelScale: 2.0, emitGlyphs: false)
        let hl = TextHighlight(6..<15, bg: .srgb(1, 1, 0, 0.35), pad: 2.0, key: "match")
        let quads = TextHighlightPainter.quads(highlights: [hl], in: "Hello highlight", shaped: shaped, textSystem: ts, pixelScale: 2.0)
        #expect(quads.count >= 1)
        #expect(quads[0].cornerRadius == 8.0)
    }

    @Test("Multi-color SVGIcon rasterizes RGB colors, gradients, currentColor, and monochrome fallback")
    func multiColorSVGIcon() {
        let badge = SVGIcon(
            viewBox: 24,
            body: """
            <defs>
              <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
                <stop offset="0%" stop-color="#ff0000"/>
                <stop offset="100%" stop-color="#0000ff"/>
              </linearGradient>
            </defs>
            <rect x="2" y="2" width="10" height="20" rx="2" fill="#00ff00"/>
            <circle cx="17" cy="12" r="5" fill="url(#g)"/>
            <path d="M4 12 L20 12" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
            """
        )
        #expect(badge.isColorIcon == true)

        let rasterizer = ColorIconRasterizer()
        let img = rasterizer.rasterize(badge, pixelSize: 48, currentColor: .srgb(1, 1, 1))
        #expect(img != nil)
        #expect(img?.width == 48 && img?.height == 48)
        let rgba = img!.mips[0].rgba
        #expect(rgba.count == 48 * 48 * 4)
        // Left green rect pixel around (x=12, y=24) has non-zero green channel
        let idx = (24 * 48 + 12) * 4
        #expect(rgba[idx + 1] > 180)
        #expect(rgba[idx + 3] > 200)

        // Monochrome SVGIcon with XML body rasterizes cleanly into GlyphAtlas
        let monoXml = SVGIcon(viewBox: 24, body: "<rect x=\"4\" y=\"4\" width=\"16\" height=\"16\" rx=\"3\"/>")
        #expect(monoXml.isColorIcon == false)
        let entry = GlyphAtlas().rasterizeIcon(monoXml, pixelSize: 24)
        #expect(entry.uv.z > entry.uv.x)
    }
}
