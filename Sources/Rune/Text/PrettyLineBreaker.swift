import Foundation
#if canImport(CoreText)
import CoreText
#elseif canImport(_FoundationICU)
internal import _FoundationICU
#endif

/// Blink's `ScoreLineBreaker` (`text-wrap-style: pretty`, opt-in via `TextSystem.setPrettyWrap(true)`).
/// Ported from `crates/rune/src/text/pretty.rs` (`#882`, `#919`):
/// re-breaks a wrapped proportional paragraph whose greedy last line holds one short word
/// (`advance - trailingWs < maxWidth / 3` and no isolate / break opportunity inside its trimmed range)
/// across its last `4` lines while keeping the exact greedy line count.
///
/// `#933`: pills (a link's icon, a mention's chip) wrap prettily too, as their inline boxes do in
/// Chromium: each box is a cluster at its position, taking its width (never a space), and a break
/// opportunity at a box's position breaks before the box. `wrapAnywhere` text is scored too, but a
/// paragraph with a word broken inside to fit (Parley's `BreakReason::Emergency`) keeps its greedy
/// lines, as Blink turns the score breaker off once a line overflows (`RetryAfterOverflow`).
///
/// `#1023`: a paragraph with a line that holds no text, only an inline box, keeps its greedy
/// breaks (nothing can slice such a line).
public enum PrettyLineBreaker {
    /// Maximum trailing lines of a paragraph considered by `ScoreLineBreaker::Optimize`.
    private static let maxLines = 4
    /// `kOrphansPenalty` on a break immediately before the last word (CSS px^2).
    private static let orphansPenalty: Float = 10_000.0
    /// `kScoreOverfull`.
    private static let overfull: Float = 1e12
    /// `kLastLinePenaltyMultiplier`.
    private static let lastLinePenaltyMultiplier: Float = 4.0
    /// `LayoutUnit::AddEpsilon`: a line fits up to 1/64 CSS px past its width.
    private static let epsilon: Float = 1.0 / 64.0

    private struct Candidate {
        var atU16: Int
        var noBreakCss: Float
        var ifBreakCss: Float
        var penalty: Float
    }

    internal struct GreedyLineInfo {
        var u16Start: Int
        var u16End: Int
        var widthPx: Float
        var trailingWsPx: Float
        var hasRTLRun: Bool
        #if canImport(CoreText)
        var ctLine: CTLine? = nil
        var strIndexBase: Int = 0
        #endif
        /// A word broken inside to fit (`wrapAnywhere`'s overflow-wrap): Parley's `BreakReason::Emergency`.
        var isEmergency: Bool = false
    }

