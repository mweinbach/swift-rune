import Foundation
import Rune
import RuneMotion

// MARK: - ScrollBar Constants (`rune_kit::scroll_bar`)

public enum ScrollBarMetrics {
    public static let thumbWidth: Float = 6.0
    public static let thumbHoverWidth: Float = 10.0
    public static let inset: Float = 2.0
    public static let stripWidth: Float = 14.0
    public static let hoverStripWidth: Float = 20.0
    public static let minThumbLength: Float = 24.0
    public static let fadeDelay: Double = 0.75
    public static let pageDelay: Double = 0.3
    public static let pageInterval: Double = 0.06
    public static let enterSpring = Spring(duration: 0.14, bounce: 0.0)
    public static let leaveSpring = Spring(duration: 0.28, bounce: 0.0)
    public static let widenSpring = Spring(duration: 0.12, bounce: 0.0)
    public static let keptLimit: Int = 256
}

// MARK: - Style & Configuration (`KitScrollBarStyle`)

/// Visual and behavioral configuration for a RuneKit scrollbar (`rune_kit::scroll_bar::ScrollBarStyle`).
/// Named `KitScrollBarStyle` to avoid colliding with `Rune.ScrollBarStyle` (the OS preference enum).
public struct KitScrollBarStyle: Sendable, Equatable {
    public var key: String = "scroll-bar"
    public var thumbKey: String = "thumb"
    public var horizontal: Bool = false
    public var inside: Bool = false
    public var overlay: Bool = false
    public var gutter: Bool = false
    public var areaReveals: Bool = false
    public var scrollOnly: Bool = false
    public var border: Float = 0.0
    public var hoverTarget: String? = nil
    public var trackStartInset: Float = ScrollBarMetrics.inset
    public var trackEndInset: Float = ScrollBarMetrics.inset
    public var edgeInset: Float = ScrollBarMetrics.inset
    public var stripWidth: Float = ScrollBarMetrics.stripWidth
    public var hoverStripWidth: Float = ScrollBarMetrics.hoverStripWidth
    public var width: Float = ScrollBarMetrics.thumbWidth
    public var hoverWidth: Float = ScrollBarMetrics.thumbHoverWidth
    public var minThumb: Float = ScrollBarMetrics.minThumbLength
    public var holdDuration: Double = ScrollBarMetrics.fadeDelay
    public var enterSpring: Spring = ScrollBarMetrics.enterSpring
    public var leaveSpring: Spring = ScrollBarMetrics.leaveSpring
    public var tintSpring: Spring = ScrollBarMetrics.widenSpring
    public var thumbColor: Color
    public var thumbHoverColor: Color
    public var trackColor: Color? = nil
    public var trackBorderColor: Color? = nil
    public var trackRadius: Float = 999
    public var thumbRadius: Float = 999
    public var devicePixels: Bool = true
    public var scale: Float = 1.0
    public var webkitParts: Bool = false
    public var alwaysVisible: Bool = false

    public init(
        thumbColor: Color,
        thumbHoverColor: Color,
        trackColor: Color? = nil,
        trackBorderColor: Color? = nil
    ) {
        self.thumbColor = thumbColor
        self.thumbHoverColor = thumbHoverColor
        self.trackColor = trackColor
        self.trackBorderColor = trackBorderColor
    }

    public static func neutral(dark: Bool) -> KitScrollBarStyle {
        fromKit(Kit.neutral(dark: dark))
    }

    public static func fromKit(_ kit: Kit) -> KitScrollBarStyle {
        var s = KitScrollBarStyle(
            thumbColor: kit.c.borderBase,
            thumbHoverColor: kit.c.borderStrong,
            trackColor: nil
        )
        s.width = ScrollBarMetrics.thumbWidth
        s.hoverWidth = ScrollBarMetrics.thumbHoverWidth
        s.stripWidth = ScrollBarMetrics.stripWidth
        s.hoverStripWidth = ScrollBarMetrics.hoverStripWidth
        s.minThumb = ScrollBarMetrics.minThumbLength
        s.edgeInset = ScrollBarMetrics.inset
        s.holdDuration = ScrollBarMetrics.fadeDelay
        return s
    }

    /// Preset tuned for `@opencode/ui` ScrollView (`SCROLL_VIEW_TRACK`).
    public static func scrollView(_ kit: Kit) -> KitScrollBarStyle {
        var s = KitScrollBarStyle(
            thumbColor: kit.c.borderMuted,
            thumbHoverColor: kit.c.borderStrong
        )
        s.stripWidth = 12.0
        s.edgeInset = 4.0
        s.trackStartInset = 8.0
        s.trackEndInset = 8.0
        s.minThumb = 32.0
        s.width = 4.0
        s.hoverWidth = 4.0
        s.overlay = true
        s.inside = true
        s.areaReveals = true
        s.holdDuration = 0.8
        s.enterSpring = Spring(duration: 0.2, bounce: 0.0)
        s.leaveSpring = Spring(duration: 0.2, bounce: 0.0)
        s.tintSpring = Spring(duration: 0.15, bounce: 0.0)
        return s
    }

    /// Native `@opencode/ui` `scrollbar.css` preset (`NATIVE_TRACK`).
    public static func native(thumb: Color, thumbHover: Color) -> KitScrollBarStyle {
        var s = KitScrollBarStyle(thumbColor: thumb, thumbHoverColor: thumbHover)
        s.stripWidth = 8.0
        s.edgeInset = 2.0
        s.trackStartInset = 4.0
        s.trackEndInset = 4.0
        s.minThumb = 32.0
        s.border = 2.0
        s.width = 4.0
        s.hoverWidth = 4.0
        s.overlay = true
        s.gutter = true
        s.areaReveals = true
        s.holdDuration = 0.0
        s.enterSpring = .none
        s.leaveSpring = .none
        s.tintSpring = .none
        s.devicePixels = true
        return s
    }

    /// Native `@opencode/ui` `scrollbar.css` preset derived from `Kit` tokens (`NATIVE_TRACK`).
    public static func native(_ kit: Kit) -> KitScrollBarStyle {
        native(thumb: kit.c.borderMuted, thumbHover: kit.c.borderStrong)
    }

