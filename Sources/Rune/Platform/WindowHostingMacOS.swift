import Foundation
import RuneMotion
import RuneRef

#if os(macOS)
import AppKit
@preconcurrency import ObjectiveC
import QuartzCore

// MARK: - Traffic Lights & #836 RTL Layout (platform/macos/traffic_lights.rs)

/// Keeps macOS traffic lights at an app-configured origin across AppKit relayouts
/// and supports RTL right-side mirroring (#836).
public enum RuneTrafficLights {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var spots: [ObjectIdentifier: (CGFloat, CGFloat)] = [:]
    nonisolated(unsafe) private static var placing = false

    /// RAII token removing the tracked spot when a window closes.
    public final class Spot {
        private let id: ObjectIdentifier

        public init(window: NSWindow) {
            self.id = ObjectIdentifier(window)
        }

        deinit {
            RuneTrafficLights.removeSpot(forId: id)
        }
    }

    private static func setSpot(_ spot: (CGFloat, CGFloat), for window: NSWindow) {
        lock.lock()
        spots[ObjectIdentifier(window)] = spot
        lock.unlock()
    }

    private static func spot(for window: NSWindow) -> (CGFloat, CGFloat)? {
        lock.lock()
        defer { lock.unlock() }
        return spots[ObjectIdentifier(window)]
    }

    private static func removeSpot(forId id: ObjectIdentifier) {
        lock.lock()
        spots.removeValue(forKey: id)
        lock.unlock()
    }

    /// Pure geometry helper for traffic-light x-origins (`traffic_lights.rs` + #836 RTL).
    public static func computeOrigins(
        x: CGFloat,
        y: CGFloat,
        pitch: CGFloat,
        buttonWidths: [CGFloat],
        parentWidth: CGFloat,
        rtl: Bool
    ) -> [CGPoint] {
        buttonWidths.enumerated().map { idx, width in
            let at = x + CGFloat(idx) * pitch
            let posX = rtl ? (parentWidth - at - width) : at
            return CGPoint(x: posX, y: y)
        }
    }

    /// Pure geometry helper for `titlebar_inset` (`window/mac.rs` + #836 RTL).
    public static func computeTitlebarInset(
        windowWidth: CGFloat,
        zoomFrameInWindow: CGRect,
        fullScreen: Bool,
        fullSizeContent: Bool,
        zoomHidden: Bool,
        rtl: Bool
    ) -> Float {
        if fullScreen || !fullSizeContent || zoomHidden {
            return 0.0
        }
        if rtl {
            return Float(max(0.0, windowWidth - zoomFrameInWindow.origin.x))
        }
        return Float(max(0.0, zoomFrameInWindow.origin.x + zoomFrameInWindow.size.width))
    }

    @MainActor
    public static func place(_ window: NSWindow, at origin: (Float, Float)) {
        let spot = (CGFloat(origin.0), CGFloat(origin.1))
        setSpot(spot, for: window)
        placeIn(window, spot: spot)
    }

    @MainActor
    public static func placeIn(_ window: NSWindow, spot: (CGFloat, CGFloat)) {
        if window.styleMask.contains(.fullScreen) {
            return
        }
        guard let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let parent = close.superview,
              let container = parent.superview else {
            return
        }
        hold(parent)
        hold(container)
        if placing {
            return
        }
        placing = true
        defer { placing = false }

        let rtl = RuneLabels.shared.isRTL
        let pitch = abs(mini.frame.origin.x - close.frame.origin.x)
        var frame = container.frame
        frame.size.height = close.frame.size.height + 2.0 * spot.1
        frame.origin.y = window.frame.size.height - frame.size.height
        let width = parent.frame.size.width
        container.frame = frame

        let buttons = [close, mini, zoom]
        let origins = computeOrigins(
            x: spot.0,
            y: spot.1,
            pitch: pitch,
            buttonWidths: buttons.map(\.frame.size.width),
            parentWidth: width,
            rtl: rtl
        )
        for (button, pt) in zip(buttons, origins) {
            button.setFrameOrigin(pt)
        }
    }

    /// True when traffic lights sit on the right half of `window` (RTL app).
    @MainActor
    public static func trafficLightsRight(_ window: NSWindow) -> Bool {
        guard let close = window.standardWindowButton(.closeButton) else {
            return false
        }
        let rectInWindow = close.convert(close.bounds, to: nil)
        return rectInWindow.origin.x > window.frame.size.width * 0.5
    }

    /// How far in from their edge the traffic lights reach (`mac::titlebar_inset`).
    @MainActor
    public static func titlebarInset(_ window: NSWindow) -> Float {
        let mask = window.styleMask
        guard !mask.contains(.fullScreen), mask.contains(.fullSizeContentView) else {
            return 0.0
        }
        guard let zoom = window.standardWindowButton(.zoomButton) else {
            return 0.0
        }
        let rect = zoom.convert(zoom.bounds, to: nil)
        let rtl = trafficLightsRight(window)
        return computeTitlebarInset(
            windowWidth: window.frame.size.width,
            zoomFrameInWindow: rect,
            fullScreen: mask.contains(.fullScreen),
            fullSizeContent: mask.contains(.fullSizeContentView),
            zoomHidden: zoom.isHiddenOrHasHiddenAncestor,
            rtl: rtl
        )
    }

    /// How far down AppKit moves the window from presses on the content view when not drag-region scoped.
    @MainActor
    public static func nativeTitlebarBand(_ window: NSWindow) -> Float {
        let mask = window.styleMask
        guard mask.contains([.titled, .fullSizeContentView]), !mask.contains(.fullScreen) else {
            return 0.0
        }
        if let content = window.contentView, RuneDragRegions.isScoped(content) {
            return 0.0
        }
        let contentLayout = window.contentLayoutRect
        return Float(max(0.0, window.frame.size.height - contentLayout.size.height))
    }

    private static func heldClass(of object: AnyObject) -> AnyClass? {
        var cls: AnyClass? = object_getClass(object)
        while let current = cls {
            if NSStringFromClass(current).hasPrefix("RuneTrafficLights_") {
                return current
            }
            cls = class_getSuperclass(current)
        }
        return nil
    }

    @MainActor
    private static func hold(_ view: NSView) {
        if heldClass(of: view) != nil {
            return
        }
        guard let base: AnyClass = object_getClass(view) else { return }
        let name = "RuneTrafficLights_\(NSStringFromClass(base))"
        let subclass: AnyClass?
        if let existing = objc_lookUpClass(name) {
            subclass = existing
        } else if let pair = objc_allocateClassPair(base, name, 0) {
            let layoutSel = sel_registerName("layout")
            let layoutImp: @convention(c) (AnyObject, Selector) -> Void = { obj, sel in
                MainActor.assumeIsolated {
                    if let held = RuneTrafficLights.heldClass(of: obj),
                       let superCls = class_getSuperclass(held),
                       let baseIMP = class_getMethodImplementation(superCls, sel) {
                        typealias LayoutFn = @convention(c) (AnyObject, Selector) -> Void
                        let fn = unsafeBitCast(baseIMP, to: LayoutFn.self)
                        fn(obj, sel)
                    }
                    if RuneTrafficLights.placing {
                        return
                    }
                    guard let v = obj as? NSView,
                          let win = v.window,
                          let spot = RuneTrafficLights.spot(for: win) else {
                        return
                    }
                    RuneTrafficLights.placeIn(win, spot: spot)
                }
            }
            let cImp = unsafeBitCast(layoutImp, to: IMP.self)
            class_addMethod(pair, layoutSel, cImp, "v@:")
            objc_registerClassPair(pair)
            subclass = pair
        } else {
            subclass = objc_lookUpClass(name)
        }
        if let subclass {
            object_setClass(view, subclass)
        }
    }
}

