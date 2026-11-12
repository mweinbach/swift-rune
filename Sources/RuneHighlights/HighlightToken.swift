import Foundation

/// A Zed-compatible syntax capture token.
public struct HighlightToken: Sendable, Equatable, Hashable {
    public enum Kind: UInt8, Sendable, Equatable, Hashable, CaseIterable {
        case none = 0
        case attribute = 1
        case attributeJSX = 2
        case boolean = 3
        case comment = 4
        case commentDoc = 5
        case constant = 6
        case constantBuiltin = 7
        case constructor = 8
        case diffMinus = 9
        case diffPlus = 10
        case embedded = 11
        case emphasis = 12
        case emphasisStrong = 13
        case function = 14
        case functionDefinition = 15
        case functionMethod = 16
        case keyword = 17
        case keywordControl = 18
        case keywordDeclaration = 19
        case keywordImport = 20
        case keywordOperator = 21
        case label = 22
        case namespace = 23
        case number = 24
        case `operator` = 25
        case predictive = 26
        case preproc = 27
        case primary = 28
        case property = 29
        case propertyJSONKey = 30
        case punctuation = 31
        case punctuationBracket = 32
        case punctuationBracketHTML = 33
        case punctuationBracketJSX = 34
        case punctuationDelimiter = 35
        case punctuationDelimiterHTML = 36
        case punctuationDelimiterJSX = 37
        case punctuationListMarker = 38
        case punctuationMarkup = 39
        case punctuationSpecial = 40
        case selector = 41
        case selectorClass = 42
        case selectorID = 43
        case string = 44
        case stringEscape = 45
        case stringRegex = 46
        case stringSpecial = 47
        case stringSpecialSymbol = 48
        case tag = 49
        case tagDoctype = 50
        case tagJSX = 51
        case textJSX = 52
        case textLiteral = 53
        case title = 54
        case type = 55
        case typeBuiltin = 56
        case typeClass = 57
        case variable = 58
        case variableParameter = 59
        case variableSpecial = 60
        case `enum` = 61
        case hint = 62
        case keywordJSDoc = 63
        case linkText = 64
        case linkURI = 65
        case selectorPseudo = 66
        case tagComponentJSX = 67
        case typeJSDoc = 68
        case variableJSDoc = 69
        case variant = 70
        case background = 71
        case foreground = 72
    }

    public let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public static let none = HighlightToken(.none)
    public static var count: Int { Kind.allCases.count }
    public static var all: [HighlightToken] { Kind.allCases.map(HighlightToken.init) }

    public var index: Int { Int(kind.rawValue) }

    /// Zed capture name (e.g. `"keyword.control"`, `"string.escape"`).
    public var name: String {
        Self.names[Int(kind.rawValue)]
    }

    /// Parent token for theme fallback (e.g. `"keyword.control"` -> `"keyword"`).
    public var parent: HighlightToken? {
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let parentName = String(name[..<dot])
        return HighlightToken.fromName(parentName)
    }

    public static func fromName(_ name: String) -> HighlightToken? {
        guard let idx = nameToIndex[name], let kind = Kind(rawValue: idx) else { return nil }
        return HighlightToken(kind)
    }

    private static let names: [String] = [
        "none", "attribute", "attribute.jsx", "boolean", "comment", "comment.doc",
        "constant", "constant.builtin", "constructor", "diff.minus", "diff.plus", "embedded",
        "emphasis", "emphasis.strong", "function", "function.definition", "function.method", "keyword",
        "keyword.control", "keyword.declaration", "keyword.import", "keyword.operator", "label", "namespace",
        "number", "operator", "predictive", "preproc", "primary", "property",
        "property.json_key", "punctuation", "punctuation.bracket", "punctuation.bracket.html", "punctuation.bracket.jsx", "punctuation.delimiter",
        "punctuation.delimiter.html", "punctuation.delimiter.jsx", "punctuation.list_marker", "punctuation.markup", "punctuation.special", "selector",
        "selector.class", "selector.id", "string", "string.escape", "string.regex", "string.special",
        "string.special.symbol", "tag", "tag.doctype", "tag.jsx", "text.jsx", "text.literal",
        "title", "type", "type.builtin", "type.class", "variable", "variable.parameter",
        "variable.special", "enum", "hint", "keyword.jsdoc", "link_text", "link_uri",
        "selector.pseudo", "tag.component.jsx", "type.jsdoc", "variable.jsdoc", "variant", "background",
        "foreground",
    ]

