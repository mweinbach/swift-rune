import Foundation
import Rune
import RuneMotion

// MARK: - TabStrip, TabDragState & TabAutoScroll (`rune_kit::shell::tab_strip`)

public enum TabOrientation: Sendable, Equatable, Hashable {
    case horizontal
    case vertical
}

public enum TabDensity: Sendable, Equatable, Hashable {
    case full
    case compact
    case iconOnly

    public static let comfortable = TabDensity.full
    public static let spacious = TabDensity.full

    public var height: Float {
        switch self {
        case .full: return 34.0
        case .compact: return 28.0
        case .iconOnly: return 28.0
        }
    }

    public static func `default`(for orientation: TabOrientation) -> TabDensity {
        switch orientation {
        case .horizontal: return .full
        case .vertical: return .compact
        }
    }
}

public enum TabOverflow: Sendable, Equatable {
    case scroll(fadeWidth: Float = 16.0)
    case shrink(minWidth: Float = 88.0, maxWidth: Float = 200.0)
    case shrinkThenScroll(
        minWidth: Float = 28.0,
        maxWidth: Float = 224.0,
        pinnedWidth: Float = 36.0,
        fadeWidth: Float = 24.0
    )

    public static let horizontalDefault = TabOverflow.shrinkThenScroll()
    public static let verticalDefault = TabOverflow.scroll()

    public static func densityFor(_ width: Float) -> TabDensity {
        if width <= 44.0 {
            return .iconOnly
        } else if width <= 64.0 {
            return .compact
        }
        return .full
    }

    /// The widest an unpinned horizontal tab grows (`max_width`): what each tab is when the strip
    /// was given no width to share. `nil` for `.scroll`, whose tabs upstream have no bound
    /// (`f32::INFINITY`); a horizontal strip then takes `horizontalDefault`'s 224.
    public var maxTabWidth: Float? {
        switch self {
        case .scroll: return nil
        case .shrink(_, let maxW): return maxW
        case .shrinkThenScroll(_, let maxW, _, _): return maxW
        }
    }

    /// A pinned tab's width across a horizontal strip (`pinned_width`; 36 where the mode has none).
    public var pinnedTabWidth: Float {
        switch self {
        case .shrinkThenScroll(_, _, let pinnedW, _): return pinnedW
        case .scroll, .shrink: return 36.0
        }
    }

    public var fadeWidth: Float {
        switch self {
        case .scroll(let fadeWidth): return fadeWidth
        case .shrink: return 0.0
        case .shrinkThenScroll(_, _, _, let fadeWidth): return fadeWidth
        }
    }

    public func tabWidth(
        available: Float,
        unpinnedCount: Int,
        pinnedCount: Int,
        gap: Float = 2.0
    ) -> Float? {
        guard unpinnedCount > 0 else { return nil }
        switch self {
        case .scroll:
            return nil
        case .shrink(let minW, let maxW):
            let totalGap = Float(max(0, unpinnedCount + pinnedCount - 1)) * gap
            let usable = max(0, available - totalGap - Float(pinnedCount) * 36.0)
            return (usable / Float(unpinnedCount)).clamped(to: minW...max(minW, maxW))
        case .shrinkThenScroll(let minW, let maxW, let pinnedW, _):
            let totalGap = Float(max(0, unpinnedCount + pinnedCount - 1)) * gap
            let usable = max(0, available - totalGap - Float(pinnedCount) * pinnedW)
            let raw = usable / Float(unpinnedCount)
            return raw.clamped(to: minW...max(minW, maxW))
        }
    }
}

public enum TabItemStatus: Sendable, Equatable {
    case none
    case dirty
    case dot(Color)
    case badge(String, tone: BadgeTone = .neutral)
    case spinner
}

/// Assistive technology words for a tab strip's close button and tab status (`rune_kit::shell::TabWords`).
public struct TabWords: Sendable, Equatable {
    public var close: String
    public var busy: String
    public var attention: String
    public var unread: String
    public var failed: String

    public static let `default` = TabWords()

    public init(
        close: String = "Close tab",
        busy: String = "Working",
        attention: String = "Needs attention",
        unread: String = "Unread",
        failed: String = "Failed"
    ) {
        self.close = close
        self.busy = busy
        self.attention = attention
        self.unread = unread
        self.failed = failed
    }
}

public struct TabReorder: Sendable, Equatable {
    public var from: Int
    public var to: Int

    public init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }
}

public struct TabTearOut: Sendable, Equatable {
    public var id: String
    public var index: Int
    public var windowPoint: Vec2

    public init(id: String, index: Int, windowPoint: Vec2) {
        self.id = id
        self.index = index
        self.windowPoint = windowPoint
    }
}

public struct TabTearMove: Sendable, Equatable {
    public var id: String
    public var windowPoint: Vec2
    public var insideStrip: Bool

    public init(id: String, windowPoint: Vec2, insideStrip: Bool) {
        self.id = id
        self.windowPoint = windowPoint
        self.insideStrip = insideStrip
    }
}

public struct TearOutSpec: Sendable, Equatable {
    public var threshold: Float
    public var allowPinned: Bool
    public var lone: Bool
    public var stripBounds: MotionRect?

    public init(threshold: Float = 36.0, allowPinned: Bool = false, lone: Bool = false, stripBounds: MotionRect? = nil) {
        self.threshold = max(4.0, threshold)
        self.allowPinned = allowPinned
        self.lone = lone
        self.stripBounds = stripBounds
    }
}

private func motionRectContains(_ rect: MotionRect, _ pt: Vec2) -> Bool {
    pt.x >= rect.left && pt.x <= rect.right && pt.y >= rect.top && pt.y <= rect.bottom
}

public enum TabDragPhase: Sendable, Equatable {
    case idle
    case pressing(id: String, index: Int, start: Vec2, current: Vec2)
    case dragging(id: String, fromIndex: Int, toIndex: Int, offset: Float)
    case tornOut(id: String, originIndex: Int, windowPoint: Vec2)
}

/// Drag, width-lock, separator suppression, and tear-out state machine for `TabStrip`
/// (`rune_kit::shell::tab_strip::drag::TabDragState`).
public struct TabDragState: Sendable, Equatable {
    public static let slop: Float = 4.0

    public enum DragOutcome: Sendable, Equatable {
        case none
        case moved(TabReorder)
        case tornOut(TabTearOut)
        case tearMoved(TabTearMove)
    }

    public private(set) var phase: TabDragPhase = .idle
    public private(set) var widthLock: Float? = nil

    internal mutating func lockWidthForClose(_ width: Float) {
        widthLock = width > 0 ? width : nil
    }
    public private(set) var hoveredId: String? = nil
    public private(set) var incomingIndex: Int? = nil
    public private(set) var handedOff: Bool = false
    fileprivate var swallowNextClick = false
    private var pressAnchor: Vec2? = nil
    private var pressScrollOffset: Float = 0
    fileprivate var draggedPitch: Float? = nil
    private var tabRects: [String: MotionRect] = [:]

    public init() {}

    public var isDragging: Bool {
        if case .dragging = phase { return true }
        return false
    }

    public var isTornOut: Bool {
        if case .tornOut = phase { return true }
        return false
    }

