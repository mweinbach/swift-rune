// MARK: - CSS Flexbox Level 1 Layout Algorithm

private struct FlexItem {
    var node: NodeId
    var order: UInt32

    // Subset of TaffyStyle fields used by flexbox (avoids keeping TaffyStyle copies per item on stack)
    var flexGrow: Float
    var flexShrink: Float
    var flexBasisDim: Dimension
    var aspectRatio: Float?
    var boxSizing: BoxSizing
    var overflowMain: Overflow
    var alignSelf: AlignSelf?
    var position: Position
    var inset: Rect<LengthPercentageAuto>

    var size: Size<Float?>
    var minSize: Size<Float?>
    var maxSize: Size<Float?>
    var padding: Rect<Float>
    var border: Rect<Float>
    var margin: Rect<Float?> // nil = auto
    var marginIsAuto: Rect<Bool>

    var flexBasis: Float = 0
    var innerFlexBasis: Float = 0
    var hypotheticalInnerSize: Size<Float> = .zero
    var hypotheticalOuterSize: Size<Float> = .zero
    var targetSize: Size<Float> = .zero
    var outerTargetSize: Size<Float> = .zero
    var contentSize: Size<Float> = .zero

    var resolvedMinimumMainSize: Float = 0
    var baseline: Float = 0
    var offsetMain: Float = 0
    var offsetCross: Float = 0

    var frozen: Bool = false
    var violation: Float = 0
}

private struct FlexLine {
    var itemRange: Range<Int>
    var crossSize: Float = 0
    var offsetCross: Float = 0
}

private struct FlexContainerContext {
    var dir: FlexDirection
    var isRow: Bool
    var isWrapReverse: Bool
    var flexWrap: FlexWrap
    var alignItems: AlignItems
    var alignContent: AlignContent
    var justifyContent: JustifyContent

    var contentBoxInset: Rect<Float>
    var innerPB: Size<Float>
    var minSize: Size<Float?>
    var maxSize: Size<Float?>
    var known: Size<Float?>
    var availInner: Size<AvailableSpace>
    var nodeInnerSize: Size<Float?>
    var mainGap: Float
    var crossGap: Float
    var earlyReturn: LayoutOutput?
}

internal func computeFlexboxLayout(
    tree: any LayoutTree,
    node: NodeId,
    input: LayoutInput
) -> LayoutOutput {
    let ctx = flexComputeContainerContext(tree: tree, node: node, input: input)
    if let early = ctx.earlyReturn {
        return early
    }

    var items = flexCollectItems(tree: tree, node: node, ctx: ctx)
    flexDetermineBaseSizes(tree: tree, ctx: ctx, items: &items)

    var (lines, resolvedInnerMain) = flexCollectLinesAndMainSize(ctx: ctx, items: items, input: input)
    flexResolveFlexibleLengths(ctx: ctx, lines: lines, items: &items, resolvedInnerMain: resolvedInnerMain)
    flexDetermineCrossSizes(tree: tree, ctx: ctx, items: &items, resolvedInnerMain: resolvedInnerMain)

    let resolvedInnerCross = flexComputeLinesAndAlignContent(ctx: ctx, lines: &lines, items: items)
    let (outerWidth, outerHeight, finalParentSize) = flexStretchAndPositionItems(
        ctx: ctx,
        lines: lines,
        items: &items,
        resolvedInnerMain: resolvedInnerMain,
        resolvedInnerCross: resolvedInnerCross
    )

    return flexFinalizeChildrenAndOutput(
        tree: tree,
        ctx: ctx,
        items: items,
        input: input,
        finalParentSize: finalParentSize,
        outerWidth: outerWidth,
        outerHeight: outerHeight
    )
}

