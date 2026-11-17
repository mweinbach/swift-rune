import Foundation
#if canImport(CoreText) && canImport(CoreGraphics)
import CoreText
import CoreGraphics
#endif

/// Retention policy for shaped and broken text layouts (`layout_cache::Keep`).
public enum TextKeep: Sendable, Hashable {
    case cached
    case owned
    case secret
}

/// Visible vertical interval in the text layout's local points.
public struct TextRasterWindow: Hashable, Sendable {
    public var lowerY: Float
    public var upperY: Float

    public init(lowerY: Float, upperY: Float) {
        self.lowerY = lowerY
        self.upperY = upperY
    }

    internal func intersects(_ top: Float, _ bottom: Float) -> Bool {
        lowerY < upperY && top < upperY && lowerY < bottom
    }

    /// The shaping band includes two ems, allowing a large span on a neighbouring line to reach the clip.
    internal func expanded(for style: TextStyle, spans: [TextSpan]?, scale: Float) -> Self {
        let em = max(style.size, style.lineHeight ?? style.size, spans?.compactMap(\.size).max() ?? 0)
        let pad = 2 * em + 2 / max(scale, 0.0625)
        return Self(lowerY: lowerY - pad, upperY: upperY + pad)
    }

    /// Search the measured line boxes; glyph masks are requested only for candidate lines.
    internal func lines(in layout: ShapedText) -> Range<Int> {
        func first(_ matches: (Int) -> Bool) -> Int {
            var lo = 0, hi = layout.lineCount
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if matches(mid) { hi = mid } else { lo = mid + 1 }
            }
            return lo
        }
        let start = first { layout.lineTopPt($0) + layout.lineBoxHeightPt($0) >= lowerY }
        let end = first { layout.lineTopPt($0) > upperY }
        return start..<max(start, end)
    }

    /// Clips and origins are device coordinates. Captured or turned layers paint in their own space.
    internal static func paint(top: Float, bottom: Float, viewport: Float, origin: Float,
                               scale: Float, margin: Float, transformed: Bool) -> Self? {
        guard !transformed, scale > 0, scale.isFinite else { return nil }
        return Self(lowerY: (max(top, -margin) - origin) / scale,
                    upperY: (min(bottom, viewport + margin) - origin) / scale)
    }
}

/// Result of classifying a text edit for incremental paragraph / prefix reuse (`text_layout::edited`).
public enum TextEditKind: Sendable, Equatable {
    case unchanged
    case prefixAppend(commonUTF8Bytes: Int)
    case edit(prefixUTF8Bytes: Int, suffixUTF8Bytes: Int)
    case fullReplace

    /// True when `was != now` and shared prefix + suffix covers at least half of `max(was.utf8.count, now.utf8.count)` (`text_layout::edited`).
    public var isEdit: Bool {
        switch self {
        case .prefixAppend, .edit:
            return true
        case .unchanged, .fullReplace:
            return false
        }
    }
}

public enum TextLayoutRebreak {
    /// Classifies an edit from `was` to `now` (`text_layout::edited`).
    public static func edited(was: String, now: String) -> TextEditKind {
        if was == now {
            return .unchanged
        }
        let a = Array(was.utf8)
        let b = Array(now.utf8)
        let minLen = min(a.count, b.count)
        var prefix = 0
        while prefix < minLen && a[prefix] == b[prefix] {
            prefix += 1
        }
        let maxSuffix = min(a.count - prefix, b.count - prefix)
        var suffix = 0
        while suffix < maxSuffix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        guard 2 * (prefix + suffix) >= max(a.count, b.count) else {
            return .fullReplace
        }
        if suffix == 0 && prefix == a.count {
            return .prefixAppend(commonUTF8Bytes: prefix)
        }
        return .edit(prefixUTF8Bytes: prefix, suffixUTF8Bytes: suffix)
    }
}

/// Key identifying the font/shaping attributes of a text run independent of wrap width (`text::ShapeKey`).
public struct TextShapeKey: Hashable, Sendable {
    private var textKey: TextUTF8Key
    public var authText: String {
        get { textKey.source }
        set { textKey = TextUTF8Key(newValue) }
    }
    public var spans: [TextSpan]?
    public var pills: [PillChip]
    public var style: TextStyle
    private let inheritedSmoothing: FontSmoothing
    private var scaleBits: UInt32
    public var scale100: Int {
        get { Int((Float(bitPattern: scaleBits) * 100).rounded()) }
        set { scaleBits = (Float(newValue) / 100).bitPattern }
    }
    public var fontEpoch: UInt64
    public var languageTag: String?
    public var ellipsisMaxWKey: Int
    /// An idle measurement can keep a second line break without replacing a mounted width.
    private var preparedWidth: UInt32?
    internal func prepared(at width: Float?) -> Self {
        var key = self
        key.preparedWidth = (width ?? .infinity).bitPattern
        return key
    }

