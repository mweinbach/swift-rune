import Foundation
import Rune
import RuneMotion

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

    /// How a closed sidebar is peeking over the workspace (`rune_kit::shell::pane::PeekPhase`).
    public enum PeekPhase: Sendable, Equatable {
        case rest
        case shown
        case left
    }

    /// How `SplitView` slides a collapsible pane in and out (`rune_kit::shell::PaneMotion`).
    public struct PaneMotion: Sendable, Equatable {
        public var springOverride: Spring?
        public var scaleReference: Float?
        public var scaleMin: Float
        public var scaleMax: Float
        public var fadeTailFraction: Float?
        public var reducedFadeSeconds: Float

        public static let slide = PaneMotion()
        public static let snap = PaneMotion(springOverride: MotionTokens.SNAP)
        public static let instant = PaneMotion(springOverride: Spring.none)

        public init(
            springOverride: Spring? = nil,
            scaleReference: Float? = nil,
            scaleMin: Float = 0.001,
            scaleMax: Float = 1.0,
            fadeTailFraction: Float? = nil,
            reducedFadeSeconds: Float = 0.0
        ) {
            self.springOverride = springOverride
            self.scaleReference = scaleReference
            self.scaleMin = scaleMin
            self.scaleMax = scaleMax
            self.fadeTailFraction = fadeTailFraction
            self.reducedFadeSeconds = max(0.0, reducedFadeSeconds)
        }

        public func spring(_ s: Spring) -> Self {
            var c = self
            c.springOverride = s
            return c
        }

        public func scaleWithWidth(reference: Float, min minSeconds: Float, max maxSeconds: Float) -> Self {
            let clampedMin = max(0.001, minSeconds)
            var c = self
            c.scaleReference = max(1.0, reference)
            c.scaleMin = clampedMin
            c.scaleMax = max(clampedMin, maxSeconds)
            return c
        }

        public func fadeTail(_ fraction: Float) -> Self {
            var c = self
            c.fadeTailFraction = fraction.clamped(to: 0.001...1.0)
            return c
        }

        public func reducedMotionFade(_ seconds: Float) -> Self {
            var c = self
            c.reducedFadeSeconds = max(0.0, seconds)
            return c
        }

        public func spring(forWidth width: Float, kit k: Kit) -> Spring {
            let base = springOverride ?? k.motion.disclosure
            guard let ref = scaleReference else { return base }
            let scaled = base.duration * sqrt(max(0.0, width) / ref)
            return base.withDuration(scaled.clamped(to: scaleMin...scaleMax))
        }

        public func spring(reducedMotion: Bool) -> Spring? {
            if reducedMotion { return nil }
            let resolved = springOverride ?? MotionTokens.SETTLE
            if resolved == Spring.none || resolved.duration <= 0 {
                return nil
            }
            return resolved
        }

        public func fade(spring: Spring, open: Bool, reducedMotion: Bool) -> Anim<Float> {
            if reducedMotion {
                return reducedFadeSeconds > 0
                    ? Anim<Float>.tween(duration: reducedFadeSeconds, easing: .easeInOut)
                    : .instant
            }
            if let fraction = fadeTailFraction {
                return Self.tailFade(spring: spring, fraction: fraction, open: open)
            }
            if open {
                return Anim<Float>.tween(duration: spring.duration * 0.5, easing: .easeOut)
            }
            return Anim<Float>.tween(duration: spring.duration * 0.35, easing: .easeIn)
        }

        private static func tailFade(spring: Spring, fraction: Float, open: Bool) -> Anim<Float> {
            let step: Float = 1.0 / 480.0
            if open {
                var t: Float = 0.0
                var x: Float = 0.0
                while x < fraction && t < 4.0 {
                    t += step
                    x = spring.sample(from: 0.0, velocity: 0.0, target: 1.0, at: t).position
                }
                return Anim<Float>.tween(duration: max(t, step), easing: .easeIn)
            }
            var t: Float = 0.0
            while spring.sample(from: 1.0, velocity: 0.0, target: 0.0, at: t).position > fraction && t < 4.0 {
                t += step
            }
            var lo = max(0.0, t - step)
            var hi = t
            for _ in 0..<24 {
                let mid = (lo + hi) * 0.5
                if spring.sample(from: 1.0, velocity: 0.0, target: 0.0, at: mid).position > fraction {
                    lo = mid
                } else {
                    hi = mid
                }
            }
            let v = spring.sample(from: 1.0, velocity: 0.0, target: 0.0, at: hi).velocity
            return Anim<Float>(spring: spring, delay: hi, velocityRule: .uniform(v / fraction))
        }
    }

    /// Hover-peek configuration for a closed sidebar (`rune_kit::shell::SidebarPeek`).
    public struct SidebarPeek: Sendable, Equatable {
        public var edgeWidth: Float
        public var edgeDelaySeconds: Double
        public var toggleDelaySeconds: Double
        public var belowY: Float?
        public var holdMargin: Float
        public var holdGraceSeconds: Double
        public var springOverride: Spring?
        public var reducedFadeSeconds: Float

        public static let off = SidebarPeek().edge(0, delay: 0)
        public static let hover = SidebarPeek()

        public static func edge(width: Float = 16) -> SidebarPeek {
            SidebarPeek().edge(width, delay: 0.05)
        }

        public init(
            edgeWidth: Float = 16.0,
            edgeDelaySeconds: Double = 0.05,
            toggleDelaySeconds: Double = 0.10,
            belowY: Float? = nil,
            holdMargin: Float = 12.0,
            holdGraceSeconds: Double = 0.15,
            springOverride: Spring? = nil,
            reducedFadeSeconds: Float = 0.15
        ) {
            self.edgeWidth = max(0.0, edgeWidth)
            self.edgeDelaySeconds = max(0.0, edgeDelaySeconds)
            self.toggleDelaySeconds = max(0.0, toggleDelaySeconds)
            self.belowY = belowY.map { max(0.0, $0) }
            self.holdMargin = max(0.0, holdMargin)
            self.holdGraceSeconds = max(0.0, holdGraceSeconds)
            self.springOverride = springOverride
            self.reducedFadeSeconds = max(0.0, reducedFadeSeconds)
        }

        public var isEnabled: Bool { edgeWidth > 0 }

        public func edge(_ width: Float, delay: Double) -> Self {
            var c = self
            c.edgeWidth = max(0.0, width)
            c.edgeDelaySeconds = max(0.0, delay)
            return c
        }

        public func toggleDelay(_ delay: Double) -> Self {
            var c = self
            c.toggleDelaySeconds = max(0.0, delay)
            return c
        }

        public func below(_ y: Float) -> Self {
            var c = self
            c.belowY = max(0.0, y)
            return c
        }

        public func hold(margin: Float, grace: Double) -> Self {
            var c = self
            c.holdMargin = max(0.0, margin)
            c.holdGraceSeconds = max(0.0, grace)
            return c
        }

        public func spring(_ s: Spring) -> Self {
            var c = self
            c.springOverride = s
            return c
        }

        public func reducedMotionFade(_ seconds: Float) -> Self {
            var c = self
            c.reducedFadeSeconds = max(0.0, seconds)
            return c
        }
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

    public func range(_ min: Float, _ max: Float) -> PaneState {
        range(min: min, max: max)
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

    public var isCollapsed: Bool { !isOpen }

    public var fromPeek: Bool {
        if case .open(let p) = dock { return p }
        return false
    }

    public var isPeeking: Bool {
        dock == .closedPeekShown
    }

    public var peekPhase: PeekPhase {
        switch dock {
        case .closedPeekShown: return .shown
        case .closedPeekLeft: return .left
        case .open, .closedRest: return .rest
        }
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
        askedWidth = width
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

    /// Drags the pane directly to `width`, collapsing when dragged below half `minWidth` (`pane::PaneState::drag_to`).
    public mutating func dragTo(width newWidth: Float) {
        guard newWidth.isFinite else { return }
        if newWidth < minWidth * 0.5 {
            setOpen(false)
        } else {
            setOpen(true)
            setWidth(newWidth)
        }
    }

    /// Applies a raw pointer delta against the currently held grip start (or a fresh start if idle).
    public mutating func dragTo(_ delta: Float, positiveGrows: Bool = true, collapseThreshold: Float = 80) {
        let start = grip.data ?? GripStart(width: width, open: isOpen)
        let signedDelta = positiveGrows ? delta : -delta
        let base = start.open ? start.width : 0
        let proposed = base + signedDelta
        if proposed < collapseThreshold {
            setOpen(false)
        } else {
            setOpen(true)
            setWidth(proposed)
        }
    }

    public mutating func pressGrip(at point: Vec2) {
        grip.press(GripStart(width: width, open: isOpen), at: point)
    }

    public mutating func dragGrip(
        deltaX: Float,
        at point: Vec2? = nil,
        positiveGrows: Bool = true,
        collapseThreshold: Float = 80
    ) {
        if let point {
            _ = grip.moved(to: point)
        }
        dragTo(deltaX, positiveGrows: positiveGrows, collapseThreshold: collapseThreshold)
    }

    public mutating func releaseGrip() {
        grip.release()
    }

    @discardableResult
    public mutating func pointerGrip(movedTo point: Vec2) -> Bool {
        grip.pointerMoved(to: point) != nil
    }

    public mutating func loseGrip() {
        grip.lose()
    }

    public mutating func beginResize(at point: Vec2? = nil) {
        grip.press(GripStart(width: width, open: isOpen), at: point)
    }

    public mutating func updateResize(deltaWidth: Float, collapseThreshold: Float = 80) {
        guard grip.data != nil else { return }
        dragTo(deltaWidth, positiveGrows: true, collapseThreshold: collapseThreshold)
    }

    public mutating func endResize() {
        grip.release()
    }

    public mutating func cancelResize() {
        guard let start = grip.release() else { return }
        width = start.width
        setOpen(start.open)
    }

    public mutating func resetWidth() {
        setWidth(defaultAskedWidth)
    }

    public mutating func resetToDefaultWidth() {
        resetWidth()
    }

    private mutating func clamp() {
        if width.isFinite {
            width = width.rounded().clamped(to: minWidth...maxWidth)
        } else {
            width = minWidth
        }
    }
}

public typealias PaneMotion = PaneState.PaneMotion
public typealias SidebarPeek = PaneState.SidebarPeek

/// Returns `true` when `(key, mods)` matches the standard sidebar toggle shortcut (`Shift+Cmd+B` or
/// `Ctrl+Cmd+S` on macOS, `Ctrl+Shift+B` off macOS).
public func isSidebarToggle(_ key: Key, mods: Mods, macOS: Bool = KeyPlatform.current == .mac) -> Bool {
    guard !mods.alt, !mods.logo || (macOS && mods.cmd) else { return false }
    let letter: String
    switch key {
    case .text(let s): letter = s.lowercased()
    case .command(let ch): letter = String(ch).lowercased()
    default: return false
    }
    let shiftB = letter == "b" && mods.shift && (macOS ? (mods.cmd && !mods.ctrl) : (mods.ctrl && !mods.cmd))
    let ctrlS = macOS && letter == "s" && mods.cmd && mods.ctrl && !mods.shift
    return shiftB || ctrlS
}

/// Drag-to-reorder state machine for vertical lists such as `SidebarRow` (`rune_kit::shell::Reorder`).
public struct Reorder<ID: Hashable & Sendable>: Sendable, Equatable {
    public static var slop: Float { 4.0 }

    public struct Held: Sendable, Equatable {
        public var id: ID
        public var startIndex: Int
        public var currentIndex: Int
        public var pressY: Float
        public var anchorY: Float
        public var lastY: Float
        public var pitch: Float
        public var crossedSlop: Bool
    }

    private var grip: Grip<Held> = .idle
    public private(set) var rowGap: Float = 0.0

    public init() {}

    /// Points between the rows (the list's gap), so a row steps aside by its height plus this (`Reorder::gap`).
    public func gap(_ points: Float) -> Self {
        var c = self
        c.rowGap = max(0.0, points)
        return c
    }

    public var isHeld: Bool { grip.isHeld }
    public var isDragging: Bool { grip.data?.crossedSlop ?? false }
    public var activeId: ID? { grip.data?.id }
    public var currentIndex: Int? { grip.data?.currentIndex }

    /// The row being dragged, by its index before the drag (`Reorder::dragging`).
    public func dragging() -> Int? {
        guard let h = grip.data, h.crossedSlop else { return nil }
        return h.startIndex
    }

    /// Where the dragged row would land if dropped now (`Reorder::target`).
    public func target() -> Int? {
        guard let h = grip.data, h.crossedSlop else { return nil }
        return h.currentIndex
    }

    public var draggingId: ID? {
        guard let h = grip.data, h.crossedSlop else { return nil }
        return h.id
    }

    /// Y displacement for the dragged row (`0` before crossing slop or when idle).
    public var offsetY: Float {
        guard let h = grip.data, h.crossedSlop else { return 0 }
        return h.lastY - h.anchorY
    }

    public func offsetY(for id: ID) -> Float {
        guard draggingId == id else { return 0 }
        return offsetY
    }

    /// How far row `index` sits from its place: the dragged row with the pointer, and the rows
    /// between its place and its target a step toward the gap it left (`Reorder::shift`).
    public func shift(forIndex index: Int) -> Float {
        guard let h = grip.data, h.crossedSlop else { return 0 }
        let from = h.startIndex
        let to = h.currentIndex
        let dy = h.lastY - h.anchorY
        if index == from {
            return dy
        } else if from < index && index <= to {
            return -h.pitch
        } else if to <= index && index < from {
            return h.pitch
        }
        return 0
    }

    public mutating func press(id: ID, index: Int, at point: Vec2) {
        grip.press(
            Held(
                id: id,
                startIndex: index,
                currentIndex: index,
                pressY: point.y,
                anchorY: point.y,
                lastY: point.y,
                pitch: 28.0 + rowGap,
                crossedSlop: false
            ),
            at: point
        )
    }

    /// Advances the drag to `point`, updating the target landing slot via `pitch = max(1, rowHeight + rowGap)`.
    /// Returns the landing `(from, to)` delta when the target slot changes, while deferring the committed list
    /// reorder to `end(cancelled:)`.
    @discardableResult
    public mutating func drag(
        to point: Vec2,
        rowHeight: Float = 28.0,
        count: Int
    ) -> (from: Int, to: Int)? {
        guard var held = grip.moved(to: point), count > 0, rowHeight > 0 else { return nil }
        let pitch = max(1.0, rowHeight + rowGap)
        held.pitch = pitch
        held.lastY = point.y
        if !held.crossedSlop {
            if abs(point.y - held.pressY) < Self.slop {
                grip.hold(held)
                return nil
            }
            held.crossedSlop = true
        }
        let deltaSlots = ((point.y - held.anchorY) / pitch).rounded()
        let nextIdx = (held.startIndex + Int(deltaSlots)).clamped(to: 0...(count - 1))
        let prevTarget = held.currentIndex
        held.currentIndex = nextIdx
        grip.hold(held)
        if nextIdx != prevTarget {
            return (from: prevTarget, to: nextIdx)
        }
        return nil
    }

    /// Ends the drag and returns `(from, to)` for a non-cancelled drop that moves a row (`Reorder::end`).
    @discardableResult
    public mutating func end(cancelled: Bool = false) -> (from: Int, to: Int)? {
        guard let held = grip.release() else { return nil }
        if !cancelled && held.crossedSlop && held.startIndex != held.currentIndex {
            return (from: held.startIndex, to: held.currentIndex)
        }
        return nil
    }

    @discardableResult
    public mutating func pointerMoved(to point: Vec2) -> Bool {
        grip.pointerMoved(to: point) != nil
    }

    public mutating func lose() {
        grip.lose()
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
