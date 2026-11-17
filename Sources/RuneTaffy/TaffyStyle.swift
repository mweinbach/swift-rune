// MARK: - Compact storage

/// Rune stores the upper half of an IEEE Float when its lower half is exactly zero.
/// The caller keeps the full Float in extended storage for every other bit pattern.
private struct ExactBFloat: Sendable, Hashable {
    var bits: UInt16 = 0

    init(bits: UInt16 = 0) { self.bits = bits }

    init?(_ value: Float) {
        guard value.bitPattern & 0xFFFF == 0 else { return nil }
        bits = UInt16(value.bitPattern >> 16)
    }

    var value: Float { Float(bitPattern: UInt32(bits) << 16) }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }
    func hash(into hasher: inout Hasher) { hasher.combine(value) }
}

private extension Dimension {
    var packed: (Float, UInt8) {
        switch self {
        case .length(let n): (n, 0)
        case .percent(let n): (n, 1)
        case .auto: (0, 2)
        case .maxContent: (0, 3)
        case .minContent: (0, 4)
        case .fitContentPx(let n): (n, 5)
        case .fitContentPercent(let n): (n, 6)
        }
    }

    init(_ value: Float, tag: UInt8) {
        switch tag {
        case 0: self = .length(value)
        case 1: self = .percent(value)
        case 2: self = .auto
        case 3: self = .maxContent
        case 4: self = .minContent
        case 5: self = .fitContentPx(value)
        default: self = .fitContentPercent(value)
        }
    }
}

private extension LengthPercentage {
    var packed: (Float, UInt8) {
        switch self {
        case .length(let n): (n, 0)
        case .percent(let n): (n, 1)
        }
    }

    init(_ value: Float, tag: UInt8) {
        self = tag == 0 ? .length(value) : .percent(value)
    }
}

/// Bit positions and widths of the fields sharing the eight-byte tag word.
private struct StyleField {
    let shift: Int
    let mask: UInt64

    init(_ shift: Int, _ width: Int) {
        self.shift = shift
        mask = (1 << width) - 1
    }

    // The size, min-size and max-size pairs occupy bits 0–17; padding units use 18–21.
    static let display = Self(22, 3)
    static let position = Self(25, 3)
    static let direction = Self(28, 2)
    static let wrap = Self(30, 2)
    static let overflowX = Self(32, 2)
    static let overflowY = Self(34, 2)
    static let gapWidth = Self(36, 1)
    static let gapHeight = Self(37, 1)
    static let basisZero = Self(38, 1)
    static let basisNegative = Self(39, 1)
    static let alignItems = Self(40, 4)
    static let alignSelf = Self(44, 4)
    static let alignContent = Self(48, 4)
    static let justifyContent = Self(52, 4)
    static let extendedGap = Self(56, 1)
    static let extendedGrow = Self(57, 1)
    static let extendedShrink = Self(58, 1)
    static let extendedBasis = Self(59, 1)
}

private struct StyleTags: Sendable, Hashable {
    // All six dimensions are auto (tag 2); optional alignment fields use 15 for nil.
    private var bits: UInt64 = 0x00FF_FF00_0001_2492

    subscript(_ field: StyleField) -> UInt8 {
        get { UInt8((bits >> field.shift) & field.mask) }
        set {
            bits = (bits & ~(field.mask << field.shift)) | (UInt64(newValue) << field.shift)
        }
    }

    func dimensions(_ values: Size<Float>, at shift: Int) -> Size<Dimension> {
        Size(width: Dimension(values.width, tag: self[StyleField(shift, 3)]),
             height: Dimension(values.height, tag: self[StyleField(shift + 3, 3)]))
    }

    mutating func pack(_ dimensions: Size<Dimension>, at shift: Int) -> Size<Float> {
        let (width, widthTag) = dimensions.width.packed
        let (height, heightTag) = dimensions.height.packed
        self[StyleField(shift, 6)] = widthTag | heightTag << 3
        return Size(width: width, height: height)
    }

