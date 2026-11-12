// MARK: - SlotId & StorageStats

/// Direct index into `LayoutStore`'s dense slot array.
public struct SlotId: Sendable, Equatable, Hashable {
    public var rawValue: UInt32

    @inlinable
    public init(_ rawValue: UInt32 = 0) {
        self.rawValue = rawValue
    }

    @inlinable
    public var toNodeId: NodeId {
        NodeId(UInt64(rawValue))
    }

    @inlinable
    public static func from(_ id: NodeId) -> SlotId {
        SlotId(UInt32(truncatingIfNeeded: id.rawValue))
    }
}

public struct StorageStats: Sendable, Equatable {
    public var liveNodes: Int
    public var slotCapacity: Int
    public var sparseCapacity: Int
}

private let unmountedIdx: UInt32 = UInt32.max

private struct RetainedSlot: Sendable {
    var style: TaffyStyle = .default
    var cache: Cache = Cache()
    var unroundedLayout: Layout = .zero
    var finalLayout: Layout = .zero
    var boxLayout: BoxLayout = .zero
    var measure: UInt64 = 0
    var hasContext: Bool = false
    var mutated: Bool = false
    var childStart: Int = 0
    var childLen: Int = 0
}

/// Retained flat-arena layout store integrated with commit-pass reconciliation
/// (mirroring `rune_taffy::LayoutStore`).
public struct LayoutStore: Sendable {
    private var slots: [RetainedSlot] = []
    private var nodeIdx: [UInt32] = []
    private var byKey: [UInt64: UInt32] = [:]
    private var free: [UInt32] = []
    private var prevChildren: [UInt32] = []
    private var currChildren: [UInt32] = []
    private var childScratch: [UInt32] = []
    private var mutatedSlots: [UInt32] = []
    private var prevLive: Int = 0
    private var visitedExisting: Int = 0

    public init(capacity: Int = 32) {
        slots.reserveCapacity(capacity)
        nodeIdx.reserveCapacity(capacity)
        byKey.reserveCapacity(capacity)
        prevChildren.reserveCapacity(capacity)
        currChildren.reserveCapacity(capacity)
        childScratch.reserveCapacity(64)
    }

    public var liveCount: Int {
        byKey.count
    }

    public mutating func beginCommit() {
        swap(&prevChildren, &currChildren)
        currChildren.removeAll(keepingCapacity: true)
        childScratch.removeAll(keepingCapacity: true)
        for i in nodeIdx.indices {
            nodeIdx[i] = unmountedIdx
        }
        prevLive = byKey.count
        visitedExisting = 0
    }

    public func beginChildren() -> Int {
        childScratch.count
    }

    public mutating func pushChild(_ child: SlotId) {
        childScratch.append(child.rawValue)
    }

    public func canReuse(key: UInt64, slot: SlotId) -> Bool {
        let idx = Int(slot.rawValue)
        return byKey[key] == slot.rawValue
            && idx < nodeIdx.count
            && nodeIdx[idx] == unmountedIdx
            && !slots[idx].mutated
    }

    public func isUsedThisCommit(key: UInt64) -> Bool {
        guard let s = byKey[key] else { return false }
        let idx = Int(s)
        return idx < nodeIdx.count && nodeIdx[idx] != unmountedIdx
    }

    public mutating func reuseSlot(_ slot: SlotId, nodeIndex: UInt32) {
        let idx = Int(slot.rawValue)
        if nodeIdx[idx] == unmountedIdx {
            visitedExisting += 1
        }
        nodeIdx[idx] = nodeIndex
        let oldStart = slots[idx].childStart
        let len = slots[idx].childLen
        let newStart = currChildren.count
        if len > 0 {
            currChildren.append(contentsOf: prevChildren[oldStart..<(oldStart + len)])
        }
        slots[idx].childStart = newStart
    }

