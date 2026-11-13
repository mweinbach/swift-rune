import Foundation

/// A single animated value you own directly (no `NodeId` or `AnimationStore` required).
/// Uses the same closed-form `Layer` math as `AnimationStore`.
public struct Animated<T: Animatable>: Sendable {
    public private(set) var target: T
    private var targetLanes: MotionLanes
    private var layers: [Layer?]
    private var curve: Curve = .instant
    private var posEps: Float
    private var velEps: Float

    public init(_ value: T, propClass: PropClass = .spatial, pixelScale: Float = 2.0) {
        self.target = value
        self.targetLanes = value.toLanes()
        self.layers = Array(repeating: nil, count: T.laneCount)
        let eps = propClass.settleThresholds(pixelScale: pixelScale)
        self.posEps = eps.pos
        self.velEps = eps.vel
    }

    /// Jumps immediately to `value` with zero velocity.
    public mutating func set(_ value: T) {
        self.target = value
        self.targetLanes = value.toLanes()
        self.layers = Array(repeating: nil, count: T.laneCount)
        self.curve = .instant
    }

    /// Animates to `target` from the exact position and velocity at `now`.
    public mutating func animateTo(_ newTarget: T, anim: Anim<T>, at now: Double) {
        let tg = newTarget.toLanes()
        let explicitVel: Float? = switch anim.velocityRule {
        case .inherit: nil
        case .zero: 0.0
        case let .uniform(u): u
        }
        if anim.initialVelocity == nil && explicitVel == nil && tg == targetLanes {
            return
        }
        self.curve = anim.curve
        for i in 0..<T.laneCount {
            let s = layers[i]?.sample(at: now) ?? (offset: 0, velocity: 0)
            let x = targetLanes[i] + s.offset
            let v = anim.initialVelocity?.lanes[i] ?? explicitVel ?? s.velocity
            restartLane(i, x: x, v: v, target: tg[i], curve: anim.curve, at: now)
        }
        self.target = T.fromLanes(targetLanes)
    }

    /// Retargets on the curve last used.
    public mutating func retarget(_ newTarget: T, at now: Double) {
        animateTo(newTarget, anim: Anim(curve: curve), at: now)
    }

    /// Gesture handoff: continue from the current position with `velocity` on `curve`.
    public mutating func release(velocity: T, target newTarget: T, curve: Curve, at now: Double) {
        let v = velocity.toLanes()
        let tg = newTarget.toLanes()
        self.curve = curve
        for i in 0..<T.laneCount {
            let s = layers[i]?.sample(at: now) ?? (offset: 0, velocity: 0)
            let x = targetLanes[i] + s.offset
            restartLane(i, x: x, v: v[i], target: tg[i], curve: curve, at: now)
        }
        self.target = T.fromLanes(targetLanes)
    }

    private mutating func restartLane(_ i: Int, x: Float, v: Float, target: Float, curve: Curve, at now: Double) {
        let eps = Eps(pos: posEps, vel: velEps)
        if case let .decay(d) = curve {
            let k = max(1e-3, d.rate)
            targetLanes[i] = x + v / k
            let layer = Layer.decay(rate: k, at: now, velocity: v, eps: eps)
            layers[i] = layer.kind == .rest ? nil : layer
        } else {
            targetLanes[i] = target
            let layer = Layer.start(curve: curve, at: now, offset: x - target, velocity: v, eps: eps)
            layers[i] = layer.kind == .rest ? nil : layer
        }
    }

    public func sample(at now: Double) -> T {
        var out = MotionLanes()
        for i in 0..<T.laneCount {
            let off = layers[i]?.sample(at: now).offset ?? 0
            out[i] = targetLanes[i] + off
        }
        return T.fromLanes(out)
    }

    public func velocity(at now: Double) -> T {
        var out = MotionLanes()
        for i in 0..<T.laneCount {
            out[i] = layers[i]?.sample(at: now).velocity ?? 0
        }
        return T.fromLanes(out)
    }

    public var settleTime: Double {
        var maxEnd = -Double.infinity
        for l in layers {
            if let l {
                maxEnd = max(maxEnd, l.t0 + Double(l.settleDuration))
            }
        }
        return maxEnd
    }

    public func isSettled(at now: Double) -> Bool {
        now >= settleTime
    }

    /// Shifts all active layers forward by `delta` seconds.
    public mutating func shift(_ delta: Double) {
        for i in layers.indices {
            if var l = layers[i] {
                l.t0 += delta
                layers[i] = l
            }
        }
    }
}
