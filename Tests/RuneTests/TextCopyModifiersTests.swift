import Testing
import Foundation
@testable import Rune
import RuneMotion

@Suite("El Text Copy Modifiers: uncopied, copyBreaks, copyPrefix (#511)")
struct TextCopyModifiersTests {

    @Test("El modifiers ignore non-text elements, keep uncopied sorted, and strip ranges")
    func elModifierStorageAndCopySlice() {
        let box: El<Int> = el()
            .uncopied(0..<2)
            .copyBreaks(2, 3)
            .copyPrefix("- ")
        #expect(box.uncopiedRanges.isEmpty)
        #expect(box.copyBreaksPair == (1, 1))
        #expect(box.copyPrefixString == nil)

        let t: El<Int> = text("hello world")
            .uncopied(5..<5)
            .uncopied(6..<8)
            .uncopied(0..<2)
            .copyBreaks(0, 2)
            .copyPrefix("> ")
        #expect(t.uncopiedRanges == [0..<2, 6..<8])
        #expect(t.copyBreaksPair == (0, 2))
        #expect(t.copyPrefixString == "> ")

        #expect(CopyJoin.copySlice(in: "hello world", range: 0..<11, uncopied: t.uncopiedRanges) == "llo rld")
        #expect(CopyJoin.copySlice(in: "hello world", range: 0..<2, uncopied: [0..<2]) == "")
        #expect(CopyJoin.copySlice(in: "a•b", range: 0..<5, uncopied: [1..<4]) == "ab")
    }

    @Test("copy_leaves_the_breaks_and_prefixes_texts_ask_for (selection_copy_breaks.rs parity)")
    func copyLeavesBreaksAndPrefixesEndToEnd() throws {
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(400, 260),
            view: { _, _ -> El<Int> in
                col().w(400).h(260).p(10).gap(4).selectionGroup()
                    .child(text("Title").key("title").w(300).h(22).copyBreaks(1, 2).selectable())
                    .child(text("one").key("one").w(300).h(22).copyPrefix("- ").selectable())
                    .child(text("two").key("two").w(300).h(22).copyPrefix("- ").selectable())
                    .child(text("After").key("after").w(300).h(22).selectable())
            }
        )
        _ = rt.frame(at: 0.0)
        guard let title = rt.elements().first(where: { $0.key == "title" }),
              let after = rt.elements().first(where: { $0.key == "after" }) else {
            Issue.record("Missing elements")
            return
        }

        let start = Vec2(title.rect[0] + 1, title.rect[1] + title.rect[3] * 0.5)
        let end = Vec2(after.rect[0] + after.rect[2] - 2, after.rect[1] + after.rect[3] * 0.5)
        rt.pointerDown(at: start, button: .primary, mods: .none, at: 0.1)
        rt.pointerMove(to: end, mods: .none, at: 0.12)
        rt.pointerUp(at: end, button: .primary, mods: .none, at: 0.14)
        _ = rt.frame(at: 0.15)

