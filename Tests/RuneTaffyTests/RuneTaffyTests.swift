import Testing
@testable import RuneTaffy

@Suite("RuneTaffy Layout Engine Tests")
struct RuneTaffyTests {

    // MARK: - Flexbox Tests

    @Test func flexboxRowGrowAndMinMaxFreezeLoop() throws {
        var tree = TaffyTree()
        // Container: 300px wide, 100px tall
        // Child A: flexGrow 1, maxWidth 50 -> freezes at 50
        // Child B: flexGrow 1 -> gets (300 - 50) * 1/3 = 83.33...
        // Child C: flexGrow 2 -> gets (300 - 50) * 2/3 = 166.66...
        let childA = tree.newLeaf(TaffyStyle(
            maxSize: Size(width: .length(50), height: .auto),
            flexGrow: 1
        ))
        let childB = tree.newLeaf(TaffyStyle(flexGrow: 1))
        let childC = tree.newLeaf(TaffyStyle(flexGrow: 2))

        let root = try tree.newWithChildren(
            TaffyStyle(
                display: .flex,
                size: Size(width: .length(300), height: .length(100)),
                flexDirection: .row
            ),
            children: [childA, childB, childC]
        )

        try tree.computeLayout(root, availableSpace: .maxContent)

        let lA = try tree.layout(childA)
        let lB = try tree.layout(childB)
        let lC = try tree.layout(childC)

        #expect(lA.location.x == 0)
        #expect(lA.size.width == 50)
        #expect(lA.size.height == 100)

        // Cumulative rounding: 50 + 83 = 133, 133 + 167 = 300 (zero hairline gaps!)
        #expect(lB.location.x == 50)
        #expect(lB.size.width == 83)
        #expect(lC.location.x == 133)
        #expect(lC.size.width == 167)
        #expect(lA.size.width + lB.size.width + lC.size.width == 300)
    }

    @Test func flexboxShrinkAndBasis() throws {
        var tree = TaffyTree()
        let child1 = tree.newLeaf(TaffyStyle(
            minSize: Size(width: .length(80), height: .auto),
            flexShrink: 1,
            flexBasis: .length(100)
        ))
        let child2 = tree.newLeaf(TaffyStyle(
            flexShrink: 1,
            flexBasis: .length(100)
        ))
        let root = try tree.newWithChildren(
            TaffyStyle(
                display: .flex,
                size: Size(width: .length(150), height: .length(50)),
                flexDirection: .row
            ),
            children: [child1, child2]
        )

        try tree.computeLayout(root, availableSpace: .maxContent)
        let l1 = try tree.layout(child1)
        let l2 = try tree.layout(child2)

        // Total basis 200 in 150 -> deficit 50. child1 clamps at minWidth 80 (shrinks 20), child2 shrinks remaining 30 -> 70
        #expect(l1.size.width == 80)
        #expect(l2.size.width == 70)
    }

    @Test func flexboxDirectionsAndWrap() throws {
        var tree = TaffyTree()
        let c1 = tree.newLeaf(TaffyStyle(size: Size(width: .length(60), height: .length(20))))
        let c2 = tree.newLeaf(TaffyStyle(size: Size(width: .length(60), height: .length(20))))
        let c3 = tree.newLeaf(TaffyStyle(size: Size(width: .length(60), height: .length(20))))

        let root = try tree.newWithChildren(
            TaffyStyle(
                display: .flex,
                size: Size(width: .length(130), height: .length(100)),
                gap: Size(width: .length(10), height: .length(5)),
                flexDirection: .row,
                flexWrap: .wrap,
                alignContent: .flexStart
            ),
            children: [c1, c2, c3]
        )

        try tree.computeLayout(root, availableSpace: .maxContent)
        let l1 = try tree.layout(c1)
        let l2 = try tree.layout(c2)
        let l3 = try tree.layout(c3)

        // c1 + gap + c2 = 60 + 10 + 60 = 130 (fits on line 1)
        // c3 wraps to line 2 at y = 20 + 5 = 25
        #expect(l1.location == Point(x: 0, y: 0))
        #expect(l2.location == Point(x: 70, y: 0))
        #expect(l3.location == Point(x: 0, y: 25))
    }