// MARK: - Per-Instance Drag Region Subclass (window/mac.rs)

/// Scopes `mouseDownCanMoveWindow` to `NO` on a single content view instance
/// without mutating shared classes (`window/mac.rs::scope_drag_regions`).
public enum RuneDragRegions {
    private static let cannotMoveWindowIMP: @convention(c) (AnyObject, Selector) -> ObjCBool = { _, _ in
        ObjCBool(false)
    }

    public static func isScoped(_ object: AnyObject) -> Bool {
        guard let cls = object_getClass(object) else { return false }
        return NSStringFromClass(cls).hasPrefix("RuneDragRegions_")
    }

    public static func scopeDragRegions(on object: AnyObject) {
        guard let base = object_getClass(object) else { return }
        let baseName = NSStringFromClass(base)
        if baseName.hasPrefix("RuneDragRegions_") {
            return
        }
        let subName = "RuneDragRegions_\(baseName)"
        let subClass: AnyClass?
        if let existing = objc_lookUpClass(subName) {
            subClass = existing
        } else if let pair = objc_allocateClassPair(base, subName, 0) {
            let sel = sel_registerName("mouseDownCanMoveWindow")
            let types: UnsafePointer<CChar>? = class_getInstanceMethod(base, sel).flatMap { method_getTypeEncoding($0) }
            let imp = unsafeBitCast(cannotMoveWindowIMP, to: IMP.self)
            if let types {
                class_addMethod(pair, sel, imp, types)
            } else {
                class_addMethod(pair, sel, imp, "B@:")
            }
            objc_registerClassPair(pair)
            subClass = pair
        } else {
            subClass = objc_lookUpClass(subName)
        }
        if let subClass {
            object_setClass(object, subClass)
        }
    }

    @MainActor
    public static func ownWindowDragging(window: NSWindow, chrome: Chrome) {
        guard let contentView = window.contentView else { return }
        let isPanel = window is NSPanel
        let borderless = !window.styleMask.contains(.titled)
        guard Chrome.usesDragRegions(chrome: chrome, borderless: borderless, isPanel: isPanel) else {
            return
        }
        scopeDragRegions(on: contentView)
    }
}

// MARK: - Window Shape, Corners & Shadow Resampling (platform/macos/window_shape.rs)

/// State machine deciding when a transparent macOS window re-samples its shadow (`window_shape::Resample`).
public struct ShadowResampleState: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case nextFrame
        case onScreen(UInt64)
    }

    public private(set) var state: State

    public init(state: State = .idle) {
        self.state = state
    }

    public mutating func shown(last: UInt64) {
        if state == .idle {
            state = last > 0 ? .onScreen(last) : .nextFrame
        }
    }

    public mutating func redraw() {
        state = .nextFrame
    }

    public mutating func presented(_ drawable: UInt64) {
        if state == .nextFrame {
            state = .onScreen(drawable)
        }
    }

    public mutating func hidden() {
        state = .idle
    }

    public mutating func turn(onScreen: UInt64) -> Bool {
        if case .onScreen(let n) = state, onScreen >= n {
            state = .idle
            return true
        }
        return false
    }
}

/// Applies rounded content corners and shadow resampling to transparent borderless windows.
public enum RuneWindowShape {
    @MainActor
    public static func applyCorners(
        to window: NSWindow,
        options: MacWindowOptions,
        transparent: Bool,
        borderless: Bool
    ) {
        guard transparent, borderless, let radius = options.cornerRadius,
              let view = window.contentView,
              let layer = view.layer else {
            return
        }
        layer.cornerRadius = CGFloat(radius)
        layer.cornerCurve = options.isCornerCurveCircular ? .circular : .continuous
        layer.masksToBounds = true
    }
}

// MARK: - Window Configuration, FullScreenWatch & Keyable Panel (platform/macos.rs, window/mac.rs)

/// Watches `NSWindow` full-screen enter/exit notifications and triggers a chrome sync/redraw.
@MainActor
public final class FullScreenWatch {
    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []
    private var changed = false

    public init(window: NSWindow, onTransition: @escaping @MainActor () -> Void = {}) {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ]
        for name in names {
            let tok = center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    self?.changed = true
                    window?.contentView?.needsDisplay = true
                    onTransition()
                }
            }
            tokens.append(tok)
        }
    }

    deinit {
        for tok in tokens {
            NotificationCenter.default.removeObserver(tok)
        }
    }

    public func takeChanged() -> Bool {
        let was = changed
        changed = false
        return was
    }
}

/// Non-activating `NSPanel` subclass that still accepts key focus when clicked or requested (`OverlayPanel`).
public final class RuneKeyablePanel: NSPanel {
    public var allowsKeyFocus: Bool = true

    override public var canBecomeKey: Bool {
        allowsKeyFocus
    }

    override public var canBecomeMain: Bool {
        false
    }
}

/// macOS native window construction and chrome synchronization (`platform/macos.rs`, `window/chrome.rs`).
public enum RuneMacWindowConfig {
    @MainActor
    public static func configureWindow(_ window: NSWindow, options: MacWindowOptions) {
        if let shadow = options.shadow {
            window.hasShadow = shadow
        }
        if let level = options.level {
            window.level = NSWindow.Level(rawValue: level)
        }
        if let bits = options.collectionBehavior {
            window.collectionBehavior = NSWindow.CollectionBehavior(rawValue: bits)
        }
        if let exclude = options.excludeFromCapture {
            window.sharingType = exclude ? .none : .readOnly
        }
    }

    @MainActor
    public static func frameChrome(
        chrome: Chrome,
        titlebar: Titlebar?,
        titlebarSet: TitlebarSet = TitlebarSet()
    ) -> Chrome {
        guard let titlebar else { return chrome }
        return titlebarSet.over(titlebar).macChrome(chrome)
    }

    @MainActor
    public static func syncChrome(
        window: NSWindow,
        chrome: Chrome,
        titlebar: Titlebar?,
        titlebarSet: TitlebarSet = TitlebarSet()
    ) -> ChromeInsets {
        let effective = frameChrome(chrome: chrome, titlebar: titlebar, titlebarSet: titlebarSet)
        if let spot = effective.trafficLights {
            RuneTrafficLights.place(window, at: spot)
        }
        let leading = RuneTrafficLights.titlebarInset(window)
        let lightsRight = RuneTrafficLights.trafficLightsRight(window)
        let left: Float = lightsRight ? 0.0 : leading
        let right: Float = lightsRight ? leading : 0.0
        let bandHeight = titlebar.map { titlebarSet.over($0).height } ?? 0.0
        return ChromeInsets(leading: left, trailing: right, height: bandHeight)
    }

