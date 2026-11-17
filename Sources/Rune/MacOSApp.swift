import Foundation
import RuneMotion
import RuneRef

#if os(macOS)
import AppKit
import QuartzCore

/// macOS AppKit + Metal application host called by `RuneApp.run(spec)`.
public enum MacOSApp {
    @MainActor
    public static func run<State>(_ spec: AppSpec<State>, parsed: ToolingArgs) throws {
        var wrapped = App<State>(
            title: spec.title,
            size: spec.size,
            minSize: spec.minSize,
            dark: spec.dark,
            state: spec.makeState(),
            view: spec.view
        )
        wrapped.scenes = spec.scenes
        wrapped.fontData = spec.fonts
        wrapped.fontFamilies = spec.families
        wrapped.setupHook = spec.setup
        wrapped.pollHook = spec.poll
        wrapped.onKeyHook = spec.onKey
        wrapped.srgbBlendEnabled = spec.srgbBlend
        try run(wrapped, parsed: parsed, onFileDrop: spec.onFileDrop, onFileDropPhase: spec.onFileDropPhase)
    }

    @MainActor
    public static func run<State>(_ appBuilder: App<State>, parsed: ToolingArgs) throws {
        try run(appBuilder, parsed: parsed, onFileDrop: nil, onFileDropPhase: nil)
    }

