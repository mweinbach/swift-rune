import Foundation

/// Errors thrown by runtime catalog loading (`Catalog.loadJSON`).
public enum I18nError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownLocale(Int)
    case invalidJSON(String)

    public var description: String {
        switch self {
        case .unknownLocale(let index):
            return "no locale \(index)"
        case .invalidJSON(let message):
            return message
        }
    }
}

/// Parsed BCP-47 locale tag (`language[-script][-region]`) plus optional picker metadata (`id`, `label`, `rtl`).
public struct LocaleInfo: Sendable, Hashable, Codable, CustomStringConvertible {
    public var id: String
    public var language: String
    public var script: String?
    public var region: String?
    public var label: String
    public var rtl: Bool
    private var explicitTag: String?

    public init(language: String, script: String? = nil, region: String? = nil) {
        self.language = language.lowercased()
        self.script = script?.capitalized
        self.region = region?.uppercased()
        self.explicitTag = nil
        var computedTag = self.language
        if let s = self.script { computedTag += "-\(s)" }
        if let r = self.region { computedTag += "-\(r)" }
        self.id = computedTag
        self.label = computedTag
        self.rtl = Self.inferRTL(language: self.language, script: self.script)
    }

    public init(_ tag: String) {
        let parsed = Self.parseTag(tag)
        self.init(language: parsed.language, script: parsed.script, region: parsed.region)
    }

    /// Creates a `LocaleInfo` with explicit manifest metadata (`id`, BCP-47 `tag`, picker `label`, `rtl`).
    public init(id: String, tag: String, label: String, rtl: Bool) {
        let parsed = Self.parseTag(tag)
        self.id = id
        self.language = parsed.language
        self.script = parsed.script
        self.region = parsed.region
        self.label = label
        self.rtl = rtl
        self.explicitTag = tag
    }

