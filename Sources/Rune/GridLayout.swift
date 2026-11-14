import Foundation
import RuneMotion

// MARK: - Layout Mode

/// CSS display / layout algorithm for a container (`taffy::Display` + Rune `LayoutMode`).
public enum LayoutMode: String, Sendable, Hashable, Codable {
    case flex
    case grid
    case block
}

// MARK: - CSS Grid Track & Placement Types

/// A single track sizing function in CSS Grid (`grid-template-columns` / `grid-template-rows`).
public indirect enum GridTrack: Sendable, Hashable, Codable {
    case px(Float)
    case fr(Float)
    case auto
    case percent(Float)
    case minContent
    case maxContent
    case minmax(GridTrack, GridTrack)

    /// Creates `count` copies of `track` (CSS `repeat(count, track)`).
    public static func repeatCount(_ count: Int, _ track: GridTrack) -> [GridTrack] {
        guard count > 0 else { return [] }
        return Array(repeating: track, count: count)
    }

    /// Repeats a pattern of `tracks` `count` times (CSS `repeat(count, t1 t2 ...)`).
    public static func repeatTracks(_ count: Int, _ tracks: [GridTrack]) -> [GridTrack] {
        guard count > 0, !tracks.isEmpty else { return [] }
        var out: [GridTrack] = []
        out.reserveCapacity(count * tracks.count)
        for _ in 0..<count {
            out.append(contentsOf: tracks)
        }
        return out
    }
}

/// CSS `grid-auto-flow` placement direction and packing mode.
public enum GridAutoFlow: String, Sendable, Hashable, Codable {
    case row
    case column
    case rowDense
    case columnDense

    public var isColumn: Bool {
        self == .column || self == .columnDense
    }

    public var isDense: Bool {
        self == .rowDense || self == .columnDense
    }
}

/// CSS Grid item placement on one axis (`grid-column` / `grid-row` / `grid-area`).
public enum GridPlacement: Sendable, Hashable, Codable {
    case auto
    /// 1-based grid line (negative values count from the explicit grid end).
    case line(Int)
    /// Span `n` tracks from the auto-placed or explicit start.
    case span(Int)
    /// Start at 1-based `line` and span `span` tracks.
    case lineSpan(Int, Int)
    /// Named grid area (resolved against `GridContainerStyle.templateAreas`).
    case area(String)
}

/// Grid container properties stored on `LayoutStyle.grid`.
public struct GridContainerStyle: Sendable, Hashable {
    public var templateColumns: [GridTrack] = []
    public var templateRows: [GridTrack] = []
    public var autoColumns: [GridTrack] = [.auto]
    public var autoRows: [GridTrack] = [.auto]
    public var autoFlow: GridAutoFlow = .row
    public var templateAreas: [[String]] = []
    public var justifyItems: AlignItems = .stretch
    public var justifyContent: JustifyContent = .start
    public var alignContent: JustifyContent = .start

    public init(
        templateColumns: [GridTrack] = [],
        templateRows: [GridTrack] = [],
        autoColumns: [GridTrack] = [.auto],
        autoRows: [GridTrack] = [.auto],
        autoFlow: GridAutoFlow = .row,
        templateAreas: [[String]] = [],
        justifyItems: AlignItems = .stretch,
        justifyContent: JustifyContent = .start,
        alignContent: JustifyContent = .start
    ) {
        self.templateColumns = templateColumns
        self.templateRows = templateRows
        self.autoColumns = autoColumns.isEmpty ? [.auto] : autoColumns
        self.autoRows = autoRows.isEmpty ? [.auto] : autoRows
        self.autoFlow = autoFlow
        self.templateAreas = templateAreas
        self.justifyItems = justifyItems
        self.justifyContent = justifyContent
        self.alignContent = alignContent
    }
}

/// Grid item placement & self-alignment stored on `LayoutStyle.gridItem`.
public struct GridItemStyle: Sendable, Hashable {
    public var column: GridPlacement = .auto
    public var row: GridPlacement = .auto
    public var columnEnd: GridPlacement? = nil
    public var rowEnd: GridPlacement? = nil
    public var area: String? = nil
    public var justifySelf: AlignItems? = nil

    public init(
        column: GridPlacement = .auto,
        row: GridPlacement = .auto,
        columnEnd: GridPlacement? = nil,
        rowEnd: GridPlacement? = nil,
        area: String? = nil,
        justifySelf: AlignItems? = nil
    ) {
        self.column = column
        self.row = row
        self.columnEnd = columnEnd
        self.rowEnd = rowEnd
        self.area = area
        self.justifySelf = justifySelf
    }
}

// MARK: - CSS Grid & Block Layout Solvers

enum GridAndBlockSolver {
    struct PlacedItem {
        var childIndex: Int
        var colStart: Int
        var colSpan: Int
        var rowStart: Int
        var rowSpan: Int
    }

    struct ResolvedTrack {
        var spec: GridTrack
        var base: Float = 0
        var limit: Float = .infinity
        var fr: Float = 0
        var size: Float = 0
        var position: Float = 0
    }

    struct AreaBounds {
        var rowStart: Int
        var rowSpan: Int
        var colStart: Int
        var colSpan: Int
    }

    // MARK: - CSS Grid Layout

