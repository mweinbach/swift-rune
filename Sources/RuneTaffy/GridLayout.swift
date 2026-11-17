// MARK: - CSS Grid Layout Algorithm

private struct GridTrack {
    var sizing: TrackSizingFunction
    var baseSize: Float = 0
    var growthLimit: Float = .infinity
    var isCollapsed: Bool = false
    var offset: Float = 0
}

private struct GridItem {
    var node: NodeId
    var order: UInt32
    var style: TaffyStyle

    var rowStart: Int = 0
    var rowEnd: Int = 1
    var colStart: Int = 0
    var colEnd: Int = 1

    var padding: Rect<Float>
    var border: Rect<Float>
    var margin: Rect<Float?>
}

private struct GridOccupancy {
    var cols: Int
    var rows: Int
    var occupied: [Bool]

    init(rows: Int, cols: Int) {
        self.rows = Swift.max(1, rows)
        self.cols = Swift.max(1, cols)
        self.occupied = Array(repeating: false, count: self.rows * self.cols)
    }

    mutating func ensureSize(rows newRows: Int, cols newCols: Int) {
        let r = Swift.max(rows, newRows)
        let c = Swift.max(cols, newCols)
        if r == rows && c == cols { return }
        var next = Array(repeating: false, count: r * c)
        for rr in 0..<rows {
            for cc in 0..<cols {
                next[rr * c + cc] = occupied[rr * cols + cc]
            }
        }
        rows = r
        cols = c
        occupied = next
    }

    func isFree(rowRange: Range<Int>, colRange: Range<Int>) -> Bool {
        for r in rowRange {
            if r >= rows { continue }
            for c in colRange {
                if c >= cols { continue }
                if occupied[r * cols + c] { return false }
            }
        }
        return true
    }

    mutating func mark(rowRange: Range<Int>, colRange: Range<Int>) {
        ensureSize(rows: rowRange.upperBound, cols: colRange.upperBound)
        for r in rowRange {
            for c in colRange {
                occupied[r * cols + c] = true
            }
        }
    }
}