    public var draggingId: String? {
        switch phase {
        case .dragging(let id, _, _, _), .tornOut(let id, _, _): return id
        case .idle, .pressing: return nil
        }
    }

    /// The index of the tab being dragged, reordered or torn out (`TabDragState::dragging`).
    public var draggingIndex: Int? {
        switch phase {
        case .dragging(_, let from, _, _), .tornOut(_, let from, _): return from
        case .idle, .pressing: return nil
        }
    }

    public var activeId: String? {
        switch phase {
        case .pressing(let id, _, _, _), .dragging(let id, _, _, _), .tornOut(let id, _, _):
            return id
        case .idle:
            return nil
        }
    }

    public mutating func setHovered(_ id: String?) {
        hoveredId = id
    }

    public mutating func leave() {
        hoveredId = nil
        if case .idle = phase {
            widthLock = nil
        }
    }

    public mutating func clearWidthLock() {
        widthLock = nil
    }

    public mutating func setIncoming(index: Int?) {
        incomingIndex = index
    }

    public func incomingSlot(count: Int) -> Int? {
        guard let idx = incomingIndex, count >= 0 else { return nil }
        return idx.clamped(to: 0...count)
    }

    public mutating func reportRect(_ rect: MotionRect, for id: String) {
        tabRects[id] = rect
    }

    public func rect(for id: String) -> MotionRect? {
        tabRects[id]
    }

    public mutating func press(id: String, index: Int, at windowPoint: Vec2, tabWidth: Float? = nil, scrollOffset: Float = 0) {
        swallowNextClick = false
        handedOff = false
        pressAnchor = windowPoint
        pressScrollOffset = scrollOffset
        draggedPitch = nil
        if let tabWidth, tabWidth > 0 {
            widthLock = tabWidth
        }
        phase = .pressing(id: id, index: index, start: windowPoint, current: windowPoint)
    }

    /// Computes landing slot index from a pointer position along an ordered list of centers/extents.
    public static func landingSlot(
        pointerAlong: Float,
        itemExtents: [(start: Float, size: Float)],
        fromIndex: Int
    ) -> Int {
        guard !itemExtents.isEmpty else { return 0 }
        for (i, item) in itemExtents.enumerated() {
            let mid = item.start + item.size * 0.5
            if pointerAlong < mid {
                return i > fromIndex ? max(0, i - 1) : i
            }
        }
        return itemExtents.count - 1
    }

    /// Advances the pointer gesture, transitioning across slop -> `.dragging` -> `.tornOut`
    /// as needed.
    @discardableResult
    public mutating func follow(
        to windowPoint: Vec2,
        orientation: TabOrientation = .horizontal,
        tabCenters: [Float] = [],
        tabSize: Float = 120.0,
        count: Int,
        tearOut: TearOutSpec? = nil,
        isPinned: Bool = false,
        scrollOffset: Float = 0,
        partition: Range<Int>? = nil
    ) -> DragOutcome {
        let alongDelta: (Vec2, Vec2) -> Float = { a, b in
            orientation == .horizontal ? (b.x - a.x) : (b.y - a.y)
        }
        let crossDist: (Vec2, Vec2) -> Float = { a, b in
            orientation == .horizontal ? abs(b.y - a.y) : abs(b.x - a.x)
        }

        let scrolled = scrollOffset - pressScrollOffset
        switch phase {
        case .idle:
            return .none

        case .pressing(let id, let idx, let start, _):
            let primary = alongDelta(start, windowPoint) + scrolled
            let cross = crossDist(start, windowPoint)
            if hypotf(primary, cross) < Self.slop {
                phase = .pressing(id: id, index: idx, start: start, current: windowPoint)
                return .none
            }
            if let tearOut, (count > 1 || tearOut.lone), (!isPinned || tearOut.allowPinned) {
                let outsideStrip: Bool
                if let bounds = tearOut.stripBounds {
                    let expanded = MotionRect(
                        left: bounds.left - tearOut.threshold,
                        top: bounds.top - tearOut.threshold,
                        right: bounds.right + tearOut.threshold,
                        bottom: bounds.bottom + tearOut.threshold
                    )
                    outsideStrip = !motionRectContains(expanded, windowPoint)
                } else {
                    outsideStrip = cross >= tearOut.threshold
                }
                if outsideStrip {
                    phase = .tornOut(id: id, originIndex: idx, windowPoint: windowPoint)
                    return .tornOut(TabTearOut(id: id, index: idx, windowPoint: windowPoint))
                }
            }
            phase = .dragging(id: id, fromIndex: idx, toIndex: idx, offset: primary)
            return followDragging(
                id: id,
                from: idx,
                currentTarget: idx,
                windowPoint: windowPoint,
                orientation: orientation,
                tabCenters: tabCenters,
                tabSize: tabSize,
                count: count,
                offset: primary,
                tearOut: tearOut,
                isPinned: isPinned,
                partition: partition
            )

        case .dragging(let id, let from, let currentTarget, _):
            let anchorCenter = tabCenters.indices.contains(from) ? tabCenters[from] : Float(from) * tabSize + tabSize * 0.5
            let ptrAlong = orientation == .horizontal ? windowPoint.x : windowPoint.y
            let offset = (tabCenters.isEmpty ? alongDelta(pressAnchor ?? .zero, windowPoint) : ptrAlong - anchorCenter) + scrolled
            return followDragging(
                id: id,
                from: from,
                currentTarget: currentTarget,
                windowPoint: windowPoint,
                orientation: orientation,
                tabCenters: tabCenters,
                tabSize: tabSize,
                count: count,
                offset: offset,
                tearOut: tearOut,
                isPinned: isPinned,
                partition: partition
            )

        case .tornOut(let id, let originIndex, _):
            phase = .tornOut(id: id, originIndex: originIndex, windowPoint: windowPoint)
            let inside = tearOut?.stripBounds.map { motionRectContains($0, windowPoint) } ?? false
            return .tearMoved(TabTearMove(id: id, windowPoint: windowPoint, insideStrip: inside))
        }
    }

