import Testing
@testable import Rune

@Suite("Rich TextEdit Marks, Blocks, Pills, HTML & Soft-Wrap Caret Motion Tests")
struct RichTextEditTests {

    @Test("an interior UTF-8 offset snaps to the closest grapheme edge, with ties going to the start")
    func nearestGraphemeEdge() {
        let edit = TextEdit("ée\u{301}👩🏽‍💻🇯🇵\r\nב", multiline: true)
        var start = 0
        for grapheme in edit.text {
            let end = start + grapheme.utf8.count
            for byte in start...end {
                let expected = byte - start <= end - byte ? start : end
                #expect(edit.snapToGraphemeBoundary(byte) == expected)
            }
            start = end
        }
        #expect(edit.snapToGraphemeBoundary(.min) == 0)
        #expect(edit.snapToGraphemeBoundary(.max) == edit.text.utf8.count)
    }

    @Test("vertical arrow keys keep the visual edge of a mixed-direction selection")
    func verticalKeysAtBidiBoundary() {
        let system = TextSystem()
        var edit = TextEdit("A\nAאבB", multiline: true).rich()
        var shaped = ShapedText(size: Vec2(40, 32), lineCount: 2, lineHeight: 16,
                                glyphs: [], underlines: [], backgrounds: [])
        shaped.portableLines = [(0, "A", 0, 0, [0, 10]), (2, "AאבB", 16, 0, [0, 10, 10, 20, 20, 30, 40])]
        shaped.portableBidiCells[1] = [
            .init(range: 2..<3, left: 0, width: 10, rtl: false, space: false),
            .init(range: 5..<7, left: 10, width: 10, rtl: true, space: false),
            .init(range: 3..<5, left: 20, width: 10, rtl: true, space: false),
            .init(range: 7..<8, left: 30, width: 10, rtl: false, space: false),
        ]
        edit.setCursor(utf8Offset: 1)
        _ = edit.handleKey(KeyEvent(key: .arrowDown, mods: Mods(shift: true)), layout: shaped,
                           textSystem: system, pixelScale: 2)
        #expect(edit.selectedUTF8Range == 1..<3)
        #expect(edit.caretAffinity == .upstream)
        #expect(system.caretRect(in: shaped, utf8Offset: edit.cursor, affinity: edit.caretAffinity, pixelScale: 2).x == 10)

        _ = edit.handleKey(KeyEvent(key: .arrowUp), layout: shaped, textSystem: system, pixelScale: 2)
        #expect(edit.cursor == 1 && edit.anchor == 1 && edit.caretColumn.goal == 10)
        edit.moveLine(delta: .max, in: shaped, textSystem: system)
        #expect(edit.cursor == edit.text.utf8.count && edit.caretColumn.goal == 10)
        edit.moveLine(delta: .min, in: shaped, textSystem: system, extend: true)
        #expect(edit.cursor == 0 && edit.selectedUTF8Range == 0..<edit.text.utf8.count)
    }

    @MainActor
    @Test("field navigation and both paint paths use the same side of a soft wrap")
    func wrappedFieldKeyboardCaret() throws {
        struct State {
            var edit = TextEdit("one two three four five six seven eight nine ten eleven twelve\nend", multiline: true)
        }
        var initial = State()
        initial.edit.setCursor(utf8Offset: 0)
        let color = Color.srgb(0, 1, 0)
        for metal in [false, true] {
            let rt = Runtime(state: initial, viewport: Vec2(90, 180), pixelScale: 2) { _, _ in
                textInput(key: "field", \State.edit).font(TextStyle(size: 15).lh(22))
                    .size(90, 180).focused(true).caret(color)
            }
            rt.srgbBlend = false
            func draw(_ time: Double) throws -> [Float] {
                let ink = color.simd4(srgb: rt.srgbBlend)
                let painted: SIMD4<Float>?
                if metal {
                    painted = rt.renderFrame(at: time).instances.first(where: { $0.fill == ink })?.rect
                } else {
                    painted = rt.frame(at: time).primitives.first(where: { $0.fill == ink })?.rect
                }
                let rect = try #require(painted)
                let caret = try #require(rt.element(byKey: "field")?.caret)
                #expect(rect.y == caret[1] * rt.pixelScale)
                #expect(rect.w == caret[3] * rt.pixelScale)
                return caret
            }

            let first = try draw(0)
            #expect(rt.keyDown(KeyEvent(key: .arrowDown), at: 0.01))
            let second = try draw(0.02)
            let middleByte = rt.state.edit.cursor
            #expect(second[0] == first[0] && second[1] == first[1] + 22)
            #expect(rt.keyDown(KeyEvent(key: .arrowDown, mods: Mods(shift: true)), at: 0.03))
            let third = try draw(0.04)
            #expect(third[1] == second[1] + 22)
            #expect(rt.state.edit.selectedUTF8Range.lowerBound == middleByte)
            #expect(rt.keyDown(KeyEvent(key: .arrowUp), at: 0.05))
            let back = try draw(0.06)
            #expect(rt.state.edit.cursor == middleByte)
            #expect(back == second)
        }
    }