    /// Returns per-line width caps (in device px) for the prefix lines of `lines[first..<n-1]`
    /// that must break earlier to pull a lone short word down onto the final line, or `nil` if
    /// greedy breaks stand. `boxU16` holds the shaped positions of inline boxes (pill/icon
    /// placeholders): they take room in a line but give no break opportunities of their own.
    internal static func prettyLineCaps(
        lines: [GreedyLineInfo],
        in shapedNS: NSString,
        fontSizePt: Float,
        scale: Float,
        maxWidthPx: Float,
        boxU16: Set<Int> = [],
        advanceAtUTF16: ((Int) -> Float)? = nil
    ) -> [Int: CGFloat]? {
        let n = lines.count
        // `#1023`: a line that holds no text (only an inline box) reports an empty range at
        // `usize::MAX` in Parley: nothing here can slice such a line, so keep the greedy breaks.
        // The shaped text here carries each box as a placeholder unit, so a line whose units are
        // all box positions is that line.
        guard n >= 2,
              lines.allSatisfy({ isSliceable($0, in: shapedNS, boxU16: boxU16) }),
              !lines.contains(where: { $0.hasRTLRun }) else { return nil }
        guard scale > 0, maxWidthPx > 0 else { return nil }
        // A word broken inside to fit (`wrap_anywhere`'s overflow-wrap) keeps the greedy lines: Blink
        // turns the score breaker off once a line overflows and breaks again (`RetryAfterOverflow`).
        if lines.contains(where: { $0.isEmergency }) { return nil }

        let last = lines[n - 1]
        // `ShouldOptimize`: last line shorter than a third of the line width.
        guard (last.widthPx - last.trailingWsPx) < (maxWidthPx / 3.0) else { return nil }

        // Nor when the last line holds a bidi isolate (`\u{2066}`..`\u{2069}`, `#919`).
        let lastRange = NSRange(location: last.u16Start, length: max(0, last.u16End - last.u16Start))
        if lastRange.length > 0 {
            let lastSub = shapedNS.substring(with: lastRange)
            if lastSub.unicodeScalars.contains(where: { $0.value >= 0x2066 && $0.value <= 0x2069 }) {
                return nil
            }
        }

        let first = max(0, n - maxLines)
        let window = Array(lines[first..<n])
        let spanStart = window[0].u16Start
        let spanEnd = trimmedU16End(in: shapedNS, start: spanStart, end: last.u16End)
        guard spanEnd > spanStart else { return nil }

        let lastWordsEnd = trimmedU16End(in: shapedNS, start: last.u16Start, end: last.u16End)
        let breaks = lineBreakOpportunities(in: shapedNS, from: spanStart, to: spanEnd, boxU16: boxU16)
        // Only optimize when the last line has no internal break opportunity (a single word/unit).
        if breaks.contains(where: { $0 > last.u16Start && $0 < lastWordsEnd }) {
            return nil
        }

        // Each candidate is scored in CSS points relative to the first line under review.
        let xAt: (Int) -> Float
        if let advanceAtUTF16 {
            let origin = advanceAtUTF16(spanStart)
            xAt = { advanceAtUTF16($0) - origin }
        } else {
            #if canImport(CoreText)
            var offsets: [Float] = []
            var advance: Float = 0
            for line in window {
                guard let ctLine = line.ctLine else { return nil }
                offsets.append(advance)
                advance += Float(CTLineGetOffsetForStringIndex(ctLine, line.u16End - line.strIndexBase, nil))
            }
            xAt = { pos in
                guard let idx = window.lastIndex(where: { pos >= $0.u16Start }),
                      let ctLine = window[idx].ctLine else { return 0 }
                let line = window[idx]
                let local = min(pos, line.u16End) - line.strIndexBase
                return offsets[idx] + Float(CTLineGetOffsetForStringIndex(ctLine, local, nil))
            }
            #else
            return nil
            #endif
        }

        func endBeforePx(atU16 pos: Int) -> Float {
            let trimmed = trimmedU16End(in: shapedNS, start: spanStart, end: pos)
            guard trimmed > spanStart else { return 0 }
            return xAt(trimmed)
        }

        let invScale = 1.0 / scale
        var cands: [Candidate] = [
            Candidate(atU16: spanStart, noBreakCss: 0, ifBreakCss: 0, penalty: 0),
        ]
        for b in breaks {
            cands.append(Candidate(
                atU16: b,
                noBreakCss: xAt(b) * invScale,
                ifBreakCss: endBeforePx(atU16: b) * invScale,
                penalty: 0
            ))
        }
        let endCss = endBeforePx(atU16: spanEnd) * invScale
        cands.append(Candidate(atU16: spanEnd, noBreakCss: endCss, ifBreakCss: endCss, penalty: 0))

        guard cands.count >= 5 else { return nil }
        cands[cands.count - 2].penalty += orphansPenalty

        let widthCss = maxWidthPx * invScale
        let fitCss = widthCss + epsilon
        let linePenalty = widthCss * fontSizePt * 4.0
        let chosen = optimal(cands: cands, fit: fitCss, linePenalty: linePenalty)
        guard chosen.count == window.count else { return nil }

        let greedyStarts = window.dropFirst().map(\.u16Start)
        let chosenStarts = chosen.dropLast().map { cands[$0].atU16 }
        if chosenStarts == greedyStarts {
            return nil
        }

        var caps: [Int: CGFloat] = [:]
        var from = 0
        for (k, bIdx) in chosen.dropLast().enumerated() {
            let roomPx = (cands[bIdx].ifBreakCss - cands[from].noBreakCss) * scale + 0.5
            caps[first + k] = CGFloat(max(1.0, roomPx))
            from = bIdx
        }
        return caps.isEmpty ? nil : caps
    }