    func resolve(_ values: Size<Float>, at shift: Int, parent: Size<Float?>, adjustment: Size<Float>) -> Size<Float?> {
        let units = self[StyleField(shift, 6)]
        if units == 0 {
            return Size(width: values.width + adjustment.width, height: values.height + adjustment.height)
        }
        if units == 0b010_010 { return .none }
        func resolve(_ value: Float, unit: UInt8, parent: Float?, adjustment: Float) -> Float? {
            switch unit {
            case 0: return value + adjustment
            case 1: return parent.map { value * $0 + adjustment }
            default: return nil
            }
        }
        return Size(width: resolve(values.width, unit: units & 7, parent: parent.width, adjustment: adjustment.width),
                    height: resolve(values.height, unit: units >> 3, parent: parent.height, adjustment: adjustment.height))
    }

    // Rust retains the inner display of an expanded style when wrapping it for scrolling.
    // Swift can keep intrinsic/fit-content keywords inline and still follow that rule.
    var hasExtendedDimension: Bool { bits & 0x24924 != 0 }
    var hasPercentPadding: Bool { bits & (0xF << 18) != 0 }

    // Preserve signed zero when reading a flex basis, and Float's equality/hash for the style.
    private var equalityBits: UInt64 { bits & ~(UInt64(1) << StyleField.basisNegative.shift) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.equalityBits == rhs.equalityBits }
    func hash(into hasher: inout Hasher) { hasher.combine(equalityBits) }
}

/// A border or an aspect ratio should not allocate every grid track and placement field.
private struct GridFields: Sendable, Hashable {
    var gridTemplateRows: [GridTemplateComponent] = []
    var gridTemplateColumns: [GridTemplateComponent] = []
    var gridAutoRows: [TrackSizingFunction] = []
    var gridAutoColumns: [TrackSizingFunction] = []
    var gridAutoFlow = GridAutoFlow.row
    var gridTemplateAreas: [GridTemplateArea] = []
    var gridTemplateRowNames: [[String]] = []
    var gridTemplateColumnNames: [[String]] = []
    var gridRow = Line<GridPlacement>(start: .auto, end: .auto)
    var gridColumn = Line<GridPlacement>(start: .auto, end: .auto)
    static let defaults = Self()
}

/// Only allocated when a node uses a value outside the inline layout representation.
private struct ExtendedStyle: Sendable, Hashable {
    var boxSizing = BoxSizing.borderBox
    var scrollbarWidth: Float = 0
    var direction = Direction.ltr
    var textAlign = TextAlign.auto
    var aspectRatio: Float?
    var margin = Rect<LengthPercentageAuto>(all: .zero)
    var border = Rect<LengthPercentage>(all: .zero)
    var inset = Rect<LengthPercentageAuto>(all: .auto)
    var gap: Size<LengthPercentage>?
    var flexGrow: Float?
    var flexShrink: Float?
    var flexBasis: Dimension?
    var justifyItems: JustifyItems?
    var justifySelf: JustifySelf?
    var grid: [GridFields] = []
    var itemIsTable = false
    var itemIsReplaced = false
    var contain = Contain.none

    static let defaults = Self()
}

/// Flexbox, grid, block and out-of-flow layout style. A typical Rune node fits in a single
/// 64-byte cache line on a 64-bit host; uncommon CSS properties have copy-on-write storage.
public struct TaffyStyle: Sendable, Equatable, Hashable {
    private var tags = StyleTags()
    private var sizeValues = Size<Float>.zero
    private var minValues = Size<Float>.zero
    private var maxValues = Size<Float>.zero
    private var paddingValues = Rect<Float>.zero
    private var gapWidth = ExactBFloat()
    private var gapHeight = ExactBFloat()
    private var grow = ExactBFloat()
    private var shrink = ExactBFloat(bits: 0x3F80)
    // The empty array uses Swift's shared singleton. A single value uses native copy-on-write,
    // so copying or sending a style never exposes shared mutable fields.
    private var extra: [ExtendedStyle] = []

