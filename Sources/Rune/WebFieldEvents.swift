import Foundation

extension WebAppHost {
    /// The native field reports UTF-16 offsets relative to the last window of model text it received.
    @discardableResult
    public func handleFieldSelection(
        key: String, base: Int, expected: String, anchor: Int, focus: Int, at now: Double
    ) -> Bool {
        applyFieldEvent(key: key, base: base, expected: expected, text: nil, anchor: anchor, focus: focus, at: now)
    }

    /// Applies an edited native text window through the focused editor's undo, rich text and change handlers.
    @discardableResult
    public func handleFieldEdit(
        key: String, base: Int, expected: String, text: String, anchor: Int, focus: Int, at now: Double
    ) -> Bool {
        applyFieldEvent(key: key, base: base, expected: expected, text: text, anchor: anchor, focus: focus, at: now)
    }

    /// Password fields send only committed keystrokes. Their model value never enters the browser mirror.
    @discardableResult
    public func handleSecureFieldInsert(key: String, text: String, at now: Double) -> Bool {
        defer { syncField(activate: false) }
        guard runtime.focusedPath == key, fieldMirror?.key == key, fieldMirror?.secure == true,
              let el = runtime.focusedInputElement(at: key), el.hasEditAccess,
              let lens = el.handlers.editLens, el.isSecure || lens.get(runtime.state).isSecure else { return false }
        return runtime.keyDown(KeyEvent(key: .text(text), mods: .none), at: now)
    }

    private func applyFieldEvent(
        key: String, base: Int, expected: String, text: String?, anchor: Int, focus: Int, at now: Double
    ) -> Bool {
        // The DOM's edit and selection events count as typed input even if the mirror is stale.
        InputTime.noteDispatched()
        let dispatch = runtime.noteInput(at: now)
        defer {
            runtime.endInputDispatch(dispatch)
            syncField(activate: false)
        }
        guard let mirror = fieldMirror, mirror.key == key, mirror.base == base, !mirror.secure,
              mirror.text.utf8.elementsEqual(expected.utf8), runtime.focusedPath == key,
              let el = runtime.focusedInputElement(at: key), el.hasEditAccess, !el.isSecure,
              let lens = el.handlers.editLens else { return false }

        let previous = lens.get(runtime.state)
        let proposed = text ?? expected
        guard !previous.isSecure, Self.containsWindow(expected, in: previous.text, at: base),
              let anchorByte = Self.byteOffset(in: proposed, utf16: anchor),
              let focusByte = Self.byteOffset(in: proposed, utf16: focus) else { return false }

        var edit = previous
        let replacing = text != nil && !expected.utf8.elementsEqual(proposed.utf8)
        if replacing {
            // Limit the edit to its changed scalars, keeping surrounding rich spans, pills and undo history.
            let change = Self.replacement(from: expected, to: proposed, caret: focusByte)
            edit.multiline = !el.isSingleLineInput
            edit.cancelPreedit()
            edit.setSelectionRaw(anchor: base + change.oldRange.lowerBound, cursor: base + change.oldRange.upperBound)
            edit.snapToPills()
            edit.insert(change.inserted)
        }
        // A single-line editor may filter a pasted newline, or a pill may enlarge a replacement.
        // In that case Rune's resulting caret and model value must go back to the DOM.
        let matches = Self.containsWindow(proposed, in: edit.text, at: base)
            && edit.text.utf8.count - proposed.utf8.count == previous.text.utf8.count - expected.utf8.count
        if matches {
            edit.setSelectionRaw(anchor: base + anchorByte, cursor: base + focusByte)
            edit.snapToPills()
        }
        if replacing && !edit.text.utf8.elementsEqual(previous.text.utf8) {
            runtime.deliverInputEdit(el: el, previousEdit: previous, newEdit: edit, editLens: lens, at: now)
            return matches && lens.get(runtime.state).text.utf8.elementsEqual(edit.text.utf8)
        }
        if edit.cursor != previous.cursor || edit.anchor != previous.anchor {
            lens.set(&runtime.state, edit)
            runtime.pendingCaretFollow = true
            runtime.dirtyCommit(at: now, why: CommitWhy.input)
        }
        return matches
    }

    private static func byteOffset(in text: String, utf16 offset: Int) -> Int? {
        let units = text.utf16
        guard offset >= 0, let index = units.index(units.startIndex, offsetBy: offset, limitedBy: units.endIndex),
              let scalar = index.samePosition(in: text.unicodeScalars) else { return nil }
        return text.utf8.distance(from: text.startIndex, to: scalar)
    }

    private static func containsWindow(_ window: String, in value: String, at base: Int) -> Bool {
        let bytes = value.utf8
        guard base >= 0, let start = bytes.index(bytes.startIndex, offsetBy: base, limitedBy: bytes.endIndex),
              start.samePosition(in: value.unicodeScalars) != nil else {
            return false
        }
        return bytes[start...].starts(with: window.utf8)
    }

    /// With repeated characters, the DOM caret disambiguates which otherwise identical text was inserted/deleted.
    private static func replacement(from old: String, to new: String, caret: Int) -> (oldRange: Range<Int>, inserted: String) {
        let before = old.unicodeScalars
        let after = new.unicodeScalars
        var a = before.startIndex, b = after.startIndex
        var c = before.endIndex, d = after.endIndex
        let caretIndex = new.utf8.index(new.startIndex, offsetBy: caret)
        while a < c, b < caretIndex, before[a] == after[b] {
            before.formIndex(after: &a)
            after.formIndex(after: &b)
        }
        while a < c, b < d {
            let lastOld = before.index(before: c)
            let lastNew = after.index(before: d)
            guard before[lastOld] == after[lastNew] else { break }
            c = lastOld
            d = lastNew
        }
        while a < c, b < d, before[a] == after[b] {
            before.formIndex(after: &a)
            after.formIndex(after: &b)
        }
        let start = old.utf8.distance(from: old.startIndex, to: a)
        let end = old.utf8.distance(from: old.startIndex, to: c)
        return (start..<end, String(after[b..<d]))
    }
}
