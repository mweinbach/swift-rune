import Foundation
#if canImport(simd)
import simd
#endif

// MARK: - 1. Line Metrics (`rune::text::line_metrics`)

/// Heights and stream-lag metrics from a laid-out `ShapedText` (`rune::text::line_metrics`).
public enum TextLineMetrics {
    /// Whole-line layout height in device pixels, at least one line (`line_metrics::layout_height`).
    public static func layoutHeight(layoutHeightPx: Float, style: TextStyle, scale: Float) -> Float {
        max(layoutHeightPx, style.resolvedLineHeight * scale).rounded(.up)
    }

    /// Spec layout height in device pixels: snapped to 1/64 px when `exact` is true, else whole pixels (`spec_height`).
    public static func specHeight(layoutHeightPx: Float, style: TextStyle, scale: Float, exact: Bool) -> Float {
        if !exact {
            return layoutHeight(layoutHeightPx: layoutHeightPx, style: style, scale: scale)
        }
        let h = max(layoutHeightPx, style.resolvedLineHeight * scale)
        return (h * 64.0).rounded() / 64.0
    }

    /// Fraction `[0, 1]` of the final line occupied by non-hanging ink advance (`last_line_fill`).
    public static func lastLineFill(lineAdvancePx: Float, hangingAdvancePx: Float, widthPx: Float) -> Float {
        ((lineAdvancePx - hangingAdvancePx) / max(widthPx, 1.0)).clamped01()
    }

    /// Height held back while the final line streams in, rounded to 1/64 pt (`stream_height_lag`).
    public static func streamHeightLag(
        lineCount: Int,
        lineHeightPx: Float,
        lineAdvancePx: Float,
        hangingAdvancePx: Float,
        widthPx: Float,
        scale: Float
    ) -> Float {
        guard lineCount > 0, scale > 0 else { return 0 }
        let cap: Float = (lineCount == 1) ? 0.52 : 0.82
        let fill = lastLineFill(lineAdvancePx: lineAdvancePx, hangingAdvancePx: hangingAdvancePx, widthPx: widthPx)
        let lag = (lineHeightPx / scale) * cap * (1.0 - fill)
        return (lag * 64.0).rounded() / 64.0
    }
}

private extension Float {
    func clamped01() -> Float { min(max(self, 0), 1) }
}

// MARK: - 2. Pixel-Edge Underlines & Decorations (`underline.rs`, `decorations.rs`)

/// Whole-pixel underline edge helpers (`rune::text::underline`) and span background radii (`decorations.rs`).
public enum TextDecorations {
    /// Corner radius in points for rounded inline span backgrounds (`decorations::SPAN_RADIUS`).
    public static let spanRadius: Float = 4.0

    /// Whole device-pixel left and right underline edges (`underline::underline_edges`).
    /// Adjacent touching runs share edges, and a run reaching `lineEndPx` extends cleanly to box ceiling.
    public static func underlineEdges(lineEndPx: Float, originX: Float, startX: Float, endX: Float) -> (Float, Float) {
        let right = (endX >= lineEndPx - 0.01) ? (endX - 1e-3).rounded(.up) : endX.rounded()
        return ((originX + startX.rounded()).rounded(), (originX + right).rounded())
    }

    /// Merges adjacent background rects on the same line and expands each by `padding`.
    public static func mergedPaddedBackgrounds(
        _ items: [(rect: SIMD4<Float>, color: Color)],
        padding: Float
    ) -> [(rect: SIMD4<Float>, color: Color)] {
        guard !items.isEmpty else { return [] }
        var out: [(rect: SIMD4<Float>, color: Color)] = []
        for item in items {
            let expanded = SIMD4<Float>(
                item.rect.x - padding,
                item.rect.y,
                item.rect.z + padding * 2,
                item.rect.w
            )
            if let last = out.last,
               last.color == item.color,
               abs(last.rect.y - expanded.y) < 0.5,
               abs(last.rect.w - expanded.w) < 0.5,
               expanded.x <= last.rect.x + last.rect.z + padding * 2 + 0.5 {
                let x0 = min(last.rect.x, expanded.x)
                let x1 = max(last.rect.x + last.rect.z, expanded.x + expanded.z)
                out[out.count - 1].rect = SIMD4<Float>(x0, last.rect.y, x1 - x0, last.rect.w)
            } else {
                out.append((expanded, item.color))
            }
        }
        return out
    }
}

