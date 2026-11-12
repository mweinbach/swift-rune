import Foundation
import Testing
@testable import RuneI18n

@Suite("RuneI18n Tests")
struct RuneI18nTests {
    @Test("Locale parsing, RTL detection, and script-aware negotiation")
    func localeNegotiationAndRTL() {
        let zhTW = LocaleInfo("zh_TW")
        #expect(zhTW.tag == "zh-TW")
        #expect(!zhTW.isRTL)
        #expect(LocaleInfo("ar-EG").isRTL)
        #expect(LocaleInfo("he").isRTL)
        #expect(LocaleInfo("en-Arab").isRTL)

        let negotiated = negotiateLocale(
            requested: ["zh-HK", "fr-CA"],
            available: ["en", "zh-Hans", "zh-Hant", "fr"],
            default: "en"
        )
        #expect(negotiated == "zh-Hant")

        let fallback = negotiateLocale(
            requested: ["ko-KR"],
            available: ["en", "de"],
            default: "en"
        )
        #expect(fallback == "en")
    }

    @Test("CLDR cardinal plural categories across English, Russian, Arabic, French, Japanese")
    func cldrPluralRules() {
        let en = LocaleInfo("en")
        #expect(PluralCategory.select(count: 0, locale: en) == .other)
        #expect(PluralCategory.select(count: 1, locale: en) == .one)
        #expect(PluralCategory.select(count: 2, locale: en) == .other)

        let fr = LocaleInfo("fr")
        #expect(PluralCategory.select(count: 0, locale: fr) == .one)
        #expect(PluralCategory.select(count: 1, locale: fr) == .one)
        #expect(PluralCategory.select(count: 2, locale: fr) == .other)

        let ru = LocaleInfo("ru")
        #expect(PluralCategory.select(count: 1, locale: ru) == .one)
        #expect(PluralCategory.select(count: 21, locale: ru) == .one)
        #expect(PluralCategory.select(count: 11, locale: ru) == .many)
        #expect(PluralCategory.select(count: 3, locale: ru) == .few)
        #expect(PluralCategory.select(count: 14, locale: ru) == .many)

        let ar = LocaleInfo("ar")
        #expect(PluralCategory.select(count: 0, locale: ar) == .zero)
        #expect(PluralCategory.select(count: 1, locale: ar) == .one)
        #expect(PluralCategory.select(count: 2, locale: ar) == .two)
        #expect(PluralCategory.select(count: 5, locale: ar) == .few)
        #expect(PluralCategory.select(count: 42, locale: ar) == .many)
        #expect(PluralCategory.select(count: 100, locale: ar) == .other)

        #expect(PluralCategory.select(count: 1, locale: LocaleInfo("ja")) == .other)
    }

    @Test("JSON Catalog nested keys, plural forms, and Template variable edge cases")
    func catalogAndTemplates() throws {
        let json = """
        {
          "app": {
            "greeting": "Hello, {{ user }}!",
            "tasks": {
              "one": "{{count}} task remaining",
              "other": "{{count}} tasks remaining"
            }
          }
        }
        """
        let enCat = try Catalog.fromJSON(locale: "en", data: Data(json.utf8))
        var i18n = I18n(locale: "en", fallback: "en", catalogs: [enCat])

        #expect(i18n.t("app.greeting", args: ["user": "Ada"]) == "Hello, Ada!")
        // Upstream template.rs:36-40 leaves missing args empty.
        #expect(i18n.t("app.greeting") == "Hello, !")
        #expect(i18n.plural("app.tasks", count: 1) == "1 task remaining")
        #expect(i18n.plural("app.tasks", count: 5) == "5 tasks remaining")

        // Unclosed braces in template degrade gracefully to literal text
        let broken = Template("Unclosed {{var")
        #expect(broken.render(["var": "x"]) == "Unclosed {{var")

        i18n.setLocale("es-MX")
        #expect(i18n.t("app.greeting", args: ["user": "Rune"]) == "Hello, Rune!")
        #expect(i18n.hasKey("app.greeting"))
        #expect(!i18n.hasKey("app.nonexistent"))
        #expect(i18n.availableLocales == ["en"])
    }

