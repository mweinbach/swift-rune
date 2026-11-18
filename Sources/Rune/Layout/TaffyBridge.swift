import Foundation
import RuneMotion
import RuneTaffy

/// Translates `Rune.LayoutStyle` and `GridContainerStyle`/`GridItemStyle` into `RuneTaffy.TaffyStyle`
/// and runs single-shot (`TaffyTree`) or retained (`LayoutStore`) Taffy layout with Rune's
/// `aspect_fit`, `scroll_x` (`unwrapped_width`), and `border_layout` semantics.
enum TaffyBridge {
    struct UncheckedMeasureBox: @unchecked Sendable {
        let fn: (Float?) -> Vec2
    }

    enum ScrollXChild: Equatable {
        case single(vertical: Bool)
        case many(vertical: Bool)
    }

    // MARK: - Style Translation

    static func mapDirection(_ dir: FlexDirection) -> RuneTaffy.FlexDirection {
        switch dir {
        case .row: return .row
        case .column: return .column
        case .rowReverse: return .rowReverse
        case .columnReverse: return .columnReverse
        }
    }

    static func mapAlignItems(_ align: AlignItems) -> RuneTaffy.AlignItems {
        switch align {
        case .start: return .flexStart
        case .center: return .center
        case .end: return .flexEnd
        case .stretch: return .stretch
        }
    }

    static func mapJustifyContent(_ justify: JustifyContent) -> RuneTaffy.JustifyContent {
        switch justify {
        case .start: return .flexStart
        case .center: return .center
        case .end: return .flexEnd
        case .spaceBetween: return .spaceBetween
        case .spaceAround: return .spaceAround
        case .spaceEvenly: return .spaceEvenly
        }
    }

    static func mapDimension(_ dim: Dimension) -> RuneTaffy.Dimension {
        switch dim {
        case .auto: return .auto
        case .points(let v): return .length(max(0, v))
        case .fraction(let f): return .percent(max(0, f))
        case .minContent: return .minContent
        case .maxContent: return .maxContent
        case .fitContentPx(let v): return .fitContentPx(max(0, v))
        case .fitContentPercent(let p): return .fitContentPercent(max(0, p))
        }
    }

    static func mapMinTrack(_ track: GridTrack) -> RuneTaffy.MinTrackSizingFunction {
        switch track {
        case .px(let v): return .length(max(0, v))
        case .percent(let p): return .percent(max(0, p))
        case .auto, .fr, .minmax: return .auto
        case .minContent: return .minContent
        case .maxContent: return .maxContent
        }
    }

    static func mapMaxTrack(_ track: GridTrack) -> RuneTaffy.MaxTrackSizingFunction {
        switch track {
        case .px(let v): return .length(max(0, v))
        case .percent(let p): return .percent(max(0, p))
        case .fr(let f): return .fr(max(0, f))
        case .auto, .minmax: return .auto
        case .minContent: return .minContent
        case .maxContent: return .maxContent
        }
    }

    static func mapTrack(_ track: GridTrack) -> RuneTaffy.TrackSizingFunction {
        switch track {
        case .px(let v): return .length(max(0, v))
        case .fr(let f): return .fr(max(0, f))
        case .auto: return .auto
        case .percent(let p): return .percent(max(0, p))
        case .minContent: return .minContent
        case .maxContent: return .maxContent
        case .minmax(let mn, let mx):
            return .minmax(mapMinTrack(mn), mapMaxTrack(mx))
        }
    }

    static func mapGridAreas(_ areas: [[String]]) -> [String: RuneTaffy.GridTemplateArea] {
        var bounds: [String: (minR: Int, maxR: Int, minC: Int, maxC: Int)] = [:]
        for (r, row) in areas.enumerated() {
            for (c, rawName) in row.enumerated() {
                let name = rawName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, name != "." else { continue }
                if var b = bounds[name] {
                    b.minR = min(b.minR, r)
                    b.maxR = max(b.maxR, r)
                    b.minC = min(b.minC, c)
                    b.maxC = max(b.maxC, c)
                    bounds[name] = b
                } else {
                    bounds[name] = (r, r, c, c)
                }
            }
        }
        var out: [String: RuneTaffy.GridTemplateArea] = [:]
        out.reserveCapacity(bounds.count)
        for (name, b) in bounds {
            out[name] = RuneTaffy.GridTemplateArea(
                name: name,
                rowStart: UInt16(b.minR + 1),
                rowEnd: UInt16(b.maxR + 2),
                columnStart: UInt16(b.minC + 1),
                columnEnd: UInt16(b.maxC + 2)
            )
        }
        return out
    }

