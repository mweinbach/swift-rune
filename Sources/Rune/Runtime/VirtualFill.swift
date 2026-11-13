import Foundation

// MARK: - Virtual Fill Bounded Resume Machine (`crates/rune/src/runtime/virtual/fill.rs`)

internal struct VirtualFillStateMachine: Equatable, Sendable {
    static let fillFrames: UInt16 = 12
    static let resumeWait: Double = 3.0 / 60.0
    static let resumeLimit: UInt8 = 3

    enum Phase: Equatable, Sendable {
        case idle
        case filling(frames: UInt16, best: Int, resumes: UInt8)
        case waiting(attempt: UInt64, due: Double, best: Int, resumes: UInt8)
        case stalled
    }

    enum Event: Equatable, Sendable {
        case frame(now: Double, wanted: Bool, missing: Int, moved: Bool)
        case due(attempt: UInt64, now: Double)
    }

    enum Effect: Equatable, Sendable {
        case draw
        case wakeAt(Double)
    }

    struct ArmedWake: Equatable, Sendable {
        var attempt: UInt64
        var due: Double
    }

    private(set) var phase: Phase = .idle
    private var nextSeq: UInt64 = 0
    private(set) var armedWake: ArmedWake? = nil

    var isFilling: Bool {
        if case .filling = phase { return true }
        return false
    }

    var atBound: Bool {
        if case .filling(let frames, _, _) = phase {
            return frames >= Self.fillFrames
        }
        return false
    }

    mutating func wake(at now: Double) -> UInt64? {
        guard let armed = armedWake, now >= armed.due else { return nil }
        armedWake = nil
        return armed.attempt
    }

    func resuming(at now: Double) -> Bool {
        guard let armed = armedWake else { return false }
        return now >= armed.due
    }

    @discardableResult
    mutating func step(_ event: Event) -> Effect? {
        let effect = transition(event)
        if case .waiting = phase {
            // Waiting owns `armedWake`.
        } else {
            armedWake = nil
        }
        return effect
    }

    private mutating func transition(_ event: Event) -> Effect? {
        switch (phase, event) {
        case (_, .frame(_, wanted: false, _, _)):
            phase = .idle
            return nil

        case (_, .frame(_, wanted: true, _, moved: true)):
            phase = .filling(frames: 1, best: Int.max, resumes: 0)
            return .draw

        case (.idle, .frame(_, wanted: true, _, moved: false)):
            phase = .filling(frames: 1, best: Int.max, resumes: 0)
            return .draw

        case (.filling(let frames, let prevBest, let prevResumes), .frame(let now, wanted: true, let missing, moved: false)):
            let nextFrames = min(Self.fillFrames + 1, frames &+ 1)
            if nextFrames <= Self.fillFrames {
                phase = .filling(frames: nextFrames, best: prevBest, resumes: prevResumes)
                return .draw
            }
            let (best, resumes) = missing < prevBest ? (missing, UInt8(0)) : (prevBest, prevResumes)
            if missing == 0 {
                phase = .idle
                return nil
            }
            if resumes >= Self.resumeLimit {
                phase = .stalled
                return nil
            }
            nextSeq &+= 1
            let attempt = nextSeq
            let nextResumes = resumes + 1
            let shift = Double(UInt32(1) << (nextResumes - 1))
            let due = now + Self.resumeWait * shift
            phase = .waiting(attempt: attempt, due: due, best: best, resumes: nextResumes)
            armedWake = ArmedWake(attempt: attempt, due: due)
            return .wakeAt(due)

        case (.waiting, .frame(_, wanted: true, _, _)),
             (.stalled, .frame(_, wanted: true, _, _)):
            return nil

        case (.waiting(let attempt, let due, let best, let resumes), .due(let a, let now)) where attempt == a && now >= due:
            phase = .filling(frames: 1, best: best, resumes: resumes)
            return .draw

        default:
            return nil
        }
    }
}

// MARK: - Runtime Virtual Windowing (`crates/rune/src/el/virtual_list.rs`)

internal struct RuntimeVirtualListState: Sendable {
    static let overscanMultiplier: Float = 2.0
    static let indexedEdgeMultiplier: Float = 1.75
    static let indexedBudgetMultiplier: Float = 0.5
    static let nonIndexedEdgeMultiplier: Float = 0.5
    static let maxCachedKeys: Int = 250_000

    var measuredByKey: [String: Float] = [:]
    var lastKeys: [String] = []
    var lastKeysVersion: UInt64? = nil
    var lastMountedRange: Range<Int> = 0..<0
    var lastVisibleRange: Range<Int>? = nil
    var lastSelectedKey: String? = nil
    var lastAnchorKey: String? = nil
    var lastAnchorLocalY: Float = 0
    var lastAnchorPrefixY: Float = 0
    var rowKeyBySegment: [String: String] = [:]
    var wantsMoreFrames: Bool = false
    var missingOverscanRows: Int = 0

    func rowHeight(forKey key: String, estimated: Float) -> Float {
        measuredByKey[key] ?? max(1, estimated)
    }

