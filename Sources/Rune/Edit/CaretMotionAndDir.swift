import Foundation
#if canImport(CoreText)
import CoreText
#endif
#if canImport(CoreFoundation)
import CoreFoundation
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

public enum CaretVisualStepper: Sendable {
    private enum Seek: Equatable {
        case trySide(side: TextAffinity, then: TextAffinity?)
        case found(Int, TextAffinity)
        case edge
    }

    private enum Tried {
        case moved(Int, TextAffinity)
        case stayed
    }

    private static func stepSeek(_ state: Seek, event: Tried) -> Seek {
        switch (state, event) {
        case (.trySide, .moved(let j, let side)):
            return .found(j, side)
        case (.trySide(_, let thenSide?), .stayed):
            return .trySide(side: thenSide, then: nil)
        case (.trySide(_, nil), .stayed):
            return .edge
        default:
            return state
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
        guard CaretMotion.of(shaped, hidden: hidden) == .visual else {
            return nil
        }
        #if canImport(CoreText) && canImport(CoreGraphics)
        guard !shaped.lineStrings.isEmpty else {
            return (.edge, .ltr)
        }
        let lineIdx = lineIndex(in: shaped, utf8Offset: utf8Offset, side: side)
        let rec = shaped.lineStrings[lineIdx]
        let paraFlow: TextFlow = shaped.forcedDirection ?? (TextSystem.isRTLParagraph(rec.text) ? .rtl : .ltr)
        guard let ctLine = rec.ctLine else {
            return (.edge, paraFlow)
        }

        let authText = shaped.markerMap.authText
        let lineAuthUTF8Start = rec.utf8Start
        let lineAuthUTF8End = lineAuthUTF8Start + rec.text.utf8.count
        let clampedAuthUTF8 = min(max(lineAuthUTF8Start, utf8Offset), lineAuthUTF8End)

        let stops = visualCaretStops(
            in: ctLine,
            shaped: shaped,
            lineIdx: lineIdx,
            authText: authText,
            lineAuthUTF8Start: lineAuthUTF8Start,
            lineAuthUTF8End: lineAuthUTF8End
        )
        guard !stops.isEmpty else {
            return (.edge, paraFlow)
        }

        let landing = visual(stops: stops, at: clampedAuthUTF8, side: side, arrow: arrow)
        return (landing, paraFlow)
        #else
        return (.edge, .ltr)
        #endif
    }

    /// True if the cluster just right (or left) of `utf8Offset` is whitespace running that direction (`caret_motion.rs:223`).
    public static func spaceAhead(
        _ shaped: ShapedText,
        at utf8Offset: Int,
        side: TextAffinity,
        right: Bool
    ) -> Bool {
        #if canImport(CoreText) && canImport(CoreGraphics)
        guard !shaped.lineStrings.isEmpty else { return false }
        let lineIdx = lineIndex(in: shaped, utf8Offset: utf8Offset, side: side)
        let rec = shaped.lineStrings[lineIdx]
        guard let ctLine = rec.ctLine else { return false }
        let authText = shaped.markerMap.authText
        let stops = visualCaretStops(
            in: ctLine,
            shaped: shaped,
            lineIdx: lineIdx,
            authText: authText,
            lineAuthUTF8Start: rec.utf8Start,
            lineAuthUTF8End: rec.utf8Start + rec.text.utf8.count
        )
        guard let curIdx = findStopIndex(stops: stops, utf8: utf8Offset, side: side) else { return false }
        let neighborIdx = right ? curIdx + 1 : curIdx - 1
        guard neighborIdx >= 0 && neighborIdx < stops.count else { return false }
        let lo = min(stops[curIdx].authUTF8, stops[neighborIdx].authUTF8)
        let hi = max(stops[curIdx].authUTF8, stops[neighborIdx].authUTF8)
        guard hi > lo, hi <= authText.utf8.count else { return false }
        let sIdx = authText.utf8.index(authText.utf8.startIndex, offsetBy: lo)
        let eIdx = authText.utf8.index(authText.utf8.startIndex, offsetBy: hi)
        let sub = String(decoding: authText.utf8[sIdx..<eIdx], as: UTF8.self)
        let isSpace = !sub.isEmpty && sub.unicodeScalars.allSatisfy { $0.value == 0x20 || $0.value == 0xA0 }
        let neighborRTL = stops[curIdx].isRTL
        return isSpace && (neighborRTL != right)
        #else
        return false
        #endif
    }

    #if canImport(CoreText) && canImport(CoreGraphics)
    private struct VisualStop {
        var authUTF8: Int
        var x: Float
        var affinity: TextAffinity
        var isRTL: Bool
        var isWordBoundary: Bool
    }

    private static func lineIndex(in shaped: ShapedText, utf8Offset: Int, side: TextAffinity) -> Int {
        for (i, rec) in shaped.lineStrings.enumerated() {
            let start = rec.utf8Start
            let end = start + rec.text.utf8.count
            if utf8Offset < end || (utf8Offset == end && (side == .upstream || i == shaped.lineStrings.count - 1)) {
                return i
            }
        }
        return max(0, shaped.lineStrings.count - 1)
    }

    private static func authU16ToAuthUTF8(authText: String, u16Offset: Int) -> Int {
        let target = max(0, min(u16Offset, authText.utf16.count))
        let u16Idx = authText.utf16.index(authText.utf16.startIndex, offsetBy: target)
        let strIdx = u16Idx.samePosition(in: authText) ?? authText.endIndex
        return authText.utf8.distance(from: authText.utf8.startIndex, to: strIdx.samePosition(in: authText.utf8)!)
    }

    private static func visualCaretStops(
        in ctLine: CTLine,
        shaped: ShapedText,
        lineIdx: Int,
        authText: String,
        lineAuthUTF8Start: Int,
        lineAuthUTF8End: Int
    ) -> [VisualStop] {
        let baseAuthU16: Int
        if lineIdx < shaped.markerMap.lines.count {
            let lr = shaped.markerMap.lines[lineIdx]
            baseAuthU16 = lr.authU16Start - lr.shapedU16Start
        } else {
            let startIdx = authText.utf8.index(authText.utf8.startIndex, offsetBy: min(lineAuthUTF8Start, authText.utf8.count))
            baseAuthU16 = authText.utf16.distance(from: authText.utf16.startIndex, to: startIdx.samePosition(in: authText.utf16)!)
        }

        let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []
        var stops: [VisualStop] = []

        for run in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            let isRTL = CTRunGetStatus(run).contains(.rightToLeft)
            var indices = Array<CFIndex>(repeating: 0, count: glyphCount)
            CTRunGetStringIndices(run, CFRangeMake(0, glyphCount), &indices)
            let range = CTRunGetStringRange(run)
            let runEndU16 = range.location + range.length

            var boundariesU16: [Int] = []
            if isRTL {
                boundariesU16.append(runEndU16)
                for g in 0..<glyphCount {
                    boundariesU16.append(indices[g])
                }
            } else {
                for g in 0..<glyphCount {
                    boundariesU16.append(indices[g])
                }
                boundariesU16.append(runEndU16)
            }

            var seenOffsets: Set<Int> = []
            for localShapedU16 in boundariesU16 {
                let authU16 = max(0, baseAuthU16 + localShapedU16)
                let authUTF8 = min(max(lineAuthUTF8Start, authU16ToAuthUTF8(authText: authText, u16Offset: authU16)), lineAuthUTF8End)
                if seenOffsets.contains(authUTF8) { continue }
                seenOffsets.insert(authUTF8)
                let x = Float(CTLineGetOffsetForStringIndex(ctLine, localShapedU16, nil))
                let affinity: TextAffinity = isRTL ? .upstream : .downstream
                stops.append(VisualStop(
                    authUTF8: authUTF8,
                    x: x,
                    affinity: affinity,
                    isRTL: isRTL,
                    isWordBoundary: true
                ))
            }
        }

        stops.sort { a, b in
            if abs(a.x - b.x) > 0.01 { return a.x < b.x }
            return a.authUTF8 < b.authUTF8
        }
        return stops
    }

