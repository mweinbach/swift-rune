import Foundation
import Testing
@testable import Rune
import RuneMotion

@Suite("Line Clamp Parity (line_clamp_tests.rs)")
struct LineClampParityTests {
    private static let title = "The quick brown fox jumps over the lazy dog and adds several words so line wrapping has enough text to overflow two lines cleanly"
    private static let token = "line_clamp_measures_the_whole_identifier_before_it_decides_where_the_ellipsis_falls"
    private static let style = TextStyle(size: 13.0, lineHeight: 16.0)
    private static let markColor = Color(r: 0.95, g: 0.25, b: 0.25, a: 1.0)

    private struct ClampState {
        var text: String
        var lines: Int
        var mark: Range<Int>?
    }

    private func makeClamp(
        _ content: String,
        lines: Int,
        mark: Range<Int>? = nil,
        width: Float
    ) -> Runtime<ClampState> {
        let rt = Runtime<ClampState>(
            state: ClampState(text: content, lines: lines, mark: mark),
            viewport: Vec2(width, 400.0),
            pixelScale: 2.0
        ) { s, _ in
            var t: El<ClampState>
            if let r = s.mark {
                let utf8 = Array(s.text.utf8)
                let a = min(r.lowerBound, utf8.count)
                let b = max(a, min(r.upperBound, utf8.count))
                let s0 = String(decoding: utf8[0..<a], as: UTF8.self)
                let s1 = String(decoding: utf8[a..<b], as: UTF8.self)
                let s2 = String(decoding: utf8[b..<utf8.count], as: UTF8.self)
                t = rich([
                    TextSpan(s0),
                    TextSpan(s1, color: Self.markColor),
                    TextSpan(s2),
                ])
                .link(TextLink(r, id: "hit"))
            } else {
                t = text(s.text)
            }
            t = t.key("t").font(Self.style).wFull().wrapText().selectable()
            if s.lines > 0 {
                t = t.maxLines(s.lines)
            }
            return col().wFull().child(t)
        }
        _ = rt.frame(at: 0.0)
        return rt
    }

    private func clampedNode<S>(_ rt: Runtime<S>) -> Runtime<S>.FlatNode {
        rt.flatNodes.first { $0.key == "t" }!
    }

    private func drawnDetails<S>(_ rt: Runtime<S>) -> (text: String, elided: TextElision?, lineCount: Int, height: Float, lastWidth: Float) {
        let n = clampedNode(rt)
        let el = n.el
        let innerW = max(0, n.targetRect.width - el.layout.padding.left - el.layout.padding.right)
        let resolved = ElDisplayResolver.resolveText(
            el: el,
            rawText: el.liveText?.get() ?? el.plainText,
            isSecure: el.isSecure
        )
        let shaped = resolved.shape(
            using: rt.textSystem,
            maxWidth: innerW,
            pixelScale: rt.pixelScale,
            emitGlyphs: false
        )
        let lastIdx = max(0, (el.textStyle.maxLines > 0 ? min(el.textStyle.maxLines, shaped.lineCount) : shaped.lineCount) - 1)
        let lastW = shaped.lineAdvancePx(at: lastIdx) / max(1.0, rt.pixelScale)
        return (
            shaped.drawnText,
            n.elided ?? shaped.elided,
            shaped.lineCount,
            n.targetRect.height,
            lastW
        )
    }

    @Test("stops_after_n_lines_with_an_ellipsis_and_measures_n_lines")
    func stopsAfterNLinesWithEllipsis() {
        let rt = makeClamp(Self.title, lines: 3, width: 200.0)
        let d = drawnDetails(rt)
        guard let e = d.elided else {
            Issue.record("expected title to elide past three lines at 200 pt")
            return
        }
        #expect(d.text.hasSuffix("…") && !String(d.text.dropLast()).hasSuffix(" "), "\(d.text)")
        #expect(e.tail == Self.title.utf8.count)
        #expect(d.lineCount == 3 && d.height == 48.0)
        let elInfo = rt.elements().first { $0.key == "t" }
        #expect(elInfo?.text == Self.title)

        rt.setViewport(Vec2(320.0, 400.0), pixelScale: 2.0)
        _ = rt.frame(at: 0.1)
        let wider = drawnDetails(rt)
        #expect(wider.text.utf8.count > d.text.utf8.count && wider.lineCount == 3 && wider.height == 48.0, "\(wider.text)")

        rt.setViewport(Vec2(2000.0, 400.0), pixelScale: 2.0)
        _ = rt.frame(at: 0.2)
        let all = drawnDetails(rt)
        #expect(all.text == Self.title && all.elided == nil && all.lineCount == 1 && all.height == 16.0)

        rt.setViewport(Vec2(200.0, 400.0), pixelScale: 2.0)
        _ = rt.frame(at: 0.3)
        #expect(drawnDetails(rt).text == d.text)
    }