    #if !canImport(CoreText) && canImport(_FoundationICU)
    private final class ICULineBreakPool: @unchecked Sendable {
        private let lock = NSLock()
        private var pool: [OpaquePointer] = []

        func withIterator<R>(_ body: (OpaquePointer) -> R) -> R? {
            let iterator: OpaquePointer
            if let reused = lock.withLock({ pool.popLast() }) {
                iterator = reused
            } else {
                var status = U_ZERO_ERROR
                guard let created = swift_ubrk_open(UBRK_LINE, "und", nil, 0, &status),
                      status.rawValue <= U_ZERO_ERROR.rawValue else { return nil }
                iterator = created
            }
            let result = body(iterator)
            var resetStatus = U_ZERO_ERROR
            var zero: UInt16 = 0
            swift_ubrk_setText(iterator, &zero, 0, &resetStatus)
            if resetStatus.rawValue <= U_ZERO_ERROR.rawValue {
                let kept = lock.withLock { () -> Bool in
                    guard pool.count < 4 else { return false }
                    pool.append(iterator)
                    return true
                }
                if !kept { swift_ubrk_close(iterator) }
            } else {
                swift_ubrk_close(iterator)
            }
            return result
        }
    }

    private static let icuLineBreakPool = ICULineBreakPool()

    internal static func lineBreakOpportunities(inUTF16 units: [UInt16], offset start: Int = 0) -> [Int] {
        guard !units.isEmpty, let count = Int32(exactly: units.count) else { return [] }
        return units.withUnsafeBufferPointer { buffer in
            icuLineBreakPool.withIterator { iterator -> [Int] in
                var status = U_ZERO_ERROR
                swift_ubrk_setText(iterator, buffer.baseAddress, count, &status)
                guard status.rawValue <= U_ZERO_ERROR.rawValue else { return [] }
                var breaks: [Int] = []
                breaks.reserveCapacity(max(8, units.count / 5))
                var boundary = swift_ubrk_next(iterator)
                while boundary != UBRK_DONE && boundary < count {
                    breaks.append(start + Int(boundary))
                    boundary = swift_ubrk_next(iterator)
                }
                return breaks
            } ?? []
        }
    }

    private static func utf16Units(of text: String) -> [UInt16] {
        if let ascii = text.utf8.withContiguousStorageIfAvailable({ buf -> [UInt16]? in
            let n = buf.count
            for i in 0..<n {
                if buf[i] >= 0x80 { return nil }
            }
            return [UInt16](unsafeUninitializedCapacity: n) { out, outCount in
                let dst = out.baseAddress!
                let src = buf.baseAddress!
                for i in 0..<n { dst[i] = UInt16(src[i]) }
                outCount = n
            }
        }), let ascii {
            return ascii
        }
        return Array(text.utf16)
    }
    #endif

