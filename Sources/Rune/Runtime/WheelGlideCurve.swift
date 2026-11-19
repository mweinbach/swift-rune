import Foundation
import RuneMotion

/// Notched mouse wheel easing curve matching Chromium's `ScrollOffsetAnimationCurve`
/// (`cc/animation/scroll_offset_animation_curve.cc`, `kInverseDelta`) and upstream
/// `crates/rune/src/runtime/scroll/wheel.rs` (`#1150`).
///
/// Each notch updates the target and eases over 200 ms (up to 120 device px) down to
/// 100 ms (480+ device px) on `cubic-bezier(0.42, 0, 0.58, 1)`, preserving velocity
/// across stacked notches and snapping rendered offsets to whole device pixels.
public struct WheelCurve: Sendable, Equatable {
    public static let longestFrames: Double = 12.0
    public static let shortestFrames: Double = 6.0
    public static let rampStartDevicePx: Double = 120.0
    public static let rampEndDevicePx: Double = 480.0
    public static let epsilonDevicePx: Double = 0.01

    public var from: Double
    public var to: Double
    public var t: Double
    public var duration: Double
    public var ease: CubicBezier
    /// True from creation until the first non-catch-up frame steps it.
    public var fresh: Bool
    /// The last offset this curve wrote to the viewport (for `follow(_:)` adjustments).
    public var appliedOffset: Double
    /// True when a notch aimed at the viewport's end (`stickBottom` follows growth).
    public var toEnd: Bool

    public init(from: Double, to: Double, scale: Double) {
        self.from = from
        self.to = to
        self.t = 0.0
        self.duration = Self.duration(delta: to - from, scale: scale)
        self.ease = CubicBezier(0.42, 0.0, 0.58, 1.0)
        self.fresh = true
        self.appliedOffset = from
        self.toEnd = false
    }

    private init(
        from: Double,
        to: Double,
        t: Double,
        duration: Double,
        ease: CubicBezier,
        fresh: Bool,
        appliedOffset: Double,
        toEnd: Bool
    ) {
        self.from = from
        self.to = to
        self.t = t
        self.duration = duration
        self.ease = ease
        self.fresh = fresh
        self.appliedOffset = appliedOffset
        self.toEnd = toEnd
    }

    /// Finished resting curve at `at` (`WheelCurve::still`).
    public static func still(at offset: Double) -> WheelCurve {
        WheelCurve(
            from: offset,
            to: offset,
            t: 0.0,
            duration: 0.0,
            ease: CubicBezier(0.42, 0.0, 0.58, 1.0),
            fresh: false,
            appliedOffset: offset,
            toEnd: false
        )
    }

    /// Shifts start and target by any external offset change since `appliedOffset` (`ApplyAdjustment`).
    public mutating func follow(offset: Double) {
        let moved = offset - appliedOffset
        if moved != 0.0 {
            from += moved
            to += moved
            appliedOffset = offset
        }
    }

    /// Records the offset this curve just applied to the viewport.
    public mutating func applied(_ offset: Double) {
        appliedOffset = offset
    }

    /// Destination offset in logical points.
    public var target: Double { to }

    /// Marks whether the current target was clamped to the viewport's end.
    public mutating func aimedAtEnd(_ atEnd: Bool) {
        toEnd = atEnd
    }

    /// Current eased offset in logical points.
    public var value: Double {
        if duration <= 0.0 || t >= duration { return to }
        let (y, _) = ease.evalWithSlope(Float(t / duration))
        return from + (to - from) * Double(y)
    }

    /// Current velocity in points per second.
    public var velocity: Double {
        if duration <= 0.0 || t >= duration { return 0.0 }
        let (_, slope) = ease.evalWithSlope(Float(t / duration))
        return Double(slope) * (to - from) / duration
    }

    /// True once the curve has reached its target.
    public var isDone: Bool {
        t >= duration
    }

    /// Advances the curve by `dt` seconds. Infinite `dt` lands immediately.
    public mutating func advance(dt: Double, catchUp: Bool = false) {
        if dt.isInfinite {
            fresh = false
            t = max(duration, 0.0)
            return
        }
        if dt == 0.0 { return }
        if fresh {
            if !catchUp { fresh = false }
            return
        }
        t = min(t + max(0.0, dt), max(duration, 0.0))
    }

