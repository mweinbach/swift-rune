// MARK: - Out-of-Flow (Absolute / Fixed) Positioning

/// Positions all `position: .absolute` / `.fixed` children of `node` relative to `node`'s padding box.
internal func computeOutOfFlowLayout<Tree: LayoutTree>(
    tree: Tree,
    node: NodeId,
    parentStyle: TaffyStyle,
    containerOutput: inout LayoutOutput
) {
    let containerSize = containerOutput.size
    let parentBorder = parentStyle.resolvedBorder(parentWidth: containerSize.width)
    let parentPadding = parentStyle.resolvedPadding(parentWidth: containerSize.width)

    let cbWidth = Swift.max(0, containerSize.width - parentBorder.horizontalSum)
    let cbHeight = Swift.max(0, containerSize.height - parentBorder.verticalSum)
    let cbSize = Size<Float?>(width: cbWidth, height: cbHeight)

    let count = tree.childCount(node)
    var orderCounter: UInt32 = 0

    for i in 0..<count {
        let child = tree.childId(node, at: i)
        let childStyle = tree.style(child)

        if childStyle.display == .none {
            continue
        }

        if !childStyle.isOutOfFlow {
            orderCounter += 1
            continue
        }

        let padding = childStyle.resolvedPadding(parentWidth: cbWidth)
        let border = childStyle.resolvedBorder(parentWidth: cbWidth)
        let pbSum = padding.sumAxes + border.sumAxes
        let adj = childStyle.contentBoxAdjustment(paddingBorderSum: pbSum)

        let insetLeft = childStyle.inset.left.maybeResolve(cbWidth)
        let insetRight = childStyle.inset.right.maybeResolve(cbWidth)
        let insetTop = childStyle.inset.top.maybeResolve(cbHeight)
        let insetBottom = childStyle.inset.bottom.maybeResolve(cbHeight)

        let minW = childStyle.minSize.width.maybeResolve(cbWidth).map { $0 + adj.width }
        let maxW = childStyle.maxSize.width.maybeResolve(cbWidth).map { $0 + adj.width }
        let minH = childStyle.minSize.height.maybeResolve(cbHeight).map { $0 + adj.height }
        let maxH = childStyle.maxSize.height.maybeResolve(cbHeight).map { $0 + adj.height }

        let styleW = childStyle.size.width.maybeResolve(cbWidth).map { $0 + adj.width }
        let styleH = childStyle.size.height.maybeResolve(cbHeight).map { $0 + adj.height }

        let marginLeft = childStyle.margin.left.maybeResolve(cbWidth)
        let marginRight = childStyle.margin.right.maybeResolve(cbWidth)
        let marginTop = childStyle.margin.top.maybeResolve(cbHeight)
        let marginBottom = childStyle.margin.bottom.maybeResolve(cbHeight)

        // Known width from style or opposite insets (when margin is not auto)
        var knownW: Float? = styleW.map { maybeClamp($0, min: minW, max: maxW) }
        if knownW == nil, let l = insetLeft, let r = insetRight {
            let mSum = (marginLeft ?? 0) + (marginRight ?? 0)
            knownW = maybeClamp(Swift.max(0, cbWidth - l - r - mSum), min: minW, max: maxW)
        }

        var knownH: Float? = styleH.map { maybeClamp($0, min: minH, max: maxH) }
        if knownH == nil, let t = insetTop, let b = insetBottom {
            let mSum = (marginTop ?? 0) + (marginBottom ?? 0)
            knownH = maybeClamp(Swift.max(0, cbHeight - t - b - mSum), min: minH, max: maxH)
        }

        let withRatio = applyAspectRatio(Size(width: knownW, height: knownH), childStyle.aspectRatio)
        knownW = withRatio.width
        knownH = withRatio.height

        let measuredW: Float
        let measuredH: Float
        if let kw = knownW, let kh = knownH {
            measuredW = kw
            measuredH = kh
        } else {
            let measureInput = LayoutInput(
                runMode: .computeSize,
                sizingMode: .contentSize,
                axis: .both,
                knownDimensions: Size(width: knownW, height: knownH),
                parentSize: cbSize,
                availableSpace: Size(
                    width: .definite(knownW ?? cbWidth),
                    height: .definite(knownH ?? cbHeight)
                ),
                verticalMarginsAreCollapsible: .false
            )
            let measured = computeNodeLayout(tree: tree, node: child, input: measureInput)
            measuredW = knownW ?? measured.size.width
            measuredH = knownH ?? measured.size.height
        }
        let finalW = maybeClamp(measuredW, min: minW, max: maxW)
        let finalH = maybeClamp(measuredH, min: minH, max: maxH)

        let childInput = LayoutInput(
            runMode: .performLayout,
            sizingMode: .contentSize,
            axis: .both,
            knownDimensions: Size(width: finalW, height: finalH),
            parentSize: cbSize,
            availableSpace: Size(
                width: .definite(knownW ?? cbWidth),
                height: .definite(knownH ?? cbHeight)
            ),
            verticalMarginsAreCollapsible: .false
        )
        let childOutput = computeNodeLayout(tree: tree, node: child, input: childInput)

        // Horizontal position & auto margin resolution
        let (x, resolvedML, resolvedMR) = resolveAbsoluteAxis(
            insetStart: insetLeft,
            insetEnd: insetRight,
            marginStart: marginLeft,
            marginEnd: marginRight,
            childSize: finalW,
            containingSize: cbWidth,
            borderStart: parentBorder.left,
            paddingStart: parentPadding.left,
            alignFallback: parentStyle.alignItems ?? .normal,
            alignSelf: childStyle.alignSelf,
            justifyItems: parentStyle.justifyItems,
            justifySelf: childStyle.justifySelf,
            isHorizontal: true,
            parentDisplay: parentStyle.display,
            flexDirection: parentStyle.flexDirection,
            justifyContent: parentStyle.justifyContent ?? .normal
        )

        let (y, resolvedMT, resolvedMB) = resolveAbsoluteAxis(
            insetStart: insetTop,
            insetEnd: insetBottom,
            marginStart: marginTop,
            marginEnd: marginBottom,
            childSize: finalH,
            containingSize: cbHeight,
            borderStart: parentBorder.top,
            paddingStart: parentPadding.top,
            alignFallback: parentStyle.alignItems ?? .normal,
            alignSelf: childStyle.alignSelf,
            justifyItems: parentStyle.justifyItems,
            justifySelf: childStyle.justifySelf,
            isHorizontal: false,
            parentDisplay: parentStyle.display,
            flexDirection: parentStyle.flexDirection,
            justifyContent: parentStyle.justifyContent ?? .normal
        )

        let childLayout = Layout(
            order: orderCounter,
            location: Point(x: x, y: y),
            size: Size(width: finalW, height: finalH),
            contentSize: childOutput.contentSize,
            scrollbarSize: .zero,
            border: border,
            padding: padding,
            margin: Rect(left: resolvedML, right: resolvedMR, top: resolvedMT, bottom: resolvedMB)
        )
        tree.setUnroundedLayout(child, childLayout)
        orderCounter += 1
    }
}