// MARK: - 3. LTR Isolation Units in Bidi Prose (`rune::text::ltr_units`)

/// Identifies inline left-to-right technical units (paths, URLs, flags, numbers, filenames)
/// inside RTL prose (`rune::text::ltr_units`).
public enum TextBidiUnits {
    private static let openChars: Set<Character> = ["(", "[", "{", "\"", "'", "«", "“", "‘", "<"]
    private static let closeChars: Set<Character> = [")", "]", "}", ">"]
    private static let endChars: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "\"", "'", "»", "”", "’", "،", "؛", "؟", "۔", "…", ">"]

    private static func pair(_ c: Character) -> Character {
        switch c {
        case "(": return ")"
        case "[": return "]"
        case "{": return "}"
        case "<": return ">"
        case ")": return "("
        case "]": return "["
        case "}": return "{"
        case ">": return "<"
        default: return c
        }
    }

    /// Returns UTF-8 byte ranges of LTR units inside `text` (`ltr_units::ltr_units`).
    public static func ltrUnits(in text: String) -> [Range<Int>] {
        var out: [Range<Int>] = []
        let utf8 = Array(text.utf8)
        var bytePos = 0
        var wordStart = 0

        for ch in text {
            let chBytes = ch.utf8.count
            if ch.isWhitespace {
                if wordStart < bytePos,
                   let slice = String(bytes: utf8[wordStart..<bytePos], encoding: .utf8),
                   let localRange = unitRange(in: slice) {
                    out.append((wordStart + localRange.lowerBound)..<(wordStart + localRange.upperBound))
                }
                wordStart = bytePos + chBytes
            }
            bytePos += chBytes
        }
        if wordStart < utf8.count,
           let slice = String(bytes: utf8[wordStart..<utf8.count], encoding: .utf8),
           let localRange = unitRange(in: slice) {
            out.append((wordStart + localRange.lowerBound)..<(wordStart + localRange.upperBound))
        }
        return out
    }

    private static func unitRange(in word: String) -> Range<Int>? {
        var startIdx = word.startIndex
        var endIdx = word.endIndex
        while startIdx < endIdx {
            let c = word[startIdx]
            let rest = word[word.index(after: startIdx)..<endIdx]
            let closesInside = (pair(c) != c) && rest.contains(pair(c))
            if openChars.contains(c) && !closesInside {
                startIdx = word.index(after: startIdx)
            } else {
                break
            }
        }
        while startIdx < endIdx {
            let prev = word.index(before: endIdx)
            let c = word[prev]
            let head = word[startIdx..<prev]
            let opensInside = head.contains(pair(c))
            if endChars.contains(c) && !(closeChars.contains(c) && opensInside) {
                endIdx = prev
            } else {
                break
            }
        }
        let core = String(word[startIdx..<endIdx])
        guard !core.isEmpty else { return nil }
        let ascii = core.utf8.allSatisfy { $0 < 0x80 }
        let hasAlnum = core.utf8.contains { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) }
        let hasSymbol = core.utf8.contains { !(($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)) }
        let isPath = (core.hasPrefix("/") || core.hasPrefix("~") || core.hasPrefix(".")) && (core.contains("/") || core.contains("\\")) || isDrivePath(core)
        let isNamed = (core.contains("/") || core.contains("\\")) && hasExtension(core)
        guard hasAlnum && ((ascii && hasSymbol) || (!ascii && (isPath || isNamed))) else {
            return nil
        }
        let byteStart = word[..<startIdx].utf8.count
        let byteEnd = word[..<endIdx].utf8.count
        return byteStart..<byteEnd
    }

    private static func isDrivePath(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return b.count > 3 && ((b[0] >= 65 && b[0] <= 90) || (b[0] >= 97 && b[0] <= 122)) && b[1] == 58 && (b[2] == 92 || b[2] == 47)
    }

    private static func hasExtension(_ s: String) -> Bool {
        guard let dot = s.lastIndex(of: ".") else { return false }
        let stem = s[..<dot]
        let ext = s[s.index(after: dot)...]
        return !stem.isEmpty && (1...8).contains(ext.count) && ext.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) }
    }
}

