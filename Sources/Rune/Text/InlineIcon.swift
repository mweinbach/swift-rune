import Foundation
import RuneMotion
import RuneRef

/// Minimal standalone vector/image icon descriptor (`rune::el::BareIcon`) used by inline pills and badges.
public struct BareIcon: Sendable, Hashable {
    public var svg: SVGIcon?
    public var image: RGBA8Atlas?
    public var size: Float
    public var gap: Float
    public var radius: Float
    public var color: Color?

    public init(_ svg: SVGIcon, size: Float = 14.0, color: Color? = nil, gap: Float = 4.0, radius: Float = 0.0) {
        self.svg = svg
        self.image = nil
        self.size = max(1.0, size)
        self.gap = max(0.0, gap)
        self.radius = max(0.0, radius)
        self.color = color
    }

    public init(image: RGBA8Atlas, size: Float = 14.0, gap: Float = 4.0, radius: Float = 0.0) {
        self.svg = nil
        self.image = image
        self.size = max(1.0, size)
        self.gap = max(0.0, gap)
        self.radius = max(0.0, radius)
        self.color = nil
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(svg)
        hasher.combine(image?.width)
        hasher.combine(image?.height)
        hasher.combine(image?.texels)
        hasher.combine(size)
        hasher.combine(gap)
        hasher.combine(radius)
        hasher.combine(color)
    }
}

/// Visual styling for an inline rounded pill span (`rune::el::PillStyle`).
public struct PillStyle: Sendable, Hashable {
    public var background: Color?
    public var ring: TextRing?
    public var color: Color?
    public var pad: Float
    public var gap: Float
    public var bold: Bool
    public var italic: Bool
    public var mono: Bool
    public var icon: BareIcon?

    public init(
        background: Color? = Color(r: 0.22, g: 0.25, b: 0.32, a: 0.22),
        ring: TextRing? = nil,
        color: Color? = nil,
        pad: Float = 4.0,
        gap: Float = 4.0,
        bold: Bool = false,
        italic: Bool = false,
        mono: Bool = false,
        icon: BareIcon? = nil
    ) {
        self.background = background
        self.ring = ring
        self.color = color
        self.pad = max(0, pad)
        self.gap = max(0, gap)
        self.bold = bold
        self.italic = italic
        self.mono = mono
        self.icon = icon
    }

    public static let `default` = PillStyle()

    public static func tint(_ color: Color, backgroundAlpha: Float = 0.16, ringAlpha: Float = 0.35) -> PillStyle {
        PillStyle(
            background: Color(r: color.r, g: color.g, b: color.b, a: backgroundAlpha),
            ring: TextRing(color: Color(r: color.r, g: color.g, b: color.b, a: ringAlpha), width: 1.0),
            color: color
        )
    }

    public func bg(_ c: Color) -> PillStyle { var s = self; s.background = c; return s }
    public func fg(_ c: Color) -> PillStyle { var s = self; s.color = c; return s }
    public func ring(_ c: Color, width: Float = 1.0) -> PillStyle { var s = self; s.ring = TextRing(color: c, width: width); return s }
    public func color(_ c: Color) -> PillStyle { var s = self; s.color = c; return s }
    public func pad(_ p: Float) -> PillStyle { var s = self; s.pad = max(0, p); return s }
    public func gap(_ g: Float) -> PillStyle { var s = self; s.gap = max(0, g); return s }
    public func bold(_ on: Bool = true) -> PillStyle { var s = self; s.bold = on; return s }
    public func italic(_ on: Bool = true) -> PillStyle { var s = self; s.italic = on; return s }
    public func mono(_ on: Bool = true) -> PillStyle { var s = self; s.mono = on; return s }
    public func icon(_ icon: SVGIcon, size: Float = 12.0, color: Color? = nil) -> PillStyle {
        var s = self
        s.icon = BareIcon(icon, size: size, color: color)
        return s
    }
}

