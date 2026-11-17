import Foundation
#if canImport(CoreText)
import CoreText
#endif

// MARK: - Direction Keys (crates/rune/src/edit/direction_keys.rs)

/// Text reading direction (`rune::el::Flow`).
public enum TextFlow: String, Sendable, Hashable, Codable {
    case ltr
    case rtl
}

/// The direction a field's lines read in (`rune::edit::FieldDir`).
public enum FieldDir: Sendable, Hashable {
    /// As its text and the element give it.
    case natural
    /// Set by Ctrl+Shift: every line, whatever its words.
    case forced(TextFlow)
}

/// How far the Ctrl+Shift direction chord has gone (`rune::edit::DirChord`).
public enum DirChord: Sendable, Equatable {
    case idle
    /// Ctrl is down, nothing else.
    case ctrl
    /// Ctrl and one Shift are down, nothing else: its release sets the direction.
    case armed(KeySide)
}

/// Steps the Ctrl+Left/Right Shift field-direction chord (`direction_keys.rs:37`).
/// macOS has no such gesture and always returns `(.idle, nil)`.
public func stepDirChord(
    _ state: DirChord,
    modifier: ModifierKey,
    pressed: Bool,
    ctrl: Bool,
    shift: Bool,
    platform: KeyPlatform = .current
) -> (DirChord, TextFlow?) {
    guard !platform.isMac else { return (.idle, nil) }
    switch (state, modifier, pressed) {
    case (.idle, .controlLeft, true), (.idle, .controlRight, true):
        return !shift ? (.ctrl, nil) : (.idle, nil)
    case (.ctrl, .shiftLeft, true) where ctrl:
        return (.armed(.left), nil)
    case (.ctrl, .shiftRight, true) where ctrl:
        return (.armed(.right), nil)
    case (.armed(let side), .shiftLeft, false),
         (.armed(let side), .shiftRight, false),
         (.armed(let side), .controlLeft, false),
         (.armed(let side), .controlRight, false):
        return (.idle, side == .left ? .ltr : .rtl)
    case (.armed, .shiftLeft, true),
         (.armed, .shiftRight, true),
         (.armed, .controlLeft, true),
         (.armed, .controlRight, true):
        return (.idle, nil)
    case (.ctrl, .controlLeft, false), (.ctrl, .controlRight, false):
        return (.idle, nil)
    case (.ctrl, _, _):
        return (.ctrl, nil)
    default:
        return (.idle, nil)
    }
}

extension TextEdit {
    /// The direction Ctrl+Shift set, if it set one (`direction_keys.rs:58`).
    public var forcedDir: TextFlow? {
        switch dir {
        case .natural: return nil
        case .forced(let flow): return flow
        }
    }

    /// Sets every line's direction, as Ctrl+Shift does (`direction_keys.rs:66`).
    public mutating func forceDir(_ flow: TextFlow) {
        dir = .forced(flow)
    }
}

// MARK: - Caret Motion & Word Stepping (crates/rune/src/edit/caret_motion.rs)

/// How Left/Right arrows move through a field's text (`caret_motion.rs:138`).
public enum CaretMotion: Sendable, Equatable {
    /// By character or word in the text's order (only LTR runs, or a hidden secret).
    case logical
    /// Across the line as drawn: the text holds right-to-left runs.
    case visual

    /// Determines logical vs visual caret stepping for `shaped` text (`caret_motion.rs:146`).
    public static func of(_ shaped: ShapedText, hidden: Bool) -> CaretMotion {
        if hidden { return .logical }
        if shaped.forcedDirection == .rtl { return .visual }
        // A paragraph laid out right to left (`layout.is_rtl()`).
        if shaped.lineIsRTL.contains(true) || !shaped.portableBidiCells.isEmpty { return .visual }
        #if canImport(CoreText) && canImport(CoreGraphics)
        for rec in shaped.lineStrings {
            if TextSystem.isRTLParagraph(rec.text) {
                return .visual
            }
            if let ctLine = rec.ctLine, let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] {
                for run in runs where CTRunGetStatus(run).contains(.rightToLeft) {
                    return .visual
                }
            }
        }
        return .logical
        #else
        for line in shaped.portableLines where TextSystem.isRTLParagraph(line.text) {
            return .visual
        }
        return .logical
        #endif
    }
}

