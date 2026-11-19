import Foundation
import Testing
@testable import RuneKit
@testable import Rune
import RuneMotion

@Suite("RuneKit Upstream Parity Closeout (#1122, #1130, #1133, Diff & TabStrip)")
struct RuneKitParityCloseoutTests {

    // MARK: - Helpers

    private func maxListDepth(in blocks: [MarkdownDocBlock]) -> Int {
        var best = 0
        var stack: [([MarkdownDocBlock], Int)] = [(blocks, 0)]
        while let (cur, depth) = stack.popLast() {
            for b in cur {
                switch b {
                case let .list(_, items):
                    let next = depth + 1
                    if next > best { best = next }
                    for item in items { stack.append((item, next)) }
                case let .quote(inner):
                    stack.append((inner, depth))
                default:
                    break
                }
            }
        }
        return best
    }

    private func maxQuoteDepth(in blocks: [MarkdownDocBlock]) -> Int {
        var best = 0
        var stack: [([MarkdownDocBlock], Int)] = [(blocks, 0)]
        while let (cur, depth) = stack.popLast() {
            for b in cur {
                switch b {
                case let .quote(inner):
                    let next = depth + 1
                    if next > best { best = next }
                    stack.append((inner, next))
                case let .list(_, items):
                    for item in items { stack.append((item, depth)) }
                default:
                    break
                }
            }
        }
        return best
    }

    private func findDeepTailMaps(in maps: [MarkdownBlockMap]) -> [Int] {
        var counts: [Int] = []
        var stack: [MarkdownBlockMap] = maps.reversed()
        while let m = stack.popLast() {
            switch m {
            case let .deepTail(lines, _):
                counts.append(lines)
            case let .quote(inner):
                for c in inner.reversed() { stack.append(c) }
            case let .list(items):
                for item in items.reversed() {
                    for c in item.reversed() { stack.append(c) }
                }
            default:
                break
            }
        }
        return counts
    }

    private func collectElements<S>(_ root: El<S>, matching predicate: (El<S>) -> Bool) -> [El<S>] {
        var out: [El<S>] = []
        var stack: [El<S>] = [root]
        while let node = stack.popLast() {
            if predicate(node) { out.append(node) }
            for child in node.children.reversed() { stack.append(child) }
        }
        return out
    }

