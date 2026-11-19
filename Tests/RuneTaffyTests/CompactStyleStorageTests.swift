import Testing
@testable import RuneTaffy

@Suite("Compact layout style storage")
struct CompactStyleStorageTests {
    @Test func runeStylesFitOneCacheLine() {
        if MemoryLayout<Int>.size == 8 {
            #expect(MemoryLayout<CompactStyle>.size == 64)
            #expect(MemoryLayout<CompactStyle>.stride == 64)
        } else {
            #expect(MemoryLayout<CompactStyle>.stride <= 64)
        }

        #expect(CompactStyle.default.position == .static)
        let dimensions: [Dimension] = [.auto, .zero, .length(42.5), .percent(0.375), .maxContent]
        for width in dimensions {
            for height in dimensions {
                var style = CompactStyle.runeBase(.columnReverse)
                style.size = Size(width: width, height: height)
                style.minSize = Size(width: .length(10), height: .percent(0.25))
                style.maxSize = Size(width: .auto, height: .length(500))
                style.padding = Rect(left: .length(4), right: .percent(0.125), top: .length(8), bottom: .length(12))
                style.gap = Size(width: .length(6), height: .percent(0.25))
                style.setGrow(1.5)
                style.flexShrink = 0.25
                style.flexWrap = .wrap
                style.setOverflow(.hidden, .scroll)
                style.alignItems = .center
                style.alignSelf = .flexEnd
                style.justifyContent = .spaceBetween
                style.alignContent = .stretch

                #expect(style.position == .relative)
                #expect(style.size == Size(width: width, height: height))
                #expect(style.minSize == Size(width: .length(10), height: .percent(0.25)))
                #expect(style.maxSize == Size(width: .auto, height: .length(500)))
                #expect(style.padding.right == .percent(0.125))
                #expect(style.gap.height == .percent(0.25))
                #expect(style.flexShrink == 0.25 && style.flexGrow == 1.5 && style.flexBasis == .zero)
                #expect(style.flexWrap == .wrap && style.flexDirection == .columnReverse)
                #expect(style.overflow == Point(x: .hidden, y: .scroll))
                #expect(style.alignItems == .center && style.alignSelf == .flexEnd)
                #expect(style.justifyContent == .spaceBetween && style.alignContent == .stretch)
                #expect(style.heapBytes() == 0)
            }
        }
    }

    @Test func extendedValuesAreExactAndReleaseTheirLastAllocation() {
        let base = CompactStyle.runeBase()
        var style = base
        let precise = Float(bitPattern: 0x3EAB_CDEF)
        style.flexGrow = precise
        style.flexShrink = -Float.leastNonzeroMagnitude
        style.gap = Size(width: .percent(precise), height: .length(2))
        style.flexBasis = .fitContentPercent(precise)
        style.gridTemplateColumns = [.fr(1)]
        style.inset.left = .percent(precise)

        #expect(style.flexGrow.bitPattern == precise.bitPattern)
        #expect(style.flexShrink.bitPattern == (-Float.leastNonzeroMagnitude).bitPattern)
        #expect(style.gap == Size(width: .percent(precise), height: .length(2)))
        #expect(style.flexBasis == .fitContentPercent(precise))
        #expect(style.heapBytes() > 0)

        let retained = style
        style.flexGrow = 0
        style.flexShrink = 0
        style.gap = Size(width: .zero, height: .zero)
        style.flexBasis = .auto
        style.gridTemplateColumns.removeAll()
        #expect(style.heapBytes() > 0)
        style.inset.left = .auto
        #expect(style.heapBytes() == 0)
        #expect(style == base)
        #expect(Set([style, base, retained]).count == 2)
        #expect(retained.inset.left == .percent(precise))
        #expect(retained.gridTemplateColumns == [.fr(1)])
        #expect(retained.gap.width == .percent(precise))

        let negativeZero = CompactStyle(flexGrow: -0.0, flexBasis: .length(-0.0))
        let positiveZero = CompactStyle(flexGrow: 0, flexBasis: .length(0))
        #expect(negativeZero.flexGrow.bitPattern == Float(-0.0).bitPattern)
        if case .length(let value) = negativeZero.flexBasis {
            #expect(value.bitPattern == Float(-0.0).bitPattern)
        } else {
            Issue.record("lost flex basis unit")
        }
        #expect(negativeZero == positiveZero)
        #expect(Set([negativeZero, positiveZero]).count == 1)
    }

