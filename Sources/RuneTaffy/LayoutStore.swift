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

/// Flat open-addressed `UInt64 -> UInt32` map using Fibonacci hashing and backward-shift
/// deletion (zero tombstones, single cache-line probe per entry, no SipHash overhead).
private struct SlotIndexEntry: Sendable {
    var key: UInt64 = 0
    var val: UInt32 = unmountedIdx
}

private struct SlotIndexMap: Sendable {
    private var entries: [SlotIndexEntry]
    private var shift: UInt32
    private(set) var count: Int = 0

    init(minimumCapacity: Int = 32) {
        let cap = Self.tableSize(forElements: minimumCapacity)
        self.entries = Array(repeating: SlotIndexEntry(), count: cap)
        self.shift = UInt32(64 - cap.trailingZeroBitCount)
    }

    var capacity: Int { entries.count }

    @inline(__always)
    private static func tableSize(forElements n: Int) -> Int {
        let needed = Swift.max(32, (n * 10 + 6) / 7)
        var cap = 32
        while cap < needed { cap &<<= 1 }
        return cap
    }

    @inline(__always)
    private func bucket(_ key: UInt64) -> Int {
        Int((key &* 0x9E37_79B9_7F4A_7C15) &>> shift)
    }

    @inline(__always)
    func get(_ key: UInt64) -> UInt32? {
        let mask = entries.count - 1
        var idx = bucket(key)
        return entries.withUnsafeBufferPointer { buf in
            while true {
                let entry = buf[idx]
                if entry.val == unmountedIdx { return nil }
                if entry.key == key { return entry.val }
                idx = (idx + 1) & mask
            }
        }
    }

    private mutating func grow() {
        let newCap = entries.count &<< 1
        let newShift = UInt32(64 - newCap.trailingZeroBitCount)
        let mask = newCap - 1
        var newEntries = Array(repeating: SlotIndexEntry(), count: newCap)
        newEntries.withUnsafeMutableBufferPointer { dst in
            entries.withUnsafeBufferPointer { src in
                for i in 0..<src.count {
                    let e = src[i]
                    if e.val == unmountedIdx { continue }
                    var idx = Int((e.key &* 0x9E37_79B9_7F4A_7C15) &>> newShift)
                    while dst[idx].val != unmountedIdx {
                        idx = (idx + 1) & mask
                    }
                    dst[idx] = e
                }
            }
        }
        entries = newEntries
        shift = newShift
    }

    @inline(__always)
    mutating func set(_ key: UInt64, _ value: UInt32) {
        if (count + 1) * 10 >= entries.count * 7 {
            grow()
        }
        let mask = entries.count - 1
        var idx = bucket(key)
        var inserted = false
        entries.withUnsafeMutableBufferPointer { buf in
            while true {
                let v = buf[idx].val
                if v == unmountedIdx {
                    buf[idx] = SlotIndexEntry(key: key, val: value)
                    inserted = true
                    return
                }
                if buf[idx].key == key {
                    buf[idx].val = value
                    return
                }
                idx = (idx + 1) & mask
            }
        }
        if inserted { count += 1 }
    }

    @discardableResult
    mutating func remove(_ key: UInt64) -> UInt32? {
        let mask = entries.count - 1
        var idx = bucket(key)
        while true {
            let v = entries[idx].val
            if v == unmountedIdx { return nil }
            if entries[idx].key == key {
                count -= 1
                var hole = idx
                var cur = (hole + 1) & mask
                while entries[cur].val != unmountedIdx {
                    let ideal = bucket(entries[cur].key)
                    if ((hole &- ideal) & mask) < ((cur &- ideal) & mask) {
                        entries[hole] = entries[cur]
                        hole = cur
                    }
                    cur = (cur + 1) & mask
                }
                entries[hole].val = unmountedIdx
                return v
            }
            idx = (idx + 1) & mask
        }
    }

    @inline(__always)
    func forEach(_ body: (UInt64, UInt32) -> Void) {
        for i in entries.indices {
            let e = entries[i]
            if e.val != unmountedIdx {
                body(e.key, e.val)
            }
        }
    }

    @inline(__always)
    func forEachValue(_ body: (UInt32) -> Void) {
        for i in entries.indices {
            let v = entries[i].val
            if v != unmountedIdx {
                body(v)
            }
        }
    }
}

