import Foundation

/// A locale entry in `locales.json` for `I18nCodegen`.
public struct I18nManifestLocale: Sendable, Equatable, Codable {
    public var id: String
    public var tag: String
    public var label: String
    public var rtl: Bool

    public init(id: String, tag: String? = nil, label: String? = nil, rtl: Bool = false) {
        self.id = id
        self.tag = tag ?? id
        self.label = label ?? id
        self.rtl = rtl
    }
}

/// Top-level `locales.json` manifest for layered catalog code generation.
public struct I18nManifest: Sendable, Equatable, Codable {
    public var layers: [String]
    public var locales: [I18nManifestLocale]

    public init(layers: [String] = [], locales: [I18nManifestLocale]) {
        self.layers = layers
        self.locales = locales
    }
}

/// Validation diagnostic produced when checking catalog consistency across locales.
public struct I18nCodegenDiagnostic: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case placeholderMismatch
        case missingPluralOther
        case missingTranslation
    }

    public var kind: Kind
    public var locale: String
    public var key: String
    public var detail: String

    public init(kind: Kind, locale: String, key: String, detail: String) {
        self.kind = kind
        self.locale = locale
        self.key = key
        self.detail = detail
    }
}

/// Errors thrown by `I18nCodegen` on malformed manifests, catalogs, or strict validation failures.
public enum I18nCodegenError: Error, Sendable, Equatable, CustomStringConvertible {
    case fileReadFailed(path: String, reason: String)
    case invalidJSON(path: String, reason: String)
    case emptyLocales
    case invalidLocaleId(String)
    case validationFailed([I18nCodegenDiagnostic])

    public var description: String {
        switch self {
        case let .fileReadFailed(path, reason):
            return "Failed to read '\(path)': \(reason)"
        case let .invalidJSON(path, reason):
            return "Invalid JSON in '\(path)': \(reason)"
        case .emptyLocales:
            return "locales.json lists no locales"
        case let .invalidLocaleId(id):
            return "Locale entry '\(id)' needs an id of ASCII letters, digits, '-' or '_'"
        case let .validationFailed(diags):
            return "i18n validation failed with \(diags.count) diagnostic(s): " +
                diags.map { "[\($0.locale)] \($0.key): \($0.detail)" }.joined(separator: "; ")
        }
    }
}

/// Output of `I18nCodegen.compile(...)`.
public struct I18nCodegenResult: Sendable, Equatable {
    public var keys: [String]
    public var plurals: [String]
    public var locales: [I18nManifestLocale]
    public var messagesByLocale: [String: [String: String]]
    public var diagnostics: [I18nCodegenDiagnostic]
    public var swiftSource: String
}

/// Build-time / CLI catalog validator and Swift source code generator (ports `rune-i18n::codegen`).
public enum I18nCodegen {
    /// Reads `locales.json` and `<layer>/<id>.json` from `directory`, validates schemas and
    /// placeholders across locales, and writes deterministic Swift source code to `outputFile`.
    @discardableResult
    public static func generate(
        from directory: URL,
        to outputFile: URL,
        enumName: String = "I18nKeys",
        strict: Bool = false
    ) throws -> I18nCodegenResult {
        let result = try compile(from: directory, enumName: enumName, strict: strict)
        let parent = outputFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data(result.swiftSource.utf8).write(to: outputFile, options: .atomic)
        return result
    }

