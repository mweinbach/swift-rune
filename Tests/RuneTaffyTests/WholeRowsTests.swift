import Testing
@testable import RuneTaffy

@Suite("Whole-point flex rows")
struct WholeRowsTests {
    @Test func measuredRowsReuseTheirFractionalMeasurementAcrossParentStyleChanges() throws {
        var tree = TaffyTree()
        var column = TaffyStyle(flexDirection: .column)
        let rows = [Float(1.25), 2.5, 3.75].map { height in
            tree.newLeafWithSimpleMeasure { _ in Size(width: 12, height: height) }
        }
        let root = try tree.newWithChildren(column, children: rows)
        for enabled in [false, true, false, true] {
            column.wholeRows = enabled
            try tree.setStyle(root, column)
            try tree.computeLayout(root, availableSpace: .maxContent)
            let boxes = try rows.map { try tree.unroundedLayout($0) }
            #expect(boxes.map(\.size.height) == (enabled ? [1, 3, 4] : [1.25, 2.5, 3.75]))
            #expect(boxes.map(\.location.y) == (enabled ? [0, 1, 4] : [0, 1.25, 3.75]))
            #expect(try tree.unroundedLayout(root).size.height == (enabled ? 8 : 7.5))
        }
    }

    @Test func inFlowRowSizesDriveFractionalSpacingAndAbsoluteAnchors() throws {
        var tree = TaffyTree()
        var column = TaffyStyle(position: .relative, flexDirection: .column, wholeRows: true)
        column.padding.top = .length(1.25)
        column.padding.bottom = .length(2.125)
        column.gap.height = .length(0.375)
        var first = TaffyStyle(size: Size(width: .auto, height: .length(5.25)))
        first.margin.top = .length(0.875)
        first.margin.bottom = .length(0.375)
        var second = TaffyStyle(size: Size(width: .auto, height: .length(6.5)))
        second.margin.top = .length(-0.375)
        second.margin.bottom = .length(0.25)
        let rows = [first, second, TaffyStyle(size: Size(width: .auto, height: .length(3.625)))].map {
            tree.newLeaf($0)
        }
        let overlay = tree.newLeaf(TaffyStyle(position: .absolute, inset: Rect(all: .zero)))
        let badge = tree.newLeaf(TaffyStyle(position: .absolute, size: Size(width: .auto, height: .length(6.125))))
        let root = try tree.newWithChildren(column, children: rows + [overlay, badge])
        try tree.computeLayout(root, availableSpace: .maxContent)
        let boxes = try rows.map { try tree.unroundedLayout($0) }
        #expect(boxes.map(\.size.height) == [5, 7, 4])
        #expect(boxes.map(\.location.y) == [2.125, 7.5, 15.125])
        #expect(try tree.unroundedLayout(root).size.height == 21.25)
        #expect(try tree.unroundedLayout(overlay).size.height == 21.25)
        #expect(try tree.unroundedLayout(badge).size.height == 6.125)
    }

    @Test func percentageAspectRatioAndFinalFlexSharesStayFractional() throws {
        var tree = TaffyTree()
        var column = TaffyStyle(size: Size(width: .length(100.5), height: .length(100.25)),
                                flexDirection: .column, wholeRows: true, alignItems: .flexStart)
        let percent = tree.newLeaf(TaffyStyle(size: Size(width: .auto, height: .percent(0.125))))
        let aspect = tree.newLeaf(TaffyStyle(size: Size(width: .length(17.5), height: .auto), aspectRatio: 2))
        let fixed = tree.newLeaf(TaffyStyle(size: Size(width: .auto, height: .length(10.5))))
        let root = try tree.newWithChildren(column, children: [percent, aspect, fixed])
        try tree.computeLayout(root, availableSpace: .maxContent)
        let rowHeights = try [percent, aspect, fixed].map { try tree.unroundedLayout($0).size.height }
        #expect(rowHeights == [12.53125, 8.75, 11])

        column.size.height = .length(48.75)
        try tree.setStyle(root, column)
        try tree.setStyle(percent, TaffyStyle(flexGrow: 1, flexBasis: .length(7.3)))
        try tree.setStyle(aspect, TaffyStyle(flexGrow: 2, flexBasis: .length(5.5)))
        try tree.setStyle(fixed, TaffyStyle(size: Size(width: .auto, height: .length(1.5))))
        try tree.computeLayout(root, availableSpace: .maxContent)
        #expect(try [percent, aspect, fixed].map { try tree.unroundedLayout($0).size.height } == [18.25, 28.5, 2])
    }

    @Test func contentBoxRoundsItsLengthBeforeAddingInsets() throws {
        var tree = TaffyTree()
        var style = TaffyStyle(boxSizing: .contentBox, size: Size(width: .auto, height: .length(6.375)))
        style.padding.top = .length(0.125)
        style.padding.bottom = .length(0.375)
        style.border.top = .length(0.125)
        style.border.bottom = .length(0.25)
        let row = tree.newLeaf(style)
        let root = try tree.newWithChildren(TaffyStyle(flexDirection: .column, wholeRows: true), children: [row])
        try tree.computeLayout(root, availableSpace: .maxContent)
        #expect(try tree.unroundedLayout(row).size.height == 6.875)
    }

    @Test func flagSurvivesExtendedStyleAndBelongsToInnerScrollColumn() {
        var style = CompactStyle.runeBase(.column)
        let plain = style
        style.setWholeRows()
        #expect(style.isWholeRowsColumn && style != plain && style.heapBytes() == 0)
        style.justifyContent = .center
        style.aspectRatio = 1.75
        let outer = style.takeBoxPlacement()
        #expect(!outer.wholeRows && style.isWholeRowsColumn)
        style.flexDirection = .columnReverse
        #expect(!style.isWholeRowsColumn)
        style.flexDirection = .column
        style.flexWrap = .wrap
        #expect(!style.isWholeRowsColumn)
        style.flexWrap = .noWrap
        style.display = .grid
        #expect(!style.isWholeRowsColumn)
    }

    @Test func extendedDimensionWidthStillRoundsAbsoluteRowHeight() throws {
        var tree = TaffyTree()
        // Width uses a cold keyword (minContent) so `size` spills to ExtendedStyle; height is a length that must still round.
        let child = tree.newLeaf(TaffyStyle(size: Size(width: .minContent, height: .length(6.375))))
        let root = try tree.newWithChildren(
            TaffyStyle(flexDirection: .column, wholeRows: true),
            children: [child]
        )
        try tree.computeLayout(root, availableSpace: .maxContent)
        #expect(try tree.unroundedLayout(child).size.height == 6)
    }
}
