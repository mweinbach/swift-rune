import Foundation

/// Paints a checked field from its shaped byte ranges, using the same geometry for scene and GPU frames.
final class FieldSpelling {
    var watch: SpellPauseWatch?
    var checker: SpellChecker?

    #if os(macOS)
    static let color = Color(r: 1, g: 0.0437, b: 0.0296)
    #else
    static let color = Color(r: 1, g: 0, b: 0)
    #endif

    /// `clip` is left/top/right/bottom in device pixels. Paragraph positions and baselines
    /// are in layout pixels, while the selection boxes and text origin are in points.
    func paint(edit: TextEdit, focusedPath: String?, now: Double, box: TextLayoutBox, system: TextSystem,
               origin: Vec2, scale: Vec2, pixels: Float, clip: SIMD4<Float>, rotated: Bool,
               emit: (SIMD4<Float>, Float) -> Void) {
        guard !edit.isSecure, edit.preedit == nil, scale.x > 0, scale.y > 0, pixels > 0 else { return }
        if edit.text.isEmpty {
            // A user can focus an empty composer before its first keystroke.
            if let path = focusedPath {
                if watch?.path != path { watch = SpellPauseWatch(path: path) }
                _ = watch?.observe(path: path, text: "", selection: edit.selectedUTF8Range, now: now)
            }
            return
        }
        let length = edit.text.utf8.count
        let pieces: [ParagraphPiece]
        var shown = 0..<length
        if let paragraphs = box.paragraphs {
            let top = rotated ? -Float.infinity : (clip.y / pixels - origin.y) * paragraphs.scale / scale.y
            let bottom = rotated ? Float.infinity : (clip.w / pixels - origin.y) * paragraphs.scale / scale.y
            pieces = paragraphs.pieces(top: top, bottom: bottom)
            guard let first = pieces.first, let last = pieces.last, first.start < length else { return }
            shown = first.start..<min(length, last.end + 1)
        } else {
            pieces = []
        }

        let sliced = shown.count != length
        let visibleText: String
        if sliced {
            let bytes = edit.text.utf8
            let lo = bytes.index(bytes.startIndex, offsetBy: shown.lowerBound)
            let hi = bytes.index(lo, offsetBy: shown.count)
            visibleText = String(decoding: bytes[lo..<hi], as: UTF8.self)
        } else {
            visibleText = edit.text
        }
        var waiting: Int?
        if let path = focusedPath {
            if watch?.path != path { watch = SpellPauseWatch(path: path, text: visibleText) }
            waiting = watch?.observe(path: path, text: visibleText, selection: edit.selectedUTF8Range, now: now)
        }
        let checker = checker ?? .shared
        #if os(WASI) || os(Windows)
        let found = checker.misspelledUTF8Ranges(in: visibleText)
        let base = shown.lowerBound
        #else
        let found = checker.misspelledUTF8Ranges(in: edit.text)
        let base = 0
        #endif
        let left = rotated ? -Float.infinity : clip.x
        let right = rotated ? Float.infinity : clip.z

        func paintRange(_ range: Range<Int>, in layout: TextLayoutBox, offsetY: Float) {
            let shape = layout.shaped
            let count = shape.lineBaselinesPx.count
            guard count > 0 else { return }
            // Find the first line of the word without traversing the earlier lines of a long layout.
            var lo = 0, hi = count
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if shape.lineUTF8Range(at: mid).upperBound <= range.lowerBound { lo = mid + 1 } else { hi = mid }
            }
            var line = lo
            while line < count && shape.lineUTF8Range(at: line).lowerBound < range.upperBound {
                let y = (origin.y + ((offsetY + shape.lineBaselinesPx[line]) / layout.pixelScale + 1) * scale.y) * pixels
                if rotated || (y <= clip.w && y + 3 * scale.y * pixels >= clip.y) {
                    let boxes: [SIMD4<Float>]
                    #if canImport(CoreText) && canImport(CoreGraphics)
                    if shape.lineStrings.isEmpty {
                        boxes = system.selectionRectsPortable(in: shape, lines: line..<(line + 1),
                                                              utf8Range: range, pixelScale: layout.pixelScale)
                    } else {
                        boxes = system.selectionRects(in: shape, lines: line..<(line + 1),
                                                      utf8Range: range, pixelScale: layout.pixelScale)
                    }
                    #else
                    boxes = system.selectionRects(in: shape, lines: line..<(line + 1),
                                                  utf8Range: range, pixelScale: layout.pixelScale)
                    #endif
                    for bounds in boxes {
                        let x = (origin.x + bounds.x * scale.x) * pixels
                        Self.marker(from: x, to: x + bounds.z * scale.x * pixels, top: y,
                                    pixels: scale.x * pixels, left: left, right: right, emit: emit)
                    }
                }
                line += 1
            }
        }
        for result in found {
            let range = (result.lowerBound + base)..<(result.upperBound + base)
            guard range.overlaps(shown) else { continue }
            if let waiting, range.lowerBound <= waiting && waiting <= range.upperBound { continue }
            if box.paragraphs == nil {
                paintRange(range, in: box, offsetY: 0)
            } else {
                let index = partitionPoint(pieces) { $0.end <= range.lowerBound }
                for piece in pieces[index...].prefix(while: { $0.start < range.upperBound }) {
                    let start = max(range.lowerBound, piece.start), end = min(range.upperBound, piece.end)
                    if start < end {
                        paintRange((start - piece.start)..<(end - piece.start), in: piece.layout, offsetY: piece.y)
                    }
                }
            }
        }
    }

    /// Chromium's spelling marker as drawn by Rune. Retain the original dot/wave phase when a
    /// single-line field has scrolled far along the word.
    private static func marker(from x0: Float, to x1: Float, top y: Float, pixels k: Float,
                               left: Float, right: Float, emit: (SIMD4<Float>, Float) -> Void) {
        guard x0.isFinite, x1.isFinite, y.isFinite, k.isFinite, x1 > x0, k > 0 else { return }
        #if os(macOS)
        let diameter = 3 * k, step = 4 * k
        let last = max(0, floor((x1 - x0 - diameter) / step))
        let start = x0 + (x1 - x0 - last * step - diameter) / 2
        let first = max(0, ceil((left - start - diameter) / step))
        let end = min(last, floor((right - start) / step))
        guard first <= end, let from = Int(exactly: first), let to = Int(exactly: end) else { return }
        for i in from...to {
            emit(SIMD4(start + Float(i) * step, y, diameter, diameter), diameter / 2)
        }
        #else
        let start = x0.rounded(), end = x1.rounded()
        let first = max(start, left.rounded(.down)), limit = min(end, right.rounded(.up))
        guard first < limit, let from = Int(exactly: first), let to = Int(exactly: limit) else { return }
        let wave: [Float] = [0, 1, 2, 2, 1, 0]
        let thickness = max(1, k).rounded()
        for x in from..<to {
            let phase = ((Float(x) - start) / k).rounded(.down).truncatingRemainder(dividingBy: Float(wave.count))
            guard let index = Int(exactly: phase) else { continue }
            emit(SIMD4(Float(x), (y + wave[index] * k).rounded(), 1, thickness), 0)
        }
        #endif
    }
}