    /// Reads `locales.json` and `<layer>/<id>.json` from `directory` and returns the compiled result.
    public static func compile(
        from directory: URL,
        enumName: String = "I18nKeys",
        strict: Bool = false
    ) throws -> I18nCodegenResult {
        let manifestURL = directory.appendingPathComponent("locales.json")
        let manifestObj = try readJSONObject(at: manifestURL)
        let layers = (manifestObj["layers"] as? [Any])?.compactMap { $0 as? String } ?? []
        let locales = try parseLocales(manifestObj)

        var mergedByLocale: [String: [String: String]] = [:]
        for locale in locales {
            var merged: [String: String] = [:]
            if layers.isEmpty {
                let directURL = directory.appendingPathComponent("\(locale.id).json")
                if FileManager.default.fileExists(atPath: directURL.path) {
                    let obj = try readJSONObject(at: directURL)
                    flattenMessages(obj, prefix: "", into: &merged)
                }
            } else {
                for layer in layers {
                    let path = directory
                        .appendingPathComponent(layer)
                        .appendingPathComponent("\(locale.id).json")
                    guard FileManager.default.fileExists(atPath: path.path) else { continue }
                    let obj = try readJSONObject(at: path)
                    flattenMessages(obj, prefix: "", into: &merged)
                }
            }
            mergedByLocale[locale.id] = merged
        }

        let manifest = I18nManifest(layers: layers, locales: locales)
        return try compile(manifest: manifest, messagesByLocale: mergedByLocale, enumName: enumName, strict: strict)
    }

    /// Validates an in-memory manifest and per-locale flat message maps, and generates Swift source.
    public static func compile(
        manifest: I18nManifest,
        messagesByLocale: [String: [String: String]],
        enumName: String = "I18nKeys",
        strict: Bool = false
    ) throws -> I18nCodegenResult {
        guard !manifest.locales.isEmpty else {
            throw I18nCodegenError.emptyLocales
        }
        for locale in manifest.locales {
            guard isValidLocaleId(locale.id) else {
                throw I18nCodegenError.invalidLocaleId(locale.id)
            }
        }

        let sourceLocale = manifest.locales[0]
        let sourceMessages = messagesByLocale[sourceLocale.id] ?? [:]

        // A base whose source has `base.one` and `base.other` is a plural.
        let plurals: [String] = sourceMessages.keys
            .compactMap { key -> String? in
                guard key.hasSuffix(".other") else { return nil }
                return String(key.dropLast(".other".count))
            }
            .filter { sourceMessages["\($0).one"] != nil }
            .sorted()

        let pluralSet = Set(plurals)
        let pluralSuffixes = Set(PluralCategory.allCases.map(\.rawValue))

        var keySet = Set(sourceMessages.keys)
        for locale in manifest.locales {
            let map = messagesByLocale[locale.id] ?? [:]
            for key in map.keys {
                if let dot = key.lastIndex(of: ".") {
                    let base = String(key[..<dot])
                    let category = String(key[key.index(after: dot)...])
                    if pluralSet.contains(base) && pluralSuffixes.contains(category) {
                        keySet.insert(key)
                    }
                }
            }
        }
        let keys = keySet.sorted()

        let diagnostics = validateConsistency(
            locales: manifest.locales,
            keys: keys,
            plurals: plurals,
            messagesByLocale: messagesByLocale
        )

        if strict {
            let hardErrors = diagnostics.filter { $0.kind != .missingTranslation }
            if !hardErrors.isEmpty {
                throw I18nCodegenError.validationFailed(hardErrors)
            }
        }

        let swiftSource = generateSwiftSource(
            enumName: enumName,
            keys: keys,
            plurals: plurals,
            locales: manifest.locales,
            messagesByLocale: messagesByLocale
        )

        return I18nCodegenResult(
            keys: keys,
            plurals: plurals,
            locales: manifest.locales,
            messagesByLocale: messagesByLocale,
            diagnostics: diagnostics,
            swiftSource: swiftSource
        )
    }

