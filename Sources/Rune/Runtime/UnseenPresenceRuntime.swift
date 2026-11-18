import Foundation
import RuneMotion

// MARK: - Unseen Presence Runtime (`crates/rune/src/runtime/motion/unseen_presence.rs`)

internal struct UnseenPresenceState: Sendable {
    struct Node: Sendable {
        var origin: Vec2
        var scrollIndex: Int?
        var parent: NodeId?
    }

    struct Scroll: Sendable {
        var path: String
        var origin: Vec2
        var offset: Vec2

        func contentPosition(of point: Vec2) -> Vec2 {
            Vec2(point.x - origin.x + offset.x, point.y - origin.y + offset.y)
        }
    }

    var indexById: [NodeId: Int] = [:]
    var nodes: [Node] = []
    var scrolls: [Int: Scroll] = [:]

    func node(_ id: NodeId) -> Node? {
        indexById[id].map { nodes[$0] }
    }

    /// Compare in each commit's scroll content coordinates. Viewport indices may change
    /// during a reorder, while their paths remain stable.
    func stayedInScrollSpace(_ old: Node, new: Node, in next: Self) -> Bool {
        let before = old.scrollIndex.flatMap { scrolls[$0] }
        let after = new.scrollIndex.flatMap { next.scrolls[$0] }
        guard before?.path == after?.path else { return false }
        let a = before?.contentPosition(of: old.origin) ?? old.origin
        let b = after?.contentPosition(of: new.origin) ?? new.origin
        return abs(a.x - b.x) <= 1.5 && abs(a.y - b.y) <= 1.5
    }
}

fileprivate let kitVirtualSpacerKey = "kitVirtualSpacer"

extension El {
    /// Marks a list rows container with its full logical item keys so `UnseenPresence` knows when a filter replaced what the reader saw (`VirtualList::replaced_view`).
    public func kitFilterKeys(_ keys: [String]) -> Self {
        var copy = self
        copy.kitFilterKeysValue = keys.isEmpty ? nil : keys
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
}

/// Tracks last-frame visibility and inherited opacity for `unseen_presence.rs` parity:
/// - offscreen/invisible nodes mount and update colors at once (`entersUnseen`)
/// - offscreen/faded-out exiting nodes unmount instead of running invisible exits (`endUnseenExits`)
/// - already-mounted unseen rows in a filtered list that replaced the viewport re-enter with a fade (`reenterUnseenRow`).
internal struct KitUnseenPresenceState {
    struct PaintedNode {
        var parent: NodeId?
        var visible: Bool
        var inView: Bool
        var geometricallyInView: Bool
        var inheritedOpacity: Float
        var drawn: MotionRect
        var stickyShift: Vec2

        mutating func update(_ sample: Self) {
            let saw = inView || sample.inView
            let onScreen = geometricallyInView || sample.geometricallyInView
            self = sample
            inView = saw
            geometricallyInView = onScreen
        }
    }

    private(set) var frameById: [NodeId: PaintedNode] = [:]
    private(set) var offscreenEntrances: [NodeId] = []
    var hasBuilt = false
    private var filterContainerIndices: [Int] = []
    var prevFilterStateById: [NodeId: (keys: [String], seenChildKeys: Set<String>)] = [:]

    mutating func beginFrame() {
        frameById.removeAll(keepingCapacity: true)
        offscreenEntrances.removeAll(keepingCapacity: true)
    }

    mutating func recordFrameNode(
        _ node: Presented, visible: Bool, inView: Bool, geometricallyInView: Bool,
        inhOpacity: Float, drawn: MotionRect, ownStickyShift: Vec2
    ) {
        hasBuilt = true
        let sample = PaintedNode(parent: node.parent, visible: visible, inView: inView,
                                 geometricallyInView: geometricallyInView, inheritedOpacity: inhOpacity,
                                 drawn: drawn, stickyShift: ownStickyShift)
        frameById[node.id, default: sample].update(sample)
        if node.phase == .entering && !geometricallyInView { offscreenEntrances.append(node.id) }
    }