    /// Retargets to `newTarget` preserving current position and velocity (`UpdateTarget`).
    /// Returns `false` if already at `newTarget` with nothing left to animate.
    @discardableResult
    public mutating func retarget(to newTarget: Double, scale: Double) -> Bool {
        let savedApplied = appliedOffset
        let moving = sendTo(newTarget, scale: scale)
        appliedOffset = savedApplied
        return moving
    }

    private mutating func sendTo(_ newTarget: Double, scale: Double) -> Bool {
        if abs((to - newTarget) * scale) < Self.epsilonDevicePx {
            to = newTarget
            return !isDone
        }
        let at = value
        let delta = newTarget - at
        if abs(delta * scale) < Self.epsilonDevicePx {
            from = newTarget
            to = newTarget
            t = 0.0
            duration = 0.0
            return false
        }
        if isDone || duration <= 0.0 {
            self = WheelCurve(from: at, to: newTarget, scale: scale)
            return true
        }
        let v = velocity
        let rawBound = (v != 0.0) ? (delta / v * 2.5) : Double.infinity
        let bound = (abs(v * scale) < Self.epsilonDevicePx || rawBound < 0.0) ? Double.infinity : rawBound
        let nextDuration = min(Self.duration(delta: delta, scale: scale), bound)
        if nextDuration < Self.epsilonDevicePx {
            from = newTarget
            to = newTarget
            t = 0.0
            duration = 0.0
            return false
        }
        let slope = Float(min(1000.0, max(-1000.0, v * nextDuration / delta)))
        from = at
        to = newTarget
        t = 0.0
        duration = nextDuration
        ease = CubicBezier(0.42, 0.42 * slope, 0.58, 1.0)
        return true
    }

    /// Rounds `offset` points onto the nearest whole device pixel (`scale` device px per pt).
    public static func devicePixel(_ offset: Double, scale: Double) -> Double {
        scale > 0.0 ? (offset * scale).rounded() / scale : offset
    }

    /// Snaps `offset` to the device grid, letting `max` win when within 1 device pixel of the end.
    public static func onGridOrEnd(_ offset: Double, max limit: Double, scale: Double) -> Double {
        let snapped = devicePixel(offset, scale: scale)
        if (limit - snapped) * scale < 1.0 { return limit }
        return min(max(0.0, snapped), limit)
    }

    /// Easing duration in seconds for `delta` logical points at `scale` device pixels per point.
    public static func duration(delta: Double, scale: Double) -> Double {
        let slope = (shortestFrames - longestFrames) / (rampEndDevicePx - rampStartDevicePx)
        let raw = longestFrames - rampStartDevicePx * slope + abs(delta * scale) * slope
        let frames = min(longestFrames, max(shortestFrames, raw))
        return frames / 60.0
    }
}

extension Runtime {
    /// Enables or disables Chromium-style notched mouse wheel gliding (`Runtime::set_wheel_glide`, `#1150`).
    /// Reduced motion always lands notched wheel scrolls immediately regardless of this flag.
    public func setWheelGlide(_ enabled: Bool) {
        wheelGlideEnabled = enabled
        if !enabled {
            landAllWheelCurves()
        }
    }

    /// Whether notched wheel events currently glide (`wheelGlideEnabled && !reducedMotion`).
    public var wheelGlides: Bool {
        wheelGlideEnabled && !reducedMotion
    }

    internal var hasActiveWheelGlides: Bool {
        !wheelCurvesY.isEmpty || !wheelCurvesX.isEmpty
    }

    internal func wheelTargetY(for path: String) -> Float {
        if let curve = wheelCurvesY[path] {
            return Float(curve.target)
        }
        return scrollOffsets[path]?.y ?? 0
    }

    internal func wheelTargetX(for path: String) -> Float {
        if let curve = wheelCurvesX[path] {
            return Float(curve.target)
        }
        return scrollOffsets[path]?.x ?? 0
    }

