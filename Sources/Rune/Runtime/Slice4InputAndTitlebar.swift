import Foundation

// MARK: - Hover Delays (`runtime/input/hover_delay.rs`)

/// Where a delayed hover element's report stands (`hover_delay::Delayed`).
public enum KitHoverDelayPhase: Equatable, Sendable {
    /// The pointer is inside; enter is reported at `due` (clock seconds).
    case enterDue(due: Double)
    /// It heard the enter (`true`).
    case shown
    /// It heard the enter and the pointer left; leave is reported at `due`.
    case leaveDue(due: Double)
}

/// Event delivered to [`stepKitHoverDelayState`] (`hover_delay::Event`).
public enum KitHoverDelayEvent: Equatable, Sendable {
    case settle(inside: Bool, mayEnter: Bool, enterDelay: Double, leaveDelay: Double, now: Double)
    case due(now: Double)
    case pressed
    case ended
}

/// Effect emitted by [`stepKitHoverDelayState`] (`hover_delay::Effect`).
public enum KitHoverDelayEffect: Equatable, Sendable {
    case report(Bool)
    case wakeAt(Double)
}

/// Pure transition for one delayed hover element (`hover_delay::step`).
public func stepKitHoverDelayState(_ state: inout KitHoverDelayPhase?, _ event: KitHoverDelayEvent) -> [KitHoverDelayEffect] {
    let shown: Bool = switch state {
    case .shown, .leaveDue: true
    case .enterDue, nil: false
    }
    switch event {
    case .settle(let inside, let mayEnter, let enterDelay, let leaveDelay, let now):
        let want = inside && (shown || mayEnter)
        if want == shown {
            state = shown ? .shown : nil
            return []
        }
        switch state {
        case .enterDue, .leaveDue:
            return []
        case .shown, nil:
            break
        }
        let delay = want ? enterDelay : leaveDelay
        if delay <= 0.0 {
            state = want ? .shown : nil
            return [.report(want)]
        }
        let due = now + delay
        state = want ? .enterDue(due: due) : .leaveDue(due: due)
        return [.wakeAt(due)]

    case .due(let now):
        switch state {
        case .enterDue(let due) where due <= now:
            state = .shown
            return [.report(true)]
        case .leaveDue(let due) where due <= now:
            state = nil
            return [.report(false)]
        default:
            return []
        }

    case .pressed:
        if case .enterDue = state {
            state = nil
        }
        return []

    case .ended:
        state = nil
        return shown ? [.report(false)] : []
    }
}

/// Ordered collection of delayed hover reports by node path (`hover_delay::HoverDelays`).
/// Re-entered states move to the end so waits that expire together report in start order.
public struct KitHoverDelayList: Equatable, Sendable {
    public private(set) var entries: [(path: String, phase: KitHoverDelayPhase)] = []

    public init() {}

    public static func == (lhs: KitHoverDelayList, rhs: KitHoverDelayList) -> Bool {
        guard lhs.entries.count == rhs.entries.count else { return false }
        for (a, b) in zip(lhs.entries, rhs.entries) {
            if a.path != b.path || a.phase != b.phase { return false }
        }
        return true
    }

    public var isEmpty: Bool { entries.isEmpty }

    public var paths: [String] { entries.map(\.path) }

    public var waiting: Bool {
        entries.contains {
            switch $0.phase {
            case .enterDue, .leaveDue: return true
            case .shown: return false
            }
        }
    }

    public mutating func clear() {
        entries.removeAll()
    }

    /// Drops `path` silently and returns whether it had already heard its enter.
    @discardableResult
    public mutating func forget(_ path: String) -> Bool {
        guard let i = entries.firstIndex(where: { $0.path == path }) else { return false }
        let removed = entries.remove(at: i).phase
        switch removed {
        case .shown, .leaveDue: return true
        case .enterDue: return false
        }
    }

