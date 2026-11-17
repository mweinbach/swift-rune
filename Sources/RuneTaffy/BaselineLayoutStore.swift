public typealias BaselineTaffyTree = TaffyTree

/// Reference implementation of the retained commit interface using TaffyTree's
/// parent links, generational node IDs and per-node child arrays. Select with
/// the BaselineTaffy build trait to run the same Rune application against it.
public struct BaselineLayoutStore: Sendable {
    private struct Entry: Sendable {
        var id: NodeId
        var nodeIndex: UInt32
        var measure: UInt64?
        var used = true
        var mutated = true
    }

    private var tree: TaffyTree
    private var entries: [Entry?] = []
    private var byKey: [UInt64: UInt32] = [:]
    private var slotForNode: [UInt32] = []
    private var free: [UInt32] = []
    private var scratch: [NodeId] = []

    public init(capacity: Int = 32) {
        tree = TaffyTree(capacity: capacity)
        tree.roundingEnabled = false
        entries.reserveCapacity(capacity)
        byKey.reserveCapacity(capacity)
        slotForNode.reserveCapacity(capacity)
        scratch.reserveCapacity(64)
    }

    public var liveCount: Int { byKey.count }

    public mutating func beginCommit() {
        scratch.removeAll(keepingCapacity: true)
        for index in entries.indices { entries[index]?.used = false }
    }

    public func beginChildren() -> Int { scratch.count }

    public mutating func pushChild(_ child: SlotId) { scratch.append(id(child)) }

    public func canReuse(key: UInt64, slot: SlotId) -> Bool {
        guard byKey[key] == slot.rawValue, let entry = entries[Int(slot.rawValue)] else { return false }
        return !entry.used && !entry.mutated
    }

    public func isUsedThisCommit(key: UInt64) -> Bool { mountedNodeIndex(key: key) != nil }

    public mutating func reuseSlot(_ slot: SlotId, nodeIndex: UInt32) {
        let index = Int(slot.rawValue)
        entries[index]!.used = true
        entries[index]!.nodeIndex = nodeIndex
    }

    public mutating func rekeyAndReuseBatch<S: Sequence>(_ items: S) where S.Element == (UInt64, UInt64, SlotId, UInt32) {
        let batch = Array(items)
        if let first = batch.first {
            let root = id(first.2)
            if let parent = try! tree.parent(root) { _ = try! tree.removeChild(parent, child: root) }
        }
        for (oldKey, _, slot, _) in batch {
            let removed = byKey.removeValue(forKey: oldKey)
            assert(removed == slot.rawValue)
        }
        for (_, newKey, slot, nodeIndex) in batch {
            if let stale = byKey.removeValue(forKey: newKey) { remove(stale) }
            byKey[newKey] = slot.rawValue
            reuseSlot(slot, nodeIndex: nodeIndex)
        }
    }

    public mutating func syncNode(
        key: UInt64, nodeIndex: UInt32, style: TaffyStyle, measure: UInt64?,
        forceMeasureDirty: Bool, childMark: Int, childrenDirty: Bool
    ) -> (SlotId, Bool) {
        let children = scratch[childMark...]
        defer { scratch.removeSubrange(childMark...) }
        if let raw = byKey[key] {
            let index = Int(raw)
            var entry = entries[index]!
            let styleChanged = try! tree.style(entry.id) != style
            let childrenChanged = try! !tree.children(entry.id).elementsEqual(children)
            let measureChanged = forceMeasureDirty || entry.measure != measure
            if styleChanged { try! tree.setStyle(entry.id, style) }
            if childrenChanged { try! tree.setChildren(entry.id, children: Array(children)) }
            if measureChanged { try! tree.markDirty(entry.id) }
            let dirty = styleChanged || childrenChanged || measureChanged
            entry.mutated = entry.mutated || dirty
            entry.measure = measure
            entry.used = true
            entry.nodeIndex = nodeIndex
            entries[index] = entry
            return (SlotId(raw), dirty)
        }
        let node = children.isEmpty ? tree.newLeaf(style) : try! tree.newWithChildren(style, children: Array(children))
        let entry = Entry(id: node, nodeIndex: nodeIndex, measure: measure)
        let raw: UInt32
        if let available = free.popLast() {
            entries[Int(available)] = entry
            raw = available
        } else {
            raw = UInt32(entries.count)
            entries.append(entry)
        }
        if node.index == slotForNode.count { slotForNode.append(raw) } else { slotForNode[node.index] = raw }
        byKey[key] = raw
        return (SlotId(raw), true)
    }

