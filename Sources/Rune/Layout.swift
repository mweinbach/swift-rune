import Foundation
import RuneMotion

public enum FlexDirection: Sendable, Hashable, Codable {
    case row
    case column
}

public enum AlignItems: Sendable, Hashable, Codable {
    case start
    case center
    case end
    case stretch
}

public enum JustifyContent: Sendable, Hashable, Codable {
    case start
    case center
    case end
    case spaceBetween
    case spaceAround
    case spaceEvenly
}

public enum Dimension: Sendable, Hashable, Codable {
    case auto
    case points(Float)
    case fraction(Float)

    @inlinable
    public func resolve(against available: Float?) -> Float? {
        switch self {
        case .auto:
            return nil
        case .points(let pt):
            return max(0, pt)
        case .fraction(let f):
            guard let avail = available, avail.isFinite else { return nil }
            return max(0, avail * f)
        }
    }
}

public struct ScrollAxes: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let vertical = ScrollAxes(rawValue: 1 << 0)
    public static let horizontal = ScrollAxes(rawValue: 1 << 1)
    public static let both: ScrollAxes = [.vertical, .horizontal]
}

public enum StickyEdge: Sendable, Hashable, Codable {
    case top(Float)
    case bottom(Float)
}

/// Complete CSS Flexbox + Grid + Block + Absolute + Scroll layout style for a single `El`.
public struct LayoutStyle: Sendable, Hashable {
    public var displayMode: LayoutMode = .flex
    public var direction: FlexDirection = .row
    public var wrap: Bool = false
    public var alignItems: AlignItems = .stretch
    public var alignSelf: AlignItems? = nil
    public var justifyContent: JustifyContent = .start

    public var grid: GridContainerStyle? = nil
    public var gridItem: GridItemStyle? = nil

    public var width: Dimension = .auto
    public var height: Dimension = .auto
    public var minWidth: Dimension = .auto
    public var minHeight: Dimension = .auto
    public var maxWidth: Dimension = .auto
    public var maxHeight: Dimension = .auto

    public var flexGrow: Float = 0
    public var flexShrink: Float = 1
    public var flexBasis: Dimension = .auto

    public var aspectRatio: Float? = nil
    public var aspectFit: Float? = nil

    public var padding: Sides = .all(0)
    public var margin: Sides = .all(0)
    public var rowGap: Float = 0
    public var columnGap: Float = 0

    public var isAbsolute: Bool = false
    public var pinLeft: Float? = nil
    public var pinTop: Float? = nil
    public var pinRight: Float? = nil
    public var pinBottom: Float? = nil

    public var scrollAxes: ScrollAxes = []
    public var stickBottom: Bool = false
    public var clipOverflow: Bool = false
    public var sticky: StickyEdge? = nil

    public init(direction: FlexDirection = .row) {
        self.direction = direction
    }
}

/// Computed layout box for a single node (in window logical points prior to scroll translation).
public struct ComputedLayout: Sendable, Equatable {
    /// Local offset `(x, y)` relative to parent's top-left border box, plus `(width, height)`.
    public var localRect: MotionRect
    /// Content extent `(width, height)` inside scrollable containers.
    public var contentSize: Vec2

    public init(localRect: MotionRect = .zero, contentSize: Vec2 = .zero) {
        self.localRect = localRect
        self.contentSize = contentSize
    }
}

/// Lightweight input node for `LayoutEngine` so layout stays decoupled from generic `State` handlers.
public struct LayoutInputNode {
    public var style: LayoutStyle
    public var children: [LayoutInputNode]
    /// Optional intrinsic measurement callback `(maxWidth: Float?) -> Vec2` (used by text & icons).
    public var measure: ((Float?) -> Vec2)?

    public init(
        style: LayoutStyle,
        children: [LayoutInputNode] = [],
        measure: ((Float?) -> Vec2)? = nil
    ) {
        self.style = style
        self.children = children
        self.measure = measure
    }
}

/// Pure, single-pass-with-cache CSS Flexbox layout solver.
public enum LayoutEngine {
    public struct ResultNode: Sendable {
        public var layout: ComputedLayout
        public var children: [ResultNode]
    }