// MARK: - 4. Single-Line Grapheme Run Layout (`rune::text::run`)

/// A string shaped once as a single line for per-grapheme cell advance/kerning lookup (`rune::text::Run`).
public struct TextRun: Hashable, Sendable {
    public let text: String
    public let hash: UInt64

    public init(_ text: String) {
        self.text = text
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 {
            h ^= UInt64(b)
            h &*= 0x100000001b3
        }
        self.hash = h
    }
}

/// A shaped single-line `TextRun` with per-grapheme quantized x offsets (`rune::text::RunLayout`).
public struct RunLayout: Sendable {
    public struct GraphemeEntry: Equatable, Sendable {
        public var utf8Offset: Int
        public var xPx: Float
    }

    public let text: String
    public let scale: Float
    public let graphemes: [GraphemeEntry]
    public let totalWidthPx: Float
    internal let cellLayout: TextRunCellLayout?

    public init(text: String, scale: Float, graphemes: [GraphemeEntry], totalWidthPx: Float) {
        self.text = text
        self.scale = scale
        self.graphemes = graphemes
        self.totalWidthPx = totalWidthPx
        self.cellLayout = nil
    }

    internal init(text: String, scale: Float, graphemes: [GraphemeEntry], totalWidthPx: Float, cellLayout: TextRunCellLayout?) {
        self.text = text
        self.scale = scale
        self.graphemes = graphemes
        self.totalWidthPx = totalWidthPx
        self.cellLayout = cellLayout
    }

    /// Device-pixel x of the grapheme starting at UTF-8 byte `offset`.
    public func x(atUTF8Offset offset: Int) -> Float? {
        guard let i = graphemeIndex(atUTF8Offset: offset) else { return nil }
        return graphemes[i].xPx
    }

    /// Point advance width of the grapheme starting at UTF-8 byte `offset`.
    public func advance(atUTF8Offset offset: Int, scale: Float? = nil) -> Float? {
        guard let i = graphemeIndex(atUTF8Offset: offset), i + 1 < graphemes.count else { return nil }
        let s = max(scale ?? self.scale, 1.0)
        return max(0, (graphemes[i + 1].xPx - graphemes[i].xPx) / s)
    }

    private func graphemeIndex(atUTF8Offset offset: Int) -> Int? {
        guard graphemes.count >= 2 else { return nil }
        var lo = 0
        var hi = graphemes.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if graphemes[mid].utf8Offset < offset {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        guard lo + 1 < graphemes.count, graphemes[lo].utf8Offset == offset else { return nil }
        return lo
    }
}

extension TextSystem {
    /// Shapes `run` as one line and records per-grapheme x/advance boundaries (`TextSystem::run_layout`).
    public func runLayout(_ run: TextRun, style: TextStyle, scale: Float = 1.0) -> RunLayout {
        let s = max(scale, 1.0)
        var single = style
        single.wrap = .noWrap
        let shaped = shape(text: run.text, spans: nil, style: single, maxWidth: nil, pixelScale: s, emitGlyphs: false)
        var entries: [RunLayout.GraphemeEntry] = []
        var utf8Cursor = 0
        for ch in run.text {
            let xPt = caretRect(in: shaped, utf8Offset: utf8Cursor, pixelScale: s).x
            let xPx = (xPt * s * 64.0).rounded() / 64.0
            entries.append(RunLayout.GraphemeEntry(utf8Offset: utf8Cursor, xPx: xPx))
            utf8Cursor += ch.utf8.count
        }
        let endPx = (shaped.size.x * s - 1e-3).rounded(.up)
        entries.append(RunLayout.GraphemeEntry(utf8Offset: run.text.utf8.count, xPx: max(0, endPx)))
        let cellLayout = cachedRunCellLayout(run, style: single, pixelScale: s)
        return RunLayout(text: run.text, scale: s, graphemes: entries, totalWidthPx: max(0, endPx), cellLayout: cellLayout)
    }

