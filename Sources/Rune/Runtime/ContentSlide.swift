import Foundation
import RuneMotion

// MARK: - Growth Content Slides (`crates/rune/src/runtime/motion/content_slide.rs`)

/// Where a slide is: how far down from its layout it shows, and how fast that changes
/// (points, per second).
internal enum SlidePhase: Equatable, Sendable {
    /// Shrinking with the growth left to open; `at` is the row's presented height when `dy`
    /// was last measured, and `v` how fast it last moved, which a spring takes over.
    case following(dy: Float, v: Float, at: Float)
    /// Springing to its layout on the row's growth spring, once the growth stopped opening
    /// toward it. It never follows again.
    case settling(dy: Float, v: Float)

    var dy: Float {
        switch self {
        case .following(let dy, _, _), .settling(let dy, _):
            return dy
        }
    }

    /// The phase after row growth has advanced through these time slices.
    func step(growth g: GrowTrack, spring: Spring, steps: GrowthSteps) -> SlidePhase {
        let dt = steps.duration
        var dy: Float
        var v: Float
        switch self {
        case .following(let curDy, let curV, let at):
            let was = g.target - at
            let left = g.target - g.h
            if was * curDy < 0.0 && abs(was) > 1.0 / 64.0 {
                let factor = max(0.0, min(1.0, left / was))
                let next = curDy * factor
                let nextV = dt > 0.0 ? (next - curDy) / dt : curV
                return .following(dy: next, v: nextV, at: g.h)
            }
            dy = curDy
            v = curV
        case .settling(let curDy, let curV):
            dy = curDy
            v = curV
        }
        for step in steps {
            (dy, v) = spring.sample(from: dy, velocity: v, target: 0.0, at: step)
        }
        return .settling(dy: dy, v: v)
    }

    /// Whether it still shows off its layout, or still moves toward it.
    var live: Bool {
        switch self {
        case .following(let dy, _, _):
            return abs(dy) > 1.0 / 128.0
        case .settling(let dy, let v):
            return abs(dy) > 1.0 / 128.0 || abs(v) > 0.5
        }
    }
}

internal struct ContentSlide: Equatable, Sendable {
    var node: NodeId
    var row: NodeId
    var phase: SlidePhase
}

/// The contents of a growth stack's rows sliding with them, drawn outside the scene.
internal struct ContentSlides: Equatable, Sendable {
    private(set) var slides: [ContentSlide] = []

    /// Each sliding node and how far down from its layout it shows.
    var shifts: [(NodeId, Float)] {
        slides.map { ($0.node, $0.phase.dy) }
    }

    /// Slides `node`, drawn `dy` points down from its layout plus any slide it still had, with
    /// row `row`'s growth `g`, if that growth opens toward its layout. Otherwise it stops
    /// following and the whole amount is returned, for the caller to slide some other way.
    mutating func follow(node: NodeId, row: NodeId, growth g: GrowTrack, dy incomingDy: Float) -> Float {
        let existingDy: Float
        if let idx = slides.firstIndex(where: { $0.node == node }) {
            existingDy = slides[idx].phase.dy
            slides.remove(at: idx)
        } else {
            existingDy = 0.0
        }
        let totalDy = incomingDy + existingDy
        let left = g.target - g.h
        if left * totalDy < 0.0 && abs(left) > 1.0 / 64.0 {
            slides.append(ContentSlide(node: node, row: row, phase: .following(dy: totalDy, v: 0.0, at: g.h)))
            return 0.0
        }
        return totalDy
    }

    /// Lands row `row`'s slides at once (its growth landed at once).
    mutating func land(row: NodeId) {
        slides.removeAll { $0.row == row }
    }

    /// Steps row `row`'s slides after its growth `g` stepped `steps` substeps. Returns whether any
    /// still moves for that row.
    @discardableResult
    mutating func step(row: NodeId, growth g: GrowTrack, spring: Spring, steps: GrowthSteps) -> Bool {
        for i in slides.indices where slides[i].row == row {
            slides[i].phase = slides[i].phase.step(growth: g, spring: spring, steps: steps)
        }
        slides.removeAll { !$0.phase.live }
        return slides.contains { $0.row == row }
    }

    /// Drops the slides of rows that left the stack.
    mutating func keep(rows: [NodeId]) {
        slides.removeAll { !rows.contains($0.row) }
    }
}
