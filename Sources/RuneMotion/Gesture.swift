import Foundation

/// iOS `UIScrollView` deceleration rates, per millisecond.
public enum DecelerationRate {
    public static let normal: Float = 0.998
    public static let fast: Float = 0.99
}

/// Direct manipulation helpers: fling projection, iOS rubber-banding, and least-squares velocity tracking.
public enum Gesture {
    /// Where a fling released at `x` with velocity `v` (units/s) comes to rest under UIKit's
    /// per-millisecond deceleration `rate`: `x + (v / 1000) * rate / (1 - rate)`.
    @inlinable
    public static func project(x: Float, velocity v: Float, rate: Float = DecelerationRate.normal) -> Float {
        x + (v / 1000.0) * rate / (1.0 - rate)
    }

    /// iOS rubber-band: how far content moves when dragged `overshoot` points past its edge
    /// in a viewport `dimension` points long (`c = 0.55`).
    @inlinable
    public static func rubberBand(overshoot: Float, dimension: Float) -> Float {
        rubberBandWith(overshoot: overshoot, dimension: dimension, c: 0.55)
    }

    /// `rubberBand` with an explicit constant `c`. Odd in `overshoot`.
    @inlinable
    public static func rubberBandWith(overshoot: Float, dimension: Float, c: Float) -> Float {
        if dimension <= 0 { return 0 }
        let x = abs(overshoot)
        let y = (1.0 - 1.0 / (x * c / dimension + 1.0)) * dimension
        return overshoot < 0 ? -y : y
    }

    /// Maps a raw drag position into `[min, max]`, rubber-banding whatever lies outside.
    @inlinable
    public static func rubberBandClamp(_ x: Float, min minVal: Float, max maxVal: Float, dimension: Float) -> Float {
        if x < minVal {
            return minVal + rubberBand(overshoot: x - minVal, dimension: dimension)
        } else if x > maxVal {
            return maxVal + rubberBand(overshoot: x - maxVal, dimension: dimension)
        } else {
            return x
        }
    }
}

/// Least-squares velocity over the last 100 ms of samples (at most 20), using platform
/// event timestamps. 40 ms without movement counts as stopped (Flutter `VelocityTracker`).
public struct VelocityTracker<T: Animatable>: Sendable {
    private static var maxSamples: Int { 20 }
    private static var horizon: Double { 0.100 }
    private static var stopGap: Double { 0.040 }

    private var t: [Double]
    private var x: [MotionLanes]
    private var len: Int = 0
    private var head: Int = 0

    public init() {
        self.t = Array(repeating: 0.0, count: Self.maxSamples)
        self.x = Array(repeating: .zero, count: Self.maxSamples)
    }

    /// Records a position at event time `timestamp` (seconds).
    public mutating func add(at timestamp: Double, value: T) {
        t[head] = timestamp
        x[head] = value.toLanes()
        head = (head + 1) % Self.maxSamples
        len = min(len + 1, Self.maxSamples)
    }

    public mutating func reset() {
        len = 0
    }

    /// Estimated velocity in units per second at the newest sample.
    public func velocity() -> T {
        var out = MotionLanes()
        guard len >= 2 else { return T.fromLanes(out) }

        let newest = (head + Self.maxSamples - 1) % Self.maxSamples
        let tNew = t[newest]
        var idx: [Int] = []
        idx.reserveCapacity(len)
        var prevT = tNew

        for k in 0..<len {
            let i = (newest + Self.maxSamples - k) % Self.maxSamples
            let ti = t[i]
            if tNew - ti > Self.horizon || prevT - ti > Self.stopGap {
                break
            }
            idx.append(i)
            prevT = ti
        }

        let n = idx.count
        guard n >= 2 else { return T.fromLanes(out) }

        let meanT = idx.reduce(0.0) { $0 + (t[$1] - tNew) } / Double(n)
        var variance = 0.0
        for i in idx {
            let dt = t[i] - tNew - meanT
            variance += dt * dt
        }
        guard variance > 1e-12 else { return T.fromLanes(out) }

        let lanesCount = min(T.laneCount, 16)
        for lane in 0..<lanesCount {
            let meanX = idx.reduce(0.0) { $0 + Double(x[$1][lane]) } / Double(n)
            var cov = 0.0
            for i in idx {
                cov += (t[i] - tNew - meanT) * (Double(x[i][lane]) - meanX)
            }
            out[lane] = Float(cov / variance)
        }
        return T.fromLanes(out)
    }
}
