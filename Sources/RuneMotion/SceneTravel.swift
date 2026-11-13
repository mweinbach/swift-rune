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

        if radius != nodes[t].radius {
            trackSet(t, Props.CORNERS, radius)
            trackAnimate(t, Props.CORNERS, nodes[t].radius, Anim(curve: anim.x.curve))
        }
        if fill != nodes[t].fill {
            trackSet(t, Props.FILL, fill)
            trackAnimate(t, Props.FILL, nodes[t].fill, Anim(curve: anim.x.curve))
        }

        // Replaced absent look: target is present immediately and keeps whatever exit-at-1 look existed.
        if !nodes[t].presence.isPresent {
            nodes[t].presence.setPair(fxIdentity, nodes[t].presence.pair.1)
            nodes[t].presence = .present(at0: fxIdentity, at1: nodes[t].presence.pair.1)
            if hasTrack(t, Props.PRESENCE) || nodes[t].tracks[Int(Props.PRESENCE.id.rawValue)] != nil {
                trackSet(t, Props.PRESENCE, 1.0)
            }
        }
        nodes[t].dirty = true

        // Drop `from` immediately (if alive) so two copies never draw on top of each other.
        removeNow(f)

        guard let tAfter = slot(to) else { return }
        if !store.reducedMotion {
            let endRect = nodes[tAfter].frame.translated(parentTargetOrigin(tAfter))
            if start != endRect {
                startPath(tAfter, start: start, velocity: vStart, anim: anim)
            }
        }
    }

    /// Launches `id` on a straight screen-space flight from root-space rect `from` to its current frame.
    public mutating func launch(_ id: NodeId, from: MotionRect, anim: LayoutAnim) {
        guard let i = slot(id), !store.reducedMotion else { return }
        let endRect = nodes[i].frame.translated(parentTargetOrigin(i))
        if from == endRect { return }
        startPath(i, start: from, velocity: (0, 0, 0, 0), anim: anim)
    }

    /// Restarts an in-flight screen path cleanly if the drawn element shifted while mid-flight.
    public mutating func retargetDrawn(_ id: NodeId, offset: Vec2, velocity: Vec2) {
        guard let i = slot(id), let path = nodes[i].path else { return }
        let e = pathDual(i, path: path, origin: path.origin)
        var cur = MotionRect.fromEdges(e.0.x, e.1.x, e.2.x, e.3.x)
        cur = cur.translated(offset)
        let vel: (Float, Float, Float, Float) = (
            e.0.v + velocity.x,
            e.1.v + velocity.y,
            e.2.v + velocity.x,
            e.3.v + velocity.y
        )
        let endWorld = path.endLocal.translated(path.origin)
        if cur == endWorld {
            return
        }
        // Keep current curve/duration on TRAVEL track.
        let travelAnim = LayoutAnim(x: Anim<Float>(curve: .spring(MotionTokens.SMOOTH)))
        startPath(i, start: cur, velocity: vel, anim: travelAnim)
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

        // Convert world edge velocities to axis progress velocities `(vx, vy)`.
        let vProg = axisProgressVelocity(start: start, end: endWorld, vel: velocity)
        let ti = store.ensure(nodes[i].id, Props.TRAVEL.id, .scale, initLanes: .zero, count: 2)
        store.setRaw(ti, lanes: .zero, count: 2)
        let tid = store.idOf(Int(ti))
        recordTrack(i, Props.TRAVEL.id, tid, changed: true)

        var xAnim = anim.x
        var yAnim = anim.y
        if let lead = anim.lead {
            xAnim = (endWorld.left + endWorld.right >= start.left + start.right) ? lead.0 : anim.x
            yAnim = (endWorld.top + endWorld.bottom >= start.top + start.bottom) ? lead.0 : anim.y
        }

        // Animate X then Y lanes on TRAVEL so each axis can have its own curve.
        let lv = MotionLanes(vProg.x, vProg.y)
        store.animateRaw(
            Int(ti),
            targets: MotionLanes(1.0, 0.0),
            count: 2,
            curve: xAnim.curve,
            blend: xAnim.blend,
            delay: xAnim.delay,
            velocityRule: .inherit,
            token: xAnim.token,
            laneVelocities: lv
        )
        store.animateRaw(
            Int(ti),
            targets: MotionLanes(1.0, 1.0),
            count: 2,
            curve: yAnim.curve,
            blend: yAnim.blend,
            delay: yAnim.delay,
            velocityRule: .inherit,
            token: yAnim.token,
            laneVelocities: lv
        )
        nodes[i].dirty = true
    }

    internal mutating func endPath(_ i: Int) {
        guard nodes[i].path != nil else { return }
        nodes[i].path = nil
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
            if abs(d0) >= abs(d1) {
                return abs(d0) > 1e-4 ? v0 / d0 : 0.0
            } else {
                return abs(d1) > 1e-4 ? v1 / d1 : 0.0
            }
        }
        return Vec2(
            axisRate(s0: start.left, s1: start.right, e0: end.left, e1: end.right, v0: vel.0, v1: vel.2),
            axisRate(s0: start.top, s1: start.bottom, e0: end.top, e1: end.bottom, v0: vel.1, v1: vel.3)
        )
    }
}