    /// Compact scrollbar preset for menus, popups, and lists (`MENU_SCROLL_TRACK`).
    public static func menuScroll(thumb: Color, thumbHover: Color) -> KitScrollBarStyle {
        var s = KitScrollBarStyle(thumbColor: thumb, thumbHoverColor: thumbHover)
        s.stripWidth = 8.0
        s.edgeInset = 2.0
        s.trackStartInset = 4.0
        s.trackEndInset = 4.0
        s.minThumb = 24.0
        s.width = 4.0
        s.hoverWidth = 4.0
        s.overlay = true
        s.inside = true
        s.areaReveals = true
        s.scrollOnly = true
        s.holdDuration = 0.8
        s.enterSpring = Spring(duration: 0.2, bounce: 0.0)
        s.leaveSpring = Spring(duration: 0.2, bounce: 0.0)
        s.tintSpring = .none
        return s
    }

    /// Compact scrollbar preset derived from `Kit` tokens (`MENU_SCROLL_TRACK`).
    public static func menuScroll(_ kit: Kit) -> KitScrollBarStyle {
        menuScroll(thumb: kit.c.borderMuted, thumbHover: kit.c.borderStrong)
    }

    /// Subtracts the clear border around Chromium-style pills (`Track::pill`).
    public func pillExtent(start: Float, length: Float) -> (start: Float, length: Float) {
        (start + border, max(0, length - 2.0 * border))
    }

    public func key(_ value: String) -> Self {
        var copy = self; copy.key = value; return copy
    }

    public func thumbKey(_ value: String) -> Self {
        var copy = self; copy.thumbKey = value; return copy
    }

    public func horizontal(_ value: Bool = true) -> Self {
        var copy = self; copy.horizontal = value; return copy
    }

    public func inside(_ value: Bool = true) -> Self {
        var copy = self; copy.inside = value; return copy
    }

    public func hoverTarget(_ value: String?) -> Self {
        var copy = self; copy.hoverTarget = value; return copy
    }

    public func trackOffset(_ value: Float) -> Self {
        var copy = self
        copy.trackStartInset = value
        copy.trackEndInset = value
        return copy
    }

    public func trackInsets(start: Float, end: Float) -> Self {
        var copy = self
        copy.trackStartInset = start
        copy.trackEndInset = end
        return copy
    }

    public func strip(_ value: Float) -> Self {
        var copy = self; copy.stripWidth = max(1, value); return copy
    }

    public func edgeInset(_ value: Float) -> Self {
        var copy = self; copy.edgeInset = max(0, value); return copy
    }

    public func thumb(_ color: Color) -> Self {
        var copy = self; copy.thumbColor = color; return copy
    }

    public func thumbHover(_ color: Color) -> Self {
        var copy = self; copy.thumbHoverColor = color; return copy
    }

    public func track(_ color: Color?, border: Color? = nil) -> Self {
        var copy = self
        copy.trackColor = color
        copy.trackBorderColor = border
        return copy
    }

    public func width(_ value: Float) -> Self {
        var copy = self; copy.width = max(1, value); return copy
    }

    public func hoverWidth(_ value: Float) -> Self {
        var copy = self; copy.hoverWidth = max(width, value); return copy
    }

    public func minThumb(_ value: Float) -> Self {
        var copy = self; copy.minThumb = max(4, value); return copy
    }

    public func devicePixels(_ enabled: Bool = true, scale: Float = 1.0) -> Self {
        var copy = self
        copy.devicePixels = enabled
        copy.scale = max(1, scale)
        return copy
    }

    public func webkitParts(_ enabled: Bool = true) -> Self {
        var copy = self; copy.webkitParts = enabled; return copy
    }

    public func alwaysVisible(_ enabled: Bool = true) -> Self {
        var copy = self; copy.alwaysVisible = enabled; return copy
    }

    /// Total interactive press strip width (always wide enough to contain the widest thumb + inset).
    public var resolvedStripWidth: Float {
        max(stripWidth, hoverWidth + edgeInset * 2.0)
    }
}

// MARK: - Axis Geometry & Pure Math (`scroll_bar.rs`)

/// Single-axis viewport/content/offset metrics for scrollbar calculations.
public struct ScrollAxisMetrics: Sendable, Equatable {
    public var offset: Float
    public var content: Float
    public var viewport: Float

    public init(offset: Float, content: Float, viewport: Float) {
        self.offset = offset
        self.content = content
        self.viewport = viewport
    }

    public var maxScroll: Float {
        max(0, content - viewport)
    }
}

public enum ScrollBarMath {
    /// Aligns a coordinate/size to `pixelStep` when `devicePixels` is enabled.
    @inline(__always)
    public static func align(_ value: Float, devicePixels: Bool, scale: Float = 1.0) -> Float {
        guard devicePixels, scale > 0 else { return value }
        return (value * scale).rounded() / scale
    }

    /// Computes usable track length and whether the scrollbar should appear (`len >= minThumb`).
    public static func trackLength(
        for metrics: ScrollAxisMetrics,
        startInset: Float = ScrollBarMetrics.inset,
        endInset: Float = ScrollBarMetrics.inset,
        minThumb: Float = ScrollBarMetrics.minThumbLength
    ) -> (length: Float, shows: Bool) {
        let len = max(0, metrics.viewport - startInset - endInset)
        let shows = metrics.content > metrics.viewport + 0.5 && len >= minThumb
        return (len, shows)
    }