    #if !canImport(CoreText) && canImport(_FoundationICU)
    /// UTF-16 overload of `prettyLineCaps` that reuses `wrap()`'s UTF-16 units and
    /// precomputed ICU line break opportunities without bridging to `NSString`.
    private static func prettyLineCapsUTF16(
        lines: [GreedyLineInfo],
        units: [UInt16],
        allBreaks: [Int],
        fontSizePt: Float,
        maxWidthPx: Float,
        advanceAtUTF16: (Int) -> Float
    ) -> [Int: CGFloat]? {
        let n = lines.count
        guard n >= 2, !lines.contains(where: { $0.hasRTLRun || $0.isEmergency }), maxWidthPx > 0 else { return nil }
        for line in lines {
            guard line.u16Start >= 0, line.u16Start <= line.u16End, line.u16End <= units.count else { return nil }
        }
        let last = lines[n - 1]
        guard (last.widthPx - last.trailingWsPx) < (maxWidthPx / 3.0) else { return nil }
        if last.u16End > last.u16Start {
            for i in last.u16Start..<last.u16End {
                let ch = units[i]
                if ch >= 0x2066 && ch <= 0x2069 { return nil }
            }
        }

        func trimmedEnd(start: Int, end: Int) -> Int {
            var cursor = end
            while cursor > start {
                let ch = units[cursor - 1]
                if ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D || ch == 0xA0 || ch == 0x0B || ch == 0x0C {
                    cursor -= 1
                } else {
                    break
                }
            }
            return cursor
        }

        let first = max(0, n - maxLines)
        let windowCount = n - first
        let spanStart = lines[first].u16Start
        let spanEnd = trimmedEnd(start: spanStart, end: last.u16End)
        guard spanEnd > spanStart else { return nil }

        let lastWordsEnd = trimmedEnd(start: last.u16Start, end: last.u16End)
        let loIdx = partitionPoint(allBreaks) { $0 <= spanStart }
        let hiIdx = partitionPoint(allBreaks) { $0 < spanEnd }
        let breaks = allBreaks[loIdx..<hiIdx]
        for b in breaks {
            if b > last.u16Start && b < lastWordsEnd { return nil }
        }

        let origin = advanceAtUTF16(spanStart)
        func xAt(_ pos: Int) -> Float { advanceAtUTF16(pos) - origin }
        func endBeforePx(atU16 pos: Int) -> Float {
            let trimmed = trimmedEnd(start: spanStart, end: pos)
            guard trimmed > spanStart else { return 0 }
            return xAt(trimmed)
        }

        var cands: [Candidate] = []
        cands.reserveCapacity(breaks.count + 2)
        cands.append(Candidate(atU16: spanStart, noBreakCss: 0, ifBreakCss: 0, penalty: 0))
        for b in breaks {
            cands.append(Candidate(atU16: b, noBreakCss: xAt(b), ifBreakCss: endBeforePx(atU16: b), penalty: 0))
        }
        let endCss = endBeforePx(atU16: spanEnd)
        cands.append(Candidate(atU16: spanEnd, noBreakCss: endCss, ifBreakCss: endCss, penalty: 0))

        guard cands.count >= 5 else { return nil }
        cands[cands.count - 2].penalty += orphansPenalty

        let fitCss = maxWidthPx + epsilon
        let linePenalty = maxWidthPx * fontSizePt * 4.0
        let chosen = optimal(cands: cands, fit: fitCss, linePenalty: linePenalty)
        guard chosen.count == windowCount else { return nil }

        var changed = false
        for k in 0..<(windowCount - 1) {
            if cands[chosen[k]].atU16 != lines[first + 1 + k].u16Start {
                changed = true
                break
            }
        }
        guard changed else { return nil }

        var caps: [Int: CGFloat] = Dictionary(minimumCapacity: windowCount - 1)
        var from = 0
        for k in 0..<(windowCount - 1) {
            let bIdx = chosen[k]
            let roomPx = (cands[bIdx].ifBreakCss - cands[from].noBreakCss) + 0.5
            caps[first + k] = CGFloat(max(1.0, roomPx))
            from = bIdx
        }
        return caps.isEmpty ? nil : caps
    }
    #endif

