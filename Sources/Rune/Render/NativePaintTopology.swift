import RuneMotion

/// Authored paint traits used when validating the sibling order and frame-wide paint prepasses.
struct NativePaintTraits: OptionSet {
    let rawValue: UInt8
    init(rawValue: UInt8) { self.rawValue = rawValue }

    static let sticky = Self(rawValue: 1 << 0)
    static let anchoredOrModal = Self(rawValue: 1 << 1)
    static let dissolve = Self(rawValue: 1 << 2)
    static let raised = Self(rawValue: 1 << 3)
    static let groupOpacity = Self(rawValue: 1 << 4)
    static let pressColor = Self(rawValue: 1 << 5)
    static let offscreenGeometry = Self(rawValue: 1 << 6)

    func hasSameTopology(as other: Self) -> Bool {
        subtracting(.offscreenGeometry) == other.subtracting(.offscreenGeometry)
    }

    init<State>(_ el: borrowing El<State>, inScrollViewport: Bool = false) {
        var traits = Self()
        if el.stickyConfig?.edge != nil { traits.insert(.sticky) }
        if el.anchor != nil || el.isModal { traits.insert(.anchoredOrModal) }
        if el.isDissolve { traits.insert(.dissolve) }
        if el.isRaised { traits.insert(.raised) }
        if el.groupOpacity != nil { traits.insert(.groupOpacity) }
        if el.pressColor != nil { traits.insert(.pressColor) }
        if inScrollViewport && el.allowsOffscreenGeometry { traits.insert(.offscreenGeometry) }
        self = traits
    }
}

extension El {
    /// These nodes have ordinary box or single-line ink. Input and accessibility
    /// modifiers are preserved in the painted record and do not expand its ink.
    fileprivate var allowsOffscreenGeometry: Bool {
        guard hasOnlyCulledPaintExtras, !isRaised, !isModal, !isDissolve,
              stickyConfig == nil, anchor == nil, flightId == nil, !isolatedLayer,
              scale == Vec2(1, 1), rotate == 0, offset == .zero, blur == 0,
              layout.scrollAxes.isEmpty, !layout.clipOverflow, clipRadius == nil,
              clipCorners == nil, clipFade == nil, backdropBlur == 0,
              shadows.isEmpty, shapes.isEmpty, gradient == nil,
              !hasEditLens, role != .textInput, !isSecure, !focusable, a11yRange == nil,
              liveBindings.isEmpty, liveText == nil, loopingSpec == nil,
              groupOpacity == nil, pressScaleFactor == nil, virtualEstimate == nil,
              growthSpec == nil, foldGlideSpec == nil, layoutAnim?.travel != .screen,
              iconPayload == nil, imagePayload == nil, pixelsPayload == nil,
              terminalGridPayload == nil, surfacePayload == nil,
              textHighlights == nil, textLinks.isEmpty, spanRingsSpec.isEmpty,
              advanceInRun == nil, pillChips.isEmpty, focusWithinRing == nil
        else { return false }
        guard plainText != nil || richSpans != nil else { return true }
        guard children.isEmpty, focusRingColor == nil,
              isTruncateFadeEnabled || (textStyle.wrap != .wrap && textStyle.maxLines == 0),
              plainText.map(hasTextLineBreak) != true else { return false }
        return richSpans?.contains { span in
            span.pad > 0 || (span.size ?? 0) > textStyle.size || hasTextLineBreak(span.text)
        } != true
    }
}

extension Runtime {
    /// Indices into the current committed nodes. A transient tree can also refer
    /// to exiting snapshots, which retain their presented parent after removal.
    struct NativePaintTopology {
        struct Identity {
            var id: NodeId
            var parent: NodeId?
            var zOrder: Int
            var traits: NativePaintTraits
        }

        var currentCommit = true
        var parentSlots: [Int] = []
        var presentedIndexBySlot: [Int] = []
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

        /// Remounts may change every row ID while leaving the slot permutation and edges intact.
        /// Compare scene order and parent IDs at the old slots without indexing by ID again.
        func matchesRemount(_ presented: [Presented], mounted: [FlatNode], holds: Bool) -> Bool {
            guard hasHolds == holds, !parentSlots.isEmpty, parentSlots.count == presented.count,
                  parentSlots.count == mounted.count else { return false }
            for i in parentSlots.indices {
                let slot = order[i], parent = parentSlots[i]
                guard presented[i].id == mounted[slot].nodeId,
                      presented[i].parent == (parent < 0 ? nil : mounted[parent].nodeId),
                      mounted[slot].zOrder == identity[i].zOrder,
                      mounted[slot].paintTraits.hasSameTopology(as: identity[i].traits) else { return false }
            }
            return true
        }

