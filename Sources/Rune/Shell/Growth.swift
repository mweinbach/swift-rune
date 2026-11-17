import Foundation
import RuneMotion

/// Constants for timeline row growth (`rune::growth`).
public enum Growth {
    /// `timeline.growth`: 0.32 s, bounce 0 (`growth::GROWTH`).
    public static let spring = Spring(duration: 0.32, bounce: 0.0)
    /// The farthest a whole row glides in the spring's own duration (`growth::WHOLE_REACH`).
    public static let wholeReach: Float = 300.0
    /// Fixed integrator substep (`1 / 240` s; `growth::SUBSTEP`).
    public static let substep: Float = 1.0 / 240.0
    static let settle: Float = 1.0 / 16.0
    static let settleVelocity: Float = 1.5
    static let foldFeatherGrow: Float = 600.0

    /// Speed limits in points per second (`growth::caps`).
    public enum Caps {
        public static let start: Float = 1.875 * 60.0
        /// Ramp factor per second (`ln(1.6) * 60`).
        public static let rampPerSecond: Float = 28.2
        public static let max: Float = 11.5 * 60.0
        public static let maxLong: Float = 16.0 * 60.0
        public static let longDistance: Float = 240.0
        public static let carryingTail: Float = 7.5 * 60.0
        public static let near: Float = 36.0
        public static let maskGrow: Float = 5.0 * 60.0
        public static let maxDecel: Float = 1800.0
        public static let approach: Float = 14.0
        public static let approachMin: Float = 3.0
    }

    /// Streaming climb pace constants (`growth::pace`).
    public enum Pace {
        public static let window: Float = 0.5
        public static let trail: Float = 4.0
        public static let min: Float = 2.5
        public static let land: Float = 18.0
        public static let landRamp: Float = 0.15
        public static let landMin: Float = 8.0
        public static let max: Float = 40.0
        public static let accel: Float = 6000.0
    }
}

/// Fold spring and moving-edge feather depth (`growth::FoldGlide`).
public struct FoldGlide: Sendable, Hashable {
    public var spring: Spring
    public var feather: Float?

    public init(spring: Spring, feather: Float? = nil) {
        self.spring = spring
        self.feather = feather
    }
}

/// Height tracker matching `rune::growth::GrowTrack` (`growth.rs:232-573`).
public struct GrowTrack: Sendable, Equatable {
    enum Motion: Sendable, Equatable {
        case spring
        case fold(spring: Spring, feather: Float?, limit: Float, shut: Bool)
    }

    enum Pace: Sendable, Equatable {
        case rest
        case climbing(ended: Float)
    }

    enum Stage: Sendable, Equatable {
        case free
        case stopAt(Float)

        func aim(_ target: Float) -> Float {
            switch self {
            case .free: return target
            case .stopAt(let at): return at
            }
        }

        var isSet: Bool {
            if case .stopAt = self { return true }
            return false
        }
    }

    enum Lift: Sendable, Equatable {
        case none
        /// Only `GrowTrack.hideAbove` cuts a fold to `.riding`; a computed slope is `.easing` however it lands.
        case riding(pinned: Float)
        case easing(a: Float, b: Float)
    }

    public var h: Float
    public var v: Float
    public var target: Float
    public var age: Float
    internal var linearEdge = false
    public var mask: Float
    public var streaming: Bool
    public var whole: Bool
    public var duration: Float
    var span: Float
    var motion: Motion
    var stage: Stage
    var lift: Lift
    var restore: Float
    var give: Float?
    var pace: Pace
    var rate: Float

    public init(
        h: Float = 0,
        v: Float = 0,
        target: Float = 0,
        age: Float = 0,
        mask: Float = 0,
        streaming: Bool = false,
        whole: Bool = false,
        duration: Float = 0
    ) {
        self.h = h
        self.v = v
        self.target = target
        self.age = age
        self.mask = mask
        self.streaming = streaming
        self.whole = whole
        self.duration = duration
        self.span = 0
        self.motion = .spring
        self.stage = .free
        self.lift = .none
        self.restore = 0
        self.give = nil
        self.pace = .rest
        self.rate = 0
    }

    public static func settled(_ h: Float) -> GrowTrack {
        GrowTrack(h: h, v: 0, target: h)
    }

    public var moving: Bool {
        !atRest(remaining: target - h) || mask > 0.01
    }

    func atRest(remaining: Float) -> Bool {
        let (distance, speed): (Float, Float) = (duration > 0.0 || target == 0.0)
            ? (1.0 / 128.0, 0.5)
            : (Growth.settle, Growth.settleVelocity)
        return abs(remaining) <= distance && abs(v) <= speed
    }

