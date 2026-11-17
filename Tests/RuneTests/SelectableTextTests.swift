import Testing
import Foundation
@testable import Rune

@Suite("El & Runtime Item 4: SelectionStyle, Selection API, SelectAll & CopyJoin")
struct SelectableTextTests {

    #if canImport(Darwin) || os(Linux) || os(Android)
    @Test func dictionaryWordsUseRuneUTF8Offsets() {
        // Boundaries from the pinned ICU4X WordSegmenter::new_dictionary.
        let words = ["👩🏽‍💻", " ", "ภาษา", "ไทย", " ", "日本語", " ", "e\u{301}", " ", "五月", "天",
                     " ", "中华", "人民", "共和国", " ", "မြန်မာဘာသာ", "စကား", " ", "ພາສາ", "ລາວ",
                     " ", "ភាសាខ្មែរ", "ប្រទេស", "កម្ពុជា", " ", "3.14", "  ", "l’heure", "!"]
        let text = words.joined()
        var byte = 0
        for word in words {
            let end = byte + word.utf8.count
            for offset in byte..<end {
                let range = SelectionMath.unitRange(in: text, at: offset, unit: .word)
                #expect(range == (byte, end))
            }
            byte = end
        }
        #expect(SelectionMath.unitRange(in: text, at: byte, unit: .word) == (byte - 1, byte))
    }

    @Test func visualWordArrowUsesTheDictionaryInAMixedDirectionLine() {
        let text = "中华人民共和国 אב"
        let layout = TextSystem().shape(text: text, style: TextStyle(size: 18), maxWidth: nil,
                                        pixelScale: 1, emitGlyphs: false)
        let to = CaretVisualStepper.visualIn(layout, at: 0, side: .downstream, arrow: .wordRight, hidden: false)
        #expect(to?.0 == .at("中华".utf8.count, .upstream))
    }
    #endif

    @Test("SelectionStyle presets, builders, pick(active:) and El modifiers")
    func selectionStyleAndElModifiers() {
        let chrom = SelectionStyle.chromium
        let activePick = chrom.pick(active: true)
        let inactivePick = chrom.pick(active: false)
        #expect(activePick.ink == .white)
        #expect(inactivePick.ink != nil)
        #expect(activePick.highlight != inactivePick.highlight)

        let onlyInk = SelectionStyle(highlight: .srgb(0.2, 0.4, 0.9, 0.3)).ink(.black)
        #expect(onlyInk.pick(active: true).ink == .black)
        #expect(onlyInk.inactiveInk == nil)
        #expect(onlyInk.pick(active: false).ink == nil)

        let custom = SelectionStyle(highlight: .srgb(1, 0, 0, 0.3))
            .ink(.black)
            .inactive(.srgb(0.5, 0.5, 0.5, 0.3), ink: .white)
        #expect(custom.pick(active: true).ink == .black)
        #expect(custom.pick(active: false).ink == .white)

        var seenChange: SelectionChange? = nil
        var tx = Tx()
        let root: El<Int> = col()
            .selectionGroup()
            .selectionStyle(chrom)
            .onSelectionChange { _, change, t in
                seenChange = change
                t.copyText(change.selection?.text ?? "")
            }
            .selectionCopy { sel in "quote: \(sel.text)" }
            .child(text("hello").selectable())
            .child(el().keepsTextSelection())

        #expect(root.isSelectionGroup)
        #expect(root.resolvedSelectionStyle == chrom)
        #expect(root.selectionColor == chrom.active)
        #expect(root.children[0].isSelectable)
        #expect(root.children[1].preservesTextSelection)
        #expect(root.hasSelectionChangeHandler)
        #expect(root.hasSelectionCopyHandler)

        let sampleSel = TextSelection(
            texts: [
                SelectedText(
                    path: "root/0",
                    key: "t0",
                    range: 0..<5,
                    len: 5,
                    whole: true,
                    text: "hello",
                    content: "hello"
                ),
            ],
            text: "hello",
            backward: false
        )
        #expect(root.invokeSelectionCopy(sampleSel) == "quote: hello")
        var state = 0
        let change = SelectionChange(selection: sampleSel, was: false, isDragging: false)
        #expect(change.started)
        #expect(!change.cleared)
        root.invokeSelectionChange(state: &state, change: change, tx: &tx)
        #expect(seenChange == change)
        #expect(tx.clipboardWrite?.text == "hello")
    }

