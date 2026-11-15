import Foundation
import RuneMotion
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Env & Commit Generation (`crates/rune/src/runtime/cx.rs`)

/// Immutable view environment snapshot passed to view functions (`rune::Env`).
public struct Env: Sendable, Equatable {
    public var systemDark: Bool
    public var scale: Float

    public init(systemDark: Bool = true, scale: Float = 1.0) {
        self.systemDark = systemDark
        self.scale = scale
    }
}

enum CommitGenerationStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counter: UInt64 = 0

    static func current() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return counter
    }

    @discardableResult
    static func increment() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        counter &+= 1
        return counter
    }
}

/// How many view commits have started across runtimes (`rune::commit_generation`).
public func commitGeneration() -> UInt64 {
    CommitGenerationStore.current()
}

// MARK: - View Defaults & Outline (`cx.rs`, `el::Outline`)

/// Focus ring outline geometry and color (`rune::el::Outline`).
public struct Outline: Sendable, Equatable {
    public var width: Float
    public var offset: Float
    public var color: Color

    public init(width: Float, offset: Float, color: Color) {
        self.width = width
        self.offset = offset
        self.color = color
    }
}

/// Default styles and interaction modes declared by a view via `Cx` (`rune::runtime::ViewDefaults`).
public struct ViewDefaults: Sendable, Equatable {
    public var foreground: Color?
    public var focusRing: Outline?
    public var help: HelpLook?
    public var webFocus: Bool = false
    public var forceFocusRings: Bool = false

    public init(
        foreground: Color? = nil,
        focusRing: Outline? = nil,
        help: HelpLook? = nil,
        webFocus: Bool = false,
        forceFocusRings: Bool = false
    ) {
        self.foreground = foreground
        self.focusRing = focusRing
        self.help = help
        self.webFocus = webFocus
        self.forceFocusRings = forceFocusRings
    }
}

// MARK: - HelpLook (`runtime/input/help_look.rs` — defined in Runtime/HelpTooltip.swift)

// MARK: - ScrollBars (`platform/scroll_bars.rs`, defined in PlatformCommon.swift)

enum SystemScrollBarsScope {
    @TaskLocal static var current: SystemScrollBars?
}

public func systemScrollBars() -> ScrollBars {
    (SystemScrollBarsScope.current ?? SystemScrollBars.current()).bars
}

public func systemScrollerOverlay() -> Bool {
    (SystemScrollBarsScope.current ?? SystemScrollBars.current()).scrollerOverlay
}

public func systemScrollerJumps() -> Bool {
    (SystemScrollBarsScope.current ?? SystemScrollBars.current()).jumpToClick
}

// MARK: - ZoomState (`runtime/zoom.rs`)

/// Page-zoom state (`rune::runtime::zoom::Zoom`).
public struct ZoomState: Sendable, Equatable {
    public var k: Float
    public var window: Vec2
    public var windowScale: Float

    public init(k: Float = 1.0, window: Vec2 = .zero, windowScale: Float = 1.0) {
        self.k = Self.clamp(k)
        self.window = window
        self.windowScale = windowScale
    }

    public static func clamp(_ k: Float) -> Float {
        k.isFinite ? min(max(k, 0.1), 10.0) : 1.0
    }

    public func view() -> (viewport: Vec2, scale: Float) {
        (Vec2(window.x / k, window.y / k), windowScale * k)
    }
}

// MARK: - CxEnvironmentState & Cx Extensions (`runtime/cx.rs`)

final class CxReadsLog: @unchecked Sendable {
    var caretRead: Bool = false
    var selectionRectsRead: Bool = false
    var layoutReads: [MemoRead] = []

    init() {}

    init(copying other: CxReadsLog) {
        self.caretRead = other.caretRead
        self.selectionRectsRead = other.selectionRectsRead
        self.layoutReads = other.layoutReads
    }
}

/// Primary pointer capability reported by browser `(hover: none)` / `(pointer: coarse)` (`platform/web.rs::PrimaryPointer`).
/// Natively `.hover` so `hoverNone` and `touchControls` both return `false`.
public enum PrimaryPointer: Sendable, Equatable, Hashable {
    case hover
    case noHover
    case touch

