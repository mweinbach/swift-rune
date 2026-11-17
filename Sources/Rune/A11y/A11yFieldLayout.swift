#if os(macOS) && canImport(AppKit)
import AppKit

/// The retained layout used to draw a field. Queries use its own line breaks, glyphs and
/// coordinate system, including single-line scrolling and the presented scale.
internal struct A11yFieldLayout: Sendable, Equatable {
    private let box: TextLayoutBox
    private let system: TextSystem
    private let origin: Vec2
    private let scale: Vec2
    private let lineRanges: [NSRange]

    init?(text: String, box: TextLayoutBox, system: TextSystem, origin: Vec2, scale: Vec2) {
        guard text.utf8.count <= 64 * 1024, !box.shaped.wasTruncated, box.shaped.elided == nil,
              box.authText.utf8.elementsEqual(text.utf8), scale.x > 0, scale.y > 0 else { return nil }
        let lines = box.shaped.lineStrings
        guard let first = lines.first, first.utf8Start == 0 else { return nil }

        var ranges: [NSRange] = []
        var units = 0
        for (i, line) in lines.enumerated() {
            // Waiting paragraphs can have an estimated height and a placeholder line record.
            // A partially shaped field must expose the full model through the fallback.
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
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Holding the layout box pins it: the layout cache clones before a rebreak.
        lhs.box === rhs.box && lhs.origin == rhs.origin && lhs.scale == rhs.scale
    }

    func line(atByte offset: Int) -> Int {
        box.shaped.lineIndex(forUTF8Offset: offset)
    }

    func range(ofLine index: Int) -> NSRange {
        lineRanges.indices.contains(index) ? lineRanges[index] : NSRange(location: 0, length: 0)
    }

    func frame(forBytes range: Range<Int>) -> NSRect {
        let shaped = box.shaped
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