    public mutating func retarget(_ newTarget: Float) {
        guard abs(newTarget - target) > 1e-4 else { return }
        let prevLift = currentLift()
        if !moving {
            age = 0.0
        }
        if streaming {
            rate += Swift.max(0.0, newTarget - target) / Growth.Pace.window
        }
        target = newTarget
        span = abs(target - h)
        stage = .free
        give = nil
        if case .fold(let spring, let feather, let limit, _) = motion {
            let newShut = target < h
            if target < h && h > limit {
                h = Swift.max(limit, target)
            } else if target > h && target > limit {
                stage = .stopAt(Swift.max(limit, h))
            }
            motion = .fold(spring: spring, feather: feather, limit: limit, shut: newShut)
            span = abs(target - h)
        }
        let d = target - h
        if prevLift > 1.0 / 64.0 && abs(d) > 1.0 / 64.0 {
            lift = .easing(a: prevLift * target / d, b: -prevLift / d)
        } else {
            lift = .none
        }
    }

    public func currentLift() -> Float {
        switch lift {
        case .none:
            return 0.0
        case .riding(let pinned):
            return Swift.max(0.0, pinned - h)
        case .easing(let a, let b):
            return Swift.max(0.0, a + b * h)
        }
    }

    public mutating func hideAbove(_ above: Float) -> Float {
        let pinned = currentLift() + h
        let cut = Swift.max(0.0, Swift.min(above, h - target))
        h -= cut
        span = abs(target - h)
        lift = .riding(pinned: pinned)
        return cut
    }

    public mutating func rideUp(_ rise: Float) {
        let from = currentLift()
        let curH = h
        let stageAt = Swift.min(target, curH + Swift.max(0.0, rise))
        let d = stageAt - curH
        let end = target - stageAt
        let b: Float = d > 1.0 / 64.0 ? (end - from) / d : 0.0
        lift = .easing(a: d > 1.0 / 64.0 ? (from - b * curH) : end, b: b)
        stage = .stopAt(stageAt)
        span = d
    }

    public var isShuttingFold: Bool {
        if case .fold = motion { return h > target + 0.01 }
        return false
    }

    public var isShut: Bool {
        if case .fold(_, _, _, let shut) = motion { return shut }
        return false
    }

    var isRiding: Bool {
        if case .riding = lift { return true }
        return false
    }

    var isLiftedAtAll: Bool {
        lift != .none
    }

    public var isPaced: Bool {
        if case .climbing = pace { return true }
        return false
    }

    public mutating func forgetFolded() {
        lift = .none
        if case .fold(let spring, let feather, let limit, _) = motion {
            motion = .fold(spring: spring, feather: feather, limit: limit, shut: false)
        }
    }

    public var glide: Spring? {
        if case .fold(let spring, _, _, _) = motion { return spring }
        return nil
    }

    public var feather: Float? {
        if case .fold(_, let feather, _, _) = motion { return feather }
        return nil
    }

    public var isStaged: Bool {
        stage.isSet
    }

    public func restarted(at newH: Float) -> GrowTrack {
        var copy = GrowTrack.settled(newH)
        copy.streaming = streaming
        copy.whole = whole
        if case .fold(let spring, let feather, let limit, _) = motion {
            copy.motion = .fold(spring: spring, feather: feather, limit: limit, shut: false)
        } else {
            copy.motion = motion
        }
        return copy
    }

    public mutating func setKind(streaming: Bool, whole: Bool, glide: (FoldGlide, Float)?) {
        self.streaming = streaming
        self.whole = whole
        if streaming && pace == .rest {
            pace = .climbing(ended: 0.0)
        }
        let filteredGlide = streaming ? nil : glide
        let shut = isShut
        if let (g, limit) = filteredGlide {
            motion = .fold(spring: g.spring, feather: g.feather, limit: limit, shut: shut)
        } else {
            stage = .free
            motion = .spring
        }
    }

