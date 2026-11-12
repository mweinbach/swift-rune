import Foundation
import Rune

/// Axis of a split pane in `SplitTree` (`rune_kit::shell::split`).
public enum SplitAxis: Sendable, Equatable, Hashable {
    case horizontal
    case vertical
}

/// A tab item in a `PaneGroup` (`rune_kit::shell::tab_strip`).
public struct PaneTab<Content: Sendable>: Sendable {
    public var id: String
    public var title: String
    public var closable: Bool
    public var dirty: Bool
    public var content: Content

    public init(
        id: String,
        title: String,
        closable: Bool = true,
        dirty: Bool = false,
        content: Content
    ) {
        self.id = id
        self.title = title
        self.closable = closable
        self.dirty = dirty
        self.content = content
    }
}

/// A group of tabs with an active tab index (`rune_kit::shell::tab_strip`).
public struct PaneGroup<Content: Sendable>: Sendable {
    public var id: String
    public var tabs: [PaneTab<Content>]
    public var activeTabID: String?

    public init(id: String = UUID().uuidString, tabs: [PaneTab<Content>] = [], activeTabID: String? = nil) {
        self.id = id
        self.tabs = tabs
        self.activeTabID = activeTabID ?? tabs.first?.id
    }

    public var activeTab: PaneTab<Content>? {
        if let activeTabID, let found = tabs.first(where: { $0.id == activeTabID }) {
            return found
        }
        return tabs.first
    }

    public mutating func select(tabID: String) {
        if tabs.contains(where: { $0.id == tabID }) {
            activeTabID = tabID
        }
    }

    public mutating func add(_ tab: PaneTab<Content>, activate: Bool = true) {
        if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs[idx] = tab
        } else {
            tabs.append(tab)
        }
        if activate {
            activeTabID = tab.id
        }
    }

    @discardableResult
    public mutating func close(tabID: String) -> Bool {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }), tabs[idx].closable else {
            return false
        }
        tabs.remove(at: idx)
        if activeTabID == tabID {
            let nextIdx = min(idx, max(0, tabs.count - 1))
            activeTabID = tabs.isEmpty ? nil : tabs[nextIdx].id
        }
        return true
    }

    /// Reorders `tabID` to `destinationIndex` (`rune_kit::shell::reorder`).
    public mutating func reorder(tabID: String, to destinationIndex: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == tabID }), !tabs.isEmpty else { return }
        let clamped = max(0, min(destinationIndex, tabs.count - 1))
        guard from != clamped else { return }
        let moved = tabs.remove(at: from)
        tabs.insert(moved, at: clamped)
    }
}

