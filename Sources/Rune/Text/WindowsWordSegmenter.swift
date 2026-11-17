#if os(Windows)
import CRuneDesktopText
internal import _FoundationICU

enum WindowsWordSegmenter {
    static func start() { rune_windows_segmenter_start() }
    static func firstFramePresented() { rune_windows_segmenter_presented() }

    /// Before System32's dictionaries are ready ICU4X uses the rule-based
    /// word breaks, grouping contiguous complex-script text by language.
    static func ruleBasedBoundaries(in text: String) -> [Int] {
        var ends = Set(text.ranges(of: #/\b/#.wordBoundaryKind(.default)).map {
            text.utf8.distance(from: text.startIndex, to: $0.lowerBound)
        })
        if text.utf8.contains(where: { $0 >= 0xe0 }) {
            func dictionaryScript(_ c: Unicode.Scalar) -> Int32? {
                guard c.value >= 0xe00 else { return nil }
                let code = Int32(c.value)
                let script = swift_u_getIntPropertyValue(code, UCHAR_SCRIPT)
                switch script {
                case Int32(USCRIPT_THAI.rawValue), Int32(USCRIPT_LAO.rawValue),
                     Int32(USCRIPT_KHMER.rawValue), Int32(USCRIPT_MYANMAR.rawValue):
                    return swift_u_getIntPropertyValue(code, UCHAR_LINE_BREAK) == Int32(U_LB_COMPLEX_CONTEXT.rawValue) ? script : nil
                case Int32(USCRIPT_HAN.rawValue), Int32(USCRIPT_HIRAGANA.rawValue):
                    return Int32(USCRIPT_HAN.rawValue)
                default:
                    return nil
                }
            }
            var last: Int32?, byte = 0
            for scalar in text.unicodeScalars {
                let script = dictionaryScript(scalar)
                if script != last { ends.insert(byte) }
                else if script != nil { ends.remove(byte) }
                last = script
                byte += scalar.utf8.count
            }
        }
        ends.remove(0)
        return ends.sorted()
    }

    /// Replace only the interior word flags of dictionary-script runs, retaining
    /// the visual caret's standard UAX word flags elsewhere.
    static func visualWordBreaks(_ standard: Set<Int>, in text: String) -> Set<Int> {
        guard text.utf8.contains(where: { $0 >= 0xe0 }),
              let length = Int32(exactly: text.utf16.count) else { return standard }
        let utf16 = Array(text.utf16)
        var flags = [UInt8](repeating: 0, count: utf16.count + 1)
        var byte = 0, unit = 0
        for scalar in text.unicodeScalars {
            if standard.contains(byte) { flags[unit] = 1 }
            unit += scalar.utf16.count
            byte += scalar.utf8.count
        }
        if standard.contains(byte) { flags[unit] = 1 }
        guard rune_windows_visual_word_breaks(utf16, length, &flags) != 0 else { return standard }
        var result: Set<Int> = []
        byte = 0
        unit = 0
        for scalar in text.unicodeScalars {
            if flags[unit] != 0 { result.insert(byte) }
            unit += scalar.utf16.count
            byte += scalar.utf8.count
        }
        if flags[unit] != 0 { result.insert(byte) }
        return result
    }

    /// UTF-8 word ends for selection. A cold or missing system ICU leaves the
    /// synchronous Unicode rule fallback available even on the first frame.
    static func boundaries(in text: String) -> [Int]? {
        guard let length = Int32(exactly: text.utf16.count) else { return nil }
        if length == 0 { return [] }
        let utf16 = Array(text.utf16)
        var ends = [Int32](repeating: 0, count: utf16.count)
        let count = rune_windows_word_ends(utf16, length, &ends)
        guard count >= 0 else { return nil }
        var bytes: [Int] = []
        bytes.reserveCapacity(Int(count))
        var unit = 0, byte = 0, i = 0
        for scalar in text.unicodeScalars {
            unit += scalar.utf16.count
            byte += scalar.utf8.count
            if i < count, ends[i] == unit {
                bytes.append(byte)
                i += 1
            }
        }
        if bytes.last != byte { bytes.append(byte) }
        return bytes
    }
}
#endif
