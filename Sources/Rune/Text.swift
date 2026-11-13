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
}

public enum TextWrap: Sendable, Hashable, Codable {
    case wrap
    case noWrap
    case ellipsis
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
    public var fontSmoothing: FontSmoothing
    public var variations: String
    public var features: String
    public var opticalSize: OpticalSize

    public init(
        size: Float = 14.0,
        weight: Float = 400.0,
        lineHeight: Float? = nil,
        letterSpacing: Float = 0.0,
        italic: Bool = false,
        family: FontFamily = .systemUI,
        align: TextAlign = .leading,
        wrap: TextWrap = .noWrap,
        fontSmoothing: FontSmoothing = .systemDefault,
        variations: String = "",
        features: String = "",
        opticalSize: OpticalSize = .auto
    ) {
        self.size = max(1.0, size)
        self.weight = weight.clamped(to: 100...900)
        self.lineHeight = lineHeight
        self.letterSpacing = letterSpacing
        self.italic = italic
        self.family = family
        self.align = align
        self.wrap = wrap
        self.fontSmoothing = fontSmoothing
        self.variations = variations
        self.features = features
        self.opticalSize = opticalSize
    }

    private enum CodingKeys: String, CodingKey {
        case size, weight, lineHeight, letterSpacing, italic, family, align, wrap, fontSmoothing, variations, features, opticalSize
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
            fontSmoothing: try c.decode(FontSmoothing.self, forKey: .fontSmoothing),
            variations: try c.decodeIfPresent(String.self, forKey: .variations) ?? "",
            features: try c.decodeIfPresent(String.self, forKey: .features) ?? "",
            opticalSize: try c.decodeIfPresent(OpticalSize.self, forKey: .opticalSize) ?? .auto
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

    public init(
        _ text: String,
        color: Color? = nil,
        background: Color? = nil,
        weight: Float? = nil,
        italic: Bool = false,
        monospace: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false
    ) {
        self.text = text
        self.color = color
        self.background = background
        self.weight = weight
        self.italic = italic
        self.monospace = monospace
        self.underline = underline
        self.strikethrough = strikethrough
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

    public init(
        rect: SIMD4<Float>,
        uv: SIMD4<Float>,
        color: Color? = nil,
        colorGlyphIndex: UInt32? = nil
    ) {
        self.rect = rect
        self.uv = uv
        self.color = color
        self.colorGlyphIndex = colorGlyphIndex
    }
}

/// Shaped multi-line text result with metrics, glyph quads, and caret lookup helpers.
/// `CTLine` is an immutable CoreText CFType safe across threads.
public struct ShapedText: @unchecked Sendable {
    public var size: Vec2
    public var lineCount: Int
    public var lineHeight: Float
    public var glyphs: [PositionedGlyph]
    public var underlines: [SIMD4<Float>]
    public var strikethroughs: [SIMD4<Float>] = []
    public var backgrounds: [(SIMD4<Float>, Color)]
    #if canImport(CoreText) && canImport(CoreGraphics)
    internal var lineStrings: [(utf8Start: Int, text: String, originY: Float, originX: Float, ctLine: CTLine?)] = []
    #endif
    fileprivate var portableLines: [(utf8Start: Int, text: String, originY: Float, originX: Float, charOffsets: [Float])] = []
}

/// Shelf-packed R8 coverage atlas for CoreText glyphs and rasterized SVG icons.
public final class GlyphAtlas: @unchecked Sendable {
    public struct Entry: Hashable, Sendable {
        public var uv: SIMD4<Float>
        public var pixelSize: SIMD2<Int>
        /// Top-left offset from baseline origin in device pixels (`x` right, `y` down from baseline).
        public var bearingPx: SIMD2<Float>
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

    /// Upstream CPU byte budget for cached RGBA color glyphs (`atlas.rs:52`, `COLOR_GLYPH_BUDGET`).
    public static let colorGlyphBudgetBytes: Int = 16 * 1024 * 1024

    #if canImport(CoreText) && canImport(CoreGraphics)
    private struct GlyphKey: Hashable {
        var fontHash: CFHashCode
        var glyphID: CGGlyph
        var sizePx10: Int
        var subpixelBin: UInt8
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
    private var shelfX: Int = 1
    private var shelfY: Int = 1
    private var shelfHeight: Int = 0
    private var accessCounter: UInt64 = 0
    #if canImport(CoreText) && canImport(CoreGraphics)
    private var glyphCache: [GlyphKey: (entry: Entry, lastUsed: UInt64)] = [:]
    private var colorGlyphCache: [ColorGlyphKey: (entry: ColorGlyphEntry, lastUsed: UInt64)] = [:]
    private var colorGlyphByIndex: [UInt32: ColorGlyphEntry] = [:]
    private var colorGlyphBytes: Int = 0
    private var nextColorGlyphIndex: UInt32 = 1
    #endif
    private var portableGlyphCache: [PortableGlyphKey: (entry: Entry, lastUsed: UInt64)] = [:]
    private var iconCache: [IconKey: (entry: Entry, lastUsed: UInt64)] = [:]

    /// Initializes the atlas with lazy CPU pixel backing (`#830`: keeps a 1-byte 1x1 stub until the first mask is placed).
    public convenience init(width: Int = 1024, height: Int = 1024, maxCachedEntries: Int = 4096) {
        self.init(
            width: width,
            height: height,
            maxCachedEntries: maxCachedEntries,
            colorGlyphBudget: GlyphAtlas.colorGlyphBudgetBytes
        )
    }

