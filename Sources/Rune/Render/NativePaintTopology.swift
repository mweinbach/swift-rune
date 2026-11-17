import RuneMotion

extension Runtime {
    /// Indices into the current committed nodes. A transient tree can also refer
    /// to exiting snapshots, which retain their presented parent after removal.
    struct NativePaintTopology {
        struct Identity {
            var id: NodeId
            var parent: NodeId?
        }

        var identity: [Identity] = []
        var order: [Int] = []
        var roots: [Int] = []
        var childOffsets: [Int] = []
        var childSlots: [Int] = []
        var exitingSlot: [NodeId: Int] = [:]

        func children(of node: FlatNode) -> ArraySlice<Int> {
            let slot = exitingSlot.isEmpty ? node.index : (exitingSlot[node.nodeId] ?? node.index)
            return childSlots[childOffsets[slot]..<childOffsets[slot + 1]]
        }
        var exits: [FlatNode] = []
        var dissolveIndices: [Int] = []
        var hasSticky = false
        var hasHolds = false
        var hasRaised = false
        var hasGroupOpacity = false
        var hasPressColor = false

        func matches(_ presented: [Presented], holds: Bool) -> Bool {
            guard hasHolds == holds, identity.count == presented.count else { return false }
            for i in identity.indices {
                if presented[i].id != identity[i].id || presented[i].parent != identity[i].parent { return false }
            }
            return true
        }
    }

    func prepareNativePaintTopology(_ frame: FrameOutput, byID: [NodeId: Presented], holds: Bool) -> NativePaintTopology {
        if let topology = nativePaintTopology, topology.matches(frame.nodes, holds: holds) {
            return topology
        }

        var tree = NativePaintTopology()
        tree.hasHolds = holds
        tree.hasSticky = holds || flatNodes.contains(where: \.isSticky)
        tree.order.reserveCapacity(frame.nodes.count)
        tree.identity.reserveCapacity(frame.nodes.count)
        var parentIDs: [NodeId?] = []
        parentIDs.reserveCapacity(frame.nodes.count)
        var hasZOrder = false
        for p in frame.nodes {
            let node: FlatNode
            let slot: Int
            if let mounted = mountedNode(p.id) {
                node = mounted
                slot = mounted.index
            } else if let exiting = exitingSnapshots[p.id] {
                node = exiting
                slot = ~tree.exits.count
                tree.exitingSlot[p.id] = flatNodes.count + tree.exits.count
                tree.exits.append(exiting)
            } else {
                continue
            }
            if node.el.isDissolve { tree.dissolveIndices.append(tree.order.count) }
            tree.hasRaised = tree.hasRaised || node.el.isRaised
            tree.hasGroupOpacity = tree.hasGroupOpacity || node.el.groupOpacity != nil
            tree.hasPressColor = tree.hasPressColor || node.el.pressColor != nil
            hasZOrder = hasZOrder || node.zOrder != 0
            tree.order.append(slot)
            tree.identity.append(.init(id: p.id, parent: p.parent))
            parentIDs.append(byID[p.id]?.parent)
        }

        // A flat adjacency buffer avoids allocating a separate array for every row and cell.
        // Links use the presented parent: an exiting or reparented node can become a scene root.
        let slotCount = flatNodes.count + tree.exits.count
        var offsets = [Int](repeating: 0, count: slotCount + 1)
        var parents = [Int](repeating: -1, count: tree.order.count)
        for index in tree.order.indices {
            let slot = tree.order[index]
            guard let parent = parentIDs[index], byID[parent] != nil else {
                tree.roots.append(slot)
                continue
            }
            let owner: Int?
            if slot >= 0, let expected = flatNodes[slot].parentIndex, flatNodes[expected].nodeId == parent {
                owner = expected
            } else {
                owner = nodeIndexById[parent] ?? tree.exitingSlot[parent]
            }
            if let owner {
                parents[index] = owner
                offsets[owner + 1] += 1
            }
        }
        for i in 0..<slotCount { offsets[i + 1] += offsets[i] }
        tree.childOffsets = offsets
        tree.childSlots = [Int](repeating: 0, count: offsets[slotCount])
        for index in tree.order.indices where parents[index] >= 0 {
            let parent = parents[index]
            tree.childSlots[offsets[parent]] = tree.order[index]
            offsets[parent] += 1
        }

        if tree.hasSticky || hasZOrder {
            let exits = tree.exits
            let sticky = tree.hasSticky
            func order(_ slot: Int) -> (Int, Int) {
                let n = slot >= 0 ? flatNodes[slot] : exits[~slot]
                if !sticky { return (n.zOrder, 0) }
                let rank = n.el.anchor != nil || n.el.isModal ? 2 : (n.isSticky ? 1 : 0)
                return (n.zOrder, rank)
            }
            func before(_ a: Int, _ b: Int) -> Bool { order(a) < order(b) }
            tree.roots.sort(by: before)
            for parent in 0..<slotCount {
                let start = tree.childOffsets[parent]
                let end = tree.childOffsets[parent + 1]
                if end - start > 1 && (start + 1..<end).contains(where: {
                    before(tree.childSlots[$0], tree.childSlots[$0 - 1])
                }) {
                    tree.childSlots[start..<end].sort(by: before)
                }
            }
        }

        // Exiting snapshots and synthetic partial frames follow the scene's current ancestry.
        // A committed mounted tree can reuse links while live text and scroll rectangles change.
        if tree.exits.isEmpty && tree.order.count == frame.nodes.count && tree.order.count == flatNodes.count {
            nativePaintTopology = tree
        }
        return tree
    }
}
