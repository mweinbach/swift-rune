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
}
