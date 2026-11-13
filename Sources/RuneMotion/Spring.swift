import Foundation

/// SwiftUI-style perceptual spring parameterized by `(duration, bounce)`.
///
/// - `duration`: perceptual period in seconds (`omega = 2 * pi / duration`).
/// - `bounce`: `0` critically damped (no overshoot), `(0, 1)` underdamped (bouncy),
///   `(-1, 0)` overdamped (`zeta = 1 / (1 + bounce)`).
public struct Spring: Sendable, Hashable, Codable {
    public var duration: Float
    public var bounce: Float

    public init(duration: Float = 0.5, bounce: Float = 0.0) {
        self.duration = max(duration, 1e-6)
        self.bounce = bounce.clamped(to: -0.999...0.999)
    }

    public static let none = Spring(duration: 1e-6, bounce: 0.0)
    public static let `default` = Spring(duration: 0.5, bounce: 0.0)
    public static let smooth = Spring(duration: 0.5, bounce: 0.0)
    public static let snappy = Spring(duration: 0.5, bounce: 0.15)
    public static let bouncy = Spring(duration: 0.5, bounce: 0.3)
    public static var interactive: Spring {
        fromResponse(0.15, dampingFraction: 0.86)
    }

    /// Construct a spring with explicit perceptual duration and bounce.
    public static func smooth(duration: Float, extraBounce: Float = 0.0) -> Spring {
        Spring(duration: duration, bounce: extraBounce)
    }

    public static func snappy(duration: Float, extraBounce: Float = 0.0) -> Spring {
        Spring(duration: duration, bounce: 0.15 + extraBounce)
    }

    public static func bouncy(duration: Float, extraBounce: Float = 0.0) -> Spring {
        Spring(duration: duration, bounce: 0.3 + extraBounce)
    }

    /// Construct from classical `(stiffness, damping)` assuming unit mass `m = 1`.
    public static func fromStiffnessDamping(stiffness: Float, damping: Float, mass: Float = 1.0) -> Spring {
        let m = max(mass, 1e-5)
        let k = max(stiffness, 1e-5)
        let omega = sqrtf(k / m)
        let duration = (2.0 * .pi) / omega
        let zeta = max(0, damping) / (2.0 * sqrtf(k * m))
        return fromDurationDampingRatio(duration: duration, dampingRatio: zeta)
    }

    /// Construct from perceptual duration and classical damping ratio `zeta`.
    public static func fromDurationDampingRatio(duration: Float, dampingRatio zeta: Float) -> Spring {
        let z = max(zeta, 1e-3)
        let bounce: Float
        if z <= 1.0 {
            bounce = 1.0 - z
        } else {
            bounce = (1.0 / z) - 1.0
        }
        return Spring(duration: duration, bounce: bounce)
    }

    /// SwiftUI `.spring(response:dampingFraction:)`: `omega = 2*pi / response`, `zeta = dampingFraction`.
    public static func fromResponse(_ response: Float, dampingFraction: Float) -> Spring {
        fromDurationDampingRatio(duration: max(response, 1e-6), dampingRatio: dampingFraction)
    }

    /// Construct from angular frequency `omega` (rad/s) and damping ratio `zeta` (> 0).
    public static func fromOmegaZeta(omega: Float, zeta: Float) -> Spring {
        let w = max(omega, 1e-4)
        return fromDurationDampingRatio(duration: (2.0 * .pi) / w, dampingRatio: zeta)
    }

    /// Motion's `{ visualDuration, bounce }`: `duration = visualDuration * 1.2`.
    public static func fromMotion(visualDuration: Float, bounce: Float = 0.0) -> Spring {
        Spring(duration: visualDuration * 1.2, bounce: bounce)
    }

    /// The `visualDuration` to hand Motion for the same physical spring (`duration / 1.2`).
    @inlinable
    public var motionVisualDuration: Float {
        duration / 1.2
    }

    /// Undamped angular frequency `omega = 2 * pi / duration`.
    @inlinable
    public var omega: Float {
        (2.0 * .pi) / max(duration, 1e-6)
    }

    /// Perceptual response (`duration`).
    @inlinable
    public var response: Float { duration }

    /// Classical damping ratio `zeta`.
    @inlinable
    public var dampingRatio: Float {
        if bounce >= 0 {
            return max(1e-4, 1.0 - bounce)
        } else {
            return 1.0 / max(1e-4, 1.0 + bounce)
        }
    }