/// Recursive split/tab tree for multi-pane workspace layouts (`rune_kit::shell::split`).
public indirect enum SplitTree<Content: Sendable>: Sendable {
    case leaf(PaneGroup<Content>)
    case split(id: String, axis: SplitAxis, ratio: Float, first: SplitTree<Content>, second: SplitTree<Content>)

    public var focusedGroupID: String? {
        switch self {
        case .leaf(let g): return g.id
        case .split(_, _, _, let first, _): return first.focusedGroupID
        }
    }

    public mutating func selectTab(groupID: String, tabID: String) {
        switch self {
        case .leaf(var group):
            if group.id == groupID {
                group.select(tabID: tabID)
                self = .leaf(group)
            }
        case .split(let id, let axis, let ratio, var first, var second):
            first.selectTab(groupID: groupID, tabID: tabID)
            second.selectTab(groupID: groupID, tabID: tabID)
            self = .split(id: id, axis: axis, ratio: ratio, first: first, second: second)
        }
    }

    public mutating func closeTab(groupID: String, tabID: String) {
        switch self {
        case .leaf(var group):
            if group.id == groupID {
                group.close(tabID: tabID)
                self = .leaf(group)
            }
        case .split(let id, let axis, let ratio, var first, var second):
            first.closeTab(groupID: groupID, tabID: tabID)
            second.closeTab(groupID: groupID, tabID: tabID)
            self = .split(id: id, axis: axis, ratio: ratio, first: first, second: second)
        }
    }

    public mutating func reorderTab(groupID: String, tabID: String, to index: Int) {
        switch self {
        case .leaf(var group):
            if group.id == groupID {
                group.reorder(tabID: tabID, to: index)
                self = .leaf(group)
            }
        case .split(let id, let axis, let ratio, var first, var second):
            first.reorderTab(groupID: groupID, tabID: tabID, to: index)
            second.reorderTab(groupID: groupID, tabID: tabID, to: index)
            self = .split(id: id, axis: axis, ratio: ratio, first: first, second: second)
        }
    }

    public mutating func setRatio(splitID: String, ratio: Float) {
        switch self {
        case .leaf:
            break
        case .split(let id, let axis, let currentRatio, var first, var second):
            let nextRatio = (id == splitID) ? ratio.clamped(to: 0.15...0.85) : currentRatio
            first.setRatio(splitID: splitID, ratio: ratio)
            second.setRatio(splitID: splitID, ratio: ratio)
            self = .split(id: id, axis: axis, ratio: nextRatio, first: first, second: second)
        }
    }

    public mutating func splitLeaf(
        groupID: String,
        axis: SplitAxis,
        newGroup: PaneGroup<Content>,
        ratio: Float = 0.5,
        splitID: String = UUID().uuidString
    ) {
        switch self {
        case .leaf(let group):
            if group.id == groupID {
                self = .split(
                    id: splitID,
                    axis: axis,
                    ratio: ratio.clamped(to: 0.15...0.85),
                    first: .leaf(group),
                    second: .leaf(newGroup)
                )
            }
        case .split(let id, let a, let r, var first, var second):
            first.splitLeaf(groupID: groupID, axis: axis, newGroup: newGroup, ratio: ratio, splitID: splitID)
            second.splitLeaf(groupID: groupID, axis: axis, newGroup: newGroup, ratio: ratio, splitID: splitID)
            self = .split(id: id, axis: a, ratio: r, first: first, second: second)
        }
    }
}

/// Resizable, collapsible side pane state (`rune_kit::shell::pane::PaneState`).
public struct PaneState: Sendable, Equatable {
    public static let defaultMin: Float = 160
    public static let defaultMax: Float = 480

    public enum Dock: Sendable, Equatable {
        case open(fromPeek: Bool)
        case closedRest
        case closedPeekShown
        case closedPeekLeft
    }

    public struct GripStart: Sendable, Equatable {
        public var width: Float
        public var open: Bool
    }

    public private(set) var width: Float
    public private(set) var dock: Dock
    public private(set) var minWidth: Float
    public private(set) var maxWidth: Float
    private var askedWidth: Float
    private var defaultAskedWidth: Float
    private var grip: Grip<GripStart> = .idle

    public init(width: Float) {
        self.width = width
        self.dock = .open(fromPeek: false)
        self.minWidth = Self.defaultMin
        self.maxWidth = Self.defaultMax
        self.askedWidth = width
        self.defaultAskedWidth = width
        clamp()
    }

    public func range(min: Float, max: Float) -> PaneState {
        var copy = self
        copy.minWidth = Swift.max(1, min)
        copy.maxWidth = Swift.max(copy.minWidth, max)
        copy.width = copy.askedWidth
        copy.clamp()
        return copy
    }

    public func collapsed() -> PaneState {
        var copy = self
        copy.dock = .closedRest
        return copy
    }

    public func withWidth(_ width: Float) -> PaneState {
        var copy = self
        if width.isFinite {
            copy.askedWidth = width
            copy.setWidth(width)
        }
        return copy
    }

    public var isOpen: Bool {
        if case .open = dock { return true }
        return false
    }

    public var isPeeking: Bool {
        dock == .closedPeekShown
    }

    public var isResizing: Bool {
        grip.isHeld
    }

    public var defaultWidth: Float {
        defaultAskedWidth.rounded().clamped(to: minWidth...maxWidth)
    }

