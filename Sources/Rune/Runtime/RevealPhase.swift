import Foundation
import RuneMotion

/// How a text node arrived on this commit for streaming reveal tracking (`runtime/motion/reveal_phase.rs`).
public enum RevealArrival: Sendable, Equatable {
    case kept
    case entering
    case landed
    case replaced
}

/// Inputs that drive a `RevealPhase` transition (`reveal_phase.rs:RevealEvent`).
public enum RevealEvent: Sendable {
    case commit(
        content: String,
        fade: Float,
        arrival: RevealArrival,
        now: Double,
        reducedMotion: Bool
    )
    case tick(now: Double)
    case shift(delta: Double)
}

/// Side effect emitted by `RevealPhase.step` for window-level `RevealChain`.
public enum RevealPhaseEffect: Sendable, Equatable {
    case started(Double)
}

/// Window-level reading-order word stagger chain across streaming texts (`reveal_phase.rs:RevealChain`).
public struct RevealChain: Sendable, Equatable {
    public var tail: Double

    public init(tail: Double = 0.0) {
        self.tail = tail
    }

    public mutating func started(_ at: Double) {
        if at.isFinite {
            tail = max(tail, at)
        }
    }

    public func chainTime(now: Double, fade: Float) -> Double {
        guard (tail - now) <= Double(fade) else { return now }
        return max(tail, now)
    }
}

/// Streaming word-by-word reveal state machine (`runtime/motion/reveal_phase.rs`).
public enum RevealPhase: Sendable, Equatable {
    public struct WordStart: Sendable, Equatable {
        public var byteOffset: UInt32
        public var start: Double

        public init(byteOffset: UInt32, start: Double) {
            self.byteOffset = byteOffset
            self.start = start
        }
    }

    case idle(shown: Int, fade: Float)
    case fading(shown: Int, words: [WordStart], fade: Float)

    public var shownBytes: Int {
        switch self {
        case .idle(let shown, _): return shown
        case .fading(let shown, _, _): return shown
        }
    }

    public var fadeDuration: Float {
        switch self {
        case .idle(_, let fade): return fade
        case .fading(_, _, let fade): return fade
        }
    }

    public var words: [WordStart] {
        switch self {
        case .idle: return []
        case .fading(_, let words, _): return words
        }
    }

    public var isFading: Bool {
        if case .fading(_, let words, _) = self {
            return !words.isEmpty
        }
        return false
    }

    /// Cubic ease-out used for streaming word alpha (`ease_out` in `reveal_phase.rs`).
    @inlinable
    public static func easeOut(_ x: Float) -> Float {
        let c = min(max(x, 0.0), 1.0)
        let u = 1.0 - c
        return 1.0 - u * u * u
    }

    /// UTF-8 byte offsets of non-whitespace word starts in `content[from...]`.
    public static func wordStarts(in content: String, from: Int) -> [UInt32] {
        let utf8 = content.utf8
        guard from >= 0, from <= utf8.count else { return [] }
        let startIdx = utf8.index(utf8.startIndex, offsetBy: from)
        guard startIdx.samePosition(in: content) != nil else { return [] }
        let suffix = String(decoding: utf8[startIdx...], as: UTF8.self)
        var out: [UInt32] = []
        var prevSpace = true
        var byteCursor = from
        for ch in suffix {
            let isSpace = ch.isWhitespace
            if !isSpace && prevSpace {
                out.append(UInt32(byteCursor))
            }
            prevSpace = isSpace
            byteCursor += ch.utf8.count
        }
        return out
    }

