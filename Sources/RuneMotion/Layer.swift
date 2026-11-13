import Foundation

/// Settle thresholds: below these the residual offset and speed are invisible, so the lane can
/// snap to `(target, 0)` and go dormant.
public struct Eps: Sendable, Equatable {
    public var pos: Float
    public var vel: Float

    @inlinable
    public init(pos: Float, vel: Float) {
        self.pos = pos
        self.vel = vel
    }
}

/// Closed-form single-lane offset response `value(t) = target + offset(t - t0)`.
///
/// Zero integration state: evaluation at any timestamp `t` depends purely on `tau = t - t0`,
/// making animations unconditionally frame-rate independent and deterministic.
public struct Layer: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case rest
        case under(sigma: Float, omegaD: Float, a: Float, b: Float, c: Float, d: Float)
        case critical(omega: Float, a: Float, b: Float, c: Float, d: Float)
        case over(r1: Float, r2: Float, c1: Float, c2: Float)
        case decay(rate: Float, a: Float)
        case tween(duration: Float, a: Float, v0: Float, easing: Easing)
        case poly(duration: Float, c0: Float, c1: Float, c2: Float, c3: Float)
    }

    public static let maxSettle: Double = 120.0

    public static let rest = Layer(t0: 0.0, end: -.infinity, kind: .rest)

    public var t0: Double
    /// Absolute time after which the offset and its velocity are below `Eps` (or `-.infinity` for `.rest`).
    public var end: Double
    public var kind: Kind

    /// Elapsed settle duration relative to `t0`.
    @inlinable
    public var settleDuration: Float {
        get {
            if case .rest = kind { return 0 }
            if !end.isFinite { return 0 }
            return max(0, Float(end - t0))
        }
        set {
            end = t0 + Double(newValue)
        }
    }

    public init(t0: Double, end: Double, kind: Kind) {
        self.t0 = t0
        self.end = end
        self.kind = kind
    }

    public init(t0: Double, settleDuration: Float, kind: Kind) {
        self.t0 = t0
        self.end = t0 + Double(settleDuration)
        self.kind = kind
    }

    /// Evaluates `(offset, velocity)` at timestamp `now`.
    /// Physics layers return `(0, 0)` once `now >= end`; timed layers (`.tween`, `.poly`) clamp
    /// to their end state so keyframe end velocity is handed to the next segment.
    @inlinable
    public func sample(at now: Double) -> (offset: Float, velocity: Float) {
        switch kind {
        case .rest:
            return (0, 0)

        case let .under(sigma, omegaD, a, b, c, d):
            if now >= end { return (0, 0) }
            let tau = Float(max(0.0, now - t0))
            let e = MotionMath.exp(-sigma * tau)
            let (sn, cs) = MotionMath.sinCos(omegaD * tau)
            return (e * (a * cs + b * sn), e * (c * cs + d * sn))

        case let .critical(omega, a, b, c, d):
            if now >= end { return (0, 0) }
            let tau = Float(max(0.0, now - t0))
            let e = MotionMath.exp(-omega * tau)
            return ((a + b * tau) * e, (c + d * tau) * e)

        case let .over(r1, r2, c1, c2):
            if now >= end { return (0, 0) }
            let tau = Float(max(0.0, now - t0))
            let e1 = MotionMath.exp(r1 * tau)
            let e2 = MotionMath.exp(r2 * tau)
            return (c1 * e1 + c2 * e2, c1 * r1 * e1 + c2 * r2 * e2)

        case let .decay(rate, a):
            if now >= end { return (0, 0) }
            let tau = Float(max(0.0, now - t0))
            let e = MotionMath.exp(-rate * tau)
            return (a * e, -rate * a * e)

        case let .tween(duration, a, v0, easing):
            if duration <= 0 { return (0, 0) }
            let tau = min(Float(max(0.0, now - t0)), duration)
            let u = min(tau / duration, 1.0)
            let w = 1.0 - u
            let g = tau * w * w
            let dg = w * (1.0 - 3.0 * u)
            let off = a * (1.0 - easing.sample(u)) + v0 * g
            let vel = -a * easing.derivative(u) / duration + v0 * dg
            return (off, vel)

        case let .poly(duration, c0, c1, c2, c3):
            if duration <= 0 { return (0, 0) }
            let tau = min(Float(max(0.0, now - t0)), duration)
            let off = c0 + tau * (c1 + tau * (c2 + tau * c3))
            let vel = c1 + tau * (2.0 * c2 + tau * 3.0 * c3)
            return (off, vel)
        }
    }

    @inlinable
    public var initialOffset: Float {
        switch kind {
        case .rest: return 0
        case let .under(_, _, a, _, _, _): return a
        case let .critical(_, a, _, _, _): return a
        case let .over(_, _, c1, c2): return c1 + c2
        case let .decay(_, a): return a
        case let .tween(_, a, _, _): return a
        case let .poly(_, c0, _, _, _): return c0
        }
    }

    @inlinable
    public func isSettled(at t: Double) -> Bool {
        if case .rest = kind { return true }
        return t >= end
    }

    /// Upstream-parity layer constructor returning `Layer.rest` when immediately idle.
    public static func start(
        curve: Curve,
        at t0: Double,
        offset: Float,
        velocity: Float,
        eps: Eps
    ) -> Layer {
        switch curve {
        case .instant:
            return .rest
        case .spring(let s):
            return spring(s, at: t0, offset: offset, v0: velocity, eps: eps)
        case let .tween(duration, easing):
            return tween(duration: duration, easing: easing, at: t0, offset: offset, velocity: velocity)
        case let .decay(d):
            return decay(rate: d.rate, at: t0, velocity: velocity, eps: eps)
        case let .hermite(duration, endVelocity):
            return hermite(duration: duration, at: t0, offset: offset, v0: velocity, v1: endVelocity)
        }
    }

    public static func spring(
        _ s: Spring,
        at t0: Double,
        offset: Float,
        v0: Float,
        eps: Eps
    ) -> Layer {
        var layer = springUnbounded(s, at: t0, offset: offset, v0: v0)
        if layer.kind != .rest {
            layer.end = t0 + layer.settleAfter(eps: eps)
        }
        return layer
    }

    /// A spring layer with `end = .infinity` for one-off sampling where no settle bound is needed.
    public static func springUnbounded(_ s: Spring, at t0: Double, offset: Float, v0: Float) -> Layer {
        if offset == 0 && v0 == 0 {
            return .rest
        }
        let omega = s.omega
        let zeta = s.dampingRatio
        let a = offset
        let kind: Kind
        if abs(zeta - 1.0) < 1e-4 {
            let b = v0 + omega * a
            kind = .critical(omega: omega, a: a, b: b, c: b - omega * a, d: -omega * b)
        } else if zeta < 1.0 {
            let sigma = zeta * omega
            let wd = omega * sqrtf(max(1e-8, 1.0 - zeta * zeta))
            let b = (v0 + sigma * a) / wd
            kind = .under(
                sigma: sigma,
                omegaD: wd,
                a: a,
                b: b,
                c: b * wd - sigma * a,
                d: -a * wd - sigma * b
            )
        } else {
            let root = sqrtf(max(1e-8, zeta * zeta - 1.0))
            let r1 = -omega * (zeta - root)
            let r2 = -omega * (zeta + root)
            let c1 = (v0 - r2 * a) / (r1 - r2)
            kind = .over(r1: r1, r2: r2, c1: c1, c2: a - c1)
        }
        return Layer(t0: t0, end: .infinity, kind: kind)
    }

    public static func tween(
        duration: Float,
        easing: Easing,
        at t0: Double,
        offset: Float,
        velocity: Float
    ) -> Layer {
        if duration <= 0 || (offset == 0 && velocity == 0) {
            return .rest
        }
        return Layer(
            t0: t0,
            end: t0 + Double(duration),
            kind: .tween(duration: duration, a: offset, v0: velocity, easing: easing)
        )
    }

    /// Exponential decay with rate `k` (1/s). The lane's target is the projected rest point
    /// `x + v/k`, and the offset starts at `-v/k`.
    public static func decay(rate k: Float, at t0: Double, velocity v0: Float, eps: Eps) -> Layer {
        if v0 == 0 {
            return .rest
        }
        let a = -v0 / k
        let tp = log(Double(abs(a) / eps.pos))
        let tv = log(Double(abs(v0) / eps.vel))
        let dur = min(max(max(tp, tv) / Double(k), 0.0), maxSettle)
        return Layer(t0: t0, end: t0 + dur, kind: .decay(rate: k, a: a))
    }

    /// Cubic Hermite from `(offset, v0)` to `(0, v1)` over `duration`: C1 keyframe splines.
    public static func hermite(
        duration d: Float,
        at t0: Double,
        offset a: Float,
        v0 b: Float,
        v1: Float
    ) -> Layer {
        if d <= 0 {
            return .rest
        }
        let cc = (-3.0 * a - (2.0 * b + v1) * d) / (d * d)
        let dd = (2.0 * a + (v1 + b) * d) / (d * d * d)
        return Layer(t0: t0, end: t0 + Double(d), kind: .poly(duration: d, c0: a, c1: b, c2: cc, c3: dd))
    }

    /// Compatibility constructor used by legacy `Layer.make` callers/tests.
    public static func make(
        curve: Curve,
        offset a: Float,
        velocity v0: Float,
        t0: Double,
        posEps: Float,
        velEps: Float
    ) -> Layer? {
        let eps = Eps(pos: posEps, vel: velEps)
        switch curve {
        case .instant:
            return nil
        case let .tween(duration, easing):
            if (abs(a) <= posEps && abs(v0) <= velEps) || duration <= 1e-5 { return nil }
            let l = tween(duration: duration, easing: easing, at: t0, offset: a, velocity: v0)
            return l.kind == .rest ? nil : l
        case let .hermite(duration, endVelocity):
            if (abs(a) <= posEps && abs(v0) <= velEps && abs(endVelocity) <= velEps) || duration <= 1e-5 { return nil }
            let l = hermite(duration: duration, at: t0, offset: a, v0: v0, v1: endVelocity)
            return l.kind == .rest ? nil : l
        case let .decay(d):
            if abs(a) <= posEps && abs(v0) <= velEps { return nil }
            let k = d.rate
            let tp = abs(a) > posEps ? log(Double(abs(a) / posEps)) : 0
            let tv = abs(k * a) > velEps ? log(Double(abs(k * a) / velEps)) : 0
            let dur = min(max(max(tp, tv) / Double(k), 0.0), maxSettle)
            if dur <= 1e-5 { return nil }
            return Layer(t0: t0, end: t0 + dur, kind: .decay(rate: k, a: a))
        case let .spring(s):
            if abs(a) <= posEps && abs(v0) <= velEps { return nil }
            let l = spring(s, at: t0, offset: a, v0: v0, eps: eps)
            if l.kind == .rest || l.end - t0 <= 1e-5 { return nil }
            return l
        }
    }

    private func settleAfter(eps: Eps) -> Double {
        let ep = Double(eps.pos)
        let ev = Double(eps.vel)
        let t: Double
        switch kind {
        case let .under(sigma, _, a, b, c, d):
            let s = Double(sigma)
            let tp = log(hypot(Double(a), Double(b)) / ep)
            let tv = log(hypot(Double(c), Double(d)) / ev)
            t = max(tp, tv) / s
        case let .critical(omega, a, b, c, d):
            let w = Double(omega)
            let da = Double(a), db = Double(b), dc = Double(c), dd = Double(d)
            func tail(_ ka: Double, _ kb: Double, _ tau: Double) -> Double {
                func at(_ x: Double) -> Double { abs((ka + kb * x) * Foundation.exp(-w * x)) }
                let ext = kb == 0 ? -1.0 : (1.0 / w - ka / kb)
                return max(at(tau), ext > tau ? at(ext) : 0.0)
            }
            t = Self.bisect(scale: 1.0 / w) { tau in
                tail(da, db, tau) <= ep && tail(dc, dd, tau) <= ev
            }
        case let .over(r1, r2, c1, c2):
            let dr1 = Double(r1), dr2 = Double(r2), dc1 = Double(c1), dc2 = Double(c2)
            t = Self.bisect(scale: -1.0 / dr1) { tau in
                let e1 = Foundation.exp(dr1 * tau)
                let e2 = Foundation.exp(dr2 * tau)
                let env = abs(dc1) * e1 + abs(dc2) * e2
                let envv = abs(dc1 * dr1) * e1 + abs(dc2 * dr2) * e2
                return env <= ep && envv <= ev
            }
        default:
            t = 0.0
        }
        return t.isFinite ? min(max(t, 0.0), Self.maxSettle) : Self.maxSettle
    }

    private static func bisect(scale: Double, ok: (Double) -> Bool) -> Double {
        if ok(0.0) { return 0.0 }
        var hi = max(scale, 1e-3)
        while !ok(hi) {
            hi *= 2.0
            if hi > maxSettle { return maxSettle }
        }
        var lo = 0.0
        for _ in 0..<40 {
            let mid = 0.5 * (lo + hi)
            if ok(mid) { hi = mid } else { lo = mid }
        }
        return hi
    }
}