    private static func findStopIndex(stops: [VisualStop], utf8: Int, side: TextAffinity) -> Int? {
        let matches = stops.enumerated().filter { $0.element.authUTF8 == utf8 }
        if matches.isEmpty {
            return stops.enumerated().min(by: { abs($0.element.authUTF8 - utf8) < abs($1.element.authUTF8 - utf8) })?.offset
        }
        if let exact = matches.first(where: { $0.element.affinity == side }) {
            return exact.offset
        }
        return matches.first?.offset
    }

    private static func visual(stops: [VisualStop], at utf8: Int, side: TextAffinity, arrow: CaretArrow) -> CaretLanding {
        let other: TextAffinity = (side == .downstream) ? .upstream : .downstream
        var state = Seek.trySide(side: side, then: other)
        while true {
            switch state {
            case .trySide(let curSide, _):
                guard let idx = findStopIndex(stops: stops, utf8: utf8, side: curSide) else {
                    state = .edge
                    continue
                }
                let nextIdx: Int
                switch arrow {
                case .left, .wordLeft:
                    nextIdx = idx - 1
                case .right, .wordRight:
                    nextIdx = idx + 1
                }
                if nextIdx >= 0 && nextIdx < stops.count {
                    let target = stops[nextIdx]
                    let cur = stops[idx]
                    let moved = target.authUTF8 != utf8 || abs(target.x - cur.x) > 0.01
                    state = stepSeek(state, event: moved ? .moved(target.authUTF8, target.affinity) : .stayed)
                } else {
                    state = stepSeek(state, event: .stayed)
                }
            case .found(let j, let s):
                return .at(j, s)
            case .edge:
                return .edge
            }
        }
    }
    #endif
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

