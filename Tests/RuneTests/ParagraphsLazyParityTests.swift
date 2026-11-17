import Foundation
import Testing
import RuneMotion
@testable import Rune

/// By-paragraph field layout (`text/paragraphs.rs`), the lazy long paste
/// (`text/paragraphs/lazy.rs`) and its per-frame fill (`runtime/text_fill.rs`), upstream
/// 3aea1e4a (#865), 165f87a4 (#957) and 2371240d (#990). Upstream added no `#[test]`s for the
/// lazy paste; these drive the real code with upstream's constants.
@Suite("paragraphs.rs / lazy.rs / text_fill.rs parity")
@MainActor
struct ParagraphsLazyParityTests {
    static let style = TextStyle(size: 14, weight: 400)

    /// Lines of printable ASCII, each short enough to fit on one line at `width`.
    static func pasteLines(_ n: Int) -> String {
        (0..<n).map { "line \($0) of the paste" }.joined(separator: "\n")
    }

    static func wrapped(_ s: TextStyle) -> TextStyle {
        var st = s
        st.wrap = .wrap
        return st
    }

    static func request(_ field: UInt64) -> ParagraphRequest {
        ParagraphRequest(field: field, forced: .ltr, startFlow: .ltr)
    }

    // MARK: - Byte helpers

    @Test("countNewlines / commonStart / commonEnd / asciiPrintable agree with a byte-at-a-time count")
    func byteHelpers() {
        var text: [UInt8] = []
        for i in 0..<10_000 {
            let b: UInt8 = i % 37 == 0 ? 0x0a : UInt8(0x20 + i % 90)
            text.append(b)
        }
        for (a, b) in [(0, 0), (0, 7), (3, 19), (0, text.count), (4095, 8200)] {
            #expect(countNewlines(text, a, b) == text[a..<b].filter { $0 == 0x0a }.count)
        }
        var other = text
        other[9000] = 0x41
        #expect(commonStart(text, other) == 9000)
        #expect(commonEnd(text, other) == text.count - 9001)
        #expect(commonStart(text, text) == text.count)
        let short = Array(text[0..<5000])
        #expect(commonStart(text, short) == 5000)
        #expect(asciiPrintable(Array("abc def ~!".utf8), 0, 10))
        #expect(!asciiPrintable(Array("abcdefgh\tij".utf8), 0, 11))
        #expect(!asciiPrintable(Array("abcdefghé".utf8), 0, 10))
        #expect(!asciiPrintable(Array("ab\u{7f}".utf8), 0, 3))
    }

    @Test("AsciiLine measures each printable character once; oneLine sums them and narrowest splits at spaces")
    func asciiLineMeasures() throws {
        let ts = TextSystem()
        let ascii = try #require(ts.asciiLine(style: Self.style, scale: 2))
        #expect(ascii.advance.count == 95)
        #expect(ascii.widest == ascii.advance.max())
        #expect(ascii.height == Self.style.resolvedLineHeight * 2)
        let words = Array("ab cd".utf8)
        let sum = words.reduce(Float(0)) { $0 + ascii.advance[Int($1 - 0x20)] }
        let one = try #require(ascii.oneLine(words, 0, words.count, maxWidth: nil, floor: 0, printableKnown: false))
        #expect(one.0 == ascii.height)
        #expect(abs(one.1 - sum) < 1e-3)
        // Too wide for the width, with room kept for kerning: none.
        #expect(ascii.oneLine(words, 0, words.count, maxWidth: sum, floor: 0, printableKnown: false) == nil)
        // Not printable: none.
        let tab = Array("a\tb".utf8)
        #expect(ascii.oneLine(tab, 0, 3, maxWidth: nil, floor: 0, printableKnown: false) == nil)
        let narrow = try #require(ascii.narrowest(Array("ab cdef g".utf8), 0, 9, floor: 0))
        #expect(narrow.0 == ascii.height * 3)
        let cdef = Array("cdef".utf8).reduce(Float(0)) { $0 + ascii.advance[Int($1 - 0x20)] }
        #expect(abs(narrow.1 - cdef) < 1e-3)
        #expect(ascii.narrow(ascii.height - 1))
        #expect(!ascii.narrow(ascii.height))
    }