private func flexComputeContainerContext(
    tree: any LayoutTree,
    node: NodeId,
    input: LayoutInput
) -> FlexContainerContext {
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

    let contentBoxInset = Rect(
        left: padding.left + border.left,
        right: padding.right + border.right + scrollbarSize.width,
        top: padding.top + border.top,
        bottom: padding.bottom + border.bottom + scrollbarSize.height
    )

    let minSize = Size(
        width: style.minSize.width.maybeResolve(parentSize.width).map { $0 + adj.width },
        height: style.minSize.height.maybeResolve(parentSize.height).map { $0 + adj.height }
    )
    let maxSize = Size(
        width: style.maxSize.width.maybeResolve(parentSize.width).map { $0 + adj.width },
        height: style.maxSize.height.maybeResolve(parentSize.height).map { $0 + adj.height }
    )

    let styleSize: Size<Float?>
    if input.sizingMode == .inherentSize {
        styleSize = Size(
            width: style.size.width.maybeResolve(parentSize.width).map { $0 + adj.width },
            height: style.size.height.maybeResolve(parentSize.height).map { $0 + adj.height }
        )
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

    let dir = style.flexDirection
    let isRow = dir.isRow
    let innerPB = Size(width: contentBoxInset.horizontalSum, height: contentBoxInset.verticalSum)

    var earlyReturn: LayoutOutput? = nil
    if input.runMode == .computeSize, let w = known.width, let h = known.height {
        let clamped = Size(
            width: maybeClamp(Swift.max(w, pbSum.width + scrollbarSize.width), min: minSize.width, max: maxSize.width),
            height: maybeClamp(Swift.max(h, pbSum.height + scrollbarSize.height), min: minSize.height, max: maxSize.height)
        )
        earlyReturn = LayoutOutput.fromOuterSize(clamped)
    }

    let availOuter = Size(
        width: input.availableSpace.width.maybeSet(known.width),
        height: input.availableSpace.height.maybeSet(known.height)
    )
    let availInner = Size(
        width: availOuter.width.maybeSub(innerPB.width).mapDefiniteValue { Swift.max(0, $0) },
        height: availOuter.height.maybeSub(innerPB.height).mapDefiniteValue { Swift.max(0, $0) }
    )
    let nodeInnerSize = Size<Float?>(
        width: known.width.map { Swift.max(0, $0 - innerPB.width) },
        height: known.height.map { Swift.max(0, $0 - innerPB.height) }
    )
    let mainGap = (isRow ? style.gap.width : style.gap.height).resolveOrZero(nodeInnerSize.main(direction: dir))
    let crossGap = (isRow ? style.gap.height : style.gap.width).resolveOrZero(nodeInnerSize.cross(direction: dir))

    return FlexContainerContext(
        dir: dir,
        isRow: isRow,
        isWrapReverse: style.flexWrap == .wrapReverse,
        flexWrap: style.flexWrap,
        alignItems: style.alignItems ?? .stretch,
        alignContent: style.alignContent ?? .stretch,
        justifyContent: style.justifyContent ?? .flexStart,
        contentBoxInset: contentBoxInset,
        innerPB: innerPB,
        minSize: minSize,
        maxSize: maxSize,
        known: known,
        availInner: availInner,
        nodeInnerSize: nodeInnerSize,
        mainGap: mainGap,
        crossGap: crossGap,
        earlyReturn: earlyReturn
    )
}

private func flexCollectItems(
    tree: any LayoutTree,
    node: NodeId,
    ctx: FlexContainerContext
) -> [FlexItem] {
    let childCount = tree.childCount(node)
    var items: [FlexItem] = []
    items.reserveCapacity(childCount)
    var orderCounter: UInt32 = 0
    let nodeInnerSize = ctx.nodeInnerSize

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

        let cPad = cStyle.resolvedPadding(parentWidth: nodeInnerSize.width)
        let cBorder = cStyle.resolvedBorder(parentWidth: nodeInnerSize.width)
        let cPb = cPad.sumAxes + cBorder.sumAxes
        let cAdj = cStyle.contentBoxAdjustment(paddingBorderSum: cPb)

        let cSize = Size(
            width: cStyle.size.width.maybeResolve(nodeInnerSize.width).map { $0 + cAdj.width },
            height: cStyle.size.height.maybeResolve(nodeInnerSize.height).map { $0 + cAdj.height }
        )
        let cMin = Size(
            width: cStyle.minSize.width.maybeResolve(nodeInnerSize.width).map { $0 + cAdj.width },
            height: cStyle.minSize.height.maybeResolve(nodeInnerSize.height).map { $0 + cAdj.height }
        )
        let cMax = Size(
            width: cStyle.maxSize.width.maybeResolve(nodeInnerSize.width).map { $0 + cAdj.width },
            height: cStyle.maxSize.height.maybeResolve(nodeInnerSize.height).map { $0 + cAdj.height }
        )
        let cMargin = cStyle.resolvedMargin(parentWidth: nodeInnerSize.width)
        let cMarginIsAuto = Rect(
            left: cMargin.left == nil,
            right: cMargin.right == nil,
            top: cMargin.top == nil,
            bottom: cMargin.bottom == nil
        )

        items.append(FlexItem(
            node: child,
            order: orderCounter,
            flexGrow: cStyle.flexGrow,
            flexShrink: cStyle.flexShrink,
            flexBasisDim: cStyle.flexBasis,
            aspectRatio: cStyle.aspectRatio,
            boxSizing: cStyle.boxSizing,
            overflowMain: ctx.isRow ? cStyle.overflow.x : cStyle.overflow.y,
            alignSelf: cStyle.alignSelf,
            position: cStyle.position,
            inset: cStyle.inset,
            size: cSize,
            minSize: cMin,
            maxSize: cMax,
            padding: cPad,
            border: cBorder,
            margin: cMargin,
            marginIsAuto: cMarginIsAuto
        ))
        orderCounter += 1
    }
    return items
}

private func flexDetermineBaseSizes(
    tree: any LayoutTree,
    ctx: FlexContainerContext,
    items: inout [FlexItem]
) {
    for idx in items.indices {
        flexDetermineSingleItemBaseSize(tree: tree, ctx: ctx, item: &items[idx])
    }
}