/// Rare unrounded layout fields moved out of `RetainedSlot` so common nodes fit in 200 bytes.
private struct ColdLayoutAux: Sendable {
    var contentSize: Size<Float> = .zero
    var scrollbarSize: Size<Float> = .zero
    var border: Rect<Float> = .zero
    var padding: Rect<Float> = .zero
    var margin: Rect<Float> = .zero
}

private struct RetainedSlot: Sendable {
    private static let childLenMask: UInt32 = 0x03FF_FFFF
    private static let hasContextBit: UInt32 = 1 << 26
    private static let mutatedBit: UInt32 = 1 << 27
    private static let contentModeShift: UInt32 = 28
    private static let edgesModeShift: UInt32 = 30
    private static let coldAuxMask: UInt32 = 0xA000_0000 // contentMode == 2 || edgesMode == 2

    var style: TaffyStyle = .default
    var cache: Cache = Cache()
    var measure: UInt64 = 0
    var location: Point<Float> = .zero
    var size: Size<Float> = .zero
    var order: UInt32 = 0
    var childStart: UInt32 = 0
    var childLenAndFlags: UInt32 = 0

    @inline(__always)
    var childLen: Int {
        get { Int(childLenAndFlags & Self.childLenMask) }
        set { childLenAndFlags = (childLenAndFlags & ~Self.childLenMask) | (UInt32(newValue) & Self.childLenMask) }
    }

    @inline(__always)
    var hasContext: Bool {
        get { (childLenAndFlags & Self.hasContextBit) != 0 }
        set {
            if newValue { childLenAndFlags |= Self.hasContextBit }
            else { childLenAndFlags &= ~Self.hasContextBit }
        }
    }

    @inline(__always)
    var mutated: Bool {
        get { (childLenAndFlags & Self.mutatedBit) != 0 }
        set {
            if newValue { childLenAndFlags |= Self.mutatedBit }
            else { childLenAndFlags &= ~Self.mutatedBit }
        }
    }

    /// 0 = `.zero`, 1 = same as `size`, 2 = stored in `coldAux`.
    @inline(__always)
    var contentSizeMode: UInt32 {
        get { (childLenAndFlags >> Self.contentModeShift) & 3 }
        set {
            childLenAndFlags = (childLenAndFlags & ~(3 << Self.contentModeShift)) | ((newValue & 3) << Self.contentModeShift)
        }
    }

    /// 0 = all edges `.zero`, 1 = `padding == style.inlinePaddingValues` & other edges `.zero`, 2 = stored in `coldAux`.
    @inline(__always)
    var edgesMode: UInt32 {
        get { (childLenAndFlags >> Self.edgesModeShift) & 3 }
        set {
            childLenAndFlags = (childLenAndFlags & ~(3 << Self.edgesModeShift)) | ((newValue & 3) << Self.edgesModeShift)
        }
    }

    @inline(__always)
    var hasColdAux: Bool {
        (childLenAndFlags & Self.coldAuxMask) != 0
    }

    @inline(__always)
    func reconstructLayout(slotRaw: UInt32, coldAux: [UInt32: ColdLayoutAux]) -> Layout {
        let cMode = contentSizeMode
        let eMode = edgesMode
        if !hasColdAux {
            let cs = cMode == 1 ? size : .zero
            let pad = eMode == 1 ? style.inlinePaddingValues : .zero
            return Layout(
                order: order,
                location: location,
                size: size,
                contentSize: cs,
                scrollbarSize: .zero,
                border: .zero,
                padding: pad,
                margin: .zero
            )
        }
        let aux = coldAux[slotRaw] ?? ColdLayoutAux()
        let cs = cMode == 2 ? aux.contentSize : (cMode == 1 ? size : .zero)
        let pad = eMode == 2 ? aux.padding : (eMode == 1 ? style.inlinePaddingValues : .zero)
        let border = eMode == 2 ? aux.border : .zero
        let margin = eMode == 2 ? aux.margin : .zero
        let sb = eMode == 2 ? aux.scrollbarSize : .zero
        return Layout(
            order: order,
            location: location,
            size: size,
            contentSize: cs,
            scrollbarSize: sb,
            border: border,
            padding: pad,
            margin: margin
        )
    }