    // MARK: - By-paragraph layout

    @Test("a field of more than one paragraph lays out by paragraph, its lines where one layout puts them")
    func paragraphsStackLikeOneLayout() throws {
        let ts = TextSystem()
        let style = Self.wrapped(Self.style)
        let text = "first paragraph\nsecond one that is a little longer\n\nfourth"
        let box = ts.layoutInput(text: text, spans: nil, pills: [], style: style, maxWidth: 600, pixelScale: 1, emitGlyphs: false, request: Self.request(1))
        let pl = try #require(box.paragraphs)
        #expect(pl.paragraphs.map { [$0.start, $0.end] } == [[0, 15], [16, 50], [51, 51], [52, 58]])
        let whole = ts.layoutKeyed(text: text, style: style, maxWidth: 600, pixelScale: 1, emitGlyphs: false, keep: .owned)
        let a = box.shaped
        let b = whole.shaped
        #expect(a.lineStrings.count == b.lineStrings.count)
        for (x, y) in zip(a.lineStrings, b.lineStrings) {
            #expect(x.utf8Start == y.utf8Start)
            #expect(x.text == y.text)
            #expect(abs(x.originY - y.originY) <= 0.5)
        }
        #expect(a.size == b.size)
        for at in [0, 5, 15, 16, 30, 51, 52, 58] {
            let ca = ts.caretRect(in: a, utf8Offset: at, pixelScale: 1)
            let cb = ts.caretRect(in: b, utf8Offset: at, pixelScale: 1)
            #expect(abs(ca.x - cb.x) < 0.01, "caret x at \(at)")
            #expect(abs(ca.y - cb.y) <= 0.5, "caret y at \(at)")
        }
        // A press lands on the byte one layout gives.
        for (x, line) in [(Float(20), 1), (Float(3), 3), (Float(200), 0)] {
            let y = b.lineStrings[line].originY + 2
            #expect(ts.hitTestUTF8Offset(in: a, localX: x, localY: y, pixelScale: 1) == ts.hitTestUTF8Offset(in: b, localX: x, localY: y, pixelScale: 1))
        }
        // One line: one layout, as most drafts are.
        #expect(ts.layoutInput(text: "one line", spans: nil, pills: [], style: style, maxWidth: 600, pixelScale: 1, emitGlyphs: false, request: Self.request(1)).paragraphs == nil)
    }

    @Test("an edit shapes only the paragraph it changed; the others keep their layouts")
    func editShapesOnlyItsParagraph() throws {
        let ts = TextSystem()
        let style = Self.wrapped(Self.style)
        let lines = (0..<40).map { "paragraph number \($0)" }
        let text = lines.joined(separator: "\n")
        let first = try #require(ts.layoutInput(text: text, spans: nil, pills: [], style: style, maxWidth: 500, pixelScale: 2, emitGlyphs: false, request: Self.request(7)).paragraphs)
        #expect(first.paragraphs.count == 40)
        let before = ts.paragraphState.shapedParagraphs
        var edited = lines
        edited[17] += " typed"
        let second = try #require(ts.layoutInput(text: edited.joined(separator: "\n"), spans: nil, pills: [], style: style, maxWidth: 500, pixelScale: 2, emitGlyphs: false, request: Self.request(7)).paragraphs)
        #expect(ts.paragraphState.shapedParagraphs - before == 1)
        for k in 0..<40 where k != 17 {
            #expect(second.paragraphs[k].layout === first.paragraphs[k].layout)
        }
        #expect(second.paragraphs[17].layout !== first.paragraphs[17].layout)
        // The paragraphs after it moved by what it inserted.
        #expect(second.paragraphs[18].start == first.paragraphs[18].start + " typed".utf8.count)
        // At another width the kept paragraphs break again rather than shape.
        let shaped = ts.paragraphState.shapedParagraphs
        _ = ts.layoutInput(text: edited.joined(separator: "\n"), spans: nil, pills: [], style: style, maxWidth: 120, pixelScale: 2, emitGlyphs: false, request: Self.request(7))
        #expect(ts.paragraphState.shapedParagraphs == shaped)
    }

