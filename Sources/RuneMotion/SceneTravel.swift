import Foundation

extension Scene {
    // MARK: - Matched Geometry & Screen Travel

    /// Shared-element handoff: `from` exits immediately while `to` flies from `from`'s exact
    /// root-space rect, corner radius, and fill to its own layout on a straight screen-space path.
    public mutating func matchGeometry(_ from: NodeId, _ to: NodeId, _ anim: LayoutAnim) {
        matchGeometryOffset(from, to, anim, drawnOffset: .zero, drawnVelocity: .zero)
    }

    /// `matchGeometry` starting from where `from` was drawn if shifted by scroll/gesture velocity.
    public mutating func matchGeometryOffset(
        _ from: NodeId,
        _ to: NodeId,
        _ anim: LayoutAnim,
        drawnOffset: Vec2,
        drawnVelocity: Vec2
    ) {
        guard let f = slot(from), let t = slot(to) else { return }
        if store.reducedMotion {
            remove(from)
            let acts = nodes[t].phaseStep(.fadeIn(transition: nodes[t].transition))
            applyPhaseActs(t, acts)
            return
        }
        let (fe, fv) = exactWorld(f)
        var start = MotionRect.fromEdges(fe.0, fe.1, fe.2, fe.3)
        start = start.translated(drawnOffset)
        let vStart: (Float, Float, Float, Float) = (
            fv.0 + drawnVelocity.x,
            fv.1 + drawnVelocity.y,
            fv.2 + drawnVelocity.x,
            fv.3 + drawnVelocity.y
        )
        let radius: Corners = currentValue(f, Props.CORNERS) ?? nodes[f].radius
        let fill: MotionColor = currentValue(f, Props.FILL) ?? nodes[f].fill
        let toRadius = nodes[t].radius
        let toFill = nodes[t].fill

        let acts = nodes[t].phaseStep(.appear(transition: nodes[t].transition))
        applyPhaseActs(t, acts)

        startPath(t, start: start, velocity: vStart, anim: anim)
        trackSet(t, Props.CORNERS, radius)
        trackAnimate(
            t,
            Props.CORNERS,
            toRadius,
            Anim<Corners>(
                curve: anim.x.curve,
                blend: anim.x.blend,
                delay: anim.x.delay,
                velocityRule: anim.x.velocityRule,
                token: anim.x.token
            )
        )
        trackSet(t, Props.FILL, fill)
        trackAnimate(
            t,
            Props.FILL,
            toFill,
            Anim<MotionColor>(
                curve: anim.y.curve,
                blend: anim.y.blend,
                delay: anim.y.delay,
                velocityRule: anim.y.velocityRule,
                token: anim.y.token
            )
        )
        intent(to, TraceIntent.position | TraceIntent.size | TraceIntent.shape, anim.y.curve.logicalDuration)
        removeNow(f)
    }

    /// Launches `id` on a straight screen-space flight from root-space rect `from` to its current frame.
    public mutating func launch(_ id: NodeId, from: MotionRect, anim: LayoutAnim) {
        guard let i = slot(id), !store.reducedMotion else { return }
        let acts = nodes[i].phaseStep(.appear(transition: nodes[i].transition))
        applyPhaseActs(i, acts)
        startPath(i, start: from, velocity: (0, 0, 0, 0), anim: anim)
        intent(id, TraceIntent.position, anim.y.curve.logicalDuration)
    }

    /// `setFrame` with screen travel for a node drawn `offset`/`velocity` away from its scene rect.
    public mutating func retargetDrawn(
        _ id: NodeId,
        _ frame: MotionRect,
        _ anim: LayoutAnim,
        offset: Vec2,
        velocity: Vec2
    ) {
        setFrameDrawn(id, frame, anim, drawnOffset: offset, drawnVelocity: velocity)
    }

    /// How far node `id`'s screen path draws its top-left corner from where its layout under
    /// its parent's presented origin would, and how much faster it moves it (root space).
    /// Returns `nil` without a path, or while the path still draws it at another size.
    public func pathLead(_ id: NodeId) -> [Vec2]? {
        guard let i = slot(id), let path = nodes[i].path else { return nil }
        let on = pathDual(i, path: path, origin: path.origin)
        let laid = laidDual(i)
        let q = 1.0 / (64.0 * store.pixelScale)
        let wOn = on.2.x - on.0.x
        let hOn = on.3.x - on.1.x
        let wLaid = laid.2.x - laid.0.x
        let hLaid = laid.3.x - laid.1.x
        if abs(wOn - wLaid) > q || abs(hOn - hLaid) > q {
            return nil
        }
        var relativeVelocity = Vec2(on.0.v - laid.0.v, on.1.v - laid.1.v)
        if let endpoint = launchEndpoints[id], let travel = get(id, Props.TRAVEL) {
            // The launch moves with its endpoint by its travel fraction. The layout
            // it would land on moves with the whole endpoint.
            relativeVelocity.x -= (1 - travel.x) * endpoint.velocity.x
            relativeVelocity.y -= (1 - travel.y) * endpoint.velocity.y
        }
        return [Vec2(on.0.x - laid.0.x, on.1.x - laid.1.x), relativeVelocity]
    }

