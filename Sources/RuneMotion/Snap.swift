import Foundation

/// Two-edge 1/64 device-pixel snapping (`snap.rs`).
///
/// Snap both edges, then derive the size. Snapping origin and size separately makes a stationary
/// edge flicker by one quantum as the other edge moves.
public enum Snap {
    /// Rounds `value` points to the 1/64 device-pixel grid at `scale` device pixels per point.
    @inlinable
    public static func grid(_ value: Float, scale: Float) -> Float {
        let q = 64.0 * max(scale, 0.001)
        return (value * q).rounded() / q
    }

    /// Snaps a rectangle's four edges to the 1/64 px grid and derives its size from them.
    @inlinable
    public static func rect(_ r: MotionRect, scale: Float) -> MotionRect {
        edges(left: r.left, top: r.top, right: r.right, bottom: r.bottom, scale: scale)
    }

    /// Snaps edges given directly (`left`, `top`, `right`, `bottom`).
    @inlinable
    public static func edges(
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        scale: Float
    ) -> MotionRect {
        MotionRect(
            left: grid(left, scale: scale),
            top: grid(top, scale: scale),
            right: grid(right, scale: scale),
            bottom: grid(bottom, scale: scale)
        )
    }
}

/// A magnetic snap detent along a 1D axis (e.g. sheet heights, carousel pages, scrubber ticks).
public struct SnapDetent: Sendable, Hashable, Codable {
    public var id: String
    public var position: Float
    /// Optional magnetic capture radius; `0` means always snap only on release.
    public var radius: Float

    public init(id: String, position: Float, radius: Float = 0) {
        self.id = id
        self.position = position
        self.radius = max(0, radius)
    }
}

/// Collection of `SnapDetent`s supporting nearest-detent, velocity-projected target selection,
/// magnetic attraction, and bounds rubber-banding.
public struct SnapPoints: Sendable, Equatable {
    public var detents: [SnapDetent]

    public init(_ detents: [SnapDetent]) {
        self.detents = detents.sorted { $0.position < $1.position }
    }

    public init(positions: [Float]) {
        self.detents = positions.sorted().enumerated().map { idx, pos in
            SnapDetent(id: "detent-\(idx)", position: pos)
        }
    }

    public var bounds: ClosedRange<Float>? {
        guard let first = detents.first, let last = detents.last else { return nil }
        return first.position...last.position
    }

    /// Returns the detent closest to `value`.
    public func nearest(to value: Float) -> SnapDetent? {
        detents.min(by: { abs($0.position - value) < abs($1.position - value) })
    }

    /// Projects a fling from `position` with `velocity` (units/s) using `Gesture.project`
    /// and selects the best matching detent.
    public func projectTarget(
        from position: Float,
        velocity: Float,
        rate: Float = DecelerationRate.normal
    ) -> SnapDetent? {
        guard !detents.isEmpty else { return nil }
        let projected = Gesture.project(x: position, velocity: velocity, rate: rate)
        return nearest(to: projected)
    }

    /// Applies rubber-banding outside `[min, max]` detent bounds using `Gesture.rubberBandWith`.
    public func rubberBandClamp(_ value: Float, dimension: Float, c: Float = 0.55) -> Float {
        guard let range = bounds else { return value }
        if value < range.lowerBound {
            return range.lowerBound + Gesture.rubberBandWith(overshoot: value - range.lowerBound, dimension: dimension, c: c)
        }
        if value > range.upperBound {
            return range.upperBound + Gesture.rubberBandWith(overshoot: value - range.upperBound, dimension: dimension, c: c)
        }
        return value
    }

    /// Gently pulls `value` toward any detent within its `radius` (or `defaultRadius`).
    public func magneticPull(_ value: Float, defaultRadius: Float = 0, strength: Float = 0.5) -> Float {
        let clampedStrength = strength.clamped(to: 0...1)
        for detent in detents {
            let r = detent.radius > 0 ? detent.radius : defaultRadius
            guard r > 0 else { continue }
            let delta = value - detent.position
            if abs(delta) < r {
                return detent.position + delta * (1.0 - clampedStrength)
            }
        }
        return value
    }
}