    @Test("an NFC paragraph edited to its NFD form gets its own layout: keys and cache are by bytes")
    func nfcToNfdParagraphIsReshaped() throws {
        let ts = TextSystem()
        let style = Self.wrapped(Self.style)
        let nfc = "caf\u{E9}\nb"
        let nfd = "cafe\u{301}\nb"
        #expect(nfc == nfd)
        let first = try #require(ts.layoutInput(text: nfc, spans: nil, pills: [], style: style, maxWidth: 300, pixelScale: 1, emitGlyphs: false, request: Self.request(21)).paragraphs)
        #expect(first.content == Array(nfc.utf8))
        #expect(first.paragraphs[0].end == 5)
        let shaped = ts.paragraphState.shapedParagraphs
        let second = try #require(ts.layoutInput(text: nfd, spans: nil, pills: [], style: style, maxWidth: 300, pixelScale: 1, emitGlyphs: false, request: Self.request(21)).paragraphs)
        #expect(second !== first)
        #expect(second.content == Array(nfd.utf8))
        let bounds: [[Int]] = second.paragraphs.map { [$0.start, $0.end] }
        #expect(bounds == [[0, 6], [7, 8]])
        // The edited paragraph is shaped again from its own bytes; the one after it is kept.
        #expect(ts.paragraphState.shapedParagraphs - shaped == 1)
        #expect(second.paragraphs[0].key != first.paragraphs[0].key)
        #expect(second.paragraphs[0].layout !== first.paragraphs[0].layout)
        #expect(Array(second.paragraphs[0].layout.authText.utf8) == Array("cafe\u{301}".utf8))
        #expect(second.paragraphs[1].layout === first.paragraphs[1].layout)
        let lines = second.composed.lineStrings
        let lineStarts: [Int] = lines.map { $0.utf8Start }
        #expect(lineStarts == [0, 7])
        #expect(Array(lines[0].text.utf8) == Array("cafe\u{301}".utf8))
        // After the commit ends, the NFD text in another field still isn't the NFC layout.
        ts.endCommit()
        let other = try #require(ts.layoutInput(text: "x\n" + "cafe\u{301}", spans: nil, pills: [], style: style, maxWidth: 300, pixelScale: 1, emitGlyphs: false, request: Self.request(22)).paragraphs)
        let p1 = other.paragraphs[1]
        #expect(p1.start == 2 && p1.end == 8)
        #expect(Array(p1.layout.authText.utf8) == Array("cafe\u{301}".utf8))
        // One text's bytes are read once a pass, and only for the same bytes.
        #expect(ts.paragraphState.bytes(of: nfc) == Array(nfc.utf8))
        #expect(ts.paragraphState.bytes(of: nfd) == Array(nfd.utf8))
    }

    // MARK: - Lazy long paste

