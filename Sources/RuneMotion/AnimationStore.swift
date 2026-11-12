import Foundation

/// Diagnostics recorded whenever active tracks are retargeted mid-flight.
public struct RetargetAudit: Sendable, Equatable {
    public var lanes: Int = 0
    public var maxVelocityError: Float = 0

    public init(lanes: Int = 0, maxVelocityError: Float = 0) {
        self.lanes = lanes
        self.maxVelocityError = maxVelocityError
    }
}

/// Lifecycle event emitted by `AnimationStore` when a track settles or completes.
public enum MotionEvent: Sendable, Equatable {
    case settled(node: NodeId, prop: PropId)
    case completed(token: UInt64, node: NodeId, prop: PropId, finished: Bool)
}

/// How a released gesture continues.
public enum Release<T: Animatable>: Sendable, Equatable {
    case spring(target: T, spring: Spring)
    case decay(Decay)
    case decayClamped(decay: Decay, min: T, max: T, spring: Spring)
}

/// Imperative multi-lane animation store driving both direct property animations and `Scene`.
///
/// Tracks only live while in motion; settled tracks collapse to a compact resting `MotionLanes`
/// entry and consume zero CPU on idle frames.
public struct AnimationStore: Sendable {
    private struct Key: Hashable, Sendable {
        var node: NodeId
        var prop: PropId
    }

    private struct Track: Sendable {
        var propClass: PropClass
        var laneCount: Int
        var target: MotionLanes
        var current: MotionLanes
        var velocity: MotionLanes
        /// Per-lane stack of superposed analytic offset layers (`1` in `.merge`, `>= 1` in `.additive`).
        var layers: [[Layer]]
        var epoch: UInt64 = 0
        var logicalEnd: Double = 0

        var isActive: Bool {
            layers.contains { !$0.isEmpty }
        }
    }

    private var tracks: [Key: Track] = [:]
    private var nodeTimeScales: [NodeId: Float] = [:]
    public var pixelScale: Float = 2.0
    public var reducedMotion: Bool = false
    private var lastSampleTime: Double = 0.0
    private var audit = RetargetAudit()
    private var touchedThisFrame: [(NodeId, String, Bool)] = []
    private var events: [MotionEvent] = []

    /// Most recent store timestamp passed to `sample(at:)`.
    public var now: Double { lastSampleTime }

    public init(pixelScale: Float = 2.0, reducedMotion: Bool = false) {
        self.pixelScale = max(pixelScale, 0.5)
        self.reducedMotion = reducedMotion
    }

    /// True if any track still has unsettled analytic layers.
    public var isAnimating: Bool {
        tracks.values.contains { $0.isActive }
    }

    /// Number of currently active (unsettled) tracks.
    public var activeTrackCount: Int {
        tracks.values.reduce(0) { $0 + ($1.isActive ? 1 : 0) }
    }

    public mutating func takeRetargetAudit() -> RetargetAudit {
        let out = audit
        audit = RetargetAudit()
        return out
    }

    public mutating func takeTouchedTracks() -> [(NodeId, String, Bool)] {
        let out = touchedThisFrame
        touchedThisFrame.removeAll(keepingCapacity: true)
        return out
    }

    public mutating func takeEvents() -> [MotionEvent] {
        let out = events
        events.removeAll(keepingCapacity: true)
        return out
    }

    /// Sets `prop` on `node` to `target` immediately with zero velocity, cancelling any running motion.
    public mutating func snap<T: Animatable>(_ node: NodeId, _ prop: Prop<T>, to target: T) {
        let key = Key(node: node, prop: prop.id)
        let lanes = target.toLanes()
        let nextEpoch = (tracks[key]?.epoch ?? 0) &+ 1
        tracks[key] = Track(
            propClass: prop.propClass,
            laneCount: T.laneCount,
            target: lanes,
            current: lanes,
            velocity: .zero,
            layers: Array(repeating: [], count: T.laneCount),
            epoch: nextEpoch,
            logicalEnd: lastSampleTime
        )
        touchedThisFrame.append((node, prop.name, false))
    }

