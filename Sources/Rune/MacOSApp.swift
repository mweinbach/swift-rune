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
        let app = NSApplication.shared
        app.setActivationPolicy(appBuilder.isAccessory ? .accessory : .regular)
        if !appBuilder.isAccessory {
            _ = RuneDefaultMacMenus.ensure(app)
            RuneDefaultMacMenus.addStandardMenus(app)
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
        runtime.setSystemContrast(SystemPreferences.current().contrast)
        runtime.applyTx(initTx, at: 0.0, markDirtyIfNotLiveOnly: false)

        let renderer = try MetalRenderer()
        let reports = (appBuilder.onFrameEncodedHook != nil || appBuilder.onFrameDrawnHook != nil)
            ? FrameReports<State>(onFrameEncoded: appBuilder.onFrameEncodedHook, onFrameDrawn: appBuilder.onFrameDrawnHook)
            : nil
        let meter = appBuilder.devStatsReceiver != nil ? SurfaceMeter(name: appBuilder.title) : nil

        var mask: NSWindow.StyleMask = [.titled]
        let opts = appBuilder.windowOptionsValue
        if opts.closable { mask.insert(.closable) }
        if opts.minimizable { mask.insert(.miniaturizable) }
        if opts.resizable { mask.insert(.resizable) }
        if appBuilder.chromeStyle.borderless || opts.borderless {
            mask = [.borderless]
        } else if appBuilder.chromeStyle.fullSizeContent || appBuilder.chromeStyle == .titlebarIntegrated || appBuilder.customTitlebar != nil || appBuilder.macosWindowValue.fullSizeContentView {
            mask.insert(.fullSizeContentView)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: CGFloat(vp.x), height: CGFloat(vp.y)),
            styleMask: mask,
            backing: .buffered,
            defer: false
        )
        window.title = appBuilder.title
        let minSz = appBuilder.minSize ?? opts.minSize ?? WindowOptions.defaultMinSize
        window.contentMinSize = NSSize(width: CGFloat(minSz.x), height: CGFloat(minSz.y))
        if let maxSz = opts.maxSize {
            window.contentMaxSize = NSSize(width: CGFloat(maxSz.x), height: CGFloat(maxSz.y))
        }
        window.hasShadow = opts.hasShadow
        if opts.alwaysOnTop || appBuilder.macosWindowValue.floatingLevel {
            window.level = .floating
        }
        if appBuilder.customTitlebar != nil || appBuilder.chromeStyle == .titlebarIntegrated || appBuilder.macosWindowValue.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }
        if appBuilder.customTitlebar != nil || appBuilder.macosWindowValue.hidesTitle {
            window.titleVisibility = .hidden
        }
        window.isMovableByWindowBackground = appBuilder.macosWindowValue.movableByWindowBackground

        let windowHandle = WindowHandle(
            title: appBuilder.title,
            isVisible: true,
            onClose: { [weak window] in Task { @MainActor in window?.close() } },
            onMinimize: { [weak window] in Task { @MainActor in window?.miniaturize(nil) } },
            onFocus: { [weak window] in Task { @MainActor in window?.makeKeyAndOrderFront(nil) } },
            onShow: { [weak window] in Task { @MainActor in window?.orderFront(nil) } },
            onHide: { [weak window] in Task { @MainActor in window?.orderOut(nil) } },
            onSetTitle: { [weak window] newTitle in Task { @MainActor in window?.title = newTitle } },
            onSetPosition: { [weak window] pt in
                Task { @MainActor in
                    window?.setFrameOrigin(NSPoint(x: CGFloat(pt.x), y: CGFloat(pt.y)))
                }
            },
            onPlace: { [weak window] req in
                Task { @MainActor in
                    guard let w = window else { return }
                    if let sz = req.size {
                        w.setContentSize(NSSize(width: CGFloat(sz.x), height: CGFloat(sz.y)))
                    }
                    if let pos = req.position {
                        w.setFrameOrigin(NSPoint(x: CGFloat(pos.x), y: CGFloat(pos.y)))
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

        let appShared = appBuilder.sharedHandle.shared
        AppMenuBridge.markRunning(appShared, running: true, headless: false)
        defer {
            AppMenuBridge.markRunning(appShared, running: false, headless: false)
            RuneNativeMenuHost.shared.clear()
        }
        if !appBuilder.menuItems.isEmpty {
            do {
                try AppMenuBridge.setMenu(appBuilder.menuItems, for: appShared)
            } catch let err as MenuError {
                AppMenuBridge.recordError(err, for: appShared)
            } catch {
                AppMenuBridge.recordError(.unsupported, for: appShared)
            }
        }

        let hostView = RuneMetalHostView(
            frame: NSRect(x: 0, y: 0, width: CGFloat(vp.x), height: CGFloat(vp.y)),
            runtime: runtime,
            renderer: renderer,
            timeScale: parsed.timeScale,
            respectSystemAppearance: respectSystemAppearance,
            compositor: appBuilder.compositorValue,
            appShared: appShared,
            reports: reports,
            surfaceMeter: meter,
            devStatsReceiver: appBuilder.devStatsReceiver,
            windowHandle: windowHandle,
            minWindowSize: (minSz.x, minSz.y),
            maxWindowSize: opts.maxSize.map { ($0.x, $0.y) },
            onReady: appBuilder.onReadyHook
        )

        let windowlessDriver = MacOSWindowlessDriver<State>(
            isWindowless: appBuilder.isWindowless,
            startAt: CACurrentMediaTime(),
            timeScale: parsed.timeScale,
            shared: appBuilder.sharedHandle.shared,
            runtime: runtime,
            onShowWindow: { [weak window, weak hostView] in
                guard let window, let hostView else { return }
                if appBuilder.isOpenInactive {
                    window.orderFront(nil)
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
        shortcutBridge.sync(registry: runtime.shortcutRegistry)
        let systemObserver = MacOSSystemObserver { [weak runtime, weak hostView] in
            guard let runtime else { return }
            runtime.setSystemContrast(SystemPreferences.current().contrast)
            runtime.markNeedsCommit()
            hostView?.requestRender()
        }

        let delegate = RuneAppDelegate(
            keepRunning: appBuilder.keepsRunning || appBuilder.isWindowless,
            onFocusChange: { [weak hostView] focused in
                if focused {
                    runtime.setSystemContrast(SystemPreferences.current().contrast)
                }
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
                hostView.stopTimer()
                hostView.cancelActiveModals()
                appBuilder.sharedHandle.shared.setVisible(false)
                if !(appBuilder.keepsRunning || appBuilder.isWindowless) && NSApplication.shared.windows.filter(\.isVisible).count <= 1 {
                    let after: QuitAfter = runtime.relaunchRequested ? .relaunch : .exit
                    _ = QuitLifecycle.send(.start(ending: false, after: after))
                }
            },
            onTerminate: {
                _ = systemObserver
                shortcutBridge.clear()
                windowlessDriver.stop()
                hostView.stopTimer()
                hostView.cancelActiveModals()
                runtime.dispatchQuit(at: hostView.currentElapsedTime())
                QuitLifecycle.runQuitHooksIfOwed()
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
        MacOSQuitHook.install()
        window.delegate = delegate
        window.contentView = hostView
        window.center()

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

        if appBuilder.isWindowless {
            ReadySignal.ready()
            windowlessDriver.start()
        } else {
            if appBuilder.isOpenInactive {
                window.orderFront(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(hostView)
                if !appBuilder.isAccessory {
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

        withExtendedLifetime(delegate) {
            app.run()
        }
        windowlessDriver.stop()
        QuitLifecycle.finishOrderlyExit()
    }
}

@MainActor
private final class RuneAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
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
private final class RuneMetalHostView<State>: NSView, @MainActor NSTextInputClient {
    private let runtime: Runtime<State>
    private let renderer: MetalRenderer
    private let metalLayer = CAMetalLayer()
    private let startTime = CACurrentMediaTime()
    private let timeScale: Double
    private let respectSystemAppearance: Bool
    private let compositor: AnyCompositor<State>?
    private let appShared: AppShared<State>?
    private let reports: FrameReports<State>?
    private let surfaceMeter: SurfaceMeter?
    private let devStatsReceiver: ((SurfaceStats) -> Void)?
    private let windowHandle: WindowHandle?
    private let onReady: ((WindowHandle) -> Void)?
    private var didFireReady: Bool = false
    private var lastFrameTime: Double = 0.0
    private var displayLinkDriver: MacOSDisplayLinkDriver?
    private var trackingAreaRef: NSTrackingArea?
    private var didSignalReady = false
    private let popupPresenter = MacOSPopupMenuPresenter()
    private let fileDialogPresenter = MacOSFileDialogPresenter()
    private let dragOutCoordinator = MacOSDragOutCoordinator()
    private var materialHost: RuneMaterialHost?
    private var restingGiveBackDone: Bool = false
    private let accessibilityHost = MacOSAccessibilityHost()
    private lazy var textInputBridge = MacOSTextInputBridge { [weak self] imeEvent in
        guard let self else { return }
        if self.runtime.dispatchImeEvent(imeEvent, at: self.nowSeconds()) {
            self.requestRender()
        }
    }
    private var lastAppliedCursor: Cursor = .default
    private var didInitialA11ySync = false
    private let toolTipOwner = MacOSToolTipOwner()
    private let windowFrameDriver = MacOSWindowFrameDriver()
    private let minWindowSize: (Float, Float)
    private let maxWindowSize: (Float, Float)?
    private var appliedMenuRevision: UInt64 = 0
    private let fnKeyMonitor = FnKeyMonitor()

    init(
        frame: NSRect,
        runtime: Runtime<State>,
        renderer: MetalRenderer,
        timeScale: Double,
        respectSystemAppearance: Bool,
        compositor: AnyCompositor<State>? = nil,
        appShared: AppShared<State>? = nil,
        reports: FrameReports<State>? = nil,
        surfaceMeter: SurfaceMeter? = nil,
        devStatsReceiver: ((SurfaceStats) -> Void)? = nil,
        windowHandle: WindowHandle? = nil,
        minWindowSize: (Float, Float) = (WindowOptions.defaultMinSize.x, WindowOptions.defaultMinSize.y),
        maxWindowSize: (Float, Float)? = nil,
        onReady: ((WindowHandle) -> Void)? = nil
    ) {
        self.runtime = runtime
        self.renderer = renderer
        self.timeScale = timeScale
        self.respectSystemAppearance = respectSystemAppearance
        self.compositor = compositor
        self.appShared = appShared
        self.reports = reports
        self.surfaceMeter = surfaceMeter
        self.devStatsReceiver = devStatsReceiver
        self.windowHandle = windowHandle
        self.minWindowSize = minWindowSize
        self.maxWindowSize = maxWindowSize
        self.onReady = onReady
        super.init(frame: frame)
        self.wantsLayer = true
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = runtime.srgbBlend ? .bgra8Unorm : .bgra8Unorm_srgb
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
        syncGeometryAndRender()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncGeometryAndRender()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        materialHost?.setLiveResizing(true, mode: MaterialMode.fromEnv())
    }

    private func syncGeometryAndRender() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let newVP = Vec2(Float(max(1, bounds.width)), Float(max(1, bounds.height)))
        if windowFrameDriver.isMoving || windowFrameDriver.takeJumpIfMatching(viewport: newVP) {
            runtime.stepViewport(newVP, pixelScale: Float(scale))
        } else {
            runtime.setViewport(newVP, pixelScale: Float(scale))
        }
        renderTick()
    }

    func stopTimer() {
        displayLinkDriver?.stop()
        displayLinkDriver = nil
        if let w = window {
            windowFrameDriver.landFrame(window: w)
        }
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
        let t = nowSeconds()
        let dt = Float(max(0.0, t - lastFrameTime))
        lastFrameTime = t

        if let w = window {
            let scale = Float(w.backingScaleFactor)
            _ = windowFrameDriver.step(window: w, now: t, scale: scale, resting: runtime.windowResting) { [weak self] vp, sc in
                self?.runtime.stepViewport(vp, pixelScale: sc)
            }
        }
        runtime.windowResting = !(inLiveResize || windowFrameDriver.isMoving)

        if let drained = appShared?.applyStateUpdates(to: runtime, at: t) {
            applyDrainedRequests(drained)
        }
        syncNativeMenus()

        let desiredFmt: MTLPixelFormat = runtime.srgbBlend ? .bgra8Unorm : .bgra8Unorm_srgb
        if metalLayer.pixelFormat != desiredFmt {
            metalLayer.pixelFormat = desiredFmt
        }

        let materialMode = MaterialMode.fromEnv()
        if let w = window {
            runtime.nativeMaterials = (!w.isOpaque && materialMode != .fallback)
        } else {
            runtime.nativeMaterials = false
        }

        let commitsBefore = runtime.viewCommitCount
        let updateStart = CACurrentMediaTime()
        let renderFrame = runtime.renderFrame(at: t)
        let updateMs = (CACurrentMediaTime() - updateStart) * 1000.0

        if let w = window {
            if !w.isOpaque && materialMode != .fallback && !renderFrame.materials.isEmpty {
                let mh: RuneMaterialHost
                if let existing = materialHost {
                    mh = existing
                } else {
                    mh = RuneMaterialHost(frame: bounds)
                    materialHost = mh
                }
                mh.attach(to: w, below: self, metalLayer: metalLayer)
                mh.setLiveResizing(inLiveResize, mode: materialMode)
                mh.apply(renderFrame.materials, scale: CGFloat(runtime.pixelScale), mode: materialMode)
            } else if let mh = materialHost {
                mh.setLiveResizing(inLiveResize, mode: materialMode)
                mh.hideAll(mode: materialMode)
            }
        }

        if let title = runtime.windowTitle, window?.title != title {
            window?.title = title
        }
        if runtime.closeWindowRequested {
            runtime.clearShellRequests()
            window?.performClose(nil)
            return
        }
        if runtime.minimizeRequested {
            runtime.clearShellRequests()
            window?.miniaturize(nil)
        }
        if runtime.quitRequested {
            let after: QuitAfter = runtime.relaunchRequested ? .relaunch : .exit
            _ = QuitLifecycle.send(.start(ending: false, after: after))
            NSApplication.shared.terminate(nil)
            return
        }

        if let frameReq = runtime.takeWindowFrameRequest(), let w = window {
            let scale = Float(w.backingScaleFactor)
            windowFrameDriver.applyRequest(
                frameReq,
                window: w,
                now: t,
                minSize: minWindowSize,
                maxSize: maxWindowSize,
                scale: scale
            ) { [weak self] vp, sc in
                self?.runtime.stepViewport(vp, pixelScale: sc)
            }
        }
        let isAnim = runtime.isAnimating || (compositor?.isAnimating ?? false) || windowFrameDriver.isMoving
        if isAnim {
            restingGiveBackDone = false
        } else if !restingGiveBackDone {
            restingGiveBackDone = true
            let hidden = window?.occlusionState.contains(.visible) == false
            renderer.giveBack(all: hidden, residentCaches: false)
        }
        surfaceMeter?.setPacing(isAnim ? .paced : .idle)
        _ = surfaceMeter?.redraw(paced: displayLinkDriver?.isRunning ?? false)

        var drawCount = 0
        if let drawable = metalLayer.nextDrawable() {
            let synced = metalLayer.presentsWithTransaction && materialMode != .unsynced
            if synced {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
            }
            if let comp = compositor, let cmdBuf = renderer.commandQueue.makeCommandBuffer() {
                let compFrame = CompositorFrame<State>(
                    deviceKey: DeviceKey(rawValue: renderer.device.registryID),
                    pixelSize: (Int(metalLayer.drawableSize.width), Int(metalLayer.drawableSize.height)),
                    dt: dt,
                    updateMilliseconds: updateMs,
                    srgbBlend: runtime.srgbBlend,
                    runtime: runtime,
                    device: renderer.device,
                    commandQueue: renderer.commandQueue,
                    commandBuffer: cmdBuf,
                    targetTexture: drawable.texture,
                    pixelFormat: desiredFmt,
                    renderer: renderer,
                    drawUI: { [renderer, renderFrame] in
                        drawCount += 1
                        renderer.drawRange(frame: renderFrame, into: drawable.texture, commandBuffer: cmdBuf)
                    }
                )
                comp.render(frame: compFrame)
                if !comp.drawsOwnContent && compFrame.uiDrawCount == 0 {
                    compFrame.drawUI()
                }
                if synced {
                    cmdBuf.commit()
                    cmdBuf.waitUntilScheduled()
                    drawable.present()
                } else {
                    cmdBuf.present(drawable)
                    cmdBuf.commit()
                }
            } else {
                drawCount = 1
                renderer.draw(frame: renderFrame, to: drawable, synchronized: synced)
            }
            if synced {
                CATransaction.commit()
            }
            _ = surfaceMeter?.presented()
            if !didFireReady {
                didFireReady = true
                ReadySignal.ready()
                if let wh = windowHandle {
                    onReady?(wh)
                }
            }
            if let reports {
                let encoded = FrameEncoded(
                    outcome: .drawn,
                    frameMs: (CACurrentMediaTime() - updateStart) * 1000.0,
                    updateMs: updateMs,
                    encodeMs: 0.0,
                    committed: runtime.viewCommitCount != commitsBefore,
                    primitives: renderFrame.instances.count,
                    glyphs: renderFrame.instances.reduce(0) { $0 + ($1.params.y == KIND_GLYPH ? 1 : 0) },
                    animating: runtime.isAnimating,
                    compositorAnimating: compositor?.isAnimating ?? false,
                    drawCount: drawCount,
                    compositorSummary: compositor?.summary()
                )
                reports.record(encoded)
                _ = runtime.updateIf(at: t) { s, tx in
                    reports.flush(state: &s, tx: &tx, at: t)
                }
            }
        }
        if let stats = surfaceMeter?.currentStats() {
            devStatsReceiver?(stats)
        }
        pumpPlatformActions()
        syncPlatformBridges(treeCommitted: !didInitialA11ySync || runtime.viewCommitCount != commitsBefore)

        if isAnim {
            if displayLinkDriver == nil {
                let driver = MacOSDisplayLinkDriver { [weak self] in
                    self?.renderTick()
                }
                displayLinkDriver = driver
            }
            displayLinkDriver?.start(in: self)
        } else {
            stopTimer()
        }
    }

    private func syncPlatformBridges(treeCommitted: Bool) {
        let focused = window?.isKeyWindow ?? true
        let imeAllowed = runtime.hasFocusedTextInput && !runtime.hasSecureFocus && focused
        let cancelIme = runtime.consumeImeReset()
        let caretRect = MacOSHostViewHelper.caretScreenRect(caret: runtime.focusedCaretRect(), in: self)
        textInputBridge.sync(
            imeText: imeAllowed ? runtime.focusedImeSnapshot() : nil,
            caretScreenRect: caretRect,
            cancelExisting: cancelIme,
            in: self
        )

        MacOSHostViewHelper.applyCursor(runtime.currentCursor(), previous: &lastAppliedCursor, in: self)

        if treeCommitted {
            didInitialA11ySync = true
            toolTipOwner.sync(regions: runtime.helpRegionsList(), on: self)
            let snapshot = runtime.accessibilitySnapshot()
            accessibilityHost.update(tree: snapshot, parentView: self) { [weak self] id, action in
                MacOSHostViewHelper.dispatchAccessibilityAction(id, action: action) { id, action in
                    guard let self else { return }
                    if self.runtime.performAccessibilityAction(id, action: action, at: self.nowSeconds()) {
                        self.requestRender()
                    }
                }
            }
        }
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
            try RuneNativeMenuHost.shared.apply(items: snap.items) { [weak self] itemId in
                guard let self, let shared = self.appShared else { return }
                let latest = AppMenuBridge.snapshot(for: shared).items
                guard let item = latest.first(where: { !$0.isSeparator && $0.id == itemId }) else { return }
                let action = item.action
                self.runtime.update(at: self.nowSeconds()) { state, tx in
                    action(&state, &tx)
                }
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
                window?.setFrameOrigin(NSPoint(x: CGFloat(pos.x), y: CGFloat(pos.y)))
            }
            if let place = req.place {
                if let sz = place.size {
                    window?.setContentSize(NSSize(width: CGFloat(sz.x), height: CGFloat(sz.y)))
                }
                if let pos = place.position {
                    window?.setFrameOrigin(NSPoint(x: CGFloat(pos.x), y: CGFloat(pos.y)))
                }
            }
            window?.orderFront(nil)
            appShared?.setVisible(true)
        case .hide:
            window?.orderOut(nil)
            appShared?.setVisible(false)
        case .none:
            if let pos = req.position {
                window?.setFrameOrigin(NSPoint(x: CGFloat(pos.x), y: CGFloat(pos.y)))
            }
            if let place = req.place {
                if let sz = place.size {
                    window?.setContentSize(NSSize(width: CGFloat(sz.x), height: CGFloat(sz.y)))
                }
                if let pos = place.position {
                    window?.setFrameOrigin(NSPoint(x: CGFloat(pos.x), y: CGFloat(pos.y)))
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
            window?.miniaturize(nil)
        case .none:
            break
        }
    }

    private func localPoint(for event: NSEvent) -> Vec2 {
        let p = convert(event.locationInWindow, from: nil)
        return Vec2(Float(p.x), Float(p.y))
    }

    private func mods(for event: NSEvent) -> Mods {
        MacOSKeyMapper.mods(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        runtime.pointerMove(to: localPoint(for: event), mods: mods(for: event), at: nowSeconds())
        renderTick()
    }

    override func mouseExited(with event: NSEvent) {
        runtime.pointerExit(at: nowSeconds())
        renderTick()
    }

    override func mouseDragged(with event: NSEvent) {
        runtime.pointerMove(to: localPoint(for: event), mods: mods(for: event), at: nowSeconds())
        renderTick()
    }

    override func rightMouseDragged(with event: NSEvent) {
        runtime.pointerMove(to: localPoint(for: event), mods: mods(for: event), at: nowSeconds())
        renderTick()
    }

    override func otherMouseDragged(with event: NSEvent) {
        runtime.pointerMove(to: localPoint(for: event), mods: mods(for: event), at: nowSeconds())
        renderTick()
    }

    override func mouseDown(with event: NSEvent) {
        runtime.pointerDown(at: localPoint(for: event), button: .primary, mods: mods(for: event), at: nowSeconds())
        renderTick()
    }

    override func mouseUp(with event: NSEvent) {
        runtime.pointerUp(at: localPoint(for: event), button: .primary, mods: mods(for: event), at: nowSeconds())
        renderTick()
    }

    override func rightMouseDown(with event: NSEvent) {
        runtime.pointerDown(at: localPoint(for: event), button: .secondary, mods: mods(for: event), at: nowSeconds())
        renderTick()
    }

    override func rightMouseUp(with event: NSEvent) {
        runtime.pointerUp(at: localPoint(for: event), button: .secondary, mods: mods(for: event), at: nowSeconds())
        renderTick()
    }

    override func otherMouseDown(with event: NSEvent) {
        runtime.pointerDown(at: localPoint(for: event), button: .middle, mods: mods(for: event), at: nowSeconds())
        renderTick()
    }

    override func otherMouseUp(with event: NSEvent) {
        runtime.pointerUp(at: localPoint(for: event), button: .middle, mods: mods(for: event), at: nowSeconds())
        renderTick()
    }

    override func scrollWheel(with event: NSEvent) {
        let mult: Float = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
        let wev = WheelEvent(
            dx: Float(event.scrollingDeltaX) * mult,
            dy: Float(event.scrollingDeltaY) * mult,
            precise: event.hasPreciseScrollingDeltas,
            mods: mods(for: event)
        )
        runtime.wheel(wev, at: localPoint(for: event), now: nowSeconds())
        renderTick()
    }

    private func makeKeyEvent(from event: NSEvent) -> KeyEvent? {
        MacOSKeyMapper.makeKeyEvent(from: event)
    }

    @discardableResult
    func dispatchKeyEvent(_ ev: KeyEvent, isRepeat: Bool = false) -> Bool {
        let handled = MacOSClipboardSync.dispatchKeyWithSync(ev, runtime: runtime, at: nowSeconds())
        _ = isRepeat
        renderTick()
        return handled
    }

    @discardableResult
    func dispatchNativeKeyEvent(_ event: NSEvent) -> Bool {
        guard let kev = makeKeyEvent(from: event) else { return false }
        return dispatchKeyEvent(kev, isRepeat: event.isARepeat)
    }

    override func keyDown(with event: NSEvent) {
        if runtime.hasFocusedTextInput && !runtime.hasSecureFocus {
            let imeResult = textInputBridge.processKeyDown(event, in: self)
            if imeResult == .handledByIME {
                renderTick()
                return
            }
        }
        _ = dispatchNativeKeyEvent(event)
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
        renderTick()
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
            MacOSUnsafeSendableBox(accessibilityHost.accessibilityChildren())
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
        return Vec2(Float(p.x), Float(p.y))
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

@MainActor
private final class MacOSWindowlessDriver<State> {
    var isWindowShown: Bool
    private let startAt: CFTimeInterval
    private let timeScale: Double
    private let shared: AppShared<State>
    private let runtime: Runtime<State>
    private let onShowWindow: @MainActor () -> Void
    private var timer: Timer?

    init(
        isWindowless: Bool,
        startAt: CFTimeInterval,
        timeScale: Double,
        shared: AppShared<State>,
        runtime: Runtime<State>,
        onShowWindow: @escaping @MainActor () -> Void
    ) {
        self.isWindowShown = !isWindowless
        self.startAt = startAt
        self.timeScale = timeScale
        self.shared = shared
        self.runtime = runtime
        self.onShowWindow = onShowWindow
    }

    func start() {
        pump()
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
        let req = shared.applyStateUpdates(to: runtime, at: now)
        if req.quit {
            NSApplication.shared.terminate(nil)
            return
        }
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
        if runtime.quitRequested || runtime.relaunchRequested {
            let after: QuitAfter = runtime.relaunchRequested ? .relaunch : .exit
            _ = QuitLifecycle.send(.start(ending: false, after: after))
            NSApplication.shared.terminate(nil)
        }
    }
}
#endif