    private static func parseTag(_ tag: String) -> (language: String, script: String?, region: String?) {
        let normalized = tag.replacingOccurrences(of: "_", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = normalized.split(separator: "-").map(String.init)
        guard let first = parts.first, !first.isEmpty else {
            return ("en", nil, nil)
        }
        let lang = first.lowercased()
        var script: String? = nil
        var region: String? = nil
        for part in parts.dropFirst() {
            // A 1-character singleton (e.g. -u-, -t-, -x-) starts a BCP-47 extension/private-use sequence.
            if part.count == 1 {
                break
            }
            if part.count == 4 && part.allSatisfy(\.isLetter) && script == nil {
                script = part.capitalized
            } else if (part.count == 2 && part.allSatisfy(\.isLetter)) || (part.count == 3 && part.allSatisfy(\.isNumber)), region == nil {
                region = part.uppercased()
            }
        }
        return (lang, script, region)
    }

    private static func inferRTL(language: String, script: String?) -> Bool {
        switch language {
        case "ar", "he", "iw", "fa", "ur", "yi", "ps", "dv", "ug", "sd", "ku":
            return script == nil || script == "Arab" || script == "Hebr" || script == "Thaa"
        default:
            return script == "Arab" || script == "Hebr" || script == "Thaa"
        }
    }

    public var tag: String {
        if let explicitTag { return explicitTag }
        var out = language
        if let script { out += "-\(script)" }
        if let region { out += "-\(region)" }
        return out
    }

    public var isRTL: Bool { rtl }

    public var description: String { tag }

    public static func == (lhs: LocaleInfo, rhs: LocaleInfo) -> Bool {
        lhs.language == rhs.language
            && lhs.script == rhs.script
            && lhs.region == rhs.region
            && lhs.id == rhs.id
            && lhs.label == rhs.label
            && lhs.rtl == rhs.rtl
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(language)
        hasher.combine(script)
        hasher.combine(region)
        hasher.combine(id)
        hasher.combine(label)
        hasher.combine(rtl)
    }
}

/// Returns the index in `supported` of the best matching locale for `preferred` (BCP-47 tags, most wanted first)
/// using CLDR likely-subtag script expansion and Norwegian (`no`/`nb`/`nn`) equivalence, or `nil` when none match.
public func negotiate(_ preferred: [String], supported: [String]) -> Int? {
    func maximize(_ raw: String) -> (language: String, script: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        guard let first = parts.first, (2...3).contains(first.count), first.allSatisfy(\.isLetter) else {
            return nil
        }
        let info = LocaleInfo(trimmed)
        let script = info.script ?? likelyScript(for: info)
        return (info.language, script)
    }

    let targets = supported.map(maximize)
    for pref in preferred {
        guard let source = maximize(pref) else { continue }
        let norwegian = isNorwegian(source.language)
        if let idx = targets.firstIndex(where: { target in
            guard let target else { return false }
            if norwegian {
                return isNorwegian(target.language)
            }
            return target.language == source.language && target.script == source.script
        }) {
            return idx
        }
    }
    return nil
}

/// Negotiates the best supported locale from user preferences with fallback.
public func negotiateLocale(
    requested: [String],
    available: [String],
    default fallback: String = "en"
) -> String {
    if let idx = negotiate(requested, supported: available) {
        return available[idx]
    }
    return fallback
}

private func isNorwegian(_ lang: String) -> Bool {
    lang == "no" || lang == "nb" || lang == "nn"
}

private func likelyScript(for locale: LocaleInfo) -> String {
    switch locale.language {
    case "zh":
        switch locale.region {
        case "TW", "HK", "MO": return "Hant"
        default: return "Hans"
        }
    case "yue":
        switch locale.region {
        case "CN": return "Hans"
        default: return "Hant"
        }
    case "sr":
        switch locale.region {
        case "XK", "ME": return "Latn"
        default: return "Cyrl"
        }
    case "pa":
        switch locale.region {
        case "PK": return "Arab"
        default: return "Guru"
        }
    case "uz":
        switch locale.region {
        case "AF": return "Arab"
        default: return "Latn"
        }
    case "az":
        switch locale.region {
        case "IR": return "Arab"
        default: return "Latn"
        }
    case "kk", "ky":
        return locale.region == "CN" ? "Arab" : "Cyrl"
    case "ku":
        return (locale.region == "IQ" || locale.region == "IR") ? "Arab" : "Latn"
    case "mn":
        return locale.region == "CN" ? "Mong" : "Cyrl"
    case "sd":
        return locale.region == "IN" ? "Deva" : "Arab"
    case "tg":
        return locale.region == "PK" ? "Arab" : "Cyrl"
    case "ar", "fa", "ur", "ps", "ug":
        return "Arab"
    case "he", "iw", "yi":
        return "Hebr"
    case "ru", "uk", "be", "bg", "mk":
        return "Cyrl"
    case "ja": return "Jpan"
    case "ko": return "Kore"
    case "el": return "Grek"
    case "hi", "mr", "ne", "sa": return "Deva"
    case "th": return "Thai"
    case "hy": return "Armn"
    case "ka": return "Geor"
    case "bn", "as": return "Beng"
    case "ta": return "Taml"
    case "te": return "Telu"
    case "kn": return "Knda"
    case "ml": return "Mlym"
    case "gu": return "Gujr"
    case "or": return "Orya"
    case "si": return "Sinh"
    case "my": return "Mymr"
    case "km": return "Khmr"
    case "lo": return "Laoo"
    case "am", "ti": return "Ethi"
    case "dv": return "Thaa"
    default:
        return "Latn"
    }
}

/// Returns the OS's preferred languages as BCP-47 tags, most wanted first.
public func systemLanguages() -> [String] {
    Locale.preferredLanguages
}

/// Parses POSIX locale environment variables (`LANGUAGE`, `LC_ALL`, `LC_MESSAGES`, `LANG`)
/// into deduplicated BCP-47 tags, stripping `.encoding` and `@variant` and ignoring `C` / `POSIX`.
public func posixLanguages(_ env: (String) -> String?) -> [String] {
    var out: [String] = []
    var rawValues: [String] = []
    if let languageList = env("LANGUAGE") {
        rawValues.append(contentsOf: languageList.split(separator: ":").map(String.init))
    }
    for key in ["LC_ALL", "LC_MESSAGES", "LANG"] {
        if let val = env(key) {
            rawValues.append(val)
        }
    }
    for value in rawValues {
        let base = value.split(whereSeparator: { $0 == "." || $0 == "@" }).first.map(String.init) ?? ""
        let tag = base.replacingOccurrences(of: "_", with: "-")
        if tag.isEmpty || tag == "C" || tag == "POSIX" || out.contains(tag) {
            continue
        }
        out.append(tag)
    }
    return out
}

/// CLDR cardinal plural category.
public enum PluralCategory: String, Sendable, Hashable, Codable, CaseIterable {
    case zero
    case one
    case two
    case few
    case many
    case other

    /// Evaluates CLDR cardinal plural category for integer `n` in `locale`.
    public static func select(count: Int, locale: LocaleInfo) -> PluralCategory {
        let n = abs(count)
        let mod10 = n % 10
        let mod100 = n % 100

        switch locale.language {
        case "ja", "zh", "yue", "ko", "vi", "th", "id", "ms", "lo", "km", "my", "bo", "dz", "jv", "su", "wo", "yo", "ig":
            return .other

        case "pt":
            if locale.region == "PT" {
                return n == 1 ? .one : .other
            }
            return (n == 0 || n == 1) ? .one : .other

        case "fr", "hi", "fa", "bn", "gu", "kn", "mr", "pa", "as", "or", "am", "ti", "zu", "si", "hy", "ff", "kab":
            return (n == 0 || n == 1) ? .one : .other

        case "ru", "uk", "be":
            if mod10 == 1 && mod100 != 11 { return .one }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return .few }
            return .many

        case "pl":
            if n == 1 { return .one }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return .few }
            return .many

        case "cs", "sk":
            if n == 1 { return .one }
            if (2...4).contains(n) { return .few }
            return .other