    static func mapPlacement(
        start: GridPlacement,
        end: GridPlacement?,
        namedArea: RuneTaffy.GridTemplateArea?,
        isRow: Bool
    ) -> RuneTaffy.Line<RuneTaffy.GridPlacement> {
        if let area = namedArea {
            let s = isRow ? area.rowStart : area.columnStart
            let e = isRow ? area.rowEnd : area.columnEnd
            return RuneTaffy.Line(start: .line(Int16(s)), end: .line(Int16(e)))
        }
        let mappedEnd: RuneTaffy.GridPlacement = end.map { mapSingleEnd($0) } ?? .auto
        switch start {
        case .auto:
            return RuneTaffy.Line(start: .auto, end: mappedEnd)
        case .line(let n):
            return RuneTaffy.Line(start: .line(Int16(n)), end: mappedEnd)
        case .span(let count):
            return RuneTaffy.Line(start: .span(UInt16(max(1, count))), end: mappedEnd)
        case .lineSpan(let line, let span):
            return RuneTaffy.Line(start: .line(Int16(line)), end: .span(UInt16(max(1, span))))
        case .area(let name):
            return RuneTaffy.Line(start: .namedLine(name, 1), end: .namedLine(name, -1))
        }
    }

    private static func mapSingleEnd(_ p: GridPlacement) -> RuneTaffy.GridPlacement {
        switch p {
        case .auto, .area: return .auto
        case .line(let n): return .line(Int16(n))
        case .span(let s): return .span(UInt16(max(1, s)))
        case .lineSpan(let line, _): return .line(Int16(line))
        }
    }

    static func snappedBorderSides(_ sides: Sides, pixelScale: Float) -> Sides {
        let s = max(pixelScale, 0.5)
        func snapLine(_ w: Float) -> Float {
            guard w > 0 else { return 0 }
            return PixelSnap.lineWidth(w * s) / s
        }
        return Sides(
            top: snapLine(sides.top),
            right: snapLine(sides.right),
            bottom: snapLine(sides.bottom),
            left: snapLine(sides.left)
        )
    }

