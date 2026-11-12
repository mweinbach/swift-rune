/// Full CSS layout style for a node in `TaffyTree` / `LayoutStore`.
///
/// Mirrors `taffy::Style` and `rune_taffy::CompactStyle` with full Flexbox, CSS Grid,
/// Block, and Out-Of-Flow properties.
public struct TaffyStyle: Sendable, Equatable, Hashable {
    // MARK: - Core Layout Properties
    public var display: Display
    public var position: Position
    public var boxSizing: BoxSizing
    public var overflow: Point<Overflow>
    public var scrollbarWidth: Float
    public var direction: Direction
    public var textAlign: TextAlign

    // MARK: - Sizing
    public var size: Size<Dimension>
    public var minSize: Size<Dimension>
    public var maxSize: Size<Dimension>
    public var aspectRatio: Float?

    // MARK: - Spacing & Insets
    public var margin: Rect<LengthPercentageAuto>
    public var padding: Rect<LengthPercentage>
    public var border: Rect<LengthPercentage>
    public var inset: Rect<LengthPercentageAuto>
    public var gap: Size<LengthPercentage>

    // MARK: - Flexbox
    public var flexDirection: FlexDirection
    public var flexWrap: FlexWrap
    public var flexGrow: Float
    public var flexShrink: Float
    public var flexBasis: Dimension

    // MARK: - Alignment
    public var alignItems: AlignItems?
    public var alignSelf: AlignSelf?
    public var justifyItems: JustifyItems?
    public var justifySelf: JustifySelf?
    public var alignContent: AlignContent?
    public var justifyContent: JustifyContent?

    // MARK: - CSS Grid Container
    public var gridTemplateRows: [GridTemplateComponent]
    public var gridTemplateColumns: [GridTemplateComponent]
    public var gridAutoRows: [TrackSizingFunction]
    public var gridAutoColumns: [TrackSizingFunction]
    public var gridAutoFlow: GridAutoFlow
    public var gridTemplateAreas: [GridTemplateArea]
    public var gridTemplateRowNames: [[String]]
    public var gridTemplateColumnNames: [[String]]

    // MARK: - CSS Grid Item
    public var gridRow: Line<GridPlacement>
    public var gridColumn: Line<GridPlacement>

    // MARK: - Item Flags
    public var itemIsTable: Bool
    public var itemIsReplaced: Bool
    public var contain: Contain

    public static let `default` = TaffyStyle()

    /// Base element style used by Rune (`Display.flex`, `Position.relative`, `flexShrink: 0`).
    public static func runeBase(_ direction: FlexDirection = .row) -> TaffyStyle {
        TaffyStyle(
            display: .flex,
            position: .relative,
            flexDirection: direction,
            flexShrink: 0
        )
    }

