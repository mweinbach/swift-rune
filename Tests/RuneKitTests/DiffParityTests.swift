import Foundation
import Testing
@testable import RuneKit
import Rune

@Suite("RuneKit Diff Full Parity Tests (Increment 3)")
struct DiffParityTests {
    // Rust's diff test walks each /code container once. Wrapped code has a separate text child.
    private func isCodeCell(_ element: ElementInfo) -> Bool {
        guard !element.exiting, let key = element.key, !key.hasSuffix("-text") else { return false }
        return ["dv-code-", "dv-scode-", "dv-ccode-", "dv-dcode-", "dv-acode-"].contains(where: key.hasPrefix)
    }

    // MARK: - Myers (`diff/myers.rs`)

    @Test("Myers diff handles empty, identical, all-insert, all-delete, and reconstructs edits")
    func myersBasicAndReconstruction() {
        #expect(Myers.diff([Int](), [Int]()) == [])
        #expect(Myers.diff([1, 2, 3], [1, 2, 3]) == [.equal(3)])
        #expect(Myers.diff([Int](), [1, 2]) == [.insert(2)])
        #expect(Myers.diff([1, 2], [Int]()) == [.delete(2)])

        let a = Array("ABCABBA")
        let b = Array("CBABAC")
        let ops = Myers.diff(a, b)
        var reconstructed: [Character] = []
        var ai = 0
        var bi = 0
        for op in ops {
            switch op {
            case .equal(let n):
                for k in 0..<n {
                    #expect(a[ai + k] == b[bi + k])
                    reconstructed.append(a[ai + k])
                }
                ai += n
                bi += n
            case .delete(let n):
                ai += n
            case .insert(let n):
                reconstructed.append(contentsOf: b[bi..<(bi + n)])
                bi += n
            }
        }
        #expect(ai == a.count)
        #expect(bi == b.count)
        #expect(reconstructed == b)
    }

    @Test("Myers fallback respects MAX_D without blowing up on completely disjoint huge inputs")
    func myersFallbackAboveMaxD() {
        let a = Array(0..<2500)
        let b = Array(3000..<5500)
        let ops = Myers.diff(a, b)
        var ai = 0
        var bi = 0
        for op in ops {
            switch op {
            case .equal(let n): ai += n; bi += n
            case .delete(let n): ai += n
            case .insert(let n): bi += n
            }
        }
        #expect(ai == a.count)
        #expect(bi == b.count)
        #expect(ops == [.delete(2500), .insert(2500)])
    }

    // MARK: - Model & Fuzz (`diff/model.rs`)

    @Test("FileDiff produces multiple context hunks when changes are separated by > 2*context")
    func contextHunksSplitAndMerge() {
        let oldLines = (1...30).map { "line \($0)" }
        var newLines = oldLines
        newLines[1] = "line 2 edited"
        newLines[25] = "line 26 edited"

        let separate = FileDiff.between(
            old: oldLines.joined(separator: "\n"),
            new: newLines.joined(separator: "\n"),
            path: "sample.txt",
            context: 3
        )
        #expect(separate.hunks.count == 2)
        #expect(separate.hunks[0].oldStart == 1)
        #expect(separate.hunks[1].oldStart == 23)
        #expect(separate.additionsCount == 2)
        #expect(separate.deletionsCount == 2)
        #expect(separate.text(side: .old) == oldLines.joined(separator: "\n"))
        #expect(separate.text(side: .new) == newLines.joined(separator: "\n"))

        // Adjacent within 2 * context (line 2 and line 6) -> merges into 1 hunk
        var mergedNew = oldLines
        mergedNew[1] = "line 2 edited"
        mergedNew[5] = "line 6 edited"
        let merged = FileDiff.between(
            old: oldLines.joined(separator: "\n"),
            new: mergedNew.joined(separator: "\n"),
            path: "sample.txt",
            context: 3
        )
        #expect(merged.hunks.count == 1)
    }

    @Test("FileDiff.parse parses multi-file git patches with add, delete, rename, binary, and sections")
    func parseGitMultiFilePatch() {
        let patch = """
        diff --git a/src/a.rs b/src/a.rs
        index 111..222 100644
        --- a/src/a.rs
        +++ b/src/a.rs
        @@ -10,4 +10,5 @@ fn greet() {
         let x = 1;
        -let y = 2;
        +let y = 3;
        +let z = 4;
         return x + y;
        diff --git a/added.txt b/added.txt
        new file mode 100644
        --- /dev/null
        +++ b/added.txt
        @@ -0,0 +1,2 @@
        +hello
        +world
        diff --git a/removed.txt b/removed.txt
        deleted file mode 100644
        --- a/removed.txt
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -bye
        \\ No newline at end of file
        diff --git a/old_name.md b/new_name.md
        similarity index 95%
        rename from old_name.md
        rename to new_name.md
        --- a/old_name.md
        +++ b/new_name.md
        @@ -1,1 +1,1 @@
        -old title
        +new title
        diff --git a/logo.png b/logo.png
        Binary files a/logo.png and b/logo.png differ
        """

        let files = FileDiff.parse(patch)
        #expect(files.count == 5)

        #expect(files[0].status == .modified)
        #expect(files[0].path == "src/a.rs")
        #expect(files[0].hunks[0].section == "fn greet() {")
        #expect(files[0].additionsCount == 2)
        #expect(files[0].deletionsCount == 1)

        #expect(files[1].status == .added)
        #expect(files[1].soleSide == .new)
        #expect(files[1].text(side: .new) == "hello\nworld")

        #expect(files[2].status == .deleted)
        #expect(files[2].soleSide == .old)
        #expect(files[2].text(side: .old) == "bye")

        #expect(files[3].status == .renamed(from: "old_name.md"))
        #expect(files[3].oldPath == "old_name.md")
        #expect(files[3].newPath == "new_name.md")

        #expect(files[4].isBinary)
        #expect(files[4].hunks.isEmpty)
    }