    /// Shifts both `target` and `current` of a track by `delta` without altering velocity or
    /// exciting new spring energy (used by `Travel.parent` when an ancestor moves).
    public mutating func shift<T: Animatable>(_ node: NodeId, _ prop: Prop<T>, by delta: MotionLanes) {
        let key = Key(node: node, prop: prop.id)
        guard var track = tracks[key] else { return }
        for i in 0..<track.laneCount {
            track.target[i] += delta[i]
            track.current[i] += delta[i]
        }
        tracks[key] = track
    }

    /// Animates `prop` on `node` toward `target` at timestamp `now`.
    /// If the property was never initialized on `node`, initializes it at `target` without animating.
    public mutating func set<T: Animatable>(
        _ node: NodeId,
        _ prop: Prop<T>,
        to target: T,
        anim: Anim<T>,
        at now: Double
    ) {
        let key = Key(node: node, prop: prop.id)
        let newTarget = target.toLanes()
        guard var track = tracks[key] else {
            snap(node, prop, to: target)
            return
        }

        // First sample existing layers at `now` so `current` and `velocity` are exact.
        evaluateTrack(&track, at: now)

        let effectiveCurve = reducedMotion ? prop.propClass.forReducedMotion(anim.curve) : anim.curve
        if anim.blend == .snap || effectiveCurve == .instant {
            track.target = newTarget
            track.current = newTarget
            track.velocity = .zero
            track.epoch &+= 1
            track.logicalEnd = now
            for i in 0..<track.laneCount { track.layers[i].removeAll() }
            tracks[key] = track
            touchedThisFrame.append((node, prop.name, false))
            return
        }

        let (posEps, velEps) = prop.propClass.settleThresholds(pixelScale: pixelScale)
        let t0 = now + Double(anim.delay)
        let oldTarget = track.target
        track.target = newTarget
        track.epoch &+= 1
        let scale = nodeTimeScale(node)
        track.logicalEnd = scale <= 0 ? .infinity : (t0 + Double(effectiveCurve.logicalDuration) / Double(scale))

        var anyActive = false
        for lane in 0..<track.laneCount {
            let targetDelta = newTarget[lane] - oldTarget[lane]
            let seededVel = anim.initialVelocity?.lanes[lane]

            switch anim.blend {
            case .snap:
                track.layers[lane].removeAll()
                track.current[lane] = newTarget[lane]
                track.velocity[lane] = 0

            case .additive:
                let v0 = seededVel ?? 0
                if abs(targetDelta) > posEps || abs(v0) > velEps {
                    if let layer = Layer.make(
                        curve: effectiveCurve,
                        offset: -targetDelta,
                        velocity: v0,
                        t0: t0,
                        posEps: posEps,
                        velEps: velEps
                    ) {
                        track.layers[lane].append(layer)
                    }
                }
                // Cap additive stack depth at 8 by merging if needed.
                if track.layers[lane].count > 8 {
                    var sumOff: Float = 0
                    var sumVel: Float = 0
                    for l in track.layers[lane] {
                        let s = l.sample(at: now)
                        sumOff += s.offset
                        sumVel += s.velocity
                    }
                    track.layers[lane].removeAll(keepingCapacity: true)
                    if let merged = Layer.make(
                        curve: effectiveCurve,
                        offset: sumOff,
                        velocity: sumVel,
                        t0: t0,
                        posEps: posEps,
                        velEps: velEps
                    ) {
                        track.layers[lane].append(merged)
                    }
                }

            case .merge:
                let preVel = seededVel ?? track.velocity[lane]
                let wasMoving = !track.layers[lane].isEmpty
                let offset = track.current[lane] - newTarget[lane]
                if abs(targetDelta) <= posEps && seededVel == nil && wasMoving {
                    // Target unchanged and no new velocity seed: keep existing trajectory untouched!
                    anyActive = true
                    continue
                }
                track.layers[lane].removeAll(keepingCapacity: true)
                if let layer = Layer.make(
                    curve: effectiveCurve,
                    offset: offset,
                    velocity: preVel,
                    t0: t0,
                    posEps: posEps,
                    velEps: velEps
                ) {
                    track.layers[lane].append(layer)
                    if wasMoving && anim.delay == 0 {
                        let postVel = layer.sample(at: now).velocity
                        audit.lanes += 1
                        audit.maxVelocityError = max(audit.maxVelocityError, abs(postVel - preVel))
                    }
                } else {
                    track.current[lane] = newTarget[lane]
                    track.velocity[lane] = 0
                }
            }

            if !track.layers[lane].isEmpty {
                anyActive = true
            }
        }

        evaluateTrack(&track, at: now)
        tracks[key] = track
        touchedThisFrame.append((node, prop.name, anyActive))
    }