    /// Initializes the atlas with an explicit color-glyph CPU memory budget (`#807`, default 16 MiB).
    public init(
        width: Int = 1024,
        height: Int = 1024,
        maxCachedEntries: Int = 4096,
        colorGlyphBudget: Int
    ) {
        self.targetWidth = max(1, width)
        self.targetHeight = max(1, height)
        self.atlas = R8Atlas(width: 1, height: 1)
        self.maxCachedEntries = max(1, maxCachedEntries)
        self.maxColorGlyphBytes = max(0, colorGlyphBudget)
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
            portableGlyphCache[key] = cached
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
        guard let uv = allocateAndBlit(width: r.width, height: r.height, bitmap: r.bitmap) else {
            lock.unlock()
            return Entry(uv: .zero, pixelSize: SIMD2<Int>(r.width, r.height), bearingPx: SIMD2<Float>(0, r.bearingY))
        }
        let entry = Entry(
            uv: uv,
            pixelSize: SIMD2<Int>(r.width, r.height),
            bearingPx: SIMD2<Float>(0, r.bearingY)
        )
        accessCounter &+= 1
        portableGlyphCache[key] = (entry, accessCounter)
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
        colorGlyphCache[key] = (entry, accessCounter)
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
        smoothing: FontSmoothing = .systemDefault
    ) -> Entry? {
        let bin = UInt8(((subpixelX - floorf(subpixelX)) * 4.0).rounded()) & 3
        let subShift = Float(bin) * 0.25
        let key = GlyphKey(
            fontHash: CFHash(font),
            glyphID: glyph,
            sizePx10: Int((fontSizePx * 10.0).rounded()),
            subpixelBin: bin,
            smoothing: smoothing
        )
        lock.lock()
        if var cached = glyphCache[key] {
            accessCounter &+= 1
            cached.lastUsed = accessCounter
            glyphCache[key] = cached
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
            glyphCache[key] = (empty, accessCounter)
            evictLRUIfNeededLocked()
            lock.unlock()
            return empty
        }

        let pad = 2
        let minX = Int(floor(bbox.minX)) - pad
        let maxX = Int(ceil(bbox.maxX + CGFloat(subShift))) + pad
        let minY = Int(floor(bbox.minY)) - pad
        let maxY = Int(ceil(bbox.maxY)) + pad
        let bw = max(1, maxX - minX)
        let bh = max(1, maxY - minY)

        var bitmap = Array<UInt8>(repeating: 0, count: bw * bh)
        let graySpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &bitmap,
            width: bw,
            height: bh,
            bitsPerComponent: 8,
            bytesPerRow: bw,
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

        var pos = CGPoint(x: CGFloat(-minX) + CGFloat(subShift), y: CGFloat(-minY))
        CTFontDrawGlyphs(font, &g, &pos, 1, ctx)

        lock.lock()
        guard let uv = allocateAndBlit(width: bw, height: bh, bitmap: bitmap) else {
            lock.unlock()
            return nil
        }
        // CoreGraphics row 0 in `bitmap` is the TOP row (`y = maxY` above baseline)!
        let entry = Entry(
            uv: uv,
            pixelSize: SIMD2<Int>(bw, bh),
            bearingPx: SIMD2<Float>(Float(minX) - subShift, Float(-maxY))
        )
        accessCounter &+= 1
        glyphCache[key] = (entry, accessCounter)
        evictLRUIfNeededLocked()
        lock.unlock()
        return entry
    }
    #endif

    public static func rasterizeIconBitmap(_ icon: SVGIcon, pixelSize: Int) -> [UInt8] {
        let px = max(1, pixelSize)
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
            let scale = CGFloat(px) / CGFloat(icon.viewBox)
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
        return PortableSVGRasterizer.rasterize(resolvedIcon, pixelSize: px)
        #endif
    }

    public func rasterizeIcon(_ icon: SVGIcon, pixelSize: Int) -> Entry {
        let px = max(4, pixelSize)
        let key = IconKey(icon: icon, pixelSize: px)
        lock.lock()
        if var cached = iconCache[key] {
            accessCounter &+= 1
            cached.lastUsed = accessCounter
            iconCache[key] = cached
            lock.unlock()
            return cached.entry
        }
        lock.unlock()

        let bitmap = Self.rasterizeIconBitmap(icon, pixelSize: px)

        lock.lock()
        guard let uv = allocateAndBlit(width: px, height: px, bitmap: bitmap) else {
            lock.unlock()
            return Entry(uv: .zero, pixelSize: SIMD2<Int>(px, px), bearingPx: .zero)
        }
        let entry = Entry(uv: uv, pixelSize: SIMD2<Int>(px, px), bearingPx: .zero)
        accessCounter &+= 1
        iconCache[key] = (entry, accessCounter)
        evictLRUIfNeededLocked()
        lock.unlock()
        return entry
    }

    private func ensureBackingLocked() {
        if !backingAllocated {
            atlas = R8Atlas(width: targetWidth, height: targetHeight)
            backingAllocated = true
        }
    }

