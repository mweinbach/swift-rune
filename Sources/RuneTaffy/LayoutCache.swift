// MARK: - Layout Input / Output & Cache

public enum RunMode: Sendable, Equatable, Hashable {
    case performLayout
    case computeSize
    case performHiddenLayout
}

public enum SizingMode: Sendable, Equatable, Hashable {
    case contentSize
    case inherentSize
}

public enum RequestedAxis: Sendable, Equatable, Hashable {
    case horizontal
    case vertical
    case both
}

public enum ClearState: Sendable, Equatable, Hashable {
    case alreadyEmpty
    case cleared
}

/// CSS collapsible margin pair tracking largest positive and most-negative margins separately.
public struct CollapsibleMarginSet: Sendable, Equatable, Hashable {
    public var positive: Float
    public var negative: Float

    public static let zero = CollapsibleMarginSet(positive: 0, negative: 0)

    @inlinable
    public init(positive: Float, negative: Float) {
        self.positive = positive
        self.negative = negative
    }

    @inlinable
    public static func fromMargin(_ margin: Float) -> CollapsibleMarginSet {
        if margin >= 0 {
            return CollapsibleMarginSet(positive: margin, negative: 0)
        } else {
            return CollapsibleMarginSet(positive: 0, negative: margin)
        }
    }

    @inlinable
    public func collapseWithMargin(_ margin: Float) -> CollapsibleMarginSet {
        collapseWithSet(.fromMargin(margin))
    }

    @inlinable
    public func collapseWithSet(_ other: CollapsibleMarginSet) -> CollapsibleMarginSet {
        CollapsibleMarginSet(
            positive: Swift.max(positive, other.positive),
            negative: Swift.min(negative, other.negative)
        )
    }

    @inlinable
    public func resolve() -> Float {
        positive + negative
    }
}

/// Input parameters passed down to a node's layout computation.
public struct LayoutInput: Sendable, Equatable, Hashable {
    public var runMode: RunMode
    public var sizingMode: SizingMode
    public var axis: RequestedAxis
    public var knownDimensions: Size<Float?>
    public var knownDimensionsAreDefinite: Size<Bool>
    public var parentSize: Size<Float?>
    public var availableSpace: Size<AvailableSpace>
    public var verticalMarginsAreCollapsible: Line<Bool>

    public static let hidden = LayoutInput(
        runMode: .performHiddenLayout,
        sizingMode: .inherentSize,
        axis: .both,
        knownDimensions: .none,
        knownDimensionsAreDefinite: .true,
        parentSize: .none,
        availableSpace: .maxContent,
        verticalMarginsAreCollapsible: .false
    )

    public init(
        runMode: RunMode = .performLayout,
        sizingMode: SizingMode = .inherentSize,
        axis: RequestedAxis = .both,
        knownDimensions: Size<Float?> = .none,
        knownDimensionsAreDefinite: Size<Bool> = .true,
        parentSize: Size<Float?> = .none,
        availableSpace: Size<AvailableSpace> = .maxContent,
        verticalMarginsAreCollapsible: Line<Bool> = .false
    ) {
        self.runMode = runMode
        self.sizingMode = sizingMode
        self.axis = axis
        self.knownDimensions = knownDimensions
        self.knownDimensionsAreDefinite = knownDimensionsAreDefinite
        self.parentSize = parentSize
        self.availableSpace = availableSpace
        self.verticalMarginsAreCollapsible = verticalMarginsAreCollapsible
    }
}

/// Output returned from a node's layout computation.
public struct LayoutOutput: Sendable, Equatable {
    public var size: Size<Float>
    public var contentSize: Size<Float>
    public var firstBaselines: Point<Float?>
    public var topMargin: CollapsibleMarginSet
    public var bottomMargin: CollapsibleMarginSet
    public var marginsCanCollapseThrough: Bool

    public static let hidden = LayoutOutput(
        size: .zero,
        contentSize: .zero,
        firstBaselines: Point(x: nil, y: nil),
        topMargin: .zero,
        bottomMargin: .zero,
        marginsCanCollapseThrough: false
    )

    public init(
        size: Size<Float>,
        contentSize: Size<Float> = .zero,
        firstBaselines: Point<Float?> = Point(x: nil, y: nil),
        topMargin: CollapsibleMarginSet = .zero,
        bottomMargin: CollapsibleMarginSet = .zero,
        marginsCanCollapseThrough: Bool = false
    ) {
        self.size = size
        self.contentSize = contentSize
        self.firstBaselines = firstBaselines
        self.topMargin = topMargin
        self.bottomMargin = bottomMargin
        self.marginsCanCollapseThrough = marginsCanCollapseThrough
    }