    @Test("text_within_the_limit_is_untouched")
    func textWithinLimitIsUntouched() {
        let rt4 = makeClamp("one two", lines: 2, width: 400.0)
        let d4 = drawnDetails(rt4)
        #expect(d4.text == "one two")
        #expect(d4.elided == nil)
        #expect(d4.lineCount == 1)
        #expect(d4.height == 16.0)

        let rt0 = makeClamp(Self.title, lines: 0, width: 200.0)
        let d0 = drawnDetails(rt0)
        #expect(d0.text == Self.title)
        #expect(d0.elided == nil)
        #expect(d0.lineCount > 3)
        #expect(d0.height == 16.0 * Float(d0.lineCount))
    }

    @Test("a_line_break_before_the_cut_is_dropped")
    func lineBreakBeforeCutIsDropped() {
        let rt = makeClamp("first\nsecond\nthird", lines: 2, width: 400.0)
        let d = drawnDetails(rt)
        #expect(d.text == "first\nsecond…")
        #expect(d.height == 32.0)
    }

    @Test("cuts_fall_between_graphemes")
    func cutsFallBetweenGraphemes() {
        let mixed = "👩‍👩‍👧‍👦 cafe\u{301} שלום עולם 🇯🇵 नमस्ते e\u{301}e\u{301}e\u{301} 👩‍👩‍👧‍👦 done and some more words to wrap 👩‍👩‍👧‍👦"
        let bounds = Set(TextElision.graphemeByteBounds(in: mixed, baseOffset: 0))
        let rt = makeClamp(mixed, lines: 2, width: 60.0)
        var cuts = 0
        for w in stride(from: 60, to: 400, by: 7) {
            rt.setViewport(Vec2(Float(w), 400.0), pixelScale: 2.0)
            _ = rt.frame(at: 1.0)
            let d = drawnDetails(rt)
            guard let e = d.elided else { continue }
            cuts += 1
            #expect(d.lineCount <= 2, "\(w): \(d.text)")
            #expect(bounds.contains(e.head), "\(w): \(e) splits a grapheme: \(d.text)")
        }
        #expect(cuts > 10, "most widths cut: \(cuts)")
    }

    @Test("copying_a_clamped_text_copies_all_of_it")
    func copyingClampedTextCopiesAll() {
        let rt = makeClamp(Self.title, lines: 2, width: 200.0)
        let r = clampedNode(rt).targetRect
        let p = Vec2(r.x + 20.0, r.y + 8.0)
        rt.pointerMove(to: p, at: 0.5)
        rt.pointerDown(at: p, at: 0.5)
        rt.pointerUp(at: p, at: 0.5)
        _ = rt.frame(at: 1.0)
        _ = rt.keyDown(KeyEvent(key: .command("a"), mods: RuneTestKey.primaryMods()), at: 1.05)
        _ = rt.frame(at: 1.1)
        #expect(rt.selectedText() == Self.title)
    }

    @Test("spans_and_links_past_the_cut_are_hidden")
    func spansAndLinksPastCutAreHidden() {
        let rangeUTF8: Range<Int> = {
            let r = Self.title.range(of: "overflow")!
            let lo = Self.title[..<r.lowerBound].utf8.count
            let hi = lo + "overflow".utf8.count
            return lo..<hi
        }()

        func colouredGlyphCount<S>(_ rt: Runtime<S>) -> Int {
            let want = Self.markColor.simd4(srgb: rt.srgbBlend)
            let glyphKind = Float(PrimitiveKind.glyph.rawValue)
            let frame = rt.frame(at: 0.0)
            return frame.primitives.filter { prim in
                guard prim.params.y == glyphKind else { return false }
                let color = prim.fill
                return abs(color.x - want.x) < 1e-3 &&
                    abs(color.y - want.y) < 1e-3 &&
                    abs(color.z - want.z) < 1e-3 &&
                    abs(color.w - want.w) < 1e-3
            }.count
        }

        let rtClamped = makeClamp(Self.title, lines: 2, mark: rangeUTF8, width: 200.0)
        let dClamped = drawnDetails(rtClamped)
        #expect(dClamped.elided != nil && dClamped.elided!.head < rangeUTF8.lowerBound)
        #expect(!rtClamped.elements().contains { $0.path.hasSuffix("#link-0") }, "a link past the cut isn't pressable")
        #expect(colouredGlyphCount(rtClamped) == 0)

        let rtFull = makeClamp(Self.title, lines: 0, mark: rangeUTF8, width: 200.0)
        #expect(rtFull.elements().contains { $0.path.hasSuffix("#link-0") })
        #expect(colouredGlyphCount(rtFull) > 0, "shown, the span draws its colour")
    }

