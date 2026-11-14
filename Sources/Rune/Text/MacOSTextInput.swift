import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Input method event delivered to the focused `TextEdit` or editor (`rune::edit::Ime`).
public enum ImeEvent: Sendable, Equatable {
    /// Active marked text (not yet committed), cursor/selection UTF-8 byte range inside it, and clauses.
    case preedit(String, cursorUTF8: Range<Int>?, clauses: [ImeClause])
    /// Committed string to insert at the caret (replacing any active preedit).
    case commit(String)
    /// Reconversion selection range in document UTF-8 byte coordinates.
    case select(Range<Int>)
    /// Input method enabled for the focused text input.
    case enabled
    /// Input method disabled.
    case disabled
}

/// Pure-Swift UTF-16 <-> UTF-8, clause extraction, and reconversion helpers (`rune::platform::ime`).
public enum ImeUTF16Bridge {
    /// Converts a UTF-16 code unit offset in `string` to a scalar-aligned UTF-8 byte offset.
    public static func utf8Offset(in string: String, fromUTF16Offset utf16: Int) -> Int {
        guard utf16 > 0 else { return 0 }
        let clamped = min(utf16, string.utf16.count)
        let u16Idx = string.utf16.index(string.utf16.startIndex, offsetBy: clamped)
        if let scalarIdx = u16Idx.samePosition(in: string.unicodeScalars) {
            return string.utf8.distance(from: string.utf8.startIndex, to: scalarIdx.samePosition(in: string.utf8) ?? string.utf8.endIndex)
        }
        // If `utf16` landed inside a surrogate pair, snap back to the preceding scalar boundary.
        var count = 0
        var utf8 = 0
        for scalar in string.unicodeScalars {
            let next = count + scalar.utf16.count
            if next > clamped { break }
            count = next
            utf8 += scalar.utf8.count
        }
        return utf8
    }

    /// Converts a UTF-8 byte offset in `string` to a UTF-16 code unit offset.
    public static func utf16Offset(in string: String, fromUTF8Offset utf8: Int) -> Int {
        guard utf8 > 0 else { return 0 }
        let clamped = min(utf8, string.utf8.count)
        // Walk scalar boundaries so non-boundary offsets round down cleanly.
        var bytes = 0
        var u16 = 0
        for scalar in string.unicodeScalars {
            let next = bytes + scalar.utf8.count
            if next > clamped { break }
            bytes = next
            u16 += scalar.utf16.count
        }
        return u16
    }

    /// Converts an `NSRange` (UTF-16 units) in `string` to a UTF-8 byte range, or `nil` if `location == NSNotFound`.
    public static func utf8Range(in string: String, fromNSRange nsRange: NSRange) -> Range<Int>? {
        guard nsRange.location != NSNotFound else { return nil }
        let start = utf8Offset(in: string, fromUTF16Offset: nsRange.location)
        let end = utf8Offset(in: string, fromUTF16Offset: nsRange.location + max(0, nsRange.length))
        return min(start, end)..<max(start, end)
    }

    /// Converts a UTF-8 byte range in `string` to an `NSRange` in UTF-16 code units.
    public static func nsRange(in string: String, fromUTF8Range utf8Range: Range<Int>) -> NSRange {
        let lo = utf16Offset(in: string, fromUTF8Offset: utf8Range.lowerBound)
        let hi = utf16Offset(in: string, fromUTF8Offset: utf8Range.upperBound)
        return NSRange(location: lo, length: max(0, hi - lo))
    }

    /// Slices the paragraph around `selectionUTF8` (up to `maxContextBytes` per side) for IME reconversion.
    public static func imeTextSlice(
        text: String,
        selectionUTF8: Range<Int>,
        maxContextBytes: Int = 1024
    ) -> ImeText {
        let len = text.utf8.count
        let selStart = min(max(0, selectionUTF8.lowerBound), len)
        let selEnd = min(max(selStart, selectionUTF8.upperBound), len)

        let rawLow = max(0, selStart - maxContextBytes)
        let rawHigh = min(len, selEnd + maxContextBytes)

        // Snap bounds to scalar boundaries and stop at paragraph breaks (`\n`).
        var start = 0
        var end = len
        var offset = 0
        var foundParaEnd = false
        for scalar in text.unicodeScalars {
            let next = offset + scalar.utf8.count
            if next <= selStart {
                if scalar == "\n" || offset < rawLow {
                    start = next
                }
            }
            if !foundParaEnd && offset >= selEnd {
                if scalar == "\n" || next > rawHigh {
                    end = offset
                    foundParaEnd = true
                }
            }
            offset = next
        }
        start = min(start, selStart)
        end = max(end, selEnd)

        let sIdx = text.utf8.index(text.utf8.startIndex, offsetBy: start)
        let eIdx = text.utf8.index(text.utf8.startIndex, offsetBy: end)
        let slice = String(text[sIdx..<eIdx])
        return ImeText(
            startUTF8: start,
            text: slice,
            selectionUTF8: (selStart - start)..<(selEnd - start)
        )
    }

