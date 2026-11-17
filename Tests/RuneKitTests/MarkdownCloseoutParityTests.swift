import Foundation
import Testing
@testable import Rune
@testable import RuneKit

@Suite("RuneKit Content Closeout Parity Tests (All Remaining S2/S3 Cases)")
struct MarkdownCloseoutParityTests {
    @Test("An outside list disc uses a whole device pixel box inside the reserved marker column")
    @MainActor
    func outsideListDiscTracksScale() throws {
        let style = MarkdownStyle.fromKit(Kit.neutral(dark: false)).listMarkersOutside(true)
        let rt = Runtime(state: 0, viewport: Vec2(280, 120)) { _, _ in
            Markdown("- words").render(style)
        }
        var rightInsets: [Float] = []
        for scale: Float in [1, 2] {
            rt.setViewport(Vec2(280, 120), pixelScale: scale)
            _ = rt.frame(at: Double(scale))
            let node = try #require(rt.flatNodes.first { $0.el.outsideListDiscFont != nil })
            let parent = rt.flatNodes[try #require(node.parentIndex)]
            let r = node.targetRect
            #expect(r.width > 0 && r.width == r.height)
            #expect(abs(r.width * scale - (r.width * scale).rounded()) < 0.001)
            #expect(abs(parent.targetRect.width - style.listIndent) < 0.001)
            rightInsets.append(parent.targetRect.x + parent.targetRect.width - r.x - r.width)
        }
        // The extra seven device pixels of end inset occupy fewer points at Retina scale.
        #expect(rightInsets[0] > rightInsets[1] + 2)
    }

    private static func glyphCenters<S>(_ rt: Runtime<S>, in rect: [Float]) -> [Vec2] {
        guard rect.count == 4 else { return [] }
        let scene = rt.frame(at: rt.currentTime)
        let scale = max(rt.pixelScale, 1.0)
        var out: [Vec2] = scene.primitives.compactMap { p -> Vec2? in
            guard p.kind == .glyph else { return nil }
            let cx = (p.rect.x + p.rect.z * 0.5) / scale
            let cy = (p.rect.y + p.rect.w * 0.5) / scale
            guard cx >= rect[0] && cx <= rect[0] + rect[2]
                    && cy >= rect[1] && cy <= rect[1] + rect[3] else {
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

    private static func glyphXs<S>(_ rt: Runtime<S>, in rect: [Float]) -> [(x: Float, y: Float)] {
        guard rect.count == 4 else { return [] }
        let scene = rt.frame(at: rt.currentTime)
        let scale = max(rt.pixelScale, 1.0)
        var out: [(x: Float, y: Float)] = scene.primitives.compactMap { p -> (Float, Float)? in
            guard p.kind == .glyph else { return nil }
            let gx = p.rect.x / scale
            let gy = p.rect.y / scale
            let cx = (p.rect.x + p.rect.z * 0.5) / scale
            let cy = (p.rect.y + p.rect.w * 0.5) / scale
            guard cx >= rect[0] && cx <= rect[0] + rect[2]
                    && cy >= rect[1] && cy <= rect[1] + rect[3] else {
                return nil
            }
            return (gx, gy)
        }
        out.sort { $0.y < $1.y }
        var clustered: [(x: Float, y: Float)] = []
        clustered.reserveCapacity(out.count)
        var i = 0
        while i < out.count {
            let anchorY = out[i].y
            var j = i + 1
            while j < out.count && abs(out[j].y - anchorY) <= 8.0 {
                j += 1
            }
            clustered.append(contentsOf: out[i..<j].sorted { $0.x < $1.x })
            i = j
        }
        return clustered
    }

    private static func glyphCenters<S>(_ rt: Runtime<S>, pathContains needle: String) -> [Vec2] {
        guard let target = rt.elements().first(where: { $0.path.contains(needle) }) else { return [] }
        return glyphCenters(rt, in: target.rect)
    }

    private static func glyphXs<S>(_ rt: Runtime<S>, pathContains needle: String) -> [(x: Float, y: Float)] {
        guard let target = rt.elements().first(where: { $0.path.contains(needle) }) else { return [] }
        return glyphXs(rt, in: target.rect)
    }

    private static func drag<S>(_ rt: Runtime<S>, from: Vec2, to: Vec2, t: inout Double) {
        rt.pointerMove(to: from, at: t)
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        rt.pointerDown(at: from, at: t)
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        rt.pointerMove(to: to, at: t)
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        rt.pointerUp(at: to, at: t)
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
    }

    // MARK: - Cache & LinkHelp (src/markdown/tests.rs #8, #10, #13, #14)

    @MainActor
    @Test("src/markdown/tests.rs: doc cache parses 40 docs once (#8), drops grown stream prefixes (#10), incremental reuse (#13), and multi-link tooltips (#14)")
    func cacheAndMultiLinkHelpParity() {
        // #8: 40 documents parsed once each cleanly on shared cache
        let cache = MarkdownDocCache(capacity: 64, budgetBytes: 1 << 20)
        let docs = (0..<40).map { "# Heading \($0)\n\nParagraph number \($0) with **bold** and `code`." }
        for d in docs { _ = cache.docCached(d) }
        #expect(cache.fullParseCount == 40)
        for d in docs { _ = cache.docCached(d) }
        #expect(cache.fullParseCount == 40)
        #expect(cache.currentEntryCount == 40)
        #expect(cache.estimatedBytes > 0)

        // #10 & #13: growing stream drops earlier prefix entries cleanly & non-streaming growth uses incremental cut reuse
        let sc = MarkdownDocCache(capacity: 32, budgetBytes: 2 << 20, frameGeneration: { 0 })
        _ = sc.streamCached("First paragraph.\n\n")
        _ = sc.streamCached("First paragraph.\n\nSecond paragraph.\n\n")
        let d3 = sc.streamCached("First paragraph.\n\nSecond paragraph.\n\nThird.")
        #expect(sc.currentEntryCount == 1)
        #expect(sc.peek("First paragraph.\n\n") == nil)
        #expect(sc.peek("First paragraph.\n\nSecond paragraph.\n\nThird.") == d3)
        _ = sc.docCached("First paragraph.\n\nSecond paragraph.\n\nThird.\n\nFourth paragraph.")
        #expect(sc.incrementalExtendCount >= 1)
        sc.reset()
        #expect(sc.currentEntryCount == 0 && sc.estimatedBytes == 0 && sc.fullParseCount == 0)

        // Budget eviction honors budgetBytes cap
        let tight = MarkdownDocCache(capacity: 64, budgetBytes: 1024, frameGeneration: { 0 })
        for i in 0..<20 {
            _ = tight.docCached(String(repeating: "Word \(i) ", count: 40))
        }
        #expect(tight.estimatedBytes <= 1024)

        // #13: repeated Runtime frames preserve stable block keys/paths and invalidate cleanly when source changes
        let kit = Kit.neutral(dark: true)
        let rt = Runtime<String>(state: "# Title\n\nBody copy.", viewport: Vec2(480, 200)) { src, _ in
            col().wFull().child(Markdown(src).build(kit).key("md"))
        }
        _ = rt.frame(at: 0.0)
        let pathsA = rt.elements().map(\.path)
        _ = rt.frame(at: 0.02)
        #expect(rt.elements().map(\.path) == pathsA)
        rt.update(at: 0.03) { s, _ in s = "# Title\n\nUpdated body.\n\n- added item" }
        _ = rt.frame(at: 0.04)
        #expect(rt.element(byKey: "b2")?.role == .list)

        // #13 full upstream cache parity (`src/markdown/tests.rs:288-362`): 3 siblings (2 unkeyed identical, 1 keyed),
        // root path preservation (#0/#0/b0, #0/#1/b0, #0/third/b0), selective rebuilds, & MarkdownStyle invalidation.
        struct PureState: Sendable {
            var tick: Int = 0
            var a: String = "Hello **world** from `rune`."
            var b: String = "Hello **world** from `rune`."
            var query: String = ""
            var accent: Color = .white
        }
        Markdown.withRenderCounter { renders in
            let pureRT = Runtime<PureState>(state: PureState(), viewport: Vec2(480, 400), pixelScale: 1.0, systemDark: true) { s, _ in
                _ = s.tick
                var style = MarkdownStyle.fromKit(kit)
                style.text = s.accent
                let hlA: [(ranges: [Range<Int>], style: MarkdownHighlight)] = s.query.isEmpty
                    ? []
                    : Markdown(s.a).findRanges(s.query, caseSensitivity: .insensitive).map { ($0, .match()) }
                return col().wFull().hFull().children([
                    Markdown(s.a).highlights(hlA).selectable(true).render(style),
                    Markdown(s.b).selectable(true).render(style),
                    Markdown("Third **card** note").render(style).key("third"),
                ])
            }
            _ = renders.take()
            _ = pureRT.frame(at: 0.0)
            #expect(renders.take() == 3)
            let purePaths = pureRT.elements().map(\.path)
            #expect(purePaths.contains(where: { $0.hasSuffix("/0/0/@b0") }))
            #expect(purePaths.contains(where: { $0.hasSuffix("/0/1/@b0") }))
            #expect(purePaths.contains(where: { $0.hasSuffix("/0/@third/@b0") }))

            for i in 1...5 {
                pureRT.update(at: Double(i) * 0.01) { s, _ in s.tick += 1 }
                _ = pureRT.frame(at: Double(i) * 0.01 + 0.005)
            }
            #expect(renders.take() == 0)

            pureRT.update(at: 0.10) { s, _ in s.b = "Updated *second* paragraph." }
            _ = pureRT.frame(at: 0.11)
            #expect(renders.take() == 1)
            #expect(pureRT.elements().contains(where: { $0.text == "Updated second paragraph." }))

            pureRT.update(at: 0.12) { s, _ in s.query = "world" }
            _ = pureRT.frame(at: 0.13)
            #expect(renders.take() == 1)

            let newInk = Color(r: 0.2, g: 0.6, b: 1.0, a: 1.0)
            pureRT.update(at: 0.14) { s, _ in s.accent = newInk }
            _ = pureRT.frame(at: 0.15)
            #expect(renders.take() == 3)
            _ = pureRT.frame(at: 2.0)
            #expect(pureRT.elements().contains(where: {
                $0.key == "b0"
                    && ($0.textColor.map {
                        abs($0.r - newInk.r) < 1e-3
                            && abs($0.g - newInk.g) < 1e-3
                            && abs($0.b - newInk.b) < 1e-3
                            && abs($0.a - newInk.a) < 1e-3
                    } ?? false)
            }))
        }

        // #14: multiple links each keep their own independent help tooltip
        let helpRT = Runtime<Int>(state: 0, viewport: Vec2(480, 200)) { _, _ in
            col().wFull().child(
                Markdown("Compare [Alpha](https://alpha.example) and [Beta](https://beta.example).")
                    .linkHelp { "Tooltip for \($0)" }
                    .onLink { _, _, _ in }
                    .build(kit)
            )
        }
        _ = helpRT.frame(at: 0.0)
        let links = helpRT.elements().filter { $0.role == .link }
        #expect(links.count == 2)
        #expect(links.first(where: { $0.key == "https://alpha.example" })?.help == "Tooltip for https://alpha.example")
        #expect(links.first(where: { $0.key == "https://beta.example" })?.help == "Tooltip for https://beta.example")
    }

    @Test("Streaming appends reparse the last block and preserve source coordinates")
    func streamedCacheMatchesFreshParse() {
        let cache = MarkdownDocCache(budgetBytes: 4 << 20, frameGeneration: { 0 })
        let complete = """
        Intro with **bold
        across lines** and `code`.

        | File | Change |
        |---|---|
        | a.rs | **x** |

        - [ ] an _item
        - [x] more

        ```swift
        let café = 42
        ```

        > a quoted **edit**

        last *words
        """
        var prefix = ""
        for scalar in complete.unicodeScalars {
            prefix.unicodeScalars.append(scalar)
            let result = cache.streamCached(prefix)
            let fresh = MarkdownTailStream.parseStreaming(prefix, autolink: true)
            #expect(result == fresh, "Incremental and whole parses differ at \(prefix.debugDescription)")
        }
        #expect(cache.incrementalExtendCount > complete.utf8.count / 2)
        let extended = complete + " with [a link"
        let replaced = String(extended.dropLast(9)) + "changed **tail"
        _ = cache.streamCached(extended)
        let wholeBefore = cache.fullParseCount
        let edited = cache.streamCached(replaced)
        #expect(edited == MarkdownTailStream.parseStreaming(replaced, autolink: true))
        #expect(cache.fullParseCount == wholeBefore + 1)

        let ref = "# Title\n\n[ref]\n\n[ref]"
        _ = cache.streamCached(ref)
        let resolved = cache.streamCached(ref + ": https://example.com")
        #expect(resolved == MarkdownParser.parseDocument(ref + ": https://example.com"))
        #expect(cache.streamCached("**open") != cache.docCached("**open"))
    }

    @Test("Streaming markers carry the pinned Rust link destinations and line scope")
    func streamingMarkerSnapshots() throws {
        func firstInline(_ source: String) throws -> MarkdownInline {
            let first = try #require(Markdown(source).streaming().blocks().first)
            switch first {
            case let .para(inl), let .heading(_, inl): return inl
            default: throw CocoaError(.coderValueNotFound)
            }
        }
        let open = try firstInline("see [ x")
        #expect(open.text == "see  x")
        #expect(open.links == [MarkdownLinkSpan(start: 4, end: 6, url: "")])
        #expect(try firstInline("see [x").text == "see")
        #expect(try firstInline("a `aa \u{2003}").text == "a " + MarkdownInline.openPad + "aa")
        #expect(try firstInline("# a **b\n").text == "a **b")
        let cut = try firstInline("a [label](foo \"Ti")
        #expect(cut.links == [MarkdownLinkSpan(start: 2, end: 7, url: "foo")])
    }

    #if !os(WASI)
    @MainActor
    @Test("A new event thread starts with independent document caches and commit generations")
    func eventThreadCacheOwnership() async {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(8, 8)) { _, _ in el() }
        _ = rt.frame(at: 0)
        let current = MarkdownDocCache.shared
        #expect(commitGeneration() > 0)
        let (generation, other): (UInt64, MarkdownDocCache) = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: (commitGeneration(), MarkdownDocCache.shared))
            }
        }
        #expect(generation == 0)
        #expect(other !== current)
    }
    #endif

    @Test("Long streams keep settled blocks and preserve retained snapshots")
    func longStreamKeepsSnapshots() {
        let cache = MarkdownDocCache(budgetBytes: 4 << 20, frameGeneration: { 0 })
        let chunk = "Paragraph with **bold**, café and an [issue](https://example.com).\n\n"
        let initial = String(repeating: chunk, count: 768)
        let original = cache.streamCached(initial)
        var source = initial
        for _ in 0..<64 {
            source += chunk
            _ = cache.streamCached(source)
        }
        #expect(cache.fullParseCount == 1)
        #expect(cache.incrementalExtendCount == 64)
        #expect(cache.currentEntryCount == 1)
        #expect(cache.streamCached(source) == MarkdownTailStream.parseStreaming(source, autolink: true))
        #expect(original == MarkdownTailStream.parseStreaming(initial, autolink: true))
    }

    @MainActor
    @Test("Live Markdown survives cache pressure across runtime commits")
    func liveDocumentsAndStreamSnapshots() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(8, 8)) { _, _ in el() }
        var time = 0.0
        func commit() {
            rt.invalidate()
            time += 0.01
            _ = rt.frame(at: time)
        }
        let cache = MarkdownDocCache(budgetBytes: 128)
        commit()
        let old = "# Intro\n\nold snapshot.\n"
        _ = cache.streamCached(old)
        let new = old + "\nNew **text"
        _ = cache.streamCached(new)
        #expect(cache.peek(old, streaming: true) != nil)
        let documents = (0..<300).map { "Document \($0)" }
        for text in documents { _ = cache.docCached(text) }
        let parses = cache.fullParseCount
        #expect(cache.currentEntryCount == documents.count + 2)
        commit()
        for text in documents { _ = cache.docCached(text) }
        #expect(cache.fullParseCount == parses)
        _ = cache.streamCached(new + " arrives")
        #expect(cache.peek(new, streaming: true) == nil)
        #expect(cache.peek(old, streaming: true) != nil)
        commit()
        _ = cache.docCached("Another document")
        #expect(cache.peek(old, streaming: true) == nil)
        #expect(cache.peek(documents[0]) != nil)
    }

    @MainActor
    @Test("Rebuilding Markdown runs a custom highlighter once per fenced block")
    func reusedCustomHighlighter() {
        final class Calls: @unchecked Sendable { var count = 0 }
        let calls = Calls()
        let style = MarkdownStyle.neutral(dark: true)
        let rt = Runtime(state: 0, viewport: Vec2(400, 400)) { _, _ in
            Markdown("```py\nx = 1\n```\n\n```go\nvar y = 2\n```").highlight { _, _ in
                calls.count += 1
                return []
            }.render(style)
        }
        for i in 0..<4 {
            rt.invalidate()
            _ = rt.frame(at: Double(i) / 60)
        }
        #expect(calls.count == 2)
    }

    @MainActor
    @Test("Streaming Markdown drives runtime word reveal on new text")
    func markdownRevealReachesRuntime() {
        let style = MarkdownStyle.neutral(dark: true)
        let initial: El<Int> = Markdown("First word").render(style)
        #expect(initial.children.first?.textReveal == -1)
        let stream: El<Int> = Markdown("First word").streaming().render(style)
        #expect(stream.children.first?.textReveal == 0)
        let rt = Runtime(state: "First word", viewport: Vec2(300, 80)) { source, _ in
            Markdown(source).streaming().reveal(0.2).render(style)
        }
        _ = rt.frame(at: 0)
        rt.update(at: 0.01) { source, _ in source += " appended" }
        let first = rt.frame(at: 0.01)
        #expect(rt.isAnimating)
        let settled = rt.frame(at: 1)
        func glyphAlpha(_ scene: RefScene) -> Float {
            scene.primitives.filter { $0.kind == .glyph }.reduce(0) { $0 + $1.fill.w }
        }
        #expect(glyphAlpha(settled) > glyphAlpha(first))
    }

    @Test("Code block rows preserve multiline lexer ranges")
    func multilineCodeRows() {
        let kit = Kit.neutral(dark: true)
        let color = Color(r: 0.4, g: 0.5, b: 0.7)
        let highlighter = SyntaxHighlighter { _, code in
            guard code == "x /*two\nlines*/ y" else { return [] }
            return [SyntaxHighlight(range: 2..<15, paint: .color(color))]
        }
        let built: El<Int> = kit.codeBlock(code: "x /*two\r\nlines*/ y", showLineNumbers: false, highlighter: highlighter)
        let rows = built.children[1].children
        let colored = rows.map { row in row.children.last?.richSpans?.filter { $0.color == color }.map(\.text).joined() }
        #expect(colored == ["/*two", "lines*/"])
    }

    @Test("Syntax decoration ranges use the enclosing code offset in bytes")
    func syntaxRangeOffset() {
        let theme = SyntaxTheme.neutral(dark: true).withWeight(.keyword, 640.75)
        let color = Color(r: 0.1, g: 0.2, b: 0.3)
        let spans = theme.spans([
            SyntaxHighlight(range: 0..<3, paint: .kind(.keyword)),
            SyntaxHighlight(range: 4..<6, paint: .color(color)),
        ], offset: 7)
        #expect(spans.map(\.byteRange) == [7..<10, 11..<13])
        #expect(spans.map(\.weight) == [640, nil])
        #expect(spans.map(\.color) == [theme.color(for: .keyword), color])
    }

    @Test("Markdown and syntax offsets distinguish canonically equivalent UTF-8")
    func cachedUTF8Offsets() {
        let cache = MarkdownDocCache(budgetBytes: 4096)
        let precomposed = "é\n\n- [ ] Task"
        let decomposed = "e\u{301}\n\n- [ ] Task"
        let first = cache.docCached(precomposed)
        let second = cache.docCached(decomposed)
        #expect(second == MarkdownParser.parseDocument(decomposed))
        #expect(first.tasks != second.tasks)

        let custom = SyntaxHighlighter { _, text in
            [SyntaxHighlight(range: 0..<text.utf8.count, paint: .kind(.string))]
        }
        #expect(custom.highlight(language: nil, code: "é").first?.range == 0..<2)
        #expect(custom.highlight(language: nil, code: "e\u{301}").first?.range == 0..<3)
        let scalar = SyntaxHighlighter { _, _ in [SyntaxHighlight(range: 0..<1, paint: .kind(.string))] }
        #expect(scalar.highlight(language: nil, code: "e\u{301}").first?.range == 0..<1)
    }

    // MARK: - Comprehensive S2 Builder Parity (tests/markdown.rs #64, Markdown, MarkdownStyle, MarkdownHighlight, LinkIcons, SyntaxTheme, ImageZoom, Actions)

    @MainActor
    @Test("S2 & tests/markdown.rs #64: every Markdown/MarkdownStyle/MarkdownHighlight/LinkIcon/ImageZoom/Control builder overrides defaults cleanly")
    func styleAndBuilderCoverageParity() {
        let red = Color(r: 0.9, g: 0.1, b: 0.1, a: 1.0)
        let blue = Color(r: 0.1, g: 0.3, b: 0.95, a: 1.0)
        let green = Color(r: 0.1, g: 0.8, b: 0.25, a: 1.0)
        let gold = Color(r: 0.95, g: 0.78, b: 0.15, a: 1.0)
        let darkBg = Color(r: 0.08, g: 0.09, b: 0.11, a: 1.0)

        let kit = Kit.neutral(dark: true)
        let customTheme = SyntaxTheme.neutral(dark: true).with(.keyword, red).withWeight(.keyword, 700)
        #expect(customTheme.weight(for: .keyword) == 700)

        let style = MarkdownStyle.fromKit(kit)
            .text(red)
            .muted(gold)
            .link(blue)
            .linkUnderline(green)
            .linkHover(gold)
            .inlineCodeBg(darkBg)
            .codeBlock(darkBg, red)
            .codeBlockPadding(18, 12)
            .codeBlockText(gold)
            .plainCodeText(green)
            .shellCode(fill: darkBg, border: blue, text: gold)
            .codeMargin(top: 10, bottom: 14)
            .list(28, 8)
            .listMarkersOutside(true)
            .listNestedIndent(bullets: 18, numbers: 22)
            .quoteRule(red)
            .quote(blue, width: 4, pad: 16, text: gold)
            .rule(green)
            .bodyFont(TextStyle(size: 16, weight: 400, lineHeight: 24))
            .headingFont(1, TextStyle(size: 28, weight: 700, lineHeight: 34))
            .codeBlockFont(TextStyle(size: 13, weight: 500, lineHeight: 19, family: .monospace))
            .inlineCodeFont(scale: 0.9, weight: 600)
            .inlineCodePad(4)
            .strongWeight(800)
            .textWidth(640)
            .wideFade(20)
            .diff(added: green.alpha(0.2), removed: red.alpha(0.2))
            .diffText(added: green, removed: red)
            .diffTextTint(0.5)
            .diffHunk(blue)
            .syntax(.string, gold)
            .syntaxTheme(customTheme)
            .syntaxHighlight(true)
            .selection(blue.alpha(0.3))
            .diagram(nodeFill: darkBg, nodeBorder: blue, line: green)
            .diagramSurface(fill: darkBg, border: red, subgraph: blue.alpha(0.1))
            .diagramTypography(font: TextStyle(size: 14, weight: 500, lineHeight: 20), maxWidth: 500, minScale: 0.5)
            .diagramHover(gold, neighbours: true)
            .highlightBg(gold.alpha(0.25))
            .highlightFg(red)
            .highlightRing(blue, 1.5)
            .highlightCurrent(bg: green.alpha(0.35), fg: red, ring: (gold, 2.0))
            .linkIcons(12, 4)
            .linkIcon(.trailing(gap: 5, size: 14))
            .tableRules(green)
            .tableHeader(fill: darkBg, text: gold)
            .tableHeaderText(red)
            .tableHeaderRule(blue)
            .tableHeaderWeight(700)
            .tableTabularFigures(true)
            .tableMinColumn(48)
            .tableFont(TextStyle(size: 13, weight: 400, lineHeight: 18))
            .tableCellPadding(x: 12, y: 8)
            .tableFlushLeft(true)
            .tableFullWidth(false)
            .tableColumnAlign(false)
            .tableScrollBar(thumb: blue, thumbHover: gold)

        #expect(style.text == red)
        #expect(style.muted == gold)
        #expect(style.accent == blue)
        #expect(style.linkUnderline == green)
        #expect(style.linkHover == gold)
        #expect(style.codeBg == darkBg)
        #expect(style.codeBlockFill == darkBg && style.codeBlockBorder == red)
        #expect(style.codeBlockPad == [18, 12])
        #expect(style.codeText == gold && style.plainCodeText == green)
        #expect(style.shell == MarkdownShellLook(fill: darkBg, border: blue, text: gold))
        #expect(style.codeMargin == [10, 14])
        #expect(style.listIndent == 28 && style.listGap == 8 && style.listOutside == true)
        #expect(style.listNested == [18, 22])
        #expect(style.quote == MarkdownQuoteLook(width: 4, pad: 16, text: gold))
        #expect(style.rule == green && style.body.size == 16 && style.headings[0].size == 28)
        #expect(style.inlineCodeScale == 0.9 && style.inlineCodeWeight == 600 && style.inlineCodePad == 4)
        #expect(style.strongWeight == 800 && style.textWidth == 640 && style.wideFade == 20)
        #expect(style.diffHunk == blue && style.syntax.weight(for: .keyword) == 700)
        #expect(style.selection == blue.alpha(0.3))
        #expect(style.diagram.hoverNeighbours && style.diagram.hover == gold)
        #expect(style.highlightBg == gold.alpha(0.25) && style.highlightFg == red && style.highlightRing?.1 == 1.5)
        #expect(style.tableHeadText == red && style.tableHeadRule == blue && style.tableHeadWeight == 700)
        #expect(style.tableFlushLeft && !style.tableFullWidth && !style.tableAlign)
        #expect(style.tableBar == [blue, gold])
        #expect(Markdown.highlightKey(3) == "h3")

        // Markdown & MarkdownHighlight & LinkFavicon & LinkIcons
        let hl = MarkdownHighlight.match().current(true).bg(gold).fg(red).ring(blue, 2.0).key("custom-hl")
        #expect(hl.current && hl.bg == gold && hl.fg == red && hl.ringColor == blue && hl.ringWidth == 2.0 && hl.key == "custom-hl")
        #expect(!(MarkdownLinkIcons.globe.body ?? "").isEmpty && !(MarkdownLinkIcons.github.body ?? "").isEmpty)
        #expect(MarkdownLinkIcons.linkHost("https://github.com/anomalyco/rune") == "github.com")

        let favicon = RGBA8Atlas(width: 4, height: 4, texels: [UInt8](repeating: 255, count: 64))
        let md = Markdown("See [repo](https://github.com/anomalyco/rune) and [docs](https://example.org/docs) needle.")
            .reveal(0.25)
            .dirTentative(MarkdownDirection.rtl)
            .highlight(83..<89, hl)
            .linkFavicon { url in url.contains("example.org") ? favicon : nil }
            .style(style)
        #expect(md.revealDelay == 0.25 && md.tentativeDirection == MarkdownDirection.rtl)

        let rt = Runtime<Int>(state: 0, viewport: Vec2(700, 300)) { _, _ in
            col().wFull().child(md.onLink { _, _, _ in }.build(kit))
        }
        _ = rt.frame(at: 0.0)
        let mark = rt.elements().first(where: { $0.role == ElementRole.mark })
        #expect(mark?.key == "custom-hl" && mark?.fill == gold)
        let para = rt.elements().first(where: { $0.key == "b0" })
        #expect(para?.textColor == red)

        // ImageZoom Stage & Preview builders + Kit button/iconButton expanded/help/shortcut
        struct StageHost: Sendable { var stage = StageZoom() }
        struct PreviewHost: Sendable { var zoom = ImageZoomState() }
        let stageEl: El<StageHost> = Stage<StageHost>(\StageHost.stage, natural: Vec2(100, 100), image: el().size(100, 100))
            .grows(false)
            .icons(zoomIn: kit.glyph.check, zoomOut: kit.glyph.close, fit: kit.glyph.search)
            .labels(zoomIn: "Zoom In Custom", zoomOut: "Zoom Out Custom", fit: "Fit Custom", group: "Custom Stage")
            .build(StageZoom(), kit: kit, size: Vec2(400, 300))
        let stageRT = Runtime<StageHost>(state: StageHost(), viewport: Vec2(400, 300)) { _, _ in stageEl }
        _ = stageRT.frame(at: 0.0)
        #expect(stageRT.elements().contains(where: { $0.label == "Zoom In Custom" }))

        let prevEl: El<PreviewHost> = Preview<PreviewHost>(\PreviewHost.zoom, natural: Vec2(100, 100), image: el().size(100, 100))
            .icons(minus: kit.glyph.dash, plus: kit.glyph.check)
            .labels(zoomOut: "P-Out", fit: "P-Fit", zoomIn: "P-In", close: "P-Close")
            .formatLevel { "\($0)%" }
            .build(ImageZoomState(), kit: kit, window: Vec2(400, 300))
        let prevRT = Runtime<PreviewHost>(state: PreviewHost(), viewport: Vec2(400, 300)) { _, _ in prevEl }
        _ = prevRT.frame(at: 0.0)
        #expect(prevRT.elements().contains(where: { $0.label == "P-In" }))

        let btnRT = Runtime<Int>(state: 0, viewport: Vec2(300, 200)) { _, _ in
            let wideBtn: El<Int> = Button<Int>(key: "wide-btn", "Expand")
                .expanded(true)
                .help("Expand Hint")
                .shortcut("⌘E")
                .build(kit)
            let helpBtn: El<Int> = IconButton<Int>(key: "help-btn", svg: kit.glyph.copy)
                .label("Copy")
                .expanded(true)
                .help("Copy Hint")
                .shortcut("⌘C")
                .build(kit)
            let noteEl: El<Int> = Note("Hello **note**").key("note-builder").gap(8).build(kit)
            return Kit.root(
                col().wFull().gap(4).children([wideBtn, helpBtn, noteEl]),
                overlays: [el().key("ov-root").size(20, 20)]
            )
        }
        _ = btnRT.frame(at: 0.0)
        #expect((btnRT.element(byKey: "wide-btn")?.rect[2] ?? 0) >= 32.0)
        #expect(btnRT.element(byKey: "wide-btn")?.expanded == true)
        #expect(btnRT.element(byKey: "help-btn")?.expanded == true)
        #expect(btnRT.element(byKey: "help-btn")?.help?.contains("Copy Hint") == true)
        #expect(btnRT.element(byKey: "note-builder") != nil)
        #expect(btnRT.element(byKey: "kit-root") != nil && btnRT.element(byKey: "ov-root") != nil)

        let tableLikeStyle = MarkdownStyle.fromKit(kit).tableLike(TableStyle.fromKit(kit))
        #expect(tableLikeStyle.tableFrame == nil && tableLikeStyle.tableBody == nil)
        let noteFill = Color(r: 0.11, g: 0.22, b: 0.33, a: 1.0)
        let noteBorder = Color(r: 0.44, g: 0.55, b: 0.66, a: 1.0)
        let noteStyled = tableLikeStyle.diagramNote(noteFill, noteBorder)
        #expect(noteStyled.diagram.noteFill == noteFill && noteStyled.diagram.noteBorder == noteBorder)
        #expect(noteStyled.mermaidTheme().noteFill == noteFill && noteStyled.mermaidTheme().noteBorder == noteBorder)
        #expect(ImageZoomMath.wheelZoomFactor(deltaY: -120) > 1.0 && ImageZoomMath.wheelZoomFactor(deltaY: 120) < 1.0)
        var diffWithHL = DiffState(diff: FileDiff.fromTexts(path: "a.swift", old: "let x = 1\n", new: "let x = 2\n", context: 3))
        diffWithHL.setHighlighter(SyntaxHighlighter.builtin)
        let _ = diffWithHL.singleColumn(file: 0)
        #expect(diffWithHL.files[0].fold(context: 1).hunks.count >= 1)
        #expect(DiffLineRange.line(DiffLineRef(side: .new, line: 1)).start.line == 1)

        // #144: full markdown_fixture document renders headings, lists, tasks, code, quote, table, links, and mermaid in both dark and light appearances
        let fixtureDoc = """
        ## What's happening

        See [the retry notes](https://example.com/retry) and **bold** `code`.

        - item one
          - nested point

        ```ts
        const QUIET_MS = 25_000
        ```

        > Quoted advice.

        1. First step

        - [x] watchdog added
        - [ ] reconnect test

        | Case | Delay |
        | :--- | ---: |
        | flapping | 1s |

        ```mermaid
        graph TD
          A[Start] --> B[End]
        ```
        """
        for dark in [true, false] {
            let fk = Kit.neutral(dark: dark)
            let fixRT = Runtime<Int>(state: 0, viewport: Vec2(640, 900)) { _, _ in
                col().wFull().child(Markdown(fixtureDoc).onLink { _, _, _ in }.onTask { _, _, _, _, _ in }.build(fk))
            }
            _ = fixRT.frame(at: 0.0)
            let els = fixRT.elements()
            #expect(els.contains(where: { $0.role == .heading && $0.level == 2 }))
            #expect(els.contains(where: { $0.role == .list }))
            #expect(els.contains(where: { $0.role == .checkbox && $0.selected == "true" }))
            #expect(els.contains(where: { $0.role == .table }))
            #expect(els.contains(where: { $0.role == .code }))
            #expect(els.contains(where: { $0.role == .link && $0.key == "https://example.com/retry" }))
        }
    }

    // MARK: - Table Mechanics & Card Parity (tests/markdown.rs #71-#77, #82-#84; markdown_table_card.rs #96, #101, #103, #104, #107, #108)

    @MainActor
    @Test("tests/markdown.rs & markdown_table_card.rs: column lock, wrapping, tabular figures, flushLeft, copy, header pad & rounding (#71-#77, #82-#84, #96, #101, #103, #104, #107, #108)")
    func markdownTableDetailedParity() {
        let kit = Kit.neutral(dark: true)

        func runTable(_ src: String, width: Float = 600, streaming: Bool = false, scrollWide: Bool = false, style: MarkdownStyle) -> Runtime<String> {
            let rt = Runtime<String>(state: src, viewport: Vec2(width, 600), pixelScale: 1.0, systemDark: true) { s, _ in
                col().wFull().child(Markdown(s).streaming(streaming).scrollWide(scrollWide).selectable(true).copySource(true).render(style).key("note"))
            }
            _ = rt.frame(at: 0.0)
            return rt
        }

        func cell(_ rt: Runtime<String>, row rowKey: String, col c: Int) -> ElementInfo? {
            let rowEl = rt.element(byKey: rowKey)
            return rowEl.flatMap { r in
                rt.elements().first { $0.key == "c\(c)" && $0.path.hasPrefix(r.path + "/") }
            }
        }

        // #71 & #104: streaming last row does not move column widths (card + scrollWide)
        let cardStyle = MarkdownStyle.fromKit(kit).tableCard(kit)
        let shortRT = runTable("| Term | Meaning |\n|---|---|\n| cache | short |\n| tail | arriving", streaming: true, scrollWide: true, style: cardStyle)
        let longRT = runTable("| Term | Meaning |\n|---|---|\n| cache | short |\n| tail | arriving " + String(repeating: "x", count: 250), streaming: true, scrollWide: true, style: cardStyle)
        #expect(cell(shortRT, row: "th", col: 0)?.rect[2] == cell(longRT, row: "th", col: 0)?.rect[2])
        #expect(cell(shortRT, row: "th", col: 1)?.rect[2] == cell(longRT, row: "th", col: 1)?.rect[2])

        // #72: finished table sizes to its last row too
        let wholeRT = runTable("| Term | Meaning |\n|---|---|\n| cache | short |\n| tail | longer tail value", streaming: false, style: cardStyle)
        let wholeWideRT = runTable("| Term | Meaning |\n|---|---|\n| cache | short |\n| tail | longer tail value much wider now", streaming: false, style: cardStyle)
        #expect((cell(wholeWideRT, row: "th", col: 1)?.rect[2] ?? 0) > (cell(wholeRT, row: "th", col: 1)?.rect[2] ?? 0))

        // #73 & #84: narrow table stays single-line per cell; long cell wraps inside narrow constrained column
        let narrowRT = runTable("| A | B |\n|---|---|\n| 1 | hello |", width: 500, style: MarkdownStyle.fromKit(kit))
        #expect((cell(narrowRT, row: "r0", col: 1)?.rect[3] ?? 0) < 40)
        let wrapRT = runTable("| K | Desc |\n|---|---|\n| id | This cell is very long and definitely wraps cleanly across multiple visual lines when bounded. |", width: 220, style: MarkdownStyle.fromKit(kit))
        #expect((cell(wrapRT, row: "r0", col: 1)?.rect[3] ?? 0) > (cell(wrapRT, row: "r0", col: 0)?.rect[3] ?? 0) || (wrapRT.element(byKey: "r0")?.rect[3] ?? 0) > 40)

        // #74, #75, #76: options outline=nil, tabular figures, header fill/rule/weight, font, flushLeft
        let customTableStyle = MarkdownStyle.fromKit(kit)
            .tableOutline(nil)
            .tableTabularFigures(true)
            .tableHeader(fill: Color(r: 0.2, g: 0.3, b: 0.4, a: 1), text: Color(r: 0.9, g: 0.9, b: 1, a: 1))
            .tableHeaderRule(Color(r: 0.4, g: 0.5, b: 0.6, a: 1))
            .tableHeaderWeight(700)
            .tableFont(TextStyle(size: 13, weight: 400, lineHeight: 18))
            .tableCellPadding(x: 10, y: 6)
            .tableFlushLeft(true)
        let optRT = runTable("| Item | Num |\n|---|---:|\n| First | 111 |\n| Second | 999 |", style: customTableStyle)
        #expect(optRT.element(byKey: "s-end") != nil)
        #expect(optRT.element(byKey: "th")?.fill == Color(r: 0.2, g: 0.3, b: 0.4, a: 1))
        #expect(optRT.element(byKey: "th")?.opacity == 1)
        // Verify first column sits flush left (c0.x == th.x)
        if let thRect = optRT.element(byKey: "th")?.rect, let c0Rect = cell(optRT, row: "r0", col: 0)?.rect {
            #expect(abs(c0Rect[0] - thRect[0]) < 1.0)
        }

        // #74 (`tests/markdown.rs:338`): outline=nil drops frame radius & adds s-end, dims header text while keeping body textBase, and tnum aligns 1111 vs 0000
        let defaultNumRT = runTable("| Name | Count |\n|---|--:|\n| a | 1111 |\n| b | 0000 |\n", style: MarkdownStyle.fromKit(kit))
        #expect(defaultNumRT.element(byKey: "s-end") == nil)
        let defEls = defaultNumRT.elements()
        if let defTH = defEls.first(where: { $0.key == "th" }), let pIdx = defTH.parentIndex {
            #expect(defEls[pIdx].radius == 6.0)
        }
        #expect(defEls.first(where: { $0.text == "Name" })?.textColor == defEls.first(where: { $0.text == "a" })?.textColor)

        let dimHead = Color(r: 0.5, g: 0.5, b: 0.5, a: 1.0)
        let blueRule = Color(r: 0.0, g: 0.0, b: 1.0, a: 1.0)
        let noOutStyle = MarkdownStyle.fromKit(kit).tableOutline(nil).tableRules(blueRule).tableHeaderRule(blueRule).tableHeaderText(dimHead)
        let noOutRT = runTable("| Name | Count |\n|---|--:|\n| a | 1111 |\n| b | 0000 |\n", style: noOutStyle)
        #expect(noOutRT.element(byKey: "s0")?.fill == blueRule)
        #expect(noOutRT.element(byKey: "s-end")?.fill == blueRule)
        let noOutEls = noOutRT.elements()
        if let nTH = noOutEls.first(where: { $0.key == "th" }), let pIdx = nTH.parentIndex {
            #expect(noOutEls[pIdx].radius == 0.0)
            #expect(nTH.opacity == 1)
        }
        #expect(noOutEls.first(where: { $0.text == "Name" })?.textColor == dimHead)
        #expect(noOutEls.first(where: { $0.text == "a" })?.textColor == kit.c.textBase)
        let c1111 = noOutEls.first(where: { $0.text == "1111" })
        let c0000 = noOutEls.first(where: { $0.text == "0000" })
        #expect(c1111 != nil && c0000 != nil)
        if let w1 = c1111?.rect[2], let w0 = c0000?.rect[2] {
            #expect(abs(w1 - w0) < 0.01)
        }

        // Tabular figures (on by default) give every digit one width and leave other text alone
        // (`tests/markdown.rs:367-375`).
        for family in [FontFamily.systemUI, FontFamily.named("System Font")] {
            let plain = TextStyle(size: 14, weight: 400).family(family)
            let tnum = plain.features("'tnum' 1")
            let w = { (t: String, f: TextStyle) -> Float in TextMeasure.measure(t, style: f).x }
            #expect(w("1111", tnum) == w("0000", tnum), "\(family)")
            #expect(w("1111", plain) != w("0000", plain), "\(family)'s default figures are proportional")
            // Words only: Inter's tabular set also covers the space and the comma, as Chromium
            // measures it ("draft cursor, updatedAt" at 14 px: 153.0625 plain, 153.296875 with 'tnum'),
            // which widths rounded up to whole points hid until #934.
            #expect(w("draftCursorUpdatedAt", tnum) == w("draftCursorUpdatedAt", plain), "\(family)")
        }

        // #77, #82, #96: narrow container stops columns; scrollWide keeps narrow table compact & lets fullWidth scroll wide
        let clipRT = runTable("| Heading One | Heading Two | Heading Three |\n|---|---|---|\n| supercalifragilistic | expialidocious | antidisestablishmentarianism |", width: 220, style: cardStyle)
        #expect((clipRT.element(byKey: "tb")?.rect[2] ?? 0) <= 220.5)
        let narrowScrollRT = runTable("| A | B |\n|---|---|\n| 1 | 2 |", width: 500, scrollWide: true, style: MarkdownStyle.fromKit(kit).tableFullWidth(false))
        #expect((narrowScrollRT.element(byKey: "th")?.rect[2] ?? 999) < 500)
        let fullWideScrollRT = runTable("| Term | Meaning |\n|---|---|\n| cache | a sentence much too long for one line of a narrow column so it scrolls wide horizontally cleanly without wrapping at all |", width: 300, scrollWide: true, style: cardStyle)
        #expect((fullWideScrollRT.element(byKey: "th")?.rect[2] ?? 0) > 300)

        // #83: column alignment toggled on vs off
        let alignRT = runTable("| L | R |\n|:---|---:|\n| x | 1 |\n", width: 320, style: cardStyle)
        let noAlignRT = runTable("| L | R |\n|:---|---:|\n| x | 1 |\n", width: 320, style: cardStyle.tableColumnAlign(false))
        let alignedGlyphX = Self.glyphXs(alignRT, in: cell(alignRT, row: "r0", col: 1)?.rect ?? []).first?.x ?? 0
        let unalignedGlyphX = Self.glyphXs(noAlignRT, in: cell(noAlignRT, row: "r0", col: 1)?.rect ?? []).first?.x ?? 0
        #expect(alignedGlyphX > unalignedGlyphX + 10.0)

        // #101, #103, #107, #108: streaming last row + card copy + header-only pad + outline header
        let streamCardRT = runTable("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | arri", streaming: true, style: cardStyle)
        #expect(streamCardRT.element(byKey: "r1") != nil && streamCardRT.element(byKey: "tb") != nil)

        let tableDoc = "Before.\n\n| A | B |\n|---|---|\n| alpha | beta |\n\nAfter.\n"
        let copyRT = runTable(tableDoc, style: cardStyle)
        copyRT.update(at: 0.01) { _, tx in tx.selectAllText("b1") }
        _ = copyRT.frame(at: 0.02)
        _ = copyRT.keyDown(KeyEvent(key: .command("c"), mods: RuneKitTestKey.primaryMods()), at: 0.02)
        #expect(copyRT.clipboard.text == "| A | B |\n|---|---|\n| alpha | beta |")
        if let cellEl = copyRT.elements().first(where: { $0.text == "alpha" }) {
            copyRT.update(at: 0.03) { _, tx in tx.selectText(cellEl.path, range: 0..<5) }
            _ = copyRT.frame(at: 0.04)
            _ = copyRT.keyDown(KeyEvent(key: .command("c"), mods: RuneKitTestKey.primaryMods()), at: 0.04)
            #expect(copyRT.clipboard.text == "alpha")
        }

        let widePad = MarkdownStyle.fromKit(kit).tableHeaderPad(x: 6, y: 6).tableCellPadding(x: 30, y: 6)
        let samePad = MarkdownStyle.fromKit(kit).tableHeaderPad(x: 6, y: 6).tableCellPadding(x: 6, y: 6)
        let hOnlyA = runTable("| a | b |\n|---|---|\n", style: widePad)
        let hOnlyB = runTable("| a | b |\n|---|---|\n", style: samePad)
        #expect(cell(hOnlyA, row: "th", col: 0)?.rect[2] == cell(hOnlyB, row: "th", col: 0)?.rect[2])

        let outlinedFill = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let outlineRT = runTable("| A | B |\n|---|---|\n| a | b |\n", style: MarkdownStyle.neutral(dark: true).tableHeader(fill: outlinedFill, text: .white))
        #expect(outlineRT.element(byKey: "th")?.fill == outlinedFill)
    }

    // MARK: - Link Style, Streaming Chunks & Link Ring (tests/markdown.rs #88-#90)

    @MainActor
    @Test("tests/markdown.rs: linkStyle selective URL match, chunked streaming links, and linkRing focus/hover (#88-#90)")
    func linkStyleRingAndStreamingParity() {
        let kit = Kit.neutral(dark: true)
        let hoverGold = Color(r: 0.95, g: 0.8, b: 0.1, a: 1.0)
        let ringColor = Color(r: 0.2, g: 0.7, b: 1.0, a: 1.0)

        let rt = Runtime<String>(
            state: "Start [First **bold** `code`](ses",
            viewport: Vec2(400, 200),
            pixelScale: 2.0,
            systemDark: true
        ) { src, _ in
            col().wFull().child(
                Markdown(src)
                    .selectable(true)
                    .linkStyle { url in
                        url.hasPrefix("session:") ? (color: .white, underline: false, weight: 600, hoverColor: hoverGold) : nil
                    }
                    .linkRing { url in url.hasPrefix("session:") ? (ringColor, 1.5) : nil }
                    .onLink { _, _, _ in }
                    .build(kit)
            )
        }
        _ = rt.frame(at: 0.0)
        #expect(rt.elements().filter { $0.role == .link }.isEmpty)

        rt.update(at: 0.01) { s, _ in
            s = "Start [First **bold** `code`](session:one) and [Ext](https://a.dev)."
        }
        _ = rt.frame(at: 0.02)
        let sessionLink = rt.elements().first(where: { $0.role == .link && $0.key == "session:one" })
        let extLink = rt.elements().first(where: { $0.role == .link && $0.key == "https://a.dev" })
        #expect(sessionLink != nil && extLink != nil)

        if let sr = sessionLink?.rect {
            let p = Vec2(sr[0] + sr[2] * 0.5, sr[1] + sr[3] * 0.5)
            rt.pointerMove(to: p, at: 0.03)
            _ = rt.frame(at: 0.04)
            #expect(rt.currentCursor() == .pointer)
        }

        // #88 (`tests/markdown.rs:796`): linkStyle selectively styles only matching URLs (`session:`),
        // preserves default look on non-matching URLs (`https://a.dev`), and paints hover rect only on matching URL.
        let chipBg = Color(r: 0.18, g: 0.22, b: 0.32, a: 1.0)
        let chipHover = Color(r: 0.28, g: 0.36, b: 0.52, a: 1.0)
        let selRT = Runtime<Int>(state: 0, viewport: Vec2(400, 160), pixelScale: 1.0, systemDark: true) { _, _ in
            col().wFull().child(
                Markdown("See [Title](session:abc) and [Link](https://a.dev).")
                    .linkStyle { url in
                        url.hasPrefix("session:")
                            ? MarkdownLinkStyle(color: .white, underline: false, weight: 500, bg: chipBg, hoverColor: .white, hoverBg: chipHover)
                            : nil
                    }
                    .onLink { _, _, _ in }
                    .build(kit)
            )
        }
        let scene0 = selRT.frame(at: 0.0)
        let chipBgFills = scene0.primitives.filter { $0.kind == .roundedRect && $0.fill == chipBg.simd4(srgb: scene0.srgbBlend) }
        let chipHoverFills0 = scene0.primitives.filter { $0.kind == .roundedRect && $0.fill == chipHover.simd4(srgb: scene0.srgbBlend) }
        #expect(chipBgFills.count == 1)
        #expect(chipHoverFills0.isEmpty)

        let selChip = selRT.elements().first(where: { $0.role == .link && $0.key == "session:abc" })!
        let selExt = selRT.elements().first(where: { $0.role == .link && $0.key == "https://a.dev" })!
        #expect(selChip.label == "Title")
        #expect(abs(chipBgFills[0].rect.z - selChip.rect[2]) < 1.0)

        // Hovering https://a.dev -> pointer cursor, NO chipHover fill
        selRT.pointerMove(to: Vec2(selExt.rect[0] + selExt.rect[2] * 0.5, selExt.rect[1] + selExt.rect[3] * 0.5), at: 0.02)
        let sceneExt = selRT.frame(at: 0.03)
        #expect(selRT.currentCursor() == .pointer)
        #expect(sceneExt.primitives.filter { $0.kind == .roundedRect && $0.fill == chipHover.simd4(srgb: sceneExt.srgbBlend) }.isEmpty)

        // Hovering session:abc -> pointer cursor + chipHover rect on session:abc's bounds
        selRT.pointerMove(to: Vec2(selChip.rect[0] + selChip.rect[2] * 0.5, selChip.rect[1] + selChip.rect[3] * 0.5), at: 0.05)
        let sceneChip = selRT.frame(at: 0.06)
        #expect(selRT.currentCursor() == .pointer)
        let chipHoverFills = sceneChip.primitives.filter { $0.kind == .roundedRect && $0.fill == chipHover.simd4(srgb: sceneChip.srgbBlend) }
        #expect(chipHoverFills.count == 1)
        #expect(abs(chipHoverFills[0].rect.x - selChip.rect[0]) < 1.0 && abs(chipHoverFills[0].rect.z - selChip.rect[2]) < 1.0)
    }

    // MARK: - Highlight Marks, ScrollIntoView, Overflow & 2000 Scale (markdown_blocks_and_highlights.rs #117-#120, #122; markdown_find.rs #134)

    @MainActor
    @Test("tests/markdown_blocks_and_highlights.rs & markdown_find.rs: mark nodes, scrollIntoView, overflow/link click, streaming UTF-8 edges, and 2000 marks add 0 layout nodes (#117-#120, #122, #134)")
    func highlightMarksScrollAndScaleParity() {
        let kit = Kit.neutral(dark: true)

        // #118: tall document + scrollIntoView to body default key & deep code block custom key
        var tallDoc = "# Searchable Document\n\n"
        for i in 0..<25 {
            tallDoc.append("Paragraph \(i) with filler words to push later content below the fold.\n\n")
        }
        tallDoc.append("Paragraph with the first_target_match in body text.\n\n```rust\n")
        for i in 0..<30 {
            tallDoc.append("let line_\(i) = \(i);\n")
        }
        tallDoc.append("let deep_code_target = 42;\n```\n")

        let nsTall = tallDoc as NSString
        let r1 = Range(nsTall.range(of: "first_target_match"))!
        let r2 = Range(nsTall.range(of: "deep_code_target"))!

        let scrollRT = Runtime<Int>(state: 0, viewport: Vec2(480, 200), pixelScale: 1.0, systemDark: true) { _, _ in
            col().key("doc-scroll").wFull().h(200).scrollXY().child(
                Markdown(tallDoc)
                    .highlights([(ranges: [r1], style: .match()), (ranges: [r2], style: .match().current(true).key("code-hit"))])
                    .build(kit)
            )
        }
        _ = scrollRT.frame(at: 0.0)
        let y1Init = scrollRT.element(byKey: Markdown.highlightKey(0))?.rect[1] ?? 0
        let y2Init = scrollRT.element(byKey: "code-hit")?.rect[1] ?? 0
        #expect(y1Init > 300 && y2Init > y1Init + 250)

        scrollRT.update(at: 0.01) { _, tx in tx.scrollIntoView(Markdown.highlightKey(0)) }
        var st = 0.02
        for _ in 0..<60 { st += 1.0 / 60.0; _ = scrollRT.frame(at: st) }
        let m1Rect = scrollRT.element(byKey: Markdown.highlightKey(0))?.rect ?? []
        #expect(m1Rect.count == 4 && m1Rect[1] >= -1 && m1Rect[1] + m1Rect[3] <= 205)

        scrollRT.update(at: st) { _, tx in tx.scrollIntoView("code-hit") }
        for _ in 0..<60 { st += 1.0 / 60.0; _ = scrollRT.frame(at: st) }
        let m2Rect = scrollRT.element(byKey: "code-hit")?.rect ?? []
        #expect(m2Rect.count == 4 && m2Rect[1] >= -1 && m2Rect[1] + m2Rect[3] <= 205)

        // #119, #120, #134: UTF-8 edges, huge offset never wraps, mark over link does not block link clicks, unsorted/overlapping multi-range
        struct LinkClickState { var opened: [String] = [] }
        let edgeSrc = "~~https://example.org/path~~ and שלום world"
        let linkRT = Runtime<LinkClickState>(state: LinkClickState(), viewport: Vec2(320, 200), pixelScale: 1.0, systemDark: true) { _, _ in
            col().wFull().children([
                Markdown(edgeSrc)
                    .selectable(true)
                    .highlights([(ranges: [20..<24, 2..<26], style: .match().current(true).key("hit"))])
                    .onLink { s, url, _ in s.opened.append(url) }
                    .build(kit),
                text("plain").textHighlights([TextHighlight((Int(UInt32.max) + 1)..<(Int(UInt32.max) + 5), bg: .white, key: "outside")]),
            ])
        }
        _ = linkRT.frame(at: 0.0)
        #expect(linkRT.element(byKey: "outside") == nil)
        if let linkEl = linkRT.elements().first(where: { $0.role == .link && $0.key == "https://example.org/path" }) {
            let p = Vec2(linkEl.rect[0] + linkEl.rect[2] * 0.5, linkEl.rect[1] + linkEl.rect[3] * 0.5)
            linkRT.pointerMove(to: p, at: 0.01)
            linkRT.pointerDown(at: p, at: 0.01)
            linkRT.pointerUp(at: p, at: 0.01)
            _ = linkRT.frame(at: 0.02)
            #expect(linkRT.state.opened == ["https://example.org/path"])
        }

        // #122: 2000 matches add 0 layout Element nodes (only virtual #mark-k ElementInfo projections)
        let blockLine = "needle needle needle needle with some fictional filler words.\n\n"
        let twoKSrc = String(repeating: blockLine, count: 500)
        var needleRanges: [Range<Int>] = []
        let twoKBytes = Array(twoKSrc.utf8)
        let needleBytes = Array("needle".utf8)
        var idx = 0
        while idx <= twoKBytes.count - needleBytes.count {
            if twoKBytes[idx..<(idx + needleBytes.count)].elementsEqual(needleBytes) {
                needleRanges.append(idx..<(idx + needleBytes.count))
                idx += needleBytes.count
            } else {
                idx += 1
            }
        }
        #expect(needleRanges.count == 2000)

        let scaleRT = Runtime<Bool>(state: false, viewport: Vec2(480, 200), pixelScale: 1.0, systemDark: true) { marked, _ in
            let hls: [(ranges: [Range<Int>], style: MarkdownHighlight)] = marked
                ? needleRanges.map { ([$0], .match()) }
                : []
            return col().w(480).h(200).scrollXY().child(Markdown(twoKSrc).highlights(hls).build(kit))
        }
        _ = scaleRT.frame(at: 0.0)
        let nonMarkCountBefore = scaleRT.elements().filter { $0.role != .mark }.count
        scaleRT.update(at: 0.01) { s, _ in s = true }
        _ = scaleRT.frame(at: 0.02)
        let elsAfter = scaleRT.elements()
        #expect(elsAfter.filter { $0.role != .mark }.count == nonMarkCountBefore)
        #expect(elsAfter.filter { $0.role == .mark }.count == 2000)
        #expect(elsAfter.contains(where: { $0.key == Markdown.highlightKey(1999) }))

        // #117 (`markdown_blocks_and_highlights.rs:408-517`): multi-block + syntax byte mapping without reshaping glyphs,
        // syntax-only omissions, cross-block highlight ("linked text." / "Second"), & active ring rect.
        let hlDoc = """
        # Heading Alpha

        Plain **bold token** and `inline_code` plus ~~struck_word~~ and [linked text](https://example.org/hidden).

        Second paragraph continues here.

        - list item one
        - [x] task needle done

        > quoted thoughts

        | Col A | Col B |
        |---|---|
        | cell_alpha | cell_beta |

        ```rust
        fn compute(value: i32) -> i32 {
            value + 1
        }
        ```
        """
        func byteRange(_ needle: String) -> Range<Int> {
            let r = hlDoc.range(of: needle)!
            return hlDoc.utf8.distance(from: hlDoc.startIndex, to: r.lowerBound)..<hlDoc.utf8.distance(from: hlDoc.startIndex, to: r.upperBound)
        }
        let boldStarsOffset = byteRange("**bold").lowerBound
        let linkDestOffset = byteRange("(https://example.org/hidden)").lowerBound
        let hlItems: [(ranges: [Range<Int>], style: MarkdownHighlight)] = [
            ([byteRange("Alpha")], .match()),
            ([byteRange("Plain **bold")], .match()),
            ([byteRange("inline_code")], .match()),
            ([byteRange("struck")], .match()),
            ([byteRange("linked text](https://example.org/hidden).\n\nSecond")], .match()),
            ([byteRange("item one")], .match()),
            ([byteRange("needle")], .match()),
            ([byteRange("thoughts")], .match()),
            ([byteRange("cell_beta")], .match()),
            ([byteRange("compute(value")], .match().current(true).key("active-match")),
            ([boldStarsOffset..<(boldStarsOffset + 2)], .match().key("syntax-only-stars")),
            ([linkDestOffset..<(linkDestOffset + "(https://example.org/hidden)".utf8.count)], .match().key("syntax-only-url")),
        ]
        let ringColor = Color(r: 0.96, g: 0.62, b: 0.04, a: 1.0)
        let hlStyle = MarkdownStyle.fromKit(kit)
            .highlightBg(Color(r: 0.92, g: 0.70, b: 0.03, a: 0.22))
            .highlightCurrent(bg: Color(r: 0.96, g: 0.62, b: 0.04, a: 0.40), fg: nil, ring: (ringColor, 1.5))

        func renderHL(_ hls: [(ranges: [Range<Int>], style: MarkdownHighlight)]) -> (Runtime<Int>, RefScene) {
            let r = Runtime<Int>(state: 0, viewport: Vec2(520, 900), pixelScale: 1.0, systemDark: true) { _, _ in
                col().w(520).child(Markdown(hlDoc).highlights(hls).render(hlStyle))
            }
            return (r, r.frame(at: 0.0))
        }
        let (_, plainScene) = renderHL([])
        let (hlRT, hlScene) = renderHL(hlItems)
        let plainGlyphs = plainScene.primitives.filter { $0.kind == .glyph }.map { ($0.rect, $0.uv) }
        let hlGlyphs = hlScene.primitives.filter { $0.kind == .glyph }.map { ($0.rect, $0.uv) }
        #expect(plainGlyphs.count == hlGlyphs.count && zip(plainGlyphs, hlGlyphs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 })

        let markPairs = hlRT.elements().filter { $0.role == .mark }.map { ($0.key ?? "", $0.label ?? "") }
        for (k, lbl) in [
            (Markdown.highlightKey(0), "Alpha"),
            (Markdown.highlightKey(1), "Plain bold"),
            (Markdown.highlightKey(2), "inline_code"),
            (Markdown.highlightKey(3), "struck"),
            (Markdown.highlightKey(5), "item one"),
            (Markdown.highlightKey(6), "needle"),
            (Markdown.highlightKey(7), "thoughts"),
            (Markdown.highlightKey(8), "cell_beta"),
            ("active-match", "compute(value"),
        ] {
            #expect(markPairs.contains(where: { $0.0 == k && $0.1 == lbl }), "Missing mark (\(k), \(lbl)) in \(markPairs)")
        }
        let crossLabels = markPairs.filter { $0.0 == Markdown.highlightKey(4) }.map(\.1)
        #expect(crossLabels == ["linked text.", "Second"])
        #expect(!markPairs.contains(where: { $0.0.hasPrefix("syntax-only") }))

        let wantRing = ringColor.simd4(srgb: hlScene.srgbBlend)
        let ringed = hlScene.primitives.filter { $0.kind == .roundedRect && abs($0.params.x - 1.5) < 0.01 && $0.border == wantRing }
        #expect(ringed.count == 1)
    }

    // MARK: - Selection, Tabs & Quote Copy (markdown_select.rs #149, #151, #152; markdown_copy_source.rs #157)

    @MainActor
    @Test("tests/markdown_select.rs & markdown_copy_source.rs: uncopied code padding (#149), aligned tabs copying as \\t (#151), quote+list+code plain text copy (#152, #157)")
    func selectionUncopiedTabsAndQuoteCopyParity() {
        let kit = Kit.neutral(dark: true)

        // #149: inline code double-click stops at padding and copies cleanly without padding
        let codePadRT = Runtime<Int>(state: 0, viewport: Vec2(480, 200), pixelScale: 2.0, systemDark: true) { _, _ in
            col().wFull().p(10).child(Markdown("Run `cargo test` now").selectable(true).build(kit).key("m0"))
        }
        var t = 0.0
        _ = codePadRT.frame(at: t)
        let g149 = Self.glyphCenters(codePadRT, pathContains: "m0/@b0")
        try? #require(g149.count >= 6)
        let wordPt = Vec2(g149[4].x, g149[4].y)
        for _ in 0..<2 {
            t += 0.02
            codePadRT.pointerMove(to: wordPt, at: t)
            codePadRT.pointerDown(at: wordPt, at: t)
            codePadRT.pointerUp(at: wordPt, at: t)
            _ = codePadRT.frame(at: t)
        }
        #expect(codePadRT.selectedText() == "cargo")
        _ = codePadRT.keyDown(KeyEvent(key: .command("a"), mods: RuneKitTestKey.primaryMods()), at: t + 0.02)
        #expect(codePadRT.selectedText() == "Run cargo test now")

        // #151: tabs line up on 4-column stops with space-indented pairs and copy back as `\t`
        let tabCode = "\tif x {\n    if x {\n\t\treturn\n        return\n  \tgo\n    go\nab\tc\nab  c"
        let tabSrc = "```go\n\(tabCode)\n```\n"
        let tabRT = Runtime<Int>(state: 0, viewport: Vec2(480, 400), pixelScale: 2.0, systemDark: true) { _, _ in
            col().wFull().p(10).child(Markdown(tabSrc).selectable(true).build(kit).key("m0"))
        }
        _ = tabRT.frame(at: 0.0)
        let tabBoxRect = tabRT.element(byKey: "b0")?.rect ?? []
        var lines: [[Float]] = []
        var lastY = Float.nan
        for (gx, gy) in Self.glyphXs(tabRT, in: tabBoxRect) {
            if lastY.isNaN || abs(gy - lastY) > 8.0 {
                lines.append([])
                lastY = gy
            }
            lines[lines.count - 1].append(gx)
        }
        #expect(lines.count == 8)
        for idx in stride(from: 0, to: lines.count, by: 2) where idx + 1 < lines.count {
            #expect(lines[idx].count == lines[idx + 1].count)
            for (ax, bx) in zip(lines[idx], lines[idx + 1]) {
                #expect(abs(ax - bx) < 0.75)
            }
        }
        tabRT.update(at: 0.02) { _, tx in tx.selectAllText("b0") }
        _ = tabRT.frame(at: 0.03)
        _ = tabRT.keyDown(KeyEvent(key: .command("c"), mods: RuneKitTestKey.primaryMods()), at: 0.03)
        #expect(tabRT.clipboard.text == tabCode)

        // #152 & #157: quote with paragraphs, nested lists & code copies clean plain text; single item copies without marker; drag across items includes marker
        let quoteSrc = "Before.\n\n> First `para` here.\n>\n> Second para.\n>\n> - one\n> - two\n>   - nested\n> 1. first\n> 2. second\n\n```\nlet a = 1;\nlet b = 2;\n```\n\nAfter.\n"
        let quoteRT = Runtime<Int>(state: 0, viewport: Vec2(480, 800), pixelScale: 2.0, systemDark: true) { _, _ in
            col().wFull().p(10).child(Markdown(quoteSrc).selectable(true).build(kit).key("m0"))
        }
        var qt = 0.0
        _ = quoteRT.frame(at: qt)
        quoteRT.update(at: qt + 0.01) { _, tx in tx.selectAllText("m0") }
        qt += 0.02
        _ = quoteRT.frame(at: qt)
        _ = quoteRT.keyDown(KeyEvent(key: .command("c"), mods: RuneKitTestKey.primaryMods()), at: qt)
        #expect(quoteRT.clipboard.text == "Before.\n\nFirst para here.\n\nSecond para.\n\n- one\n- two\n  - nested\n\n1. first\n2. second\n\nlet a = 1;\nlet b = 2;\n\nAfter.")

        // Single list item copies without its bullet marker; drag across two items emits `\n- two`
        let oneTextEl = quoteRT.elements().first(where: { $0.role == .text && ($0.text ?? "").contains("one") })
        let twoTextEl = quoteRT.elements().first(where: { $0.role == .text && ($0.text ?? "").contains("two") })
        let oneGlyphs = Self.glyphCenters(quoteRT, in: oneTextEl?.rect ?? [])
        let twoGlyphs = Self.glyphCenters(quoteRT, in: twoTextEl?.rect ?? [])
        #expect(oneGlyphs.count >= 3 && twoGlyphs.count >= 3)
        if twoGlyphs.count >= 3 {
            Self.drag(quoteRT, from: Vec2(twoGlyphs[0].x - 1, twoGlyphs[0].y), to: Vec2(twoGlyphs[2].x + 3, twoGlyphs[2].y), t: &qt)
            #expect(quoteRT.selectedText() == "two")
        }
        if oneGlyphs.count >= 3 && twoGlyphs.count >= 3 {
            Self.drag(quoteRT, from: Vec2(oneGlyphs[1].x - 1, oneGlyphs[1].y), to: Vec2(twoGlyphs[2].x + 3, twoGlyphs[2].y), t: &qt)
            #expect(quoteRT.selectedText() == "ne\n- two")
        }
    }

    // MARK: - Link Menu Routing & ContextMenu Key (tests/markdown_link_menu.rs #162-#164)

    @MainActor
    @Test("tests/markdown_link_menu.rs: right-click row fallback (#162), Key.contextMenu bottom-left (#163), cross-link drag suppression (#164)")
    func linkContextMenuParity() {
        struct MenuState {
            var selectable: Bool
            var linkMenus: [(url: String, x: Float, y: Float)] = []
            var rowMenus: Int = 0
            var opened: [String] = []
        }
        let kit = Kit.neutral(dark: true)

        func makeRT(selectable: Bool) -> Runtime<MenuState> {
            Runtime<MenuState>(state: MenuState(selectable: selectable), viewport: Vec2(480, 200), pixelScale: 2.0, systemDark: true) { s, _ in
                col().wFull().p(10)
                    .child(
                        Markdown("Hello there and [link](https://x.dev/a) and [other](https://x.dev/b).")
                            .selectable(s.selectable)
                            .onLink { st, url, _ in st.opened.append(url) }
                            .onLinkSecondary { st, url, _ in st.linkMenus.append((url, 0, 0)) }
                            .build(kit)
                    )
                    .onSecondaryClick { st, _, _ in st.rowMenus += 1 }
            }
        }

        // #162: selectable false & true both deliver link secondary menu and fall back to row menu on plain text
        for sel in [false, true] {
            let rt = makeRT(selectable: sel)
            _ = rt.frame(at: 0.0)
            let link = rt.elements().first(where: { $0.role == .link && $0.key == "https://x.dev/a" })!
            let center = Vec2(link.rect[0] + link.rect[2] * 0.5, link.rect[1] + link.rect[3] * 0.5)
            rt.pointerMove(to: center, at: 0.01)
            _ = rt.frame(at: 0.02)
            #expect(rt.currentCursor() == .pointer)

            rt.pointerDown(at: center, button: .secondary, at: 0.03)
            rt.pointerUp(at: center, button: .secondary, at: 0.03)
            _ = rt.frame(at: 0.04)
            #expect(rt.state.linkMenus.map(\.url) == ["https://x.dev/a"])
            #expect(rt.state.rowMenus == 0 && rt.state.opened.isEmpty)

            rt.pointerDown(at: Vec2(16, center.y), button: .secondary, at: 0.05)
            rt.pointerUp(at: Vec2(16, center.y), button: .secondary, at: 0.05)
            _ = rt.frame(at: 0.06)
            #expect(rt.state.rowMenus == 1)
            #expect(rt.state.linkMenus.count == 1)
        }

        // #163: Tab focuses first link, Key.contextMenu emits press at bottom-left of link without triggering row menu
        let menuKeyRT = Runtime<MenuState>(state: MenuState(selectable: false), viewport: Vec2(480, 200), pixelScale: 2.0, systemDark: true) { _, _ in
            let mdEl: El<MenuState> = Markdown("Hello there and [link](https://x.dev/a) and [other](https://x.dev/b).")
                .onLink { _, _, _ in }
                .onLinkSecondary { st, url, press, _ in
                    st.linkMenus.append((url, press.window.x, press.window.y))
                }
                .build(kit)
            return col().wFull().p(10)
                .child(mdEl)
                .onSecondaryClick { st, _, _ in st.rowMenus += 1 }
        }
        _ = menuKeyRT.frame(at: 0.0)
        _ = menuKeyRT.keyDown(KeyEvent(key: .tab), at: 0.01)
        _ = menuKeyRT.frame(at: 0.02)
        let focusedLink = menuKeyRT.elements().first(where: { $0.role == ElementRole.link && $0.key == "https://x.dev/a" })!
        #expect(focusedLink.focused)
        _ = menuKeyRT.keyDown(KeyEvent(key: .contextMenu), at: 0.03)
        _ = menuKeyRT.frame(at: 0.04)
        #expect(menuKeyRT.state.rowMenus == 0)
        #expect(menuKeyRT.state.linkMenus.count == 1)
        if let firstMenu = menuKeyRT.state.linkMenus.first {
            #expect(firstMenu.url == "https://x.dev/a")
            #expect(abs(firstMenu.x - focusedLink.rect[0]) < 1.0)
            #expect(abs(firstMenu.y - (focusedLink.rect[1] + focusedLink.rect[3])) < 1.0)
        }

        // #164: secondary-down on link A dragged onto link B opens no menu; fresh secondary click on B opens B's menu
        let dragRT = makeRT(selectable: false)
        _ = dragRT.frame(at: 0.0)
        let lA = dragRT.elements().first(where: { $0.role == .link && $0.key == "https://x.dev/a" })!
        let lB = dragRT.elements().first(where: { $0.role == .link && $0.key == "https://x.dev/b" })!
        let cA = Vec2(lA.rect[0] + lA.rect[2] * 0.5, lA.rect[1] + lA.rect[3] * 0.5)
        let cB = Vec2(lB.rect[0] + lB.rect[2] * 0.5, lB.rect[1] + lB.rect[3] * 0.5)
        dragRT.pointerDown(at: cA, button: .secondary, at: 0.01)
        dragRT.pointerMove(to: cB, at: 0.02)
        dragRT.pointerUp(at: cB, button: .secondary, at: 0.03)
        _ = dragRT.frame(at: 0.04)
        #expect(dragRT.state.linkMenus.isEmpty && dragRT.state.rowMenus == 0)
        dragRT.pointerDown(at: cB, button: .secondary, at: 0.05)
        dragRT.pointerUp(at: cB, button: .secondary, at: 0.05)
        _ = dragRT.frame(at: 0.06)
        #expect(dragRT.state.linkMenus.map(\.url) == ["https://x.dev/b"])
    }

    // MARK: - Diff Visible File & 50k Benchmark + Docs Accessibility (diff.rs #182, #186; a11y/docs.rs #198)

    @MainActor
    @Test("tests/diff.rs & tests/a11y/docs.rs: DiffView onVisibleFile scroll, 50k diff timing (#182, #186), and full markdown_reads_as_a_document + actions (#198)")
    func diffScrollBenchmarkAndDocsA11yParity() {
        let kit = Kit.neutral(dark: true)

        // #182 + S2#204/#163/#177/#192: DiffView.onVisibleFile fires when scrolling across files; singleColumn & scrollToLine work
        let patch = """
        diff --git a/alpha.swift b/alpha.swift
        --- a/alpha.swift
        +++ b/alpha.swift
        @@ -1,3 +1,10 @@
        +line 1
        +line 2
        +line 3
        +line 4
        +line 5
        +line 6
        +line 7
        diff --git a/beta.swift b/beta.swift
        --- a/beta.swift
        +++ b/beta.swift
        @@ -1,2 +1,12 @@
        +beta 1
        +beta 2
        +beta 3
        +beta 4
        +beta 5
        +beta 6
        +beta 7
        +beta 8
        +beta 9
        +beta 10
        """
        var dState = DiffState(files: FileDiff.parse(patch))
        let lineRange = DiffLineRange.line(DiffLineRef(side: .new, line: 1))
        #expect(lineRange.contains(DiffLineRef(side: .new, line: 1)))
        dState.setMode(.unified)
        #expect(dState.mode == DiffMode.unified)
        let onlyNewDiff = DiffState(diff: FileDiff.fromTexts(path: "only.swift", old: "", new: "a\nb\n"), mode: .split)
        #expect(onlyNewDiff.singleColumn() == .new)
        var scrollTx = Tx()
        dState.scrollToLine(0, at: DiffLineRef(side: .new, line: 3), keyPrefix: "dv", tx: &scrollTx)
        #expect(dState.visibleFile == 0)

        struct DiffHost: Sendable {
            var diff: DiffState
            var visibleSeen: [Int] = []
        }
        let dRT = Runtime<DiffHost>(state: DiffHost(diff: DiffState(files: FileDiff.parse(patch))), viewport: Vec2(500, 140), pixelScale: 1.0, systemDark: true) { s, cx in
            col().wFull().h(140).child(
                DiffView<DiffHost>(key: "dv", kit: kit, get: { $0.diff }, set: { $0.diff = $1 })
                    .viewportHeight(140)
                    .onVisibleFile { host, fileIdx in host.visibleSeen.append(fileIdx) }
                    .build(state: s, cx: cx)
            )
        }
        _ = dRT.frame(at: 0.0)
        var dt = 0.02
        for _ in 0..<25 {
            dRT.wheel(WheelEvent(dx: 0, dy: -60), at: Vec2(100, 70), now: dt)
            dt += 1.0 / 60.0
            _ = dRT.frame(at: dt)
        }
        #expect(dRT.state.visibleSeen.contains(1) || dRT.state.diff.visibleFile == 1)

        // #186: 50,000-line scattered diff completes swiftly
        let fiftyK = 50_000
        let old50 = (0..<fiftyK).map { "line \($0)" }
        var new50 = old50
        for i in stride(from: 0, to: fiftyK, by: 500) {
            new50[i] = "modified \(i)"
        }
        let old50Str = old50.joined(separator: "\n")
        let new50Str = new50.joined(separator: "\n")
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let res = FileDiff.fromTexts(path: "huge.swift", old: old50Str, new: new50Str)
            #expect(res.additionsCount == 100 && res.deletionsCount == 100)
        }
        #expect(elapsed < .seconds(3))

        // #198: a11y/docs.rs `markdown_reads_as_a_document` full tree + actions
        let doc = """
        # Release notes

        Read [the guide](https://example.com/guide) first.

        ## Changes

        * [x] tests pass
        * [ ] docs

        - Faster start
        - Smaller downloads

        1. Update
        2. Restart

        ```rust
        fn main() {}
        ```

        > Quoted advice.

        | Name | Size |
        | --- | ---: |
        | app | 4 MB |
        """
        struct DocA11yState {
            var chosen: String?
            var taskChecked = false
        }
        let a11yRT = Runtime<DocA11yState>(state: DocA11yState(), viewport: Vec2(600, 800), pixelScale: 1.0, systemDark: true) { _, _ in
            col().w(600).child(
                Markdown(doc)
                    .onLink { st, url, _ in st.chosen = url }
                    .onTask { st, _, _, checked, _ in st.taskChecked = checked }
                    .build(kit)
                    .key("doc")
            )
        }
        _ = a11yRT.frame(at: 0.0)
        let json = a11yRT.accessibilityJSON(pretty: false)
        #expect(json.contains("\"Release notes\"") && json.contains("\"Changes\""))
        #expect(json.contains("\"link\"") && json.contains("\"the guide\""))
        #expect(json.contains("\"check-box\"") || json.contains("\"checkbox\""))
        #expect(json.contains("\"code\"") && json.contains("\"blockquote\""))
        #expect(json.contains("\"table\"") && json.contains("\"columnheader\"") && json.contains("\"gridcell\""))

        let els = a11yRT.elements()
        #expect(els.filter { $0.role == .list }.count == 3)
        #expect(els.filter { $0.role == .code }.count == 1)
        #expect(els.filter { $0.role == .blockquote }.count == 1)
        #expect(els.filter { $0.role == .table }.count == 1)
        #expect(!els.contains(where: { !$0.a11yHidden && ($0.text == "•" || $0.text == "1.") }))

        let linkEl = els.first(where: { $0.role == .link && $0.key == "https://example.com/guide" })
        #expect(linkEl != nil)
        if let linkEl {
            #expect(a11yRT.accessibilityAction(linkEl.path, .press, at: 0.02))
            _ = a11yRT.frame(at: 0.03)
            #expect(a11yRT.state.chosen == "https://example.com/guide")
        }
        let uncheckedBox = els.first(where: { $0.role == .checkbox && $0.label == "docs" })
        #expect(uncheckedBox != nil)
        if let uncheckedBox {
            #expect(a11yRT.accessibilityAction(uncheckedBox.path, .press, at: 0.04))
            _ = a11yRT.frame(at: 0.05)
            #expect(a11yRT.state.taskChecked)
        }
    }

    @MainActor
    @Test("tests/markdown_copy_source.rs #154: Runtime drag across blocks Cmd+C copies verbatim block source vs drawn text")
    func markdownCopySourceDragAndSelectAllParity() {
        let kit = Kit.neutral(dark: true)
        let src = "# Title\n\nHello **world** and [link](https://x.dev/a).\n\n- alpha\n- [x] beta\n\n```rust\nfn main() {}\n```\n\nLast *line*.\n"
        struct S: Sendable { var sourceCopy: Bool }

        func makeRT(sourceCopy: Bool) -> (Runtime<S>, Clipboard) {
            let board = Clipboard(kind: .memory)
            let rt = Runtime<S>(state: S(sourceCopy: sourceCopy), viewport: Vec2(480, 800), pixelScale: 2.0, systemDark: true) { s, _ in
                col().wFull().p(10).child(Markdown(src).selectable(true).copySource(s.sourceCopy).build(kit).key("note"))
            }
            rt.useClipboard(board)
            _ = rt.frame(at: 0.0)
            return (rt, board)
        }

        // 1. Select all + Cmd+C copies whole verbatim source when copySource(true), drawn text when false
        let (rtTrue, boardTrue) = makeRT(sourceCopy: true)
        rtTrue.update(at: 0.01) { _, tx in tx.selectAllText("note") }
        _ = rtTrue.frame(at: 0.02)
        #expect(rtTrue.selectedText()?.hasPrefix("Title\n\nHello world") == true)
        _ = rtTrue.keyDown(KeyEvent(key: .text("c"), mods: RuneKitTestKey.primaryMods()), at: 0.03)
        _ = rtTrue.frame(at: 0.04)
        #expect((rtTrue.copyRequest ?? boardTrue.readRich().content.text) == src)

        let (rtFalse, boardFalse) = makeRT(sourceCopy: false)
        rtFalse.update(at: 0.01) { _, tx in tx.selectAllText("note") }
        _ = rtFalse.frame(at: 0.02)
        _ = rtFalse.keyDown(KeyEvent(key: .text("c"), mods: RuneKitTestKey.primaryMods()), at: 0.03)
        _ = rtFalse.frame(at: 0.04)
        #expect((rtFalse.copyRequest ?? boardFalse.readRich().content.text) == "Title\n\nHello world and link.\n\n- alpha\n- [x] beta\n\nfn main() {}\n\nLast line.")

        // 2. Drag across blocks note/b1 .. note/b4 + Cmd+C copies exact touched-blocks Markdown source
        let (dragRT, dragBoard) = makeRT(sourceCopy: true)
        let b1 = dragRT.elements().first(where: { $0.path.hasSuffix("@note/@b1") })!
        let b4 = dragRT.elements().first(where: { $0.path.hasSuffix("@note/@b4") })!
        let x0 = b1.rect[0] + 30
        let y0 = b1.rect[1] + b1.rect[3] * 0.5
        let x1 = b4.rect[0] + 10
        let y1 = b4.rect[1] + b4.rect[3] * 0.5
        dragRT.pointerMove(to: Vec2(x0, y0), at: 0.02)
        dragRT.pointerDown(at: Vec2(x0, y0), at: 0.02)
        _ = dragRT.frame(at: 0.03)
        for k in 1...6 {
            let f = Float(k) / 6.0
            dragRT.pointerMove(to: Vec2(x0 + (x1 - x0) * f, y0 + (y1 - y0) * f), at: 0.03 + Double(k) * 0.01)
            _ = dragRT.frame(at: 0.035 + Double(k) * 0.01)
        }
        dragRT.pointerUp(at: Vec2(x1, y1), at: 0.10)
        _ = dragRT.frame(at: 0.11)
        #expect(dragRT.selectedText()?.contains("alpha") == true)
        _ = dragRT.keyDown(KeyEvent(key: .text("c"), mods: RuneKitTestKey.primaryMods()), at: 0.12)
        _ = dragRT.frame(at: 0.13)
        let expectedRange = String(src.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect((dragRT.copyRequest ?? dragBoard.readRich().content.text) == expectedRange)
    }
}
