// MARK: - CSS Block Layout Algorithm

private struct BlockItem {
    var node: NodeId
    var order: UInt32
    var style: TaffyStyle
    var size: Size<Float?>
    var minSize: Size<Float?>
    var maxSize: Size<Float?>
    var padding: Rect<Float>
    var border: Rect<Float>
    var margin: Rect<Float?>
    var marginTopSet: CollapsibleMarginSet = .zero
    var marginBottomSet: CollapsibleMarginSet = .zero
    var canCollapseThrough: Bool = false
    var computedSize: Size<Float> = .zero
    var contentSize: Size<Float> = .zero
    var scrollOverflowOrigin: Point<Float> = .zero
    var firstBaselineY: Float? = nil
    var yPosition: Float = 0
}

internal func computeBlockLayout(
    tree: any LayoutTree,
    node: NodeId,
    input: LayoutInput,
    blockContext: UnsafeMutablePointer<BlockContext>?
) -> LayoutOutput {
    let style = tree.style(node)
    let parentSize = input.parentSize
    let padding = style.resolvedPadding(parentWidth: parentSize.width)
    let border = style.resolvedBorder(parentWidth: parentSize.width)
    let pbSum = padding.sumAxes + border.sumAxes
    let adj = style.contentBoxAdjustment(paddingBorderSum: pbSum)

    let scrollbarSize = Size<Float>(
        width: style.overflow.y == .scroll ? style.scrollbarWidth : 0,
        height: style.overflow.x == .scroll ? style.scrollbarWidth : 0
    )

    let minSize = style.resolveMinSize(parent: parentSize, adjustment: adj)
    let maxSize = style.resolveMaxSize(parent: parentSize, adjustment: adj)

    let styleSize: Size<Float?>
    if input.sizingMode == .inherentSize {
        styleSize = style.resolveSize(parent: parentSize, adjustment: adj)
    } else {
        styleSize = .none
    }

    let clampedStyleW = styleSize.width.map { maybeClamp($0, min: minSize.width, max: maxSize.width) }
    let clampedStyleH = styleSize.height.map { maybeClamp($0, min: minSize.height, max: maxSize.height) }

    var known = Size(
        width: input.knownDimensions.width ?? clampedStyleW,
        height: input.knownDimensions.height ?? clampedStyleH
    )
    known = applyAspectRatio(known, style.aspectRatio)

    // If ComputeSize and requested dimension(s) are already known, return early (taffy 0.15 block.rs:435-446)
    if input.runMode == .computeSize {
        if let w = known.width, let h = known.height {
            let clamped = Size(
                width: maybeClamp(Swift.max(w, pbSum.width + scrollbarSize.width), min: minSize.width, max: maxSize.width),
                height: maybeClamp(Swift.max(h, pbSum.height + scrollbarSize.height), min: minSize.height, max: maxSize.height)
            )
            let ownMargin = style.resolvedMarginOrZero(parentWidth: parentSize.width)
            return LayoutOutput(
                size: clamped,
                contentSize: clamped,
                firstBaselines: Point(x: nil, y: nil),
                topMargin: input.verticalMarginsAreCollapsible.start ? .fromMargin(ownMargin.top) : .zero,
                bottomMargin: input.verticalMarginsAreCollapsible.end ? .fromMargin(ownMargin.bottom) : .zero,
                marginsCanCollapseThrough: clamped.height == 0 && pbSum.height == 0
            )
        }
        if input.axis == .horizontal, let w = known.width {
            let clampedW = maybeClamp(Swift.max(w, pbSum.width + scrollbarSize.width), min: minSize.width, max: maxSize.width)
            return LayoutOutput.fromOuterSize(Size(width: clampedW, height: 0))
        }
    }

    let contentBoxInset = Rect(
        left: padding.left + border.left,
        right: padding.right + border.right + scrollbarSize.width,
        top: padding.top + border.top,
        bottom: padding.bottom + border.bottom + scrollbarSize.height
    )
    let innerGapW = contentBoxInset.horizontalSum
    let innerGapH = contentBoxInset.verticalSum

    let innerAvailW = input.availableSpace.width
        .maybeSet(known.width)
        .maybeSub(innerGapW)
        .mapDefiniteValue { Swift.max(0, $0) }
    let innerAvailH = input.availableSpace.height
        .maybeSet(known.height)
        .maybeSub(innerGapH)
        .mapDefiniteValue { Swift.max(0, $0) }

    let innerParentSize = Size<Float?>(
        width: known.width.map { Swift.max(0, $0 - innerGapW) },
        height: known.height.map { Swift.max(0, $0 - innerGapH) }
    )

    // Determine container's content width if not yet known
    let childCount = tree.childCount(node)
    var items: [BlockItem] = []
    items.reserveCapacity(childCount)
    var orderCounter: UInt32 = 0

    for i in 0..<childCount {
        let child = tree.childId(node, at: i)
        let cStyle = tree.style(child)
        if cStyle.display == .none {
            _ = computeHiddenLayout(tree: tree, node: child)
            continue
        }
        if cStyle.isOutOfFlow {
            orderCounter += 1
            continue
        }
        let cPad = cStyle.resolvedPadding(parentWidth: innerParentSize.width)
        let cBorder = cStyle.resolvedBorder(parentWidth: innerParentSize.width)
        let cPb = cPad.sumAxes + cBorder.sumAxes
        let cAdj = cStyle.contentBoxAdjustment(paddingBorderSum: cPb)

        let cSize = cStyle.resolveSize(parent: innerParentSize, adjustment: cAdj)
        let cMin = cStyle.resolveMinSize(parent: innerParentSize, adjustment: cAdj)
        let cMax = cStyle.resolveMaxSize(parent: innerParentSize, adjustment: cAdj)
        let cMargin = cStyle.resolvedMargin(parentWidth: innerParentSize.width)

        items.append(BlockItem(
            node: child,
            order: orderCounter,
            style: cStyle,
            size: cSize,
            minSize: cMin,
            maxSize: cMax,
            padding: cPad,
            border: cBorder,
            margin: cMargin
        ))
        orderCounter += 1
    }

    // 1. Determine container inner width
    var containerInnerW: Float
    if let kw = known.width {
        containerInnerW = Swift.max(0, kw - innerGapW)
    } else {
        var maxChildOuterW: Float = 0
        for idx in items.indices {
            let item = items[idx]
            let mL = item.margin.left ?? 0
            let mR = item.margin.right ?? 0
            let itemAvailW = innerAvailW.maybeSub(mL + mR).mapDefiniteValue { Swift.max(0, $0) }
            let itemKnownW = item.size.width.map { maybeClamp($0, min: item.minSize.width, max: item.maxSize.width) }
            let out = computeNodeLayout(
                tree: tree,
                node: item.node,
                input: LayoutInput(
                    runMode: .computeSize,
                    sizingMode: .inherentSize,
                    axis: .horizontal,
                    knownDimensions: Size(width: itemKnownW, height: item.size.height),
                    parentSize: innerParentSize,
                    availableSpace: Size(width: itemAvailW, height: innerAvailH),
                    verticalMarginsAreCollapsible: Line(start: true, end: true)
                )
            )
            let clampedW = maybeClamp(out.size.width, min: item.minSize.width, max: item.maxSize.width)
            maxChildOuterW = Swift.max(maxChildOuterW, clampedW + mL + mR)
        }
        let rawW = maxChildOuterW + innerGapW
        let clampedOuterW = maybeClamp(rawW, min: minSize.width, max: maxSize.width)
        containerInnerW = Swift.max(0, clampedOuterW - innerGapW)
    }

    // Short-circuit if computing size and only width (or both dimensions) is now known (taffy 0.15 block.rs:605-612).
    if input.runMode == .computeSize {
        let containerOuterW = maybeClamp(known.width ?? (containerInnerW + innerGapW), min: minSize.width, max: maxSize.width)
        if let h = known.height {
            let containerOuterH = maybeClamp(Swift.max(h, pbSum.height + scrollbarSize.height), min: minSize.height, max: maxSize.height)
            return LayoutOutput.fromOuterSize(Size(width: containerOuterW, height: containerOuterH))
        }
        if input.axis == .horizontal {
            return LayoutOutput.fromOuterSize(Size(width: containerOuterW, height: 0))
        }
    }

    let finalParentSize = Size<Float?>(width: containerInnerW, height: innerParentSize.height)

    // 2. Measure / layout each child vertically and perform margin collapsing
    var currentY: Float = contentBoxInset.top
    var activeMarginSet = CollapsibleMarginSet.zero
    var isFirstNonCollapsed = true
    var firstChildTopMargin = CollapsibleMarginSet.zero
    var lastChildBottomMargin = CollapsibleMarginSet.zero
    var allChildrenCollapsedThrough = true
    var contentMinX: Float = 0
    var contentMinY: Float = 0
    var contentMaxX: Float = contentBoxInset.left
    var firstBaselineY: Float? = nil

    let canCollapseTopWithFirstChild = style.display == .block
        && padding.top == 0
        && border.top == 0
        && style.overflow.y == .visible
        && known.height == nil
    let canCollapseBottomWithLastChild = style.display == .block
        && padding.bottom == 0
        && border.bottom == 0
        && style.overflow.y == .visible
        && style.size.height == .auto

    for idx in items.indices {
        var item = items[idx]
        let cPad = item.style.resolvedPadding(parentWidth: containerInnerW)
        let cBorder = item.style.resolvedBorder(parentWidth: containerInnerW)
        let cPb = cPad.sumAxes + cBorder.sumAxes
        let cAdj = item.style.contentBoxAdjustment(paddingBorderSum: cPb)
        let cMargin = item.style.resolvedMargin(parentWidth: containerInnerW)

        let mL = cMargin.left ?? 0
        let mR = cMargin.right ?? 0
        let itemAvailW = Swift.max(0, containerInnerW - mL - mR)

        let resolvedMinW = item.style.minSize.width.maybeResolve(containerInnerW).map { $0 + cAdj.width }
        let resolvedMaxW = item.style.maxSize.width.maybeResolve(containerInnerW).map { $0 + cAdj.width }
        let resolvedMinH = item.style.minSize.height.maybeResolve(finalParentSize.height).map { $0 + cAdj.height }
        let resolvedMaxH = item.style.maxSize.height.maybeResolve(finalParentSize.height).map { $0 + cAdj.height }

        let styleW = item.style.size.width.maybeResolve(containerInnerW).map { $0 + cAdj.width }
        let styleH = item.style.size.height.maybeResolve(finalParentSize.height).map { $0 + cAdj.height }

        // Block-level non-replaced elements with auto width stretch to fill containerInnerW
        var targetW: Float? = styleW
        if targetW == nil && !item.style.itemIsTable && !item.style.itemIsReplaced {
            targetW = itemAvailW
        }
        targetW = targetW.map { maybeClamp($0, min: resolvedMinW, max: resolvedMaxW) }
        var targetH: Float? = styleH.map { maybeClamp($0, min: resolvedMinH, max: resolvedMaxH) }

        let ratioed = applyAspectRatio(Size(width: targetW, height: targetH), item.style.aspectRatio)
        targetW = ratioed.width
        targetH = ratioed.height

        let childOut = computeNodeLayout(
            tree: tree,
            node: item.node,
            input: LayoutInput(
                runMode: input.runMode,
                sizingMode: .inherentSize,
                axis: .both,
                knownDimensions: Size(width: targetW, height: targetH),
                parentSize: finalParentSize,
                availableSpace: Size(width: .definite(itemAvailW), height: innerAvailH),
                verticalMarginsAreCollapsible: Line(start: true, end: true)
            )
        )

        let finalW = maybeClamp(targetW ?? childOut.size.width, min: resolvedMinW, max: resolvedMaxW)
        let finalH = maybeClamp(targetH ?? childOut.size.height, min: resolvedMinH, max: resolvedMaxH)

        item.padding = cPad
        item.border = cBorder
        item.margin = cMargin
        item.computedSize = Size(width: finalW, height: finalH)
        item.contentSize = childOut.contentSize
        item.scrollOverflowOrigin = childOut.scrollOverflowOrigin
        item.firstBaselineY = childOut.firstBaselines.y
        item.marginTopSet = childOut.topMargin
        item.marginBottomSet = childOut.bottomMargin
        item.canCollapseThrough = childOut.marginsCanCollapseThrough

        if isFirstNonCollapsed {
            firstChildTopMargin = item.marginTopSet
        }

        if item.canCollapseThrough {
            activeMarginSet = activeMarginSet.collapseWithSet(item.marginTopSet).collapseWithSet(item.marginBottomSet)
            item.yPosition = currentY + activeMarginSet.resolve()
        } else {
            let collapsed = activeMarginSet.collapseWithSet(item.marginTopSet)
            if isFirstNonCollapsed && canCollapseTopWithFirstChild && blockContext != nil {
                // Top margin escapes to parent
            } else {
                currentY += collapsed.resolve()
            }
            item.yPosition = currentY
            currentY += finalH
            activeMarginSet = item.marginBottomSet
            isFirstNonCollapsed = false
            allChildrenCollapsedThrough = false
        }

        lastChildBottomMargin = item.marginBottomSet
        items[idx] = item
    }

    if !(canCollapseBottomWithLastChild && blockContext != nil) && !allChildrenCollapsedThrough {
        currentY += activeMarginSet.resolve()
    }

    let contentBottom = currentY
    let totalContentHeight = contentBottom - contentBoxInset.top
    let naturalOuterW = containerInnerW + innerGapW
    let naturalOuterH = totalContentHeight + innerGapH

    let finalOuterW = maybeClamp(known.width ?? naturalOuterW, min: minSize.width, max: maxSize.width)
    let finalOuterH = maybeClamp(known.height ?? naturalOuterH, min: minSize.height, max: maxSize.height)

    // 3. Position children if RunMode == .performLayout
    if input.runMode == .performLayout {
        for item in items {
            let mTop = item.margin.top ?? 0
            let mBottom = item.margin.bottom ?? 0
            let resolvedML: Float
            let resolvedMR: Float
            let freeX = containerInnerW - item.computedSize.width
            switch (item.margin.left, item.margin.right) {
            case (nil, nil):
                let half = Swift.max(0, freeX) * 0.5
                resolvedML = half
                resolvedMR = half
            case (nil, let r?):
                resolvedML = Swift.max(0, freeX - r)
                resolvedMR = r
            case (let l?, nil):
                resolvedML = l
                resolvedMR = Swift.max(0, freeX - l)
            case (let l?, let r?):
                resolvedML = l
                resolvedMR = r
            }

            var x = contentBoxInset.left + resolvedML
            var y = item.yPosition

            if item.style.position == .relative {
                if let l = item.style.inset.left.maybeResolve(containerInnerW) {
                    x += l
                } else if let r = item.style.inset.right.maybeResolve(containerInnerW) {
                    x -= r
                }
                if let t = item.style.inset.top.maybeResolve(finalOuterH - innerGapH) {
                    y += t
                } else if let b = item.style.inset.bottom.maybeResolve(finalOuterH - innerGapH) {
                    y -= b
                }
            }

            contentMinX = Swift.min(contentMinX, x)
            contentMinY = Swift.min(contentMinY, y)
            if item.scrollOverflowOrigin != .zero {
                if item.style.overflow.x == .visible {
                    contentMinX = Swift.min(contentMinX, x + item.scrollOverflowOrigin.x)
                }
                if item.style.overflow.y == .visible {
                    contentMinY = Swift.min(contentMinY, y + item.scrollOverflowOrigin.y)
                }
            }
            contentMaxX = Swift.max(contentMaxX, x + item.computedSize.width)
            if firstBaselineY == nil {
                firstBaselineY = y + (item.firstBaselineY ?? item.computedSize.height)
            }

            tree.setUnroundedLayout(item.node, Layout(
                order: item.order,
                location: Point(x: x, y: y),
                size: item.computedSize,
                contentSize: item.contentSize,
                scrollbarSize: .zero,
                border: item.border,
                padding: item.padding,
                margin: Rect(left: resolvedML, right: resolvedMR, top: mTop, bottom: mBottom)
            ))
        }
    }

    let ownMargin = style.resolvedMarginOrZero(parentWidth: parentSize.width)
    var outTopMargin = input.verticalMarginsAreCollapsible.start ? CollapsibleMarginSet.fromMargin(ownMargin.top) : .zero
    var outBottomMargin = input.verticalMarginsAreCollapsible.end ? CollapsibleMarginSet.fromMargin(ownMargin.bottom) : .zero

    if canCollapseTopWithFirstChild && input.verticalMarginsAreCollapsible.start {
        outTopMargin = outTopMargin.collapseWithSet(firstChildTopMargin)
    }
    if canCollapseBottomWithLastChild && input.verticalMarginsAreCollapsible.end {
        outBottomMargin = outBottomMargin.collapseWithSet(lastChildBottomMargin)
    }

    let finalContentSize = Size(
        width: Swift.max(finalOuterW, contentMaxX + contentBoxInset.right),
        height: Swift.max(finalOuterH, contentBottom + contentBoxInset.bottom)
    )

    return LayoutOutput(
        size: Size(width: finalOuterW, height: finalOuterH),
        contentSize: finalContentSize,
        firstBaselines: Point(x: nil, y: firstBaselineY),
        scrollOverflowOrigin: Point(x: contentMinX, y: contentMinY),
        topMargin: outTopMargin,
        bottomMargin: outBottomMargin,
        marginsCanCollapseThrough: allChildrenCollapsedThrough && pbSum.height == 0 && known.height == nil
    )
}
