import Foundation

/// Generational handle to one animated property track in `AnimationStore`.
public struct TrackId: Sendable, Hashable, Codable {
    public var index: UInt32
    public var generation: UInt32

    public init(index: UInt32, generation: UInt32) {
        self.index = index
        self.generation = generation
    }

    internal var indexInt: Int { Int(index) }
}

/// Optional diagnostics for inherited spring velocity continuity at retarget boundaries.
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
    case settled(track: TrackId, node: NodeId, prop: PropId)
    case completed(token: UInt64, node: NodeId, prop: PropId, finished: Bool)
}

/// How a released gesture continues.
public enum Release<T: Animatable>: Sendable, Equatable {
    case spring(target: T, spring: Spring)
    case decay(Decay)
    case decayClamped(decay: Decay, min: T, max: T, spring: Spring)
}

/// Struct-of-arrays multi-lane animation store driving imperative property animations and `Scene`.
///
/// Tracks only remain active while moving or waiting for a delayed start; settled tracks collapse
/// to their resting pose and consume zero CPU on idle frames.
public struct AnimationStore: Sendable {
    @usableFromInline internal static let none: UInt32 = UInt32.max
    @usableFromInline internal static let maxAdditive: Int = 8

    private struct Key: Hashable, Sendable {
        var node: UInt64
        var prop: UInt16
    }

    internal struct Extra: Sendable {
        var layer: Layer
        var next: UInt32
    }

    internal struct Pending: Sendable {
        var at: Double
        var target: Float
        /// `NaN` means inherit instantaneous velocity when applied.
        var velocity: Float
        var curve: Curve
        var blend: Blend
        var next: UInt32
    }

    internal struct Meta: Sendable {
        var node: NodeId
        var prop: PropId
        var propClass: PropClass
        var generation: UInt32
        var alive: Bool
        var epoch: UInt32
        var token: UInt64
        var logicalAt: Double
        var nodeNext: UInt32
    }

    internal struct SubClock: Sendable {
        var time: Double
        var scale: Float
        var nodes: UInt32
    }

    private enum AuditMode: Sendable {
        case disabled
        case spatialOnly
        case allSprings
    }

    private var nowTime: Double = 0.0
    private var _pixelScale: Float = 2.0
    public var reducedMotion: Bool = false

    // Per-lane SoA arrays
    internal var lTarget: [Float] = []
    internal var lValue: [Float] = []
    internal var lVel: [Float] = []
    internal var lLayer: [Layer] = []
    internal var lMore: [UInt32] = []
    internal var lPending: [UInt32] = []
    internal var lCurve: [Curve] = []
    private var laneFree: [[UInt32]] = Array(repeating: [], count: MotionLanes.maxLanes + 1)

    // Per-track SoA arrays
    internal var tLane0: [UInt32] = []
    internal var tN: [UInt8] = []
    internal var tSettleAt: [Double] = []
    internal var tNextDue: [Double] = []
    internal var tSlot: [UInt32] = []
    internal var tMeta: [Meta] = []
    /// `0` means store clock; otherwise 1-based index into `clocks`.
    internal var tClock: [UInt32] = []
    internal var tHeld: [Bool] = []
    private var trackFree: [UInt32] = []

    // Per-node sub-clocks
    internal var clocks: [SubClock] = []
    private var clockFree: [UInt32] = []
    internal var nodeClock: [UInt64: UInt32] = [:]

    // Active / touched / started tracking
    internal var activeIndices: [UInt32] = []
    internal var touchedBuffer: [TrackId] = []
    internal var setTouched: [TrackId] = []
    internal var starts: [TrackId] = []
    internal var tickedStarts: [TrackId] = []

    // Intrusive pools
    internal var extra: [Extra] = []
    private var extraFree: UInt32 = none
    internal var pending: [Pending] = []
    private var pendingFree: UInt32 = none

    private var index: [Key: UInt32] = [:]
    private var nodeHead: [UInt64: UInt32] = [:]

    internal var eventCarry = Carry<MotionEvent>()
    private var auditMode: AuditMode = .disabled
    private var audit = RetargetAudit()

    /// Device pixels per point; sets settle thresholds below the 1/64 px snap quantum.
    public var pixelScale: Float {
        get { _pixelScale }
        set { _pixelScale = max(newValue, 1.0) }
    }

    /// Presentation timestamp animations are applied at and sampled for (seconds).
    public var now: Double { nowTime }

    /// Creates an animation store matching upstream defaults (`pixelScale = 2.0`, `auditRetargets = false`).
    public init() {}

    /// Creates an animation store with explicit display scale and reduced-motion flag.
    public init(pixelScale: Float, reducedMotion: Bool = false) {
        self._pixelScale = max(pixelScale, 0.5)
        self.reducedMotion = reducedMotion
        self.auditMode = .disabled
    }

    /// Pre-sizes pools for `tracks` tracks of `lanesPerTrack` lanes to avoid per-frame allocations.
    public static func withCapacity(tracks: Int, lanesPerTrack: Int = 4) -> AnimationStore {
        var s = AnimationStore()
        let lanes = max(0, tracks * lanesPerTrack)
        s.lTarget.reserveCapacity(lanes)
        s.lValue.reserveCapacity(lanes)
        s.lVel.reserveCapacity(lanes)
        s.lLayer.reserveCapacity(lanes)
        s.lMore.reserveCapacity(lanes)
        s.lPending.reserveCapacity(lanes)
        s.lCurve.reserveCapacity(lanes)
        s.tLane0.reserveCapacity(tracks)
        s.tN.reserveCapacity(tracks)
        s.tSettleAt.reserveCapacity(tracks)
        s.tNextDue.reserveCapacity(tracks)
        s.tSlot.reserveCapacity(tracks)
        s.tMeta.reserveCapacity(tracks)
        s.tClock.reserveCapacity(tracks)
        s.tHeld.reserveCapacity(tracks)
        s.activeIndices.reserveCapacity(tracks)
        s.touchedBuffer.reserveCapacity(tracks)
        s.eventCarry.reserveCapacity(tracks * 2)
        s.index.reserveCapacity(tracks)
        s.nodeHead.reserveCapacity(tracks)
        return s
    }

    // MARK: - Time & Policy

    public mutating func setPixelScale(_ scale: Float) {
        _pixelScale = max(scale, 1.0)
    }

    public mutating func setReducedMotion(_ on: Bool) {
        reducedMotion = on
    }

    public mutating func auditRetargets(_ enabled: Bool) {
        auditMode = enabled ? .spatialOnly : .disabled
        audit = RetargetAudit()
    }

    public mutating func takeRetargetAudit() -> RetargetAudit {
        let out = audit
        audit = RetargetAudit()
        return out
    }

    /// Sets the frame's target presentation time, advancing all active per-node sub-clocks by `dt * scale`.
    public mutating func setTime(_ t: Double) {
        let dt = t - nowTime
        nowTime = t
        if clocks.count > 1 {
            for i in 1..<clocks.count where clocks[i].nodes > 0 && clocks[i].scale != 0 {
                clocks[i].time += dt * Double(clocks[i].scale)
            }
        }
    }

