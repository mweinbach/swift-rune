import Foundation
import Rune
import RuneMotion

// MARK: - ScrollBar Constants (`rune_kit::scroll_bar`)

public enum ScrollBarMetrics {
    public static let thumbWidth: Float = 4.0
    public static let thumbHoverWidth: Float = 8.0
    public static let inset: Float = 2.0
    public static let stripWidth: Float = 10.0
    public static let hoverStripWidth: Float = 24.0
    public static let minThumbLength: Float = 20.0
    public static let fadeDelay: Double = 0.8
    public static let pageDelay: Double = 0.4
    public static let pageInterval: Double = 0.08
}

// MARK: - Style & Configuration (`KitScrollBarStyle`)

/// Visual and behavioral configuration for a RuneKit scrollbar (`rune_kit::scroll_bar::ScrollBarStyle`).
/// Named `KitScrollBarStyle` to avoid colliding with `Rune.ScrollBarStyle` (the OS preference enum).
public struct KitScrollBarStyle: Sendable, Equatable {
    public var key: String = "scroll-bar"
    public var thumbKey: String = "thumb"
    public var horizontal: Bool = false
    public var inside: Bool = false
    public var hoverTarget: String? = nil
    public var trackStartInset: Float = ScrollBarMetrics.inset
    public var trackEndInset: Float = ScrollBarMetrics.inset
    public var edgeInset: Float = ScrollBarMetrics.inset
    public var stripWidth: Float = ScrollBarMetrics.stripWidth
    public var hoverStripWidth: Float = ScrollBarMetrics.hoverStripWidth
    public var width: Float = ScrollBarMetrics.thumbWidth
    public var hoverWidth: Float = ScrollBarMetrics.thumbHoverWidth
    public var minThumb: Float = ScrollBarMetrics.minThumbLength
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
        KitScrollBarStyle(
            thumbColor: kit.c.borderStrong.alpha(0.65),
            thumbHoverColor: kit.c.borderStrong,
            trackColor: nil
        )
    }

    /// Preset tuned for general application scroll viewports (`ScrollBarStyle::scroll_view`).
    public static func scrollView(_ kit: Kit) -> KitScrollBarStyle {
        fromKit(kit)
            .inside(true)
            .width(ScrollBarMetrics.thumbWidth)
            .hoverWidth(ScrollBarMetrics.thumbHoverWidth)
    }

    /// Native desktop overlay/inset scrollbar preset (`ScrollBarStyle::native`).
    public static func native(_ kit: Kit) -> KitScrollBarStyle {
        fromKit(kit)
            .inside(true)
            .devicePixels(true)
    }

    /// Compact scrollbar preset for menus, popups, and lists (`ScrollBarStyle::menu_scroll`).
    public static func menuScroll(_ kit: Kit) -> KitScrollBarStyle {
        fromKit(kit)
            .inside(true)
            .width(3.5)
            .hoverWidth(6.0)
            .minThumb(16.0)
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

    /// Computes usable track length and whether the scrollbar should appear.
    public static func trackLength(
        for metrics: ScrollAxisMetrics,
        startInset: Float = ScrollBarMetrics.inset,
        endInset: Float = ScrollBarMetrics.inset
    ) -> (length: Float, shows: Bool) {
        let len = max(0, metrics.viewport - startInset - endInset)
        let shows = metrics.content > metrics.viewport + 0.5 && len > 0
        return (len, shows)
    }

    /// Computes thumb `(start, length)` along the track, including rubber-band overscroll compression.
    public static func thumbAlong(
        _ metrics: ScrollAxisMetrics,
        trackLength: Float,
        minThumb: Float = ScrollBarMetrics.minThumbLength,
        devicePixels: Bool = true,
        scale: Float = 1.0
    ) -> (start: Float, length: Float) {
        guard trackLength > 0, metrics.content > 0, metrics.viewport > 0 else {
            return (0, 0)
        }
        let ratio = min(1.0, metrics.viewport / metrics.content)
        let rawLen = trackLength * ratio
        let maxScroll = metrics.maxScroll

        let over: Float
        if metrics.offset < 0 {
            over = -metrics.offset
        } else if metrics.offset > maxScroll {
            over = metrics.offset - maxScroll
        } else {
            over = 0
        }

        let compressed: Float
        if over > 0 {
            let scaleDown = metrics.viewport / (metrics.viewport + over)
            compressed = rawLen * scaleDown
        } else {
            compressed = rawLen
        }

        let len = min(trackLength, align(max(minThumb, compressed), devicePixels: devicePixels, scale: scale))
        let travel = max(0, trackLength - len)
        let frac: Float
        if maxScroll <= 0 {
            frac = 0
        } else {
            frac = (metrics.offset / maxScroll).clamped(to: 0...1)
        }
        let start = align(frac * travel, devicePixels: devicePixels, scale: scale).clamped(to: 0...travel)
        return (start, len)
    }

    /// Maps a thumb start position along the track back to content scroll offset.
    public static func offsetAlong(
        thumbStart: Float,
        trackLength: Float,
        thumbLength: Float,
        maxScroll: Float
    ) -> Float {
        let travel = trackLength - thumbLength
        guard travel > 0, maxScroll > 0 else { return 0 }
        let frac = (thumbStart / travel).clamped(to: 0...1)
        return frac * maxScroll
    }

    /// Converts a drag position along the track (and initial thumb grab offset) into a scroll offset.
    public static func turnedOffset(
        pointerAlongTrack: Float,
        grab: Float,
        trackLength: Float,
        thumbLength: Float,
        maxScroll: Float
    ) -> Float {
        offsetAlong(
            thumbStart: pointerAlongTrack - grab,
            trackLength: trackLength,
            thumbLength: thumbLength,
            maxScroll: maxScroll
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

// MARK: - El & Kit ScrollBar Builders

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
            endInset: style.trackEndInset
        )
        let effectiveLen = max(trackLen, max(0, metrics.viewport - style.trackStartInset - style.trackEndInset))
        let (thumbStart, thumbLen) = ScrollBarMath.thumbAlong(
            metrics,
            trackLength: effectiveLen,
            minThumb: style.minThumb,
            devicePixels: style.devicePixels,
            scale: style.scale
        )
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
                    maxScroll: metrics.maxScroll
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
        scrollBarStyled(.scrollView(kit), viewportKey: viewportKey)
    }

    /// Attaches a styled scrollbar track/thumb pair overlaid along the scrollable viewport edge (`El::scroll_bar_styled`).
    public func scrollBarStyled(_ style: KitScrollBarStyle, viewportKey: String = "scroll") -> El<State> {
        let stripW = style.resolvedStripWidth
        var thumb: El<State> = el()
            .key(style.thumbKey)
            .rounded(style.thumbRadius)
            .bg(style.thumbColor)
            .transition(Transition.opacity.spring(.snappy))

        if style.horizontal {
            thumb = thumb.w(max(style.minThumb, 24)).h(style.width).pill()
        } else {
            thumb = thumb.w(style.width).h(max(style.minThumb, 24)).pill()
        }

        var track: El<State> = el()
            .key(style.key)
            .rounded(style.trackRadius)
            .p(style.edgeInset)
            .child(thumb)

        if let trackColor = style.trackColor {
            track = track.bg(trackColor)
        }
        if let trackBorderColor = style.trackBorderColor {
            track = track.border(1.0, trackBorderColor)
        }

        if style.horizontal {
            track = track
                .h(stripW)
                .pin(right: style.trackEndInset, bottom: 0, left: style.trackStartInset)
                .onDrag { _, d, tx in
                    tx.scrollTo(viewportKey, offset: Vec2(max(0, d.local.x), 0), animated: false)
                }
        } else {
            track = track
                .w(stripW)
                .pin(top: style.trackStartInset, right: 0, bottom: style.trackEndInset)
                .onDrag { _, d, tx in
                    tx.scrollTo(viewportKey, offset: Vec2(0, max(0, d.local.y)), animated: false)
                }
        }

        return el()
            .key("\(style.key)-wrap-\(viewportKey)")
            .child(self)
            .child(track)
    }

    /// Marks an element as an edge hover target for an overlay scrollbar (`El::scroll_bar_hover`).
    public func scrollBarHover(_ viewportKey: String) -> El<State> {
        self.key("\(viewportKey)-hover-target")
    }
}
