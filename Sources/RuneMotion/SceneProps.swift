import Foundation

extension Scene {
    // MARK: - Properties & Tracks

    /// Animates one property of a scene node (`Props.OPACITY`, `Props.RADIUS`, ..., or a custom one).
    /// The first animation starts from the node's base value.
    public mutating func animate<T: Animatable>(
        _ id: NodeId,
        _ prop: Prop<T>,
        to target: T,
        anim: Anim<T>
    ) {
        guard let i = slot(id) else { return }
        if !atBase(i, prop, target) {
            ensureProp(i, prop)
            trackAnimate(i, prop, target, anim)
        }
        let bits = TraceIntent.forProp(prop.id)
        intent(id, bits, anim.curve.logicalDuration)
    }

    /// Convenience overload accepting a `Spring`.
    public mutating func animate<T: Animatable>(
        _ id: NodeId,
        _ prop: Prop<T>,
        to target: T,
        spring: Spring,
        delay: Float = 0
    ) {
        animate(id, prop, to: target, anim: Anim(curve: Curve.from(spring), delay: delay))
    }

    /// Puts the node at `frame` immediately, ending any motion toward another.
    public mutating func landFrame(_ id: NodeId, _ frame: MotionRect) {
        guard let i = slot(id) else { return }
        let old = nodes[i].frame
        if old == frame && nodes[i].path == nil && !store.isAnimating(id, Props.FRAME) {
            return
        }
        if frame.width != old.width {
            rebaseTrailing(i, dw: frame.width - old.width)
        }
        endPath(i)
        nodes[i].frame = frame
        trackSet(i, Props.FRAME, frame)
        nodes[i].dirty = true
    }

    /// Sets a property immediately (direct manipulation).
    public mutating func set<T: Animatable>(_ id: NodeId, _ prop: Prop<T>, _ value: T) {
        if inFlightTo(id, prop, value) {
            return
        }
        guard let i = slot(id), !atBase(i, prop, value) else { return }
        trackSet(i, prop, value)
    }

    /// The property's presented/stored value, falling back to the node's base value.
    public func get<T: Animatable>(_ id: NodeId, _ prop: Prop<T>) -> T? {
        guard let i = slot(id) else { return nil }
        return store.get(id, prop) ?? baseValue(i, prop)
    }

    /// True when `id` is `ScenePhase.present` at `frame` with no screen-space path and no active track.
    @inline(__always)
    public func isRestingAt(_ id: NodeId, _ frame: MotionRect) -> Bool {
        guard let i = slot(id) else { return false }
        let n = nodes[i]
        let frameAtRest: MotionRect
        if let vals = values(i, Props.FRAME.id), vals.count >= 4 {
            let b = vals.startIndex
            frameAtRest = MotionRect.fromEdges(vals[b], vals[b + 1], vals[b + 2], vals[b + 3])
        } else {
            frameAtRest = n.frame
        }
        return n.presence.isResting
            && n.path == nil
            && frameAtRest == frame
            && (store.activeLen == 0 || !store.isNodeAnimating(id))
    }

    internal mutating func ensureProp<T: Animatable>(_ i: Int, _ prop: Prop<T>) {
        if !hasTrack(i, prop), let base: T = baseValue(i, prop) {
            trackSet(i, prop, base)
        }
    }

    internal func hasTrack<T: Animatable>(_ i: Int, _ prop: Prop<T>) -> Bool {
        let pid = Int(prop.id.rawValue)
        if pid < nodes[i].tracks.count, nodes[i].tracks[pid] != nil {
            return true
        }
        return store.has(nodes[i].id, prop)
    }

    /// True when the property has no track yet and `value` already equals its base value.
    internal func atBase<T: Animatable>(_ i: Int, _ prop: Prop<T>, _ value: T) -> Bool {
        guard !hasTrack(i, prop), let a = baseLanes(i, prop.id) else { return false }
        let b = value.toLanes()
        for k in 0..<T.laneCount {
            if a[k] != b[k] { return false }
        }
        return true
    }

    internal func baseLanes(_ i: Int, _ propId: PropId) -> MotionLanes? {
        let n = nodes[i]
        switch propId {
        case Props.OPACITY.id:
            return MotionLanes(n.opacity, 0, 0, 0)
        case Props.UNIFORM_SCALE.id, Props.PRESENCE.id:
            return MotionLanes(1.0, 0, 0, 0)
        case Props.SCALE.id:
            return MotionLanes(n.baseScale2D.x, n.baseScale2D.y, 0, 0)
        case Props.FRAME.id:
            return n.frame.toLanes()
        case Props.CORNERS.id:
            return n.radius.toLanes()
        case Props.FILL.id:
            return n.fill.toLanes()
        case Props.BORDER.id:
            return n.border.toLanes()
        case Props.OFFSET.id:
            return MotionLanes(n.baseOffset.x, n.baseOffset.y, 0, 0)
        case Props.ROTATE.id:
            return MotionLanes(n.baseRotate, 0, 0, 0)
        case Props.BLUR_SCALAR.id, Props.BLUR.id:
            return MotionLanes(n.baseBlur, 0, 0, 0)
        case Props.MASK.id:
            return MotionLanes.zero
        default:
            return nil
        }
    }

    internal func baseValue<T: Animatable>(_ i: Int, _ prop: Prop<T>) -> T? {
        if prop.id == Props.FILL.id, let v = nodes[i].fill as? T {
            return v
        }
        if prop.id == Props.BORDER.id, let v = nodes[i].border as? T {
            return v
        }
        return baseLanes(i, prop.id).map(T.fromLanes)
    }

    internal func currentValue<T: Animatable>(_ i: Int, _ prop: Prop<T>) -> T? {
        let pid = Int(prop.id.rawValue)
        guard pid < nodes[i].tracks.count, let tid = nodes[i].tracks[pid] else { return nil }
        guard let (x, _) = sample(tid) else { return nil }
        var lanes = MotionLanes.zero
        for k in 0..<T.laneCount {
            lanes[k] = x[k]
        }
        return T.fromLanes(lanes)
    }

    internal mutating func trackSet<T: Animatable>(_ i: Int, _ prop: Prop<T>, _ value: T) {
        let (tid, changed) = store.setChanged(nodes[i].id, prop, value)
        recordTrack(i, prop.id, tid, changed: changed)
    }

    internal mutating func trackAnimate<T: Animatable>(
        _ i: Int,
        _ prop: Prop<T>,
        _ target: T,
        _ anim: Anim<T>
    ) {
        let (tid, changed) = store.animateChanged(nodes[i].id, prop, to: target, anim: anim)
        recordTrack(i, prop.id, tid, changed: changed)
    }

    internal mutating func recordTrack(_ i: Int, _ propId: PropId, _ tid: TrackId, changed: Bool) {
        let pid = Int(propId.rawValue)
        if pid < nodes[i].tracks.count {
            nodes[i].tracks[pid] = tid
        }
        if changed {
            nodes[i].dirty = true
        }
    }

    internal mutating func intent(_ id: NodeId, _ bits: UInt32, _ seconds: Float) {
        if trace != nil {
            intents.append((id, bits, seconds))
        }
    }
}