    private mutating func remove(_ raw: UInt32) {
        let index = Int(raw)
        try! tree.remove(entries[index]!.id)
        entries[index] = nil
        free.append(raw)
    }

    public mutating func finishFlatten() {
        for (key, raw) in byKey where entries[Int(raw)]?.used != true {
            remove(raw)
            byKey.removeValue(forKey: key)
        }
    }

    public mutating func compactIfSparse(_ remap: (UInt32, SlotId) -> Void) {
        for index in entries.indices { entries[index]?.mutated = false }
    }

    public mutating func endCommit(root: inout SlotId, remap: (UInt32, SlotId) -> Void) {
        finishFlatten()
        compactIfSparse(remap)
    }

    private func id(_ slot: SlotId) -> NodeId { entries[Int(slot.rawValue)]!.id }

    public func childIds(_ parent: SlotId) -> SlotChildIter {
        let children = try! tree.children(id(parent))
        return SlotChildIter(children.map { slotForNode[$0.index] }[...])
    }

    public func style(_ slot: SlotId) -> TaffyStyle { try! tree.style(id(slot)) }
    public func boxLayout(_ slot: SlotId) -> BoxLayout { BoxLayout.from(try! tree.unroundedLayout(id(slot))) }
    public func layout(_ slot: SlotId) -> Layout { try! tree.layout(id(slot)) }

    public func mountedNodeIndex(key: UInt64) -> Int? {
        guard let raw = byKey[key], let entry = entries[Int(raw)], entry.used else { return nil }
        return Int(entry.nodeIndex)
    }

    public func measureHash(key: UInt64) -> UInt64?? {
        guard let raw = byKey[key], let entry = entries[Int(raw)] else { return nil }
        return .some(entry.measure)
    }

    public mutating func setStyleAndMarkAncestors(_ slot: SlotId, style: TaffyStyle, ancestors: [SlotId]) {
        let node = id(slot)
        try! tree.setStyle(node, style)
        entries[Int(slot.rawValue)]!.mutated = true
    }

    public mutating func markDirtyAndAncestors(_ slot: SlotId, ancestors: [SlotId]) {
        let node = id(slot)
        try! tree.markDirty(node)
    }

    public mutating func markAllDirty() {
        for case let entry? in entries where entry.measure != nil { try! tree.markDirty(entry.id) }
    }

    public mutating func computeLayout(
        root: SlotId, availableSpace: Size<AvailableSpace>, rounding: Bool = false,
        measureLeaf: @escaping @Sendable (LayoutInput, Int?, TaffyStyle) -> LayoutOutput
    ) {
        let rootNode = id(root)
        tree.roundingEnabled = rounding
        try! tree.computeLayout(rootNode, availableSpace: availableSpace) { [entries, slotForNode] node, input, style in
            let entry = entries[Int(slotForNode[node.index])]!
            return measureLeaf(input, entry.measure == nil ? nil : Int(entry.nodeIndex), style)
        }
    }

    public func storageStats() -> StorageStats {
        var stats = tree.storageStats()
        let extra = entries.capacity * MemoryLayout<Entry?>.stride
            + (slotForNode.capacity + free.capacity) * MemoryLayout<UInt32>.stride
            + scratch.capacity * MemoryLayout<NodeId>.stride
        stats.inlineBufferBytes += extra
        stats.totalRetainedBytes += extra
        stats.sparseCapacity = byKey.capacity
        return stats
    }
}
