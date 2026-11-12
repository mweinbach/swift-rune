import Foundation

/// Exponential inertial decay `v(tau) = v0 * exp(-rate * tau)`, matching iOS `UIScrollView`.
public struct Decay: Sendable, Hashable, Codable {
    /// Decay rate `k` in `1/s`.
    public var rate: Float

    public init(rate: Float = 2.002002) {
        self.rate = max(rate, 1e-4)
    }

    /// `UIScrollView.DecelerationRate.normal` (`0.998` per ms -> `-1000 * ln(0.998) = 2.002002 / s`).
    public static let IOS_NORMAL = Decay(rate: 2.002002)
    /// `UIScrollView.DecelerationRate.fast` (`0.990` per ms -> `-1000 * ln(0.990) = 10.050336 / s`).
    public static let IOS_FAST = Decay(rate: 10.050336)

    /// From a per-millisecond deceleration rate `r` (UIKit): `k = -1000 * ln(r)`.
    public static func perMs(_ r: Float) -> Decay {
        let clamped = r.clamped(to: 1e-4...0.99999)
        return Decay(rate: -1000.0 * logf(clamped))
    }

    /// Total rest distance `v0 / rate` travelled as `t -> infinity`.
    @inlinable
    public func distance(initialVelocity v0: Float) -> Float {
        v0 / rate
    }

    /// Resting target starting from `x0` with velocity `v0`.
    @inlinable
    public func target(from x0: Float, initialVelocity v0: Float) -> Float {
        x0 + distance(initialVelocity: v0)
    }

    /// Time until `|v(t)| <= velocityThreshold`.
    @inlinable
    public func duration(initialVelocity v0: Float, velocityThreshold: Float = 0.5) -> Float {
        let speed = abs(v0)
        let thresh = max(velocityThreshold, 1e-4)
        if speed <= thresh { return 0 }
        return logf(speed / thresh) / rate
    }
}

/// Unified curve descriptor for `AnimationStore` and `Scene`.
public enum Curve: Sendable, Hashable {
    case spring(Spring)
    case tween(duration: Float, easing: Easing)
    case decay(Decay)
    /// Velocity-matched cubic Hermite spline of `duration` seconds.
    case hermite(duration: Float)
    case instant

    public static let REDUCED_FADE = Curve.tween(duration: 0.18, easing: .easeInOut)

    @inlinable
    public static func smooth(_ duration: Float = 0.5) -> Curve {
        .spring(Spring(duration: duration, bounce: 0))
    }

    @inlinable
    public static func snappy(_ duration: Float = 0.25) -> Curve {
        .spring(Spring(duration: duration, bounce: 0))
    }

    @inlinable
    public static func bouncy(_ duration: Float = 0.3) -> Curve {
        .spring(Spring(duration: duration, bounce: 0.3))
    }

    @inlinable
    public static func linear(_ duration: Float) -> Curve {
        .tween(duration: duration, easing: .linear)
    }

    @inlinable
    public static func easeInOut(_ duration: Float) -> Curve {
        .tween(duration: duration, easing: .easeInOut)
    }

    /// Logical completion time in seconds (`spring.duration`, `tween.duration`, `1 / decay.rate`, or `0`).
    @inlinable
    public var logicalDuration: Float {
        switch self {
        case .spring(let s): return s.duration
        case .tween(let duration, _): return duration
        case .decay(let d): return 1.0 / d.rate
        case .hermite(let duration): return duration
        case .instant: return 0.0
        }
    }
}

/// Retargeting strategy when a track receives a new target while already in flight.
public enum Blend: Sendable, Hashable {
    /// Collapse current position and velocity into a single analytic response toward the new target.
    case merge
    /// Superpose a new analytic offset layer on top of running layers (`target_new - target_old`).
    case additive
    /// Cut immediately to the target with zero velocity, dropping all active layers.
    case snap
}

/// Typed velocity wrapper matching an `Animatable`'s lanes (units per second).
public struct Velocity<T: Animatable>: Sendable, Equatable {
    public var lanes: MotionLanes

    public static var zero: Velocity<T> { Velocity(lanes: .zero) }

    public init(lanes: MotionLanes) {
        self.lanes = lanes
    }

    public init(_ raw: T) {
        self.lanes = raw.toLanes()
    }
}

/// Full animation specification combining curve, retargeting blend, optional delay, and velocity seed.
public struct Anim<T: Animatable>: Sendable, Equatable {
    public var curve: Curve
    public var blend: Blend
    public var delay: Float
    public var initialVelocity: Velocity<T>?

    public init(
        curve: Curve,
        blend: Blend = .merge,
        delay: Float = 0,
        initialVelocity: Velocity<T>? = nil
    ) {
        self.curve = curve
        self.blend = blend
        self.delay = max(0, delay)
        self.initialVelocity = initialVelocity
    }

    public static func spring(_ spring: Spring, blend: Blend = .merge) -> Anim<T> {
        Anim(curve: .spring(spring), blend: blend)
    }

    public static func tween(duration: Float, easing: Easing = .easeInOut, blend: Blend = .merge) -> Anim<T> {
        Anim(curve: .tween(duration: duration, easing: easing), blend: blend)
    }

    public static var instant: Anim<T> {
        Anim(curve: .instant, blend: .snap)
    }
}
