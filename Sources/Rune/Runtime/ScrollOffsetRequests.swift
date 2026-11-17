import Foundation
import RuneMotion

// MARK: - App offset requests (`crates/rune/src/runtime/scroll/offset.rs`)

extension Runtime {
    /// How many viewports out a long glide starts: farther, it cuts to there first and glides
    /// the rest (`scroll/bottom.rs::GLIDE_REACH`, read by `offset.rs::scroll_to_offsets`).
    internal static var scrollGlideReach: Double { 2.0 }

    /// Moves viewport `path` to `next`, clamped to its content: on `glide` (motion on and not a
    /// cut) the scroll track springs there, otherwise the offset lands at once. `animNow` is the
    /// animation clock the spring starts on.
    internal func setScrollOffset(path: String, next: Vec2, glide: Spring?, cut: Bool, animNow: Double) {
        let maxExt = scrollMaxExtents[path] ?? .zero
        let clamped = Vec2(
            max(0, min(maxExt.x, next.x)),
            max(0, min(maxExt.y, next.y))
        )
        let nid = NodeId.hash("scroll:\(path)")
        if let glide, !cut && !reducedMotion {
            let start = scrollOffsets[path] ?? .zero
            if scrollStore.get(nid, Props.SCROLL) == nil {
                scrollStore.snap(nid, Props.SCROLL, to: start)
            }
            scrollStore.set(nid, Props.SCROLL, to: clamped, anim: .spring(glide), at: animNow)
            scrollGlidingPaths.insert(path)
            scrollOffsets[path] = start
        } else {
            scrollStore.snap(nid, Props.SCROLL, to: clamped)
            scrollOffsets[path] = clamped
            scrollGlidingPaths.remove(path)
            frameInstantScrollKey = path
            clearScrollHandGliding(path: path)
        }
        if maxExt.y > 0.5 && abs(clamped.y - maxExt.y) <= 1.0 {
            wasPinnedToBottom.insert(path)
        } else {
            wasPinnedToBottom.remove(path)
        }
    }


