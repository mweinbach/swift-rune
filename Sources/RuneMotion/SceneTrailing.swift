import Foundation

extension Scene {
    /// Holds children whose x trails the parent's width (right-aligned icons/controls) against
    /// the parent's trailing edge while its width animates.
    public mutating func setRideTrailing(_ id: NodeId, _ on: Bool) {
        guard let i = slot(id) else { return }
        if nodes[i].rideTrailing != on {
            nodes[i].rideTrailing = on
            nodes[i].dirty = true
        }
    }

    /// When a parent's width changes by `dw`, shifts any `rideTrailing` child's `frame` track
    /// horizontally by `dw` so the child doesn't start a separate horizontal slide.
    internal mutating func rebaseTrailing(_ parentIdx: Int, dw: Float) {
        if dw == 0 { return }
        var c = nodes[parentIdx].firstChild
        while c != Self.noneIdx {
            let ci = Int(c)
            if nodes[ci].rideTrailing {
                nodes[ci].frame = nodes[ci].frame.translated(Vec2(dw, 0))
                if var path = nodes[ci].path {
                    path.endLocal = path.endLocal.translated(Vec2(dw, 0))
                    nodes[ci].path = path
                }
                nodes[ci].dirty = true
                if let tid = nodes[ci].tracks[Int(Props.FRAME.id.rawValue)] {
                    store.translateTrack(tid, delta: MotionLanes(dw, 0, dw, 0), count: 4)
                }
            }
            c = nodes[ci].nextSibling
        }
    }

    /// Additional X offset (and its time derivative) added to a trailing-riding node from its parent's width delta.
    internal func trailDual(_ i: Int) -> (x: Float, v: Float) {
        guard nodes[i].rideTrailing else { return (0, 0) }
        let p = nodes[i].parent
        guard p != Self.noneIdx else { return (0, 0) }
        let pi = Int(p)
        let pf: (x: Float, v: Float, w: Float, vw: Float)
        if let path = nodes[pi].path {
            let e = pathDual(pi, path: path, origin: parentTargetOrigin(pi))
            pf = (e.0.x, e.0.v, e.2.x - e.0.x, e.2.v - e.0.v)
        } else if let tid = nodes[pi].tracks[Int(Props.FRAME.id.rawValue)], let (x, v) = sample(tid) {
            pf = (x[0], v[0], x[2] - x[0], v[2] - v[0])
        } else {
            return (0, 0)
        }
        return (pf.w - nodes[pi].frame.width, pf.vw)
    }
}