    /// Native paint already computed the transformed bounds and inherited clip. Filter bleed
    /// counts when choosing a drawn anchor, while an entrance needs strictly positive coverage.
    mutating func recordNativeFrameNode(
        _ node: Presented, rect: MotionRect, drawn: MotionRect, scale: Vec2, turn: Turn?,
        localClip: MotionRect?, screenClip: MotionRect, margin: Float,
        bypassClip: Bool, opacity: Float, sticky: Vec2
    ) {
        var clip = localClip
        if let reveal = node.revealClip { clip = clip.map { intersectRects($0, reveal) } ?? reveal }
        if !node.mask.isNone {
            let inset = node.mask.inset
            let masked = MotionRect(left: rect.left + inset.left * scale.x, top: rect.top + inset.top * scale.y,
                                    right: rect.right - inset.right * scale.x, bottom: rect.bottom - inset.bottom * scale.y)
            clip = clip.map { intersectRects($0, masked) } ?? masked
        }

        func overlaps(_ bounds: MotionRect, _ clip: MotionRect, _ margin: Float) -> Bool {
            clip.width > 0 && clip.height > 0 && bounds.right >= clip.left - margin
                && bounds.left <= clip.right + margin && bounds.bottom >= clip.top - margin
                && bounds.top <= clip.bottom + margin
        }

        let visible = bypassClip || (overlaps(drawn, screenClip, margin)
            && (clip.map { overlaps(rect, $0, margin) } ?? true))
        let geometricallyInView: Bool
        if bypassClip {
            geometricallyInView = true
        } else {
            let local = clip.map { intersectRects(rect, $0) } ?? rect
            let showing = intersectRects(turn?.bbox(local) ?? local, screenClip)
            geometricallyInView = local.width > 0 && local.height > 0 && showing.width > 0.001 && showing.height > 0.001
        }
        recordFrameNode(node, visible: visible, inView: opacity >= (1.0 / 512.0) && geometricallyInView,
                        geometricallyInView: geometricallyInView, inhOpacity: opacity,
                        drawn: drawn, ownStickyShift: sticky)
    }

    mutating func updateCycleOpacity(_ id: NodeId, opacity: Float) {
        guard let geometry = frameById[id]?.geometricallyInView else { return }
        frameById[id]?.inheritedOpacity = opacity
        frameById[id]?.inView = geometry && opacity >= (1.0 / 512.0)
    }

    /// Only a hidden exit needs to know whether a visible descendant is still on screen.
    func visibleAncestors() -> Set<NodeId> {
        var ancestors: Set<NodeId> = []
        for node in frameById.values where node.inView {
            var parent = node.parent
            while let id = parent, ancestors.insert(id).inserted {
                parent = frameById[id]?.parent
            }
        }
        return ancestors
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
        var hidden = [Bool](repeating: true, count: nodes.count)
        for i in nodes.indices.reversed() {
            let sample = frameById[nodes[i].nodeId]
            if !hidden[i] || sample?.visible == true {
                // A child can overflow a clipped or transparent parent's own bounds.
                // Propagate its draw before applying this node's opacity cutoff.
                if let parent = nodes[i].parentIndex, parent < i { hidden[parent] = false }
                hidden[i] = (sample?.inheritedOpacity ?? 1) < (1.0 / 512.0)
            }
        }
        return hidden
    }