    @Test func intrinsicLengthsAndBoxPlacementSurvivePacking() {
        let values: [Dimension] = [.length(-13), .percent(0.125), .minContent, .maxContent,
                                   .fitContentPx(123.25), .fitContentPercent(0.12345), .auto]
        var style = CompactStyle(display: .block)
        for width in values {
            for height in values {
                let pair = Size(width: width, height: height)
                style.size = pair
                style.minSize = pair
                style.maxSize = pair
                #expect(style.size == pair && style.minSize == pair && style.maxSize == pair)
            }
        }
        var inline = CompactStyle(display: .block)
        let wrapper = inline.takeBoxPlacement()
        #expect(inline.display == .flex && wrapper.display == .flex)
        #expect(wrapper.position == .static && inline.position == .relative)

        for coldKeyword in [Dimension.minContent, .fitContentPx(99), .fitContentPercent(0.4)] {
            var block = CompactStyle(display: .block, size: Size(width: coldKeyword, height: .auto))
            let wrapper = block.takeBoxPlacement()
            #expect(wrapper.size.width == coldKeyword)
            #expect(block.display == .block)
        }
        var grid = CompactStyle(display: .grid, gridTemplateColumns: [.fr(1)])
        _ = grid.takeBoxPlacement()
        #expect(grid.display == .grid && grid.gridTemplateColumns == [.fr(1)])
    }

    @Test func alignmentSafetyRoundTripsInlineAndThroughLayoutTraits() {
        let itemKeywords: [AlignItemsKeyword] = [
            .normal, .start, .end, .flexStart, .flexEnd, .selfStart, .selfEnd, .center, .baseline, .stretch
        ]
        let contentKeywords: [AlignContentKeyword] = [
            .normal, .start, .end, .flexStart, .flexEnd, .center, .stretch, .spaceBetween, .spaceEvenly, .spaceAround
        ]
        let safeties: [AlignmentSafety] = [.default, .unsafe, .safe]

        for safety in safeties {
            for kw in itemKeywords {
                let value = AlignItems(keyword: kw, safety: safety)
                var style = CompactStyle.runeBase(.column)
                style.setAlignItems(value)
                style.setAlignSelf(value)
                #expect(style.alignItems == value)
                #expect(style.alignSelf == value)
                #expect(style.alignItems?.keyword == kw && style.alignItems?.safety == safety)
                #expect(style.heapBytes() == 0, "hot alignItems/alignSelf with safety must fit inline in 64 bytes")

                // Cold justifyItems / justifySelf preserve safety and release allocation when cleared.
                style.justifyItems = value
                style.justifySelf = value
                #expect(style.justifyItems == value && style.justifySelf == value)
                #expect(style.heapBytes() > 0)
                style.justifyItems = nil
                style.justifySelf = nil
                #expect(style.heapBytes() == 0)
            }
            for kw in contentKeywords {
                let value = AlignContent(keyword: kw, safety: safety)
                var style = CompactStyle.runeBase(.column)
                style.setAlignContent(value)
                style.setJustifyContent(value)
                style.setWholeRows()
                #expect(style.alignContent == value)
                #expect(style.justifyContent == value)
                #expect(style.wholeRows)
                #expect(style.heapBytes() == 0, "hot alignContent/justifyContent with safety + wholeRows must fit inline")
            }
        }

        // Distinct safety values compare unequal and hash distinctly.
        let defCenter = CompactStyle(alignItems: .center)
        let safeCenter = CompactStyle(alignItems: .safe(.center))
        let unsafeCenter = CompactStyle(alignItems: .unsafe(.center))
        #expect(defCenter != safeCenter && safeCenter != unsafeCenter && defCenter != unsafeCenter)
        #expect(Set([defCenter, safeCenter, unsafeCenter]).count == 3)

        // takeBoxPlacement preserves alignment safety on both outer and inner styles.
        var wrapped = CompactStyle.runeBase(.column)
        wrapped.setWholeRows()
        wrapped.setAlignSelf(.safe(.flexEnd))
        wrapped.setJustifyContent(.unsafe(.center))
        wrapped.justifySelf = .safe(.end)
        let outer = wrapped.takeBoxPlacement()
        #expect(outer.alignSelf == .safe(.flexEnd))
        #expect(outer.justifySelf == .safe(.end))
        #expect(wrapped.alignSelf == nil && wrapped.justifySelf == nil)
        #expect(wrapped.justifyContent == .unsafe(.center))
        #expect(wrapped.wholeRows && !outer.wholeRows)

        // Position fixed/sticky spill cleanly to cold storage and release when reset.
        var positioned = CompactStyle.default
        for pos in [Position.fixed, .sticky] {
            positioned.position = pos
            #expect(positioned.position == pos)
            #expect(positioned.heapBytes() > 0)
        }
        positioned.position = .static
        #expect(positioned == CompactStyle.default && positioned.heapBytes() == 0)
    }

