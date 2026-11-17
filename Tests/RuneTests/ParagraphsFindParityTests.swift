import Testing
import RuneMotion
@testable import Rune

@MainActor
@Suite("Find matches in editable paragraphs")
struct ParagraphsFindParityTests {
    #if canImport(CoreText) && canImport(CoreGraphics)
    @Test("a find range across packed runs shapes only its intersecting lines")
    func packedRuns() throws {
        let system = TextSystem()
        var style = TextStyle(size: 14, weight: 400)
        style.wrap = .wrap
        let text = Array(repeating: "abcd", count: 1350).joined(separator: "\n")
        var request = ParagraphRequest(field: 1, forced: .ltr, startFlow: .ltr)
        func layout() -> TextLayoutBox {
            system.layoutInput(text: text, spans: nil, pills: [], style: style, maxWidth: 300,
                               pixelScale: 2, emitGlyphs: false, request: request)
        }
        let waiting = try #require(layout().paragraphs)
        let firstRun = try #require(waiting.paragraphs.first(where: \.run))
        let mark = TextHighlight((firstRun.end - 1)..<(firstRun.end + 3), bg: .white)
        request.highlights = [mark]
        let box = layout()
        let filled = try #require(box.paragraphs)
        #expect(waiting.waitingLines - filled.waitingLines == 2)
        #expect(filled.piece(at: mark.byteRange.lowerBound).layout.authText == "abcd")
        #expect(filled.piece(at: mark.byteRange.upperBound - 1).layout.authText == "abcd")
        let quads = TextHighlightPainter.fieldQuads(marks: [mark], box: box, system: system, origin: .zero,
                                                    transform: Vec2(1, 1), pixelScale: 2)
        #expect(quads.count == 2)
        let first = try #require(quads.first)
        let last = try #require(quads.last)
        #expect(first.rect.y < last.rect.y)
    }
    #endif

    struct State {
        var field = TextEdit("abc\néx", multiline: true)
    }

    @Test("both paint paths and layout reads place the match at the authored bytes in the second paragraph")
    func fieldMatchPaintAndRead() throws {
        let ink = Color.srgb(1, 0, 0, 1)
        let background = Color.srgb(0, 1, 0, 1)
        let rt = Runtime<State>(state: State(), viewport: Vec2(240, 120), pixelScale: 2) { _, _ in
            textInput(key: "field", \State.field).size(240, 120)
                .textHighlight(TextHighlight(6..<7, bg: background, fg: ink).key("match"))
        }
        let ref = rt.frame(at: 0)
        let hit = try #require(rt.highlightTargetWithNode(selector: "field/match"))
        #expect(hit.rect.y > 0)
        let red = SIMD4<Float>(1, 0, 0, 1)
        let green = SIMD4<Float>(0, 1, 0, 1)
        let mark = try #require(ref.primitives.first { $0.fill == green })
        #expect(abs(mark.rect.x / 2 - hit.rect.x) < 0.01)
        #expect(abs(mark.rect.y / 2 - hit.rect.y) < 0.01)
        #expect(ref.primitives.filter { $0.kind == .glyph && $0.fill == red }.count == 1)
        let metal = rt.renderFrame(at: 0.01)
        #expect(metal.instances.contains { $0.fill == green })
        #expect(metal.instances.filter { $0.fill == red }.count == 1)

        rt.update { state, _ in state.field.isSecure = true }
        let secure = rt.frame(at: 0.02)
        #expect(rt.highlightTargetWithNode(selector: "field/match") == nil)
        #expect(!secure.primitives.contains { $0.fill == red || $0.fill == green })
    }
}
