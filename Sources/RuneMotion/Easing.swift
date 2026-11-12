import Foundation

/// CSS / WebKit cubic Bézier timing function `P0=(0,0), P1=(x1,y1), P2=(x2,y2), P3=(1,1)`.
public struct CubicBezier: Sendable, Hashable, Codable {
    public var x1: Float
    public var y1: Float
    public var x2: Float
    public var y2: Float

    public init(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
        self.x1 = x1.clamped(to: 0...1)
        self.y1 = y1
        self.x2 = x2.clamped(to: 0...1)
        self.y2 = y2
    }

    public static let EASE = CubicBezier(0.25, 0.1, 0.25, 1.0)
    public static let EASE_IN = CubicBezier(0.42, 0.0, 1.0, 1.0)
    public static let EASE_OUT = CubicBezier(0.0, 0.0, 0.58, 1.0)
    public static let EASE_IN_OUT = CubicBezier(0.42, 0.0, 0.58, 1.0)
    public static let ENTER = CubicBezier(0.2, 0.8, 0.2, 1.0)
    public static let EXIT = CubicBezier(0.4, 0.0, 1.0, 1.0)
    public static let OVERSHOOT = CubicBezier(0.34, 1.45, 0.64, 1.0)
    public static let DRAW_ON = CubicBezier(0.45, 0.0, 0.2, 1.0)

    @inlinable
    func sampleCurveX(_ t: Float) -> Float {
        let cx = 3.0 * x1
        let bx = 3.0 * (x2 - x1) - cx
        let ax = 1.0 - cx - bx
        return ((ax * t + bx) * t + cx) * t
    }

    @inlinable
    func sampleCurveY(_ t: Float) -> Float {
        let cy = 3.0 * y1
        let by = 3.0 * (y2 - y1) - cy
        let ay = 1.0 - cy - by
        return ((ay * t + by) * t + cy) * t
    }

    @inlinable
    func sampleCurveDerivativeX(_ t: Float) -> Float {
        let cx = 3.0 * x1
        let bx = 3.0 * (x2 - x1) - cx
        let ax = 1.0 - cx - bx
        return (3.0 * ax * t + 2.0 * bx) * t + cx
    }

    @inlinable
    func sampleCurveDerivativeY(_ t: Float) -> Float {
        let cy = 3.0 * y1
        let by = 3.0 * (y2 - y1) - cy
        let ay = 1.0 - cy - by
        return (3.0 * ay * t + 2.0 * by) * t + cy
    }

    /// Solve `x(t) = u` using Newton-Raphson (up to 8 iterations) with bisection fallback.
    public func solveCurveX(_ u: Float) -> Float {
        if u <= 0 { return 0 }
        if u >= 1 { return 1 }

        var t = u
        for _ in 0..<8 {
            let x = sampleCurveX(t) - u
            if abs(x) < 1e-6 {
                return t
            }
            let d = sampleCurveDerivativeX(t)
            if abs(d) < 1e-6 {
                break
            }
            t = (t - x / d).clamped(to: 0...1)
        }

        var t0: Float = 0
        var t1: Float = 1
        t = u
        for _ in 0..<40 {
            let x = sampleCurveX(t)
            if abs(x - u) < 1e-7 {
                return t
            }
            if u > x {
                t0 = t
            } else {
                t1 = t
            }
            t = (t0 + t1) * 0.5
        }
        return t
    }

    /// Evaluates `(y, dy/du)` at normalized time `u in [0, 1]`.
    public func evalWithSlope(_ u: Float) -> (Float, Float) {
        (sample(u), derivative(u))
    }

    /// Evaluates `y` at normalized time `u in [0, 1]`.
    public func sample(_ u: Float) -> Float {
        if u <= 0 { return 0 }
        if u >= 1 { return 1 }
        if x1 == y1 && x2 == y2 { return u }
        let t = solveCurveX(u)
        return sampleCurveY(t)
    }