    @inline(__always)
    func reconstructBoxLayout(slotRaw: UInt32, coldAux: [UInt32: ColdLayoutAux]) -> BoxLayout {
        let eMode = edgesMode
        if eMode == 0 {
            return BoxLayout(x: location.x, y: location.y, w: size.width, h: size.height, inset: (0, 0, 0, 0))
        }
        if eMode == 1 {
            let p = style.inlinePaddingValues
            return BoxLayout(x: location.x, y: location.y, w: size.width, h: size.height,
                             inset: (p.left, p.top, p.right, p.bottom))
        }
        let aux = coldAux[slotRaw] ?? ColdLayoutAux()
        return BoxLayout(
            x: location.x,
            y: location.y,
            w: size.width,
            h: size.height,
            inset: (
                aux.padding.left + aux.border.left,
                aux.padding.top + aux.border.top,
                aux.padding.right + aux.border.right,
                aux.padding.bottom + aux.border.bottom
            )
        )
    }

    @inline(__always)
    mutating func storeUnroundedLayout(_ layout: Layout, slotRaw: UInt32, coldAux: inout [UInt32: ColdLayoutAux]) {
        location = layout.location
        size = layout.size
        order = layout.order

        let cMode: UInt32
        if layout.contentSize == .zero {
            cMode = 0
        } else if layout.contentSize == layout.size {
            cMode = 1
        } else {
            cMode = 2
        }

        let eMode: UInt32
        if layout.border == .zero && layout.margin == .zero && layout.scrollbarSize == .zero {
            if layout.padding == .zero {
                eMode = 0
            } else if !style.hasPercentPadding && layout.padding == style.inlinePaddingValues {
                eMode = 1
            } else {
                eMode = 2
            }
        } else {
            eMode = 2
        }

        let hadCold = hasColdAux
        contentSizeMode = cMode
        edgesMode = eMode
        if cMode == 2 || eMode == 2 {
            coldAux[slotRaw] = ColdLayoutAux(
                contentSize: layout.contentSize,
                scrollbarSize: layout.scrollbarSize,
                border: layout.border,
                padding: layout.padding,
                margin: layout.margin
            )
        } else if hadCold {
            coldAux.removeValue(forKey: slotRaw)
        }
    }

    /// Preserve previously computed padding if style changes before the next layout pass.
    @inline(__always)
    mutating func preserveStylePaddingIfNeeded(
        newStyle: TaffyStyle,
        slotRaw: UInt32,
        coldAux: inout [UInt32: ColdLayoutAux]
    ) {
        guard edgesMode == 1 else { return }
        if newStyle.hasPercentPadding || newStyle.inlinePaddingValues != style.inlinePaddingValues {
            var aux = contentSizeMode == 2 ? (coldAux[slotRaw] ?? ColdLayoutAux()) : ColdLayoutAux()
            aux.padding = style.inlinePaddingValues
            coldAux[slotRaw] = aux
            edgesMode = 2
        }
    }
}

/// Retained flat-arena layout store integrated with commit-pass reconciliation
/// (mirroring `rune_taffy::LayoutStore`).
public struct LayoutStore: Sendable {
    private var slots: [RetainedSlot] = []
    private var nodeIdx: [UInt32] = []
    private var byKey: SlotIndexMap
    private var free: [UInt32] = []
    private var prevChildren: [UInt32] = []
    private var currChildren: [UInt32] = []
    private var childScratch: [UInt32] = []
    private var mutatedSlots: [UInt32] = []
    private var coldAux: [UInt32: ColdLayoutAux] = [:]
    // Rune presents unrounded geometry; allocate overrides only for callers requesting pixel rounding.
    private var roundedLayouts: [UInt32: Layout] = [:]
    private var prevLive: Int = 0
    private var visitedExisting: Int = 0