    @inline(__always)
    private mutating func setExtended<T: Equatable>(_ key: WritableKeyPath<ExtendedStyle, T>, _ value: T) {
        let normal = ExtendedStyle.defaults[keyPath: key]
        if value == normal {
            guard !extra.isEmpty, extra[0][keyPath: key] != normal else { return }
            extra[0][keyPath: key] = value
            if extra[0] == ExtendedStyle.defaults { extra = [] }
        } else {
            if extra.isEmpty { extra = [.defaults] }
            extra[0][keyPath: key] = value
        }
    }

    private mutating func setGrid<T: Equatable>(_ key: WritableKeyPath<GridFields, T>, _ value: T) {
        let normal = GridFields.defaults[keyPath: key]
        if value == normal {
            guard !extra.isEmpty, !extra[0].grid.isEmpty, extra[0].grid[0][keyPath: key] != normal else { return }
            extra[0].grid[0][keyPath: key] = value
            if extra[0].grid[0] == .defaults { setExtended(\.grid, []) }
        } else {
            if extra.isEmpty { extra = [.defaults] }
            if extra[0].grid.isEmpty { extra[0].grid = [.defaults] }
            extra[0].grid[0][keyPath: key] = value
        }
    }

    // MARK: - Core Layout Properties

    public var display: Display {
        get { Display(rawValue: tags[.display])! }
        set { tags[.display] = newValue.rawValue }
    }
    public var position: Position {
        get { Position(rawValue: tags[.position])! }
        set { tags[.position] = newValue.rawValue }
    }
    public var overflow: Point<Overflow> {
        get { Point(x: Overflow(rawValue: tags[.overflowX])!, y: Overflow(rawValue: tags[.overflowY])!) }
        set {
            tags[.overflowX] = newValue.x.rawValue
            tags[.overflowY] = newValue.y.rawValue
        }
    }

    // MARK: - Sizing and spacing

    public var size: Size<Dimension> {
        get { tags.dimensions(sizeValues, at: 0) }
        set { sizeValues = tags.pack(newValue, at: 0) }
    }
    public var minSize: Size<Dimension> {
        get { tags.dimensions(minValues, at: 6) }
        set { minValues = tags.pack(newValue, at: 6) }
    }
    public var maxSize: Size<Dimension> {
        get { tags.dimensions(maxValues, at: 12) }
        set { maxValues = tags.pack(newValue, at: 12) }
    }
    public var padding: Rect<LengthPercentage> {
        get {
            Rect(left: LengthPercentage(paddingValues.left, tag: tags[StyleField(18, 1)]),
                 right: LengthPercentage(paddingValues.right, tag: tags[StyleField(19, 1)]),
                 top: LengthPercentage(paddingValues.top, tag: tags[StyleField(20, 1)]),
                 bottom: LengthPercentage(paddingValues.bottom, tag: tags[StyleField(21, 1)]))
        }
        set {
            (paddingValues.left, tags[StyleField(18, 1)]) = newValue.left.packed
            (paddingValues.right, tags[StyleField(19, 1)]) = newValue.right.packed
            (paddingValues.top, tags[StyleField(20, 1)]) = newValue.top.packed
            (paddingValues.bottom, tags[StyleField(21, 1)]) = newValue.bottom.packed
        }
    }
    public var gap: Size<LengthPercentage> {
        get {
            if tags[.extendedGap] != 0 { return extra[0].gap! }
            return Size(width: LengthPercentage(gapWidth.value, tag: tags[.gapWidth]),
                        height: LengthPercentage(gapHeight.value, tag: tags[.gapHeight]))
        }
        set {
            let (width, widthTag) = newValue.width.packed
            let (height, heightTag) = newValue.height.packed
            if let w = ExactBFloat(width), let h = ExactBFloat(height) {
                gapWidth = w
                gapHeight = h
                tags[.gapWidth] = widthTag
                tags[.gapHeight] = heightTag
                if tags[.extendedGap] != 0 {
                    setExtended(\.gap, nil)
                    tags[.extendedGap] = 0
                }
            } else {
                gapWidth = ExactBFloat()
                gapHeight = ExactBFloat()
                tags[.gapWidth] = 0
                tags[.gapHeight] = 0
                setExtended(\.gap, newValue)
                tags[.extendedGap] = 1
            }
        }
    }