private func flexDetermineSingleItemBaseSize(
    tree: any LayoutTree,
    ctx: FlexContainerContext,
    item: inout FlexItem
) {
    let dir = ctx.dir
    let isRow = ctx.isRow
    let nodeInnerSize = ctx.nodeInnerSize
    let availInner = ctx.availInner

    let cPb = item.padding.sumAxes + item.border.sumAxes
    let cAdj = item.boxSizing == .contentBox ? cPb : .zero
    let childMainParent = nodeInnerSize.main(direction: dir)
    let resolvedBasis = item.flexBasisDim.maybeResolve(childMainParent).map { $0 + cAdj.main(direction: dir) }

    let basis: Float
    if let rb = resolvedBasis {
        basis = rb
    } else if let sm = item.size.main(direction: dir) {
        basis = sm
    } else if let ratio = item.aspectRatio, ratio > 0, ratio.isFinite,
              let crossSize = item.size.cross(direction: dir) {
        basis = isRow ? (crossSize * ratio) : (crossSize / ratio)
    } else {
        var knownDims = Size<Float?>(width: nil, height: nil)
        knownDims.setCross(item.size.cross(direction: dir), direction: dir)
        let crossMarginSum = (item.margin.crossStart(direction: dir) ?? 0) + (item.margin.crossEnd(direction: dir) ?? 0)
        var childAvail = availInner
        childAvail.setMain(.maxContent, direction: dir)
        childAvail.setCross(
            availInner.cross(direction: dir).maybeSub(crossMarginSum).mapDefiniteValue { Swift.max(0, $0) },
            direction: dir
        )
        let out = computeNodeLayout(
            tree: tree,
            node: item.node,
            input: LayoutInput(
                runMode: .computeSize,
                sizingMode: .contentSize,
                axis: isRow ? .horizontal : .vertical,
                knownDimensions: knownDims,
                parentSize: nodeInnerSize,
                availableSpace: childAvail,
                verticalMarginsAreCollapsible: .false
            )
        )
        basis = out.size.main(direction: dir)
    }

    let resolvedMinMain: Float
    if let explicitMin = item.minSize.main(direction: dir) {
        resolvedMinMain = explicitMin
    } else if item.overflowMain == .visible {
        var knownDims = Size<Float?>(width: nil, height: nil)
        knownDims.setCross(item.size.cross(direction: dir), direction: dir)
        var childAvail = availInner
        childAvail.setMain(.minContent, direction: dir)
        let minOut = computeNodeLayout(
            tree: tree,
            node: item.node,
            input: LayoutInput(
                runMode: .computeSize,
                sizingMode: .contentSize,
                axis: isRow ? .horizontal : .vertical,
                knownDimensions: knownDims,
                parentSize: nodeInnerSize,
                availableSpace: childAvail,
                verticalMarginsAreCollapsible: .false
            )
        )
        let minContentMain = minOut.size.main(direction: dir)
        let clampUpper = maybeMin(item.size.main(direction: dir), item.maxSize.main(direction: dir))
        resolvedMinMain = maybeMin(minContentMain, clampUpper) ?? minContentMain
    } else {
        resolvedMinMain = 0
    }

    let pbMain = item.padding.mainAxisSum(direction: dir) + item.border.mainAxisSum(direction: dir)
    let clampedBasis = Swift.max(basis, pbMain)
    let clampedMinMain = Swift.max(resolvedMinMain, pbMain)
    let hypotheticalMain = maybeClamp(clampedBasis, min: clampedMinMain, max: item.maxSize.main(direction: dir))

    item.flexBasis = clampedBasis
    item.innerFlexBasis = Swift.max(0, clampedBasis - pbMain)
    item.resolvedMinimumMainSize = clampedMinMain

    let marginMainSum = (item.margin.mainStart(direction: dir) ?? 0) + (item.margin.mainEnd(direction: dir) ?? 0)
    item.hypotheticalInnerSize.setMain(hypotheticalMain, direction: dir)
    item.hypotheticalOuterSize.setMain(hypotheticalMain + marginMainSum, direction: dir)

    if let sc = item.size.cross(direction: dir) {
        let clampedCross = maybeClamp(sc, min: item.minSize.cross(direction: dir), max: item.maxSize.cross(direction: dir))
        item.hypotheticalInnerSize.setCross(clampedCross, direction: dir)
        let marginCrossSum = (item.margin.crossStart(direction: dir) ?? 0) + (item.margin.crossEnd(direction: dir) ?? 0)
        item.hypotheticalOuterSize.setCross(clampedCross + marginCrossSum, direction: dir)
    }
}