    static func layoutGrid(
        _ node: LayoutInputNode,
        availableWidth: Float?,
        availableHeight: Float?,
        forcedWidth: Float?,
        forcedHeight: Float?,
        childLayout: (LayoutInputNode, Float?, Float?, Float?, Float?) -> LayoutEngine.ResultNode
    ) -> LayoutEngine.ResultNode {
        let s = node.style
        let gs = s.grid ?? GridContainerStyle()
        let padH = s.padding.left + s.padding.right
        let padV = s.padding.top + s.padding.bottom

        let minW = s.minWidth.resolve(against: availableWidth)
        let maxW = s.maxWidth.resolve(against: availableWidth)
        let minH = s.minHeight.resolve(against: availableHeight)
        let maxH = s.maxHeight.resolve(against: availableHeight)

        func clampW(_ w: Float) -> Float {
            var v = max(0, w)
            if let maxW { v = min(v, maxW) }
            if let minW { v = max(v, minW) }
            return v
        }

        func clampH(_ h: Float) -> Float {
            var v = max(0, h)
            if let maxH { v = min(v, maxH) }
            if let minH { v = max(v, minH) }
            return v
        }

        var resolvedW = forcedWidth ?? s.width.resolve(against: availableWidth)
        var resolvedH = forcedHeight ?? s.height.resolve(against: availableHeight)
        if let w = resolvedW { resolvedW = clampW(w) }
        if let h = resolvedH { resolvedH = clampH(h) }

        let innerAvailW: Float? = s.scrollAxes.contains(.horizontal)
            ? nil
            : (resolvedW ?? maxW ?? availableWidth).map { max(0, $0 - padH) }
        let innerAvailH: Float? = s.scrollAxes.contains(.vertical)
            ? nil
            : (resolvedH ?? maxH ?? availableHeight).map { max(0, $0 - padV) }

        var childResults = Array(
            repeating: LayoutEngine.ResultNode(layout: ComputedLayout(), children: []),
            count: node.children.count
        )

        var flowIndices: [Int] = []
        var absIndices: [Int] = []
        for i in 0..<node.children.count {
            if node.children[i].style.isAbsolute {
                absIndices.append(i)
            } else {
                flowIndices.append(i)
            }
        }

        // 1. Parse named template areas
        let areaMap = parseAreas(gs.templateAreas)
        let areaRowCount = gs.templateAreas.count
        let areaColCount = gs.templateAreas.map(\.count).max() ?? 0

        let explicitCols = max(gs.templateColumns.count, areaColCount)
        let explicitRows = max(gs.templateRows.count, areaRowCount)

        // 2. Place grid items (explicit + sparse/dense auto-placement)
        let placed = placeItems(
            children: node.children,
            flowIndices: flowIndices,
            explicitCols: max(1, explicitCols),
            explicitRows: max(1, explicitRows),
            autoFlow: gs.autoFlow,
            areaMap: areaMap
        )

        let totalCols = max(explicitCols, placed.map { $0.colStart + $0.colSpan }.max() ?? 0, 1)
        let totalRows = max(explicitRows, placed.map { $0.rowStart + $0.rowSpan }.max() ?? 0, 1)

        var colTracks = (0..<totalCols).map { idx -> ResolvedTrack in
            let spec: GridTrack
            if idx < gs.templateColumns.count {
                spec = gs.templateColumns[idx]
            } else {
                spec = gs.autoColumns[idx % gs.autoColumns.count]
            }
            return ResolvedTrack(spec: spec)
        }

        var rowTracks = (0..<totalRows).map { idx -> ResolvedTrack in
            let spec: GridTrack
            if idx < gs.templateRows.count {
                spec = gs.templateRows[idx]
            } else {
                spec = gs.autoRows[idx % gs.autoRows.count]
            }
            return ResolvedTrack(spec: spec)
        }

        // 3. Measure intrinsic item sizes for column track sizing
        var intrinsicColSizes: [Int: (minW: Float, maxW: Float)] = [:]
        for item in placed {
            let child = node.children[item.childIndex]
            let cs = child.style
            let mH = cs.margin.left + cs.margin.right
            let wMin: Float
            let wMax: Float
            if let explicitW = cs.width.resolve(against: innerAvailW) {
                wMin = explicitW + mH
                wMax = explicitW + mH
            } else if let measure = child.measure {
                let minIntrinsic = measure(0)
                let maxIntrinsic = measure(nil)
                let padChildH = cs.padding.left + cs.padding.right
                wMin = minIntrinsic.x + padChildH + mH
                wMax = maxIntrinsic.x + padChildH + mH
            } else {
                let solvedMax = childLayout(child, innerAvailW, innerAvailH, nil, nil)
                let minWChild = cs.minWidth.resolve(against: innerAvailW) ?? 0
                wMin = max(minWChild, cs.padding.left + cs.padding.right) + mH
                wMax = solvedMax.layout.localRect.width + mH
            }
            intrinsicColSizes[item.childIndex] = (wMin, max(wMin, wMax))
        }

        // 4. Solve column tracks
        let colGapTotal = Float(max(0, totalCols - 1)) * s.columnGap
        solveTracks(
            tracks: &colTracks,
            availableSize: innerAvailW,
            gapTotal: colGapTotal,
            placed: placed,
            isColumn: true,
            itemIntrinsic: { idx in intrinsicColSizes[idx] ?? (0, 0) }
        )

        // Position columns & apply justifyContent if container width is known
        let usedColsWidth = colTracks.reduce(0) { $0 + $1.size } + colGapTotal
        let containerInnerW = resolvedW.map { max(0, $0 - padH) } ?? clampW(usedColsWidth + padH) - padH
        positionTracks(
            tracks: &colTracks,
            containerInner: containerInnerW,
            padStart: s.padding.left,
            gap: s.columnGap,
            justify: gs.justifyContent
        )

        // 5. Measure item heights now that column track widths are known
        var solvedChildren: [Int: LayoutEngine.ResultNode] = [:]
        var intrinsicRowSizes: [Int: (minH: Float, maxH: Float)] = [:]

        for item in placed {
            let child = node.children[item.childIndex]
            let cs = child.style
            let mH = cs.margin.left + cs.margin.right
            let mV = cs.margin.top + cs.margin.bottom
            let areaW = spanSize(tracks: colTracks, start: item.colStart, span: item.colSpan, gap: s.columnGap)
            let availChildW = max(0, areaW - mH)

            let jSelf = cs.gridItem?.justifySelf ?? gs.justifyItems
            let forcedChildW: Float?
            if let explicitW = cs.width.resolve(against: availChildW) {
                forcedChildW = explicitW
            } else if jSelf == .stretch && cs.width == .auto {
                forcedChildW = availChildW
            } else {
                forcedChildW = nil
            }

            let solved = childLayout(child, availChildW, innerAvailH, forcedChildW, nil)
            solvedChildren[item.childIndex] = solved
            let h = solved.layout.localRect.height + mV
            intrinsicRowSizes[item.childIndex] = (h, h)
        }

        // 6. Solve row tracks
        let rowGapTotal = Float(max(0, totalRows - 1)) * s.rowGap
        solveTracks(
            tracks: &rowTracks,
            availableSize: innerAvailH,
            gapTotal: rowGapTotal,
            placed: placed,
            isColumn: false,
            itemIntrinsic: { idx in intrinsicRowSizes[idx] ?? (0, 0) }
        )

        let usedRowsHeight = rowTracks.reduce(0) { $0 + $1.size } + rowGapTotal
        let finalOuterW = resolvedW ?? clampW(usedColsWidth + padH)
        let finalOuterH = resolvedH ?? clampH(usedRowsHeight + padV)
        let finalInnerH = max(0, finalOuterH - padV)

        positionTracks(
            tracks: &rowTracks,
            containerInner: finalInnerH,
            padStart: s.padding.top,
            gap: s.rowGap,
            justify: gs.alignContent
        )

        // 7. Finalize each placed item's rect (re-layout if stretched vertically or height changed)
        var maxContentX: Float = finalOuterW
        var maxContentY: Float = finalOuterH

        for item in placed {
            let child = node.children[item.childIndex]
            let cs = child.style
            let areaX = colTracks[item.colStart].position
            let areaY = rowTracks[item.rowStart].position
            let areaW = spanSize(tracks: colTracks, start: item.colStart, span: item.colSpan, gap: s.columnGap)
            let areaH = spanSize(tracks: rowTracks, start: item.rowStart, span: item.rowSpan, gap: s.rowGap)

            let mL = cs.margin.left
            let mR = cs.margin.right
            let mT = cs.margin.top
            let mB = cs.margin.bottom
            let availChildW = max(0, areaW - mL - mR)
            let availChildH = max(0, areaH - mT - mB)

            let jSelf = cs.gridItem?.justifySelf ?? gs.justifyItems
            let aSelf = cs.alignSelf ?? s.alignItems

            let forcedChildW: Float? = cs.width.resolve(against: availChildW)
                ?? (jSelf == .stretch ? availChildW : nil)
            let forcedChildH: Float? = cs.height.resolve(against: availChildH)
                ?? (aSelf == .stretch ? availChildH : nil)

            var solved: LayoutEngine.ResultNode
            if let existing = solvedChildren[item.childIndex],
               (forcedChildH == nil || abs(existing.layout.localRect.height - forcedChildH!) < 0.01) {
                solved = existing
            } else {
                solved = childLayout(child, availChildW, availChildH, forcedChildW, forcedChildH)
            }

            let cw = solved.layout.localRect.width
            let ch = solved.layout.localRect.height

            let freeX = areaW - (cw + mL + mR)
            let offsetX: Float
            switch jSelf {
            case .start, .stretch: offsetX = mL
            case .center: offsetX = mL + freeX * 0.5
            case .end: offsetX = mL + freeX
            }

            let freeY = areaH - (ch + mT + mB)
            let offsetY: Float
            switch aSelf {
            case .start, .stretch: offsetY = mT
            case .center: offsetY = mT + freeY * 0.5
            case .end: offsetY = mT + freeY
            }

            let x = areaX + offsetX
            let y = areaY + offsetY
            solved.layout.localRect = MotionRect.fromXYWH(x, y, cw, ch)
            childResults[item.childIndex] = solved

            maxContentX = max(maxContentX, x + cw + mR + s.padding.right)
            maxContentY = max(maxContentY, y + ch + mB + s.padding.bottom)
        }

        // 8. Position absolute children
        layoutAbsoluteChildren(
            node: node,
            absIndices: absIndices,
            finalOuterW: finalOuterW,
            finalOuterH: finalOuterH,
            childResults: &childResults,
            childLayout: childLayout
        )

        return LayoutEngine.ResultNode(
            layout: ComputedLayout(
                localRect: MotionRect.fromXYWH(0, 0, finalOuterW, finalOuterH),
                contentSize: Vec2(maxContentX, maxContentY)
            ),
            children: childResults
        )
    }