    /// Computes thumb `(start, length)` along the track, including Chromium pixel alignment
    /// (length rounded, position truncated, `(0..<1) -> 1`) and rubber-band overscroll compression.
    public static func thumbAlong(
        _ metrics: ScrollAxisMetrics,
        trackLength: Float,
        minThumb: Float = ScrollBarMetrics.minThumbLength,
        devicePixels: Bool = false,
        scale: Float = 1.0
    ) -> (start: Float, length: Float) {
        guard trackLength > 0, metrics.content > 0, metrics.viewport > 0 else {
            return (0, 0)
        }
        let maxScroll = metrics.maxScroll
        let total = max(1.0, metrics.viewport + maxScroll)
        let over: Float
        if metrics.offset < 0 {
            over = -metrics.offset
        } else if metrics.offset > maxScroll {
            over = metrics.offset - maxScroll
        } else {
            over = 0
        }
        let frac: Float = maxScroll > 0 ? (metrics.offset / maxScroll).clamped(to: 0...1) : 0

        if devicePixels && scale > 0 {
            let trPx = (trackLength * scale).rounded()
            let baseLenPx = (trPx * metrics.viewport / total).rounded()
            let minPx = (minThumb * scale).rounded()
            let compressedPx = over > 0
                ? (baseLenPx * (metrics.viewport / (metrics.viewport + over))).rounded()
                : baseLenPx
            let lenPx = min(trPx, max(minPx, compressedPx))
            let rawPos = maxScroll > 0 ? (trPx - lenPx) * frac : 0
            let posPx: Float = (rawPos > 0 && rawPos < 1.0) ? 1.0 : rawPos.rounded(.towardZero)
            return (posPx / scale, lenPx / scale)
        }

        let ratio = min(1.0, metrics.viewport / total)
        let rawLen = trackLength * ratio
        let compressed: Float = over > 0 ? rawLen * (metrics.viewport / (metrics.viewport + over)) : rawLen
        let len = min(trackLength, max(minThumb, compressed))
        let travel = max(0, trackLength - len)
        let start = (frac * travel).clamped(to: 0...travel)
        return (start, len)
    }

    /// Maps a thumb start position along the track back to content scroll offset (`currentOffset` when `travel <= 0`).
    public static func offsetAlong(
        thumbStart: Float,
        trackLength: Float,
        thumbLength: Float,
        maxScroll: Float,
        currentOffset: Float = 0
    ) -> Float {
        let travel = trackLength - thumbLength
        guard travel > 0 else { return currentOffset }
        guard maxScroll > 0 else { return 0 }
        let frac = (thumbStart / travel).clamped(to: 0...1)
        return frac * maxScroll
    }

    /// Converts a drag position along the track (and initial thumb grab offset) into a scroll offset.
    public static func turnedOffset(
        pointerAlongTrack: Float,
        grab: Float,
        trackLength: Float,
        thumbLength: Float,
        maxScroll: Float,
        currentOffset: Float = 0
    ) -> Float {
        offsetAlong(
            thumbStart: pointerAlongTrack - grab,
            trackLength: trackLength,
            thumbLength: thumbLength,
            maxScroll: maxScroll,
            currentOffset: currentOffset
        )
    }
}

// MARK: - Press State Machine (`scroll_bar/press.rs`)

/// Active pointer press on a scrollbar: either dragging the thumb or paging along the track.
public enum ScrollBarPress: Sendable, Equatable {
    case thumb(grab: Float)
    case pages(toward: Int32)

    /// Selects `.thumb` vs `.pages` for a track pointer-down event matching upstream macOS rules.
    public static func begin(
        pointerAlongTrack: Float,
        thumbStart: Float,
        thumbLength: Float,
        altPressed: Bool,
        jumpPreference: Bool,
        horizontal: Bool
    ) -> ScrollBarPress {
        let onThumb = pointerAlongTrack >= thumbStart && pointerAlongTrack <= (thumbStart + thumbLength)
        if !onThumb && (jumpPreference == altPressed) && !horizontal {
            return .pages(toward: pointerAlongTrack < thumbStart ? -1 : 1)
        }
        let grab = onThumb ? (pointerAlongTrack - thumbStart) : (thumbLength * 0.5)
        return .thumb(grab: grab)
    }
}

/// Manages `Grip<ScrollBarPress>` transitions across press, drag moves, lost releases, and pointer moves.
public struct ScrollBarPressTracker: Sendable, Equatable {
    public private(set) var grip: Grip<ScrollBarPress> = .idle

    public init() {}

    public var isHeld: Bool { grip.isHeld }
    public var activePress: ScrollBarPress? { grip.data }

    @discardableResult
    public mutating func pointerDown(_ press: ScrollBarPress, at point: Vec2?) -> ScrollBarPress? {
        grip.press(press, at: point)
    }

    public mutating func dragMoved(to point: Vec2) -> ScrollBarPress? {
        grip.moved(to: point)
    }

    @discardableResult
    public mutating func pointerUp() -> ScrollBarPress? {
        grip.release()
    }

    /// Detects a lost release when non-drag pointer moves arrive while still marked held.
    @discardableResult
    public mutating func observePointerMove(at point: Vec2) -> ScrollBarPress? {
        grip.pointerMoved(to: point)
    }

    @discardableResult
    public mutating func cancel() -> ScrollBarPress? {
        grip.lose()
    }
}

// MARK: - Visibility & Fade State Machine (`scroll_bar/visibility.rs`)

/// Overlay vs always-visible reveal, hover-widen, and timed auto-hide state machine.
public struct ScrollBarVisibility: Sendable, Equatable {
    public var shows: Bool
    public var alwaysVisible: Bool
    public var insideViewport: Bool
    public var overBar: Bool
    public var held: Bool
    public var hideAt: Double?
    public private(set) var visible: Bool
    public private(set) var opacity: Float
    public private(set) var isWide: Bool

    public init(alwaysVisible: Bool = false, shows: Bool = false) {
        self.alwaysVisible = alwaysVisible
        self.shows = shows
        self.insideViewport = false
        self.overBar = false
        self.held = false
        self.hideAt = nil
        self.visible = alwaysVisible && shows
        self.opacity = self.visible ? 1.0 : 0.0
        self.isWide = false
        reconcile(now: 0)
    }

    public mutating func setShows(_ shows: Bool, now: Double = 0) {
        self.shows = shows
        if !shows {
            overBar = false
            held = false
            hideAt = nil
        }
        reconcile(now: now)
    }

    public mutating func setAlwaysVisible(_ always: Bool, now: Double = 0) {
        self.alwaysVisible = always
        reconcile(now: now)
    }

    public mutating func setPointerInside(_ inside: Bool, now: Double) {
        insideViewport = inside
        if !inside {
            overBar = false
        }
        reconcile(now: now)
    }