    /// One request of `offset.rs::scroll_to_offsets`, then its `apply_jumps`, on viewport `path`.
    /// Each axis is its own: an axis the request leaves out (`nil`), or that the viewport doesn't
    /// scroll, is left alone, glide and all (`r.x.filter(|_| axes.x())`). An asked axis glides only
    /// on a `glide` spring with motion on (`animate = !reduced_motion && !settled`) and more than
    /// half a point to go: a long trip cuts to `GLIDE_REACH` viewports out first, and the glide
    /// starts with the speed a running glide keeps (`retarget_v`), heading for the requested
    /// offset unclamped (`st.x.aim` / `GlideTo::Offset(to)`), which `followScrollOffsetAims`
    /// clamps to the live extent each frame. Otherwise the axis jumps (`apply_jumps`), halting its
    /// own motion only, and a jump that moved it more than 1e-3 arms the viewport's hover hold
    /// (`st.nudge.arm(now)`). Returns whether a jump moved it.
    @discardableResult
    internal func applyScrollOffsetRequest(path: String, x reqX: Float?, y reqY: Float?, glide: Spring?, cut: Bool, animNow: Double) -> Bool {
        let axes = nodeByPath[path].map { flatNodes[$0].el.layout.scrollAxes } ?? .both
        let want: [Float?] = [
            axes.contains(.horizontal) ? reqX : nil,
            axes.contains(.vertical) ? reqY : nil,
        ]
        guard want.contains(where: { $0 != nil }) else { return false }
        let nid = NodeId.hash("scroll:\(path)")
        let maxExt = scrollMaxExtents[path] ?? .zero
        let before = scrollOffsets[path] ?? .zero
        if !scrollStore.has(nid, Props.SCROLL) {
            scrollStore.snap(nid, Props.SCROLL, to: before)
        }
        scrollStore.setTime(animNow)
        let finals = scrollStore.target(nid, Props.SCROLL) ?? before
        let value = scrollStore.get(nid, Props.SCROLL) ?? before
        let velocity: Vec2 = scrollStore.velocity(nid, Props.SCROLL) ?? .zero
        let trackMoving = scrollStore.isMoving(nid, Props.SCROLL)
        // Only a running glide's speed carries into the next (`st.glide()` / `st.x.glide`); a
        // hand's momentum stops (`st.x.v = 0`, `to_glide` out of momentum).
        let gliding = scrollGlidingPaths.contains(path)
        let view: Vec2 = scrollViewportSizes[path]
            ?? nodeByPath[path].map { Vec2(flatNodes[$0].targetRect.width, flatNodes[$0].targetRect.height) }
            ?? .zero
        let spring = (glide != nil && !cut && !reducedMotion) ? glide : nil

        func comp(_ v: Vec2, _ a: Int) -> Float { a == 0 ? v.x : v.y }
        func laneMoving(_ a: Int) -> Bool {
            trackMoving && (abs(comp(finals, a) - comp(value, a)) > 1e-4 || abs(comp(velocity, a)) > 1e-4)
        }
        // Where each asked lane stands now (a jump's end, or a glide's start after any cut), and
        // the glides that start from there.
        var land: [Float?] = [nil, nil]
        var glides: [(end: Float, v: Float, aim: Float)?] = [nil, nil]
        var moved = false
        for a in 0..<2 {
            guard let w = want[a] else { continue }
            let to = max(0, w)
            let end = min(to, comp(maxExt, a))
            let was = comp(before, a)
            if let spring, abs(end - was) > 0.5 {
                // A long trip cuts to a couple of viewports out first (`offset.rs:49-53,63-66`).
                let reach = Float(Self.scrollGlideReach) * comp(view, a)
                let start = min(max(was, end - reach), end + reach)
                let v0 = gliding && laneMoving(a) ? comp(velocity, a) : 0
                land[a] = start
                glides[a] = (end, ScrollGlide.retargetV(spring, offset: Double(start), v: v0, to: Double(end)), to)
            } else {
                land[a] = end
                // `apply_jumps`: a jump that moved its axis more than 1e-3 arms the hold.
                if abs(end - was) > 1e-3 { moved = true }
            }
        }
        // Land the asked lanes where they stand now, at rest: a jump at its end, a glide at its
        // start. A lane the request leaves out repeats its target with no velocity of its own
        // (NaN), so the store leaves its motion alone.
        let nan = Float.nan
        let landed = Vec2(land[0] ?? finals.x, land[1] ?? finals.y)
        scrollStore.animateWithVelocity(
            nid, Props.SCROLL,
            to: landed,
            velocity: Vec2(land[0] == nil ? nan : 0, land[1] == nil ? nan : 0),
            anim: .instant
        )
        if let spring, glides.contains(where: { $0 != nil }) {
            // One spring steps every glide of a viewport (`st.spring = glide`, `glide_spring`): a
            // lane already gliding that the request leaves out goes on with its speed on it.
            func carried(_ a: Int) -> Bool { want[a] == nil && gliding && laneMoving(a) }
            scrollStore.animateWithVelocity(
                nid, Props.SCROLL,
                to: Vec2(glides[0]?.end ?? landed.x, glides[1]?.end ?? landed.y),
                velocity: Vec2(
                    glides[0]?.v ?? (carried(0) ? comp(velocity, 0) : nan),
                    glides[1]?.v ?? (carried(1) ? comp(velocity, 1) : nan)
                ),
                anim: .spring(spring)
            )
            var aims = scrollOffsetAims[path] ?? ScrollOffsetAims(spring: spring)
            aims.spring = spring
            for a in 0..<2 where want[a] != nil {
                aims.lanes[a] = glides[a].map { ScrollOffsetAims.Lane(aim: $0.aim, set: $0.end) }
            }
            scrollOffsetAims[path] = aims
            scrollGlidingPaths.insert(path)
        } else {
            // Nothing this request asked for glides. A lane it left alone may still be moving on
            // its own; otherwise the viewport stands where the jump put it.
            if var aims = scrollOffsetAims[path] {
                for a in 0..<2 where want[a] != nil { aims.lanes[a] = nil }
                scrollOffsetAims[path] = aims.lanes.contains(where: { $0 != nil }) ? aims : nil
            }
            let othersMoving = (0..<2).contains { want[$0] == nil && laneMoving($0) }
            if !othersMoving {
                scrollGlidingPaths.remove(path)
                scrollOffsetAims.removeValue(forKey: path)
                clearScrollHandGliding(path: path)
            }
            frameInstantScrollKey = path
        }
        var cur = before
        if let lx = land[0] { cur.x = lx }
        if let ly = land[1] { cur.y = ly }
        scrollOffsets[path] = cur
        let finalY = scrollStore.target(nid, Props.SCROLL)?.y ?? cur.y
        if maxExt.y > 0.5 && abs(finalY - maxExt.y) <= 1.0 {
            wasPinnedToBottom.insert(path)
        } else {
            wasPinnedToBottom.remove(path)
        }
        if moved {
            armScrollNudge(path: path, at: currentTime)
        }
        return moved
    }

    /// Each frame before the scroll track samples: a glide an offset request started heads for
    /// its requested offset clamped to the viewport's live extent (`x.rs:483`
    /// `st.x.aim.min(st.x.max)`, `bottom.rs::glide` `to.min(st.max)`), so content growing
    /// mid-glide carries it on toward where it was sent, keeping its speed. A lane someone else
    /// has since retargeted (a hand, a jump, a glide to the bottom) is no longer the request's.
    internal func followScrollOffsetAims(animNow: Double) {
        guard !scrollOffsetAims.isEmpty else { return }
        for path in Array(scrollOffsetAims.keys) {
            guard var aims = scrollOffsetAims[path] else { continue }
            let nid = NodeId.hash("scroll:\(path)")
            guard scrollGlidingPaths.contains(path), let finals = scrollStore.target(nid, Props.SCROLL) else {
                scrollOffsetAims.removeValue(forKey: path)
                continue
            }
            let maxExt = scrollMaxExtents[path] ?? .zero
            var targets = finals
            var retarget = false
            for a in 0..<2 {
                guard let lane = aims.lanes[a] else { continue }
                let final = a == 0 ? finals.x : finals.y
                if final != lane.set {
                    aims.lanes[a] = nil
                    continue
                }
                let to = min(lane.aim, max(0, a == 0 ? maxExt.x : maxExt.y))
                if to != lane.set {
                    if a == 0 { targets.x = to } else { targets.y = to }
                    aims.lanes[a]?.set = to
                    retarget = true
                }
            }
            if retarget {
                // No velocity of its own (NaN): each retargeted lane keeps its speed, as
                // `glide_axis` steps on from where it is toward the new end.
                scrollStore.setTime(animNow)
                scrollStore.animateWithVelocity(
                    nid, Props.SCROLL, to: targets, velocity: Vec2(.nan, .nan), anim: .spring(aims.spring)
                )
            }
            scrollOffsetAims[path] = aims.lanes.contains(where: { $0 != nil }) ? aims : nil
        }
    }