    static func toTaffyStyle(
        _ style: LayoutStyle,
        parentAreas: [String: RuneTaffy.GridTemplateArea]? = nil,
        borderOverride: Sides? = nil,
        scrollXChild: ScrollXChild? = nil,
        forceScrollXRow: Bool = false
    ) -> RuneTaffy.TaffyStyle {
        var ts = RuneTaffy.TaffyStyle()

        if style.displayNone {
            ts.display = .none
        } else {
            switch style.displayMode {
            case .flex: ts.display = .flex
            case .grid: ts.display = .grid
            case .block: ts.display = .block
            }
        }

        if style.isAbsolute {
            ts.position = .absolute
        } else if style.sticky != nil {
            ts.position = .sticky
        } else {
            ts.position = .relative
        }

        ts.boxSizing = style.boxSizingBorderBox ? .borderBox : .contentBox

        let ox: RuneTaffy.Overflow = style.scrollAxes.contains(.horizontal)
            ? .scroll
            : (style.clipOverflow ? .hidden : .visible)
        let oy: RuneTaffy.Overflow = style.scrollAxes.contains(.vertical)
            ? .scroll
            : (style.clipOverflow ? .hidden : .visible)
        ts.overflow = RuneTaffy.Point(x: ox, y: oy)
        ts.scrollbarWidth = max(0, style.scrollbarWidth)

        ts.size = RuneTaffy.Size(width: mapDimension(style.width), height: mapDimension(style.height))
        ts.minSize = RuneTaffy.Size(width: mapDimension(style.minWidth), height: mapDimension(style.minHeight))
        ts.maxSize = RuneTaffy.Size(width: mapDimension(style.maxWidth), height: mapDimension(style.maxHeight))
        if let ratio = style.aspectRatio, ratio.isFinite, ratio > 0 {
            ts.aspectRatio = ratio
        }

        ts.margin = RuneTaffy.Rect(
            left: .length(style.margin.left),
            right: .length(style.margin.right),
            top: .length(style.margin.top),
            bottom: .length(style.margin.bottom)
        )
        ts.padding = RuneTaffy.Rect(
            left: .length(max(0, style.padding.left)),
            right: .length(max(0, style.padding.right)),
            top: .length(max(0, style.padding.top)),
            bottom: .length(max(0, style.padding.bottom))
        )
        let b = borderOverride ?? style.border
        ts.border = RuneTaffy.Rect(
            left: .length(max(0, b.left)),
            right: .length(max(0, b.right)),
            top: .length(max(0, b.top)),
            bottom: .length(max(0, b.bottom))
        )
        ts.inset = RuneTaffy.Rect(
            left: style.pinLeft.map { .length($0) } ?? .auto,
            right: style.pinRight.map { .length($0) } ?? .auto,
            top: style.pinTop.map { .length($0) } ?? .auto,
            bottom: style.pinBottom.map { .length($0) } ?? .auto
        )
        ts.gap = RuneTaffy.Size(
            width: .length(max(0, style.columnGap)),
            height: .length(max(0, style.rowGap))
        )

        ts.wholeRows = style.wholeRows
        ts.flexDirection = forceScrollXRow ? .row : mapDirection(style.direction)
        ts.flexWrap = style.wrapReverse ? .wrapReverse : (style.wrap ? .wrap : .noWrap)
        ts.flexGrow = max(0, style.flexGrow)
        ts.flexShrink = max(0, style.flexShrink)
        ts.flexBasis = mapDimension(style.flexBasis)

        ts.alignItems = mapAlignItems(style.alignItems)
        ts.alignSelf = style.alignSelf.map(mapAlignItems)
        ts.justifyContent = mapJustifyContent(style.justifyContent)
        ts.alignContent = style.alignContent.map(mapJustifyContent)

        if style.displayMode == .grid, let g = style.grid {
            ts.gridTemplateColumns = g.templateColumns.map { .single(mapTrack($0)) }
            ts.gridTemplateRows = g.templateRows.map { .single(mapTrack($0)) }
            ts.gridAutoColumns = g.autoColumns.map(mapTrack)
            ts.gridAutoRows = g.autoRows.map(mapTrack)
            switch g.autoFlow {
            case .row: ts.gridAutoFlow = .row
            case .column: ts.gridAutoFlow = .column
            case .rowDense: ts.gridAutoFlow = .rowDense
            case .columnDense: ts.gridAutoFlow = .columnDense
            }
            ts.justifyItems = mapAlignItems(g.justifyItems)
            ts.justifyContent = mapJustifyContent(g.justifyContent)
            ts.alignContent = mapJustifyContent(g.alignContent)
            let areaMap = mapGridAreas(g.templateAreas)
            ts.gridTemplateAreas = Array(areaMap.values)
        } else if style.alignContent == nil, let g = style.grid {
            ts.alignContent = mapJustifyContent(g.alignContent)
        }

        if let gi = style.gridItem {
            let areaName: String?
            if let explicit = gi.area {
                areaName = explicit
            } else if case .area(let colArea) = gi.column {
                areaName = colArea
            } else if case .area(let rowArea) = gi.row {
                areaName = rowArea
            } else {
                areaName = nil
            }
            let resolvedArea = areaName.flatMap { parentAreas?[$0] }
            ts.gridRow = mapPlacement(start: gi.row, end: gi.rowEnd, namedArea: resolvedArea, isRow: true)
            ts.gridColumn = mapPlacement(start: gi.column, end: gi.columnEnd, namedArea: resolvedArea, isRow: false)
            if let js = gi.justifySelf {
                ts.justifySelf = mapAlignItems(js)
            }
        }

        if let sx = scrollXChild {
            applyScrollXChild(&ts, sx)
        }

        return ts
    }

    /// Upstream `unwrapped_width` (`runtime/commit.rs:195`, `flatten.rs:196`): horizontal scroll
    /// content without a fixed width takes `width: max-content` and never shrinks. `.single` sets
    /// `min-width: 100%` for `w.isAuto || wFull`; `.many` only sets it for `wFull` (`w == 100%`)
    /// so multiple auto-width siblings don't expand to 100% each.
    static func applyScrollXChild(_ style: inout RuneTaffy.TaffyStyle, _ sx: ScrollXChild) {
        let vertical: Bool
        let setMinWidthFull: Bool
        let w = style.size.width
        let wFull = (w == .percent(1.0))
        switch sx {
        case .single(let v):
            vertical = v
            setMinWidthFull = (w.isAuto || wFull)
        case .many(let v):
            vertical = v
            setMinWidthFull = wFull
        }
        if w.isAuto || wFull {
            style.size.width = .maxContent
            if setMinWidthFull && style.minSize.width.isAuto {
                style.minSize.width = .percent(1.0)
            }
        }
        style.flexShrink = 0.0
        if vertical && style.alignSelf == nil {
            style.alignSelf = .flexStart
        }
    }