    /// Resolves an AppKit `replacementRange` (UTF-16 relative to `imeText.text`) into a document UTF-8 range.
    public static func resolveReplacement(_ replacementRange: NSRange, in imeText: ImeText?) -> Range<Int>? {
        guard let imeText, replacementRange.location != NSNotFound else { return nil }
        guard let rel = utf8Range(in: imeText.text, fromNSRange: replacementRange) else { return nil }
        return (imeText.startUTF8 + rel.lowerBound)..<(imeText.startUTF8 + rel.upperBound)
    }

    /// Extracts IME clauses from an `NSAttributedString` (marking `.markedClauseSegment` / thick underline).
    public static func clauses(from attributed: NSAttributedString, preedit: String) -> [ImeClause] {
        guard !preedit.isEmpty else { return [] }
        let fullLen = (attributed.string as NSString).length
        guard fullLen > 0 else { return [] }

        var result: [ImeClause] = []
        var pos = 0
        while pos < fullLen {
            var effective = NSRange(location: 0, length: 0)
            let attrs = attributed.attributes(at: pos, effectiveRange: &effective)
            let clampedStart = max(pos, effective.location)
            let clampedEnd = min(fullLen, effective.location + max(1, effective.length))
            let segRange = NSRange(location: clampedStart, length: clampedEnd - clampedStart)

            #if canImport(AppKit)
            let isThickUnderline: Bool
            if let styleRaw = attrs[.underlineStyle] as? Int {
                let style = NSUnderlineStyle(rawValue: styleRaw)
                isThickUnderline = style.contains(.thick)
            } else {
                isThickUnderline = false
            }
            let hasClause = attrs[NSAttributedString.Key(rawValue: "NSMarkedClauseSegment")] != nil ||
                attrs[.markedClauseSegment] != nil ||
                isThickUnderline
            #else
            let isThickUnderline = false
            let hasClause = attrs[NSAttributedString.Key(rawValue: "NSMarkedClauseSegment")] != nil
            #endif

            if hasClause, let utf8 = utf8Range(in: preedit, fromNSRange: segRange), !utf8.isEmpty {
                result.append(ImeClause(utf8Range: utf8, isTarget: isThickUnderline))
            }
            pos = clampedEnd
        }

        // Only return clauses when the IME actually emitted segment/target attributes.
        if result.count == 1 && !result[0].isTarget {
            return []
        }
        return result
    }
}

#if os(macOS) && canImport(AppKit)

/// Result of routing an `NSEvent` through `MacOSTextInputBridge.processKeyDown(_:in:)`.
public enum MacOSKeyInterceptResult: Sendable, Equatable {
    /// Consumed by the macOS IME / dead-key / emoji picker / dictation pipeline.
    case handledByIME
    /// Not consumed as composed text; host should dispatch via `Runtime.keyDown`.
    case forwardKeyDown
}

/// AppKit `NSTextInputClient` bridge implementing preedit, clauses, reconversion, and caret anchoring.
@MainActor
public final class MacOSTextInputBridge {
    private var imeText: ImeText?
    private var markedString: String = ""
    private var markedAttributed = NSMutableAttributedString()
    private var markedSelectionUTF16 = NSRange(location: 0, length: 0)
    private var candidateScreenRect: NSRect = .zero

    // Per-`interpretKeyEvents` dispatch state
    private var trackingKeyEvent = false
    private var didInsertDuringKeyEvent = false
    private var didMarkDuringKeyEvent = false
    private var didCommandDuringKeyEvent = false
    private var isCanceling = false

    public var onEvent: ((ImeEvent) -> Void)?

    public init(onEvent: ((ImeEvent) -> Void)? = nil) {
        self.onEvent = onEvent
    }

    public var isComposing: Bool { !markedString.isEmpty }
    public var currentMarkedText: String { markedString }
    public var isTrackingKeyEvent: Bool { trackingKeyEvent }

    /// Publishes focused field context & screen-space caret rect to AppKit IME (`rune::platform::ime::sync`).
    public func sync(
        imeText: ImeText?,
        caretScreenRect: NSRect,
        cancelExisting: Bool = false,
        in view: NSView? = nil
    ) {
        self.imeText = imeText
        self.candidateScreenRect = caretScreenRect
        if cancelExisting {
            cancel(in: view)
        }
    }

    /// Discards any active OS composition when Rune loses focus or clears preedit (`rune::platform::ime::cancel`).
    public func cancel(in view: NSView? = nil) {
        isCanceling = true
        defer { isCanceling = false }
        markedString = ""
        markedAttributed = NSMutableAttributedString()
        markedSelectionUTF16 = NSRange(location: 0, length: 0)
        view?.inputContext?.discardMarkedText()
    }

