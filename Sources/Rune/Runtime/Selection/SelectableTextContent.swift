/// Selection and shaping share displayed UTF-8 offsets. Copying translates both ends back
/// to the authored text, including a selection that ends inside an expanded letter.
internal struct SelectableTextContent {
    let displayed: String
    let source: TextCaseMapping?
    let uncopied: [Range<Int>]
}

internal extension El {
    var selectableAuthoredText: String? {
        guard isSelectable, !isSecure, handlers.editLens == nil else { return nil }
        return liveText?.get() ?? plainText ?? richSpans?.map(\.text).joined()
    }

    var selectableContent: SelectableTextContent? {
        guard let raw = selectableAuthoredText else { return nil }
        let source = textCaseValue.map { TextCaseMapping(source: raw, textCase: $0) }
        let uncopied = uncopiedRanges
        return SelectableTextContent(displayed: source?.displayed ?? raw, source: source,
            uncopied: source.map { map in uncopied.map { map.displayedRange(forSourceUTF8Range: $0) } } ?? uncopied)
    }
}