    public var shownWidth: Float {
        isOpen ? width : 0
    }

    public mutating func setWidth(_ width: Float) {
        guard width.isFinite else { return }
        self.width = width.rounded().clamped(to: minWidth...maxWidth)
    }

    public mutating func setOpen(_ open: Bool) {
        switch (dock, open) {
        case (.closedPeekShown, true):
            dock = .open(fromPeek: true)
        case (.closedRest, true), (.closedPeekLeft, true):
            dock = .open(fromPeek: false)
        case (.open, false):
            dock = .closedRest
        default:
            break
        }
    }

    public mutating func toggle() {
        setOpen(!isOpen)
    }

    public mutating func peek() {
        if !isOpen {
            dock = .closedPeekShown
        }
    }

    public mutating func endPeek() {
        if isPeeking {
            dock = .closedPeekLeft
        }
    }

    public mutating func beginResize(at point: Vec2? = nil) {
        grip.press(GripStart(width: width, open: isOpen), at: point)
    }

    public mutating func updateResize(deltaWidth: Float, collapseThreshold: Float = 80) {
        guard let start = grip.data else { return }
        let proposed = start.width + deltaWidth
        if proposed < collapseThreshold {
            setOpen(false)
        } else {
            setOpen(true)
            setWidth(proposed)
        }
    }

    public mutating func endResize() {
        grip.release()
    }

    public mutating func cancelResize() {
        guard let start = grip.release() else { return }
        width = start.width
        setOpen(start.open)
    }

    public mutating func resetToDefaultWidth() {
        setWidth(defaultWidth)
        setOpen(true)
    }

    private mutating func clamp() {
        if width.isFinite {
            width = width.rounded().clamped(to: minWidth...maxWidth)
        } else {
            width = minWidth
        }
    }
}

extension Kit {
    /// Renders a shell status bar (`rune_kit::shell::toolbar`).
    public func statusBar<State>(
        key: String = "statusbar",
        leading: El<State>? = nil,
        trailing: El<State>? = nil
    ) -> El<State> {
        var bar: El<State> = row()
            .key(key)
            .wFull()
            .h(26)
            .px(10)
            .itemsCenter()
            .justifyBetween()
            .bg(c.layer01)
            .borderSides(top: 1.0, color: c.borderMuted)
        if let leading { bar = bar.child(leading) } else { bar = bar.child(spacer()) }
        if let trailing { bar = bar.child(trailing) }
        return bar
    }

    /// Renders a collapsible sidebar (`rune_kit::shell::sidebar`).
    public func sidebar<State>(
        key: String = "sidebar",
        pane: PaneState,
        title: String? = nil,
        content: El<State>,
        onToggle: ((inout State) -> Void)? = nil
    ) -> El<State> {
        guard pane.isOpen || pane.isPeeking else {
            return el().key("\(key)-collapsed").w(0).hFull()
        }

        var panel: El<State> = col()
            .key(key)
            .w(pane.width)
            .hFull()
            .bg(c.layer01)
            .borderSides(right: 1.0, color: c.borderMuted)
            .clip(true)

        if title != nil || onToggle != nil {
            var header: El<State> = row()
                .wFull()
                .h(34)
                .px(10)
                .itemsCenter()
                .justifyBetween()
                .borderSides(bottom: 1.0, color: c.borderWeak)
            if let title {
                header = header.child(text(title).font(ty.smallMedium).color(c.textMuted))
            } else {
                header = header.child(spacer())
            }
            if let onToggle {
                header = header.child(
                    iconButton(key: "\(key)-toggle", svg: KitIcons.chevronDown, label: "Toggle sidebar", size: .sm, variant: .ghost) { s, _ in
                        onToggle(&s)
                    }
                )
            }
            panel = panel.child(header)
        }

        return panel.child(el().wFull().grow(1).minH(0).child(content))
    }