    public mutating func step(_ path: String, _ event: KitHoverDelayEvent) -> [KitHoverDelayEffect] {
        let at = entries.firstIndex(where: { $0.path == path })
        var phase: KitHoverDelayPhase? = at.map { entries[$0].phase }
        let effects = stepKitHoverDelayState(&phase, event)
        switch (at, phase) {
        case let (i?, s?) where entries[i].phase == s:
            break
        case let (i?, s):
            let keptPath = entries.remove(at: i).path
            if let s {
                entries.append((path: keptPath, phase: s))
            }
        case (nil, let s?):
            entries.append((path: path, phase: s))
        case (nil, nil):
            break
        }
        return effects
    }

    public func nextWakeDeadline(after now: Double) -> Double? {
        var best: Double? = nil
        for entry in entries {
            let due: Double? = switch entry.phase {
            case .enterDue(let d), .leaveDue(let d): d
            case .shown: nil
            }
            if let due, due > now {
                best = best.map { min($0, due) } ?? due
            }
        }
        return best
    }
}

// MARK: - Press Repeat (`runtime/input/press_repeat.rs`)

/// Monotonic generation token identifying one press-repeat arm (`machine::Attempt`).
public struct PressRepeatAttempt: Hashable, Sendable, Comparable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: PressRepeatAttempt, rhs: PressRepeatAttempt) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Generator of [`PressRepeatAttempt`] values (`machine::Seq`).
public struct PressRepeatSeq: Equatable, Sendable {
    private var nextValue: UInt64 = 1

    public init() {}

    public mutating func next() -> PressRepeatAttempt {
        let out = PressRepeatAttempt(nextValue)
        nextValue &+= 1
        return out
    }
}

/// State of an armed drag hold-repeat (`press_repeat::Repeat`).
public enum PressRepeatState: Equatable, Sendable {
    case idle
    case armed(attempt: PressRepeatAttempt, path: String, due: Double)

    public var attempt: PressRepeatAttempt? {
        switch self {
        case .armed(let attempt, _, _): return attempt
        case .idle: return nil
        }
    }
}

/// Event delivered to [`stepPressRepeat`] (`press_repeat::Event`).
public enum PressRepeatEvent: Equatable, Sendable {
    case arm(path: String, due: Double)
    case end
    case due(attempt: PressRepeatAttempt, now: Double)
}

/// Effect emitted by [`stepPressRepeat`] (`press_repeat::Effect`).
public enum PressRepeatEffect: Equatable, Sendable {
    case fire(String)
    case wakeAt(Double)
}

/// Pure transition for drag press-repeat (`press_repeat::step`).
public func stepPressRepeat(
    seq: inout PressRepeatSeq,
    state: inout PressRepeatState,
    event: PressRepeatEvent
) -> [PressRepeatEffect] {
    switch event {
    case .arm(let path, let due):
        let attempt = seq.next()
        state = .armed(attempt: attempt, path: path, due: due)
        return [.wakeAt(due)]
    case .end:
        state = .idle
        return []
    case .due(let attempt, let now):
        if case .armed(let armed, let path, let due) = state,
           armed == attempt,
           due <= now + 1e-6 {
            state = .idle
            return [.fire(path)]
        }
        return []
    }
}

/// Stateful press-repeat machine owned by `Runtime` (`press_repeat::PressRepeat`).
public struct PressRepeatMachine: Equatable, Sendable {
    public var seq = PressRepeatSeq()
    public var state: PressRepeatState = .idle

    public init() {}

    public mutating func step(_ event: PressRepeatEvent) -> [PressRepeatEffect] {
        stepPressRepeat(seq: &seq, state: &state, event: event)
    }

    public var attempt: PressRepeatAttempt? { state.attempt }

    public func waiting(at now: Double) -> Bool {
        if case .armed(_, _, let due) = state {
            return now + 1e-6 < due
        }
        return false
    }

