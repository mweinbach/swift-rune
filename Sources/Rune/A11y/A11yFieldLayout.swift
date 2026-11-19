#if os(macOS) && canImport(AppKit)
import AppKit

/// The retained layout used to draw a field. Queries use its own line breaks, glyphs and
/// coordinate system, including single-line scrolling, presented scale, and long-field drawn
/// visual lines (`#1121`).
internal struct A11yFieldLayout: Sendable, Equatable {
    /// Maximum number of drawn visual lines exposed for a long field (`a11y/text.rs::MAX_DRAWN_LINES`).
    static let maxDrawnLines = 512

    private struct DrawnVisualLine: Sendable {
        let shapeLineIndex: Int
        let byteRange: Range<Int>
        let utf16Range: NSRange
        let rect: NSRect
    }

    private let box: TextLayoutBox
    private let system: TextSystem
    private let origin: Vec2
    private let scale: Vec2
    private let lineRanges: [NSRange]
    private let isPartialLongField: Bool
    private let drawnLines: [DrawnVisualLine]

    init?(text: String, box: TextLayoutBox, system: TextSystem, origin: Vec2, scale: Vec2, visibleClip: NSRect? = nil) {
        guard !box.shaped.wasTruncated, box.shaped.elided == nil,
              box.authText.utf8.elementsEqual(text.utf8), scale.x > 0, scale.y > 0 else { return nil }
        let lines = box.shaped.lineStrings
        guard let first = lines.first, first.utf8Start == 0 else { return nil }

        let isLongOrPartial = text.utf8.count > 64 * 1024 || lines.contains(where: { $0.ctLine == nil })
        if !isLongOrPartial {
            var ranges: [NSRange] = []
            var units = 0
            for (i, line) in lines.enumerated() {
                guard line.ctLine != nil else { return nil }
                let end = line.utf8Start + line.text.utf8.count
                let next = i + 1 < lines.count ? lines[i + 1].utf8Start : text.utf8.count
                guard end <= next, next <= text.utf8.count else { return nil }
                let gap = next - end
                if gap > 0 {
                    let bytes = text.utf8
                    guard gap == 1, bytes[bytes.index(bytes.startIndex, offsetBy: end)] == 10 else { return nil }
                }
                let length = line.text.utf16.count + gap
                ranges.append(NSRange(location: units, length: length))
                units += length
            }
            self.box = box
            self.system = system
            self.origin = origin
            self.scale = scale
            self.lineRanges = ranges
            self.isPartialLongField = false
            self.drawnLines = []
            return
        }

        // Long field (> 64 KiB) or partially shaped field (`#1121`): publish geometry for every
        // shaped/drawn visual line inside `visibleClip` up to `maxDrawnLines` without copying or
        // exposing off-screen rows.
        var drawn: [DrawnVisualLine] = []
        drawn.reserveCapacity(min(lines.count, Self.maxDrawnLines))
        let totalBytes = text.utf8.count
        for (i, line) in lines.enumerated() {
            guard drawn.count < Self.maxDrawnLines else { break }
            guard let ctLine = line.ctLine else { continue }
            let start = max(0, min(line.utf8Start, totalBytes))
            let end = min(totalBytes, start + line.text.utf8.count)
            let next = i + 1 < lines.count ? min(totalBytes, max(end, lines[i + 1].utf8Start)) : totalBytes
            let lineEnd = (next > end && next - end <= 2) ? next : end
            let utf16Range = ImeUTF16Bridge.nsRange(in: text, fromUTF8Range: start..<lineEnd)
            let h = box.shaped.lineBoxHeightPt(i)
            let wPx = Float(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            let w = max(wPx / max(box.pixelScale, 1), 1)
            let lineRect = NSRect(
                x: CGFloat(origin.x + line.originX * scale.x),
                y: CGFloat(origin.y + line.originY * scale.y),
                width: CGFloat(w * scale.x),
                height: CGFloat(h * scale.y)
            )
            if let visibleClip, !visibleClip.isEmpty, !visibleClip.intersects(lineRect) {
                continue
            }
            drawn.append(DrawnVisualLine(shapeLineIndex: i, byteRange: start..<lineEnd, utf16Range: utf16Range, rect: lineRect))
        }
        guard !drawn.isEmpty else { return nil }
        self.box = box
        self.system = system
        self.origin = origin
        self.scale = scale
        self.lineRanges = []
        self.isPartialLongField = true
        self.drawnLines = drawn
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Holding the layout box pins it: the layout cache clones before a rebreak.
        lhs.box === rhs.box && lhs.origin == rhs.origin && lhs.scale == rhs.scale
    }

    func line(atByte offset: Int) -> Int {
        if isPartialLongField {
            if let hit = drawnLines.first(where: { offset >= $0.byteRange.lowerBound && offset < max($0.byteRange.upperBound, $0.byteRange.lowerBound + 1) }) {
                return hit.shapeLineIndex
            }
            return box.authText.utf8.prefix(max(0, offset)).count { $0 == 10 }
        }
        return box.shaped.lineIndex(forUTF8Offset: offset)
    }

    func range(ofLine index: Int) -> NSRange {
        if isPartialLongField {
            if let hit = drawnLines.first(where: { $0.shapeLineIndex == index }) {
                return hit.utf16Range
            }
            guard index >= 0 else { return NSRange(location: 0, length: 0) }
            var current = 0
            var start = 0
            var end = 0
            for unit in box.authText.utf16 {
                end += 1
                if unit == 10 {
                    if current == index { return NSRange(location: start, length: end - start) }
                    current += 1
                    start = end
                }
            }
            return current == index ? NSRange(location: start, length: end - start) : NSRange(location: 0, length: 0)
        }
        return lineRanges.indices.contains(index) ? lineRanges[index] : NSRange(location: 0, length: 0)
    }

    func frame(forBytes range: Range<Int>) -> NSRect {
        let shaped = box.shaped
        if isPartialLongField {
            let matching = drawnLines.filter { line in
                if range.isEmpty {
                    return range.lowerBound >= line.byteRange.lowerBound && range.lowerBound <= line.byteRange.upperBound
                }
                return line.byteRange.upperBound > range.lowerBound && line.byteRange.lowerBound < range.upperBound
            }
            guard !matching.isEmpty else { return .zero }
            let rectangles = system.selectionRects(in: shaped, utf8Range: range, pixelScale: box.pixelScale)
            if !rectangles.isEmpty {
                return rectangles.reduce(NSRect.null) { bounds, rect in
                    bounds.union(NSRect(x: CGFloat(origin.x + rect.x * scale.x), y: CGFloat(origin.y + rect.y * scale.y),
                                        width: CGFloat(rect.z * scale.x), height: CGFloat(rect.w * scale.y)))
                }
            }
            let caret = system.caretRect(in: shaped, utf8Offset: range.lowerBound, upstream: false, pixelScale: box.pixelScale)
            if caret.w > 0 {
                return NSRect(x: CGFloat(origin.x + caret.x * scale.x), y: CGFloat(origin.y + caret.y * scale.y),
                              width: CGFloat(max(caret.z, 1) * scale.x), height: CGFloat(caret.w * scale.y))
            }
            return matching.reduce(NSRect.null) { $0.union($1.rect) }
        }
        let first = line(atByte: range.lowerBound)
        let last = line(atByte: max(range.lowerBound, range.upperBound - 1))
        // Selection paint can include a trailing sliver on the row before a soft wrap.
        // An AX bounds query belongs only to the rows containing the requested characters.
        let top = shaped.lineStrings[first].originY
        let bottom = shaped.lineStrings[last].originY
        let rectangles = system.selectionRects(in: shaped, utf8Range: range, pixelScale: box.pixelScale)
            .filter { top <= $0.y && $0.y <= bottom }
        let localRects = rectangles.isEmpty
            ? [system.caretRect(in: shaped, utf8Offset: range.lowerBound, upstream: false, pixelScale: box.pixelScale)]
            : rectangles
        return localRects.reduce(NSRect.null) { bounds, rect in
            bounds.union(NSRect(x: CGFloat(origin.x + rect.x * scale.x), y: CGFloat(origin.y + rect.y * scale.y),
                                width: CGFloat(rect.z * scale.x), height: CGFloat(rect.w * scale.y)))
        }
    }

    func byte(at point: NSPoint) -> Int {
        if isPartialLongField {
            if let hitLine = drawnLines.min(by: { abs($0.rect.midY - point.y) < abs($1.rect.midY - point.y) }) {
                let localX = (Float(point.x) - origin.x) / scale.x
                let hit = system.caretHit(in: box.shaped, on: hitLine.shapeLineIndex, atX: localX, pixelScale: box.pixelScale).utf8Offset
                return max(hitLine.byteRange.lowerBound, min(hit, hitLine.byteRange.upperBound))
            }
        }
        let hit = system.hitTestUTF8Offset(in: box.shaped, localX: (Float(point.x) - origin.x) / scale.x,
                                           localY: (Float(point.y) - origin.y) / scale.y, pixelScale: box.pixelScale)
        // Text input chooses the nearest insertion edge. AX asks which character contains
        // the point, including the half of its glyph nearest its trailing edge.
        guard hit > 0 else { return hit }
        let text = box.authText
        let units = ImeUTF16Bridge.utf16Offset(in: text, fromUTF8Offset: hit)
        guard units > 0 else { return 0 }
        let previous = (text as NSString).rangeOfComposedCharacterSequence(at: units - 1)
        let start = ImeUTF16Bridge.utf8Offset(in: text, fromUTF16Offset: previous.location)
        return frame(forBytes: start..<hit).contains(point) ? start : hit
    }
}
#endif