/// Deterministic IEEE-754 `exp`, `sin`, and `cos` (`math.rs`) for cross-host bit-identical traces.
public enum MotionMath {
    @usableFromInline static let log2E: Float = 1.4426950408889634
    @usableFromInline static let ln2Hi: Float = 6.931_457_5e-1
    @usableFromInline static let ln2Lo: Float = 1.428_606_8e-6
    @usableFromInline static let frac2Pi: Float = 0.6366197723675814

    @inlinable
    static func fma(_ a: Float, _ b: Float, _ c: Float) -> Float {
        c.addingProduct(a, b)
    }

    /// `e^x` with relative error under 3e-7 for `x` in `[-87, 88]`.
    @inlinable
    public static func exp(_ x: Float) -> Float {
        if x < -87.0 { return 0.0 }
        if x > 88.0 { return .infinity }
        let xc = min(max(x, -87.0), 88.0)
        let k = (xc * log2E).rounded()
        let r = fma(-k, ln2Lo, fma(-k, ln2Hi, xc))
        let r2 = r * r
        let a = 1.0 + r
        let b = fma(r, 1.0 / 6.0, 0.5)
        let c = fma(r, 1.0 / 120.0, 1.0 / 24.0)
        let p = fma(r2, fma(r2, fma(r2, 1.0 / 720.0, c), b), a)
        let bits = UInt32(bitPattern: Int32(k) + 127) << 23
        return p * Float(bitPattern: bits)
    }

    /// `(sin(x), cos(x))` with absolute error under 3e-7 for `|x| < 1e5`.
    @inlinable
    public static func sinCos(_ x: Float) -> (sin: Float, cos: Float) {
        let hi: Float = 1.570_796_4
        let lo: Float = -4.371_139e-8
        let qf = (x * frac2Pi).rounded()
        let q = UInt32(bitPattern: Int32(qf))
        let r = fma(-qf, lo, fma(-qf, hi, x))
        let z = r * r
        let z2 = z * z
        let sHi = fma(z, 1.0 / 120.0, -1.0 / 6.0)
        let sLo = fma(z, 1.0 / 362_880.0, -1.0 / 5040.0)
        let s = fma(r * z, fma(z2, sLo, sHi), r)
        let cHi = fma(z, 1.0 / 24.0, -0.5)
        let cMid = fma(z, -1.0 / 3_628_800.0, 1.0 / 40_320.0)
        let cLo = fma(z, cMid, -1.0 / 720.0)
        let c = fma(z, fma(z2, cLo, cHi), 1.0)
        let swap = (q & 1) != 0
        let sb = swap ? c : s
        let cb = swap ? s : c
        let sinSign = (q & 2) << 30
        let cosSign = ((q &+ 1) & 2) << 30
        return (
            Float(bitPattern: sb.bitPattern ^ sinSign),
            Float(bitPattern: cb.bitPattern ^ cosSign)
        )
    }
}

/// Items a frame reports (settle events, unmounted nodes), kept readable until the next frame (`carry.rs`).
public struct Carry<T: Sendable>: Sendable {
    private var storage: [T] = []
    private var reported: Int = 0

    public init() {}

    /// Starts a frame: drops what the last one reported, keeps what came after it.
    public mutating func begin() {
        if reported > 0 {
            storage.removeFirst(min(reported, storage.count))
            reported = 0
        }
    }

    /// Ends a frame: everything so far is what it reports.
    public mutating func end() {
        reported = storage.count
    }

    public mutating func push(_ item: T) {
        storage.append(item)
    }

    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        storage.reserveCapacity(minimumCapacity)
    }

    public mutating func removeAll(keepingCapacity: Bool = true) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        reported = 0
    }

    /// What the last frame reported, and anything pushed since.
    public var items: [T] {
        storage
    }
}
