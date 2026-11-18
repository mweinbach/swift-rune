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

#if os(WASI) && RUNE_BROWSER_TEXT
internal final class BrowserLabelDecorations {
    var backgrounds: [(SIMD4<Float>, Color)] = []
    var underlines: [SIMD4<Float>] = []
    var strikethroughs: [SIMD4<Float>] = []
    var underlineEnds: [Float] = []

    func apply(to shaped: inout ShapedText) {
        shaped.backgrounds = backgrounds
        shaped.underlines = underlines
        shaped.strikethroughs = strikethroughs
        shaped.underlineLineEndsPt = underlineEnds
    }
}
#endif

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

extension TextSpan {
    /// The same font, decoration geometry and line breaking apply throughout a foreground-only run.
    var affectsLayout: Bool {
        !text.isEmpty && (weight != nil || italic || monospace || size != nil || background != nil
            || underline || strikethrough)
    }

    static func layoutSpans(_ spans: [TextSpan]?) -> [TextSpan]? {
        guard let spans, spans.contains(where: \.affectsLayout) else { return nil }
        var result: [TextSpan] = []
        var plain = ""
        lazy var hasInlineMono = spans.contains { $0.monospace && !$0.text.isEmpty }
        for span in spans where !span.text.isEmpty {
            if span.affectsLayout {
                if !plain.isEmpty {
                    result.append(TextSpan(plain))
                    plain = ""
                }
                // Flattened rich text splits even the enclosing font range at syntax-color edges.
                // Keep decoration edges and smaller padding spans next to inline code intact.
                if result.last?.sharesFont(with: span) == true && (span.size == nil || span.monospace || !hasInlineMono) {
                    result[result.count - 1].text.append(span.text)
                } else {
                    var layout = span
                    layout.color = nil
                    result.append(layout)
                }
            } else {
                plain.append(span.text)
            }
        }
        if !plain.isEmpty { result.append(TextSpan(plain)) }
        return result
    }

    private func sharesFont(with other: TextSpan) -> Bool {
        background == nil && other.background == nil && !underline && !other.underline
            && !strikethrough && !other.strikethrough && weight == other.weight && size == other.size
            && italic == other.italic && monospace == other.monospace
    }
}

/// Foreground spans are ordered in logical UTF-8 coordinates. The glyph order can be visual (RTL).
struct TextSpanInkMap: Sendable {
    private var ranges: [(bytes: Range<Int>, color: Color)] = []

    init(_ spans: [TextSpan]?) {
        guard let spans else { return }
        var byte = 0
        for span in spans {
            let end = byte + span.text.utf8.count
            if let color = span.color, end > byte { ranges.append((byte..<end, color)) }
            byte = end
        }
    }

    var isEmpty: Bool { ranges.isEmpty }

    #if os(Linux)
    /// Native coverage can stay in its measured tiles when the entire row has one foreground.
    func varies(in bytes: Range<Int>) -> Bool {
        guard !bytes.isEmpty else { return false }
        var index = rangeIndex(at: bytes.lowerBound)
        guard index < ranges.count else { return false }
        if ranges[index].bytes.lowerBound > bytes.lowerBound {
            return ranges[index].bytes.lowerBound < bytes.upperBound
        }
        while ranges[index].bytes.upperBound < bytes.upperBound {
            let next = index + 1
            guard next < ranges.count, ranges[next].bytes.lowerBound == ranges[index].bytes.upperBound,
                  ranges[next].color == ranges[index].color else { return true }
            index = next
        }
        return false
    }
    #endif

    func drawn(in cut: TextElision) -> Self {
        var result = Self(nil)
        for run in ranges {
            let bytes = cut.mark(run.bytes.lowerBound, run.bytes.upperBound, isLink: false)
            if !bytes.isEmpty { result.ranges.append((bytes, run.color)) }
        }
        return result
    }