    @Test("a_word_wider_than_the_box_is_cut_to_fit")
    func wordWiderThanBoxIsCutToFit() {
        let rt0 = makeClamp(Self.token, lines: 0, width: 200.0)
        #expect(drawnDetails(rt0).lineCount == 1, "the word shapes as one overflowing line")

        let rt1 = makeClamp(Self.token, lines: 1, width: 200.0)
        let d1 = drawnDetails(rt1)
        #expect(d1.elided != nil && d1.text.hasSuffix("…") && d1.text.count > 10, "\(d1.text)")
        #expect(d1.lineCount == 1)
        #expect(d1.height == 16.0)
        let elemW = clampedNode(rt1).targetRect.width
        #expect(d1.lastWidth <= 200.25 && d1.lastWidth > 150.0 && elemW <= 200.0, "\(d1.lastWidth) \(elemW): \(d1.text)")
    }

    @Test("a_wrapped_word_fills_the_last_line")
    func wrappedWordFillsLastLine() {
        let content = "See \(Self.token)"
        let rt1 = makeClamp(content, lines: 1, width: 200.0)
        let d1 = drawnDetails(rt1)
        #expect(d1.text.hasPrefix("See line_") && d1.text.hasSuffix("…") && d1.lineCount == 1, "\(d1.text)")
        let elemW1 = clampedNode(rt1).targetRect.width
        #expect(d1.lastWidth <= 200.25 && d1.lastWidth > 150.0 && elemW1 <= 200.0, "\(d1.lastWidth) \(elemW1): \(d1.text)")

        let rt2 = makeClamp(content, lines: 2, width: 200.0)
        let d2 = drawnDetails(rt2)
        #expect(d2.text.hasPrefix("See\nline_") || d2.text.hasPrefix("See line_"), "\(d2.text)")
        #expect(d2.lineCount <= 2 && d2.lastWidth <= 200.25, "\(d2.text)")

        let rtAnywhere = Runtime<Void>(
            state: (),
            viewport: Vec2(200.0, 400.0),
            pixelScale: 2.0
        ) { _, _ in
            var t: El<Void> = text(Self.token).key("t").font(Self.style).wrapText().maxLines(2)
            t.textStyle.wrapAnywhere = true
            return col().wFull().child(t)
        }
        _ = rtAnywhere.frame(at: 0.0)
        let n = clampedNode(rtAnywhere)
        let dAny = drawnDetails(rtAnywhere)
        #expect(n.elided != nil, "the token wraps past two lines at 200 pt")
        #expect(dAny.lineCount == 2, "wraps onto two lines before cutting")
        #expect(
            (n.elided?.head ?? 0) > 40 && dAny.lastWidth <= 200.25,
            "both lines fill the 200 pt box: head=\(n.elided?.head ?? 0), width=\(dAny.lastWidth)"
        )
    }

    @Test("a_text_field_ignores_the_clamp_and_truncation")
    func textFieldIgnoresClampAndTruncation() {
        let rt = Runtime<TextEdit>(
            state: TextEdit(Self.title),
            viewport: Vec2(200.0, 400.0),
            pixelScale: 2.0
        ) { _, _ in
            col().wFull()
                .child(textInput(key: "t", \TextEdit.self).wFull().maxLines(1))
                .child(textInput(key: "u", \TextEdit.self).wFull().truncateMiddle())
        }
        _ = rt.frame(at: 0.0)
        for key in ["t", "u"] {
            let n = rt.flatNodes.first { $0.key == key }!
            #expect(n.elided == nil && n.el.textStyle.maxLines == 0 && n.el.textStyle.wrap != TextWrap.ellipsis, "\(key)")
            let r = n.targetRect
            let p = Vec2(r.right - 4.0, r.y + 8.0)
            rt.pointerMove(to: p, at: 1.0)
            rt.pointerDown(at: p, at: 1.0)
            rt.pointerUp(at: p, at: 1.0)
            _ = rt.frame(at: 1.0)
            _ = rt.keyDown(KeyEvent(key: .arrowRight), at: 1.1)
            _ = rt.frame(at: 1.1)
        }
    }

    @Test("clamped_elision_cache_reuses_cut_across_commits")
    func clampedElisionCacheReusesCutAcrossCommits() {
        let rt = makeClamp(Self.title, lines: 2, mark: 9..<25, width: 180.0)
        let d0 = drawnDetails(rt)
        #expect(d0.lineCount == 2)
        #expect(d0.elided != nil)
        #expect(rt.textSystem.cachedElisionCount == 1)
        let shapedBefore = rt.textSystem.shapeMissCount
        rt.invalidate(at: 1.0 / 60.0)
        _ = rt.frame(at: 1.0 / 60.0)
        #expect(rt.textSystem.shapeMissCount == shapedBefore, "repeat commit reuses cached clamped cut")
        #expect(drawnDetails(rt).elided == d0.elided)
    }
}