    /// Per node of `newNodes`: neither it nor anything under it drew last frame, and none of its
    /// swept path lands in sight (inside window + ancestor clips, non-transparent) in this layout.
    func unseenBeforeAndAfter<S>(
        prevNodes: [Runtime<S>.FlatNode],
        previousIndexById: [NodeId: Int],
        newNodes: [Runtime<S>.FlatNode],
        scrolls: [String: Vec2],
        scrollMax: [String: Vec2],
        wasPinnedToBottom: Set<String>,
        viewport: Vec2
    ) -> (unseenNew: [Bool], unseenPrevIds: Set<NodeId>) {
        let nothing = drewNothing(nodes: prevNodes)
        guard !nothing.isEmpty else { return ([], []) }

        var unseenPrevIds: Set<NodeId> = []
        for i in prevNodes.indices where nothing[i] {
            unseenPrevIds.insert(prevNodes[i].nodeId)
        }

        let mounts = newNodes.count > prevNodes.count
        if unseenPrevIds.isEmpty && !mounts {
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
            let previousPaint = frameById[n.nodeId]
            let ownSticky = previousPaint?.stickyShift ?? .zero
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
            if let oldIdx = previousIndexById[n.nodeId],
               prevNodes[oldIdx].targetRect.width > 0 || prevNodes[oldIdx].targetRect.height > 0,
               let drawn = previousPaint?.drawn {
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
            !after[i] && (previousIndexById[newNodes[i].nodeId].map { nothing[$0] } ?? true)
        }
        return (unseenNew, unseenPrevIds)
    }

    /// Detects list containers whose key set changed and dropped all previously seen row keys (`replaced_view`),
    /// returning the set of row container `NodeId`s that replaced what the reader saw.
    mutating func updateFilterReplacedContainers<S>(newNodes: [Runtime<S>.FlatNode], filterIndices: [Int]) -> Set<NodeId> {
        var replaced: Set<NodeId> = []
        var next: [NodeId: (keys: [String], seenChildKeys: Set<String>)] = [:]
        filterContainerIndices = filterIndices
        for i in filterIndices {
            let node = newNodes[i]
            guard let keys = node.el.kitFilterKeysValue, !keys.isEmpty else { continue }
            if isFilterReplaced(containerId: node.nodeId, newKeys: keys) {
                replaced.insert(node.nodeId)
            }
            // Painting supplies the set of visible keys for the next commit.
            next[node.nodeId] = (keys, [])
        }
        prevFilterStateById = next
        return replaced
    }

    /// True when `containerId` has filter keys that changed and dropped every seen row from the prior build.
    func isFilterReplaced(containerId: NodeId, newKeys: [String]?) -> Bool {
        guard let keys = newKeys, !keys.isEmpty, let prev = prevFilterStateById[containerId] else { return false }
        guard prev.keys != keys else { return false }
        let newKeySet = Set(keys)
        return !prev.seenChildKeys.contains { newKeySet.contains($0) }
    }

    /// Updates `seenChildKeys` for tracked filter containers after the new rows have painted.
    mutating func recordPostBuildFilterSeen<S>(nodes: [Runtime<S>.FlatNode]) {
        guard !prevFilterStateById.isEmpty else { return }
        for idx in filterContainerIndices where nodes.indices.contains(idx) {
            let n = nodes[idx]
            guard prevFilterStateById[n.nodeId] != nil else { continue }
            let prefix = n.path + "/"
            var seenRows: Set<String> = []
            for j in (idx + 1)..<nodes.count {
                let child = nodes[j]
                guard child.path.hasPrefix(prefix) else { break }
                guard child.parentIndex == idx, let k = child.key else { continue }
                let painted = frameById[child.nodeId]
                let rowSaw = painted?.visible == true && (painted?.inheritedOpacity ?? 1.0) >= (1.0 / 512.0)
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

        var didReenter = false

        // 1. `end_unseen_exits`: unseen nodes omitted in this commit have nothing visible to exit-fade.
        endUnseenExits(on: &scene)

        var replacedParents: Set<NodeId>?
        let winRect = MotionRect(left: 0, top: 0, right: viewport.x, bottom: viewport.y)
        var next = UnseenPresenceState()
        next.indexById = nodeIndexById
        next.nodes.reserveCapacity(specs.count)
        let hasHolds = scrollRequestsState.keeps.contains { $0.hold != nil }
        let hasSticky = !cut && (hasHolds || flatNodes.contains { $0.isSticky })
        var cumSticky = hasSticky ? [Vec2](repeating: .zero, count: flatNodes.count) : []

        for i in flatNodes.indices {
            let node = flatNodes[i]
            let spec = specs[i]
            let id = spec.id
            let scrollIndex: Int?
            if node.el.layout.scrollAxes.isEmpty {
                scrollIndex = node.enclosingVScrollIndex ?? node.enclosingHScrollIndex
            } else {
                scrollIndex = i
                next.scrolls[i] = .init(path: node.path, origin: spec.rect.origin,
                                       offset: scrollOffsets[node.path] ?? .zero)
            }
            let snapshot = UnseenPresenceState.Node(origin: spec.rect.origin, scrollIndex: scrollIndex, parent: spec.parent)
            next.nodes.append(snapshot)

            guard !cut else { continue }

            var mySticky = Vec2.zero
            if hasSticky {
                let sticky = node.isSticky
                let parentShift = node.el.anchor != nil && !sticky
                    ? .zero : (node.parentIndex.map { cumSticky[$0] } ?? .zero)
                mySticky = sticky || hasHolds
                    ? computeStickyShift(nodeIndex: i, parentStickyShift: parentShift,
                                         nodes: flatNodes, rectOf: { $0.targetRect }).shift
                    : parentShift
                cumSticky[i] = mySticky
            }
            let clip = intersectRects(node.clipRect, spec.rect.offsetBy(mySticky))
            let winClip = intersectRects(clip, winRect)
            let inViewNow = node.el.isolatedLayer || (winClip.width > 0.001 && winClip.height > 0.001)

            if !inViewNow {
                // 2. `enters_unseen`: newly mounted nodes clipped out of view land immediately at rest.
                if let trans = node.el.transition,
                   unseenPresence.indexById[id] == nil,
                   scene.phase(id) == .entering,
                   trans.insertion.pointOffset == .zero,
                   trans.insertion.relativeOffset == .zero {
                    scene.enterNow(id)
                }

                // 3. `unseen_before_and_after`: rows staying unseen snap their layout frame and visuals
                // so offscreen reflow/colour changes do not animate invisibly (`unseen_presence.rs`).
                if kitHooks.unseenPresence.frameById[id]?.inView == false {
                    let parentOrigin = spec.parent.flatMap { nodeIndexById[$0] }.map { specs[$0].rect.origin } ?? .zero
                    let localFrame = MotionRect(
                        left: spec.rect.left - parentOrigin.x,
                        top: spec.rect.top - parentOrigin.y,
                        right: spec.rect.right - parentOrigin.x,
                        bottom: spec.rect.bottom - parentOrigin.y
                    )
                    scene.landUnseen(spec, localFrame: localFrame)
                }
            } else if !reducedMotion,
                      spec.transition != nil,
                      kitHooks.unseenPresence.frameById[id]?.inView == false,
                      let parent = spec.parent,
                      let previous = unseenPresence.node(id),
                      !unseenPresence.stayedInScrollSpace(previous, new: snapshot, in: next) {
                // Only a previously unseen transition moving into view can need the set of
                // replaced parents. Preserve the prior motion parent across matched flights.
                if replacedParents == nil {
                    var parents: Set<NodeId> = []
                    for (oldId, sample) in kitHooks.unseenPresence.frameById
                    where sample.inView && nodeIndexById[oldId] == nil {
                        if let oldParent = unseenPresence.node(oldId)?.parent { parents.insert(oldParent) }
                    }
                    replacedParents = parents
                }
                if replacedParents?.contains(parent) == true {
                    scene.reenter(id)
                    didReenter = true
                }
            }
        }

        unseenPresence = next
        return didReenter
    }

    internal func landUnseenEntrances(on scene: inout Scene) {
        for id in kitHooks.unseenPresence.offscreenEntrances
        where kitHooks.unseenPresence.frameById[id]?.geometricallyInView == false && scene.phase(id) == .entering {
            scene.enterNow(id)
        }
    }

    /// A hidden parent may still paint a visible child outside its bounds.
    func endUnseenExits(on scene: inout Scene) {
        guard kitHooks.unseenPresence.hasBuilt, !exitingSnapshots.isEmpty else { return }
        var ancestors: Set<NodeId>?
        for id in exitingSnapshots.keys {
            guard case .exiting = scene.phase(id),
                  !activeFlightIds.contains(id), !launchedFlightIds.contains(id),
                  !unclippedMatchedFlightIds.contains(id),
                  let previous = kitHooks.unseenPresence.frameById[id],
                  !previous.visible || previous.inheritedOpacity < (1.0 / 512.0) else { continue }
            if ancestors == nil { ancestors = kitHooks.unseenPresence.visibleAncestors() }
            if ancestors?.contains(id) == false { scene.unmount(id) }
        }
    }

    /// Applies `unseen_presence.rs` rules right before `scene.commit`:
    /// - offscreen/invisible nodes land mount transitions and colors at once
    /// - previously unseen kept rows in a filtered view that replaced what was seen re-enter with a fade
    /// - returns newly-omitted nodes that drew nothing last frame so they can be unmounted cleanly after commit.
    func applyUnseenPresenceBeforeCommit(
        prevNodes: [FlatNode],
        previousIndexById: [NodeId: Int],
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
        let replacedContainers = kitHooks.unseenPresence.updateFilterReplacedContainers(
            newNodes: flatNodes, filterIndices: layoutObservers.filterContainers
        )
        // The swept-visibility pass can only suppress these motion fields or re-enter a
        // replacement. An instant scroll remount with none of them needs only to retire
        // previously invisible omissions. A flight remains independently owned.
        if replacedContainers.isEmpty && !specs.contains(where: {
            $0.transition != nil || $0.layoutAnim != nil || $0.styleSpring != nil
        }) {
            guard !cut else { return [] }
            let hidden = kitHooks.unseenPresence.drewNothing(nodes: prevNodes)
            return prevNodes.indices.compactMap { i in
                let id = prevNodes[i].nodeId
                return hidden[i] && nodeIndexById[id] == nil && !activeFlightIds.contains(id) ? id : nil
            }
        }
        let (unseenNew, unseenPrevIds) = kitHooks.unseenPresence.unseenBeforeAndAfter(
            prevNodes: prevNodes,
            previousIndexById: previousIndexById,
            newNodes: flatNodes,
            scrolls: scrollOffsets,
            scrollMax: scrollMaxExtents,
            wasPinnedToBottom: wasPinnedToBottom,
            viewport: viewport
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
            if nodeIndexById[nid] == nil,
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

}
