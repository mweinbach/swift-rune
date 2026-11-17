import Foundation

/// Result of visual line motion (`TextSystem.moveLine` / `TextSystem.lineEdge`).
public struct TextCursorMove: Equatable, Sendable {
    public var utf8Offset: Int
    public var goalX: Float?
    public var affinity: TextAffinity

    public init(utf8Offset: Int, goalX: Float? = nil, affinity: TextAffinity = .downstream) {
        self.utf8Offset = utf8Offset
        self.goalX = goalX
        self.affinity = affinity
    }
}

internal struct PortableCaretCell: Sendable {
    enum PillEdge { case leading, trailing }
    let range: Range<Int>
    let left: Float
    let width: Float
    let rtl: Bool
    let space: Bool
    var pillEdge: PillEdge? = nil

    var leadingX: Float { rtl ? left + width : left }
    var trailingX: Float { rtl ? left : left + width }

    func isSelected(by bytes: Range<Int>) -> Bool {
        switch pillEdge {
        case .leading: return bytes.contains(range.lowerBound)
        case .trailing: return bytes.lowerBound < range.upperBound && range.upperBound <= bytes.upperBound
        case nil: return range.overlaps(bytes)
        }
    }

    func hit(at x: Float) -> Int {
        let nearLeft = x <= left + width * 0.5
        return nearLeft == rtl ? range.upperBound : range.lowerBound
    }
}

extension Array where Element == PortableCaretCell {
    /// Merge touching visual cells. A logical selection can leave disjoint runs on the same line.
    internal func appendSelectionRects(for bytes: Range<Int>, origin: Vec2, height: Float, toPoints: Float,
                                       into rects: inout [SIMD4<Float>]) {
        var span: (left: Float, right: Float)?
        func appendSpan() {
            if let span { rects.append(SIMD4(origin.x + span.left, origin.y, span.right - span.left, height)) }
        }
        for cell in self where cell.isSelected(by: bytes) {
            let left = cell.left * toPoints
            let right = (cell.left + cell.width) * toPoints
            if let current = span, left <= current.right + 0.01 {
                span = (current.left, Swift.max(current.right, right))
            } else {
                appendSpan()
                span = (left, right)
            }
        }
        appendSpan()
    }
}

extension ShapedText {
    internal var cursorLineCount: Int {
        #if canImport(CoreText) && canImport(CoreGraphics)
        if !lineStrings.isEmpty { return lineStrings.count }
        #endif
        return portableLines.count
    }

    private func cursorLine(at index: Int) -> (start: Int, text: String) {
        #if canImport(CoreText) && canImport(CoreGraphics)
        if !lineStrings.isEmpty { return (lineStrings[index].utf8Start, lineStrings[index].text) }
        #endif
        return (portableLines[index].utf8Start, portableLines[index].text)
    }

    /// A downstream caret at a soft wrap starts the following line. Hard newlines keep
    /// independent byte positions on each side of the break, including empty lines.
    public func lineIndex(forUTF8Offset utf8Offset: Int, affinity: TextAffinity = .downstream) -> Int {
        let count = cursorLineCount
        guard count > 1 else { return 0 }
        var low = 1, high = count
        while low < high {
            let mid = low + (high - low) / 2
            let start = cursorLine(at: mid).start
            let onPriorLine = utf8Offset < start || (utf8Offset == start && affinity == .upstream
                && utf8Offset == lineUTF8Range(at: mid - 1).upperBound)
            if onPriorLine { high = mid } else { low = mid + 1 }
        }
        return low - 1
    }

    fileprivate func isSoftEnd(_ byte: Int, on line: Int) -> Bool {
        line + 1 < cursorLineCount && byte == lineUTF8Range(at: line).upperBound
            && byte == cursorLine(at: line + 1).start
    }

    internal func selectsHardBreak(after line: Int, end: Int, selection: Range<Int>) -> Bool {
        guard line + 1 < cursorLineCount else { return false }
        let next = cursorLine(at: line + 1).start
        return end < next && selection.overlaps(end..<next)
    }

    internal func endBeforeNewline(on index: Int) -> Int {
        let line = cursorLine(at: index)
        let end = line.start + line.text.utf8.count
        if let last = line.text.last, last.isNewline { return end - last.utf8.count }
        return end
    }

    internal func visualCells(on line: Int) -> [PortableCaretCell] {
        if let bidi = portableBidiCells[line] { return bidi.filter { $0.pillEdge == nil } }
        let rec = portableLines[line]
        var byte = 0
        return rec.text.compactMap { ch in
            let start = byte
            byte += ch.utf8.count
            guard byte < rec.charOffsets.count else { return nil }
            let x = rec.charOffsets[start], end = rec.charOffsets[byte]
            return PortableCaretCell(range: (rec.utf8Start + start)..<(rec.utf8Start + byte),
                                     left: min(x, end), width: abs(end - x), rtl: end < x,
                                     space: ch == " " || ch == "\u{A0}")
        }.sorted { ($0.left, $0.range.lowerBound) < ($1.left, $1.range.lowerBound) }
    }

    // Native shapers store the visual caret x at each logical UTF-8 boundary. Only
    // extended grapheme boundaries are insertion points; x may decrease in RTL runs.
    internal func portableHit(on line: Int, at x: Float) -> Int {
        let rec = portableLines[line]
        guard let first = rec.charOffsets.first else { return rec.utf8Start }
        let localX = x - rec.originX
        if let cells = portableBidiCells[line], let last = cells.last {
            for cell in cells where localX <= cell.left + cell.width {
                return cell.hit(at: localX)
            }
            return last.hit(at: localX)
        }
        var nearest = 0
        var distance = abs(first - localX)
        var byte = 0
        for character in rec.text {
            byte += character.utf8.count
            guard byte < rec.charOffsets.count else { break }
            let candidate = abs(rec.charOffsets[byte] - localX)
            if candidate < distance {
                nearest = byte
                distance = candidate
            }
        }
        return rec.utf8Start + nearest
    }

