import Foundation
import RuneMotion

/// Linux PRIMARY is independent of the regular clipboard, including its secret-copy timer.
internal struct PrimarySelection {
    var pending = false
    var written: Int?
    var write: String?
    var paste: String?
}

extension Runtime {
    internal func notePrimarySelection() {
        guard clipboardRouting.primary.pending else { return }
        clipboardRouting.primary.pending = false
        let selection: String?
        if let path = focusedPath, let el = focusedInputElement(at: path), let lens = el.handlers.editLens {
            let edit = lens.get(state)
            guard !el.isSecure, !edit.isSecure else { return }
            selection = edit.selectedText
        } else {
            selection = selectedText()
        }
        guard var text = selection, !text.isEmpty else { return }
        // String.hashValue normalizes composed/decomposed text. PRIMARY preserves UTF-8 bytes.
        let hash = text.withUTF8 { bytes in
            var hasher = Hasher()
            hasher.combine(bytes: UnsafeRawBufferPointer(bytes))
            return hasher.finalize()
        }
        guard hash != clipboardRouting.primary.written else { return }
        clipboardRouting.primary.written = hash
        clipboardRouting.primary.write = text
    }

    internal func primaryPasteDown(at point: Vec2, now: Double) -> Bool {
        guard let path = primaryTargetPath(at: point), let idx = nodeByPath[path], !subtreeExiting(idx),
              hoverAllowed(idx) else { return false }
        let node = flatNodes[idx]
        guard node.el.hasEditAccess, !node.el.isSecure, let lens = node.el.handlers.editLens,
              !lens.get(state).isSecure else { return false }
        setFocus(path: path, keyboard: false, at: now)
        var edit = lens.get(state)
        let hit = textCaretHit(node: node, windowPos: point, edit: edit)
        edit.setCursor(hit, extendSelection: false)
        lens.set(&state, edit)
        clipboardRouting.primary.paste = path
        dirtyCommit(at: now, why: CommitWhy.input)
        return true
    }

    internal func queuePrimaryPaste(target: String, text: String) {
        guard !text.isEmpty else { return }
        clipboardRouting.replies.append((.paste(ClipboardContent(text), target: .some(target), primary: true), InputTime.arrival()))
    }
}