    private mutating func followDragging(
        id: String,
        from: Int,
        currentTarget: Int,
        windowPoint: Vec2,
        orientation: TabOrientation,
        tabCenters: [Float],
        tabSize: Float,
        count: Int,
        offset: Float,
        tearOut: TearOutSpec?,
        isPinned: Bool,
        partition: Range<Int>?
    ) -> DragOutcome {
        if let tearOut, (count > 1 || tearOut.lone), (!isPinned || tearOut.allowPinned) {
            let outsideStrip: Bool
            if let bounds = tearOut.stripBounds {
                let expanded = MotionRect(
                    left: bounds.left - tearOut.threshold,
                    top: bounds.top - tearOut.threshold,
                    right: bounds.right + tearOut.threshold,
                    bottom: bounds.bottom + tearOut.threshold
                )
                outsideStrip = !motionRectContains(expanded, windowPoint)
            } else if let anchor = pressAnchor {
                let cross = orientation == .horizontal ? abs(windowPoint.y - anchor.y) : abs(windowPoint.x - anchor.x)
                outsideStrip = cross >= tearOut.threshold
            } else {
                outsideStrip = false
            }
            if outsideStrip {
                phase = .tornOut(id: id, originIndex: from, windowPoint: windowPoint)
                return .tornOut(TabTearOut(id: id, index: from, windowPoint: windowPoint))
            }
        }
        guard count > 0 else {
            phase = .dragging(id: id, fromIndex: from, toIndex: from, offset: offset)
            return .none
        }
        let range = partition ?? 0..<count
        guard range.contains(from) else { return .none }
        let step = max(1, tabSize)
        let minOffset = Float(range.lowerBound - from) * step
        let maxOffset = Float(range.upperBound - 1 - from) * step
        let delta = offset.clamped(to: minOffset...maxOffset)
        draggedPitch = step
        let target: Int
        if !tabCenters.isEmpty {
            let extents = tabCenters.map { (start: $0 - tabSize * 0.5, size: tabSize) }
            let ptr = orientation == .horizontal ? windowPoint.x : windowPoint.y
            target = Self.landingSlot(pointerAlong: ptr, itemExtents: extents, fromIndex: currentTarget)
                .clamped(to: range.lowerBound...(range.upperBound - 1))
        } else {
            target = from + Int((delta / step).rounded())
        }
        phase = .dragging(id: id, fromIndex: from, toIndex: target, offset: delta)
        if target != currentTarget {
            return .moved(TabReorder(from: currentTarget, to: target))
        }
        return .none
    }

    /// Shift amount for non-dragged sibling at `index` when an item is dragged from `from` to `to`.
    public func shift(forIndex index: Int, itemExtent: Float) -> Float {
        guard case .dragging(_, let from, let to, _) = phase, from != to else { return 0 }
        if from < to && index > from && index <= to {
            return -itemExtent
        }
        if from > to && index >= to && index < from {
            return itemExtent
        }
        return 0
    }

    public mutating func handOff() {
        handedOff = true
        phase = .idle
        widthLock = nil
        pressAnchor = nil
        pressScrollOffset = 0
        draggedPitch = nil
    }

    @discardableResult
    public mutating func release() -> TabReorder? {
        defer {
            phase = .idle
            pressAnchor = nil
            pressScrollOffset = 0
            draggedPitch = nil
        }
        switch phase {
        case .dragging(_, let from, let to, _) where from != to:
            return TabReorder(from: from, to: to)
        default:
            return nil
        }
    }

    public mutating func cancel() {
        phase = .idle
        incomingIndex = nil
        pressAnchor = nil
        pressScrollOffset = 0
        draggedPitch = nil
    }
}

/// Edge auto-scrolling helper while dragging tabs near strip boundaries
/// (`rune_kit::shell::tab_strip::auto_scroll`).
public enum TabAutoScroll {
    public static let acceleration: Float = 8.0
    public static let threshold: Float = 0.05
    public static let tolerance: Float = 10.0
    public static let kept: Int = 64

    public struct View: Sendable, Equatable {
        public var rect: MotionRect
        public var scrollOffset: Float
        public var maxScroll: Float

        public init(rect: MotionRect, scrollOffset: Float, maxScroll: Float) {
            self.rect = rect
            self.scrollOffset = scrollOffset
            self.maxScroll = max(0, maxScroll)
        }
    }

    /// Eight points per 60 Hz frame at the very edge, scaled by depth in the 5% band.
    public static func step(
        pointerAlong: Float,
        viewportStart: Float,
        viewportEnd: Float,
        scrollOffset: Float,
        maxScroll: Float,
        dt: Float
    ) -> Float {
        let limit = max(0, maxScroll)
        let offset = scrollOffset.clamped(to: 0...limit)
        guard dt > 0 else { return offset }
        let speed = stepSpeed(at: pointerAlong - viewportStart, length: viewportEnd - viewportStart,
                              offset: offset, limit: limit)
        guard speed != 0 else { return offset }
        return (offset + speed * (dt * 60)).clamped(to: 0...limit)
    }

    private static func stepSpeed(at position: Float, length: Float, offset: Float, limit: Float) -> Float {
        let band = length * threshold
        guard band > 0 else { return 0 }
        if position <= band && offset > 0 {
            return -acceleration * ((band - position) / band)
        }
        if position >= length - band && offset < limit {
            return acceleration * ((position - (length - band)) / band)
        }
        return 0
    }

    fileprivate final class Viewport {
        let rect = Live<MotionRect>(.zero)
        var position = ScrollPos()

        func offset(vertical: Bool) -> Float { vertical ? position.offset.y : position.offset.x }

        func step(at point: Vec2, vertical: Bool, key: String, tx: inout Tx) {
            let bounds = rect.get()
            let cross = vertical ? point.x : point.y
            let lower = vertical ? bounds.left : bounds.top
            let upper = vertical ? bounds.right : bounds.bottom
            guard cross >= lower - tolerance, cross <= upper + tolerance else { return }
            let current = offset(vertical: vertical)
            let limit = max(0, vertical ? position.max.y : position.max.x)
            let along = vertical ? point.y - bounds.top : point.x - bounds.left
            let length = vertical ? bounds.bottom - bounds.top : bounds.right - bounds.left
            let speed = TabAutoScroll.stepSpeed(at: along, length: length, offset: current, limit: limit)
            guard speed != 0 else { return }
            let next = (current + speed).clamped(to: 0...limit)
            if vertical { position.offset.y = next } else { position.offset.x = next }
            tx.scrollToInstant(key, x: vertical ? 0 : next, y: vertical ? next : 0)
            tx.dragRepeatAfter(.microseconds(16_667))
        }
    }

    private struct ViewKey: Hashable {
        let runtime: UInt64
        let strip: String
    }

    private final class Viewports { var entries: [ViewKey: Viewport] = [:] }

    fileprivate static func viewport(for strip: String) -> Viewport {
        guard let runtime = currentRuntimeId() else { return Viewport() }
        let cache = runeExecutionLocal(forKey: "rune.kit.tabStripViewports", create: Viewports.init)
        let key = ViewKey(runtime: runtime, strip: strip)
        if let found = cache.entries[key] { return found }
        if cache.entries.count >= kept { cache.entries.removeAll(keepingCapacity: true) }
        let value = Viewport()
        cache.entries[key] = value
        return value
    }
}

/// Descriptor for a single tab in `TabStrip` (`rune_kit::shell::tab_strip::TabItem`).
public struct StripTabItem<State> {
    public static var cornerRadius: Float { 6.0 }
    public static var iconSlot: Float { 20.0 }
    public static var slotEndGap: Float { 4.0 }
    public static var dotSize: Float { 7.0 }
    public static var badgeDotSize: Float { 6.0 }
    public static var titleFade: Float { 16.0 }

    public var id: String
    public var title: String
    public var subtitle: String?
    public var iconSvg: SVGIcon?
    public var isPinned: Bool
    public var isClosable: Bool
    public var isDisabled: Bool
    public var isPulsing: Bool
    /// Highlighted while its context menu is open; keeps it built past `BAND_PAST` (`TabItem::marked`).
    public var isMarked: Bool
    public var status: TabItemStatus
    public var badgeText: String?
    public var avatarEl: El<State>?
    public var editorEl: El<State>?
    public var decorateFn: ((El<State>, TabDensity) -> El<State>)?