    public mutating func setPointerOverBar(_ over: Bool, now: Double) {
        overBar = over
        if over && shows {
            visible = true
            hideAt = nil
        } else if !over && visible && !alwaysVisible && !held {
            hideAt = now + ScrollBarMetrics.fadeDelay
        }
        reconcile(now: now)
    }

    public mutating func setHeld(_ held: Bool, now: Double) {
        self.held = held
        if held && shows {
            visible = true
            hideAt = nil
        } else if !held && !overBar && visible && !alwaysVisible {
            hideAt = now + ScrollBarMetrics.fadeDelay
        }
        reconcile(now: now)
    }

    public mutating func scrolled(now: Double) {
        guard shows else { return }
        visible = true
        if !alwaysVisible && !overBar && !held {
            hideAt = now + ScrollBarMetrics.fadeDelay
        } else {
            hideAt = nil
        }
        reconcile(now: now)
    }

    public mutating func tick(now: Double) {
        if let deadline = hideAt, now >= deadline {
            if !alwaysVisible && !overBar && !held {
                visible = false
                hideAt = nil
            }
        }
        reconcile(now: now)
    }

    /// Whether the scrollbar accepts pointer hits right now (hidden overlay bars pass clicks through!).
    public var acceptsPointerHits: Bool {
        shows && (alwaysVisible || visible || held || overBar)
    }

    private mutating func reconcile(now: Double) {
        if !shows {
            visible = false
            opacity = 0.0
            isWide = false
            return
        }
        if alwaysVisible {
            visible = true
            hideAt = nil
        } else if overBar || held {
            visible = true
            hideAt = nil
        } else if let deadline = hideAt, now >= deadline {
            visible = false
            hideAt = nil
        }
        opacity = visible ? 1.0 : 0.0
        isWide = overBar || held
    }
}

// MARK: - Live Kept Store (`KEPT = 256`) & El / Kit ScrollBar Builders

/// Live presentation bindings + interaction trackers retained across frames per scrollbar key.
public final class ScrollBarLiveSlot: @unchecked Sendable {
    private let lock = NSLock()
    public let liveTrack: Live<MotionRect>
    public let liveThumb: Live<MotionRect>
    public let liveOpacity: Live<Float>
    public let liveFill: Live<Color>
    public var visibility: ScrollBarVisibility
    public var pressTracker: ScrollBarPressTracker
    public var lastMetrics: ScrollAxisMetrics

    private var hasObservedScroll: Bool = false
    private var lastStyle: KitScrollBarStyle

    public init(style: KitScrollBarStyle) {
        self.lastStyle = style
        self.liveTrack = Live(MotionRect(left: 0, top: 0, right: style.resolvedStripWidth, bottom: 100))
        self.liveThumb = Live(MotionRect(left: style.edgeInset, top: style.trackStartInset, right: style.edgeInset + style.width, bottom: style.trackStartInset + style.minThumb))
        self.liveOpacity = Live(style.alwaysVisible || !style.overlay ? 1.0 : 0.0)
        self.liveFill = Live(style.thumbColor)
        self.visibility = ScrollBarVisibility(alwaysVisible: style.alwaysVisible || !style.overlay, shows: true)
        self.pressTracker = ScrollBarPressTracker()
        self.lastMetrics = ScrollAxisMetrics(offset: 0, content: 400, viewport: 100)
    }

    public func syncStyle(_ style: KitScrollBarStyle) {
        lock.lock()
        defer { lock.unlock() }
        let wasAlways = visibility.alwaysVisible
        let nextAlways = style.alwaysVisible || !style.overlay
        let colorChanged = style.thumbColor != lastStyle.thumbColor || style.thumbHoverColor != lastStyle.thumbHoverColor
        lastStyle = style
        if wasAlways != nextAlways {
            pressTracker = ScrollBarPressTracker()
            hasObservedScroll = false
            visibility = ScrollBarVisibility(alwaysVisible: nextAlways, shows: visibility.shows)
            liveOpacity.snap(visibility.opacity)
            liveFill.snap(style.thumbColor)
            return
        }
        visibility.setAlwaysVisible(nextAlways, now: 0)
        let targetFill = (visibility.isWide || pressTracker.isHeld) ? style.thumbHoverColor : style.thumbColor
        if colorChanged {
            liveFill.snap(targetFill)
        } else {
            liveFill.set(targetFill)
        }
        if visibility.alwaysVisible && visibility.shows {
            liveOpacity.snap(1.0)
        } else if !visibility.shows {
            liveOpacity.snap(0.0)
        }
    }

