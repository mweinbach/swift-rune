import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - 1. Font Epoch & Family Slot Registry (rune::text::measure + families)

/// Monotonically increasing epoch bumped whenever font families or loaded fonts change (`rune::text::font_epoch`).
public func fontEpoch() -> UInt64 {
    FontFamiliesRegistry.currentEpoch()
}

/// Temporarily overrides `sans` and `mono` family slots for `body`, bumping `fontEpoch()` on entry and exit.
public func withFontFamilies(sans: String, mono: String, _ body: () throws -> Void) rethrows {
    try FontFamiliesRegistry.withFamilies(sans: sans, mono: mono, body)
}

/// Process-wide font epoch & thread-scoped slot registry (`rune::text::families`).
public enum FontFamiliesRegistry {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var epoch: UInt64 = 1
        var sans: String = ""
        var mono: String = ""
    }

    private struct ThreadFrame {
        var sans: String
        var mono: String
        var epoch: UInt64
    }

    private static let storage = Storage()
    private static let threadStackKey = "rune.fontFamilies.threadStack"

    private static func currentThreadStack() -> [ThreadFrame]? {
        Thread.current.threadDictionary[threadStackKey] as? [ThreadFrame]
    }

    private static func setThreadStack(_ stack: [ThreadFrame]) {
        if stack.isEmpty {
            Thread.current.threadDictionary.removeObject(forKey: threadStackKey)
        } else {
            Thread.current.threadDictionary[threadStackKey] = stack
        }
    }

    /// Returns active thread-local override families if running inside `withFontFamilies`, else `nil`.
    internal static func threadOverrideFamilies() -> (sans: String, mono: String)? {
        guard let top = currentThreadStack()?.last else { return nil }
        return (top.sans, top.mono)
    }

    public static func currentEpoch() -> UInt64 {
        if let top = currentThreadStack()?.last {
            return top.epoch
        }
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.epoch
    }

    @discardableResult
    public static func bumpEpoch() -> UInt64 {
        storage.lock.lock()
        storage.epoch &+= 1
        let val = storage.epoch
        storage.lock.unlock()
        if var stack = currentThreadStack(), !stack.isEmpty {
            stack[stack.count - 1].epoch = val
            setThreadStack(stack)
        }
        return val
    }

    public static func currentFamilies() -> (sans: String, mono: String) {
        if let top = currentThreadStack()?.last {
            return (top.sans, top.mono)
        }
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return (storage.sans, storage.mono)
    }

    @discardableResult
    public static func setFamilies(sans: String, mono: String) -> Bool {
        if var stack = currentThreadStack(), let top = stack.last {
            if top.sans == sans && top.mono == mono {
                return false
            }
            storage.lock.lock()
            storage.epoch &+= 1
            let newEpoch = storage.epoch
            storage.lock.unlock()
            stack[stack.count - 1] = ThreadFrame(sans: sans, mono: mono, epoch: newEpoch)
            setThreadStack(stack)
            return true
        }
        storage.lock.lock()
        if storage.sans == sans && storage.mono == mono {
            storage.lock.unlock()
            return false
        }
        storage.sans = sans
        storage.mono = mono
        storage.epoch &+= 1
        storage.lock.unlock()
        return true
    }

    public static func withFamilies(sans: String, mono: String, _ body: () throws -> Void) rethrows {
        storage.lock.lock()
        storage.epoch &+= 1
        let entryEpoch = storage.epoch
        storage.lock.unlock()

        var stack = currentThreadStack() ?? []
        stack.append(ThreadFrame(sans: sans, mono: mono, epoch: entryEpoch))
        setThreadStack(stack)
        defer {
            var updated = currentThreadStack() ?? []
            if !updated.isEmpty {
                updated.removeLast()
            }
            setThreadStack(updated)
            storage.lock.lock()
            storage.epoch &+= 1
            storage.lock.unlock()
        }
        try body()
    }
}

// MARK: - 2. TextCase & Source-to-Displayed Byte Mapping (rune::text::case)

/// Text case transformation (`rune::TextCase`).
public enum TextCase: String, Sendable, Hashable, Codable {
    case uppercase
    case lowercase
}

/// Transforms `source` according to `TextCase` while tracking bidirectional UTF-8 byte offsets
/// matching `crates/rune/src/text/case.rs`.
public struct TextCaseMapping: Sendable, Equatable {
    private struct Bound: Sendable, Equatable {
        var sourceByte: Int
        var displayedByte: Int
    }

    public let displayed: String
    private let sourceUTF8Count: Int
    private let bounds: [Bound]

    public init(source: String, textCase: TextCase) {
        let scalars = Array(source.unicodeScalars)
        var shown = ""
        shown.reserveCapacity(source.utf8.count)
        var pairs: [Bound] = []
        pairs.reserveCapacity(scalars.count + 1)
        var srcByte = 0
        var dstByte = 0

        for i in scalars.indices {
            pairs.append(Bound(sourceByte: srcByte, displayedByte: dstByte))
            let scalar = scalars[i]
            let transformed: String
            if textCase == .uppercase {
                transformed = String(scalar).uppercased()
            } else if scalar == "\u{03A3}" {
                // Unicode SpecialCasing Final_Sigma: preceded by cased, not followed by cased
                // (ignoring case-ignorable scalars).
                var hasBefore = false
                var j = i - 1
                while j >= 0 {
                    if scalars[j].properties.isCaseIgnorable {
                        j -= 1
                        continue
                    }
                    hasBefore = scalars[j].properties.isCased
                    break
                }
                var hasAfter = false
                var k = i + 1
                while k < scalars.count {
                    if scalars[k].properties.isCaseIgnorable {
                        k += 1
                        continue
                    }
                    hasAfter = scalars[k].properties.isCased
                    break
                }
                transformed = (hasBefore && !hasAfter) ? "\u{03C2}" : "\u{03C3}"
            } else {
                transformed = String(scalar).lowercased()
            }

            shown.append(transformed)
            srcByte += scalar.utf8.count
            dstByte += transformed.utf8.count
        }
        pairs.append(Bound(sourceByte: srcByte, displayedByte: dstByte))
        self.displayed = shown
        self.sourceUTF8Count = srcByte
        self.bounds = pairs
    }

