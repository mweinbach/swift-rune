import Foundation
import Testing
@testable import RuneKit
@testable import Rune

@Suite("RuneKit Markdown Full Parity Tests (Increment 4)")
struct MarkdownFullParityTests {
    // MARK: - Helpers

    private static let juiceDoc = """
        **More useful**
        1. **Run it live.** Real numbers.
        2. **Hands-on.** Press `e`.

        **More juice**
        4. **Hash ripple.** A changed hash scrambles.
        5. **Panels that carry over.** The panel stays put.
        8. **Motion with weight.** Panels spring in.

        **My pick:** 1, 2 and 4.
        """

    private func utf8Slice(_ str: String, _ range: Range<Int>) -> String {
        let bytes = Array(str.utf8)
        let lo = max(0, min(bytes.count, range.lowerBound))
        let hi = max(lo, min(bytes.count, range.upperBound))
        return String(decoding: bytes[lo..<hi], as: UTF8.self)
    }

    private func approxColor(_ a: Color?, _ b: Color, eps: Float = 0.002) -> Bool {
        guard let a else { return false }
        return abs(a.r - b.r) < eps && abs(a.g - b.g) < eps && abs(a.b - b.b) < eps && abs(a.a - b.a) < eps
    }

    private func sliceMatches(_ src: String, _ matches: [[Range<Int>]]) -> [[String]] {
        matches.map { match in match.map { utf8Slice(src, $0) } }
    }