    public func hover(_ inside: Bool, style: KitScrollBarStyle, now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }
        lastStyle = style
        guard visibility.shows else {
            visibility.setPointerOverBar(false, now: now)
            liveOpacity.snap(0.0)
            return
        }
        visibility.setPointerOverBar(inside, now: now)
        if inside || visibility.alwaysVisible || pressTracker.isHeld {
            liveOpacity.set(1.0)
        } else if visibility.visible {
            liveOpacity.pulse(active: 1.0, rest: 0.0, holdSeconds: style.holdDuration)
        } else {
            liveOpacity.set(0.0)
        }
        liveFill.set((inside || pressTracker.isHeld) ? style.thumbHoverColor : style.thumbColor)
        let current = liveThumb.get()
        let activeW = (inside || pressTracker.isHeld) ? style.hoverWidth : style.width
        if style.horizontal {
            let y0 = max(0, style.resolvedStripWidth - style.edgeInset - activeW)
            liveThumb.set(MotionRect(left: current.left, top: y0, right: current.right, bottom: y0 + activeW))
        } else {
            let x0 = max(0, style.resolvedStripWidth - style.edgeInset - activeW)
            liveThumb.set(MotionRect(left: x0, top: current.top, right: x0 + activeW, bottom: current.bottom))
        }
    }

    public enum PointerDownResult: Sendable, Equatable {
        case grabThumb
        case jump(Float)
        case page(Int32)
    }

    public func pointerDown(
        along: Float,
        windowPoint: Vec2,
        trackLength: Float,
        altPressed: Bool,
        jumpPreference: Bool,
        style: KitScrollBarStyle,
        now: Double = ProcessInfo.processInfo.systemUptime
    ) -> ScrollBarPress {
        let (action, _) = pointerDownDetail(
            along: along,
            windowPoint: windowPoint,
            trackLength: trackLength,
            trackSize: nil,
            altPressed: altPressed,
            jumpPreference: jumpPreference,
            style: style,
            now: now
        )
        return action
    }

    public func pointerDownWithResult(
        along: Float,
        windowPoint: Vec2,
        trackLength: Float,
        trackSize: Vec2,
        altPressed: Bool,
        jumpPreference: Bool,
        style: KitScrollBarStyle,
        now: Double = ProcessInfo.processInfo.systemUptime
    ) -> PointerDownResult {
        let (_, result) = pointerDownDetail(
            along: along,
            windowPoint: windowPoint,
            trackLength: trackLength,
            trackSize: trackSize,
            altPressed: altPressed,
            jumpPreference: jumpPreference,
            style: style,
            now: now
        )
        return result
    }

    private func pointerDownDetail(
        along: Float,
        windowPoint: Vec2,
        trackLength: Float,
        trackSize: Vec2?,
        altPressed: Bool,
        jumpPreference: Bool,
        style: KitScrollBarStyle,
        now: Double
    ) -> (ScrollBarPress, PointerDownResult) {
        lock.lock()
        defer { lock.unlock() }
        lastStyle = style
        let thumb = liveThumb.get()
        let thumbStart = style.horizontal ? (thumb.left - style.trackStartInset) : (thumb.top - style.trackStartInset)
        let thumbLen = max(style.minThumb, style.horizontal ? thumb.width : thumb.height)
        let onThumb = along >= thumbStart && along <= (thumbStart + thumbLen)
        let action = ScrollBarPress.begin(
            pointerAlongTrack: along,
            thumbStart: thumbStart,
            thumbLength: thumbLen,
            altPressed: altPressed,
            jumpPreference: jumpPreference,
            horizontal: style.horizontal
        )
        pressTracker.pointerDown(action, at: windowPoint)
        visibility.setHeld(true, now: now)
        liveOpacity.set(visibility.opacity)
        liveFill.set(style.thumbHoverColor)
        if case .pages(let toward) = action {
            return (action, .page(toward))
        }
        if !onThumb {
            let resolvedSize = trackSize ?? Vec2(liveTrack.get().width, liveTrack.get().height)
            let nextOffset = applyThumbDragLocked(along: along, trackSize: resolvedSize, style: style)
            return (action, .jump(nextOffset))
        }
        // Keep held thumb width synced immediately on press.
        let activeW = style.hoverWidth
        if style.horizontal {
            let y0 = max(0, style.resolvedStripWidth - style.edgeInset - activeW)
            liveThumb.set(MotionRect(left: thumb.left, top: y0, right: thumb.right, bottom: y0 + activeW))
        } else {
            let x0 = max(0, style.resolvedStripWidth - style.edgeInset - activeW)
            liveThumb.set(MotionRect(left: x0, top: thumb.top, right: x0 + activeW, bottom: thumb.bottom))
        }
        return (action, .grabThumb)
    }

    public func drag(
        along: Float,
        windowPoint: Vec2,
        trackSize: Vec2,
        style: KitScrollBarStyle
    ) -> Float {
        dragIfThumb(along: along, windowPoint: windowPoint, trackSize: trackSize, style: style) ?? lastMetrics.offset
    }

    public func liveTrackSize() -> Vec2 {
        lock.lock()
        defer { lock.unlock() }
        let r = liveTrack.get()
        return Vec2(r.width, r.height)
    }

    public func pageTargetOffset(
        along: Float,
        trackLength: Float,
        style: KitScrollBarStyle
    ) -> Float? {
        lock.lock()
        defer { lock.unlock() }
        guard case .pages(let dir) = pressTracker.activePress else {
            return nil
        }
        let thumb = liveThumb.get()
        let currentStart = (style.horizontal ? thumb.left : thumb.top) - style.trackStartInset
        let currentLen = style.horizontal ? thumb.width : thumb.height
        let stillNeedsPage = dir > 0
            ? (along >= currentStart + currentLen)
            : (along <= currentStart)
        guard stillNeedsPage else {
            return nil
        }
        let step = max(1.0, lastMetrics.viewport * 0.9)
        let nextOffset = (lastMetrics.offset + Float(dir) * step).clamped(to: 0...lastMetrics.maxScroll)
        if abs(nextOffset - lastMetrics.offset) < 1e-4 {
            return nil
        }
        lastMetrics.offset = nextOffset
        return nextOffset
    }

    public func dragIfThumb(
        along: Float,
        windowPoint: Vec2,
        trackSize: Vec2,
        style: KitScrollBarStyle
    ) -> Float? {
        lock.lock()
        defer { lock.unlock() }
        _ = pressTracker.dragMoved(to: windowPoint)
        if case .pages = pressTracker.activePress {
            return nil
        }
        let resolvedSize = (trackSize.x > 0 && trackSize.y > 0)
            ? trackSize
            : Vec2(liveTrack.get().width, liveTrack.get().height)
        return applyThumbDragLocked(along: along, trackSize: resolvedSize, style: style)
    }

    private func applyThumbDragLocked(along: Float, trackSize: Vec2, style: KitScrollBarStyle) -> Float {
        let rawSpan = style.horizontal ? trackSize.x : trackSize.y
        let effectiveLen = max(style.minThumb, rawSpan - style.trackStartInset - style.trackEndInset)
        let thumb = liveThumb.get()
        let thumbLen = min(effectiveLen, max(style.minThumb, style.horizontal ? thumb.width : thumb.height))
        let grab: Float
        if case .thumb(let g) = pressTracker.activePress {
            grab = g
        } else {
            grab = thumbLen * 0.5
        }
        let maxScroll = lastMetrics.maxScroll
        let clampedStart = (along - grab).clamped(to: 0...max(0, effectiveLen - thumbLen))
        let nextOffset = ScrollBarMath.offsetAlong(
            thumbStart: clampedStart,
            trackLength: effectiveLen,
            thumbLength: thumbLen,
            maxScroll: maxScroll,
            currentOffset: lastMetrics.offset
        )
        lastMetrics.offset = nextOffset
        let (pillStart, pillLen) = style.pillExtent(start: clampedStart, length: thumbLen)
        let activeW = style.hoverWidth
        if style.horizontal {
            let y0 = max(0, style.resolvedStripWidth - style.edgeInset - activeW)
            liveThumb.snap(MotionRect(
                left: style.trackStartInset + pillStart,
                top: y0,
                right: style.trackStartInset + pillStart + pillLen,
                bottom: y0 + activeW
            ))
        } else {
            let x0 = max(0, style.resolvedStripWidth - style.edgeInset - activeW)
            liveThumb.snap(MotionRect(
                left: x0,
                top: style.trackStartInset + pillStart,
                right: x0 + activeW,
                bottom: style.trackStartInset + pillStart + pillLen
            ))
        }
        return nextOffset
    }

    public func release(style: KitScrollBarStyle, now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }
        _ = pressTracker.pointerUp()
        visibility.setHeld(false, now: now)
        if visibility.alwaysVisible || visibility.overBar {
            liveOpacity.set(visibility.shows ? 1.0 : 0.0)
        } else if visibility.visible && visibility.shows {
            liveOpacity.pulse(active: 1.0, rest: 0.0, holdSeconds: style.holdDuration)
        } else {
            liveOpacity.set(0.0)
        }
        liveFill.set(visibility.overBar ? style.thumbHoverColor : style.thumbColor)
        let current = liveThumb.get()
        if visibility.shows && current.width > 0 && current.height > 0 {
            let activeW = visibility.overBar ? style.hoverWidth : style.width
            if style.horizontal {
                let y0 = max(0, style.resolvedStripWidth - style.edgeInset - activeW)
                liveThumb.set(MotionRect(left: current.left, top: y0, right: current.right, bottom: y0 + activeW))
            } else {
                let x0 = max(0, style.resolvedStripWidth - style.edgeInset - activeW)
                liveThumb.set(MotionRect(left: x0, top: current.top, right: x0 + activeW, bottom: current.bottom))
            }
        }
    }

    public func updateFromScrollPos(
        _ pos: ScrollPos,
        style: KitScrollBarStyle,
        now: Double = ProcessInfo.processInfo.systemUptime
    ) {
        lock.lock()
        defer { lock.unlock() }
        lastStyle = style
        let axisOffset = style.horizontal ? pos.offset.x : pos.offset.y
        let axisViewport = style.horizontal ? pos.viewport.x : pos.viewport.y
        let axisMax = style.horizontal ? pos.max.x : pos.max.y
        let metrics = ScrollAxisMetrics(
            offset: axisOffset,
            content: axisViewport + axisMax,
            viewport: axisViewport
        )
        let scrolledChanged = hasObservedScroll && abs(metrics.offset - lastMetrics.offset) > 1e-4
        hasObservedScroll = true
        lastMetrics = metrics

        let (trackLen, shows) = ScrollBarMath.trackLength(
            for: metrics,
            startInset: style.trackStartInset,
            endInset: style.trackEndInset,
            minThumb: style.minThumb
        )
        visibility.setShows(shows, now: now)
        if !shows {
            liveOpacity.snap(0.0)
            liveTrack.snap(.zero)
            liveThumb.snap(.zero)
            return
        }

        if scrolledChanged {
            visibility.scrolled(now: now)
        }
        if visibility.alwaysVisible || visibility.overBar || visibility.held {
            liveOpacity.snap(1.0)
        } else if scrolledChanged {
            liveOpacity.pulse(active: 1.0, rest: 0.0, holdSeconds: style.holdDuration)
        } else if !visibility.visible {
            liveOpacity.snap(0.0)
        }

        let viewportW = pos.drawn.x > 0 ? pos.drawn.x : pos.viewport.x
        let viewportH = pos.drawn.y > 0 ? pos.drawn.y : pos.viewport.y
        let stripW = style.resolvedStripWidth
        let effectiveLen = max(trackLen, max(0, metrics.viewport - style.trackStartInset - style.trackEndInset))
        let (rawStart, rawLen) = ScrollBarMath.thumbAlong(
            metrics,
            trackLength: effectiveLen,
            minThumb: style.minThumb,
            devicePixels: style.devicePixels,
            scale: style.scale
        )
        let (pillStart, pillLen) = style.pillExtent(start: rawStart, length: rawLen)
        let activeW = (visibility.isWide || pressTracker.isHeld) ? style.hoverWidth : style.width
        if style.horizontal {
            let y0 = max(0, stripW - style.edgeInset - activeW)
            liveTrack.snap(MotionRect(
                left: 0,
                top: max(0, viewportH - stripW),
                right: viewportW,
                bottom: viewportH
            ))
            liveThumb.snap(MotionRect(
                left: style.trackStartInset + pillStart,
                top: y0,
                right: style.trackStartInset + pillStart + pillLen,
                bottom: y0 + activeW
            ))
        } else {
            let x0 = max(0, stripW - style.edgeInset - activeW)
            liveTrack.snap(MotionRect(
                left: max(0, viewportW - stripW),
                top: 0,
                right: viewportW,
                bottom: viewportH
            ))
            liveThumb.snap(MotionRect(
                left: x0,
                top: style.trackStartInset + pillStart,
                right: x0 + activeW,
                bottom: style.trackStartInset + pillStart + pillLen
            ))
        }
    }
}

