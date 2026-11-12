import Foundation

/// Unicode-aware search folding (`rune_kit::search::Fold`):
/// full case folding (`ß`/`ẞ` -> `ss`, `ς` -> `σ`, `İ` -> `i`, and in Turkish/Azerbaijani `I` -> `ı`),
/// full-width ASCII & half-width katakana folding (`ＡＰＩ` -> `API`, `ﾃｽﾄ` -> `テスト`),
/// and asymmetric accent folding (plain query matches accented or unaccented; accented query matches exact).
public struct SearchFold: Sendable, Equatable, Hashable {
    /// `I` folds to dotless `ı`, `İ` to `i`.
    public var turkic: Bool

    public init(turkic: Bool = false) {
        self.turkic = turkic
    }

    /// Folding configured for BCP 47 language tag `tag` (`tr` and `az` fold `I` to `ı`).
    public static func forLanguage(_ tag: String) -> SearchFold {
        SearchFold(turkic: tag.hasPrefix("tr") || tag.hasPrefix("az"))
    }

    /// Non-overlapping UTF-8 byte ranges of `query` in `text`.
    public func findByteRanges(_ text: String, query: String) -> [Range<Int>] {
        if text.isEmpty || query.isEmpty {
            return []
        }
        if text.utf8.allSatisfy({ $0 < 0x80 }) && query.utf8.allSatisfy({ $0 < 0x80 }) && !turkic {
            let hay = text.lowercased()
            let needle = query.lowercased()
            return matchIndicesUTF8(hay: hay, needle: needle)
        }
        let strip = !Self.isAccented(query)
        let (needle, _) = fold(query, strip: strip)
        if needle.isEmpty {
            return []
        }
        let (hay, map) = fold(text, strip: strip)
        let needleLen = needle.utf8.count
        var ranges: [Range<Int>] = []
        for matchRange in matchIndicesUTF8(hay: hay, needle: needle) {
            let f0 = matchRange.lowerBound
            let f1 = f0 + needleLen
            guard f0 < map.count, f1 < map.count else { continue }
            let s0 = map[f0]
            let s1 = map[f1]
            if s0 != Int.max && s1 != Int.max && s0 < s1 {
                ranges.append(s0..<s1)
            }
        }
        return ranges
    }

    /// Non-overlapping string ranges of `query` in `text`.
    public func find(_ text: String, query: String) -> [Range<String.Index>] {
        let utf8 = text.utf8
        return findByteRanges(text, query: query).compactMap { byteRange in
            guard byteRange.lowerBound >= 0, byteRange.upperBound <= utf8.count else { return nil }
            let start = utf8.index(utf8.startIndex, offsetBy: byteRange.lowerBound)
            let end = utf8.index(utf8.startIndex, offsetBy: byteRange.upperBound)
            return start..<end
        }
    }

    /// Whether `text` contains `query` (trimmed); an empty query matches everything.
    public func contains(_ text: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || !findByteRanges(text, query: trimmed).isEmpty
    }

    // MARK: - Folding internals

    private static func isAccented(_ query: String) -> Bool {
        for scalar in query.unicodeScalars where !scalar.isASCII {
            for lower in String(scalar).lowercased().unicodeScalars {
                if plainLetter(lower) != nil {
                    return true
                }
                let decomposed = String(lower).decomposedStringWithCanonicalMapping.unicodeScalars
                if decomposed.dropFirst().contains(where: isMark) {
                    return true
                }
            }
        }
        return false
    }

    private func fold(_ s: String, strip: Bool) -> (String, [Int]) {
        var out = String()
        out.reserveCapacity(s.utf8.count)
        var map: [Int] = []
        map.reserveCapacity(s.utf8.count + 1)

        var byteOffset = 0
        for scalar in s.unicodeScalars {
            let scalarBytes = scalar.utf8.count
            let before = out.utf8.count
            push(&out, scalar: scalar, strip: strip)
            if out.utf8.count != before {
                if map.count < before {
                    map.append(contentsOf: repeatElement(Int.max, count: before - map.count))
                }
                map.append(byteOffset)
            }
            byteOffset += scalarBytes
        }

        let totalOut = out.utf8.count
        if map.count < totalOut {
            map.append(contentsOf: repeatElement(Int.max, count: totalOut - map.count))
        }
        map.append(s.utf8.count)
        return (out, map)
    }

