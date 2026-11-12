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

    // MARK: - Ported upstream rune-taffy tests (D-T1..D-T6 + setters + compaction)

    @Test func compactCachePreservesSecondChanceOverflowAndTaffy015Keys() {
        func makeInput(_ w: Float, definite: Bool = true, axis: RequestedAxis = .both, parent: Size<Float?> = .none) -> LayoutInput {
            LayoutInput(
                runMode: .computeSize,
                sizingMode: .inherentSize,
                axis: axis,
                knownDimensions: Size(width: w, height: nil),
                knownDimensionsAreDefinite: Size(width: definite, height: true),
                parentSize: parent,
                availableSpace: .maxContent,
                verticalMarginsAreCollapsible: .false
            )
        }
        func makeOut(_ w: Float) -> LayoutOutput {
            LayoutOutput.fromOuterSize(Size(width: w, height: w * 2))
        }

        var cache = CompactCache()
        #expect(cache.isEmpty)
        cache.store(makeInput(0), output: makeOut(0))
        cache.store(makeInput(1), output: makeOut(1))
        #expect(!cache.isEmpty)
        #expect(cache.heapBytes() == 0)

        for w in 2..<9 {
            cache.store(makeInput(Float(w)), output: makeOut(Float(w)))
        }
        #expect(cache.heapBytes() > 0)

        // Storing 9 evicts 0 (first slot without recent hit). Touching 1 sets its recent flag.
        cache.store(makeInput(9), output: makeOut(9))
        #expect(cache.get(makeInput(1))?.size == makeOut(1).size)
        cache.store(makeInput(10), output: makeOut(10))
        #expect(cache.get(makeInput(1))?.size == makeOut(1).size)
        #expect(cache.get(makeInput(2)) == nil)

        // D-T5: collapsible margins / non-zero top/bottom margins skip ComputeSize cache store
        var collapse = makeOut(99)
        collapse.topMargin = CollapsibleMarginSet.fromMargin(8)
        cache.store(makeInput(99), output: collapse)
        #expect(cache.get(makeInput(99)) == nil)

        // D-T5: overwriting existing matching ComputeSize entry updates in place without evicting another slot
        cache.store(makeInput(1), output: LayoutOutput.fromOuterSize(Size(width: 1, height: 777)))
        #expect(cache.get(makeInput(1))?.size == Size(width: 1, height: 777))
        #expect(cache.get(makeInput(10))?.size == Size(width: 10, height: 20))

        // D-T4: definiteness and x-axis-only parent_size matching
        var keyCache = Cache()
        keyCache.store(
            makeInput(50, definite: true, axis: .horizontal, parent: Size(width: 200, height: 300)),
            output: makeOut(50)
        )
        // Different y-axis parent size hits ComputeSize when x-axis matches and axis matches
        #expect(keyCache.get(makeInput(50, definite: true, axis: .horizontal, parent: Size(width: 200, height: 999)))?.size == makeOut(50).size)
        // Different definiteness misses
        #expect(keyCache.get(makeInput(50, definite: false, axis: .horizontal, parent: Size(width: 200, height: 300))) == nil)
        // Different x-axis parent size misses
        #expect(keyCache.get(makeInput(50, definite: true, axis: .horizontal, parent: Size(width: 250, height: 300))) == nil)
        // Switching mode invalidates previous entries
        let altMode = LayoutInput(
            runMode: .computeSize,
            sizingMode: .contentSize,
            axis: .horizontal,
            knownDimensions: Size(width: 50, height: nil),
            parentSize: Size(width: 200, height: 300),
            availableSpace: .maxContent
        )
        #expect(keyCache.get(altMode) == nil)
        #expect(keyCache.clear() == .cleared)
        #expect(keyCache.isEmpty)
    }

    @Test func taffyStyleSettersAndTakeBoxPlacement() {
        for dir in [FlexDirection.row, .column, .rowReverse, .columnReverse] {
            var cs = CompactStyle.runeBase(dir)
            var ts = Style(
                display: .flex,
                position: .relative,
                flexDirection: dir,
                flexShrink: 0
            )
            #expect(cs == ts)

            cs.setWidth(percent(1))
            ts.size.width = percent(1)
            cs.setHeight(length(48.5))
            ts.size.height = length(48.5)
            cs.setMinWidth(length(0))
            ts.minSize.width = length(0)
            cs.setMinHeight(length(10))
            ts.minSize.height = length(10)
            cs.setMaxWidth(length(300))
            ts.maxSize.width = length(300)
            cs.setMaxHeight(length(240))
            ts.maxSize.height = length(240)
            cs.setPaddingAll(12)
            ts.padding = Rect(all: .length(12))
            cs.setPadLeft(6)
            ts.padding.left = .length(6)
            cs.setPadRight(7)
            ts.padding.right = .length(7)
            cs.setPadTop(8)
            ts.padding.top = .length(8)
            cs.setPadBottom(9)
            ts.padding.bottom = .length(9)
            cs.setGap(8, 4)
            ts.gap = Size(width: .length(8), height: .length(4))
            cs.setGrow(1.5)
            ts.flexGrow = 1.5
            ts.flexShrink = 1
            ts.flexBasis = zero()
            cs.setFlexWrap(.wrap)
            ts.flexWrap = .wrap
            cs.setOverflow(.hidden, .scroll)
            ts.overflow = Point(x: .hidden, y: .scroll)
            cs.setAlignItems(.center)
            ts.alignItems = .center
            cs.setAlignSelf(.stretch)
            ts.alignSelf = .stretch
            cs.setJustifyContent(.spaceBetween)
            ts.justifyContent = .spaceBetween
            cs.setAspectRatio(1.75)
            ts.aspectRatio = 1.75
            cs.setMarginX(4)
            cs.setMarginY(2)
            ts.margin = Rect(left: .length(4), right: .length(4), top: .length(2), bottom: .length(2))
            cs.setBorder((1, 2, 3, 4))
            ts.border = Rect(left: .length(4), right: .length(2), top: .length(1), bottom: .length(3))
            #expect(cs == ts)

            cs.setOverflow(.hidden, .scroll)
            cs.setAspectRatio(2.0)
            let outer = cs.takeBoxPlacement()
            #expect(outer.overflow == Point(x: .hidden, y: .scroll))
            #expect(cs.overflow == Point(x: .hidden, y: .scroll))
            #expect(outer.aspectRatio == 2.0)
            #expect(cs.aspectRatio == nil)
            #expect(cs.flexGrow == 1.0)
            #expect(cs.flexShrink == 1.0)
            #expect(cs.flexBasis == .auto)
        }

        // Prelude helpers
        #expect(evenlySizedTracks(3) == .repeat(.count(3), [TrackSizingFunction(min: .length(0), max: .fr(1))]))
        #expect(flex(2.0) == TrackSizingFunction.fr(2.0))
        #expect(Contain.layout.contains(.layout))
    }

    @Test func layoutStoreLargeToSmallSwapCompactsSparseSlots() {
        var store = LayoutStore()

        func syncList(_ rows: Int) -> (root: SlotId, entries: [SlotId]) {
            store.beginCommit()
            var slotByNodeIndex: [SlotId] = []
            slotByNodeIndex.reserveCapacity(1 + rows * 3)
            let total = 1 + rows * 3
            slotByNodeIndex = Array(repeating: SlotId(0), count: total)

            let rootMark = store.beginChildren()
            var rowSlots: [SlotId] = []
            rowSlots.reserveCapacity(rows)
            var nextIdx: UInt32 = 1

            for i in 0..<rows {
                let rowNodeIdx = nextIdx
                nextIdx += 1
                let c1Idx = nextIdx
                nextIdx += 1
                let c2Idx = nextIdx
                nextIdx += 1

                let baseKey = UInt64(100 + i * 10)
                let (s1, d1) = store.syncNode(
                    key: baseKey + 1,
                    nodeIndex: c1Idx,
                    style: TaffyStyle(size: Size(width: length(120), height: length(18))),
                    measure: UInt64(i + 1),
                    forceMeasureDirty: false,
                    childMark: store.beginChildren(),
                    childrenDirty: false
                )
                let (s2, d2) = store.syncNode(
                    key: baseKey + 2,
                    nodeIndex: c2Idx,
                    style: TaffyStyle(size: Size(width: length(20), height: length(20))),
                    measure: nil,
                    forceMeasureDirty: false,
                    childMark: store.beginChildren(),
                    childrenDirty: false
                )
                let rowMark = store.beginChildren()
                store.pushChild(s1)
                store.pushChild(s2)
                let (rowSlot, _) = store.syncNode(
                    key: baseKey,
                    nodeIndex: rowNodeIdx,
                    style: TaffyStyle(display: .flex, size: Size(width: percent(1), height: length(32)), flexDirection: .row),
                    measure: nil,
                    forceMeasureDirty: false,
                    childMark: rowMark,
                    childrenDirty: d1 || d2
                )
                slotByNodeIndex[Int(c1Idx)] = s1
                slotByNodeIndex[Int(c2Idx)] = s2
                slotByNodeIndex[Int(rowNodeIdx)] = rowSlot
                rowSlots.append(rowSlot)
            }

            for r in rowSlots {
                store.pushChild(r)
            }
            var (root, _) = store.syncNode(
                key: 1,
                nodeIndex: 0,
                style: TaffyStyle(display: .flex, size: Size(width: length(1000), height: length(900)), flexDirection: .column),
                measure: nil,
                forceMeasureDirty: false,
                childMark: rootMark,
                childrenDirty: true
            )
            slotByNodeIndex[0] = root
            store.endCommit(root: &root) { me, newSlot in
                slotByNodeIndex[Int(me)] = newSlot
            }
            return (root, slotByNodeIndex)
        }

        let r500 = syncList(500)
        let stats500 = store.storageStats()
        #expect(stats500.liveNodes == 1501)
        #expect(stats500.totalRetainedBytes > 0)
        store.computeLayout(root: r500.root, availableSpace: Size(width: .definite(1000), height: .definite(900))) { _, _, _ in
            LayoutOutput.fromOuterSize(Size(width: 120, height: 18))
        }

        let r10 = syncList(10)
        let stats10 = store.storageStats()
        #expect(stats10.liveNodes == 31)
        // Swift Array rounds reserveCapacity(62) up to the next malloc size class (81)
        #expect(stats10.slotCapacity <= 96)
        #expect(stats10.totalRetainedBytes * 10 < stats500.totalRetainedBytes)

        store.computeLayout(root: r10.root, availableSpace: Size(width: .definite(1000), height: .definite(900))) { _, _, _ in
            LayoutOutput.fromOuterSize(Size(width: 120, height: 18))
        }
        #expect(store.boxLayout(r10.entries[0]).size == Size(width: 1000, height: 900))
        #expect(store.boxLayout(r10.entries[1]).size == Size(width: 1000, height: 32))
    }

    @Test func layoutStoreHoistedOofAspectFitAnchoredFitAndCacheHits() {
        var store = LayoutStore()
        var slots: [SlotId] = Array(repeating: SlotId(0), count: 6)

        func commitScene(pass: Int) -> SlotId {
            store.beginCommit()
            // 0: root (key 1), 1: static wrapper (key 10), 2: abs child (key 11), 3: aspect_fit (key 20), 4: overlay (key 30), 5: overlay leaf (key 31)
            let mStatic = store.beginChildren()
            let absStyle = TaffyStyle(
                position: .absolute,
                size: Size(width: length(88), height: length(36)),
                inset: Rect(left: .auto, right: .length(14.5), top: .length(9.25), bottom: .auto)
            )
            let (s11, d11) = store.syncNode(key: 11, nodeIndex: 2, style: absStyle, measure: nil, forceMeasureDirty: false, childMark: store.beginChildren(), childrenDirty: false)
            store.pushChild(s11)
            let (s10, d10) = store.syncNode(
                key: 10,
                nodeIndex: 1,
                style: TaffyStyle(display: .flex, position: .static, padding: Rect(left: .length(7.25), right: .length(7.25), top: .length(5.5), bottom: .length(5.5))),
                measure: nil,
                forceMeasureDirty: false,
                childMark: mStatic,
                childrenDirty: d11
            )

            let (s20, d20) = store.syncNode(
                key: 20,
                nodeIndex: 3,
                style: TaffyStyle(size: Size(width: percent(1), height: auto()), flexGrow: 1),
                measure: nil,
                forceMeasureDirty: false,
                childMark: store.beginChildren(),
                childrenDirty: false
            )

            let mOv = store.beginChildren()
            let (s31, d31) = store.syncNode(
                key: 31,
                nodeIndex: 5,
                style: TaffyStyle(size: Size(width: percent(1), height: auto())),
                measure: 99,
                forceMeasureDirty: false,
                childMark: store.beginChildren(),
                childrenDirty: false
            )
            store.pushChild(s31)
            let (s30, d30) = store.syncNode(
                key: 30,
                nodeIndex: 4,
                style: TaffyStyle(
                    position: .absolute,
                    size: Size(width: length(160), height: auto()),
                    inset: Rect(left: .length(0), right: .auto, top: .length(0), bottom: .auto)
                ),
                measure: nil,
                forceMeasureDirty: false,
                childMark: mOv,
                childrenDirty: d31
            )

            let mRoot = store.beginChildren()
            store.pushChild(s10)
            store.pushChild(s20)
            store.pushChild(s30)
            var (s1, _) = store.syncNode(
                key: 1,
                nodeIndex: 0,
                style: TaffyStyle(display: .flex, position: .relative, size: Size(width: length(400), height: length(300)), flexDirection: .column),
                measure: nil,
                forceMeasureDirty: false,
                childMark: mRoot,
                childrenDirty: d10 || d20 || d30
            )
            slots = [s1, s10, s11, s20, s30, s31]
            store.endCommit(root: &s1) { me, newSlot in slots[Int(me)] = newSlot }
            _ = pass
            return s1
        }

        final class Counter: @unchecked Sendable { var count = 0 }
        let room = Size<AvailableSpace>(width: .definite(400), height: .definite(300))

        // Commit 1 (cold)
        let root1 = commitScene(pass: 1)
        let coldCounter = Counter()
        store.computeLayout(root: root1, availableSpace: room) { input, _, _ in
            coldCounter.count += 1
            return LayoutOutput.fromOuterSize(Size(width: input.knownDimensions.width ?? 160, height: input.knownDimensions.height ?? 320))
        }
        #expect(coldCounter.count > 0)
        // D-T2: unrounded Layout matches BoxLayout
        #expect(store.layout(slots[2]).location.x == store.boxLayout(slots[2]).x)
        // Static node hoisted abs child relative to root (400 - 14.5 - 88 = 297.5)
        #expect(abs(store.boxLayout(slots[2]).x - (400 - 14.5 - 88 - 7.25)) < 8.0)

        // Commit 2 (warm, zero changes) -> 0 leaf measurements
        let root2 = commitScene(pass: 2)
        let warmCounter = Counter()
        store.computeLayout(root: root2, availableSpace: room) { input, _, _ in
            warmCounter.count += 1
            return LayoutOutput.fromOuterSize(Size(width: input.knownDimensions.width ?? 160, height: input.knownDimensions.height ?? 320))
        }
        #expect(warmCounter.count == 0)

        // Pass 2 intra-commit refit for aspect_fit + anchored_fit
        let roomSz = store.boxLayout(slots[3]).size
        let fitW = min(roomSz.width, roomSz.height * (16.0 / 9.0))
        let fitH = fitW / (16.0 / 9.0)
        let fitted = TaffyStyle(size: Size(width: length(fitW), height: length(fitH)), flexShrink: 0)
        store.setStyleAndMarkAncestors(slots[3], style: fitted, ancestors: [root2])
        var ovStyle = store.style(slots[4])
        ovStyle.setMaxHeight(length(180))
        store.setStyleAndMarkAncestors(slots[4], style: ovStyle, ancestors: [root2])

        store.computeLayout(root: root2, availableSpace: room) { input, _, _ in
            LayoutOutput.fromOuterSize(Size(width: input.knownDimensions.width ?? 160, height: input.knownDimensions.height ?? 320))
        }
        #expect(abs(store.boxLayout(slots[3]).w - fitW) < 0.01)
        #expect(abs(store.boxLayout(slots[3]).h - fitH) < 0.01)
        #expect(store.boxLayout(slots[4]).h <= 180.01)
    }

    @Test func layoutStoreCarriesCacheAcrossCommitsWithShiftAndReorder() {
        struct RowSpec {
            let idBase: UInt64
            let textW: Float
            let hash: UInt64
        }

        final class MeasureLog: @unchecked Sendable {
            var keys: [UInt64] = []
        }

        var store = LayoutStore()

        func runCommit(rows: [RowSpec], vpW: Float) -> [UInt64] {
            var idxToKey: [UInt64] = []
            var idxToSpec: [RowSpec?] = []
            func nextNodeIndex(key: UInt64, spec: RowSpec? = nil) -> UInt32 {
                let idx = UInt32(idxToKey.count)
                idxToKey.append(key)
                idxToSpec.append(spec)
                return idx
            }

            store.beginCommit()

            // Hidden Display.none subtree (key 30)
            let hiddenChildMark = store.beginChildren()
            let (hid, hDirty) = store.syncNode(
                key: 30,
                nodeIndex: nextNodeIndex(key: 30),
                style: TaffyStyle(display: .none, size: Size(width: length(90), height: length(90))),
                measure: nil,
                forceMeasureDirty: false,
                childMark: hiddenChildMark,
                childrenDirty: false
            )

            var rowSlots: [SlotId] = []
            var anyRowDirty = false
            for row in rows {
                let iconMark = store.beginChildren()
                let (iconSlot, dIcon) = store.syncNode(
                    key: row.idBase + 1,
                    nodeIndex: nextNodeIndex(key: row.idBase + 1),
                    style: TaffyStyle(size: Size(width: length(16), height: length(16)), flexShrink: 0),
                    measure: nil,
                    forceMeasureDirty: false,
                    childMark: iconMark,
                    childrenDirty: false
                )
                let textMark = store.beginChildren()
                let (textSlot, dText) = store.syncNode(
                    key: row.idBase + 2,
                    nodeIndex: nextNodeIndex(key: row.idBase + 2, spec: row),
                    style: TaffyStyle(minSize: Size(width: length(0), height: auto()), flexGrow: 1, flexShrink: 1, flexBasis: length(0)),
                    measure: row.hash,
                    forceMeasureDirty: false,
                    childMark: textMark,
                    childrenDirty: false
                )
                let rowMark = store.beginChildren()
                store.pushChild(iconSlot)
                store.pushChild(textSlot)
                let (rowSlot, dRow) = store.syncNode(
                    key: row.idBase,
                    nodeIndex: nextNodeIndex(key: row.idBase),
                    style: TaffyStyle(
                        display: .flex,
                        position: .relative,
                        size: Size(width: percent(1), height: auto()),
                        padding: Rect(left: .length(8), right: .length(8), top: .length(4), bottom: .length(4)),
                        gap: Size(width: .length(6), height: .length(0)),
                        flexDirection: .row,
                        flexShrink: 0,
                        alignItems: .center
                    ),
                    measure: nil,
                    forceMeasureDirty: false,
                    childMark: rowMark,
                    childrenDirty: dIcon || dText
                )
                anyRowDirty = anyRowDirty || dRow
                rowSlots.append(rowSlot)
            }

            let rootMark = store.beginChildren()
            store.pushChild(hid)
            for s in rowSlots { store.pushChild(s) }
            var (root, _) = store.syncNode(
                key: 1,
                nodeIndex: nextNodeIndex(key: 1),
                style: TaffyStyle(
                    display: .flex,
                    position: .relative,
                    size: Size(width: length(vpW), height: length(500)),
                    padding: Rect(all: .length(8)),
                    gap: Size(width: .length(0), height: .length(4)),
                    flexDirection: .column
                ),
                measure: nil,
                forceMeasureDirty: false,
                childMark: rootMark,
                childrenDirty: hDirty || anyRowDirty
            )
            store.endCommit(root: &root) { _, _ in }

            let log = MeasureLog()
            let keyMap = idxToKey
            let specMap = idxToSpec
            store.computeLayout(root: root, availableSpace: Size(width: .definite(vpW), height: .definite(500))) { input, ctx, _ in
                guard let ctx, let spec = specMap[ctx] else { return LayoutOutput.fromOuterSize(.zero) }
                log.keys.append(keyMap[ctx])
                let maxW = input.knownDimensions.width ?? {
                    switch input.availableSpace.width {
                    case .definite(let w): return w
                    case .minContent: return max(spec.textW * 0.25, 20)
                    case .maxContent: return nil
                    }
                }()
                let (w, lines): (Float, Float) = if let limit = maxW, spec.textW > limit, limit > 0 {
                    (limit, (spec.textW / limit).rounded(.up))
                } else {
                    (spec.textW, 1)
                }
                return LayoutOutput.fromOuterSize(Size(
                    width: input.knownDimensions.width ?? w,
                    height: input.knownDimensions.height ?? (lines * 16)
                ))
            }
            #expect(store.boxLayout(hid) == .zero)
            return log.keys
        }

        let rows1 = (0..<8).map { i in
            RowSpec(idBase: UInt64(100 + i * 10), textW: 220 + Float(i) * 35, hash: UInt64(1000 + i))
        }

        // Commit 1: cold
        let keys1 = runCommit(rows: rows1, vpW: 360)
        #expect(keys1.count >= 8)

        // Commit 2: warm -> 0 measures
        let keys2 = runCommit(rows: rows1, vpW: 360)
        #expect(keys2.isEmpty)

        // Commit 3: prepend row 90 -> only newly inserted leaf key 92 measures!
        let rows3 = [RowSpec(idBase: 90, textW: 310, hash: 9999)] + rows1
        let keys3 = runCommit(rows: rows3, vpW: 360)
        #expect(!keys3.isEmpty)
        #expect(keys3.allSatisfy { $0 == 92 })

        // Commit 4: narrow viewport 360 -> 280 -> re-measures
        let keys4 = runCommit(rows: rows3, vpW: 280)
        #expect(keys4.count >= 8)

        // Commit 5: reorder, drop, add 500 & 510, mutate row 110 hash -> unchanged reordered rows (92, 142) stay cached
        let rows5 = [
            rows3[5], // idBase 140
            RowSpec(idBase: 500, textW: 410, hash: 5001),
            RowSpec(idBase: rows3[2].idBase, textW: 480, hash: 77777), // idBase 110 mutated
            RowSpec(idBase: 510, textW: 145, hash: 5002),
            rows3[0], // idBase 90
        ]
        let keys5 = runCommit(rows: rows5, vpW: 280)
        #expect(keys5.contains(502))
        #expect(keys5.contains(512))
        #expect(keys5.contains(112))
        #expect(!keys5.contains(92))
        #expect(!keys5.contains(142))
    }

    @Test func layoutStoreMemoReuseRetryGuardAndRekeyBatch() {
        var store = LayoutStore()

        // Commit 1: create slot for key 10
        store.beginCommit()
        var s1 = TaffyStyle.runeBase(.row)
        s1.setWidth(length(120))
        s1.setHeight(length(40))
        let (slot10, _) = store.syncNode(
            key: 10,
            nodeIndex: 0,
            style: s1,
            measure: 42,
            forceMeasureDirty: false,
            childMark: store.beginChildren(),
            childrenDirty: false
        )
        store.finishFlatten()
        store.compactIfSparse { _, _ in }
        #expect(store.measureHash(key: 10) == .some(42))
        #expect(store.measureHash(key: 999) == nil)

        // Commit 2, Pass 1 (discarded before apply): key 10 mutates to width 300
        store.beginCommit()
        #expect(store.canReuse(key: 10, slot: slot10))
        var sTmp = TaffyStyle.runeBase(.row)
        sTmp.setWidth(length(300))
        sTmp.setHeight(length(40))
        _ = store.syncNode(
            key: 10,
            nodeIndex: 0,
            style: sTmp,
            measure: 42,
            forceMeasureDirty: false,
            childMark: store.beginChildren(),
            childrenDirty: false
        )
        store.finishFlatten()

        // Commit 2, Pass 2 (retry): `canReuse` must reject `slot10` because Pass 1 mutated it!
        store.beginCommit()
        #expect(!store.canReuse(key: 10, slot: slot10))

        // Normal flatten restores s1 and compacts
        _ = store.syncNode(
            key: 10,
            nodeIndex: 0,
            style: s1,
            measure: 42,
            forceMeasureDirty: false,
            childMark: store.beginChildren(),
            childrenDirty: false
        )
        store.finishFlatten()
        store.compactIfSparse { _, _ in }

        // Commit 3: clean slot reusable again and can rekey cleanly 10 -> 20
        store.beginCommit()
        #expect(store.canReuse(key: 10, slot: slot10))
        store.rekeyAndReuseBatch([(UInt64(10), UInt64(20), slot10, UInt32(3))])
        #expect(store.mountedNodeIndex(key: 20) == 3)
        #expect(store.mountedNodeIndex(key: 10) == nil)
    }
}