    public init(capacity: Int = 32) {
        slots.reserveCapacity(capacity)
        nodeIdx.reserveCapacity(capacity)
        byKey = SlotIndexMap(minimumCapacity: capacity)
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
        nodeIdx.withUnsafeMutableBufferPointer { buf in
            buf.update(repeating: unmountedIdx)
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
        return byKey.get(key) == slot.rawValue
            && idx < nodeIdx.count
            && nodeIdx[idx] == unmountedIdx
            && !slots[idx].mutated
    }

    public func isUsedThisCommit(key: UInt64) -> Bool {
        guard let s = byKey.get(key) else { return false }
        let idx = Int(s)
        return idx < nodeIdx.count && nodeIdx[idx] != unmountedIdx
    }

    public mutating func reuseSlot(_ slot: SlotId, nodeIndex: UInt32) {
        let idx = Int(slot.rawValue)
        if nodeIdx[idx] == unmountedIdx {
            visitedExisting += 1
        }
        nodeIdx[idx] = nodeIndex
        let oldStart = Int(slots[idx].childStart)
        let len = slots[idx].childLen
        let newStart = currChildren.count
        if len > 0 {
            let needed = newStart + len
            if needed > currChildren.capacity {
                currChildren.reserveCapacity(Swift.max(needed, newStart + (newStart >> 1)))
            }
            currChildren.append(contentsOf: prevChildren[oldStart..<(oldStart + len)])
        }
        slots[idx].childStart = UInt32(newStart)
    }

    /// Rebases a sequence of `(oldKey, newKey, slot, nodeIndex)` entries when a memoized subtree
    /// moves to a new parent path, preserving each slot's warm cache and children.
    public mutating func rekeyAndReuseBatch<S: Sequence>(_ items: S) where S.Element == (UInt64, UInt64, SlotId, UInt32) {
        let batch = Array(items)
        for (oldKey, _, slot, _) in batch {
            let removed = byKey.remove(oldKey)
            assert(removed == slot.rawValue, "rekeyAndReuseBatch: oldKey \(oldKey) did not map to slot \(slot.rawValue)")
        }
        for (_, newKey, slot, nodeIndex) in batch {
            if let stale = byKey.remove(newKey) {
                roundedLayouts.removeValue(forKey: stale)
                coldAux.removeValue(forKey: stale)
                slots[Int(stale)] = RetainedSlot()
                free.append(stale)
                if prevLive > 0 {
                    prevLive -= 1
                }
            }
            byKey.set(newKey, slot.rawValue)
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
        let childLen = childScratch.count - childMark
        let childStart = currChildren.count
        if childLen == 1 {
            currChildren.append(childScratch[childMark])
        } else if childLen == 2 {
            currChildren.append(childScratch[childMark])
            currChildren.append(childScratch[childMark + 1])
        } else if childLen > 0 {
            let needed = childStart + childLen
            if needed > currChildren.capacity {
                currChildren.reserveCapacity(Swift.max(needed, childStart + (childStart >> 1)))
            }
            currChildren.append(contentsOf: childScratch[childMark...])
        }

        if let s = byKey.get(key) {
            let idx = Int(s)
            let firstVisit = nodeIdx[idx] == unmountedIdx
            if firstVisit {
                visitedExisting += 1
            }
            nodeIdx[idx] = nodeIndex

            var dirty = false
            var markMutated = false
            slots.withUnsafeMutableBufferPointer { slotBuf in
                let oldStart = Int(slotBuf[idx].childStart)
                let oldLen = slotBuf[idx].childLen
                let kidsChanged: Bool
                if oldLen != childLen {
                    kidsChanged = true
                } else if childLen == 0 {
                    kidsChanged = false
                } else if firstVisit {
                    kidsChanged = prevChildren.withUnsafeBufferPointer { prevBuf in
                        childScratch.withUnsafeBufferPointer { scratchBuf in
                            for k in 0..<childLen {
                                if prevBuf[oldStart + k] != scratchBuf[childMark + k] { return true }
                            }
                            return false
                        }
                    }
                } else {
                    kidsChanged = currChildren.withUnsafeBufferPointer { currBuf in
                        for k in 0..<childLen {
                            if currBuf[oldStart + k] != currBuf[childStart + k] { return true }
                        }
                        return false
                    }
                }

                let styleChanged = slotBuf[idx].style != style
                if styleChanged {
                    slotBuf[idx].preserveStylePaddingIfNeeded(newStyle: style, slotRaw: s, coldAux: &coldAux)
                    slotBuf[idx].style = style
                }
                slotBuf[idx].childStart = UInt32(childStart)
                slotBuf[idx].childLen = childLen

                let hadMeasure = slotBuf[idx].hasContext
                let hasMeasure = measure != nil
                let newM = measure ?? 0
                let measureChanged = hadMeasure != hasMeasure || (hasMeasure && (forceMeasureDirty || slotBuf[idx].measure != newM))

                let wasMutated = slotBuf[idx].mutated
                let nowMutated = wasMutated || styleChanged || kidsChanged || measureChanged
                if hadMeasure != hasMeasure { slotBuf[idx].hasContext = hasMeasure }
                if wasMutated != nowMutated { slotBuf[idx].mutated = nowMutated }
                if hasMeasure { slotBuf[idx].measure = newM } else if hadMeasure { slotBuf[idx].measure = 0 }

                dirty = styleChanged || kidsChanged || measureChanged || childrenDirty
                if dirty {
                    slotBuf[idx].cache.clear()
                }
                markMutated = nowMutated && !wasMutated
            }
            if markMutated {
                mutatedSlots.append(s)
            }
            if childLen > 0 {
                childScratch.removeLast(childLen)
            }
            return (SlotId(s), dirty)
        } else {
            if childLen > 0 {
                childScratch.removeLast(childLen)
            }
            var slot = RetainedSlot()
            slot.style = style
            slot.measure = measure ?? 0
            slot.childStart = UInt32(childStart)
            slot.childLen = childLen
            slot.hasContext = measure != nil
            slot.mutated = true
            let s: UInt32
            if let freeS = free.popLast() {
                s = freeS
                slots[Int(freeS)] = slot
                nodeIdx[Int(freeS)] = nodeIndex
            } else {
                if slots.count == slots.capacity {
                    let nextCap = Swift.max(32, slots.count + (slots.count >> 1))
                    slots.reserveCapacity(nextCap)
                    nodeIdx.reserveCapacity(nextCap)
                }
                s = UInt32(slots.count)
                slots.append(slot)
                nodeIdx.append(nodeIndex)
            }
            mutatedSlots.append(s)
            byKey.set(key, s)
            return (SlotId(s), true)
        }
    }

    public mutating func finishFlatten() {
        if visitedExisting == prevLive { return }
        var toRemove: [UInt64] = []
        byKey.forEach { k, s in
            if nodeIdx[Int(s)] == unmountedIdx {
                roundedLayouts.removeValue(forKey: s)
                coldAux.removeValue(forKey: s)
                slots[Int(s)] = RetainedSlot()
                free.append(s)
                toRemove.append(k)
            }
        }
        for k in toRemove {
            byKey.remove(k)
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
        var newByKey = SlotIndexMap(minimumCapacity: cap)

        byKey.forEach { key, oldRaw in
            let oldS = Int(oldRaw)
            let newS = UInt32(newSlots.count)
            remapTable[oldS] = newS
            var slot = slots[oldS]
            slots[oldS] = RetainedSlot()
            _ = slot.cache.clear()
            let me = nodeIdx[oldS]
            remap(me, SlotId(newS))
            newByKey.set(key, newS)
            newSlots.append(slot)
            newNodeIdx.append(me)
        }

        if !coldAux.isEmpty {
            var nextAux: [UInt32: ColdLayoutAux] = [:]
            nextAux.reserveCapacity(coldAux.count)
            for (oldKey, aux) in coldAux {
                let mapped = remapTable[Int(oldKey)]
                if mapped != unmountedIdx {
                    nextAux[mapped] = aux
                }
            }
            coldAux = nextAux
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
        let idx = Int(parent.rawValue)
        let start = Int(slots[idx].childStart)
        let end = start + slots[idx].childLen
        return SlotChildIter(currChildren[start..<end])
    }

    public func style(_ id: SlotId) -> TaffyStyle {
        slots[Int(id.rawValue)].style
    }

    public func boxLayout(_ id: SlotId) -> BoxLayout {
        let idx = Int(id.rawValue)
        return slots[idx].reconstructBoxLayout(slotRaw: id.rawValue, coldAux: coldAux)
    }

    public func layout(_ id: SlotId) -> Layout {
        if !roundedLayouts.isEmpty, let rounded = roundedLayouts[id.rawValue] { return rounded }
        let idx = Int(id.rawValue)
        return slots[idx].reconstructLayout(slotRaw: id.rawValue, coldAux: coldAux)
    }

    public func mountedNodeIndex(key: UInt64) -> Int? {
        guard let s = byKey.get(key) else { return nil }
        let idx = nodeIdx[Int(s)]
        return idx == unmountedIdx ? nil : Int(idx)
    }

    public func measureHash(key: UInt64) -> UInt64?? {
        guard let s = byKey.get(key) else { return nil }
        let idx = Int(s)
        return .some(slots[idx].hasContext ? slots[idx].measure : nil)
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
        slots[idx].preserveStylePaddingIfNeeded(newStyle: style, slotRaw: id.rawValue, coldAux: &coldAux)
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
        byKey.forEachValue { s in
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
        swap(&coldAux, &adapter.coldAux)
        swap(&roundedLayouts, &adapter.roundedLayouts)
        let rootNode = root.toNodeId
        computeRootLayout(tree: adapter, root: rootNode, availableSpace: availableSpace)
        if rounding {
            roundLayout(tree: adapter, root: rootNode)
        } else if !adapter.roundedLayouts.isEmpty {
            clearRounding(adapter: adapter, node: rootNode)
        }
        swap(&roundedLayouts, &adapter.roundedLayouts)
        swap(&coldAux, &adapter.coldAux)
        swap(&slots, &adapter.slots)
    }

    private func clearRounding(adapter: LayoutStoreAdapter, node: NodeId) {
        adapter.visitSubtree(node, inheriting: ()) { child, _ in
            adapter.roundedLayouts.removeValue(forKey: UInt32(child.index))
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
        byKey.forEachValue { s in
            let idx = Int(s)
            coldStyleBytes += slots[idx].style.heapBytes()
            coldCacheBytes += slots[idx].cache.heapBytes()
        }
        let coldAuxBytes = roundedLayouts.capacity * (MemoryLayout<UInt32>.stride + MemoryLayout<Layout>.stride)
            + coldAux.capacity * (MemoryLayout<UInt32>.stride + MemoryLayout<ColdLayoutAux>.stride)
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

/// Stable identities captured with a prepared subtree. The slot can be recycled after
/// omission or compaction, so the key is always checked before claiming a run.
package struct RetainedLayoutKey: Sendable {
    package let key: UInt64
    package let slot: SlotId

    package init(key: UInt64, slot: SlotId) {
        self.key = key
        self.slot = slot
    }
}

extension LayoutEngine {
    package func canReuse(_ nodes: ArraySlice<RetainedLayoutKey>) -> Bool {
        for node in nodes where !canReuse(key: node.key, slot: node.slot) { return false }
        return true
    }

    package mutating func reuseSlots(_ nodes: ArraySlice<RetainedLayoutKey>, startingAt index: UInt32) {
        var next = index
        for node in nodes {
            reuseSlot(node.slot, nodeIndex: next)
            next += 1
        }
    }

    /// The saved boxes are recorded in extraction order, from the last descendant back.
    package func geometryMatches(_ nodes: ArraySlice<RetainedLayoutKey>, reversedBoxes: [Layout]) -> Bool {
        guard nodes.count == reversedBoxes.count else { return false }
        for (node, expected) in zip(nodes.reversed(), reversedBoxes) {
            if layout(node.slot) != expected { return false }
        }
        return true
    }
}

private final class LayoutStoreAdapter: LayoutTree {
    var containerDepth: Int = 0
    var slots: [RetainedSlot] = []
    var coldAux: [UInt32: ColdLayoutAux] = [:]
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

    @inline(__always)
    func childCount(_ node: NodeId) -> Int {
        slots[node.index].childLen
    }

    @inline(__always)
    func childId(_ node: NodeId, at index: Int) -> NodeId {
        let start = Int(slots[node.index].childStart)
        return NodeId(UInt64(currChildren[start + index]))
    }

    @inline(__always)
    func style(_ node: NodeId) -> TaffyStyle {
        slots[node.index].style
    }

    @inline(__always)
    func unroundedLayout(_ node: NodeId) -> Layout {
        let idx = node.index
        return slots[idx].reconstructLayout(slotRaw: UInt32(idx), coldAux: coldAux)
    }

    @inline(__always)
    func setUnroundedLayout(_ node: NodeId, _ layout: Layout) {
        let idx = node.index
        slots[idx].storeUnroundedLayout(layout, slotRaw: UInt32(idx), coldAux: &coldAux)
    }

    @inline(__always)
    func setFinalLayout(_ node: NodeId, _ layout: Layout) {
        roundedLayouts[UInt32(node.index)] = layout
    }

    @inline(__always)
    func cacheClear(_ node: NodeId) {
        slots[node.index].cache.clear()
    }

    @inline(__always)
    func cacheGet(_ node: NodeId, _ input: LayoutInput) -> LayoutOutput? {
        slots[node.index].cache.get(input)
    }

    @inline(__always)
    func cacheStore(_ node: NodeId, _ input: LayoutInput, _ output: LayoutOutput) {
        slots[node.index].cache.store(input, output: output)
    }

    @inline(__always)
    func measureLeafNode(_ node: NodeId, _ style: TaffyStyle, _ input: LayoutInput) -> LayoutOutput {
        let idx = node.index
        let ctx: Int? = slots[idx].hasContext ? Int(nodeIdx[idx]) : nil
        return measureLeaf(input, ctx, style)
    }
}