    /// Wraps one portable shaped paragraph at Unicode break opportunities. Advances and inline
    /// boxes are in logical points. Emergency breaks may only fall between graphemes.
    internal static func wrap(
        _ text: String, width: Float, fontSize: Float, wrapAnywhere: Bool, pretty: Bool,
        utf8Start: Int = 0, pillRanges: [Range<Int>] = [],
        measure: (Character, Int) -> (advance: Float, leadingBox: Float, trailingBox: Float)
    ) -> [(start: Int, text: String, width: Float)] {
        struct Edge {
            let index: String.Index
            let utf8: Int
            let utf16: Int
            let x: Float
            let inkEnd: Float
            let hangs: Bool
        }
        var edges: [Edge] = []
        edges.reserveCapacity(text.utf8.count + 1)
        edges.append(Edge(index: text.startIndex, utf8: 0, utf16: 0, x: 0, inkEnd: 0, hangs: false))
        var maxInkEnd: Float = 0
        var index = text.startIndex
        while index < text.endIndex {
            let nextIndex = text.index(after: index)
            let character = text[index]
            let start = edges[edges.count - 1]
            let cell = measure(character, start.utf8)
            let x = start.x + cell.leadingBox + cell.advance + cell.trailingBox
            let hangingSpace = character == " " || character == "\t" || character == "\u{3000}"
            let hangs = hangingSpace && cell.trailingBox == 0
            let fullyHangs = hangs && cell.leadingBox == 0
            let visibleEdge = hangs ? start.x + cell.leadingBox : x
            let inkEnd = fullyHangs ? start.inkEnd : visibleEdge
            if !fullyHangs && inkEnd > maxInkEnd { maxInkEnd = inkEnd }
            edges.append(Edge(index: nextIndex, utf8: start.utf8 + character.utf8.count,
                              utf16: start.utf16 + character.utf16.count, x: x,
                              inkEnd: inkEnd, hangs: fullyHangs))
            index = nextIndex
        }

        let end = edges.count - 1
        if end == 0 { return [(0, text, 0)] }
        if maxInkEnd <= width + epsilon {
            if pillRanges.isEmpty {
                return [(0, text, edges[end].x)]
            }
            let proposed = utf8Start + edges[end].utf8
            let pIdx = partitionPoint(pillRanges) { $0.upperBound <= proposed }
            if !(pIdx < pillRanges.count && pillRanges[pIdx].lowerBound > utf8Start && pillRanges[pIdx].lowerBound < proposed) {
                return [(0, text, edges[end].x)]
            }
        }

        #if os(WASI) && RUNE_BROWSER_TEXT
        let ns = text as NSString
        let standard = Set(lineBreakOpportunities(in: ns, from: 0, to: ns.length))
        let natural = BrowserSegmentation.dictionaryBreaks(standard, in: text, words: false)
        func canBreak(_ boundary: Int) -> Bool {
            boundary == end || natural.contains(edges[boundary].utf16)
        }
        #elseif !canImport(CoreText) && canImport(_FoundationICU)
        let utf16 = utf16Units(of: text)
        let sortedBreaks = lineBreakOpportunities(inUTF16: utf16)
        func canBreak(_ boundary: Int) -> Bool {
            if boundary == end { return true }
            let target = edges[boundary].utf16
            let idx = partitionPoint(sortedBreaks) { $0 < target }
            return idx < sortedBreaks.count && sortedBreaks[idx] == target
        }
        #else
        let ns = text as NSString
        let sortedBreaks = lineBreakOpportunities(in: ns, from: 0, to: ns.length)
        func canBreak(_ boundary: Int) -> Bool {
            if boundary == end { return true }
            let target = edges[boundary].utf16
            let idx = partitionPoint(sortedBreaks) { $0 < target }
            return idx < sortedBreaks.count && sortedBreaks[idx] == target
        }
        #endif

        func wrapLines(caps: [Int: CGFloat] = [:]) -> [Range<Int>] {
            var ranges: [Range<Int>] = []
            var lo = 0
            while lo < end {
                let available = caps[ranges.count].map(Float.init) ?? width
                var hi = lo
                var regularBreak: Int?
                var emergencyBreak: Int?
                #if !(os(WASI) && RUNE_BROWSER_TEXT)
                let loU16 = edges[lo].utf16
                var breakCursor = partitionPoint(sortedBreaks) { $0 < loU16 }
                #endif
                while hi < end {
                    // Parley records a break before this grapheme only after some
                    // advance. A zero-width prefix stays with the following text.
                    if edges[hi].x != edges[lo].x {
                        #if os(WASI) && RUNE_BROWSER_TEXT
                        let isNatural = canBreak(hi)
                        #else
                        let u16 = edges[hi].utf16
                        while breakCursor < sortedBreaks.count && sortedBreaks[breakCursor] < u16 {
                            breakCursor += 1
                        }
                        let isNatural = breakCursor < sortedBreaks.count && sortedBreaks[breakCursor] == u16
                        #endif
                        if isNatural { regularBreak = hi }
                        else if wrapAnywhere { emergencyBreak = hi }
                    }
                    let next = edges[hi + 1]
                    if !next.hangs, next.inkEnd - edges[lo].x > available + epsilon,
                       let boundary = regularBreak ?? emergencyBreak {
                        hi = boundary
                        break
                    }
                    hi += 1
                }
                // Start the chip on a fresh line when the proposed break splits its label.
                // A label already at the start can wrap across lines at the normal breaks.
                if !pillRanges.isEmpty {
                    let proposed = utf8Start + edges[hi].utf8
                    let index = partitionPoint(pillRanges) { $0.upperBound <= proposed }
                    if index < pillRanges.count {
                        let start = pillRanges[index].lowerBound - utf8Start
                        if edges[lo].utf8 < start && start < edges[hi].utf8 {
                            hi = partitionPoint(edges) { $0.utf8 < start }
                        }
                    }
                }
                ranges.append(lo..<hi)
                lo = hi
            }
            return ranges
        }

        var ranges = wrapLines()
        if pretty && ranges.count > 1 {
            let info = ranges.map { range in
                let a = edges[range.lowerBound], b = edges[range.upperBound]
                return GreedyLineInfo(u16Start: a.utf16, u16End: b.utf16, widthPx: b.x - a.x,
                                      trailingWsPx: b.x - max(a.x, b.inkEnd), hasRTLRun: false,
                                      isEmergency: !canBreak(range.upperBound))
            }
            let oneToOneU16 = edges[end].utf16 == end
            func xForU16(_ u16: Int) -> Float {
                if oneToOneU16 {
                    return (u16 >= 0 && u16 <= end) ? edges[u16].x : 0
                }
                let idx = partitionPoint(edges) { $0.utf16 < u16 }
                return (idx <= end && edges[idx].utf16 == u16) ? edges[idx].x : 0
            }
            #if !canImport(CoreText) && canImport(_FoundationICU)
            if let caps = prettyLineCapsUTF16(lines: info, units: utf16, allBreaks: sortedBreaks,
                                              fontSizePt: fontSize, maxWidthPx: width,
                                              advanceAtUTF16: xForU16) {
                let revised = wrapLines(caps: caps)
                if revised.count == ranges.count { ranges = revised }
            }
            #else
            if let caps = prettyLineCaps(lines: info, in: ns, fontSizePt: fontSize, scale: 1,
                                         maxWidthPx: width, advanceAtUTF16: xForU16) {
                let revised = wrapLines(caps: caps)
                if revised.count == ranges.count { ranges = revised }
            }
            #endif
        }
        return ranges.map {
            let a = edges[$0.lowerBound], b = edges[$0.upperBound]
            return (a.utf8, String(text[a.index..<b.index]), b.x - a.x)
        }
    }

