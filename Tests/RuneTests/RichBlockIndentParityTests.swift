import Testing
import RuneMotion
@testable import Rune

@MainActor
@Suite("Rich field block indentation")
struct RichBlockIndentParityTests {
    private struct State {
        var field: TextEdit
    }

    @Test("a formatting change moves all soft lines, caret and glyphs in the retained field")
    func retainedField() throws {
        let size: Float = 14
        let scale: Float = 1.5
        let width: Float = 110
        let style = TextStyle(size: size, family: .monospace, wrapAnywhere: true)
        let paragraph = String(repeating: "x", count: 36)
        let text = "x\n" + paragraph + "\n"
        let runtime = Runtime(state: State(field: .fromRichParts(text: text)),
                              viewport: Vec2(width, 250), pixelScale: scale) { _, _ in
            textInput(key: "field", \State.field).size(width, 250).font(style)
        }
        let system = runtime.textSystem
        _ = runtime.frame(at: 0)
        let original = try #require(runtime.nodeTextLayouts.first { $0.value.isInput }?.value.box)
        #expect(system.visualLines(in: original.shaped).allSatisfy { $0.originX == 0 })

        runtime.update { state, _ in
            state.field = .fromRichParts(text: text, blocks: [.paragraph, .numbered(1), .quote])
        }
        _ = runtime.frame(at: 1)
        let updated = try #require(runtime.nodeTextLayouts.first { $0.value.isInput }?.value.box)
        let lines = system.visualLines(in: updated.shaped)
        let numbered = lines.filter { (2..<(2 + paragraph.utf8.count)).contains($0.utf8Start) }
        let indent = (Block.numbered(1).indentPt(fontSize: size) * scale).rounded() / scale
        #expect(numbered.count > 1)
        #expect(numbered.allSatisfy { $0.originX == indent })
        let caret = system.caretRect(in: updated.shaped, utf8Offset: 2, upstream: false, pixelScale: scale)
        #expect(caret.x == indent)
        let quote = (Block.quote.indentPt(fontSize: size) * scale).rounded() / scale
        #expect(lines.last?.originX == quote)
        let drawn = system.layoutKeyed(text: updated.authText, spans: updated.spans, pills: updated.pills,
                                       style: updated.style, maxWidth: updated.maxWidth,
                                       pixelScale: scale, emitGlyphs: true).shaped
        let first = try #require(drawn.glyphs.first { $0.utf8Offset == 0 })
        let list = try #require(drawn.glyphs.first { $0.utf8Offset == 2 })
        #expect(abs(list.rect.x - first.rect.x - indent) < 0.01)
    }

    @Test("code wraps at the remaining width inside both insets on each backend")
    func codeWidth() {
        let system = TextSystem()
        let scale: Float = 2
        let width: Float = 100
        let text = String(repeating: "0", count: 48)
        let base = TextStyle(size: 16, family: .monospace, wrap: .wrap, wrapAnywhere: true)
        let inset = Block.code.indentPt(fontSize: base.size)
        var code = base
        code.paragraphBlocks = [.code]
        func check(_ shape: (TextStyle, Float) -> ShapedText) {
            let lines = system.visualLines(in: shape(code, width))
            let inner = system.visualLines(in: shape(base, width - 2 * inset))
            let leftOnly = system.visualLines(in: shape(base, width - inset))
            #expect(lines.map(\.utf8End) == inner.map(\.utf8End))
            #expect(lines.map(\.utf8End) != leftOnly.map(\.utf8End))
            #expect(lines.allSatisfy { $0.originX == inset })
        }
        check { style, width in system.shape(text: text, style: style, maxWidth: width, pixelScale: scale) }
        check { style, width in system.shapePortable(text: text, style: style, maxWidth: width, pixelScale: scale) }
    }
}
