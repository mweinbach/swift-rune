// MARK: - TaffyTree Errors

public enum TaffyError: Error, Sendable, Equatable {
    case invalidInputNode(NodeId)
    case invalidParentNode(NodeId)
    case invalidChildNode(NodeId)
    case childIndexOutOfBounds(parent: NodeId, childIndex: Int, childCount: Int)
}

// MARK: - Generational Slab Node Storage

private struct TreeNodeData: Sendable {
    var generation: UInt32
    var occupied: Bool
    var style: TaffyStyle
    var cache: Cache
    var unroundedLayout: Layout
    var roundedLayout: Layout?
    var parent: NodeId?
    var children: [NodeId]
    var measure: MeasureFunc?

    init(generation: UInt32) {
        self.generation = generation
        self.occupied = false
        self.style = .default
        self.cache = Cache()
        self.unroundedLayout = .zero
        self.roundedLayout = nil
        self.parent = nil
        self.children = []
        self.measure = nil
    }
}

/// Generational arena-backed layout tree with dirty-flag propagation, caching, and full
/// Flexbox / CSS Grid / Block layout computation.
public struct TaffyTree: Sendable {
    private var nodes: [TreeNodeData] = []
    private var freeIndices: [Int] = []
    private var liveNodeCount: Int = 0
    private var roundedCount = 0
    public var roundingEnabled: Bool = true

    public init(capacity: Int = 16) {
        self.nodes.reserveCapacity(capacity)
    }

    public var totalNodeCount: Int {
        liveNodeCount
    }

    // MARK: - Node Validation

    @inline(__always)
    private func validIndex(_ id: NodeId) -> Int? {
        let idx = id.index
        guard idx >= 0 && idx < nodes.count else { return nil }
        let slot = nodes[idx]
        guard slot.occupied && slot.generation == id.generation else { return nil }
        return idx
    }

    // MARK: - Node Allocation & Removal

    public mutating func newLeaf(_ style: TaffyStyle = .default) -> NodeId {
        allocateNode(style: style, children: [], measure: nil)
    }

    public mutating func newLeafWithMeasure(
        _ style: TaffyStyle = .default,
        measure: @escaping MeasureFunc
    ) -> NodeId {
        allocateNode(style: style, children: [], measure: measure)
    }

    public mutating func newLeafWithSimpleMeasure(
        _ style: TaffyStyle = .default,
        measure: @escaping SimpleMeasureFunc
    ) -> NodeId {
        allocateNode(style: style, children: [], measure: { _, avail, _ in measure(avail) })
    }

    public mutating func newWithChildren(_ style: TaffyStyle = .default, children: [NodeId]) throws -> NodeId {
        for child in children {
            guard validIndex(child) != nil else {
                throw TaffyError.invalidChildNode(child)
            }
        }
        let parentId = allocateNode(style: style, children: children, measure: nil)
        for child in children {
            if let cIdx = validIndex(child) {
                detachFromCurrentParent(child, childIndex: cIdx)
                nodes[cIdx].parent = parentId
            }
        }
        return parentId
    }

    private mutating func allocateNode(
        style: TaffyStyle,
        children: [NodeId],
        measure: MeasureFunc?
    ) -> NodeId {
        liveNodeCount += 1
        if let idx = freeIndices.popLast() {
            let gen = nodes[idx].generation
            nodes[idx].occupied = true
            nodes[idx].style = style
            nodes[idx].cache.clear()
            nodes[idx].unroundedLayout = .zero
            nodes[idx].roundedLayout = nil
            nodes[idx].parent = nil
            nodes[idx].children = children
            nodes[idx].measure = measure
            return NodeId.make(index: idx, generation: gen)
        } else {
            let idx = nodes.count
            var slot = TreeNodeData(generation: 0)
            slot.occupied = true
            slot.style = style
            slot.children = children
            slot.measure = measure
            nodes.append(slot)
            return NodeId.make(index: idx, generation: 0)
        }
    }