    @Test("TypingStyle armed at caret only applies at that selection and disarms cleanly")
    func typingStyleArmingAndMarks() {
        var edit = TextEdit("ab", multiline: true).rich()
        edit.toggleMark(.bold)
        #expect(edit.hasRichMark(.bold))

        // Moving caret clears armed style; moving back manually still keeps it until setCursor
        edit.setCursor(utf8Offset: 0)
        #expect(!edit.hasRichMark(.bold))

        edit.setCursor(utf8Offset: 2)
        edit.toggleMark(.bold)
        edit.insert("c")
        #expect(edit.text == "abc")
        #expect(edit.richMarks == [RichMarkRange(2..<3, .bold)])

        // Trailing-edge inheritance continues bold typing
        edit.insert("d")
        #expect(edit.richMarks == [RichMarkRange(2..<4, .bold)])

        // Explicit setCursor drops pending style
        edit.setCursor(utf8Offset: 4)
        edit.toggleMark(.italic)
        edit.setCursor(utf8Offset: 4)
        edit.insert("e")
        #expect(edit.richMarks == [RichMarkRange(2..<5, .bold)])
    }

    @Test("AllowMask restricts marks and blocks, and Block.code strips inline marks")
    func blocksCodeAndAllowMasks() {
        var edit = TextEdit("hello\nworld", multiline: true)
            .rich()
            .allowRichMarks([.bold, .italic])
            .allowBlocks([.paragraph, .bullet, .code])

        edit.setSelectionRaw(anchor: 0, cursor: 5)
        edit.toggleMark(.bold)
        edit.toggleMark(.underline) // disallowed
        #expect(edit.richMarks == [RichMarkRange(0..<5, .bold)])

        // Toggling disallowed block does nothing
        edit.toggleBlock(.quote)
        #expect(edit.activeBlock == .paragraph)

        // Setting code block strips inline marks on that paragraph
        edit.setBlock(.code)
        #expect(edit.activeBlock == .code)
        #expect(edit.richMarks.isEmpty)

        // List toggle + indent/outdent via Tab/Shift+Tab
        edit.setCursor(utf8Offset: 8)
        edit.toggleBlock(.bullet(0))
        #expect(edit.activeBlock == .bullet(0))
        let indentOut = edit.handleKey(KeyEvent(key: .tab))
        #expect(indentOut == .modified)
        #expect(edit.activeBlock == .bullet(1))
        let outdentOut = edit.handleKey(KeyEvent(key: .tab, mods: Mods(shift: true)))
        #expect(outdentOut == .modified)
        #expect(edit.activeBlock == .bullet(0))
    }

    @Test("Atomic Pill: caret steps over, selection covers whole, backspace deletes whole, code blocks keep plain text")
    func pillAtomicity() {
        var edit = TextEdit("hi ", multiline: true).rich()
        edit.insertPill(id: "file:readme", label: "@README.md")
        edit.insert(" end")
        #expect(edit.text == "hi @README.md end")
        #expect(edit.pills.count == 1)
        #expect(edit.pills[0].id == "file:readme")
        #expect(edit.pills[0].range == 3..<13)

        // Trying to place caret inside pill snaps to nearer edge (here 5 -> 3)
        edit.setCursor(utf8Offset: 5)
        #expect(edit.cursor == 3)

        // Arrow right jumps over the entire pill to 13
        edit.moveRight()
        #expect(edit.cursor == 13)

        // Arrow left jumps back to 3
        edit.moveLeft()
        #expect(edit.cursor == 3)

        // Setting selection ending inside pill grows to cover whole pill
        edit.setCursor(utf8Offset: 1)
        edit.setCursor(utf8Offset: 8, extendSelection: true)
        #expect(edit.selectedUTF8Range == 1..<13)

        // Backspace from pill trailing edge deletes the whole pill
        edit.setCursor(utf8Offset: 13)
        edit.backspace()
        #expect(edit.text == "hi  end")
        #expect(edit.pills.isEmpty)

        // Undo restores the pill
        let didUndo = edit.undo()
        #expect(didUndo)
        #expect(edit.text == "hi @README.md end")
        #expect(edit.pills.count == 1)
    }

