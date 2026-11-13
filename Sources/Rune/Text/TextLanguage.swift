import Foundation

/// CJK writing system preference for font fallback ordering (`rune::text::language::Writing`).
public enum TextWriting: String, Sendable, Hashable, Codable {
    case japanese
    case korean
    case simplifiedChinese
    case traditionalChinese
    case hongKongChinese

    public var bcp47Tag: String {
        switch self {
        case .japanese: return "ja"
        case .korean: return "ko"
        case .simplifiedChinese: return "zh-Hans"
        case .traditionalChinese: return "zh-Hant"
        case .hongKongChinese: return "zh-HK"
        }
    }

    /// Family substring preference list (most preferred first).
    public var preferredFamilies: [String] {
        switch self {
        case .japanese:
            return ["Hiragino Sans", "Hiragino Kaku Gothic", "ヒラギノ角ゴ", "Yu Gothic", "Meiryo", "CJK JP", "Noto Sans JP", "Source Han Sans JP"]
        case .korean:
            return ["SD Gothic", "Malgun", "CJK KR", "Noto Sans KR", " KR", "AppleGothic", "Nanum"]
        case .simplifiedChinese:
            return ["PingFang SC", "Microsoft YaHei", "CJK SC", "Noto Sans SC", "Source Han Sans SC", "Hiragino Sans GB"]
        case .traditionalChinese:
            return ["PingFang TC", "Microsoft JhengHei", "CJK TC", "Noto Sans TC", "Source Han Sans TC"]
        case .hongKongChinese:
            return ["PingFang HK", "CJK HK", "Noto Sans HK", "Source Han Sans HC", "PingFang TC", "Microsoft JhengHei", "CJK TC", "Noto Sans TC"]
        }
    }

    /// Family substrings excluded from this writing system (e.g. `Hiragino Sans GB` is SC, not JP).
    public var excludedFamilies: [String] {
        switch self {
        case .japanese: return [" GB"]
        default: return []
        }
    }
}