    /// Upstream `fit_room` (`runtime/commit/flatten.rs:10`): first-pass room box for `aspect_fit`.
    /// Preserves `raw.maxSize` on both axes while setting `flexGrow = 1`, `flexShrink = 1`,
    /// `flexBasis = 0` when `mainMax` is auto so content never sizes the room.
    static func fitRoomStyle(raw: RuneTaffy.TaffyStyle, parentRow: Bool) -> RuneTaffy.TaffyStyle {
        var s = raw
        let mainMax = parentRow ? raw.maxSize.width : raw.maxSize.height
        s.size = raw.maxSize
        s.minSize = RuneTaffy.Size(
            width: raw.minSize.width.isAuto ? .length(0) : raw.minSize.width,
            height: raw.minSize.height.isAuto ? .length(0) : raw.minSize.height
        )
        s.flexGrow = 1.0
        s.flexShrink = 1.0
        s.flexBasis = mainMax.isAuto ? .length(0) : .auto
        s.alignSelf = .stretch
        s.aspectRatio = nil
        return s
    }

    /// Upstream `fitted` (`runtime/commit/flatten.rs:28`): second-pass fixed box at `ratio` inside `room`.
    static func fittedStyle(ratio: Float, raw: RuneTaffy.TaffyStyle, room: RuneTaffy.Size<Float>) -> RuneTaffy.TaffyStyle {
        let safeRatio = max(ratio, 0.0001)
        let w = max(0, min(room.width, room.height * safeRatio))
        var s = raw
        s.size = RuneTaffy.Size(width: .length(w), height: .length(w / safeRatio))
        s.flexGrow = 0.0
        s.flexShrink = 0.0
        s.flexBasis = .auto
        s.aspectRatio = nil
        return s
    }

    // MARK: - Scroll Content Extent Helper

    struct ContentExtent {
        private(set) var size: Vec2
        private let trailingInset: Vec2

        init(_ own: RuneTaffy.Layout) {
            size = Vec2(max(own.size.width, own.contentSize.width), max(own.size.height, own.contentSize.height))
            trailingInset = Vec2(own.padding.right + own.border.right, own.padding.bottom + own.border.bottom)
        }

        struct Child {
            let participates: Bool
            let overflowX: Bool
            let overflowY: Bool

            init(_ style: RuneTaffy.TaffyStyle) {
                participates = style.display != .none && style.position != .absolute && style.position != .fixed
                overflowX = style.overflow.x == .visible
                overflowY = style.overflow.y == .visible
            }
        }

        mutating func include(_ child: RuneTaffy.Layout, style: Child, content: Vec2) {
            guard style.participates else { return }
            let width = style.overflowX ? max(child.size.width, content.x) : child.size.width
            let height = style.overflowY ? max(child.size.height, content.y) : child.size.height
            size.x = max(size.x, child.location.x + width + child.margin.right + trailingInset.x)
            size.y = max(size.y, child.location.y + height + child.margin.bottom + trailingInset.y)
        }
    }

    // MARK: - Single-Shot LayoutEngine.compute