    internal var unpreparedKey: Self {
        var key = self
        key.preparedWidth = nil
        return key
    }

    internal var hasPreparedWidth: Bool { preparedWidth != nil }
    /// Whether this layout breaks `text-wrap-style: pretty` (`#882`); a pretty and a greedy layout of
    /// the same text never share an entry (upstream folds `pretty` into `hash::break_key`).
    public var pretty: Bool

    public init(
        authText: String,
        spans: [TextSpan]?,
        pills: [PillChip],
        style: TextStyle,
        pixelScale: Float,
        fontEpoch: UInt64,
        languageTag: String?,
        maxWidth: Float?,
        pretty: Bool = false
    ) {
        self.init(authText: authText, spans: spans, pills: pills, style: style, pixelScale: pixelScale,
                  fontEpoch: fontEpoch, languageTag: languageTag, maxWidth: maxWidth, pretty: pretty,
                  defaultSmoothing: .platformDefault)
    }

    public init(
        authText: String,
        spans: [TextSpan]?,
        pills: [PillChip],
        style: TextStyle,
        pixelScale: Float,
        fontEpoch: UInt64,
        languageTag: String?,
        maxWidth: Float?,
        pretty: Bool = false,
        defaultSmoothing: FontSmoothing
    ) {
        self.textKey = TextUTF8Key(authText)
        self.spans = spans
        self.pills = pills
        self.style = style
        self.inheritedSmoothing = style.fontSmoothing == .systemDefault ? defaultSmoothing : .systemDefault
        self.scaleBits = max(1.0, pixelScale).bitPattern
        self.fontEpoch = fontEpoch
        self.languageTag = languageTag
        self.ellipsisMaxWKey = (style.wrap == .ellipsis)
            ? (maxWidth.map { Int(($0 * 2.0).rounded()) } ?? -1)
            : -1
        self.pretty = Self.layoutPretty(pretty, style: style)
    }

    /// Keep the authored style on the layout while including its actual mask rasterizer in the cache key.
    var rasterStyle: TextStyle {
        var result = style
        if result.fontSmoothing == .systemDefault { result.fontSmoothing = inheritedSmoothing }
        return result
    }

    func usesSmoothing(_ mode: FontSmoothing) -> Bool {
        style.fontSmoothing != .systemDefault || inheritedSmoothing == mode
    }

    /// Pretty wrapping re-breaks only plainly wrapped, unclamped, unjustified proportional text
    /// (`text.rs::layout_keyed`: `pretty && max_width.is_some() && !mono`); `wrapAnywhere` text
    /// is scored too (`#933`), a paragraph with a word broken inside keeping its greedy lines. Width-independent so a
    /// retained layout keeps its pretty setting across `text_rebreak` width changes; a `nil`
    /// width never wraps, so `pretty` is inert there.
    public static func layoutPretty(_ pretty: Bool, style: TextStyle) -> Bool {
        pretty
            && style.wrap == .wrap
            && style.align != .justified
            && style.maxLines == 0
            && style.elide == .end
            && !style.family.isMonospace
    }
}

internal final class TextPreparedShape: @unchecked Sendable {
    let authText: String
    let shapedText: String
    let style: TextStyle
    let scale: Float
    let lhPt: Float
    let lhPx: Float
    var markerMap: ShapedText.MarkerMap
    let preparedPills: [TextSystem.PreparedPill]
    let spanPalette: [Color]
    let decoratedRanges: [TextSystem.DecoratedRange]
    /// Inline code runs whose boxes may grow their lines (`#983`).
    let spanBoxes: [TextSystem.InlineSpanBox]
    #if canImport(CoreText) && canImport(CoreGraphics)
    var utf8AtUTF16: [Int]?
    let baseFont: CTFont
    let baseAscentPx: CGFloat
    let baseDescentPx: CGFloat
    let attrStr: CFAttributedString
    let typesetter: CTTypesetter
    #endif
    let estimatedBytes: Int
    /// Layout commit (`TextSystem.layoutCommitSeq`) this shape was last used in through the
    /// typesetter cache; mutated only under `TextSystem.lock` (`#905` rest eviction).
    internal var lastUsedCommit: UInt64 = 0