    /// Routes an `NSEvent` keyDown through `NSTextInputContext` when appropriate.
    public func processKeyDown(_ event: NSEvent, in view: NSView, optionAsAlt: Bool = false) -> MacOSKeyInterceptResult {
        let flags = event.modifierFlags
        // Command or Control chords (plus Option chords when `El::ime_option_as_alt` is active) bypass IME composition.
        if (flags.contains(.command) || flags.contains(.control) || (optionAsAlt && flags.contains(.option))) && !isComposing {
            return .forwardKeyDown
        }

        // Control keys (Enter, Tab, Escape, Backspace, Forward Delete, Arrows, Home/End, PageUp/Down)
        // pass directly to Runtime when NOT actively composing an IME candidate.
        if !isComposing {
            switch event.keyCode {
            case 36, 76, 48, 53, 51, 117, 123, 124, 125, 126, 115, 119, 116, 121:
                return .forwardKeyDown
            default:
                break
            }
        }

        let wasComposing = isComposing
        trackingKeyEvent = true
        didInsertDuringKeyEvent = false
        didMarkDuringKeyEvent = false
        didCommandDuringKeyEvent = false
        defer { trackingKeyEvent = false }

        view.interpretKeyEvents([event])

        if didCommandDuringKeyEvent && !didMarkDuringKeyEvent && !didInsertDuringKeyEvent {
            return .forwardKeyDown
        }
        if didMarkDuringKeyEvent || didInsertDuringKeyEvent || wasComposing != isComposing {
            return .handledByIME
        }
        return .forwardKeyDown
    }

    // MARK: - NSTextInputClient Forwarding Surface

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let attr = string as? NSAttributedString {
            text = attr.string
        } else if let str = string as? String {
            text = str
        } else {
            text = ""
        }

        if let sel = ImeUTF16Bridge.resolveReplacement(replacementRange, in: imeText) {
            onEvent?(.select(sel))
        }

        markedString = ""
        markedAttributed = NSMutableAttributedString()
        markedSelectionUTF16 = NSRange(location: 0, length: 0)
        if trackingKeyEvent {
            didInsertDuringKeyEvent = true
        }
        if !isCanceling {
            onEvent?(.commit(text))
        }
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let attr: NSAttributedString
        if let a = string as? NSAttributedString {
            attr = a
        } else if let s = string as? String {
            attr = NSAttributedString(string: s)
        } else {
            attr = NSAttributedString()
        }

        if !isComposing, let sel = ImeUTF16Bridge.resolveReplacement(replacementRange, in: imeText) {
            onEvent?(.select(sel))
        }

        markedString = attr.string
        markedAttributed = NSMutableAttributedString(attributedString: attr)
        markedSelectionUTF16 = selectedRange
        if trackingKeyEvent {
            didMarkDuringKeyEvent = true
        }

        let cursorUTF8 = ImeUTF16Bridge.utf8Range(in: markedString, fromNSRange: selectedRange)
        let clauses = ImeUTF16Bridge.clauses(from: attr, preedit: markedString)
        onEvent?(.preedit(markedString, cursorUTF8: cursorUTF8, clauses: clauses))
    }

    public func unmarkText() {
        let previous = markedString
        markedString = ""
        markedAttributed = NSMutableAttributedString()
        markedSelectionUTF16 = NSRange(location: 0, length: 0)
        if !isCanceling && !previous.isEmpty {
            onEvent?(.commit(previous))
        }
    }

    public func selectedRange() -> NSRange {
        if isComposing {
            return markedSelectionUTF16
        }
        guard let imeText else { return NSRange(location: 0, length: 0) }
        return ImeUTF16Bridge.nsRange(in: imeText.text, fromUTF8Range: imeText.selectionUTF8)
    }

    public func markedRange() -> NSRange {
        guard isComposing else { return NSRange(location: NSNotFound, length: 0) }
        let caretLoc = imeText.map {
            ImeUTF16Bridge.utf16Offset(in: $0.text, fromUTF8Offset: $0.selectionUTF8.lowerBound)
        } ?? 0
        return NSRange(location: caretLoc, length: (markedString as NSString).length)
    }

    public func hasMarkedText() -> Bool {
        isComposing
    }

    public func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard let imeText, range.location != NSNotFound else { return nil }
        let totalU16 = (imeText.text as NSString).length
        let loc = min(max(0, range.location), totalU16)
        let end = min(totalU16, loc + max(0, range.length))
        let clamped = NSRange(location: loc, length: end - loc)
        actualRange?.pointee = clamped
        guard clamped.length > 0 else { return NSAttributedString() }
        let sub = (imeText.text as NSString).substring(with: clamped)
        return NSAttributedString(string: sub)
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [
            .markedClauseSegment,
            .underlineStyle,
            .underlineColor,
            .backgroundColor,
        ]
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        return candidateScreenRect
    }

    public func characterIndex(for point: NSPoint) -> Int {
        _ = point
        return 0
    }

    public func doCommand(by selector: Selector) {
        _ = selector
        if trackingKeyEvent {
            didCommandDuringKeyEvent = true
        }
    }
}

#endif