    // MARK: - CSS Block Layout

    static func layoutBlock(
        _ node: LayoutInputNode,
        availableWidth: Float?,
        availableHeight: Float?,
        forcedWidth: Float?,
        forcedHeight: Float?,
        childLayout: (LayoutInputNode, Float?, Float?, Float?, Float?) -> LayoutEngine.ResultNode
    ) -> LayoutEngine.ResultNode {
        let s = node.style
        let padH = s.padding.left + s.padding.right
        let padV = s.padding.top + s.padding.bottom

        let minW = s.minWidth.resolve(against: availableWidth)
        let maxW = s.maxWidth.resolve(against: availableWidth)
        let minH = s.minHeight.resolve(against: availableHeight)
        let maxH = s.maxHeight.resolve(against: availableHeight)

        func clampW(_ w: Float) -> Float {
            var v = max(0, w)
            if let maxW { v = min(v, maxW) }
            if let minW { v = max(v, minW) }
            return v
        }

        func clampH(_ h: Float) -> Float {
            var v = max(0, h)
            if let maxH { v = min(v, maxH) }
            if let minH { v = max(v, minH) }
            return v
        }

        var resolvedW = forcedWidth ?? s.width.resolve(against: availableWidth)
        var resolvedH = forcedHeight ?? s.height.resolve(against: availableHeight)
        if let w = resolvedW { resolvedW = clampW(w) }
        if let h = resolvedH { resolvedH = clampH(h) }

        let innerAvailW: Float? = s.scrollAxes.contains(.horizontal)
            ? nil
            : (resolvedW ?? maxW ?? availableWidth).map { max(0, $0 - padH) }
        let innerAvailH: Float? = s.scrollAxes.contains(.vertical)
            ? nil
            : (resolvedH ?? maxH ?? availableHeight).map { max(0, $0 - padV) }

        var childResults = Array(
            repeating: LayoutEngine.ResultNode(layout: ComputedLayout(), children: []),
            count: node.children.count
        )

        var flowIndices: [Int] = []
        var absIndices: [Int] = []
        for i in 0..<node.children.count {
            if node.children[i].style.isAbsolute {
                absIndices.append(i)
            } else {
                flowIndices.append(i)
            }
        }

        var cursorY = s.padding.top
        var prevMarginBottom: Float = 0
        var hasPrevFlow = false
        var maxChildExtentW: Float = 0

        for idx in flowIndices {
            let child = node.children[idx]
            let cs = child.style
            let availChildW = innerAvailW.map { max(0, $0 - cs.margin.left - cs.margin.right) }

            // Block-level children with auto width fill the containing block's width unless they have an intrinsic width
            let forcedChildW: Float?
            if let ew = cs.width.resolve(against: innerAvailW) {
                forcedChildW = ew
            } else if child.measure == nil, let availChildW, cs.displayMode == .block {
                forcedChildW = availChildW
            } else {
                forcedChildW = nil
            }

            var solved = childLayout(child, availChildW, innerAvailH, forcedChildW, nil)
            let cw = solved.layout.localRect.width
            let ch = solved.layout.localRect.height

            // Collapse adjacent vertical margins in CSS block flow
            let collapsedGap: Float
            if hasPrevFlow {
                if prevMarginBottom >= 0 && cs.margin.top >= 0 {
                    collapsedGap = max(prevMarginBottom, cs.margin.top)
                } else if prevMarginBottom < 0 && cs.margin.top < 0 {
                    collapsedGap = min(prevMarginBottom, cs.margin.top)
                } else {
                    collapsedGap = prevMarginBottom + cs.margin.top
                }
            } else {
                collapsedGap = cs.margin.top
            }

            let y = cursorY + collapsedGap
            let x = s.padding.left + cs.margin.left
            solved.layout.localRect = MotionRect.fromXYWH(x, y, cw, ch)
            childResults[idx] = solved

            cursorY = y + ch
            prevMarginBottom = cs.margin.bottom
            hasPrevFlow = true
            maxChildExtentW = max(maxChildExtentW, cs.margin.left + cw + cs.margin.right)
        }

        let totalContentH = hasPrevFlow ? (cursorY - s.padding.top + prevMarginBottom) : 0
        let finalOuterW = resolvedW ?? clampW(maxChildExtentW + padH)
        let finalOuterH = resolvedH ?? clampH(totalContentH + padV)

        layoutAbsoluteChildren(
            node: node,
            absIndices: absIndices,
            finalOuterW: finalOuterW,
            finalOuterH: finalOuterH,
            childResults: &childResults,
            childLayout: childLayout
        )

        return LayoutEngine.ResultNode(
            layout: ComputedLayout(
                localRect: MotionRect.fromXYWH(0, 0, finalOuterW, finalOuterH),
                contentSize: Vec2(max(finalOuterW, maxChildExtentW + padH), max(finalOuterH, totalContentH + padV))
            ),
            children: childResults
        )
    }

