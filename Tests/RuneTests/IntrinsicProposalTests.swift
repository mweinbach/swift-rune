#if canImport(CRuneDesktopText) && !canImport(CoreText) && (os(Linux) || os(Windows))
import Testing
@testable import Rune

@Suite("Native text used by intrinsic size proposals")
struct IntrinsicProposalTests {
    @Test func intrinsicWidthsShareOnlyTheParagraphGeometry() throws {
        let system = TextSystem()
        let probes = IntrinsicTextShapes()
        let spans = [TextSpan("Café au lait and "), TextSpan("אבג text\nÉé e\u{301} words", weight: 700)]
        let source = spans.map(\.text).joined()
        let style = TextStyle(size: 16, wrap: .wrap)
        func layout(_ width: Float?, retaining: Bool, paint: Bool = false, in s: TextSystem = system) -> TextLayoutBox {
            s.layoutKeyed(retaining: nil, intrinsicShapes: s === system ? probes : nil,
                          text: source, spans: spans, style: style, maxWidth: width,
                          pixelScale: 1.25, emitGlyphs: paint, keep: .cached, countAsRebreak: retaining)
        }

        let wide = layout(nil, retaining: false)
        let calls = system.shapedCallCount
        #expect(calls > 0)
        let first = try #require(probes.paragraphs[wide.shapeKey])
        #expect(first.linesByStart.count == 2)
        #expect(first.fragments.isEmpty)
        let narrow = layout(0.4, retaining: false)
        #expect(narrow.shaped.lineCount > wide.shaped.lineCount)
        #expect(system.shapedCallCount == calls)
        #expect(system.cachedLayoutCount == 0)
        #expect(system.cachedShapeCount == 0)

        let final = layout(85, retaining: true)
        let drawn = layout(85, retaining: true, paint: true)
        #expect(system.shapedCallCount == calls)
        let fresh = layout(85, retaining: true, paint: true, in: TextSystem())
        #expect(drawn.shaped.size == fresh.shaped.size)
        #expect(final.shaped.portableLines.map(\.utf8Start) == fresh.shaped.portableLines.map(\.utf8Start))
        #expect(drawn.shaped.portableLines.map(\.charOffsets) == fresh.shaped.portableLines.map(\.charOffsets))
        #expect(drawn.shaped.glyphs == fresh.shaped.glyphs)
        #expect(drawn.shaped.lineBaselinesPx == fresh.shaped.lineBaselinesPx)

        _ = system.setLanguage("ar")
        _ = layout(nil, retaining: false)
        #expect(system.shapedCallCount > calls)
        #expect(probes.paragraphs.count == 2)
        _ = system.layoutKeyed(retaining: nil, intrinsicShapes: probes, text: "secret", style: style,
                               maxWidth: nil, pixelScale: 1.25, emitGlyphs: false,
                               keep: .secret, countAsRebreak: false)
        #expect(probes.paragraphs.count == 2)
    }
}
#endif