    public init(id: String, title: String) {
        self.id = id
        self.title = title
        self.subtitle = nil
        self.iconSvg = nil
        self.isPinned = false
        self.isClosable = true
        self.isDisabled = false
        self.isPulsing = false
        self.isMarked = false
        self.status = .none
        self.badgeText = nil
        self.avatarEl = nil
        self.editorEl = nil
        self.decorateFn = nil
    }

    public func subtitle(_ value: String?) -> Self { var c = self; c.subtitle = value; return c }
    public func icon(_ svg: SVGIcon?) -> Self { var c = self; c.iconSvg = svg; return c }
    public func avatar(_ element: El<State>?) -> Self { var c = self; c.avatarEl = element; return c }
    public func editor(_ element: El<State>?) -> Self { var c = self; c.editorEl = element; return c }
    public func decorate(_ wrap: @escaping (El<State>, TabDensity) -> El<State>) -> Self {
        var c = self
        c.decorateFn = wrap
        return c
    }
    public func pinned(_ on: Bool = true) -> Self { var c = self; c.isPinned = on; return c }
    public func closable(_ on: Bool = true) -> Self { var c = self; c.isClosable = on; return c }
    public func disabled(_ on: Bool = true) -> Self { var c = self; c.isDisabled = on; return c }
    public func pulse(_ on: Bool = true) -> Self { var c = self; c.isPulsing = on; return c }
    /// Highlights the tab while its context menu is open (`TabItem::marked`).
    public func marked(_ on: Bool = true) -> Self { var c = self; c.isMarked = on; return c }
    public func status(_ value: TabItemStatus) -> Self { var c = self; c.status = value; return c }
    public func badge(_ value: String?) -> Self { var c = self; c.badgeText = value; return c }
}

/// Configurable desktop/mobile tab strip supporting pinned partitions, overflow shrink/scroll,
/// separator hover/active suppression, close buttons, middle-click close, pulse rings, and
/// `TabDragState` reordering / tear-out (`rune_kit::shell::TabStrip`).
public struct TabStrip<State> {
    private var keyId: String
    private var items: [StripTabItem<State>]
    private var lazySource: (slots: [TabSlot], build: (Int) -> StripTabItem<State>)? = nil
    private var selectedId: String?
    private var orientation: TabOrientation = .horizontal
    private var density: TabDensity? = nil
    private var overflow: TabOverflow? = nil
    private var dragKeyPath: WritableKeyPath<State, TabDragState>? = nil
    private var dragStateValue: TabDragState = TabDragState()
    private var tearOutSpec: TearOutSpec? = nil
    private var leadingEl: El<State>? = nil
    private var trailingEl: El<State>? = nil
    private var availableWidth: Float? = nil
    private var accessibleLabel: String? = nil
    private var gapOverride: Float? = nil
    private var selectOnDragStartOverride: Bool? = nil
    private var matchedPrefixValue: String? = nil
    private var reorderSpringValue: Spring = MotionTokens.SNAP
    private var trailingWidthValue: Float = 28.0
    private var fillColor: Color? = nil
    private var closeIconSvg: SVGIcon? = nil
    private var closeTabStopValue: Bool = false
    private var wordsValue: TabWords = .default
    private var hoverNoneValue: Bool = false
    private var busyIndicatorFn: ((Kit) -> El<State>)? = nil
    private var onSelectFn: ((inout State, String, inout Tx) -> Void)? = nil
    private var onCloseFn: ((inout State, String, inout Tx) -> Void)? = nil
    private var onDoubleClickFn: ((inout State, String, inout Tx) -> Void)? = nil
    private var onHoverFn: ((inout State, String, Bool, inout Tx) -> Void)? = nil
    private var onReorderFn: ((inout State, TabReorder, inout Tx) -> Void)? = nil
    private var onTearOutFn: ((inout State, TabTearOut, inout Tx) -> Void)? = nil
    private var onTearMoveFn: ((inout State, TabTearMove, inout Tx) -> Void)? = nil

    public init(key: String = "tab-strip", tabs: [StripTabItem<State>], selected: String? = nil) {
        self.keyId = key
        self.items = tabs
        self.selectedId = selected
    }

    public init(key: String = "tab-strip", orientation: TabOrientation = .horizontal) {
        self.keyId = key
        self.items = []
        self.orientation = orientation
    }

    public func tabs(_ tabs: [StripTabItem<State>]) -> Self {
        var c = self
        c.items.append(contentsOf: tabs)
        return c
    }

    /// The tabs, of which the strip builds only those it shows (`build(index)`), when there are
    /// more than `BAND_PAST`: the rest stand as empty space their length, so a strip of hundreds
    /// of tabs costs a frame what a screenful does. In place of `tabs(_:)`
    /// (`TabStrip::lazy_tabs`, #1020).
    public func lazyTabs(_ slots: [TabSlot], build: @escaping (Int) -> StripTabItem<State>) -> Self {
        var c = self
        c.lazySource = (slots, build)
        return c
    }

    public func active(_ id: String?) -> Self { var c = self; c.selectedId = id; return c }
    public func label(_ value: String) -> Self { var c = self; c.accessibleLabel = value; return c }

    public func orientation(_ value: TabOrientation) -> Self { var c = self; c.orientation = value; return c }
    public func density(_ value: TabDensity) -> Self { var c = self; c.density = value; return c }
    public func overflow(_ value: TabOverflow) -> Self { var c = self; c.overflow = value; return c }
    public func gap(_ points: Float) -> Self { var c = self; c.gapOverride = max(0, points); return c }
    public func selectOnDragStart(_ on: Bool) -> Self { var c = self; c.selectOnDragStartOverride = on; return c }
    public func matchedPrefix(_ prefix: String?) -> Self { var c = self; c.matchedPrefixValue = prefix; return c }
    public func reorderSpring(_ spring: Spring) -> Self { var c = self; c.reorderSpringValue = spring; return c }
    public func trailingWidth(_ points: Float) -> Self { var c = self; c.trailingWidthValue = max(0, points); return c }
    public func fill(_ color: Color) -> Self { var c = self; c.fillColor = color; return c }
    public func closeIcon(_ svg: SVGIcon?) -> Self { var c = self; c.closeIconSvg = svg; return c }
    public func closeTabStop(_ on: Bool = true) -> Self { var c = self; c.closeTabStopValue = on; return c }
    /// Assistive-technology words for close buttons and tab status marks (`TabStrip::words`).
    public func words(_ words: TabWords) -> Self { var c = self; c.wordsValue = words; return c }
    /// Shows every closable non-icon-only tab's close button at rest for touch / hoverless screens (`TabStrip::hover_none`).
    public func hoverNone(_ on: Bool = true) -> Self { var c = self; c.hoverNoneValue = on; return c }
    public func busyIndicator(_ f: @escaping (Kit) -> El<State>) -> Self { var c = self; c.busyIndicatorFn = f; return c }
    public func dragState(_ keyPath: WritableKeyPath<State, TabDragState>, current: TabDragState) -> Self {
        var c = self
        c.dragKeyPath = keyPath
        c.dragStateValue = current
        return c
    }
    public func tearOut(_ spec: TearOutSpec) -> Self { var c = self; c.tearOutSpec = spec; return c }
    public func leading(_ element: El<State>?) -> Self { var c = self; c.leadingEl = element; return c }
    public func trailing(_ element: El<State>?) -> Self { var c = self; c.trailingEl = element; return c }
    public func availableWidth(_ w: Float) -> Self { var c = self; c.availableWidth = w; return c }
    public func onSelect(_ f: @escaping (inout State, String, inout Tx) -> Void) -> Self { var c = self; c.onSelectFn = f; return c }
    public func onClose(_ f: @escaping (inout State, String, inout Tx) -> Void) -> Self { var c = self; c.onCloseFn = f; return c }
    public func onDoubleClick(_ f: @escaping (inout State, String, inout Tx) -> Void) -> Self { var c = self; c.onDoubleClickFn = f; return c }
    public func onHover(_ f: @escaping (inout State, String, Bool, inout Tx) -> Void) -> Self { var c = self; c.onHoverFn = f; return c }
    public func onReorder(_ f: @escaping (inout State, TabReorder, inout Tx) -> Void) -> Self { var c = self; c.onReorderFn = f; return c }
    public func onTearOut(_ f: @escaping (inout State, TabTearOut, inout Tx) -> Void) -> Self { var c = self; c.onTearOutFn = f; return c }
    public func onTearMove(_ f: @escaping (inout State, TabTearMove, inout Tx) -> Void) -> Self { var c = self; c.onTearMoveFn = f; return c }