        case "lt":
            if mod10 == 1 && !(11...19).contains(mod100) { return .one }
            if (2...9).contains(mod10) && !(11...19).contains(mod100) { return .few }
            return .other

        case "lv", "prg":
            if mod10 == 0 || (11...19).contains(mod100) { return .zero }
            if mod10 == 1 && mod100 != 11 { return .one }
            return .other

        case "ro", "mo":
            if n == 1 { return .one }
            if n == 0 || (1...19).contains(mod100) { return .few }
            return .other

        case "sl":
            if mod100 == 1 { return .one }
            if mod100 == 2 { return .two }
            if mod100 == 3 || mod100 == 4 { return .few }
            return .other

        case "hr", "sr", "bs":
            if mod10 == 1 && mod100 != 11 { return .one }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return .few }
            return .other

        case "ga":
            if n == 1 { return .one }
            if n == 2 { return .two }
            if (3...6).contains(n) { return .few }
            if (7...10).contains(n) { return .many }
            return .other

        case "cy":
            switch n {
            case 0: return .zero
            case 1: return .one
            case 2: return .two
            case 3: return .few
            case 6: return .many
            default: return .other
            }

        case "mt":
            if n == 1 { return .one }
            if n == 2 { return .two }
            if n == 0 || (3...10).contains(mod100) { return .few }
            if (11...19).contains(mod100) { return .many }
            return .other

        case "is", "mk":
            return (mod10 == 1 && mod100 != 11) ? .one : .other

        case "gd":
            if n == 1 || n == 11 { return .one }
            if n == 2 || n == 12 { return .two }
            if (3...10).contains(n) || (13...19).contains(n) { return .few }
            return .other

        case "fil", "tl":
            if mod10 == 4 || mod10 == 6 || mod10 == 9 { return .other }
            return .one

        case "ar":
            if n == 0 { return .zero }
            if n == 1 { return .one }
            if n == 2 { return .two }
            if (3...10).contains(mod100) { return .few }
            if (11...99).contains(mod100) { return .many }
            return .other

        case "he", "iw":
            if n == 1 { return .one }
            if n == 2 { return .two }
            if n > 10 && n % 10 == 0 { return .many }
            return .other

        default:
            // Germanic / Romance (es, it, ...) / Turkic (tr, az, ...) / Finno-Ugric / Georgian
            return n == 1 ? .one : .other
        }
    }
}

/// One piece of a parsed `Template`: literal text or a placeholder argument name.
public enum TemplatePart: Sendable, Equatable {
    case text(String)
    case arg(String)
}

/// Pre-parsed `{{variable}}` interpolation template.
public struct Template: Sendable, Equatable {
    private enum Segment: Sendable, Equatable {
        case literal(String)
        case variable(String)
    }

    private let segments: [Segment]

    /// The template's literal runs and placeholder argument names in order.
    public var parts: [TemplatePart] {
        segments.map { seg in
            switch seg {
            case .literal(let s): return .text(s)
            case .variable(let name): return .arg(name)
            }
        }
    }

    /// Splits `source` into literal text runs and `{{name}}` placeholder argument parts.
    public static func parts(_ source: String) -> [TemplatePart] {
        Template(source).parts
    }

    public init(_ source: String) {
        var out: [Segment] = []
        var pos = source.startIndex

        func appendLiteral(_ slice: Substring) {
            guard !slice.isEmpty else { return }
            let str = String(slice)
            if case .literal(let prev)? = out.last {
                out[out.count - 1] = .literal(prev + str)
            } else {
                out.append(.literal(str))
            }
        }

        while pos < source.endIndex {
            guard let openRange = source[pos...].range(of: "{{") else {
                appendLiteral(source[pos...])
                break
            }
            let open = openRange.lowerBound
            let inner = openRange.upperBound
            if let firstClose = source[inner...].firstIndex(of: "}"),
               firstClose > inner,
               source[firstClose...].hasPrefix("}}") {
                let name = source[inner..<firstClose].trimmingCharacters(in: .whitespaces)
                let afterClose = source.index(firstClose, offsetBy: 2)
                appendLiteral(source[pos..<open])
                out.append(.variable(name))
                pos = afterClose
            } else {
                let nextPos = source.index(after: open)
                appendLiteral(source[pos..<nextPos])
                pos = nextPos
            }
        }

        self.segments = out
    }

    public func render(_ args: [String: String] = [:]) -> String {
        var result = ""
        for seg in segments {
            switch seg {
            case .literal(let s):
                result += s
            case .variable(let name):
                if let val = args[name] {
                    result += val
                }
            }
        }
        return result
    }
}

/// Message entry in a `Catalog`: either a single template or pluralized forms.
public enum CatalogEntry: Sendable, Equatable {
    case single(Template)
    case plural([PluralCategory: Template])
}

/// One locale's message blob: concatenated UTF-8 text plus little-endian `(start, len)` `u32` span pairs.
/// Supports both compile-time embedded blobs (`init(text:spans:)`) and lazy runtime loading (`later()`).
public final class Messages: @unchecked Sendable, Equatable {
    private enum Storage {
        case later
        case loaded(utf8: [UInt8], spans: [UInt8])
    }

