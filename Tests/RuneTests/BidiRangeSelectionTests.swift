#if canImport(CoreText) && canImport(CoreGraphics)
import Testing
@testable import Rune

@Suite("Bidirectional range selection at soft wraps")
struct BidiRangeSelectionTests {
    @Test func selectionCrossesWrapWithAGapOnTheNextLine() throws {
        let system = TextSystem()
        let style = TextStyle(size: 20, wrap: .wrap, direction: .ltr)
        let prefix = "MMMMM "
        let text = prefix + "AאבB"
        let width = system.shape(text: prefix, style: style, maxWidth: nil, pixelScale: 2, emitGlyphs: false).size.x + 1
        let shaped = system.shape(text: text, style: style, maxWidth: width, pixelScale: 2, emitGlyphs: false)
        let wrap = prefix.utf8.count
        try #require(shaped.lineStrings.map(\.utf8Start) == [0, wrap])

        func middle(of bytes: Range<Int>) -> SIMD2<Float> {
            let start = system.caretRect(in: shaped, utf8Offset: bytes.lowerBound, affinity: .downstream, pixelScale: 2)
            let end = system.caretRect(in: shaped, utf8Offset: bytes.upperBound, affinity: .upstream, pixelScale: 2)
            return SIMD2((start.x + end.x) / 2, start.y + start.w / 2)
        }
        let alefBytes = (wrap + 1)..<(wrap + "Aא".utf8.count)
        let betBytes = alefBytes.upperBound..<(wrap + "Aאב".utf8.count)
        let a = middle(of: wrap..<alefBytes.lowerBound)
        let alef = middle(of: alefBytes)
        let bet = middle(of: betBytes)
        let b = middle(of: betBytes.upperBound..<text.utf8.count)
        try #require(a.x < bet.x && bet.x < alef.x && alef.x < b.x)

        for start in [wrap - 2, wrap] {
            let rects = system.selectionRects(in: shaped, utf8Range: start..<alefBytes.upperBound, pixelScale: 2)
            func contains(_ point: SIMD2<Float>) -> Bool {
                rects.contains { rect in
                    (rect.x..<(rect.x + rect.z)).contains(point.x) && (rect.y..<(rect.y + rect.w)).contains(point.y)
                }
            }
            #expect(rects.count == (start < wrap ? 3 : 2))
            #expect(contains(middle(of: (wrap - 2)..<(wrap - 1))) == (start < wrap))
            #expect(contains(a) && contains(alef))
            #expect(!contains(bet) && !contains(b))
        }

        // Selecting the complete RTL run joins its two cells into one visual interval.
        let run = system.selectionRects(in: shaped, utf8Range: alefBytes.lowerBound..<betBytes.upperBound, pixelScale: 2)
        try #require(run.count == 1)
        let rect = run[0]
        let leading = system.caretRect(in: shaped, utf8Offset: alefBytes.lowerBound, affinity: .downstream, pixelScale: 2)
        let trailing = system.caretRect(in: shaped, utf8Offset: betBytes.upperBound, affinity: .upstream, pixelScale: 2)
        #expect(abs(rect.x - trailing.x) < 0.01)
        #expect(abs(rect.x + rect.z - leading.x) < 0.01)
    }

    @Test func latinRunFillsItsWidthInARightToLeftParagraph() throws {
        let system = TextSystem()
        let text = "abc"
        let shaped = system.shape(text: text, style: TextStyle(size: 20, direction: .rtl),
                                  maxWidth: nil, pixelScale: 2, emitGlyphs: false)
        let leading = system.caretRect(in: shaped, utf8Offset: 0, affinity: .downstream, pixelScale: 2)
        let trailing = system.caretRect(in: shaped, utf8Offset: text.utf8.count, affinity: .upstream, pixelScale: 2)
        try #require(trailing.x > leading.x)
        let selection = system.selectionRects(in: shaped, utf8Range: 0..<text.utf8.count, pixelScale: 2)
        try #require(selection.count == 1)
        #expect(abs(selection[0].x - leading.x) < 0.01)
        #expect(abs(selection[0].x + selection[0].z - trailing.x) < 0.01)
    }
}
#endif