    @Test("HTML import/export round-trips marks, pills, lists, quotes, code, br, Google Docs bold reset, and XSS href filter")
    func htmlRoundTripAndSecurity() {
        let html = """
        <script>alert(1)</script>
        <p><b style="font-weight:normal">Plain</b> <strong>Bold</strong> <em>Ital</em> <a href="javascript:alert(2)">Bad</a> <a href="https://example.com">Good</a> <span data-pill="u1">@alice</span></p>
        <ul><li>One<ul><li>Nested</li></ul></li></ul>
        <blockquote>Quote line<br>Soft line</blockquote>
        <pre>let x = 1\nlet y = 2</pre>
        """
        let edit = TextEdit.fromHTML(html)
        #expect(!edit.text.contains("alert"))
        #expect(edit.pills.map(\.id) == ["u1"])

        let links = edit.richMarks.compactMap { $0.mark.linkURL }
        #expect(links == ["https://example.com"])

        let paras = edit.paragraphs()
        #expect(paras.count == 7)
        #expect(paras[1].block == .bullet(0))
        #expect(paras[2].block == .bullet(1))
        #expect(paras[3].block == .quote && !paras[3].softBreak)
        #expect(paras[4].block == .quote && paras[4].softBreak)
        #expect(paras[5].block == .code)
        #expect(paras[6].block == .code)

        // Check Google Docs `<b style="font-weight:normal">` did NOT make "Plain" bold
        let plainRange = 0..<5
        #expect(!edit.richMarks.contains { $0.mark == .bold && $0.start < plainRange.upperBound && $0.end > plainRange.lowerBound })

        let exported = edit.toHTML()
        #expect(exported.contains("<strong>Bold</strong>"))
        #expect(exported.contains("<em>Ital</em>"))
        #expect(exported.contains("<a href=\"https://example.com\">Good</a>"))
        #expect(exported.contains("<span data-pill=\"u1\">@alice</span>"))
        #expect(exported.contains("<blockquote>Quote line<br>Soft line</blockquote>"))
        #expect(exported.contains("<pre><code>let x = 1\nlet y = 2</code></pre>"))

        // Obfuscated scheme rejection
        #expect(!TextEdit.isSafeHref("java\tscript:alert(1)"))
        #expect(!TextEdit.isSafeHref("data:text/html,<script>"))
        #expect(TextEdit.isSafeHref("/docs/guide"))
    }

    @Test("RichDisplaySpecs splices preedit, strips secure, and moves across soft-wrapped lines keeping column")
    func richDisplayAndSoftWrapMotion() {
        var edit = TextEdit("abcd efgh ijkl mnop qrst", multiline: true).rich()
        edit.setSelectionRaw(anchor: 0, cursor: 4)
        edit.setMark(.bold)
        edit.setCursor(utf8Offset: 4)
        edit.setPreedit("XYZ")

        let specs = edit.richDisplaySpecs()
        #expect(specs.displayText == "abcdXYZ efgh ijkl mnop qrst")
        #expect(specs.preeditRange == 4..<7)
        #expect(specs.spans.contains { $0.byteRange == 4..<7 && ($0.weight ?? 0) >= 600 })

        edit.cancelPreedit()

        let ts = TextSystem()
        let style = TextStyle(size: 14).wrapped()
        let shaped = ts.shape(text: edit.text, style: style, maxWidth: 80, pixelScale: 1.0)
        let vLines = ts.visualLines(in: shaped)
        #expect(vLines.count >= 2)

        edit.setCursor(utf8Offset: 0)
        edit.lineEdge(end: true, in: shaped, textSystem: ts)
        let firstLineEndX = ts.caretRect(in: shaped, utf8Offset: edit.cursor, upstream: edit.caretAffinity == .upstream, pixelScale: 1.0)[0]
        #expect(edit.cursor == vLines[0].utf8End)

        edit.moveLine(delta: 1, in: shaped, textSystem: ts, pixelScale: 1.0)
        #expect(edit.caretColumn.goal == firstLineEndX)
        #expect(edit.cursor >= vLines[1].utf8Start && edit.cursor <= vLines[1].utf8End)

        // Secure field never leaks richDisplaySpecs or HTML
        edit.isSecure = true
        #expect(edit.toHTML().isEmpty)
        #expect(edit.richDisplaySpecs().spans.isEmpty)
        #expect(edit.richMarks.isEmpty)
    }
}
