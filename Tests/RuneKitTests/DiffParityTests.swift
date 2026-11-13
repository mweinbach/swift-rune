import Testing
@testable import RuneKit
import Rune

@Suite("RuneKit Diff Full Parity Tests (Increment 3)")
struct DiffParityTests {
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
    private func clickElement(_ rt: Runtime<HostState>, key: String, at now: Double) -> Bool {
        guard let el = rt.element(byKey: key), el.rect.count == 4 else { return false }
        let pt = Vec2(el.rect[0] + el.rect[2] * 0.5, el.rect[1] + el.rect[3] * 0.5)
        rt.pointerDown(at: pt, at: now)
        rt.pointerUp(at: pt, at: now + 0.01)
        return true
    }

    @Test("DiffView toggles fold/mode/wrap, expands gaps, and copies text through Runtime")
    @MainActor
    func diffViewInteractiveControls() {
        let oldLines = (1...50).map { "line \($0)" }
        var newLines = oldLines
        newLines[45] = "line 46 modified"
        let diff = FileDiff.between(
            old: oldLines.joined(separator: "\n"),
            new: newLines.joined(separator: "\n"),
            path: "Demo.swift"
        )
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
        rt.frame(at: 0.1)
        #expect(rt.state.diff.mode == .split)

        // Toggle wrap
        #expect(clickElement(rt, key: "d-wrap", at: 0.2))
        rt.frame(at: 0.2)
        #expect(rt.state.diff.wrap)

        // Expand gap
        let gapsBefore = rt.state.diff.computeGaps().count
        #expect(clickElement(rt, key: "d-gap-0-all", at: 0.3))
        rt.frame(at: 0.3)
        #expect(rt.state.diff.computeGaps().count < gapsBefore)

        // Copy button
        #expect(clickElement(rt, key: "d-copy", at: 0.4))
        rt.frame(at: 0.4)
        #expect(rt.state.diff.copiedToastVisible)
        #expect(rt.state.copied?.contains("line 46 modified") == true)

        // Fold toggle hides body
        #expect(clickElement(rt, key: "d-fold", at: 0.5))
        rt.frame(at: 0.5)
        #expect(!rt.state.diff.expanded)
        #expect(rt.element(byKey: "d-body") == nil)
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
        #expect(!tx.scrollToRequests.isEmpty)
        #expect(state.key(KeyEvent(key: .text("[")), tx: &tx))
        #expect(state.visibleFile == 0)

        state.select(DiffLineRange(
            start: DiffLineRef(side: .old, line: 1),
            end: DiffLineRef(side: .old, line: 1)
        ))
        let hoveredOld = state.hoverText(side: .old, cell: "c-old", inside: true)
        #expect(hoveredOld)
        #expect(state.copySide == .old)
        let cmdCOld = state.key(KeyEvent(key: .command("c"), mods: Mods(cmd: true)), tx: &tx)
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
        let cmdCNew = state.key(KeyEvent(key: .command("c"), mods: Mods(cmd: true)), tx: &tx)
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
        if let plus = rt.element(byKey: "mv-o-0-plus"), plus.rect.count == 4 {
            let pt = Vec2(plus.rect[0] + plus.rect[2] * 0.5, plus.rect[1] + plus.rect[3] * 0.5)
            rt.pointerDown(at: pt, at: 0.1)
            rt.pointerUp(at: pt, at: 0.12)
            rt.frame(at: 0.12)
            #expect(rt.state.commented == DiffLineRange(
                start: DiffLineRef(side: .old, line: 1),
                end: DiffLineRef(side: .old, line: 1)
            ))
        } else {
            Issue.record("Missing mv-o-0-plus comment button")
        }
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

        // #35: 30k lines with 50 scattered edits reconstruct cleanly and match expected equal count
        let nLarge = 30_000
        let base = (0..<nLarge).map { $0 }
        var edited = base
        for k in 0..<50 {
            let idx = (k * 599 + 17) % nLarge
            edited[idx] = nLarge + k
        }
        let hugeOps = Myers.diff(base, edited)
        var hugeEq = 0
        for op in hugeOps {
            if case .equal(let c) = op { hugeEq += c }
        }
        #expect(hugeEq == nLarge - 50)

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

    @Test("diff/view.rs: DiffViewHelpers expandTabsWithOffsets, insertSoftBreaks, mergeCodeSpans, rowLabel (#46-#48)")
    func diffViewHelpersParity() {
        let (expanded, map) = DiffViewHelpers.expandTabsWithOffsets("\ta\té", tabSize: 4)
        #expect(expanded == "    a   é")
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
        let highlights = [
            SyntaxHighlight(range: 0..<2, paint: .kind(.punctuation)), // "a."
            SyntaxHighlight(range: 2..<4, paint: .kind(.property)),    // "b/"
            SyntaxHighlight(range: 4..<6, paint: .kind(.variable)),    // "c "
        ]
        let kit = Kit.neutral(dark: false)
        let theme = SyntaxTheme.fromKit(kit)
        let spans = DiffViewHelpers.mergeCodeSpans(
            code: code,
            rawCount: code.utf8.count,
            offsetMap: nil,
            highlights: highlights,
            changedRanges: [2..<3], // "b"
            defaultColor: kit.c.textBase,
            syntaxTheme: theme,
            wordBg: kit.c.warning.bg,
            wrap: true
        )
        let joined = spans.map(\.text).joined()
        #expect(joined == "a.\u{200B}b/\u{200B}c ")
        #expect(spans.contains(where: { $0.text.contains("b") && $0.background == kit.c.warning.bg }))

        // Disabled wrap keeps original characters
        #expect(DiffViewHelpers.insertSoftBreaks("a.b(c)[d]/e", enabled: false) == "a.b(c)[d]/e")
        #expect(DiffViewHelpers.insertSoftBreaks("a. b/ ", enabled: true) == "a. b/ ")

        // rowLabel formatting
        let added = DiffLine(kind: .addition, oldNumber: nil, newNumber: 7, text: "let x = 1")
        let removed = DiffLine(kind: .deletion, oldNumber: 4, newNumber: nil, text: "let y = 2")
        let ctx = DiffLine(kind: .context, oldNumber: 10, newNumber: 11, text: "keep")
        #expect(DiffViewHelpers.rowLabel(added) == "added line 7: let x = 1")
        #expect(DiffViewHelpers.rowLabel(removed) == "removed line 4: let y = 2")
        #expect(DiffViewHelpers.rowLabel(ctx, side: .old) == "unchanged line 10: keep")
        #expect(DiffViewHelpers.rowLabel(ctx, side: .new) == "unchanged line 11: keep")
    }

    @Test("tests/diff.rs: note coords in unified & split (#175)")
    @MainActor
    func diffRuntimeNoteCoordsParity() {
        struct AppState: Sendable {
            var diff: DiffState
            var toggledNote: Bool = false
        }

        let kit = Kit.neutral(dark: false)
        let oldText = (1...20).map { "func line\($0)() -> Int { return \($0) }" }.joined(separator: "\n")
        var newLines = (1...20).map { "func line\($0)() -> Int { return \($0) }" }
        newLines[1] = "func line2Changed() -> Int { return 999 }"
        let fileDiff = FileDiff.fromTexts(path: "Sources/Demo.swift", old: oldText, new: newLines.joined(separator: "\n"), context: 3)

        for mode in [DiffMode.unified, DiffMode.split] {
            let st = AppState(
                diff: DiffState(
                    diff: fileDiff,
                    mode: mode,
                    annotations: [DiffAnnotation(id: "note-1", file: 0, side: .new, line: 2, author: "rev", body: "Check name")]
                )
            )
            let rt = Runtime<AppState>(
                state: st,
                viewport: Vec2(720, 420),
                view: { s, cx in
                    DiffView<AppState>(key: "dv", kit: kit, get: { $0.diff }, set: { $0.diff = $1 })
                        .viewportHeight(360)
                        .annotation { _, a in
                            El<AppState>(direction: .row).key("custom-note-\(a.id)").h(88)
                                .child(text(a.body))
                        }
                        .onLineClick { st, ref, _ in
                            st.toggledNote.toggle()
                            if st.toggledNote {
                                st.diff.annotations.append(DiffAnnotation(id: "note-clicked", file: 0, side: ref.side, line: ref.line, body: "Added"))
                            } else {
                                st.diff.annotations.removeAll { $0.id == "note-clicked" }
                            }
                        }
                        .build(state: s, cx: cx)
                }
            )
            _ = rt.frame(at: 0.01)
            let noteEl = rt.element(byKey: "custom-note-note-1")
            #expect(noteEl != nil)
            let targetKey = (mode == .unified) ? "dv-n-2" : "dv-sn-1"
            let cell = rt.element(byKey: targetKey)
            #expect(cell != nil)
            if let noteRect = noteEl?.rect, noteRect.count == 4,
               let cellRect = cell?.rect, cellRect.count == 4 {
                #expect(noteRect[1] >= cellRect[1])
                if mode == .split {
                    // Split mode right-side note sits on the right half (`x >= cellRect[0] - 10`)
                    #expect(noteRect[0] >= 350)
                }
                let pt = Vec2(cellRect[0] + cellRect[2] * 0.5, cellRect[1] + cellRect[3] * 0.5)
                rt.pointerDown(at: pt, at: 0.02)
                rt.pointerUp(at: pt, at: 0.03)
                _ = rt.frame(at: 0.04)
                #expect(rt.state.toggledNote == true)
                #expect(rt.element(byKey: "custom-note-note-clicked") != nil)
            }
        }
    }

    @Test("tests/diff.rs: virtualization with tall notes (#176), drag/escape (#178, #180), sticky header & gutter (#179, #181), labels & hunks (#182), PerfWarn (#184-#185)")
    @MainActor
    func diffRuntimeVirtualDragStickyAndPerfWarnParity() {
        struct AppState: Sendable {
            var diff: DiffState
            var selected: DiffLineRange? = nil
        }

        let kit = Kit.neutral(dark: false)
        let oldText = (1...80).map { "func line\($0)() -> Int { return \($0) }" }.joined(separator: "\n")
        var newLines = (1...80).map { "func line\($0)() -> Int { return \($0) }" }
        newLines[0] = "// changed header line that is super super wide so horizontal scrolling can be exercised thoroughly in runtime viewports"
        newLines[1] = "func line2Changed() -> Int { return 999 }"
        newLines[75] = "func line76() -> Int { return -1 }"

        PerfWarn.resetForTesting()
        let bigDiff = FileDiff.fromTexts(
            path: "Sources/Big.swift",
            old: oldText,
            new: newLines.joined(separator: "\n"),
            context: 60
        )
        let rt = Runtime<AppState>(
            state: AppState(diff: DiffState(
                diff: bigDiff,
                annotations: [DiffAnnotation(id: "tall", file: 0, side: .new, line: 4, body: "Tall note")]
            )),
            viewport: Vec2(360, 320),
            onKey: { state, ev, tx in
                state.diff.key(ev, keyPrefix: "dv", tx: &tx)
            },
            view: { s, cx in
                El<AppState>(direction: .column).wFull().hFull()
                    .child(
                        DiffView<AppState>(key: "dv", kit: kit, get: { $0.diff }, set: { $0.diff = $1 })
                            .viewportHeight(220)
                            .annotation { _, a in
                                El<AppState>(direction: .row).key("tall-\(a.id)").h(110).child(text(a.body))
                            }
                            .onSelect { state, range, _ in
                                state.selected = range
                            }
                            .build(state: s, cx: cx)
                    )
            }
        )
        _ = rt.frame(at: 0.01)

        // #176: virtualization skips bottom rows out of viewport
        #expect(rt.element(byKey: "dv-row-0") != nil)
        #expect(rt.element(byKey: "dv-row-75") == nil)
        let tall = rt.element(byKey: "tall-tall")
        #expect(tall != nil)
        #expect(abs((tall?.rect[3] ?? 0) - 110) < 2)

        // #182: accessible heading label + row labels
        let heading = rt.elements().first(where: { $0.role == .heading })
        #expect(heading?.label?.contains("Sources/Big.swift") == true)
        #expect(rt.elements().contains(where: { $0.label?.hasPrefix("removed line ") == true }))
        #expect(rt.elements().contains(where: { $0.label?.hasPrefix("added line ") == true }))
        #expect(rt.elements().contains(where: { $0.label?.hasPrefix("unchanged line ") == true }))

        // #180 & #178: press line 2, drag to line 4, Escape during drag cancels without firing onSelect
        if let n1 = rt.element(byKey: "dv-n-1"), let n3 = rt.element(byKey: "dv-n-3"),
           n1.rect.count == 4, n3.rect.count == 4 {
            let p1 = Vec2(n1.rect[0] + n1.rect[2] * 0.5, n1.rect[1] + n1.rect[3] * 0.5)
            let p3 = Vec2(n3.rect[0] + n3.rect[2] * 0.5, n3.rect[1] + n3.rect[3] * 0.5)
            rt.pointerMove(to: p1, at: 0.05)
            rt.pointerDown(at: p1, at: 0.06)
            rt.pointerMove(to: p3, at: 0.07)
            _ = rt.keyDown(KeyEvent(key: .escape), at: 0.08)
            rt.pointerUp(at: p3, at: 0.09)
            _ = rt.frame(at: 0.10)
            #expect(rt.state.selected == nil)
            #expect(rt.state.diff.selectedRange == nil)
        }

        // #179 & #181: horizontal scroll keeps header & unified gutter pinned at left edge (`stickyLeft(0)`) & press still selects
        if let body = rt.element(byKey: "dv-body"), body.rect.count == 4 {
            let hdrBefore = rt.element(byKey: "dv-header")?.rect[0]
            let center = Vec2(body.rect[0] + body.rect[2] * 0.5, body.rect[1] + 60)
            rt.wheel(WheelEvent(dx: -120, dy: 0), at: center, now: 0.12)
            _ = rt.frame(at: 0.13)
            if let hdrAfter = rt.element(byKey: "dv-header")?.rect[0], let hdrBefore {
                #expect(abs(hdrAfter - hdrBefore) < 2.0)
            }
            let gutter = rt.element(byKey: "dv-gutter-1")
            #expect(gutter != nil)
            if let g = gutter, let b = rt.element(byKey: "dv-body") {
                #expect(abs(g.rect[0] - b.rect[0]) < 2.0)
            }
            if let cell = rt.element(byKey: "dv-o-0"), cell.rect.count == 4 {
                let pt = Vec2(cell.rect[0] + cell.rect[2] * 0.5, cell.rect[1] + cell.rect[3] * 0.5)
                rt.pointerDown(at: pt, at: 0.14)
                rt.pointerUp(at: pt, at: 0.15)
                _ = rt.frame(at: 0.16)
                #expect(rt.state.selected != nil)
            }
        }

        // #184-#185: hovering across lines & scrolling emits zero PerfWarn warnings
        for rowIdx in 0..<8 {
            if let codeEl = rt.element(byKey: "dv-code-\(rowIdx)"), codeEl.rect.count == 4 {
                rt.pointerMove(to: Vec2(codeEl.rect[0] + 20, codeEl.rect[1] + 10), at: 0.20 + Double(rowIdx) * 0.01)
                _ = rt.frame(at: 0.205 + Double(rowIdx) * 0.01)
            }
        }
        #expect(PerfWarn.takeTestLog(resetSites: true).isEmpty)
    }
}
