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
    var isScrollContainer: Bool
    var alignSelf: AlignSelf
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
    func participatesInBaseline(_ ctx: FlexContainerContext) -> Bool {
        ctx.isRow && alignSelf.keyword == .baseline && !marginIsAuto.top && !marginIsAuto.bottom
    }

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
    var wholeRows: Bool
    var isWrapReverse: Bool
    var isRTL: Bool
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

    var isRTLColumn: Bool { !isRow && isRTL }

    func resolvedCrossAlignment(for child: TaffyStyle) -> AlignSelf {
        let alignment = child.alignSelf ?? alignItems
        switch alignment.keyword {
        case .selfStart, .selfEnd:
            // Self-relative alignment uses the child's inline direction.
            let sameDirection = isRow || (child.direction == .rtl) == isRTLColumn
            let resolved: AlignItemsKeyword = alignment.keyword == .selfStart
                ? (sameDirection ? .start : .end)
                : (sameDirection ? .end : .start)
            return AlignSelf(keyword: resolved, safety: alignment.safety)
        default:
            return alignment
        }
    }

    /// Project an intrinsic measurement for this parent after the child caches its own fractional size.
    func measuredMainSize(_ output: LayoutOutput) -> Float {
        wholeRows ? (output.size.height + 0.5).rounded(.down) : output.size.main(direction: dir)
    }
}

private struct FlexBox {
    var ctx: FlexContainerContext
    var items: [FlexItem]
    var lines: [FlexLine]
    var finalParentSize: Size<Float?>
    var outerWidth: Float
    var outerHeight: Float

    func finish(tree: any LayoutTree, input: LayoutInput) -> LayoutOutput {
        flexFinalizeChildrenAndOutput(tree: tree, ctx: ctx, items: items, lines: lines,
                                      input: input, finalParentSize: finalParentSize,
                                      outerWidth: outerWidth, outerHeight: outerHeight)
    }
}

private enum FlexPreparation {
    case done(LayoutOutput)
    case box(FlexBox)
}

internal func computeFlexboxLayout(
    tree: any LayoutTree,
    node: NodeId,
    input: LayoutInput
) -> LayoutOutput {
    var parents: [(NodeId, LayoutInput, FlexBox)] = []
    var currentNode = node
    var currentInput = input
    var output: LayoutOutput
    descend: while true {
        switch prepareFlexbox(tree: tree, node: currentNode, input: currentInput) {
        case .done(let early):
            output = early
            break descend
        case .box(let box):
            // A chain of single-item flex containers can commit its final layouts from the
            // innermost box out. No parent needs to keep a solver call frame while its child
            // measures text, and each layout remains on its original thread.
            if currentInput.runMode == .performLayout, box.items.count == 1,
               tree.childCount(currentNode) == 1 {
                let item = box.items[0]
                let child = item.node
                let childInput = flexFinalChildInput(target: item.targetSize, parent: box.finalParentSize)
                if tree.childCount(child) == 1, tree.style(child).display == .flex,
                   tree.cacheGet(child, childInput) == nil {
                    parents.append((currentNode, currentInput, box))
                    currentNode = child
                    currentInput = childInput
                    continue descend
                }
            }
            output = box.finish(tree: tree, input: currentInput)
            break descend
        }
    }
    while let (parent, parentInput, box) = parents.popLast() {
        computeOutOfFlowLayout(tree: tree, node: currentNode, containerOutput: &output)
        tree.cacheStore(currentNode, currentInput, output)
        currentNode = parent
        currentInput = parentInput
        output = box.finish(tree: tree, input: parentInput)
    }
    return output
}

