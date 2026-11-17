import Foundation
import RuneMotion
import RuneRef
#if canImport(simd)
import simd
#endif

/// Mouse / pointer button (`rune::PointerButton`).
public enum PointerButton: String, Sendable, Hashable, Codable {
    case primary
    case secondary
    case middle
    case back
    case forward
}

/// Gesture phase (`rune::Phase`).
public enum GesturePhase: String, Sendable, Hashable, Codable {
    case began
    case changed
    case ended
    case cancelled
}

/// Pointer press coordinates in window and element-local space (`rune::PointerPress`).
public struct PointerPress: Sendable, Equatable {
    public var window: Vec2
    public var local: Vec2
    public var elementSize: Vec2
    public var button: PointerButton
    public var mods: Mods
    public var clicks: Int

    public init(
        window: Vec2,
        local: Vec2,
        elementSize: Vec2,
        button: PointerButton = .primary,
        mods: Mods = .none,
        clicks: Int = 1
    ) {
        self.window = window
        self.local = local
        self.elementSize = elementSize
        self.button = button
        self.mods = mods
        self.clicks = clicks
    }
}

/// Element-local pointer coordinates for `onPointerMoveLocal` / `onSecondaryPressLocal` (`rune::PointerEvent`).
public struct PointerEvent: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var windowX: Float
    public var windowY: Float

    public init(x: Float = 0, y: Float = 0, windowX: Float = 0, windowY: Float = 0) {
        self.x = x
        self.y = y
        self.windowX = windowX
        self.windowY = windowY
    }

    /// Window-space coordinates matching `PointerPress` (`PointerEvent::window`).
    public func window() -> PointerPress {
        PointerPress(
            window: Vec2(windowX, windowY),
            local: Vec2(x, y),
            elementSize: .zero
        )
    }
}

/// Phase of a pointer drag gesture (`crates/rune/src/el/mod.rs` `Phase`).
public enum DragPhase: String, Sendable, Equatable, Hashable {
    case down
    case move
    case up
}

/// Drag event payload delivered to `onDrag` (`rune::Drag`).
public struct Drag: Sendable, Equatable {
    /// Current pointer position in window points.
    public var window: Vec2
    /// Current pointer position relative to the dragged element's top-left origin.
    public var local: Vec2
    /// Total displacement `(window - startWindow)` since pointer-down.
    public var delta: Vec2
    /// Initial pointer-down position relative to element origin.
    public var startLocal: Vec2
    /// Dragged element's `(width, height)`.
    public var size: Vec2
    /// Click count on press (`1` = normal drag, `2` = double-click-and-drag word selection).
    public var clicks: Int
    public var mods: Mods
    /// Phase of this drag callback (`.down`, `.move`, `.up`).
    public var phase: DragPhase
    /// Whether the gesture ended cancelled (Escape / focus loss / taken away, `Drag::cancelled`).
    public var isCancelled: Bool
    /// Pointer in desktop pixels when hosted in a native window (`Drag::screen_point`).
    public var screen: (Int32, Int32)?

    public init(
        window: Vec2,
        local: Vec2,
        delta: Vec2,
        startLocal: Vec2,
        size: Vec2,
        clicks: Int = 1,
        mods: Mods = .none,
        phase: DragPhase = .move,
        isCancelled: Bool = false,
        screen: (Int32, Int32)? = nil
    ) {
        self.window = window
        self.local = local
        self.delta = delta
        self.startLocal = startLocal
        self.size = size
        self.clicks = clicks
        self.mods = mods
        self.phase = phase
        self.isCancelled = isCancelled
        self.screen = screen
    }

    public static func == (lhs: Drag, rhs: Drag) -> Bool {
        lhs.window == rhs.window
            && lhs.local == rhs.local
            && lhs.delta == rhs.delta
            && lhs.startLocal == rhs.startLocal
            && lhs.size == rhs.size
            && lhs.clicks == rhs.clicks
            && lhs.mods == rhs.mods
            && lhs.phase == rhs.phase
            && lhs.isCancelled == rhs.isCancelled
            && lhs.screen?.0 == rhs.screen?.0
            && lhs.screen?.1 == rhs.screen?.1
    }

    /// True on gesture termination when aborted without a drop (`Drag::cancelled`).
    public func cancelled() -> Bool {
        isCancelled
    }

    /// Pointer coordinates from the window's top-left (`Drag::window_point`).
    public func windowPoint() -> [Float] {
        [window.x, window.y]
    }

    /// Pointer in physical desktop pixels when hosted natively (`Drag::screen_point`).
    public func screenPoint() -> (Int32, Int32)? {
        screen
    }
}

/// Wheel / trackpad scroll event (`rune::WheelEvent`).
public struct WheelEvent: Sendable, Equatable {
    public var dx: Float
    public var dy: Float
    public var precise: Bool
    public var phase: GesturePhase
    public var mods: Mods
    public var momentum: Bool
    public var x: Float
    public var y: Float

    public init(
        dx: Float = 0,
        dy: Float = 0,
        precise: Bool = true,
        phase: GesturePhase = .changed,
        mods: Mods = .none,
        momentum: Bool = false,
        x: Float = 0,
        y: Float = 0
    ) {
        self.dx = dx
        self.dy = dy
        self.precise = precise
        self.phase = phase
        self.mods = mods
        self.momentum = momentum
        self.x = x
        self.y = y
    }
}

/// Trackpad pinch magnification event (`rune::MagnifyEvent`).
public struct MagnifyEvent: Sendable, Equatable {
    /// Change in magnification (`scale = 1.0 + delta`); positive zooms in.
    public var delta: Float
    /// Pointer x in element-local layout points (before `liveScale` transforms).
    public var x: Float
    /// Pointer y in element-local layout points.
    public var y: Float
    public var phase: GesturePhase

    public init(delta: Float = 0, x: Float = 0, y: Float = 0, phase: GesturePhase = .changed) {
        self.delta = delta
        self.x = x
        self.y = y
        self.phase = phase
    }
}

/// Two-finger trackpad rotation event (`rune::RotateEvent`).
public struct RotateEvent: Sendable, Equatable {
    /// Degrees turned since last event (positive counterclockwise).
    public var degrees: Float
    public var x: Float
    public var y: Float
    public var phase: GesturePhase

    public init(degrees: Float = 0, x: Float = 0, y: Float = 0, phase: GesturePhase = .changed) {
        self.degrees = degrees
        self.x = x
        self.y = y
        self.phase = phase
    }
}

internal struct TxPickRead {
    let within: String?
    let x: Float
    let y: Float
    let pick: Pick
    let invoke: (_ stateBox: inout Any, _ picked: Picked?, _ tx: inout Tx) -> Bool
}

/// Transaction handle passed into every event handler (`rune::Tx`).
public struct Tx {
    public internal(set) var liveOnlyRequested: Bool = false
    public internal(set) var commitKind: TxCommit = .animate
    public internal(set) var motionSource: MotionSource? = nil
    public internal(set) var followEdgeRequested: Bool = false
    public internal(set) var askedMotion: Bool = false
    internal var liveTail = LiveTailRequests()
    public internal(set) var unprompted: Bool = false
    public internal(set) var colorMotionSpring: Spring? = nil
    public internal(set) var clock: Double = 0.0
    public internal(set) var button: PointerButton = .primary
    public internal(set) var mods: Mods = .none
    public internal(set) var physicalKeyCode: PhysicalKeyCode? = nil
    public internal(set) var isKeyRepeat: Bool = false
    public internal(set) var focusedElementKey: String? = nil
    public internal(set) var pasteRequested: Bool = false

    /// Physical key that produced this key event, if any (`Tx::physical_key`).
    public func physicalKey() -> PhysicalKeyCode? { physicalKeyCode ?? physicalKeyValue }

    /// True while a held key auto-repeats (`Tx::key_repeat`).
    public func keyRepeat() -> Bool { isKeyRepeat || keyRepeatValue }

    /// The currently focused element's key (or `"#<index>"` if unkeyed), if any (`Tx::focused`).
    public func focused() -> String? { focusedElementKey }

    public internal(set) var settleRequested: Bool {
        get { commitKind.snaps }
        set { commitKind = newValue ? .settle : .animate }
    }

    public internal(set) var requestedFocusKey: String? = nil
    public internal(set) var requestedFocusVisible: Bool = true
    public internal(set) var focusAskedByReturn: Bool = false
    /// The focus ask is `Tx.focusWhenShown` (`FocusAsk::WhenShown`): it waits for its element.
    public internal(set) var focusAskedWhenShown: Bool = false
    public internal(set) var blurFocusRequested: Bool = false
    public internal(set) var clipboardWrite: ClipboardContent? = nil
    public var scrollToRequests: [(key: String, offset: Vec2, animated: Bool)] {
        scrollOffsetRequests.compactMap { req in
            guard !req.anchor, let x = req.x, let y = req.y else { return nil }
            return (req.key, Vec2(x, y), req.glide != nil)
        }
    }
    public internal(set) var scrollRevealRequests: [ScrollRevealRequest] = []
    public internal(set) var scrollBottomRequests: [(key: String, animated: Bool)] = []
    public internal(set) var scrollPageRequests: [(key: String, pages: Int)] = []
    public internal(set) var scrollOffsetRequests: [ScrollOffsetRequest] = []
    public internal(set) var keepOnScreenKeys: [String] = []
    public internal(set) var invalidateMemoPrefixes: [String] = []
    public internal(set) var windowTitle: String? = nil
    public internal(set) var quitRequested: Bool = false
    public internal(set) var textFlights: [(source: String, destination: String)] = []
    public internal(set) var launches: [(source: String, destination: String)] = []
    public internal(set) var unclippedFlightsRequested: Bool = false
    public internal(set) var focusVisibleAtEvent: Bool = false
    public internal(set) var byKeysAtEvent: Bool = false
    public internal(set) var assistiveTechnologyActive: Bool = false
    public internal(set) var eventInputTime: Double? = nil
    /// `Tx.inputWaiting` (`Tx::input_waiting`): set only on the poll transaction.
    internal var isInputWaiting: Bool = false
    public internal(set) var sentKeys: [KeyEvent] = []
    public internal(set) var toggleMaximizedRequested: Bool = false
    public internal(set) var toggleFullScreenRequested: Bool = false
    public internal(set) var announcement: (text: String, politeness: LiveRegionPoliteness)? = nil
    public internal(set) var shortcutActivationToken: String? = nil
    internal var minimizeOrder: UInt64? = nil
    internal var pickReads: [TxPickRead] = []
    /// `Tx.readClipboard` callbacks (`Tx::clipboard_reads`).
    internal var clipboardReads: [TxClipboardRead] = []
    internal var runtimeActions: [String: Any] = [:]

    public init() {}

    /// Declares that this handler only updated `Live<T>` sources and does NOT need a view rebuild
    /// or layout pass on this frame!
    public mutating func liveOnly() {
        liveOnlyRequested = true
    }

    /// Reverts `liveOnlyRequested` when a handler declines an event (`Tx::took`).
    @discardableResult
    public static func took(_ taken: Bool, _ tx: inout Tx) -> Bool {
        if !taken { tx.liveOnlyRequested = false }
        return taken
    }

    /// Applies this change at once (snaps its own layout) while leaving other running tracks alone.
    public mutating func instant() {
        commitKind = commitKind.instant()
    }

    /// Animates this change even where the runtime would otherwise snap, preserving any `settle()` land flag.
    public mutating func animated() {
        commitKind = commitKind.animated()
        askedMotion = true
    }

    /// Cuts all animations created by this state commit and lands every running track.
    public mutating func settle() {
        commitKind = .settle
    }

    /// Lands every running track while allowing this change's own layout to animate.
    public mutating func settleAnimated() {
        commitKind = .settleAnimated
    }

    /// Animates this change's layout using `spring`.
    public mutating func motion(_ spring: Spring) {
        motionSource = .spring(spring)
    }

    /// Animates this change's layout using `anim` (spring or eased tween).
    public mutating func motionCurve(_ anim: Anim<Float>) {
        motionSource = .fromAnim(anim)
    }

    /// Animates this change's layout using `curve`.
    public mutating func motionCurve(_ curve: Curve, delay: Float = 0) {
        motionSource = .fromAnim(Anim<Float>(curve: curve, delay: delay))
    }

    /// Rows pinned to a `stickBottom` viewport's bottom ride its edge through this change (`Tx::follow_edge`).
    public mutating func followEdge() {
        followEdgeRequested = true
    }

    /// Animates this change's color transitions with `spring`.
    public mutating func colorMotion(_ spring: Spring) {
        colorMotionSpring = spring
    }

    /// Requests a wake deadline `seconds` from now (`Tx::wake_after`).
    public mutating func wakeAfter(_ seconds: Double) {
        let clamped = max(0.0, seconds)
        if let existing = runtimeActions["wakeAfter"] as? Double {
            runtimeActions["wakeAfter"] = min(existing, clamped)
        } else {
            runtimeActions["wakeAfter"] = clamped
        }
        var list = (runtimeActions["wakeAfterList"] as? [Double]) ?? []
        list.append(clamped)
        runtimeActions["wakeAfterList"] = list
    }

    internal var physicalKeyValue: PhysicalKeyCode? = nil
    internal var keyBaseValue: Character? = nil
    internal var keyRepeatValue: Bool = false
    internal var tracingEnabled: Bool = false
    internal var traceEvents: [String] = []
    internal var traceChannels: [(name: String, kind: TraceChannels.Kind, value: Float)] = []

    /// Unmodified base character for the current key/key-up handler (`Tx::key_base`).
    public func keyBase() -> Character? { keyBaseValue }

    /// Whether this runtime has an attached motion or tooling trace (`Tx::tracing`).
    public var tracing: Bool { tracingEnabled }

    /// Appends a trace event marker on the next traced frame (`Tx::trace_event`).
    public mutating func traceEvent(_ event: @autoclosure () -> String) {
        guard tracingEnabled else { return }
        traceEvents.append(event())
    }

    /// Records a sample-and-hold scalar trace channel (`Tx::trace_channel`).
    public mutating func traceChannel(_ name: String, kind: TraceChannels.Kind, value: Float) {
        guard tracingEnabled else { return }
        traceChannels.append((name, kind, value))
    }

    /// String-kind convenience overload matching Rust `"position"`, `"level"`, `"phase"`.
    public mutating func traceChannel(_ name: String, kind: String, value: Float) {
        guard tracingEnabled, let parsed = TraceChannels.Kind(rawValue: kind) else { return }
        traceChannels.append((name, parsed, value))
    }

    /// Positional convenience overload for `traceChannel(_:kind:value:)`.
    public mutating func traceChannel(_ name: String, _ kind: String, _ value: Float) {
        traceChannel(name, kind: kind, value: value)
    }

    /// Requests a wake once the logical `clock` reaches `due` (`Tx::wake_at`).
    public mutating func wakeAt(_ due: Double) {
        wakeAfter(max(0.0, due - clock))
    }

    /// Evicts memoized subtrees whose keys begin with `prefix` (`Tx::invalidate_memos_by_prefix`).
    public mutating func invalidateMemosByPrefix(_ prefix: String) {
        invalidateMemoPrefixes.append(prefix)
    }

    /// Moves keyboard focus to the element with `.key(targetKey)`.
    public mutating func focus(_ targetKey: String) {
        requestedFocusKey = targetKey
        requestedFocusVisible = true
        focusAskedByReturn = false
        focusAskedWhenShown = false
        blurFocusRequested = false
    }

    /// Clears keyboard focus.
    public mutating func blur() {
        blurFocusRequested = true
        // A `Tx.focusWhenShown` stands apart from the blur, as upstream's `focus_to` does.
        if !focusAskedWhenShown { requestedFocusKey = nil }
    }

    /// Copies text to the system / headless clipboard.
    public mutating func copyText(_ text: String) {
        clipboardWrite = ClipboardContent(text)
        runtimeActions[txSecretCopyKey] = nil
    }

    /// Requests a paste delivery into the focused editor or `onPaste`/`onPasteContent` handler (`Tx::request_paste`).
    public mutating func requestPaste() {
        pasteRequested = true
    }

    /// Scrolls the scroll container `.key(key)` to `offset`.
    public mutating func scrollTo(_ key: String, offset: Vec2, animated: Bool = true) {
        scrollOffsetRequests.append(
            ScrollOffsetRequest(
                key: key,
                x: offset.x,
                y: offset.y,
                glide: animated ? MotionTokens.GLIDE : nil,
                anchor: false
            )
        )
    }

    /// Reveals a keyed element (including an unrealized virtual row) in its scroll viewports.
    public mutating func scrollIntoView(_ key: String) {
        scrollRevealRequests.append(.intoView(scope: nil, key: key))
    }

    /// Reveals `key` inside `scope` only.
    public mutating func scrollIntoViewIn(_ scope: String, _ key: String) {
        scrollRevealRequests.append(.intoView(scope: scope, key: key))
    }

    /// Reveals and vertically centers a keyed element or highlight.
    public mutating func scrollCenter(_ key: String) {
        scrollRevealRequests.append(.center(scope: nil, key: key, animated: true))
    }

    /// Vertically centers `key` inside `scope` only.
    public mutating func scrollCenterIn(_ scope: String, _ key: String) {
        scrollRevealRequests.append(.center(scope: scope, key: key, animated: true))
    }

    /// Instantly centers `key` inside `scope` only.
    public mutating func scrollCenterInInstant(_ scope: String, _ key: String) {
        scrollRevealRequests.append(.center(scope: scope, key: key, animated: false))
    }

    /// Glides the scroll viewport `key` (or nearest enclosing one) to its bottom.
    public mutating func scrollToBottom(_ key: String) {
        scrollBottomRequests.append((key, true))
    }

    /// Instantly jumps the scroll viewport `key` (or nearest enclosing one) to its bottom.
    public mutating func scrollToBottomInstant(_ key: String) {
        scrollBottomRequests.append((key, false))
    }

    /// Pages the scroll viewport `key` by `pages` pages (90% of viewport height per page).
    public mutating func scrollPage(_ key: String, _ pages: Int) {
        scrollPageRequests.append((key, pages))
    }

    /// Instantly moves the horizontal scroll viewport `key` to `x`.
    public mutating func scrollToX(_ key: String, _ x: Float) {
        scrollOffsetRequests.append(ScrollOffsetRequest(key: key, x: x, y: nil, glide: nil, anchor: false))
    }

    /// Instantly moves the vertical scroll viewport `key` to `y`.
    public mutating func scrollToY(_ key: String, _ y: Float) {
        scrollOffsetRequests.append(ScrollOffsetRequest(key: key, x: nil, y: y, glide: nil, anchor: false))
    }

    /// Glides the scroll viewport `key` to `(x, y)` using `MotionTokens.GLIDE`.
    public mutating func scrollTo(_ key: String, x: Float, y: Float) {
        scrollOffsetRequests.append(ScrollOffsetRequest(key: key, x: x, y: y, glide: MotionTokens.GLIDE, anchor: false))
    }

    /// Glides the scroll viewport `key` to `(x, y)` using `spring`.
    public mutating func scrollToWith(_ key: String, x: Float, y: Float, spring: Spring) {
        scrollOffsetRequests.append(ScrollOffsetRequest(key: key, x: x, y: y, glide: spring, anchor: false))
    }

    /// Instantly moves the scroll viewport `key` to `(x, y)`.
    public mutating func scrollToInstant(_ key: String, x: Float, y: Float) {
        scrollOffsetRequests.append(ScrollOffsetRequest(key: key, x: x, y: y, glide: nil, anchor: false))
    }

    /// Moves the vertical scroll viewport around `key` so its top sits `at` points below the viewport top.
    /// Instant; any momentum or glide stops. A virtual row that isn't mounted lands too: the jump
    /// goes where its list's estimates put it, which mounts it, and is placed again from its layout
    /// before the frame draws, the rows it mounts there showing at once.
    /// Pass `"row/mark"` to land a descendant element or text highlight, including one in an unmounted virtual row.
    public mutating func scrollKeyTo(_ key: String, at: Float) {
        scrollOffsetRequests.append(ScrollOffsetRequest(key: key, x: nil, y: at, glide: nil, anchor: true))
    }