    /// `setTime(t)` followed by `tick()`.
    public mutating func tickAt(_ t: Double) {
        setTime(t)
        tick()
    }

    // MARK: - Per-Node Time Scaling

    /// Runs every track of `node` (and future tracks) at `scale` times the store's speed.
    /// `0` freezes the node in place (delays included) and excludes it from `running`.
    public mutating func setNodeTimeScale(_ node: NodeId, _ scale: Float) {
        let s = scale.isFinite ? max(0.0, scale) : 1.0
        let old = nodeClock[node.rawValue] ?? 0
        if clockScale(old) == s { return }
        let newClock: UInt32 = (s == 1.0) ? 0 : clockAt(scale: s)
        let delta = clockTime(newClock) - clockTime(old)
        if newClock == 0 {
            nodeClock.removeValue(forKey: node.rawValue)
        } else {
            clocks[Int(newClock)].nodes += 1
            nodeClock[node.rawValue] = newClock
        }
        var t = nodeHead[node.rawValue] ?? Self.none
        while t != Self.none {
            let ti = Int(t)
            rebase(ti, delta: delta)
            tClock[ti] = newClock
            t = tMeta[ti].nodeNext
        }
        releaseClock(old)
    }

    public func nodeTimeScale(_ node: NodeId) -> Float {
        if nodeClock.isEmpty { return 1.0 }
        return clockScale(nodeClock[node.rawValue] ?? 0)
    }

    public func nodeTime(_ node: NodeId) -> Double {
        if nodeClock.isEmpty { return nowTime }
        return clockTime(nodeClock[node.rawValue] ?? 0)
    }

    private mutating func clockAt(scale: Float) -> UInt32 {
        if clocks.count > 1 {
            for i in 1..<clocks.count where clocks[i].nodes > 0 && clocks[i].scale == scale {
                return UInt32(i)
            }
        }
        if clocks.isEmpty {
            clocks.append(SubClock(time: 0.0, scale: 1.0, nodes: 0))
        }
        let clock = SubClock(time: nowTime, scale: scale, nodes: 0)
        if let free = clockFree.popLast() {
            clocks[Int(free)] = clock
            return free
        }
        clocks.append(clock)
        return UInt32(clocks.count - 1)
    }

    private mutating func releaseClock(_ c: UInt32) {
        guard c != 0 else { return }
        let ci = Int(c)
        clocks[ci].nodes -= 1
        if clocks[ci].nodes == 0 {
            clockFree.append(c)
        }
    }

    @inline(__always)
    internal func clockScale(_ c: UInt32) -> Float {
        c == 0 ? 1.0 : clocks[Int(c)].scale
    }

    @inline(__always)
    internal func clockTime(_ c: UInt32) -> Double {
        c == 0 ? nowTime : clocks[Int(c)].time
    }

    @inline(__always)
    internal func timeOf(_ t: Int) -> Double {
        clockTime(tClock[t])
    }

    @inline(__always)
    internal func frozen(_ t: Int) -> Bool {
        let c = tClock[t]
        return c != 0 && clocks[Int(c)].scale == 0.0
    }

    internal mutating func rebase(_ t: Int, delta: Double) {
        resample(t)
        if delta == 0.0 { return }
        let l0 = Int(tLane0[t])
        let n = Int(tN[t])
        for l in l0..<(l0 + n) {
            lLayer[l].t0 += delta
            lLayer[l].end += delta
            var m = lMore[l]
            while m != Self.none {
                let mi = Int(m)
                extra[mi].layer.t0 += delta
                extra[mi].layer.end += delta
                m = extra[mi].next
            }
            var p = lPending[l]
            while p != Self.none {
                let pi = Int(p)
                pending[pi].at += delta
                p = pending[pi].next
            }
        }
        tSettleAt[t] += delta
        tNextDue[t] += delta
        tMeta[t].logicalAt += delta
    }

    // MARK: - Frame Tick

    /// Samples every active track at its clock time, promotes due pending starts, and settles finished tracks.
    public mutating func tick() {
        eventCarry.begin()
        touchedBuffer.removeAll(keepingCapacity: true)
        for id in setTouched where contains(id) {
            touchedBuffer.append(id)
        }
        setTouched.removeAll(keepingCapacity: true)
        swap(&starts, &tickedStarts)
        starts.removeAll(keepingCapacity: true)

        let clocked = !nodeClock.isEmpty
        var i = 0
        while i < activeIndices.count {
            let t = Int(activeIndices[i])
            let trackNow = clocked ? timeOf(t) : nowTime
            let m = mode(t)
            if m.holds && tHeld[t] {
                i += 1
                continue
            }
            touchedBuffer.append(TrackId(index: UInt32(t), generation: tMeta[t].generation))
            if tNextDue[t] <= trackNow {
                applyDue(t, now: trackNow)
            }
            tHeld[t] = m.holds
            let l0 = Int(tLane0[t])
            let n = Int(tN[t])
            var stacked = false
            for k in 0..<n {
                let l = l0 + k
                let (o, v) = lLayer[l].sample(at: trackNow)
                lValue[l] = lTarget[l] + o
                lVel[l] = v
                if lMore[l] != Self.none { stacked = true }
            }
            if stacked {
                for l in l0..<(l0 + n) where lMore[l] != Self.none {
                    let (o2, v2) = sampleExtra(l, now: trackNow)
                    lValue[l] += o2
                    lVel[l] += v2
                }
            }
            if trackNow >= tSettleAt[t] && tNextDue[t] == .infinity {
                settle(t)
                deactivate(t, slot: i)
                continue
            }
            i += 1
        }
        eventCarry.end()
    }

    /// Events since the previous tick (retained across frames via `Carry` until the next `tick()`).
    public var events: [MotionEvent] {
        eventCarry.items
    }

    /// Drains and returns current events (legacy compatibility helper).
    public mutating func takeEvents() -> [MotionEvent] {
        let out = eventCarry.items
        eventCarry.removeAll(keepingCapacity: true)
        return out
    }

    /// Legacy compatibility helper returning active or settled diagnostics; prefer `touchedTracks()`.
    public mutating func takeTouchedTracks() -> [(NodeId, String, Bool)] {
        touchedTracks().map { (id, node, prop) in
            let moving = tSlot[id.indexInt] != Self.none
            return (node, "prop(\(prop.rawValue))", moving)
        }
    }

    public func valuesOf(_ id: TrackId) -> ArraySlice<Float>? {
        guard contains(id) else { return nil }
        let t = id.indexInt
        let l0 = Int(tLane0[t])
        return lValue[l0..<(l0 + Int(tN[t]))]
    }