private func prepareFlexbox(tree: any LayoutTree, node: NodeId, input: LayoutInput) -> FlexPreparation {
    let ctx = flexComputeContainerContext(tree: tree, node: node, input: input)
    if let early = ctx.earlyReturn {
        return .done(early)
    }

    var items = flexCollectItems(tree: tree, node: node, ctx: ctx)
    flexDetermineBaseSizes(tree: tree, ctx: ctx, items: &items)

    var (lines, resolvedInnerMain) = flexCollectLinesAndMainSize(tree: tree, ctx: ctx, items: items, input: input)
    if input.runMode == .computeSize {
        let mainAxisRequested = (input.axis == .horizontal && ctx.isRow) || (input.axis == .vertical && !ctx.isRow)
        if mainAxisRequested {
            let outerMain = maybeClamp(
                ctx.known.main(direction: ctx.dir) ?? (resolvedInnerMain + ctx.innerPB.main(direction: ctx.dir)),
                min: ctx.minSize.main(direction: ctx.dir),
                max: ctx.maxSize.main(direction: ctx.dir)
            )
            var size = Size<Float>.zero
            size.setMain(outerMain, direction: ctx.dir)
            return .done(LayoutOutput.fromOuterSize(size))
        }
    }
    flexResolveFlexibleLengths(ctx: ctx, lines: lines, items: &items, resolvedInnerMain: resolvedInnerMain)
    flexDetermineCrossSizes(tree: tree, ctx: ctx, items: &items)

    flexMeasureBaselines(tree: tree, ctx: ctx, lines: lines, items: &items)
    let resolvedInnerCross = flexComputeLinesAndAlignContent(ctx: ctx, lines: &lines, items: items)
    if input.runMode == .computeSize {
        let outerWidth = maybeClamp(
            ctx.known.width ?? ((ctx.isRow ? resolvedInnerMain : resolvedInnerCross) + ctx.innerPB.width),
            min: ctx.minSize.width,
            max: ctx.maxSize.width
        )
        let outerHeight = maybeClamp(
            ctx.known.height ?? ((ctx.isRow ? resolvedInnerCross : resolvedInnerMain) + ctx.innerPB.height),
            min: ctx.minSize.height,
            max: ctx.maxSize.height
        )
        return .done(LayoutOutput.fromOuterSize(Size(width: outerWidth, height: outerHeight)))
    }
    let (outerWidth, outerHeight, finalParentSize) = flexStretchAndPositionItems(
        ctx: ctx,
        lines: lines,
        items: &items,
        resolvedInnerMain: resolvedInnerMain,
        resolvedInnerCross: resolvedInnerCross
    )

    return .box(FlexBox(ctx: ctx, items: items, lines: lines, finalParentSize: finalParentSize,
                        outerWidth: outerWidth, outerHeight: outerHeight))
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

    let isRTL = style.direction == .rtl
    let contentBoxInset = Rect(
        left: padding.left + border.left + (isRTL ? scrollbarSize.width : 0),
        right: padding.right + border.right + (isRTL ? 0 : scrollbarSize.width),
        top: padding.top + border.top,
        bottom: padding.bottom + border.bottom + scrollbarSize.height
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

    let dir = style.flexDirection
    let isRow = dir.isRow
    let innerPB = Size(width: contentBoxInset.horizontalSum, height: contentBoxInset.verticalSum)

    var earlyReturn: LayoutOutput? = nil
    if input.runMode == .computeSize {
        if let w = known.width, let h = known.height {
            let clamped = Size(
                width: maybeClamp(Swift.max(w, pbSum.width + scrollbarSize.width), min: minSize.width, max: maxSize.width),
                height: maybeClamp(Swift.max(h, pbSum.height + scrollbarSize.height), min: minSize.height, max: maxSize.height)
            )
            earlyReturn = LayoutOutput.fromOuterSize(clamped)
        } else if input.axis == .horizontal, let w = known.width {
            let clampedW = maybeClamp(Swift.max(w, pbSum.width + scrollbarSize.width), min: minSize.width, max: maxSize.width)
            earlyReturn = LayoutOutput.fromOuterSize(Size(width: clampedW, height: 0))
        } else if input.axis == .vertical, let h = known.height {
            let clampedH = maybeClamp(Swift.max(h, pbSum.height + scrollbarSize.height), min: minSize.height, max: maxSize.height)
            earlyReturn = LayoutOutput.fromOuterSize(Size(width: 0, height: clampedH))
        }
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
        wholeRows: style.isWholeRowsColumn,
        isWrapReverse: style.flexWrap == .wrapReverse,
        isRTL: isRTL,
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
        var cStyle = tree.style(child)
        if cStyle.display == .none {
            _ = computeHiddenLayout(tree: tree, node: child)
            continue
        }
        if cStyle.isOutOfFlow {
            orderCounter += 1
            continue
        }

        var flexBasis = cStyle.flexBasis
        if ctx.wholeRows {
            cStyle.roundAbsoluteRowHeights()
            if case .length(let value) = flexBasis { flexBasis = .length((value + 0.5).rounded(.down)) }
        }
        let cPad = cStyle.resolvedPadding(parentWidth: nodeInnerSize.width)
        let cBorder = cStyle.resolvedBorder(parentWidth: nodeInnerSize.width)
        let cPb = cPad.sumAxes + cBorder.sumAxes
        let cAdj = cStyle.contentBoxAdjustment(paddingBorderSum: cPb)

        var cSize = cStyle.resolveSize(parent: nodeInnerSize, adjustment: cAdj)
        let cMin = cStyle.resolveMinSize(parent: nodeInnerSize, adjustment: cAdj)
        let cMax = cStyle.resolveMaxSize(parent: nodeInnerSize, adjustment: cAdj)
        if let specified = cSize.cross(direction: ctx.dir) {
            // Measure the child at the used cross size. Its preferred main size transfers
            // from the authored content-box size, before flex applies min/max constraints.
            let minCross = applyAspectRatio(cMin, cStyle.aspectRatio).cross(direction: ctx.dir)
            let maxCross = applyAspectRatio(cMax, cStyle.aspectRatio).cross(direction: ctx.dir)
            let cross = maybeClamp(specified, min: minCross, max: maxCross)
            cSize.setCross(cross, direction: ctx.dir)
            if cSize.main(direction: ctx.dir) == nil, let ratio = cStyle.aspectRatio, ratio > 0, ratio.isFinite {
                let content = specified - cAdj.cross(direction: ctx.dir)
                let main = (ctx.isRow ? content * ratio : content / ratio) + cAdj.main(direction: ctx.dir)
                cSize.setMain(main, direction: ctx.dir)
            }
        }
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
            flexBasisDim: flexBasis,
            aspectRatio: cStyle.aspectRatio,
            boxSizing: cStyle.boxSizing,
            overflowMain: ctx.isRow ? cStyle.overflow.x : cStyle.overflow.y,
            isScrollContainer: cStyle.overflow.x.isScrollContainer || cStyle.overflow.y.isScrollContainer,
            alignSelf: ctx.resolvedCrossAlignment(for: cStyle),
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
    let singleItem = items.count == 1
    for idx in items.indices {
        flexDetermineSingleItemBaseSize(tree: tree, ctx: ctx, item: &items[idx], singleItem: singleItem)
    }
}

private func flexDetermineSingleItemBaseSize(
    tree: any LayoutTree,
    ctx: FlexContainerContext,
    item: inout FlexItem,
    singleItem: Bool
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
              ctx.flexWrap == .noWrap, item.alignSelf.keyword == .stretch,
              let parentCross = nodeInnerSize.cross(direction: dir),
              let start = item.margin.crossStart(direction: dir), let end = item.margin.crossEnd(direction: dir) {
        let cross = maybeClamp(Swift.max(0, parentCross - start - end),
                               min: item.minSize.cross(direction: dir), max: item.maxSize.cross(direction: dir))
        basis = isRow ? cross * ratio : cross / ratio
    } else {
        var knownDims = Size<Float?>(width: nil, height: nil)
        knownDims.setCross(item.size.cross(direction: dir), direction: dir)
        let crossMarginSum = (item.margin.crossStart(direction: dir) ?? 0) + (item.margin.crossEnd(direction: dir) ?? 0)
        var childAvail = availInner
        childAvail.setMain(
            availInner.main(direction: dir) == .minContent ? .minContent : .maxContent,
            direction: dir
        )
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
        basis = ctx.measuredMainSize(out)
    }

    func basisCoversAutomaticMinimum() -> Bool {
        // Content can raise the automatic minimum only as far as the preferred size.
        guard let preferred = item.size.main(direction: dir), basis >= preferred else { return false }
        if item.flexShrink == 0 { return true }
        guard singleItem, let available = childMainParent else { return false }
        return basis + (item.margin.mainStart(direction: dir) ?? 0) + (item.margin.mainEnd(direction: dir) ?? 0) <= available
    }

    let transferredMax = applyAspectRatio(item.maxSize, item.aspectRatio).main(direction: dir)
    let resolvedMinMain: Float
    if let explicitMin = item.minSize.main(direction: dir) {
        resolvedMinMain = explicitMin
    } else if basisCoversAutomaticMinimum() {
        resolvedMinMain = 0
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
        let minContentMain = ctx.measuredMainSize(minOut)
        let clampUpper = maybeMin(item.size.main(direction: dir), transferredMax)
        resolvedMinMain = maybeMin(minContentMain, clampUpper) ?? minContentMain
    } else {
        resolvedMinMain = 0
    }

    let pbMain = item.padding.mainAxisSum(direction: dir) + item.border.mainAxisSum(direction: dir)
    let clampedBasis = Swift.max(basis, pbMain)
    let clampedMinMain = Swift.max(resolvedMinMain, pbMain)
    // Cross-axis min/max bounds transfer through the ratio for the hypothetical size only.
    let transferredMin = applyAspectRatio(item.minSize, item.aspectRatio).main(direction: dir)
    let hypotheticalMain = maybeClamp(clampedBasis, min: Swift.max(transferredMin ?? 0, clampedMinMain), max: transferredMax)

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
    tree: any LayoutTree,
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
            // CSS Flexbox intrinsic main size contribution (taffy 0.15 compute/flexbox.rs:1461-1645)
            var mainSize: Float = 0
            for line in lines {
                var itemMainSum: Float = 0
                for i in line.itemRange {
                    let item = items[i]
                    let styleMin = item.minSize.main(direction: dir)
                    let stylePreferred = item.size.main(direction: dir)
                    let styleMax = item.maxSize.main(direction: dir)
                    let marginMainSum = (item.margin.mainStart(direction: dir) ?? 0) + (item.margin.mainEnd(direction: dir) ?? 0)
                    let clampingBasis: Float = ctx.isRow
                        ? Swift.max(item.flexBasis, stylePreferred ?? item.flexBasis)
                        : item.flexBasis
                    let flexBasisMin: Float? = (item.flexShrink == 0) ? clampingBasis : nil
                    let flexBasisMax: Float? = (item.flexGrow == 0) ? clampingBasis : nil
                    let minMainSize = Swift.max(
                        maybeMax(styleMin, flexBasisMin) ?? item.resolvedMinimumMainSize,
                        item.resolvedMinimumMainSize
                    )
                    let maxMainSize = maybeMin(styleMax, flexBasisMax) ?? .infinity

                    let contentContribution: Float
                    if let pref = stylePreferred, maxMainSize <= minMainSize || maxMainSize <= pref {
                        contentContribution = Swift.max(Swift.min(pref, maxMainSize), minMainSize) + marginMainSum
                    } else if maxMainSize <= minMainSize {
                        contentContribution = minMainSize + marginMainSum
                    } else if item.isScrollContainer {
                        contentContribution = item.flexBasis + marginMainSum
                    } else if let pref = stylePreferred {
                        let pbMain = item.padding.mainAxisSum(direction: dir) + item.border.mainAxisSum(direction: dir)
                        let innerMain = Swift.max(pref, pbMain)
                        let base = ctx.isRow ? innerMain : Swift.max(innerMain, item.flexBasis)
                        contentContribution = maybeClamp(base + marginMainSum, min: styleMin, max: styleMax)
                    } else {
                        let crossAxisParent = ctx.nodeInnerSize.cross(direction: dir)
                        let crossMarginSum = (item.margin.crossStart(direction: dir) ?? 0) + (item.margin.crossEnd(direction: dir) ?? 0)
                        let childCrossAvail = ctx.availInner.cross(direction: dir)
                            .mapDefiniteValue { Swift.max(0, (crossAxisParent ?? $0) - crossMarginSum) }
                            .maybeMin(item.maxSize.cross(direction: dir))
                            .maybeMax(item.minSize.cross(direction: dir))
                        var childAvail = ctx.availInner
                        childAvail.setCross(childCrossAvail, direction: dir)
                        var childKnown = item.size
                        childKnown.setMain(nil, direction: dir)
                        let itemAlign = item.alignSelf
                        if itemAlign.keyword == .stretch && childKnown.cross(direction: dir) == nil {
                            childKnown.setCross(childCrossAvail.intoOption(), direction: dir)
                        }
                        let measurement = computeNodeLayout(
                            tree: tree,
                            node: item.node,
                            input: LayoutInput(
                                runMode: .computeSize,
                                sizingMode: .contentSize,
                                axis: ctx.isRow ? .horizontal : .vertical,
                                knownDimensions: childKnown,
                                parentSize: ctx.nodeInnerSize,
                                availableSpace: childAvail,
                                verticalMarginsAreCollapsible: .false
                            )
                        )
                        let measured = ctx.measuredMainSize(measurement)
                        let transferred: Float? = {
                            guard let ratio = item.aspectRatio, ratio > 0, ratio.isFinite,
                                  let crossVal = childKnown.cross(direction: dir) else { return nil }
                            return ctx.isRow ? (crossVal * ratio) : (crossVal / ratio)
                        }()
                        let innerMain = maybeMax(measured, transferred) ?? measured
                        let base = ctx.isRow ? innerMain : Swift.max(innerMain, item.flexBasis)
                        contentContribution = maybeClamp(base + marginMainSum, min: styleMin, max: styleMax)
                    }

                    let diff = contentContribution - item.flexBasis
                    let flexContribution: Float
                    if diff > 0 {
                        let frac = diff / Swift.max(1.0, item.flexGrow)
                        flexContribution = Swift.max(1.0, item.flexGrow) * frac
                    } else if diff < 0 {
                        let scaledShrinkFactor = Swift.max(1.0, item.flexShrink) * item.innerFlexBasis
                        if scaledShrinkFactor == 0 {
                            flexContribution = 0
                        } else {
                            let frac = diff / scaledShrinkFactor
                            flexContribution = scaledShrinkFactor * frac
                        }
                    } else {
                        flexContribution = 0
                    }
                    itemMainSum += item.flexBasis + flexContribution
                }
                let gapSum = ctx.mainGap * Float(Swift.max(0, line.itemRange.count - 1))
                mainSize = Swift.max(mainSize, itemMainSum + gapSum)
            }
            resolvedInnerMain = maybeClamp(mainSize, min: containerMainMin, max: containerMainMax)
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
    items: inout [FlexItem]
) {
    for idx in items.indices {
        flexDetermineSingleItemCrossSize(
            tree: tree,
            ctx: ctx,
            item: &items[idx]
        )
    }
}

private func flexDetermineSingleItemCrossSize(
    tree: any LayoutTree,
    ctx: FlexContainerContext,
    item: inout FlexItem
) {
    let dir = ctx.dir
    let isRow = ctx.isRow
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
                sizingMode: .contentSize,
                axis: isRow ? .vertical : .horizontal,
                knownDimensions: knownDims,
                parentSize: ctx.nodeInnerSize,
                availableSpace: childAvail,
                verticalMarginsAreCollapsible: .false
            )
        )
        let clamped = maybeClamp(out.size.cross(direction: dir), min: item.minSize.cross(direction: dir), max: item.maxSize.cross(direction: dir))
        item.hypotheticalInnerSize.setCross(clamped, direction: dir)
        item.targetSize.setCross(clamped, direction: dir)
    }

    let marginCross = (item.margin.crossStart(direction: dir) ?? 0) + (item.margin.crossEnd(direction: dir) ?? 0)
    item.hypotheticalOuterSize.setCross(item.hypotheticalInnerSize.cross(direction: dir) + marginCross, direction: dir)
    item.outerTargetSize.setCross(item.hypotheticalOuterSize.cross(direction: dir), direction: dir)
}