    /// Holds the top edge of `key` in its drawn screen position across this commit.
    public mutating func keepOnScreen(_ key: String) {
        keepOnScreenKeys.append(key)
    }

    /// Merges another handler's transaction intent into `self` (`runtime/input/action.rs::merge`).
    public mutating func merge(_ one: Tx) {
        scrollRevealRequests.append(contentsOf: one.scrollRevealRequests)
        scrollBottomRequests.append(contentsOf: one.scrollBottomRequests)
        scrollPageRequests.append(contentsOf: one.scrollPageRequests)
        scrollOffsetRequests.append(contentsOf: one.scrollOffsetRequests)
        keepOnScreenKeys.append(contentsOf: one.keepOnScreenKeys)
        invalidateMemoPrefixes.append(contentsOf: one.invalidateMemoPrefixes)
        textFlights.append(contentsOf: one.textFlights)
        launches.append(contentsOf: one.launches)
        unclippedFlightsRequested = unclippedFlightsRequested || one.unclippedFlightsRequested
        if let cb = one.clipboardWrite {
            clipboardWrite = cb
            runtimeActions[txSecretCopyKey] = nil
        }
        if one.runtimeActions[txSecretCopyKey] != nil {
            clipboardWrite = nil
            runtimeActions["richClipboardWrite"] = nil
        }
        pasteRequested = pasteRequested || one.pasteRequested
        if let title = one.windowTitle { windowTitle = title }
        quitRequested = quitRequested || one.quitRequested
        blurFocusRequested = blurFocusRequested || one.blurFocusRequested
        if let fk = one.requestedFocusKey {
            if !one.focusAskedByReturn || requestedFocusKey == nil || focusAskedByReturn {
                requestedFocusKey = fk
                requestedFocusVisible = one.requestedFocusVisible
                focusAskedByReturn = one.focusAskedByReturn
                focusAskedWhenShown = one.focusAskedWhenShown
            }
        }
        sentKeys.append(contentsOf: one.sentKeys)
        toggleMaximizedRequested = toggleMaximizedRequested || one.toggleMaximizedRequested
        toggleFullScreenRequested = toggleFullScreenRequested || one.toggleFullScreenRequested
        if let otherMinimizeOrder = one.minimizeOrder {
            minimizeOrder = max(minimizeOrder ?? 0, otherMinimizeOrder)
        }
        pickReads.append(contentsOf: one.pickReads)
        clipboardReads.append(contentsOf: one.clipboardReads)
        traceEvents.append(contentsOf: one.traceEvents)
        traceChannels.append(contentsOf: one.traceChannels)
        if let ann = one.announcement { announcement = ann }
        if let wakeList = one.runtimeActions["wakeAfterList"] as? [Double] {
            for wake in wakeList {
                wakeAfter(wake)
            }
        } else if let wake = one.runtimeActions["wakeAfter"] as? Double {
            wakeAfter(wake)
        }
        for (k, v) in one.runtimeActions where k != "wakeAfter" && k != "wakeAfterList" {
            switch k {
            case Tx.sentKeysKey:
                var existing = (runtimeActions[k] as? [KeyEvent]) ?? []
                if let added = v as? [KeyEvent] {
                    existing.append(contentsOf: added)
                }
                runtimeActions[k] = existing
            case Tx.traceEventsKey:
                var existing = (runtimeActions[k] as? [String]) ?? []
                if let added = v as? [String] {
                    existing.append(contentsOf: added)
                }
                runtimeActions[k] = existing
            case Tx.traceChannelsKey:
                var existing = (runtimeActions[k] as? [TraceChannelRecord]) ?? []
                if let added = v as? [TraceChannelRecord] {
                    existing.append(contentsOf: added)
                }
                runtimeActions[k] = existing
            case Tx.shellKey:
                if let incoming = v as? Shell {
                    if let cur = runtimeActions[k] as? Shell, cur > incoming {
                        break
                    }
                    runtimeActions[k] = incoming
                }
            default:
                runtimeActions[k] = v
            }
        }
        commitKind = commitKind.merge(one.commitKind)
        followEdgeRequested = followEdgeRequested || one.followEdgeRequested
        liveTail.merge(one.liveTail)
        askedMotion = askedMotion || one.askedMotion
        if let m = one.motionSource { motionSource = m }
        if let cm = one.colorMotionSpring { colorMotionSpring = cm }
    }

    public mutating func setTitle(_ title: String) {
        windowTitle = title
    }

    public mutating func quit() {
        quitRequested = true
    }

    public mutating func flyText(_ source: String, to destination: String) {
        textFlights.append((source, destination))
    }

    public mutating func launch(_ source: String, to destination: String) {
        launches.append((source, destination))
    }

    public mutating func unclippedFlights() {
        unclippedFlightsRequested = true
    }

    /// Returns focus to `targetKey` (showing ring when `visible` is true) unless an explicit `.focus(...)` won this turn.
    public mutating func returnFocus(_ targetKey: String, visible: Bool = true) {
        if requestedFocusKey == nil || focusAskedByReturn {
            requestedFocusKey = targetKey
            requestedFocusVisible = visible
            focusAskedByReturn = true
            focusAskedWhenShown = false
            blurFocusRequested = false
        }
    }

    /// Whether keyboard focus was showing its ring (`:focus-visible`) when this event arrived.
    public func focusVisible() -> Bool { focusVisibleAtEvent }

    /// Whether assistive technology (e.g. VoiceOver) is active (`Tx::assistive_technology`).
    public func assistiveTechnology() -> Bool { assistiveTechnologyActive }

    /// Event input timestamp in seconds (`Tx::input_time`).
    public func inputTime() -> Double? { eventInputTime }

    /// Whether this drag callback is a scheduled `dragRepeatAfter` tick (`Tx::drag_repeat`).
    public func dragRepeat() -> Bool { isDragRepeat }

    /// Dispatches a synthetic `KeyEvent` after the current handler completes (`Tx::send_key`).
    public mutating func sendKey(_ ev: KeyEvent) {
        sentKeys.append(ev)
    }

    /// Requests toggling the window's maximized/zoomed state (`Tx::toggle_maximized`).
    public mutating func toggleMaximized() {
        toggleMaximizedRequested = true
    }

    /// Requests toggling the window's native full-screen state (`Tx::toggle_full_screen`).
    public mutating func toggleFullScreen() {
        toggleFullScreenRequested = true
    }

    /// Posts an accessibility live-region announcement (`Tx::announce`).
    public mutating func announce(_ text: String, _ politeness: LiveRegionPoliteness = .polite) {
        announcement = (text, politeness)
    }

    /// Requests opening `url` in the system browser (`Tx::open_url` Swift-case alias).
    public mutating func openURL(_ url: String) throws {
        try openUrl(url, sameTab: false)
    }

    /// Requests opening `url` in the same web tab (`Tx::open_url_same_tab` Swift-case alias).
    public mutating func openURLSameTab(_ url: String) throws {
        try openUrlSameTab(url)
    }

    /// Activation token provided by the desktop portal (e.g. Wayland) during a global shortcut callback (`Tx::activation_token`).
    public func activationToken() -> String? {
        shortcutActivationToken
    }

    /// Reads the topmost element at window point `(x, y)` after this handler completes (`Tx::element_at`).
    public mutating func elementAt<S>(
        _ x: Float,
        _ y: Float,
        _ body: @escaping (_ state: inout S, _ picked: Picked?, _ tx: inout Tx) -> Void
    ) {
        elementAtWith(x, y, pick: .default, body)
    }

    /// Reads the topmost element at `(x, y)` with `Pick` options (`Tx::element_at_with`).
    public mutating func elementAtWith<S>(
        _ x: Float,
        _ y: Float,
        pick: Pick,
        _ body: @escaping (_ state: inout S, _ picked: Picked?, _ tx: inout Tx) -> Void
    ) {
        enqueuePickRead(within: nil, x: x, y: y, pick: pick, body)
    }

    /// Reads the topmost element at `(x, y)` restricted to `within` (`Tx::element_at_in`).
    public mutating func elementAtIn<S>(
        _ within: String,
        x: Float,
        y: Float,
        _ body: @escaping (_ state: inout S, _ picked: Picked?, _ tx: inout Tx) -> Void
    ) {
        elementAtInWith(within, x: x, y: y, pick: .default, body)
    }

    /// Reads the topmost element at `(x, y)` restricted to `within` with `Pick` options (`Tx::element_at_in_with`).
    public mutating func elementAtInWith<S>(
        _ within: String,
        x: Float,
        y: Float,
        pick: Pick,
        _ body: @escaping (_ state: inout S, _ picked: Picked?, _ tx: inout Tx) -> Void
    ) {
        enqueuePickRead(within: within, x: x, y: y, pick: pick, body)
    }

    private mutating func enqueuePickRead<S>(
        within: String?,
        x: Float,
        y: Float,
        pick: Pick,
        _ body: @escaping (_ state: inout S, _ picked: Picked?, _ tx: inout Tx) -> Void
    ) {
        pickReads.append(TxPickRead(within: within, x: x, y: y, pick: pick) { stateBox, picked, tx in
            guard var typed = stateBox as? S else { return false }
            body(&typed, picked, &tx)
            stateBox = typed
            return true
        })
    }
}

/// Read-only view-building context (`rune::Cx`).
public struct Cx<State> {
    private var _viewport: Vec2
    public internal(set) var viewport: Vec2 {
        get {
            layoutCollector.viewportRead = true
            return _viewport
        }
        set {
            _viewport = newValue
        }
    }
    public internal(set) var pixelScale: Float
    public internal(set) var systemDark: Bool
    public internal(set) var reducedMotion: Bool
    public let windowFocused: Bool
    public let focusedKey: String?
    public let hoveredKey: String?
    public let pressedKey: String?
    public let waker: Waker
    public var helpLook: HelpLook?
    internal let scrollLookup: (String) -> Vec2
    internal let scrollMaxLookup: (String) -> Vec2
    internal let viewportSizeLookup: (String) -> Vec2
    internal let contentSizeLookup: (String) -> Vec2
    internal let layoutRectLookup: (String) -> MotionRect?
    internal var envState = CxEnvironmentState()
    internal let layoutCollector: LayoutReadCollector

    public init(
        viewport: Vec2,
        pixelScale: Float = 2.0,
        systemDark: Bool = true,
        reducedMotion: Bool = false,
        windowFocused: Bool = true,
        focusedKey: String? = nil,
        hoveredKey: String? = nil,
        pressedKey: String? = nil,
        waker: Waker = Waker(),
        helpLook: HelpLook? = nil,
        scrollLookup: @escaping (String) -> Vec2 = { _ in .zero },
        scrollMaxLookup: @escaping (String) -> Vec2 = { _ in .zero },
        viewportSizeLookup: @escaping (String) -> Vec2 = { _ in .zero },
        contentSizeLookup: @escaping (String) -> Vec2 = { _ in .zero },
        layoutRectLookup: @escaping (String) -> MotionRect? = { _ in nil }
    ) {
        self._viewport = viewport
        self.pixelScale = pixelScale
        self.systemDark = systemDark
        self.reducedMotion = reducedMotion
        self.windowFocused = windowFocused
        self.focusedKey = focusedKey
        self.hoveredKey = hoveredKey
        self.pressedKey = pressedKey
        self.waker = waker
        self.helpLook = helpLook
        self.scrollLookup = scrollLookup
        self.scrollMaxLookup = scrollMaxLookup
        self.viewportSizeLookup = viewportSizeLookup
        self.contentSizeLookup = contentSizeLookup
        self.layoutRectLookup = layoutRectLookup
        self.layoutCollector = LayoutReadCollector()
    }

    internal init(
        viewport: Vec2,
        pixelScale: Float,
        systemDark: Bool,
        reducedMotion: Bool,
        windowFocused: Bool,
        focusedKey: String?,
        hoveredKey: String?,
        pressedKey: String?,
        waker: Waker,
        helpLook: HelpLook? = nil,
        scrollLookup: @escaping (String) -> Vec2,
        scrollMaxLookup: @escaping (String) -> Vec2 = { _ in .zero },
        viewportSizeLookup: @escaping (String) -> Vec2 = { _ in .zero },
        contentSizeLookup: @escaping (String) -> Vec2 = { _ in .zero },
        layoutRectLookup: @escaping (String) -> MotionRect? = { _ in nil },
        layoutCollector: LayoutReadCollector
    ) {
        self._viewport = viewport
        self.pixelScale = pixelScale
        self.systemDark = systemDark
        self.reducedMotion = reducedMotion
        self.windowFocused = windowFocused
        self.focusedKey = focusedKey
        self.hoveredKey = hoveredKey
        self.pressedKey = pressedKey
        self.waker = waker
        self.helpLook = helpLook
        self.scrollLookup = scrollLookup
        self.scrollMaxLookup = scrollMaxLookup
        self.viewportSizeLookup = viewportSizeLookup
        self.contentSizeLookup = contentSizeLookup
        self.layoutRectLookup = layoutRectLookup
        self.layoutCollector = layoutCollector
    }

    public func isFocused(_ key: String) -> Bool {
        focusedKey == key
    }

    public func isHovered(_ key: String) -> Bool {
        hoveredKey == key
    }

    public func isPressed(_ key: String) -> Bool {
        pressedKey == key
    }

    public func scrollOffset(of key: String) -> Vec2 {
        scrollLookup(key)
    }
    public func scrollMax(of key: String) -> Vec2 {
        scrollMaxLookup(key)
    }

    public func viewportSize(of key: String) -> Vec2 {
        viewportSizeLookup(key)
    }

    public func contentSize(of key: String) -> Vec2 {
        contentSizeLookup(key)
    }

    public func layoutRect(of key: String) -> MotionRect? {
        layoutRectLookup(key)
    }

    public func layoutSize(of key: String) -> Vec2? {
        guard let r = layoutRectLookup(key) else { return nil }
        return Vec2(r.width, r.height)
    }

    public mutating func setHelpLook(_ look: HelpLook) {
        helpLook = look
        envState.defaults.help = look
    }
}

/// Accessibility / semantic role tag (`rune::RoleTag`).
public enum ElementRole: String, Sendable, Hashable, Codable {
    case group = "group"
    case text = "text"
    case button = "button"
    case checkbox = "checkbox"
    case switchControl = "switch"
    case radio = "radio"
    case tab = "tab"
    case textInput = "textbox"
    case slider = "slider"
    case progress = "progressbar"
    case listItem = "listitem"
    case heading = "heading"
    case dialog = "dialog"
    case menuBar = "menubar"
    case menu = "menu"
    case menuItem = "menuitem"
    case image = "img"
    case icon = "icon"
    case separator = "separator"
    case combobox = "combobox"
    case listbox = "listbox"
    case option = "option"
    case tree = "tree"
    case treeItem = "treeitem"
    case grid = "grid"
    case row = "row"
    case gridCell = "gridcell"
    case columnHeader = "columnheader"
    case radiogroup = "radiogroup"
    case tabList = "tablist"
    case tooltip = "tooltip"
    case alert = "alert"
    case region = "region"
    case main = "main"
    case link = "link"
    case toolbar = "toolbar"
    case splitter = "splitter"
    case status = "status"
    case list = "list"
    case menuItemCheckbox = "menu-item-check-box"
    case menuItemRadio = "menu-item-radio"
    case passwordInput = "password-input"
    case multilineTextInput = "multiline-text-input"
    case mark = "mark"
    case code = "code"
    case blockquote = "blockquote"
    case table = "table"
}

/// Live property binding entry attached to an `El`.
struct BoundLiveProperty: Sendable {
    enum Target: Sendable, Hashable {
        case opacity
        case scale
        case blur
        case offset
        case fill
        case rect
        case trim
        case textColor
        case borderColor
        case shadowColor
        case gradientTop
        case gradientBottom
    }

    var target: Target
    var source: LiveSource
    var spring: Spring?
    var restSpring: Spring?
}

/// Type-erased event handlers parameterized on app `State`.
public struct ElementHandlers<State> {
    public var onClick: ((inout State, inout Tx) -> Void)?
    public var onClickPress: ((inout State, PointerPress, inout Tx) -> Void)?
    public var onDoubleClick: ((inout State, inout Tx) -> Void)?
    public var onSecondaryClick: ((inout State, PointerPress, inout Tx) -> Void)?
    public var onMiddlePress: ((inout State, inout Tx) -> Void)?
    public var onPointerDown: ((inout State, PointerPress, inout Tx) -> Void)?
    public var onPointerUp: ((inout State, PointerPress, inout Tx) -> Void)?
    public var onPointerMove: ((inout State, PointerPress, inout Tx) -> Void)?
    public var onHover: ((inout State, Bool, inout Tx) -> Void)?
    public var onHoverChange: ((inout State, Bool, inout Tx) -> Void)?
    public var hoverDelay: (enter: Float, leave: Float) = (0, 0)
    public var onDrag: ((inout State, Drag, inout Tx) -> Void)?
    public var onDragEnd: ((inout State, Bool, inout Tx) -> Void)?
    public var drop: DropSpec<State>?
    public var dragOut: ((State) -> DragItem?)?
    public var dragThreshold: Float?
    /// `El.touchDragsAtOnce` (`Handlers::touch_at_once`).
    public var touchAtOnce: Bool = false
    public var pressOnDown: Bool = false
    public var onDragStart: ((inout State, inout Tx) -> Void)?
    public var onDragOutEnd: ((inout State, DragOutcome, inout Tx) -> Void)?
    public var onKey: ((inout State, KeyEvent, inout Tx) -> Bool)?
    public var onKeyUp: ((inout State, KeyEvent, inout Tx) -> Bool)?
    public var onPhysicalInput: ((inout State, PhysicalInput, inout Tx) -> Bool)?
    public var onWheel: ((inout State, WheelEvent, inout Tx) -> Bool)?
    public var onMagnify: ((inout State, MagnifyEvent, inout Tx) -> Bool)?
    public var onRotate: ((inout State, RotateEvent, inout Tx) -> Bool)?
    public var onSmartMagnify: ((inout State, Float, Float, inout Tx) -> Bool)?
    public var pointerButtons: Set<PointerButton>?

    /// Mutable projection into `State` for `textInput` elements!
    public var editLens: (get: (State) -> TextEdit, set: (inout State, TextEdit) -> Void)?
    public var onInputKey: ((inout State, KeyEvent, inout Tx) -> Bool)?
    public var onTextChange: ((inout State, String, inout Tx) -> Void)?
    public var onTextSubmit: ((inout State, String, inout Tx) -> Void)?
    public var onLink: ((inout State, String, inout Tx) -> Void)?
    public var onLinkSecondary: ((inout State, String, PointerPress, inout Tx) -> Void)?
    public var modalDismiss: ((inout State, inout Tx) -> Void)?
    public var onStep: ((inout State, Int, inout Tx) -> Void)?
    public var onStepLimit: ((inout State, Bool, inout Tx) -> Void)?

    internal var atBottomReport: ((inout State, Bool) -> Bool)?
    internal var farFromBottomReport: (min: Float, frameKey: String?, handler: (inout State, Bool) -> Bool)?

    public var onAtBottom: ((inout State, Bool) -> Void)? {
        get { atBottomReport.map { report in { state, at in _ = report(&state, at) } } }
        set { atBottomReport = newValue.map { handler in { state, at in handler(&state, at); return true } } }
    }