    @discardableResult
    public mutating func remove(_ node: NodeId) throws -> NodeId {
        guard let idx = validIndex(node) else {
            throw TaffyError.invalidInputNode(node)
        }

        // Detach from parent and mark parent dirty
        if let parent = nodes[idx].parent, let pIdx = validIndex(parent) {
            nodes[pIdx].children.removeAll { $0 == node }
            markDirtyInternal(pIdx)
        }

        // Clear parent pointers on children
        let kids = nodes[idx].children
        for child in kids {
            if let cIdx = validIndex(child) {
                nodes[cIdx].parent = nil
            }
        }

        if nodes[idx].roundedLayout != nil { roundedCount -= 1 }
        // Vacated generational slots must release the former node's cold style,
        // children, measurement closure and cache overflow while retaining capacity.
        nodes[idx] = TreeNodeData(generation: nodes[idx].generation &+ 1)
        freeIndices.append(idx)
        liveNodeCount -= 1
        return node
    }

    public mutating func clear() {
        nodes.removeAll(keepingCapacity: true)
        freeIndices.removeAll(keepingCapacity: true)
        liveNodeCount = 0
        roundedCount = 0
    }

    // MARK: - Hierarchy Mutations

    private mutating func detachFromCurrentParent(_ child: NodeId, childIndex cIdx: Int) {
        if let oldParent = nodes[cIdx].parent, let opIdx = validIndex(oldParent) {
            nodes[opIdx].children.removeAll { $0 == child }
            markDirtyInternal(opIdx)
        }
    }

    public mutating func addChild(_ parent: NodeId, child: NodeId) throws {
        guard let pIdx = validIndex(parent) else { throw TaffyError.invalidParentNode(parent) }
        guard let cIdx = validIndex(child) else { throw TaffyError.invalidChildNode(child) }
        detachFromCurrentParent(child, childIndex: cIdx)
        nodes[cIdx].parent = parent
        nodes[pIdx].children.append(child)
        markDirtyInternal(pIdx)
    }

    public mutating func insertChildAtIndex(_ parent: NodeId, index: Int, child: NodeId) throws {
        guard let pIdx = validIndex(parent) else { throw TaffyError.invalidParentNode(parent) }
        guard let cIdx = validIndex(child) else { throw TaffyError.invalidChildNode(child) }
        let count = nodes[pIdx].children.count
        guard index >= 0 && index <= count else {
            throw TaffyError.childIndexOutOfBounds(parent: parent, childIndex: index, childCount: count)
        }
        detachFromCurrentParent(child, childIndex: cIdx)
        nodes[cIdx].parent = parent
        nodes[pIdx].children.insert(child, at: index)
        markDirtyInternal(pIdx)
    }

    @discardableResult
    public mutating func removeChild(_ parent: NodeId, child: NodeId) throws -> NodeId {
        guard let pIdx = validIndex(parent) else { throw TaffyError.invalidParentNode(parent) }
        guard let cIdx = validIndex(child) else { throw TaffyError.invalidChildNode(child) }
        if let pos = nodes[pIdx].children.firstIndex(of: child) {
            nodes[pIdx].children.remove(at: pos)
            nodes[cIdx].parent = nil
            markDirtyInternal(pIdx)
        }
        return child
    }

    @discardableResult
    public mutating func removeChildAtIndex(_ parent: NodeId, index: Int) throws -> NodeId {
        guard let pIdx = validIndex(parent) else { throw TaffyError.invalidParentNode(parent) }
        let count = nodes[pIdx].children.count
        guard index >= 0 && index < count else {
            throw TaffyError.childIndexOutOfBounds(parent: parent, childIndex: index, childCount: count)
        }
        let child = nodes[pIdx].children.remove(at: index)
        if let cIdx = validIndex(child) {
            nodes[cIdx].parent = nil
        }
        markDirtyInternal(pIdx)
        return child
    }

    @discardableResult
    public mutating func replaceChildAtIndex(_ parent: NodeId, index: Int, newChild: NodeId) throws -> NodeId {
        guard let pIdx = validIndex(parent) else { throw TaffyError.invalidParentNode(parent) }
        guard let ncIdx = validIndex(newChild) else { throw TaffyError.invalidChildNode(newChild) }
        let count = nodes[pIdx].children.count
        guard index >= 0 && index < count else {
            throw TaffyError.childIndexOutOfBounds(parent: parent, childIndex: index, childCount: count)
        }
        let oldChild = nodes[pIdx].children[index]
        if let ocIdx = validIndex(oldChild) {
            nodes[ocIdx].parent = nil
        }
        detachFromCurrentParent(newChild, childIndex: ncIdx)
        nodes[ncIdx].parent = parent
        nodes[pIdx].children[index] = newChild
        markDirtyInternal(pIdx)
        return oldChild
    }