    private func allocateAndBlit(width bw: Int, height bh: Int, bitmap: [UInt8]) -> SIMD4<Float>? {
        guard bw > 0, bh > 0 else { return nil }
        ensureBackingLocked()
        if bw + 2 > atlas.width || bh + 2 > atlas.height {
            growAtlas(minWidth: max(atlas.width, bw + 4), minHeight: max(atlas.height, bh + 4))
        }
        guard bw + 2 <= atlas.width && bh + 2 <= atlas.height else {
            return nil
        }
        if shelfX + bw + 1 >= atlas.width {
            shelfX = 1
            shelfY += shelfHeight + 1
            shelfHeight = 0
        }
        if shelfY + bh + 1 >= atlas.height {
            if atlas.height >= maxAtlasDimension {
                resetShelfLocked()
            } else {
                growAtlas(minWidth: atlas.width, minHeight: shelfY + bh + 2)
            }
        }
        guard shelfX + bw + 1 <= atlas.width && shelfY + bh + 1 <= atlas.height else {
            return nil
        }

        let dstX = shelfX
        let dstY = shelfY
        for row in 0..<bh {
            let srcStart = row * bw
            let dstStart = (dstY + row) * atlas.width + dstX
            for col in 0..<bw {
                atlas.texels[dstStart + col] = bitmap[srcStart + col]
            }
        }
        shelfX += bw + 1
        shelfHeight = max(shelfHeight, bh)
        generation &+= 1

        let invW = 1.0 / Float(atlas.width)
        let invH = 1.0 / Float(atlas.height)
        return SIMD4<Float>(
            Float(dstX) * invW,
            Float(dstY) * invH,
            Float(dstX + bw) * invW,
            Float(dstY + bh) * invH
        )
    }

    private func resetShelfLocked() {
        shelfX = 1
        shelfY = 1
        shelfHeight = 0
        if !atlas.texels.isEmpty {
            atlas.texels.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress {
                    memset(base, 0, raw.count)
                }
            }
        }
        #if canImport(CoreText) && canImport(CoreGraphics)
        glyphCache.removeAll()
        #endif
        portableGlyphCache.removeAll()
        iconCache.removeAll()
        generation &+= 1
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

    private func growAtlas(minWidth: Int, minHeight: Int) {
        let oldW = atlas.width
        let oldH = atlas.height
        let newW = min(maxAtlasDimension, minWidth > oldW ? max(oldW * 2, minWidth) : oldW)
        let newH = min(maxAtlasDimension, minHeight > oldH ? max(oldH * 2, minHeight) : oldH)
        if atlas.texels.isEmpty {
            atlas = R8Atlas(width: newW, height: newH, texels: [])
        } else {
            var newTexels = Array<UInt8>(repeating: 0, count: newW * newH)
            if newW == oldW {
                newTexels.replaceSubrange(0..<atlas.texels.count, with: atlas.texels)
            } else {
                for r in 0..<oldH {
                    let srcOff = r * oldW
                    let dstOff = r * newW
                    newTexels.replaceSubrange(dstOff..<(dstOff + oldW), with: atlas.texels[srcOff..<(srcOff + oldW)])
                }
            }
            atlas = R8Atlas(width: newW, height: newH, texels: newTexels)
        }
        let wRatio = Float(oldW) / Float(newW)
        let hRatio = Float(oldH) / Float(newH)
        #if canImport(CoreText) && canImport(CoreGraphics)
        for (k, var v) in glyphCache {
            v.entry.uv.x *= wRatio
            v.entry.uv.z *= wRatio
            v.entry.uv.y *= hRatio
            v.entry.uv.w *= hRatio
            glyphCache[k] = v
        }
        #endif
        for (k, var v) in portableGlyphCache {
            v.entry.uv.x *= wRatio
            v.entry.uv.z *= wRatio
            v.entry.uv.y *= hRatio
            v.entry.uv.w *= hRatio
            portableGlyphCache[k] = v
        }
        for (k, var v) in iconCache {
            v.entry.uv.x *= wRatio
            v.entry.uv.z *= wRatio
            v.entry.uv.y *= hRatio
            v.entry.uv.w *= hRatio
            iconCache[k] = v
        }
        generation &+= 1
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
        var weight10: Int
        var italic: Bool
    }

    private struct MeasureKey: Hashable {
        var text: String
        var style: TextStyle
        var maxWidthHalfPt: Int
        var scale100: Int
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
    private var measureCache: [MeasureKey: Vec2] = [:]

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
        lock.unlock()

        FontFamiliesRegistry.setFamilies(sans: sans, mono: mono)
        let newEpoch = fontEpoch()
        lock.lock()
        lastObservedFontEpoch = newEpoch
        lock.unlock()
        return true
    }

