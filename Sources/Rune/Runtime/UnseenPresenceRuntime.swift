import Foundation
import RuneMotion

// MARK: - Unseen Presence Runtime (`crates/rune/src/runtime/motion/unseen_presence.rs`)

internal struct UnseenPresenceState: Sendable {
    struct PrevNodeSnapshot: Sendable {
        var scrollContentPos: Vec2
        var scrollPath: String?
        var parentId: NodeId?
    }

    var unseenIds: Set<NodeId> = []
    var seenIds: Set<NodeId> = []
    var seenAncestorIds: Set<NodeId> = []
    var currentPaintSeenIds: Set<NodeId> = []
    var currentPaintUnseenIds: Set<NodeId> = []
    var prevMountedIds: Set<NodeId> = []
    var prevNodesById: [NodeId: PrevNodeSnapshot] = [:]
    var prevChildrenByParent: [NodeId: [NodeId]] = [:]

    mutating func beginPaint() {
        currentPaintSeenIds.removeAll(keepingCapacity: true)
        currentPaintUnseenIds.removeAll(keepingCapacity: true)
    }

    mutating func recordPaintedNode(id: NodeId, inView: Bool) {
        if inView {
            currentPaintSeenIds.insert(id)
            currentPaintUnseenIds.remove(id)
        } else if !currentPaintSeenIds.contains(id) {
            currentPaintUnseenIds.insert(id)
        }
    }
}

fileprivate let kitFilterKeysKey = "kitFilterKeys"
fileprivate let kitVirtualSpacerKey = "kitVirtualSpacer"

extension El {
    /// Marks a list rows container with its full logical item keys so `UnseenPresence` knows when a filter replaced what the reader saw (`VirtualList::replaced_view`).
    public func kitFilterKeys(_ keys: [String]) -> Self {
        var copy = self
        copy.runtimeExtras[kitFilterKeysKey] = keys
        return copy
    }

    /// Marks an element as a virtual list spacer so `GrowthStack` does not track or hold closing space for it.
    public func kitVirtualSpacer(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.runtimeExtras[kitVirtualSpacerKey] = enabled
        return copy
    }

    internal var isKitVirtualSpacer: Bool {
        (runtimeExtras[kitVirtualSpacerKey] as? Bool) ?? false
    }

    internal var kitFilterKeysValue: [String]? {
        runtimeExtras[kitFilterKeysKey] as? [String]
    }
}

/// Tracks last-frame visibility and inherited opacity for `unseen_presence.rs` parity:
/// - offscreen/invisible nodes mount and update colors at once (`entersUnseen`)
/// - offscreen/faded-out exiting nodes unmount instead of running invisible exits (`endUnseenExits`)
/// - already-mounted unseen rows in a filtered list that replaced the viewport re-enter with a fade (`reenterUnseenRow`).
internal struct KitUnseenPresenceState {
    var hasBuilt: Bool = false
    var frameSeenById: [NodeId: Bool] = [:]
    var frameInhOpacityById: [NodeId: Float] = [:]
    var frameDrawnById: [NodeId: MotionRect] = [:]
    var frameStickyShiftById: [NodeId: Vec2] = [:]
    var prevFilterStateById: [NodeId: (keys: [String], seenChildKeys: Set<String>)] = [:]

    mutating func beginFrame() {
        frameSeenById.removeAll(keepingCapacity: true)
        frameInhOpacityById.removeAll(keepingCapacity: true)
        frameDrawnById.removeAll(keepingCapacity: true)
        frameStickyShiftById.removeAll(keepingCapacity: true)
    }

    mutating func recordFrameNode(
        id: NodeId,
        visible: Bool,
        inhOpacity: Float,
        drawn: MotionRect,
        ownStickyShift: Vec2 = .zero
    ) {
        hasBuilt = true
        frameSeenById[id] = visible
        frameInhOpacityById[id] = inhOpacity
        frameDrawnById[id] = drawn
        if ownStickyShift != .zero {
            frameStickyShiftById[id] = ownStickyShift
        }
    }