    public mutating func setChildren(_ parent: NodeId, children: [NodeId]) throws {
        guard let pIdx = validIndex(parent) else { throw TaffyError.invalidParentNode(parent) }
        for child in children {
            guard validIndex(child) != nil else { throw TaffyError.invalidChildNode(child) }
        }
        for oldChild in nodes[pIdx].children {
            if let ocIdx = validIndex(oldChild) {
                nodes[ocIdx].parent = nil
            }
        }
        for child in children {
            if let cIdx = validIndex(child) {
                detachFromCurrentParent(child, childIndex: cIdx)
                nodes[cIdx].parent = parent
            }
        }
        nodes[pIdx].children = children
        markDirtyInternal(pIdx)
    }

    public func children(_ parent: NodeId) throws -> [NodeId] {
        guard let pIdx = validIndex(parent) else { throw TaffyError.invalidParentNode(parent) }
        return nodes[pIdx].children
    }

    public func childCount(_ parent: NodeId) throws -> Int {
        guard let pIdx = validIndex(parent) else { throw TaffyError.invalidParentNode(parent) }
        return nodes[pIdx].children.count
    }

    public func parent(_ child: NodeId) throws -> NodeId? {
        guard let cIdx = validIndex(child) else { throw TaffyError.invalidChildNode(child) }
        return nodes[cIdx].parent
    }

    // MARK: - Style, Measure & Dirty Propagation

    public func style(_ node: NodeId) throws -> TaffyStyle {
        guard let idx = validIndex(node) else { throw TaffyError.invalidInputNode(node) }
        return nodes[idx].style
    }

    public mutating func setStyle(_ node: NodeId, _ style: TaffyStyle) throws {
        guard let idx = validIndex(node) else { throw TaffyError.invalidInputNode(node) }
        if nodes[idx].style != style {
            nodes[idx].style = style
            markDirtyInternal(idx)
        }
    }

    public mutating func setMeasureFunc(_ node: NodeId, measure: MeasureFunc?) throws {
        guard let idx = validIndex(node) else { throw TaffyError.invalidInputNode(node) }
        nodes[idx].measure = measure
        markDirtyInternal(idx)
    }

    public mutating func markDirty(_ node: NodeId) throws {
        guard let idx = validIndex(node) else { throw TaffyError.invalidInputNode(node) }
        markDirtyInternal(idx)
    }

    public func dirty(_ node: NodeId) throws -> Bool {
        guard let idx = validIndex(node) else { throw TaffyError.invalidInputNode(node) }
        return isNodeCacheEmpty(idx)
    }

    private func isNodeCacheEmpty(_ idx: Int) -> Bool {
        var copy = nodes[idx].cache
        return copy.clear() == .alreadyEmpty
    }

    private mutating func markDirtyInternal(_ startIdx: Int) {
        var current: Int? = startIdx
        while let idx = current {
            let state = nodes[idx].cache.clear()
            if state == .alreadyEmpty {
                break
            }
            if let p = nodes[idx].parent, let pIdx = validIndex(p) {
                current = pIdx
            } else {
                current = nil
            }
        }
    }

    // MARK: - Layout Computation & Queries

    public mutating func computeLayout(
        _ root: NodeId,
        availableSpace: Size<AvailableSpace>
    ) throws {
        try computeLayout(root, availableSpace: availableSpace, measureLeaf: nil)
    }

    internal mutating func computeLayout(
        _ root: NodeId, availableSpace: Size<AvailableSpace>,
        measureLeaf: (@Sendable (NodeId, LayoutInput, TaffyStyle) -> LayoutOutput)?
    ) throws {
        guard validIndex(root) != nil else { throw TaffyError.invalidInputNode(root) }
        let adapter = TaffyTreeAdapter(measureLeaf: measureLeaf)
        swap(&nodes, &adapter.nodes)
        adapter.roundedCount = roundedCount
        computeRootLayout(tree: adapter, root: root, availableSpace: availableSpace)
        if roundingEnabled {
            roundLayout(tree: adapter, root: root)
        } else if adapter.roundedCount > 0 {
            clearRounding(adapter: adapter, node: root)
        }
        roundedCount = adapter.roundedCount
        swap(&nodes, &adapter.nodes)
    }

    private func clearRounding(adapter: TaffyTreeAdapter, node: NodeId) {
        if adapter.nodes[node.index].roundedLayout != nil {
            adapter.nodes[node.index].roundedLayout = nil
            adapter.roundedCount -= 1
        }
        let count = adapter.childCount(node)
        for i in 0..<count {
            clearRounding(adapter: adapter, node: adapter.childId(node, at: i))
        }
    }