    public func nextWakeDeadline(after now: Double) -> Double? {
        if case .armed(_, _, let due) = state, due > now {
            return due
        }
        return nil
    }
}

// MARK: - Titlebar Press & Window Menu (`runtime/input/titlebar.rs`)

/// Where a custom titlebar asks the host to open its system window menu (`titlebar::WindowMenu`).
public enum WindowMenu: Equatable, Sendable {
    case pointer
    case keyboard
}

/// Headless/platform caption button chrome state (`crate::titlebar::Caption`).
public struct TitlebarCaption: Equatable, Sendable {
    public var height: Float
    public var hidden: Bool
    public var mirrored: Bool
    public var maximized: Bool
    public var minimizable: Bool
    public var maximizable: Bool
    public var state: TitlebarCaptionState

    public init(height: Float, hidden: Bool = false, mirrored: Bool = RuneLabels.shared.isRTL,
                maximized: Bool = false, minimizable: Bool = true, maximizable: Bool = true,
                state: TitlebarCaptionState = .idle) {
        self.height = height
        self.hidden = hidden
        self.mirrored = mirrored
        self.maximized = maximized
        self.minimizable = minimizable
        self.maximizable = maximizable
        self.state = state
    }
}

/// First press in a potential titlebar double-click pair (`titlebar::Pair`).
public struct TitlebarPair: Equatable, Sendable {
    public var at: Double
    public var point: Vec2

    public init(at: Double, point: Vec2) {
        self.at = at
        self.point = point
    }

    /// True when a press at `point` and `now` pairs with this press within `interval` and 4pt per-axis slop.
    public func second(now: Double, point: Vec2, interval: Double) -> Bool {
        (now - at) <= interval
            && abs(point.x - self.point.x) <= 4.0
            && abs(point.y - self.point.y) <= 4.0
    }
}

/// State of the titlebar primary-pair and secondary-menu press machine (`titlebar::TitlebarPress`).
public enum TitlebarPressState: Equatable, Sendable {
    case rest
    case armed(TitlebarPair)
    case secondaryOnRegion(TitlebarPair?)

    public var secondaryArmed: Bool {
        if case .secondaryOnRegion = self { return true }
        return false
    }
}

/// Event delivered to [`stepTitlebar`] (`titlebar::Event`).
public enum TitlebarEvent: Equatable, Sendable {
    case region(now: Double, point: Vec2, interval: Double)
    case empty(now: Double, point: Vec2, interval: Double, band: Bool)
    case secondaryDown(region: Bool)
    case secondaryUp(region: Bool)
    case clear
}

/// Request emitted by [`stepTitlebar`] (`titlebar::Request`).
public enum TitlebarRequest: Equatable, Sendable {
    case action(TitlebarAction)
    case menu
}

private func titlebarPairOf(
    _ last: TitlebarPair?,
    now: Double,
    point: Vec2,
    interval: Double
) -> (TitlebarPair?, Bool) {
    if let last, last.second(now: now, point: point, interval: interval) {
        return (nil, true)
    }
    return (TitlebarPair(at: now, point: point), false)
}

private func titlebarCurrentPair(_ state: TitlebarPressState) -> TitlebarPair? {
    switch state {
    case .rest: return nil
    case .armed(let pair): return pair
    case .secondaryOnRegion(let pair): return pair
    }
}

private func titlebarArmed(_ pair: TitlebarPair?) -> TitlebarPressState {
    pair.map { .armed($0) } ?? .rest
}

private func titlebarKeepSecondary(_ state: TitlebarPressState, _ pair: TitlebarPair?) -> TitlebarPressState {
    state.secondaryArmed ? .secondaryOnRegion(pair) : titlebarArmed(pair)
}