/// Byte-ranged inline pill or bare inline-icon descriptor (`rune::text::PillChip`).
public struct PillChip: Sendable, Hashable {
    public var range: Range<Int>
    public var style: PillStyle
    public var icon: BareIcon?
    public var isBare: Bool
    public var bareGap: Float
    public var bareRadius: Float
    public var bareImage: RGBA8Atlas?

    public init(
        _ range: Range<Int>,
        style: PillStyle = .default,
        icon: BareIcon? = nil,
        isBare: Bool = false,
        bareGap: Float = 0.0,
        bareRadius: Float = 0.0,
        bareImage: RGBA8Atlas? = nil
    ) {
        let lower = max(0, range.lowerBound)
        let upper = max(lower, range.upperBound)
        self.range = lower..<upper
        self.style = style
        self.icon = icon ?? style.icon
        self.isBare = isBare
        self.bareGap = max(0, bareGap)
        self.bareRadius = max(0, bareRadius)
        self.bareImage = bareImage ?? icon?.image
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(range)
        hasher.combine(style)
        hasher.combine(icon)
        hasher.combine(isBare)
        hasher.combine(bareGap)
        hasher.combine(bareRadius)
        hasher.combine(bareImage?.width)
        hasher.combine(bareImage?.height)
        hasher.combine(bareImage?.texels)
    }
}

/// An icon set inline in text by `El.inlineIcon` (`crates/rune/src/el/pills.rs`).
public struct InlineIcon: Sendable, Hashable {
    public var byteOffset: Int
    public var icon: SVGIcon?
    public var image: RGBA8Atlas?
    public var size: Float
    public var color: Color?
    public var gap: Float
    public var radius: Float

    /// Minimum advance reserve for wrapping calculation (`size + gap`).
    public var reserveWidth: Float { size + gap }

    public init(
        byteOffset: Int = 0,
        icon: SVGIcon,
        size: Float = 14.0,
        color: Color? = nil,
        gap: Float = 4.0,
        radius: Float = 0.0
    ) {
        self.byteOffset = max(0, byteOffset)
        self.icon = icon
        self.image = nil
        self.size = size.isFinite ? max(0.0, size) : 0.0
        self.color = color
        self.gap = gap.isFinite ? max(0.0, gap) : 0.0
        self.radius = radius.isFinite ? max(0.0, radius) : 0.0
    }

    public init(
        image: RGBA8Atlas,
        size: Float = 14.0,
        gap: Float = 4.0,
        radius: Float = 0.0
    ) {
        self.byteOffset = 0
        self.icon = nil
        self.image = image
        self.size = size.isFinite ? max(0.0, size) : 0.0
        self.color = nil
        self.gap = gap.isFinite ? max(0.0, gap) : 0.0
        self.radius = radius.isFinite ? max(0.0, radius) : 0.0
    }

    public static func glyph(_ svg: SVGIcon) -> InlineIcon {
        InlineIcon(icon: svg, size: 14.0, color: nil, gap: 4.0, radius: 0.0)
    }

    public static func image(_ pixels: RGBA8Atlas) -> InlineIcon {
        InlineIcon(image: pixels, size: 14.0, gap: 4.0, radius: 0.0)
    }

    public func size(_ points: Float) -> InlineIcon {
        var copy = self
        copy.size = points.isFinite ? max(0.0, points) : 0.0
        return copy
    }

    public func gap(_ points: Float) -> InlineIcon {
        var copy = self
        copy.gap = points.isFinite ? max(0.0, points) : 0.0
        return copy
    }

    public func radius(_ points: Float) -> InlineIcon {
        var copy = self
        copy.radius = points.isFinite ? max(0.0, points) : 0.0
        return copy
    }

