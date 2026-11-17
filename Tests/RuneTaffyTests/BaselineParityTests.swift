import RuneTaffy
import Testing

// Run the same replay with `swift test --traits BaselineTaffy` to exercise the
// independent retained tree. Both upstream Rust backends produced these boxes
// at 842c28c2 with identical measure inputs and style mutations.
@Test func measuredBaselinesAndStyleReplacementMatchRust() {
    var store = LayoutEngine()
    let room = Size<AvailableSpace>(width: .definite(200), height: .maxContent)
    var a = SlotId(), b = SlotId(), root = SlotId()
    var parent = TaffyStyle.runeBase(.row)
    parent.setAlignItems(.baseline)
    parent.setPaddingAll(2)
    parent.setGap(3, 0)
    let expected: [[[Float]]] = [
        [[0, 0, 57, 28], [2, 6, 30, 20], [35, 2, 20, 12]],
        [[0, 0, 72, 28], [5, 6, 42, 20], [50, 2, 20, 12]],
        [[0, 0, 50, 24], [0, 4, 30, 20], [30, 0, 20, 12]],
        [[0, 0, 68, 32], [33, 7, 30, 20], [5, 5, 28, 12]],
        [[0, 0, 68, 32], [33, 7, 30, 20], [5, 5, 28, 5]],
        [[0, 0, 68, 30], [33, 5, 30, 20], [5, 6, 28, 5]],
        [[0, 0, 68, 80], [33, 55, 30, 20], [5, 56, 28, 5]]
    ]
    for phase in expected.indices {
        if phase == 0 || phase == 3 {
            store.beginCommit()
            let first = phase == 0
            a = store.syncNode(key: 10, nodeIndex: first ? 1 : 12, style: .runeBase(), measure: 1,
                forceMeasureDirty: false, childMark: store.beginChildren(), childrenDirty: false).0
            b = store.syncNode(key: 11, nodeIndex: first ? 2 : 11, style: .runeBase(), measure: first ? 1 : 2,
                forceMeasureDirty: false, childMark: store.beginChildren(), childrenDirty: false).0
            let mark = store.beginChildren()
            store.pushChild(first ? a : b)
            store.pushChild(first ? b : a)
            if !first { parent.setPaddingAll(5) }
            root = store.syncNode(key: 1, nodeIndex: 0, style: parent, measure: nil,
                forceMeasureDirty: false, childMark: mark, childrenDirty: true).0
            store.endCommit(root: &root) { _, _ in }
        } else if phase == 1 {
            var leaf = TaffyStyle.runeBase()
            leaf.setWidth(.length(42))
            leaf.setMarginLeft(3)
            store.setStyleAndMarkAncestors(a, style: leaf, ancestors: [root])
        } else if phase == 6 {
            parent.setHeight(.length(80))
            parent.setFlexWrap(.wrapReverse)
            store.setStyleAndMarkAncestors(root, style: parent, ancestors: [])
        } else if phase >= 4 {
            var fixed = TaffyStyle.runeBase()
            fixed.setHeight(.length(5))
            if phase == 5 { fixed.setOverflow(.hidden, .scroll) }
            store.setStyleAndMarkAncestors(b, style: fixed, ancestors: [root])
        } else {
            store.setStyleAndMarkAncestors(a, style: .runeBase(), ancestors: [root])
            parent.setGap(0, 0)
            parent.setPaddingAll(0)
            store.setStyleAndMarkAncestors(root, style: parent, ancestors: [])
        }
        store.computeLayout(root: root, availableSpace: room, measureLeaf: measureRustFixture)
        let rectangles = [root, a, b].map { slot in
            let box = store.boxLayout(slot)
            return [box.x, box.y, box.w, box.h]
        }
        #expect(rectangles == expected[phase], "phase \(phase)")
    }
}

private func measureRustFixture(_ input: LayoutInput, _ context: Int?, _ style: TaffyStyle) -> LayoutOutput {
    let intrinsic: (Float, Float, Float)
    switch context {
    case 1, 12: intrinsic = (30, 20, 6)
    case 2: intrinsic = (20, 12, 10)
    case 11: intrinsic = (28, 12, 8)
    default: intrinsic = (0, 0, 0)
    }
    let size = Size(width: input.knownDimensions.width ?? intrinsic.0,
                    height: input.knownDimensions.height ?? intrinsic.1)
    return .fromSizesAndBaselines(size: size, contentSize: size, firstBaselines: .init(x: nil, y: intrinsic.2))
}

@Test func unroundedWarmSolvePreservesIndependentSnapshotsAndRoots() {
    var store = LayoutStore()
    store.beginCommit()
    var leaf = TaffyStyle.runeBase()
    leaf.setSize(.init(width: .length(4.5), height: .length(7.5)))
    var a = store.syncNode(key: 1, nodeIndex: 0, style: leaf, measure: nil,
        forceMeasureDirty: false, childMark: 0, childrenDirty: false).0
    let b = store.syncNode(key: 2, nodeIndex: 1, style: leaf, measure: nil,
        forceMeasureDirty: false, childMark: 0, childrenDirty: false).0
    store.endCommit(root: &a) { _, _ in }
    for slot in [a, b] {
        store.computeLayout(root: slot, availableSpace: .maxContent, rounding: true) { _, _, _ in .hidden }
    }
    let snapshot = store
    store.computeLayout(root: a, availableSpace: .maxContent) { _, _, _ in .hidden }
    #expect(store.layout(a).size.width == 4.5)
    #expect(store.layout(b).size.width == 5)
    #expect(snapshot.layout(a).size.width == 5)
    store.computeLayout(root: b, availableSpace: .maxContent) { _, _, _ in .hidden }
    #expect(store.layout(b).size.height == 7.5)
}