    func computeOffsets(keys: [String], estimated: Float) -> (prefix: [Float], total: Float) {
        var prefix: [Float] = []
        prefix.reserveCapacity(keys.count + 1)
        var y: Float = 0
        prefix.append(0)
        for k in keys {
            y += rowHeight(forKey: k, estimated: estimated)
            prefix.append(y)
        }
        return (prefix, y)
    }

    func visibleRange(offset: Float, viewport: Float, prefix: [Float], count: Int) -> Range<Int> {
        guard count > 0, viewport > 0 else { return 0..<0 }
        let lo = max(0, offset)
        let hi = lo + viewport
        var start = count
        var end = 0
        for i in 0..<count {
            let r0 = prefix[i]
            let r1 = prefix[i + 1]
            if r1 > lo && r0 < hi {
                start = min(start, i)
                end = max(end, i + 1)
            }
        }
        return start < end ? start..<end : 0..<0
    }

    func overscanWindow(
        offset: Float,
        viewport: Float,
        prefix: [Float],
        count: Int,
        indexed: Bool,
        pinnedIndices: Set<Int>
    ) -> (mounted: Range<Int>, wantedMore: Bool, missing: Int) {
        guard count > 0, viewport > 0 else { return (0..<0, false, 0) }
        let lo = max(0, offset - viewport * Self.overscanMultiplier)
        let hi = offset + viewport * (1.0 + Self.overscanMultiplier)

        var targetLo = count
        var targetHi = 0
        for i in 0..<count {
            let r0 = prefix[i]
            let r1 = prefix[i + 1]
            if r1 > lo && r0 < hi {
                targetLo = min(targetLo, i)
                targetHi = max(targetHi, i + 1)
            }
        }
        if targetLo >= targetHi {
            targetLo = 0
            targetHi = min(count, 1)
        }

        // Preserve pinned indices near edges within overscan.
        for idx in pinnedIndices where idx >= 0 && idx < count {
            if idx < targetLo && (prefix[targetLo] - prefix[idx]) <= viewport * Self.overscanMultiplier {
                targetLo = min(targetLo, idx)
            }
            if idx >= targetHi && (prefix[idx + 1] - prefix[targetHi]) <= viewport * Self.overscanMultiplier {
                targetHi = max(targetHi, idx + 1)
            }
        }

        guard indexed else {
            return (targetLo..<targetHi, false, 0)
        }

        // Budget off-screen fills on indexed virtualRows to `0.5 * viewport` per edge per frame
        // when jumping/mounting fresh ranges so huge jumps spread cleanly across frames.
        let visRange = visibleRange(offset: offset, viewport: viewport, prefix: prefix, count: count)
        let visLo = visRange.isEmpty ? targetLo : visRange.lowerBound
        let visHi = visRange.isEmpty ? targetHi : visRange.upperBound

        let prevLo = lastMountedRange.lowerBound
        let prevHi = lastMountedRange.upperBound
        let hadPrior = !lastMountedRange.isEmpty

        let chosenLo: Int
        let chosenHi: Int
        if !hadPrior || lastMountedRange.overlaps(targetLo..<targetHi) == false {
            // Initial mount or jump: mount visible + up to 0.5*viewport budget per side.
            let budget = viewport * Self.indexedBudgetMultiplier
            var loIdx = visLo
            while loIdx > targetLo && (prefix[visLo] - prefix[loIdx - 1]) <= budget {
                loIdx -= 1
            }
            var hiIdx = visHi
            while hiIdx < targetHi && (prefix[hiIdx] - prefix[visHi]) <= budget {
                hiIdx += 1
            }
            chosenLo = loIdx
            chosenHi = hiIdx
        } else {
            let budget = viewport * Self.indexedBudgetMultiplier
            var loIdx = min(visLo, max(targetLo, prevLo))
            while loIdx > targetLo && (max(prevLo, visLo) > loIdx ? (prefix[min(prevLo, visLo)] - prefix[loIdx - 1]) : 0) <= budget {
                loIdx -= 1
                if (prefix[prevLo] - prefix[loIdx]) >= budget { break }
            }
            var hiIdx = max(visHi, min(targetHi, prevHi))
            while hiIdx < targetHi && (prefix[hiIdx] - prefix[max(prevHi, visHi)]) < budget {
                hiIdx += 1
            }
            chosenLo = min(loIdx, visLo)
            chosenHi = max(hiIdx, visHi)
        }

        let missing = max(0, chosenLo - targetLo) + max(0, targetHi - chosenHi)
        // Only ask for more frames while edge rows beyond `1.75 * viewport` still aren't mounted.
        let edgeLo = max(0, offset - viewport * Self.indexedEdgeMultiplier)
        let edgeHi = offset + viewport * (1.0 + Self.indexedEdgeMultiplier)
        let edgeWanted = (chosenLo > 0 && prefix[chosenLo] > edgeLo) || (chosenHi < count && prefix[chosenHi] < edgeHi)
        return (chosenLo..<chosenHi, missing > 0 && edgeWanted, missing)
    }

    mutating func pruneMeasurements(keeping activeKeys: Set<String>) {
        guard measuredByKey.count > activeKeys.count * 2 + 256 else { return }
        measuredByKey = measuredByKey.filter { activeKeys.contains($0.key) }
    }
}
