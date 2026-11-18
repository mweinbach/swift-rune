import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - 1. Font Epoch & Family Slot Registry (rune::text::measure + families)

/// Cache epoch for the current font families. Ending a scoped override restores the enclosing epoch.
public func fontEpoch() -> UInt64 {
    FontFamiliesRegistry.currentEpoch()
}

/// Temporarily overrides the font families used by this thread, including changes made inside the closure.
public func withFontFamilies(sans: String, mono: String, _ body: () throws -> Void) rethrows {
    try FontFamiliesRegistry.withFamilies(sans: sans, mono: mono, body)
}

public enum FontFamiliesRegistry {
    internal struct State {
        var sans: String
        var mono: String
        var epoch: UInt64

        func matches(sans: String, mono: String) -> Bool {
            TextUTF8Key.equalBytes(self.sans, sans) && TextUTF8Key.equalBytes(self.mono, mono)
        }
    }

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var defaults = State(sans: "", mono: "", epoch: 1)
        var nextEpoch: UInt64 = 1
        var settingsEpoch: UInt64 = 1

        func allocateEpoch() -> UInt64 {
            nextEpoch &+= 1
            return nextEpoch
        }
    }

    private static let storage = Storage()
    private static let overrideKey = "rune.fontFamilies.override"

    internal static var threadOverride: State? {
        get { RuneExecutionContext.locals[overrideKey] as? State }
        set {
            if let newValue {
                RuneExecutionContext.locals[overrideKey] = newValue
            } else {
                RuneExecutionContext.locals.removeObject(forKey: overrideKey)
            }
        }
    }

    private static let windowKey = "rune.fontFamilies.windows"
    internal static var windowChoice: State? {
        RuneExecutionContext.locals[windowKey] as? State
    }

    internal static var settingsEpoch: UInt64 {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.settingsEpoch
    }

    internal static func makeState(sans: String, mono: String) -> State {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return State(sans: sans, mono: mono, epoch: storage.allocateEpoch())
    }

    internal static func chooseWindowFamilies(sans: String, mono: String) {
        if let choice = windowChoice, choice.matches(sans: sans, mono: mono) { return }
        RuneExecutionContext.locals[windowKey] = makeState(sans: sans, mono: mono)
    }

    internal static func snapshot() -> State {
        if let threadOverride { return threadOverride }
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.defaults
    }

    public static func currentEpoch() -> UInt64 { snapshot().epoch }

    /// Invalidates font-dependent caches when process-wide settings or registered faces change.
    @discardableResult
    public static func bumpEpoch() -> UInt64 {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        storage.settingsEpoch = storage.allocateEpoch()
        storage.defaults.epoch = storage.settingsEpoch
        if var state = threadOverride {
            state.epoch = storage.allocateEpoch()
            threadOverride = state
            return state.epoch
        }
        return storage.defaults.epoch
    }

    public static func currentFamilies() -> (sans: String, mono: String) {
        let state = snapshot()
        return (state.sans, state.mono)
    }

    @discardableResult
    public static func setFamilies(sans: String, mono: String) -> Bool {
        let scoped = threadOverride
        storage.lock.lock()
        defer { storage.lock.unlock() }
        let previous = scoped ?? storage.defaults
        guard !previous.matches(sans: sans, mono: mono) else { return false }
        let state = State(sans: sans, mono: mono, epoch: storage.allocateEpoch())
        if scoped != nil {
            threadOverride = state
        } else {
            storage.defaults = state
        }
        return true
    }

    public static func withFamilies(sans: String, mono: String, _ body: () throws -> Void) rethrows {
        let previous = threadOverride
        let previousWindowChoice = windowChoice
        storage.lock.lock()
        let epoch = storage.allocateEpoch()
        storage.lock.unlock()
        threadOverride = State(sans: sans, mono: mono, epoch: epoch)
        defer {
            threadOverride = previous
            if let previousWindowChoice {
                RuneExecutionContext.locals[windowKey] = previousWindowChoice
            } else {
                RuneExecutionContext.locals.removeObject(forKey: windowKey)
            }
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
    internal let authored: String
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
        self.authored = source
        self.bounds = pairs
    }

    /// Displayed UTF-8 byte offset where source byte `offset` starts (`up == false`),
    /// or its end when inside an expanding scalar (`up == true`, matching `Source::shown`).
    public func displayedOffset(forSourceUTF8Offset offset: Int, up: Bool = false) -> Int {
        bound(at: offset, by: \.sourceByte, up: up).displayedByte
    }

    /// Source UTF-8 byte offset of the scalar drawn at displayed byte `offset` (`up == false`),
    /// or the next scalar's start when inside an expanded scalar (`up == true`, matching `Source::source`).
    public func sourceOffset(forDisplayedUTF8Offset offset: Int, up: Bool = false) -> Int {
        bound(at: offset, by: \.displayedByte, up: up).sourceByte
    }

    private func bound(at offset: Int, by coordinate: KeyPath<Bound, Int>, up: Bool) -> Bound {
        // Both byte columns are sorted and include the end sentinel.
        var lo = 0
        var hi = bounds.count - 1
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if bounds[mid][keyPath: coordinate] < offset {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if !up && lo > 0 && bounds[lo][keyPath: coordinate] > offset { lo -= 1 }
        return bounds[lo]
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
            // This flag selects the app's mono slot. An inherited systemMono run keeps its own face.
            var monospace = (base.family == .monospace)
            var underline = false
            var strikethrough = false
            var pad: Float = 0

            for sp in snappedSpans where sp.byteRange.lowerBound <= a && b <= sp.byteRange.upperBound {
                if let c = sp.color { color = c }
                if let bCol = sp.background { bg = bCol; pad = sp.pad }
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
                size: size,
                pad: pad
            )

            if var prev = merged.last,
               prev.color == span.color,
               prev.background == span.background,
               prev.weight == span.weight,
               prev.size == span.size,
               prev.italic == span.italic,
               prev.monospace == span.monospace,
               prev.underline == span.underline,
               prev.strikethrough == span.strikethrough,
               prev.pad == span.pad {
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
    /// Clip each mark to the bytes of its paragraph. Its quads are returned in device
    /// pixels at the field's drawn origin, including its transform and raster scale.
    internal static func fieldQuads(
        marks: [TextHighlight], box: TextLayoutBox, system: TextSystem,
        origin: Vec2, transform: Vec2, pixelScale: Float
    ) -> [HighlightQuad] {
        guard !marks.isEmpty else { return [] }
        let scale = box.pixelScale
        var result: [HighlightQuad] = []
        func append(_ marks: [TextHighlight], from layout: TextLayoutBox, at y: Float) {
            for var q in quads(highlights: marks, in: layout.authText, shaped: layout.shaped, textSystem: system, pixelScale: scale) {
                q.rect.x = (origin.x + transform.x * q.rect.x / scale) * pixelScale
                q.rect.y = (origin.y + transform.y * (q.rect.y + y) / scale) * pixelScale
                q.rect.z *= transform.x * pixelScale / scale
                q.rect.w *= transform.y * pixelScale / scale
                q.cornerRadius *= transform.x * pixelScale / scale
                q.ring?.width *= transform.x * pixelScale / scale
                result.append(q)
            }
        }
        if let paragraphs = box.paragraphs {
            for mark in marks {
                let range = mark.byteRange
                let first = partitionPoint(paragraphs.paragraphs) { $0.end <= range.lowerBound }
                for p in paragraphs.paragraphs[first...].prefix(while: { $0.start < range.upperBound }) where p.shaped {
                    let start = max(range.lowerBound, p.start)
                    let end = min(range.upperBound, p.end)
                    guard start < end else { continue }
                    var local = mark
                    local.byteRange = (start - p.start)..<(end - p.start)
                    append([local], from: p.layout, at: p.y)
                }
            }
        } else {
            append(marks, from: box, at: 0)
        }
        return result
    }

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
            let rawA = min(h.byteRange.lowerBound, len)
            let rawB = min(h.byteRange.upperBound, len)
            guard rawA < rawB, h.bg.a > 0 || h.ring != nil else { continue }
            let pad = h.pad * pixelScale
            let ring = h.ring.map { TextRing(color: $0.color, width: $0.width * pixelScale) }
            let boxes = textSystem.selectionRects(in: shaped, utf8Range: rawA..<rawB, pixelScale: pixelScale)
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
        public var usesCurrentColor = false

        func resolvedColor(_ currentColor: Color) -> Color {
            usesCurrentColor ? currentColor.alpha(currentColor.a * color.a) : color
        }
    }

    public struct LinearGradient: Sendable, Equatable {
        public var id: String
        public var x1: Float
        public var y1: Float
        public var x2: Float
        public var y2: Float
        public var stops: [PaintStop]
        public var usesUserSpace = false
        public var transform: [Float] = [1, 0, 0, 1, 0, 0]
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
        parseBody(body, defaultFill: "currentColor")
    }

    static func parseBody(_ body: String, defaultFill: String) -> ParsedBody {
        var gradients: [String: LinearGradient] = [:]
        var activeGradient: LinearGradient? = nil

        struct Scope {
            var tag: String
            var transform: [Float]
            var paints: Bool
            var opacity: Float
            var inheritedAttrs: [String: String]
        }

        let identity: [Float] = [1, 0, 0, 1, 0, 0]
        var scopes = [Scope(tag: "", transform: identity, paints: true, opacity: 1, inheritedAttrs: ["fill": defaultFill])]
        var commands: [DrawCommand] = []

        let inheritedKeys = Set([
            "color", "fill", "stroke", "stroke-width", "stroke-linecap",
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
                }
                if scopes.count > 1 && scopes.last?.tag == endTag {
                    scopes.removeLast()
                }
                continue
            }

            let isSelfClosing = raw.hasSuffix("/")
            let bodyTag = raw.dropFirst(raw.hasPrefix("<") ? 1 : 0)
            let tag = bodyTag.split(whereSeparator: { $0.isWhitespace || $0 == "/" }).first.map { String($0).lowercased() } ?? ""
            let attrs = attributes(in: raw)
            let parent = scopes.last!
            let ownTransform = attrs["transform"].map(parseTransform) ?? identity
            let composedTransform = multiply(ownTransform, parent.transform)
            let nonRendering = ["defs", "clippath", "mask", "symbol", "lineargradient"].contains(tag)
            let paints = parent.paints && attrs["display"] != "none" && !nonRendering
            let combinedOpacity = parent.opacity * opacity(attrs["opacity"])

            var mergedAttrs = parent.inheritedAttrs
            for (key, value) in attrs where inheritedKeys.contains(key) && value != "inherit" {
                if key != "color" || value.lowercased() != "currentcolor" { mergedAttrs[key] = value }
            }
            let inheritedColor = mergedAttrs["color"].flatMap(parseColor)
            if !isSelfClosing && (nonRendering || tag == "g" || tag == "a" || tag == "svg") {
                scopes.append(Scope(tag: tag, transform: composedTransform, paints: paints,
                                    opacity: combinedOpacity, inheritedAttrs: mergedAttrs))
            }

            if tag == "lineargradient" {
                let id = attrs["id"] ?? ""
                let x1 = parseLengthOrPercent(attrs["x1"], defaultValue: 0)
                let y1 = parseLengthOrPercent(attrs["y1"], defaultValue: 0)
                let x2 = parseLengthOrPercent(attrs["x2"], defaultValue: 1)
                let y2 = parseLengthOrPercent(attrs["y2"], defaultValue: 0)
                let grad = LinearGradient(id: id, x1: x1, y1: y1, x2: x2, y2: y2, stops: [],
                                          usesUserSpace: attrs["gradientUnits"] == "userSpaceOnUse",
                                          transform: attrs["gradientTransform"].map(parseTransform) ?? identity)
                if isSelfClosing {
                    gradients[id] = grad
                } else {
                    activeGradient = grad
                }
                continue
            }

            if tag == "stop", activeGradient != nil {
                let off = parseLengthOrPercent(attrs["offset"], defaultValue: 0)
                let offset = max(activeGradient?.stops.last?.offset ?? 0, min(1, off))
                let value = attrs["stop-color"] ?? "black"
                let isCurrent = value.lowercased() == "currentcolor"
                let color = (isCurrent ? inheritedColor : parseColor(value)) ?? .black
                activeGradient?.stops.append(PaintStop(offset: offset, color: color.alpha(color.a * opacity(attrs["stop-opacity"])),
                                                       usesCurrentColor: isCurrent && inheritedColor == nil))
                continue
            }

            guard paints, let d = elementPathData(tag: tag, attributes: attrs) else {
                continue
            }

            let fillStyle = parseFillStyle(mergedAttrs["fill"] ?? defaultFill, currentColor: inheritedColor)
            let fillOpacity = opacity(mergedAttrs["fill-opacity"])
            let evenOdd = (mergedAttrs["fill-rule"] == "evenodd")

            let strokeAttr = mergedAttrs["stroke"]
            let strokeStyle = strokeAttr.flatMap { value -> FillStyle? in
                value == "none" ? nil : parseFillStyle(value, currentColor: inheritedColor)
            }
            let strokeWidth = Float((mergedAttrs["stroke-width"] ?? "").replacingOccurrences(of: "px", with: "")) ?? 1.0
            let strokeOpacity = opacity(mergedAttrs["stroke-opacity"])
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
        attributes(in: element)[key]
    }

    private static func attributes(in element: String) -> [String: String] {
        var attributes: [String: String] = [:]
        var tail = element.drop(while: { !$0.isWhitespace })
        while !tail.isEmpty {
            tail = tail.drop(while: \.isWhitespace)
            let name = tail.prefix { !$0.isWhitespace && $0 != "=" && $0 != "/" && $0 != ">" }
            guard !name.isEmpty else { break }
            tail = tail[name.endIndex...].drop(while: \.isWhitespace)
            guard tail.first == "=" else { break }
            tail = tail.dropFirst().drop(while: \.isWhitespace)
            guard let quote = tail.first, quote == "\"" || quote == "'" else { break }
            tail = tail.dropFirst()
            guard let end = tail.firstIndex(of: quote) else { break }
            attributes[String(name)] = String(tail[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            tail = tail[tail.index(after: end)...]
        }
        return attributes
    }

    private static func elementPathData(tag: String, attributes: [String: String]) -> String? {
        func num(_ name: String) -> Float {
            guard let raw = attributes[name], let value = Float(raw.replacingOccurrences(of: "px", with: "")),
                  value.isFinite else { return 0 }
            return value
        }
        switch tag {
        case "path":
            return attributes["d"]
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
            guard let ptsRaw = attributes["points"] else { return nil }
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
                if let val = Float(cur), val.isFinite { out.append(val) }
                cur.removeAll(keepingCapacity: true)
            }
            if c != "," && !c.isWhitespace {
                cur.append(c)
            }
            prev = c
        }
        if let val = Float(cur), val.isFinite { out.append(val) }
        return out
    }

    private static func parseLengthOrPercent(_ raw: String?, defaultValue: Float) -> Float {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return defaultValue
        }
        let percent = raw.hasSuffix("%")
        let number = raw.dropLast(percent ? 1 : (raw.hasSuffix("px") ? 2 : 0))
        guard let value = Float(number), value.isFinite else { return defaultValue }
        return percent ? value / 100 : value
    }

    private static func opacity(_ value: String?) -> Float {
        min(1, max(0, parseLengthOrPercent(value, defaultValue: 1)))
    }

    static func parseFillStyle(_ value: String, currentColor: Color? = nil) -> FillStyle {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "none" { return .none }
        if trimmed.lowercased() == "currentcolor" { return currentColor.map(FillStyle.solid) ?? .currentColor }
        if trimmed.hasPrefix("url(#"), trimmed.hasSuffix(")") {
            let id = String(trimmed.dropFirst(5).dropLast())
            return .gradient(id)
        }
        if let col = parseColor(trimmed) {
            return .solid(col)
        }
        return currentColor.map(FillStyle.solid) ?? .currentColor
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
        case "transparent": return .transparent
        case "black": return .black
        case "white": return .white
        case "silver": return .rgba8(192, 192, 192, 255)
        case "gray", "grey": return .rgba8(128, 128, 128, 255)
        case "maroon": return .rgba8(128, 0, 0, 255)
        case "red": return .rgba8(255, 0, 0, 255)
        case "purple": return .rgba8(128, 0, 128, 255)
        case "fuchsia", "magenta": return .rgba8(255, 0, 255, 255)
        case "green": return .rgba8(0, 128, 0, 255)
        case "lime": return .rgba8(0, 255, 0, 255)
        case "olive": return .rgba8(128, 128, 0, 255)
        case "yellow": return .rgba8(255, 255, 0, 255)
        case "navy": return .rgba8(0, 0, 128, 255)
        case "blue": return .rgba8(0, 0, 255, 255)
        case "teal": return .rgba8(0, 128, 128, 255)
        case "aqua", "cyan": return .rgba8(0, 255, 255, 255)
        case "orange": return .rgba8(255, 165, 0, 255)
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
        guard px <= LinearMipGenerator.maxDecodeDimension, icon.viewBox.isFinite, icon.viewBox > 0 else { return nil }
        let tintKey = currentColor.hexKey + (oneColor.map { "/" + $0.hexKey } ?? "")
        let key = CacheKey(icon: icon, px: px, tintKey: tintKey, mirrored: mirrored)
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
        let previous = cache.updateValue(CacheEntry(image: decoded, byteCost: byteCost, used: true), forKey: key)
        totalBytes += byteCost - (previous?.byteCost ?? 0)
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
        let scale = Float(px) / viewBox
        var rgba = SVGIconRenderer.rasterize(parsed, width: px, height: px,
                                             transform: .scale(scale, scale), currentColor: currentColor)
        if let tint = oneColor {
            let color = tint.srgbComponents
            let rgb = SIMD3<UInt8>(UInt8((color.r * 255).rounded()), UInt8((color.g * 255).rounded()),
                                   UInt8((color.b * 255).rounded()))
            for i in stride(from: 0, to: rgba.count, by: 4) where rgba[i + 3] > 0 {
                rgba[i] = rgb.x
                rgba[i + 1] = rgb.y
                rgba[i + 2] = rgb.z
            }
        }
        return rgba
    }
}

extension SVGIconRenderer {
    /// Composites SVG paint commands into the straight sRGB pixels consumed by the mip generator.
    internal static func rasterize(_ parsed: ParsedBody, width: Int, height: Int,
                                   transform: GTransform, currentColor: Color) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var mask = [UInt8](repeating: 0, count: width * height)

        for command in parsed.commands {
            let t = command.transform
            let ctm = GTransform.then(GTransform(xx: t[0], xy: t[1], yx: t[2], yy: t[3], tx: t[4], ty: t[5]), transform)
            let resolution = GPathStroker.computeResolutionScale(ctm)
            let elements = GSVGPathParser.parse(command.pathData)
            guard let path = GaneshArea.buildGPath(.path(elements), tolerance: 0.25 / resolution) else { continue }

            func draw(_ style: FillStyle, opacity: Float, pen: GStroke?, rule: GAAARule) {
                guard opacity > 0, let paint = pixelPaint(style, parsed: parsed, tint: currentColor,
                                                          bounds: path.bounds, transform: ctm) else { return }
                GaneshArea.coverage(of: path, transform: ctm, pen: pen, rule: rule,
                                    width: width, height: height, into: &mask)
                for index in mask.indices where mask[index] > 0 {
                    let pixel = index * 4
                    let source = paint.sample(index: index, width: width)
                    let alpha = min(1, source.w * opacity * Float(mask[index]) / 255)
                    guard alpha > 0 else { continue }
                    let remaining = Float(rgba[pixel + 3]) / 255 * (1 - alpha)
                    let outAlpha = alpha + remaining
                    for channel in 0..<3 {
                        let value = (source[channel] * 255 * alpha + Float(rgba[pixel + channel]) * remaining) / outAlpha
                        rgba[pixel + channel] = UInt8(clamping: Int(value.rounded()))
                    }
                    rgba[pixel + 3] = UInt8(clamping: Int((outAlpha * 255).rounded()))
                }
            }

            draw(command.fill, opacity: command.opacity * command.fillOpacity, pen: nil,
                 rule: command.evenOdd ? .evenOdd : .nonZero)
            if let stroke = command.stroke, command.strokeWidth > 0 {
                let cap: GLineCap = switch command.lineCap {
                case "round": .round
                case "square": .square
                default: .butt
                }
                let join: GLineJoin = switch command.lineJoin {
                case "round": .round
                case "bevel": .bevel
                default: .miter
                }
                let pen = GStroke(width: command.strokeWidth, miterLimit: 4, lineCap: cap, lineJoin: join)
                draw(stroke, opacity: command.opacity * command.strokeOpacity, pen: pen, rule: .nonZero)
            }
        }
        return rgba
    }

    private enum PixelPaint {
        case solid(SIMD4<Float>)
        case linear(step: GPoint, bias: Float, stops: [(Float, SIMD4<Float>)])

        func sample(index: Int, width: Int) -> SIMD4<Float> {
            switch self {
            case .solid(let rgba):
                return rgba
            case let .linear(step, bias, stops):
                let t = (Float(index % width) + 0.5) * step.x + (Float(index / width) + 0.5) * step.y + bias
                var previous = stops[0]
                for stop in stops.dropFirst() {
                    if t < stop.0 {
                        let mix = max(0, (t - previous.0) / (stop.0 - previous.0))
                        return previous.1 + (stop.1 - previous.1) * mix
                    }
                    previous = stop
                }
                return previous.1
            }
        }
    }

    private static func pixelPaint(_ style: FillStyle, parsed: ParsedBody, tint: Color,
                                   bounds: GRect, transform: GTransform) -> PixelPaint? {
        func components(_ color: Color) -> SIMD4<Float> {
            let c = color.srgbComponents
            return SIMD4(c.r, c.g, c.b, c.a)
        }

        switch style {
        case .none: return nil
        case .solid(let color): return .solid(components(color))
        case .currentColor: return .solid(components(tint))
        case .gradient(let id):
            guard let gradient = parsed.gradients[id], !gradient.stops.isEmpty else { return nil }
            let stops = gradient.stops.map { ($0.offset, components($0.resolvedColor(tint))) }
            let t = gradient.transform
            var ctm = GTransform(xx: t[0], xy: t[1], yx: t[2], yy: t[3], tx: t[4], ty: t[5])
            if !gradient.usesUserSpace {
                let box = GTransform(xx: bounds.width, xy: 0, yx: 0, yy: bounds.height,
                                     tx: bounds.left, ty: bounds.top)
                ctm = .then(ctm, box)
            }
            ctm = .then(ctm, transform)
            let direction = GPoint(x: gradient.x2 - gradient.x1, y: gradient.y2 - gradient.y1)
            let divisor = (ctm.xx * ctm.yy - ctm.xy * ctm.yx) * direction.lengthSqd
            guard divisor.isFinite, divisor != 0 else { return .solid(stops[stops.count - 1].1) }
            // The gradient runs in SVG coordinates. Map its projection into device space once per shape.
            let step = GPoint(x: (ctm.yy * direction.x - ctm.xy * direction.y) / divisor,
                              y: (ctm.xx * direction.y - ctm.yx * direction.x) / divisor)
            let start = ctm.transformPoint(GPoint(x: gradient.x1, y: gradient.y1))
            return .linear(step: step, bias: -start.dot(step), stops: stops)
        }
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
