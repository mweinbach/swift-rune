import Testing
@testable import RuneTaffy
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
private struct ConstrainedThreadBox {
    var run: () -> Void
}

#if canImport(Darwin)
private func constrainedThreadEntry(_ raw: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    raw.assumingMemoryBound(to: ConstrainedThreadBox.self).pointee.run()
    return nil
}
#else
private func constrainedThreadEntry(_ raw: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    raw?.assumingMemoryBound(to: ConstrainedThreadBox.self).pointee.run()
    return nil
}
#endif

/// Runs `body` on a dedicated pthread with a tight `stackBytes` stack to exercise stack continuation.
private func runOnConstrainedThread(stackBytes: Int, _ body: () -> Void) {
    withoutActuallyEscaping(body) { escapingBody in
        var box = ConstrainedThreadBox(run: escapingBody)
        withUnsafeMutablePointer(to: &box) { boxPtr in
            var attr = pthread_attr_t()
            precondition(pthread_attr_init(&attr) == 0)
            defer { _ = pthread_attr_destroy(&attr) }
            precondition(pthread_attr_setstacksize(&attr, stackBytes) == 0)
            #if canImport(Darwin) || canImport(Musl)
            var thread: pthread_t?
            precondition(pthread_create(&thread, &attr, constrainedThreadEntry, boxPtr) == 0)
            if let created = thread {
                _ = pthread_join(created, nil)
            }
            #else
            var thread = pthread_t()
            precondition(pthread_create(&thread, &attr, constrainedThreadEntry, boxPtr) == 0)
            _ = pthread_join(thread, nil)
            #endif
        }
    }
}
#endif

@Test func fixedFlexSiblingsSkipRedundantIntrinsicMeasurements() throws {
    final class Measurements: @unchecked Sendable {
        var minimums = 0
    }
    let measurements = Measurements()
    var tree = TaffyTree()
    let style = TaffyStyle(size: Size(width: .length(80), height: .length(20)), flexShrink: 0)
    let first = tree.newLeafWithSimpleMeasure(style) { available in
        if available.width == .minContent { measurements.minimums += 1 }
        return Size(width: 65, height: 20)
    }
    let second = tree.newLeaf(style)
    let root = try tree.newWithChildren(
        TaffyStyle(size: Size(width: .length(110), height: .length(20))),
        children: [first, second]
    )
    try tree.computeLayout(root, availableSpace: .maxContent)
    #expect(measurements.minimums == 0)
    #expect(try tree.layout(first).size.width == 80)
    #expect(try tree.layout(second).location.x == 80)

    // A smaller flex basis still needs the intrinsic floor, even for an inflexible item.
    var smaller = style
    smaller.flexBasis = .length(40)
    try tree.setStyle(first, smaller)
    try tree.computeLayout(root, availableSpace: .maxContent)
    #expect(measurements.minimums > 0)
    #expect(try tree.layout(first).size.width == 65)
    #expect(try tree.layout(second).location.x == 65)
}

@Test func deepFixedFlexContainersRetainLeafGeometryAfterHideAndShow() throws {
    var tree = TaffyTree()
    let container = TaffyStyle(size: Size(width: .length(100), height: .length(100)))
    let leaf = tree.newLeafWithSimpleMeasure(TaffyStyle(size: Size(width: .length(90.5), height: .length(25)))) { _ in
        Size(width: 130, height: 42)
    }
    var root = leaf
    for _ in 0..<1_024 {
        root = try tree.newWithChildren(container, children: [root])
    }
    let absolute = tree.newLeaf(TaffyStyle(position: .absolute, size: Size(width: .length(11), height: .length(17))))
    root = try tree.newWithChildren(container, children: [root, absolute])
    try tree.computeLayout(root, availableSpace: .maxContent)
    #expect(try tree.layout(leaf).size == Size(width: 91, height: 25))
    #expect(try tree.unroundedLayout(leaf).contentSize == Size(width: 130, height: 42))

    var hidden = container
    hidden.display = .none
    try tree.setStyle(root, hidden)
    try tree.computeLayout(root, availableSpace: .maxContent)
    #expect(try tree.layout(leaf).size == .zero)
    #expect(try tree.layout(absolute).size == .zero)

    tree.roundingEnabled = false
    try tree.setStyle(root, container)
    try tree.computeLayout(root, availableSpace: .maxContent)
    #expect(try tree.layout(leaf).size == Size(width: 90.5, height: 25))
    #expect(try tree.layout(absolute).size == Size(width: 11, height: 17))
    #expect(try tree.layout(leaf).contentSize == Size(width: 130, height: 42))
}