    /// Ends node `id`'s screen travel at its layout: it then shows under its parent's presented origin.
    public mutating func landPath(_ id: NodeId) {
        guard let i = slot(id), let path = nodes[i].path else { return }
        endPath(i)
        trackSet(i, Props.FRAME, path.endLocal)
        nodes[i].dirty = true
    }

    /// Starts or updates screen-space path for slot `i`.
    internal mutating func startPath(
        _ i: Int,
        start: MotionRect,
        velocity: (Float, Float, Float, Float),
        anim: LayoutAnim
    ) {
        let origin = parentTargetOrigin(i)
        let endLocal = nodes[i].frame
        let endWorld = endLocal.translated(origin)
        let isNew = nodes[i].path == nil
        nodes[i].path = ScreenPath(start: start, endLocal: endLocal, origin: origin)
        if isNew {
            travelling.append(UInt32(i))
        }

        // Project edge velocities onto each axis' path to keep velocity continuous.
        let vProg = axisProgressVelocity(start: start, end: endWorld, vel: velocity)
        let ti = store.ensure(nodes[i].id, Props.TRAVEL.id, .scale, initLanes: .zero, count: 2)
        store.setRaw(ti, lanes: .zero, count: 2)
        let tid = store.idOf(Int(ti))
        recordTrack(i, Props.TRAVEL.id, tid, changed: true)

        store.animateRaw(
            Int(ti),
            targets: MotionLanes(1.0, 0.0),
            count: 2,
            curve: anim.x.curve,
            blend: anim.x.blend,
            delay: anim.x.delay,
            velocityRule: .inherit,
            token: anim.x.token,
            laneVelocities: MotionLanes(vProg.x, 0.0)
        )
        store.animateRaw(
            Int(ti),
            targets: MotionLanes(1.0, 1.0),
            count: 2,
            curve: anim.y.curve,
            blend: anim.y.blend,
            delay: anim.y.delay,
            velocityRule: .inherit,
            token: anim.y.token,
            laneVelocities: MotionLanes(vProg.x, vProg.y)
        )
        if nodes[i].tracks[Int(Props.FRAME.id.rawValue)] != nil {
            trackSet(i, Props.FRAME, endLocal)
        }
        nodes[i].dirty = true
    }

    internal mutating func endPath(_ i: Int) {
        guard nodes[i].path != nil else { return }
        nodes[i].path = nil
        launchEndpoints.removeValue(forKey: nodes[i].id)
        if let tid = nodes[i].tracks[Int(Props.TRAVEL.id.rawValue)] {
            store.remove(nodes[i].id, Props.TRAVEL)
            nodes[i].tracks[Int(Props.TRAVEL.id.rawValue)] = nil
            _ = tid
        }
        travelling.removeAll { Int($0) == i }
    }

    internal func laidDual(_ i: Int) -> (SceneDual, SceneDual, SceneDual, SceneDual) {
        let p = nodes[i].parent
        let parentOrigin: (SceneDual, SceneDual)
        if p == Self.noneIdx {
            parentOrigin = (.c(0), .c(0))
        } else {
            let po = originDual(Int(p))
            parentOrigin = po
        }
        var local: (SceneDual, SceneDual, SceneDual, SceneDual)
        if let tid = nodes[i].tracks[Int(Props.FRAME.id.rawValue)], let (x, v) = sample(tid) {
            local = (SceneDual(x: x[0], v: v[0]), SceneDual(x: x[1], v: v[1]),
                     SceneDual(x: x[2], v: v[2]), SceneDual(x: x[3], v: v[3]))
        } else {
            let e = nodes[i].frame.edges
            local = (.c(e.0), .c(e.1), .c(e.2), .c(e.3))
        }
        let trail = trailDual(i)
        let poX = parentOrigin.0.add(SceneDual(x: trail.x, v: trail.v))
        let poY = parentOrigin.1
        return (
            local.0.add(poX),
            local.1.add(poY),
            local.2.add(poX),
            local.3.add(poY)
        )
    }

    internal func startPathDual(start: MotionRect, end: MotionRect, progress: (SceneDual, SceneDual)) -> (SceneDual, SceneDual, SceneDual, SceneDual) {
        let s = start.edges
        let e = end.edges
        return (
            SceneDual.c(s.0).add(SceneDual.c(e.0 - s.0).mul(progress.0)),
            SceneDual.c(s.1).add(SceneDual.c(e.1 - s.1).mul(progress.1)),
            SceneDual.c(s.2).add(SceneDual.c(e.2 - s.2).mul(progress.0)),
            SceneDual.c(s.3).add(SceneDual.c(e.3 - s.3).mul(progress.1))
        )
    }

    internal func axisProgressVelocity(
        start: MotionRect,
        end: MotionRect,
        vel: (Float, Float, Float, Float)
    ) -> Vec2 {
        func axisRate(s0: Float, s1: Float, e0: Float, e1: Float, v0: Float, v1: Float) -> Float {
            let d0 = e0 - s0
            let d1 = e1 - s1
            let len2 = d0 * d0 + d1 * d1
            return len2 < 1e-6 ? 0.0 : (v0 * d0 + v1 * d1) / len2
        }
        return Vec2(
            axisRate(s0: start.left, s1: start.right, e0: end.left, e1: end.right, v0: vel.0, v1: vel.2),
            axisRate(s0: start.top, s1: start.bottom, e0: end.top, e1: end.bottom, v0: vel.1, v1: vel.3)
        )
    }
}
