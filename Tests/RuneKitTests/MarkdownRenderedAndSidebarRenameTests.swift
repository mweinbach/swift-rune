import Foundation
import Testing
@testable import Rune
@testable import RuneKit

/// up-kit-1: upstream `d77610b5` (#941), `da9e1608` (#953), `310019d0` (#960, test removed by
/// `a3354747` #978) and `ee8340a4` (r436).
@Suite("RuneKit markdown & sidebar upstream delta (up-kit-1)", .serialized)
struct MarkdownRenderedAndSidebarRenameTests {

    // MARK: - #960 markdown::Rendered

    /// The documents, queries and cases of #960's `rendered_finds_what_find_finds` (removed
    /// upstream by #978 under the no-new-tests rule; kept here as an equality check, not weakened).
    private static let docs = [
        "Start *italic* and **bold** and `code` and ~~struck~~ and [linked words](https://example.org/path) end.",
        "# Title\n\n- one **two**\n- three\n\n> quoted `x`\n\n| a | b |\n|---|---|\n| cell | Straße |\n\n```rust\nlet x = 1;\n```",
        "AT&amp;T &lt;tag&gt; and İstanbul",
    ]
    private static let queries = ["t", "two", "x", "strasse", "&", "istanbul", "cell"]

    @Test("#960: MarkdownRendered.find returns exactly what MarkdownFind.find returns")
    func renderedFindsWhatFindFinds() throws {
        for src in Self.docs {
            let rendered = MarkdownRendered(src)
            for q in Self.queries {
                for c in [MarkdownCase.insensitive, .sensitive] {
                    #expect(rendered.find(src, q, c) == MarkdownFind.find(src, q, c), "\(q) in \(src)")
                    #expect(MarkdownFind.find(src, q, c) == Markdown(src).findRanges(q, caseSensitivity: c))
                }
            }
            let first = try #require(rendered.texts().first, "a block")
            #expect(!rendered.sourceRanges(src, block: 0, range: 0..<first.utf8.count).isEmpty)
        }
    }

    @Test("#960: MarkdownRendered lists each block's visible text and maps ranges back to the source")
    func renderedTextsAndSourceRanges() throws {
        let src = Self.docs[1]
        let rendered = MarkdownRendered(src)
        // The block walk: heading, list item paragraphs, quote, table head and body cells, code.
        #expect(rendered.texts() == ["Title", "one two", "three", "quoted x", "a", "b", "cell", "Straße", "let x = 1;"])

        // "two" in "one two" (block 1) is `**two**` in the source.
        let ranges = rendered.sourceRanges(src, block: 1, range: 4..<7)
        #expect(ranges.count == 1)
        let r = try #require(ranges.first)
        let bytes = Array(src.utf8)
        #expect(String(decoding: bytes[r], as: UTF8.self) == "two")
        #expect(rendered.find(src, "two", .sensitive) == [ranges])

        // Empty, reversed-out-of-bounds or unknown-block ranges name nothing.
        #expect(rendered.sourceRanges(src, block: 1, range: 3..<3).isEmpty)
        #expect(rendered.sourceRanges(src, block: 1, range: 0..<100).isEmpty)
        #expect(rendered.sourceRanges(src, block: 99, range: 0..<1).isEmpty)
        #expect(rendered.sourceRanges(src, block: -1, range: 0..<1).isEmpty)

        // Empty source or query finds nothing, as `find` does.
        #expect(rendered.find(src, "", .insensitive).isEmpty)
        #expect(MarkdownRendered("").find("", "a", .insensitive).isEmpty)
        #expect(MarkdownRendered("").texts().isEmpty)
        #expect(MarkdownRendered().texts().isEmpty)
    }

    @Test("#960: MarkdownRendered is Sendable and owns its text across threads")
    func renderedIsSendable() async {
        let src = Self.docs[0]
        let rendered = MarkdownRendered(src)
        let hits = await Task.detached { rendered.find(src, "bold", .insensitive) }.value
        #expect(hits == MarkdownFind.find(src, "bold", .insensitive))
        #expect(hits.count == 1)
    }

