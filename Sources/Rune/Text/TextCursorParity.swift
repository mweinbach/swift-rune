import Foundation
#if canImport(CoreText)
import CoreText
#endif
#if canImport(simd)
import simd
#endif

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

extension ShapedText {
    /// Returns the visual line index containing `utf8Offset`, respecting soft-wrap `affinity` (`cursor.rs`).
    ///
    /// At a soft wrap boundary where `line[i]` ends at `k` and `line[i+1]` starts at `k`:
    /// - `.downstream` picks `i + 1` (start of next visual line)
    /// - `.upstream` picks `i` (end of current visual line)
    /// Hard newlines (`line[i+1].utf8Start > lineEnd`) keep `utf8Offset == lineEnd` on `line[i]`.
    public func lineIndex(forUTF8Offset utf8Offset: Int, affinity: TextAffinity = .downstream) -> Int {
        guard !lineStrings.isEmpty else { return 0 }
        let clamped = max(0, utf8Offset)
        for i in 0..<lineStrings.count {
            let rec = lineStrings[i]
            let lineStart = rec.utf8Start
            let lineEnd = lineStart + rec.text.utf8.count
            if clamped < lineEnd {
                return i
            }
            if clamped == lineEnd {
                let isSoftWrappedToNext = (i + 1 < lineStrings.count) && (lineStrings[i + 1].utf8Start == lineEnd)
                if isSoftWrappedToNext && affinity == .downstream {
                    return i + 1
                }
                return i
            }
        }
        return lineStrings.count - 1
    }
}

extension TextSystem {
    /// Caret rectangle `(x, y, width, height)` in element-local points honoring `TextAffinity` at soft wraps.
    public func caretRect(
        in shaped: ShapedText,
        utf8Offset: Int,
        affinity: TextAffinity,
        pixelScale: Float
    ) -> SIMD4<Float> {
        guard !shaped.lineStrings.isEmpty else {
            return SIMD4<Float>(0, 0, 1.5, shaped.lineHeight)
        }
        let lineIdx = shaped.lineIndex(forUTF8Offset: utf8Offset, affinity: affinity)
        let rec = shaped.lineStrings[lineIdx]
        let xPt = xInLine(rec: rec, utf8Offset: utf8Offset, pixelScale: pixelScale)
        return SIMD4<Float>(xPt, rec.originY, 1.5, shaped.lineHeight)
    }

    /// Moves visually up (`delta < 0`) or down (`delta > 0`) by visual lines, preserving `goalX` in points
    /// across wrapped lines (`rune::text::cursor::move_line`).
    public func moveLine(
        in shaped: ShapedText,
        utf8Offset: Int,
        delta: Int,
        goalX: Float? = nil,
        affinity: TextAffinity = .downstream,
        pixelScale: Float = 1.0
    ) -> TextCursorMove {
        guard !shaped.lineStrings.isEmpty else {
            return TextCursorMove(utf8Offset: 0, goalX: goalX, affinity: affinity)
        }
        let lineIdx = shaped.lineIndex(forUTF8Offset: utf8Offset, affinity: affinity)
        let currentRec = shaped.lineStrings[lineIdx]
        let targetX = goalX ?? xInLine(rec: currentRec, utf8Offset: utf8Offset, pixelScale: pixelScale)
        let nextIdx = (lineIdx + delta).clamped(to: 0...(shaped.lineStrings.count - 1))
        let targetRec = shaped.lineStrings[nextIdx]
        let nextOffset = utf8OffsetOnLine(rec: targetRec, xPt: targetX, pixelScale: pixelScale)
        // Visual cursor landed at `nextOffset` on `nextIdx`; choose upstream if it hit the end of a soft-wrapped line.
        let lineEnd = targetRec.utf8Start + targetRec.text.utf8.count
        let isSoftEnd = (nextIdx + 1 < shaped.lineStrings.count) && (shaped.lineStrings[nextIdx + 1].utf8Start == lineEnd)
        let nextAffinity: TextAffinity = (isSoftEnd && nextOffset == lineEnd) ? .upstream : .downstream
        return TextCursorMove(utf8Offset: nextOffset, goalX: targetX, affinity: nextAffinity)
    }