private func flexCollectLinesAndMainSize(
    ctx: FlexContainerContext,
    items: [FlexItem],
    input: LayoutInput
) -> ([FlexLine], Float) {
    let dir = ctx.dir
    let containerMainMax = ctx.maxSize.main(direction: dir).map { Swift.max(0, $0 - ctx.innerPB.main(direction: dir)) }
    let containerMainMin = ctx.minSize.main(direction: dir).map { Swift.max(0, $0 - ctx.innerPB.main(direction: dir)) }
    let containerMainAvail = ctx.availInner.main(direction: dir)
    let lineBreakMainMax: Float?
    if let nm = ctx.nodeInnerSize.main(direction: dir) {
        lineBreakMainMax = nm
    } else if case .definite(let d) = containerMainAvail {
        lineBreakMainMax = maybeClamp(d, min: containerMainMin, max: containerMainMax)
    } else {
        lineBreakMainMax = containerMainMax
    }

    var lines: [FlexLine] = []
    if !items.isEmpty {
        if ctx.flexWrap == .noWrap {
            lines.append(FlexLine(itemRange: 0..<items.count))
        } else {
            var lineStart = 0
            var lineMainSum: Float = 0
            for i in items.indices {
                let itemOuterMain = items[i].hypotheticalOuterSize.main(direction: dir)
                let gapBefore = (i > lineStart) ? ctx.mainGap : 0
                if i > lineStart, let limit = lineBreakMainMax, lineMainSum + gapBefore + itemOuterMain > limit + 0.001 {
                    lines.append(FlexLine(itemRange: lineStart..<i))
                    lineStart = i
                    lineMainSum = itemOuterMain
                } else {
                    lineMainSum += gapBefore + itemOuterMain
                }
            }
            lines.append(FlexLine(itemRange: lineStart..<items.count))
        }
    }

    let resolvedInnerMain: Float
    if let nm = ctx.nodeInnerSize.main(direction: dir) {
        resolvedInnerMain = nm
    } else {
        var maxLineMain: Float = 0
        for line in lines {
            var lineSum: Float = 0
            for i in line.itemRange {
                if i > line.itemRange.lowerBound { lineSum += ctx.mainGap }
                lineSum += items[i].hypotheticalOuterSize.main(direction: dir)
            }
            maxLineMain = Swift.max(maxLineMain, lineSum)
        }
        switch containerMainAvail {
        case .minContent, .maxContent:
            resolvedInnerMain = maybeClamp(maxLineMain, min: containerMainMin, max: containerMainMax)
        case .definite(let avail):
            if input.sizingMode == .contentSize {
                resolvedInnerMain = maybeClamp(maxLineMain, min: containerMainMin, max: containerMainMax)
            } else {
                resolvedInnerMain = maybeClamp(Swift.min(avail, maxLineMain), min: containerMainMin, max: containerMainMax)
            }
        }
    }
    return (lines, resolvedInnerMain)
}

private func flexResolveFlexibleLengths(
    ctx: FlexContainerContext,
    lines: [FlexLine],
    items: inout [FlexItem],
    resolvedInnerMain: Float
) {
    let dir = ctx.dir
    let mainGap = ctx.mainGap
    for line in lines {
        let lineCount = line.itemRange.count
        let totalGap = mainGap * Float(Swift.max(0, lineCount - 1))

        var usedMain: Float = totalGap
        for i in line.itemRange {
            let marginMain = (items[i].margin.mainStart(direction: dir) ?? 0) + (items[i].margin.mainEnd(direction: dir) ?? 0)
            usedMain += items[i].hypotheticalInnerSize.main(direction: dir) + marginMain
        }
        let growing = usedMain < resolvedInnerMain

        for i in line.itemRange {
            items[i].frozen = false
            items[i].targetSize.setMain(items[i].hypotheticalInnerSize.main(direction: dir), direction: dir)
        }

        // Freeze inflexible items
        for i in line.itemRange {
            let flexFactor = growing ? items[i].flexGrow : items[i].flexShrink
            let inflexible = flexFactor == 0
                || (growing && items[i].flexBasis > items[i].hypotheticalInnerSize.main(direction: dir))
                || (!growing && items[i].flexBasis < items[i].hypotheticalInnerSize.main(direction: dir))
            if inflexible {
                items[i].frozen = true
                items[i].targetSize.setMain(items[i].hypotheticalInnerSize.main(direction: dir), direction: dir)
            }
        }

        // Compute initial free space
        var initialUsed: Float = totalGap
        for i in line.itemRange {
            let marginMain = (items[i].margin.mainStart(direction: dir) ?? 0) + (items[i].margin.mainEnd(direction: dir) ?? 0)
            initialUsed += (items[i].frozen ? items[i].targetSize.main(direction: dir) : items[i].flexBasis) + marginMain
        }
        let initialFreeSpace = resolvedInnerMain - initialUsed

        // Iterative freeze loop
        while true {
            var allFrozen = true
            var unfrozenFlexSum: Float = 0
            var remainingUsed: Float = totalGap
            for i in line.itemRange {
                let marginMain = (items[i].margin.mainStart(direction: dir) ?? 0) + (items[i].margin.mainEnd(direction: dir) ?? 0)
                if items[i].frozen {
                    remainingUsed += items[i].targetSize.main(direction: dir) + marginMain
                } else {
                    allFrozen = false
                    unfrozenFlexSum += growing ? items[i].flexGrow : items[i].flexShrink
                    remainingUsed += items[i].flexBasis + marginMain
                }
            }
            if allFrozen { break }

            var remainingFree = resolvedInnerMain - remainingUsed
            if unfrozenFlexSum < 1.0 {
                let scaled = initialFreeSpace * unfrozenFlexSum
                if scaled.magnitude < remainingFree.magnitude {
                    remainingFree = scaled
                }
            }

            if growing && remainingFree > 0 && unfrozenFlexSum > 0 {
                for i in line.itemRange where !items[i].frozen {
                    let share = items[i].flexGrow / unfrozenFlexSum
                    items[i].targetSize.setMain(items[i].flexBasis + remainingFree * share, direction: dir)
                }
            } else if !growing && remainingFree < 0 {
                var scaledShrinkSum: Float = 0
                for i in line.itemRange where !items[i].frozen {
                    scaledShrinkSum += items[i].flexShrink * items[i].innerFlexBasis
                }
                if scaledShrinkSum > 0 {
                    for i in line.itemRange where !items[i].frozen {
                        let ratio = (items[i].flexShrink * items[i].innerFlexBasis) / scaledShrinkSum
                        items[i].targetSize.setMain(items[i].flexBasis + remainingFree * ratio, direction: dir)
                    }
                } else {
                    for i in line.itemRange where !items[i].frozen {
                        items[i].targetSize.setMain(items[i].flexBasis, direction: dir)
                    }
                }
            } else {
                for i in line.itemRange where !items[i].frozen {
                    items[i].targetSize.setMain(items[i].flexBasis, direction: dir)
                }
            }

            var totalViolation: Float = 0
            for i in line.itemRange where !items[i].frozen {
                let unclamped = items[i].targetSize.main(direction: dir)
                let clamped = maybeClamp(unclamped, min: items[i].resolvedMinimumMainSize, max: items[i].maxSize.main(direction: dir))
                items[i].targetSize.setMain(clamped, direction: dir)
                items[i].violation = clamped - unclamped
                totalViolation += items[i].violation
            }

            if totalViolation == 0 {
                for i in line.itemRange { items[i].frozen = true }
                break
            } else if totalViolation > 0 {
                var frozeAny = false
                for i in line.itemRange where !items[i].frozen && items[i].violation > 0 {
                    items[i].frozen = true
                    frozeAny = true
                }
                if !frozeAny { break }
            } else {
                var frozeAny = false
                for i in line.itemRange where !items[i].frozen && items[i].violation < 0 {
                    items[i].frozen = true
                    frozeAny = true
                }
                if !frozeAny { break }
            }
        }

        for i in line.itemRange {
            let marginMain = (items[i].margin.mainStart(direction: dir) ?? 0) + (items[i].margin.mainEnd(direction: dir) ?? 0)
            items[i].outerTargetSize.setMain(items[i].targetSize.main(direction: dir) + marginMain, direction: dir)
        }
    }
}