    /// Classical stiffness `k = omega^2` (unit mass).
    @inlinable
    public var stiffness: Float {
        let w = omega
        return w * w
    }

    /// Classical viscous damping `c = 2 * zeta * omega` (unit mass).
    @inlinable
    public var damping: Float {
        2.0 * dampingRatio * omega
    }

    @inlinable
    public func scaledDuration(_ factor: Float) -> Spring {
        Spring(duration: duration * factor, bounce: bounce)
    }

    @inlinable
    public func withDuration(_ newDuration: Float) -> Spring {
        Spring(duration: newDuration, bounce: bounce)
    }

    /// Position and velocity at `t` seconds after leaving `x0` with velocity `v0` toward `target`.
    public func sample(from x0: Float, velocity v0: Float, target: Float, at t: Float) -> (position: Float, velocity: Float) {
        if t <= 0 { return (x0, v0) }
        let omega = self.omega
        let zeta = self.dampingRatio
        let a = x0 - target
        if abs(zeta - 1.0) < 1e-4 {
            let b = v0 + omega * a
            let e = expf(-omega * t)
            let lin = a + b * t
            return (target + lin * e, (b - omega * lin) * e)
        } else if zeta < 1.0 {
            let sigma = zeta * omega
            let omegaD = omega * sqrtf(max(1e-8, 1.0 - zeta * zeta))
            let b = (v0 + sigma * a) / omegaD
            let e = expf(-sigma * t)
            let angle = omegaD * t
            let cs = cosf(angle)
            let sn = sinf(angle)
            let off = e * (a * cs + b * sn)
            let vel = e * ((b * omegaD - sigma * a) * cs - (a * omegaD + sigma * b) * sn)
            return (target + off, vel)
        } else {
            let s = sqrtf(max(1e-8, zeta * zeta - 1.0))
            let r1 = -omega * (zeta - s)
            let r2 = -omega * (zeta + s)
            let c1 = (v0 - r2 * a) / (r1 - r2)
            let c2 = a - c1
            let e1 = expf(r1 * t)
            let e2 = expf(r2 * t)
            return (target + c1 * e1 + c2 * e2, c1 * r1 * e1 + c2 * r2 * e2)
        }
    }

    /// Seconds until a unit step (0 -> 1 from rest) stays within `epsilon` of the target
    /// (position `epsilon`, velocity `10 * epsilon`).
    public func settlingDuration(epsilon: Float = 1e-3) -> Float {
        settlingDuration(from: 0.0, velocity: 0.0, target: 1.0, epsilon: epsilon)
    }

    /// Seconds until an arbitrary retarget stays within `epsilon` of `target`.
    public func settlingDuration(from x0: Float, velocity v0: Float, target: Float, epsilon: Float = 1e-3) -> Float {
        if self == .none { return 0.0 }
        let eps = max(epsilon, 1e-6)
        guard let layer = Layer.make(
            curve: .spring(self),
            offset: x0 - target,
            velocity: v0,
            t0: 0.0,
            posEps: eps,
            velEps: eps * 10.0
        ) else {
            return 0.0
        }
        return max(0.0, layer.settleDuration)
    }

    /// Bakes the unit step response into a CSS `linear()` easing plus its duration in ms.
    public func cssLinear() -> (easing: String, durationMs: UInt32) {
        let total = max(settlingDuration(epsilon: 0.002), 1.0 / 60.0)
        let n = min(max(Int(ceilf(total * 60.0)), 2), 240)
        var s = "linear(0"
        for i in 1..<n {
            let t = total * Float(i) / Float(n)
            let (x, _) = sample(from: 0.0, velocity: 0.0, target: 1.0, at: t)
            let rounded = (x * 1000.0).rounded() / 1000.0
            s.append(",\(rounded)")
        }
        s.append(",1)")
        return (s, UInt32((total * 1000.0).rounded()))
    }
}

/// Paired enter / exit springs (exits run ~20% tighter with less bounce).
public struct SpringPair: Sendable, Hashable, Codable {
    public var enter: Spring
    public var exit: Spring

    public init(enter: Spring, exit: Spring) {
        self.enter = enter
        self.exit = exit
    }

    public static let none = SpringPair(enter: .none, exit: .none)

    public static func withExitRatio(_ enter: Spring, ratio: Float) -> SpringPair {
        SpringPair(enter: enter, exit: Spring(duration: enter.duration * ratio, bounce: enter.bounce * 0.5))
    }
}

