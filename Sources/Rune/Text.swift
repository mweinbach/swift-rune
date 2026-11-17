import Foundation
#if canImport(CoreText)
import CoreText
#endif
#if os(macOS)
import class AppKit.NSFont
#elseif canImport(UIKit)
import class UIKit.UIFont
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import RuneMotion
import RuneRef
#if canImport(simd)
import simd
#endif

public enum FontFamily: Sendable, Hashable, Codable {
    case systemUI
    case monospace
    /// The platform's monospaced UI face, followed by the app's mono slot.
    case systemMono
    case custom(String)

    public static func named(_ name: String) -> FontFamily { .custom(name) }

    package var isMonospace: Bool { self == .monospace || self == .systemMono }

    /// A named stack falls back to the app's sans slot, just as Rune's paragraph shaper does.
    internal func stack(sans: String, mono: String) -> String {
        let sans = Self.expandingSystemMono(in: sans.isEmpty ? DefaultFonts.sansFamily : sans, fallback: DefaultFonts.sansFamily)
        switch self {
        case .systemUI: return sans
        case .monospace, .systemMono:
            let slot = Self.expandingSystemMono(in: mono.isEmpty ? DefaultFonts.defaultMonoSlot : mono, fallback: sans)
            if self == .systemMono && !Self.systemMonoFamilies.isEmpty {
                return (Self.systemMonoFamilies + [slot]).joined(separator: ", ")
            }
            return slot
        case .custom(let names): return names.isEmpty || names == sans ? sans : names + ", " + sans
        }
    }

    /// CoreText looks up individual names. Pango accepts an unquoted, comma-separated list.
    internal static func candidates(in stack: String) -> [String] {
        if !stack.utf8.contains(where: { byte in
            byte == UInt8(ascii: ",") || byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") || byte == UInt8(ascii: "\\")
        }) {
            let name = stack.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? [] : [name]
        }
        var result: [String] = []
        forEachFamily(in: stack) { name, _ in result.append(name) }
        return result
    }

    /// Preserve quoted family names when expanding the CSS generic in an app's font slot.
    static func expandingSystemMono(in stack: String, fallback: String, system: [String] = systemMonoFamilies) -> String {
        guard stack.utf8.contains(UInt8(ascii: "-")), stack.range(of: "ui-monospace", options: .caseInsensitive) != nil else { return stack }
        var result: [String] = []
        var expanded = false
        var hasNamed = false
        forEachFamily(in: stack) { _, token in
            let raw = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.caseInsensitiveCompare("ui-monospace") == .orderedSame {
                result.append(contentsOf: system)
                expanded = true
                hasNamed = hasNamed || !system.isEmpty
            } else {
                result.append(raw)
                hasNamed = hasNamed || !cssGenericFamilies.contains(raw.lowercased())
            }
        }
        guard expanded else { return stack }
        if !hasNamed { result.append(fallback) }
        return result.joined(separator: ", ")
    }

    private static let cssGenericFamilies: Set<String> = [
        "serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui",
        "ui-serif", "ui-sans-serif", "ui-rounded", "emoji", "math", "fangsong",
    ]

    private static let systemMonoFamilies: [String] = {
        #if canImport(CoreText)
        [".SF NS Mono", "Menlo"]
        #elseif os(Windows)
        ["Cascadia Mono", "Consolas", "Courier New"]
        #elseif os(Linux)
        // Pango resolves the user's fontconfig monospace alias in process.
        ["monospace", "DejaVu Sans Mono", "Liberation Mono", "Noto Sans Mono", "Ubuntu Mono"]
        #else
        // Upstream uses the app's slot on targets without an installed system font collection.
        []
        #endif
    }()

    private static func forEachFamily(in stack: String, _ visit: (String, Substring) -> Void) {
        var name = ""
        var quote: Character?
        var start = stack.startIndex
        var cursor = start
        func flush(until end: String.Index) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { visit(trimmed, stack[start..<end]) }
            name.removeAll(keepingCapacity: true)
        }
        while cursor < stack.endIndex {
            let position = cursor
            let character = stack[cursor]
            stack.formIndex(after: &cursor)
            if character == "," && quote == nil {
                flush(until: position)
                start = cursor
                continue
            }
            if character == "\\", cursor < stack.endIndex {
                name.append(stack[cursor])
                stack.formIndex(after: &cursor)
            } else if let delimiter = quote {
                if character == delimiter { quote = nil } else { name.append(character) }
            } else if (character == "'" || character == "\"") && name.allSatisfy(\.isWhitespace) {
                quote = character
            } else {
                name.append(character)
            }
        }
        flush(until: stack.endIndex)
    }
}

/// Optical sizing mode for variable/CoreText fonts (`rune::tok::OpticalSize`).
public enum OpticalSize: Sendable, Hashable, Codable {
    case auto
    case fontDefault
    case fixed(Float)

    public static func == (lhs: OpticalSize, rhs: OpticalSize) -> Bool {
        switch (lhs, rhs) {
        case (.auto, .auto), (.fontDefault, .fontDefault): return true
        case let (.fixed(a), .fixed(b)): return a.bitPattern == b.bitPattern || (a == b)
        default: return false
        }
    }
}

public enum TextAlign: Sendable, Hashable, Codable {
    case leading
    case center
    case trailing
    case justified
}

public enum TextWrap: Sendable, Hashable, Codable {
    case wrap
    case noWrap
    case ellipsis
}

/// Which end `TextWrap.ellipsis` trims (`El.truncate`, `El.truncateMiddle`, `El.truncateHead`).
public enum TextElide: String, Sendable, Hashable, Codable {
    case end
    case middle
    case head
}

/// Typographic styling matching `rune::TextStyle`.
public struct TextStyle: Sendable, Hashable, Codable {
    public var size: Float
    /// CSS numeric font weight (`100...900`, `400 = regular`, `500 = medium`, `600 = semibold`, `700 = bold`).
    public var weight: Float
    public var lineHeight: Float?
    public var letterSpacing: Float
    public var italic: Bool
    public var family: FontFamily
    public var align: TextAlign
    public var wrap: TextWrap
    public var wrapAnywhere: Bool
    public var elide: TextElide
    public var maxLines: Int
    public var exactLines: Bool
    public var fontSmoothing: FontSmoothing
    public var variations: String
    public var features: String
    public var opticalSize: OpticalSize
    public var direction: TextFlow?
    /// A by-paragraph field's text (`TextSpec::by_paragraph`, `text/paragraphs.rs`): set, its
    /// pills' labels are shaped between U+2068 FSI and U+2069 PDI, and with `direction` nil each
    /// paragraph reads the way its first strong character outside them does, else the way the
    /// one before it does, the first this flow (`plaintext_flow`). On a field's element it holds
    /// the element's resolved flow for `El.dirByParagraph` (`TextDir::Plaintext`). Not encoded.
    internal var byParagraphStart: TextFlow? = nil
    /// Resolved editing blocks that indent visual lines. An unformatted field shares the plain-text layout.
    internal var paragraphBlocks: [Block] = []
    /// A placeholder starts inside its field's first block using the field font size.
    internal var placeholderIndent: Float = 0
    internal var hasBlockInsets: Bool { !paragraphBlocks.isEmpty || placeholderIndent > 0 }

    fileprivate func blockInsetsPx(at paragraph: Int, scale: Float, rtl: Bool) -> SIMD2<Float> {
        if placeholderIndent > 0 {
            let indent = (placeholderIndent * scale).rounded()
            return rtl ? SIMD2(0, indent) : SIMD2(indent, 0)
        }
        guard paragraph < paragraphBlocks.count else { return .zero }
        let block = paragraphBlocks[paragraph]
        let left = (block.indentPt(fontSize: size) * scale).rounded()
        return SIMD2(left, block == .code ? left : 0)
    }

    public static let body = TextStyle(size: 13.0, weight: 400.0)

    public init(
        size: Float = 13.0,
        weight: Float = 400.0,
        lineHeight: Float? = nil,
        letterSpacing: Float = 0.0,
        italic: Bool = false,
        family: FontFamily = .systemUI,
        align: TextAlign = .leading,
        wrap: TextWrap = .noWrap,
        wrapAnywhere: Bool = false,
        elide: TextElide = .end,
        maxLines: Int = 0,
        exactLines: Bool = true,
        fontSmoothing: FontSmoothing = .systemDefault,
        variations: String = "",
        features: String = "",
        opticalSize: OpticalSize = .auto,
        direction: TextFlow? = nil
    ) {
        self.size = max(1.0, size)
        self.weight = weight.clamped(to: 100...900)
        self.lineHeight = lineHeight
        self.letterSpacing = letterSpacing
        self.italic = italic
        self.family = family
        self.align = align
        self.wrap = wrap
        self.wrapAnywhere = wrapAnywhere
        self.elide = elide
        self.maxLines = max(0, maxLines)
        self.exactLines = exactLines
        self.fontSmoothing = fontSmoothing
        self.variations = variations
        self.features = features
        self.opticalSize = opticalSize
        self.direction = direction
    }

    private enum CodingKeys: String, CodingKey {
        case size, weight, lineHeight, letterSpacing, italic, family, align, wrap, wrapAnywhere, elide, maxLines, exactLines, fontSmoothing, variations, features, opticalSize, direction
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            size: try c.decode(Float.self, forKey: .size),
            weight: try c.decode(Float.self, forKey: .weight),
            lineHeight: try c.decodeIfPresent(Float.self, forKey: .lineHeight),
            letterSpacing: try c.decode(Float.self, forKey: .letterSpacing),
            italic: try c.decode(Bool.self, forKey: .italic),
            family: try c.decode(FontFamily.self, forKey: .family),
            align: try c.decode(TextAlign.self, forKey: .align),
            wrap: try c.decode(TextWrap.self, forKey: .wrap),
            wrapAnywhere: try c.decodeIfPresent(Bool.self, forKey: .wrapAnywhere) ?? false,
            elide: try c.decodeIfPresent(TextElide.self, forKey: .elide) ?? .end,
            maxLines: try c.decodeIfPresent(Int.self, forKey: .maxLines) ?? 0,
            exactLines: try c.decodeIfPresent(Bool.self, forKey: .exactLines) ?? true,
            fontSmoothing: try c.decode(FontSmoothing.self, forKey: .fontSmoothing),
            variations: try c.decodeIfPresent(String.self, forKey: .variations) ?? "",
            features: try c.decodeIfPresent(String.self, forKey: .features) ?? "",
            opticalSize: try c.decodeIfPresent(OpticalSize.self, forKey: .opticalSize) ?? .auto,
            direction: try c.decodeIfPresent(TextFlow.self, forKey: .direction)
        )
    }

    public func family(_ family: FontFamily) -> TextStyle {
        var copy = self
        copy.family = family
        return copy
    }

    public func variations(_ variations: String) -> TextStyle {
        var copy = self
        copy.variations = variations
        return copy
    }

    public func features(_ features: String) -> TextStyle {
        var copy = self
        copy.features = features
        return copy
    }

    /// Code keeps a cell per character even in fonts with programming ligatures.
    internal func shapingFeatures(monospace: Bool) -> String {
        guard monospace else { return features }
        let unligated = "'liga' 0, 'clig' 0, 'calt' 0, 'dlig' 0"
        guard !features.isEmpty else { return unligated }
        let others = features.split(separator: ",").filter { item in
            let tag = item.split { $0.isWhitespace || $0 == "=" || $0 == "'" || $0 == "\"" }.first
            return tag != "liga" && tag != "clig" && tag != "calt" && tag != "dlig"
        }
        return others.isEmpty ? unligated : others.joined(separator: ",") + ", " + unligated
    }

    public func opticalSize(_ size: Float) -> TextStyle {
        var copy = self
        copy.opticalSize = .fixed(size)
        return copy
    }

    public func opticalSizing(_ opticalSize: OpticalSize) -> TextStyle {
        var copy = self
        copy.opticalSize = opticalSize
        return copy
    }

    public func linePx() -> Float {
        resolvedLineHeight
    }

    public func smoothing(_ mode: FontSmoothing) -> TextStyle {
        var copy = self
        copy.fontSmoothing = mode
        return copy
    }

    public func lh(_ h: Float) -> TextStyle {
        var copy = self
        copy.lineHeight = h
        return copy
    }

    public func mono() -> TextStyle {
        var copy = self
        copy.family = .monospace
        return copy
    }

    public func bold() -> TextStyle {
        var copy = self
        copy.weight = 700.0
        return copy
    }

    public func medium() -> TextStyle {
        var copy = self
        copy.weight = 500.0
        return copy
    }

    public func semibold() -> TextStyle {
        var copy = self
        copy.weight = 600.0
        return copy
    }

    public func wrapAnywhere(_ enabled: Bool = true) -> TextStyle {
        var copy = self
        copy.wrapAnywhere = enabled
        return copy
    }

    public func aligned(_ a: TextAlign) -> TextStyle {
        var copy = self
        copy.align = a
        return copy
    }

    public func justify(_ on: Bool = true) -> TextStyle {
        var copy = self
        copy.align = on ? .justified : .leading
        return copy
    }

    public func wrapped(_ on: Bool = true) -> TextStyle {
        var copy = self
        copy.wrap = on ? .wrap : .noWrap
        return copy
    }

    public func noWrap() -> TextStyle {
        var copy = self
        copy.wrap = .noWrap
        return copy
    }

    public func ellipsis() -> TextStyle {
        var copy = self
        copy.wrap = .ellipsis
        return copy
    }

    public func italic(_ on: Bool = true) -> TextStyle {
        var copy = self
        copy.italic = on
        return copy
    }

    public func letterSpacing(_ spacing: Float) -> TextStyle {
        var copy = self
        copy.letterSpacing = spacing
        return copy
    }

    public var resolvedLineHeight: Float {
        if let lh = lineHeight, lh > 0 { return lh }
        return size * 1.25
    }
}

/// Rich inline styled text span (`rune::Span`).
public struct TextSpan: Sendable, Hashable {
    public var text: String
    public var color: Color?
    public var background: Color?
    public var weight: Float?
    public var italic: Bool
    public var monospace: Bool
    public var underline: Bool
    public var strikethrough: Bool
    public var size: Float?
    /// Room (points) its background takes past the text on each side (`Span::bg_pad`).
    public var pad: Float

    public init(
        _ text: String,
        color: Color? = nil,
        background: Color? = nil,
        weight: Float? = nil,
        italic: Bool = false,
        monospace: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false,
        size: Float? = nil,
        pad: Float = 0
    ) {
        self.pad = max(0, pad)
        self.text = text
        self.color = color
        self.background = background
        self.weight = weight
        self.italic = italic
        self.monospace = monospace
        self.underline = underline
        self.strikethrough = strikethrough
        self.size = size
    }
}

/// Vector SVG path icon definition (`M/L/H/V/C/Q/Z` or SVG body in a square `viewBox`, typically `16` or `24`).
public struct SVGIcon: Sendable, Hashable {
    public var viewBox: Float
    public var paths: [String]
    public var strokeWidth: Float?
    /// Optional raw SVG body markup (multi-color paths/shapes/gradients, `currentColor`, groups, transforms).
    public var body: String?

    public init(viewBox: Float = 24.0, paths: [String], strokeWidth: Float? = 2.0, body: String? = nil) {
        self.viewBox = max(1, viewBox)
        self.paths = paths
        self.strokeWidth = strokeWidth
        self.body = body
    }

    public init(viewBox: Float = 24.0, body: String) {
        self.viewBox = max(1, viewBox)
        self.paths = []
        self.strokeWidth = nil
        self.body = body
    }

    /// True when the icon's SVG body declares its own colors (`fill="#..."`, `stroke="#..."`, `stop-color="#..."`).
    public var isColorIcon: Bool {
        guard let body else { return false }
        return body.contains("fill=\"#") || body.contains("stroke=\"#") || body.contains("stop-color=\"#") ||
            body.contains("fill='#") || body.contains("stroke='#") || body.contains("stop-color='#")
    }
}

/// Positioned glyph quad emitted by `TextSystem` in element-local logical points.
public struct PositionedGlyph: Sendable, Equatable {
    private final class ColorBitmap: Sendable {
        let entry: GlyphAtlas.ColorGlyphEntry
        init(_ entry: GlyphAtlas.ColorGlyphEntry) { self.entry = entry }
    }
    private var colorBitmap: ColorBitmap?
    fileprivate var retainedColorGlyph: GlyphAtlas.ColorGlyphEntry? {
        guard let entry = colorBitmap?.entry, (colorGlyphIndex ?? 0) == entry.index else { return nil }
        return entry
    }
    /// Quad `[x, y, width, height]` in logical points relative to the text box origin.
    public var rect: SIMD4<Float>
    /// Normalized `[u0, v0, u1, v1]` in `GlyphAtlas` (`.zero` for RGBA color glyphs).
    public var uv: SIMD4<Float>
    public var color: Color?
    /// Atlas lookup index for cached color glyphs. `TextSystem.colorGlyph(for:)` also reads uncached and evicted glyphs.
    public var colorGlyphIndex: UInt32?
    /// UTF-8 byte of the glyph cluster in the text this layout shaped.
    public var utf8Offset: Int
    /// Alpha atlas page index (`GlyphAtlas.pageData(_:)`, `atlas.rs:168`).
    public var atlasPage: UInt16
    /// Vertical ink displacement baked into the native desktop glide mask, in device pixels.
    var maskShiftY: Float = 0
    var outlineGroup: TextOutlineGroup?
    #if canImport(CoreText) && canImport(CoreGraphics)
    var classicInk: AppleClassicGlyph.Ink?
    #elseif os(Linux) || os(Windows) || os(Android)
    var desktopInk: DesktopGlyphInk?
    #endif
    var usesInkDilation: Bool {
        #if canImport(CoreText) && canImport(CoreGraphics)
        classicInk != nil || outlineGroup?.inkVariant != nil
        #elseif os(Linux) || os(Windows) || os(Android)
        desktopInk != nil
        #else
        false
        #endif
    }
    #if os(Windows)
    // Native tile shared by adjacent graphemes. Its gamma table depends on paint-time ink.
    var windowsMask: WindowsGlyphMask?
    #endif
    internal var hasLCDMask: Bool {
        #if os(Windows)
        return windowsMask?.rgb != nil
        #else
        return false
        #endif
    }

    public init(
        rect: SIMD4<Float>,
        uv: SIMD4<Float>,
        color: Color? = nil,
        colorGlyphIndex: UInt32? = nil,
        atlasPage: UInt16 = 0,
        utf8Offset: Int = 0
    ) {
        self.rect = rect
        self.uv = uv
        self.color = color
        self.colorGlyphIndex = colorGlyphIndex
        self.atlasPage = atlasPage
        self.utf8Offset = utf8Offset
    }

    internal init(rect: SIMD4<Float>, colorGlyph: GlyphAtlas.ColorGlyphEntry,
                  color: Color? = nil, utf8Offset: Int = 0) {
        self.init(rect: rect, uv: .zero, color: color,
                  colorGlyphIndex: colorGlyph.index == 0 ? nil : colorGlyph.index, utf8Offset: utf8Offset)
        colorBitmap = ColorBitmap(colorGlyph)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        #if os(Windows)
        guard lhs.windowsMask?.bounds == rhs.windowsMask?.bounds, lhs.hasLCDMask == rhs.hasLCDMask else { return false }
        #endif
        guard lhs.rect == rhs.rect, lhs.uv == rhs.uv, lhs.color == rhs.color,
              lhs.colorGlyphIndex == rhs.colorGlyphIndex, lhs.utf8Offset == rhs.utf8Offset,
              lhs.atlasPage == rhs.atlasPage, lhs.maskShiftY == rhs.maskShiftY else { return false }
        guard lhs.outlineGroup == rhs.outlineGroup else { return false }
        return lhs.colorGlyphIndex != nil || lhs.colorBitmap === rhs.colorBitmap
            || lhs.retainedColorGlyph == rhs.retainedColorGlyph
    }
}

/// Shaped multi-line text result with metrics, glyph quads, and caret lookup helpers.
/// `CTLine` is an immutable CoreText CFType safe across threads.
public struct ShapedText: @unchecked Sendable {
    public struct PillChipQuad: Sendable, Equatable {
        public var pillIndex: Int
        public var rect: SIMD4<Float>
        public var background: Color?
        public var ring: TextRing?
        public var cornerRadius: Float
        public var icon: SVGIcon?
        public var iconRect: SIMD4<Float>?
        public var iconColor: Color?

        public init(
            pillIndex: Int,
            rect: SIMD4<Float>,
            background: Color?,
            ring: TextRing? = nil,
            cornerRadius: Float,
            icon: SVGIcon? = nil,
            iconRect: SIMD4<Float>? = nil,
            iconColor: Color? = nil
        ) {
            self.pillIndex = pillIndex
            self.rect = rect
            self.background = background
            self.ring = ring
            self.cornerRadius = cornerRadius
            self.icon = icon
            self.iconRect = iconRect
            self.iconColor = iconColor
        }
    }

    public struct InlineIconQuad: Sendable, Equatable {
        public var pillIndex: Int
        public var pill: PillChip
        public var rect: SIMD4<Float>
        public var cornerRadius: Float
        public var image: RGBA8Atlas?
        public var icon: SVGIcon?
        public var color: Color?

        public init(
            pillIndex: Int,
            pill: PillChip,
            rect: SIMD4<Float>,
            cornerRadius: Float,
            image: RGBA8Atlas? = nil,
            icon: SVGIcon? = nil,
            color: Color? = nil
        ) {
            self.pillIndex = pillIndex
            self.pill = pill
            self.rect = rect
            self.cornerRadius = cornerRadius
            self.image = image
            self.icon = icon
            self.color = color
        }
    }

    internal struct MarkerMap: Sendable, Hashable {
        struct Entry: Sendable, Hashable {
            var shapedU16: Int
            var authU16: Int
            var isTrail: Bool
        }
        struct LineRange: Sendable, Hashable {
            var shapedU16Start: Int
            var shapedU16End: Int
            var authU16Start: Int
            var authU16End: Int
            var authUTF8Start: Int
        }
        var entries: [Entry] = []
        var authText: String = ""
        var lines: [LineRange] = []

        func shapedU16(forAuthU16 u16: Int) -> Int {
            guard !entries.isEmpty else { return u16 }
            var shift = 0
            for e in entries {
                if e.isTrail {
                    if u16 >= e.authU16 { shift += 1 }
                } else {
                    if u16 > e.authU16 { shift += 1 }
                }
            }
            return u16 + shift
        }

        func shapedU16ForSpanBoundary(_ u16: Int, isEnd: Bool) -> Int {
            guard !entries.isEmpty else { return u16 }
            var shift = 0
            for e in entries {
                if isEnd {
                    if u16 > e.authU16 { shift += 1 }
                } else {
                    if u16 >= e.authU16 { shift += 1 }
                }
            }
            return u16 + shift
        }

        func authU16(forShapedU16 s: Int) -> Int {
            guard !entries.isEmpty else { return s }
            var markersBefore = 0
            for e in entries {
                if e.shapedU16 < s {
                    markersBefore += 1
                } else {
                    break
                }
            }
            return max(0, s - markersBefore)
        }
    }

    public var size: Vec2
    public var lineCount: Int
    public var lineHeight: Float
    public var glyphs: [PositionedGlyph]
    public var underlines: [SIMD4<Float>]
    public var strikethroughs: [SIMD4<Float>] = []
    public var backgrounds: [(SIMD4<Float>, Color)]
    public var pillChips: [PillChipQuad] = []
    public var inlineIcons: [InlineIconQuad] = []
    #if canImport(CoreText) && canImport(CoreGraphics)
    internal var lineStrings: [(utf8Start: Int, text: String, originY: Float, originX: Float, ctLine: CTLine?)] = []
    /// Per glyph in `glyphs`, its face and exact pen, so paint can choose its subpixel phase
    /// again where a text laid out from a fractional origin lands (`glyph_emit.rs`, #935).
    internal var glyphPens: [GlyphPen] = []
    internal var glyphPlacements: TextBoxGeometry.GlyphPlacements?
    internal var usesPaintInks = false
    #endif
    /// An unpainted layout exposes neutral mask geometry even after a renderer warmed its cache.
    internal var canReplayGlyphInks: Bool {
        #if canImport(CoreText) && canImport(CoreGraphics)
        return !usesPaintInks || GlyphAtlas.baseInkBucket != nil
        #else
        return true
        #endif
    }

    internal var portableLines: [(utf8Start: Int, text: String, originY: Float, originX: Float, charOffsets: [Float])] = []
    /// Native bidi lines in visual order. A logical insertion point can have two different x positions.
    internal var portableBidiCells: [Int: [PortableCaretCell]] = [:]
    /// Native shapes before line breaking, plus the fragments measured at the last width.
    internal struct DesktopParagraph {
        #if canImport(CRuneDesktopText) && !canImport(CoreText)
        let linesByStart: [Int: DesktopTextLine]
        let fragments: [DesktopTextLine?]
        let ranges: [Range<Int>]
        #endif
    }
    #if canImport(CRuneDesktopText) && !canImport(CoreText)
    internal var desktopParagraph: DesktopParagraph? = nil
    internal var desktopRestingText: DesktopRestingText? = nil
    #endif

    internal var markerMap: MarkerMap = MarkerMap()
    /// A by-paragraph field's paragraphs over its stacked lines (`ParagraphLayout`), so a selection
    /// boxes each paragraph's bytes and shows a selected line break (`TextFlow::range_boxes`);
    /// empty for one layout.
    internal var paragraphSpans: [ParagraphLineSpan] = []
    /// The width (points) a selected line break between paragraphs highlights (`ParagraphLayout::newline`).
    internal var paragraphNewlinePt: Float = 0
    internal var forcedDirection: TextFlow? = nil
    /// Per line, whether its paragraph lays out right to left (its layout's base direction).
    internal var lineIsRTL: [Bool] = []
    internal var primaryIsRTL: Bool = false
    public var wasTruncated: Bool = false
    internal var lastLineAdvancePx: Float = 0
    internal var hangingAdvancePx: Float = 0
    internal var lastLineWidthPx: Float = 0
    internal var lastLineTrailingWsPx: Float = 0
    public var elided: TextElision? = nil
    public var drawnText: String = ""
    internal var lineAdvancesPx: [(widthPx: Float, trailingWsPx: Float)] = []
    internal var lineGlyphRanges: [Range<Int>] = []
    /// Each line's top (points) when inline code grew some lines (`#983`); empty while every
    /// line is `lineHeight` tall.
    internal var grownLineTopsPt: [Float] = []
    /// Each grown layout line's box height in points (`block_max_coord - block_min_coord`).
    internal var grownLineHeightsPt: [Float] = []

    /// Each grown layout line's `line_height` in points (unrounded `over + under`).
    internal var grownLineMetricHeightsPt: [Float] = []

    /// Line `i`'s `line.metrics().line_height` in points: its grown height when inline code grew
    /// lines (`#983`), else `lineHeight` (`line_metrics::stream_height_lag` reads the last line's).
    internal func lineMetricHeightPt(_ i: Int) -> Float {
        (i >= 0 && i < grownLineMetricHeightsPt.count) ? grownLineMetricHeightsPt[i] : lineHeight
    }

    /// Line `i`'s box height in points, for carets and selections: its grown box's when inline
    /// code grew lines (`#983`), else `lineHeight`.
    internal func lineBoxHeightPt(_ i: Int) -> Float {
        (i >= 0 && i < grownLineHeightsPt.count) ? grownLineHeightsPt[i] : lineHeight
    }

    /// The line at `localY` (points): by `grownLineTopsPt` when lines grew, else by `lineHeight`.
    internal func lineIndex(atLocalY localY: Float, lineCount n: Int) -> Int {
        guard n > 0 else { return 0 }
        if grownLineTopsPt.count == n {
            var idx = 0
            for (i, top) in grownLineTopsPt.enumerated() where localY >= top {
                idx = i
            }
            return idx
        }
        return Int(floorf(max(0, localY) / max(1, lineHeight))).clamped(to: 0...(n - 1))
    }

    /// Line `i`'s top in points (`grownLineTopsPt` when inline code grew lines).
    internal func lineTopPt(_ i: Int) -> Float {
        (i >= 0 && i < grownLineTopsPt.count) ? grownLineTopsPt[i] : Float(i) * lineHeight
    }

    /// The line height glyph-band culling may assume: `0` (no culling) once lines grew.
    internal var bandLineHeight: Float {
        grownLineTopsPt.isEmpty ? lineHeight : 0
    }
    /// Parley's per-line baseline in device pixels from the layout's top.
    internal var lineBaselinesPx: [Float] = []
    /// Per underline in `underlines`, where its line's glyph runs end (points, alignment in), so
    /// paint can end a run that ends its line where it ends (`underline::underline_edges`).
    internal var underlineLineEndsPt: [Float] = []

    /// Horizontal extent of the laid-out lines, including their alignment offsets, in points.
    internal func lineExtent(scale: Float) -> ClosedRange<Float> {
        var left = Float.infinity
        var right = -Float.infinity
        #if canImport(CoreText) && canImport(CoreGraphics)
        for (index, line) in lineStrings.enumerated() {
            left = min(left, line.originX)
            right = max(right, line.originX + lineAdvancePx(at: index) / scale)
        }
        #endif
        for line in portableLines {
            left = min(left, line.originX)
            right = max(right, line.originX + (line.charOffsets.max() ?? 0))
        }
        return left <= right ? left...right : 0...max(0, size.x)
    }

    internal func lineAdvancePx(at index: Int) -> Float {
        guard index >= 0, index < lineAdvancesPx.count else { return 0 }
        let rec = lineAdvancesPx[index]
        return max(0, rec.widthPx - rec.trailingWsPx)
    }

    internal func lineUTF8Range(at index: Int) -> Range<Int> {
        #if canImport(CoreText) && canImport(CoreGraphics)
        if index >= 0 && index < lineStrings.count {
            let rec = lineStrings[index]
            return rec.utf8Start..<(rec.utf8Start + rec.text.utf8.count)
        }
        #endif
        if index >= 0 && index < portableLines.count {
            let rec = portableLines[index]
            return rec.utf8Start..<(rec.utf8Start + rec.text.utf8.count)
        }
        return 0..<0
    }
}

internal struct PillMetrics: Sendable, Hashable {
    var margin: Float
    var pad: Float
    var icon: Float
    var iconGap: Float

    init(size: Float) {
        self.margin = max(size * 0.12, 1.5)
        self.pad = max(size * 0.36, 3.0)
        self.icon = Float((size * 0.95).rounded())
        self.iconGap = max(size * 0.22, 2.0)
    }

    func lead(icon hasIcon: Bool, style: PillStyle) -> Float {
        let resolvedPad = (style.pad != PillStyle.default.pad) ? style.pad : pad
        let resolvedGap = (style.gap != PillStyle.default.gap) ? style.gap : iconGap
        return margin + resolvedPad + (hasIcon ? (icon + resolvedGap) : 0)
    }

    func trail(style: PillStyle) -> Float {
        let resolvedPad = (style.pad != PillStyle.default.pad) ? style.pad : pad
        return resolvedPad + margin
    }

    func resolvedPad(style: PillStyle) -> Float {
        (style.pad != PillStyle.default.pad) ? style.pad : pad
    }
}

/// Shelf-packed R8 coverage atlas for CoreText glyphs and rasterized SVG icons.
public final class GlyphAtlas: @unchecked Sendable {
    public struct Entry: Hashable, Sendable {
        public var uv: SIMD4<Float>
        public var pixelSize: SIMD2<Int>
        /// Top-left offset from baseline origin in device pixels (`x` right, `y` down from baseline).
        public var bearingPx: SIMD2<Float>
        /// Alpha atlas page holding this entry (`0` = primary page, `1...` = secondary/overflow pages).
        public var page: UInt16
        /// Pixel origin `(x, y)` within `page` (`atlas.rs:34`).
        public var pixelOrigin: SIMD2<Int>
        var outlineGroup: TextOutlineGroup?
        #if canImport(CRuneDesktopText) && !canImport(CoreText)
        var desktopTile: DesktopOutlineTile?

        // Deferred coverage metadata belongs to the renderer. Public placement
        // equality stays the same for an eagerly rasterized and a GPU-filled entry.
        public static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.uv == rhs.uv && lhs.pixelSize == rhs.pixelSize && lhs.bearingPx == rhs.bearingPx &&
                lhs.page == rhs.page && lhs.pixelOrigin == rhs.pixelOrigin && lhs.outlineGroup == rhs.outlineGroup
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(uv)
            hasher.combine(pixelSize)
            hasher.combine(bearingPx)
            hasher.combine(page)
            hasher.combine(pixelOrigin)
            hasher.combine(outlineGroup)
        }
        #endif
        #if canImport(CoreText) && canImport(CoreGraphics)
        var classicInk: AppleClassicGlyph.Ink?
        #endif

        public init(
            uv: SIMD4<Float>,
            pixelSize: SIMD2<Int>,
            bearingPx: SIMD2<Float>,
            page: UInt16 = 0,
            pixelOrigin: SIMD2<Int> = .zero
        ) {
            self.uv = uv
            self.pixelSize = pixelSize
            self.bearingPx = bearingPx
            self.page = page
            self.pixelOrigin = pixelOrigin
        }
    }

    /// Cached RGBA8 color glyph bitmap (`#807`, Apple Color Emoji / COLR / CBDT / sbix).
    public struct ColorGlyphEntry: Sendable, Equatable {
        public var index: UInt32
        public var pixelSize: SIMD2<Int>
        public var bearingPx: SIMD2<Float>
        /// Row-major premultiplied sRGB values, matching the Core Graphics color glyph bitmap.
        public var rgba: Data

        public init(index: UInt32 = 0, pixelSize: SIMD2<Int>, bearingPx: SIMD2<Float>, rgba: Data) {
            self.index = index
            self.pixelSize = pixelSize
            self.bearingPx = bearingPx
            self.rgba = rgba
        }
    }

    /// Upstream steady-state shelf page size (`atlas.rs:7`, `ATLAS_SIZE`).
    public static let atlasSize: Int = 2048
    /// Steady-state shelf pages (page 0 + one secondary page for ping-pong eviction, `atlas.rs:48`).
    public static let maxSteadyPages: Int = 2
    /// Hard ceiling on total glyph atlas pages (`atlas.rs:50`).
    public static let maxOverflowPages: Int = 8
    /// Upstream CPU byte budget for cached RGBA color glyphs (`atlas.rs:52`, `COLOR_GLYPH_BUDGET`).
    public static let colorGlyphBudgetBytes: Int = 16 * 1024 * 1024
    /// Quarter-pixel Y glide phases matching `glyph_emit::GLIDE_PHASES`.
    public static let glidePhases: UInt8 = 4

    private enum ShelfUse: Equatable {
        case idle
        case lastFrame
        case thisFrame
    }

    private struct ShelfState {
        let width: Int
        let height: Int
        var x: Int = 1
        var y: Int = 1
        var h: Int = 0
        var used: ShelfUse = .idle
        var full: Bool = false
        var age: UInt64
        var liveTexels: UInt32 = 0

        init(width: Int, height: Int, age: UInt64) {
            self.width = width
            self.height = height
            self.age = age
        }

        mutating func reset(age: UInt64) {
            self = ShelfState(width: width, height: height, age: age)
        }

        var nonEmpty: Bool {
            x > 1 || y > 1 || h > 0
        }

        func usedRows() -> (Int, Int)? {
            nonEmpty ? (0, min(y + h + 1, height)) : nil
        }

        mutating func alloc(w: Int, h: Int) -> (Int, Int)? {
            if x + w + 1 > width {
                y += self.h + 1
                x = 1
                self.h = 0
            }
            if y + h + 1 > height {
                full = true
                return nil
            }
            let pos = (x, y)
            x += w + 1
            self.h = max(self.h, h)
            return pos
        }

        mutating func touch(texels: UInt32) {
            used = .thisFrame
            liveTexels = liveTexels &+ min(UInt32.max &- liveTexels, texels)
        }

        mutating func endFrame() {
            switch used {
            case .thisFrame: used = .lastFrame
            case .idle, .lastFrame: used = .idle
            }
            liveTexels = 0
        }
    }

    private struct AtlasPageState {
        var atlas: R8Atlas
        var dirty: (Int, Int)?
        var shelf: ShelfState

        init(width: Int, height: Int, age: UInt64) {
            self.atlas = R8Atlas(width: width, height: height)
            self.dirty = nil
            self.shelf = ShelfState(width: width, height: height, age: age)
        }
    }

    #if canImport(CoreText) && canImport(CoreGraphics)
    private struct GlyphKey: Hashable {
        var fontHash: CFHashCode
        var glyphID: CGGlyph
        var sizePx10: Int
        var subpixelBin: UInt8
        var subpixelYBin: UInt8
        var smoothing: FontSmoothing
        var inkBucket: UInt8
    }

    #endif

    private enum ColorGlyphKey: Hashable {
        case coreText(fontHash: UInt, glyphID: UInt16, sizePx10: Int)
        #if canImport(CRuneDesktopText) && !canImport(CoreText)
        case desktop(DesktopMaskKey, width: Int, height: Int)
        #endif
    }

    private enum PortableGlyphKey: Hashable {
        #if os(Windows)
        case windowsMask(sourcePage: UInt16, tile: SIMD4<Int32>, bucket: UInt8, lcd: Bool)
        #endif
        case bitmap(scalar: UInt32, sizePx10: Int, bold: Bool, italic: Bool, smoothing: FontSmoothing)
        #if canImport(CRuneDesktopText) && !canImport(CoreText)
        case desktop(DesktopMaskKey)
        #endif
    }

    private struct IconKey: Hashable {
        var icon: SVGIcon
        var pixelSize: Int
        var drawnSixtyFourths: UInt8 = 0
        var mirrored: Bool = false
    }

    private let lock = NSLock()
    #if canImport(CoreText) && canImport(CoreGraphics)
    private lazy var classicGlyphs = AppleClassicGlyph()
    #endif
    private let outlineLock = NSLock()
    // Created under outlineLock, so classic text does not allocate an outline texture row.
    private var outlineStorage: TextOutlineStorage?
    private var outlines: TextOutlineStorage {
        if let outlineStorage { return outlineStorage }
        let storage = TextOutlineStorage()
        outlineStorage = storage
        return storage
    }
    private var fillStats = TextOutlineFillStats()
    internal var outlineFillStats: TextOutlineFillStats { lock.withLock { fillStats } }
    private weak var cpuMaskPool: CpuBootPool?

    internal func fillMasks(on pool: CpuBootPool?) {
        lock.withLock { cpuMaskPool = pool }
    }

    internal func withOutlineStore<R>(_ body: (OutlineStore) -> R) -> R {
        outlineLock.withLock { body(outlines.store) }
    }

    private var pageZero: R8Atlas
    public var atlas: R8Atlas {
        lock.withLock { maskPagePlanLocked(0)?.cpuAtlas() ?? pageZero }
    }
    /// Cache entries depend on the most recent recycle among the shelves their glyphs sample.
    internal func pageSignature(usedPages: UInt8) -> (size: SIMD2<Int>, epoch: UInt64) {
        lock.withLock {
            var epoch = outlineResetEpoch
            for (page, reset) in maskPageEpochs where usedPages & (1 << page) != 0 {
                epoch = max(epoch, reset)
            }
            return (SIMD2(pageZero.width, pageZero.height), epoch)
        }
    }

    internal var pagePixelSize: SIMD2<Int> { SIMD2(targetWidth, targetHeight) }

    // The CPU boot painter or an attached GPU may reserve masks for a later fill.
    private var rendererDefersOutlineMasks = false
    private var deferOutlineMasks: Bool { rendererDefersOutlineMasks || cpuMaskPool != nil }
    internal var defersOutlineMasks: Bool {
        get { lock.withLock { rendererDefersOutlineMasks } }
        set { lock.withLock { rendererDefersOutlineMasks = newValue } }
    }
    private var lcdOutlineMasks: [TextOutlineMaskKey: Entry] = [:]
    private var outlineMaskFills: [QueuedOutlineFill] = []
    private var savedMaskPlan: (generation: UInt64, plan: OutlineMaskPlan)?
    private var savedPagePlans: (generation: UInt64, plans: [OutlineMaskPlan?])?
    private var baseGeneration: UInt64 = 1
    private var outlineResetEpoch: UInt64 = 0
    private var maskPageEpochs: [Int: UInt64] = [:]

    public private(set) var generation: UInt64 = 1
    private struct PageChange {
        var revision: UInt64 = 1
        var rawRevision: UInt64 = 1
        var patch: GlyphAtlasPatch?
        var rawPatch: GlyphAtlasPatch?
        var published = false
        var rawPublished = false

        mutating func write(_ rect: SIMD4<Int>, generation: UInt64, raw: Bool) {
            if published || patch == nil {
                patch = GlyphAtlasPatch(fromRevision: revision, edges: rect)
                published = false
            } else {
                patch?.include(rect)
            }
            revision = generation
            if raw {
                if rawPublished || rawPatch == nil {
                    rawPatch = GlyphAtlasPatch(fromRevision: rawRevision, edges: rect)
                    rawPublished = false
                } else {
                    rawPatch?.include(rect)
                }
                rawRevision = generation
            }
        }
    }
    private var pageChanges: [Int: PageChange] = [:]

    /// The base bitmap changes separately from masks queued for a GPU fill.
    internal func rawGlyphRevisionLocked(page: Int) -> UInt64 {
        pageChanges[page]?.rawRevision ?? 1
    }

    private var combinedSnapshot: (generation: UInt64, atlas: R8Atlas)?
    public let maxCachedEntries: Int
    public let maxColorGlyphBytes: Int
    public let maxAtlasDimension: Int = 4096
    private let targetWidth: Int
    private let targetHeight: Int
    private var backingAllocated: Bool = false
    private var page0Shelf: ShelfState
    private var page0Dirty: (Int, Int)? = nil
    private var overflowPages: [AtlasPageState] = []
    private var clock: UInt64 = 1
    private var resetsCount: UInt64 = 0
    private var rasterizedCount: UInt64 = 0
    private var accessCounter: UInt64 = 0
    #if canImport(CoreText) && canImport(CoreGraphics)
    private var glyphCache: [GlyphKey: (entry: Entry, lastUsed: UInt64, lastFrame: UInt64)] = [:]
    #endif
    private var colorGlyphCache: [ColorGlyphKey: (entry: ColorGlyphEntry, lastUsed: UInt64, lastFrame: UInt64)] = [:]
    private var colorGlyphByIndex: [UInt32: ColorGlyphEntry] = [:]
    private var colorGlyphBytes: Int = 0
    private var nextColorGlyphIndex: UInt32 = 1
    private var portableGlyphCache: [PortableGlyphKey: (entry: Entry, lastUsed: UInt64, lastFrame: UInt64)] = [:]
    private var iconCache: [IconKey: (entry: Entry, lastUsed: UInt64, lastFrame: UInt64)] = [:]
    private var frameSequence: UInt64 = 0

    /// Initializes the atlas with lazy CPU pixel backing (`#830`: keeps a 1-byte 1x1 stub until the first mask is placed).
    public convenience init(width: Int = GlyphAtlas.atlasSize, height: Int = GlyphAtlas.atlasSize, maxCachedEntries: Int = 4096) {
        self.init(
            width: width,
            height: height,
            maxCachedEntries: maxCachedEntries,
            colorGlyphBudget: GlyphAtlas.colorGlyphBudgetBytes
        )
    }

    /// Initializes the atlas with an explicit color-glyph CPU memory budget (`#807`, default 16 MiB).
    public init(
        width: Int = GlyphAtlas.atlasSize,
        height: Int = GlyphAtlas.atlasSize,
        maxCachedEntries: Int = 4096,
        colorGlyphBudget: Int
    ) {
        let w = max(1, width)
        let h = max(1, height)
        self.targetWidth = w
        self.targetHeight = h
        self.pageZero = R8Atlas(width: 1, height: 1)
        self.page0Shelf = ShelfState(width: w, height: h, age: 1)
        self.maxCachedEntries = max(1, maxCachedEntries)
        self.maxColorGlyphBytes = max(0, colorGlyphBudget)
    }

    /// Number of allocated shelf pages (at least 1, matching `atlas.rs:248`).
    public var pageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return 1 + overflowPages.count
    }

    /// Alpha texels for a page returned by `Entry.page` / `PositionedGlyph.atlasPage` (`atlas.rs:253`).
    public func pageData(_ page: Int) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        guard page >= 0 && page <= overflowPages.count else { return nil }
        if let plan = maskPagePlanLocked(page) { return plan.cpuAtlas().texels }
        if page == 0 {
            return backingAllocated ? pageZero.texels : []
        }
        guard page >= 1 && page <= overflowPages.count else { return nil }
        return overflowPages[page - 1].atlas.texels
    }

    private var publishedPages: PageSnapshot?

    internal struct PageSnapshot {
        let bases: [R8Atlas]
        let fills: [OutlineMaskPlan?]
        let revisions: [UInt64]
        let rawRevisions: [UInt64]
        let patches: [GlyphAtlasPatch?]
        let rawPatches: [GlyphAtlasPatch?]
        let generation: UInt64
    }

    /// Page-local CPU rasters. Vertically stacked snapshots remain available via compositedAtlas().
    public var atlases: [R8Atlas] {
        lock.withLock {
            let bases = [pageZero] + overflowPages.map(\.atlas)
            let plans = maskPagePlansLocked(bases: bases)
            guard !plans.isEmpty else { return bases }
            return bases.enumerated().map { index, base in plans[index]?.cpuAtlas() ?? base }
        }
    }

    internal func framePages() -> PageSnapshot {
        lock.withLock {
            if !outlineMaskFills.isEmpty, let cpuMaskPool {
                fillQueuedMasksLocked(on: cpuMaskPool)
            }
            if let publishedPages, publishedPages.generation == generation { return publishedPages }
            let bases = [pageZero] + overflowPages.map(\.atlas)
            var revisions: [UInt64] = [], rawRevisions: [UInt64] = [], patches: [GlyphAtlasPatch?] = []
            var rawPatches: [GlyphAtlasPatch?] = []
            for i in bases.indices {
                var change = pageChanges[i] ?? PageChange()
                revisions.append(change.revision)
                rawRevisions.append(change.rawRevision)
                patches.append(change.patch)
                rawPatches.append(change.rawPatch)
                if !change.published || !change.rawPublished {
                    change.published = true
                    change.rawPublished = true
                    pageChanges[i] = change
                }
            }
            let snapshot = PageSnapshot(bases: bases, fills: maskPagePlansLocked(bases: bases),
                                revisions: revisions, rawRevisions: rawRevisions, patches: patches, rawPatches: rawPatches, generation: generation)
            publishedPages = snapshot
            return snapshot
        }
    }

    /// Publishes the CPU-painted rows to the next GPU upload and retires their fill recipes.
    private func fillQueuedMasksLocked(on pool: CpuBootPool) {
        let start = RuneExecutionContext.uptimeNanoseconds
        let pageJobs = outlineMaskFills.map { item in
            var job = item
            job.rect.y %= UInt32(targetHeight)
            return job
        }
        let filled = withOutlineStore { pool.fillMasks(pageJobs, store: $0) }
        let covered = RuneExecutionContext.uptimeNanoseconds
        generation &+= 1
        baseGeneration = generation
        savedMaskPlan = nil
        savedPagePlans = nil
        publishedPages = nil
        combinedSnapshot = nil
        for (job, bytes) in zip(outlineMaskFills, filled.masks) {
            let r = job.rect
            let page = Int(r.y) / targetHeight
            let x = Int(r.x), y = Int(r.y) % targetHeight, w = Int(r.z), h = Int(r.w)
            if page == 0 {
                blitWithGutter(into: &pageZero.texels, pageWidth: targetWidth, dstX: x, dstY: y,
                               bw: w, bh: h, bitmap: bytes)
                page0Dirty = page0Dirty.map { (min($0.0, y - 1), max($0.1, y + h + 1)) } ?? (y - 1, y + h + 1)
            } else {
                blitWithGutter(into: &overflowPages[page - 1].atlas.texels, pageWidth: targetWidth,
                               dstX: x, dstY: y, bw: w, bh: h, bitmap: bytes)
                let dirty = overflowPages[page - 1].dirty
                overflowPages[page - 1].dirty = dirty.map { (min($0.0, y - 1), max($0.1, y + h + 1)) } ?? (y - 1, y + h + 1)
            }
            pageChanges[page, default: PageChange()].write(
                SIMD4(x - 1, y - 1, x + w + 1, y + h + 1), generation: generation, raw: true)
        }
        fillStats.masks &+= UInt64(outlineMaskFills.count)
        fillStats.texels &+= filled.texels
        fillStats.coverNs &+= covered - start
        fillStats.copyNs &+= RuneExecutionContext.uptimeNanoseconds - covered
        outlineMaskFills.removeAll(keepingCapacity: true)
    }

    /// Returns a single `R8Atlas` containing all active pages stacked vertically (`width x (height * pageCount)`).
    /// When only page 0 exists, returns `atlas` directly with zero copy.
    public func compositedAtlas() -> R8Atlas {
        lock.withLock { maskPlanLocked()?.cpuAtlas() ?? compositedBaseLocked() }
    }

    private func maskPlanLocked(base: R8Atlas? = nil) -> OutlineMaskPlan? {
        guard !outlineMaskFills.isEmpty else { return nil }
        if let cached = savedMaskPlan, cached.generation == generation { return cached.plan }
        guard let curves = withOutlineStore({ $0.snapshot() }) else { return nil }
        let single = overflowPages.isEmpty
        let plan = OutlineMaskPlan(base: base ?? compositedBaseLocked(), curves: curves,
                                   fills: outlineMaskFills, baseGeneration: single ? rawGlyphRevisionLocked(page: 0) : baseGeneration,
                                   epoch: single ? maskEpochLocked(page: 0) : resetsCount)
        savedMaskPlan = (generation, plan)
        return plan
    }

    private func maskPagePlanLocked(_ page: Int) -> OutlineMaskPlan? {
        guard !outlineMaskFills.isEmpty else { return nil }
        if overflowPages.isEmpty { return maskPlanLocked(base: pageZero) }
        let plans = maskPagePlansLocked(bases: [pageZero] + overflowPages.map(\.atlas))
        return plans.indices.contains(page) ? plans[page] : nil
    }

    private func maskPagePlansLocked(bases: [R8Atlas]) -> [OutlineMaskPlan?] {
        guard !outlineMaskFills.isEmpty else { return [] }
        if bases.count == 1 { return [maskPlanLocked(base: bases[0])] }
        if let saved = savedPagePlans, saved.generation == generation { return saved.plans }
        guard let curves = withOutlineStore({ $0.snapshot() }) else { return [] }
        var perPage = Array(repeating: [QueuedOutlineFill](), count: bases.count)
        for var item in outlineMaskFills {
            let page = Int(item.rect.y) / targetHeight
            item.rect.y -= UInt32(page * targetHeight)
            perPage[page].append(item)
        }
        let plans: [OutlineMaskPlan?] = bases.indices.map { page in
            guard !perPage[page].isEmpty else { return nil }
            return OutlineMaskPlan(base: bases[page], curves: curves, fills: perPage[page],
                                   baseGeneration: rawGlyphRevisionLocked(page: page), epoch: maskEpochLocked(page: page))
        }
        savedPagePlans = (generation, plans)
        return plans
    }

    private func maskEpochLocked(page: Int) -> UInt64 {
        max(outlineResetEpoch, maskPageEpochs[page] ?? 0)
    }

    private func compositedBaseLocked() -> R8Atlas {
        if overflowPages.isEmpty {
            return pageZero
        }
        if let combinedSnapshot, combinedSnapshot.generation == generation {
            return combinedSnapshot.atlas
        }
        let total = 1 + overflowPages.count
        let pageW = max(1, targetWidth)
        let pageH = max(1, targetHeight)
        let pageBytes = pageW * pageH
        var combined = [UInt8](repeating: 0, count: pageBytes * total)
        if backingAllocated && pageZero.width == pageW && pageZero.height == pageH && pageZero.texels.count == pageBytes {
            combined.replaceSubrange(0..<pageBytes, with: pageZero.texels)
        } else if backingAllocated && !pageZero.texels.isEmpty {
            let copyRows = min(pageH, pageZero.height)
            let copyCols = min(pageW, pageZero.width)
            for row in 0..<copyRows {
                let srcStart = row * pageZero.width
                let dstStart = row * pageW
                combined.replaceSubrange(dstStart..<(dstStart + copyCols), with: pageZero.texels[srcStart..<(srcStart + copyCols)])
            }
        }
        for i in overflowPages.indices {
            let pageAtlas = overflowPages[i].atlas
            let dstBase = (i + 1) * pageBytes
            if pageAtlas.width == pageW && pageAtlas.height == pageH && pageAtlas.texels.count == pageBytes {
                combined.replaceSubrange(dstBase..<(dstBase + pageBytes), with: pageAtlas.texels)
            }
        }
        let result = R8Atlas(width: pageW, height: pageH * total, texels: combined)
        combinedSnapshot = (generation, result)
        return result
    }

    /// Dirty row range `[y0, y1)` for a page since the last upload/reset (`atlas.rs:205`).
    public func dirtyRows(_ page: Int) -> (Int, Int)? {
        lock.lock()
        defer { lock.unlock() }
        if page == 0 { return page0Dirty }
        guard page >= 1 && page <= overflowPages.count else { return nil }
        return overflowPages[page - 1].dirty
    }

    /// Changes when a page is added or recycled, invalidating cached placements.
    internal var placementClock: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return clock
    }

    /// Pins the pages of a previously emitted layout before any new mask can recycle them.
    internal func retainPages(_ pages: Set<UInt16>, since resets: UInt64?) -> Bool {
        lock.withLock {
            guard resets == resetsCount else { return false }
            for page in pages { touchLocked(page: page, texels: 0) }
            return true
        }
    }

    /// Pin cached phase variants only if every shelf they reference predates the receipt.
    internal func retainGlyphPlacements(_ pages: UInt8, since generation: UInt64) -> Bool {
        lock.withLock {
            guard outlineResetEpoch <= generation else { return false }
            for page in 0..<Self.maxOverflowPages where pages & (1 << page) != 0 {
                guard maskEpochLocked(page: page) <= generation, page <= overflowPages.count else { return false }
                touchLocked(page: UInt16(page), texels: 0)
            }
            return true
        }
    }

    internal func touchGlyphPlacements(_ texels: SIMD8<UInt32>) {
        lock.withLock {
            for page in 0..<Self.maxOverflowPages where texels[page] != 0 && page <= overflowPages.count {
                touchLocked(page: UInt16(page), texels: texels[page])
            }
        }
    }

    /// Number of shelf page resets since creation (`atlas.rs:258`).
    public var resets: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return resetsCount
    }

    /// Number of glyphs and icons placed into the atlas since creation (`atlas.rs:263`).
    public var rasterized: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return rasterizedCount
    }

    /// Marks every used row on every page for re-upload (`atlas.rs:230`).
    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        page0Dirty = page0Shelf.usedRows()
        for i in overflowPages.indices {
            overflowPages[i].dirty = overflowPages[i].shelf.usedRows()
        }
        generation &+= 1
        baseGeneration = generation
        for page in 0...overflowPages.count {
            let atlas = page == 0 ? pageZero : overflowPages[page - 1].atlas
            pageChanges[page, default: PageChange()].write(SIMD4(0, 0, atlas.width, atlas.height), generation: generation, raw: true)
        }
    }

    /// Marks `page` as used in the current frame (`atlas.rs:299`).
    public func touch(page: UInt16, texels: UInt32 = 0) {
        lock.lock()
        defer { lock.unlock() }
        touchLocked(page: page, texels: texels)
    }

    /// Evicts a single atlas page, clearing cached entries pointing to it and resetting its shelf (`atlas.rs:307`).
    public func evictPage(_ page: Int) {
        lock.lock()
        defer { lock.unlock() }
        evictPageLocked(page)
    }

    /// Advances the frame boundary across pages, reclaiming idle or overflow pages not in `pinnedMask` (`atlas.rs:324`).
    public func beginFrame(pinnedMask: UInt32 = 0) {
        beginFrame(pinnedMask: pinnedMask, pinOutlines: pinnedMask != 0)
    }

    @discardableResult
    internal func beginFrame(pinnedMask: UInt32, pinOutlines: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let recycledOutlines = outlineLock.withLock { outlineStorage?.store.beginFrame(pinned: pinOutlines) == true }
        if recycledOutlines {
            // Captured frames own their immutable curves and atlas-fill plans. New layouts must
            // resolve every old outline-backed placement, even when its page was not recycled.
            #if canImport(CoreText) && canImport(CoreGraphics)
            glyphCache = glyphCache.filter { $0.value.entry.outlineGroup == nil }
            #endif
            #if canImport(CRuneDesktopText) && !canImport(CoreText)
            portableGlyphCache = portableGlyphCache.filter { $0.value.entry.desktopTile == nil }
            #endif
            lcdOutlineMasks.removeAll(keepingCapacity: true)
            outlineMaskFills.removeAll(keepingCapacity: true)
            savedMaskPlan = nil
            savedPagePlans = nil
            clock &+= 1
            resetsCount &+= 1
            outlineResetEpoch = resetsCount
            generation &+= 1
            baseGeneration = generation
        }
        frameSequence &+= 1
        let total = 1 + overflowPages.count
        var totalLive: UInt64 = 0
        for p in 0..<total {
            totalLive += UInt64(shelfLocked(p).liveTexels)
        }
        let halfPage = max(1, UInt64(targetWidth * targetHeight / 2))
        let needed = min(Self.maxOverflowPages, max(Self.maxSteadyPages, Int(totalLive / halfPage) + Self.maxSteadyPages))
        let fullCount = (0..<total).filter { shelfLocked($0).full }.count
        if fullCount >= needed || total > needed {
            let keep = min(needed, total)
            if let oldest = (0..<keep)
                .filter({ p in shelfLocked(p).full && (pinnedMask & (UInt32(1) << min(p, 31))) == 0 })
                .min(by: { shelfLocked($0).age < shelfLocked($1).age }) {
                evictPageLocked(oldest)
            }
            for p in keep..<total {
                if (pinnedMask & (UInt32(1) << min(p, 31))) == 0 && shelfLocked(p).nonEmpty {
                    evictPageLocked(p)
                }
            }
            while 1 + overflowPages.count > needed {
                let last = overflowPages.count
                if (pinnedMask & (UInt32(1) << min(last, 31))) != 0 || shelfLocked(last).nonEmpty {
                    break
                }
                overflowPages.removeLast()
                publishedPages = nil
                pageChanges.removeValue(forKey: last)
                combinedSnapshot = nil
            }
        }
        let finalTotal = 1 + overflowPages.count
        for p in 0..<finalTotal {
            if p == 0 {
                page0Shelf.endFrame()
            } else {
                overflowPages[p - 1].shelf.endFrame()
            }
            if (pinnedMask & (UInt32(1) << min(p, 31))) != 0 {
                touchLocked(page: UInt16(p), texels: 0)
            }
        }
        return recycledOutlines
    }

    /// Drops glyph and icon cache entries older than 1 frame (`GlyphCache::drop_orphans`, `#905`).
    public func dropOrphans() {
        lock.lock()
        defer { lock.unlock() }
        let f = frameSequence
        portableGlyphCache = portableGlyphCache.filter { (f &- $0.value.lastFrame) <= 1 }
        iconCache = iconCache.filter { (f &- $0.value.lastFrame) <= 1 }
        #if canImport(CoreText) && canImport(CoreGraphics)
        glyphCache = glyphCache.filter { (f &- $0.value.lastFrame) <= 1 }
        #endif
        colorGlyphCache = colorGlyphCache.filter { (f &- $0.value.lastFrame) <= 1 }
        var liveIndices = Set<UInt32>()
        var totalBytes = 0
        for v in colorGlyphCache.values {
            liveIndices.insert(v.entry.index)
            totalBytes += v.entry.rgba.count
        }
        colorGlyphByIndex = colorGlyphByIndex.filter { liveIndices.contains($0.key) }
        colorGlyphBytes = totalBytes
    }

    /// Current CPU bytes held by cached RGBA color glyphs (`#807`).
    public var currentColorGlyphBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return colorGlyphBytes
    }

    /// Number of currently cached RGBA color glyphs (`#807`).
    public var colorGlyphEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return colorGlyphCache.count
    }

    /// Looks up a previously emitted color glyph bitmap by its `PositionedGlyph.colorGlyphIndex` (`#807`).
    public func colorGlyph(_ index: UInt32) -> ColorGlyphEntry? {
        lock.lock()
        defer { lock.unlock() }
        return colorGlyphByIndex[index]
    }

    /// True once at least one mask/glyph/icon has triggered CPU backing allocation (`#830`).
    public var hasAllocatedBacking: Bool {
        lock.lock()
        defer { lock.unlock() }
        return backingAllocated
    }

    /// Allocated CPU backing size in bytes (`0` for measure-only `TextSystem`s, `#830`).
    public var allocatedBackingBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return backingAllocated ? pageZero.texels.count : 0
    }

    /// Total cached entries across R8 glyph/icon and RGBA color-glyph tables.
    public var cachedEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        var total = portableGlyphCache.count + iconCache.count + colorGlyphCache.count
        #if canImport(CoreText) && canImport(CoreGraphics)
        total += glyphCache.count
        #endif
        return total
    }

    /// Number of placed icon entries currently cached (`GlyphAtlas::icons`).
    public var cachedIconCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return iconCache.count
    }

    /// Fast cross-launch font identity hash (`#807`: byte length, first/last 64 KiB, and SFNT `head` table).
    public static func fontIdentityHash(_ fontBytes: Data) -> UInt64 {
        let edgeBytes = 64 * 1024
        var h: UInt64 = 0xcbf29ce484222325
        @inline(__always)
        func mixBytes(_ ptr: UnsafeBufferPointer<UInt8>) {
            for b in ptr {
                h ^= UInt64(b)
                h &*= 0x100000001b3
            }
        }
        @inline(__always)
        func mixUInt64(_ v: UInt64) {
            var val = v
            for _ in 0..<8 {
                h ^= val & 0xFF
                h &*= 0x100000001b3
                val >>= 8
            }
        }

        mixUInt64(UInt64(fontBytes.count))
        let frontLen = min(fontBytes.count, edgeBytes)
        let backStart = fontBytes.count > edgeBytes ? (fontBytes.count - edgeBytes) : 0
        fontBytes.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            if frontLen > 0 {
                mixBytes(UnsafeBufferPointer(start: bytes.baseAddress, count: frontLen))
            }
            if backStart < fontBytes.count {
                mixBytes(UnsafeBufferPointer(start: bytes.baseAddress?.advanced(by: backStart), count: fontBytes.count - backStart))
            }
            // SFNT table directory (`numTables` at offset 4, 16-byte records starting at offset 12).
            if bytes.count >= 12 {
                let numTables = (Int(bytes[4]) << 8) | Int(bytes[5])
                let maxRecords = min(numTables, (bytes.count - 12) / 16)
                for i in 0..<maxRecords {
                    let rec = 12 + i * 16
                    // Tag "head" = 0x68 0x65 0x61 0x64
                    if bytes[rec] == 0x68 && bytes[rec + 1] == 0x65 && bytes[rec + 2] == 0x61 && bytes[rec + 3] == 0x64 {
                        let offset = (Int(bytes[rec + 8]) << 24)
                            | (Int(bytes[rec + 9]) << 16)
                            | (Int(bytes[rec + 10]) << 8)
                            | Int(bytes[rec + 11])
                        let length = (Int(bytes[rec + 12]) << 24)
                            | (Int(bytes[rec + 13]) << 16)
                            | (Int(bytes[rec + 14]) << 8)
                            | Int(bytes[rec + 15])
                        if offset >= 0, length > 0, offset + length <= bytes.count {
                            mixBytes(UnsafeBufferPointer(start: bytes.baseAddress?.advanced(by: offset), count: length))
                        }
                        break
                    }
                }
            }
        }
        return h
    }

    #if canImport(CRuneDesktopText) && !canImport(CoreText)
    internal var desktopTileSize: SIMD2<Int> {
        SIMD2(max(1, min(256, targetWidth - 2)), max(1, min(128, targetHeight - 2)))
    }

    /// Native shapers rasterize a run in one tile. Each grapheme's ink may occupy a different
    /// vertical interval, independent of how tall its neighbors made the shared tile.
    internal func desktopCoveredRows(of entry: Entry, columns: Range<Int>) -> Range<Int>? {
        if let tile = entry.desktopTile {
            return withOutlineStore { store in
                guard tile.generation == store.generation else { return nil }
                return tile.coveredRows(columns: columns, store: store)
            }
        }
        lock.lock()
        defer { lock.unlock() }
        let page = Int(entry.page)
        guard page <= overflowPages.count else { return nil }
        let source = page == 0 ? pageZero : overflowPages[page - 1].atlas
        let x = entry.pixelOrigin.x + columns.lowerBound
        let y = entry.pixelOrigin.y
        let rows = 0..<entry.pixelSize.y
        guard !rows.isEmpty, !columns.isEmpty, ((y + rows.count - 1) * source.width + x + columns.count) <= source.texels.count else {
            return nil
        }
        func hasCoverage(_ row: Int) -> Bool {
            let start = (y + row) * source.width + x
            return source.texels[start..<(start + columns.count)].contains { $0 != 0 }
        }
        guard let first = rows.first(where: hasCoverage), let last = rows.last(where: hasCoverage) else { return nil }
        return first..<(last + 1)
    }

    internal func desktopColor(key: DesktopMaskKey?, width: Int, height: Int,
                               bitmap: () -> Data?) -> ColorGlyphEntry? {
        let key = key.map { ColorGlyphKey.desktop($0, width: width, height: height) }
        if let key, let cached = lock.withLock({ cachedColorGlyphLocked(key) }) { return cached }
        guard let pixels = bitmap() else { return nil }
        return storeColorGlyph(key: key, size: SIMD2(width, height), bearing: .zero, pixels: pixels)
    }

    internal func desktopMask(key: DesktopMaskKey?, width: Int, height: Int,
                              deferredTile: () -> DesktopOutlineTile? = { nil }, bitmap: () -> [UInt8]?) -> Entry? {
        let cacheKey = key.map(PortableGlyphKey.desktop)
        lock.lock()
        defer { lock.unlock() }
        if let cacheKey, var cached = portableGlyphCache[cacheKey] {
            accessCounter &+= 1
            cached.lastUsed = accessCounter
            cached.lastFrame = frameSequence
            portableGlyphCache[cacheKey] = cached
            touchLocked(page: cached.entry.page, texels: UInt32(width * height))
            return cached.entry
        }
        let tile = deferOutlineMasks ? deferredTile() : nil
        let fill = tile.flatMap { tile in withOutlineStore { $0.fill(for: tile) } }
        let coverage: [UInt8]?
        if fill != nil {
            coverage = nil
        } else {
            guard let pixels = bitmap() else { return nil }
            coverage = pixels
        }
        guard let placed = allocateAndBlit(width: width, height: height, bitmap: coverage) else { return nil }
        var entry = Entry(uv: placed.uv, pixelSize: SIMD2(width, height), bearingPx: .zero,
                          page: placed.page, pixelOrigin: placed.origin)
        if let fill {
            entry.desktopTile = tile
            let crop = tile?.components.count == 1 ? tile?.components.first?.rect : nil
            queueMaskLocked(entry, fill: fill, crop: crop)
        }
        if let cacheKey {
            accessCounter &+= 1
            portableGlyphCache[cacheKey] = (entry, accessCounter, frameSequence)
            evictLRUIfNeededLocked()
        }
        return entry
    }
    #endif

    public func rasterizePortableGlyph(
        scalar: UnicodeScalar,
        fontSizePx: Float,
        bold: Bool = false,
        italic: Bool = false,
        smoothing: FontSmoothing = .systemDefault
    ) -> Entry {
        let key = PortableGlyphKey.bitmap(
            scalar: scalar.value,
            sizePx10: Int((fontSizePx * 10.0).rounded()),
            bold: bold,
            italic: italic,
            smoothing: smoothing
        )
        lock.lock()
        if var cached = portableGlyphCache[key] {
            accessCounter &+= 1
            cached.lastUsed = accessCounter
            cached.lastFrame = frameSequence
            portableGlyphCache[key] = cached
            touchLocked(page: cached.entry.page, texels: UInt32(cached.entry.pixelSize.x * cached.entry.pixelSize.y))
            lock.unlock()
            return cached.entry
        }
        lock.unlock()

        let r = PortableGlyphFont.rasterizeScaled(
            scalar: scalar,
            fontSizePx: fontSizePx,
            bold: bold,
            italic: italic
        )
        lock.lock()
        guard let placed = allocateAndBlit(width: r.width, height: r.height, bitmap: r.bitmap) else {
            lock.unlock()
            return Entry(uv: .zero, pixelSize: SIMD2<Int>(r.width, r.height), bearingPx: SIMD2<Float>(0, r.bearingY))
        }
        let entry = Entry(
            uv: placed.uv,
            pixelSize: SIMD2<Int>(r.width, r.height),
            bearingPx: SIMD2<Float>(0, r.bearingY),
            page: placed.page,
            pixelOrigin: placed.origin
        )
        accessCounter &+= 1
        portableGlyphCache[key] = (entry, accessCounter, frameSequence)
        evictLRUIfNeededLocked()
        lock.unlock()
        return entry
    }

    #if canImport(CoreText) && canImport(CoreGraphics)
    /// True when `font` contains color outline/bitmap tables (`COLR`, `CBDT`, `sbix`) or color traits (`#807`).
    public static func isColorFont(_ font: CTFont) -> Bool {
        if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) {
            return true
        }
        // "COLR" (0x434F4C52), "CBDT" (0x43424454), "sbix" (0x73626978)
        let opt = CTFontTableOptions(rawValue: 0)
        return CTFontCopyTable(font, CTFontTableTag(0x434F4C52), opt) != nil
            || CTFontCopyTable(font, CTFontTableTag(0x43424454), opt) != nil
            || CTFontCopyTable(font, CTFontTableTag(0x73626978), opt) != nil
    }

    func rasterizeColorGlyph(font: CTFont, glyph: CGGlyph, fontSizePx: Float) -> ColorGlyphEntry? {
        let key = ColorGlyphKey.coreText(
            fontHash: CFHash(font),
            glyphID: glyph,
            sizePx10: Int((fontSizePx * 10.0).rounded())
        )
        if let cached = lock.withLock({ cachedColorGlyphLocked(key) }) { return cached }

        var g = glyph
        var bbox = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &g, &bbox, 1)
        if bbox.isEmpty || bbox.width <= 0 || bbox.height <= 0 {
            return nil
        }

        let pad = 2
        let minX = Int(floor(bbox.minX)) - pad
        let minY = Int(floor(bbox.minY)) - pad
        let maxX = Int(ceil(bbox.maxX)) + pad
        let maxY = Int(ceil(bbox.maxY)) + pad
        let bw = max(1, maxX - minX)
        let bh = max(1, maxY - minY)

        var rgba = Data(count: bw * bh * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bi = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: bw,
                      height: bh,
                      bitsPerComponent: 8,
                      bytesPerRow: bw * 4,
                      space: cs,
                      bitmapInfo: bi.rawValue
                  ) else {
                return false
            }
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            var pos = CGPoint(x: CGFloat(-minX), y: CGFloat(-minY))
            CTFontDrawGlyphs(font, &g, &pos, 1, ctx)
            return true
        }
        guard drawn else { return nil }

        return storeColorGlyph(key: key, size: SIMD2(bw, bh),
                               bearing: SIMD2(Float(minX), Float(-maxY)), pixels: rgba)
    }

    func rasterizeGlyph(
        font: CTFont,
        glyph: CGGlyph,
        fontSizePx: Float,
        phaseX: UInt8 = 0,
        subpixelYBin: UInt8 = 0,
        smoothing: FontSmoothing = .systemDefault,
        inkBucket requestedBucket: UInt8 = 0
    ) -> Entry? {
        let binY = subpixelYBin & 3
        let subShift = Float(phaseX) / TextCoreTextMatch.phases
        let shiftY = Float(binY) * 0.25
        let mode = smoothing == .systemDefault ? FontSmoothing.platformDefault : smoothing
        let classic = mode == .on || mode == .off
        let dilate = classic && mode.pipeline.dilate
        let inkBucket = smoothing == .windfoil || dilate ? Self.dilationBucket(requestedBucket, ppem: fontSizePx) : 0
        let key = GlyphKey(
            fontHash: CFHash(font),
            glyphID: glyph,
            sizePx10: Int((fontSizePx * 10.0).rounded()),
            subpixelBin: phaseX,
            subpixelYBin: binY,
            smoothing: smoothing,
            inkBucket: inkBucket
        )
        lock.lock()
        if var cached = glyphCache[key] {
            accessCounter &+= 1
            cached.lastUsed = accessCounter
            cached.lastFrame = frameSequence
            glyphCache[key] = cached
            touchLocked(page: cached.entry.page, texels: UInt32(cached.entry.pixelSize.x * cached.entry.pixelSize.y))
            lock.unlock()
            return cached.entry
        }
        lock.unlock()

        if phaseX != 0, smoothing.isOutlineMode,
           outlineLock.withLock({ outlines.usesWholePen(font: font, ppem: fontSizePx, smoothing: smoothing) }) {
            // Windfoil's whole pens share one mask for all x phases; the upper half moves
            // its quad one pixel. Use the same placement when CoreText supplies the mask.
            guard var placed = rasterizeGlyph(font: font, glyph: glyph, fontSizePx: fontSizePx,
                                              phaseX: 0, subpixelYBin: binY, smoothing: smoothing,
                                              inkBucket: inkBucket) else { return nil }
            if placed.pixelSize.x > 0 && Float(phaseX) >= TextCoreTextMatch.phases / 2 {
                placed.bearingPx.x += 1
            }
            lock.withLock {
                if let group = placed.outlineGroup, group.generation != withOutlineStore({ $0.generation }) { return }
                accessCounter &+= 1
                glyphCache[key] = (placed, accessCounter, frameSequence)
                evictLRUIfNeededLocked()
            }
            return placed
        }

        if classic, let mask = outlineLock.withLock({
            classicGlyphs.mask(font: font, glyph: glyph, ppem: fontSizePx, phase: subShift, shiftY: shiftY,
                               pipeline: mode.pipeline, bucket: inkBucket, maximumSide: Self.atlasSize)
        }) {
            return lock.withLock {
                if let cached = glyphCache[key] { return cached.entry }
                var entry = Entry(uv: .zero, pixelSize: .zero, bearingPx: .zero)
                if mask.bytes.contains(where: { $0 != 0 }) {
                    guard let placed = allocateAndBlit(width: mask.width, height: mask.height, bitmap: mask.bytes) else { return nil }
                    entry = Entry(uv: placed.uv, pixelSize: SIMD2(mask.width, mask.height), bearingPx: mask.bearing,
                                  page: placed.page, pixelOrigin: placed.origin)
                    if dilate {
                        let source = TextOutlineGroup.InkVariant(font: font, glyph: glyph, ppem: fontSizePx,
                            phase: phaseX, yPhase: binY, bucket: inkBucket, bearing: mask.bearing)
                        entry.classicInk = .init(source: source, size: SIMD2(Float(mask.width), Float(mask.height)), smoothing: mode)
                    }
                }
                accessCounter &+= 1
                glyphCache[key] = (entry, accessCounter, frameSequence)
                evictLRUIfNeededLocked()
                return entry
            }
        }

        let deferred = smoothing.isOutlineMode && lock.withLock { deferOutlineMasks }
        if smoothing.isOutlineMode, let mask = outlineLock.withLock({
            outlines.mask(font: font, glyph: glyph, ppem: fontSizePx, smoothing: smoothing,
                          phase: subShift, shiftY: shiftY, inkBucket: inkBucket,
                          maximumSide: Self.atlasSize, deferred: deferred)
        }) {
            if let entry: Entry = lock.withLock({
                if let cached = glyphCache[key] { return cached.entry }
                guard mask.group.generation == withOutlineStore({ $0.generation }) else { return nil }
                let start = RuneExecutionContext.uptimeNanoseconds
                guard let placed = allocateAndBlit(width: mask.width, height: mask.height, bitmap: mask.bytes) else {
                    return nil
                }
                var entry = Entry(uv: placed.uv, pixelSize: SIMD2(mask.width, mask.height),
                                  bearingPx: mask.bearing, page: placed.page, pixelOrigin: placed.origin)
                entry.outlineGroup = mask.group
                if mask.bytes == nil {
                    queueMaskLocked(entry, fill: mask.fill)
                } else {
                    fillStats.masks &+= 1
                    fillStats.texels &+= UInt64(mask.width * mask.height)
                    fillStats.coverNs &+= mask.coverNs
                    fillStats.copyNs &+= RuneExecutionContext.uptimeNanoseconds - start
                }
                accessCounter &+= 1
                glyphCache[key] = (entry, accessCounter, frameSequence)
                evictLRUIfNeededLocked()
                return entry
            }) { return entry }
        }

        var g = glyph
        var bbox = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &g, &bbox, 1)
        if bbox.isEmpty || bbox.width <= 0.01 || bbox.height <= 0.01 {
            let empty = Entry(uv: .zero, pixelSize: .zero, bearingPx: .zero)
            lock.lock()
            accessCounter &+= 1
            glyphCache[key] = (empty, accessCounter, frameSequence)
            evictLRUIfNeededLocked()
            lock.unlock()
            return empty
        }

        let pad = 2
        let minX = Int(floor(bbox.minX)) - pad
        let maxX = Int(ceil(bbox.maxX)) + pad
        let minY = Int(floor(bbox.minY)) - pad
        let maxY = Int(ceil(bbox.maxY)) + pad
        let baseBw = max(1, maxX - minX)
        let baseBh = max(1, maxY - minY)

        var baseBitmap = Array<UInt8>(repeating: 0, count: baseBw * baseBh)
        let graySpace = CGColorSpaceCreateDeviceGray()
        let drawn = baseBitmap.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: baseBw,
                height: baseBh,
                bitsPerComponent: 8,
                bytesPerRow: baseBw,
                space: graySpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }

            // `.on` respects the user's AppleFontSmoothing setting (#954).
            let allowFontSmoothing = smoothing.pipeline.dilate
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            ctx.setAllowsFontSmoothing(allowFontSmoothing)
            ctx.setShouldSmoothFonts(allowFontSmoothing)
            ctx.setAllowsFontSubpixelPositioning(true)
            ctx.setShouldSubpixelPositionFonts(true)
            ctx.setAllowsFontSubpixelQuantization(false)
            ctx.setShouldSubpixelQuantizeFonts(false)
            ctx.setFillColor(gray: 1.0, alpha: 1.0)

            // Draw the outline at its actual X phase. Translating a mask drawn at phase zero
            // filters its edges twice and lightens narrow stems.
            var pos = CGPoint(x: CGFloat(-minX) + CGFloat(subShift), y: CGFloat(-minY))
            CTFontDrawGlyphs(font, &g, &pos, 1, ctx)
            return true
        }
        guard drawn else { return nil }
        let bw = baseBw
        let bh = binY == 0 ? baseBh : baseBh + 1
        let bitmap: [UInt8]
        if binY == 0 {
            bitmap = baseBitmap
        } else {
            // CoreGraphics pins a baseline to a whole row. Retain vertical glide phases
            // between those rows.
            var shifted = Array<UInt8>(repeating: 0, count: bw * bh)
            for y in 0..<bh {
                for x in 0..<bw {
                    let above = y == 0 ? 0 : Float(baseBitmap[(y - 1) * bw + x])
                    let current = y == baseBh ? 0 : Float(baseBitmap[y * bw + x])
                    shifted[y * bw + x] = UInt8((current * (1 - shiftY) + above * shiftY).rounded())
                }
            }
            bitmap = shifted
        }

        lock.lock()
        guard let placed = allocateAndBlit(width: bw, height: bh, bitmap: bitmap) else {
            lock.unlock()
            return nil
        }
        // CoreGraphics row 0 in `bitmap` is the TOP row (`y = maxY` above baseline)!
        let entry = Entry(
            uv: placed.uv,
            pixelSize: SIMD2<Int>(bw, bh),
            bearingPx: SIMD2<Float>(Float(minX), Float(-maxY)),
            page: placed.page,
            pixelOrigin: placed.origin
        )
        accessCounter &+= 1
        glyphCache[key] = (entry, accessCounter, frameSequence)
        evictLRUIfNeededLocked()
        lock.unlock()
        return entry
    }
    #endif

    public static func rasterizeIconBitmap(_ icon: SVGIcon, pixelSize: Int, drawnSize: Float? = nil) -> [UInt8] {
        let px = max(1, pixelSize)
        return GaneshIcon.coverageAt(icon, pixelSize: px, drawnSize: drawnSize, origin: .zero)
    }

    public func rasterizeIconIfPlaced(_ icon: SVGIcon, pixelSize: Int, drawnSize: Float? = nil, mirrored: Bool = false) -> Entry? {
        let px = drawnSize != nil ? max(1, pixelSize) : max(4, pixelSize)
        let q: UInt8
        let rasterDrawn: Float?
        if let d = drawnSize {
            let clamped = min(Float(px), max(1e-4, d))
            q = UInt8(min(63, max(0, Int(((Float(px) - clamped) * 64.0).rounded()))))
            rasterDrawn = Float(px) - Float(q) / 64.0
        } else {
            q = 0
            rasterDrawn = nil
        }
        let key = IconKey(icon: icon, pixelSize: px, drawnSixtyFourths: q, mirrored: mirrored)
        lock.lock()
        if var cached = iconCache[key] {
            accessCounter &+= 1
            cached.lastUsed = accessCounter
            cached.lastFrame = frameSequence
            iconCache[key] = cached
            touchLocked(page: cached.entry.page, texels: UInt32(cached.entry.pixelSize.x * cached.entry.pixelSize.y))
            lock.unlock()
            return cached.entry
        }
        lock.unlock()

        var bitmap = Self.rasterizeIconBitmap(icon, pixelSize: px, drawnSize: rasterDrawn)
        guard bitmap.contains(where: { $0 != 0 }) else {
            return nil
        }
        if mirrored && px > 1 && bitmap.count >= px * px {
            for row in 0..<px {
                let rowBase = row * px
                for col in 0..<(px / 2) {
                    let a = rowBase + col
                    let b = rowBase + (px - 1 - col)
                    bitmap.swapAt(a, b)
                }
            }
        }

        lock.lock()
        guard let placed = allocateAndBlit(width: px, height: px, bitmap: bitmap) else {
            lock.unlock()
            return nil
        }
        let entry = Entry(
            uv: placed.uv,
            pixelSize: SIMD2<Int>(px, px),
            bearingPx: .zero,
            page: placed.page,
            pixelOrigin: placed.origin
        )
        accessCounter &+= 1
        iconCache[key] = (entry, accessCounter, frameSequence)
        evictLRUIfNeededLocked()
        lock.unlock()
        return entry
    }

    public func rasterizeIcon(_ icon: SVGIcon, pixelSize: Int, drawnSize: Float? = nil, mirrored: Bool = false) -> Entry {
        let px = drawnSize != nil ? max(1, pixelSize) : max(4, pixelSize)
        return rasterizeIconIfPlaced(icon, pixelSize: pixelSize, drawnSize: drawnSize, mirrored: mirrored)
            ?? Entry(uv: .zero, pixelSize: SIMD2<Int>(px, px), bearingPx: .zero)
    }

    private func shelfLocked(_ page: Int) -> ShelfState {
        page == 0 ? page0Shelf : overflowPages[page - 1].shelf
    }

    private func touchLocked(page: UInt16, texels: UInt32) {
        if page == 0 {
            page0Shelf.touch(texels: texels)
        } else {
            let idx = Int(page) - 1
            if idx >= 0 && idx < overflowPages.count {
                overflowPages[idx].shelf.touch(texels: texels)
            }
        }
    }

    private func evictPageLocked(_ page: Int) {
        if !outlineMaskFills.isEmpty {
            outlineMaskFills.removeAll { Int($0.rect.y) / targetHeight == page }
            savedMaskPlan = nil
        }
        let p16 = UInt16(page)
        if !lcdOutlineMasks.isEmpty { lcdOutlineMasks = lcdOutlineMasks.filter { $0.value.page != p16 } }
        #if canImport(CoreText) && canImport(CoreGraphics)
        glyphCache = glyphCache.filter { $0.value.entry.page != p16 }
        #endif
        portableGlyphCache = portableGlyphCache.filter { key, cached in
            #if os(Windows)
            if case .windowsMask(let sourcePage, _, _, _) = key, sourcePage == p16 { return false }
            #endif
            return cached.entry.page != p16
        }
        iconCache = iconCache.filter { $0.value.entry.page != p16 }
        clock &+= 1
        resetsCount &+= 1
        maskPageEpochs[page] = resetsCount
        let age = clock
        if page == 0 {
            page0Dirty = nil
            page0Shelf.reset(age: age)
        } else if page >= 1 && page <= overflowPages.count {
            overflowPages[page - 1].dirty = nil
            overflowPages[page - 1].shelf.reset(age: age)
        }
        generation &+= 1
        baseGeneration = generation
        // Drop previous patch ancestry when a shelf starts over.
        pageChanges[page] = PageChange(revision: generation, rawRevision: generation)
    }

    private func ensureBackingLocked() {
        if !backingAllocated {
            pageZero = R8Atlas(width: targetWidth, height: targetHeight)
            backingAllocated = true
        }
    }

    #if os(Windows)
    /// Several glyph quads can sample one native tile. Correct the whole tile
    /// once per ink bucket so filtered glyphs still sample their actual neighbors.
    fileprivate func windowsMask(_ tile: SIMD4<Int32>, sourcePage: UInt16, bucket: UInt8, lcd: WindowsGlyphMask? = nil) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        let key = PortableGlyphKey.windowsMask(sourcePage: sourcePage, tile: tile, bucket: bucket, lcd: lcd != nil)
        if var cached = portableGlyphCache[key] {
            accessCounter &+= 1
            cached.lastUsed = accessCounter
            cached.lastFrame = frameSequence
            portableGlyphCache[key] = cached
            touchLocked(page: cached.entry.page, texels: 0)
            return cached.entry
        }
        let page = Int(sourcePage)
        guard page <= overflowPages.count else { return nil }
        let x = Int(tile.x), y = Int(tile.y), w = Int(tile.z), h = Int(tile.w)
        let table = WindowsTextGamma.tables[Int(bucket)]
        let packedWidth = w * (lcd == nil ? 1 : 3)
        guard packedWidth + 2 <= targetWidth else { return nil }
        var pixels: [UInt8]
        if let lcd {
            guard var rgb = lcd.rgb?(), rgb.count == packedWidth * h else { return nil }
            for i in rgb.indices { rgb[i] = table[Int(rgb[i])] }
            pixels = rgb
        } else {
            pixels = []
            pixels.reserveCapacity(w * h)
            let source = page == 0 ? pageZero : overflowPages[page - 1].atlas
            guard x >= 0, y >= 0, w > 0, h > 0, x + w <= source.width,
                  (y + h - 1) * source.width + x + w <= source.texels.count else { return nil }
            for row in y..<(y + h) {
                let start = row * source.width + x
                for c in source.texels[start..<(start + w)] { pixels.append(table[Int(c)]) }
            }
        }
        touchLocked(page: sourcePage, texels: 0)
        guard let placed = allocateAndBlit(width: packedWidth, height: h, bitmap: pixels) else { return nil }
        let entry = Entry(uv: placed.uv, pixelSize: SIMD2(packedWidth, h), bearingPx: .zero,
                          page: placed.page, pixelOrigin: placed.origin)
        accessCounter &+= 1
        portableGlyphCache[key] = (entry, accessCounter, frameSequence)
        evictLRUIfNeededLocked()
        return entry
    }
    #endif

    private func placeLocked(width bw: Int, height bh: Int) -> (page: Int, x: Int, y: Int)? {
        guard bw > 0, bh > 0, bw + 2 <= targetWidth, bh + 2 <= targetHeight else {
            return nil
        }
        let total = 1 + overflowPages.count

        // 1. Non-full pages first.
        for p in 0..<total {
            if !shelfLocked(p).full {
                let pos: (Int, Int)?
                if p == 0 {
                    pos = page0Shelf.alloc(w: bw, h: bh)
                } else {
                    pos = overflowPages[p - 1].shelf.alloc(w: bw, h: bh)
                }
                if let (x, y) = pos {
                    if p == 0 { ensureBackingLocked() }
                    return (p, x, y)
                }
            }
        }
        // 2. Shelf tails on full pages for small glyphs before opening or resetting a page.
        for p in 0..<total {
            let pos: (Int, Int)?
            if p == 0 {
                pos = page0Shelf.alloc(w: bw, h: bh)
            } else {
                pos = overflowPages[p - 1].shelf.alloc(w: bw, h: bh)
            }
            if let (x, y) = pos {
                if p == 0 { ensureBackingLocked() }
                return (p, x, y)
            }
        }
        // 3. Recycle an idle page (untouched in both the last frame and this frame).
        if let p = (0..<total)
            .filter({ p in
                let s = shelfLocked(p)
                return s.used == .idle && s.nonEmpty
            })
            .min(by: { shelfLocked($0).age < shelfLocked($1).age }) {
            evictPageLocked(p)
            let pos = p == 0 ? page0Shelf.alloc(w: bw, h: bh) : overflowPages[p - 1].shelf.alloc(w: bw, h: bh)
            if let (x, y) = pos {
                if p == 0 { ensureBackingLocked() }
                return (p, x, y)
            }
        }
        // 4. Steady-state page pair reached: recycle the oldest page not touched this frame.
        if total >= Self.maxSteadyPages,
           let p = (0..<total)
            .filter({ p in
                let s = shelfLocked(p)
                return s.used != .thisFrame && s.nonEmpty
            })
            .min(by: { shelfLocked($0).age < shelfLocked($1).age }) {
            evictPageLocked(p)
            let pos = p == 0 ? page0Shelf.alloc(w: bw, h: bh) : overflowPages[p - 1].shelf.alloc(w: bw, h: bh)
            if let (x, y) = pos {
                if p == 0 { ensureBackingLocked() }
                return (p, x, y)
            }
        }
        // 5. Grow overflow page up to MAX_OVERFLOW_PAGES.
        if total < Self.maxOverflowPages {
            clock &+= 1
            var newPage = AtlasPageState(width: targetWidth, height: targetHeight, age: clock)
            if let (x, y) = newPage.shelf.alloc(w: bw, h: bh) {
                overflowPages.append(newPage)
                return (overflowPages.count, x, y)
            }
        }
        // Every page is referenced this frame; leave unplaced rather than overwriting emitted quads.
        return nil
    }

    private func allocateAndBlit(width bw: Int, height bh: Int, bitmap: [UInt8]?) -> (uv: SIMD4<Float>, page: UInt16, origin: SIMD2<Int>)? {
        guard let (page, dstX, dstY) = placeLocked(width: bw, height: bh) else {
            return nil
        }

        publishedPages = nil
        savedMaskPlan = nil
        savedPagePlans = nil
        let pageW: Int
        let pageH: Int
        if page == 0 {
            pageW = pageZero.width
            pageH = pageZero.height
            if let bitmap { blitWithGutter(into: &pageZero.texels, pageWidth: pageW, dstX: dstX, dstY: dstY, bw: bw, bh: bh, bitmap: bitmap) }
            let d = (dstY - 1, dstY + bh + 1)
            page0Dirty = page0Dirty.map { (min($0.0, d.0), max($0.1, d.1)) } ?? d
        } else {
            let idx = page - 1
            pageW = overflowPages[idx].atlas.width
            pageH = overflowPages[idx].atlas.height
            if let bitmap { blitWithGutter(into: &overflowPages[idx].atlas.texels, pageWidth: pageW, dstX: dstX, dstY: dstY, bw: bw, bh: bh, bitmap: bitmap) }
            let d = (dstY - 1, dstY + bh + 1)
            overflowPages[idx].dirty = overflowPages[idx].dirty.map { (min($0.0, d.0), max($0.1, d.1)) } ?? d
        }

        rasterizedCount &+= 1
        touchLocked(page: UInt16(page), texels: UInt32(bw * bh))
        generation &+= 1
        if bitmap != nil { baseGeneration = generation }
        pageChanges[page, default: PageChange()].write(
            SIMD4(dstX - 1, dstY - 1, dstX + bw + 1, dstY + bh + 1), generation: generation, raw: bitmap != nil
        )

        let invW = 1.0 / Float(pageW)
        let invH = 1.0 / Float(pageH)
        let uv = SIMD4<Float>(
            Float(dstX) * invW,
            Float(dstY) * invH,
            Float(dstX + bw) * invW,
            Float(dstY + bh) * invH
        )
        return (uv, UInt16(page), SIMD2<Int>(dstX, dstY))
    }

    private func queueMaskLocked(_ entry: Entry, fill: OutlineFillParams, crop: SIMD4<Int>? = nil) {
        let y = Int(entry.page) * targetHeight + entry.pixelOrigin.y
        let rect = SIMD4(UInt32(entry.pixelOrigin.x), UInt32(y), UInt32(entry.pixelSize.x), UInt32(entry.pixelSize.y))
        var job = QueuedOutlineFill(rect: rect, fill: fill)
        job.crop = crop
        outlineMaskFills.append(job)
    }

    /// Places a gray or RGB coverage recipe. CPU users get a complete bitmap
    /// immediately; an attached GPU can rasterize the same mask when first read.
    internal func placeOutlineMask(width: Int, height: Int, fill: OutlineFillParams) -> Entry? {
        guard width > 0 && height > 0 && width <= targetWidth - 2 && height <= targetHeight - 2 else { return nil }
        let deferred = lock.withLock { deferOutlineMasks }
        let start = deferred ? 0 : RuneExecutionContext.uptimeNanoseconds
        let bytes: [UInt8]? = deferred ? nil : withOutlineStore { store in
            OutlineMaskFiller.fillMask(store: store, fill: fill, atX: 0, atY: 0,
                                       width: UInt32(width), height: UInt32(height))
        }
        return lock.withLock {
            let copyStart = deferred ? 0 : RuneExecutionContext.uptimeNanoseconds
            guard let placed = allocateAndBlit(width: width, height: height, bitmap: bytes) else { return nil }
            let entry = Entry(uv: placed.uv, pixelSize: SIMD2(width, height), bearingPx: .zero,
                              page: placed.page, pixelOrigin: placed.origin)
            if deferred {
                queueMaskLocked(entry, fill: fill)
            } else {
                fillStats.masks &+= 1
                fillStats.texels &+= UInt64(width * height)
                fillStats.coverNs &+= copyStart - start
                fillStats.copyNs &+= RuneExecutionContext.uptimeNanoseconds - copyStart
            }
            return entry
        }
    }
    /// Each displayed RGB pixel samples three adjacent R8 texels. Warm draws keep the
    /// tripled-width tile until its page or outline generation is recycled.
    internal func lcdMask(for group: TextOutlineGroup) -> Entry? {
        guard group.glyphs.count == 1, let part = group.glyphs.first,
              part.outline.coverage == 2, part.rect == SIMD4(0, 0, group.size.x, group.size.y),
              let w = Int(exactly: group.size.x), let h = Int(exactly: group.size.y),
              w > 0, w <= (targetWidth - 2) / 3, h > 0, h <= targetHeight - 2 else { return nil }
        let o = part.outline
        let key = TextOutlineMaskKey(generation: group.generation, record: o.record, hint: o.hint, size: SIMD2(w, h),
                                     pen: o.pen, scale: o.scale, radius: o.radius)
        return lock.withLock {
            if let hit = lcdOutlineMasks[key] {
                touchLocked(page: hit.page, texels: UInt32(w * h * 3))
                return hit
            }
            let fill = OutlineFillParams(record: o.record, hint: o.hint, scale: o.scale, radius: o.radius,
                                         pen: SIMD2(3 * o.pen.x, o.pen.y), coverage: 3)
            let start = RuneExecutionContext.uptimeNanoseconds
            let mask: (valid: Bool, bytes: [UInt8]?) = withOutlineStore { store in
                guard store.generation == group.generation else { return (false, nil) }
                return (true, deferOutlineMasks ? nil : OutlineMaskFiller.fillMask(store: store, fill: fill, atX: 0, atY: 0,
                                        width: UInt32(w * 3), height: UInt32(h)))
            }
            let covered = RuneExecutionContext.uptimeNanoseconds
            guard mask.valid, let placed = allocateAndBlit(width: w * 3, height: h, bitmap: mask.bytes) else { return nil }
            let entry = Entry(uv: placed.uv, pixelSize: SIMD2(w * 3, h), bearingPx: .zero,
                              page: placed.page, pixelOrigin: placed.origin)
            if mask.bytes == nil {
                queueMaskLocked(entry, fill: fill)
            } else {
                fillStats.masks &+= 1
                fillStats.texels &+= UInt64(w * h * 3)
                fillStats.coverNs &+= covered - start
                fillStats.copyNs &+= RuneExecutionContext.uptimeNanoseconds - covered
            }
            lcdOutlineMasks[key] = entry
            return entry
        }
    }

    /// Directly packs an arbitrary R8 mask onto the shelf pages (matching `Atlas::put` in `atlas.rs:429`).
    public func placeMask(width bw: Int, height bh: Int, bitmap: [UInt8]) -> Entry? {
        guard bw > 0, bh > 0, bitmap.count >= bw * bh else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let placed = allocateAndBlit(width: bw, height: bh, bitmap: bitmap) else {
            return nil
        }
        return Entry(
            uv: placed.uv,
            pixelSize: SIMD2<Int>(bw, bh),
            bearingPx: .zero,
            page: placed.page,
            pixelOrigin: placed.origin
        )
    }

    private func blitWithGutter(
        into texels: inout [UInt8],
        pageWidth: Int,
        dstX: Int,
        dstY: Int,
        bw: Int,
        bh: Int,
        bitmap: [UInt8]
    ) {
        let x0 = dstX - 1
        let x1 = dstX + bw + 1
        let topRow = (dstY - 1) * pageWidth
        for c in x0..<x1 {
            texels[topRow + c] = 0
        }
        for row in 0..<bh {
            let srcStart = row * bw
            let line = (dstY + row) * pageWidth
            texels[line + x0] = 0
            for col in 0..<bw {
                texels[line + dstX + col] = bitmap[srcStart + col]
            }
            texels[line + dstX + bw] = 0
        }
        let botRow = (dstY + bh) * pageWidth
        for c in x0..<x1 {
            texels[botRow + c] = 0
        }
    }

    private func evictLRUIfNeededLocked() {
        var total = portableGlyphCache.count + iconCache.count + colorGlyphCache.count
        #if canImport(CoreText) && canImport(CoreGraphics)
        total += glyphCache.count
        #endif
        while total > maxCachedEntries {
            enum Victim {
                case portable(PortableGlyphKey, UInt64)
                case icon(IconKey, UInt64)
                case color(ColorGlyphKey, UInt64)
                #if canImport(CoreText) && canImport(CoreGraphics)
                case glyph(GlyphKey, UInt64)
                #endif
                var seq: UInt64 {
                    switch self {
                    case .portable(_, let s), .icon(_, let s), .color(_, let s): return s
                    #if canImport(CoreText) && canImport(CoreGraphics)
                    case .glyph(_, let s): return s
                    #endif
                    }
                }
            }
            var oldest: Victim?
            for (k, v) in portableGlyphCache {
                if oldest == nil || v.lastUsed < oldest!.seq { oldest = .portable(k, v.lastUsed) }
            }
            for (k, v) in iconCache {
                if oldest == nil || v.lastUsed < oldest!.seq { oldest = .icon(k, v.lastUsed) }
            }
            #if canImport(CoreText) && canImport(CoreGraphics)
            for (k, v) in glyphCache {
                if oldest == nil || v.lastUsed < oldest!.seq { oldest = .glyph(k, v.lastUsed) }
            }
            #endif
            for (k, v) in colorGlyphCache {
                if oldest == nil || v.lastUsed < oldest!.seq { oldest = .color(k, v.lastUsed) }
            }
            guard let victim = oldest else { break }
            switch victim {
            case .portable(let k, _): portableGlyphCache.removeValue(forKey: k)
            case .icon(let k, _): iconCache.removeValue(forKey: k)
            #if canImport(CoreText) && canImport(CoreGraphics)
            case .glyph(let k, _): glyphCache.removeValue(forKey: k)
            #endif
            case .color(let k, _):
                if let removed = colorGlyphCache.removeValue(forKey: k) {
                    colorGlyphByIndex.removeValue(forKey: removed.entry.index)
                    colorGlyphBytes = max(0, colorGlyphBytes - removed.entry.rgba.count)
                }
            }
            total -= 1
        }
    }

    private func cachedColorGlyphLocked(_ key: ColorGlyphKey) -> ColorGlyphEntry? {
        guard var cached = colorGlyphCache[key] else { return nil }
        accessCounter &+= 1
        cached.lastUsed = accessCounter
        cached.lastFrame = frameSequence
        colorGlyphCache[key] = cached
        return cached.entry
    }

    private func storeColorGlyph(key: ColorGlyphKey?, size: SIMD2<Int>, bearing: SIMD2<Float>,
                                 pixels: Data) -> ColorGlyphEntry {
        guard let key else { return ColorGlyphEntry(pixelSize: size, bearingPx: bearing, rgba: pixels) }
        return lock.withLock {
            if let cached = cachedColorGlyphLocked(key) { return cached }
            let index = nextColorGlyphIndex
            nextColorGlyphIndex &+= 1
            if nextColorGlyphIndex == 0 { nextColorGlyphIndex = 1 }
            let entry = ColorGlyphEntry(index: index, pixelSize: size, bearingPx: bearing, rgba: pixels)
            accessCounter &+= 1
            colorGlyphCache[key] = (entry, accessCounter, frameSequence)
            colorGlyphByIndex[index] = entry
            colorGlyphBytes += pixels.count
            evictColorGlyphBudgetLocked(preserving: key)
            evictLRUIfNeededLocked()
            return entry
        }
    }

    private func evictColorGlyphBudgetLocked(preserving keepKey: ColorGlyphKey) {
        while colorGlyphBytes > maxColorGlyphBytes {
            var oldestKey: ColorGlyphKey?
            var oldestSeq: UInt64 = .max
            for (k, v) in colorGlyphCache where k != keepKey {
                if oldestKey == nil || v.lastUsed < oldestSeq {
                    oldestKey = k
                    oldestSeq = v.lastUsed
                }
            }
            guard let victim = oldestKey, let removed = colorGlyphCache.removeValue(forKey: victim) else {
                break
            }
            colorGlyphByIndex.removeValue(forKey: removed.entry.index)
            colorGlyphBytes = max(0, colorGlyphBytes - removed.entry.rgba.count)
        }
    }

    #if canImport(CoreGraphics)
    internal static func parseSVGPath(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var tokens: [String] = []
        var cur = ""
        for ch in d {
            if (ch == "e" || ch == "E"), !cur.isEmpty, cur != "-", cur != "." {
                cur.append(ch)
            } else if ch.isLetter {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
                tokens.append(String(ch))
            } else if ch == "," || ch.isWhitespace {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
            } else if ch == "-" && !cur.isEmpty && cur.last != "e" && cur.last != "E" {
                tokens.append(cur)
                cur = "-"
            } else if ch == "." && cur.contains(".") && cur.last != "e" && cur.last != "E" {
                tokens.append(cur)
                cur = "."
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { tokens.append(cur) }

        var idx = 0
        var cx: CGFloat = 0
        var cy: CGFloat = 0
        var sx: CGFloat = 0
        var sy: CGFloat = 0
        var lastC2X: CGFloat = 0
        var lastC2Y: CGFloat = 0
        var lastQX: CGFloat = 0
        var lastQY: CGFloat = 0
        var prevCmd: Character = "M"
        var cmd: Character = "M"

        func nextNum() -> CGFloat? {
            guard idx < tokens.count, let v = Double(tokens[idx]) else { return nil }
            idx += 1
            return CGFloat(v)
        }

        while idx < tokens.count {
            let startIdx = idx
            let tok = tokens[idx]
            if tok.count == 1, let first = tok.first, first.isLetter {
                cmd = first
                idx += 1
                if cmd == "Z" || cmd == "z" {
                    path.closeSubpath()
                    cx = sx; cy = sy
                    prevCmd = cmd
                    continue
                }
            }
            var parsed = true
            switch cmd {
            case "M":
                guard let x = nextNum(), let y = nextNum() else { parsed = false; break }
                cx = x; cy = y; sx = x; sy = y
                path.move(to: CGPoint(x: cx, y: cy))
                prevCmd = "M"
                cmd = "L"
            case "m":
                guard let dx = nextNum(), let dy = nextNum() else { parsed = false; break }
                cx += dx; cy += dy; sx = cx; sy = cy
                path.move(to: CGPoint(x: cx, y: cy))
                prevCmd = "m"
                cmd = "l"
            case "L":
                guard let x = nextNum(), let y = nextNum() else { parsed = false; break }
                cx = x; cy = y
                path.addLine(to: CGPoint(x: cx, y: cy))
                prevCmd = cmd
            case "l":
                guard let dx = nextNum(), let dy = nextNum() else { parsed = false; break }
                cx += dx; cy += dy
                path.addLine(to: CGPoint(x: cx, y: cy))
                prevCmd = cmd
            case "H":
                guard let x = nextNum() else { parsed = false; break }
                cx = x
                path.addLine(to: CGPoint(x: cx, y: cy))
                prevCmd = cmd
            case "h":
                guard let dx = nextNum() else { parsed = false; break }
                cx += dx
                path.addLine(to: CGPoint(x: cx, y: cy))
                prevCmd = cmd
            case "V":
                guard let y = nextNum() else { parsed = false; break }
                cy = y
                path.addLine(to: CGPoint(x: cx, y: cy))
                prevCmd = cmd
            case "v":
                guard let dy = nextNum() else { parsed = false; break }
                cy += dy
                path.addLine(to: CGPoint(x: cx, y: cy))
                prevCmd = cmd
            case "C":
                guard let x1 = nextNum(), let y1 = nextNum(),
                      let x2 = nextNum(), let y2 = nextNum(),
                      let x = nextNum(), let y = nextNum() else { parsed = false; break }
                path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
                lastC2X = x2; lastC2Y = y2
                cx = x; cy = y
                prevCmd = cmd
            case "c":
                guard let dx1 = nextNum(), let dy1 = nextNum(),
                      let dx2 = nextNum(), let dy2 = nextNum(),
                      let dx = nextNum(), let dy = nextNum() else { parsed = false; break }
                let x2 = cx + dx2, y2 = cy + dy2
                path.addCurve(
                    to: CGPoint(x: cx + dx, y: cy + dy),
                    control1: CGPoint(x: cx + dx1, y: cy + dy1),
                    control2: CGPoint(x: x2, y: y2)
                )
                lastC2X = x2; lastC2Y = y2
                cx += dx; cy += dy
                prevCmd = cmd
            case "S":
                guard let x2 = nextNum(), let y2 = nextNum(),
                      let x = nextNum(), let y = nextNum() else { parsed = false; break }
                let isCubicPrev = (prevCmd == "C" || prevCmd == "c" || prevCmd == "S" || prevCmd == "s")
                let x1 = isCubicPrev ? (2 * cx - lastC2X) : cx
                let y1 = isCubicPrev ? (2 * cy - lastC2Y) : cy
                path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
                lastC2X = x2; lastC2Y = y2
                cx = x; cy = y
                prevCmd = cmd
            case "s":
                guard let dx2 = nextNum(), let dy2 = nextNum(),
                      let dx = nextNum(), let dy = nextNum() else { parsed = false; break }
                let isCubicPrev = (prevCmd == "C" || prevCmd == "c" || prevCmd == "S" || prevCmd == "s")
                let x1 = isCubicPrev ? (2 * cx - lastC2X) : cx
                let y1 = isCubicPrev ? (2 * cy - lastC2Y) : cy
                let x2 = cx + dx2, y2 = cy + dy2
                path.addCurve(to: CGPoint(x: cx + dx, y: cy + dy), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
                lastC2X = x2; lastC2Y = y2
                cx += dx; cy += dy
                prevCmd = cmd
            case "Q":
                guard let x1 = nextNum(), let y1 = nextNum(),
                      let x = nextNum(), let y = nextNum() else { parsed = false; break }
                path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x1, y: y1))
                lastQX = x1; lastQY = y1
                cx = x; cy = y
                prevCmd = cmd
            case "q":
                guard let dx1 = nextNum(), let dy1 = nextNum(),
                      let dx = nextNum(), let dy = nextNum() else { parsed = false; break }
                let qx = cx + dx1, qy = cy + dy1
                path.addQuadCurve(to: CGPoint(x: cx + dx, y: cy + dy), control: CGPoint(x: qx, y: qy))
                lastQX = qx; lastQY = qy
                cx += dx; cy += dy
                prevCmd = cmd
            case "T":
                guard let x = nextNum(), let y = nextNum() else { parsed = false; break }
                let isQuadPrev = (prevCmd == "Q" || prevCmd == "q" || prevCmd == "T" || prevCmd == "t")
                let qx = isQuadPrev ? (2 * cx - lastQX) : cx
                let qy = isQuadPrev ? (2 * cy - lastQY) : cy
                path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: qx, y: qy))
                lastQX = qx; lastQY = qy
                cx = x; cy = y
                prevCmd = cmd
            case "t":
                guard let dx = nextNum(), let dy = nextNum() else { parsed = false; break }
                let isQuadPrev = (prevCmd == "Q" || prevCmd == "q" || prevCmd == "T" || prevCmd == "t")
                let qx = isQuadPrev ? (2 * cx - lastQX) : cx
                let qy = isQuadPrev ? (2 * cy - lastQY) : cy
                path.addQuadCurve(to: CGPoint(x: cx + dx, y: cy + dy), control: CGPoint(x: qx, y: qy))
                lastQX = qx; lastQY = qy
                cx += dx; cy += dy
                prevCmd = cmd
            case "A", "a":
                guard let rxRaw = nextNum(), let ryRaw = nextNum(),
                      let rotDeg = nextNum(),
                      let largeArc = nextNum(), let sweep = nextNum(),
                      let xArg = nextNum(), let yArg = nextNum() else { parsed = false; break }
                let ex = (cmd == "a") ? cx + xArg : xArg
                let ey = (cmd == "a") ? cy + yArg : yArg
                Self.addSVGArc(
                    to: path,
                    from: CGPoint(x: cx, y: cy),
                    to: CGPoint(x: ex, y: ey),
                    rx: abs(rxRaw),
                    ry: abs(ryRaw),
                    xAxisRotationDeg: rotDeg,
                    largeArc: largeArc != 0,
                    sweep: sweep != 0
                )
                cx = ex; cy = ey
                prevCmd = cmd
            default:
                idx += 1
            }
            if !parsed && idx == startIdx {
                idx += 1
            }
        }
        return path
    }

    private static func addSVGArc(
        to path: CGMutablePath,
        from p0: CGPoint,
        to p1: CGPoint,
        rx rxIn: CGFloat,
        ry ryIn: CGFloat,
        xAxisRotationDeg: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        if hypot(p1.x - p0.x, p1.y - p0.y) < 1e-6 { return }
        if rxIn < 1e-6 || ryIn < 1e-6 {
            path.addLine(to: p1)
            return
        }
        let phi = xAxisRotationDeg * .pi / 180.0
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx2 = (p0.x - p1.x) * 0.5
        let dy2 = (p0.y - p1.y) * 0.5
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        var rx = rxIn
        var ry = ryIn
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1.0 {
            let s = sqrt(lambda)
            rx *= s
            ry *= s
        }

        let rx2 = rx * rx
        let ry2 = ry * ry
        let x1p2 = x1p * x1p
        let y1p2 = y1p * y1p
        let denom = rx2 * y1p2 + ry2 * x1p2
        if denom < 1e-12 {
            path.addLine(to: p1)
            return
        }
        let num = max(0.0, rx2 * ry2 - denom)
        let factor = sqrt(num / denom) * (largeArc == sweep ? -1.0 : 1.0)
        let cxp = factor * (rx * y1p / ry)
        let cyp = factor * -(ry * x1p / rx)

        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) * 0.5
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) * 0.5

        func vecAngle(ux: CGFloat, uy: CGFloat, vx: CGFloat, vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            if len < 1e-12 { return 0 }
            let ratio = max(-1.0, min(1.0, dot / len))
            let ang = acos(ratio)
            return (ux * vy - uy * vx) < 0 ? -ang : ang
        }

        let ux = (x1p - cxp) / rx
        let uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx
        let vy = (-y1p - cyp) / ry
        let theta1 = vecAngle(ux: 1, uy: 0, vx: ux, vy: uy)
        var dTheta = vecAngle(ux: ux, uy: uy, vx: vx, vy: vy)
        if !sweep && dTheta > 0 { dTheta -= 2.0 * .pi }
        if sweep && dTheta < 0 { dTheta += 2.0 * .pi }

        let segs = max(1, Int(ceil(abs(dTheta) / (.pi / 2.0))))
        let delta = dTheta / CGFloat(segs)
        let alpha = (4.0 / 3.0) * tan(delta * 0.25)

        var t1 = theta1
        for _ in 0..<segs {
            let t2 = t1 + delta
            let cos1 = cos(t1), sin1 = sin(t1)
            let cos2 = cos(t2), sin2 = sin(t2)
            let e1x = cos1 - alpha * sin1, e1y = sin1 + alpha * cos1
            let e2x = cos2 + alpha * sin2, e2y = sin2 - alpha * cos2

            func mapPt(_ px: CGFloat, _ py: CGFloat) -> CGPoint {
                let sx = px * rx
                let sy = py * ry
                return CGPoint(
                    x: cosPhi * sx - sinPhi * sy + cx,
                    y: sinPhi * sx + cosPhi * sy + cy
                )
            }
            path.addCurve(to: mapPt(cos2, sin2), control1: mapPt(e1x, e1y), control2: mapPt(e2x, e2y))
            t1 = t2
        }
    }
    #endif
}

/// Typography shaper, measurer, and glyph-quad emitter (`rune::TextSystem`).
public final class TextSystem: @unchecked Sendable {
    private struct FontKey: Hashable {
        var family: FontFamily
        var sizePx10: Int
        var weight: Float
        var italic: Bool
        var fontScopeEpoch: UInt64
        var variations: String
        var features: String
    }

    internal struct DecoratedRange {
        var u16Range: Range<Int>
        var underline: Bool
        var strikethrough: Bool
        var background: Color?
        /// Inline code (`Span::mono`): its background is its font's content area (`#983`).
        var monospace: Bool = false
        /// `Span::bg_pad` in points.
        var pad: Float = 0
    }

    /// A span set in a font of its own (inline code, a run of another size) whose quantized box may
    /// grow the lines it sits on, as Parley lays every run's box out (`#983`, `inline_fit.rs`): its
    /// shaped range and its font's ascent and descent in device px. Weight and italic alone keep
    /// the family's metrics (Parley synthesizes them from the same face), so they make no box.
    internal struct InlineSpanBox {
        var u16Range: Range<Int>
        var ascentPx: Float
        var descentPx: Float
        /// The box's own line height (device px): the paragraph's, or for a span with its own
        /// size `LineHeight::FontSizeRelative(line / style.size)` at that size (`text.rs`).
        var lineHeightPx: Float
    }

    private struct MeasureKey: Hashable {
        var text: String
        var style: TextStyle
        var maxWidthHalfPt: Int
        var scale100: Int
        var pillsHash: UInt64 = 0
        var fontEpoch: UInt64 = 1
        var pretty: Bool = false
        var bitmapFallback: Bool = false
    }

    private struct ShapeKey: Hashable {
        var text: TextUTF8Key
        var spans: [TextSpan]?
        var style: TextStyle
        var maxWidthHalfPt: Int
        var scaleBits: UInt32
        var pillsHash: UInt64
        var fontEpoch: UInt64
        var langEpoch: UInt64
        var emitGlyphs: Bool
        var pretty: Bool = false
    }

    private struct ElisionKey: Hashable {
        var text: String
        var spans: [TextSpan]?
        var style: TextStyle
        var maxWidthHalfPt: Int
        var scale100: Int
        var pillsHash: UInt64
        var fontEpoch: UInt64
        var langEpoch: UInt64
    }

    private struct CachedElision {
        var elision: TextElision
        var withoutGlyphs: ShapedText
        /// Elision commit epoch it was last used in (`elisionEpoch`; also `rest()`'s staleness clock).
        var epoch: UInt64 = 0
    }

    internal struct PreparedPill {
        var pillIndex: Int
        var pill: PillChip
        var authU16Lo: Int
        var authU16Hi: Int
        var leadShapedU16: Int
        var labelShapedU16Lo: Int
        var labelShapedU16Hi: Int
        var trailShapedU16: Int?
        var leadWidthPt: Float
        var trailWidthPt: Float
    }

    /// Reference runs include exterior pill boxes and, for by-paragraph text, FSI/PDI.
    /// Glyph emission and editing continue to use the authored byte offsets.
    internal struct MarkedPillText {
        struct Marker {
            let shapedByte: Int
            let authoredByte: Int
            let width: Float
            let isLeading: Bool
        }

        let text: String
        let markers: [Marker]
        private let boundaries: [Int]

        init?(_ source: String, start: Int, ranges: [Range<Int>], isolateLabels: Bool = true,
              padding: (Int, Int) -> (leading: Float, trailing: Float) = { _, _ in (0, 0) }) {
            let bytes = source.utf8
            let end = start + bytes.count
            let first = partitionPoint(ranges) { $0.upperBound <= start }
            guard start < end, first < ranges.count, ranges[first].lowerBound < end else { return nil }
            var result = ""
            var boundaries: [Int] = []
            var markers: [Marker] = []
            var cursor = bytes.startIndex
            for range in ranges[first...] {
                if range.lowerBound >= end { break }
                let lo = max(start, range.lowerBound) - start
                let hi = min(end, range.upperBound) - start
                let lower = bytes.index(bytes.startIndex, offsetBy: lo)
                let upper = bytes.index(lower, offsetBy: hi - lo)
                result += String(decoding: bytes[cursor..<lower], as: UTF8.self)
                let pad = padding(range.lowerBound, range.upperBound)
                // A visible-width neutral in the reference layout gives each exterior box
                // its bidi position even on shapers that give U+FFFC zero width. Only the
                // authored glyphs are painted; the box uses its own measured width.
                if start + lo == range.lowerBound, pad.leading > 0 {
                    markers.append(Marker(shapedByte: result.utf8.count, authoredByte: range.lowerBound,
                                          width: pad.leading, isLeading: true))
                    result += "\u{25A1}"
                    boundaries.append(lo)
                }
                if isolateLabels {
                    result += "\u{2068}"
                    boundaries.append(lo)
                }
                result += String(decoding: bytes[lower..<upper], as: UTF8.self)
                if isolateLabels {
                    result += "\u{2069}"
                    boundaries.append(hi)
                }
                if start + hi == range.upperBound, pad.trailing > 0 {
                    markers.append(Marker(shapedByte: result.utf8.count, authoredByte: range.upperBound,
                                          width: pad.trailing, isLeading: false))
                    result += "\u{25A1}"
                    boundaries.append(hi)
                }
                cursor = upper
            }
            guard !boundaries.isEmpty else { return nil }
            result += String(decoding: bytes[cursor...], as: UTF8.self)
            self.text = result
            self.markers = markers
            self.boundaries = boundaries
        }

        /// The beginning of an authored character, after any adjoining isolate controls.
        func byteOffset(_ authored: Int) -> Int {
            authored + 3 * partitionPoint(boundaries) { $0 <= authored }
        }
    }

    private static func hashPills(_ pills: [PillChip]) -> UInt64 {
        guard !pills.isEmpty else { return 0 }
        var hasher = Hasher()
        for p in pills {
            hasher.combine(p)
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// Whether paragraph `text` (shaped text, its pills' labels between FSI and PDI when
    /// isolated) lays out right to left, nil when it takes CoreText's natural direction: `style`'s
    /// direction when it has one; under a by-paragraph field's `dirByParagraph`
    /// (`TextStyle.byParagraphStart`) its first strong character outside its isolates, else the
    /// direction of the paragraph before it (`previous`), the first the start flow (`flow_of` /
    /// `key_paragraphs`); else right to left when it reads so.
    internal static func paragraphIsRTL(_ text: String, style: TextStyle, previous: inout Bool?) -> Bool? {
        switch style.direction {
        case .rtl: return true
        case .ltr: return false
        case nil:
            guard let start = style.byParagraphStart else { return isRTLParagraph(text) ? true : nil }
            let rtl = firstStrongDirection(in: text, acrossParagraphs: false).map { $0 == .rtl } ?? previous ?? (start == .rtl)
            previous = rtl
            return rtl
        }
    }

    /// `extraPt` is what inline code grows the lines by (`#983`).
    internal static func specLineHeight(lineCount: Int, lineHeightPt: Float, scale: Float, exact: Bool, extraPt: Float = 0) -> Float {
        let s = max(1.0, scale)
        let rawPx = (Float(max(1, lineCount)) * lineHeightPt + extraPt) * s
        let snappedPx = exact ? ((rawPx * 64.0).rounded() / 64.0) : ceilf(rawPx)
        return snappedPx / s
    }

    internal static func isRTLParagraph(_ text: String) -> Bool {
        firstStrongDirection(in: text, acrossParagraphs: false) == .rtl
    }

    /// Prevents `CTTypesetterSuggestLineBreak` emergency mid-word breaks when `wrapAnywhere == false`,
    /// keeping an overflowing unspaced token on one line to match upstream `parley` word wrapping.
    private static func isLineBreakOpportunity(at pos: Int, in ns: NSString, start: Int, end: Int) -> Bool {
        guard pos > start, pos < end else { return true }
        let b = ns.character(at: pos - 1)
        let a = ns.character(at: pos)
        if (0xD800...0xDBFF).contains(b) && (0xDC00...0xDFFF).contains(a) { return false }
        func isWs(_ c: unichar) -> Bool {
            c == 0x20 || c == 0x09 || c == 0x0C || c == 0x200B || (0x2000...0x200A).contains(c) || c == 0x3000
        }
        func isBreakAfterPunct(_ c: unichar) -> Bool {
            c == 0x002D || c == 0x00AD || c == 0x002F || (0x2010...0x2014).contains(c)
        }
        func isCJKOrObj(_ c: unichar) -> Bool {
            (0x2E80...0x9FFF).contains(c) || (0xAC00...0xD7AF).contains(c) ||
            (0xF900...0xFAFF).contains(c) || (0x3040...0x30FF).contains(c) ||
            (0xD800...0xDFFF).contains(c) || c == 0xFFFC
        }
        return isWs(b) || isBreakAfterPunct(b) || isWs(a) || isCJKOrObj(b) || isCJKOrObj(a)
    }

    private static func keepUnbrokenWordIntact(
        _ rawSuggested: Int,
        segStart: Int,
        hardEnd: Int,
        in ns: NSString
    ) -> Int {
        let initial = min(max(1, rawSuggested), hardEnd - segStart)
        var pos = segStart + initial
        if pos >= hardEnd || isLineBreakOpportunity(at: pos, in: ns, start: segStart, end: hardEnd) {
            return initial
        }
        while pos < hardEnd && !isLineBreakOpportunity(at: pos, in: ns, start: segStart, end: hardEnd) {
            pos += 1
        }
        return pos - segStart
    }

    internal static func mergeContiguousBackgrounds(_ boxes: [(SIMD4<Float>, Color)]) -> [(SIMD4<Float>, Color)] {
        guard boxes.count > 1 else { return boxes }
        var out: [(SIMD4<Float>, Color)] = []
        out.reserveCapacity(boxes.count)
        for box in boxes {
            if let last = out.last,
               last.1 == box.1,
               abs(last.0.y - box.0.y) <= 0.5,
               abs(last.0.w - box.0.w) <= 0.5 {
                let lastRight = last.0.x + last.0.z
                let boxRight = box.0.x + box.0.z
                if box.0.x <= lastRight + 1.0 && boxRight >= last.0.x - 1.0 {
                    let minX = min(last.0.x, box.0.x)
                    let maxX = max(lastRight, boxRight)
                    out[out.count - 1].0 = SIMD4<Float>(minX, last.0.y, maxX - minX, last.0.w)
                    continue
                }
            }
            out.append(box)
        }
        return out
    }

    private static func preparePills(
        _ pills: [PillChip],
        in authText: String,
        fontSize: Float,
        isolate: Bool = false
    ) -> (shapedText: String, map: ShapedText.MarkerMap, prepared: [PreparedPill]) {
        guard !pills.isEmpty, !authText.isEmpty else {
            return (authText, ShapedText.MarkerMap(entries: [], authText: authText, lines: []), [])
        }
        let utf8Count = authText.utf8.count
        let indexed = pills.enumerated().sorted { $0.element.range.lowerBound < $1.element.range.lowerBound }
        var valid: [(idx: Int, pill: PillChip)] = []
        var prevEnd = 0
        for (origIdx, p) in indexed {
            let s = p.range.lowerBound
            let e = p.range.upperBound
            guard s >= prevEnd, s < e, e <= utf8Count else { continue }
            guard InlineIconLayout.isUTF8Boundary(s, in: authText),
                  InlineIconLayout.isUTF8Boundary(e, in: authText) else { continue }
            valid.append((origIdx, p))
            prevEnd = e
        }
        guard !valid.isEmpty else {
            return (authText, ShapedText.MarkerMap(entries: [], authText: authText, lines: []), [])
        }

        let pm = PillMetrics(size: fontSize)
        var shaped = ""
        shaped.reserveCapacity(authText.utf8.count + valid.count * 6)
        var entries: [ShapedText.MarkerMap.Entry] = []
        var prepared: [PreparedPill] = []
        prepared.reserveCapacity(valid.count)

        let utf8View = authText.utf8
        var prevAuthIndex = authText.startIndex
        var prevAuthU16 = 0
        var shapedU16 = 0

        for (origIdx, pill) in valid {
            let loIdx = String.Index(utf8View.index(utf8View.startIndex, offsetBy: pill.range.lowerBound), within: authText)!
            let hiIdx = String.Index(utf8View.index(utf8View.startIndex, offsetBy: pill.range.upperBound), within: authText)!
            let gapStr = authText[prevAuthIndex..<loIdx]
            let gapU16 = gapStr.utf16.count
            shaped.append(contentsOf: gapStr)
            shapedU16 += gapU16
            let authU16Lo = prevAuthU16 + gapU16

            let leadW: Float = pill.isBare
                ? ((pill.icon?.size ?? 14.0) + pill.bareGap)
                : pm.lead(icon: pill.icon != nil, style: pill.style)
            let leadU16 = shapedU16
            entries.append(.init(shapedU16: leadU16, authU16: authU16Lo, isTrail: false))
            shaped.append("\u{FFFC}")
            shapedU16 += 1
            // A by-paragraph field shapes the label between FSI and PDI, as a `dir="auto"` span
            // with `unicode-bidi: isolate` (`paragraphs.rs` `with_isolates`): it keeps its own
            // direction, and its paragraph's direction skips it.
            if isolate {
                entries.append(.init(shapedU16: shapedU16, authU16: authU16Lo, isTrail: false))
                shaped.append("\u{2068}")
                shapedU16 += 1
            }

            let labelStr = authText[loIdx..<hiIdx]
            let labelU16 = labelStr.utf16.count
            let labelStartU16 = shapedU16
            shaped.append(contentsOf: labelStr)
            shapedU16 += labelU16
            let labelEndU16 = shapedU16
            let authU16Hi = authU16Lo + labelU16
            if isolate {
                entries.append(.init(shapedU16: shapedU16, authU16: authU16Hi, isTrail: true))
                shaped.append("\u{2069}")
                shapedU16 += 1
            }

            var trailU16: Int? = nil
            var trailW: Float = 0
            if !pill.isBare {
                trailW = pm.trail(style: pill.style)
                let tu16 = shapedU16
                entries.append(.init(shapedU16: tu16, authU16: authU16Hi, isTrail: true))
                shaped.append("\u{FFFC}")
                shapedU16 += 1
                trailU16 = tu16
            }

            prepared.append(PreparedPill(
                pillIndex: origIdx,
                pill: pill,
                authU16Lo: authU16Lo,
                authU16Hi: authU16Hi,
                leadShapedU16: leadU16,
                labelShapedU16Lo: labelStartU16,
                labelShapedU16Hi: labelEndU16,
                trailShapedU16: trailU16,
                leadWidthPt: leadW,
                trailWidthPt: trailW
            ))
            prevAuthIndex = hiIdx
            prevAuthU16 = authU16Hi
        }
        shaped.append(contentsOf: authText[prevAuthIndex...])
        return (shaped, ShapedText.MarkerMap(entries: entries, authText: authText, lines: []), prepared)
    }

    private let lock = NSLock()
    public let glyphAtlas: GlyphAtlas
    /// Installed while constructing a frame for a renderer that can bind quadratic glyph records.
    internal var outlineRendererSupport: ((Bool) -> (outlines: Bool, lcd: Bool))?
    internal var outlinePaths = OutlinePaths()
    private var outlinePathsRevision: UInt64 = 0
    public let glyphCache = GlyphReplayCache()
    public let colorIcons = ColorIconRasterizer()
    private var languageTagOverride: String?
    private var usesScopedFamilies = true
    private var ownFamilies: FontFamiliesRegistry.State
    private var followedWindowEpoch: UInt64?
    private var lastFontSettingsEpoch = FontFamiliesRegistry.settingsEpoch
    private var lastObservedFontEpoch: UInt64 = 0
    private var lastObservedLanguageEpoch: UInt64 = TextLanguageRegistry.currentEpoch()
    #if canImport(CoreText) && canImport(CoreGraphics)
    private var fontCache: [FontKey: CTFont] = [:]
    #endif
    /// Measured sizes stamped with the layout commit (`layoutCommitSeq`) they were last used in (`#905` rest eviction).
    private var measureCache: [MeasureKey: (size: Vec2, usedGeneration: UInt64)] = [:]

    private struct TypesetterKey: Hashable {
        var text: TextUTF8Key
        var spans: [TextSpan]?
        var pills: [PillChip]
        var shapingStyle: TextStyle
        var scaleBit: UInt32
        var languageTag: String?
        var fontEpoch: UInt64

        init(text: String, spans: [TextSpan]?, pills: [PillChip], style: TextStyle, scale: Float, languageTag: String?, fontEpoch: UInt64) {
            self.text = TextUTF8Key(text)
            self.spans = spans
            self.pills = pills
            var normalized = style
            normalized.align = .leading
            normalized.wrap = .wrap
            normalized.wrapAnywhere = false
            normalized.paragraphBlocks = []
            normalized.placeholderIndent = 0
            normalized.elide = .end
            normalized.maxLines = 0
            normalized.exactLines = false
            self.shapingStyle = normalized
            self.scaleBit = scale.bitPattern
            self.languageTag = languageTag
            self.fontEpoch = fontEpoch
        }
    }

    public var smoothing: FontSmoothing = .platformDefault {
        didSet {
            if smoothing != oldValue {
                lock.lock()
                measureCache.removeAll(keepingCapacity: true)
                shapeCache.removeAll(keepingCapacity: true)
                elisionCache.removeAll(keepingCapacity: true)
                typesetterCache.removeAll(keepingCapacity: true)
                preparedShapeCache.removeAll(keepingCapacity: true)
                layoutCache.removeAll(keepingCapacity: true)
                lock.unlock()
            }
        }
    }

    public var applePipeline: ApplePipeline { smoothing.pipeline }

    private struct CachedShape {
        var shaped: ShapedText
        var usedGeneration: UInt64
        var pages: Set<UInt16>
        var atlasResets: UInt64
    }

    private var shapeCache: [ShapeKey: CachedShape] = [:]
    private var elisionCache: [ElisionKey: CachedElision] = [:]
    private var typesetterCache: [TypesetterKey: TextPreparedShape] = [:]
    #if canImport(CoreText) && canImport(CoreGraphics)
    private var preparedShapeCache: [TextShapeKey: TextPreparedShape] = [:]
    #else
    private var preparedShapeCache: [TextShapeKey: ShapedText.DesktopParagraph] = [:]
    #endif
    private var layoutCache: [TextShapeKey: TextLayoutBox] = [:]
    private var layoutCommitSeq: UInt64 = 0
    private var preparedPass: UInt64 = 0
    @TaskLocal private static var preparingSystem: TextSystem?
    private var _shapedCount: Int = 0
    private var _rebrokenCount: Int = 0
    private var _typesetterRebrokenCount: Int = 0
    private var elisionEpoch: UInt64 = 0
    private var _shapeCount: UInt64 = 0
    internal private(set) var measureMissCount: Int = 0
    internal private(set) var shapeMissCount: Int = 0
    internal private(set) var shapedBuildCount: Int = 0
    private var shapeCallCounter: UInt64 = 0
    /// By-paragraph field layouts, printable ASCII's measures and the lazy paste's scratch
    /// (`text/paragraphs.rs`, `text/paragraphs/lazy.rs`).
    internal let paragraphState = ParagraphState()

    private var _rasterRevision: UInt64 = 0
    internal var rasterRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _rasterRevision
    }

    /// Forget placed glyph runs while retaining line breaks, native shapes and the atlas.
    public func forgetRasterState() {
        lock.lock()
        shapeCache = shapeCache.filter { !$0.key.emitGlyphs }
        layoutCache = layoutCache.mapValues { box in
            guard box.hasGlyphs || box.windowPaint != nil else { return box }
            // A previous frame or an active flight can still own the placed box.
            // Clone its measurements and leave that snapshot untouched.
            let measured = box.clone()
            measured.lastUsedCommit = box.lastUsedCommit
            measured.hasGlyphs = false
            measured.shaped.glyphs = []
            measured.shaped.lineGlyphRanges = []
            measured.rasterWindow = nil
            measured.desktopAtlasResets = nil
            measured.desktopPages = []
            #if canImport(CoreText) && canImport(CoreGraphics)
            measured.shaped.glyphPens = []
            measured.shaped.glyphPlacements = nil
            #elseif canImport(CRuneDesktopText) && !canImport(CoreText)
            measured.shaped.desktopRestingText = nil
            measured.desktopRasterLayout = box.desktopRasterLayout
            #endif
            return measured
        }
        _rasterRevision &+= 1
        lock.unlock()
        glyphCache.clear()
    }

    /// A fresh raster starts each outline path at rest, even just after a moving frame.
    internal func beginOutlineFrame() {
        let revision = rasterRevision
        if outlinePathsRevision != revision {
            outlinePaths = OutlinePaths()
            outlinePathsRevision = revision
        }
        outlinePaths.beginFrame()
    }

    /// Drops cached layouts and typesetters while keeping rasterized glyph and icon atlases intact.
    public func clearLayoutCaches() {
        lock.lock()
        measureCache.removeAll(keepingCapacity: true)
        shapeCache.removeAll(keepingCapacity: true)
        elisionCache.removeAll(keepingCapacity: true)
        typesetterCache.removeAll(keepingCapacity: true)
        preparedShapeCache.removeAll(keepingCapacity: true)
        layoutCache.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Advances the layout commit generation after a committed frame (`#905`) without any
    /// still-shown keys to refresh; the same clock and budget sweep as `endCommit(activeKeys:)`.
    public func endCommit() {
        endCommit(activeKeys: [])
    }

    /// Whether an entry last used in commit `used` is two or more commits behind commit `g`.
    /// Entries a sweep stamped with the commit just begun (`used > g`) count as fresh.
    private static func isStale(used: UInt64, lastCommit g: UInt64) -> Bool {
        used <= g && g - used >= 2
    }

    /// Window at rest (`TextSystem::rest`, `#905`): evicts layout/shape/measure/elision/typesetter
    /// entries the last two commits didn't use, forgets their glyph runs, and drops orphan glyph
    /// cache entries.
    public func rest() {
        var evictedKeys: [TextShapeKey] = []
        lock.lock()
        if layoutCommitSeq > 0 {
            // `endCommit` moved the generation on after the last commit.
            let g = layoutCommitSeq &- 1
            measureCache = measureCache.filter { !Self.isStale(used: $0.value.usedGeneration, lastCommit: g) }
            shapeCache = shapeCache.filter { !Self.isStale(used: $0.value.usedGeneration, lastCommit: g) }
            typesetterCache = typesetterCache.filter { !Self.isStale(used: $0.value.lastUsedCommit, lastCommit: g) }
            for (k, b) in layoutCache where Self.isStale(used: b.lastUsedCommit, lastCommit: g) {
                evictedKeys.append(k)
            }
            for k in evictedKeys {
                layoutCache.removeValue(forKey: k)
            }
        }
        evictedKeys += evictPrepared(over: 0)
        let orphaned = dropOrphanShapes(afterRemoving: evictedKeys)
        // Elisions run on their own per-commit epoch (`beginElisionCommit`), bumped as each commit begins.
        let e = elisionEpoch
        elisionCache = elisionCache.filter { !Self.isStale(used: $0.value.epoch, lastCommit: e) }
        lock.unlock()
        for k in orphaned {
            glyphCache.forget(shapeKey: k)
        }
        paragraphState.rest()
        glyphAtlas.dropOrphans()
    }

    internal var cachedMeasureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return measureCache.count
    }

    /// Entries in the `shape(...)`/`measure(...)` `ShapedText` cache (`shapeCache`); distinct from
    /// `cachedShapeCount`, which counts `layoutKeyed` prepared shapes (`cached_shape_count`).
    internal var cachedShapedTextCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return shapeCache.count
    }

    internal var cachedTypesetterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return typesetterCache.count
    }

    /// Rasterizes a standalone `SVGIcon` into the glyph atlas and returns a `PositionedGlyph` quad (`text/mod.rs` `icon_quad`).
    public func iconQuad(_ icon: SVGIcon, pixelSize: Float, origin: SIMD2<Float> = .zero) -> PositionedGlyph? {
        guard pixelSize.isFinite && pixelSize > 0 else { return nil }
        let px = max(1, Int(pixelSize.rounded()))
        guard let entry = glyphAtlas.rasterizeIconIfPlaced(icon, pixelSize: px) else {
            return nil
        }
        return PositionedGlyph(
            rect: SIMD4<Float>(origin.x, origin.y, Float(entry.pixelSize.x), Float(entry.pixelSize.y)),
            uv: entry.uv,
            color: nil,
            colorGlyphIndex: nil,
            atlasPage: entry.page
        )
    }

    public var shapeCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _shapeCount
    }

    public var cachedElisionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return elisionCache.count
    }

    public var shapedCallCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return shapeCallCounter
    }

    internal func recordShapeCall() {
        lock.lock()
        shapeCallCounter &+= 1
        lock.unlock()
    }

    /// Total number of full text shaping runs (`TextSystem::shaped_count`).
    public var shapedCount: Int {
        lock.withLock { _shapedCount }
    }

    /// Total number of width re-break passes that reused cached shaping (`TextSystem::rebroken_count`).
    public var rebrokenCount: Int {
        lock.withLock { _rebrokenCount + _typesetterRebrokenCount }
    }

    /// Current number of cached laid-out boxes (`TextSystem::cached_layout_count`).
    public var cachedLayoutCount: Int {
        lock.withLock { layoutCache.count }
    }

    /// Current number of cached prepared shapes (`TextSystem::cached_shape_count`).
    public var cachedShapeCount: Int {
        lock.withLock { preparedShapeCache.count }
    }

    internal func cachedLayoutBox(for shapeKey: TextShapeKey) -> TextLayoutBox? {
        lock.withLock { layoutCache[shapeKey] }
    }

    internal func layoutKeys() -> Set<TextShapeKey> {
        lock.withLock { Set(layoutCache.keys) }
    }

    /// A prepared advance-in-run leaf keeps its whole unwrapped layout and the native
    /// cluster advances together. Evicting that layout also releases the cell data.
    internal func preparedRunCells(_ run: TextRun, style: TextStyle, scale: Float) -> TextRunCellLayout? {
        let preparing = isPreparingLayouts
        guard preparing || lock.withLock({ preparedPass != 0 }) else { return nil }
        let key = TextShapeKey(authText: run.text, spans: nil, pills: [], style: style, pixelScale: scale,
                               fontEpoch: currentFontEpoch, languageTag: language,
                               maxWidth: nil, defaultSmoothing: smoothing)
        let cached = cachedLayoutBox(for: key, matchingWidth: nil)
        if let cells = lock.withLock({ cached?.preparedRunCells }) { return cells }
        guard preparing else { return nil }
        let box = cached ?? layoutKeyed(text: run.text, style: style, maxWidth: nil, pixelScale: scale,
                                        emitGlyphs: false)
        let cells = TextRunCellLayout(text: run.text, textSystem: self, style: style, pixelScale: scale)
        lock.withLock { box.preparedRunCells = cells }
        return cells
    }

    internal func prepareLayouts(_ measure: () -> Void) -> Int {
        let before = layoutKeys()
        Self.$preparingSystem.withValue(self, operation: measure)
        return keepPrepared(since: before)
    }

    internal var isPreparingLayouts: Bool { Self.preparingSystem === self }

    /// Materialize only the final node width. Taffy's trial widths can read a matching
    /// break, but never retain their own overflow decisions or elision-search probes.
    internal func preparedOverflowLayout(
        _ leaf: ElResolvedText, width: Float?, scale: Float, create: Bool = false
    ) -> TextLayoutBox? {
        guard !leaf.isSecure, leaf.advanceRun == nil, !leaf.displayedText.isEmpty,
              leaf.truncateFade || Self.needsElision(leaf.style, maxWidth: width) else { return nil }
        let layoutWidth = leaf.truncateFade ? nil : width
        var style = leaf.style
        if leaf.truncateFade {
            style.wrap = .noWrap
            style.maxLines = 0
        }
        let key = TextShapeKey(authText: leaf.displayedText, spans: leaf.spans, pills: leaf.pills,
                               style: style, pixelScale: max(scale, 1), fontEpoch: currentFontEpoch,
                               languageTag: language, maxWidth: layoutWidth, pretty: false,
                               defaultSmoothing: smoothing)
        if let hit = cachedLayoutBox(for: key, matchingWidth: layoutWidth) { return hit }
        guard create else { return nil }
        if leaf.truncateFade {
            return overflowContent(leaf, cut: nil, width: nil, scale: scale, glyphs: false)
        }
        let decision = shapeImpl(text: leaf.displayedText, spans: leaf.spans, pills: leaf.pills,
                                 style: leaf.style, maxWidth: width, pixelScale: scale,
                                 emitGlyphs: false, bypassCache: true)
        // The cut is selected without retaining trial strings. Cache the typeset content
        // of this exact cut for the first glyph-producing pass.
        _ = overflowContent(leaf, cut: decision.elided, width: width, scale: scale, glyphs: false)
        let box = TextLayoutBox(shapeKey: key, authText: leaf.displayedText, spans: leaf.spans,
                                pills: leaf.pills, style: leaf.style, pixelScale: scale,
                                maxWidth: width, shaped: decision, hasGlyphs: false, prepared: nil)
        lock.withLock {
            let storage = layoutStorageKey(for: key, width: width)
            box.lastUsedCommit = layoutCommitSeq
            layoutCache[storage] = box
        }
        return box
    }

    private func overflowContent(
        _ leaf: ElResolvedText, cut: TextElision?, width: Float?, scale: Float,
        glyphs: Bool, glide: Vec2 = .zero
    ) -> TextLayoutBox {
        var style = leaf.style
        let clamps = style.maxLines > 0 && !leaf.truncateFade
        style.maxLines = 0
        if !clamps { style.wrap = .noWrap }
        else if style.wrap == .noWrap || style.wrap == .ellipsis { style.wrap = .wrap }
        let drawn = cut?.drawnString(from: leaf.displayedText) ?? leaf.displayedText
        let spans = leaf.spans.map { cut?.mapSpans($0, originalLength: leaf.displayedText.utf8.count, drawn: drawn) ?? $0 }
        return layoutKeyed(text: drawn, spans: spans, pills: cut?.mapPills(leaf.pills) ?? leaf.pills,
                           style: style, maxWidth: clamps ? width : nil, pixelScale: scale,
                           emitGlyphs: glyphs, glidePx: glide)
    }

    internal func drawPreparedOverflow(_ leaf: ElResolvedText, box: TextLayoutBox, glide: Vec2) -> ShapedText {
        let cut = box.shaped.elided
        var drawn = overflowContent(leaf, cut: cut, width: box.maxWidth, scale: box.pixelScale,
                                    glyphs: true, glide: glide).shaped
        if let cut {
            drawn.elided = cut
            drawn.wasTruncated = true
            drawn.drawnText = cut.drawnString(from: leaf.displayedText)
        }
        return drawn
    }

    internal func cachedLayoutBox(for key: TextShapeKey, matchingWidth width: Float?) -> TextLayoutBox? {
        lock.withLock {
            if let box = layoutCache[key], Self.widthsMatch(width, box.maxWidth) { return box }
            return layoutCache[key.prepared(at: width)]
        }
    }

    /// Called under the cache lock. Reuse the ordinary slot until an idle pass needs
    /// a second width. That break gets a slot a mounted view can subsequently find.
    private func layoutStorageKey(for key: TextShapeKey, width: Float?) -> TextShapeKey {
        let preparing = isPreparingLayouts
        guard preparing || preparedPass != 0 else { return key }
        let ordinary = layoutCache[key]
        if let ordinary, Self.widthsMatch(width, ordinary.maxWidth) { return key }
        let alternate = key.prepared(at: width)
        return (preparing && ordinary != nil) || layoutCache[alternate] != nil ? alternate : key
    }

    /// Marks layouts first shaped by an idle pass and limits the bytes it leaves unmounted.
    @discardableResult
    internal func keepPrepared(since before: Set<TextShapeKey>, budget: Int = 1 << 20) -> Int {
        lock.lock()
        preparedPass = max(1, preparedPass &+ 1)
        let added = Set(layoutCache.keys).subtracting(before)
        for key in added {
            layoutCache[key]?.preparedPass = preparedPass
        }
        let evicted = dropOrphanShapes(afterRemoving: evictPrepared(over: budget))
        lock.unlock()
        for key in evicted { glyphCache.forget(shapeKey: key) }
        return added.count
    }

    /// Called under the text lock. A separate key array allows ARC to test the cache's
    /// reference directly without retaining the boxes while scanning them.
    private func evictPrepared(over budget: Int) -> [TextShapeKey] {
        guard preparedPass != 0 else { return [] }
        var loose: [(key: TextShapeKey, age: UInt64, cost: Int)] = []
        var total: UInt64 = 0
        for key in Array(layoutCache.keys) {
            guard let pass = layoutCache[key]?.preparedPass,
                  isKnownUniquelyReferenced(&layoutCache[key]) else { continue }
            let cost = ParagraphState.layoutCost(textBytes: key.authText.utf8.count)
            loose.append((key, preparedPass &- pass, cost))
            total += UInt64(cost)
        }
        let limit = UInt64(max(0, budget))
        guard total > limit else { return [] }
        loose.sort { $0.age == $1.age ? $0.cost > $1.cost : $0.age > $1.age }
        var evicted: [TextShapeKey] = []
        for entry in loose {
            if total <= limit { break }
            layoutCache.removeValue(forKey: entry.key)
            evicted.append(entry.key)
            total -= UInt64(entry.cost)
        }
        return evicted
    }

    /// Breaks of the same shape share the native prepared shape and glyph cache.
    private func dropOrphanShapes(afterRemoving keys: [TextShapeKey]) -> Set<TextShapeKey> {
        guard !keys.isEmpty else { return [] }
        var orphaned = Set(keys.map(\.unpreparedKey))
        if preparedPass != 0 {
            for key in layoutCache.keys { orphaned.remove(key.unpreparedKey) }
        }
        for key in orphaned { preparedShapeCache.removeValue(forKey: key) }
        return orphaned
    }

    /// Evicts a superseded layout/shape/glyph entry immediately (`text_layout::supersede`).
    public func supersede(_ key: TextShapeKey) {
        lock.lock()
        layoutCache.removeValue(forKey: key)
        if preparedPass != 0 {
            for alternate in layoutCache.keys.filter({ $0.hasPreparedWidth && $0.unpreparedKey == key }) {
                layoutCache.removeValue(forKey: alternate)
            }
        }
        preparedShapeCache.removeValue(forKey: key)
        lock.unlock()
        glyphCache.forget(shapeKey: key)
    }

    /// Advances commit counter and sweeps stale cached layouts beyond 60 commits and 3 MiB (`end_commit`).
    public func endCommit(activeKeys: Set<TextShapeKey>) {
        let staleCommits: UInt64 = 60
        let staleBytes = 3 * 1024 * 1024
        var evictedKeys: [TextShapeKey] = []

        lock.lock()
        layoutCommitSeq &+= 1
        let nowSeq = layoutCommitSeq
        for k in activeKeys {
            if let b = layoutCache[k] {
                b.lastUsedCommit = nowSeq
            }
        }
        var totalBytes = 0
        for (key, b) in layoutCache {
            if key.hasPreparedWidth && activeKeys.contains(key.unpreparedKey) {
                b.lastUsedCommit = nowSeq
            }
            totalBytes += b.estimatedBytes
        }
        if totalBytes > staleBytes {
            let candidates = layoutCache
                .filter { !activeKeys.contains($0.key) && nowSeq &- $0.value.lastUsedCommit >= staleCommits }
                .sorted { $0.value.lastUsedCommit < $1.value.lastUsedCommit }
            for (k, b) in candidates {
                if totalBytes <= staleBytes { break }
                layoutCache.removeValue(forKey: k)
                totalBytes = max(0, totalBytes - b.estimatedBytes)
                evictedKeys.append(k)
            }
        }
        let orphaned = dropOrphanShapes(afterRemoving: evictedKeys)
        lock.unlock()
        paragraphState.endCommit()

        for k in orphaned {
            glyphCache.forget(shapeKey: k)
        }
    }

    public func beginElisionCommit() {
        lock.lock()
        elisionEpoch &+= 1
        lock.unlock()
    }

    public func pruneUnusedElisions() {
        lock.lock()
        let cur = elisionEpoch
        elisionCache = elisionCache.filter { $0.value.epoch == cur }
        lock.unlock()
    }

    public init(glyphAtlas: GlyphAtlas = GlyphAtlas()) {
        self.glyphAtlas = glyphAtlas
        self.ownFamilies = FontFamiliesRegistry.threadOverride ?? .init(sans: "", mono: "", epoch: 1)
        self.lastObservedFontEpoch = ownFamilies.epoch
        self.languageTagOverride = TextLanguageRegistry.currentLanguageTag()
    }

    internal convenience init(forMeasurement: Void) {
        self.init()
        usesScopedFamilies = false
        followMeasurementFontFamilies()
    }

    internal func followMeasurementFontFamilies() {
        let families = FontFamiliesRegistry.snapshot()
        lock.lock()
        ownFamilies = families
        lock.unlock()
    }

    /// Window text retains its own slots while painting. Sibling windows on the same thread
    /// take up a new choice when they start their next frame (`text/families.rs`).
    internal func initializeWindowFontFamilies() {
        lock.lock()
        usesScopedFamilies = false
        lock.unlock()
        _ = followWindowFontFamilies()
    }

    /// A document loaded new faces for its current family slots.
    internal func invalidateWindowFontFaces() {
        lock.lock()
        ownFamilies = FontFamiliesRegistry.makeState(sans: ownFamilies.sans, mono: ownFamilies.mono)
        lock.unlock()
        syncGlobalFamiliesIfNeeded()
    }

    internal func chooseWindowFontFamilies(sans: String, mono: String) -> Bool {
        FontFamiliesRegistry.chooseWindowFamilies(sans: sans, mono: mono)
        return followWindowFontFamilies()
    }

    internal var windowFontFamiliesBehind: Bool {
        guard let choice = FontFamiliesRegistry.windowChoice else { return false }
        lock.lock()
        defer { lock.unlock() }
        return followedWindowEpoch != choice.epoch
    }

    internal func followWindowFontFamilies() -> Bool {
        guard let choice = FontFamiliesRegistry.windowChoice else { return false }
        lock.lock()
        guard followedWindowEpoch != choice.epoch else {
            lock.unlock()
            return false
        }
        followedWindowEpoch = choice.epoch
        lock.unlock()
        return setFamilies(sans: choice.sans, mono: choice.mono)
    }

    private func activeFamilies() -> FontFamiliesRegistry.State {
        let settings = FontFamiliesRegistry.settingsEpoch
        lock.lock()
        if lastFontSettingsEpoch != settings {
            ownFamilies = FontFamiliesRegistry.makeState(sans: ownFamilies.sans, mono: ownFamilies.mono)
            lastFontSettingsEpoch = settings
        }
        let own = ownFamilies
        let scoped = usesScopedFamilies
        lock.unlock()
        return scoped ? FontFamiliesRegistry.threadOverride ?? own : own
    }

    /// Preferred BCP-47 language tag used for CJK fallback and `kCTLanguageAttributeName` (`TextSystem::language`).
    public var language: String? {
        syncGlobalFamiliesIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return languageTagOverride
    }

    /// Shapes in `tag` from now on, dropping cached measurements. Returns `false` when already shaping in that language (`TextSystem::set_language`).
    @discardableResult
    public func setLanguage(_ tag: String?) -> Bool {
        let normalized: String?
        if let tag {
            guard let parsed = TextLanguageRegistry.normalizeTag(tag) else {
                return false
            }
            normalized = parsed
        } else {
            normalized = nil
        }
        lock.lock()
        if languageTagOverride == normalized {
            lock.unlock()
            return false
        }
        languageTagOverride = normalized
        measureCache.removeAll(keepingCapacity: true)
        shapeCache.removeAll(keepingCapacity: true)
        elisionCache.removeAll(keepingCapacity: true)
        typesetterCache.removeAll(keepingCapacity: true)
        preparedShapeCache.removeAll(keepingCapacity: true)
        layoutCache.removeAll(keepingCapacity: true)
        lock.unlock()
        glyphCache.clear()
        return true
    }

    /// Cache epoch for the active family slots, including a thread-scoped measurement override.
    public var currentFontEpoch: UInt64 { activeFamilies().epoch }

    private final class PrettyWrapStorage: @unchecked Sendable {
        let lock = NSLock()
        var enabled: Bool = false
    }
    private static let prettyStorage = PrettyWrapStorage()

    /// Opts wrapped proportional text into Chromium's `text-wrap-style: pretty` (`ScoreLineBreaker`, `#882`).
    /// A paragraph that would end on a lone short word takes a word or more down with it, pills and
    /// inline boxes included (`#933`). Text in a monospace family, justified, cut to a number of lines
    /// or opted out with `El.wrapGreedy` keeps greedy lines, as does, as in Chromium, a paragraph whose
    /// last line holds an isolated run (inline code) and one with a word broken inside to fit (`wrapAnywhere`).
    public static func setPrettyWrap(_ on: Bool) {
        prettyStorage.lock.lock()
        let changed = (prettyStorage.enabled != on)
        prettyStorage.enabled = on
        prettyStorage.lock.unlock()
        if changed {
            _ = FontFamiliesRegistry.bumpEpoch()
        }
    }

    public static var prettyWrap: Bool {
        prettyStorage.lock.lock()
        let v = prettyStorage.enabled
        prettyStorage.lock.unlock()
        return v
    }

    /// Declares CSS `@font-face` weight ranges for app-registered families (`set_face_weights`, `#853`).
    public static func setFaceWeights(_ faces: [FaceWeights]) {
        FaceWeightsRegistry.set(faces)
        _ = FontFamiliesRegistry.bumpEpoch()
    }

    public static var faceWeights: [FaceWeights] {
        FaceWeightsRegistry.snapshot()
    }

    /// Looks up a cached RGBA color glyph bitmap emitted during `shape(...)` (`#807`).
    public func colorGlyph(_ index: UInt32) -> GlyphAtlas.ColorGlyphEntry? {
        glyphAtlas.colorGlyph(index)
    }

    /// Looks up the pixels held by this shaped glyph, including uncached and evicted glyphs.
    public func colorGlyph(for glyph: PositionedGlyph) -> GlyphAtlas.ColorGlyphEntry? {
        glyph.retainedColorGlyph ?? glyph.colorGlyphIndex.flatMap(glyphAtlas.colorGlyph)
    }

    /// The coverage atlas sample to paint for a shaped glyph in straight RGBA.
    /// Set `encoded` when the RGB channels already use the sRGB transfer function.
    public func glyphMask(for glyph: PositionedGlyph, ink: SIMD4<Float>, encoded: Bool) -> (uv: SIMD4<Float>, page: UInt16, gamma: Float) {
        #if os(Windows)
        if let tile = glyph.windowsMask?.bounds {
            let bucket = WindowsTextGamma.bucket(ink, encoded: encoded)
            if let corrected = glyphAtlas.windowsMask(tile, sourcePage: glyph.atlasPage, bucket: bucket) {
                let dx = Float(corrected.pixelOrigin.x - Int(tile.x)) / Float(glyphAtlas.pagePixelSize.x)
                let dy = Float(corrected.pixelOrigin.y - Int(tile.y)) / Float(glyphAtlas.pagePixelSize.y)
                return (glyph.uv + SIMD4(dx, dy, dx, dy), corrected.page, 1)
            }
            return (glyph.uv, glyph.atlasPage, 1)
        }
        #endif
        let premultiplied = SIMD4(ink.x * ink.w, ink.y * ink.w, ink.z * ink.w, ink.w)
        return (glyph.uv, glyph.atlasPage, coverageExponent(premultiplied))
    }

    internal func glyphMask(for glyph: PositionedGlyph, premultipliedInk ink: SIMD4<Float>, encoded: Bool) -> (uv: SIMD4<Float>, page: UInt16, gamma: Float) {
        #if os(Windows)
        if glyph.windowsMask != nil && ink.w > 0 {
            return glyphMask(for: glyph, ink: SIMD4(ink.x / ink.w, ink.y / ink.w, ink.z / ink.w, ink.w), encoded: encoded)
        }
        #endif
        return (glyph.uv, glyph.atlasPage, coverageExponent(ink))
    }

    /// The GPU uses three adjacent R8 texels per pixel only for native-size quads.
    internal func lcdMask(for glyph: PositionedGlyph, rect: SIMD4<Float>, ink: SIMD4<Float>, encoded: Bool) -> (uv: SIMD4<Float>, page: UInt16)? {
        #if os(Windows)
        guard let source = glyph.windowsMask, source.rgb != nil else { return nil }
        let tile = source.bounds
        let width = Float(glyphAtlas.pagePixelSize.x), height = Float(glyphAtlas.pagePixelSize.y)
        guard abs((glyph.uv.z - glyph.uv.x) * width - rect.z) <= 0.5,
              abs((glyph.uv.w - glyph.uv.y) * height - rect.w) <= 0.5,
              let entry = glyphAtlas.windowsMask(tile, sourcePage: glyph.atlasPage, bucket: WindowsTextGamma.bucket(ink, encoded: encoded), lcd: source) else { return nil }
        let dx = Float(entry.pixelOrigin.x - 3 * Int(tile.x)) / width
        let dy = Float(entry.pixelOrigin.y - Int(tile.y)) / height
        return (glyph.uv * SIMD4(3, 1, 3, 1) + SIMD4(dx, dy, dx, dy), entry.page)
        #else
        return nil
        #endif
    }

    /// CSS font family lists backing `.systemUI` (`sans`) and `.monospace` (`mono`).
    public func families() -> (sans: String, mono: String) {
        let active = activeFamilies()
        return (active.sans, active.mono)
    }

    /// Updates this text system and the fonts used by free measurement calls.
    @discardableResult
    public func setFamilies(sans: String, mono: String) -> Bool {
        let previous = activeFamilies()
        guard previous.sans != sans || previous.mono != mono else { return false }
        _ = FontFamiliesRegistry.setFamilies(sans: sans, mono: mono)
        let state = FontFamiliesRegistry.makeState(sans: sans, mono: mono)
        lock.lock()
        ownFamilies = state
        lock.unlock()
        syncGlobalFamiliesIfNeeded()
        return true
    }

    private func syncGlobalFamiliesIfNeeded() {
        let langEpoch = TextLanguageRegistry.currentEpoch()
        let activeFontEpoch = currentFontEpoch
        var clearGlyphs = false
        lock.lock()
        if lastObservedFontEpoch != activeFontEpoch {
            #if canImport(CoreText) && canImport(CoreGraphics)
            fontCache.removeAll(keepingCapacity: true)
            #endif
            measureCache.removeAll(keepingCapacity: true)
            shapeCache.removeAll(keepingCapacity: true)
            elisionCache.removeAll(keepingCapacity: true)
            typesetterCache.removeAll(keepingCapacity: true)
            preparedShapeCache.removeAll(keepingCapacity: true)
            layoutCache.removeAll(keepingCapacity: true)
            lastObservedFontEpoch = activeFontEpoch
            clearGlyphs = true
        }
        if lastObservedLanguageEpoch != langEpoch {
            let globalTag = TextLanguageRegistry.currentLanguageTag()
            if languageTagOverride != globalTag {
                languageTagOverride = globalTag
                measureCache.removeAll(keepingCapacity: true)
                shapeCache.removeAll(keepingCapacity: true)
                elisionCache.removeAll(keepingCapacity: true)
                typesetterCache.removeAll(keepingCapacity: true)
                preparedShapeCache.removeAll(keepingCapacity: true)
                layoutCache.removeAll(keepingCapacity: true)
                clearGlyphs = true
            }
            lastObservedLanguageEpoch = langEpoch
        }
        lock.unlock()
        if clearGlyphs {
            glyphCache.clear()
        }
    }

    #if canImport(CoreText) && canImport(CoreGraphics)

    private static func coreTextWeight(for cssWeight: Float) -> CGFloat {
        let stops: [(Float, CGFloat)] = [
            (100, -0.80), (200, -0.60), (300, -0.40), (400, 0.0),
            (500, 0.23), (600, 0.30), (700, 0.40), (800, 0.56), (900, 0.62),
        ]
        let clamped = min(max(cssWeight, 100), 900)
        for i in 0..<(stops.count - 1) {
            let (w0, c0) = stops[i]
            let (w1, c1) = stops[i + 1]
            if clamped <= w1 {
                let t = CGFloat((clamped - w0) / (w1 - w0))
                return c0 + (c1 - c0) * t
            }
        }
        return 0.62
    }

    private static func firstMatchingFont(in families: [String], sizePx: CGFloat) -> CTFont? {
        for name in families {
            // The hidden SF Mono name resolves to a substitute through CTFontCreateWithName.
            if name == ".SF NS Mono" {
                #if os(macOS)
                return NSFont.monospacedSystemFont(ofSize: sizePx, weight: .regular) as CTFont
                #elseif canImport(UIKit)
                return UIFont.monospacedSystemFont(ofSize: sizePx, weight: .regular) as CTFont
                #else
                continue
                #endif
            }
            // Apple's public name for San Francisco resolves to a private family and PostScript name.
            if name.caseInsensitiveCompare("System Font") == .orderedSame {
                return CTFontCreateWithName("System Font" as CFString, sizePx, nil)
            }
            let font = CTFontCreateWithName(name as CFString, sizePx, nil)
            let resolvedName = CTFontCopyFamilyName(font) as String
            if resolvedName.caseInsensitiveCompare(name) == .orderedSame ||
                (CTFontCopyPostScriptName(font) as String).caseInsensitiveCompare(name) == .orderedSame ||
                (CTFontCopyFullName(font) as String).caseInsensitiveCompare(name) == .orderedSame {
                return font
            }
        }
        return nil
    }

    private static func parseOpenTypeFeatures(_ raw: String) -> [[CFString: Any]] {
        guard !raw.isEmpty else { return [] }
        var out: [[CFString: Any]] = []
        for item in raw.split(separator: ",") {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard let rawTag = parts.first else { continue }
            let tag = rawTag.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard tag.utf8.count == 4 else { continue }
            let value: Int
            if parts.count >= 2 {
                let valStr = String(parts[1]).lowercased()
                if valStr == "on" {
                    value = 1
                } else if valStr == "off" {
                    value = 0
                } else if let n = Int(valStr) {
                    value = n
                } else {
                    continue
                }
            } else {
                value = 1
            }
            out.append([
                kCTFontOpenTypeFeatureTag: tag as CFString,
                kCTFontOpenTypeFeatureValue: value as CFNumber,
            ])
        }
        return out
    }

    private static func parseFontVariations(_ raw: String) -> [NSNumber: Double] {
        guard !raw.isEmpty else { return [:] }
        var out: [NSNumber: Double] = [:]
        for item in raw.split(separator: ",") {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 2 else { continue }
            let tag = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let bytes = Array(tag.utf8)
            guard bytes.count == 4, let val = Double(parts[1]) else { continue }
            let fourCC = (Int32(bytes[0]) << 24) | (Int32(bytes[1]) << 16) | (Int32(bytes[2]) << 8) | Int32(bytes[3])
            out[NSNumber(value: fourCC)] = val
        }
        return out
    }

    internal func resolveCTFont(style: TextStyle, pixelScale: Float) -> CTFont {
        syncGlobalFamiliesIfNeeded()
        let families = activeFamilies()
        let sizePx = style.size * pixelScale
        let key = FontKey(
            family: style.family,
            sizePx10: Int((sizePx * 10.0).rounded()),
            weight: style.weight,
            italic: style.italic,
            fontScopeEpoch: families.epoch,
            variations: style.variations,
            features: style.features
        )
        lock.lock()
        if let cached = fontCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let ctWeight = Self.coreTextWeight(for: style.weight)
        var traits: [CFString: Any] = [
            kCTFontWeightTrait: ctWeight,
        ]
        if style.italic {
            traits[kCTFontSlantTrait] = CGFloat(0.15)
        }

        DefaultFonts.registerIfNeeded()

        let stack = style.family.stack(sans: families.sans, mono: families.mono)
        let candidates = FontFamily.candidates(in: stack)
        let mono = style.family.isMonospace
        let baseFont = Self.firstMatchingFont(in: candidates, sizePx: CGFloat(sizePx))
            ?? CTFontCreateUIFontForLanguage(mono ? .userFixedPitch : .system, CGFloat(sizePx), nil)
            ?? CTFontCreateWithName((mono ? "Menlo-Regular" : "SFProText-Regular") as CFString, CGFloat(sizePx), nil)

        let familyName = CTFontCopyFamilyName(baseFont) as String
        let featureSettings = Self.parseOpenTypeFeatures(style.shapingFeatures(monospace: mono))
        let variationSettings = Self.parseFontVariations(style.variations)
        let declaredFaces = FaceWeightsRegistry.snapshot()
        let weighted: CTFont
        let targetWeight = FaceWeightsRegistry.effectiveCSSWeight(
            familyName: familyName, requestedWeight: style.weight, faces: declaredFaces
        )
        if let faceMatch = FaceWeightsRegistry.matchingFace(
               inFamily: familyName,
               targetCSSWeight: targetWeight,
               italic: style.italic,
               sizePx: CGFloat(sizePx)
           ) {
            if !featureSettings.isEmpty || !variationSettings.isEmpty {
                var extraAttrs: [CFString: Any] = [:]
                if !featureSettings.isEmpty {
                    extraAttrs[kCTFontFeatureSettingsAttribute] = featureSettings as CFArray
                }
                if !variationSettings.isEmpty {
                    let selectedAxes = CTFontCopyVariation(faceMatch) as? [NSNumber: Double] ?? [:]
                    extraAttrs[kCTFontVariationAttribute] = selectedAxes.merging(variationSettings) { _, author in author } as CFDictionary
                }
                let desc = CTFontDescriptorCreateCopyWithAttributes(
                    CTFontCopyFontDescriptor(faceMatch),
                    extraAttrs as CFDictionary
                )
                weighted = CTFontCreateCopyWithAttributes(faceMatch, CGFloat(sizePx), nil, desc)
            } else {
                weighted = faceMatch
            }
        } else {
            var attrs: [CFString: Any] = [
                kCTFontFamilyNameAttribute: familyName,
                kCTFontTraitsAttribute: traits,
            ]
            if !featureSettings.isEmpty {
                attrs[kCTFontFeatureSettingsAttribute] = featureSettings as CFArray
            }
            if !variationSettings.isEmpty {
                attrs[kCTFontVariationAttribute] = variationSettings as CFDictionary
            }
            let weightDesc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
            let matched = CTFontCreateWithFontDescriptor(weightDesc, CGFloat(sizePx), nil)
            if (CTFontCopyFamilyName(matched) as String).caseInsensitiveCompare(familyName) == .orderedSame {
                weighted = matched
            } else {
                var copyAttrs: [CFString: Any] = [kCTFontTraitsAttribute: traits]
                if !featureSettings.isEmpty {
                    copyAttrs[kCTFontFeatureSettingsAttribute] = featureSettings as CFArray
                }
                if !variationSettings.isEmpty {
                    copyAttrs[kCTFontVariationAttribute] = variationSettings as CFDictionary
                }
                let desc = CTFontDescriptorCreateCopyWithAttributes(
                    CTFontCopyFontDescriptor(baseFont),
                    copyAttrs as CFDictionary
                )
                weighted = CTFontCreateCopyWithAttributes(baseFont, CGFloat(sizePx), nil, desc)
            }
        }
        lock.lock()
        fontCache[key] = weighted
        lock.unlock()
        return weighted
    }

    private final class CTRunDelegateWidthBox {
        let widthPx: CGFloat
        let ascentPx: CGFloat
        let descentPx: CGFloat
        init(widthPx: CGFloat, ascentPx: CGFloat, descentPx: CGFloat) {
            self.widthPx = widthPx
            self.ascentPx = ascentPx
            self.descentPx = descentPx
        }
    }

    private static func makeWidthDelegate(widthPx: CGFloat, ascentPx: CGFloat, descentPx: CGFloat) -> CTRunDelegate {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: { refCon in
                Unmanaged<CTRunDelegateWidthBox>.fromOpaque(refCon).release()
            },
            getAscent: { refCon in
                Unmanaged<CTRunDelegateWidthBox>.fromOpaque(refCon).takeUnretainedValue().ascentPx
            },
            getDescent: { refCon in
                Unmanaged<CTRunDelegateWidthBox>.fromOpaque(refCon).takeUnretainedValue().descentPx
            },
            getWidth: { refCon in
                Unmanaged<CTRunDelegateWidthBox>.fromOpaque(refCon).takeUnretainedValue().widthPx
            }
        )
        let box = CTRunDelegateWidthBox(widthPx: widthPx, ascentPx: ascentPx, descentPx: descentPx)
        return CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(box).toOpaque())!
    }

    private static func spaceAdvancePx(font: CTFont, letterSpacingPx: Float) -> CGFloat {
        var spaceChar: UniChar = 0x20
        var spaceGlyph: CGGlyph = 0
        let rawW: CGFloat
        if CTFontGetGlyphsForCharacters(font, &spaceChar, &spaceGlyph, 1), spaceGlyph != 0 {
            var adv = CGSize.zero
            rawW = CGFloat(CTFontGetAdvancesForGlyphs(font, .horizontal, &spaceGlyph, &adv, 1))
        } else {
            rawW = CTFontGetSize(font) * 0.5
        }
        return max(0, rawW + CGFloat(letterSpacingPx))
    }

    #endif

    /// Fast cached measurement of plain `text` constrained to `maxWidth` logical points.
    /// When `maxWidth` is non-nil and `style.wrap == .noWrap`, wraps at `maxWidth` per upstream `text::measure`.
    public func measure(
        _ text: String,
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        pills: [PillChip] = [],
        keep requestedKeep: TextKeep = .cached,
        bypassCache requestedBypass: Bool = false,
        pretty: Bool = false
    ) -> Vec2 {
        // `bypassCache` (Slice 3) and `keep: .secret` (kitc) both keep secure text out of every cache.
        let keep: TextKeep = requestedBypass ? .secret : requestedKeep
        let bypassCache = keep == .secret
        if text.isEmpty {
            return Vec2(0, Self.specLineHeight(lineCount: 1, lineHeightPt: style.resolvedLineHeight, scale: pixelScale, exact: style.exactLines))
        }
        var effectiveStyle = style
        if effectiveStyle.fontSmoothing == .systemDefault {
            effectiveStyle.fontSmoothing = smoothing
        }
        if maxWidth != nil && effectiveStyle.wrap == .noWrap {
            effectiveStyle.wrap = .wrap
        }
        let effectivePretty = pretty
            && maxWidth != nil
            && effectiveStyle.wrap == .wrap
            && effectiveStyle.align != .justified
            && effectiveStyle.maxLines == 0
        if keep == .secret || isPreparingLayouts {
            return shapeForMeasure(
                text: text,
                spans: nil,
                pills: pills,
                style: effectiveStyle,
                maxWidth: maxWidth,
                pixelScale: pixelScale,
                pretty: effectivePretty, bypassCache: true
            ).size
        }
        let maxWKey = maxWidth.map { Int(($0 * 2.0).rounded()) } ?? -1
        let pHash = Self.hashPills(pills)
        let key = MeasureKey(
            text: text,
            style: effectiveStyle,
            maxWidthHalfPt: maxWKey,
            scale100: Int((pixelScale * 100).rounded()),
            pillsHash: pHash,
            fontEpoch: currentFontEpoch,
            pretty: effectivePretty
        )
        if !bypassCache {
            lock.lock()
            if let cached = measureCache[key] {
                measureCache[key] = (cached.size, layoutCommitSeq)
                if effectiveStyle.wrap == .ellipsis || effectiveStyle.maxLines > 0, maxWidth != nil {
                    let eKey = ElisionKey(
                        text: text,
                        spans: nil,
                        style: effectiveStyle,
                        maxWidthHalfPt: maxWKey,
                        scale100: key.scale100,
                        pillsHash: pHash,
                        fontEpoch: key.fontEpoch,
                        langEpoch: TextLanguageRegistry.currentEpoch()
                    )
                    if var entry = elisionCache[eKey] {
                        entry.epoch = elisionEpoch
                        elisionCache[eKey] = entry
                    }
                }
                lock.unlock()
                return cached.size
            }
            lock.unlock()
        }
        let shaped = shapeForMeasure(text: text, spans: nil, pills: pills, style: effectiveStyle, maxWidth: maxWidth, pixelScale: pixelScale, pretty: effectivePretty)
        lock.lock()
        measureMissCount += 1
        if !bypassCache {
            if measureCache.count > 4096 {
                measureCache.removeAll(keepingCapacity: true)
            }
            measureCache[key] = (shaped.size, layoutCommitSeq)
        }
        lock.unlock()
        return shaped.size
    }

    private func shapeForMeasure(
        text: String,
        spans: [TextSpan]?,
        pills: [PillChip],
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        pretty: Bool = false,
        bypassCache: Bool = false
    ) -> ShapedText {
        measureRuntimePhase(.text) {
            shapeImpl(
                text: text,
                spans: spans,
                pills: pills,
                style: style,
                maxWidth: maxWidth,
                pixelScale: pixelScale,
                emitGlyphs: false,
                glidePx: .zero,
                countRebreak: false,
                bypassCache: bypassCache,
                pretty: pretty
            )
        }
    }

    private static func widthsMatch(_ a: Float?, _ b: Float?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x - y) <= 0.1
        default: return false
        }
    }

    #if canImport(CoreText) && canImport(CoreGraphics)

    /// Retains and re-breaks laid-out text across commits (`text_rebreak` / `TextLayoutBox`).
    public func layoutKeyed(
        text: String,
        spans: [TextSpan]? = nil,
        pills: [PillChip] = [],
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        emitGlyphs: Bool,
        glidePx: Vec2 = .zero,
        keep: TextKeep = .cached,
        countAsRebreak: Bool = true,
        pretty: Bool = false,
        rasterWindow: TextRasterWindow? = nil
    ) -> TextLayoutBox {
        if emitGlyphs, let rasterWindow, keep != .secret, !Self.needsElision(style, maxWidth: maxWidth) {
            let measure = layoutKeyed(text: text, spans: spans, pills: pills, style: style,
                                      maxWidth: maxWidth, pixelScale: pixelScale, emitGlyphs: false,
                                      countAsRebreak: countAsRebreak, pretty: pretty)
            if let prepared = measure.prepared, measure.shaped.lineCount > 1,
               rasterWindow.lowerY > 0 || rasterWindow.upperY < measure.shaped.size.y {
                return paintInWindow(measure, prepared: prepared, window: rasterWindow, glide: glidePx)
            }
            if measure.hasGlyphs, measure.shaped.canReplayGlyphInks, glidePx == .zero { return measure }
        }
        return measureRuntimePhase(.text) {
            let scale = max(pixelScale, 1.0)
            let authText = spans.map { $0.map(\.text).joined() } ?? text
            let effectiveMaxW = maxWidth
            let fEpoch = currentFontEpoch
            let langTag = language
            let shapeKey = TextShapeKey(
                authText: authText,
                spans: spans,
                pills: pills,
                style: style,
                pixelScale: scale,
                fontEpoch: fEpoch,
                languageTag: langTag,
                maxWidth: effectiveMaxW,
                pretty: pretty,
                defaultSmoothing: smoothing
            )
            // Gated by style in `TextShapeKey.layoutPretty`; every break of this layout (first
            // shape, glyph fill, width re-break) uses the key's setting so its cache entry stays coherent.
            let effectivePretty = shapeKey.pretty

            if authText.isEmpty || keep == .secret || Self.needsElision(style, maxWidth: effectiveMaxW) {
                let shaped = shapeImpl(
                    text: text,
                    spans: spans,
                    pills: pills,
                    style: shapeKey.rasterStyle,
                    maxWidth: effectiveMaxW,
                    pixelScale: scale,
                    emitGlyphs: emitGlyphs,
                    glidePx: glidePx,
                    // Secure text never enters the shared shape cache (upstream `Keep::Secret`).
                    bypassCache: keep == .secret,
                    pretty: effectivePretty
                )
                return TextLayoutBox(
                    shapeKey: shapeKey,
                    authText: authText,
                    spans: spans,
                    pills: pills,
                    style: style,
                    pixelScale: scale,
                    maxWidth: effectiveMaxW,
                    shaped: shaped,
                    hasGlyphs: emitGlyphs,
                    prepared: nil
                )
            }

            var storageKey = shapeKey
            if keep == .cached && glidePx == .zero {
                lock.lock()
                storageKey = layoutStorageKey(for: shapeKey, width: effectiveMaxW)
                if var cachedBox = layoutCache[storageKey] {
                    cachedBox.lastUsedCommit = layoutCommitSeq
                    if Self.widthsMatch(cachedBox.maxWidth, effectiveMaxW) {
                        if !emitGlyphs || (cachedBox.hasGlyphs && cachedBox.shaped.canReplayGlyphInks) {
                            lock.unlock()
                            return cachedBox
                        }
                        if let prepared = cachedBox.prepared {
                            _ = layoutCache.removeValue(forKey: storageKey)
                            let unique = isKnownUniquelyReferenced(&cachedBox)
                            lock.unlock()
                            let withGlyphs = breakLines(
                                prepared: prepared,
                                maxWidth: effectiveMaxW,
                                emitGlyphs: true,
                                glidePx: .zero,
                                pretty: effectivePretty
                            )
                            let outBox = unique ? cachedBox : cachedBox.clone()
                            outBox.shaped = withGlyphs
                            outBox.hasGlyphs = true
                            outBox.lastUsedCommit = lock.withLock { layoutCommitSeq }
                            lock.lock()
                            layoutCache[storageKey] = outBox
                            lock.unlock()
                            return outBox
                        }
                        lock.unlock()
                    } else if let prepared = cachedBox.prepared {
                        if countAsRebreak {
                            _ = layoutCache.removeValue(forKey: storageKey)
                            let unique = isKnownUniquelyReferenced(&cachedBox)
                            lock.unlock()
                            let reShaped = breakLines(
                                prepared: prepared,
                                maxWidth: effectiveMaxW,
                                emitGlyphs: emitGlyphs,
                                glidePx: .zero,
                                pretty: effectivePretty
                            )
                            let outBox = unique ? cachedBox : cachedBox.clone()
                            outBox.maxWidth = effectiveMaxW
                            outBox.shaped = reShaped
                            outBox.hasGlyphs = emitGlyphs
                            lock.lock()
                            _rebrokenCount += 1
                            outBox.lastUsedCommit = layoutCommitSeq
                            layoutCache[storageKey] = outBox
                            lock.unlock()
                            return outBox
                        } else {
                            lock.unlock()
                            let probed = breakLines(
                                prepared: prepared,
                                maxWidth: effectiveMaxW,
                                emitGlyphs: emitGlyphs,
                                glidePx: .zero,
                                pretty: effectivePretty
                            )
                            return TextLayoutBox(
                                shapeKey: shapeKey,
                                authText: authText,
                                spans: spans,
                                pills: pills,
                                style: style,
                                pixelScale: scale,
                                maxWidth: effectiveMaxW,
                                shaped: probed,
                                hasGlyphs: emitGlyphs,
                                prepared: prepared
                            )
                        }
                    } else {
                        lock.unlock()
                    }
                } else {
                    lock.unlock()
                }
            }

            let cachedPrepared = lock.withLock { preparedShapeCache[shapeKey] }
            if let prepared = cachedPrepared {
                let shaped = breakLines(
                    prepared: prepared,
                    maxWidth: effectiveMaxW,
                    emitGlyphs: emitGlyphs,
                    glidePx: glidePx,
                    pretty: effectivePretty
                )
                let box = TextLayoutBox(
                    shapeKey: shapeKey,
                    authText: authText,
                    spans: spans,
                    pills: pills,
                    style: style,
                    pixelScale: scale,
                    maxWidth: effectiveMaxW,
                    shaped: shaped,
                    hasGlyphs: emitGlyphs,
                    prepared: prepared
                )
                if keep == .cached && glidePx == .zero && countAsRebreak {
                    lock.lock()
                    box.lastUsedCommit = layoutCommitSeq
                    layoutCache[storageKey] = box
                    lock.unlock()
                }
                return box
            }

            let prepared = prepareShape(
                authText: authText,
                spans: spans,
                pills: pills,
                style: shapeKey.rasterStyle,
                scale: scale,
                languageTag: langTag
            )
            let shaped = breakLines(
                prepared: prepared,
                maxWidth: effectiveMaxW,
                emitGlyphs: emitGlyphs,
                glidePx: glidePx,
                pretty: effectivePretty
            )
            let box = TextLayoutBox(
                shapeKey: shapeKey,
                authText: authText,
                spans: spans,
                pills: pills,
                style: style,
                pixelScale: scale,
                maxWidth: effectiveMaxW,
                shaped: shaped,
                hasGlyphs: emitGlyphs,
                prepared: prepared
            )
            lock.lock()
            _shapedCount += 1
            shapeCallCounter &+= 1
            if keep == .cached {
                preparedShapeCache[shapeKey] = prepared
                if glidePx == .zero && countAsRebreak {
                    box.lastUsedCommit = layoutCommitSeq
                    layoutCache[storageKey] = box
                }
            }
            lock.unlock()
            return box
        }
    }

    /// `box` broken again at `maxWidth` from the shape it holds, without shaping
    /// (`line_break::rebreak` of a kept paragraph, `paragraphs.rs`); nil when it holds none.
    internal func rebreakOwned(_ box: TextLayoutBox, maxWidth: Float?, emitGlyphs: Bool) -> TextLayoutBox? {
        guard let prepared = box.prepared, box.shapeKey.usesSmoothing(smoothing) else { return nil }
        let shaped = measureRuntimePhase(.text) {
            breakLines(prepared: prepared, maxWidth: maxWidth, emitGlyphs: emitGlyphs, glidePx: .zero, pretty: box.shapeKey.pretty)
        }
        lock.withLock { _rebrokenCount += 1 }
        return TextLayoutBox(
            shapeKey: box.shapeKey,
            authText: box.authText,
            spans: box.spans,
            pills: box.pills,
            style: box.style,
            pixelScale: box.pixelScale,
            maxWidth: maxWidth,
            shaped: shaped,
            hasGlyphs: emitGlyphs,
            prepared: prepared
        )
    }

    #endif

    /// Shapes plain or rich text into lines, optional pill/inline-icon quads, and optional `GlyphAtlas` quads.
    public func shape(
        text: String,
        spans: [TextSpan]? = nil,
        pills: [PillChip] = [],
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        emitGlyphs: Bool = true,
        glidePx: Vec2 = .zero,
        bypassCache: Bool = false,
        pretty: Bool = false
    ) -> ShapedText {
        measureRuntimePhase(.text) {
            shapeImpl(
                text: text,
                spans: spans,
                pills: pills,
                style: style,
                maxWidth: maxWidth,
                pixelScale: pixelScale,
                emitGlyphs: emitGlyphs,
                glidePx: glidePx,
                bypassCache: bypassCache,
                pretty: pretty
            )
        }
    }

    private static func needsElision(_ style: TextStyle, maxWidth: Float?) -> Bool {
        style.maxLines > 0 || (style.wrap == .ellipsis && (maxWidth ?? 0) > 0)
    }

    private func shapeImpl(
        text: String,
        spans: [TextSpan]? = nil,
        pills: [PillChip] = [],
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        emitGlyphs: Bool = true,
        glidePx: Vec2 = .zero,
        countRebreak: Bool = true,
        bypassCache requestedBypass: Bool = false,
        pretty: Bool = false
    ) -> ShapedText {
        // Scratch-only elision and fade probes must not fill the unbudgeted run caches.
        let bypassCache = requestedBypass || isPreparingLayouts
        var style = style
        if style.fontSmoothing == .systemDefault { style.fontSmoothing = smoothing }
        let authText = spans.map { $0.map(\.text).joined() } ?? text
        let scale = pixelScale > 0 ? max(pixelScale, 0.0625) : 1.0
        if authText.isEmpty {
            return shapeCoreImpl(
                text: text,
                spans: spans,
                pills: pills,
                style: style,
                maxWidth: maxWidth,
                pixelScale: scale,
                emitGlyphs: emitGlyphs,
                glidePx: glidePx,
                countRebreak: countRebreak,
                bypassCache: bypassCache,
                pretty: false
            )
        }
        syncGlobalFamiliesIfNeeded()
        let pHash = Self.hashPills(pills)
        let fEpoch = currentFontEpoch
        let lEpoch = TextLanguageRegistry.currentEpoch()
        let maxWKey = maxWidth.map { Int(($0 * 2.0).rounded()) } ?? -1
        let scaleKey = Int((scale * 100.0).rounded())
        let needsElide = Self.needsElision(style, maxWidth: maxWidth)
        let canCacheShape = glidePx == .zero && !bypassCache
        let effectivePretty = pretty
            && !needsElide
            && maxWidth != nil
            && (maxWidth ?? 0) > 0
            && style.wrap == .wrap
            && style.align != .justified

        let sKey = canCacheShape ? ShapeKey(
            text: TextUTF8Key(authText),
            spans: spans,
            style: style,
            maxWidthHalfPt: maxWKey,
            scaleBits: scale.bitPattern,
            pillsHash: pHash,
            fontEpoch: fEpoch,
            langEpoch: lEpoch,
            emitGlyphs: emitGlyphs,
            pretty: effectivePretty
        ) : nil

        if let sKey {
            lock.lock()
            if var cached = shapeCache[sKey], cached.shaped.canReplayGlyphInks,
               cached.pages.isEmpty || glyphAtlas.retainPages(cached.pages, since: cached.atlasResets) {
                cached.usedGeneration = layoutCommitSeq
                shapeCache[sKey] = cached
                if cached.shaped.elided != nil {
                    let eKey = ElisionKey(
                        text: authText,
                        spans: spans,
                        style: style,
                        maxWidthHalfPt: maxWKey,
                        scale100: scaleKey,
                        pillsHash: pHash,
                        fontEpoch: fEpoch,
                        langEpoch: lEpoch
                    )
                    if var entry = elisionCache[eKey] {
                        entry.epoch = elisionEpoch
                        elisionCache[eKey] = entry
                    }
                }
                lock.unlock()
                return cached.shaped
            }
            lock.unlock()
        }

        let res: ShapedText
        if needsElide {
            res = resolveElidedShape(
                authText: authText,
                spans: spans,
                pills: pills,
                style: style,
                maxWidth: maxWidth,
                scale: scale,
                emitGlyphs: emitGlyphs,
                pillsHash: pHash,
                maxWidthHalfPt: maxWKey,
                scale100: scaleKey,
                fontEpoch: fEpoch,
                langEpoch: lEpoch,
                glidePx: glidePx,
                bypassCache: bypassCache
            )
        } else {
            res = shapeCoreImpl(
                text: authText,
                spans: spans,
                pills: pills,
                style: style,
                maxWidth: maxWidth,
                pixelScale: scale,
                emitGlyphs: emitGlyphs,
                glidePx: glidePx,
                countRebreak: countRebreak,
                bypassCache: bypassCache,
                pretty: effectivePretty
            )
            lock.lock()
            shapeMissCount += 1
            lock.unlock()
        }

        lock.lock()
        _shapeCount &+= 1
        if let sKey {
            if shapeCache.count > 2048 {
                shapeCache.removeAll(keepingCapacity: true)
            }
            shapeCache[sKey] = CachedShape(shaped: res, usedGeneration: layoutCommitSeq,
                pages: Set(res.glyphs.map(\.atlasPage)), atlasResets: glyphAtlas.resets)
        }
        lock.unlock()
        return res
    }

    private func resolveElidedShape(
        authText: String,
        spans: [TextSpan]?,
        pills: [PillChip],
        style: TextStyle,
        maxWidth: Float?,
        scale: Float,
        emitGlyphs: Bool,
        pillsHash: UInt64,
        maxWidthHalfPt: Int,
        scale100: Int,
        fontEpoch: UInt64,
        langEpoch: UInt64,
        glidePx: Vec2,
        bypassCache: Bool = false
    ) -> ShapedText {
        let eKey: ElisionKey? = (maxWidth != nil && !bypassCache)
            ? ElisionKey(
                text: authText,
                spans: spans,
                style: style,
                maxWidthHalfPt: maxWidthHalfPt,
                scale100: scale100,
                pillsHash: pillsHash,
                fontEpoch: fontEpoch,
                langEpoch: langEpoch
            )
            : nil

        let clampsLines = style.maxLines > 0
        var uncutStyle = style
        uncutStyle.maxLines = 0
        if clampsLines {
            if style.wrap == .noWrap || style.wrap == .ellipsis { uncutStyle.wrap = .wrap }
        } else {
            uncutStyle.wrap = .noWrap
        }
        let width = clampsLines ? maxWidth : nil

        func shape(_ text: String, spans: [TextSpan]?, pills: [PillChip], glyphs: Bool) -> ShapedText {
            shapeCoreImpl(text: text, spans: spans, pills: pills, style: uncutStyle, maxWidth: width,
                          pixelScale: scale, emitGlyphs: glyphs, glidePx: glyphs ? glidePx : .zero,
                          bypassCache: bypassCache)
        }
        func cutShape(_ cut: TextElision, glyphs: Bool = false) -> ShapedText {
            let drawn = cut.drawnString(from: authText)
            let mappedSpans = spans.map { cut.mapSpans($0, originalLength: authText.utf8.count, drawn: drawn) }
            var shaped = shape(drawn, spans: mappedSpans, pills: cut.mapPills(pills), glyphs: glyphs)
            shaped.elided = cut
            shaped.wasTruncated = true
            shaped.drawnText = drawn
            return shaped
        }

        if let eKey, let cached = lock.withLock({ () -> CachedElision? in
            guard var entry = elisionCache[eKey] else { return nil }
            entry.epoch = elisionEpoch
            elisionCache[eKey] = entry
            return entry
        }) {
            return emitGlyphs ? cutShape(cached.elision, glyphs: true) : cached.withoutGlyphs
        }

        let full = shape(authText, spans: spans, pills: pills, glyphs: false)
        let limit = clampsLines ? style.maxLines : 1
        let maxWPx = maxWidth.map { max(1, $0 * scale) } ?? .greatestFiniteMagnitude
        let lastWidth = clampsLines ? full.lineAdvancePx(at: min(limit, full.lineCount) - 1) : full.lastLineAdvancePx
        lock.withLock { shapeMissCount += 1 }
        if full.lineCount <= limit && lastWidth <= maxWPx + 0.5 {
            return emitGlyphs ? shape(authText, spans: spans, pills: pills, glyphs: true) : full
        }
        let measured: ShapedText
        let elision: TextElision
        if clampsLines {
            (measured, elision) = computeClamped(authText: authText, lines: limit, full: full, maxWPx: maxWPx) {
                cutShape($0)
            }
        } else {
            (measured, elision) = computeTruncated(authText: authText, mode: style.elide, maxWPx: maxWPx) {
                cutShape($0)
            }
        }
        if let eKey {
            lock.withLock {
                if elisionCache.count > 2048 { elisionCache.removeAll(keepingCapacity: true) }
                elisionCache[eKey] = CachedElision(elision: elision, withoutGlyphs: measured, epoch: elisionEpoch)
            }
        }
        return emitGlyphs ? cutShape(elision, glyphs: true) : measured
    }

    private func computeClamped(
        authText: String, lines: Int, full: ShapedText, maxWPx: Float,
        measure: (TextElision) -> ShapedText
    ) -> (ShapedText, TextElision) {
        let totalLen = authText.utf8.count
        let lastIdx = min(lines, full.lineCount) - 1
        let start = min(totalLen, full.lineUTF8Range(at: lastIdx).lowerBound)
        let end = (lines < full.lineCount)
            ? min(totalLen, max(start, full.lineUTF8Range(at: lines).upperBound))
            : totalLen
        let utf8 = authText.utf8
        let sIdx = utf8.index(utf8.startIndex, offsetBy: start)
        let eIdx = utf8.index(utf8.startIndex, offsetBy: end)
        let bounds = TextElision.graphemeByteBounds(in: authText[sIdx..<eIdx], baseOffset: start)
        let n = max(0, bounds.count - 1)

        func cut(_ k: Int) -> TextElision {
            var j = k
            while j > 0 && TextElision.isBlankSlice(in: authText, byteRange: bounds[j - 1]..<bounds[j]) {
                j -= 1
            }
            let head: Int
            if j == 0 {
                let pEnd = utf8.index(utf8.startIndex, offsetBy: start)
                var prefix = String(authText[..<pEnd])
                while let last = prefix.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
                    prefix.unicodeScalars.removeLast()
                }
                head = prefix.utf8.count
            } else {
                head = bounds[j]
            }
            return TextElision(head: head, tail: totalLen)
        }

        func fits(_ cand: ShapedText) -> Bool {
            let shownLast = min(lines, cand.lineCount) - 1
            return cand.lineCount <= lines && cand.lineAdvancePx(at: shownLast) <= maxWPx + 0.5
        }

        var lo = 0
        var hi = n
        var best: (Int, ShapedText, TextElision)? = nil
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let e = cut(mid)
            let cand = measure(e)
            if fits(cand) {
                lo = mid
                best = (mid, cand, e)
            } else {
                hi = mid - 1
            }
        }
        if let best, best.0 == lo {
            return (best.1, best.2)
        }
        let finalE = cut(lo)
        let finalCand = measure(finalE)
        return (finalCand, finalE)
    }

    private func computeTruncated(
        authText: String, mode: TextElide, maxWPx: Float,
        measure: (TextElision) -> ShapedText
    ) -> (ShapedText, TextElision) {
        let bounds = TextElision.graphemeByteBounds(in: authText, baseOffset: 0)
        let n = max(0, bounds.count - 1)

        func cut(_ k: Int) -> TextElision {
            var h: Int
            var tCount: Int
            switch mode {
            case .end:
                h = k
                tCount = 0
            case .middle:
                h = k - k / 2
                tCount = k / 2
            case .head:
                h = 0
                tCount = k
            }
            var t = n - tCount
            while h > 0 && TextElision.isBlankSlice(in: authText, byteRange: bounds[h - 1]..<bounds[h]) {
                h -= 1
            }
            while t < n && TextElision.isBlankSlice(in: authText, byteRange: bounds[t]..<bounds[t + 1]) {
                t += 1
            }
            return TextElision(head: bounds[h], tail: bounds[t])
        }

        var lo = 0
        var hi = n
        var best: (Int, ShapedText, TextElision)? = nil
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let e = cut(mid)
            let cand = measure(e)
            if cand.lineCount == 1 && cand.lastLineAdvancePx <= maxWPx + 0.5 {
                lo = mid
                best = (mid, cand, e)
            } else {
                hi = mid - 1
            }
        }
        if let best, best.0 == lo {
            return (best.1, best.2)
        }
        let finalE = cut(lo)
        let finalCand = measure(finalE)
        return (finalCand, finalE)
    }

    #if canImport(CoreText) && canImport(CoreGraphics)
    private func shapeCoreImpl(
        text: String,
        spans: [TextSpan]? = nil,
        pills: [PillChip] = [],
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        emitGlyphs: Bool = true,
        glidePx: Vec2 = .zero,
        countRebreak: Bool = false,
        bypassCache: Bool = false,
        pretty: Bool = false
    ) -> ShapedText {
        let scale = pixelScale > 0 ? max(pixelScale, 0.0625) : 1.0
        let lhPt = style.resolvedLineHeight
        let authText = spans.map { $0.map(\.text).joined() } ?? text

        if authText.isEmpty {
            let emptyH = Self.specLineHeight(lineCount: 1, lineHeightPt: lhPt, scale: scale, exact: style.exactLines)
            let insets = style.blockInsetsPx(at: 0, scale: scale, rtl: style.direction == .rtl) / scale
            let emptyOriginX = style.direction == .rtl ? max(insets.x, (maxWidth ?? 0) - insets.y) : insets.x
            return ShapedText(
                size: Vec2(insets.x, emptyH),
                lineCount: 1,
                lineHeight: lhPt,
                glyphs: [],
                underlines: [],
                backgrounds: [],
                lineStrings: [(0, "", 0, emptyOriginX, nil)],
                forcedDirection: style.direction,
                drawnText: "",
                lineGlyphRanges: [0..<0]
            )
        }
        recordShapeCall()

        let effectiveLang = TextLanguageRegistry.effectiveLanguageTag(for: authText, chosen: language)
        if bypassCache {
            let prepared = prepareShape(authText: authText, spans: spans, pills: pills, style: style,
                                        scale: scale, languageTag: language)
            return breakLines(prepared: prepared, maxWidth: maxWidth, emitGlyphs: emitGlyphs,
                              glidePx: glidePx, styleOverride: style, pretty: pretty)
        }
        let tsKey = TypesetterKey(
            text: authText,
            spans: spans,
            pills: pills,
            style: style,
            scale: scale,
            languageTag: effectiveLang,
            fontEpoch: currentFontEpoch
        )
        let builtPrepared: TextPreparedShape
        lock.lock()
        let hitTS = typesetterCache[tsKey]
        if let hitTS {
            hitTS.lastUsedCommit = layoutCommitSeq
            if countRebreak {
                _typesetterRebrokenCount += 1
            }
        }
        lock.unlock()

        if let hitTS {
            builtPrepared = hitTS
        } else {
            let created = prepareShape(
                authText: authText,
                spans: spans,
                pills: pills,
                style: style,
                scale: scale,
                languageTag: language
            )
            lock.lock()
            if typesetterCache.count > 1024 {
                typesetterCache.removeAll(keepingCapacity: true)
            }
            created.lastUsedCommit = layoutCommitSeq
            typesetterCache[tsKey] = created
            shapedBuildCount += 1
            lock.unlock()
            builtPrepared = created
        }

        return breakLines(
            prepared: builtPrepared,
            maxWidth: maxWidth,
            emitGlyphs: emitGlyphs,
            glidePx: glidePx,
            styleOverride: style,
            pretty: pretty
        )
    }

    private func prepareShape(
        authText: String,
        spans: [TextSpan]?,
        pills: [PillChip],
        style: TextStyle,
        scale: Float,
        languageTag: String?
    ) -> TextPreparedShape {
        let lhPt = style.resolvedLineHeight
        let lhPx = lhPt * scale
        let (shapedText, markerMap, preparedPills) = Self.preparePills(pills, in: authText, fontSize: style.size, isolate: style.byParagraphStart != nil)

        let baseFont = resolveCTFont(style: style, pixelScale: scale)
        let baseAscentPx = CTFontGetAscent(baseFont)
        let baseDescentPx = CTFontGetDescent(baseFont)

        let attrStr = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
        CFAttributedStringReplaceString(attrStr, CFRangeMake(0, 0), shapedText as CFString)
        let fullLen = CFAttributedStringGetLength(attrStr)
        CFAttributedStringSetAttribute(attrStr, CFRangeMake(0, fullLen), kCTFontAttributeName, baseFont)
        if let langTag = TextLanguageRegistry.effectiveLanguageTag(for: authText, chosen: languageTag) {
            CFAttributedStringSetAttribute(attrStr, CFRangeMake(0, fullLen), kCTLanguageAttributeName, langTag as CFString)
        }
        if style.letterSpacing != 0 {
            let kern = CGFloat(style.letterSpacing * scale) as CFNumber
            CFAttributedStringSetAttribute(attrStr, CFRangeMake(0, fullLen), kCTKernAttributeName, kern)
        }

        // Apply per-paragraph base writing direction natively; tab stops use per-'\t' CTRunDelegate widths below.
        let shapedNS = shapedText as NSString
        var paraScanStart = 0
        var previousParaRTL: Bool? = nil
        while paraScanStart < fullLen {
            var paraScanEnd = fullLen
            for i in paraScanStart..<fullLen where shapedNS.character(at: i) == 0x0A {
                paraScanEnd = i
                break
            }
            let paraSub = shapedNS.substring(with: NSRange(location: paraScanStart, length: max(0, paraScanEnd - paraScanStart)))
            let resolvedDir: CTWritingDirection? = Self.paragraphIsRTL(paraSub, style: style, previous: &previousParaRTL)
                .map { $0 ? .rightToLeft : .leftToRight }
            if var dirVal = resolvedDir {
                let pStyle = withUnsafeMutableBytes(of: &dirVal) { dirPtr -> CTParagraphStyle in
                    let setting = CTParagraphStyleSetting(
                        spec: .baseWritingDirection,
                        valueSize: MemoryLayout<CTWritingDirection>.size,
                        value: dirPtr.baseAddress!
                    )
                    return withUnsafePointer(to: setting) { ptr in
                        CTParagraphStyleCreate(ptr, 1)
                    }
                }
                let pRangeLen = min(fullLen - paraScanStart, (paraScanEnd - paraScanStart) + (paraScanEnd < fullLen ? 1 : 0))
                if pRangeLen > 0 {
                    CFAttributedStringSetAttribute(attrStr, CFRangeMake(paraScanStart, pRangeLen), kCTParagraphStyleAttributeName, pStyle)
                }
            }
            paraScanStart = (paraScanEnd < fullLen) ? (paraScanEnd + 1) : fullLen
        }

        // Apply per-span font/color/size overrides in shaped UTF-16 coordinates.
        let spanColorKey = "RuneColorIndex" as CFString
        let pillMarkerKey = "RunePillMarker" as CFString
        var spanPalette: [Color] = []
        var decoratedRanges: [DecoratedRange] = []
        var spanBoxes: [InlineSpanBox] = []
        // `inline_fit::mono_fits`: the smaller spaces that stand for inline code's CSS padding have
        // no box in a browser, so theirs is cut to fit the strut (never growing the line); only for
        // proportional text holding code (`mono_style` turns the strut cut off).
        let cutsCodePadding = !style.family.isMonospace && (spans?.contains(where: { $0.monospace }) ?? false)
        var spanTabInfo: [(u16Range: Range<Int>, spacePx: CGFloat, isMonospace: Bool)] = []
        if let spans {
            var authU16Cursor = 0
            for span in spans {
                let u16Count = span.text.utf16.count
                guard u16Count > 0 else { continue }
                let sLo = markerMap.shapedU16ForSpanBoundary(authU16Cursor, isEnd: false)
                let sHi = markerMap.shapedU16ForSpanBoundary(authU16Cursor + u16Count, isEnd: true)
                let sLen = max(0, sHi - sLo)
                if sLen > 0 {
                    let range = CFRangeMake(sLo, sLen)
                    if span.weight != nil || span.italic || span.monospace || span.size != nil {
                        var subStyle = style
                        if let w = span.weight { subStyle.weight = w }
                        if span.italic { subStyle.italic = true }
                        if span.monospace { subStyle.family = .monospace }
                        if let sz = span.size { subStyle.size = sz }
                        let subFont = resolveCTFont(style: subStyle, pixelScale: scale)
                        CFAttributedStringSetAttribute(attrStr, range, kCTFontAttributeName, subFont)
                        let isCodePadding = cutsCodePadding
                            && !span.monospace
                            && (span.size.map { $0 < style.size } ?? false)
                            && !span.text.isEmpty
                            && span.text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
                        if (span.monospace || span.size != nil) && !isCodePadding {
                            spanBoxes.append(InlineSpanBox(
                                u16Range: sLo..<sHi,
                                ascentPx: Float(CTFontGetAscent(subFont)),
                                descentPx: Float(CTFontGetDescent(subFont)),
                                lineHeightPx: span.size.map { lhPx / style.size * $0 } ?? lhPx
                            ))
                        }
                        spanTabInfo.append((
                            u16Range: sLo..<sHi,
                            spacePx: Self.spaceAdvancePx(font: subFont, letterSpacingPx: style.letterSpacing * scale),
                            isMonospace: span.monospace
                        ))
                    }
                    if let col = span.color {
                        let idx = spanPalette.count
                        spanPalette.append(col)
                        CFAttributedStringSetAttribute(attrStr, range, spanColorKey, idx as CFNumber)
                    }
                    if span.underline || span.strikethrough || span.background != nil {
                        decoratedRanges.append(DecoratedRange(
                            u16Range: sLo..<sHi,
                            underline: span.underline,
                            strikethrough: span.strikethrough,
                            background: span.background,
                            monospace: span.monospace,
                            pad: span.pad
                        ))
                    }
                }
                authU16Cursor += u16Count
            }
        }

        // Install CTRunDelegate width reservations on pill/icon placeholder scalars.
        var pillMarkerU16 = Set<Int>()
        for (pIdx, vp) in preparedPills.enumerated() {
            pillMarkerU16.insert(vp.leadShapedU16)
            let leadDelegate = Self.makeWidthDelegate(
                widthPx: CGFloat(vp.leadWidthPt * scale),
                ascentPx: baseAscentPx,
                descentPx: baseDescentPx
            )
            let leadRange = CFRangeMake(vp.leadShapedU16, 1)
            CFAttributedStringSetAttribute(attrStr, leadRange, kCTFontAttributeName, baseFont)
            CFAttributedStringSetAttribute(attrStr, leadRange, kCTRunDelegateAttributeName, leadDelegate)
            CFAttributedStringSetAttribute(attrStr, leadRange, pillMarkerKey, (pIdx << 1) as CFNumber)
            if let trailU16 = vp.trailShapedU16 {
                pillMarkerU16.insert(trailU16)
                let trailDelegate = Self.makeWidthDelegate(
                    widthPx: CGFloat(vp.trailWidthPt * scale),
                    ascentPx: baseAscentPx,
                    descentPx: baseDescentPx
                )
                let trailRange = CFRangeMake(trailU16, 1)
                CFAttributedStringSetAttribute(attrStr, trailRange, kCTFontAttributeName, baseFont)
                CFAttributedStringSetAttribute(attrStr, trailRange, kCTRunDelegateAttributeName, trailDelegate)
                CFAttributedStringSetAttribute(attrStr, trailRange, pillMarkerKey, ((pIdx << 1) | 1) as CFNumber)
            }
        }

        // Install CTRunDelegate tab width reservations preserving 1:1 string indices (`text/tests.rs:89`).
        if shapedText.contains("\t") {
            let baseSpacePx = Self.spaceAdvancePx(font: baseFont, letterSpacingPx: style.letterSpacing * scale)
            var u16Pos = 0
            var monoCol = 0
            var inMonoSpan = false
            for scalar in shapedText.unicodeScalars {
                let activeSpan = spanTabInfo.first(where: { $0.u16Range.contains(u16Pos) })
                let isMono = (style.family.isMonospace) || (activeSpan?.isMonospace == true)
                if !style.family.isMonospace {
                    if !isMono {
                        inMonoSpan = false
                        monoCol = 0
                    } else if !inMonoSpan {
                        inMonoSpan = true
                        monoCol = 0
                    }
                }
                if scalar.value == 0x0A {
                    monoCol = 0
                } else if scalar.value == 0x09 {
                    let spacePx = activeSpan?.spacePx ?? baseSpacePx
                    let tabWidthPx: CGFloat
                    if isMono {
                        let cols = 4 - (monoCol % 4)
                        tabWidthPx = CGFloat(cols) * spacePx
                        monoCol += cols
                    } else {
                        tabWidthPx = spacePx
                    }
                    let tabDelegate = Self.makeWidthDelegate(
                        widthPx: tabWidthPx,
                        ascentPx: baseAscentPx,
                        descentPx: baseDescentPx
                    )
                    let tabRange = CFRangeMake(u16Pos, 1)
                    CFAttributedStringReplaceString(attrStr, tabRange, "\u{FFFC}" as CFString)
                    CFAttributedStringSetAttribute(attrStr, tabRange, kCTRunDelegateAttributeName, tabDelegate)
                } else if isMono && !pillMarkerU16.contains(u16Pos) {
                    monoCol += 1
                }
                u16Pos += scalar.utf16.count
            }
        }

        // Break into visual lines using CTTypesetter while keeping pill labels & bare icons atomic when they fit.
        let typesetter = CTTypesetterCreateWithAttributedString(attrStr)
        return TextPreparedShape(
            authText: authText,
            shapedText: shapedText,
            style: style,
            scale: scale,
            lhPt: lhPt,
            lhPx: lhPx,
            markerMap: markerMap,
            preparedPills: preparedPills,
            spanPalette: spanPalette,
            decoratedRanges: decoratedRanges,
            baseFont: baseFont,
            baseAscentPx: baseAscentPx,
            baseDescentPx: baseDescentPx,
            attrStr: attrStr,
            typesetter: typesetter,
            spanBoxes: spanBoxes
        )
    }

    private static func isBreakOpportunity(_ u16: unichar) -> Bool {
        u16 == 0x20 || u16 == 0x09 || u16 == 0x00AD
            || (u16 >= 0x2000 && u16 <= 0x200B)
            || u16 == 0x2028 || u16 == 0x2029 || u16 == 0x3000
            || (u16 >= 0x4E00 && u16 <= 0x9FFF)
            || (u16 >= 0x3040 && u16 <= 0x30FF)
            || (u16 >= 0xAC00 && u16 <= 0xD7AF)
    }

    private func breakLines(
        prepared: TextPreparedShape,
        maxWidth: Float?,
        emitGlyphs: Bool,
        glidePx: Vec2,
        styleOverride: TextStyle? = nil,
        pretty: Bool = false,
        emitDecorations: Bool = false
    ) -> ShapedText {
        let authText = prepared.authText
        let shapedText = prepared.shapedText
        let style = styleOverride ?? prepared.style
        let scale = prepared.scale
        let lhPt = style.resolvedLineHeight
        let lhPx = lhPt * scale
        var markerMap = prepared.markerMap
        let preparedPills = prepared.preparedPills
        let decoratedRanges = prepared.decoratedRanges
        let baseFont = prepared.baseFont
        let baseAscentPx = prepared.baseAscentPx
        let baseDescentPx = prepared.baseDescentPx
        let attrStr = prepared.attrStr
        let typesetter = prepared.typesetter
        let pillMarkerKey = "RunePillMarker" as CFString
        let shapedNS = shapedText as NSString
        let fullLen = CFAttributedStringGetLength(attrStr)

        struct VisualLine {
            var ctLine: CTLine
            var authUTF8Start: Int
            var authU16Start: Int
            var authU16End: Int
            var u16Start: Int
            var u16End: Int
            var authSubstr: String
            var widthPx: Float
            var trailingWsPx: Float
            var isRTL: Bool
            var isParaLast: Bool
            var insetsPx: SIMD2<Float>
            var strIndexBase: Int = 0
            var fittingWidthPx: Float? = nil
        }
        var visualLines: [VisualLine] = []
        var anyTruncated = false
        // Inline boxes (pill chips' lead/trail placeholders, bare icons) for pretty wrapping (`#933`).
        var pillBoxU16: Set<Int> = []
        for vp in preparedPills {
            pillBoxU16.insert(vp.leadShapedU16)
            if let t = vp.trailShapedU16 { pillBoxU16.insert(t) }
        }
        var paragraph = 0
        var u16Start = 0
        var authUTF8Cursor = 0
        let authNS = authText as NSString
        var previousLineParaRTL: Bool? = nil

        func authoredSlice(fromAuthU16 a0: Int, toAuthU16 a1: Int) -> String {
            guard a1 > a0, a1 <= authNS.length else { return "" }
            return authNS.substring(with: NSRange(location: a0, length: a1 - a0))
        }

        while u16Start < fullLen {
            var hardEnd = fullLen
            for i in u16Start..<fullLen where shapedNS.character(at: i) == 0x0A {
                hardEnd = i
                break
            }
            let paraShapedSub = shapedNS.substring(with: NSRange(location: u16Start, length: max(0, hardEnd - u16Start)))
            let paraIsRTL: Bool = Self.paragraphIsRTL(paraShapedSub, style: style, previous: &previousLineParaRTL) ?? false
            let insets = style.blockInsetsPx(at: paragraph, scale: scale, rtl: paraIsRTL)
            let availableWidthPx = maxWidth.map { max(1, $0 * scale - insets.x - insets.y) }
            let effectiveWrapWidthPx = style.wrap == .wrap ? availableWidthPx.map { CGFloat($0) } : nil

            let segStart = u16Start
            if segStart == hardEnd {
                let emptyAttr = CFAttributedStringCreate(kCFAllocatorDefault, "" as CFString, [kCTFontAttributeName: baseFont] as CFDictionary)!
                let ctLine = CTLineCreateWithAttributedString(emptyAttr)
                let a0 = markerMap.authU16(forShapedU16: segStart)
                visualLines.append(VisualLine(
                    ctLine: ctLine,
                    authUTF8Start: authUTF8Cursor,
                    authU16Start: a0,
                    authU16End: a0,
                    u16Start: segStart,
                    u16End: segStart,
                    authSubstr: "",
                    widthPx: 0,
                    trailingWsPx: 0,
                    isRTL: paraIsRTL,
                    isParaLast: true,
                    insetsPx: insets
                ))
            } else {
                // kitc's break loop (wrapAnywhere via `CTTypesetterSuggestLineBreak` + surrogate-pair fix;
                // a break landing mid-word extends to the next break opportunity) run per line at
                // `lineCaps[line]` when the pretty pass (`#882`) narrows a line, else at the wrap width.
                func breakParagraph(lineCaps: [Int: CGFloat]?) -> [(ctLine: CTLine, segStart: Int, count: Int, isParaLast: Bool, wPx: Float, twPx: Float, fittingWidthPx: Float, emergency: Bool)] {
                    var cursor = u16Start
                    var out: [(ctLine: CTLine, segStart: Int, count: Int, isParaLast: Bool, wPx: Float, twPx: Float, fittingWidthPx: Float, emergency: Bool)] = []
                    var lineIdxInPara = 0
                    while cursor < hardEnd {
                        var count: CFIndex
                        var emergency = false
                        var hangingStart: Int?
                        if let wrapW = effectiveWrapWidthPx {
                            let targetW = lineCaps?[lineIdxInPara] ?? wrapW
                            let suggested: CFIndex
                            if style.wrapAnywhere {
                                suggested = CTTypesetterSuggestLineBreak(typesetter, cursor, Double(targetW))
                            } else {
                                let raw = CTTypesetterSuggestLineBreak(typesetter, cursor, Double(targetW))
                                suggested = Self.keepUnbrokenWordIntact(raw, segStart: cursor, hardEnd: hardEnd, in: shapedNS)
                            }
                            count = min(max(1, suggested), hardEnd - cursor)
                            if style.wrapAnywhere {
                                let endIdx = cursor + count
                                if endIdx < hardEnd && CFStringIsSurrogateHighCharacter(shapedNS.character(at: endIdx - 1)) {
                                    count += 1
                                }
                                // A word broken inside to fit: Parley's `BreakReason::Emergency` (`#933`).
                                emergency = cursor + count < hardEnd
                                    && !Self.isLineBreakOpportunity(at: cursor + count, in: shapedNS, start: cursor, end: hardEnd)
                            } else if cursor + count < hardEnd {
                                let b = cursor + count
                                if !Self.isBreakOpportunity(shapedNS.character(at: b - 1))
                                    && !Self.isBreakOpportunity(shapedNS.character(at: b)) {
                                    var end = b
                                    while end < hardEnd && !Self.isBreakOpportunity(shapedNS.character(at: end)) {
                                        end += 1
                                    }
                                    while end < hardEnd && (shapedNS.character(at: end) == 0x20 || shapedNS.character(at: end) == 0x09) {
                                        end += 1
                                    }
                                    count = max(1, end - cursor)
                                }
                                // Spaces hang on the preceding line even when its first word overflows.
                                // Keep their authored range for selection and hit testing.
                                let wordEnd = count
                                while cursor + count < hardEnd {
                                    let next = shapedNS.character(at: cursor + count)
                                    guard next == 0x20 || next == 0x09 else { break }
                                    count += 1
                                }
                                if count > wordEnd { hangingStart = wordEnd }
                            }
                            // Keep pill chips and bare inline icons attached to their label/word when they fit on a line.
                            let tentativeEnd = cursor + count
                            for vp in preparedPills {
                                let fullLo = vp.leadShapedU16
                                let fullHi = (vp.trailShapedU16 ?? max(vp.labelShapedU16Hi - 1, vp.leadShapedU16)) + 1
                                if tentativeEnd > fullLo && tentativeEnd < fullHi && fullLo > cursor {
                                    count = fullLo - cursor
                                    break
                                }
                            }
                            count = max(1, count)
                        } else {
                            count = hardEnd - cursor
                        }
                        let isParaLast = (cursor + count >= hardEnd)
                        let cfRange = CFRangeMake(cursor, count)
                        var ctLine = CTTypesetterCreateLine(typesetter, cfRange)
                        if style.wrap == .ellipsis, let availableWidthPx {
                            let maxWPx = Double(availableWidthPx)
                            let rawW = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
                            if rawW > maxWPx + 0.5 {
                                let ellipAttr = CFAttributedStringCreate(
                                    kCFAllocatorDefault,
                                    "…" as CFString,
                                    [kCTFontAttributeName: baseFont] as CFDictionary
                                )!
                                let token = CTLineCreateWithAttributedString(ellipAttr)
                                let truncType: CTLineTruncationType = switch style.elide {
                                case .end: .end
                                case .middle: .middle
                                case .head: .start
                                }
                                if let truncated = CTLineCreateTruncatedLine(ctLine, maxWPx, truncType, token) {
                                    ctLine = truncated
                                } else {
                                    ctLine = token
                                }
                                anyTruncated = true
                            }
                        } else if style.align == .justified && !isParaLast && style.wrap == .wrap, let availableWidthPx {
                            var trimmed = count
                            while trimmed > 1 {
                                let ch = shapedNS.character(at: cursor + trimmed - 1)
                                if ch == 0x20 || ch == 0x09 {
                                    trimmed -= 1
                                } else {
                                    break
                                }
                            }
                            let baseLine = trimmed < count ? CTTypesetterCreateLine(typesetter, CFRangeMake(cursor, trimmed)) : ctLine
                            let targetWPx = Double(availableWidthPx)
                            if let jLine = CTLineCreateJustifiedLine(baseLine, 1.0, targetWPx) {
                                ctLine = jLine
                            }
                        }
                        let wPx = Float(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
                        let twPx = Float(CTLineGetTrailingWhitespaceWidth(ctLine))
                        var fittingWidthPx = wPx
                        if let hangingStart, hangingStart < count {
                            // Keep the overflowing word's measured advance, including nonbreaking
                            // spaces within it. The full CTLine still supplies every caret and glyph.
                            let word = CTTypesetterCreateLine(typesetter, CFRangeMake(cursor, hangingStart))
                            let wordWidthPx = Float(CTLineGetTypographicBounds(word, nil, nil, nil))
                            let available = isParaLast ? max(0, (maxWidth ?? 0) * scale - insets.x - insets.y) : 0
                            fittingWidthPx = max(wordWidthPx, min(wPx, available))
                        }
                        out.append((ctLine, cursor, count, isParaLast, wPx, twPx, fittingWidthPx, emergency))
                        cursor += count
                        lineIdxInPara += 1
                    }
                    return out
                }

                var paraLines = breakParagraph(lineCaps: nil)
                // `#933`: pills and `wrapAnywhere` text wrap prettily too (`line_break::break_new`
                // breaks once with the pills' adjustments, scores, then breaks again with the caps
                // first and the pills' adjustments after them).
                if pretty, style.paragraphBlocks.isEmpty,
                   let wrapW = effectiveWrapWidthPx,
                   style.wrap == .wrap,
                   style.align != .justified,
                   style.maxLines == 0,
                   style.elide == .end,
                   !style.family.isMonospace,
                   !paraIsRTL,
                   paraLines.count >= 2 {
                    let greedyInfos: [PrettyLineBreaker.GreedyLineInfo] = paraLines.map { entry in
                        let runs = CTLineGetGlyphRuns(entry.ctLine) as? [CTRun] ?? []
                        let hasRTL = runs.contains { CTRunGetStatus($0).contains(.rightToLeft) }
                        return PrettyLineBreaker.GreedyLineInfo(
                            u16Start: entry.segStart,
                            u16End: entry.segStart + entry.count,
                            widthPx: entry.wPx,
                            trailingWsPx: entry.twPx,
                            hasRTLRun: hasRTL,
                            ctLine: entry.ctLine,
                            strIndexBase: 0,
                            isEmergency: entry.emergency
                        )
                    }
                    if let caps = PrettyLineBreaker.prettyLineCaps(
                        lines: greedyInfos,
                        in: shapedNS,
                        fontSizePt: style.size,
                        scale: scale,
                        maxWidthPx: Float(wrapW),
                        boxU16: pillBoxU16
                    ) {
                        let rebroken = breakParagraph(lineCaps: caps)
                        if rebroken.count == paraLines.count {
                            paraLines = rebroken
                        }
                    }
                }

                for entry in paraLines {
                    let a0 = markerMap.authU16(forShapedU16: entry.segStart)
                    let a1 = markerMap.authU16(forShapedU16: entry.segStart + entry.count)
                    let sub = authoredSlice(fromAuthU16: a0, toAuthU16: a1)
                    visualLines.append(VisualLine(
                        ctLine: entry.ctLine,
                        authUTF8Start: authUTF8Cursor,
                        authU16Start: a0,
                        authU16End: a1,
                        u16Start: entry.segStart,
                        u16End: entry.segStart + entry.count,
                        authSubstr: sub,
                        widthPx: entry.wPx,
                        trailingWsPx: entry.twPx,
                        isRTL: paraIsRTL,
                        isParaLast: entry.isParaLast,
                        insetsPx: insets,
                        fittingWidthPx: entry.fittingWidthPx
                    ))
                    authUTF8Cursor += sub.utf8.count
                }
            }
            if hardEnd < fullLen && shapedNS.character(at: hardEnd) == 0x0A {
                paragraph += 1
                authUTF8Cursor += 1
                u16Start = hardEnd + 1
                if u16Start == fullLen {
                    let emptyAttr = CFAttributedStringCreate(kCFAllocatorDefault, "" as CFString, [kCTFontAttributeName: baseFont] as CFDictionary)!
                    let ctLine = CTLineCreateWithAttributedString(emptyAttr)
                    let a0 = markerMap.authU16(forShapedU16: u16Start)
                    visualLines.append(VisualLine(
                        ctLine: ctLine,
                        authUTF8Start: authUTF8Cursor,
                        authU16Start: a0,
                        authU16End: a0,
                        u16Start: u16Start,
                        u16End: u16Start,
                        authSubstr: "",
                        widthPx: 0,
                        trailingWsPx: 0,
                        isRTL: style.direction == .rtl,
                        isParaLast: true,
                        insetsPx: style.blockInsetsPx(at: paragraph, scale: scale, rtl: style.direction == .rtl)
                    ))
                }
            } else {
                u16Start = hardEnd
            }
        }

        let maxLineWidthPx = visualLines.reduce(Float(0)) { max($0, $1.insetsPx.x + $1.widthPx) }
        let containerWidthPx = maxWidth.map { max(maxLineWidthPx, $0 * scale) } ?? maxLineWidthPx
        let ascentPx = Float(baseAscentPx)
        let descentPx = Float(baseDescentPx)

        // Inline code grows its line as Blink's does (`#983`, `inline_fit.rs`): each line's code
        // boxes past the strut's push its baseline down and the next lines with it.
        let spanBoxes = prepared.spanBoxes
        var lineGrowthPx: [(over: Float, under: Float)] = []
        var grownBoxes: [InlineCodeBox.LineBox] = []
        var grownLineHeightsPx: [Float] = []
        var grownExtraPx: Float = 0
        let strutParleyOverPx = InlineCodeBox.quantizedBox(ascentPx: ascentPx, descentPx: descentPx, lineHeightPx: lhPx).over
        if !spanBoxes.isEmpty {
            var anyGrown = false
            lineGrowthPx.reserveCapacity(visualLines.count)
            for item in visualLines {
                let code = spanBoxes.compactMap { b -> (ascentPx: Float, descentPx: Float, lineHeightPx: Float)? in
                    (b.u16Range.lowerBound < item.u16End && item.u16Start < b.u16Range.upperBound)
                        ? (b.ascentPx, b.descentPx, b.lineHeightPx) : nil
                }
                let g = InlineCodeBox.lineGrowth(strut: (ascentPx, descentPx), code: code, lineHeightPx: lhPx)
                if g.over > 0 || g.under > 0 { anyGrown = true }
                lineGrowthPx.append(g)
            }
            if anyGrown {
                // Parley's quantized line boxes: tops at the running `line_y` rounded, bottoms
                // `(baseline + under).round()`, the layout as tall as the unrounded line heights.
                let boxes = InlineCodeBox.lineBoxes(growth: lineGrowthPx, lineHeightPx: lhPx)
                grownBoxes = boxes.lines
                grownExtraPx = boxes.heightPx - Float(visualLines.count) * lhPx
                grownLineHeightsPx = boxes.lines.map(\.heightPx)
            } else {
                lineGrowthPx = []
            }
        }

        // CoreText clusters use UTF-16 indices in the string containing pill markers.
        // Carry authored bytes to paint so bidi runs and ligatures take their mark's ink.
        let byteAtUTF16 = emitGlyphs ? authoredByteOffsets(prepared) : []
        var glyphsOut: [PositionedGlyph] = []
        var underlinesOut: [SIMD4<Float>] = []
        var underlineLineEnds: [Float] = []
        let placementEpoch = emitGlyphs ? glyphAtlas.resets : 0
        var glyphPensOut: [GlyphPen] = []
        var strikethroughsOut: [SIMD4<Float>] = []
        var rawBackgroundsOut: [(SIMD4<Float>, Color)] = []
        var pillChipsOut: [ShapedText.PillChipQuad] = []
        var inlineIconsOut: [ShapedText.InlineIconQuad] = []
        var lineRecords: [(utf8Start: Int, text: String, originY: Float, originX: Float, ctLine: CTLine?)] = []
        var lineMarkerRanges: [ShapedText.MarkerMap.LineRange] = []
        var lineGlyphRanges: [Range<Int>] = []
        lineRecords.reserveCapacity(visualLines.count)
        lineMarkerRanges.reserveCapacity(visualLines.count)
        lineGlyphRanges.reserveCapacity(visualLines.count)

        let invS = 1.0 / scale
        let ascentPt = ascentPx * invS
        let strokeThicknessPt = max(1.0, style.size * 0.07)
        let pm = PillMetrics(size: style.size)

        var lineBaselines: [Float] = []
        lineBaselines.reserveCapacity(visualLines.count)
        for (lineIdx, item) in visualLines.enumerated() {
            let lineStartGlyphIdx = glyphsOut.count
            let lineTopPx = lineIdx < grownBoxes.count ? grownBoxes[lineIdx].topPx : Float(lineIdx) * lhPx
            let growOverPx = lineIdx < lineGrowthPx.count ? lineGrowthPx[lineIdx].over : 0
            // Parley rounds the running line top before adding its quantized span-box ascent.
            let baselineYPx = lineTopPx.rounded() + strutParleyOverPx + growOverPx
            lineBaselines.append(baselineYPx)
            let insetRight = maxWidth == nil ? 0 : item.insetsPx.y
            let alignmentWidthPx = !style.hasBlockInsets ? containerWidthPx : (maxWidth.map { $0 * scale } ?? maxLineWidthPx)
            let lineWidthPx = CGFloat(max(0, alignmentWidthPx - item.insetsPx.x - insetRight))
            let flushOffsetPx: Float
            switch style.align {
            case .leading:
                if item.isRTL {
                    flushOffsetPx = max(0, Float(CTLineGetPenOffsetForFlush(item.ctLine, 1.0, lineWidthPx)))
                } else {
                    flushOffsetPx = 0
                }
            case .center:
                flushOffsetPx = max(0, Float(CTLineGetPenOffsetForFlush(item.ctLine, 0.5, lineWidthPx)))
            case .trailing:
                if item.isRTL {
                    flushOffsetPx = 0
                } else {
                    flushOffsetPx = max(0, Float(CTLineGetPenOffsetForFlush(item.ctLine, 1.0, lineWidthPx)))
                }
            case .justified:
                if !item.isParaLast && style.wrap == .wrap && maxWidth != nil {
                    flushOffsetPx = 0
                } else if item.isRTL {
                    flushOffsetPx = max(0, Float(CTLineGetPenOffsetForFlush(item.ctLine, 1.0, lineWidthPx)))
                } else {
                    flushOffsetPx = 0
                }
            }
            let alignOffsetPx = item.insetsPx.x + flushOffsetPx
            let originXPt = alignOffsetPx * invS
            let originYPt = lineTopPx * invS
            lineRecords.append((
                utf8Start: item.authUTF8Start,
                text: item.authSubstr,
                originY: originYPt,
                originX: originXPt,
                ctLine: item.ctLine
            ))
            lineMarkerRanges.append(.init(
                shapedU16Start: item.u16Start,
                shapedU16End: item.u16End,
                authU16Start: item.authU16Start,
                authU16End: item.authU16End,
                authUTF8Start: item.authUTF8Start
            ))

            if (emitGlyphs || emitDecorations) && !decoratedRanges.isEmpty && item.u16End > item.u16Start {
                // Span backgrounds per glyph run (`decorations.rs`, `#983`): inline code's box is its
                // font's content area, other spans balance on the cap height, whole device px;
                // touching runs with one background merge into a rect as tall as the widest run.
                if decoratedRanges.contains(where: { $0.background != nil }) {
                    var pieces: [(x0: Float, padPx: Float, run: InlineCodeBox.RunBackground)] = []
                    let lineRuns = CTLineGetGlyphRuns(item.ctLine) as? [CTRun] ?? []
                    for dec in decoratedRanges {
                        guard let bg = dec.background else { continue }
                        let lo = max(item.u16Start, dec.u16Range.lowerBound)
                        let hi = min(item.u16End, dec.u16Range.upperBound)
                        guard hi > lo else { continue }
                        for run in lineRuns {
                            let r = CTRunGetStringRange(run)
                            let rLo = max(lo, r.location + item.strIndexBase)
                            let rHi = min(hi, r.location + r.length + item.strIndexBase)
                            guard rHi > rLo else { continue }
                            let attrs = CTRunGetAttributes(run) as NSDictionary
                            guard let rf = attrs[kCTFontAttributeName] else { continue }
                            let runFont = rf as! CTFont
                            let a = Float(CTLineGetOffsetForStringIndex(item.ctLine, rLo - item.strIndexBase, nil))
                            let b = Float(CTLineGetOffsetForStringIndex(item.ctLine, rHi - item.strIndexBase, nil))
                            let x0 = alignOffsetPx + min(a, b)
                            let w = abs(b - a)
                            guard w * invS > 0.01 else { continue }
                            let capPx = Float(CTFontGetCapHeight(runFont))
                            let v = InlineCodeBox.backgroundVertical(
                                baselinePx: baselineYPx,
                                mono: dec.monospace,
                                ascentPx: Float(CTFontGetAscent(runFont)),
                                descentPx: Float(CTFontGetDescent(runFont)),
                                capHeightPx: capPx > 0 ? capPx : nil,
                                fontSizePx: Float(CTFontGetSize(runFont))
                            )
                            let padPx = dec.pad * scale
                            let l = (x0 - padPx).rounded()
                            let rr = (x0 + w + padPx).rounded()
                            pieces.append((x0, padPx, InlineCodeBox.RunBackground(
                                rect: SIMD4<Float>(l, v.top, rr - l, v.bottom - v.top),
                                color: bg
                            )))
                        }
                    }
                    pieces.sort { $0.x0 < $1.x0 }
                    var merged: [InlineCodeBox.RunBackground] = []
                    var lastBg: Int? = nil
                    for p in pieces {
                        InlineCodeBox.appendMerging(p.run, pad: p.padPx, into: &merged, last: &lastBg)
                    }
                    for m in merged {
                        rawBackgroundsOut.append((m.rect * invS, m.color))
                    }
                }
                var lineGlyphEndPx: Float? = nil
                for dec in decoratedRanges where dec.underline || dec.strikethrough {
                    let lo = max(item.u16Start, dec.u16Range.lowerBound)
                    let hi = min(item.u16End, dec.u16Range.upperBound)
                    guard hi > lo else { continue }
                    let x0Px = Float(CTLineGetOffsetForStringIndex(item.ctLine, lo - item.strIndexBase, nil))
                    let x1Px = Float(CTLineGetOffsetForStringIndex(item.ctLine, hi - item.strIndexBase, nil))
                    let xPt = originXPt + min(x0Px, x1Px) * invS
                    let wPt = abs(x1Px - x0Px) * invS
                    guard wPt > 0.01 else { continue }
                    if dec.underline {
                        let uy = baselineYPx * invS + max(1.0, style.size * 0.12)
                        underlinesOut.append(SIMD4<Float>(xPt, uy, wPt, strokeThicknessPt))
                        // Where its line's glyph runs end (points, alignment in), for `underline_edges`:
                        // inline boxes (pills, inline icons) don't count (`underline.rs:12-15`).
                        if lineGlyphEndPx == nil { lineGlyphEndPx = Self.glyphRunsEndPx(item.ctLine) }
                        underlineLineEnds.append((alignOffsetPx + (lineGlyphEndPx ?? item.widthPx)) * invS)
                    }
                    if dec.strikethrough {
                        let sy = baselineYPx * invS - ascentPt * 0.35
                        strikethroughsOut.append(SIMD4<Float>(xPt, sy, wPt, strokeThicknessPt))
                    }
                }
            }

            let runs = CTLineGetGlyphRuns(item.ctLine) as? [CTRun] ?? []

            // Compute pill chips and bare inline-icon quads from line placeholder runs.
            if !preparedPills.isEmpty {
                var markerBoxes: [Int: (xPx: Float, wPx: Float)] = [:]
                for run in runs {
                    let attrs = CTRunGetAttributes(run) as NSDictionary
                    if let markerId = attrs[pillMarkerKey] as? Int {
                        let n = CTRunGetGlyphCount(run)
                        var pos = CGPoint.zero
                        if n > 0 {
                            CTRunGetPositions(run, CFRangeMake(0, 1), &pos)
                        }
                        let wPx = Float(CTRunGetTypographicBounds(run, CFRangeMake(0, n), nil, nil, nil))
                        markerBoxes[markerId] = (alignOffsetPx + Float(pos.x), wPx)
                    }
                }
                let lineVisibleEndPx = alignOffsetPx + max(0, item.widthPx - item.trailingWsPx)

                // A strong caret at an isolate boundary can sit on the far side of its
                // neighbor. The label's own visual advances determine the chip and icon.
                func labelGeometry(_ pill: PreparedPill) -> (left: Float, right: Float, ascent: Float, descent: Float) {
                    let lo = max(item.u16Start, pill.labelShapedU16Lo) - item.strIndexBase
                    let hi = min(item.u16End, pill.labelShapedU16Hi) - item.strIndexBase
                    var left = Float.greatestFiniteMagnitude, right = -Float.greatestFiniteMagnitude
                    var ascent: Float = 0, descent: Float = 0
                    for run in runs {
                        let range = CTRunGetStringRange(run)
                        guard lo < hi, lo < range.location + range.length, range.location < hi else { continue }
                        let attrs = CTRunGetAttributes(run) as NSDictionary
                        guard attrs[pillMarkerKey] == nil, let value = attrs[kCTFontAttributeName] else { continue }
                        let font = value as! CTFont
                        ascent = max(ascent, Float(CTFontGetAscent(font)))
                        descent = max(descent, Float(CTFontGetDescent(font)))
                        let count = CTRunGetGlyphCount(run)
                        guard count > 0 else { continue }
                        var indices = [CFIndex](repeating: 0, count: count)
                        var positions = [CGPoint](repeating: .zero, count: count)
                        var advances = [CGSize](repeating: .zero, count: count)
                        CTRunGetStringIndices(run, CFRange(), &indices)
                        CTRunGetPositions(run, CFRange(), &positions)
                        CTRunGetAdvances(run, CFRange(), &advances)
                        for i in indices.indices where lo <= indices[i] && indices[i] < hi {
                            let x0 = alignOffsetPx + Float(positions[i].x)
                            let x1 = x0 + Float(advances[i].width)
                            left = min(left, x0, x1)
                            right = max(right, x0, x1)
                        }
                    }
                    return (left, right, ascent, descent)
                }
                // Bare inline icons (`pills.rs` / `pill_chips.rs:6-41`).
                for (pIdx, vp) in preparedPills.enumerated() where vp.pill.isBare {
                    guard let box = markerBoxes[pIdx << 1] else { continue }
                    let label = labelGeometry(vp)
                    var (asc, desc) = (label.ascent, label.descent)
                    let px = max(1.0, ((vp.pill.icon?.size ?? 14.0) * scale).rounded())
                    if asc <= 0 {
                        asc = px * 0.95
                        desc = px * 0.25
                    }
                    let yPx = (baselineYPx + (desc - asc) * 0.5 - px * 0.5).rounded()
                    let xPx = (abs(box.xPx - label.right) < 1.0 ? (box.xPx + box.wPx - px) : box.xPx).rounded()
                    inlineIconsOut.append(ShapedText.InlineIconQuad(
                        pillIndex: vp.pillIndex,
                        pill: vp.pill,
                        rect: SIMD4<Float>(xPx * invS, yPx * invS, px * invS, px * invS),
                        cornerRadius: vp.pill.bareRadius,
                        image: vp.pill.bareImage,
                        icon: vp.pill.icon?.svg,
                        color: vp.pill.style.color
                    ))
                }

                // Rounded pill chips (`pill_chips.rs:47-153`).
                var starts: [(pIdx: Int, lead: (xPx: Float, wPx: Float)?)] = []
                for (pIdx, vp) in preparedPills.enumerated() where !vp.pill.isBare {
                    if let lead = markerBoxes[pIdx << 1] {
                        starts.append((pIdx, lead))
                    } else if vp.labelShapedU16Lo < item.u16Start && item.u16Start < vp.labelShapedU16Hi {
                        starts.append((pIdx, nil))
                    }
                }
                let marginPx = pm.margin * scale
                for (pIdx, leadBox) in starts {
                    let vp = preparedPills[pIdx]
                    let trailBox = markerBoxes[(pIdx << 1) | 1]
                    let padPx = pm.resolvedPad(style: vp.pill.style) * scale
                    let label = labelGeometry(vp)
                    let (grX0, grX1) = (label.left, label.right)
                    var (asc, desc) = (label.ascent, label.descent)
                    if asc <= 0 {
                        asc = style.size * scale * 0.95
                        desc = style.size * scale * 0.25
                    }
                    let topPx = (baselineYPx - asc - 1.0 * scale).rounded()
                    let botPx = (baselineYPx + desc + 1.0 * scale).rounded()

                    guard let lead = leadBox else {
                        if grX0 > grX1 { continue }
                        let x1Raw = trailBox.flatMap { abs($0.xPx - grX1) < 1.0 ? ($0.xPx + $0.wPx - marginPx) : nil }
                            ?? (trailBox == nil ? lineVisibleEndPx : (grX1 + padPx))
                        let x0Px = min(grX0, alignOffsetPx)
                        let rectPx = SIMD4<Float>(x0Px.rounded(), topPx, max(0, x1Raw - x0Px).rounded(), botPx - topPx)
                        let rectPt = rectPx * invS
                        pillChipsOut.append(ShapedText.PillChipQuad(
                            pillIndex: vp.pillIndex,
                            rect: rectPt,
                            background: vp.pill.style.background,
                            ring: vp.pill.style.ring,
                            cornerRadius: min(5.0, rectPt.w * 0.5)
                        ))
                        continue
                    }

                    let hasGlyphs = grX0 <= grX1
                    let rtlLead = hasGlyphs && abs(lead.xPx - grX1) < 1.0
                    let x0Px: Float
                    let x1Px: Float
                    if hasGlyphs {
                        x0Px = rtlLead
                            ? (grX0 - padPx)
                            : max(grX0 - (lead.wPx - marginPx), lead.xPx + marginPx)
                        if let t = trailBox, abs(t.xPx - grX1) < 1.0 {
                            x1Px = t.xPx + t.wPx - marginPx
                        } else if rtlLead {
                            x1Px = lead.xPx + lead.wPx - marginPx
                        } else if trailBox == nil {
                            x1Px = lineVisibleEndPx
                        } else {
                            x1Px = grX1 + padPx
                        }
                    } else {
                        x0Px = lead.xPx + marginPx
                        x1Px = trailBox.map { $0.xPx + $0.wPx - marginPx } ?? lineVisibleEndPx
                    }
                    let rectPx = SIMD4<Float>(x0Px.rounded(), topPx, max(0, x1Px - x0Px).rounded(), botPx - topPx)
                    let rectPt = rectPx * invS
                    var iconRectPt: SIMD4<Float>? = nil
                    if vp.pill.icon?.svg != nil {
                        let iconPx = max(1.0, (pm.icon * scale).rounded())
                        let ixPx = (rtlLead ? (rectPx.x + rectPx.z - padPx - iconPx) : (rectPx.x + padPx)).rounded()
                        let iyPx = ((topPx + botPx - iconPx) * 0.5).rounded()
                        iconRectPt = SIMD4<Float>(ixPx * invS, iyPx * invS, iconPx * invS, iconPx * invS)
                    }
                    pillChipsOut.append(ShapedText.PillChipQuad(
                        pillIndex: vp.pillIndex,
                        rect: rectPt,
                        background: vp.pill.style.background,
                        ring: vp.pill.style.ring,
                        cornerRadius: min(5.0, rectPt.w * 0.5),
                        icon: vp.pill.icon?.svg,
                        iconRect: iconRectPt,
                        iconColor: vp.pill.style.color
                    ))
                }
            }

            if emitGlyphs {
                emitLineGlyphs(runs, prepared: prepared, markerMap: markerMap, byteAtUTF16: byteAtUTF16,
                               style: style, alignOffsetPx: alignOffsetPx, baselineYPx: baselineYPx,
                               glidePx: glidePx, glyphsOut: &glyphsOut, glyphPensOut: &glyphPensOut)
            }
            lineGlyphRanges.append(lineStartGlyphIdx..<glyphsOut.count)
        }

        markerMap.lines = lineMarkerRanges
        let backgroundsOut = Self.mergeContiguousBackgrounds(rawBackgroundsOut)
        let totalHeightPt = Self.specLineHeight(lineCount: max(1, visualLines.count), lineHeightPt: lhPt, scale: scale, exact: style.exactLines, extraPt: grownExtraPx * invS)
        // A text box is as wide as its widest line to a 64th of a device pixel (`text_width`, #934).
        let measuredWidthPx = visualLines.reduce(Float(0)) { max($0, $1.insetsPx.x + ($1.fittingWidthPx ?? $1.widthPx)) }
        let totalWidthPt = TextBoxGeometry.textWidth(measuredWidthPx) / scale
        var shapedOut = ShapedText(
            size: Vec2(totalWidthPt, totalHeightPt),
            lineCount: max(1, visualLines.count),
            lineHeight: lhPt,
            glyphs: glyphsOut,
            underlines: underlinesOut,
            strikethroughs: strikethroughsOut,
            backgrounds: backgroundsOut,
            pillChips: pillChipsOut,
            inlineIcons: inlineIconsOut,
            lineStrings: lineRecords,
            markerMap: markerMap,
            forcedDirection: style.direction,
            primaryIsRTL: (style.direction == .rtl) || (style.direction == nil && (visualLines.first?.isRTL ?? false)),
            wasTruncated: anyTruncated,
            lastLineAdvancePx: visualLines.last?.widthPx ?? 0,
            hangingAdvancePx: visualLines.last?.trailingWsPx ?? 0,
            lastLineWidthPx: visualLines.last?.widthPx ?? 0,
            lastLineTrailingWsPx: visualLines.last?.trailingWsPx ?? 0,
            drawnText: authText,
            lineAdvancesPx: visualLines.map { ($0.widthPx, $0.trailingWsPx) },
            lineGlyphRanges: lineGlyphRanges
        )
        shapedOut.grownLineTopsPt = grownBoxes.map { $0.topPx * invS }
        shapedOut.grownLineHeightsPt = grownBoxes.map { ($0.bottomPx - $0.topPx) * invS }
        shapedOut.grownLineMetricHeightsPt = grownLineHeightsPx.map { $0 * invS }
        shapedOut.lineIsRTL = visualLines.map(\.isRTL)
        shapedOut.lineBaselinesPx = lineBaselines
        shapedOut.underlineLineEndsPt = underlineLineEnds
        shapedOut.usesPaintInks = emitGlyphs && GlyphAtlas.baseInkBucket != nil
        shapedOut.glyphPens = glyphPensOut.count == glyphsOut.count ? glyphPensOut : []
        if !shapedOut.glyphPens.isEmpty {
            shapedOut.glyphPlacements = TextBoxGeometry.GlyphPlacements(glyphs: glyphsOut, since: placementEpoch)
        }
        return shapedOut
    }

    private func authoredByteOffsets(_ prepared: TextPreparedShape) -> [Int] {
        if let offsets = lock.withLock({ prepared.utf8AtUTF16 }) { return offsets }
        let text = prepared.authText
        var offsets: [Int] = []
        if text.utf8.count != text.utf16.count {
            offsets.reserveCapacity(text.utf16.count + 1)
            var byte = 0
            for scalar in text.unicodeScalars {
                offsets.append(byte)
                if scalar.utf16.count == 2 { offsets.append(byte) }
                byte += scalar.utf8.count
            }
            offsets.append(byte)
        }
        lock.withLock { prepared.utf8AtUTF16 = offsets }
        return offsets
    }

    private func emitLineGlyphs(
        _ runs: [CTRun], prepared: TextPreparedShape, markerMap: ShapedText.MarkerMap,
        byteAtUTF16: [Int], style: TextStyle, alignOffsetPx: Float, baselineYPx: Float,
        glidePx: Vec2, glyphsOut: inout [PositionedGlyph], glyphPensOut: inout [GlyphPen]
    ) {
        let spanPalette = prepared.spanPalette
        let spanColorKey = "RuneColorIndex" as CFString
        let pillMarkerKey = "RunePillMarker" as CFString
        let invS = 1 / prepared.scale
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            if attrs[kCTRunDelegateAttributeName] != nil || attrs[pillMarkerKey] != nil {
                continue
            }
            let glyphCount = CTRunGetGlyphCount(run)
            if glyphCount == 0 { continue }
            let runFont = (attrs[kCTFontAttributeName] as! CTFont)
            let runFontSizePx = Float(CTFontGetSize(runFont))
            let runIsColor = GlyphAtlas.isColorFont(runFont)
            let runColor: Color? = (attrs[spanColorKey] as? Int).flatMap { idx in
                (0..<spanPalette.count).contains(idx) ? spanPalette[idx] : nil
            }

            let runInk: UInt8
            if let baseInk = GlyphAtlas.baseInkBucket, style.fontSmoothing == .on || style.fontSmoothing == .windfoil {
                runInk = runColor.flatMap { GlyphAtlas.inkBucket(SIMD4($0.r, $0.g, $0.b, $0.a), encoded: false) } ?? baseInk
            } else {
                runInk = 0
            }

            var glyphs = Array<CGGlyph>(repeating: 0, count: glyphCount)
            var positions = Array<CGPoint>(repeating: .zero, count: glyphCount)
            var indices = Array<CFIndex>(repeating: 0, count: glyphCount)
            CTRunGetStringIndices(run, CFRangeMake(0, glyphCount), &indices)
            CTRunGetGlyphs(run, CFRangeMake(0, glyphCount), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, glyphCount), &positions)

            for i in 0..<glyphCount {
                let authoredIndex = max(0, markerMap.authU16(forShapedU16: indices[i]))
                let byte = byteAtUTF16.isEmpty ? authoredIndex : byteAtUTF16[min(authoredIndex, byteAtUTF16.count - 1)]
                let gxPx = alignOffsetPx + Float(positions[i].x)
                let gyPx = baselineYPx - Float(positions[i].y)
                if runIsColor, let colorEntry = glyphAtlas.rasterizeColorGlyph(
                    font: runFont,
                    glyph: glyphs[i],
                    fontSizePx: runFontSizePx
                ), colorEntry.pixelSize.x > 0 && colorEntry.pixelSize.y > 0 {
                    let quadXPx = roundf(gxPx) + colorEntry.bearingPx.x
                    let quadYPx = roundf(gyPx) + colorEntry.bearingPx.y
                    glyphPensOut.append(GlyphPen(font: runFont, glyph: glyphs[i], sizePx: runFontSizePx, xPx: gxPx, glideX: 0, binY: 0, smoothing: style.fontSmoothing, isColor: true, yOffsetPx: -Float(positions[i].y)))
                    glyphsOut.append(PositionedGlyph(
                        rect: SIMD4<Float>(
                            quadXPx * invS,
                            quadYPx * invS,
                            Float(colorEntry.pixelSize.x) * invS,
                            Float(colorEntry.pixelSize.y) * invS
                        ),
                        colorGlyph: colorEntry,
                        color: runColor,
                        utf8Offset: byte
                    ))
                    continue
                }

                let pen = TextBoxGeometry.glyphPen(at: gxPx, ppem: runFontSizePx, glide: glidePx.x, smoothing: style.fontSmoothing)
                let phases = Float(GlyphAtlas.glidePhases)
                let y = gyPx.rounded() * phases + (glidePx.y * phases).rounded()
                let quadYPx = floorf(y / phases)
                let binYArg = UInt8(y - quadYPx * phases)
                guard let entry = glyphAtlas.rasterizeGlyph(
                    font: runFont,
                    glyph: glyphs[i],
                    fontSizePx: runFontSizePx,
                    phaseX: pen.phase,
                    subpixelYBin: binYArg,
                    smoothing: style.fontSmoothing,
                    inkBucket: runInk
                ), entry.pixelSize.x > 0 && entry.pixelSize.y > 0 else {
                    continue
                }

                let quadXPx = pen.pixel + entry.bearingPx.x
                let finalQuadYPx = quadYPx + entry.bearingPx.y
                glyphPensOut.append(GlyphPen(font: runFont, glyph: glyphs[i], sizePx: runFontSizePx, xPx: gxPx,
                                             glideX: glidePx.x, binY: binYArg, smoothing: style.fontSmoothing, isColor: false,
                                             yOffsetPx: -Float(positions[i].y), phase: pen.phase, bearingX: entry.bearingPx.x,
                                             maskTexels: UInt32(entry.pixelSize.x * entry.pixelSize.y)))
                var positioned = PositionedGlyph(
                    rect: SIMD4<Float>(
                        quadXPx * invS,
                        finalQuadYPx * invS,
                        Float(entry.pixelSize.x) * invS,
                        Float(entry.pixelSize.y) * invS
                    ),
                    uv: entry.uv,
                    color: runColor,
                    atlasPage: entry.page,
                    utf8Offset: byte
                )
                positioned.classicInk = entry.classicInk
                positioned.outlineGroup = entry.outlineGroup
                glyphsOut.append(positioned)
            }
        }
    }

    /// Reuses the measured layout and retained CTLines while a large document scrolls.
    /// Only lines whose ink can reach the clip acquire atlas entries.
    private func paintInWindow(_ measured: TextLayoutBox, prepared: TextPreparedShape,
                               window: TextRasterWindow, glide: Vec2) -> TextLayoutBox {
        let resets = glyphAtlas.resets
        let previous = lock.withLock { measured.windowPaint }
        let matchingWidth = previous?.box.maxWidth == measured.maxWidth
        if let previous, matchingWidth, previous.window == window, previous.glide == glide, previous.box.shaped.canReplayGlyphInks,
           glyphAtlas.retainPages(previous.box.desktopPages, since: previous.resets) {
            return previous.box
        }
        let byteAtUTF16 = authoredByteOffsets(prepared)
        let box = measured.clone()
        if !prepared.decoratedRanges.isEmpty && !measured.hasGlyphs {
            if let prior = previous?.box.shaped, matchingWidth {
                box.shaped.underlines = prior.underlines
                box.shaped.underlineLineEndsPt = prior.underlineLineEndsPt
                box.shaped.strikethroughs = prior.strikethroughs
                box.shaped.backgrounds = prior.backgrounds
            } else {
                box.shaped = breakLines(prepared: prepared, maxWidth: measured.maxWidth, emitGlyphs: false,
                                        glidePx: glide, pretty: measured.shapeKey.pretty, emitDecorations: true)
            }
        }
        var glyphs: [PositionedGlyph] = []
        var pens: [GlyphPen] = []
        let layout = box.shaped
        // Empty ranges before/after the window retain original line numbers for caret/outline paint.
        var ranges = Array(repeating: 0..<0, count: layout.lineStrings.count)
        let band = window.expanded(for: measured.style, spans: measured.spans, scale: prepared.scale)
        let rows = band.lines(in: layout)
        for row in rows {
            let rec = layout.lineStrings[row]
            let start = glyphs.count
            if let line = rec.ctLine {
                emitLineGlyphs(CTLineGetGlyphRuns(line) as? [CTRun] ?? [],
                               prepared: prepared, markerMap: layout.markerMap, byteAtUTF16: byteAtUTF16,
                               style: prepared.style, alignOffsetPx: rec.originX * prepared.scale,
                               baselineYPx: layout.lineBaselinesPx[row], glidePx: glide,
                               glyphsOut: &glyphs, glyphPensOut: &pens)
            }
            ranges[row] = start..<glyphs.count
        }
        if rows.upperBound < ranges.count {
            let end = glyphs.count
            ranges.replaceSubrange(rows.upperBound..., with: repeatElement(end..<end, count: ranges.count - rows.upperBound))
        }
        box.shaped.glyphs = glyphs
        box.shaped.usesPaintInks = GlyphAtlas.baseInkBucket != nil
        box.shaped.glyphPens = pens
        box.shaped.glyphPlacements = pens.isEmpty ? nil : TextBoxGeometry.GlyphPlacements(glyphs: glyphs, since: resets)
        box.shaped.lineGlyphRanges = ranges
        box.hasGlyphs = true
        box.rasterWindow = window
        box.desktopPages = Set(glyphs.map(\.atlasPage))
        lock.withLock { measured.windowPaint = (window, glide, resets, box) }
        return box
    }

    /// Where a line's glyph runs end (line px): the furthest right edge of a run that draws glyphs,
    /// run delegates (pills, inline icons) left out, as `underline_edges` takes `GlyphRun`s only.
    private static func glyphRunsEndPx(_ line: CTLine) -> Float {
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        var end: Float = 0
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            if attrs[kCTRunDelegateAttributeName] != nil || attrs["RunePillMarker" as CFString] != nil { continue }
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            var pos = CGPoint.zero
            CTRunGetPositions(run, CFRangeMake(0, 1), &pos)
            let w = Float(CTRunGetTypographicBounds(run, CFRangeMake(0, n), nil, nil, nil))
            end = max(end, Float(pos.x) + w)
        }
        return end
    }

    private static func globalShapedU16Index(in shaped: ShapedText, lineIdx: Int, authUTF8: Int, ctLine: CTLine) -> Int {
        let rec = shaped.lineStrings[lineIdx]
        let localUTF8 = rec.text.graphemeByte(atOrBefore: max(authUTF8, rec.utf8Start) - rec.utf8Start)
        let caret = rec.text.utf8.index(rec.text.startIndex, offsetBy: localUTF8)
        let localAuthU16 = rec.text[..<caret].utf16.count
        if lineIdx < shaped.markerMap.lines.count && !shaped.markerMap.entries.isEmpty {
            let lineMeta = shaped.markerMap.lines[lineIdx]
            let globalAuthU16 = lineMeta.authU16Start + localAuthU16
            return shaped.markerMap.shapedU16(forAuthU16: globalAuthU16)
                .clamped(to: lineMeta.shapedU16Start...lineMeta.shapedU16End)
        }
        let ctRange = CTLineGetStringRange(ctLine)
        return ctRange.location + localAuthU16
    }

    /// Computes caret `(x, y, height)` in element-local logical points for `utf8Offset` in `shaped`.
    public func caretRect(in shaped: ShapedText, utf8Offset: Int, pixelScale: Float) -> SIMD4<Float> {
        let scale = pixelScale > 0 ? max(pixelScale, 0.0625) : 1.0
        guard !shaped.lineStrings.isEmpty else {
            return caretRectPortable(in: shaped, utf8Offset: utf8Offset, pixelScale: scale)
        }
        var chosenIdx = shaped.lineStrings.count - 1
        for i in 0..<shaped.lineStrings.count {
            let rec = shaped.lineStrings[i]
            let endUTF8 = rec.utf8Start + rec.text.utf8.count
            if utf8Offset <= endUTF8 {
                chosenIdx = i
                break
            }
        }
        let rec = shaped.lineStrings[chosenIdx]
        var xPt = rec.originX
        if let ctLine = rec.ctLine {
            let globalU16 = Self.globalShapedU16Index(in: shaped, lineIdx: chosenIdx, authUTF8: utf8Offset, ctLine: ctLine)
            let offsetPx = CTLineGetOffsetForStringIndex(ctLine, globalU16, nil)
            xPt += Float(offsetPx) / scale
        }
        return SIMD4<Float>(xPt, rec.originY, 1.5, shaped.lineBoxHeightPt(chosenIdx))
    }

    /// Hit-tests `(localX, localY)` in element-local logical points to a UTF-8 byte offset.
    public func hitTestUTF8Offset(in shaped: ShapedText, localX: Float, localY: Float, pixelScale: Float) -> Int {
        guard !shaped.lineStrings.isEmpty else {
            return hitTestUTF8OffsetPortable(in: shaped, localX: localX, localY: localY, pixelScale: pixelScale)
        }
        let scale = pixelScale > 0 ? max(pixelScale, 0.0625) : 1.0
        let lineIdx = shaped.lineIndex(atLocalY: localY, lineCount: shaped.lineStrings.count)
        let rec = shaped.lineStrings[lineIdx]
        guard let ctLine = rec.ctLine, !rec.text.isEmpty else {
            return rec.utf8Start
        }
        let relXPx = CGFloat((localX - rec.originX) * scale)
        let u16Idx = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: relXPx, y: 0))
        if u16Idx == kCFNotFound {
            return rec.utf8Start
        }
        let localU16: Int
        if lineIdx < shaped.markerMap.lines.count && !shaped.markerMap.entries.isEmpty {
            let lineMeta = shaped.markerMap.lines[lineIdx]
            let clampedShaped = u16Idx.clamped(to: lineMeta.shapedU16Start...lineMeta.shapedU16End)
            let authU16 = shaped.markerMap.authU16(forShapedU16: clampedShaped)
            localU16 = authU16 - lineMeta.authU16Start
        } else {
            localU16 = u16Idx - CTLineGetStringRange(ctLine).location
        }
        let byte = ImeUTF16Bridge.utf8Offset(in: rec.text, fromUTF16Offset: localU16)
        let hit = rec.utf8Start + rec.text.graphemeByte(atOrBefore: byte)
        return min(hit, shaped.endBeforeNewline(on: lineIdx))
    }

    /// Computes per-line selection rectangles `[x, y, width, height]` in logical points for `utf8Range`.
    public func selectionRects(in shaped: ShapedText, utf8Range: Range<Int>, pixelScale: Float) -> [SIMD4<Float>] {
        guard !utf8Range.isEmpty else { return [] }
        if shaped.lineStrings.isEmpty {
            return selectionRectsPortable(in: shaped, utf8Range: utf8Range, pixelScale: pixelScale)
        }
        // A by-paragraph field's paragraphs each box their own bytes (`TextFlow::range_boxes`).
        if !shaped.paragraphSpans.isEmpty {
            return paragraphSelectionRects(in: shaped, utf8Range: utf8Range, pixelScale: pixelScale)
        }
        return selectionRects(in: shaped, lines: 0..<shaped.lineStrings.count, utf8Range: utf8Range, pixelScale: pixelScale)
    }

    /// `selectionRects` over lines `lines` of `shaped` only (one paragraph of a by-paragraph field).
    internal func selectionRects(in shaped: ShapedText, lines: Range<Int>, utf8Range: Range<Int>, pixelScale: Float) -> [SIMD4<Float>] {
        guard !utf8Range.isEmpty, !shaped.lineStrings.isEmpty else { return [] }
        let scale = pixelScale > 0 ? max(pixelScale, 0.0625) : 1.0
        let invS = 1.0 / scale
        var rects: [SIMD4<Float>] = []
        for lineIdx in lines {
            let rec = shaped.lineStrings[lineIdx]
            let lineStart = rec.utf8Start
            let lineEnd = lineStart + rec.text.utf8.count
            let lo = max(lineStart, utf8Range.lowerBound)
            let hi = min(lineEnd, utf8Range.upperBound)
            if hi <= lo && shaped.selectsHardBreak(after: lineIdx, end: lineEnd, selection: utf8Range) {
                let endX = caretRect(in: shaped, utf8Offset: lineEnd, upstream: true, pixelScale: pixelScale).x
                rects.append(SIMD4<Float>(endX, rec.originY, 4.0, shaped.lineBoxHeightPt(lineIdx)))
                continue
            }
            guard hi > lo else { continue }
            let x0: Float
            let x1: Float
            if let ctLine = rec.ctLine {
                if ctLine.hasMixedRunDirections {
                    let cells = shaped.coreTextVisualCells(on: lineIdx, in: ctLine)
                    cells.appendSelectionRects(for: lo..<hi, origin: Vec2(rec.originX, rec.originY),
                                               height: shaped.lineBoxHeightPt(lineIdx), toPoints: invS, into: &rects)
                    continue
                }
                let u16Lo = Self.globalShapedU16Index(in: shaped, lineIdx: lineIdx, authUTF8: lo, ctLine: ctLine)
                let u16Hi = Self.globalShapedU16Index(in: shaped, lineIdx: lineIdx, authUTF8: hi, ctLine: ctLine)
                x0 = rec.originX + Float(ctLine.insertionOffset(at: u16Lo, upstream: false)) * invS
                x1 = rec.originX + Float(ctLine.insertionOffset(at: u16Hi, upstream: true)) * invS
            } else {
                x0 = rec.originX
                x1 = rec.originX
            }
            let minX = min(x0, x1)
            let w = max(2.0, abs(x1 - x0))
            rects.append(SIMD4<Float>(minX, rec.originY, w, shaped.lineBoxHeightPt(lineIdx)))
        }
        return rects
    }

    internal func computeInk(_ text: String, style: TextStyle) -> TextInk? {
        guard !text.isEmpty else { return nil }
        let k = TextInkAccumulator.oversample
        let shaped = shape(text: text, spans: nil, style: style, maxWidth: nil, pixelScale: k, emitGlyphs: false)
        let graySpace = CGColorSpaceCreateDeviceGray()
        let rgbSpace = CGColorSpaceCreateDeviceRGB()

        var acc = TextInkAccumulator()
        for (rec, baselineYPx) in zip(shaped.lineStrings, shaped.lineBaselinesPx) {
            guard let ctLine = rec.ctLine else { continue }
            let alignOffsetPx = rec.originX * k
            let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []
            for run in runs {
                let glyphCount = CTRunGetGlyphCount(run)
                if glyphCount == 0 { continue }
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let runFont = (attrs[kCTFontAttributeName] as! CTFont)
                let runIsColor = GlyphAtlas.isColorFont(runFont)

                var glyphs = Array<CGGlyph>(repeating: 0, count: glyphCount)
                var positions = Array<CGPoint>(repeating: .zero, count: glyphCount)
                CTRunGetGlyphs(run, CFRangeMake(0, glyphCount), &glyphs)
                CTRunGetPositions(run, CFRangeMake(0, glyphCount), &positions)

                for i in 0..<glyphCount {
                    var g = glyphs[i]
                    var bbox = CGRect.zero
                    CTFontGetBoundingRectsForGlyphs(runFont, .default, &g, &bbox, 1)
                    if bbox.isEmpty || bbox.width <= 0.01 || bbox.height <= 0.01 {
                        continue
                    }

                    let gxPx = alignOffsetPx + Float(positions[i].x)
                    let floorX = floorf(gxPx)
                    let subX = gxPx - floorX
                    let gyPx = baselineYPx - Float(positions[i].y)

                    let minX = Int(floor(bbox.minX)) - 1
                    let maxX = Int(ceil(bbox.maxX + CGFloat(subX))) + 1
                    let minY = Int(floor(bbox.minY)) - 1
                    let maxY = Int(ceil(bbox.maxY)) + 1
                    let bw = max(1, maxX - minX)
                    let bh = max(1, maxY - minY)

                    if runIsColor {
                        var rgba = Array<UInt8>(repeating: 0, count: bw * bh * 4)
                        guard let ctx = CGContext(
                            data: &rgba,
                            width: bw,
                            height: bh,
                            bitsPerComponent: 8,
                            bytesPerRow: bw * 4,
                            space: rgbSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        ) else { continue }
                        ctx.setAllowsAntialiasing(true)
                        ctx.setShouldAntialias(true)
                        var pos = CGPoint(x: CGFloat(-minX) + CGFloat(subX), y: CGFloat(-minY))
                        CTFontDrawGlyphs(runFont, &g, &pos, 1, ctx)
                        for row in 0..<bh {
                            for col in 0..<bw {
                                let a = Float(rgba[(row * bw + col) * 4 + 3]) / 255.0
                                if a > 0 {
                                    acc.add(
                                        x: floorX + Float(minX) + Float(col),
                                        y: gyPx - Float(maxY) + Float(row),
                                        alpha: a
                                    )
                                }
                            }
                        }
                    } else {
                        var bitmap = Array<UInt8>(repeating: 0, count: bw * bh)
                        guard let ctx = CGContext(
                            data: &bitmap,
                            width: bw,
                            height: bh,
                            bitsPerComponent: 8,
                            bytesPerRow: bw,
                            space: graySpace,
                            bitmapInfo: CGImageAlphaInfo.none.rawValue
                        ) else { continue }
                        ctx.setAllowsAntialiasing(true)
                        ctx.setShouldAntialias(true)
                        ctx.setAllowsFontSmoothing(false)
                        ctx.setShouldSmoothFonts(false)
                        ctx.setAllowsFontSubpixelPositioning(true)
                        ctx.setShouldSubpixelPositionFonts(true)
                        ctx.setFillColor(gray: 1.0, alpha: 1.0)
                        var pos = CGPoint(x: CGFloat(-minX) + CGFloat(subX), y: CGFloat(-minY))
                        CTFontDrawGlyphs(runFont, &g, &pos, 1, ctx)
                        for row in 0..<bh {
                            for col in 0..<bw {
                                let a = Float(bitmap[row * bw + col]) / 255.0
                                if a > 0 {
                                    acc.add(
                                        x: floorX + Float(minX) + Float(col),
                                        y: gyPx - Float(maxY) + Float(row),
                                        alpha: a
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        return acc.finish()
    }
    #else
    public func layoutKeyed(
        text: String,
        spans: [TextSpan]? = nil,
        pills: [PillChip] = [],
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        emitGlyphs: Bool,
        glidePx: Vec2 = .zero,
        keep: TextKeep = .cached,
        countAsRebreak: Bool = true,
        pretty: Bool = false,
        rasterWindow: TextRasterWindow? = nil
    ) -> TextLayoutBox {
        measureRuntimePhase(.text) {
            let scale = max(pixelScale, 1.0)
            let authText = spans.map { $0.map(\.text).joined() } ?? text
            let effectiveMaxW = maxWidth
            let shapeKey = TextShapeKey(
                authText: authText,
                spans: spans,
                pills: pills,
                style: style,
                pixelScale: scale,
                fontEpoch: currentFontEpoch,
                languageTag: language,
                maxWidth: effectiveMaxW,
                pretty: pretty,
                defaultSmoothing: smoothing
            )
            if emitGlyphs, let window = rasterWindow, keep != .secret, !authText.isEmpty,
               !Self.needsElision(style, maxWidth: maxWidth) {
                let measured = cachedLayoutBox(for: shapeKey, matchingWidth: maxWidth)
                    ?? layoutKeyed(text: text, spans: spans, pills: pills, style: style, maxWidth: maxWidth,
                                   pixelScale: scale, emitGlyphs: false, keep: keep,
                                   countAsRebreak: countAsRebreak, pretty: pretty)
                if measured.shaped.lineCount > 1, window.lowerY > 0 || window.upperY < measured.shaped.size.y {
                    return paintPortableWindow(measured, in: window, keep: keep, glidePx: glidePx)
                }
            }
            var storageKey = shapeKey
            if keep == .cached, glidePx == .zero, !authText.isEmpty {
                let cached = lock.withLock { () -> TextLayoutBox? in
                    storageKey = layoutStorageKey(for: shapeKey, width: effectiveMaxW)
                    guard let box = layoutCache[storageKey], Self.widthsMatch(box.maxWidth, effectiveMaxW),
                          !emitGlyphs || box.hasGlyphs else { return nil }
                    box.lastUsedCommit = layoutCommitSeq
                    return box
                }
                if let cached, !emitGlyphs || glyphAtlas.retainPages(cached.desktopPages, since: cached.desktopAtlasResets) {
                    return cached
                }
            }
            let prepared = keep == .cached ? lock.withLock { preparedShapeCache[shapeKey] } : nil
            let box = breakPortable(shapeKey, maxWidth: effectiveMaxW, scale: scale, emitGlyphs: emitGlyphs,
                                    keep: keep, glidePx: glidePx, previousBreak: prepared)
            if keep == .cached {
                #if canImport(CRuneDesktopText) && !canImport(CoreText)
                let native = box.shaped.desktopParagraph
                box.shaped.desktopParagraph = nil
                #endif
                // Probes can reuse a drawn shape at another width without retaining their
                // own layout, native fonts or masks in the shared cache.
                guard glidePx == .zero && countAsRebreak && !authText.isEmpty else { return box }
                lock.withLock {
                    let priorLayout = layoutCache[storageKey]
                    #if canImport(CRuneDesktopText) && !canImport(CoreText)
                    if let native {
                        preparedShapeCache[shapeKey] = native
                        if let priorLayout, !Self.widthsMatch(priorLayout.maxWidth, effectiveMaxW) {
                            _rebrokenCount += 1
                        }
                    }
                    #endif
                    if priorLayout == nil { _shapedCount += 1 }
                    box.lastUsedCommit = layoutCommitSeq
                    box.preparedPass = priorLayout?.preparedPass
                    layoutCache[storageKey] = box
                }
            }
            return box
        }
    }

    private func paintPortableWindow(_ measured: TextLayoutBox, in window: TextRasterWindow,
                                     keep: TextKeep, glidePx: Vec2) -> TextLayoutBox {
        if let cached = lock.withLock({ measured.windowPaint }),
           cached.window == window, cached.glide == glidePx,
           glyphAtlas.retainPages(cached.box.desktopPages, since: cached.resets) {
            return cached.box
        }
        let key = measured.shapeKey
        let scale = measured.pixelScale
        let prefetch = window.expanded(for: key.style, spans: key.spans, scale: scale)
        let box: TextLayoutBox
        #if canImport(CRuneDesktopText) && !canImport(CoreText)
        let prepared = measured.shaped.desktopParagraph ?? lock.withLock { preparedShapeCache[key] }
        var native = lock.withLock { measured.desktopRasterLayout }
        if native == nil, let prepared, key.spans == nil, key.pills.isEmpty, key.style.align != .justified {
            native = DesktopRasterLayout(shaped: measured.shaped, paragraph: prepared)
            lock.withLock { measured.desktopRasterLayout = native }
        }
        if let native {
            let shaped = native.paint(measured.shaped, in: prefetch, scale: scale, glide: glidePx, atlas: glyphAtlas)
            box = TextLayoutBox(shapeKey: key, authText: key.authText, spans: key.spans, pills: key.pills,
                                style: key.style, pixelScale: scale, maxWidth: measured.maxWidth,
                                shaped: shaped, hasGlyphs: true, prepared: nil)
        } else {
            box = breakPortable(key, maxWidth: measured.maxWidth, scale: scale, emitGlyphs: true,
                                keep: keep, glidePx: glidePx, previousBreak: prepared, rasterWindow: prefetch)
        }
        #else
        box = breakPortable(key, maxWidth: measured.maxWidth, scale: scale, emitGlyphs: true,
                            keep: keep, glidePx: glidePx, rasterWindow: prefetch)
        #endif
        let resets = glyphAtlas.resets
        box.rasterWindow = window
        box.desktopPages = Set(box.shaped.glyphs.map(\.atlasPage))
        box.desktopAtlasResets = resets
        lock.withLock {
            measured.lastUsedCommit = layoutCommitSeq
            measured.windowPaint = (window, glidePx, resets, box)
        }
        return box
    }

    private func breakPortable(_ key: TextShapeKey, maxWidth: Float?, scale: Float, emitGlyphs: Bool,
                               keep: TextKeep, glidePx: Vec2 = .zero, previousBreak: ShapedText.DesktopParagraph? = nil,
                               rasterWindow: TextRasterWindow? = nil) -> TextLayoutBox {
        let shaped: ShapedText
        if Self.needsElision(key.style, maxWidth: maxWidth) {
            shaped = shapeImpl(text: key.authText, spans: key.spans, pills: key.pills, style: key.rasterStyle,
                               maxWidth: maxWidth, pixelScale: scale, emitGlyphs: emitGlyphs, glidePx: glidePx,
                               bypassCache: keep == .secret)
        } else {
            shaped = shapePortable(text: key.authText, spans: key.spans, pills: key.pills, style: key.rasterStyle,
                                   maxWidth: maxWidth, pixelScale: scale, emitGlyphs: emitGlyphs,
                                   bypassCache: keep == .secret, nativeFonts: true, pretty: key.pretty,
                                   retain: keep, previousBreak: previousBreak, glidePx: glidePx, rasterWindow: rasterWindow)
        }
        let box = TextLayoutBox(shapeKey: key, authText: key.authText, spans: key.spans, pills: key.pills,
                                style: key.style, pixelScale: scale, maxWidth: maxWidth, shaped: shaped,
                                hasGlyphs: emitGlyphs, prepared: nil)
        if keep != .secret && emitGlyphs {
            box.desktopAtlasResets = glyphAtlas.resets
            box.desktopPages = Set(shaped.glyphs.map(\.atlasPage))
        }
        return box
    }

    internal func rebreakOwned(_ box: TextLayoutBox, maxWidth: Float?, emitGlyphs: Bool) -> TextLayoutBox? {
        #if canImport(CRuneDesktopText) && !canImport(CoreText)
        guard box.shaped.desktopParagraph != nil, box.shapeKey.usesSmoothing(smoothing), box.shapeKey.fontEpoch == currentFontEpoch,
              box.shapeKey.languageTag == language else { return nil }
        let next = measureRuntimePhase(.text) {
            breakPortable(box.shapeKey, maxWidth: maxWidth, scale: box.pixelScale, emitGlyphs: emitGlyphs,
                          keep: .owned, previousBreak: box.shaped.desktopParagraph)
        }
        lock.withLock { _rebrokenCount += 1 }
        return next
        #else
        return nil
        #endif
    }

    private func shapeCoreImpl(
        text: String, spans: [TextSpan]?, pills: [PillChip], style: TextStyle,
        maxWidth: Float?, pixelScale: Float, emitGlyphs: Bool, glidePx: Vec2 = .zero,
        countRebreak: Bool = false, bypassCache: Bool = false, pretty: Bool = false
    ) -> ShapedText {
        shapePortable(text: text, spans: spans, pills: pills, style: style, maxWidth: maxWidth,
                      pixelScale: pixelScale, emitGlyphs: emitGlyphs, bypassCache: bypassCache,
                      nativeFonts: true, pretty: pretty, glidePx: glidePx)
    }

    public func caretRect(in shaped: ShapedText, utf8Offset: Int, pixelScale: Float) -> SIMD4<Float> {
        caretRectPortable(in: shaped, utf8Offset: utf8Offset, pixelScale: pixelScale)
    }

    public func hitTestUTF8Offset(in shaped: ShapedText, localX: Float, localY: Float, pixelScale: Float) -> Int {
        hitTestUTF8OffsetPortable(in: shaped, localX: localX, localY: localY, pixelScale: pixelScale)
    }

    public func selectionRects(in shaped: ShapedText, utf8Range: Range<Int>, pixelScale: Float) -> [SIMD4<Float>] {
        if !shaped.paragraphSpans.isEmpty {
            return paragraphSelectionRects(in: shaped, utf8Range: utf8Range, pixelScale: pixelScale)
        }
        return selectionRectsPortable(in: shaped, utf8Range: utf8Range, pixelScale: pixelScale)
    }

    internal func selectionRects(in shaped: ShapedText, lines: Range<Int>, utf8Range: Range<Int>, pixelScale: Float) -> [SIMD4<Float>] {
        selectionRectsPortable(in: shaped, lines: lines, utf8Range: utf8Range, pixelScale: pixelScale)
    }

    internal func computeInk(_ text: String, style: TextStyle) -> TextInk? {
        #if canImport(CRuneDesktopText) && !canImport(CoreText)
        let scale = TextInkAccumulator.oversample
        var ink = TextInkAccumulator()
        var top: Float = 0
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let line = DesktopTextLine(text: String(paragraph), start: 0, style: style,
                families: families(), language: language, scale: scale, span: { _ in nil }) {
                line.addInk(to: &ink, originYPx: top.rounded())
            }
            top += style.resolvedLineHeight * scale
        }
        return ink.finish()
        #else
        return computeInkPortable(text, style: style)
        #endif
    }
    #endif

    /// Visual wrapped line ranges `(utf8Start, utf8End, originY, originX)` for soft-wrap caret motion.
    public func visualLines(in shaped: ShapedText) -> [(utf8Start: Int, utf8End: Int, originY: Float, originX: Float)] {
        #if canImport(CoreText) && canImport(CoreGraphics)
        if !shaped.lineStrings.isEmpty {
            return shaped.lineStrings.map { ($0.utf8Start, $0.utf8Start + $0.text.utf8.count, $0.originY, $0.originX) }
        }
        #endif
        return shaped.portableLines.map { ($0.utf8Start, $0.utf8Start + $0.text.utf8.count, $0.originY, $0.originX) }
    }

    /// Computes which visual line index owns `(utf8Offset, upstream)` in a soft-wrapped `ShapedText`.
    public func visualLineIndex(in shaped: ShapedText, utf8Offset: Int, upstream: Bool) -> Int {
        shaped.lineIndex(forUTF8Offset: utf8Offset, affinity: upstream ? .upstream : .downstream)
    }

    /// Caret rect honoring the preceding or following grapheme at soft wraps and bidi boundaries.
    public func caretRect(in shaped: ShapedText, utf8Offset: Int, upstream: Bool, pixelScale: Float) -> SIMD4<Float> {
        guard shaped.cursorLineCount > 0 else {
            return SIMD4<Float>(0, 0, 1.5, shaped.lineHeight)
        }
        let lineIdx = visualLineIndex(in: shaped, utf8Offset: utf8Offset, upstream: upstream)
        #if canImport(CoreText) && canImport(CoreGraphics)
        if lineIdx < shaped.lineStrings.count {
            let ctRec = shaped.lineStrings[lineIdx]
            let scale = pixelScale > 0 ? max(pixelScale, 0.0625) : 1.0
            var xPt = ctRec.originX
            if let ctLine = ctRec.ctLine {
                let globalU16 = Self.globalShapedU16Index(in: shaped, lineIdx: lineIdx, authUTF8: utf8Offset, ctLine: ctLine)
                xPt += Float(ctLine.insertionOffset(at: globalU16, upstream: upstream)) / scale
            }
            return SIMD4<Float>(xPt, ctRec.originY, 1.5, shaped.lineBoxHeightPt(lineIdx))
        }
        #endif
        return shaped.portableCaret(on: lineIdx, at: utf8Offset, upstream: upstream)
    }

    // MARK: - Portable (Headless / Linux / Windows / Android / Web) Text Shaping

    internal func measurePortable(
        _ text: String,
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        pills: [PillChip] = [],
        bypassCache: Bool = false,
        nativeFonts: Bool = false,
        pretty: Bool = false
    ) -> Vec2 {
        if text.isEmpty {
            return Vec2(0, Self.specLineHeight(lineCount: 1, lineHeightPt: style.resolvedLineHeight, scale: pixelScale, exact: style.exactLines))
        }
        var effectiveStyle = style
        if effectiveStyle.fontSmoothing == .systemDefault {
            effectiveStyle.fontSmoothing = smoothing
        }
        if maxWidth != nil && effectiveStyle.wrap == .noWrap {
            effectiveStyle.wrap = .wrap
        }
        let key = MeasureKey(
            text: text,
            style: effectiveStyle,
            maxWidthHalfPt: maxWidth.map { Int(($0 * 2.0).rounded()) } ?? -1,
            scale100: Int((pixelScale * 100.0).rounded()),
            pillsHash: Self.hashPills(pills),
            fontEpoch: currentFontEpoch, pretty: pretty, bitmapFallback: !nativeFonts
        )
        if !bypassCache {
            lock.lock()
            if let cached = measureCache[key] {
                measureCache[key] = (cached.size, layoutCommitSeq)
                lock.unlock()
                return cached.size
            }
            lock.unlock()
        }

        let shaped = shapePortable(text: text, spans: nil, pills: pills, style: effectiveStyle, maxWidth: maxWidth, pixelScale: pixelScale, emitGlyphs: false, bypassCache: bypassCache, nativeFonts: nativeFonts, pretty: pretty)
        if !bypassCache {
            lock.lock()
            measureMissCount += 1
            if measureCache.count > 4096 {
                measureCache.removeAll(keepingCapacity: true)
            }
            measureCache[key] = (shaped.size, layoutCommitSeq)
            lock.unlock()
        }
        return shaped.size
    }

    internal func shapePortable(
        text: String,
        spans: [TextSpan]? = nil,
        pills: [PillChip] = [],
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        emitGlyphs: Bool = true,
        bypassCache: Bool = false,
        nativeFonts: Bool = false,
        pretty: Bool = false,
        retain: TextKeep? = nil,
        previousBreak: ShapedText.DesktopParagraph? = nil,
        glidePx: Vec2 = .zero,
        rasterWindow: TextRasterWindow? = nil
    ) -> ShapedText {
        let _ = bypassCache
        let scale = pixelScale > 0 ? max(pixelScale, 0.0625) : 1.0
        let invS = 1.0 / scale
        let lineH = style.resolvedLineHeight
        let fullText = spans.map { $0.map(\.text).joined() } ?? text

        #if canImport(CRuneDesktopText) && !canImport(CoreText)
        let faceBoxes = DesktopFaceBoxes()
        func blankStrut() -> DesktopTextLine? {
            guard nativeFonts else { return nil }
            return DesktopTextLine(text: " ", start: 0, style: style, families: families(),
                                   language: language, scale: scale, faceBoxes: faceBoxes, span: { _ in nil })
        }
        #endif
        if fullText.isEmpty {
            let emptyH = Self.specLineHeight(lineCount: 1, lineHeightPt: lineH, scale: scale, exact: style.exactLines)
            let insets = style.blockInsetsPx(at: 0, scale: scale, rtl: style.direction == .rtl) * invS
            let originX = style.direction == .rtl ? max(insets.x, (maxWidth ?? 0) - insets.y) : insets.x
            #if canImport(CRuneDesktopText) && !canImport(CoreText)
            let strut = blankStrut()
            let newlinePt = (strut?.strutFontHeightPt ?? 0) / 4
            let baselines = strut.map { [$0.strutBaselinePx] } ?? []
            #else
            let newlinePt: Float = 0
            let baselines: [Float] = []
            #endif
            return ShapedText(
                size: Vec2(insets.x, emptyH),
                lineCount: 1,
                lineHeight: lineH,
                glyphs: [],
                underlines: [],
                strikethroughs: [],
                backgrounds: [],
                portableLines: [(0, "", 0, originX, [0])],
                paragraphNewlinePt: newlinePt,
                lineAdvancesPx: [(0, 0)],
                lineBaselinesPx: baselines
            )
        }
        if previousBreak == nil { recordShapeCall() }

        // Map contiguous span UTF-8 byte ranges for per-character attributes.
        var spanEntries: [(utf8Range: Range<Int>, span: TextSpan)] = []
        if let spans {
            var utf8Cursor = 0
            for span in spans {
                let byteCount = span.text.utf8.count
                if byteCount > 0 {
                    spanEntries.append((utf8Cursor..<(utf8Cursor + byteCount), span))
                    utf8Cursor += byteCount
                }
            }
        }

        let pm = PillMetrics(size: style.size)
        let validPills: [(idx: Int, pill: PillChip)] = {
            guard !pills.isEmpty else { return [] }
            let utf8Len = fullText.utf8.count
            let sorted = pills.enumerated().sorted { $0.element.range.lowerBound < $1.element.range.lowerBound }
            var out: [(idx: Int, pill: PillChip)] = []
            var prevEnd = 0
            for (origIdx, p) in sorted {
                let s = p.range.lowerBound
                let e = p.range.upperBound
                guard s >= prevEnd, s < e, e <= utf8Len,
                      InlineIconLayout.isUTF8Boundary(s, in: fullText),
                      InlineIconLayout.isUTF8Boundary(e, in: fullText) else { continue }
                out.append((origIdx, p))
                prevEnd = e
            }
            return out
        }()

        let pillRanges = validPills.map(\.pill.range)
        let isolateRanges = style.byParagraphStart == nil ? [] : pillRanges
        var leadWidths: [Int: Float] = [:], trailWidths: [Int: Float] = [:]
        for (_, pill) in validPills {
            leadWidths[pill.range.lowerBound] = pill.isBare
                ? (pill.icon?.size ?? 14) + pill.bareGap : pm.lead(icon: pill.icon != nil, style: pill.style)
            if !pill.isBare { trailWidths[pill.range.upperBound] = pm.trail(style: pill.style) }
        }
        func leadExtra(atUTF8 offset: Int) -> Float { leadWidths[offset] ?? 0 }
        func trailExtra(endingAtUTF8 offset: Int) -> Float { trailWidths[offset] ?? 0 }
        func pillContaining(_ start: Int, _ end: Int) -> (idx: Int, pill: PillChip)? {
            let i = partitionPoint(validPills) { $0.pill.range.upperBound <= start }
            guard i < validPills.count, validPills[i].pill.range.lowerBound <= start,
                  end <= validPills[i].pill.range.upperBound else { return nil }
            return validPills[i]
        }

        func spanIndex(at byte: Int) -> Int? {
            var lo = 0, hi = spanEntries.count
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if spanEntries[mid].utf8Range.upperBound <= byte { lo = mid + 1 } else { hi = mid }
            }
            return lo < spanEntries.count && spanEntries[lo].utf8Range.contains(byte) ? lo : nil
        }
        func spanAt(utf8Offset: Int) -> TextSpan? {
            spanIndex(at: utf8Offset).map { spanEntries[$0].span }
        }

        #if canImport(CRuneDesktopText) && !canImport(CoreText)
        let nativeFamilies = families()
        let cutsCodePadding = !style.family.isMonospace && spanEntries.contains { $0.span.monospace }
        let hasDecorations = spanEntries.contains { $0.span.background != nil || $0.span.underline || $0.span.strikethrough }
        let tabs = DesktopTabStops(fullText) { style.family.isMonospace || spanAt(utf8Offset: $0)?.monospace == true }
        var nativeWidths: [Int: DesktopTextLine.Cell] = [:]
        var paragraphLayouts: [Int: (text: String, line: DesktopTextLine)] = [:]
        func desktopLine(_ text: String, start: Int, rtl: Bool? = nil,
                         stretch: (Character, Int) -> Float = { _, _ in 0 }) -> DesktopTextLine? {
            guard nativeFonts else { return nil }
            var lineStyle = style
            if let rtl { lineStyle.direction = rtl ? .rtl : .ltr }
            return DesktopTextLine(text: text, start: start, style: lineStyle, families: nativeFamilies, language: language,
                scale: scale, faceBoxes: faceBoxes, cutsCodePadding: cutsCodePadding, pillRanges: pillRanges, tabs: tabs,
                span: { spanAt(utf8Offset: $0) }, stretch: stretch, extra: { byte, end in
                    (leadExtra(atUTF8: byte), trailExtra(endingAtUTF8: end))
                })
        }
        #endif
        func charAdvance(_ ch: Character, atUTF8 utf8Offset: Int) -> Float {
            #if canImport(CRuneDesktopText) && !canImport(CoreText)
            if let cell = nativeWidths[utf8Offset], cell.character == ch {
                return cell.advance + style.letterSpacing
            }
            if nativeFonts, let replacement = desktopLine(String(ch), start: utf8Offset)?.cells[utf8Offset] {
                return replacement.advance + style.letterSpacing
            }
            #endif
            let match = spanAt(utf8Offset: utf8Offset)
            let isMono = match?.monospace == true || style.family.isMonospace
            let fontSz = match?.size ?? style.size
            let count = ch.unicodeScalars.count
            let scalarSum = ch.unicodeScalars.reduce(Float(0)) { acc, scalar in
                acc + PortableGlyphFont.advanceRatio(for: scalar, mono: isMono) * fontSz
            }
            return scalarSum + (count > 0 ? style.letterSpacing : 0)
        }

        // Split into raw lines on '\n' and wrap/ellipsis if requested.
        var lines: [(utf8Start: Int, text: String, width: Float, isRTL: Bool, isParaLast: Bool, insets: SIMD2<Float>)] = []
        var portableTruncated = false
        let rawParagraphs = fullText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        #if canImport(CRuneDesktopText) && !canImport(CoreText)
        let ownedPlainParagraph = retain == .owned && rawParagraphs.count == 1 && spanEntries.isEmpty
            && pills.isEmpty && style.wrap == .wrap && style.maxLines == 0
        let keepNativeParagraph = (retain == .cached || ownedPlainParagraph) && !bypassCache && nativeFonts
        let retained = keepNativeParagraph ? previousBreak : nil
        #endif
        var previousDirection: Bool?
        for (pIdx, slice) in rawParagraphs.enumerated() {
            let cursorUTF8 = fullText.utf8.distance(from: fullText.startIndex, to: slice.startIndex)
            let para = String(slice)
            let isolated = MarkedPillText(para, start: cursorUTF8, ranges: isolateRanges)
            let isRTL = Self.paragraphIsRTL(isolated?.text ?? para, style: style, previous: &previousDirection) ?? false
            #if canImport(CRuneDesktopText) && !canImport(CoreText)
            let paragraphLayout = retained?.linesByStart[cursorUTF8] ?? desktopLine(para, start: cursorUTF8, rtl: isRTL)
            if let paragraphLayout { paragraphLayouts[cursorUTF8] = (para, paragraphLayout) }
            nativeWidths = paragraphLayout?.cells ?? [:]
            #endif
            let insets = style.blockInsetsPx(at: pIdx, scale: scale, rtl: isRTL) * invS
            let availableWidth = maxWidth.map { max(invS, $0 - insets.x - insets.y) }
            if para.isEmpty {
                lines.append((cursorUTF8, "", 0, isRTL, true, insets))
            } else if style.wrap == .wrap, let maxW = availableWidth {
                let usePretty = pretty && !isRTL && style.align != .justified && style.maxLines == 0
                    && !style.family.isMonospace && !containsStrongRTL(para)
                let wrapped = PrettyLineBreaker.wrap(para, width: maxW, fontSize: style.size,
                                                     wrapAnywhere: style.wrapAnywhere, pretty: usePretty,
                                                     utf8Start: cursorUTF8, pillRanges: pillRanges) { ch, local in
                    let byte = cursorUTF8 + local
                    return leadExtra(atUTF8: byte) + charAdvance(ch, atUTF8: byte) + trailExtra(endingAtUTF8: byte + ch.utf8.count)
                }
                for (i, line) in wrapped.enumerated() {
                    lines.append((cursorUTF8 + line.start, line.text, line.width, isRTL, i == wrapped.count - 1, insets))
                }
            } else if style.wrap == .ellipsis, let maxW = availableWidth, maxW > 0 {
                let chars = Array(para)
                var chStarts = [Int]()
                chStarts.reserveCapacity(chars.count + 1)
                var chWidths = [Float]()
                chWidths.reserveCapacity(chars.count)
                var u = cursorUTF8
                var totalParaW: Float = 0
                for ch in chars {
                    let chBytes = String(ch).utf8.count
                    let w = leadExtra(atUTF8: u) + charAdvance(ch, atUTF8: u) + trailExtra(endingAtUTF8: u + chBytes)
                    chStarts.append(u)
                    chWidths.append(w)
                    totalParaW += w
                    u += chBytes
                }
                chStarts.append(u)
                if totalParaW <= maxW + 0.5 * invS {
                    lines.append((cursorUTF8, para, totalParaW, isRTL, true, insets))
                } else {
                    portableTruncated = true
                    let ellW = charAdvance("…", atUTF8: cursorUTF8)
                    let budget = max(0, maxW - ellW)
                    var outStr = "…"
                    var outW = ellW
                    switch style.elide {
                    case .end:
                        var endIdx = 0
                        var wSum: Float = 0
                        while endIdx < chars.count && wSum + chWidths[endIdx] <= budget {
                            wSum += chWidths[endIdx]
                            endIdx += 1
                        }
                        while endIdx > 0 && chars[endIdx - 1].isWhitespace {
                            endIdx -= 1
                            wSum -= chWidths[endIdx]
                        }
                        outStr = String(chars[0..<endIdx]) + "…"
                        outW = wSum + ellW
                    case .head:
                        var startIdx = chars.count
                        var wSum: Float = 0
                        while startIdx > 0 && wSum + chWidths[startIdx - 1] <= budget {
                            startIdx -= 1
                            wSum += chWidths[startIdx]
                        }
                        while startIdx < chars.count && chars[startIdx].isWhitespace {
                            wSum -= chWidths[startIdx]
                            startIdx += 1
                        }
                        outStr = "…" + String(chars[startIdx..<chars.count])
                        outW = ellW + wSum
                    case .middle:
                        var bestHead = 0
                        var bestTail = chars.count
                        var bestW = ellW
                        var lo = 0
                        var hi = chars.count
                        while lo <= hi {
                            let mid = (lo + hi) / 2
                            var h = mid - mid / 2
                            var t = chars.count - mid / 2
                            while h > 0 && chars[h - 1].isWhitespace { h -= 1 }
                            while t < chars.count && chars[t].isWhitespace { t += 1 }
                            let wH = chWidths[0..<h].reduce(0, +)
                            let wT = chWidths[t..<chars.count].reduce(0, +)
                            if wH + wT <= budget {
                                bestHead = h
                                bestTail = t
                                bestW = wH + ellW + wT
                                lo = mid + 1
                            } else {
                                hi = mid - 1
                            }
                        }
                        outStr = String(chars[0..<bestHead]) + "…" + String(chars[bestTail..<chars.count])
                        outW = bestW
                    }
                    lines.append((cursorUTF8, outStr, outW, isRTL, true, insets))
                }
            } else {
                var w: Float = 0
                var charUTF8 = cursorUTF8
                for ch in para {
                    let chBytes = String(ch).utf8.count
                    w += leadExtra(atUTF8: charUTF8) + charAdvance(ch, atUTF8: charUTF8) + trailExtra(endingAtUTF8: charUTF8 + chBytes)
                    charUTF8 += chBytes
                }
                lines.append((cursorUTF8, para, w, isRTL, true, insets))
            }
        }
        if lines.isEmpty {
            lines = [(0, "", 0, false, true, .zero)]
        }
        if style.maxLines > 0 && lines.count > style.maxLines {
            lines = Array(lines.prefix(style.maxLines))
            var last = lines[style.maxLines - 1]
            let ellW = charAdvance("…", atUTF8: last.utf8Start)
            var trimmed = last.text
            while let c = trimmed.last, c.isWhitespace { trimmed.removeLast() }
            if let maxWidth, maxWidth > 0 {
                let maxW = max(invS, maxWidth - last.insets.x - last.insets.y)
                var curW: Float = 0
                var charUTF8 = last.utf8Start
                var kept = ""
                for ch in trimmed {
                    let chBytes = String(ch).utf8.count
                    let chW = leadExtra(atUTF8: charUTF8) + charAdvance(ch, atUTF8: charUTF8) + trailExtra(endingAtUTF8: charUTF8 + chBytes)
                    if curW + chW + ellW > maxW { break }
                    kept.append(ch)
                    curW += chW
                    charUTF8 += chBytes
                }
                while let c = kept.last, c.isWhitespace {
                    let chW = charAdvance(c, atUTF8: last.utf8Start)
                    kept.removeLast()
                    curW = max(0, curW - chW)
                }
                last.text = kept + "…"
                last.width = curW + ellW
            } else {
                last.text = trimmed + "…"
                last.width += ellW
            }
            last.isParaLast = true
            lines[style.maxLines - 1] = last
            portableTruncated = true
        }

        #if canImport(CRuneDesktopText) && !canImport(CoreText)
        let desktopLines = lines.enumerated().map { index, item -> DesktopTextLine? in
            if let paragraph = paragraphLayouts[item.utf8Start], paragraph.text == item.text { return paragraph.line }
            // A new width can leave some exact byte ranges in place. Their glyph order,
            // font fallback and masks remain valid for the same shape key.
            if let retained, retained.fragments.indices.contains(index), let fragment = retained.fragments[index],
               retained.ranges[index] == item.utf8Start..<(item.utf8Start + item.text.utf8.count) {
                return fragment
            }
            return desktopLine(item.text, start: item.utf8Start, rtl: item.isRTL)
        }
        for i in lines.indices {
            if let line = desktopLines[i] { lines[i].width = line.width }
        }
        let strutLine = desktopLines.lazy.compactMap { $0 }.first ?? blankStrut()
        let strutBaselinePx = strutLine?.strutBaselinePx ?? lineH * scale * 0.78
        let lineGrowth = desktopLines.map { $0?.growth ?? (over: 0, under: 0) }
        let grownBoxes: [InlineCodeBox.LineBox]
        let grownExtraPt: Float
        if lineGrowth.contains(where: { $0.over > 0 || $0.under > 0 }) {
            let boxes = InlineCodeBox.lineBoxes(growth: lineGrowth, lineHeightPx: lineH * scale)
            grownBoxes = boxes.lines
            grownExtraPt = (boxes.heightPx - Float(lines.count) * (lineH * scale)) * invS
        } else {
            grownBoxes = []
            grownExtraPt = 0
        }
        #else
        let grownBoxes: [InlineCodeBox.LineBox] = []
        let grownExtraPt: Float = 0
        #endif

        // A text box is as wide as its widest line to a 64th of a device pixel (`text_width`, #934).
        let maxLineW = TextBoxGeometry.boxWidth(maxLineWidthPt: lines.reduce(Float(0)) { max($0, $1.insets.x + $1.width) }, scale: scale)
        let containerWidth = maxWidth.map { max($0, maxLineW) } ?? maxLineW
        let totalH = Self.specLineHeight(lineCount: max(1, lines.count), lineHeightPt: lineH, scale: scale,
                                         exact: style.exactLines, extraPt: grownExtraPt)

        var glyphs: [PositionedGlyph] = []
        var underlines: [SIMD4<Float>] = []
        var strikethroughs: [SIMD4<Float>] = []
        var rawBackgrounds: [(SIMD4<Float>, Color)] = []
        var underlineEnds: [Float] = []
        var pillChipsOut: [ShapedText.PillChipQuad] = []
        var inlineIconsOut: [ShapedText.InlineIconQuad] = []
        var lineRecords: [(utf8Start: Int, text: String, originY: Float, originX: Float, charOffsets: [Float])] = []
        var bidiCells: [Int: [PortableCaretCell]] = [:]
        #if canImport(CRuneDesktopText) && !canImport(CoreText)
        let restingText = emitGlyphs ? DesktopRestingText(glide: glidePx, cache: !bypassCache, rasterWindow: rasterWindow) : nil
        #endif
        var lineGlyphRanges: [Range<Int>] = []

        var baselinesPx: [Float] = []
        var lineAdvancesPx: [(widthPx: Float, trailingWsPx: Float)] = []
        for (idx, item) in lines.enumerated() {
            let lineStartGlyphIdx = glyphs.count
            let lineTopPx = grownBoxes.isEmpty ? Float(idx) * lineH * scale : grownBoxes[idx].topPx
            let originY = lineTopPx * invS
            let boxHeightPt = grownBoxes.isEmpty ? lineH : (grownBoxes[idx].bottomPx - lineTopPx) * invS
            #if canImport(CRuneDesktopText) && !canImport(CoreText)
            let baselinePx = lineTopPx.rounded() + strutBaselinePx + lineGrowth[idx].over
            #else
            let baselinePx = lineTopPx + lineH * scale * 0.78
            #endif
            baselinesPx.append(baselinePx)
            let baselineOffset = baselinePx * invS - originY
            let insetRight = maxWidth == nil ? 0 : item.insets.y
            let alignmentWidth = !style.hasBlockInsets ? containerWidth : (maxWidth ?? maxLineW)
            let availableWidth = max(0, alignmentWidth - item.insets.x - insetRight)
            var hanging: Float = 0
            let lineEnd = item.utf8Start + item.text.utf8.count
            var visibleEnd = lineEnd
            var spaces = 0
            var extraPerSpace: Float = 0
            var justifiedOffset = item.isRTL ? max(0, availableWidth - item.width) : 0
            func expands(_ character: Character) -> Bool { character == " " || character == "\u{00A0}" }
            if style.wrap == .wrap, let maxWidth,
               style.align == .justified || (!validPills.isEmpty && !item.isParaLast) {
                #if canImport(CRuneDesktopText) && !canImport(CoreText)
                nativeWidths = desktopLines[idx]?.cells ?? [:]
                #endif
                // Keep terminal whitespace at its authored advance, beyond the visible edge.
                // A following inline box stops the whitespace from hanging.
                var end = item.text.endIndex
                while end > item.text.startIndex {
                    let previous = item.text.index(before: end)
                    let ch = item.text[previous]
                    guard ch == " " || ch == "\t" || ch == "\u{3000}",
                          trailExtra(endingAtUTF8: visibleEnd) == 0 else { break }
                    let start = visibleEnd - ch.utf8.count
                    #if canImport(CRuneDesktopText) && !canImport(CoreText)
                    if let cell = nativeWidths[start], cell.isRTL != item.isRTL { break }
                    #endif
                    hanging += charAdvance(ch, atUTF8: start)
                    visibleEnd = start
                    end = previous
                    if leadExtra(atUTF8: start) > 0 { break }
                }
                if style.align == .justified {
                    if !item.isParaLast { spaces = item.text[..<end].count(where: expands) }
                    let free = max(0, maxWidth - item.insets.x - insetRight) - item.width + hanging
                    if spaces > 0 { extraPerSpace = max(0, free) / Float(spaces) }
                    if item.isRTL { justifiedOffset = (extraPerSpace > 0 ? 0 : free) - hanging }
                }
            }
            func stretch(_ ch: Character, at byte: Int) -> Float {
                guard extraPerSpace > 0, byte < visibleEnd else { return 0 }
                return expands(ch) ? extraPerSpace : 0
            }
            let flushOffset: Float
            switch style.align {
            case .leading: flushOffset = item.isRTL ? max(0, availableWidth - item.width) : 0
            case .center: flushOffset = max(0, (availableWidth - item.width) * 0.5)
            case .trailing: flushOffset = item.isRTL ? 0 : max(0, availableWidth - item.width)
            case .justified: flushOffset = justifiedOffset
            }
            let originX = item.insets.x + flushOffset

            #if canImport(CRuneDesktopText) && !canImport(CoreText)
            let native = extraPerSpace > 0
                ? desktopLine(item.text, start: item.utf8Start, rtl: item.isRTL, stretch: stretch) : desktopLines[idx]
            let paintNative = emitGlyphs && (native?.hasVisibleInk(in: rasterWindow, baselinePx: baselinePx, glide: glidePx) ?? false)
            var nativeColors: [Int: Color] = [:]
            nativeWidths = native?.cells ?? [:]
            if emitGlyphs, let native, hasDecorations {
                native.appendDecorations(spans: spanEntries, index: spanIndex(at:), originX: originX,
                    baselinePx: baselinePx, style: style, backgrounds: &rawBackgrounds, underlines: &underlines,
                    strikethroughs: &strikethroughs, underlineEnds: &underlineEnds)
            }
            if let native, !native.leadingMarkers.isEmpty || !native.trailingMarkers.isEmpty || native.cells.values.contains(where: \.isRTL) {
                var cells = native.cells.values.map { cell in
                    PortableCaretCell(range: cell.byte..<cell.byteEnd, left: cell.left,
                                      width: cell.advance + stretch(cell.character, at: cell.byte),
                                      rtl: cell.isRTL, space: cell.character == " " || cell.character == "\u{A0}")
                }
                // A marker occupies space in the visual line and one insertion point
                // in the authored text. Clicking anywhere inside it selects that point.
                for (byte, marker) in native.leadingMarkers {
                    cells.append(.init(range: byte..<byte, left: marker.left, width: marker.width,
                                       rtl: marker.rtl, space: false, pillEdge: .leading))
                }
                for (byte, marker) in native.trailingMarkers {
                    cells.append(.init(range: byte..<byte, left: marker.left, width: marker.width,
                                       rtl: marker.rtl, space: false, pillEdge: .trailing))
                }
                bidiCells[idx] = cells.sorted { ($0.left, $0.range.lowerBound) < ($1.left, $1.range.lowerBound) }
            }
            #endif
            var charOffsets: [Float] = [0]
            var penX: Float = 0
            var trailingWsPt: Float = 0
            var bytePos = item.utf8Start
            var pillBounds: [Int: (left: Float, right: Float, iconX: Float?)] = [:]

            for ch in item.text {
                let chStart = bytePos
                let chBytes = String(ch).utf8.count
                let chEnd = chStart + chBytes
                bytePos = chEnd

                let lExtra = leadExtra(atUTF8: chStart)
                let tExtra = trailExtra(endingAtUTF8: chEnd)
                penX += lExtra

                let spanMatch = spanAt(utf8Offset: chStart)
                let spanBold = (spanMatch?.weight ?? style.weight) >= 600.0
                let spanItalic = (spanMatch?.italic == true) || style.italic
                let spanColor = spanMatch?.color
                let fontSz = spanMatch?.size ?? style.size
                let chW = charAdvance(ch, atUTF8: chStart) + stretch(ch, at: chStart)
                if ch == " " || ch == "\t" { trailingWsPt += chW } else { trailingWsPt = 0 }

                #if canImport(CRuneDesktopText) && !canImport(CoreText)
                let nativeCell = native?.cells[chStart]
                if let nativeCell { penX = nativeCell.left }
                let needsBitmapFont = nativeCell == nil
                #else
                let needsBitmapFont = true
                #endif
                // A chip continued on the next line stops at this line's visible edge.
                // Hanging whitespace keeps its positions for editing.
                if let (index, pill) = pillContaining(chStart, chEnd),
                   chStart < visibleEnd || pill.range.upperBound <= lineEnd || lExtra > 0 {
                    let left = originX + penX
                    let right = left + chW
                    #if canImport(CRuneDesktopText) && !canImport(CoreText)
                    let lead = native?.leadingMarkers[chStart]
                    let trail = native?.trailingMarkers[chEnd]
                    let rtlLead = lead?.rtl ?? (nativeCell?.isRTL == true)
                    let rtlTrail = trail?.rtl ?? (nativeCell?.isRTL == true)
                    let leadX = lead.map { originX + $0.left } ?? (rtlLead ? right : left - lExtra)
                    let trailX = trail.map { originX + $0.left } ?? (rtlTrail ? left - tExtra : right)
                    #else
                    let rtlLead = false, rtlTrail = false
                    let leadX = left - lExtra, trailX = right
                    #endif
                    if pill.isBare {
                        if lExtra > 0 {
                            let size = pill.icon?.size ?? 14
                            let x = rtlLead ? leadX + lExtra - size : leadX
                            inlineIconsOut.append(.init(pillIndex: index, pill: pill,
                                rect: SIMD4(x, originY + (boxHeightPt - size) * 0.5, size, size),
                                cornerRadius: pill.bareRadius, image: pill.bareImage, icon: pill.icon?.svg, color: pill.style.color))
                        }
                    } else {
                        var x0 = left, x1 = right
                        if lExtra > 0 {
                            x0 = min(x0, leadX + (rtlLead ? 0 : pm.margin))
                            x1 = max(x1, leadX + lExtra - (rtlLead ? pm.margin : 0))
                        }
                        if tExtra > 0 {
                            x0 = min(x0, trailX + (rtlTrail ? pm.margin : 0))
                            x1 = max(x1, trailX + tExtra - (rtlTrail ? 0 : pm.margin))
                        }
                        let old = pillBounds[index]
                        var iconX = old?.iconX
                        if lExtra > 0, pill.icon?.svg != nil {
                            let pad = pm.resolvedPad(style: pill.style)
                            iconX = rtlLead ? leadX + lExtra - pm.margin - pad - pm.icon : leadX + pm.margin + pad
                        }
                        pillBounds[index] = (min(x0, old?.left ?? x0), max(x1, old?.right ?? x1), iconX)
                    }
                }

                if needsBitmapFont, let bg = spanMatch?.background {
                    rawBackgrounds.append((SIMD4<Float>(originX + penX, originY, chW, boxHeightPt), bg))
                }
                if needsBitmapFont, spanMatch?.underline == true {
                    underlines.append(SIMD4<Float>(originX + penX, originY + baselineOffset + 1.5, chW, 1.0))
                }
                if needsBitmapFont, spanMatch?.strikethrough == true {
                    strikethroughs.append(SIMD4<Float>(originX + penX, originY + lineH * 0.52, chW, 1.0))
                }

                if emitGlyphs {
                    #if canImport(CRuneDesktopText) && !canImport(CoreText)
                    if paintNative, let native, let nativeCell {
                        if let spanColor { nativeColors[chStart] = spanColor }
                        glyphs += native.glyphs(for: nativeCell, originX: originX,
                            baselineY: baselinePx * invS, color: spanColor,
                            atlas: glyphAtlas, cache: !bypassCache, glidePx: glidePx, rasterWindow: rasterWindow)
                    }
                    #endif
                    let paintBitmap = needsBitmapFont && (rasterWindow.map { band in
                        let (height, bearing) = PortableGlyphFont.bitmapHeightAndBearing(fontSizePx: fontSz * scale)
                        let top = (baselinePx + bearing) * invS
                        return band.intersects(top, top + Float(height) * invS)
                    } ?? true)
                    if paintBitmap {
                        for scalar in ch.unicodeScalars where scalar.value > 0x20 {
                            let entry = glyphAtlas.rasterizePortableGlyph(
                                scalar: scalar,
                                fontSizePx: fontSz * scale,
                                bold: spanBold,
                                italic: spanItalic
                            )
                            let gx = originX + penX + entry.bearingPx.x * invS
                            let gy = originY + baselineOffset + entry.bearingPx.y * invS
                            let gw = Float(entry.pixelSize.x) * invS
                            let gh = Float(entry.pixelSize.y) * invS
                            glyphs.append(PositionedGlyph(
                                rect: SIMD4<Float>(gx, gy, gw, gh),
                                uv: entry.uv,
                                color: spanColor,
                                atlasPage: entry.page,
                                utf8Offset: chStart
                            ))
                        }
                    }
                }
                penX += chW + tExtra
                #if canImport(CRuneDesktopText) && !canImport(CoreText)
                if let nativeCell {
                    charOffsets[charOffsets.count - 1] = nativeCell.caret
                    for _ in 1..<chBytes { charOffsets.append(nativeCell.caret) }
                    charOffsets.append(nativeCell.endCaret)
                    continue
                }
                #endif
                for _ in 0..<chBytes {
                    charOffsets.append(penX)
                }
            }
            for (pIdx, p) in validPills where !p.isBare {
                guard let b = pillBounds[pIdx] else { continue }
                let h = boxHeightPt
                let chipRect = SIMD4<Float>(b.left, originY, max(0, b.right - b.left), h)
                let iconRect = b.iconX.map { SIMD4<Float>($0, originY + (h - pm.icon) * 0.5, pm.icon, pm.icon) }
                pillChipsOut.append(ShapedText.PillChipQuad(
                    pillIndex: pIdx,
                    rect: chipRect,
                    background: p.style.background,
                    ring: p.style.ring,
                    cornerRadius: min(5.0, h * 0.5),
                    icon: p.icon?.svg,
                    iconRect: iconRect,
                    iconColor: p.style.color
                ))
            }
            lineRecords.append((item.utf8Start, item.text, originY, originX, charOffsets))
            #if canImport(CRuneDesktopText) && !canImport(CoreText)
            if paintNative, let native, let restingText {
                restingText.add(.init(native: native, originX: originX, baselineY: baselinePx * invS, colors: nativeColors), at: idx)
            }
            #endif
            lineGlyphRanges.append(lineStartGlyphIdx..<glyphs.count)
            let advance = item.width + extraPerSpace * Float(spaces)
            let trailing = style.align == .justified && style.wrap == .wrap && maxWidth != nil ? hanging : trailingWsPt
            lineAdvancesPx.append((advance * scale, trailing * scale))
        }

        let backgrounds = Self.mergeContiguousBackgrounds(rawBackgrounds)
        let last = lineAdvancesPx.last ?? (widthPx: 0, trailingWsPx: 0)
        var shaped = ShapedText(
            size: Vec2(maxLineW, totalH),
            lineCount: lines.count,
            lineHeight: lineH,
            glyphs: glyphs,
            underlines: underlines,
            strikethroughs: strikethroughs,
            backgrounds: backgrounds,
            pillChips: pillChipsOut,
            inlineIcons: inlineIconsOut,
            portableLines: lineRecords,
            portableBidiCells: bidiCells,
            forcedDirection: style.direction,
            lineIsRTL: lines.map(\.isRTL),
            primaryIsRTL: (style.direction == .rtl) || (style.direction == nil && (lines.first?.isRTL ?? false)),
            wasTruncated: portableTruncated,
            lastLineAdvancePx: last.widthPx,
            hangingAdvancePx: last.trailingWsPx,
            lastLineWidthPx: last.widthPx,
            lastLineTrailingWsPx: last.trailingWsPx,
            drawnText: fullText,
            lineAdvancesPx: lineAdvancesPx,
            lineGlyphRanges: lineGlyphRanges
        )
        shaped.grownLineTopsPt = grownBoxes.map { $0.topPx * invS }
        shaped.grownLineHeightsPt = grownBoxes.map { ($0.bottomPx - $0.topPx) * invS }
        shaped.grownLineMetricHeightsPt = grownBoxes.map { $0.heightPx * invS }
        shaped.lineBaselinesPx = baselinesPx
        shaped.underlineLineEndsPt = underlineEnds.count == underlines.count ? underlineEnds : []
        #if canImport(CRuneDesktopText) && !canImport(CoreText)
        shaped.desktopRestingText = restingText
        shaped.paragraphNewlinePt = (strutLine?.strutFontHeightPt ?? 0) / 4
        if keepNativeParagraph, !paragraphLayouts.isEmpty {
            shaped.desktopParagraph = .init(linesByStart: paragraphLayouts.mapValues(\.line), fragments: desktopLines,
                ranges: lines.map { $0.utf8Start..<($0.utf8Start + $0.text.utf8.count) })
        }
        #endif
        return shaped
    }

    internal func caretRectPortable(in shaped: ShapedText, utf8Offset: Int, pixelScale: Float) -> SIMD4<Float> {
        guard !shaped.portableLines.isEmpty else { return SIMD4<Float>(0, 0, 1.5, shaped.lineHeight) }
        let line = shaped.lineIndex(forUTF8Offset: utf8Offset, affinity: .upstream)
        return shaped.portableCaret(on: line, at: utf8Offset)
    }

    internal func hitTestUTF8OffsetPortable(in shaped: ShapedText, localX: Float, localY: Float, pixelScale: Float) -> Int {
        guard !shaped.portableLines.isEmpty else { return 0 }
        let line = shaped.lineIndex(atLocalY: localY, lineCount: shaped.portableLines.count)
        return shaped.portableHit(on: line, at: localX)
    }

    internal func selectionRectsPortable(in shaped: ShapedText, lines: Range<Int>? = nil, utf8Range: Range<Int>, pixelScale: Float) -> [SIMD4<Float>] {
        var rects: [SIMD4<Float>] = []
        for index in lines ?? shaped.portableLines.indices {
            let rec = shaped.portableLines[index]
            let lineStart = rec.utf8Start
            let lineEnd = lineStart + rec.text.utf8.count
            let lo = max(utf8Range.lowerBound, lineStart)
            let hi = min(utf8Range.upperBound, lineEnd)
            if hi <= lo && shaped.selectsHardBreak(after: index, end: lineEnd, selection: utf8Range) {
                let endX = shaped.portableCaret(on: index, at: lineEnd, upstream: true).x
                rects.append(SIMD4<Float>(endX, rec.originY, 4.0, shaped.lineBoxHeightPt(index)))
                continue
            }
            guard hi > lo else { continue }
            if let cells = shaped.portableBidiCells[index] {
                cells.appendSelectionRects(for: lo..<hi, origin: Vec2(rec.originX, rec.originY),
                                           height: shaped.lineBoxHeightPt(index), toPoints: 1, into: &rects)
                continue
            }
            let l0 = max(0, min(rec.charOffsets.count - 1, lo - lineStart))
            let l1 = max(0, min(rec.charOffsets.count - 1, hi - lineStart))
            let x0 = rec.originX + rec.charOffsets[l0]
            let x1 = rec.originX + rec.charOffsets[l1]
            rects.append(SIMD4<Float>(min(x0, x1), rec.originY, max(2.0, abs(x1 - x0)), shaped.lineBoxHeightPt(index)))
        }
        return rects
    }

    internal func computeInkPortable(_ text: String, style: TextStyle) -> TextInk? {
        guard !text.isEmpty else { return nil }
        let k = TextInkAccumulator.oversample
        let shaped = shapePortable(text: text, spans: nil, style: style, maxWidth: nil, pixelScale: k, emitGlyphs: false)
        let lineH = style.resolvedLineHeight * k
        let baselineOffset = lineH * 0.78
        let isMono = style.family.isMonospace
        let isBold = style.weight >= 600.0
        var acc = TextInkAccumulator()
        for rec in shaped.portableLines {
            var penX = rec.originX * k
            let baselineY = rec.originY * k + baselineOffset
            for scalar in rec.text.unicodeScalars {
                let adv = PortableGlyphFont.advanceRatio(for: scalar, mono: isMono) * style.size * k
                if scalar.value > 0x20 {
                    let r = PortableGlyphFont.rasterizeScaled(
                        scalar: scalar,
                        fontSizePx: style.size * k,
                        bold: isBold,
                        italic: style.italic
                    )
                    let left = penX + 0.5
                    let top = baselineY + r.bearingY
                    for row in 0..<r.height {
                        for col in 0..<r.width {
                            let a = Float(r.bitmap[row * r.width + col]) / 255.0
                            if a > 0 {
                                acc.add(x: left + Float(col), y: top + Float(row), alpha: a)
                            }
                        }
                    }
                }
                penX += adv
            }
        }
        return acc.finish()
    }
}