private func flexDetermineCrossSizes(
    tree: any LayoutTree,
    ctx: FlexContainerContext,
    items: inout [FlexItem],
    resolvedInnerMain: Float
) {
    for idx in items.indices {
        flexDetermineSingleItemCrossSize(
            tree: tree,
            ctx: ctx,
            item: &items[idx],
            resolvedInnerMain: resolvedInnerMain
        )
    }
}

private func flexDetermineSingleItemCrossSize(
    tree: any LayoutTree,
    ctx: FlexContainerContext,
    item: inout FlexItem,
    resolvedInnerMain: Float
) {
    let dir = ctx.dir
    let isRow = ctx.isRow
    let containerCrossInner = ctx.nodeInnerSize.cross(direction: dir)
    let targetMain = item.targetSize.main(direction: dir)
    var targetCross = item.size.cross(direction: dir)

    if targetCross == nil, let ratio = item.aspectRatio, ratio > 0, ratio.isFinite {
        targetCross = isRow ? (targetMain / ratio) : (targetMain * ratio)
    }

    if let tc = targetCross {
        let clamped = maybeClamp(tc, min: item.minSize.cross(direction: dir), max: item.maxSize.cross(direction: dir))
        item.hypotheticalInnerSize.setCross(clamped, direction: dir)
        item.targetSize.setCross(clamped, direction: dir)
    } else {
        var knownDims = Size<Float?>(width: nil, height: nil)
        knownDims.setMain(targetMain, direction: dir)
        var childAvail = ctx.availInner
        childAvail.setMain(.definite(targetMain), direction: dir)

        let out = computeNodeLayout(
            tree: tree,
            node: item.node,
            input: LayoutInput(
                runMode: .computeSize,
                sizingMode: .inherentSize,
                axis: isRow ? .vertical : .horizontal,
                knownDimensions: knownDims,
                parentSize: Size(
                    width: isRow ? resolvedInnerMain : containerCrossInner,
                    height: isRow ? containerCrossInner : resolvedInnerMain
                ),
                availableSpace: childAvail,
                verticalMarginsAreCollapsible: .false
            )
        )
        let clamped = maybeClamp(out.size.cross(direction: dir), min: item.minSize.cross(direction: dir), max: item.maxSize.cross(direction: dir))
        item.hypotheticalInnerSize.setCross(clamped, direction: dir)
        item.targetSize.setCross(clamped, direction: dir)
        item.baseline = isRow ? (out.firstBaselines.y ?? clamped) : (out.firstBaselines.x ?? clamped)
    }

    let marginCross = (item.margin.crossStart(direction: dir) ?? 0) + (item.margin.crossEnd(direction: dir) ?? 0)
    item.hypotheticalOuterSize.setCross(item.hypotheticalInnerSize.cross(direction: dir) + marginCross, direction: dir)
    item.outerTargetSize.setCross(item.hypotheticalOuterSize.cross(direction: dir), direction: dir)
}

