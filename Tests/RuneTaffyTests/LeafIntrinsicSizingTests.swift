import Testing
@testable import RuneTaffy

@Test func intrinsicContentContributesBeforeFlexRowHeightIsClamped() throws {
    var tree = TaffyTree()
    let leaf = tree.newLeafWithSimpleMeasure(TaffyStyle(
        maxSize: Size(width: .auto, height: .length(9.5)), flexShrink: 0
    )) { _ in Size(width: 6, height: 15.75) }
    var column = TaffyStyle(size: Size(width: .length(100.5), height: .auto), flexDirection: .column)
    let root = try tree.newWithChildren(column, children: [leaf])
    for enabled in [false, true, false] {
        column.wholeRows = enabled
        try tree.setStyle(root, column)
        try tree.computeLayout(root, availableSpace: .maxContent)
        let containerHeight = try tree.unroundedLayout(root).size.height
        let rowHeight = try tree.unroundedLayout(leaf).size.height
        #expect(containerHeight == (enabled ? 16 : 15.75))
        #expect(rowHeight == (enabled ? 10 : 9.5))
    }
}
