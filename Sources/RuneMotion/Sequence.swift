import Foundation

/// A single pose at elapsed seconds along a `MotionSequence`.
public struct Beat: Sendable, Equatable {
    public var at: Double
    public var opacity: Float
    public var scale: Float
    public var easing: Easing

    public init(at: Double, opacity: Float = 1.0, scale: Float = 1.0, easing: Easing = .easeInOut) {
        self.at = at
        self.opacity = opacity
        self.scale = max(0, scale)
        self.easing = easing
    }

    public func opacity(_ value: Float) -> Beat {
        var copy = self
        copy.opacity = value
        return copy
    }

    public func scale(_ value: Float) -> Beat {
        var copy = self
        copy.scale = max(0, value)
        return copy
    }

    public func easing(_ value: Easing) -> Beat {
        var copy = self
        copy.easing = value
        return copy
    }
}

/// A one-shot pose sequence starting at `at == 0` and holding its final pose.
public struct MotionSequence: Sendable, Equatable {
    public var frames: [Beat]
    public var delay: Double

    public init(frames: [Beat], delay: Double = 0.0) {
        self.frames = frames.sorted { $0.at < $1.at }
        self.delay = max(0.0, delay)
    }

    public func delay(_ seconds: Double) -> MotionSequence {
        var copy = self
        copy.delay = max(0.0, seconds)
        return copy
    }

    public var duration: Double {
        frames.last?.at ?? 0.0
    }

    public func sample(elapsed: Double) -> Beat {
        guard !frames.isEmpty else { return Beat(at: elapsed) }
        if elapsed <= frames[0].at { return frames[0] }
        for i in 1..<frames.count {
            let a = frames[i - 1]
            let b = frames[i]
            if elapsed < b.at {
                let span = b.at - a.at
                if span <= 1e-9 { return b }
                let t = b.easing.sample(Float((elapsed - a.at) / span))
                return Beat(
                    at: elapsed,
                    opacity: a.opacity + (b.opacity - a.opacity) * t,
                    scale: max(0, a.scale + (b.scale - a.scale) * t),
                    easing: b.easing
                )
            }
        }
        return frames[frames.count - 1]
    }
}

/// A looping opacity curve sampled from wall clock time: `stops` are `(fraction 0...1, opacity)` pairs
/// interpolated linearly; this element is at `frac(t / period - phase)`. Every cycle with the same
/// period stays in phase. Reduced motion holds `still`. Use `Cycle.DISPLAY_RATE` for a continuous
/// sweep, or a positive `fps` for an intentionally stepped indicator (`cycle.rs`, #965).
public struct Cycle: Sendable, Equatable {
    /// Sample on the host's display frames, without arming an independent timer (`Cycle::DISPLAY_RATE`).
    public static let DISPLAY_RATE: Float = 0.0
    /// Swift-style alias of `DISPLAY_RATE`.
    public static var displayRate: Float { DISPLAY_RATE }


    public var period: Float
    public var phase: Float
    public var stops: [(fraction: Float, opacity: Float)]
    public var still: Float
    public var fps: Float

    public init(
        period: Float,
        phase: Float = 0.0,
        stops: [(fraction: Float, opacity: Float)],
        still: Float = 1.0,
        fps: Float = 30.0
    ) {
        self.period = max(period, 1e-4)
        self.phase = phase
        self.stops = stops
        self.still = still
        self.fps = fps
    }

    public static func == (lhs: Cycle, rhs: Cycle) -> Bool {
        lhs.period == rhs.period &&
            lhs.phase == rhs.phase &&
            lhs.still == rhs.still &&
            lhs.fps == rhs.fps &&
            lhs.stops.count == rhs.stops.count &&
            zip(lhs.stops, rhs.stops).allSatisfy { $0.fraction == $1.fraction && $0.opacity == $1.opacity }
    }

    /// A stepped cycle's timer interval (`Cycle::frame_interval`): `nil` at `DISPLAY_RATE`, so the
    /// cycle follows host frames, else `1 / max(fps, 1)` computed in `Float` as upstream does.
    public func frameInterval() -> Double? {
        guard fps != Self.DISPLAY_RATE else { return nil }
        return Double(Float(1.0) / max(fps, 1.0))
    }

    public func sample(at t: Double) -> Float {
        guard !stops.isEmpty else { return 1.0 }
        let raw = t / Double(period) - Double(phase)
        let x = Float(raw - floor(raw))
        for i in 0..<stops.count {
            if stops[i].fraction >= x {
                if i == 0 { return stops[0].opacity }
                let (x0, v0) = stops[i - 1]
                let (x1, v1) = stops[i]
                return v0 + (v1 - v0) * (x - x0) / max(x1 - x0, 1e-6)
            }
        }
        return stops.last?.opacity ?? 1.0
    }
}