// Baselines come from the child's final layout. An intrinsic-size cache entry
// contains only the dimensions and cannot provide a nested container's baseline.
private func flexMeasureBaselines(
    tree: any LayoutTree, ctx: FlexContainerContext, lines: [FlexLine], items: inout [FlexItem]
) {
    guard ctx.isRow else { return }
    for line in lines {
        var participantCount = 0
        for index in line.itemRange where items[index].participatesInBaseline(ctx) {
            participantCount += 1
            if participantCount == 2 { break }
        }
        guard participantCount == 2 else { continue }
        for index in line.itemRange where items[index].participatesInBaseline(ctx) {
            let item = items[index]
            let width = item.targetSize.width
            let height = item.hypotheticalInnerSize.height
            let output = computeNodeLayout(tree: tree, node: item.node, input: LayoutInput(
                runMode: .performLayout, sizingMode: .contentSize, axis: .both,
                knownDimensions: Size(width: width, height: height), parentSize: ctx.nodeInnerSize,
                availableSpace: Size(width: .definite(width), height: .definite(height))
            ))
            let first = output.firstBaselines.y ?? height
            items[index].baseline = tree.style(item.node).overflow.y.isScrollContainer
                ? Swift.max(0, Swift.min(first, height)) : first
        }
    }
}