    @Test func compressibleReplacedAndLayoutStyleProtocolsMatchUpstream() {
        func inspectCore<S: CoreLayoutStyle>(_ s: S) -> (BoxGenerationMode, Bool, Bool, Bool) {
            (s.boxGenerationMode, s.isBlock, s.isReplaced, s.isCompressibleReplaced)
        }
        func inspectFlex<S: FlexboxContainerLayoutStyle & FlexboxItemLayoutStyle>(_ s: S) -> (AlignItems?, AlignSelf?, JustifyContent?, AlignContent?) {
            (s.alignItems, s.alignSelf, s.justifyContent, s.alignContent)
        }
        func inspectBlock<S: BlockContainerLayoutStyle & BlockItemLayoutStyle>(_ s: S) -> (TextAlign, Bool, JustifyItems?, JustifySelf?) {
            (s.textAlign, s.isTable, s.justifyItems, s.justifySelf)
        }
        func inspectGrid<S: GridContainerLayoutStyle & GridItemLayoutStyle>(_ s: S) -> (GridAutoFlow, AlignItems?, JustifySelf?) {
            (s.gridAutoFlow, s.alignItems, s.justifySelf)
        }
        func inspectOof<S: OutOfFlowItemLayoutStyle>(_ s: S) -> (Bool, AlignSelf?, JustifySelf?) {
            (s.isTable, s.alignSelf, s.justifySelf)
        }

        // Default style: not replaced, not compressible replaced, 0 heap bytes.
        var style = CompactStyle.default
        #expect(!style.itemIsReplaced && !style.itemIsCompressibleReplaced && !style.isCompressibleReplaced)
        #expect(inspectCore(style) == (.normal, false, false, false))
        #expect(style.heapBytes() == 0)

        // Setting itemIsCompressibleReplaced alone sets isCompressibleReplaced without setting isReplaced.
        style.itemIsCompressibleReplaced = true
        #expect(style.itemIsCompressibleReplaced)
        #expect(style.isCompressibleReplaced)
        #expect(!style.isReplaced)
        #expect(style.heapBytes() > 0)
        #expect(inspectCore(style) == (.normal, false, false, true))

        // Clearing releases extended storage back to 0 heap bytes.
        style.isCompressibleReplaced = false
        #expect(!style.itemIsCompressibleReplaced && !style.isCompressibleReplaced)
        #expect(style.heapBytes() == 0)
        #expect(style == CompactStyle.default)

        // Setting itemIsReplaced implies isCompressibleReplaced (matching upstream traits.rs:23).
        let replaced = CompactStyle(display: .block, itemIsReplaced: true)
        #expect(replaced.isBlock && replaced.isReplaced && replaced.isCompressibleReplaced)
        #expect(!replaced.itemIsCompressibleReplaced)
        #expect(inspectCore(replaced) == (.normal, true, true, true))

        let hidden = CompactStyle(display: .none, itemIsCompressibleReplaced: true)
        #expect(inspectCore(hidden) == (.none, false, false, true))

        let full = CompactStyle(
            textAlign: .center,
            alignItems: .safe(.center),
            alignSelf: .unsafe(.end),
            justifyItems: .safe(.start),
            justifySelf: .unsafe(.flexEnd),
            alignContent: .safe(.spaceBetween),
            justifyContent: .unsafe(.center),
            gridAutoFlow: .columnDense,
            itemIsTable: true
        )
        let flex = inspectFlex(full)
        #expect(flex.0 == .safe(.center) && flex.1 == .unsafe(.end) && flex.2 == .unsafe(.center) && flex.3 == .safe(.spaceBetween))
        let block = inspectBlock(full)
        #expect(block.0 == .center && block.1 && block.2 == .safe(.start) && block.3 == .unsafe(.flexEnd))
        let grid = inspectGrid(full)
        #expect(grid.0 == .columnDense && grid.1 == .safe(.center) && grid.2 == .unsafe(.flexEnd))
        let oof = inspectOof(full)
        #expect(oof.0 && oof.1 == .unsafe(.end) && oof.2 == .unsafe(.flexEnd))
    }