    /// Glyph quads for the grapheme starting at UTF-8 byte `utf8Offset` of `run`, positioned
    /// with the run's top-left at `origin` in logical points (`glyph_emit.rs:104`).
    public func glyphsIn(
        run: RunLayout,
        at utf8Offset: Int,
        scale: Float = 1.0,
        origin: Vec2 = .zero
    ) -> [PositionedGlyph] {
        _ = scale // Run holds its scale; retained for Rust `glyphs_in` signature compatibility.
        return run.cellLayout?.glyphsIn(atByte: utf8Offset, using: self, originPt: origin) ?? []
    }
}

// MARK: - 5. ApplePipeline, SmoothingSupport, Subpixel Quantisation (`coretext_match`, `support`, `macos/smoothing`)

/// Which stages of CoreGraphics' glyph pipeline run (`rune::text::ApplePipeline`).
public struct ApplePipeline: Equatable, Hashable, Sendable {
    public var dilate: Bool
    public var flatten: Bool
    public var hint: Bool

    public init(dilate: Bool, flatten: Bool, hint: Bool) {
        self.dilate = dilate
        self.flatten = flatten
        self.hint = hint
    }

    public static let smoothed = ApplePipeline(dilate: true, flatten: true, hint: true)
    public static let unsmoothed = ApplePipeline(dilate: false, flatten: true, hint: true)
}

/// Platform capability for a `FontSmoothing` mode (`rune::text::SmoothingSupport`).
public enum SmoothingSupport: Equatable, Sendable {
    case yes
    case fallback(String)
    case no(String)
}

public enum TextCoreTextMatch {
    public static let phases: Float = 60.0

    /// CoreGraphics subpixel quantisation steps per device pixel (`quantisation_steps`).
    public static func quantisationSteps(ppem: Float) -> Float {
        guard ppem > 0 else { return 5.0 }
        return min(5.0, 1.0 + floorf((100.0 / 3.0) / ppem))
    }

    /// Quantised pixel origin and sixtieth-pixel phase (`0..<60`) (`coretext_match::glyph_x`).
    public static func glyphX(_ x: Float, ppem: Float) -> (pixel: Float, phase: UInt8) {
        let steps = quantisationSteps(ppem: ppem)
        let quantized = floorf(((x * 256.0).rounded() / 256.0) * steps) / steps
        let fx = floorf(quantized)
        let phase = ((quantized - fx) * steps).rounded()
        if phase >= steps {
            return (fx + 1.0, 0)
        }
        return (fx, UInt8(phase * (phases / steps)))
    }

    /// Browser page default smoothing (`coretext_match::browser_default`).
    public static func browserDefault(platform: String, touchPoints: UInt32) -> FontSmoothing {
        let isMac = platform.prefix(3).lowercased() == "mac"
        return (isMac && touchPoints <= 1) ? .on : .off
    }

