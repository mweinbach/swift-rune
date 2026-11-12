// MARK: - CSS Flexbox Level 1 Layout Algorithm

private struct FlexItem {
    var node: NodeId
    var order: UInt32
    var style: TaffyStyle

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

internal func computeFlexboxLayout(
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

    if input.runMode == .computeSize, let w = known.width, let h = known.height {
        let clamped = Size(
            width: maybeClamp(Swift.max(w, pbSum.width + scrollbarSize.width), min: minSize.width, max: maxSize.width),
            height: maybeClamp(Swift.max(h, pbSum.height + scrollbarSize.height), min: minSize.height, max: maxSize.height)
        )
        return LayoutOutput.fromOuterSize(clamped)
    }

    let dir = style.flexDirection
    let isRow = dir.isRow
    let isWrapReverse = style.flexWrap == .wrapReverse

    let innerPB = Size(width: contentBoxInset.horizontalSum, height: contentBoxInset.verticalSum)
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

    // 1. Collect in-flow flex items
    let childCount = tree.childCount(node)
    var items: [FlexItem] = []
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
            style: cStyle,
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

    // 2. Determine flex base size & hypothetical main size for each item
    let containerMainMax = maxSize.main(direction: dir).map { Swift.max(0, $0 - innerPB.main(direction: dir)) }
    let containerMainMin = minSize.main(direction: dir).map { Swift.max(0, $0 - innerPB.main(direction: dir)) }

    for idx in items.indices {
        var item = items[idx]
        let cPb = item.padding.sumAxes + item.border.sumAxes
        let cAdj = item.style.contentBoxAdjustment(paddingBorderSum: cPb)

        let childMainParent = nodeInnerSize.main(direction: dir)
        let childCrossParent = nodeInnerSize.cross(direction: dir)

        let resolvedBasis = item.style.flexBasis.maybeResolve(childMainParent).map { $0 + cAdj.main(direction: dir) }

        var basis: Float
        if let rb = resolvedBasis {
            basis = rb
        } else if let sm = item.size.main(direction: dir) {
            basis = sm
        } else if let ratio = item.style.aspectRatio, ratio > 0, ratio.isFinite,
                  let crossSize = item.size.cross(direction: dir) {
            basis = isRow ? (crossSize * ratio) : (crossSize / ratio)
        } else {
            // Measure item's max-content size along main axis
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

        // Minimum main size for min-width/height: auto
        let styleMinMain = item.minSize.main(direction: dir)
        let resolvedMinMain: Float
        if let explicitMin = styleMinMain {
            resolvedMinMain = explicitMin
        } else {
            let overflowMain = isRow ? item.style.overflow.x : item.style.overflow.y
            if overflowMain == .visible {
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
        }

        let pbMain = item.padding.mainAxisSum(direction: dir) + item.border.mainAxisSum(direction: dir)
        basis = Swift.max(basis, pbMain)
        let clampedMinMain = Swift.max(resolvedMinMain, pbMain)
        let hypotheticalMain = maybeClamp(basis, min: clampedMinMain, max: item.maxSize.main(direction: dir))

        item.flexBasis = basis
        item.innerFlexBasis = Swift.max(0, basis - pbMain)
        item.resolvedMinimumMainSize = clampedMinMain

        let marginMainSum = (item.margin.mainStart(direction: dir) ?? 0) + (item.margin.mainEnd(direction: dir) ?? 0)
        item.hypotheticalInnerSize.setMain(hypotheticalMain, direction: dir)
        item.hypotheticalOuterSize.setMain(hypotheticalMain + marginMainSum, direction: dir)

        // Ensure cross hypothetical is initialized if known
        if let sc = item.size.cross(direction: dir) {
            let clampedCross = maybeClamp(sc, min: item.minSize.cross(direction: dir), max: item.maxSize.cross(direction: dir))
            item.hypotheticalInnerSize.setCross(clampedCross, direction: dir)
            let marginCrossSum = (item.margin.crossStart(direction: dir) ?? 0) + (item.margin.crossEnd(direction: dir) ?? 0)
            item.hypotheticalOuterSize.setCross(clampedCross + marginCrossSum, direction: dir)
        }

        _ = childCrossParent
        items[idx] = item
    }

    // 3. Determine container main size
    let containerMainAvail = availInner.main(direction: dir)
    let lineBreakMainMax: Float?
    if let nm = nodeInnerSize.main(direction: dir) {
        lineBreakMainMax = nm
    } else if case .definite(let d) = containerMainAvail {
        lineBreakMainMax = maybeClamp(d, min: containerMainMin, max: containerMainMax)
    } else {
        lineBreakMainMax = containerMainMax
    }

    // 4. Collect flex items into flex lines
    var lines: [FlexLine] = []
    if !items.isEmpty {
        if style.flexWrap == .noWrap {
            lines.append(FlexLine(itemRange: 0..<items.count))
        } else {
            var lineStart = 0
            var lineMainSum: Float = 0
            for i in items.indices {
                let itemOuterMain = items[i].hypotheticalOuterSize.main(direction: dir)
                let gapBefore = (i > lineStart) ? mainGap : 0
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

    // Compute container inner main size if not yet definite
    let resolvedInnerMain: Float
    if let nm = nodeInnerSize.main(direction: dir) {
        resolvedInnerMain = nm
    } else {
        var maxLineMain: Float = 0
        for line in lines {
            var lineSum: Float = 0
            for i in line.itemRange {
                if i > line.itemRange.lowerBound { lineSum += mainGap }
                lineSum += items[i].hypotheticalOuterSize.main(direction: dir)
            }
            maxLineMain = Swift.max(maxLineMain, lineSum)
        }
        switch containerMainAvail {
        case .minContent:
            resolvedInnerMain = maybeClamp(maxLineMain, min: containerMainMin, max: containerMainMax)
        case .maxContent:
            resolvedInnerMain = maybeClamp(maxLineMain, min: containerMainMin, max: containerMainMax)
        case .definite(let avail):
            // For definite available space with auto size, flex container shrinks/grows up to available space or content
            if input.sizingMode == .contentSize {
                resolvedInnerMain = maybeClamp(maxLineMain, min: containerMainMin, max: containerMainMax)
            } else {
                resolvedInnerMain = maybeClamp(Swift.min(avail, maxLineMain), min: containerMainMin, max: containerMainMax)
            }
        }
    }

    // 5. Resolve flexible lengths (CSS Flexbox 9.7) per line
    for line in lines {
        let lineCount = line.itemRange.count
        let totalGap = mainGap * Float(Swift.max(0, lineCount - 1))

        var usedMain: Float = totalGap
        for i in line.itemRange {
            let marginMain = (items[i].margin.mainStart(direction: dir) ?? 0) + (items[i].margin.mainEnd(direction: dir) ?? 0)
            usedMain += items[i].hypotheticalInnerSize.main(direction: dir) + marginMain
        }
        let growing = usedMain < resolvedInnerMain

        var sumHypothetical: Float = totalGap
        var sumFlexBase: Float = totalGap
        for i in line.itemRange {
            let marginMain = (items[i].margin.mainStart(direction: dir) ?? 0) + (items[i].margin.mainEnd(direction: dir) ?? 0)
            sumHypothetical += items[i].hypotheticalInnerSize.main(direction: dir) + marginMain
            sumFlexBase += items[i].flexBasis + marginMain
            items[i].frozen = false
            items[i].targetSize.setMain(items[i].hypotheticalInnerSize.main(direction: dir), direction: dir)
        }

        // Freeze inflexible items
        for i in line.itemRange {
            let flexFactor = growing ? items[i].style.flexGrow : items[i].style.flexShrink
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
                    unfrozenFlexSum += growing ? items[i].style.flexGrow : items[i].style.flexShrink
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
                    let share = items[i].style.flexGrow / unfrozenFlexSum
                    items[i].targetSize.setMain(items[i].flexBasis + remainingFree * share, direction: dir)
                }
            } else if !growing && remainingFree < 0 {
                var scaledShrinkSum: Float = 0
                for i in line.itemRange where !items[i].frozen {
                    scaledShrinkSum += items[i].style.flexShrink * items[i].innerFlexBasis
                }
                if scaledShrinkSum > 0 {
                    for i in line.itemRange where !items[i].frozen {
                        let ratio = (items[i].style.flexShrink * items[i].innerFlexBasis) / scaledShrinkSum
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

            // Clamp and check violations
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

    // 6. Determine hypothetical cross size of each item
    let containerCrossInner = nodeInnerSize.cross(direction: dir)
    for idx in items.indices {
        var item = items[idx]
        let targetMain = item.targetSize.main(direction: dir)
        var targetCross = item.size.cross(direction: dir)

        if targetCross == nil, let ratio = item.style.aspectRatio, ratio > 0, ratio.isFinite {
            targetCross = isRow ? (targetMain / ratio) : (targetMain * ratio)
        }

        if let tc = targetCross {
            let clamped = maybeClamp(tc, min: item.minSize.cross(direction: dir), max: item.maxSize.cross(direction: dir))
            item.hypotheticalInnerSize.setCross(clamped, direction: dir)
            item.targetSize.setCross(clamped, direction: dir)
        } else {
            var knownDims = Size<Float?>(width: nil, height: nil)
            knownDims.setMain(targetMain, direction: dir)
            var childAvail = availInner
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
            let baselineVal = isRow ? (out.firstBaselines.y ?? clamped) : (out.firstBaselines.x ?? clamped)
            item.baseline = baselineVal
        }

        let marginCross = (item.margin.crossStart(direction: dir) ?? 0) + (item.margin.crossEnd(direction: dir) ?? 0)
        item.hypotheticalOuterSize.setCross(item.hypotheticalInnerSize.cross(direction: dir) + marginCross, direction: dir)
        item.outerTargetSize.setCross(item.hypotheticalOuterSize.cross(direction: dir), direction: dir)
        items[idx] = item
    }

    // 7. Calculate cross size of each flex line
    let containerAlignItems = style.alignItems ?? .stretch
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
                let align = item.style.alignSelf ?? containerAlignItems
                let marginCrossStart = item.margin.crossStart(direction: dir) ?? 0
                let marginCrossEnd = item.margin.crossEnd(direction: dir) ?? 0
                let outerCross = item.hypotheticalOuterSize.cross(direction: dir)

                if align == .baseline && !item.marginIsAuto.crossStart(direction: dir) && !item.marginIsAuto.crossEnd(direction: dir) {
                    let ascent = item.baseline + marginCrossStart
                    let descent = outerCross - ascent
                    maxAscent = Swift.max(maxAscent, ascent)
                    maxDescent = Swift.max(maxDescent, descent)
                } else {
                    maxNonBaseline = Swift.max(maxNonBaseline, outerCross)
                }
                _ = marginCrossEnd
            }
            lines[lineIdx].crossSize = Swift.max(maxNonBaseline, maxAscent + maxDescent)
        }
    }

    // Determine container cross size
    let totalLinesCross = lines.reduce(Float(0)) { $0 + $1.crossSize } + crossGap * Float(Swift.max(0, lines.count - 1))
    let containerCrossMin = minSize.cross(direction: dir).map { Swift.max(0, $0 - innerPB.cross(direction: dir)) }
    let containerCrossMax = maxSize.cross(direction: dir).map { Swift.max(0, $0 - innerPB.cross(direction: dir)) }
    let resolvedInnerCross = containerCrossInner ?? maybeClamp(totalLinesCross, min: containerCrossMin, max: containerCrossMax)

    // 8. Align-content: distribute cross space among lines
    if !lines.isEmpty {
        let freeCross = resolvedInnerCross - totalLinesCross
        let alignContent = style.alignContent ?? .stretch
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
            curCross = isWrapReverse ? remCross : 0
        case .flexEnd:
            curCross = isWrapReverse ? 0 : remCross
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

        let lineIndices = isWrapReverse ? Array(lines.indices.reversed()) : Array(lines.indices)
        for l in lineIndices {
            lines[l].offsetCross = curCross
            curCross += lines[l].crossSize + crossGap + extraGap
        }
    }

    // 9. Stretch items with align-self: stretch & auto cross size, then resolve final cross sizes
    for line in lines {
        for i in line.itemRange {
            let align = items[i].style.alignSelf ?? containerAlignItems
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

    // 10. Main-axis positioning (auto margins + justify-content) & Cross-axis positioning
    let outerWidth = maybeClamp(
        known.width ?? ((isRow ? resolvedInnerMain : resolvedInnerCross) + innerPB.width),
        min: minSize.width,
        max: maxSize.width
    )
    let outerHeight = maybeClamp(
        known.height ?? ((isRow ? resolvedInnerCross : resolvedInnerMain) + innerPB.height),
        min: minSize.height,
        max: maxSize.height
    )
    let finalParentSize = Size<Float?>(
        width: Swift.max(0, outerWidth - innerPB.width),
        height: Swift.max(0, outerHeight - innerPB.height)
    )

    let justify = style.justifyContent ?? .flexStart
    let isMainReverse = dir.isReverse
    var contentMaxX: Float = contentBoxInset.left
    var contentMaxY: Float = contentBoxInset.top
    var firstBaselineY: Float? = nil

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
                    if isRow { items[i].margin.left = dir == .row ? perAuto : items[i].margin.left }
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

        // Compute max baseline in line for baseline alignment
        var maxLineBaseline: Float = 0
        for i in range {
            let align = items[i].style.alignSelf ?? containerAlignItems
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

            // Cross-axis alignment within line
            let itemCross = items[i].targetSize.cross(direction: dir)
            let mCrossStart = items[i].margin.crossStart(direction: dir)
            let mCrossEnd = items[i].margin.crossEnd(direction: dir)
            let freeCross = line.crossSize - itemCross - (mCrossStart ?? 0) - (mCrossEnd ?? 0)

            var offsetInLine: Float
            if mCrossStart == nil && mCrossEnd == nil {
                offsetInLine = Swift.max(0, freeCross) * 0.5
            } else if mCrossStart == nil {
                offsetInLine = Swift.max(0, freeCross)
            } else if mCrossEnd == nil {
                offsetInLine = mCrossStart ?? 0
            } else {
                let align = items[i].style.alignSelf ?? containerAlignItems
                let startMargin = mCrossStart ?? 0
                switch align {
                case .flexStart, .normal, .stretch:
                    offsetInLine = isWrapReverse ? (startMargin + freeCross) : startMargin
                case .flexEnd:
                    offsetInLine = isWrapReverse ? startMargin : (startMargin + freeCross)
                case .start, .selfStart:
                    offsetInLine = startMargin
                case .end, .selfEnd:
                    offsetInLine = startMargin + freeCross
                case .center:
                    offsetInLine = startMargin + freeCross * 0.5
                case .baseline:
                    offsetInLine = isWrapReverse
                        ? (startMargin + freeCross)
                        : (maxLineBaseline - items[i].baseline)
                }
            }
            items[i].offsetCross = line.offsetCross + offsetInLine
        }
    }

    // 11. Final PerformLayout pass on children
    if input.runMode == .performLayout {
        for idx in items.indices {
            let item = items[idx]
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

            var x = contentBoxInset.left + (isRow ? item.offsetMain : item.offsetCross)
            var y = contentBoxInset.top + (isRow ? item.offsetCross : item.offsetMain)

            if item.style.position == .relative {
                if let l = item.style.inset.left.maybeResolve(finalParentSize.width) {
                    x += l
                } else if let r = item.style.inset.right.maybeResolve(finalParentSize.width) {
                    x -= r
                }
                if let t = item.style.inset.top.maybeResolve(finalParentSize.height) {
                    y += t
                } else if let b = item.style.inset.bottom.maybeResolve(finalParentSize.height) {
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
    }

    return LayoutOutput(
        size: Size(width: outerWidth, height: outerHeight),
        contentSize: Size(
            width: Swift.max(outerWidth, contentMaxX + contentBoxInset.right),
            height: Swift.max(outerHeight, contentMaxY + contentBoxInset.bottom)
        ),
        firstBaselines: Point(x: nil, y: firstBaselineY)
    )
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