    public var onFarFromBottom: (min: Float, frameKey: String?, handler: (inout State, Bool) -> Void)? {
        get { farFromBottomReport.map { spec in
            (spec.min, spec.frameKey, { state, far in _ = spec.handler(&state, far) })
        } }
        set { farFromBottomReport = newValue.map { spec in
            (spec.min, spec.frameKey, { state, far in spec.handler(&state, far); return true })
        } }
    }
    public var onScrollOffset: ((ScrollPos) -> Void)?
    public var onScroll: ((inout State, ScrollPos, inout Tx) -> Void)?
    public var onScrollOffsetToken: UInt64 = 0
    public var onVisibleRows: ((inout State, Range<Int>) -> Bool)?
    public var onDrawnLayout: ((inout State, [Float], inout Tx) -> Void)?
    public var onVisible: ((inout State, Bool, inout Tx) -> Void)?
    public var onPaste: ((inout State, String, inout Tx) -> Void)?
    public var onPasteContent: ((inout State, ClipboardContent, inout Tx) -> Void)?
    public var onInputPaste: ((inout State, ClipboardContent, inout Tx) -> Bool)?
    public var onLayout: ((inout State, [Float], inout Tx) -> Void)?
    public var onScreenLayout: ((inout State, [Float], inout Tx) -> Void)?
    public var drawnRectUpdate: ((MotionRect) -> Bool)?
    public var onBackgroundPress: ((inout State, PointerPress, inout Tx) -> Void)?
    public var onInputChange: ((inout State, String, inout Tx) -> Bool)?
    public var onSpellcheckEnabled: Bool? = nil
    public var onSpellcheck: ((inout State, Bool, inout Tx) -> Void)?
    public var onSpellcheckLanguages: ((inout State, [String], inout Tx) -> Void)?

    public init() {}
}

final class ElColdData<State> {
    var pixelSnapEnabled: Bool = true
    var clipRadius: Float? = nil
    var clipCorners: Corners? = nil
    var clipFade: SIMD4<Float>? = nil
    var scrollEdgeFadeWidth: Float = 0
    var scrollFadeStyle: ScrollFadeStyle = .smooth
    var scrollMarginPts: Float = 0
    var scrollAnchorEnabled: Bool = false
    var stickyConfig: StickyConfig? = nil
    var growthSpec: GrowthSpec? = nil
    var isStreaming: Bool = false
    var isArrivesWhole: Bool = false
    var joinedRowFaceKey: String?
    var growthReveal: GrowthReveal?
    var textReveal: Float = -1.0
    var foldGlideSpec: FoldGlide? = nil
    var virtualEstimate: Float? = nil
    var virtualRowsSource: VirtualRowSource<State>? = nil
    var virtualRowsVersion: UInt64? = nil
    var focusSelected: Bool = false
    var revealSelected: Bool = false

    var hoverBg: Color? = nil
    var pressBg: Color? = nil
    var pressColor: Color? = nil
    var pressScaleFactor: Float? = nil
    var isHoverGroup: Bool = false
    var hoverGroupShare: String? = nil
    var isHoverAlone: Bool = false
    var hoverMotion: (enter: Anim<Float>, exit: Anim<Float>)? = nil
    var hoverWithin: (enter: Anim<Float>, exit: Anim<Float>)? = nil
    var groupOpacity: (rest: Float, hovered: Float)? = nil
    var groupColor: Color? = nil
    var isDissolve: Bool = false
    var drawnRectLive: Live<MotionRect>? = nil
    var focusRingColor: Color? = nil
    var focusRingWidth: Float = 2.0
    var focusRingOffset: Float = 2.0
    var focusReturnKey: String? = nil
    var modalClickOutside: Bool = false
    var tabIndex: Int? = nil
    var isDefaultButton: Bool = false
    var noFocusRing: Bool = false
    var focusRequested: Bool = false
    var focusHighlightColor: Color? = nil
    var focusWithinRing: (width: Float, offset: Float, color: Color)? = nil
    var focusWithinFlat: Bool = false
    var focusFollows: Bool = false

    var a11yLabelStorage: CowText? = nil
    var a11yHelp: String? = nil
    var helpWhenTruncated: Bool = false
    var helpSide: Side? = nil
    var a11ySelected: String? = nil
    var a11yExpanded: Bool? = nil
    var a11yLevel: Int? = nil
    var itemSelected: Bool = false
    var a11yDescriptionStorage: CowText? = nil
    var a11yValue: String? = nil
    var a11yRange: A11yRange? = nil
    var a11yChecked: A11yChecked? = nil
    var a11yDisabled: Bool = false
    var isA11yHidden: Bool = false
    var a11yActiveDescendant: String? = nil
    var a11yLabelledByStorage: CowText? = nil
    var a11yDescribedByStorage: CowText? = nil
    var a11yBusy: Bool = false
    var a11yInvalid: Bool = false
    var a11yReadOnly: Bool = false
    var a11ySorted: Bool? = nil
    var a11yLive: LiveRegionPoliteness? = nil
    var a11yPosInSet: (position: Int, size: Int)? = nil
    var a11yShortcutHint: String? = nil
    var a11yHref: String? = nil

    var richSpans: [TextSpan]? = nil
    var textHighlights: [TextHighlight]? = nil
    var textLinks: [TextLink]? = nil
    var liveText: LiveText? = nil
    var placeholder: String? = nil
    var placeholderColor: Color? = nil
    var placeholderFontBox: AnyObject? = nil
    var outsideListDiscFontBox: AnyObject? = nil
    var wrapGreedy: Bool = false
    var caretColor: Color? = nil
    var selectionColor: Color? = nil
    var iconPayload: (SVGIcon, Float)? = nil
    var imagePayload: RGBA8Atlas? = nil
    var pixelsPayload: Pixels? = nil
    var pixelsFitMode: SurfaceFit? = nil
    var surfacePayload: (surface: NativeSurface, fit: SurfaceFit)? = nil
    var surfacePlace: SurfacePlace = .centered
    var gradient: Gradient? = nil
    var borderSides: Sides? = nil
    var dashedBorder: (dash: Float, gap: Float, phase: Float)? = nil

    var anchor: Anchor? = nil
    var layoutAnim: LayoutAnim? = nil
    var styleSpring: Spring? = nil
    var transition: Transition? = nil
    var enterDelay: Float = 0
    var hasInstantChanges: Bool = false
    var hasAnimatedChanges: Bool = false
    var loopingSpec: LoopSpec? = nil
    var flightId: String? = nil
    var flightCrop: Bool = false
    var flightSpring: Spring? = nil
    var terminalGridPayload: TerminalGrid? = nil
    var explicitDir: Direction? = nil
    var isUnmirrored: Bool = false
    var mirrorInRtl: Bool = false
    var textDirByParagraph: Bool = false
    var focusFillColor: Color? = nil
    var pressFocusesBelow: Bool = false
    var noWindowDrag: Bool = false
    var isImeCursor: Bool = false
    var optionAsAlt: Bool = false
    var spellcheck: Bool = false
    var richStyle: RichStyle? = nil
    var pillColors: (bg: Color, fg: Color?)? = nil
    var pillIconLookup: ((String) -> SVGIcon?)? = nil
    var pillStyleLookup: ((String) -> PillStyle)? = nil
    var isSingleLineInput: Bool = false
    var editAccessWithheld: Bool = false
    var animateEditLayoutEnabled: Bool = false
    var isIconOneColor: Bool = false
    var iconRotation: Float = 0.0
    var isWidthLeads: Bool = false
    var holdLandingWidthEnabled: Bool = false
    var paintContain: Vec2? = nil
    var motionSnapsEnabled: Bool = false
    var isRaised: Bool = false
    var offsetMotionAnim: Anim<Vec2>? = nil
    var opacityMotionAnim: Anim<Float>? = nil
    var scaleMotionAnim: Anim<Vec2>? = nil
    var rotateMotionAnim: Anim<Float>? = nil
    var textCaseValue: TextCase? = nil
    var spanRings: [(range: Range<Int>, color: Color, width: Float)]? = nil
    var advanceInRun: (run: TextRun, byteOffset: Int)? = nil
    var isTruncateFadeEnabled: Bool = false
    var truncateFadeEm: Float = 1.5
    var isolates: [(range: Range<Int>, dir: Direction)]? = nil
    var liveBindings: [BoundLiveProperty]? = nil
    var handlersBox: ElHandlersBox<State>? = nil
    private var _runtimeExtras: [String: Any]? = nil
    var runtimeExtras: [String: Any] {
        get { _runtimeExtras ?? [:] }
        set { _runtimeExtras = newValue.isEmpty ? nil : newValue }
        _modify {
            var dict = _runtimeExtras ?? [:]
            _runtimeExtras = nil
            defer { _runtimeExtras = dict.isEmpty ? nil : dict }
            yield &dict
        }
    }
    var keyLocation: String? = nil

    func clone() -> ElColdData<State> {
        let c = ElColdData<State>()
        copyPaintAndMotionFields(to: c)
        copyFocusAndA11yFields(to: c)
        copyTextAndMediaFields(to: c)
        copyStyleAndHandlerFields(to: c)
        return c
    }

    @inline(never)
    private func copyPaintAndMotionFields(to c: ElColdData<State>) {
        c.pixelSnapEnabled = pixelSnapEnabled
        c.clipRadius = clipRadius
        c.clipCorners = clipCorners
        c.clipFade = clipFade
        c.scrollEdgeFadeWidth = scrollEdgeFadeWidth
        c.scrollFadeStyle = scrollFadeStyle
        c.scrollMarginPts = scrollMarginPts
        c.scrollAnchorEnabled = scrollAnchorEnabled
        c.stickyConfig = stickyConfig
        c.growthSpec = growthSpec
        c.isStreaming = isStreaming
        c.isArrivesWhole = isArrivesWhole
        c.joinedRowFaceKey = joinedRowFaceKey
        c.growthReveal = growthReveal
        c.foldGlideSpec = foldGlideSpec
        c.virtualEstimate = virtualEstimate
        c.virtualRowsSource = virtualRowsSource
        c.virtualRowsVersion = virtualRowsVersion
        c.focusSelected = focusSelected
        c.revealSelected = revealSelected
        c.hoverBg = hoverBg
        c.pressBg = pressBg
        c.pressColor = pressColor
        c.pressScaleFactor = pressScaleFactor
        c.isHoverGroup = isHoverGroup
        c.hoverGroupShare = hoverGroupShare
        c.isHoverAlone = isHoverAlone
        c.hoverMotion = hoverMotion
        c.hoverWithin = hoverWithin
        c.groupOpacity = groupOpacity
        c.groupColor = groupColor
        c.isDissolve = isDissolve
        c.drawnRectLive = drawnRectLive
    }

    @inline(never)
    private func copyFocusAndA11yFields(to c: ElColdData<State>) {
        c.focusRingColor = focusRingColor
        c.focusRingWidth = focusRingWidth
        c.focusRingOffset = focusRingOffset
        c.focusReturnKey = focusReturnKey
        c.modalClickOutside = modalClickOutside
        c.tabIndex = tabIndex
        c.isDefaultButton = isDefaultButton
        c.noFocusRing = noFocusRing
        c.focusRequested = focusRequested
        c.focusHighlightColor = focusHighlightColor
        c.focusWithinRing = focusWithinRing
        c.focusWithinFlat = focusWithinFlat
        c.focusFollows = focusFollows
        c.a11yLabelStorage = a11yLabelStorage
        c.a11yHelp = a11yHelp
        c.helpWhenTruncated = helpWhenTruncated
        c.helpSide = helpSide
        c.a11ySelected = a11ySelected
        c.a11yExpanded = a11yExpanded
        c.a11yLevel = a11yLevel
        c.itemSelected = itemSelected
        c.a11yDescriptionStorage = a11yDescriptionStorage
        c.a11yValue = a11yValue
        c.a11yRange = a11yRange
        c.a11yChecked = a11yChecked
        c.a11yDisabled = a11yDisabled
        c.isA11yHidden = isA11yHidden
        c.a11yActiveDescendant = a11yActiveDescendant
        c.a11yLabelledByStorage = a11yLabelledByStorage
        c.a11yDescribedByStorage = a11yDescribedByStorage
        c.a11yBusy = a11yBusy
        c.a11yInvalid = a11yInvalid
        c.a11yReadOnly = a11yReadOnly
        c.a11ySorted = a11ySorted
        c.a11yLive = a11yLive
        c.a11yPosInSet = a11yPosInSet
        c.a11yShortcutHint = a11yShortcutHint
        c.a11yHref = a11yHref
    }

    @inline(never)
    private func copyTextAndMediaFields(to c: ElColdData<State>) {
        c.richSpans = richSpans
        c.textHighlights = textHighlights
        c.textLinks = textLinks
        c.liveText = liveText
        c.placeholder = placeholder
        c.placeholderColor = placeholderColor
        c.placeholderFontBox = placeholderFontBox
        c.outsideListDiscFontBox = outsideListDiscFontBox
        c.wrapGreedy = wrapGreedy
        c.caretColor = caretColor
        c.selectionColor = selectionColor
        c.iconPayload = iconPayload
        c.imagePayload = imagePayload
        c.pixelsPayload = pixelsPayload
        c.pixelsFitMode = pixelsFitMode
        c.surfacePayload = surfacePayload
        c.surfacePlace = surfacePlace
        c.gradient = gradient
        c.borderSides = borderSides
        c.dashedBorder = dashedBorder
        c.anchor = anchor
        c.layoutAnim = layoutAnim
        c.styleSpring = styleSpring
        c.transition = transition
        c.enterDelay = enterDelay
        c.hasInstantChanges = hasInstantChanges
        c.hasAnimatedChanges = hasAnimatedChanges
        c.loopingSpec = loopingSpec
        c.flightId = flightId
        c.flightCrop = flightCrop
        c.flightSpring = flightSpring
        c.terminalGridPayload = terminalGridPayload
        c.explicitDir = explicitDir
        c.isUnmirrored = isUnmirrored
        c.mirrorInRtl = mirrorInRtl
        c.textDirByParagraph = textDirByParagraph
    }

    @inline(never)
    private func copyStyleAndHandlerFields(to c: ElColdData<State>) {
        c.focusFillColor = focusFillColor
        c.pressFocusesBelow = pressFocusesBelow
        c.noWindowDrag = noWindowDrag
        c.isImeCursor = isImeCursor
        c.optionAsAlt = optionAsAlt
        c.spellcheck = spellcheck
        c.richStyle = richStyle
        c.pillColors = pillColors
        c.pillIconLookup = pillIconLookup
        c.pillStyleLookup = pillStyleLookup
        c.isSingleLineInput = isSingleLineInput
        c.editAccessWithheld = editAccessWithheld
        c.animateEditLayoutEnabled = animateEditLayoutEnabled
        c.isIconOneColor = isIconOneColor
        c.iconRotation = iconRotation
        c.isWidthLeads = isWidthLeads
        c.holdLandingWidthEnabled = holdLandingWidthEnabled
        c.paintContain = paintContain
        c.motionSnapsEnabled = motionSnapsEnabled
        c.isRaised = isRaised
        c.offsetMotionAnim = offsetMotionAnim
        c.opacityMotionAnim = opacityMotionAnim
        c.scaleMotionAnim = scaleMotionAnim
        c.rotateMotionAnim = rotateMotionAnim
        c.textCaseValue = textCaseValue
        c.spanRings = spanRings
        c.advanceInRun = advanceInRun
        c.isTruncateFadeEnabled = isTruncateFadeEnabled
        c.truncateFadeEm = truncateFadeEm
        c.isolates = isolates
        c.liveBindings = liveBindings
        c.handlersBox = handlersBox.map { ElHandlersBox($0.value) }
        c._runtimeExtras = _runtimeExtras
        c.keyLocation = keyLocation
    }
}

final class ElHandlersBox<State> {
    var value: ElementHandlers<State>
    init(_ value: ElementHandlers<State>) {
        self.value = value
    }
}

final class ElColdBox<State> {
    let data: ElColdData<State>
    init(_ data: ElColdData<State> = ElColdData<State>()) {
        self.data = data
    }
}

/// Declarative UI element returned from pure view functions `(State, inout Cx<State>) -> El<State>`.
public struct El<State> {
    private var _cold: ElColdBox<State>? = nil

    private mutating func ensureCold() -> ElColdBox<State> {
        if _cold == nil {
            _cold = ElColdBox(ElColdData<State>())
        } else if !isKnownUniquelyReferenced(&_cold) {
            _cold = ElColdBox(_cold!.data.clone())
        }
        return _cold!
    }

    public var keyId: String? = nil
    public var role: ElementRole = .group
    internal var memoRegionReused: Bool = false
    internal var memoRegionEnvHash: UInt64 = 0
    public var layout: LayoutStyle
    public var children: [El<State>] = []

    // Hot content & visual styling
    public var plainText: String? = nil
    public var textStyle: TextStyle = TextStyle()
    public var textColor: Color? = nil
    public var shapes: [Shape] = []
    public var background: Color = .transparent
    public var borderColor: Color = .transparent
    public var borderWidth: Float = 0
    public var corners: Corners = .all(0)
    public var shadows: [Shadow] = []
    public var opacity: Float = 1.0
    public var scale: Vec2 = Vec2(1, 1)
    public var rotate: Float = 0
    public var origin: Vec2 = Vec2(0.5, 0.5)
    public var offset: Vec2 = .zero
    public var blur: Float = 0
    public var backdropBlur: Float = 0
    public var zIndex: Int = 0
    public var isolatedLayer: Bool = false
    public var focusable: Bool = false
    public var focusOptOut: Bool = false
    public var autofocus: Bool = false
    public var focusGroup: Bool = false
    public var isModal: Bool = false
    public var isInert: Bool = false
    public var isHit: Bool = false
    public var explicitHit: Bool { get { isHit } set { isHit = newValue } }
    public var isSecure: Bool = false
    public var revealedOverride: Bool? = nil
    public var isRevealed: Bool {
        get { revealedOverride ?? false }
        set { revealedOverride = newValue }
    }