    public mutating func syncNode(
        key: UInt64,
        nodeIndex: UInt32,
        style: TaffyStyle,
        measure: UInt64?,
        forceMeasureDirty: Bool,
        childMark: Int,
        childrenDirty: Bool
    ) -> (SlotId, Bool) {
        let newKids = childScratch[childMark...]
        let childStart = currChildren.count
        let childLen = newKids.count
        currChildren.append(contentsOf: newKids)

        if let s = byKey[key] {
            let idx = Int(s)
            let firstVisit = nodeIdx[idx] == unmountedIdx
            if firstVisit {
                visitedExisting += 1
            }
            nodeIdx[idx] = nodeIndex

            let oldStart = slots[idx].childStart
            let oldEnd = oldStart + slots[idx].childLen
            let kidsChanged: Bool
            if firstVisit {
                kidsChanged = !prevChildren[oldStart..<oldEnd].elementsEqual(newKids)
            } else {
                kidsChanged = !currChildren[oldStart..<oldEnd].elementsEqual(currChildren[childStart...])
            }

            let styleChanged = slots[idx].style != style
            if styleChanged {
                slots[idx].style = style
            }
            slots[idx].childStart = childStart
            slots[idx].childLen = childLen

            let hadMeasure = slots[idx].hasContext
            let hasMeasure = measure != nil
            let newM = measure ?? 0
            let measureChanged = hadMeasure != hasMeasure || (hasMeasure && (forceMeasureDirty || slots[idx].measure != newM))

            let wasMutated = slots[idx].mutated
            let nowMutated = wasMutated || styleChanged || kidsChanged || measureChanged
            slots[idx].hasContext = hasMeasure
            slots[idx].mutated = nowMutated
            slots[idx].measure = newM

            let dirty = styleChanged || kidsChanged || measureChanged || childrenDirty
            if dirty {
                slots[idx].cache.clear()
            }
            if nowMutated && !wasMutated {
                mutatedSlots.append(s)
            }
            childScratch.removeSubrange(childMark...)
            return (SlotId(s), dirty)
        } else {
            childScratch.removeSubrange(childMark...)
            let slot = RetainedSlot(
                style: style,
                cache: Cache(),
                unroundedLayout: .zero,
                finalLayout: .zero,
                boxLayout: .zero,
                measure: measure ?? 0,
                hasContext: measure != nil,
                mutated: true,
                childStart: childStart,
                childLen: childLen
            )
            let s: UInt32
            if let freeS = free.popLast() {
                s = freeS
                slots[Int(freeS)] = slot
                nodeIdx[Int(freeS)] = nodeIndex
            } else {
                s = UInt32(slots.count)
                slots.append(slot)
                nodeIdx.append(nodeIndex)
            }
            mutatedSlots.append(s)
            byKey[key] = s
            return (SlotId(s), true)
        }
    }

    public mutating func finishFlatten() {
        if visitedExisting == prevLive { return }
        var toRemove: [UInt64] = []
        for (k, s) in byKey {
            if nodeIdx[Int(s)] == unmountedIdx {
                slots[Int(s)] = RetainedSlot()
                free.append(s)
                toRemove.append(k)
            }
        }
        for k in toRemove {
            byKey.removeValue(forKey: k)
        }
    }

    public mutating func endCommit(root: inout SlotId, remap: (UInt32, SlotId) -> Void) {
        if visitedExisting != prevLive {
            finishFlatten()
        }
        for idx in mutatedSlots {
            if Int(idx) < slots.count {
                slots[Int(idx)].mutated = false
            }
        }
        mutatedSlots.removeAll(keepingCapacity: true)
        _ = root
        _ = remap
    }

    public func style(_ id: SlotId) -> TaffyStyle {
        slots[Int(id.rawValue)].style
    }

    public func boxLayout(_ id: SlotId) -> BoxLayout {
        slots[Int(id.rawValue)].boxLayout
    }

    public func layout(_ id: SlotId) -> Layout {
        slots[Int(id.rawValue)].finalLayout
    }

    public func mountedNodeIndex(key: UInt64) -> Int? {
        guard let s = byKey[key] else { return nil }
        let idx = nodeIdx[Int(s)]
        return idx == unmountedIdx ? nil : Int(idx)
    }

