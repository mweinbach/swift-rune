// MARK: - Subpixel-Free Cumulative Layout Rounding

/// Rounds unrounded layout coordinates into integer pixel boundaries using cumulative
/// parent-space positions so adjacent siblings never leave 1px hairline gaps.
///
/// Matches Taffy's `round_layout` algorithm.
internal func roundLayout<Tree: LayoutTree>(tree: Tree, root: NodeId) {
    tree.visitSubtree(root, inheriting: Point<Float>.zero) { node, parent in
        let unrounded = tree.unroundedLayout(node)
        let cumX = parent.x + unrounded.location.x
        let cumY = parent.y + unrounded.location.y

        var rounded = unrounded
        rounded.location = Point(
            x: unrounded.location.x.rounded(),
            y: unrounded.location.y.rounded()
        )
        rounded.size = Size(
            width: (cumX + unrounded.size.width).rounded() - cumX.rounded(),
            height: (cumY + unrounded.size.height).rounded() - cumY.rounded()
        )
        rounded.contentSize = Size(
            width: (cumX + unrounded.contentSize.width).rounded() - cumX.rounded(),
            height: (cumY + unrounded.contentSize.height).rounded() - cumY.rounded()
        )
        rounded.padding = Rect(
            left: unrounded.padding.left.rounded(),
            right: unrounded.padding.right.rounded(),
            top: unrounded.padding.top.rounded(),
            bottom: unrounded.padding.bottom.rounded()
        )
        rounded.border = Rect(
            left: unrounded.border.left.rounded(),
            right: unrounded.border.right.rounded(),
            top: unrounded.border.top.rounded(),
            bottom: unrounded.border.bottom.rounded()
        )

        tree.setFinalLayout(node, rounded)
        return Point(x: cumX, y: cumY)
    }
}