    @Test("a paste of more than LAZY_MIN lines shapes its last EAGER_END and first EAGER_START lines, the rest wait in runs")
    func longPasteWaitsInRuns() throws {
        #expect(ParagraphConstants.lazyMin == 64)
        #expect(ParagraphConstants.eagerEnd == 24)
        #expect(ParagraphConstants.eagerStart == 4)
        #expect(ParagraphConstants.runLines == 512)
        let ts = TextSystem()
        let style = Self.wrapped(Self.style)
        let n = 1200
        let text = Self.pasteLines(n)
        let pl = try #require(ts.layoutInput(text: text, spans: nil, pills: [], style: style, maxWidth: 400, pixelScale: 2, emitGlyphs: false, request: Self.request(3)).paragraphs)
        #expect(pl.waiting)
        let shaped = pl.paragraphs.filter(\.shaped)
        #expect(shaped.count == ParagraphConstants.eagerStart + ParagraphConstants.eagerEnd)
        let starts = Array(text.utf8).enumerated().filter { $0.element == 0x0a }.map { $0.offset + 1 }
        let lineStarts = [0] + starts
        #expect(Array(shaped.prefix(4).map(\.start)) == Array(lineStarts.prefix(4)))
        #expect(Array(shaped.suffix(24).map(\.start)) == Array(lineStarts.suffix(24)))
        // The waiting lines are runs of at most RUN_LINES, at their exact height.
        let ascii = try #require(ts.asciiLine(style: style, scale: 2))
        let runs = pl.paragraphs.filter { !$0.shaped }
        #expect(runs.allSatisfy { $0.run && $0.lines <= UInt32(ParagraphConstants.runLines) })
        #expect(runs.reduce(0) { $0 + Int($1.lines) } == n - 28)
        #expect(runs.count == Int((Double(n - 28) / 512).rounded(.up)))
        for r in runs { #expect(r.height == Float(r.lines) * ascii.height) }
        // A paste of LAZY_MIN lines shapes them all.
        let small = try #require(TextSystem().layoutInput(text: Self.pasteLines(64), spans: nil, pills: [], style: style, maxWidth: 400, pixelScale: 2, emitGlyphs: false, request: Self.request(3)).paragraphs)
        #expect(!small.waiting)
    }

    @Test("the fill shapes waiting lines within its budget, the rows shown first, at the heights they waited at")
    func fillShapesWithinBudgetAtExactHeights() throws {
        let ts = TextSystem()
        let style = Self.wrapped(Self.style)
        let n = 900
        let text = Self.pasteLines(n)
        var laid = try #require(ts.layoutInput(text: text, spans: nil, pills: [], style: style, maxWidth: 400, pixelScale: 2, emitGlyphs: false, request: Self.request(4)).paragraphs)
        let height = laid.height
        // A frame's fill: the rows near line 500 first, a run taken apart there.
        let lh = try #require(ts.asciiLine(style: style, scale: 2)).height
        let rows = (Float(500) * lh, Float(520) * lh)
        let (one, moved) = try #require(ts.fillParagraphs(laid, budget: textFillBudget, rows: rows, reach: .infinity))
        #expect(!moved)
        #expect(one.height == height)
        let hit = one.piece(atY: rows.0 + 1)
        #expect(one.paragraphs[hit.index].shaped)
        #expect(one.paragraphs.count > laid.paragraphs.count)
        #expect(one.waitingLines < laid.waitingLines)
        // Filled to the end, frame by frame: every height the eager whole layout gives.
        laid = one
        var frames = 0
        while laid.waiting, frames < 10_000 {
            let start = DispatchTime.now().uptimeNanoseconds
            let (next, moved) = try #require(ts.fillParagraphs(laid, budget: textFillBudget, rows: rows, reach: .infinity))
            let spent = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            #expect(!moved)
            // One paragraph past the budget at most (it checks before each).
            #expect(spent < textFillBudget + 0.05)
            #expect(next.waitingLines < laid.waitingLines)
            laid = next
            frames += 1
        }
        #expect(!laid.waiting)
        #expect(frames > 1)
        #expect(laid.paragraphs.count == n)
        let whole = ts.layoutKeyed(text: text, style: style, maxWidth: 400, pixelScale: 2, emitGlyphs: false, keep: .owned).shaped
        #expect(whole.lineStrings.count == n)
        #expect(laid.height == Float(n) * whole.lineHeight * 2)
        for (k, p) in laid.paragraphs.enumerated() {
            #expect(p.y == (whole.lineTopPt(k) * 2).rounded())
            #expect(p.height == whole.lineBoxHeightPt(k) * 2)
        }
        #expect(laid.composed.size == whole.size)
    }

    // MARK: - Runtime wiring

    struct S {
        var field = TextEdit("", multiline: true)
    }

    static func runtime() -> Runtime<S> {
        Runtime(state: S(), viewport: Vec2(400, 300), pixelScale: 2.0) { _, _ in
            col().size(400, 300)
                .child(textInput(key: "field", \S.field).font(Self.style).size(400, 300))
        }
    }

    static func fieldBox(_ rt: Runtime<S>) -> (NodeId, TextLayoutBox)? {
        rt.nodeTextLayouts.first { $0.value.isInput && $0.value.box.paragraphs != nil }.map { ($0.key, $0.value.box) }
    }

    @Test("a long paste into a field fills over frames reporting the text-fill source, then stops")
    func runtimeFillsOverFramesWithTextFillSource() throws {
        #expect(AnimSource.textFill == 1024)
        #expect(AnimSource.names(AnimSource.textFill) == ["text-fill"])
        let rt = Self.runtime()
        _ = rt.frame(at: 0.0)
        rt.update { _, tx in tx.focus("field") }
        _ = rt.frame(at: 0.0)
        let n = 1500
        rt.paste(Self.pasteLines(n))
        _ = rt.frame(at: 0.016)
        #expect(rt.state.field.text.utf8.count == Self.pasteLines(n).utf8.count)
        let (id, box) = try #require(Self.fieldBox(rt))
        let first = try #require(box.paragraphs)
        // The first paint drew rows and noted them; its fill ran already.
        #expect(rt.isAnimating)
        #expect((rt.animSources & AnimSource.textFill) != 0)
        #expect(rt.textRows[id] != nil || !first.waiting)
        var t = 0.016
        var frames = 0
        var lastWaiting = Int.max
        while let p = Self.fieldBox(rt)?.1.paragraphs, p.waiting, frames < 20_000 {
            #expect(p.waitingLines <= lastWaiting)
            lastWaiting = p.waitingLines
            #expect((rt.animSources & AnimSource.textFill) != 0)
            t += 0.016
            _ = rt.frame(at: t)
            frames += 1
        }
        let done = try #require(Self.fieldBox(rt)?.1.paragraphs)
        #expect(!done.waiting)
        #expect(done.paragraphs.count == n)
        #expect(rt.textRows.isEmpty)
        t += 0.016
        _ = rt.frame(at: t)
        #expect((rt.animSources & AnimSource.textFill) == 0)
    }

    struct RichS {
        var field: TextEdit = {
            var e = TextEdit("", multiline: true)
            e.isRichEnabled = true
            return e
        }()
    }

    @Test("a rich field with no marks lays out by paragraph and a long paste's lines wait (blocks all paragraphs)")
    func richFieldLongPasteWaits() throws {
        let rt = Runtime(state: RichS(), viewport: Vec2(400, 300), pixelScale: 2.0) { _, _ in
            col().size(400, 300)
                .child(textInput(key: "field", \RichS.field).font(Self.style).size(400, 300))
        }
        _ = rt.frame(at: 0.0)
        rt.update { _, tx in tx.focus("field") }
        _ = rt.frame(at: 0.0)
        let n = ParagraphConstants.lazyMin * 10
        // A rich field reads the clipboard's rich flavours first; the paste lands through its edit.
        rt.update { s, _ in s.field.paste(Self.pasteLines(n)) }
        #expect(rt.state.field.text == Self.pasteLines(n))
        #expect(rt.state.field.isRichEnabled)
        // The rich resolve shows one `.paragraph` block per line.
        let el = textInput(key: "field", \RichS.field).font(Self.style)
        let resolved = ElDisplayResolver.resolveInput(el: el, edit: rt.state.field, innerWidth: 400)
        #expect(resolved.isRich)
        #expect(resolved.blocks.count == n)
        #expect(resolved.blocks.allSatisfy { $0 == .paragraph })
        // Laid out without a frame's fill: the lines away from the paste's ends wait in runs.
        let ts = TextSystem()
        let request = try #require(Runtime<RichS>.paragraphRequest(field: NodeId(1), el: el, edit: rt.state.field, resolved: resolved))
        let pl = try #require(ts.layoutInput(text: resolved.renderedString, spans: resolved.spans, pills: resolved.pills, style: resolved.style, maxWidth: 400, pixelScale: 2, emitGlyphs: false, request: request).paragraphs)
        #expect(pl.waiting)
        #expect(pl.paragraphs.filter { $0.shaped }.count == ParagraphConstants.eagerStart + ParagraphConstants.eagerEnd)
        #expect(pl.waitingLines == n - ParagraphConstants.eagerStart - ParagraphConstants.eagerEnd)
        // In the runtime the field holds a by-paragraph layout and fills it over frames.
        _ = rt.frame(at: 0.016)
        let box = try #require(rt.nodeTextLayouts.first { $0.value.isInput }?.value.box)
        #expect(box.paragraphs != nil)
        // A block that isn't a paragraph keeps one layout (blocks aren't ported to paragraphs).
        var quoted = resolved
        quoted.blocks[0] = .quote
        #expect(Runtime<RichS>.paragraphRequest(field: NodeId(1), el: el, edit: rt.state.field, resolved: quoted) == nil)
    }

    @Test("a commit's end forgets its last layout and keeps stale layouts within STALE_BYTES")
    func commitEndForgetsLastAndEvictsStale() throws {
        let ts = TextSystem()
        let style = Self.wrapped(Self.style)
        _ = ts.layoutInput(text: "a\nb", spans: nil, pills: [], style: style, maxWidth: 300, pixelScale: 1, emitGlyphs: false, request: Self.request(11))
        #expect(ts.paragraphState.lastParagraphs != nil)
        ts.endCommit()
        #expect(ts.paragraphState.lastParagraphs == nil)
        #expect(ParagraphState.staleBytes == 3 << 20)
        // `evict_to`: stale entries past the budget go oldest first; the last two commits' stay.
        let laid = try #require(ts.paragraphState.cache.values.first?.layout)
        var cache: [UInt64: ParagraphCacheEntry] = [:]
        for (k, used) in [(1, 10), (2, 9), (3, 7), (4, 5)] as [(UInt64, UInt64)] {
            var e = ParagraphCacheEntry(laid, used: used, textLen: 0)
            e.cost = 100
            cache[k] = e
        }
        ParagraphState.evict(&cache, 10, budget: 150)
        // Ages 0 and 1 aren't stale; of the stale (ages 3 and 5) only the younger fits.
        #expect(Set(cache.keys) == [1, 2, 3])
        ParagraphState.evict(&cache, 10, budget: 0)
        #expect(Set(cache.keys) == [1, 2])
        #expect(ParagraphCacheEntry(laid, used: 0, textLen: 10).cost == 10 * 64 + 2048)
    }

    @Test("a caret key or a press near waiting lines shapes them first; typing does not")
    func caretKeyAndPressFillNearRows() throws {
        #expect(Runtime<S>.readsTextLayout(KeyEvent(key: .arrowUp)))
        #expect(Runtime<S>.readsTextLayout(KeyEvent(key: .home)))
        #expect(Runtime<S>.readsTextLayout(KeyEvent(key: .text("a"), mods: Mods(cmd: true))))
        #expect(!Runtime<S>.readsTextLayout(KeyEvent(key: .text("a"))))
        #expect(!Runtime<S>.readsTextLayout(KeyEvent(key: .backspace)))
        #expect(!Runtime<S>.readsTextLayout(KeyEvent(key: .delete)))
        #expect(Runtime<S>.readsTextLayout(KeyEvent(key: .backspace, mods: Mods(alt: true))))

        let rt = Self.runtime()
        _ = rt.frame(at: 0.0)
        rt.update { _, tx in tx.focus("field") }
        _ = rt.frame(at: 0.0)
        rt.paste(Self.pasteLines(3000))
        _ = rt.frame(at: 0.016)
        let (id, box) = try #require(Self.fieldBox(rt))
        let before = try #require(box.paragraphs)
        try #require(before.waiting)
        #expect(rt.textRows[id] != nil)
        let lh = try #require(rt.textSystem.asciiLine(style: Self.wrapped(Self.style), scale: 2)).height
        func unshaped(_ p: ParagraphLayout, _ rows: (Float, Float)) -> Int {
            p.paragraphs.filter { !$0.shaped && $0.y + $0.height >= rows.0 && $0.y <= rows.1 }.count
        }
        // Rows the field shows far from its caret (scrolled to line 1500), not filled yet.
        let far = (Float(1500) * lh, Float(1530) * lh)
        #expect(unshaped(before, far) > 0)
        rt.textRows[id] = far
        // Typing at the caret reads no layout: nothing is filled for it.
        _ = rt.keyDown(KeyEvent(key: .text("x")), at: 0.02)
        #expect(Self.fieldBox(rt)?.1 === box)
        // A caret key: every waiting line within a window's height of the rows shown is shaped.
        _ = rt.keyDown(KeyEvent(key: .arrowUp), at: 0.03)
        let afterKey = try #require(rt.nodeTextLayouts[id]?.box.paragraphs)
        #expect(afterKey !== before)
        let reach = (far.1 - far.0) + 1
        #expect(unshaped(afterKey, (far.0 - reach, far.1 + reach)) == 0)

        // A press: the same, for rows elsewhere still waiting.
        let rt2 = Self.runtime()
        _ = rt2.frame(at: 0.0)
        rt2.update { _, tx in tx.focus("field") }
        _ = rt2.frame(at: 0.0)
        rt2.paste(Self.pasteLines(3000))
        _ = rt2.frame(at: 0.016)
        let (id2, box2) = try #require(Self.fieldBox(rt2))
        let waiting2 = try #require(box2.paragraphs)
        let rows2 = (Float(800) * lh, Float(830) * lh)
        #expect(unshaped(waiting2, rows2) > 0)
        rt2.textRows[id2] = rows2
        rt2.pointerDown(at: Vec2(10, 10), at: 0.02)
        let afterPress = try #require(rt2.nodeTextLayouts[id2]?.box.paragraphs)
        #expect(unshaped(afterPress, (rows2.0 - (rows2.1 - rows2.0) - 1, rows2.1 + (rows2.1 - rows2.0) + 1)) == 0)
        rt2.pointerUp(at: Vec2(10, 10), at: 0.03)
    }

    @Test("fillTextNear shapes all waiting lines within reach of the rows, whatever the budget")
    func fillNearShapesWithinReach() throws {
        let ts = TextSystem()
        let style = Self.wrapped(Self.style)
        let laid = try #require(ts.layoutInput(text: Self.pasteLines(2000), spans: nil, pills: [], style: style, maxWidth: 400, pixelScale: 2, emitGlyphs: false, request: Self.request(9)).paragraphs)
        let lh = try #require(ts.asciiLine(style: style, scale: 2)).height
        let rows = (Float(1000) * lh, Float(1040) * lh)
        let reach = (rows.1 - rows.0) * 1.0 + 1
        let (near, moved) = try #require(ts.fillParagraphs(laid, budget: .infinity, rows: rows, reach: reach))
        #expect(!moved)
        #expect(near.waiting)
        for p in near.paragraphs {
            let d: Float = (p.y + p.height >= rows.0 && p.y <= rows.1) ? 0 : max(rows.0 - p.y - p.height, p.y - rows.1)
            if d <= reach { #expect(p.shaped, "line at \(p.y) within reach is shaped") }
        }
        // A caret in a filled line hits and lays out as an eager layout's.
        let whole = ts.layoutKeyed(text: Self.pasteLines(2000), style: style, maxWidth: 400, pixelScale: 2, emitGlyphs: false, keep: .owned).shaped
        let at = near.piece(atY: rows.0 + 1).start + 3
        let c1 = ts.caretRect(in: near.composed, utf8Offset: at, pixelScale: 2)
        let c2 = ts.caretRect(in: whole, utf8Offset: at, pixelScale: 2)
        #expect(abs(c1.x - c2.x) < 0.01)
        #expect(abs(c1.y - c2.y) <= 0.5)
    }
}
