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
    public var thumbOnly: Bool = false
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
    public var devicePixels: Bool = false
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
        s.thumbOnly = true
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
        s.thumbOnly = true
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

    public func thumbOnly(_ enabled: Bool = true) -> Self {
        var copy = self; copy.thumbOnly = enabled; return copy
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
        horizontal: Bool,
        thumbOnly: Bool = false
    ) -> ScrollBarPress {
        if thumbOnly {
            return .thumb(grab: 0.0)
        }
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

/// Deterministic visibility & thumb-length glide state machine (`crates/rune-kit/src/scroll_bar/visibility.rs`).
public enum ScrollBarVisibilityMachine {
    public static let fadeTail: Double = 0.35
    public static let glideSpan: Double = 0.5

    public enum Phase: Equatable, Sendable {
        case hidden
        case pulsing(until: Double)
        case held

        public func visible(at now: Double) -> Bool {
            switch self {
            case .hidden: return false
            case .pulsing(let until): return now < until
            case .held: return true
            }
        }
    }

    public enum Glide: Equatable, Sendable {
        case idle
        case running(until: Double)
    }

    public enum BarState: Equatable, Sendable {
        case uninit
        case noOverflow
        case always(glide: Glide)
        case overlay(phase: Phase, glide: Glide)

        public func gliding(at now: Double) -> Bool {
            switch glide {
            case .idle: return false
            case .running(let until): return now < until
            }
        }

        public func seen(at now: Double) -> Bool {
            switch self {
            case .always: return true
            case .overlay(let phase, _): return phase.visible(at: now)
            case .uninit, .noOverflow: return false
            }
        }

        public var pulseUntil: Double {
            switch self {
            case .overlay(let phase, _):
                switch phase {
                case .pulsing(let until): return until
                case .held: return .infinity
                case .hidden: return -1.0
                }
            default:
                return -1.0
            }
        }

        private var glide: Glide {
            switch self {
            case .always(let g), .overlay(_, let g): return g
            case .uninit, .noOverflow: return .idle
            }
        }
    }

    public struct Follow: Equatable, Sendable {
        public var shows: Bool
        public var overlay: Bool
        public var scrolled: Bool
        public var instant: Bool
        public var resized: Bool
        public var lengthened: Bool
        public var extentChanged: Bool
        public var pressed: Bool
        public var revealed: Bool
        public var now: Double
        public var holdSeconds: Double

        public init(
            shows: Bool,
            overlay: Bool,
            scrolled: Bool,
            instant: Bool,
            resized: Bool,
            lengthened: Bool,
            extentChanged: Bool,
            pressed: Bool,
            revealed: Bool,
            now: Double,
            holdSeconds: Double
        ) {
            self.shows = shows
            self.overlay = overlay
            self.scrolled = scrolled
            self.instant = instant
            self.resized = resized
            self.lengthened = lengthened
            self.extentChanged = extentChanged
            self.pressed = pressed
            self.revealed = revealed
            self.now = now
            self.holdSeconds = holdSeconds
        }
    }

    public enum Event: Equatable, Sendable {
        case follow(Follow)
        case hold
        case letGo(pressed: Bool, revealed: Bool, areaReveals: Bool, now: Double, holdSeconds: Double)
    }

    public enum OpacityEffect: Equatable, Sendable {
        case set(Float)
        case snap(Float)
        case pulse(holdSeconds: Double)
    }

    public enum Effect: Equatable, Sendable {
        case glide(glides: Bool, cut: Bool)
        case opacity(OpacityEffect)
    }

    public static func step(_ state: inout BarState, _ event: Event) -> [Effect] {
        switch event {
        case .follow(let f):
            return follow(&state, f)
        case .hold:
            return hold(&state)
        case .letGo(let pressed, let revealed, let areaReveals, let now, let holdSeconds):
            guard case .overlay(_, let glide) = state else { return [] }
            if pressed || revealed { return [] }
            let phase: Phase
            let opacity: OpacityEffect
            if areaReveals {
                phase = .hidden
                opacity = .set(0.0)
            } else {
                phase = .pulsing(until: now + (holdSeconds + fadeTail))
                opacity = .pulse(holdSeconds: holdSeconds)
            }
            state = .overlay(phase: phase, glide: glide)
            return [.opacity(opacity)]
        }
    }

    private static func hold(_ state: inout BarState) -> [Effect] {
        guard case .overlay(_, let glide) = state else { return [] }
        state = .overlay(phase: .held, glide: glide)
        return [.opacity(.set(1.0))]
    }

    private static func follow(_ state: inout BarState, _ f: Follow) -> [Effect] {
        let prev = state
        let gliding = prev.gliding(at: f.now)
        let glides = f.shows && !f.scrolled && !f.instant && !f.resized && (f.lengthened || gliding) && prev.seen(at: f.now)
        let cut = gliding && !glides
        let glide: Glide
        if !glides {
            glide = .idle
        } else if f.lengthened {
            glide = .running(until: f.now + glideSpan)
        } else {
            switch prev {
            case .always(let g), .overlay(_, let g): glide = g
            case .uninit, .noOverflow: glide = .idle
            }
        }
        var effects: [Effect] = [.glide(glides: glides, cut: cut)]

        if !f.shows {
            state = .noOverflow
            if prev != .noOverflow {
                effects.append(.opacity(.snap(1.0)))
            }
            return effects
        }

        if !f.overlay {
            state = .always(glide: glide)
            switch prev {
            case .overlay where !f.instant:
                effects.append(.opacity(.set(1.0)))
            case .always:
                break
            default:
                effects.append(.opacity(.snap(1.0)))
            }
            return effects
        }

        if f.pressed || f.revealed {
            state = .overlay(phase: .held, glide: glide)
            effects.append(.opacity(.set(1.0)))
            return effects
        }

        func makePulse() -> (Phase, OpacityEffect?) {
            (.pulsing(until: f.now + (f.holdSeconds + fadeTail)), .pulse(holdSeconds: f.holdSeconds))
        }

        let phase: Phase
        let opacity: OpacityEffect?
        switch prev {
        case .always:
            if f.scrolled && !f.instant {
                (phase, opacity) = makePulse()
            } else if f.instant {
                (phase, opacity) = (.hidden, .snap(0.0))
            } else {
                (phase, opacity) = (.hidden, .set(0.0))
            }
        case .overlay(let oldPhase, _):
            if (f.scrolled && !f.instant) || ((f.scrolled || f.extentChanged) && f.instant && oldPhase.visible(at: f.now)) {
                (phase, opacity) = makePulse()
            } else {
                (phase, opacity) = (oldPhase, nil)
            }
        case .uninit, .noOverflow:
            if f.scrolled && !f.instant {
                (phase, opacity) = makePulse()
            } else {
                (phase, opacity) = (.hidden, .snap(0.0))
            }
        }
        state = .overlay(phase: phase, glide: glide)
        if let opacity {
            effects.append(.opacity(opacity))
        }
        return effects
    }
}

// MARK: - Live Kept Store (`KEPT = 256`) & El / Kit ScrollBar Builders

/// Live presentation bindings + interaction trackers retained across frames per scrollbar key.
public final class ScrollBarLiveSlot: @unchecked Sendable {
    private let lock = NSLock()
    public let liveTrack: Live<MotionRect>
    public let liveSlot: Live<MotionRect>
    public let liveThumb: Live<MotionRect>
    public let liveOpacity: Live<Float>
    public let liveFill: Live<Color>
    public var visibility: ScrollBarVisibility
    public private(set) var barState: ScrollBarVisibilityMachine.BarState = .uninit
    public var pressTracker: ScrollBarPressTracker
    public var lastMetrics: ScrollAxisMetrics

    private var lastPos: ScrollPos = ScrollPos()
    private var lastStyle: KitScrollBarStyle
    private var hasAppliedStyle: Bool = false
    private var near: Bool = false
    private var overBar: Bool = false
    private var targetHovered: Bool = false
    private var lastNow: Double = 0.0
    private var thumbDragOriginStart: Float? = nil
    private var thumbDragOriginWindow: Vec2? = nil

    public init(style: KitScrollBarStyle) {
        self.lastStyle = style
        self.liveTrack = Live(MotionRect(left: 0, top: 0, right: style.resolvedStripWidth, bottom: 100))
        self.liveSlot = Live(MotionRect(left: style.resolvedStripWidth - style.edgeInset - max(style.width, style.hoverWidth), top: 0, right: style.resolvedStripWidth - style.edgeInset, bottom: style.minThumb))
        self.liveThumb = Live(MotionRect(left: max(0, style.hoverWidth - style.width), top: 0, right: max(style.width, style.hoverWidth), bottom: style.minThumb))
        self.liveOpacity = Live(style.alwaysVisible || !style.overlay ? 1.0 : 0.0)
        self.liveFill = Live(style.thumbColor)
        self.visibility = ScrollBarVisibility(alwaysVisible: style.alwaysVisible || !style.overlay, shows: true)
        self.pressTracker = ScrollBarPressTracker()
        self.lastMetrics = ScrollAxisMetrics(offset: 0, content: 400, viewport: 100)
    }

    private var wideLocked: Bool {
        overBar || pressTracker.isHeld
    }

    private var revealedLocked: Bool {
        near || targetHovered
    }

    private var isRTLLocked: Bool {
        lastPos.direction == .rtl
    }

    private func turnedRect(_ style: KitScrollBarStyle, across: Float, along: Float, thick: Float, long: Float) -> MotionRect {
        if style.horizontal {
            return MotionRect.fromXYWH(along, across, long, thick)
        }
        return MotionRect.fromXYWH(across, along, thick, long)
    }

    private func flowedRect(_ r: MotionRect, within: Float) -> MotionRect {
        if isRTLLocked {
            return MotionRect.fromXYWH(within - r.x - r.width, r.y, r.width, r.height)
        }
        return r
    }

    private func trackMetrics(for pos: ScrollPos, style: KitScrollBarStyle) -> (metrics: ScrollAxisMetrics, trackLen: Float, shows: Bool, effectiveLen: Float) {
        let axisOffset = style.horizontal ? pos.offset.x : pos.offset.y
        let axisViewport = style.horizontal ? pos.viewport.x : pos.viewport.y
        let axisMax = style.horizontal ? pos.max.x : pos.max.y
        let metrics = ScrollAxisMetrics(
            offset: axisOffset,
            content: axisViewport + axisMax,
            viewport: axisViewport
        )
        let (len, shows) = ScrollBarMath.trackLength(
            for: metrics,
            startInset: style.trackStartInset,
            endInset: style.trackEndInset,
            minThumb: style.minThumb
        )
        let effectiveLen = max(0, len)
        return (metrics, len, shows, effectiveLen)
    }

    private func thumbGeometry(metrics: ScrollAxisMetrics, effectiveLen: Float, shows: Bool, style: KitScrollBarStyle) -> (top: Float, length: Float) {
        let (rawStart, rawLen) = ScrollBarMath.thumbAlong(
            metrics,
            trackLength: effectiveLen,
            minThumb: style.minThumb,
            devicePixels: style.devicePixels,
            scale: style.scale
        )
        let (pillStart, pillLen) = style.pillExtent(start: rawStart, length: rawLen)
        return (pillStart, shows ? pillLen : 0.0)
    }

    private func trackRect(pos: ScrollPos, len: Float, shows: Bool, style: KitScrollBarStyle) -> MotionRect {
        let stripW = style.resolvedStripWidth
        let viewportW = pos.drawn.x > 0 ? pos.drawn.x : pos.viewport.x
        let viewportH = pos.drawn.y > 0 ? pos.drawn.y : pos.viewport.y
        let acrossSpan = style.horizontal ? viewportH : viewportW
        let from = (style.gutter && !style.inside) ? acrossSpan : (acrossSpan - stripW)
        let drawnLen = shows ? max(0, len) : 0.0
        return flowedRect(turnedRect(style, across: from, along: style.trackStartInset, thick: stripW, long: drawnLen), within: viewportW)
    }

    private func slotRect(top: Float, h: Float, trackLen: Float, style: KitScrollBarStyle) -> MotionRect {
        let stripW = style.resolvedStripWidth
        let widest = max(style.width, style.hoverWidth)
        let start = style.thumbOnly ? Float(0.0) : (stripW - style.edgeInset - widest)
        let width = style.thumbOnly ? stripW : widest
        let within = style.horizontal ? max(0, trackLen) : stripW
        return flowedRect(turnedRect(style, across: start, along: top, thick: width, long: h), within: within)
    }

    private func thumbRect(h: Float, style: KitScrollBarStyle) -> MotionRect {
        let widest = max(style.width, style.hoverWidth)
        let w = wideLocked ? style.hoverWidth : style.width
        let slotSpan = style.thumbOnly ? style.resolvedStripWidth : widest
        let end = style.thumbOnly ? style.edgeInset : Float(0.0)
        let within = style.horizontal ? h : slotSpan
        return flowedRect(turnedRect(style, across: slotSpan - end - w, along: 0, thick: w, long: h), within: within)
    }

    private func currentThumbLenLocked(style: KitScrollBarStyle) -> Float {
        let r = liveThumb.get()
        return style.horizontal ? r.width : r.height
    }

    private func widenLocked(style: KitScrollBarStyle) {
        let h = currentThumbLenLocked(style: style)
        liveThumb.set(thumbRect(h: h, style: style))
        liveFill.set(wideLocked ? style.thumbHoverColor : style.thumbColor)
    }

    private func syncCompatibilityVisibility(overlay: Bool, shows: Bool, now: Double) {
        visibility.shows = shows
        visibility.alwaysVisible = !overlay
        visibility.overBar = overBar
        visibility.held = pressTracker.isHeld
        visibility.insideViewport = revealedLocked
        visibility.tick(now: now)
    }

    @discardableResult
    private func stepVisibilityLocked(_ event: ScrollBarVisibilityMachine.Event, style: KitScrollBarStyle) -> (glides: Bool, cut: Bool) {
        let effects = ScrollBarVisibilityMachine.step(&barState, event)
        var glides = false
        var cut = false
        for effect in effects {
            switch effect {
            case let .glide(g, c):
                glides = g
                cut = c
            case .opacity(let change):
                switch change {
                case .set(let o):
                    liveOpacity.set(o)
                case .snap(let o):
                    liveOpacity.snap(o)
                case .pulse(let hold):
                    liveOpacity.pulse(active: 1.0, rest: 0.0, holdSeconds: hold)
                }
            }
        }
        return (glides, cut)
    }

    private func holdLocked(style: KitScrollBarStyle) {
        _ = stepVisibilityLocked(.hold, style: style)
    }

    private func letGoLocked(style: KitScrollBarStyle, now: Double) {
        _ = stepVisibilityLocked(
            .letGo(
                pressed: pressTracker.isHeld,
                revealed: revealedLocked,
                areaReveals: style.areaReveals,
                now: now,
                holdSeconds: style.holdDuration
            ),
            style: style
        )
    }

    private func revealLocked(style: KitScrollBarStyle, now: Double, _ change: () -> Void) {
        let was = revealedLocked
        change()
        switch (was, revealedLocked) {
        case (false, true):
            holdLocked(style: style)
        case (true, false):
            letGoLocked(style: style, now: now)
        default:
            break
        }
    }

    public func syncStyle(_ style: KitScrollBarStyle) {
        lock.lock()
        defer { lock.unlock() }
        if hasAppliedStyle && style == lastStyle {
            return
        }
        hasAppliedStyle = true
        lastStyle = style
        liveFill.snap(wideLocked ? style.thumbHoverColor : style.thumbColor)
        let info = trackMetrics(for: lastPos, style: style)
        let (top, h) = thumbGeometry(metrics: info.metrics, effectiveLen: info.effectiveLen, shows: info.shows, style: style)
        liveTrack.snap(trackRect(pos: lastPos, len: info.trackLen, shows: info.shows, style: style))
        liveSlot.snap(slotRect(top: top, h: h, trackLen: info.trackLen, style: style))
        liveThumb.snap(thumbRect(h: h, style: style))
    }

    public func hover(_ inside: Bool, style: KitScrollBarStyle, now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }
        lastStyle = style
        lastNow = max(lastNow, now)
        if overBar != inside {
            overBar = inside
            widenLocked(style: style)
        }
        revealLocked(style: style, now: lastNow) {
            near = inside
        }
        syncCompatibilityVisibility(overlay: style.overlay, shows: visibility.shows, now: lastNow)
    }

    public func hoverTarget(_ inside: Bool, style: KitScrollBarStyle? = nil, now: Double) {
        lock.lock()
        defer { lock.unlock() }
        let s = style ?? lastStyle
        lastNow = max(lastNow, now)
        revealLocked(style: s, now: lastNow) {
            targetHovered = inside
        }
        syncCompatibilityVisibility(overlay: s.overlay, shows: visibility.shows, now: lastNow)
    }

    public func pointer(localPoint: Vec2?, windowPoint: Vec2?, style: KitScrollBarStyle, now: Double) {
        lock.lock()
        defer { lock.unlock() }
        lastStyle = style
        lastNow = max(lastNow, now)
        if let wp = windowPoint, pressTracker.observePointerMove(at: wp) != nil {
            widenLocked(style: style)
            letGoLocked(style: style, now: lastNow)
        }
        pointLocked(localPoint: localPoint, style: style, now: lastNow)
        syncCompatibilityVisibility(overlay: style.overlay, shows: visibility.shows, now: lastNow)
    }

    private func pointLocked(localPoint: Vec2?, style: KitScrollBarStyle, now: Double) {
        let info = trackMetrics(for: lastPos, style: style)
        let w = style.horizontal ? lastPos.viewport.y : lastPos.viewport.x
        let hAll = style.horizontal ? lastPos.viewport.x : lastPos.viewport.y
        let gutter = (style.gutter && !style.inside) ? style.resolvedStripWidth : 0.0
        let trackW = style.resolvedStripWidth
        let barEnd = w + gutter
        let lo = style.trackStartInset
        let len = max(0, info.trackLen)
        let rawP = localPoint.map { p in
            let mx = isRTLLocked ? (lastPos.viewport.x - p.x) : p.x
            return style.horizontal ? Vec2(p.y, mx) : Vec2(mx, p.y)
        }
        let (thumbTop, thumbH) = ScrollBarMath.thumbAlong(
            info.metrics,
            trackLength: info.effectiveLen,
            minThumb: style.minThumb,
            devicePixels: style.devicePixels,
            scale: style.scale
        )
        func inStrip(_ across: Float, _ along: Float) -> Bool {
            across >= (barEnd - trackW) && across <= barEnd && along >= lo && along <= (lo + len)
        }
        func onThumb(_ p: Vec2) -> Bool {
            inStrip(p.x, p.y) && (!style.areaReveals || (p.y >= lo + thumbTop && p.y <= lo + thumbTop + thumbH))
        }
        let targeted = style.hoverTarget != nil
        let nextNear: Bool
        if info.shows, let p = rawP {
            if style.scrollOnly {
                nextNear = onThumb(p) && (near || lastNow < barState.pulseUntil)
            } else if targeted {
                nextNear = onThumb(p)
            } else if style.areaReveals {
                nextNear = p.x >= 0 && p.x <= (w + gutter) && p.y >= 0 && p.y <= hAll
            } else {
                let revealEdge = max(style.hoverStripWidth, trackW)
                nextNear = p.x >= (barEnd - revealEdge) && p.x <= barEnd && p.y >= lo && p.y <= (lo + len)
            }
        } else {
            nextNear = false
        }
        let nextOver = nextNear && rawP.map(onThumb) == true
        if overBar != nextOver {
            overBar = nextOver
            widenLocked(style: style)
        }
        revealLocked(style: style, now: now) {
            near = nextNear
        }
    }

    public enum PointerDownResult: Sendable, Equatable {
        case grabThumb
        case jump(Float)
        case page(Int32)
    }

    @discardableResult
    public func pointerDown(
        along: Float,
        windowPoint: Vec2 = .zero,
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
        lastNow = max(lastNow, now)
        let info = trackMetrics(for: lastPos, style: style)
        let (rawStart, rawLen) = ScrollBarMath.thumbAlong(
            info.metrics,
            trackLength: max(style.minThumb, trackLength),
            minThumb: style.minThumb,
            devicePixels: style.devicePixels,
            scale: style.scale
        )
        let onThumb = style.thumbOnly || (along >= rawStart && along <= (rawStart + rawLen))
        let action = ScrollBarPress.begin(
            pointerAlongTrack: style.thumbOnly ? rawStart : along,
            thumbStart: rawStart,
            thumbLength: rawLen,
            altPressed: altPressed,
            jumpPreference: jumpPreference,
            horizontal: style.horizontal,
            thumbOnly: style.thumbOnly
        )
        pressTracker.pointerDown(action, at: windowPoint)
        if style.thumbOnly {
            thumbDragOriginStart = rawStart
            thumbDragOriginWindow = windowPoint
        } else {
            thumbDragOriginStart = nil
            thumbDragOriginWindow = nil
        }
        holdLocked(style: style)
        widenLocked(style: style)
        syncCompatibilityVisibility(overlay: style.overlay, shows: info.shows, now: lastNow)
        if case .pages(let toward) = action {
            return (action, .page(toward))
        }
        if !onThumb {
            let resolvedSize = trackSize ?? Vec2(liveTrack.get().width, liveTrack.get().height)
            let nextOffset = applyThumbDragLocked(along: along, trackSize: resolvedSize, style: style)
            return (action, .jump(nextOffset))
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
        let info = trackMetrics(for: lastPos, style: style)
        let (currentStart, currentLen) = ScrollBarMath.thumbAlong(
            info.metrics,
            trackLength: max(style.minThumb, trackLength),
            minThumb: style.minThumb,
            devicePixels: style.devicePixels,
            scale: style.scale
        )
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
        var effectiveAlong = along
        if style.thumbOnly {
            guard let originStart = thumbDragOriginStart, let originW = thumbDragOriginWindow else {
                return nil
            }
            let rawDelta = style.horizontal
                ? (isRTLLocked ? (originW.x - windowPoint.x) : (windowPoint.x - originW.x))
                : (windowPoint.y - originW.y)
            if abs(rawDelta) < 1e-6 {
                return nil
            }
            effectiveAlong = originStart + rawDelta
        }
        let resolvedSize = (trackSize.x > 0 && trackSize.y > 0)
            ? trackSize
            : Vec2(liveTrack.get().width, liveTrack.get().height)
        return applyThumbDragLocked(along: effectiveAlong, trackSize: resolvedSize, style: style)
    }

    private func applyThumbDragLocked(along: Float, trackSize: Vec2, style: KitScrollBarStyle) -> Float {
        let rawSpan = style.horizontal ? trackSize.x : trackSize.y
        let effectiveLen = max(style.minThumb, rawSpan)
        let info = trackMetrics(for: lastPos, style: style)
        let (_, thumbLen) = ScrollBarMath.thumbAlong(
            info.metrics,
            trackLength: effectiveLen,
            minThumb: style.minThumb,
            devicePixels: style.devicePixels,
            scale: style.scale
        )
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
        liveSlot.snap(slotRect(top: pillStart, h: pillLen, trackLen: effectiveLen, style: style))
        liveThumb.snap(thumbRect(h: pillLen, style: style))
        return nextOffset
    }

    public func release(style: KitScrollBarStyle, now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }
        lastNow = max(lastNow, now)
        _ = pressTracker.pointerUp()
        thumbDragOriginStart = nil
        thumbDragOriginWindow = nil
        widenLocked(style: style)
        letGoLocked(style: style, now: lastNow)
        syncCompatibilityVisibility(overlay: style.overlay, shows: visibility.shows, now: lastNow)
    }

    public func updateFromScrollPos(
        _ pos: ScrollPos,
        style: KitScrollBarStyle,
        watch: ScrollWatchState? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        lastStyle = style
        var at = pos
        if at.drawn.x > 0 && at.drawn.y > 0 {
            at.viewport = at.drawn
        }
        let prevAt = lastPos
        lastPos = at
        let w = watch ?? scrollWatchState()
        lastNow = w.now
        let info = trackMetrics(for: at, style: style)
        lastMetrics = info.metrics
        let overlay = style.overlay

        liveTrack.set(trackRect(pos: at, len: info.trackLen, shows: info.shows, style: style))
        let (top, h) = thumbGeometry(metrics: info.metrics, effectiveLen: info.effectiveLen, shows: info.shows, style: style)

        let prevVp = style.horizontal ? prevAt.viewport.x : prevAt.viewport.y
        let curVp = style.horizontal ? at.viewport.x : at.viewport.y
        let prevMax = style.horizontal ? prevAt.max.x : prevAt.max.y
        let curMax = style.horizontal ? at.max.x : at.max.y
        let resized = abs(prevVp - curVp) > 0.5
        let lengthened = !resized && abs(prevMax - curMax) > 0.5
        let extentChanged = abs(prevMax - curMax) > 0.5 || abs(prevVp - curVp) > 0.5

        let (glides, cut) = stepVisibilityLocked(
            .follow(ScrollBarVisibilityMachine.Follow(
                shows: info.shows,
                overlay: overlay,
                scrolled: w.scrolled,
                instant: w.instant,
                resized: resized,
                lengthened: lengthened,
                extentChanged: extentChanged,
                pressed: pressTracker.isHeld,
                revealed: revealedLocked,
                now: w.now,
                holdSeconds: style.holdDuration
            )),
            style: style
        )

        let sr = slotRect(top: top, h: h, trackLen: info.trackLen, style: style)
        if glides {
            liveSlot.set(sr)
        } else {
            liveSlot.snap(sr)
        }
        if cut || abs(currentThumbLenLocked(style: style) - h) > 1e-5 {
            let tr = thumbRect(h: h, style: style)
            if glides {
                liveThumb.set(tr)
            } else {
                liveThumb.snap(tr)
            }
        }
        visibility.shows = info.shows
        visibility.alwaysVisible = !overlay
        if w.scrolled {
            visibility.scrolled(now: w.now)
        }
        syncCompatibilityVisibility(overlay: overlay, shows: info.shows, now: w.now)
    }
}