    internal func cancelWheelGlides(for path: String, vertical: Bool = true, horizontal: Bool = true) {
        if vertical { wheelCurvesY.removeValue(forKey: path) }
        if horizontal { wheelCurvesX.removeValue(forKey: path) }
    }

    internal func landAllWheelCurves() {
        for (path, curve) in wheelCurvesY {
            let maxExt = scrollMaxExtents[path] ?? .zero
            let cur = scrollOffsets[path] ?? .zero
            let nextY = Float(min(max(0.0, curve.target), Double(maxExt.y)))
            let next = Vec2(cur.x, nextY)
            scrollOffsets[path] = next
            scrollStore.snap(NodeId.hash("scroll:" + path), Props.SCROLL, to: next)
        }
        for (path, curve) in wheelCurvesX {
            let maxExt = scrollMaxExtents[path] ?? .zero
            let cur = scrollOffsets[path] ?? .zero
            let nextX = Float(min(max(0.0, curve.target), Double(maxExt.x)))
            let next = Vec2(nextX, cur.y)
            scrollOffsets[path] = next
            scrollStore.snap(NodeId.hash("scroll:" + path), Props.SCROLL, to: next)
        }
        wheelCurvesY.removeAll(keepingCapacity: true)
        wheelCurvesX.removeAll(keepingCapacity: true)
    }

    @discardableResult
    internal func startOrRetargetWheelNotchY(path: String, dy: Float, at now: Double) -> Bool {
        guard let limit = scrollMaxExtents[path]?.y else { return false }
        let limitD = Double(limit)
        let curOffset = Double(scrollOffsets[path]?.y ?? 0)
        let scale = Double(inputScale())
        var curve = wheelCurvesY[path] ?? WheelCurve.still(at: curOffset)
        curve.follow(offset: curOffset)
        let rawTarget = curve.target - Double(dy)
        let clamped = min(max(0.0, rawTarget), limitD)
        let target = WheelCurve.onGridOrEnd(clamped, max: limitD, scale: scale)
        let sticks = nodeByPath[path].map { flatNodes[$0].el.layout.stickBottom } ?? false
        let moving = curve.retarget(to: target, scale: scale)
        curve.aimedAtEnd(sticks && limitD > 0.5 && (limitD - target) * scale < 1.0)
        if !moving {
            if wheelCurvesY[path] != nil {
                wheelCurvesY.removeValue(forKey: path)
            }
            return false
        }
        if !wheelGlides {
            wheelCurvesY.removeValue(forKey: path)
            let cur = scrollOffsets[path] ?? .zero
            let next = Vec2(cur.x, Float(target))
            if next != cur {
                applyManualScroll(path: path, to: next, at: now)
            }
            if curve.toEnd { wasPinnedToBottom.insert(path) } else { wasPinnedToBottom.remove(path) }
            return next != cur
        }
        wheelCurvesY[path] = curve
        scrollGlidingPaths.remove(path)
        if !curve.toEnd { wasPinnedToBottom.remove(path) }
        wakeAt(now)
        return true
    }

    @discardableResult
    internal func startOrRetargetWheelNotchX(path: String, dx: Float, at now: Double) -> Bool {
        guard let limit = scrollMaxExtents[path]?.x else { return false }
        let limitD = Double(limit)
        let curOffset = Double(scrollOffsets[path]?.x ?? 0)
        let isRtl = nodeByPath[path].map { flatNodes[$0].flow == .rtl } ?? false
        let signDx = isRtl ? -Double(dx) : Double(dx)
        let scale = Double(inputScale())
        var curve = wheelCurvesX[path] ?? WheelCurve.still(at: curOffset)
        curve.follow(offset: curOffset)
        let rawTarget = curve.target - signDx
        let clamped = min(max(0.0, rawTarget), limitD)
        let target = WheelCurve.onGridOrEnd(clamped, max: limitD, scale: scale)
        let moving = curve.retarget(to: target, scale: scale)
        if !moving {
            wheelCurvesX.removeValue(forKey: path)
            return false
        }
        if !wheelGlides {
            wheelCurvesX.removeValue(forKey: path)
            let cur = scrollOffsets[path] ?? .zero
            let next = Vec2(Float(target), cur.y)
            if next != cur {
                applyManualScroll(path: path, to: next, at: now)
            }
            return next != cur
        }
        wheelCurvesX[path] = curve
        slice2State.scrollHorizontalVelocities.removeValue(forKey: path)
        scrollGlidingPaths.remove(path)
        wakeAt(now)
        return true
    }