    public static func compute(root: LayoutInputNode, viewport: Vec2) -> ResultNode {
        var rootModified = root
        if rootModified.style.width == .auto {
            rootModified.style.width = .points(viewport.x)
        }
        if rootModified.style.height == .auto {
            rootModified.style.height = .points(viewport.y)
        }
        let solved = layoutNode(
            rootModified,
            availableWidth: viewport.x,
            availableHeight: viewport.y,
            forcedWidth: rootModified.style.width.resolve(against: viewport.x),
            forcedHeight: rootModified.style.height.resolve(against: viewport.y)
        )
        return solved
    }

    private static func layoutNode(
        _ node: LayoutInputNode,
        availableWidth: Float?,
        availableHeight: Float?,
        forcedWidth: Float?,
        forcedHeight: Float?
    ) -> ResultNode {
        if node.style.displayMode == .grid {
            return GridAndBlockSolver.layoutGrid(
                node,
                availableWidth: availableWidth,
                availableHeight: availableHeight,
                forcedWidth: forcedWidth,
                forcedHeight: forcedHeight,
                childLayout: layoutNode
            )
        }
        if node.style.displayMode == .block && !node.children.isEmpty {
            return GridAndBlockSolver.layoutBlock(
                node,
                availableWidth: availableWidth,
                availableHeight: availableHeight,
                forcedWidth: forcedWidth,
                forcedHeight: forcedHeight,
                childLayout: layoutNode
            )
        }

        let s = node.style
        let padH = s.padding.left + s.padding.right
        let padV = s.padding.top + s.padding.bottom

        // Resolve explicit & min/max constraints on outer box
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

        // Aspect fit (`object-fit: contain` for the box itself)
        if let fitRatio = s.aspectFit, fitRatio > 0 {
            let finiteMinW = min(maxW ?? .infinity, min(resolvedW ?? .infinity, availableWidth ?? .infinity))
            let roomW = finiteMinW.isFinite ? finiteMinW : 0
            let finiteMinH = min(maxH ?? .infinity, min(resolvedH ?? .infinity, availableHeight ?? .infinity))
            let roomH = finiteMinH.isFinite ? finiteMinH : (roomW / fitRatio)
            if roomW > 0 && roomH > 0 {
                if roomW / roomH > fitRatio {
                    resolvedH = clampH(roomH)
                    resolvedW = clampW(resolvedH! * fitRatio)
                } else {
                    resolvedW = clampW(roomW)
                    resolvedH = clampH(resolvedW! / fitRatio)
                }
            }
        } else if let ar = s.aspectRatio, ar > 0 {
            if let w = resolvedW, resolvedH == nil {
                resolvedH = clampH(w / ar)
            } else if let h = resolvedH, resolvedW == nil {
                resolvedW = clampW(h * ar)
            }
        }

        if let w = resolvedW { resolvedW = clampW(w) }
        if let h = resolvedH { resolvedH = clampH(h) }

        // Leaf node with intrinsic measure (e.g. text / rich text / icon)
        if node.children.isEmpty, let measure = node.measure {
            let innerMaxW: Float?
            if let w = resolvedW {
                innerMaxW = max(0, w - padH)
            } else if let maxW {
                innerMaxW = max(0, maxW - padH)
            } else if let availW = availableWidth {
                innerMaxW = max(0, availW - padH)
            } else {
                innerMaxW = nil
            }
            let intrinsic = measure(innerMaxW)
            let finalW = resolvedW ?? clampW(intrinsic.x + padH)
            let finalH = resolvedH ?? clampH(intrinsic.y + padV)
            return ResultNode(
                layout: ComputedLayout(
                    localRect: MotionRect.fromXYWH(0, 0, finalW, finalH),
                    contentSize: Vec2(intrinsic.x + padH, intrinsic.y + padV)
                ),
                children: []
            )
        }

        if node.children.isEmpty {
            let finalW = resolvedW ?? clampW(padH)
            let finalH = resolvedH ?? clampH(padV)
            return ResultNode(
                layout: ComputedLayout(
                    localRect: MotionRect.fromXYWH(0, 0, finalW, finalH),
                    contentSize: Vec2(finalW, finalH)
                ),
                children: []
            )
        }

        // Partition children into in-flow flex items and out-of-flow `.isAbsolute` children
        let isRow = (s.direction == .row)
        let mainGap = isRow ? s.columnGap : s.rowGap
        let crossGap = isRow ? s.rowGap : s.columnGap

        let innerAvailW: Float? = s.scrollAxes.contains(.horizontal)
            ? nil
            : (resolvedW ?? maxW ?? availableWidth).map { max(0, $0 - padH) }
        let innerAvailH: Float? = s.scrollAxes.contains(.vertical)
            ? nil
            : (resolvedH ?? maxH ?? availableHeight).map { max(0, $0 - padV) }

        let containerMain: Float? = isRow
            ? resolvedW.map { max(0, $0 - padH) }
            : resolvedH.map { max(0, $0 - padV) }
        let containerCross: Float? = isRow
            ? resolvedH.map { max(0, $0 - padV) }
            : resolvedW.map { max(0, $0 - padH) }

        var childResults = Array(
            repeating: ResultNode(layout: ComputedLayout(), children: []),
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

        struct FlexItem {
            var childIndex: Int
            var baseMain: Float
            var hypotheticalMain: Float
            var minMain: Float
            var maxMain: Float?
            var marginMainStart: Float
            var marginMainEnd: Float
            var marginCrossStart: Float
            var marginCrossEnd: Float
            var grow: Float
            var shrink: Float
            var finalMain: Float = 0
            var finalCross: Float = 0
            var solved: ResultNode? = nil
        }

        var items: [FlexItem] = []
        items.reserveCapacity(flowIndices.count)

        for idx in flowIndices {
            let child = node.children[idx]
            let cs = child.style
            let mMainStart = isRow ? cs.margin.left : cs.margin.top
            let mMainEnd = isRow ? cs.margin.right : cs.margin.bottom
            let mCrossStart = isRow ? cs.margin.top : cs.margin.left
            let mCrossEnd = isRow ? cs.margin.bottom : cs.margin.right

            let explicitMain = isRow
                ? cs.width.resolve(against: innerAvailW)
                : cs.height.resolve(against: innerAvailH)
            let basisResolved = cs.flexBasis.resolve(against: isRow ? innerAvailW : innerAvailH)

            let baseMain: Float
            var preSolved: ResultNode? = nil
            if let b = basisResolved {
                baseMain = b
            } else if let em = explicitMain {
                baseMain = em
            } else {
                // Measure child intrinsically
                let align = cs.alignSelf ?? s.alignItems
                let preCrossForce: Float? = (align == .stretch && (isRow ? cs.height == .auto : cs.width == .auto))
                    ? containerCross.map { max(0, $0 - mCrossStart - mCrossEnd) }
                    : nil
                let probe = layoutNode(
                    child,
                    availableWidth: innerAvailW.map { max(0, $0 - cs.margin.left - cs.margin.right) },
                    availableHeight: innerAvailH.map { max(0, $0 - cs.margin.top - cs.margin.bottom) },
                    forcedWidth: isRow ? nil : preCrossForce,
                    forcedHeight: isRow ? preCrossForce : nil
                )
                baseMain = isRow ? probe.layout.localRect.width : probe.layout.localRect.height
                preSolved = probe
            }

            let explicitMinMain = isRow
                ? cs.minWidth.resolve(against: innerAvailW)
                : cs.minHeight.resolve(against: innerAvailH)
            let explicitMaxMain = isRow
                ? cs.maxWidth.resolve(against: innerAvailW)
                : cs.maxHeight.resolve(against: innerAvailH)

            // CSS Flexbox automatic minimum size: scrollable boxes default to 0 min-size on scroll axis;
            // non-scroll boxes respect explicit minW/minH (e.g. `.minH(0)`), or content baseMain when `grow == 0`.
            let minMain: Float
            if let em = explicitMinMain {
                minMain = em
            } else if (isRow && !cs.scrollAxes.isEmpty) || (!isRow && !cs.scrollAxes.isEmpty) {
                minMain = 0
            } else if cs.flexGrow > 0 && cs.flexBasis != .auto {
                minMain = 0
            } else {
                minMain = min(baseMain, explicitMain ?? 0)
            }

            var hyp = max(baseMain, minMain)
            if let maxM = explicitMaxMain { hyp = min(hyp, maxM) }

            items.append(FlexItem(
                childIndex: idx,
                baseMain: baseMain,
                hypotheticalMain: hyp,
                minMain: minMain,
                maxMain: explicitMaxMain,
                marginMainStart: mMainStart,
                marginMainEnd: mMainEnd,
                marginCrossStart: mCrossStart,
                marginCrossEnd: mCrossEnd,
                grow: max(0, cs.flexGrow),
                shrink: max(0, cs.flexShrink),
                finalMain: hyp,
                solved: (hyp == baseMain) ? preSolved : nil
            ))
        }

        // Group flex items into lines (1 line unless `s.wrap` is enabled and main limit is known)
        let wrapLimit: Float? = s.wrap
            ? (containerMain ?? (isRow ? maxW.map { max(0, $0 - padH) } ?? innerAvailW : maxH.map { max(0, $0 - padV) } ?? innerAvailH))
            : nil

        var lines: [Range<Int>] = []
        if items.isEmpty {
            lines = []
        } else if let limit = wrapLimit, s.wrap {
            var lineStart = 0
            var accum: Float = 0
            for i in 0..<items.count {
                let outerMain = items[i].hypotheticalMain + items[i].marginMainStart + items[i].marginMainEnd
                let gapBefore = (i > lineStart) ? mainGap : 0
                if i > lineStart && accum + gapBefore + outerMain > limit + 0.01 {
                    lines.append(lineStart..<i)
                    lineStart = i
                    accum = outerMain
                } else {
                    accum += gapBefore + outerMain
                }
            }
            lines.append(lineStart..<items.count)
        } else {
            lines = [0..<items.count]
        }

        // Resolve flexible lengths along each line, then solve final child boxes and line cross heights
        struct SolvedLine {
            var range: Range<Int>
            var usedMain: Float
            var crossSize: Float
        }

        var solvedLines: [SolvedLine] = []
        solvedLines.reserveCapacity(lines.count)
        var maxLineMain: Float = 0
        var totalLinesCross: Float = 0

        for (lineIdx, range) in lines.enumerated() {
            let countInLine = range.count
            let totalGaps = countInLine > 1 ? Float(countInLine - 1) * mainGap : 0
            var sumHyp: Float = totalGaps
            var totalGrow: Float = 0
            var totalScaledShrink: Float = 0

            for i in range {
                sumHyp += items[i].hypotheticalMain + items[i].marginMainStart + items[i].marginMainEnd
                totalGrow += items[i].grow
                totalScaledShrink += items[i].shrink * max(items[i].baseMain, 0)
            }

            if let targetMain = containerMain {
                let initialFree = targetMain - sumHyp
                if initialFree > 1e-4 && totalGrow > 0 {
                    var frozen = Set<Int>()
                    var remainingSpace = targetMain - totalGaps
                    for i in range {
                        remainingSpace -= (items[i].marginMainStart + items[i].marginMainEnd)
                    }
                    // Iterative freeze loop for min/max violations during flex-grow
                    while true {
                        var activeGrow: Float = 0
                        var unfrozenBase: Float = 0
                        for i in range where !frozen.contains(i) {
                            if items[i].grow > 0 {
                                activeGrow += items[i].grow
                                unfrozenBase += items[i].baseMain
                            } else {
                                frozen.insert(i)
                                remainingSpace -= items[i].hypotheticalMain
                            }
                        }
                        if activeGrow <= 0 { break }
                        let free = max(0, remainingSpace - unfrozenBase)
                        var newlyFrozen = false
                        for i in range where !frozen.contains(i) {
                            let target = items[i].baseMain + free * (items[i].grow / activeGrow)
                            var clamped = max(target, items[i].minMain)
                            if let mx = items[i].maxMain { clamped = min(clamped, mx) }
                            items[i].finalMain = clamped
                            items[i].solved = nil
                            if abs(clamped - target) > 1e-4 {
                                frozen.insert(i)
                                remainingSpace -= clamped
                                newlyFrozen = true
                            }
                        }
                        if !newlyFrozen { break }
                    }
                } else if initialFree < -1e-4 && totalScaledShrink > 0 {
                    var frozen = Set<Int>()
                    var remainingSpace = targetMain - totalGaps
                    for i in range {
                        remainingSpace -= (items[i].marginMainStart + items[i].marginMainEnd)
                    }
                    // Iterative freeze loop for min/max violations during flex-shrink
                    while true {
                        var activeScaledShrink: Float = 0
                        var unfrozenBase: Float = 0
                        for i in range where !frozen.contains(i) {
                            let scaled = items[i].shrink * max(items[i].baseMain, 0)
                            if scaled > 0 {
                                activeScaledShrink += scaled
                                unfrozenBase += items[i].baseMain
                            } else {
                                frozen.insert(i)
                                remainingSpace -= items[i].hypotheticalMain
                            }
                        }
                        if activeScaledShrink <= 0 { break }
                        let deficit = max(0, unfrozenBase - remainingSpace)
                        var newlyFrozen = false
                        for i in range where !frozen.contains(i) {
                            let weight = (items[i].shrink * max(items[i].baseMain, 0)) / activeScaledShrink
                            let target = max(0, items[i].baseMain - deficit * weight)
                            var clamped = max(target, items[i].minMain)
                            if let mx = items[i].maxMain { clamped = min(clamped, mx) }
                            items[i].finalMain = clamped
                            items[i].solved = nil
                            if abs(clamped - target) > 1e-4 {
                                frozen.insert(i)
                                remainingSpace -= clamped
                                newlyFrozen = true
                            }
                        }
                        if !newlyFrozen { break }
                    }
                }
            }

            // First pass on cross size for items in this line
            var lineCross: Float = 0
            var usedMain: Float = totalGaps
            let singleLineDefiniteCross: Float? = (lines.count == 1) ? containerCross : nil

            for i in range {
                let child = node.children[items[i].childIndex]
                let cs = child.style
                let align = cs.alignSelf ?? s.alignItems
                let stretchCross: Float?
                if align == .stretch,
                   let defCross = singleLineDefiniteCross,
                   (isRow ? cs.height == .auto : cs.width == .auto) {
                    stretchCross = max(0, defCross - items[i].marginCrossStart - items[i].marginCrossEnd)
                } else {
                    stretchCross = nil
                }

                let res: ResultNode
                if let cached = items[i].solved, stretchCross == nil {
                    res = cached
                } else {
                    res = layoutNode(
                        child,
                        availableWidth: isRow ? items[i].finalMain : (singleLineDefiniteCross ?? innerAvailW),
                        availableHeight: isRow ? (singleLineDefiniteCross ?? innerAvailH) : items[i].finalMain,
                        forcedWidth: isRow ? items[i].finalMain : stretchCross,
                        forcedHeight: isRow ? stretchCross : items[i].finalMain
                    )
                }
                items[i].solved = res
                items[i].finalMain = isRow ? res.layout.localRect.width : res.layout.localRect.height
                items[i].finalCross = isRow ? res.layout.localRect.height : res.layout.localRect.width

                usedMain += items[i].finalMain + items[i].marginMainStart + items[i].marginMainEnd
                lineCross = max(lineCross, items[i].finalCross + items[i].marginCrossStart + items[i].marginCrossEnd)
            }

            if lines.count == 1, let defCross = singleLineDefiniteCross {
                lineCross = defCross
            }

            // Second pass for stretched items whose cross wasn't known until `lineCross` was measured!
            for i in range {
                let child = node.children[items[i].childIndex]
                let cs = child.style
                let align = cs.alignSelf ?? s.alignItems
                if align == .stretch && (isRow ? cs.height == .auto : cs.width == .auto) {
                    let targetCross = max(0, lineCross - items[i].marginCrossStart - items[i].marginCrossEnd)
                    if abs(items[i].finalCross - targetCross) > 0.01 {
                        let res = layoutNode(
                            child,
                            availableWidth: isRow ? items[i].finalMain : targetCross,
                            availableHeight: isRow ? targetCross : items[i].finalMain,
                            forcedWidth: isRow ? items[i].finalMain : targetCross,
                            forcedHeight: isRow ? targetCross : items[i].finalMain
                        )
                        items[i].solved = res
                        items[i].finalCross = isRow ? res.layout.localRect.height : res.layout.localRect.width
                    }
                }
            }

            maxLineMain = max(maxLineMain, usedMain)
            totalLinesCross += lineCross + (lineIdx > 0 ? crossGap : 0)
            solvedLines.append(SolvedLine(range: range, usedMain: usedMain, crossSize: lineCross))
        }

        // Determine final outer dimensions of this container
        let contentBoxMain = containerMain ?? maxLineMain
        let contentBoxCross = containerCross ?? totalLinesCross
        var finalOuterW = resolvedW ?? clampW((isRow ? contentBoxMain : contentBoxCross) + padH)
        var finalOuterH = resolvedH ?? clampH((isRow ? contentBoxCross : contentBoxMain) + padV)
        if let ar = s.aspectRatio, ar > 0 {
            if resolvedW != nil && resolvedH == nil {
                finalOuterH = clampH(finalOuterW / ar)
            } else if resolvedH != nil && resolvedW == nil {
                finalOuterW = clampW(finalOuterH * ar)
            }
        }

        let finalInnerMain = max(0, (isRow ? finalOuterW - padH : finalOuterH - padV))
        let finalInnerCross = max(0, (isRow ? finalOuterH - padV : finalOuterW - padH))
        let mainPadStart = isRow ? s.padding.left : s.padding.top
        let crossPadStart = isRow ? s.padding.top : s.padding.left

        // Position each line and each flex item using `justifyContent` and `alignItems` / `alignSelf`
        var crossCursor = crossPadStart
        var maxContentX: Float = finalOuterW
        var maxContentY: Float = finalOuterH

        for line in solvedLines {
            let countInLine = line.range.count
            let leftoverMain = max(0, finalInnerMain - line.usedMain)
            var mainStartOffset: Float = 0
            var extraBetween: Float = 0

            switch s.justifyContent {
            case .start:
                mainStartOffset = 0
            case .center:
                mainStartOffset = leftoverMain * 0.5
            case .end:
                mainStartOffset = leftoverMain
            case .spaceBetween:
                if countInLine > 1 {
                    extraBetween = leftoverMain / Float(countInLine - 1)
                }
            case .spaceAround:
                if countInLine > 0 {
                    let unit = leftoverMain / Float(countInLine)
                    mainStartOffset = unit * 0.5
                    extraBetween = unit
                }
            case .spaceEvenly:
                if countInLine > 0 {
                    let unit = leftoverMain / Float(countInLine + 1)
                    mainStartOffset = unit
                    extraBetween = unit
                }
            }

            var mainCursor = mainPadStart + mainStartOffset
            for i in line.range {
                let item = items[i]
                let child = node.children[item.childIndex]
                let align = child.style.alignSelf ?? s.alignItems
                let freeCross = line.crossSize - (item.finalCross + item.marginCrossStart + item.marginCrossEnd)

                let crossOffset: Float
                switch align {
                case .start, .stretch:
                    crossOffset = item.marginCrossStart
                case .center:
                    crossOffset = item.marginCrossStart + freeCross * 0.5
                case .end:
                    crossOffset = item.marginCrossStart + freeCross
                }

                let itemMainPos = mainCursor + item.marginMainStart
                let itemCrossPos = crossCursor + crossOffset
                let x = isRow ? itemMainPos : itemCrossPos
                let y = isRow ? itemCrossPos : itemMainPos
                let w = isRow ? item.finalMain : item.finalCross
                let h = isRow ? item.finalCross : item.finalMain

                var solved = item.solved ?? ResultNode(layout: ComputedLayout(), children: [])
                solved.layout.localRect = MotionRect.fromXYWH(x, y, w, h)
                childResults[item.childIndex] = solved

                maxContentX = max(maxContentX, x + w + (isRow ? item.marginMainEnd : item.marginCrossEnd) + s.padding.right)
                maxContentY = max(maxContentY, y + h + (isRow ? item.marginCrossEnd : item.marginMainEnd) + s.padding.bottom)

                mainCursor += item.marginMainStart + item.finalMain + item.marginMainEnd + mainGap + extraBetween
            }

            crossCursor += line.crossSize + crossGap
            let _ = finalInnerCross
        }

        // Position out-of-flow `.isAbsolute` children against this element's padding box `[0, 0, finalOuterW, finalOuterH]`
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

            var solved = layoutNode(
                child,
                availableWidth: finalOuterW,
                availableHeight: finalOuterH,
                forcedWidth: pinnedW,
                forcedHeight: pinnedH
            )
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

        return ResultNode(
            layout: ComputedLayout(
                localRect: MotionRect.fromXYWH(0, 0, finalOuterW, finalOuterH),
                contentSize: Vec2(maxContentX, maxContentY)
            ),
            children: childResults
        )
    }
}