/// Which way, and how far, one arrow press moves (`caret_motion.rs:154`).
public enum CaretArrow: Sendable, Equatable {
    case left
    case right
    case wordLeft
    case wordRight
}

/// Where an arrow press lands across the drawn line (`caret_motion.rs:191`).
public enum CaretLanding: Sendable, Equatable {
    case at(Int, TextAffinity)
    case edge
}

#if canImport(CoreText) && canImport(CoreGraphics)
extension CTLine {
    internal var hasMixedRunDirections: Bool {
        guard let runs = CTLineGetGlyphRuns(self) as? [CTRun], let first = runs.first else { return false }
        let rtl = CTRunGetStatus(first).contains(.rightToLeft)
        return runs.dropFirst().contains { CTRunGetStatus($0).contains(.rightToLeft) != rtl }
    }

    /// A trailing edge's index is the last UTF-16 unit of the cluster. Consumers use insertion indices.
    internal func enumerateInsertionOffsets(_ visit: @escaping (Int, Bool, CGFloat) -> Bool) {
        CTLineEnumerateCaretOffsets(self) { x, index, leading, stop in
            if visit(leading ? index : index + 1, leading, CGFloat(x)) { stop.pointee = true }
        }
    }

    internal func insertionOffset(at utf16: Int, upstream: Bool) -> CGFloat {
        var secondary: CGFloat = 0
        var offset = CTLineGetOffsetForStringIndex(self, utf16, &secondary)
        if offset != secondary {
            enumerateInsertionOffsets { index, leading, x in
                guard index == utf16 else { return false }
                offset = x
                return leading != upstream
            }
        }
        return offset
    }
}

extension ShapedText {
    /// Visual grapheme cells in native device pixels, keyed by their authored UTF-8 ranges.
    internal func coreTextVisualCells(on row: Int, in ctLine: CTLine) -> [PortableCaretCell] {
        let rec = lineStrings[row]
        var offsets: [Int: SIMD2<Float>] = [:]
        ctLine.enumerateInsertionOffsets { index, leading, x in
            offsets[index, default: SIMD2(repeating: .nan)][leading ? 0 : 1] = Float(x)
            return false
        }
        func x(at index: Int, leading: Bool) -> Float {
            if let pair = offsets[index] {
                let preferred = leading ? pair.x : pair.y
                if preferred.isFinite { return preferred }
                let alternate = leading ? pair.y : pair.x
                if alternate.isFinite { return alternate }
            }
            return Float(CTLineGetOffsetForStringIndex(ctLine, index, nil))
        }
        let nativeStart = CTLineGetStringRange(ctLine).location
        let map = markerMap
        let meta = map.lines.indices.contains(row) ? map.lines[row] : nil
        func nativeIndex(for localU16: Int) -> Int {
            if let meta, !map.entries.isEmpty {
                let absolute = map.shapedU16(forAuthU16: meta.authU16Start + localU16)
                let clamped = min(max(absolute, meta.shapedU16Start), meta.shapedU16End)
                return nativeStart + clamped - meta.shapedU16Start
            }
            return nativeStart + localU16
        }
        var cells: [PortableCaretCell] = []
        var utf8 = rec.utf8Start
        var u16 = 0
        for ch in rec.text {
            let leading = x(at: nativeIndex(for: u16), leading: true)
            u16 += ch.utf16.count
            let trailing = x(at: nativeIndex(for: u16), leading: false)
            let end = utf8 + ch.utf8.count
            cells.append(PortableCaretCell(range: utf8..<end, left: min(leading, trailing),
                                          width: abs(trailing - leading), rtl: leading > trailing,
                                          space: ch == " " || ch == "\u{A0}"))
            utf8 = end
        }
        cells.sort { ($0.left, $0.range.lowerBound) < ($1.left, $1.range.lowerBound) }
        return cells
    }
}
#endif