    // MARK: - Grid Helpers

    private static func parseAreas(_ areas: [[String]]) -> [String: AreaBounds] {
        var map: [String: (minR: Int, maxR: Int, minC: Int, maxC: Int)] = [:]
        for (r, row) in areas.enumerated() {
            for (c, name) in row.enumerated() {
                if name.isEmpty || name == "." { continue }
                if var existing = map[name] {
                    existing.minR = min(existing.minR, r)
                    existing.maxR = max(existing.maxR, r)
                    existing.minC = min(existing.minC, c)
                    existing.maxC = max(existing.maxC, c)
                    map[name] = existing
                } else {
                    map[name] = (r, r, c, c)
                }
            }
        }
        var out: [String: AreaBounds] = [:]
        for (name, b) in map {
            out[name] = AreaBounds(
                rowStart: b.minR,
                rowSpan: b.maxR - b.minR + 1,
                colStart: b.minC,
                colSpan: b.maxC - b.minC + 1
            )
        }
        return out
    }

    private static func resolveAxis(
        start: GridPlacement,
        end: GridPlacement?,
        explicitCount: Int
    ) -> (start: Int?, span: Int) {
        func resolveLine(_ line: Int) -> Int {
            if line > 0 { return line - 1 }
            if line < 0 { return max(0, explicitCount + 1 + line) }
            return 0
        }

        switch start {
        case .auto:
            if case .span(let s) = end {
                return (nil, max(1, s))
            }
            if case .line(let e) = end {
                let endIdx = resolveLine(e)
                return (max(0, endIdx - 1), 1)
            }
            return (nil, 1)
        case .line(let l):
            let sIdx = resolveLine(l)
            if let end {
                switch end {
                case .span(let sp):
                    return (sIdx, max(1, sp))
                case .line(let e):
                    let eIdx = resolveLine(e)
                    return (sIdx, max(1, eIdx - sIdx))
                default:
                    return (sIdx, 1)
                }
            }
            return (sIdx, 1)
        case .span(let sp):
            if case .line(let e) = end {
                let eIdx = resolveLine(e)
                let span = max(1, sp)
                return (max(0, eIdx - span), span)
            }
            return (nil, max(1, sp))
        case .lineSpan(let l, let sp):
            return (resolveLine(l), max(1, sp))
        case .area:
            return (nil, 1)
        }
    }

