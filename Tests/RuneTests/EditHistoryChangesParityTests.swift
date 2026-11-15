import Foundation
import Testing
@testable import Rune

/// Undo as changes and history v2 (`crates/rune/src/edit/history.rs`, `edit/tests.rs`, upstream #990).
@Suite("Edit history as changes (#990)")
struct EditHistoryChangesParityTests {
    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // `edit/tests.rs::history_is_bounded_shared_and_cleared_after_send` (changed in #990: the newest
    // step stays however large). The `Arc::ptr_eq` share check has no Swift analogue (the stacks are
    // copy-on-write values) and Swift's `TextEdit` has no `focused` flag; the rest is asserted as is.
    @Test("history_is_bounded_shared_and_cleared_after_send")
    func historyIsBoundedSharedAndClearedAfterSend() {
        var e = TextEdit("", multiline: true)
        for _ in 0..<(TextEdit.maxHistorySteps + 12) { e.paste("é") }
        let rendered = e
        #expect(e.historyLen().undo == TextEdit.maxHistorySteps)
        for _ in 0..<(TextEdit.maxHistorySteps + 1) { e.undo() }
        #expect(e.text == String(repeating: "é", count: 12))
        #expect(rendered.text == String(repeating: "é", count: TextEdit.maxHistorySteps + 12))
        e.paste(String(repeating: "a", count: TextEdit.maxHistoryBytes))
        // Changed with undo as changes: the newest step stays however large, so a paste of a whole
        // file can always be undone (older steps go to keep the history in its bytes).
        #expect(e.historyLen().undo == 1, "one oversized edit keeps its own step")
        e.undo()
        #expect(e.text.utf8.count == 24, "undoing it gives back the twelve characters before it")
        e.redo()
        #expect(e.text.utf8.count == 24 + TextEdit.maxHistoryBytes)
        e.clear()
        e.undo()
        #expect(e.text.isEmpty)
        e.paste("draft")
        e.setTextStorageRaw("external")
        e.setSelectionRaw(anchor: 8, cursor: 8)
        e.undo()
        #expect(e.text == "external", "external model replacement cannot restore stale history")
    }

    // `edit/tests.rs::history_groups_typing_and_restores_unicode_selection`.
    @Test("history_groups_typing_and_restores_unicode_selection")
    func historyGroupsTypingAndRestoresUnicodeSelection() {
        var e = TextEdit("", multiline: true)
        for s in ["h", "é", "🙂"] { _ = e.handleKey(KeyEvent(key: .text(s))) }
        e.undo()
        #expect(e.text == "" && e.anchor == 0 && e.cursor == 0)
        e.redo()
        #expect(e.text == "hé🙂" && e.anchor == 7 && e.cursor == 7)
        _ = e.handleKey(KeyEvent(key: .arrowLeft))
        _ = e.handleKey(KeyEvent(key: .arrowLeft, mods: Mods(shift: true)))
        #expect(e.anchor == 3 && e.cursor == 1)
        e.paste("界\r\n日")
        #expect(e.text == "h界\n日🙂")
        e.undo()
        #expect(e.text == "hé🙂" && e.anchor == 3 && e.cursor == 1)
        e.redo()
        #expect(e.text == "h界\n日🙂" && e.anchor == 8 && e.cursor == 8)
        e.undo()
        _ = e.handleKey(KeyEvent(key: .text("a")))
        e.redo()
        #expect(e.text == "ha🙂", "new edit discards the redo branch")
        e.undo()
        #expect(e.text == "hé🙂" && e.anchor == 3 && e.cursor == 1)
    }