    public var hoverNone: Bool { self != .hover }
    public var touchControls: Bool { self == .touch }

    public static func from(hover: Bool, coarse: Bool) -> PrimaryPointer {
        switch (hover, coarse) {
        case (false, true): return .touch
        case (false, _): return .noHover
        default: return .hover
        }
    }
}

struct CxEnvironmentState {
    var titlebarInset: Float = 0.0
    var chrome: ChromeInsets = .zero
    var captionColor: Color? = nil
    var defaults: ViewDefaults = ViewDefaults()
    var titlebar: TitlebarSet = TitlebarSet()
    var systemAccent: SystemAccent = .default
    var systemContrast: SystemContrast? = nil
    var systemScrollBars: SystemScrollBars = .default
    var systemReducedMotion: Bool = false
    var primaryPointer: PrimaryPointer = .hover
    var reducedMotionOverride: Bool? = nil
    var timeScale: Float = 1.0
    var zoom: Float = 1.0
    var caret: (keyPath: String, rect: [Float])? = nil
    var selectionRects: [[Float]] = []
    var markedTexts: [SelectionMark] = []
    var reads = CxReadsLog()
}

/// Per-`Runtime` shell environment & clock settings (`runtime/cx.rs`, `system_settings.rs`, `zoom.rs`).
struct RuntimeShellSettings {
    var zoomState: ZoomState
    var isApplyingZoom: Bool = false
    var hasScaledClock: Bool = false
    var lastHostTime: Double = 0.0
    var lastScaleHostTime: Double = 0.0
    var scaledTimeBase: Double = 0.0
    var hostReducedMotion: Bool = false
    var viewTimeScale: Float = 1.0
    var viewDefaults: ViewDefaults = ViewDefaults()
    var captionColor: Color? = nil
    var titlebarInset: Float = 0.0
    /// What the native window's controls take of the titlebar, in window points, as the host
    /// last set it (`Runtime::set_chrome_insets`); `nil` until a host sets it, when the
    /// headless derivation from `App::titlebar` stands in (`Runtime::headless_chrome`).
    var hostChromeInsets: ChromeInsets? = nil
    var baseTitlebar: Titlebar? = nil
    var titlebarOverride: TitlebarSet = TitlebarSet()
    var systemAccent: SystemAccent = .default
    var systemContrast: SystemContrast? = nil
    var scrollBarsState: SystemScrollBars = .default
    var primaryPointer: PrimaryPointer = .hover
    var fullKeyboardAccess: Bool = true
    var caretReadByView: Bool = false
    var lastCommittedCaret: (keyPath: String, rect: [Float])? = nil
    var selectionRectsReadByView: Bool = false
    var lastCommittedSelectionRects: [[Float]] = []

    init(viewport: Vec2 = .zero, pixelScale: Float = 2.0, reducedMotion: Bool = false) {
        self.zoomState = ZoomState(k: 1.0, window: viewport, windowScale: max(pixelScale, 0.5))
        self.hostReducedMotion = reducedMotion
    }

    func scaledTime(at hostNow: Double) -> Double {
        let clampedNow = max(lastHostTime, hostNow)
        if !hasScaledClock && viewTimeScale == 1.0 {
            return clampedNow
        }
        return scaledTimeBase + max(0.0, clampedNow - lastScaleHostTime) * Double(viewTimeScale)
    }

    mutating func advanceClock(to hostNow: Double) -> Double {
        let clampedNow = max(lastHostTime, hostNow)
        lastHostTime = clampedNow
        return scaledTime(at: clampedNow)
    }

    mutating func setSplitAnchor(hostTime: Double, animTime: Double) {
        lastHostTime = hostTime
        lastScaleHostTime = hostTime
        scaledTimeBase = animTime
        hasScaledClock = true
    }