    @Test("300 deterministic random diffs reconstruct new text from old + hunks cleanly")
    func fuzz300RandomDiffs() {
        var seed: UInt64 = 0x1234_5678_9ABC_DEF0
        func next(_ upper: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(max(1, upper)))
        }
        let vocab = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]

        for _ in 0..<300 {
            let nOld = next(40)
            let nNew = next(40)
            let oldLines = (0..<nOld).map { _ in vocab[next(vocab.count)] }
            let newLines = (0..<nNew).map { _ in vocab[next(vocab.count)] }
            let oldStr = oldLines.joined(separator: "\n")
            let newStr = newLines.joined(separator: "\n")

            let diff = FileDiff.between(old: oldStr, new: newStr, path: "fuzz.txt", context: 2)
            var state = DiffState(diff: diff)
            for gap in state.computeGaps() {
                state.expand(gapIndex: gap.index, direction: .all)
            }
            var reconstructedNew: [String] = []
            for row in state.rows() {
                if case .unified(let line, _, _) = row, line.kind != .deletion {
                    reconstructedNew.append(line.text)
                }
            }
            if newLines.isEmpty {
                #expect(diff.hunks.isEmpty || reconstructedNew.isEmpty)
            } else if !diff.hunks.isEmpty {
                // Full source text preserves exact equality
                #expect(diff.text(side: .new) == newStr)
                // Applied hunks preserve line counts
                let net = diff.additionsCount - diff.deletionsCount
                #expect(oldLines.count + net == newLines.count)
            } else {
                #expect(oldLines == newLines)
            }
        }
    }

    // MARK: - Word Diff & Split Pairs (`diff/words.rs` & `diff/pairs.rs`)

    @Test("DiffWords isolates single contiguous intra-line span and skips lines > 1000 UTF-16 code units")
    func wordDiffAndLineLengthCap() {
        let ranges = DiffWords.changedRanges(
            old: "let answer = compute(foo, bar);",
            new: "let result = compute(foo, baz);"
        )
        #expect(ranges.old.count == 1)
        #expect(ranges.new.count == 1)

        // Single-word Unicode identifier diff
        let uni = DiffWords.words(old: "let α = 1;", new: "let β = 1;")
        #expect(uni.old != nil && uni.new != nil)

        // BOM (0xFEFF) acts as whitespace token
        let bomOld = "\u{FEFF}let x = old;"
        let bomNew = "\u{FEFF}let x = new;"
        let bom = DiffWords.words(old: bomOld, new: bomNew)
        #expect(bom.old != nil && bom.new != nil)

        // Surrogate-pair UTF-16 length cap (> 1000 UTF-16 units)
        let hugeEmojiOld = String(repeating: "😀", count: 501) // 1002 UTF-16 code units
        let hugeEmojiNew = String(repeating: "🎉", count: 501)
        let capped = DiffWords.changedRanges(old: hugeEmojiOld, new: hugeEmojiNew)
        #expect(capped.old.isEmpty && capped.new.isEmpty)

        let hugeOld = String(repeating: "a", count: 1005)
        let hugeNew = String(repeating: "b", count: 1005)
        let cappedAscii = DiffWords.changedRanges(old: hugeOld, new: hugeNew)
        #expect(cappedAscii.old.isEmpty && cappedAscii.new.isEmpty)
    }

    @Test("DiffHunk.splitRows aligns contiguous blocks using Pierre similarity pairing")
    func splitRowsSimilarityPairing() {
        let old = """
        let count = items.len();
        completely_unrelated_old();
        """
        let new = """
        let count = items.count();
        something_else_entirely();
        added_extra_line();
        """
        let diff = FileDiff.between(old: old, new: new, path: "pair.rs")
        let rows = diff.hunks[0].splitRows()

        let hasPair = rows.contains { row in
            if case let .pair(o, n, oCh, nCh) = row {
                return o.text.contains("items.len") && n.text.contains("items.count") && !oCh.isEmpty && !nCh.isEmpty
            }
            return false
        }
        #expect(hasPair)

        // Contiguous block pairs min(2, 3) = 2 pairs and leaves 1 unmatched addition
        let unmatchedCount = rows.filter {
            if case .only(let l) = $0 { return l.kind != .context }
            return false
        }.count
        #expect(unmatchedCount == 1)

        // Shifted alignment: when new has an inserted line before a matching line, sliding offset pairs the similar line
        let shiftedOld = """
        // old comment
        let total = compute(alpha, beta, gamma);
        """
        let shiftedNew = """
        // leading banner line that differs completely
        let total = compute(alpha, delta, gamma);
        // trailing extra
        """
        let shiftedDiff = FileDiff.between(old: shiftedOld, new: shiftedNew, path: "shifted.rs")
        let shiftedRows = shiftedDiff.hunks[0].splitRows()
        let alignedSimilar = shiftedRows.contains { row in
            if case let .pair(o, n, _, _) = row {
                return o.text.contains("compute") && n.text.contains("compute")
            }
            return false
        }
        #expect(alignedSimilar)
    }

    // MARK: - DiffState Gaps, Selection, Copy & Annotations (`diff/state.rs`)

    @Test("DiffState expands gaps up/down/all and copies selected or full lines")
    func stateGapsSelectionAndCopy() {
        let oldLines = (1...60).map { "line \($0)" }
        var newLines = oldLines
        newLines[55] = "line 56 changed"

        let diff = FileDiff.between(
            old: oldLines.joined(separator: "\n"),
            new: newLines.joined(separator: "\n"),
            path: "long.swift",
            context: 3
        )
        var state = DiffState(diff: diff)
        let gapsBefore = state.computeGaps()
        #expect(gapsBefore.count == 2)
        #expect(gapsBefore[0].canStep)

        let initialCount = gapsBefore[0].count
        state.expand(gapIndex: 0, direction: .down)
        let gapsAfterStep = state.computeGaps()
        #expect(gapsAfterStep[0].count == initialCount - DiffLayout.expandStep)

        state.expand(gapIndex: 0, direction: .all)
        let gapsAfterAll = state.computeGaps()
        #expect(!gapsAfterAll.contains(where: { $0.index == 0 }))

        // Select two lines on new side and verify targeted copy
        state.select(DiffLineRange(
            start: DiffLineRef(side: .new, line: 56),
            end: DiffLineRef(side: .new, line: 57)
        ))
        #expect(state.copyText(side: .new) == "line 56 changed\nline 57")

        state.select(nil)
        #expect(state.copyText(side: .new).hasPrefix("line 1\n"))
    }

    @Test("DiffState inserts inline annotations and virtualizes large diffs")
    func stateAnnotationsAndVirtualization() {
        let oldLines = (1...400).map { "let v\($0) = \($0)" }
        var newLines = oldLines
        newLines[0] = "let v1 = 999"
        newLines[399] = "let v400 = 888"

        let diff = FileDiff.between(
            old: oldLines.joined(separator: "\n"),
            new: newLines.joined(separator: "\n"),
            path: "big.swift",
            context: 2
        )
        var state = DiffState(diff: diff, annotations: [
            DiffAnnotation(id: "c1", side: .new, line: 1, author: "rev", body: "Magic number?")
        ])
        for g in state.computeGaps() {
            state.expand(gapIndex: g.index, direction: .all)
        }
        let rows = state.rows()
        #expect(rows.count > 300)
        #expect(rows.contains { row in
            if case .annotation(let a) = row { return a.body == "Magic number?" }
            return false
        })

        let winTop = state.visibleWindow(for: rows, scrollY: 0, viewportHeight: 200)
        #expect(winTop.beforeHeight == 0)
        #expect(winTop.afterHeight > 0)
        #expect(winTop.range.count < rows.count)

        let winMid = state.visibleWindow(for: rows, scrollY: 3000, viewportHeight: 200)
        #expect(winMid.beforeHeight > 0)
        #expect(winMid.afterHeight > 0)
        #expect(winMid.range.lowerBound > 50)
    }

    // MARK: - Interactive DiffView Runtime Integration (`tests/diff.rs`)

    struct HostState: Sendable {
        var diff: DiffState
        var copied: String?
        var lastSelection: DiffLineRange?
        var activeTab: Int = 0
        var list: [DiffState] = []
    }

    @MainActor
    private func clickElement<State>(_ rt: Runtime<State>, key: String, at now: Double) -> Bool {
        guard let el = rt.element(byKey: key), el.rect.count == 4 else { return false }
        let pt = Vec2(el.rect[0] + el.rect[2] * 0.5, el.rect[1] + el.rect[3] * 0.5)
        rt.pointerMove(to: pt, at: now)
        _ = rt.frame(at: now)
        rt.pointerDown(at: pt, at: now)
        rt.pointerUp(at: pt, at: now + 0.01)
        return true
    }

    @Test("Unified diff gutters expose one comment per row and select the opposite line through an empty number column")
    @MainActor
    func unifiedGutterCommentAndEmptySelection() throws {
        let file = FileDiff.fromTexts(path: "example.txt", old: "first\nbefore\nlast\n", new: "first\nafter\nlast\n", context: 3)
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(state: HostState(diff: DiffState(diff: file)), viewport: Vec2(600, 400)) { state, cx in
            DiffView(key: "g", kit: kit, state: \HostState.diff)
                .onComment { state, lines, _ in state.lastSelection = lines }
                .build(state: state, cx: cx)
        }
        _ = rt.frame(at: 0)
        let buttons = rt.elements().compactMap(\.key).filter { $0.hasSuffix("-plus") }
        #expect(Set(buttons) == ["g-n-0-plus", "g-o-1-plus", "g-n-2-plus", "g-n-3-plus"])
        let gutter = try #require(rt.element(byKey: "g-gutter-0"))
        let button = try #require(rt.element(byKey: "g-n-0-plus"))
        #expect(abs(button.rect[0] - (gutter.rect[0] + gutter.rect[2] - 10)) < 1)
        #expect(abs(button.rect[1] - (gutter.rect[1] + 2)) < 1)
        #expect(button.rect[2] == 16 && button.rect[3] == 16)
        #expect(button.opacity < 0.01)
        let code = try #require(rt.element(byKey: "g-code-0"))
        rt.pointerMove(to: Vec2(code.rect[0] + 40, code.rect[1] + 10), at: 0.05)
        _ = rt.frame(at: 0.05)
        _ = rt.frame(at: 1)
        #expect(try #require(rt.element(byKey: "g-n-0-plus")).opacity > 0.99)
        #expect(try #require(rt.element(byKey: "g-o-1-plus")).opacity < 0.01)

        #expect(clickElement(rt, key: "g-n-1", at: 1.05))
        _ = rt.frame(at: 1.07)
        #expect(rt.state.diff.selectedRange == .line(DiffLineRef(side: .old, line: 2)))
        #expect(clickElement(rt, key: "g-o-2", at: 1.1))
        _ = rt.frame(at: 1.12)
        #expect(rt.state.diff.selectedRange == .line(DiffLineRef(side: .new, line: 2)))

        let oldRange = DiffLineRange(start: DiffLineRef(side: .old, line: 1), end: DiffLineRef(side: .old, line: 2))
        rt.state.diff.select(oldRange)
        rt.pointerMove(to: Vec2(code.rect[0] + 40, code.rect[1] + 10), at: 1.2)
        _ = rt.frame(at: 1.2)
        #expect(clickElement(rt, key: "g-n-0-plus", at: 1.25))
        _ = rt.frame(at: 1.27)
        #expect(rt.state.lastSelection == oldRange)
    }

    @Test("DiffView toggles fold/mode/wrap, expands gaps, and copies text through Runtime")
    @MainActor
    func diffViewInteractiveControls() throws {
        let oldLines = (1...50).map { "line \($0)" }
        var newLines = oldLines
        newLines[45] = "line 46 modified"
        let old = oldLines.joined(separator: "\n")
        let new = newLines.joined(separator: "\n")
        let diff = FileDiff.between(old: old, new: new, path: "Demo.swift")
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(
            state: HostState(diff: DiffState(diff: diff)),
            viewport: Vec2(800, 600)
        ) { state, cx in
            DiffView(key: "d", kit: kit, state: \HostState.diff)
                .onCopy { s, txt, _ in s.copied = txt }
                .onSelect { s, range, _ in s.lastSelection = range }
                .build(state: state, cx: cx)
        }
        rt.frame(at: 0)

        // Toggle mode Unified -> Split
        #expect(clickElement(rt, key: "d-mode", at: 0.1))
        rt.frame(at: 0.12)
        #expect(rt.state.diff.mode == .split)

        // Toggle wrap
        #expect(clickElement(rt, key: "d-wrap", at: 0.2))
        rt.frame(at: 0.22)
        #expect(rt.state.diff.wrap)

        // Expand gap
        let gapsBefore = rt.state.diff.computeGaps().count
        let expand = try #require(rt.element(byKey: "d-gap-0-all"))
        let pointer = Vec2(expand.rect[0] + expand.rect[2] / 2, expand.rect[1] + expand.rect[3] / 2)
        #expect(clickElement(rt, key: "d-gap-0-all", at: 0.3))
        rt.frame(at: 0.32)
        #expect(rt.state.diff.computeGaps().count < gapsBefore)

        // Expanding the gap puts the old pane under the stationary pointer.
        let left = try #require(rt.element(byKey: "d-ccode-o-0"))
        #expect(rt.hitTestElement(at: pointer)?.path.hasPrefix(left.path) == true)
        #expect(rt.state.diff.copySide == .old)
        #expect(clickElement(rt, key: "d-copy", at: 0.4))
        rt.frame(at: 0.42)
        #expect(rt.state.diff.copiedToastVisible)
        #expect(rt.state.copied == old)
        #expect(rt.clipboard.text == old)

        let right = try #require(rt.element(byKey: "d-ccode-n-0"))
        rt.pointerMove(to: Vec2(right.rect[0] + right.rect[2] / 2, right.rect[1] + right.rect[3] / 2), at: 0.43)
        rt.frame(at: 0.44)
        #expect(rt.state.diff.copySide == .new)
        #expect(clickElement(rt, key: "d-copy", at: 0.45))
        rt.frame(at: 0.47)
        #expect(rt.state.copied == new)
        #expect(rt.clipboard.text == new)

        // Fold toggle hides body
        #expect(clickElement(rt, key: "d-fold", at: 0.5))
        rt.frame(at: 0.52)
        #expect(!rt.state.diff.expanded)
        #expect(rt.element(byKey: "d-body") == nil)
    }

    @Test("Directed, cross-side selections copy the anchor side in document order")
    func directedDiffSelection() {
        let file = FileDiff.fromTexts(path: "x", old: "keep\nold one\nold two\nend\n",
                                      new: "keep\nnew one\nnew two\nend\n")
        var state = DiffState(files: [file, file])
        let old1 = DiffLineRef(side: .old, line: 1)
        let old2 = DiffLineRef(side: .old, line: 2)
        let old3 = DiffLineRef(side: .old, line: 3)
        let new2 = DiffLineRef(side: .new, line: 2)
        let new3 = DiffLineRef(side: .new, line: 3)
        let new4 = DiffLineRef(side: .new, line: 4)
        let new5 = DiffLineRef(side: .new, line: 5)
        let cases: [(DiffLineRef, DiffLineRef, String?, String?)] = [
            (old3, new2, "old two", "old one\nold two"),
            (new2, old3, "new one", "new one\nnew two"),
            (old3, old2, "old one\nold two", "old one\nold two"),
            (new4, old1, "keep\nnew one\nnew two\nend", "keep\nnew one\nnew two\nend"),
            (old2, new3, "old one\nold two", "old one\nold two"),
            (new5, old1, nil, nil)
        ]
        for mode in [DiffMode.unified, .split] {
            state.setMode(mode)
            for (from, to, unified, split) in cases {
                let range = DiffLineRange(file: 1, start: from, end: to)
                let expected = mode == .unified ? unified : split
                state.select(range)
                #expect(state.selectedRange?.start == from)
                #expect(state.selectedRange?.end == to)
                #expect(state.selectedText() == expected)
                var tx = Tx()
                let handled = state.key(KeyEvent(key: .command("c"), mods: RuneKitTestKey.primaryMods()), tx: &tx)
                #expect(handled == (expected != nil))
                #expect(tx.clipboardWrite?.text == expected)
            }
        }
        state.setMode(.unified)
        let directed = DiffLineRange(file: 1, start: old3, end: new2)
        #expect(state.contains(directed, at: old3))
        #expect(state.contains(directed, at: new2))
        #expect(!state.contains(directed, at: old2))
        #expect(!state.contains(directed, at: new3))
    }

    @Test("A unified gutter drag crosses replacements and keeps its original side when copying")
    @MainActor
    func gutterDragAcrossSides() throws {
        let diff = FileDiff.fromTexts(path: "x", old: "keep\nold one\nold two\nend\n",
                                      new: "keep\nnew one\nnew two\nend\n")
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(state: HostState(diff: DiffState(diff: diff)), viewport: Vec2(600, 320)) { state, cx in
            DiffView(key: "dv", kit: kit, state: \HostState.diff)
                .onSelect { s, range, _ in s.lastSelection = range }
                .build(state: state, cx: cx)
        }
        _ = rt.frame(at: 0)
        let old3 = DiffLineRef(side: .old, line: 3)
        let new2 = DiffLineRef(side: .new, line: 2)
        let rows = rt.state.diff.rows()
        let oldRow = try #require(rows.firstIndex { $0.lineRef(for: .unified) == old3 })
        let newRow = try #require(rows.firstIndex { $0.lineRef(for: .unified) == new2 })
        let startCell = try #require(rt.element(byKey: "dv-n-\(newRow)"))
        let endCell = try #require(rt.element(byKey: "dv-n-\(oldRow)"))
        let start = Vec2(startCell.rect[0] + 8, startCell.rect[1] + 8)
        let end = Vec2(endCell.rect[0] + 8, endCell.rect[1] + 8)
        rt.pointerDown(at: start, at: 0.1)
        rt.pointerMove(to: end, at: 0.2)
        rt.pointerUp(at: end, at: 0.3)
        _ = rt.frame(at: 0.3)
        #expect(rt.state.lastSelection == DiffLineRange(start: new2, end: old3))
        #expect(rt.state.diff.selectedText() == "new one")

        rt.state.diff.setMode(.split)
        rt.state.diff.select(nil)
        func settle(at t: Double) {
            rt.invalidate(at: t)
            for tick in 0...30 { _ = rt.frame(at: t + Double(tick) / 30) }
        }
        func colorDistance(_ a: Color, _ b: Color) -> Float {
            max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b), abs(a.a - b.a))
        }
        settle(at: 0.4)
        let paired = try #require(rt.state.diff.rows().firstIndex { $0.lineRef(for: .split, preferredSide: .old) == old3 })
        let oldKey = "dv-so-\(paired)"
        let newKey = "dv-sn-\(paired)"
        let oldFill = try #require(rt.element(byKey: oldKey)).fill
        let newFill = try #require(rt.element(byKey: newKey)).fill
        rt.state.diff.select(DiffLineRange(start: new2, end: old3))
        settle(at: 1.5)
        #expect(try colorDistance(#require(rt.element(byKey: oldKey)).fill, oldFill) > 0.05)
        #expect(try colorDistance(#require(rt.element(byKey: newKey)).fill, newFill) > 0.05)
        rt.state.diff.select(.line(old3))
        settle(at: 2.6)
        #expect(try colorDistance(#require(rt.element(byKey: oldKey)).fill, oldFill) > 0.05)
        #expect(try colorDistance(#require(rt.element(byKey: newKey)).fill, newFill) < 0.001)
    }

    @Test("DiffView gutter pointer press, shift-extend, and drag select ranges cleanly")
    @MainActor
    func diffViewGutterSelectionDrag() {
        let diff = FileDiff.between(
            old: "one\ntwo\nthree\nfour\nfive",
            new: "one\nTWO\nthree\nFOUR\nfive",
            path: "sel.txt"
        )
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(
            state: HostState(diff: DiffState(diff: diff)),
            viewport: Vec2(600, 400)
        ) { state, cx in
            DiffView(key: "dv", kit: kit, state: \HostState.diff)
                .onSelect { s, range, _ in s.lastSelection = range }
                .build(state: state, cx: cx)
        }
        rt.frame(at: 0)

        // Press & drag from row 0's new gutter down by ~2 lines (40px)
        guard let box0 = rt.element(byKey: "dv-n-0"), box0.rect.count == 4 else {
            Issue.record("Missing dv-n-0 gutter cell")
            return
        }
        let start = Vec2(box0.rect[0] + 8, box0.rect[1] + 8)
        rt.pointerDown(at: start, at: 0.1)
        rt.pointerMove(to: Vec2(start.x, start.y + 42), at: 0.15)
        rt.pointerUp(at: Vec2(start.x, start.y + 42), at: 0.2)
        rt.frame(at: 0.2)

        #expect(rt.state.lastSelection != nil)
        #expect(rt.state.lastSelection?.start.side == .new)
        #expect(rt.state.lastSelection?.start.line == 1)
        #expect((rt.state.lastSelection?.end.line ?? 0) >= 2)

        // Shift-click extends the selection on the same side to line 3 (row 3)
        if let box3 = rt.element(byKey: "dv-n-3"), box3.rect.count == 4 {
            let p3 = Vec2(box3.rect[0] + 8, box3.rect[1] + 8)
            rt.pointerDown(at: p3, mods: Mods(shift: true), at: 0.3)
            rt.pointerUp(at: p3, mods: Mods(shift: true), at: 0.35)
            rt.frame(at: 0.35)
            #expect(rt.state.lastSelection == DiffLineRange(
                start: DiffLineRef(side: .new, line: 1),
                end: DiffLineRef(side: .new, line: 3)
            ))
        } else {
            Issue.record("Missing dv-n-3 gutter cell for shift-extend")
        }
    }

    @Test("Kit.diffLayer and Kit.diffTabbed switch tabs and render multiple files")
    @MainActor
    func diffLayerAndTabbed() {
        let d1 = FileDiff.between(old: "a = 1", new: "a = 2", path: "one.swift")
        let d2 = FileDiff.between(old: "b = 1", new: "b = 2", path: "two.swift")
        let kit = Kit.neutral(dark: true)

        let rt = Runtime(
            state: HostState(
                diff: DiffState(diff: d1),
                list: [DiffState(diff: d1), DiffState(diff: d2)]
            ),
            viewport: Vec2(700, 500)
        ) { state, cx in
            El<HostState>(direction: .column)
                .child(kit.diffTabbed(
                    key: "tabs",
                    state: state,
                    cx: cx,
                    activeIndex: { $0.activeTab },
                    setActiveIndex: { $0.activeTab = $1 },
                    get: { $0.list },
                    set: { $0.list = $1 }
                ))
                .child(kit.diffLayer(
                    key: "layer",
                    state: state,
                    cx: cx,
                    get: { $0.list },
                    set: { $0.list = $1 }
                ))
        }
        rt.frame(at: 0)
        #expect(rt.element(byKey: "tabs-panel-0") != nil)
        #expect(clickElement(rt, key: "tabs-tab-1", at: 0.1))
        rt.frame(at: 0.1)
        #expect(rt.state.activeTab == 1)
        #expect(rt.element(byKey: "tabs-panel-1") != nil)
        #expect(rt.element(byKey: "layer-0") != nil)
        #expect(rt.element(byKey: "layer-1") != nil)
    }

    @Test("DiffFoldRow.lineInfo, binary files, and FileDiff.patch work cleanly")
    @MainActor
    func diffFoldRowBinaryAndPatch() {
        let added = FileDiff.patch(old: nil, new: "hello\nworld", path: "new.txt")
        #expect(added.status == .added)
        #expect(added.soleSide == .new)
        #expect(added.columns >= 2)

        let deleted = FileDiff.patch(old: "gone", new: nil, path: "old.txt")
        #expect(deleted.status == .deleted)
        #expect(deleted.soleSide == .old)

        let renamed = FileDiff.patch(old: "same\nline", new: "same\nchanged", path: "dst.txt", oldPath: "src.txt")
        #expect(renamed.status == .renamed(from: "src.txt"))

        let binary = FileDiff(oldPath: "a.bin", newPath: "a.bin", status: .modified, hunks: [], isBinary: true)
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(
            state: HostState(diff: DiffState(diff: renamed)),
            viewport: Vec2(600, 300)
        ) { state, cx in
            El<HostState>(direction: .column)
                .child(DiffView(key: "li", kit: kit, state: \HostState.diff)
                    .foldRow(.lineInfo)
                    .build(state: state, cx: cx))
                .child(kit.diffView(key: "bin", binary, style: .split))
        }
        rt.frame(at: 0)
        #expect(rt.element(byKey: "li-fold") != nil)
        #expect(rt.element(byKey: "bin") != nil)
    }

    @Test("Line-info fold buttons expand one step or the whole gap with Shift")
    func lineInfoFoldModifiers() throws {
        let old = (1...90).map { "line \($0)" }
        var new = old
        new[64] = "edited"
        let file = FileDiff.between(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"),
                                    path: "fold.txt", context: 1)
        for shift in [false, true] {
            let rt = Runtime(state: DiffState(diff: file), viewport: Vec2(640, 400)) { s, cx in
                DiffView<DiffState>(key: "fold", kit: .neutral(dark: true), get: { $0 }, set: { $0 = $1 })
                    .foldRow(.lineInfo).build(state: s, cx: cx)
            }
            rt.frame(at: 0)
            let hidden = try #require(rt.state.hidden(gap: 0))
            #expect(hidden > DiffLayout.expandStep)
            let button = try #require(rt.element(byKey: "fold-gap-0-up"))
            let point = Vec2(button.rect[0] + button.rect[2] / 2, button.rect[1] + button.rect[3] / 2)
            let mods = Mods(shift: shift)
            rt.pointerDown(at: point, mods: mods, at: 0.05)
            rt.pointerUp(at: point, mods: mods, at: 0.10)
            rt.frame(at: 0.11)
            #expect(rt.state.hidden(gap: 0) == (shift ? 0 : hidden - DiffLayout.expandStep))
        }

        let patch = "diff --git a/fold.txt b/fold.txt\n--- a/fold.txt\n+++ b/fold.txt\n@@ -50 +50 @@\n-old\n+new\n"
        let parsed = try #require(FileDiff.parse(patch).first)
        let rt = Runtime(state: DiffState(diff: parsed), viewport: Vec2(640, 400)) { s, cx in
            DiffView<DiffState>(key: "patch", kit: .neutral(dark: true), get: { $0 }, set: { $0 = $1 })
                .foldRow(.lineInfo).build(state: s, cx: cx)
        }
        rt.frame(at: 0)
        #expect(rt.element(byKey: "patch-gap-0")?.label == "0 unmodified lines")
        #expect(rt.element(byKey: "patch-gap-0-up") == nil)
    }

    // MARK: - Golden Tests Ported from `crates/rune-kit/tests/diff.rs`

    @Test("a_patch_parses_renames_modes_binaries_and_missing_newlines (tests/diff.rs)")
    func patchParsesRenamesModesBinariesAndMissingNewlines() {
        let patch = """
        diff --git a/old_name.rs b/new_name.rs
        similarity index 90%
        rename from old_name.rs
        rename to new_name.rs
        old mode 100644
        new mode 100755
        --- a/old_name.rs
        +++ b/new_name.rs
        @@ -1,2 +1,2 @@ fn greet()
        -let greeting = "hi"
        \\ No newline at end of file
        +let greeting = "hello"
        \\ No newline at end of file
        diff --git a/copy_src.txt b/copy_dst.txt
        similarity index 95%
        copy from copy_src.txt
        copy to copy_dst.txt
        --- a/copy_src.txt
        +++ b/copy_dst.txt
        @@ -1 +1 @@
        -old
        +new
        diff --git a/logo.png b/logo.png
        new file mode 100644
        index 0000000..1234567
        GIT binary patch
        literal 0
        HcmV?d00001
        diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"
        deleted file mode 100644
        --- "a/caf\\303\\251.txt"
        +++ /dev/null
        @@ -1 +0,0 @@
        -espresso
        """
        let files = FileDiff.parse(patch)
        #expect(files.count == 4)

        let f0 = files[0]
        #expect(f0.oldPath == "old_name.rs")
        #expect(f0.newPath == "new_name.rs")
        #expect(f0.status == .renamed(from: "old_name.rs"))
        #expect(f0.similarity == 90)
        #expect(f0.oldMode == "100644")
        #expect(f0.newMode == "100755")
        #expect(f0.hunks.first?.section == "fn greet()")
        #expect(f0.hunks[0].lines[0].noNewline)
        #expect(f0.hunks[0].lines[1].noNewline)
        #expect(!f0.hunks[0].lines[0].changes.isEmpty)
        #expect(f0.hunks[0].lines[0].pair == 1)
        #expect(f0.hunks[0].lines[1].pair == 0)

        let f1 = files[1]
        #expect(f1.status == .copied)
        #expect(f1.oldPath == "copy_src.txt")
        #expect(f1.newPath == "copy_dst.txt")
        #expect(f1.similarity == 95)

        let f2 = files[2]
        #expect(f2.isBinary)
        #expect(f2.status == .added)
        #expect(f2.newMode == "100644")

        let f3 = files[3]
        #expect(f3.status == .deleted)
        #expect(f3.oldPath == "café.txt")
    }

    @Test("two_texts_diff_into_hunks_with_word_changes (tests/diff.rs)")
    func twoTextsDiffIntoHunksWithWordChanges() {
        let diff = FileDiff.fromTexts(
            path: "sample.rs",
            old: "alpha\nbeta one\ngamma",
            new: "alpha\nbeta two\ngamma",
            context: 1
        )
        #expect(diff.status == .modified)
        #expect(diff.hunks.count == 1)
        let lines = diff.hunks[0].lines
        #expect(lines.count == 4)
        #expect(lines[1].kind == .deletion && lines[1].pair == 2 && !lines[1].changes.isEmpty)
        #expect(lines[2].kind == .addition && lines[2].pair == 1 && !lines[2].changes.isEmpty)
    }

    @Test("folded_ranges_open_twenty_lines_at_a_time (tests/diff.rs)")
    func foldedRangesOpenTwentyLinesAtATime() {
        let oldLines = (1...55).map { "line \($0)" }
        var newLines = oldLines
        newLines[49] = "line 50 edited"
        let diff = FileDiff.fromTexts(
            path: "long.txt",
            old: oldLines.joined(separator: "\n"),
            new: newLines.joined(separator: "\n"),
            context: 3
        )
        var st = DiffState(diff: diff)
        // Lines 1..46 are hidden in leading gap 0
        #expect(st.hidden(file: 0, gap: 0) == 46)
        st.expand(file: 0, gapIndex: 0, direction: .up)
        #expect(st.hidden(file: 0, gap: 0) == 26)
        #expect(st.effectiveHunks(file: 0)[0].lines.first?.text == "line 27")

        let unexpandable = FileDiff.parse("""
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -50,2 +50,2 @@
        -old
        +new
         ctx
        """)[0]
        let stPatch = DiffState(diff: unexpandable)
        #expect(stPatch.hidden(file: 0, gap: 0) == nil)
    }

    @Test("Multi-file DiffState navigation, hover copySide, onComment, custom builders, and noNewline/wrap rendering")
    @MainActor
    func multiFileNavigationHoverCommentAndViewParity() {
        let f1 = FileDiff.parse("""
        diff --git a/first.swift b/first.swift
        --- a/first.swift
        +++ b/first.swift
        @@ -1,2 +1,2 @@
        -let a = foo.bar(1)
        \\ No newline at end of file
        +let a = foo.baz(2)
        \\ No newline at end of file
        """)[0]
        let f2 = FileDiff.fromTexts(path: "second.swift", old: "x = 1", new: "x = 2")
        var state = DiffState(
            files: [f1, f2],
            annotations: [
                DiffAnnotation(id: "a1", file: 1, side: .new, line: 1, author: "rev", body: "check x")
            ]
        )
        #expect(state.fileIndex(path: "second.swift") == 1)

        var tx = Tx()
        #expect(state.key(KeyEvent(key: .text("]")), tx: &tx))
        #expect(state.visibleFile == 1)
        #expect(tx.scrollOffsetRequests.last?.key == "diff-df1")
        #expect(state.key(KeyEvent(key: .text("[")), tx: &tx))
        #expect(state.visibleFile == 0)

        state.select(DiffLineRange(
            start: DiffLineRef(side: .old, line: 1),
            end: DiffLineRef(side: .old, line: 1)
        ))
        let hoveredOld = state.hoverText(side: .old, cell: "c-old", inside: true)
        #expect(hoveredOld)
        #expect(state.copySide == .old)
        let otherModifier = KeyPlatform.current == .mac ? Mods(ctrl: true) : Mods(logo: true)
        #expect(!state.key(KeyEvent(key: .command("c"), mods: otherModifier), tx: &tx))
        let cmdCOld = state.key(KeyEvent(key: .command("c"), mods: RuneKitTestKey.primaryMods()), tx: &tx)
        #expect(cmdCOld)
        #expect(tx.clipboardWrite?.text == "let a = foo.bar(1)")
        _ = state.hoverText(side: .old, cell: "c-old", inside: false)
        let hoveredNew = state.hoverText(side: .new, cell: "c-new", inside: true)
        #expect(hoveredNew)
        #expect(state.copySide == .new)
        state.select(DiffLineRange(
            start: DiffLineRef(side: .new, line: 1),
            end: DiffLineRef(side: .new, line: 1)
        ))
        let cmdCNew = state.key(KeyEvent(key: .text("c"), mods: RuneKitTestKey.primaryMods()), tx: &tx)
        #expect(cmdCNew)
        #expect(tx.clipboardWrite?.text == "let a = foo.baz(2)")
        let escCleared = state.key(KeyEvent(key: .escape), tx: &tx)
        #expect(escCleared)
        #expect(state.selectedRange == nil)

        struct ViewHost: Sendable {
            var diff: DiffState
            var commented: DiffLineRange?
        }
        state.wrap = true
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(
            state: ViewHost(diff: state),
            viewport: Vec2(800, 600)
        ) { hs, cx in
            DiffView(key: "mv", kit: kit, state: \ViewHost.diff)
                .onComment { s, range, _ in s.commented = range }
                .annotation { _, ann in
                    El<ViewHost>(direction: .row).key("custom-note-\(ann.id)").child(text(ann.body))
                }
                .headerActions { _, idx in
                    El<ViewHost>(direction: .row).key("hdr-act-\(idx)").child(text("Extra"))
                }
                .build(state: hs, cx: cx)
        }
        rt.frame(at: 0)

        #expect(rt.element(byKey: "mv-header") != nil)
        #expect(rt.element(byKey: "mv-f1-header") != nil)
        #expect(rt.element(byKey: "hdr-act-0") != nil)
        #expect(rt.element(byKey: "custom-note-a1") != nil)

        // Click '+' comment button in line 1 deletion cell
        #expect(clickElement(rt, key: "mv-o-0-plus", at: 0.1))
        rt.frame(at: 0.12)
        #expect(rt.state.commented == .line(DiffLineRef(side: .old, line: 1)))
    }

    // MARK: - 1:1 Rust Parity Additions (`diff/model.rs`, `myers.rs`, `state.rs`, `view.rs`, `tests/diff.rs`)

    @Test("diff/model.rs: hunk_header_tracks_counts_and_section, three_lines_is_standard, no_newline_marker_is_captured")
    func diffModelHeadersContextAndNoNewline() {
        // #29 hunk header omits ,1 when oldCount/newCount == 1 and retains parsed section label
        let singlePatch = """
        diff --git a/a.rs b/a.rs
        --- a/a.rs
        +++ b/a.rs
        @@ -1 +1,2 @@ fn main()
        -a
        +a
        +b
        """
        let singleParsed = FileDiff.parse(singlePatch)
        #expect(singleParsed.count == 1)
        #expect(singleParsed[0].hunks[0].header == "@@ -1 +1,2 @@ fn main()")
        #expect(singleParsed[0].hunks[0].section == "fn main()")

        let computed = FileDiff.fromTexts(path: "a.rs", old: "a\n", new: "a\nb\n", context: 3)
        #expect(computed.hunks[0].header == "@@ -1 +1,2 @@")

        // #30 three_lines_is_standard: 6 unchanged lines between edits merge into 1 hunk; 7 split into 2
        let sixGapOld = (1...12).map { "L\($0)" }.joined(separator: "\n")
        var sixGapNewLines = (1...12).map { "L\($0)" }
        sixGapNewLines[1] = "X2"  // line 2
        sixGapNewLines[8] = "X9"  // line 9 -> lines 3..8 are 6 unchanged lines
        let merged = FileDiff.fromTexts(path: "g6.rs", old: sixGapOld, new: sixGapNewLines.joined(separator: "\n"), context: 3)
        #expect(merged.hunks.count == 1)

        let sevenGapOld = (1...13).map { "L\($0)" }.joined(separator: "\n")
        var sevenGapNewLines = (1...13).map { "L\($0)" }
        sevenGapNewLines[1] = "X2"  // line 2
        sevenGapNewLines[9] = "X10" // line 10 -> lines 3..9 are 7 unchanged lines
        let split = FileDiff.fromTexts(path: "g7.rs", old: sevenGapOld, new: sevenGapNewLines.joined(separator: "\n"), context: 3)
        #expect(split.hunks.count == 2)

        // #31 no_newline_marker_is_captured on old, new, and both sides
        let newBreak = FileDiff.fromTexts(path: "a", old: "one\ntwo", new: "one\ntwo\n")
        #expect(newBreak.hunks.first?.lines.map(\.kind) == [.context, .deletion, .addition])
        #expect(newBreak.hunks.first?.lines.map(\.noNewline) == [false, true, false])
        let bothMissing = FileDiff.fromTexts(path: "a", old: "one\ntwo", new: "one\nthree")
        #expect(bothMissing.hunks.first?.lines.map(\.noNewline) == [false, true, true])
        #expect(FileDiff.fromTexts(path: "a", old: "same", new: "same").hunks.isEmpty)
        #expect(FileDiff.fromTexts(path: "a", old: "one\r\ntwo\r\n", new: "one\ntwo\n").hunks.isEmpty)

        let noNewlinePatch = """
        diff --git a/nn.txt b/nn.txt
        --- a/nn.txt
        +++ b/nn.txt
        @@ -1,2 +1,2 @@
         keep
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """
        let nn = FileDiff.parse(noNewlinePatch)
        #expect(nn.count == 1)
        #expect(nn[0].hunks[0].lines[0].noNewline == false)
        #expect(nn[0].hunks[0].lines[1].noNewline == true)
        #expect(nn[0].hunks[0].lines[2].noNewline == true)
    }

    @Test("An existing empty file keeps its path and reports which side has text")
    func emptyVersionKeepsPath() {
        for (old, new, side) in [("", "x", DiffSide.new), ("x", "", .old)] {
            let file = FileDiff.fromTexts(path: "a.txt", old: old, new: new)
            #expect(file.status == .modified)
            #expect(file.oldPath == "a.txt" && file.newPath == "a.txt")
            #expect(file.soleSide == side)
            #expect(FileDiff.patch(old: old, new: new, path: "a.txt") == file)

            let renamed = FileDiff.patch(old: old, new: new, path: "b.txt", oldPath: "a.txt")
            #expect(renamed.status == .renamed(from: "a.txt"))
            #expect(renamed.oldPath == "a.txt" && renamed.newPath == "b.txt")
            #expect(renamed.soleSide == nil)
        }
        #expect(FileDiff.fromTexts(path: "a.txt", old: "", new: "").soleSide == nil)
        #expect(FileDiff.between(old: "", new: "x", path: "a.txt").status == .added)
        #expect(FileDiff.between(old: "x", new: "", path: "a.txt").status == .deleted)
    }

    @Test("A NUL on either side produces a binary diff and preserves file metadata")
    func binaryContentFromTexts() {
        let binary = "a\0b"
        for (old, new) in [(binary, ""), ("", binary), (binary, "c\0d")] {
            let file = FileDiff.fromTexts(path: "img.bin", old: old, new: new)
            #expect(file.isBinary)
            #expect(file.hunks.isEmpty)
            #expect(file.source == nil)
            #expect(file.soleSide == nil)
            #expect(file.status == .modified)
            #expect(file.oldPath == "img.bin")
            #expect(file.newPath == "img.bin")
        }

        let added = FileDiff.patch(old: nil, new: binary, path: "img.bin")
        #expect(added.isBinary && added.status == .added)
        #expect(added.oldPath == "/dev/null" && added.newPath == "img.bin")
        let deleted = FileDiff.patch(old: binary, new: nil, path: "img.bin")
        #expect(deleted.isBinary && deleted.status == .deleted)
        #expect(deleted.oldPath == "img.bin" && deleted.newPath == "/dev/null")
        let renamed = FileDiff.patch(old: binary, new: "plain", path: "new.bin", oldPath: "old.bin")
        #expect(renamed.isBinary && renamed.status == .renamed(from: "old.bin"))
        #expect(renamed.oldPath == "old.bin" && renamed.newPath == "new.bin")
    }

    @Test("diff/myers.rs: random_inputs_match_dp_lcs_length (1200 rounds), huge_inputs_with_scattered_edits (30k), repeated_blocks_pair_cleanly")
    func diffMyersLcsHugeAndRepeatedBlocks() {
        func dpLcsLength(_ a: [Int], _ b: [Int]) -> Int {
            var prev = Array(repeating: 0, count: b.count + 1)
            var curr = Array(repeating: 0, count: b.count + 1)
            for x in a {
                for j in 0..<b.count {
                    curr[j + 1] = (x == b[j]) ? (prev[j] + 1) : max(prev[j + 1], curr[j])
                }
                swap(&prev, &curr)
                for j in 0...b.count { curr[j] = 0 }
            }
            return prev[b.count]
        }

        // #34: 1200 deterministic random pairs compared against true DP LCS length
        var rng: UInt64 = 0x5DEECE66D
        func nextRand() -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int((rng >> 33) & 0x7FFF_FFFF)
        }
        for _ in 0..<1200 {
            let na = nextRand() % 28
            let nb = nextRand() % 28
            let a = (0..<na).map { _ in nextRand() % 4 }
            let b = (0..<nb).map { _ in nextRand() % 4 }
            let ops = Myers.diff(a, b)
            var eqCount = 0
            var reconstructed: [Int] = []
            var ia = 0
            var ib = 0
            for op in ops {
                switch op {
                case .equal(let n):
                    eqCount += n
                    for _ in 0..<n {
                        #expect(a[ia] == b[ib])
                        reconstructed.append(a[ia])
                        ia += 1
                        ib += 1
                    }
                case .delete(let n):
                    ia += n
                case .insert(let n):
                    for _ in 0..<n {
                        reconstructed.append(b[ib])
                        ib += 1
                    }
                }
            }
            #expect(reconstructed == b)
            #expect(eqCount == dpLcsLength(a, b))
        }

        // Rust's search-cap regression. Every seventh line changes, well beyond 1,024 edits.
        let nLarge = 30_000
        let base = (0..<nLarge).map { $0 }
        var edited = base
        for i in base.indices where i % 7 == 3 { edited[i] = i + 1_000_000 }
        let hugeOps = Myers.diff(base, edited)
        var hugeEq = 0
        for op in hugeOps {
            if case .equal(let c) = op { hugeEq += c }
        }
        #expect(hugeEq == nLarge - 4_286)
        let deleted = hugeOps.reduce(0) { sum, op in if case .delete(let n) = op { sum + n } else { sum } }
        let inserted = hugeOps.reduce(0) { sum, op in if case .insert(let n) = op { sum + n } else { sum } }
        #expect(deleted == 4_286 && inserted == 4_286)

        // #37: repeated identical blocks stay aligned cleanly
        let blockA = ["fn helper() {", "    let x = 1;", "    let y = 2;", "}"]
        let oldLines = blockA + ["// middle old"] + blockA
        let newLines = blockA + ["// middle new"] + blockA
        let ops = Myers.diff(oldLines, newLines)
        #expect(ops == [.equal(4), .delete(1), .insert(1), .equal(4)])
    }

    @Test("diff/state.rs: expand up/down/all (#40), split keys (#41), one-side copy & release clear (#42), cancel restore & setFiles reset (#43-#44), hover hold & visibleWindow (#45)")
    func diffStateParityDetails() {
        let oldLines = (1...60).map { "line \($0)" }
        var newLines = oldLines
        newLines[0] = "changed 1"
        newLines[59] = "changed 60"
        let diff = FileDiff.fromTexts(path: "long.swift", old: oldLines.joined(separator: "\n"), new: newLines.joined(separator: "\n"), context: 3)
        var st = DiffState(diff: diff)

        // #40: hidden starts at 52 (60 - 4 - 4), expand up -> 32, down -> 12, all -> 0
        #expect(st.hidden(gap: 1) == 52)
        st.expand(gapIndex: 1, direction: .up)
        #expect(st.hidden(gap: 1) == 32)
        st.expand(gapIndex: 1, direction: .down)
        #expect(st.hidden(gap: 1) == 12)
        st.expand(gapIndex: 1, direction: .all)
        #expect(st.hidden(gap: 1) == 0)

        // #41: split pairs changes cleanly
        let splitSt = DiffState(diff: diff, mode: .split)
        let splitRows = splitSt.rows()
        #expect(splitRows.contains(where: {
            if case .splitPair = $0 { return true }
            return false
        }))
        #expect(splitSt.diff.columns >= 2)

        // #42-#44: one-side selection copy, release-to-clear, cancel restores prior, setFiles ends active press
        let p = """
        diff --git a/s.rs b/s.rs
        --- a/s.rs
        +++ b/s.rs
        @@ -1,4 +1,4 @@
         ctx1
        -old2
        +new2
         ctx3
         ctx4
        """
        var selSt = DiffState(diff: FileDiff.parse(p)[0])
        let r1 = DiffLineRef(side: .old, line: 1)
        let r2 = DiffLineRef(side: .old, line: 2)
        let r3 = DiffLineRef(side: .old, line: 3)
        selSt.select(DiffLineRange(start: r1, end: r2))
        #expect(selSt.copyText(side: .old) == "ctx1\nold2")

        // Pressing already-selected single line without drag clears on release
        selSt.select(DiffLineRange(start: r1, end: r1))
        selSt.selection.step(.press(at: r1, column: .numbers, shift: false))
        selSt.selection.step(.release)
        #expect(selSt.selectedRange == nil)

        // #43: Cancel restores pre-press selection
        let prior = DiffLineRange(start: r1, end: r1)
        selSt.select(prior)
        selSt.selection.step(.press(at: r2, column: .numbers, shift: false))
        selSt.selection.step(.move(at: r3))
        selSt.selection.step(.cancel)
        #expect(selSt.selectedRange == prior)

        // #44: setFiles drops active press so cancel restores nil
        selSt.selection.step(.press(at: r2, column: .numbers, shift: false))
        selSt.setFiles([diff])
        selSt.selection.step(.cancel)
        #expect(selSt.selectedRange == nil)

        // #45: copySide follows hovered side unless held cell keeps opposite side entered
        #expect(selSt.hoverText(side: .old, cell: "o-0", inside: true) == true)
        #expect(selSt.copySide == .old)
        // Entering new cell while old cell is still held does NOT switch side
        #expect(selSt.hoverText(side: .new, cell: "n-0", inside: true) == false)
        #expect(selSt.copySide == .old)
        // Releasing old cell leaves new cell active, then next new hover confirms switch
        _ = selSt.hoverText(side: .old, cell: "o-0", inside: false)
        #expect(selSt.hoverText(side: .new, cell: "n-1", inside: true) == true)
        #expect(selSt.copySide == .new)

        // #45: visibleWindow tracks scrolled offset
        let win = splitSt.visibleWindow(for: splitRows, scrollY: 40, viewportHeight: 60, overscan: 0)
        #expect(win.range.lowerBound > 0)
    }

    @Test("diff/view.rs: DiffViewHelpers formattedCode, mergeCodeSpans, rowLabel (#46-#48)")
    func diffViewHelpersParity() {
        let (expanded, map, pads) = DiffViewHelpers.formattedCode("\ta\té", tabSize: 4, wrap: false)
        #expect(expanded == "\t   a\t  é")
        #expect(pads == [1..<4, 6..<8])
        #expect(map != nil)
        if let map {
            // Raw "\t" (0..<1) -> expanded (0..<4); raw "a" (1..<2) -> (4..<5); "\t" (2..<3) -> (5..<8); "é" (3..<5) -> (8..<10)
            #expect(map[0] == 0)
            #expect(map[1] == 4)
            #expect(map[2] == 5)
            #expect(map[3] == 8)
            #expect(map[5] == 10)
        }

        // Cross-span soft-break insertion after '.' and '/' before non-whitespace
        let code = "a.b/c "
        let shown = DiffViewHelpers.formattedCode(code, wrap: true)
        #expect(shown.uncopied == [2..<5, 7..<10])
        let highlights = [
            SyntaxHighlight(range: 0..<2, paint: .kind(.punctuation)), // "a."
            SyntaxHighlight(range: 2..<4, paint: .kind(.property)),    // "b/"
            SyntaxHighlight(range: 4..<6, paint: .kind(.variable)),    // "c "
        ]
        let kit = Kit.neutral(dark: false)
        let theme = SyntaxTheme.fromKit(kit)
        let spans = DiffViewHelpers.mergeCodeSpans(
            code: shown.text,
            offsetMap: shown.sourceOffsets,
            highlights: highlights,
            changedRanges: [2..<3], // "b"
            defaultColor: kit.c.textBase,
            syntaxTheme: theme,
            wordBg: kit.c.warning.bg
        )
        let joined = spans.map(\.text).joined()
        #expect(joined == "a.\u{200B}b/\u{200B}c ")
        #expect(spans.contains(where: { $0.text.contains("b") && $0.background == kit.c.warning.bg }))

        // Disabled wrap keeps original characters
        #expect(DiffViewHelpers.formattedCode("a.b(c)[d]/e", wrap: false).text == "a.b(c)[d]/e")
        #expect(DiffViewHelpers.formattedCode("a. b/ ", wrap: true).text == "a. b/ ")

        // rowLabel formatting
        let added = DiffLine(kind: .addition, oldNumber: nil, newNumber: 7, text: "let x = 1")
        let removed = DiffLine(kind: .deletion, oldNumber: 4, newNumber: nil, text: "let y = 2")
        let ctx = DiffLine(kind: .context, oldNumber: 10, newNumber: 11, text: "keep")
        #expect(DiffViewHelpers.rowLabel(added) == "added line 7: let x = 1")
        #expect(DiffViewHelpers.rowLabel(removed) == "removed line 4: let y = 2")
        #expect(DiffViewHelpers.rowLabel(ctx, side: .old) == "unchanged line 10: keep")
        #expect(DiffViewHelpers.rowLabel(ctx, side: .new) == "unchanged line 11: keep")
    }

    @Test("tests/diff.rs: stacked note coords in unified & split (#175)")
    @MainActor
    func diffRuntimeNoteCoordsParity() {
        struct AppState: Sendable {
            var diff: DiffState
            var toggledNote: Bool = false
        }

        let kit = Kit.neutral(dark: false)
        let numberedOld = (1...30).map { "let value_\($0) = compute(\($0));" }.joined(separator: "\n")
        var numberedNewArr = (1...30).map { "let value_\($0) = compute(\($0));" }
        numberedNewArr[9] = "let value_10 = compute(10) + 1;"
        let fileDiff = FileDiff.fromTexts(path: "a.rs", old: numberedOld, new: numberedNewArr.joined(separator: "\n"))
        let rows = DiffState(diff: fileDiff).rows(file: 0)
        let r9Idx = rows.firstIndex(where: { $0.lineRef(for: .unified)?.line == 9 })!
        let r10NewIdx = rows.firstIndex(where: { if case let .unified(l, _, _) = $0 { return l.kind == .addition && l.newNumber == 10 }; return false })!
        let r11Idx = rows.firstIndex(where: { $0.lineRef(for: .unified)?.line == 11 })!

        let unifiedState = AppState(
            diff: DiffState(
                diff: fileDiff,
                mode: .unified,
                annotations: [
                    DiffAnnotation(id: "c1", file: 0, side: .new, line: 10, body: "c1"),
                    DiffAnnotation(id: "c2", file: 0, side: .new, line: 10, body: "c2"),
                ]
            )
        )
        let rt = Runtime<AppState>(
            state: unifiedState,
            viewport: Vec2(900, 1200),
            view: { s, cx in
                DiffView<AppState>(key: "dv", kit: kit, get: { $0.diff }, set: { $0.diff = $1 })
                    .viewportHeight(1100)
                    .onLineClick { st, ref, _ in
                        st.toggledNote.toggle()
                        if st.toggledNote {
                            st.diff.annotations.append(DiffAnnotation(id: "clicked", file: 0, side: ref.side, line: ref.line, body: "Added"))
                        } else {
                            st.diff.annotations.removeAll { $0.id == "clicked" }
                        }
                    }
                    .build(state: s, cx: cx)
            }
        )
        _ = rt.frame(at: 0.01)

        // Note rows inserted after row indices: compute indices with annotations present
        let uRows = rt.state.diff.rows(file: 0)
        let uLine10Idx = uRows.firstIndex(where: { if case let .unified(l, _, _) = $0 { return l.kind == .addition && l.newNumber == 10 }; return false }) ?? r10NewIdx
        let uLine9Idx = uRows.firstIndex(where: { $0.lineRef(for: .unified)?.line == 9 }) ?? r9Idx
        let uLine11Idx = uRows.firstIndex(where: { $0.lineRef(for: .unified)?.line == 11 }) ?? r11Idx

        let line10 = rt.element(byKey: "dv-row-\(uLine10Idx)")
        let line9 = rt.element(byKey: "dv-row-\(uLine9Idx)")
        let line11 = rt.element(byKey: "dv-row-\(uLine11Idx)")
        let c1 = rt.element(byKey: "dv-note-c1")
        let c2 = rt.element(byKey: "dv-note-c2")
        #expect(line10 != nil && line9 != nil && line11 != nil && c1 != nil && c2 != nil)
        if let line10, let line9, let line11, let c1, let c2 {
            #expect(line10.rect[3] == 20.0)
            #expect(abs(line9.rect[2] - 898.0) <= 2.5)
            #expect(abs(c1.rect[1] - (line10.rect[1] + line10.rect[3])) < 0.5)
            #expect(abs(c2.rect[1] - (c1.rect[1] + c1.rect[3])) < 0.5)
            #expect(abs(line11.rect[1] - (c2.rect[1] + c2.rect[3])) < 0.5)
        }

        // Split mode: annotation sits directly under the split pair row and on the right half
        rt.update(at: 0.02) { s, _ in s.diff.setMode(.split) }
        _ = rt.frame(at: 0.02)
        let sRows = rt.state.diff.rows(file: 0)
        let sPairIdx = sRows.firstIndex(where: { if case let .splitPair(_, n, _, _) = $0 { return n.newNumber == 10 }; return false })!
        let sRow = rt.element(byKey: "dv-srow-\(sPairIdx)")
        let sC1 = rt.element(byKey: "dv-note-c1")
        let sC2 = rt.element(byKey: "dv-note-c2")
        #expect(sRow != nil && sC1 != nil && sC2 != nil)
        if let sRow, let sC1, let sC2 {
            #expect(abs(sC1.rect[1] - (sRow.rect[1] + sRow.rect[3])) < 0.5)
            #expect(abs(sC2.rect[1] - (sC1.rect[1] + sC1.rect[3])) < 0.5)
            for note in [sC1, sC2] {
                #expect(abs(note.rect[0] - (sRow.rect[0] + sRow.rect[2] / 2)) < 0.5)
                #expect(abs(note.rect[2] - sRow.rect[2] / 2) < 0.5)
            }
            if let sn = rt.element(byKey: "dv-sn-\(sPairIdx)") {
                let pt = Vec2(sn.rect[0] + sn.rect[2] * 0.5, sn.rect[1] + sn.rect[3] * 0.5)
                rt.pointerDown(at: pt, at: 0.04)
                rt.pointerUp(at: pt, at: 0.05)
                _ = rt.frame(at: 0.06)
                #expect(rt.state.toggledNote == true)
                #expect(rt.element(byKey: "dv-note-clicked") != nil)
            }
        }
    }

    @Test("Annotations on a split line stack independently in each column")
    @MainActor
    func annotationsStackWithinEachSplitSide() throws {
        let file = FileDiff.fromTexts(path: "a.swift", old: "start\nlet rate = 1\nafter", new: "start\nlet rate = 2\nafter")
        var state = DiffState(diff: file, mode: .split)
        let heightWithoutNotes = state.rows().reduce(Float(0)) { $0 + $1.baseHeight }
        state.annotations = [
            DiffAnnotation(id: "L1", side: .old, line: 2, body: "First old note"),
            DiffAnnotation(id: "R1", side: .new, line: 2, body: "First new note"),
            DiffAnnotation(id: "L2", side: .old, line: 2, body: "Second old note"),
            DiffAnnotation(id: "R2", side: .new, line: 2, body: "Second new note"),
            DiffAnnotation(id: "R3", side: .new, line: 2, body: "Third new note"),
        ]
        let rows = state.rows()
        let line = try #require(rows.firstIndex { $0.lineRef(for: .split)?.line == 2 })
        let nextLine = try #require(rows.firstIndex { $0.lineRef(for: .split)?.line == 3 })
        let top = rows[...line].reduce(Float(0)) { $0 + $1.baseHeight }
        let estimate = 3 * DiffLayout.noteHeight
        #expect(rows.reduce(Float(0)) { $0 + $1.baseHeight } == heightWithoutNotes + estimate)
        let window = state.visibleWindow(for: rows, scrollY: top + estimate - 2, viewportHeight: 1, overscan: 0)
        #expect(window.range == (line + 1)..<nextLine)
        #expect(window.beforeHeight == top)

        let heights: [String: Float] = ["L1": 72, "L2": 25, "R1": 25, "R2": 38, "R3": 46]
        let kit = Kit.neutral(dark: false)
        let rt = Runtime<DiffState>(state: state, viewport: Vec2(900, 600)) { diff, cx in
            DiffView<DiffState>(key: "dv", kit: kit, get: { $0 }, set: { $0 = $1 })
                .annotation { _, ann in el().h(heights[ann.id]!) }
                .build(state: diff, cx: cx)
        }
        _ = rt.frame(at: 0)
        let pair = try #require(rt.element(byKey: "dv-srow-\(line)"))
        let startY = pair.rect[1] + pair.rect[3]
        let half = pair.rect[2] / 2
        let expected: [(String, Float, Float)] = [
            ("L1", 0, 0), ("L2", 0, 72),
            ("R1", half, 0), ("R2", half, 25), ("R3", half, 63),
        ]
        for (id, x, y) in expected {
            let note = try #require(rt.element(byKey: "dv-note-\(id)"))
            #expect(note.rect == [pair.rect[0] + x, startY + y, half, heights[id]!])
        }
        let after = try #require(rt.element(byKey: "dv-crow-\(nextLine)"))
        #expect(after.rect[1] == startY + 109)
    }

    @Test("tests/diff.rs: 4000-line/40-note virtualization (#176), gutter drag/plus/Escape (#178, #180), sticky header/actions/resize (#179), stuck gutter (#181), labels & 3-file nav (#182), PerfWarn (#184-#185)")
    @MainActor
    func diffRuntimeVirtualDragStickyAndPerfWarnParity() throws {
        struct AppState: Sendable {
            var diff: DiffState
            var selections: [DiffLineRange?] = []
            var comments: [DiffLineRange] = []
            var actions: [Int] = []
        }

        let kit = Kit.neutral(dark: false)

        // 1. #176: 4000-line diff with 40 annotations builds < 100 initial rows, scrolls to bottom & back to top
        func makeNumbered(_ total: Int, every: Int) -> (String, String) {
            let old = (1...total).map { "let value_\($0) = compute(\($0));" }.joined(separator: "\n")
            let new = (1...total).map { i in
                (i % every == 0) ? "let value_\(i) = compute(\(i)) + 1;" : "let value_\(i) = compute(\(i));"
            }.joined(separator: "\n")
            return (old, new)
        }
        let (bigOld, bigNew) = makeNumbered(4000, every: 3)
        let bigFile = FileDiff.fromTexts(path: "long.rs", old: bigOld, new: bigNew, context: 4000)
        let bigAnns = (1...40).map { i in
            DiffAnnotation(id: "n\(i)", file: 0, side: .new, line: UInt32(i * 99), author: "rev", body: "n\(i)")
        }
        let vRT = Runtime<AppState>(
            state: AppState(diff: DiffState(diff: bigFile, annotations: bigAnns)),
            viewport: Vec2(800, 650),
            view: { s, cx in
                DiffView<AppState>(key: "dv", kit: kit, get: { $0.diff }, set: { $0.diff = $1 })
                    .viewportHeight(600)
                    .build(state: s, cx: cx)
            }
        )
        var vt = 0.01
        _ = vRT.frame(at: vt)
        let initBuiltRows = vRT.elements().filter { ($0.key ?? "").hasPrefix("dv-row-") }.count
        #expect(initBuiltRows > 0 && initBuiltRows < 100)
        let vTotalRows = vRT.state.diff.rows(file: 0).count
        let lastRowKey = "dv-row-\(vTotalRows - 1)"
        #expect(vRT.element(byKey: lastRowKey) == nil)
        for _ in 0..<40 {
            vRT.wheel(WheelEvent(dx: 0, dy: -100_000), at: Vec2(400, 300), now: vt)
            vt += 1.0 / 120.0
            _ = vRT.frame(at: vt)
        }
        for _ in 0..<120 { vt += 1.0 / 120.0; _ = vRT.frame(at: vt) }
        if let vBody = vRT.element(byKey: "dv-body"), let lastRow = vRT.element(byKey: lastRowKey) {
            #expect(abs((lastRow.rect[1] + lastRow.rect[3]) - (vBody.rect[1] + vBody.rect[3])) < 4.0)
        } else {
            Issue.record("Expected bottom row \(lastRowKey) after scrolling 4000-line diff")
        }
        let bottomBuiltRows = vRT.elements().filter { ($0.key ?? "").hasPrefix("dv-row-") }.count
        #expect(bottomBuiltRows < 160)
        if let note40 = vRT.element(byKey: "dv-note-n40"),
           let idx3960 = vRT.state.diff.rows(file: 0).firstIndex(where: { if case let .unified(l, _, _) = $0 { return l.kind == .addition && l.newNumber == 3960 }; return false }),
           let line3960 = vRT.element(byKey: "dv-row-\(idx3960)") {
            #expect(abs(note40.rect[1] - (line3960.rect[1] + line3960.rect[3])) < 0.5)
        }
        for _ in 0..<40 {
            vRT.wheel(WheelEvent(dx: 0, dy: 100_000), at: Vec2(400, 300), now: vt)
            vt += 1.0 / 120.0
            _ = vRT.frame(at: vt)
        }
        for _ in 0..<120 { vt += 1.0 / 120.0; _ = vRT.frame(at: vt) }
        let topBody = try #require(vRT.element(byKey: "dv-body"))
        let topHeader = try #require(vRT.element(byKey: "dv-header"))
        let firstRow = try #require(vRT.element(byKey: "dv-row-0"))
        #expect(abs(topHeader.rect[1] - topBody.rect[1]) < 2.0)
        #expect(abs(firstRow.rect[1] - (topHeader.rect[1] + topHeader.rect[3])) < 2.0)

        // 2. #178 & #180: line numbers select, drag 3->5, '+' comments selection vs single line, Escape clears & cancels drag
        let (selOld, selNew) = makeNumbered(20, every: 5)
        let selDiff = FileDiff.fromTexts(path: "a.rs", old: selOld, new: selNew, context: 20)
        let selRT = Runtime<AppState>(
            state: AppState(diff: DiffState(diff: selDiff)),
            viewport: Vec2(800, 900),
            onKey: { st, ev, tx in st.diff.key(ev, keyPrefix: "dv", tx: &tx) },
            view: { s, cx in
                DiffView<AppState>(key: "dv", kit: kit, get: { $0.diff }, set: { $0.diff = $1 })
                    .viewportHeight(840)
                    .onSelect { st, r, _ in st.selections.append(r) }
                    .onComment { st, r, _ in st.comments.append(r) }
                    .build(state: s, cx: cx)
            }
        )
        let selRows = selRT.state.diff.rows(file: 0)
        func rowIdx(line: Int, additionPreferred: Bool = false) -> Int {
            if additionPreferred,
               let idx = selRows.firstIndex(where: { if case let .unified(l, _, _) = $0 { return l.kind == .addition && l.newNumber == line }; return false }) {
                return idx
            }
            return selRows.firstIndex(where: { $0.lineRef(for: .unified)?.line == UInt32(line) })!
        }
        var st = 0.01
        _ = selRT.frame(at: st)
        let r3 = rowIdx(line: 3)
        let r4 = rowIdx(line: 4)
        let r5 = rowIdx(line: 5, additionPreferred: true)
        let r9 = rowIdx(line: 9)
        if let n3 = selRT.element(byKey: "dv-n-\(r3)"), let n5 = selRT.element(byKey: "dv-n-\(r5)") {
            let p3 = Vec2(n3.rect[0] + n3.rect[2] * 0.5, n3.rect[1] + 10)
            selRT.pointerDown(at: p3, at: st); st += 0.01
            selRT.pointerUp(at: p3, at: st); st += 0.01
            _ = selRT.frame(at: st)
            let three = DiffLineRange(start: DiffLineRef(side: .new, line: 3), end: DiffLineRef(side: .new, line: 3))
            #expect(selRT.state.diff.selectedRange == three)
            #expect(selRT.state.selections == [three])

            // Drag line 3 -> line 5
            let x = n3.rect[0] + n3.rect[2] * 0.5
            let y0 = n3.rect[1] + 10
            let y1 = n5.rect[1] + 10
            selRT.pointerDown(at: Vec2(x, y0), at: st); st += 0.01
            for step in 1...6 {
                selRT.pointerMove(to: Vec2(x, y0 + (y1 - y0) * Float(step) / 6.0), at: st); st += 0.01
                _ = selRT.frame(at: st)
            }
            selRT.pointerUp(at: Vec2(x, y1), at: st); st += 0.01
            _ = selRT.frame(at: st)
            let range35 = DiffLineRange(start: DiffLineRef(side: .new, line: 3), end: DiffLineRef(side: .new, line: 5))
            #expect(selRT.state.diff.selectedRange == range35)
            #expect(selRT.state.selections.last == .some(range35))

            // '+' on selected line 4 comments on range35; on line 9 comments on line 9 alone
            #expect(clickElement(selRT, key: "dv-n-\(r4)-plus", at: st))
            st += 0.02
            _ = selRT.frame(at: st)
            #expect(selRT.state.comments == [range35])
            #expect(clickElement(selRT, key: "dv-n-\(r9)-plus", at: st))
            st += 0.02
            _ = selRT.frame(at: st)
            #expect(selRT.state.comments == [range35, .line(DiffLineRef(side: .new, line: 9))])

            // Escape clears selection
            _ = selRT.keyDown(KeyEvent(key: .escape), at: st); st += 0.01
            _ = selRT.frame(at: st)
            #expect(selRT.state.diff.selectedRange == nil)

            // #180: cancelling a gutter drag restores selection without notifying onSelect on pointerUp
            let click3 = Vec2(n3.rect[0] + n3.rect[2] * 0.5, n3.rect[1] + 10)
            selRT.pointerDown(at: click3, at: st); selRT.pointerUp(at: click3, at: st + 0.01); st += 0.02
            _ = selRT.frame(at: st)
            let originalSel = selRT.state.diff.selectedRange
            let prevCount = selRT.state.selections.count
            if let n4 = selRT.element(byKey: "dv-n-\(r4)") {
                let dx = n4.rect[0] + n4.rect[2] * 0.5
                let dy = n4.rect[1] + 10
                selRT.pointerDown(at: Vec2(dx, dy), at: st); st += 0.01
                selRT.pointerMove(to: Vec2(dx, dy + 40), at: st); st += 0.01
                _ = selRT.frame(at: st)
                _ = selRT.keyDown(KeyEvent(key: .escape), at: st); st += 0.01
                _ = selRT.frame(at: st)
                #expect(selRT.state.diff.selectedRange == originalSel)
                #expect(selRT.state.selections.count == prevCount)
                selRT.pointerUp(at: Vec2(dx, dy + 40), at: st); st += 0.01
                _ = selRT.frame(at: st)
                #expect(selRT.state.selections.count == prevCount)
            }
        }

        // 3. #179: header spans viewport across resizes [800, 450, 600], horizontal scroll keeps header/actions fixed & clickable, vertical sticky header
        let longLine = String(repeating: "x", count: 400)
        func wideSource(_ suffix: String) -> String {
            (0..<60).map { i in (i == 1) ? longLine : "let v\(i) = \(i % 2)\(suffix);" }.joined(separator: "\n")
        }
        let wideFiles = (0..<2).map { i in
            FileDiff.fromTexts(path: "dir/f\(i).rs", old: wideSource(""), new: wideSource("+1"), context: 60)
        }
        let hdrRT = Runtime<AppState>(
            state: AppState(diff: DiffState(files: wideFiles)),
            viewport: Vec2(600, 400),
            pixelScale: 2.0,
            view: { s, cx in
                DiffView<AppState>(key: "dv", kit: kit, get: { $0.diff }, set: { $0.diff = $1 })
                    .headerActions { _, idx in
                        El<AppState>(direction: .row)
                            .key("act-\(idx)")
                            .px(6).py(2)
                            .onClick { st in st.actions.append(idx) }
                            .child(text("Act"))
                    }
                    .build(state: s, cx: cx)
            }
        )
        var ht = 0.0
        _ = hdrRT.frame(at: ht)
        func verifyHeader(width w: Float) {
            if let hdr = hdrRT.element(byKey: "dv-header"),
               let act = hdrRT.element(byKey: "dv-actions") {
                #expect(abs(hdr.rect[0] - 1.0) <= 2.0 && abs(hdr.rect[2] - (w - 2.0)) <= 2.5)
                #expect(act.rect[0] >= -0.5 && act.rect[0] + act.rect[2] <= w + 0.5 && act.rect[2] > 0)
            } else {
                Issue.record("Missing header/actions at width \(w)")
            }
        }
        verifyHeader(width: 600)
        for _ in 0..<2 {
            hdrRT.wheel(WheelEvent(dx: -250, dy: 0), at: Vec2(300, 200), now: ht); ht += 0.01
            _ = hdrRT.frame(at: ht)
        }
        for _ in 0..<60 { ht += 1.0 / 60.0; _ = hdrRT.frame(at: ht) }
        verifyHeader(width: 600)
        let scrolledCode = hdrRT.element(byKey: "dv-code-2")?.rect[0] ?? 0
        #expect(scrolledCode < -100)
        if let act = hdrRT.element(byKey: "dv-actions") {
            let p = Vec2(act.rect[0] + act.rect[2] * 0.5, act.rect[1] + act.rect[3] * 0.5)
            hdrRT.pointerDown(at: p, at: ht); hdrRT.pointerUp(at: p, at: ht + 0.01); ht += 0.02
            _ = hdrRT.frame(at: ht)
            #expect(hdrRT.state.actions == [0])
        }
        for w in [Float(800), Float(450), Float(600)] {
            hdrRT.setViewport(Vec2(w, 400), pixelScale: 2.0)
            _ = hdrRT.frame(at: ht); ht += 0.01
            verifyHeader(width: w)
        }
        hdrRT.wheel(WheelEvent(dx: 0, dy: -150), at: Vec2(300, 200), now: ht); ht += 0.01
        for _ in 0..<60 { ht += 1.0 / 60.0; _ = hdrRT.frame(at: ht) }
        if let stickyHdr = hdrRT.element(byKey: "dv-header"), let act = hdrRT.element(byKey: "dv-actions") {
            #expect(stickyHdr.stuck > 0)
            #expect(abs(stickyHdr.rect[1] - 1.0) <= 2.0)
            let p = Vec2(act.rect[0] + act.rect[2] * 0.5, act.rect[1] + act.rect[3] * 0.5)
            hdrRT.pointerDown(at: p, at: ht); hdrRT.pointerUp(at: p, at: ht + 0.01); ht += 0.02
            _ = hdrRT.frame(at: ht)
            #expect(hdrRT.state.actions == [0, 0])
        }

        // 4. #181: unified gutters stay stuck at left edge while code scrolls sideways, press doesn't select scrolled code, drag across vertical scroll selects range
        let gDiff = FileDiff.fromTexts(path: "a.rs", old: wideSource(""), new: wideSource("+1"), context: 30)
        let gRT = Runtime<AppState>(
            state: AppState(diff: DiffState(diff: gDiff)),
            viewport: Vec2(600, 400),
            view: { s, cx in
                DiffView<AppState>(key: "dv", kit: kit, get: { $0.diff }, set: { $0.diff = $1 })
                    .viewportHeight(350)
                    .build(state: s, cx: cx)
            }
        )
        var gt = 0.0
        _ = gRT.frame(at: gt)
        let codeBeforeX = gRT.element(byKey: "dv-code-6")?.rect[0] ?? 0
        for _ in 0..<2 {
            gRT.wheel(WheelEvent(dx: -250, dy: 0), at: Vec2(300, 200), now: gt); gt += 0.01
            _ = gRT.frame(at: gt)
        }
        for _ in 0..<60 { gt += 1.0 / 60.0; _ = gRT.frame(at: gt) }
        let codeAfterX = gRT.element(byKey: "dv-code-6")?.rect[0] ?? 0
        #expect(codeAfterX < codeBeforeX - 100)
        if let g6 = gRT.element(byKey: "dv-gutter-6"), let bdy = gRT.element(byKey: "dv-body") {
            #expect(abs(g6.rect[0] - bdy.rect[0]) < 2.0)
            #expect(g6.stuck > 100.0)
        }
        if let no6 = gRT.element(byKey: "dv-o-6") {
            let p = Vec2(no6.rect[0] + no6.rect[2] * 0.5, no6.rect[1] + no6.rect[3] * 0.5)
            gRT.pointerDown(at: p, at: gt); gRT.pointerUp(at: p, at: gt + 0.01); gt += 0.02
            _ = gRT.frame(at: gt)
            #expect(gRT.state.diff.selectedRange != nil)
            #expect(gRT.selectedText() == nil)
        }
        if let g4 = gRT.element(byKey: "dv-o-4"), g4.rect.count == 4 {
            let x = g4.rect[0] + g4.rect[2] * 0.5
            let y0 = g4.rect[1] + 10
            gRT.pointerDown(at: Vec2(x, y0), at: gt); gt += 0.01
            _ = gRT.frame(at: gt)
            gRT.wheel(WheelEvent(dx: 0, dy: -80), at: Vec2(300, 200), now: gt); gt += 0.01
            for _ in 0..<60 { gt += 1.0 / 60.0; _ = gRT.frame(at: gt) }
            if let g10 = gRT.element(byKey: "dv-o-10") {
                let y1 = g10.rect[1] + 10
                gRT.pointerMove(to: Vec2(x, y1), at: gt); gt += 0.01
                _ = gRT.frame(at: gt)
                gRT.pointerUp(at: Vec2(x, y1), at: gt); gt += 0.01
                _ = gRT.frame(at: gt)
                let sel = gRT.state.diff.selectedRange
                #expect(sel != nil && sel?.start.line != sel?.end.line)
            }
        }

        // 5. #182: 3-file a11y labels (`heading`, `added/removed/unchanged line`) + `]`, `j`, `[` navigation + `onVisibleFile`
        let (navOld, navNew) = makeNumbered(200, every: 50)
        let navFiles = (0..<3).map { i in FileDiff.fromTexts(path: "f\(i).rs", old: navOld, new: navNew, context: 3) }
        let navRT = Runtime<AppState>(
            state: AppState(diff: DiffState(files: navFiles)),
            viewport: Vec2(800, 400),
            onKey: { st, ev, tx in st.diff.key(ev, keyPrefix: "dv", tx: &tx) },
            view: { s, cx in
                DiffView<AppState>(key: "dv", kit: kit, get: { $0.diff }, set: { $0.diff = $1 })
                    .onVisibleFile { st, fileIdx in st.actions.append(fileIdx) }
                    .build(state: s, cx: cx)
            }
        )
        var nt = 0.01
        _ = navRT.frame(at: nt)
        let navEls = navRT.elements()
        #expect(navEls.contains(where: { $0.role == .heading && $0.label == "f0.rs, 4 added, 4 removed" }))
        #expect(navEls.contains(where: { $0.label == "added line 50: let value_50 = compute(50) + 1;" }))
        #expect(navEls.contains(where: { $0.label == "removed line 50: let value_50 = compute(50);" }))
        #expect(navEls.contains(where: { $0.label == "unchanged line 49: let value_49 = compute(49);" }))
        _ = navRT.keyDown(KeyEvent(key: .text("]")), at: nt); nt += 0.01
        for _ in 0..<60 { nt += 1.0 / 60.0; _ = navRT.frame(at: nt) }
        #expect(navRT.state.diff.visibleFile == 1)
        let f1Hdr = navRT.element(byKey: "dv-f1-header")!
        #expect(f1Hdr.rect[1] <= 2.0)
        _ = navRT.keyDown(KeyEvent(key: .text("j")), at: nt); nt += 0.01
        for _ in 0..<60 { nt += 1.0 / 60.0; _ = navRT.frame(at: nt) }
        #expect(navRT.state.diff.visibleFile == 1)
        _ = navRT.keyDown(KeyEvent(key: .text("[")), at: nt); nt += 0.01
        for _ in 0..<60 { nt += 1.0 / 60.0; _ = navRT.frame(at: nt) }
        #expect(navRT.state.diff.visibleFile == 0)
        #expect(navRT.state.actions.last == 0)

        // 6. #184-#185: liveOnly hover & events skip view builds cleanly and `checkLiveOnly` reports real view mutations
        for mode in [DiffMode.unified, .split] {
            let (lOld, lNew) = makeNumbered(40, every: 3)
            var ld = DiffState(diff: FileDiff.fromTexts(path: "a.rs", old: lOld, new: lNew, context: 40))
            ld.setMode(mode)
            let lRT = Runtime<AppState>(
                state: AppState(diff: ld),
                viewport: Vec2(900, 1200),
                view: { s, cx in
                    DiffView<AppState>(key: "dv", kit: kit, get: { $0.diff }, set: { $0.diff = $1 }).build(state: s, cx: cx)
                }
            )
            var lt = 0.0
            _ = lRT.frame(at: lt)
            let codeCells = lRT.elements().filter(isCodeCell)
            #expect(codeCells.count > 20)
            let checksBefore = lRT.liveOnlyEvents
            for (idx, cell) in codeCells.enumerated() {
                if idx % 2 == 0 {
                    lt += 0.3
                    _ = lRT.frame(at: lt)
                }
                lRT.pointerMove(to: Vec2(cell.rect[0] + cell.rect[2] * 0.5, cell.rect[1] + cell.rect[3] * 0.5), at: lt)
                lt += 1.0 / 60.0
                _ = lRT.frame(at: lt)
            }
            #expect(lRT.liveOnlyEvents > checksBefore)
            #expect(lRT.liveOnlyWarnings.isEmpty)
        }
    }

    @Test("FileDiff.fold, DiffLineRange.line, DiffState.singleColumn, setHighlighter, and scrollToLine parity")
    @MainActor
    func diffModelAndStateCloseoutAPIs() {
        let fullOld = (1...30).map { "func f\($0)() { let x = \($0) }" }.joined(separator: "\n") + "\n"
        var newLines = (1...30).map { "func f\($0)() { let x = \($0) }" }
        newLines[3] = "func f4() { let x = 400 }"
        newLines[25] = "func f26() { let x = 2600 }"
        let fullNew = newLines.joined(separator: "\n") + "\n"

        // FileDiff.fold splits a single huge-context hunk around changes while keeping source expandable
        let singleHunk = FileDiff.fromTexts(path: "a.swift", old: fullOld, new: fullNew, context: 1000)
        #expect(singleHunk.hunks.count == 1)
        let folded = singleHunk.fold(context: 2)
        #expect(folded.hunks.count == 2)
        #expect(folded.expandable)
        #expect(folded.hunks[0].lines.contains(where: { $0.kind == .addition }))
        #expect(folded.hunks[1].lines.contains(where: { $0.kind == .addition }))

        // DiffLineRange.line & DiffState.singleColumn
        let ref = DiffLineRef(side: .new, line: 4)
        let lineRange = DiffLineRange.line(ref)
        #expect(lineRange.start == ref && lineRange.end == ref)

        let addedFile = FileDiff.fromTexts(path: "added.swift", old: "", new: "let a = 1\nlet b = 2\n", context: 3)
        let deletedFile = FileDiff.fromTexts(path: "deleted.swift", old: "let x = 1\n", new: "", context: 3)
        var st = DiffState(files: [addedFile, deletedFile, singleHunk], mode: .split)
        #expect(st.singleColumn(file: 0) == .new)
        #expect(st.singleColumn(file: 1) == .old)
        #expect(st.singleColumn(file: 2) == nil)
        st.setMode(.unified)
        #expect(st.singleColumn(file: 0) == nil)

        // DiffState.setHighlighter
        final class CounterBox: @unchecked Sendable { var calls = 0 }
        let box = CounterBox()
        let customHL = SyntaxHighlighter(id: "diff-custom") { _, _ in
            box.calls += 1
            return []
        }
        st.setHighlighter(customHL)
        let kit = Kit.neutral(dark: false)
        let rt = Runtime<DiffState>(state: st, viewport: Vec2(700, 400)) { s, cx in
            DiffView<DiffState>(key: "dv", kit: kit, get: { $0 }, set: { $0 = $1 }).build(state: s, cx: cx)
        }
        _ = rt.frame(at: 0.0)
        #expect(box.calls > 0)
        rt.update(at: 0.1) { s, _ in s.setMode(.split) }
        _ = rt.frame(at: 0.1)
        #expect(rt.element(byKey: "dv-arow-0") != nil)
        #expect(rt.element(byKey: "dv-aempty-0") == nil)
        #expect(rt.element(byKey: "dv-f1-drow-0") != nil)
        #expect(rt.element(byKey: "dv-f1-dempty-0") == nil)

        // DiffState.scrollToLine expands collapsed gap and scrolls to target file line
        var collapsedFileState = DiffState(diff: folded)
        var tx = Tx()
        collapsedFileState.scrollToLine(0, at: DiffLineRef(side: .new, line: 15), keyPrefix: "dv", tx: &tx)
        #expect(!collapsedFileState.collapsed(file: 0))
        #expect(!tx.scrollOffsetRequests.isEmpty)
        #expect(tx.scrollOffsetRequests.last?.key == "dv-df0.c15")
    }

    @Test("tests/diff.rs #183: focused_annotation_input_keeps_navigation_and_escape_keys")
    @MainActor
    func focusedAnnotationInputKeepsNavigationAndEscapeKeys() {
        struct ComposeApp: Sendable {
            var diff: DiffState
            var comment: TextEdit = TextEdit()
        }
        let kit = Kit.neutral(dark: true)
        let long = String(repeating: "x", count: 400)
        var oldLines = (1...60).map { "let value_\($0) = compute(\($0));" }
        var newLines = (1...60).map { i in
            (i % 10 == 0) ? "let value_\(i) = compute(\(i)) + 1;" : "let value_\(i) = compute(\(i));"
        }
        oldLines[8] = long
        newLines[8] = long
        let old = oldLines.joined(separator: "\n")
        let new = newLines.joined(separator: "\n")
        let files = (0..<2).map { i in FileDiff.fromTexts(path: "f\(i).rs", old: old, new: new, context: 3) }
        var diff = DiffState(files: files)
        diff.annotations = [DiffAnnotation(id: "c1", file: 0, side: .new, line: 10, body: "")]
        let sel = DiffLineRange.line(DiffLineRef(side: .new, line: 10))
        diff.select(sel)

        let rt = Runtime<ComposeApp>(
            state: ComposeApp(diff: diff),
            viewport: Vec2(600, 600),
            onKey: { s, ev, tx in s.diff.key(ev, keyPrefix: "dv", tx: &tx) },
            view: { s, cx in
                let dv = DiffView<ComposeApp>(key: "dv", kit: kit, get: { $0.diff }, set: { $0.diff = $1 })
                    .annotation { _, a in
                        let colNode: El<ComposeApp> = col()
                        return colNode
                            .wFull()
                            .child(
                                textInput(key: "input-\(a.id)", \ComposeApp.comment)
                                    .font(TextStyle(size: 13, weight: 400))
                                    .size(300, 28)
                            )
                            .child(
                                el()
                                    .key("pop-\(a.id)")
                                    .size(80, 20)
                                    .anchored("input-\(a.id)", side: .bottom, align: .start, gap: 4)
                            )
                    }
                    .build(state: s, cx: cx)
                return col().wFull().hFull().child(dv)
            }
        )
        var t = 0.0
        _ = rt.frame(at: t)
        for _ in 0..<30 { t += 1.0 / 60.0; _ = rt.frame(at: t) }
        rt.wheel(WheelEvent(dx: -250, dy: -40), at: Vec2(300, 200), now: t)
        for _ in 0..<60 { t += 1.0 / 60.0; _ = rt.frame(at: t) }

        let code10 = rt.elements().first { ($0.key ?? "").contains("-code-") && $0.rect[1] > 100 && $0.rect[0] < -50 }
        let codeX = code10?.rect[0] ?? 0
        #expect(codeX < -50, "Expected code scrolled sideways, got \(codeX)")

        guard let inp = rt.element(byKey: "input-c1"), let pop = rt.element(byKey: "pop-c1") else {
            Issue.record("Missing annotation input-c1 or pop-c1")
            return
        }
        #expect(abs(inp.rect[0]) < 2.0, "Input stays pinned near left edge: \(String(describing: inp.rect))")
        #expect(abs(pop.rect[0] - max(8.0, inp.rect[0])) < 1.0)
        #expect(abs(pop.rect[1] - (inp.rect[1] + inp.rect[3] + 4.0)) < 1.0)

        // Click the comment box to focus and type `][jk`
        let clickPt = Vec2(inp.rect[0] + 10, inp.rect[1] + 10)
        rt.pointerDown(at: clickPt, at: t); t += 0.01
        rt.pointerUp(at: clickPt, at: t); t += 0.01
        _ = rt.frame(at: t)
        #expect(rt.focusedKey == "input-c1")

        for ch in ["]", "[", "j", "k"] {
            _ = rt.keyDown(KeyEvent(key: .text(ch)), at: t); t += 0.01
            _ = rt.frame(at: t)
        }
        #expect(rt.state.comment.text == "][jk")
        if let inpAfter = rt.element(byKey: "input-c1"), let caret = inpAfter.caret {
            #expect(caret[0] >= inpAfter.rect[0] && caret[0] < inpAfter.rect[0] + inpAfter.rect[2])
        } else {
            Issue.record("Focused input should report caret")
        }
        #expect(rt.state.diff.visibleFile == 0)
        #expect(rt.state.diff.selectedRange == sel)

        // First Escape blurs input without clearing diff selection; second Escape clears diff selection
        _ = rt.keyDown(KeyEvent(key: .escape), at: t); t += 0.01
        _ = rt.frame(at: t)
        #expect(rt.focusedKey == nil)
        #expect(rt.state.diff.selectedRange == sel)

        _ = rt.keyDown(KeyEvent(key: .escape), at: t); t += 0.01
        _ = rt.frame(at: t)
        #expect(rt.state.diff.selectedRange == nil)
    }

    @Test("tests/diff.rs #185 & #186: checkLiveOnly catches state mutation during liveOnly, 50k diff stays responsive")
    @MainActor
    func liveOnlyCheckAnd50kDiffBenchmark() {
        struct LiveApp: Sendable {
            var diff: DiffState
            var mutateMode: Bool = false
        }
        let kit = Kit.neutral(dark: false)
        let old = (1...200).map { "let line_\($0) = \($0);" }.joined(separator: "\n")
        let new = (1...200).map { ($0 % 5 == 0) ? "let line_\($0) = \($0 + 1);" : "let line_\($0) = \($0);" }.joined(separator: "\n")
        var state = DiffState(diff: FileDiff.fromTexts(path: "a.rs", old: old, new: new, context: 200))
        state.setMode(.unified)

        let rt = Runtime<LiveApp>(
            state: LiveApp(diff: state),
            viewport: Vec2(900, 600),
            onKey: { s, _, tx in
                if s.mutateMode {
                    s.diff.setMode(s.diff.mode == .split ? .unified : .split)
                }
                tx.liveOnly()
                return true
            },
            view: { s, cx in
                DiffView<LiveApp>(key: "dv", kit: kit, get: { $0.diff }, set: { $0.diff = $1 }).build(state: s, cx: cx)
            }
        )
        var t = 0.0
        _ = rt.frame(at: t)
        rt.checkLiveOnly(false)
        let initialSkips = rt.liveOnlyEvents
        rt.wheel(WheelEvent(dx: 0, dy: -600), at: Vec2(400, 300), now: t)
        for _ in 0..<4 { t += 1.0 / 60.0; _ = rt.frame(at: t) }
        _ = rt.keyDown(KeyEvent(key: .f(5)), at: t); t += 0.01
        _ = rt.frame(at: t)
        #expect(rt.liveOnlyEvents > initialSkips)
        #expect(rt.liveOnlyWarnings.isEmpty)

        // Probe catches silent mode mutation under tx.liveOnly() after >= 0.25s
        rt.checkLiveOnly(true)
        rt.state.mutateMode = true
        t += 0.30
        _ = rt.keyDown(KeyEvent(key: .f(5)), at: t); t += 0.01
        _ = rt.frame(at: t)
        #if DEBUG
        #expect(rt.liveOnlyWarnings.count == 1)
        #else
        #expect(rt.liveOnlyWarnings.isEmpty)
        #endif

        // #186: 50k-line scattered diff (every 7th changed) constructs & renders windowed slice quickly
        let old50 = (1...50_000).map { "let v_\($0) = compute(\($0));" }.joined(separator: "\n")
        let new50 = (1...50_000).map { ($0 % 7 == 0) ? "let v_\($0) = compute(\($0)) + 1;" : "let v_\($0) = compute(\($0));" }.joined(separator: "\n")
        let bigFile = FileDiff.fromTexts(path: "big.rs", old: old50, new: new50, context: 3)
        let bigRT = Runtime<DiffState>(state: DiffState(diff: bigFile), viewport: Vec2(1200, 900)) { s, cx in
            DiffView<DiffState>(key: "dv50k", kit: kit, get: { $0 }, set: { $0 = $1 }).build(state: s, cx: cx)
        }
        _ = bigRT.frame(at: 0.0)
        #expect(bigFile.additionsCount == 7_142 && bigFile.deletionsCount == 7_142)
        #expect(bigFile.hunks.count == 1 && bigFile.hunks.first?.lines.count == 57_136)
        #expect(bigRT.state.rows(file: 0).count == 57_138)
        let mounted = bigRT.elements().filter { ($0.key ?? "").hasPrefix("dv50k-df") }.count
        #expect(mounted > 0 && mounted < 160)
    }

    @Test("Wrapped diff rows grow, shrink after a resize, and fit split panes")
    @MainActor
    func wrapFitsCodeToViewport() throws {
        let long = String(repeating: "word ", count: 40)
        let patch = [
            "--- a/test.rs", "+++ b/test.rs", "@@ -1,4 +1,4 @@",
            " head", " \(long)", "-old \(long)", "+new \(long)", " tail",
        ].joined(separator: "\n")
        let file = try #require(FileDiff.parseUnified(patch).first)
        let rt = Runtime(state: DiffState(diff: file), viewport: Vec2(640, 400), pixelScale: 2) { state, cx in
            DiffView<DiffState>(key: "wrap", kit: .neutral(dark: false), get: { $0 }, set: { $0 = $1 })
                .build(state: state, cx: cx)
        }
        var t = 0.0
        func settle() {
            for _ in 0..<5 { t += 1.0 / 120; _ = rt.renderFrame(at: t) }
        }
        func rect(_ key: String) throws -> [Float] {
            try #require(rt.element(byKey: "wrap-\(key)")).rect
        }
        settle()
        let unwrapped = try rect("df0.c2")[3]
        rt.setViewport(Vec2(275, 400), pixelScale: 2)
        rt.update(at: t) { state, _ in state.wrap = true }
        settle()
        #expect(rt.elements().filter { !$0.exiting && $0.key == "wrap-code-1" }.count == 1)
        #expect(try abs(rect("code-1-text")[2] - 156) < 0.1)
        let narrow = try rect("df0.c2")
        #expect(narrow[3] > unwrapped)
        #expect(try abs(rect("df0.o3")[1] - (narrow[1] + narrow[3])) < 0.1)

        rt.setViewport(Vec2(960, 400), pixelScale: 2)
        settle()
        #expect(try rect("df0.c2")[3] < narrow[3])
        rt.setViewport(Vec2(275, 400), pixelScale: 2)
        rt.update(at: t) { state, _ in
            state.wrap = false
            state.setMode(.split)
        }
        settle()
        let old = try rect("scode-o-2")
        let new = try rect("scode-n-2")
        #expect(try rect("df0.c2")[3] > narrow[3])
        #expect(try abs(rect("scode-o-2-text")[2] - 58.5) < 0.1)
        #expect(old[0] + old[2] <= rt.viewport.x / 2 + 1)
        #expect(new[0] >= rt.viewport.x / 2)
        #expect(new[0] + new[2] <= rt.viewport.x + 1)

        rt.update(at: t) { state, _ in state.setMode(.unified) }
        settle()
        #expect(try rect("df0.c2")[3] == unwrapped)
    }

    @Test("A single interactive diff scrolls its file header and reuses its sticky actions")
    @MainActor
    func singleFileScrollableHeader() throws {
        struct Host: Sendable {
            var diff: DiffState
            var clicks = 0
        }
        let lines = (1...180).map { $0 == 8 ? String(repeating: "wide ", count: 100) : "line \($0)" }
        let patch = ["--- a/test.rs", "+++ b/test.rs", "@@ -1,180 +1,180 @@"] + lines.map { " " + $0 }
        let file = try #require(FileDiff.parseUnified(patch.joined(separator: "\n")).first)
        let rt = Runtime(state: Host(diff: DiffState(diff: file)), viewport: Vec2(800, 320)) { s, cx in
            DiffView<Host>(key: "df", kit: .neutral(dark: false), get: { $0.diff }, set: { $0.diff = $1 })
                .headerActions { _, _ in
                    El<Host>(direction: .row).key("review-file").w(32).h(24).onClick { $0.clicks += 1 }
                }
                .build(state: s, cx: cx)
        }
        var t = 0.0
        func settle() {
            for _ in 0..<5 { t += 1.0 / 120; _ = rt.renderFrame(at: t) }
        }
        func scroll(_ x: Float, _ y: Float) {
            rt.update(at: t) { _, tx in tx.scrollTo("df-body", offset: Vec2(x, y), animated: false) }
            settle()
        }
        settle()
        scroll(48, 11)
        #expect(try #require(rt.element(byKey: "df-header")).rect[1] == -11)
        scroll(180, 900)
        let sticky = try #require(rt.element(byKey: "df-header"))
        #expect(sticky.rect[0] == 0 && sticky.rect[1] == 0)
        #expect(rt.elements().filter { !$0.exiting && $0.key == "df-header" }.count == 1)
        func click(_ key: String) throws {
            let frame = try #require(rt.element(byKey: key)).visible
            let point = Vec2(frame[0] + frame[2] / 2, frame[1] + frame[3] / 2)
            rt.pointerDown(at: point, at: t)
            rt.pointerUp(at: point, at: t + 0.001)
            settle()
        }
        try click("review-file")
        #expect(rt.state.clicks == 1)

        rt.update(at: t) { s, tx in s.diff.scrollToLine(0, at: .init(side: .new, line: 130), keyPrefix: "df", tx: &tx) }
        var mounted: [Int] = []
        for _ in 0..<5 {
            t += 1.0 / 120
            _ = rt.renderFrame(at: t)
            mounted.append(rt.elements().filter { !$0.exiting && $0.key?.hasPrefix("df-df0.") == true }.count)
        }
        // The 16-row viewport lands immediately and fills one viewport of overscan per frame.
        #expect(mounted == [32, 48, 64, 80, 80])
        let target = try #require(rt.element(byKey: "df-df0.c130"))
        let clearance = ceil(sticky.rect[3] / DiffLayout.lineHeight) * DiffLayout.lineHeight
        #expect(target.rect[1] == clearance)

        rt.update(at: t) { s, _ in s.diff.setMode(.split) }
        settle()
        #expect(try #require(rt.element(byKey: "df-header")).rect[0] == 0)
        try click("df-fold")
        #expect(rt.element(byKey: "df-body") == nil)
        try click("df-fold")
        #expect(rt.state.diff.expanded && rt.scrollOffset(forKey: "df-body").y == 0)
    }

    @Test("Diff navigation before the first frame respects header visibility")
    @MainActor
    func navigateBeforeFirstFrame() throws {
        let lines = (1...260).map { " line \($0)" }
        let patch = ["--- a/test.rs", "+++ b/test.rs", "@@ -1,260 +1,260 @@"] + lines
        let file = try #require(FileDiff.parseUnified(patch.joined(separator: "\n")).first)
        for showHeader in [true, false] {
            let rt = Runtime(state: DiffState(diff: file), viewport: Vec2(600, 400)) { state, cx in
                DiffView<DiffState>(key: "df", kit: .neutral(dark: false), get: { $0 }, set: { $0 = $1 })
                    .showHeader(showHeader)
                    .build(state: state, cx: cx)
            }
            rt.update(at: 0) { state, tx in
                state.scrollToLine(0, at: .init(side: .new, line: 165), keyPrefix: "df", tx: &tx)
            }
            for tick in 0..<8 { _ = rt.renderFrame(at: Double(tick) / 120) }
            let row = try #require(rt.element(byKey: "df-df0.c165"))
            let clearance = ceil(DiffLayout.headerHeight / DiffLayout.lineHeight) * DiffLayout.lineHeight
            #expect(row.rect[1] == (showHeader ? clearance : 0))
        }
    }

    @Test("Large multi-file diffs mount the viewport and jump by stable document keys")
    @MainActor
    func multiFileVirtualization() throws {
        let lines = (1...128).map { (i: Int) in
            DiffLine(kind: .context, oldNumber: i, newNumber: i, text: i == 110 ? String(repeating: "w", count: 180) : "line \(i)")
        }
        let foldedSource = FileDiff(oldPath: "folded", newPath: "folded", hunks: [],
                                    source: DiffSource(oldLines: [], newLines: ["e\u{301}\t\tz"]))
        #expect(foldedSource.textColumns(tabSize: 4) == 9)
        #expect(foldedSource.textColumns(tabSize: 8) == 17)
        let hunk = DiffHunk(oldStart: 1, oldCount: lines.count, newStart: 1, newCount: lines.count, lines: lines)
        var files = (0..<32).map { FileDiff(oldPath: "f\($0)", newPath: "f\($0)", hunks: [hunk]) }
        files[31].hunks[0].lines[69].text = "last file's line 70"
        let kit = Kit.neutral(dark: false)
        let rt = Runtime(state: DiffState(files: files), viewport: Vec2(600, 400)) { s, cx in
            col().wFull().hFull().dir(.rtl).child(
                DiffView<DiffState>(key: "review", kit: kit, get: { $0 }, set: { $0 = $1 }).build(state: s, cx: cx)
            )
        }
        _ = rt.frame(at: 0)
        #expect(rt.element(byKey: "review-df0.c1") != nil)
        let oldNumber = try #require(rt.element(byKey: "review-o-0"))
        let newNumber = try #require(rt.element(byKey: "review-n-0"))
        #expect(oldNumber.rect[0] < newNumber.rect[0])
        #expect(rt.element(byKey: "review-f31-header") == nil)
        #expect(rt.elements().filter { $0.key?.hasPrefix("review-df") == true }.count < 100)

        rt.wheel(WheelEvent(dx: -250, dy: 0), at: Vec2(300, 200), now: 0.01)
        for tick in 1...5 { _ = rt.frame(at: 0.01 + Double(tick) / 120) }
        #expect(rt.scrollOffset(forKey: "review-body").x > 0)
        rt.setViewport(Vec2(450, 400), pixelScale: 1)
        _ = rt.frame(at: 0.07)
        let resizedHeader = try #require(rt.element(byKey: "review-header"))
        let resizedBody = try #require(rt.element(byKey: "review-body"))
        #expect(resizedHeader.rect[0] == resizedBody.rect[0])
        #expect(resizedHeader.rect[2] == resizedBody.rect[2])
        rt.update(at: 0.1) { state, tx in
            state.scrollToLine(31, at: DiffLineRef(side: .old, line: 70), keyPrefix: "review", tx: &tx)
        }
        for tick in 1...6 { _ = rt.frame(at: 0.1 + Double(tick) / 120) }
        let target = try #require(rt.element(byKey: "review-df31.c70"))
        #expect(rt.state.visibleFile == 31)
        let header = try #require(rt.element(byKey: "review-f31-header"))
        #expect(abs(header.rect[1] + header.rect[3] - target.rect[1]) <= 1)
        #expect(rt.element(byKey: "review-row-0") == nil)
        let mountedRows = rt.elements().filter { !$0.exiting && $0.key?.hasPrefix("review-df") == true }.count
        // The destination is away from both ends: one 400-point viewport and two on either side.
        let maximumRows = Int(ceil(5 * rt.viewport.y / DiffLayout.lineHeight))
        #expect(mountedRows <= maximumRows)

        let original = rt.state
        rt.update(at: 0.2) { state, _ in
            state.annotations.append(DiffAnnotation(id: "reviewer", file: 31, side: .new, line: 70, body: "note"))
        }
        _ = rt.frame(at: 0.2)
        #expect(rt.element(byKey: "review-f31-note-reviewer") != nil)
        var selected = original
        selected.visibleFile = 0
        let point = DiffLineRef(side: .new, line: 70)
        selected.select(DiffLineRange(file: 31, start: point, end: point))
        #expect(selected.copyText() == "last file's line 70")
        #expect(original.rows(file: 31).count == 128)
        #expect(rt.state.rows(file: 31).count == 129)
        rt.update(at: 0.3) { state, _ in state.setCollapsed(file: 31, true) }
        _ = rt.frame(at: 0.3)
        #expect(rt.element(byKey: "review-df31.c70") == nil)
    }

    @Test("Unified diff rows preserve intrinsic code height across wrap and size changes")
    @MainActor
    func unifiedIntrinsicRowHeight() throws {
        struct Host: Sendable {
            var diff: DiffState
            var lineHeight: Float = 18
        }
        let values = ["plain", "first\nsecond\nthird", "last", String(repeating: "word ", count: 40)]
        let lines = values.enumerated().map { i, value in
            DiffLine(kind: .context, oldNumber: i + 1, newNumber: i + 1, text: value, noNewline: i == 2)
        }
        let hunk = DiffHunk(oldStart: 1, oldCount: 4, newStart: 1, newCount: 4, lines: lines)
        let file = FileDiff(oldPath: "test", newPath: "test", hunks: [hunk])
        let rt = Runtime(state: Host(diff: DiffState(diff: file)), viewport: Vec2(640, 400), pixelScale: 2) { s, cx in
            var kit = Kit.neutral(dark: false)
            kit.ty.mono = TextStyle(size: 12).mono().lh(s.lineHeight)
            return DiffView<Host>(key: "diff", kit: kit, get: { $0.diff }, set: { $0.diff = $1 }).build(state: s, cx: cx)
        }
        func height(_ line: Int) throws -> Float {
            try #require(rt.element(byKey: "diff-df0.c\(line)")).rect[3]
        }
        _ = rt.frame(at: 0)
        #expect(try height(1) == DiffLayout.lineHeight)
        #expect(try height(2) == 54)
        #expect(try height(3) > DiffLayout.lineHeight)
        #expect(try height(4) == DiffLayout.lineHeight)

        rt.setViewport(Vec2(275, 400), pixelScale: 2)
        rt.update(at: 0.1) { state, _ in state.diff.wrap = true }
        _ = rt.frame(at: 0.1)
        #expect(try height(2) == 54)
        rt.update(at: 0.2) { state, _ in
            state.diff.wrap = false
            state.lineHeight = 41.125
        }
        _ = rt.frame(at: 0.2)
        #expect(try height(1) == 41.125)
        #expect(try height(2) == 123.375)
        #expect(try height(4) == 41.125)
    }

    // Compare with rune-kit/tests/diff.rs::diff_50k_time in the Rust perf profile.
    @Test("Release diff timings for commits, scrolling, flings and jumps",
          .enabled(if: ProcessInfo.processInfo.environment["RUNE_DIFF_BENCH"] == "1"))
    @MainActor
    func diff50kTimings() {
        let kit = Kit.neutral(dark: true)
        func measure(_ work: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            work()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
        func open(_ count: Int) -> Runtime<DiffState> {
            let old = (1...count).map { "let value_\($0) = compute(\($0));\n" }.joined()
            let new = (1...count).map { "let value_\($0) = compute(\($0))\($0 % 7 == 0 ? " + 1" : "");\n" }.joined()
            let file = FileDiff.fromTexts(path: "big.rs", old: old, new: new)
            let st = DiffState(diff: file)
            let rows = st.rows().count
            let rt = Runtime(state: st, viewport: Vec2(1200, 900), pixelScale: 2) { state, cx in
                DiffView<DiffState>(key: "dv", kit: kit, get: { $0 }, set: { $0 = $1 })
                    .onSelect { _, _, _ in }.onComment { _, _, _ in }
                    .build(state: state, cx: cx)
            }
            let ms = measure { _ = rt.renderFrame(at: 0) }
            let mounted = rt.elements().filter { $0.key?.hasPrefix("dv-df") == true }.count
            print("diff \(count) lines, \(rows) rows, first frame \(ms) ms, \(mounted) mounted")
            #expect(mounted > 0 && mounted < 160)
            return rt
        }
        for count in [300, 50_000] {
            let rt = open(count)
            var t = 0.0
            func frame() { t += 1.0 / 120.0; _ = rt.renderFrame(at: t) }
            for _ in 0..<30 { frame() }
            func sample(_ label: String, _ n: Int, prepare: (Int) -> Void = { _ in }) {
                var times: [Double] = []
                let initialCommits = rt.viewCommitCount
                for i in 0..<n { prepare(i); times.append(measure(frame)) }
                times.sort()
                print("diff \(count) \(label) frame ms p50 \(times[n / 2]) p90 \(times[n * 9 / 10]) p99 \(times[n * 99 / 100]), \(rt.viewCommitCount - initialCommits)/\(n) commits")
            }
            sample("commit", 200) { _ in rt.invalidate(at: t) }
            if count == 50_000 {
                sample("idle", 200)
                for dy: Float in [-30, -400] {
                    sample("wheel \(dy)", 600) { _ in rt.wheel(WheelEvent(dx: 0, dy: dy), at: Vec2(600, 450), now: t) }
                }
                sample("jump", 20) { i in
                    rt.wheel(WheelEvent(dx: 0, dy: i.isMultiple(of: 2) ? -300_000 : 150_000), at: Vec2(600, 450), now: t)
                }
            }
        }
    }

    @Test("tests/diff.rs #184: hovering lines at rest builds nothing new under checkLiveOnly")
    @MainActor
    func hoveringLinesAtRestBuildsNothingNew() throws {
        let kit = Kit.neutral(dark: false)
        let old = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let new = (1...40).map { ($0 % 3 == 0) ? "line \($0) edited" : "line \($0)" }.joined(separator: "\n")
        for (mode, wrap) in [(DiffMode.unified, false), (.unified, true), (.split, true)] {
            var diff = DiffState(diff: FileDiff.fromTexts(path: "a.rs", old: old, new: new, context: 40))
            diff.setMode(mode)
            diff.wrap = wrap
            let rt = Runtime<DiffState>(state: diff, viewport: Vec2(900, 1200)) { s, cx in
                DiffView<DiffState>(key: "dv", kit: kit, get: { $0 }, set: { $0 = $1 }).build(state: s, cx: cx)
            }
            var t = 0.0
            _ = rt.frame(at: t)
            let cells = rt.elements().filter(isCodeCell)
            func move(to cell: ElementInfo) {
                let x = cell.rect[0] + cell.rect[2] / 2
                let y = cell.rect[1] + cell.rect[3] / 2
                rt.pointerMove(to: Vec2(x, y), at: t)
                t += 1.0 / 60.0
                _ = rt.frame(at: t)
            }
            #expect(cells.count > 30)
            let checks = rt.liveOnlyEvents
            for (i, cell) in cells.enumerated() {
                if i % 2 == 0 {
                    t += 0.3
                    _ = rt.frame(at: t)
                }
                move(to: cell)
            }
            #expect(rt.liveOnlyEvents > checks)
            #expect(rt.liveOnlyWarnings.isEmpty, "Unexpected liveOnly warnings for \(mode): \(rt.liveOnlyWarnings)")

            // Count real view builds without the debug stale-view checks above.
            rt.checkLiveOnly(false)
            let sides: [(String, DiffSide)] = mode == .unified
                ? [("dv-code-", .new)] : [("dv-ccode-o-", .old), ("dv-ccode-n-", .new)]
            for (prefix, side) in sides {
                let first = try #require(rt.element(byKey: prefix + "0"))
                let second = try #require(rt.element(byKey: prefix + "1"))
                move(to: first)
                let commits = rt.viewCommitCount
                let skips = rt.liveOnlyEvents
                move(to: second)
                #expect(rt.state.copySide == side)
                #expect(rt.liveOnlyEvents == skips + 2)
                #expect(rt.viewCommitCount == commits)
            }
        }
    }

    @Test("src/diff/model.rs #29: texts_make_hunks_with_three_lines_of_context")
    func textsMakeHunksWithThreeLinesOfContext() {
        let oldLines = (1...20).map { "line \($0)" }
        var newLines = oldLines
        newLines[4] = "five"
        newLines[16] = "seventeen"

        let diff = FileDiff.fromTexts(
            path: "sample.txt",
            old: oldLines.joined(separator: "\n"),
            new: newLines.joined(separator: "\n"),
            context: 3
        )
        #expect(diff.hunks.map(\.header) == [
            "@@ -2,7 +2,7 @@ line 1",
            "@@ -14,7 +14,7 @@ line 13",
        ])
        #expect(diff.additionsCount == 2)
        #expect(diff.deletionsCount == 2)

        let h0 = diff.hunks[0]
        #expect(h0.oldStart == 2 && h0.oldCount == 7 && h0.newStart == 2 && h0.newCount == 7)
        #expect(h0.lines.map(\.kind) == [
            .context, .context, .context, .deletion, .addition, .context, .context, .context
        ])
        #expect(h0.lines[0].oldLine == 2 && h0.lines[0].newLine == 2)
        #expect(h0.lines[3].oldLine == 5 && h0.lines[3].newLine == nil && h0.lines[3].text == "line 5")
        let added = h0.lines[4]
        #expect(added.oldLine == nil && added.newLine == 5 && added.text == "five")
        #expect(added.changes.map { String(decoding: Array(added.text.utf8)[$0], as: UTF8.self) } == ["five"])

        let h1 = diff.hunks[1]
        #expect(h1.oldStart == 14 && h1.oldCount == 7 && h1.newStart == 14 && h1.newCount == 7)
        #expect(h1.lines[3].oldLine == 17 && h1.lines[4].newLine == 17)
        #expect(h1.lines[4].changes.map { String(decoding: Array(h1.lines[4].text.utf8)[$0], as: UTF8.self) } == ["seventeen"])
    }

    @Test("Diff syntax uses 128 raw source lines, folded context, and side-specific hunk text")
    func syntaxChunksUseRawSideLines() {
        let old = ["/*", "\té OLD", "*/"]
        let new = ["let", "\té NEW", ";"]
        let hunk = DiffHunk(oldStart: 2, oldCount: 1, newStart: 2, newCount: 1, lines: [
            DiffLine(kind: .deletion, oldNumber: 2, newNumber: nil, text: old[1]),
            DiffLine(kind: .addition, oldNumber: nil, newNumber: 2, text: new[1])
        ])
        let file = FileDiff(oldPath: "code.rs", newPath: "code.rs", hunks: [hunk],
                            source: DiffSource(oldLines: old, newLines: new))
        let st = DiffState(diff: file)
        // Folded first and third lines open and close the comment around the visible deletion.
        let commentEnd = old[1].utf8.count
        let comment = SyntaxHighlight(range: 0..<commentEnd, paint: .kind(.comment))
        #expect(st.highlights(file: 0, side: .old, line: 2) == [comment])

        let custom = SyntaxHighlighter { _, source in
            guard let word = source.range(of: "NEW"), source.utf8.filter({ $0 == 10 }).count == 128 else { return [] }
            let start = source.utf8.distance(from: source.startIndex, to: word.lowerBound)
            return [SyntaxHighlight(range: start..<(start + 3), paint: .kind(.keyword))]
        }
        let colored = st.highlights(file: 0, side: .new, line: 2, using: custom)
        #expect(colored == [SyntaxHighlight(range: 4..<7, paint: .kind(.keyword))])
        let kit = Kit.neutral(dark: false)
        let theme = SyntaxTheme.fromKit(kit)
        let (shown, offsets, _) = DiffViewHelpers.formattedCode(new[1], tabSize: 4, wrap: false)
        let spans = DiffViewHelpers.mergeCodeSpans(code: shown, offsetMap: offsets,
                                                   highlights: colored, changedRanges: [4..<7], defaultColor: kit.c.textBase,
                                                   syntaxTheme: theme, wordBg: kit.c.warning.bg)
        #expect(spans.map(\.text).joined() == "\t   é NEW")
        #expect(spans.last?.text == "NEW" && spans.last?.color == theme.color(for: .keyword) && spans.last?.background == kit.c.warning.bg)
        var copy = st
        copy.files[0].source = nil
        #expect(copy.highlights(file: 0, side: .old, line: 2).allSatisfy { $0.paint != .kind(.comment) })
        #expect(copy.highlights(file: 0, side: .new, line: 2, using: custom) == colored)
        #expect(st.highlights(file: 0, side: .old, line: 2) == [comment])
        copy.files[0].newPath = "unknown.ext"
        #expect(copy.highlights(file: 0, side: .old, line: 2).isEmpty)

        let insertion = DiffHunk(oldStart: 1, oldCount: 0, newStart: 2, newCount: 1, lines: [
            DiffLine(kind: .addition, oldNumber: nil, newNumber: 2, text: "inserted")
        ])
        let oneSide = FileDiff(oldPath: "gap.rs", newPath: "gap.rs", hunks: [insertion],
                               source: DiffSource(oldLines: [], newLines: ["/*", "inserted", "gap", "*/"]))
        #expect(DiffState(diff: oneSide).highlights(file: 0, side: .old, line: 2) == [
            SyntaxHighlight(range: 0..<3, paint: .kind(.comment))
        ])
    }

    @Test("Rendered diff rows reuse only visited syntax chunks and refresh identical lines after source or highlighter replacement")
    @MainActor
    func syntaxChunksFollowMountedRows() {
        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            private var texts: [String] = []
            func append(_ text: String) { lock.withLock { texts.append(text) } }
            var inputs: [String] { lock.withLock { texts } }
        }
        func file(_ first: String) -> FileDiff {
            let lines = [first, "payload"] + (3...384).map { "line \($0)" }
            return FileDiff.fromTexts(path: "unknown.ext", old: "", new: lines.joined(separator: "\n") + "\n")
        }
        let calls = Calls()
        let color = Color(r: 1, g: 0, b: 1)
        let syntax = SyntaxHighlighter(id: UUID().uuidString) { _, text in
            calls.append(text)
            guard text.hasPrefix("/*\npayload\n") else { return [] }
            return [SyntaxHighlight(range: 3..<10, paint: .color(color))]
        }
        var initial = DiffState(diff: file("/*"))
        initial.highlighter = syntax
        let kit = Kit.neutral(dark: false)
        let rt = Runtime(state: initial, viewport: Vec2(520, 200)) { s, cx in
            DiffView<DiffState>(key: "dv", kit: kit, get: { $0 }, set: { $0 = $1 }).build(state: s, cx: cx)
        }
        func painted(at t: Double) -> Bool {
            let scene = rt.frame(at: t)
            return scene.primitives.contains { $0.kind == .glyph && $0.fill == color.simd4(srgb: scene.srgbBlend) }
        }
        #expect(painted(at: 0))
        #expect(calls.inputs.count == 1 && calls.inputs[0].hasSuffix("line 128\n"))
        rt.invalidate(at: 0.01)
        #expect(painted(at: 0.01))
        #expect(calls.inputs.count == 1)
        _ = initial.highlights(file: 0, side: .new, line: 129, using: syntax)
        #expect(calls.inputs.count == 2 && calls.inputs[1].hasPrefix("line 129\n"))
        _ = initial.highlights(file: 0, side: .new, line: 256, using: syntax)
        #expect(calls.inputs.count == 2)
        let replacement = file("//")
        rt.update(at: 0.02) { s, _ in s.files[0] = replacement }
        #expect(!painted(at: 0.02))
        let all = SyntaxHighlighter { _, source in
            [SyntaxHighlight(range: 0..<source.utf8.count, paint: .color(color))]
        }
        rt.update(at: 0.03) { s, _ in s.setHighlighter(all) }
        #expect(painted(at: 0.03))
        let blank = SyntaxHighlighter { _, _ in [] }
        let overridden = Runtime(state: initial, viewport: Vec2(520, 200)) { s, cx in
            var view = DiffView<DiffState>(key: "dv", kit: kit, get: { $0 }, set: { $0 = $1 })
            view.highlighter = blank
            return view.build(state: s, cx: cx)
        }
        let scene = overridden.frame(at: 0)
        #expect(!scene.primitives.contains { $0.kind == .glyph && $0.fill == color.simd4(srgb: scene.srgbBlend) })
    }

    @Test("src/diff/view.rs #46: word_backgrounds_cut_syntax_colours")
    func wordBackgroundsCutSyntaxColours() {
        let kit = Kit.neutral(dark: false)
        let theme = SyntaxTheme.fromKit(kit)
        let kwColor = theme.color(for: .keyword)
        let strColor = theme.color(for: .string)
        let wordBg = kit.c.success.bg.alpha(0.35)

        let spans = DiffViewHelpers.mergeCodeSpans(
            code: "foobarbaz!",
            offsetMap: nil,
            highlights: [
                SyntaxHighlight(range: 0..<6, paint: .kind(.keyword)),
                SyntaxHighlight(range: 6..<10, paint: .kind(.string)),
            ],
            changedRanges: [3..<8],
            defaultColor: kit.c.textBase,
            syntaxTheme: theme,
            wordBg: wordBg
        )
        #expect(spans.count == 4)
        #expect(spans[0].text == "foo" && spans[0].color == kwColor && spans[0].background == nil)
        #expect(spans[1].text == "bar" && spans[1].color == kwColor && spans[1].background == wordBg)
        #expect(spans[2].text == "ba" && spans[2].color == strColor && spans[2].background == wordBg)
        #expect(spans[3].text == "z!" && spans[3].color == strColor && spans[3].background == nil)
    }
}