    @MainActor
    private static func run<State>(
        _ appBuilder: App<State>,
        parsed: ToolingArgs,
        onFileDrop: ((inout State, [URL], inout Tx) -> Void)?,
        onFileDropPhase: ((inout State, FileDropPhase, inout Tx) -> Void)?
    ) throws {
        ReadySignal.runStarts()
        RelaunchController.waitForPrevious()
        MediaPlaybackGate.enable()
        HeadlessRunner.registerFonts(appBuilder.fontData)

        var initialState = appBuilder.makeState()
        var initTx = Tx()
        if let sceneName = parsed.sceneName, let applyScene = appBuilder.scenes[sceneName] {
            applyScene(&initialState, &initTx)
        }

        let vp = parsed.viewportOverride ?? appBuilder.size
        // `RUNE_OPEN_INACTIVE`: a tool's launch (an accessibility probe, a capture) leaves the
        // user's focus and keyboard where they are, as `App::open_inactive` does (#962).
        let openInactive = OpenInactiveLaunch.openInactive(app: appBuilder.isOpenInactive) || appBuilder.macosWindowValue.nonactivatingPanel
        let app = NSApplication.shared
        app.setActivationPolicy(appBuilder.isAccessory ? .accessory : .regular)
        if !appBuilder.isAccessory {
            _ = RuneDefaultMacMenus.ensure(app)
            if appBuilder.usesStandardMenus {
                RuneDefaultMacMenus.addStandardMenus(app)
            }
        }

        let respectSystemAppearance = (parsed.darkOverride == nil && appBuilder.dark == nil)
        let sysDark: Bool = {
            if let d = parsed.darkOverride { return d }
            if let d = appBuilder.dark { return d }
            return app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }()

        let waker = Waker()
        let runtime = Runtime<State>(
            state: initialState,
            viewport: vp,
            pixelScale: Float(NSScreen.main?.backingScaleFactor ?? 2.0),
            systemDark: sysDark,
            reducedMotion: parsed.reducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            waker: waker,
            onKey: appBuilder.onKeyHook,
            view: appBuilder.view
        )
        runtime.windowTitle = appBuilder.title
        runtime.recordEvents = false
        runtime.urlOpener.headless = false
        runtime.srgbBlend = appBuilder.srgbBlendEnabled
        runtime.fontSmoothing = appBuilder.fontSmoothingMode
        runtime.poll = appBuilder.pollHook
        runtime.onFocus = appBuilder.onFocusHook
        runtime.onModifiers = appBuilder.onModifiersHook
        runtime.onVisibility = appBuilder.onVisibilityHook
        runtime.onIme = appBuilder.onImeHook
        runtime.onClose = appBuilder.onCloseHook
        runtime.onQuit = appBuilder.onQuitHook
        runtime.turnScope = appBuilder.turnScopeHook
        runtime.onReopen = appBuilder.onReopenHook
        runtime.onOpenUrl = appBuilder.onOpenUrlHook
        runtime.onAppFileDrop = onFileDrop
        runtime.onFileDrop = onFileDropPhase
        runtime.tabVisitsControls = appBuilder.tabVisitsControlsEnabled
        runtime.nativeHelp = true
        runtime.fitHeight = appBuilder.isFitContentHeight
        runtime.readSystemContrastSettings()
        runtime.applyTx(initTx, at: 0.0, markDirtyIfNotLiveOnly: false)
        if let pg = appBuilder.playgroundHost {
            runtime.playgroundHost = pg
        }
        _ = try PlaygroundAttach.attach(
            runtime: runtime,
            host: appBuilder.playgroundHost,
            scenes: appBuilder.scenes,
            sceneOrder: appBuilder.sceneOrder,
            makeState: appBuilder.makeState,
            appId: appBuilder.title,
            open: parsed.playgroundName,
            openRequested: parsed.hasPlayground,
            variant: parsed.playgroundVariant,
            windowed: true
        )

        let reports = (appBuilder.onFrameEncodedHook != nil || appBuilder.onFrameDrawnHook != nil || appBuilder.onFrameInspectHook != nil)
            ? FrameReports<State>(
                onFrameEncoded: appBuilder.onFrameEncodedHook,
                onFrameDrawn: appBuilder.onFrameDrawnHook,
                onInspectDrawn: appBuilder.onFrameInspectHook
            )
            : nil
        let meter = SurfaceMeter(name: appBuilder.title)

        let opts = appBuilder.windowOptionsValue
        let initiallyHidden = appBuilder.isWindowless || !opts.visible
        let launcher = appBuilder.macosWindowValue.launcher
        let appMin = appBuilder.minSize.map { ($0.x, $0.y) }
        let hostMin = appBuilder.isFitContentHeight ? opts.fitMinSize(appMin: appMin) : appMin
        let (minSize, maxSize) = opts.sizeLimits(appMin: hostMin)
        let window = RuneMacWindowConfig.makeWindow(
            title: appBuilder.title, size: vp, minSize: hostMin.map { Vec2($0.0, $0.1) },
            chrome: appBuilder.chromeStyle, titlebar: appBuilder.customTitlebar,
            options: opts, macos: appBuilder.macosWindowValue, openAs: .normal
        )
        let renderer = try MetalRenderer(device: MetalAdapterPicker.forScreen(window.screen))
        DisplayGpuAdapter(backend: .metal, device: renderer.device.name).reportIfRequested()
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        let viewport = Vec2(Float(contentSize.width), Float(contentSize.height))
        if vp != viewport || runtime.pixelScale != Float(window.backingScaleFactor) {
            runtime.setViewport(viewport, pixelScale: Float(window.backingScaleFactor))
        }

        let appShared = appBuilder.sharedHandle.shared
        let queueFrame: @MainActor @Sendable (WindowFrameRequest) -> Void = { [weak runtime] request in
            runtime?.queueWindowHandleFrame(request)
            waker.wake()
        }
        let setTitle: @MainActor @Sendable (String) -> Void = { [weak window, weak runtime] title in
            runtime?.windowTitle = title
            window?.title = title
        }
        let windowHandle = WindowHandle(
            title: appBuilder.title,
            isVisible: !initiallyHidden,
            position: opts.position.map { Vec2(Float($0.0), Float($0.1)) },
            onClose: { [weak window] in Task { @MainActor in window?.close() } },
            onMinimize: { [weak window] in Task { @MainActor in RuneMacWindowConfig.minimize(window, launcher: launcher) } },
            onFocus: { [weak window] in Task { @MainActor in window?.makeKeyAndOrderFront(nil) } },
            onShow: { appShared.requestShow() },
            onHide: { appShared.requestHide() },
            onSetTitle: { title in Task { @MainActor in setTitle(title) } },
            onSetPosition: { [weak window] pt in
                Task { @MainActor in
                    MacOSWindowOrigin.setPosition(of: window, x: CGFloat(pt.x), y: CGFloat(pt.y))
                }
            },
            onFrame: { request in Task { @MainActor in queueFrame(request) } },
            onPlace: { [weak window] req in
                Task { @MainActor in
                    guard let w = window else { return }
                    if let sz = req.size {
                        w.setContentSize(NSSize(width: CGFloat(sz.x), height: CGFloat(sz.y)))
                    }
                    if let pos = req.position {
                        MacOSWindowOrigin.setPosition(of: w, x: CGFloat(pos.x), y: CGFloat(pos.y))
                    }
                    if req.activate {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        w.makeKeyAndOrderFront(nil)
                    } else {
                        w.orderFront(nil)
                    }
                }
            }
        )

        windowHandle.attachPlacementProvider(RuneMacWindowConfig.placementProvider(for: window))
        defer { windowHandle.unbind() }

        AppMenuBridge.attach(appBuilder.menuItems, to: appShared)
        defer {
            AppMenuBridge.markRunning(appShared, running: false, headless: false)
            RuneNativeMenuHost.shared.clear()
        }
        let shortcutGuard = ShortcutGuard.attach(shared: appShared, wake: waker, headless: false)
        defer { shortcutGuard.close() }

        let nativeTrace = try NativeWindowTrace(args: parsed, recordsDrawables: true)
        let hostView = RuneMetalHostView(
            frame: NSRect(x: 0, y: 0, width: CGFloat(viewport.x), height: CGFloat(viewport.y)),
            runtime: runtime,
            renderer: renderer,
            timeScale: parsed.timeScale,
            respectSystemAppearance: respectSystemAppearance,
            compositor: appBuilder.compositorValue,
            appShared: appShared,
            shortcutGuard: shortcutGuard,
            reports: reports,
            nativeTrace: nativeTrace,
            surfaceMeter: meter,
            devStatsReceiver: appBuilder.devStatsReceiver,
            windowHandle: windowHandle,
            minWindowSize: minSize,
            maxWindowSize: maxSize,
            onReady: appBuilder.onReadyHook,
            launcher: launcher,
            chrome: appBuilder.chromeStyle,
            titlebar: (appBuilder.chromeStyle.borderless || opts.borderless) ? nil : appBuilder.customTitlebar
        )

        let windowlessDriver = MacOSWindowlessDriver<State>(
            initiallyHidden: initiallyHidden,
            startAt: CACurrentMediaTime(),
            timeScale: parsed.timeScale,
            shared: appBuilder.sharedHandle.shared,
            runtime: runtime,
            shortcutGuard: shortcutGuard,
            applyHiddenShell: { [weak window] in
                runtime.applyMacShellRequests(to: window, launcher: launcher)
            },
            applyPendingFrame: { [weak hostView] in
                guard let hostView else { return }
                hostView.applyWindowFrameRequest(at: hostView.currentElapsedTime())
            },
            onShowWindow: { [weak window, weak hostView] in
                guard let window, let hostView else { return }
                windowHandle.updateVisibility(true)
                if openInactive {
                    // Unfocused (`App::open_inactive`, `RUNE_OPEN_INACTIVE`): ordered front without
                    // becoming key or activating the app (`platform/macos.rs` `show_without_focus`).
                    window.orderFrontRegardless()
                } else {
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(hostView)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                if appBuilder.openAs.isMaximized {
                    window.zoom(nil)
                }
                if appBuilder.openAs.isFullScreen {
                    window.toggleFullScreen(nil)
                }
                hostView.requestRender()
            }
        )

        let shortcutBridge = MacOSHostShortcutBridge()
        if appBuilder.globalShortcuts.isEmpty {
            shortcutBridge.sync(registry: runtime.shortcutRegistry)
        }
        let systemObserver = MacOSSystemObserver { [weak runtime, weak hostView] in
            guard let runtime else { return }
            // Scroller style, system colours, or the workspace's accessibility display options
            // (`NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification`): reduced motion,
            // the contrast theme and Increase Contrast are read again at once (#980).
            runtime.readSystemAccessibilitySettings(forceReducedMotion: parsed.reducedMotion)
            runtime.markNeedsCommit()
            hostView?.requestRender()
        }

        let delegate = RuneAppDelegate(
            keepRunning: appBuilder.keepsRunning || appBuilder.isWindowless,
            onFocusChange: { [weak hostView] focused in
                // `WindowEvent::Focused(focused)`, gained or lost: reduced motion, the contrast
                // theme and Increase Contrast are read again (`window/events.rs`).
                runtime.readSystemAccessibilitySettings(forceReducedMotion: parsed.reducedMotion)
                runtime.dispatchFocus(focused, at: hostView?.currentElapsedTime() ?? 0.0)
                if focused {
                    RuneStandardMenuRouter.setActiveKeyDispatcher {
                        { ev in
                            hostView?.dispatchNativeKeyEvent(ev) ?? false
                        }
                    }
                }
                hostView?.requestRender()
            },
            onShouldClose: { [weak hostView] in
                runtime.dispatchClose(at: hostView?.currentElapsedTime() ?? 0.0)
            },
            onClose: {
                hostView.cancelPreparedText()
                hostView.stopTimer()
                hostView.cancelActiveModals()
                windowHandle.updateVisibility(false)
                appBuilder.sharedHandle.shared.setVisible(false)
                if !(appBuilder.keepsRunning || appBuilder.isWindowless) && NSApplication.shared.windows.filter(\.isVisible).count <= 1 {
                    let after: QuitAfter = runtime.relaunchRequested ? .relaunch : .exit
                    _ = QuitLifecycle.send(.start(ending: false, after: after))
                }
            },
            onTerminate: {
                _ = systemObserver
                RuneStartup.started { try nativeTrace?.finish() }
                shortcutGuard.close()
                shortcutBridge.clear()
                windowlessDriver.stop()
                hostView.stopTimer()
                hostView.cancelActiveModals()
                runtime.dispatchQuit(at: hostView.currentElapsedTime())
                QuitLifecycle.runQuitHooksIfOwed()
                hostView.cancelPreparedText()
                ReadySignal.clear()
                if let fastHook = QuitLifecycle.activeFastExitHook() {
                    QuitLifecycle.endFast(fastHook)
                }
            },
            onReopen: { hasVisible in
                runtime.dispatchReopen(hasVisibleWindows: hasVisible, at: hostView.currentElapsedTime())
            },
            onOpenUrl: { url in
                runtime.dispatchOpenUrl(url, at: hostView.currentElapsedTime())
            }
        )
        app.delegate = delegate
        JumpListStore.installDockMenuIfReady()
        MacOSQuitHook.install()
        window.delegate = delegate
        RuneMaterialHost.install(hostView, in: window)
        RuneWindowShape.applyCorners(to: window, options: appBuilder.macosWindowValue, transparent: opts.transparent, borderless: opts.borderless || appBuilder.chromeStyle.borderless)
        RuneDragRegions.ownWindowDragging(window: window, chrome: appBuilder.chromeStyle)
        if opts.position == nil { window.center() }
        hostView.attachChromeSync()

        appBuilder.sharedHandle.shared.setWaker(waker)
        appBuilder.sharedHandle.shared.setVisible(windowlessDriver.isWindowShown)
        appBuilder.onWindowHook?(windowHandle)

        RuneStandardMenuRouter.setActiveKeyDispatcher { [weak hostView] in
            { [weak hostView] ev in
                hostView?.dispatchNativeKeyEvent(ev) ?? false
            }
        }

        waker.setCallback { [weak hostView, weak windowlessDriver] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let driver = windowlessDriver, !driver.isWindowShown {
                        driver.pump()
                    } else {
                        hostView?.requestRender()
                    }
                }
            }
        }
        appBuilder.setupHook?(waker)