    mutating func setTimeScale(_ newScale: Float, at hostNow: Double) {
        let clamped = min(max(newScale.isFinite ? newScale : 1.0, 0.0), 8.0)
        guard clamped != viewTimeScale || hasScaledClock else { return }
        if !hasScaledClock && clamped == 1.0 { return }
        let anchor = max(lastScaleHostTime, max(lastHostTime, hostNow))
        if !hasScaledClock {
            scaledTimeBase = anchor
            lastScaleHostTime = anchor
            hasScaledClock = true
        } else {
            scaledTimeBase += max(0.0, anchor - lastScaleHostTime) * Double(viewTimeScale)
            lastScaleHostTime = anchor
        }
        viewTimeScale = clamped
    }
}

extension Cx {
    /// Re-tags this context for a nested sub-view over another state type (`Cx::retype`).
    public func retype<T>() -> Cx<T> {
        var out = Cx<T>(
            viewport: viewport,
            pixelScale: pixelScale,
            systemDark: systemDark,
            reducedMotion: reducedMotion,
            windowFocused: windowFocused,
            focusedKey: focusedKey,
            hoveredKey: hoveredKey,
            pressedKey: pressedKey,
            waker: waker,
            helpLook: helpLook,
            scrollLookup: scrollLookup,
            scrollMaxLookup: scrollMaxLookup,
            viewportSizeLookup: viewportSizeLookup,
            contentSizeLookup: contentSizeLookup,
            layoutRectLookup: layoutRectLookup,
            layoutCollector: layoutCollector
        )
        out.envState = envState
        out.envState.markedTexts = []
        out.envState.reads = CxReadsLog(copying: envState.reads)
        return out
    }

    /// Takes back settings and read dependencies from a `retype`d sub-view without overwriting outer chrome (`Cx::absorb`).
    public mutating func absorb<T>(_ other: Cx<T>) {
        self.reducedMotion = other.reducedMotion
        if let subHelp = other.helpLook {
            self.helpLook = subHelp
        }
        self.envState.reducedMotionOverride = other.envState.reducedMotionOverride
        self.envState.timeScale = other.envState.timeScale
        self.envState.zoom = other.envState.zoom
        self.envState.defaults = other.envState.defaults
        if other.envState.reads.caretRead {
            self.envState.reads.caretRead = true
        }
        if other.envState.reads.selectionRectsRead {
            self.envState.reads.selectionRectsRead = true
        }
        if !other.envState.markedTexts.isEmpty {
            self.envState.markedTexts.append(contentsOf: other.envState.markedTexts)
        }
        for read in other.envState.reads.layoutReads {
            if let idx = self.envState.reads.layoutReads.firstIndex(where: { $0.sameTarget(as: read) }) {
                self.envState.reads.layoutReads[idx] = read
            } else {
                self.envState.reads.layoutReads.append(read)
            }
        }
    }

    mutating func clearChrome() {
        envState.titlebarInset = 0.0
        envState.chrome = .zero
    }

    /// Immutable view environment snapshot (`Cx::env`).
    public func env() -> Env {
        Env(systemDark: systemDark, scale: pixelScale)
    }

    /// System dark appearance flag (`Cx::system_dark`).
    public func getSystemDark() -> Bool {
        systemDark
    }

    /// Leading inset of the macOS traffic lights (`Cx::titlebar_inset`).
    public func titlebarInset() -> Float {
        envState.titlebarInset
    }

    /// Window chrome control insets in current zoomed view points (`Cx::chrome_insets`).
    public func chromeInsets() -> ChromeInsets {
        envState.chrome
    }

    /// Windows caption button symbol color override (`Cx::caption_color`).
    public mutating func captionColor(_ color: Color) {
        envState.captionColor = color
    }

    /// Default foreground color for unstyled text, icons, and text inputs (`Cx::foreground`).
    public mutating func foreground(_ color: Color) {
        envState.defaults.foreground = color
    }

    /// Default keyboard focus ring style (`Cx::focus_ring`).
    public mutating func focusRing(_ width: Float, _ offset: Float, _ color: Color) {
        envState.defaults.focusRing = Outline(width: width, offset: offset, color: color)
    }

    /// Labelled overload for `focusRing(width:offset:color:)`.
    public mutating func focusRing(width: Float, offset: Float, color: Color) {
        envState.defaults.focusRing = Outline(width: width, offset: offset, color: color)
    }

    /// Tooltip surface, placement, and animation configuration (`Cx::help_look`).
    public mutating func helpLook(_ look: HelpLook) {
        self.helpLook = look
        envState.defaults.help = look
    }

