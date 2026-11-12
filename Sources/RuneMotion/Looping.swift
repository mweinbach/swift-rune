import Foundation

/// How a periodic `LoopSpec` repeats across cycles.
public enum LoopMode: Sendable, Hashable {
    /// Repeats `0 -> 1` continuously.
    case wrap
    /// Alternates `0 -> 1 -> 0` each period.
    case pingPong
    /// Plays `count` periods then holds phase `1.0`.
    case count(Int)

    /// Maps non-negative elapsed time `elapsed` over `period` into normalized phase `[0, 1]`.
    public func phase(elapsed: Double, period: Double) -> Double {
        guard period > 0, elapsed >= 0 else { return 0 }
        let raw = elapsed / period
        switch self {
        case .wrap:
            let frac = raw.truncatingRemainder(dividingBy: 1.0)
            return frac < 0 ? frac + 1.0 : frac
        case .pingPong:
            let cycle = raw.truncatingRemainder(dividingBy: 2.0)
            let pos = cycle < 0 ? cycle + 2.0 : cycle
            return pos <= 1.0 ? pos : (2.0 - pos)
        case .count(let n):
            guard n > 0 else { return 1.0 }
            if raw >= Double(n) { return 1.0 }
            let frac = raw.truncatingRemainder(dividingBy: 1.0)
            return frac < 0 ? frac + 1.0 : frac
        }
    }
}

/// What a `LoopTrack` drives (`looping.rs`).
public enum LoopKind: Sendable, Equatable {
    case opacity(low: Float, high: Float)
    /// Piecewise-linear, wall-clock opacity with a bounded frame rate.
    case opacityCycle(Cycle)
    /// Finite opacity/scale choreography; holds its last pose at rest.
    case sequence(MotionSequence)
    case rotation
    /// An eased one-way sweep that wraps, in fractions of the node's own size.
    case slide(from: Vec2, to: Vec2)
    /// A `slide` swept along `easing` instead of ease-in-out.
    case slideEased(from: Vec2, to: Vec2, easing: Easing)
}

/// Specification for clock-driven periodic or finite looping motion (`looping.rs`).
public struct LoopSpec: Sendable, Equatable {
    public var period: Double
    public var delay: Double
    public var mode: LoopMode
    public var kind: LoopKind

    public init(period: Double, delay: Double = 0.0, mode: LoopMode = .wrap, kind: LoopKind) {
        self.period = max(period, 1e-6)
        self.delay = max(0.0, delay)
        self.mode = mode
        self.kind = kind
    }

    public static func sequence(_ frames: MotionSequence) -> LoopSpec {
        LoopSpec(period: max(frames.duration, 1e-6), delay: frames.delay, kind: .sequence(frames))
    }

    public static func cycle(_ cycle: Cycle) -> LoopSpec {
        LoopSpec(period: Double(cycle.period), delay: 0.0, kind: .opacityCycle(cycle))
    }

    public static func opacity(period: Double, delay: Double = 0.0, low: Float, high: Float) -> LoopSpec {
        LoopSpec(period: period, delay: delay, kind: .opacity(low: low, high: high))
    }

    public static func rotation(period: Double) -> LoopSpec {
        LoopSpec(period: period, delay: 0.0, kind: .rotation)
    }

    /// Reduced motion holds the sweep's midpoint; removal cools it back to no offset.
    public static func slide(period: Double, from: Vec2, to: Vec2) -> LoopSpec {
        LoopSpec(period: period, delay: 0.0, kind: .slide(from: from, to: to))
    }

    /// Sets the easing curve for `slide` specs; other kinds are unchanged.
    public func easing(_ easing: Easing) -> LoopSpec {
        var copy = self
        switch kind {
        case let .slide(from, to), let .slideEased(from, to, _):
            copy.kind = .slideEased(from: from, to: to, easing: easing)
        default:
            break
        }
        return copy
    }

    /// Sets the loop repetition mode (`wrap`, `pingPong`, `count`).
    public func mode(_ mode: LoopMode) -> LoopSpec {
        var copy = self
        copy.mode = mode
        return copy
    }
}

/// Live clock-driven loop track with smooth cooling (`enabled(_:at:)`) and phase-preserving `retime`.
public struct LoopTrack: Sendable {
    private enum PhaseState: Sendable, Equatable {
        case playing(since: Double)
        case done
    }

    public private(set) var spec: LoopSpec
    private var phaseState: PhaseState
    private var phase0: Double
    private var amplitude: Animated<Float>

    public init(spec: LoopSpec, now: Double) {
        self.spec = spec
        self.phaseState = .playing(since: now + spec.delay)
        self.phase0 = 0.0
        var amp = Animated<Float>(1.0, propClass: .opacity)
        amp.set(1.0)
        self.amplitude = amp
    }

    private var isFiniteSequence: Bool {
        if case .sequence = spec.kind { return true }
        return false
    }

