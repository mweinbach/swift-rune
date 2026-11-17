import Foundation
import RuneMotion

// MARK: - App offset requests (`crates/rune/src/runtime/scroll/offset.rs`)

extension Runtime {
    /// `scroll_viewport_on`: a key or highlight selects the nearest viewport supporting
    /// an axis the request names. Nested horizontal lists can sit inside a vertical scroll.
    internal func scrollViewportForOffset(key: String, x: Float?, y: Float?) -> Int? {
        var candidate = mountedScrollAnchor(key: key)?.index
        while let index = candidate {
            let node = flatNodes[index]
            let axes = node.el.layout.scrollAxes
            if (x != nil && axes.contains(.horizontal)) || (y != nil && axes.contains(.vertical)) {
                return index
            }
            candidate = node.parentIndex
        }
        return nil
    }

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
    /// own motion only. App requests arm the viewport's hover hold after a jump of more than
    /// 1e-3 (`st.nudge.arm(now)`). Keyboard paging releases that hold. Returns whether a jump moved it.
    @discardableResult
    internal func applyScrollOffsetRequest(path: String, x reqX: Float?, y reqY: Float?, glide: Spring?, cut: Bool, animNow: Double, holdHover: Bool = true, recordJump: Bool = false) -> Bool {
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
        var jumped = false
        for a in 0..<2 {
            guard let w = want[a] else { continue }
            let to = max(0, w)
            let end = min(to, comp(maxExt, a))
            let was = comp(before, a)
            if let spring, abs(end - was) > 0.5 {
                // A long trip cuts to a couple of viewports out first (`offset.rs:49-53,63-66`).
                let reach = Float(ScrollSlack.glideReach) * comp(view, a)
                let start = min(max(was, end - reach), end + reach)
                let v0 = gliding && laneMoving(a) ? comp(velocity, a) : 0
                land[a] = start
                glides[a] = (end, ScrollAxisHelper.retargetV(spring: spring, offset: Double(start), v: v0, to: Double(end)), to)
            } else {
                land[a] = end
                jumped = true
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
        if recordJump && jumped {
            if moved {
                markScrollMovedByHand(path: path)
            } else {
                // A stationary jump on one axis can accompany a glide on the other. Rust
                // consumes the jump's direct-movement latch during the next scroll step.
                pendingScrollJumpPaths.insert(path)
            }
        }
        if moved && holdHover {
            armScrollNudge(path: path, at: currentTime)
        }
        return moved
    }

    /// The scroll range includes the space closing rows still occupy. The natural layout supplies
    /// the destination even while growing rows are constrained to their drawn height.
    internal func growthScrollMaximum(
        path: String, stackPath: String?, stackBottom: Float, viewportHeight: Float,
        measured: Float, natural: Float
    ) -> Float {
        guard let stackPath, let stack = growthStacks[stackPath] else {
            if slice2State.scrollModes[path]?.hand.laid != nil {
                updateScrollMode(forPath: path, event: .laid(nil))
            }
            return measured
        }
        var extra: Float = 0
        for key in stack.closing.keys {
            extra += max(0, growthRows[key]?.track.h ?? 0) + stack.gap
        }
        if !stack.closing.isEmpty && stack.closing.count == stack.order.count {
            extra -= stack.gap
        }
        let maximum = max(measured, stackBottom + extra - viewportHeight)
        let moving = !stack.closing.isEmpty || abs(measured - natural) > 0.01
        let laid = moving ? Double(natural) : nil
        if slice2State.scrollModes[path]?.hand.laid != laid {
            updateScrollMode(forPath: path, event: .laid(laid))
        }
        return maximum
    }

    /// A reader above a shrinking list glides to its new layout end while its rows close.
    /// A hand, a keep, an explicit glide, or rows growing back past the reader take it over.
    internal func followShrinkingScrollEnds(at now: Double) {
        for (path, previous) in slice2State.scrollModes {
            guard let offset = scrollOffsets[path], let extent = scrollMaxExtents[path],
                  nodeByPath[path] != nil else { continue }
            let laid = previous.hand.laid
            let oldEnd: Double?
            if case .glide(_, .shrunkEnd(let end), _) = previous {
                oldEnd = end
            } else {
                oldEnd = nil
            }
            guard laid != nil || oldEnd != nil || previous.hand.direct || previous.hand.scrolling || previous.hand.shrinkCut else { continue }
            var mode = previous
            ScrollMode.step(&mode, .growth(moving: laid != nil))
            let held = reducedMotion || mode.hand.shrinkCut || scrollRequestsState.owns(path)
                || isTouchOwning(path: path, horizontal: false)
            let nid = NodeId.hash("scroll:" + path)
            let target = scrollStore.target(nid, Props.SCROLL) ?? offset
            let velocity = scrollStore.velocity(nid, Props.SCROLL) ?? Vec2.zero
            if let oldEnd {
                if !scrollGlidingPaths.contains(path) || target.y != Float(oldEnd) {
                    // An explicit offset or a wheel has already replaced the shrink track.
                    mode = mode.toRest()
                } else if held || (laid.map { Float($0) >= offset.y } ?? true) {
                    scrollStore.setTime(now)
                    scrollStore.animateWithVelocity(nid, Props.SCROLL, to: Vec2(target.x, offset.y),
                        velocity: Vec2(.nan, 0), anim: .instant)
                    if target.x == offset.x && abs(velocity.x) < 0.01 {
                        scrollGlidingPaths.remove(path)
                    }
                    mode = mode.toRest()
                } else if let laid, laid != oldEnd {
                    scrollStore.setTime(now)
                    scrollStore.animateWithVelocity(nid, Props.SCROLL, to: Vec2(target.x, Float(laid)),
                        velocity: Vec2(.nan, velocity.y), anim: .spring(MotionTokens.GLIDE))
                    mode = mode.toGlide(velocity.y, to: .shrunkEnd(laid))
                }
            } else if let laid, !held, !wasPinnedToBottom.contains(path), !scrollGlidingPaths.contains(path),
                      offset.y <= extent.y, Double(offset.y) - laid > 0.5 {
                scrollStore.setTime(now)
                if !scrollStore.has(nid, Props.SCROLL) {
                    scrollStore.snap(nid, Props.SCROLL, to: offset)
                }
                scrollStore.animateWithVelocity(nid, Props.SCROLL, to: Vec2(target.x, Float(laid)),
                    velocity: Vec2(.nan, 0), anim: .spring(MotionTokens.GLIDE))
                scrollGlidingPaths.insert(path)
                mode = mode.toGlide(0, to: .shrunkEnd(laid))
            }
            ScrollMode.step(&mode, .step(xV: velocity.x))
            slice2State.scrollModes[path] = mode
        }
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
}