/// Bounded kept scrollbar live-binding store (`KEPT = 256`), isolated per active `Runtime` memo scope.
public final class ScrollBarLiveStore: @unchecked Sendable {
    public static let shared = ScrollBarLiveStore()

    private final class ScopeBucket {
        weak var owner: AnyObject?
        var slots: [String: ScrollBarLiveSlot] = [:]
        var areaSlotsByViewportKey: [String: [String]] = [:]

        init(owner: AnyObject?) {
            self.owner = owner
        }
    }

    private let lock = NSLock()
    private var scopedBuckets: [ObjectIdentifier: ScopeBucket] = [:]
    private var unscopedBucket = ScopeBucket(owner: nil)

    public init() {}

    private func bucketLocked(for scope: AnyObject?) -> ScopeBucket {
        guard let scope else {
            return unscopedBucket
        }
        let id = ObjectIdentifier(scope)
        if let existing = scopedBuckets[id], existing.owner === scope {
            return existing
        }
        scopedBuckets = scopedBuckets.filter { $0.value.owner != nil }
        let created = ScopeBucket(owner: scope)
        scopedBuckets[id] = created
        return created
    }

    public func slot(
        for key: String,
        style: KitScrollBarStyle,
        viewportKey: String? = nil,
        scope: AnyObject? = MemoScope.activeCacheObject
    ) -> ScrollBarLiveSlot {
        lock.lock()
        defer { lock.unlock() }
        let bucket = bucketLocked(for: scope)
        if bucket.slots.count >= ScrollBarMetrics.keptLimit, bucket.slots[key] == nil {
            bucket.slots.removeAll(keepingCapacity: true)
            bucket.areaSlotsByViewportKey.removeAll(keepingCapacity: true)
        }
        if let vp = viewportKey {
            var list = bucket.areaSlotsByViewportKey[vp] ?? []
            if !list.contains(key) {
                list.append(key)
                bucket.areaSlotsByViewportKey[vp] = list
            }
        }
        if let existing = bucket.slots[key] {
            existing.syncStyle(style)
            return existing
        }
        let created = ScrollBarLiveSlot(style: style)
        bucket.slots[key] = created
        return created
    }