    private func charPrefixEnds(_ s: String) -> [String.Index] {
        var out: [String.Index] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            idx = s.index(after: idx)
            out.append(idx)
        }
        return out
    }

    private func shownText(_ blocks: [MarkdownDocBlock]) -> String {
        func walk(_ blocks: [MarkdownDocBlock], _ out: inout [String]) {
            for b in blocks {
                switch b {
                case let .para(i), let .heading(_, i):
                    out.append(i.text)
                case let .list(_, items):
                    for item in items { walk(item, &out) }
                case let .quote(inner):
                    walk(inner, &out)
                case let .table(t):
                    out.append(contentsOf: t.head.map(\.text))
                    for row in t.rows {
                        let lastNonEmpty = row.lastIndex(where: { !$0.text.isEmpty }).map { $0 + 1 } ?? 0
                        out.append(contentsOf: row[..<lastNonEmpty].map(\.text))
                    }
                case let .code(c), let .diff(c), let .mermaid(c):
                    out.append(c)
                case let .image(_, alt, _):
                    out.append(alt)
                case .rule:
                    break
                }
            }
        }
        var out: [String] = []
        walk(blocks, &out)
        return out.joined(separator: "\n")
    }

    private func styledSlices(_ blocks: [MarkdownDocBlock], _ style: MarkdownInlineStyle) -> [String] {
        guard let first = blocks.first else { return [] }
        let inl: MarkdownInline?
        switch first {
        case let .para(i), let .heading(_, i): inl = i
        default: inl = nil
        }
        guard let inl else { return [] }
        return inl.spans.filter { $0.style == style }.map { utf8Slice(inl.text, $0.start..<$0.end) }
    }

    private func collectRichNodes<S>(_ root: El<S>) -> [(key: String?, plain: String, spans: [TextSpan])] {
        var out: [(key: String?, plain: String, spans: [TextSpan])] = []
        func walk(_ el: El<S>) {
            if let spans = el.richSpans, !spans.isEmpty {
                out.append((el.keyId, el.plainText ?? spans.map(\.text).joined(), spans))
            }
            for child in el.children {
                walk(child)
            }
        }
        walk(root)
        return out
    }

    private func spanRanges(for spans: [TextSpan], matching predicate: (TextSpan) -> Bool) -> [(Range<Int>, TextSpan)] {
        var out: [(Range<Int>, TextSpan)] = []
        var offset = 0
        for sp in spans {
            let len = sp.text.utf8.count
            if predicate(sp) {
                out.append((offset..<(offset + len), sp))
            }
            offset += len
        }
        return out
    }

    private func elementParent<S>(_ rt: Runtime<S>, of el: ElementInfo) -> ElementInfo? {
        guard let pid = el.parentIndex else { return nil }
        let els = rt.elements()
        return els.indices.contains(pid) ? els[pid] : nil
    }

    private func tableCell<S>(_ rt: Runtime<S>, rowKey: String, col: Int) -> ElementInfo? {
        guard let rowEl = rt.element(byKey: rowKey) else { return nil }
        let prefix = rowEl.path + "/"
        return rt.elements().first(where: { $0.key == "c\(col)" && $0.path.hasPrefix(prefix) })
    }

    private func textInSubtree<S>(_ rt: Runtime<S>, under ancestor: ElementInfo, matching text: String) -> ElementInfo? {
        let prefix = ancestor.path + "/"
        return rt.elements().first(where: { $0.path.hasPrefix(prefix) && $0.text == text })
    }

    // MARK: - Block Interrupts & Numbered Lists (interrupt_tests.rs)

    @Test("Numbered lines after bold heading lines start ordered lists and map back to source")
    func numberedLinesAfterHeadingAreListAndMapSource() {
        let blocks = MarkdownParser.parseAST(Self.juiceDoc)
        let summaries: [String] = blocks.map { b in
            switch b {
            case let .para(i): return i.text
            case let .list(_, items): return "\(items.count)"
            default: return ""
            }
        }
        #expect(summaries == ["More useful", "2", "More juice", "3", "My pick: 1, 2 and 4."])

        if case let .list(start, items) = blocks[3] {
            #expect(start == 4)
            if case let .para(first) = items[0][0], case let .para(third) = items[2][0] {
                #expect(first.text == "Hash ripple. A changed hash scrambles.")
                #expect(third.text == "Motion with weight. Panels spring in.")
                let bold = first.spans.first(where: { $0.style == .strong })
                #expect(bold != nil)
                if let bold {
                    #expect(utf8Slice(first.text, bold.start..<bold.end) == "Hash ripple.")
                }
            } else {
                Issue.record("Expected para items in list[3]")
            }
        } else {
            Issue.record("Expected list at index 3")
        }

        let doc = MarkdownParser.parseDocument(Self.juiceDoc)
        if case let .list(itemMaps) = doc.maps[3], case let .inline(spanMap) = itemMaps[0][0], let firstSeg = spanMap.segments.first {
            #expect(firstSeg.out.lowerBound == 0)
            #expect(utf8Slice(Self.juiceDoc, firstSeg.src) == "Hash ripple.")
        } else {
            Issue.record("Expected list/inline spanMap on block 3")
        }

        // Numbers that aren't list markers stay text, quoted lists continue too.
        for src in ["Escaped\n4\\. not a list", "**Bold across\n4. lines**", "Bare\n4.", "Decimal\n4.5 points"] {
            let parsed = MarkdownParser.parseAST(src)
            #expect(parsed.count == 1)
            if case .para = parsed[0] {} else {
                Issue.record("Expected single para for \(src)")
            }
        }

        let quoted = MarkdownParser.parseAST("> Next\n> 3. three\n> 4. four")
        if case let .quote(inner) = quoted[0] {
            let innerSummaries = inner.map { b -> String in
                if case let .para(i) = b { return i.text }
                if case let .list(_, items) = b { return "\(items.count)" }
                return ""
            }
            #expect(innerSummaries == ["Next", "2"])
        } else {
            Issue.record("Expected quote block")
        }
    }

    // MARK: - Streaming Tail & DocCache (stream_tests.rs, markdown/tests.rs)

    @Test("MarkdownTailStream never flashes markers, stabilizes open spans/tables/links, and matches whole parse")
    func streamingTailStabilizationAndIncrementalCache() {
        // Open spans draw styled without showing partial markers
        var tail = MarkdownTailStream()
        for (src, style, expected) in [
            ("…and **Settings ›", MarkdownInlineStyle.strong, ["Settings ›"]),
            ("…and **Settings › Appearance*", MarkdownInlineStyle.strong, ["Settings › Appearance"]),
            ("an _important", MarkdownInlineStyle.em, ["important"]),
            ("was ~~old", MarkdownInlineStyle.strike, ["old"]),
            ("Run `cargo te", MarkdownInlineStyle.code, ["cargo te"]),
        ] {
            tail.reset(src)
            let doc = tail.document(streaming: true)
            #expect(styledSlices(doc.blocks, style) == expected)
        }

        // Markers at very end wait for next character; non-opening markers stay.
        for (src, want) in [
            ("…and **", "…and"),
            ("…and *", "…and"),
            ("use `", "use"),
            ("snake_", "snake_"),
            ("2*", "2*"),
            ("2 * 3", "2 * 3"),
            ("takes ~5 min", "takes ~5 min"),
        ] {
            tail.reset(src)
            #expect(shownText(tail.document(streaming: true).blocks) == want)
        }

        // Open link draws as styled link
        for src in ["see [the do", "see [the docs]", "see [the docs](", "see [the docs](https://ex"] {
            tail.reset(src)
            let blocks = tail.document(streaming: true).blocks
            let wantText = src.hasSuffix("do") ? "see the do" : "see the docs"
            let wantLink = src.hasSuffix("do") ? "the do" : "the docs"
            #expect(shownText(blocks) == wantText)
            #expect(styledSlices(blocks, .link) == [wantLink])
        }

        // Held incomplete table headers wait until they are tables (upstream stream_tests::a_header_line_waits_until_it_is_a_table).
        var held = MarkdownTailStream()
        for pending in ["| File", "| File |", "| File |\n", "| File |\n|", "Intro\n\n| File", "Intro\n| File | Change |"] {
            held.reset(pending)
            let blocks = held.document(streaming: true).blocks
            #expect(!shownText(blocks).contains("File"))
        }
        held.reset("| File | Change")
        if case let .table(t) = held.document(streaming: true).blocks.first {
            #expect(t.head.count == 2)
        } else {
            Issue.record("Expected two-cell header to draw immediately as a table")
        }
        held.reset("| File |\n|---|\n")
        if case .table = held.document(streaming: true).blocks.first {} else {
            Issue.record("Expected one-column table once its delimiter row ends")
        }
        for notTable in ["| File\nis a word", "| File\n| Change", "| File\n\n", "| File |\n| Change |\n"] {
            held.reset(notTable)
            if case .para = held.document(streaming: true).blocks.first {} else {
                Issue.record("Expected paragraph once pipe line proves not a table: \(notTable)")
            }
        }
        held.reset("```\n| File")
        if case let .code(c) = held.document(streaming: true).blocks.first {
            #expect(c == "| File")
        } else {
            Issue.record("Expected code block inside unclosed fence")
        }
        let tableStreamDoc = "| File | Change |\n|---|---|\n| a.rs | x |"
        for endIdx in tableStreamDoc.indices {
            let prefix = String(tableStreamDoc[...endIdx])
            held.reset(prefix)
            let blocks = held.document(streaming: true).blocks
            #expect(blocks.allSatisfy { if case .table = $0 { return true }; return false })
        }
        #expect(held.document(streaming: true).blocks.count == 1)

        let multiDoc = """
        # Title

        First para with **bold** and `code`.
        Setext
        ---

        - one
        - two

        - [ ] todo
        - [x] done

        > quoted
        > lines

        ```rust
        fn main() {}
        ```

        | a | b |
        |:-|-:|
        | 1 | 2 |

        last *words*
        """
        let cache = MarkdownDocCache(capacity: 24)
        for docText in [Self.juiceDoc, multiDoc] {
            for endIdx in charPrefixEnds(docText) {
                let prefix = String(docText[..<endIdx])
                let cached = cache.docCached(prefix)
                let direct = MarkdownParser.parseDocument(prefix)
                #expect(cached.blocks == direct.blocks)
                #expect(cached.sources == direct.sources)
                #expect(cached.tasks == direct.tasks)
                #expect(cached.blockStarts == direct.blockStarts)
                #expect(cached.maps == direct.maps)
            }
        }

        // #20 (`stream_tests.rs:46-68`): 9-doc byte/char-prefix-by-prefix monotonic visibility
        let streamDocs = [
            "…and **Settings › Appearance**…",
            "Open **Settings › Appearance** to change it.",
            "**Note:** run `cargo test` and *then* ~~not~~ this.",
            "Mix **bold _and em_** end, an __under__ and `` a`b `` here.",
            "# Heading with **bold**\n\nSee https://example.com/a_b_c and 2 * 3 = 6, snake_case_name.",
            "- item **one**\n- item `two`\n\n> quoted *em*",
            "| a | **b** |\n|---|---|\n| `c` | *d* |",
            "See [the **docs**](https://example.com/a_b \"t\") and ![a chart](x.png), then *[more](y)*.",
            "- [ ] todo\n- [x] done",
        ]
        var strm = MarkdownTailStream()
        for docText in streamDocs {
            let stripWS = docText.contains("![")
            func visible(_ blocks: [MarkdownDocBlock]) -> String {
                let s = shownText(blocks)
                return stripWS ? String(s.unicodeScalars.filter { !$0.properties.isWhitespace }) : s
            }
            let whole = visible(MarkdownParser.parseDocument(docText).blocks)
            for endIdx in charPrefixEnds(docText) {
                let prefix = String(docText[..<endIdx])
                strm.reset(prefix)
                let shown = visible(strm.document(streaming: true).blocks)
                #expect(whole.hasPrefix(shown), "Prefix \(prefix) showed \(shown) which is not a prefix of \(whole)")
            }
        }
    }

    @Test("Reference definition invalidates cache properly and doc cache capacity preserves older docs")
    func referenceDefinitionAndCacheEviction() {
        let cache = MarkdownDocCache(capacity: 24)
        let before = cache.docCached("[x]\n\nsecond block\n\nthird block")
        let after = cache.docCached("[x]\n\nsecond block\n\nthird block\n\n[x]: https://example.com")
        #expect(before.blocks != after.blocks)
        if case let .para(inl) = after.blocks[0] {
            #expect(inl.links.first?.url == "https://example.com")
        } else {
            Issue.record("Expected para with resolved reference link")
        }

        // Bare www. autolinks resolve with http:// scheme parity (`autolink.rs:83`).
        let wwwMatches = MarkdownAutolink.scan("see www.example.org.")
        #expect(wwwMatches.first?.url == "http://www.example.org")
    }

    // MARK: - Search / Find Parity (tests/markdown_find.rs)

    @Test("MarkdownFind searches across inline markers, skips link/image URLs, and honors block boundaries & code")
    func markdownFindInlineMarkersUrlsAndBlocks() {
        let src = "a **b**"
        let md = Markdown(src)
        let hits = md.findRanges("a b", caseSensitivity: .sensitive)
        #expect(hits == [[0..<2, 4..<5]])
        #expect(sliceMatches(src, hits) == [["a ", "b"]])

        let rich = "Start *italic* and **bold** and `code` and ~~struck~~ and [linked words](https://example.org/path) end."
        let richHits = Markdown(rich).findRanges("Start italic and bold and code and struck and linked words end.", caseSensitivity: .sensitive)
        #expect(sliceMatches(rich, richHits) == [[
            "Start ", "italic", " and ", "bold", " and ", "code", " and ", "struck", " and ", "linked words", " end.",
        ]])

        let urlSrc = """
        Read [the guide](https://example.org/secret-url) or [ref text][secret-ref].

        Bare https://example.org/bare-link and <https://example.org/angle-link> work.

        Look at ![diagram alt text](https://example.org/hidden-image.png).

        [secret-ref]: https://example.org/ref-target
        """
        for hidden in ["secret-url", "secret-ref", "ref-target", "hidden-image", ".png"] {
            #expect(Markdown(urlSrc).findRanges(hidden).isEmpty)
        }
        #expect(sliceMatches(urlSrc, Markdown(urlSrc).findRanges("diagram alt text", caseSensitivity: .sensitive)) == [["diagram alt text"]])

        let blocksDoc = """
        # Heading One

        First paragraph
        continues on next line.

        Second paragraph.

        - item alpha
        - [x] item beta

        | Head A | Head B |
        |---|---|
        | cell one | cell two |

        ```rust
        fn compute() -> i32 {
            42
        }
        ```

        ```diff
        -old_val
        +new_val
        ```
        """
        for across in [
            "Heading One First",
            "line. Second",
            "item alpha item beta",
            "[x] item beta",
            "Head A Head B",
            "cell one cell two",
            "rust",
            "```",
        ] {
            #expect(Markdown(blocksDoc).findRanges(across).isEmpty)
        }
        let soft = Markdown(blocksDoc).findRanges("First paragraph continues", caseSensitivity: .sensitive)
        #expect(sliceMatches(blocksDoc, soft) == [["First paragraph\ncontinues"]])
        let codeHit = Markdown(blocksDoc).findRanges("fn compute() -> i32 {\n    42", caseSensitivity: .sensitive)
        #expect(sliceMatches(blocksDoc, codeHit) == [["fn compute() -> i32 {\n    42"]])
        let diffHit = Markdown(blocksDoc).findRanges("-old_val\n+new_val", caseSensitivity: .sensitive)
        #expect(sliceMatches(blocksDoc, diffHit) == [["-old_val\n+new_val"]])

        // #123 (`tests/markdown_find.rs:44-55`): nested formatting inside link + multiline inline code in quotes/lists
        let nestedLink = "See [**bold *em* `code`**](https://example.org/u) now"
        #expect(sliceMatches(nestedLink, Markdown(nestedLink).findRanges("See bold em code now", caseSensitivity: .sensitive)) == [
            ["See ", "bold ", "em", " ", "code", " now"]
        ])
        let quotedCode = "> prefix `one\n> two` suffix\n\n- item `three\n  four` tail"
        #expect(sliceMatches(quotedCode, Markdown(quotedCode).findRanges("prefix one two suffix", caseSensitivity: .sensitive)) == [
            ["prefix ", "one\n", "two", " suffix"]
        ])
        #expect(sliceMatches(quotedCode, Markdown(quotedCode).findRanges("item three four tail", caseSensitivity: .sensitive)) == [
            ["item ", "three\n", "four", " tail"]
        ])
    }

    @Test("MarkdownFind handles entities, backslash escapes, Unicode case/sigma folding, and empty inputs")
    func markdownFindEntitiesEscapesUnicodeAndEdgeCases() {
        let entSrc = "AT&amp;T &mdash; \\*literal\\* and &#x26; plus \\\\ end"
        #expect(Markdown(entSrc).findRanges("amp").isEmpty)
        #expect(Markdown(entSrc).findRanges("mdash").isEmpty)
        #expect(sliceMatches(entSrc, Markdown(entSrc).findRanges("AT&T", caseSensitivity: .sensitive)) == [["AT&amp;T"]])
        // Swift maps each escaped punctuation sequence `\*` as one contiguous source span `i..<(i+2)`.
        #expect(sliceMatches(entSrc, Markdown(entSrc).findRanges("*literal*", caseSensitivity: .sensitive)) == [["\\*literal\\*"]])

        // Multibyte & case folding (Turkish İ, German ẞ/ß, Greek Σ/σ/ς)
        let uni = "İstanbul İİ und STRAẞE sowie **Straße** führen zu Café 🦀 שלום"
        #expect(Markdown(uni).findRanges("café", caseSensitivity: .sensitive).isEmpty)
        #expect(sliceMatches(uni, Markdown(uni).findRanges("CAFÉ", caseSensitivity: .insensitive)) == [["Café"]])
        #expect(sliceMatches(uni, Markdown(uni).findRanges("🦀 שלום", caseSensitivity: .insensitive)) == [["🦀 שלום"]])
        #expect(sliceMatches(uni, Markdown(uni).findRanges("straße", caseSensitivity: .insensitive)) == [["STRAẞE"], ["Straße"]])

        let greek = "ΟΣ and ος and οσ"
        #expect(sliceMatches(greek, Markdown(greek).findRanges("ος", caseSensitivity: .insensitive)) == [["ΟΣ"], ["ος"], ["οσ"]])
        #expect(sliceMatches(greek, Markdown(greek).findRanges("ΟΣ", caseSensitivity: .insensitive)) == [["ΟΣ"], ["ος"], ["οσ"]])

        // Non-overlapping & empty
        #expect(Markdown("aaaa").findRanges("aa", caseSensitivity: .sensitive) == [[0..<2], [2..<4]])
        #expect(Markdown("ababa").findRanges("aba", caseSensitivity: .sensitive) == [[0..<3]])
        #expect(Markdown("Some **markdown**").findRanges("").isEmpty)
        #expect(Markdown("").findRanges("markdown").isEmpty)
    }

    @Test("MarkdownAutolink skips image syntax, emails in plain URL scan, and unsafe schemes")
    func markdownAutolinkSafetyAndExclusions() {
        let src = "HTTP://example.org/a, ![https://image.example/alt](image.png) [https://label.example](https://dest.example) <https://angle.example> `https://code.example` javascript:alert(1) data:text/plain,test"
        let doc = MarkdownParser.parseDocument(src, autolink: true)
        let urls = doc.blocks.flatMap { block -> [String] in
            if case let .para(inl) = block { return inl.links.map(\.url) }
            return []
        }
        #expect(urls == ["HTTP://example.org/a", "https://dest.example", "https://angle.example"])
        #expect(doc.blocks.contains {
            if case let .image(imgSrc, alt, _) = $0 { return imgSrc == "image.png" && alt == "https://image.example/alt" }
            return false
        })

        // #116 (`markdown_blocks_and_highlights.rs:351-406`): GFM punctuation/parens/entity rules + .autolink(false) click test
        let gfmSrc = "Visit https://example.org/docs?x=1#top, http://example.org:8080/a; and www.example.org/path/to_file! Also (see https://en.wikipedia.org/wiki/Rust_(programming_language)) and https://example.org/entity&nbsp; but not `https://in.code` or [explicit](https://explicit.example/x).\n\n```\nhttps://in.fence.example\n```\n"
        let gfmDoc = MarkdownParser.parseDocument(gfmSrc, autolink: true)
        if case let .para(p) = gfmDoc.blocks[0] {
            let pairs = p.links.map { (utf8Slice(p.text, $0.start..<$0.end), $0.url) }
            #expect(pairs.map(\.0) == [
                "https://example.org/docs?x=1#top",
                "http://example.org:8080/a",
                "www.example.org/path/to_file",
                "https://en.wikipedia.org/wiki/Rust_(programming_language)",
                "https://example.org/entity",
                "explicit",
            ])
            #expect(pairs.map(\.1) == [
                "https://example.org/docs?x=1#top",
                "http://example.org:8080/a",
                "http://www.example.org/path/to_file",
                "https://en.wikipedia.org/wiki/Rust_(programming_language)",
                "https://example.org/entity",
                "https://explicit.example/x",
            ])
        } else {
            Issue.record("Expected GFM paragraph block")
        }

        struct AutoState: Sendable {
            var autolink = true
            var opened: [String] = []
        }
        let kit = Kit.neutral(dark: true)
        let autoRT = Runtime<AutoState>(state: AutoState(), viewport: Vec2(480, 120), pixelScale: 1.0, systemDark: true) { s, _ in
            col().w(480).child(
                Markdown("Try www.example.org/hello, or [named](https://named.example).")
                    .autolink(s.autolink)
                    .onLink { st, url, _ in st.opened.append(url) }
                    .build(kit)
            )
        }
        _ = autoRT.frame(at: 0.0)
        let bareEl = autoRT.elements().first(where: { $0.role == .link && $0.key == "http://www.example.org/hello" })!
        let barePt = Vec2(bareEl.rect[0] + bareEl.rect[2] * 0.5, bareEl.rect[1] + bareEl.rect[3] * 0.5)
        autoRT.pointerMove(to: barePt, at: 0.01)
        autoRT.pointerDown(at: barePt, at: 0.01)
        autoRT.pointerUp(at: barePt, at: 0.01)
        _ = autoRT.frame(at: 0.02)
        #expect(autoRT.state.opened == ["http://www.example.org/hello"])

        autoRT.update(at: 0.03) { s, _ in
            s.autolink = false
            s.opened.removeAll()
        }
        _ = autoRT.frame(at: 0.04)
        #expect(autoRT.elements().first(where: { $0.role == .link && $0.key == "http://www.example.org/hello" }) == nil)
        #expect(autoRT.elements().first(where: { $0.role == .link && $0.key == "https://named.example" }) != nil)
    }

    // MARK: - Block Parsing, Tables, Diffs, Code, Bidi, PlainText

    @Test("Tables parse alignments, inline links, escaped pipes, ragged rows, and trailing header lines")
    func tableParsingAlignmentsAndEscapedPipes() {
        let tableSrc = "| Name | Count | Note |\n|:-----|:-----:|-----:|\n| **a** | 1 | [x](https://x.dev) |\n| b |\n"
        let blocks = MarkdownParser.parseAST(tableSrc)
        if case let .table(t) = blocks[0] {
            #expect(t.align == [.start, .center, .end])
            #expect(t.head.map(\.unpaddedText) == ["Name", "Count", "Note"])
            #expect(t.rows[0][0].spans.contains(where: { $0.style == .strong }))
            #expect(t.rows[0][2].links.first?.url == "https://x.dev")
            #expect(t.rows[1][0].text == "b")
            #expect(!t.open)
        } else {
            Issue.record("Expected table block")
        }

        for src in ["Intro\n\n| a | b |", "Intro\n\n| a | b |\n|:-", "Intro\n\n| a | b |\n|--|--:|"] {
            let parsed = MarkdownParser.parseAST(src)
            #expect(parsed.count == 2)
            if case let .table(t) = parsed[1] {
                #expect(t.rows.isEmpty && t.head.count == 2)
            } else {
                Issue.record("Expected trailing table in \(src)")
            }
        }
        if case .para = MarkdownParser.parseAST("| just one |")[0] {} else { Issue.record("Single cell should stay para") }
        if case let .table(escaped) = MarkdownParser.parseAST("| \\| **a** \\| b | c |")[0] {
            #expect(escaped.head.count == 2)
            #expect(escaped.head[0].text == "| a | b")
        } else {
            Issue.record("Expected table with escaped pipe")
        }
    }

    @Test("MarkdownBidi detects inline, block, and table directions and isolates embedded runs")
    func markdownBidiAndPlainText() {
        let rtlDoc = MarkdownParser.parseAST("שלום **world**\n\n| א | b |\n|---|---|\n| 1 | 2 |")
        #expect(MarkdownBidi.blocksDirection([rtlDoc[0]]) == .rtl)
        if case let .table(t) = rtlDoc[1] {
            #expect(MarkdownBidi.tableDirection(t) == .rtl)
        }
        let iso = MarkdownBidi.isolateEmbeddedRuns("שלום world שלום", base: .rtl)
        #expect(iso.contains("\u{2066}") && iso.contains("\u{2069}"))

        // #61 (`tests/markdown.rs:49-60`): inline code ending a line leaves no closing \u{2069}
        let codeEndDoc = MarkdownParser.parseAST("Run `cargo test`\n\n- item `two`\n\n| `c` |\n|---|\n| `d ` |\n")
        if case let .para(p) = codeEndDoc[0] {
            #expect(p.text == "Run \u{202f}\u{202f}\u{2066}cargo test")
            #expect(!p.text.contains("\u{2069}"))
            #expect(p.spans.map(\.style) == [.codePad, .code])
        } else {
            Issue.record("Expected para block for inline code ending line")
        }
        if case let .list(_, items) = codeEndDoc[1], case let .para(itemPara) = items[0][0] {
            #expect(itemPara.text == "item \u{202f}\u{202f}\u{2066}two")
            #expect(!itemPara.text.contains("\u{2069}"))
        } else {
            Issue.record("Expected list item para")
        }
        if case let .table(tbl) = codeEndDoc[2] {
            #expect(tbl.head[0].text == "\u{202f}\u{202f}\u{2066}c")
            #expect(tbl.rows[0][0].text == "\u{202f}\u{202f}\u{2066}d")
        } else {
            Issue.record("Expected table block")
        }
    }

    // MARK: - Runtime Rendering & Interactive Parity (tests/markdown*.rs)

    @MainActor
    @Test("MarkdownView renders blocks with Kit tokens, heading levels, caller blockKeys, and code/mermaid/quote/image frames")
    func markdownRenderingFramesAndBlockKeys() {
        let doc = """
        # Title

        Some `code`, *em*, **bold** and [a link](https://x.dev/a).

        > Quoted first
        >
        > - one
        > - [x] two

        ```rust
        fn main() {}
        ```

        ```mermaid
        graph LR
          A --> B
        ```

        ![Chart alt](chart.png)
        """
        struct State: Sendable {
            var quoteTexts: [String] = []
            var codeFrames: [MarkdownCodeFrameContext] = []
            var diagramFrames: [MarkdownDiagramFrameContext] = []
            var imageFrames: [MarkdownImageFrameContext] = []
        }

        // Measure quote_frame, code_frame, diagram_frame, image_frame contexts
        let collector = LockedCollector()
        let kit = Kit.neutral(dark: true)
        let rt = Runtime<State>(state: State(), viewport: Vec2(600, 900), pixelScale: 1.0, systemDark: true) { _, _ in
            Markdown(doc)
                .codeFrame { card, ctx in
                    collector.addCode(ctx)
                    return col().key("code-\(ctx.index)").child(card)
                }
                .diagramFrame { card, ctx in
                    collector.addDiagram(ctx)
                    return col().key("diag-\(ctx.index)").child(card)
                }
                .quoteFrame { q, ctx in
                    collector.addQuote(ctx)
                    return q
                }
                .imageFrame { img, ctx in
                    collector.addImage(ctx)
                    return img
                }
                .build(kit)
        }
        _ = rt.frame(at: 0.0)

        let els = rt.elements()
        #expect(els.contains(where: { $0.role == .heading && ($0.text ?? "").contains("Title") }))
        #expect(els.contains(where: { $0.role == .image && $0.label == "Chart alt" }))
        #expect(els.contains(where: { $0.key == "code-0" }))
        #expect(els.contains(where: { $0.key == "diag-1" }))

        let snap = collector.snapshot()
        #expect(snap.codes.count == 1)
        #expect(snap.codes[0].index == 0 && snap.codes[0].language == "rust" && snap.codes[0].source == "fn main() {}")
        #expect(snap.diagrams.count == 1)
        #expect(snap.diagrams[0].index == 1 && !snap.diagrams[0].open)
        #expect(snap.quotes == ["Quoted first\n\n- one\n- [x] two"])
        #expect(snap.images == [MarkdownImageFrameContext(src: "chart.png", alt: "Chart alt", title: "")])
    }

    @MainActor
    @Test("Caller blockKeys assign custom keys, avoid collisions, and keep streaming prefixes mounted")
    func callerBlockKeysAndStreamingMount() {
        let kit = Kit.neutral(dark: true)
        let rt = Runtime<String>(state: "# Heading\n\nPara two\n\nPara three", viewport: Vec2(360, 400), pixelScale: 1.0, systemDark: true) { src, _ in
            let b1Offset = src.utf8.count > 11 ? 11 : 0
            return Markdown(src)
                .blockKeys([(0, "sec-head"), (b1Offset, "sec-two"), (b1Offset + 10, "sec-two")])
                .build(kit)
        }
        _ = rt.frame(at: 0.0)
        let keys = rt.elements().compactMap(\.key)
        #expect(keys.contains("sec-head"))
        #expect(keys.contains("sec-two"))
        #expect(keys.contains("b2"))

        // Streaming append keeps earlier blocks mounted under b0, b1...
        rt.update(at: 0.016) { s, _ in s.append("\n\n- appended") }
        _ = rt.frame(at: 0.032)
        let keys2 = rt.elements().compactMap(\.key)
        #expect(keys2.contains("sec-head") && keys2.contains("b3"))

        // #65 (`tests/markdown.rs:104-126`): default b0/b1 keys & element.path stability without caller blockKeys
        let defaultSteps = [
            "# Plan\n\nFirst para",
            "# Plan\n\nFirst para is done.\n\n- a",
            "# Plan\n\nFirst para is done.\n\n- a\n- b\n\n```sh\nls",
            "# Plan\n\nFirst para is done.\n\n- a\n- b\n\n```sh\nls -la\n",
        ]
        let defRT = Runtime<String>(state: defaultSteps[0], viewport: Vec2(360, 500), pixelScale: 1.0, systemDark: true) { src, _ in
            Markdown(src).build(kit)
        }
        _ = defRT.frame(at: 0.0)
        var seenDefaultKeys = Set(defRT.elements().compactMap(\.key))
        let headPath = defRT.element(byKey: "b0")!.path
        #expect(seenDefaultKeys.contains("b0") && seenDefaultKeys.contains("b1"))
        for (i, step) in defaultSteps.dropFirst().enumerated() {
            defRT.update(at: Double(i + 1) * 0.02) { s, _ in s = step }
            _ = defRT.frame(at: Double(i + 1) * 0.02 + 0.01)
            let nowKeys = Set(defRT.elements().compactMap(\.key))
            for prev in seenDefaultKeys {
                #expect(nowKeys.contains(prev), "Key \(prev) lost at step \(i + 1)")
            }
            #expect(defRT.element(byKey: "b0")!.path == headPath)
            seenDefaultKeys = nowKeys
        }
        #expect(seenDefaultKeys.contains("b3"))
    }

    @MainActor
    @Test("Interactive task lists fire onTask on click, render check marks, and honor tasksReadOnly")
    func taskListCheckboxesInteractiveAndReadOnly() {
        struct TaskState: Sendable {
            var src: String
            var handled: Bool = true
            var readOnly: Bool = false
            var toggled: [(String, Int, Bool)] = []
        }

        let kit = Kit.neutral(dark: true)
        let rt = Runtime<TaskState>(
            state: TaskState(src: "Notes\n\n- [ ] alpha\n- [x] beta\n"),
            viewport: Vec2(320, 300),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            var md = Markdown(s.src).blockKeys([(0, "intro"), (7, "checklist")]).view(for: TaskState.self)
            if s.handled {
                md = md.onTask { st, blockKey, offset, nextChecked, tx in
                    st.toggled.append((blockKey, offset, nextChecked))
                    tx.copyText("\(blockKey):\(offset):\(nextChecked)")
                }
            }
            if s.readOnly {
                md = md.tasksReadOnly(true)
            }
            return col().w(320).child(md.build(kit))
        }
        _ = rt.frame(at: 0.0)

        let boxes = rt.elements().filter { $0.role == .checkbox }
        #expect(boxes.count == 2)
        #expect(boxes[0].label == "alpha" && boxes[0].selected == "false" && boxes[0].focusable)
        #expect(boxes[1].label == "beta" && boxes[1].selected == "true" && boxes[1].focusable)

        let marks = rt.elements().filter { $0.key == "mark" }
        #expect(marks.count == 2)
        #expect(marks[0].opacity == 0 && marks[1].opacity == 1)

        // Click checkbox 0
        let b0 = boxes[0].rect
        let p0 = Vec2(b0[0] + 12, b0[1] + b0[3] * 0.5)
        rt.pointerMove(to: p0, at: 0.01)
        rt.pointerDown(at: p0, at: 0.01)
        rt.pointerUp(at: p0, at: 0.01)
        _ = rt.frame(at: 0.02)
        #expect(rt.state.toggled.count == 1)
        #expect(rt.state.toggled[0].0 == "checklist" && rt.state.toggled[0].1 == 9 && rt.state.toggled[0].2 == true)

        // Click checkbox 1
        let b1 = boxes[1].rect
        let p1 = Vec2(b1[0] + 12, b1[1] + b1[3] * 0.5)
        rt.pointerMove(to: p1, at: 0.03)
        rt.pointerDown(at: p1, at: 0.03)
        rt.pointerUp(at: p1, at: 0.03)
        _ = rt.frame(at: 0.04)
        #expect(rt.state.toggled.count == 2)
        #expect(rt.state.toggled[1].0 == "checklist" && rt.state.toggled[1].1 == 21 && rt.state.toggled[1].2 == false)

        // Read-only disables focusable & clicks
        rt.update(at: 0.05) { st, _ in
            st.readOnly = true
            st.toggled.removeAll()
        }
        _ = rt.frame(at: 0.06)
        let roBoxes = rt.elements().filter { !$0.exiting && $0.role == .checkbox }
        #expect(roBoxes.count == 2 && !roBoxes[0].focusable && !roBoxes[1].focusable)
        rt.pointerDown(at: p0, at: 0.07)
        rt.pointerUp(at: p0, at: 0.07)
        _ = rt.frame(at: 0.08)
        #expect(rt.state.toggled.isEmpty)

        // #112 (`markdown_blocks_and_highlights.rs:149-178`): nested tasks + Tab/Space keyboard nav & readOnly skip
        let nestedSrc = "Préface\n\n- plain\n  - [ ] nested\n- [x] outer\n\nTail\n\n- [ ] last\n"
        let nestRT = Runtime<TaskState>(
            state: TaskState(src: nestedSrc),
            viewport: Vec2(320, 400),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            var md = Markdown(s.src).view(for: TaskState.self)
            if s.handled {
                md = md.onTask { st, blockKey, offset, nextChecked, _ in
                    st.toggled.append((blockKey, offset, nextChecked))
                }
            }
            if s.readOnly {
                md = md.tasksReadOnly(true)
            }
            return col().w(320).child(md.build(kit))
        }
        _ = nestRT.frame(at: 0.0)
        // Space without focus does nothing
        _ = nestRT.keyDown(KeyEvent(key: .space), at: 0.01)
        _ = nestRT.frame(at: 0.02)
        #expect(nestRT.state.toggled.isEmpty)

        let expectedSteps: [(String, String, Bool)] = [
            ("[ ] nested", "b1", true),
            ("[x] outer", "b1", false),
            ("[ ] last", "b3", true),
        ]
        var nt = 0.03
        for (idx, (marker, wantKey, wantChecked)) in expectedSteps.enumerated() {
            _ = nestRT.keyDown(KeyEvent(key: .tab), at: nt); nt += 0.01
            _ = nestRT.frame(at: nt); nt += 0.01
            _ = nestRT.keyDown(KeyEvent(key: .space), at: nt); nt += 0.01
            _ = nestRT.frame(at: nt); nt += 0.01
            #expect(nestRT.state.toggled.count == idx + 1)
            let markerOff = nestedSrc.utf8.distance(from: nestedSrc.startIndex, to: nestedSrc.range(of: marker)!.lowerBound)
            #expect(nestRT.state.toggled[idx] == (wantKey, markerOff, wantChecked))
        }
        nestRT.update(at: nt) { st, _ in st.readOnly = true; st.toggled.removeAll() }
        nt += 0.01
        _ = nestRT.frame(at: nt); nt += 0.01
        for _ in 0..<4 {
            _ = nestRT.keyDown(KeyEvent(key: .tab), at: nt); nt += 0.01
            _ = nestRT.keyDown(KeyEvent(key: .space), at: nt); nt += 0.01
            _ = nestRT.frame(at: nt); nt += 0.01
        }
        #expect(nestRT.state.toggled.isEmpty)
        #expect(nestRT.elements().filter { $0.role == .checkbox }.allSatisfy { !$0.focusable })
    }

    @MainActor
    @Test("Links trigger onLink, onLinkSecondary, linkHelp tooltip, linkStyle, and codeLink")
    func markdownLinksCallbacksHelpAndCodeLink() {
        struct LinkState: Sendable {
            var primary: [String] = []
            var secondary: [String] = []
        }

        let kit = Kit.neutral(dark: true)
        let rt = Runtime<LinkState>(state: LinkState(), viewport: Vec2(480, 200), pixelScale: 1.0, systemDark: true) { _, _ in
            Markdown("See [Docs](https://x.dev/a) or `src/main.swift`.")
                .linkHelp { url in url.hasPrefix("https:") ? "Open \(url)" : nil }
                .codeLink(match: { code in code.hasSuffix(".swift") ? "file://\(code)" : nil }, color: Color(r: 0.2, g: 0.6, b: 1.0, a: 1.0))
                .onLink { st, url, _ in st.primary.append(url) }
                .onLinkSecondary { st, url, _ in st.secondary.append(url) }
                .build(kit)
        }
        _ = rt.frame(at: 0.0)

        let els = rt.elements()
        let docsLink = els.first(where: { $0.role == .link && $0.key == "https://x.dev/a" })
        let codeLink = els.first(where: { $0.role == .link && $0.key == "file://src/main.swift" })
        #expect(docsLink != nil)
        #expect(codeLink != nil)
        #expect(docsLink?.help == "Open https://x.dev/a")
        if let dr = docsLink?.rect {
            let leftHit = Vec2(dr[0] + dr[2] * 0.5, dr[1] + dr[3] * 0.5)
            rt.pointerMove(to: leftHit, at: 0.01)
            rt.pointerDown(at: leftHit, at: 0.01)
            rt.pointerUp(at: leftHit, at: 0.01)
            _ = rt.frame(at: 0.02)
            #expect(rt.state.primary == ["https://x.dev/a"])
        }
        if let cr = codeLink?.rect {
            let rightHit = Vec2(cr[0] + cr[2] * 0.5, cr[1] + cr[3] * 0.5)
            rt.pointerMove(to: rightHit, at: 0.03)
            rt.pointerDown(at: rightHit, button: .secondary, at: 0.03)
            rt.pointerUp(at: rightHit, button: .secondary, at: 0.03)
            _ = rt.frame(at: 0.04)
            #expect(rt.state.secondary == ["file://src/main.swift"])
        }

        // #68 (`tests/markdown.rs:166-212`): Cursor.pointer, Tab+Enter opening links, and !focusable + .default cursor without onLink
        struct LinksDocState: Sendable {
            var handled: Bool
            var opened: [String] = []
        }
        let linksDoc = "See [one](https://a.dev) and [two](https://b.dev).\n\n- an item with [three](https://c.dev)\n"
        let navLinkRT = Runtime<LinksDocState>(state: LinksDocState(handled: true), viewport: Vec2(480, 400), pixelScale: 1.0, systemDark: true) { s, _ in
            let md = Markdown(linksDoc)
            let built: El<LinksDocState> = s.handled
                ? md.onLink { st, url, _ in st.opened.append(url) }.build(kit)
                : md.build(kit)
            return col().wFull().p(10).child(built)
        }
        _ = navLinkRT.frame(at: 0.0)
        let twoEl = navLinkRT.elements().first(where: { $0.role == .link && $0.key == "https://b.dev" })!
        navLinkRT.pointerMove(to: Vec2(twoEl.rect[0] + twoEl.rect[2] * 0.5, twoEl.rect[1] + twoEl.rect[3] * 0.5), at: 0.01)
        _ = navLinkRT.frame(at: 0.02)
        #expect(navLinkRT.currentCursor() == .pointer)

        _ = navLinkRT.keyDown(KeyEvent(key: .tab), at: 0.03)
        _ = navLinkRT.frame(at: 0.04)
        _ = navLinkRT.keyDown(KeyEvent(key: .enter), at: 0.05)
        _ = navLinkRT.frame(at: 0.06)
        #expect(navLinkRT.state.opened == ["https://a.dev"])

        navLinkRT.update(at: 0.07) { s, _ in s.handled = false; s.opened.removeAll() }
        _ = navLinkRT.frame(at: 0.08)
        #expect(navLinkRT.elements().allSatisfy { !$0.focusable && !$0.path.contains("#link-") })
        navLinkRT.pointerMove(to: Vec2(twoEl.rect[0] + twoEl.rect[2] * 0.5, twoEl.rect[1] + twoEl.rect[3] * 0.5), at: 0.09)
        _ = navLinkRT.frame(at: 0.10)
        #expect(navLinkRT.currentCursor() == .default)
    }

    @MainActor
    @Test("Tables render default outlined look vs tableCard preset, tableHeaderPad, tableMargin, and scrollWide")
    func markdownTableCardAndLayoutModes() {
        let src = """
        Before.

        | | West | Centre |
        |---|---|---|
        | North | Lettuce ×2 | Tomato ×2 |
        | Middle | Wheat ×1 | Feed box |
        | South | Ranch | Kitchen |

        After.
        """
        let kit = Kit.neutral(dark: true)

        // 1. tableCard preset puts body rows inside tb/tbc card inset inside frame
        let cardRT = Runtime<Int>(state: 0, viewport: Vec2(700, 600), pixelScale: 2.0, systemDark: true) { _, _ in
            let style = MarkdownStyle.fromKit(kit).tableCard(kit)
            return col().w(600).child(Markdown(src).render(style))
        }
        _ = cardRT.frame(at: 0.0)
        let cardEls = cardRT.elements()
        let th = cardEls.first(where: { $0.key == "th" })
        let tb = cardEls.first(where: { $0.key == "tb" })
        let tbc = cardEls.first(where: { $0.key == "tbc" })
        #expect(th != nil && tb != nil && tbc != nil)
        if let th, let tb, let tbc, let parentIdx = th.parentIndex {
            let frame = cardEls[parentIdx]
            #expect(frame.radius == 6.0 && approxColor(frame.fill, kit.c.layer01))
            #expect(tb.radius == 4.0 && approxColor(tb.fill, kit.c.bgBase))
            #expect(abs((th.rect[0] - frame.rect[0]) - 2.0) < 0.1)
            #expect(abs((th.rect[1] - frame.rect[1]) - 2.0) < 0.1)
            #expect(abs(tb.rect[1] - (th.rect[1] + th.rect[3])) < 0.1)
            #expect(tbc.rect == tb.rect)
        }
        #expect(!cardEls.contains(where: { $0.key == "s0" || $0.key == "s-end" }))

        // 2. Default style keeps separators and outlined frame
        let plainRT = Runtime<Int>(state: 0, viewport: Vec2(700, 600), pixelScale: 2.0, systemDark: true) { _, _ in
            col().w(600).child(Markdown(src).build(kit))
        }
        _ = plainRT.frame(at: 0.0)
        let plainEls = plainRT.elements()
        #expect(plainEls.contains(where: { $0.key == "s0" && $0.key != "tb" }))
        #expect(!plainEls.contains(where: { $0.key == "tb" }))

        // 3. scrollWide wraps wide table and wide code in "scroll" viewport
        let wideSrc = """
        ```rust
        let very_long_identifier_name_that_exceeds_a_narrow_column_width = 1234567890 + 987654321;
        ```

        | Column Alpha Wide | Column Beta Wide | Column Gamma Wide | Column Delta Wide |
        |---|---|---|---|
        | alpha_long_cell_value | beta_long_cell_value | gamma_long_cell_value | delta_long_cell_value |
        """
        let wideRT = Runtime<Int>(state: 0, viewport: Vec2(300, 400), pixelScale: 1.0, systemDark: true) { _, _ in
            col().w(240).child(Markdown(wideSrc).scrollWide(true).build(kit))
        }
        _ = wideRT.frame(at: 0.0)
        #expect(wideRT.elements().filter { $0.key == "scroll" }.count >= 2)
    }

    @MainActor
    @Test("Diff fences tint + and - rows, dim hunk headers, and mermaid fences stream & fall back cleanly")
    func diffFencesAndStreamingMermaid() {
        let kit = Kit.neutral(dark: true)
        let diffDoc = """
        ```diff
        @@ -1,2 +1,2 @@
        -old line
        +new line
         context
        ```
        """
        let diffRT = Runtime<Int>(state: 0, viewport: Vec2(480, 300), pixelScale: 1.0, systemDark: true) { _, _ in
            Markdown(diffDoc).build(kit)
        }
        _ = diffRT.frame(at: 0.0)
        let diffEls = diffRT.elements()
        let l0 = diffEls.first(where: { $0.key == "l0" })
        let l1 = diffEls.first(where: { $0.key == "l1" })
        let l2 = diffEls.first(where: { $0.key == "l2" })
        let style = MarkdownStyle.fromKit(kit)
        #expect(l0 != nil && l0?.fill == Color.transparent)
        #expect(approxColor(l1?.fill, style.diffRemove))
        #expect(approxColor(l2?.fill, style.diffAdd))

        // #78 (`tests/markdown.rs:468-503`): ```patch fence, line tint rect widths, hunk textColor, & diffTextTint(0.5)
        if case .diff = MarkdownParser.parseAST("```patch\n+a\n```").first {} else {
            Issue.record("Expected ```patch fence to parse as .diff")
        }
        let addC = Color(r: 0, g: 1, b: 0, a: 1)
        let remC = Color(r: 1, g: 0, b: 0, a: 1)
        let hunkC = Color(r: 0, g: 0, b: 1, a: 1)
        let patchDoc = "```diff\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n```\n"
        let styledDiffRT = Runtime<Int>(state: 0, viewport: Vec2(480, 400), pixelScale: 1.0, systemDark: false) { _, _ in
            col().wFull().child(
                Markdown(patchDoc).render(MarkdownStyle.neutral(dark: false).diff(added: addC, removed: remC).diffHunk(hunkC))
            )
        }
        _ = styledDiffRT.frame(at: 0.0)
        let sdEls = styledDiffRT.elements()
        let blockRect = sdEls.first(where: { $0.key == "b0" })!.rect
        for lk in ["l2", "l3"] {
            let tint = sdEls.first(where: { $0.key == lk })!.rect
            #expect(tint[2] >= blockRect[2] - 2.0 && tint[0] >= blockRect[0] && tint[0] + tint[2] <= blockRect[0] + blockRect[2] + 0.01)
        }
        let hunkEl = sdEls.first(where: { $0.text == "@@ -1,2 +1,2 @@" })!
        #expect(hunkEl.textColor == hunkC)
        let untintedBase = Kit.neutral(dark: false).c.textBase
        #expect(sdEls.first(where: { $0.text == "+new" })?.textColor == untintedBase)
        #expect(sdEls.first(where: { $0.text == "-old" })?.textColor == untintedBase)

        let tintedDiffRT = Runtime<Int>(state: 0, viewport: Vec2(480, 400), pixelScale: 1.0, systemDark: false) { _, _ in
            col().wFull().child(
                Markdown(patchDoc).render(MarkdownStyle.neutral(dark: false).diffTextTint(0.5))
            )
        }
        _ = tintedDiffRT.frame(at: 0.0)
        let tdEls = tintedDiffRT.elements()
        let addTextCol = tdEls.first(where: { $0.text == "+new" })!.textColor!
        let remTextCol = tdEls.first(where: { $0.text == "-old" })!.textColor!
        #expect(addTextCol.g > addTextCol.r && remTextCol.r > remTextCol.g)
        #expect(tdEls.first(where: { $0.text == " keep" })?.textColor == untintedBase)

        // Streaming mermaid: incomplete lines wait before diagram appears; unsupported type falls back to "source".
        let mermaidRT = Runtime<(String, Bool)>(
            state: ("```mermaid\ngraph TD\n  A[Start] --> B[End]\n", true),
            viewport: Vec2(600, 600),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col().wFull().child(Markdown(s.0).streaming(s.1).build(kit))
        }
        _ = mermaidRT.frame(at: 0.0)
        let mKeys = mermaidRT.elements().compactMap(\.key)
        #expect(mKeys.contains("n:A") && mKeys.contains("n:B") && !mKeys.contains("source"))

        mermaidRT.update(at: 0.02) { s, _ in s.0 = "```mermaid\nkanban\n  Todo\n" }
        _ = mermaidRT.frame(at: 0.04)
        #expect(mermaidRT.elements().compactMap(\.key).contains("source"))
    }

    @Test("Markdown selectable, selectionGroup, selectionCopy, and sourceCopy parity")
    @MainActor
    func markdownSelectableAndSourceCopyWiring() {
        func countSelectableTexts<S>(_ node: El<S>) -> Int {
            var count = node.isSelectable ? 1 : 0
            for child in node.children {
                count += countSelectableTexts(child)
            }
            return count
        }

        let kit = Kit.neutral(dark: true)
        let src = "# Title\n\nHello **world** and [link](https://x.dev/a).\n\n- alpha\n- [x] beta\n\n```rust\nfn main() {}\n```\n\nLast *line*.\n"
        let nonSelectable: El<Int> = Markdown(src).selectable(false).copySource(true).build(kit)
        #expect(!nonSelectable.isSelectionGroup)
        #expect(!nonSelectable.hasSelectionCopyHandler)
        #expect(countSelectableTexts(nonSelectable) == 0)

        let selectableOnly: El<Int> = Markdown(src).selectable(true).copySource(false).build(kit)
        #expect(selectableOnly.isSelectionGroup)
        #expect(!selectableOnly.hasSelectionCopyHandler)
        #expect(countSelectableTexts(selectableOnly) >= 6)

        let tableDiffSrc = "| A | B |\n| --- | --- |\n| 1 | 2 |\n\n```diff\n@@ -1 +1 @@\n-old\n+new\n```\n"
        let tableDiffEl: El<Int> = Markdown(tableDiffSrc).selectable(true).build(kit)
        #expect(countSelectableTexts(tableDiffEl) >= 7)

        let copySourceRoot: El<Int> = Markdown(src).selectable(true).copySource(true).build(kit)
        #expect(copySourceRoot.isSelectionGroup)
        #expect(copySourceRoot.hasSelectionCopyHandler)

        let allWhole = TextSelection(
            texts: [
                SelectedText(path: "b0/t", range: 0..<5, len: 5, whole: true, text: "Title", content: "Title"),
                SelectedText(path: "b1/t", range: 0..<21, len: 21, whole: true, text: "Hello world and link.", content: "Hello world and link."),
                SelectedText(path: "b2/i0/b0", range: 0..<5, len: 5, whole: true, text: "alpha", content: "alpha"),
                SelectedText(path: "b2/i1/b0", range: 0..<4, len: 4, whole: true, text: "beta", content: "beta"),
                SelectedText(path: "b3/code", range: 0..<12, len: 12, whole: true, text: "fn main() {}", content: "fn main() {}"),
                SelectedText(path: "b4/t", range: 0..<10, len: 10, whole: true, text: "Last line.", content: "Last line."),
            ],
            text: "drawn"
        )
        #expect(copySourceRoot.invokeSelectionCopy(allWhole) == src)

        let onlyB1 = TextSelection(
            texts: [
                SelectedText(path: "b0/t", range: 0..<0, len: 5, whole: false, text: "", content: "Title"),
                SelectedText(path: "b1/t", range: 0..<21, len: 21, whole: true, text: "Hello world and link.", content: "Hello world and link."),
                SelectedText(path: "b2/i0/b0", range: 0..<0, len: 5, whole: false, text: "", content: "alpha"),
            ],
            text: "Hello world and link."
        )
        #expect(copySourceRoot.invokeSelectionCopy(onlyB1) == "Hello **world** and [link](https://x.dev/a).")

        let onlyB2 = TextSelection(
            texts: [
                SelectedText(path: "@note/@b1/@t", range: 0..<0, len: 21, whole: false, text: "", content: "Hello world and link."),
                SelectedText(path: "@note/@b2/@i0/@b0", range: 0..<5, len: 5, whole: true, text: "alpha", content: "alpha"),
                SelectedText(path: "@note/@b2/@i1/@b0", range: 0..<4, len: 4, whole: true, text: "beta", content: "beta"),
                SelectedText(path: "@note/@b3/@code", range: 0..<0, len: 12, whole: false, text: "", content: "fn main() {}"),
            ],
            text: "- alpha\n- [x] beta"
        )
        #expect(copySourceRoot.invokeSelectionCopy(onlyB2) == "- alpha\n- [x] beta")

        let partialB1 = TextSelection(
            texts: [
                SelectedText(path: "b0/t", range: 0..<0, len: 5, whole: false, text: "", content: "Title"),
                SelectedText(path: "b1/t", range: 6..<11, len: 21, whole: false, text: "world", content: "Hello world and link."),
                SelectedText(path: "b2/i0/b0", range: 0..<0, len: 5, whole: false, text: "", content: "alpha"),
            ],
            text: "world"
        )
        #expect(copySourceRoot.invokeSelectionCopy(partialB1) == nil)

        let ruled = "---\n\nHello **world**\n\n---\n"
        let ruledRoot: El<Int> = Markdown(ruled).selectable(true).copySource(true).build(kit)
        let ruledSel = TextSelection(
            texts: [SelectedText(path: "b1/t", range: 0..<11, len: 11, whole: true, text: "Hello world", content: "Hello world")],
            text: "Hello world"
        )
        #expect(ruledRoot.invokeSelectionCopy(ruledSel) == ruled)

        let crlf = "```rust\r\nfn main() {}\r\n```\r\n\r\n```diff\r\n@@ -1 +1 @@\r\n-old\r\n+new\r\n```\r\n"
        let crlfRoot: El<Int> = Markdown(crlf).selectable(true).copySource(true).build(kit)
        let crlfSel = TextSelection(
            texts: [
                SelectedText(path: "b0/code", range: 0..<12, len: 12, whole: true, text: "fn main() {}", content: "fn main() {}"),
                SelectedText(path: "b1/l0", range: 0..<11, len: 11, whole: true, text: "@@ -1 +1 @@", content: "@@ -1 +1 @@"),
                SelectedText(path: "b1/l1", range: 0..<4, len: 4, whole: true, text: "-old", content: "-old"),
                SelectedText(path: "b1/l2", range: 0..<4, len: 4, whole: true, text: "+new", content: "+new"),
            ],
            text: "fn main() {}\n\n@@ -1 +1 @@\n-old\n+new"
        )
        #expect(crlfRoot.invokeSelectionCopy(crlfSel) == crlf)
    }

    @MainActor
    @Test("Markdown selectable & copySource end-to-end Runtime tests (tests/markdown_copy_source.rs & markdown_select.rs)")
    func markdownRuntimeSelectAndCopySourceParity() throws {
        let kit = Kit.neutral(dark: true)

        func glyphCenters(_ rt: Runtime<some Sendable>, pathSuffix: String) -> [Vec2] {
            guard let el = rt.elements().first(where: { $0.path.hasSuffix(pathSuffix) }) else {
                return []
            }
            let scene = rt.frame(at: rt.currentTime)
            let scale = max(rt.pixelScale, 1.0)
            var out: [Vec2] = scene.primitives.compactMap { p -> Vec2? in
                guard p.kind == .glyph else { return nil }
                let cx = (p.rect.x + p.rect.z * 0.5) / scale
                let cy = (p.rect.y + p.rect.w * 0.5) / scale
                guard cx >= el.rect[0] && cx <= el.rect[0] + el.rect[2]
                        && cy >= el.rect[1] && cy <= el.rect[1] + el.rect[3] else {
                    return nil
                }
                return Vec2(cx, cy)
            }
            out.sort { a, b in
                let ay = (a.y / 10.0).rounded()
                let by = (b.y / 10.0).rounded()
                return ay != by ? ay < by : a.x < b.x
            }
            return out
        }

        func drag(_ rt: Runtime<some Sendable>, from p0: Vec2, to p1: Vec2, t: inout Double) {
            rt.pointerMove(to: p0, at: t)
            rt.pointerDown(at: p0, button: .primary, mods: .none, at: t)
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            for k in 1...6 {
                let f = Float(k) / 6.0
                rt.pointerMove(to: Vec2(p0.x + (p1.x - p0.x) * f, p0.y + (p1.y - p0.y) * f), at: t)
                t += 1.0 / 60.0
                _ = rt.frame(at: t)
            }
            rt.pointerUp(at: p1, button: .primary, mods: .none, at: t)
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }

        // 1. markdown_copy_source: copying_takes_the_source_of_whole_blocks, a_drag_across_blocks_copies_each_whole,
        //    without_copy_source_copying_takes_the_drawn_text
        let copySrcDoc = "# Title\n\nHello **world** and [link](https://x.dev/a).\n\n- alpha\n- [x] beta\n\n```rust\nfn main() {}\n```\n\nLast *line*.\n"
        struct CopyDocState { var source: Bool }
        func copyThroughRuntime(_ rt: Runtime<CopyDocState>, t: inout Double, _ action: (inout Tx) -> Void) -> String {
            rt.update(at: t) { _, tx in action(&tx) }
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            _ = rt.keyDown(KeyEvent(key: .command("c"), mods: Mods(cmd: true)), at: t)
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            return rt.clipboard.text
        }

        let copyRT = Runtime<CopyDocState>(state: CopyDocState(source: true), viewport: Vec2(480, 800), pixelScale: 2.0, systemDark: true) { s, _ in
            col().wFull().p(10.0).child(Markdown(copySrcDoc).selectable(true).copySource(s.source).build(kit).key("note"))
        }
        var t = 0.0
        _ = copyRT.frame(at: t)
        let b1Path = copyRT.elements().first(where: { $0.path.hasSuffix("@note/@b1") })!.path
        let b2Path = copyRT.elements().first(where: { $0.path.hasSuffix("@note/@b2") })!.path
        let b3Path = copyRT.elements().first(where: { $0.path.hasSuffix("@note/@b3") })!.path
        let alphaPath = copyRT.elements().first(where: { $0.path.hasSuffix("@note/@b2/@i0/@1/@b0") || $0.path.hasSuffix("@note/@b2/@i0/1/@b0") })?.path
            ?? copyRT.elements().first(where: { $0.path.contains("@note/@b2/@i0") && $0.path.hasSuffix("@b0") })!.path

        #expect(copyThroughRuntime(copyRT, t: &t) { $0.selectAllText("note") } == copySrcDoc)
        #expect(copyRT.selectedText()?.hasPrefix("Title\n") == true)
        #expect(copyThroughRuntime(copyRT, t: &t) { $0.selectAllText(b1Path) } == "Hello **world** and [link](https://x.dev/a).")
        #expect(copyThroughRuntime(copyRT, t: &t) { $0.selectAllText(b2Path) } == "- alpha\n- [x] beta")
        #expect(copyThroughRuntime(copyRT, t: &t) { $0.selectAllText(b3Path) } == "```rust\nfn main() {}\n```")
        #expect(copyThroughRuntime(copyRT, t: &t) { $0.selectText(b1Path, range: 6..<11) } == "world")
        #expect(copyThroughRuntime(copyRT, t: &t) { $0.selectAllText(alphaPath) } == "alpha")

        // Drag across b1..b4 copies raw markdown slice from b1 onward.
        let b1El = copyRT.elements().first(where: { $0.path == b1Path })!
        let b4El = copyRT.elements().first(where: { $0.path.hasSuffix("@note/@b4") })!
        drag(
            copyRT,
            from: Vec2(b1El.rect[0] + 30.0, b1El.rect[1] + b1El.rect[3] * 0.5),
            to: Vec2(b4El.rect[0] + 10.0, b4El.rect[1] + b4El.rect[3] * 0.5),
            t: &t
        )
        let midSel = copyRT.selectedText() ?? ""
        #expect(midSel.contains("alpha") && !midSel.hasPrefix("Hello"))
        _ = copyRT.keyDown(KeyEvent(key: .command("c"), mods: Mods(cmd: true)), at: t)
        t += 1.0 / 60.0
        _ = copyRT.frame(at: t)
        let expectedTail = String(copySrcDoc.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(copyRT.clipboard.text == expectedTail)

        // Without copySource, Select All copies the drawn text rather than raw Markdown syntax.
        copyRT.update(at: t) { s, _ in s.source = false }
        t += 1.0 / 60.0
        _ = copyRT.frame(at: t)
        let plainAll = copyThroughRuntime(copyRT, t: &t) { $0.selectAllText("note") }
        #expect(!plainAll.contains("**world**"))
        #expect(plainAll.contains("Title") && plainAll.contains("Hello world and link.") && plainAll.contains("fn main() {}") && plainAll.contains("Last line."))

        // 2. an_apps_on_key_sees_cmd_a_before_a_clicked_note
        struct KeysState { var takes: Bool; var keys: [Key] = [] }
        for takes in [true, false] {
            let keyRT = Runtime<KeysState>(
                state: KeysState(takes: takes),
                viewport: Vec2(300, 200),
                pixelScale: 2.0,
                systemDark: true,
                onKey: { s, ev, _ in
                    s.keys.append(ev.key)
                    return s.takes && ev.key == .command("a")
                }
            ) { _, _ in
                col().wFull().p(10.0).child(Markdown("a\n\nb").selectable(true).build(kit).key("note"))
            }
            var kt = 0.0
            _ = keyRT.frame(at: kt)
            let p0 = keyRT.elements().first(where: { $0.path.hasSuffix("@note/@b0") })!
            let clickPt = Vec2(p0.rect[0] + 3.0, p0.rect[1] + p0.rect[3] * 0.5)
            keyRT.pointerMove(to: clickPt, at: kt)
            keyRT.pointerDown(at: clickPt, button: .primary, mods: .none, at: kt)
            keyRT.pointerUp(at: clickPt, button: .primary, mods: .none, at: kt)
            kt += 1.0 / 60.0
            _ = keyRT.frame(at: kt)
            _ = keyRT.keyDown(KeyEvent(key: .command("a"), mods: Mods(cmd: true)), at: kt)
            kt += 1.0 / 60.0
            _ = keyRT.frame(at: kt)
            #expect(keyRT.state.keys == [.command("a")])
            if takes {
                #expect(keyRT.selectedText() == nil)
            } else {
                #expect(keyRT.selectedText() == "a\n\nb")
            }
        }

        // 3. inline_code_rule_and_crlf_blocks_copy_cleanly (ruled & CRLF portions via Runtime)
        let ruled = "---\n\nHello **world**\n\n---\n"
        let ruledRT = Runtime<Int>(state: 0, viewport: Vec2(480, 800), pixelScale: 2.0, systemDark: true) { _, _ in
            col().wFull().p(10.0).child(Markdown(ruled).selectable(true).copySource(true).build(kit).key("note"))
        }
        _ = ruledRT.frame(at: 0.0)
        ruledRT.update(at: 0.01) { _, tx in tx.selectAllText("note") }
        _ = ruledRT.frame(at: 0.02)
        _ = ruledRT.keyDown(KeyEvent(key: .command("c"), mods: Mods(cmd: true)), at: 0.02)
        #expect(ruledRT.clipboard.text == ruled)

        let crlf = "```rust\r\nfn main() {}\r\n```\r\n\r\n```diff\r\n@@ -1 +1 @@\r\n-old\r\n+new\r\n```\r\n"
        let crlfRT = Runtime<Int>(state: 0, viewport: Vec2(480, 800), pixelScale: 2.0, systemDark: true) { _, _ in
            col().wFull().p(10.0).child(Markdown(crlf).selectable(true).copySource(true).build(kit).key("note"))
        }
        _ = crlfRT.frame(at: 0.0)
        crlfRT.update(at: 0.01) { _, tx in tx.selectAllText("note") }
        _ = crlfRT.frame(at: 0.02)
        _ = crlfRT.keyDown(KeyEvent(key: .command("c"), mods: Mods(cmd: true)), at: 0.02)
        #expect(crlfRT.clipboard.text == crlf)
        #expect(crlfRT.selectedText() == "fn main() {}\n\n@@ -1 +1 @@\n-old\n+new")

        // 4. markdown_select: without_selectable_nothing_selects
        let firstMsg = "Hello **world** and [link](https://x.dev/a).\n\n- alpha\n- beta\n\n```\nfn main() {}\n```\n"
        let nonSelRT = Runtime<Int>(state: 0, viewport: Vec2(480, 800), pixelScale: 2.0, systemDark: true) { _, _ in
            col().wFull().gap(24.0).p(10.0).child(Markdown(firstMsg).selectable(false).build(kit).key("m0"))
        }
        var nt = 0.0
        _ = nonSelRT.frame(at: nt)
        let nPara = glyphCenters(nonSelRT, pathSuffix: "@m0/@b0")
        let nCode = glyphCenters(nonSelRT, pathSuffix: "@m0/@b2")
        try #require(nPara.count >= 2 && nCode.count >= 3, "nPara=\(nPara.count) nCode=\(nCode.count) paths=\(nonSelRT.elements().map(\.path))")
        nonSelRT.pointerMove(to: nPara[1], at: nt)
        #expect(nonSelRT.currentCursor() == .default)
        drag(nonSelRT, from: Vec2(nPara[1].x - 3.0, nPara[1].y), to: Vec2(nCode[2].x - 3.0, nCode[2].y), t: &nt)
        #expect(nonSelRT.selectedText() == nil)

        // 5. markdown_select: highlighted_code_copies_as_plain_text
        let pyCode = "def f(x):\n    return f\"{x!r}\"  # done"
        let pyRT = Runtime<Int>(state: 0, viewport: Vec2(480, 800), pixelScale: 2.0, systemDark: true) { _, _ in
            col().wFull().p(10.0).child(Markdown("```python\n\(pyCode)\n```\n").selectable(true).build(kit).key("m0"))
        }
        var pt = 0.0
        _ = pyRT.frame(at: pt)
        let pyGlyphs = glyphCenters(pyRT, pathSuffix: "@m0/@b0")
        try #require(pyGlyphs.count > 4, "pyGlyphs=\(pyGlyphs.count) paths=\(pyRT.elements().map(\.path))")
        for _ in 0..<2 {
            pyRT.pointerMove(to: pyGlyphs[1], at: pt)
            pyRT.pointerDown(at: pyGlyphs[1], button: .primary, mods: .none, at: pt)
            pyRT.pointerUp(at: pyGlyphs[1], button: .primary, mods: .none, at: pt)
            pt += 1.0 / 60.0
            _ = pyRT.frame(at: pt)
        }
        #expect(pyRT.selectedText() == "def")
        _ = pyRT.keyDown(KeyEvent(key: .command("a"), mods: Mods(cmd: true)), at: pt)
        _ = pyRT.keyDown(KeyEvent(key: .command("c"), mods: Mods(cmd: true)), at: pt)
        #expect(pyRT.clipboard.text == pyCode)

        // 6. markdown_select: a_drag_selects_from_a_paragraph_into_a_code_block & a_selection_survives_its_message_and_the_next_streaming_in
        struct StreamMsgs: Sendable, Hashable { var msgs: [String] }
        let streamRT = Runtime<StreamMsgs>(
            state: StreamMsgs(msgs: [firstMsg, "Second message"]),
            viewport: Vec2(480, 800),
            pixelScale: 2.0,
            systemDark: true
        ) { s, _ in
            col().wFull().gap(24.0).p(10.0).children(
                s.msgs.enumerated().map { i, m in
                    memo("m\(i)", m) {
                        Markdown(m).selectable(true).build(kit).key("m\(i)")
                    }
                }
            )
        }
        var st = 0.0
        _ = streamRT.frame(at: st)
        let m0Para = glyphCenters(streamRT, pathSuffix: "@m0/@b0")
        let m0Code = glyphCenters(streamRT, pathSuffix: "@m0/@b2")
        try #require(m0Para.count >= 2 && m0Code.count >= 3, "m0Para=\(m0Para.count) m0Code=\(m0Code.count) paths=\(streamRT.elements().map(\.path))")
        streamRT.pointerMove(to: m0Para[1], at: st)
        #expect(streamRT.currentCursor() == .text)
        drag(streamRT, from: Vec2(m0Para[1].x - 3.0, m0Para[1].y), to: Vec2(m0Code[2].x - 3.0, m0Code[2].y), t: &st)
        let m0Dragged = streamRT.selectedText() ?? ""
        #expect(m0Dragged.hasPrefix("ello world and link.") && m0Dragged.contains("alpha") && m0Dragged.contains("beta") && m0Dragged.contains("fn"))
        _ = streamRT.keyDown(KeyEvent(key: .command("c"), mods: Mods(cmd: true)), at: st)
        #expect(streamRT.clipboard.text == m0Dragged)
        _ = streamRT.keyDown(KeyEvent(key: .command("a"), mods: Mods(cmd: true)), at: st)
        #expect(streamRT.selectedText()?.contains("Second message") == false)
        #expect(streamRT.selectedText()?.contains("Hello world and link.") == true)

        // Streaming growth in memo'd messages preserves the active drag selection.
        st += 0.5
        _ = streamRT.frame(at: st)
        let m0Para2 = glyphCenters(streamRT, pathSuffix: "@m0/@b0")
        let m0Alpha = glyphCenters(streamRT, pathSuffix: "@m0/@b1/@i0")
        try #require(m0Para2.count >= 2 && m0Alpha.count >= 3, "m0Para2=\(m0Para2.count) m0Alpha=\(m0Alpha.count) paths=\(streamRT.elements().map(\.path))")
        drag(streamRT, from: Vec2(m0Para2[1].x - 3.0, m0Para2[1].y), to: Vec2(m0Alpha[3].x - 3.0, m0Alpha[3].y), t: &st)
        let beforeStream = streamRT.selectedText()
        #expect(beforeStream == "ello world and link.\n\n- al")
        for chunk in [" streams", " in\n\nand", " on"] {
            streamRT.update(at: st) { s, _ in
                s.msgs[1].append(chunk)
                s.msgs[0].append(chunk)
            }
            st += 1.0 / 60.0
            _ = streamRT.frame(at: st)
            #expect(streamRT.selectedText() == beforeStream)
        }
    }

    // MARK: - 1:1 Rust Parity Additions (`src/markdown/tests.rs`, `markdown_table_card`, `markdown_find`, `markdown_fixture`, `markdown_diagram_*`, `markdown_quote_frame`, `markdown.rs #91`)

    @Test("A nested list renders its fenced code with syntax highlighting")
    func nestedListCodeHighlight() throws {
        let source = """
        - Message

          - Example

            ```rust
            fn callback() {}
            ```
        """
        let root: El<Int> = Markdown(source).build(.neutral(dark: false))
        let code = try #require(collectRichNodes(root).first { $0.plain == "fn callback() {}" })
        #expect(Set(code.spans.compactMap(\.color)).count > 1)
    }

    @Test("src/markdown/tests.rs & blocks_and_highlights: syntax highlights (#1-#6), glyph-invariant TextSystem (#7), whole/stream/ref cache (#9, #11), link span ordering (#12), strike (#115)")
    func markdownCoreParserMetricsAndMaps() {
        // #1: known languages are coloured and others stay plain
        let darkKit = Kit.neutral(dark: true)
        let darkStyle = MarkdownStyle.fromKit(darkKit)
        let langSrc = """
        ```ts
        const a = 1
        ```

        ```brainfuck
        +[-]
        ```

            indented

        ```
        none
        ```

        - ```rust,ignore
          fn f() {}
          ```

        > ```SQL
        > select 1
        > ```
        """
        let langRoot: El<Int> = Markdown(langSrc).render(darkStyle)
        let codeNodes = collectRichNodes(langRoot)
        let tsNode = codeNodes.first(where: { $0.plain == "const a = 1" })
        #expect(tsNode != nil)
        if let tsNode {
            let kwTexts = tsNode.spans.filter { approxColor($0.color, darkStyle.syntax.color(for: .keyword)) }.map(\.text)
            let numTexts = tsNode.spans.filter { approxColor($0.color, darkStyle.syntax.color(for: .number)) }.map(\.text)
            #expect(kwTexts == ["const "])
            #expect(numTexts == ["1"])
            #expect(tsNode.spans.allSatisfy { $0.color != nil && $0.weight == nil && !$0.italic && $0.monospace })
        }
        let plainInk = darkStyle.plainCodeText ?? darkStyle.codeText ?? darkStyle.text
        for plainCode in ["+[-]", "indented", "none"] {
            let node = codeNodes.first(where: { $0.plain == plainCode })
            #expect(node != nil)
            if let node {
                #expect(node.spans.count == 1 && approxColor(node.spans[0].color, plainInk))
            }
        }
        let rustNode = codeNodes.first(where: { $0.plain == "fn f() {}" })
        #expect(rustNode?.spans.filter { approxColor($0.color, darkStyle.syntax.color(for: .function)) }.map(\.text) == ["f"])
        let sqlNode = codeNodes.first(where: { $0.plain == "select 1" })
        #expect(sqlNode?.spans.filter { approxColor($0.color, darkStyle.syntax.color(for: .keyword)) }.map(\.text) == ["select "])

        // #2: a streaming fence colours only its finished lines
        let lightStyle = MarkdownStyle.fromKit(Kit.neutral(dark: false))
        let lightInk = lightStyle.codeText ?? lightStyle.text
        func lastColouredEnd(_ src: String) -> Int {
            let root: El<Int> = Markdown(src).streaming(true).render(lightStyle)
            let nodes = collectRichNodes(root)
            guard let node = nodes.first else { return 0 }
            let coloured = spanRanges(for: node.spans, matching: { !approxColor($0.color, lightInk) })
            return coloured.last?.0.upperBound ?? 0
        }
        #expect(lastColouredEnd("```ts\nconst") == 0)
        #expect(lastColouredEnd("```ts\nconst a = 1\nconst b") == "const a = 1".utf8.count)
        #expect(lastColouredEnd("```ts\nconst a = 1\nconst b = 2\n") == "const a = 1\nconst b = 2".utf8.count)
        #expect(lastColouredEnd("```ts\nconst a = 1\nlet b = 2\n```") == "const a = 1\nlet b = 2".utf8.count)

        // #3: syntax builders override and switch off colour
        let red = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let rustSrc = "```rust\nlet x = 1;\n```"
        let customStyle = darkStyle.syntax(.keyword, red)
        let customRoot: El<Int> = Markdown(rustSrc).render(customStyle)
        let customNode = collectRichNodes(customRoot).first
        #expect(customNode?.spans.filter { approxColor($0.color, red) }.map(\.text) == ["let "])
        let offRoot: El<Int> = Markdown(rustSrc).render(customStyle.syntaxHighlight(false))
        let offNode = collectRichNodes(offRoot).first
        #expect(offNode?.spans.count == 1 && approxColor(offNode?.spans[0].color, darkStyle.codeText ?? darkStyle.text))

        // #4: a custom SyntaxHighlighter receives each fence language (except diff) and applies Kind + Color paints
        final class LangRecorder: @unchecked Sendable {
            private let lock = NSLock()
            var entries: [(String?, String)] = []
            var runs = 0
            func record(_ l: String?, _ c: String) {
                lock.lock()
                entries.append((l, c))
                runs += 1
                lock.unlock()
            }
        }
        let rec4 = LangRecorder()
        let hl4 = SyntaxHighlighter(id: "lang-seen-\(UUID().uuidString)") { lang, code in
            rec4.record(lang, code)
            return [
                SyntaxHighlight(range: 2..<3, paint: .color(red)),
                SyntaxHighlight(range: 0..<1, paint: .kind(.keyword)),
            ]
        }
        let hlSrc = """
        ```Kotlin title="a.kt"
        val x = 1
        ```

        ```
        bare fence
        ```

            indented code

        ```rust,ignore
        fn f() {}
        ```

        ```diff
        +a
        ```
        """
        let hlRoot: El<Int> = Markdown(hlSrc).highlighter(hl4).render(darkStyle)
        #expect(rec4.entries.count == 4)
        if rec4.entries.count == 4 {
            #expect(rec4.entries[0].0 == "Kotlin" && rec4.entries[0].1 == "val x = 1")
            #expect(rec4.entries[1].0 == nil && rec4.entries[1].1 == "bare fence")
            #expect(rec4.entries[2].0 == nil && rec4.entries[2].1 == "indented code")
            #expect(rec4.entries[3].0 == "rust" && rec4.entries[3].1 == "fn f() {}")
        }
        for code in ["val x = 1", "bare fence", "indented code", "fn f() {}"] {
            let n = collectRichNodes(hlRoot).first(where: { $0.plain == code })
            #expect(n != nil)
            if let n {
                let kw = n.spans.filter { approxColor($0.color, darkStyle.syntax.color(for: .keyword)) }.map(\.text)
                let rd = n.spans.filter { approxColor($0.color, red) }.map(\.text)
                #expect(kw == [utf8Slice(code, 0..<1)])
                #expect(rd == [utf8Slice(code, 2..<3)])
            }
        }

        // #5: builtin ts output matches SyntaxTheme colors and disabled highlighter invokes 0 times
        let builtinSrc = "```ts\nconst a = 1;\n```\n\n```\nplain\n```\n\n```cobol\nMOVE 1 TO X\n```"
        let builtinRoot: El<Int> = Markdown(builtinSrc).render(lightStyle)
        let builtinNodes = collectRichNodes(builtinRoot)
        if let tsBuiltin = builtinNodes.first(where: { $0.plain == "const a = 1;" }) {
            let colouredSpans = spanRanges(for: tsBuiltin.spans, matching: { _ in true }).compactMap { pair -> (Int, Int, Color)? in
                guard let c = pair.1.color else { return nil }
                return (pair.0.lowerBound, pair.0.upperBound, c)
            }
            let cKeyword = lightStyle.syntax.color(for: .keyword)
            let cVar = lightStyle.syntax.color(for: .variable)
            let cOp = lightStyle.syntax.color(for: .operator)
            let cNum = lightStyle.syntax.color(for: .number)
            let cPunc = lightStyle.syntax.color(for: .punctuation)
            let wantColors: [(Int, Int, Color)] = [
                (0, 6, cKeyword),
                (6, 8, cVar),
                (8, 10, cOp),
                (10, 11, cNum),
                (11, 12, cPunc),
            ]
            #expect(colouredSpans.count == wantColors.count)
            for (got, want) in zip(colouredSpans, wantColors) {
                #expect(got.0 == want.0 && got.1 == want.1 && approxColor(got.2, want.2))
            }
        } else {
            Issue.record("Missing builtin ts code node")
        }
        let offRec = LangRecorder()
        let offHl = SyntaxHighlighter(id: "off-\(UUID().uuidString)") { lang, code in
            offRec.record(lang, code)
            return []
        }
        let _: El<Int> = Markdown(builtinSrc).highlighter(offHl).render(lightStyle.syntaxHighlight(false))
        #expect(offRec.runs == 0)

        // #6: rebuilding a view runs custom highlighter once per block across 3 commits
        let runRec = LangRecorder()
        let runHl = SyntaxHighlighter(id: "once-\(UUID().uuidString)") { lang, code in
            runRec.record(lang, code)
            return Syntax.builtin(language: lang, code: code)
        }
        let rebuildRT = Runtime<Int>(
            state: 0,
            viewport: Vec2(400, 400),
            view: { _, _ in
                Markdown("```py\nx = 1\n```\n\n```go\nvar y = 2\n```").highlighter(runHl).render(darkStyle)
            }
        )
        _ = rebuildRT.frame(at: 0.01)
        for i in 1...3 {
            rebuildRT.update(at: Double(i) * 0.02) { s, _ in s = i }
            _ = rebuildRT.frame(at: Double(i) * 0.02 + 0.01)
        }
        #expect(runRec.runs == 2)

        // #7: highlighting never moves a glyph across widths [nil, 900, 420, 260] (full & streaming)
        let ts = TextSystem()
        let glyphCases: [(String, String)] = [
            ("tsx", "export function Card({ title }: { title: string }) {\n  return <div className=\"card\">{title.toUpperCase()}</div>; // done\n}"),
            ("rust", "fn main() { let v: Vec<u8> = vec![1, 2, 3]; println!(\"{v:?} → ok\"); }"),
            ("sh", "FOO=1 npm run build --if-present && echo \"$HOME/${X}\" | tee out.txt # café"),
            ("yaml", "name: rune\nlist: [a, 1, {b: c}]\nscript: |\n  echo hi"),
        ]
        for (lang, code) in glyphCases {
            let fullSpans = darkStyle.syntax.spans(for: code, highlights: Syntax.builtin(language: lang, code: code), defaultColor: darkStyle.codeText)
            #expect(!fullSpans.isEmpty)
            let cutRaw = code.firstIndex(of: "\n").map { code.distance(from: code.startIndex, to: $0) + 4 } ?? (code.utf8.count / 2)
            let utf8View = code.utf8
            var cutIdx = utf8View.index(utf8View.startIndex, offsetBy: min(cutRaw, utf8View.count))
            while cutIdx < utf8View.endIndex && cutIdx.samePosition(in: code) == nil {
                cutIdx = utf8View.index(after: cutIdx)
            }
            let partial = String(code[..<cutIdx])
            let streamPrefixLen = partial.lastIndex(of: "\n").map { String(partial[..<$0]).utf8.count } ?? 0
            let streamSlice = utf8Slice(code, 0..<streamPrefixLen)
            let streamSpans = darkStyle.syntax.spans(
                for: streamSlice,
                highlights: Syntax.builtin(language: lang, code: streamSlice),
                defaultColor: darkStyle.codeText
            ) + (streamPrefixLen < code.utf8.count ? [TextSpan(utf8Slice(code, streamPrefixLen..<code.utf8.count), color: darkStyle.codeText, monospace: true)] : [])

            for width in [nil, Float(900), Float(420), Float(260)] as [Float?] {
                let plain = ts.shape(text: code, spans: nil, style: darkStyle.codeBlock, maxWidth: width, pixelScale: 2.0, emitGlyphs: true)
                let full = ts.shape(text: code, spans: fullSpans, style: darkStyle.codeBlock, maxWidth: width, pixelScale: 2.0, emitGlyphs: true)
                let stream = ts.shape(text: code, spans: streamSpans, style: darkStyle.codeBlock, maxWidth: width, pixelScale: 2.0, emitGlyphs: true)
                #expect(plain.glyphs.map { [$0.rect, $0.uv] } == full.glyphs.map { [$0.rect, $0.uv] })
                #expect(plain.glyphs.map { [$0.rect, $0.uv] } == stream.glyphs.map { [$0.rect, $0.uv] })
            }
        }

        // #9: streaming byte-by-byte through MarkdownDocCache matches whole-document parse
        let streamDocs = [
            "# Title\n\nFirst para with **bold** and `code`.\nSetext\n---\n\n- one\n- two\n\n  more of two\n\n- [ ] todo\n- [x] done\n\n1. a\n2. b\n\nAfter the list.\n\n> quoted\n> lines\n\n```rust\nfn main() {}\n```\n\n    indented code\n\n***\n\n| a | b |\n|:-|-:|\n| 1 | 2 |\n\ntail text <span>html</span>\n\n<div>\nblock\n</div>\n\nlast *words*",
            "para one\n\npara two\n```ts\nconst a = 1\n```\n- item\nlazy line\n\n| x | y |\n| - | - |\nend",
            "---\ntitle: Example\n---\n\nPréface\n\n- plain\n  - [ ] nested\n    - [x] deeper\n- [ ] sibling\n\n<div>hidden</div>\n\nAfter\n\n- [x] final task\n\npartial",
        ]
        for docText in streamDocs {
            var idx = docText.startIndex
            while idx < docText.endIndex {
                idx = docText.index(after: idx)
                let prefix = String(docText[..<idx])
                let cached = MarkdownDocCache.shared.docCached(prefix, autolink: true)
                let whole = MarkdownParser.parseDocument(prefix, autolink: true)
                #expect(cached.blocks == whole.blocks)
                #expect(cached.sources == whole.sources)
                #expect(cached.tasks == whole.tasks)
                #expect(cached.blockStarts == whole.blockStarts)
                #expect(cached.maps == whole.maps)
                #expect(cached.cuts == whole.cuts)
            }
        }

        // #11: reference link definitions settle to identical whole-parse blocks
        _ = MarkdownDocCache.shared.docCached("[x]\n\nsome text", autolink: true)
        let refCached = MarkdownDocCache.shared.docCached("[x]\n\nsome text\n\n[x]: https://example.com", autolink: true)
        let refWhole = MarkdownParser.parseDocument("[x]\n\nsome text\n\n[x]: https://example.com", autolink: true)
        #expect(refCached.blocks == refWhole.blocks)

        // #12: link spans keep inner bold/em/code styles intact
        let linkRoot: El<Int> = Markdown("[**bold** *em* `code` plain](session:1)")
            .linkStyle { url in
                url.hasPrefix("session:") ? (.white, false, 500, nil) : nil
            }
            .render(darkStyle)
        if let linkNode = collectRichNodes(linkRoot).first(where: { $0.plain.contains("bold") }) {
            #expect(linkNode.spans.contains(where: { $0.text == "bold" && $0.weight == darkStyle.strongWeight && approxColor($0.color, .white) }))
            #expect(linkNode.spans.contains(where: { $0.text == "em" && $0.italic && approxColor($0.color, .white) }))
            #expect(linkNode.spans.contains(where: { $0.text.trimmingCharacters(in: .whitespaces) == "code" || ($0.monospace && $0.text.contains("code")) }))
            #expect(linkNode.spans.contains(where: { $0.text.contains("plain") && $0.weight == 500 && approxColor($0.color, .white) }))
        } else {
            Issue.record("Expected rich node for link spans test")
        }

        // #115: GFM strikethrough parses to .strike inline span and renders strikethrough TextSpan in light & dark themes
        let strikeDoc = MarkdownParser.parseDocument("A ~~struck~~ word")
        if case .para(let strikeInl) = strikeDoc.blocks.first {
            #expect(strikeInl.spans.contains(where: { $0.style == .strike && utf8Slice(strikeInl.text, $0.start..<$0.end) == "struck" }))
        } else {
            Issue.record("Expected para for strike test")
        }
        for s in [lightStyle, darkStyle] {
            let root: El<Int> = Markdown("A ~~struck~~ word").render(s)
            let node = collectRichNodes(root).first
            #expect(node?.spans.contains(where: { $0.strikethrough && $0.text == "struck" }) == true)
        }
    }

    @Test("tests/markdown.rs: image block exposes zoomIn cursor on hover (#91)")
    func markdownImageZoomInCursor() {
        let kit = Kit.neutral(dark: false)
        let rt = Runtime<String>(
            state: "![Preview diagram](https://example.com/diagram.png)",
            viewport: Vec2(480, 260),
            view: { src, _ in
                kit.markdown(src)
            }
        )
        _ = rt.frame(at: 0.01)
        let imgEl = rt.elements().first(where: {
            $0.role == .image || $0.a11yDescription == "Preview diagram"
        })
        #expect(imgEl != nil)
        if let r = imgEl?.rect, r.count == 4 {
            rt.pointerMove(to: Vec2(r[0] + r[2] * 0.5, r[1] + r[3] * 0.5), at: 0.02)
            _ = rt.frame(at: 0.03)
            #expect(rt.currentCursor() == .zoomIn)
        }
    }

    @Test("tests/markdown_table_card.rs: card body inset (#93), preset (#94), pad (#95), fullWidth/scrollWide (#96-#97), margin (#98), defaults (#99-#103), copy (#104), frame order (#105), setters (#106-#108)")
    @MainActor
    func markdownTableCardParity() {
        let kit = Kit.neutral(dark: false)
        let cardStyle = MarkdownStyle.fromKit(kit).tableCard(kit)
        let plainStyle = MarkdownStyle.fromKit(kit)
        let mdTable = """
        | Metric | Value | Note |
        | :--- | ---: | :--- |
        | Latency | 12 | Fast |
        | Throughput | 900 | High |
        """

        // #93: card preset sets faint header text, body text, header/body padding (8 / 10 + 0.5 border), 12pt cell inset, aligned columns
        let presetSrc = """
        | East | West |
        | --- | --- |
        | North | Lettuce ×2 |
        """
        let presetRT = Runtime<String>(
            state: presetSrc,
            viewport: Vec2(600, 320),
            view: { src, _ in Markdown(src).view(for: String.self).render(cardStyle) }
        )
        _ = presetRT.frame(at: 0.01)
        if let th = presetRT.element(byKey: "th"),
           let r0 = presetRT.element(byKey: "r0"),
           let thC1 = tableCell(presetRT, rowKey: "th", col: 1),
           let r0C0 = tableCell(presetRT, rowKey: "r0", col: 0),
           let r0C1 = tableCell(presetRT, rowKey: "r0", col: 1),
           let west = textInSubtree(presetRT, under: thC1, matching: "West"),
           let north = textInSubtree(presetRT, under: r0C0, matching: "North"),
           let lettuce = textInSubtree(presetRT, under: r0C1, matching: "Lettuce ×2") {
            #expect(approxColor(west.textColor, kit.c.textFaint))
            #expect(approxColor(north.textColor, kit.c.textBase))
            #expect(abs(th.rect[3] - (west.rect[3] + 16.0)) < 0.5)
            #expect(abs(west.rect[0] - thC1.rect[0] - 12.0) < 0.5)
            #expect(abs(north.rect[0] - r0C0.rect[0] - 12.0) < 0.5)
            #expect(abs(lettuce.rect[0] - west.rect[0]) < 0.5)
            #expect(r0.rect[3] >= north.rect[3] + 20.0 - 0.5)
        } else {
            Issue.record("Missing table cells in card preset check (#93)")
        }

        // #94: header padding can differ from body cells (.tableHeaderPad(x: 20, y: 9) vs .tableCellPadding(x: 6, y: 4))
        let diffPadStyle = MarkdownStyle.fromKit(kit).tableCellPadding(x: 6, y: 4).tableHeaderPad(x: 20, y: 9)
        let diffPadRT = Runtime<String>(
            state: "| Head | B |\n| --- | --- |\n| x | y |",
            viewport: Vec2(600, 220),
            view: { src, _ in Markdown(src).view(for: String.self).render(diffPadStyle) }
        )
        _ = diffPadRT.frame(at: 0.01)
        if let th = diffPadRT.element(byKey: "th"),
           let r0 = diffPadRT.element(byKey: "r0"),
           let thC0 = tableCell(diffPadRT, rowKey: "th", col: 0),
           let r0C0 = tableCell(diffPadRT, rowKey: "r0", col: 0),
           let headText = textInSubtree(diffPadRT, under: thC0, matching: "Head"),
           let xText = textInSubtree(diffPadRT, under: r0C0, matching: "x") {
            #expect(abs((headText.rect[0] - thC0.rect[0]) - 20.0) < 0.5)
            #expect(abs((xText.rect[0] - r0C0.rect[0]) - 6.0) < 0.5)
            #expect(abs((th.rect[3] - headText.rect[3]) - 18.0) < 0.5)
            #expect(abs((r0.rect[3] - xText.rect[3]) - 8.0) < 0.5)
        } else {
            Issue.record("Missing table cells in header/cell differential padding check (#94)")
        }

        // #93-#95, #101: card mounts body container "tb", header-alone draws no "tb"
        let cardRT = Runtime<String>(
            state: mdTable,
            viewport: Vec2(620, 320),
            view: { src, _ in
                Markdown(src).view(for: String.self).render(cardStyle)
            }
        )
        _ = cardRT.frame(at: 0.01)
        let tb = cardRT.element(byKey: "tb")
        let th = cardRT.element(byKey: "th")
        let r0 = cardRT.element(byKey: "r0")
        let r1 = cardRT.element(byKey: "r1")
        #expect(tb != nil && th != nil && r0 != nil && r1 != nil)
        if let tb, let th {
            #expect(tb.rect[1] >= th.rect[1] + th.rect[3] - 0.5)
            #expect(tb.rect[2] > 500) // tableFullWidth fills width
            if let frame = elementParent(cardRT, of: th) {
                #expect(abs((th.rect[0] - frame.rect[0]) - 2.0) < 0.5)
            }
        }

        // #101: header-alone draws no card "tb"
        let headOnlyRT = Runtime<String>(
            state: "| Only | Head |\n| --- | --- |",
            viewport: Vec2(480, 160),
            view: { src, _ in Markdown(src).view(for: String.self).render(cardStyle) }
        )
        _ = headOnlyRT.frame(at: 0.01)
        #expect(headOnlyRT.element(byKey: "th") != nil)
        #expect(headOnlyRT.element(byKey: "tb") == nil)

        // #98 & #99 & #102: default outlined table has radius 6, transparent frame fill, layer01 th fill, 0.5 inset; custom tableFrame fills & pads without "tb"
        let defRT = Runtime<String>(
            state: mdTable,
            viewport: Vec2(600, 260),
            view: { src, _ in Markdown(src).streaming(true).view(for: String.self).render(plainStyle) }
        )
        _ = defRT.frame(at: 0.01)
        #expect(defRT.element(byKey: "tb") == nil)
        #expect(defRT.element(byKey: "s0") != nil)
        if let defTh = defRT.element(byKey: "th"), let defFrame = elementParent(defRT, of: defTh) {
            #expect(abs(defFrame.radius - 6.0) < 0.01)
            #expect(approxColor(defFrame.fill, .transparent))
            #expect(approxColor(defTh.fill, kit.c.layer01))
            #expect(abs((defTh.rect[0] - defFrame.rect[0]) - 0.5) < 0.25)
            #expect(defFrame.rect[2] < 600.0)
        }

        let framedStyle = MarkdownStyle.fromKit(kit).tableFrame(fill: kit.c.layer02, ring: kit.c.borderBase, pad: 3.0)
        let framedRT = Runtime<String>(
            state: mdTable,
            viewport: Vec2(600, 260),
            view: { src, _ in Markdown(src).view(for: String.self).render(framedStyle) }
        )
        _ = framedRT.frame(at: 0.01)
        #expect(framedRT.element(byKey: "tb") == nil && framedRT.element(byKey: "s0") != nil)
        if let fTh = framedRT.element(byKey: "th"), let fFrame = elementParent(framedRT, of: fTh) {
            #expect(abs(fFrame.radius - 6.0) < 0.01)
            #expect(approxColor(fFrame.fill, kit.c.layer02))
            #expect(abs((fTh.rect[0] - fFrame.rect[0]) - 3.0) < 0.25)
        }

        // #97: scrollWide embeds table inside "scroll" viewport for wide tables
        let wideTable = """
        | ColumnOneVeryLongHeaderName | ColumnTwoVeryLongHeaderName | ColumnThreeVeryLongHeaderName | ColumnFourVeryLongHeaderName |
        | --- | --- | --- | --- |
        | alpha_long_value_1234567890 | beta_long_value_1234567890 | gamma_long_value_1234567890 | delta_long_value_1234567890 |
        """
        let wideRT = Runtime<String>(
            state: wideTable,
            viewport: Vec2(280, 220),
            view: { src, _ in Markdown(src).scrollWide().view(for: String.self).render(cardStyle) }
        )
        _ = wideRT.frame(at: 0.01)
        #expect(wideRT.element(byKey: "scroll") != nil)

        // #105: later of tableOutline and tableFrame replaces the prior frame in both style & Runtime geometry
        let outlineAfterFrame = cardStyle.tableOutline(kit.c.borderStrong)
        #expect(outlineAfterFrame.tableFrame == nil)
        #expect(outlineAfterFrame.tableOutline == kit.c.borderStrong)
        let outlineRT = Runtime<String>(
            state: mdTable,
            viewport: Vec2(600, 260),
            view: { src, _ in Markdown(src).view(for: String.self).render(outlineAfterFrame) }
        )
        _ = outlineRT.frame(at: 0.01)
        if let thEl = outlineRT.element(byKey: "th"), let frame = elementParent(outlineRT, of: thEl) {
            #expect(abs((thEl.rect[0] - frame.rect[0]) - 0.5) < 0.25)
        }
        let frameAfterOutline = outlineAfterFrame.tableFrame(fill: kit.c.layer02, ring: kit.c.borderBase, pad: 4.0)
        #expect(frameAfterOutline.tableFrame?.pad == 4.0)
        #expect(frameAfterOutline.tableOutline == nil)
        let reFramedRT = Runtime<String>(
            state: mdTable,
            viewport: Vec2(600, 260),
            view: { src, _ in Markdown(src).view(for: String.self).render(frameAfterOutline) }
        )
        _ = reFramedRT.frame(at: 0.01)
        if let lTh = reFramedRT.element(byKey: "th"), let lFrame = elementParent(reFramedRT, of: lTh) {
            #expect(abs((lTh.rect[0] - lFrame.rect[0]) - 4.0) < 0.25)
        }

        // #98 (tableMargin): tableMargin separates table from surrounding prose
        let proseAndTable = "Intro\n\n\(mdTable)\n\nOutro"
        let tightRT = Runtime<String>(
            state: proseAndTable,
            viewport: Vec2(500, 420),
            view: { src, _ in Markdown(src).view(for: String.self).render(plainStyle.tableMargin(top: 2, bottom: 2)) }
        )
        let spacedRT = Runtime<String>(
            state: proseAndTable,
            viewport: Vec2(500, 420),
            view: { src, _ in Markdown(src).view(for: String.self).render(plainStyle.tableMargin(top: 40, bottom: 44)) }
        )
        _ = tightRT.frame(at: 0.01)
        _ = spacedRT.frame(at: 0.01)
        if let thTight = tightRT.element(byKey: "th"), let thSpaced = spacedRT.element(byKey: "th") {
            #expect(thSpaced.rect[1] - thTight.rect[1] >= 20)
        }

        // #104: copy from rendered document includes table markdown/text
        #expect(Markdown(mdTable).plainText().contains("Latency"))

        let wild = MarkdownStyle.fromKit(kit)
            .tableFrame(fill: kit.c.layer01, ring: kit.c.borderMuted, pad: .nan)
            .tableBody(fill: kit.c.bgBase, radius: .infinity, shadows: [])
            .tableHeaderPad(x: -5, y: .nan)
            .tableCellPadding(x: .infinity, y: -1)
            .tableMargin(top: .nan, bottom: -.infinity)
        #expect(wild.tableFrame?.pad == 0)
        #expect(wild.tableBody?.radius == 0)
        #expect(wild.tableHeadPad == [0, 0])
        #expect(wild.tablePad == [0, 0])
        #expect(wild.tableMargin == [0, 0])
    }

    @Test("tests/markdown_find.rs: 1MB doc (#131), 200k matches (#132), mid-scalar UTF-8 safety (#133), 100k fragmented match (#135)")
    func markdownFindScaleAndBoundaryParity() {
        // #131: one megabyte document searches linearly (ignoring link URL `/needle`)
        let section =
            "## Section Heading\n\n" +
            "Paragraph with **bold words**, *italic text*, `inline_code`, and [a link](https://example.org/ignored/needle).\n" +
            "Continuation line after a soft break with İstanbul and Straße.\n\n" +
            "- first list item\n" +
            "- [x] second **needle** item\n\n" +
            "```rust\nfn work(x: i32) -> i32 { x + 1 }\n```\n\n"
        let repeats = (1_048_576 / section.utf8.count) + 1
        let bigDoc = String(repeating: section, count: repeats)
        #expect(bigDoc.utf8.count >= 1_048_576)

        let hits = Markdown(bigDoc).findRanges("second needle item", caseSensitivity: .insensitive)
        #expect(hits.count == repeats)
        #expect(sliceMatches(bigDoc, Array(hits.prefix(1))) == [["second ", "needle", " item"]])
        #expect(sliceMatches(bigDoc, Array(hits.suffix(1))) == [["second ", "needle", " item"]])
        let sensitive = Markdown(bigDoc).findRanges("Continuation line", caseSensitivity: .sensitive)
        #expect(sensitive.count == repeats)

        // #132: frequent matches in single segment (200,000 occurrences)
        let n132 = 200_000
        let manySrc = String(repeating: "a", count: n132)
        let manyHits = Markdown(manySrc).findRanges("a", caseSensitivity: .sensitive)
        #expect(manyHits.count == n132)
        #expect(manyHits.first == [0..<1])
        #expect(manyHits.last == [(n132 - 1)..<n132])

        // #133: rejected Unicode mid-char candidates (İ vs "i\u{307}" + trailing ASCII 'i')
        let n133 = 200_000
        let k133 = 2_000
        var uniSrc = String(repeating: "\u{0130}", count: n133)
        let uniQuery = String(repeating: "i\u{0307}", count: k133) + "i"
        #expect(Markdown(uniSrc).findRanges(uniQuery, caseSensitivity: .insensitive).isEmpty)
        uniSrc.append("i")
        let uniHits = Markdown(uniSrc).findRanges(uniQuery, caseSensitivity: .insensitive)
        let expectedStart = (n133 - k133) * "\u{0130}".utf8.count
        #expect(uniHits == [[expectedStart..<uniSrc.utf8.count]])

        // #135: 100k bold tokens -> 199,999 source ranges in 1 match + 500 fragmented highlight render
        let n135 = 100_000
        let fragSrc = String(repeating: "**a** ", count: n135)
        let fragQuery = String(repeating: "a ", count: n135).trimmingCharacters(in: .whitespaces)
        let fragHits = Markdown(fragSrc).findRanges(fragQuery, caseSensitivity: .sensitive)
        #expect(fragHits.count == 1)
        #expect(fragHits[0].count == 2 * n135 - 1)
        let _: El<Int> = Markdown(fragSrc).highlights([(ranges: fragHits[0], style: .match())]).render(MarkdownStyle.neutral(dark: true))

        let smallN = 500
        let smallSrc = String(repeating: "**a** ", count: smallN)
        let smallExpected = String(repeating: "a ", count: smallN).trimmingCharacters(in: .whitespaces)
        let smallHits = Markdown(smallSrc).findRanges(smallExpected, caseSensitivity: .sensitive)
        #expect(smallHits.count == 1)
        let kit = Kit.neutral(dark: true)
        let smallRT = Runtime<Int>(
            state: 0,
            viewport: Vec2(600, 200),
            view: { _, _ in
                Markdown(smallSrc)
                    .highlights(smallHits.map { ($0, .match()) })
                    .build(kit)
            }
        )
        _ = smallRT.frame(at: 0.01)
        let renderedText = smallRT.elements().compactMap(\.text).joined()
        #expect(renderedText.contains("a a a"))
    }

    @Test("tests/markdown_fixture.rs: parsed_blocks_and_highlights fixture snapshot (#144)")
    func markdownFixtureParsedBlocksAndHighlights() {
        let fixture = """
        # Session Summary

        Paragraph with **bold**, *italic*, `inline`, and [link](https://rune.dev).

        - [x] Completed step
        - [ ] Pending step

        > Quoted note

        ```swift
        func greet(_ name: String) -> String { "Hi \\(name)" }
        ```

        | Col A | Col B |
        | --- | ---: |
        | 1 | 2 |

        ```mermaid
        flowchart LR
          A --> B
        ```
        """
        let doc = MarkdownParser.parseDocument(fixture)
        #expect(doc.blocks.count >= 6)
        let swiftHighlights = Syntax.builtin(language: "swift", code: #"func greet(_ name: String) -> String { "Hi \(name)" }"#)
        #expect(!swiftHighlights.isEmpty)
        #expect(MarkdownFind.findBounds(in: fixture, doc: doc, query: "link").count == 1)
    }

    @MainActor
    @Test("tests/markdown_diagram_stream.rs, markdown_diagram_frame.rs, markdown_quote_frame.rs (#158-#161, #168-#171)")
    func markdownDiagramAndQuoteFrameParity() {
        let kit = Kit.neutral(dark: true)
        let collector = LockedCollector()

        // #158: open mermaid fence draws complete lines (`n:A`, `n:B`, incremental `n:C`), unsupported kanban streams as `"source"`
        if case .mermaid = MarkdownParser.parseAST("```mermaid\ngraph TD\nA-->B").first {
        } else {
            Issue.record("Expected open mermaid fence to parse as .mermaid")
        }
        let openRT = Runtime<String>(
            state: "```",
            viewport: Vec2(600, 800),
            view: { src, _ in col().wFull().child(Markdown(src).streaming(true).render(MarkdownStyle.neutral(dark: true))) }
        )
        var ot = 0.0
        _ = openRT.frame(at: ot)
        for more in ["mer", "maid\n", "graph T", "D\n  A[Start] --> B[Ch", "eck]\n"] {
            let b0h = openRT.element(byKey: "b0")?.rect[3] ?? 0
            #expect(b0h == 0)
            openRT.update(at: ot) { s, _ in s.append(more) }
            ot += 1.0 / 60.0
            _ = openRT.frame(at: ot)
        }
        #expect(openRT.element(byKey: "n:A") != nil)
        #expect(openRT.element(byKey: "n:B") != nil)
        #expect(openRT.element(byKey: "source") == nil)
        openRT.update(at: ot) { s, _ in s.append("  B --> C[Do") }
        ot += 1.0 / 60.0
        _ = openRT.frame(at: ot)
        #expect(openRT.element(byKey: "n:C") == nil)
        openRT.update(at: ot) { s, _ in s.append("ne]\n") }
        ot += 1.0 / 60.0
        _ = openRT.frame(at: ot)
        #expect(openRT.element(byKey: "n:C") != nil)

        let kanbanRT = Runtime<String>(
            state: "```mermaid\nkanban\n  Todo\n",
            viewport: Vec2(600, 800),
            view: { src, _ in col().wFull().child(Markdown(src).streaming(true).render(MarkdownStyle.neutral(dark: true))) }
        )
        _ = kanbanRT.frame(at: 0.0)
        #expect(kanbanRT.element(byKey: "source") != nil)

        // #159: closing open fence settles to same node layout as finished diagram without opacity fade
        let bodyLR = "```mermaid\ngraph LR\n  A[Start] --> B{Ready?}\n  B -->|yes| C[Ship]\n  B -->|no| D[Fix]\n  D --> B\n"
        let closedLR = bodyLR + "```\n"
        let settleRT = Runtime<(String, Bool)>(
            state: (bodyLR, true),
            viewport: Vec2(600, 800),
            view: { s, _ in col().wFull().child(Markdown(s.0).streaming(s.1).render(MarkdownStyle.neutral(dark: true))) }
        )
        var st = 0.0
        _ = settleRT.frame(at: st)
        for _ in 0..<120 { st += 1.0 / 60.0; _ = settleRT.frame(at: st) }
        func diagramPieces(_ rt: Runtime<(String, Bool)>) -> [ElementInfo] {
            rt.elements().filter { e in
                let k = e.key ?? ""
                return (k.hasPrefix("n:") || k.hasPrefix("e:")) && !e.exiting
            }
        }
        let beforePieces = diagramPieces(settleRT)
        #expect(beforePieces.count > 8)
        settleRT.update(at: st) { s, _ in s = (closedLR, true) }
        st += 1.0 / 60.0
        _ = settleRT.frame(at: st)
        let firstPieces = diagramPieces(settleRT)
        for _ in 0..<120 { st += 1.0 / 60.0; _ = settleRT.frame(at: st) }
        let afterPieces = diagramPieces(settleRT)

        let freshRT = Runtime<(String, Bool)>(
            state: (closedLR, true),
            viewport: Vec2(600, 800),
            view: { s, _ in col().wFull().child(Markdown(s.0).streaming(s.1).render(MarkdownStyle.neutral(dark: true))) }
        )
        _ = freshRT.frame(at: 0.0)
        for i in 1...120 { _ = freshRT.frame(at: Double(i) / 60.0) }
        let wantPieces = diagramPieces(freshRT)
        #expect(beforePieces.count == wantPieces.count && firstPieces.count == wantPieces.count && afterPieces.count == wantPieces.count)
        for (i, want) in wantPieces.enumerated() where i < beforePieces.count && i < firstPieces.count && i < afterPieces.count {
            #expect(beforePieces[i].opacity == 1 && firstPieces[i].opacity == 1)
            for axis in 0..<4 {
                #expect(abs(afterPieces[i].rect[axis] - want.rect[axis]) < 0.5)
            }
        }

        // #160: finished diagram shows whole at opacity 1 & scale 1 the frame it mounts
        let seqRT = Runtime<String>(
            state: "",
            viewport: Vec2(600, 800),
            view: { s, _ in col().wFull().child(Markdown(s).render(MarkdownStyle.neutral(dark: true))) }
        )
        _ = seqRT.frame(at: 0.0)
        seqRT.update(at: 0.01) { s, _ in
            s = "Before\n\n```mermaid\nsequenceDiagram\n  A->>B: hi\n  B-->>A: hello\n```\n"
        }
        _ = seqRT.frame(at: 1.0 / 60.0)
        let shownSeq = seqRT.elements().filter { e in
            let k = e.key ?? ""
            return !k.isEmpty && !k.hasPrefix("b") && !e.exiting
        }
        #expect(shownSeq.count > 4)
        #expect(shownSeq.allSatisfy { $0.opacity == 1.0 && $0.scale == 1.0 })

        // #161: fitting & settling a streamed diagram never bloats `"fit"` width
        let streamLines = [
            "```mermaid\n",
            "flowchart LR\n",
            "  Drop[Socket drops] --> R1[Retry at once]\n",
            "  R1 -->|ok| On[Online]\n",
            "  R1 -->|fails| R2[Back off 1 s]\n",
            "  R2 -->|ok| On\n",
            "  R2 -->|fails| Off[Offline]\n",
            "  Off -->|retry| R2\n",
        ]
        let fitRT = Runtime<String>(
            state: "",
            viewport: Vec2(768, 800),
            view: { s, _ in col().wFull().child(Markdown(s).streaming(true).render(MarkdownStyle.neutral(dark: true))) }
        )
        var ft = 0.0
        _ = fitRT.frame(at: ft)
        for line in streamLines {
            fitRT.update(at: ft) { s, _ in s.append(line) }
            for _ in 0..<20 { ft += 1.0 / 120.0; _ = fitRT.frame(at: ft) }
        }
        for _ in 0..<120 { ft += 1.0 / 120.0; _ = fitRT.frame(at: ft) }
        let beforeFitW = fitRT.element(byKey: "fit")?.rect[2] ?? 0
        #expect(beforeFitW > 0)
        fitRT.update(at: ft) { s, _ in s.append("```\n") }
        var widths: [Float] = []
        for _ in 0..<120 {
            ft += 1.0 / 120.0
            _ = fitRT.frame(at: ft)
            if let w = fitRT.element(byKey: "fit")?.rect[2] {
                widths.append(w)
            }
        }
        let endFitW = widths.last ?? beforeFitW
        let peakFitW = widths.reduce(beforeFitW, max)
        #expect(peakFitW <= max(beforeFitW, endFitW) + 0.5)

        // #168: diagramFrame counts non-mermaid code fences in index, omits unsupported kanban, mounts card + open child inside frame-1 & frame-2
        let twoDoc = """
        Code first:

        ```rust
        fn main() {}
        ```

        ```mermaid
        graph LR
          A --> B
        ```

        Then a second:

        ```mermaid
        sequenceDiagram
          A->>B: hi
        ```

        ```mermaid
        kanban
          Todo
        ```
        """
        let frameRT = Runtime<String>(
            state: twoDoc,
            viewport: Vec2(600, 900),
            view: { src, _ in
                col().wFull().child(
                    Markdown(src)
                        .diagramFrame { (card: El<String>, d: MarkdownDiagramFrameContext) -> El<String> in
                            collector.addDiagram(d)
                            return col().key("frame-\(d.index)").child(card).child(el().key("open").size(20, 20))
                        }
                        .render(MarkdownStyle.neutral(dark: true))
                )
            }
        )
        _ = frameRT.frame(at: 0.01)
        let diagSeen = collector.snapshot().diagrams
        #expect(diagSeen.first?.index == 1 && diagSeen.first?.open == false)
        #expect(diagSeen.contains(where: { $0.index == 2 && $0.source.hasPrefix("sequenceDiagram") }))
        #expect(!diagSeen.contains(where: { $0.source.contains("kanban") }))
        for idx in [1, 2] {
            let f = frameRT.element(byKey: "frame-\(idx)")
            #expect(f != nil)
            if let f {
                #expect(frameRT.elements().contains(where: { $0.key == "card" && $0.path.hasPrefix(f.path + "/") }))
                #expect(frameRT.elements().contains(where: { $0.key == "open" && $0.path.hasPrefix(f.path + "/") }))
            }
        }

        // #169: diagramTypography(..., minScale: 0) shrinks wide diagram to fit card width
        let wideSeq = """
        ```mermaid
        sequenceDiagram
          participant B as Browser on a laptop
          participant E as Edge cache in front
          participant A as Auth service cluster
          participant P as Payments API server
          participant W as Billing worker pool
          participant S as Search index shard
          B->>E: a request arrives at the edge
          E->>A: is this session token still valid?
          P->>W: enqueue the invoice with the scope
          W->>S: index the invoice
        ```
        """
        func runWideDiagram(minScale: Float?) -> (card: [Float], diagram: [Float]) {
            let base = MarkdownStyle.neutral(dark: true)
            let style = if let minScale {
                base.diagramTypography(font: base.diagram.font, maxWidth: 420, minScale: minScale)
            } else {
                base.diagramTypography(font: base.diagram.font, maxWidth: 420, minScale: base.diagram.minScale)
            }
            let r = Runtime<Int>(
                state: 0,
                viewport: Vec2(600, 900),
                view: { _, _ in col().w(420).child(Markdown(wideSeq).render(style)) }
            )
            _ = r.frame(at: 0.0)
            return (r.element(byKey: "card")?.rect ?? [], r.element(byKey: "diagram")?.rect ?? [])
        }
        let wideDefault = runWideDiagram(minScale: nil)
        let wideZeroMin = runWideDiagram(minScale: 0.0)
        #expect(wideDefault.diagram.count == 4 && wideDefault.card.count == 4)
        #expect(wideDefault.diagram[2] > wideDefault.card[2])
        #expect(wideZeroMin.diagram.count == 4 && wideZeroMin.card.count == 4)
        #expect(wideZeroMin.diagram[0] >= wideZeroMin.card[0] && wideZeroMin.diagram[0] + wideZeroMin.diagram[2] <= wideZeroMin.card[0] + wideZeroMin.card[2] + 0.5)

        // #170-#171: exact quoteFrame plain text on rich & nested quotes
        func collectQuotes(_ src: String) -> [String] {
            let qc = LockedCollector()
            _ = col().child(
                Markdown(src)
                    .quoteFrame { (qEl: El<Int>, q: MarkdownQuoteFrameContext) -> El<Int> in
                        qc.addQuote(q)
                        return qEl
                    }
                    .build(kit)
            )
            return qc.snapshot().quotes
        }
        let richQuote = "Before.\n\n> First `para` here.\n>\n> Second para.\n>\n> - one\n> - [x] two\n>   - nested\n> 3. third\n>\n> ```\n> let a = 1;\n> ```\n\nAfter.\n"
        #expect(collectQuotes(richQuote) == ["First para here.\n\nSecond para.\n\n- one\n- [x] two\n  - nested\n\n3. third\n\nlet a = 1;"])
        #expect(collectQuotes("> outer\n>\n> > inner\n") == ["inner", "outer\n\ninner"])
    }
}

private final class LockedCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [MarkdownCodeFrameContext] = []
    private var diagrams: [MarkdownDiagramFrameContext] = []
    private var quotes: [String] = []
    private var images: [MarkdownImageFrameContext] = []

    func addCode(_ c: MarkdownCodeFrameContext) { lock.lock(); codes.append(c); lock.unlock() }
    func addDiagram(_ c: MarkdownDiagramFrameContext) { lock.lock(); diagrams.append(c); lock.unlock() }
    func addQuote(_ q: MarkdownQuoteFrameContext) { lock.lock(); quotes.append(q.text); lock.unlock() }
    func addImage(_ i: MarkdownImageFrameContext) { lock.lock(); images.append(i); lock.unlock() }

    func snapshot() -> (codes: [MarkdownCodeFrameContext], diagrams: [MarkdownDiagramFrameContext], quotes: [String], images: [MarkdownImageFrameContext]) {
        lock.lock()
        defer { lock.unlock() }
        return (codes, diagrams, quotes, images)
    }
}