    /// Word-boundary segment ending at `j` (within its line), matching UAX #29 + ZWNJ preservation.
    private func uaxWordSegmentBefore(_ j: Int) -> (start: Int, isWord: Bool)? {
        guard j > 0 else { return nil }
        let bytes = Array(text.utf8)
        let clampedJ = min(j, bytes.count)
        let lineStartByte = bytes[..<clampedJ].lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        if lineStartByte == clampedJ {
            return (prevGraphemeOffset(clampedJ), false)
        }
        let segments = uaxWordSegments(inUTF8Range: lineStartByte..<clampedJ)
        return segments.last.map { ($0.start, $0.isWord) }
    }

    /// Word-boundary segment starting at `j` (within its line), matching UAX #29 + ZWNJ preservation.
    private func uaxWordSegmentAfter(_ j: Int) -> (end: Int, isWord: Bool)? {
        let len = text.utf8.count
        guard j < len else { return nil }
        let bytes = Array(text.utf8)
        let lineEndByte = bytes[j...].firstIndex(of: 0x0A) ?? len
        if lineEndByte == j {
            return (nextGraphemeOffset(j), false)
        }
        let segments = uaxWordSegments(inUTF8Range: j..<lineEndByte)
        return segments.first.map { ($0.1, $0.2) }
    }

    private func prevGraphemeOffset(_ offset: Int) -> Int {
        guard offset > 0 else { return 0 }
        let idx = stringIndex(forUTF8Offset: offset)
        let prev = text.index(before: idx)
        return text.utf8.distance(from: text.utf8.startIndex, to: prev.samePosition(in: text.utf8)!)
    }

    private func nextGraphemeOffset(_ offset: Int) -> Int {
        guard offset < text.utf8.count else { return text.utf8.count }
        let idx = stringIndex(forUTF8Offset: offset)
        let next = text.index(after: idx)
        return text.utf8.distance(from: text.utf8.startIndex, to: next.samePosition(in: text.utf8)!)
    }