    /// Displayed UTF-8 byte offset where source byte `offset` starts (`up == false`),
    /// or its end when inside an expanding scalar (`up == true`, matching `Source::shown`).
    public func displayedOffset(forSourceUTF8Offset offset: Int, up: Bool = false) -> Int {
        guard !bounds.isEmpty else { return 0 }
        if up {
            let idx = bounds.firstIndex { $0.sourceByte >= offset }
            return idx.map { bounds[$0].displayedByte } ?? (bounds.last?.displayedByte ?? 0)
        } else {
            let idx = bounds.lastIndex { $0.sourceByte <= offset }
            return idx.map { bounds[$0].displayedByte } ?? 0
        }
    }

    /// Source UTF-8 byte offset of the scalar drawn at displayed byte `offset` (`up == false`),
    /// or the next scalar's start when inside an expanded scalar (`up == true`, matching `Source::source`).
    public func sourceOffset(forDisplayedUTF8Offset offset: Int, up: Bool = false) -> Int {
        guard !bounds.isEmpty else { return sourceUTF8Count }
        if up {
            let idx = bounds.firstIndex { $0.displayedByte >= offset }
            return idx.map { bounds[$0].sourceByte } ?? sourceUTF8Count
        } else {
            let idx = bounds.lastIndex { $0.displayedByte <= offset }
            return idx.map { bounds[$0].sourceByte } ?? 0
        }
    }

    public func displayedRange(forSourceUTF8Range range: Range<Int>) -> Range<Int> {
        let lo = displayedOffset(forSourceUTF8Offset: range.lowerBound, up: false)
        let hi = range.isEmpty
            ? lo
            : displayedOffset(forSourceUTF8Offset: range.upperBound, up: true)
        return min(lo, hi)..<max(lo, hi)
    }
}

// MARK: - 3. Rich Text Spans, Links, and TextHighlights (rune::text::span)

/// Stroke ring around a span, link, or highlight (`(Color, f32)`).
public struct TextRing: Sendable, Hashable {
    public var color: Color
    public var width: Float

    public init(color: Color, width: Float) {
        self.color = color
        self.width = max(0, width)
    }
}

/// Byte-range styled span (`rune::Span`).
public struct RichSpan: Sendable, Hashable {
    public var byteRange: Range<Int>
    public var color: Color?
    public var background: Color?
    public var ring: TextRing?
    public var pad: Float
    public var weight: Float?
    public var size: Float?
    public var italic: Bool?
    public var monospace: Bool?
    public var underline: Bool?
    public var strikethrough: Bool?

    public init(_ byteRange: Range<Int>) {
        self.byteRange = max(0, byteRange.lowerBound)..<max(max(0, byteRange.lowerBound), byteRange.upperBound)
        self.color = nil
        self.background = nil
        self.ring = nil
        self.pad = 0
        self.weight = nil
        self.size = nil
        self.italic = nil
        self.monospace = nil
        self.underline = nil
        self.strikethrough = nil
    }

    public func color(_ c: Color) -> Self { var s = self; s.color = c; return s }
    public func bg(_ c: Color) -> Self { var s = self; s.background = c; return s }
    public func ring(_ c: Color, width: Float = 1.0) -> Self { var s = self; s.ring = TextRing(color: c, width: width); return s }
    public func pad(_ p: Float) -> Self { var s = self; s.pad = max(0, p); return s }
    public func weight(_ w: Float) -> Self { var s = self; s.weight = w; return s }
    public func size(_ pts: Float) -> Self { var s = self; s.size = max(1, pts); return s }
    public func bold() -> Self { weight(700) }
    public func italic(_ on: Bool = true) -> Self { var s = self; s.italic = on; return s }
    public func mono(_ on: Bool = true) -> Self { var s = self; s.monospace = on; return s }
    public func underline(_ on: Bool = true) -> Self { var s = self; s.underline = on; return s }
    public func strikethrough(_ on: Bool = true) -> Self { var s = self; s.strikethrough = on; return s }
}

/// Flattens overlapping `RichSpan` slices onto contiguous `TextSpan` chunks ready for `TextSystem.shape`.
public enum RichSpanFlattener {
    public static func flatten(_ spans: [RichSpan], in text: String, base: TextStyle) -> [TextSpan] {
        let len = text.utf8.count
        guard len > 0 else { return [] }
        if spans.isEmpty {
            return [TextSpan(text)]
        }

        // Collect all valid scalar boundaries so splitting never cuts inside multi-byte UTF-8.
        var boundaries: Set<Int> = [0, len]
        var scalarStarts: [Int] = [0]
        var off = 0
        for scalar in text.unicodeScalars {
            off += scalar.utf8.count
            scalarStarts.append(off)
        }
        func snap(_ byte: Int) -> Int {
            let clamped = min(max(0, byte), len)
            // Largest scalar boundary <= clamped
            var lo = 0
            var hi = scalarStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if scalarStarts[mid] <= clamped {
                    lo = mid
                } else {
                    hi = mid - 1
                }
            }
            return scalarStarts[lo]
        }

        let snappedSpans = spans.compactMap { s -> RichSpan? in
            let a = snap(s.byteRange.lowerBound)
            let b = snap(s.byteRange.upperBound)
            guard a < b else { return nil }
            var copy = s
            copy.byteRange = a..<b
            boundaries.insert(a)
            boundaries.insert(b)
            return copy
        }