/// Process-wide language registry for CJK fallback and `kCTLanguageAttributeName` (`rune::text::language`).
public enum TextLanguageRegistry {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var chosen: TextWriting?
        var chosenTag: String?
        var epoch: UInt64 = 1
    }

    private static let state = State()

    /// Parses the first CJK language tag from a comma/semicolon-separated BCP-47 list (e.g. `"ja,en-US"` or `"zh-Hant-TW"`).
    public static func parseWriting(from tags: String) -> (writing: TextWriting, tag: String)? {
        for raw in tags.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lower = trimmed.lowercased().replacingOccurrences(of: "_", with: "-")
            let subtags = lower.split(separator: "-").map(String.init)
            guard let primary = subtags.first else { continue }
            switch primary {
            case "ja", "jpn":
                return (.japanese, "ja")
            case "ko", "kor":
                return (.korean, "ko")
            case "zh", "zho", "yue":
                if subtags.contains("hk") || subtags.contains("mo") || primary == "yue" {
                    return (.hongKongChinese, "zh-HK")
                }
                if subtags.contains("hant") || subtags.contains("tw") {
                    return (.traditionalChinese, "zh-Hant")
                }
                return (.simplifiedChinese, "zh-Hans")
            default:
                continue
            }
        }
        return nil
    }

    /// Sets the process-wide preferred language tags (`rune::text::set_language`).
    /// Returns `true` when the active writing/tag changed.
    @discardableResult
    public static func setLanguage(_ tags: String) -> Bool {
        let parsed = parseWriting(from: tags)
        let nextWriting = parsed?.writing
        let nextTag = parsed?.tag ?? {
            let first = tags
                .split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return first
        }()

        state.lock.lock()
        defer { state.lock.unlock() }
        if state.chosen == nextWriting && state.chosenTag == nextTag {
            return false
        }
        state.chosen = nextWriting
        state.chosenTag = nextTag
        state.epoch &+= 1
        return true
    }

    public static func currentWriting() -> TextWriting? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.chosen
    }

    public static func currentLanguageTag() -> String? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.chosenTag
    }

    public static func currentEpoch() -> UInt64 {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.epoch
    }

    /// Detects writing system from the characters in `text` (`rune::text::language::of_text`).
    /// Kana => Japanese; Hangul => Korean; Bopomofo => Traditional Chinese; Han => `chosenLanguage` if CJK, else Simplified Chinese.
    public static func writingOfText(_ text: String, chosenLanguage: String? = nil) -> TextWriting? {
        guard let tag = effectiveLanguageTag(for: text, chosen: chosenLanguage) else {
            return nil
        }
        return parseWriting(from: tag)?.writing
    }

    /// Computes the shaping/fallback BCP-47 language tag for `text` given interface `chosen` (`language::of_text`).
    public static func effectiveLanguageTag(for text: String, chosen: String?) -> String? {
        let normalizedChosen = chosen.flatMap { normalizeTag($0) }
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            return normalizedChosen
        }
        var sawHan = false
        var scriptTag: String? = nil
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x3041...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) || (0xFF66...0xFF9F).contains(v) {
                scriptTag = "ja"
                break
            }
            if (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v) || (0xA960...0xA97F).contains(v) || (0xAC00...0xD7AF).contains(v) || (0xD7B0...0xD7FF).contains(v) {
                scriptTag = "ko"
                break
            }
            if (0x3100...0x312F).contains(v) || (0x31A0...0x31BF).contains(v) {
                scriptTag = "zh-Hant"
                break
            }
            if (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v) || (0x20000...0x3FFFF).contains(v) {
                sawHan = true
            }
        }
        let chosenPrimary = normalizedChosen.map { primarySubtag($0) }
        if let scriptTag {
            let scriptPrimary = primarySubtag(scriptTag)
            if chosenPrimary == scriptPrimary {
                return normalizedChosen
            }
            return scriptTag
        }
        if sawHan && !(chosenPrimary == "ja" || chosenPrimary == "ko" || chosenPrimary == "zh") {
            return "zh-Hans"
        }
        return normalizedChosen
    }

    /// Normalizes a single BCP-47 language tag (returns `nil` for empty/unparseable tags).
    public static func normalizeTag(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let first = String(trimmed.split(whereSeparator: { $0 == "," || $0 == ";" }).first ?? "").trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty, first.unicodeScalars.allSatisfy({
            ($0.value >= 0x41 && $0.value <= 0x5A)
            || ($0.value >= 0x61 && $0.value <= 0x7A)
            || ($0.value >= 0x30 && $0.value <= 0x39)
            || $0 == "-" || $0 == "_"
        }) else {
            return nil
        }
        let canonical = first.replacingOccurrences(of: "_", with: "-")
        if let parsed = parseWriting(from: canonical) {
            return parsed.tag
        }
        return canonical
    }

    private static func primarySubtag(_ tag: String) -> String {
        String(tag.split(separator: "-", maxSplits: 1).first ?? "").lowercased()
    }

    /// Returns indices of `names` reordered so families drawing `writing` appear first in preference order,
    /// followed by all remaining entries in original order (`rune::text::language::order`).
    public static func fallbackOrder(names: [String?], writing: TextWriting) -> [Int] {
        var preferred: [(rank: Int, index: Int)] = []
        var preferredSet = Set<Int>()
        for (i, maybeName) in names.enumerated() {
            guard let name = maybeName else { continue }
            if writing.excludedFamilies.contains(where: { name.contains($0) }) {
                continue
            }
            if let rank = writing.preferredFamilies.firstIndex(where: { name.contains($0) }) {
                preferred.append((rank, i))
                preferredSet.insert(i)
            }
        }
        preferred.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.index < b.index
        }
        var out = preferred.map(\.index)
        for i in 0..<names.count where !preferredSet.contains(i) {
            out.append(i)
        }
        return out
    }
}

/// Top-level convenience mirror of `rune::text::set_language`.
@discardableResult
public func setTextLanguage(_ tags: String) -> Bool {
    TextLanguageRegistry.setLanguage(tags)
}