        let expected = "Title\n\n- one\n- two\nAfter"
        #expect(rt.selectedText() == expected)
        var controlAndSuper = RuneTestKey.primaryMods()
        controlAndSuper.ctrl = true
        controlAndSuper.logo = true
        #expect(!rt.keyDown(KeyEvent(key: .command("c"), mods: controlAndSuper), at: 0.16))
        #expect(rt.clipboard.text != expected)
        let parsed = try Chord.parse("mod+c")
        #expect(rt.keyDown(KeyEvent(key: parsed.key, mods: parsed.mods), at: 0.18))
        let handledCopy = rt.keyDown(KeyEvent(key: .command("c"), mods: RuneTestKey.primaryMods()), at: 0.2)
        #expect(handledCopy)
        #expect(rt.clipboard.text == expected)
    }

    @Test("a_text_taken_from_inside_or_alone_goes_without_its_prefix (selection_copy_breaks.rs parity)")
    func textTakenFromInsideOrAloneOmitsPrefix() {
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(400, 200),
            view: { _, _ -> El<Int> in
                col().w(400).h(200).p(10).gap(4).selectionGroup()
                    .child(text("one").key("one").w(300).h(22).copyPrefix("- ").selectable())
                    .child(text("two").key("two").w(300).h(22).copyPrefix("- ").selectable())
            }
        )
        _ = rt.frame(at: 0.0)
        guard let one = rt.elements().first(where: { $0.key == "one" }),
              let two = rt.elements().first(where: { $0.key == "two" }) else {
            Issue.record("Missing list items")
            return
        }

        // Single text copied alone omits its prefix.
        rt.update { _, tx in tx.selectAllText("one") }
        _ = rt.frame(at: 0.05)
        #expect(rt.selectedText() == "one")
        #expect(rt.keyDown(KeyEvent(key: .command("c"), mods: RuneTestKey.primaryMods()), at: 0.06))
        #expect(rt.clipboard.text == "one")

        // Dragging from inside "one" across into "two" omits first item's prefix, keeps second's.
        let startInside = Vec2(one.rect[0] + 12, one.rect[1] + one.rect[3] * 0.5)
        let endTwo = Vec2(two.rect[0] + two.rect[2] - 2, two.rect[1] + two.rect[3] * 0.5)
        rt.pointerDown(at: startInside, button: .primary, mods: .none, at: 1.0)
        rt.pointerMove(to: endTwo, mods: .none, at: 1.05)
        rt.pointerUp(at: endTwo, button: .primary, mods: .none, at: 1.08)
        _ = rt.frame(at: 1.1)

        let selText = rt.selectedText() ?? ""
        #expect(!selText.hasPrefix("- "))
        #expect(selText.hasSuffix("\n- two"))
    }

    @Test("uncopied stops double-click word bounds, preserves whole, and counts leading-uncopied as fromStart")
    func uncopiedWordBoundsWholeAndCopyPrefix() {
        // Word boundaries trim uncopied spans at ends, and fall back to original range when all uncopied
        #expect(SelectionMath.unitRange(in: "abwordcd", at: 3, unit: .word, uncopied: [0..<2, 6..<8]) == (2, 6))
        #expect(SelectionMath.trimUncopied([0..<4], range: (0, 4)) == (0, 4))
        #expect(SelectionMath.trimUncopied([0..<8], range: (0, 5)) == (0, 5))
        #expect(SelectionMath.unitRange(in: "word", at: 1, unit: .word, uncopied: [0..<4]) == (0, 4))

        // End-to-end Runtime double-click + selectionCopy whole flag
        var capturedWhole: Bool? = nil
        var capturedPiece: String? = nil
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(360, 140),
            view: { _, _ -> El<Int> in
                col().w(360).h(140).p(10)
                    .selectionCopy { sel in
                        capturedWhole = sel.texts.first?.whole
                        capturedPiece = sel.texts.first?.text
                        return sel.text
                    }
                    .child(text("  word").key("w").w(260).h(24).uncopied(0..<2).selectable())
            }
        )
        _ = rt.frame(at: 0.0)
        guard let w = rt.elements().first(where: { $0.key == "w" }) else {
            Issue.record("Missing w")
            return
        }
        let clickPt = Vec2(w.rect[0] + 24, w.rect[1] + w.rect[3] * 0.5)
        rt.pointerDown(at: clickPt, button: .primary, mods: .none, at: 0.5)
        rt.pointerUp(at: clickPt, button: .primary, mods: .none, at: 0.52)
        rt.pointerDown(at: clickPt, button: .primary, mods: .none, at: 0.6)
        rt.pointerUp(at: clickPt, button: .primary, mods: .none, at: 0.62)
        _ = rt.frame(at: 0.63)

        #expect(rt.selectedText() == "word")
        #expect(rt.keyDown(KeyEvent(key: .command("c"), mods: RuneTestKey.primaryMods()), at: 0.65))
        #expect(capturedWhole == true)
        #expect(capturedPiece == "word")

        // Selection starting right after leading uncopied counts as fromStart for copyPrefix
        let nodes = [
            SelectableNodeSnapshot(
                path: "@root/@a",
                isSelectable: true,
                text: "\talpha",
                rect: .fromXYWH(0, 0, 200, 20),
                uncopied: [0..<1],
                copyBreakBefore: 1,
                copyBreakAfter: 1,
                copyPrefix: "- "
            ),
            SelectableNodeSnapshot(
                path: "@root/@b",
                isSelectable: true,
                text: "beta",
                rect: .fromXYWH(0, 24, 200, 20),
                copyBreakBefore: 1,
                copyBreakAfter: 1,
                copyPrefix: "- "
            ),
        ]
        let coord = SelectionCoordinator()
        let built = coord.buildSelection(ranges: [(nodes[0], 1..<6), (nodes[1], 0..<4)])
        #expect(built?.texts[0].whole == true)
        #expect(built?.texts[0].text == "alpha")
        #expect(built?.text == "- alpha\n- beta")

        // All-uncopied node still counts as a CopyJoin piece, sets whole == true, and keeps breaks/prefixes.
        let allUncopiedNodes = [
            SelectableNodeSnapshot(
                path: "@root/@u",
                isSelectable: true,
                text: "pad",
                rect: .fromXYWH(0, 0, 200, 20),
                uncopied: [0..<3],
                copyBreakBefore: 1,
                copyBreakAfter: 2
            ),
            SelectableNodeSnapshot(
                path: "@root/@next",
                isSelectable: true,
                text: "item",
                rect: .fromXYWH(0, 24, 200, 20),
                copyBreakBefore: 1,
                copyBreakAfter: 1,
                copyPrefix: "- "
            ),
        ]
        let allUncopiedBuilt = coord.buildSelection(ranges: [(allUncopiedNodes[0], 0..<3), (allUncopiedNodes[1], 0..<4)])
        #expect(allUncopiedBuilt?.texts[0].whole == true)
        #expect(allUncopiedBuilt?.texts[0].text == "")
        #expect(allUncopiedBuilt?.text == "\n\n- item")
        var pick = SelectAllPick()
        let selectAll = SelectAllResolver.resolve(
            nodes: [SelectableNodeSnapshot(path: "@root", isSelectionGroup: true)]
                + allUncopiedNodes.map {
                    var n = $0
                    n.parentPath = "@root"
                    return n
                },
            pick: &pick
        )
        #expect(selectAll == .selectGroup(groupPath: "@root", nodePaths: ["@root/@u", "@root/@next"], joinedText: "\n\n- item"))
    }

    @Test("CopyJoin honors trailing newlines, beside tabs, and the Select All shortcut")
    func copyJoinTrailingNewlinesBesideAndSelectAll() {
        let entries: [CopyJoin.Entry] = [
            CopyJoin.Entry(
                rect: .fromXYWH(0, 0, 100, 20),
                pieceText: "head\n",
                copyBreakAfter: 2
            ),
            CopyJoin.Entry(
                rect: .fromXYWH(0, 24, 100, 20),
                pieceText: "left",
                copyBreakBefore: 1,
                copyPrefix: "* "
            ),
            CopyJoin.Entry(
                rect: .fromXYWH(110, 24, 100, 20),
                pieceText: "right",
                copyPrefix: "* "
            ),
        ]
        #expect(CopyJoin.join(entries) == "head\n\n* left\t* right")

        // Select All in a selectionGroup honors uncopied + copyBreaks + copyPrefix.
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(360, 200),
            view: { _, _ -> El<Int> in
                col().w(360).h(200).p(8).selectionGroup()
                    .child(text("H1\t").w(300).h(22).uncopied(2..<3).copyBreaks(1, 2).selectable())
                    .child(text("item").w(300).h(22).copyPrefix("- ").selectable())
            }
        )
        _ = rt.frame(at: 0.0)
        #expect(rt.keyDown(KeyEvent(key: .command("a"), mods: RuneTestKey.primaryMods()), at: 0.1))
        #expect(rt.selectedText() == "H1\n\n- item")
    }
}