    private func rangeIndex(at byte: Int) -> Int {
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if byte >= ranges[mid].bytes.upperBound { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func color(at byte: Int) -> Color? {
        let index = rangeIndex(at: byte)
        guard index < ranges.count, byte >= ranges[index].bytes.lowerBound else { return nil }
        return ranges[index].color
    }

    func color(at byte: Int, cursor: inout Int) -> Color? {
        if cursor > 0 && byte < ranges[cursor - 1].bytes.upperBound {
            cursor = rangeIndex(at: byte)
        } else if cursor < ranges.count && byte >= ranges[cursor].bytes.upperBound {
            cursor += 1
            if cursor < ranges.count && byte >= ranges[cursor].bytes.upperBound { cursor = rangeIndex(at: byte) }
        }
        guard cursor < ranges.count, byte >= ranges[cursor].bytes.lowerBound else { return nil }
        return ranges[cursor].color
    }
}

extension ShapedText {
    var requestedInkBucket: UInt8? {
        #if canImport(CoreText) && canImport(CoreGraphics)
        return glyphs.isEmpty ? nil : GlyphAtlas.baseInkBucket
        #else
        return nil
        #endif
    }

    func glyphPlacementsAreResident(in atlas: GlyphAtlas) -> Bool {
        #if canImport(CoreText) && canImport(CoreGraphics)
        return glyphPlacements?.retainSource(in: atlas) ?? glyphs.isEmpty
        #else
        return true
        #endif
    }

    func foregroundMasksAreResident(in atlas: GlyphAtlas) -> Bool {
        #if os(Linux)
        guard let owned = desktopRestingText?.ownedPages else { return true }
        return atlas.retainPages(owned.pages, since: owned.resets)
        #else
        return scopedInkBucket == nil || glyphPlacementsAreResident(in: atlas)
        #endif
    }

    /// Preserve the shaped lines while changing the mask and bearing for a different paint scope.
    mutating func applyScopedGlyphMasks(in atlas: GlyphAtlas) {
        #if canImport(CoreText) && canImport(CoreGraphics)
        let scope = GlyphAtlas.baseInkBucket
        guard !glyphs.isEmpty, scope != nil || scopedInkBucket != nil else { return }
        let base = scope ?? 0
        scopedInkBucket = scope
        hasInitialSpanMasks = false
        let generation = atlas.resets
        var changed = false
        var lastColor: Color?
        var lastBucket: UInt8?
        for index in glyphs.indices where glyphs[index].usesInkDilation {
            let source = glyphs[index]
            let ink = scope == nil ? nil : source.color
            if lastColor != ink {
                lastColor = ink
                lastBucket = lastColor.flatMap { GlyphAtlas.inkBucket(SIMD4($0.r, $0.g, $0.b, $0.a), encoded: false) }
            }
            let (mask, rect) = atlas.outlineInk(source, rect: source.rect, bucket: lastBucket ?? base)
            guard mask.classicInk?.source.bucket != source.classicInk?.source.bucket
                || mask.outlineGroup !== source.outlineGroup || mask.uv != source.uv
                || mask.atlasPage != source.atlasPage || rect != source.rect else { continue }
            var placed = mask
            placed.rect = rect
            glyphs[index] = placed
            if glyphPens.indices.contains(index),
               let variant = mask.classicInk?.source ?? mask.outlineGroup?.inkVariant,
               let size = mask.classicInk?.size ?? mask.outlineGroup?.size {
                glyphPens[index].bearingX = variant.bearing.x
                glyphPens[index].maskTexels = UInt32(size.x * size.y)
            }
            changed = true
        }
        if changed {
            glyphPlacements = TextBoxGeometry.GlyphPlacements(glyphs: glyphs, since: generation)
        }
        #endif
    }

    func applyingSpanInks(_ spans: [TextSpan]?, using originalInks: TextSpanInkMap? = nil) -> ShapedText {
        let source = originalInks ?? TextSpanInkMap(spans)
        let inks = elided.map(source.drawn(in:)) ?? source
        #if os(Linux) && canImport(CRuneDesktopText)
        return applyingOwnedForeground(inks, byteOffset: 0)
        #else
        var result = self
        var cursor = 0
        for index in result.glyphs.indices {
            let color = inks.color(at: result.glyphs[index].utf8Offset, cursor: &cursor)
            if result.glyphs[index].color != color { result.glyphs[index].color = color }
        }
        #if canImport(CRuneDesktopText) && !canImport(CoreText)
        result.desktopRestingText = desktopRestingText?.applyingSpanInks(inkAtByte: inks.color(at:))
        #endif
        return result
        #endif
    }
}

/// Key identifying the font/shaping attributes of a text run independent of wrap width (`text::ShapeKey`).
public struct TextShapeKey: Hashable, Sendable {
    private var textKey: TextUTF8Key
    public var authText: String {
        get { textKey.source }
        set { textKey = TextUTF8Key(newValue) }
    }
    // Layout, retained memo leaves and glyph caches share these immutable, potentially rich
    // attributes. Copying a shape key preserves their storage and previously computed hash.
    private final class Attributes: Hashable, Sendable {
        let spans: [TextSpan]?
        let layoutSpans: [TextSpan]?
        let pills: [PillChip]
        let style: TextStyle
        let fingerprint: Int

        init(_ spans: [TextSpan]?, _ pills: [PillChip], _ style: TextStyle) {
            self.spans = spans
            self.layoutSpans = TextSpan.layoutSpans(spans)
            self.pills = pills
            self.style = style
            var hash = Hasher()
            hash.combine(layoutSpans)
            hash.combine(pills)
            hash.combine(style)
            fingerprint = hash.finalize()
        }

        init(paintSpans: [TextSpan]?, geometry: Attributes) {
            self.spans = paintSpans
            self.layoutSpans = geometry.layoutSpans
            self.pills = geometry.pills
            self.style = geometry.style
            self.fingerprint = geometry.fingerprint
        }

        func hash(into hasher: inout Hasher) { hasher.combine(fingerprint) }

        static func == (lhs: Attributes, rhs: Attributes) -> Bool {
            lhs === rhs || (lhs.fingerprint == rhs.fingerprint && lhs.style == rhs.style
                && lhs.layoutSpans == rhs.layoutSpans && lhs.pills == rhs.pills)
        }
    }

    private var attributes: Attributes
    public var spans: [TextSpan]? {
        _read { yield attributes.spans }
        set { attributes = Attributes(newValue, pills, style) }
    }
    var layoutSpans: [TextSpan]? { attributes.layoutSpans }

    func matchesLayoutSpans(_ spans: [TextSpan]?) -> Bool {
        attributes.spans == spans || attributes.layoutSpans == TextSpan.layoutSpans(spans)
    }

    var layoutOnly: Self {
        guard spans != layoutSpans else { return self }
        return withPaintSpans(layoutSpans)
    }

    /// The caller has already verified that these spans share the current layout.
    func withPaintSpans(_ spans: [TextSpan]?) -> Self {
        var copy = self
        copy.attributes = Attributes(paintSpans: spans, geometry: attributes)
        return copy
    }

    public var pills: [PillChip] {
        _read { yield attributes.pills }
        set { attributes = Attributes(spans, newValue, style) }
    }
    public var style: TextStyle {
        _read { yield attributes.style }
        set { attributes = Attributes(spans, pills, newValue) }
    }
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
        self.attributes = Attributes(spans, pills, style)
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

/// Native paragraph shapes shared by a single measured view while Taffy probes several widths.
internal final class IntrinsicTextShapes {
    #if canImport(CRuneDesktopText) && !canImport(CoreText)
    var paragraphs: [TextShapeKey: ShapedText.DesktopParagraph] = [:]
    #endif
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
    let decoratedRanges: [TextSystem.DecoratedRange]
    /// Inline code runs whose boxes may grow their lines (`#983`).
    let spanBoxes: [TextSystem.InlineSpanBox]
    #if canImport(CoreText) && canImport(CoreGraphics)
    var utf8AtUTF16: [Int]?
    let baseFont: CTFont
    let baseAscentPx: CGFloat
    let baseDescentPx: CGFloat
    let attrStr: CFAttributedString
    let hasRunDelegates: Bool
    enum LineSource {
        case singleLine(CTLine)
        case typesetter(CTTypesetter)
    }
    let lineSource: LineSource
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
        decoratedRanges: [TextSystem.DecoratedRange],
        baseFont: CTFont,
        baseAscentPx: CGFloat,
        baseDescentPx: CGFloat,
        attrStr: CFAttributedString,
        hasRunDelegates: Bool,
        lineSource: LineSource,
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
        self.decoratedRanges = decoratedRanges
        self.baseFont = baseFont
        self.baseAscentPx = baseAscentPx
        self.baseDescentPx = baseDescentPx
        self.attrStr = attrStr
        self.hasRunDelegates = hasRunDelegates
        self.lineSource = lineSource
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
        self.decoratedRanges = decoratedRanges
        self.estimatedBytes = max(128, authText.utf8.count * 24 + preparedPills.count * 64 + decoratedRanges.count * 32)
    }
    #endif
}

/// Identifies the ordinary layout slots owned by a single text cache between clears.
internal final class TextLayoutCacheIdentity: Sendable {}

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
    public var shaped: ShapedText {
        didSet {
            recentPaint = nil
            #if os(WASI) && RUNE_BROWSER_TEXT
            browserPaint = nil
            #endif
        }
    }
    public var hasGlyphs: Bool {
        didSet {
            #if os(WASI) && RUNE_BROWSER_TEXT
            if hasGlyphs != oldValue { browserPaint = nil }
            #endif
        }
    }
    /// The pinned layout cache charges each entry by authored UTF-8 length.
    internal let cacheCost: Int
    internal let prepared: TextPreparedShape?
    internal var ordinaryCache: TextLayoutCacheIdentity?
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
    #if os(WASI) && RUNE_BROWSER_TEXT
    internal var browserPaint: (origin: DesktopTextLine.LabelOrigin, rgb: UInt32?, spans: GlyphPaintSpans, glyphs: [PositionedGlyph], decorations: BrowserLabelDecorations?, pages: Set<UInt16>, resets: UInt64, revision: UInt64)?
    #endif
    // Page recycling invalidates UVs in a cached desktop text layout.
    internal var desktopAtlasResets: UInt64?
    internal var desktopPages: Set<UInt16> = []
    /// A by-paragraph field's paragraphs (`TextLayout::Paragraphs`), whose stacked lines `shaped`
    /// holds; nil for one layout (`TextLayout::Single`).
    internal var paragraphs: ParagraphLayout? = nil

    public var estimatedBytes: Int {
        var bytes = (prepared?.estimatedBytes ?? max(128, authText.utf8.count * 16))
            + shaped.glyphs.count * MemoryLayout<PositionedGlyph>.stride + shaped.lineCount * 48
            + (recentPaint?.glyphBytes ?? 0)
        #if canImport(CRuneDesktopText) && !canImport(CoreText)
        bytes += shaped.desktopRestingText?.retainedGlyphBytes ?? 0
        #endif
        #if os(WASI) && RUNE_BROWSER_TEXT
        bytes += (browserPaint?.glyphs.count ?? 0) * MemoryLayout<PositionedGlyph>.stride
        if let decoration = browserPaint?.decorations {
            bytes += decoration.backgrounds.count * MemoryLayout<(SIMD4<Float>, Color)>.stride
            bytes += (decoration.underlines.count + decoration.strikethroughs.count) * MemoryLayout<SIMD4<Float>>.stride
            bytes += decoration.underlineEnds.count * MemoryLayout<Float>.stride
        }
        #endif
        if let partial = windowPaint?.box {
            bytes += partial.shaped.glyphs.count * MemoryLayout<PositionedGlyph>.stride
                + partial.shaped.lineGlyphRanges.count * MemoryLayout<Range<Int>>.stride
            #if canImport(CRuneDesktopText) && !canImport(CoreText)
            bytes += partial.shaped.desktopRestingText?.retainedGlyphBytes ?? 0
            #endif
        }
        return bytes
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
        self.cacheCost = ParagraphState.layoutCost(textBytes: authText.utf8.count)
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

    /// Keeps the original native layout alive while a mounted label presents its own syntax colors.
    private var spanInkGeometry: TextLayoutBox?
    private(set) var spanInks = TextSpanInkMap(nil)
    /// Keep the most recent glyph colors when its caller releases the box between frames.
    /// Only mounted boxes own the geometry. The snapshot never retains its owning box.
    final class SpanPaint {
        private let key: TextShapeKey
        private let shaped: ShapedText
        private let inks: TextSpanInkMap
        private weak var box: TextLayoutBox?

        init(_ box: TextLayoutBox) {
            self.key = box.shapeKey
            self.shaped = box.shaped
            self.inks = box.spanInks
            self.box = box
        }

        func view(
            of geometry: TextLayoutBox, spans: [TextSpan]?, bucket: UInt8? = nil, forMeasurement: Bool = false
        ) -> TextLayoutBox? {
            guard key.spans == spans, forMeasurement || shaped.scopedInkBucket == bucket else { return nil }
            if let box { return box }
            let painted = geometry.clone(key: key, shaped: shaped)
            painted.spanInks = inks
            painted.spanInkGeometry = geometry
            box = painted
            return painted
        }

        var glyphBytes: Int {
            inks.isEmpty && shaped.scopedInkBucket == nil ? 0 : shaped.glyphs.count * MemoryLayout<PositionedGlyph>.stride
        }
    }

    var recentPaint: SpanPaint?
    var cachedGeometry: TextLayoutBox { spanInkGeometry ?? self }

    func applyingSpanInks(_ spans: [TextSpan]?, atlas: GlyphAtlas? = nil) -> TextLayoutBox {
        let bucket = atlas == nil ? nil : shaped.requestedInkBucket
        if self.spans == spans, !shaped.hasInitialSpanMasks, shaped.scopedInkBucket == bucket { return self }
        let geometry = cachedGeometry
        if geometry.spans == spans, !geometry.shaped.hasInitialSpanMasks, geometry.shaped.scopedInkBucket == bucket { return geometry }
        let key = geometry.shapeKey.withPaintSpans(spans)
        let inks = TextSpanInkMap(spans)
        var shaped = inks.isEmpty ? geometry.shaped : geometry.shaped.applyingSpanInks(spans, using: inks)
        if let atlas {
            shaped.applyScopedGlyphMasks(in: atlas)
        }
        #if canImport(CoreText) && canImport(CoreGraphics)
        if atlas == nil, shaped.scopedInkBucket != nil {
            // A metrics-only view keeps the existing masks until paint supplies the current ink.
            shaped.hasInitialSpanMasks = true
        }
        #endif
        let out = geometry.clone(key: key, shaped: shaped)
        out.spanInks = inks
        out.spanInkGeometry = geometry
        return out
    }

    public func clone() -> TextLayoutBox {
        let out = clone(key: shapeKey, shaped: shaped)
        out.spanInkGeometry = spanInkGeometry
        out.spanInks = spanInks
        return out
    }

    private func clone(key: TextShapeKey, shaped: ShapedText) -> TextLayoutBox {
        let out = TextLayoutBox(
            shapeKey: key,
            authText: authText,
            spans: key.spans,
            pills: pills,
            style: style,
            pixelScale: pixelScale,
            maxWidth: maxWidth,
            shaped: shaped,
            hasGlyphs: hasGlyphs,
            prepared: prepared
        )
        out.rasterWindow = rasterWindow
        #if canImport(CRuneDesktopText) && !canImport(CoreText)
        out.desktopRasterLayout = desktopRasterLayout
        #endif
        out.desktopAtlasResets = desktopAtlasResets
        out.desktopPages = desktopPages
        #if os(Linux) && canImport(CRuneDesktopText)
        if let owned = shaped.desktopRestingText?.ownedPages {
            // A projection may also carry neutral masks from unchanged lines.
            out.desktopAtlasResets = min(desktopAtlasResets ?? owned.resets, owned.resets)
            out.desktopPages = owned.pages
        }
        #endif
        out.preparedPass = preparedPass
        out.preparedRunCells = preparedRunCells
        out.paragraphs = paragraphs
        return out
    }
}

/// A flattened glyph or retained draw already has its authored foreground applied.
/// The shape key covers the text and metrics. Painting also depends on the color at each byte.
internal struct GlyphPaintSpans: Hashable, Sendable {
    private let spans: [TextSpan]

    init(_ spans: [TextSpan]?) { self.spans = spans ?? [] }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.spans.count == rhs.spans.count else { return false }
        return lhs.spans.withUnsafeBufferPointer { a in
            rhs.spans.withUnsafeBufferPointer { b in
                a.baseAddress == b.baseAddress || a.indices.allSatisfy {
                    a[$0].color == b[$0].color && a[$0].text.utf8.count == b[$0].text.utf8.count
                }
            }
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(spans.count)
        for span in spans {
            hasher.combine(span.text.utf8.count)
            hasher.combine(span.color)
        }
    }
}

/// Cache key for flattened band-culled glyph quads (`glyph_cache.rs`).
public struct GlyphReplayKey: Hashable, Sendable {
    public var shapeKey: TextShapeKey {
        didSet { inkSpans = GlyphPaintSpans(shapeKey.spans) }
    }
    private var inkSpans: GlyphPaintSpans
    private var scopedInkBucket: UInt8?
    public var maxWidthHalfPt: Int
    public var glideBinX: UInt8
    public var glideBinY: UInt8

    public init(
        shapeKey: TextShapeKey,
        maxWidth: Float?,
        glidePx: Vec2
    ) {
        self.init(shapeKey: shapeKey, spans: shapeKey.spans, maxWidth: maxWidth, glidePx: glidePx)
    }

    internal init(
        shapeKey: TextShapeKey,
        spans: [TextSpan]?,
        maxWidth: Float?,
        glidePx: Vec2,
        scopedInkBucket: UInt8? = nil
    ) {
        self.scopedInkBucket = scopedInkBucket
        self.shapeKey = shapeKey
        self.inkSpans = GlyphPaintSpans(spans)
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
