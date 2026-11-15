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
    /// half a point to go, after cutting to `GLIDE_REACH` viewports out on a long trip; otherwise
    /// it jumps, halting its own motion only. A jump that moved its axis more than 1e-3 arms the
    /// viewport's hover hold (`st.nudge.arm(now)`). Returns whether a jump moved it.
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
        // Where each axis heads (its motion's target, else where it stands), and whether its
        // lane is moving now: a lane left alone keeps exactly that.
        let heading = scrollStore.target(nid, Props.SCROLL) ?? before
        let value = scrollStore.get(nid, Props.SCROLL) ?? before
        let velocity: Vec2 = scrollStore.velocity(nid, Props.SCROLL) ?? .zero
        let trackMoving = scrollStore.isMoving(nid, Props.SCROLL)
        let view: Vec2 = scrollViewportSizes[path]
            ?? nodeByPath[path].map { Vec2(flatNodes[$0].targetRect.width, flatNodes[$0].targetRect.height) }
            ?? .zero
        let animate = glide != nil && !cut && !reducedMotion

        func comp(_ v: Vec2, _ a: Int) -> Float { a == 0 ? v.x : v.y }
        var jumpTo: [Float?] = [nil, nil]    // lanes landing now (a jump, or a long glide's cut)
        var glideTo: [Float?] = [nil, nil]   // lanes gliding from there
        var moved = false
        for a in 0..<2 {
            guard let w = want[a] else { continue }
            let end = min(max(0, w), comp(maxExt, a))
            let was = comp(before, a)
            if animate && abs(end - was) > 0.5 {
                // A long trip cuts to a couple of viewports out first (`offset.rs:49-52,63-66`).
                let reach = Float(Self.scrollGlideReach) * comp(view, a)
                let start = min(max(was, end - reach), end + reach)
                if start != was { jumpTo[a] = start }
                glideTo[a] = end
            } else {
                jumpTo[a] = end
                // `apply_jumps`: a jump that moved its axis more than 1e-3 arms the hold.
                if abs(end - was) > 1e-3 { moved = true }
            }
        }
        func laneMoving(_ a: Int) -> Bool {
            trackMoving && (abs(comp(heading, a) - comp(value, a)) > 1e-4 || abs(comp(velocity, a)) > 1e-4)
        }
        if jumpTo.contains(where: { $0 != nil }) {
            let next = Vec2(jumpTo[0] ?? comp(before, 0), jumpTo[1] ?? comp(before, 1))
            // A lane that doesn't jump and is moving (left alone, or about to retarget its glide)
            // keeps its motion: only the jumping lanes land.
            let keeps = (0..<2).contains { jumpTo[$0] == nil && laneMoving($0) }
            if keeps {
                let targets = Vec2(jumpTo[0] ?? comp(heading, 0), jumpTo[1] ?? comp(heading, 1))
                scrollStore.set(nid, Props.SCROLL, to: targets, anim: Anim<Vec2>(curve: .spring(MotionTokens.INSTANT), blend: .snap), at: animNow)
                var cur = scrollOffsets[path] ?? before
                if let jx = jumpTo[0] { cur.x = jx }
                if let jy = jumpTo[1] { cur.y = jy }
                scrollOffsets[path] = cur
            } else {
                let handGliding = isScrollHandGliding(path: path)
                setScrollOffset(path: path, next: next, glide: nil, cut: cut, animNow: animNow)
                if handGliding && glideTo.contains(where: { $0 != nil }) { markScrollHandGliding(path: path) }
            }
        }
        if let glide, glideTo.contains(where: { $0 != nil }) {
            let landed = scrollStore.target(nid, Props.SCROLL) ?? heading
            let targets = Vec2(glideTo[0] ?? comp(landed, 0), glideTo[1] ?? comp(landed, 1))
            scrollStore.set(nid, Props.SCROLL, to: targets, anim: .spring(glide), at: animNow)
            scrollGlidingPaths.insert(path)
        } else {
            // Nothing this request asked for glides. A lane it left alone may still be moving
            // on its own; otherwise the viewport stands where the jump put it.
            let othersMoving = (0..<2).contains { want[$0] == nil && laneMoving($0) }
            if !othersMoving {
                scrollGlidingPaths.remove(path)
                clearScrollHandGliding(path: path)
            }
            frameInstantScrollKey = path
        }
        let finalY = scrollStore.target(nid, Props.SCROLL)?.y ?? (scrollOffsets[path] ?? before).y
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
}