    /// Forces keyboard focus rings on every focusable control during this commit (`Cx::force_focus_rings`).
    public mutating func forceFocusRings() {
        envState.defaults.forceFocusRings = true
    }

    /// Enables web-style tab-stop and focus behavior (`Cx::web_focus`).
    public mutating func webFocus() {
        envState.defaults.webFocus = true
    }

    /// Sets the custom titlebar height in window points (`Cx::titlebar_height`).
    public mutating func titlebarHeight(_ points: Float) {
        envState.titlebar.height = max(1.0, points)
    }

    /// Replaces the window's custom titlebar geometry during this commit (`Cx::set_titlebar`).
    public mutating func setTitlebar(_ titlebar: Titlebar) {
        envState.titlebar.titlebar = titlebar
    }

    /// User's system accent color for the current window appearance (`Cx::accent`).
    public func accent() -> Color {
        envState.systemAccent.accent(dark: systemDark)
    }

    /// Keyboard focus ring color for the current window appearance (`Cx::focus_color`).
    public func focusColor() -> Color {
        envState.systemAccent.focus(dark: systemDark)
    }

    /// Browser safe-area insets `[top, right, bottom, left]` (`Cx::safe_area`, zero on native).
    public func safeArea() -> [Float] {
        [0.0, 0.0, 0.0, 0.0]
    }

    /// The primary pointer can't hover: a browser's `(hover: none)`, a phone's or tablet's touch
    /// screen. What a mouse would reveal on hover (a code block's Copy, a row's actions) should
    /// show without it. False natively. A change re-runs the view (`Cx::hover_none`).
    public func hoverNone() -> Bool {
        envState.primaryPointer.hoverNone
    }

    /// A page's primary pointer is coarse and can't hover. Use this for a phone or tablet's
    /// controls rather than the viewport width: a narrow window can still have a mouse.
    /// False natively. A change re-runs the view (`Cx::touch_controls`).
    public func touchControls() -> Bool {
        envState.primaryPointer.touchControls
    }

    /// System high-contrast forced-colors theme, if active (`Cx::system_contrast`).
    public func systemContrast() -> SystemContrast? {
        envState.systemContrast
    }

    /// Host OS reduced-motion preference independent of per-commit override (`Cx::system_reduced_motion`).
    public func systemReducedMotion() -> Bool {
        envState.systemReducedMotion
    }

    /// User's "Show scroll bars" preference (`Cx::scroll_bars`).
    public func scrollBars() -> ScrollBars {
        envState.systemScrollBars.bars
    }

    /// Whether scroll bars currently overlay and fade out at rest (`Cx::overlay_scroll_bars`).
    public func overlayScrollBars() -> Bool {
        envState.systemScrollBars.isOverlay
    }

    /// Effective reduced-motion flag for this commit (`Cx::is_reduced_motion`).
    public func isReducedMotion() -> Bool {
        envState.reducedMotionOverride ?? reducedMotion
    }

    /// Overrides reduced-motion for this commit (`Cx::reduced_motion`).
    public mutating func reducedMotion(_ on: Bool) {
        envState.reducedMotionOverride = on
        self.reducedMotion = on
    }

    /// Scales the window's animation clock (`Cx::time_scale`, clamped to `0...8`).
    public mutating func timeScale(_ scale: Float) {
        envState.timeScale = scale.isFinite ? min(max(scale, 0.0), 8.0) : 1.0
    }

    /// Sets UI page zoom (`Cx::zoom`, clamped to `0.1...10.0`).
    public mutating func zoom(_ k: Float) {
        envState.zoom = ZoomState.clamp(k)
    }
}

/// Checks whether `key` matches any segment of the focused field's `keyPath` (`cx::caret_of`).
func caretRectForKey(_ caret: (keyPath: String, rect: [Float])?, key: String) -> [Float]? {
    guard let caret else { return nil }
    return caret.keyPath.split(separator: "/").contains { $0 == key || $0 == "@\(key)" } ? caret.rect : nil
}

// MARK: - Runtime System Settings & Zoom API (`system_settings.rs`, `zoom.rs`, `titlebar.rs`)

