import Foundation
import RuneMotion

/// Portable UTF-16 `UITextInput` bridge backing `RuneIOSView` (and unit-testable on every platform).
///
/// Maps UTF-16 document coordinates (including active marked/preedit text) onto the focused
/// `Runtime<State>` `TextEdit` and `ImeEvent` pipeline, while never exposing secure field contents.
public enum IOSTextInputBridge {
    /// Snapshot of the focused field's display text (with preedit spliced in) in UTF-16 units.
    public struct Snapshot: Sendable, Equatable {
        /// Display string (empty for secure fields so UIKit never mirrors secrets).
        public let displayText: String
        /// Total UTF-16 code units in `displayText`.
        public let utf16Length: Int
        /// Selected range in UTF-16 code units within `displayText`.
        public let selectedUTF16: Range<Int>
        /// Active IME marked/preedit range in UTF-16 code units within `displayText`, if any.
        public let markedUTF16: Range<Int>?
        /// True when the focused field is a password / secure field.
        public let isSecure: Bool
        /// True when the focused field is multiline.
        public let isMultiline: Bool
    }

    /// Reads the current focused editor snapshot from `runtime`, or `nil` when no field is focused.
    public static func snapshot<State>(of runtime: Runtime<State>) -> Snapshot? {
        guard let fp = runtime.focusedPath,
              let idx = runtime.nodeByPath[fp],
              let lens = runtime.flatNodes[idx].el.handlers.editLens else {
            return nil
        }
        let el = runtime.flatNodes[idx].el
        let edit = lens.get(runtime.state)
        let secure = el.isSecure || edit.isSecure
        if secure {
            return Snapshot(
                displayText: "",
                utf16Length: 0,
                selectedUTF16: 0..<0,
                markedUTF16: nil,
                isSecure: true,
                isMultiline: edit.multiline
            )
        }
        if let preedit = edit.preedit, !preedit.text.isEmpty {
            let selUTF8 = edit.selectedUTF8Range
            let loIdx = edit.stringIndex(forUTF8Offset: selUTF8.lowerBound)
            let hiIdx = edit.stringIndex(forUTF8Offset: selUTF8.upperBound)
            var display = String(edit.text[..<loIdx])
            display += preedit.text
            display += String(edit.text[hiIdx...])
            let utf16Len = display.utf16.count
            let preeditStartUTF16 = ImeUTF16Bridge.utf16Offset(in: edit.text, fromUTF8Offset: selUTF8.lowerBound)
            let preeditLenUTF16 = preedit.text.utf16.count
            let markedRange = preeditStartUTF16..<(preeditStartUTF16 + preeditLenUTF16)
            let selUTF16: Range<Int>
            if let cur = preedit.cursor {
                let lo = preeditStartUTF16 + ImeUTF16Bridge.utf16Offset(in: preedit.text, fromUTF8Offset: cur.lowerBound)
                let hi = preeditStartUTF16 + ImeUTF16Bridge.utf16Offset(in: preedit.text, fromUTF8Offset: cur.upperBound)
                selUTF16 = min(lo, hi)..<max(lo, hi)
            } else {
                selUTF16 = markedRange.upperBound..<markedRange.upperBound
            }
            return Snapshot(
                displayText: display,
                utf16Length: utf16Len,
                selectedUTF16: selUTF16,
                markedUTF16: markedRange,
                isSecure: false,
                isMultiline: edit.multiline
            )
        }
        let display = edit.displayString
        let utf16Len = display.utf16.count
        let selUTF8 = edit.selectedUTF8Range
        let lo = ImeUTF16Bridge.utf16Offset(in: edit.text, fromUTF8Offset: selUTF8.lowerBound)
        let hi = ImeUTF16Bridge.utf16Offset(in: edit.text, fromUTF8Offset: selUTF8.upperBound)
        return Snapshot(
            displayText: display,
            utf16Length: utf16Len,
            selectedUTF16: min(lo, hi)..<max(lo, hi),
            markedUTF16: nil,
            isSecure: false,
            isMultiline: edit.multiline
        )
    }

    /// Reads the substring at `utf16Range` from the focused non-secure editor.
    public static func text<State>(in runtime: Runtime<State>, utf16Range: Range<Int>) -> String? {
        guard let snap = snapshot(of: runtime), !snap.isSecure else { return nil }
        let lo = max(0, min(utf16Range.lowerBound, snap.utf16Length))
        let hi = max(lo, min(utf16Range.upperBound, snap.utf16Length))
        let u16 = snap.displayText.utf16
        let start = u16.index(u16.startIndex, offsetBy: lo)
        let end = u16.index(u16.startIndex, offsetBy: hi)
        return String(snap.displayText[start..<end])
    }