/// Pure transition for titlebar presses and custom-titlebar window menu opening (`titlebar::step`).
public func stepTitlebar(_ state: inout TitlebarPressState, _ event: TitlebarEvent) -> [TitlebarRequest] {
    switch event {
    case .region(let now, let point, let interval):
        let (next, double) = titlebarPairOf(titlebarCurrentPair(state), now: now, point: point, interval: interval)
        state = titlebarKeepSecondary(state, next)
        return [.action(double ? .doubleClick : .drag)]

    case .empty(let now, let point, let interval, let band):
        guard band else { return [] }
        let (next, double) = titlebarPairOf(titlebarCurrentPair(state), now: now, point: point, interval: interval)
        state = titlebarKeepSecondary(state, next)
        return double ? [.action(.doubleClick)] : []

    case .secondaryDown(let region):
        let pair = titlebarCurrentPair(state)
        state = region ? .secondaryOnRegion(pair) : titlebarArmed(pair)
        return []

    case .secondaryUp(let region):
        guard case .secondaryOnRegion(let pair) = state else { return [] }
        state = titlebarArmed(pair)
        return region ? [.menu] : []

    case .clear:
        state = .rest
        return []
    }
}

/// Titlebar runtime sub-state (`titlebar::Titlebar`).
public struct TitlebarMachine: Equatable, Sendable {
    public var action: TitlebarAction? = nil
    public var press: TitlebarPressState = .rest
    public var nativeBand: Float = 0.0
    public var windowMenu: WindowMenu? = nil
    public var caption: TitlebarCaption? = nil
    internal var headlessWindowsTitlebar: Titlebar?

    public init() {}

    public mutating func pressRegion(now: Double, x: Float, y: Float, interval: Double) {
        act(.region(now: now, point: Vec2(x, y), interval: interval))
    }

    public mutating func pressEmpty(now: Double, x: Float, y: Float, interval: Double) {
        let band = y < nativeBand
        act(.empty(now: now, point: Vec2(x, y), interval: interval, band: band))
    }

    public mutating func clear() {
        act(.clear)
    }

    public mutating func act(_ event: TitlebarEvent) {
        for request in stepTitlebar(&press, event) {
            switch request {
            case .action(let titlebarAction):
                action = titlebarAction
            case .menu:
                windowMenu = .pointer
            }
        }
    }
}

// MARK: - Runtime Titlebar & Focus-Cancellation APIs

extension Runtime {
    /// Double-click pairing interval in seconds used by titlebar presses (`Runtime::double_click_interval`).
    public var doubleClickInterval: Double {
        get { kitHooks.doubleClickInterval }
        set { kitHooks.doubleClickInterval = newValue }
    }

    /// Window points from the top dragged natively by the system (`Runtime::set_native_titlebar_band`).
    public func setNativeTitlebarBand(_ points: Float) {
        kitHooks.titlebar.nativeBand = points
    }

    /// Sets headless/custom caption button chrome (`Runtime::set_caption`).
    public func setCaption(_ caption: TitlebarCaption?) {
        guard kitHooks.titlebar.caption != caption else { return }
        kitHooks.titlebar.caption = caption
        needsCommit = true
        // titlebar.rs:225: `set_caption` marks the state dirty.
        commitWhyPending |= CommitWhy.dirty
    }

    /// Returns and clears the pending window menu request (`Runtime::take_window_menu`).
    public func takeWindowMenu() -> WindowMenu? {
        defer { kitHooks.titlebar.windowMenu = nil }
        return kitHooks.titlebar.windowMenu
    }

    /// Clears pending titlebar press state (`Titlebar::clear`).
    internal func clearTitlebarPress() {
        kitHooks.titlebar.clear()
    }

    /// Handles a primary press that hit no interactive target (`Runtime::pointer_down` bare drag / empty band).
    internal func recordTitlebarPressOnMiss(at pos: Vec2, button: PointerButton, now: Double) {
        guard button == .primary else { return }
        if isBareTitlebarDragRegion(at: pos) {
            kitHooks.titlebar.pressRegion(now: now, x: pos.x, y: pos.y, interval: kitHooks.doubleClickInterval)
        } else {
            kitHooks.titlebar.pressEmpty(now: now, x: pos.x, y: pos.y, interval: kitHooks.doubleClickInterval)
        }
    }