    public func notifyHoverTarget(
        viewportKey: String,
        inside: Bool,
        now: Double,
        scope: AnyObject? = MemoScope.activeCacheObject
    ) {
        lock.lock()
        let targets: [ScrollBarLiveSlot]
        if let scope {
            let bucket = bucketLocked(for: scope)
            let keys = bucket.areaSlotsByViewportKey[viewportKey] ?? []
            targets = keys.compactMap { bucket.slots[$0] }
        } else {
            scopedBuckets = scopedBuckets.filter { $0.value.owner != nil }
            var found: [ScrollBarLiveSlot] = []
            for bucket in scopedBuckets.values {
                for k in (bucket.areaSlotsByViewportKey[viewportKey] ?? []) {
                    if let s = bucket.slots[k] { found.append(s) }
                }
            }
            for k in (unscopedBucket.areaSlotsByViewportKey[viewportKey] ?? []) {
                if let s = unscopedBucket.slots[k] { found.append(s) }
            }
            targets = found
        }
        lock.unlock()
        for slot in targets {
            slot.hoverTarget(inside, style: nil, now: now)
        }
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
    public func scrollBar(
        _ kit: Kit,
        viewportKey: String = "scroll",
        file: String = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> El<State> {
        scrollBarStyled(.fromKit(kit), viewportKey: viewportKey, file: file, line: line, column: column)
    }

    /// Attaches a styled scrollbar track/thumb pair overlaid along the scrollable viewport edge (`El::scroll_bar_styled`),
    /// wired to `ScrollBarVisibility`, `ScrollBarPressTracker`, and live `MotionRect`/`Opacity`/`Fill` bindings.
    /// A wheel over the bar scrolls the viewport it follows, as a browser's scrollbar belongs to its scroller (`#1214`).
    public func scrollBarStyled(
        _ style: KitScrollBarStyle,
        viewportKey: String = "scroll",
        file: String = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> El<State> {
        let systemBars = Rune.systemScrollBars()
        let systemOverlay = Rune.systemScrollerOverlay()
        let jumpPreference = Rune.systemScrollerJumps()
        var effectiveStyle = style
        if !style.alwaysVisible && systemBars.isOverlay(scrollerOverlay: systemOverlay) {
            effectiveStyle.overlay = true
        }

        // Delegate outer wrapper creation to `El.wrapScrollArea()` so box placement, `aspectFit`,
        // `anchor`, `transition`, and `.clipToContent` (`clipFadeLinear` forwarding to `inner`
        // rather than `track`) stay identical to bare `El` (`scroll_bar.rs`, `scroll_bar_fade.rs`).
        let savedSticky = self.layout.sticky
        let savedSelf = self
        var (area, resolvedKey, outer, inner) = self.wrapScrollArea(file: file, line: line, column: column)
        let target = "\(area)/\(resolvedKey)"
        let slotKey = "\(effectiveStyle.key)::\(area)::\(effectiveStyle.horizontal ? "x" : "y")"
        let slot = ScrollBarLiveStore.shared.slot(for: slotKey, style: effectiveStyle, viewportKey: resolvedKey)

        let thumb: El<State> = el()
            .key(effectiveStyle.thumbKey)
            .rounded(effectiveStyle.thumbRadius)
            .bg(effectiveStyle.thumbColor)
            .absolute(x: 0, y: 0)
            .liveRect(slot.liveThumb.smooth(effectiveStyle.tintSpring))
            .liveFill(slot.liveFill.smooth(effectiveStyle.tintSpring))

        let thumbSlot: El<State> = el()
            .key("thumb-slot")
            .absolute(x: 0, y: 0)
            .liveRect(slot.liveSlot.smooth(effectiveStyle.tintSpring))
            .child(thumb)

        func attachDragHandlers(_ target: El<State>) -> El<State> {
            target
                .onPointerDown { _, press, tx in
                    let trackDims = (effectiveStyle.thumbOnly || press.elementSize.x <= 0 || press.elementSize.y <= 0)
                        ? slot.liveTrackSize()
                        : press.elementSize
                    let along = effectiveStyle.horizontal ? press.local.x : press.local.y
                    let trackSpan = max(
                        effectiveStyle.minThumb,
                        effectiveStyle.horizontal ? trackDims.x : trackDims.y
                    )
                    let result = slot.pointerDownWithResult(
                        along: along,
                        windowPoint: press.window,
                        trackLength: trackSpan,
                        trackSize: trackDims,
                        altPressed: press.mods.alt,
                        jumpPreference: jumpPreference,
                        style: effectiveStyle,
                        now: tx.clock
                    )
                    switch result {
                    case .page(let toward):
                        let step = max(1.0, slot.lastMetrics.viewport * 0.9)
                        let targetOffset = (slot.lastMetrics.offset + Float(toward) * step).clamped(to: 0...slot.lastMetrics.maxScroll)
                        if let pageOffset = slot.pageTargetOffset(along: along, trackLength: trackSpan, style: effectiveStyle) {
                            tx.scrollTo(
                                resolvedKey,
                                offset: effectiveStyle.horizontal ? Vec2(pageOffset, 0) : Vec2(0, pageOffset),
                                animated: true
                            )
                        } else if abs(targetOffset - slot.lastMetrics.offset) >= 1e-4 {
                            tx.scrollTo(
                                resolvedKey,
                                offset: effectiveStyle.horizontal ? Vec2(targetOffset, 0) : Vec2(0, targetOffset),
                                animated: true
                            )
                        }
                        tx.dragRepeatAfter(0.30)
                        tx.liveOnly()
                    case .jump(let nextOffset):
                        tx.scrollTo(
                            resolvedKey,
                            offset: effectiveStyle.horizontal ? Vec2(nextOffset, 0) : Vec2(0, nextOffset),
                            animated: false
                        )
                        tx.liveOnly()
                    case .grabThumb:
                        tx.liveOnly()
                    }
                }
                .onDrag { _, d, tx in
                    let trackDims = (effectiveStyle.thumbOnly || d.size.x <= 0 || d.size.y <= 0)
                        ? slot.liveTrackSize()
                        : d.size
                    let along = effectiveStyle.horizontal ? d.local.x : d.local.y
                    if tx.isDragRepeat {
                        let trackSpan = max(
                            effectiveStyle.minThumb,
                            effectiveStyle.horizontal ? trackDims.x : trackDims.y
                        )
                        if let nextPage = slot.pageTargetOffset(along: along, trackLength: trackSpan, style: effectiveStyle) {
                            tx.scrollTo(
                                resolvedKey,
                                offset: effectiveStyle.horizontal ? Vec2(nextPage, 0) : Vec2(0, nextPage),
                                animated: true
                            )
                            tx.dragRepeatAfter(0.05)
                        }
                    } else if let nextOffset = slot.dragIfThumb(along: along, windowPoint: d.window, trackSize: trackDims, style: effectiveStyle) {
                        tx.scrollTo(
                            resolvedKey,
                            offset: effectiveStyle.horizontal ? Vec2(nextOffset, 0) : Vec2(0, nextOffset),
                            animated: false
                        )
                    }
                    tx.liveOnly()
                }
                .onDragEnd { _, _, tx in
                    slot.release(style: effectiveStyle, now: tx.clock)
                    tx.liveOnly()
                }
        }

        let wiredThumbSlot = effectiveStyle.thumbOnly ? attachDragHandlers(thumbSlot) : thumbSlot

        // A wheel over the bar is the viewport's, the track standing beside it rather than in it, on
        // either axis: a sideways wheel over a table's bar scrolls the table, and a vertical wheel
        // over it chains on up from the table to the pane that holds it (`#1214`).
        let baseTrack: El<State> = el()
            .key(effectiveStyle.key)
            .rounded(effectiveStyle.trackRadius)
            .absolute(x: 0, y: 0)
            .liveRect(slot.liveTrack.binding)
            .liveOpacity(slot.liveOpacity.smooth(effectiveStyle.enterSpring).rest(effectiveStyle.leaveSpring))
            .wheelScrolls(target)

        var track: El<State> = (effectiveStyle.thumbOnly ? baseTrack : attachDragHandlers(baseTrack))
            .child(wiredThumbSlot)

        if let trackColor = effectiveStyle.trackColor {
            track = track.bg(trackColor)
        }
        if let trackBorderColor = effectiveStyle.trackBorderColor {
            track = track.border(1.0, trackBorderColor)
        }

        outer.layout.sticky = savedSticky
        inner.layout.sticky = nil
        outer.layout.minWidth = (savedSelf.layout.scrollAxes.contains(.horizontal) && savedSelf.layout.minWidth == .auto)
            ? .points(0)
            : savedSelf.layout.minWidth
        outer.layout.minHeight = (savedSelf.layout.scrollAxes.contains(.vertical) && savedSelf.layout.minHeight == .auto)
            ? .points(0)
            : savedSelf.layout.minHeight
        inner.layout.width = .fraction(1.0)

        return outer
            .onPointerMoveAny { press, tx in
                tx.liveOnly()
                slot.pointer(localPoint: press.local, windowPoint: press.window, style: effectiveStyle, now: tx.clock)
            }
            .chainHoverChangeAny { inside, tx in
                tx.liveOnly()
                if !inside {
                    slot.pointer(localPoint: nil, windowPoint: nil, style: effectiveStyle, now: tx.clock)
                }
            }
            .child(inner.chainScrollOffset { pos in
                slot.updateFromScrollPos(pos, style: effectiveStyle)
            })
            .child(track)
    }

    /// Marks an element as an edge hover target for an overlay scrollbar (`El::scroll_bar_hover`).
    public func scrollBarHover(_ viewportKey: String) -> El<State> {
        let scopeObj = MemoScope.activeCacheObject
        return self.chainHoverChangeAny { [weak scopeObj] inside, tx in
            tx.liveOnly()
            ScrollBarLiveStore.shared.notifyHoverTarget(
                viewportKey: viewportKey,
                inside: inside,
                now: tx.clock,
                scope: scopeObj
            )
        }
    }
}