    public func color(_ c: Color) -> InlineIcon {
        var copy = self
        copy.color = c
        return copy
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(byteOffset)
        hasher.combine(icon)
        hasher.combine(image?.width)
        hasher.combine(image?.height)
        hasher.combine(image?.texels)
        hasher.combine(size)
        hasher.combine(color)
        hasher.combine(gap)
        hasher.combine(radius)
    }
}

/// Placed inline icon geometry inside shaped text bounds.
public struct PlacedInlineIcon: Sendable, Equatable {
    public var inlineIcon: InlineIcon
    /// UTF-8 byte index in `sourceText` where the icon sits.
    public var byteOffset: Int
    /// Zero-based wrapped line index in the shaped text layout.
    public var lineIndex: Int
    /// Drawable icon frame in local text coordinates.
    public var rect: MotionRect
    /// Full reserved advance span (including trailing `gap`).
    public var reservedWidth: Float
}

/// Layout and validation helper for `InlineIcon` and `PillChip` inside wrapped/unwrapped text (`crates/rune/src/el/pills.rs`).
public enum InlineIconLayout {
    /// Returns `true` iff `offset` lies on a valid UTF-8 scalar boundary in `text` (`0...text.utf8.count`).
    public static func isUTF8Boundary(_ offset: Int, in text: String) -> Bool {
        let utf8 = text.utf8
        guard offset >= 0, offset <= utf8.count else { return false }
        if offset == 0 || offset == utf8.count { return true }
        let idx = utf8.index(utf8.startIndex, offsetBy: offset)
        return String.Index(idx, within: text) != nil
    }

    /// Snaps an arbitrary byte offset downward to the nearest valid UTF-8 scalar boundary in `text`.
    public static func snapUTF8Boundary(_ offset: Int, in text: String) -> Int {
        let count = text.utf8.count
        var cur = min(max(0, offset), count)
        let utf8 = text.utf8
        while cur > 0 {
            let idx = utf8.index(utf8.startIndex, offsetBy: cur)
            if String.Index(idx, within: text) != nil {
                return cur
            }
            cur -= 1
        }
        return 0
    }

    /// Returns `true` iff `icon` starts at a valid scalar boundary before a non-empty word
    /// and does not collide with an existing `InlineIcon` or `PillChip`.
    public static func canPlace(_ icon: InlineIcon, in text: String, existing: [InlineIcon], pills: [PillChip] = []) -> Bool {
        let count = text.utf8.count
        guard icon.byteOffset >= 0, icon.byteOffset < count, isUTF8Boundary(icon.byteOffset, in: text) else {
            return false
        }
        let wLen = wordByteLength(startingAt: icon.byteOffset, in: text)
        guard wLen > 0 else { return false }
        let end = icon.byteOffset + wLen
        if existing.contains(where: { $0.byteOffset == icon.byteOffset }) {
            return false
        }
        if pills.contains(where: { $0.range.lowerBound < end && icon.byteOffset < $0.range.upperBound }) {
            return false
        }
        return true
    }

    /// Computes UTF-8 byte length of the whitespace-delimited word starting at `byteOffset`.
    public static func wordByteLength(startingAt byteOffset: Int, in text: String) -> Int {
        let utf8 = text.utf8
        guard byteOffset >= 0, byteOffset < utf8.count, isUTF8Boundary(byteOffset, in: text) else {
            return 0
        }
        let startIdx = String.Index(utf8.index(utf8.startIndex, offsetBy: byteOffset), within: text) ?? text.endIndex
        var endIdx = startIdx
        while endIdx < text.endIndex {
            let scalar = text.unicodeScalars[endIdx]
            if scalar.properties.isWhitespace {
                break
            }
            endIdx = text.unicodeScalars.index(after: endIdx)
        }
        return text.utf8.distance(from: startIdx, to: endIdx)
    }