    private func push(_ out: inout String, scalar raw: Unicode.Scalar, strip: Bool) {
        var c = raw
        switch raw.value {
        case 0xFF01...0xFF5E:
            if let half = Unicode.Scalar(raw.value - 0xFEE0) {
                c = half
            }
        case 0x3000:
            c = Unicode.Scalar(0x20)
        case 0xFF61...0xFF9F:
            if let voiced = Self.voice(before: out.unicodeScalars.last, mark: raw) {
                out.unicodeScalars.removeLast()
                out.unicodeScalars.append(voiced)
                return
            }
            c = Self.halfwidthKana(raw)
        default:
            break
        }

        switch c.value {
        case 0x00DF, 0x1E9E: // ß, ẞ
            out.append("ss")
            return
        case 0x03C2: // ς
            out.append("σ")
            return
        case 0x0130: // İ
            out.append("i")
            return
        case 0x0049 where turkic: // I
            out.append("ı")
            return
        default:
            if c.isASCII {
                let lower = (c.value >= 0x41 && c.value <= 0x5A) ? Unicode.Scalar(c.value + 32)! : c
                out.unicodeScalars.append(lower)
                return
            }
        }

        for lc in String(c).lowercased().unicodeScalars {
            if !strip {
                out.unicodeScalars.append(lc)
                continue
            }
            if let plain = Self.plainLetter(lc) {
                out.append(plain)
                continue
            }
            let v = lc.value
            let isStripRange = (0xC0...0x24F).contains(v) || (0x370...0x52F).contains(v) || (0x1E00...0x1FFF).contains(v)
            if !isStripRange {
                out.unicodeScalars.append(lc)
                continue
            }
            let decomposed = Array(String(lc).decomposedStringWithCanonicalMapping.unicodeScalars)
            if decomposed.count > 1, let base = decomposed.first, decomposed.dropFirst().allSatisfy(Self.isMark) {
                out.unicodeScalars.append(base)
            } else {
                out.unicodeScalars.append(lc)
            }
        }
    }

    private static func isMark(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x0300...0x036F,
             0x1AB0...0x1AFF,
             0x1DC0...0x1DFF,
             0x20D0...0x20FF,
             0xFE20...0xFE2F:
            return true
        default:
            return false
        }
    }

    private static func plainLetter(_ c: Unicode.Scalar) -> String? {
        switch c.value {
        case 0x0142: return "l"  // ł
        case 0x00F8: return "o"  // ø
        case 0x0111, 0x00F0: return "d" // đ, ð
        case 0x0127: return "h"  // ħ
        case 0x0167: return "t"  // ŧ
        case 0x00E6: return "ae" // æ
        case 0x0153: return "oe" // œ
        case 0x00FE: return "th" // þ
        default: return nil
        }
    }

    private static let halfwidthKanaTable: [Unicode.Scalar] = Array(
        "。「」、・ヲァィゥェォャュョッーアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワン゛゜".unicodeScalars
    )

    private static func halfwidthKana(_ c: Unicode.Scalar) -> Unicode.Scalar {
        let idx = Int(c.value) - 0xFF61
        guard idx >= 0 && idx < halfwidthKanaTable.count else { return c }
        return halfwidthKanaTable[idx]
    }

    private static func voice(before: Unicode.Scalar?, mark: Unicode.Scalar) -> Unicode.Scalar? {
        guard let b = before?.value else { return nil }
        let voiced: UInt32? = switch (mark.value, b) {
        case (0xFF9E, 0x30A6): 0x30F4 // ウ゛ = ヴ
        case (0xFF9E, 0x30AB...0x30C1) where b % 2 == 1: b + 1 // カ..チ -> ガ..ヂ
        case (0xFF9E, 0x30C4), (0xFF9E, 0x30C6), (0xFF9E, 0x30C8): b + 1 // ツテト -> ヅデド
        case (0xFF9E, 0x30CF...0x30DB) where (b - 0x30CF) % 3 == 0: b + 1 // ハ..ホ -> バ..ボ
        case (0xFF9F, 0x30CF...0x30DB) where (b - 0x30CF) % 3 == 0: b + 2 // ハ..ホ -> パ..ポ
        default: nil
        }
        return voiced.flatMap(Unicode.Scalar.init)
    }

    private func matchIndicesUTF8(hay: String, needle: String) -> [Range<Int>] {
        let hBytes = Array(hay.utf8)
        let nBytes = Array(needle.utf8)
        let nCount = nBytes.count
        let hCount = hBytes.count
        guard nCount > 0 && nCount <= hCount else { return [] }

        var results: [Range<Int>] = []
        var i = 0
        while i <= hCount - nCount {
            if hBytes[i..<(i + nCount)].elementsEqual(nBytes) {
                results.append(i..<(i + nCount))
                i += nCount
            } else {
                i += 1
            }
        }
        return results
    }
}

/// Upstream name alias (`rune_kit::search::Fold`).
public typealias Fold = SearchFold