    /// Records secondary button down against bare `.windowDrag()` regions when custom caption chrome is active.
    internal func recordSecondaryTitlebarDown(at pos: Vec2, captured: Bool) {
        let region = !captured && kitHooks.titlebar.caption != nil && isBareTitlebarDragRegion(at: pos)
        kitHooks.titlebar.act(.secondaryDown(region: region))
    }

    /// Records secondary button up against bare `.windowDrag()` regions (`titlebar::secondary_region_up`).
    internal func recordSecondaryTitlebarUp(at pos: Vec2) {
        guard kitHooks.titlebar.press.secondaryArmed else { return }
        let region = isBareTitlebarDragRegion(at: pos)
        kitHooks.titlebar.act(.secondaryUp(region: region))
    }

    /// Returns whether a secondary press at `pos` hits a text input or non-empty selectable text.
    internal func isSecondaryTextOrInputHit(at pos: Vec2) -> Bool {
        guard let hit = hitTest(at: pos) else { return false }
        let n = hit.node
        if n.el.handlers.editLens != nil { return true }
        if n.el.isSelectable {
            return !(n.el.plainText ?? "").isEmpty || !(n.el.richSpans?.isEmpty ?? true)
        }
        return false
    }

    /// Cancels pointer press/drag/titlebar state on window focus loss (`Runtime::cancel_pointer`),
    /// returning `true` if a live pointer/drag change requested a view commit.
    @discardableResult
    internal func cancelPointerForFocusLoss(at now: Double) -> Bool {
        slice2State.autoscroll.cancel()
        var didMarkDirty = false
        kitHooks.titlebar.clear()
        primaryPointerHeld = false
        secondaryPointerHeld = false
        armedDragOut = nil
        endKitPressRepeat()

        if let drag = activeDrag {
            activeDrag = nil
            if !drag.isTextSelectionDrag,
               let idx = nodeByPath[drag.path],
               let onEnd = flatNodes[idx].el.handlers.onDragEnd {
                var tx = makeTx(at: now, button: drag.button)
                onEnd(&state, true, &tx)
                applyTx(tx, at: now)
            }
            dirtyCommit(at: now)
            didMarkDirty = true
        }
        if selectionState.isDraggingSelection || selectionState.edgeScroll != .idle {
            selectionState.isDraggingSelection = false
            selectionState.suppressedClickOnRelease = false
            selectionState.edgeScroll.stop()
            selectionState.coordinator.phase.endDrag()
            dirtyCommit(at: now, external: false)
            dispatchSelectionChanges(at: now)
            didMarkDirty = true
        }
        if pressedPath != nil || pressedKey != nil || pressedLink != nil || pressedTint != nil {
            pressedPath = nil
            pressedKey = nil
            pressedLink = nil
            pressedTint = nil
            pressedPointerInside = false
            syncPressScale(at: cxSettings.scaledTime(at: now), cut: false)
            dirtyCommit(at: now)
            didMarkDirty = true
        }
        if hoveredLink != nil {
            hoveredLink = nil
            dirtyCommit(at: now)
            didMarkDirty = true
        }
        if let old = hoveredPath {
            hoveredPath = nil
            hoveredKey = nil
            if let idx = nodeByPath[old], !flatNodes[idx].el.hasKitHoverDelays,
               let cb = flatNodes[idx].el.handlers.onHover {
                var tx = makeTx(at: now)
                cb(&state, false, &tx)
                applyTx(tx, at: now)
            }
            dirtyCommit(at: now)
            didMarkDirty = true
        }
        pointerPosition = Vec2(-10000, -10000)
        return didMarkDirty
    }
}