    /// Validates placeholder names and plural `.other` presence across all locales against the source locale.
    public static func validateConsistency(
        locales: [I18nManifestLocale],
        keys: [String],
        plurals: [String],
        messagesByLocale: [String: [String: String]]
    ) -> [I18nCodegenDiagnostic] {
        guard let sourceLocale = locales.first else { return [] }
        let sourceMap = messagesByLocale[sourceLocale.id] ?? [:]
        var diagnostics: [I18nCodegenDiagnostic] = []

        func placeholderSet(_ template: String) -> Set<String> {
            Set(Template.parts(template).compactMap { part in
                if case let .arg(name) = part { return name }
                return nil
            })
        }

        let sourcePlaceholders: [String: Set<String>] = sourceMap.mapValues { placeholderSet($0) }

        for locale in locales.dropFirst() {
            let map = messagesByLocale[locale.id] ?? [:]
            for key in keys {
                guard let localized = map[key] else {
                    if sourceMap[key] != nil {
                        diagnostics.append(I18nCodegenDiagnostic(
                            kind: .missingTranslation,
                            locale: locale.id,
                            key: key,
                            detail: "missing translation (falls back to '\(sourceLocale.id)')"
                        ))
                    }
                    continue
                }
                if let expected = sourcePlaceholders[key] {
                    let actual = placeholderSet(localized)
                    if actual != expected {
                        diagnostics.append(I18nCodegenDiagnostic(
                            kind: .placeholderMismatch,
                            locale: locale.id,
                            key: key,
                            detail: "placeholders \(actual.sorted()) do not match source \(expected.sorted())"
                        ))
                    }
                }
            }
            for base in plurals {
                let hasAnyForm = PluralCategory.allCases.contains { map["\(base).\($0.rawValue)"] != nil }
                if hasAnyForm && map["\(base).other"] == nil {
                    diagnostics.append(I18nCodegenDiagnostic(
                        kind: .missingPluralOther,
                        locale: locale.id,
                        key: base,
                        detail: "locale defines plural forms for '\(base)' without '\(base).other'"
                    ))
                }
            }
        }
        return diagnostics
    }