    private static let nameToIndex: [String: UInt8] = {
        var map: [String: UInt8] = [:]
        for (idx, name) in names.enumerated() {
            map[name] = UInt8(idx)
        }
        return map
    }()
}

/// A highlighted UTF-8 byte range in source text.
public struct HighlightSpan: Sendable, Equatable, Hashable {
    public var utf8Range: Range<Int>
    public var token: HighlightToken

    public init(utf8Range: Range<Int>, token: HighlightToken) {
        self.utf8Range = utf8Range
        self.token = token
    }

    /// Extracts the matching `Substring` from `source`.
    public func text(in source: String) -> Substring? {
        let utf8 = source.utf8
        guard utf8Range.lowerBound >= 0,
              utf8Range.upperBound <= utf8.count,
              let start = utf8.index(utf8.startIndex, offsetBy: utf8Range.lowerBound, limitedBy: utf8.endIndex),
              let end = utf8.index(utf8.startIndex, offsetBy: utf8Range.upperBound, limitedBy: utf8.endIndex),
              start <= end
        else {
            return nil
        }
        return source[start..<end]
    }
}

/// RGBA color for syntax theme mapping.
public struct HighlightColor: Sendable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(hex: UInt32, alpha: Double = 1.0) {
        self.red = Double((hex >> 16) & 0xff) / 255.0
        self.green = Double((hex >> 8) & 0xff) / 255.0
        self.blue = Double(hex & 0xff) / 255.0
        self.alpha = alpha
    }
}

/// Visual style for a syntax token.
public struct HighlightStyle: Sendable, Equatable, Hashable {
    public var color: HighlightColor?
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool

    public init(
        color: HighlightColor? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false
    ) {
        self.color = color
        self.bold = bold
        self.italic = italic
        self.underline = underline
    }
}

/// Maps `HighlightToken` capture names to `HighlightStyle`, with hierarchical parent fallback.
public struct HighlightTheme: Sendable, Equatable {
    public var name: String
    public var foreground: HighlightColor
    public var background: HighlightColor
    private var styles: [String: HighlightStyle]

    public init(
        name: String,
        foreground: HighlightColor,
        background: HighlightColor,
        styles: [String: HighlightStyle]
    ) {
        self.name = name
        self.foreground = foreground
        self.background = background
        self.styles = styles
    }

    /// Resolves the style for `token`, walking parent capture names (e.g. `keyword.control` -> `keyword`).
    public func style(for token: HighlightToken) -> HighlightStyle? {
        if let direct = styles[token.name] {
            return direct
        }
        var current: HighlightToken? = token.parent
        while let candidate = current {
            if let found = styles[candidate.name] {
                return found
            }
            current = candidate.parent
        }
        return nil
    }