    public var effectiveDensity: TabDensity {
        density ?? TabDensity.default(for: orientation)
    }

    public var effectiveOverflow: TabOverflow {
        overflow ?? (orientation == .horizontal ? .horizontalDefault : .verticalDefault)
    }

    /// Reorders an ordered list respecting the pinned-before-unpinned boundary unless moving
    /// within the same partition.
    public static func applyReorder<T>(_ array: inout [T], from: Int, to: Int, isPinned: (T) -> Bool) -> Bool {
        guard array.indices.contains(from), array.indices.contains(to), from != to else { return false }
        let pinnedCount = array.prefix(while: isPinned).count
        let itemPinned = isPinned(array[from])
        let validRange = itemPinned ? (0..<max(1, pinnedCount)) : (pinnedCount..<array.count)
        guard validRange.contains(to) else { return false }
        let moved = array.remove(at: from)
        array.insert(moved, at: to)
        return true
    }

    public func build(_ state: State, kit k: Kit) -> El<State> {
        buildLayered(state, kit: k, elevateDragged: false)
    }

    /// An unpinned horizontal tab's width when the strip was given no `availableWidth`: the
    /// overflow's `max_width` (`self.viewport.map_or(max_width, ..)`), `horizontalDefault`'s for
    /// `.scroll`.
    static func defaultTabWidth(_ overflow: TabOverflow) -> Float {
        overflow.maxTabWidth ?? TabOverflow.horizontalDefault.maxTabWidth ?? 224.0
    }
    /// The width of the line between two horizontal tabs.
    static var separatorWidth: Float { 1.0 }

    /// The slots in strip order (pinned first) and how to build the tab at each; tabs given
    /// whole become slots built from the items themselves.
    private func resolvedSlots() -> (slots: [TabSlot], build: (Int) -> StripTabItem<State>) {
        if let lazy = lazySource {
            let given = lazy.slots
            let order = given.indices.filter { given[$0].pinned } + given.indices.filter { !given[$0].pinned }
            let build = lazy.build
            return (order.map { given[$0] }, { build(order[$0]) })
        }
        let ordered = items.filter(\.isPinned) + items.filter { !$0.isPinned }
        let slots = ordered.map {
            TabSlot(id: $0.id, pinned: $0.isPinned, twoLine: $0.subtitle != nil, keep: $0.isMarked || $0.editorEl != nil)
        }
        return (slots, { ordered[$0] })
    }

