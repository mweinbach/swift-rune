import Foundation
import RuneMotion

public enum FlexDirection: Sendable, Hashable, Codable {
    case row
    case column
    case rowReverse
    case columnReverse
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
    case minContent
    case maxContent
    case fitContentPx(Float)
    case fitContentPercent(Float)

    @inlinable
    public func resolve(against available: Float?) -> Float? {
        switch self {
        case .auto, .minContent, .maxContent, .fitContentPx, .fitContentPercent:
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
    case left(Float)
}

private final class GridStyleBox<Value: Hashable & Sendable>: Hashable, Sendable {
    let value: Value

    init(_ value: Value) { self.value = value }

    static func == (lhs: GridStyleBox, rhs: GridStyleBox) -> Bool {
        lhs === rhs || lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) { hasher.combine(value) }
}

/// Complete CSS Flexbox + Grid + Block + Absolute + Scroll layout style for a single `El`.
public struct LayoutStyle: Sendable, Hashable {
    public var displayMode: LayoutMode = .flex
    public var displayNone: Bool = false
    public var direction: FlexDirection = .row
    public var wrap: Bool = false
    public var wrapReverse: Bool = false
    public var alignItems: AlignItems = .stretch
    public var alignSelf: AlignItems? = nil
    public var alignContent: JustifyContent? = nil
    public var justifyContent: JustifyContent = .start
    public var boxSizingBorderBox: Bool = true

    // Flex and block nodes only carry two references for the optional grid configuration.
    private var gridStorage: GridStyleBox<GridContainerStyle>?
    private var gridItemStorage: GridStyleBox<GridItemStyle>?
    public var grid: GridContainerStyle? {
        get { gridStorage?.value }
        set { gridStorage = newValue.map(GridStyleBox.init) }
    }
    public var gridItem: GridItemStyle? {
        get { gridItemStorage?.value }
        set { gridItemStorage = newValue.map(GridStyleBox.init) }
    }

    public var width: Dimension = .auto
    public var height: Dimension = .auto
    public var minWidth: Dimension = .auto
    public var minHeight: Dimension = .auto
    public var maxWidth: Dimension = .auto
    public var maxHeight: Dimension = .auto

    public var flexGrow: Float = 0
    public var flexShrink: Float = 0
    public var flexBasis: Dimension = .auto

    public var aspectRatio: Float? = nil
    public var aspectFit: Float? = nil

    public var padding: Sides = .all(0)
    public var border: Sides = .all(0)
    public var borderLayout: Bool = false
    public var margin: Sides = .all(0)
    public var rowGap: Float = 0
    public var columnGap: Float = 0

    public var isAbsolute: Bool = false
    public var pinLeft: Float? = nil
    public var pinTop: Float? = nil
    public var pinRight: Float? = nil
    public var pinBottom: Float? = nil

    public var scrollAxes: ScrollAxes = []
    public var scrollbarWidth: Float = 0
    public var stickBottom: Bool = false
    public var clipOverflow: Bool = false
    internal var usesNaturalGrowthContents = false
    public var sticky: StickyEdge? = nil

    public init(direction: FlexDirection = .row) {
        self.direction = direction
    }
}

/// Computed layout box for a single node (in window logical points prior to scroll translation).
public struct ComputedLayout: Sendable, Equatable {
    /// Local offset `(x, y)` relative to parent's top-left border box, plus `(width, height)`.
    public var localRect: MotionRect
    /// Unrounded local `(width, height)` preserved directly from layout (`(y + h) - y` ULP safe).
    public var localSize: Vec2
    /// Content extent `(width, height)` inside scrollable containers.
    public var contentSize: Vec2

    public init(localRect: MotionRect = .zero, localSize: Vec2? = nil, contentSize: Vec2 = .zero) {
        self.localRect = localRect
        self.localSize = localSize ?? Vec2(localRect.width, localRect.height)
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

/// Pure CSS Flexbox / Grid / Block / Absolute layout solver backed by `RuneTaffy`.
public enum LayoutEngine {
    public struct ResultNode: Sendable {
        public var layout: ComputedLayout
        public var children: [ResultNode]
    }

    public static func compute(root: LayoutInputNode, viewport: Vec2) -> ResultNode {
        TaffyBridge.compute(root: root, viewport: viewport)
    }
}