    @Test func flexboxRowReverseAndColumnReverse() throws {
        var tree = TaffyTree()
        let c1 = tree.newLeaf(TaffyStyle(size: Size(width: .length(30), height: .length(20))))
        let c2 = tree.newLeaf(TaffyStyle(size: Size(width: .length(40), height: .length(20))))

        let root = try tree.newWithChildren(
            TaffyStyle(
                display: .flex,
                size: Size(width: .length(100), height: .length(50)),
                flexDirection: .rowReverse,
                justifyContent: .flexStart
            ),
            children: [c1, c2]
        )

        try tree.computeLayout(root, availableSpace: .maxContent)
        let l1 = try tree.layout(c1)
        let l2 = try tree.layout(c2)

        // rowReverse + flexStart packs from the right edge: c1 at x=70, c2 at x=30
        #expect(l1.location.x == 70)
        #expect(l2.location.x == 30)
    }

    @Test func flexboxJustifyContentAndAutoMargins() throws {
        var tree = TaffyTree()
        let c1 = tree.newLeaf(TaffyStyle(size: Size(width: .length(20), height: .length(20))))
        let c2 = tree.newLeaf(TaffyStyle(
            size: Size(width: .length(20), height: .length(20)),
            margin: Rect(left: .auto, right: .zero, top: .auto, bottom: .auto)
        ))

        let root = try tree.newWithChildren(
            TaffyStyle(
                display: .flex,
                size: Size(width: .length(100), height: .length(60)),
                flexDirection: .row
            ),
            children: [c1, c2]
        )

        try tree.computeLayout(root, availableSpace: .maxContent)
        let l1 = try tree.layout(c1)
        let l2 = try tree.layout(c2)

        #expect(l1.location == Point(x: 0, y: 0))
        // c2 pushed to right edge (x = 80) and vertically centered (y = 20)
        #expect(l2.location == Point(x: 80, y: 20))
    }

    @Test func flexboxBaselineAlignment() throws {
        var tree = TaffyTree()
        let c1 = tree.newLeafWithSimpleMeasure(TaffyStyle()) { _ in Size(width: 20, height: 30) }
        let c2 = tree.newLeafWithSimpleMeasure(TaffyStyle()) { _ in Size(width: 20, height: 10) }

        let root = try tree.newWithChildren(
            TaffyStyle(
                display: .flex,
                size: Size(width: .length(100), height: .length(50)),
                flexDirection: .row,
                alignItems: .baseline
            ),
            children: [c1, c2]
        )

        try tree.computeLayout(root, availableSpace: .maxContent)
        let l1 = try tree.layout(c1)
        let l2 = try tree.layout(c2)

        // Default baseline is bottom of box: c1 at y=0 (baseline 30), c2 at y=20 (baseline 10 -> 20+10=30)
        #expect(l1.location.y == 0)
        #expect(l2.location.y == 20)
    }

    // MARK: - CSS Grid Tests

    @Test func gridFrAndMinmaxTracks() throws {
        var tree = TaffyTree()
        let c1 = tree.newLeaf(TaffyStyle())
        let c2 = tree.newLeaf(TaffyStyle())
        let c3 = tree.newLeaf(TaffyStyle())

        let root = try tree.newWithChildren(
            TaffyStyle(
                display: .grid,
                size: Size(width: .length(320), height: .length(100)),
                gap: Size(width: .length(10), height: .zero),
                gridTemplateRows: [.fr(1)],
                gridTemplateColumns: [
                    .length(50),
                    .minmax(.length(60), .fr(1)),
                    .fr(2),
                ]
            ),
            children: [c1, c2, c3]
        )

        try tree.computeLayout(root, availableSpace: .maxContent)
        let l1 = try tree.layout(c1)
        let l2 = try tree.layout(c2)
        let l3 = try tree.layout(c3)

        // 320 - 20 (gaps) - 50 (col 0) = 250 for 1fr + 2fr -> col1 = 83.33, col2 = 166.67
        #expect(l1.location.x == 0)
        #expect(l1.size.width == 50)
        #expect(l2.location.x == 60)
        #expect(l2.size.width == 83)
        #expect(l3.location.x == 153)
        #expect(l3.size.width == 167)
        #expect(l1.size.height == 100)
        #expect(l2.size.height == 100)
        #expect(l3.size.height == 100)
    }