    /// Moves to the start (`toEnd == false`) or visual end (`toEnd == true`) of the current visual line (`line_edge`).
    public func lineEdge(
        in shaped: ShapedText,
        utf8Offset: Int,
        toEnd: Bool,
        affinity: TextAffinity = .downstream
    ) -> TextCursorMove {
        guard !shaped.lineStrings.isEmpty else {
            return TextCursorMove(utf8Offset: 0, goalX: nil, affinity: affinity)
        }
        let lineIdx = shaped.lineIndex(forUTF8Offset: utf8Offset, affinity: affinity)
        let rec = shaped.lineStrings[lineIdx]
        let lineStart = rec.utf8Start
        let lineEnd = lineStart + rec.text.utf8.count
        if !toEnd {
            return TextCursorMove(utf8Offset: lineStart, goalX: nil, affinity: .downstream)
        }
        let isSoftEnd = (lineIdx + 1 < shaped.lineStrings.count) && (shaped.lineStrings[lineIdx + 1].utf8Start == lineEnd)
        return TextCursorMove(utf8Offset: lineEnd, goalX: nil, affinity: isSoftEnd ? .upstream : .downstream)
    }

    private func xInLine(
        rec: (utf8Start: Int, text: String, originY: Float, originX: Float, ctLine: Any?),
        utf8Offset: Int,
        pixelScale: Float
    ) -> Float {
        let localUTF8 = (utf8Offset - rec.utf8Start).clamped(to: 0...rec.text.utf8.count)
        let prefixUTF8 = rec.text.utf8.prefix(localUTF8)
        let prefixStr = String(decoding: prefixUTF8, as: UTF8.self)
        #if canImport(CoreText) && canImport(CoreGraphics)
        if let ctLineObj = rec.ctLine {
            let ctLine = ctLineObj as! CTLine
            let scale = max(pixelScale, 1.0)
            let offsetPx = CTLineGetOffsetForStringIndex(ctLine, prefixStr.utf16.count, nil)
            return rec.originX + Float(offsetPx) / scale
        }
        #endif
        let cellPt = Float(PortableGlyphFont.glyphWidth) * (1.0 / 16.0) * 14.0
        return rec.originX + Float(prefixStr.count) * cellPt
    }

    private func utf8OffsetOnLine(
        rec: (utf8Start: Int, text: String, originY: Float, originX: Float, ctLine: Any?),
        xPt: Float,
        pixelScale: Float
    ) -> Int {
        guard !rec.text.isEmpty else { return rec.utf8Start }
        #if canImport(CoreText) && canImport(CoreGraphics)
        if let ctLineObj = rec.ctLine {
            let ctLine = ctLineObj as! CTLine
            let scale = max(pixelScale, 1.0)
            let relPx = CGFloat((xPt - rec.originX) * scale)
            let u16Idx = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: relPx, y: 0))
            if u16Idx == kCFNotFound || u16Idx <= 0 {
                return rec.utf8Start
            }
            let clampedU16 = min(u16Idx, rec.text.utf16.count)
            let prefixStr = String(decoding: rec.text.utf16.prefix(clampedU16), as: UTF16.self)
            return rec.utf8Start + prefixStr.utf8.count
        }
        #endif
        let cellPt = max(Float(1.0), Float(PortableGlyphFont.glyphWidth) * (1.0 / 16.0) * 14.0)
        let idx = Int(((xPt - rec.originX) / cellPt).rounded()).clamped(to: 0...rec.text.count)
        let charIdx = rec.text.index(rec.text.startIndex, offsetBy: idx)
        return rec.utf8Start + String(rec.text[..<charIdx]).utf8.count
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