    // Cold / CoW properties (keeps `El<State>` compact on worker thread stacks)
    public var richSpans: [TextSpan]? { get { _cold?.data.richSpans } set { ensureCold().data.richSpans = newValue } }
    public var textHighlights: [TextHighlight]? { get { _cold?.data.textHighlights } set { ensureCold().data.textHighlights = newValue } }
    public var textLinks: [TextLink] {
        get { _cold?.data.textLinks ?? [] }
        set { ensureCold().data.textLinks = newValue.isEmpty ? nil : newValue }
    }
    public var liveText: LiveText? { get { _cold?.data.liveText } set { ensureCold().data.liveText = newValue } }
    public var placeholder: String? { get { _cold?.data.placeholder } set { ensureCold().data.placeholder = newValue } }
    public var placeholderColor: Color? { get { _cold?.data.placeholderColor } set { ensureCold().data.placeholderColor = newValue } }
    private final class FontStyleBox: @unchecked Sendable {
        let style: TextStyle
        init(_ style: TextStyle) { self.style = style }
    }
    public var placeholderFont: TextStyle? {
        get { (_cold?.data.placeholderFontBox as? FontStyleBox)?.style }
        set { ensureCold().data.placeholderFontBox = newValue.map(FontStyleBox.init) }
    }
    internal var outsideListDiscFont: TextStyle? {
        get { (_cold?.data.outsideListDiscFontBox as? FontStyleBox)?.style }
        set { ensureCold().data.outsideListDiscFontBox = newValue.map(FontStyleBox.init) }
    }
    public var isWrapGreedy: Bool { get { _cold?.data.wrapGreedy ?? false } set { ensureCold().data.wrapGreedy = newValue } }
    public var caretColor: Color? { get { _cold?.data.caretColor } set { ensureCold().data.caretColor = newValue } }
    public var selectionColor: Color? { get { _cold?.data.selectionColor } set { ensureCold().data.selectionColor = newValue } }
    public var iconPayload: (SVGIcon, Float)? { get { _cold?.data.iconPayload } set { ensureCold().data.iconPayload = newValue } }
    public var imagePayload: RGBA8Atlas? { get { _cold?.data.imagePayload } set { ensureCold().data.imagePayload = newValue } }
    public var pixelsPayload: Pixels? { get { _cold?.data.pixelsPayload } set { ensureCold().data.pixelsPayload = newValue } }
    public var pixelsFitMode: SurfaceFit? { get { _cold?.data.pixelsFitMode } set { ensureCold().data.pixelsFitMode = newValue } }
    public var surfacePayload: (surface: NativeSurface, fit: SurfaceFit)? { get { _cold?.data.surfacePayload } set { ensureCold().data.surfacePayload = newValue } }
    public var surfacePlace: SurfacePlace { get { _cold?.data.surfacePlace ?? .centered } set { ensureCold().data.surfacePlace = newValue } }
    public var gradient: Gradient? { get { _cold?.data.gradient } set { ensureCold().data.gradient = newValue } }
    public var borderSides: Sides? { get { _cold?.data.borderSides } set { ensureCold().data.borderSides = newValue } }
    public var dashedBorder: (dash: Float, gap: Float, phase: Float)? { get { _cold?.data.dashedBorder } set { ensureCold().data.dashedBorder = newValue } }
    public var pixelSnapEnabled: Bool { get { _cold?.data.pixelSnapEnabled ?? true } set { ensureCold().data.pixelSnapEnabled = newValue } }
    public var clipRadius: Float? { get { _cold?.data.clipRadius } set { ensureCold().data.clipRadius = newValue } }
    public var clipCorners: Corners? { get { _cold?.data.clipCorners } set { ensureCold().data.clipCorners = newValue } }
    public var clipFade: SIMD4<Float>? { get { _cold?.data.clipFade } set { ensureCold().data.clipFade = newValue } }
    public var scrollEdgeFadeWidth: Float { get { _cold?.data.scrollEdgeFadeWidth ?? 0 } set { ensureCold().data.scrollEdgeFadeWidth = newValue } }
    public var scrollFadeStyle: ScrollFadeStyle { get { _cold?.data.scrollFadeStyle ?? .smooth } set { ensureCold().data.scrollFadeStyle = newValue } }
    public var scrollMarginPts: Float { get { _cold?.data.scrollMarginPts ?? 0 } set { ensureCold().data.scrollMarginPts = newValue } }
    public var scrollAnchorEnabled: Bool { get { _cold?.data.scrollAnchorEnabled ?? false } set { ensureCold().data.scrollAnchorEnabled = newValue } }
    internal var stickyConfig: StickyConfig? { get { _cold?.data.stickyConfig } set { ensureCold().data.stickyConfig = newValue } }
    public var growthSpec: GrowthSpec? { get { _cold?.data.growthSpec } set { ensureCold().data.growthSpec = newValue } }
    public var isStreaming: Bool { get { _cold?.data.isStreaming ?? false } set { ensureCold().data.isStreaming = newValue } }
    internal var joinedRowFaceKey: String? { get { _cold?.data.joinedRowFaceKey } set { ensureCold().data.joinedRowFaceKey = newValue } }
    internal var growthReveal: GrowthReveal? { get { _cold?.data.growthReveal } set { ensureCold().data.growthReveal = newValue } }
    public var isArrivesWhole: Bool { get { _cold?.data.isArrivesWhole ?? false } set { ensureCold().data.isArrivesWhole = newValue } }
    public var explicitDir: Direction? { get { _cold?.data.explicitDir } set { ensureCold().data.explicitDir = newValue } }
    public var isUnmirrored: Bool { get { _cold?.data.isUnmirrored ?? false } set { ensureCold().data.isUnmirrored = newValue } }
    public var mirrorInRtl: Bool { get { _cold?.data.mirrorInRtl ?? false } set { ensureCold().data.mirrorInRtl = newValue } }
    public var textDirByParagraph: Bool { get { _cold?.data.textDirByParagraph ?? false } set { ensureCold().data.textDirByParagraph = newValue } }
    public var focusFillColor: Color? { get { _cold?.data.focusFillColor } set { ensureCold().data.focusFillColor = newValue } }
    public var pressFocusesBelow: Bool { get { _cold?.data.pressFocusesBelow ?? false } set { ensureCold().data.pressFocusesBelow = newValue } }
    public var noWindowDrag: Bool { get { _cold?.data.noWindowDrag ?? false } set { ensureCold().data.noWindowDrag = newValue } }
    public var isImeCursor: Bool { get { _cold?.data.isImeCursor ?? false } set { ensureCold().data.isImeCursor = newValue } }
    public var isImeOptionAsAlt: Bool { get { _cold?.data.optionAsAlt ?? false } set { ensureCold().data.optionAsAlt = newValue } }
    public var isSpellcheck: Bool { get { _cold?.data.spellcheck ?? false } set { ensureCold().data.spellcheck = newValue } }
    public var textReveal: Float { get { _cold?.data.textReveal ?? -1.0 } set { ensureCold().data.textReveal = newValue } }
    public var foldGlideSpec: FoldGlide? { get { _cold?.data.foldGlideSpec } set { ensureCold().data.foldGlideSpec = newValue } }
    public var virtualEstimate: Float? { get { _cold?.data.virtualEstimate } set { ensureCold().data.virtualEstimate = newValue } }
    internal var virtualizeSite: String? {
        get { _cold?.data.runtimeExtras["virtualizeSite"] as? String }
        set { ensureCold().data.runtimeExtras["virtualizeSite"] = newValue }
    }
    public var traceNameValue: String? {
        get { _cold?.data.runtimeExtras["traceName"] as? String }
        set { ensureCold().data.runtimeExtras["traceName"] = newValue }
    }
    public var traceNamespaceValue: (className: String, host: String)? {
        get { _cold?.data.runtimeExtras["traceNamespace"] as? (className: String, host: String) }
        set { ensureCold().data.runtimeExtras["traceNamespace"] = newValue }
    }
    internal var virtualRowsSource: VirtualRowSource<State>? { get { _cold?.data.virtualRowsSource } set { ensureCold().data.virtualRowsSource = newValue } }
    internal var virtualRowsVersionHash: UInt64? { get { _cold?.data.virtualRowsVersion } set { ensureCold().data.virtualRowsVersion = newValue } }
    public var isFocusSelected: Bool { get { _cold?.data.focusSelected ?? false } set { ensureCold().data.focusSelected = newValue } }
    public var isRevealSelected: Bool { get { _cold?.data.revealSelected ?? false } set { ensureCold().data.revealSelected = newValue } }
    public var hoverBg: Color? { get { _cold?.data.hoverBg } set { ensureCold().data.hoverBg = newValue } }
    public var pressBg: Color? { get { _cold?.data.pressBg } set { ensureCold().data.pressBg = newValue } }
    public var pressColor: Color? { get { _cold?.data.pressColor } set { ensureCold().data.pressColor = newValue } }
    public var pressScaleFactor: Float? { get { _cold?.data.pressScaleFactor } set { ensureCold().data.pressScaleFactor = newValue } }
    public var isHoverGroup: Bool { get { _cold?.data.isHoverGroup ?? false } set { ensureCold().data.isHoverGroup = newValue } }
    public var hoverGroupShare: String? { get { _cold?.data.hoverGroupShare } set { ensureCold().data.hoverGroupShare = newValue } }
    public var isHoverAlone: Bool { get { _cold?.data.isHoverAlone ?? false } set { ensureCold().data.isHoverAlone = newValue } }
    public var hoverMotionSpec: (enter: Anim<Float>, exit: Anim<Float>)? { get { _cold?.data.hoverMotion } set { ensureCold().data.hoverMotion = newValue } }
    public var hoverWithinSpec: (enter: Anim<Float>, exit: Anim<Float>)? { get { _cold?.data.hoverWithin } set { ensureCold().data.hoverWithin = newValue } }
    public var groupOpacity: (rest: Float, hovered: Float)? { get { _cold?.data.groupOpacity } set { ensureCold().data.groupOpacity = newValue } }
    public var groupColor: Color? { get { _cold?.data.groupColor } set { ensureCold().data.groupColor = newValue } }
    public var isDissolve: Bool { get { _cold?.data.isDissolve ?? false } set { ensureCold().data.isDissolve = newValue } }
    public var drawnRectLive: Live<MotionRect>? { get { _cold?.data.drawnRectLive } set { ensureCold().data.drawnRectLive = newValue } }
    public var focusRingColor: Color? { get { _cold?.data.focusRingColor } set { ensureCold().data.focusRingColor = newValue } }
    public var focusRingWidth: Float { get { _cold?.data.focusRingWidth ?? 2.0 } set { ensureCold().data.focusRingWidth = newValue } }
    public var focusRingOffset: Float { get { _cold?.data.focusRingOffset ?? 2.0 } set { ensureCold().data.focusRingOffset = newValue } }
    public var focusReturnKey: String? { get { _cold?.data.focusReturnKey } set { ensureCold().data.focusReturnKey = newValue } }
    public var modalClickOutside: Bool { get { _cold?.data.modalClickOutside ?? false } set { ensureCold().data.modalClickOutside = newValue } }
    public var tabIndex: Int? { get { _cold?.data.tabIndex } set { ensureCold().data.tabIndex = newValue } }
    public var isDefaultButton: Bool { get { _cold?.data.isDefaultButton ?? false } set { ensureCold().data.isDefaultButton = newValue } }
    public var noFocusRing: Bool { get { _cold?.data.noFocusRing ?? false } set { ensureCold().data.noFocusRing = newValue } }
    public var isFocusRequested: Bool { get { _cold?.data.focusRequested ?? false } set { ensureCold().data.focusRequested = newValue } }
    public var focusHighlightColor: Color? { get { _cold?.data.focusHighlightColor } set { ensureCold().data.focusHighlightColor = newValue } }
    public var focusWithinRing: (width: Float, offset: Float, color: Color)? {
        get { _cold?.data.focusWithinRing }
        set { ensureCold().data.focusWithinRing = newValue }
    }
    public var focusWithinFlat: Bool { get { _cold?.data.focusWithinFlat ?? false } set { ensureCold().data.focusWithinFlat = newValue } }
    public var isFocusFollowsSelection: Bool { get { _cold?.data.focusFollows ?? false } set { ensureCold().data.focusFollows = newValue } }

    public var a11yLabel: String? {
        get { _cold?.data.a11yLabelStorage?.stringValue }
        set { ensureCold().data.a11yLabelStorage = newValue.map(CowText.owned) }
    }
    internal var a11yLabelCow: CowText? {
        get { _cold?.data.a11yLabelStorage }
        set { ensureCold().data.a11yLabelStorage = newValue }
    }
    public var a11yHelp: String? { get { _cold?.data.a11yHelp } set { ensureCold().data.a11yHelp = newValue } }
    public var isHelpWhenTruncated: Bool { get { _cold?.data.helpWhenTruncated ?? false } set { ensureCold().data.helpWhenTruncated = newValue } }
    public var helpSide: Side? { get { _cold?.data.helpSide } set { ensureCold().data.helpSide = newValue } }
    public var a11ySelected: String? { get { _cold?.data.a11ySelected } set { ensureCold().data.a11ySelected = newValue } }
    public var a11yExpanded: Bool? { get { _cold?.data.a11yExpanded } set { ensureCold().data.a11yExpanded = newValue } }
    public var a11yLevel: Int? { get { _cold?.data.a11yLevel } set { ensureCold().data.a11yLevel = newValue } }
    public var itemSelected: Bool { get { _cold?.data.itemSelected ?? false } set { ensureCold().data.itemSelected = newValue } }
    public var a11yDescription: String? {
        get { _cold?.data.a11yDescriptionStorage?.stringValue }
        set { ensureCold().data.a11yDescriptionStorage = newValue.map(CowText.owned) }
    }
    internal var a11yDescriptionCow: CowText? {
        get { _cold?.data.a11yDescriptionStorage }
        set { ensureCold().data.a11yDescriptionStorage = newValue }
    }
    public var a11yValue: String? { get { _cold?.data.a11yValue } set { ensureCold().data.a11yValue = newValue } }
    public var a11yRange: A11yRange? { get { _cold?.data.a11yRange } set { ensureCold().data.a11yRange = newValue } }
    public var a11yChecked: A11yChecked? { get { _cold?.data.a11yChecked } set { ensureCold().data.a11yChecked = newValue } }
    public var a11yDisabled: Bool { get { _cold?.data.a11yDisabled ?? false } set { ensureCold().data.a11yDisabled = newValue } }
    public var isA11yHidden: Bool { get { _cold?.data.isA11yHidden ?? false } set { ensureCold().data.isA11yHidden = newValue } }
    public var a11yActiveDescendant: String? { get { _cold?.data.a11yActiveDescendant } set { ensureCold().data.a11yActiveDescendant = newValue } }
    public var a11yLabelledBy: String? {
        get { _cold?.data.a11yLabelledByStorage?.stringValue }
        set { ensureCold().data.a11yLabelledByStorage = newValue.map(CowText.owned) }
    }
    public var a11yDescribedBy: String? {
        get { _cold?.data.a11yDescribedByStorage?.stringValue }
        set { ensureCold().data.a11yDescribedByStorage = newValue.map(CowText.owned) }
    }
    public var a11yBusy: Bool { get { _cold?.data.a11yBusy ?? false } set { ensureCold().data.a11yBusy = newValue } }
    public var a11yInvalid: Bool { get { _cold?.data.a11yInvalid ?? false } set { ensureCold().data.a11yInvalid = newValue } }
    public var a11yReadOnly: Bool { get { _cold?.data.a11yReadOnly ?? false } set { ensureCold().data.a11yReadOnly = newValue } }
    public var a11ySorted: Bool? { get { _cold?.data.a11ySorted } set { ensureCold().data.a11ySorted = newValue } }
    public var a11yLive: LiveRegionPoliteness? { get { _cold?.data.a11yLive } set { ensureCold().data.a11yLive = newValue } }
    public var a11yPosInSet: (position: Int, size: Int)? { get { _cold?.data.a11yPosInSet } set { ensureCold().data.a11yPosInSet = newValue } }
    public var a11yShortcutHint: String? { get { _cold?.data.a11yShortcutHint } set { ensureCold().data.a11yShortcutHint = newValue } }
    public var a11yHref: String? { get { _cold?.data.a11yHref } set { ensureCold().data.a11yHref = newValue } }

    public var anchor: Anchor? { get { _cold?.data.anchor } set { ensureCold().data.anchor = newValue } }
    public var layoutAnim: LayoutAnim? { get { _cold?.data.layoutAnim } set { ensureCold().data.layoutAnim = newValue } }
    public var styleSpring: Spring? { get { _cold?.data.styleSpring } set { ensureCold().data.styleSpring = newValue } }
    public var transition: Transition? { get { _cold?.data.transition } set { ensureCold().data.transition = newValue } }
    public var enterDelay: Float { get { _cold?.data.enterDelay ?? 0 } set { ensureCold().data.enterDelay = newValue } }
    public var hasInstantChanges: Bool { get { _cold?.data.hasInstantChanges ?? false } set { ensureCold().data.hasInstantChanges = newValue } }
    public var hasAnimatedChanges: Bool { get { _cold?.data.hasAnimatedChanges ?? false } set { ensureCold().data.hasAnimatedChanges = newValue } }
    public var loopingSpec: LoopSpec? { get { _cold?.data.loopingSpec } set { ensureCold().data.loopingSpec = newValue } }
    public var flightId: String? { get { _cold?.data.flightId } set { ensureCold().data.flightId = newValue } }
    public var isMatchedCrop: Bool { get { _cold?.data.flightCrop ?? false } set { ensureCold().data.flightCrop = newValue } }
    public var flightSpring: Spring? { get { _cold?.data.flightSpring } set { ensureCold().data.flightSpring = newValue } }
    public var terminalGridPayload: TerminalGrid? { get { _cold?.data.terminalGridPayload } set { ensureCold().data.terminalGridPayload = newValue } }
    public var spellcheck: Bool { get { _cold?.data.spellcheck ?? false } set { ensureCold().data.spellcheck = newValue } }
    public var richStyleSpec: RichStyle? { get { _cold?.data.richStyle } set { ensureCold().data.richStyle = newValue } }
    public var pillColorsSpec: (bg: Color, fg: Color?)? { get { _cold?.data.pillColors } set { ensureCold().data.pillColors = newValue } }
    public var pillIconLookup: ((String) -> SVGIcon?)? { get { _cold?.data.pillIconLookup } set { ensureCold().data.pillIconLookup = newValue } }
    public var pillStyleLookup: ((String) -> PillStyle)? { get { _cold?.data.pillStyleLookup } set { ensureCold().data.pillStyleLookup = newValue } }
    public var isSingleLineInput: Bool { get { _cold?.data.isSingleLineInput ?? false } set { ensureCold().data.isSingleLineInput = newValue } }
    /// The field shows its editor but takes no edits from it (upstream `Input::access == None`).
    public var editAccessWithheld: Bool { get { _cold?.data.editAccessWithheld ?? false } set { ensureCold().data.editAccessWithheld = newValue } }
    public var animateEditLayoutEnabled: Bool { get { _cold?.data.animateEditLayoutEnabled ?? false } set { ensureCold().data.animateEditLayoutEnabled = newValue } }
    public var isIconOneColor: Bool { get { _cold?.data.isIconOneColor ?? false } set { ensureCold().data.isIconOneColor = newValue } }
    public var iconRotation: Float { get { _cold?.data.iconRotation ?? 0.0 } set { ensureCold().data.iconRotation = newValue } }
    public var isWidthLeads: Bool { get { _cold?.data.isWidthLeads ?? false } set { ensureCold().data.isWidthLeads = newValue } }
    public var holdLandingWidthEnabled: Bool { get { _cold?.data.holdLandingWidthEnabled ?? false } set { ensureCold().data.holdLandingWidthEnabled = newValue } }
    public var paintContain: Vec2? { get { _cold?.data.paintContain } set { ensureCold().data.paintContain = newValue } }
    public var motionSnapsEnabled: Bool { get { _cold?.data.motionSnapsEnabled ?? false } set { ensureCold().data.motionSnapsEnabled = newValue } }
    public var isRaised: Bool { get { _cold?.data.isRaised ?? false } set { ensureCold().data.isRaised = newValue } }
    public var offsetMotionAnim: Anim<Vec2>? { get { _cold?.data.offsetMotionAnim } set { ensureCold().data.offsetMotionAnim = newValue } }
    public var opacityMotionAnim: Anim<Float>? { get { _cold?.data.opacityMotionAnim } set { ensureCold().data.opacityMotionAnim = newValue } }
    public var scaleMotionAnim: Anim<Vec2>? { get { _cold?.data.scaleMotionAnim } set { ensureCold().data.scaleMotionAnim = newValue } }
    public var rotateMotionAnim: Anim<Float>? { get { _cold?.data.rotateMotionAnim } set { ensureCold().data.rotateMotionAnim = newValue } }
    public var textCaseValue: TextCase? { get { _cold?.data.textCaseValue } set { ensureCold().data.textCaseValue = newValue } }
    public var spanRingsSpec: [(range: Range<Int>, color: Color, width: Float)] { get { _cold?.data.spanRings ?? [] } set { ensureCold().data.spanRings = newValue.isEmpty ? nil : newValue } }
    public var advanceInRun: (run: TextRun, byteOffset: Int)? { get { _cold?.data.advanceInRun } set { ensureCold().data.advanceInRun = newValue } }
    public var isTruncateFadeEnabled: Bool { get { _cold?.data.isTruncateFadeEnabled ?? false } set { ensureCold().data.isTruncateFadeEnabled = newValue } }
    public var truncateFadeEm: Float { get { _cold?.data.truncateFadeEm ?? 1.5 } set { ensureCold().data.truncateFadeEm = newValue } }
    public var isolatesSpec: [(range: Range<Int>, dir: Direction)] { get { _cold?.data.isolates ?? [] } set { ensureCold().data.isolates = newValue.isEmpty ? nil : newValue } }
    var liveBindings: [BoundLiveProperty] { get { _cold?.data.liveBindings ?? [] } set { ensureCold().data.liveBindings = newValue.isEmpty ? nil : newValue } }
    public var handlers: ElementHandlers<State> {
        get { _cold?.data.handlersBox?.value ?? ElementHandlers<State>() }
        set {
            let box = ensureCold()
            if isKnownUniquelyReferenced(&box.data.handlersBox) {
                box.data.handlersBox?.value = newValue
            } else {
                box.data.handlersBox = ElHandlersBox(newValue)
            }
        }
    }
    internal var runtimeExtras: [String: Any] {
        get { _cold?.data.runtimeExtras ?? [:] }
        set { ensureCold().data.runtimeExtras = newValue }
        _modify {
            let box = ensureCold()
            yield &box.data.runtimeExtras
        }
    }
    public var keyLocation: String {
        get { _cold?.data.keyLocation ?? "" }
        set { ensureCold().data.keyLocation = newValue.isEmpty ? nil : newValue }
    }