    @Test func gridSpanAndDenseAutoFlow() throws {
        var tree = TaffyTree()
        // Item 1: 1x1 at (auto, auto) -> col 0, row 0
        let item1 = tree.newLeaf(TaffyStyle())
        // Item 2: spans 2 columns -> doesn't fit in remaining col 1 of 2-col grid, goes to row 1 (col 0..2)
        let item2 = tree.newLeaf(TaffyStyle(
            gridColumn: Line(start: .auto, end: .span(2))
        ))
        // Item 3: 1x1 -> with rowDense, backfills col 1, row 0!
        let item3 = tree.newLeaf(TaffyStyle())

        let root = try tree.newWithChildren(
            TaffyStyle(
                display: .grid,
                size: Size(width: .length(200), height: .length(100)),
                gridTemplateRows: [.length(50), .length(50)],
                gridTemplateColumns: [.fr(1), .fr(1)],
                gridAutoFlow: .rowDense
            ),
            children: [item1, item2, item3]
        )

        try tree.computeLayout(root, availableSpace: .maxContent)
        let l1 = try tree.layout(item1)
        let l2 = try tree.layout(item2)
        let l3 = try tree.layout(item3)

        #expect(l1.location == Point(x: 0, y: 0))
        #expect(l1.size == Size(width: 100, height: 50))

        #expect(l2.location == Point(x: 0, y: 50))
        #expect(l2.size == Size(width: 200, height: 50))

        #expect(l3.location == Point(x: 100, y: 0))
        #expect(l3.size == Size(width: 100, height: 50))
    }

    @Test func gridNamedAreasAndExplicitLines() throws {
        var tree = TaffyTree()
        let header = tree.newLeaf(TaffyStyle(
            gridRow: Line(start: .namedLine("header-start", 1), end: .namedLine("header-end", 1)),
            gridColumn: Line(start: .namedLine("header-start", 1), end: .namedLine("header-end", 1))
        ))
        let sidebar = tree.newLeaf(TaffyStyle(
            gridRow: Line(start: .line(2), end: .line(3)),
            gridColumn: Line(start: .line(1), end: .line(2))
        ))
        let main = tree.newLeaf(TaffyStyle(
            gridRow: Line(start: .line(2), end: .line(-1)),
            gridColumn: Line(start: .line(2), end: .line(-1))
        ))

        let root = try tree.newWithChildren(
            TaffyStyle(
                display: .grid,
                size: Size(width: .length(300), height: .length(200)),
                gridTemplateRows: [.length(40), .fr(1)],
                gridTemplateColumns: [.length(100), .fr(1)],
                gridTemplateAreas: [
                    GridTemplateArea(name: "header", rowStart: 0, rowEnd: 1, columnStart: 0, columnEnd: 2),
                ]
            ),
            children: [header, sidebar, main]
        )

        try tree.computeLayout(root, availableSpace: .maxContent)
        let lh = try tree.layout(header)
        let ls = try tree.layout(sidebar)
        let lm = try tree.layout(main)

        #expect(lh.location == Point(x: 0, y: 0))
        #expect(lh.size == Size(width: 300, height: 40))

        #expect(ls.location == Point(x: 0, y: 40))
        #expect(ls.size == Size(width: 100, height: 160))

        #expect(lm.location == Point(x: 100, y: 40))
        #expect(lm.size == Size(width: 200, height: 160))
    }

    @Test func gridAutoFillAndAlignment() throws {
        var tree = TaffyTree()
        let items = (0..<4).map { _ in
            tree.newLeaf(TaffyStyle(
                size: Size(width: .length(20), height: .length(20)),
                alignSelf: .center,
                justifySelf: .end
            ))
        }

        let root = try tree.newWithChildren(
            TaffyStyle(
                display: .grid,
                size: Size(width: .length(200), height: .length(100)),
                gridTemplateRows: [.length(50), .length(50)],
                gridTemplateColumns: [.repeat(.autoFill, [.length(100)])]
            ),
            children: items
        )

        try tree.computeLayout(root, availableSpace: .maxContent)
        let l0 = try tree.layout(items[0])
        let l1 = try tree.layout(items[1])

        // 2 columns of 100px each; justifySelf: .end -> x = 100 - 20 = 80; alignSelf: .center -> y = (50 - 20)/2 = 15
        #expect(l0.location == Point(x: 80, y: 15))
        #expect(l1.location == Point(x: 180, y: 15))
    }

    // MARK: - Block Layout Tests