    /// Coverage gamma exponent for non-Apple / non-smoothed text (`coverage_exponent`).
    public static func coverageExponent(mode: FontSmoothing, fill: [Float], apple: Bool, windows: Bool) -> Float {
        guard fill.count >= 4, fill[3] > 0 else { return 1.0 }
        let resolved = (mode == .systemDefault) ? FontSmoothing.classic : mode
        let directWrite = (resolved == .directWrite || resolved == .clearType) && windows
        let chromium = resolved.isChromiumOutline
        if (apple && !chromium) || directWrite || resolved == .on || resolved == .windfoil {
            return 1.0
        }
        let luma = ((0.2126 * fill[0] + 0.7152 * fill[1] + 0.0722 * fill[2]) / fill[3]).clamped01()
        return 1.12 + (0.45 - 1.12) * luma
    }
}

extension FontSmoothing {
    /// Every mode in the order a setting lists them (`FontSmoothing::ALL`).
    public static let all: [FontSmoothing] = [
        .windfoil,
        .windfoilChromium,
        .slug,
        .windfoilRgb,
        .hintedGpu,
        .hinted,
        .directWrite,
        .clearType,
        .on,
        .off,
    ]

    public static var classic: FontSmoothing {
        #if os(macOS)
        return .on
        #else
        return .off
        #endif
    }

    public static var platformDefault: FontSmoothing {
        #if os(macOS)
        return .on
        #else
        return .windfoilChromium
        #endif
    }

    public var isOutlineMode: Bool {
        switch self {
        case .windfoil, .windfoilChromium, .slug, .hintedGpu, .hinted, .windfoilRgb:
            return true
        case .on, .off, .directWrite, .clearType, .systemDefault:
            return false
        }
    }

    public var isChromiumOutline: Bool {
        switch self {
        case .windfoilChromium, .slug, .hintedGpu, .hinted, .windfoilRgb:
            return true
        case .windfoil, .on, .off, .directWrite, .clearType, .systemDefault:
            return false
        }
    }

    public var isLCD: Bool {
        self == .windfoilRgb || self == .clearType
    }

    public func drawn(lcdOK: Bool) -> FontSmoothing {
        if !lcdOK {
            if self == .windfoilRgb { return .windfoilChromium }
            if self == .clearType { return .directWrite }
        }
        return self
    }

    public var pipeline: ApplePipeline {
        isEnabled ? .smoothed : .unsmoothed
    }

    public func support(
        outlinesAvailable: Bool = true,
        dualSourceSupported: Bool = true,
        isWindows: Bool = {
            #if os(Windows)
            return true
            #else
            return false
            #endif
        }()
    ) -> SmoothingSupport {
        let resolved = (self == .systemDefault) ? Self.classic : self
        let outlinesOut = !outlinesAvailable
        let noDual = !dualSourceSupported
        switch resolved {
        case .directWrite where !isWindows:
            return .no("DirectWrite is Windows only")
        case .clearType where !isWindows:
            return .no("ClearType is Windows only")
        case .clearType where noDual,
             .windfoilRgb where noDual || outlinesOut:
            return .fallback("This GPU can't blend subpixel text (dual-source blending), so it draws grayscale")
        case .slug where outlinesOut:
            return .no("Slug draws on the GPU, and this renderer can't build its shader")
        default:
            if outlinesOut && resolved.isOutlineMode {
                return .fallback("This renderer can't build the outline shader: the CPU fills the same coverage, and moving text scales its masks")
            }
            return .yes
        }
    }
}

// MARK: - 6. Free Measurement API (`measure.rs`) & RichLayoutOptions (`rich_layout.rs`) & Icon Swap (`icon.rs`)

public enum TextBaseDirection: Sendable, Hashable, Codable {
    case auto
    case ltr
    case rtl
}

/// Options for `TextSystem.layoutRich(with:)` (`rune::text::RichLayoutOptions`).
public struct RichLayoutOptions: Equatable, Sendable {
    public var align: TextAlign
    public var wrapAnywhere: Bool
    public var direction: TextBaseDirection

    public init(align: TextAlign = .leading, wrapAnywhere: Bool = false, direction: TextBaseDirection = .auto) {
        self.align = align
        self.wrapAnywhere = wrapAnywhere
        self.direction = direction
    }

    public func aligned(_ align: TextAlign) -> RichLayoutOptions {
        var c = self; c.align = align; return c
    }