    // MARK: - Flexbox and alignment

    public var flexDirection: FlexDirection {
        get { FlexDirection(rawValue: tags[.direction])! }
        set { tags[.direction] = newValue.rawValue }
    }
    public var flexWrap: FlexWrap {
        get { FlexWrap(rawValue: tags[.wrap])! }
        set { tags[.wrap] = newValue.rawValue }
    }
    public var flexGrow: Float {
        get { tags[.extendedGrow] == 0 ? grow.value : extra[0].flexGrow! }
        set {
            if let packed = ExactBFloat(newValue) {
                grow = packed
                if tags[.extendedGrow] != 0 {
                    setExtended(\.flexGrow, nil)
                    tags[.extendedGrow] = 0
                }
            } else {
                grow = ExactBFloat()
                setExtended(\.flexGrow, newValue)
                tags[.extendedGrow] = 1
            }
        }
    }
    public var flexShrink: Float {
        get { tags[.extendedShrink] == 0 ? shrink.value : extra[0].flexShrink! }
        set {
            if let packed = ExactBFloat(newValue) {
                shrink = packed
                if tags[.extendedShrink] != 0 {
                    setExtended(\.flexShrink, nil)
                    tags[.extendedShrink] = 0
                }
            } else {
                shrink = ExactBFloat()
                setExtended(\.flexShrink, newValue)
                tags[.extendedShrink] = 1
            }
        }
    }
    public var flexBasis: Dimension {
        get {
            if tags[.extendedBasis] != 0 { return extra[0].flexBasis! }
            if tags[.basisZero] == 0 { return .auto }
            return .length(tags[.basisNegative] == 0 ? 0 : -0.0)
        }
        set {
            switch newValue {
            case .auto:
                tags[.basisZero] = 0
                tags[.basisNegative] = 0
            case .length(let value) where value == 0:
                tags[.basisZero] = 1
                tags[.basisNegative] = value.sign == .minus ? 1 : 0
            default:
                tags[.basisZero] = 0
                tags[.basisNegative] = 0
                setExtended(\.flexBasis, newValue)
                tags[.extendedBasis] = 1
                return
            }
            if tags[.extendedBasis] != 0 {
                setExtended(\.flexBasis, nil)
                tags[.extendedBasis] = 0
            }
        }
    }
    public var alignItems: AlignItems? {
        get { AlignItems(rawValue: tags[.alignItems]) }
        set { tags[.alignItems] = newValue?.rawValue ?? 15 }
    }
    public var alignSelf: AlignSelf? {
        get { AlignSelf(rawValue: tags[.alignSelf]) }
        set { tags[.alignSelf] = newValue?.rawValue ?? 15 }
    }
    public var alignContent: AlignContent? {
        get { AlignContent(rawValue: tags[.alignContent]) }
        set { tags[.alignContent] = newValue?.rawValue ?? 15 }
    }
    public var justifyContent: JustifyContent? {
        get { JustifyContent(rawValue: tags[.justifyContent]) }
        set { tags[.justifyContent] = newValue?.rawValue ?? 15 }
    }

    // MARK: - Extended CSS properties