    @MainActor
    public static func titlebarDoubleClick(_ window: NSWindow) {
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        switch action {
        case "Minimize":
            window.miniaturize(nil)
        case "None":
            break
        default:
            window.zoom(nil)
        }
    }

    @MainActor
    public static func placement(of window: NSWindow) -> WindowPlacement {
        let frame = window.frame
        let contentRect = window.contentRect(forFrameRect: frame)
        let scale = Double(window.backingScaleFactor)
        let screenFrame = window.screen?.frame
        let displayOrigin = screenFrame.map { (Int32($0.origin.x.rounded()), Int32($0.origin.y.rounded())) }
        let displaySize = screenFrame.map { (UInt32(($0.size.width * scale).rounded()), UInt32(($0.size.height * scale).rounded())) }
        return WindowPlacement(
            position: (Int32(frame.origin.x.rounded()), Int32(frame.origin.y.rounded())),
            contentPosition: (Int32(contentRect.origin.x.rounded()), Int32(contentRect.origin.y.rounded())),
            contentSize: (
                UInt32(max(0, (contentRect.size.width * scale).rounded())),
                UInt32(max(0, (contentRect.size.height * scale).rounded()))
            ),
            scale: scale,
            maximized: window.isZoomed,
            minimized: window.isMiniaturized,
            fullScreen: window.styleMask.contains(.fullScreen),
            restore: nil,
            display: displayOrigin.flatMap { o in displaySize.map { s in (o, s) } }
        )
    }

