import Foundation
import RuneMotion

/// How a revealing text node arrived on a commit (`runtime/motion/reveal_phase.rs`).
internal enum WordRevealArrival: Equatable, Sendable {
    case kept
    case landed
    case entering
    case replaced
}

internal enum WordRevealEvent: Sendable {
    case commit(
        content: String,
        fade: Float,
        arrival: WordRevealArrival,
        chain: WordRevealChain?,
        now: Double,
        reducedMotion: Bool
    )
    case tick(now: Double)
    case shift(Double)
}

internal enum WordRevealEffect: Equatable, Sendable {
    case started(Double)
}

internal struct WordRevealFade: Equatable, Sendable {
    let words: [(startByte: UInt32, startTime: Double)]
    let fade: Float

    static func == (lhs: WordRevealFade, rhs: WordRevealFade) -> Bool {
        lhs.fade == rhs.fade && lhs.words.count == rhs.words.count &&
            zip(lhs.words, rhs.words).allSatisfy { $0.startByte == $1.startByte && $0.startTime == $1.startTime }
    }

    /// Opacity factor `[0, 1]` for the word containing `byte` at scaled clock `now`.
    func alpha(atUTF8Byte byte: UInt32, now: Double) -> Float {
        var lo = 0
        var hi = words.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if words[mid].startByte <= byte {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        guard lo > 0 else { return 1.0 }
        let t0 = words[lo - 1].startTime
        if fade <= 0 {
            return now >= t0 ? 1.0 : 0.0
        }
        let x = Float((now - t0) / Double(fade))
        let clamped = min(max(x, 0), 1)
        let inv = 1.0 - clamped
        return 1.0 - inv * inv * inv
    }

    var latestStart: Double {
        words.last?.startTime ?? 0.0
    }
}

/// Cross-text word-reveal queue for a window's clock (`RevealChain` in `reveal_phase.rs`).
internal struct WordRevealChain: Equatable, Sendable {
    private(set) var until: Double = 0.0

    func start(now: Double, fade: Float) -> Double {
        if until - now > Double(fade) {
            return now
        }
        return max(until, now)
    }

    mutating func started(at t: Double) {
        until = max(until, t)
    }
}

/// Per-node streaming word-reveal state machine (`RevealPhase` in `reveal_phase.rs`).
internal enum WordRevealPhase: Equatable, Sendable {
    case idle(shown: Int)
    case fading(shown: Int, words: [(startByte: UInt32, startTime: Double)], fade: Float)

    static func == (lhs: WordRevealPhase, rhs: WordRevealPhase) -> Bool {
        switch (lhs, rhs) {
        case let (.idle(a), .idle(b)):
            return a == b
        case let (.fading(sa, wa, fa), .fading(sb, wb, fb)):
            guard sa == sb && fa == fb && wa.count == wb.count else { return false }
            return zip(wa, wb).allSatisfy { $0.startByte == $1.startByte && $0.startTime == $1.startTime }
        default:
            return false
        }
    }

    var isFading: Bool {
        if case .fading = self { return true }
        return false
    }

    var shownBytes: Int {
        switch self {
        case let .idle(shown), let .fading(shown, _, _):
            return shown
        }
    }

    func caughtUp(endBytes: Int) -> Bool {
        !isFading && shownBytes == endBytes
    }

    var fade: WordRevealFade? {
        if case let .fading(_, words, fade) = self {
            return WordRevealFade(words: words, fade: fade)
        }
        return nil
    }

    @discardableResult
    mutating func step(_ event: WordRevealEvent) -> [WordRevealEffect] {
        switch event {
        case let .tick(now):
            if case let .fading(shown, words, fade) = self,
               words.allSatisfy({ now - $0.startTime >= Double(fade) }) {
                self = .idle(shown: shown)
            }
            return []
        case let .shift(delta):
            if case .fading(let shown, var words, let fade) = self {
                for i in words.indices {
                    words[i].startTime += delta
                }
                self = .fading(shown: shown, words: words, fade: fade)
            }
            return []
        case let .commit(content, fade, arrival, chain, now, reducedMotion):
            return applyCommit(
                content: content,
                fade: fade,
                arrival: arrival,
                chain: chain,
                now: now,
                reducedMotion: reducedMotion
            )
        }
    }

    private mutating func applyCommit(
        content: String,
        fade: Float,
        arrival: WordRevealArrival,
        chain: WordRevealChain?,
        now: Double,
        reducedMotion: Bool
    ) -> [WordRevealEffect] {
        var words: [(startByte: UInt32, startTime: Double)]
        let from: Int
        switch arrival {
        case .kept:
            switch self {
            case let .idle(shown):
                words = []
                from = shown
            case let .fading(shown, existing, _):
                words = existing
                from = shown
            }
        case .entering:
            words = []
            from = 0
        case .landed, .replaced:
            words = []
            from = content.utf8.count
        }

        var effects: [WordRevealEffect] = []
        let contentLen = content.utf8.count
        if contentLen > from && fade > 0 {
            let starts = Self.wordStarts(in: content, fromUTF8Byte: from)
            let own = words.last.map { max($0.startTime, now) } ?? now
            let chainAt = chain.map { $0.start(now: now, fade: fade) } ?? now
            let queued = Int(max(0.0, chainAt - now) / 0.0055)
            let pending = words.filter { $0.startTime > now }.count + starts.count + queued
            let stagger: Double
            if reducedMotion {
                stagger = 0.0
            } else {
                let k = min(max(Float(pending) / 24.0, 0.0), 1.0)
                stagger = Double(0.020 + (0.0055 - 0.020) * k)
            }
            var tn = chainAt > own ? (chainAt + stagger) : own
            for b in starts {
                words.append((b, tn))
                tn += stagger
            }
            if chain != nil, let last = words.last {
                effects.append(.started(last.startTime))
            }
        }

        if words.isEmpty {
            self = .idle(shown: contentLen)
        } else {
            self = .fading(shown: contentLen, words: words, fade: fade)
        }
        return effects
    }