    public func buildLayered(_ state: State, kit k: Kit, elevateDragged: Bool = true) -> El<State> {
        let dens = effectiveDensity
        let tabH = dens.height
        let overflowMode = effectiveOverflow
        let vertical = orientation == .vertical
        // Tabs given whole take the lazy path too: each is built once, in order (pinned first).
        let (slots, buildTab) = resolvedSlots()
        let count = slots.count
        let pinnedCount = slots.filter(\.pinned).count

        let effectiveGap = gapOverride ?? 2.0
        let computedUnpinnedWidth: Float? = {
            if let locked = dragStateValue.widthLock, locked > 0 {
                return locked
            }
            if let avail = availableWidth {
                let trailingReserve = trailingEl != nil ? (trailingWidthValue + effectiveGap) : 0.0
                return overflowMode.tabWidth(
                    available: max(0, avail - trailingReserve),
                    unpinnedCount: count - pinnedCount,
                    pinnedCount: pinnedCount,
                    gap: effectiveGap
                )
            }
            return nil
        }()

        // A separator stands after tab `i` unless it or the next is active, hovered or dragged.
        let quiet: (String) -> Bool = { id in
            id == selectedId || id == dragStateValue.hoveredId || id == dragStateValue.draggingId
        }
        let separatorAfter: (Int) -> Bool = { i in
            !vertical && i + 1 < count && !quiet(slots[i].id) && !quiet(slots[i + 1].id)
        }
        // Each tab's length along the strip with the gap after it: its width across (and the
        // separator after it), its row down.
        // Every horizontal tab is drawn this wide (`width: Some(tab_w)`), so a run of unbuilt
        // tabs is exactly as long as they would be.
        let tabW = computedUnpinnedWidth ?? Self.defaultTabWidth(overflowMode)
        let unpinnedDensity = density ?? (vertical ? dens : TabOverflow.densityFor(tabW))
        let pinnedW = overflowMode.pinnedTabWidth
        let tabWidth: Float? = vertical ? computedUnpinnedWidth : tabW
        let pitch: (Bool, Bool) -> Float = { pin, twoLine in
            vertical
                ? (twoLine ? TabStripBand.twoLineHeight : tabH) + effectiveGap
                : (pin ? pinnedW : tabW) + effectiveGap
        }
        let pitches: [Float] = slots.indices.map { i in
            pitch(slots[i].pinned, slots[i].twoLine) + (separatorAfter(i) ? Self.separatorWidth + effectiveGap : 0)
        }
        let landing = dragStateValue.incomingSlot(count: count)
        let listKey = "\(keyId)-list"
        let scrollKey = "\(keyId)-scroll"
        let viewport = dragKeyPath.map { _ in TabAutoScroll.viewport(for: keyId) }

        // Which tabs are built: past `BAND_PAST`, those near what the strip shows, and the ones a
        // gesture, a key or a menu is on wherever they are.
        let shown: [Bool]? = count > BAND_PAST ? {
            let along = vertical
                ? (tabH + effectiveGap) * TabStripBand.verticalStepRows
                : (tabW + effectiveGap) * TabStripBand.horizontalStepTabs
            let fallback = vertical ? TabStripBand.verticalFallback : (availableWidth ?? TabStripBand.horizontalFallback)
            let band = TabStripBand.band(
                listKey: listKey,
                scrollKey: scrollKey,
                vertical: vertical,
                step: max(along, TabStripBand.minStep),
                fallback: fallback
            )
            return TabStripBand.built(
                slots: slots,
                pitches: pitches,
                band: band,
                active: selectedId,
                dragging: dragStateValue.draggingIndex,
                landing: landing
            )
        }() : nil

        var stripChildren: [El<State>] = []
        stripChildren.reserveCapacity(min(count, BAND_PAST * 2) * 2)
        // Where each built tab's element is in `stripChildren`.
        var atChild = [Int?](repeating: nil, count: count)
        // A run of tabs not built: where it starts, and its length along the strip.
        var run: (from: Int, len: Float)? = nil
        func space() {
            guard let (from, len) = run else { return }
            run = nil
            let spacer: El<State> = el().key("\(listKey)-unbuilt-\(from)").a11yHidden()
            // The list's own gap stands after it, as after a tab.
            stripChildren.append(
                vertical
                    ? spacer.wFull().h(max(0, len - effectiveGap))
                    : spacer.w(max(0, len - effectiveGap)).h(tabH)
            )
        }
        for i in 0..<count {
            if let shown, !shown[i] {
                run = (run?.from ?? i, (run?.len ?? 0) + pitches[i])
                continue
            }
            space()
            let item = buildTab(i)
            atChild[i] = stripChildren.count
            stripChildren.append(
                buildSingleTab(
                    item: item,
                    index: i,
                    tabBarCount: count,
                    partition: item.isPinned ? 0..<pinnedCount : pinnedCount..<count,
                    pitch: pitches[i],
                    viewport: viewport,
                    dens: item.isPinned ? .iconOnly : unpinnedDensity,
                    tabH: tabH,
                    computedUnpinnedWidth: tabWidth,
                    dragStateValue: dragStateValue,
                    elevateDragged: elevateDragged,
                    kit: k
                )
            )
            if separatorAfter(i) {
                stripChildren.append(
                    el()
                        .key("\(keyId)-sep-\(i)")
                        .w(Self.separatorWidth)
                        .h(tabH * 0.55)
                        .bg(k.c.borderMuted)
                )
            }
        }
        space()
        // The incoming tab's place: an empty slot its own length, which the tab takes when it's
        // let go.
        if let slot = landing {
            let incomingPitch = pitch(false, false)
            let place: El<State> = el().key("\(listKey)-incoming").a11yHidden()
            let sized = vertical ? place.wFull().h(incomingPitch) : place.w(incomingPitch - effectiveGap).h(tabH)
            let child = (slot < count ? atChild[slot] : nil) ?? stripChildren.count
            stripChildren.insert(sized, at: child)
        }

        let listLabel = accessibleLabel ?? "Tabs"
        var track: El<State>
        if orientation == .horizontal {
            let list = row()
                .key(listKey)
                .role(.tabList)
                .label(listLabel)
                .focusGroup(true)
                .gap(effectiveGap)
                .itemsCenter()
                .children(stripChildren)
            track = row()
                .key(scrollKey)
                .grow(1)
                .minW(0)
                .itemsCenter()
                .scrollX()
                .child(list)
        } else {
            let list = col()
                .key(listKey)
                .role(.tabList)
                .label(listLabel)
                .focusGroup(true)
                .wFull()
                .gap(effectiveGap)
                .children(stripChildren)
            track = col()
                .key(scrollKey)
                .wFull()
                .grow(1)
                .minH(0)
                .scroll()
                .child(list)
        }

        if let viewport {
            track = track.drawnRectInto(viewport.rect).chainScrollOffset { viewport.position = $0 }
        }

        if orientation == .horizontal {
            var strip: El<State> = row()
                .key(keyId)
                .wFull()
                .h(tabH + 6)
                .px(6)
                .gap(4)
                .itemsCenter()
                .bg(fillColor ?? k.c.layer01)
                .borderSides(bottom: 1.0, color: k.c.borderMuted)
            if let dragKeyPath {
                strip = strip.onHover { s, inside, tx in
                    let previousWidth = s[keyPath: dragKeyPath].widthLock
                    if !inside { s[keyPath: dragKeyPath].leave() }
                    if s[keyPath: dragKeyPath].widthLock == previousWidth { tx.liveOnly() }
                }
            }
            if let leadingEl { strip = strip.child(leadingEl) }
            strip = strip.child(track)
            if let trailingEl { strip = strip.child(trailingEl) }
            return strip
        } else {
            // It grows into the height it's given, so its scroll shows what fits (`grow(1).min_h(0)`).
            var strip: El<State> = col()
                .key(keyId)
                .wFull()
                .grow(1)
                .minH(0)
                .p(6)
                .gap(4)
                .bg(fillColor ?? k.c.layer01)
            if let leadingEl { strip = strip.child(leadingEl) }
            strip = strip.child(track)
            if let trailingEl { strip = strip.child(trailingEl) }
            return strip
        }
    }

    @inline(never)
    private func buildSingleTab(
        item: StripTabItem<State>,
        index: Int,
        tabBarCount: Int,
        partition: Range<Int>,
        pitch: Float,
        viewport: TabAutoScroll.Viewport?,
        dens: TabDensity,
        tabH: Float,
        computedUnpinnedWidth: Float?,
        dragStateValue: TabDragState,
        elevateDragged: Bool,
        kit k: Kit
    ) -> El<State> {
        let isSelected = (item.id == selectedId)
        let isHovered = (dragStateValue.hoveredId == item.id)
        let isDragged = (dragStateValue.draggingId == item.id)
        let isEditing = item.editorEl != nil

        var tab = buildTabShell(
            item: item,
            index: index,
            tabBarCount: tabBarCount,
            tabH: tabH,
            computedUnpinnedWidth: computedUnpinnedWidth,
            isSelected: isSelected,
            isHovered: isHovered,
            isEditing: isEditing,
            kit: k
        )
        tab = appendTabContent(
            to: tab,
            item: item,
            dens: dens,
            tabH: tabH,
            isSelected: isSelected,
            isEditing: isEditing,
            kit: k
        )
        if !item.isDisabled && !isEditing {
            tab = attachTabHandlers(
                to: tab,
                item: item,
                index: index,
                tabBarCount: tabBarCount,
                partition: partition,
                pitch: pitch,
                viewport: viewport,
                computedUnpinnedWidth: computedUnpinnedWidth,
                isSelected: isSelected,
                kit: k
            )
        }
        return applyTabDragAndDecoration(
            to: tab,
            item: item,
            index: index,
            dens: dens,
            computedUnpinnedWidth: computedUnpinnedWidth,
            dragStateValue: dragStateValue,
            isDragged: isDragged,
            elevateDragged: elevateDragged,
            kit: k
        )
    }

    private static func statusWords(_ words: TabWords, _ status: TabItemStatus) -> String {
        switch status {
        case .none: return ""
        case .spinner: return words.busy
        case .dirty: return words.attention
        case .dot: return words.unread
        case .badge(_, let tone):
            switch tone {
            case .danger: return words.failed
            case .warning: return words.attention
            case .info, .neutral, .success, .accent: return words.unread
            }
        }
    }