    internal func targetsOf(_ id: TrackId, into out: inout [Float]) -> Bool {
        guard contains(id) else { return false }
        let t = id.indexInt
        let l0 = Int(tLane0[t])
        let n = min(out.count, Int(tN[t]))
        for k in 0..<n {
            out[k] = finalTarget(l0 + k)
        }
        return true
    }

    public func isActive(_ id: TrackId) -> Bool {
        contains(id) && tSlot[id.indexInt] != Self.none
    }

    internal func sampleExact(_ id: TrackId, x: inout [Float], v: inout [Float]) -> Bool {
        guard contains(id) else { return false }
        let t = id.indexInt
        let l0 = Int(tLane0[t])
        let trackNow = timeOf(t)
        let n = Int(tN[t])
        for i in 0..<n {
            let (px, pv) = sampleLane(l0 + i, at: trackNow)
            x[i] = px
            v[i] = pv
        }
        return true
    }

    public var activeLen: Int { activeIndices.count }
    public var activeTrackCount: Int { activeIndices.count }

    /// True if any track is animating on a clock with positive scale. Frozen tracks are ignored.
    public var running: Bool {
        if nodeClock.isEmpty {
            return !activeIndices.isEmpty
        }
        return activeIndices.contains { mode(Int($0)) != .frozen }
    }

    /// Compatibility alias for `running`.
    public var isAnimating: Bool { running }

    public var trackLen: Int {
        tMeta.reduce(0) { $0 + ($1.alive ? 1 : 0) }
    }

    // MARK: - Typed Public API

    /// Sets `prop` on `node` immediately with zero velocity, cancelling any running motion.
    @discardableResult
    public mutating func set<T: Animatable>(_ node: NodeId, _ prop: Prop<T>, _ value: T) -> TrackId {
        setChanged(node, prop, value).0
    }

    @discardableResult
    public mutating func snap<T: Animatable>(_ node: NodeId, _ prop: Prop<T>, to value: T) -> TrackId {
        set(node, prop, value)
    }

    internal mutating func setChanged<T: Animatable>(_ node: NodeId, _ prop: Prop<T>, _ value: T) -> (TrackId, Bool) {
        let lanes = value.toLanes()
        let n = T.laneCount
        if let t = index[Key(node: node.rawValue, prop: prop.id.rawValue)] {
            checkLanes(Int(t), expected: n)
            if atRestOn(Int(t), lanes: lanes, count: n) {
                return (idOf(Int(t)), false)
            }
        }
        let t = ensure(node, prop.id, prop.propClass, initLanes: lanes, count: n)
        setRaw(t, lanes: lanes, count: n)
        return (idOf(Int(t)), true)
    }

    private func atRestOn(_ t: Int, lanes: MotionLanes, count: Int) -> Bool {
        guard tSlot[t] == Self.none && tMeta[t].token == 0 else { return false }
        let l0 = Int(tLane0[t])
        for i in 0..<count {
            let l = l0 + i
            let x = lanes[i]
            if lTarget[l] != x || lValue[l] != x || lVel[l] != 0.0 ||
                lPending[l] != Self.none || lMore[l] != Self.none || lLayer[l].kind != .rest {
                return false
            }
        }
        return true
    }

    /// Animates `prop` on `node` to `target`. On first sight the property snaps immediately.
    @discardableResult
    public mutating func animate<T: Animatable>(
        _ node: NodeId,
        _ prop: Prop<T>,
        to target: T,
        anim: Anim<T>
    ) -> TrackId {
        animateChanged(node, prop, to: target, anim: anim).0
    }

    internal mutating func animateChanged<T: Animatable>(
        _ node: NodeId,
        _ prop: Prop<T>,
        to target: T,
        anim: Anim<T>
    ) -> (TrackId, Bool) {
        guard let t = index[Key(node: node.rawValue, prop: prop.id.rawValue)] else {
            return setChanged(node, prop, target)
        }
        let ti = Int(t)
        checkLanes(ti, expected: T.laneCount)
        let targetLanes = target.toLanes()
        let velLanes = anim.initialVelocity?.lanes
        let changed = animateRaw(
            ti,
            targets: targetLanes,
            count: T.laneCount,
            curve: anim.curve,
            blend: anim.blend,
            delay: anim.delay,
            velocityRule: anim.velocityRule,
            token: anim.token,
            laneVelocities: velLanes
        )
        return (idOf(ti), changed)
    }

    @discardableResult
    public mutating func animateWithVelocity<T: Animatable>(
        _ node: NodeId,
        _ prop: Prop<T>,
        to target: T,
        velocity: T,
        anim: Anim<T>
    ) -> TrackId {
        let targetLanes = target.toLanes()
        let velLanes = velocity.toLanes()
        let t = Int(ensure(node, prop.id, prop.propClass, initLanes: targetLanes, count: T.laneCount))
        _ = animateRaw(
            t,
            targets: targetLanes,
            count: T.laneCount,
            curve: anim.curve,
            blend: anim.blend,
            delay: anim.delay,
            velocityRule: anim.velocityRule,
            token: anim.token,
            laneVelocities: velLanes
        )
        return idOf(t)
    }

    /// Compatibility overload advancing store time if `now != self.now` before animating.
    @discardableResult
    public mutating func set<T: Animatable>(
        _ node: NodeId,
        _ prop: Prop<T>,
        to target: T,
        anim: Anim<T>,
        at now: Double
    ) -> TrackId {
        if now != nowTime { setTime(now) }
        return animate(node, prop, to: target, anim: anim)
    }

    /// Launches an inertial decay fling from optional `start` with initial `velocity`, returning the projected rest value.
    @discardableResult
    public mutating func fling<T: Animatable>(
        _ node: NodeId,
        _ prop: Prop<T>,
        from start: T? = nil,
        velocity: Velocity<T>,
        decay: Decay = .IOS_NORMAL,
        at now: Double
    ) -> T {
        if now != nowTime { setTime(now) }
        if let start {
            _ = set(node, prop, start)
        } else if !has(node, prop) {
            _ = set(node, prop, T.zeroValue)
        }
        let cur = sample(node, prop) ?? T.zeroValue
        let t = Int(index[Key(node: node.rawValue, prop: prop.id.rawValue)]!)
        _ = animateRaw(
            t,
            targets: cur.toLanes(),
            count: T.laneCount,
            curve: .decay(decay),
            blend: .merge,
            delay: 0,
            velocityRule: .inherit,
            token: 0,
            laneVelocities: velocity.lanes
        )
        return target(node, prop) ?? cur
    }

