import Foundation
import RuneMotion

/// Minimal standalone vector icon descriptor (`rune::el::BareIcon`) used by inline pills and badges.
public struct BareIcon: Sendable, Hashable {
    public var svg: SVGIcon
    public var size: Float
    public var color: Color?

    public init(_ svg: SVGIcon, size: Float = 14.0, color: Color? = nil) {
        self.svg = svg
        self.size = max(1.0, size)
        self.color = color
    }
}

/// Visual styling for an inline rounded pill span (`rune::el::PillStyle`).
public struct PillStyle: Sendable, Hashable {
    public var background: Color
    public var ring: TextRing?
    public var color: Color?
    public var pad: Float
    public var gap: Float
    public var bold: Bool
    public var italic: Bool
    public var mono: Bool

    public init(
        background: Color = Color(r: 0.22, g: 0.25, b: 0.32, a: 0.22),
        ring: TextRing? = nil,
        color: Color? = nil,
        pad: Float = 6.0,
        gap: Float = 4.0,
        bold: Bool = false,
        italic: Bool = false,
        mono: Bool = false
    ) {
        self.background = background
        self.ring = ring
        self.color = color
        self.pad = max(0, pad)
        self.gap = max(0, gap)
        self.bold = bold
        self.italic = italic
        self.mono = mono
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
    public func ring(_ c: Color, width: Float = 1.0) -> PillStyle { var s = self; s.ring = TextRing(color: c, width: width); return s }
    public func color(_ c: Color) -> PillStyle { var s = self; s.color = c; return s }
    public func pad(_ p: Float) -> PillStyle { var s = self; s.pad = max(0, p); return s }
    public func gap(_ g: Float) -> PillStyle { var s = self; s.gap = max(0, g); return s }
    public func bold(_ on: Bool = true) -> PillStyle { var s = self; s.bold = on; return s }
    public func italic(_ on: Bool = true) -> PillStyle { var s = self; s.italic = on; return s }
    public func mono(_ on: Bool = true) -> PillStyle { var s = self; s.mono = on; return s }
}

/// Byte-ranged inline pill descriptor (`rune::el::PillChip`).
public struct PillChip: Sendable, Hashable {
    public var range: Range<Int>
    public var style: PillStyle
    public var icon: BareIcon?

    public init(_ range: Range<Int>, style: PillStyle = .default, icon: BareIcon? = nil) {
        let lower = max(0, range.lowerBound)
        let upper = max(lower, range.upperBound)
        self.range = lower..<upper
        self.style = style
        self.icon = icon
    }
}

/// Inline vector icon anchored at a UTF-8 byte boundary inside a text element (`El.inlineIcon`).
public struct InlineIcon: Sendable, Hashable {
    public var byteOffset: Int
    public var icon: SVGIcon
    public var size: Float
    public var color: Color?
    public var gap: Float
    /// Minimum advance reserve for wrapping word-width calculation (`size + gap`).
    public var reserveWidth: Float { size + gap }

