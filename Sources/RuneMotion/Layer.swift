import Foundation

/// Closed-form single-lane offset response `value(t) = target + offset(t - t0)`.
///
/// Zero integration state: evaluation at any timestamp `t` depends purely on `tau = t - t0`,
/// making animations unconditionally frame-rate independent and deterministic.
public struct Layer: Sendable {
    public enum Kind: Sendable {
        case under(sigma: Float, omegaD: Float, a: Float, b: Float)
        case critical(omega: Float, a: Float, b: Float)
        case over(r1: Float, r2: Float, c1: Float, c2: Float)
        case decay(rate: Float, a: Float)
        case tween(duration: Float, a: Float, v0: Float, easing: Easing)
        case poly(duration: Float, c0: Float, c1: Float, c2: Float, c3: Float)
    }

    public var t0: Double
    public var settleDuration: Float
    public var kind: Kind

    public init(t0: Double, settleDuration: Float, kind: Kind) {
        self.t0 = t0
        self.settleDuration = settleDuration
        self.kind = kind
    }

    /// Evaluates `(offset, velocity)` at timestamp `t`.
    @inlinable
    public func sample(at t: Double) -> (offset: Float, velocity: Float) {
        let tau = Float(t - t0)
        if tau < 0 {
            return (initialOffset, 0)
        }
        if tau >= settleDuration {
            return (0, 0)
        }
        switch kind {
        case let .under(sigma, omegaD, a, b):
            let e = expf(-sigma * tau)
            let angle = omegaD * tau
            let cs = cosf(angle)
            let sn = sinf(angle)
            let off = e * (a * cs + b * sn)
            let vel = e * ((b * omegaD - sigma * a) * cs - (a * omegaD + sigma * b) * sn)
            return (off, vel)

        case let .critical(omega, a, b):
            let e = expf(-omega * tau)
            let lin = a + b * tau
            let off = lin * e
            let vel = (b - omega * lin) * e
            return (off, vel)

        case let .over(r1, r2, c1, c2):
            let e1 = expf(r1 * tau)
            let e2 = expf(r2 * tau)
            return (c1 * e1 + c2 * e2, c1 * r1 * e1 + c2 * r2 * e2)

        case let .decay(rate, a):
            let e = expf(-rate * tau)
            return (a * e, -rate * a * e)

        case let .tween(duration, a, v0, easing):
            if duration <= 1e-6 { return (0, 0) }
            let tClamped = min(tau, duration)
            let u = (tClamped / duration).clamped(to: 0...1)
            let w = 1.0 - u
            let g = tClamped * w * w
            let dg = w * (1.0 - 3.0 * u)
            let off = a * (1.0 - easing.sample(u)) + v0 * g
            let vel = -a * easing.derivative(u) / duration + v0 * dg
            return (off, vel)

        case let .poly(duration, c0, c1, c2, c3):
            if duration <= 1e-6 { return (0, 0) }
            let u = (tau / duration).clamped(to: 0...1)
            let off = ((c3 * u + c2) * u + c1) * u + c0
            let vel = ((3.0 * c3 * u + 2.0 * c2) * u + c1) / duration
            return (off, vel)
        }
    }

    @inlinable
    public var initialOffset: Float {
        switch kind {
        case let .under(_, _, a, _): return a
        case let .critical(_, a, _): return a
        case let .over(_, _, c1, c2): return c1 + c2
        case let .decay(_, a): return a
        case let .tween(_, a, _, _): return a
        case let .poly(_, c0, _, _, _): return c0
        }
    }

    @inlinable
    public func isSettled(at t: Double) -> Bool {
        Float(t - t0) >= settleDuration
    }