@Suite("Deep container stack continuation", .serialized)
struct DeepContainerStackContinuationTests {
    @Test func deepUncachedMultiChildFlexContainersComputeExactLeafBounds() throws {
        let depth = 400
        var tree = TaffyTree()
        tree.roundingEnabled = false

        let leaf = tree.newLeaf(TaffyStyle(
            size: Size(width: .length(37.5), height: .length(19.25)),
            flexShrink: 0
        ))
        let bulletStyle = TaffyStyle(
            size: Size(width: .length(6), height: .length(4)),
            flexShrink: 0
        )
        let rowStyle = TaffyStyle(
            display: .flex,
            padding: Rect(left: .length(1), right: .zero, top: .length(1), bottom: .zero),
            flexDirection: .row,
            flexShrink: 0
        )

        var current = leaf
        var chain: [NodeId] = [leaf]
        chain.reserveCapacity(depth + 1)
        for _ in 0..<depth {
            // Two children per level force full recursive ComputeSize + PerformLayout (not single-child trampoline).
            let bullet = tree.newLeaf(bulletStyle)
            current = try tree.newWithChildren(rowStyle, children: [bullet, current])
            chain.append(current)
        }

        let beforeGrows = stackGrowCount()
        try tree.computeLayout(current, availableSpace: .maxContent)
        let afterCold = stackGrowCount()
        #expect(afterCold > beforeGrows)

        // Each level adds 1pt left padding + 6pt bullet width = 7pt X, and 1pt top padding = 1pt Y.
        var leafAbsX: Float = 0
        var leafAbsY: Float = 0
        for node in chain.dropLast() {
            let l = try tree.unroundedLayout(node)
            leafAbsX += l.location.x
            leafAbsY += l.location.y
        }
        let leafLayout = try tree.unroundedLayout(leaf)
        let rootLayout = try tree.unroundedLayout(current)
        #expect(leafLayout.size == Size(width: 37.5, height: 19.25))
        #expect(leafAbsX == Float(depth) * 7.0)
        #expect(leafAbsY == Float(depth) * 1.0)
        #expect(rootLayout.size == Size(width: 37.5 + Float(depth) * 7.0, height: 19.25 + Float(depth) * 1.0))

        // Warm cached re-layout hits root cache and allocates zero additional stack segments.
        try tree.computeLayout(current, availableSpace: .maxContent)
        #expect(stackGrowCount() == afterCold)
    }