extension Runtime {
    /// Leading inset of the macOS traffic lights (`Runtime::set_titlebar_inset`).
    public func setTitlebarInset(_ points: Float) {
        if points != cxSettings.titlebarInset {
            cxSettings.titlebarInset = points
            markNeedsCommit()
        }
    }

    public var titlebarInset: Float { cxSettings.titlebarInset }

    /// Base custom titlebar configured by the app (`App::titlebar`).
    public func setBaseTitlebar(_ titlebar: Titlebar?) {
        if titlebar != cxSettings.baseTitlebar {
            cxSettings.baseTitlebar = titlebar
            markNeedsCommit()
        }
    }

    /// Effective titlebar combining app base titlebar and per-commit `Cx::set_titlebar` / `Cx::titlebar_height`.
    public func effectiveTitlebar() -> Titlebar? {
        let ov = cxSettings.titlebarOverride
        if cxSettings.baseTitlebar == nil && ov.titlebar == nil && ov.height == nil {
            return nil
        }
        return ov.over(cxSettings.baseTitlebar ?? Titlebar())
    }

    /// Chrome insets in current zoomed view points, as the view reads them (`Cx::chrome_insets`):
    /// `windowChromeInsets()` over the zoom (`Measurement::chrome`, `insets.zoomed(zoom)`).
    public func chromeInsets() -> ChromeInsets {
        windowChromeInsets().zoomed(cxSettings.zoomState.k)
    }

    /// Sets the system accent palette (`Runtime::set_system_accent`).
    public func setSystemAccent(_ accent: SystemAccent) {
        if accent != cxSettings.systemAccent {
            cxSettings.systemAccent = accent
            markNeedsCommit()
        }
    }

    public func systemAccent() -> SystemAccent { cxSettings.systemAccent }

    /// Sets the system contrast theme (`Runtime::set_system_contrast`).
    public func setSystemContrast(_ contrast: SystemContrast?) {
        if contrast != cxSettings.systemContrast {
            cxSettings.systemContrast = contrast
            markNeedsCommit()
        }
    }

    public func systemContrast() -> SystemContrast? { cxSettings.systemContrast }

    /// Sets the host OS reduced-motion preference (`Runtime::set_system_reduced_motion`).
    public func setSystemReducedMotion(_ reduced: Bool) {
        if cxSettings.hostReducedMotion != reduced {
            cxSettings.hostReducedMotion = reduced
            self.reducedMotion = reduced
            markNeedsCommit()
        }
    }

    /// Host accessibility reduced-motion preference (`Runtime::system_reduced_motion`).
    public func systemReducedMotion() -> Bool {
        cxSettings.hostReducedMotion
    }

    /// Updates the host's primary pointer capability (re-runs the view when changed).
    @discardableResult
    public func setPrimaryPointer(_ pointer: PrimaryPointer) -> Bool {
        guard cxSettings.primaryPointer != pointer else { return false }
        cxSettings.primaryPointer = pointer
        markNeedsCommit()
        return true
    }

    /// Applies browser `(hover, coarse)` pointer capability flags and invalidates on change.
    @discardableResult
    public func setWebPointerCapability(hover: Bool, coarse: Bool) -> Bool {
        setPrimaryPointer(.from(hover: hover, coarse: coarse))
    }

    /// Primary pointer cannot hover (`Cx::hover_none` runtime value, `false` natively).
    public func hoverNone() -> Bool {
        cxSettings.primaryPointer.hoverNone
    }

    /// Primary pointer is coarse and cannot hover (`Cx::touch_controls` runtime value, `false` natively).
    public func touchControls() -> Bool {
        cxSettings.primaryPointer.touchControls
    }

    /// Tab visits every control when on (`Runtime::set_full_keyboard_access`).
    public func setFullKeyboardAccess(_ on: Bool) {
        cxSettings.fullKeyboardAccess = on
    }

    public func fullKeyboardAccess() -> Bool { cxSettings.fullKeyboardAccess }

    /// App override allowing Tab to visit every control (`Runtime::set_tab_visits_controls`).
    public func setTabVisitsControls(_ on: Bool) {
        tabVisitsControls = on
    }

