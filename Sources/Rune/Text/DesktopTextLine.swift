#if (os(Linux) || os(Windows) || os(Android)) && !canImport(CRuneDesktopText)
#error("Rune requires the CRuneDesktopText native font backend on this platform")
#endif
#if os(WASI) && RUNE_BROWSER_TEXT && !canImport(CRuneDesktopText)
#error("The Rune browser text bridge is missing from the WASI target dependencies")
#endif
#if canImport(CRuneDesktopText) && !canImport(CoreText)
import CRuneDesktopText
import Foundation

/// A shaped line retains its native font fallback, kerning and bidi layout until its masks
/// have been copied into the shared Rune glyph atlas. Atlas tiles can span many graphemes.
struct DesktopFont: Hashable {
    let family: String
    let mono: Bool
    let sizePx: Float
    let weight: Int32
    let italic: Bool
    let direction: Int32
    let language: String
    let features: String
    let variations: String
    // A newly registered font can change the fallback and its palette for the same family name.
    let settingsEpoch: UInt64

    init(style: TextStyle, span: TextSpan?, families: (sans: String, mono: String), language: String?, scale: Float) {
        settingsEpoch = FontFamiliesRegistry.settingsEpoch
        mono = span?.monospace == true || style.family == .monospace
        if mono { family = families.mono.isEmpty ? DefaultFonts.monoFamily : families.mono }
        else if case .custom(let name) = style.family { family = name }
        else { family = families.sans.isEmpty ? DefaultFonts.sansFamily : families.sans }
        sizePx = (span?.size ?? style.size) * scale
        let requestedWeight = span?.weight ?? style.weight
        let declared = FaceWeightsRegistry.declaredFace(in: TextSystem.faceWeights, family: family, requestedWeight: requestedWeight)
        let matchedWeight = declared?.weight ?? requestedWeight
        weight = Int32(matchedWeight.isFinite ? min(900, max(100, matchedWeight)) : 400)
        italic = span?.italic == true || style.italic
        direction = style.direction.map { $0 == .rtl ? 2 : 1 } ?? 0
        self.language = language ?? ""
        // Both CSS ('kern' 0) and HarfBuzz (kern=0) spellings are accepted by Rune.
        func settings(_ raw: String) -> [String] {
            raw.split(separator: ",").compactMap { item in
                let parts = item.split { $0.isWhitespace || $0 == "=" || $0 == "'" || $0 == "\"" }
                guard let tag = parts.first, tag.utf8.count == 4 else { return nil }
                let raw = parts.count > 1 ? String(parts[1]) : "1"
                let value = raw == "off" ? "0" : (raw == "on" ? "1" : raw)
                guard let numeric = Double(value), numeric.isFinite else { return nil }
                return "\(tag)=\(value)"
            }
        }
        features = settings(style.features).joined(separator: ",")
        var axes = settings(style.variations)
        if case .fixed(let points) = style.opticalSize, points.isFinite,
           !axes.contains(where: { $0.hasPrefix("opsz=") }) { axes.append("opsz=\(points)") }
        variations = axes.joined(separator: ",")
    }
}

struct DesktopMaskKey: Hashable {
    let text: String
    let font: DesktopFont
    let x: Int
    let y: Int
    let textHash: Int
    var phase = SIMD2<Int>.zero

    func hash(into hasher: inout Hasher) {
        hasher.combine(textHash)
        hasher.combine(font)
        hasher.combine(x)
        hasher.combine(y)
        hasher.combine(phase)
    }
}

/// Native rasterizers return integer-aligned coverage. Carry a moving line's fractional
/// position in the atlas mask so native-size GPU quads can retain exact texel sampling.
private struct DesktopGlyphGlide {
    let whole: SIMD2<Int>
    let phase: SIMD2<Int>

    init(_ offset: Vec2) {
        let quarters = SIMD2(Int(exactly: (offset.x * 4).rounded()) ?? 0,
                             Int(exactly: (offset.y * 4).rounded()) ?? 0)
        whole = quarters &>> 2
        phase = quarters & 3
    }