    private static func placeItems(
        children: [LayoutInputNode],
        flowIndices: [Int],
        explicitCols: Int,
        explicitRows: Int,
        autoFlow: GridAutoFlow,
        areaMap: [String: AreaBounds]
    ) -> [PlacedItem] {
        var occupied: Set<Int64> = []
        @inline(__always)
        func cellKey(_ r: Int, _ c: Int) -> Int64 {
            (Int64(r) << 32) | Int64(UInt32(bitPattern: Int32(c)))
        }
        func isFree(r: Int, c: Int, rSpan: Int, cSpan: Int) -> Bool {
            for rr in r..<(r + rSpan) {
                for cc in c..<(c + cSpan) {
                    if occupied.contains(cellKey(rr, cc)) { return false }
                }
            }
            return true
        }
        func markUsed(r: Int, c: Int, rSpan: Int, cSpan: Int) {
            for rr in r..<(r + rSpan) {
                for cc in c..<(c + cSpan) {
                    occupied.insert(cellKey(rr, cc))
                }
            }
        }

        struct Pending {
            var childIndex: Int
            var colStart: Int?
            var colSpan: Int
            var rowStart: Int?
            var rowSpan: Int
        }

        var pending: [Pending] = []
        pending.reserveCapacity(flowIndices.count)

        for idx in flowIndices {
            let gi = children[idx].style.gridItem ?? GridItemStyle()
            var colStart: Int? = nil
            var colSpan = 1
            var rowStart: Int? = nil
            var rowSpan = 1

            let areaName: String? = gi.area ?? {
                if case .area(let a) = gi.column { return a }
                if case .area(let a) = gi.row { return a }
                return nil
            }()

            if let areaName, let bounds = areaMap[areaName] {
                colStart = bounds.colStart
                colSpan = bounds.colSpan
                rowStart = bounds.rowStart
                rowSpan = bounds.rowSpan
            } else {
                let cRes = resolveAxis(start: gi.column, end: gi.columnEnd, explicitCount: explicitCols)
                let rRes = resolveAxis(start: gi.row, end: gi.rowEnd, explicitCount: explicitRows)
                colStart = cRes.start
                colSpan = cRes.span
                rowStart = rRes.start
                rowSpan = rRes.span
            }

            pending.append(Pending(
                childIndex: idx,
                colStart: colStart,
                colSpan: colSpan,
                rowStart: rowStart,
                rowSpan: rowSpan
            ))
        }

        var placed = Array<PlacedItem?>(repeating: nil, count: pending.count)

        // Pass 1: Definite on both axes
        for (i, p) in pending.enumerated() {
            if let c = p.colStart, let r = p.rowStart {
                markUsed(r: r, c: c, rSpan: p.rowSpan, cSpan: p.colSpan)
                placed[i] = PlacedItem(
                    childIndex: p.childIndex,
                    colStart: c,
                    colSpan: p.colSpan,
                    rowStart: r,
                    rowSpan: p.rowSpan
                )
            }
        }

        // Compute grid bounds for auto-placement
        let maxExplicitCol = max(explicitCols, pending.compactMap { p in
            p.colStart.map { $0 + p.colSpan }
        }.max() ?? 1)
        let maxExplicitRow = max(explicitRows, pending.compactMap { p in
            p.rowStart.map { $0 + p.rowSpan }
        }.max() ?? 1)

        // Pass 2: Remaining items (either one axis definite or both auto)
        var cursorR = 0
        var cursorC = 0

        for (i, p) in pending.enumerated() {
            if placed[i] != nil { continue }

            if let c = p.colStart {
                var r = autoFlow.isDense ? 0 : cursorR
                while !isFree(r: r, c: c, rSpan: p.rowSpan, cSpan: p.colSpan) {
                    r += 1
                }
                markUsed(r: r, c: c, rSpan: p.rowSpan, cSpan: p.colSpan)
                placed[i] = PlacedItem(childIndex: p.childIndex, colStart: c, colSpan: p.colSpan, rowStart: r, rowSpan: p.rowSpan)
                if !autoFlow.isDense {
                    cursorR = r
                    cursorC = c + p.colSpan
                }
            } else if let r = p.rowStart {
                var c = autoFlow.isDense ? 0 : cursorC
                while !isFree(r: r, c: c, rSpan: p.rowSpan, cSpan: p.colSpan) {
                    c += 1
                }
                markUsed(r: r, c: c, rSpan: p.rowSpan, cSpan: p.colSpan)
                placed[i] = PlacedItem(childIndex: p.childIndex, colStart: c, colSpan: p.colSpan, rowStart: r, rowSpan: p.rowSpan)
                if !autoFlow.isDense {
                    cursorR = r
                    cursorC = c + p.colSpan
                }
            } else if autoFlow.isColumn {
                var c = autoFlow.isDense ? 0 : cursorC
                var r = autoFlow.isDense ? 0 : cursorR
                let rowCap = max(maxExplicitRow, p.rowSpan)
                while true {
                    if r + p.rowSpan > rowCap {
                        r = 0
                        c += 1
                    }
                    if isFree(r: r, c: c, rSpan: p.rowSpan, cSpan: p.colSpan) {
                        break
                    }
                    r += 1
                }
                markUsed(r: r, c: c, rSpan: p.rowSpan, cSpan: p.colSpan)
                placed[i] = PlacedItem(childIndex: p.childIndex, colStart: c, colSpan: p.colSpan, rowStart: r, rowSpan: p.rowSpan)
                if !autoFlow.isDense {
                    cursorC = c
                    cursorR = r + p.rowSpan
                }
            } else {
                var r = autoFlow.isDense ? 0 : cursorR
                var c = autoFlow.isDense ? 0 : cursorC
                let colCap = max(maxExplicitCol, p.colSpan)
                while true {
                    if c + p.colSpan > colCap {
                        c = 0
                        r += 1
                    }
                    if isFree(r: r, c: c, rSpan: p.rowSpan, cSpan: p.colSpan) {
                        break
                    }
                    c += 1
                }
                markUsed(r: r, c: c, rSpan: p.rowSpan, cSpan: p.colSpan)
                placed[i] = PlacedItem(childIndex: p.childIndex, colStart: c, colSpan: p.colSpan, rowStart: r, rowSpan: p.rowSpan)
                if !autoFlow.isDense {
                    cursorR = r
                    cursorC = c + p.colSpan
                }
            }
        }

        return placed.compactMap { $0 }
    }