    @inlinable
    public static func fromOuterSize(_ size: Size<Float>) -> LayoutOutput {
        LayoutOutput(size: size)
    }

    @inlinable
    public static func fromSizesAndBaselines(
        size: Size<Float>,
        contentSize: Size<Float>,
        firstBaselines: Point<Float?>
    ) -> LayoutOutput {
        LayoutOutput(size: size, contentSize: contentSize, firstBaselines: firstBaselines)
    }
}

/// Full computed layout for a node (matching `taffy::Layout`).
public struct Layout: Sendable, Equatable {
    public var order: UInt32
    public var location: Point<Float>
    public var size: Size<Float>
    public var contentSize: Size<Float>
    public var scrollbarSize: Size<Float>
    public var border: Rect<Float>
    public var padding: Rect<Float>
    public var margin: Rect<Float>

    public static let zero = Layout()

    public init(
        order: UInt32 = 0,
        location: Point<Float> = .zero,
        size: Size<Float> = .zero,
        contentSize: Size<Float> = .zero,
        scrollbarSize: Size<Float> = .zero,
        border: Rect<Float> = .zero,
        padding: Rect<Float> = .zero,
        margin: Rect<Float> = .zero
    ) {
        self.order = order
        self.location = location
        self.size = size
        self.contentSize = contentSize
        self.scrollbarSize = scrollbarSize
        self.border = border
        self.padding = padding
        self.margin = margin
    }

    @inlinable
    public func contentBoxSize() -> Size<Float> {
        Size(
            width: Swift.max(0, size.width - padding.horizontalSum - border.horizontalSum),
            height: Swift.max(0, size.height - padding.verticalSum - border.verticalSum)
        )
    }
}

/// Compact unrounded box geometry + combined `padding + border` inset (matching `rune_taffy::BoxLayout`).
public struct BoxLayout: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var w: Float
    public var h: Float
    /// `[left, top, right, bottom]` = `padding + border`.
    public var inset: (Float, Float, Float, Float)

    public static let zero = BoxLayout(x: 0, y: 0, w: 0, h: 0, inset: (0, 0, 0, 0))

    public init(x: Float, y: Float, w: Float, h: Float, inset: (Float, Float, Float, Float) = (0, 0, 0, 0)) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.inset = inset
    }

    @inlinable
    public static func from(_ layout: Layout) -> BoxLayout {
        BoxLayout(
            x: layout.location.x,
            y: layout.location.y,
            w: layout.size.width,
            h: layout.size.height,
            inset: (
                layout.padding.left + layout.border.left,
                layout.padding.top + layout.border.top,
                layout.padding.right + layout.border.right,
                layout.padding.bottom + layout.border.bottom
            )
        )
    }

    @inlinable
    public var size: Size<Float> {
        Size(width: w, height: h)
    }

    public static func == (lhs: BoxLayout, rhs: BoxLayout) -> Bool {
        lhs.x == rhs.x
            && lhs.y == rhs.y
            && lhs.w == rhs.w
            && lhs.h == rhs.h
            && lhs.inset == rhs.inset
    }
}

// MARK: - 9-Slot Second-Chance Clock Cache (matching Taffy 0.15 & rune-taffy CompactCache)

private let taffyInfinityBits: UInt32 = Float.infinity.bitPattern
private let taffyNegInfinityBits: UInt32 = (-Float.infinity).bitPattern
private let taffySignBit1: UInt64 = UInt64(1) << 63
private let taffySignBit2: UInt64 = UInt64(1) << 31
private let taffyBothSignBitsMask: UInt64 = taffySignBit1 | taffySignBit2
private let taffyNonSignBitsMask: UInt64 = ~taffyBothSignBitsMask
private let taffyXAxisValueMask: UInt64 = UInt64(UInt32.max) << 32

@inline(__always)
private func optionCacheKey(_ input: Float?) -> UInt32 {
    input?.bitPattern ?? taffyInfinityBits
}

@inline(__always)
private func sizeOptionCacheKey(_ input: Size<Float?>) -> UInt64 {
    (UInt64(optionCacheKey(input.width)) << 32) | UInt64(optionCacheKey(input.height))
}

@inline(__always)
private func availableSpaceCacheKey(_ input: AvailableSpace) -> UInt32 {
    switch input {
    case .definite(let value): return (-value).bitPattern
    case .minContent: return taffyNegInfinityBits
    case .maxContent: return taffyInfinityBits
    }
}