/// Bounded kept scrollbar live-binding store (`KEPT = 256`).
public final class ScrollBarLiveStore: @unchecked Sendable {
    public static let shared = ScrollBarLiveStore()
    private let lock = NSLock()
    private var slots: [String: ScrollBarLiveSlot] = [:]

    public init() {}

    public func slot(for key: String, style: KitScrollBarStyle) -> ScrollBarLiveSlot {
        lock.lock()
        defer { lock.unlock() }
        if slots.count >= ScrollBarMetrics.keptLimit, slots[key] == nil {
            slots.removeAll(keepingCapacity: true)
        }
        if let existing = slots[key] {
            existing.syncStyle(style)
            return existing
        }
        let created = ScrollBarLiveSlot(style: style)
        slots[key] = created
        return created
    }
}

extension Kit {
    /// Renders an interactive standalone scrollbar strip using `KitScrollBarStyle` math.
    public func styledScrollBar<State>(
        _ style: KitScrollBarStyle,
        metrics: ScrollAxisMetrics,
        hovered: Bool = false,
        held: Bool = false,
        visible: Bool = true,
        onJump: ((inout State, Float, inout Tx) -> Void)? = nil
    ) -> El<State> {
        let (trackLen, shows) = ScrollBarMath.trackLength(
            for: metrics,
            startInset: style.trackStartInset,
            endInset: style.trackEndInset,
            minThumb: style.minThumb
        )
        let effectiveLen = max(trackLen, max(0, metrics.viewport - style.trackStartInset - style.trackEndInset))
        let (rawStart, rawLen) = ScrollBarMath.thumbAlong(
            metrics,
            trackLength: effectiveLen,
            minThumb: style.minThumb,
            devicePixels: style.devicePixels,
            scale: style.scale
        )
        let (thumbStart, thumbLen) = style.pillExtent(start: rawStart, length: rawLen)
        let activeWidth = (hovered || held) ? style.hoverWidth : style.width
        let thumbFill = (hovered || held) ? style.thumbHoverColor : style.thumbColor
        let strip = style.resolvedStripWidth
        let showOpacity: Float = (shows && (style.alwaysVisible || visible || hovered || held)) ? 1.0 : 0.0

        var thumbEl: El<State> = el()
            .key(style.thumbKey)
            .rounded(style.thumbRadius)
            .bg(thumbFill)
            .opacity(showOpacity)

        var trackEl: El<State> = el()
            .key(style.key)
            .rounded(style.trackRadius)

        if let trackColor = style.trackColor {
            trackEl = trackEl.bg(trackColor)
        }
        if let trackBorderColor = style.trackBorderColor {
            trackEl = trackEl.border(1.0, trackBorderColor)
        }

        if style.horizontal {
            let yOffset = max(0, strip - style.edgeInset - activeWidth)
            thumbEl = thumbEl
                .w(thumbLen)
                .h(activeWidth)
                .absolute(x: style.trackStartInset + thumbStart, y: yOffset)
            trackEl = trackEl
                .w(metrics.viewport)
                .h(strip)
        } else {
            let xOffset = max(0, strip - style.edgeInset - activeWidth)
            thumbEl = thumbEl
                .w(activeWidth)
                .h(thumbLen)
                .absolute(x: xOffset, y: style.trackStartInset + thumbStart)
            trackEl = trackEl
                .w(strip)
                .h(metrics.viewport)
        }

        if let onJump {
            trackEl = trackEl.onDrag { s, d, tx in
                guard effectiveLen > 0, metrics.maxScroll > 0 else { return }
                let along = style.horizontal ? (d.local.x - style.trackStartInset) : (d.local.y - style.trackStartInset)
                let nextOffset = ScrollBarMath.turnedOffset(
                    pointerAlongTrack: along,
                    grab: thumbLen * 0.5,
                    trackLength: effectiveLen,
                    thumbLength: thumbLen,
                    maxScroll: metrics.maxScroll,
                    currentOffset: metrics.offset
                )
                onJump(&s, nextOffset, &tx)
            }
        }

        return trackEl.child(thumbEl)
    }
}