    @Test func blockMarginCollapsingAndAutoCentering() throws {
        var tree = TaffyTree()
        let b1 = tree.newLeaf(TaffyStyle(
            display: .block,
            size: Size(width: .length(100), height: .length(30)),
            margin: Rect(left: .auto, right: .auto, top: .length(10), bottom: .length(25))
        ))
        let b2 = tree.newLeaf(TaffyStyle(
            display: .block,
            size: Size(width: .auto, height: .length(40)),
            margin: Rect(left: .zero, right: .zero, top: .length(15), bottom: .length(10))
        ))

        let root = try tree.newWithChildren(
            TaffyStyle(
                display: .flowRoot,
                size: Size(width: .length(200), height: .auto)
            ),
            children: [b1, b2]
        )

        try tree.computeLayout(root, availableSpace: .maxContent)
        let lRoot = try tree.layout(root)
        let l1 = try tree.layout(b1)
        let l2 = try tree.layout(b2)

        // b1 horizontally centered: (200 - 100) / 2 = 50, y = 10
        #expect(l1.location == Point(x: 50, y: 10))
        #expect(l1.size == Size(width: 100, height: 30))

        // Margin between b1 (bottom 25) and b2 (top 15) collapses to max(25, 15) = 25!
        // So b2.y = 10 + 30 + 25 = 65; b2 stretches to width 200
        #expect(l2.location == Point(x: 0, y: 65))
        #expect(l2.size == Size(width: 200, height: 40))

        // Total height = 65 + 40 + 10 (b2 bottom margin) = 115
        #expect(lRoot.size == Size(width: 200, height: 115))
    }

    // MARK: - Out-of-Flow (Absolute) Tests

    @Test func absolutePositioningInsetsAndCentering() throws {
        var tree = TaffyTree()
        let pinned = tree.newLeaf(TaffyStyle(
            position: .absolute,
            size: Size(width: .length(40), height: .length(20)),
            inset: Rect(left: .auto, right: .length(10), top: .auto, bottom: .length(15))
        ))
        let centered = tree.newLeaf(TaffyStyle(
            position: .absolute,
            size: Size(width: .length(50), height: .length(30)),
            margin: Rect(all: .auto),
            inset: Rect(all: .zero)
        ))

        let root = try tree.newWithChildren(
            TaffyStyle(
                display: .flex,
                size: Size(width: .length(200), height: .length(100))
            ),
            children: [pinned, centered]
        )

        try tree.computeLayout(root, availableSpace: .maxContent)
        let lp = try tree.layout(pinned)
        let lc = try tree.layout(centered)

        #expect(lp.location == Point(x: 150, y: 65))
        #expect(lc.location == Point(x: 75, y: 35))
    }

    // MARK: - MeasureFunc & Dirty Cache Invalidation Tests

    @Test func measureFuncWithAvailableWidthConstraint() throws {
        var tree = TaffyTree()
        // Simulate a text-like leaf whose height wraps based on available width: area = 1000
        let textLeaf = tree.newLeafWithMeasure(TaffyStyle()) { known, avail, _ in
            let w: Float
            if let kw = known.width {
                w = kw
            } else if case .definite(let aw) = avail.width {
                w = Swift.min(aw, 200)
            } else {
                w = 200
            }
            let h = known.height ?? (w > 0 ? (1000 / w).rounded(.up) : 0)
            return Size(width: w, height: h)
        }

        let root = try tree.newWithChildren(
            TaffyStyle(
                display: .flex,
                size: Size(width: .length(100), height: .auto),
                flexDirection: .column
            ),
            children: [textLeaf]
        )

        try tree.computeLayout(root, availableSpace: .maxContent)
        let lLeaf = try tree.layout(textLeaf)
        let lRoot = try tree.layout(root)

        #expect(lLeaf.size == Size(width: 100, height: 10))
        #expect(lRoot.size == Size(width: 100, height: 10))
    }

    @Test func dirtyPropagationAndGenerationalNodeIds() throws {
        var tree = TaffyTree()
        let child = tree.newLeaf(TaffyStyle(size: Size(width: .length(50), height: .length(20))))
        let root = try tree.newWithChildren(
            TaffyStyle(display: .flex, flexDirection: .column),
            children: [child]
        )

        try tree.computeLayout(root, availableSpace: .maxContent)
        #expect(try !tree.dirty(root))
        #expect(try !tree.dirty(child))
        #expect(try tree.layout(root).size == Size(width: 50, height: 20))

        // Mutate child style -> propagates dirty to root
        try tree.setStyle(child, TaffyStyle(size: Size(width: .length(80), height: .length(30))))
        #expect(try tree.dirty(child))
        #expect(try tree.dirty(root))

        try tree.computeLayout(root, availableSpace: .maxContent)
        #expect(try tree.layout(root).size == Size(width: 80, height: 30))

        // Remove child and verify generational invalidation
        try tree.remove(child)
        #expect(throws: TaffyError.invalidInputNode(child)) {
            _ = try tree.layout(child)
        }