    public init(direction: FlexDirection = .row) {
        self.layout = LayoutStyle(direction: direction)
    }

    // MARK: - Identity & Hierarchy

    public func key(_ k: String, file: String = #fileID, line: UInt = #line, column: UInt = #column) -> Self {
        var copy = self
        copy.keyId = k
        copy.keyLocation = "\(file):\(line):\(column)"
        return copy
    }

    public func child(_ c: El<State>) -> Self {
        var copy = self
        copy.children.append(c)
        return copy
    }

    public func child(_ c: El<State>?) -> Self {
        guard let c else { return self }
        return child(c)
    }

    public func children<S: Sequence>(_ list: S) -> Self where S.Element == El<State> {
        var copy = self
        copy.children.append(contentsOf: list)
        return copy
    }

    // MARK: - Sizing & Flexbox Modifiers

    public func w(_ v: Float) -> Self {
        var copy = self
        copy.layout.width = .points(v)
        return copy
    }

    public func h(_ v: Float) -> Self {
        var copy = self
        copy.layout.height = .points(v)
        return copy
    }

    public func size(_ w: Float, _ h: Float) -> Self {
        var copy = self
        copy.layout.width = .points(w)
        copy.layout.height = .points(h)
        return copy
    }

    public func square(_ s: Float) -> Self {
        size(s, s)
    }

    public func wFull() -> Self {
        var copy = self
        copy.layout.width = .fraction(1.0)
        return copy
    }

    public func hFull() -> Self {
        var copy = self
        copy.layout.height = .fraction(1.0)
        return copy
    }

    public func sizeFull() -> Self {
        wFull().hFull()
    }

    public func wFrac(_ f: Float) -> Self {
        var copy = self
        copy.layout.width = .fraction(f)
        return copy
    }

    public func hFrac(_ f: Float) -> Self {
        var copy = self
        copy.layout.height = .fraction(f)
        return copy
    }

    public func wAuto() -> Self {
        var copy = self
        copy.layout.width = .auto
        return copy
    }

    public func hAuto() -> Self {
        var copy = self
        copy.layout.height = .auto
        return copy
    }

    public func sizeAuto() -> Self {
        wAuto().hAuto()
    }

    public func minWFrac(_ f: Float) -> Self {
        var copy = self
        copy.layout.minWidth = .fraction(f)
        return copy
    }

    public func minHFrac(_ f: Float) -> Self {
        var copy = self
        copy.layout.minHeight = .fraction(f)
        return copy
    }

    public func maxWFrac(_ f: Float) -> Self {
        var copy = self
        copy.layout.maxWidth = .fraction(f)
        return copy
    }

    public func maxHFrac(_ f: Float) -> Self {
        var copy = self
        copy.layout.maxHeight = .fraction(f)
        return copy
    }

    public func minW(_ v: Float) -> Self {
        var copy = self
        copy.layout.minWidth = .points(v)
        return copy
    }

    public func minH(_ v: Float) -> Self {
        var copy = self
        copy.layout.minHeight = .points(v)
        return copy
    }

    public func maxW(_ v: Float) -> Self {
        var copy = self
        copy.layout.maxWidth = .points(v)
        return copy
    }

    public func maxH(_ v: Float) -> Self {
        var copy = self
        copy.layout.maxHeight = .points(v)
        return copy
    }

    public func grow(_ g: Float = 1.0) -> Self {
        var copy = self
        copy.layout.flexGrow = g
        copy.layout.flexShrink = 1.0
        if copy.layout.flexBasis == .auto {
            copy.layout.flexBasis = .points(0)
        }
        return copy
    }

    public func shrink(_ s: Float) -> Self {
        var copy = self
        copy.layout.flexShrink = s
        return copy
    }

    public func basis(_ pt: Float) -> Self {
        var copy = self
        copy.layout.flexBasis = .points(pt)
        return copy
    }

    public func aspectRatio(_ r: Float) -> Self {
        var copy = self
        copy.layout.aspectRatio = (r.isFinite && r > 0) ? r : nil
        return copy
    }

    public func aspectFit(_ r: Float) -> Self {
        var copy = self
        copy.layout.aspectFit = (r.isFinite && r > 0) ? r : nil
        return copy
    }

    public func flexWrap(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.layout.wrap = enabled
        return copy
    }

    public func gap(_ g: Float) -> Self {
        var copy = self
        copy.layout.rowGap = max(0, g)
        copy.layout.columnGap = max(0, g)
        return copy
    }

    public func rowGap(_ g: Float) -> Self {
        var copy = self
        copy.layout.rowGap = max(0, g)
        return copy
    }

    public func columnGap(_ g: Float) -> Self {
        var copy = self
        copy.layout.columnGap = max(0, g)
        return copy
    }

    // MARK: - Padding & Margin

    public func p(_ all: Float) -> Self {
        var copy = self
        copy.layout.padding = .all(all)
        return copy
    }

    public func px(_ h: Float) -> Self {
        var copy = self
        copy.layout.padding.left = h
        copy.layout.padding.right = h
        return copy
    }

    public func py(_ v: Float) -> Self {
        var copy = self
        copy.layout.padding.top = v
        copy.layout.padding.bottom = v
        return copy
    }

    public func pt(_ v: Float) -> Self { var c = self; c.layout.padding.top = v; return c }
    public func pb(_ v: Float) -> Self { var c = self; c.layout.padding.bottom = v; return c }
    public func pl(_ v: Float) -> Self { var c = self; c.layout.padding.left = v; return c }
    public func pr(_ v: Float) -> Self { var c = self; c.layout.padding.right = v; return c }

    public func m(_ all: Float) -> Self {
        var copy = self
        copy.layout.margin = .all(all)
        return copy
    }

    public func mx(_ h: Float) -> Self { var c = self; c.layout.margin.left = h; c.layout.margin.right = h; return c }
    public func my(_ v: Float) -> Self { var c = self; c.layout.margin.top = v; c.layout.margin.bottom = v; return c }
    public func mt(_ v: Float) -> Self { var c = self; c.layout.margin.top = v; return c }
    public func mb(_ v: Float) -> Self { var c = self; c.layout.margin.bottom = v; return c }
    public func ml(_ v: Float) -> Self { var c = self; c.layout.margin.left = v; return c }
    public func mr(_ v: Float) -> Self { var c = self; c.layout.margin.right = v; return c }

    // MARK: - Alignment & Positioning

    public func itemsStart() -> Self { var c = self; c.layout.alignItems = .start; return c }
    public func itemsCenter() -> Self { var c = self; c.layout.alignItems = .center; return c }
    public func centerY() -> Self { itemsCenter() }
    public func centerX() -> Self { justifyCenter() }
    public func itemsEnd() -> Self { var c = self; c.layout.alignItems = .end; return c }
    public func itemsStretch() -> Self { var c = self; c.layout.alignItems = .stretch; return c }
    public func alignSelf(_ a: AlignItems) -> Self { var c = self; c.layout.alignSelf = a; return c }

    public func justifyStart() -> Self { var c = self; c.layout.justifyContent = .start; return c }
    public func justifyCenter() -> Self { var c = self; c.layout.justifyContent = .center; return c }
    public func justifyEnd() -> Self { var c = self; c.layout.justifyContent = .end; return c }
    public func justifyBetween() -> Self { var c = self; c.layout.justifyContent = .spaceBetween; return c }
    public func justifyAround() -> Self { var c = self; c.layout.justifyContent = .spaceAround; return c }
    public func justifyEvenly() -> Self { var c = self; c.layout.justifyContent = .spaceEvenly; return c }

    public func center() -> Self {
        var copy = self
        copy.layout.alignItems = .center
        copy.layout.justifyContent = .center
        return copy
    }

    public func absolute(x: Float, y: Float) -> Self {
        var copy = self
        copy.layout.isAbsolute = true
        copy.layout.pinLeft = x
        copy.layout.pinTop = y
        return copy
    }

    public func pin(top: Float? = nil, right: Float? = nil, bottom: Float? = nil, left: Float? = nil) -> Self {
        var copy = self
        copy.layout.isAbsolute = true
        if let top { copy.layout.pinTop = top }
        if let right { copy.layout.pinRight = right }
        if let bottom { copy.layout.pinBottom = bottom }
        if let left { copy.layout.pinLeft = left }
        return copy
    }

    public func z(_ order: Int) -> Self {
        var copy = self
        copy.zIndex = order
        return copy
    }

    // MARK: - Scrolling & Clipping

    public func scroll(stickBottom: Bool = false) -> Self {
        var copy = self
        copy.layout.scrollAxes = .vertical
        copy.layout.stickBottom = stickBottom
        copy.layout.clipOverflow = true
        return copy
    }

    public func scroll(_ spec: ScrollSpec) -> Self {
        scroll(stickBottom: spec.stickBottom)
    }

    public func scrollY(stickBottom: Bool = false) -> Self {
        scroll(stickBottom: stickBottom)
    }

    public func scrollX() -> Self {
        var copy = self
        copy.layout.scrollAxes = .horizontal
        copy.layout.clipOverflow = true
        return copy
    }

    public func scrollXY() -> Self {
        var copy = self
        copy.layout.scrollAxes = .both
        copy.layout.clipOverflow = true
        return copy
    }

    public func clip(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.layout.clipOverflow = enabled
        return copy
    }

    public func onAtBottom(_ handler: @escaping (inout State, Bool) -> Void) -> Self {
        onAtBottomIf { state, at in
            handler(&state, at)
            return true
        }
    }

    /// Receives the initial and subsequent changed bottom reports. Return true to rebuild the view.
    public func onAtBottomIf(_ report: @escaping (inout State, Bool) -> Bool) -> Self {
        var copy = self
        copy.handlers.atBottomReport = report
        return copy
    }

    public func onFarFromBottom(_ min: Float, _ handler: @escaping (inout State, Bool) -> Void) -> Self {
        onFarFromBottomIf(min) { state, far in
            handler(&state, far)
            return true
        }
    }

    public func onFarFromBottomUnder(_ min: Float, frame: String, _ handler: @escaping (inout State, Bool) -> Void) -> Self {
        onFarFromBottomIf(min, frame: frame) { state, far in
            handler(&state, far)
            return true
        }
    }

    public func onFarFromBottomIf(_ min: Float, frame: String? = nil, _ report: @escaping (inout State, Bool) -> Bool) -> Self {
        var copy = self
        copy.handlers.farFromBottomReport = (min, frame, report)
        return copy
    }

    public func onScrollOffset(_ handler: @escaping (ScrollPos) -> Void) -> Self {
        var copy = self
        copy.handlers.onScrollOffset = handler
        copy.handlers.onScrollOffsetToken = allocateScrollOffsetHandlerToken()
        return copy
    }

    public func chainScrollOffset(_ handler: @escaping (ScrollPos) -> Void) -> Self {
        var copy = self
        if let prev = copy.handlers.onScrollOffset {
            copy.handlers.onScrollOffset = { pos in
                prev(pos)
                handler(pos)
            }
        } else {
            copy.handlers.onScrollOffset = handler
        }
        copy.handlers.onScrollOffsetToken = allocateScrollOffsetHandlerToken()
        return copy
    }