    /// Upstream's `sliceable` (`#1023`): a line's range is a valid slice of the text
    /// (`start <= end && end <= text.len`) and the line holds text, not only inline boxes (Parley
    /// gives a box-only line an empty range at `usize::MAX`, which fails the bounds check).
    internal static func isSliceable(_ line: GreedyLineInfo, in shapedNS: NSString, boxU16: Set<Int>) -> Bool {
        guard line.u16Start >= 0, line.u16Start <= line.u16End, line.u16End <= shapedNS.length else { return false }
        if line.u16End > line.u16Start, (line.u16Start..<line.u16End).allSatisfy({ boxU16.contains($0) }) {
            return false
        }
        return true
    }

    /// Optimal line breaks using Blink's DP (`ComputeScores` / `ComputeBreakPoints`).
    private static func optimal(cands: [Candidate], fit: Float, linePenalty: Float) -> [Int] {
        var scores: [(score: Float, prev: Int, lines: Int)] = [(0, 0, 0)]
        scores.reserveCapacity(cands.count)
        var active = 0
        for end in 1..<cands.count {
            let isLast = (end == cands.count - 1)
            var best = Float.greatestFiniteMagnitude
            var bestPrev = 0
            var bestHope: Float = 0
            let startEdge = cands[end].ifBreakCss - fit
            for start in active..<end {
                let startScore = scores[start].score
                if startScore + bestHope >= best {
                    continue
                }
                let delta = cands[start].noBreakCss - startEdge
                var widthScore: Float = 0
                var extra: Float = 0
                if delta < 0 {
                    widthScore = overfull
                } else if isLast {
                    extra = lastLinePenaltyMultiplier * cands[start].penalty
                } else {
                    widthScore = delta * delta
                }
                if delta < 0 {
                    active = start + 1
                } else {
                    bestHope = widthScore
                }
                let score = startScore + widthScore + extra
                if score <= best {
                    best = score
                    bestPrev = start
                }
            }
            scores.append((best + cands[end].penalty + linePenalty, bestPrev, scores[bestPrev].lines + 1))
        }
        var out: [Int] = []
        var i = cands.count - 1
        while i > 0 {
            out.append(i)
            i = scores[i].prev
        }
        out.reverse()
        return out
    }