private func resolveAbsoluteAxis(
    insetStart: Float?,
    insetEnd: Float?,
    marginStart: Float?,
    marginEnd: Float?,
    childSize: Float,
    containingSize: Float,
    borderStart: Float,
    paddingStart: Float,
    alignFallback: AlignItems,
    alignSelf: AlignSelf?,
    justifyItems: JustifyItems?,
    justifySelf: JustifySelf?,
    isHorizontal: Bool,
    parentDisplay: Display,
    flexDirection: FlexDirection,
    justifyContent: JustifyContent
) -> (position: Float, marginStart: Float, marginEnd: Float) {
    let mStart = marginStart ?? 0
    let mEnd = marginEnd ?? 0

    switch (insetStart, insetEnd) {
    case (let s?, let e?):
        let freeSpace = containingSize - s - e - childSize
        let actualMStart: Float
        let actualMEnd: Float
        switch (marginStart, marginEnd) {
        case (nil, nil):
            let half = Swift.max(0, freeSpace) * 0.5
            actualMStart = half
            actualMEnd = half
        case (nil, let r?):
            actualMStart = freeSpace - r
            actualMEnd = r
        case (let l?, nil):
            actualMStart = l
            actualMEnd = freeSpace - l
        case (let l?, let r?):
            actualMStart = l
            actualMEnd = r
        }
        return (borderStart + s + actualMStart, actualMStart, actualMEnd)

    case (let s?, nil):
        return (borderStart + s + mStart, mStart, mEnd)

    case (nil, let e?):
        return (borderStart + containingSize - e - childSize - mEnd, mStart, mEnd)

    case (nil, nil):
        // Static position fallback
        var offset = borderStart + paddingStart + mStart
        if parentDisplay == .flex {
            let isMain = (isHorizontal && flexDirection.isRow) || (!isHorizontal && flexDirection.isColumn)
            let contentSize = Swift.max(0, containingSize - paddingStart * 2)
            let free = contentSize - childSize - mStart - mEnd
            if isMain {
                let effectiveJustify: AlignContentKeyword =
                    (justifyContent.safety == .safe && free < 0) ? .start : justifyContent.keyword
                switch effectiveJustify {
                case .center: offset += free * 0.5
                case .flexEnd, .end: offset += free
                default: break
                }
            } else {
                let align = alignSelf ?? alignFallback
                let effectiveAlign: AlignItemsKeyword =
                    (align.safety == .safe && free < 0) ? .start : align.keyword
                switch effectiveAlign {
                case .center: offset += free * 0.5
                case .flexEnd, .end: offset += free
                default: break
                }
            }
        } else if parentDisplay == .grid {
            let contentSize = Swift.max(0, containingSize - paddingStart * 2)
            let free = contentSize - childSize - mStart - mEnd
            let align = isHorizontal ? (justifySelf ?? justifyItems ?? .normal) : (alignSelf ?? alignFallback)
            let effectiveAlign: AlignItemsKeyword =
                (align.safety == .safe && free < 0) ? .start : align.keyword
            switch effectiveAlign {
            case .center: offset += free * 0.5
            case .end, .flexEnd, .selfEnd: offset += free
            default: break
            }
        }
        return (offset, mStart, mEnd)
    }
}