    private static func wordStarts(in string: String, fromUTF8Byte from: Int) -> [UInt32] {
        guard from < string.utf8.count else { return [] }
        let startIdx = string.utf8.index(string.startIndex, offsetBy: from)
        var out: [UInt32] = []
        var prevSpace = true
        var byteOffset = from
        for scalar in string[startIdx...].unicodeScalars {
            let isSpace = scalar.properties.isWhitespace
            if !isSpace && prevSpace {
                out.append(UInt32(byteOffset))
            }
            prevSpace = isSpace
            byteOffset += scalar.utf8.count
        }
        return out
    }
}

/// Precomputed per-word reveal opacity mask mapped into element-local shaped coordinates.
internal struct WordFadeMask {
    var rects: [(rect: SIMD4<Float>, alpha: Float)]

    func alpha(for glyph: PositionedGlyph) -> Float {
        guard !rects.isEmpty else { return 1.0 }
        let cx = glyph.rect.x + glyph.rect.z * 0.5
        let cy = glyph.rect.y + glyph.rect.w * 0.5
        for entry in rects {
            let r = entry.rect
            if cx >= r.x - 0.5 && cx <= r.x + r.z + 0.5 && cy >= r.y - 0.5 && cy <= r.y + r.w + 0.5 {
                return entry.alpha
            }
        }
        return 1.0
    }
}

/// Commit payload describing one `El.reveal(wordFade:)` node.
internal struct WordRevealCommitEntry {
    var id: NodeId
    var text: String
    var fade: Float
    var nodeTime: Double
    var timeScaled: Bool
}

/// Runtime storage for active `El.reveal(wordFade:)` text nodes and the window's reveal chain.
internal struct WordRevealStore: Sendable {
    internal var phases: [NodeId: WordRevealPhase] = [:]
    private var texts: [NodeId: String] = [:]
    internal var chain = WordRevealChain()

    var isFading: Bool {
        phases.values.contains { $0.isFading }
    }

    mutating func reset() {
        phases.removeAll(keepingCapacity: true)
        texts.removeAll(keepingCapacity: true)
        chain = WordRevealChain()
    }

    mutating func commit(
        entries: [WordRevealCommitEntry],
        retainIds: Set<NodeId>,
        prevMountedIds: Set<NodeId>,
        cut: Bool,
        reducedMotion: Bool
    ) {
        if cut {
            chain = WordRevealChain()
        }
        for entry in entries {
            let wasMounted = prevMountedIds.contains(entry.id)
            let arrival: WordRevealArrival
            if cut {
                arrival = .landed
            } else if !wasMounted {
                arrival = .entering
            } else if let prevText = texts[entry.id], !entry.text.hasPrefix(prevText) {
                arrival = .replaced
            } else {
                arrival = .kept
            }

            var phase = phases[entry.id] ?? .idle(shown: 0)
            let effects = phase.step(.commit(
                content: entry.text,
                fade: entry.fade,
                arrival: arrival,
                chain: entry.timeScaled ? nil : chain,
                now: entry.nodeTime,
                reducedMotion: reducedMotion
            ))
            for eff in effects {
                if case let .started(t) = eff {
                    chain.started(at: t)
                }
            }
            phases[entry.id] = phase
            texts[entry.id] = entry.text
        }

        if !phases.isEmpty {
            phases = phases.filter { retainIds.contains($0.key) }
            texts = texts.filter { retainIds.contains($0.key) }
        }
    }

    mutating func tick(timeForNode: (NodeId) -> Double) {
        guard !phases.isEmpty else { return }
        for id in Array(phases.keys) {
            guard var phase = phases[id] else { continue }
            phase.step(.tick(now: timeForNode(id)))
            phases[id] = phase
        }
    }

    func mask(
        for id: NodeId,
        text: String,
        shaped: ShapedText,
        textSystem: TextSystem,
        pixelScale: Float,
        now: Double
    ) -> WordFadeMask? {
        guard let phase = phases[id],
              let fade = phase.fade,
              !fade.words.isEmpty,
              !text.isEmpty else {
            return nil
        }
        let textLen = text.utf8.count
        var entries: [(rect: SIMD4<Float>, alpha: Float)] = []
        for idx in fade.words.indices {
            let w = fade.words[idx]
            let a = fade.alpha(atUTF8Byte: w.startByte, now: now)
            if a >= 0.9999 { continue }
            let lo = min(Int(w.startByte), textLen)
            let rawHi = (idx + 1 < fade.words.count) ? Int(fade.words[idx + 1].startByte) : textLen
            let hi = min(rawHi, textLen)
            guard lo < hi else { continue }
            for r in textSystem.selectionRects(in: shaped, utf8Range: lo..<hi, pixelScale: pixelScale) {
                entries.append((r, a))
            }
        }
        guard !entries.isEmpty else { return nil }
        return WordFadeMask(rects: entries)
    }
}