    private let lock = NSLock()
    private var storage: Storage

    public init(text: String, spans: [UInt8]) {
        self.storage = .loaded(utf8: Array(text.utf8), spans: spans)
    }

    private init(storage: Storage) {
        self.storage = storage
    }

    /// Creates a deferred message slot to be filled at runtime via `Catalog.loadJSON(locale:json:)`.
    public static func later() -> Messages {
        Messages(storage: .later)
    }

    /// Returns whether messages are embedded or have already been loaded at runtime.
    public func present() -> Bool {
        lock.withLock {
            if case .loaded = storage { return true }
            return false
        }
    }

    /// Returns the message for key index `key`, or `nil` when absent or unloaded.
    public func get(_ key: Int) -> String? {
        guard key >= 0 else { return nil }
        let snapshot: ([UInt8], [UInt8])? = lock.withLock {
            if case .loaded(let utf8, let spans) = storage {
                return (utf8, spans)
            }
            return nil
        }
        guard let (utf8, spans) = snapshot else { return nil }
        let at = key * 8
        guard at + 8 <= spans.count else { return nil }
        let start = UInt32(spans[at])
            | (UInt32(spans[at + 1]) << 8)
            | (UInt32(spans[at + 2]) << 16)
            | (UInt32(spans[at + 3]) << 24)
        if start == UInt32.max {
            return nil
        }
        let len = UInt32(spans[at + 4])
            | (UInt32(spans[at + 5]) << 8)
            | (UInt32(spans[at + 6]) << 16)
            | (UInt32(spans[at + 7]) << 24)
        let s = Int(start)
        let e = s + Int(len)
        guard s >= 0, e <= utf8.count else { return nil }
        return String(decoding: utf8[s..<e], as: UTF8.self)
    }

    internal func setIfAbsent(text: String, spans: [UInt8]) {
        lock.withLock {
            if case .later = storage {
                storage = .loaded(utf8: Array(text.utf8), spans: spans)
            }
        }
    }

    public static func == (lhs: Messages, rhs: Messages) -> Bool {
        if lhs === rhs { return true }
        let l = lhs.lock.withLock { lhs.storage }
        let r = rhs.lock.withLock { rhs.storage }
        switch (l, r) {
        case (.later, .later):
            return true
        case (.loaded(let lu, let ls), .loaded(let ru, let rs)):
            return lu == ru && ls == rs
        default:
            return false
        }
    }
}

/// Translation catalog for a single locale or a multi-locale indexed blob bundle.
public struct Catalog: Sendable, Equatable {
    public var locale: LocaleInfo
    public var entries: [String: CatalogEntry]

    public let keys: [String]
    public let plurals: [String]
    public let pluralForms: [[UInt32]]
    public let locales: [LocaleInfo]
    public let messages: [Messages]

    public init(locale: LocaleInfo, entries: [String: CatalogEntry] = [:]) {
        self.locale = locale
        self.entries = entries
        self.keys = []
        self.plurals = []
        self.pluralForms = []
        self.locales = [locale]
        self.messages = []
    }

    /// Creates a multi-locale blob catalog matching upstream `rune_i18n::Catalog::new`.
    public init(
        keys: [String],
        plurals: [String],
        pluralForms: [[UInt32]],
        locales: [LocaleInfo],
        messages: [Messages]
    ) {
        self.locale = locales.first ?? LocaleInfo("en")
        self.entries = [:]
        self.keys = keys
        self.plurals = plurals
        self.pluralForms = pluralForms
        self.locales = locales
        self.messages = messages
    }

    /// Returns whether `locale`'s messages are embedded or already loaded at runtime.
    public func present(_ locale: Int) -> Bool {
        guard locale >= 0 && locale < messages.count else { return false }
        return messages[locale].present()
    }

    /// Fills a deferred runtime locale (`Messages.later()`) from a flat JSON object of `key -> message`.
    /// Unknown keys are ignored, missing keys fall back to locale 0, and missing RTL messages get LRI..PDI isolation.
    public func loadJSON(locale: Int, json: String) throws {
        guard locale >= 0 && locale < messages.count else {
            throw I18nError.unknownLocale(locale)
        }
        let target = messages[locale]
        if target.present() { return }
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = raw as? [String: Any] else {
            throw I18nError.invalidJSON("not a JSON object")
        }
        let isTargetRTL = locales.indices.contains(locale) && locales[locale].rtl
        let isSourceRTL = locales.first?.rtl ?? false
        let isolate: ((String) -> String?)? = (isTargetRTL && !isSourceRTL)
            ? { key in
                guard let k = Catalog.find(keys, name: key) else { return nil }
                return messages.first?.get(k)
            }
            : nil
        let (text, spans) = Catalog.blob(
            keys: keys,
            message: { dict[$0] as? String },
            isolate: isolate
        )
        target.setIfAbsent(text: text, spans: spans)
    }