    public init(
        display: Display = .flex,
        position: Position = .relative,
        boxSizing: BoxSizing = .borderBox,
        overflow: Point<Overflow> = Point(x: .visible, y: .visible),
        scrollbarWidth: Float = 0,
        direction: Direction = .ltr,
        textAlign: TextAlign = .auto,
        size: Size<Dimension> = Size(width: .auto, height: .auto),
        minSize: Size<Dimension> = Size(width: .auto, height: .auto),
        maxSize: Size<Dimension> = Size(width: .auto, height: .auto),
        aspectRatio: Float? = nil,
        margin: Rect<LengthPercentageAuto> = Rect(all: .zero),
        padding: Rect<LengthPercentage> = Rect(all: .zero),
        border: Rect<LengthPercentage> = Rect(all: .zero),
        inset: Rect<LengthPercentageAuto> = Rect(all: .auto),
        gap: Size<LengthPercentage> = Size(width: .zero, height: .zero),
        flexDirection: FlexDirection = .row,
        flexWrap: FlexWrap = .noWrap,
        flexGrow: Float = 0,
        flexShrink: Float = 1,
        flexBasis: Dimension = .auto,
        alignItems: AlignItems? = nil,
        alignSelf: AlignSelf? = nil,
        justifyItems: JustifyItems? = nil,
        justifySelf: JustifySelf? = nil,
        alignContent: AlignContent? = nil,
        justifyContent: JustifyContent? = nil,
        gridTemplateRows: [GridTemplateComponent] = [],
        gridTemplateColumns: [GridTemplateComponent] = [],
        gridAutoRows: [TrackSizingFunction] = [],
        gridAutoColumns: [TrackSizingFunction] = [],
        gridAutoFlow: GridAutoFlow = .row,
        gridTemplateAreas: [GridTemplateArea] = [],
        gridTemplateRowNames: [[String]] = [],
        gridTemplateColumnNames: [[String]] = [],
        gridRow: Line<GridPlacement> = Line(start: .auto, end: .auto),
        gridColumn: Line<GridPlacement> = Line(start: .auto, end: .auto),
        itemIsTable: Bool = false,
        itemIsReplaced: Bool = false,
        contain: Contain = .none
    ) {
        self.display = display
        self.position = position
        self.boxSizing = boxSizing
        self.overflow = overflow
        self.scrollbarWidth = scrollbarWidth
        self.direction = direction
        self.textAlign = textAlign
        self.size = size
        self.minSize = minSize
        self.maxSize = maxSize
        self.aspectRatio = aspectRatio
        self.margin = margin
        self.padding = padding
        self.border = border
        self.inset = inset
        self.gap = gap
        self.flexDirection = flexDirection
        self.flexWrap = flexWrap
        self.flexGrow = flexGrow
        self.flexShrink = flexShrink
        self.flexBasis = flexBasis
        self.alignItems = alignItems
        self.alignSelf = alignSelf
        self.justifyItems = justifyItems
        self.justifySelf = justifySelf
        self.alignContent = alignContent
        self.justifyContent = justifyContent
        self.gridTemplateRows = gridTemplateRows
        self.gridTemplateColumns = gridTemplateColumns
        self.gridAutoRows = gridAutoRows
        self.gridAutoColumns = gridAutoColumns
        self.gridAutoFlow = gridAutoFlow
        self.gridTemplateAreas = gridTemplateAreas
        self.gridTemplateRowNames = gridTemplateRowNames
        self.gridTemplateColumnNames = gridTemplateColumnNames
        self.gridRow = gridRow
        self.gridColumn = gridColumn
        self.itemIsTable = itemIsTable
        self.itemIsReplaced = itemIsReplaced
        self.contain = contain
    }

    public func heapBytes() -> Int {
        gridTemplateRows.capacity * MemoryLayout<GridTemplateComponent>.stride
            + gridTemplateColumns.capacity * MemoryLayout<GridTemplateComponent>.stride
            + gridAutoRows.capacity * MemoryLayout<TrackSizingFunction>.stride
            + gridAutoColumns.capacity * MemoryLayout<TrackSizingFunction>.stride
            + gridTemplateAreas.capacity * MemoryLayout<GridTemplateArea>.stride
            + gridTemplateRowNames.capacity * MemoryLayout<[String]>.stride
            + gridTemplateColumnNames.capacity * MemoryLayout<[String]>.stride
    }

    // MARK: - Mutating Setters (matching rune_taffy::style::setters)

    @inlinable
    public mutating func setWidth(_ d: Dimension) {
        size.width = d
    }

    @inlinable
    public mutating func setHeight(_ d: Dimension) {
        size.height = d
    }

    @inlinable
    public mutating func setSize(_ s: Size<Dimension>) {
        size = s
    }

    @inlinable
    public mutating func setMinWidth(_ d: Dimension) {
        minSize.width = d
    }

    @inlinable
    public mutating func setMinHeight(_ d: Dimension) {
        minSize.height = d
    }

    @inlinable
    public mutating func setMaxWidth(_ d: Dimension) {
        maxSize.width = d
    }

    @inlinable
    public mutating func setMaxHeight(_ d: Dimension) {
        maxSize.height = d
    }

    @inlinable
    public mutating func setPadLeft(_ p: Float) {
        padding.left = .length(p)
    }

    @inlinable
    public mutating func setPadRight(_ p: Float) {
        padding.right = .length(p)
    }

    @inlinable
    public mutating func setPadTop(_ p: Float) {
        padding.top = .length(p)
    }

    @inlinable
    public mutating func setPadBottom(_ p: Float) {
        padding.bottom = .length(p)
    }

    @inlinable
    public mutating func setPaddingAll(_ p: Float) {
        let lp = LengthPercentage.length(p)
        padding = Rect(left: lp, right: lp, top: lp, bottom: lp)
    }