    @Test("Upstream locale extension tags, Norwegian equivalence, and Punjabi script negotiation")
    func upstreamLocaleTests() {
        // BCP-47 extension subtags (-u-...) must not be misparsed as region codes
        let deExt = LocaleInfo("de-u-co-phonebk")
        #expect(deExt.language == "de")
        #expect(deExt.region == nil)

        #expect(
            negotiateLocale(
                requested: ["zh-TW-u-nu-hanidec", "en"],
                available: ["en", "zh-Hans", "zh-Hant"]
            ) == "zh-Hant"
        )
        #expect(
            negotiateLocale(
                requested: ["de-AT"],
                available: ["en", "de-DE-u-co-phonebk"]
            ) == "de-DE-u-co-phonebk"
        )
        // Norwegian no / nb / nn equivalence
        #expect(negotiateLocale(requested: ["nb-NO"], available: ["en", "no"]) == "no")
        #expect(negotiateLocale(requested: ["nn"], available: ["en", "nb"]) == "nb")
        // Punjabi script inference: pa-PK -> Arab, pa-IN -> Guru
        #expect(
            negotiateLocale(
                requested: ["pa-PK"],
                available: ["en", "pa-IN", "pa-Arab-PK"]
            ) == "pa-Arab-PK"
        )
        #expect(
            negotiateLocale(
                requested: ["pa-PK"],
                available: ["en", "pa-IN"],
                default: "en"
            ) == "en"
        )
    }

    @Test("POSIX & system language detection, Template parts, and locale number/list formatting")
    func systemLanguagesFormattingAndParts() {
        let env: [String: String] = [
            "LANGUAGE": "de_AT.UTF-8@euro:fr_CA:C:POSIX:de_AT",
            "LC_ALL": "C",
            "LC_MESSAGES": "es_MX.UTF-8",
            "LANG": "en_US.UTF-8",
        ]
        #expect(posixLanguages { env[$0] } == ["de-AT", "fr-CA", "es-MX", "en-US"])
        #expect(!systemLanguages().isEmpty)

        let parts = Template.parts("Press {{ key }} to {{ action }}!")
        #expect(parts == [
            .text("Press "),
            .arg("key"),
            .text(" to "),
            .arg("action"),
            .text("!"),
        ])

        let en = I18n(locale: "en-US", fallback: "en-US")
        #expect(en.integer(1234567) == "1,234,567")
        #expect(en.decimal(12.345, maxFraction: 2) == "12.35")
        #expect(en.decimal(12.500, maxFraction: 2) == "12.5")
        #expect(en.list(["a", "b", "c"]) == "a, b, and c")

        let de = I18n(locale: "de-DE", fallback: "en-US")
        #expect(de.integer(1234) == "1.234")
        #expect(de.decimal(1.5, maxFraction: 2) == "1,5")
        #expect(de.list(["a", "b", "c"]) == "a, b und c")

        // Additional CLDR plural rules: Polish, Czech, Hebrew
        let pl = LocaleInfo("pl")
        #expect(PluralCategory.select(count: 1, locale: pl) == .one)
        #expect(PluralCategory.select(count: 2, locale: pl) == .few)
        #expect(PluralCategory.select(count: 5, locale: pl) == .many)
        #expect(PluralCategory.select(count: 22, locale: pl) == .few)

        let cs = LocaleInfo("cs")
        #expect(PluralCategory.select(count: 1, locale: cs) == .one)
        #expect(PluralCategory.select(count: 3, locale: cs) == .few)
        #expect(PluralCategory.select(count: 5, locale: cs) == .other)

        let he = LocaleInfo("he")
        #expect(PluralCategory.select(count: 1, locale: he) == .one)
        #expect(PluralCategory.select(count: 2, locale: he) == .two)
        #expect(PluralCategory.select(count: 5, locale: he) == .other)
    }

    @Test("Compact number formatting and pluralCategory helper")
    func compactNumberFormatting() {
        let en = I18n(locale: "en-US", fallback: "en-US")
        #expect(en.compact(950) == "950")
        #expect(en.compact(1_200) == "1.2K")
        #expect(en.compact(3_400_000) == "3.4M")
        #expect(en.compact(5_600_000_000) == "5.6B")
        #expect(en.compact(-1_500.0) == "-1.5K")
        #expect(en.pluralCategory(for: 1) == .one)
        #expect(en.pluralCategory(for: 2) == .other)

        let de = I18n(locale: "de-DE", fallback: "en-US")
        #expect(de.compact(1_200) == "1,2K")
        #expect(de.compact(3_400_000) == "3,4M")
    }

    @Test("I18nCodegen layered JSON loading, schema validation, RTL isolation, and Swift generation")
    func codegenLayeredCatalogsAndValidation() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("rune-i18n-codegen-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }

        let upstream = tmp.appendingPathComponent("upstream")
        let app = tmp.appendingPathComponent("app")
        try fm.createDirectory(at: upstream, withIntermediateDirectories: true)
        try fm.createDirectory(at: app, withIntermediateDirectories: true)

        let localesJSON = """
        {
          "layers": ["upstream", "app"],
          "locales": [
            { "id": "en", "tag": "en", "label": "English" },
            { "id": "ar", "tag": "ar", "label": "العربية", "rtl": true }
          ]
        }
        """
        try Data(localesJSON.utf8).write(to: tmp.appendingPathComponent("locales.json"))

        let enUpstream = """
        {
          "greeting": "Hello {{name}}",
          "files.one": "{{count}} file",
          "files.other": "{{count}} files",
          "only_en": "English only."
        }
        """
        let enApp = """
        {
          "greeting": "Welcome {{name}}"
        }
        """
        let arUpstream = """
        {
          "greeting": "مرحبا {{name}}",
          "files.one": "ملف واحد",
          "files.other": "{{count}} ملفات"
        }
        """
        try Data(enUpstream.utf8).write(to: upstream.appendingPathComponent("en.json"))
        try Data(enApp.utf8).write(to: app.appendingPathComponent("en.json"))
        try Data(arUpstream.utf8).write(to: upstream.appendingPathComponent("ar.json"))

        let outFile = tmp.appendingPathComponent("Generated/I18nKeys.swift")
        let result = try I18nCodegen.generate(from: tmp, to: outFile, enumName: "AppStrings")

        #expect(result.plurals == ["files"])
        #expect(result.messagesByLocale["en"]?["greeting"] == "Welcome {{name}}")
        #expect(result.diagnostics.contains { $0.kind == .missingTranslation && $0.locale == "ar" && $0.key == "only_en" })
        #expect(result.swiftSource.contains("public static let greeting = I18nKey(\"greeting\")"))
        #expect(result.swiftSource.contains("public static let files = I18nPluralKey(\"files\")"))
        #expect(result.swiftSource.contains("\\u{2066}English only.\\u{2069}"))
        #expect(fm.fileExists(atPath: outFile.path))

        // Placeholder mismatch fails strict compilation
        let badManifest = I18nManifest(locales: [
            I18nManifestLocale(id: "en"),
            I18nManifestLocale(id: "fr"),
        ])
        #expect(throws: I18nCodegenError.self) {
            try I18nCodegen.compile(
                manifest: badManifest,
                messagesByLocale: [
                    "en": ["hi": "Hello {{name}}"],
                    "fr": ["hi": "Bonjour {{user}}"],
                ],
                strict: true
            )
        }
    }

    @Test("Parity #817: RTL plural isolation and category fallback order before other")
    func rtlPluralIsolationAndFallbackOrder() throws {
        // Dictionary-mode plural fallback order: ar has only .other, en has .one & .other
        let enCat = Catalog(
            locale: LocaleInfo("en"),
            entries: [
                "files": .plural([
                    .one: Template("{{count}} file"),
                    .other: Template("{{count}} files"),
                ]),
            ]
        )
        let arCat = Catalog(
            locale: LocaleInfo("ar"),
            entries: [
                "files": .plural([
                    .other: Template("{{count}} ملفات"),
                ]),
            ]
        )
        let i18n = I18n(locale: "ar", fallback: "en", catalogs: [enCat, arCat])
        // For count == 1 (.one), ar lacks .one -> must check source[.one] BEFORE ar[.other]
        #expect(i18n.plural("files", count: 1) == "1 file")
        // For count == 2 (.two), neither has .two -> falls back to ar[.other]
        #expect(i18n.plural("files", count: 2) == "2 ملفات")

        // Codegen-mode RTL plural isolation (#817)
        let manifest = I18nManifest(locales: [
            I18nManifestLocale(id: "en", tag: "en", label: "English", rtl: false),
            I18nManifestLocale(id: "ar", tag: "ar", label: "العربية", rtl: true),
        ])
        let compiled = try I18nCodegen.compile(
            manifest: manifest,
            messagesByLocale: [
                "en": ["files.one": "{{count}} file", "files.other": "{{count}} files"],
                "ar": ["files.other": "{{count}} ملفات"],
            ]
        )
        #expect(compiled.swiftSource.contains("id: \"ar\", tag: \"ar\", label: \"العربية\", rtl: true"))
        #expect(compiled.swiftSource.contains("\\u{2066}{{count}} file\\u{2069}"))
    }

    @Test("Parity #821: Runtime blob Catalog, Messages.later, and Catalog.loadJSON")
    func runtimeBlobCatalogAndLoadJSON() throws {
        let keys = ["files.one", "files.other", "greeting", "missing"]
        let plurals = ["files"]
        let pluralForms: [[UInt32]] = [[UInt32.max, 0, UInt32.max, UInt32.max, UInt32.max, 1]]
        let (enText, enSpans) = Catalog.blob(keys: keys, message: { key in
            switch key {
            case "files.one": return "{{count}} file"
            case "files.other": return "{{count}} files"
            case "greeting": return "Hello, {{name}}!"
            default: return nil
            }
        })
        let locales = [
            LocaleInfo(id: "en", tag: "en", label: "English", rtl: false),
            LocaleInfo(id: "ar", tag: "ar", label: "العربية", rtl: true),
        ]
        let catalog = Catalog(
            keys: keys,
            plurals: plurals,
            pluralForms: pluralForms,
            locales: locales,
            messages: [Messages(text: enText, spans: enSpans), .later()]
        )
        #expect(catalog.present(0))
        #expect(!catalog.present(1))
        #expect(!catalog.present(9))

        var i18n = I18n(catalog: catalog)
        let kGreeting = I18nKey.named(catalog.keys, "greeting")
        let pFiles = I18nPluralKey.named(catalog.plurals, "files")
        #expect(i18n.localeIndex == 0)
        #expect(i18n.findLocale("ar") == 1)
        #expect(i18n.info().label == "English")
        #expect(i18n.text(kGreeting) == "Hello, {{name}}!")
        let changedToAr = i18n.setLocale(1)
        #expect(changedToAr)
        let changedSame = i18n.setLocale(1)
        #expect(!changedSame)
        let changedOOB = i18n.setLocale(99)
        #expect(!changedOOB)
        // Unloaded locale 1 falls back to source locale 0
        #expect(i18n.text(kGreeting) == "Hello, {{name}}!")

        #expect(throws: I18nError.unknownLocale(5)) {
            try catalog.loadJSON(locale: 5, json: "{}")
        }
        #expect(throws: I18nError.invalidJSON("not a JSON object")) {
            try catalog.loadJSON(locale: 1, json: "[1, 2, 3]")
        }

        // Load ar with partial keys (greeting + files.other only, plus an unknown extra key)
        try catalog.loadJSON(locale: 1, json: """
        {
          "greeting": "مرحبا {{name}}",
          "files.other": "{{count}} ملفات",
          "unknown.extra": "ignored"
        }
        """)
        #expect(catalog.present(1))
        #expect(i18n.format(kGreeting, args: ["name": "Ada"]) == "مرحبا Ada")
        #expect(i18n.textIn(0, kGreeting) == "Hello, {{name}}!")
        // #817 + #821: missing plural form files.one in RTL gets LRI..PDI isolated source string
        #expect(i18n.pluralFormat(pFiles, count: 1) == "\u{2066}1 file\u{2069}")
        #expect(i18n.pluralFormat(pFiles, count: 2) == "2 ملفات")
        #expect(i18n.pluralRaw(pFiles, count: 5) == "{{count}} ملفات")
        #expect(i18n.pluralForm(pFiles, category: .one) == "\u{2066}{{count}} file\u{2069}")

        // Already-present locale is a no-op
        try catalog.loadJSON(locale: 1, json: "{\"greeting\": \"changed\"}")
        #expect(i18n.text(kGreeting) == "مرحبا {{name}}")
    }

    @Test("Parity P1: Template edge cases, likely-subtag negotiation, CLDR plurals, and Decimal rounding")
    func templateNegotiationPluralsAndDecimal() {
        // Template {{a}b}}, empty {{}}, {{ }}
        #expect(Template("{{a}b}}").parts == [.text("{{a}b}}")])
        #expect(Template("{{a}b}}").render(["a": "x"]) == "{{a}b}}")
        #expect(Template("x {{}} y {{ }} z").parts == [.text("x {{}} y "), .arg(""), .text(" z")])
        #expect(Template("x {{}} y {{ }} z").render([:]) == "x {{}} y  z")
        #expect(Template("x {{}} y {{ }} z").render(["": "V"]) == "x {{}} y V z")
        #expect(Template("hi {{missing}}!").render([:]) == "hi !")

        // ICU-parity negotiation order and likely subtags
        #expect(negotiate(["en-GB"], supported: ["en-US", "en-GB"]) == 0)
        #expect(negotiate(["zh"], supported: ["en", "zh-Hans", "zh-Hant"]) == 1)
        #expect(negotiate(["sr"], supported: ["en", "sr-Latn", "sr-Cyrl"]) == 2)
        #expect(negotiate(["sr-ME"], supported: ["en", "sr-Latn", "sr-Cyrl"]) == 1)

        // CLDR plural rules coverage
        #expect(PluralCategory.select(count: 1, locale: LocaleInfo("tr")) == .one)
        #expect(PluralCategory.select(count: 0, locale: LocaleInfo("tr")) == .other)
        #expect(PluralCategory.select(count: 2, locale: LocaleInfo("tr")) == .other)
        #expect(PluralCategory.select(count: 0, locale: LocaleInfo("pt-PT")) == .other)
        #expect(PluralCategory.select(count: 1, locale: LocaleInfo("pt-PT")) == .one)
        #expect(PluralCategory.select(count: 0, locale: LocaleInfo("pt")) == .one)
        #expect(PluralCategory.select(count: 1, locale: LocaleInfo("lt")) == .one)
        #expect(PluralCategory.select(count: 3, locale: LocaleInfo("lt")) == .few)
        #expect(PluralCategory.select(count: 11, locale: LocaleInfo("lt")) == .other)
        #expect(PluralCategory.select(count: 0, locale: LocaleInfo("lv")) == .zero)
        #expect(PluralCategory.select(count: 21, locale: LocaleInfo("lv")) == .one)
        #expect(PluralCategory.select(count: 1, locale: LocaleInfo("ro")) == .one)
        #expect(PluralCategory.select(count: 0, locale: LocaleInfo("ro")) == .few)
        #expect(PluralCategory.select(count: 20, locale: LocaleInfo("ro")) == .other)
        #expect(PluralCategory.select(count: 101, locale: LocaleInfo("sl")) == .one)
        #expect(PluralCategory.select(count: 102, locale: LocaleInfo("sl")) == .two)
        #expect(PluralCategory.select(count: 104, locale: LocaleInfo("sl")) == .few)
        #expect(PluralCategory.select(count: 105, locale: LocaleInfo("sl")) == .other)
        #expect(PluralCategory.select(count: 2, locale: LocaleInfo("hr")) == .few)
        #expect(PluralCategory.select(count: 5, locale: LocaleInfo("hr")) == .other)
        #expect(PluralCategory.select(count: 2, locale: LocaleInfo("ga")) == .two)
        #expect(PluralCategory.select(count: 7, locale: LocaleInfo("ga")) == .many)
        #expect(PluralCategory.select(count: 0, locale: LocaleInfo("cy")) == .zero)
        #expect(PluralCategory.select(count: 3, locale: LocaleInfo("cy")) == .few)
        #expect(PluralCategory.select(count: 6, locale: LocaleInfo("cy")) == .many)
        #expect(PluralCategory.select(count: 0, locale: LocaleInfo("mt")) == .few)
        #expect(PluralCategory.select(count: 15, locale: LocaleInfo("mt")) == .many)
        #expect(PluralCategory.select(count: 11, locale: LocaleInfo("is")) == .other)
        #expect(PluralCategory.select(count: 21, locale: LocaleInfo("is")) == .one)
        #expect(PluralCategory.select(count: 11, locale: LocaleInfo("mk")) == .other)
        #expect(PluralCategory.select(count: 12, locale: LocaleInfo("gd")) == .two)

        // Shortest round-trip float rounding (1.005 -> 1.01 half-expand)
        let en = I18n(locale: "en-US", fallback: "en-US")
        #expect(en.decimal(1.005, maxFraction: 2) == "1.01")
        #expect(en.decimal(-1.005, maxFraction: 2) == "-1.01")
    }
}