public enum CaretVisualStepper: Sendable {
    private struct VisualLine {
        var text: String
        var utf8Start: Int
        var flow: TextFlow
        var cells: [PortableCaretCell]
        var caretX: Float

        func neighbor(right: Bool) -> Int? {
            right ? cells.firstIndex { $0.left + $0.width > caretX + 0.001 }
                  : cells.lastIndex { $0.left < caretX - 0.001 }
        }
    }

    /// Computes visual bidi Left/Right/WordLeft/WordRight movement inside `shaped` (`caret_motion.rs:204`).
    public static func visualIn(
        _ shaped: ShapedText,
        at utf8Offset: Int,
        side: TextAffinity,
        arrow: CaretArrow,
        hidden: Bool
    ) -> (CaretLanding, TextFlow)? {
        guard CaretMotion.of(shaped, hidden: hidden) == .visual else { return nil }
        guard let line = visualLine(in: shaped, at: utf8Offset, side: side) else {
            return (.edge, shaped.forcedDirection ?? .ltr)
        }
        let right = arrow == .right || arrow == .wordRight
        guard var index = line.neighbor(right: right) else { return (.edge, line.flow) }
        if arrow == .wordLeft || arrow == .wordRight {
            let boundaries = Set(line.text.ranges(of: #/\b/#.wordBoundaryKind(.default)).map {
                line.utf8Start + line.text.utf8.distance(from: line.text.startIndex, to: $0.lowerBound)
            })
            let step = right ? 1 : -1
            while line.cells.indices.contains(index + step) {
                let cell = line.cells[index]
                let edge = right == cell.rtl ? cell.range.lowerBound : cell.range.upperBound
                if boundaries.contains(edge) && !cell.space { break }
                index += step
            }
        }
        let cell = line.cells[index]
        if right == cell.rtl { return (.at(cell.range.lowerBound, .downstream), line.flow) }
        return (.at(cell.range.upperBound, .upstream), line.flow)
    }

    /// True if the cluster just right (or left) of `utf8Offset` is whitespace running that direction (`caret_motion.rs:223`).
    public static func spaceAhead(
        _ shaped: ShapedText,
        at utf8Offset: Int,
        side: TextAffinity,
        right: Bool
    ) -> Bool {
        guard let line = visualLine(in: shaped, at: utf8Offset, side: side),
              let index = line.neighbor(right: right) else { return false }
        return line.cells[index].space && line.cells[index].rtl != right
    }

    private static func visualLine(in shaped: ShapedText, at byte: Int, side: TextAffinity) -> VisualLine? {
        let row = shaped.lineIndex(forUTF8Offset: byte, affinity: side)
        func flow(_ text: String) -> TextFlow {
            let rtl = shaped.lineIsRTL.indices.contains(row) ? shaped.lineIsRTL[row] : TextSystem.isRTLParagraph(text)
            return shaped.forcedDirection ?? (rtl ? .rtl : .ltr)
        }
        if shaped.portableLines.indices.contains(row) {
            let rec = shaped.portableLines[row]
            let x = shaped.portableCaret(on: row, at: byte, upstream: side == .upstream).x - rec.originX
            return VisualLine(text: rec.text, utf8Start: rec.utf8Start, flow: flow(rec.text),
                              cells: shaped.visualCells(on: row), caretX: x)
        }
        #if canImport(CoreText) && canImport(CoreGraphics)
        guard shaped.lineStrings.indices.contains(row) else { return nil }
        let rec = shaped.lineStrings[row]
        guard let ctLine = rec.ctLine else {
            return VisualLine(text: rec.text, utf8Start: rec.utf8Start, flow: flow(rec.text), cells: [], caretX: 0)
        }

        let cells = shaped.coreTextVisualCells(on: row, in: ctLine)
        let localByte = rec.text.graphemeByte(atOrBefore: max(byte, rec.utf8Start) - rec.utf8Start)
        let insertion = rec.utf8Start + localByte
        let leading = cells.first { $0.range.lowerBound == insertion }?.leadingX
        let trailing = cells.first { $0.range.upperBound == insertion }?.trailingX
        let x = side == .upstream ? trailing ?? leading : leading ?? trailing
        return VisualLine(text: rec.text, utf8Start: rec.utf8Start, flow: flow(rec.text), cells: cells, caretX: x ?? 0)
        #else
        return nil
        #endif
    }
}

