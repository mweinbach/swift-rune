// MARK: - NodeId & MeasureFunc

/// Opaque node identifier in `TaffyTree` or `LayoutStore`.
public struct NodeId: Sendable, Equatable, Hashable, Comparable {
    public let rawValue: UInt64

    @inlinable
    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    @inlinable
    public var index: Int {
        Int(truncatingIfNeeded: rawValue & 0xFFFF_FFFF)
    }

    @inlinable
    public var generation: UInt32 {
        UInt32(truncatingIfNeeded: rawValue >> 32)
    }

    @inlinable
    public static func make(index: Int, generation: UInt32) -> NodeId {
        NodeId((UInt64(generation) << 32) | UInt64(UInt32(truncatingIfNeeded: index)))
    }

    @inlinable
    public static func < (lhs: NodeId, rhs: NodeId) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Custom measurement callback for leaf nodes.
public typealias MeasureFunc = @Sendable (
    _ knownDimensions: Size<Float?>,
    _ availableSpace: Size<AvailableSpace>,
    _ style: TaffyStyle
) -> Size<Float>

/// Simplified measurement callback taking only `AvailableSpace`.
public typealias SimpleMeasureFunc = @Sendable (_ availableSpace: Size<AvailableSpace>) -> Size<Float>

// MARK: - Internal LayoutTree Abstraction

internal protocol LayoutTree: AnyObject {
    var containerDepth: Int { get set }
    func childCount(_ node: NodeId) -> Int
    func childId(_ node: NodeId, at index: Int) -> NodeId
    func style(_ node: NodeId) -> TaffyStyle
    func unroundedLayout(_ node: NodeId) -> Layout
    func setUnroundedLayout(_ node: NodeId, _ layout: Layout)
    func setFinalLayout(_ node: NodeId, _ layout: Layout)
    func cacheClear(_ node: NodeId)
    func cacheGet(_ node: NodeId, _ input: LayoutInput) -> LayoutOutput?
    func cacheStore(_ node: NodeId, _ input: LayoutInput, _ output: LayoutOutput)
    func measureLeafNode(_ node: NodeId, _ input: LayoutInput) -> LayoutOutput
}

// MARK: - Block Context for Margin Collapsing

internal struct BlockContext {
    var margin: CollapsibleMarginSet = .zero
}

extension LayoutTree {
    /// Visit parents before their children, carrying the parent's result down each branch.
    func visitSubtree<Context>(_ root: NodeId, inheriting initial: Context, _ visit: (NodeId, Context) -> Context) {
        var pending = [(root, initial)]
        while let (node, inherited) = pending.popLast() {
            let context = visit(node, inherited)
            for index in (0..<childCount(node)).reversed() {
                pending.append((childId(node, at: index), context))
            }
        }
    }
}

// MARK: - Core Layout Dispatch

extension Rect where T == LengthPercentageAuto {
    func relativeOffset(in parent: Size<Float?>, rtl: Bool) -> Point<Float> {
        let fromLeft = left.maybeResolve(parent.width)
        let fromRight = right.maybeResolve(parent.width).map { -$0 }
        return Point(x: (rtl ? fromRight ?? fromLeft : fromLeft ?? fromRight) ?? 0,
                     y: top.maybeResolve(parent.height) ?? -bottom.resolveOrZero(parent.height))
    }
}

internal func computeRootLayout(
    tree: any LayoutTree,
    root: NodeId,
    availableSpace: Size<AvailableSpace>
) {
    let rootStyle = tree.style(root)
    let parentSize = availableSpace.intoOptions()

    let padding = rootStyle.resolvedPadding(parentWidth: parentSize.width)
    let border = rootStyle.resolvedBorder(parentWidth: parentSize.width)
    let margin = rootStyle.resolvedMarginOrZero(parentWidth: parentSize.width)
    let pbSum = padding.sumAxes + border.sumAxes
    let adj = rootStyle.contentBoxAdjustment(paddingBorderSum: pbSum)

    let styleSize = rootStyle.size
    let minSize = rootStyle.minSize
    let maxSize = rootStyle.maxSize

    let resolvedMinW = minSize.width.maybeResolve(parentSize.width).map { $0 + adj.width }
    let resolvedMaxW = maxSize.width.maybeResolve(parentSize.width).map { $0 + adj.width }
    let resolvedMinH = minSize.height.maybeResolve(parentSize.height).map { $0 + adj.height }
    let resolvedMaxH = maxSize.height.maybeResolve(parentSize.height).map { $0 + adj.height }

    var knownW = styleSize.width.maybeResolve(parentSize.width).map {
        maybeClamp($0 + adj.width, min: resolvedMinW, max: resolvedMaxW)
    }
    var knownH = styleSize.height.maybeResolve(parentSize.height).map {
        maybeClamp($0 + adj.height, min: resolvedMinH, max: resolvedMaxH)
    }

    // Apply aspect ratio on root if one dimension is known
    let withRatio = applyAspectRatio(Size(width: knownW, height: knownH), rootStyle.aspectRatio)
    knownW = withRatio.width
    knownH = withRatio.height

    let input = LayoutInput(
        runMode: .performLayout,
        sizingMode: .inherentSize,
        axis: .both,
        knownDimensions: Size(width: knownW, height: knownH),
        knownDimensionsAreDefinite: .true,
        parentSize: parentSize,
        availableSpace: Size(width: availableSpace.width.maybeSub(margin.horizontalSum).maybeMax(0),
                             height: availableSpace.height.maybeSub(margin.verticalSum).maybeMax(0)),
        verticalMarginsAreCollapsible: .false
    )

    let output = computeNodeLayout(tree: tree, node: root, input: input)

    // The initial containing block positions the root's margin box from its inline-start edge.
    let rtl = rootStyle.direction == .rtl
    var location = Point(x: margin.left, y: margin.top)
    if rtl, let width = parentSize.width { location.x = width - output.size.width - margin.right }
    if rootStyle.position == .relative {
        let offset = rootStyle.inset.relativeOffset(in: parentSize, rtl: rtl)
        location.x += offset.x
        location.y += offset.y
    }
    let rootLayout = Layout(
        order: 0,
        location: location,
        size: output.size,
        contentSize: output.contentSize,
        scrollbarSize: .zero,
        border: border,
        padding: padding,
        margin: margin
    )
    tree.setUnroundedLayout(root, rootLayout)
}

internal func computeHiddenLayout(tree: any LayoutTree, node: NodeId) -> LayoutOutput {
    tree.visitSubtree(node, inheriting: ()) { child, _ in
        tree.cacheClear(child)
        tree.setUnroundedLayout(child, .zero)
    }
    return .hidden
}

internal func computeNodeLayout(
    tree: any LayoutTree,
    node: NodeId,
    input: LayoutInput,
    blockContext: UnsafeMutablePointer<BlockContext>? = nil
) -> LayoutOutput {
    if input.runMode == .performHiddenLayout {
        return computeHiddenLayout(tree: tree, node: node)
    }

    if let cached = tree.cacheGet(node, input) {
        return cached
    }

    let style = tree.style(node)
    let hasChildren = tree.childCount(node) > 0

    let output: LayoutOutput
    switch (style.display, hasChildren) {
    case (.none, _):
        let hidden = computeHiddenLayout(tree: tree, node: node)
        tree.cacheStore(node, input, hidden)
        return hidden
    case (.block, true), (.flowRoot, true), (.flex, true), (.grid, true):
        let previousDepth = tree.containerDepth
        let nextDepth = previousDepth + 1
        output = maybeGrowContainerStack(depth: nextDepth) { grew in
            tree.containerDepth = grew ? 1 : nextDepth
            defer { tree.containerDepth = previousDepth }
            var out: LayoutOutput
            switch style.display {
            case .block:
                out = computeBlockLayout(tree: tree, node: node, input: input, blockContext: blockContext)
            case .flowRoot:
                out = computeBlockLayout(tree: tree, node: node, input: input, blockContext: nil)
            case .flex:
                out = computeFlexboxLayout(tree: tree, node: node, input: input)
            case .grid:
                out = computeGridLayout(tree: tree, node: node, input: input)
            case .none:
                out = .hidden
            }
            if input.runMode == .performLayout {
                computeOutOfFlowLayout(tree: tree, node: node, containerOutput: &out)
            }
            return out
        }
    case (_, false):
        output = computeLeafLayout(tree: tree, node: node, input: input)
    }

    tree.cacheStore(node, input, output)
    return output
}

// MARK: - Leaf Layout

internal func computeLeafLayout(
    tree: any LayoutTree,
    node: NodeId,
    input: LayoutInput
) -> LayoutOutput {
    let style = tree.style(node)
    let parentSize = input.parentSize
    let padding = style.resolvedPadding(parentWidth: parentSize.width)
    let border = style.resolvedBorder(parentWidth: parentSize.width)
    let pbSum = padding.sumAxes + border.sumAxes
    let adj = style.contentBoxAdjustment(paddingBorderSum: pbSum)

    // Scrollbar reservation if scroll overflow
    let scrollbarSize = Size<Float>(
        width: style.overflow.y == .scroll ? style.scrollbarWidth : 0,
        height: style.overflow.x == .scroll ? style.scrollbarWidth : 0
    )

    // A content-size query measures the leaf's contribution before the parent
    // applies its size constraints. Parent-supplied dimensions still apply.
    let inherent = input.sizingMode == .inherentSize
    let resolvedMin = inherent ? style.resolveMinSize(parent: parentSize, adjustment: adj) : .none
    let resolvedMax = inherent ? style.resolveMaxSize(parent: parentSize, adjustment: adj) : .none
    let aspectRatio = inherent ? style.aspectRatio : nil

    var known = input.knownDimensions
    if inherent {
        if known.width == nil {
            known.width = style.size.width.maybeResolve(parentSize.width).map { $0 + adj.width }
        }
        if known.height == nil {
            known.height = style.size.height.maybeResolve(parentSize.height).map { $0 + adj.height }
        }
    }

    // Clamp known dimensions
    if let w = known.width {
        known.width = maybeClamp(w, min: resolvedMin.width, max: resolvedMax.width)
    }
    if let h = known.height {
        known.height = maybeClamp(h, min: resolvedMin.height, max: resolvedMax.height)
    }

    // Apply aspect ratio
    known = applyAspectRatio(known, aspectRatio)

    let margin = style.resolvedMarginOrZero(parentWidth: parentSize.width)
    let topMargin = input.verticalMarginsAreCollapsible.start ? CollapsibleMarginSet.fromMargin(margin.top) : .zero
    let bottomMargin = input.verticalMarginsAreCollapsible.end ? CollapsibleMarginSet.fromMargin(margin.bottom) : .zero

    // The real layout pass still needs intrinsic content and the measured text baseline.
    if input.runMode == .computeSize, let w = known.width, let h = known.height {
        let clampedSize = Size(
            width: maybeClamp(Swift.max(w, pbSum.width + scrollbarSize.width), min: resolvedMin.width, max: resolvedMax.width),
            height: maybeClamp(Swift.max(h, pbSum.height + scrollbarSize.height), min: resolvedMin.height, max: resolvedMax.height)
        )
        return LayoutOutput(
            size: clampedSize,
            contentSize: clampedSize,
            firstBaselines: Point(x: nil, y: nil),
            topMargin: topMargin,
            bottomMargin: bottomMargin,
            marginsCanCollapseThrough: clampedSize.height == 0 && padding.top == 0 && padding.bottom == 0 && border.top == 0 && border.bottom == 0
        )
    }

    // Subtract padding/border/scrollbar from available space for leaf measurement
    let avail = Size(
        width: input.availableSpace.width.maybeSet(known.width).maybeSub(pbSum.width + scrollbarSize.width).mapDefiniteValue { Swift.max(0, $0) },
        height: input.availableSpace.height.maybeSet(known.height).maybeSub(pbSum.height + scrollbarSize.height).mapDefiniteValue { Swift.max(0, $0) }
    )
    let contentKnown = Size(
        width: known.width.map { Swift.max(0, $0 - pbSum.width - scrollbarSize.width) },
        height: known.height.map { Swift.max(0, $0 - pbSum.height - scrollbarSize.height) }
    )

    let measureInput = LayoutInput(
        runMode: input.runMode,
        sizingMode: input.sizingMode,
        axis: input.axis,
        knownDimensions: contentKnown,
        knownDimensionsAreDefinite: input.knownDimensionsAreDefinite,
        parentSize: parentSize,
        availableSpace: avail,
        verticalMarginsAreCollapsible: input.verticalMarginsAreCollapsible
    )

    let measured = tree.measureLeafNode(node, measureInput)
    let measuredTotal = Size(
        width: measured.size.width + pbSum.width + scrollbarSize.width,
        height: measured.size.height + pbSum.height + scrollbarSize.height
    )

    let size = Size(
        width: maybeClamp(Swift.max(known.width ?? measuredTotal.width, pbSum.width), min: resolvedMin.width, max: resolvedMax.width),
        height: maybeClamp(Swift.max(known.height ?? measuredTotal.height, pbSum.height), min: resolvedMin.height, max: resolvedMax.height)
    )
    let canCollapseThrough = size.height == 0 && padding.top == 0 && padding.bottom == 0 && border.top == 0 && border.bottom == 0 && measured.size.height == 0

    return LayoutOutput(
        size: size,
        contentSize: measuredTotal,
        firstBaselines: measured.firstBaselines,
        lastBaselines: measured.lastBaselines,
        scrollOverflowOrigin: measured.scrollOverflowOrigin,
        topMargin: topMargin,
        bottomMargin: bottomMargin,
        marginsCanCollapseThrough: canCollapseThrough
    )
}

// MARK: - Size<Float> + Operator

@inlinable
internal func + (lhs: Size<Float>, rhs: Size<Float>) -> Size<Float> {
    Size(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
}

@inlinable
internal func - (lhs: Size<Float>, rhs: Size<Float>) -> Size<Float> {
    Size(width: lhs.width - rhs.width, height: lhs.height - rhs.height)
}
