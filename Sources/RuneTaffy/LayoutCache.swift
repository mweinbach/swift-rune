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

private struct CompactMeasureEntry: Sendable {
    var kdAvailableSpace: UInt64 = 0
    var parentSize: UInt64 = 0
    var size = Size<Float>.zero

    @inline(__always)
    func matchesSize(_ key: CacheKey) -> Bool {
        kdAvailableSpace == key.kdAvailableSpace
            && CacheKey.xAxisParentSize(parentSize) == CacheKey.xAxisParentSize(key.parentSize)
            && CacheKey.sizeIsValidFor(entryParentSize: parentSize, queryParentSize: key.parentSize)
    }
}

/// Matches the upstream cache's 32-bit metadata word. The valid bits distinguish empty
/// inline slots from real zero-valued keys; no slot needs a separate Optional tag.
private struct CacheMetadata: Sendable {
    private var bits: UInt32 = 0

    var isEmpty: Bool { bits & 0x3FF == 0 }
    var measureMask: UInt32 { bits & 0x1FF }
    var hasFinal: Bool { bits & (1 << 9) != 0 }
    var mode: UInt8 { UInt8((bits >> 23) & 7) }
    var next: Int { Int((bits >> 19) & 15) }

    mutating func clear(keepingMode mode: UInt8) { bits = UInt32(mode) << 23 }

    func definiteness(at shift: Int) -> UInt8 { UInt8((bits >> shift) & 3) }
    mutating func setDefiniteness(at shift: Int, _ value: UInt8) {
        bits = (bits & ~(3 << shift)) | (UInt32(value) << shift)
    }

    mutating func markFinal(_ definiteness: UInt8) {
        bits |= 1 << 9
        setDefiniteness(at: 30, definiteness)
    }

    mutating func touch(_ slot: Int) { bits |= 1 << (10 + slot) }

    mutating func claimMeasure() -> Int {
        var slot = next
        while bits & (1 << (10 + slot)) != 0 {
            bits &= ~(1 << (10 + slot))
            slot = (slot + 1) % 9
        }
        bits |= 1 << slot
        touch(slot)
        bits = (bits & ~(15 << 19)) | (UInt32((slot + 1) % 9) << 19)
        return slot
    }
}

private struct CompactFinalEntry: Sendable {
    var kdAvailableSpace: UInt64 = 0
    var parentSize: UInt64 = 0
    var size = Size<Float>.zero
    var contentSize = Size<Float>.zero
    var firstBaselineY = Float.nan
    var metadata = CacheMetadata()
}

private struct ColdFinalOutput: Sendable {
    let firstBaselineX: Float?
    let nanBaselineY: Float?
    let topMargin: CollapsibleMarginSet
    let bottomMargin: CollapsibleMarginSet
    let marginsCanCollapseThrough: Bool

    init?(_ output: LayoutOutput) {
        let y = output.firstBaselines.y
        guard output.firstBaselines.x != nil || y?.isNaN == true || output.topMargin != .zero
            || output.bottomMargin != .zero || output.marginsCanCollapseThrough else { return nil }
        firstBaselineX = output.firstBaselines.x
        nanBaselineY = y?.isNaN == true ? y : nil
        topMargin = output.topMargin
        bottomMargin = output.bottomMargin
        marginsCanCollapseThrough = output.marginsCanCollapseThrough
    }
}

private struct CacheOverflow: Sendable {
    var measures: [CompactMeasureEntry] = []
    var definiteness: UInt16 = 0
    var final: ColdFinalOutput?
}

/// Nine second-chance measure slots and one final layout. Two measures and the common final
/// output fit inline in 96 bytes on 64-bit hosts. Additional measures and uncommon final
/// fields allocate on demand; copying a cache preserves independent value semantics.
public struct Cache: Sendable {
    private static let cacheSize = 9
    private static let inlineMeasures = 2

    private var final = CompactFinalEntry()
    private var measure0 = CompactMeasureEntry()
    private var measure1 = CompactMeasureEntry()
    private var overflow: [CacheOverflow] = []

    public init() {}
    public var isEmpty: Bool { final.metadata.isEmpty }

    public func heapBytes() -> Int {
        guard !overflow.isEmpty else { return 0 }
        return MemoryLayout<CacheOverflow>.stride
            + overflow[0].measures.capacity * MemoryLayout<CompactMeasureEntry>.stride
    }

    private mutating func ensureOverflow() {
        if overflow.isEmpty { overflow = [CacheOverflow()] }
    }

    private func measure(_ index: Int) -> CompactMeasureEntry {
        switch index {
        case 0: return measure0
        case 1: return measure1
        default: return overflow[0].measures[index - Self.inlineMeasures]
        }
    }

    private func measureDefiniteness(_ index: Int) -> UInt8 {
        if index < Self.inlineMeasures { return final.metadata.definiteness(at: 26 + index * 2) }
        return UInt8((overflow[0].definiteness >> ((index - Self.inlineMeasures) * 2)) & 3)
    }