    /// Sets the user's "Show scroll bars" preference (`Runtime::set_system_scroll_bars`).
    public func setSystemScrollBars(_ bars: ScrollBars) {
        let next = SystemScrollBars(
            bars: bars,
            scrollerOverlay: cxSettings.scrollBarsState.scrollerOverlay,
            jumpToClick: cxSettings.scrollBarsState.jumpToClick
        )
        if next != cxSettings.scrollBarsState {
            cxSettings.scrollBarsState = next
            memo.invalidateAll()
            markNeedsCommit()
        }
    }

    public func systemScrollBars() -> ScrollBars { cxSettings.scrollBarsState.bars }

    /// Sets whether the pointing device prefers overlay scroll bars (`Runtime::set_system_scroller_overlay`).
    public func setSystemScrollerOverlay(_ overlay: Bool) {
        let next = SystemScrollBars(
            bars: cxSettings.scrollBarsState.bars,
            scrollerOverlay: overlay,
            jumpToClick: cxSettings.scrollBarsState.jumpToClick
        )
        if next != cxSettings.scrollBarsState {
            cxSettings.scrollBarsState = next
            memo.invalidateAll()
            markNeedsCommit()
        }
    }

    public func systemScrollerOverlay() -> Bool { cxSettings.scrollBarsState.scrollerOverlay }

    /// Sets track-click scroll jump behavior (`Runtime::set_system_scroller_jumps`).
    public func setSystemScrollerJumps(_ jumps: Bool) {
        let next = SystemScrollBars(
            bars: cxSettings.scrollBarsState.bars,
            scrollerOverlay: cxSettings.scrollBarsState.scrollerOverlay,
            jumpToClick: jumps
        )
        if next != cxSettings.scrollBarsState {
            cxSettings.scrollBarsState = next
            memo.invalidateAll()
            markNeedsCommit()
        }
    }

    public func systemScrollerJumps() -> Bool { cxSettings.scrollBarsState.jumpToClick }

    /// Whether scroll bars currently overlay and fade out at rest (`Runtime::overlay_scroll_bars`).
    public func overlayScrollBars() -> Bool { cxSettings.scrollBarsState.isOverlay }

    /// Active view UI zoom (`Runtime::zoom`).
    public func zoom() -> Float { cxSettings.zoomState.k }

    /// Window viewport in unzoomed window points (`Runtime::window_viewport`).
    public func windowViewport() -> Vec2 { cxSettings.zoomState.window }

    /// Window scale in device pixels per window point (`Runtime::window_scale`).
    public func windowScale() -> Float { cxSettings.zoomState.windowScale }

    /// Device pixels per view point (`Runtime::input_scale`, `windowScale * zoom`).
    public func inputScale() -> Float { pixelScale }

    /// Converts a rect from zoomed view points into window points (`Runtime::to_window`).
    public func toWindow(_ rect: [Float]) -> [Float] {
        rect.map { $0 * cxSettings.zoomState.k }
    }

    /// Updates window-point viewport and scale while preserving the view's current `Cx::zoom` (`Runtime::set_viewport`).
    public func setWindowViewport(_ size: Vec2, pixelScale: Float) {
        cxSettings.zoomState.window = size
        cxSettings.zoomState.windowScale = max(0.5, pixelScale)
        let (vp, sc) = cxSettings.zoomState.view()
        cxSettings.isApplyingZoom = true
        self.viewport = vp
        self.pixelScale = sc
        cxSettings.isApplyingZoom = false
    }

    /// Last committed `ViewDefaults` (`foreground`, `focusRing`, `help`, `webFocus`, `forceFocusRings`).
    public var viewDefaults: ViewDefaults { cxSettings.viewDefaults }

    /// Last committed `Cx::caption_color`.
    public var viewCaptionColor: Color? { cxSettings.captionColor }

    /// Last committed `Cx::time_scale`.
    public var viewTimeScale: Float { cxSettings.viewTimeScale }

    /// Last committed `Cx::set_titlebar` / `Cx::titlebar_height`.
    public var viewTitlebarOverride: TitlebarSet { cxSettings.titlebarOverride }
}