    public init(
        byteOffset: Int,
        icon: SVGIcon,
        size: Float = 14.0,
        color: Color? = nil,
        gap: Float = 4.0
    ) {
        self.byteOffset = max(0, byteOffset)
        self.icon = icon
        self.size = max(1.0, size)
        self.color = color
        self.gap = max(0, gap)
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

/// Layout and copy helper for `InlineIcon` slots inside wrapped/unwrapped text (`crates/rune/src/el/pills.rs`).
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

    /// Validates an `InlineIcon` against `text` and existing icons, snapping invalid offsets to scalar boundaries
    /// and rejecting duplicate anchors at the same byte offset (`pills.rs` overlap guard).
    public static func canPlace(_ candidate: InlineIcon, in text: String, existing: [InlineIcon]) -> Bool {
        guard isUTF8Boundary(candidate.byteOffset, in: text) else { return false }
        return !existing.contains(where: { $0.byteOffset == candidate.byteOffset })
    }

    /// Inserts an inline object-replacement marker `\u{FFFC}` into `text` for word-width & line wrapping,
    /// returning the marker-expanded string and a map from each marker UTF-8 byte index to its `InlineIcon`.
    public static func insertInlineMarkers(
        into text: String,
        icons: [InlineIcon]
    ) -> (expanded: String, markerOffsets: [(expandedByte: Int, sourceByte: Int, icon: InlineIcon)]) {
        let valid = icons
            .filter { isUTF8Boundary($0.byteOffset, in: text) }
            .sorted { $0.byteOffset < $1.byteOffset }
        guard !valid.isEmpty else { return (text, []) }

        // Deduplicate same-offset anchors keeping first-inserted order.
        var deduped: [InlineIcon] = []
        for ic in valid where deduped.last?.byteOffset != ic.byteOffset {
            deduped.append(ic)
        }

        let objReplacement = "\u{FFFC}"
        let utf8 = text.utf8
        var out = String()
        out.reserveCapacity(utf8.count + deduped.count * 3)
        var map: [(Int, Int, InlineIcon)] = []
        var cursor = utf8.startIndex
        var cursorByte = 0

        for ic in deduped {
            let target = utf8.index(utf8.startIndex, offsetBy: ic.byteOffset)
            if target > cursor, let slice = String(utf8[cursor..<target]) {
                out.append(slice)
            }
            let expandedByte = out.utf8.count
            out.append(objReplacement)
            map.append((expandedByte, ic.byteOffset, ic))
            cursor = target
            cursorByte = ic.byteOffset
        }
        if cursorByte < utf8.count, let tail = String(utf8[cursor..<utf8.endIndex]) {
            out.append(tail)
        }
        return (out, map)
    }

    /// Strips any `\u{FFFC}` inline-icon markers so plain-text copy / clipboard serialization ignores inline icons.
    public static func copyablePlainText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// Computes wrapped glyph/line layout taking each `InlineIcon`'s reserved advance (`size + gap`)
    /// into account for line breaks and returns placed icon rectangles aligned to the line's baseline.
    public static func layout(
        text: String,
        style: TextStyle,
        icons: [InlineIcon],
        maxWidth: Float?,
        pixelScale: Float = 2.0,
        textSystem: TextSystem = TextSystem()
    ) -> (totalSize: Vec2, placed: [PlacedInlineIcon]) {
        let sorted = icons
            .map { ic -> InlineIcon in
                var copy = ic
                copy.byteOffset = snapUTF8Boundary(ic.byteOffset, in: text)
                return copy
            }
            .sorted { $0.byteOffset < $1.byteOffset }

        var unique: [InlineIcon] = []
        for ic in sorted where unique.last?.byteOffset != ic.byteOffset {
            unique.append(ic)
        }

        let lh = max(style.size * 1.25, style.lineHeight ?? (style.size * 1.25))
        guard !unique.isEmpty else {
            let shaped = textSystem.shape(text: text, style: style, maxWidth: maxWidth, pixelScale: pixelScale)
            return (Vec2(shaped.size.x, shaped.size.y), [])
        }

        // Tokenize into segments separated by inline icons and whitespace so wrapping respects word width + icon reserve.
        let limit = maxWidth ?? Float.greatestFiniteMagnitude
        struct Token {
            var width: Float
            var isSpace: Bool
            var isNewline: Bool
            var icon: InlineIcon?
            var sourceByte: Int
        }

        var tokens: [Token] = []
        let utf8 = text.utf8
        var prevOffset = 0

        func appendTextTokens(_ slice: String, startByte: Int) {
            var wordStart = 0
            var cur = 0
            let scalars = Array(slice.unicodeScalars)
            var bytePos = 0
            var curStartByte = startByte
            func flushWord(endByte: Int, bytesCount: Int) {
                guard bytesCount > 0 else { return }
                let sIdx = slice.utf8.index(slice.utf8.startIndex, offsetBy: wordStart)
                let eIdx = slice.utf8.index(slice.utf8.startIndex, offsetBy: bytePos)
                if let sub = String(slice.utf8[sIdx..<eIdx]), !sub.isEmpty {
                    let shaped = textSystem.shape(text: sub, style: style, maxWidth: nil, pixelScale: pixelScale)
                    tokens.append(Token(width: shaped.size.x, isSpace: false, isNewline: false, icon: nil, sourceByte: curStartByte))
                }
                wordStart = bytePos
                curStartByte = endByte
            }
            for sc in scalars {
                let len = sc.utf8.count
                if sc == "\n" {
                    flushWord(endByte: startByte + bytePos, bytesCount: bytePos - wordStart)
                    tokens.append(Token(width: 0, isSpace: false, isNewline: true, icon: nil, sourceByte: startByte + bytePos))
                    bytePos += len
                    wordStart = bytePos
                    curStartByte = startByte + bytePos
                } else if sc == " " || sc == "\t" {
                    flushWord(endByte: startByte + bytePos, bytesCount: bytePos - wordStart)
                    let spaceW = max(style.size * 0.28, textSystem.shape(text: " ", style: style, maxWidth: nil, pixelScale: pixelScale).size.x)
                    tokens.append(Token(width: spaceW, isSpace: true, isNewline: false, icon: nil, sourceByte: startByte + bytePos))
                    bytePos += len
                    wordStart = bytePos
                    curStartByte = startByte + bytePos
                } else {
                    bytePos += len
                }
                cur += 1
            }
            _ = cur
            flushWord(endByte: startByte + bytePos, bytesCount: bytePos - wordStart)
        }

        for ic in unique {
            if ic.byteOffset > prevOffset {
                let sIdx = utf8.index(utf8.startIndex, offsetBy: prevOffset)
                let eIdx = utf8.index(utf8.startIndex, offsetBy: ic.byteOffset)
                if let slice = String(utf8[sIdx..<eIdx]) {
                    appendTextTokens(slice, startByte: prevOffset)
                }
            }
            tokens.append(Token(width: ic.reserveWidth, isSpace: false, isNewline: false, icon: ic, sourceByte: ic.byteOffset))
            prevOffset = ic.byteOffset
        }
        if prevOffset < utf8.count {
            let sIdx = utf8.index(utf8.startIndex, offsetBy: prevOffset)
            if let tail = String(utf8[sIdx..<utf8.endIndex]) {
                appendTextTokens(tail, startByte: prevOffset)
            }
        }

        var lineX: Float = 0
        var lineIndex = 0
        var maxLineW: Float = 0
        var placed: [PlacedInlineIcon] = []

        for tok in tokens {
            if tok.isNewline {
                maxLineW = max(maxLineW, lineX)
                lineX = 0
                lineIndex += 1
                continue
            }
            if style.wrap == .wrap && lineX > 0 && lineX + tok.width > limit && !tok.isSpace {
                maxLineW = max(maxLineW, lineX)
                lineX = 0
                lineIndex += 1
            }
            if let ic = tok.icon {
                let yOffset = max(0, (lh - ic.size) * 0.5)
                let rect = MotionRect.fromXYWH(lineX, Float(lineIndex) * lh + yOffset, ic.size, ic.size)
                placed.append(PlacedInlineIcon(
                    inlineIcon: ic,
                    byteOffset: tok.sourceByte,
                    lineIndex: lineIndex,
                    rect: rect,
                    reservedWidth: tok.width
                ))
            }
            lineX += tok.width
        }
        maxLineW = max(maxLineW, lineX)
        let totalHeight = Float(max(1, lineIndex + 1)) * lh
        return (Vec2(maxLineW, totalHeight), placed)
    }
}

extension El {
    /// Applies a rounded pill background/ring/pad highlight to UTF-8 `byteRange` (`crates/rune/src/el/pills.rs`).
    public func pill(_ byteRange: Range<Int>, _ style: PillStyle = .default, icon: BareIcon? = nil) -> Self {
        var copy = self
        let chip = PillChip(byteRange, style: style, icon: icon)
        var chips = copy.pillChips
        chips.append(chip)
        copy.runtimeExtras["pillChips"] = chips

        var span = RichSpan(chip.range)
            .bg(style.background)
            .pad(style.pad)
        if let ring = style.ring {
            span = span.ring(ring.color, width: ring.width)
        }
        if let fg = style.color {
            span = span.color(fg)
        }
        if style.bold { span = span.bold() }
        if style.italic { span = span.italic(true) }
        if style.mono { span = span.mono(true) }

        var existingRich = (copy.runtimeExtras["richSpanDefs"] as? [RichSpan]) ?? []
        existingRich.append(span)
        copy.runtimeExtras["richSpanDefs"] = existingRich

        if let text = copy.plainText {
            copy.richSpans = RichSpanFlattener.flatten(existingRich, in: text, base: copy.textStyle)
        }

        if let icon {
            copy = copy.inlineIcon(
                at: chip.range.lowerBound,
                icon.svg,
                size: icon.size,
                color: icon.color ?? style.color,
                gap: style.gap
            )
        }
        return copy
    }