    public static let defaultDark = HighlightTheme(
        name: "Rune Dark",
        foreground: HighlightColor(hex: 0xE6EDF3),
        background: HighlightColor(hex: 0x0D1117),
        styles: [
            "comment": HighlightStyle(color: HighlightColor(hex: 0x8B949E), italic: true),
            "comment.doc": HighlightStyle(color: HighlightColor(hex: 0x9BA4AE), italic: true),
            "keyword": HighlightStyle(color: HighlightColor(hex: 0xFF7B72)),
            "keyword.control": HighlightStyle(color: HighlightColor(hex: 0xFF7B72)),
            "keyword.declaration": HighlightStyle(color: HighlightColor(hex: 0xFF7B72)),
            "keyword.import": HighlightStyle(color: HighlightColor(hex: 0xFF7B72)),
            "keyword.operator": HighlightStyle(color: HighlightColor(hex: 0xFF7B72)),
            "string": HighlightStyle(color: HighlightColor(hex: 0xA5D6FF)),
            "string.escape": HighlightStyle(color: HighlightColor(hex: 0x79C0FF), bold: true),
            "string.regex": HighlightStyle(color: HighlightColor(hex: 0x7EE787)),
            "number": HighlightStyle(color: HighlightColor(hex: 0x79C0FF)),
            "boolean": HighlightStyle(color: HighlightColor(hex: 0x79C0FF)),
            "constant": HighlightStyle(color: HighlightColor(hex: 0x79C0FF)),
            "constant.builtin": HighlightStyle(color: HighlightColor(hex: 0x79C0FF)),
            "type": HighlightStyle(color: HighlightColor(hex: 0xFFA657)),
            "type.builtin": HighlightStyle(color: HighlightColor(hex: 0xFFA657)),
            "function": HighlightStyle(color: HighlightColor(hex: 0xD2A8FF)),
            "function.definition": HighlightStyle(color: HighlightColor(hex: 0xD2A8FF), bold: true),
            "function.method": HighlightStyle(color: HighlightColor(hex: 0xD2A8FF)),
            "property": HighlightStyle(color: HighlightColor(hex: 0x79C0FF)),
            "property.json_key": HighlightStyle(color: HighlightColor(hex: 0x7EE787)),
            "attribute": HighlightStyle(color: HighlightColor(hex: 0xD2A8FF)),
            "preproc": HighlightStyle(color: HighlightColor(hex: 0xFF7B72)),
            "tag": HighlightStyle(color: HighlightColor(hex: 0x7EE787)),
            "tag.doctype": HighlightStyle(color: HighlightColor(hex: 0x8B949E)),
            "selector": HighlightStyle(color: HighlightColor(hex: 0x7EE787)),
            "operator": HighlightStyle(color: HighlightColor(hex: 0xFF7B72)),
            "punctuation": HighlightStyle(color: HighlightColor(hex: 0x8B949E)),
            "title": HighlightStyle(color: HighlightColor(hex: 0x79C0FF), bold: true),
            "emphasis": HighlightStyle(italic: true),
            "emphasis.strong": HighlightStyle(bold: true),
            "text.literal": HighlightStyle(color: HighlightColor(hex: 0xA5D6FF)),
            "link_text": HighlightStyle(color: HighlightColor(hex: 0xA5D6FF), underline: true),
            "link_uri": HighlightStyle(color: HighlightColor(hex: 0x79C0FF), underline: true),
            "diff.plus": HighlightStyle(color: HighlightColor(hex: 0x7EE787)),
            "diff.minus": HighlightStyle(color: HighlightColor(hex: 0xFFA198)),
            "variable.special": HighlightStyle(color: HighlightColor(hex: 0xFFA657)),
            "label": HighlightStyle(color: HighlightColor(hex: 0xD2A8FF)),
        ]
    )

    public static let defaultLight = HighlightTheme(
        name: "Rune Light",
        foreground: HighlightColor(hex: 0x1F2328),
        background: HighlightColor(hex: 0xFFFFFF),
        styles: [
            "comment": HighlightStyle(color: HighlightColor(hex: 0x6E7781), italic: true),
            "keyword": HighlightStyle(color: HighlightColor(hex: 0xCF222E)),
            "string": HighlightStyle(color: HighlightColor(hex: 0x0A3069)),
            "string.escape": HighlightStyle(color: HighlightColor(hex: 0x0550AE), bold: true),
            "number": HighlightStyle(color: HighlightColor(hex: 0x0550AE)),
            "boolean": HighlightStyle(color: HighlightColor(hex: 0x0550AE)),
            "constant": HighlightStyle(color: HighlightColor(hex: 0x0550AE)),
            "type": HighlightStyle(color: HighlightColor(hex: 0x953800)),
            "function": HighlightStyle(color: HighlightColor(hex: 0x8250DF)),
            "property": HighlightStyle(color: HighlightColor(hex: 0x0550AE)),
            "property.json_key": HighlightStyle(color: HighlightColor(hex: 0x116329)),
            "attribute": HighlightStyle(color: HighlightColor(hex: 0x8250DF)),
            "preproc": HighlightStyle(color: HighlightColor(hex: 0xCF222E)),
            "tag": HighlightStyle(color: HighlightColor(hex: 0x116329)),
            "title": HighlightStyle(color: HighlightColor(hex: 0x0550AE), bold: true),
            "diff.plus": HighlightStyle(color: HighlightColor(hex: 0x116329)),
            "diff.minus": HighlightStyle(color: HighlightColor(hex: 0xCF222E)),
        ]
    )
}