    static func compute(root: LayoutInputNode, viewport: Vec2) -> LayoutEngine.ResultNode {
        var tree = RuneTaffy.TaffyTree()
        tree.roundingEnabled = false

        var aspectFitNodes: [(id: RuneTaffy.NodeId, ratio: Float, raw: RuneTaffy.TaffyStyle)] = []
        var nodeStyles: [RuneTaffy.NodeId: RuneTaffy.TaffyStyle] = [:]

        func build(
            _ node: LayoutInputNode,
            isRoot: Bool,
            parentRow: Bool,
            parentAreas: [String: RuneTaffy.GridTemplateArea]?,
            scrollXChild: ScrollXChild?
        ) -> RuneTaffy.NodeId {
            var style = node.style
            if isRoot {
                if style.width == .auto {
                    style.width = .points(viewport.x)
                }
                if style.height == .auto {
                    style.height = .points(viewport.y)
                }
            }

            let areas: [String: RuneTaffy.GridTemplateArea]? = style.grid.map { mapGridAreas($0.templateAreas) }
            let hasScrollX = style.scrollAxes.contains(.horizontal)
            let forceRow = style.forcesHorizontalFlexRow(childCount: node.children.count)
            let childSX: ScrollXChild?
            if hasScrollX {
                let v = style.scrollAxes.contains(.vertical)
                childSX = (node.children.count == 1) ? .single(vertical: v) : .many(vertical: v)
            } else {
                childSX = nil
            }

            let rawTaffy = toTaffyStyle(
                style,
                parentAreas: parentAreas,
                scrollXChild: scrollXChild,
                forceScrollXRow: forceRow
            )

            let effectiveTaffy: RuneTaffy.TaffyStyle
            if let ratio = style.aspectFit, ratio.isFinite, ratio > 0 {
                effectiveTaffy = fitRoomStyle(raw: rawTaffy, parentRow: parentRow)
            } else {
                effectiveTaffy = rawTaffy
            }

            let isRow = effectiveTaffy.flexDirection.isRow
            let childIds = node.children.map {
                build($0, isRoot: false, parentRow: isRow, parentAreas: areas, scrollXChild: childSX)
            }

            let id: RuneTaffy.NodeId
            if childIds.isEmpty, let measureFn = node.measure {
                let box = UncheckedMeasureBox(fn: measureFn)
                id = tree.newLeafWithMeasure(effectiveTaffy) { known, avail, _ in
                    let maxW: Float?
                    switch avail.width {
                    case .definite(let w): maxW = max(0, w)
                    case .minContent: maxW = 0
                    case .maxContent: maxW = nil
                    }
                    let measured = box.fn(maxW)
                    return RuneTaffy.Size(
                        width: known.width ?? measured.x,
                        height: known.height ?? measured.y
                    )
                }
            } else {
                id = (try? tree.newWithChildren(effectiveTaffy, children: childIds)) ?? tree.newLeaf(effectiveTaffy)
            }

            nodeStyles[id] = effectiveTaffy
            if let ratio = style.aspectFit, ratio.isFinite, ratio > 0 {
                aspectFitNodes.append((id: id, ratio: ratio, raw: rawTaffy))
            }
            return id
        }

        let rootId = build(root, isRoot: true, parentRow: false, parentAreas: nil, scrollXChild: nil)
        let available = RuneTaffy.Size<RuneTaffy.AvailableSpace>(
            width: .definite(viewport.x),
            height: .definite(viewport.y)
        )
        try? tree.computeLayout(rootId, availableSpace: available)

        if !aspectFitNodes.isEmpty {
            for entry in aspectFitNodes {
                let roomLayout = (try? tree.unroundedLayout(entry.id)) ?? RuneTaffy.Layout.zero
                let fitted = fittedStyle(ratio: entry.ratio, raw: entry.raw, room: roomLayout.size)
                try? tree.setStyle(entry.id, fitted)
                nodeStyles[entry.id] = fitted
            }
            try? tree.computeLayout(rootId, availableSpace: available)
        }

        func extract(_ node: LayoutInputNode, _ id: RuneTaffy.NodeId, _ taffyLayout: RuneTaffy.Layout) -> LayoutEngine.ResultNode {
            let childIds = (try? tree.children(id)) ?? []

            var childResults: [LayoutEngine.ResultNode] = []
            childResults.reserveCapacity(childIds.count)
            var content = ContentExtent(taffyLayout)
            for (i, cid) in childIds.enumerated() where i < node.children.count {
                let childLayout = (try? tree.unroundedLayout(cid)) ?? .zero
                let child = extract(node.children[i], cid, childLayout)
                childResults.append(child)
                content.include(childLayout, style: ContentExtent.Child(nodeStyles[cid] ?? RuneTaffy.TaffyStyle()), content: child.layout.contentSize)
            }

            return LayoutEngine.ResultNode(
                layout: ComputedLayout(
                    localRect: MotionRect.fromXYWH(
                        taffyLayout.location.x,
                        taffyLayout.location.y,
                        taffyLayout.size.width,
                        taffyLayout.size.height
                    ),
                    localSize: Vec2(taffyLayout.size.width, taffyLayout.size.height),
                    contentSize: content.size
                ),
                children: childResults
            )
        }

        return extract(root, rootId, (try? tree.unroundedLayout(rootId)) ?? .zero)
    }
}