    /// Hands a released gesture to physics from its current sampled value and velocity.
    @discardableResult
    public mutating func release<T: Animatable>(
        _ node: NodeId,
        _ prop: Prop<T>,
        velocity: T,
        how: Release<T>
    ) -> TrackId {
        let velLanes = velocity.toLanes()
        let cur = sample(node, prop) ?? {
            preconditionFailure("release: set the value before releasing it")
        }()
        let t = Int(index[Key(node: node.rawValue, prop: prop.id.rawValue)]!)
        let n = T.laneCount
        switch how {
        case let .spring(target, spring):
            _ = animateRaw(
                t,
                targets: target.toLanes(),
                count: n,
                curve: Curve.from(spring),
                blend: .auto,
                delay: 0,
                velocityRule: .inherit,
                token: 0,
                laneVelocities: velLanes
            )

        case let .decay(d):
            _ = animateRaw(
                t,
                targets: cur.toLanes(),
                count: n,
                curve: .decay(d),
                blend: .auto,
                delay: 0,
                velocityRule: .inherit,
                token: 0,
                laneVelocities: velLanes
            )

        case let .decayClamped(decay, minVal, maxVal, spring):
            let curLanes = cur.toLanes()
            let lo = minVal.toLanes()
            let hi = maxVal.toLanes()
            let k = decay.rate
            let l0 = Int(tLane0[t])
            let trackNow = timeOf(t)
            let eps = tMeta[t].propClass.eps(pixelScale: _pixelScale)
            for i in 0..<n {
                let l = l0 + i
                let x = curLanes[i]
                let v = velLanes[i]
                cancelPending(l)
                if x < lo[i] || x > hi[i] {
                    let bound = min(max(x, lo[i]), hi[i])
                    startLane(l, at: trackNow, target: bound, curve: Curve.from(spring), blend: .merge, vel: v, eps: eps)
                    continue
                }
                let proj = x + v / k
                startLane(l, at: trackNow, target: x, curve: .decay(decay), blend: .merge, vel: v, eps: eps)
                let bound: Float? = proj > hi[i] ? hi[i] : (proj < lo[i] ? lo[i] : nil)
                if let b = bound {
                    // x + (v/k)(1 - e^{-k*tau}) = b -> tau = -ln(1 - (b - x)*k/v) / k
                    let tau = -log(Double(1.0 - (b - x) * k / v)) / Double(k)
                    pushPending(
                        l,
                        Pending(
                            at: trackNow + max(0.0, tau),
                            target: b,
                            velocity: .nan,
                            curve: Curve.from(spring),
                            blend: .merge,
                            next: Self.none
                        )
                    )
                }
            }
            commitScheduled(t, logicalAt: trackNow, token: 0)
        }
        return idOf(t)
    }

    /// Legacy compatibility release overload advancing time if needed and returning the final target.
    @discardableResult
    public mutating func release<T: Animatable>(
        _ node: NodeId,
        _ prop: Prop<T>,
        _ how: Release<T>,
        velocity: Velocity<T>,
        at now: Double
    ) -> T {
        if now != nowTime { setTime(now) }
        if !has(node, prop) { _ = set(node, prop, T.zeroValue) }
        _ = release(node, prop, velocity: T.fromLanes(velocity.lanes), how: how)
        return target(node, prop) ?? T.zeroValue
    }

    /// Legacy compatibility `sample(at:)` calling `tickAt(now)`.
    public mutating func sample(at now: Double) {
        tickAt(now)
    }

    /// The value presented at the last `tick` (what's on screen).
    public func get<T: Animatable>(_ node: NodeId, _ prop: Prop<T>) -> T? {
        guard let t = index[Key(node: node.rawValue, prop: prop.id.rawValue)] else { return nil }
        let l0 = Int(tLane0[Int(t)])
        var lanes = MotionLanes.zero
        for i in 0..<T.laneCount { lanes[i] = lValue[l0 + i] }
        return T.fromLanes(lanes)
    }

    /// The velocity at the last `tick`, in units per second.
    public func velocity<T: Animatable>(_ node: NodeId, _ prop: Prop<T>) -> T? {
        guard let t = index[Key(node: node.rawValue, prop: prop.id.rawValue)] else { return nil }
        let l0 = Int(tLane0[Int(t)])
        var lanes = MotionLanes.zero
        for i in 0..<T.laneCount { lanes[i] = lVel[l0 + i] }
        return T.fromLanes(lanes)
    }

    /// Legacy compatibility overload returning `Velocity<T>` directly (zero if missing).
    @_disfavoredOverload
    public func velocity<T: Animatable>(_ node: NodeId, _ prop: Prop<T>) -> Velocity<T> {
        guard let t = index[Key(node: node.rawValue, prop: prop.id.rawValue)] else { return .zero }
        let l0 = Int(tLane0[Int(t)])
        var lanes = MotionLanes.zero
        for i in 0..<T.laneCount { lanes[i] = lVel[l0 + i] }
        return Velocity(lanes: lanes)
    }

    /// Exact analytic value at `now()` (may be between ticks).
    public func sample<T: Animatable>(_ node: NodeId, _ prop: Prop<T>) -> T? {
        guard let t = index[Key(node: node.rawValue, prop: prop.id.rawValue)] else { return nil }
        let ti = Int(t)
        let l0 = Int(tLane0[ti])
        let trackNow = timeOf(ti)
        var lanes = MotionLanes.zero
        for i in 0..<T.laneCount {
            lanes[i] = sampleLane(l0 + i, at: trackNow).0
        }
        return T.fromLanes(lanes)
    }

    /// Exact analytic velocity at `now()`.
    public func sampleVelocity<T: Animatable>(_ node: NodeId, _ prop: Prop<T>) -> T? {
        guard let t = index[Key(node: node.rawValue, prop: prop.id.rawValue)] else { return nil }
        let ti = Int(t)
        let l0 = Int(tLane0[ti])
        let trackNow = timeOf(ti)
        var lanes = MotionLanes.zero
        for i in 0..<T.laneCount {
            lanes[i] = sampleLane(l0 + i, at: trackNow).1
        }
        return T.fromLanes(lanes)
    }

    /// Latest target (including any pending delayed animations).
    public func target<T: Animatable>(_ node: NodeId, _ prop: Prop<T>) -> T? {
        guard let t = index[Key(node: node.rawValue, prop: prop.id.rawValue)] else { return nil }
        let ti = Int(t)
        let l0 = Int(tLane0[ti])
        var lanes = MotionLanes.zero
        for i in 0..<T.laneCount {
            lanes[i] = finalTarget(l0 + i)
        }
        return T.fromLanes(lanes)
    }

    public func has<T>(_ node: NodeId, _ prop: Prop<T>) -> Bool {
        index[Key(node: node.rawValue, prop: prop.id.rawValue)] != nil
    }

    public func has(_ node: NodeId, _ prop: PropId) -> Bool {
        index[Key(node: node.rawValue, prop: prop.rawValue)] != nil
    }

    public func isAnimating<T>(_ node: NodeId, _ prop: Prop<T>) -> Bool {
        guard let t = index[Key(node: node.rawValue, prop: prop.id.rawValue)] else { return false }
        return tSlot[Int(t)] != Self.none
    }

    public func isMoving(_ node: NodeId, _ prop: PropId) -> Bool {
        guard let t = index[Key(node: node.rawValue, prop: prop.rawValue)] else { return false }
        return tSlot[Int(t)] != Self.none
    }