    private static func solveTracks(
        tracks: inout [ResolvedTrack],
        availableSize: Float?,
        gapTotal: Float,
        placed: [PlacedItem],
        isColumn: Bool,
        itemIntrinsic: (Int) -> (Float, Float)
    ) {
        // Initialize base, limit, fr from GridTrack spec
        func initBounds(_ spec: GridTrack) -> (base: Float, limit: Float, fr: Float) {
            switch spec {
            case .px(let v):
                let pv = max(0, v)
                return (pv, pv, 0)
            case .percent(let f):
                if let avail = availableSize, avail.isFinite {
                    let pv = max(0, avail * f)
                    return (pv, pv, 0)
                }
                return (0, .infinity, 0)
            case .fr(let f):
                return (0, .infinity, max(0, f))
            case .auto, .minContent, .maxContent:
                return (0, .infinity, 0)
            case .minmax(let minT, let maxT):
                let (minB, _, _) = initBounds(minT)
                let (_, maxL, maxFr) = initBounds(maxT)
                return (minB, max(minB, maxL), maxFr)
            }
        }

        for i in 0..<tracks.count {
            let b = initBounds(tracks[i].spec)
            tracks[i].base = b.base
            tracks[i].limit = b.limit
            tracks[i].fr = b.fr
        }

        // Intrinsic sizing pass: single-span items first, then multi-span items
        let sortedItems = placed.sorted { a, b in
            let sa = isColumn ? a.colSpan : a.rowSpan
            let sb = isColumn ? b.colSpan : b.rowSpan
            return sa < sb
        }

        for item in sortedItems {
            let start = isColumn ? item.colStart : item.rowStart
            let span = isColumn ? item.colSpan : item.rowSpan
            let (minNeed, maxNeed) = itemIntrinsic(item.childIndex)
            let range = start..<min(tracks.count, start + span)

            func needsIntrinsicBase(_ spec: GridTrack) -> Bool {
                switch spec {
                case .auto, .minContent, .maxContent, .fr: return true
                case .minmax(let minT, _): return needsIntrinsicBase(minT)
                case .px, .percent: return false
                }
            }

            func targetNeed(for spec: GridTrack) -> Float {
                switch spec {
                case .minContent: return minNeed
                case .maxContent, .auto: return maxNeed
                case .fr: return minNeed
                case .minmax(_, let maxT):
                    if case .maxContent = maxT { return maxNeed }
                    if case .auto = maxT { return maxNeed }
                    return minNeed
                case .px, .percent: return 0
                }
            }

            if span == 1, let idx = range.first {
                if needsIntrinsicBase(tracks[idx].spec) {
                    let need = targetNeed(for: tracks[idx].spec)
                    tracks[idx].base = max(tracks[idx].base, min(need, tracks[idx].limit))
                }
            } else {
                // Spanning item: distribute deficit evenly across intrinsic tracks
                let currentSum = range.reduce(Float(0)) { $0 + tracks[$1].base }
                let intrinsicIndices = range.filter { needsIntrinsicBase(tracks[$0].spec) }
                if !intrinsicIndices.isEmpty {
                    let need = range.map { targetNeed(for: tracks[$0].spec) }.max() ?? maxNeed
                    let deficit = max(0, need - currentSum)
                    if deficit > 0 {
                        let share = deficit / Float(intrinsicIndices.count)
                        for idx in intrinsicIndices {
                            tracks[idx].base = min(tracks[idx].limit, tracks[idx].base + share)
                        }
                    }
                }
            }
        }

        // Distribute free space to `fr` tracks if availableSize is finite
        let totalFr = tracks.reduce(Float(0)) { $0 + $1.fr }
        if totalFr > 0, let avail = availableSize, avail.isFinite {
            let nonFrUsed = tracks.filter { $0.fr == 0 }.reduce(Float(0)) { $0 + $1.base }
            let freeForFr = max(0, avail - gapTotal - nonFrUsed)
            let frUnit = freeForFr / totalFr
            for i in 0..<tracks.count where tracks[i].fr > 0 {
                let candidate = max(tracks[i].base, tracks[i].fr * frUnit)
                tracks[i].size = min(candidate, tracks[i].limit)
            }
            for i in 0..<tracks.count where tracks[i].fr == 0 {
                tracks[i].size = tracks[i].base
            }
        } else {
            for i in 0..<tracks.count {
                tracks[i].size = tracks[i].base
            }
        }
    }