extension El {
    /// Attaches a RuneKit overlay scrollbar container around a scrollable viewport element (`El::scroll_bar`).
    public func scrollBar(_ kit: Kit, viewportKey: String = "scroll") -> El<State> {
        scrollBarStyled(.fromKit(kit), viewportKey: viewportKey)
    }

    /// Attaches a styled scrollbar track/thumb pair overlaid along the scrollable viewport edge (`El::scroll_bar_styled`),
    /// wired to `ScrollBarVisibility`, `ScrollBarPressTracker`, and live `MotionRect`/`Opacity`/`Fill` bindings.
    public func scrollBarStyled(_ style: KitScrollBarStyle, viewportKey: String = "scroll") -> El<State> {
        let systemBars = Rune.systemScrollBars()
        let systemOverlay = Rune.systemScrollerOverlay()
        let jumpPreference = Rune.systemScrollerJumps()
        var effectiveStyle = style
        if !style.alwaysVisible && systemBars.isOverlay(scrollerOverlay: systemOverlay) {
            effectiveStyle.overlay = true
        }
        let slot = ScrollBarLiveStore.shared.slot(for: "\(effectiveStyle.key)::\(viewportKey)", style: effectiveStyle)

        let thumb: El<State> = el()
            .key(effectiveStyle.thumbKey)
            .rounded(effectiveStyle.thumbRadius)
            .bg(effectiveStyle.thumbColor)
            .absolute(x: 0, y: 0)
            .liveRect(slot.liveThumb.smooth(effectiveStyle.tintSpring))
            .liveFill(slot.liveFill.smooth(effectiveStyle.tintSpring))

        var track: El<State> = el()
            .key(effectiveStyle.key)
            .rounded(effectiveStyle.trackRadius)
            .absolute(x: 0, y: 0)
            .liveRect(slot.liveTrack.binding)
            .liveOpacity(slot.liveOpacity.smooth(effectiveStyle.enterSpring).rest(effectiveStyle.leaveSpring))
            .onHover { _, inside, tx in
                slot.hover(inside, style: effectiveStyle)
                tx.liveOnly()
            }
            .onPointerDown { _, press, tx in
                let trackDims = (press.elementSize.x > 0 && press.elementSize.y > 0)
                    ? press.elementSize
                    : slot.liveTrackSize()
                let along = (effectiveStyle.horizontal ? press.local.x : press.local.y) - effectiveStyle.trackStartInset
                let trackSpan = max(
                    effectiveStyle.minThumb,
                    (effectiveStyle.horizontal ? trackDims.x : trackDims.y)
                        - effectiveStyle.trackStartInset
                        - effectiveStyle.trackEndInset
                )
                let result = slot.pointerDownWithResult(
                    along: along,
                    windowPoint: press.window,
                    trackLength: trackSpan,
                    trackSize: trackDims,
                    altPressed: press.mods.alt,
                    jumpPreference: jumpPreference,
                    style: effectiveStyle
                )
                switch result {
                case .page(let toward):
                    let step = max(1.0, slot.lastMetrics.viewport * 0.9)
                    let targetOffset = (slot.lastMetrics.offset + Float(toward) * step).clamped(to: 0...slot.lastMetrics.maxScroll)
                    if let pageOffset = slot.pageTargetOffset(along: along, trackLength: trackSpan, style: effectiveStyle) {
                        tx.scrollTo(
                            viewportKey,
                            offset: effectiveStyle.horizontal ? Vec2(pageOffset, 0) : Vec2(0, pageOffset),
                            animated: true
                        )
                    } else if abs(targetOffset - slot.lastMetrics.offset) >= 1e-4 {
                        tx.scrollTo(
                            viewportKey,
                            offset: effectiveStyle.horizontal ? Vec2(targetOffset, 0) : Vec2(0, targetOffset),
                            animated: true
                        )
                    }
                    tx.dragRepeatAfter(0.30)
                    tx.liveOnly()
                case .jump(let nextOffset):
                    tx.scrollTo(
                        viewportKey,
                        offset: effectiveStyle.horizontal ? Vec2(nextOffset, 0) : Vec2(0, nextOffset),
                        animated: false
                    )
                    tx.liveOnly()
                case .grabThumb:
                    tx.liveOnly()
                }
            }
            .onDrag { _, d, tx in
                let trackDims = (d.size.x > 0 && d.size.y > 0) ? d.size : slot.liveTrackSize()
                let along = (effectiveStyle.horizontal ? d.local.x : d.local.y) - effectiveStyle.trackStartInset
                if tx.isDragRepeat {
                    let trackSpan = max(
                        effectiveStyle.minThumb,
                        (effectiveStyle.horizontal ? trackDims.x : trackDims.y)
                            - effectiveStyle.trackStartInset
                            - effectiveStyle.trackEndInset
                    )
                    if let nextPage = slot.pageTargetOffset(along: along, trackLength: trackSpan, style: effectiveStyle) {
                        tx.scrollTo(
                            viewportKey,
                            offset: effectiveStyle.horizontal ? Vec2(nextPage, 0) : Vec2(0, nextPage),
                            animated: true
                        )
                        tx.dragRepeatAfter(0.05)
                    }
                } else if let nextOffset = slot.dragIfThumb(along: along, windowPoint: d.window, trackSize: trackDims, style: effectiveStyle) {
                    tx.scrollTo(
                        viewportKey,
                        offset: effectiveStyle.horizontal ? Vec2(nextOffset, 0) : Vec2(0, nextOffset),
                        animated: false
                    )
                }
                tx.liveOnly()
            }
            .onDragEnd { _, _, tx in
                slot.release(style: effectiveStyle)
                tx.liveOnly()
            }
            .child(thumb)

        if let trackColor = effectiveStyle.trackColor {
            track = track.bg(trackColor)
        }
        if let trackBorderColor = effectiveStyle.trackBorderColor {
            track = track.border(1.0, trackBorderColor)
        }

        // Transfer outer box/flex/positioning layout properties onto the wrapper `col()`
        // so the wrapped viewport lays out identically to the bare viewport (`scroll_bar.rs`).
        var outer: El<State> = col()
            .key("\(effectiveStyle.key)-wrap-\(viewportKey)")
        outer.layout.displayNone = self.layout.displayNone
        outer.layout.width = self.layout.width
        outer.layout.height = self.layout.height
        outer.layout.minWidth = (self.layout.scrollAxes.contains(.horizontal) && self.layout.minWidth == .auto)
            ? .points(0)
            : self.layout.minWidth
        outer.layout.minHeight = (self.layout.scrollAxes.contains(.vertical) && self.layout.minHeight == .auto)
            ? .points(0)
            : self.layout.minHeight
        outer.layout.maxWidth = self.layout.maxWidth
        outer.layout.maxHeight = self.layout.maxHeight
        outer.layout.flexGrow = self.layout.flexGrow
        outer.layout.flexShrink = self.layout.flexShrink
        outer.layout.flexBasis = self.layout.flexBasis
        outer.layout.margin = self.layout.margin
        outer.layout.alignSelf = self.layout.alignSelf
        outer.layout.aspectRatio = self.layout.aspectRatio
        outer.layout.aspectFit = self.layout.aspectFit
        outer.layout.gridItem = self.layout.gridItem
        outer.layout.isAbsolute = self.layout.isAbsolute
        outer.layout.pinLeft = self.layout.pinLeft
        outer.layout.pinTop = self.layout.pinTop
        outer.layout.pinRight = self.layout.pinRight
        outer.layout.pinBottom = self.layout.pinBottom
        outer.layout.sticky = self.layout.sticky

        var inner = self
        inner.layout.displayNone = false
        inner.layout.width = .fraction(1.0)
        inner.layout.height = .auto
        inner.layout.minWidth = .points(0)
        inner.layout.minHeight = .points(0)
        inner.layout.maxWidth = .auto
        inner.layout.maxHeight = .auto
        inner.layout.flexGrow = 1
        inner.layout.flexShrink = 1
        inner.layout.flexBasis = .auto
        inner.layout.margin = .all(0)
        inner.layout.alignSelf = nil
        inner.layout.aspectRatio = nil
        inner.layout.aspectFit = nil
        inner.layout.gridItem = nil
        inner.layout.isAbsolute = false
        inner.layout.pinLeft = nil
        inner.layout.pinTop = nil
        inner.layout.pinRight = nil
        inner.layout.pinBottom = nil
        inner.layout.sticky = nil

        return outer
            .child(inner.chainScrollOffset { pos in
                slot.updateFromScrollPos(pos, style: effectiveStyle)
            })
            .child(track)
    }

    /// Marks an element as an edge hover target for an overlay scrollbar (`El::scroll_bar_hover`).
    public func scrollBarHover(_ viewportKey: String) -> El<State> {
        self.key("\(viewportKey)-hover-target")
    }
}