    /// The source includes its neighbor on the left and/or top. Adjacent output tiles use
    /// the same samples on their shared edge, including when a ligature spans two cells.
    static func translate(_ input: [UInt8], width: Int, height: Int, channels: Int, phase: SIMD2<Int>) -> [UInt8] {
        guard phase != .zero else { return input }
        let dx = phase.x == 0 ? 0 : channels
        let sourceStride = width * channels + dx
        let dy = phase.y == 0 ? 0 : sourceStride
        let weights = ((4 - phase.x) * (4 - phase.y), phase.x * (4 - phase.y),
                       (4 - phase.x) * phase.y, phase.x * phase.y)
        var output = [UInt8](repeating: 0, count: width * height * channels)
        for y in 0..<height {
            var src = y * sourceStride + dy + dx
            var dst = y * width * channels
            for _ in 0..<(width * channels) {
                let sum = Int(input[src]) * weights.0 + Int(input[src - dx]) * weights.1
                    + Int(input[src - dy]) * weights.2 + Int(input[src - dx - dy]) * weights.3
                output[dst] = UInt8((sum + 8) / 16)
                src += 1
                dst += 1
            }
        }
        return output
    }
}

private final class DesktopTextRun {
    struct InkPlanes {
        let mask: [UInt8]
        let color: [UInt8]
        let width, height: Int

        func hasMask(in columns: Range<Int>) -> Bool {
            for y in 0..<height {
                let start = y * width
                if mask[(start + columns.lowerBound)..<(start + columns.upperBound)].contains(where: { $0 != 0 }) {
                    return true
                }
            }
            return false
        }

        /// Crop the premultiplied sRGB tile to this grapheme's visual cell.
        func colorBitmap(in columns: Range<Int>) -> Data? {
            let count = columns.count
            var result = Data()
            for y in 0..<height {
                for x in columns {
                    let src = (y * width + x) * 4
                    let alpha = Int(color[src + 3])
                    if alpha == 0 { continue }
                    if result.isEmpty { result = Data(count: count * height * 4) }
                    let dst = (y * count + x - columns.lowerBound) * 4
                    for channel in 0..<4 { result[dst + channel] = color[src + channel] }
                }
            }
            return result.isEmpty ? nil : result
        }
    }

    let text: String
    let textHash: Int
    let font: DesktopFont
    private let renderLock = NSLock()
    let native: OpaquePointer
    let metrics: RuneDesktopLineMetrics
    let hasColor: Bool
    private var lastColorTile: (rect: SIMD4<Int>, phase: SIMD2<Int>, planes: InkPlanes)?

    var boxMetrics: (ascentPx: Float, descentPx: Float) {
        if metrics.font_ascent > 0 { return (metrics.font_ascent, metrics.font_descent) }
        return (metrics.ascent, metrics.descent)
    }

    init?(text: String, font: DesktopFont) {
        guard let length = Int32(exactly: text.utf8.count), font.sizePx.isFinite,
              let line = rune_desktop_line_create(text, length, font.family, font.sizePx,
                font.weight, font.italic ? 1 : 0, font.mono ? 1 : 0, font.direction) else { return nil }
        self.text = text
        self.textHash = text.hashValue
        self.font = font
        native = line
        if !font.language.isEmpty || !font.features.isEmpty || !font.variations.isEmpty {
            rune_desktop_line_configure(line, font.language, font.features, font.variations)
        }
        metrics = rune_desktop_line_metrics(line)
        hasColor = rune_desktop_line_has_color(line) != 0
    }

    deinit { rune_desktop_line_destroy(native) }

    func mask(x: Int, y: Int, width: Int, height: Int, phase: SIMD2<Int> = .zero) -> [UInt8]? {
        renderLock.lock()
        defer { renderLock.unlock() }
        let dx = phase.x == 0 ? 0 : 1, dy = phase.y == 0 ? 0 : 1
        var pixels = [UInt8](repeating: 0, count: (width + dx) * (height + dy))
        guard rune_desktop_line_mask(native, Int32(x - dx), Int32(y - dy), Int32(width + dx), Int32(height + dy), &pixels) != 0 else { return nil }
        return DesktopGlyphGlide.translate(pixels, width: width, height: height, channels: 1, phase: phase)
    }