    public var boxSizing: BoxSizing {
        get { extra.isEmpty ? .borderBox : extra[0].boxSizing }
        set { setExtended(\.boxSizing, newValue) }
    }
    public var scrollbarWidth: Float {
        get { extra.isEmpty ? 0 : extra[0].scrollbarWidth }
        set { setExtended(\.scrollbarWidth, newValue) }
    }
    public var direction: Direction {
        get { extra.isEmpty ? .ltr : extra[0].direction }
        set { setExtended(\.direction, newValue) }
    }
    public var textAlign: TextAlign {
        get { extra.isEmpty ? .auto : extra[0].textAlign }
        set { setExtended(\.textAlign, newValue) }
    }
    public var aspectRatio: Float? {
        get { extra.isEmpty ? nil : extra[0].aspectRatio }
        set { setExtended(\.aspectRatio, newValue) }
    }
    public var margin: Rect<LengthPercentageAuto> {
        get { extra.isEmpty ? Rect(all: .zero) : extra[0].margin }
        set { setExtended(\.margin, newValue) }
    }
    public var border: Rect<LengthPercentage> {
        get { extra.isEmpty ? Rect(all: .zero) : extra[0].border }
        set { setExtended(\.border, newValue) }
    }
    public var inset: Rect<LengthPercentageAuto> {
        get { extra.isEmpty ? Rect(all: .auto) : extra[0].inset }
        set { setExtended(\.inset, newValue) }
    }
    public var justifyItems: JustifyItems? {
        get { extra.isEmpty ? nil : extra[0].justifyItems }
        set { setExtended(\.justifyItems, newValue) }
    }
    public var justifySelf: JustifySelf? {
        get { extra.isEmpty ? nil : extra[0].justifySelf }
        set { setExtended(\.justifySelf, newValue) }
    }
    public var gridTemplateRows: [GridTemplateComponent] {
        get { extra.isEmpty || extra[0].grid.isEmpty ? [] : extra[0].grid[0].gridTemplateRows }
        set { setGrid(\.gridTemplateRows, newValue) }
    }
    public var gridTemplateColumns: [GridTemplateComponent] {
        get { extra.isEmpty || extra[0].grid.isEmpty ? [] : extra[0].grid[0].gridTemplateColumns }
        set { setGrid(\.gridTemplateColumns, newValue) }
    }
    public var gridAutoRows: [TrackSizingFunction] {
        get { extra.isEmpty || extra[0].grid.isEmpty ? [] : extra[0].grid[0].gridAutoRows }
        set { setGrid(\.gridAutoRows, newValue) }
    }
    public var gridAutoColumns: [TrackSizingFunction] {
        get { extra.isEmpty || extra[0].grid.isEmpty ? [] : extra[0].grid[0].gridAutoColumns }
        set { setGrid(\.gridAutoColumns, newValue) }
    }
    public var gridAutoFlow: GridAutoFlow {
        get { extra.isEmpty || extra[0].grid.isEmpty ? .row : extra[0].grid[0].gridAutoFlow }
        set { setGrid(\.gridAutoFlow, newValue) }
    }
    public var gridTemplateAreas: [GridTemplateArea] {
        get { extra.isEmpty || extra[0].grid.isEmpty ? [] : extra[0].grid[0].gridTemplateAreas }
        set { setGrid(\.gridTemplateAreas, newValue) }
    }
    public var gridTemplateRowNames: [[String]] {
        get { extra.isEmpty || extra[0].grid.isEmpty ? [] : extra[0].grid[0].gridTemplateRowNames }
        set { setGrid(\.gridTemplateRowNames, newValue) }
    }
    public var gridTemplateColumnNames: [[String]] {
        get { extra.isEmpty || extra[0].grid.isEmpty ? [] : extra[0].grid[0].gridTemplateColumnNames }
        set { setGrid(\.gridTemplateColumnNames, newValue) }
    }
    public var gridRow: Line<GridPlacement> {
        get { extra.isEmpty || extra[0].grid.isEmpty ? Line(start: .auto, end: .auto) : extra[0].grid[0].gridRow }
        set { setGrid(\.gridRow, newValue) }
    }
    public var gridColumn: Line<GridPlacement> {
        get { extra.isEmpty || extra[0].grid.isEmpty ? Line(start: .auto, end: .auto) : extra[0].grid[0].gridColumn }
        set { setGrid(\.gridColumn, newValue) }
    }
    public var itemIsTable: Bool {
        get { extra.isEmpty ? false : extra[0].itemIsTable }
        set { setExtended(\.itemIsTable, newValue) }
    }
    public var itemIsReplaced: Bool {
        get { extra.isEmpty ? false : extra[0].itemIsReplaced }
        set { setExtended(\.itemIsReplaced, newValue) }
    }
    public var contain: Contain {
        get { extra.isEmpty ? .none : extra[0].contain }
        set { setExtended(\.contain, newValue) }
    }

