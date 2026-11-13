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
        try run(wrapped, parsed: parsed)
    }

    @MainActor
    public static func run<State>(_ appBuilder: App<State>, parsed: ToolingArgs) throws {
        HeadlessRunner.registerFonts(appBuilder.fontData)

        var initialState = appBuilder.makeState()
        var initTx = Tx()
        if let sceneName = parsed.sceneName, let applyScene = appBuilder.scenes[sceneName] {
            applyScene(&initialState, &initTx)
        }

        let vp = parsed.viewportOverride ?? appBuilder.size
        let app = NSApplication.shared
        app.setActivationPolicy(appBuilder.isAccessory ? .accessory : .regular)

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
        runtime.tabVisitsControls = appBuilder.tabVisitsControlsEnabled
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
        if appBuilder.chromeStyle == .borderless {
            mask = [.borderless]
        } else if appBuilder.chromeStyle == .titlebarIntegrated || appBuilder.customTitlebar != nil || appBuilder.macosWindowValue.fullSizeContentView {
            mask.insert(.fullSizeContentView)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: CGFloat(vp.x), height: CGFloat(vp.y)),
            styleMask: mask,
            backing: .buffered,
            defer: false
        )
        window.title = appBuilder.title
        if let minSz = appBuilder.minSize ?? opts.minSize {
            window.contentMinSize = NSSize(width: CGFloat(minSz.x), height: CGFloat(minSz.y))
        }
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

        let hostView = RuneMetalHostView(
            frame: NSRect(x: 0, y: 0, width: CGFloat(vp.x), height: CGFloat(vp.y)),
            runtime: runtime,
            renderer: renderer,
            timeScale: parsed.timeScale,
            respectSystemAppearance: respectSystemAppearance,
            compositor: appBuilder.compositorValue,
            appShared: appBuilder.sharedHandle.shared,
            reports: reports,
            surfaceMeter: meter,
            devStatsReceiver: appBuilder.devStatsReceiver,
            windowHandle: windowHandle,
            onReady: appBuilder.onReadyHook
        )

        let delegate = RuneAppDelegate(
            keepRunning: appBuilder.keepsRunning,
            onFocusChange: { [weak hostView] focused in
                runtime.dispatchFocus(focused, at: hostView?.currentElapsedTime() ?? 0.0)
                hostView?.requestRender()
            },
            onShouldClose: { [weak hostView] in
                runtime.dispatchClose(at: hostView?.currentElapsedTime() ?? 0.0)
            },
            onClose: {
                hostView.stopTimer()
                appBuilder.sharedHandle.shared.setVisible(false)
            },
            onTerminate: {
                runtime.dispatchQuit(at: hostView.currentElapsedTime())
            },
            onReopen: { hasVisible in
                runtime.dispatchReopen(hasVisibleWindows: hasVisible, at: hostView.currentElapsedTime())
            },
            onOpenUrl: { url in
                runtime.dispatchOpenUrl(url, at: hostView.currentElapsedTime())
            }
        )
        app.delegate = delegate
        window.delegate = delegate
        window.contentView = hostView
        window.center()

        appBuilder.sharedHandle.shared.setWaker(waker)
        appBuilder.sharedHandle.shared.setVisible(true)
        appBuilder.onWindowHook?(windowHandle)

        waker.setCallback { [weak hostView] in
            DispatchQueue.main.async {
                hostView?.requestRender()
            }
        }
        appBuilder.setupHook?(waker)

        if appBuilder.isOpenInactive {
            window.orderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(hostView)
            app.activate(ignoringOtherApps: true)
        }
        if appBuilder.openAs.isMaximized {
            window.zoom(nil)
        }
        if appBuilder.openAs.isFullScreen {
            window.toggleFullScreen(nil)
        }

        withExtendedLifetime(delegate) {
            app.run()
        }
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
private final class RuneMetalHostView<State>: NSView {
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
    private var animTimer: Timer?
    private var trackingAreaRef: NSTrackingArea?

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
        self.onReady = onReady
        super.init(frame: frame)
        self.wantsLayer = true
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = runtime.srgbBlend ? .bgra8Unorm : .bgra8Unorm_srgb
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
        syncGeometryAndRender()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncGeometryAndRender()
    }

    private func syncGeometryAndRender() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        runtime.pixelScale = Float(scale)
        runtime.viewport = Vec2(Float(max(1, bounds.width)), Float(max(1, bounds.height)))
        renderTick()
    }

    func stopTimer() {
        animTimer?.invalidate()
        animTimer = nil
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

        if let drained = appShared?.applyStateUpdates(to: runtime, at: t) {
            applyDrainedRequests(drained)
        }

        let desiredFmt: MTLPixelFormat = runtime.srgbBlend ? .bgra8Unorm : .bgra8Unorm_srgb
        if metalLayer.pixelFormat != desiredFmt {
            metalLayer.pixelFormat = desiredFmt
        }

        let commitsBefore = runtime.viewCommitCount
        let updateStart = CACurrentMediaTime()
        let refScene = runtime.frame(at: t)
        let updateMs = (CACurrentMediaTime() - updateStart) * 1000.0

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
            NSApplication.shared.terminate(nil)
            return
        }

        let isAnim = runtime.isAnimating || (compositor?.isAnimating ?? false)
        surfaceMeter?.setPacing(isAnim ? .paced : .idle)
        _ = surfaceMeter?.redraw(paced: animTimer != nil)

        var drawCount = 0
        if let drawable = metalLayer.nextDrawable() {
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
                    drawUI: { [renderer] in
                        drawCount += 1
                        renderer.renderScene(refScene, into: drawable.texture, commandBuffer: cmdBuf)
                    }
                )
                comp.render(frame: compFrame)
                if !comp.drawsOwnContent && compFrame.uiDrawCount == 0 {
                    compFrame.drawUI()
                }
                cmdBuf.present(drawable)
                cmdBuf.commit()
            } else {
                drawCount = 1
                renderer.render(scene: refScene, to: drawable)
            }
            _ = surfaceMeter?.presented()
            if !didFireReady {
                didFireReady = true
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
                    primitives: refScene.primitives.count,
                    glyphs: refScene.primitives.reduce(0) { $0 + ($1.kind == .glyph ? 1 : 0) },
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

        if isAnim {
            if animTimer == nil {
                let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.renderTick()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                animTimer = timer
            }
        } else {
            stopTimer()
        }
    }

    private func applyDrainedRequests(_ req: AppDrainedRequests<State>) {
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
                if ch == "v" {
                    if let pasted = NSPasteboard.general.string(forType: .string) {
                        runtime.paste(ClipboardContent(pasted), at: nowSeconds())
                        renderTick()
                        return
                    }
                }
            } else if !chars.isEmpty {
                key = .text(chars)
            } else {
                return
            }
        }
        let prevClip = runtime.clipboard
        let prevRich = runtime.richClipboard
        runtime.keyDown(KeyEvent(key: key, mods: m), at: nowSeconds())
        if runtime.richClipboard != prevRich {
            Clipboard.shared.writeRich(runtime.richClipboard)
        } else if runtime.clipboard != prevClip, !runtime.clipboard.text.isEmpty {
            Clipboard.shared.writeRich(RichClipboardPayload(content: runtime.clipboard))
        }
        renderTick()
    }

    // MARK: - NSDraggingDestination (File Drop)

    private func droppedFiles(from sender: NSDraggingInfo) -> [DroppedFile] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL] ?? []
        return urls.map { DroppedFile(url: $0) }
    }

    private func dragPoint(from sender: NSDraggingInfo) -> Vec2 {
        let p = convert(sender.draggingLocation, from: nil)
        return Vec2(Float(p.x), Float(p.y))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let files = droppedFiles(from: sender)
        guard !files.isEmpty else { return [] }
        runtime.fileDrop(.entered(files, at: dragPoint(from: sender)), at: nowSeconds())
        renderTick()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        runtime.fileDrop(.hovered(at: dragPoint(from: sender)), at: nowSeconds())
        renderTick()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        runtime.fileDrop(.exited, at: nowSeconds())
        renderTick()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = droppedFiles(from: sender)
        guard !files.isEmpty else { return false }
        runtime.fileDrop(.dropped(files, at: dragPoint(from: sender)), at: nowSeconds())
        renderTick()
        return true
    }
}
#endif
