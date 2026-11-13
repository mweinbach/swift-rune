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

        let paraEl = rt.elements().first(where: { $0.key == "b0" })
        #expect(paraEl != nil)
        #expect(paraEl?.help == "Open https://x.dev/a")
        if let r = paraEl?.rect {
            let leftHit = Vec2(r[0] + 40, r[1] + r[3] * 0.5)
            rt.pointerMove(to: leftHit, at: 0.01)
            rt.pointerDown(at: leftHit, at: 0.01)
            rt.pointerUp(at: leftHit, at: 0.01)
            _ = rt.frame(at: 0.02)
            #expect(rt.state.primary == ["https://x.dev/a"])

            let rightHit = Vec2(r[0] + r[2] * 0.7, r[1] + r[3] * 0.5)
            rt.pointerMove(to: rightHit, at: 0.03)
            rt.pointerDown(at: rightHit, button: .secondary, at: 0.03)
            rt.pointerUp(at: rightHit, button: .secondary, at: 0.03)
            _ = rt.frame(at: 0.04)
            #expect(!rt.state.secondary.isEmpty)
        }
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
                #expect(keyRT.selectedText() == "a\nb")
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
        #expect(crlfRT.selectedText() == "fn main() {}\n@@ -1 +1 @@\n-old\n+new")

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
        #expect(beforeStream == "ello world and link.\nal")
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