    public static let `default` = TaffyStyle()

    /// Base element style used by Rune (`Display.flex`, `Position.relative`, `flexShrink: 0`).
    public static func runeBase(_ direction: FlexDirection = .row) -> TaffyStyle {
        var style = Self()
        style.position = .relative
        style.flexDirection = direction
        style.shrink = ExactBFloat()
        return style
    }

    public init() {}

    public init(
        display: Display = .flex,
        position: Position = .static,
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
        guard !extra.isEmpty else { return 0 }
        let bytes = MemoryLayout<ExtendedStyle>.stride
        guard let fields = extra[0].grid.first else { return bytes }
        return bytes + MemoryLayout<GridFields>.stride + fields.gridTemplateRows.capacity * MemoryLayout<GridTemplateComponent>.stride
            + fields.gridTemplateColumns.capacity * MemoryLayout<GridTemplateComponent>.stride
            + fields.gridAutoRows.capacity * MemoryLayout<TrackSizingFunction>.stride
            + fields.gridAutoColumns.capacity * MemoryLayout<TrackSizingFunction>.stride
            + fields.gridTemplateAreas.capacity * MemoryLayout<GridTemplateArea>.stride
            + fields.gridTemplateRowNames.capacity * MemoryLayout<[String]>.stride
            + fields.gridTemplateColumnNames.capacity * MemoryLayout<[String]>.stride
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
        let usesInlinePlacement = extra.isEmpty && !tags.hasExtendedDimension
            && display != .grid && position != .fixed && position != .sticky
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

        if usesInlinePlacement || display == .none {
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

    /// Resolve numeric lengths/percentages from their inline tags, including the border-box adjustment.
    internal func resolveSize(parent: Size<Float?>, adjustment: Size<Float>) -> Size<Float?> {
        tags.resolve(sizeValues, at: 0, parent: parent, adjustment: adjustment)
    }

    internal func resolveMinSize(parent: Size<Float?>, adjustment: Size<Float>) -> Size<Float?> {
        tags.resolve(minValues, at: 6, parent: parent, adjustment: adjustment)
    }

    internal func resolveMaxSize(parent: Size<Float?>, adjustment: Size<Float>) -> Size<Float?> {
        tags.resolve(maxValues, at: 12, parent: parent, adjustment: adjustment)
    }

    internal func resolvedPadding(parentWidth: Float?) -> Rect<Float> {
        if !tags.hasPercentPadding { return paddingValues }
        return padding.map { $0.resolveOrZero(parentWidth) }
    }

    internal func resolvedBorder(parentWidth: Float?) -> Rect<Float> {
        guard !extra.isEmpty else { return .zero }
        return extra[0].border.map { $0.resolveOrZero(parentWidth) }
    }

    internal func resolvedMargin(parentWidth: Float?) -> Rect<Float?> {
        guard !extra.isEmpty else { return Rect(all: 0) }
        return extra[0].margin.map { $0.maybeResolve(parentWidth) }
    }

    internal func resolvedMarginOrZero(parentWidth: Float?) -> Rect<Float> {
        guard !extra.isEmpty else { return .zero }
        return extra[0].margin.map { $0.resolveOrZero(parentWidth) }
    }

    @inlinable
    internal var isOutOfFlow: Bool {
        position == .absolute || position == .fixed
    }
}

public typealias CompactStyle = TaffyStyle
public typealias Style = TaffyStyle