    func inkPlanes(x: Int, y: Int, width: Int, height: Int, phase: SIMD2<Int> = .zero) -> InkPlanes? {
        guard hasColor else { return nil }
        return renderLock.withLock {
            let rect = SIMD4(x, y, width, height)
            if let cached = lastColorTile, cached.rect == rect, cached.phase == phase { return cached.planes }
            let dx = phase.x == 0 ? 0 : 1, dy = phase.y == 0 ? 0 : 1
            let w = Int32(width + dx), h = Int32(height + dy), left = Int32(x - dx), top = Int32(y - dy)
            var mask = [UInt8](repeating: 0, count: Int(w) * Int(h))
            var color = [UInt8](repeating: 0, count: mask.count * 4)
            guard rune_desktop_line_mask(native, left, top, w, h, &mask) != 0,
                  rune_desktop_line_color(native, left, top, w, h, &color) != 0 else {
                return nil
            }
            for pixel in stride(from: 0, to: color.count, by: 4) {
                let alpha = Int(color[pixel + 3])
                for i in pixel..<(pixel + 3) { color[i] = UInt8((Int(color[i]) * alpha + 127) / 255) }
            }
            let planes = InkPlanes(mask: DesktopGlyphGlide.translate(mask, width: width, height: height, channels: 1, phase: phase),
                                   color: DesktopGlyphGlide.translate(color, width: width, height: height, channels: 4, phase: phase),
                                   width: width, height: height)
            lastColorTile = (rect, phase, planes)
            return planes
        }
    }
}

/// The paragraph strut and an inline element's own box use their declared faces, even if
/// a fallback face draws some of their text. Share these probes across wraps of one layout.
final class DesktopFaceBoxes {
    typealias Box = (ascentPx: Float, descentPx: Float)
    private var measured: [DesktopFont: Box] = [:]

    func box(for font: DesktopFont) -> Box? {
        if let box = measured[font] { return box }
        guard let box = DesktopTextRun(text: " ", font: font)?.boxMetrics else { return nil }
        measured[font] = box
        return box
    }
}

final class DesktopTextLine {
    struct MarkerPosition {
        let left: Float
        let width: Float
        let rtl: Bool
    }

    struct Cell {
        let character: Character
        let byte: Int
        let byteEnd: Int
        let advance: Float
        let left: Float
        let right: Float
        let caret: Float
        let isRTL: Bool
        let endCaret: Float
        fileprivate let run: DesktopTextRun
        fileprivate let localLeft: Float
    }

    let cells: [Int: Cell]
    let leadingMarkers: [Int: MarkerPosition]
    let trailingMarkers: [Int: MarkerPosition]
    let width: Float
    let baseline: Float
    let strutBaselinePx: Float
    let strutAscentPt: Float
    let strutFontHeightPt: Float
    let glyphEndPt: Float
    let growth: (over: Float, under: Float)
    // Secret text may reuse tiles within this layout call, without inserting its contents
    // into the persistent atlas lookup. TextRun's persistent cell path uses cache == true.
    private var transientTiles: [DesktopMaskKey: GlyphAtlas.Entry] = [:]
    private let scale: Float