        let sortedCuts = boundaries.sorted()
        var merged: [TextSpan] = []

        for i in 0..<(sortedCuts.count - 1) {
            let a = sortedCuts[i]
            let b = sortedCuts[i + 1]
            guard a < b else { continue }
            let startIdx = text.utf8.index(text.utf8.startIndex, offsetBy: a)
            let endIdx = text.utf8.index(text.utf8.startIndex, offsetBy: b)
            let chunk = String(text[startIdx..<endIdx])

            var color: Color? = nil
            var bg: Color? = nil
            var weight: Float? = nil
            var size: Float? = nil
            var italic = base.italic
            var monospace = (base.family == .monospace)
            var underline = false
            var strikethrough = false

            for sp in snappedSpans where sp.byteRange.lowerBound <= a && b <= sp.byteRange.upperBound {
                if let c = sp.color { color = c }
                if let bCol = sp.background { bg = bCol }
                if let w = sp.weight { weight = w }
                if let sz = sp.size { size = sz }
                if let it = sp.italic { italic = it }
                if let mo = sp.monospace { monospace = mo }
                if let ul = sp.underline { underline = ul }
                if let st = sp.strikethrough { strikethrough = st }
            }

            let span = TextSpan(
                chunk,
                color: color,
                background: bg,
                weight: weight,
                italic: italic,
                monospace: monospace,
                underline: underline,
                strikethrough: strikethrough,
                size: size
            )

            if var prev = merged.last,
               prev.color == span.color,
               prev.background == span.background,
               prev.weight == span.weight,
               prev.size == span.size,
               prev.italic == span.italic,
               prev.monospace == span.monospace,
               prev.underline == span.underline,
               prev.strikethrough == span.strikethrough {
                prev.text.append(span.text)
                merged[merged.count - 1] = prev
            } else {
                merged.append(span)
            }
        }
        return merged
    }
}

/// Visual overrides for a `TextLink` in hover, pressed, or keyboard-focused states (`rune::LinkPaint`).
public struct LinkPaint: Sendable, Hashable {
    public var color: Color?
    public var background: Color?
    public var ring: TextRing?
    public var underline: Bool?

    public init(
        color: Color? = nil,
        background: Color? = nil,
        ring: TextRing? = nil,
        underline: Bool? = nil
    ) {
        self.color = color
        self.background = background
        self.ring = ring
        self.underline = underline
    }

    public func color(_ c: Color) -> Self { var p = self; p.color = c; return p }
    public func bg(_ c: Color) -> Self { var p = self; p.background = c; return p }
    public func ring(_ c: Color, width: Float = 1.0) -> Self { var p = self; p.ring = TextRing(color: c, width: width); return p }
    public func underline(_ on: Bool = true) -> Self { var p = self; p.underline = on; return p }

    /// Whether no hover, pressed, or focused visual overrides are configured.
    public var isEmpty: Bool {
        color == nil && background == nil && ring == nil && underline == nil
    }
}

/// Interactive byte-range link inside rich text (`rune::Link`).
public struct TextLink: Sendable, Hashable {
    public var byteRange: Range<Int>
    public var id: String
    public var role: ElementRole
    public var label: String?
    public var hover: LinkPaint
    public var pressed: LinkPaint?
    public var focused: LinkPaint?
    public var help: String?

    public init(
        _ byteRange: Range<Int>,
        id: String,
        role: ElementRole = .link,
        label: String? = nil,
        hover: LinkPaint = LinkPaint(),
        pressed: LinkPaint? = nil,
        focused: LinkPaint? = nil,
        help: String? = nil
    ) {
        self.byteRange = max(0, byteRange.lowerBound)..<max(max(0, byteRange.lowerBound), byteRange.upperBound)
        self.id = id
        self.role = role
        self.label = label
        self.hover = hover
        self.pressed = pressed
        self.focused = focused
        self.help = help.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func role(_ role: ElementRole) -> Self { var l = self; l.role = role; return l }
    public func label(_ label: String) -> Self { var l = self; l.label = label; return l }
    public func hover(_ paint: LinkPaint) -> Self { var l = self; l.hover = paint; return l }
    public func pressed(_ paint: LinkPaint) -> Self { var l = self; l.pressed = paint; return l }
    public func focused(_ paint: LinkPaint) -> Self { var l = self; l.focused = paint; return l }
    public func help(_ text: String) -> Self {
        var l = self
        l.help = text.isEmpty ? nil : text
        return l
    }

    /// Computes effective interactive `LinkPaint` priority (`pressed > hover > focused ?? hover`, `links.rs:187-197`).
    public func effectivePaint(hovered: Bool, pressed: Bool, focused: Bool) -> LinkPaint {
        if pressed {
            return self.pressed ?? self.hover
        }
        if hovered {
            return self.hover
        }
        if focused {
            return self.focused ?? self.hover
        }
        return LinkPaint()
    }
}

/// Paint-only background highlight over UTF-8 byte ranges (`rune::TextHighlight`).
public struct TextHighlight: Sendable, Hashable {
    public var byteRange: Range<Int>
    public var bg: Color
    public var fg: Color?
    public var ring: TextRing?
    public var pad: Float
    public var key: String?

    public init(
        _ byteRange: Range<Int>,
        bg: Color,
        fg: Color? = nil,
        ring: TextRing? = nil,
        pad: Float = 0,
        key: String? = nil
    ) {
        self.byteRange = max(0, byteRange.lowerBound)..<max(max(0, byteRange.lowerBound), byteRange.upperBound)
        self.bg = bg
        self.fg = fg
        self.ring = ring
        self.pad = max(0, pad)
        self.key = key
    }

