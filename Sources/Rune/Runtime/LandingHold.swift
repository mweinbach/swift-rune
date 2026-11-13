import Foundation
import RuneMotion

/// Tracks elements held at their landing width this frame (`runtime/motion/landing_hold.rs`).
public struct LandingHolds: Sendable, Equatable {
    public private(set) var ids: Set<NodeId> = []

    public init() {}

    public func holds(_ id: NodeId) -> Bool {
        ids.contains(id)
    }

    public mutating func insert(_ id: NodeId) {
        ids.insert(id)
    }

    public mutating func clear() {
        ids.removeAll(keepingCapacity: true)
    }
}

extension Runtime {
    /// Subtree and X-offset adjustment for a node holding its landing width (`landing_holds`).
    internal struct LandingHoldEntry {
        let index: Int
        let subtreeRange: Range<Int>
        let offsetX: Float
    }

    /// Marks elements (and their subtrees) with `holdLandingWidth` whose target width changed
    /// under animated commits (`runtime/motion/landing_hold.rs`).
    internal func collectLandingHolds(animated: Bool, nodes: [FlatNode]) -> [LandingHoldEntry] {
        landingHolds.clear()
        guard animated else { return [] }
        var holds: [LandingHoldEntry] = []
        for i in nodes.indices {
            let n = nodes[i]
            guard n.el.holdLandingWidthFlag || n.el.holdLandingWidthEnabled else { continue }
            guard scene.hasNode(n.nodeId),
                  let drawn = scene.get(n.nodeId, Props.FRAME) else { continue }
            let was = scene.store.target(n.nodeId, Props.FRAME) ?? drawn
            guard abs(was.width - n.localRect.width) >= 0.5 else { continue }

            var end = i + 1
            while end < nodes.count {
                let pIdx = nodes[end].parentIndex ?? -1
                if pIdx < i { break }
                end += 1
            }

            var firstPresentChild: Int? = nil
            var drawnAnchorChild: Int? = nil
            for c in (i + 1)..<end where nodes[c].parentIndex == i {
                let cId = nodes[c].nodeId
                guard scene.hasNode(cId), !scene.isExiting(cId) else { continue }
                if firstPresentChild == nil { firstPresentChild = c }
                if drawnRectByPath[nodes[c].path] != nil {
                    drawnAnchorChild = c
                    break
                }
            }
            let anchorIdx = drawnAnchorChild ?? firstPresentChild
            let jump = anchorIdx.flatMap { c in
                scene.get(nodes[c].nodeId, Props.FRAME).map { $0.x - nodes[c].localRect.x }
            } ?? 0.0

            for j in i..<end {
                landingHolds.insert(nodes[j].nodeId)
            }
            holds.append(LandingHoldEntry(
                index: i,
                subtreeRange: i..<end,
                offsetX: (drawn.x - n.localRect.x) + jump
            ))
        }
        return holds
    }
}
