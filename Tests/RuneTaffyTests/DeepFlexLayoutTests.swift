import Testing
@testable import RuneTaffy

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
