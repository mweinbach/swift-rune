import RuneMotion

extension Runtime {
    /// The layout solver sees a fixed-height placeholder for each consecutive run of
    /// unchanged rows. Restore the actual children before virtual measurement and flattening.
    struct FixedVirtualRowLayout {
        // Float represents every integral coordinate through 2^24 exactly.
        static var maximumExactHeight: Float { 16_777_216 }

        let source: El<State>
        let listIndices: [Int]
        let groups: [(position: Int, saved: [LayoutEngine.ResultNode])]
        let boxes: [NodeId: RetainedLayoutCoordinator.TextLayoutRecord]
        let width: Float

        func restore(_ solved: inout LayoutEngine.ResultNode) -> Bool {
            var ancestors: [LayoutEngine.ResultNode] = []
            var list = solved
            for index in listIndices {
                guard list.children.indices.contains(index) else { return false }
                ancestors.append(list)
                list = list.children[index]
            }
            guard list.layout.localSize.x == width else { return false }
            let compact = list.children
            var children: [LayoutEngine.ResultNode] = []
            var group = 0
            for (i, result) in compact.enumerated() {
                guard group < groups.count, groups[group].position == i else {
                    children.append(result)
                    continue
                }
                let box = result.layout.localRect
                guard box.x == 0, box.width == width, box.y >= 0, box.y.rounded() == box.y,
                      box.bottom <= Self.maximumExactHeight else { return false }
                var y = box.y
                for var row in groups[group].saved {
                    let size = row.layout.localSize
                    row.layout.localRect = .fromXYWH(box.x, y, size.x, size.y)
                    children.append(row)
                    y += size.y
                }
                guard y == box.bottom else { return false }
                group += 1
            }
            guard group == groups.count else { return false }
            list.children = children
            for (ancestor, index) in zip(ancestors, listIndices).reversed() {
                var parent = ancestor
                parent.children[index] = list
                list = parent
            }
            solved = list
            return true
        }
    }
}
