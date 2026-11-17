#if canImport(Darwin) || os(Linux) || os(Android)
import Foundation

/// Foundation's Unicode word-boundary option uses ICU's dictionary break iterator.
/// It includes punctuation and spaces, as Rune's native WordSegmenter does.
enum NativeWordSegmentation {
    private static let boundary = try! NSRegularExpression(pattern: #"\b"#, options: .useUnicodeWordBoundaries)

    static func wordRange(in text: String, at byte: Int) -> (Int, Int) {
        let position = text.utf8.index(text.startIndex, offsetBy: byte).utf16Offset(in: text)
        let count = text.utf16.count
        var start = 0, end = count
        boundary.enumerateMatches(in: text, range: NSRange(location: 0, length: count)) { match, _, stop in
            guard let offset = match?.range.location else { return }
            if offset <= position { start = offset }
            else { end = offset; stop.pointee = true }
        }
        let lower = text.utf16.index(text.startIndex, offsetBy: start)
        let upper = text.utf16.index(lower, offsetBy: end - start)
        return (text.utf8.distance(from: text.startIndex, to: lower),
                text.utf8.distance(from: text.startIndex, to: upper))
    }

    static func visualWordBreaks(in text: String) -> Set<Int> {
        var breaks = Set<Int>()
        var index = text.startIndex, byte = 0, units = 0
        boundary.enumerateMatches(in: text, range: NSRange(location: 0, length: text.utf16.count)) { match, _, _ in
            guard let offset = match?.range.location else { return }
            let next = text.utf16.index(index, offsetBy: offset - units)
            byte += text.utf8.distance(from: index, to: next)
            breaks.insert(byte)
            index = next
            units = offset
        }
        return breaks
    }
}
#endif