    /// Binary search for `name` in UTF-8-byte-sorted `keys`.
    public static func find(_ keys: [String], name: String) -> Int? {
        var lo = 0
        var hi = keys.count
        let nameBytes = Array(name.utf8)
        while lo < hi {
            let mid = (lo + hi) / 2
            let midBytes = Array(keys[mid].utf8)
            if midBytes.lexicographicallyPrecedes(nameBytes) {
                lo = mid + 1
            } else if nameBytes.lexicographicallyPrecedes(midBytes) {
                hi = mid
            } else {
                return mid
            }
        }
        return nil
    }

    /// Builds the `(text, spans)` blob for `keys`, wrapping missing RTL messages with `\u{2066}...\u{2069}` when `isolate` returns a source string.
    public static func blob(
        keys: [String],
        message: (String) -> String?,
        isolate: ((String) -> String?)? = nil
    ) -> (String, [UInt8]) {
        var utf8Buf: [UInt8] = []
        var spans: [UInt8] = []
        spans.reserveCapacity(keys.count * 8)
        for key in keys {
            let own = message(key)
            let resolved: String?
            if let own {
                resolved = own
            } else if let isolate, let src = isolate(key) {
                resolved = "\u{2066}\(src)\u{2069}"
            } else {
                resolved = nil
            }
            let start: UInt32
            let len: UInt32
            if let msg = resolved {
                start = UInt32(utf8Buf.count)
                let bytes = Array(msg.utf8)
                len = UInt32(bytes.count)
                utf8Buf.append(contentsOf: bytes)
            } else {
                start = UInt32.max
                len = 0
            }
            spans.append(UInt8(truncatingIfNeeded: start))
            spans.append(UInt8(truncatingIfNeeded: start >> 8))
            spans.append(UInt8(truncatingIfNeeded: start >> 16))
            spans.append(UInt8(truncatingIfNeeded: start >> 24))
            spans.append(UInt8(truncatingIfNeeded: len))
            spans.append(UInt8(truncatingIfNeeded: len >> 8))
            spans.append(UInt8(truncatingIfNeeded: len >> 16))
            spans.append(UInt8(truncatingIfNeeded: len >> 24))
        }
        return (String(decoding: utf8Buf, as: UTF8.self), spans)
    }

    internal func pluralForms(for key: I18nPluralKey) -> [Int?] {
        let idx = key.index >= 0 ? key.index : (Catalog.find(plurals, name: key.rawValue) ?? -1)
        guard idx >= 0 && idx < pluralForms.count else {
            return Array(repeating: nil, count: 6)
        }
        return pluralForms[idx].map { $0 == UInt32.max ? nil : Int($0) }
    }

    internal func pluralName(for key: I18nPluralKey) -> String {
        if key.index >= 0 && key.index < plurals.count {
            return plurals[key.index]
        }
        return key.rawValue
    }

    /// Parses a JSON dictionary where values are either strings (`"Hello {{name}}"`)
    /// or plural objects (`{"one": "{{count}} item", "other": "{{count}} items"}`)
    /// or nested namespaces (`{"settings": {"title": "Settings"}}` -> `"settings.title"`).
    public static func fromJSON(locale: String, data: Data) throws -> Catalog {
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = raw as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        var entries: [String: CatalogEntry] = [:]
        flatten(dict: dict, prefix: "", into: &entries)
        return Catalog(locale: LocaleInfo(locale), entries: entries)
    }

    private static func flatten(dict: [String: Any], prefix: String, into entries: inout [String: CatalogEntry]) {
        let pluralKeys = Set(PluralCategory.allCases.map(\.rawValue))
        for (k, v) in dict {
            let fullKey = prefix.isEmpty ? k : "\(prefix).\(k)"
            if let str = v as? String {
                entries[fullKey] = .single(Template(str))
            } else if let sub = v as? [String: Any] {
                let keys = Set(sub.keys)
                if !keys.isEmpty && keys.isSubset(of: pluralKeys) && sub.values.allSatisfy({ $0 is String }) {
                    var forms: [PluralCategory: Template] = [:]
                    for (pk, pv) in sub {
                        if let cat = PluralCategory(rawValue: pk), let s = pv as? String {
                            forms[cat] = Template(s)
                        }
                    }
                    entries[fullKey] = .plural(forms)
                } else {
                    flatten(dict: sub, prefix: fullKey, into: &entries)
                }
            }
        }
    }
}

/// Multi-locale localization bundle with fallback resolution, plural selection, and `{{var}}` formatting.
public struct I18n: Sendable {
    public private(set) var currentLocale: LocaleInfo
    public var fallbackLocale: LocaleInfo
    public let catalog: Catalog?
    private var catalogs: [String: Catalog]
    private var localeOrder: [String]
    private var currentIndex: Int