    // MARK: - #953 table code-cell end padding

    private static func firstBodyCell(_ src: String) throws -> MarkdownInline {
        let doc = MarkdownDocCache.shared.docCached(src, autolink: true)
        for b in doc.blocks {
            if case let .table(t) = b { return try #require(t.rows.first?.first) }
        }
        Issue.record("no table in \(src)")
        throw CancellationError()
    }

    private static func findEl<S>(_ root: El<S>, key: String) -> El<S>? {
        if root.keyId == key { return root }
        for c in root.children {
            if let hit = findEl(c, key: key) { return hit }
        }
        return nil
    }

    /// The first body cell's (natural, min) widths as the table sets them.
    @MainActor
    private static func bodyCellWidths(_ src: String, pad: Float) throws -> (natural: Float, min: Float) {
        var style = MarkdownStyle.fromKit(Kit.neutral(dark: true)).inlineCodePad(pad)
        style.tableMinColumn = 10_000
        let root: El<Int> = Markdown(src).render(style)
        let row = try #require(findEl(root, key: "r0"))
        let cell = try #require(findEl(row, key: "c0"))
        guard case let .points(natural) = cell.layout.width, case let .points(minW) = cell.layout.minWidth else {
            Issue.record("the cell sets point widths")
            throw CancellationError()
        }
        return (natural, minW)
    }

    @Test("#953: a cell ending in inline code counts the chip's end padding in both widths")
    func tableCodeCellEndPadHits() throws {
        func pads(_ inl: MarkdownInline) -> [Bool] {
            let h = MarkdownTableCodePad.hits(inl)
            return [h.last, h.word]
        }
        // Code that ends the cell: its end pad went with the line's trailing space.
        let ends = try Self.firstBodyCell("| h |\n|---|\n| `code` |")
        #expect(ends.spans.contains { $0.style == .code && $0.end >= ends.text.utf8.count })
        #expect(pads(ends) == [true, true])

        // Code that ends a word mid-cell: only its min-content (fit) width counts the pad.
        let word = try Self.firstBodyCell("| h |\n|---|\n| `a` b |")
        #expect(pads(word) == [false, true])

        // Code glued to the following word: neither width adds a pad.
        let glued = try Self.firstBodyCell("| h |\n|---|\n| `a`b |")
        #expect(pads(glued) == [false, false])

        // No code at all.
        let plain = try Self.firstBodyCell("| h |\n|---|\n| plain words |")
        #expect(pads(plain) == [false, false])
    }

    @Test("#953: the table's column widths add inlineCodePad where the pad hits")
    @MainActor
    func tableCodeCellColumnWidths() throws {
        let pad: Float = 8
        let endsSrc = "| h |\n|---|\n| `code` |"
        let e0 = try Self.bodyCellWidths(endsSrc, pad: 0)
        let e8 = try Self.bodyCellWidths(endsSrc, pad: pad)
        #expect(abs((e8.natural - e0.natural) - pad) < 0.001, "natural counts the chip's end padding")
        #expect(abs((e8.min - e0.min) - pad) < 0.001, "fit counts the chip's end padding")

        let wordSrc = "| h |\n|---|\n| `a` b |"
        let w0 = try Self.bodyCellWidths(wordSrc, pad: 0)
        let w8 = try Self.bodyCellWidths(wordSrc, pad: pad)
        #expect(abs(w8.natural - w0.natural) < 0.001, "code mid-line: its end pad is inside the line's width")
        #expect(abs((w8.min - w0.min) - pad) < 0.001, "code ending a word: a break there drops its end pad, fit counts it")

        let plainSrc = "| h |\n|---|\n| plain words |"
        let p0 = try Self.bodyCellWidths(plainSrc, pad: 0)
        let p8 = try Self.bodyCellWidths(plainSrc, pad: pad)
        #expect(p0.natural == p8.natural && p0.min == p8.min)

        // #1290: Inline code inside a link has no code-pill padding in table column widths.
        let linkedEnds = try Self.firstBodyCell("| h |\n|---|\n| [`code`](https://example.com) |")
        let linkedEndsHits = MarkdownTableCodePad.hits(linkedEnds)
        #expect(!linkedEndsHits.last && !linkedEndsHits.word)
        let le0 = try Self.bodyCellWidths("| h |\n|---|\n| [`code`](https://example.com) |", pad: 0)
        let le8 = try Self.bodyCellWidths("| h |\n|---|\n| [`code`](https://example.com) |", pad: pad)
        #expect(abs(le8.natural - le0.natural) < 0.001)
        #expect(abs(le8.min - le0.min) < 0.001)

        let linkedWord = try Self.firstBodyCell("| h |\n|---|\n| [`a`](https://example.com) b |")
        let linkedWordHits = MarkdownTableCodePad.hits(linkedWord)
        #expect(!linkedWordHits.last && !linkedWordHits.word)
        let lw0 = try Self.bodyCellWidths("| h |\n|---|\n| [`a`](https://example.com) b |", pad: 0)
        let lw8 = try Self.bodyCellWidths("| h |\n|---|\n| [`a`](https://example.com) b |", pad: pad)
        #expect(abs(lw8.natural - lw0.natural) < 0.001)
        #expect(abs(lw8.min - lw0.min) < 0.001)
    }

    @Test("#1290: inline code inside links keeps monospace + bidi isolate and inherits link styling without pill bg/padding")
    @MainActor
    func markdownInlineCodeInsideLinksInheritsLinkStyling() throws {
        // Parser uses linkOpenPad/linkClosePad inside links and openPad/closePad outside links.
        let doc = MarkdownParser.parseDocument("See [`code`](https://example.com) and `chip`.", autolink: true)
        guard case let .para(inl) = doc.blocks.first else {
            Issue.record("expected paragraph")
            return
        }
        #expect(inl.text == "See \u{2066}code\u{2069} and \u{202f}\u{202f}\u{2066}chip\u{2069}\u{202f}\u{202f}.")
        #expect(inl.unpaddedText == "See code and chip.")
        #expect(MarkdownInline.unpadded("\u{2066}a\u{2069} \u{202f}\u{202f}\u{2066}b\u{2069}\u{202f}\u{202f}") == "a b")

        // Standalone image alt (not inside a link) keeps pill pads; linked image alt is inside a link.
        let imgDoc = MarkdownParser.parseDocument("**![`alt`](https://example.com/a.png)** and [![`inlink`](https://example.com/b.png)](https://example.com).", autolink: true)
        guard case let .para(imgInl) = imgDoc.blocks.first else {
            Issue.record("expected paragraph")
            return
        }
        #expect(imgInl.text.contains("\u{202f}\u{202f}\u{2066}alt\u{2069}\u{202f}\u{202f}"))
        #expect(imgInl.text.contains("\u{2066}inlink\u{2069}"))
        #expect(!imgInl.text.contains("\u{202f}\u{202f}\u{2066}inlink"))

        // Rendered spans: code inside link inherits link color and underline with no code-pill background.
        let style = MarkdownStyle.fromKit(Kit.neutral(dark: true))
        func richSpans(of root: El<Int>) -> [TextSpan] {
            var out: [TextSpan] = []
            func walk(_ e: El<Int>) {
                if let sp = e.richSpans { out.append(contentsOf: sp) }
                for c in e.children { walk(c) }
            }
            walk(root)
            return out
        }

        let defaultRoot: El<Int> = Markdown("See [`code`](https://example.com) and `chip`.").render(style)
        let spans = richSpans(of: defaultRoot)
        let linkedCode = try #require(spans.first { $0.text == "code" })
        let standaloneCode = try #require(spans.first { $0.text == "chip" })
        let linkedOpenPad = try #require(spans.first { $0.text == MarkdownInline.linkOpenPad })
        let linkedClosePad = try #require(spans.first { $0.text == MarkdownInline.linkClosePad })
        let chipOpenPad = try #require(spans.first { $0.text == MarkdownInline.openPad })

        #expect(linkedCode.monospace)
        #expect(linkedCode.weight == style.inlineCodeWeight)
        #expect(linkedCode.color == style.accent)
        #expect(linkedCode.underline)
        #expect(linkedCode.background == nil)
        #expect(linkedOpenPad.color == style.accent && linkedOpenPad.underline && linkedOpenPad.background == nil)
        #expect(linkedClosePad.color == style.accent && linkedClosePad.underline && linkedClosePad.background == nil)

        #expect(standaloneCode.monospace)
        #expect(standaloneCode.weight == style.inlineCodeWeight)
        #expect(standaloneCode.color == style.text)
        #expect(!standaloneCode.underline)
        #expect(standaloneCode.background == style.codeBg)
        #expect(chipOpenPad.background == style.codeBg)

        // Custom linkPaint (custom color, bg, underline: false) is inherited by inline code inside the link.
        let customBg = Color(r: 1.0, g: 0.0, b: 0.5, a: 1.0)
        let customRoot: El<Int> = Markdown("[**bold** *em* `code` plain](session:1)")
            .linkStyle { url -> MarkdownLinkStyle? in
                url.hasPrefix("session:")
                    ? MarkdownLinkStyle(color: .white, underline: false, weight: 500, bg: customBg)
                    : nil
            }
            .render(style)
        let customSpans = richSpans(of: customRoot)
        let customCode = try #require(customSpans.first { $0.text == "code" })
        let customBold = try #require(customSpans.first { $0.text == "bold" })
        let customPlain = try #require(customSpans.first { $0.text.contains("plain") })
        #expect(customCode.monospace)
        #expect(customCode.color == .white)
        #expect(!customCode.underline)
        #expect(customCode.background == customBg)
        #expect(customCode.weight == style.inlineCodeWeight)
        #expect(customBold.weight == style.strongWeight)
        #expect(customPlain.weight == 500)

        // Markdown link containing code takes link styling even when codeLink also matches the text.
        let clColor = Color(r: 0.1, g: 0.8, b: 0.4, a: 1.0)
        let mixedRoot: El<Int> = Markdown("[`app.swift`](https://example.com) vs `app.swift`")
            .codeLink(match: { code in code.hasSuffix(".swift") ? "file://\(code)" : nil }, color: clColor)
            .render(style)
        let mixedSpans = richSpans(of: mixedRoot).filter { $0.text == "app.swift" }
        #expect(mixedSpans.count == 2)
        #expect(mixedSpans[0].color == style.accent && mixedSpans[0].underline && mixedSpans[0].background == nil)
        #expect(mixedSpans[1].color == clColor && !mixedSpans[1].underline && mixedSpans[1].background == nil)

        // Lightweight inlineSpans helper skips code-pill bg inside links.
        let helperSpans = MarkdownParser.inlineSpans("[`code`](https://example.com) `chip`", kit: Kit.neutral(dark: true))
        let helperLinked = try #require(helperSpans.first { $0.text == "code" })
        let helperStandalone = try #require(helperSpans.first { $0.text == "chip" })
        #expect(helperLinked.monospace && helperLinked.underline && helperLinked.background == nil)
        #expect(helperStandalone.monospace && !helperStandalone.underline && helperStandalone.background != nil)
    }

    @Test("#1290: streaming dropClosingPad strips trailing linkClosePad as well as closePad")
    func markdownStreamingDropClosingPadHandlesLinkClose() throws {
        // Direct dropClosingPad on a paragraph ending with linkClosePad (U+2069).
        let text = "\u{2066}code\u{2069}"
        let openLen = MarkdownInline.linkOpenPad.utf8.count
        let codeEnd = openLen + 4
        let closeEnd = codeEnd + MarkdownInline.linkClosePad.utf8.count
        let inl = MarkdownInline(
            text: text,
            spans: [
                MarkdownStyleSpan(start: 0, end: openLen, style: .codePad),
                MarkdownStyleSpan(start: openLen, end: codeEnd, style: .code),
                MarkdownStyleSpan(start: codeEnd, end: closeEnd, style: .codePad),
                MarkdownStyleSpan(start: 0, end: closeEnd, style: .link),
            ],
            links: [MarkdownLinkSpan(start: 0, end: closeEnd, url: "https://example.com")]
        )
        let map = MarkdownSpanMap([MarkdownSpanMap.Segment(src: 2..<6, out: openLen..<codeEnd)])
        var doc = MarkdownParsedDoc(blocks: [.para(inl)], maps: [.inline(map)])
        MarkdownTailStream.dropClosingPad(in: &doc)
        guard case let .para(stripped) = doc.blocks.first else {
            Issue.record("expected paragraph")
            return
        }
        #expect(stripped.text == "\u{2066}code")
        #expect(!stripped.text.contains("\u{2069}"))
        #expect(stripped.spans.map(\.style) == [.codePad, .code, .link])
        #expect(stripped.links == [MarkdownLinkSpan(start: 0, end: codeEnd, url: "https://example.com")])

        // End-to-end streaming of an unclosed inline code span inside a link grows without trailing U+2069 or pill spaces.
        let s1 = MarkdownTailStream.parseStreaming("[`foo", autolink: true)
        let s2 = MarkdownTailStream.parseStreaming("[`foobar", autolink: true)
        guard case let .para(p1) = s1.blocks.first, case let .para(p2) = s2.blocks.first else {
            Issue.record("expected streaming paragraphs")
            return
        }
        #expect(p1.text == "\u{2066}foo")
        #expect(p2.text == "\u{2066}foobar")
        #expect(!p1.text.contains("\u{202f}") && !p1.text.contains("\u{2069}"))
        #expect(p2.text.hasPrefix(p1.text))
    }

    // MARK: - r436 sidebar rename field label

    @Test("r436: a_renaming_row_names_its_field_after_the_row")
    @MainActor
    func aRenamingRowNamesItsFieldAfterTheRow() throws {
        struct S {
            var sidebar = PaneState(width: 240).range(180, 420)
            var picked = 1
            var twoLines = false
            var renaming: Int? = nil
            var edit = TextEdit()
        }
        let names = ["Alpha", "Bravo", "Charlie", "Delta"]
        for twoLines in [false, true] {
            let kit = Kit.neutral(dark: true)
            let rt = Runtime(state: S(twoLines: twoLines), viewport: Vec2(1000, 600), systemDark: true) { s, _ in
                let rows: [El<S>] = names.enumerated().map { i, name in
                    var r = SidebarRow<S>(key: "row\(i)", title: name)
                        .selected(s.picked == i)
                        .onClick { st, _ in st.picked = i }
                    if s.twoLines {
                        r = r.subtitle("user\(i)@example.com")
                    }
                    if s.renaming == i {
                        r = r.renaming(
                            \S.edit,
                            inputKey: "rename",
                            onCommit: { st, _, _ in st.renaming = nil },
                            onCancel: { st, _ in st.renaming = nil }
                        )
                    }
                    return r.build(kit)
                }
                let sb = Sidebar<S>(key: "sb")
                    .section(SidebarSection<S>(key: "today", title: "Today").children(rows).build(kit))
                    .build(kit)
                return SplitView<S>(key: "sv") { _ in Page<S>().build(kit) }
                    .sidebar(\.sidebar, current: s.sidebar) { _ in sb }
                    .paneMotion(.instant)
                    .build(s, kit: kit)
            }
            rt.frame(at: 0)
            rt.update { s, _ in
                s.renaming = 1
                s.edit = TextEdit("Bravo")
            }
            rt.frame(at: 1.0 / 60.0)
            let field = try #require(rt.elements().first { $0.key == "rename" })
            #expect(field.focusable && !field.inert, "the rename field is the focusable field a nameless warning is about")
            #expect(field.label == "Bravo", "the rename field is named after the row it edits")
            func a11yNode(_ n: AccessibilityNode, _ id: String) -> AccessibilityNode? {
                if n.id == id { return n }
                for c in n.children {
                    if let hit = a11yNode(c, id) { return hit }
                }
                return nil
            }
            let node = try #require(a11yNode(rt.accessibilitySnapshot(), "rename"), "the rename field is in the accessibility tree")
            #expect(node.label == "Bravo", "a reader says the row's label for its rename field")
        }
    }
}