    @inlinable
    public mutating func setGap(_ column: Float, _ row: Float) {
        gap = Size(width: .length(column), height: .length(row))
    }

    @inlinable
    public mutating func setGrow(_ g: Float) {
        flexGrow = g
        flexShrink = 1.0
        flexBasis = .zero
    }

    @inlinable
    public mutating func setFlexGrow(_ g: Float) {
        flexGrow = g
    }

    @inlinable
    public mutating func setFlexShrink(_ sh: Float) {
        flexShrink = sh
    }

    @inlinable
    public mutating func setFlexBasis(_ basis: Dimension) {
        flexBasis = basis
    }

    @inlinable
    public mutating func setFlexDirection(_ dir: FlexDirection) {
        flexDirection = dir
    }

    @inlinable
    public mutating func setFlexWrap(_ wrap: FlexWrap) {
        flexWrap = wrap
    }

    @inlinable
    public mutating func setOverflow(_ x: Overflow, _ y: Overflow) {
        overflow = Point(x: x, y: y)
    }

    @inlinable
    public mutating func setAlignItems(_ a: AlignItems) {
        alignItems = a
    }

    @inlinable
    public mutating func setAlignSelf(_ a: AlignSelf?) {
        alignSelf = a
    }

    @inlinable
    public mutating func setJustifyContent(_ j: JustifyContent) {
        justifyContent = j
    }

    @inlinable
    public mutating func setAspectRatio(_ ratio: Float?) {
        aspectRatio = ratio
    }

    @inlinable
    public mutating func setEqualColumns(_ n: Int) {
        display = .grid
        gridTemplateColumns = Array(repeating: .fr(1.0), count: Swift.max(1, n))
    }

    @inlinable
    public mutating func setGridCell(_ column: Int) {
        gridColumn = Line(start: .line(Int16(column) + 1), end: .span(1))
        gridRow = Line(start: .line(1), end: .span(1))
    }

    @inlinable
    public mutating func setPositionAbsolute() {
        position = .absolute
    }

    @inlinable
    public mutating func setAbsoluteInset(_ inset: Rect<LengthPercentageAuto>) {
        position = .absolute
        self.inset = inset
    }

    /// Border widths in points, `[top, right, bottom, left]`, which the box's padding and
    /// content lay out inside.
    @inlinable
    public mutating func setBorder(_ widths: (Float, Float, Float, Float)) {
        let (top, right, bottom, left) = widths
        border = Rect(
            left: .length(left),
            right: .length(right),
            top: .length(top),
            bottom: .length(bottom)
        )
    }

    /// Border widths in points, `[top, right, bottom, left]`.
    @inlinable
    public mutating func setBorder(_ widths: [Float]) {
        guard widths.count >= 4 else { return }
        setBorder((widths[0], widths[1], widths[2], widths[3]))
    }

    @inlinable
    public mutating func setMarginLeft(_ m: Float) {
        margin.left = .length(m)
    }

    @inlinable
    public mutating func setMarginRight(_ m: Float) {
        margin.right = .length(m)
    }

    @inlinable
    public mutating func setMarginTop(_ m: Float) {
        margin.top = .length(m)
    }

    @inlinable
    public mutating func setMarginBottom(_ m: Float) {
        margin.bottom = .length(m)
    }

    @inlinable
    public mutating func setMarginX(_ m: Float) {
        let v = LengthPercentageAuto.length(m)
        margin.left = v
        margin.right = v
    }

    @inlinable
    public mutating func setMarginY(_ m: Float) {
        let v = LengthPercentageAuto.length(m)
        margin.top = v
        margin.bottom = v
    }