    /// Marks ancestors of seen nodes as seen (`mark_ancestors`), matching `unseen_presence.rs`.
    func markAncestors<S>(_ nodes: [Runtime<S>.FlatNode], _ flags: inout [Bool]) {
        guard flags.count == nodes.count else { return }
        for i in nodes.indices.reversed() {
            if flags[i], let p = nodes[i].parentIndex, p < i {
                flags[p] = true
            }
        }
    }

    /// Per node of `prevNodes`: neither it nor anything under it drew in the last frame.
    func drewNothing<S>(nodes: [Runtime<S>.FlatNode]) -> [Bool] {
        guard hasBuilt, !nodes.isEmpty else { return [] }
        var seen = nodes.map { frameSeenById[$0.nodeId] ?? false }
        markAncestors(nodes, &seen)
        return nodes.indices.map { i in
            !seen[i] || (frameInhOpacityById[nodes[i].nodeId] ?? 1.0) < (1.0 / 512.0)
        }
    }

    /// Per node of `newNodes`: neither it nor anything under it drew last frame, and none of its
    /// swept path lands in sight (inside window + ancestor clips, non-transparent) in this layout.
    func unseenBeforeAndAfter<S>(
        prevNodes: [Runtime<S>.FlatNode],
        newNodes: [Runtime<S>.FlatNode],
        scrolls: [String: Vec2],
        scrollMax: [String: Vec2],
        wasPinnedToBottom: Set<String>,
        viewport: Vec2
    ) -> (unseenNew: [Bool], unseenPrevIds: Set<NodeId>) {
        let nothing = drewNothing(nodes: prevNodes)
        guard !nothing.isEmpty else { return ([], []) }

        var seenPrevById: [NodeId: Bool] = [:]
        seenPrevById.reserveCapacity(prevNodes.count)
        var oldIndexById: [NodeId: Int] = [:]
        oldIndexById.reserveCapacity(prevNodes.count)
        var unseenPrevIds: Set<NodeId> = []
        for i in prevNodes.indices {
            let nid = prevNodes[i].nodeId
            oldIndexById[nid] = i
            let wasSeen = !nothing[i]
            seenPrevById[nid] = wasSeen
            if !wasSeen {
                unseenPrevIds.insert(nid)
            }
        }

        let mounts = newNodes.count > prevNodes.count
        let allPrevSeen = !unseenPrevIds.isEmpty ? false : true
        if allPrevSeen && !mounts {
            return ([], unseenPrevIds)
        }

        let windowRect = MotionRect.fromXYWH(0, 0, viewport.x, viewport.y)
        var inner: [(clip: MotionRect, shiftMin: Vec2, shiftMax: Vec2)] = Array(
            repeating: (windowRect, .zero, .zero),
            count: newNodes.count
        )
        var after = Array(repeating: false, count: newNodes.count)
        var alpha = Array(repeating: Float(1.0), count: newNodes.count)

        for i in newNodes.indices {
            let n = newNodes[i]
            let el = n.el
            let hasLoopOrLiveOpacity = el.loopingSpec != nil || el.liveBindings.contains { $0.target == .opacity }
            let ownOpacity: Float
            if hasLoopOrLiveOpacity {
                ownOpacity = 1.0
            } else {
                let gOp = max(0.0, el.groupOpacity?.rest ?? 1.0)
                ownOpacity = el.opacity * gOp
            }
            let parentAlpha: Float = {
                if let p = n.parentIndex, p < i { return alpha[p] }
                return 1.0
            }()
            alpha[i] = ownOpacity * parentAlpha

            let (parentClip, parentShiftMin, parentShiftMax): (MotionRect, Vec2, Vec2) = {
                if let p = n.parentIndex, el.anchor == nil {
                    if p < i {
                        return inner[p]
                    } else {
                        after[i] = true
                        return (windowRect, .zero, .zero)
                    }
                }
                return (windowRect, .zero, .zero)
            }()

            // A stuck ancestor draws where it's held, not where scrolling puts it: subtract last
            // frame's own sticky shift so it and its children stay inside the viewport clip.
            let ownSticky = frameStickyShiftById[n.nodeId] ?? .zero
            let stickyMin = Vec2(parentShiftMin.x - ownSticky.x, parentShiftMin.y - ownSticky.y)
            let stickyMax = Vec2(parentShiftMax.x - ownSticky.x, parentShiftMax.y - ownSticky.y)

            // `n.targetRect` is already in scrolled window coordinates after `shiftFlatAndSpecsForScrollDeltas`,
            // while descendants also need scroll-range sweep for scrolled children.
            let t = n.targetRect
            let r = MotionRect(
                left: t.left - stickyMax.x,
                top: t.top - stickyMax.y,
                right: t.right - stickyMin.x,
                bottom: t.bottom - stickyMin.y
            )
            let swept: MotionRect
            if let oldIdx = oldIndexById[n.nodeId],
               let oldNode = prevNodes.indices.contains(oldIdx) ? prevNodes[oldIdx] : nil,
               oldNode.targetRect.width > 0 || oldNode.targetRect.height > 0,
               let drawn = frameDrawnById[n.nodeId] {
                swept = MotionRect(
                    left: min(drawn.left, r.left),
                    top: min(drawn.top, r.top),
                    right: max(drawn.right, r.right),
                    bottom: max(drawn.bottom, r.bottom)
                )
            } else {
                swept = r
            }

            var shadowMargin: Float = 0
            for s in el.shadows where !s.inset {
                shadowMargin = max(shadowMargin, abs(s.x) + abs(s.y) + max(0, s.spread) + s.blur * 1.5)
            }
            let margin = shadowMargin + el.blur * 3.0 + (el.focusable ? 4.0 : 0.0)

            if alpha[i] >= (1.0 / 512.0),
               parentClip.width > 0, parentClip.height > 0,
               swept.right > parentClip.left - margin,
               swept.left < parentClip.right + margin,
               swept.bottom > parentClip.top - margin,
               swept.top < parentClip.bottom + margin {
                after[i] = true
            }

            let nextClip: MotionRect
            if el.layout.clipOverflow || el.clipRadius != nil || el.clipCorners != nil || el.clipFade != nil || !el.layout.scrollAxes.isEmpty {
                let left = max(parentClip.left, swept.left)
                let top = max(parentClip.top, swept.top)
                let right = max(left, min(parentClip.right, swept.right))
                let bottom = max(top, min(parentClip.bottom, swept.bottom))
                nextClip = MotionRect(left: left, top: top, right: right, bottom: bottom)
            } else {
                nextClip = parentClip
            }

            // Include child-scroll slack if this node scrolls
            var nextMin = stickyMin
            var nextMax = stickyMax
            if !el.layout.scrollAxes.isEmpty {
                let off = scrolls[n.path] ?? .zero
                let maxExt = scrollMax[n.path] ?? .zero
                let ox0 = el.layout.scrollAxes.contains(.horizontal) ? off.x : 0
                let ox1 = ox0.clamped(to: 0...max(0, maxExt.x))
                let oy0 = el.layout.scrollAxes.contains(.vertical) ? off.y : 0
                let oy1 = (el.layout.stickBottom && wasPinnedToBottom.contains(n.path))
                    ? max(0, maxExt.y)
                    : oy0.clamped(to: 0...max(0, maxExt.y))
                // `targetRect` of children has `-off` applied in `.ltr` and `+off` in `.rtl`;
                // clamping difference captures scroll correction on the matching sign.
                let dx0 = (n.flow == .rtl) ? (ox0 - ox1) : (ox1 - ox0)
                let dy0 = oy1 - oy0
                nextMin = Vec2(nextMin.x + min(0, dx0), nextMin.y + min(0, dy0))
                nextMax = Vec2(nextMax.x + max(0, dx0), nextMax.y + max(0, dy0))
            }

            inner[i] = (nextClip, nextMin, nextMax)
        }

        markAncestors(newNodes, &after)

        let unseenNew: [Bool] = newNodes.indices.map { i in
            let nid = newNodes[i].nodeId
            let wasSeen = seenPrevById[nid] ?? false
            return !after[i] && !wasSeen
        }
        return (unseenNew, unseenPrevIds)
    }