    /// Launches an inertial decay fling from the current value with `velocity` (units/s),
    /// returning the resting target `T` that the decay will settle on.
    @discardableResult
    public mutating func fling<T: Animatable>(
        _ node: NodeId,
        _ prop: Prop<T>,
        from initial: T? = nil,
        velocity: Velocity<T>,
        decay: Decay = .IOS_NORMAL,
        at now: Double
    ) -> T {
        if let initial {
            let key = Key(node: node, prop: prop.id)
            if tracks[key] == nil {
                snap(node, prop, to: initial)
            }
        }
        let start = get(node, prop)?.toLanes() ?? initial?.toLanes() ?? .zero
        var restLanes = MotionLanes()
        for lane in 0..<T.laneCount {
            restLanes[lane] = decay.target(from: start[lane], initialVelocity: velocity.lanes[lane])
        }
        let restTarget = T.fromLanes(restLanes)
        set(
            node,
            prop,
            to: restTarget,
            anim: Anim(curve: .decay(decay), blend: .merge, initialVelocity: velocity),
            at: now
        )
        return restTarget
    }

    /// Continues a released gesture with `Release<T>` (spring, decay, or clamped decay).
    @discardableResult
    public mutating func release<T: Animatable>(
        _ node: NodeId,
        _ prop: Prop<T>,
        _ release: Release<T>,
        velocity: Velocity<T>,
        at now: Double
    ) -> T {
        switch release {
        case let .spring(target, spring):
            set(node, prop, to: target, anim: Anim(curve: .spring(spring), blend: .merge, initialVelocity: velocity), at: now)
            return target
        case let .decay(decay):
            return fling(node, prop, velocity: velocity, decay: decay, at: now)
        case let .decayClamped(decay, minVal, maxVal, spring):
            let start = (get(node, prop) ?? T.zeroValue).toLanes()
            let minL = minVal.toLanes()
            let maxL = maxVal.toLanes()
            var targetLanes = MotionLanes()
            var clamped = false
            for lane in 0..<T.laneCount {
                let projected = decay.target(from: start[lane], initialVelocity: velocity.lanes[lane])
                if projected < minL[lane] {
                    targetLanes[lane] = minL[lane]
                    clamped = true
                } else if projected > maxL[lane] {
                    targetLanes[lane] = maxL[lane]
                    clamped = true
                } else {
                    targetLanes[lane] = projected
                }
            }
            let target = T.fromLanes(targetLanes)
            if clamped {
                set(node, prop, to: target, anim: Anim(curve: .spring(spring), blend: .merge, initialVelocity: velocity), at: now)
            } else {
                set(node, prop, to: target, anim: Anim(curve: .decay(decay), blend: .merge, initialVelocity: velocity), at: now)
            }
            return target
        }
    }

