import Foundation

/// A growth stack whose width changed: its rows measure at the new width at once,
/// but their new heights wait until the width is stable, and a streaming row
/// shrinks only a while after (`crates/rune/src/runtime/types.rs:472`).
public enum WidthHold: Equatable, Sendable {
    case off
    /// Heights wait until `until`; a streaming row may shrink from `shrinkFrom`.
    case rewrap(until: Double, shrinkFrom: Double)

    /// Seconds new heights wait after a width change (`WidthHold::HOLD`).
    public static let hold: Double = 0.12
    /// Seconds a streaming row keeps its height after a width change before shrinking (`WidthHold::SHRINK`).
    public static let shrink: Double = 0.4

    /// The width changed at `now` (`WidthHold::rewrap`).
    public static func rewrap(at now: Double) -> WidthHold {
        .rewrap(until: now + hold, shrinkFrom: now + shrink)
    }

    /// Whether a height set at `at` waits for the width to settle (`WidthHold::defers`).
    public func defers(at time: Double) -> Bool {
        if case let .rewrap(until, _) = self {
            return time < until
        }
        return false
    }

    /// Whether a streaming row may shrink at `now` (`WidthHold::may_shrink`).
    public func mayShrink(at now: Double) -> Bool {
        if case let .rewrap(_, shrinkFrom) = self {
            return now >= shrinkFrom
        }
        return true
    }
}

/// Per-row growth/fold tracking entry (`GrowTrack` + layout metadata).
internal struct RuntimeGrowthEntry: Sendable {
    var track: GrowTrack
    var edge: StreamEdge
    var spring: Spring
    var foldLimit: Float
    var naturalHeight: Float = 0
    var withheld: Float = 0
    var lastWidth: Float = 0
    var lastFirstChildTop: Float? = nil
    var contentSlide: (was: Float, dy: Float)? = nil
}

/// Consecutive `foldGlide` rows in one growth stack that open or shut together on one spring (`GrowthRun`).
internal enum RuntimeGrowthRun: Sendable {
    case formed(rows: [String], extents: [Float], targets: [Float], track: GrowTrack)
    case broken

    static func link(keys: [String], grows: [String: RuntimeGrowthEntry]) -> RuntimeGrowthRun? {
        guard keys.count > 1 else { return nil }
        var entries: [RuntimeGrowthEntry] = []
        entries.reserveCapacity(keys.count)
        for k in keys {
            guard let e = grows[k] else { return nil }
            entries.append(e)
        }
        guard let spring = entries[0].track.glide else { return nil }
        var track = GrowTrack.settled(entries.reduce(0) { $0 + $1.track.h })
        track.setKind(
            streaming: false,
            whole: false,
            glide: (FoldGlide(spring: spring, feather: entries[0].track.feather), .infinity)
        )
        track.retarget(entries.reduce(0) { $0 + $1.track.target })
        return .formed(
            rows: keys,
            extents: entries.map { max($0.track.target, $0.track.h) },
            targets: entries.map { $0.track.target },
            track: track
        )
    }

    mutating func commit(order: [String], grows: inout [String: RuntimeGrowthEntry]) -> Bool {
        guard case .formed(let rows, _, let targets, let track) = self else { return false }
        let aims = zip(rows, targets).allSatisfy { k, t in
            grows[k].map { abs($0.track.target - t) < 1e-4 } ?? true
        }
        let present = rows.compactMap { order.firstIndex(of: $0) }
        let contiguous = present.count < 2 || zip(present, present.dropFirst()).allSatisfy { $1 == $0 + 1 }
        if aims && contiguous {
            return true
        }
        let speed = track.v
        for k in rows {
            if var g = grows[k], g.track.h > 1e-4 && g.track.h < max(g.track.target, g.track.h) - 1e-4 {
                g.track.v = speed
                grows[k] = g
            }
        }
        self = .broken
        return false
    }

