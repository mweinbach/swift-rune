#if os(macOS) && canImport(AppKit)
import AppKit

/// A field's complete model value answers range queries even when only visible lines have
/// been shaped. AccessKit uses the same fallback for long fields (upstream #1058).
internal final class RuneAXTextField: RuneNSAccessibilityElement {
    struct Snapshot {
        let text: String
        let anchor: Int
        let focus: Int
        let layout: A11yFieldLayout?
        let viewToScreen: CGAffineTransform
        let target: String
        let select: (@Sendable (String, Range<Int>) -> Void)?

        var selectedRange: NSRange {
            ImeUTF16Bridge.nsRange(in: text, fromUTF8Range: min(anchor, focus)..<max(anchor, focus))
        }

        func byteOffset(_ units: Int) -> Int {
            let utf16 = text.utf16
            let offset = min(max(0, units), utf16.count)
            var index = utf16.index(utf16.startIndex, offsetBy: offset)
            // AccessKit moves an offset inside a surrogate pair to the next scalar.
            if index.samePosition(in: text.unicodeScalars) == nil {
                utf16.formIndex(after: &index)
            }
            return text.utf8.distance(from: text.utf8.startIndex, to: index)
        }

        func bytes(_ range: NSRange) -> Range<Int>? {
            guard range.location != NSNotFound else { return nil }
            let count = text.utf16.count
            let start = min(max(range.location, 0), count)
            let end = start + min(max(range.length, 0), count - start)
            return byteOffset(start)..<byteOffset(end)
        }

        func string(for range: NSRange) -> String? {
            guard let offsets = bytes(range) else { return nil }
            let utf8 = text.utf8
            let start = utf8.index(utf8.startIndex, offsetBy: offsets.lowerBound)
            let end = utf8.index(start, offsetBy: offsets.count)
            return String(decoding: utf8[start..<end], as: UTF8.self)
        }

        func range(ofLine line: Int) -> NSRange {
            if let layout { return layout.range(ofLine: line) }
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

        func characterRange(at index: Int) -> NSRange {
            if layout != nil, index >= 0, index < text.utf16.count {
                return (text as NSString).rangeOfComposedCharacterSequence(at: index)
            }
            let bytes = text.utf8
            let start = bytes.index(bytes.startIndex, offsetBy: byteOffset(index))
            let location = text.utf16.distance(from: text.startIndex, to: start)
            guard start < bytes.endIndex else { return NSRange(location: location, length: 0) }
            let length = text.unicodeScalars[start].utf16.count
            return NSRange(location: location, length: length)
        }
    }

    // AppKit queries a field on its AX thread while the host refreshes it on the main thread.
    // Each query holds one version of its text, layout, coordinate transform, and callbacks.
    private let lock = NSLock()
    private var state: Snapshot
    var snapshot: Snapshot { lock.withLock { state } }

    func replaceSnapshot(_ next: Snapshot) {
        lock.withLock { state = next }
    }

    init(node: AccessibilityNode, parent: AnyObject?, snapshot: Snapshot,
         onAction: (@Sendable (String, AccessibilityAction) -> Void)?,
         onSetValue: (@Sendable (String, AccessibilityActionValue) -> Void)?) {
        state = snapshot
        super.init(node: node, parent: parent, onAction: onAction, onSetValue: onSetValue)
    }

    @MainActor
    static func viewToScreen(_ view: NSView) -> CGAffineTransform {
        guard let window = view.window else { return .identity }
        func screen(_ point: NSPoint) -> NSPoint { window.convertPoint(toScreen: view.convert(point, to: nil)) }
        let origin = screen(.zero)
        let x = screen(NSPoint(x: 1, y: 0))
        let y = screen(NSPoint(x: 0, y: 1))
        return CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
                                 c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y)
    }

    /// Readers may retain the old element when its field is removed or becomes a password.
    override func invalidate() {
        replaceSnapshot(Snapshot(text: "", anchor: 0, focus: 0, layout: nil,
                                 viewToScreen: .identity, target: nodeId, select: nil))
        super.invalidate()
    }

    override func accessibilityValue() -> Any? { snapshot.text }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        let field = snapshot
        guard let layout = field.layout, let offsets = field.bytes(range) else { return .zero }
        let local = layout.frame(forBytes: offsets)
        guard !local.isEmpty else { return .zero }
        return local.applying(field.viewToScreen)
    }

    override func accessibilityNumberOfCharacters() -> Int { snapshot.text.utf16.count }

    override func accessibilitySelectedTextRange() -> NSRange { snapshot.selectedRange }

    override func accessibilitySelectedText() -> String? {
        let field = snapshot
        return field.string(for: field.selectedRange)
    }

    override func accessibilityString(for range: NSRange) -> String? { snapshot.string(for: range) }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        snapshot.string(for: range).map { NSAttributedString(string: $0) }
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        let field = snapshot
        return field.layout?.line(atByte: field.focus) ?? field.text.utf8.prefix(max(0, field.focus)).count { $0 == 10 }
    }

    override func accessibilityLine(for index: Int) -> Int {
        let field = snapshot
        let offset = field.byteOffset(index)
        return field.layout?.line(atByte: offset) ?? field.text.utf8.prefix(offset).count { $0 == 10 }
    }

    override func accessibilityRange(forLine line: Int) -> NSRange { snapshot.range(ofLine: line) }

    override func accessibilityRange(for index: Int) -> NSRange { snapshot.characterRange(at: index) }

    override func accessibilityRange(for point: NSPoint) -> NSRange {
        let field = snapshot
        let offset = field.layout?.byte(at: point.applying(field.viewToScreen.inverted())) ?? field.focus
        return field.characterRange(at: ImeUTF16Bridge.utf16Offset(in: field.text, fromUTF8Offset: offset))
    }

    override func accessibilityStyleRange(for index: Int) -> NSRange {
        NSRange(location: 0, length: snapshot.text.utf16.count)
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(NSAccessibilityElement.setAccessibilitySelectedTextRange(_:)) {
            return snapshot.select != nil
        }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        let field = snapshot
        guard let select = field.select, let offsets = field.bytes(range) else { return }
        select(field.target, offsets)
    }
}
#endif