    /// Detects list containers whose key set changed and dropped all previously seen row keys (`replaced_view`),
    /// returning the set of row container `NodeId`s that replaced what the reader saw.
    mutating func updateFilterReplacedContainers<S>(
        prevNodes: [Runtime<S>.FlatNode],
        newNodes: [Runtime<S>.FlatNode],
        unseenPrevIds: Set<NodeId>
    ) -> Set<NodeId> {
        var replaced: Set<NodeId> = []
        var activeContainerIds: Set<NodeId> = []

        for node in newNodes {
            guard let keys = node.el.kitFilterKeysValue, !keys.isEmpty else { continue }
            activeContainerIds.insert(node.nodeId)
            let newKeySet = Set(keys)
            if let prev = prevFilterStateById[node.nodeId] {
                if prev.keys != keys {
                    let anySeenStayed = prev.seenChildKeys.contains { newKeySet.contains($0) }
                    if !anySeenStayed {
                        replaced.insert(node.nodeId)
                    }
                }
            }
        }

        // Capture seen child row keys from the current `newNodes`? No — wait until `buildRefScene` updates `frameSeenById`,
        // OR capture from `prevNodes`? On the next commit, `prevNodes` were the nodes drawn in `frameSeenById`!
        // Refresh stored keys now, and compute `seenChildKeys` lazily on the next commit (or update in `recordPostBuildFilterSeen`).
        for node in newNodes {
            guard let keys = node.el.kitFilterKeysValue else { continue }
            prevFilterStateById[node.nodeId] = (keys: keys, seenChildKeys: [])
        }
        if !prevFilterStateById.isEmpty {
            prevFilterStateById = prevFilterStateById.filter { activeContainerIds.contains($0.key) }
        }
        _ = prevNodes
        _ = unseenPrevIds
        return replaced
    }