    @MainActor
    public static func makeWindow(
        title: String,
        size: Vec2,
        minSize: Vec2?,
        chrome: Chrome,
        titlebar: Titlebar?,
        options: WindowOptions,
        macos: MacWindowOptions,
        openAs: OpenAs
    ) -> NSWindow {
        var style: NSWindow.StyleMask = options.borderless ? [.borderless] : [.titled, .closable, .miniaturizable]
        if options.resizable && !options.borderless {
            style.insert(.resizable)
        }
        let effectiveChrome = frameChrome(chrome: chrome, titlebar: titlebar)
        if !options.borderless && effectiveChrome.fullSizeContent {
            style.insert(.fullSizeContentView)
        }
        let rect = NSRect(x: 0, y: 0, width: CGFloat(size.x), height: CGFloat(size.y))
        let window: NSWindow
        if macos.nonactivatingPanel {
            style.insert(.nonactivatingPanel)
            let panel = RuneKeyablePanel(
                contentRect: rect,
                styleMask: style,
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = false
            panel.hidesOnDeactivate = false
            window = panel
        } else {
            window = NSWindow(
                contentRect: rect,
                styleMask: style,
                backing: .buffered,
                defer: false
            )
        }
        window.title = title
        window.isReleasedWhenClosed = false
        if options.transparent {
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        if !options.borderless && effectiveChrome.fullSizeContent {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        if options.alwaysOnTop {
            window.level = .floating
        }
        if options.clickThrough {
            window.ignoresMouseEvents = true
        }
        let appMinTuple = minSize.map { ($0.x, $0.y) }
        let (minLim, maxLim) = options.sizeLimits(appMin: appMinTuple)
        window.contentMinSize = NSSize(width: CGFloat(minLim.0), height: CGFloat(minLim.1))
        if let maxLim {
            window.contentMaxSize = NSSize(width: CGFloat(maxLim.0), height: CGFloat(maxLim.1))
        }
        if let phys = options.physicalSize {
            let scale = window.backingScaleFactor
            window.setContentSize(NSSize(width: CGFloat(phys.0) / scale, height: CGFloat(phys.1) / scale))
        }
        if let pos = options.position {
            window.setFrameTopLeftPoint(NSPoint(x: CGFloat(pos.0), y: CGFloat(pos.1)))
        }
        configureWindow(window, options: macos)
        if openAs.maximizes && !window.isZoomed {
            window.zoom(nil)
        }
        if openAs.fullScreens && !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        return window
    }
}

// MARK: - Multi-Window AppKit Host (window.rs, window/any_host.rs, window/spec.rs)

@MainActor
private final class HostedWindowSlot: NSObject, NSWindowDelegate {
    let slotIndex: Int
    let entry: HostedWindowEntry
    let runtime: AnyObject
    let renderer: MetalRenderer
    let window: NSWindow
    let view: RuneHostedMetalView
    let waker: Waker
    var restMachine = WindowRestMachine()
    var restTimer: Timer?
    var fullScreenWatch: FullScreenWatch?
    var trafficLightSpot: RuneTrafficLights.Spot?
    var shortcutGuard: ShortcutGuard?
    var shortcutBridge: MacOSHostShortcutBridge?
    var isHiddenOrClosed = false
    var isTornDown = false
    weak var host: RuneMultiWindowHost?

    init(
        slotIndex: Int,
        entry: HostedWindowEntry,
        runtime: AnyObject,
        renderer: MetalRenderer,
        window: NSWindow,
        view: RuneHostedMetalView,
        waker: Waker
    ) {
        self.slotIndex = slotIndex
        self.entry = entry
        self.runtime = runtime
        self.renderer = renderer
        self.window = window
        self.view = view
        self.waker = waker
        super.init()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // `WindowEvent::Focused`: reduced motion, the contrast theme and Increase Contrast are
        // read again (`window/events.rs`).
        view.rereadSystemAccessibilitySettings()
        entry.setFocused(runtimeObj: runtime, focused: true)
        view.requestRender()
    }

    func windowDidResignKey(_ notification: Notification) {
        // `WindowEvent::Focused(false)` re-reads them too.
        view.rereadSystemAccessibilitySettings()
        entry.setFocused(runtimeObj: runtime, focused: false)
        view.requestRender()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        // Covered or uncovered, minimising included (`WindowEvent::Occluded`): the view's driver
        // steps its sight and routes wakes through `covered_step` while it can't draw (#995).
        if WindowCoverWatch.occluded(window) {
            view.coverChanged(occluded: true)
            stepRest(.unseen)
        } else {
            // Uncovered: re-sync the chrome as `window/sight.rs` does, then draw what changed.
            entry.syncWindowChrome(runtimeObj: runtime, window: window)
            if view.coverChanged(occluded: false) != .redraw {
                view.requestRender()
            }
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        stepRest(.unseen)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if entry.secondary {
            view.cancelActiveModals()
            window.orderOut(nil)
            isHiddenOrClosed = true
            stepRest(.unseen)
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard !entry.secondary else { return }
        view.stopTimer()
        view.cancelActiveModals()
        restTimer?.invalidate()
        restTimer = nil
        isTornDown = true
        shortcutGuard?.close()
        shortcutGuard = nil
        shortcutBridge?.clear()
        shortcutBridge = nil
        entry.markMenusRunning(false)
        entry.handle.unbind()
        host?.handlePrimaryClosed(slot: slotIndex)
    }

    func stepRest(_ event: WindowRestMachine.Event) {
        let effects = restMachine.step(event)
        for effect in effects {
            switch effect {
            case .giveBackUnused:
                entry.trimIdleCaches(runtimeObj: runtime, all: false)
                view.giveBackRenderer(all: false)
            case .giveBackAll:
                entry.trimIdleCaches(runtimeObj: runtime, all: true)
                view.giveBackRenderer(all: true)
            }
        }
        scheduleRestTimerIfNeeded()
    }

    private func scheduleRestTimerIfNeeded() {
        restTimer?.invalidate()
        restTimer = nil
        guard let due = restMachine.deadline else { return }
        let delay = max(0.05, due - ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isTornDown else { return }
                self.stepRest(.woke(now: ProcessInfo.processInfo.systemUptime))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        restTimer = timer
    }
}

@MainActor
private final class RuneHostedMetalView: NSView, @MainActor NSTextInputClient {
    private let entry: HostedWindowEntry
    private let runtime: AnyObject
    private let renderer: MetalRenderer
    private let metalLayer = CAMetalLayer()
    private let startTime = CACurrentMediaTime()
    private let timeScale: Double
    private let respectSystemAppearance: Bool
    private var displayLinkDriver: MacOSDisplayLinkDriver?
    private var trackingAreaRef: NSTrackingArea?
    private var didSignalReady = false
    private var didRunOnReady = false
    private var shadowResample = ShadowResampleState()
    private var drawableCounter: UInt64 = 0
    private let popupPresenter = MacOSPopupMenuPresenter()
    private let fileDialogPresenter = MacOSFileDialogPresenter()
    private let dragOutCoordinator = MacOSDragOutCoordinator()
    private let accessibilityHost = MacOSAccessibilityHost()
    private lazy var textInputBridge = MacOSTextInputBridge { [weak self] imeEvent in
        guard let self else { return }
        var dispatched = false
        self.arrived(.keyPress, nil) { dispatched = self.entry.dispatchImeEvent(runtimeObj: self.runtime, event: imeEvent, at: self.nowSeconds()) }
        if dispatched {
            self.requestRender()
        }
    }
    private var lastAppliedCursor: Cursor = .default
    private var didInitialA11ySync = false
    /// The accessibility tree must go out again although no commit changed it (#980).
    private var a11yFollowUp = false
    /// The launch's `--reduced-motion`: the system's setting can't turn it off.
    private var forceReducedMotion = false
    private let toolTipOwner = MacOSToolTipOwner()
    private let windowFrameDriver = MacOSWindowFrameDriver()
    private var appliedMenuRevision: UInt64 = 0
    private var isWindowResting = true
    private let fnKeyMonitor = FnKeyMonitor()
    /// Whether the shown window can draw, and what covering it runs (`window/sight.rs`, #995).
    private var coverDriver = CoveredWindowDriver()
    weak var slot: HostedWindowSlot?

    init(
        frame: NSRect,
        entry: HostedWindowEntry,
        runtime: AnyObject,
        renderer: MetalRenderer,
        timeScale: Double,
        respectSystemAppearance: Bool
    ) {
        self.entry = entry
        self.runtime = runtime
        self.renderer = renderer
        self.timeScale = timeScale
        self.respectSystemAppearance = respectSystemAppearance
        super.init(frame: frame)
        self.wantsLayer = true
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.framebufferOnly = false
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        self.layer = metalLayer
        MacOSMetalLayerSurface.pinContentsTopLeft(metalLayer)
        registerForDraggedTypes(MacOSDropReader.draggedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingAreaRef {
            removeTrackingArea(old)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        shadowResample.redraw()
        syncGeometryAndRender()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        shadowResample.redraw()
        syncGeometryAndRender()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard respectSystemAppearance else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        entry.setSystemDark(runtimeObj: runtime, dark: dark)
        requestRender()
    }

    func stopTimer() {
        displayLinkDriver?.stop()
        displayLinkDriver = nil
        if let w = window {
            windowFrameDriver.landFrame(window: w)
        }
    }

    private func nowSeconds() -> Double {
        (CACurrentMediaTime() - startTime) * timeScale
    }

    func syncGeometryAndRender() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let newVP = Vec2(Float(max(1, bounds.width)), Float(max(1, bounds.height)))
        if windowFrameDriver.isMoving || windowFrameDriver.takeJumpIfMatching(viewport: newVP) {
            entry.stepViewport(runtimeObj: runtime, viewport: newVP, pixelScale: Float(scale))
        } else {
            entry.applyViewport(runtimeObj: runtime, viewport: newVP, pixelScale: Float(scale))
        }
        // Resized / ScaleFactorChanged re-sync the chrome (`window/events.rs`).
        if let w = window {
            entry.syncWindowChrome(runtimeObj: runtime, window: w)
        }
        requestRender()
    }

    /// The window's accessibility adapter watches the workspace's display options and reads
    /// reduced motion, the contrast theme and Increase Contrast again when they change (#980).
    func watchSystemDisplayOptions(forceReducedMotion: Bool) {
        self.forceReducedMotion = forceReducedMotion
        accessibilityHost.watchDisplayOptions { [weak self] in
            guard let self else { return }
            self.rereadSystemAccessibilitySettings()
            self.requestRender()
        }
    }

    /// Reduced motion (kept on under the launch's `--reduced-motion`), the contrast theme and
    /// Increase Contrast, read again from the system.
    func rereadSystemAccessibilitySettings() {
        entry.readSystemAccessibilitySettings(runtimeObj: runtime, forceReducedMotion: forceReducedMotion)
    }

    func requestRender() {
        guard bounds.width > 0 && bounds.height > 0 else { return }
        let t = nowSeconds()
        if let w = window {
            let scale = Float(w.backingScaleFactor)
            _ = windowFrameDriver.step(window: w, now: t, scale: scale, resting: isWindowResting) { [weak self] vp, sc in
                guard let self else { return }
                self.entry.stepViewport(runtimeObj: self.runtime, viewport: vp, pixelScale: sc)
            }
        }
        isWindowResting = !(inLiveResize || windowFrameDriver.isMoving)
        entry.setWindowResting(runtimeObj: runtime, resting: isWindowResting)
        entry.applyAppStateUpdates(runtimeObj: runtime, at: t, shortcutGuard: slot?.shortcutGuard)
        entry.syncNativeMenus(
            runtimeObj: runtime,
            appliedRevision: &appliedMenuRevision,
            nowProvider: { [weak self] in self?.nowSeconds() ?? 0.0 },
            onDispatched: { [weak self] in self?.requestRender() }
        )
        if !coverDriver.canDraw {
            coveredTick(at: t)
            return
        }
        let commitsBefore = entry.viewCommitCount(runtimeObj: runtime)
        let refScene = entry.frame(runtimeObj: runtime, at: t)
        // A new `Cx::set_titlebar` / `Cx::titlebar_height` moves the traffic lights and the band
        // (`window/lifecycle.rs` `take_titlebar_changed`); changed insets re-run the view next.
        if entry.takeTitlebarChanged(runtimeObj: runtime), let w = window {
            entry.syncWindowChrome(runtimeObj: runtime, window: w)
            DispatchQueue.main.async { [weak self] in self?.requestRender() }
        }
        if let title = entry.windowTitle(runtimeObj: runtime), let w = window, w.title != title {
            w.title = title
        }
        if entry.quitRequested(runtimeObj: runtime) {
            let after: QuitAfter = entry.relaunchRequested(runtimeObj: runtime) ? .relaunch : .exit
            _ = QuitLifecycle.send(.start(ending: false, after: after))
            NSApplication.shared.terminate(nil)
            return
        }
        if let drawable = metalLayer.nextDrawable() {
            renderer.render(scene: refScene, to: drawable)
            drawableCounter &+= 1
            shadowResample.presented(drawableCounter)
            slot?.stepRest(.drew(now: ProcessInfo.processInfo.systemUptime, lowMemory: false))
            if shadowResample.turn(onScreen: drawableCounter), entry.options.transparent, let win = window, win.hasShadow {
                win.invalidateShadow()
            }
            if !didSignalReady {
                didSignalReady = true
                ReadySignal.ready()
                entry.handle.setReady(true)
                runOnReadyOnce()
            }
        }
        slot?.host?.drainOpenedWindows()
        pumpPlatformActions()
        applyWindowFrameRequest(at: t)
        // The accessibility stamp: a commit, held words or an attaching reader, or words said since
        // the last update (`announced`), which a live-only `Tx::announce` brings without a commit.
        syncPlatformBridges(
            treeCommitted: !didInitialA11ySync || a11yFollowUp
                || entry.viewCommitCount(runtimeObj: runtime) != commitsBefore
                || accessibilityHost.announcementChanged(entry.accessibilityAnnouncement(runtimeObj: runtime))
        )

        if entry.isAnimating(runtimeObj: runtime) || windowFrameDriver.isMoving {
            if displayLinkDriver == nil {
                displayLinkDriver = MacOSDisplayLinkDriver { [weak self] in
                    self?.requestRender()
                }
            }
            displayLinkDriver?.start(in: self)
        } else {
            stopTimer()
        }
    }

    /// The window was covered, uncovered, minimised or restored (`Host::set_cover`). Returns what
    /// the driver asks of the host; the slot rests a covered window (`rest_step(Unseen)`).
    @discardableResult
    func coverChanged(occluded: Bool) -> CoveredWindowDriver.Outcome {
        let outcome = coverDriver.setOccluded(occluded, runtime: entry.coveredRuntime(runtimeObj: runtime), at: nowSeconds())
        switch outcome {
        case .rest:
            stopTimer()
        case .redraw:
            requestRender()
        case .none:
            break
        }
        return outcome
    }

    /// A wake, due timer or redraw for a shown window that can't draw (`covered_step`): `poll`,
    /// due timers and queued input run, and while an assistive client reads the window what
    /// changed builds at once for it (`Runtime::covered_wake`); nothing draws or moves.
    private func coveredTick(at t: Double) {
        stopTimer()
        let committed = coverDriver.step(entry.coveredRuntime(runtimeObj: runtime), at: t)
        // `on_ready` starts an app's live work, so it can't wait on a drawable: the first frame
        // skipped for being off screen runs it; the window isn't ready until it draws
        // (`FirstFrame::skipped`).
        runOnReadyOnce()
        // What the step asked of the shell goes out now (`self.shell(event_loop)`).
        if let title = entry.windowTitle(runtimeObj: runtime), let w = window, w.title != title {
            w.title = title
        }
        if entry.quitRequested(runtimeObj: runtime) {
            let after: QuitAfter = entry.relaunchRequested(runtimeObj: runtime) ? .relaunch : .exit
            _ = QuitLifecycle.send(.start(ending: false, after: after))
            NSApplication.shared.terminate(nil)
            return
        }
        slot?.host?.drainOpenedWindows()
        pumpPlatformActions()
        applyWindowFrameRequest(at: t)
        syncPlatformBridges(
            treeCommitted: committed || a11yFollowUp
                || accessibilityHost.announcementChanged(entry.accessibilityAnnouncement(runtimeObj: runtime))
        )
    }

    /// `App::on_ready`, once per window: at its first drawn frame or first covered one.
    private func runOnReadyOnce() {
        guard !didRunOnReady else { return }
        didRunOnReady = true
        entry.fireOnReady()
    }

    /// A `Tx.setWindowFrame` the runtime holds goes to the window (`window/frame.rs`).
    private func applyWindowFrameRequest(at t: Double) {
        guard let frameReq = entry.takeWindowFrameRequest(runtimeObj: runtime), let w = window else { return }
        let scale = Float(w.backingScaleFactor)
        let minSz = entry.options.minSize ?? WindowOptions.defaultMinSize
        windowFrameDriver.applyRequest(
            frameReq,
            window: w,
            now: t,
            minSize: (minSz.x, minSz.y),
            maxSize: entry.options.maxSize.map { ($0.x, $0.y) },
            scale: scale
        ) { [weak self] vp, sc in
            guard let self else { return }
            self.entry.stepViewport(runtimeObj: self.runtime, viewport: vp, pixelScale: sc)
        }
    }

    private func syncPlatformBridges(treeCommitted: Bool) {
        let focused = window?.isKeyWindow ?? true
        let imeAllowed = entry.hasImeTarget(runtimeObj: runtime) && !entry.hasSecureFocus(runtimeObj: runtime) && focused
        let cancelIme = entry.consumeImeReset(runtimeObj: runtime)
        let caretRect = MacOSHostViewHelper.caretScreenRect(
            caret: entry.focusedCaretRect(runtimeObj: runtime),
            in: self
        )
        textInputBridge.sync(
            imeText: imeAllowed ? entry.focusedImeSnapshot(runtimeObj: runtime) : nil,
            caretScreenRect: caretRect,
            cancelExisting: cancelIme,
            in: self
        )

        MacOSHostViewHelper.applyCursor(
            entry.currentCursor(runtimeObj: runtime),
            previous: &lastAppliedCursor,
            in: self
        )

        if treeCommitted {
            didInitialA11ySync = true
            a11yFollowUp = false
            if accessibilityHost.onActivate == nil {
                accessibilityHost.onActivate = { [weak self] in self?.scheduleAccessibilityFollowUp() }
            }
            toolTipOwner.sync(regions: entry.helpRegionsList(runtimeObj: runtime), on: self)
            let snapshot = entry.accessibilitySnapshot(runtimeObj: runtime)
            let held = accessibilityHost.update(
                tree: snapshot,
                announcement: entry.accessibilityAnnouncement(runtimeObj: runtime),
                parentView: self
            ) { [weak self] id, action in
                MacOSHostViewHelper.dispatchAccessibilityAction(id, action: action) { id, action in
                    guard let self else { return }
                    if self.entry.performAccessibilityAction(
                        runtimeObj: self.runtime,
                        id: id,
                        action: action,
                        at: self.nowSeconds()
                    ) {
                        self.requestRender()
                    }
                }
            }
            if held { scheduleAccessibilityFollowUp() }
        }
    }

    /// Held announcer words or a client that just attached: the runtime stays dirty and the tree
    /// goes out again on the next frame (`a11y_update`'s `self.dirty = true`).
    private func scheduleAccessibilityFollowUp() {
        a11yFollowUp = true
        entry.markAccessibilityDirty(runtimeObj: runtime)
        DispatchQueue.main.async { [weak self] in self?.requestRender() }
    }

    private func localPoint(for event: NSEvent) -> Vec2 {
        let p = convert(event.locationInWindow, from: nil)
        return Vec2(Float(p.x), Float(p.y))
    }

    private func mods(for event: NSEvent) -> Mods {
        MacOSKeyMapper.mods(for: event)
    }

    /// Dispatches `body` as the platform input `event` of `kind` (else AppKit's current event
    /// when it is that kind), inside the scope holding when it arrived (`input::time::arrived`).
    private func arrived(_ kind: HostInputKind, _ event: NSEvent?, _ body: () -> Void) {
        entry.hostInput(runtimeObj: runtime, kind: kind, eventTimestamp: MacOSInputEvents.timestamp(kind, event), body)
    }

    override func mouseMoved(with event: NSEvent) {
        arrived(.pointer, event) { entry.pointerMove(runtimeObj: runtime, to: localPoint(for: event), mods: mods(for: event), at: nowSeconds()) }
        requestRender()
    }

    override func mouseExited(with event: NSEvent) {
        arrived(.pointer, event) { entry.pointerExit(runtimeObj: runtime, at: nowSeconds()) }
        requestRender()
    }

    override func mouseDragged(with event: NSEvent) {
        arrived(.pointer, event) { entry.pointerMove(runtimeObj: runtime, to: localPoint(for: event), mods: mods(for: event), at: nowSeconds()) }
        requestRender()
    }

    override func mouseDown(with event: NSEvent) {
        let pt = localPoint(for: event)
        if entry.copyTitlebarDragHits(runtimeObj: runtime, point: pt), let win = window {
            if event.clickCount >= 2 {
                RuneMacWindowConfig.titlebarDoubleClick(win)
                return
            }
            win.performDrag(with: event)
            return
        }
        arrived(.pointer, event) { entry.pointerDown(runtimeObj: runtime, at: pt, button: .primary, mods: mods(for: event), at: nowSeconds()) }
        requestRender()
    }

    override func mouseUp(with event: NSEvent) {
        arrived(.pointer, event) { entry.pointerUp(runtimeObj: runtime, at: localPoint(for: event), button: .primary, mods: mods(for: event), at: nowSeconds()) }
        requestRender()
    }

    override func rightMouseDown(with event: NSEvent) {
        arrived(.pointer, event) { entry.pointerDown(runtimeObj: runtime, at: localPoint(for: event), button: .secondary, mods: mods(for: event), at: nowSeconds()) }
        requestRender()
    }

    override func rightMouseUp(with event: NSEvent) {
        arrived(.pointer, event) { entry.pointerUp(runtimeObj: runtime, at: localPoint(for: event), button: .secondary, mods: mods(for: event), at: nowSeconds()) }
        requestRender()
    }

    override func scrollWheel(with event: NSEvent) {
        // `window/events.rs`: native wheel distances matched to Chromium (#856).
        let (dx, dy) = WheelDistance.points(for: event)
        let wev = WheelEvent(
            dx: dx,
            dy: dy,
            precise: event.hasPreciseScrollingDeltas,
            mods: mods(for: event)
        )
        arrived(.wheel, event) { entry.wheel(runtimeObj: runtime, event: wev, at: localPoint(for: event), now: nowSeconds()) }
        requestRender()
    }

    override func keyDown(with event: NSEvent) {
        let focused = window?.isKeyWindow ?? true
        let imeAllowed = entry.hasImeTarget(runtimeObj: runtime) && !entry.hasSecureFocus(runtimeObj: runtime) && focused
        let optionAsAlt = imeAllowed && entry.imeOptionAsAlt(runtimeObj: runtime)
        if imeAllowed {
            var imeResult: MacOSKeyInterceptResult = .forwardKeyDown
            arrived(.keyPress, event) { imeResult = textInputBridge.processKeyDown(event, in: self, optionAsAlt: optionAsAlt) }
            if imeResult == .handledByIME {
                requestRender()
                return
            }
        }
        guard let kev = MacOSKeyMapper.makeKeyEvent(from: event, optionAsAlt: optionAsAlt) else { return }
        arrived(.keyPress, event) { _ = entry.keyDownWithClipboardSync(runtimeObj: runtime, event: kev, at: nowSeconds()) }
        requestRender()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            _ = fnKeyMonitor.start(on: window)
        } else {
            fnKeyMonitor.stop()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        arrived(.keyRelease, event) { dispatchFlagsChanged(event) }
        requestRender()
    }

    private func dispatchFlagsChanged(_ event: NSEvent) {
        let now = nowSeconds()
        let fnTransitions = fnKeyMonitor.take()
        if !fnTransitions.isEmpty {
            let currentMods = mods(for: event)
            entry.dispatchModifiers(runtimeObj: runtime, mods: currentMods, at: now)
            for fnPressed in fnTransitions {
                _ = entry.keyDown(runtimeObj: runtime, event: KeyEvent(key: .modifier(.fn, pressed: fnPressed), mods: currentMods), at: now)
            }
        }
        if let mapped = MacOSKeyMapper.modifierKeyEvent(keyCode: event.keyCode, flags: event.modifierFlags) {
            entry.dispatchModifiers(runtimeObj: runtime, mods: mapped.mods, at: now)
            if event.keyCode != FnKeyMonitor.keyCodeFn || fnTransitions.isEmpty {
                _ = entry.keyDown(runtimeObj: runtime, event: mapped.event, at: now)
            }
        } else {
            entry.dispatchModifiers(runtimeObj: runtime, mods: mods(for: event), at: now)
        }
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        textInputBridge.insertText(string, replacementRange: replacementRange)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        textInputBridge.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    func unmarkText() {
        textInputBridge.unmarkText()
    }

    func selectedRange() -> NSRange {
        textInputBridge.selectedRange()
    }

    func markedRange() -> NSRange {
        textInputBridge.markedRange()
    }

    func hasMarkedText() -> Bool {
        textInputBridge.hasMarkedText()
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        textInputBridge.attributedSubstring(forProposedRange: range, actualRange: actualRange)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        textInputBridge.validAttributesForMarkedText()
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        textInputBridge.firstRect(forCharacterRange: range, actualRange: actualRange)
    }

    func characterIndex(for point: NSPoint) -> Int {
        textInputBridge.characterIndex(for: point)
    }

    override func doCommand(by selector: Selector) {
        textInputBridge.doCommand(by: selector)
    }

    // MARK: - NSAccessibility

    nonisolated override func isAccessibilityElement() -> Bool {
        false
    }

    nonisolated override func accessibilityChildren() -> [Any]? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated {
            // An assistive client reads the tree (AccessKit's activation): covered, the window
            // builds what changed for it at once (`Runtime::covered_wake`).
            coverDriver.assistiveClientAttached(entry.coveredRuntime(runtimeObj: runtime))
            return MacOSUnsafeSendableBox(accessibilityHost.accessibilityChildren())
        }.value
    }

    nonisolated override var accessibilityFocusedUIElement: Any? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated {
            MacOSUnsafeSendableBox(accessibilityHost.accessibilityFocusedUIElement())
        }.value
    }

    nonisolated override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard Thread.isMainThread else { return super.accessibilityHitTest(point) }
        return MainActor.assumeIsolated {
            MacOSUnsafeSendableBox(accessibilityHost.accessibilityHitTest(point, in: self))
        }.value ?? super.accessibilityHitTest(point)
    }

    func cancelActiveModals() {
        popupPresenter.cancel()
        fileDialogPresenter.cancel()
        entry.cancelPopups(runtimeObj: runtime)
        entry.cancelFileDialogs(runtimeObj: runtime, at: nowSeconds())
    }

    func giveBackRenderer(all: Bool) {
        renderer.giveBack(all: all, residentCaches: all)
    }

    private func pumpPlatformActions() {
        if let dragStart = entry.takeDragOutStart(runtimeObj: runtime) {
            dragOutCoordinator.start(dragStart, in: self) { [weak self] outcome in
                guard let self else { return }
                self.entry.finishDragOut(runtimeObj: self.runtime, outcome: outcome, at: self.nowSeconds())
                self.requestRender()
            }
        }
        if !popupPresenter.isPresenting {
            while let taken = entry.takePopup(runtimeObj: runtime) {
                switch taken {
                case .failure:
                    continue
                case .success(let show):
                    popupPresenter.present(show, in: self) { [weak self] picked in
                        guard let self else { return }
                        self.entry.resolvePopup(runtimeObj: self.runtime, picked: picked)
                        self.requestRender()
                    }
                    break
                }
                break
            }
        }
        if !fileDialogPresenter.isPresenting, let pending = entry.takeFileDialog(runtimeObj: runtime) {
            fileDialogPresenter.present(pending, in: self.window) { [weak self] id, result in
                guard let self else { return }
                self.entry.answerFileDialog(runtimeObj: self.runtime, id: id, result: result)
                self.requestRender()
            }
        }
    }

    // MARK: - NSDraggingDestination (File Drop)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = MacOSDropReader.hoverURLs(from: sender)
        guard !urls.isEmpty else { return [] }
        let pt = localPoint(forDragging: sender)
        let files = urls.map { DroppedFile(url: $0) }
        entry.fileDrop(runtimeObj: runtime, event: .entered(files, at: pt), at: nowSeconds())
        requestRender()
        return entry.acceptsDrop(runtimeObj: runtime, urls: urls, at: pt) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = MacOSDropReader.hoverURLs(from: sender)
        let pt = localPoint(forDragging: sender)
        entry.fileDrop(runtimeObj: runtime, event: .hovered(at: pt), at: nowSeconds())
        requestRender()
        guard !urls.isEmpty else { return [] }
        return entry.acceptsDrop(runtimeObj: runtime, urls: urls, at: pt) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        entry.fileDrop(runtimeObj: runtime, event: .exited, at: nowSeconds())
        requestRender()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pt = localPoint(forDragging: sender)
        let hoverUrls = MacOSDropReader.hoverURLs(from: sender)
        guard !hoverUrls.isEmpty else { return false }
        MacOSDropReader.dropURLs(from: sender) { [weak self] urls in
            guard let self, !urls.isEmpty else { return }
            let files = urls.map { DroppedFile(url: $0) }
            self.entry.fileDrop(runtimeObj: self.runtime, event: .dropped(files, at: pt), at: self.nowSeconds())
            self.requestRender()
        }
        return true
    }

    private func localPoint(forDragging sender: NSDraggingInfo) -> Vec2 {
        let p = convert(sender.draggingLocation, from: nil)
        return Vec2(Float(p.x), Float(p.y))
    }
}

/// Multi-window AppKit event loop coordinator (`crates/rune/src/window.rs`).
@MainActor
public final class RuneMultiWindowHost: NSObject, NSApplicationDelegate {
    private var slots: [HostedWindowSlot] = []
    private let runOptions: RunOptions
    private let parsed: ToolingArgs

    private init(runOptions: RunOptions, parsed: ToolingArgs) {
        self.runOptions = runOptions
        self.parsed = parsed
        super.init()
    }

    public static func run(
        _ windows: [AnyWindowSpec],
        options: RunOptions = RunOptions(),
        parsed: ToolingArgs = ToolingArgs()
    ) throws {
        ReadySignal.runStarts()
        RelaunchController.waitForPrevious()

        let app = NSApplication.shared
        app.setActivationPolicy(options.accessory ? .accessory : .regular)
        if !options.accessory {
            _ = RuneDefaultMacMenus.ensure(app)
            RuneDefaultMacMenus.addStandardMenus(app)
        }

        let host = RuneMultiWindowHost(runOptions: options, parsed: parsed)
        app.delegate = host
        MacOSQuitHook.install()

        for spec in windows {
            try host.openEntry(spec.makeHostEntry())
        }

        // `RUNE_OPEN_INACTIVE` (a tool's launch): the app doesn't take activation at launch
        // either; the activation policy stays the app's own (#962).
        if OpenInactiveLaunch.activatesAtLaunch(accessory: options.accessory) {
            app.activate(ignoringOtherApps: true)
        }
        defer {
            for slot in host.slots {
                slot.entry.markMenusRunning(false)
            }
            RuneNativeMenuHost.shared.clear()
        }
        withExtendedLifetime(host) {
            app.run()
        }
        QuitLifecycle.finishOrderlyExit()
    }

    private func openEntry(_ specEntry: HostedWindowEntry) throws {
        // Never duplicate an already-open non-torn-down key.
        if slots.contains(where: { !$0.isTornDown && $0.entry.key == specEntry.key }) {
            return
        }
        let slotIndex = slots.count
        let app = NSApplication.shared
        let sysDark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let waker = Waker()
        let scale = Float(NSScreen.main?.backingScaleFactor ?? 2.0)
        let reducedMotion = parsed.reducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let rt = specEntry.createRuntime(
            pixelScale: scale,
            systemDark: sysDark,
            reducedMotion: reducedMotion,
            waker: waker
        )
        specEntry.markMenusRunning(true)
        let renderer = try MetalRenderer()
        let initialVP = specEntry.runtimeViewport(runtimeObj: rt)
        let window = RuneMacWindowConfig.makeWindow(
            title: specEntry.title,
            size: initialVP,
            minSize: specEntry.minSize,
            chrome: specEntry.chrome,
            titlebar: specEntry.titlebar,
            options: specEntry.options,
            macos: specEntry.macosWindow,
            openAs: specEntry.openAs
        )
        let respectSysDark = parsed.darkOverride == nil && specEntry.darkOverride == nil
        let view = RuneHostedMetalView(
            frame: NSRect(x: 0, y: 0, width: CGFloat(initialVP.x), height: CGFloat(initialVP.y)),
            entry: specEntry,
            runtime: rt,
            renderer: renderer,
            timeScale: parsed.timeScale,
            respectSystemAppearance: respectSysDark
        )
        let slot = HostedWindowSlot(
            slotIndex: slotIndex,
            entry: specEntry,
            runtime: rt,
            renderer: renderer,
            window: window,
            view: view,
            waker: waker
        )
        slot.host = self
        view.slot = slot
        view.watchSystemDisplayOptions(forceReducedMotion: parsed.reducedMotion)
        window.delegate = slot
        window.contentView = view

        RuneWindowShape.applyCorners(
            to: window,
            options: specEntry.macosWindow,
            transparent: specEntry.options.transparent,
            borderless: specEntry.options.borderless
        )
        RuneDragRegions.ownWindowDragging(window: window, chrome: specEntry.chrome)
        slot.trafficLightSpot = RuneTrafficLights.Spot(window: window)
        let skipHostShortcutBridge = specEntry.hasAppGlobalShortcuts
        slot.shortcutGuard = specEntry.attachShortcuts(wake: waker, headless: false)
        if !skipHostShortcutBridge {
            let shortcutBridge = MacOSHostShortcutBridge()
            shortcutBridge.sync(registry: specEntry.shortcutRegistry(runtimeObj: rt))
            slot.shortcutBridge = shortcutBridge
        }
        // `window/chrome.rs::sync_chrome`: place the traffic lights, then tell the runtime what
        // the window's controls take of the titlebar (`set_titlebar_inset`, `set_chrome_insets`).
        specEntry.syncWindowChrome(runtimeObj: rt, window: window)
        slot.fullScreenWatch = FullScreenWatch(window: window) { [weak window, weak specEntry, weak view, weak rt] in
            guard let window, let specEntry, let rt else { return }
            specEntry.syncWindowChrome(runtimeObj: rt, window: window)
            view?.requestRender()
        }

        if window.windowNumber > 0 {
            specEntry.handle.setWindowNumber(UInt32(window.windowNumber))
        }
        waker.setCallback { [weak view] in
            DispatchQueue.main.async {
                view?.requestRender()
            }
        }

        slots.append(slot)
        specEntry.handle.bind(
            slot: slotIndex,
            dispatch: { [weak self] idx, request in
                Task { @MainActor in
                    self?.handleRequest(slotIndex: idx, request: request)
                }
            },
            placementProvider: { [weak window] in
                guard let window else { return nil }
                return MainActor.assumeIsolated {
                    RuneMacWindowConfig.placement(of: window)
                }
            },
            clickThroughApplier: { [weak window] on in
                MainActor.assumeIsolated {
                    guard let window else {
                        return .failure(MultiWindowError.emptyOrDuplicateKey("closed"))
                    }
                    window.ignoresMouseEvents = on
                    return .success(())
                }
            }
        )

        specEntry.fireOnCreated()

        if specEntry.options.visible {
            if specEntry.options.position == nil {
                window.center()
            }
            // `Host::new` reads `RUNE_OPEN_INACTIVE` for every window, those opened later too:
            // a tool's launch never takes the user's keyboard (#962).
            let inactive = OpenInactiveLaunch.openInactive(app: specEntry.inactive)
            if inactive || specEntry.macosWindow.nonactivatingPanel {
                window.orderFrontRegardless()
            } else {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view)
            }
        }
        if window.windowNumber > 0 {
            specEntry.handle.setWindowNumber(UInt32(window.windowNumber))
        }
        view.syncGeometryAndRender()
    }

    func drainOpenedWindows() {
        let opened = RuneMultiWindow.takeOpened()
        for spec in opened {
            try? openEntry(spec.makeHostEntry())
        }
    }

    private func handleRequest(slotIndex: Int, request: WindowHandleRequest) {
        guard slotIndex < slots.count else { return }
        let slot = slots[slotIndex]
        guard !slot.isTornDown else { return }
        let win = slot.window
        switch request {
        case .focus:
            if win.isMiniaturized { win.deminiaturize(nil) }
            if slot.entry.macosWindow.nonactivatingPanel {
                win.orderFrontRegardless()
                win.makeKey()
            } else {
                win.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        case .open, .show:
            slot.isHiddenOrClosed = false
            if win.isMiniaturized { win.deminiaturize(nil) }
            if request == .open && !slot.entry.macosWindow.nonactivatingPanel {
                win.makeKeyAndOrderFront(nil)
            } else {
                win.orderFrontRegardless()
            }
            slot.view.requestRender()
        case .hide:
            slot.isHiddenOrClosed = true
            win.orderOut(nil)
            slot.stepRest(.unseen)
        case .close:
            win.close()
        case .setPosition(let x, let y):
            win.setFrameTopLeftPoint(NSPoint(x: CGFloat(x), y: CGFloat(y)))
        case .setAlwaysOnTop(let on):
            win.level = on ? .floating : .normal
        case .resize(let w, let h, let animate):
            var frame = win.frameRect(forContentRect: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            frame.origin.x = win.frame.origin.x
            frame.origin.y = win.frame.maxY - frame.size.height
            win.setFrame(frame, display: true, animate: animate)
        case .center:
            win.center()
        case .setTitle(let title):
            win.title = title
        case .setTaskbar(let state):
            let badge = state.badgeCount > 0 ? "\(state.badgeCount)" : ""
            NSApplication.shared.dockTile.badgeLabel = badge
        case .flash:
            NSApplication.shared.requestUserAttention(.informationalRequest)
        case .setClickThrough(let on):
            win.ignoresMouseEvents = on
        }
    }

    func handlePrimaryClosed(slot slotIndex: Int) {
        let openPrimaryRemaining = slots.contains { !$0.isTornDown && !$0.entry.secondary }
        let keepRunning = slots[slotIndex].entry.keepRunning || runOptions.accessory
        if !openPrimaryRemaining && !keepRunning {
            _ = QuitLifecycle.send(.start(ending: false, after: .exit))
            NSApplication.shared.terminate(nil)
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !runOptions.accessory && !slots.contains { $0.entry.keepRunning && !$0.isTornDown }
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = QuitLifecycle.send(.start(ending: false, after: .exit))
        return .terminateNow
    }

    public func applicationWillTerminate(_ notification: Notification) {
        for slot in slots {
            slot.view.stopTimer()
            slot.restTimer?.invalidate()
            slot.restTimer = nil
        }
        QuitLifecycle.runQuitHooksIfOwed()
        ReadySignal.clear()
        if let fastHook = QuitLifecycle.activeFastExitHook() {
            QuitLifecycle.endFast(fastHook)
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        var handled = false
        for slot in slots where !slot.isTornDown {
            if slot.entry.runReopenHook(runtimeObj: slot.runtime, hasVisibleWindows: flag) {
                handled = true
            }
        }
        return !handled
    }
}

extension MacOSApp {
    /// Launches a multi-window application using `RuneMultiWindowHost`.
    @MainActor
    public static func runWindows(
        _ windows: [AnyWindowSpec],
        options: RunOptions = RunOptions(),
        arguments: [String]? = nil
    ) throws {
        try RuneMultiWindow.runWindows(windows, options: options, arguments: arguments)
    }
}
#endif