    /// Strips any `\u{FFFC}` inline-icon placeholder scalars so clipboard copy emits pure text (`pills.rs:51`).
    public static func copyablePlainText(from displayText: String) -> String {
        guard displayText.unicodeScalars.contains(where: { $0.value == 0xFFFC }) else {
            return displayText
        }
        var out = ""
        out.unicodeScalars.reserveCapacity(displayText.unicodeScalars.count)
        for s in displayText.unicodeScalars where s.value != 0xFFFC {
            out.unicodeScalars.append(s)
        }
        return out
    }

    /// Computes placed inline icon rects and layout size using `TextSystem` (`pills.rs:47-56`).
    public static func layout(
        text: String,
        icons: [InlineIcon],
        style: TextStyle,
        maxWidth: Float?,
        textSystem: TextSystem = TextSystem(),
        pixelScale: Float = 1.0
    ) -> (size: Vec2, placed: [PlacedInlineIcon]) {
        let chips = icons.compactMap { icon -> PillChip? in
            let wLen = wordByteLength(startingAt: icon.byteOffset, in: text)
            guard wLen > 0 else { return nil }
            let bare = icon.image.map { BareIcon(image: $0, size: icon.size, gap: icon.gap, radius: icon.radius) }
                ?? icon.icon.map { BareIcon($0, size: icon.size, color: icon.color, gap: icon.gap, radius: icon.radius) }
            return PillChip(
                icon.byteOffset..<(icon.byteOffset + wLen),
                style: PillStyle(background: nil, color: icon.color, pad: 0, gap: icon.gap),
                icon: bare,
                isBare: true,
                bareGap: icon.gap,
                bareRadius: icon.radius,
                bareImage: icon.image
            )
        }
        let shaped = textSystem.shape(
            text: text,
            spans: nil,
            pills: chips,
            style: style,
            maxWidth: maxWidth,
            pixelScale: pixelScale,
            emitGlyphs: false
        )
        let lh = max(1.0, shaped.lineHeight)
        var placed: [PlacedInlineIcon] = []
        for quad in shaped.inlineIcons {
            let lineIdx = max(0, Int(floor(quad.rect.y / lh)))
            let iconDef: InlineIcon
            if let img = quad.image {
                iconDef = InlineIcon(image: img, size: quad.rect.z, gap: quad.pill.bareGap, radius: quad.cornerRadius)
            } else {
                iconDef = InlineIcon(
                    byteOffset: quad.pill.range.lowerBound,
                    icon: quad.icon ?? SVGIcon(paths: []),
                    size: quad.rect.z,
                    color: quad.color,
                    gap: quad.pill.bareGap,
                    radius: quad.cornerRadius
                )
            }
            placed.append(PlacedInlineIcon(
                inlineIcon: iconDef,
                byteOffset: quad.pill.range.lowerBound,
                lineIndex: lineIdx,
                rect: MotionRect.fromXYWH(quad.rect.x, quad.rect.y, quad.rect.z, quad.rect.w),
                reservedWidth: quad.rect.z + quad.pill.bareGap
            ))
        }
        return (shaped.size, placed)
    }
}

/// Builds a rich text element from a base string and authored byte-ranged spans (`rune::el::rich`).
public func rich<State>(_ content: String, _ spans: [RichSpan] = []) -> El<State> {
    var node = El<State>(direction: .row)
    node.role = .text
    node.plainText = content
    node.runtimeExtras["richSpanDefs"] = spans
    node.richSpans = RichSpanFlattener.flatten(spans, in: content, base: node.textStyle)
    return node
}

extension El {
    private static func rebuildRichSpans(
        content: String,
        authoredSpans: [RichSpan],
        pills: [PillChip],
        base: TextStyle
    ) -> [TextSpan] {
        var combined = authoredSpans
        for pill in pills where !pill.isBare {
            var span = RichSpan(pill.range)
            if let fg = pill.style.color { span = span.color(fg) }
            if pill.style.bold { span = span.bold() }
            if pill.style.italic { span = span.italic(true) }
            if pill.style.mono { span = span.mono(true) }
            combined.append(span)
        }
        return RichSpanFlattener.flatten(combined, in: content, base: base)
    }

