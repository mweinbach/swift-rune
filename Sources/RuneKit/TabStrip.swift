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
    public private(set) var hoveredId: String? = nil
    public private(set) var incomingIndex: Int? = nil
    public private(set) var handedOff: Bool = false
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

    public mutating func press(id: String, index: Int, at windowPoint: Vec2, tabWidth: Float? = nil) {
        handedOff = false
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
        isPinned: Bool = false
    ) -> DragOutcome {
        let alongDelta: (Vec2, Vec2) -> Float = { a, b in
            orientation == .horizontal ? (b.x - a.x) : (b.y - a.y)
        }
        let crossDist: (Vec2, Vec2) -> Float = { a, b in
            orientation == .horizontal ? abs(b.y - a.y) : abs(b.x - a.x)
        }

        switch phase {
        case .idle:
            return .none

        case .pressing(let id, let idx, let start, _):
            let primary = alongDelta(start, windowPoint)
            let cross = crossDist(start, windowPoint)
            if max(abs(primary), cross) < Self.slop {
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
                isPinned: isPinned
            )

        case .dragging(let id, let from, let currentTarget, _):
            let anchorCenter = tabCenters.indices.contains(from) ? tabCenters[from] : Float(from) * tabSize + tabSize * 0.5
            let ptrAlong = orientation == .horizontal ? windowPoint.x : windowPoint.y
            let offset = tabCenters.isEmpty ? alongDelta(.zero, windowPoint) : (ptrAlong - anchorCenter)
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
                isPinned: isPinned
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
        isPinned: Bool
    ) -> DragOutcome {
        if let tearOut, (count > 1 || tearOut.lone), (!isPinned || tearOut.allowPinned), let bounds = tearOut.stripBounds {
            let expanded = MotionRect(
                left: bounds.left - tearOut.threshold,
                top: bounds.top - tearOut.threshold,
                right: bounds.right + tearOut.threshold,
                bottom: bounds.bottom + tearOut.threshold
            )
            if !motionRectContains(expanded, windowPoint) {
                phase = .tornOut(id: id, originIndex: from, windowPoint: windowPoint)
                return .tornOut(TabTearOut(id: id, index: from, windowPoint: windowPoint))
            }
        }
        guard count > 0 else {
            phase = .dragging(id: id, fromIndex: from, toIndex: from, offset: offset)
            return .none
        }
        let target: Int
        if !tabCenters.isEmpty {
            let extents = tabCenters.map { (start: $0 - tabSize * 0.5, size: tabSize) }
            let ptr = orientation == .horizontal ? windowPoint.x : windowPoint.y
            target = Self.landingSlot(pointerAlong: ptr, itemExtents: extents, fromIndex: currentTarget)
                .clamped(to: 0...(count - 1))
        } else {
            let step = max(1, tabSize)
            let deltaSlots = Int((offset / step).rounded())
            target = (from + deltaSlots).clamped(to: 0...(count - 1))
        }
        phase = .dragging(id: id, fromIndex: from, toIndex: target, offset: offset)
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
    }

    @discardableResult
    public mutating func release() -> TabReorder? {
        defer { phase = .idle }
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

    /// Computes a new clamped scroll offset over `dt` seconds when `pointerAlong` sits inside the
    /// edge activation band (`[start, start + zone]` or `[end - zone, end]`).
    public static func step(
        pointerAlong: Float,
        viewportStart: Float,
        viewportEnd: Float,
        scrollOffset: Float,
        maxScroll: Float,
        dt: Float
    ) -> Float {
        let len = viewportEnd - viewportStart
        guard len > 0, maxScroll > 0, dt > 0 else { return scrollOffset.clamped(to: 0...max(0, maxScroll)) }
        let zone = max(tolerance, len * threshold)
        let speed: Float
        if pointerAlong < viewportStart + zone {
            let depth = (viewportStart + zone - pointerAlong) / zone
            speed = -depth.clamped(to: 0...2) * len * acceleration
        } else if pointerAlong > viewportEnd - zone {
            let depth = (pointerAlong - (viewportEnd - zone)) / zone
            speed = depth.clamped(to: 0...2) * len * acceleration
        } else {
            return scrollOffset.clamped(to: 0...maxScroll)
        }
        return (scrollOffset + speed * dt).clamped(to: 0...maxScroll)
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
    public var status: TabItemStatus
    public var badgeText: String?

    public init(id: String, title: String) {
        self.id = id
        self.title = title
        self.subtitle = nil
        self.iconSvg = nil
        self.isPinned = false
        self.isClosable = true
        self.isDisabled = false
        self.isPulsing = false
        self.status = .none
        self.badgeText = nil
    }

    public func subtitle(_ value: String?) -> Self { var c = self; c.subtitle = value; return c }
    public func icon(_ svg: SVGIcon?) -> Self { var c = self; c.iconSvg = svg; return c }
    public func pinned(_ on: Bool = true) -> Self { var c = self; c.isPinned = on; return c }
    public func closable(_ on: Bool = true) -> Self { var c = self; c.isClosable = on; return c }
    public func disabled(_ on: Bool = true) -> Self { var c = self; c.isDisabled = on; return c }
    public func pulse(_ on: Bool = true) -> Self { var c = self; c.isPulsing = on; return c }
    public func status(_ value: TabItemStatus) -> Self { var c = self; c.status = value; return c }
    public func badge(_ value: String?) -> Self { var c = self; c.badgeText = value; return c }
}

/// Configurable desktop/mobile tab strip supporting pinned partitions, overflow shrink/scroll,
/// separator hover/active suppression, close buttons, middle-click close, pulse rings, and
/// `TabDragState` reordering / tear-out (`rune_kit::shell::TabStrip`).
public struct TabStrip<State> {
    private var keyId: String
    private var items: [StripTabItem<State>]
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
    private var onSelectFn: ((inout State, String, inout Tx) -> Void)? = nil
    private var onCloseFn: ((inout State, String, inout Tx) -> Void)? = nil
    private var onReorderFn: ((inout State, TabReorder, inout Tx) -> Void)? = nil
    private var onTearOutFn: ((inout State, TabTearOut, inout Tx) -> Void)? = nil

    public init(key: String = "tab-strip", tabs: [StripTabItem<State>], selected: String? = nil) {
        self.keyId = key
        self.items = tabs
        self.selectedId = selected
    }

    public func label(_ value: String) -> Self { var c = self; c.accessibleLabel = value; return c }

    public func orientation(_ value: TabOrientation) -> Self { var c = self; c.orientation = value; return c }
    public func density(_ value: TabDensity) -> Self { var c = self; c.density = value; return c }
    public func overflow(_ value: TabOverflow) -> Self { var c = self; c.overflow = value; return c }
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
    public func onReorder(_ f: @escaping (inout State, TabReorder, inout Tx) -> Void) -> Self { var c = self; c.onReorderFn = f; return c }
    public func onTearOut(_ f: @escaping (inout State, TabTearOut, inout Tx) -> Void) -> Self { var c = self; c.onTearOutFn = f; return c }

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

    public func buildLayered(_ state: State, kit k: Kit, elevateDragged: Bool = true) -> El<State> {
        let dens = effectiveDensity
        let tabH = dens.height
        let overflowMode = effectiveOverflow
        let pinned = items.filter(\.isPinned)
        let unpinned = items.filter { !$0.isPinned }
        let ordered = pinned + unpinned

        let computedUnpinnedWidth: Float? = {
            if let locked = dragStateValue.widthLock, locked > 0 {
                return locked
            }
            if let avail = availableWidth {
                return overflowMode.tabWidth(
                    available: avail,
                    unpinnedCount: unpinned.count,
                    pinnedCount: pinned.count
                )
            }
            return nil
        }()

        let tabBarCount = ordered.count

        func buildSingleTab(item: StripTabItem<State>, index: Int) -> El<State> {
            let isSelected = (item.id == selectedId)
            let isHovered = (dragStateValue.hoveredId == item.id)
            let isDragged = (dragStateValue.draggingId == item.id)

            let bg: Color = isSelected ? k.c.surfaceRaised : (isHovered ? k.c.surfaceHover : .transparent)
            let fg: Color = item.isDisabled ? k.c.textFaint : (isSelected ? k.c.textBase : k.c.textMuted)

            var tab: El<State> = row()
                .key("\(keyId)-tab-\(item.id)")
                .role(.tab)
                .label(item.title)
                .selected(isSelected ? "true" : "false")
                .itemSelected(isSelected)
                .positionInSet(index + 1, size: tabBarCount)
                .h(tabH)
                .px(item.isPinned ? 8 : 10)
                .gap(6)
                .itemsCenter()
                .rounded(StripTabItem<State>.cornerRadius)
                .bg(bg)
                .clip(true)

            if orientation == .horizontal {
                if item.isPinned {
                    tab = tab.w(36).center()
                } else if let w = computedUnpinnedWidth {
                    tab = tab.w(w)
                } else {
                    tab = tab.minW(100).maxW(220)
                }
            } else {
                tab = tab.wFull()
            }

            if item.isPulsing {
                tab = tab.border(1.5, k.c.borderFocus)
            } else if isSelected {
                tab = tab.border(1.0, k.c.borderMuted)
            }

            // Leading icon / status slot
            if let svg = item.iconSvg {
                tab = tab.child(
                    el().w(StripTabItem<State>.iconSlot).h(tabH).center()
                        .child(Rune.icon(svg, size: 14).color(isSelected ? k.c.iconBase : k.c.iconMuted))
                )
            }

            if !item.isPinned {
                var textStack: El<State> = col().grow(1).minW(0)
                    .child(text(item.title).font(isSelected ? k.ty.uiMedium : k.ty.ui).color(fg).ellipsis())
                if let sub = item.subtitle, !sub.isEmpty {
                    textStack = textStack.child(text(sub).font(k.ty.small).color(k.c.textFaint).ellipsis())
                }
                tab = tab.child(textStack)
            }

            switch item.status {
            case .none:
                break
            case .dirty:
                tab = tab.child(el().w(StripTabItem<State>.dotSize).h(StripTabItem<State>.dotSize).rounded(3.5).bg(k.c.textAccent))
            case .dot(let col):
                tab = tab.child(el().w(StripTabItem<State>.dotSize).h(StripTabItem<State>.dotSize).rounded(3.5).bg(col))
            case .badge(let label, let tone):
                tab = tab.child(k.badge(label, tone: tone))
            case .spinner:
                tab = tab.child(k.radarSpinner(key: "\(keyId)-spin-\(item.id)", size: 12))
            }

            if let badgeText = item.badgeText, !badgeText.isEmpty, case .none = item.status {
                tab = tab.child(k.badge(badgeText, tone: .neutral))
            }

            if item.isClosable && !item.isPinned && !item.isDisabled, let onCloseFn {
                let idCopy = item.id
                tab = tab.child(
                    k.iconButton(
                        key: "\(keyId)-close-\(item.id)",
                        svg: k.glyph.close,
                        label: "Close \(item.title)",
                        size: .sm,
                        variant: .ghost
                    ) { s, tx in
                        onCloseFn(&s, idCopy, &tx)
                    }
                )
            }

            if !item.isDisabled {
                let idCopy = item.id
                if !isSelected {
                    tab = tab.hover(k.c.surfaceHover)
                }
                tab = tab.focusable().focusRing(k.c.borderFocus)

                if let onSelectFn {
                    tab = tab.onClick { s, tx in
                        onSelectFn(&s, idCopy, &tx)
                    }
                }

                // Middle-click closes closable unpinned tabs
                if item.isClosable && !item.isPinned, let onCloseFn {
                    tab = tab.onPointerDown { s, press, tx in
                        if press.button == .middle {
                            onCloseFn(&s, idCopy, &tx)
                        } else if let dragKeyPath, press.button == .primary {
                            s[keyPath: dragKeyPath].press(
                                id: idCopy,
                                index: index,
                                at: press.window,
                                tabWidth: computedUnpinnedWidth
                            )
                        }
                    }
                } else if let dragKeyPath {
                    tab = tab.onPointerDown { s, press, _ in
                        guard press.button == .primary else { return }
                        s[keyPath: dragKeyPath].press(
                            id: idCopy,
                            index: index,
                            at: press.window,
                            tabWidth: computedUnpinnedWidth
                        )
                    }
                }

                if let dragKeyPath {
                    let isPin = item.isPinned
                    let estWidth = item.isPinned ? Float(36) : (computedUnpinnedWidth ?? 120.0)
                    let tearSpec = tearOutSpec
                    let onReorder = onReorderFn
                    let onTear = onTearOutFn
                    tab = tab
                        .onHover { s, inside, _ in
                            if inside {
                                s[keyPath: dragKeyPath].setHovered(idCopy)
                            } else if s[keyPath: dragKeyPath].hoveredId == idCopy {
                                s[keyPath: dragKeyPath].setHovered(nil)
                            }
                        }
                        .onDrag { s, drag, tx in
                            let outcome = s[keyPath: dragKeyPath].follow(
                                to: drag.window,
                                orientation: orientation,
                                tabSize: estWidth,
                                count: tabBarCount,
                                tearOut: tearSpec,
                                isPinned: isPin
                            )
                            switch outcome {
                            case .moved(let reorder):
                                onReorder?(&s, reorder, &tx)
                            case .tornOut(let tear):
                                onTear?(&s, tear, &tx)
                            case .none, .tearMoved:
                                break
                            }
                        }
                        .onDragEnd { s, cancelled, tx in
                            if cancelled {
                                s[keyPath: dragKeyPath].cancel()
                            } else if let reorder = s[keyPath: dragKeyPath].release() {
                                onReorder?(&s, reorder, &tx)
                            }
                        }
                }
            }

            if isDragged && elevateDragged {
                if case .dragging(_, _, _, let offset) = dragStateValue.phase {
                    tab = orientation == .horizontal
                        ? tab.offset(offset, 0)
                        : tab.offset(0, offset)
                }
                tab = tab.z(20).shadows(k.shadowLayers(k.elevation.raised))
            } else if dragStateValue.isDragging {
                let shift = dragStateValue.shift(forIndex: index, itemExtent: computedUnpinnedWidth ?? 120.0)
                if shift != 0 {
                    tab = orientation == .horizontal
                        ? tab.offset(shift, 0).animateLayout(MotionTokens.SNAP)
                        : tab.offset(0, shift).animateLayout(MotionTokens.SNAP)
                }
            }

            return tab.role(.tab)
        }

        // Assemble strip children with separator suppression next to active/hovered/selected tabs
        var stripChildren: [El<State>] = []
        for (idx, item) in ordered.enumerated() {
            stripChildren.append(buildSingleTab(item: item, index: idx))
            if orientation == .horizontal && idx + 1 < ordered.count {
                let next = ordered[idx + 1]
                let suppress = item.id == selectedId
                    || next.id == selectedId
                    || item.id == dragStateValue.hoveredId
                    || next.id == dragStateValue.hoveredId
                    || item.id == dragStateValue.draggingId
                    || next.id == dragStateValue.draggingId
                if !suppress {
                    stripChildren.append(
                        el()
                            .key("\(keyId)-sep-\(idx)")
                            .w(1)
                            .h(tabH * 0.55)
                            .bg(k.c.borderMuted)
                    )
                }
            }
        }

        let listLabel = accessibleLabel ?? "Tabs"
        var track: El<State>
        if orientation == .horizontal {
            track = row()
                .key("\(keyId)-track")
                .role(.tabList)
                .label(listLabel)
                .focusGroup(true)
                .grow(1)
                .minW(0)
                .gap(2)
                .itemsCenter()
            if computedUnpinnedWidth == nil || availableWidth == nil {
                track = track.scroll()
            }
            track = track.children(stripChildren)
        } else {
            track = col()
                .key("\(keyId)-track")
                .role(.tabList)
                .label(listLabel)
                .focusGroup(true)
                .wFull()
                .grow(1)
                .minH(0)
                .gap(2)
                .scroll()
                .children(stripChildren)
        }

        if orientation == .horizontal {
            var strip: El<State> = row()
                .key(keyId)
                .wFull()
                .h(tabH + 6)
                .px(6)
                .gap(4)
                .itemsCenter()
                .bg(k.c.layer01)
                .borderSides(bottom: 1.0, color: k.c.borderMuted)
            if let dragKeyPath {
                strip = strip.onHover { s, inside, _ in
                    if !inside { s[keyPath: dragKeyPath].leave() }
                }
            }
            if let leadingEl { strip = strip.child(leadingEl) }
            strip = strip.child(track)
            if let trailingEl { strip = strip.child(trailingEl) }
            return strip
        } else {
            var strip: El<State> = col()
                .key(keyId)
                .wFull()
                .p(6)
                .gap(4)
                .bg(k.c.layer01)
            if let leadingEl { strip = strip.child(leadingEl) }
            strip = strip.child(track)
            if let trailingEl { strip = strip.child(trailingEl) }
            return strip
        }
    }
}
