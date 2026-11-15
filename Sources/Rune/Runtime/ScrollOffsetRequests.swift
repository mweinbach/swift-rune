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

    /// One request of `offset.rs::scroll_to_offsets`, then its `apply_jumps`: viewport `path`
    /// goes to `next` (clamped to its content), deciding glide or jump per axis. An axis glides
    /// only on a `glide` spring with motion on (`animate = !reduced_motion && !settled`) and more
    /// than half a point to go; a gliding axis farther than `GLIDE_REACH` viewports cuts to that
    /// far out first. Every other axis jumps, and a jump that moved the offset more than 1e-3
    /// arms the viewport's hover hold (`st.nudge.arm(now)`). Returns whether a jump moved it.
    @discardableResult
    internal func applyScrollOffsetRequest(path: String, next: Vec2, glide: Spring?, cut: Bool, animNow: Double) -> Bool {
        let before = scrollOffsets[path] ?? .zero
        let maxExt = scrollMaxExtents[path] ?? .zero
        let end = Vec2(max(0, min(maxExt.x, next.x)), max(0, min(maxExt.y, next.y)))
        let animate = glide != nil && !cut && !reducedMotion
        let glideX = animate && abs(end.x - before.x) > 0.5
        let glideY = animate && abs(end.y - before.y) > 0.5
        if glideX || glideY {
            // A gliding axis on a long trip cuts to a couple of viewports out first, as a glide
            // to the bottom does (`offset.rs:49-52,63-66`); a jumping axis lands first, and the
            // gliding one then glides from there.
            let view: Vec2 = scrollViewportSizes[path]
                ?? nodeByPath[path].map { Vec2(flatNodes[$0].targetRect.width, flatNodes[$0].targetRect.height) }
                ?? .zero
            let reachX = Float(Self.scrollGlideReach) * view.x
            let reachY = Float(Self.scrollGlideReach) * view.y
            let start = Vec2(
                glideX ? min(max(before.x, end.x - reachX), end.x + reachX) : end.x,
                glideY ? min(max(before.y, end.y - reachY), end.y + reachY) : end.y
            )
            if start != before {
                let handGliding = isScrollHandGliding(path: path)
                setScrollOffset(path: path, next: start, glide: nil, cut: cut, animNow: animNow)
                if handGliding { markScrollHandGliding(path: path) }
            }
            setScrollOffset(path: path, next: end, glide: glide, cut: cut, animNow: animNow)
        } else {
            setScrollOffset(path: path, next: end, glide: nil, cut: cut, animNow: animNow)
        }
        // `apply_jumps`: a jumped axis that moved more than 1e-3 arms the hover hold.
        let movedX = !glideX && abs(end.x - before.x) > 1e-3
        let movedY = !glideY && abs(end.y - before.y) > 1e-3
        if movedX || movedY {
            armScrollNudge(path: path, at: currentTime)
            return true
        }
        return false
    }
}