    private static func positionTracks(
        tracks: inout [ResolvedTrack],
        containerInner: Float,
        padStart: Float,
        gap: Float,
        justify: JustifyContent
    ) {
        let totalTrackSize = tracks.reduce(Float(0)) { $0 + $1.size }
        let totalGaps = Float(max(0, tracks.count - 1)) * gap
        let leftover = max(0, containerInner - totalTrackSize - totalGaps)

        var startOffset: Float = 0
        var extraBetween: Float = 0
        switch justify {
        case .start:
            break
        case .center:
            startOffset = leftover * 0.5
        case .end:
            startOffset = leftover
        case .spaceBetween:
            if tracks.count > 1 {
                extraBetween = leftover / Float(tracks.count - 1)
            }
        case .spaceAround:
            if !tracks.isEmpty {
                let unit = leftover / Float(tracks.count)
                startOffset = unit * 0.5
                extraBetween = unit
            }
        case .spaceEvenly:
            if !tracks.isEmpty {
                let unit = leftover / Float(tracks.count + 1)
                startOffset = unit
                extraBetween = unit
            }
        }

        var cursor = padStart + startOffset
        for i in 0..<tracks.count {
            tracks[i].position = cursor
            cursor += tracks[i].size + gap + extraBetween
        }
    }

    private static func spanSize(tracks: [ResolvedTrack], start: Int, span: Int, gap: Float) -> Float {
        let end = min(tracks.count, start + span)
        guard start < end else { return 0 }
        var total: Float = 0
        for i in start..<end {
            total += tracks[i].size
        }
        total += Float(max(0, end - start - 1)) * gap
        return total
    }

    private static func layoutAbsoluteChildren(
        node: LayoutInputNode,
        absIndices: [Int],
        finalOuterW: Float,
        finalOuterH: Float,
        childResults: inout [LayoutEngine.ResultNode],
        childLayout: (LayoutInputNode, Float?, Float?, Float?, Float?) -> LayoutEngine.ResultNode
    ) {
        let s = node.style
        for idx in absIndices {
            let child = node.children[idx]
            let cs = child.style
            let pinnedW: Float?
            if let l = cs.pinLeft, let r = cs.pinRight, cs.width == .auto {
                pinnedW = max(0, finalOuterW - l - r - cs.margin.left - cs.margin.right)
            } else {
                pinnedW = cs.width.resolve(against: finalOuterW)
            }
            let pinnedH: Float?
            if let t = cs.pinTop, let b = cs.pinBottom, cs.height == .auto {
                pinnedH = max(0, finalOuterH - t - b - cs.margin.top - cs.margin.bottom)
            } else {
                pinnedH = cs.height.resolve(against: finalOuterH)
            }

            var solved = childLayout(child, finalOuterW, finalOuterH, pinnedW, pinnedH)
            let cw = solved.layout.localRect.width
            let ch = solved.layout.localRect.height

            let x: Float
            if let l = cs.pinLeft {
                x = l + cs.margin.left
            } else if let r = cs.pinRight {
                x = finalOuterW - r - cs.margin.right - cw
            } else {
                x = s.padding.left + cs.margin.left
            }

            let y: Float
            if let t = cs.pinTop {
                y = t + cs.margin.top
            } else if let b = cs.pinBottom {
                y = finalOuterH - b - cs.margin.bottom - ch
            } else {
                y = s.padding.top + cs.margin.top
            }

            solved.layout.localRect = MotionRect.fromXYWH(x, y, cw, ch)
            childResults[idx] = solved
        }
    }
}

// MARK: - Monospace Terminal Grid (`rune::el::grid`)

/// Background fill span in a terminal `GridRow`.
public struct TerminalGridFill: Sendable, Hashable {
    public var startColumn: Int
    public var endColumn: Int
    public var color: Color

    public init(startColumn: Int, endColumn: Int, color: Color) {
        self.startColumn = startColumn
        self.endColumn = endColumn
        self.color = color
    }
}

/// Pinned wide/fallback glyph cell in a terminal `GridRow`.
public struct TerminalGridCell: Sendable, Hashable {
    public var column: Int
    public var width: Int
    public var text: String
    public var style: TextStyle
    public var color: Color

    public init(column: Int, width: Int = 1, text: String, style: TextStyle = TextStyle(), color: Color) {
        self.column = column
        self.width = max(1, width)
        self.text = text
        self.style = style
        self.color = color
    }
}

/// Thread-safe per-row shaping & instance cache attached to `TerminalGridRow` (`DrawnRow` / `LaidRow`).
internal final class TerminalGridRowCacheBox: @unchecked Sendable {
    struct LaidRow {
        var scaleBits: UInt32
        var widthBits: UInt32
        var contentHash: UInt64
        var line: ShapedText
        var cells: [ShapedText]
    }

    let lock = NSLock()
    private var laid: LaidRow? = nil
    var drawnStorage: AnyObject? = nil

    func laidRow(
        pixelScale: Float,
        widthPt: Float,
        contentHash: UInt64 = 0,
        compute: () -> (ShapedText, [ShapedText])
    ) -> (line: ShapedText, cells: [ShapedText]) {
        let sBits = pixelScale.bitPattern
        let wBits = widthPt.bitPattern
        lock.lock()
        if let existing = laid,
           existing.scaleBits == sBits,
           existing.widthBits == wBits,
           existing.contentHash == contentHash {
            let out = (existing.line, existing.cells)
            lock.unlock()
            return out
        }
        lock.unlock()
        let (line, cells) = compute()
        lock.lock()
        laid = LaidRow(scaleBits: sBits, widthBits: wBits, contentHash: contentHash, line: line, cells: cells)
        lock.unlock()
        return (line, cells)
    }
}

/// One row of a monospace terminal `TerminalGrid` (`rune::GridRow`).
public struct TerminalGridRow: Sendable {
    public var text: String { didSet { cache = TerminalGridRowCacheBox() } }
    public var spans: [TextSpan] { didSet { cache = TerminalGridRowCacheBox() } }
    public var style: TextStyle { didSet { cache = TerminalGridRowCacheBox() } }
    public var cells: [TerminalGridCell] = [] { didSet { cache = TerminalGridRowCacheBox() } }
    public var fills: [TerminalGridFill] = [] { didSet { cache = TerminalGridRowCacheBox() } }
    public var overlayShape: Shape? = nil { didSet { cache = TerminalGridRowCacheBox() } }
    public var wraps: Bool = false
    internal var cache = TerminalGridRowCacheBox()