        func matches(_ presented: [Presented], holds: Bool) -> Bool {
            guard hasHolds == holds, identity.count == presented.count else { return false }
            for i in identity.indices {
                if presented[i].id != identity[i].id || presented[i].parent != identity[i].parent { return false }
            }
            return true
        }
    }

    func prepareNativePaintTopology(_ frame: FrameOutput, byID: FramePoseIndex, holds: Bool,
                                    fromMountedScene: Bool = false) -> NativePaintTopology {
        if var topology = nativePaintTopology {
            if topology.currentCommit {
                if topology.matches(frame.nodes, holds: holds) { return topology }
            } else if fromMountedScene && topology.matchesRemount(frame.nodes, mounted: flatNodes, holds: holds) {
                topology.currentCommit = true
                for i in topology.identity.indices {
                    topology.identity[i].id = frame.nodes[i].id
                    topology.identity[i].parent = frame.nodes[i].parent
                }
                nativePaintTopology = topology
                return topology
            }
        }

        var tree = NativePaintTopology()
        tree.hasHolds = holds
        tree.hasSticky = holds || flatNodes.withUnsafeBufferPointer { nodes in
            nodes.indices.contains { nodes[$0].paintTraits.contains(.sticky) }
        }
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
            if node.paintTraits.contains(.dissolve) { tree.dissolveIndices.append(tree.order.count) }
            tree.hasRaised = tree.hasRaised || node.paintTraits.contains(.raised)
            tree.hasGroupOpacity = tree.hasGroupOpacity || node.paintTraits.contains(.groupOpacity)
            tree.hasPressColor = tree.hasPressColor || node.paintTraits.contains(.pressColor)
            hasZOrder = hasZOrder || node.zOrder != 0
            tree.order.append(slot)
            tree.identity.append(.init(id: p.id, parent: p.parent, zOrder: node.zOrder, traits: node.paintTraits))
            parentIDs.append(byID[p.id]?.parent)
        }

        // A flat adjacency buffer avoids allocating a separate array for every row and cell.
        // Links use the presented parent: an exiting or reparented node can become a scene root.
        // Sort compact presentation indices before converting them to mounted or exit slots.
        let needsSort = tree.hasSticky || hasZOrder
        let slotCount = flatNodes.count + tree.exits.count
        var offsets = [Int](repeating: 0, count: slotCount + 1)
        var parents = [Int](repeating: -1, count: tree.order.count)
        for index in tree.order.indices {
            let slot = tree.order[index]
            guard let parent = parentIDs[index], byID[parent] != nil else {
                tree.roots.append(needsSort ? index : slot)
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
            tree.childSlots[offsets[parent]] = needsSort ? index : tree.order[index]
            offsets[parent] += 1
        }

        if needsSort {
            let identities = tree.identity
            let sticky = tree.hasSticky
            func rank(_ traits: NativePaintTraits) -> Int {
                traits.contains(.anchoredOrModal) ? 2 : (traits.contains(.sticky) ? 1 : 0)
            }
            func before(_ a: Int, _ b: Int) -> Bool {
                let lhs = identities[a], rhs = identities[b]
                if lhs.zOrder != rhs.zOrder { return lhs.zOrder < rhs.zOrder }
                return sticky && rank(lhs.traits) < rank(rhs.traits)
            }
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
            for i in tree.roots.indices { tree.roots[i] = tree.order[tree.roots[i]] }
            for i in tree.childSlots.indices { tree.childSlots[i] = tree.order[tree.childSlots[i]] }
        }

        // Exiting snapshots and synthetic partial frames follow the scene's current ancestry.
        // A committed mounted tree can reuse links while live text and scroll rectangles change.
        if tree.exits.isEmpty && tree.order.count == frame.nodes.count && tree.order.count == flatNodes.count {
            // The parent slots were already resolved while building childOffsets. Retaining
            // this buffer also avoids another flat-node walk on shapes that change every frame.
            if fromMountedScene {
                tree.parentSlots = parents
                if !tree.childSlots.isEmpty {
                    // The scatter cursors are spent. Reuse their storage for lookup during paint.
                    offsets.removeLast() // The adjacency end sentinel has no corresponding node.
                    for i in tree.order.indices { offsets[tree.order[i]] = i }
                    tree.presentedIndexBySlot = offsets
                }
            }
            nativePaintTopology = tree
        }
        return tree
    }
}