    /// True when `containerId` has filter keys that changed and dropped every seen row from the prior build.
    func isFilterReplaced(containerId: NodeId, newKeys: [String]?) -> Bool {
        guard let keys = newKeys, !keys.isEmpty, let prev = prevFilterStateById[containerId] else { return false }
        guard prev.keys != keys else { return false }
        let newKeySet = Set(keys)
        return !prev.seenChildKeys.contains { newKeySet.contains($0) }
    }

    /// Updates `seenChildKeys` for tracked filter containers after `buildRefScene` records `frameSeenById`.
    mutating func recordPostBuildFilterSeen<S>(nodes: [Runtime<S>.FlatNode]) {
        guard !prevFilterStateById.isEmpty else { return }
        for idx in nodes.indices {
            let n = nodes[idx]
            guard prevFilterStateById[n.nodeId] != nil else { continue }
            let prefix = n.path + "/"
            var seenRows: Set<String> = []
            for j in (idx + 1)..<nodes.count {
                let child = nodes[j]
                guard child.path.hasPrefix(prefix) else { break }
                guard child.parentIndex == idx, let k = child.key else { continue }
                let rowSaw = (frameSeenById[child.nodeId] ?? false)
                    && ((frameInhOpacityById[child.nodeId] ?? 1.0) >= (1.0 / 512.0))
                if rowSaw {
                    // Option row keys look like `"\(listKey)-option-\(optID)"`; strip prefix if present.
                    if let range = k.range(of: "-option-") {
                        seenRows.insert(String(k[range.upperBound...]))
                    } else {
                        seenRows.insert(k)
                    }
                }
            }
            if let existing = prevFilterStateById[n.nodeId] {
                prevFilterStateById[n.nodeId] = (keys: existing.keys, seenChildKeys: seenRows)
            }
        }
    }
}