    var rows: [String] {
        switch self {
        case .formed(let rows, _, _, _): return rows
        case .broken: return []
        }
    }

    var moving: Bool {
        if case .formed(_, _, _, let track) = self {
            return track.moving
        }
        return false
    }

    mutating func step(
        by dt: Float,
        spring: Spring,
        edge: StreamEdge,
        grows: inout [String: RuntimeGrowthEntry]
    ) -> Float {
        guard case .formed(let rows, let extents, let targets, var track) = self else { return 0 }
        track.step(by: dt, spring: spring, edge: edge, carryingTail: false)
        var left = track.h
        var grown: Float = 0
        for (k, extent) in zip(rows, extents) {
            let h = max(0, min(left, extent))
            left -= extent
            guard var entry = grows[k] else { continue }
            let atEdge = h > 1e-4 && h < extent - 1e-4
            grown += max(0, h - entry.track.h)
            entry.track.h = h
            entry.track.v = atEdge ? track.v : 0
            entry.track.mask = atEdge ? track.mask : 0
            grows[k] = entry
        }
        self = .formed(rows: rows, extents: extents, targets: targets, track: track)
        return grown
    }
}

/// Per-`growth(...)` stack state for width-change rewrap deferral, closing rows, and fold runs (`RowStack` in `types.rs`).
internal struct RuntimeGrowthStackState: Sendable {
    var width: Float
    var widthHold: WidthHold
    var pendingHeights: [String: Float] = [:]
    /// Row growth keys (`growth:<path>` / `fold:<path>`) in presented order, including closing rows.
    var order: [String] = []
    /// Removed row growth keys mapped to when their space starts closing.
    var closing: [String: Double] = [:]
    var gap: Float = 0
    /// Room below the last row beyond the stack's own bottom padding and border.
    var trailingSpace: Float = 0
    var spring: Spring = Growth.spring
    var edge: StreamEdge = .feather
    /// Fold rows opening or shutting together as one block.
    var runs: [RuntimeGrowthRun] = []
    var tailHandoff: TailHandoff?

    init(
        width: Float,
        widthHold: WidthHold = .off,
        pendingHeights: [String: Float] = [:],
        order: [String] = [],
        closing: [String: Double] = [:],
        gap: Float = 0,
        spring: Spring = Growth.spring,
        edge: StreamEdge = .feather,
        runs: [RuntimeGrowthRun] = []
    ) {
        self.width = width
        self.widthHold = widthHold
        self.pendingHeights = pendingHeights
        self.order = order
        self.closing = closing
        self.gap = gap
        self.spring = spring
        self.edge = edge
        self.runs = runs
    }

    /// Computes vertical shifts for surviving child indices (`survivingKeys`) and extra stack height
    /// contributed by still-closing rows in `order`.
    func closingLayoutAdjustments(
        survivingKeys: [String?],
        growthRows: [String: RuntimeGrowthEntry]
    ) -> (childShiftsY: [Float], stackExtraH: Float) {
        guard !closing.isEmpty else {
            return ([Float](repeating: 0, count: survivingKeys.count), 0)
        }
        var keyToChildIndex: [String: Int] = [:]
        var hasSurviving = false
        for (idx, k) in survivingKeys.enumerated() {
            if let k {
                keyToChildIndex[k] = idx
                hasSurviving = true
            }
        }
        var childShifts = [Float](repeating: 0, count: survivingKeys.count)
        var accumClosing: Float = 0
        var seenClosing = false
        for k in order {
            if closing[k] != nil, let entry = growthRows[k] {
                if hasSurviving {
                    accumClosing += max(0, entry.track.h) + gap
                } else {
                    if seenClosing {
                        accumClosing += gap
                    }
                    accumClosing += max(0, entry.track.h)
                    seenClosing = true
                }
            } else if let cIdx = keyToChildIndex[k] {
                childShifts[cIdx] = accumClosing
            }
        }
        return (childShifts, accumClosing)
    }
}
