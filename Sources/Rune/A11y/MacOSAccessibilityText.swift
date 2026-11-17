#if os(macOS) && canImport(AppKit)
import AppKit

/// A field's complete model value answers range queries even when only visible lines have
/// been shaped. AccessKit uses the same fallback for long fields (upstream #1058).
internal final class RuneAXTextField: RuneNSAccessibilityElement {
    private var text: String
    private(set) var anchor: Int
    private(set) var focus: Int
    private var select: (@Sendable (String, Range<Int>) -> Void)?

    init(node: AccessibilityNode, parent: AnyObject?, text: String, anchor: Int, focus: Int,
         onAction: (@Sendable (String, AccessibilityAction) -> Void)?,
         onSelectText: (@Sendable (String, Range<Int>) -> Void)?,
         onSetValue: (@Sendable (String, AccessibilityActionValue) -> Void)?) {
        self.text = text
        self.anchor = anchor
        self.focus = focus
        self.select = node.actions.contains(.setValue) ? onSelectText : nil
        super.init(node: node, parent: parent, onAction: onAction, onSetValue: onSetValue)
    }

    func updateText(_ value: String, anchor: Int, focus: Int,
                    onSelectText: (@Sendable (String, Range<Int>) -> Void)?) {
        text = value
        self.anchor = anchor
        self.focus = focus
        select = onSelectText
    }

    /// Readers may retain the old element when its field is removed or becomes a password.
    func invalidate() {
        updateText("", anchor: 0, focus: 0, onSelectText: nil)
        update(node: AccessibilityNode(id: nodeId, role: .textInput), parent: nil,
               onAction: nil, onSetValue: nil)
        setAccessibilityChildren([])
        setAccessibilityElement(false)
    }

    private func byteOffset(_ units: Int) -> Int {
        let utf16 = text.utf16
        let offset = min(max(0, units), utf16.count)
        var index = utf16.index(utf16.startIndex, offsetBy: offset)
        // AccessKit moves an offset inside a surrogate pair to the next scalar.
        if index.samePosition(in: text.unicodeScalars) == nil {
            utf16.formIndex(after: &index)
        }
        return text.utf8.distance(from: text.utf8.startIndex, to: index)
    }

    private func bytes(_ range: NSRange) -> Range<Int>? {
        guard range.location != NSNotFound else { return nil }
        let count = text.utf16.count
        let start = min(max(range.location, 0), count)
        let end = start + min(max(range.length, 0), count - start)
        return byteOffset(start)..<byteOffset(end)
    }

    override func accessibilityValue() -> Any? { text }

    override func accessibilityFrame(for range: NSRange) -> NSRect { .zero }

    override func accessibilityNumberOfCharacters() -> Int { text.utf16.count }

    override func accessibilitySelectedTextRange() -> NSRange {
        ImeUTF16Bridge.nsRange(in: text, fromUTF8Range: min(anchor, focus)..<max(anchor, focus))
    }

    override func accessibilitySelectedText() -> String? {
        accessibilityString(for: accessibilitySelectedTextRange())
    }

    override func accessibilityString(for range: NSRange) -> String? {
        guard let offsets = bytes(range) else { return nil }
        let utf8 = text.utf8
        let start = utf8.index(utf8.startIndex, offsetBy: offsets.lowerBound)
        let end = utf8.index(start, offsetBy: offsets.count)
        return String(decoding: utf8[start..<end], as: UTF8.self)
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0) }
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        text.utf8.prefix(max(0, focus)).count { $0 == 10 }
    }

    override func accessibilityLine(for index: Int) -> Int {
        text.utf8.prefix(byteOffset(index)).count { $0 == 10 }
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        guard line >= 0 else { return NSRange(location: 0, length: 0) }
        var current = 0
        var start = 0
        var end = 0
        for unit in text.utf16 {
            end += 1
            if unit == 10 {
                if current == line { return NSRange(location: start, length: end - start) }
                current += 1
                start = end
            }
        }
        return current == line ? NSRange(location: start, length: end - start) : NSRange(location: 0, length: 0)
    }

    override func accessibilityRange(for index: Int) -> NSRange {
        let bytes = text.utf8
        let start = bytes.index(bytes.startIndex, offsetBy: byteOffset(index))
        let location = text.utf16.distance(from: text.startIndex, to: start)
        guard start < bytes.endIndex else { return NSRange(location: location, length: 0) }
        let length = text.unicodeScalars[start].utf16.count
        return NSRange(location: location, length: length)
    }

    override func accessibilityRange(for point: NSPoint) -> NSRange {
        accessibilityRange(for: ImeUTF16Bridge.utf16Offset(in: text, fromUTF8Offset: focus))
    }

    override func accessibilityStyleRange(for index: Int) -> NSRange {
        NSRange(location: 0, length: text.utf16.count)
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(NSAccessibilityElement.setAccessibilitySelectedTextRange(_:)) {
            return select != nil
        }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        guard let select, let offsets = bytes(range) else { return }
        select(nodeId, offsets)
    }
}
#endif
