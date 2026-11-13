import Foundation
import RuneMotion

/// One sliding element's phase inside a growing row (`runtime/motion/content_slide.rs`).
public enum SlidePhase: Sendable, Equatable {
    /// Rides the growth row by holding the offset at `(target - h) / (target - at) * dy`.
    case following(dy: Float, v: Float, at: Float)
    /// Springs home after the growth stopped opening toward it.
    case settling(dy: Float, v: Float)

    public var offset: Float {
        switch self {
        case .following(let dy, _, _): return dy
        case .settling(let dy, _): return dy
        }
    }

    public var isLive: Bool {
        switch self {
        case .following(let dy, _, _): return abs(dy) > 0.01
        case .settling(let dy, let v): return abs(dy) > 0.01 || abs(v) > 0.5
        }
    }

    public func step(growth g: GrowTrack, spring: Spring, substeps: Int) -> SlidePhase {
        let dt = Float(substeps) * Growth.substep
        switch self {
        case let .following(dy, v, at):
            let was = g.target - at
            let left = g.target - g.h
            if was * dy < 0.0 && abs(was) > (1.0 / 64.0) {
                let frac = min(max(left / was, 0.0), 1.0)
                let nextDy = dy * frac
                let nextV: Float = dt > 0.0 ? (nextDy - dy) / dt : v
                return .following(dy: nextDy, v: nextV, at: g.h)
            }
            var newDy = dy
            var newV = v
            for _ in 0..<substeps {
                (newDy, newV) = spring.sample(from: newDy, velocity: newV, target: 0.0, at: Growth.substep)
            }
            return .settling(dy: newDy, v: newV)

        case let .settling(dy, v):
            var newDy = dy
            var newV = v
            for _ in 0..<substeps {
                (newDy, newV) = spring.sample(from: newDy, velocity: newV, target: 0.0, at: Growth.substep)
            }
            return .settling(dy: newDy, v: newV)
        }
    }
}

/// Active content slide entry tied to a growth row (`content_slide.rs:Slide`).
public struct ContentSlideEntry: Sendable, Equatable {
    public var id: NodeId
    public var row: NodeId
    public var phase: SlidePhase

    public init(id: NodeId, row: NodeId, phase: SlidePhase) {
        self.id = id
        self.row = row
        self.phase = phase
    }
}

/// Slides carried by a growth stack when rows' tops move (`content_slide.rs:ContentSlides`).
public struct ContentSlides: Sendable, Equatable {
    public var entries: [ContentSlideEntry] = []

    public init(entries: [ContentSlideEntry] = []) {
        self.entries = entries
    }

    public var isMoving: Bool {
        entries.contains { $0.phase.isLive }
    }

    public func offset(for id: NodeId) -> Float? {
        entries.first(where: { $0.id == id })?.phase.offset
    }

    @discardableResult
    public mutating func follow(id: NodeId, row: NodeId, growth: GrowTrack, dy: Float) -> Float {
        let cur: Float
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            cur = entries[idx].phase.offset
            entries.remove(at: idx)
        } else {
            cur = 0.0
        }
        let total = cur + dy
        let left = growth.target - growth.h
        guard left * total < 0.0 && abs(left) > (1.0 / 64.0) else {
            return total
        }
        entries.append(ContentSlideEntry(id: id, row: row, phase: .following(dy: total, v: 0.0, at: growth.h)))
        return 0.0
    }

    public mutating func step(
        spring: Spring,
        substeps: Int,
        trackForRow: (NodeId) -> GrowTrack?
    ) -> Bool {
        var moved = false
        var kept: [ContentSlideEntry] = []
        kept.reserveCapacity(entries.count)
        for var entry in entries {
            let g = trackForRow(entry.row) ?? GrowTrack.settled(0.0)
            let next = entry.phase.step(growth: g, spring: spring, substeps: substeps)
            if abs(next.offset - entry.phase.offset) > 1e-4 {
                moved = true
            }
            if next.isLive {
                entry.phase = next
                kept.append(entry)
            } else {
                moved = true
            }
        }
        entries = kept
        return moved
    }

    public mutating func land(id: NodeId) {
        entries.removeAll { $0.id == id }
    }

    public mutating func keep(rows: Set<NodeId>) {
        entries.removeAll { !rows.contains($0.row) }
    }
}