private func flexComputeLinesAndAlignContent(
    ctx: FlexContainerContext,
    lines: inout [FlexLine],
    items: [FlexItem]
) -> Float {
    let dir = ctx.dir
    let containerCrossInner = ctx.nodeInnerSize.cross(direction: dir)
    let containerAlignItems = ctx.alignItems

    for lineIdx in lines.indices {
        let range = lines[lineIdx].itemRange
        if lines.count == 1, let definiteCross = containerCrossInner {
            lines[lineIdx].crossSize = definiteCross
        } else {
            var maxAscent: Float = 0
            var maxDescent: Float = 0
            var maxNonBaseline: Float = 0
            for i in range {
                let item = items[i]
                let align = item.alignSelf ?? containerAlignItems
                let marginCrossStart = item.margin.crossStart(direction: dir) ?? 0
                let outerCross = item.hypotheticalOuterSize.cross(direction: dir)

                if align == .baseline && !item.marginIsAuto.crossStart(direction: dir) && !item.marginIsAuto.crossEnd(direction: dir) {
                    let ascent = item.baseline + marginCrossStart
                    let descent = outerCross - ascent
                    maxAscent = Swift.max(maxAscent, ascent)
                    maxDescent = Swift.max(maxDescent, descent)
                } else {
                    maxNonBaseline = Swift.max(maxNonBaseline, outerCross)
                }
            }
            lines[lineIdx].crossSize = Swift.max(maxNonBaseline, maxAscent + maxDescent)
        }
    }

    let crossGap = ctx.crossGap
    let totalLinesCross = lines.reduce(Float(0)) { $0 + $1.crossSize } + crossGap * Float(Swift.max(0, lines.count - 1))
    let containerCrossMin = ctx.minSize.cross(direction: dir).map { Swift.max(0, $0 - ctx.innerPB.cross(direction: dir)) }
    let containerCrossMax = ctx.maxSize.cross(direction: dir).map { Swift.max(0, $0 - ctx.innerPB.cross(direction: dir)) }
    let resolvedInnerCross = containerCrossInner ?? maybeClamp(totalLinesCross, min: containerCrossMin, max: containerCrossMax)

    if !lines.isEmpty {
        let freeCross = resolvedInnerCross - totalLinesCross
        let alignContent = ctx.alignContent
        if lines.count == 1 && alignContent == .stretch {
            lines[0].crossSize = Swift.max(lines[0].crossSize, resolvedInnerCross)
        } else if freeCross > 0 && alignContent == .stretch {
            let extraPerLine = freeCross / Float(lines.count)
            for l in lines.indices {
                lines[l].crossSize += extraPerLine
            }
        }

        let updatedTotalCross = lines.reduce(Float(0)) { $0 + $1.crossSize } + crossGap * Float(Swift.max(0, lines.count - 1))
        let remCross = resolvedInnerCross - updatedTotalCross
        var curCross: Float = 0
        var extraGap: Float = 0

        switch alignContent {
        case .flexStart, .normal, .stretch:
            curCross = ctx.isWrapReverse ? remCross : 0
        case .flexEnd:
            curCross = ctx.isWrapReverse ? 0 : remCross
        case .start:
            curCross = 0
        case .end:
            curCross = remCross
        case .center:
            curCross = remCross * 0.5
        case .spaceBetween:
            if lines.count > 1 && remCross > 0 {
                extraGap = remCross / Float(lines.count - 1)
            }
        case .spaceAround:
            if remCross > 0 {
                let step = remCross / Float(lines.count)
                curCross = step * 0.5
                extraGap = step
            }
        case .spaceEvenly:
            if remCross > 0 {
                let step = remCross / Float(lines.count + 1)
                curCross = step
                extraGap = step
            }
        }

        let lineIndices = ctx.isWrapReverse ? Array(lines.indices.reversed()) : Array(lines.indices)
        for l in lineIndices {
            lines[l].offsetCross = curCross
            curCross += lines[l].crossSize + crossGap + extraGap
        }
    }

    return resolvedInnerCross
}