    /// Applies multiple pill chips (`crates/rune/src/el/pills.rs`).
    public func pills(_ items: [PillChip]) -> Self {
        var copy = self
        for item in items {
            copy = copy.pill(item.range, item.style, icon: item.icon)
        }
        return copy
    }

    /// Anchors an inline vector icon at UTF-8 `byteOffset` inside this text element (`El.inlineIcon`).
    /// Rejects offsets inside multi-byte UTF-8 sequences or colliding with an existing inline icon at the same byte.
    public func inlineIcon(
        at byteOffset: Int,
        _ svg: SVGIcon,
        size: Float? = nil,
        color: Color? = nil,
        gap: Float = 4.0
    ) -> Self {
        var copy = self
        let resolvedSize = max(1.0, size ?? (copy.textStyle.size * 0.9))
        let candidate = InlineIcon(
            byteOffset: byteOffset,
            icon: svg,
            size: resolvedSize,
            color: color ?? copy.textColor,
            gap: gap
        )
        var existing = copy.inlineIcons
        if let text = copy.plainText {
            guard InlineIconLayout.canPlace(candidate, in: text, existing: existing) else {
                return copy
            }
        } else if existing.contains(where: { $0.byteOffset == candidate.byteOffset }) {
            return copy
        }
        existing.append(candidate)
        existing.sort { $0.byteOffset < $1.byteOffset }
        copy.runtimeExtras["inlineIcons"] = existing
        return copy
    }

    /// Inline icons anchored inside this element.
    public var inlineIcons: [InlineIcon] {
        runtimeExtras["inlineIcons"] as? [InlineIcon] ?? []
    }

    /// Pill chips attached to this element.
    public var pillChips: [PillChip] {
        runtimeExtras["pillChips"] as? [PillChip] ?? []
    }
}