    @Test("a step stores what it changed: typing joins into one change, not two documents")
    func typingJoinsIntoOneChange() throws {
        var e = TextEdit("hello world", multiline: true)
        e.setCursor(utf8Offset: 5)
        for s in [",", " ", "x"] { _ = e.handleKey(KeyEvent(key: .text(s))) }
        #expect(e.text == "hello, x world")
        #expect(e.historyLen().undo == 1)
        let v = try json(try #require(e.historyJson(maxSteps: 8, maxBytes: 1 << 20)))
        #expect(v["v"] as? Int == 2)
        #expect(v["d"] as? String == "hello, x world")
        let undo = try #require(v["undo"] as? [[String: Any]])
        #expect(undo.count == 1)
        let step = undo[0]
        // The joined step spans the three keystrokes' diffs: the second keystroke's space diffs
        // after the first's (the shared prefix runs as far as it can), so the step replaces the
        // space before "world" with ", x " (`Change::join`), and applying it gives the text after.
        #expect(step["at"] as? Int == 5)
        #expect(step["r"] as? String == " ")
        #expect(step["i"] as? String == ", x ")
        #expect("hello" + (step["i"] as? String ?? "") + "world" == "hello, x world")
        #expect(step["bl"] as? Int == 11)
        #expect(step["al"] as? Int == 14)
        let before = try #require(step["b"] as? [String: Any])
        let after = try #require(step["a"] as? [String: Any])
        #expect(before["a"] as? Int == 5 && before["f"] as? Int == 5)
        #expect(after["a"] as? Int == 8 && after["f"] as? Int == 8)
        #expect(before["t"] == nil, "version 2 stores no document per step")
        e.undo()
        #expect(e.text == "hello world" && e.cursor == 5)
    }

    @Test("the diff takes a character boundary on both sides")
    func diffKeepsCharacterBoundaries() {
        // "é" (C3 A9) to "è" (C3 A8) share a lead byte: the change is the whole character.
        #expect(HistoryText.diff("aéb", "aèb") == (1, 2, 2))
        #expect(HistoryText.diff("abc", "abc") == (3, 0, 0))
        #expect(HistoryText.diff("", "xyz") == (0, 0, 3))
        #expect(HistoryText.diff("aaaa", "aa") == (2, 2, 0))
        // Longer than a 4 KiB block on each side.
        let long = String(repeating: "q", count: 10_000)
        #expect(HistoryText.diff(long + "1" + long, long + "22" + long) == (10_000, 1, 2))
    }

    @Test("history_json keeps the newest undo step however large, and older steps within the bytes")
    func newestStepAlwaysStored() throws {
        var e = TextEdit("", multiline: true)
        e.paste("one")
        e.breakHistoryGroup()
        e.paste(String(repeating: "z", count: 4096))
        let v = try json(try #require(e.historyJson(maxSteps: 16, maxBytes: 64)))
        let undo = try #require(v["undo"] as? [[String: Any]])
        #expect(undo.count == 1, "the older step doesn't fit 64 bytes; the newest is kept anyway")
        #expect((undo[0]["i"] as? String)?.utf8.count == 4096)

        var restored = TextEdit(e.text, multiline: true)
        restored.clearHistory()
        let ok1 = restored.restoreHistoryJson(try #require(e.historyJson(maxSteps: 16, maxBytes: 1 << 20)))
        #expect(ok1)
        #expect(restored.historyLen().undo == 2)
        restored.undo()
        #expect(restored.text == "one")
        restored.undo()
        #expect(restored.text.isEmpty)
        restored.redo()
        restored.redo()
        #expect(restored.text == e.text)
    }

    @Test("restore_history_json reads version 1 and checks the chain of version 2")
    func readsV1AndChecksChain() throws {
        let v1 = #"{"v":1,"undo":[{"b":{"t":"","a":0,"f":0,"m":[],"k":["p"],"s":[]},"a":{"t":"hi","a":2,"f":2,"m":[],"k":["p"],"s":[]}}],"redo":[]}"#
        var e = TextEdit("hi", multiline: true)
        let ok2 = e.restoreHistoryJson(v1)
        #expect(ok2)
        #expect(e.historyLen() == (1, 0))
        e.undo()
        #expect(e.text.isEmpty)
        e.redo()
        #expect(e.text == "hi" && e.cursor == 2)

        // A v1 history stored a few keystrokes early gets one more step to this document.
        var later = TextEdit("hi!", multiline: true)
        let ok3 = later.restoreHistoryJson(v1)
        #expect(ok3)
        #expect(later.historyLen() == (2, 0))
        later.undo()
        #expect(later.text == "hi")
        later.undo()
        #expect(later.text.isEmpty)

        // Version 2: a step that doesn't lead back from the document is refused.
        let good = #"{"v":2,"d":"hi","undo":[{"at":0,"r":"","i":"hi","bl":0,"al":2,"b":{"a":0,"f":0,"m":[],"k":["p"],"s":[]},"a":{"a":2,"f":2,"m":[],"k":["p"],"s":[]}}],"redo":[]}"#
        var g = TextEdit("hi", multiline: true)
        let ok4 = g.restoreHistoryJson(good)
        #expect(ok4)
        g.undo()
        #expect(g.text.isEmpty)
        let wrongText = good.replacingOccurrences(of: #""i":"hi""#, with: #""i":"ho""#)
        var w = TextEdit("hi", multiline: true)
        let ok5 = w.restoreHistoryJson(wrongText)
        #expect(!ok5)
        #expect(w.historyLen() == (0, 0))
        // An offset inside a character of the document it's in is refused (`meta_holds`).
        let badOffset = #"{"v":2,"d":"é","undo":[{"at":0,"r":"","i":"é","bl":0,"al":2,"b":{"a":0,"f":0,"m":[],"k":["p"],"s":[]},"a":{"a":1,"f":1,"m":[],"k":["p"],"s":[]}}],"redo":[]}"#
        var b = TextEdit("é", multiline: true)
        let ok6 = b.restoreHistoryJson(badOffset)
        #expect(!ok6)
        // No document: not version 2.
        var n = TextEdit("hi", multiline: true)
        let ok7 = n.restoreHistoryJson(#"{"v":2,"undo":[],"redo":[]}"#)
        #expect(!ok7)
        let ok8 = n.restoreHistoryJson(#"{"v":3,"d":"hi","undo":[],"redo":[]}"#)
        #expect(!ok8)
    }

    @Test("a paste with no carriage return is copied whole; CRLF still folds")
    func pasteCopiesWhole() {
        var e = TextEdit("", multiline: true)
        let pasted = "line one\nline two\ttabbed\n"
        e.paste(pasted)
        #expect(e.text == pasted)
        e.paste("a\r\nb")
        #expect(e.text == pasted + "a\nb")
        var single = TextEdit("")
        single.paste("x\ny")
        #expect(single.text == "xy")
    }

    /// `history.rs` `Meta::bytes` / `Change::bytes`: marks at `size_of::<MarkRange>()` (40), blocks
    /// at `size_of::<Block>()` (2) and soft breaks at `size_of::<u32>()` (4), plus the texts.
    @Test("a step's bytes count marks, blocks and soft breaks at upstream's sizes")
    func stepBytesMatchUpstreamSizes() {
        let meta = TextEdit.HistoryMeta(
            anchor: 0, cursor: 0, marks: [],
            richMarks: [RichMarkRange(start: 0, end: 1, mark: .bold), RichMarkRange(start: 1, end: 2, mark: .italic)],
            blocks: [.paragraph, .quote, .paragraph],
            softBreaks: [3]
        )
        #expect(meta.byteCost == 2 * 40 + 3 * 2 + 1 * 4)
        let change = TextEdit.HistoryChange(at: 0, removed: "ab", inserted: "xyz", lens: (2, 3), before: meta, after: meta)
        #expect(change.byteCost == 2 + 3 + 2 * meta.byteCost)
    }

    /// `edit/tests.rs::paste_keeps_single_line_fields_on_one_line`.
    @Test("a paste keeps single-line fields on one line")
    func pasteKeepsSingleLineFieldsOnOneLine() {
        var secure = TextEdit("")
        secure.isSecure = true
        var single = TextEdit("")
        var multi = TextEdit("", multiline: true)
        secure.paste("a\tb\r\nc\u{2028}d")
        single.paste("a\tb\r\nc\u{2028}d")
        multi.paste("a\tb\r\nc\u{2028}d")
        #expect(secure.text == "abcd")
        #expect(single.text == "abcd")
        #expect(multi.text == "a\tb\nc\u{2028}d")
        _ = single.applyIme(.commit("x\ny"))
        #expect(single.text == "abcdxy")
    }
}