    public func isMoving<T>(_ node: NodeId, _ prop: Prop<T>) -> Bool {
        isMoving(node, prop.id)
    }

    public func isNodeAnimating(_ node: NodeId) -> Bool {
        var t = nodeHead[node.rawValue] ?? Self.none
        while t != Self.none {
            let ti = Int(t)
            if tSlot[ti] != Self.none { return true }
            t = tMeta[ti].nodeNext
        }
        return false
    }

    public func trackId<T>(_ node: NodeId, _ prop: Prop<T>) -> TrackId? {
        index[Key(node: node.rawValue, prop: prop.id.rawValue)].map { idOf(Int($0)) }
    }

    public func trackId(_ node: NodeId, _ prop: PropId) -> TrackId? {
        index[Key(node: node.rawValue, prop: prop.rawValue)].map { idOf(Int($0)) }
    }

    public func contains(_ id: TrackId) -> Bool {
        let i = id.indexInt
        return i < tMeta.count && tMeta[i].alive && tMeta[i].generation == id.generation
    }

    public func isSettled(_ id: TrackId) -> Bool {
        !contains(id) || tSlot[id.indexInt] == Self.none
    }

    public func isSettled(_ node: NodeId, _ prop: PropId) -> Bool {
        guard let t = index[Key(node: node.rawValue, prop: prop.rawValue)] else { return true }
        return tSlot[Int(t)] == Self.none
    }

    public func epoch(_ id: TrackId) -> UInt32? {
        contains(id) ? tMeta[id.indexInt].epoch : nil
    }

    public func epoch(_ node: NodeId, _ prop: PropId) -> UInt64? {
        guard let t = index[Key(node: node.rawValue, prop: prop.rawValue)] else { return nil }
        return UInt64(tMeta[Int(t)].epoch)
    }

    public func logicalEnd(_ id: TrackId) -> Double? {
        guard contains(id) else { return nil }
        let t = id.indexInt
        let at = tMeta[t].logicalAt
        if tClock[t] == 0 { return at }
        let rem = at - timeOf(t)
        let scale = Double(clocks[Int(tClock[t])].scale)
        if rem <= 0.0 { return nowTime + rem }
        if scale == 0.0 { return .infinity }
        return nowTime + rem / scale
    }

    public func logicalEnd(_ node: NodeId, _ prop: PropId) -> Double? {
        guard let id = trackId(node, prop) else { return nil }
        return logicalEnd(id)
    }

    public func owner(_ id: TrackId) -> (NodeId, PropId)? {
        guard contains(id) else { return nil }
        let m = tMeta[id.indexInt]
        return (m.node, m.prop)
    }

    public mutating func remove<T>(_ node: NodeId, _ prop: Prop<T>) {
        guard let t = index[Key(node: node.rawValue, prop: prop.id.rawValue)] else { return }
        unlinkNode(node, t: t)
        freeTrack(Int(t))
    }

    public mutating func removeNode(_ node: NodeId) {
        if let c = nodeClock.removeValue(forKey: node.rawValue) {
            releaseClock(c)
        }
        var t = nodeHead.removeValue(forKey: node.rawValue) ?? Self.none
        while t != Self.none {
            let ti = Int(t)
            let next = tMeta[ti].nodeNext
            freeTrack(ti)
            t = next
        }
    }

    public mutating func clear() {
        lTarget.removeAll(keepingCapacity: true)
        lValue.removeAll(keepingCapacity: true)
        lVel.removeAll(keepingCapacity: true)
        lLayer.removeAll(keepingCapacity: true)
        lMore.removeAll(keepingCapacity: true)
        lPending.removeAll(keepingCapacity: true)
        lCurve.removeAll(keepingCapacity: true)
        for i in laneFree.indices { laneFree[i].removeAll(keepingCapacity: true) }
        tLane0.removeAll(keepingCapacity: true)
        tN.removeAll(keepingCapacity: true)
        tSettleAt.removeAll(keepingCapacity: true)
        tNextDue.removeAll(keepingCapacity: true)
        tSlot.removeAll(keepingCapacity: true)
        tMeta.removeAll(keepingCapacity: true)
        tClock.removeAll(keepingCapacity: true)
        tHeld.removeAll(keepingCapacity: true)
        trackFree.removeAll(keepingCapacity: true)
        clocks.removeAll(keepingCapacity: true)
        clockFree.removeAll(keepingCapacity: true)
        nodeClock.removeAll(keepingCapacity: true)
        activeIndices.removeAll(keepingCapacity: true)
        touchedBuffer.removeAll(keepingCapacity: true)
        setTouched.removeAll(keepingCapacity: true)
        starts.removeAll(keepingCapacity: true)
        tickedStarts.removeAll(keepingCapacity: true)
        extra.removeAll(keepingCapacity: true)
        extraFree = Self.none
        pending.removeAll(keepingCapacity: true)
        pendingFree = Self.none
        index.removeAll(keepingCapacity: true)
        nodeHead.removeAll(keepingCapacity: true)
        eventCarry.removeAll(keepingCapacity: true)
        audit = RetargetAudit()
    }

    /// Live tuning: any lane currently springing on `old` re-springs on `new` preserving `(x, v)`.
    public mutating func retune(old: Spring, new: Spring) {
        for slot in 0..<activeIndices.count {
            let t = Int(activeIndices[slot])
            let trackNow = timeOf(t)
            let l0 = Int(tLane0[t])
            let n = Int(tN[t])
            let eps = tMeta[t].propClass.eps(pixelScale: _pixelScale)
            var hit = false
            for l in l0..<(l0 + n) where lCurve[l] == .spring(old) {
                let target = lTarget[l]
                startLane(l, at: trackNow, target: target, curve: .spring(new), blend: .merge, vel: nil, eps: eps)
                hit = true
            }
            if hit { recompute(t) }
        }
    }

    /// Shifts a track's active target and current pose by `delta` while preserving its motion/velocity.
    public mutating func shift<T: Animatable>(_ node: NodeId, _ prop: Prop<T>, by delta: T) {
        shiftRaw(node, prop.id, laneCount: T.laneCount, by: delta.toLanes())
    }

    /// Legacy compatibility `shift` accepting raw `MotionLanes`.
    public mutating func shift<T>(_ node: NodeId, _ prop: Prop<T>, by delta: MotionLanes) {
        shiftRaw(node, prop.id, laneCount: T.laneCount, by: delta)
    }

    private mutating func shiftRaw(_ node: NodeId, _ prop: PropId, laneCount: Int, by dl: MotionLanes) {
        guard let t = index[Key(node: node.rawValue, prop: prop.rawValue)] else { return }
        let ti = Int(t)
        let l0 = Int(tLane0[ti])
        let n = min(laneCount, Int(tN[ti]))
        var anyNonZero = false
        for i in 0..<n {
            let d = dl[i]
            if d == 0 { continue }
            anyNonZero = true
            let l = l0 + i
            lTarget[l] += d
            lValue[l] += d
            var p = lPending[l]
            while p != Self.none {
                pending[Int(p)].target += d
                p = pending[Int(p)].next
            }
        }
        if anyNonZero { resample(ti) }
    }

