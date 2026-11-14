import Foundation
#if canImport(CoreText)
import CoreText
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
    case custom(String)

    public static let systemMono: FontFamily = .monospace
    public static func named(_ name: String) -> FontFamily { .custom(name) }
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

    public init(
        _ text: String,
        color: Color? = nil,
        background: Color? = nil,
        weight: Float? = nil,
        italic: Bool = false,
        monospace: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false,
        size: Float? = nil
    ) {
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
    /// Quad `[x, y, width, height]` in logical points relative to the text box origin.
    public var rect: SIMD4<Float>
    /// Normalized `[u0, v0, u1, v1]` in `GlyphAtlas` (`.zero` for RGBA color glyphs).
    public var uv: SIMD4<Float>
    public var color: Color?
    /// Non-nil index into `GlyphAtlas.colorGlyph(_:)` for RGBA color/emoji glyphs (`#807`).
    public var colorGlyphIndex: UInt32?
    /// Alpha atlas page index (`GlyphAtlas.pageData(_:)`, `atlas.rs:168`).
    public var atlasPage: UInt16

    public init(
        rect: SIMD4<Float>,
        uv: SIMD4<Float>,
        color: Color? = nil,
        colorGlyphIndex: UInt32? = nil,
        atlasPage: UInt16 = 0
    ) {
        self.rect = rect
        self.uv = uv
        self.color = color
        self.colorGlyphIndex = colorGlyphIndex
        self.atlasPage = atlasPage
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
    #endif
    fileprivate var portableLines: [(utf8Start: Int, text: String, originY: Float, originX: Float, charOffsets: [Float])] = []
    internal var markerMap: MarkerMap = MarkerMap()
    internal var forcedDirection: TextFlow? = nil
    internal var primaryIsRTL: Bool = false
    public var wasTruncated: Bool = false
    internal var lastLineAdvancePx: Float = 0
    internal var hangingAdvancePx: Float = 0
    public var elided: TextElision? = nil
    internal var drawnText: String = ""
    internal var lineAdvancesPx: [(widthPx: Float, trailingWsPx: Float)] = []

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
    }

    private struct ColorGlyphKey: Hashable {
        var fontHash: CFHashCode
        var glyphID: CGGlyph
        var sizePx10: Int
    }
    #endif

    private struct PortableGlyphKey: Hashable {
        var scalar: UInt32
        var sizePx10: Int
        var bold: Bool
        var italic: Bool
        var smoothing: FontSmoothing
    }

    private struct IconKey: Hashable {
        var icon: SVGIcon
        var pixelSize: Int
        var drawnSixtyFourths: UInt8 = 0
        var mirrored: Bool = false
    }

    private let lock = NSLock()
    public private(set) var atlas: R8Atlas
    public private(set) var generation: UInt64 = 1
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
    private var colorGlyphCache: [ColorGlyphKey: (entry: ColorGlyphEntry, lastUsed: UInt64, lastFrame: UInt64)] = [:]
    private var colorGlyphByIndex: [UInt32: ColorGlyphEntry] = [:]
    private var colorGlyphBytes: Int = 0
    private var nextColorGlyphIndex: UInt32 = 1
    #endif
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
        self.atlas = R8Atlas(width: 1, height: 1)
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
        if page == 0 {
            return backingAllocated ? atlas.texels : []
        }
        guard page >= 1 && page <= overflowPages.count else { return nil }
        return overflowPages[page - 1].atlas.texels
    }

    /// Returns a single `R8Atlas` containing all active pages stacked vertically (`width x (height * pageCount)`).
    /// When only page 0 exists, returns `atlas` directly with zero copy.
    public func compositedAtlas() -> R8Atlas {
        lock.lock()
        defer { lock.unlock() }
        if overflowPages.isEmpty {
            return atlas
        }
        let total = 1 + overflowPages.count
        let pageW = max(1, targetWidth)
        let pageH = max(1, targetHeight)
        let pageBytes = pageW * pageH
        var combined = [UInt8](repeating: 0, count: pageBytes * total)
        if backingAllocated && atlas.width == pageW && atlas.height == pageH && atlas.texels.count == pageBytes {
            combined.replaceSubrange(0..<pageBytes, with: atlas.texels)
        } else if backingAllocated && !atlas.texels.isEmpty {
            let copyRows = min(pageH, atlas.height)
            let copyCols = min(pageW, atlas.width)
            for row in 0..<copyRows {
                let srcStart = row * atlas.width
                let dstStart = row * pageW
                combined.replaceSubrange(dstStart..<(dstStart + copyCols), with: atlas.texels[srcStart..<(srcStart + copyCols)])
            }
        }
        for i in overflowPages.indices {
            let pageAtlas = overflowPages[i].atlas
            let dstBase = (i + 1) * pageBytes
            if pageAtlas.width == pageW && pageAtlas.height == pageH && pageAtlas.texels.count == pageBytes {
                combined.replaceSubrange(dstBase..<(dstBase + pageBytes), with: pageAtlas.texels)
            }
        }
        return R8Atlas(width: pageW, height: pageH * total, texels: combined)
    }

    /// Dirty row range `[y0, y1)` for a page since the last upload/reset (`atlas.rs:205`).
    public func dirtyRows(_ page: Int) -> (Int, Int)? {
        lock.lock()
        defer { lock.unlock() }
        if page == 0 { return page0Dirty }
        guard page >= 1 && page <= overflowPages.count else { return nil }
        return overflowPages[page - 1].dirty
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
        lock.lock()
        defer { lock.unlock() }
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
        colorGlyphCache = colorGlyphCache.filter { (f &- $0.value.lastFrame) <= 1 }
        var liveIndices = Set<UInt32>()
        var totalBytes = 0
        for v in colorGlyphCache.values {
            liveIndices.insert(v.entry.index)
            totalBytes += v.entry.rgba.count
        }
        colorGlyphByIndex = colorGlyphByIndex.filter { liveIndices.contains($0.key) }
        colorGlyphBytes = totalBytes
        #endif
    }

    /// Current CPU bytes held by cached RGBA color glyphs (`#807`).
    public var currentColorGlyphBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        #if canImport(CoreText) && canImport(CoreGraphics)
        return colorGlyphBytes
        #else
        return 0
        #endif
    }

    /// Number of currently cached RGBA color glyphs (`#807`).
    public var colorGlyphEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        #if canImport(CoreText) && canImport(CoreGraphics)
        return colorGlyphCache.count
        #else
        return 0
        #endif
    }

    /// Looks up a previously emitted color glyph bitmap by its `PositionedGlyph.colorGlyphIndex` (`#807`).
    public func colorGlyph(_ index: UInt32) -> ColorGlyphEntry? {
        lock.lock()
        defer { lock.unlock() }
        #if canImport(CoreText) && canImport(CoreGraphics)
        return colorGlyphByIndex[index]
        #else
        return nil
        #endif
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
        return backingAllocated ? atlas.texels.count : 0
    }

    /// Total cached entries across R8 glyph/icon and RGBA color-glyph tables.
    public var cachedEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        var total = portableGlyphCache.count + iconCache.count
        #if canImport(CoreText) && canImport(CoreGraphics)
        total += glyphCache.count + colorGlyphCache.count
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

    public func rasterizePortableGlyph(
        scalar: UnicodeScalar,
        fontSizePx: Float,
        bold: Bool = false,
        italic: Bool = false,
        smoothing: FontSmoothing = .systemDefault
    ) -> Entry {
        let key = PortableGlyphKey(
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
        let key = ColorGlyphKey(
            fontHash: CFHash(font),
            glyphID: glyph,
            sizePx10: Int((fontSizePx * 10.0).rounded())
        )
        lock.lock()
        if var cached = colorGlyphCache[key] {
            accessCounter &+= 1
            cached.lastUsed = accessCounter
            cached.lastFrame = frameSequence
            colorGlyphCache[key] = cached
            lock.unlock()
            return cached.entry
        }
        lock.unlock()

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

        lock.lock()
        let idx = nextColorGlyphIndex == 0 ? 1 : nextColorGlyphIndex
        nextColorGlyphIndex = idx &+ 1
        if nextColorGlyphIndex == 0 { nextColorGlyphIndex = 1 }
        let entry = ColorGlyphEntry(
            index: idx,
            pixelSize: SIMD2<Int>(bw, bh),
            bearingPx: SIMD2<Float>(Float(minX), Float(-maxY)),
            rgba: rgba
        )
        accessCounter &+= 1
        colorGlyphCache[key] = (entry, accessCounter, frameSequence)
        colorGlyphByIndex[idx] = entry
        colorGlyphBytes += rgba.count
        evictColorGlyphBudgetLocked(preserving: key)
        evictLRUIfNeededLocked()
        lock.unlock()
        return entry
    }

    func rasterizeGlyph(
        font: CTFont,
        glyph: CGGlyph,
        fontSizePx: Float,
        subpixelX: Float = 0,
        subpixelYBin: UInt8 = 0,
        smoothing: FontSmoothing = .systemDefault
    ) -> Entry? {
        let bin = UInt8(((subpixelX - floorf(subpixelX)) * 4.0).rounded()) & 3
        let binY = subpixelYBin & 3
        let subShift = Float(bin) * 0.25
        let shiftY = Float(binY) * 0.25
        let key = GlyphKey(
            fontHash: CFHash(font),
            glyphID: glyph,
            sizePx10: Int((fontSizePx * 10.0).rounded()),
            subpixelBin: bin,
            subpixelYBin: binY,
            smoothing: smoothing
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
        guard let ctx = CGContext(
            data: &baseBitmap,
            width: baseBw,
            height: baseBh,
            bitsPerComponent: 8,
            bytesPerRow: baseBw,
            space: graySpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        let allowFontSmoothing = smoothing.isEnabled
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(allowFontSmoothing)
        ctx.setShouldSmoothFonts(allowFontSmoothing)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setFillColor(gray: 1.0, alpha: 1.0)

        var pos = CGPoint(x: CGFloat(-minX), y: CGFloat(-minY))
        CTFontDrawGlyphs(font, &g, &pos, 1, ctx)

        // CoreGraphics snaps `pos.y` to integer device rows and applies hinting shifts to
        // small `pos.x` offsets, so shift non-zero quarter-pixel X/Y phases analytically in
        // bitmap space (`bilinear` / separable box-filter weights `subShift`, `shiftY`) so all
        // 4 glide phases per axis align to 1/4 px cleanly while resting (`bin == 0`) stays exact.
        let bw = bin == 0 ? baseBw : baseBw + 1
        let bh = binY == 0 ? baseBh : baseBh + 1
        let bitmap: [UInt8]
        if bin == 0 && binY == 0 {
            bitmap = baseBitmap
        } else {
            var xShifted: [Float]
            if bin == 0 {
                xShifted = baseBitmap.map(Float.init)
            } else {
                xShifted = Array<Float>(repeating: 0, count: bw * baseBh)
                let wx0 = 1.0 - subShift
                let wx1 = subShift
                for y in 0..<baseBh {
                    let srcRow = y * baseBw
                    let dstRow = y * bw
                    for x in 0..<bw {
                        let a = x < baseBw ? Float(baseBitmap[srcRow + x]) : 0.0
                        let b = (x > 0 && x - 1 < baseBw) ? Float(baseBitmap[srcRow + x - 1]) : 0.0
                        xShifted[dstRow + x] = a * wx0 + b * wx1
                    }
                }
            }
            if binY == 0 {
                bitmap = xShifted.map { UInt8($0.rounded().clamped(to: 0.0...255.0)) }
            } else {
                var out = Array<UInt8>(repeating: 0, count: bw * bh)
                let wy0 = 1.0 - shiftY
                let wy1 = shiftY
                for y in 0..<bh {
                    let rCur = y < baseBh ? y * bw : -1
                    let rPrev = (y > 0 && y - 1 < baseBh) ? (y - 1) * bw : -1
                    let dstRow = y * bw
                    for x in 0..<bw {
                        let a = rCur >= 0 ? xShifted[rCur + x] : 0.0
                        let b = rPrev >= 0 ? xShifted[rPrev + x] : 0.0
                        out[dstRow + x] = UInt8((a * wy0 + b * wy1).rounded().clamped(to: 0.0...255.0))
                    }
                }
                bitmap = out
            }
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
            bearingPx: SIMD2<Float>(Float(minX) - subShift, Float(-maxY)),
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
        let drawn = min(Float(px), max(1e-4, drawnSize ?? Float(px)))
        #if canImport(CoreGraphics)
        var bitmap = Array<UInt8>(repeating: 0, count: px * px)
        let graySpace = CGColorSpaceCreateDeviceGray()
        if let ctx = CGContext(
            data: &bitmap,
            width: px,
            height: px,
            bitsPerComponent: 8,
            bytesPerRow: px,
            space: graySpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) {
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            // Flip Y so SVG top-left (0,0) maps to top of bitmap!
            ctx.translateBy(x: 0, y: CGFloat(px))
            let scale = CGFloat(drawn) / CGFloat(icon.viewBox)
            ctx.scaleBy(x: scale, y: -scale)

            for d in icon.paths {
                let cgPath = Self.parseSVGPath(d)
                ctx.addPath(cgPath)
                if let sw = icon.strokeWidth, sw > 0 {
                    ctx.setStrokeColor(gray: 1.0, alpha: 1.0)
                    ctx.setLineWidth(CGFloat(sw))
                    ctx.setLineCap(.round)
                    ctx.setLineJoin(.round)
                    ctx.strokePath()
                } else {
                    ctx.setFillColor(gray: 1.0, alpha: 1.0)
                    ctx.fillPath()
                }
            }
            if icon.paths.isEmpty, let body = icon.body {
                SVGIconRenderer.drawMonochromeBody(body, in: ctx)
            }
        }
        return bitmap
        #else
        let resolvedIcon: SVGIcon
        if icon.paths.isEmpty, let body = icon.body {
            resolvedIcon = SVGIcon(
                viewBox: icon.viewBox,
                paths: SVGIconRenderer.extractPathStrings(fromBody: body),
                strokeWidth: icon.strokeWidth
            )
        } else {
            resolvedIcon = icon
        }
        return PortableSVGRasterizer.rasterize(resolvedIcon, pixelSize: px, drawnSize: drawn)
        #endif
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
        let p16 = UInt16(page)
        #if canImport(CoreText) && canImport(CoreGraphics)
        glyphCache = glyphCache.filter { $0.value.entry.page != p16 }
        #endif
        portableGlyphCache = portableGlyphCache.filter { $0.value.entry.page != p16 }
        iconCache = iconCache.filter { $0.value.entry.page != p16 }
        clock &+= 1
        resetsCount &+= 1
        let age = clock
        if page == 0 {
            page0Dirty = nil
            page0Shelf.reset(age: age)
        } else if page >= 1 && page <= overflowPages.count {
            overflowPages[page - 1].dirty = nil
            overflowPages[page - 1].shelf.reset(age: age)
        }
        generation &+= 1
    }

    private func ensureBackingLocked() {
        if !backingAllocated {
            atlas = R8Atlas(width: targetWidth, height: targetHeight)
            backingAllocated = true
        }
    }

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

    private func allocateAndBlit(width bw: Int, height bh: Int, bitmap: [UInt8]) -> (uv: SIMD4<Float>, page: UInt16, origin: SIMD2<Int>)? {
        guard let (page, dstX, dstY) = placeLocked(width: bw, height: bh) else {
            return nil
        }

        let pageW: Int
        let pageH: Int
        if page == 0 {
            pageW = atlas.width
            pageH = atlas.height
            blitWithGutter(into: &atlas.texels, pageWidth: pageW, dstX: dstX, dstY: dstY, bw: bw, bh: bh, bitmap: bitmap)
            let d = (dstY - 1, dstY + bh + 1)
            page0Dirty = page0Dirty.map { (min($0.0, d.0), max($0.1, d.1)) } ?? d
        } else {
            let idx = page - 1
            pageW = overflowPages[idx].atlas.width
            pageH = overflowPages[idx].atlas.height
            blitWithGutter(into: &overflowPages[idx].atlas.texels, pageWidth: pageW, dstX: dstX, dstY: dstY, bw: bw, bh: bh, bitmap: bitmap)
            let d = (dstY - 1, dstY + bh + 1)
            overflowPages[idx].dirty = overflowPages[idx].dirty.map { (min($0.0, d.0), max($0.1, d.1)) } ?? d
        }

        rasterizedCount &+= 1
        touchLocked(page: UInt16(page), texels: UInt32(bw * bh))
        generation &+= 1

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
        var total = portableGlyphCache.count + iconCache.count
        #if canImport(CoreText) && canImport(CoreGraphics)
        total += glyphCache.count + colorGlyphCache.count
        #endif
        while total > maxCachedEntries {
            enum Victim {
                case portable(PortableGlyphKey, UInt64)
                case icon(IconKey, UInt64)
                #if canImport(CoreText) && canImport(CoreGraphics)
                case glyph(GlyphKey, UInt64)
                case color(ColorGlyphKey, UInt64)
                #endif
                var seq: UInt64 {
                    switch self {
                    case .portable(_, let s), .icon(_, let s): return s
                    #if canImport(CoreText) && canImport(CoreGraphics)
                    case .glyph(_, let s), .color(_, let s): return s
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
            for (k, v) in colorGlyphCache {
                if oldest == nil || v.lastUsed < oldest!.seq { oldest = .color(k, v.lastUsed) }
            }
            #endif
            guard let victim = oldest else { break }
            switch victim {
            case .portable(let k, _): portableGlyphCache.removeValue(forKey: k)
            case .icon(let k, _): iconCache.removeValue(forKey: k)
            #if canImport(CoreText) && canImport(CoreGraphics)
            case .glyph(let k, _): glyphCache.removeValue(forKey: k)
            case .color(let k, _):
                if let removed = colorGlyphCache.removeValue(forKey: k) {
                    colorGlyphByIndex.removeValue(forKey: removed.entry.index)
                    colorGlyphBytes = max(0, colorGlyphBytes - removed.entry.rgba.count)
                }
            #endif
            }
            total -= 1
        }
    }

    #if canImport(CoreText) && canImport(CoreGraphics)
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
    #endif

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
        var weight10: Int
        var italic: Bool
        var fontScopeEpoch: UInt64
        var variations: String
        var features: String
    }

    private struct MeasureKey: Hashable {
        var text: String
        var style: TextStyle
        var maxWidthHalfPt: Int
        var scale100: Int
        var pillsHash: UInt64 = 0
        var fontEpoch: UInt64 = 1
    }

    private struct ShapeKey: Hashable {
        var text: String
        var spans: [TextSpan]?
        var style: TextStyle
        var maxWidthHalfPt: Int
        var scale100: Int
        var pillsHash: UInt64
        var fontEpoch: UInt64
        var langEpoch: UInt64
        var emitGlyphs: Bool
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
        var withoutGlyphs: ShapedText?
        var withGlyphs: ShapedText?
        var usedGeneration: UInt64 = 0
    }

    private struct PreparedPill {
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

    private static func hashPills(_ pills: [PillChip]) -> UInt64 {
        guard !pills.isEmpty else { return 0 }
        var hasher = Hasher()
        for p in pills {
            hasher.combine(p)
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    internal static func isRTLParagraph(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // Strong RTL ranges: Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic, RTL Presentation.
            if (0x0590...0x08FF).contains(v) || (0xFB1D...0xFEFC).contains(v) || (0x10800...0x10FFF).contains(v) || (0x1E800...0x1EFFF).contains(v) {
                return true
            }
            // Strong LTR ranges: ASCII letters, Latin Ext, Greek, Cyrillic, Armenian, Georgian, Hangul, CJK.
            if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v)
                || (0x00C0...0x052F).contains(v) || (0x10A0...0x10FF).contains(v)
                || (0x3040...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v) {
                return false
            }
        }
        return false
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
        _ rawSuggested: CFIndex,
        segStart: Int,
        hardEnd: Int,
        in ns: NSString
    ) -> CFIndex {
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
        fontSize: Float
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

            let labelStr = authText[loIdx..<hiIdx]
            let labelU16 = labelStr.utf16.count
            let labelStartU16 = shapedU16
            shaped.append(contentsOf: labelStr)
            shapedU16 += labelU16
            let labelEndU16 = shapedU16
            let authU16Hi = authU16Lo + labelU16

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
    public let colorIcons = ColorIconRasterizer()
    private var sansFamilyOverride: String = ""
    private var monoFamilyOverride: String = ""
    private var languageTagOverride: String?
    private var lastObservedFontEpoch: UInt64 = fontEpoch()
    private var lastObservedLanguageEpoch: UInt64 = TextLanguageRegistry.currentEpoch()
    #if canImport(CoreText) && canImport(CoreGraphics)
    private var fontCache: [FontKey: CTFont] = [:]
    #endif
    private var measureCache: [MeasureKey: (size: Vec2, usedGeneration: UInt64)] = [:]
    private var commitGeneration: UInt64 = 0
    private struct DecoratedRange {
        var u16Range: Range<Int>
        var underline: Bool
        var strikethrough: Bool
        var background: Color?
    }

    private struct TypesetterKey: Hashable {
        var text: String
        var spans: [TextSpan]?
        var pills: [PillChip]
        var shapingStyle: TextStyle
        var scaleBit: UInt32
        var languageTag: String?
        var fontEpoch: UInt64

        init(text: String, spans: [TextSpan]?, pills: [PillChip], style: TextStyle, scale: Float, languageTag: String?, fontEpoch: UInt64) {
            self.text = text
            self.spans = spans
            self.pills = pills
            var normalized = style
            normalized.align = .leading
            normalized.wrap = .wrap
            normalized.wrapAnywhere = false
            normalized.elide = .end
            normalized.maxLines = 0
            normalized.exactLines = false
            self.shapingStyle = normalized
            self.scaleBit = scale.bitPattern
            self.languageTag = languageTag
            self.fontEpoch = fontEpoch
        }
    }

    private struct CachedTypesetter {
        var typesetter: CTTypesetter
        var shapedText: String
        var markerMap: ShapedText.MarkerMap
        var preparedPills: [PreparedPill]
        var spanPalette: [Color]
        var decoratedRanges: [DecoratedRange]
        var baseFont: CTFont
        var baseAscentPx: CGFloat
        var baseDescentPx: CGFloat
        var usedGeneration: UInt64 = 0
    }

    public var smoothing: FontSmoothing = .platformDefault {
        didSet {
            if smoothing != oldValue {
                lock.lock()
                measureCache.removeAll(keepingCapacity: true)
                shapeCache.removeAll(keepingCapacity: true)
                elisionCache.removeAll(keepingCapacity: true)
                typesetterCache.removeAll(keepingCapacity: true)
                lock.unlock()
            }
        }
    }

    public var applePipeline: ApplePipeline { smoothing.pipeline }

    private var shapeCache: [ShapeKey: (shaped: ShapedText, usedGeneration: UInt64)] = [:]
    private var elisionCache: [ElisionKey: CachedElision] = [:]
    private var typesetterCache: [TypesetterKey: CachedTypesetter] = [:]
    internal private(set) var measureMissCount: Int = 0
    internal private(set) var shapeMissCount: Int = 0
    internal private(set) var shapedBuildCount: Int = 0
    internal private(set) var rebrokenCount: Int = 0
    private var shapeCallCounter: UInt64 = 0

    /// Drops cached layouts and typesetters while keeping rasterized glyph and icon atlases intact.
    public func clearLayoutCaches() {
        lock.lock()
        measureCache.removeAll(keepingCapacity: true)
        shapeCache.removeAll(keepingCapacity: true)
        elisionCache.removeAll(keepingCapacity: true)
        typesetterCache.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Advances the layout commit generation after a committed frame (`#905`).
    public func endCommit() {
        lock.lock()
        commitGeneration &+= 1
        lock.unlock()
    }

    /// Window at rest (`TextSystem::rest`, `#905`): evicts layout/shape/elision/typesetter entries
    /// untouched for 2+ commits and drops orphan glyph cache entries.
    public func rest() {
        lock.lock()
        if commitGeneration > 0 {
            let g = commitGeneration &- 1
            measureCache = measureCache.filter { (g &- $0.value.usedGeneration) < 2 }
            shapeCache = shapeCache.filter { (g &- $0.value.usedGeneration) < 2 }
            elisionCache = elisionCache.filter { (g &- $0.value.usedGeneration) < 2 }
            typesetterCache = typesetterCache.filter { (g &- $0.value.usedGeneration) < 2 }
        }
        lock.unlock()
        glyphAtlas.dropOrphans()
    }

    internal var cachedMeasureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return measureCache.count
    }

    internal var cachedShapeCount: Int {
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

    internal var cachedElisionCount: Int {
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

    public init(glyphAtlas: GlyphAtlas = GlyphAtlas()) {
        self.glyphAtlas = glyphAtlas
        let (sans, mono) = FontFamiliesRegistry.currentFamilies()
        self.sansFamilyOverride = sans
        self.monoFamilyOverride = mono
        self.languageTagOverride = TextLanguageRegistry.currentLanguageTag()
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
        defer { lock.unlock() }
        if languageTagOverride == normalized {
            return false
        }
        languageTagOverride = normalized
        measureCache.removeAll(keepingCapacity: true)
        shapeCache.removeAll(keepingCapacity: true)
        elisionCache.removeAll(keepingCapacity: true)
        typesetterCache.removeAll(keepingCapacity: true)
        return true
    }

    /// Current global font epoch seen by this `TextSystem` (auto-syncs when global families change).
    public var currentFontEpoch: UInt64 {
        syncGlobalFamiliesIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return lastObservedFontEpoch
    }

    /// Looks up a cached RGBA color glyph bitmap emitted during `shape(...)` (`#807`).
    public func colorGlyph(_ index: UInt32) -> GlyphAtlas.ColorGlyphEntry? {
        glyphAtlas.colorGlyph(index)
    }

    /// CSS font family lists backing `.systemUI` (`sans`) and `.monospace` (`mono`).
    public func families() -> (sans: String, mono: String) {
        syncGlobalFamiliesIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return (sansFamilyOverride, monoFamilyOverride)
    }

    /// Updates `sans` and `mono` family slots (`TextSystem::set_families`). Drops cached shapes/fonts when changed.
    @discardableResult
    public func setFamilies(sans: String, mono: String) -> Bool {
        if FontFamiliesRegistry.threadOverrideFamilies() != nil {
            return FontFamiliesRegistry.setFamilies(sans: sans, mono: mono)
        }
        lock.lock()
        let unchanged = (sansFamilyOverride == sans && monoFamilyOverride == mono)
        if unchanged {
            lock.unlock()
            return false
        }
        sansFamilyOverride = sans
        monoFamilyOverride = mono
        #if canImport(CoreText) && canImport(CoreGraphics)
        fontCache.removeAll(keepingCapacity: true)
        #endif
        measureCache.removeAll(keepingCapacity: true)
        shapeCache.removeAll(keepingCapacity: true)
        elisionCache.removeAll(keepingCapacity: true)
        typesetterCache.removeAll(keepingCapacity: true)
        lock.unlock()

        FontFamiliesRegistry.setFamilies(sans: sans, mono: mono)
        let newEpoch = fontEpoch()
        lock.lock()
        lastObservedFontEpoch = newEpoch
        lock.unlock()
        return true
    }

    private func syncGlobalFamiliesIfNeeded() {
        let langEpoch = TextLanguageRegistry.currentEpoch()
        let inThreadScope = (FontFamiliesRegistry.threadOverrideFamilies() != nil)
        let globalEpoch = inThreadScope ? 0 : fontEpoch()
        lock.lock()
        if !inThreadScope && lastObservedFontEpoch != globalEpoch {
            let (sans, mono) = FontFamiliesRegistry.currentFamilies()
            sansFamilyOverride = sans
            monoFamilyOverride = mono
            #if canImport(CoreText) && canImport(CoreGraphics)
            fontCache.removeAll(keepingCapacity: true)
            #endif
            measureCache.removeAll(keepingCapacity: true)
            shapeCache.removeAll(keepingCapacity: true)
            elisionCache.removeAll(keepingCapacity: true)
            typesetterCache.removeAll(keepingCapacity: true)
            lastObservedFontEpoch = globalEpoch
        }
        if lastObservedLanguageEpoch != langEpoch {
            let globalTag = TextLanguageRegistry.currentLanguageTag()
            if languageTagOverride != globalTag {
                languageTagOverride = globalTag
                measureCache.removeAll(keepingCapacity: true)
                shapeCache.removeAll(keepingCapacity: true)
                elisionCache.removeAll(keepingCapacity: true)
                typesetterCache.removeAll(keepingCapacity: true)
            }
            lastObservedLanguageEpoch = langEpoch
        }
        lock.unlock()
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

    private static func firstMatchingFont(in cssList: String, sizePx: CGFloat) -> CTFont? {
        for raw in cssList.split(separator: ",") {
            let name = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            guard !name.isEmpty else { continue }
            let font = CTFontCreateWithName(name as CFString, sizePx, nil)
            let resolvedName = CTFontCopyFamilyName(font) as String
            if resolvedName.caseInsensitiveCompare(name) == .orderedSame ||
                (CTFontCopyPostScriptName(font) as String).caseInsensitiveCompare(name) == .orderedSame {
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
        let threadFamilies = FontFamiliesRegistry.threadOverrideFamilies()
        let scopeEpoch = fontEpoch()
        let sizePx = style.size * pixelScale
        let key = FontKey(
            family: style.family,
            sizePx10: Int((sizePx * 10.0).rounded()),
            weight10: Int(style.weight.rounded()),
            italic: style.italic,
            fontScopeEpoch: scopeEpoch,
            variations: style.variations,
            features: style.features
        )
        lock.lock()
        if let cached = fontCache[key] {
            lock.unlock()
            return cached
        }
        let sansList = threadFamilies?.sans ?? sansFamilyOverride
        let monoList = threadFamilies?.mono ?? monoFamilyOverride
        lock.unlock()

        let ctWeight = Self.coreTextWeight(for: style.weight)
        var traits: [CFString: Any] = [
            kCTFontWeightTrait: ctWeight,
        ]
        if style.italic {
            traits[kCTFontSlantTrait] = CGFloat(0.15)
        }

        DefaultFonts.registerIfNeeded()

        let baseFont: CTFont
        switch style.family {
        case .systemUI:
            let effectiveSans = sansList.isEmpty ? DefaultFonts.sansFamily : sansList
            baseFont = Self.firstMatchingFont(in: effectiveSans, sizePx: CGFloat(sizePx))
                ?? CTFontCreateUIFontForLanguage(.system, CGFloat(sizePx), nil)
                ?? CTFontCreateWithName("SFProText-Regular" as CFString, CGFloat(sizePx), nil)
        case .monospace:
            let effectiveMono = monoList.isEmpty ? DefaultFonts.monoFamily : monoList
            baseFont = Self.firstMatchingFont(in: effectiveMono, sizePx: CGFloat(sizePx))
                ?? CTFontCreateUIFontForLanguage(.userFixedPitch, CGFloat(sizePx), nil)
                ?? CTFontCreateWithName("Menlo-Regular" as CFString, CGFloat(sizePx), nil)
        case .custom(let name):
            baseFont = CTFontCreateWithName(name as CFString, CGFloat(sizePx), nil)
        }

        let familyName = CTFontCopyFamilyName(baseFont) as String
        let featureSettings = Self.parseOpenTypeFeatures(style.features)
        let variationSettings = Self.parseFontVariations(style.variations)
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
        let weighted: CTFont
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

    internal static func specLineHeight(lineCount: Int, lineHeightPt: Float, scale: Float, exact: Bool) -> Float {
        let s = max(1.0, scale)
        let rawPx = Float(max(1, lineCount)) * lineHeightPt * s
        let snappedPx = exact ? ((rawPx * 64.0).rounded() / 64.0) : ceilf(rawPx)
        return snappedPx / s
    }

    /// Fast cached measurement of plain `text` constrained to `maxWidth` logical points.
    /// When `maxWidth` is non-nil and `style.wrap == .noWrap`, wraps at `maxWidth` per upstream `text::measure`.
    public func measure(
        _ text: String,
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        pills: [PillChip] = []
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
        let maxWKey = maxWidth.map { Int(($0 * 2.0).rounded()) } ?? -1
        let pHash = Self.hashPills(pills)
        let key = MeasureKey(
            text: text,
            style: effectiveStyle,
            maxWidthHalfPt: maxWKey,
            scale100: Int((pixelScale * 100).rounded()),
            pillsHash: pHash,
            fontEpoch: fontEpoch()
        )
        lock.lock()
        if let cached = measureCache[key] {
            measureCache[key] = (cached.size, commitGeneration)
            lock.unlock()
            return cached.size
        }
        lock.unlock()
        let shaped = shape(text: text, spans: nil, pills: pills, style: effectiveStyle, maxWidth: maxWidth, pixelScale: pixelScale, emitGlyphs: false)
        lock.lock()
        measureMissCount += 1
        if measureCache.count > 4096 {
            measureCache.removeAll(keepingCapacity: true)
        }
        measureCache[key] = (shaped.size, commitGeneration)
        lock.unlock()
        return shaped.size
    }

    /// Shapes plain or rich text into lines, optional pill/inline-icon quads, and optional `GlyphAtlas` quads.
    public func shape(
        text: String,
        spans: [TextSpan]? = nil,
        pills: [PillChip] = [],
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        emitGlyphs: Bool = true,
        glidePx: Vec2 = .zero
    ) -> ShapedText {
        var effectiveStyle = style
        if effectiveStyle.fontSmoothing == .systemDefault {
            effectiveStyle.fontSmoothing = smoothing
        }
        return measureFramePhase(.text) {
            shapeImpl(
                text: text,
                spans: spans,
                pills: pills,
                style: effectiveStyle,
                maxWidth: maxWidth,
                pixelScale: pixelScale,
                emitGlyphs: emitGlyphs,
                glidePx: glidePx
            )
        }
    }

    private func shapeImpl(
        text: String,
        spans: [TextSpan]? = nil,
        pills: [PillChip] = [],
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        emitGlyphs: Bool = true,
        glidePx: Vec2 = .zero
    ) -> ShapedText {
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
                glidePx: glidePx
            )
        }
        syncGlobalFamiliesIfNeeded()
        let pHash = Self.hashPills(pills)
        let fEpoch = fontEpoch()
        let lEpoch = TextLanguageRegistry.currentEpoch()
        let maxWKey = maxWidth.map { Int(($0 * 2.0).rounded()) } ?? -1
        let scaleKey = Int((scale * 100.0).rounded())
        let needsElide = (style.maxLines > 0) || (style.wrap == .ellipsis && maxWidth != nil && maxWidth! > 0)

        if glidePx == .zero {
            let sKey = ShapeKey(
                text: authText,
                spans: spans,
                style: style,
                maxWidthHalfPt: maxWKey,
                scale100: scaleKey,
                pillsHash: pHash,
                fontEpoch: fEpoch,
                langEpoch: lEpoch,
                emitGlyphs: emitGlyphs
            )
            lock.lock()
            if let cached = shapeCache[sKey] {
                shapeCache[sKey] = (cached.shaped, commitGeneration)
                lock.unlock()
                return cached.shaped
            }
            lock.unlock()

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
                    langEpoch: lEpoch
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
                    glidePx: glidePx
                )
                lock.lock()
                shapeMissCount += 1
                lock.unlock()
            }
            lock.lock()
            if shapeCache.count > 2048 {
                shapeCache.removeAll(keepingCapacity: true)
            }
            shapeCache[sKey] = (res, commitGeneration)
            lock.unlock()
            return res
        }

        if needsElide {
            return resolveElidedShape(
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
                langEpoch: lEpoch
            )
        }
        return shapeCoreImpl(
            text: authText,
            spans: spans,
            pills: pills,
            style: style,
            maxWidth: maxWidth,
            pixelScale: scale,
            emitGlyphs: emitGlyphs,
            glidePx: glidePx
        )
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
        langEpoch: UInt64
    ) -> ShapedText {
        let eKey: ElisionKey? = maxWidth != nil
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

        if let eKey {
            lock.lock()
            var cached = elisionCache[eKey]
            if var entry = cached {
                entry.usedGeneration = commitGeneration
                elisionCache[eKey] = entry
                cached = entry
            }
            lock.unlock()
            if let cached {
                if emitGlyphs {
                    if let wg = cached.withGlyphs {
                        return wg
                    }
                    let rebuilt = buildCutShaped(
                        elision: cached.elision,
                        authText: authText,
                        spans: spans,
                        pills: pills,
                        style: style,
                        maxWidth: maxWidth,
                        scale: scale,
                        emitGlyphs: true
                    )
                    lock.lock()
                    if var existing = elisionCache[eKey] {
                        existing.withGlyphs = rebuilt
                        existing.usedGeneration = commitGeneration
                        elisionCache[eKey] = existing
                    }
                    lock.unlock()
                    return rebuilt
                } else if let wog = cached.withoutGlyphs {
                    return wog
                }
            }
        }

        // First shape the uncut text without clamping/ellipsis to test if it already fits.
        var uncutStyle = style
        uncutStyle.maxLines = 0
        if style.maxLines == 0 && style.wrap == .ellipsis {
            uncutStyle.wrap = .noWrap
        } else if style.maxLines > 0 && uncutStyle.wrap == .noWrap {
            uncutStyle.wrap = .wrap
        }
        let uncutWidth: Float? = (style.maxLines == 0 && style.wrap == .ellipsis) ? nil : maxWidth
        let full = shapeCoreImpl(
            text: authText,
            spans: spans,
            pills: pills,
            style: uncutStyle,
            maxWidth: uncutWidth,
            pixelScale: scale,
            emitGlyphs: false
        )

        if style.maxLines > 0 {
            let lines = style.maxLines
            let maxWPx = maxWidth.map { max(1.0, $0 * scale) } ?? Float.greatestFiniteMagnitude
            let lastShown = min(lines, full.lineCount) - 1
            let lastW = full.lineAdvancePx(at: lastShown)
            if full.lineCount <= lines && lastW <= maxWPx + 0.5 {
                let res: ShapedText = emitGlyphs
                    ? shapeCoreImpl(text: authText, spans: spans, pills: pills, style: uncutStyle, maxWidth: uncutWidth, pixelScale: scale, emitGlyphs: true)
                    : full
                lock.lock()
                shapeMissCount += 1
                lock.unlock()
                return res
            }
            let (candNoGlyphs, elision) = computeClamped(
                authText: authText,
                spans: spans,
                pills: pills,
                style: style,
                full: full,
                maxWidth: maxWidth,
                scale: scale
            )
            let finalRes = emitGlyphs
                ? buildCutShaped(elision: elision, authText: authText, spans: spans, pills: pills, style: style, maxWidth: maxWidth, scale: scale, emitGlyphs: true)
                : candNoGlyphs
            lock.lock()
            shapeMissCount += 1
            if let eKey {
                if elisionCache.count > 2048 {
                    elisionCache.removeAll(keepingCapacity: true)
                }
                elisionCache[eKey] = CachedElision(
                    elision: elision,
                    withoutGlyphs: candNoGlyphs,
                    withGlyphs: emitGlyphs ? finalRes : nil,
                    usedGeneration: commitGeneration
                )
            }
            lock.unlock()
            return finalRes
        } else {
            // Single-line `.ellipsis` truncation
            let maxWPx = max(1.0, (maxWidth ?? 0) * scale)
            if full.lineCount <= 1 && full.lastLineAdvancePx <= maxWPx + 0.5 {
                let res: ShapedText = emitGlyphs
                    ? shapeCoreImpl(text: authText, spans: spans, pills: pills, style: uncutStyle, maxWidth: nil, pixelScale: scale, emitGlyphs: true)
                    : full
                lock.lock()
                shapeMissCount += 1
                lock.unlock()
                return res
            }
            let (candNoGlyphs, elision) = computeTruncated(
                authText: authText,
                spans: spans,
                pills: pills,
                style: style,
                maxWPx: maxWPx,
                scale: scale
            )
            let finalRes = emitGlyphs
                ? buildCutShaped(elision: elision, authText: authText, spans: spans, pills: pills, style: style, maxWidth: maxWidth, scale: scale, emitGlyphs: true)
                : candNoGlyphs
            lock.lock()
            shapeMissCount += 1
            if let eKey {
                if elisionCache.count > 2048 {
                    elisionCache.removeAll(keepingCapacity: true)
                }
                elisionCache[eKey] = CachedElision(
                    elision: elision,
                    withoutGlyphs: candNoGlyphs,
                    withGlyphs: emitGlyphs ? finalRes : nil,
                    usedGeneration: commitGeneration
                )
            }
            lock.unlock()
            return finalRes
        }
    }

    private func buildCutShaped(
        elision: TextElision,
        authText: String,
        spans: [TextSpan]?,
        pills: [PillChip],
        style: TextStyle,
        maxWidth: Float?,
        scale: Float,
        emitGlyphs: Bool
    ) -> ShapedText {
        let drawn = elision.drawnString(from: authText)
        let origLen = authText.utf8.count
        let mappedSpans = spans.map { elision.mapSpans($0, originalLength: origLen, drawn: drawn) }
        let mappedPills = elision.mapPills(pills)
        var cutStyle = style
        cutStyle.maxLines = 0
        let cutMaxW: Float?
        if style.maxLines > 0 {
            cutStyle.wrap = (style.wrap == .noWrap || style.wrap == .ellipsis) ? .wrap : style.wrap
            cutMaxW = maxWidth
        } else {
            cutStyle.wrap = .noWrap
            cutMaxW = nil
        }
        var shaped = shapeCoreImpl(
            text: drawn,
            spans: mappedSpans,
            pills: mappedPills,
            style: cutStyle,
            maxWidth: cutMaxW,
            pixelScale: scale,
            emitGlyphs: emitGlyphs
        )
        shaped.elided = elision
        shaped.wasTruncated = true
        shaped.drawnText = drawn
        return shaped
    }

    private func computeClamped(
        authText: String,
        spans: [TextSpan]?,
        pills: [PillChip],
        style: TextStyle,
        full: ShapedText,
        maxWidth: Float?,
        scale: Float
    ) -> (ShapedText, TextElision) {
        let lines = style.maxLines
        let totalLen = authText.utf8.count
        let maxWPx = maxWidth.map { max(1.0, $0 * scale) } ?? Float.greatestFiniteMagnitude
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
            let cand = buildCutShaped(elision: e, authText: authText, spans: spans, pills: pills, style: style, maxWidth: maxWidth, scale: scale, emitGlyphs: false)
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
        let finalCand = buildCutShaped(elision: finalE, authText: authText, spans: spans, pills: pills, style: style, maxWidth: maxWidth, scale: scale, emitGlyphs: false)
        return (finalCand, finalE)
    }

    private func computeTruncated(
        authText: String,
        spans: [TextSpan]?,
        pills: [PillChip],
        style: TextStyle,
        maxWPx: Float,
        scale: Float
    ) -> (ShapedText, TextElision) {
        let bounds = TextElision.graphemeByteBounds(in: authText, baseOffset: 0)
        let n = max(0, bounds.count - 1)

        func cut(_ k: Int) -> TextElision {
            var h: Int
            var tCount: Int
            switch style.elide {
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
            let cand = buildCutShaped(elision: e, authText: authText, spans: spans, pills: pills, style: style, maxWidth: nil, scale: scale, emitGlyphs: false)
            if cand.lastLineAdvancePx <= maxWPx + 0.5 {
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
        let finalCand = buildCutShaped(elision: finalE, authText: authText, spans: spans, pills: pills, style: style, maxWidth: nil, scale: scale, emitGlyphs: false)
        return (finalCand, finalE)
    }

    private func shapeCoreImpl(
        text: String,
        spans: [TextSpan]? = nil,
        pills: [PillChip] = [],
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        emitGlyphs: Bool = true,
        glidePx: Vec2 = .zero
    ) -> ShapedText {
        let scale = pixelScale > 0 ? max(pixelScale, 0.0625) : 1.0
        let lhPt = style.resolvedLineHeight
        let lhPx = lhPt * scale
        let authText = spans.map { $0.map(\.text).joined() } ?? text

        if authText.isEmpty {
            let emptyH = Self.specLineHeight(lineCount: 1, lineHeightPt: lhPt, scale: scale, exact: style.exactLines)
            let emptyOriginX: Float = (style.direction == .rtl ? (maxWidth ?? 0) : 0)
            return ShapedText(
                size: Vec2(0, emptyH),
                lineCount: 1,
                lineHeight: lhPt,
                glyphs: [],
                underlines: [],
                backgrounds: [],
                lineStrings: [(0, "", 0, emptyOriginX, nil)],
                forcedDirection: style.direction
            )
        }
        recordShapeCall()

        let effectiveLang = TextLanguageRegistry.effectiveLanguageTag(for: authText, chosen: language)
        let tsKey = TypesetterKey(
            text: authText,
            spans: spans,
            pills: pills,
            style: style,
            scale: scale,
            languageTag: effectiveLang,
            fontEpoch: fontEpoch()
        )
        let builtTypesetter: CachedTypesetter
        lock.lock()
        let hitTS = typesetterCache[tsKey]
        if var updatedTS = hitTS {
            updatedTS.usedGeneration = commitGeneration
            typesetterCache[tsKey] = updatedTS
            rebrokenCount += 1
        }
        lock.unlock()

        if let hitTS {
            builtTypesetter = hitTS
        } else {
            let (shapedText, initialMarkerMap, preparedPills) = Self.preparePills(pills, in: authText, fontSize: style.size)

            let baseFont = resolveCTFont(style: style, pixelScale: scale)
            let baseAscentPx = CTFontGetAscent(baseFont)
            let baseDescentPx = CTFontGetDescent(baseFont)

            let attrStr = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
            CFAttributedStringReplaceString(attrStr, CFRangeMake(0, 0), shapedText as CFString)
            let fullLen = CFAttributedStringGetLength(attrStr)
            CFAttributedStringSetAttribute(attrStr, CFRangeMake(0, fullLen), kCTFontAttributeName, baseFont)
            if let langTag = effectiveLang {
                CFAttributedStringSetAttribute(attrStr, CFRangeMake(0, fullLen), kCTLanguageAttributeName, langTag as CFString)
            }
            if style.letterSpacing != 0 {
                let kern = CGFloat(style.letterSpacing * scale) as CFNumber
                CFAttributedStringSetAttribute(attrStr, CFRangeMake(0, fullLen), kCTKernAttributeName, kern)
            }

            // Apply per-paragraph base writing direction natively; tab stops use per-'\t' CTRunDelegate widths below.
            let shapedNS = shapedText as NSString
            var paraScanStart = 0
            while paraScanStart < fullLen {
                var paraScanEnd = fullLen
                for i in paraScanStart..<fullLen where shapedNS.character(at: i) == 0x0A {
                    paraScanEnd = i
                    break
                }
                let paraSub = shapedNS.substring(with: NSRange(location: paraScanStart, length: max(0, paraScanEnd - paraScanStart)))
                let resolvedDir: CTWritingDirection? = {
                    switch style.direction {
                    case .rtl: return .rightToLeft
                    case .ltr: return .leftToRight
                    case nil: return Self.isRTLParagraph(paraSub) ? .rightToLeft : nil
                    }
                }()
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
            var spanTabInfo: [(u16Range: Range<Int>, spacePx: CGFloat, isMonospace: Bool)] = []
            if let spans {
                var authU16Cursor = 0
                for span in spans {
                    let u16Count = span.text.utf16.count
                    guard u16Count > 0 else { continue }
                    let sLo = initialMarkerMap.shapedU16ForSpanBoundary(authU16Cursor, isEnd: false)
                    let sHi = initialMarkerMap.shapedU16ForSpanBoundary(authU16Cursor + u16Count, isEnd: true)
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
                                background: span.background
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
                    let isMono = (style.family == .monospace) || (activeSpan?.isMonospace == true)
                    if style.family != .monospace {
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

            let created = CachedTypesetter(
                typesetter: CTTypesetterCreateWithAttributedString(attrStr),
                shapedText: shapedText,
                markerMap: initialMarkerMap,
                preparedPills: preparedPills,
                spanPalette: spanPalette,
                decoratedRanges: decoratedRanges,
                baseFont: baseFont,
                baseAscentPx: baseAscentPx,
                baseDescentPx: baseDescentPx,
                usedGeneration: commitGeneration
            )
            lock.lock()
            if typesetterCache.count > 1024 {
                typesetterCache.removeAll(keepingCapacity: true)
            }
            typesetterCache[tsKey] = created
            shapedBuildCount += 1
            lock.unlock()
            builtTypesetter = created
        }

        let shapedText = builtTypesetter.shapedText
        var markerMap = builtTypesetter.markerMap
        let preparedPills = builtTypesetter.preparedPills
        let spanPalette = builtTypesetter.spanPalette
        let decoratedRanges = builtTypesetter.decoratedRanges
        let baseFont = builtTypesetter.baseFont
        let baseAscentPx = builtTypesetter.baseAscentPx
        let baseDescentPx = builtTypesetter.baseDescentPx
        let fullLen = shapedText.utf16.count
        let shapedNS = shapedText as NSString
        let spanColorKey = "RuneColorIndex" as CFString
        let pillMarkerKey = "RunePillMarker" as CFString

        // Break into visual lines using CTTypesetter while keeping pill labels & bare icons atomic when they fit.
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
            var strIndexBase: Int = 0
        }
        var visualLines: [VisualLine] = []
        var anyTruncated = false
        let typesetter = builtTypesetter.typesetter
        let effectiveWrapWidthPx: CGFloat? = (style.wrap == .wrap && maxWidth != nil)
            ? CGFloat(max(1.0, maxWidth! * scale))
            : nil

        var u16Start = 0
        var authUTF8Cursor = 0
        let authNS = authText as NSString

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
            let paraIsRTL: Bool = {
                switch style.direction {
                case .rtl: return true
                case .ltr: return false
                case nil: return Self.isRTLParagraph(paraShapedSub)
                }
            }()

            var segStart = u16Start
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
                    isParaLast: true
                ))
            } else {
                while segStart < hardEnd {
                    var count: CFIndex
                    if let wrapW = effectiveWrapWidthPx {
                        let suggested: CFIndex
                        if style.wrapAnywhere {
                            suggested = CTTypesetterSuggestClusterBreak(typesetter, segStart, Double(wrapW))
                        } else {
                            let raw = CTTypesetterSuggestLineBreak(typesetter, segStart, Double(wrapW))
                            suggested = Self.keepUnbrokenWordIntact(raw, segStart: segStart, hardEnd: hardEnd, in: shapedNS)
                        }
                        count = min(max(1, suggested), hardEnd - segStart)
                        // Keep pill chips and bare inline icons attached to their label/word when they fit on a line.
                        let tentativeEnd = segStart + count
                        for vp in preparedPills {
                            let fullLo = vp.leadShapedU16
                            let fullHi = (vp.trailShapedU16 ?? max(vp.labelShapedU16Hi - 1, vp.leadShapedU16)) + 1
                            if tentativeEnd > fullLo && tentativeEnd < fullHi && fullLo > segStart {
                                count = fullLo - segStart
                                break
                            }
                        }
                        count = max(1, count)
                    } else {
                        count = hardEnd - segStart
                    }
                    let isParaLast = (segStart + count >= hardEnd)
                    let cfRange = CFRangeMake(segStart, count)
                    var ctLine = CTTypesetterCreateLine(typesetter, cfRange)
                    if style.wrap == .ellipsis, let maxW = maxWidth {
                        let maxWPx = Double(maxW * scale)
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
                    } else if style.align == .justified && !isParaLast && style.wrap == .wrap, let maxW = maxWidth {
                        var trimmed = count
                        while trimmed > 1 {
                            let ch = shapedNS.character(at: segStart + trimmed - 1)
                            if ch == 0x20 || ch == 0x09 {
                                trimmed -= 1
                            } else {
                                break
                            }
                        }
                        let baseLine = trimmed < count ? CTTypesetterCreateLine(typesetter, CFRangeMake(segStart, trimmed)) : ctLine
                        let targetWPx = Double(max(1.0, maxW * scale))
                        if let jLine = CTLineCreateJustifiedLine(baseLine, 1.0, targetWPx) {
                            ctLine = jLine
                        }
                    }
                    let a0 = markerMap.authU16(forShapedU16: segStart)
                    let a1 = markerMap.authU16(forShapedU16: segStart + count)
                    let sub = authoredSlice(fromAuthU16: a0, toAuthU16: a1)
                    let wPx = Float(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
                    let twPx = Float(CTLineGetTrailingWhitespaceWidth(ctLine))
                    visualLines.append(VisualLine(
                        ctLine: ctLine,
                        authUTF8Start: authUTF8Cursor,
                        authU16Start: a0,
                        authU16End: a1,
                        u16Start: segStart,
                        u16End: segStart + count,
                        authSubstr: sub,
                        widthPx: wPx,
                        trailingWsPx: twPx,
                        isRTL: paraIsRTL,
                        isParaLast: isParaLast
                    ))
                    authUTF8Cursor += sub.utf8.count
                    segStart += count
                }
            }
            if hardEnd < fullLen && shapedNS.character(at: hardEnd) == 0x0A {
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
                        isParaLast: true
                    ))
                }
            } else {
                u16Start = hardEnd
            }
        }

        let maxLineWidthPx = visualLines.reduce(Float(0)) { max($0, $1.widthPx) }
        let containerWidthPx = maxWidth.map { max(maxLineWidthPx, $0 * scale) } ?? maxLineWidthPx
        let ascentPx = Float(baseAscentPx)
        let descentPx = Float(baseDescentPx)
        let halfLeadingPx = (lhPx - (ascentPx + descentPx)) * 0.5

        var glyphsOut: [PositionedGlyph] = []
        var underlinesOut: [SIMD4<Float>] = []
        var strikethroughsOut: [SIMD4<Float>] = []
        var rawBackgroundsOut: [(SIMD4<Float>, Color)] = []
        var pillChipsOut: [ShapedText.PillChipQuad] = []
        var inlineIconsOut: [ShapedText.InlineIconQuad] = []
        var lineRecords: [(utf8Start: Int, text: String, originY: Float, originX: Float, ctLine: CTLine?)] = []
        var lineMarkerRanges: [ShapedText.MarkerMap.LineRange] = []
        lineRecords.reserveCapacity(visualLines.count)
        lineMarkerRanges.reserveCapacity(visualLines.count)

        let invS = 1.0 / scale
        let ascentPt = ascentPx * invS
        let strokeThicknessPt = max(1.0, style.size * 0.07)
        let pm = PillMetrics(size: style.size)

        for (lineIdx, item) in visualLines.enumerated() {
            let lineTopPx = Float(lineIdx) * lhPx
            let baselineYPx = (lineTopPx + halfLeadingPx + ascentPx).rounded()
            let alignOffsetPx: Float
            switch style.align {
            case .leading:
                if item.isRTL {
                    alignOffsetPx = max(0, Float(CTLineGetPenOffsetForFlush(item.ctLine, 1.0, CGFloat(containerWidthPx))))
                } else {
                    alignOffsetPx = 0
                }
            case .center:
                alignOffsetPx = max(0, Float(CTLineGetPenOffsetForFlush(item.ctLine, 0.5, CGFloat(containerWidthPx))))
            case .trailing:
                if item.isRTL {
                    alignOffsetPx = 0
                } else {
                    alignOffsetPx = max(0, Float(CTLineGetPenOffsetForFlush(item.ctLine, 1.0, CGFloat(containerWidthPx))))
                }
            case .justified:
                if !item.isParaLast && style.wrap == .wrap && maxWidth != nil {
                    alignOffsetPx = 0
                } else if item.isRTL {
                    alignOffsetPx = max(0, Float(CTLineGetPenOffsetForFlush(item.ctLine, 1.0, CGFloat(containerWidthPx))))
                } else {
                    alignOffsetPx = 0
                }
            }

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

            if emitGlyphs && !decoratedRanges.isEmpty && item.u16End > item.u16Start {
                for dec in decoratedRanges {
                    let lo = max(item.u16Start, dec.u16Range.lowerBound)
                    let hi = min(item.u16End, dec.u16Range.upperBound)
                    guard hi > lo else { continue }
                    let x0Px = Float(CTLineGetOffsetForStringIndex(item.ctLine, lo - item.strIndexBase, nil))
                    let x1Px = Float(CTLineGetOffsetForStringIndex(item.ctLine, hi - item.strIndexBase, nil))
                    let xPt = originXPt + min(x0Px, x1Px) * invS
                    let wPt = abs(x1Px - x0Px) * invS
                    guard wPt > 0.01 else { continue }
                    if let bg = dec.background {
                        rawBackgroundsOut.append((SIMD4<Float>(xPt, originYPt, wPt, lhPt), bg))
                    }
                    if dec.underline {
                        let uy = baselineYPx * invS + max(1.0, style.size * 0.12)
                        underlinesOut.append(SIMD4<Float>(xPt, uy, wPt, strokeThicknessPt))
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

                // Bare inline icons (`pills.rs` / `pill_chips.rs:6-41`).
                for (pIdx, vp) in preparedPills.enumerated() where vp.pill.isBare {
                    guard let box = markerBoxes[pIdx << 1] else { continue }
                    var asc: Float = 0
                    var desc: Float = 0
                    var grX1 = -Float.greatestFiniteMagnitude
                    let lo = max(item.u16Start, vp.labelShapedU16Lo)
                    let hi = min(item.u16End, vp.labelShapedU16Hi)
                    if hi > lo {
                        let ox0 = alignOffsetPx + Float(CTLineGetOffsetForStringIndex(item.ctLine, lo - item.strIndexBase, nil))
                        let ox1 = alignOffsetPx + Float(CTLineGetOffsetForStringIndex(item.ctLine, hi - item.strIndexBase, nil))
                        grX1 = max(ox0, ox1)
                        for run in runs {
                            let attrs = CTRunGetAttributes(run) as NSDictionary
                            if attrs[pillMarkerKey] != nil { continue }
                            let r = CTRunGetStringRange(run)
                            let rEnd = r.location + r.length
                            if r.location < hi && lo < rEnd, let rf = attrs[kCTFontAttributeName] {
                                let runFont = rf as! CTFont
                                asc = max(asc, Float(CTFontGetAscent(runFont)))
                                desc = max(desc, Float(CTFontGetDescent(runFont)))
                            }
                        }
                    }
                    let px = max(1.0, ((vp.pill.icon?.size ?? 14.0) * scale).rounded())
                    if asc <= 0 {
                        asc = px * 0.95
                        desc = px * 0.25
                    }
                    let yPx = (baselineYPx + (desc - asc) * 0.5 - px * 0.5).rounded()
                    let xPx = (abs(box.xPx - grX1) < 1.0 ? (box.xPx + box.wPx - px) : box.xPx).rounded()
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
                    var asc: Float = 0
                    var desc: Float = 0
                    var grX0 = Float.greatestFiniteMagnitude
                    var grX1 = -Float.greatestFiniteMagnitude
                    let lo = max(item.u16Start, vp.labelShapedU16Lo)
                    let hi = min(item.u16End, vp.labelShapedU16Hi)
                    if hi > lo {
                        let ox0 = alignOffsetPx + Float(CTLineGetOffsetForStringIndex(item.ctLine, lo - item.strIndexBase, nil))
                        let ox1 = alignOffsetPx + Float(CTLineGetOffsetForStringIndex(item.ctLine, hi - item.strIndexBase, nil))
                        grX0 = min(ox0, ox1)
                        grX1 = max(ox0, ox1)
                        for run in runs {
                            let attrs = CTRunGetAttributes(run) as NSDictionary
                            if attrs[pillMarkerKey] != nil { continue }
                            let r = CTRunGetStringRange(run)
                            let rEnd = r.location + r.length
                            if r.location < hi && lo < rEnd, let rf = attrs[kCTFontAttributeName] {
                                let runFont = rf as! CTFont
                                asc = max(asc, Float(CTFontGetAscent(runFont)))
                                desc = max(desc, Float(CTFontGetDescent(runFont)))
                            }
                        }
                    }
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

            guard emitGlyphs else { continue }
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

                var glyphs = Array<CGGlyph>(repeating: 0, count: glyphCount)
                var positions = Array<CGPoint>(repeating: .zero, count: glyphCount)
                CTRunGetGlyphs(run, CFRangeMake(0, glyphCount), &glyphs)
                CTRunGetPositions(run, CFRangeMake(0, glyphCount), &positions)

                for i in 0..<glyphCount {
                    let gxPx = alignOffsetPx + Float(positions[i].x)
                    let gyPx = baselineYPx - Float(positions[i].y)
                    let floorX = floorf(gxPx)
                    let subX = gxPx - floorX
                    if runIsColor, let colorEntry = glyphAtlas.rasterizeColorGlyph(
                        font: runFont,
                        glyph: glyphs[i],
                        fontSizePx: runFontSizePx
                    ), colorEntry.pixelSize.x > 0 && colorEntry.pixelSize.y > 0 {
                        let quadXPx = roundf(gxPx) + colorEntry.bearingPx.x
                        let quadYPx = roundf(gyPx) + colorEntry.bearingPx.y
                        glyphsOut.append(PositionedGlyph(
                            rect: SIMD4<Float>(
                                quadXPx * invS,
                                quadYPx * invS,
                                Float(colorEntry.pixelSize.x) * invS,
                                Float(colorEntry.pixelSize.y) * invS
                            ),
                            uv: .zero,
                            color: runColor,
                            colorGlyphIndex: colorEntry.index
                        ))
                        continue
                    }

                    let quadXPx: Float
                    let quadYPx: Float
                    let subXArg: Float
                    let binYArg: UInt8
                    let posXPx: Float
                    if glidePx != .zero {
                        let phases = Float(GlyphAtlas.glidePhases)
                        let totalX = gxPx + (glidePx.x * phases).rounded() / phases
                        let qx = (totalX * phases).rounded()
                        let fx = floorf(qx / phases)
                        let binX = UInt8(Int(qx - fx * phases)) & 3
                        let subShiftX = Float(binX) * 0.25
                        let totalY = gyPx + (glidePx.y * phases).rounded() / phases
                        let qy = (totalY * phases).rounded()
                        let fy = floorf(qy / phases)
                        binYArg = UInt8(Int(qy - fy * phases)) & 3
                        subXArg = subShiftX
                        posXPx = totalX
                        quadYPx = totalY - Float(binYArg) * 0.25
                    } else {
                        subXArg = subX
                        binYArg = 0
                        posXPx = floorX + subX
                        quadYPx = gyPx
                    }

                    guard let entry = glyphAtlas.rasterizeGlyph(
                        font: runFont,
                        glyph: glyphs[i],
                        fontSizePx: runFontSizePx,
                        subpixelX: subXArg,
                        subpixelYBin: binYArg,
                        smoothing: style.fontSmoothing
                    ), entry.pixelSize.x > 0 && entry.pixelSize.y > 0 else {
                        continue
                    }

                    quadXPx = posXPx + entry.bearingPx.x
                    let finalQuadYPx = quadYPx + entry.bearingPx.y
                    glyphsOut.append(PositionedGlyph(
                        rect: SIMD4<Float>(
                            quadXPx * invS,
                            finalQuadYPx * invS,
                            Float(entry.pixelSize.x) * invS,
                            Float(entry.pixelSize.y) * invS
                        ),
                        uv: entry.uv,
                        color: runColor,
                        atlasPage: entry.page
                    ))
                }
            }
        }

        markerMap.lines = lineMarkerRanges
        let backgroundsOut = Self.mergeContiguousBackgrounds(rawBackgroundsOut)
        let totalHeightPt = Self.specLineHeight(lineCount: max(1, visualLines.count), lineHeightPt: lhPt, scale: scale, exact: style.exactLines)
        let totalWidthPt = ceilf(maxLineWidthPx / scale * 2.0) * 0.5
        return ShapedText(
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
            drawnText: authText,
            lineAdvancesPx: visualLines.map { ($0.widthPx, $0.trailingWsPx) }
        )
    }

    private static func globalShapedU16Index(in shaped: ShapedText, lineIdx: Int, authUTF8: Int, ctLine: CTLine) -> Int {
        let rec = shaped.lineStrings[lineIdx]
        let localUTF8 = (authUTF8 - rec.utf8Start).clamped(to: 0...rec.text.utf8.count)
        let localAuthU16 = String(decoding: rec.text.utf8.prefix(localUTF8), as: UTF8.self).utf16.count
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
            return SIMD4<Float>(0, 0, 1.5, shaped.lineHeight)
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
        return SIMD4<Float>(xPt, rec.originY, 1.5, shaped.lineHeight)
    }

    /// Hit-tests `(localX, localY)` in element-local logical points to a UTF-8 byte offset.
    public func hitTestUTF8Offset(in shaped: ShapedText, localX: Float, localY: Float, pixelScale: Float) -> Int {
        guard !shaped.lineStrings.isEmpty else { return 0 }
        let scale = pixelScale > 0 ? max(pixelScale, 0.0625) : 1.0
        let lineIdx = Int(floorf(max(0, localY) / max(1, shaped.lineHeight)))
            .clamped(to: 0...(shaped.lineStrings.count - 1))
        let rec = shaped.lineStrings[lineIdx]
        guard let ctLine = rec.ctLine, !rec.text.isEmpty else {
            return rec.utf8Start
        }
        let relXPx = CGFloat((localX - rec.originX) * scale)
        let u16Idx = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: relXPx, y: 0))
        if u16Idx == kCFNotFound {
            return rec.utf8Start
        }
        if lineIdx < shaped.markerMap.lines.count && !shaped.markerMap.entries.isEmpty {
            let lineMeta = shaped.markerMap.lines[lineIdx]
            let clampedShaped = u16Idx.clamped(to: lineMeta.shapedU16Start...lineMeta.shapedU16End)
            let authU16 = shaped.markerMap.authU16(forShapedU16: clampedShaped)
            let localAuthU16 = (authU16 - lineMeta.authU16Start).clamped(to: 0...rec.text.utf16.count)
            let u16Prefix = rec.text.utf16.prefix(localAuthU16)
            return rec.utf8Start + String(decoding: u16Prefix, as: UTF16.self).utf8.count
        }
        let ctRange = CTLineGetStringRange(ctLine)
        let localU16 = (u16Idx - ctRange.location).clamped(to: 0...rec.text.utf16.count)
        if localU16 <= 0 {
            return rec.utf8Start
        }
        let u16Prefix = rec.text.utf16.prefix(localU16)
        let prefixStr = String(decoding: u16Prefix, as: UTF16.self)
        return rec.utf8Start + prefixStr.utf8.count
    }

    /// Computes per-line selection rectangles `[x, y, width, height]` in logical points for `utf8Range`.
    public func selectionRects(in shaped: ShapedText, utf8Range: Range<Int>, pixelScale: Float) -> [SIMD4<Float>] {
        guard !utf8Range.isEmpty, !shaped.lineStrings.isEmpty else { return [] }
        let scale = pixelScale > 0 ? max(pixelScale, 0.0625) : 1.0
        let invS = 1.0 / scale
        var rects: [SIMD4<Float>] = []
        for (lineIdx, rec) in shaped.lineStrings.enumerated() {
            let lineStart = rec.utf8Start
            let lineEnd = lineStart + rec.text.utf8.count
            let lo = max(lineStart, utf8Range.lowerBound)
            let hi = min(lineEnd, utf8Range.upperBound)
            if hi < lo { continue }
            if hi == lo && utf8Range.upperBound > lineEnd {
                // Newline at end of empty or non-empty line: show a narrow trailing selection sliver
                let endX: Float
                if let ctLine = rec.ctLine, !rec.text.isEmpty {
                    let endU16 = Self.globalShapedU16Index(in: shaped, lineIdx: lineIdx, authUTF8: lineEnd, ctLine: ctLine)
                    endX = rec.originX + Float(CTLineGetOffsetForStringIndex(ctLine, endU16, nil)) * invS
                } else {
                    endX = rec.originX
                }
                rects.append(SIMD4<Float>(endX, rec.originY, 4.0, shaped.lineHeight))
                continue
            }
            guard hi > lo else { continue }
            let x0: Float
            let x1: Float
            if let ctLine = rec.ctLine {
                let u16Lo = Self.globalShapedU16Index(in: shaped, lineIdx: lineIdx, authUTF8: lo, ctLine: ctLine)
                let u16Hi = Self.globalShapedU16Index(in: shaped, lineIdx: lineIdx, authUTF8: hi, ctLine: ctLine)
                x0 = rec.originX + Float(CTLineGetOffsetForStringIndex(ctLine, u16Lo, nil)) * invS
                x1 = rec.originX + Float(CTLineGetOffsetForStringIndex(ctLine, u16Hi, nil)) * invS
            } else {
                x0 = rec.originX
                x1 = rec.originX
            }
            let minX = min(x0, x1)
            let w = max(2.0, abs(x1 - x0))
            rects.append(SIMD4<Float>(minX, rec.originY, w, shaped.lineHeight))
        }
        return rects
    }

    internal func computeInk(_ text: String, style: TextStyle) -> TextInk? {
        guard !text.isEmpty else { return nil }
        let k = TextInkAccumulator.oversample
        let shaped = shape(text: text, spans: nil, style: style, maxWidth: nil, pixelScale: k, emitGlyphs: false)
        let baseFont = resolveCTFont(style: style, pixelScale: k)
        let lhPx = style.resolvedLineHeight * k
        let ascentPx = Float(CTFontGetAscent(baseFont))
        let descentPx = Float(CTFontGetDescent(baseFont))
        let halfLeadingPx = (lhPx - (ascentPx + descentPx)) * 0.5
        let graySpace = CGColorSpaceCreateDeviceGray()
        let rgbSpace = CGColorSpaceCreateDeviceRGB()

        var acc = TextInkAccumulator()
        for (lineIdx, rec) in shaped.lineStrings.enumerated() {
            guard let ctLine = rec.ctLine else { continue }
            let lineTopPx = Float(lineIdx) * lhPx
            let baselineYPx = (lineTopPx + halfLeadingPx + ascentPx).rounded()
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
                    let gyPx = baselineYPx - Float(positions[i].y)
                    let floorX = floorf(gxPx)
                    let subX = gxPx - floorX

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
    public func measure(
        _ text: String,
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        pills: [PillChip] = []
    ) -> Vec2 {
        measureFramePhase(.text) {
            measurePortable(text, style: style, maxWidth: maxWidth, pixelScale: pixelScale, pills: pills)
        }
    }

    public func shape(
        text: String,
        spans: [TextSpan]? = nil,
        pills: [PillChip] = [],
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        emitGlyphs: Bool = true
    ) -> ShapedText {
        var effectiveStyle = style
        if effectiveStyle.fontSmoothing == .systemDefault {
            effectiveStyle.fontSmoothing = smoothing
        }
        return measureFramePhase(.text) {
            shapePortable(text: text, spans: spans, pills: pills, style: effectiveStyle, maxWidth: maxWidth, pixelScale: pixelScale, emitGlyphs: emitGlyphs)
        }
    }

    public func caretRect(in shaped: ShapedText, utf8Offset: Int, pixelScale: Float) -> SIMD4<Float> {
        caretRectPortable(in: shaped, utf8Offset: utf8Offset, pixelScale: pixelScale)
    }

    public func hitTestUTF8Offset(in shaped: ShapedText, localX: Float, localY: Float, pixelScale: Float) -> Int {
        hitTestUTF8OffsetPortable(in: shaped, localX: localX, localY: localY, pixelScale: pixelScale)
    }

    public func selectionRects(in shaped: ShapedText, utf8Range: Range<Int>, pixelScale: Float) -> [SIMD4<Float>] {
        selectionRectsPortable(in: shaped, utf8Range: utf8Range, pixelScale: pixelScale)
    }

    internal func computeInk(_ text: String, style: TextStyle) -> TextInk? {
        computeInkPortable(text, style: style)
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
        let lines = visualLines(in: shaped)
        guard !lines.isEmpty else { return 0 }
        for i in lines.indices {
            let l = lines[i]
            if upstream {
                if utf8Offset <= l.utf8End { return i }
            } else {
                // Downstream prefers the next wrapped line when sitting on a soft-wrap boundary,
                // unless this line ends in an explicit `\n` or is the last line.
                let isLast = (i == lines.count - 1)
                if isLast { return i }
                if utf8Offset < l.utf8End { return i }
                if utf8Offset == l.utf8End {
                    let nextStart = lines[i + 1].utf8Start
                    if nextStart > l.utf8End {
                        // Hard break (`\n`) separates line `i` and line `i + 1`, so `utf8End` belongs to line `i`.
                        return i
                    }
                    // Soft-wrap boundary: upstream keeps end of `i`, downstream belongs to `i + 1`.
                }
            }
        }
        return lines.count - 1
    }

    /// Caret rect honoring soft-wrap upstream/downstream affinity at line boundaries.
    public func caretRect(in shaped: ShapedText, utf8Offset: Int, upstream: Bool, pixelScale: Float) -> SIMD4<Float> {
        let lines = visualLines(in: shaped)
        guard !lines.isEmpty else {
            return SIMD4<Float>(0, 0, 1.5, shaped.lineHeight)
        }
        let lineIdx = visualLineIndex(in: shaped, utf8Offset: utf8Offset, upstream: upstream)
        let rec = lines[lineIdx]
        #if canImport(CoreText) && canImport(CoreGraphics)
        if lineIdx < shaped.lineStrings.count {
            let ctRec = shaped.lineStrings[lineIdx]
            let scale = pixelScale > 0 ? max(pixelScale, 0.0625) : 1.0
            var xPt = ctRec.originX
            if let ctLine = ctRec.ctLine {
                let globalU16 = Self.globalShapedU16Index(in: shaped, lineIdx: lineIdx, authUTF8: utf8Offset, ctLine: ctLine)
                xPt += Float(CTLineGetOffsetForStringIndex(ctLine, globalU16, nil)) / scale
            }
            return SIMD4<Float>(xPt, ctRec.originY, 1.5, shaped.lineHeight)
        }
        #endif
        if lineIdx < shaped.portableLines.count {
            let pRec = shaped.portableLines[lineIdx]
            let localUTF8 = (utf8Offset - pRec.utf8Start).clamped(to: 0...pRec.text.utf8.count)
            let charIdx = String(decoding: pRec.text.utf8.prefix(localUTF8), as: UTF8.self).count
            let xPt = pRec.originX + pRec.charOffsets[min(charIdx, pRec.charOffsets.count - 1)]
            return SIMD4<Float>(xPt, rec.originY, 1.5, shaped.lineHeight)
        }
        return caretRect(in: shaped, utf8Offset: utf8Offset, pixelScale: pixelScale)
    }

    // MARK: - Portable (Headless / Linux / Windows / Android / Web) Text Shaping

    internal func measurePortable(
        _ text: String,
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        pills: [PillChip] = []
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
            fontEpoch: fontEpoch()
        )
        lock.lock()
        if let cached = measureCache[key] {
            measureCache[key] = (cached.size, commitGeneration)
            lock.unlock()
            return cached.size
        }
        lock.unlock()

        let shaped = shapePortable(text: text, spans: nil, pills: pills, style: effectiveStyle, maxWidth: maxWidth, pixelScale: pixelScale, emitGlyphs: false)
        lock.lock()
        measureMissCount += 1
        if measureCache.count > 4096 {
            measureCache.removeAll(keepingCapacity: true)
        }
        measureCache[key] = (shaped.size, commitGeneration)
        lock.unlock()
        return shaped.size
    }

    internal func shapePortable(
        text: String,
        spans: [TextSpan]? = nil,
        pills: [PillChip] = [],
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        emitGlyphs: Bool = true
    ) -> ShapedText {
        let scale = pixelScale > 0 ? max(pixelScale, 0.0625) : 1.0
        let invS = 1.0 / scale
        let lineH = style.resolvedLineHeight
        let fullText = spans.map { $0.map(\.text).joined() } ?? text

        if fullText.isEmpty {
            let emptyH = Self.specLineHeight(lineCount: 1, lineHeightPt: lineH, scale: scale, exact: style.exactLines)
            return ShapedText(
                size: Vec2(0, emptyH),
                lineCount: 1,
                lineHeight: lineH,
                glyphs: [],
                underlines: [],
                strikethroughs: [],
                backgrounds: [],
                portableLines: [(0, "", 0, 0, [0])]
            )
        }
        recordShapeCall()

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

        func leadExtra(atUTF8 offset: Int) -> Float {
            guard let (_, p) = validPills.first(where: { $0.pill.range.lowerBound == offset }) else { return 0 }
            if p.isBare {
                return (p.icon?.size ?? 14.0) + p.bareGap
            }
            return pm.lead(icon: p.icon != nil, style: p.style)
        }

        func trailExtra(endingAtUTF8 endOffset: Int) -> Float {
            guard let (_, p) = validPills.first(where: { !$0.pill.isBare && $0.pill.range.upperBound == endOffset }) else { return 0 }
            return pm.trail(style: p.style)
        }

        func spanAt(utf8Offset: Int) -> TextSpan? {
            spanEntries.last { $0.utf8Range.contains(utf8Offset) }?.span
        }

        func charAdvance(_ ch: Character, atUTF8 utf8Offset: Int) -> Float {
            let match = spanAt(utf8Offset: utf8Offset)
            let isMono = match?.monospace == true || style.family == .monospace
            let fontSz = match?.size ?? style.size
            let count = ch.unicodeScalars.count
            let scalarSum = ch.unicodeScalars.reduce(Float(0)) { acc, scalar in
                acc + PortableGlyphFont.advanceRatio(for: scalar, mono: isMono) * fontSz
            }
            return scalarSum + (count > 0 ? style.letterSpacing : 0)
        }

        // Split into raw lines on '\n' and wrap/ellipsis if requested.
        var lines: [(utf8Start: Int, text: String, width: Float, isRTL: Bool, isParaLast: Bool)] = []
        var portableTruncated = false
        var cursorUTF8 = 0
        let rawParagraphs = fullText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (pIdx, para) in rawParagraphs.enumerated() {
            let isRTL = Self.isRTLParagraph(para)
            if para.isEmpty {
                lines.append((cursorUTF8, "", 0, isRTL, true))
            } else if style.wrap == .wrap, let maxW = maxWidth, maxW > 0 {
                var current = ""
                var curW: Float = 0
                var lineStart = cursorUTF8
                var charUTF8 = cursorUTF8
                for ch in para {
                    let chBytes = String(ch).utf8.count
                    let chW = leadExtra(atUTF8: charUTF8) + charAdvance(ch, atUTF8: charUTF8) + trailExtra(endingAtUTF8: charUTF8 + chBytes)
                    if !current.isEmpty && curW + chW > maxW {
                        lines.append((lineStart, current, curW, isRTL, false))
                        lineStart += current.utf8.count
                        current = String(ch)
                        curW = chW
                    } else {
                        current.append(ch)
                        curW += chW
                    }
                    charUTF8 += chBytes
                }
                if !current.isEmpty {
                    lines.append((lineStart, current, curW, isRTL, true))
                }
            } else if style.wrap == .ellipsis, let maxW = maxWidth, maxW > 0 {
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
                    lines.append((cursorUTF8, para, totalParaW, isRTL, true))
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
                    lines.append((cursorUTF8, outStr, outW, isRTL, true))
                }
            } else {
                var w: Float = 0
                var charUTF8 = cursorUTF8
                for ch in para {
                    let chBytes = String(ch).utf8.count
                    w += leadExtra(atUTF8: charUTF8) + charAdvance(ch, atUTF8: charUTF8) + trailExtra(endingAtUTF8: charUTF8 + chBytes)
                    charUTF8 += chBytes
                }
                lines.append((cursorUTF8, para, w, isRTL, true))
            }
            cursorUTF8 += para.utf8.count
            if pIdx + 1 < rawParagraphs.count {
                cursorUTF8 += 1
            }
        }
        if lines.isEmpty {
            lines = [(0, "", 0, false, true)]
        }
        if style.maxLines > 0 && lines.count > style.maxLines {
            lines = Array(lines.prefix(style.maxLines))
            var last = lines[style.maxLines - 1]
            let ellW = charAdvance("…", atUTF8: last.utf8Start)
            var trimmed = last.text
            while let c = trimmed.last, c.isWhitespace { trimmed.removeLast() }
            if let maxW = maxWidth, maxW > 0 {
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

        let maxLineW = lines.map(\.width).max() ?? 0
        let totalW = maxWidth.map { style.align == .leading ? max(maxLineW, min($0, maxLineW)) : max($0, maxLineW) } ?? maxLineW
        let totalH = Self.specLineHeight(lineCount: max(1, lines.count), lineHeightPt: lineH, scale: scale, exact: style.exactLines)

        var glyphs: [PositionedGlyph] = []
        var underlines: [SIMD4<Float>] = []
        var strikethroughs: [SIMD4<Float>] = []
        var rawBackgrounds: [(SIMD4<Float>, Color)] = []
        var pillChipsOut: [ShapedText.PillChipQuad] = []
        var inlineIconsOut: [ShapedText.InlineIconQuad] = []
        var lineRecords: [(utf8Start: Int, text: String, originY: Float, originX: Float, charOffsets: [Float])] = []

        let baselineOffset = lineH * 0.78
        for (idx, item) in lines.enumerated() {
            let originY = Float(idx) * lineH
            let originX: Float
            switch style.align {
            case .leading: originX = item.isRTL ? max(0, totalW - item.width) : 0
            case .center: originX = max(0, (totalW - item.width) * 0.5)
            case .trailing: originX = item.isRTL ? 0 : max(0, totalW - item.width)
            case .justified:
                if !item.isParaLast && style.wrap == .wrap && maxWidth != nil {
                    originX = 0
                } else {
                    originX = item.isRTL ? max(0, totalW - item.width) : 0
                }
            }

            let extraPerSpace: Float = (style.align == .justified && !item.isParaLast && style.wrap == .wrap && maxWidth != nil)
                ? {
                    let spaces = item.text.filter { $0 == " " }.count
                    return spaces > 0 ? max(0, totalW - item.width) / Float(spaces) : 0
                }()
                : 0

            var charOffsets: [Float] = [0]
            var penX: Float = 0
            var bytePos = item.utf8Start
            var pillBounds: [Int: (leadX: Float, x0: Float, x1: Float, hasGlyphs: Bool, hasLead: Bool, hasTrail: Bool)] = [:]

            for ch in item.text {
                let chStart = bytePos
                let chBytes = String(ch).utf8.count
                let chEnd = chStart + chBytes
                bytePos = chEnd

                let lExtra = leadExtra(atUTF8: chStart)
                if lExtra > 0 {
                    if let pMatch = validPills.first(where: { $0.pill.range.lowerBound == chStart }) {
                        if pMatch.pill.isBare {
                            let iconSize = pMatch.pill.icon?.size ?? 14.0
                            let iconY = originY + (lineH - iconSize) * 0.5
                            inlineIconsOut.append(ShapedText.InlineIconQuad(
                                pillIndex: pMatch.idx,
                                pill: pMatch.pill,
                                rect: SIMD4<Float>(originX + penX, iconY, iconSize, iconSize),
                                cornerRadius: pMatch.pill.bareRadius,
                                image: pMatch.pill.bareImage,
                                icon: pMatch.pill.icon?.svg,
                                color: pMatch.pill.style.color
                            ))
                        } else {
                            pillBounds[pMatch.idx] = (penX, penX + lExtra, penX + lExtra, false, true, false)
                        }
                    }
                    penX += lExtra
                }

                let spanMatch = spanAt(utf8Offset: chStart)
                let spanBold = (spanMatch?.weight ?? style.weight) >= 600.0
                let spanItalic = (spanMatch?.italic == true) || style.italic
                let spanColor = spanMatch?.color
                let fontSz = spanMatch?.size ?? style.size
                let chW = charAdvance(ch, atUTF8: chStart) + (ch == " " ? extraPerSpace : 0)

                if let activePill = validPills.first(where: { !$0.pill.isBare && chStart >= $0.pill.range.lowerBound && chEnd <= $0.pill.range.upperBound }) {
                    var b = pillBounds[activePill.idx] ?? (penX, penX, penX + chW, false, false, false)
                    if !b.hasGlyphs {
                        b.x0 = originX + penX
                        b.hasGlyphs = true
                    }
                    b.x1 = originX + penX + chW
                    pillBounds[activePill.idx] = b
                }

                if let bg = spanMatch?.background {
                    rawBackgrounds.append((SIMD4<Float>(originX + penX, originY, chW, lineH), bg))
                }
                if spanMatch?.underline == true {
                    underlines.append(SIMD4<Float>(originX + penX, originY + baselineOffset + 1.5, chW, 1.0))
                }
                if spanMatch?.strikethrough == true {
                    strikethroughs.append(SIMD4<Float>(originX + penX, originY + lineH * 0.52, chW, 1.0))
                }

                if emitGlyphs {
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
                            atlasPage: entry.page
                        ))
                    }
                }
                penX += chW
                let tExtra = trailExtra(endingAtUTF8: chEnd)
                if tExtra > 0 {
                    if let activePill = validPills.first(where: { !$0.pill.isBare && $0.pill.range.upperBound == chEnd }),
                       var b = pillBounds[activePill.idx] {
                        b.hasTrail = true
                        pillBounds[activePill.idx] = b
                    }
                    penX += tExtra
                }
                for _ in 0..<chBytes {
                    charOffsets.append(penX)
                }
            }
            for (pIdx, p) in validPills where !p.isBare {
                guard let b = pillBounds[pIdx] else { continue }
                let pad = pm.resolvedPad(style: p.style)
                let x0 = b.hasLead ? (originX + b.leadX + pm.margin) : b.x0
                let x1 = b.hasTrail ? (b.x1 + pad) : b.x1
                let h = lineH
                let chipRect = SIMD4<Float>(x0, originY, max(0, x1 - x0), h)
                var iconRect: SIMD4<Float>? = nil
                if b.hasLead && p.icon?.svg != nil {
                    iconRect = SIMD4<Float>(x0 + pad, originY + (h - pm.icon) * 0.5, pm.icon, pm.icon)
                }
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
        }

        let backgrounds = Self.mergeContiguousBackgrounds(rawBackgrounds)
        return ShapedText(
            size: Vec2(totalW, totalH),
            lineCount: lines.count,
            lineHeight: lineH,
            glyphs: glyphs,
            underlines: underlines,
            strikethroughs: strikethroughs,
            backgrounds: backgrounds,
            pillChips: pillChipsOut,
            inlineIcons: inlineIconsOut,
            portableLines: lineRecords,
            forcedDirection: style.direction,
            primaryIsRTL: (style.direction == .rtl) || (style.direction == nil && (lines.first?.isRTL ?? false)),
            wasTruncated: portableTruncated
        )
    }

    internal func caretRectPortable(in shaped: ShapedText, utf8Offset: Int, pixelScale: Float) -> SIMD4<Float> {
        let clamped = max(0, utf8Offset)
        for rec in shaped.portableLines {
            let lineEnd = rec.utf8Start + rec.text.utf8.count
            if clamped <= lineEnd {
                let local = max(0, min(rec.charOffsets.count - 1, clamped - rec.utf8Start))
                return SIMD4<Float>(rec.originX + rec.charOffsets[local], rec.originY, 1.5, shaped.lineHeight)
            }
        }
        if let last = shaped.portableLines.last {
            return SIMD4<Float>(last.originX + (last.charOffsets.last ?? 0), last.originY, 1.5, shaped.lineHeight)
        }
        return SIMD4<Float>(0, 0, 1.5, shaped.lineHeight)
    }

    internal func hitTestUTF8OffsetPortable(in shaped: ShapedText, localX: Float, localY: Float, pixelScale: Float) -> Int {
        guard !shaped.portableLines.isEmpty else { return 0 }
        let lineIdx = max(0, min(shaped.portableLines.count - 1, Int(floor(max(0, localY) / max(1.0, shaped.lineHeight)))))
        let rec = shaped.portableLines[lineIdx]
        let relX = max(0, localX - rec.originX)
        var bestIdx = 0
        var bestDist = Float.greatestFiniteMagnitude
        for (i, off) in rec.charOffsets.enumerated() {
            let d = abs(off - relX)
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        return rec.utf8Start + bestIdx
    }

    internal func selectionRectsPortable(in shaped: ShapedText, utf8Range: Range<Int>, pixelScale: Float) -> [SIMD4<Float>] {
        var rects: [SIMD4<Float>] = []
        for rec in shaped.portableLines {
            let lineStart = rec.utf8Start
            let lineEnd = lineStart + rec.text.utf8.count
            let lo = max(utf8Range.lowerBound, lineStart)
            let hi = min(utf8Range.upperBound, lineEnd)
            if lo == hi && utf8Range.contains(lineStart) && utf8Range.upperBound > lineEnd {
                let endX = rec.originX + (rec.charOffsets.last ?? 0)
                rects.append(SIMD4<Float>(endX, rec.originY, 4.0, shaped.lineHeight))
                continue
            }
            guard hi > lo else { continue }
            let l0 = max(0, min(rec.charOffsets.count - 1, lo - lineStart))
            let l1 = max(0, min(rec.charOffsets.count - 1, hi - lineStart))
            let x0 = rec.originX + rec.charOffsets[l0]
            let x1 = rec.originX + rec.charOffsets[l1]
            rects.append(SIMD4<Float>(min(x0, x1), rec.originY, max(2.0, abs(x1 - x0)), shaped.lineHeight))
        }
        return rects
    }

    internal func computeInkPortable(_ text: String, style: TextStyle) -> TextInk? {
        guard !text.isEmpty else { return nil }
        let k = TextInkAccumulator.oversample
        let shaped = shapePortable(text: text, spans: nil, style: style, maxWidth: nil, pixelScale: k, emitGlyphs: false)
        let lineH = style.resolvedLineHeight * k
        let baselineOffset = lineH * 0.78
        let isMono = style.family == .monospace
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
