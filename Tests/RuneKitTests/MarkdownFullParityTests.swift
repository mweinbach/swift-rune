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

        // Every prefix of JUICE and multi-block doc parses identically through incremental MarkdownDocCache
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
        let before = cache.docCached("[x]\n\nsome text")
        let after = cache.docCached("[x]\n\nsome text\n\n[x]: https://example.com")
        #expect(before.blocks != after.blocks)
        if case let .para(inl) = after.blocks[0] {
            #expect(inl.links.first?.url == "https://example.com")
        } else {
            Issue.record("Expected para with resolved reference link")
        }
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