private func flexStretchAndPositionItems(
    ctx: FlexContainerContext,
    lines: [FlexLine],
    items: inout [FlexItem],
    resolvedInnerMain: Float,
    resolvedInnerCross: Float
) -> (Float, Float, Size<Float?>) {
    let dir = ctx.dir
    let isRow = ctx.isRow
    let containerAlignItems = ctx.alignItems

    for line in lines {
        for i in line.itemRange {
            let align = items[i].alignSelf ?? containerAlignItems
            let hasAutoCross = items[i].size.cross(direction: dir) == nil
            let noAutoCrossMargin = !items[i].marginIsAuto.crossStart(direction: dir) && !items[i].marginIsAuto.crossEnd(direction: dir)
            if (align == .stretch || align == .normal) && hasAutoCross && noAutoCrossMargin {
                let marginCross = (items[i].margin.crossStart(direction: dir) ?? 0) + (items[i].margin.crossEnd(direction: dir) ?? 0)
                let stretched = maybeClamp(
                    Swift.max(0, line.crossSize - marginCross),
                    min: items[i].minSize.cross(direction: dir),
                    max: items[i].maxSize.cross(direction: dir)
                )
                items[i].targetSize.setCross(stretched, direction: dir)
                items[i].outerTargetSize.setCross(stretched + marginCross, direction: dir)
            }
        }
    }

    let outerWidth = maybeClamp(
        ctx.known.width ?? ((isRow ? resolvedInnerMain : resolvedInnerCross) + ctx.innerPB.width),
        min: ctx.minSize.width,
        max: ctx.maxSize.width
    )
    let outerHeight = maybeClamp(
        ctx.known.height ?? ((isRow ? resolvedInnerCross : resolvedInnerMain) + ctx.innerPB.height),
        min: ctx.minSize.height,
        max: ctx.maxSize.height
    )
    let finalParentSize = Size<Float?>(
        width: Swift.max(0, outerWidth - ctx.innerPB.width),
        height: Swift.max(0, outerHeight - ctx.innerPB.height)
    )

    let justify = ctx.justifyContent
    let isMainReverse = dir.isReverse
    let mainGap = ctx.mainGap

    for line in lines {
        let range = line.itemRange
        let lineCount = range.count
        let totalLineGap = mainGap * Float(Swift.max(0, lineCount - 1))

        var usedMain = totalLineGap
        var autoMarginCount = 0
        for i in range {
            usedMain += items[i].outerTargetSize.main(direction: dir)
            if items[i].marginIsAuto.mainStart(direction: dir) { autoMarginCount += 1 }
            if items[i].marginIsAuto.mainEnd(direction: dir) { autoMarginCount += 1 }
        }
        let freeMain = resolvedInnerMain - usedMain

        var curMain: Float = 0
        var extraMainGap: Float = 0
        if autoMarginCount > 0 && freeMain > 0 {
            let perAuto = freeMain / Float(autoMarginCount)
            for i in range {
                if items[i].marginIsAuto.mainStart(direction: dir) {
                    if dir == .row { items[i].margin.left = perAuto }
                    if dir == .rowReverse { items[i].margin.right = perAuto }
                    if dir == .column { items[i].margin.top = perAuto }
                    if dir == .columnReverse { items[i].margin.bottom = perAuto }
                }
                if items[i].marginIsAuto.mainEnd(direction: dir) {
                    if dir == .row { items[i].margin.right = perAuto }
                    if dir == .rowReverse { items[i].margin.left = perAuto }
                    if dir == .column { items[i].margin.bottom = perAuto }
                    if dir == .columnReverse { items[i].margin.top = perAuto }
                }
            }
        } else {
            switch justify {
            case .flexStart, .normal, .stretch:
                curMain = isMainReverse ? freeMain : 0
            case .flexEnd:
                curMain = isMainReverse ? 0 : freeMain
            case .start:
                curMain = 0
            case .end:
                curMain = freeMain
            case .center:
                curMain = freeMain * 0.5
            case .spaceBetween:
                if lineCount > 1 && freeMain > 0 {
                    extraMainGap = freeMain / Float(lineCount - 1)
                }
            case .spaceAround:
                if freeMain > 0 {
                    let step = freeMain / Float(lineCount)
                    curMain = step * 0.5
                    extraMainGap = step
                }
            case .spaceEvenly:
                if freeMain > 0 {
                    let step = freeMain / Float(lineCount + 1)
                    curMain = step
                    extraMainGap = step
                }
            }
        }

        var maxLineBaseline: Float = 0
        for i in range {
            let align = items[i].alignSelf ?? containerAlignItems
            if align == .baseline {
                let mStart = items[i].margin.crossStart(direction: dir) ?? 0
                maxLineBaseline = Swift.max(maxLineBaseline, items[i].baseline + mStart)
            }
        }

        let orderedIndices = isMainReverse ? Array(range.reversed()) : Array(range)
        for i in orderedIndices {
            let mMainStart = items[i].margin.mainStart(direction: dir) ?? 0
            let mMainEnd = items[i].margin.mainEnd(direction: dir) ?? 0
            items[i].offsetMain = curMain + mMainStart
            curMain += mMainStart + items[i].targetSize.main(direction: dir) + mMainEnd + mainGap + extraMainGap

            let itemCross = items[i].targetSize.cross(direction: dir)
            let mCrossStart = items[i].margin.crossStart(direction: dir)
            let mCrossEnd = items[i].margin.crossEnd(direction: dir)
            let freeCross = line.crossSize - itemCross - (mCrossStart ?? 0) - (mCrossEnd ?? 0)

            let offsetInLine: Float
            if mCrossStart == nil && mCrossEnd == nil {
                offsetInLine = Swift.max(0, freeCross) * 0.5
            } else if mCrossStart == nil {
                offsetInLine = Swift.max(0, freeCross)
            } else if mCrossEnd == nil {
                offsetInLine = mCrossStart ?? 0
            } else {
                let align = items[i].alignSelf ?? containerAlignItems
                let startMargin = mCrossStart ?? 0
                switch align {
                case .flexStart, .normal, .stretch:
                    offsetInLine = ctx.isWrapReverse ? (startMargin + freeCross) : startMargin
                case .flexEnd:
                    offsetInLine = ctx.isWrapReverse ? startMargin : (startMargin + freeCross)
                case .start, .selfStart:
                    offsetInLine = startMargin
                case .end, .selfEnd:
                    offsetInLine = startMargin + freeCross
                case .center:
                    offsetInLine = startMargin + freeCross * 0.5
                case .baseline:
                    offsetInLine = ctx.isWrapReverse
                        ? (startMargin + freeCross)
                        : (maxLineBaseline - items[i].baseline)
                }
            }
            items[i].offsetCross = line.offsetCross + offsetInLine
        }
    }

    return (outerWidth, outerHeight, finalParentSize)
}

