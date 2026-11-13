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
    /// Velocity-matched cubic Hermite spline of `duration` seconds ending at `endVelocity`.
    case hermite(duration: Float, endVelocity: Float)
    case instant

    @inlinable
    public static func from(_ spring: Spring) -> Curve {
        spring == .none ? .instant : .spring(spring)
    }

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
        case .hermite(let duration, _): return duration
        case .instant: return 0.0
        }
    }

    /// How retargeting blends by default: springs, decays, and keyframes merge; tweens add.
    @inlinable
    public var defaultBlend: Blend {
        switch self {
        case .spring, .decay, .instant, .hermite: return .merge
        case .tween: return .additive
        }
    }
}

/// Retargeting strategy when a track receives a new target while already in flight.
public enum Blend: Sendable, Hashable {
    /// Merge for springs, decays, and Hermite keyframes; additive for tweens.
    case auto
    /// Collapse current position and velocity into a single analytic response toward the new target.
    case merge
    /// Superpose a new analytic offset layer on top of running layers (`target_new - target_old`).
    case additive
    /// Cut immediately to the target with zero velocity, dropping all active layers.
    case snap
}

/// Starting velocity rule for an animation segment.
public enum VelocityRule: Sendable, Hashable {
    /// Keep the track's instantaneous velocity (default interruptible motion).
    case inherit
    /// Start from zero velocity.
    case zero
    /// Start every lane at the same velocity (units per second).
    case uniform(Float)
}

private final class VelocityStorage: @unchecked Sendable {
    var lanes: MotionLanes
    init(_ lanes: MotionLanes) { self.lanes = lanes }
    static let zero = VelocityStorage(.zero)
}

/// Typed velocity wrapper matching an `Animatable`'s lanes (units per second).
public struct Velocity<T: Animatable>: Sendable, Hashable {
    private var storage: VelocityStorage

    public var lanes: MotionLanes {
        get { storage.lanes }
        set {
            if !isKnownUniquelyReferenced(&storage) {
                storage = VelocityStorage(storage.lanes)
            }
            storage.lanes = newValue
        }
    }

    public static var zero: Velocity<T> { Velocity(storage: .zero) }

    private init(storage: VelocityStorage) {
        self.storage = storage
    }

    public init(lanes: MotionLanes) {
        self.storage = VelocityStorage(lanes)
    }

    public init(_ raw: T) {
        self.storage = VelocityStorage(raw.toLanes())
    }

    public static func == (lhs: Velocity<T>, rhs: Velocity<T>) -> Bool {
        lhs.storage === rhs.storage || lhs.storage.lanes == rhs.storage.lanes
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(storage.lanes)
    }
}

/// Full animation specification combining curve, retargeting blend, optional delay, velocity seed, and completion token.
public struct Anim<T: Animatable>: Sendable, Hashable {
    public var curve: Curve
    public var blend: Blend
    public var delay: Float
    public var initialVelocity: Velocity<T>?
    public var velocityRule: VelocityRule
    /// Non-zero fires `MotionEvent.completed(token:node:prop:finished:)` when this animation settles or is replaced.
    public var token: UInt64

    public init(
        curve: Curve,
        blend: Blend = .auto,
        delay: Float = 0,
        initialVelocity: Velocity<T>? = nil,
        velocityRule: VelocityRule = .inherit,
        token: UInt64 = 0
    ) {
        self.curve = curve
        self.blend = blend
        self.delay = max(0, delay)
        self.initialVelocity = initialVelocity
        self.velocityRule = velocityRule
        self.token = token
    }

    @inlinable
    public var resolvedBlend: Blend {
        switch blend {
        case .auto: return curve.defaultBlend
        default: return blend
        }
    }

    public func delay(_ seconds: Float) -> Anim<T> {
        var copy = self
        copy.delay = max(0, seconds)
        return copy
    }

    public func blend(_ blend: Blend) -> Anim<T> {
        var copy = self
        copy.blend = blend
        return copy
    }

    public func additive() -> Anim<T> { blend(.additive) }
    public func merge() -> Anim<T> { blend(.merge) }

    public func velocity(_ rule: VelocityRule) -> Anim<T> {
        var copy = self
        copy.velocityRule = rule
        if case .zero = rule { copy.initialVelocity = nil }
        return copy
    }

    public func completion(_ token: UInt64) -> Anim<T> {
        var copy = self
        copy.token = token
        return copy
    }

    public static func spring(_ spring: Spring, blend: Blend = .auto) -> Anim<T> {
        Anim(curve: Curve.from(spring), blend: blend)
    }

    public init(
        spring: Spring,
        blend: Blend = .auto,
        delay: Float = 0,
        initialVelocity: Velocity<T>? = nil,
        velocityRule: VelocityRule = .inherit,
        token: UInt64 = 0
    ) {
        self.init(
            curve: Curve.from(spring),
            blend: blend,
            delay: delay,
            initialVelocity: initialVelocity,
            velocityRule: velocityRule,
            token: token
        )
    }

    public init(_ pair: SpringPair, blend: Blend = .auto) {
        self.init(curve: Curve.from(pair.enter), blend: blend)
    }

    public static func tween(duration: Float, easing: Easing = .easeInOut, blend: Blend = .auto) -> Anim<T> {
        Anim(curve: .tween(duration: duration, easing: easing), blend: blend)
    }

    public static var instant: Anim<T> {
        Anim(curve: .instant, blend: .snap)
    }
}

/// Untyped animation descriptor used internally by `AnimationStore` and `Scene`.
public typealias RawAnim = Anim<Float>