    internal func portableCaret(on line: Int, at byte: Int, upstream: Bool = false) -> SIMD4<Float> {
        let rec = portableLines[line]
        let local = rec.text.graphemeByte(atOrBefore: max(byte, rec.utf8Start) - rec.utf8Start)
        var x = rec.charOffsets.indices.contains(local) ? rec.charOffsets[local] : (rec.charOffsets.last ?? 0)
        if let cells = portableBidiCells[line] {
            let clamped = rec.utf8Start + local
            let leading = cells.first { $0.pillEdge == .leading && $0.range.lowerBound == clamped }?.leadingX
                ?? cells.first { $0.pillEdge == nil && $0.range.lowerBound == clamped }?.leadingX
            let trailing = cells.first { $0.pillEdge == .trailing && $0.range.upperBound == clamped }?.trailingX
                ?? cells.first { $0.pillEdge == nil && $0.range.upperBound == clamped }?.trailingX
            x = upstream ? (trailing ?? leading ?? x) : (leading ?? trailing ?? x)
        }
        return SIMD4(rec.originX + x, rec.originY, 1.5, lineBoxHeightPt(line))
    }
}

extension String {
    /// Floor an arbitrary UTF-8 offset to an insertion point without decoding a partial scalar.
    internal func graphemeByte(atOrBefore offset: Int) -> Int {
        let count = utf8.count
        if offset <= 0 { return 0 }
        if offset >= count { return count }
        var index = utf8.index(startIndex, offsetBy: offset)
        var byte = offset
        while String.Index(index, within: self) == nil {
            utf8.formIndex(before: &index)
            byte -= 1
        }
        return byte
    }
}

extension TextSystem {
    public func caretRect(
        in shaped: ShapedText, utf8Offset: Int, affinity: TextAffinity, pixelScale: Float
    ) -> SIMD4<Float> {
        caretRect(in: shaped, utf8Offset: utf8Offset, upstream: affinity == .upstream, pixelScale: pixelScale)
    }

    /// Moves by visual lines, preserving the horizontal column in element-local points.
    public func moveLine(
        in shaped: ShapedText,
        utf8Offset: Int,
        delta: Int,
        goalX: Float? = nil,
        affinity: TextAffinity = .downstream,
        pixelScale: Float = 1.0
    ) -> TextCursorMove? {
        let count = shaped.cursorLineCount
        guard count > 0 else { return nil }
        let line = shaped.lineIndex(forUTF8Offset: utf8Offset, affinity: affinity)
        let x = goalX ?? caretRect(in: shaped, utf8Offset: utf8Offset, affinity: affinity, pixelScale: pixelScale).x
        if delta < -line { return TextCursorMove(utf8Offset: 0, goalX: x) }
        guard delta < count - line else { return nil }
        return caretHit(in: shaped, on: line + delta, atX: x, pixelScale: pixelScale)
    }

    /// Pick the caret on this visual line that is physically closest to the requested column.
    /// Opposite-direction runs can have two distinct caret positions at one authored byte.
    internal func caretHit(in shaped: ShapedText, on target: Int, atX x: Float, pixelScale: Float) -> TextCursorMove {
        guard (0..<shaped.cursorLineCount).contains(target) else { return TextCursorMove(utf8Offset: 0, goalX: x) }
        let byte: Int
        #if canImport(CoreText) && canImport(CoreGraphics)
        if !shaped.lineStrings.isEmpty {
            let rec = shaped.lineStrings[target]
            let y = rec.originY + shaped.lineBoxHeightPt(target) * 0.5
            let hit = hitTestUTF8Offset(in: shaped, localX: x, localY: y, pixelScale: pixelScale)
            byte = rec.utf8Start + rec.text.graphemeByte(atOrBefore: max(hit, rec.utf8Start) - rec.utf8Start)
        } else {
            byte = shaped.portableHit(on: target, at: x)
        }
        #else
        byte = shaped.portableHit(on: target, at: x)
        #endif
        var affinity = TextAffinity.downstream
        if shaped.isSoftEnd(byte, on: target) {
            affinity = .upstream
        } else if target == 0 || !shaped.isSoftEnd(byte, on: target - 1) {
            let next = caretRect(in: shaped, utf8Offset: byte, affinity: .downstream, pixelScale: pixelScale)
            let prior = caretRect(in: shaped, utf8Offset: byte, affinity: .upstream, pixelScale: pixelScale)
            if abs(prior.x - x) < abs(next.x - x) { affinity = .upstream }
        }
        return TextCursorMove(utf8Offset: byte, goalX: x, affinity: affinity)
    }

    /// Returns the authored start or end of the visual line at this caret.
    public func lineEdge(
        in shaped: ShapedText, utf8Offset: Int, toEnd: Bool, affinity: TextAffinity = .downstream
    ) -> TextCursorMove {
        guard shaped.cursorLineCount > 0 else { return TextCursorMove(utf8Offset: 0, affinity: affinity) }
        let line = shaped.lineIndex(forUTF8Offset: utf8Offset, affinity: affinity)
        let byte = toEnd ? shaped.endBeforeNewline(on: line) : shaped.lineUTF8Range(at: line).lowerBound
        return TextCursorMove(utf8Offset: byte, affinity: toEnd && shaped.isSoftEnd(byte, on: line) ? .upstream : .downstream)
    }
}