    public func color(_ c: Color) -> Self {
        var h = self
        h.fg = c
        return h
    }

    public func fg(_ c: Color?) -> Self {
        var h = self
        h.fg = c
        return h
    }

    public func ring(_ color: Color, width: Float = 1.0) -> Self {
        var h = self
        h.ring = TextRing(color: color, width: width)
        return h
    }

    public func pad(_ p: Float) -> Self {
        var h = self
        h.pad = max(0, p)
        return h
    }

    public func key(_ k: String) -> Self {
        var h = self
        h.key = k
        return h
    }
}

/// Computed highlight quad (merging contiguous same-line boxes per `decorations.rs:239-250`).
public struct HighlightQuad: Sendable, Equatable {
    public var rect: SIMD4<Float>
    public var bg: Color
    public var ring: TextRing?
    public var cornerRadius: Float
}

public enum TextHighlightPainter {
    public static func quads(
        highlights: [TextHighlight],
        in text: String,
        shaped: ShapedText,
        textSystem: TextSystem,
        pixelScale: Float,
        origin: Vec2 = .zero
    ) -> [HighlightQuad] {
        guard !highlights.isEmpty, !text.isEmpty else { return [] }
        let len = text.utf8.count
        let radius = 4.0 * pixelScale
        var out: [HighlightQuad] = []

        for h in highlights {
            let a = min(h.byteRange.lowerBound, len)
            let b = min(h.byteRange.upperBound, len)
            guard a < b, h.bg.a > 0 || h.ring != nil else { continue }
            let pad = h.pad * pixelScale
            let ring = h.ring.map { TextRing(color: $0.color, width: $0.width * pixelScale) }
            let boxes = textSystem.selectionRects(in: shaped, utf8Range: a..<b, pixelScale: pixelScale)
            for r in boxes where r.z > 0 {
                let x = origin.x * pixelScale + r.x * pixelScale - pad
                let y = origin.y * pixelScale + r.y * pixelScale
                let w = r.z * pixelScale + 2.0 * pad
                let hPx = r.w * pixelScale
                let rect = SIMD4<Float>(x, y, w, hPx)

                if var prev = out.last,
                   abs(prev.rect.y - rect.y) < 1.0,
                   abs((prev.rect.x + prev.rect.z) - rect.x - 2.0 * pad) < 1.5,
                   prev.bg == h.bg {
                    let right = rect.x + rect.z
                    prev.rect.z = max(prev.rect.z, right - prev.rect.x)
                    prev.rect.w = max(prev.rect.w, rect.w)
                    out[out.count - 1] = prev
                } else {
                    out.append(HighlightQuad(rect: rect, bg: h.bg, ring: ring, cornerRadius: radius))
                }
            }
        }
        return out
    }
}

// MARK: - 4. Full SVG XML Parser & Multi-Color SVG Icon Rasterizer (rune::text::icon + color_icon)

/// Parses SVG `<g>`, `<path>`, `<rect>`, `<circle>`, `<ellipse>`, `<line>`, `<polyline>`, `<polygon>`,
/// transforms, opacity groups, `currentColor`, hex/rgb colors, and `<linearGradient>` definitions.
public enum SVGIconRenderer {
    public struct PaintStop: Sendable, Equatable {
        public var offset: Float
        public var color: Color
    }

    public struct LinearGradient: Sendable, Equatable {
        public var id: String
        public var x1: Float
        public var y1: Float
        public var x2: Float
        public var y2: Float
        public var stops: [PaintStop]
    }

    public enum FillStyle: Sendable, Equatable {
        case none
        case solid(Color)
        case currentColor
        case gradient(String)
    }

    public struct DrawCommand: Sendable, Equatable {
        public var pathData: String
        public var fill: FillStyle
        public var fillOpacity: Float
        public var evenOdd: Bool
        public var stroke: FillStyle?
        public var strokeWidth: Float
        public var strokeOpacity: Float
        public var lineCap: String
        public var lineJoin: String
        public var opacity: Float
        public var transform: [Float] // [a, b, c, d, tx, ty]
    }

    public struct ParsedBody: Sendable, Equatable {
        public var commands: [DrawCommand]
        public var gradients: [String: LinearGradient]
    }