@Test func nestedFlexContainerUsesParticipatingChildBaselineFromRust() {
    var store = LayoutEngine()
    store.beginCommit()
    var leaves: [SlotId] = []
    for (key, context) in [(1, 1), (2, 2), (3, 11)] {
        var style = TaffyStyle.runeBase()
        if key == 1 { style.setAlignSelf(.start) }
        leaves.append(store.syncNode(key: UInt64(key), nodeIndex: UInt32(context), style: style, measure: 1,
            forceMeasureDirty: false, childMark: store.beginChildren(), childrenDirty: false).0)
    }
    var group = TaffyStyle.runeBase()
    group.setAlignItems(.baseline)
    group.setPaddingAll(2)
    let innerMark = store.beginChildren()
    store.pushChild(leaves[0])
    store.pushChild(leaves[1])
    let inner = store.syncNode(key: 4, nodeIndex: 4, style: group, measure: nil,
        forceMeasureDirty: false, childMark: innerMark, childrenDirty: true).0
    let outerMark = store.beginChildren()
    store.pushChild(inner)
    store.pushChild(leaves[2])
    var root = store.syncNode(key: 5, nodeIndex: 5, style: group, measure: nil,
        forceMeasureDirty: false, childMark: outerMark, childrenDirty: true).0
    store.endCommit(root: &root) { _, _ in }
    store.computeLayout(root: root, availableSpace: .maxContent, measureLeaf: measureRustFixture)
    let boxes = ([root, inner] + leaves).map { slot in
        let box = store.boxLayout(slot)
        return [box.x, box.y, box.w, box.h]
    }
    #expect(boxes == [[0, 0, 86, 28], [2, 2, 54, 24], [2, 2, 30, 20], [32, 2, 20, 12], [56, 6, 28, 12]])
}

@Test func baselineBackendRekeysAndPrunesWithoutLosingDescendants() {
    var store = BaselineLayoutStore()
    store.beginCommit()
    let leaf = store.syncNode(key: 10, nodeIndex: 1, style: .runeBase(), measure: 123,
        forceMeasureDirty: false, childMark: 0, childrenDirty: false).0
    var parentMark = store.beginChildren()
    store.pushChild(leaf)
    let group = store.syncNode(key: 11, nodeIndex: 2, style: .runeBase(), measure: nil,
        forceMeasureDirty: false, childMark: parentMark, childrenDirty: true).0
    let stale = store.syncNode(key: 12, nodeIndex: 3, style: .runeBase(), measure: nil,
        forceMeasureDirty: false, childMark: 0, childrenDirty: false).0
    parentMark = store.beginChildren()
    store.pushChild(group)
    store.pushChild(stale)
    var root = store.syncNode(key: 13, nodeIndex: 4, style: .runeBase(), measure: nil,
        forceMeasureDirty: false, childMark: parentMark, childrenDirty: true).0
    store.endCommit(root: &root) { _, _ in }
    store.beginCommit()
    #expect(store.canReuse(key: 11, slot: group))
    store.rekeyAndReuseBatch([(11, 12, group, 2), (10, 100, leaf, 1)])
    root = group
    store.endCommit(root: &root) { _, _ in }
    store.computeLayout(root: root, availableSpace: .maxContent, measureLeaf: measureRustFixture)
    #expect(store.liveCount == 2)
    #expect(store.measureHash(key: 10) == nil)
    #expect(store.measureHash(key: 13) == nil)
    #expect(store.measureHash(key: 100) == .some(123))
    #expect(store.mountedNodeIndex(key: 12) == 2)
    #expect(Array(store.childIds(group)) == [leaf.toNodeId])
    #expect(store.layout(group).size == Size(width: 30, height: 20))
    #expect(store.storageStats().childHeapBytes > 0)
}

@Test func flexTransfersUsedCrossSizeThroughAspectRatio() {
    for direction in [FlexDirection.column, .row] {
        for useMax in [true, false] {
            var store = LayoutEngine()
            store.beginCommit()
            var style = TaffyStyle.runeBase()
            style.setAspectRatio(2)
            if direction == .column {
                style.setWidth(.length(useMax ? 696 : 60))
                if useMax { style.setMaxWidth(.length(176)) } else { style.setMinWidth(.length(176)) }
            } else {
                style.setHeight(.length(useMax ? 696 : 60))
                if useMax { style.setMaxHeight(.length(88)) } else { style.setMinHeight(.length(88)) }
            }
            let leaf = store.syncNode(key: 1, nodeIndex: 1, style: style, measure: nil,
                forceMeasureDirty: false, childMark: 0, childrenDirty: false).0
            let mark = store.beginChildren()
            store.pushChild(leaf)
            var parent = TaffyStyle.runeBase(direction)
            parent.setAlignItems(.start)
            var root = store.syncNode(key: 2, nodeIndex: 0, style: parent, measure: nil,
                forceMeasureDirty: false, childMark: mark, childrenDirty: true).0
            store.endCommit(root: &root) { _, _ in }
            store.computeLayout(root: root, availableSpace: .maxContent) { _, _, _ in .hidden }
            #expect(store.layout(leaf).size == Size(width: 176, height: 88))
        }
    }
}

@Test func referenceTreeReleasesColdStyleWhenNodeIsRemoved() throws {
    var tree = TaffyTree()
    var style = TaffyStyle.runeBase()
    style.setEqualColumns(100)
    let old = tree.newLeaf(style)
    #expect(tree.storageStats().coldStyleBytes > 0)
    try tree.remove(old)
    #expect(tree.storageStats().coldStyleBytes == 0)
    let next = tree.newLeaf()
    #expect(next.index == old.index && next.generation != old.generation)
}