    init?(text: String, start: Int, style: TextStyle, families: (sans: String, mono: String), language: String?, scale: Float,
          faceBoxes: DesktopFaceBoxes = DesktopFaceBoxes(), cutsCodePadding: Bool = false,
          pillRanges: [Range<Int>] = [], span: (Int) -> TextSpan?,
          stretch: (Character, Int) -> Float = { _, _ in 0 },
          extra: (Int, Int) -> (leading: Float, trailing: Float) = { _, _ in (0, 0) }) {
        guard !text.isEmpty else { return nil }
        self.scale = scale
        DefaultFonts.registerIfNeeded()
        // Keep spans with equal font settings together. Decoration and color boundaries
        // can then divide the same shaped ligature without changing its advance.
        var groups: [(start: Int, font: DesktopFont, text: String, inlineHeightPx: Float?)] = []
        var byte = start
        var lastSpan: TextSpan?
        let baseFont = DesktopFont(style: style, span: nil, families: families, language: language, scale: scale)
        var font = baseFont
        let lineHeightPx = style.resolvedLineHeight * scale
        var inlineHeightPx: Float?
        for ch in text {
            let nextSpan = span(byte)
            if nextSpan != lastSpan {
                font = DesktopFont(style: style, span: nextSpan, families: families, language: language, scale: scale)
                inlineHeightPx = nil
                if let nextSpan, nextSpan.monospace || nextSpan.size != nil {
                    let isPadding = cutsCodePadding && !nextSpan.monospace
                        && (nextSpan.size ?? style.size) < style.size
                        && nextSpan.text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
                    if !isPadding {
                        // Resolve relative line height at the authored point size, before the
                        // device scale can round the span size across a quantization boundary.
                        inlineHeightPx = nextSpan.size.map { lineHeightPx / style.size * $0 } ?? lineHeightPx
                    }
                }
                lastSpan = nextSpan
            }
            if groups.last?.font == font {
                groups[groups.count - 1].text.append(ch)
                if let inlineHeightPx { groups[groups.count - 1].inlineHeightPx = inlineHeightPx }
            } else {
                groups.append((byte, font, String(ch), inlineHeightPx))
            }
            byte += ch.utf8.count
        }
        // Resolve the paragraph's visual order before dividing it into font runs.
        // A change of weight or family in the middle of Hebrew in an English sentence
        // must not turn those two styled runs into independent LTR paragraphs.
        let isolateLabels = style.byParagraphStart != nil
        let marked = TextSystem.MarkedPillText(text, start: start, ranges: pillRanges, isolateLabels: isolateLabels, padding: extra)
        let hasMarkers = !(marked?.markers.isEmpty ?? true)
        let bidi = groups.count > 1 || hasMarkers ? DesktopTextRun(text: marked?.text ?? text, font: baseFont) : nil
        if hasMarkers && bidi == nil { return nil }
        struct PlacedCell {
            let character: Character
            let byte, end: Int
            let left, advance, refLeft, refWidth, caret, endCaret: Float
            let run: DesktopTextRun
            let isRTL: Bool
        }
        var visual: [PlacedCell] = []
        var boxes: [(ascentPx: Float, descentPx: Float, lineHeightPx: Float)] = []
        for group in groups {
            let groupIsolates: TextSystem.MarkedPillText?
            if isolateLabels {
                groupIsolates = groups.count == 1 && !hasMarkers ? marked
                    : TextSystem.MarkedPillText(group.text, start: group.start, ranges: pillRanges)
            } else {
                groupIsolates = nil
            }
            guard let run = DesktopTextRun(text: groupIsolates?.text ?? group.text, font: group.font) else { return nil }
            if let inlineHeightPx = group.inlineHeightPx {
                let metrics = faceBoxes.box(for: group.font) ?? run.boxMetrics
                boxes.append((metrics.ascentPx, metrics.descentPx, inlineHeightPx))
            }
            var local = 0
            for ch in group.text {
                let end = local + ch.utf8.count
                let byte = group.start + local
                var left: Float = 0, advance: Float = 0
                let localByte = groupIsolates?.byteOffset(local) ?? local
                var direction = rune_desktop_line_cell(run.native, Int32(localByte), Int32(localByte + ch.utf8.count), &left, &advance)
                var refLeft = left, refWidth = advance
                let reference = bidi ?? run
                let refByte = bidi == nil ? localByte : marked?.byteOffset(byte - start) ?? (byte - start)
                let refEnd = refByte + ch.utf8.count
                if bidi != nil {
                    direction = rune_desktop_line_cell(reference.native, Int32(refByte), Int32(refEnd), &refLeft, &refWidth)
                }
                visual.append(PlacedCell(character: ch, byte: byte, end: group.start + end,
                    left: left, advance: advance, refLeft: refLeft, refWidth: refWidth,
                    caret: rune_desktop_line_caret(reference.native, Int32(refByte)),
                    endCaret: rune_desktop_line_caret(reference.native, Int32(refEnd)), run: run, isRTL: direction < 0))
                local = end
            }
        }
        guard let strut = faceBoxes.box(for: baseFont) else { return nil }
        strutAscentPt = strut.ascentPx / scale
        strutFontHeightPt = (strut.ascentPx + strut.descentPx) / scale
        strutBaselinePx = InlineCodeBox.quantizedBox(ascentPx: strut.ascentPx,
            descentPx: strut.descentPx, lineHeightPx: lineHeightPx).over
        growth = InlineCodeBox.lineGrowth(strut: strut, code: boxes, lineHeightPx: lineHeightPx)
        baseline = (strutBaselinePx + growth.over) / scale
        visual.sort { $0.refLeft == $1.refLeft ? $0.byte < $1.byte : $0.refLeft < $1.refLeft }
        // The native strong caret can lie on the opposite edge of a mixed-direction run.
        // Preserve that visual edge as the actual font widths and inline spacing are applied.
        var edges: [Int64: Float] = [:]
        var intervals: [(left: Float, right: Float)] = []
        func edge(_ x: Float) -> Int64 { Int64((Double(x) * 1024).rounded()) }
        var widthPt: Float = 0
        var leading: [Int: MarkerPosition] = [:]
        var trailing: [Int: MarkerPosition] = [:]
        var marks: [(marker: TextSystem.MarkedPillText.Marker, left: Float, width: Float, rtl: Bool)] = []
        if let bidi, let marked {
            for marker in marked.markers {
                var left: Float = 0, width: Float = 0
                let direction = rune_desktop_line_cell(bidi.native, Int32(marker.shapedByte),
                    Int32(marker.shapedByte + 3), &left, &width)
                marks.append((marker, left, width, direction < 0))
            }
            marks.sort { $0.left < $1.left }
        }
        var nextMark = 0
        func placeMarks(before x: Float) {
            while nextMark < marks.count, marks[nextMark].left + marks[nextMark].width / 2 <= x {
                let mark = marks[nextMark]
                let position = MarkerPosition(left: widthPt, width: mark.marker.width, rtl: mark.rtl)
                if mark.marker.isLeading { leading[mark.marker.authoredByte] = position }
                else { trailing[mark.marker.authoredByte] = position }
                edges[edge(mark.left)] = widthPt
                widthPt += mark.marker.width
                edges[edge(mark.left + mark.width)] = widthPt
                nextMark += 1
            }
        }
        var lastGlyphEdge: Float = 0
        for cell in visual {
            placeMarks(before: cell.refLeft + cell.refWidth / 2)
            let padding = hasMarkers ? (leading: Float(0), trailing: Float(0)) : extra(cell.byte, cell.end)
            let advance = cell.advance / scale + style.letterSpacing + stretch(cell.character, cell.byte)
            widthPt += cell.isRTL ? padding.trailing : padding.leading
            let left = widthPt
            lastGlyphEdge = max(lastGlyphEdge, left + advance)
            edges[edge(cell.refLeft)] = widthPt
            widthPt += advance + (cell.isRTL ? padding.leading : padding.trailing)
            intervals.append((left, widthPt))
            edges[edge(cell.refLeft + cell.refWidth)] = widthPt
        }
        placeMarks(before: .infinity)
        leadingMarkers = leading
        trailingMarkers = trailing
        var result: [Int: Cell] = [:]
        for (index, cell) in visual.enumerated() {
            let (left, right) = intervals[index]
            result[cell.byte] = Cell(character: cell.character, byte: cell.byte, byteEnd: cell.end,
                advance: cell.advance / scale, left: left, right: right, caret: edges[edge(cell.caret)] ?? left, isRTL: cell.isRTL,
                endCaret: edges[edge(cell.endCaret)] ?? (left + cell.advance / scale),
                run: cell.run, localLeft: cell.left)
        }
        cells = result
        width = widthPt
        glyphEndPt = lastGlyphEdge
    }