    /// Replaces rich byte-ranged spans while preserving existing pill label colors and styles (`pills/tests.rs:30`).
    public func spans(_ newSpans: [RichSpan]) -> Self {
        var copy = self
        copy.runtimeExtras["richSpanDefs"] = newSpans
        let content = copy.plainText ?? copy.richSpans?.map(\.text).joined() ?? ""
        copy.richSpans = Self.rebuildRichSpans(
            content: content,
            authoredSpans: newSpans,
            pills: copy.pillChips,
            base: copy.textStyle
        )
        return copy
    }

    /// Enables or disables justified paragraph alignment for wrapped text (`El::justify`).
    public func justify(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.textStyle.align = enabled ? .justified : .leading
        return copy
    }

    /// Draws `byteRange` of a static `text`/`rich` element as a rounded pill (`crates/rune/src/el/pills.rs:22`).
    /// Empty, overlapping, out-of-bounds, or non-char-boundary ranges, and text fields, are skipped.
    public func pill(_ byteRange: Range<Int>, _ style: PillStyle = .default, icon: BareIcon? = nil) -> Self {
        let chip = PillChip(byteRange, style: style, icon: icon)
        return pills([chip])
    }

    /// Draws several `(range, style)` pill chips (`crates/rune/src/el/pills.rs:27`).
    public func pills(_ items: [(Range<Int>, PillStyle)]) -> Self {
        pills(items.map { PillChip($0.0, style: $0.1) })
    }

    /// Applies multiple validated `PillChip` entries, skipping invalid, non-boundary, overlapping, or field targets.
    public func pills(_ items: [PillChip]) -> Self {
        var copy = self
        // Ignore static pills on editable text fields (`pills.rs:28`).
        guard copy.handlers.editLens == nil else { return copy }
        let content = copy.plainText ?? copy.richSpans?.map(\.text).joined() ?? ""
        let len = content.utf8.count
        guard len > 0 else { return copy }

        var chips = copy.pillChips
        var changed = false
        for item in items {
            let s = item.range.lowerBound
            let e = item.range.upperBound
            let valid = s >= 0 && s < e && e <= len
                && InlineIconLayout.isUTF8Boundary(s, in: content)
                && InlineIconLayout.isUTF8Boundary(e, in: content)
            guard valid else { continue }
            guard !chips.contains(where: { $0.range.lowerBound < e && s < $0.range.upperBound }) else {
                continue
            }
            let at = chips.partitionPoint { $0.range.lowerBound < s }
            chips.insert(item, at: at)
            changed = true
        }
        guard changed else { return copy }

        copy.runtimeExtras["pillChips"] = chips
        let authoredSpans = (copy.runtimeExtras["richSpanDefs"] as? [RichSpan]) ?? []
        if !authoredSpans.isEmpty || chips.contains(where: { !$0.isBare && ($0.style.color != nil || $0.style.bold || $0.style.italic || $0.style.mono) }) {
            copy.richSpans = Self.rebuildRichSpans(
                content: content,
                authoredSpans: authoredSpans,
                pills: chips,
                base: copy.textStyle
            )
        }
        return copy
    }

