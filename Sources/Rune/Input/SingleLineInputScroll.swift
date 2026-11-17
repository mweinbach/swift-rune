import Foundation

// MARK: - Single-line Horizontal Input Scroll (`runtime/commit/text_layout.rs:single_line_scroll`)

extension Runtime {
    /// Per-path horizontal scroll offset (in logical points) for focused single-line fields.
    public var inputScroll: [String: Float] {
        inputMachines.inputScroll
    }

    internal func displayCaretByteOffset(for edit: TextEdit, showingPlaceholder: Bool) -> Int {
        guard !showingPlaceholder else { return 0 }
        if edit.isSecure && !edit.isRevealed {
            if !edit.multiline {
                let prefix = edit.text.utf8.prefix(max(0, min(edit.cursor, edit.text.utf8.count)))
                let scalarCount = String(decoding: prefix, as: UTF8.self).unicodeScalars.count
                return scalarCount * "•".utf8.count
            }
            return 0
        }
        return edit.cursor.clamped(to: 0...edit.displayString.utf8.count)
    }

    internal func computeSingleLineScroll(
        path: String,
        edit: TextEdit,
        shaped: ShapedText,
        isFocused: Bool,
        showingPlaceholder: Bool,
        innerWidthPt: Float,
        pixelScale: Float
    ) -> Float {
        guard !edit.multiline else {
            inputMachines.inputScroll.removeValue(forKey: path)
            return 0
        }
        guard isFocused else {
            inputMachines.inputScroll.removeValue(forKey: path)
            return 0
        }
        let caretW: Float = 1.5
        let byteOff = displayCaretByteOffset(for: edit, showingPlaceholder: showingPlaceholder)
        let cx = textSystem.caretRect(in: shaped, utf8Offset: byteOff, affinity: edit.caretAffinity, pixelScale: pixelScale).x
        let fullW = shaped.size.x
        var scroll = inputMachines.inputScroll[path] ?? 0.0
        let visible = max(0.0, innerWidthPt)
        if cx - scroll > visible - caretW {
            scroll = cx - visible + caretW
        }
        scroll = min(scroll, cx)
        let maxScroll = max(0.0, fullW + caretW - visible)
        scroll = max(0.0, min(scroll, maxScroll))
        inputMachines.inputScroll[path] = scroll
        return scroll
    }
}