    /// Updates the focused editor's selection to `utf16Range` (committed document coordinates).
    @discardableResult
    public static func setSelection<State>(
        in runtime: Runtime<State>,
        utf16Range: Range<Int>,
        at now: Double
    ) -> Bool {
        guard let fp = runtime.focusedPath,
              let idx = runtime.nodeByPath[fp],
              let lens = runtime.flatNodes[idx].el.handlers.editLens else {
            return false
        }
        let el = runtime.flatNodes[idx].el
        let edit = lens.get(runtime.state)
        guard !el.isSecure && !edit.isSecure else { return false }
        if edit.preedit != nil {
            _ = runtime.finishComposition(at: now)
        }
        let fresh = lens.get(runtime.state)
        let lo = ImeUTF16Bridge.utf8Offset(in: fresh.text, fromUTF16Offset: max(0, utf16Range.lowerBound))
        let hi = ImeUTF16Bridge.utf8Offset(in: fresh.text, fromUTF16Offset: max(utf16Range.lowerBound, utf16Range.upperBound))
        return runtime.accessibilitySelectText(fp, range: min(lo, hi)..<max(lo, hi), at: now)
    }

    /// Replaces `utf16Range` with `replacement` in the focused editor.
    @discardableResult
    public static func replace<State>(
        in runtime: Runtime<State>,
        utf16Range: Range<Int>,
        with replacement: String,
        at now: Double
    ) -> Bool {
        guard let fp = runtime.focusedPath,
              let idx = runtime.nodeByPath[fp],
              let lens = runtime.flatNodes[idx].el.handlers.editLens else {
            return false
        }
        let el = runtime.flatNodes[idx].el
        let edit = lens.get(runtime.state)
        guard !el.isSecure && !edit.isSecure else { return false }
        if edit.preedit != nil {
            _ = runtime.dispatchImeEvent(.preedit("", cursorUTF8: nil, clauses: []), at: now)
        }
        let fresh = lens.get(runtime.state)
        let lo = ImeUTF16Bridge.utf8Offset(in: fresh.text, fromUTF16Offset: max(0, utf16Range.lowerBound))
        let hi = ImeUTF16Bridge.utf8Offset(in: fresh.text, fromUTF16Offset: max(utf16Range.lowerBound, utf16Range.upperBound))
        let targetRange = min(lo, hi)..<max(lo, hi)
        if !runtime.accessibilitySelectText(fp, range: targetRange, at: now) && targetRange != fresh.selectedUTF8Range {
            return false
        }
        if replacement.isEmpty {
            if !targetRange.isEmpty {
                return runtime.keyDown(KeyEvent(key: .backspace), at: now)
            }
            return true
        }
        return runtime.dispatchImeEvent(.commit(replacement), at: now)
    }

    /// Sets active IME marked/preedit text with a UTF-16 `selectedRange` relative to `markedText`.
    @discardableResult
    public static func setMarkedText<State>(
        in runtime: Runtime<State>,
        _ markedText: String?,
        selectedUTF16Range: NSRange,
        at now: Double
    ) -> Bool {
        guard !runtime.hasSecureFocus else { return false }
        let text = markedText ?? ""
        if text.isEmpty {
            return runtime.dispatchImeEvent(.preedit("", cursorUTF8: nil, clauses: []), at: now)
        }
        let cursorUTF8: Range<Int>?
        if selectedUTF16Range.location != NSNotFound {
            let lo = ImeUTF16Bridge.utf8Offset(in: text, fromUTF16Offset: max(0, selectedUTF16Range.location))
            let hi = ImeUTF16Bridge.utf8Offset(
                in: text,
                fromUTF16Offset: max(0, selectedUTF16Range.location) + max(0, selectedUTF16Range.length)
            )
            cursorUTF8 = min(lo, hi)..<max(lo, hi)
        } else {
            let end = text.utf8.count
            cursorUTF8 = end..<end
        }
        return runtime.dispatchImeEvent(.preedit(text, cursorUTF8: cursorUTF8, clauses: []), at: now)
    }

    /// Commits any active marked/preedit text into the focused editor.
    @discardableResult
    public static func unmarkText<State>(in runtime: Runtime<State>, at now: Double) -> Bool {
        guard !runtime.hasSecureFocus else { return false }
        return runtime.finishComposition(at: now)
    }