    @Test func safeVsUnsafeAlignmentControlsOverflowEdgeInFlexAndGrid() throws {
        // Overflowing flex child: 120x80 inside 60x40 container.
        // Unsafe center puts child at (-30, -20); safe center clamps to start edge (0, 0).
        var tree = TaffyTree()
        tree.roundingEnabled = false
        let childStyle = TaffyStyle(size: Size(width: .length(120), height: .length(80)), flexShrink: 0)

        let unsafeChild = tree.newLeaf(childStyle)
        let unsafeRoot = try tree.newWithChildren(
            TaffyStyle(
                display: .flex,
                size: Size(width: .length(60), height: .length(40)),
                flexDirection: .row,
                alignItems: .unsafe(.center),
                justifyContent: .unsafe(.center)
            ),
            children: [unsafeChild]
        )
        try tree.computeLayout(unsafeRoot, availableSpace: .maxContent)
        #expect(try tree.unroundedLayout(unsafeChild).location == Point(x: -30, y: -20))

        let safeChild = tree.newLeaf(childStyle)
        let safeRoot = try tree.newWithChildren(
            TaffyStyle(
                display: .flex,
                size: Size(width: .length(60), height: .length(40)),
                flexDirection: .row,
                alignItems: .safe(.center),
                justifyContent: .safe(.center)
            ),
            children: [safeChild]
        )
        try tree.computeLayout(safeRoot, availableSpace: .maxContent)
        #expect(try tree.unroundedLayout(safeChild).location == Point(x: 0, y: 0))

        // Overflowing grid item: 100x60 inside 50x30 cell.
        let unsafeGridItem = tree.newLeaf(TaffyStyle(
            size: Size(width: .length(100), height: .length(60)),
            alignSelf: .unsafe(.end),
            justifySelf: .unsafe(.center)
        ))
        let safeGridItem = tree.newLeaf(TaffyStyle(
            size: Size(width: .length(100), height: .length(60)),
            alignSelf: .safe(.end),
            justifySelf: .safe(.center)
        ))
        let gridRoot = try tree.newWithChildren(
            TaffyStyle(
                display: .grid,
                size: Size(width: .length(100), height: .length(30)),
                gridTemplateRows: [.length(30)],
                gridTemplateColumns: [.length(50), .length(50)]
            ),
            children: [unsafeGridItem, safeGridItem]
        )
        try tree.computeLayout(gridRoot, availableSpace: .maxContent)
        #expect(try tree.unroundedLayout(unsafeGridItem).location == Point(x: -25, y: -30))
        #expect(try tree.unroundedLayout(safeGridItem).location == Point(x: 50, y: 0))
    }
}