    /// Places an `InlineIcon` before UTF-8 byte `byteOffset` (`crates/rune/src/el/pills.rs:57`).
    public func inlineIcon(at byteOffset: Int, _ icon: InlineIcon) -> Self {
        var copy = self
        guard copy.handlers.editLens == nil else { return copy }
        let content = copy.plainText ?? copy.richSpans?.map(\.text).joined() ?? ""
        let len = content.utf8.count
        guard byteOffset >= 0, byteOffset < len, InlineIconLayout.isUTF8Boundary(byteOffset, in: content) else {
            return copy
        }
        let wordLen = InlineIconLayout.wordByteLength(startingAt: byteOffset, in: content)
        guard wordLen > 0 else { return copy }
        let end = byteOffset + wordLen

        var chips = copy.pillChips
        guard !chips.contains(where: { $0.range.lowerBound < end && byteOffset < $0.range.upperBound }) else {
            return copy
        }
        var placedIcon = icon
        placedIcon.byteOffset = byteOffset
        var bareIcons = copy.inlineIcons
        let iconIdx = bareIcons.partitionPoint { $0.byteOffset < byteOffset }
        bareIcons.insert(placedIcon, at: iconIdx)
        copy.runtimeExtras["inlineIcons"] = bareIcons

        let bareDesc: BareIcon? = icon.image.map {
            BareIcon(image: $0, size: icon.size, gap: icon.gap, radius: icon.radius)
        } ?? icon.icon.map {
            BareIcon($0, size: icon.size, color: icon.color, gap: icon.gap, radius: icon.radius)
        }
        let chip = PillChip(
            byteOffset..<end,
            style: PillStyle(background: nil, color: icon.color, pad: 0, gap: icon.gap),
            icon: bareDesc,
            isBare: true,
            bareGap: icon.gap,
            bareRadius: icon.radius,
            bareImage: icon.image
        )
        let chipIdx = chips.partitionPoint { $0.range.lowerBound < byteOffset }
        chips.insert(chip, at: chipIdx)
        copy.runtimeExtras["pillChips"] = chips
        return copy
    }

    /// Convenience overload matching earlier SVG inline icon calls (`El.inlineIcon(at:svg:size:color:gap:)`).
    public func inlineIcon(
        at byteOffset: Int,
        _ svg: SVGIcon,
        size: Float? = nil,
        color: Color? = nil,
        gap: Float = 4.0
    ) -> Self {
        let resolvedSize = max(1.0, size ?? (textStyle.size * 0.9))
        return inlineIcon(
            at: byteOffset,
            InlineIcon(byteOffset: byteOffset, icon: svg, size: resolvedSize, color: color ?? textColor, gap: gap)
        )
    }

    /// Inline icons anchored inside this element.
    public var inlineIcons: [InlineIcon] {
        runtimeExtras["inlineIcons"] as? [InlineIcon] ?? []
    }

    /// Pill chips (including bare inline icons) attached to this element.
    public var pillChips: [PillChip] {
        runtimeExtras["pillChips"] as? [PillChip] ?? []
    }
}