    /// Returns the logical window-point caret rectangle at `utf16Offset` (falling back to the focused caret rect).
    public static func caretRect<State>(
        in runtime: Runtime<State>,
        atUTF16Offset offset: Int
    ) -> MotionRect {
        let viewport = MotionRect.fromXYWH(0, 0, runtime.viewport.x, runtime.viewport.y)
        if let fp = runtime.focusedPath,
           let layout = runtime.accessibilityTextLayout(target: fp, clip: viewport),
           let cells = layout.cells(unit: .utf16, pixelScale: 1),
           !cells.isEmpty {
            let target = Int32(clamping: max(0, offset))
            if let cell = cells.first(where: { target >= $0.start && target < $0.end }) {
                let x = cell.rtl ? (cell.x + cell.width) : cell.x
                return MotionRect.fromXYWH(Float(x), Float(cell.y), 2, Float(max(1, cell.height)))
            }
            if let prev = cells.last(where: { $0.end <= target }) {
                let x = prev.rtl ? prev.x : (prev.x + prev.width)
                return MotionRect.fromXYWH(Float(x), Float(prev.y), 2, Float(max(1, prev.height)))
            }
            if let first = cells.first {
                return MotionRect.fromXYWH(Float(first.x), Float(first.y), 2, Float(max(1, first.height)))
            }
        }
        return runtime.focusedCaretRect() ?? MotionRect.fromXYWH(0, 0, 2, 18)
    }

    /// Returns logical window-point selection rectangles for `utf16Range`, merged per visual line.
    public static func selectionRects<State>(
        in runtime: Runtime<State>,
        forUTF16Range range: Range<Int>
    ) -> [MotionRect] {
        guard !range.isEmpty else {
            return [caretRect(in: runtime, atUTF16Offset: range.lowerBound)]
        }
        let viewport = MotionRect.fromXYWH(0, 0, runtime.viewport.x, runtime.viewport.y)
        guard let fp = runtime.focusedPath,
              let layout = runtime.accessibilityTextLayout(target: fp, clip: viewport),
              let cells = layout.cells(unit: .utf16, pixelScale: 1) else {
            return [caretRect(in: runtime, atUTF16Offset: range.lowerBound)]
        }
        let lo = Int32(clamping: range.lowerBound)
        let hi = Int32(clamping: range.upperBound)
        var byLine: [(line: Int32, rect: MotionRect)] = []
        for cell in cells where cell.end > lo && cell.start < hi {
            guard cell.height > 0 else { continue }
            let r = MotionRect.fromXYWH(Float(cell.x), Float(cell.y), Float(max(1, cell.width)), Float(cell.height))
            if let lastIdx = byLine.indices.last, byLine[lastIdx].line == cell.line {
                let old = byLine[lastIdx].rect
                byLine[lastIdx].rect = MotionRect(
                    left: min(old.left, r.left),
                    top: min(old.top, r.top),
                    right: max(old.right, r.right),
                    bottom: max(old.bottom, r.bottom)
                )
            } else {
                byLine.append((cell.line, r))
            }
        }
        return byLine.isEmpty ? [caretRect(in: runtime, atUTF16Offset: range.lowerBound)] : byLine.map(\.rect)
    }

    /// Hit-tests `point` (in logical window points) to the closest UTF-16 offset in the focused editor.
    public static func closestUTF16Offset<State>(
        in runtime: Runtime<State>,
        to point: Vec2
    ) -> Int {
        guard let snap = snapshot(of: runtime), !snap.isSecure else { return 0 }
        let viewport = MotionRect.fromXYWH(0, 0, runtime.viewport.x, runtime.viewport.y)
        guard let fp = runtime.focusedPath,
              let layout = runtime.accessibilityTextLayout(target: fp, clip: viewport),
              let cells = layout.cells(unit: .utf16, pixelScale: 1),
              !cells.isEmpty else {
            return snap.selectedUTF16.upperBound
        }
        let px = Double(point.x)
        let py = Double(point.y)
        // Pick the closest visual line vertically, then the closest cell edge horizontally.
        var bestLine: Int32 = cells[0].line
        var bestLineDist = Double.infinity
        for cell in cells {
            let cy = cell.y + cell.height * 0.5
            let dy = py < cell.y ? (cell.y - py) : (py > cell.y + cell.height ? (py - (cell.y + cell.height)) : 0)
            let score = dy > 0 ? (dy + 10_000) : abs(py - cy)
            if score < bestLineDist {
                bestLineDist = score
                bestLine = cell.line
            }
        }
        let lineCells = cells.filter { $0.line == bestLine }
        var bestOffset = Int(lineCells[0].start)
        var bestDist = Double.infinity
        for cell in lineCells {
            let leadingX = cell.rtl ? (cell.x + cell.width) : cell.x
            let trailingX = cell.rtl ? cell.x : (cell.x + cell.width)
            let dLead = abs(px - leadingX)
            if dLead < bestDist {
                bestDist = dLead
                bestOffset = Int(cell.start)
            }
            let dTrail = abs(px - trailingX)
            if dTrail < bestDist {
                bestDist = dTrail
                bestOffset = Int(cell.end)
            }
        }
        return max(0, min(bestOffset, snap.utf16Length))
    }
}