    public init(
        locale: String = "en",
        fallback: String = "en",
        catalogs: [Catalog] = []
    ) {
        self.currentLocale = LocaleInfo(locale)
        self.fallbackLocale = LocaleInfo(fallback)
        self.catalog = nil
        var map: [String: Catalog] = [:]
        var order: [String] = []
        for cat in catalogs {
            let tag = cat.locale.tag
            if map[tag] == nil {
                order.append(tag)
            }
            map[tag] = cat
        }
        self.catalogs = map
        self.localeOrder = order
        self.currentIndex = order.firstIndex(of: self.currentLocale.tag) ?? 0
    }

    /// Initializes a translator over a multi-locale blob `Catalog`, starting at locale index 0.
    public init(catalog: Catalog) {
        self.catalog = catalog
        let first = catalog.locales.first ?? LocaleInfo("en")
        self.currentLocale = first
        self.fallbackLocale = first
        self.catalogs = [:]
        self.localeOrder = catalog.locales.map(\.tag)
        self.currentIndex = 0
    }

    /// Supported locales in catalog order.
    public var locales: [LocaleInfo] {
        if let catalog { return catalog.locales }
        return localeOrder.compactMap { catalogs[$0]?.locale }
    }

    /// Current locale index into `locales`.
    public var localeIndex: Int {
        currentIndex
    }

    /// Returns `LocaleInfo` for the current locale.
    public func info() -> LocaleInfo {
        let all = locales
        if currentIndex >= 0 && currentIndex < all.count {
            return all[currentIndex]
        }
        return currentLocale
    }

    /// Returns the index in `locales` whose `id` matches `id`, or `nil`.
    public func findLocale(_ id: String) -> Int? {
        locales.firstIndex { $0.id == id }
    }

    public mutating func insert(_ catalog: Catalog) {
        let tag = catalog.locale.tag
        if catalogs[tag] == nil {
            localeOrder.append(tag)
        }
        catalogs[tag] = catalog
    }

    public mutating func setLocale(_ tag: String) {
        if let catalog {
            let idx = negotiate(requested: [tag])
            if let matched = catalog.locales.indices.contains(idx) ? idx : catalog.locales.firstIndex(where: { $0.tag == tag }) {
                _ = setLocale(matched)
            }
            return
        }
        let best = negotiateLocale(
            requested: [tag],
            available: Array(catalogs.keys),
            default: fallbackLocale.tag
        )
        currentLocale = LocaleInfo(best)
        currentIndex = localeOrder.firstIndex(of: best) ?? 0
    }

    /// Selects locale by index into `locales`, returning whether the active locale changed.
    /// Out-of-bounds indices are ignored and return `false`.
    @discardableResult
    public mutating func setLocale(_ index: Int) -> Bool {
        let all = locales
        guard index >= 0 && index < all.count else { return false }
        let changed = currentIndex != index
        currentIndex = index
        currentLocale = all[index]
        return changed
    }

    public var isRTL: Bool { currentLocale.isRTL }

    /// All catalog locale tags registered in this bundle.
    public var availableLocales: [String] {
        if let catalog {
            return catalog.locales.map(\.tag).sorted()
        }
        return Array(catalogs.keys).sorted()
    }

    /// Returns whether `key` exists in either the current or fallback locale chain.
    public func hasKey(_ key: String) -> Bool {
        if let catalog {
            return Catalog.find(catalog.keys, name: key) != nil
        }
        return lookup(key) != nil
    }

    /// Negotiates the best supported locale index from `preferred`, defaulting to `0` (source locale).
    public func negotiateIndex(_ preferred: [String]) -> Int {
        let tags = locales.map(\.tag)
        return RuneI18n.negotiate(preferred, supported: tags) ?? 0
    }

    private func negotiate(requested preferred: [String]) -> Int {
        negotiateIndex(preferred)
    }

    /// Negotiates the best supported locale from `preferred` without mutating `currentLocale`.
    public func negotiate(_ preferred: [String]) -> String {
        if let catalog {
            let tags = catalog.locales.map(\.tag)
            return negotiateLocale(requested: preferred, available: tags, default: fallbackLocale.tag)
        }
        return negotiateLocale(requested: preferred, available: Array(catalogs.keys), default: fallbackLocale.tag)
    }