// MARK: - UAX #29 Word Segmentation + ZWNJ + Pill Stepping (caret_motion.rs:36-135)

extension TextEdit {
    /// Steps back one UAX #29 word segment (respecting ZWNJ joins and treating pills as single words).
    public func prevWord(_ i: Int, platform: KeyPlatform = .current) -> Int {
        _ = platform
        if isSecure && !isRevealed { return 0 }
        var j = min(max(0, i), text.utf8.count)
        while true {
            if let start = pillBefore(j) {
                return start
            }
            guard let (start, isWord) = uaxWordSegmentBefore(j) else {
                return 0
            }
            if !isWord {
                if pillBefore(start) != nil {
                    return start
                }
                j = start
                continue
            }
            let pillEnd = richMarks.filter { $0.mark.isPill && start < $0.end && $0.end < j }
                .map(\.end)
                .max()
            return pillEnd ?? start
        }
    }

    /// Steps forward one UAX #29 word segment (respecting ZWNJ joins, platform word-end conventions, and pills).
    public func nextWord(_ i: Int, platform: KeyPlatform = .current) -> Int {
        if isSecure && !isRevealed { return text.utf8.count }
        let len = text.utf8.count
        var j = min(max(0, i), len)
        if !platform.isMac {
            if let end = pillAfter(j) {
                j = end
            } else if case let (end, true)? = uaxWordSegmentAfter(j) {
                j = clipToPillStart(j, end)
            }
            while j < len && pillAfter(j) == nil {
                if case let (end, false)? = uaxWordSegmentAfter(j) {
                    j = end
                } else {
                    break
                }
            }
            return j
        }
        while true {
            if let end = pillAfter(j) {
                return end
            }
            guard let (end, isWord) = uaxWordSegmentAfter(j) else {
                return len
            }
            if !isWord {
                j = end
                continue
            }
            return clipToPillStart(j, end)
        }
    }

    private func clipToPillStart(_ j: Int, _ end: Int) -> Int {
        richMarks.filter { $0.mark.isPill && j < $0.start && $0.start < end }
            .map(\.start)
            .min() ?? end
    }

    /// A hard line break is its own segment, including a two-byte CRLF.
    private func uaxWordSegmentBefore(_ j: Int) -> (start: Int, isWord: Bool)? {
        let end = stringIndex(forUTF8Offset: j)
        guard end > text.startIndex else { return nil }
        let previous = text.index(before: end)
        if text[previous].isNewline {
            return (text.utf8.distance(from: text.startIndex, to: previous), false)
        }
        let start = text[..<end].lastIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.startIndex
        return uaxWordSegment(in: text[start..<end], forward: false)
    }

    private func uaxWordSegmentAfter(_ j: Int) -> (end: Int, isWord: Bool)? {
        let start = stringIndex(forUTF8Offset: j)
        guard start < text.endIndex else { return nil }
        if text[start].isNewline {
            return (text.utf8.distance(from: text.startIndex, to: text.index(after: start)), false)
        }
        let end = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex
        return uaxWordSegment(in: text[start..<end], forward: true)
    }

    /// Use the same Unicode word boundaries as visual arrow navigation. A segment is a word
    /// if it contains a letter or number, as in upstream `edit/caret_motion.rs`.
    private func uaxWordSegment(in line: Substring, forward: Bool) -> (Int, Bool)? {
        let boundaries = line.ranges(of: #/\b/#.wordBoundaryKind(.default))
        guard let edge = (forward ? boundaries.dropFirst().first : boundaries.dropLast().last)?.lowerBound else { return nil }
        let segment = forward ? line[..<edge] : line[edge...]
        let isWord = segment.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil }
        return (text.utf8.distance(from: text.startIndex, to: edge), isWord)
    }
}
