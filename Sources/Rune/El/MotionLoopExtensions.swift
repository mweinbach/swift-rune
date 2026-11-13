import Foundation
import RuneMotion

/// Convenience `El` motion/loop/stagger bindings mirroring upstream `el/visuals.rs` & `el/enter_delay.rs`.
public extension El {
    /// Delays a newly mounted element's entrance by `stagger.delay(index: index, count: count)` seconds.
    func enterDelay(_ stagger: Stagger, index: Int, count: Int) -> Self {
        enterDelay(stagger.delay(index: index, count: count))
    }

    /// Keyframed wall-clock opacity cycle defined inline from stop pairs `(phase, opacity)`.
    func cycle(
        period: Float = 1.0,
        phase: Float = 0.0,
        stops: [(Float, Float)],
        still: Float = 0.4,
        fps: Float = 30.0
    ) -> Self {
        cycle(Cycle(period: period, phase: phase, stops: stops, still: still, fps: fps))
    }

    /// Pulses opacity continuously between `low` and `high` over `period` seconds.
    func loopOpacity(
        low: Float = 0.0,
        high: Float = 1.0,
        period: Double = 1.0,
        delay: Double = 0.0
    ) -> Self {
        looping(.opacity(period: period, delay: delay, low: low, high: high))
    }

    /// Rotates continuously `360°` over `period` seconds.
    func loopRotation(period: Double = 1.0, delay: Double = 0.0) -> Self {
        looping(LoopSpec(period: period, delay: delay, kind: .rotation))
    }

    /// Sweeps translation offset repeatedly between `from` and `to` (fractions of node size).
    func loopSlide(
        period: Double = 1.0,
        from: Vec2,
        to: Vec2,
        easing: Easing? = nil,
        delay: Double = 0.0
    ) -> Self {
        let base = LoopSpec(
            period: period,
            delay: delay,
            kind: easing.map { .slideEased(from: from, to: to, easing: $0) } ?? .slide(from: from, to: to)
        )
        return looping(base)
    }
}

public extension Stagger {
    /// Creates an upstream-style cascade stagger with a fixed per-item `step` and optional total `cap`
    /// (`Stagger::new(step).cap(maxDelay)`).
    static func cascade(_ step: Float = 0.06, cap: Float = 0.0) -> Stagger {
        Stagger(step: step, maxDelay: cap)
    }

    /// Fluent upstream-style cap builder (`Stagger::cap`).
    func cap(_ maxDelay: Float) -> Stagger {
        var copy = Stagger(step: step, maxDelay: max(0, maxDelay), from: from).start(start)
        if let ease {
            copy = copy.ease(ease)
        }
        return copy
    }

    /// Upstream parameter-order convenience (`stagger.delay(i, items.len())`).
    func delay(_ index: Int, of count: Int) -> Float {
        delay(index: index, count: count)
    }
}