    /// Evaluates all active tracks at `now` and prunes settled layers.
    public mutating func sample(at now: Double) {
        lastSampleTime = now
        for key in Array(tracks.keys) {
            guard var track = tracks[key], track.isActive else { continue }
            evaluateTrack(&track, at: now)
            if !track.isActive {
                events.append(.settled(node: key.node, prop: key.prop))
            }
            tracks[key] = track
        }
    }

    /// Reads the current value of `prop` on `node` (at the most recent `sample(at:)`).
    public func get<T: Animatable>(_ node: NodeId, _ prop: Prop<T>) -> T? {
        guard let track = tracks[Key(node: node, prop: prop.id)] else { return nil }
        return T.fromLanes(track.current)
    }

    /// Reads the resting target of `prop` on `node`.
    public func target<T: Animatable>(_ node: NodeId, _ prop: Prop<T>) -> T? {
        guard let track = tracks[Key(node: node, prop: prop.id)] else { return nil }
        return T.fromLanes(track.target)
    }

    /// Reads the instantaneous velocity of `prop` on `node`.
    public func velocity<T: Animatable>(_ node: NodeId, _ prop: Prop<T>) -> Velocity<T> {
        guard let track = tracks[Key(node: node, prop: prop.id)] else { return .zero }
        return Velocity(lanes: track.velocity)
    }

    /// True if `prop` on `node` currently has unsettled motion layers.
    public func isMoving<T: Animatable>(_ node: NodeId, _ prop: Prop<T>) -> Bool {
        tracks[Key(node: node, prop: prop.id)]?.isActive ?? false
    }

    public func has<T: Animatable>(_ node: NodeId, _ prop: Prop<T>) -> Bool {
        tracks[Key(node: node, prop: prop.id)] != nil
    }

    /// Removes all tracks belonging to `node`.
    public mutating func removeNode(_ node: NodeId) {
        tracks = tracks.filter { $0.key.node != node }
    }

    public mutating func clear() {
        tracks.removeAll()
        nodeTimeScales.removeAll()
    }

    /// Sets per-node clock scale (`0.0` freezes, `1.0` is normal).
    public mutating func setNodeTimeScale(_ node: NodeId, _ scale: Float) {
        if scale == 1.0 {
            nodeTimeScales.removeValue(forKey: node)
        } else {
            nodeTimeScales[node] = max(0, scale)
        }
    }

    public func nodeTimeScale(_ node: NodeId) -> Float {
        nodeTimeScales[node] ?? 1.0
    }

    public func epoch(_ node: NodeId, _ prop: PropId) -> UInt64? {
        tracks[Key(node: node, prop: prop)]?.epoch
    }

    public func isSettled(_ node: NodeId, _ prop: PropId) -> Bool {
        !(tracks[Key(node: node, prop: prop)]?.isActive ?? false)
    }

    public func logicalEnd(_ node: NodeId, _ prop: PropId) -> Double? {
        tracks[Key(node: node, prop: prop)]?.logicalEnd
    }

    /// Ensures an untyped track exists, initializing at `target` if absent.
    public mutating func ensureRaw(
        node: NodeId,
        prop: PropId,
        propClass: PropClass,
        laneCount: Int,
        target: MotionLanes
    ) {
        let key = Key(node: node, prop: prop)
        if tracks[key] == nil {
            tracks[key] = Track(
                propClass: propClass,
                laneCount: laneCount,
                target: target,
                current: target,
                velocity: .zero,
                layers: Array(repeating: [], count: laneCount),
                epoch: 1,
                logicalEnd: lastSampleTime
            )
        }
    }

    /// Snaps an untyped track immediately to `target`.
    public mutating func snapRaw(
        node: NodeId,
        prop: PropId,
        propClass: PropClass,
        laneCount: Int,
        target: MotionLanes
    ) {
        let key = Key(node: node, prop: prop)
        let nextEpoch = (tracks[key]?.epoch ?? 0) &+ 1
        tracks[key] = Track(
            propClass: propClass,
            laneCount: laneCount,
            target: target,
            current: target,
            velocity: .zero,
            layers: Array(repeating: [], count: laneCount),
            epoch: nextEpoch,
            logicalEnd: lastSampleTime
        )
    }