    /// Translates `track`'s targets & sampled values by `delta` while preserving motion/velocity.
    internal mutating func translateTrack(_ track: TrackId, delta: MotionLanes, count: Int) {
        guard contains(track) else { return }
        let ti = track.indexInt
        let l0 = Int(tLane0[ti])
        let n = min(count, Int(tN[ti]))
        var anyNonZero = false
        for i in 0..<n {
            let d = delta[i]
            if d == 0 { continue }
            anyNonZero = true
            let l = l0 + i
            lTarget[l] += d
            lValue[l] += d
            var p = lPending[l]
            while p != Self.none {
                pending[Int(p)].target += d
                p = pending[Int(p)].next
            }
        }
        if anyNonZero { resample(ti) }
    }

    // MARK: - Legacy Raw Compatibility Shims (for Scene/Choreography migration)

    public mutating func ensureRaw(
        node: NodeId,
        prop: PropId,
        propClass: PropClass,
        laneCount: Int,
        target: MotionLanes
    ) {
        _ = ensure(node, prop, propClass, initLanes: target, count: laneCount)
    }

    public mutating func snapRaw(
        node: NodeId,
        prop: PropId,
        propClass: PropClass,
        laneCount: Int,
        target: MotionLanes
    ) {
        let t = ensure(node, prop, propClass, initLanes: target, count: laneCount)
        setRaw(t, lanes: target, count: laneCount)
    }

    public mutating func animateRaw(
        node: NodeId,
        prop: PropId,
        propClass: PropClass,
        laneCount: Int,
        target newTarget: MotionLanes,
        curve: Curve,
        blend: Blend,
        delay: Float,
        initialVelocity: MotionLanes?,
        at now: Double,
        token: UInt64 = 0
    ) {
        if now != nowTime { setTime(now) }
        guard let t = index[Key(node: node.rawValue, prop: prop.rawValue)] else {
            let created = ensure(node, prop, propClass, initLanes: newTarget, count: laneCount)
            setRaw(created, lanes: newTarget, count: laneCount)
            return
        }
        let ti = Int(t)
        checkLanes(ti, expected: laneCount)
        _ = animateRaw(
            ti,
            targets: newTarget,
            count: laneCount,
            curve: curve,
            blend: blend,
            delay: delay,
            velocityRule: .inherit,
            token: token,
            laneVelocities: initialVelocity
        )
    }

    // MARK: - Internal SoA Core

    @discardableResult
    internal mutating func ensure(
        _ node: NodeId,
        _ prop: PropId,
        _ propClass: PropClass,
        initLanes: MotionLanes,
        count n: Int
    ) -> UInt32 {
        let key = Key(node: node.rawValue, prop: prop.rawValue)
        if let existing = index[key] {
            checkLanes(Int(existing), expected: n)
            return existing
        }
        precondition(n > 0 && n <= MotionLanes.maxLanes)
        let l0: UInt32
        if let freeL0 = laneFree[n].popLast() {
            l0 = freeL0
        } else {
            let start = lTarget.count
            let end = start + n
            lTarget.append(contentsOf: repeatElement(Float(0), count: n))
            lValue.append(contentsOf: repeatElement(Float(0), count: n))
            lVel.append(contentsOf: repeatElement(Float(0), count: n))
            lLayer.append(contentsOf: repeatElement(Layer.rest, count: n))
            lMore.append(contentsOf: repeatElement(Self.none, count: n))
            lPending.append(contentsOf: repeatElement(Self.none, count: n))
            lCurve.append(contentsOf: repeatElement(Curve.instant, count: n))
            assert(lTarget.count == end)
            l0 = UInt32(start)
        }
        let l0i = Int(l0)
        for i in 0..<n {
            let l = l0i + i
            let x = initLanes[i]
            lTarget[l] = x
            lValue[l] = x
            lVel[l] = 0.0
            lLayer[l] = .rest
            lMore[l] = Self.none
            lPending[l] = Self.none
            lCurve[l] = .instant
        }
        let head = nodeHead[node.rawValue] ?? Self.none
        let clock: UInt32 = nodeClock.isEmpty ? 0 : (nodeClock[node.rawValue] ?? 0)
        let t: UInt32
        if let freeT = trackFree.popLast() {
            let ti = Int(freeT)
            let gen = tMeta[ti].generation &+ 1
            tMeta[ti] = Meta(
                node: node,
                prop: prop,
                propClass: propClass,
                generation: gen,
                alive: true,
                epoch: 0,
                token: 0,
                logicalAt: -.infinity,
                nodeNext: head
            )
            tLane0[ti] = l0
            tN[ti] = UInt8(n)
            tSettleAt[ti] = -.infinity
            tNextDue[ti] = .infinity
            tSlot[ti] = Self.none
            tClock[ti] = clock
            resample(ti)
            t = freeT
        } else {
            tMeta.append(Meta(
                node: node,
                prop: prop,
                propClass: propClass,
                generation: 0,
                alive: true,
                epoch: 0,
                token: 0,
                logicalAt: -.infinity,
                nodeNext: head
            ))
            tLane0.append(l0)
            tN.append(UInt8(n))
            tSettleAt.append(-.infinity)
            tNextDue.append(.infinity)
            tSlot.append(Self.none)
            tClock.append(clock)
            tHeld.append(false)
            t = UInt32(tMeta.count - 1)
        }
        index[key] = t
        nodeHead[node.rawValue] = t
        return t
    }

    @inline(__always)
    internal func idOf(_ t: Int) -> TrackId {
        TrackId(index: UInt32(t), generation: tMeta[t].generation)
    }

    private func checkLanes(_ t: Int, expected: Int) {
        precondition(
            Int(tN[t]) == expected,
            "property \(tMeta[t].prop.rawValue) of \(tMeta[t].node) was created with \(tN[t]) lanes, used with \(expected)"
        )
    }

    internal func laneTargets4(_ t: Int) -> (Float, Float, Float, Float) {
        let l0 = Int(tLane0[t])
        return (finalTarget(l0), finalTarget(l0 + 1), finalTarget(l0 + 2), finalTarget(l0 + 3))
    }

    internal mutating func setRaw(_ t: UInt32, lanes: MotionLanes, count n: Int) {
        let ti = Int(t)
        let l0 = Int(tLane0[ti])
        for i in 0..<n {
            let l = l0 + i
            let x = lanes[i]
            cancelPending(l)
            freeExtra(l)
            lLayer[l] = .rest
            lTarget[l] = x
            lValue[l] = x
            lVel[l] = 0.0
            lCurve[l] = .instant
        }
        tNextDue[ti] = .infinity
        tSettleAt[ti] = -.infinity
        takeToken(ti, finished: false)
        tMeta[ti].epoch &+= 1
        if tSlot[ti] != Self.none {
            let slot = Int(tSlot[ti])
            deactivate(ti, slot: slot)
        }
        setTouched.append(TrackId(index: t, generation: tMeta[ti].generation))
    }