    /// Renders a `PaneGroup` tab strip + active tab content (`rune_kit::shell::tab_strip`).
    public func paneGroup<State, Content: Sendable>(
        key: String = "pane-group",
        group: PaneGroup<Content>,
        onSelectTab: @escaping (inout State, String) -> Void,
        onCloseTab: ((inout State, String) -> Void)? = nil,
        renderContent: (Content) -> El<State>
    ) -> El<State> {
        var strip: El<State> = row()
            .key("\(key)-strip")
            .wFull()
            .h(32)
            .px(6)
            .gap(4)
            .itemsCenter()
            .bg(c.layer02)
            .borderSides(bottom: 1.0, color: c.borderMuted)

        for tab in group.tabs {
            let isActive = group.activeTab?.id == tab.id
            var tabEl: El<State> = row()
                .key("\(key)-tab-\(tab.id)")
                .px(10)
                .py(4)
                .gap(6)
                .itemsCenter()
                .rounded(radius.sm)
                .bg(isActive ? c.layer01 : .transparent)
                .onClick { s in onSelectTab(&s, tab.id) }
                .child(
                    text(tab.dirty ? "\(tab.title) •" : tab.title)
                        .font(isActive ? ty.smallMedium : ty.small)
                        .color(isActive ? c.textBase : c.textMuted)
                )

            if tab.closable, let onCloseTab {
                tabEl = tabEl.child(
                    iconButton(key: "\(key)-close-\(tab.id)", svg: KitIcons.close, label: "Close \(tab.title)", size: .sm, variant: .ghost) { s, _ in
                        onCloseTab(&s, tab.id)
                    }
                )
            }
            strip = strip.child(tabEl)
        }

        let body: El<State> = if let active = group.activeTab {
            renderContent(active.content)
        } else {
            emptyState(key: "\(key)-empty", title: "No open tab")
        }

        return col()
            .key(key)
            .wFull()
            .hFull()
            .bg(c.page)
            .child(strip)
            .child(el().wFull().grow(1).minH(0).child(body))
    }

    /// Recursively renders a `SplitTree` of `PaneGroup`s (`rune_kit::shell::split`).
    public func splitTree<State, Content: Sendable>(
        key: String = "split-tree",
        tree: SplitTree<Content>,
        onSelectTab: @escaping (inout State, String, String) -> Void,
        onCloseTab: ((inout State, String, String) -> Void)? = nil,
        renderContent: (Content) -> El<State>
    ) -> El<State> {
        switch tree {
        case .leaf(let group):
            return paneGroup(
                key: "\(key)-leaf-\(group.id)",
                group: group,
                onSelectTab: { s, tabID in onSelectTab(&s, group.id, tabID) },
                onCloseTab: onCloseTab.map { cb in { s, tabID in cb(&s, group.id, tabID) } },
                renderContent: renderContent
            )

        case let .split(id, axis, ratio, first, second):
            let r = ratio.clamped(to: 0.15...0.85)
            let firstEl = splitTree(
                key: "\(key)-\(id)-a",
                tree: first,
                onSelectTab: onSelectTab,
                onCloseTab: onCloseTab,
                renderContent: renderContent
            )
            let secondEl = splitTree(
                key: "\(key)-\(id)-b",
                tree: second,
                onSelectTab: onSelectTab,
                onCloseTab: onCloseTab,
                renderContent: renderContent
            )

            switch axis {
            case .horizontal:
                return row()
                    .key("\(key)-\(id)")
                    .wFull()
                    .hFull()
                    .child(el().hFull().wFrac(r).minW(0).child(firstEl))
                    .child(el().w(1).hFull().bg(c.borderMuted))
                    .child(el().hFull().wFrac(1.0 - r).minW(0).child(secondEl))
            case .vertical:
                return col()
                    .key("\(key)-\(id)")
                    .wFull()
                    .hFull()
                    .child(el().wFull().hFrac(r).minH(0).child(firstEl))
                    .child(el().wFull().h(1).bg(c.borderMuted))
                    .child(el().wFull().hFrac(1.0 - r).minH(0).child(secondEl))
            }
        }
    }
}