private extension Array {
    func partitionPoint(where predicate: (Element) -> Bool) -> Int {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if predicate(self[mid]) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}

extension TextSystem {
    /// Emits shaped background boxes, pill chip backgrounds/rings/icons, bare inline icons, and underlines/strikethroughs.
    internal func emitTextDecorationsAndPills(
        shaped: ShapedText,
        textOriginX: Float,
        textOriginY: Float,
        scaleVec: Vec2,
        pxScale: Float,
        defaultTextColor: Color,
        localAlpha: Float,
        srgbBlend: Bool,
        devClip: SIMD4<Float>,
        rot: Float,
        insertImage: (RGBA8Atlas) -> SIMD4<Float>,
        into primitives: inout [Primitive]
    ) {
        for (bgRect, bgColor) in shaped.backgrounds {
            let col = bgColor.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
            if col.w <= 0.0005 { continue }
            primitives.append(.roundedRect(
                rect: SIMD4<Float>(
                    (textOriginX + bgRect.x * scaleVec.x) * pxScale,
                    (textOriginY + bgRect.y * scaleVec.y) * pxScale,
                    bgRect.z * scaleVec.x * pxScale,
                    bgRect.w * scaleVec.y * pxScale
                ),
                radii: SIMD4<Float>(repeating: min(4.0, bgRect.w * 0.3) * pxScale),
                fill: col,
                clip: devClip,
                turn: rot
            ))
        }

        for chip in shaped.pillChips {
            let chipCol = (chip.background ?? Color(r: 0.22, g: 0.25, b: 0.32, a: 0.22))
                .scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
            let ringCol = chip.ring.map { $0.color.scaleAlpha(localAlpha).simd4(srgb: srgbBlend) } ?? .zero
            let ringW = (chip.ring?.width ?? 0) * pxScale
            primitives.append(.roundedRect(
                rect: SIMD4<Float>(
                    (textOriginX + chip.rect.x * scaleVec.x) * pxScale,
                    (textOriginY + chip.rect.y * scaleVec.y) * pxScale,
                    chip.rect.z * scaleVec.x * pxScale,
                    chip.rect.w * scaleVec.y * pxScale
                ),
                radii: SIMD4<Float>(repeating: chip.cornerRadius * pxScale),
                fill: chipCol,
                borderColor: ringCol,
                borderWidth: ringW,
                clip: devClip,
                turn: rot
            ))
            if let svg = chip.icon, let ir = chip.iconRect {
                let pxSize = max(4, Int((min(ir.z, ir.w) * pxScale).rounded()))
                let entry = glyphAtlas.rasterizeIcon(svg, pixelSize: pxSize)
                let tint = (chip.iconColor ?? defaultTextColor).scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                primitives.append(.glyph(
                    rect: SIMD4<Float>(
                        (textOriginX + ir.x * scaleVec.x) * pxScale,
                        (textOriginY + ir.y * scaleVec.y) * pxScale,
                        ir.z * scaleVec.x * pxScale,
                        ir.w * scaleVec.y * pxScale
                    ),
                    uv: entry.uv,
                    color: tint,
                    gamma: 1.0,
                    clip: devClip,
                    turn: rot
                ))
            }
        }

        for inline in shaped.inlineIcons {
            let devRect = SIMD4<Float>(
                (textOriginX + inline.rect.x * scaleVec.x) * pxScale,
                (textOriginY + inline.rect.y * scaleVec.y) * pxScale,
                inline.rect.z * scaleVec.x * pxScale,
                inline.rect.w * scaleVec.y * pxScale
            )
            if let img = inline.image {
                let uv = insertImage(img)
                let tint = Color.white.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                primitives.append(.image(
                    rect: devRect,
                    radii: SIMD4<Float>(repeating: inline.cornerRadius * pxScale),
                    uv: uv,
                    tint: tint,
                    clip: devClip,
                    turn: rot
                ))
            } else if let svg = inline.icon {
                let pxSize = max(4, Int((min(inline.rect.z, inline.rect.w) * pxScale).rounded()))
                let entry = glyphAtlas.rasterizeIcon(svg, pixelSize: pxSize)
                let tint = (inline.color ?? defaultTextColor).scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                primitives.append(.glyph(
                    rect: devRect,
                    uv: entry.uv,
                    color: tint,
                    gamma: 1.0,
                    clip: devClip,
                    turn: rot
                ))
            }
        }

        let lineColor = defaultTextColor.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
        if lineColor.w > 0.0005 {
            for u in shaped.underlines {
                primitives.append(.roundedRect(
                    rect: SIMD4<Float>(
                        (textOriginX + u.x * scaleVec.x) * pxScale,
                        (textOriginY + u.y * scaleVec.y) * pxScale,
                        u.z * scaleVec.x * pxScale,
                        u.w * scaleVec.y * pxScale
                    ),
                    fill: lineColor,
                    clip: devClip,
                    turn: rot
                ))
            }
            for st in shaped.strikethroughs {
                primitives.append(.roundedRect(
                    rect: SIMD4<Float>(
                        (textOriginX + st.x * scaleVec.x) * pxScale,
                        (textOriginY + st.y * scaleVec.y) * pxScale,
                        st.z * scaleVec.x * pxScale,
                        st.w * scaleVec.y * pxScale
                    ),
                    fill: lineColor,
                    clip: devClip,
                    turn: rot
                ))
            }
        }
    }
}
