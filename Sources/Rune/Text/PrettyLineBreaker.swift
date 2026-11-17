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

    /// Wraps one portable shaped paragraph at Unicode break opportunities. Advances arrive in
    /// logical points and include inline boxes. Emergency breaks may only fall between graphemes.
    internal static func wrap(
        _ text: String, width: Float, fontSize: Float, wrapAnywhere: Bool, pretty: Bool,
        utf8Start: Int = 0, pillRanges: [Range<Int>] = [],
        advance: (Character, Int) -> Float
    ) -> [(start: Int, text: String, width: Float)] {
        struct Edge {
            let index: String.Index
            let utf8: Int
            let utf16: Int
            let x: Float
            let inkEnd: Float
        }
        let ns = text as NSString
        let natural = Set(lineBreakOpportunities(in: ns, from: 0, to: ns.length))
        var edges = [Edge(index: text.startIndex, utf8: 0, utf16: 0, x: 0, inkEnd: 0)]
        for index in text.indices {
            let character = text[index]
            let start = edges[edges.count - 1]
            let x = start.x + advance(character, start.utf8)
            edges.append(Edge(index: text.index(after: index), utf8: start.utf8 + character.utf8.count,
                              utf16: start.utf16 + character.utf16.count, x: x,
                              inkEnd: character.isWhitespace ? start.inkEnd : x))
        }

        let end = edges.count - 1
        func canBreak(_ boundary: Int) -> Bool {
            boundary == end || natural.contains(edges[boundary].utf16)
        }
        func wrapLines(caps: [Int: CGFloat] = [:]) -> [Range<Int>] {
            var ranges: [Range<Int>] = []
            var lo = 0
            while lo < end {
                let available = caps[ranges.count].map(Float.init) ?? width
                var hi = lo + 1
                var lastFit: Int?
                while hi <= end {
                    if edges[hi].inkEnd - edges[lo].x > available + epsilon {
                        if let lastFit { hi = lastFit }
                        else if wrapAnywhere { hi = max(lo + 1, hi - 1) }
                        else { while !canBreak(hi) { hi += 1 } }
                        break
                    }
                    if canBreak(hi) { lastFit = hi }
                    if hi == end { break }
                    hi += 1
                }
                // Start the chip on a fresh line when the proposed break splits its label.
                // A label already at the start can wrap across lines at the normal breaks.
                let proposed = utf8Start + edges[hi].utf8
                let index = partitionPoint(pillRanges) { $0.upperBound <= proposed }
                if index < pillRanges.count {
                    let start = pillRanges[index].lowerBound - utf8Start
                    if edges[lo].utf8 < start && start < edges[hi].utf8 {
                        hi = partitionPoint(edges) { $0.utf8 < start }
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
            let offsets = Dictionary(uniqueKeysWithValues: edges.map { ($0.utf16, $0.x) })
            if let caps = prettyLineCaps(lines: info, in: ns, fontSizePt: fontSize, scale: 1,
                                         maxWidthPx: width, advanceAtUTF16: { offsets[$0] ?? 0 }) {
                let revised = wrapLines(caps: caps)
                if revised.count == ranges.count { ranges = revised }
            }
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
        let slice = nsStr.substring(with: NSRange(location: start, length: end - start))
        #if canImport(CoreText)
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
        let units = Array(slice.utf16)
        guard let count = Int32(exactly: units.count) else { return [] }
        return units.withUnsafeBufferPointer { buffer in
            var status = U_ZERO_ERROR
            guard let iterator = swift_ubrk_open(UBRK_LINE, "und", buffer.baseAddress, count, &status) else { return [] }
            defer { swift_ubrk_close(iterator) }
            var breaks: [Int] = []
            var boundary = swift_ubrk_next(iterator)
            while boundary != UBRK_DONE && boundary < count {
                breaks.append(start + Int(boundary))
                boundary = swift_ubrk_next(iterator)
            }
            return breaks
        }
        #else
        // Minimal SDKs without Unicode segmentation can wrap after space, tab, zero-width
        // space or a discretionary hyphen. Keep nonbreaking spaces and graphemes intact.
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