    /// Animates an untyped track toward `target` using `curve`, `blend`, and `delay`.
    public mutating func animateRaw(
        node: NodeId,
        prop: PropId,
        propClass: PropClass,
        laneCount: Int,
        target newTarget: MotionLanes,
        curve: Curve,
        blend: Blend,
        delay: Float,
        initialVelocity: MotionLanes? = nil,
        at now: Double
    ) {
        let key = Key(node: node, prop: prop)
        guard var track = tracks[key] else {
            snapRaw(node: node, prop: prop, propClass: propClass, laneCount: laneCount, target: newTarget)
            return
        }
        evaluateTrack(&track, at: now)

        let effectiveCurve = reducedMotion ? propClass.forReducedMotion(curve) : curve
        if blend == .snap || effectiveCurve == .instant {
            track.target = newTarget
            track.current = newTarget
            track.velocity = .zero
            track.epoch &+= 1
            track.logicalEnd = now
            for i in 0..<track.laneCount { track.layers[i].removeAll() }
            tracks[key] = track
            return
        }

        let (posEps, velEps) = propClass.settleThresholds(pixelScale: pixelScale)
        let t0 = now + Double(delay)
        let oldTarget = track.target
        track.target = newTarget
        track.epoch &+= 1
        let scale = nodeTimeScale(node)
        track.logicalEnd = scale <= 0 ? .infinity : (t0 + Double(effectiveCurve.logicalDuration) / Double(scale))

        for lane in 0..<track.laneCount {
            let targetDelta = newTarget[lane] - oldTarget[lane]
            let seededVel = initialVelocity?[lane]
            switch blend {
            case .snap:
                track.layers[lane].removeAll()
                track.current[lane] = newTarget[lane]
                track.velocity[lane] = 0
            case .additive:
                let v0 = seededVel ?? 0
                if abs(targetDelta) > posEps || abs(v0) > velEps,
                   let layer = Layer.make(curve: effectiveCurve, offset: -targetDelta, velocity: v0, t0: t0, posEps: posEps, velEps: velEps) {
                    track.layers[lane].append(layer)
                }
            case .merge:
                let preVel = seededVel ?? track.velocity[lane]
                let wasMoving = !track.layers[lane].isEmpty
                let offset = track.current[lane] - newTarget[lane]
                if abs(targetDelta) <= posEps && seededVel == nil && wasMoving {
                    continue
                }
                track.layers[lane].removeAll(keepingCapacity: true)
                if let layer = Layer.make(curve: effectiveCurve, offset: offset, velocity: preVel, t0: t0, posEps: posEps, velEps: velEps) {
                    track.layers[lane].append(layer)
                } else {
                    track.current[lane] = newTarget[lane]
                    track.velocity[lane] = 0
                }
            }
        }
        evaluateTrack(&track, at: now)
        tracks[key] = track
    }

    private func evaluateTrack(_ track: inout Track, at now: Double) {
        for lane in 0..<track.laneCount {
            if track.layers[lane].isEmpty {
                track.current[lane] = track.target[lane]
                track.velocity[lane] = 0
                continue
            }
            var offSum: Float = 0
            var velSum: Float = 0
            track.layers[lane].removeAll { $0.isSettled(at: now) }
            for layer in track.layers[lane] {
                let s = layer.sample(at: now)
                offSum += s.offset
                velSum += s.velocity
            }
            if track.layers[lane].isEmpty {
                track.current[lane] = track.target[lane]
                track.velocity[lane] = 0
            } else {
                track.current[lane] = track.target[lane] + offSum
                track.velocity[lane] = velSum
            }
        }
    }
}
