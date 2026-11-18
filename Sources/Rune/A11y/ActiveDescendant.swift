extension Runtime {
    /// Native accessibility follows the active row of a focused composite. The
    /// browser keeps DOM focus on the composite and exports aria-activedescendant.
    internal func nativeAccessibilitySnapshot(securePaths: Set<String> = []) -> AccessibilityNode {
        let redirect = nativeFocusRedirect()
        var tree = accessibilitySnapshot(securePaths: securePaths)
        guard let redirect,
              let target = tree.route(where: { $0.runtimePath == redirect.target }),
              let owner = tree.route(where: { $0.isFocused && $0.runtimePath == redirect.owner }) else { return tree }
        tree.setNativeFocus(false, at: owner[...])
        tree.setNativeFocus(true, at: target[...])
        return tree
    }

    // Resolve the selector against the mounted frame before an editor can publish another.
    private func nativeFocusRedirect() -> (owner: String, target: String)? {
        guard let focusedPath, let index = nodeByPath[focusedPath],
              let selector = flatNodes[index].el.a11yActiveDescendant, !selector.isEmpty else { return nil }

        func matches(_ index: Int) -> Bool {
            let node = flatNodes[index]
            return selectsElementSelector(selector, path: node.path, key: node.key)
        }

        // Runtime nodes are in preorder. The first sibling after this subtree has
        // a parent before the composite; a popup can still be elsewhere in the tree.
        let descendants = flatNodes.indices.suffix(from: index + 1).lazy.prefix {
            (self.flatNodes[$0].parentIndex ?? -1) >= index
        }
        guard let targetIndex = descendants.first(where: matches) ?? flatNodes.indices.first(where: matches),
              targetIndex != index, !subtreeExiting(targetIndex) else { return nil }
        return (focusedPath, flatNodes[targetIndex].path)
    }
}

private extension AccessibilityNode {
    func route(where matches: (Self) -> Bool) -> [Int]? {
        if matches(self) { return [] }
        for (index, child) in children.enumerated() {
            if let rest = child.route(where: matches) { return [index] + rest }
        }
        return nil
    }

    mutating func setNativeFocus(_ focused: Bool, at route: ArraySlice<Int>) {
        if let index = route.first {
            children[index].setNativeFocus(focused, at: route.dropFirst())
        } else {
            isFocused = focused
        }
    }
}