extension Runtime {
    internal func isNodeInViewForUnseen(
        el: El<State>,
        isActiveFlight: Bool,
        visibleRect: MotionRect
    ) -> Bool {
        if el.isolatedLayer || isActiveFlight { return true }
        let winRect = MotionRect(left: 0, top: 0, right: viewport.x, bottom: viewport.y)
        let winClip = intersectRects(visibleRect, winRect)
        return winClip.width > 0.001 && winClip.height > 0.001
    }

    internal func applyUnseenPresenceAfterCommit(
        specs: [NodeSpec],
        cut: Bool,
        to scene: inout Scene
    ) -> Bool {
        guard specs.count == flatNodes.count else { return false }

        let newIdSet = Set(specs.map(\.id))
        var didReenter = false

        // 1. `end_unseen_exits`: unseen nodes omitted in this commit have nothing visible to exit-fade.
        for id in unseenPresence.unseenIds where !newIdSet.contains(id) {
            if !unseenPresence.seenAncestorIds.contains(id), case .exiting = scene.phase(id) {
                scene.unmount(id)
            }
        }

        // Build per-parent child lists & parent origins for local-frame snapping / replaced-view detection.
        var childrenByParent: [NodeId: [NodeId]] = [:]
        var specById: [NodeId: NodeSpec] = Dictionary(minimumCapacity: specs.count)
        for spec in specs {
            specById[spec.id] = spec
            if let pid = spec.parent {
                childrenByParent[pid, default: []].append(spec.id)
            }
        }

        // Compute which parents had previously-seen children removed/replaced (`replacedView`).
        var replacedParents: Set<NodeId> = []
        for (pid, prevKids) in unseenPresence.prevChildrenByParent {
            let hadSeenRemoved = prevKids.contains { kid in
                unseenPresence.seenIds.contains(kid) && !newIdSet.contains(kid)
            }
            if hadSeenRemoved {
                replacedParents.insert(pid)
            }
        }

        let winRect = MotionRect(left: 0, top: 0, right: viewport.x, bottom: viewport.y)
        var nextPrevNodes: [NodeId: UnseenPresenceState.PrevNodeSnapshot] = Dictionary(minimumCapacity: specs.count)
        var cumSticky = [Vec2](repeating: .zero, count: flatNodes.count)

        for i in flatNodes.indices {
            let node = flatNodes[i]
            let spec = specs[i]
            let id = spec.id
            let parentSticky = (node.el.anchor != nil && !node.isSticky)
                ? .zero
                : (node.parentIndex.map { cumSticky[$0] } ?? .zero)
            let mySticky = computeStickyShift(
                nodeIndex: i,
                parentStickyShift: parentSticky,
                nodes: flatNodes,
                rectOf: \.targetRect
            ).shift
            cumSticky[i] = mySticky

            let scrollNodeIdx = !node.el.layout.scrollAxes.isEmpty
                ? i
                : (node.enclosingVScrollIndex ?? node.enclosingHScrollIndex)
            let scrollPath = scrollNodeIdx.map { flatNodes[$0].path }
            let scrollOrigin = scrollNodeIdx.map { specs[$0].rect.origin } ?? .zero
            let curScroll = scrollPath.flatMap { scrollOffsets[$0] } ?? .zero
            let scrollContentPos = Vec2(
                spec.rect.x - scrollOrigin.x + curScroll.x,
                spec.rect.y - scrollOrigin.y + curScroll.y
            )
            nextPrevNodes[id] = UnseenPresenceState.PrevNodeSnapshot(
                scrollContentPos: scrollContentPos,
                scrollPath: scrollPath,
                parentId: spec.parent
            )

            guard !cut else { continue }

            let clip = intersectRects(node.clipRect, spec.rect.offsetBy(mySticky))
            let winClip = intersectRects(clip, winRect)
            let inViewNow = node.el.isolatedLayer || (winClip.width > 0.001 && winClip.height > 0.001)

            if !inViewNow {
                // 2. `enters_unseen`: newly mounted nodes clipped out of view land immediately at rest.
                if !unseenPresence.prevMountedIds.contains(id),
                   scene.phase(id) == .entering,
                   let trans = node.el.transition,
                   trans.insertion.pointOffset == .zero,
                   trans.insertion.relativeOffset == .zero {
                    scene.enterNow(id)
                }

                // 3. `unseen_before_and_after`: rows staying unseen snap their layout frame and visuals
                // so offscreen reflow/colour changes do not animate invisibly (`unseen_presence.rs`).
                if unseenPresence.unseenIds.contains(id) {
                    let parentOrigin = spec.parent.flatMap { specById[$0]?.rect.origin } ?? .zero
                    let localFrame = MotionRect(
                        left: spec.rect.left - parentOrigin.x,
                        top: spec.rect.top - parentOrigin.y,
                        right: spec.rect.right - parentOrigin.x,
                        bottom: spec.rect.bottom - parentOrigin.y
                    )
                    scene.landFrame(id, localFrame)
                    if let fill = spec.fill { scene.set(id, Props.FILL, fill) }
                    if let border = spec.border { scene.set(id, Props.BORDER, border) }
                    scene.set(id, Props.OPACITY, spec.opacity)
                    scene.set(id, Props.BLUR, Blur(spec.blur))
                    scene.set(id, Props.CORNERS, spec.corners)
                    scene.set(id, Props.OFFSET, spec.offset)
                    scene.set(id, Props.SCALE, spec.scale)
                    scene.set(id, Props.ROTATE, spec.rotate)
                }
            } else if !reducedMotion,
                      spec.transition != nil,
                      unseenPresence.prevMountedIds.contains(id),
                      unseenPresence.unseenIds.contains(id),
                      let prevSnap = unseenPresence.prevNodesById[id] {
                // 4. `reenter_unseen_row`: previously unseen row entering view on a replaced/filtered
                // list (not merely scrolled into view) restarts its entrance fade from 0 -> 1.
                let movedPurelyByScroll = prevSnap.scrollPath == scrollPath
                    && abs(scrollContentPos.x - prevSnap.scrollContentPos.x) <= 1.5
                    && abs(scrollContentPos.y - prevSnap.scrollContentPos.y) <= 1.5
                let isReplacedParent = spec.parent.map { replacedParents.contains($0) } ?? false
                if !movedPurelyByScroll && isReplacedParent {
                    scene.reenter(id)
                    didReenter = true
                }
            }
        }

        unseenPresence.prevMountedIds = newIdSet
        unseenPresence.prevNodesById = nextPrevNodes
        unseenPresence.prevChildrenByParent = childrenByParent
        return didReenter
    }