    public func wrappingAnywhere(_ on: Bool = true) -> RichLayoutOptions {
        var c = self; c.wrapAnywhere = on; return c
    }

    public func directed(_ direction: TextBaseDirection) -> RichLayoutOptions {
        var c = self; c.direction = direction; return c
    }
}

/// Shared measurement entry points mirroring `rune::text::{measure, measure_with, content_widths, advance}`.
public enum TextMeasure {
    private static let shared = TextSystem()

    public static func measure(
        _ text: String,
        spans: [TextSpan] = [],
        style: TextStyle,
        maxWidth: Float? = nil
    ) -> Vec2 {
        measureWith(text, spans: spans, style: style, maxWidth: maxWidth, options: RichLayoutOptions())
    }

    public static func measureWith(
        _ text: String,
        spans: [TextSpan] = [],
        style: TextStyle,
        maxWidth: Float? = nil,
        options: RichLayoutOptions
    ) -> Vec2 {
        var effectiveStyle = style
        effectiveStyle.align = options.align
        let shaped = shared.shape(
            text: text,
            spans: spans.isEmpty ? nil : spans,
            style: effectiveStyle,
            maxWidth: maxWidth,
            pixelScale: 1.0,
            emitGlyphs: false
        )
        return Vec2(ceilf(shaped.size.x), shaped.size.y)
    }

    public static func contentWidths(_ text: String, spans: [TextSpan] = [], style: TextStyle) -> (min: Float, max: Float) {
        let minS = shared.shape(text: text, spans: spans.isEmpty ? nil : spans, style: style, maxWidth: 0, pixelScale: 1.0, emitGlyphs: false)
        let maxS = shared.shape(text: text, spans: spans.isEmpty ? nil : spans, style: style, maxWidth: nil, pixelScale: 1.0, emitGlyphs: false)
        return (minS.size.x, maxS.size.x)
    }

    public static func advance(_ text: String, style: TextStyle) -> Float {
        var single = style
        single.wrap = .noWrap
        return shared.shape(text: text, spans: nil, style: single, maxWidth: nil, pixelScale: 1.0, emitGlyphs: false).size.x
    }
}

/// App-wide alternative icon swap & size swap registry (`set_icon_swap` / `set_icon_swap_size` / `icon_coverage_at`).
public enum IconSwapRegistry {
    public typealias SwapHandler = @Sendable (SVGIcon) -> SVGIcon?
    public typealias SizeHandler = @Sendable (Float) -> Float

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var swap: SwapHandler?
        var swapSize: SizeHandler?
        var generation: UInt64 = 1
    }

    private static let state = State()

    public static func setIconSwap(_ handler: SwapHandler?) {
        state.lock.lock()
        state.swap = handler
        state.generation &+= 1
        state.lock.unlock()
    }

    public static func setIconSwapSize(_ handler: SizeHandler?) {
        state.lock.lock()
        state.swapSize = handler
        state.generation &+= 1
        state.lock.unlock()
    }

    public static func resolvedIcon(for icon: SVGIcon) -> (icon: SVGIcon, wasSwapped: Bool) {
        state.lock.lock()
        let swap = state.swap
        state.lock.unlock()
        if let swap, let replacement = swap(icon) {
            return (replacement, true)
        }
        return (icon, false)
    }

    public static func resolvedSize(for icon: SVGIcon, requestedSize: Float) -> Float {
        state.lock.lock()
        let swap = state.swap
        let sizeFn = state.swapSize
        state.lock.unlock()
        guard let swap, let sizeFn, swap(icon) != nil else { return requestedSize }
        return sizeFn(requestedSize)
    }

    public static func iconCoverageAt(icon: SVGIcon, pixelSize: Int) -> [UInt8] {
        let (resolved, _) = resolvedIcon(for: icon)
        return GlyphAtlas.rasterizeIconBitmap(resolved, pixelSize: max(1, pixelSize))
    }
}