    /// Join the visual cells of each decorated run before adding its CSS padding. This keeps
    /// decorations aligned to native clusters and lets the widest run determine the merged box.
    func appendDecorations(spans: [(utf8Range: Range<Int>, span: TextSpan)], index: (Int) -> Int?,
                           originX: Float, baselinePx: Float, style: TextStyle,
                           backgrounds: inout [(SIMD4<Float>, Color)], underlines: inout [SIMD4<Float>],
                           strikethroughs: inout [SIMD4<Float>], underlineEnds: inout [Float]) {
        struct Fragment {
            let spanIndex: Int
            let run: DesktopTextRun
            let left: Float
            var right: Float
        }
        var fragments: [Fragment] = []
        for cell in cells.values.sorted(by: { ($0.left, $0.byte) < ($1.left, $1.byte) }) {
            guard let i = index(cell.byte) else { continue }
            let span = spans[i].span
            guard span.background != nil || span.underline || span.strikethrough else { continue }
            if let last = fragments.last, last.spanIndex == i, last.run === cell.run,
               abs(last.right - cell.left) < 0.01 {
                fragments[fragments.count - 1].right = max(last.right, cell.right)
            } else {
                fragments.append(Fragment(spanIndex: i, run: cell.run, left: cell.left, right: cell.right))
            }
        }
        var merged: [InlineCodeBox.RunBackground] = []
        var previous: Int?
        let thickness = max(1, style.size * 0.07)
        for f in fragments where f.right - f.left > 0.01 {
            let span = spans[f.spanIndex].span, metrics = f.run.boxMetrics
            if span.underline {
                let y = baselinePx / scale + max(1, style.size * 0.12)
                underlines.append(SIMD4(originX + f.left, y, f.right - f.left, thickness))
                underlineEnds.append(originX + glyphEndPt)
            }
            if span.strikethrough {
                let y = baselinePx / scale - strutAscentPt * 0.35
                strikethroughs.append(SIMD4(originX + f.left, y, f.right - f.left, thickness))
            }
            guard let color = span.background else { continue }
            let cap = f.run.metrics.cap_height
            let v = InlineCodeBox.backgroundVertical(baselinePx: baselinePx, mono: span.monospace,
                ascentPx: metrics.ascentPx, descentPx: metrics.descentPx, capHeightPx: cap > 0 ? cap : nil,
                fontSizePx: f.run.font.sizePx)
            let pad = span.pad * scale
            let left = ((originX + f.left) * scale - pad).rounded()
            let right = ((originX + f.right) * scale + pad).rounded()
            let rect = SIMD4(left, v.top, right - left, v.bottom - v.top)
            InlineCodeBox.appendMerging(.init(rect: rect, color: color), pad: pad, into: &merged, last: &previous)
        }
        backgrounds.append(contentsOf: merged.map { ($0.rect / scale, $0.color) })
    }

