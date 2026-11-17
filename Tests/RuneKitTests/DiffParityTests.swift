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
    func diffRuntimeVirtualDragStickyAndPerfWarnParity() {
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
        if let vBody = vRT.element(byKey: "dv-body"), let row0 = vRT.element(byKey: "dv-row-0") {
            #expect(abs(row0.rect[1] - vBody.rect[1]) < 2.0)
        }

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
            if let p4 = selRT.element(byKey: "dv-n-\(r4)-plus") {
                let c4 = Vec2(p4.rect[0] + p4.rect[2] * 0.5, p4.rect[1] + p4.rect[3] * 0.5)
                selRT.pointerDown(at: c4, at: st); selRT.pointerUp(at: c4, at: st + 0.01); st += 0.02
                _ = selRT.frame(at: st)
                #expect(selRT.state.comments == [range35])
            }
            if let p9 = selRT.element(byKey: "dv-n-\(r9)-plus") {
                let c9 = Vec2(p9.rect[0] + p9.rect[2] * 0.5, p9.rect[1] + p9.rect[3] * 0.5)
                selRT.pointerDown(at: c9, at: st); selRT.pointerUp(at: c9, at: st + 0.01); st += 0.02
                _ = selRT.frame(at: st)
                let nine = DiffLineRange(start: DiffLineRef(side: .new, line: 9), end: DiffLineRef(side: .new, line: 9))
                #expect(selRT.state.comments.count == 2 && selRT.state.comments[1] == nine)
            }

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
            let codeCells = lRT.elements().filter { ($0.path).hasSuffix("/code") || ($0.key ?? "").contains("-code-") || ($0.key ?? "").contains("-ccode-") }
                .filter { $0.rect.count == 4 }
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

        // DiffState.scrollToLine expands collapsed gap and scrolls to target file line
        var collapsedFileState = DiffState(diff: folded)
        var tx = Tx()
        collapsedFileState.scrollToLine(0, at: DiffLineRef(side: .new, line: 15), keyPrefix: "dv", tx: &tx)
        #expect(!collapsedFileState.collapsed(file: 0))
        #expect(!tx.scrollOffsetRequests.isEmpty)
        #expect(tx.scrollOffsetRequests.last?.key == "dv-body")
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
        #expect(rt.liveOnlyWarnings.count == 1)

        // #186: 50k-line scattered diff (every 7th changed) constructs & renders windowed slice quickly
        let old50 = (1...50_000).map { "let v_\($0) = compute(\($0));" }.joined(separator: "\n")
        let new50 = (1...50_000).map { ($0 % 7 == 0) ? "let v_\($0) = compute(\($0)) + 1;" : "let v_\($0) = compute(\($0));" }.joined(separator: "\n")
        let bigFile = FileDiff.fromTexts(path: "big.rs", old: old50, new: new50, context: 3)
        let bigRT = Runtime<DiffState>(state: DiffState(diff: bigFile), viewport: Vec2(1200, 900)) { s, cx in
            DiffView<DiffState>(key: "dv50k", kit: kit, get: { $0 }, set: { $0 = $1 }).build(state: s, cx: cx)
        }
        _ = bigRT.frame(at: 0.0)
        #expect(bigRT.state.rows(file: 0).count > 10_000)
        #expect(bigRT.elements().filter { ($0.key ?? "").hasPrefix("dv50k-row-") }.count < 160)
    }

    @Test("tests/diff.rs #184: hovering lines at rest builds nothing new under checkLiveOnly")
    @MainActor
    func hoveringLinesAtRestBuildsNothingNew() {
        let kit = Kit.neutral(dark: false)
        let old = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let new = (1...40).map { ($0 % 3 == 0) ? "line \($0) edited" : "line \($0)" }.joined(separator: "\n")
        for mode in [DiffMode.unified, DiffMode.split] {
            var diff = DiffState(diff: FileDiff.fromTexts(path: "a.rs", old: old, new: new, context: 40))
            diff.setMode(mode)
            let rt = Runtime<DiffState>(state: diff, viewport: Vec2(900, 1200)) { s, cx in
                DiffView<DiffState>(key: "dv", kit: kit, get: { $0 }, set: { $0 = $1 }).build(state: s, cx: cx)
            }
            var t = 0.0
            _ = rt.frame(at: t)
            let cells = rt.elements().filter {
                let k = $0.key ?? ""
                return !$0.exiting && (
                    k.hasPrefix("dv-code-") || k.hasPrefix("dv-scode-") || k.hasPrefix("dv-ccode-") || k.hasPrefix("dv-dcode-") || k.hasPrefix("dv-acode-")
                )
            }
            #expect(cells.count > 30)
            let checks = rt.liveOnlyEvents
            for (i, cell) in cells.enumerated() {
                if i % 2 == 0 {
                    t += 0.3
                    _ = rt.frame(at: t)
                }
                let cx = cell.rect[0] + cell.rect[2] * 0.5
                let cy = cell.rect[1] + cell.rect[3] * 0.5
                rt.pointerMove(to: Vec2(cx, cy), at: t)
                t += 1.0 / 60.0
                _ = rt.frame(at: t)
            }
            #expect(rt.liveOnlyEvents > checks)
            #expect(rt.liveOnlyWarnings.isEmpty, "Unexpected liveOnly warnings for \(mode): \(rt.liveOnlyWarnings)")
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

    @Test("src/diff/view.rs #46: word_backgrounds_cut_syntax_colours")
    func wordBackgroundsCutSyntaxColours() {
        let kit = Kit.neutral(dark: false)
        let theme = SyntaxTheme.fromKit(kit)
        let kwColor = theme.color(for: .keyword)
        let strColor = theme.color(for: .string)
        let wordBg = kit.c.success.bg.alpha(0.35)

        let spans = DiffViewHelpers.mergeCodeSpans(
            code: "foobarbaz!",
            rawCount: 10,
            offsetMap: nil,
            highlights: [
                SyntaxHighlight(range: 0..<6, paint: .kind(.keyword)),
                SyntaxHighlight(range: 6..<10, paint: .kind(.string)),
            ],
            changedRanges: [3..<8],
            defaultColor: kit.c.textBase,
            syntaxTheme: theme,
            wordBg: wordBg,
            wrap: false
        )
        #expect(spans.count == 4)
        #expect(spans[0].text == "foo" && spans[0].color == kwColor && spans[0].background == nil)
        #expect(spans[1].text == "bar" && spans[1].color == kwColor && spans[1].background == wordBg)
        #expect(spans[2].text == "ba" && spans[2].color == strColor && spans[2].background == wordBg)
        #expect(spans[3].text == "z!" && spans[3].color == strColor && spans[3].background == nil)
    }
}
