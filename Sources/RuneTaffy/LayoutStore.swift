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
    public var bytesPerSlot: Int
    public var inlineBufferBytes: Int
    public var childHeapBytes: Int
    public var coldStyleBytes: Int
    public var coldCacheBytes: Int
    public var coldAuxBytes: Int
    public var totalRetainedBytes: Int

    public init(
        liveNodes: Int,
        slotCapacity: Int,
        sparseCapacity: Int,
        bytesPerSlot: Int = 0,
        inlineBufferBytes: Int = 0,
        childHeapBytes: Int = 0,
        coldStyleBytes: Int = 0,
        coldCacheBytes: Int = 0,
        coldAuxBytes: Int = 0,
        totalRetainedBytes: Int = 0
    ) {
        self.liveNodes = liveNodes
        self.slotCapacity = slotCapacity
        self.sparseCapacity = sparseCapacity
        self.bytesPerSlot = bytesPerSlot
        self.inlineBufferBytes = inlineBufferBytes
        self.childHeapBytes = childHeapBytes
        self.coldStyleBytes = coldStyleBytes
        self.coldCacheBytes = coldCacheBytes
        self.coldAuxBytes = coldAuxBytes
        self.totalRetainedBytes = totalRetainedBytes
    }
}

/// Iterator over a slot's child `NodeId`s (matching `rune_taffy::SlotChildIter`).
public struct SlotChildIter: Sequence, IteratorProtocol, Sendable {
    private let slice: ArraySlice<UInt32>
    private var idx: Int

    internal init(_ slice: ArraySlice<UInt32>) {
        self.slice = slice
        self.idx = slice.startIndex
    }

    public mutating func next() -> NodeId? {
        guard idx < slice.endIndex else { return nil }
        let raw = slice[idx]
        idx += 1
        return NodeId(UInt64(raw))
    }
}

private let unmountedIdx: UInt32 = UInt32.max

private struct RetainedSlot: Sendable {
    var style: TaffyStyle = .default
    var cache: Cache = Cache()
    var unroundedLayout: Layout = .zero
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
    // Rune presents unrounded geometry; allocate overrides only for callers requesting pixel rounding.
    private var roundedLayouts: [UInt32: Layout] = [:]
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

