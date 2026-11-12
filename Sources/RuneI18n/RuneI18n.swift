import Foundation

/// Parsed BCP-47 locale tag (`language[-script][-region]`).
public struct LocaleInfo: Sendable, Hashable, Codable, CustomStringConvertible {
    public var language: String
    public var script: String?
    public var region: String?

    public init(language: String, script: String? = nil, region: String? = nil) {
        self.language = language.lowercased()
        self.script = script?.capitalized
        self.region = region?.uppercased()
    }

    public init(_ tag: String) {
        let normalized = tag.replacingOccurrences(of: "_", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = normalized.split(separator: "-").map(String.init)
        guard let first = parts.first, !first.isEmpty else {
            self.init(language: "en")
            return
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
        self.init(language: lang, script: script, region: region)
    }

    public var tag: String {
        var out = language
        if let script { out += "-\(script)" }
        if let region { out += "-\(region)" }
        return out
    }

    public var isRTL: Bool {
        switch language {
        case "ar", "he", "iw", "fa", "ur", "yi", "ps", "dv":
            return true
        default:
            return script == "Arab" || script == "Hebr"
        }
    }

    public var description: String { tag }
}

/// Negotiates the best supported locale from user preferences with fallback.
public func negotiateLocale(
    requested: [String],
    available: [String],
    default fallback: String = "en"
) -> String {
    let parsedAvail = available.map { ($0, LocaleInfo($0)) }
    for reqRaw in requested {
        let req = LocaleInfo(reqRaw)
        // 1. Exact tag match
        if let exact = parsedAvail.first(where: { $0.1 == req }) {
            return exact.0
        }
        // 2. Language + script match (including region->script inference)
        let inferredScript = req.script ?? inferScript(for: req)
        if let s = inferredScript,
           let scriptMatch = parsedAvail.first(where: { languagesMatch($0.1.language, req.language) && ($0.1.script ?? inferScript(for: $0.1)) == s }) {
            return scriptMatch.0
        }
        // 3. Language + region match
        if let r = req.region,
           let regionMatch = parsedAvail.first(where: { languagesMatch($0.1.language, req.language) && $0.1.region == r }) {
            return regionMatch.0
        }
        // 4. Base language match (including Norwegian no/nb/nn equivalence, rejecting script conflicts)
        if let langMatch = parsedAvail.first(where: {
            guard languagesMatch($0.1.language, req.language) else { return false }
            let availScript = $0.1.script ?? inferScript(for: $0.1)
            if let reqScript = inferredScript, let availScript, reqScript != availScript {
                return false
            }
            return true
        }) {
            return langMatch.0
        }
    }
    return fallback
}

private func languagesMatch(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    let norwegian: Set<String> = ["no", "nb", "nn"]
    return norwegian.contains(a) && norwegian.contains(b)
}

private func inferScript(for locale: LocaleInfo) -> String? {
    switch locale.language {
    case "zh", "yue":
        switch locale.region {
        case "TW", "HK", "MO":
            return "Hant"
        case "CN", "SG", "MY":
            return "Hans"
        default:
            return nil
        }
    case "pa":
        switch locale.region {
        case "PK":
            return "Arab"
        case "IN":
            return "Guru"
        default:
            return nil
        }
    case "sr":
        switch locale.region {
        case "RS", "ME", "BA":
            return "Cyrl"
        case "XK":
            return "Latn"
        default:
            return nil
        }
    case "uz":
        switch locale.region {
        case "AF":
            return "Arab"
        case "UZ":
            return "Latn"
        default:
            return nil
        }
    case "az":
        switch locale.region {
        case "IR":
            return "Arab"
        case "AZ":
            return "Latn"
        default:
            return nil
        }
    default:
        return nil
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
        case "ja", "zh", "ko", "vi", "th", "id", "ms", "tr":
            return .other

        case "fr", "pt", "hi", "fa":
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
            return .other

        default:
            // Germanic / Romance / Greek / Finno-Ugric standard (en, de, es, it, nl, sv, da, no, fi, ...)
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
        var remainder = source[...]
        while let openRange = remainder.range(of: "{{") {
            let prefix = remainder[..<openRange.lowerBound]
            if !prefix.isEmpty {
                out.append(.literal(String(prefix)))
            }
            let afterOpen = remainder[openRange.upperBound...]
            if let closeRange = afterOpen.range(of: "}}") {
                let rawVar = afterOpen[..<closeRange.lowerBound].trimmingCharacters(in: .whitespaces)
                if !rawVar.isEmpty {
                    out.append(.variable(rawVar))
                } else {
                    out.append(.literal("{{}}"))
                }
                remainder = afterOpen[closeRange.upperBound...]
            } else {
                out.append(.literal(String(remainder[openRange.lowerBound...])))
                remainder = remainder[remainder.endIndex...]
            }
        }
        if !remainder.isEmpty {
            out.append(.literal(String(remainder)))
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
                result += args[name] ?? "{{\(name)}}"
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

/// Translation catalog for a single locale.
public struct Catalog: Sendable, Equatable {
    public var locale: LocaleInfo
    public var entries: [String: CatalogEntry]

    public init(locale: LocaleInfo, entries: [String: CatalogEntry] = [:]) {
        self.locale = locale
        self.entries = entries
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
    private var catalogs: [String: Catalog]

    public init(
        locale: String = "en",
        fallback: String = "en",
        catalogs: [Catalog] = []
    ) {
        self.currentLocale = LocaleInfo(locale)
        self.fallbackLocale = LocaleInfo(fallback)
        var map: [String: Catalog] = [:]
        for cat in catalogs {
            map[cat.locale.tag] = cat
        }
        self.catalogs = map
    }

    public mutating func insert(_ catalog: Catalog) {
        catalogs[catalog.locale.tag] = catalog
    }

    public mutating func setLocale(_ tag: String) {
        let best = negotiateLocale(
            requested: [tag],
            available: Array(catalogs.keys),
            default: fallbackLocale.tag
        )
        currentLocale = LocaleInfo(best)
    }

    public var isRTL: Bool { currentLocale.isRTL }

    /// All catalog locale tags registered in this bundle.
    public var availableLocales: [String] {
        Array(catalogs.keys).sorted()
    }

    /// Returns whether `key` exists in either the current or fallback locale chain.
    public func hasKey(_ key: String) -> Bool {
        lookup(key) != nil
    }

    /// Negotiates the best supported locale from `preferred` without mutating `currentLocale`.
    public func negotiate(_ preferred: [String]) -> String {
        negotiateLocale(requested: preferred, available: Array(catalogs.keys), default: fallbackLocale.tag)
    }

    /// Formats `n` with the current locale's digits and grouping (`1,234`, `1.234`).
    public func integer(_ n: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: currentLocale.tag)
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// Formats `n` rounded half away from zero to at most `maxFraction` fraction digits.
    public func decimal(_ n: Double, maxFraction: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: currentLocale.tag)
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = max(0, maxFraction)
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
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
        t(key.rawValue)
    }

    /// Strongly-typed template formatting using a generated `I18nKey`.
    public func format(_ key: I18nKey, args: [String: String] = [:]) -> String {
        t(key.rawValue, args: args)
    }

    /// Strongly-typed plural formatting using a generated `I18nPluralKey`.
    public func plural(_ key: I18nPluralKey, count: Int, args: [String: String] = [:]) -> String {
        plural(key.rawValue, count: count, args: args)
    }

    /// Looks up and formats `key` with optional named `args`.
    public func t(_ key: String, args: [String: String] = [:]) -> String {
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
        guard let (locale, entry) = lookupWithLocale(key) else {
            return key
        }
        switch entry {
        case .single(let tmpl):
            return tmpl.render(merged)
        case .plural(let forms):
            let cat = PluralCategory.select(count: count, locale: locale)
            if let tmpl = forms[cat] ?? forms[.other] {
                return tmpl.render(merged)
            }
            if let fallbackForms = lookupFallbackPluralForms(key),
               let tmpl = fallbackForms[cat] ?? fallbackForms[.other] ?? fallbackForms.values.first {
                return tmpl.render(merged)
            }
            return forms.values.first?.render(merged) ?? key
        }
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

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Strongly-typed plural base key (generated by `I18nCodegen` or constructed directly).
public struct I18nPluralKey: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public typealias Key = I18nKey
public typealias PluralKey = I18nPluralKey
