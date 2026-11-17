import Foundation
import Testing
import RuneMotion
@testable import Rune
#if canImport(CoreText)
import CoreText
#endif

/// The by-paragraph field's directions, pill isolates and line-break selection
/// (`text/paragraphs.rs` as of 615f06a4: `TextFlow::range_boxes` and `newline`, `flow_of`,
/// `key_paragraphs`' `start_flow`/`forced`, `with_isolates`; `TextSpec::by_paragraph`,
/// `paragraphs_flow` and `plaintext_flow` from #865 3aea1e4a). Upstream has no `#[test]`s for
/// these; the cases drive the real layout with upstream's rules.
@Suite("paragraphs.rs flows, isolates and range_boxes parity")
@MainActor
struct ParagraphsFlowParityTests {
    static let style: TextStyle = {
        var s = TextStyle(size: 14, weight: 400)
        s.wrap = .wrap
        return s
    }()

    /// `newline`: a quarter of the primary font's ascent and descent at the field's size, points.
    static func newlinePt(_ ts: TextSystem, scale: Float) throws -> Float {
        #if canImport(CoreText) && canImport(CoreGraphics)
        let font = ts.resolveCTFont(style: style, pixelScale: scale)
        return 0.25 * Float(CTFontGetAscent(font) + abs(CTFontGetDescent(font))) / scale
        #elseif canImport(CRuneDesktopText)
        let line = DesktopTextLine(text: " ", start: 0, style: style, families: ts.families(),
                                   language: ts.language, scale: scale, span: { _ in nil })
        #if os(Linux) || os(Windows)
        return 0.25 * (try #require(line)).strutFontHeightPt
        #else
        return 0.25 * (line?.strutFontHeightPt ?? style.size)
        #endif
        #else
        return 0.25 * style.size
        #endif
    }

    @Test("a selection across a paragraph break shows the break newline-wide at the end of its line (range_boxes)")
    func selectedLineBreakShowsNewlineWidth() throws {
        let ts = TextSystem()
        let text = "ab\n\ncd"
        let req = ParagraphRequest(field: 1, forced: .ltr, startFlow: .ltr)
        let box = ts.layoutInput(text: text, spans: nil, pills: [], style: Self.style, maxWidth: 300, pixelScale: 2, emitGlyphs: false, request: req)
        let pl = try #require(box.paragraphs)
        #expect(pl.paragraphs.count == 3)
        let shaped = box.shaped
        let ws = try Self.newlinePt(ts, scale: 2)
        #expect(abs(shaped.paragraphNewlinePt - ws) < 1e-4)
        // Each paragraph's own boxes, as its own layout gives them.
        let ab = ts.layoutKeyed(text: "ab", style: Self.style, maxWidth: 300, pixelScale: 2, emitGlyphs: false, keep: .owned).shaped
        let abBox = try #require(ts.selectionRects(in: ab, utf8Range: 0..<2, pixelScale: 2).first)
        let rects = ts.selectionRects(in: shaped, utf8Range: 0..<text.utf8.count, pixelScale: 2)
        #expect(rects.count == 3)
        // "ab" and its line break: its box grows by the newline's width.
        #expect(abs(rects[0].x - abBox.x) < 1e-3)
        #expect(abs(rects[0].z - (abBox.z + ws)) < 1e-3)
        // The blank paragraph: only its line break, from its start, its height.
        #expect(abs(rects[1].x) < 1e-3)
        #expect(abs(rects[1].z - ws) < 1e-3)
        #expect(abs(rects[1].y - pl.paragraphs[1].y / 2) < 1e-3)
        #expect(abs(rects[1].w - pl.paragraphs[1].height / 2) < 1e-3)
        // The last paragraph has no line break after it.
        let cd = ts.layoutKeyed(text: "cd", style: Self.style, maxWidth: 300, pixelScale: 2, emitGlyphs: false, keep: .owned).shaped
        let cdBox = try #require(ts.selectionRects(in: cd, utf8Range: 0..<2, pixelScale: 2).first)
        #expect(abs(rects[2].z - cdBox.z) < 1e-3)
        // A selection ending at a paragraph's end doesn't take its line break.
        let upTo = ts.selectionRects(in: shaped, utf8Range: 0..<2, pixelScale: 2)
        #expect(upTo.count == 1)
        #expect(abs(upTo[0].z - abBox.z) < 1e-3)
        // One starting at the break: only the break, at the line's end.
        let fromEnd = ts.selectionRects(in: shaped, utf8Range: 2..<3, pixelScale: 2)
        #expect(fromEnd.count == 1)
        let abEnd = ab.lineAdvancesPx[0].widthPx / 2
        #expect(abs(fromEnd[0].x - abEnd) < 1e-3)
        #expect(abs(fromEnd[0].z - ws) < 1e-3)
    }

    @Test("a right-to-left paragraph's selected line break shows on its left")
    func rtlLineBreakOnTheLeft() throws {
        let ts = TextSystem()
        let text = "\u{645}\u{631}\u{62D}\u{628}\u{627}\nb"
        let req = ParagraphRequest(field: 2, forced: nil, startFlow: .ltr)
        let box = ts.layoutInput(text: text, spans: nil, pills: [], style: Self.style, maxWidth: 300, pixelScale: 2, emitGlyphs: false, request: req)
        let pl = try #require(box.paragraphs)
        #expect(pl.paragraphs.map(\.flow) == [.rtl, .ltr])
        let ws = box.shaped.paragraphNewlinePt
        let first = pl.paragraphs[0]
        let line = try #require(box.shaped.textTestLines.first)
        let advance = try #require(box.shaped.lineAdvancesPx.first)
        #expect(abs(line.originX + advance.widthPx / 2 - 300) < 0.01)
        let own = ts.selectionRects(in: first.layout.shaped, utf8Range: 0..<first.end, pixelScale: 2)
        let ownLeft = try #require(own.map(\.x).min())
        let rects = ts.selectionRects(in: box.shaped, utf8Range: 0..<(first.end + 1), pixelScale: 2)
        #expect(rects.count == own.count)
        let left = try #require(rects.map(\.x).min())
        #expect(abs(left - (ownLeft - ws)) < 1e-3)
    }

    @Test("drawing one visible paragraph emits atlas glyphs at authored UTF-8 offsets")
    func visibleParagraphGlyphs() throws {
        let ts = TextSystem()
        let box = ts.layoutInput(text: "é\nWQ\nfern", spans: nil, pills: [], style: Self.style,
                                 maxWidth: 240, pixelScale: 2, emitGlyphs: false,
                                 request: ParagraphRequest(field: 5, forced: .ltr, startFlow: .ltr))
        let layout = try #require(box.paragraphs)
        let paragraph = layout.paragraphs[1]
        let center = paragraph.y + paragraph.height / 2
        let drawn = layout.glyphs(top: center, bottom: center, using: ts)
        let origin = "é\n".utf8.count
        #expect(Set(drawn.map(\.utf8Offset)) == [origin, origin + 1])
        #expect(drawn.contains { $0.rect.z > 0 && $0.rect.w > 0 && $0.uv.z > $0.uv.x })
        let own = layout.glyphs(at: 1, using: ts)
        #expect(drawn.map(\.rect.y) == own.map { $0.rect.y + paragraph.y / 2 })

        let previous = layout.paragraphs[1].layout
        let hidden = layout.paragraphs[0].layout
        previous.shaped.glyphs[0].rect.y += 5
        ts.forgetRasterState()
        let fresh = layout.glyphs(top: center, bottom: center, using: ts)
        #expect(fresh == drawn)
        #expect(previous.shaped.glyphs[0].rect.y == own[0].rect.y + 5)
        #expect(layout.paragraphs[0].layout === hidden)
        #expect(!hidden.hasGlyphs)
    }

    @Test("by-paragraph keys: a paragraph with no strong character reads as the one before it, the first the start flow")
    func neutralParagraphsInheritFlow() throws {
        let ts = TextSystem()
        let arabic = "\u{645}\u{631}\u{62D}\u{628}\u{627}"
        // `dirByParagraph` under a right-to-left element: the first neutral line starts right to left.
        let underRtl = try #require(ts.layoutInput(text: "123\nabc\n456\n\(arabic)\n789", spans: nil, pills: [], style: Self.style, maxWidth: 300, pixelScale: 1, emitGlyphs: false, request: ParagraphRequest(field: 3, forced: nil, startFlow: .rtl)).paragraphs)
        #expect(underRtl.paragraphs.map(\.flow) == [.rtl, .ltr, .ltr, .rtl, .rtl])
        // Forced (`paragraphs_flow`): every paragraph reads the element's way.
        let forced = try #require(ts.layoutInput(text: "abc\n\(arabic)", spans: nil, pills: [], style: Self.style, maxWidth: 300, pixelScale: 1, emitGlyphs: false, request: ParagraphRequest(field: 4, forced: .ltr, startFlow: .ltr)).paragraphs)
        #expect(forced.paragraphs.map(\.flow) == [.ltr, .ltr])
        // The stacked lines carry each paragraph's base direction for caret motion.
        #expect(underRtl.composed.lineIsRTL == [true, false, false, true, true])
    }

    @Test("one layout of a dirByParagraph text resolves paragraphs as key_paragraphs does")
    func singleLayoutPlaintextParagraphs() throws {
        let ts = TextSystem()
        let arabic = "\u{645}\u{631}\u{62D}\u{628}\u{627}"
        var plain = Self.style
        plain.byParagraphStart = .ltr
        let a = ts.shape(text: "\(arabic)\n123\nhello", style: plain, maxWidth: 300, pixelScale: 1, emitGlyphs: false)
        #expect(a.lineIsRTL == [true, true, false])
        let line = try #require(a.textTestLines.first)
        let advance = try #require(a.lineAdvancesPx.first)
        #expect(abs(line.originX + advance.widthPx - 300) < 0.01)
        var rtlStart = Self.style
        rtlStart.byParagraphStart = .rtl
        let b = ts.shape(text: "123\nhello", style: rtlStart, maxWidth: 300, pixelScale: 1, emitGlyphs: false)
        #expect(b.lineIsRTL == [true, false])
        // Without it, a neutral line takes its natural direction.
        let c = ts.shape(text: "\(arabic)\n123", style: Self.style, maxWidth: 300, pixelScale: 1, emitGlyphs: false)
        #expect(c.lineIsRTL == [true, false])
        // Arabic-Indic digits are weak, and a directional isolate keeps its contents private.
        let mixed = ts.shape(text: "\u{0661}\u{0662} English\n\u{2068}\(arabic)\u{2069} English",
                             style: Self.style, maxWidth: 300, pixelScale: 1, emitGlyphs: false)
        #expect(mixed.lineIsRTL == [false, false])
    }

    @Test("a by-paragraph field's pill label is isolated: its paragraph's direction skips it (with_isolates, flow_of)")
    func pillLabelsAreIsolated() throws {
        let ts = TextSystem()
        let arabic = "\u{645}\u{631}\u{62D}\u{628}\u{627}"
        let label = "@src/app.ts"
        let text = "\(label) \(arabic)\nnext"
        let pill = PillChip(0..<label.utf8.count)
        var byParagraph = Self.style
        byParagraph.byParagraphStart = .ltr
        let isolated = ts.shape(text: text, pills: [pill], style: byParagraph, maxWidth: 400, pixelScale: 1, emitGlyphs: false)
        // The label's letters don't count: the line reads right to left from its Arabic.
        #expect(isolated.lineIsRTL.first == true)
        // One layout of the same text that isn't by paragraph reads the label's letters first.
        let whole = ts.shape(text: text, pills: [pill], style: Self.style, maxWidth: 400, pixelScale: 1, emitGlyphs: false)
        #expect(whole.lineIsRTL.first == false)
        // On CoreText inline advance markers, FSI and PDI are part of the laid-out string.
        #if canImport(CoreText) && canImport(CoreGraphics)
        #expect(isolated.markerMap.entries.count == 4)
        #expect(whole.markerMap.entries.count == 2)
        // A caret either side of the pill and inside its label lands where the markers map it.
        for at in [0, label.utf8.count, label.utf8.count + 1] {
            let u16 = String(decoding: Array(text.utf8)[..<at], as: UTF8.self).utf16.count
            let shapedU16 = isolated.markerMap.shapedU16(forAuthU16: u16)
            #expect(isolated.markerMap.authU16(forShapedU16: shapedU16) == u16)
        }
        #endif
        #if canImport(CoreText) || os(Linux) || os(Windows)
        // The Arabic word is visually to the left of the isolated label in this RTL paragraph.
        let wordStart = label.utf8.count + 1
        let word = ts.selectionRects(in: isolated, utf8Range: wordStart..<(wordStart + arabic.utf8.count), pixelScale: 1)
        let middle = ts.selectionRects(in: isolated, utf8Range: 1..<4, pixelScale: 1)
        let wordRight = try #require(word.map { $0.x + $0.z }.max())
        let labelLeft = try #require(middle.map(\.x).min())
        #expect(wordRight <= labelLeft + 0.01)
        let chip = try #require(isolated.pillChips.first).rect
        #expect(wordRight <= chip.x + 1)
        #expect(chip.x <= labelLeft && labelLeft < chip.x + chip.z)
        let caret = ts.caretRect(in: isolated, utf8Offset: 2, pixelScale: 1)
        #expect(ts.hitTestUTF8Offset(in: isolated, localX: caret.x, localY: caret.y + caret.w / 2, pixelScale: 1) == 2)
        #endif
    }

    // MARK: - TextSpec::by_paragraph / paragraphs_flow / plaintext_flow

    struct S {
        var field = TextEdit("", multiline: true)
        var line = TextEdit("")
    }

    @Test("a wrapped multi-line field lays out by paragraph in its text's direction; dirByParagraph in its element's")
    func byParagraphStyleResolves() {
        let arabic = "\u{645}\u{631}\u{62D}\u{628}\u{627}"
        let el = textInput(key: "f", \S.field).font(Self.style)
        func resolved(_ text: String, _ el: El<S>) -> ElResolvedInput {
            ElDisplayResolver.resolveInput(el: el, edit: TextEdit(text, multiline: true), innerWidth: 300)
        }
        // One paragraph, not dirByParagraph: one layout, no forced direction.
        #expect(resolved("hello", el).style.byParagraphStart == nil)
        #expect(resolved("hello", el).style.direction == nil)
        // More than one: every paragraph the whole text's first strong character's way.
        let ltrFirst = resolved("hello\n\(arabic)", el).style
        #expect(ltrFirst.direction == .ltr)
        #expect(ltrFirst.byParagraphStart == .ltr)
        let rtlFirst = resolved("\(arabic)\nhello", el).style
        #expect(rtlFirst.direction == .rtl)
        #expect(rtlFirst.byParagraphStart == .rtl)
        // dirByParagraph: by paragraph however many, each its own way, from the element's flow.
        var plain = el.dirByParagraph()
        let own = resolved("hello", plain).style
        #expect(own.direction == nil)
        #expect(own.byParagraphStart == .ltr)
        plain.textStyle.byParagraphStart = .rtl
        #expect(resolved("123", plain).style.byParagraphStart == .rtl)
        // A one-line field, a secure one, or a placeholder stays one text.
        let line = textInput(key: "l", \S.line).font(Self.style).dirByParagraph().singleLine()
        #expect(ElDisplayResolver.resolveInput(el: line, edit: TextEdit("a\nb"), innerWidth: 300).style.byParagraphStart == nil)
        var secure = TextEdit("a\nb", multiline: true)
        secure.isSecure = true
        #expect(ElDisplayResolver.resolveInput(el: el, edit: secure, innerWidth: 300).style.byParagraphStart == nil)
        #expect(resolved("", plain.placeholder("type")).style.byParagraphStart == nil)
    }

    @Test("a dirByParagraph field under a right-to-left element starts its paragraphs right to left")
    func plaintextFieldTakesElementFlow() throws {
        let rt = Runtime(state: S(field: TextEdit("123\nabc", multiline: true)), viewport: Vec2(400, 300), pixelScale: 2.0) { _, _ in
            col().size(400, 300).dir(.rtl)
                .child(textInput(key: "field", \S.field).font(Self.style).size(400, 300).dirByParagraph())
        }
        _ = rt.frame(at: 0.0)
        let box = try #require(rt.nodeTextLayouts.first { $0.value.isInput }?.value.box)
        let pl = try #require(box.paragraphs)
        #expect(pl.paragraphs.map(\.flow) == [.rtl, .ltr])
    }
}