    /// Advances the reveal state in response to `event`, updating `chain` when supplied.
    @discardableResult
    public mutating func step(
        _ event: RevealEvent,
        chain: inout RevealChain?
    ) -> [RevealPhaseEffect] {
        switch event {
        case let .commit(content, fade, arrival, now, reducedMotion):
            let utf8Count = content.utf8.count
            let prevShown = shownBytes
            let isBoundary: Bool = {
                guard prevShown <= utf8Count else { return false }
                let idx = content.utf8.index(content.utf8.startIndex, offsetBy: prevShown)
                return idx.samePosition(in: content) != nil
            }()

            if arrival == .replaced || arrival == .landed || utf8Count < prevShown || !isBoundary {
                self = .idle(shown: utf8Count, fade: fade)
                return []
            }

            let scanFrom: Int
            var currentWords: [WordStart]
            switch arrival {
            case .entering:
                scanFrom = 0
                currentWords = []
            case .kept:
                switch self {
                case .idle(let shown, _):
                    scanFrom = shown
                    currentWords = []
                case .fading(let shown, let w, _):
                    scanFrom = shown
                    currentWords = w
                }
            case .landed, .replaced:
                scanFrom = utf8Count
                currentWords = []
            }

            if utf8Count > scanFrom && fade > 0.0 {
                let starts = Self.wordStarts(in: content, from: scanFrom)
                if !starts.isEmpty {
                    let own = currentWords.last.map { max($0.start, now) } ?? now
                    let chainHead = chain?.chainTime(now: now, fade: fade) ?? now
                    let queued = Int(max(0.0, chainHead - now) / 0.0055)
                    let pending = currentWords.reduce(0) { $0 + ($1.start > now ? 1 : 0) } + starts.count + queued
                    let stagger: Double
                    if reducedMotion {
                        stagger = 0.0
                    } else {
                        let k = min(max(Float(pending) / 24.0, 0.0), 1.0)
                        stagger = Double(0.020 + (0.0055 - 0.020) * k)
                    }
                    var tn = chainHead > own ? chainHead + stagger : own
                    for b in starts {
                        currentWords.append(WordStart(byteOffset: b, start: tn))
                        tn += stagger
                    }
                    if let last = currentWords.last {
                        chain?.started(last.start)
                        self = .fading(shown: utf8Count, words: currentWords, fade: fade)
                        return [.started(last.start)]
                    }
                }
            }

            if currentWords.isEmpty {
                self = .idle(shown: utf8Count, fade: fade)
            } else {
                self = .fading(shown: utf8Count, words: currentWords, fade: fade)
            }
            return []

        case let .tick(now):
            guard case let .fading(shown, words, fade) = self else { return [] }
            let fadeD = Double(fade)
            var done = 0
            for w in words {
                if now - w.start >= fadeD {
                    done += 1
                } else {
                    break
                }
            }
            if done > 0 && done == words.count {
                self = .idle(shown: shown, fade: fade)
            }
            return []

        case let .shift(delta):
            guard case let .fading(shown, existingWords, fade) = self else { return [] }
            var words = existingWords
            for idx in words.indices {
                words[idx].start += delta
            }
            self = .fading(shown: shown, words: words, fade: fade)
            return []
        }
    }

    /// Opacity `[0, 1]` of the glyph at UTF-8 byte `byte` at `now` (`reveal_alpha`).
    public func alpha(at byte: UInt32, now: Double) -> Float {
        guard case let .fading(_, words, fade) = self, !words.isEmpty else {
            return 1.0
        }
        // Binary search: first index whose byteOffset > byte (`partition_point(|w| w.0 <= byte)`).
        var lo = 0
        var hi = words.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if words[mid].byteOffset <= byte {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo == 0 {
            return 1.0
        }
        let t0 = words[lo - 1].start
        if fade <= 0.0 {
            return now >= t0 ? 1.0 : 0.0
        }
        return Self.easeOut(Float((now - t0) / Double(fade)))
    }

    /// Earliest upcoming word start after `now`, if any word has not started fading yet.
    public func nextWord(at now: Double) -> Double? {
        guard case let .fading(_, words, _) = self else { return nil }
        return words.first(where: { $0.start > now })?.start
    }
}

// MARK: - Runtime Reveal Hooks

extension Runtime {
    private func isVirtualRevealChild(_ node: FlatNode) -> Bool {
        if node.key == "__v_top_spacer" || node.key == "__v_bot_spacer" {
            return true
        }
        guard !activeVirtualPaths.isEmpty else { return false }
        var cur = node.parentIndex
        while let idx = cur, idx < flatNodes.count {
            if activeVirtualPaths.contains(flatNodes[idx].path) {
                return true
            }
            cur = flatNodes[idx].parentIndex
        }
        return false
    }