private func flexFinalizeChildrenAndOutput(
    tree: any LayoutTree,
    ctx: FlexContainerContext,
    items: [FlexItem],
    input: LayoutInput,
    finalParentSize: Size<Float?>,
    outerWidth: Float,
    outerHeight: Float
) -> LayoutOutput {
    var contentMaxX: Float = ctx.contentBoxInset.left
    var contentMaxY: Float = ctx.contentBoxInset.top
    var firstBaselineY: Float? = nil

    if input.runMode == .performLayout {
        for idx in items.indices {
            flexLayoutSingleChild(
                tree: tree,
                ctx: ctx,
                item: items[idx],
                finalParentSize: finalParentSize,
                contentMaxX: &contentMaxX,
                contentMaxY: &contentMaxY,
                firstBaselineY: &firstBaselineY
            )
        }
    }

    return LayoutOutput(
        size: Size(width: outerWidth, height: outerHeight),
        contentSize: Size(
            width: Swift.max(outerWidth, contentMaxX + ctx.contentBoxInset.right),
            height: Swift.max(outerHeight, contentMaxY + ctx.contentBoxInset.bottom)
        ),
        firstBaselines: Point(x: nil, y: firstBaselineY)
    )
}

private func flexLayoutSingleChild(
    tree: any LayoutTree,
    ctx: FlexContainerContext,
    item: FlexItem,
    finalParentSize: Size<Float?>,
    contentMaxX: inout Float,
    contentMaxY: inout Float,
    firstBaselineY: inout Float?
) {
    let targetW = item.targetSize.width
    let targetH = item.targetSize.height

    let childOut = computeNodeLayout(
        tree: tree,
        node: item.node,
        input: LayoutInput(
            runMode: .performLayout,
            sizingMode: .inherentSize,
            axis: .both,
            knownDimensions: Size(width: targetW, height: targetH),
            parentSize: finalParentSize,
            availableSpace: Size(width: .definite(targetW), height: .definite(targetH)),
            verticalMarginsAreCollapsible: .false
        )
    )

    var x = ctx.contentBoxInset.left + (ctx.isRow ? item.offsetMain : item.offsetCross)
    var y = ctx.contentBoxInset.top + (ctx.isRow ? item.offsetCross : item.offsetMain)

    if item.position == .relative {
        if let l = item.inset.left.maybeResolve(finalParentSize.width) {
            x += l
        } else if let r = item.inset.right.maybeResolve(finalParentSize.width) {
            x -= r
        }
        if let t = item.inset.top.maybeResolve(finalParentSize.height) {
            y += t
        } else if let b = item.inset.bottom.maybeResolve(finalParentSize.height) {
            y -= b
        }
    }

    contentMaxX = Swift.max(contentMaxX, x + targetW)
    contentMaxY = Swift.max(contentMaxY, y + targetH)
    if firstBaselineY == nil {
        firstBaselineY = y + (childOut.firstBaselines.y ?? targetH)
    }

    let resolvedMargin = Rect<Float>(
        left: item.margin.left ?? 0,
        right: item.margin.right ?? 0,
        top: item.margin.top ?? 0,
        bottom: item.margin.bottom ?? 0
    )

    tree.setUnroundedLayout(item.node, Layout(
        order: item.order,
        location: Point(x: x, y: y),
        size: Size(width: targetW, height: targetH),
        contentSize: childOut.contentSize,
        scrollbarSize: .zero,
        border: item.border,
        padding: item.padding,
        margin: resolvedMargin
    ))
}

extension Rect where T == Bool {
    @inlinable
    func crossStart(direction: FlexDirection) -> Bool {
        direction.isRow ? top : left
    }

    @inlinable
    func crossEnd(direction: FlexDirection) -> Bool {
        direction.isRow ? bottom : right
    }

    @inlinable
    func mainStart(direction: FlexDirection) -> Bool {
        switch direction {
        case .row: return left
        case .rowReverse: return right
        case .column: return top
        case .columnReverse: return bottom
        }
    }

    @inlinable
    func mainEnd(direction: FlexDirection) -> Bool {
        switch direction {
        case .row: return right
        case .rowReverse: return left
        case .column: return bottom
        case .columnReverse: return top
        }
    }
}