/// Named motion tokens matching `rune_motion::tokens`.
public enum MotionTokens {
    /// Immediate response (press feedback, hover snaps): `0.10s`, bounce `0`.
    public static let INSTANT = Spring(duration: 0.10, bounce: 0.0)
    public static let INSTANT_EXIT = Spring(duration: 0.10, bounce: 0.0)
    /// Snappy UI controls (switches, checkboxes, buttons): `0.25s`, bounce `0`.
    public static let SNAP = Spring(duration: 0.25, bounce: 0.0)
    public static let SNAP_EXIT = Spring(duration: 0.20, bounce: 0.0)
    public static let SNAPPY = SNAP
    public static let QUICK = SNAP
    public static let SNAP_PAIR = SpringPair(enter: SNAP, exit: SNAP_EXIT)
    /// Default UI settle (disclosures, accordions, cards): `0.30s`, bounce `0`.
    public static let SETTLE = Spring(duration: 0.30, bounce: 0.0)
    public static let SETTLE_EXIT = Spring(duration: 0.24, bounce: 0.0)
    public static let DEFAULT = SETTLE
    public static let SETTLE_PAIR = SpringPair(enter: SETTLE, exit: SETTLE_EXIT)
    /// Calm layout reflow (list reordering, split resize): `0.40s`, bounce `0`.
    public static let REFLOW = Spring(duration: 0.40, bounce: 0.0)
    public static let REFLOW_EXIT = Spring(duration: 0.32, bounce: 0.0)
    public static let CALM = REFLOW
    public static let REFLOW_PAIR = SpringPair(enter: REFLOW, exit: REFLOW_EXIT)
    /// Sheet / drawer glide: `0.32s`, bounce `0`.
    public static let GLIDE = Spring(duration: 0.32, bounce: 0.0)
    public static let GLIDE_EXIT = Spring(duration: 0.26, bounce: 0.0)
    public static let SMOOTH = GLIDE
    public static let GLIDE_PAIR = SpringPair(enter: GLIDE, exit: GLIDE_EXIT)
    /// Playful pill / indicator morph: `0.30s`, bounce `0.16`.
    public static let MORPH = Spring(duration: 0.30, bounce: 0.16)
    public static let MORPH_EXIT = Spring(duration: 0.27, bounce: 0.08)
    public static let MORPH_PAIR = SpringPair(enter: MORPH, exit: MORPH_EXIT)
    /// Tactile badge / popover pop: `0.25s`, bounce `0.15`.
    public static let POP = Spring(duration: 0.25, bounce: 0.15)
    public static let POP_EXIT = Spring(duration: 0.20, bounce: 0.05)
    public static let PLAYFUL = POP
    public static let POP_PAIR = SpringPair(enter: POP, exit: POP_EXIT)
    /// Ambient slow drift: `0.85s`, bounce `0`.
    public static let DRIFT = Spring(duration: 0.85, bounce: 0.0)
    public static let DRIFT_EXIT = Spring(duration: 0.60, bounce: 0.0)
    public static let SLOW = DRIFT
    public static let DRIFT_PAIR = SpringPair(enter: DRIFT, exit: DRIFT_EXIT)
    /// Explainer camera moves (`1.2s`, bounce `0`).
    public static let CAMERA = Spring(duration: 1.2, bounce: 0.0)
    /// Leading edge in directional expansion: `0.20s`, bounce `0`.
    public static let LEAD = Spring(duration: 0.20, bounce: 0.0)

    public static let REDUCED_FADE = Curve.REDUCED_FADE
    public static let CSS_ENTER = Curve.tween(duration: 0.15, easing: .enter)
    public static let CSS_EXIT = Curve.tween(duration: 0.11, easing: .exit)

    public static func followLead() -> Spring {
        Spring.fromOmegaZeta(omega: 34.0, zeta: 0.86)
    }

    public static func followTrail() -> Spring {
        Spring.fromOmegaZeta(omega: 25.0, zeta: 1.0)
    }

    public static let ALL: [(name: String, pair: SpringPair)] = [
        ("instant", SpringPair(enter: INSTANT, exit: INSTANT_EXIT)),
        ("snap", SNAP_PAIR),
        ("settle", SETTLE_PAIR),
        ("reflow", REFLOW_PAIR),
        ("glide", GLIDE_PAIR),
        ("morph", MORPH_PAIR),
        ("pop", POP_PAIR),
        ("drift", DRIFT_PAIR),
    ]
}