    public func layout(_ node: NodeId) throws -> Layout {
        guard let idx = validIndex(node) else { throw TaffyError.invalidInputNode(node) }
        if roundingEnabled, let rounded = nodes[idx].roundedLayout { return rounded }
        return nodes[idx].unroundedLayout
    }

    public func unroundedLayout(_ node: NodeId) throws -> Layout {
        guard let idx = validIndex(node) else { throw TaffyError.invalidInputNode(node) }
        return nodes[idx].unroundedLayout
    }

    public func printTree(_ root: NodeId) -> String {
        var out = ""
        appendTreeString(node: root, depth: 0, into: &out)
        return out
    }

    private func appendTreeString(node: NodeId, depth: Int, into out: inout String) {
        guard let idx = validIndex(node) else { return }
        let indent = String(repeating: "  ", count: depth)
        let l = roundingEnabled ? (nodes[idx].roundedLayout ?? nodes[idx].unroundedLayout) : nodes[idx].unroundedLayout
        let s = nodes[idx].style
        out += "\(indent)Node(\(node.index):\(node.generation)) [\(s.display)] x:\(l.location.x) y:\(l.location.y) w:\(l.size.width) h:\(l.size.height)\n"
        for child in nodes[idx].children {
            appendTreeString(node: child, depth: depth + 1, into: &out)
        }
    }
}

private final class TaffyTreeAdapter: LayoutTree {
    var nodes: [TreeNodeData] = []
    var roundedCount = 0
    let measureLeaf: (@Sendable (NodeId, LayoutInput, TaffyStyle) -> LayoutOutput)?

    init(measureLeaf: (@Sendable (NodeId, LayoutInput, TaffyStyle) -> LayoutOutput)?) {
        self.measureLeaf = measureLeaf
    }

    func childCount(_ node: NodeId) -> Int {
        nodes[node.index].children.count
    }

    func childId(_ node: NodeId, at index: Int) -> NodeId {
        nodes[node.index].children[index]
    }

    func style(_ node: NodeId) -> TaffyStyle {
        nodes[node.index].style
    }

    func unroundedLayout(_ node: NodeId) -> Layout {
        nodes[node.index].unroundedLayout
    }

    func setUnroundedLayout(_ node: NodeId, _ layout: Layout) {
        nodes[node.index].unroundedLayout = layout
    }

    func setFinalLayout(_ node: NodeId, _ layout: Layout) {
        if nodes[node.index].roundedLayout == nil { roundedCount += 1 }
        nodes[node.index].roundedLayout = layout
    }

    func cacheGet(_ node: NodeId, _ input: LayoutInput) -> LayoutOutput? {
        nodes[node.index].cache.get(input)
    }

    func cacheStore(_ node: NodeId, _ input: LayoutInput, _ output: LayoutOutput) {
        nodes[node.index].cache.store(input, output: output)
    }

    func measureLeafNode(_ node: NodeId, _ input: LayoutInput) -> LayoutOutput {
        let slot = nodes[node.index]
        if let measureLeaf { return measureLeaf(node, input, slot.style) }
        if let measure = slot.measure {
            let size = measure(input.knownDimensions, input.availableSpace, slot.style)
            return LayoutOutput.fromOuterSize(size)
        }
        return LayoutOutput.fromOuterSize(.zero)
    }
}

extension TaffyTree {
    /// Retained Swift node, child, style and cache buffers for the reference backend.
    public func storageStats() -> StorageStats {
        let stride = MemoryLayout<TreeNodeData>.stride
        let buffer = nodes.capacity * stride + freeIndices.capacity * MemoryLayout<Int>.stride
        var children = 0
        var styles = 0
        var caches = 0
        for node in nodes {
            children += node.children.capacity * MemoryLayout<NodeId>.stride
            styles += node.style.heapBytes()
            caches += node.cache.heapBytes()
        }
        return StorageStats(liveNodes: liveNodeCount, slotCapacity: nodes.capacity, sparseCapacity: nodes.capacity,
            bytesPerSlot: stride, inlineBufferBytes: buffer, childHeapBytes: children,
            coldStyleBytes: styles, coldCacheBytes: caches, totalRetainedBytes: buffer + children + styles + caches)
    }
}