        let recycled = tree.newLeaf(TaffyStyle())
        #expect(recycled.index == child.index)
        #expect(recycled.generation == child.generation + 1)
    }

    // MARK: - RoundLayout Cumulative Rounding Test

    @Test func roundLayoutEliminatesHairlineGaps() throws {
        var tree = TaffyTree()
        let children = (0..<3).map { _ in tree.newLeaf(TaffyStyle(flexGrow: 1)) }
        let root = try tree.newWithChildren(
            TaffyStyle(
                display: .flex,
                size: Size(width: .length(100), height: .length(10)),
                flexDirection: .row
            ),
            children: children
        )

        try tree.computeLayout(root, availableSpace: .maxContent)
        let layouts = try children.map { try tree.layout($0) }

        #expect(layouts[0].location.x == 0)
        #expect(layouts[0].size.width == 33)
        #expect(layouts[1].location.x == 33)
        #expect(layouts[1].size.width == 34)
        #expect(layouts[2].location.x == 67)
        #expect(layouts[2].size.width == 33)
        #expect(layouts.reduce(Float(0)) { $0 + $1.size.width } == 100)
    }

    // MARK: - LayoutStore Commit-Pass Reconciliation Test

    @Test func layoutStoreCommitReconciliationAndCaching() {
        var store = LayoutStore()

        // Commit 1
        store.beginCommit()
        let mRoot = store.beginChildren()
        let (c1, d1) = store.syncNode(
            key: 101,
            nodeIndex: 1,
            style: TaffyStyle(size: Size(width: .length(40), height: .length(20))),
            measure: nil,
            forceMeasureDirty: false,
            childMark: store.beginChildren(),
            childrenDirty: false
        )
        store.pushChild(c1)
        var (root, dRoot) = store.syncNode(
            key: 1,
            nodeIndex: 0,
            style: TaffyStyle(display: .flex, size: Size(width: .length(100), height: .length(50))),
            measure: nil,
            forceMeasureDirty: false,
            childMark: mRoot,
            childrenDirty: d1
        )
        store.endCommit(root: &root) { _, _ in }

        #expect(d1 == true)
        #expect(dRoot == true)
        #expect(store.liveCount == 2)

        store.computeLayout(root: root, availableSpace: .maxContent) { _, _, _ in
            LayoutOutput.fromOuterSize(.zero)
        }
        #expect(store.boxLayout(c1).w == 40)
        #expect(store.boxLayout(c1).h == 20)

        // Commit 2: unchanged -> clean reuse
        store.beginCommit()
        #expect(store.canReuse(key: 1, slot: root))
        #expect(store.canReuse(key: 101, slot: c1))
        store.reuseSlot(c1, nodeIndex: 1)
        store.reuseSlot(root, nodeIndex: 0)
        store.endCommit(root: &root) { _, _ in }
        #expect(store.liveCount == 2)
        #expect(store.boxLayout(c1).w == 40)
    }

    // MARK: - 9-Slot Second-Chance Cache Test

    @Test func cacheSecondChanceEvictionAndClear() {
        var cache = Cache()
        #expect(cache.clear() == .alreadyEmpty)

        for i in 0..<12 {
            let input = LayoutInput(
                runMode: .computeSize,
                sizingMode: .inherentSize,
                axis: .both,
                knownDimensions: Size(width: Float(i * 10), height: nil)
            )
            cache.store(input, output: LayoutOutput.fromOuterSize(Size(width: Float(i * 10), height: 25)))
        }

        // Most recent 9 entries (3..11) should hit
        let hitInput = LayoutInput(
            runMode: .computeSize,
            sizingMode: .inherentSize,
            axis: .both,
            knownDimensions: Size(width: 110, height: nil)
        )
        #expect(cache.get(hitInput)?.size == Size(width: 110, height: 25))
        #expect(cache.clear() == .cleared)
        #expect(cache.clear() == .alreadyEmpty)
    }
}