    @Test func deepUncachedBlockContainersInTaffyTreeAndLayoutStore() throws {
        let depth = 400
        let leafSize = Size<Float>(width: 48, height: 14)

        // 1. TaffyTree deep block + flowRoot chain
        var tree = TaffyTree()
        tree.roundingEnabled = false
        let leaf = tree.newLeaf(TaffyStyle(
            display: .block,
            size: Size(width: .length(leafSize.width), height: .length(leafSize.height))
        ))
        var root = leaf
        var nodes: [NodeId] = [leaf]
        nodes.reserveCapacity(depth + 1)
        for i in 0..<depth {
            let blockStyle = TaffyStyle(
                display: i.isMultiple(of: 2) ? .block : .flowRoot,
                padding: Rect(left: .length(1), right: .length(1), top: .length(1), bottom: .length(1))
            )
            root = try tree.newWithChildren(blockStyle, children: [root])
            nodes.append(root)
        }

        let before = stackGrowCount()
        try tree.computeLayout(root, availableSpace: Size(width: .definite(1200), height: .maxContent))
        #expect(stackGrowCount() > before)

        var absX: Float = 0
        var absY: Float = 0
        for node in nodes.dropLast() {
            let l = try tree.unroundedLayout(node)
            absX += l.location.x
            absY += l.location.y
        }
        #expect(try tree.unroundedLayout(leaf).size == leafSize)
        #expect(absX == Float(depth))
        #expect(absY == Float(depth))
        #expect(try tree.unroundedLayout(root).size == Size(width: leafSize.width + Float(depth) * 2, height: leafSize.height + Float(depth) * 2))

        // 2. LayoutStore deep block chain (tests the retained LayoutStoreAdapter path)
        var store = LayoutStore(capacity: depth + 2)
        store.beginCommit()
        let (leafSlot, _) = store.syncNode(
            key: 1,
            nodeIndex: 0,
            style: TaffyStyle(display: .block, size: Size(width: .length(leafSize.width), height: .length(leafSize.height))),
            measure: nil,
            forceMeasureDirty: false,
            childMark: store.beginChildren(),
            childrenDirty: false
        )
        var slots: [SlotId] = [leafSlot]
        slots.reserveCapacity(depth + 1)
        var currentSlot = leafSlot
        for i in 0..<depth {
            let mark = store.beginChildren()
            store.pushChild(currentSlot)
            let style = TaffyStyle(
                display: i.isMultiple(of: 2) ? .block : .flowRoot,
                padding: Rect(left: .length(1), right: .length(1), top: .length(1), bottom: .length(1))
            )
            let (slot, _) = store.syncNode(
                key: UInt64(i + 2),
                nodeIndex: UInt32(i + 1),
                style: style,
                measure: nil,
                forceMeasureDirty: false,
                childMark: mark,
                childrenDirty: true
            )
            currentSlot = slot
            slots.append(slot)
        }
        var rootSlot = currentSlot
        store.endCommit(root: &rootSlot) { _, _ in }
        store.computeLayout(root: rootSlot, availableSpace: Size(width: .definite(1200), height: .maxContent)) { _, _, _ in
            .fromOuterSize(.zero)
        }

        var storeAbsX: Float = 0
        var storeAbsY: Float = 0
        for slot in slots.dropLast() {
            let b = store.boxLayout(slot)
            storeAbsX += b.x
            storeAbsY += b.y
        }
        #expect(store.boxLayout(leafSlot).size == leafSize)
        #expect(storeAbsX == Float(depth))
        #expect(storeAbsY == Float(depth))
        #expect(store.boxLayout(rootSlot).size == Size(width: leafSize.width + Float(depth) * 2, height: leafSize.height + Float(depth) * 2))
    }