@inline(__always)
private func mixedCacheKey(_ kd: Float?, _ avs: AvailableSpace) -> UInt32 {
    kd?.bitPattern ?? availableSpaceCacheKey(avs)
}

@inline(__always)
private func sizeMixedCacheKey(_ kd: Size<Float?>, _ avs: Size<AvailableSpace>) -> UInt64 {
    (UInt64(mixedCacheKey(kd.width, avs.width)) << 32) | UInt64(mixedCacheKey(kd.height, avs.height))
}

private struct CacheKey: Sendable, Equatable {
    let kdAvailableSpace: UInt64
    let parentSize: UInt64
    let kdDef: UInt8

    @inline(__always)
    static func fromInput(_ input: LayoutInput) -> CacheKey {
        let extraBits: UInt64
        switch input.axis {
        case .horizontal: extraBits = taffySignBit1
        case .vertical: extraBits = taffySignBit2
        case .both: extraBits = taffySignBit1 | taffySignBit2
        }
        let defW = input.knownDimensionsAreDefinite.width || input.knownDimensions.width == nil
        let defH = input.knownDimensionsAreDefinite.height || input.knownDimensions.height == nil
        return CacheKey(
            kdAvailableSpace: sizeMixedCacheKey(input.knownDimensions, input.availableSpace),
            parentSize: (sizeOptionCacheKey(input.parentSize) & taffyNonSignBitsMask) | extraBits,
            kdDef: (defW ? UInt8(1) : 0) | ((defH ? UInt8(1) : 0) << 1)
        )
    }

    @inline(__always)
    static func xAxisParentSize(_ parentSize: UInt64) -> UInt64 {
        parentSize & (taffyXAxisValueMask & taffyNonSignBitsMask)
    }

    @inline(__always)
    static func requestedAxisBits(_ parentSize: UInt64) -> UInt64 {
        parentSize & taffyBothSignBitsMask
    }

    @inline(__always)
    static func sizeIsValidFor(entryParentSize: UInt64, queryParentSize: UInt64) -> Bool {
        let entryAxis = requestedAxisBits(entryParentSize)
        return entryAxis == taffyBothSignBitsMask || entryAxis == requestedAxisBits(queryParentSize)
    }
}

@inline(__always)
private func cacheMode(_ input: LayoutInput) -> UInt8 {
    let inherent: UInt8 = input.sizingMode == .inherentSize ? 1 : 0
    let c = input.verticalMarginsAreCollapsible
    return inherent | ((c.start ? UInt8(1) : 0) << 1) | ((c.end ? UInt8(1) : 0) << 2)
}

private struct CompactMeasureEntry: Sendable, Equatable {
    var kdAvailableSpace: UInt64
    var parentSize: UInt64
    var kdDef: UInt8
    var size: Size<Float>

    static let zero = CompactMeasureEntry(kdAvailableSpace: 0, parentSize: 0, kdDef: 0, size: .zero)
}

private struct CompactFinalEntry: Sendable {
    var kdAvailableSpace: UInt64
    var parentSize: UInt64
    var kdDef: UInt8
    var output: LayoutOutput
}

/// Per-node layout cache with 1 final-layout slot and 9 measure slots using second-chance clock eviction
/// (matching `taffy::Cache` / `rune_taffy::CompactCache` 0.15 keying semantics).
public struct Cache: Sendable {
    private static let cacheSize = 9
    private static let inlineMeasures = 2
    private static let overflowMeasures = cacheSize - inlineMeasures

    private var finalLayoutEntry: CompactFinalEntry?
    private var inlineMeasure0: CompactMeasureEntry?
    private var inlineMeasure1: CompactMeasureEntry?
    private var overflowMeasures: [CompactMeasureEntry?]?
    private var recentMask: UInt16 = 0
    private var nextEntry: Int = 0
    private var modeBits: UInt8 = 0
    private var validFinal: Bool = false
    private var validMeasureMask: UInt16 = 0

    public init() {}

    public var isEmpty: Bool {
        !validFinal && validMeasureMask == 0
    }

    public func heapBytes() -> Int {
        overflowMeasures == nil ? 0 : MemoryLayout<CompactMeasureEntry?>.stride * Self.overflowMeasures
    }

    @inline(__always)
    private func measureSlot(_ index: Int) -> CompactMeasureEntry? {
        switch index {
        case 0: return inlineMeasure0
        case 1: return inlineMeasure1
        default: return overflowMeasures?[index - Self.inlineMeasures]
        }
    }