    private static func generateSwiftSource(
        enumName: String,
        keys: [String],
        plurals: [String],
        locales: [I18nManifestLocale],
        messagesByLocale: [String: [String: String]]
    ) -> String {
        let sourceLocale = locales[0]
        let sourceMap = messagesByLocale[sourceLocale.id] ?? [:]
        let pluralSet = Set(plurals)

        var lines: [String] = []
        lines.append("// Generated by RuneI18n.I18nCodegen. Do not edit.")
        lines.append("import RuneI18n")
        lines.append("")
        lines.append("public enum \(enumName): Sendable {")

        var usedKeyNames: Set<String> = []
        for key in keys {
            let ident = swiftIdentifier(for: key, used: &usedKeyNames)
            lines.append("    public static let \(ident) = I18nKey(\(swiftStringLiteral(key)))")
        }

        if !plurals.isEmpty {
            lines.append("")
            lines.append("    public enum Plurals: Sendable {")
            var usedPluralNames: Set<String> = []
            for base in plurals {
                let ident = swiftIdentifier(for: base, used: &usedPluralNames)
                lines.append("        public static let \(ident) = I18nPluralKey(\(swiftStringLiteral(base)))")
            }
            lines.append("    }")
        }

        lines.append("")
        lines.append("    public static let allKeys: [String] = [")
        for key in keys {
            lines.append("        \(swiftStringLiteral(key)),")
        }
        lines.append("    ]")

        lines.append("")
        lines.append("    public static let allPlurals: [String] = [")
        for base in plurals {
            lines.append("        \(swiftStringLiteral(base)),")
        }
        lines.append("    ]")

        lines.append("")
        lines.append("    public static func makeCatalogs() -> [Catalog] {")
        lines.append("        [")
        for locale in locales {
            let map = messagesByLocale[locale.id] ?? [:]
            let isolateRTL = locale.rtl && !sourceLocale.rtl
            lines.append("            Catalog(locale: LocaleInfo(\(swiftStringLiteral(locale.tag))), entries: [")

            // Emit single keys (excluding plural category keys belonging to `plurals`)
            for key in keys {
                if let dot = key.lastIndex(of: "."),
                   pluralSet.contains(String(key[..<dot])),
                   PluralCategory(rawValue: String(key[key.index(after: dot)...])) != nil {
                    continue
                }
                if let msg = map[key] {
                    lines.append("                \(swiftStringLiteral(key)): .single(Template(\(swiftStringLiteral(msg)))),")
                } else if isolateRTL, let srcMsg = sourceMap[key] {
                    // Wrap untranslated LTR fallback in LRI..PDI for RTL locales.
                    let isolated = "\u{2066}\(srcMsg)\u{2069}"
                    lines.append("                \(swiftStringLiteral(key)): .single(Template(\(swiftStringLiteral(isolated)))),")
                }
            }

            // Emit plural entries
            for base in plurals {
                var formPairs: [(PluralCategory, String)] = []
                for cat in PluralCategory.allCases {
                    if let msg = map["\(base).\(cat.rawValue)"] {
                        formPairs.append((cat, msg))
                    }
                }
                if !formPairs.isEmpty {
                    let rendered = formPairs
                        .map { ".\($0.0.rawValue): Template(\(swiftStringLiteral($0.1)))" }
                        .joined(separator: ", ")
                    lines.append("                \(swiftStringLiteral(base)): .plural([\(rendered)]),")
                }
            }

            lines.append("            ]),")
        }
        lines.append("        ]")
        lines.append("    }")

        lines.append("")
        lines.append("    public static func makeI18n(locale: String = \(swiftStringLiteral(sourceLocale.tag))) -> I18n {")
        lines.append("        I18n(locale: locale, fallback: \(swiftStringLiteral(sourceLocale.tag)), catalogs: makeCatalogs())")
        lines.append("    }")
        lines.append("}")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func readJSONObject(at url: URL) throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw I18nCodegenError.fileReadFailed(path: url.path, reason: error.localizedDescription)
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw I18nCodegenError.invalidJSON(path: url.path, reason: error.localizedDescription)
        }
        guard let dict = parsed as? [String: Any] else {
            throw I18nCodegenError.invalidJSON(path: url.path, reason: "root value is not a JSON object")
        }
        return dict
    }

    private static func parseLocales(_ manifest: [String: Any]) throws -> [I18nManifestLocale] {
        guard let list = manifest["locales"] as? [[String: Any]], !list.isEmpty else {
            throw I18nCodegenError.emptyLocales
        }
        return try list.map { entry in
            guard let id = entry["id"] as? String, isValidLocaleId(id) else {
                throw I18nCodegenError.invalidLocaleId((entry["id"] as? String) ?? "<missing>")
            }
            let tag = (entry["tag"] as? String) ?? id
            let label = (entry["label"] as? String) ?? id
            let rtl = (entry["rtl"] as? Bool) ?? false
            return I18nManifestLocale(id: id, tag: tag, label: label, rtl: rtl)
        }
    }

    private static func isValidLocaleId(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39) || // 0-9
            (scalar.value >= 0x41 && scalar.value <= 0x5A) || // A-Z
            (scalar.value >= 0x61 && scalar.value <= 0x7A) || // a-z
            scalar.value == 0x2D || // -
            scalar.value == 0x5F    // _
        }
    }

    private static func flattenMessages(_ dict: [String: Any], prefix: String, into out: inout [String: String]) {
        for key in dict.keys.sorted() {
            let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let str = dict[key] as? String {
                out[fullKey] = str
            } else if let sub = dict[key] as? [String: Any] {
                flattenMessages(sub, prefix: fullKey, into: &out)
            }
        }
    }

    private static func swiftIdentifier(for key: String, used: inout Set<String>) -> String {
        let parts = key
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
        var base: String
        if let first = parts.first {
            base = first.prefix(1).lowercased() + first.dropFirst()
            for part in parts.dropFirst() {
                base += part.prefix(1).uppercased() + part.dropFirst()
            }
        } else {
            base = "key"
        }
        if let firstChar = base.first, firstChar.isNumber {
            base = "_" + base
        }
        let reserved: Set<String> = [
            "class", "struct", "enum", "protocol", "func", "var", "let", "import",
            "default", "case", "switch", "if", "else", "for", "while", "return",
            "public", "private", "internal", "static", "self", "Self", "true", "false", "nil"
        ]
        if reserved.contains(base) {
            base = "`\(base)`"
        }
        var candidate = base
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(base)_\(suffix)"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }

    private static func swiftStringLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00..<0x20, 0x2066, 0x2069:
                out += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }
}