    /// Build a closed-form `Layer` for one scalar lane, returning `nil` if already settled.
    public static func make(
        curve: Curve,
        offset a: Float,
        velocity v0: Float,
        t0: Double,
        posEps: Float,
        velEps: Float
    ) -> Layer? {
        switch curve {
        case .instant:
            return nil

        case let .tween(duration, easing):
            if (abs(a) <= posEps && abs(v0) <= velEps) || duration <= 1e-5 {
                return nil
            }
            return Layer(t0: t0, settleDuration: duration, kind: .tween(duration: duration, a: a, v0: v0, easing: easing))

        case let .hermite(duration):
            if (abs(a) <= posEps && abs(v0) <= velEps) || duration <= 1e-5 {
                return nil
            }
            let vd = v0 * duration
            let c0 = a
            let c1 = vd
            let c2 = -3.0 * a - 2.0 * vd
            let c3 = 2.0 * a + vd
            return Layer(t0: t0, settleDuration: duration, kind: .poly(duration: duration, c0: c0, c1: c1, c2: c2, c3: c3))

        case let .decay(decay):
            let k = decay.rate
            if abs(a) <= posEps && abs(v0) <= velEps {
                return nil
            }
            let posBound = abs(a) > posEps ? logf(abs(a) / posEps) / k : 0
            let velBound = abs(k * a) > velEps ? logf(abs(k * a) / velEps) / k : 0
            let dur = max(posBound, velBound)
            if dur <= 1e-5 { return nil }
            return Layer(t0: t0, settleDuration: dur, kind: .decay(rate: k, a: a))

        case let .spring(spring):
            if abs(a) <= posEps && abs(v0) <= velEps {
                return nil
            }
            let omega = spring.omega
            let zeta = spring.dampingRatio
            let kind: Kind
            let upperBound: Float

            if abs(zeta - 1.0) < 1e-4 {
                let b = v0 + omega * a
                kind = .critical(omega: omega, a: a, b: b)
                // Envelope (|a| + |b|*tau)*exp(-omega*tau). Conservative bound via exp(-0.5*omega*tau).
                let peak = max(abs(a) + abs(b) / max(omega, 1e-3) * 2.0, posEps * 2.0)
                let vPeak = max(abs(b) + omega * peak, velEps * 2.0)
                let tPos = 2.0 * logf(peak / posEps) / omega
                let tVel = 2.0 * logf(vPeak / velEps) / omega
                upperBound = max(tPos, tVel, spring.duration)
            } else if zeta < 1.0 {
                let sigma = zeta * omega
                let omegaD = omega * sqrtf(max(1e-8, 1.0 - zeta * zeta))
                let b = (v0 + sigma * a) / omegaD
                kind = .under(sigma: sigma, omegaD: omegaD, a: a, b: b)
                let amp = hypotf(a, b)
                let vAmp = amp * (sigma + omegaD)
                let tPos = amp > posEps ? logf(amp / posEps) / sigma : 0
                let tVel = vAmp > velEps ? logf(vAmp / velEps) / sigma : 0
                upperBound = max(tPos, tVel)
            } else {
                let s = sqrtf(max(1e-8, zeta * zeta - 1.0))
                let r1 = -omega * (zeta - s)
                let r2 = -omega * (zeta + s)
                let c1 = (v0 - r2 * a) / (r1 - r2)
                let c2 = a - c1
                kind = .over(r1: r1, r2: r2, c1: c1, c2: c2)
                let slowRate = max(1e-4, -r1)
                let amp = abs(c1) + abs(c2)
                let vAmp = abs(c1 * r1) + abs(c2 * r2)
                let tPos = amp > posEps ? logf(amp / posEps) / slowRate : 0
                let tVel = vAmp > velEps ? logf(vAmp / velEps) / slowRate : 0
                upperBound = max(tPos, tVel)
            }

            let dur = refineSettleDuration(kind: kind, upperBound: min(upperBound, 120.0), posEps: posEps, velEps: velEps)
            if dur <= 1e-5 { return nil }
            return Layer(t0: t0, settleDuration: dur, kind: kind)
        }
    }

    /// Tightens the analytic envelope bound while guaranteeing the trajectory never exits
    /// `(posEps, velEps)` after `settleDuration`.
    private static func refineSettleDuration(
        kind: Kind,
        upperBound: Float,
        posEps: Float,
        velEps: Float
    ) -> Float {
        if upperBound <= 0 { return 0 }
        let probe = Layer(t0: 0, settleDuration: upperBound + 10.0, kind: kind)
        // Walk backward across 32 checkpoints to find the last instant outside tolerance,
        // then bisect between that instant and the next checkpoint.
        let steps = 32
        var low: Float = 0
        var high: Float = upperBound
        for i in stride(from: steps - 1, through: 0, by: -1) {
            let tau = upperBound * Float(i) / Float(steps)
            let (off, vel) = probe.sample(at: Double(tau))
            if abs(off) > posEps || abs(vel) > velEps {
                low = tau
                high = upperBound * Float(i + 1) / Float(steps)
                break
            }
            if i == 0 {
                high = upperBound / Float(steps)
            }
        }
        for _ in 0..<20 {
            let mid = (low + high) * 0.5
            // Check mid and two sub-points ahead in case of an underdamped zero crossing.
            let span = high - mid
            let s0 = probe.sample(at: Double(mid))
            let s1 = probe.sample(at: Double(mid + span * 0.35))
            let s2 = probe.sample(at: Double(mid + span * 0.7))
            let settled =
                abs(s0.offset) <= posEps && abs(s0.velocity) <= velEps &&
                abs(s1.offset) <= posEps && abs(s1.velocity) <= velEps &&
                abs(s2.offset) <= posEps && abs(s2.velocity) <= velEps
            if settled {
                high = mid
            } else {
                low = mid
            }
        }
        return high
    }
}