    @Test func deep512NestedMixedContainersSurviveConstrainedThreadStack() throws {
        let depth = 512
        var finalLeafSize = Size<Float>.zero
        var finalLeafOrigin = Point<Float>.zero
        var finalRootSize = Size<Float>.zero
        var coldGrows: UInt64 = 0
        var warmGrows: UInt64 = 0

        let runLayout = {
            var store = LayoutStore(capacity: depth * 2 + 2)
            store.beginCommit()
            let (leafSlot, _) = store.syncNode(
                key: 1,
                nodeIndex: 0,
                style: TaffyStyle(size: Size(width: .length(25), height: .length(11)), flexShrink: 0),
                measure: 42,
                forceMeasureDirty: false,
                childMark: store.beginChildren(),
                childrenDirty: false
            )
            var current = leafSlot
            var chain: [SlotId] = [leafSlot]
            chain.reserveCapacity(depth + 1)
            var nextKey: UInt64 = 2
            var nextIdx: UInt32 = 1
            for i in 0..<depth {
                let mark = store.beginChildren()
                let containerStyle: TaffyStyle
                if i.isMultiple(of: 2) {
                    var s = TaffyStyle.runeBase(.column)
                    s.setPadLeft(1)
                    s.setPadTop(1)
                    containerStyle = s
                    let (sib, _) = store.syncNode(
                        key: nextKey,
                        nodeIndex: nextIdx,
                        style: TaffyStyle(size: Size(width: .length(2), height: .length(2)), flexShrink: 0),
                        measure: nil,
                        forceMeasureDirty: false,
                        childMark: store.beginChildren(),
                        childrenDirty: false
                    )
                    nextKey += 1
                    nextIdx += 1
                    store.pushChild(sib)
                    store.pushChild(current)
                } else {
                    containerStyle = TaffyStyle(
                        display: .block,
                        padding: Rect(left: .length(1), right: .zero, top: .length(1), bottom: .zero)
                    )
                    store.pushChild(current)
                }
                let (slot, _) = store.syncNode(
                    key: nextKey,
                    nodeIndex: nextIdx,
                    style: containerStyle,
                    measure: nil,
                    forceMeasureDirty: false,
                    childMark: mark,
                    childrenDirty: true
                )
                nextKey += 1
                nextIdx += 1
                current = slot
                chain.append(slot)
            }
            var rootSlot = current
            store.endCommit(root: &rootSlot) { _, _ in }

            let g0 = stackGrowCount()
            store.computeLayout(root: rootSlot, availableSpace: .maxContent) { input, _, _ in
                .fromOuterSize(Size(
                    width: input.knownDimensions.width ?? 25,
                    height: input.knownDimensions.height ?? 11
                ))
            }
            let g1 = stackGrowCount()
            // Warm cache hit on root: zero stack segment continuations.
            store.computeLayout(root: rootSlot, availableSpace: .maxContent) { _, _, _ in
                .fromOuterSize(.zero)
            }
            let g2 = stackGrowCount()

            var ox: Float = 0
            var oy: Float = 0
            for slot in chain.dropLast() {
                let b = store.boxLayout(slot)
                ox += b.x
                oy += b.y
            }
            finalLeafOrigin = Point(x: ox, y: oy)
            finalLeafSize = store.boxLayout(leafSlot).size
            finalRootSize = store.boxLayout(rootSlot).size
            coldGrows = g1 &- g0
            warmGrows = g2 &- g1
        }

        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        // Run inside a tight 256 KiB stack thread where 512 uncached container levels would immediately overflow without stack continuation.
        runOnConstrainedThread(stackBytes: 256 * 1024, runLayout)
        #else
        runLayout()
        #endif

        // 512 levels: each adds 1pt left padding & 1pt top padding; 256 flex-column levels also prepend a 2pt-tall sibling.
        #expect(finalLeafSize == Size(width: 25, height: 11))
        #expect(finalLeafOrigin == Point(x: Float(depth), y: Float(depth) + Float(depth / 2) * 2))
        #expect(finalRootSize == Size(width: 25 + Float(depth), height: 11 + Float(depth) + Float(depth / 2) * 2))
        #expect(coldGrows > 0)
        #expect(warmGrows == 0)
    }

    @Test func shallowContainerTreeAllocatesZeroStackSegments() throws {
        var grows: UInt64 = 0
        let runShallow = {
            var tree = TaffyTree()
            let leaf = tree.newLeaf(TaffyStyle(size: Size(width: .length(20), height: .length(10))))
            var root = leaf
            for _ in 0..<16 {
                root = try! tree.newWithChildren(
                    TaffyStyle(display: .flex, padding: Rect(all: .length(1)), flexDirection: .column),
                    children: [root]
                )
            }
            let before = stackGrowCount()
            try! tree.computeLayout(root, availableSpace: .maxContent)
            grows = stackGrowCount() &- before
            #expect((try? tree.layout(leaf).size) == Size(width: 20, height: 10))
        }
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        runOnConstrainedThread(stackBytes: 1024 * 1024, runShallow)
        #else
        runShallow()
        #endif
        #expect(grows == 0)
    }
}