    #if canImport(CoreText) && canImport(CoreGraphics)
    init(
        authText: String,
        shapedText: String,
        style: TextStyle,
        scale: Float,
        lhPt: Float,
        lhPx: Float,
        markerMap: ShapedText.MarkerMap,
        preparedPills: [TextSystem.PreparedPill],
        spanPalette: [Color],
        decoratedRanges: [TextSystem.DecoratedRange],
        baseFont: CTFont,
        baseAscentPx: CGFloat,
        baseDescentPx: CGFloat,
        attrStr: CFAttributedString,
        typesetter: CTTypesetter,
        spanBoxes: [TextSystem.InlineSpanBox] = []
    ) {
        self.spanBoxes = spanBoxes
        self.authText = authText
        self.shapedText = shapedText
        self.style = style
        self.scale = scale
        self.lhPt = lhPt
        self.lhPx = lhPx
        self.markerMap = markerMap
        self.preparedPills = preparedPills
        self.spanPalette = spanPalette
        self.decoratedRanges = decoratedRanges
        self.baseFont = baseFont
        self.baseAscentPx = baseAscentPx
        self.baseDescentPx = baseDescentPx
        self.attrStr = attrStr
        self.typesetter = typesetter
        self.estimatedBytes = max(128, authText.utf8.count * 24 + preparedPills.count * 64 + decoratedRanges.count * 32)
    }
    #else
    init(
        authText: String,
        shapedText: String,
        style: TextStyle,
        scale: Float,
        lhPt: Float,
        lhPx: Float,
        markerMap: ShapedText.MarkerMap,
        preparedPills: [TextSystem.PreparedPill],
        spanPalette: [Color],
        decoratedRanges: [TextSystem.DecoratedRange],
        spanBoxes: [TextSystem.InlineSpanBox] = []
    ) {
        self.spanBoxes = spanBoxes
        self.authText = authText
        self.shapedText = shapedText
        self.style = style
        self.scale = scale
        self.lhPt = lhPt
        self.lhPx = lhPx
        self.markerMap = markerMap
        self.preparedPills = preparedPills
        self.spanPalette = spanPalette
        self.decoratedRanges = decoratedRanges
        self.estimatedBytes = max(128, authText.utf8.count * 24 + preparedPills.count * 64 + decoratedRanges.count * 32)
    }
    #endif
}

/// Reference-counted laid-out text box that supports CoW re-breaking when uniquely owned
/// (`Rc<TextLayoutBox>` + `Rc::make_mut` parity for `text_rebreak`).
public final class TextLayoutBox: @unchecked Sendable {
    public let shapeKey: TextShapeKey
    public let authText: String
    public let spans: [TextSpan]?
    public let pills: [PillChip]
    public let style: TextStyle
    public let pixelScale: Float
    public var maxWidth: Float?
    public var shaped: ShapedText
    public var hasGlyphs: Bool
    internal let prepared: TextPreparedShape?
    internal var lastUsedCommit: UInt64 = 0
    /// The idle pass that introduced this layout. Ordinary layouts have no pass.
    internal var preparedPass: UInt64?
    internal var preparedRunCells: TextRunCellLayout?
    /// A partial paint is owned by its measured layout, independent of complete glyph replays.
    internal var rasterWindow: TextRasterWindow?
    internal var windowPaint: (window: TextRasterWindow, glide: Vec2, resets: UInt64, box: TextLayoutBox)?
    #if canImport(CRuneDesktopText) && !canImport(CoreText)
    internal var desktopRasterLayout: DesktopRasterLayout?
    #endif
    // Page recycling invalidates UVs in a cached desktop text layout.
    internal var desktopAtlasResets: UInt64?
    internal var desktopPages: Set<UInt16> = []
    /// A by-paragraph field's paragraphs (`TextLayout::Paragraphs`), whose stacked lines `shaped`
    /// holds; nil for one layout (`TextLayout::Single`).
    internal var paragraphs: ParagraphLayout? = nil

    public var estimatedBytes: Int {
        let partial = windowPaint?.box.shaped
        let partialBytes = (partial?.glyphs.count ?? 0) * MemoryLayout<PositionedGlyph>.stride
            + (partial?.lineGlyphRanges.count ?? 0) * MemoryLayout<Range<Int>>.stride
        let layoutBytes = partialBytes + (prepared?.estimatedBytes ?? max(128, authText.utf8.count * 16))
            + shaped.glyphs.count * MemoryLayout<PositionedGlyph>.stride
            + shaped.lineCount * 48
        #if canImport(CRuneDesktopText) && !canImport(CoreText)
        return layoutBytes + (shaped.desktopRestingText?.retainedGlyphBytes ?? 0) + (partial?.desktopRestingText?.retainedGlyphBytes ?? 0)
        #else
        return layoutBytes
        #endif
    }