    /// `offset.rs::glide_axis`'s landing, per lane, on viewport `path`'s gliding scroll track:
    /// a lane under `LAND` (0.1 pt) from its end and slower than `40 · LAND` lands there, while
    /// the other lane goes on. Returns the track's value after landing and whether every lane
    /// is now at rest (the glide is over), or nil when the track isn't moving.
    internal func landScrollGlideLanes(path: String) -> (value: Vec2, over: Bool)? {
        let nid = NodeId.hash("scroll:\(path)")
        guard scrollStore.isMoving(nid, Props.SCROLL),
              let target = scrollStore.target(nid, Props.SCROLL),
              let value = scrollStore.get(nid, Props.SCROLL) else { return nil }
        let vel: Vec2 = scrollStore.velocity(nid, Props.SCROLL) ?? .zero
        let d = [value.x - target.x, value.y - target.y]
        let v = [vel.x, vel.y]
        var landing = [false, false]
        var still = [false, false]
        for a in 0..<2 {
            let moving = abs(d[a]) > 1e-4 || abs(v[a]) > 1e-4
            landing[a] = moving && ScrollGlide.lands(d: d[a], v: v[a])
            still[a] = !moving || landing[a]
        }
        guard landing.contains(true) else { return (value, false) }
        if still[0] && still[1] {
            scrollStore.snap(nid, Props.SCROLL, to: target)
            return (target, true)
        }
        scrollStore.animateWithVelocity(
            nid, Props.SCROLL, to: target,
            velocity: Vec2(landing[0] ? 0 : .nan, landing[1] ? 0 : .nan),
            anim: .instant
        )
        return (Vec2(landing[0] ? target.x : value.x, landing[1] ? target.y : value.y), false)
    }
}

/// An offset request's glides on one viewport (`ScrollState::x.aim`, `GlideTo::Offset(to)` and
/// `ScrollState::spring`): per lane, where it was sent (unclamped) and the end the scroll track
/// heads for now; and the spring every glide of the viewport steps on.
internal struct ScrollOffsetAims: Sendable, Equatable {
    internal struct Lane: Sendable, Equatable {
        /// The requested offset, unclamped.
        var aim: Float
        /// The end the track's lane was last sent to: the aim clamped to the extent then.
        var set: Float
    }
    var lanes: [Lane?] = [nil, nil]
    var spring: Spring

    init(spring: Spring) { self.spring = spring }
}

/// `offset.rs`'s free functions for a glide on one axis.
internal enum ScrollGlide {
    /// How near its end a glide lands, in points: its speed, in points a second, under 40 times
    /// that (`LAND`).
    static let land: Float = 0.1

    /// A glide `d` points from its end at `v` points a second lands there (`glide_axis`).
    static func lands(d: Float, v: Float) -> Bool {
        abs(d) < land && abs(v) < 40.0 * land
    }

    /// The speed a running glide at `offset` keeps when it's sent to `to` on `spring`: all of it,
    /// unless that would carry it past `to` and back (a critically damped spring heading for its
    /// end faster than ω times the distance left overshoots), so a glide sent somewhere nearer
    /// stops there on one path instead of bouncing (`offset.rs::retarget_v`).
    static func retargetV(_ spring: Spring, offset: Double, v: Float, to: Double) -> Float {
        let d = Float(offset - to)
        let most = spring.omega * abs(d)
        if v * d < 0.0 && abs(v) > most {
            // `-d.signum() * most`; `v * d < 0` rules out d == 0.
            return d > 0 ? -most : most
        }
        return v
    }

    /// Steps a glide on one axis toward `to` on `spring`. Returns whether it is still moving
    /// (`offset.rs::glide_axis`).
    @discardableResult
    static func glideAxis(_ spring: Spring, offset: inout Double, glide: inout Float?, to: Double, dt: Float) -> Bool {
        guard let v = glide else { return false }
        // Sample the displacement, not the absolute offset: f32 loses sub-point precision far down.
        let (d, nv) = spring.sample(from: Float(offset - to), velocity: v, target: 0.0, at: dt)
        // Lands under a tenth of a point out, so the last step is no bigger than the ones before it.
        if lands(d: d, v: nv) {
            offset = to
            glide = nil
            return false
        }
        offset = to + Double(d)
        glide = nv
        return true
    }
}