    private func collectAllText<S>(_ root: El<S>) -> String {
        var parts: [String] = []
        var stack: [El<S>] = [root]
        while let node = stack.popLast() {
            if let t = node.plainText, !t.isEmpty {
                parts.append(t)
            } else if let spans = node.richSpans, !spans.isEmpty {
                parts.append(spans.map(\.text).joined())
            }
            for child in node.children.reversed() { stack.append(child) }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - 1. Markdown 511-Element Nesting Bound & Iterative Rendering (#1122)

    @Test("300 nested lists cap at 255 levels without stack overflow and preserve all text")
    func deeplyNestedLists300PreserveAllText() {
        let lines = (0..<300).map { k in
            String(repeating: "  ", count: k) + "- item-\(k)"
        }
        let src = lines.joined(separator: "\n") + "\n"
        let doc = MarkdownParser.parseDocument(src)
        #expect(maxListDepth(in: doc.blocks) == 255)
        // 300 - 255 = 45 flattened items <= 64, so no deep-tail grouping needed yet
        #expect(findDeepTailMaps(in: doc.maps).isEmpty)

        let kit = Kit.neutral(dark: false)
        let el: El<Int> = Markdown(src).selectable(true).build(kit)
        let renderedText = collectAllText(el)
        #expect(renderedText.contains("item-0"))
        #expect(renderedText.contains("item-254"))
        #expect(renderedText.contains("item-255"))
        #expect(renderedText.contains("item-299"))

        // Search and plain text preserve every leaf iteratively
        #expect(!MarkdownFind.findAll(in: src, doc: doc, query: "item-299").isEmpty)
        let plain = MarkdownPlain.render(doc)
        #expect(plain.contains("item-0") && plain.contains("item-299"))
    }

    @Test("350 nested lists group past 64 flattened items into one lossless deep-tail card with unselectable marker")
    func deeplyNestedLists350EmitLosslessDeepTail() throws {
        let lines = (0..<350).map { k in
            String(repeating: "  ", count: k) + "- listleaf-\(k)"
        }
        let src = lines.joined(separator: "\n") + "\n"
        let doc = MarkdownParser.parseDocument(src)
        #expect(maxListDepth(in: doc.blocks) == 255)
        let tails = findDeepTailMaps(in: doc.maps)
        #expect(tails == [31]) // 350 - 255 - 64 = 31

        let kit = Kit.neutral(dark: false)
        let root: El<Int> = Markdown(src).selectable(true).build(kit)
        let deepTailCards = collectElements(root) { el in
            el.children.contains(where: { $0.keyId == "more" })
        }
        #expect(deepTailCards.count == 1)
        let card = try #require(deepTailCards.first)
        let marker = try #require(collectElements(card) { $0.keyId == "more" }.first)
        #expect(marker.role == .group)
        #expect(marker.a11yLabel == RuneLabels.shared.label(for: .moreNestedLines(31)))
        #expect(marker.a11yLabel == "31 more nested lines")
        // The marker text itself must remain unselectable
        #expect(!marker.isSelectable)
        for child in marker.children {
            #expect(!child.isSelectable)
        }
        // The deep-tail body chunk must be selectable and preserve every trailing line without doubled bullets
        let chunk = try #require(collectElements(card) { $0.keyId == "c0" }.first)
        #expect(chunk.isSelectable)
        let chunkText = collectAllText(chunk)
        #expect(chunkText.contains("- listleaf-319"))
        #expect(chunkText.contains("- listleaf-349"))
        #expect(!chunkText.contains("- - listleaf-319"))

        // Find and MarkdownRendered locate text inside the deep tail accurately
        let matches = MarkdownFind.findAll(in: src, doc: doc, query: "listleaf-349")
        #expect(matches.count == 1)
        let rendered = MarkdownRendered(src)
        #expect(rendered.find(src, "listleaf-349", .sensitive).count == 1)

        // Plain text keeps all lines without crashing
        let plain = MarkdownPlain.render(doc)
        #expect(plain.contains("listleaf-0"))
        #expect(plain.contains("listleaf-318"))
        #expect(plain.contains("listleaf-319"))
        #expect(plain.contains("listleaf-349"))
    }

    @Test("520 and 600 nested block quotes cap at 510 levels, preserve bullets/tasks, and emit deep-tail marker past 64")
    func deeplyNestedBlockQuotes520And600() throws {
        // 520 pure nested block quotes -> capped at 510 nested quotes, leaf text preserved
        let q520 = String(repeating: "> ", count: 520) + "deep-quote-leaf\n"
        let doc520 = MarkdownParser.parseDocument(q520)
        #expect(maxQuoteDepth(in: doc520.blocks) == 510)
        #expect(findDeepTailMaps(in: doc520.maps).isEmpty)

        final class QuoteCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String] = []
            func append(_ s: String) { lock.lock(); values.append(s); lock.unlock() }
            func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let kit = Kit.neutral(dark: false)
        let captured = QuoteCollector()
        let el520: El<Int> = Markdown(q520)
            .selectable(true)
            .quoteFrame { q, ctx in
                captured.append(ctx.text)
                return q
            }
            .build(kit)
        let capturedQuotes = captured.snapshot()
        #expect(collectAllText(el520).contains("deep-quote-leaf"))
        #expect(capturedQuotes.count == 510)
        #expect(capturedQuotes.first == "deep-quote-leaf")
        #expect(capturedQuotes.last == "deep-quote-leaf")

        // 600 nested block quotes with a line at every level -> 510 nested + 64 flattened + 26 deep-tail lines
        let q600Lines = (0..<600).map { k in
            String(repeating: "> ", count: k + 1) + "qline-\(k)"
        }
        let q600 = q600Lines.joined(separator: "\n") + "\n"
        let doc600 = MarkdownParser.parseDocument(q600)
        #expect(maxQuoteDepth(in: doc600.blocks) == 510)
        #expect(findDeepTailMaps(in: doc600.maps) == [26]) // 600 - 510 - 64 = 26
        let el600: El<Int> = Markdown(q600).selectable(true).build(kit)
        let marker = try #require(collectElements(el600) { $0.keyId == "more" }.first)
        #expect(marker.a11yLabel == "26 more nested lines")
        #expect(!MarkdownFind.findAll(in: q600, doc: doc600, query: "qline-599").isEmpty)
        #expect(!MarkdownFind.findAll(in: q600, doc: doc600, query: "qline-574").isEmpty)

        // Bullets and task checkboxes inside 515 nested block quotes remain real lists & checkboxes
        let deepTaskQuote = String(repeating: "> ", count: 515) + "- [x] deep-checked\n"
            + String(repeating: "> ", count: 515) + "- deep-bullet\n"
        let taskDoc = MarkdownParser.parseDocument(deepTaskQuote)
        #expect(maxQuoteDepth(in: taskDoc.blocks) == 510)
        #expect(maxListDepth(in: taskDoc.blocks) == 1)
        #expect(taskDoc.tasks.compactMap { $0 }.first?.checked == true)
        let taskEl: El<Int> = Markdown(deepTaskQuote).build(kit)
        #expect(collectElements(taskEl) { $0.role == .checkbox }.count == 1)
        #expect(collectElements(taskEl) { $0.role == .listItem }.count == 1)
    }

    @Test("WASI / unguarded 770 flex-container cap bounds pure quotes at 385 while keeping 255 nested lists")
    func unguardedLayoutCap385QuotesAnd255Lists() {
        let q420 = String(repeating: "> ", count: 420) + "wasi-leaf\n"
        let docQuotes = MarkdownParser.parseDocument(q420, autolink: true, unguardedLayoutLimit: MarkdownParser.maxUnguardedLayoutDepth)
        #expect(maxQuoteDepth(in: docQuotes.blocks) == 385)
        #expect(MarkdownPlain.render(docQuotes).contains("wasi-leaf"))

        let l260 = (0..<260).map { k in String(repeating: "  ", count: k) + "- w-\(k)" }.joined(separator: "\n") + "\n"
        let docLists = MarkdownParser.parseDocument(l260, autolink: true, unguardedLayoutLimit: MarkdownParser.maxUnguardedLayoutDepth)
        #expect(maxListDepth(in: docLists.blocks) == 255)
        #expect(MarkdownPlain.render(docLists).contains("w-259"))
    }

    @Test("Deep neutral quotes detect inner RTL direction iteratively and streaming extends EOF deep tail incrementally")
    func deepBidiAndStreamingEofDeepTail() {
        let rtlDeep = String(repeating: "> ", count: 520) + "مرحبا\n"
        let doc = MarkdownParser.parseDocument(rtlDeep)
        #expect(MarkdownBidi.blocksDirection(doc.blocks) == .rtl)

        // Streaming EOF deep-tail extension avoids full reparse when appending more deep-tail lines
        let cache = MarkdownDocCache(budgetBytes: 4 << 20)
        let baseLines = (0..<330).map { k in String(repeating: "  ", count: k) + "- tok-\(k)" }
        let s1 = baseLines.joined(separator: "\n") + "\n"
        let d1 = cache.streamCached(s1)
        #expect(findDeepTailMaps(in: d1.maps) == [11]) // 330 - 255 - 64 = 11
        let parsesBefore = cache.fullParseCount

        let s2 = s1 + String(repeating: "  ", count: 330) + "- tok-330\n"
        let d2 = cache.streamCached(s2)
        #expect(cache.fullParseCount == parsesBefore)
        #expect(cache.incrementalExtendCount >= 1)
        #expect(findDeepTailMaps(in: d2.maps) == [12])
        #expect(MarkdownPlain.render(d2).contains("tok-330"))
    }

    // MARK: - 2. Markdown Settled Block / Item / Code-Card / Table-Row Memoization & Per-Row Table Widths (#1130)

    @Test("Settled blocks, list items, closed code cards, and table rows memoise across streaming commits")
    @MainActor
    func settledMarkdownStreamingMemoization() {
        struct StreamState {
            var src: String
        }
        let kit = Kit.neutral(dark: true)
        let settledPrefix = """
        # Heading

        Settled paragraph with **bold** and `inline`.

        - settled item one
        - settled item two
        - open item

        ```swift
        let fixed = 42
        ```

        | Col A | Col B |
        | --- | --- |
        | r0a | r0b |
        | r1a | r1b |

        Open trailing
        """

        let rt = Runtime(state: StreamState(src: settledPrefix), viewport: Vec2(640, 480)) { state, _ in
            Markdown(state.src)
                .streaming(true)
                .codeFrame { card, _ in col().key("wrap").wFull().child(card) }
                .build(kit)
        }

        Markdown.resetBlockBuilds()
        _ = rt.frame(at: 0.0)
        let initialBuilds = Markdown.blockBuilds
        #expect(initialBuilds > 0)

        // Append tokens to the open trailing paragraph -> every settled block, list item, closed code card,
        // and table row must reuse its memoised El subtree (0 new settled builds!).
        Markdown.resetBlockBuilds()
        rt.update(at: 0.05) { state, _ in
            state.src += " streaming token"
        }
        _ = rt.frame(at: 0.05)
        #expect(Markdown.blockBuilds == 0)

        rt.update(at: 0.10) { state, _ in
            state.src += " more words"
        }
        _ = rt.frame(at: 0.10)
        #expect(Markdown.blockBuilds == 0)

        // Verify PreBlock.heapBytes counts nested allocations and stays 0 on a bare paragraph
        let bareDoc = MarkdownParser.parseDocument("Plain paragraph.")
        let bareMeta = MarkdownMemoMeta.precomputeBlocks(bareDoc.blocks, maps: bareDoc.maps)
        #expect(bareMeta.count == 1 && bareMeta[0].heapBytes() == 0)

        let richDoc = MarkdownParser.parseDocument(settledPrefix)
        let richMeta = MarkdownMemoMeta.precomputeBlocks(richDoc.blocks, maps: richDoc.maps)
        #expect(richMeta.reduce(0) { $0 + $1.heapBytes() } > 0)
    }

    @Test("Streaming a Markdown table measures only each newly settled row (O(1) per row)")
    @MainActor
    func perRowTableWidthCaching() {
        struct TableStream {
            var src: String
        }
        let kit = Kit.neutral(dark: true)
        Markdown.resetTableWidthCaches()

        let headerAndFirst = """
        | Metric | Value |
        | --- | ---: |
        | Alpha | 100 |
        | Beta | 20
        """
        let rt = Runtime(state: TableStream(src: headerAndFirst), viewport: Vec2(640, 360)) { state, _ in
            Markdown(state.src).streaming(true).build(kit)
        }
        _ = rt.frame(at: 0.0)
        // Header + settled row 0 ("Alpha") measured -> 2 row measurements (open row "Beta" excluded)
        let afterFirst = Markdown.tableRowMeasurements
        #expect(afterFirst == 2)

        // Finish row 1 ("Beta") and start open row 2 ("Gamma") -> ONLY row 1 is measured (+1!)
        rt.update(at: 0.05) { state, _ in
            state.src += "0 |\n| Gamma | 30"
        }
        _ = rt.frame(at: 0.05)
        let afterSecond = Markdown.tableRowMeasurements
        #expect(afterSecond == afterFirst + 1)

        // Finish row 2 ("Gamma") and start open row 3 ("Delta") -> ONLY row 2 is measured (+1!)
        rt.update(at: 0.10) { state, _ in
            state.src += "0 |\n| Delta | 40"
        }
        _ = rt.frame(at: 0.10)
        let afterThird = Markdown.tableRowMeasurements
        #expect(afterThird == afterSecond + 1)

        // Appending within the still-open row 3 measures 0 rows (WIDTHS table hit!)
        rt.update(at: 0.15) { state, _ in
            state.src += "5"
        }
        _ = rt.frame(at: 0.15)
        #expect(Markdown.tableRowMeasurements == afterThird)
    }

    // MARK: - 3. Markdown Code Blocks `.byLine()` (#1133)

    @Test("Markdown code blocks mark their text element with .byLine() while paragraphs do not")
    func markdownCodeBlocksEmitByLine() throws {
        let kit = Kit.neutral(dark: true)
        let src = """
        Regular paragraph.

        ```swift
        let first = 1
        let second = 2
        ```
        """
        for scrollWide in [false, true] {
            let root: El<Int> = Markdown(src).scrollWide(scrollWide).selectable(true).build(kit)
            let codeFrames = collectElements(root) { $0.role == .code }
            #expect(codeFrames.count == 1)
            let codeFrame = try #require(codeFrames.first)
            let byLineNodes = collectElements(codeFrame) { $0.isByLine }
            #expect(byLineNodes.count == 1)

            // Paragraph block b0 should NOT be marked byLine
            let paraBlock = try #require(collectElements(root) { $0.keyId == "b0" }.first)
            #expect(!paraBlock.isByLine)
        }
    }

    // MARK: - 4. Diff Split Comment Buttons, Sigils & Stretch Parity

    @Test("Diff header uses Unicode minus sigil, suppresses zero counts, and split rows stretch with per-pane comment buttons")
    @MainActor
    func diffSigilsAndSplitCommentButtons() throws {
        struct Host {
            var diff: DiffState
            var commented: [DiffLineRange] = []
        }
        let patch = """
        diff --git a/old.swift b/new.swift
        similarity index 80%
        rename from old.swift
        rename to new.swift
        old mode 100644
        new mode 100755
        --- a/old.swift
        +++ b/new.swift
        @@ -1,3 +1,3 @@
         keep
        -short old
        +a much longer replacement line that wraps across multiple visual lines in narrow split panes so the opposite pane stretches
         tail
        """
        let file = try #require(FileDiff.parse(patch).first)
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(state: Host(diff: DiffState(diff: file, mode: .split)), viewport: Vec2(420, 320), pixelScale: 1) { state, cx in
            DiffView(key: "d", kit: kit, state: \Host.diff)
                .onComment { s, range, _ in s.commented.append(range) }
                .build(state: state, cx: cx)
        }
        _ = rt.frame(at: 0.0)

        // Header stats use Unicode minus "−" and header a11y label includes renamed-from & mode change
        let adds = try #require(rt.element(byKey: "d-adds"))
        let dels = try #require(rt.element(byKey: "d-dels"))
        #expect(adds.text == "+1")
        #expect(dels.text == "−1")
        #expect(rt.element(byKey: "d-mode-change")?.text == "100644 → 100755")
        let header = try #require(rt.element(byKey: "d-header"))
        #expect(header.label == "new.swift, renamed from old.swift, 1 added, 1 removed")

        // Added-only file omits zero deletion count
        let addedOnly = FileDiff.patch(old: nil, new: "hello\n", path: "added.swift")
        let rtAdded = Runtime(state: Host(diff: DiffState(diff: addedOnly, mode: .split)), viewport: Vec2(420, 200)) { state, cx in
            DiffView(key: "a", kit: kit, state: \Host.diff)
                .onComment { s, range, _ in s.commented.append(range) }
                .build(state: state, cx: cx)
        }
        _ = rtAdded.frame(at: 0.0)
        #expect(rtAdded.element(byKey: "a-adds")?.text == "+1")
        #expect(rtAdded.element(byKey: "a-dels") == nil)
        #expect(rtAdded.element(byKey: "a-an-0-plus") != nil)

        // Wrapped split pair row stretches both panes and divider to match the taller side
        let splitRow = try #require(rt.element(byKey: "d-srow-1"))
        let divider = try #require(rt.element(byKey: "d-srow-1-divider"))
        #expect(splitRow.rect[3] > DiffLayout.lineHeight)
        #expect(abs(divider.rect[3] - splitRow.rect[3]) < 0.5)

        // Split pair row exposes independent comment buttons for old and new panes
        let oldPlus = try #require(rt.element(byKey: "d-so-1-plus"))
        let newPlus = try #require(rt.element(byKey: "d-sn-1-plus"))
        #expect(oldPlus.opacity < 0.01 && newPlus.opacity < 0.01)

        // Hovering old pane reveals ONLY old comment button; clicking comments on old line 2
        let oldCode = try #require(rt.element(byKey: "d-scode-o-1"))
        rt.pointerMove(to: Vec2(oldCode.rect[0] + 20, oldCode.rect[1] + 8), at: 0.1)
        _ = rt.frame(at: 0.1)
        _ = rt.frame(at: 0.5)
        #expect(try #require(rt.element(byKey: "d-so-1-plus")).opacity > 0.99)
        #expect(try #require(rt.element(byKey: "d-sn-1-plus")).opacity < 0.01)
        let oldBtnPt = Vec2(oldPlus.rect[0] + 8, oldPlus.rect[1] + 8)
        rt.pointerDown(at: oldBtnPt, at: 0.6)
        rt.pointerUp(at: oldBtnPt, at: 0.61)
        _ = rt.frame(at: 0.62)
        #expect(rt.state.commented == [.line(DiffLineRef(side: .old, line: 2))])
    }

    // MARK: - 5. TabStrip Lifted Drag Visuals, Floating Ghost Layer & Cross-Window Reattachment

    @Test("TabDragState tears out, closes sibling gap, reattaches within reattachDistance, and supports handOff reattach")
    func tabDragStateReattachAndGapClosing() {
        let spec = TearOutSpec(threshold: 36, reattachDistance: 24)
        var drag = TabDragState()
        drag.press(id: "t0", index: 0, at: Vec2(40, 20), grab: Vec2(12, 10))

        // Drag 50pt down -> detaches past 36pt threshold
        let detach = drag.follow(to: Vec2(40, 70), orientation: .horizontal, tabSize: 100, count: 3, tearOut: spec)
        #expect(drag.isTornOut)
        #expect(drag.tearOffset == Vec2(0, 50))
        #expect(drag.grabPoint == Vec2(12, 10))
        if case .tornOut(let tear) = detach {
            #expect(tear.id == "t0" && tear.index == 0 && tear.offset == Vec2(0, 50))
        } else {
            Issue.record("Expected .tornOut outcome")
        }
        // Siblings after torn-out tab close the gap by -pitch
        #expect(drag.shift(forIndex: 1, itemExtent: 100) == -100)
        #expect(drag.shift(forIndex: 2, itemExtent: 100) == -100)

        // Move back to 30pt (> 24pt reattachDistance) -> stays torn out
        let stillOut = drag.follow(to: Vec2(40, 50), orientation: .horizontal, tabSize: 100, count: 3, tearOut: spec)
        #expect(drag.isTornOut)
        if case .tearMoved(let mv) = stillOut {
            #expect(mv.torn && !mv.insideStrip)
        } else {
            Issue.record("Expected .tearMoved while still detached")
        }

        // Move back to 10pt (<= 24pt reattachDistance) over strip -> reattaches into .dragging!
        let reattached = drag.follow(to: Vec2(140, 30), orientation: .horizontal, tabSize: 100, count: 3, tearOut: spec)
        #expect(drag.isDragging && !drag.isTornOut)
        if case .tearMoved(let mv) = reattached {
            #expect(!mv.torn && mv.insideStrip)
        } else {
            Issue.record("Expected .tearMoved(insideStrip: true) on reattach")
        }
        if case let .dragging(_, from, to, _) = drag.phase {
            #expect(from == 0 && to == 1)
        } else {
            Issue.record("Expected .dragging after reattachment")
        }

        // Tear out again, hand off to own window, verify gap stays closed and reattach still works
        _ = drag.follow(to: Vec2(40, 80), orientation: .horizontal, tabSize: 100, count: 3, tearOut: spec)
        #expect(drag.isTornOut)
        drag.handOff()
        #expect(drag.handedOff && drag.isHandedOffTearOut && !drag.isTornOut)
        #expect(drag.shift(forIndex: 1, itemExtent: 100) == -100)
        let redock = drag.follow(to: Vec2(40, 25), orientation: .horizontal, tabSize: 100, count: 3, tearOut: spec)
        #expect(drag.isDragging && !drag.handedOff && !drag.isHandedOffTearOut)
        if case .tearMoved(let mv) = redock {
            #expect(!mv.torn && mv.insideStrip)
        } else {
            Issue.record("Expected .tearMoved(insideStrip: true) after handOff reattach")
        }
    }

    @Test("TabStrip.buildLayered mounts floating lifted ghost on tear-out, hides slot, and opens incoming gap by window point")
    @MainActor
    func tabStripLayeredGhostAndIncomingPoint() throws {
        struct AppState {
            var dragA = TabDragState()
            var dragB = TabDragState()
            var tearMoves: [TabTearMove] = []
            var tornOuts: [TabTearOut] = []
        }
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(state: AppState(), viewport: Vec2(480, 260)) { state, _ in
            var layer: [El<AppState>] = []
            let stripA = TabStrip<AppState>(key: "sa", orientation: .horizontal)
                .tabs([
                    StripTabItem(id: "a0", title: "Alpha"),
                    StripTabItem(id: "a1", title: "Beta"),
                    StripTabItem(id: "a2", title: "Gamma"),
                ])
                .active("a0")
                .availableWidth(460)
                .dragState(\.dragA, current: state.dragA)
                .tearOut(TearOutSpec(threshold: 36, reattachDistance: 24))
                .onReorder { _, _, _ in }
                .onTearMove { s, mv, _ in s.tearMoves.append(mv) }
                .onTearOut { s, tear, _ in s.tornOuts.append(tear) }
                .buildLayered(state, kit: kit, layer: &layer)

            let stripB = TabStrip<AppState>(key: "sb", orientation: .horizontal)
                .tabs([
                    StripTabItem(id: "b0", title: "One"),
                    StripTabItem(id: "b1", title: "Two"),
                ])
                .active("b0")
                .availableWidth(460)
                .dragState(\.dragB, current: state.dragB)
                .build(state, kit: kit)

            return col().sizeFull().gap(80)
                .child(stripA)
                .child(stripB)
                .children(layer)
        }

        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 0.02)

        // Drag tab a0 down 80pt off stripA -> floating ghost mounts in overlay layer!
        let tabA0 = try #require(rt.element(byKey: "sa-tab-a0")).rect
        let start = Vec2(tabA0[0] + tabA0[2] * 0.5, tabA0[1] + tabA0[3] * 0.5)
        rt.pointerMove(to: start, at: 0.03)
        rt.pointerDown(at: start, at: 0.04)
        rt.pointerMove(to: Vec2(start.x, start.y + 80), at: 0.06)
        _ = rt.frame(at: 0.06)

        #expect(rt.state.dragA.isTornOut)
        #expect(rt.state.tearMoves.last?.torn == true)
        let ghost = try #require(rt.element(byKey: "sa-list-ghost"))
        let anchor = try #require(rt.element(byKey: "sa-list-anchor"))
        #expect(ghost.rect[2] > 0 && ghost.rect[3] > 0)
        #expect(anchor.rect[2] > 0)
        // Original tab slot is hidden while ghost flies
        let slotA0 = try #require(rt.element(byKey: "sa-tab-a0"))
        #expect(slotA0.opacity < 0.01)

        // Drag back within 10pt of stripA -> reattaches, ghost disappears, slot becomes visible again
        rt.pointerMove(to: Vec2(start.x, start.y + 10), at: 0.08)
        _ = rt.frame(at: 0.08)
        #expect(!rt.state.dragA.isTornOut && rt.state.dragA.isDragging)
        #expect(rt.state.tearMoves.last?.torn == false)
        #expect(rt.element(byKey: "sa-list-ghost") == nil)

        // Release dragA
        rt.pointerUp(at: Vec2(start.x, start.y + 10), at: 0.10)
        _ = rt.frame(at: 0.10)

        // Cross-window incoming landing by window point on stripB:
        // With 2 tabs + 1 incoming tab in 460pt, each tab shrinks to ~152pt (midpoints ~77 and ~231).
        let stripBRect = try #require(rt.element(byKey: "sb-scroll")).rect
        let midY = stripBRect[1] + stripBRect[3] * 0.5
        rt.update(at: 0.12) { s, _ in
            s.dragB.setIncoming(point: Vec2(stripBRect[0] + 20, midY))
        }
        _ = rt.frame(at: 0.12)
        #expect(rt.state.dragB.incomingSlot() == 0)
        #expect(rt.element(byKey: "sb-list-incoming") != nil)

        rt.update(at: 0.13) { s, _ in
            s.dragB.setIncoming(point: Vec2(stripBRect[0] + 150, midY))
        }
        _ = rt.frame(at: 0.13)
        #expect(rt.state.dragB.incomingSlot() == 1)
        #expect(rt.element(byKey: "sb-list-incoming") != nil)

        rt.update(at: 0.135) { s, _ in
            s.dragB.setIncoming(point: Vec2(stripBRect[0] + 350, midY))
        }
        _ = rt.frame(at: 0.135)
        #expect(rt.state.dragB.incomingSlot() == 2)

        // Leaving stripB closes the incoming gap
        rt.update(at: 0.14) { s, _ in
            s.dragB.setIncoming(point: nil)
        }
        _ = rt.frame(at: 0.14)
        #expect(rt.state.dragB.incomingSlot() == nil)
        #expect(rt.element(byKey: "sb-list-incoming") == nil)
    }
}