    private mutating func setMeasure(_ index: Int, key: CacheKey, size: Size<Float>) {
        let entry = CompactMeasureEntry(kdAvailableSpace: key.kdAvailableSpace, parentSize: key.parentSize, size: size)
        if index < Self.inlineMeasures {
            if index == 0 { measure0 = entry } else { measure1 = entry }
            final.metadata.setDefiniteness(at: 26 + index * 2, key.kdDef)
        } else {
            ensureOverflow()
            if overflow[0].measures.isEmpty {
                overflow[0].measures = Array(repeating: CompactMeasureEntry(), count: Self.cacheSize - Self.inlineMeasures)
            }
            let offset = index - Self.inlineMeasures
            overflow[0].measures[offset] = entry
            let shift = offset * 2
            overflow[0].definiteness = (overflow[0].definiteness & ~(3 << shift)) | (UInt16(key.kdDef) << shift)
        }
    }

    public mutating func get(_ input: LayoutInput) -> LayoutOutput? {
        guard !isEmpty, final.metadata.mode == cacheMode(input) else { return nil }
        let key = CacheKey.fromInput(input)
        switch input.runMode {
        case .performLayout:
            guard final.metadata.hasFinal, final.kdAvailableSpace == key.kdAvailableSpace,
                  final.parentSize == key.parentSize, final.metadata.definiteness(at: 30) == key.kdDef else { return nil }
            if overflow.isEmpty {
                return LayoutOutput(size: final.size, contentSize: final.contentSize,
                                    firstBaselines: Point(x: nil, y: final.firstBaselineY.isNaN ? nil : final.firstBaselineY))
            }
            let cold = overflow[0].final
            let y = final.firstBaselineY.isNaN ? cold?.nanBaselineY : final.firstBaselineY
            return LayoutOutput(size: final.size, contentSize: final.contentSize,
                                firstBaselines: Point(x: cold?.firstBaselineX, y: y),
                                topMargin: cold?.topMargin ?? .zero, bottomMargin: cold?.bottomMargin ?? .zero,
                                marginsCanCollapseThrough: cold?.marginsCanCollapseThrough ?? false)
        case .computeSize:
            let valid = final.metadata.measureMask
            if valid & 1 != 0, measure0.matchesSize(key), final.metadata.definiteness(at: 26) == key.kdDef {
                final.metadata.touch(0)
                return .fromOuterSize(measure0.size)
            }
            if valid & 2 != 0, measure1.matchesSize(key), final.metadata.definiteness(at: 28) == key.kdDef {
                final.metadata.touch(1)
                return .fromOuterSize(measure1.size)
            }
            var mask = valid & ~3
            while mask != 0 {
                let slot = mask.trailingZeroBitCount
                let entry = measure(slot)
                if entry.matchesSize(key), measureDefiniteness(slot) == key.kdDef {
                    final.metadata.touch(slot)
                    return .fromOuterSize(entry.size)
                }
                mask &= mask - 1
            }
            return nil
        case .performHiddenLayout:
            return nil
        }
    }

    public mutating func store(_ input: LayoutInput, output: LayoutOutput) {
        guard input.runMode != .performHiddenLayout else { return }
        let mode = cacheMode(input)
        if final.metadata.mode != mode { clear(mode: mode) }
        let key = CacheKey.fromInput(input)
        switch input.runMode {
        case .performLayout:
            final.metadata.markFinal(key.kdDef)
            final.kdAvailableSpace = key.kdAvailableSpace
            final.parentSize = key.parentSize
            final.size = output.size
            final.contentSize = output.contentSize
            final.firstBaselineY = output.firstBaselines.y ?? .nan
            if let cold = ColdFinalOutput(output) {
                ensureOverflow()
                overflow[0].final = cold
            } else if !overflow.isEmpty {
                overflow[0].final = nil
            }
        case .computeSize:
            guard !output.marginsCanCollapseThrough, output.topMargin == .zero, output.bottomMargin == .zero else { return }
            var mask = final.metadata.measureMask
            while mask != 0 {
                let slot = mask.trailingZeroBitCount
                let entry = measure(slot)
                if entry.kdAvailableSpace == key.kdAvailableSpace, entry.parentSize == key.parentSize,
                   measureDefiniteness(slot) == key.kdDef {
                    setMeasure(slot, key: key, size: output.size)
                    final.metadata.touch(slot)
                    return
                }
                mask &= mask - 1
            }
            let slot = final.metadata.claimMeasure()
            setMeasure(slot, key: key, size: output.size)
        case .performHiddenLayout:
            break
        }
    }

    private mutating func clear(mode: UInt8) {
        final.metadata.clear(keepingMode: mode)
        if !overflow.isEmpty {
            overflow[0].definiteness = 0
            overflow[0].final = nil
        }
    }

    @discardableResult
    public mutating func clear() -> ClearState {
        guard !isEmpty else { return .alreadyEmpty }
        // Retain allocated overflow slots across layout invalidation, matching rune-taffy.
        clear(mode: final.metadata.mode)
        return .cleared
    }
}

public typealias CompactCache = Cache