    private struct Tile {
        let key: DesktopMaskKey
        let width, height, left, right: Int
    }

    // Each coverage pixel belongs to precisely one grapheme, including shared ligatures.
    private func visitTiles(for cell: Cell, size: SIMD2<Int>, phase: SIMD2<Int> = .zero, _ body: (Tile) -> Void) {
        let run = cell.run, m = run.metrics
        let inkLeft = Int(m.ink_x), inkTop = Int(m.ink_y)
        guard m.ink_width > 0, m.ink_height > 0 else { return }
        let inkRight = inkLeft + Int(m.ink_width) + (phase.x == 0 ? 0 : 1)
        let inkBottom = inkTop + Int(m.ink_height) + (phase.y == 0 ? 0 : 1)
        let x0 = cell.localLeft < 0.01 ? inkLeft : max(inkLeft, Int(cell.localLeft.rounded()))
        let end = cell.localLeft + cell.advance * scale
        let x1 = end > m.advance - 0.01 ? inkRight : min(inkRight, Int(end.rounded()))
        guard x0 < x1, inkTop < inkBottom else { return }
        let firstTile = inkLeft + (x0 - inkLeft) / size.x * size.x
        for x in stride(from: firstTile, to: x1, by: size.x) {
            let w = min(size.x, inkRight - x)
            for y in stride(from: inkTop, to: inkBottom, by: size.y) {
                let key = DesktopMaskKey(text: run.text, font: run.font, x: x, y: y, textHash: run.textHash, phase: phase)
                body(Tile(key: key, width: w, height: min(size.y, inkBottom - y),
                          left: max(x0, x), right: min(x1, x + w)))
            }
        }
    }

    /// Native shaping already placed and kerned the glyphs within the run. Only its
    /// translation into the layout (including justification and inline padding) is external.
    func runOriginPx(for cell: Cell, originX: Float) -> Float {
        (originX + cell.left) * scale - cell.localLeft
    }