    @Test("SelectAllResolver matches all 6 upstream select_all_tests.rs rules")
    func selectAllTestsParity() {
        let rA0 = MotionRect.fromXYWH(10, 10, 200, 20)
        let rA1 = MotionRect.fromXYWH(10, 34, 200, 20)
        let rB0 = MotionRect.fromXYWH(10, 70, 200, 20)
        let rB1 = MotionRect.fromXYWH(10, 94, 200, 20)

        func makeTree(twoGroups: Bool, focusedInput: Bool = false) -> [SelectableNodeSnapshot] {
            var nodes: [SelectableNodeSnapshot] = [
                SelectableNodeSnapshot(path: "@root", key: "root"),
                SelectableNodeSnapshot(path: "@root/@one", key: "one", parentPath: "@root", isSelectionGroup: true),
                SelectableNodeSnapshot(path: "@root/@one/@a0", key: "a0", parentPath: "@root/@one", isSelectable: true, text: "alpha one", rect: rA0),
                SelectableNodeSnapshot(path: "@root/@one/@a1", key: "a1", parentPath: "@root/@one", isSelectable: true, text: "alpha two", rect: rA1),
            ]
            if twoGroups {
                nodes.append(SelectableNodeSnapshot(path: "@root/@two", key: "two", parentPath: "@root", isSelectionGroup: true))
                nodes.append(SelectableNodeSnapshot(path: "@root/@two/@b0", key: "b0", parentPath: "@root/@two", isSelectable: true, text: "beta one", rect: rB0))
                nodes.append(SelectableNodeSnapshot(path: "@root/@two/@b1", key: "b1", parentPath: "@root/@two", isSelectable: true, text: "beta two", rect: rB1))
            }
            nodes.append(SelectableNodeSnapshot(path: "@root/@field", key: "field", parentPath: "@root", isFocusedTextInput: focusedInput))
            return nodes
        }

        // 1. the_only_group_is_selected
        var pick1 = SelectAllPick()
        #expect(
            SelectAllResolver.resolve(nodes: makeTree(twoGroups: false), pick: &pick1)
                == .selectGroup(groupPath: "@root/@one", nodePaths: ["@root/@one/@a0", "@root/@one/@a1"], joinedText: "alpha one\nalpha two")
        )