    internal func landUnseenEntrances(frameNodes: [Presented], on scene: inout Scene) {
        unseenPresence.unseenIds = unseenPresence.currentPaintUnseenIds
        unseenPresence.seenIds = unseenPresence.currentPaintSeenIds

        var ancestors: Set<NodeId> = []
        for id in unseenPresence.seenIds {
            if let node = nodeById[id] {
                var parent = node.parentIndex
                while let pIdx = parent, pIdx < flatNodes.count {
                    let pid = flatNodes[pIdx].nodeId
                    if !ancestors.insert(pid).inserted { break }
                    parent = flatNodes[pIdx].parentIndex
                }
            }
        }
        unseenPresence.seenAncestorIds = ancestors

        for p in frameNodes where !p.isExiting {
            if unseenPresence.unseenIds.contains(p.id), scene.phase(p.id) == .entering {
                scene.enterNow(p.id)
            }
        }
    }

    /// Ends exits that drew nothing on the last frame (already faded or clipped out of view).
    func endUnseenExits(on scene: inout Scene, activeFlightIds: Set<NodeId>) {
        guard kitHooks.unseenPresence.hasBuilt else { return }
        var toUnmount: [NodeId] = []
        for id in exitingSnapshots.keys {
            guard case .exiting = scene.phase(id) else { continue }
            guard !activeFlightIds.contains(id) else { continue }
            let saw = kitHooks.unseenPresence.frameSeenById[id] ?? false
            let alpha = kitHooks.unseenPresence.frameInhOpacityById[id] ?? 1.0
            if !saw || alpha < (1.0 / 512.0) {
                toUnmount.append(id)
            }
        }
        for id in toUnmount {
            scene.unmount(id)
        }
    }

