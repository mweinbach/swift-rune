import Foundation

/// A single keyframe stop along a `KeyframeTrack`.
public struct Keyframe<T: Animatable>: Sendable, Equatable {
    public var offset: Float
    public var value: T
    public var easing: Easing

    public init(at offset: Float, value: T, easing: Easing = .easeInOut) {
        self.offset = offset.clamped(to: 0...1)
        self.value = value
        self.easing = easing
    }
}

/// Multi-stop keyframe track evaluated analytically over `duration` seconds.
public struct KeyframeTrack<T: Animatable>: Sendable, Equatable {
    public var duration: Float
    public var stops: [Keyframe<T>]

    public init(duration: Float, stops: [Keyframe<T>]) {
        self.duration = max(duration, 1e-4)
        self.stops = stops.sorted { $0.offset < $1.offset }
    }

    public func sample(elapsed: Float) -> T {
        guard !stops.isEmpty else { return T.zeroValue }
        if stops.count == 1 { return stops[0].value }
        let u = (elapsed / duration).clamped(to: 0...1)
        if u <= stops[0].offset { return stops[0].value }
        for i in 1..<stops.count {
            let s0 = stops[i - 1]
            let s1 = stops[i]
            if u <= s1.offset {
                let span = s1.offset - s0.offset
                if span <= 1e-6 { return s1.value }
                let local = (u - s0.offset) / span
                let f = s1.easing.sample(local)
                let a = s0.value.toLanes()
                let b = s1.value.toLanes()
                var out = MotionLanes()
                for lane in 0..<T.laneCount {
                    out[lane] = a[lane] + (b[lane] - a[lane]) * f
                }
                return T.fromLanes(out)
            }
        }
        return stops[stops.count - 1].value
    }
}

/// Origin for cascading `Stagger` delays.
public enum StaggerFrom: Sendable, Hashable {
    case start
    case end
    case center
    case edges
    case index(Int)
}

/// Stagger helper for cascading delays across list/grid items with an optional total cap.
public struct Stagger: Sendable, Hashable {
    public var step: Float
    public var maxDelay: Float
    public var fromEnd: Bool
    public var from: StaggerFrom

    public init(step: Float = 0.03, maxDelay: Float = 0.24, fromEnd: Bool = false) {
        self.step = max(0, step)
        self.maxDelay = max(0, maxDelay)
        self.fromEnd = fromEnd
        self.from = fromEnd ? .end : .start
    }

    public init(step: Float = 0.03, maxDelay: Float = 0.24, from: StaggerFrom) {
        self.step = max(0, step)
        self.maxDelay = max(0, maxDelay)
        self.fromEnd = (from == .end)
        self.from = from
    }

    /// Delay in seconds for item `index` out of `count`.
    public func delay(index: Int, count: Int) -> Float {
        guard count > 1 else { return 0 }
        let i = max(0, min(index, count - 1))
        let maxDist: Float
        let dist: Float
        switch from {
        case .start:
            dist = Float(i)
            maxDist = Float(count - 1)
        case .end:
            dist = Float(count - 1 - i)
            maxDist = Float(count - 1)
        case .center:
            let mid = Float(count - 1) * 0.5
            dist = abs(Float(i) - mid)
            maxDist = mid
        case .edges:
            let mid = Float(count - 1) * 0.5
            dist = mid - abs(Float(i) - mid)
            maxDist = mid
        case .index(let origin):
            let clamped = max(0, min(origin, count - 1))
            dist = Float(abs(i - clamped))
            maxDist = Float(max(clamped, count - 1 - clamped))
        }
        guard maxDist > 0 else { return 0 }
        let rawTotal = step * maxDist
        let effectiveStep = (maxDelay > 0 && rawTotal > maxDelay) ? (maxDelay / maxDist) : step
        return dist * effectiveStep
    }
}

/// Loops through a sequence of discrete phases, advancing when each phase's duration elapses.
public struct PhaseAnimator<Phase: Sendable & Equatable>: Sendable {
    public let phases: [Phase]
    public private(set) var index: Int = 0
    private var nextAdvanceAt: Double?

    public init(_ phases: [Phase]) {
        self.phases = phases
    }

    public var current: Phase? {
        guard !phases.isEmpty else { return nil }
        return phases[index % phases.count]
    }

    /// Advances the phase if `now >= nextAdvanceAt`, returning the current phase and whether it changed.
    @discardableResult
    public mutating func step(at now: Double, duration: (Phase) -> Double) -> (phase: Phase?, changed: Bool) {
        guard !phases.isEmpty else { return (nil, false) }
        if let due = nextAdvanceAt {
            if now >= due {
                index = (index + 1) % phases.count
                let cur = phases[index]
                nextAdvanceAt = now + max(1e-4, duration(cur))
                return (cur, true)
            }
            return (phases[index], false)
        } else {
            let cur = phases[index]
            nextAdvanceAt = now + max(1e-4, duration(cur))
            return (cur, true)
        }
    }
}
