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
    public var start: Float
    public var ease: Easing?

    public init(step: Float = 0.03, maxDelay: Float = 0.0, fromEnd: Bool = false) {
        self.step = max(0, step)
        self.maxDelay = max(0, maxDelay)
        self.fromEnd = fromEnd
        self.from = fromEnd ? .end : .start
        self.start = 0.0
        self.ease = nil
    }

    public init(step: Float = 0.03, maxDelay: Float = 0.0, from: StaggerFrom) {
        self.step = max(0, step)
        self.maxDelay = max(0, maxDelay)
        self.fromEnd = (from == .end)
        self.from = from
        self.start = 0.0
        self.ease = nil
    }

    public init(gap: Float) {
        self.step = max(0, gap)
        self.maxDelay = 0.0
        self.fromEnd = false
        self.from = .start
        self.start = 0.0
        self.ease = nil
    }

    public func from(_ from: StaggerFrom) -> Stagger {
        var copy = self
        copy.from = from
        copy.fromEnd = (from == .end)
        return copy
    }

    public func start(_ seconds: Float) -> Stagger {
        var copy = self
        copy.start = seconds
        return copy
    }

    public func ease(_ easing: Easing) -> Stagger {
        var copy = self
        copy.ease = easing
        return copy
    }

    /// Delay in seconds for item `index` out of `count`.
    public func delay(index: Int, count: Int) -> Float {
        let effectiveCount = max(1, count)
        let clampedOrigin: Float
        let dist: Float
        let maxDist: Float
        switch from {
        case .start:
            clampedOrigin = 0.0
            dist = abs(Float(index) - clampedOrigin)
            maxDist = Float(effectiveCount - 1)
        case .end:
            clampedOrigin = Float(effectiveCount - 1)
            dist = abs(Float(index) - clampedOrigin)
            maxDist = Float(effectiveCount - 1)
        case .center:
            clampedOrigin = Float(effectiveCount - 1) * 0.5
            dist = abs(Float(index) - clampedOrigin)
            maxDist = clampedOrigin
        case .edges:
            let mid = Float(effectiveCount - 1) * 0.5
            let i = max(0, min(index, effectiveCount - 1))
            dist = mid - abs(Float(i) - mid)
            maxDist = mid
        case .index(let origin):
            clampedOrigin = Float(max(0, min(origin, effectiveCount - 1)))
            dist = abs(Float(index) - clampedOrigin)
            maxDist = Float(max(Int(clampedOrigin), effectiveCount - 1 - Int(clampedOrigin)))
        }
        let shaped = (ease != nil && maxDist > 0) ? (ease!.sample(dist / maxDist) * maxDist) : dist
        let rawTotal = step * maxDist
        let effectiveStep = (maxDelay > 0 && rawTotal > maxDelay && maxDist > 0) ? (maxDelay / maxDist) : step
        return start + shaped * effectiveStep
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

/// One scheduled keyframe step matching upstream `rune_motion::Keyframe<T>`.
public enum KeyframeStep<T: Animatable>: Sendable, Equatable {
    /// Linear/eased interpolation to `value` over `duration` seconds.
    case linear(value: T, duration: Float, easing: Easing)
    /// Spring toward `value` for `duration` seconds, then hand exact `(x, v)` to the next step.
    case spring(value: T, duration: Float, spring: Spring)
    /// Catmull-Rom C¹ cubic spline through consecutive cubic steps.
    case cubic(value: T, duration: Float)
    /// Instant jump to `value`.
    case move(value: T)

    public var value: T {
        switch self {
        case .linear(let value, _, _),
             .spring(let value, _, _),
             .cubic(let value, _),
             .move(let value):
            return value
        }
    }

    public var duration: Float {
        switch self {
        case .linear(_, let duration, _),
             .spring(_, let duration, _),
             .cubic(_, let duration):
            return max(0, duration)
        case .move:
            return 0
        }
    }
}

/// SwiftUI `KeyframeAnimator`-style ordered keyframe sequence for one property.
public struct Keyframes<T: Animatable>: Sendable, Equatable {
    public private(set) var frames: [KeyframeStep<T>]
    public private(set) var delaySeconds: Float
    public private(set) var repeatCount: UInt32

    public init() {
        self.frames = []
        self.delaySeconds = 0
        self.repeatCount = 1
    }

    public func linear(_ value: T, duration: Float) -> Keyframes<T> {
        var copy = self
        copy.frames.append(.linear(value: value, duration: duration, easing: .linear))
        return copy
    }

    public func eased(_ value: T, duration: Float, easing: Easing) -> Keyframes<T> {
        var copy = self
        copy.frames.append(.linear(value: value, duration: duration, easing: easing))
        return copy
    }

    public func spring(_ value: T, _ spring: Spring) -> Keyframes<T> {
        var copy = self
        copy.frames.append(.spring(value: value, duration: spring.duration, spring: spring))
        return copy
    }

    public func springFor(_ value: T, duration: Float, spring: Spring) -> Keyframes<T> {
        var copy = self
        copy.frames.append(.spring(value: value, duration: duration, spring: spring))
        return copy
    }

    public func cubic(_ value: T, duration: Float) -> Keyframes<T> {
        var copy = self
        copy.frames.append(.cubic(value: value, duration: duration))
        return copy
    }

    public func moveTo(_ value: T) -> Keyframes<T> {
        var copy = self
        copy.frames.append(.move(value: value))
        return copy
    }

    public func delay(_ seconds: Float) -> Keyframes<T> {
        var copy = self
        copy.delaySeconds = seconds
        return copy
    }

    public func `repeat`(_ times: UInt32) -> Keyframes<T> {
        var copy = self
        copy.repeatCount = max(1, times)
        return copy
    }

    /// Total duration of one pass in seconds.
    public var duration: Float {
        frames.reduce(0) { $0 + $1.duration }
    }

    internal var lastValue: T? { frames.last?.value }
}

extension AnimationStore {
    /// Plays `keyframes` on a property from its current value (canceling any scheduled segments).
    /// Under Reduce Motion, spatial tracks cut cleanly and opacity/color/presence take the short fade.
    @discardableResult
    public mutating func playKeyframes<T: Animatable>(
        _ node: NodeId,
        _ prop: Prop<T>,
        _ kf: Keyframes<T>
    ) -> TrackId {
        guard let last = kf.lastValue else {
            return trackId(node, prop) ?? {
                preconditionFailure("empty keyframes on a new property")
            }()
        }
        let first = kf.frames[0].value
        let start = sample(node, prop) ?? first
        let initLanes = start.toLanes()
        let t = Int(ensure(node, prop.id, prop.propClass, initLanes: initLanes, count: T.laneCount))
        let n = T.laneCount
        if reducedMotion && prop.propClass.forReducedMotion(.spring(MotionTokens.SMOOTH)) != .spring(MotionTokens.SMOOTH) {
            let targetLanes = last.toLanes()
            _ = animateRaw(
                t,
                targets: targetLanes,
                count: n,
                curve: .spring(MotionTokens.SMOOTH),
                blend: .auto,
                delay: kf.delaySeconds,
                velocityRule: .inherit,
                token: 0,
                laneVelocities: nil
            )
            return idOf(t)
        }
        cancelTrackPending(t)
        var at = timeOf(t) + Double(max(0, kf.delaySeconds))
        var prev = initLanes
        let frames = kf.frames
        for _ in 0..<kf.repeatCount {
            for k in 0..<frames.count {
                let frame = frames[k]
                let v = frame.value.toLanes()
                let dur = frame.duration
                for i in 0..<n {
                    let curve: Curve
                    let vel: Float?
                    switch frame {
                    case let .linear(_, duration, easing):
                        curve = .tween(duration: duration, easing: easing)
                        vel = 0.0
                    case let .spring(_, _, spring):
                        curve = Curve.from(spring)
                        vel = nil
                    case .move:
                        curve = .instant
                        vel = nil
                    case let .cubic(_, duration):
                        let next: KeyframeStep<T>?
                        if k + 1 < frames.count {
                            next = frames[k + 1]
                        } else if kf.repeatCount > 1 {
                            next = frames.first
                        } else {
                            next = nil
                        }
                        let m: Float
                        if case let .cubic(nextVal, d2)? = next {
                            let nv = nextVal.toLanes()
                            m = (nv[i] - prev[i]) / max(duration + d2, 1e-6)
                        } else {
                            m = 0.0
                        }
                        curve = .hermite(duration: duration, endVelocity: m)
                        vel = nil
                    }
                    schedule(t, lane: i, at: at, target: v[i], curve: curve, blend: .merge, velocity: vel)
                }
                at += Double(dur)
                prev = v
            }
        }
        commitScheduled(t, logicalAt: at, token: 0)
        return idOf(t)
    }
}