    private func uaxWordSegments(inUTF8Range range: Range<Int>) -> [(start: Int, end: Int, isWord: Bool)] {
        let lo = stringIndex(forUTF8Offset: range.lowerBound)
        let hi = stringIndex(forUTF8Offset: range.upperBound)
        let slice = String(text[lo..<hi])
        var rawSegments: [(start: Int, end: Int, isWord: Bool)] = []

        #if canImport(CoreFoundation)
        let cfStr = slice as CFString
        let cfLen = CFStringGetLength(cfStr)
        let tok = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            cfStr,
            CFRangeMake(0, cfLen),
            kCFStringTokenizerUnitWordBoundary,
            nil
        )
        var cursorU16 = 0
        while CFStringTokenizerAdvanceToNextToken(tok) != [] {
            let tr = CFStringTokenizerGetCurrentTokenRange(tok)
            guard tr.location != kCFNotFound && tr.length > 0 else { break }
            let tokenStartU16 = max(cursorU16, tr.location)
            let tokenEndU16 = min(cfLen, tr.location + tr.length)
            if tokenStartU16 > cursorU16 {
                appendGapSegment(slice: slice, u16Lo: cursorU16, u16Hi: tokenStartU16, baseUTF8: range.lowerBound, into: &rawSegments)
            }
            appendTokenSegment(slice: slice, u16Lo: tokenStartU16, u16Hi: tokenEndU16, baseUTF8: range.lowerBound, into: &rawSegments)
            cursorU16 = tokenEndU16
        }
        if cursorU16 < cfLen {
            appendGapSegment(slice: slice, u16Lo: cursorU16, u16Hi: cfLen, baseUTF8: range.lowerBound, into: &rawSegments)
        }
        #else
        var idx = slice.startIndex
        while idx < slice.endIndex {
            let startIdx = idx
            let firstIsWord = slice[idx].unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "_" }
            idx = slice.index(after: idx)
            if firstIsWord {
                while idx < slice.endIndex {
                    let ch = slice[idx]
                    let w = ch.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "_" || $0.value == 0x200C }
                    if !w { break }
                    idx = slice.index(after: idx)
                }
            }
            let sOff = range.lowerBound + slice.utf8.distance(from: slice.utf8.startIndex, to: startIdx.samePosition(in: slice.utf8)!)
            let eOff = range.lowerBound + slice.utf8.distance(from: slice.utf8.startIndex, to: idx.samePosition(in: slice.utf8)!)
            rawSegments.append((sOff, eOff, firstIsWord))
        }
        #endif

        // UAX #29 WB4 keeps ZWNJ (\u{200C}) attached within Persian/Arabic words like "می‌شود".
        var merged: [(start: Int, end: Int, isWord: Bool)] = []
        var k = 0
        while k < rawSegments.count {
            let seg = rawSegments[k]
            if seg.isWord, k + 2 < rawSegments.count {
                let mid = rawSegments[k + 1]
                let nxt = rawSegments[k + 2]
                if nxt.isWord && isSingleZWNJ(utf8Range: mid.start..<mid.end) {
                    merged.append((seg.start, nxt.end, true))
                    k += 3
                    continue
                }
            }
            // Merge if trailing seg was coalesced in loop: check against `merged.last` when ZWNJ bridged.
            if let last = merged.last, last.isWord, !seg.isWord,
               isSingleZWNJ(utf8Range: seg.start..<seg.end),
               k + 1 < rawSegments.count, rawSegments[k + 1].isWord {
                merged[merged.count - 1].end = rawSegments[k + 1].end
                k += 2
                continue
            }
            merged.append(seg)
            k += 1
        }
        return merged
    }

    private func isSingleZWNJ(utf8Range: Range<Int>) -> Bool {
        guard utf8Range.count == 3 else { return false }
        let lo = stringIndex(forUTF8Offset: utf8Range.lowerBound)
        let hi = stringIndex(forUTF8Offset: utf8Range.upperBound)
        return text[lo..<hi] == "\u{200C}"
    }

    private func appendGapSegment(
        slice: String,
        u16Lo: Int,
        u16Hi: Int,
        baseUTF8: Int,
        into out: inout [(start: Int, end: Int, isWord: Bool)]
    ) {
        appendTokenSegment(slice: slice, u16Lo: u16Lo, u16Hi: u16Hi, baseUTF8: baseUTF8, into: &out)
    }

    private func appendTokenSegment(
        slice: String,
        u16Lo: Int,
        u16Hi: Int,
        baseUTF8: Int,
        into out: inout [(start: Int, end: Int, isWord: Bool)]
    ) {
        guard u16Hi > u16Lo else { return }
        let s16 = slice.utf16.index(slice.utf16.startIndex, offsetBy: u16Lo)
        let e16 = slice.utf16.index(slice.utf16.startIndex, offsetBy: u16Hi)
        let sIdx = s16.samePosition(in: slice) ?? slice.startIndex
        let eIdx = e16.samePosition(in: slice) ?? slice.endIndex
        guard eIdx > sIdx else { return }
        let sUTF8 = baseUTF8 + slice.utf8.distance(from: slice.utf8.startIndex, to: sIdx.samePosition(in: slice.utf8)!)
        let eUTF8 = baseUTF8 + slice.utf8.distance(from: slice.utf8.startIndex, to: eIdx.samePosition(in: slice.utf8)!)
        let isWord = slice[sIdx..<eIdx].unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        out.append((sUTF8, eUTF8, isWord))
    }
}