    /// Parses raw SVG body XML into flattened `DrawCommand` list + `LinearGradient` table.
    public static func parseBody(_ body: String) -> ParsedBody {
        var gradients: [String: LinearGradient] = [:]
        var activeGradient: LinearGradient? = nil

        struct Scope {
            var transform: [Float]
            var paints: Bool
            var opacity: Float
            var inheritedAttrs: [String: String]
        }

        let identity: [Float] = [1, 0, 0, 1, 0, 0]
        var scopes: [Scope] = [Scope(transform: identity, paints: true, opacity: 1.0, inheritedAttrs: [:])]
        var commands: [DrawCommand] = []

        let inheritedKeys = Set([
            "fill", "stroke", "stroke-width", "stroke-linecap",
            "stroke-linejoin", "fill-rule", "fill-opacity", "stroke-opacity"
        ])

        for rawChunk in body.split(separator: ">") {
            let raw = rawChunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, !raw.hasPrefix("<!"), !raw.hasPrefix("<?") else { continue }

            if raw.hasPrefix("</") {
                let endTag = raw.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if endTag == "lineargradient", let grad = activeGradient {
                    gradients[grad.id] = grad
                    activeGradient = nil
                } else if scopes.count > 1 {
                    scopes.removeLast()
                }
                continue
            }

            let isSelfClosing = raw.hasSuffix("/")
            let bodyTag = raw.dropFirst(raw.hasPrefix("<") ? 1 : 0)
            let tag = bodyTag.split(whereSeparator: { $0.isWhitespace || $0 == "/" }).first.map { String($0).lowercased() } ?? ""

            if tag == "lineargradient" {
                let id = attribute(in: raw, named: "id") ?? ""
                let x1 = parseLengthOrPercent(attribute(in: raw, named: "x1"), defaultValue: 0)
                let y1 = parseLengthOrPercent(attribute(in: raw, named: "y1"), defaultValue: 0)
                let x2 = parseLengthOrPercent(attribute(in: raw, named: "x2"), defaultValue: 1)
                let y2 = parseLengthOrPercent(attribute(in: raw, named: "y2"), defaultValue: 0)
                let grad = LinearGradient(id: id, x1: x1, y1: y1, x2: x2, y2: y2, stops: [])
                if isSelfClosing {
                    gradients[id] = grad
                } else {
                    activeGradient = grad
                }
                continue
            }

            if tag == "stop", activeGradient != nil {
                let off = parseLengthOrPercent(attribute(in: raw, named: "offset"), defaultValue: 0)
                let colStr = attribute(in: raw, named: "stop-color") ?? "#000000"
                let stopAlpha = Float(attribute(in: raw, named: "stop-opacity") ?? "") ?? 1.0
                if let baseCol = parseColor(colStr) {
                    activeGradient?.stops.append(PaintStop(offset: off, color: baseCol.alpha(baseCol.a * stopAlpha)))
                }
                continue
            }

            let parent = scopes.last!
            let ownTransform = attribute(in: raw, named: "transform").map(parseTransform) ?? identity
            let composedTransform = multiply(ownTransform, parent.transform)
            let paints = parent.paints && attribute(in: raw, named: "display") != "none" && tag != "defs" && tag != "clippath" && tag != "mask"
            let groupOpacity = (Float(attribute(in: raw, named: "opacity") ?? "") ?? 1.0)
            let combinedOpacity = parent.opacity * max(0, min(1, groupOpacity))

            var mergedAttrs = parent.inheritedAttrs
            for key in inheritedKeys {
                if let val = attribute(in: raw, named: key) {
                    mergedAttrs[key] = val
                }
            }

            if tag == "g" || tag == "a" || tag == "svg" || tag == "defs" {
                if !isSelfClosing {
                    scopes.append(Scope(
                        transform: composedTransform,
                        paints: paints,
                        opacity: combinedOpacity,
                        inheritedAttrs: mergedAttrs
                    ))
                }
                continue
            }

            guard paints, let d = elementPathData(tag: tag, rawElement: raw) else {
                continue
            }

            let fillAttr = mergedAttrs["fill"] ?? "currentColor"
            let fillStyle = parseFillStyle(fillAttr)
            let fillOpacity = Float(mergedAttrs["fill-opacity"] ?? "") ?? 1.0
            let evenOdd = (mergedAttrs["fill-rule"] == "evenodd")

            let strokeAttr = mergedAttrs["stroke"]
            let strokeStyle: FillStyle? = (strokeAttr != nil && strokeAttr != "none") ? parseFillStyle(strokeAttr!) : nil
            let strokeWidth = Float((mergedAttrs["stroke-width"] ?? "").replacingOccurrences(of: "px", with: "")) ?? 1.0
            let strokeOpacity = Float(mergedAttrs["stroke-opacity"] ?? "") ?? 1.0
            let lineCap = mergedAttrs["stroke-linecap"] ?? "butt"
            let lineJoin = mergedAttrs["stroke-linejoin"] ?? "miter"

            commands.append(DrawCommand(
                pathData: d,
                fill: fillStyle,
                fillOpacity: fillOpacity,
                evenOdd: evenOdd,
                stroke: strokeStyle,
                strokeWidth: max(0, strokeWidth),
                strokeOpacity: strokeOpacity,
                lineCap: lineCap,
                lineJoin: lineJoin,
                opacity: combinedOpacity,
                transform: composedTransform
            ))
        }

        return ParsedBody(commands: commands, gradients: gradients)
    }

    public static func extractPathStrings(fromBody body: String) -> [String] {
        parseBody(body).commands.map(\.pathData)
    }