    func glyphs(for cell: Cell, originX: Float, baselineY: Float, color: Color?,
                atlas: GlyphAtlas, cache: Bool, glidePx: Vec2 = .zero,
                restingXPx: Float? = nil, utf8Offset: Int? = nil) -> [PositionedGlyph] {
        var quads: [PositionedGlyph] = []
        let localX = runOriginPx(for: cell, originX: originX)
        var maskX = localX, colorX = localX
        var maskOffset = glidePx
        if let restingXPx {
            let absolute = restingXPx + localX
            let (pixel, phase) = TextBoxGeometry.quarterPen(absolute)
            maskX = pixel - restingXPx
            maskOffset.x += Float(phase) * 0.25
            colorX = absolute.rounded() - restingXPx
        }
        let maskGlide = DesktopGlyphGlide(maskOffset), colorGlide = DesktopGlyphGlide(glidePx)
        func emit(_ glide: DesktopGlyphGlide, x: Float, mask: Bool, colorInk: Bool) {
            visitTiles(for: cell, size: atlas.desktopTileSize, phase: glide.phase) { tile in
                let key = tile.key
                let rect = SIMD4((x + Float(tile.left + glide.whole.x)) / scale,
                    baselineY + (Float(key.y + glide.whole.y) - cell.run.metrics.ascent) / scale,
                    Float(tile.right - tile.left) / scale, Float(tile.height) / scale)
                let planes = cell.run.inkPlanes(x: key.x, y: key.y, width: tile.width, height: tile.height, phase: glide.phase)
                let columns = (tile.left - key.x)..<(tile.right - key.x)
                let drawMask = mask && (planes?.hasMask(in: columns) ?? true)
                let existing = cache ? nil : transientTiles[key]
                if drawMask, let entry = existing ?? atlas.desktopMask(key: cache ? key : nil,
                    width: tile.width, height: tile.height, bitmap: {
                        planes?.mask ?? cell.run.mask(x: key.x, y: key.y, width: tile.width, height: tile.height, phase: glide.phase)
                    }) {
                    if !cache { transientTiles[key] = entry }
                    if let rows = atlas.desktopCoveredRows(of: entry, columns: columns) {
                        let du = (entry.uv.z - entry.uv.x) / Float(tile.width)
                        let dv = (entry.uv.w - entry.uv.y) / Float(tile.height)
                        let uv = SIMD4(entry.uv.x + Float(columns.lowerBound) * du, entry.uv.y + Float(rows.lowerBound) * dv,
                                       entry.uv.x + Float(columns.upperBound) * du, entry.uv.y + Float(rows.upperBound) * dv)
                        var ink = rect
                        ink.y += Float(rows.lowerBound) / scale
                        ink.w = Float(rows.count) / scale
                        quads.append(PositionedGlyph(rect: ink, uv: uv, color: color, atlasPage: entry.page, utf8Offset: utf8Offset ?? cell.byte))
                    }
                }
                if colorInk, let planes {
                    let cropKey = DesktopMaskKey(text: key.text, font: key.font, x: tile.left, y: key.y, textHash: key.textHash, phase: glide.phase)
                    if let bitmap = atlas.desktopColor(key: cache ? cropKey : nil, width: columns.count, height: tile.height,
                                                       bitmap: { planes.colorBitmap(in: columns) }) {
                        quads.append(PositionedGlyph(rect: rect, colorGlyph: bitmap, color: color, utf8Offset: utf8Offset ?? cell.byte))
                    }
                }
            }
        }
        let split = cell.run.hasColor && (maskX != colorX || maskGlide.phase != colorGlide.phase || maskGlide.whole != colorGlide.whole)
        emit(maskGlide, x: maskX, mask: true, colorInk: !split)
        if split { emit(colorGlide, x: colorX, mask: false, colorInk: true) }
        return quads
    }