private func flexComputeLinesAndAlignContent(
    ctx: FlexContainerContext,
    lines: inout [FlexLine],
    items: [FlexItem]
) -> Float {
    let dir = ctx.dir
    let containerCrossInner = ctx.nodeInnerSize.cross(direction: dir)

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
                let marginCrossStart = item.margin.crossStart(direction: dir) ?? 0
                let outerCross = item.hypotheticalOuterSize.cross(direction: dir)

                if item.participatesInBaseline(ctx) {
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
        if lines.count == 1 && alignContent.keyword == .stretch {
            lines[0].crossSize = Swift.max(lines[0].crossSize, resolvedInnerCross)
        } else if freeCross > 0 && alignContent.keyword == .stretch {
            let extraPerLine = freeCross / Float(lines.count)
            for l in lines.indices {
                lines[l].crossSize += extraPerLine
            }
        }

        let updatedTotalCross = lines.reduce(Float(0)) { $0 + $1.crossSize } + crossGap * Float(Swift.max(0, lines.count - 1))
        let remCross = resolvedInnerCross - updatedTotalCross
        var curCross: Float = 0
        var extraGap: Float = 0

        let effectiveAlignContent: AlignContentKeyword =
            (alignContent.safety == .safe && remCross < 0) ? .start : alignContent.keyword
        switch effectiveAlignContent {
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

        for index in lines.indices {
            let l = ctx.isWrapReverse ? lines.count - 1 - index : index
            lines[l].offsetCross = ctx.isRTLColumn ? resolvedInnerCross - curCross - lines[l].crossSize : curCross
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
    let reverseFlexCrossStart = ctx.isWrapReverse != ctx.isRTLColumn

    for line in lines {
        for i in line.itemRange {
            let align = items[i].alignSelf
            let hasAutoCross = items[i].size.cross(direction: dir) == nil
            let noAutoCrossMargin = !items[i].marginIsAuto.crossStart(direction: dir) && !items[i].marginIsAuto.crossEnd(direction: dir)
            if (align.keyword == .stretch || align.keyword == .normal) && hasAutoCross && noAutoCrossMargin {
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
            let effectiveJustify: AlignContentKeyword =
                (justify.safety == .safe && freeMain < 0) ? .start : justify.keyword
            switch effectiveJustify {
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
        var maxBaselineDescent: Float = 0
        for i in range {
            if items[i].participatesInBaseline(ctx) {
                let mStart = items[i].margin.crossStart(direction: dir) ?? 0
                maxLineBaseline = Swift.max(maxLineBaseline, items[i].baseline + mStart)
                let mEnd = items[i].margin.crossEnd(direction: dir) ?? 0
                maxBaselineDescent = Swift.max(maxBaselineDescent, items[i].targetSize.height + mEnd - items[i].baseline)
            }
        }

        for offset in 0..<range.count {
            let i = isMainReverse ? range.upperBound - 1 - offset : range.lowerBound + offset
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
                let align = items[i].alignSelf
                let startMargin = mCrossStart ?? 0
                let effectiveAlign: AlignItemsKeyword =
                    (align.safety == .safe && freeCross < 0) ? .start : align.keyword
                switch effectiveAlign {
                case .flexStart, .normal, .stretch:
                    offsetInLine = reverseFlexCrossStart ? startMargin + freeCross : startMargin
                case .flexEnd:
                    offsetInLine = reverseFlexCrossStart ? startMargin : startMargin + freeCross
                case .start, .selfStart:
                    offsetInLine = ctx.isRTLColumn ? startMargin + freeCross : startMargin
                case .end, .selfEnd:
                    offsetInLine = ctx.isRTLColumn ? startMargin : startMargin + freeCross
                case .center:
                    offsetInLine = startMargin + freeCross * 0.5
                case .baseline:
                    if ctx.isRow {
                        let groupBaseline = ctx.isWrapReverse ? line.crossSize - maxBaselineDescent : maxLineBaseline
                        offsetInLine = groupBaseline - items[i].baseline
                    } else {
                        let rtlBaseline = ctx.isRTLColumn && ctx.flexWrap == .noWrap
                        offsetInLine = (ctx.isWrapReverse != rtlBaseline) ? startMargin + freeCross : startMargin
                    }
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
    lines: [FlexLine],
    input: LayoutInput,
    finalParentSize: Size<Float?>,
    outerWidth: Float,
    outerHeight: Float
) -> LayoutOutput {
    var contentMinX: Float = 0
    var contentMinY: Float = 0
    var contentMaxX: Float = ctx.contentBoxInset.left
    var contentMaxY: Float = ctx.contentBoxInset.top
    var firstBaselineY: Float? = nil

    if input.runMode == .performLayout {
        let firstLine = ctx.isWrapReverse ? lines.last : lines.first
        let firstBaselineIndex = firstLine.flatMap { line in
            if ctx.isRow {
                return line.itemRange.first { items[$0].participatesInBaseline(ctx) } ?? line.itemRange.first
            }
            return ctx.dir.isReverse ? line.itemRange.last : line.itemRange.first
        }
        for idx in items.indices {
            flexLayoutSingleChild(
                tree: tree,
                ctx: ctx,
                item: items[idx],
                finalParentSize: finalParentSize,
                contentMinX: &contentMinX,
                contentMinY: &contentMinY,
                contentMaxX: &contentMaxX,
                contentMaxY: &contentMaxY,
                selectsBaseline: idx == firstBaselineIndex, firstBaselineY: &firstBaselineY
            )
        }
    }

    return LayoutOutput(
        size: Size(width: outerWidth, height: outerHeight),
        contentSize: Size(
            width: Swift.max(outerWidth, contentMaxX + ctx.contentBoxInset.right),
            height: Swift.max(outerHeight, contentMaxY + ctx.contentBoxInset.bottom)
        ),
        firstBaselines: Point(x: nil, y: firstBaselineY),
        scrollOverflowOrigin: Point(x: contentMinX, y: contentMinY)
    )
}

private func flexFinalChildInput(target: Size<Float>, parent: Size<Float?>) -> LayoutInput {
    LayoutInput(runMode: .performLayout, sizingMode: .contentSize, axis: .both,
                knownDimensions: Size(width: target.width, height: target.height), parentSize: parent,
                availableSpace: Size(width: .definite(target.width), height: .definite(target.height)),
                verticalMarginsAreCollapsible: .false)
}

private func flexLayoutSingleChild(
    tree: any LayoutTree,
    ctx: FlexContainerContext,
    item: FlexItem,
    finalParentSize: Size<Float?>,
    contentMinX: inout Float,
    contentMinY: inout Float,
    contentMaxX: inout Float,
    contentMaxY: inout Float,
    selectsBaseline: Bool, firstBaselineY: inout Float?
) {
    let targetW = item.targetSize.width
    let targetH = item.targetSize.height

    let childOut = computeNodeLayout(tree: tree, node: item.node,
                                     input: flexFinalChildInput(target: item.targetSize, parent: finalParentSize))

    var x = ctx.contentBoxInset.left + (ctx.isRow ? item.offsetMain : item.offsetCross)
    var y = ctx.contentBoxInset.top + (ctx.isRow ? item.offsetCross : item.offsetMain)

    if item.position == .relative {
        let offset = item.inset.relativeOffset(in: finalParentSize, rtl: ctx.isRTL)
        x += offset.x
        y += offset.y
    }

    contentMinX = Swift.min(contentMinX, x)
    contentMinY = Swift.min(contentMinY, y)
    if childOut.scrollOverflowOrigin != .zero {
        let childOverflow = tree.style(item.node).overflow
        if childOverflow.x == .visible {
            contentMinX = Swift.min(contentMinX, x + childOut.scrollOverflowOrigin.x)
        }
        if childOverflow.y == .visible {
            contentMinY = Swift.min(contentMinY, y + childOut.scrollOverflowOrigin.y)
        }
    }
    contentMaxX = Swift.max(contentMaxX, x + targetW)
    contentMaxY = Swift.max(contentMaxY, y + targetH)
    if selectsBaseline {
        let first = childOut.firstBaselines.y ?? targetH
        firstBaselineY = y + (tree.style(item.node).overflow.y.isScrollContainer
            ? Swift.max(0, Swift.min(first, targetH)) : first)
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