    #if canImport(CoreGraphics)
    /// Renders monochrome SVG XML into the given CoreGraphics alpha context (`GlyphAtlas`).
    public static func drawMonochromeBody(_ body: String, in ctx: CGContext) {
        let parsed = parseBody(body)
        for cmd in parsed.commands {
            ctx.saveGState()
            let t = cmd.transform
            ctx.concatenate(CGAffineTransform(
                a: CGFloat(t[0]), b: CGFloat(t[1]),
                c: CGFloat(t[2]), d: CGFloat(t[3]),
                tx: CGFloat(t[4]), ty: CGFloat(t[5])
            ))
            let cgPath = GlyphAtlas.parseSVGPath(cmd.pathData)
            if cmd.fill != .none {
                ctx.addPath(cgPath)
                ctx.setFillColor(gray: 1.0, alpha: CGFloat(cmd.fillOpacity * cmd.opacity))
                ctx.fillPath(using: cmd.evenOdd ? .evenOdd : .winding)
            }
            if cmd.stroke != nil, cmd.strokeWidth > 0 {
                ctx.addPath(cgPath)
                ctx.setStrokeColor(gray: 1.0, alpha: CGFloat(cmd.strokeOpacity * cmd.opacity))
                ctx.setLineWidth(CGFloat(cmd.strokeWidth))
                ctx.setLineCap(cgLineCap(cmd.lineCap))
                ctx.setLineJoin(cgLineJoin(cmd.lineJoin))
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
    }

    private static func cgLineCap(_ name: String) -> CGLineCap {
        switch name.lowercased() {
        case "round": return .round
        case "square": return .square
        default: return .butt
        }
    }

    private static func cgLineJoin(_ name: String) -> CGLineJoin {
        switch name.lowercased() {
        case "round": return .round
        case "bevel": return .bevel
        default: return .miter
        }
    }
    #endif

    // MARK: - XML Attribute & Path Extraction Helpers

    static func attribute(in element: String, named key: String) -> String? {
        for quote in ["\"", "'"] {
            let needle = "\(key)=\(quote)"
            if let start = element.range(of: needle) {
                let after = element[start.upperBound...]
                if let end = after.firstIndex(of: Character(quote)) {
                    return String(after[..<end])
                }
            }
        }
        return nil
    }

    static func elementPathData(tag: String, rawElement: String) -> String? {
        func num(_ name: String) -> Float {
            guard let raw = attribute(in: rawElement, named: name) else { return 0 }
            return Float(raw.replacingOccurrences(of: "px", with: "")) ?? 0
        }
        switch tag {
        case "path":
            return attribute(in: rawElement, named: "d")
        case "rect":
            let (x, y, w, h) = (num("x"), num("y"), num("width"), num("height"))
            guard w > 0, h > 0 else { return nil }
            let r = min(num("rx"), min(w * 0.5, h * 0.5))
            if r <= 0 {
                return "M\(x) \(y)h\(w)v\(h)h\(-w)Z"
            }
            return "M\(x + r) \(y)h\(w - 2 * r)a\(r) \(r) 0 0 1 \(r) \(r)v\(h - 2 * r)a\(r) \(r) 0 0 1 \(-r) \(r)h\(-(w - 2 * r))a\(r) \(r) 0 0 1 \(-r) \(-r)v\(-(h - 2 * r))a\(r) \(r) 0 0 1 \(r) \(-r)Z"
        case "circle":
            let (cx, cy, r) = (num("cx"), num("cy"), num("r"))
            guard r > 0 else { return nil }
            return "M\(cx - r) \(cy)a\(r) \(r) 0 1 0 \(2 * r) 0a\(r) \(r) 0 1 0 \(-2 * r) 0Z"
        case "ellipse":
            let (cx, cy, rx, ry) = (num("cx"), num("cy"), num("rx"), num("ry"))
            guard rx > 0, ry > 0 else { return nil }
            return "M\(cx - rx) \(cy)a\(rx) \(ry) 0 1 0 \(2 * rx) 0a\(rx) \(ry) 0 1 0 \(-2 * rx) 0Z"
        case "line":
            return "M\(num("x1")) \(num("y1"))L\(num("x2")) \(num("y2"))"
        case "polyline", "polygon":
            guard let ptsRaw = attribute(in: rawElement, named: "points") else { return nil }
            let nums = parseNumbers(ptsRaw)
            guard nums.count >= 2 else { return nil }
            var out = ""
            var i = 0
            while i + 1 < nums.count {
                out += (i == 0 ? "M" : "L") + "\(nums[i]) \(nums[i + 1])"
                i += 2
            }
            if tag == "polygon" { out.append("Z") }
            return out
        default:
            return nil
        }
    }

    static func parseNumbers(_ raw: String) -> [Float] {
        var out: [Float] = []
        var cur = ""
        var prev: Character = " "
        for c in raw {
            let startsNew = (c == "-" || c == "+") && prev != "e" && prev != "E"
            if c == "," || c.isWhitespace || (startsNew && !cur.isEmpty) {
                if let val = Float(cur) { out.append(val) }
                cur.removeAll(keepingCapacity: true)
            }
            if c != "," && !c.isWhitespace {
                cur.append(c)
            }
            prev = c
        }
        if let val = Float(cur) { out.append(val) }
        return out
    }

    private static func parseLengthOrPercent(_ raw: String?, defaultValue: Float) -> Float {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return defaultValue
        }
        if raw.hasSuffix("%") {
            return (Float(raw.dropLast()) ?? (defaultValue * 100)) / 100.0
        }
        return Float(raw.replacingOccurrences(of: "px", with: "")) ?? defaultValue
    }

    static func parseFillStyle(_ value: String) -> FillStyle {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "none" { return .none }
        if trimmed == "currentColor" { return .currentColor }
        if trimmed.hasPrefix("url(#"), trimmed.hasSuffix(")") {
            let id = String(trimmed.dropFirst(5).dropLast())
            return .gradient(id)
        }
        if let col = parseColor(trimmed) {
            return .solid(col)
        }
        return .currentColor
    }

    static func parseColor(_ raw: String) -> Color? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") {
            return Color.hex(s)
        }
        if s.hasPrefix("rgb(") && s.hasSuffix(")") {
            let nums = parseNumbers(String(s.dropFirst(4).dropLast()))
            guard nums.count >= 3 else { return nil }
            return .srgb(nums[0] / 255.0, nums[1] / 255.0, nums[2] / 255.0)
        }
        if s.hasPrefix("rgba(") && s.hasSuffix(")") {
            let nums = parseNumbers(String(s.dropFirst(5).dropLast()))
            guard nums.count >= 4 else { return nil }
            return .srgb(nums[0] / 255.0, nums[1] / 255.0, nums[2] / 255.0, nums[3])
        }
        switch s {
        case "black": return Color(r: 0, g: 0, b: 0, a: 1)
        case "white": return Color(r: 1, g: 1, b: 1, a: 1)
        default: return nil
        }
    }