        // 2. the_last_clicked_group_is_selected (even after clicking blank)
        var pick2 = SelectAllPick()
        pick2.noteClick(groupPath: "@root/@two")
        pick2.noteClick(groupPath: nil)
        #expect(
            SelectAllResolver.resolve(nodes: makeTree(twoGroups: true), pick: &pick2)
                == .selectGroup(groupPath: "@root/@two", nodePaths: ["@root/@two/@b0", "@root/@two/@b1"], joinedText: "beta one\nbeta two")
        )

        // 3. two_groups_and_no_click_select_nothing
        var pick3 = SelectAllPick()
        #expect(SelectAllResolver.resolve(nodes: makeTree(twoGroups: true), pick: &pick3) == .none)

        // 4. a_group_that_unmounted_falls_back_to_the_only_one
        #expect(
            SelectAllResolver.resolve(nodes: makeTree(twoGroups: false), pick: &pick2)
                == .selectGroup(groupPath: "@root/@one", nodePaths: ["@root/@one/@a0", "@root/@one/@a1"], joinedText: "alpha one\nalpha two")
        )

        // 5. a_focused_field_keeps_its_own_select_all
        var pick5 = SelectAllPick()
        #expect(SelectAllResolver.resolve(nodes: makeTree(twoGroups: false, focusedInput: true), pick: &pick5) == .handledByFocusedInput)

        // 6. an_app_that_handles_the_key_keeps_it
        var pick6 = SelectAllPick()
        #expect(SelectAllResolver.resolve(nodes: makeTree(twoGroups: false), pick: &pick6, appHandledCmdA: true) == .handledByApp)
    }

    @Test("CopyJoin separates horizontal table cells with tabs and rows with newlines")
    func copyJoinTabAndNewline() {
        let cell0 = MotionRect.fromXYWH(0, 0, 80, 20)
        let cell1 = MotionRect.fromXYWH(84, 0, 80, 20)
        let nextRow = MotionRect.fromXYWH(0, 28, 160, 20)
        let joined = CopyJoin.join([
            (cell0, "colA"),
            (cell1, "colB"),
            (nextRow, "row2"),
        ])
        #expect(joined == "colA\tcolB\nrow2")
    }

    @Test("SelectionCoordinator Tx.selectText, drag phase, word unit, and onSelectionChange")
    func selectionCoordinatorAndApiParity() {
        var tx = Tx()
        tx.selectText("lone", range: 5..<9)
        #expect(tx.pendingSelectTextRequest?.key == "lone")
        #expect(tx.pendingSelectTextRequest?.range == 5..<9)

        let nodes = [
            SelectableNodeSnapshot(path: "@root", key: "root"),
            SelectableNodeSnapshot(
                path: "@root/@lone",
                key: "lone",
                parentPath: "@root",
                isSelectable: true,
                text: "lone text here",
                rect: MotionRect.fromXYWH(10, 10, 200, 20)
            ),
        ]

        let coord = SelectionCoordinator()
        let selected = coord.selectText(key: "lone", range: 5..<9, in: nodes)
        #expect(selected?.text == "text")
        #expect(selected?.texts.first?.mark() == SelectionMark(path: "@root/@lone", range: 5..<9, text: "text"))

        tx.setCurrentTextSelection(selected)
        #expect(tx.textSelection()?.text == "text")

        // onSelectionChange watcher tracks started -> cleared transitions
        let watchers: [(path: String, el: El<Int>)] = [
            ("@root", col().key("root").onSelectionChange { _, _, _ in }),
        ]
        let changes1 = coord.collectSelectionChanges(elements: watchers, nodes: nodes)
        #expect(changes1.count == 1)
        #expect(changes1[0].change.started)
        #expect(changes1[0].change.selection?.text == "text")

        // No duplicate event when unchanged
        #expect(coord.collectSelectionChanges(elements: watchers, nodes: nodes).isEmpty)

        // Word-unit double-click drag keeps origin whole forward & backward
        let content = "alpha beta gamma"
        let origin = SelectionMath.unitRange(in: content, at: 7, unit: .word)
        #expect(origin == (6, 10))
        #expect(SelectionMath.extendSelection(origin: origin, at: (0, 2)) == (10, 0))
        #expect(SelectionMath.extendSelection(origin: origin, at: (13, 13)) == (6, 13))

        // Keyed path stability & kept streaming check
        #expect(SelectionMath.sameKeyedPath("#0/@msg-4/0", "#1/@msg-4/0"))
        #expect(!SelectionMath.sameKeyedPath("#0/@msg-4/0", "#0/@msg-5/0"))
        #expect(SelectionMath.kept(then: "alpha beta", now: "alpha beta gamma", upto: 5))
        #expect(!SelectionMath.kept(then: "alpha beta", now: "axpha beta", upto: 5))
        #expect(!SelectionMath.kept(then: "é", now: "e\u{0301} added", upto: 0))
        #expect(!SelectionMath.kept(then: "é", now: "è", upto: 1))
        #expect(SelectionMath.kept(then: "e\u{0301}", now: "e\u{0300}", upto: 1))

        // Mid-UTF-8 clamping snaps to floorCharBoundary (never splits multi-byte codepoints into U+FFFD)
        let utf8Nodes = [
            SelectableNodeSnapshot(
                path: "@root/@cafe",
                key: "cafe",
                parentPath: "@root",
                isSelectable: true,
                text: "café ok",
                rect: MotionRect.fromXYWH(0, 0, 120, 20)
            ),
        ]
        let utf8Coord = SelectionCoordinator()
        let utf8Sel = utf8Coord.selectText(key: "cafe", range: 0..<4, in: utf8Nodes)
        #expect(utf8Sel?.text == "caf")
        #expect(utf8Sel?.texts.first?.range == 0..<3)

        // Paragraph unit includes trailing newline; word unit steps back off trailing newline
        #expect(SelectionMath.unitRange(in: "alpha\nbeta\n", at: 2, unit: .paragraph) == (0, 6))
        #expect(SelectionMath.unitRange(in: "alpha\n", at: 6, unit: .word) == (0, 5))

        // Punctuation and whitespace stay distinct (not merged)
        #expect(SelectionMath.unitRange(in: "foo,  bar", at: 3, unit: .word) == (3, 4))
        #expect(SelectionMath.unitRange(in: "foo,  bar", at: 4, unit: .word) == (4, 6))

        // Partial-overlap unit extension keeps origin whole
        #expect(SelectionMath.extendSelection(origin: (6, 10), at: (3, 8)) == (10, 3))
        #expect(SelectionMath.extendSelection(origin: (6, 10), at: (8, 13)) == (6, 13))

        // Tx.selectAllText / SelectionCoordinator.selectAllText on group, container, and lone text
        var txAll = Tx()
        txAll.selectAllText("r")
        #expect(txAll.pendingSelectAllTextKey == "r")
        let allTree = [
            SelectableNodeSnapshot(path: "@root", key: "root"),
            SelectableNodeSnapshot(path: "@root/@g", key: "g", parentPath: "@root", isSelectionGroup: true),
            SelectableNodeSnapshot(path: "@root/@g/@r", key: "r", parentPath: "@root/@g"),
            SelectableNodeSnapshot(path: "@root/@g/@r/@a", key: "a", parentPath: "@root/@g/@r", isSelectable: true, text: "first", rect: MotionRect.fromXYWH(0, 0, 100, 20)),
            SelectableNodeSnapshot(path: "@root/@g/@r/@b", key: "b", parentPath: "@root/@g/@r", isSelectable: true, text: "second", rect: MotionRect.fromXYWH(0, 24, 100, 20)),
            SelectableNodeSnapshot(path: "@root/@g/@outside", key: "outside", parentPath: "@root/@g", isSelectable: true, text: "other", rect: MotionRect.fromXYWH(0, 50, 100, 20)),
        ]
        #expect(utf8Coord.selectAllText(key: "r", in: allTree)?.text == "first\nsecond")
        #expect(utf8Coord.selectAllText(key: "g", in: allTree)?.text == "first\nsecond\nother")
        #expect(utf8Coord.selectAllText(key: "a", in: allTree)?.text == "first")
    }
}