    public mutating func setStyleAndMarkAncestors(
        _ id: SlotId,
        style: TaffyStyle,
        ancestors: [SlotId]
    ) {
        let idx = Int(id.rawValue)
        if !slots[idx].mutated {
            slots[idx].mutated = true
            mutatedSlots.append(id.rawValue)
        }
        slots[idx].style = style
        slots[idx].cache.clear()
        for anc in ancestors {
            if slots[Int(anc.rawValue)].cache.clear() == .alreadyEmpty {
                break
            }
        }
    }

    public mutating func markDirtyAndAncestors(_ id: SlotId, ancestors: [SlotId]) {
        slots[Int(id.rawValue)].cache.clear()
        for anc in ancestors {
            if slots[Int(anc.rawValue)].cache.clear() == .alreadyEmpty {
                break
            }
        }
    }

    public mutating func markAllDirty() {
        for s in byKey.values {
            slots[Int(s)].cache.clear()
        }
    }

    public mutating func computeLayout(
        root: SlotId,
        availableSpace: Size<AvailableSpace>,
        rounding: Bool = true,
        measureLeaf: @escaping @Sendable (LayoutInput, Int?, TaffyStyle) -> LayoutOutput
    ) {
        let adapter = LayoutStoreAdapter(
            slots: slots,
            nodeIdx: nodeIdx,
            currChildren: currChildren,
            measureLeaf: measureLeaf
        )
        let rootNode = root.toNodeId
        computeRootLayout(tree: adapter, root: rootNode, availableSpace: availableSpace)
        if rounding {
            roundLayout(tree: adapter, root: rootNode)
        } else {
            copyUnrounded(adapter: adapter, node: rootNode)
        }
        slots = adapter.slots
    }

    private func copyUnrounded(adapter: LayoutStoreAdapter, node: NodeId) {
        adapter.setFinalLayout(node, adapter.unroundedLayout(node))
        let count = adapter.childCount(node)
        for i in 0..<count {
            copyUnrounded(adapter: adapter, node: adapter.childId(node, at: i))
        }
    }

    public func storageStats() -> StorageStats {
        StorageStats(
            liveNodes: byKey.count,
            slotCapacity: slots.capacity,
            sparseCapacity: byKey.capacity
        )
    }
}

public typealias LayoutEngine = LayoutStore

private final class LayoutStoreAdapter: LayoutTree {
    var slots: [RetainedSlot]
    let nodeIdx: [UInt32]
    let currChildren: [UInt32]
    let measureLeaf: @Sendable (LayoutInput, Int?, TaffyStyle) -> LayoutOutput

    init(
        slots: [RetainedSlot],
        nodeIdx: [UInt32],
        currChildren: [UInt32],
        measureLeaf: @Sendable @escaping (LayoutInput, Int?, TaffyStyle) -> LayoutOutput
    ) {
        self.slots = slots
        self.nodeIdx = nodeIdx
        self.currChildren = currChildren
        self.measureLeaf = measureLeaf
    }

    func childCount(_ node: NodeId) -> Int {
        slots[node.index].childLen
    }

    func childId(_ node: NodeId, at index: Int) -> NodeId {
        let start = slots[node.index].childStart
        return NodeId(UInt64(currChildren[start + index]))
    }

    func style(_ node: NodeId) -> TaffyStyle {
        slots[node.index].style
    }

    func unroundedLayout(_ node: NodeId) -> Layout {
        slots[node.index].unroundedLayout
    }

    func setUnroundedLayout(_ node: NodeId, _ layout: Layout) {
        slots[node.index].unroundedLayout = layout
        slots[node.index].boxLayout = BoxLayout.from(layout)
    }

    func setFinalLayout(_ node: NodeId, _ layout: Layout) {
        slots[node.index].finalLayout = layout
    }

    func cacheGet(_ node: NodeId, _ input: LayoutInput) -> LayoutOutput? {
        slots[node.index].cache.get(input)
    }

    func cacheStore(_ node: NodeId, _ input: LayoutInput, _ output: LayoutOutput) {
        slots[node.index].cache.store(input, output: output)
    }

    func measureLeafNode(_ node: NodeId, _ input: LayoutInput) -> LayoutOutput {
        let idx = node.index
        let slot = slots[idx]
        let ctx: Int? = slot.hasContext ? Int(nodeIdx[idx]) : nil
        return measureLeaf(input, ctx, slot.style)
    }
}
