import Foundation

public extension El {
    /// Marks a UTF-8 byte `range` inside a text element as non-copyable (`El::uncopied`).
    ///
    /// Excluded bytes stay rendered and navigable by glyph hit-testing, while clipboard copy
    /// skips them and double-click word boundaries stop at `uncopied` span edges.
    /// Ignored on non-text elements or when `range` is empty.
    func uncopied(_ range: Range<Int>) -> Self {
        guard hasCopyableTextStorage else { return self }
        let start = max(0, range.lowerBound)
        let end = max(0, range.upperBound)
        guard start < end else { return self }
        let clamped = start..<end
        var copy = self
        var ranges = (copy.runtimeExtras[Self.uncopiedExtraKey] as? [Range<Int>]) ?? []
        let idx = ranges.firstIndex(where: { $0.lowerBound > start }) ?? ranges.endIndex
        ranges.insert(clamped, at: idx)
        copy.runtimeExtras[Self.uncopiedExtraKey] = ranges
        return copy
    }

    /// Overrides the minimum newline count (`1` by default) emitted before and after this
    /// text element when joined with stacked neighbors during copy (`El::copy_breaks`).
    ///
    /// Ignored on non-text elements.
    func copyBreaks(_ before: UInt8, _ after: UInt8) -> Self {
        guard hasCopyableTextStorage else { return self }
        var copy = self
        copy.runtimeExtras[Self.copyBreaksExtraKey] = CopyBreaksPair(before: before, after: after)
        return copy
    }

    /// Prepends `prefix` when this text element is copied from its start alongside at least
    /// one other element (`El::copy_prefix`).
    ///
    /// Selecting from inside the text, or copying the element alone, omits `prefix`.
    /// Ignored on non-text elements.
    func copyPrefix(_ prefix: String) -> Self {
        guard hasCopyableTextStorage else { return self }
        var copy = self
        copy.runtimeExtras[Self.copyPrefixExtraKey] = prefix
        return copy
    }
}

internal struct CopyBreaksPair: Equatable, Sendable {
    var before: UInt8
    var after: UInt8
}

internal extension El {
    static var uncopiedExtraKey: String { "rune.text.uncopied" }
    static var copyBreaksExtraKey: String { "rune.text.copyBreaks" }
    static var copyPrefixExtraKey: String { "rune.text.copyPrefix" }

    var hasCopyableTextStorage: Bool {
        plainText != nil || richSpans != nil || liveText != nil
    }

    var uncopiedRanges: [Range<Int>] {
        (runtimeExtras[Self.uncopiedExtraKey] as? [Range<Int>]) ?? []
    }

    var copyBreaksPair: (before: UInt8, after: UInt8) {
        if let pair = runtimeExtras[Self.copyBreaksExtraKey] as? CopyBreaksPair {
            return (pair.before, pair.after)
        }
        return (1, 1)
    }

    var copyPrefixString: String? {
        runtimeExtras[Self.copyPrefixExtraKey] as? String
    }
}
