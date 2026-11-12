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
    public var parentSize: Size<Float?>
    public var availableSpace: Size<AvailableSpace>
    public var verticalMarginsAreCollapsible: Line<Bool>

    public static let hidden = LayoutInput(
        runMode: .performHiddenLayout,
        sizingMode: .inherentSize,
        axis: .both,
        knownDimensions: .none,
        parentSize: .none,
        availableSpace: .maxContent,
        verticalMarginsAreCollapsible: .false
    )

    public init(
        runMode: RunMode = .performLayout,
        sizingMode: SizingMode = .inherentSize,
        axis: RequestedAxis = .both,
        knownDimensions: Size<Float?> = .none,
        parentSize: Size<Float?> = .none,
        availableSpace: Size<AvailableSpace> = .maxContent,
        verticalMarginsAreCollapsible: Line<Bool> = .false
    ) {
        self.runMode = runMode
        self.sizingMode = sizingMode
        self.axis = axis
        self.knownDimensions = knownDimensions
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

// MARK: - 9-Slot Second-Chance Clock Cache (matching Taffy's Cache)

private struct CacheEntry<T: Sendable>: Sendable {
    var knownDimensions: Size<Float?>
    var availableSpace: Size<AvailableSpace>
    var parentSize: Size<Float?>
    var sizingMode: SizingMode
    var axis: RequestedAxis
    var verticalMarginsAreCollapsible: Line<Bool>
    var content: T
}

/// Per-node layout cache with 1 final-layout slot and 9 measure slots using second-chance clock eviction.
public struct Cache: Sendable {
    private static let cacheSize = 9

    private var finalLayoutEntry: CacheEntry<LayoutOutput>?
    private var measureEntries: [CacheEntry<Size<Float>>?]
    private var recentFlags: [Bool]
    private var nextEntry: Int
    private var isEmptyFlag: Bool

    public init() {
        self.finalLayoutEntry = nil
        self.measureEntries = Array(repeating: nil, count: Self.cacheSize)
        self.recentFlags = Array(repeating: false, count: Self.cacheSize)
        self.nextEntry = 0
        self.isEmptyFlag = true
    }

    @inline(__always)
    private static func entryMatches(
        entryKnownDimensions: Size<Float?>,
        entryAvailableSpace: Size<AvailableSpace>,
        entryParentSize: Size<Float?>,
        entrySizingMode: SizingMode,
        entryAxis: RequestedAxis,
        entryCollapsible: Line<Bool>,
        entrySize: Size<Float>,
        input: LayoutInput
    ) -> Bool {
        if entrySizingMode != input.sizingMode { return false }
        if entryCollapsible != input.verticalMarginsAreCollapsible { return false }
        if entryAxis != .both && entryAxis != input.axis { return false }

        // Width check
        let wMatch: Bool
        if let kdW = input.knownDimensions.width {
            wMatch = entryKnownDimensions.width == kdW || entrySize.width == kdW
        } else {
            wMatch = entryKnownDimensions.width == nil && entryAvailableSpace.width == input.availableSpace.width
        }
        if !wMatch { return false }

        // Height check
        let hMatch: Bool
        if let kdH = input.knownDimensions.height {
            hMatch = entryKnownDimensions.height == kdH || entrySize.height == kdH
        } else {
            hMatch = entryKnownDimensions.height == nil && entryAvailableSpace.height == input.availableSpace.height
        }
        if !hMatch { return false }

        // Parent size check: if entry used parent_size, or for simplicity exact match when either is Some
        if entryParentSize.width != input.parentSize.width && (entryParentSize.width != nil || input.parentSize.width != nil) {
            return false
        }
        if entryParentSize.height != input.parentSize.height && (entryParentSize.height != nil || input.parentSize.height != nil) {
            return false
        }

        return true
    }

    public mutating func get(_ input: LayoutInput) -> LayoutOutput? {
        switch input.runMode {
        case .performLayout:
            guard let entry = finalLayoutEntry else { return nil }
            if Self.entryMatches(
                entryKnownDimensions: entry.knownDimensions,
                entryAvailableSpace: entry.availableSpace,
                entryParentSize: entry.parentSize,
                entrySizingMode: entry.sizingMode,
                entryAxis: entry.axis,
                entryCollapsible: entry.verticalMarginsAreCollapsible,
                entrySize: entry.content.size,
                input: input
            ) {
                return entry.content
            }
            return nil

        case .computeSize:
            for i in 0..<Self.cacheSize {
                guard let entry = measureEntries[i] else { continue }
                if Self.entryMatches(
                    entryKnownDimensions: entry.knownDimensions,
                    entryAvailableSpace: entry.availableSpace,
                    entryParentSize: entry.parentSize,
                    entrySizingMode: entry.sizingMode,
                    entryAxis: entry.axis,
                    entryCollapsible: entry.verticalMarginsAreCollapsible,
                    entrySize: entry.content,
                    input: input
                ) {
                    recentFlags[i] = true
                    return LayoutOutput.fromOuterSize(entry.content)
                }
            }
            return nil

        case .performHiddenLayout:
            return nil
        }
    }

    public mutating func store(_ input: LayoutInput, output: LayoutOutput) {
        switch input.runMode {
        case .performLayout:
            isEmptyFlag = false
            finalLayoutEntry = CacheEntry(
                knownDimensions: input.knownDimensions,
                availableSpace: input.availableSpace,
                parentSize: input.parentSize,
                sizingMode: input.sizingMode,
                axis: input.axis,
                verticalMarginsAreCollapsible: input.verticalMarginsAreCollapsible,
                content: output
            )

        case .computeSize:
            isEmptyFlag = false
            // Second-chance clock eviction
            var idx = nextEntry
            while true {
                if measureEntries[idx] == nil || !recentFlags[idx] {
                    measureEntries[idx] = CacheEntry(
                        knownDimensions: input.knownDimensions,
                        availableSpace: input.availableSpace,
                        parentSize: input.parentSize,
                        sizingMode: input.sizingMode,
                        axis: input.axis,
                        verticalMarginsAreCollapsible: input.verticalMarginsAreCollapsible,
                        content: output.size
                    )
                    recentFlags[idx] = true
                    nextEntry = (idx + 1) % Self.cacheSize
                    return
                }
                recentFlags[idx] = false
                idx = (idx + 1) % Self.cacheSize
            }

        case .performHiddenLayout:
            break
        }
    }

    @discardableResult
    public mutating func clear() -> ClearState {
        if isEmptyFlag {
            return .alreadyEmpty
        }
        isEmptyFlag = true
        finalLayoutEntry = nil
        for i in 0..<Self.cacheSize {
            measureEntries[i] = nil
            recentFlags[i] = false
        }
        nextEntry = 0
        return .cleared
    }
}

public typealias CompactCache = Cache