    @inline(never)
    private func buildTabShell(
        item: StripTabItem<State>,
        index: Int,
        tabBarCount: Int,
        tabH: Float,
        computedUnpinnedWidth: Float?,
        isSelected: Bool,
        isHovered: Bool,
        isEditing: Bool,
        kit k: Kit
    ) -> El<State> {
        // A marked tab (its context menu open) keeps the hover wash (`item.marked => c.hover`).
        let bg: Color = (isSelected || isEditing) ? k.c.surfaceRaised : ((isHovered || item.isMarked) ? k.c.surfaceHover : .transparent)
        let statusDesc = Self.statusWords(wordsValue, item.status)
        var tab: El<State> = row()
            .key("\(keyId)-tab-\(item.id)")
            .role(.tab)
            .label(item.title)
            .hoverGroup()
            .selected(isSelected ? "true" : "false")
            .itemSelected(isSelected)
            .disabled(item.isDisabled)
            .positionInSet(index + 1, size: tabBarCount)
            .h(orientation == .vertical && item.subtitle != nil ? TabStripBand.twoLineHeight : tabH)
            .px(item.isPinned ? 8 : 10)
            .gap(6)
            .itemsCenter()
            .rounded(StripTabItem<State>.cornerRadius)
            .bg(bg)
            .clip(true)

        if !statusDesc.isEmpty {
            tab = tab.description(statusDesc)
        }

        if orientation == .horizontal {
            // Every horizontal tab has a fixed width (`width: Some(tab_w)`): the strip's share, else
            // the overflow's `max_width`, so the band's pitches are what it draws.
            if item.isPinned {
                tab = tab.w(effectiveOverflow.pinnedTabWidth).center()
            } else {
                tab = tab.w(computedUnpinnedWidth ?? Self.defaultTabWidth(effectiveOverflow))
            }
        } else {
            tab = tab.wFull()
        }

        if item.isPulsing {
            tab = tab.border(1.5, k.c.borderFocus)
        } else if isSelected {
            tab = tab.border(1.0, k.c.borderMuted)
        }
        return tab
    }

    @inline(never)
    private func buildTabLeadingAccessory(
        item: StripTabItem<State>,
        tabH: Float,
        isSelected: Bool,
        kit k: Kit
    ) -> El<State>? {
        if let avatar = item.avatarEl {
            return row().key("\(keyId)-avatar-\(item.id)")
                .size(16, 16)
                .center()
                .a11yHidden()
                .child(avatar)
        }
        if let svg = item.iconSvg {
            return el().w(StripTabItem<State>.iconSlot).h(tabH).center().a11yHidden()
                .child(Rune.icon(svg, size: 14).color(isSelected ? k.c.iconBase : k.c.iconMuted))
        }
        return nil
    }

    @inline(never)
    private func buildTabTitleOrEditor(
        item: StripTabItem<State>,
        iconOnly: Bool,
        fg: Color,
        kit k: Kit
    ) -> El<State>? {
        if let editor = item.editorEl {
            return row().key("\(keyId)-editor-\(item.id)")
                .grow(1)
                .minW(0)
                .child(editor)
        }
        guard !iconOnly else { return nil }
        // `text-[13px] font-medium` with zero tracking so long titles match OpenCode (`tab-nav.tsx`).
        var titleFont = k.ty.uiCompact
        titleFont.weight = k.ty.uiMedium.weight
        titleFont.letterSpacing = 0.0
        var textStack: El<State> = col().grow(1).minW(0).a11yHidden()
            .child(text(item.title).key("\(keyId)-title-\(item.id)").font(titleFont).color(fg).ellipsis())
        if let sub = item.subtitle, !sub.isEmpty {
            textStack = textStack.child(text(sub).font(k.ty.small).color(k.c.textFaint).ellipsis())
        }
        return textStack
    }

    @inline(never)
    private func buildTabStatusMark(item: StripTabItem<State>, kit k: Kit) -> El<State>? {
        switch item.status {
        case .none:
            if let badgeText = item.badgeText, !badgeText.isEmpty {
                return k.badge(badgeText, tone: .neutral).key("\(keyId)-status-\(item.id)").a11yHidden()
            }
            return nil
        case .dirty:
            return el().key("\(keyId)-status-\(item.id)").w(StripTabItem<State>.dotSize).h(StripTabItem<State>.dotSize).rounded(3.5).bg(k.c.textAccent).a11yHidden()
        case .dot(let col):
            return el().key("\(keyId)-status-\(item.id)").w(StripTabItem<State>.dotSize).h(StripTabItem<State>.dotSize).rounded(3.5).bg(col).a11yHidden()
        case .badge(let label, let tone):
            return k.badge(label, tone: tone).key("\(keyId)-status-\(item.id)").a11yHidden()
        case .spinner:
            return (busyIndicatorFn?(k) ?? k.radarSpinner(key: "\(keyId)-spin-\(item.id)", size: 12)).a11yHidden()
        }
    }

    @inline(never)
    private func appendTabContent(
        to initialTab: El<State>,
        item: StripTabItem<State>,
        dens: TabDensity,
        tabH: Float,
        isSelected: Bool,
        isEditing: Bool,
        kit k: Kit
    ) -> El<State> {
        var tab = initialTab
        let fg: Color = item.isDisabled ? k.c.textFaint : (isSelected ? k.c.textBase : k.c.textMuted)
        let iconOnly = item.isPinned || (dens == .iconOnly)
        let closable = item.isClosable && !item.isPinned && (!iconOnly || isSelected) && !item.isDisabled && !isEditing && onCloseFn != nil
        let touch = hoverNoneValue && closable && !iconOnly

        if let leading = buildTabLeadingAccessory(item: item, tabH: tabH, isSelected: isSelected, kit: k) {
            tab = tab.child(leading)
        }
        if let mid = buildTabTitleOrEditor(item: item, iconOnly: iconOnly, fg: fg, kit: k) {
            tab = tab.child(mid)
        }
        if let statusMark = buildTabStatusMark(item: item, kit: k) {
            tab = tab.child(statusMark)
        }
        if closable, let onCloseFn {
            let close = buildTabCloseButton(item: item, touch: touch, onCloseFn: onCloseFn, kit: k)
            if iconOnly {
                tab = tab.child(el().pin(top: 0, right: 0, bottom: 0, left: 0).center().child(close))
            } else {
                tab = tab.child(close)
            }
        }
        return tab
    }

    @inline(never)
    private func buildTabCloseButton(
        item: StripTabItem<State>,
        touch: Bool,
        onCloseFn: @escaping (inout State, String, inout Tx) -> Void,
        kit k: Kit
    ) -> El<State> {
        let idCopy = item.id
        var closeBtn = k.iconButton(
            key: "\(keyId)-close-\(item.id)",
            svg: closeIconSvg ?? k.glyph.close,
            label: wordsValue.close,
            size: .sm,
            variant: .ghost
        ) { s, tx in
            onCloseFn(&s, idCopy, &tx)
        }
        if !closeTabStopValue {
            closeBtn = closeBtn.focusable(false)
        }
        if !touch {
            closeBtn = closeBtn.groupOpacity(0.0, 1.0)
        }
        return closeBtn
    }