    public func onScroll(_ handler: @escaping (inout State, ScrollPos, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onScroll = handler
        return copy
    }

    public func scrollAnchor(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.scrollAnchorEnabled = enabled
        return copy
    }

    public func scrollFade(_ fade: ScrollFade) -> Self {
        var copy = self
        copy.scrollEdgeFadeWidth = fade.width
        copy.scrollFadeStyle = fade.style
        return copy
    }

    public func stickyTop(_ offset: Float = 0) -> Self {
        var copy = self
        let clean = offset.isFinite ? offset : 0
        var cfg = copy.stickyConfig ?? StickyConfig()
        cfg.edge = .top(clean)
        cfg.inset = clean
        cfg.tail = false
        copy.stickyConfig = cfg
        copy.layout.sticky = .top(clean)
        return copy
    }

    public func stickyTopShowing(_ show: Float) -> Self {
        var copy = stickyTop(show)
        var cfg = copy.stickyConfig ?? StickyConfig()
        cfg.tail = true
        copy.stickyConfig = cfg
        return copy
    }

    public func stickyBottom(_ offset: Float = 0) -> Self {
        var copy = self
        let clean = offset.isFinite ? offset : 0
        var cfg = copy.stickyConfig ?? StickyConfig()
        cfg.edge = .bottom(clean)
        cfg.inset = clean
        cfg.tail = false
        copy.stickyConfig = cfg
        copy.layout.sticky = .bottom(clean)
        return copy
    }

    public func stickyLeft(_ offset: Float = 0) -> Self {
        var copy = self
        let clean = offset.isFinite ? offset : 0
        var cfg = copy.stickyConfig ?? StickyConfig()
        cfg.edge = .left(clean)
        cfg.inset = clean
        cfg.tail = false
        copy.stickyConfig = cfg
        copy.layout.sticky = .left(clean)
        return copy
    }

    public func stuckShadow(_ shadow: Shadow) -> Self {
        var copy = self
        var cfg = copy.stickyConfig ?? StickyConfig()
        cfg.shadows.append(shadow)
        copy.stickyConfig = cfg
        return copy
    }

    public func stuckFade(lead: Float, span: Float) -> Self {
        var copy = self
        var cfg = copy.stickyConfig ?? StickyConfig()
        cfg.fade = (lead, max(0, span))
        copy.stickyConfig = cfg
        return copy
    }

    public func stuckReveal(_ span: Float) -> Self {
        var copy = self
        var cfg = copy.stickyConfig ?? StickyConfig()
        cfg.reveal = max(1e-3, span)
        copy.stickyConfig = cfg
        return copy
    }

    // MARK: - Visual Styling

    public func bg(_ color: Color) -> Self {
        var copy = self
        copy.background = color
        return copy
    }

    public func linearGradient(top: Color, bottom: Color, angleRadians: Float = .pi * 0.5) -> Self {
        var copy = self
        copy.gradient = .linear(top: top, bottom: bottom, angleRadians: angleRadians)
        return copy
    }

    public func radialGradient(inner: Color, outer: Color) -> Self {
        var copy = self
        copy.gradient = .radial(inner: inner, outer: outer)
        return copy
    }

    public func rounded(_ r: Float) -> Self {
        var copy = self
        copy.corners = .all(r)
        return copy
    }

    /// Apple continuous squircle corners (`radii < 0` in shader).
    public func continuousRounded(_ r: Float) -> Self {
        var copy = self
        copy.corners = .all(-abs(r))
        return copy
    }

    public func corners(_ tl: Float, _ tr: Float, _ br: Float, _ bl: Float) -> Self {
        var copy = self
        copy.corners = Corners(tl, tr, br, bl)
        return copy
    }

    public func pill() -> Self {
        rounded(9999)
    }

    public func border(_ width: Float, _ color: Color) -> Self {
        var copy = self
        copy.borderWidth = max(0, width)
        copy.borderColor = color
        if copy._cold?.data.runtimeExtras[RenderExtrasKey.borderGradient] != nil {
            copy.runtimeExtras.removeValue(forKey: RenderExtrasKey.borderGradient)
        }
        return copy
    }

    public func borderSides(top: Float = 0, right: Float = 0, bottom: Float = 0, left: Float = 0, color: Color) -> Self {
        var copy = self
        copy.borderSides = Sides(top: top, right: right, bottom: bottom, left: left)
        copy.borderColor = color
        return copy
    }

    public func dashedBorder(_ width: Float, _ color: Color, dash: Float = 4, gap: Float = 4, phase: Float = 0) -> Self {
        var copy = self
        copy.borderWidth = max(0.5, width)
        copy.borderColor = color
        copy.dashedBorder = (dash, gap, phase)
        return copy
    }

    public func shadow(_ s: Shadow) -> Self {
        var copy = self
        copy.shadows.append(s)
        return copy
    }

    public func shadows(_ list: [Shadow]) -> Self {
        var copy = self
        copy.shadows.append(contentsOf: list)
        return copy
    }

    public func opacity(_ a: Float) -> Self {
        var copy = self
        copy.opacity = a.clamped(to: 0...1)
        return copy
    }

    public func scale(_ s: Float) -> Self {
        var copy = self
        copy.scale = Vec2(s, s)
        return copy
    }

    public func scale(_ x: Float, _ y: Float) -> Self {
        var copy = self
        copy.scale = Vec2(x, y)
        return copy
    }

    public func rotate(_ radians: Float) -> Self {
        var copy = self
        copy.rotate = radians
        return copy
    }

    public func origin(_ x: Float, _ y: Float) -> Self {
        var copy = self
        copy.origin = Vec2(x, y)
        return copy
    }

    public func offset(_ x: Float, _ y: Float) -> Self {
        var copy = self
        copy.offset = Vec2(x, y)
        return copy
    }

    public func blur(_ radius: Float) -> Self {
        var copy = self
        copy.blur = max(0, radius)
        return copy
    }

    public func backdropBlur(_ radius: Float) -> Self {
        var copy = self
        copy.backdropBlur = max(0, radius)
        return copy
    }

    public func pixelSnap(_ on: Bool = true) -> Self {
        var copy = self
        copy.pixelSnapEnabled = on
        return copy
    }

    /// Snaps this element's children as Blink does inside a box with paint containment
    /// (`contain: paint`, `content` or `strict`) whose top-left is `origin`, in window points.
    public func paintContained(_ origin: Vec2) -> Self {
        var copy = self
        copy.paintContain = origin
        return copy
    }

    /// Convenience overload of ``paintContained(_:)`` taking separate `x` and `y` window points.
    public func paintContained(_ x: Float, _ y: Float) -> Self {
        paintContained(Vec2(x, y))
    }

    /// While it moves, this element and everything in its subtree snap to whole device pixels
    /// every frame (`El::motion_snaps`), stepping a pixel at a time instead of gliding.
    public func motionSnaps(_ on: Bool = true) -> Self {
        var copy = self
        copy.motionSnapsEnabled = on
        return copy
    }

    public func clipRounded(_ radius: Float) -> Self {
        var copy = self
        copy.applyParityClip { target in
            target.clipCorners = nil
            target.clipRadius = max(0, radius)
        }
        return copy
    }

    public func clipCorners(_ radii: Corners) -> Self {
        var copy = self
        let clamped = Corners(
            max(0, radii.topLeft),
            max(0, radii.topRight),
            max(0, radii.bottomRight),
            max(0, radii.bottomLeft)
        )
        copy.applyParityClip { target in
            target.clipCorners = clamped
            target.clipRadius = clamped.maxMagnitude
        }
        return copy
    }

    public func clipSoft(_ fade: Float) -> Self {
        let f = max(0, fade)
        var copy = self
        copy.applyParityClip { target in
            target.clipFade = SIMD4<Float>(f, f, f, f)
        }
        return copy
    }

    public func clipFade(left: Float = 0, top: Float = 0, right: Float = 0, bottom: Float = 0) -> Self {
        var copy = self
        copy.applyParityClip { target in
            target.clipFade = SIMD4<Float>(max(0, left), max(0, top), max(0, right), max(0, bottom))
        }
        return copy
    }

    public func clipFadeLinear(left: Float = 0, top: Float = 0, right: Float = 0, bottom: Float = 0) -> Self {
        var copy = self
        copy.applyParityClip { target in
            target.clipFade = SIMD4<Float>(-max(0, left), -max(0, top), -max(0, right), -max(0, bottom))
        }
        return copy
    }

    public func hoverGroup() -> Self {
        var copy = self
        copy.isHoverGroup = true
        return copy
    }

    public func hoverGroupShared(_ key: String) -> Self {
        var copy = self
        copy.isHoverGroup = true
        copy.hoverGroupShare = key
        return copy
    }

    public func groupOpacity(_ rest: Float, _ hovered: Float) -> Self {
        var copy = self
        copy.groupOpacity = (rest.clamped(to: 0...1), hovered.clamped(to: 0...1))
        return copy
    }

    public func groupColor(_ color: Color) -> Self {
        var copy = self
        copy.groupColor = color
        return copy
    }

    public func hoverAlone() -> Self {
        var copy = self
        copy.isHoverAlone = true
        return copy
    }

    public func instantChanges() -> Self {
        var copy = self
        copy.hasInstantChanges = true
        return copy
    }

    public func animatedChanges() -> Self {
        var copy = self
        copy.hasAnimatedChanges = true
        return copy
    }

    public func enterDelay(_ seconds: Float) -> Self {
        var copy = self
        copy.enterDelay = seconds.isFinite ? max(0, seconds) : 0
        return copy
    }

    public func looping(_ spec: LoopSpec) -> Self {
        var copy = self
        copy.loopingSpec = spec
        return copy
    }

    public func cycle(_ c: Cycle) -> Self {
        looping(.cycle(c))
    }

    /// A finite opacity/scale sequence on the shared render clock. The final pose holds;
    /// reduced motion and explicit settle land it immediately. A new key replays it; dropping
    /// the loop and putting it back carries on from where it was.
    public func sequence(_ frames: MotionSequence) -> Self {
        looping(.sequence(frames))
    }

    public func scrollEdgeFade(_ width: Float) -> Self {
        scrollFade(.strength(width))
    }

    public func scrollMargin(_ pts: Float) -> Self {
        var copy = self
        copy.scrollMarginPts = max(0, pts)
        return copy
    }

    public func above(_ key: String, gutter: Float = 0) -> Self {
        anchored(key, side: .top, align: .start, gap: gutter)
    }

    public func anchored(_ key: String, side: Side, align: Align = .start, gap: Float = 0) -> Self {
        var copy = self
        copy.layout.isAbsolute = true
        copy.anchor = Anchor(key: key, side: side, align: align, gap: gap)
        return copy
    }

    public func anchoredFit(_ key: String, side: Side, align: Align = .start, gap: Float = 0) -> Self {
        var copy = anchored(key, side: side, align: align, gap: gap)
        copy.anchor?.fit = true
        return copy
    }

    public func anchoredUnscaled() -> Self {
        var copy = self
        copy.anchor?.unscaled = true
        return copy
    }

    public func anchoredRound() -> Self {
        var copy = self
        copy.anchor?.round = true
        return copy
    }

    public func shape(_ s: Shape) -> Self {
        var copy = self
        copy.shapes.append(s)
        return copy
    }

    // MARK: - Typography Modifiers

    public func font(_ style: TextStyle) -> Self {
        var copy = self
        copy.textStyle = style
        return copy
    }

    public func size(_ fontSize: Float) -> Self {
        var copy = self
        copy.textStyle.size = fontSize
        return copy
    }

    public func weight(_ w: Float) -> Self {
        var copy = self
        copy.textStyle.weight = w
        return copy
    }

    public func bold() -> Self { weight(700) }
    public func semibold() -> Self { weight(600) }
    public func medium() -> Self { weight(500) }
    public func mono() -> Self { var c = self; c.textStyle.family = .monospace; return c }
    public func italic(_ on: Bool = true) -> Self { var c = self; c.textStyle.italic = on; return c }
    public func lineHeight(_ lh: Float) -> Self { var c = self; c.textStyle.lineHeight = lh; return c }
    public func letterSpacing(_ spacing: Float) -> Self { var c = self; c.textStyle.letterSpacing = spacing; return c }
    public func tracking(_ spacing: Float) -> Self { letterSpacing(spacing) }
    public func textAlign(_ align: TextAlign) -> Self { var c = self; c.textStyle.align = align; return c }
    public func noWrap() -> Self { var c = self; c.textStyle.wrap = .noWrap; return c }
    public func wrapText() -> Self { var c = self; c.textStyle.wrap = .wrap; return c }
    public func wrap(_ mode: TextWrap) -> Self { var c = self; c.textStyle.wrap = mode; return c }
    public func ellipsis() -> Self {
        var c = self
        c.textStyle.wrap = .ellipsis
        c.layout.flexShrink = 1.0
        c.layout.minWidth = .points(0)
        return c
    }

    /// Sets the element's resolving writing direction (`ltr`, `rtl`, or `auto` first-strong).
    public func dir(_ direction: Direction) -> Self {
        var copy = self
        copy.explicitDir = direction
        return copy
    }

    /// Keeps child order and horizontal padding/alignment unmirrored in RTL,
    /// resetting children back to LTR unless explicitly overridden.
    public func unmirrored() -> Self {
        var copy = self
        copy.isUnmirrored = true
        return copy
    }

    /// Mirrors this element horizontally in RTL (e.g. directional icons or rotations).
    public func mirrorInRtl(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.mirrorInRtl = enabled
        return copy
    }

    /// Resolves paragraph direction independently per paragraph instead of across the whole block.
    /// Multi-paragraph static text with mixed paragraph directions splits into keyed column children.
    public func dirByParagraph() -> Self {
        var copy = self
        copy.textDirByParagraph = true
        guard !copy.isSecure,
              copy.liveText == nil,
              copy.handlers.editLens == nil,
              copy.textStyle.wrap != .ellipsis else {
            return copy
        }
        if let spans = copy.richSpans {
            let paraSpans = splitRichSpansIntoParagraphs(spans)
            let dirs = paraSpans.map { Direction.of($0.map(\.text).joined()) }
            if paraSpans.count >= 2 && Set(dirs).count > 1 {
                copy.role = .group
                copy.layout.direction = .column
                copy.plainText = nil
                copy.richSpans = nil
                copy.children = paraSpans.enumerated().map { idx, slice in
                    var child = El<State>(direction: .row)
                    child.keyId = "p\(idx)"
                    child.role = .text
                    child.richSpans = slice
                    child.plainText = slice.map(\.text).joined()
                    child.textStyle = copy.textStyle
                    child.textColor = copy.textColor
                    child.explicitDir = .auto
                    return child
                }
            }
            return copy
        }
        if let content = copy.plainText {
            let ranges = splitParagraphUTF8Ranges(content)
            if ranges.count >= 2 {
                let bytes = Array(content.utf8)
                let slices = ranges.map { String(decoding: bytes[$0], as: UTF8.self) }
                let dirs = slices.map { Direction.of($0) }
                if Set(dirs).count > 1 {
                    copy.role = .group
                    copy.layout.direction = .column
                    copy.plainText = nil
                    copy.children = slices.enumerated().map { idx, slice in
                        var child = El<State>(direction: .row)
                        child.keyId = "p\(idx)"
                        child.role = .text
                        child.plainText = slice
                        child.textStyle = copy.textStyle
                        child.textColor = copy.textColor
                        child.explicitDir = .auto
                        return child
                    }
                }
            }
        }
        return copy
    }

    public func color(_ c: Color) -> Self {
        var copy = self
        copy.textColor = c
        return copy
    }

    public func placeholder(_ p: String, color: Color? = nil) -> Self {
        var copy = self
        copy.placeholder = p
        if let color { copy.placeholderColor = color }
        return copy
    }

    /// Lays this field's placeholder out in `style` rather than the field's own (`El::placeholder_font`, `#896`).
    public func placeholderFont(_ style: TextStyle) -> Self {
        var copy = self
        copy.placeholderFont = style
        return copy
    }

    /// Breaks this text's lines greedily even when `TextSystem.setPrettyWrap(true)` is active (`El::wrap_greedy`, `#882`).
    public func wrapGreedy(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.isWrapGreedy = enabled
        return copy
    }

    public func caret(_ color: Color, selection: Color? = nil) -> Self {
        var copy = self
        copy.caretColor = color
        if let selection { copy.selectionColor = selection }
        return copy
    }

    // MARK: - Motion & Live Modifiers

    public func animateLayout(_ spring: Spring = MotionTokens.SETTLE) -> Self {
        var copy = self
        copy.layoutAnim = LayoutAnim(spring: spring)
        return copy
    }

    public func animateLayout(_ spec: LayoutAnim) -> Self {
        var copy = self
        copy.layoutAnim = spec
        return copy
    }

    public func animate(_ spring: Spring = MotionTokens.SNAPPY) -> Self {
        var copy = self
        copy.styleSpring = spring
        return copy
    }

    public func transition(_ t: Transition) -> Self {
        var copy = self
        copy.transition = t
        return copy
    }

    public func liveOpacity(_ binding: Binding<Float>) -> Self {
        bindLive(.opacity, binding)
    }

    public func liveScale(_ binding: Binding<Float>) -> Self {
        bindLive(.scale, binding)
    }

    public func liveBlur(_ binding: Binding<Float>) -> Self {
        bindLive(.blur, binding)
    }

    public func liveOffset(_ binding: Binding<Vec2>) -> Self {
        bindLive(.offset, binding)
    }

    public func liveFill(_ binding: Binding<Color>) -> Self {
        bindLive(.fill, binding)
    }

    public func liveRect(_ binding: Binding<MotionRect>) -> Self {
        bindLive(.rect, binding)
    }

    public func liveTrim(_ binding: Binding<Vec2>) -> Self {
        bindLive(.trim, binding)
    }

    /// Binds this element's text color to a live `Color` source (`El::live_text_color`).
    public func liveTextColor(_ binding: Binding<Color>) -> Self {
        bindLive(.textColor, binding)
    }

    /// Binds this element's border color to a live `Color` source (`El::live_border`).
    public func liveBorder(_ binding: Binding<Color>) -> Self {
        bindLive(.borderColor, binding)
    }

    /// Binds this element's shadow color to a live `Color` source (`El::live_shadow`).
    public func liveShadow(_ binding: Binding<Color>) -> Self {
        bindLive(.shadowColor, binding)
    }

    /// Binds both stops of this element's vertical gradient to live `Color` sources (`El::live_gradient`).
    public func liveGradient(_ top: Binding<Color>, _ bottom: Binding<Color>) -> Self {
        bindLive(.gradientTop, top).bindLive(.gradientBottom, bottom)
    }

    /// Names this element explicitly in tooling traces (`El::trace_name`).
    public func traceName(_ name: String) -> Self {
        var copy = self
        copy.traceNameValue = name
        return copy
    }

    /// Assigns the `(class, host)` metadata namespace in tooling traces (`El::trace_namespace`).
    public func traceNamespace(_ className: String, _ host: String) -> Self {
        var copy = self
        copy.traceNamespaceValue = (className, host)
        return copy
    }

    private func bindLive<T: LiveValue>(_ target: BoundLiveProperty.Target, _ b: Binding<T>) -> Self {
        var copy = self
        let entry = BoundLiveProperty(target: target, source: b.live.source, spring: b.spring, restSpring: b.restSpring)
        copy.liveBindings.removeAll { $0.target == target }
        copy.liveBindings.append(entry)
        return copy
    }

    // MARK: - Interaction, Focus & Accessibility

    public func hover(_ bg: Color) -> Self {
        var copy = self
        copy.hoverBg = bg
        return copy
    }

    /// Curves used by this element's hover fill and `hoverGroup` transitions (`El::hover_motion`).
    public func hoverMotion(_ enter: Anim<Float>, _ exit: Anim<Float>) -> Self {
        var copy = self
        copy.hoverMotionSpec = (enter, exit)
        return copy
    }

    /// Curves used by this element's hover fill and `hoverGroup` transitions (`Spring` overload).
    public func hoverMotion(_ enter: Spring, _ exit: Spring) -> Self {
        hoverMotion(Anim(curve: .spring(enter)), Anim(curve: .spring(exit)))
    }

    /// Default hover curves for this element and descendants without their own `hoverMotion` (`El::hover_motion_within`).
    public func hoverMotionWithin(_ enter: Anim<Float>, _ exit: Anim<Float>) -> Self {
        var copy = self
        copy.hoverWithinSpec = (enter, exit)
        return copy
    }

    /// Default hover curves for this element and descendants (`Spring` overload).
    public func hoverMotionWithin(_ enter: Spring, _ exit: Spring) -> Self {
        hoverMotionWithin(Anim(curve: .spring(enter)), Anim(curve: .spring(exit)))
    }

    /// The `(enter, exit)` hover curves attached by `hoverMotionWithin` (`El::hover_within_curves`).
    public func hoverWithinCurves() -> (enter: Anim<Float>, exit: Anim<Float>)? {
        hoverWithinSpec
    }

    /// Adds children's premultiplied colors (`Blend::PlusLighter`) while a direct child has intermediate opacity (`El::dissolve`).
    public func dissolve() -> Self {
        var copy = self
        copy.isDissolve = true
        return copy
    }

    /// Displays `pixels` sized/stretched to fill this element's box (`El::pixels`).
    public func pixels(_ pixels: Pixels) -> Self {
        var copy = self
        copy.pixelsPayload = pixels
        copy.pixelsFitMode = nil
        return copy
    }

    /// Displays `pixels` centered at its own aspect ratio (`SurfaceFit.fit` or `.fill`, `El::pixels_fit`).
    public func pixelsFit(_ pixels: Pixels, _ fit: SurfaceFit) -> Self {
        var copy = self
        copy.pixelsPayload = pixels
        copy.pixelsFitMode = fit
        return copy
    }

    public func press(_ bg: Color) -> Self {
        var copy = self
        copy.pressBg = bg
        return copy
    }

    /// Colors text, icons, and vector shapes in this element's subtree while pressed (`El::press_color`).
    public func pressColor(_ color: Color) -> Self {
        var copy = self
        copy.pressColor = color
        return copy
    }

    public func pressScale(_ factor: Float = 0.97) -> Self {
        var copy = self
        copy.pressScaleFactor = factor
        return copy
    }

    public func focusRing(_ color: Color, offset: Float = 2.0) -> Self {
        var copy = self
        copy.focusRingColor = color
        copy.focusRingWidth = 2.0
        copy.focusRingOffset = offset
        copy.focusable = true
        return copy
    }

    public func focusRing(_ width: Float, offset: Float, _ color: Color) -> Self {
        var copy = self
        copy.focusRingColor = color
        copy.focusRingWidth = width
        copy.focusRingOffset = offset
        return copy
    }

    public func focusable(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.focusable = enabled
        copy.focusOptOut = !enabled
        return copy
    }

    public func focused(_ requested: Bool = true) -> Self {
        var copy = self
        copy.isFocusRequested = requested
        return copy
    }

    public func tabIndex(_ order: Int) -> Self {
        var copy = self
        copy.tabIndex = order
        return copy
    }

    public func defaultButton(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.isDefaultButton = enabled
        return copy
    }

    public func noFocusRing(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.noFocusRing = enabled
        return copy
    }

    public func focusHighlight(_ color: Color) -> Self {
        var copy = self
        copy.focusHighlightColor = color
        return copy
    }

    /// Paint-only background highlight over UTF-8 byte ranges of text (`El::text_highlight`).
    public func textHighlight(_ highlight: TextHighlight) -> Self {
        var copy = self
        var list = copy.textHighlights ?? []
        list.append(highlight)
        copy.textHighlights = list
        return copy
    }

    /// Attaches multiple paint-only text highlights (`El::text_highlights`).
    public func textHighlights(_ highlights: [TextHighlight]) -> Self {
        var copy = self
        var list = copy.textHighlights ?? []
        list.append(contentsOf: highlights)
        copy.textHighlights = list
        return copy
    }

    public func focusWithinRing(_ color: Color, width: Float = 2.0, offset: Float = 2.0) -> Self {
        var copy = self
        copy.focusWithinRing = (width, offset, color)
        return copy
    }

    public func focusWithinFlat(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.focusWithinFlat = enabled
        return copy
    }

    public func focusFollows(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.isFocusFollowsSelection = enabled
        return copy
    }

    public func autofocus(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.autofocus = enabled
        if enabled { copy.focusable = true }
        return copy
    }

    public func focusSelected(_ selected: Bool = true) -> Self {
        var copy = self
        copy.isFocusSelected = selected
        return copy
    }

    public func revealSelected(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.isRevealSelected = enabled
        return copy
    }

    // MARK: - Growth & Virtualization Modifiers

    public func growth(_ spec: GrowthSpec = .default) -> Self {
        var copy = self
        copy.growthSpec = spec
        return copy
    }

    public func streaming(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.isStreaming = enabled
        return copy
    }

    public func reveal(_ wordFade: Float) -> Self {
        var copy = self
        copy.textReveal = max(0, wordFade)
        return copy
    }

    public func arrivesWhole() -> Self {
        var copy = self
        copy.isArrivesWhole = true
        return copy
    }

    public func foldGlide(_ spring: Spring) -> Self {
        var copy = self
        copy.isArrivesWhole = true
        copy.foldGlideSpec = FoldGlide(spring: spring, feather: copy.foldGlideSpec?.feather)
        return copy
    }

    public func foldFeather(_ pt: Float) -> Self {
        var copy = self
        if var g = copy.foldGlideSpec {
            g.feather = max(0, pt)
            copy.foldGlideSpec = g
        }
        return copy
    }

    public func virtualize(_ estimatedRowHeight: Float = 32, file: String = #fileID, line: Int = #line) -> Self {
        var copy = self
        copy.virtualEstimate = max(1, estimatedRowHeight)
        if copy.virtualizeSite == nil {
            copy.virtualizeSite = "\(file):\(line)"
        }
        return copy
    }

    public func virtualRows(
        count: Int,
        estimatedRowHeight: Float,
        key: @escaping (State, Int) -> String,
        build: @escaping (State, Int) -> El<State>
    ) -> Self {
        var copy = self
        copy.virtualRowsSource = VirtualRowSource(count: count, key: key, build: build)
        return copy.virtualize(estimatedRowHeight)
    }

    public func virtualRows(
        _ count: Int,
        _ estimatedRowHeight: Float,
        key: @escaping (State, Int) -> String,
        build: @escaping (State, Int) -> El<State>
    ) -> Self {
        virtualRows(count: count, estimatedRowHeight: estimatedRowHeight, key: key, build: build)
    }

    public func virtualRowsVersion<H: Hashable>(_ version: H) -> Self {
        var copy = self
        var hasher = Hasher()
        hasher.combine(version)
        let signed = hasher.finalize()
        copy.virtualRowsVersionHash = UInt64(bitPattern: Int64(signed))
        return copy
    }

    public func onVisibleRows(_ handler: @escaping (inout State, Range<Int>) -> Bool) -> Self {
        var copy = self
        copy.handlers.onVisibleRows = handler
        return copy
    }

    public func focusGroup(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.focusGroup = enabled
        return copy
    }

    public func modal(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.isModal = enabled
        return copy
    }

    public func modal(clickOutside: Bool, dismiss: @escaping (inout State) -> Void) -> Self {
        var copy = self
        copy.isModal = true
        copy.modalClickOutside = clickOutside
        copy.handlers.modalDismiss = { s, _ in dismiss(&s) }
        return copy
    }

    public func modalTx(clickOutside: Bool, dismiss: @escaping (inout State, inout Tx) -> Void) -> Self {
        var copy = self
        copy.isModal = true
        copy.modalClickOutside = clickOutside
        copy.handlers.modalDismiss = dismiss
        return copy
    }

    public func modalClickOutside(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.modalClickOutside = enabled
        return copy
    }

    public func inert(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.isInert = enabled
        return copy
    }

    /// Marks the drawn, ancestor-clipped rectangle as an explicit native overlay input hit region (`El::hit`).
    public func hit(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.isHit = enabled
        return copy
    }

    public func secure(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.isSecure = enabled
        if enabled {
            if !copy.textLinks.isEmpty && copy.handlers.editLens == nil && copy.role == .text {
                copy.focusable = false
            }
            copy.textLinks = []
            copy.handlers.onLink = nil
            copy.handlers.onLinkSecondary = nil
            copy.runtimeExtras[Self.selectableExtraKey] = false
        }
        return copy
    }

    public func revealed(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.isRevealed = enabled
        return copy
    }

    public func role(_ r: ElementRole) -> Self { var c = self; c.role = r; return c }
    public func label(_ l: String) -> Self { var c = self; c.a11yLabel = l; return c }
    /// Zero-copy `label` from a compile-time `StaticString` literal (`El::label_static`).
    public func labelStatic(_ label: StaticString) -> Self { var c = self; c.a11yLabelCow = .staticString(label); return c }
    public func help(_ h: String) -> Self {
        var c = self
        if !h.isEmpty || c._cold != nil {
            c.a11yHelp = h.isEmpty ? nil : h
            c.isHelpWhenTruncated = false
        }
        return c
    }
    public func helpWhenTruncated(_ h: String) -> Self {
        var c = help(h)
        if !h.isEmpty {
            c.isHelpWhenTruncated = true
        }
        return c
    }
    public func helpRow(_ text: String) -> Self {
        var c = self
        if let existing = c.a11yHelp, !existing.isEmpty {
            c.a11yHelp = existing + String(runeHelpRowSeparator) + text
        } else {
            return c.help(text)
        }
        return c
    }
    public func helpKeys(_ keys: [String]) -> Self {
        var c = self
        guard let existing = c.a11yHelp, !existing.isEmpty else { return c }
        var appended = existing
        for key in keys where !key.isEmpty {
            appended.append(runeHelpKeySeparator)
            appended.append(contentsOf: key)
        }
        c.a11yHelp = appended
        return c
    }
    public func helpSide(_ side: Side) -> Self {
        var c = self
        c.helpSide = (side == .bottom) ? nil : side
        return c
    }
    public func helpAbove() -> Self {
        helpSide(.top)
    }
    public func selected(_ val: String?) -> Self { var c = self; c.a11ySelected = val; return c }
    public func expanded(_ val: Bool?) -> Self { var c = self; c.a11yExpanded = val; return c }
    /// Outline or heading depth for accessibility (1-based ARIA `aria-level`, `El::level`).
    public func level(_ level: Int) -> Self { var c = self; c.a11yLevel = level; return c }
    public func headingLevel(_ l: Int) -> Self { var c = self; c.role = .heading; c.a11yLevel = l; return c }
    public func itemSelected(_ on: Bool = true) -> Self { var c = self; c.itemSelected = on; return c }
    public func focusReturn(_ trigger: String) -> Self { var c = self; c.focusReturnKey = trigger; return c }

    public func description(_ text: String) -> Self { var c = self; c.a11yDescription = text; return c }
    /// Zero-copy `description` from a compile-time `StaticString` literal (`El::description_static`).
    public func descriptionStatic(_ text: StaticString) -> Self { var c = self; c.a11yDescriptionCow = .staticString(text); return c }
    public func activeDescendant(_ key: String) -> Self { var c = self; c.a11yActiveDescendant = key; return c }
    public func a11yValue(_ text: String) -> Self { var c = self; c.a11yValue = text; return c }

    public func rangeValue(_ value: Double, min: Double, max: Double) -> Self {
        var c = self
        let step = c.a11yRange?.step
        c.a11yRange = A11yRange(value: value, min: min, max: max, step: step)
        return c
    }

    @_disfavoredOverload
    public func rangeValue(_ value: Float, min: Float, max: Float) -> Self {
        rangeValue(Double(value), min: Double(min), max: Double(max))
    }

    public func rangeStep(_ step: Double) -> Self {
        var c = self
        var r = c.a11yRange ?? A11yRange(value: 0, min: 0, max: 0)
        r.step = step
        c.a11yRange = r
        return c
    }

    @_disfavoredOverload
    public func rangeStep(_ step: Float) -> Self {
        rangeStep(Double(step))
    }

    public func checked(_ on: Bool) -> Self {
        var c = self
        c.a11yChecked = on ? .trueState : .falseState
        return c
    }

    public func checkedMixed() -> Self {
        var c = self
        c.a11yChecked = .mixed
        return c
    }

    public func disabled(_ on: Bool = true) -> Self {
        var c = self
        c.a11yDisabled = on
        if on {
            c.focusable = false
            c.focusOptOut = true
        }
        return c
    }

    public func a11yHidden() -> Self {
        var c = self
        c.isA11yHidden = true
        return c
    }

    public func labelledBy(_ key: String) -> Self { var c = self; c.a11yLabelledBy = key; return c }
    public func describedBy(_ key: String) -> Self { var c = self; c.a11yDescribedBy = key; return c }
    public func busy(_ on: Bool = true) -> Self { var c = self; c.a11yBusy = on; return c }
    public func invalid(_ on: Bool = true) -> Self { var c = self; c.a11yInvalid = on; return c }
    public func readOnly(_ on: Bool = true) -> Self { var c = self; c.a11yReadOnly = on; return c }
    public func sorted(_ ascending: Bool?) -> Self { var c = self; c.a11ySorted = ascending; return c }
    public func liveRegion(_ live: LiveRegionPoliteness?) -> Self { var c = self; c.a11yLive = live; return c }
    public func positionInSet(_ position: Int, size: Int) -> Self { var c = self; c.a11yPosInSet = (position, size); return c }
    public func shortcutHint(_ keys: String) -> Self { var c = self; c.a11yShortcutHint = keys; return c }

    /// The pointer shape shown while hovering or pressing this element (`el::layout::cursor`).
    public func cursor(_ cursor: Cursor) -> Self {
        var c = self
        c.runtimeExtras["cursor"] = cursor
        return c
    }

    internal var attachedCursor: Cursor? {
        runtimeExtras["cursor"] as? Cursor
    }

    public func href(_ url: String) -> Self {
        var c = self
        c.a11yHref = url
        c.role = .link
        c.focusable = true
        c.handlers.onClick = { _, tx in
            if url.contains(":") { _ = try? tx.openUrl(url) }
        }
        return c
    }

    /// Reads the accessibility/link URL configured on this element (`El::link_url`).
    public var linkURL: String? { a11yHref }

    /// Configures a link destination URL (alias of `href(_:)` with pointer cursor).
    public func linkURL(_ url: String) -> Self {
        var copy = href(url)
        if copy.attachedCursor == nil {
            copy = copy.cursor(.pointer)
        }
        return copy
    }

    /// Solid fill applied while keyboard-focused (`El::focus_fill`).
    public func focusFill(_ color: Color) -> Self {
        var copy = self
        copy.focusFillColor = color
        return copy
    }

    /// Pressing this overlay forwards focus to the focusable element underneath it (`El::press_focuses_below`).
    public func pressFocusesBelow(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.pressFocusesBelow = enabled
        return copy
    }

    /// Marks this element as not initiating native window background drag (`El::no_window_drag`).
    public func noWindowDrag(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.noWindowDrag = enabled
        return copy
    }

    /// Marks a custom editor's caret element so IME activates there when no `textInput` is focused (`El::ime_cursor`).
    public func imeCursor(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.isImeCursor = enabled
        return copy
    }

    /// With `imeCursor`: on macOS, while this caret holds the input method, Option is treated as Alt (`El::ime_option_as_alt`).
    public func imeOptionAsAlt(_ on: Bool = true) -> Self {
        var copy = self
        if on || copy._cold != nil {
            copy.isImeOptionAsAlt = on
        }
        return copy
    }

    /// Fires when pressing empty non-interactive background inside this element (`El::on_background_press`).
    public func onBackgroundPress(_ handler: @escaping (inout State) -> Void) -> Self {
        onBackgroundPress { state, _, _ in handler(&state) }
    }

    /// Fires with transaction access when pressing background inside this element (`El::on_background_press_tx`).
    public func onBackgroundPressTx(_ handler: @escaping (inout State, inout Tx) -> Void) -> Self {
        onBackgroundPress { state, _, tx in handler(&state, &tx) }
    }

    /// Fires with full press coordinates when pressing background inside this element.
    public func onBackgroundPress(_ handler: @escaping (inout State, PointerPress, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onBackgroundPress = handler
        copy.focusable = false
        copy.focusOptOut = true
        return copy
    }

    /// Handles secondary (right-click) press in element-local coordinates (`El::on_secondary_press_local`).
    public func onSecondaryPressLocal(_ handler: @escaping (inout State, PointerPress, inout Tx) -> Void) -> Self {
        onSecondaryClick(handler)
    }

    /// Handles secondary (right-click) press with `PointerEvent` coordinates (`El::on_secondary_press_local`).
    @_disfavoredOverload
    public func onSecondaryPressLocal(_ handler: @escaping (inout State, PointerEvent, inout Tx) -> Void) -> Self {
        onSecondaryClick { state, press, tx in
            let ev = PointerEvent(x: press.local.x, y: press.local.y, windowX: press.window.x, windowY: press.window.y)
            handler(&state, ev, &tx)
        }
    }

    /// Observes pointer movement in element-local coordinates (`El::on_pointer_move_local`).
    public func onPointerMoveLocal(_ handler: @escaping (inout State, PointerPress, inout Tx) -> Void) -> Self {
        onPointerMove(handler)
    }

    /// Observes pointer movement with `PointerEvent` coordinates (`El::on_pointer_move_local`).
    @_disfavoredOverload
    public func onPointerMoveLocal(_ handler: @escaping (inout State, PointerEvent, inout Tx) -> Void) -> Self {
        onPointerMove { state, press, tx in
            let ev = PointerEvent(x: press.local.x, y: press.local.y, windowX: press.window.x, windowY: press.window.y)
            handler(&state, ev, &tx)
        }
    }

    /// Drag callback that does not read or mutate `State` (`El::on_drag_any`).
    public func onDragAny(_ handler: @escaping (Drag, inout Tx) -> Void) -> Self {
        onDrag { _, drag, tx in handler(drag, &tx) }
    }

    // MARK: - Event Handlers

    /// A primary mouse press activates the element on down. Touch, keyboard, and
    /// accessibility activation retain their ordinary click timing.
    public func pressOnDown() -> Self {
        var copy = self
        copy.handlers.pressOnDown = true
        return copy
    }

    public func onClick(_ handler: @escaping (inout State) -> Void) -> Self {
        onClick { state, _ in handler(&state) }
    }

    public func onClick(_ handler: @escaping (inout State, inout Tx) -> Void) -> Self {
        var copy = self
        if !copy.a11yDisabled && !copy.focusOptOut { copy.focusable = true }
        if copy.role == .group { copy.role = .button }
        copy.handlers.onClick = handler
        return copy
    }

    public func onClickPress(_ handler: @escaping (inout State, PointerPress, inout Tx) -> Void) -> Self {
        var copy = self
        if !copy.a11yDisabled && !copy.focusOptOut { copy.focusable = true }
        if copy.role == .group { copy.role = .button }
        copy.handlers.onClickPress = handler
        return copy
    }

    public func onDoubleClick(_ handler: @escaping (inout State, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onDoubleClick = handler
        return copy
    }

    public func onSecondaryClick(_ handler: @escaping (inout State, PointerPress, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onSecondaryClick = handler
        return copy
    }

    /// Handles a middle-button click (`El::on_middle_press`): fires on middle release inside when
    /// not handled by `pointerButtons` opt-in or a link, without changing focus or starting drags.
    public func onMiddlePress(_ handler: @escaping (inout State, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onMiddlePress = handler
        return copy
    }

    /// Makes `link.byteRange` of this text pressable (`crates/rune/src/el/text.rs:397`).
    /// Only the range's shaped glyph boxes take the pointer; each link is a Tab stop that Return or Space presses.
    public func link(_ link: TextLink) -> Self {
        var copy = self
        guard copy.handlers.editLens == nil, !copy.isSecure else { return copy }
        guard copy.plainText != nil || copy.richSpans != nil || copy.liveText != nil || copy.role == .text else {
            return copy
        }
        var links = copy.textLinks
        links.append(link)
        copy.textLinks = links
        copy.focusable = true
        return copy
    }

    /// Registers an activation handler invoked with the pressed/focused `TextLink.id` (`crates/rune/src/el/text.rs:409`).
    public func onLink(_ handler: @escaping (inout State, String, inout Tx) -> Void) -> Self {
        var copy = self
        guard copy.handlers.editLens == nil, !copy.isSecure else { return copy }
        guard copy.plainText != nil || copy.richSpans != nil || copy.liveText != nil || copy.role == .text else {
            return copy
        }
        copy.handlers.onLink = handler
        return copy
    }

    /// Convenience `onLink` overload when no `Tx` mutation is needed.
    public func onLink(_ handler: @escaping (inout State, String) -> Void) -> Self {
        onLink { state, id, _ in handler(&state, id) }
    }

    /// Registers a secondary-click handler invoked with the `TextLink.id` and press coordinates (`crates/rune/src/el/text.rs:419`).
    public func onLinkSecondary(_ handler: @escaping (inout State, String, PointerPress, inout Tx) -> Void) -> Self {
        var copy = self
        guard copy.handlers.editLens == nil, !copy.isSecure else { return copy }
        guard copy.plainText != nil || copy.richSpans != nil || copy.liveText != nil || copy.role == .text else {
            return copy
        }
        copy.handlers.onLinkSecondary = handler
        return copy
    }

    public func onPointerDown(_ handler: @escaping (inout State, PointerPress, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onPointerDown = handler
        return copy
    }

    public func onPointerUp(_ handler: @escaping (inout State, PointerPress, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onPointerUp = handler
        return copy
    }

    /// Observes pointer movement over this element without creating a native overlay input region (`El::on_pointer_move`).
    public func onPointerMove(_ handler: @escaping (inout State, PointerPress, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onPointerMove = handler
        return copy
    }

    /// Observes pointer movement over this element without reading `State` (`El::on_pointer_move_any`).
    public func onPointerMoveAny(_ handler: @escaping (PointerPress, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onPointerMove = { _, press, tx in handler(press, &tx) }
        return copy
    }

    /// Observes pointer movement with `PointerEvent` without reading `State`.
    @_disfavoredOverload
    public func onPointerMoveAny(_ handler: @escaping (PointerEvent, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onPointerMove = { _, press, tx in
            let ev = PointerEvent(x: press.local.x, y: press.local.y, windowX: press.window.x, windowY: press.window.y)
            handler(ev, &tx)
        }
        return copy
    }

    public func onHover(_ handler: @escaping (inout State, Bool, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onHover = handler
        return copy
    }

    /// Called with `true` when the pointer enters this element's visible rect and `false` when
    /// it leaves (descendants included). Never acts as a hit blocker (`El::on_hover_change`).
    public func onHoverChange(_ handler: @escaping (inout State, Bool, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onHoverChange = handler
        return copy
    }

    /// `onHoverChange` without reading app `State` (`El::on_hover_change_any`).
    public func onHoverChangeAny(_ handler: @escaping (Bool, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onHoverChange = { _, inside, tx in handler(inside, &tx) }
        return copy
    }

    /// Chains a state-agnostic `onHoverChange` handler after any existing `onHoverChange`,
    /// staying `liveOnly` only when both handlers request `liveOnly` (`El::chain_hover_change_any`).
    public func chainHoverChangeAny(_ handler: @escaping (Bool, inout Tx) -> Void) -> Self {
        var copy = self
        if let prev = copy.handlers.onHoverChange {
            copy.handlers.onHoverChange = { state, inside, tx in
                prev(&state, inside, &tx)
                let prevLive = tx.liveOnlyRequested
                tx.liveOnlyRequested = false
                handler(inside, &tx)
                tx.liveOnlyRequested = tx.liveOnlyRequested && prevLive
            }
        } else {
            copy.handlers.onHoverChange = { _, inside, tx in handler(inside, &tx) }
        }
        return copy
    }

    /// Delays `onHoverChange` enter/leave callbacks by `[enter, leave]` seconds.
    public func hoverDelays(enter: Float, leave: Float) -> Self {
        hoverDelays(Double(enter), Double(leave))
    }

    public func onDrag(_ handler: @escaping (inout State, Drag, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onDrag = handler
        return copy
    }

    /// Invoked when a drag gesture ends (`cancelled == true` if aborted via `Escape`).
    public func onDragEnd(_ handler: @escaping (inout State, Bool, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onDragEnd = handler
        return copy
    }

    // MARK: Outbound OS Drag-Out (`drag_out/mod.rs`)

    /// Marks this element as an OS drag source; `provider(state)` runs only when the pointer moves past the threshold.
    public func dragOut(_ provider: @escaping (State) -> DragItem?) -> Self {
        var copy = self
        copy.handlers.dragOut = provider
        return copy
    }

    /// Distance in points the pointer must travel after press before `dragOut` starts (defaults to `DragItem.defaultThreshold`, 4pt).
    public func dragThreshold(_ points: Float) -> Self {
        var copy = self
        copy.handlers.dragThreshold = max(0, points)
        return copy
    }

    /// Called once when an outbound OS drag session begins for this element.
    public func onDragStart(_ handler: @escaping (inout State, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onDragStart = handler
        return copy
    }

    /// Called once when an outbound OS drag session ends (paired 1:1 with `onDragStart`).
    public func onDragOutEnd(_ handler: @escaping (inout State, DragOutcome, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onDragOutEnd = handler
        return copy
    }

    // MARK: Per-Element OS File Drop (`el/drop.rs`)

    private mutating func ensureDropSpec() {
        if handlers.drop == nil {
            handlers.drop = DropSpec<State>()
        }
    }

    /// Accepts OS files dropped onto this element.
    public func onDropFiles(_ handler: @escaping (inout State, [URL], inout Tx) -> Void) -> Self {
        var copy = self
        copy.ensureDropSpec()
        copy.handlers.drop?.onDropFiles = handler
        return copy
    }

    /// Restricts which dragged files this drop zone accepts.
    public func acceptsFiles(_ predicate: @escaping (URL) -> Bool) -> Self {
        var copy = self
        copy.ensureDropSpec()
        copy.handlers.drop?.accepts = predicate
        return copy
    }

    /// Restricts accepted dropped files by extension (case-insensitive, leading dot optional).
    public func acceptsExtensions(_ extensions: [String]) -> Self {
        acceptsFiles { url in
            DropSpec<State>.matchesExtension(extensions, url: url)
        }
    }

    /// Notifies when matching dragged files enter (`true`) or leave (`false`) this drop zone.
    public func onDropHover(_ handler: @escaping (inout State, Bool, inout Tx) -> Void) -> Self {
        var copy = self
        copy.ensureDropSpec()
        copy.handlers.drop?.onDropHover = handler
        return copy
    }

    /// Called once per frame while matching dragged files move inside this drop zone (`tx.dropPoint` holds coordinates).
    public func onDropMove(_ handler: @escaping (inout State, [URL], inout Tx) -> Void) -> Self {
        var copy = self
        copy.ensureDropSpec()
        copy.handlers.drop?.onDropMove = handler
        return copy
    }

    /// Called when files rejected by `acceptsFiles`/`acceptsExtensions` are dropped on this drop zone.
    public func onDropRejected(_ handler: @escaping (inout State, [URL], inout Tx) -> Void) -> Self {
        var copy = self
        copy.ensureDropSpec()
        copy.handlers.drop?.onDropRejected = handler
        return copy
    }

    /// Notifies when dragged files with none matching enter (`true`) or leave (`false`) this drop zone.
    public func onDropRejectedHover(_ handler: @escaping (inout State, Bool, inout Tx) -> Void) -> Self {
        var copy = self
        copy.ensureDropSpec()
        copy.handlers.drop?.onDropRejectedHover = handler
        return copy
    }

    public func onKey(_ handler: @escaping (inout State, KeyEvent, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.handlers.onKey = handler
        return copy
    }

    /// Handles logical key releases on the focused element, its ancestors, or root/modal (`El::on_key_up`).
    public func onKeyUp(_ handler: @escaping (inout State, KeyEvent, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.handlers.onKeyUp = handler
        return copy
    }

    /// Handles a focused text field's key before `TextEdit` processes it; return `true` to consume (`El::on_input_key`).
    public func onInputKey(_ handler: @escaping (inout State, KeyEvent, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.handlers.onInputKey = handler
        return copy
    }

    public func onPhysicalInput(_ handler: @escaping (inout State, PhysicalInput, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.handlers.onPhysicalInput = handler
        return copy
    }

    public func onWheel(_ handler: @escaping (inout State, WheelEvent, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.handlers.onWheel = handler
        return copy
    }

    /// Handles trackpad pinch magnification gestures over this element (`El::on_magnify`).
    public func onMagnify(_ handler: @escaping (inout State, MagnifyEvent, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.handlers.onMagnify = handler
        return copy
    }

    /// Handles two-finger trackpad rotation gestures over this element (`El::on_rotate`).
    public func onRotate(_ handler: @escaping (inout State, RotateEvent, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.handlers.onRotate = handler
        return copy
    }

    /// Handles smart magnify (two-finger double tap) over this element (`El::on_smart_magnify`).
    public func onSmartMagnify(_ handler: @escaping (inout State, Float, Float, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.handlers.onSmartMagnify = handler
        return copy
    }

    /// Opts additional mouse buttons (such as `.middle`) into `onPress` and `onDrag` (`El::pointer_buttons`).
    public func pointerButtons<S: Sequence>(_ buttons: S) -> Self where S.Element == PointerButton {
        var copy = self
        var set = copy.handlers.pointerButtons ?? [.primary]
        for b in buttons { set.insert(b) }
        copy.handlers.pointerButtons = set
        return copy
    }

    /// Slider/stepper keyboard increments while focused (`El::on_step`): Left/Down `-1`, Right/Up `+1`, PageDown `-10`, PageUp `+10`.
    public func onStep(_ handler: @escaping (inout State, Int, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onStep = handler
        copy.focusable = true
        if copy.role == .group { copy.role = .slider }
        return copy
    }

    /// Slider/stepper Home (`false`) and End (`true`) limit handler (`El::on_step_limit`).
    public func onStepLimit(_ handler: @escaping (inout State, Bool, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onStepLimit = handler
        return copy
    }

    /// Called with a `Tx` when this element's screen `[x, y, width, height]` moves (`El::on_screen_layout_tx`).
    public func onScreenLayoutTx(_ handler: @escaping (inout State, [Float], inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onScreenLayout = handler
        return copy
    }
    /// Handles paste text at root/modal level or on an element (`El::on_paste`).
    public func onPaste(_ handler: @escaping (inout State, String, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onPaste = handler
        return copy
    }

    /// Handles rich clipboard paste payloads (`El::on_paste_content`).
    public func onPasteContent(_ handler: @escaping (inout State, ClipboardContent, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onPasteContent = handler
        return copy
    }

    /// Inspects or consumes a clipboard paste targeted at this focused input (`El::on_input_paste`).
    /// Return `true` to consume the paste; return `false` to let `TextEdit` insert the text afterward.
    public func onInputPaste(_ handler: @escaping (inout State, ClipboardContent, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.handlers.onInputPaste = handler
        return copy
    }

    public func onChange(_ handler: @escaping (inout State, String, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onTextChange = handler
        return copy
    }

    /// Intercepts or observes edits to this `textInput` before/as they commit (`El::on_input_change`).
    public func onInputChange(_ handler: @escaping (inout State, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onInputChange = { state, _, tx in
            handler(&state, &tx)
            return false
        }
        return copy
    }

    /// Inspects an incoming text-input edit (`newText`) and returns `true` to reject/consume it.
    public func onInputChange(_ handler: @escaping (inout State, String, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.handlers.onInputChange = handler
        return copy
    }

    public func onSubmit(_ handler: @escaping (inout State, String, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onTextSubmit = handler
        return copy
    }

    /// Configures spellcheck state and listens for spellcheck toggles (`El::on_spellcheck`).
    public func onSpellcheck(_ enabled: Bool, _ handler: @escaping (inout State, Bool, inout Tx) -> Void) -> Self {
        var copy = self
        copy.isSpellcheck = enabled
        copy.handlers.onSpellcheckEnabled = enabled
        copy.handlers.onSpellcheck = handler
        return copy
    }

    /// Rebinds this `textInput` to a custom `(get, set)` accessor pair (`el::input::edit_access`).
    public func onEdit(
        get: @escaping (State) -> TextEdit,
        set: @escaping (inout State, TextEdit) -> Void
    ) -> Self {
        var copy = self
        copy.handlers.editLens = (get: get, set: set)
        return copy
    }

    /// Rebinds this `textInput` to a named `EditAccessor` (`el::input::edit_access`).
    public func onEdit(_ access: EditAccessor<State>) -> Self {
        onEdit(get: access.get, set: access.set)
    }

    /// Receives spellcheck dictionary language selection changes (`El::on_spellcheck_languages`).
    public func onSpellcheckLanguages(_ handler: @escaping (inout State, [String], inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onSpellcheckLanguages = handler
        return copy
    }

    /// Wraps this `textInput` in a bounded vertical auto-growing scroll container (`el::input::auto_grow`).
    public func autoGrow(minLines: Int = 1, maxLines: Int = 6) -> Self {
        Rune.autoGrow(self, minLines: minLines, maxLines: maxLines)
    }

    // MARK: - CSS Grid, Block, Flight & Spellcheck Modifiers

    public func block() -> Self {
        var copy = self
        copy.layout.displayMode = .block
        return copy
    }

    public func grid(
        columns: [GridTrack] = [],
        rows: [GridTrack] = [],
        autoFlow: GridAutoFlow = .row,
        justifyItems: AlignItems = .stretch
    ) -> Self {
        var copy = self
        copy.layout.displayMode = .grid
        var gs = copy.layout.grid ?? GridContainerStyle()
        if !columns.isEmpty { gs.templateColumns = columns }
        if !rows.isEmpty { gs.templateRows = rows }
        gs.autoFlow = autoFlow
        gs.justifyItems = justifyItems
        copy.layout.grid = gs
        return copy
    }

    public func gridTemplateColumns(_ tracks: [GridTrack]) -> Self {
        var copy = self
        copy.layout.displayMode = .grid
        var gs = copy.layout.grid ?? GridContainerStyle()
        gs.templateColumns = tracks
        copy.layout.grid = gs
        return copy
    }

    public func gridTemplateRows(_ tracks: [GridTrack]) -> Self {
        var copy = self
        copy.layout.displayMode = .grid
        var gs = copy.layout.grid ?? GridContainerStyle()
        gs.templateRows = tracks
        copy.layout.grid = gs
        return copy
    }

    public func gridAutoColumns(_ tracks: [GridTrack]) -> Self {
        var copy = self
        copy.layout.displayMode = .grid
        var gs = copy.layout.grid ?? GridContainerStyle()
        gs.autoColumns = tracks.isEmpty ? [.auto] : tracks
        copy.layout.grid = gs
        return copy
    }

    public func gridAutoRows(_ tracks: [GridTrack]) -> Self {
        var copy = self
        copy.layout.displayMode = .grid
        var gs = copy.layout.grid ?? GridContainerStyle()
        gs.autoRows = tracks.isEmpty ? [.auto] : tracks
        copy.layout.grid = gs
        return copy
    }

    public func gridAutoFlow(_ flow: GridAutoFlow) -> Self {
        var copy = self
        copy.layout.displayMode = .grid
        var gs = copy.layout.grid ?? GridContainerStyle()
        gs.autoFlow = flow
        copy.layout.grid = gs
        return copy
    }

    public func gridTemplateAreas(_ areas: [[String]]) -> Self {
        var copy = self
        copy.layout.displayMode = .grid
        var gs = copy.layout.grid ?? GridContainerStyle()
        gs.templateAreas = areas
        copy.layout.grid = gs
        return copy
    }

    public func justifyItems(_ align: AlignItems) -> Self {
        var copy = self
        var gs = copy.layout.grid ?? GridContainerStyle()
        gs.justifyItems = align
        copy.layout.grid = gs
        return copy
    }

    public func alignContent(_ justify: JustifyContent) -> Self {
        var copy = self
        var gs = copy.layout.grid ?? GridContainerStyle()
        gs.alignContent = justify
        copy.layout.grid = gs
        return copy
    }

    public func equalColumns(_ count: Int) -> Self {
        gridTemplateColumns(GridTrack.repeatCount(max(1, count), .fr(1)))
    }

    public func gridCell(column: Int) -> Self {
        gridColumn(.line(column + 1), row: .line(1))
    }

    public func gridColumn(_ start: GridPlacement, end: GridPlacement? = nil, row: GridPlacement? = nil) -> Self {
        var copy = self
        var gi = copy.layout.gridItem ?? GridItemStyle()
        gi.column = start
        if let end { gi.columnEnd = end }
        if let row { gi.row = row }
        copy.layout.gridItem = gi
        return copy
    }

    public func gridRow(_ start: GridPlacement, end: GridPlacement? = nil) -> Self {
        var copy = self
        var gi = copy.layout.gridItem ?? GridItemStyle()
        gi.row = start
        if let end { gi.rowEnd = end }
        copy.layout.gridItem = gi
        return copy
    }

    public func gridArea(_ name: String) -> Self {
        var copy = self
        var gi = copy.layout.gridItem ?? GridItemStyle()
        gi.area = name
        copy.layout.gridItem = gi
        return copy
    }

    public func justifySelf(_ align: AlignItems) -> Self {
        var copy = self
        var gi = copy.layout.gridItem ?? GridItemStyle()
        gi.justifySelf = align
        copy.layout.gridItem = gi
        return copy
    }

    public func flightId(_ id: String) -> Self {
        var copy = self
        copy.flightId = id
        return copy
    }

    public func matched(_ id: String, spring: Spring? = nil) -> Self {
        var copy = self
        copy.flightId = id
        copy.flightSpring = spring
        return copy
    }

    public func matchedCrop() -> Self {
        var copy = self
        copy.isMatchedCrop = true
        return copy
    }

    public func spellcheck(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.spellcheck = enabled
        return copy
    }
}

// MARK: - Top-Level Declarative Element Constructors (`row`, `col`, `el`, `text`, ...)

@inlinable
public func row<State>() -> El<State> {
    El<State>(direction: .row)
}

@inlinable
public func col<State>() -> El<State> {
    El<State>(direction: .column)
}

@inlinable
public func el<State>() -> El<State> {
    El<State>(direction: .row)
}

public func grid<State>(
    columns: [GridTrack] = [],
    rows: [GridTrack] = [],
    autoFlow: GridAutoFlow = .row
) -> El<State> {
    El<State>(direction: .row).grid(columns: columns, rows: rows, autoFlow: autoFlow)
}

public func block<State>() -> El<State> {
    El<State>(direction: .column).block()
}

public func terminalGrid<State>(
    columns: Int,
    cellWidth: Float,
    cellHeight: Float,
    rows: [TerminalGridRow]
) -> El<State> {
    var node = El<State>(direction: .row)
    node.terminalGridPayload = TerminalGrid(
        columns: columns,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        rows: rows
    )
    return node
}

extension El {
    /// Sets the terminal grid cursor cell (`column`, `row`) exposed as the grid's accessibility caret (`El::grid_caret`).
    public func gridCaret(_ column: Int, _ row: Int) -> Self {
        var copy = self
        guard var grid = copy.terminalGridPayload else { return copy }
        grid.caret = (column: column, row: row)
        copy.terminalGridPayload = grid
        return copy
    }
}

/// Zero-copy accessibility text storage distinguishing compile-time literals from owned `String` values (`#860`).
internal enum CowText: @unchecked Sendable, Equatable {
    case staticString(StaticString)
    case owned(String)

    var stringValue: String {
        switch self {
        case .staticString(let s):
            if s.hasPointerRepresentation {
                return s.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }
            }
            return String(s.unicodeScalar)
        case .owned(let s):
            return s
        }
    }

    var isEmpty: Bool {
        switch self {
        case .staticString(let s):
            return s.hasPointerRepresentation ? (s.utf8CodeUnitCount == 0) : false
        case .owned(let s):
            return s.isEmpty
        }
    }

    static func == (lhs: CowText, rhs: CowText) -> Bool {
        switch (lhs, rhs) {
        case (.staticString(let a), .staticString(let b)):
            if a.hasPointerRepresentation && b.hasPointerRepresentation &&
                a.utf8Start == b.utf8Start && a.utf8CodeUnitCount == b.utf8CodeUnitCount {
                return true
            }
            return lhs.stringValue == rhs.stringValue
        case (.owned(let a), .owned(let b)):
            return a == b
        default:
            return lhs.stringValue == rhs.stringValue
        }
    }
}

@inlinable
public func spacer<State>() -> El<State> {
    El<State>(direction: .row).grow(1.0)
}

public func rule<State>(_ thickness: Float = 1.0, _ color: Color) -> El<State> {
    El<State>(direction: .row)
        .role(.separator)
        .wFull()
        .h(max(0.5, thickness))
        .bg(color)
}

public func text<State>(_ content: String) -> El<State> {
    var node = El<State>(direction: .row)
    node.role = .text
    node.plainText = content
    return node
}

public func liveText<State>(_ handle: LiveText) -> El<State> {
    var node = El<State>(direction: .row)
    node.role = .text
    node.liveText = handle
    node.plainText = handle.get()
    return node
}

public func text<State>(_ handle: LiveText) -> El<State> {
    liveText(handle)
}

public func rich<State>(_ spans: [TextSpan]) -> El<State> {
    var node = El<State>(direction: .row)
    node.role = .text
    node.richSpans = spans
    node.plainText = spans.map(\.text).joined()
    return node
}

public func icon<State>(_ svg: SVGIcon, size: Float = 16.0) -> El<State> {
    var node = El<State>(direction: .row)
        .size(size, size)
        .shrink(0)
    node.role = .icon
    node.iconPayload = (svg, size)
    return node
}

public func image<State>(_ atlas: RGBA8Atlas) -> El<State> {
    var node = El<State>(direction: .row)
    node.role = .image
    node.imagePayload = atlas
    if atlas.width > 0 && atlas.height > 0 {
        node.layout.aspectRatio = Float(atlas.width) / Float(atlas.height)
    }
    return node
}

/// Element showing a `Pixels` buffer (`El::pixels` / `El::pixels_fit`).
public func pixels<State>(_ buffer: Pixels, fit: SurfaceFit? = nil) -> El<State> {
    var node = El<State>(direction: .row)
    node.role = .image
    node.pixelsPayload = buffer
    node.pixelsFitMode = fit
    return node
}

public func canvas<State>(_ shape: Shape) -> El<State> {
    var node = El<State>(direction: .row)
    node.role = .image
    node.shapes = [shape]
    return node
}

public func nativeSurface<State>(_ surface: NativeSurface, _ fit: SurfaceFit = .fit) -> El<State> {
    El<State>(direction: .row).nativeSurface(surface, fit)
}

public func video<State>(_ player: Player, _ fit: SurfaceFit = .fit) -> El<State> {
    El<State>(direction: .row).video(player, fit)
}

extension El {
    /// Paints the newest picture pushed into `surface` inside this element's box.
    public func nativeSurface(_ surface: NativeSurface, _ fit: SurfaceFit = .fit) -> Self {
        var copy = self
        copy.surfacePayload = (surface, fit)
        return copy
    }

    /// Plays `player` inside this element's box (`fit` letterboxes, `fill` crops).
    public func video(_ player: Player, _ fit: SurfaceFit = .fit) -> Self {
        nativeSurface(player.surface.retaining(player), fit)
    }

    /// Anchors a `nativeSurface` or `video` frame along `(horizontal, vertical)` inside its box.
    public func surfaceAnchor(_ horizontal: Align, _ vertical: Align) -> Self {
        var copy = self
        copy.surfacePlace.anchor = (horizontal, vertical)
        return copy
    }

    /// Draws a `nativeSurface` or `video` at 1 texel per device pixel without fit scaling.
    public func surfaceUnscaled(_ unscaled: Bool = true) -> Self {
        var copy = self
        copy.surfacePlace.unscaled = unscaled
        return copy
    }
}

/// Value-typed text field configuration mirroring `el::input::InputSpec`.
public struct InputSpec: Sendable, Equatable {
    public var animateLayout: Bool
    public var placeholder: String
    public var placeholderColor: Color
    public var placeholderStyle: TextStyle?
    public var caret: Color
    public var selection: Color
    public var singleLine: Bool
    public var spellcheck: Bool

    public init(
        animateLayout: Bool = false,
        placeholder: String = "",
        placeholderColor: Color = Color.white.scaleAlpha(0.4),
        placeholderStyle: TextStyle? = nil,
        caret: Color = .white,
        selection: Color = Color.srgb(0.2, 0.48, 0.96, 0.35),
        singleLine: Bool = false,
        spellcheck: Bool = false
    ) {
        self.animateLayout = animateLayout
        self.placeholder = placeholder
        self.placeholderColor = placeholderColor
        self.placeholderStyle = placeholderStyle
        self.caret = caret
        self.selection = selection
        self.singleLine = singleLine
        self.spellcheck = spellcheck
    }
}

/// Custom `(get, set)` state lens for a `textInput` (`el::input::edit_access`).
public struct EditAccessor<State> {
    public let get: (State) -> TextEdit
    public let set: (inout State, TextEdit) -> Void

    public init(get: @escaping (State) -> TextEdit, set: @escaping (inout State, TextEdit) -> Void) {
        self.get = get
        self.set = set
    }
}

/// Wraps a state `TextEdit` accessor closure pair for `textInput` / `El.onEdit` (`el::input::edit_access`).
public func editAccess<State>(
    get: @escaping (State) -> TextEdit,
    set: @escaping (inout State, TextEdit) -> Void
) -> EditAccessor<State> {
    EditAccessor(get: get, set: set)
}

/// Interactive single-line or multiline text input bound via a Swift `WritableKeyPath<State, TextEdit>`.
public func textInput<State>(
    key: String,
    _ keyPath: WritableKeyPath<State, TextEdit>,
    spec: InputSpec? = nil
) -> El<State> {
    textInput(key: key, editAccess(get: { $0[keyPath: keyPath] }, set: { $0[keyPath: keyPath] = $1 }), spec: spec)
}

/// Interactive text input bound via an explicit `EditAccessor<State>` (`el::input::edit_access`).
public func textInput<State>(
    key: String,
    _ access: EditAccessor<State>,
    spec: InputSpec? = nil
) -> El<State> {
    var node = El<State>(direction: .row)
        .key(key)
        .role(.textInput)
        .focusable(true)
        .clip(true)
    node.textStyle.wrap = .wrap
    node.handlers.editLens = (get: access.get, set: access.set)
    if let spec {
        if !spec.placeholder.isEmpty {
            node = node.placeholder(spec.placeholder, color: spec.placeholderColor)
        }
        if let placeholderStyle = spec.placeholderStyle {
            node = node.placeholderFont(placeholderStyle)
        }
        node = node.caret(spec.caret, selection: spec.selection)
        if spec.singleLine { node = node.singleLine(true) }
        if spec.spellcheck { node = node.spellcheck(true) }
        if spec.animateLayout { node = node.animateEditLayout(true) }
    }
    return node
}

/// Wraps a `textInput` field in a scroll container bounded between `minLines` and `maxLines` (`el::input::auto_grow`).
public func autoGrow<State>(_ field: El<State>, minLines: Int = 1, maxLines: Int = 6) -> El<State> {
    let line = field.textStyle.resolvedLineHeight
    let minL = max(1, minLines)
    let maxL = max(minL, maxLines)
    var adjusted = field
    adjusted.textStyle.wrap = .wrap
    return El<State>(direction: .column)
        .key("scroll")
        .wFull()
        .shrink(1)
        .minH(Float(minL) * line)
        .maxH(Float(maxL) * line)
        .scroll(stickBottom: false)
        .child(adjusted.animateEditLayout())
}