    /// Formats `n` with the current locale's digits and grouping (`1,234`, `1.234`).
    public func integer(_ n: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: currentLocale.tag)
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// Formats `n` rounded half away from zero to at most `maxFraction` fraction digits
    /// using the shortest round-trip decimal representation of `n`.
    public func decimal(_ n: Double, maxFraction: Int = 2) -> String {
        guard n.isFinite else { return String(n) }
        let digits = max(0, maxFraction)
        let raw = n == 0 ? "0" : String(n)
        guard var dec = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
            return raw
        }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &dec, digits, .plain)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: currentLocale.tag)
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSDecimalNumber(decimal: rounded)) ?? raw
    }

    /// Formats `items` as the current locale's long conjunction list (`a, b, and c`).
    public func list(_ items: [String]) -> String {
        if items.isEmpty { return "" }
        let formatter = ListFormatter()
        formatter.locale = Locale(identifier: currentLocale.tag)
        return formatter.string(from: items) ?? items.joined(separator: ", ")
    }

    /// Formats `n` in compact notation (`1.2K`, `3.4M`, `5.6B`, `1.2T`) using the current locale's decimal separator.
    public func compact(_ n: Double, maxFraction: Int = 1) -> String {
        let sign = n < 0 ? "-" : ""
        let absVal = abs(n)
        let units: [(threshold: Double, suffix: String)] = [
            (1_000_000_000_000, "T"),
            (1_000_000_000, "B"),
            (1_000_000, "M"),
            (1_000, "K"),
        ]
        for (threshold, suffix) in units where absVal >= threshold {
            let scaled = absVal / threshold
            let formatted = decimal(scaled, maxFraction: maxFraction)
            return "\(sign)\(formatted)\(suffix)"
        }
        return decimal(n, maxFraction: maxFraction)
    }

    /// Formats integer `n` in compact notation (`1.2K`, `3.4M`, `5.6B`).
    public func compact(_ n: Int, maxFraction: Int = 1) -> String {
        compact(Double(n), maxFraction: maxFraction)
    }

    /// Returns the CLDR cardinal plural category for `count` in the current locale.
    public func pluralCategory(for count: Int) -> PluralCategory {
        PluralCategory.select(count: count, locale: currentLocale)
    }

    /// Strongly-typed message lookup using a generated `I18nKey`.
    public func text(_ key: I18nKey) -> String {
        if catalog != nil {
            return textIn(currentIndex, key)
        }
        return t(key.rawValue)
    }

    /// Looks up a typed `I18nKey` in an explicit locale index, falling back to the source locale (0).
    public func textIn(_ locale: Int, _ key: I18nKey) -> String {
        if let catalog {
            let keyIdx = key.index >= 0 ? key.index : (Catalog.find(catalog.keys, name: key.rawValue) ?? -1)
            if keyIdx >= 0, let msg = blobGet(catalog: catalog, locale: locale, keyIndex: keyIdx) {
                return msg
            }
            if keyIdx >= 0 && keyIdx < catalog.keys.count {
                return catalog.keys[keyIdx]
            }
            return key.rawValue
        }
        let all = locales
        guard locale >= 0 && locale < all.count else { return t(key.rawValue) }
        let loc = all[locale]
        if let cat = catalogs[loc.tag], case .single(let tmpl)? = cat.entries[key.rawValue] {
            return tmpl.render([:])
        }
        return t(key.rawValue)
    }

    /// Strongly-typed template formatting using a generated `I18nKey`.
    public func format(_ key: I18nKey, args: [String: String] = [:]) -> String {
        if catalog != nil {
            return Template(text(key)).render(args)
        }
        return t(key.rawValue, args: args)
    }

    /// Returns the raw template string of plural base `key` for `count`'s CLDR category in the current locale.
    public func pluralRaw(_ key: I18nPluralKey, count: Int) -> String {
        pluralForm(key, category: pluralCategory(for: count))
    }

    /// Returns the template string of plural base `key` for an explicit `category`, trying
    /// `current[category] ?? source[category]` before `current[.other] ?? source[.other]`.
    public func pluralForm(_ key: I18nPluralKey, category: PluralCategory) -> String {
        if let catalog {
            let forms = catalog.pluralForms(for: key)
            let catIndex: (PluralCategory) -> Int = { cat in
                switch cat {
                case .zero: return 0
                case .one: return 1
                case .two: return 2
                case .few: return 3
                case .many: return 4
                case .other: return 5
                }
            }
            func pick(_ cat: PluralCategory) -> String? {
                guard let keyIdx = forms[catIndex(cat)] else { return nil }
                return blobGet(catalog: catalog, locale: currentIndex, keyIndex: keyIdx)
            }
            return pick(category) ?? pick(.other) ?? catalog.pluralName(for: key)
        }
        return pickPluralTemplate(key.rawValue, category: category)?.render([:]) ?? key.rawValue
    }

    /// Strongly-typed plural formatting using a generated `I18nPluralKey`.
    public func pluralFormat(_ key: I18nPluralKey, count: Int, args: [String: String] = [:]) -> String {
        if catalog != nil {
            var merged = args
            if merged["count"] == nil {
                merged["count"] = String(count)
            }
            return Template(pluralRaw(key, count: count)).render(merged)
        }
        return plural(key.rawValue, count: count, args: args)
    }

    /// Strongly-typed plural formatting using a generated `I18nPluralKey`.
    public func plural(_ key: I18nPluralKey, count: Int, args: [String: String] = [:]) -> String {
        pluralFormat(key, count: count, args: args)
    }

    /// Looks up and formats `key` with optional named `args`.
    public func t(_ key: String, args: [String: String] = [:]) -> String {
        if let catalog {
            if let idx = Catalog.find(catalog.keys, name: key),
               let msg = blobGet(catalog: catalog, locale: currentIndex, keyIndex: idx) {
                return Template(msg).render(args)
            }
            return key
        }
        if let entry = lookup(key) {
            switch entry {
            case .single(let tmpl):
                return tmpl.render(args)
            case .plural(let forms):
                let tmpl = forms[.other] ?? forms.values.first
                return tmpl?.render(args) ?? key
            }
        }
        return key
    }

    /// Looks up and formats a pluralized message for `count`, automatically injecting `{{count}}`.
    public func plural(_ key: String, count: Int, args: [String: String] = [:]) -> String {
        var merged = args
        if merged["count"] == nil {
            merged["count"] = String(count)
        }
        if catalog != nil {
            return pluralFormat(I18nPluralKey(key), count: count, args: merged)
        }
        let cat = PluralCategory.select(count: count, locale: currentLocale)
        if let tmpl = pickPluralTemplate(key, category: cat) {
            return tmpl.render(merged)
        }
        if let single = lookupSingle(key) {
            return single.render(merged)
        }
        return key
    }

    private func blobGet(catalog: Catalog, locale: Int, keyIndex: Int) -> String? {
        if locale >= 0 && locale < catalog.messages.count,
           let local = catalog.messages[locale].get(keyIndex) {
            return local
        }
        return catalog.messages.first?.get(keyIndex)
    }

    private func pickPluralTemplate(_ key: String, category: PluralCategory) -> Template? {
        let currentForms = lookupCurrentPluralForms(key)
        let fallbackForms = lookupFallbackPluralForms(key)
        if let tmpl = currentForms?[category] ?? fallbackForms?[category] {
            return tmpl
        }
        if let tmpl = currentForms?[.other] ?? fallbackForms?[.other] {
            return tmpl
        }
        return currentForms?.values.first ?? fallbackForms?.values.first
    }

    private func lookupCurrentPluralForms(_ key: String) -> [PluralCategory: Template]? {
        if let cat = catalogs[currentLocale.tag], case .plural(let forms)? = cat.entries[key] {
            return forms
        }
        if let cat = catalogs[currentLocale.language], case .plural(let forms)? = cat.entries[key] {
            return forms
        }
        return nil
    }

    private func lookupFallbackPluralForms(_ key: String) -> [PluralCategory: Template]? {
        if let cat = catalogs[fallbackLocale.tag], case .plural(let forms)? = cat.entries[key] {
            return forms
        }
        if let cat = catalogs[fallbackLocale.language], case .plural(let forms)? = cat.entries[key] {
            return forms
        }
        return nil
    }

    private func lookupSingle(_ key: String) -> Template? {
        if let entry = lookup(key), case .single(let tmpl) = entry {
            return tmpl
        }
        return nil
    }

    private func lookup(_ key: String) -> CatalogEntry? {
        lookupWithLocale(key)?.1
    }

    private func lookupWithLocale(_ key: String) -> (LocaleInfo, CatalogEntry)? {
        if let cat = catalogs[currentLocale.tag], let e = cat.entries[key] {
            return (cat.locale, e)
        }
        if let cat = catalogs[currentLocale.language], let e = cat.entries[key] {
            return (cat.locale, e)
        }
        if let cat = catalogs[fallbackLocale.tag], let e = cat.entries[key] {
            return (cat.locale, e)
        }
        if let cat = catalogs[fallbackLocale.language], let e = cat.entries[key] {
            return (cat.locale, e)
        }
        return nil
    }
}