    internal init(
        shapeKey: TextShapeKey,
        authText: String,
        spans: [TextSpan]?,
        pills: [PillChip],
        style: TextStyle,
        pixelScale: Float,
        maxWidth: Float?,
        shaped: ShapedText,
        hasGlyphs: Bool,
        prepared: TextPreparedShape?
    ) {
        self.shapeKey = shapeKey
        self.authText = authText
        self.spans = spans
        self.pills = pills
        self.style = style
        self.pixelScale = pixelScale
        self.maxWidth = maxWidth
        self.shaped = shaped
        self.hasGlyphs = hasGlyphs
        self.prepared = prepared
    }

    public func clone() -> TextLayoutBox {
        let out = TextLayoutBox(
            shapeKey: shapeKey,
            authText: authText,
            spans: spans,
            pills: pills,
            style: style,
            pixelScale: pixelScale,
            maxWidth: maxWidth,
            shaped: shaped,
            hasGlyphs: hasGlyphs,
            prepared: prepared
        )
        out.rasterWindow = rasterWindow
        out.desktopAtlasResets = desktopAtlasResets
        out.desktopPages = desktopPages
        out.preparedPass = preparedPass
        out.preparedRunCells = preparedRunCells
        out.paragraphs = paragraphs
        return out
    }
}

/// Cache key for flattened band-culled glyph quads (`glyph_cache.rs`).
public struct GlyphReplayKey: Hashable, Sendable {
    public var shapeKey: TextShapeKey
    public var maxWidthHalfPt: Int
    public var glideBinX: UInt8
    public var glideBinY: UInt8

    public init(
        shapeKey: TextShapeKey,
        maxWidth: Float?,
        glidePx: Vec2
    ) {
        self.shapeKey = shapeKey
        self.maxWidthHalfPt = maxWidth.map { Int(($0 * 2.0).rounded()) } ?? -1
        if glidePx == .zero {
            self.glideBinX = 0
            self.glideBinY = 0
        } else {
            let qx = Int((glidePx.x * 4.0).rounded())
            let qy = Int((glidePx.y * 4.0).rounded())
            self.glideBinX = UInt8(truncatingIfNeeded: ((qx % 4) + 4) % 4)
            self.glideBinY = UInt8(truncatingIfNeeded: ((qy % 4) + 4) % 4)
        }
    }
}

/// Bounded flattened glyph cache supporting O(1) viewport-band line slicing (`glyph_cache.rs`).
public final class GlyphReplayCache: @unchecked Sendable {
    public static let maxBytes: Int = 8 << 20
    public static let maxEntries: Int = 4096
    public static let entryBytes: Int = 2 << 20

    private struct Entry {
        var glyphs: [PositionedGlyph]
        var lineGlyphRanges: [Range<Int>]
        var lineHeight: Float
        var estimatedBytes: Int
        var lastUsedFrame: UInt64
    }

    private let lock = NSLock()
    private var entries: [GlyphReplayKey: Entry] = [:]
    private var frameSeq: UInt64 = 0
    private var atlasResets: UInt64 = 0
    private var _flattened: Int = 0
    private var _totalBytes: Int = 0

    public init() {}

    /// Total number of glyph flattening passes cached since creation (`GlyphCache::flattened`).
    public var flattened: Int {
        lock.withLock { _flattened }
    }

    /// Number of currently cached layout glyph entries (`GlyphCache::len`).
    public var len: Int {
        lock.withLock { entries.count }
    }

    public var totalBytes: Int {
        lock.withLock { _totalBytes }
    }

    public func beginFrame() {
        lock.lock()
        frameSeq &+= 1
        lock.unlock()
    }

    public func forget(_ key: GlyphReplayKey) {
        lock.lock()
        if let removed = entries.removeValue(forKey: key) {
            _totalBytes = max(0, _totalBytes - removed.estimatedBytes)
        }
        lock.unlock()
    }

    public func forget(shapeKey: TextShapeKey) {
        lock.lock()
        let doomed = entries.keys.filter { $0.shapeKey == shapeKey }
        for k in doomed {
            if let removed = entries.removeValue(forKey: k) {
                _totalBytes = max(0, _totalBytes - removed.estimatedBytes)
            }
        }
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        _totalBytes = 0
        lock.unlock()
    }