    private func syncGlobalFamiliesIfNeeded() {
        let globalEpoch = fontEpoch()
        let langEpoch = TextLanguageRegistry.currentEpoch()
        lock.lock()
        if lastObservedFontEpoch != globalEpoch {
            let (sans, mono) = FontFamiliesRegistry.currentFamilies()
            sansFamilyOverride = sans
            monoFamilyOverride = mono
            #if canImport(CoreText) && canImport(CoreGraphics)
            fontCache.removeAll(keepingCapacity: true)
            #endif
            measureCache.removeAll(keepingCapacity: true)
            lastObservedFontEpoch = globalEpoch
        }
        if lastObservedLanguageEpoch != langEpoch {
            let globalTag = TextLanguageRegistry.currentLanguageTag()
            if languageTagOverride != globalTag {
                languageTagOverride = globalTag
                measureCache.removeAll(keepingCapacity: true)
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

    internal func resolveCTFont(style: TextStyle, pixelScale: Float) -> CTFont {
        syncGlobalFamiliesIfNeeded()
        let sizePx = style.size * pixelScale
        let key = FontKey(
            family: style.family,
            sizePx10: Int((sizePx * 10.0).rounded()),
            weight10: Int(style.weight.rounded()),
            italic: style.italic
        )
        lock.lock()
        if let cached = fontCache[key] {
            lock.unlock()
            return cached
        }
        let sansList = sansFamilyOverride
        let monoList = monoFamilyOverride
        lock.unlock()

        let ctWeight = Self.coreTextWeight(for: style.weight)
        var traits: [CFString: Any] = [
            kCTFontWeightTrait: ctWeight,
        ]
        if style.italic {
            traits[kCTFontSlantTrait] = CGFloat(0.15)
        }

        let baseFont: CTFont
        switch style.family {
        case .systemUI:
            baseFont = (!sansList.isEmpty ? Self.firstMatchingFont(in: sansList, sizePx: CGFloat(sizePx)) : nil)
                ?? CTFontCreateUIFontForLanguage(.system, CGFloat(sizePx), nil)
                ?? CTFontCreateWithName("SFProText-Regular" as CFString, CGFloat(sizePx), nil)
        case .monospace:
            baseFont = (!monoList.isEmpty ? Self.firstMatchingFont(in: monoList, sizePx: CGFloat(sizePx)) : nil)
                ?? CTFontCreateUIFontForLanguage(.userFixedPitch, CGFloat(sizePx), nil)
                ?? CTFontCreateWithName("Menlo-Regular" as CFString, CGFloat(sizePx), nil)
        case .custom(let name):
            baseFont = CTFontCreateWithName(name as CFString, CGFloat(sizePx), nil)
        }

        let desc = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(baseFont),
            [kCTFontTraitsAttribute: traits] as CFDictionary
        )
        let weighted = CTFontCreateCopyWithAttributes(baseFont, CGFloat(sizePx), nil, desc)
        lock.lock()
        fontCache[key] = weighted
        lock.unlock()
        return weighted
    }

    /// Fast cached measurement of plain `text` constrained to `maxWidth` logical points.
    /// When `maxWidth` is non-nil and `style.wrap == .noWrap`, wraps at `maxWidth` per upstream `text::measure`.
    public func measure(_ text: String, style: TextStyle, maxWidth: Float?, pixelScale: Float) -> Vec2 {
        if text.isEmpty {
            return Vec2(0, style.resolvedLineHeight)
        }
        var effectiveStyle = style
        if maxWidth != nil && effectiveStyle.wrap == .noWrap {
            effectiveStyle.wrap = .wrap
        }
        let maxWKey = maxWidth.map { Int(($0 * 2.0).rounded()) } ?? -1
        let key = MeasureKey(text: text, style: effectiveStyle, maxWidthHalfPt: maxWKey, scale100: Int((pixelScale * 100).rounded()))
        lock.lock()
        if let cached = measureCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let shaped = shape(text: text, style: effectiveStyle, maxWidth: maxWidth, pixelScale: pixelScale, emitGlyphs: false)
        lock.lock()
        if measureCache.count > 4096 {
            measureCache.removeAll(keepingCapacity: true)
        }
        measureCache[key] = shaped.size
        lock.unlock()
        return shaped.size
    }

    /// Shapes plain or rich text into lines and optional `GlyphAtlas` quads.
    public func shape(
        text: String,
        spans: [TextSpan]? = nil,
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        emitGlyphs: Bool = true
    ) -> ShapedText {
        measureFramePhase(.text) {
            shapeImpl(
                text: text,
                spans: spans,
                style: style,
                maxWidth: maxWidth,
                pixelScale: pixelScale,
                emitGlyphs: emitGlyphs
            )
        }
    }

    private func shapeImpl(
        text: String,
        spans: [TextSpan]? = nil,
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        emitGlyphs: Bool = true
    ) -> ShapedText {
        let scale = max(pixelScale, 1.0)
        let lhPt = style.resolvedLineHeight
        let lhPx = lhPt * scale
        let fullText = spans.map { $0.map(\.text).joined() } ?? text

        if fullText.isEmpty {
            return ShapedText(
                size: Vec2(0, lhPt),
                lineCount: 1,
                lineHeight: lhPt,
                glyphs: [],
                underlines: [],
                backgrounds: [],
                lineStrings: [(0, "", 0, 0, nil)]
            )
        }

        let baseFont = resolveCTFont(style: style, pixelScale: scale)
        let attrStr = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
        CFAttributedStringReplaceString(attrStr, CFRangeMake(0, 0), fullText as CFString)
        let fullLen = CFAttributedStringGetLength(attrStr)
        CFAttributedStringSetAttribute(attrStr, CFRangeMake(0, fullLen), kCTFontAttributeName, baseFont)
        if let langTag = TextLanguageRegistry.effectiveLanguageTag(for: fullText, chosen: language) {
            CFAttributedStringSetAttribute(attrStr, CFRangeMake(0, fullLen), kCTLanguageAttributeName, langTag as CFString)
        }
        if style.letterSpacing != 0 {
            let kern = CGFloat(style.letterSpacing * scale) as CFNumber
            CFAttributedStringSetAttribute(attrStr, CFRangeMake(0, fullLen), kCTKernAttributeName, kern)
        }

        // Apply per-span font/color overrides if rich spans are supplied
        let spanColorKey = "RuneColorIndex" as CFString
        var spanPalette: [Color] = []
        struct DecoratedRange {
            var u16Range: Range<Int>
            var underline: Bool
            var strikethrough: Bool
            var background: Color?
        }
        var decoratedRanges: [DecoratedRange] = []
        if let spans {
            var utf16Cursor = 0
            for span in spans {
                let u16Count = span.text.utf16.count
                guard u16Count > 0 else { continue }
                let range = CFRangeMake(utf16Cursor, u16Count)
                if span.weight != nil || span.italic || span.monospace {
                    var subStyle = style
                    if let w = span.weight { subStyle.weight = w }
                    if span.italic { subStyle.italic = true }
                    if span.monospace { subStyle.family = .monospace }
                    let subFont = resolveCTFont(style: subStyle, pixelScale: scale)
                    CFAttributedStringSetAttribute(attrStr, range, kCTFontAttributeName, subFont)
                }
                if let col = span.color {
                    let idx = spanPalette.count
                    spanPalette.append(col)
                    CFAttributedStringSetAttribute(attrStr, range, spanColorKey, idx as CFNumber)
                }
                if span.underline || span.strikethrough || span.background != nil {
                    decoratedRanges.append(DecoratedRange(
                        u16Range: utf16Cursor..<(utf16Cursor + u16Count),
                        underline: span.underline,
                        strikethrough: span.strikethrough,
                        background: span.background
                    ))
                }
                utf16Cursor += u16Count
            }
        }

        // Break into visual lines using CTFramesetter (when wrapping) or explicit '\n' lines
        var visualLines: [(ctLine: CTLine, utf8Start: Int, u16Start: Int, u16End: Int, substr: String, widthPx: Float)] = []
        let typesetter = CTTypesetterCreateWithAttributedString(attrStr)
        let effectiveWrapWidthPx: CGFloat? = (style.wrap == .wrap && maxWidth != nil)
            ? CGFloat(max(1.0, maxWidth! * scale))
            : nil

        var u16Start = 0
        var utf8Cursor = 0
        let nsStr = fullText as NSString

        while u16Start < fullLen {
            // Find next hard newline from u16Start
            var hardEnd = fullLen
            for i in u16Start..<fullLen {
                if nsStr.character(at: i) == 0x0A {
                    hardEnd = i
                    break
                }
            }
            var segStart = u16Start
            if segStart == hardEnd {
                // Empty line before '\n'
                let emptyAttr = CFAttributedStringCreate(kCFAllocatorDefault, "" as CFString, [kCTFontAttributeName: baseFont] as CFDictionary)!
                let ctLine = CTLineCreateWithAttributedString(emptyAttr)
                visualLines.append((ctLine, utf8Cursor, segStart, segStart, "", 0))
            } else {
                while segStart < hardEnd {
                    let count: CFIndex
                    if let wrapW = effectiveWrapWidthPx {
                        let suggested = CTTypesetterSuggestLineBreak(typesetter, segStart, Double(wrapW))
                        count = min(max(1, suggested), hardEnd - segStart)
                    } else {
                        count = hardEnd - segStart
                    }
                    let cfRange = CFRangeMake(segStart, count)
                    var ctLine = CTTypesetterCreateLine(typesetter, cfRange)
                    if style.wrap == .ellipsis, let maxW = maxWidth {
                        let maxWPx = Double(maxW * scale)
                        let rawW = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
                        if rawW > maxWPx {
                            let ellipAttr = CFAttributedStringCreate(
                                kCFAllocatorDefault,
                                "…" as CFString,
                                [kCTFontAttributeName: baseFont] as CFDictionary
                            )!
                            let token = CTLineCreateWithAttributedString(ellipAttr)
                            if let truncated = CTLineCreateTruncatedLine(ctLine, maxWPx, .end, token) {
                                ctLine = truncated
                            }
                        }
                    }
                    let sub = nsStr.substring(with: NSRange(location: segStart, length: count))
                    let wPx = Float(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
                    visualLines.append((ctLine, utf8Cursor, segStart, segStart + count, sub, wPx))
                    utf8Cursor += sub.utf8.count
                    segStart += count
                }
            }
            if hardEnd < fullLen && nsStr.character(at: hardEnd) == 0x0A {
                utf8Cursor += 1
                u16Start = hardEnd + 1
                if u16Start == fullLen {
                    // Trailing newline creates an empty final line!
                    let emptyAttr = CFAttributedStringCreate(kCFAllocatorDefault, "" as CFString, [kCTFontAttributeName: baseFont] as CFDictionary)!
                    let ctLine = CTLineCreateWithAttributedString(emptyAttr)
                    visualLines.append((ctLine, utf8Cursor, u16Start, u16Start, "", 0))
                }
            } else {
                u16Start = hardEnd
            }
        }

        let maxLineWidthPx = visualLines.reduce(Float(0)) { max($0, $1.widthPx) }
        let containerWidthPx = maxWidth.map { max(maxLineWidthPx, $0 * scale) } ?? maxLineWidthPx
        let ascentPx = Float(CTFontGetAscent(baseFont))
        let descentPx = Float(CTFontGetDescent(baseFont))
        let halfLeadingPx = (lhPx - (ascentPx + descentPx)) * 0.5

        var glyphsOut: [PositionedGlyph] = []
        var underlinesOut: [SIMD4<Float>] = []
        var strikethroughsOut: [SIMD4<Float>] = []
        var backgroundsOut: [(SIMD4<Float>, Color)] = []
        var lineRecords: [(utf8Start: Int, text: String, originY: Float, originX: Float, ctLine: CTLine?)] = []
        lineRecords.reserveCapacity(visualLines.count)

        let invS = 1.0 / scale
        let ascentPt = ascentPx * invS
        let strokeThicknessPt = max(1.0, style.size * 0.07)

        for (lineIdx, item) in visualLines.enumerated() {
            let lineTopPx = Float(lineIdx) * lhPx
            let baselineYPx = (lineTopPx + halfLeadingPx + ascentPx).rounded()
            let alignOffsetPx: Float
            switch style.align {
            case .leading:
                alignOffsetPx = 0
            case .center:
                alignOffsetPx = max(0, (containerWidthPx - item.widthPx) * 0.5)
            case .trailing:
                alignOffsetPx = max(0, containerWidthPx - item.widthPx)
            }

            let originXPt = alignOffsetPx * invS
            let originYPt = lineTopPx * invS
            lineRecords.append((
                utf8Start: item.utf8Start,
                text: item.substr,
                originY: originYPt,
                originX: originXPt,
                ctLine: item.ctLine
            ))

            if emitGlyphs && !decoratedRanges.isEmpty && item.u16End > item.u16Start {
                for dec in decoratedRanges {
                    let lo = max(item.u16Start, dec.u16Range.lowerBound)
                    let hi = min(item.u16End, dec.u16Range.upperBound)
                    guard hi > lo else { continue }
                    let localLo = lo - item.u16Start
                    let localHi = hi - item.u16Start
                    let x0Px = Float(CTLineGetOffsetForStringIndex(item.ctLine, localLo, nil))
                    let x1Px = Float(CTLineGetOffsetForStringIndex(item.ctLine, localHi, nil))
                    let xPt = originXPt + min(x0Px, x1Px) * invS
                    let wPt = abs(x1Px - x0Px) * invS
                    guard wPt > 0.01 else { continue }
                    if let bg = dec.background {
                        backgroundsOut.append((SIMD4<Float>(xPt, originYPt, wPt, lhPt), bg))
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

            guard emitGlyphs else { continue }
            let runs = CTLineGetGlyphRuns(item.ctLine) as? [CTRun] ?? []
            for run in runs {
                let glyphCount = CTRunGetGlyphCount(run)
                if glyphCount == 0 { continue }
                let attrs = CTRunGetAttributes(run) as NSDictionary
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

                let invS = 1.0 / scale
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

                    guard let entry = glyphAtlas.rasterizeGlyph(
                        font: runFont,
                        glyph: glyphs[i],
                        fontSizePx: runFontSizePx,
                        subpixelX: subX,
                        smoothing: style.fontSmoothing
                    ), entry.pixelSize.x > 0 && entry.pixelSize.y > 0 else {
                        continue
                    }

                    let quadXPx = floorX + subX + entry.bearingPx.x
                    let quadYPx = gyPx + entry.bearingPx.y
                    glyphsOut.append(PositionedGlyph(
                        rect: SIMD4<Float>(
                            quadXPx * invS,
                            quadYPx * invS,
                            Float(entry.pixelSize.x) * invS,
                            Float(entry.pixelSize.y) * invS
                        ),
                        uv: entry.uv,
                        color: runColor
                    ))
                }
            }
        }

        let totalHeightPt = Float(max(1, visualLines.count)) * lhPt
        let totalWidthPt = ceilf(maxLineWidthPx / scale * 2.0) * 0.5
        return ShapedText(
            size: Vec2(totalWidthPt, totalHeightPt),
            lineCount: max(1, visualLines.count),
            lineHeight: lhPt,
            glyphs: glyphsOut,
            underlines: underlinesOut,
            strikethroughs: strikethroughsOut,
            backgrounds: backgroundsOut,
            lineStrings: lineRecords
        )
    }

    /// Computes caret `(x, y, height)` in element-local logical points for `utf8Offset` in `shaped`.
    public func caretRect(in shaped: ShapedText, utf8Offset: Int, pixelScale: Float) -> SIMD4<Float> {
        let scale = max(pixelScale, 1.0)
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
        let localUTF8 = (utf8Offset - rec.utf8Start).clamped(to: 0...rec.text.utf8.count)
        let prefixUTF8 = rec.text.utf8.prefix(localUTF8)
        let localUTF16 = String(decoding: prefixUTF8, as: UTF8.self).utf16.count
        var xPt = rec.originX
        if let ctLine = rec.ctLine {
            let offsetPx = CTLineGetOffsetForStringIndex(ctLine, localUTF16, nil)
            xPt += Float(offsetPx) / scale
        }
        return SIMD4<Float>(xPt, rec.originY, 1.5, shaped.lineHeight)
    }

    /// Hit-tests `(localX, localY)` in element-local logical points to a UTF-8 byte offset.
    public func hitTestUTF8Offset(in shaped: ShapedText, localX: Float, localY: Float, pixelScale: Float) -> Int {
        guard !shaped.lineStrings.isEmpty else { return 0 }
        let scale = max(pixelScale, 1.0)
        let lineIdx = Int(floorf(max(0, localY) / max(1, shaped.lineHeight)))
            .clamped(to: 0...(shaped.lineStrings.count - 1))
        let rec = shaped.lineStrings[lineIdx]
        guard let ctLine = rec.ctLine, !rec.text.isEmpty else {
            return rec.utf8Start
        }
        let relXPx = CGFloat((localX - rec.originX) * scale)
        let u16Idx = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: relXPx, y: 0))
        if u16Idx == kCFNotFound || u16Idx <= 0 {
            return rec.utf8Start
        }
        let clampedU16 = min(u16Idx, rec.text.utf16.count)
        let u16Prefix = rec.text.utf16.prefix(clampedU16)
        let prefixStr = String(decoding: u16Prefix, as: UTF16.self)
        return rec.utf8Start + prefixStr.utf8.count
    }

    /// Computes per-line selection rectangles `[x, y, width, height]` in logical points for `utf8Range`.
    public func selectionRects(in shaped: ShapedText, utf8Range: Range<Int>, pixelScale: Float) -> [SIMD4<Float>] {
        guard !utf8Range.isEmpty, !shaped.lineStrings.isEmpty else { return [] }
        let scale = max(pixelScale, 1.0)
        let invS = 1.0 / scale
        var rects: [SIMD4<Float>] = []
        for rec in shaped.lineStrings {
            let lineStart = rec.utf8Start
            let lineEnd = lineStart + rec.text.utf8.count
            let lo = max(lineStart, utf8Range.lowerBound)
            let hi = min(lineEnd, utf8Range.upperBound)
            if hi < lo { continue }
            if hi == lo && utf8Range.upperBound > lineEnd {
                // Newline at end of empty or non-empty line: show a narrow trailing selection sliver
                let endX: Float
                if let ctLine = rec.ctLine, !rec.text.isEmpty {
                    let u16Len = rec.text.utf16.count
                    endX = rec.originX + Float(CTLineGetOffsetForStringIndex(ctLine, u16Len, nil)) * invS
                } else {
                    endX = rec.originX
                }
                rects.append(SIMD4<Float>(endX, rec.originY, 4.0, shaped.lineHeight))
                continue
            }
            guard hi > lo else { continue }
            let localLo = lo - lineStart
            let localHi = hi - lineStart
            let u16Lo = String(decoding: rec.text.utf8.prefix(localLo), as: UTF8.self).utf16.count
            let u16Hi = String(decoding: rec.text.utf8.prefix(localHi), as: UTF8.self).utf16.count
            let x0: Float
            let x1: Float
            if let ctLine = rec.ctLine {
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
    public func measure(_ text: String, style: TextStyle, maxWidth: Float?, pixelScale: Float) -> Vec2 {
        measureFramePhase(.text) {
            measurePortable(text, style: style, maxWidth: maxWidth, pixelScale: pixelScale)
        }
    }

    public func shape(
        text: String,
        spans: [TextSpan]? = nil,
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        emitGlyphs: Bool = true
    ) -> ShapedText {
        measureFramePhase(.text) {
            shapePortable(text: text, spans: spans, style: style, maxWidth: maxWidth, pixelScale: pixelScale, emitGlyphs: emitGlyphs)
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
            let scale = max(pixelScale, 1.0)
            let localUTF8 = (utf8Offset - ctRec.utf8Start).clamped(to: 0...ctRec.text.utf8.count)
            let localUTF16 = String(decoding: ctRec.text.utf8.prefix(localUTF8), as: UTF8.self).utf16.count
            var xPt = ctRec.originX
            if let ctLine = ctRec.ctLine {
                xPt += Float(CTLineGetOffsetForStringIndex(ctLine, localUTF16, nil)) / scale
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

    internal func measurePortable(_ text: String, style: TextStyle, maxWidth: Float?, pixelScale: Float) -> Vec2 {
        if text.isEmpty {
            return Vec2(0, style.resolvedLineHeight)
        }
        var effectiveStyle = style
        if maxWidth != nil && effectiveStyle.wrap == .noWrap {
            effectiveStyle.wrap = .wrap
        }
        let key = MeasureKey(
            text: text,
            style: effectiveStyle,
            maxWidthHalfPt: maxWidth.map { Int(($0 * 2.0).rounded()) } ?? -1,
            scale100: Int((pixelScale * 100.0).rounded())
        )
        lock.lock()
        if let cached = measureCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let shaped = shapePortable(text: text, spans: nil, style: effectiveStyle, maxWidth: maxWidth, pixelScale: pixelScale, emitGlyphs: false)
        lock.lock()
        if measureCache.count > 4096 {
            measureCache.removeAll(keepingCapacity: true)
        }
        measureCache[key] = shaped.size
        lock.unlock()
        return shaped.size
    }

    internal func shapePortable(
        text: String,
        spans: [TextSpan]? = nil,
        style: TextStyle,
        maxWidth: Float?,
        pixelScale: Float,
        emitGlyphs: Bool = true
    ) -> ShapedText {
        let scale = max(1.0, pixelScale)
        let invS = 1.0 / scale
        let lineH = style.resolvedLineHeight
        let fullText = spans.map { $0.map(\.text).joined() } ?? text

        if fullText.isEmpty {
            return ShapedText(
                size: Vec2(0, lineH),
                lineCount: 1,
                lineHeight: lineH,
                glyphs: [],
                underlines: [],
                strikethroughs: [],
                backgrounds: [],
                portableLines: [(0, "", 0, 0, [0])]
            )
        }

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

        func spanAt(utf8Offset: Int) -> TextSpan? {
            spanEntries.last { $0.utf8Range.contains(utf8Offset) }?.span
        }

        func charAdvance(_ ch: Character, atUTF8 utf8Offset: Int) -> Float {
            let match = spanAt(utf8Offset: utf8Offset)
            let isMono = match?.monospace == true || style.family == .monospace
            let count = ch.unicodeScalars.count
            let scalarSum = ch.unicodeScalars.reduce(Float(0)) { acc, scalar in
                acc + PortableGlyphFont.advanceRatio(for: scalar, mono: isMono) * style.size
            }
            return scalarSum + (count > 0 ? style.letterSpacing : 0)
        }

        // Split into raw lines on '\n' and wrap/ellipsis if requested.
        var lines: [(utf8Start: Int, text: String, width: Float)] = []
        var cursorUTF8 = 0
        let rawParagraphs = fullText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (pIdx, para) in rawParagraphs.enumerated() {
            if para.isEmpty {
                lines.append((cursorUTF8, "", 0))
            } else if style.wrap == .wrap, let maxW = maxWidth, maxW > 0 {
                var current = ""
                var curW: Float = 0
                var lineStart = cursorUTF8
                var charUTF8 = cursorUTF8
                for ch in para {
                    let chBytes = String(ch).utf8.count
                    let chW = charAdvance(ch, atUTF8: charUTF8)
                    if !current.isEmpty && curW + chW > maxW {
                        lines.append((lineStart, current, curW))
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
                    lines.append((lineStart, current, curW))
                }
            } else if style.wrap == .ellipsis, let maxW = maxWidth, maxW > 0 {
                var current = ""
                var curW: Float = 0
                let ellW = charAdvance("…", atUTF8: cursorUTF8)
                var truncated = false
                var charUTF8 = cursorUTF8
                for ch in para {
                    let chBytes = String(ch).utf8.count
                    let chW = charAdvance(ch, atUTF8: charUTF8)
                    if curW + chW + ellW > maxW {
                        truncated = true
                        break
                    }
                    current.append(ch)
                    curW += chW
                    charUTF8 += chBytes
                }
                if truncated {
                    current.append("…")
                    curW += ellW
                }
                lines.append((cursorUTF8, current, curW))
            } else {
                var w: Float = 0
                var charUTF8 = cursorUTF8
                for ch in para {
                    w += charAdvance(ch, atUTF8: charUTF8)
                    charUTF8 += String(ch).utf8.count
                }
                lines.append((cursorUTF8, para, w))
            }
            cursorUTF8 += para.utf8.count
            if pIdx + 1 < rawParagraphs.count {
                cursorUTF8 += 1
            }
        }
        if lines.isEmpty {
            lines = [(0, "", 0)]
        }

        let maxLineW = lines.map(\.width).max() ?? 0
        let totalW = maxWidth.map { style.align == .leading ? min($0, maxLineW) : $0 } ?? maxLineW
        let totalH = Float(lines.count) * lineH

        var glyphs: [PositionedGlyph] = []
        var underlines: [SIMD4<Float>] = []
        var strikethroughs: [SIMD4<Float>] = []
        var backgrounds: [(SIMD4<Float>, Color)] = []
        var lineRecords: [(utf8Start: Int, text: String, originY: Float, originX: Float, charOffsets: [Float])] = []

        let baselineOffset = lineH * 0.78
        for (idx, item) in lines.enumerated() {
            let originY = Float(idx) * lineH
            let originX: Float
            switch style.align {
            case .leading: originX = 0
            case .center: originX = max(0, (totalW - item.width) * 0.5)
            case .trailing: originX = max(0, totalW - item.width)
            }

            var charOffsets: [Float] = [0]
            var penX: Float = 0
            var bytePos = item.utf8Start
            for ch in item.text {
                let chStart = bytePos
                let chBytes = String(ch).utf8.count
                bytePos += chBytes
                let spanMatch = spanAt(utf8Offset: chStart)
                let spanBold = (spanMatch?.weight ?? style.weight) >= 600.0
                let spanItalic = (spanMatch?.italic == true) || style.italic
                let spanColor = spanMatch?.color
                let chW = charAdvance(ch, atUTF8: chStart)

                if let bg = spanMatch?.background {
                    backgrounds.append((SIMD4<Float>(originX + penX, originY, chW, lineH), bg))
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
                            fontSizePx: style.size * scale,
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
                            color: spanColor
                        ))
                    }
                }
                penX += chW
                for _ in 0..<chBytes {
                    charOffsets.append(penX)
                }
            }
            lineRecords.append((item.utf8Start, item.text, originY, originX, charOffsets))
        }

        return ShapedText(
            size: Vec2(totalW, totalH),
            lineCount: lines.count,
            lineHeight: lineH,
            glyphs: glyphs,
            underlines: underlines,
            strikethroughs: strikethroughs,
            backgrounds: backgrounds,
            portableLines: lineRecords
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