    @inline(__always)
    private mutating func setMeasureSlot(_ index: Int, _ entry: CompactMeasureEntry) {
        switch index {
        case 0: inlineMeasure0 = entry
        case 1: inlineMeasure1 = entry
        default:
            if overflowMeasures == nil {
                overflowMeasures = Array(repeating: nil, count: Self.overflowMeasures)
            }
            overflowMeasures?[index - Self.inlineMeasures] = entry
        }
    }

    public mutating func get(_ input: LayoutInput) -> LayoutOutput? {
        if isEmpty || modeBits != cacheMode(input) {
            return nil
        }
        let key = CacheKey.fromInput(input)
        switch input.runMode {
        case .performLayout:
            guard validFinal, let entry = finalLayoutEntry else { return nil }
            if entry.kdAvailableSpace == key.kdAvailableSpace
                && entry.parentSize == key.parentSize
                && entry.kdDef == key.kdDef
            {
                return entry.output
            }
            return nil

        case .computeSize:
            if validMeasureMask == 0 { return nil }
            let limit = overflowMeasures == nil ? Self.inlineMeasures : Self.cacheSize
            for index in 0..<limit {
                let bit = UInt16(1) << index
                if (validMeasureMask & bit) == 0 { continue }
                guard let entry = measureSlot(index) else { continue }
                if entry.kdAvailableSpace == key.kdAvailableSpace
                    && entry.kdDef == key.kdDef
                    && CacheKey.xAxisParentSize(entry.parentSize) == CacheKey.xAxisParentSize(key.parentSize)
                    && CacheKey.sizeIsValidFor(entryParentSize: entry.parentSize, queryParentSize: key.parentSize)
                {
                    recentMask |= bit
                    return LayoutOutput.fromOuterSize(entry.size)
                }
            }
            return nil

        case .performHiddenLayout:
            return nil
        }
    }

    public mutating func store(_ input: LayoutInput, output: LayoutOutput) {
        if input.runMode == .performHiddenLayout {
            return
        }
        let mode = cacheMode(input)
        if modeBits != mode {
            _ = clear()
            modeBits = mode
        }
        let key = CacheKey.fromInput(input)
        switch input.runMode {
        case .performLayout:
            validFinal = true
            finalLayoutEntry = CompactFinalEntry(
                kdAvailableSpace: key.kdAvailableSpace,
                parentSize: key.parentSize,
                kdDef: key.kdDef,
                output: output
            )

        case .computeSize:
            if output.marginsCanCollapseThrough
                || output.topMargin != .zero
                || output.bottomMargin != .zero
            {
                return
            }
            if validMeasureMask != 0 {
                let limit = overflowMeasures == nil ? Self.inlineMeasures : Self.cacheSize
                for index in 0..<limit {
                    let bit = UInt16(1) << index
                    if (validMeasureMask & bit) == 0 { continue }
                    guard var entry = measureSlot(index) else { continue }
                    if entry.kdAvailableSpace == key.kdAvailableSpace
                        && entry.parentSize == key.parentSize
                        && entry.kdDef == key.kdDef
                    {
                        entry.size = output.size
                        setMeasureSlot(index, entry)
                        recentMask |= bit
                        return
                    }
                }
            }

            // Second-chance clock eviction
            var next = nextEntry
            while (recentMask & (UInt16(1) << next)) != 0 {
                recentMask &= ~(UInt16(1) << next)
                next = (next + 1) % Self.cacheSize
            }
            let entryBit = UInt16(1) << next
            validMeasureMask |= entryBit
            recentMask |= entryBit
            setMeasureSlot(
                next,
                CompactMeasureEntry(
                    kdAvailableSpace: key.kdAvailableSpace,
                    parentSize: key.parentSize,
                    kdDef: key.kdDef,
                    size: output.size
                )
            )
            nextEntry = (next + 1) % Self.cacheSize

        case .performHiddenLayout:
            break
        }
    }

    @discardableResult
    public mutating func clear() -> ClearState {
        if isEmpty {
            return .alreadyEmpty
        }
        // Keep `modeBits` intact across clears (D-T6), matching upstream `taffy::Cache::clear`.
        validFinal = false
        validMeasureMask = 0
        recentMask = 0
        nextEntry = 0
        finalLayoutEntry = nil
        inlineMeasure0 = nil
        inlineMeasure1 = nil
        overflowMeasures = nil
        return .cleared
    }
}

public typealias CompactCache = Cache
