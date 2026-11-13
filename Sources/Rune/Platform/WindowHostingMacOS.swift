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
    public static func ownWindowDragging(window: NSWindow, chrome: RuneChrome) {
        guard let contentView = window.contentView else { return }
        let isPanel = window is NSPanel
        let borderless = !window.styleMask.contains(.titled)
        guard RuneChrome.usesDragRegions(chrome: chrome, borderless: borderless, isPanel: isPanel) else {
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
        options: RuneMacWindowOptions,
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
    public static func configureWindow(_ window: NSWindow, options: RuneMacWindowOptions) {
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
        chrome: RuneChrome,
        titlebar: RuneTitlebar?,
        titlebarSet: TitlebarSet = TitlebarSet()
    ) -> RuneChrome {
        guard let titlebar else { return chrome }
        return titlebarSet.over(titlebar).macChrome(chrome)
    }

    @MainActor
    public static func syncChrome(
        window: NSWindow,
        chrome: RuneChrome,
        titlebar: RuneTitlebar?,
        titlebarSet: TitlebarSet = TitlebarSet()
    ) -> RuneChromeInsets {
        let effective = frameChrome(chrome: chrome, titlebar: titlebar, titlebarSet: titlebarSet)
        if let spot = effective.trafficLights {
            RuneTrafficLights.place(window, at: spot)
        }
        let leading = RuneTrafficLights.titlebarInset(window)
        let lightsRight = RuneTrafficLights.trafficLightsRight(window)
        let left: Float = lightsRight ? 0.0 : leading
        let right: Float = lightsRight ? leading : 0.0
        let bandHeight = titlebar.map { titlebarSet.over($0).height } ?? 0.0
        return RuneChromeInsets(leading: left, trailing: right, height: bandHeight)
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
        chrome: RuneChrome,
        titlebar: RuneTitlebar?,
        options: RuneWindowOptions,
        macos: RuneMacWindowOptions,
        openAs: RuneOpenAs
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
        entry.setFocused(runtimeObj: runtime, focused: true)
        view.requestRender()
    }

    func windowDidResignKey(_ notification: Notification) {
        entry.setFocused(runtimeObj: runtime, focused: false)
        view.requestRender()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if !window.occlusionState.contains(.visible) {
            stepRest(.unseen)
        } else {
            view.requestRender()
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        stepRest(.unseen)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if entry.secondary {
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
        restTimer?.invalidate()
        restTimer = nil
        isTornDown = true
        entry.handle.unbind()
        host?.handlePrimaryClosed(slot: slotIndex)
    }

    func stepRest(_ event: WindowRestMachine.Event) {
        let effects = restMachine.step(event)
        for effect in effects {
            switch effect {
            case .giveBackUnused:
                entry.trimIdleCaches(runtimeObj: runtime, all: false)
            case .giveBackAll:
                entry.trimIdleCaches(runtimeObj: runtime, all: true)
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
private final class RuneHostedMetalView: NSView {
    private let entry: HostedWindowEntry
    private let runtime: AnyObject
    private let renderer: MetalRenderer
    private let metalLayer = CAMetalLayer()
    private let startTime = CACurrentMediaTime()
    private let timeScale: Double
    private let respectSystemAppearance: Bool
    private var animTimer: Timer?
    private var trackingAreaRef: NSTrackingArea?
    private var didSignalReady = false
    private var shadowResample = ShadowResampleState()
    private var drawableCounter: UInt64 = 0
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
        registerForDraggedTypes([.fileURL])
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
        animTimer?.invalidate()
        animTimer = nil
    }

    private func nowSeconds() -> Double {
        (CACurrentMediaTime() - startTime) * timeScale
    }

    func syncGeometryAndRender() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        entry.applyViewport(
            runtimeObj: runtime,
            viewport: Vec2(Float(max(1, bounds.width)), Float(max(1, bounds.height))),
            pixelScale: Float(scale)
        )
        requestRender()
    }

    func requestRender() {
        guard bounds.width > 0 && bounds.height > 0 else { return }
        let t = nowSeconds()
        let refScene = entry.frame(runtimeObj: runtime, at: t)
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
                entry.fireOnReady()
            }
        }
        slot?.host?.drainOpenedWindows()

        if entry.isAnimating(runtimeObj: runtime) {
            if animTimer == nil {
                let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.requestRender()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                animTimer = timer
            }
        } else {
            stopTimer()
        }
    }

    private func localPoint(for event: NSEvent) -> Vec2 {
        let p = convert(event.locationInWindow, from: nil)
        return Vec2(Float(p.x), Float(p.y))
    }

    private func mods(for event: NSEvent) -> Mods {
        let f = event.modifierFlags
        return Mods(
            shift: f.contains(.shift),
            ctrl: f.contains(.control),
            alt: f.contains(.option),
            cmd: f.contains(.command),
            logo: f.contains(.command)
        )
    }

    override func mouseMoved(with event: NSEvent) {
        entry.pointerMove(runtimeObj: runtime, to: localPoint(for: event), mods: mods(for: event), at: nowSeconds())
        requestRender()
    }

    override func mouseExited(with event: NSEvent) {
        entry.pointerExit(runtimeObj: runtime, at: nowSeconds())
        requestRender()
    }

    override func mouseDragged(with event: NSEvent) {
        entry.pointerMove(runtimeObj: runtime, to: localPoint(for: event), mods: mods(for: event), at: nowSeconds())
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
        entry.pointerDown(runtimeObj: runtime, at: pt, button: .primary, mods: mods(for: event), at: nowSeconds())
        requestRender()
    }

    override func mouseUp(with event: NSEvent) {
        entry.pointerUp(runtimeObj: runtime, at: localPoint(for: event), button: .primary, mods: mods(for: event), at: nowSeconds())
        requestRender()
    }

    override func rightMouseDown(with event: NSEvent) {
        entry.pointerDown(runtimeObj: runtime, at: localPoint(for: event), button: .secondary, mods: mods(for: event), at: nowSeconds())
        requestRender()
    }

    override func rightMouseUp(with event: NSEvent) {
        entry.pointerUp(runtimeObj: runtime, at: localPoint(for: event), button: .secondary, mods: mods(for: event), at: nowSeconds())
        requestRender()
    }

    override func scrollWheel(with event: NSEvent) {
        let mult: Float = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
        let wev = WheelEvent(
            dx: Float(event.scrollingDeltaX) * mult,
            dy: Float(event.scrollingDeltaY) * mult,
            precise: event.hasPreciseScrollingDeltas,
            mods: mods(for: event)
        )
        entry.wheel(runtimeObj: runtime, event: wev, at: localPoint(for: event), now: nowSeconds())
        requestRender()
    }

    override func keyDown(with event: NSEvent) {
        let m = mods(for: event)
        let key: Key
        switch event.keyCode {
        case 36, 76: key = .enter
        case 48: key = .tab
        case 53: key = .escape
        case 51: key = .backspace
        case 117: key = .delete
        case 49: key = .space
        case 123: key = .arrowLeft
        case 124: key = .arrowRight
        case 126: key = .arrowUp
        case 125: key = .arrowDown
        case 115: key = .home
        case 119: key = .end
        case 116: key = .pageUp
        case 121: key = .pageDown
        default:
            let chars = event.characters ?? ""
            let ign = event.charactersIgnoringModifiers ?? chars
            if m.cmd, ign.count == 1, let ch = ign.lowercased().first {
                key = .command(ch)
            } else if !chars.isEmpty {
                key = .text(chars)
            } else {
                return
            }
        }
        _ = entry.keyDown(runtimeObj: runtime, event: KeyEvent(key: key, mods: m), at: nowSeconds())
        requestRender()
    }
}

/// Multi-window AppKit event loop coordinator (`crates/rune/src/window.rs`).
@MainActor
public final class RuneMultiWindowHost: NSObject, NSApplicationDelegate {
    private var slots: [HostedWindowSlot] = []
    private let runOptions: RuneRunOptions
    private let parsed: ToolingArgs

    private init(runOptions: RuneRunOptions, parsed: ToolingArgs) {
        self.runOptions = runOptions
        self.parsed = parsed
        super.init()
    }

    public static func run(
        _ windows: [AnyRuneWindowSpec],
        options: RuneRunOptions = RuneRunOptions(),
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

        if !options.accessory {
            app.activate(ignoringOtherApps: true)
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
        let renderer = try MetalRenderer()
        let window = RuneMacWindowConfig.makeWindow(
            title: specEntry.title,
            size: specEntry.size,
            minSize: specEntry.minSize,
            chrome: specEntry.chrome,
            titlebar: specEntry.titlebar,
            options: specEntry.options,
            macos: specEntry.macosWindow,
            openAs: specEntry.openAs
        )
        let respectSysDark = parsed.darkOverride == nil && specEntry.darkOverride == nil
        let view = RuneHostedMetalView(
            frame: NSRect(x: 0, y: 0, width: CGFloat(specEntry.size.x), height: CGFloat(specEntry.size.y)),
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
        _ = RuneMacWindowConfig.syncChrome(
            window: window,
            chrome: specEntry.chrome,
            titlebar: specEntry.titlebar
        )
        slot.fullScreenWatch = FullScreenWatch(window: window) { [weak window, weak specEntry, weak view] in
            guard let window, let specEntry else { return }
            _ = RuneMacWindowConfig.syncChrome(
                window: window,
                chrome: specEntry.chrome,
                titlebar: specEntry.titlebar
            )
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
            if specEntry.inactive || specEntry.macosWindow.nonactivatingPanel {
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
        _ windows: [AnyRuneWindowSpec],
        options: RuneRunOptions = RuneRunOptions(),
        arguments: [String]? = nil
    ) throws {
        try RuneMultiWindow.runWindows(windows, options: options, arguments: arguments)
    }
}
#endif
