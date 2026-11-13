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

        for i in flatNodes.indices {
            let node = flatNodes[i]
            let spec = specs[i]
            let id = spec.id

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

            let clip = intersectRects(node.clipRect, spec.rect)
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

                // 3. `unseen_before_and_after`: rows staying unseen snap their layout frame so offscreen
                // reflow does not animate invisibly.
                if unseenPresence.unseenIds.contains(id), spec.layoutAnim != nil {
                    let parentOrigin = spec.parent.flatMap { specById[$0]?.rect.origin } ?? .zero
                    let localFrame = MotionRect(
                        left: spec.rect.left - parentOrigin.x,
                        top: spec.rect.top - parentOrigin.y,
                        right: spec.rect.right - parentOrigin.x,
                        bottom: spec.rect.bottom - parentOrigin.y
                    )
                    scene.landFrame(id, localFrame)
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
}
