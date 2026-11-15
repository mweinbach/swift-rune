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