    /// Rebases a sequence of `(oldKey, newKey, slot, nodeIndex)` entries when a memoized subtree
    /// moves to a new parent path, preserving each slot's warm cache and children.
    public mutating func rekeyAndReuseBatch<S: Sequence>(_ items: S) where S.Element == (UInt64, UInt64, SlotId, UInt32) {
        let batch = Array(items)
        for (oldKey, _, slot, _) in batch {
            let removed = byKey.removeValue(forKey: oldKey)
            assert(removed == slot.rawValue, "rekeyAndReuseBatch: oldKey \(oldKey) did not map to slot \(slot.rawValue)")
        }
        for (_, newKey, slot, nodeIndex) in batch {
            if let stale = byKey.removeValue(forKey: newKey) {
                roundedLayouts.removeValue(forKey: stale)
                slots[Int(stale)] = RetainedSlot()
                free.append(stale)
                if prevLive > 0 {
                    prevLive -= 1
                }
            }
            byKey[newKey] = slot.rawValue
            reuseSlot(slot, nodeIndex: nodeIndex)
        }
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
                roundedLayouts.removeValue(forKey: s)
                slots[Int(s)] = RetainedSlot()
                free.append(s)
                toRemove.append(k)
            }
        }
        for k in toRemove {
            byKey.removeValue(forKey: k)
        }
    }

    /// Shrinks storage when live occupancy drops below 25% of capacity (D-T1).
    public mutating func compactIfSparse(_ remap: (UInt32, SlotId) -> Void) {
        var dummy = SlotId(unmountedIdx)
        compactWithRoot(root: &dummy, remap: remap)
    }

    private mutating func compactWithRoot(root: inout SlotId, remap: (UInt32, SlotId) -> Void) {
        for idx in mutatedSlots {
            if Int(idx) < slots.count {
                slots[Int(idx)].mutated = false
            }
        }
        mutatedSlots.removeAll(keepingCapacity: true)

        let live = byKey.count
        if slots.capacity <= 64 || live * 4 > slots.capacity {
            return
        }

        let cap = Swift.max(live * 2, 32)
        var remapTable = Array(repeating: unmountedIdx, count: slots.count)
        var newSlots: [RetainedSlot] = []
        newSlots.reserveCapacity(cap)
        var newNodeIdx: [UInt32] = []
        newNodeIdx.reserveCapacity(cap)
        var newByKey: [UInt64: UInt32] = [:]
        newByKey.reserveCapacity(cap)

        for (key, oldRaw) in byKey {
            let oldS = Int(oldRaw)
            let newS = UInt32(newSlots.count)
            remapTable[oldS] = newS
            var slot = slots[oldS]
            slots[oldS] = RetainedSlot()
            _ = slot.cache.clear()
            let me = nodeIdx[oldS]
            remap(me, SlotId(newS))
            newByKey[key] = newS
            newSlots.append(slot)
            newNodeIdx.append(me)
        }

        if !roundedLayouts.isEmpty {
            roundedLayouts = Dictionary(uniqueKeysWithValues: roundedLayouts.map { (remapTable[Int($0.key)], $0.value) })
        }

        let rootIdx = Int(root.rawValue)
        if rootIdx < remapTable.count {
            let mapped = remapTable[rootIdx]
            if mapped != unmountedIdx {
                root = SlotId(mapped)
            }
        }

        for i in currChildren.indices {
            currChildren[i] = remapTable[Int(currChildren[i])]
        }

        var shrunkCurr: [UInt32] = []
        shrunkCurr.reserveCapacity(Swift.max(currChildren.count, cap))
        shrunkCurr.append(contentsOf: currChildren)

        var shrunkPrev: [UInt32] = []
        shrunkPrev.reserveCapacity(cap)

        slots = newSlots
        nodeIdx = newNodeIdx
        byKey = newByKey
        free = []
        currChildren = shrunkCurr
        prevChildren = shrunkPrev
        childScratch = []
        childScratch.reserveCapacity(64)
    }

    public mutating func endCommit(root: inout SlotId, remap: (UInt32, SlotId) -> Void) {
        if visitedExisting != prevLive {
            finishFlatten()
        }
        compactWithRoot(root: &root, remap: remap)
    }

    public func childIds(_ parent: SlotId) -> SlotChildIter {
        let s = slots[Int(parent.rawValue)]
        let start = s.childStart
        let end = start + s.childLen
        return SlotChildIter(currChildren[start..<end])
    }

    public func style(_ id: SlotId) -> TaffyStyle {
        slots[Int(id.rawValue)].style
    }

    public func boxLayout(_ id: SlotId) -> BoxLayout {
        BoxLayout.from(slots[Int(id.rawValue)].unroundedLayout)
    }

    public func layout(_ id: SlotId) -> Layout {
        if !roundedLayouts.isEmpty, let rounded = roundedLayouts[id.rawValue] { return rounded }
        return slots[Int(id.rawValue)].unroundedLayout
    }

    public func mountedNodeIndex(key: UInt64) -> Int? {
        guard let s = byKey[key] else { return nil }
        let idx = nodeIdx[Int(s)]
        return idx == unmountedIdx ? nil : Int(idx)
    }

    public func measureHash(key: UInt64) -> UInt64?? {
        guard let s = byKey[key] else { return nil }
        let slot = slots[Int(s)]
        return .some(slot.hasContext ? slot.measure : nil)
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
        rounding: Bool = false,
        measureLeaf: @escaping @Sendable (LayoutInput, Int?, TaffyStyle) -> LayoutOutput
    ) {
        let adapter = LayoutStoreAdapter(
            nodeIdx: nodeIdx,
            currChildren: currChildren,
            measureLeaf: measureLeaf
        )
        // Give the layout pass unique storage while it writes caches and solved rectangles.
        swap(&slots, &adapter.slots)
        swap(&roundedLayouts, &adapter.roundedLayouts)
        let rootNode = root.toNodeId
        computeRootLayout(tree: adapter, root: rootNode, availableSpace: availableSpace)
        if rounding {
            roundLayout(tree: adapter, root: rootNode)
        } else if !adapter.roundedLayouts.isEmpty {
            clearRounding(adapter: adapter, node: rootNode)
        }
        swap(&roundedLayouts, &adapter.roundedLayouts)
        swap(&slots, &adapter.slots)
    }

    private func clearRounding(adapter: LayoutStoreAdapter, node: NodeId) {
        adapter.roundedLayouts.removeValue(forKey: UInt32(node.index))
        let count = adapter.childCount(node)
        for i in 0..<count {
            clearRounding(adapter: adapter, node: adapter.childId(node, at: i))
        }
    }

    public func storageStats() -> StorageStats {
        let slotCapacity = slots.capacity
        let bytesPerSlot = MemoryLayout<RetainedSlot>.stride + MemoryLayout<UInt32>.stride
        let inlineBufferBytes = slotCapacity * bytesPerSlot
            + (prevChildren.capacity + currChildren.capacity + childScratch.capacity + free.capacity)
                * MemoryLayout<UInt32>.stride
        var coldStyleBytes = 0
        var coldCacheBytes = 0
        for s in byKey.values {
            let slot = slots[Int(s)]
            coldStyleBytes += slot.style.heapBytes()
            coldCacheBytes += slot.cache.heapBytes()
        }
        let coldAuxBytes = roundedLayouts.capacity * (MemoryLayout<UInt32>.stride + MemoryLayout<Layout>.stride)
        let total = inlineBufferBytes + coldStyleBytes + coldCacheBytes + coldAuxBytes
        return StorageStats(
            liveNodes: byKey.count,
            slotCapacity: slotCapacity,
            sparseCapacity: byKey.capacity,
            bytesPerSlot: bytesPerSlot,
            inlineBufferBytes: inlineBufferBytes,
            childHeapBytes: 0,
            coldStyleBytes: coldStyleBytes,
            coldCacheBytes: coldCacheBytes,
            coldAuxBytes: coldAuxBytes,
            totalRetainedBytes: total
        )
    }
}

#if BaselineTaffy
public typealias LayoutEngine = BaselineLayoutStore
#else
public typealias LayoutEngine = LayoutStore
#endif

private final class LayoutStoreAdapter: LayoutTree {
    var slots: [RetainedSlot] = []
    var roundedLayouts: [UInt32: Layout] = [:]
    let nodeIdx: [UInt32]
    let currChildren: [UInt32]
    let measureLeaf: @Sendable (LayoutInput, Int?, TaffyStyle) -> LayoutOutput

    init(
        nodeIdx: [UInt32],
        currChildren: [UInt32],
        measureLeaf: @Sendable @escaping (LayoutInput, Int?, TaffyStyle) -> LayoutOutput
    ) {
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
    }

    func setFinalLayout(_ node: NodeId, _ layout: Layout) {
        roundedLayouts[UInt32(node.index)] = layout
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