internal func computeGridLayout(
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
    let innerPB = Size(width: contentBoxInset.horizontalSum, height: contentBoxInset.verticalSum)

    let minSize = style.resolveMinSize(parent: parentSize, adjustment: adj)
    let maxSize = style.resolveMaxSize(parent: parentSize, adjustment: adj)

    let styleSize: Size<Float?>
    if input.sizingMode == .inherentSize {
        styleSize = style.resolveSize(parent: parentSize, adjustment: adj)
    } else {
        styleSize = .none
    }

    var known = Size(
        width: input.knownDimensions.width ?? styleSize.width.map { maybeClamp($0, min: minSize.width, max: maxSize.width) },
        height: input.knownDimensions.height ?? styleSize.height.map { maybeClamp($0, min: minSize.height, max: maxSize.height) }
    )
    known = applyAspectRatio(known, style.aspectRatio)

    if input.runMode == .computeSize, let w = known.width, let h = known.height {
        let clamped = Size(
            width: maybeClamp(Swift.max(w, pbSum.width + scrollbarSize.width), min: minSize.width, max: maxSize.width),
            height: maybeClamp(Swift.max(h, pbSum.height + scrollbarSize.height), min: minSize.height, max: maxSize.height)
        )
        return LayoutOutput.fromOuterSize(clamped)
    }

    let innerAvailW = input.availableSpace.width.maybeSet(known.width).maybeSub(innerPB.width).mapDefiniteValue { Swift.max(0, $0) }
    let innerAvailH = input.availableSpace.height.maybeSet(known.height).maybeSub(innerPB.height).mapDefiniteValue { Swift.max(0, $0) }

    let nodeInnerSize = Size<Float?>(
        width: known.width.map { Swift.max(0, $0 - innerPB.width) },
        height: known.height.map { Swift.max(0, $0 - innerPB.height) }
    )

    let colGap = style.gap.width.resolveOrZero(nodeInnerSize.width)
    let rowGap = style.gap.height.resolveOrZero(nodeInnerSize.height)

    // 1. Expand explicit template tracks (handling repeat(N), auto-fill, auto-fit)
    let (explicitCols, colAutoFitFlags) = expandTemplateTracks(
        components: style.gridTemplateColumns,
        containerSize: nodeInnerSize.width ?? innerAvailW.definiteValue,
        maxContainerSize: maxSize.width.map { Swift.max(0, $0 - innerPB.width) },
        gap: colGap
    )
    let (explicitRows, rowAutoFitFlags) = expandTemplateTracks(
        components: style.gridTemplateRows,
        containerSize: nodeInnerSize.height ?? innerAvailH.definiteValue,
        maxContainerSize: maxSize.height.map { Swift.max(0, $0 - innerPB.height) },
        gap: rowGap
    )

    // Build line-name lookup from gridTemplateAreas + explicit line names
    var colLineNames = buildLineNameMap(explicitCount: explicitCols.count, explicitNames: style.gridTemplateColumnNames)
    var rowLineNames = buildLineNameMap(explicitCount: explicitRows.count, explicitNames: style.gridTemplateRowNames)
    var maxAreaCol = explicitCols.count
    var maxAreaRow = explicitRows.count
    for area in style.gridTemplateAreas {
        let rS = Int(area.rowStart)
        let rE = Int(area.rowEnd)
        let cS = Int(area.columnStart)
        let cE = Int(area.columnEnd)
        maxAreaRow = Swift.max(maxAreaRow, rE)
        maxAreaCol = Swift.max(maxAreaCol, cE)
        rowLineNames["\(area.name)-start", default: []].append(rS)
        rowLineNames["\(area.name)-end", default: []].append(rE)
        colLineNames["\(area.name)-start", default: []].append(cS)
        colLineNames["\(area.name)-end", default: []].append(cE)
    }

    // 2. Collect in-flow grid items
    let childCount = tree.childCount(node)
    var items: [GridItem] = []
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
        items.append(GridItem(
            node: child,
            order: orderCounter,
            style: cStyle,
            padding: cStyle.resolvedPadding(parentWidth: nodeInnerSize.width),
            border: cStyle.resolvedBorder(parentWidth: nodeInnerSize.width),
            margin: cStyle.resolvedMargin(parentWidth: nodeInnerSize.width)
        ))
        orderCounter += 1
    }

    // 3. Place grid items (CSS Grid 8.5)
    let explicitColCount = Swift.max(explicitCols.count, maxAreaCol)
    let explicitRowCount = Swift.max(explicitRows.count, maxAreaRow)
    var occupancy = GridOccupancy(rows: Swift.max(1, explicitRowCount), cols: Swift.max(1, explicitColCount))

    var minColOrigin = 0
    var minRowOrigin = 0

    // Resolve definite placements first to find any negative-origin shifts
    var resolvedRows: [(start: Int?, end: Int?, span: Int)] = Array(repeating: (nil, nil, 1), count: items.count)
    var resolvedCols: [(start: Int?, end: Int?, span: Int)] = Array(repeating: (nil, nil, 1), count: items.count)

    for idx in items.indices {
        let r = resolvePlacementLine(
            line: items[idx].style.gridRow,
            explicitCount: explicitRowCount,
            lineNames: rowLineNames
        )
        let c = resolvePlacementLine(
            line: items[idx].style.gridColumn,
            explicitCount: explicitColCount,
            lineNames: colLineNames
        )
        resolvedRows[idx] = r
        resolvedCols[idx] = c
        if let rs = r.start { minRowOrigin = Swift.min(minRowOrigin, rs) }
        if let cs = c.start { minColOrigin = Swift.min(minColOrigin, cs) }
    }

    let rowShift = -minRowOrigin
    let colShift = -minColOrigin

    // Shift definite indices so minimum index is 0
    for idx in items.indices {
        if let s = resolvedRows[idx].start { resolvedRows[idx].start = s + rowShift }
        if let e = resolvedRows[idx].end { resolvedRows[idx].end = e + rowShift }
        if let s = resolvedCols[idx].start { resolvedCols[idx].start = s + colShift }
        if let e = resolvedCols[idx].end { resolvedCols[idx].end = e + colShift }
    }

    // Pass 1: Items with definite row AND definite column
    for idx in items.indices {
        if let rs = resolvedRows[idx].start, let re = resolvedRows[idx].end,
           let cs = resolvedCols[idx].start, let ce = resolvedCols[idx].end {
            items[idx].rowStart = rs
            items[idx].rowEnd = Swift.max(rs + 1, re)
            items[idx].colStart = cs
            items[idx].colEnd = Swift.max(cs + 1, ce)
            occupancy.mark(rowRange: items[idx].rowStart..<items[idx].rowEnd, colRange: items[idx].colStart..<items[idx].colEnd)
        }
    }

    // Pass 2: Items with definite primary axis only
    let isRowFlow = style.gridAutoFlow.isRow
    let isDense = style.gridAutoFlow.isDense

    for idx in items.indices {
        let r = resolvedRows[idx]
        let c = resolvedCols[idx]
        let hasDefRow = r.start != nil && r.end != nil
        let hasDefCol = c.start != nil && c.end != nil
        if hasDefRow == hasDefCol { continue } // Either both (already placed) or neither

        if hasDefRow, let rs = r.start, let re = r.end {
            let spanC = c.span
            var col = 0
            while !occupancy.isFree(rowRange: rs..<re, colRange: col..<(col + spanC)) {
                col += 1
            }
            items[idx].rowStart = rs
            items[idx].rowEnd = re
            items[idx].colStart = col
            items[idx].colEnd = col + spanC
            occupancy.mark(rowRange: rs..<re, colRange: col..<(col + spanC))
        } else if hasDefCol, let cs = c.start, let ce = c.end {
            let spanR = r.span
            var row = 0
            while !occupancy.isFree(rowRange: row..<(row + spanR), colRange: cs..<ce) {
                row += 1
            }
            items[idx].rowStart = row
            items[idx].rowEnd = row + spanR
            items[idx].colStart = cs
            items[idx].colEnd = ce
            occupancy.mark(rowRange: row..<(row + spanR), colRange: cs..<ce)
        }
    }

    // Pass 3: Auto-placed items
    let maxColBound = Swift.max(occupancy.cols, explicitColCount + colShift)
    let maxRowBound = Swift.max(occupancy.rows, explicitRowCount + rowShift)
    var cursorRow = 0
    var cursorCol = 0

    for idx in items.indices {
        let r = resolvedRows[idx]
        let c = resolvedCols[idx]
        if (r.start != nil && r.end != nil) || (c.start != nil && c.end != nil) {
            continue
        }

        let spanR = r.span
        let spanC = c.span

        if isRowFlow {
            let gridCols = Swift.max(maxColBound, spanC)
            var searchR = isDense ? 0 : cursorRow
            var searchC = isDense ? 0 : cursorCol
            while true {
                if searchC + spanC > gridCols {
                    searchR += 1
                    searchC = 0
                }
                if occupancy.isFree(rowRange: searchR..<(searchR + spanR), colRange: searchC..<(searchC + spanC)) {
                    items[idx].rowStart = searchR
                    items[idx].rowEnd = searchR + spanR
                    items[idx].colStart = searchC
                    items[idx].colEnd = searchC + spanC
                    occupancy.mark(rowRange: searchR..<(searchR + spanR), colRange: searchC..<(searchC + spanC))
                    cursorRow = searchR
                    cursorCol = searchC + spanC
                    break
                }
                searchC += 1
            }
        } else {
            let gridRows = Swift.max(maxRowBound, spanR)
            var searchR = isDense ? 0 : cursorRow
            var searchC = isDense ? 0 : cursorCol
            while true {
                if searchR + spanR > gridRows {
                    searchC += 1
                    searchR = 0
                }
                if occupancy.isFree(rowRange: searchR..<(searchR + spanR), colRange: searchC..<(searchC + spanC)) {
                    items[idx].rowStart = searchR
                    items[idx].rowEnd = searchR + spanR
                    items[idx].colStart = searchC
                    items[idx].colEnd = searchC + spanC
                    occupancy.mark(rowRange: searchR..<(searchR + spanR), colRange: searchC..<(searchC + spanC))
                    cursorCol = searchC
                    cursorRow = searchR + spanR
                    break
                }
                searchR += 1
            }
        }
    }

    // 4. Build final track vectors (implicit before + explicit + implicit after)
    let totalCols = Swift.max(occupancy.cols, explicitColCount + colShift)
    let totalRows = Swift.max(occupancy.rows, explicitRowCount + rowShift)

    var colTracks = buildTrackVector(
        totalCount: totalCols,
        explicitStart: colShift,
        explicitTracks: explicitCols,
        autoFitFlags: colAutoFitFlags,
        autoTracks: style.gridAutoColumns,
        occupancy: occupancy,
        isColumn: true
    )
    var rowTracks = buildTrackVector(
        totalCount: totalRows,
        explicitStart: rowShift,
        explicitTracks: explicitRows,
        autoFitFlags: rowAutoFitFlags,
        autoTracks: style.gridAutoRows,
        occupancy: occupancy,
        isColumn: false
    )

    // 5. Track sizing algorithm for columns, then rows
    sizeTracks(
        tracks: &colTracks,
        otherTracks: rowTracks,
        items: items,
        isColumn: true,
        containerInnerSize: nodeInnerSize.width,
        availableSpace: innerAvailW,
        otherAvailableSpace: innerAvailH,
        gap: colGap,
        otherGap: rowGap,
        parentInnerSize: nodeInnerSize,
        alignContent: style.justifyContent ?? .normal,
        tree: tree
    )

    sizeTracks(
        tracks: &rowTracks,
        otherTracks: colTracks,
        items: items,
        isColumn: false,
        containerInnerSize: nodeInnerSize.height,
        availableSpace: innerAvailH,
        otherAvailableSpace: innerAvailW,
        gap: rowGap,
        otherGap: colGap,
        parentInnerSize: nodeInnerSize,
        alignContent: style.alignContent ?? .normal,
        tree: tree
    )

    // Compute final container size
    let totalColWidth = sumTrackSizes(colTracks, gap: colGap)
    let totalRowHeight = sumTrackSizes(rowTracks, gap: rowGap)

    let outerWidth = maybeClamp(
        known.width ?? (totalColWidth + innerPB.width),
        min: minSize.width,
        max: maxSize.width
    )
    let outerHeight = maybeClamp(
        known.height ?? (totalRowHeight + innerPB.height),
        min: minSize.height,
        max: maxSize.height
    )
    let finalInnerW = Swift.max(0, outerWidth - innerPB.width)
    let finalInnerH = Swift.max(0, outerHeight - innerPB.height)

    // Align tracks (justify-content & align-content)
    alignTracks(tracks: &colTracks, containerInnerSize: finalInnerW, gap: colGap, alignContent: style.justifyContent ?? .normal, startOffset: contentBoxInset.left)
    alignTracks(tracks: &rowTracks, containerInnerSize: finalInnerH, gap: rowGap, alignContent: style.alignContent ?? .normal, startOffset: contentBoxInset.top)

    // 6. Position & layout each grid item
    var contentMaxX: Float = contentBoxInset.left
    var contentMaxY: Float = contentBoxInset.top
    var firstBaselineY: Float? = nil

    if input.runMode == .performLayout {
        let defaultJustifyItems = style.justifyItems ?? .stretch
        let defaultAlignItems = style.alignItems ?? .stretch

        for item in items {
            let areaX = colTracks[item.colStart].offset
            let areaEndX = colTracks[item.colEnd - 1].offset + colTracks[item.colEnd - 1].baseSize
            let areaW = Swift.max(0, areaEndX - areaX)

            let areaY = rowTracks[item.rowStart].offset
            let areaEndY = rowTracks[item.rowEnd - 1].offset + rowTracks[item.rowEnd - 1].baseSize
            let areaH = Swift.max(0, areaEndY - areaY)

            let cPb = item.padding.sumAxes + item.border.sumAxes
            let cAdj = item.style.contentBoxAdjustment(paddingBorderSum: cPb)

            let minW = item.style.minSize.width.maybeResolve(areaW).map { $0 + cAdj.width }
            let maxW = item.style.maxSize.width.maybeResolve(areaW).map { $0 + cAdj.width }
            let minH = item.style.minSize.height.maybeResolve(areaH).map { $0 + cAdj.height }
            let maxH = item.style.maxSize.height.maybeResolve(areaH).map { $0 + cAdj.height }

            let mL = item.margin.left
            let mR = item.margin.right
            let mT = item.margin.top
            let mB = item.margin.bottom

            let justify = item.style.justifySelf ?? defaultJustifyItems
            let align = item.style.alignSelf ?? defaultAlignItems

            var targetW = item.style.size.width.maybeResolve(areaW).map { $0 + cAdj.width }
            var targetH = item.style.size.height.maybeResolve(areaH).map { $0 + cAdj.height }

            if targetW == nil && (justify == .stretch || justify == .normal) && mL != nil && mR != nil && !item.style.itemIsReplaced {
                targetW = Swift.max(0, areaW - (mL ?? 0) - (mR ?? 0))
            }
            if targetH == nil && (align == .stretch || align == .normal) && mT != nil && mB != nil && !item.style.itemIsReplaced {
                targetH = Swift.max(0, areaH - (mT ?? 0) - (mB ?? 0))
            }

            targetW = targetW.map { maybeClamp($0, min: minW, max: maxW) }
            targetH = targetH.map { maybeClamp($0, min: minH, max: maxH) }
            let ratioed = applyAspectRatio(Size(width: targetW, height: targetH), item.style.aspectRatio)
            targetW = ratioed.width
            targetH = ratioed.height

            let childOut = computeNodeLayout(
                tree: tree,
                node: item.node,
                input: LayoutInput(
                    runMode: .performLayout,
                    sizingMode: .inherentSize,
                    axis: .both,
                    knownDimensions: Size(width: targetW, height: targetH),
                    parentSize: Size(width: areaW, height: areaH),
                    availableSpace: Size(width: .definite(Swift.max(0, areaW - (mL ?? 0) - (mR ?? 0))), height: .definite(Swift.max(0, areaH - (mT ?? 0) - (mB ?? 0)))),
                    verticalMarginsAreCollapsible: .false
                )
            )

            let finalW = maybeClamp(targetW ?? childOut.size.width, min: minW, max: maxW)
            let finalH = maybeClamp(targetH ?? childOut.size.height, min: minH, max: maxH)

            let (offsetX, resolvedML, resolvedMR) = alignItemInArea(
                areaSize: areaW,
                itemSize: finalW,
                marginStart: mL,
                marginEnd: mR,
                alignment: justify
            )
            let (offsetY, resolvedMT, resolvedMB) = alignItemInArea(
                areaSize: areaH,
                itemSize: finalH,
                marginStart: mT,
                marginEnd: mB,
                alignment: align
            )

            var x = areaX + offsetX
            var y = areaY + offsetY

            if item.style.position == .relative {
                if let l = item.style.inset.left.maybeResolve(areaW) { x += l }
                else if let r = item.style.inset.right.maybeResolve(areaW) { x -= r }
                if let t = item.style.inset.top.maybeResolve(areaH) { y += t }
                else if let b = item.style.inset.bottom.maybeResolve(areaH) { y -= b }
            }

            contentMaxX = Swift.max(contentMaxX, x + finalW)
            contentMaxY = Swift.max(contentMaxY, y + finalH)
            if firstBaselineY == nil {
                firstBaselineY = y + (childOut.firstBaselines.y ?? finalH)
            }

            tree.setUnroundedLayout(item.node, Layout(
                order: item.order,
                location: Point(x: x, y: y),
                size: Size(width: finalW, height: finalH),
                contentSize: childOut.contentSize,
                scrollbarSize: .zero,
                border: item.border,
                padding: item.padding,
                margin: Rect(left: resolvedML, right: resolvedMR, top: resolvedMT, bottom: resolvedMB)
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

// MARK: - Grid Helpers

private func expandTemplateTracks(
    components: [GridTemplateComponent],
    containerSize: Float?,
    maxContainerSize: Float?,
    gap: Float
) -> (tracks: [TrackSizingFunction], autoFitFlags: [Bool]) {
    var tracks: [TrackSizingFunction] = []
    var autoFitFlags: [Bool] = []

    for comp in components {
        switch comp {
        case .single(let t):
            tracks.append(t)
            autoFitFlags.append(false)
        case .repeat(let count, let list):
            guard !list.isEmpty else { continue }
            switch count {
            case .count(let n):
                for _ in 0..<n {
                    tracks.append(contentsOf: list)
                    autoFitFlags.append(contentsOf: Array(repeating: false, count: list.count))
                }
            case .autoFill, .autoFit:
                let isFit = (count == .autoFit)
                let repSize = computeAutoRepeatCount(
                    repeatedTracks: list,
                    containerSize: containerSize ?? maxContainerSize,
                    gap: gap
                )
                for _ in 0..<repSize {
                    tracks.append(contentsOf: list)
                    autoFitFlags.append(contentsOf: Array(repeating: isFit, count: list.count))
                }
            }
        }
    }

    return (tracks, autoFitFlags)
}

private func computeAutoRepeatCount(
    repeatedTracks: [TrackSizingFunction],
    containerSize: Float?,
    gap: Float
) -> Int {
    guard let avail = containerSize, avail > 0 else { return 1 }
    var singleRepSize: Float = 0
    for t in repeatedTracks {
        if let v = t.min.definiteValue(avail) {
            singleRepSize += v
        } else if let v = t.max.definiteValue(avail) {
            singleRepSize += v
        } else {
            singleRepSize += 0
        }
    }
    let unit = singleRepSize + gap * Float(repeatedTracks.count)
    if unit <= 0 { return 1 }
    let count = Int(((avail + gap) / unit).rounded(.down))
    return Swift.max(1, count)
}

private func buildLineNameMap(explicitCount: Int, explicitNames: [[String]]) -> [String: [Int]] {
    var map: [String: [Int]] = [:]
    for (idx, names) in explicitNames.enumerated() where idx <= explicitCount {
        for name in names {
            map[name, default: []].append(idx)
        }
    }
    return map
}

private func resolvePlacementLine(
    line: Line<GridPlacement>,
    explicitCount: Int,
    lineNames: [String: [Int]]
) -> (start: Int?, end: Int?, span: Int) {
    func resolvePoint(_ p: GridPlacement) -> (pos: Int?, span: Int?) {
        switch p {
        case .auto:
            return (nil, nil)
        case .line(let n):
            if n > 0 { return (Int(n - 1), nil) }
            if n < 0 { return (explicitCount + 1 + Int(n), nil) }
            return (0, nil)
        case .namedLine(let name, let n):
            let indices = lineNames[name] ?? []
            if indices.isEmpty { return (nil, nil) }
            if n > 0 {
                let idx = Int(n - 1)
                return (idx < indices.count ? indices[idx] : indices.last, nil)
            } else {
                let idx = indices.count + Int(n)
                return (idx >= 0 ? indices[idx] : indices.first, nil)
            }
        case .span(let s):
            return (nil, Swift.max(1, Int(s)))
        case .namedSpan(let name, let s):
            _ = name
            return (nil, Swift.max(1, Int(s)))
        }
    }

    let s = resolvePoint(line.start)
    let e = resolvePoint(line.end)

    switch (s.pos, s.span, e.pos, e.span) {
    case (let sp?, _, let ep?, _):
        let lo = Swift.min(sp, ep)
        let hi = Swift.max(sp + 1, ep)
        return (lo, hi, hi - lo)
    case (let sp?, _, nil, let es?):
        return (sp, sp + es, es)
    case (let sp?, _, nil, nil):
        return (sp, sp + 1, 1)
    case (nil, let ss?, let ep?, _):
        return (ep - ss, ep, ss)
    case (nil, nil, let ep?, _):
        return (ep - 1, ep, 1)
    case (nil, let ss?, nil, _):
        return (nil, nil, ss)
    case (nil, nil, nil, let es?):
        return (nil, nil, es)
    case (nil, nil, nil, nil):
        return (nil, nil, 1)
    }
}

private func buildTrackVector(
    totalCount: Int,
    explicitStart: Int,
    explicitTracks: [TrackSizingFunction],
    autoFitFlags: [Bool],
    autoTracks: [TrackSizingFunction],
    occupancy: GridOccupancy,
    isColumn: Bool
) -> [GridTrack] {
    var result: [GridTrack] = []
    result.reserveCapacity(totalCount)
    for i in 0..<totalCount {
        let expIdx = i - explicitStart
        if expIdx >= 0 && expIdx < explicitTracks.count {
            var track = GridTrack(sizing: explicitTracks[expIdx])
            if autoFitFlags[expIdx] {
                var hasItem = false
                if isColumn {
                    for r in 0..<occupancy.rows where occupancy.occupied[r * occupancy.cols + i] {
                        hasItem = true; break
                    }
                } else {
                    for c in 0..<occupancy.cols where occupancy.occupied[i * occupancy.cols + c] {
                        hasItem = true; break
                    }
                }
                track.isCollapsed = !hasItem
            }
            result.append(track)
        } else if !autoTracks.isEmpty {
            let autoIdx = ((i % autoTracks.count) + autoTracks.count) % autoTracks.count
            result.append(GridTrack(sizing: autoTracks[autoIdx]))
        } else {
            result.append(GridTrack(sizing: .auto))
        }
    }
    return result
}

private func sizeTracks(
    tracks: inout [GridTrack],
    otherTracks: [GridTrack],
    items: [GridItem],
    isColumn: Bool,
    containerInnerSize: Float?,
    availableSpace: AvailableSpace,
    otherAvailableSpace: AvailableSpace,
    gap: Float,
    otherGap: Float,
    parentInnerSize: Size<Float?>,
    alignContent: AlignContent,
    tree: any LayoutTree
) {
    // 1. Initialize base sizes & growth limits
    for i in tracks.indices {
        if tracks[i].isCollapsed {
            tracks[i].baseSize = 0
            tracks[i].growthLimit = 0
            continue
        }
        let minFn = tracks[i].sizing.min
        let maxFn = tracks[i].sizing.max

        tracks[i].baseSize = minFn.definiteValue(containerInnerSize) ?? 0
        if let maxDef = maxFn.definiteValue(containerInnerSize) {
            tracks[i].growthLimit = Swift.max(tracks[i].baseSize, maxDef)
        } else {
            tracks[i].growthLimit = .infinity
        }
    }

    // Helper to measure item intrinsic contribution along `isColumn ? .horizontal : .vertical`
    func measureItem(_ item: GridItem, axis: AbsoluteAxis, sizingMode: SizingMode, avail: AvailableSpace) -> Float {
        var known = Size<Float?>(width: nil, height: nil)
        let otherSpanRange = isColumn ? (item.rowStart..<item.rowEnd) : (item.colStart..<item.colEnd)
        let otherSpanSize = (otherSpanRange.reduce(Float(0)) { $0 + otherTracks[$1].baseSize })
            + otherGap * Float(Swift.max(0, otherSpanRange.count - 1))

        let cPb = item.padding.sumAxes + item.border.sumAxes
        let cAdj = item.style.contentBoxAdjustment(paddingBorderSum: cPb)

        if isColumn {
            known.width = item.style.size.width.maybeResolve(containerInnerSize).map { $0 + cAdj.width }
        } else {
            known.height = item.style.size.height.maybeResolve(containerInnerSize).map { $0 + cAdj.height }
            if !otherTracks.isEmpty {
                let mH = (item.margin.left ?? 0) + (item.margin.right ?? 0)
                known.width = item.style.size.width.maybeResolve(otherSpanSize).map { $0 + cAdj.width }
                    ?? Swift.max(0, otherSpanSize - mH)
            }
        }

        let itemMarginSum = isColumn
            ? ((item.margin.left ?? 0) + (item.margin.right ?? 0))
            : ((item.margin.top ?? 0) + (item.margin.bottom ?? 0))

        let out = computeNodeLayout(
            tree: tree,
            node: item.node,
            input: LayoutInput(
                runMode: .computeSize,
                sizingMode: sizingMode,
                axis: axis == .horizontal ? .horizontal : .vertical,
                knownDimensions: known,
                parentSize: parentInnerSize,
                availableSpace: Size(
                    width: isColumn ? avail : otherAvailableSpace,
                    height: isColumn ? otherAvailableSpace : avail
                ),
                verticalMarginsAreCollapsible: .false
            )
        )
        return (isColumn ? out.size.width : out.size.height) + itemMarginSum
    }

    let axis: AbsoluteAxis = isColumn ? .horizontal : .vertical

    // 2. Resolve intrinsic track sizes
    let sortedItems = items.sorted { a, b in
        let spanA = isColumn ? (a.colEnd - a.colStart) : (a.rowEnd - a.rowStart)
        let spanB = isColumn ? (b.colEnd - b.colStart) : (b.rowEnd - b.rowStart)
        return spanA < spanB
    }

    for item in sortedItems {
        let range = isColumn ? (item.colStart..<item.colEnd) : (item.rowStart..<item.rowEnd)
        let spanCount = range.count
        let spansIntrinsicMin = range.contains { tracks[$0].sizing.min.isIntrinsic }
        let spansIntrinsicMax = range.contains { tracks[$0].sizing.max.isIntrinsic }

        if !spansIntrinsicMin && !spansIntrinsicMax { continue }

        if spanCount == 1 {
            let tIdx = range.lowerBound
            if tracks[tIdx].isCollapsed { continue }
            let minFn = tracks[tIdx].sizing.min
            let maxFn = tracks[tIdx].sizing.max

            if minFn.isIntrinsic {
                let avail: AvailableSpace = (minFn == .minContent) ? .minContent : .maxContent
                let contrib = measureItem(item, axis: axis, sizingMode: .contentSize, avail: avail)
                tracks[tIdx].baseSize = Swift.max(tracks[tIdx].baseSize, contrib)
            }

            if maxFn.isIntrinsic {
                let avail: AvailableSpace = (maxFn == .minContent) ? .minContent : .maxContent
                let contrib = measureItem(item, axis: axis, sizingMode: .contentSize, avail: avail)
                let limit = maxFn.definiteLimit(containerInnerSize)
                let capped = limit.map { Swift.max(tracks[tIdx].baseSize, Swift.min(contrib, $0)) } ?? contrib
                if tracks[tIdx].growthLimit.isInfinite {
                    tracks[tIdx].growthLimit = Swift.max(tracks[tIdx].baseSize, capped)
                } else {
                    tracks[tIdx].growthLimit = Swift.max(tracks[tIdx].growthLimit, capped)
                }
            }
            if tracks[tIdx].growthLimit < tracks[tIdx].baseSize {
                tracks[tIdx].growthLimit = tracks[tIdx].baseSize
            }
        } else {
            // Spanning item: distribute deficit evenly across spanned intrinsic tracks
            let gapSum = gap * Float(Swift.max(0, spanCount - 1))
            if spansIntrinsicMin {
                let contrib = measureItem(item, axis: axis, sizingMode: .contentSize, avail: .minContent)
                let currentBase = range.reduce(Float(0)) { $0 + tracks[$1].baseSize } + gapSum
                let extra = Swift.max(0, contrib - currentBase)
                if extra > 0 {
                    let eligible = range.filter { tracks[$0].sizing.min.isIntrinsic && !tracks[$0].isCollapsed }
                    if !eligible.isEmpty {
                        let share = extra / Float(eligible.count)
                        for idx in eligible {
                            tracks[idx].baseSize += share
                            if tracks[idx].growthLimit < tracks[idx].baseSize {
                                tracks[idx].growthLimit = tracks[idx].baseSize
                            }
                        }
                    }
                }
            }
            if spansIntrinsicMax {
                let contrib = measureItem(item, axis: axis, sizingMode: .contentSize, avail: .maxContent)
                let eligible = range.filter { tracks[$0].sizing.max.isIntrinsic && !tracks[$0].isCollapsed }
                if !eligible.isEmpty {
                    let currentLimit = range.reduce(Float(0)) {
                        $0 + (tracks[$1].growthLimit.isFinite ? tracks[$1].growthLimit : tracks[$1].baseSize)
                    } + gapSum
                    let extra = Swift.max(0, contrib - currentLimit)
                    if extra > 0 {
                        let share = extra / Float(eligible.count)
                        for idx in eligible {
                            let cur = tracks[idx].growthLimit.isFinite ? tracks[idx].growthLimit : tracks[idx].baseSize
                            var next = cur + share
                            if let lim = tracks[idx].sizing.max.definiteLimit(containerInnerSize) {
                                next = Swift.min(next, Swift.max(tracks[idx].baseSize, lim))
                            }
                            tracks[idx].growthLimit = Swift.max(tracks[idx].baseSize, next)
                        }
                    }
                }
            }
        }
    }

    // Clamp any remaining infinite growth limits on non-flex tracks
    for i in tracks.indices {
        if tracks[i].growthLimit.isInfinite && !tracks[i].sizing.max.isFlexible {
            tracks[i].growthLimit = tracks[i].baseSize
        }
    }

    // 3. Maximize tracks: grow baseSize up to growthLimit if free space is available
    let totalGap = gap * Float(Swift.max(0, tracks.count - 1))
    let availDef = containerInnerSize ?? availableSpace.definiteValue
    if let avail = availDef {
        let used = tracks.reduce(Float(0)) { $0 + $1.baseSize } + totalGap
        var free = Swift.max(0, avail - used)
        if free > 0 {
            var growable = tracks.indices.filter {
                !tracks[$0].isCollapsed && tracks[$0].growthLimit.isFinite && tracks[$0].growthLimit > tracks[$0].baseSize
            }
            while free > 0.001 && !growable.isEmpty {
                let share = free / Float(growable.count)
                var nextGrowable: [Int] = []
                var spent: Float = 0
                for idx in growable {
                    let room = tracks[idx].growthLimit - tracks[idx].baseSize
                    if room <= share {
                        tracks[idx].baseSize += room
                        spent += room
                    } else {
                        tracks[idx].baseSize += share
                        spent += share
                        nextGrowable.append(idx)
                    }
                }
                free -= spent
                if spent <= 0.0001 { break }
                growable = nextGrowable
            }
        }
    } else {
        for i in tracks.indices where tracks[i].growthLimit.isFinite {
            tracks[i].baseSize = Swift.max(tracks[i].baseSize, tracks[i].growthLimit)
        }
    }

    // 4. Expand flexible (fr) tracks (CSS Grid 12.7)
    var flexIndices = tracks.indices.filter { !tracks[$0].isCollapsed && tracks[$0].sizing.max.isFlexible }
    if !flexIndices.isEmpty {
        if let avail = availDef {
            let nonFlexUsed = tracks.indices.reduce(Float(0)) { acc, idx in
                tracks[idx].sizing.max.isFlexible ? acc : (acc + tracks[idx].baseSize)
            } + totalGap
            let spaceForFlex = Swift.max(0, avail - nonFlexUsed)

            // Iterative freeze loop for fr tracks whose baseSize exceeds their fr share
            var remainingSpace = spaceForFlex
            while !flexIndices.isEmpty {
                let totalFr = flexIndices.reduce(Float(0)) { $0 + (tracks[$1].sizing.max.frValue ?? 0) }
                let frDenom = Swift.max(totalFr, 1.0)
                let hypotheticalUnit = remainingSpace / frDenom

                var frozeAny = false
                var nextFlex: [Int] = []
                for idx in flexIndices {
                    let fr = tracks[idx].sizing.max.frValue ?? 0
                    if hypotheticalUnit * fr < tracks[idx].baseSize {
                        remainingSpace = Swift.max(0, remainingSpace - tracks[idx].baseSize)
                        frozeAny = true
                    } else {
                        nextFlex.append(idx)
                    }
                }
                if !frozeAny {
                    for idx in flexIndices {
                        let fr = tracks[idx].sizing.max.frValue ?? 0
                        tracks[idx].baseSize = Swift.max(tracks[idx].baseSize, hypotheticalUnit * fr)
                    }
                    break
                }
                flexIndices = nextFlex
            }
        } else {
            // Intrinsic sizing with fr tracks: find max(baseSize / fr)
            var maxRatio: Float = 0
            for idx in flexIndices {
                let fr = tracks[idx].sizing.max.frValue ?? 0
                if fr > 0 {
                    maxRatio = Swift.max(maxRatio, tracks[idx].baseSize / fr)
                }
            }
            for idx in flexIndices {
                let fr = tracks[idx].sizing.max.frValue ?? 0
                tracks[idx].baseSize = Swift.max(tracks[idx].baseSize, maxRatio * fr)
            }
        }
    }

    // 5. Stretch auto tracks if alignContent/justifyContent is stretch/normal and container size is definite
    if let containerSize = containerInnerSize, (alignContent == .stretch || alignContent == .normal) {
        let used = sumTrackSizes(tracks, gap: gap)
        let free = Swift.max(0, containerSize - used)
        if free > 0 {
            let autoIndices = tracks.indices.filter {
                !tracks[$0].isCollapsed && tracks[$0].sizing.max == .auto
            }
            if !autoIndices.isEmpty {
                let extra = free / Float(autoIndices.count)
                for idx in autoIndices {
                    tracks[idx].baseSize += extra
                }
            }
        }
    }
}

private func sumTrackSizes(_ tracks: [GridTrack], gap: Float) -> Float {
    let activeCount = tracks.filter { !$0.isCollapsed }.count
    let sum = tracks.reduce(Float(0)) { $0 + $1.baseSize }
    return sum + gap * Float(Swift.max(0, activeCount - 1))
}

private func alignTracks(
    tracks: inout [GridTrack],
    containerInnerSize: Float,
    gap: Float,
    alignContent: AlignContent,
    startOffset: Float
) {
    guard !tracks.isEmpty else { return }
    let used = sumTrackSizes(tracks, gap: gap)
    let free = Swift.max(0, containerInnerSize - used)
    let activeCount = tracks.filter { !$0.isCollapsed }.count

    var cur = startOffset
    var extraGap: Float = 0

    switch alignContent {
    case .start, .flexStart, .normal, .stretch:
        break
    case .end, .flexEnd:
        cur += free
    case .center:
        cur += free * 0.5
    case .spaceBetween:
        if activeCount > 1 {
            extraGap = free / Float(activeCount - 1)
        }
    case .spaceAround:
        if activeCount > 0 {
            let step = free / Float(activeCount)
            cur += step * 0.5
            extraGap = step
        }
    case .spaceEvenly:
        if activeCount > 0 {
            let step = free / Float(activeCount + 1)
            cur += step
            extraGap = step
        }
    }

    var seenActive = false
    for i in tracks.indices {
        if tracks[i].isCollapsed {
            tracks[i].offset = cur
            continue
        }
        if seenActive {
            cur += gap + extraGap
        }
        tracks[i].offset = cur
        cur += tracks[i].baseSize
        seenActive = true
    }
}

private func alignItemInArea(
    areaSize: Float,
    itemSize: Float,
    marginStart: Float?,
    marginEnd: Float?,
    alignment: AlignItems
) -> (offset: Float, marginStart: Float, marginEnd: Float) {
    let mS = marginStart ?? 0
    let mE = marginEnd ?? 0
    let free = areaSize - itemSize - mS - mE

    if marginStart == nil && marginEnd == nil {
        let half = Swift.max(0, areaSize - itemSize) * 0.5
        return (half, half, half)
    }
    if marginStart == nil {
        let autoM = Swift.max(0, areaSize - itemSize - mE)
        return (autoM, autoM, mE)
    }
    if marginEnd == nil {
        let autoM = Swift.max(0, areaSize - itemSize - mS)
        return (mS, mS, autoM)
    }

    let offset: Float
    switch alignment {
    case .start, .flexStart, .selfStart, .stretch, .normal, .baseline:
        offset = mS
    case .end, .flexEnd, .selfEnd:
        offset = mS + free
    case .center:
        offset = mS + free * 0.5
    }
    return (offset, mS, mE)
}