    /// Advances all active notched wheel glide curves on the device pixel grid (`#1150`).
    /// Returns `true` when any viewport offset changed.
    @discardableResult
    internal func stepWheelGlides(dt: Double, catchUp: Bool = false, at now: Double) -> Bool {
        guard !wheelCurvesY.isEmpty || !wheelCurvesX.isEmpty else { return false }
        let scale = Double(inputScale())
        let stepDt = wheelGlides ? dt : Double.infinity
        var movedAny = false

        if !wheelCurvesY.isEmpty {
            let paths = Array(wheelCurvesY.keys)
            for path in paths {
                guard var curve = wheelCurvesY[path], let limit = scrollMaxExtents[path]?.y else {
                    wheelCurvesY.removeValue(forKey: path)
                    continue
                }
                let limitD = Double(limit)
                let cur = scrollOffsets[path] ?? .zero
                curve.follow(offset: Double(cur.y))
                let sticks = nodeByPath[path].map { flatNodes[$0].el.layout.stickBottom } ?? false
                if sticks && curve.toEnd && limitD > curve.target {
                    _ = curve.retarget(to: limitD, scale: scale)
                    curve.aimedAtEnd(true)
                }
                curve.advance(dt: stepDt, catchUp: catchUp)
                let raw = curve.isDone ? curve.target : curve.value
                let nextY = Float(WheelCurve.onGridOrEnd(raw, max: limitD, scale: scale))
                curve.applied(Double(nextY))
                if abs(nextY - cur.y) > 1e-6 {
                    let next = Vec2(cur.x, nextY)
                    scrollOffsets[path] = next
                    scrollStore.snap(NodeId.hash("scroll:" + path), Props.SCROLL, to: next)
                    frameMovedScrollPaths.insert(path)
                    markScrollMovedByHand(path: path)
                    movedAny = true
                }
                let reachedEnd = sticks && curve.toEnd && (limitD - Double(nextY)) * scale < 1.0
                if curve.isDone || reachedEnd {
                    wheelCurvesY.removeValue(forKey: path)
                    if reachedEnd || (sticks && limitD > 0.5 && (limitD - Double(nextY)) <= 1.0) {
                        wasPinnedToBottom.insert(path)
                    }
                } else {
                    wheelCurvesY[path] = curve
                }
            }
        }

        if !wheelCurvesX.isEmpty {
            let paths = Array(wheelCurvesX.keys)
            for path in paths {
                guard var curve = wheelCurvesX[path], let limit = scrollMaxExtents[path]?.x else {
                    wheelCurvesX.removeValue(forKey: path)
                    continue
                }
                let limitD = Double(limit)
                let cur = scrollOffsets[path] ?? .zero
                curve.follow(offset: Double(cur.x))
                curve.advance(dt: stepDt, catchUp: catchUp)
                let raw = curve.isDone ? curve.target : curve.value
                let nextX = Float(WheelCurve.onGridOrEnd(raw, max: limitD, scale: scale))
                curve.applied(Double(nextX))
                if abs(nextX - cur.x) > 1e-6 {
                    let next = Vec2(nextX, cur.y)
                    scrollOffsets[path] = next
                    scrollStore.snap(NodeId.hash("scroll:" + path), Props.SCROLL, to: next)
                    frameMovedScrollPaths.insert(path)
                    markScrollMovedByHand(path: path)
                    movedAny = true
                }
                if curve.isDone {
                    wheelCurvesX.removeValue(forKey: path)
                } else {
                    wheelCurvesX[path] = curve
                }
            }
        }

        if movedAny {
            scrollMovedSinceLastFrame = true
            if scrollRequiresCommit {
                commitFor(why: scrollCommitWhy, at: now, cut: false)
            } else {
                updateScrollPositions(at: now)
            }
        }
        return movedAny
    }
}