    /// Moves this style's outer box sizing and placement onto a fresh column wrapper style and
    /// resets this style's outer box to fill that column (`flex: 1 1 auto`, `minSize: 0`).
    /// The wrapper keeps `overflow` too, matching upstream `CompactStyle::take_box_placement`.
    public mutating func takeBoxPlacement() -> TaffyStyle {
        var outer = TaffyStyle.default
        outer.display = display == .none ? .none : .flex
        outer.flexDirection = .column
        outer.overflow = overflow
        outer.flexShrink = flexShrink
        outer.flexGrow = flexGrow
        outer.flexBasis = flexBasis
        outer.position = position
        outer.inset = inset
        outer.size = size
        outer.minSize = minSize
        outer.maxSize = maxSize
        outer.margin = margin
        outer.alignSelf = alignSelf
        outer.justifySelf = justifySelf
        outer.aspectRatio = aspectRatio
        outer.gridRow = gridRow
        outer.gridColumn = gridColumn

        if display == .none {
            display = .flex
        }
        position = .relative
        inset = Rect(all: .auto)
        size = Size(width: .auto, height: .auto)
        minSize = Size(width: .zero, height: .zero)
        maxSize = Size(width: .auto, height: .auto)
        margin = Rect(all: .zero)
        flexGrow = 1.0
        flexShrink = 1.0
        flexBasis = .auto
        alignSelf = nil
        justifySelf = nil
        aspectRatio = nil
        gridRow = Line(start: .auto, end: .auto)
        gridColumn = Line(start: .auto, end: .auto)
        return outer
    }

    // MARK: - Box Sizing Helpers

    /// Amount to add to a content-box dimension to convert to border-box (or 0 if already border-box).
    @inlinable
    internal func contentBoxAdjustment(paddingBorderSum: Size<Float>) -> Size<Float> {
        switch boxSizing {
        case .borderBox: return .zero
        case .contentBox: return paddingBorderSum
        }
    }

    /// Resolve `size` to border-box dimensions given `parentSize` and `paddingBorderSum`.
    @inlinable
    internal func resolveSize(parentSize: Size<Float?>, paddingBorderSum: Size<Float>) -> Size<Float?> {
        let adj = contentBoxAdjustment(paddingBorderSum: paddingBorderSum)
        return Size(
            width: size.width.maybeResolve(parentSize.width).map { $0 + adj.width },
            height: size.height.maybeResolve(parentSize.height).map { $0 + adj.height }
        )
    }

    @inlinable
    internal func resolveMinSize(parentSize: Size<Float?>, paddingBorderSum: Size<Float>) -> Size<Float?> {
        let adj = contentBoxAdjustment(paddingBorderSum: paddingBorderSum)
        return Size(
            width: minSize.width.maybeResolve(parentSize.width).map { $0 + adj.width },
            height: minSize.height.maybeResolve(parentSize.height).map { $0 + adj.height }
        )
    }

    @inlinable
    internal func resolveMaxSize(parentSize: Size<Float?>, paddingBorderSum: Size<Float>) -> Size<Float?> {
        let adj = contentBoxAdjustment(paddingBorderSum: paddingBorderSum)
        return Size(
            width: maxSize.width.maybeResolve(parentSize.width).map { $0 + adj.width },
            height: maxSize.height.maybeResolve(parentSize.height).map { $0 + adj.height }
        )
    }

    @inlinable
    internal func resolvedPadding(parentWidth: Float?) -> Rect<Float> {
        Rect(
            left: padding.left.resolveOrZero(parentWidth),
            right: padding.right.resolveOrZero(parentWidth),
            top: padding.top.resolveOrZero(parentWidth),
            bottom: padding.bottom.resolveOrZero(parentWidth)
        )
    }

    @inlinable
    internal func resolvedBorder(parentWidth: Float?) -> Rect<Float> {
        Rect(
            left: border.left.resolveOrZero(parentWidth),
            right: border.right.resolveOrZero(parentWidth),
            top: border.top.resolveOrZero(parentWidth),
            bottom: border.bottom.resolveOrZero(parentWidth)
        )
    }

    @inlinable
    internal func resolvedMargin(parentWidth: Float?) -> Rect<Float?> {
        Rect(
            left: margin.left.maybeResolve(parentWidth),
            right: margin.right.maybeResolve(parentWidth),
            top: margin.top.maybeResolve(parentWidth),
            bottom: margin.bottom.maybeResolve(parentWidth)
        )
    }

    @inlinable
    internal func resolvedMarginOrZero(parentWidth: Float?) -> Rect<Float> {
        Rect(
            left: margin.left.resolveOrZero(parentWidth),
            right: margin.right.resolveOrZero(parentWidth),
            top: margin.top.resolveOrZero(parentWidth),
            bottom: margin.bottom.resolveOrZero(parentWidth)
        )
    }

    @inlinable
    internal var isOutOfFlow: Bool {
        position == .absolute || position == .fixed
    }
}

public typealias CompactStyle = TaffyStyle
public typealias Style = TaffyStyle