    @discardableResult
    internal mutating func animateRaw(
        _ t: Int,
        targets: MotionLanes,
        count n: Int,
        curve authoredCurve: Curve,
        blend authoredBlend: Blend,
        delay authoredDelay: Float,
        velocityRule: VelocityRule,
        token: UInt64,
        laneVelocities: MotionLanes?
    ) -> Bool {
        let trackNow = timeOf(t)
        if tNextDue[t] <= trackNow {
            applyDue(t, now: trackNow)
        }
        let propClass = tMeta[t].propClass
        let curve = reducedMotion ? propClass.forReducedMotion(authoredCurve) : authoredCurve
        let eps = propClass.eps(pixelScale: _pixelScale)
        let blend: Blend = (authoredBlend == .auto) ? curve.defaultBlend : authoredBlend
        let delay = max(0, authoredDelay)
        let isDecay: Bool
        if case .decay = curve { isDecay = true } else { isDecay = false }
        let isSpring: Bool
        if case .spring = curve { isSpring = true } else { isSpring = false }

        let l0 = Int(tLane0[t])
        var changed = false
        for i in 0..<n {
            let l = l0 + i
            let target = targets[i]
            let vel: Float?
            if let lv = laneVelocities {
                // NaN means "no velocity of its own" (inherit), as `Pending.velocity` does: a
                // per-lane call can then restart some lanes with a velocity and leave the rest,
                // whose target it repeats, untouched.
                vel = lv[i].isNaN ? nil : lv[i]
            } else {
                switch velocityRule {
                case .inherit: vel = nil
                case .zero: vel = 0.0
                case .uniform(let u): vel = u
                }
            }
            if vel == nil && !isDecay && finalTarget(l) == target {
                continue
            }
            changed = true
            cancelPending(l)
            if delay > 0.0 {
                pushPending(
                    l,
                    Pending(
                        at: trackNow + Double(delay),
                        target: target,
                        velocity: vel ?? .nan,
                        curve: curve,
                        blend: blend,
                        next: Self.none
                    )
                )
            } else {
                let recordAudit: Float?
                let shouldAudit: Bool
                switch auditMode {
                case .disabled: shouldAudit = false
                case .spatialOnly: shouldAudit = propClass == .spatial && isSpring && vel == nil && lLayer[l].end > trackNow
                case .allSprings: shouldAudit = isSpring && vel == nil && lLayer[l].end > trackNow
                }
                recordAudit = shouldAudit ? sampleLane(l, at: trackNow).1 : nil
                startLane(l, at: trackNow, target: target, curve: curve, blend: blend, vel: vel, eps: eps)
                if let before = recordAudit {
                    let error = abs(sampleLane(l, at: trackNow).1 - before)
                    audit.lanes += 1
                    audit.maxVelocityError = max(audit.maxVelocityError, error)
                }
            }
        }
        if changed {
            let end = trackNow + Double(delay) + Double(curve.logicalDuration)
            commitScheduled(t, logicalAt: end, token: token)
        } else if token != 0 {
            if tSlot[t] == Self.none {
                let m = tMeta[t]
                eventCarry.push(.completed(token: token, node: m.node, prop: m.prop, finished: true))
            } else {
                takeToken(t, finished: false)
                tMeta[t].token = token
            }
        }
        return changed
    }

    internal mutating func startLane(
        _ l: Int,
        at: Double,
        target: Float,
        curve: Curve,
        blend: Blend,
        vel: Float?,
        eps: Eps
    ) {
        let (x, v) = sampleLane(l, at: at)
        lCurve[l] = curve
        if case .snap = blend {
            freeExtra(l)
            lLayer[l] = .rest
            lTarget[l] = target
            return
        }
        switch curve {
        case .instant:
            freeExtra(l)
            lLayer[l] = .rest
            lTarget[l] = target

        case .decay(let d):
            let v0 = vel ?? v
            freeExtra(l)
            lTarget[l] = x + v0 / d.rate
            lLayer[l] = Layer.decay(rate: d.rate, at: at, velocity: v0, eps: eps)

        default:
            if blend == .additive {
                let old = lTarget[l]
                lTarget[l] = target
                let layer = Layer.start(
                    curve: curve,
                    at: at,
                    offset: old - target,
                    velocity: vel.map { $0 - v } ?? 0.0,
                    eps: eps
                )
                pushLayer(l, layer: layer, at: at)
            } else {
                freeExtra(l)
                lTarget[l] = target
                lLayer[l] = Layer.start(
                    curve: curve,
                    at: at,
                    offset: x - target,
                    velocity: vel ?? v,
                    eps: eps
                )
            }
        }
    }

    private mutating func pushLayer(_ l: Int, layer: Layer, at: Double) {
        if layer.kind == .rest { return }
        if lLayer[l].kind == .rest || lLayer[l].end <= at {
            lLayer[l] = layer
            return
        }
        var count = 1
        var m = lMore[l]
        while m != Self.none {
            count += 1
            m = extra[Int(m)].next
        }
        if count >= Self.maxAdditive {
            let (x, v) = sampleLane(l, at: at)
            let (o, ov) = layer.sample(at: at)
            freeExtra(l)
            let target = lTarget[l]
            let curve = lCurve[l]
            lLayer[l] = Layer.start(
                curve: curve,
                at: at,
                offset: (x + o) - target,
                velocity: v + ov,
                eps: Eps(pos: 1e-4, vel: 1e-3)
            )
            return
        }
        let idx = allocExtra(Extra(layer: layer, next: lMore[l]))
        lMore[l] = idx
    }

    @inline(__always)
    internal func sampleLane(_ l: Int, at: Double) -> (Float, Float) {
        var (o, v) = lLayer[l].sample(at: at)
        var m = lMore[l]
        while m != Self.none {
            let e = extra[Int(m)]
            let (a, b) = e.layer.sample(at: at)
            o += a
            v += b
            m = e.next
        }
        return (lTarget[l] + o, v)
    }

    private mutating func sampleExtra(_ l: Int, now: Double) -> (Float, Float) {
        var o: Float = 0
        var v: Float = 0
        var prev = Self.none
        var m = lMore[l]
        while m != Self.none {
            let mi = Int(m)
            let e = extra[mi]
            if now >= e.layer.end {
                if prev == Self.none {
                    lMore[l] = e.next
                } else {
                    extra[Int(prev)].next = e.next
                }
                extra[mi].next = extraFree
                extraFree = m
            } else {
                let (a, b) = e.layer.sample(at: now)
                o += a
                v += b
                prev = m
            }
            m = e.next
        }
        return (o, v)
    }