    @inline(never)
    private func attachTabHandlers(
        to initialTab: El<State>,
        item: StripTabItem<State>,
        index: Int,
        tabBarCount: Int,
        partition: Range<Int>,
        pitch: Float,
        viewport: TabAutoScroll.Viewport?,
        computedUnpinnedWidth: Float?,
        isSelected: Bool,
        kit k: Kit
    ) -> El<State> {
        var tab = initialTab
        let idCopy = item.id
        let selectEarly = selectOnDragStartOverride ?? true

        if !isSelected {
            tab = tab.hover(k.c.surfaceHover)
        }
        tab = tab.focusable().focusRing(k.c.borderFocus)

        if let onSelectFn {
            let scroll = "\(keyId)-scroll"
            let key = "\(keyId)-tab-\(idCopy)"
            tab = tab.onClick { s, tx in
                if let dragKeyPath, s[keyPath: dragKeyPath].swallowNextClick {
                    s[keyPath: dragKeyPath].swallowNextClick = false
                    tx.liveOnly()
                    return
                }
                onSelectFn(&s, idCopy, &tx)
                tx.scrollIntoViewIn(scroll, key)
            }
        }
        if let onDoubleClickFn {
            tab = tab.onDoubleClick { s, tx in
                onDoubleClickFn(&s, idCopy, &tx)
            }
        }

        if item.isClosable && !item.isPinned, let onCloseFn {
            let closeLock = (orientation == .horizontal) ? computedUnpinnedWidth : nil
            tab = tab.onMiddlePress { s, tx in
                if let dragKeyPath, let closeLock, closeLock > 0 {
                    s[keyPath: dragKeyPath].lockWidthForClose(closeLock)
                }
                onCloseFn(&s, idCopy, &tx)
            }
        }
        if let dragKeyPath {
            tab = tab.onPointerDown { s, press, tx in
                guard press.button == .primary else { return }
                s[keyPath: dragKeyPath].press(
                    id: idCopy,
                    index: index,
                    at: press.window,
                    scrollOffset: viewport?.offset(vertical: orientation == .vertical) ?? 0
                )
                if selectEarly, let onSelectFn {
                    if isSelected {
                        tx.liveOnly()
                    } else {
                        onSelectFn(&s, idCopy, &tx)
                        tx.scrollIntoViewIn("\(keyId)-scroll", "\(keyId)-tab-\(idCopy)")
                    }
                }
            }
        }

        if dragKeyPath != nil || onHoverFn != nil {
            let onHover = onHoverFn
            tab = tab.onHover { s, inside, tx in
                if let dragKeyPath {
                    if inside {
                        s[keyPath: dragKeyPath].setHovered(idCopy)
                    } else if s[keyPath: dragKeyPath].hoveredId == idCopy {
                        s[keyPath: dragKeyPath].setHovered(nil)
                    }
                }
                if let onHover {
                    onHover(&s, idCopy, inside, &tx)
                } else {
                    tx.liveOnly()
                }
            }
        }

        if let dragKeyPath {
            let isPin = item.isPinned
            let vertical = orientation == .vertical
            let scrollKey = "\(keyId)-scroll"
            let tearSpec = tearOutSpec
            let onReorder = onReorderFn
            let onTear = onTearOutFn
            let onTearMove = onTearMoveFn
            tab = tab
                .onDrag { s, drag, tx in
                    switch drag.phase {
                    case .down:
                        tx.liveOnly()
                        return
                    case .up:
                        if drag.isCancelled {
                            s[keyPath: dragKeyPath].cancel()
                            tx.animated()
                            return
                        }
                        let inside = drag.local.x >= 0 && drag.local.x <= drag.size.x
                            && drag.local.y >= 0 && drag.local.y <= drag.size.y
                        let wasClick: Bool
                        if case .pressing = s[keyPath: dragKeyPath].phase {
                            wasClick = true
                            tx.liveOnly()
                        } else {
                            wasClick = false
                            tx.animated()
                        }
                        let torn = s[keyPath: dragKeyPath].isTornOut
                        let reorder = s[keyPath: dragKeyPath].release()
                        s[keyPath: dragKeyPath].swallowNextClick = inside && (selectEarly || !wasClick)
                        if let reorder { onReorder?(&s, reorder, &tx) }
                        if torn { onTear?(&s, TabTearOut(id: idCopy, index: index, windowPoint: drag.window), &tx) }
                        return
                    case .move:
                        guard onReorder != nil || tearSpec != nil else {
                            tx.liveOnly()
                            return
                        }
                    }
                    if s[keyPath: dragKeyPath].isDragging {
                        viewport?.step(at: drag.window, vertical: vertical, key: scrollKey, tx: &tx)
                    }
                    let outcome = s[keyPath: dragKeyPath].follow(
                        to: drag.window,
                        orientation: orientation,
                        tabSize: pitch,
                        count: tabBarCount,
                        tearOut: tearSpec,
                        isPinned: isPin,
                        scrollOffset: viewport?.offset(vertical: vertical) ?? 0,
                        partition: partition
                    )
                    if s[keyPath: dragKeyPath].isDragging || s[keyPath: dragKeyPath].isTornOut {
                        tx.animated()
                    }
                    switch outcome {
                    case .tornOut:
                        onTearMove?(&s, TabTearMove(id: idCopy, windowPoint: drag.window, insideStrip: false), &tx)
                    case .tearMoved(let move):
                        onTearMove?(&s, move, &tx)
                    case .moved, .none:
                        break
                    }
                }
        }
        return tab
    }

    @inline(never)
    private func applyTabDragAndDecoration(
        to initialTab: El<State>,
        item: StripTabItem<State>,
        index: Int,
        dens: TabDensity,
        computedUnpinnedWidth: Float?,
        dragStateValue: TabDragState,
        isDragged: Bool,
        elevateDragged: Bool,
        kit k: Kit
    ) -> El<State> {
        var tab = initialTab
        if isDragged {
            if case .dragging(_, _, _, let offset) = dragStateValue.phase {
                tab = orientation == .horizontal
                    ? tab.offset(offset, 0)
                    : tab.offset(0, offset)
                tab = tab.raise().offsetMotion(.instant)
            }
            if elevateDragged {
                tab = tab.z(20).shadows(k.shadowLayers(k.elevation.raised))
            }
        } else if dragStateValue.isDragging {
            let shift = dragStateValue.shift(forIndex: index, itemExtent: dragStateValue.draggedPitch ?? computedUnpinnedWidth ?? 120.0)
            if shift != 0 {
                tab = orientation == .horizontal
                    ? tab.offset(shift, 0).animateLayout(reorderSpringValue)
                    : tab.offset(0, shift).animateLayout(reorderSpringValue)
            }
        }

        if let matchedPrefixValue {
            tab = tab.matched("\(matchedPrefixValue)-\(item.id)", spring: reorderSpringValue)
        }
        if let wrap = item.decorateFn {
            tab = wrap(tab, dens)
        }
        return tab.role(.tab)
    }
}
