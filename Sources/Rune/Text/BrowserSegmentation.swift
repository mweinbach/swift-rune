#if os(WASI) && RUNE_BROWSER_TEXT
import CRuneDesktopText

internal enum BrowserSegmentation {
    /// The selectable word surrounding a scalar-aligned UTF-8 offset. Intl uses UTF-16.
    static func wordRange(in text: String, at byte: Int) -> (Int, Int) {
        guard let length = Int32(exactly: text.utf8.count), length > 0 else { return (0, text.utf8.count) }
        let index = text.utf8.index(text.utf8.startIndex, offsetBy: byte)
        let position = Int32(index.utf16Offset(in: text))
        var bounds = [Int32](repeating: 0, count: 2)
        var input = text
        input.withUTF8 { rune_browser_word_range($0.baseAddress, length, position, &bounds) }
        let start = String.Index(utf16Offset: Int(bounds[0]), in: text)
        let end = String.Index(utf16Offset: Int(bounds[1]), in: text)
        return (text.utf8.distance(from: text.utf8.startIndex, to: start),
                text.utf8.distance(from: text.utf8.startIndex, to: end))
    }

    /// Word flags for visual caret motion use UTF-8, line opportunities for wrapping use UTF-16.
    /// Outside dictionary runs, both retain their standard Unicode breaks.
    static func dictionaryBreaks(_ breaks: Set<Int>, in text: String, words: Bool) -> Set<Int> {
        // The dictionary scripts use at least three UTF-8 bytes per scalar.
        guard text.utf8.contains(where: { $0 >= 0xe0 }),
              let length = Int32(exactly: text.utf8.count) else { return breaks }
        let count = words ? Int(length) : text.utf16.count
        var flags = [UInt8](repeating: 0, count: count + 1)
        for offset in breaks { flags[offset] = 1 }
        var input = text
        input.withUTF8 {
            if words { rune_browser_dictionary_words($0.baseAddress, length, &flags) }
            else { rune_browser_dictionary_lines($0.baseAddress, length, &flags) }
        }
        return Set(flags.indices.filter { flags[$0] != 0 })
    }
}
#endif