    internal func commitTextReveals(
        at now: Double,
        cut: Bool,
        instant: Bool,
        unprompted: Bool,
        previouslyPresent: Set<NodeId>
    ) {
        if cut {
            revealChain = RevealChain()
        }
        for node in flatNodes {
            let revealVal = node.el.revealDuration
            guard revealVal >= 0.0 else { continue }
            guard let content = node.el.liveText?.get()
                ?? node.el.plainText
                ?? node.el.richSpans?.map(\.text).joined() else { continue }
            let id = node.nodeId
            let wasPresent = previouslyPresent.contains(id)
            let nodeScale = scene.store.nodeTimeScale(id)
            let timeScaled = (nodeScale != 1.0) || abs(cxSettings.viewTimeScale - 1.0) > 1e-6
            let nodeNow = (nodeScale != 1.0) ? scene.store.nodeTime(id) : now
            let fade: Float = (revealVal > 0 && reducedMotion) ? 0.15 : revealVal
            let isVirtual = isVirtualRevealChild(node)
            let mountedLate = !cut && !wasPresent && !instant && !unprompted && !isVirtual

            let vacant = (reveals[id] == nil)
            if vacant {
                let shown = mountedLate ? 0 : content.utf8.count
                reveals[id] = .idle(shown: shown, fade: fade)
            }
            var phase = reveals[id]!
            let prevShown = phase.shownBytes
            let isBoundary: Bool = {
                guard prevShown <= content.utf8.count else { return false }
                let idx = content.utf8.index(content.utf8.startIndex, offsetBy: prevShown)
                return idx.samePosition(in: content) != nil
            }()

            let arrival: RevealArrival
            if cut || instant || (!wasPresent && isVirtual) || content.utf8.count < prevShown || !isBoundary {
                arrival = .replaced
            } else if !vacant {
                arrival = .kept
            } else if mountedLate {
                arrival = .entering
            } else {
                arrival = .landed
            }

            var chainArg: RevealChain? = timeScaled ? nil : revealChain
            _ = phase.step(
                .commit(
                    content: content,
                    fade: fade,
                    arrival: arrival,
                    now: nodeNow,
                    reducedMotion: reducedMotion
                ),
                chain: &chainArg
            )
            if let updatedChain = chainArg, !timeScaled {
                revealChain = updatedChain
            }
            reveals[id] = phase
        }
        if hasActiveTextReveals() {
            isAnimating = true
        }
    }

    internal func tickTextReveals(at now: Double) {
        guard !reveals.isEmpty else { return }
        var chainArg: RevealChain? = nil
        for id in Array(reveals.keys) {
            if var phase = reveals[id] {
                let nodeNow = scene.store.nodeTimeScale(id) != 1.0 ? scene.store.nodeTime(id) : now
                _ = phase.step(.tick(now: nodeNow), chain: &chainArg)
                reveals[id] = phase
            }
        }
    }

    internal func shiftTextReveal(for id: NodeId, by delta: Double) {
        guard abs(delta) > 1e-12, var phase = reveals[id] else { return }
        var chainArg: RevealChain? = nil
        _ = phase.step(.shift(delta: delta), chain: &chainArg)
        reveals[id] = phase
    }

    internal func shiftTextReveals(by delta: Double) {
        guard abs(delta) > 1e-12, !reveals.isEmpty else { return }
        var chainArg: RevealChain? = nil
        for id in Array(reveals.keys) {
            if var phase = reveals[id] {
                _ = phase.step(.shift(delta: delta), chain: &chainArg)
                reveals[id] = phase
            }
        }
        revealChain.tail += delta
    }

    internal func pruneExitedTextReveals() {
        guard !reveals.isEmpty else { return }
        reveals = reveals.filter { scene.hasNode($0.key) }
    }

    internal func hasActiveTextReveals() -> Bool {
        reveals.contains { id, phase in
            phase.isFading && scene.store.nodeTimeScale(id) > 0.0
        }
    }
}