    /// Applies `unseen_presence.rs` rules right before `scene.commit`:
    /// - offscreen/invisible nodes land mount transitions and colors at once
    /// - previously unseen kept rows in a filtered view that replaced what was seen re-enter with a fade
    /// - returns newly-omitted nodes that drew nothing last frame so they can be unmounted cleanly after commit.
    func applyUnseenPresenceBeforeCommit(
        prevNodes: [FlatNode],
        specs: inout [NodeSpec],
        cut: Bool,
        on scene: inout Scene,
        activeFlightIds: Set<NodeId>
    ) -> [NodeId] {
        guard kitHooks.unseenPresence.hasBuilt,
              specs.count == flatNodes.count,
              !prevNodes.isEmpty else {
            return []
        }
        let (unseenNew, unseenPrevIds) = kitHooks.unseenPresence.unseenBeforeAndAfter(
            prevNodes: prevNodes,
            newNodes: flatNodes,
            scrolls: scrollOffsets,
            scrollMax: scrollMaxExtents,
            wasPinnedToBottom: wasPinnedToBottom,
            viewport: viewport
        )
        let replacedContainers = kitHooks.unseenPresence.updateFilterReplacedContainers(
            prevNodes: prevNodes,
            newNodes: flatNodes,
            unseenPrevIds: unseenPrevIds
        )

        if unseenNew.count == flatNodes.count {
            for i in flatNodes.indices {
                let node = flatNodes[i]
                let nid = node.nodeId
                let entersUnseen = unseenNew[i] && node.el.flightId == nil
                if entersUnseen {
                    specs[i].transition = nil
                    specs[i].layoutAnim = nil
                    specs[i].styleSpring = nil
                    continue
                }
                if !cut && !reducedMotion,
                   !unseenPrevIds.isEmpty,
                   unseenPrevIds.contains(nid),
                   let pIdx = node.parentIndex,
                   replacedContainers.contains(flatNodes[pIdx].nodeId),
                   scene.hasNode(nid),
                   !node.el.hasInstantChanges {
                    if case .exiting = scene.phase(nid) {
                        continue
                    }
                    scene.setTransition(nid, specs[i].transition ?? Transition.opacity)
                    scene.reenter(nid)
                }
            }
        }

        guard !cut else { return [] }
        var omittedUnseen: [NodeId] = []
        for prev in prevNodes {
            let nid = prev.nodeId
            if nodeById[nid] == nil,
               unseenPrevIds.contains(nid),
               !activeFlightIds.contains(nid) {
                omittedUnseen.append(nid)
            }
        }
        return omittedUnseen
    }

    func unmountOmittedUnseenNodes(_ ids: [NodeId], on scene: inout Scene) {
        for id in ids {
            scene.unmount(id)
        }
    }

    /// Immediately unmounts any exiting node that drew nothing on the just-finished frame
    /// (`unseen_presence.rs:end_unseen_exits`), skipping active matched flights.
    internal func endUnseenExits(on scene: inout Scene) {
        for id in unseenPresence.currentPaintUnseenIds {
            guard case .exiting = scene.phase(id),
                  !unseenPresence.seenAncestorIds.contains(id),
                  !activeFlightIds.contains(id),
                  !launchedFlightIds.contains(id),
                  !unclippedMatchedFlightIds.contains(id) else {
                continue
            }
            scene.unmount(id)
        }
    }
}