    /// Advances one fixed `1/240` s substep (`GrowTrack::step`).
    public mutating func step(spring baseSpring: Spring, edge: StreamEdge, carryingTail: Bool) {
        let dt = Growth.substep
        let activeSpring = baseSpring.withDuration(
            Swift.max(baseSpring.duration, duration) * Swift.max(edge.duration, 0.05)
        )
        let aim = stage.aim(target)
        let rem = aim - h

        if stage.isSet && abs(rem) < 1.0 {
            restore += currentLift()
            lift = .none
            h = target
            v = 0.0
            stage = .free
        } else if atRest(remaining: rem) {
            h = target
            v = 0.0
        } else if case .climbing = pace, rem > 0.0 {
            climb(remaining: rem, carryingTail: carryingTail)
        } else if !streaming, case .fold(let own, _, _, _) = motion {
            let (x, nextV) = own.sample(from: h, velocity: v, target: aim, at: dt)
            let landed = (rem >= 0.0 && x >= aim) || (rem <= 0.0 && x <= aim)
            h = landed ? aim : x
            v = landed ? 0.0 : nextV
            age += dt
        } else if whole {
            let scaled = activeSpring.withDuration(
                activeSpring.duration * Float.maximum(sqrtf(span / Growth.wholeReach), 1.0)
            )
            let (x, nextV) = scaled.sample(from: h, velocity: v, target: target, at: dt)
            let landed = (rem >= 0.0 && x >= target) || (rem <= 0.0 && x <= target)
            h = landed ? target : x
            v = landed ? 0.0 : nextV
            age += dt
        } else {
            let (x, _) = activeSpring.sample(from: h, velocity: v, target: target, at: dt)
            var cap = abs(rem) > Growth.Caps.longDistance ? Growth.Caps.maxLong : Growth.Caps.max
            if carryingTail {
                cap = Swift.min(cap, Growth.Caps.carryingTail)
            }
            cap = Swift.min(cap, Growth.Caps.start * expf(Growth.Caps.rampPerSecond * age))
            if streaming && rem > 0.0 && rem < Growth.Caps.near {
                cap = Swift.min(cap, (0.085 * rem + 0.65 * Swift.min(rem / 4.0, 1.0)) * 60.0 * edge.catchUp)
            }
            let braking = sqrtf(2.0 * Growth.Caps.maxDecel * abs(rem))
            cap = Swift.max(cap, Swift.min(abs(v) - Growth.Caps.maxDecel * dt, braking))
            cap = Swift.min(cap, Growth.Caps.approach * abs(rem) + Growth.Caps.approachMin)

            var d = x - h
            let lim = cap * dt
            d = Swift.min(Swift.max(d, -lim), lim)
            let landed = (rem >= 0.0 && d >= rem) || (rem <= 0.0 && d <= rem)
            if landed {
                d = rem
            }
            h += d
            v = landed ? 0.0 : (d / dt)
            age += dt
        }

        let left = Swift.max(0.0, target - h)
        let aimMask: Float = left > 0.25
            ? Swift.min(edge.maskMax, Swift.max(edge.floor, 1.5 * left))
            : 0.0
        if !streaming, case .fold(_, let featherOpt, _, _) = motion {
            let foldLeft = abs(target - h)
            let riding: Bool
            if case .riding = lift { riding = true } else { riding = false }
            let foldAim: Float = (foldLeft > 0.25 && !riding)
                ? Swift.min(featherOpt ?? edge.maskMax, 1.5 * foldLeft)
                : 0.0
            if foldAim > mask {
                mask = Swift.min(mask + Growth.foldFeatherGrow * dt, foldAim)
            } else {
                mask = foldAim
            }
        } else if aimMask > mask {
            mask = Swift.min(mask + Growth.Caps.maskGrow * dt, aimMask)
        } else {
            mask = Swift.max(mask - edge.shrink * dt, aimMask)
        }

        rate *= expf(-dt / Growth.Pace.window)
        if !moving {
            if !isShut { lift = .none }
            if !streaming {
                pace = .rest
                rate = 0.0
            }
        }
    }

    private mutating func climb(remaining rem: Float, carryingTail: Bool) {
        let dt = Growth.substep
        guard case .climbing(var ended) = pace else { return }
        ended = streaming ? 0.0 : (ended + dt)
        pace = .climbing(ended: ended)
        let landing = Swift.min(ended / Growth.Pace.landRamp, 1.0)
        let minW = Growth.Pace.min + (Growth.Pace.land - Growth.Pace.min) * landing
        let w = Swift.min(Swift.max(rate / Growth.Pace.trail, minW), Growth.Pace.max)
        let rawA = w * w * rem - 2.0 * w * v
        let a = Swift.min(Swift.max(rawA, -Growth.Pace.accel), Growth.Pace.accel)
        var cap = rem > Growth.Caps.longDistance ? Growth.Caps.maxLong : Growth.Caps.max
        if carryingTail {
            cap = Swift.min(cap, Growth.Caps.carryingTail)
        }
        let upper = Swift.min(cap, sqrtf(2.0 * Growth.Pace.accel * rem))
        let nextV = Swift.min(Swift.max(v + a * dt, Growth.Pace.landMin * landing), upper)
        if nextV * dt >= rem {
            h = target
            v = 0.0
        } else {
            h += nextV * dt
            v = nextV
        }
        age += dt
    }
}