    private static func parseTransform(_ spec: String) -> [Float] {
        var result: [Float] = [1, 0, 0, 1, 0, 0]
        var remaining = spec[...]
        while let openIdx = remaining.firstIndex(of: "("),
              let closeIdx = remaining[openIdx...].firstIndex(of: ")") {
            let op = remaining[..<openIdx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let args = parseNumbers(String(remaining[remaining.index(after: openIdx)..<closeIdx]))
            let nextMatrix: [Float]
            switch op {
            case "translate":
                let tx = args.first ?? 0
                let ty = args.count > 1 ? args[1] : 0
                nextMatrix = [1, 0, 0, 1, tx, ty]
            case "scale":
                let sx = args.first ?? 1
                let sy = args.count > 1 ? args[1] : sx
                nextMatrix = [sx, 0, 0, sy, 0, 0]
            case "rotate":
                let deg = args.first ?? 0
                let rad = deg * .pi / 180.0
                let c = cosf(rad)
                let s = sinf(rad)
                if args.count >= 3 {
                    let cx = args[1]
                    let cy = args[2]
                    let rot: [Float] = [c, s, -s, c, 0, 0]
                    nextMatrix = multiply([1, 0, 0, 1, -cx, -cy], multiply(rot, [1, 0, 0, 1, cx, cy]))
                } else {
                    nextMatrix = [c, s, -s, c, 0, 0]
                }
            case "matrix" where args.count >= 6:
                nextMatrix = Array(args.prefix(6))
            default:
                nextMatrix = [1, 0, 0, 1, 0, 0]
            }
            result = multiply(nextMatrix, result)
            remaining = remaining[remaining.index(after: closeIdx)...]
        }
        return result
    }

    private static func multiply(_ a: [Float], _ b: [Float]) -> [Float] {
        [
            a[0] * b[0] + a[1] * b[2],
            a[0] * b[1] + a[1] * b[3],
            a[2] * b[0] + a[3] * b[2],
            a[2] * b[1] + a[3] * b[3],
            a[4] * b[0] + a[5] * b[2] + b[4],
            a[4] * b[1] + a[5] * b[3] + b[5],
        ]
    }
}

/// Multi-color SVG `Icon` rasterizer and 4 MiB cache (`rune::text::color_icon`).
public final class ColorIconRasterizer: @unchecked Sendable {
    private static let budgetBytes = 4 * 1024 * 1024

    private struct CacheKey: Hashable {
        var icon: SVGIcon
        var px: Int
        var tintKey: String
        var mirrored: Bool
    }

    private struct CacheEntry {
        var image: DecodedImage
        var byteCost: Int
        var used: Bool
    }

    private let lock = NSLock()
    private var cache: [CacheKey: CacheEntry] = [:]
    private var totalBytes: Int = 0

    public init() {}

    public func beginFrame() {
        lock.lock()
        if totalBytes > Self.budgetBytes {
            cache = cache.filter { $0.value.used }
            totalBytes = cache.values.reduce(0) { $0 + $1.byteCost }
        }
        for key in cache.keys {
            cache[key]?.used = false
        }
        lock.unlock()
    }

    /// Rasterizes a multi-color `SVGIcon` (or silhouette in `oneColor`) into a `DecodedImage` (`RGBA8` premultiplied).
    /// Returns `nil` when the icon is strictly monochrome and `oneColor == nil`.
    public func rasterize(
        _ icon: SVGIcon,
        pixelSize: Int,
        currentColor: Color = .white,
        oneColor: Color? = nil,
        mirrored: Bool = false
    ) -> DecodedImage? {
        guard icon.isColorIcon || oneColor != nil, let body = icon.body else {
            return nil
        }
        let px = max(1, pixelSize)
        let tintHex: String
        if let one = oneColor {
            tintHex = "one:\(one.hexKey)"
        } else if body.contains("currentColor") {
            tintHex = currentColor.hexKey
        } else {
            tintHex = ""
        }

        let key = CacheKey(icon: icon, px: px, tintKey: tintHex, mirrored: mirrored)
        lock.lock()
        if var entry = cache[key] {
            entry.used = true
            cache[key] = entry
            lock.unlock()
            return entry.image
        }
        lock.unlock()

        guard var rgba = renderRGBA(body: body, viewBox: icon.viewBox, px: px, currentColor: currentColor, oneColor: oneColor) else {
            return nil
        }
        if mirrored && px > 1 && rgba.count >= px * px * 4 {
            for row in 0..<px {
                let rowBase = row * px * 4
                for col in 0..<(px / 2) {
                    let a = rowBase + col * 4
                    let b = rowBase + (px - 1 - col) * 4
                    for c in 0..<4 {
                        rgba.swapAt(a + c, b + c)
                    }
                }
            }
        }

        let mips = DecodedImage.generateMipChain(width: UInt32(px), height: UInt32(px), rgba: Data(rgba))
        let decoded = DecodedImage(
            id: "color-icon:\(key.hashValue)",
            width: UInt32(px),
            height: UInt32(px),
            mips: mips
        )
        let byteCost = mips.reduce(0) { $0 + $1.rgba.count }

        lock.lock()
        cache[key] = CacheEntry(image: decoded, byteCost: byteCost, used: true)
        totalBytes += byteCost
        lock.unlock()
        return decoded
    }