    /// Evaluates `dy/du` at normalized time `u in [0, 1]`.
    public func derivative(_ u: Float) -> Float {
        let clamped = u.clamped(to: 0...1)
        if x1 == y1 && x2 == y2 { return 1 }
        let t = solveCurveX(clamped)
        let dx = sampleCurveDerivativeX(t)
        let dy = sampleCurveDerivativeY(t)
        if abs(dx) < 1e-5 {
            let eps: Float = 1e-3
            let u0 = max(0, clamped - eps)
            let u1 = min(1, clamped + eps)
            return (sample(u1) - sample(u0)) / max(1e-5, u1 - u0)
        }
        return dy / dx
    }
}

public enum StepPosition: Sendable, Hashable, Codable {
    case jumpStart
    case jumpEnd
    case jumpNone
    case jumpBoth
}

/// Parametric easing function over normalized progress `u in [0, 1]`.
public enum Easing: Sendable, Hashable {
    case linear
    case cubicBezier(CubicBezier)
    case steps(UInt16, StepPosition)
    /// Piecewise-linear lookup table `(u, value)` with `u` monotonically increasing in `[0, 1]`.
    case piecewise([Vec2])

    public static let ease = Easing.cubicBezier(.EASE)
    public static let easeIn = Easing.cubicBezier(.EASE_IN)
    public static let easeOut = Easing.cubicBezier(.EASE_OUT)
    public static let easeInOut = Easing.cubicBezier(.EASE_IN_OUT)
    public static let enter = Easing.cubicBezier(.ENTER)
    public static let exit = Easing.cubicBezier(.EXIT)
    public static let overshoot = Easing.cubicBezier(.OVERSHOOT)
    public static let drawOn = Easing.cubicBezier(.DRAW_ON)

    public func sample(_ u: Float) -> Float {
        switch self {
        case .linear:
            if u <= 0 { return 0 }
            if u >= 1 { return 1 }
            return u
        case .cubicBezier(let cb):
            if u <= 0 { return 0 }
            if u >= 1 { return 1 }
            return cb.sample(u)
        case .steps(let rawCount, let pos):
            if u >= 1 { return 1 }
            if u <= 0 && pos != .jumpStart && pos != .jumpBoth { return 0 }
            let n = Float(max(1, rawCount))
            let bucket = floorf(max(0, u) * n)
            switch pos {
            case .jumpEnd:
                return (bucket / n).clamped(to: 0...1)
            case .jumpStart:
                return ((bucket + 1) / n).clamped(to: 0...1)
            case .jumpNone:
                let denom = max(1, n - 1)
                return (bucket / denom).clamped(to: 0...1)
            case .jumpBoth:
                return ((bucket + 1) / (n + 1)).clamped(to: 0...1)
            }
        case .piecewise(let pts):
            guard !pts.isEmpty else { return u.clamped(to: 0...1) }
            if u <= pts[0].x { return pts[0].y }
            for i in 1..<pts.count {
                let p0 = pts[i - 1]
                let p1 = pts[i]
                if u <= p1.x {
                    let span = p1.x - p0.x
                    if span <= 1e-6 { return p1.y }
                    let f = (u - p0.x) / span
                    return p0.y + (p1.y - p0.y) * f
                }
            }
            return pts[pts.count - 1].y
        }
    }

    public func evalWithSlope(_ u: Float) -> (Float, Float) {
        (sample(u), derivative(u))
    }

    public func derivative(_ u: Float) -> Float {
        switch self {
        case .linear:
            return (u >= 0 && u <= 1) ? 1.0 : 0.0
        case .cubicBezier(let cb):
            return cb.derivative(u)
        case .steps:
            return 0.0
        case .piecewise(let pts):
            guard pts.count >= 2 else { return 1.0 }
            let clamped = u.clamped(to: 0...1)
            for i in 1..<pts.count {
                let p0 = pts[i - 1]
                let p1 = pts[i]
                if clamped <= p1.x || i == pts.count - 1 {
                    let span = p1.x - p0.x
                    return span > 1e-6 ? (p1.y - p0.y) / span : 0.0
                }
            }
            return 0.0
        }
    }
}