        if initiallyHidden {
            ReadySignal.ready()
            windowlessDriver.start()
        } else {
            if openInactive {
                // Unfocused (`App::open_inactive`, `RUNE_OPEN_INACTIVE`): ordered front without
                // becoming key or activating the app (`platform/macos.rs` `show_without_focus`).
                window.orderFrontRegardless()
            } else {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(hostView)
                if OpenInactiveLaunch.activatesAtLaunch(accessory: appBuilder.isAccessory) {
                    app.activate(ignoringOtherApps: true)
                }
            }
            if appBuilder.openAs.isMaximized {
                window.zoom(nil)
            }
            if appBuilder.openAs.isFullScreen {
                window.toggleFullScreen(nil)
            }
        }

        let overlays = appBuilder.createAttachedOverlays()
        withExtendedLifetime((delegate, overlays)) {
            app.run()
        }
        try nativeTrace?.finish()
        windowlessDriver.stop()
        QuitLifecycle.finishOrderlyExit()
    }
}

@MainActor
private final class RuneAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, RuneDockJumpReceiver {
    private let keepRunning: Bool
    private let onFocusChange: (Bool) -> Void
    private let onShouldClose: () -> Bool
    private let onClose: () -> Void
    private let onTerminate: () -> Void
    private let onReopen: (Bool) -> Bool
    private let onOpenUrl: (String) -> Void