/// Strongly-typed message key (generated by `I18nCodegen` or constructed directly).
public struct I18nKey: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public let index: Int

    public init(rawValue: String) {
        self.rawValue = rawValue
        self.index = -1
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
        self.index = -1
    }

    public init(rawValue: String, index: Int) {
        self.rawValue = rawValue
        self.index = index
    }

    /// Resolves `name` in sorted `keys`, trapping if missing.
    public static func named(_ keys: [String], _ name: String) -> I18nKey {
        guard let idx = Catalog.find(keys, name: name) else {
            preconditionFailure("unknown i18n key: \(name)")
        }
        return I18nKey(rawValue: name, index: idx)
    }

    public static func == (lhs: I18nKey, rhs: I18nKey) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self.init(rawValue: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Strongly-typed plural base key (generated by `I18nCodegen` or constructed directly).
public struct I18nPluralKey: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public let index: Int

    public init(rawValue: String) {
        self.rawValue = rawValue
        self.index = -1
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
        self.index = -1
    }

    public init(rawValue: String, index: Int) {
        self.rawValue = rawValue
        self.index = index
    }

    /// Resolves `name` in sorted `plurals`, trapping if missing.
    public static func named(_ plurals: [String], _ name: String) -> I18nPluralKey {
        guard let idx = Catalog.find(plurals, name: name) else {
            preconditionFailure("unknown i18n plural key: \(name)")
        }
        return I18nPluralKey(rawValue: name, index: idx)
    }

    public static func == (lhs: I18nPluralKey, rhs: I18nPluralKey) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self.init(rawValue: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public typealias Key = I18nKey
public typealias PluralKey = I18nPluralKey