    /// Normalized phase in `[0, 1]` at `now`.
    public func phase(at now: Double) -> Double {
        let since: Double
        switch phaseState {
        case .playing(let s): since = s
        case .done: return 1.0
        }
        if isFiniteSequence {
            return min(max((now - since) / spec.period, 0.0), 1.0)
        }
        let elapsed = max(0.0, now - since)
        if spec.mode == .wrap {
            let raw = phase0 + elapsed / spec.period
            let frac = raw.truncatingRemainder(dividingBy: 1.0)
            return frac < 0 ? frac + 1.0 : frac
        }
        return spec.mode.phase(elapsed: phase0 * spec.period + elapsed, period: spec.period)
    }

    /// Preserves the presented phase when changing speed; an unchanged spec is a no-op.
    public mutating func retime(spec newSpec: LoopSpec, at now: Double) {
        if spec == newSpec { return }
        let newIsSeq: Bool
        if case .sequence = newSpec.kind { newIsSeq = true } else { newIsSeq = false }
        if isFiniteSequence || newIsSeq {
            self = LoopTrack(spec: newSpec, now: now)
            return
        }
        phase0 = phase(at: now)
        if case let .playing(since) = phaseState {
            phaseState = .playing(since: max(now, since))
        }
        spec = newSpec
    }

    /// Cools to rest without stopping or resetting phase. Reversal inherits envelope velocity.
    public mutating func setEnabled(_ enabled: Bool, at now: Double) {
        if isFiniteSequence {
            if enabled && amplitude.target == 0.0 {
                phaseState = .playing(since: now + spec.delay)
            } else if !enabled {
                phaseState = .done
            }
        }
        amplitude.animateTo(enabled ? 1.0 : 0.0, anim: Anim(curve: .spring(Spring(duration: 0.18, bounce: 0.0))), at: now)
    }

    /// Moves the track onto a clock reading `delta` more, at the same place.
    public mutating func shift(by delta: Double) {
        if case let .playing(since) = phaseState {
            phaseState = .playing(since: since + delta)
        }
        amplitude.shift(delta)
    }

    /// Moves a periodic loop `dt` further along its rhythm; finite sequences keep their place.
    public mutating func advance(by dt: Double) {
        if !isFiniteSequence, case let .playing(since) = phaseState {
            phaseState = .playing(since: since - dt)
        }
    }

    /// Explicit settle/reduced motion lands finite sequences; periodic loops keep their phase.
    public mutating func finish() {
        if isFiniteSequence {
            phaseState = .done
        }
    }

    /// True while the track needs frames at `now`.
    public func isActive(at now: Double) -> Bool {
        switch phaseState {
        case .done:
            return false
        case .playing(let since) where isFiniteSequence:
            return now >= since && now < since + spec.period
        case .playing(let since):
            if case let .count(n) = spec.mode, now >= since + Double(n) * spec.period {
                return !amplitude.isSettled(at: now)
            }
            return (amplitude.target > 0.0 && now >= since) || !amplitude.isSettled(at: now)
        }
    }

    /// The animation-clock instant to wake at; no frames are needed before it.
    public func pendingStart(at now: Double) -> Double? {
        if case let .playing(since) = phaseState, amplitude.target > 0.0, now < since {
            return since
        }
        return nil
    }

    /// Wall-clock cycles retain their cadence even when animation time is paused.
    public func frameInterval() -> Double? {
        if case let .opacityCycle(c) = spec.kind {
            return 1.0 / Double(max(c.fps, 1.0))
        }
        return nil
    }

    /// Opacity multiplier or clockwise radians. Reduced motion uses the calm first pose.
    public func sample(at now: Double, reduced: Bool) -> Float {
        sampleAt(now: now, wall: now, reduced: reduced)
    }

    public func sampleAt(now: Double, wall: Double, reduced: Bool) -> Float {
        let ph = reduced ? Float(0.0) : Float(phase(at: now))
        switch spec.kind {
        case .sequence:
            return pose(at: now, reduced: reduced)?.opacity ?? 1.0
        case .opacityCycle(let c):
            return reduced ? c.still : c.sample(at: wall)
        case .rotation:
            return ph * (.pi * 2.0)
        case .slide, .slideEased:
            return 1.0
        case let .opacity(low, high):
            let triangle = ph < 0.5 ? ph * 2.0 : (1.0 - ph) * 2.0
            return low + (high - low) * Easing.easeInOut.sample(triangle) * amplitude.sample(at: now)
        }
    }

    /// A `slide`'s offset in fractions of the node's own size.
    public func offset(at now: Double, reduced: Bool) -> Vec2? {
        let from: Vec2
        let to: Vec2
        let easing: Easing
        switch spec.kind {
        case let .slide(f, t):
            from = f
            to = t
            easing = .easeInOut
        case let .slideEased(f, t, e):
            from = f
            to = t
            easing = e
        default:
            return nil
        }
        let t = reduced ? Float(0.5) : easing.sample(Float(phase(at: now)))
        let a = amplitude.sample(at: now)
        return Vec2(
            x: (from.x + (to.x - from.x) * t) * a,
            y: (from.y + (to.y - from.y) * t) * a
        )
    }

    public func pose(at now: Double, reduced: Bool) -> Beat? {
        guard case let .sequence(frames) = spec.kind else { return nil }
        let atTime: Double
        if reduced || phaseState == .done {
            atTime = frames.duration
        } else {
            atTime = phase(at: now) * frames.duration
        }
        return frames.sample(elapsed: atTime)
    }
}
