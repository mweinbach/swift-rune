import Foundation
#if canImport(CoreText)
import CoreText
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
        var ctLine: CTLine
        var strIndexBase: Int
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
        boxU16: Set<Int> = []
    ) -> [Int: CGFloat]? {
        let n = lines.count
        guard n >= 2, !lines.contains(where: { $0.hasRTLRun }) else { return nil }
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

        #if canImport(CoreText)
        // Cumulative device-px x offsets from the start of `window`.
        var lineOffsetsPx: [Float] = []
        lineOffsetsPx.reserveCapacity(window.count)
        var cumX: Float = 0
        for line in window {
            lineOffsetsPx.append(cumX)
            let lineAdvance = Float(CTLineGetOffsetForStringIndex(line.ctLine, line.u16End - line.strIndexBase, nil))
            cumX += lineAdvance
        }

        func xPx(atU16 pos: Int) -> Float {
            for idx in window.indices.reversed() {
                let line = window[idx]
                if pos >= line.u16Start {
                    let clamped = min(pos, line.u16End)
                    let localOff = Float(CTLineGetOffsetForStringIndex(line.ctLine, clamped - line.strIndexBase, nil))
                    return lineOffsetsPx[idx] + localOff
                }
            }
            return 0
        }

        func endBeforePx(atU16 pos: Int) -> Float {
            let trimmed = trimmedU16End(in: shapedNS, start: spanStart, end: pos)
            guard trimmed > spanStart else { return 0 }
            return xPx(atU16: trimmed)
        }

        let invScale = 1.0 / scale
        var cands: [Candidate] = [
            Candidate(atU16: spanStart, noBreakCss: 0, ifBreakCss: 0, penalty: 0),
        ]
        for b in breaks {
            cands.append(Candidate(
                atU16: b,
                noBreakCss: xPx(atU16: b) * invScale,
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
        #else
        return nil
        #endif
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
        guard end > start else { return [] }
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
    }
}