    private func renderRGBA(
        body: String,
        viewBox: Float,
        px: Int,
        currentColor: Color,
        oneColor: Color?
    ) -> [UInt8]? {
        let parsed = SVGIconRenderer.parseBody(body)
        guard !parsed.commands.isEmpty else { return nil }

        #if canImport(CoreGraphics)
        var bytes = [UInt8](repeating: 0, count: px * px * 4)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &bytes,
            width: px,
            height: px,
            bitsPerComponent: 8,
            bytesPerRow: px * 4,
            space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.translateBy(x: 0, y: CGFloat(px))
        let scale = CGFloat(px) / CGFloat(viewBox)
        ctx.scaleBy(x: scale, y: -scale)

        func cgColor(_ color: Color, opacity: Float) -> CGColor {
            let comps = color.alpha(color.a * opacity).srgbComponents
            return CGColor(
                colorSpace: srgb,
                components: [CGFloat(comps.r), CGFloat(comps.g), CGFloat(comps.b), CGFloat(comps.a)]
            ) ?? CGColor(gray: 1.0, alpha: 1.0)
        }

        for cmd in parsed.commands {
            ctx.saveGState()
            let t = cmd.transform
            ctx.concatenate(CGAffineTransform(
                a: CGFloat(t[0]), b: CGFloat(t[1]),
                c: CGFloat(t[2]), d: CGFloat(t[3]),
                tx: CGFloat(t[4]), ty: CGFloat(t[5])
            ))
            let cgPath = GlyphAtlas.parseSVGPath(cmd.pathData)

            switch cmd.fill {
            case .none:
                break
            case .solid(let col):
                ctx.addPath(cgPath)
                ctx.setFillColor(cgColor(col, opacity: cmd.fillOpacity * cmd.opacity))
                ctx.fillPath(using: cmd.evenOdd ? .evenOdd : .winding)
            case .currentColor:
                ctx.addPath(cgPath)
                ctx.setFillColor(cgColor(currentColor, opacity: cmd.fillOpacity * cmd.opacity))
                ctx.fillPath(using: cmd.evenOdd ? .evenOdd : .winding)
            case .gradient(let gradId):
                if let grad = parsed.gradients[gradId], !grad.stops.isEmpty {
                    let gradColors = grad.stops.map { cgColor($0.color, opacity: cmd.fillOpacity * cmd.opacity) } as CFArray
                    let locs = grad.stops.map { CGFloat($0.offset) }
                    if let cgGrad = CGGradient(colorsSpace: srgb, colors: gradColors, locations: locs) {
                        ctx.saveGState()
                        ctx.addPath(cgPath)
                        if cmd.evenOdd { ctx.clip(using: .evenOdd) } else { ctx.clip() }
                        let bb = cgPath.boundingBox
                        let p1 = CGPoint(x: bb.minX + CGFloat(grad.x1) * bb.width, y: bb.minY + CGFloat(grad.y1) * bb.height)
                        let p2 = CGPoint(x: bb.minX + CGFloat(grad.x2) * bb.width, y: bb.minY + CGFloat(grad.y2) * bb.height)
                        ctx.drawLinearGradient(cgGrad, start: p1, end: p2, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                        ctx.restoreGState()
                    }
                }
            }

            if let stroke = cmd.stroke, cmd.strokeWidth > 0 {
                let strokeCol: Color?
                switch stroke {
                case .none: strokeCol = nil
                case .solid(let c): strokeCol = c
                case .currentColor: strokeCol = currentColor
                case .gradient(let id): strokeCol = parsed.gradients[id]?.stops.first?.color ?? currentColor
                }
                if let strokeCol {
                    ctx.addPath(cgPath)
                    ctx.setStrokeColor(cgColor(strokeCol, opacity: cmd.strokeOpacity * cmd.opacity))
                    ctx.setLineWidth(CGFloat(cmd.strokeWidth))
                    ctx.setLineCap(cmd.lineCap == "round" ? .round : (cmd.lineCap == "square" ? .square : .butt))
                    ctx.setLineJoin(cmd.lineJoin == "round" ? .round : (cmd.lineJoin == "bevel" ? .bevel : .miter))
                    ctx.strokePath()
                }
            }
            ctx.restoreGState()
        }

        // Convert to one-color silhouette preserving rendered alpha coverage (`color_icon.rs:107-110`)
        if let one = oneColor {
            let c = one.srgbComponents
            let rByte = UInt8(min(255, max(0, (c.r * 255.0).rounded())))
            let gByte = UInt8(min(255, max(0, (c.g * 255.0).rounded())))
            let bByte = UInt8(min(255, max(0, (c.b * 255.0).rounded())))
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let a = Float(bytes[i + 3]) / 255.0
                bytes[i] = UInt8((Float(rByte) * a).rounded())
                bytes[i + 1] = UInt8((Float(gByte) * a).rounded())
                bytes[i + 2] = UInt8((Float(bByte) * a).rounded())
            }
        }
        return bytes
        #else
        let paths = SVGIconRenderer.extractPathStrings(fromBody: body)
        let alpha = PortableSVGRasterizer.rasterize(SVGIcon(viewBox: viewBox, paths: paths, strokeWidth: nil), pixelSize: px)
        let tint = oneColor ?? currentColor
        let c = tint.srgbComponents
        var out = [UInt8](repeating: 0, count: px * px * 4)
        for i in 0..<(px * px) {
            let a = alpha[i]
            let af = Float(a) / 255.0
            out[i * 4 + 0] = UInt8((c.r * 255.0 * af).rounded())
            out[i * 4 + 1] = UInt8((c.g * 255.0 * af).rounded())
            out[i * 4 + 2] = UInt8((c.b * 255.0 * af).rounded())
            out[i * 4 + 3] = a
        }
        return out
        #endif
    }
}

private extension Color {
    var srgbComponents: (r: Float, g: Float, b: Float, a: Float) {
        func encode(_ v: Float) -> Float {
            let c = max(0, min(1, v))
            if c <= 0.0031308 { return c * 12.92 }
            return 1.055 * powf(c, 1.0 / 2.4) - 0.055
        }
        return (encode(r), encode(g), encode(b), max(0, min(1, a)))
    }

    var hexKey: String {
        let s = srgbComponents
        let ri = Int((s.r * 255.0).rounded())
        let gi = Int((s.g * 255.0).rounded())
        let bi = Int((s.b * 255.0).rounded())
        let ai = Int((s.a * 255.0).rounded())
        return String(format: "#%02x%02x%02x%02x", ri, gi, bi, ai)
    }
}