    private static func trimmedU16End(in nsStr: NSString, start: Int, end: Int) -> Int {
        var cursor = end
        while cursor > start {
            let ch = nsStr.character(at: cursor - 1)
            if ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D || ch == 0xA0 || ch == 0x0B || ch == 0x0C {
                cursor -= 1
            } else {
                break
            }
        }
        return cursor
    }

    /// Line break opportunities of `nsStr[start..<end]` (shaped UTF-16 positions, exclusive of both
    /// ends). Inline boxes at `boxU16` are left out of the text the segmenter sees (upstream segments
    /// the text, where boxes have no characters), and a break lands on the first cluster at its
    /// position (`clusters.partition_point(|c| c.0 < b)`): before any box there, which then starts
    /// the next line.
    internal static func lineBreakOpportunities(in nsStr: NSString, from start: Int, to end: Int, boxU16: Set<Int> = []) -> [Int] {
        guard start >= 0, end > start, end <= nsStr.length else { return [] }
        let inSpan = boxU16.filter { $0 >= start && $0 < end }
        if !inSpan.isEmpty {
            // Text without its boxes, and each kept unit's shaped position.
            var units: [unichar] = []
            var shapedAt: [Int] = []
            units.reserveCapacity(end - start)
            shapedAt.reserveCapacity(end - start)
            for i in start..<end where !inSpan.contains(i) {
                units.append(nsStr.character(at: i))
                shapedAt.append(i)
            }
            guard !units.isEmpty else { return [] }
            let stripped = NSString(characters: units, length: units.count)
            return lineBreakOpportunities(in: stripped, from: 0, to: units.count).compactMap { k -> Int? in
                // Break before stripped unit `k`: right after the unit before it, ahead of any box.
                guard k > 0, k <= shapedAt.count else { return nil }
                let at = shapedAt[k - 1] + 1
                return (at > start && at < end) ? at : nil
            }
        }
        #if canImport(CoreText)
        let slice = nsStr.substring(with: NSRange(location: start, length: end - start))
        let sliceNS = slice as NSString
        guard sliceNS.length > 0 else { return [] }
        let tok = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            slice as CFString,
            CFRangeMake(0, sliceNS.length),
            kCFStringTokenizerUnitLineBreak,
            nil
        )
        var breaks: [Int] = []
        var tokenType = CFStringTokenizerAdvanceToNextToken(tok)
        while !tokenType.isEmpty {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            if r.location != kCFNotFound {
                let relEnd = r.location + r.length
                if relEnd > 0 && relEnd < sliceNS.length {
                    breaks.append(start + relEnd)
                }
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tok)
        }
        return breaks
        #elseif canImport(_FoundationICU)
        // Swift Foundation ships the same Unicode line break iterator on its non-Darwin SDKs.
        let length = end - start
        guard length > 0 else { return [] }
        let units = [UInt16](unsafeUninitializedCapacity: length) { buffer, initializedCount in
            nsStr.getCharacters(buffer.baseAddress!, range: NSRange(location: start, length: length))
            initializedCount = length
        }
        return lineBreakOpportunities(inUTF16: units, offset: start)
        #else
        // Minimal SDKs without Unicode segmentation can wrap after space, tab, zero-width
        // space or a discretionary hyphen. Keep nonbreaking spaces and graphemes intact.
        let slice = nsStr.substring(with: NSRange(location: start, length: end - start))
        var breaks: [Int] = []
        var position = start
        var mayBreak = false
        for character in slice {
            let space = character == " " || character == "\t" || character == "\u{200B}"
            if mayBreak && !space { breaks.append(position) }
            mayBreak = space || character == "-" || character == "\u{AD}"
            position += character.utf16.count
        }
        return breaks
        #endif
    }
}