    /// Measures the exact masks used for painting, without populating a renderer's atlas.
    func addInk(to ink: inout TextInkAccumulator, originYPx: Float) {
        var lastKey: DesktopMaskKey?
        var coverage: [UInt8] = []
        var colors: [UInt8] = []
        for cell in cells.values.sorted(by: { $0.left < $1.left }) {
            visitTiles(for: cell, size: SIMD2(256, 128)) { tile in
                let key = tile.key
                if key != lastKey {
                    let planes = cell.run.inkPlanes(x: key.x, y: key.y, width: tile.width, height: tile.height)
                    coverage = planes?.mask ?? cell.run.mask(x: key.x, y: key.y, width: tile.width, height: tile.height) ?? []
                    colors = planes?.color ?? []
                    lastKey = key
                }
                guard !coverage.isEmpty else { return }
                let xOrigin = cell.left * scale - cell.localLeft
                let yOrigin = originYPx + baseline * scale - cell.run.metrics.ascent + Float(key.y)
                for y in 0..<tile.height {
                    for x in tile.left..<tile.right {
                        let index = y * tile.width + (x - key.x)
                        let mask = Float(coverage[index]) / 255
                        let colorAlpha = colors.isEmpty ? 0 : Float(colors[index * 4 + 3]) / 255
                        let alpha = mask + colorAlpha * (1 - mask)
                        if alpha > 0 { ink.add(x: xOrigin + Float(x), y: yOrigin + Float(y), alpha: alpha) }
                    }
                }
            }
        }
    }
}

/// Retains the native shaped runs so painting at a new absolute pen can choose another
/// coverage mask without laying out the paragraph again.
final class DesktopRestingText {
    struct Line {
        let native: DesktopTextLine
        let originX, baselineY: Float
        let colors: [Int: Color]
        var sourceByteOffset: Int? = nil
    }

    private var lines: [Int: Line] = [:]
    private var hasFractionalRun = false
    private let glide: Vec2
    private let cache: Bool
    private let lock = NSLock()
    private var last: (x: Float, glyphs: [PositionedGlyph], ranges: [Range<Int>], pages: Set<UInt16>, resets: UInt64)?

    init(glide: Vec2, cache: Bool) {
        self.glide = glide
        self.cache = cache
    }

    func add(_ line: Line, at index: Int) {
        lines[index] = line
        guard !hasFractionalRun else { return }
        func isFractional(_ cell: DesktopTextLine.Cell) -> Bool {
            let pen = line.native.runOriginPx(for: cell, originX: line.originX)
            return abs(pen - pen.rounded()) > 1e-5
        }
        if let offset = line.sourceByteOffset, let cell = line.native.cells[offset] {
            hasFractionalRun = isFractional(cell)
        } else {
            hasFractionalRun = line.native.cells.values.contains(where: isFractional)
        }
    }

    func place(_ shaped: inout ShapedText, at x: Float, atlas: GlyphAtlas) -> Bool {
        guard !lines.isEmpty, x.isFinite, x != x.rounded() || hasFractionalRun else { return false }
        return lock.withLock {
            if let last, last.x == x, atlas.retainPages(last.pages, since: last.resets) {
                shaped.glyphs = last.glyphs
                shaped.lineGlyphRanges = last.ranges
                return true
            }
            var glyphs: [PositionedGlyph] = [], ranges: [Range<Int>] = []
            glyphs.reserveCapacity(shaped.glyphs.count)
            for (index, original) in shaped.lineGlyphRanges.enumerated() {
                let start = glyphs.count
                if let line = lines[index] {
                    let record = shaped.portableLines[index]
                    var byte = record.utf8Start
                    for character in record.text {
                        let sourceByte = byte + (line.sourceByteOffset ?? 0)
                        if let cell = line.native.cells[sourceByte] {
                            glyphs += line.native.glyphs(for: cell, originX: line.originX, baselineY: line.baselineY,
                                color: line.colors[byte], atlas: atlas, cache: cache, glidePx: glide,
                                restingXPx: x, utf8Offset: byte)
                        }
                        byte += character.utf8.count
                    }
                } else {
                    glyphs += shaped.glyphs[original]
                }
                ranges.append(start..<glyphs.count)
            }
            if cache {
                let pages = Set(glyphs.filter { $0.uv != .zero }.map(\.atlasPage))
                last = (x, glyphs, ranges, pages, atlas.resets)
            }
            shaped.glyphs = glyphs
            shaped.lineGlyphRanges = ranges
            return true
        }
    }
}
#endif