    public init(text: String, spans: [TextSpan] = [], style: TextStyle = TextStyle()) {
        self.text = text
        self.spans = spans
        self.style = style
    }

    public func cell(column: Int, width: Int = 1, text: String, style: TextStyle, color: Color) -> Self {
        var copy = self
        copy.cells.append(TerminalGridCell(column: column, width: width, text: text, style: style, color: color))
        return copy
    }

    public func fill(start: Int, end: Int, color: Color) -> Self {
        guard end > start else { return self }
        var copy = self
        copy.fills.append(TerminalGridFill(startColumn: start, endColumn: end, color: color))
        return copy
    }

    public func shape(_ shape: Shape) -> Self {
        var copy = self
        copy.overlayShape = shape.path.commands.isEmpty ? nil : shape
        return copy
    }

    /// Marks whether this row wraps cleanly into the next row without an intervening line break (`GridRow::wraps`).
    public func wraps(_ wraps: Bool = true) -> Self {
        var copy = self
        copy.wraps = wraps
        return copy
    }

    /// Character index in `readingText` for cell `column`, clamping wide cells to their start or past text to `end` (`GridRow::char_at`).
    internal static func charAt(columnPlaces: [(column: Int, width: Int)], column: Int) -> Int {
        columnPlaces.firstIndex { $0.column + max($0.width, 1) > column } ?? columnPlaces.count
    }

    /// Fingerprint of all row content and overlays so mutated or copied rows never alias stale cache entries.
    internal var contentFingerprint: UInt64 {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(spans)
        hasher.combine(style)
        hasher.combine(cells)
        hasher.combine(fills)
        if let over = overlayShape {
            hasher.combine(true)
            hasher.combine(over.viewBox?.x.bitPattern)
            hasher.combine(over.viewBox?.y.bitPattern)
            hasher.combine(over.trimStart.bitPattern)
            hasher.combine(over.trimEnd.bitPattern)
            hasher.combine(over.ops.count)
            for op in over.ops {
                switch op {
                case let .stroke(points, closed, width, cap, color):
                    hasher.combine(UInt8(0))
                    hasher.combine(closed)
                    hasher.combine(width.bitPattern)
                    hasher.combine(cap)
                    hasher.combine(color)
                    hasher.combine(points.count)
                    for p in points {
                        hasher.combine(p.x.bitPattern)
                        hasher.combine(p.y.bitPattern)
                    }
                case let .fill(points, color):
                    hasher.combine(UInt8(1))
                    hasher.combine(color)
                    hasher.combine(points.count)
                    for p in points {
                        hasher.combine(p.x.bitPattern)
                        hasher.combine(p.y.bitPattern)
                    }
                }
            }
            for cmd in over.path.commands {
                switch cmd {
                case let .moveTo(p):
                    hasher.combine(UInt8(10))
                    hasher.combine(p.x.bitPattern)
                    hasher.combine(p.y.bitPattern)
                case let .lineTo(p):
                    hasher.combine(UInt8(11))
                    hasher.combine(p.x.bitPattern)
                    hasher.combine(p.y.bitPattern)
                case let .quadTo(c, p):
                    hasher.combine(UInt8(12))
                    hasher.combine(c.x.bitPattern)
                    hasher.combine(c.y.bitPattern)
                    hasher.combine(p.x.bitPattern)
                    hasher.combine(p.y.bitPattern)
                case let .cubicTo(c1, c2, p):
                    hasher.combine(UInt8(13))
                    hasher.combine(c1.x.bitPattern)
                    hasher.combine(c1.y.bitPattern)
                    hasher.combine(c2.x.bitPattern)
                    hasher.combine(c2.y.bitPattern)
                    hasher.combine(p.x.bitPattern)
                    hasher.combine(p.y.bitPattern)
                case .close:
                    hasher.combine(UInt8(14))
                }
            }
        } else {
            hasher.combine(false)
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// Accessibility reading of the row: pinned cells spliced into their columns, trailing whitespace trimmed.
    public func readingText() -> (text: String, columnPlaces: [(column: Int, width: Int)]) {
        var cols: [(String, Int)] = text.map { (String($0), 1) }
        for c in cells {
            if cols.count < c.column + c.width {
                cols.append(contentsOf: Array(repeating: (" ", 1), count: c.column + c.width - cols.count))
            }
            cols[c.column] = (c.text, c.width)
            for k in (c.column + 1)..<(c.column + c.width) {
                cols[k] = ("", 0)
            }
        }
        let end = cols.lastIndex(where: { !$0.0.trimmingCharacters(in: .whitespaces).isEmpty }).map { $0 + 1 } ?? 0
        var out = ""
        var places: [(Int, Int)] = []
        for col in 0..<end {
            let (s, w) = cols[col]
            for (k, ch) in s.enumerated() {
                out.append(ch)
                places.append((col, k == 0 ? w : 0))
            }
        }
        return (out, places)
    }
}

/// Monospace terminal grid payload (`rune::el::grid`).
public struct TerminalGrid: Sendable {
    public var columns: Int
    public var cellSize: Vec2
    public var rows: [TerminalGridRow]
    /// Cursor cell `(column, row)` published as the grid's accessibility caret (`El::grid_caret`).
    public var caret: (column: Int, row: Int)?

    public init(
        columns: Int,
        cellWidth: Float,
        cellHeight: Float,
        rows: [TerminalGridRow],
        caret: (column: Int, row: Int)? = nil
    ) {
        self.columns = max(1, columns)
        self.cellSize = Vec2(cellWidth, cellHeight)
        self.rows = rows
        self.caret = caret
    }
}