    init(
        keepRunning: Bool = false,
        onFocusChange: @escaping (Bool) -> Void,
        onShouldClose: @escaping () -> Bool = { true },
        onClose: @escaping () -> Void,
        onTerminate: @escaping () -> Void = {},
        onReopen: @escaping (Bool) -> Bool = { _ in false },
        onOpenUrl: @escaping (String) -> Void = { _ in }
    ) {
        self.keepRunning = keepRunning
        self.onFocusChange = onFocusChange
        self.onShouldClose = onShouldClose
        self.onClose = onClose
        self.onTerminate = onTerminate
        self.onReopen = onReopen
        self.onOpenUrl = onOpenUrl
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !keepRunning
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !onReopen(flag)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            onOpenUrl(url.absoluteString)
        }
    }

    func openDockArgument(_ argument: String) {
        onOpenUrl(argument)
    }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onShouldClose()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = QuitLifecycle.send(.start(ending: false, after: .exit))
        return .terminateNow
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onFocusChange(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        onFocusChange(false)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

@MainActor
internal final class RuneMetalHostView<State>: NSView, @MainActor NSTextInputClient {
    private let runtime: Runtime<State>
    private let renderer: MetalRenderer
    private let metalLayer = CAMetalLayer()
    private var launchDrawables = MacOSLaunchDrawables()
    private var settledFrame: SettledWindowFrame?
    private let startTime = CACurrentMediaTime()
    private let timeScale: Double
    private let respectSystemAppearance: Bool
    private let compositor: AnyCompositor<State>?
    private let appShared: AppShared<State>?
    private let shortcutGuard: ShortcutGuard?
    private let reports: FrameReports<State>?
    private let nativeTrace: NativeWindowTrace?
    private let loopActivity: AppleSurfaceLoopObserver?
    private let surfaceMeter: SurfaceMeter?
    private let devStatsReceiver: ((SurfaceStats) -> Void)?
    private let windowHandle: WindowHandle?
    private let onReady: ((WindowHandle) -> Void)?
    private var didFireReady: Bool = false
    private var didRunOnReady: Bool = false
    private let chromeStyle: Chrome
    private let customTitlebar: Titlebar?
    private let launcher: Bool
    private var chromeWatch: WindowChromeWatch?
    /// Whether the shown window can draw, and what covering it runs (`window/sight.rs`, #995).
    private var coverDriver = CoveredWindowDriver()
    private var coverWatch: WindowCoverWatch?
    private var lastFrameTime: Double = 0.0
    private lazy var displayLinkDriver: MacOSDisplayLinkDriver = {
        let driver = MacOSDisplayLinkDriver { [weak self] in self?.renderTick() }
        driver.deadlineWoke = { [weak self] in self?.surfaceMeter?.noteDeadlineWake() }
        return driver
    }()
    private var textIdleObserver: AppleTextIdleObserver?
    private var trackingAreaRef: NSTrackingArea?
    private var didSignalReady = false
    private let popupPresenter = MacOSPopupMenuPresenter()
    private let fileDialogPresenter = MacOSFileDialogPresenter()
    private let dragOutCoordinator = MacOSDragOutCoordinator()
    private var materialHost: RuneMaterialHost?
    private lazy var windowRest = AppleWindowRest { [weak self] all in
        guard let self else { return }
        runtime.rest(at: nowSeconds())
        renderer.giveBackForWindowRest(all: all)
    }
    private let accessibilityHost = MacOSAccessibilityHost()
    private lazy var textInputBridge: MacOSTextInputBridge = MacOSTextInputBridge { [weak self] imeEvent in
        guard let self else { return }
        let dispatched = self.arrived(.keyPress, nil) {
            self.runtime.dispatchImeEvent(imeEvent, recordReleaseGuard: self.textInputBridge.isTrackingKeyEvent, at: self.nowSeconds())
        }
        if dispatched {
            self.requestRender()
        }
    }
    private var lastAppliedCursor: Cursor = .default
    private var didSyncToolTips = false
    /// The accessibility tree must go out again although no commit changed it: held announcer
    /// words, or a client that just attached (`A11yTree::held` / `full`, #980).
    private var a11yFollowUp = false
    private let toolTipOwner = MacOSToolTipOwner()
    private let windowFrameDriver = MacOSWindowFrameDriver()
    private var originWatch: MacOSWindowOriginWatch?
    private let minWindowSize: (Float, Float)
    private let maxWindowSize: (Float, Float)?
    private var appliedMenuRevision: UInt64 = 0
    private let fnKeyMonitor = FnKeyMonitor()
    internal let secureInputClaim = SecureInputClaim(touchOS: true)

    init(
        frame: NSRect,
        runtime: Runtime<State>,
        renderer: MetalRenderer,
        timeScale: Double,
        respectSystemAppearance: Bool,
        compositor: AnyCompositor<State>? = nil,
        appShared: AppShared<State>? = nil,
        shortcutGuard: ShortcutGuard? = nil,
        reports: FrameReports<State>? = nil,
        nativeTrace: NativeWindowTrace? = nil,
        surfaceMeter: SurfaceMeter? = nil,
        devStatsReceiver: ((SurfaceStats) -> Void)? = nil,
        windowHandle: WindowHandle? = nil,
        minWindowSize: (Float, Float) = (WindowOptions.defaultMinSize.x, WindowOptions.defaultMinSize.y),
        maxWindowSize: (Float, Float)? = nil,
        onReady: ((WindowHandle) -> Void)? = nil,
        launcher: Bool = false,
        chrome: Chrome = .standard,
        titlebar: Titlebar? = nil
    ) {
        self.launcher = launcher
        self.chromeStyle = chrome
        self.customTitlebar = titlebar
        self.runtime = runtime
        self.renderer = renderer
        self.timeScale = timeScale
        self.respectSystemAppearance = respectSystemAppearance
        self.compositor = compositor
        self.appShared = appShared
        self.shortcutGuard = shortcutGuard
        self.reports = reports
        self.nativeTrace = nativeTrace
        self.surfaceMeter = surfaceMeter
        self.loopActivity = surfaceMeter.map(AppleSurfaceLoopObserver.init)
        if let surfaceMeter {
            runtime.surfaceMeter = surfaceMeter
            windowHandle?.attachSurfaceMeter(surfaceMeter)
        }
        self.devStatsReceiver = devStatsReceiver
        self.windowHandle = windowHandle
        self.minWindowSize = minWindowSize
        self.maxWindowSize = maxWindowSize
        self.onReady = onReady
        super.init(frame: frame)
        accessibilityHost.onActivate = { [weak self] in
            guard let self else { return }
            let readerRuntime = self.runtime
            self.coverDriver.assistiveClientAttached(readerRuntime)
            if readerRuntime.commitCount == 0 || !self.coverDriver.canDraw {
                self.coverDriver.step(readerRuntime, at: self.nowSeconds())
            }
            self.syncAccessibilityTree()
        }
        self.wantsLayer = true
        launchDrawables.cap(metalLayer)
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = runtime.srgbBlend ? .bgra8Unorm : .bgra8Unorm_srgb
        metalLayer.framebufferOnly = false
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        self.layer = metalLayer
        MacOSMetalLayerSurface.pinContentsTopLeft(metalLayer)
        registerForDraggedTypes(MacOSDropReader.draggedTypes)
        if runtime.boundClipboard == nil {
            runtime.useClipboard(.shared)
        }
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
        syncGeometryAndRender()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncGeometryAndRender()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        displayLinkDriver.cancelPreparedFrame()
        windowFrameDriver.userStartedResizing()
        materialHost?.setLiveResizing(true, mode: MaterialMode.launchMode)
        RuneMaterialHost.syncWindowFrame(moving: false, live: true, host: materialHost, layer: metalLayer)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        materialHost?.setLiveResizing(false, mode: MaterialMode.launchMode)
        RuneMaterialHost.syncWindowFrame(moving: windowFrameDriver.isMoving, live: false, host: materialHost, layer: metalLayer)
    }

    private func syncGeometryAndRender() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if metalLayer.contentsScale != scale || metalLayer.drawableSize != size {
            displayLinkDriver.cancelPreparedFrame()
        }
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = size
        let newVP = Vec2(Float(max(1, bounds.width)), Float(max(1, bounds.height)))
        if windowFrameDriver.isMoving || windowFrameDriver.takeJumpIfMatching(viewport: newVP) {
            runtime.stepViewport(newVP, pixelScale: Float(scale))
        } else {
            runtime.setViewport(newVP, pixelScale: Float(scale))
        }
        // Resized / ScaleFactorChanged re-sync the chrome (`window/events.rs`).
        syncWindowChrome()
        renderTick()
    }

    /// `window/chrome.rs::sync_chrome` for this window's `App::chrome` and `App::titlebar`.
    fileprivate func syncWindowChrome() {
        guard let w = window else { return }
        runtime.syncWindowChrome(window: w, chrome: chromeStyle, titlebar: customTitlebar)
    }

    /// Syncs the chrome now and again on full screen and uncovering (`window/sight.rs`).
    fileprivate func attachChromeSync() {
        guard let w = window else { return }
        syncWindowChrome()
        chromeWatch = WindowChromeWatch(window: w) { [weak self] in
            self?.syncWindowChrome()
            self?.requestRender()
        }
        coverWatch = WindowCoverWatch(window: w) { [weak self] occluded in
            self?.coverChanged(occluded: occluded)
        }
    }

    /// The window was covered or uncovered, minimising included (`Host::set_cover`).
    private func coverChanged(occluded: Bool) {
        switch coverDriver.setOccluded(occluded, runtime: runtime, at: nowSeconds()) {
        case .rest:
            surfaceMeter?.setPacing(.idle)
            windowRest.step(.unseen)
            sleepUntilRuntimeWake()
        case .redraw:
            requestRender()
        case .none:
            if !occluded && !displayLinkDriver.isRunning { sleepUntilRuntimeWake() }
        }
    }

    /// A wake, due timer or redraw for a shown window that can't draw (`covered_step`): `poll`,
    /// due timers and queued input run, and while an assistive client reads the window what
    /// changed builds at once for it (`Runtime::covered_wake`); nothing draws or moves.
    private func coveredTick(at t: Double) {
        stopTimer()
        let committed = coverDriver.step(runtime, at: t)
        // `on_ready` starts an app's live work, so it can't wait on a drawable: the first frame
        // skipped for being off screen runs it; the window isn't ready until it draws
        // (`FirstFrame::skipped`).
        runOnReadyOnce()
        // What the step asked of the shell goes out now (`self.shell(event_loop)`).
        if runtime.applyMacShellRequests(to: window, launcher: launcher) { return }
        applyWindowFrameRequest(at: t)
        pumpPlatformActions()
        // The reader gets the tree the covered step committed, held words or an attaching
        // reader's follow-up, and words said since the last update, as a drawn frame's stamp.
        syncPlatformBridges(treeCommitted: committed)
        sleepUntilRuntimeWake()
    }

    /// `App::on_ready`, once per window: at its first drawn frame or first covered one.
    private func runOnReadyOnce() {
        guard !didRunOnReady else { return }
        didRunOnReady = true
        if let wh = windowHandle {
            onReady?(wh)
        }
    }

    /// A `Tx.setWindowFrame` the runtime holds goes to the window (`window/frame.rs`).
    fileprivate func applyWindowFrameRequest(at t: Double) {
        guard let frameReq = runtime.takeWindowFrameRequest(), let w = window else { return }
        let scale = Float(w.backingScaleFactor)
        windowFrameDriver.applyRequest(
            frameReq,
            window: w,
            now: t,
            minSize: minWindowSize,
            maxSize: maxWindowSize,
            scale: scale,
            painting: w.isVisible && !w.isMiniaturized && coverDriver.canDraw
        ) { [weak self] vp, sc in
            self?.runtime.stepViewport(vp, pixelScale: sc)
        }
    }

    func stopTimer() {
        displayLinkDriver.stop()
        RuneMaterialHost.syncWindowFrame(moving: false, live: inLiveResize, host: materialHost, layer: metalLayer)
        if let w = window {
            windowFrameDriver.landFrame(window: w)
        }
    }

    fileprivate func cancelPreparedText() {
        windowRest.cancel()
        textIdleObserver = nil
        runtime.cancelPreparedText()
    }

    private func sleepUntilRuntimeWake() {
        guard let window, window.isVisible || window.isMiniaturized else { stopTimer(); return }
        if windowFrameDriver.isMoving {
            RuneMaterialHost.syncWindowFrame(moving: false, live: inLiveResize, host: materialHost, layer: metalLayer)
        }
        windowFrameDriver.landFrame(window: window)
        let deadline = runtime.windowWakeDeadline(covered: !coverDriver.canDraw)
        displayLinkDriver.sleep(until: deadline, now: nowSeconds(), timeScale: timeScale)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard respectSystemAppearance else { return }
        let name = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        runtime.systemDark = (name == .darkAqua)
        renderTick()
    }

    func requestRender() {
        renderTick()
    }

    private func nowSeconds() -> Double {
        (CACurrentMediaTime() - startTime) * timeScale
    }

    fileprivate func currentElapsedTime() -> Double {
        nowSeconds()
    }

    private func renderTick() {
        guard bounds.width > 0 && bounds.height > 0 else { return }
        guard nativeTrace?.reachedLimit != true else { return }
        let paced = window?.isVisible == true && coverDriver.canDraw && !inLiveResize
        let opportunity = displayLinkDriver.beginFrame(in: self, paced: paced)
        guard let targetTimestamp = opportunity.target else { return }
        defer { displayLinkDriver.endFrame() }
        let t = max(lastFrameTime, ((targetTimestamp ?? CACurrentMediaTime()) - startTime) * timeScale)
        let dt = Float(max(0.0, t - lastFrameTime))
        lastFrameTime = t

        applyWindowFrameRequest(at: t)
        let movingFrame = windowFrameDriver.isMoving
        if movingFrame {
            RuneMaterialHost.syncWindowFrame(moving: true, live: inLiveResize, host: materialHost, layer: metalLayer)
        }
        var finishingAfterPreparation = false
        func finishWindowMotion() {
            if movingFrame && !windowFrameDriver.isMoving {
                RuneMaterialHost.syncWindowFrame(moving: false, live: inLiveResize, host: materialHost, layer: metalLayer)
            }
        }
        defer { if !finishingAfterPreparation { finishWindowMotion() } }
        if let w = window {
            let scale = Float(w.backingScaleFactor)
            _ = windowFrameDriver.step(window: w, now: t, scale: scale, resting: runtime.windowResting) { [weak self] vp, sc in
                self?.runtime.stepViewport(vp, pixelScale: sc)
            }
        }
        runtime.windowResting = !(inLiveResize || windowFrameDriver.isMoving)

        shortcutGuard?.drain()
        let drained: AppDrainedRequests<State>? = if let appShared {
            if let shortcutGuard {
                shortcutGuard.withReceiving {
                    appShared.applyStateUpdates(to: runtime, at: t)
                }
            } else {
                appShared.applyStateUpdates(to: runtime, at: t)
            }
        } else {
            nil
        }
        if let drained {
            applyDrainedRequests(drained)
        }
        syncNativeMenus()
        if !coverDriver.canDraw {
            surfaceMeter?.setPacing(.idle)
            surfaceMeter?.skipped()
            coveredTick(at: t)
            return
        }

        let desiredFmt: MTLPixelFormat = runtime.srgbBlend ? .bgra8Unorm : .bgra8Unorm_srgb
        if metalLayer.pixelFormat != desiredFmt {
            metalLayer.pixelFormat = desiredFmt
        }

        let materialMode = MaterialMode.launchMode
        if let w = window {
            runtime.nativeMaterials = (!w.isOpaque && materialMode != .fallback)
        } else {
            runtime.nativeMaterials = false
        }

        let commitsBefore = runtime.viewCommitCount
        let updateStart = CACurrentMediaTime()
        nativeTrace?.begin(runtime, now: updateStart,
                           refreshHz: displayLinkDriver.refreshHz)
        var renderFrame = renderer.frame(runtime, at: t)
        if !metalLayer.isOpaque { renderFrame.clearColor = .zero }
        let updateMs = (CACurrentMediaTime() - updateStart) * 1000.0
        // A new `Cx::set_titlebar` / `Cx::titlebar_height` moves the traffic lights and the band
        // (`window/lifecycle.rs` `take_titlebar_changed`); changed insets re-run the view next.
        if runtime.takeTitlebarChanged(), window != nil {
            syncWindowChrome()
            DispatchQueue.main.async { [weak self] in self?.requestRender() }
        }


        if runtime.applyMacShellRequests(to: window, launcher: launcher) { return }

        applyWindowFrameRequest(at: t)
        func needsFrame() -> Bool {
            runtime.windowHasFrameWork || nativeTrace?.keepsDrawing == true ||
                (timeScale > 0 && (runtime.isAnimating || compositor?.isAnimating == true || windowFrameDriver.isMoving))
        }
        let needsNext = needsFrame()
        let wakeAt = needsNext ? nil : runtime.windowWakeDeadline(covered: false)
        let timerWantsFrame = paced && timeScale > 0 && wakeAt.map { $0 <= t + timeScale / displayLinkDriver.refreshHz } == true
        let continuous = needsNext || timerWantsFrame
        let canRest = wakeAt != nil && !continuous && paced && !runtime.nativeMaterials && nativeTrace == nil &&
            compositor?.drawsOwnContent != true
        let restingFrame = canRest ? SettledWindowFrame(renderFrame, scale: runtime.pixelScale) : nil
        surfaceMeter?.redraw(paced: targetTimestamp != nil || displayLinkDriver.isDeadlineTick)
        if displayLinkDriver.isDeadlineTick, let restingFrame, settledFrame == restingFrame {
            reports?.unchanged(presentsAt: targetTimestamp)
            pumpPlatformActions()
            syncPlatformBridges(treeCommitted: runtime.viewCommitCount != commitsBefore)
            sleepUntilRuntimeWake()
            surfaceMeter?.setPacing(displayLinkDriver.pacing)
            return
        }
        settledFrame = nil

        let committed = runtime.viewCommitCount != commitsBefore
        finishingAfterPreparation = true
        displayLinkDriver.finishPreparation(onCancel: finishWindowMotion) { [self] in
            defer { finishWindowMotion() }
            guard !paced || (window?.isVisible == true && coverDriver.canDraw) else { return }
            var tracedDrawable: UInt64?
            let acquiredDrawable = metalLayer.nextDrawable()
            let drawCount = acquiredDrawable.flatMap { drawable in
                tracedDrawable = nativeTrace?.track(drawable)
                return RuneMaterialHost.present(host: &materialHost, draws: renderFrame.materials, in: self, layer: metalLayer,
                                         scale: metalLayer.contentsScale, mode: materialMode) { synced in
                    renderer.present(frame: renderFrame, drawable: drawable, compositor: compositor,
                                     runtime: runtime, dt: dt, updateMilliseconds: updateMs, synchronized: synced)
                }
            }
            if let drawCount {
                let submitted = CACurrentMediaTime()
                runtime.interactionSubmitted(at: submitted, target: targetTimestamp)
                settledFrame = restingFrame
                nativeTrace?.submitted(runtime, at: submitted, started: updateStart, target: targetTimestamp,
                                       sequence: tracedDrawable, continuous: continuous)
                displayLinkDriver.submitted(at: submitted)
                launchDrawables.submitted(to: metalLayer, visible: window?.isVisible == true, idle: !continuous, at: submitted)
                windowRest.step(.drew(now: ProcessInfo.processInfo.systemUptime, lowMemory: false))
                _ = surfaceMeter?.presented()
                if textIdleObserver == nil { textIdleObserver = AppleTextIdleObserver(runtime: runtime) }
                if !didFireReady {
                    didFireReady = true
                    ReadySignal.ready()
                    runOnReadyOnce()
                }
                reports?.presented(renderFrame, at: t, started: updateStart, updateMs: updateMs, drawCount: drawCount,
                                   committed: committed, runtime: runtime, compositor: compositor,
                                   target: targetTimestamp, refreshHz: displayLinkDriver.refreshHz, submitted: submitted)
                if nativeTrace?.reachedLimit == true {
                    stopTimer()
                    // Leave the view on screen until Metal has reported its final drawables.
                    DispatchQueue.main.async {
                        RuneStartup.started { try self.nativeTrace?.finish() }
                        NSApplication.shared.terminate(nil)
                    }
                    return
                }
            } else {
                if acquiredDrawable == nil { surfaceMeter?.failed(.timeout) }
                reports?.skipped()
            }
            pumpPlatformActions()
            syncPlatformBridges(treeCommitted: runtime.viewCommitCount != commitsBefore)

            // Frame observers and platform callbacks can change the runtime after the draw.
            if continuous || needsFrame() {
                displayLinkDriver.start(in: self)
            } else {
                sleepUntilRuntimeWake()
            }
            surfaceMeter?.setPacing(displayLinkDriver.pacing)
            if let devStatsReceiver, let surfaceMeter { devStatsReceiver(surfaceMeter.currentStats()) }
        }
    }

    internal func syncPlatformBridges(treeCommitted: Bool) {
        let focused = window?.isKeyWindow ?? true
        let imeAllowed = runtime.hasImeTarget && !runtime.hasSecureFocus && focused
        let cancelIme = runtime.consumeImeReset()
        let caretRect = MacOSHostViewHelper.caretScreenRect(caret: runtime.focusedCaretRect(), in: self)
        textInputBridge.sync(
            imeText: imeAllowed ? runtime.focusedImeSnapshot() : nil,
            caretScreenRect: caretRect,
            cancelExisting: cancelIme,
            in: self
        )
        runtime.syncSecureInput(secureInputClaim, windowFocused: window?.isKeyWindow ?? false)

        MacOSHostViewHelper.applyCursor(runtime.currentCursor(), previous: &lastAppliedCursor, in: self)

        if treeCommitted || !didSyncToolTips {
            didSyncToolTips = true
            toolTipOwner.sync(regions: runtime.helpRegionsList(), on: self)
        }
        if accessibilityHost.isActivated,
           treeCommitted || a11yFollowUp || accessibilityHost.announcementChanged(runtime.a11yAnnouncement) {
            syncAccessibilityTree()
        }
    }

    private func syncAccessibilityTree() {
        a11yFollowUp = false
        let snapshot = runtime.nativeAccessibilitySnapshot()
        let held = accessibilityHost.update(tree: snapshot, announcement: runtime.a11yAnnouncement, parentView: self, onSelectText: { [weak self] id, range in
            MacOSHostViewHelper.dispatchAccessibilityRequest { [weak self] in
                guard let self else { return }
                if self.runtime.accessibilitySelectText(id, range: range, at: self.nowSeconds()) { self.requestRender() }
            }
        }, onSetValue: { [weak self] id, value in
            MacOSHostViewHelper.dispatchAccessibilitySetValue(id, value: value) { id, value in
                guard let self else { return }
                if self.runtime.accessibilityAction(id, .setValue, value: value, at: self.nowSeconds()) {
                    self.requestRender()
                }
            }
        }) { [weak self] id, action in
            MacOSHostViewHelper.dispatchAccessibilityAction(id, action: action) { id, action in
                guard let self else { return }
                if self.runtime.performAccessibilityAction(id, action: action, at: self.nowSeconds()) {
                    self.requestRender()
                }
            }
        }
        if held { scheduleAccessibilityFollowUp() }
    }

    /// Recent announcer words held on activation: the runtime stays dirty and the tree
    /// goes out again on the next frame (`a11y_update`'s `self.dirty = true`).
    private func scheduleAccessibilityFollowUp() {
        a11yFollowUp = true
        runtime.markNeedsCommit()
        DispatchQueue.main.async { [weak self] in self?.requestRender() }
    }

    private func syncNativeMenus() {
        guard let appShared else { return }
        let snap = AppMenuBridge.snapshot(for: appShared)
        guard snap.revision != appliedMenuRevision else { return }
        appliedMenuRevision = snap.revision
        if snap.items.isEmpty {
            RuneNativeMenuHost.shared.clear()
            return
        }
        do {
            let revision = snap.revision
            try RuneNativeMenuHost.shared.apply(items: snap.items) { [weak self] itemId in
                guard let self, let shared = self.appShared,
                      AppMenuBridge.fireIfCurrent(id: itemId, revision: revision, for: shared) else { return }
                self.requestRender()
            }
        } catch let err as MenuError {
            AppMenuBridge.recordError(err, for: appShared)
        } catch {
            AppMenuBridge.recordError(.unsupported, for: appShared)
        }
    }

    private func applyDrainedRequests(_ req: AppDrainedRequests<State>) {
        if let dockIcon = req.dockIcon {
            MacOSDockIconApplier.apply(dockIcon)
        }
        if req.quit {
            NSApplication.shared.terminate(nil)
            return
        }
        switch req.window {
        case .close:
            window?.performClose(nil)
            return
        case .open, .show:
            if let pos = req.position {
                MacOSWindowOrigin.setPosition(of: window, x: CGFloat(pos.x), y: CGFloat(pos.y))
            }
            if let place = req.place {
                if let sz = place.size {
                    window?.setContentSize(NSSize(width: CGFloat(sz.x), height: CGFloat(sz.y)))
                }
                if let pos = place.position {
                    MacOSWindowOrigin.setPosition(of: window, x: CGFloat(pos.x), y: CGFloat(pos.y))
                }
            }
            window?.orderFront(nil)
            windowHandle?.updateVisibility(true)
            appShared?.setVisible(true)
        case .hide:
            window?.orderOut(nil)
            windowRest.step(.unseen)
            windowHandle?.updateVisibility(false)
            appShared?.setVisible(false)
        case .none:
            if let pos = req.position {
                MacOSWindowOrigin.setPosition(of: window, x: CGFloat(pos.x), y: CGFloat(pos.y))
            }
            if let place = req.place {
                if let sz = place.size {
                    window?.setContentSize(NSSize(width: CGFloat(sz.x), height: CGFloat(sz.y)))
                }
                if let pos = place.position {
                    MacOSWindowOrigin.setPosition(of: window, x: CGFloat(pos.x), y: CGFloat(pos.y))
                }
            }
        }
        switch req.activation {
        case .activate:
            NSApplication.shared.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        case .focus:
            window?.makeKeyAndOrderFront(nil)
        case .minimize:
            _ = runtime.minimizeStep(.asked)
        case .none:
            break
        }
    }

    private func localPoint(for event: NSEvent) -> Vec2 {
        let p = convert(event.locationInWindow, from: nil)
        return runtime.inputPoint(fromWindow: Vec2(Float(p.x), Float(p.y)))
    }

    private func mods(for event: NSEvent) -> Mods {
        MacOSKeyMapper.mods(for: event)
    }

    /// Dispatches `body` as the platform input `event` of `kind` (else AppKit's current event
    /// when it is that kind), inside the scope holding when it arrived (`input::time::arrived`).
    @discardableResult
    private func arrived<R>(_ kind: HostInputKind, _ event: NSEvent?, _ body: () -> R) -> R {
        // A synchronous input handler can change the scene or its interaction report before submission.
        displayLinkDriver.cancelPreparedFrame()
        return runtime.hostInput(kind, eventTimestamp: MacOSInputEvents.timestamp(kind, event), body)
    }

    override func mouseMoved(with event: NSEvent) {
        arrived(.pointer, event) { runtime.pointerMove(to: localPoint(for: event), mods: mods(for: event), at: nowSeconds()) }
        renderTick()
    }

    override func mouseExited(with event: NSEvent) {
        arrived(.pointer, event) { runtime.pointerExit(at: nowSeconds()) }
        renderTick()
    }

    override func mouseDragged(with event: NSEvent) {
        arrived(.pointer, event) { runtime.pointerMove(to: localPoint(for: event), mods: mods(for: event), at: nowSeconds()) }
        renderTick()
    }

    override func rightMouseDragged(with event: NSEvent) {
        arrived(.pointer, event) { runtime.pointerMove(to: localPoint(for: event), mods: mods(for: event), at: nowSeconds()) }
        renderTick()
    }

    override func otherMouseDragged(with event: NSEvent) {
        arrived(.pointer, event) { runtime.pointerMove(to: localPoint(for: event), mods: mods(for: event), at: nowSeconds()) }
        renderTick()
    }

    override func mouseDown(with event: NSEvent) {
        arrived(.pointer, event) { runtime.pointerDown(at: localPoint(for: event), button: .primary, mods: mods(for: event), at: nowSeconds()) }
        renderTick()
    }

    override func mouseUp(with event: NSEvent) {
        arrived(.pointer, event) { runtime.pointerUp(at: localPoint(for: event), button: .primary, mods: mods(for: event), at: nowSeconds()) }
        renderTick()
    }

    override func rightMouseDown(with event: NSEvent) {
        arrived(.pointer, event) { runtime.pointerDown(at: localPoint(for: event), button: .secondary, mods: mods(for: event), at: nowSeconds()) }
        renderTick()
    }

    override func rightMouseUp(with event: NSEvent) {
        arrived(.pointer, event) { runtime.pointerUp(at: localPoint(for: event), button: .secondary, mods: mods(for: event), at: nowSeconds()) }
        renderTick()
    }

    override func otherMouseDown(with event: NSEvent) {
        arrived(.pointer, event) {
            runtime.pointerDown(
                at: localPoint(for: event),
                button: PointerButton.fromAppKit(buttonNumber: event.buttonNumber),
                mods: mods(for: event),
                at: nowSeconds()
            )
        }
        renderTick()
    }

    override func otherMouseUp(with event: NSEvent) {
        arrived(.pointer, event) {
            runtime.pointerUp(
                at: localPoint(for: event),
                button: PointerButton.fromAppKit(buttonNumber: event.buttonNumber),
                mods: mods(for: event),
                at: nowSeconds()
            )
        }
        renderTick()
    }

    internal static func gesturePhase(from phase: NSEvent.Phase) -> GesturePhase {
        if phase.contains(.began) || phase.contains(.mayBegin) { return .began }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        return .changed
    }

    @discardableResult
    internal func dispatchMagnify(delta: Float, at pt: Vec2, phase: GesturePhase) -> Bool {
        let handled = arrived(.magnify, nil) { runtime.magnify(MagnifyEvent(delta: delta, x: pt.x, y: pt.y, phase: phase), at: pt, now: nowSeconds()) }
        renderTick()
        return handled
    }

    @discardableResult
    internal func dispatchRotate(degrees: Float, at pt: Vec2, phase: GesturePhase) -> Bool {
        let handled = arrived(.rotate, nil) { runtime.rotate(RotateEvent(degrees: degrees, x: pt.x, y: pt.y, phase: phase), at: pt, now: nowSeconds()) }
        renderTick()
        return handled
    }

    @discardableResult
    internal func dispatchSmartMagnify(at pt: Vec2) -> Bool {
        let handled = arrived(.smartMagnify, nil) { runtime.smartMagnify(at: pt, now: nowSeconds()) }
        renderTick()
        return handled
    }

    override func magnify(with event: NSEvent) {
        _ = dispatchMagnify(
            delta: Float(event.magnification),
            at: localPoint(for: event),
            phase: Self.gesturePhase(from: event.phase)
        )
    }

    override func rotate(with event: NSEvent) {
        // NSEvent.rotation and RotateEvent.degrees are both positive counterclockwise.
        _ = dispatchRotate(
            degrees: Float(event.rotation),
            at: localPoint(for: event),
            phase: Self.gesturePhase(from: event.phase)
        )
    }

    override func smartMagnify(with event: NSEvent) {
        _ = dispatchSmartMagnify(at: localPoint(for: event))
    }

    override func scrollWheel(with event: NSEvent) {
        let wev = WheelDistance.appKitEvent(event)
        arrived(.wheel, event) { runtime.wheelFromWindow(wev, at: localPoint(for: event), now: nowSeconds()) }
        renderTick()
    }

    private func makeKeyEvent(from event: NSEvent) -> KeyEvent? {
        let focused = window?.isKeyWindow ?? true
        let optionAsAlt = runtime.hasImeTarget && focused && runtime.effectiveImeOptionAsAlt
        return MacOSKeyMapper.makeKeyEvent(from: event, optionAsAlt: optionAsAlt)
    }

    @discardableResult
    func dispatchKeyEvent(_ ev: KeyEvent, isRepeat: Bool = false, from nsEvent: NSEvent? = nil) -> Bool {
        let handled = arrived(.keyPress, nsEvent) {
            MacOSClipboardSync.dispatchKeyWithSync(ev, runtime: runtime, isRepeat: isRepeat, at: nowSeconds())
        }
        renderTick()
        return handled
    }

    @discardableResult
    func dispatchNativeKeyEvent(_ event: NSEvent) -> Bool {
        guard let kev = makeKeyEvent(from: event) else { return false }
        return dispatchKeyEvent(kev, isRepeat: event.isARepeat, from: event)
    }

    override func keyDown(with event: NSEvent) {
        let focused = window?.isKeyWindow ?? true
        let imeAllowed = runtime.hasImeTarget && !runtime.hasSecureFocus && focused
        let optionAsAlt = imeAllowed && runtime.effectiveImeOptionAsAlt
        if imeAllowed {
            let imeResult = arrived(.keyPress, event) { textInputBridge.processKeyDown(event, in: self, optionAsAlt: optionAsAlt) }
            if imeResult == .handledByIME {
                renderTick()
                return
            }
        }
        _ = dispatchNativeKeyEvent(event)
    }

    override func keyUp(with event: NSEvent) {
        if runtime.hasImeTarget && !runtime.hasSecureFocus && textInputBridge.hasMarkedText() {
            return
        }
        guard let kev = makeKeyEvent(from: event) else { return }
        _ = arrived(.keyRelease, event) { runtime.keyUp(kev, at: nowSeconds()) }
        renderTick()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        originWatch = MacOSWindowOriginWatch(window: window) { [weak runtime] origin in
            if let runtime, runtime.updateMacOSOrigin(origin) { runtime.waker.wake() }
        }
        if let window {
            metalLayer.isOpaque = window.isOpaque
            _ = fnKeyMonitor.start(on: window)
        } else {
            textIdleObserver = nil
            stopTimer()
            fnKeyMonitor.stop()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        arrived(.keyRelease, event) { dispatchFlagsChanged(event) }
        renderTick()
    }

    private func dispatchFlagsChanged(_ event: NSEvent) {
        let now = nowSeconds()
        let fnTransitions = fnKeyMonitor.take()
        if !fnTransitions.isEmpty {
            let currentMods = mods(for: event)
            for fnPressed in fnTransitions {
                _ = runtime.physicalInput(.key(key: .fn, mods: currentMods, pressed: fnPressed, repeat: false), at: now)
                _ = runtime.keyDown(KeyEvent(key: .modifier(.fn, pressed: fnPressed), mods: currentMods), at: now)
            }
        }
        if let mapped = MacOSKeyMapper.modifierKeyEvent(keyCode: event.keyCode, flags: event.modifierFlags) {
            runtime.dispatchModifiers(mapped.mods, at: now)
            if event.keyCode != FnKeyMonitor.keyCodeFn || fnTransitions.isEmpty {
                _ = runtime.keyDown(mapped.event, at: now)
            }
        } else {
            runtime.dispatchModifiers(mods(for: event), at: now)
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
        guard Thread.isMainThread else { return MacOSHostViewHelper.superclassAccessibilityChildren(of: self) }
        return MainActor.assumeIsolated {
            MacOSUnsafeSendableBox(accessibilityHost.accessibilityChildren())
        }.value
    }

    nonisolated override var accessibilityFocusedUIElement: Any? {
        guard Thread.isMainThread else { return super.accessibilityFocusedUIElement }
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

    // MARK: - Standard Menu Bar Responder Selectors (native_menu/standard_macos.rs)

    @objc func undo(_ sender: Any?) { routeStandardAction("undo:") }
    @objc func redo(_ sender: Any?) { routeStandardAction("redo:") }
    @objc func cut(_ sender: Any?) { routeStandardAction("cut:") }
    @objc func copy(_ sender: Any?) { routeStandardAction("copy:") }
    @objc func paste(_ sender: Any?) { routeStandardAction("paste:") }
    override func selectAll(_ sender: Any?) { routeStandardAction("selectAll:") }
    @objc func performMiniaturize(_ sender: Any?) { routeStandardAction("performMiniaturize:") }
    @objc func performClose(_ sender: Any?) { routeStandardAction("performClose:") }

    private func routeStandardAction(_ selector: String) {
        RuneStandardMenuRouter.performStandardAction(
            selector: selector,
            window: window,
            dispatchKeyEvent: { [weak self] ev in self?.dispatchKeyEvent(ev) ?? false },
            dispatchNativeEvent: { [weak self] ev in self?.dispatchNativeKeyEvent(ev) ?? false }
        )
    }

    func cancelActiveModals() {
        popupPresenter.cancel()
        fileDialogPresenter.cancel()
        runtime.cancelPopups()
        runtime.cancelFileDialogs(at: nowSeconds())
    }

    private func pumpPlatformActions() {
        // 1. Outbound OS drag session
        if let dragStart = runtime.takeDragOutStart() {
            dragOutCoordinator.start(dragStart, in: self) { [weak self] outcome in
                guard let self else { return }
                self.runtime.finishDragOut(outcome, at: self.nowSeconds())
                self.requestRender()
            }
        }
        // 2. Native popup menu queue
        if !popupPresenter.isPresenting {
            while let taken = runtime.takePopup() {
                switch taken {
                case .failure:
                    continue
                case .success(let show):
                    popupPresenter.present(show, in: self) { [weak self] picked in
                        guard let self else { return }
                        try? self.runtime.resolvePopup(picked)
                        self.requestRender()
                    }
                    break
                }
                break
            }
        }
        // 3. Async non-blocking file dialog sheet
        if !fileDialogPresenter.isPresenting, let pending = runtime.takeFileDialog() {
            fileDialogPresenter.present(pending, in: self.window) { [weak self] id, result in
                guard let self else { return }
                self.runtime.answerFileDialog(id, result)
                self.requestRender()
            }
        }
    }

    // MARK: - NSDraggingDestination (File Drop)

    private func dragPoint(from sender: NSDraggingInfo) -> Vec2 {
        let p = convert(sender.draggingLocation, from: nil)
        return runtime.inputPoint(fromWindow: Vec2(Float(p.x), Float(p.y)))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = MacOSDropReader.hoverURLs(from: sender)
        guard !urls.isEmpty else { return [] }
        let pt = dragPoint(from: sender)
        let files = urls.map { DroppedFile(url: $0) }
        runtime.fileDrop(.entered(files, at: pt), at: nowSeconds())
        renderTick()
        return runtime.acceptsDrop(urls, at: pt) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = MacOSDropReader.hoverURLs(from: sender)
        let pt = dragPoint(from: sender)
        runtime.fileDrop(.hovered(at: pt), at: nowSeconds())
        renderTick()
        guard !urls.isEmpty else { return [] }
        return runtime.acceptsDrop(urls, at: pt) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        runtime.fileDrop(.exited, at: nowSeconds())
        renderTick()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pt = dragPoint(from: sender)
        let hoverUrls = MacOSDropReader.hoverURLs(from: sender)
        guard !hoverUrls.isEmpty else { return false }
        MacOSDropReader.dropURLs(from: sender) { [weak self] urls in
            guard let self, !urls.isEmpty else { return }
            let files = urls.map { DroppedFile(url: $0) }
            self.runtime.fileDrop(.dropped(files, at: pt), at: self.nowSeconds())
            self.renderTick()
        }
        return true
    }
}

extension Runtime {
    /// Output from a handler or app update reaches the shell even when the window has no drawable.
    @MainActor
    func applyMacShellRequests(to window: NSWindow?, launcher: Bool) -> Bool {
        if let title = windowTitle, window?.title != title { window?.title = title }
        let minimize = shellTakeMinimize()
        if quitRequested || relaunchRequested {
            let after: QuitAfter = relaunchRequested ? .relaunch : .exit
            _ = QuitLifecycle.send(.start(ending: false, after: after))
            NSApplication.shared.terminate(nil)
            return true
        }
        if closeWindowRequested {
            clearShellRequests()
            window?.performClose(nil)
            return true
        }
        if minimize { RuneMacWindowConfig.minimize(window, launcher: launcher) }
        return false
    }
}

@MainActor
private final class MacOSWindowlessDriver<State> {
    var isWindowShown: Bool
    private let startAt: CFTimeInterval
    private let timeScale: Double
    private let shared: AppShared<State>
    private let runtime: Runtime<State>
    private let shortcutGuard: ShortcutGuard?
    private let onShowWindow: @MainActor () -> Void
    private let applyHiddenShell: @MainActor () -> Bool
    private let applyPendingFrame: @MainActor () -> Void
    private var timer: Timer?

    init(
        initiallyHidden: Bool,
        startAt: CFTimeInterval,
        timeScale: Double,
        shared: AppShared<State>,
        runtime: Runtime<State>,
        shortcutGuard: ShortcutGuard? = nil,
        applyHiddenShell: @escaping @MainActor () -> Bool,
        applyPendingFrame: @escaping @MainActor () -> Void,
        onShowWindow: @escaping @MainActor () -> Void
    ) {
        self.isWindowShown = !initiallyHidden
        self.startAt = startAt
        self.timeScale = timeScale
        self.shared = shared
        self.runtime = runtime
        self.shortcutGuard = shortcutGuard
        self.onShowWindow = onShowWindow
        self.applyHiddenShell = applyHiddenShell
        self.applyPendingFrame = applyPendingFrame
    }

    func start() {
        pump()
        guard !isWindowShown else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pump()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func pump() {
        guard !isWindowShown else { return }
        _ = MainQueueDispatcher.shared.drain()
        let now = (CACurrentMediaTime() - startAt) * timeScale
        shortcutGuard?.drain()
        let req = if let shortcutGuard {
            shortcutGuard.withReceiving {
                shared.applyStateUpdates(to: runtime, at: now)
            }
        } else {
            shared.applyStateUpdates(to: runtime, at: now)
        }
        if req.quit {
            NSApplication.shared.terminate(nil)
            return
        }
        if req.activation == .minimize { _ = runtime.minimizeStep(.asked) }
        switch req.window {
        case .open, .show:
            isWindowShown = true
            timer?.invalidate()
            timer = nil
            shared.setVisible(true)
            onShowWindow()
            return
        default:
            break
        }
        if let poll = runtime.poll {
            var st = runtime.state
            var tx = Tx()
            if poll(&st, now, &tx) {
                runtime.state = st
                runtime.applyTx(tx, at: now, markDirtyIfNotLiveOnly: false)
            }
        }
        if !applyHiddenShell(), runtime.hasPendingWindowFrame { applyPendingFrame() }
    }
}
#endif
