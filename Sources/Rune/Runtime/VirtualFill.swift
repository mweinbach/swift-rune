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
    static let pinnedRows: Int = 32

    struct VirtualMountedSnapshot: Equatable, Sendable {
        var mountedKeys: [String]
        var range: Range<Int>
        var topSpacerH: Float
        var botSpacerH: Float
        var padTop: Float
        var padBottom: Float
    }

    var measuredByKey = VirtualRowMeasurements()
    private(set) var rowPlaces = VirtualRowPlaces<String>([])

    var lastKeys: [String] {
        get { rowPlaces.keys }
        set { replaceRowPlaces(VirtualRowPlaces(newValue)) }
    }

    mutating func replaceRowPlaces(_ places: VirtualRowPlaces<String>) {
        rowPlaces = places
        // On a layout retry the prior window is restored along with the new measurements.
        if places.keys != measuredByKey.places.keys {
            measuredByKey.replacePlaces(places)
        }
    }
    var lastKeysVersion: UInt64? = nil
    var lastMountedRange: Range<Int> = 0..<0
    var lastVisibleRange: Range<Int>? = nil
    var lastSelectedKey: String? = nil
    var lastAnchorKey: String? = nil
    var lastAnchorLocalY: Float = 0
    var lastAnchorPrefixY: Float = 0
    var rowKeyBySegment: [String: String] = [:]
    var lastCommittedOffsetY: Float? = nil
    var wantsMoreFrames: Bool = false
    var missingOverscanRows: Int = 0
    var isIndexed: Bool = false
    var lastMountedSnapshot: VirtualMountedSnapshot? = nil
    /// The path of the scroll viewport the list windows against (`VirtualList::scroll_path`).
    var scrollPath: String = ""
    /// That viewport's height, as last laid out (`VirtualList::viewport`).
    var viewport: Float = 0
    /// Where the list starts in its viewport's content, as last laid out (`VirtualList::top`).
    var top: Float = 0
    /// The list lies in a row of another virtual list with the same scroll viewport (an open
    /// section of a long list, itself long): it windows against that viewport where the row
    /// places it (`top`), and only that viewport, not this list, is pinned to its end
    /// (`locate`) (`VirtualList::nested`).
    var nested: Bool = false
    /// How far the viewport's content runs on under a nested list, as last laid out: where its
    /// window stands while the viewport is pinned to its end (`VirtualList::tail`).
    var tail: Float = 0
    /// A nested list wholly above the viewport's top holds no reader, so it anchors nothing:
    /// its rows changing height move the rows under it, which the list around it anchors
    /// (`VirtualList::passed`).
    private(set) var passed: Bool = false
    /// The list's own top and bottom padding (`VirtualList::pad_top` / `pad_bottom`).
    var padTop: Float = 0
    var padBottom: Float = 0

    /// The rows' extent, their padding included, for rows totalling `total` (`VirtualList::extent`).
    func extent(total: Float) -> Float {
        padTop + total + padBottom
    }

    /// The list's own scroll offset, and whether its window is pinned to its end, for its
    /// viewport scrolled to `scroll` (`pinned`: the viewport holds its end). A nested list
    /// is never pinned itself: it stands where the viewport's end leaves it (`VirtualList::at`).
    func at(_ scroll: Float, pinned: Bool, total: Float) -> (offset: Float, pinned: Bool) {
        if !nested {
            return (max(0, scroll - top), pinned)
        }
        let offset = pinned ? extent(total: total) + tail - viewport : scroll - top
        return (max(0, offset), false)
    }

    /// `at`, noting whether a nested list lies wholly above the viewport's top and so anchors
    /// nothing (`select`, `hold` and the commits that anchor the reader) (`VirtualList::locate`).
    mutating func locate(_ scroll: Float, pinned: Bool, total: Float) -> (offset: Float, pinned: Bool) {
        let at = self.at(scroll, pinned: pinned, total: total)
        passed = nested && at.offset >= extent(total: total)
        return at
    }

    /// The rows above row `end`, at their measured or estimated heights (`VirtualList::prefix`).
    func prefix(_ end: Int, estimated: Float) -> Float {
        let count = min(lastKeys.count, max(0, end))
        return measuredByKey.heights.prefix(count).reduce(0) { $0 + ($1 ?? max(1, estimated)) }
    }

    func rowHeight(forKey key: String, estimated: Float) -> Float {
        measuredByKey[key] ?? max(1, estimated)
    }

    func computeOffsets(estimated: Float) -> (prefix: [Float], total: Float) {
        var prefix: [Float] = []
        prefix.reserveCapacity(lastKeys.count + 1)
        var y: Float = 0
        prefix.append(0)
        let fallback = max(1, estimated)
        for height in measuredByKey.heights {
            y += height ?? fallback
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

    private func overscanBounds(
        offset: Float,
        viewport: Float,
        prefix: [Float],
        count: Int,
        pinned: Bool
    ) -> (effOffset: Float, targetLo: Int, targetHi: Int, edgeLo: Float, edgeHi: Float) {
        let maxOffset = max(0, (prefix.last ?? 0) - viewport)
        let effOffset = pinned ? maxOffset : min(max(0, offset), maxOffset)
        let lo = max(0, effOffset - viewport * Self.overscanMultiplier)
        let hi = effOffset + viewport * (1.0 + Self.overscanMultiplier)

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
        if pinned { targetLo = min(targetLo, max(0, targetHi - Self.pinnedRows)) }
        let edgeLo = max(0, effOffset - viewport * Self.indexedEdgeMultiplier)
        let edgeHi = effOffset + viewport * (1.0 + Self.indexedEdgeMultiplier)
        return (effOffset, targetLo, targetHi, edgeLo, edgeHi)
    }

    private func windowNeed(
        chosenLo: Int,
        chosenHi: Int,
        targetLo: Int,
        targetHi: Int,
        edgeLo: Float,
        edgeHi: Float,
        prefix: [Float],
        count: Int,
        pinned: Bool
    ) -> (wantedMore: Bool, missing: Int) {
        let overlap = max(0, min(chosenHi, targetHi) - max(chosenLo, targetLo))
        let missing = targetHi - targetLo - overlap
        let edgeWanted = pinned
            ? (chosenHi < count || (missing > 0 && chosenLo > targetLo))
            : ((chosenLo > 0 && prefix[chosenLo] > edgeLo) || (chosenHi < count && prefix[chosenHi] < edgeHi))
        return (missing > 0 && edgeWanted, missing)
    }

    func overscanWindow(
        offset: Float,
        viewport: Float,
        prefix: [Float],
        count: Int,
        indexed: Bool,
        pinnedIndices: Set<Int>,
        pinned: Bool = false,
        bypassBudget: Bool = false,
        forceAll: Bool = false
    ) -> (mounted: Range<Int>, wantedMore: Bool, missing: Int) {
        guard count > 0, viewport > 0 else { return (0..<0, false, 0) }
        if forceAll {
            return (0..<count, false, 0)
        }
        let bounds = overscanBounds(offset: offset, viewport: viewport, prefix: prefix, count: count, pinned: pinned)
        let effOffset = bounds.effOffset
        var targetLo = bounds.targetLo
        var targetHi = bounds.targetHi

        // Preserve pinned indices near edges within overscan.
        for idx in pinnedIndices where idx >= 0 && idx < count {
            if idx < targetLo && (prefix[targetLo] - prefix[idx]) <= viewport * Self.overscanMultiplier {
                targetLo = min(targetLo, idx)
            }
            if idx >= targetHi && (prefix[idx + 1] - prefix[targetHi]) <= viewport * Self.overscanMultiplier {
                targetHi = max(targetHi, idx + 1)
            }
        }

        guard indexed && !pinned && !bypassBudget else {
            return (targetLo..<targetHi, false, 0)
        }

        // Budget off-screen fills on indexed virtualRows to `0.5 * viewport` per edge per frame
        // when jumping/mounting fresh ranges so huge jumps spread cleanly across frames.
        let visRange = visibleRange(offset: effOffset, viewport: viewport, prefix: prefix, count: count)
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
            var cLo = loIdx
            var cHi = hiIdx
            for idx in pinnedIndices where idx >= targetLo && idx < targetHi {
                cLo = min(cLo, idx)
                cHi = max(cHi, idx + 1)
            }
            chosenLo = cLo
            chosenHi = cHi
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
            var cLo = min(loIdx, visLo)
            var cHi = max(hiIdx, visHi)
            for idx in pinnedIndices where idx >= targetLo && idx < targetHi {
                cLo = min(cLo, idx)
                cHi = max(cHi, idx + 1)
            }
            chosenLo = cLo
            chosenHi = cHi
        }

        let need = windowNeed(
            chosenLo: chosenLo,
            chosenHi: chosenHi,
            targetLo: targetLo,
            targetHi: targetHi,
            edgeLo: bounds.edgeLo,
            edgeHi: bounds.edgeHi,
            prefix: prefix,
            count: count,
            pinned: pinned
        )
        return (chosenLo..<chosenHi, need.wantedMore, need.missing)
    }

    func postMeasureWindowNeed(
        offset: Float,
        viewport: Float,
        prefix: [Float],
        count: Int,
        mounted: Range<Int>,
        indexed: Bool,
        pinned: Bool
    ) -> (wantedMore: Bool, missing: Int) {
        guard indexed && count > 0 && viewport > 0 else { return (false, 0) }
        let bounds = overscanBounds(offset: offset, viewport: viewport, prefix: prefix, count: count, pinned: pinned)
        return windowNeed(
            chosenLo: mounted.lowerBound,
            chosenHi: mounted.upperBound,
            targetLo: bounds.targetLo,
            targetHi: bounds.targetHi,
            edgeLo: bounds.edgeLo,
            edgeHi: bounds.edgeHi,
            prefix: prefix,
            count: count,
            pinned: pinned
        )
    }

    /// Re-evaluates overscan fill demand against post-commit measured row heights (`window.rs:52-87`, `r368`, `r380`).
    func fillDemand(
        offset: Float,
        viewport: Float,
        prefix: [Float],
        count: Int,
        pinned: Bool = false
    ) -> (wanted: Bool, missing: Int) {
        guard count > 0, viewport > 0 else { return (false, 0) }
        let lo = max(0, lastMountedRange.lowerBound)
        let hi = min(count, lastMountedRange.upperBound)
        guard lo <= hi, hi < prefix.count else { return (false, 0) }

        let need = postMeasureWindowNeed(
            offset: offset,
            viewport: viewport,
            prefix: prefix,
            count: count,
            mounted: lo..<hi,
            indexed: true,
            pinned: pinned
        )
        return (need.wantedMore, need.wantedMore ? need.missing : 0)
    }


}