    internal func finalTarget(_ l: Int) -> Float {
        var p = lPending[l]
        var t = lTarget[l]
        while p != Self.none {
            let pe = pending[Int(p)]
            t = pe.target
            p = pe.next
        }
        return t
    }

    private mutating func applyDue(_ t: Int, now: Double) {
        let l0 = Int(tLane0[t])
        let n = Int(tN[t])
        let eps = tMeta[t].propClass.eps(pixelScale: _pixelScale)
        for l in l0..<(l0 + n) {
            while true {
                let p = lPending[l]
                if p == Self.none || pending[Int(p)].at > now { break }
                let pi = Int(p)
                let ev = pending[pi]
                lPending[l] = ev.next
                pending[pi].next = pendingFree
                pendingFree = p
                let vel: Float? = ev.velocity.isNaN ? nil : ev.velocity
                startLane(l, at: ev.at, target: ev.target, curve: ev.curve, blend: ev.blend, vel: vel, eps: eps)
            }
        }
        recompute(t)
    }

    internal mutating func recompute(_ t: Int) {
        let l0 = Int(tLane0[t])
        let n = Int(tN[t])
        var due = Double.infinity
        var settle = -Double.infinity
        for l in l0..<(l0 + n) {
            let p = lPending[l]
            if p != Self.none {
                due = min(due, pending[Int(p)].at)
            }
            if lLayer[l].kind != .rest {
                settle = max(settle, lLayer[l].end)
            }
            var m = lMore[l]
            while m != Self.none {
                let e = extra[Int(m)]
                settle = max(settle, e.layer.end)
                m = e.next
            }
        }
        tNextDue[t] = due
        tSettleAt[t] = settle
        resample(t)
    }

    private mutating func settle(_ t: Int) {
        let l0 = Int(tLane0[t])
        let n = Int(tN[t])
        for l in l0..<(l0 + n) {
            freeExtra(l)
            lLayer[l] = .rest
            lValue[l] = lTarget[l]
            lVel[l] = 0.0
        }
        let m = tMeta[t]
        eventCarry.push(.settled(track: idOf(t), node: m.node, prop: m.prop))
        takeToken(t, finished: true)
    }

    private mutating func takeToken(_ t: Int, finished: Bool) {
        let token = tMeta[t].token
        if token != 0 {
            tMeta[t].token = 0
            eventCarry.push(.completed(token: token, node: tMeta[t].node, prop: tMeta[t].prop, finished: finished))
        }
    }

    private mutating func activate(_ t: Int) {
        if tSlot[t] == Self.none {
            tSlot[t] = UInt32(activeIndices.count)
            activeIndices.append(UInt32(t))
        }
    }

    private mutating func deactivate(_ t: Int, slot: Int) {
        let last = activeIndices.count - 1
        if slot != last {
            let moved = activeIndices[last]
            activeIndices[slot] = moved
            tSlot[Int(moved)] = UInt32(slot)
        }
        activeIndices.removeLast()
        tSlot[t] = Self.none
    }

    internal mutating func pushPending(_ l: Int, _ ev: Pending) {
        var entry = ev
        var prev = Self.none
        var cur = lPending[l]
        while cur != Self.none && pending[Int(cur)].at <= entry.at {
            prev = cur
            cur = pending[Int(cur)].next
        }
        entry.next = cur
        let idx: UInt32
        if pendingFree != Self.none {
            let i = pendingFree
            pendingFree = pending[Int(i)].next
            pending[Int(i)] = entry
            idx = i
        } else {
            pending.append(entry)
            idx = UInt32(pending.count - 1)
        }
        if prev == Self.none {
            lPending[l] = idx
        } else {
            pending[Int(prev)].next = idx
        }
    }

    internal mutating func schedule(
        _ t: Int,
        lane: Int,
        at: Double,
        target: Float,
        curve: Curve,
        blend: Blend,
        velocity: Float?
    ) {
        let l = Int(tLane0[t]) + lane
        pushPending(
            l,
            Pending(
                at: at,
                target: target,
                velocity: velocity ?? .nan,
                curve: curve,
                blend: blend,
                next: Self.none
            )
        )
    }

    internal mutating func cancelTrackPending(_ t: Int) {
        let l0 = Int(tLane0[t])
        let n = Int(tN[t])
        for l in l0..<(l0 + n) {
            cancelPending(l)
        }
    }

    internal mutating func commitScheduled(_ t: Int, logicalAt: Double, token: UInt64) {
        takeToken(t, finished: false)
        tMeta[t].token = token
        tMeta[t].logicalAt = logicalAt
        tMeta[t].epoch &+= 1
        recompute(t)
        activate(t)
        starts.append(idOf(t))
    }

    private mutating func cancelPending(_ l: Int) {
        var p = lPending[l]
        while p != Self.none {
            let pi = Int(p)
            let next = pending[pi].next
            pending[pi].next = pendingFree
            pendingFree = p
            p = next
        }
        lPending[l] = Self.none
    }

    private mutating func allocExtra(_ e: Extra) -> UInt32 {
        if extraFree != Self.none {
            let i = extraFree
            extraFree = extra[Int(i)].next
            extra[Int(i)] = e
            return i
        }
        extra.append(e)
        return UInt32(extra.count - 1)
    }

    private mutating func freeExtra(_ l: Int) {
        var m = lMore[l]
        while m != Self.none {
            let mi = Int(m)
            let next = extra[mi].next
            extra[mi].next = extraFree
            extraFree = m
            m = next
        }
        lMore[l] = Self.none
    }

    private mutating func unlinkNode(_ node: NodeId, t: UInt32) {
        let head = nodeHead[node.rawValue] ?? Self.none
        if head == t {
            let next = tMeta[Int(t)].nodeNext
            if next == Self.none {
                nodeHead.removeValue(forKey: node.rawValue)
            } else {
                nodeHead[node.rawValue] = next
            }
            return
        }
        var cur = head
        while cur != Self.none {
            let ci = Int(cur)
            let next = tMeta[ci].nodeNext
            if next == t {
                tMeta[ci].nodeNext = tMeta[Int(t)].nodeNext
                return
            }
            cur = next
        }
    }

    private mutating func freeTrack(_ t: Int) {
        guard tMeta[t].alive else { return }
        let l0 = Int(tLane0[t])
        let n = Int(tN[t])
        for l in l0..<(l0 + n) {
            cancelPending(l)
            freeExtra(l)
        }
        if tSlot[t] != Self.none {
            deactivate(t, slot: Int(tSlot[t]))
        }
        let m = tMeta[t]
        index.removeValue(forKey: Key(node: m.node.rawValue, prop: m.prop.rawValue))
        laneFree[n].append(UInt32(l0))
        takeToken(t, finished: false)
        tMeta[t].alive = false
        trackFree.append(UInt32(t))
    }
}

extension PropClass {
    @inlinable
    internal func eps(pixelScale: Float) -> Eps {
        let t = settleThresholds(pixelScale: pixelScale)
        return Eps(pos: t.pos, vel: t.vel)
    }
}