    /// Returns positioned glyphs whose lines overlap `[bandTopPt, bandBottomPt]` in local points.
    /// Builds and caches the flattened glyph stream once when `keep == .cached` and size <= `entryBytes`.
    /// `.owned` (a gliding layout whose glyphs carry this frame's sub-pixel glide) and `.secret` are never cached.
    public func glyphsInBandCached(
        key: GlyphReplayKey,
        keep: TextKeep,
        bandTopPt: Float,
        bandBottomPt: Float,
        build: () -> (glyphs: [PositionedGlyph], lineGlyphRanges: [Range<Int>], lineHeight: Float)
    ) -> ArraySlice<PositionedGlyph> {
        glyphsInBandCached(key: key, keep: keep, bandTopPt: bandTopPt, bandBottomPt: bandBottomPt,
                           sinceAtlasResets: nil, build: build)
    }

    internal func glyphsInBandCached(
        key: GlyphReplayKey,
        keep: TextKeep,
        bandTopPt: Float,
        bandBottomPt: Float,
        sinceAtlasResets resets: UInt64?,
        build: () -> (glyphs: [PositionedGlyph], lineGlyphRanges: [Range<Int>], lineHeight: Float)
    ) -> ArraySlice<PositionedGlyph> {
        guard keep == .cached else {
            let built = build()
            return Self.sliceInBand(
                glyphs: built.glyphs,
                lineGlyphRanges: built.lineGlyphRanges,
                lineHeight: built.lineHeight,
                bandTopPt: bandTopPt,
                bandBottomPt: bandBottomPt
            )
        }

        lock.lock()
        let generation = resets ?? atlasResets
        if generation > atlasResets {
            // The atlas can recycle a page between two draws of the same shape.
            entries.removeAll(keepingCapacity: true)
            _totalBytes = 0
            atlasResets = generation
        }
        if generation == atlasResets, var hit = entries[key] {
            hit.lastUsedFrame = frameSeq
            entries[key] = hit
            lock.unlock()
            return Self.sliceInBand(
                glyphs: hit.glyphs,
                lineGlyphRanges: hit.lineGlyphRanges,
                lineHeight: hit.lineHeight,
                bandTopPt: bandTopPt,
                bandBottomPt: bandBottomPt
            )
        }
        lock.unlock()

        let built = build()
        let bytes = built.glyphs.count * MemoryLayout<PositionedGlyph>.stride
            + built.lineGlyphRanges.count * MemoryLayout<Range<Int>>.stride

        if bytes <= Self.entryBytes {
            lock.lock()
            if generation == atlasResets, entries[key] == nil {
                while (entries.count >= Self.maxEntries || _totalBytes + bytes > Self.maxBytes),
                      let oldest = entries.min(by: { $0.value.lastUsedFrame < $1.value.lastUsedFrame })?.key {
                    if let removed = entries.removeValue(forKey: oldest) {
                        _totalBytes = max(0, _totalBytes - removed.estimatedBytes)
                    }
                }
                entries[key] = Entry(
                    glyphs: built.glyphs,
                    lineGlyphRanges: built.lineGlyphRanges,
                    lineHeight: built.lineHeight,
                    estimatedBytes: bytes,
                    lastUsedFrame: frameSeq
                )
                _totalBytes += bytes
                _flattened += 1
            }
            lock.unlock()
        }

        return Self.sliceInBand(
            glyphs: built.glyphs,
            lineGlyphRanges: built.lineGlyphRanges,
            lineHeight: built.lineHeight,
            bandTopPt: bandTopPt,
            bandBottomPt: bandBottomPt
        )
    }

    private static func sliceInBand(
        glyphs: [PositionedGlyph],
        lineGlyphRanges: [Range<Int>],
        lineHeight: Float,
        bandTopPt: Float,
        bandBottomPt: Float
    ) -> ArraySlice<PositionedGlyph> {
        guard !glyphs.isEmpty else { return [] }
        let nLines = lineGlyphRanges.count
        guard nLines > 0, lineHeight > 0 else {
            return glyphs[...]
        }
        if bandBottomPt <= 0 {
            return []
        }
        let totalH = Float(nLines) * lineHeight
        if bandTopPt >= totalH {
            return []
        }
        let lo = max(0, min(nLines, Int(floorf(max(0, bandTopPt) / lineHeight))))
        let hi = max(lo, min(nLines, Int(ceilf(min(totalH, bandBottomPt) / lineHeight))))
        guard lo < hi else { return [] }
        let startIdx = max(0, min(glyphs.count, lineGlyphRanges[lo].lowerBound))
        let endIdx = max(startIdx, min(glyphs.count, lineGlyphRanges[hi - 1].upperBound))
        return glyphs[startIdx..<endIdx]
    }
}
