import Foundation
import RuneMotion
import RuneRef

#if canImport(UIKit) && !os(watchOS)
import UIKit
#if canImport(QuartzCore)
import QuartzCore
#endif
#if canImport(Metal)
import Metal
#endif

/// iOS / iPadOS / visionOS UIKit + Metal/RuneRef application host called by `RuneApp.run(spec)`.
public enum IOSApp {
    @MainActor
    public static func run<State>(_ spec: AppSpec<State>, parsed: ToolingArgs) throws {
        try install(makeViewController(spec, parsed: parsed))
    }

    @MainActor
    public static func run<State>(_ app: App<State>, parsed: ToolingArgs) throws {
        try install(makeViewController(app, parsed: parsed))
    }

    @MainActor
    private static func install(_ controller: UIViewController) throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let foreground = scenes.filter {
            $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive
        }
        let windows = foreground.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else {
            throw NSError(domain: "Rune.UIKit", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Rune needs a window. Set IOSApp.makeViewController(...) as the window's rootViewController in your scene delegate."
            ])
        }
        window.rootViewController = controller
        window.makeKeyAndVisible()
    }

    @MainActor
    public static func makeViewController<State>(
        _ spec: AppSpec<State>, parsed: ToolingArgs = ToolingArgs.parse([])
    ) throws -> RuneIOSViewController<State> {
        var app = App(title: spec.title, size: spec.size, minSize: spec.minSize, dark: spec.dark,
                      state: spec.makeState(), view: spec.view)
        app.fontData = spec.fonts
        app.fontFamilies = spec.families
        app.scenes = spec.scenes
        app.setupHook = spec.setup
        app.pollHook = spec.poll
        app.onKeyHook = spec.onKey
        app.srgbBlendEnabled = spec.srgbBlend
        let controller = try makeViewController(app, parsed: parsed)
        controller.runeView.runtime.onAppFileDrop = spec.onFileDrop
        controller.runeView.runtime.onFileDrop = spec.onFileDropPhase
        return controller
    }

    /// Embeds a fully configured Rune application in an existing UIKit window or navigation stack.
    @MainActor
    public static func makeViewController<State>(
        _ app: App<State>, parsed: ToolingArgs = ToolingArgs.parse([])
    ) throws -> RuneIOSViewController<State> {
        HeadlessRunner.registerFonts(app.fontData)
        let traits = UITraitCollection.current
        let runtime = app.makeRuntime(
            viewport: parsed.viewportOverride ?? app.size,
            pixelScale: Float(max(1, traits.displayScale)),
            systemDark: parsed.darkOverride ?? app.dark ?? (traits.userInterfaceStyle == .dark),
            reducedMotion: parsed.reducedMotion || UIAccessibility.isReduceMotionEnabled,
            sceneName: parsed.sceneName
        )
        runtime.urlOpener.headless = false
        runtime.readSystemContrastSettings()
        let controller = try RuneIOSViewController(
            runtime: runtime,
            timeScale: parsed.timeScale,
            respectSystemAppearance: parsed.darkOverride == nil && app.dark == nil,
            backend: parsed.forceCPU ? .software : app.gpuBackendPreference
        )
        controller.configure(app)
        return controller
    }
}

/// UIKit view hosting a `Rune` runtime via `CAMetalLayer` (`MetalRenderer`) with `RuneRef` fallback.
@MainActor
public final class RuneIOSView<State>: UIView, UIKeyInput {
    public let runtime: Runtime<State>
    fileprivate let timeScale: Double
    private let respectSystemAppearance: Bool
    private let startTime: TimeInterval
    private var activeContact: (id: UInt64, button: PointerButton?)?
    private(set) var didSignalReady = false
    fileprivate var requestFrame: (() -> Void)?
    fileprivate var frameFinished: ((Bool) -> Void)?
    fileprivate var beforeFrame: ((Double) -> Void)?
    fileprivate var firstFrame: (() -> Void)?
    fileprivate var reports: FrameReports<State>?
    fileprivate var compositor: AnyCompositor<State>?
    fileprivate var receiveStats: ((SurfaceStats) -> Void)?
    private var previousFrameTime: Double?
    private var atRest = false
    private var editing = false
    private var announcementCount: UInt32 = 0
    private var accessibilityCommit: Int?
    private var accessibleElements: [AccessibilityIdentity: RuneUIAccessibilityElement] = [:]
    private var cpuContent: CALayer?

    #if canImport(Metal)
    private let metalRenderer: MetalRenderer?
    #endif

    public override class var layerClass: AnyClass {
        #if canImport(Metal) && canImport(QuartzCore)
        return CAMetalLayer.self
        #else
        return CALayer.self
        #endif
    }

    public init(
        frame: CGRect,
        runtime: Runtime<State>,
        timeScale: Double = 1.0,
        respectSystemAppearance: Bool = true,
        backend: GpuBackend = .auto
    ) throws {
        self.runtime = runtime
        self.timeScale = timeScale
        self.respectSystemAppearance = respectSystemAppearance
        self.startTime = ProcessInfo.processInfo.systemUptime
        #if canImport(Metal)
        try GpuBackendPolicy.checkWindowBackend(backend)
        if GpuBackendPolicy.windowBackend(backend) == .software {
            metalRenderer = nil
        } else {
            GpuEvents.starting()
            do {
                metalRenderer = try MetalRenderer()
            } catch MetalRenderer.RendererError.metalUnavailable {
                guard GpuBackendPolicy.defaulted(env: ProcessInfo.processInfo.environment["RUNE_GPU_BACKEND"],
                                                chosen: backend) else {
                    throw MetalRenderer.RendererError.metalUnavailable
                }
                metalRenderer = nil
            }
        }
        #endif
        super.init(frame: frame)
        MediaPlaybackGate.enable()
        #if !os(tvOS)
        self.isMultipleTouchEnabled = true
        #endif
        self.contentScaleFactor = CGFloat(runtime.pixelScale)

        #if canImport(Metal) && canImport(QuartzCore)
        if let metalLayer = self.layer as? CAMetalLayer, let gpu = metalRenderer {
            metalLayer.device = gpu.device
            metalLayer.pixelFormat = runtime.srgbBlend ? .bgra8Unorm : .bgra8Unorm_srgb
            // Backdrop and custom compositor passes sample the drawable texture.
            metalLayer.framebufferOnly = false
            DisplayGpuAdapter(backend: .metal, device: gpu.device.name).reportIfRequested()
            metalLayer.contentsScale = CGFloat(runtime.pixelScale)
        } else {
            let content = CALayer()
            content.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer.addSublayer(content)
            cpuContent = content
            if ProcessInfo.processInfo.environment["RUNE_GPU_INFO"] == "1" {
                FileHandle.standardError.write(Data("Rune renderer: RuneRef CPU\n".utf8))
            }
        }
        #endif

        #if !os(tvOS)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
        #endif

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        #if !os(tvOS)
        // Direct and Pencil contacts belong to Runtime.touch, including when another finger lands.
        pan.allowedTouchTypes = []
        pan.allowedScrollTypesMask = .all
        #endif
        addGestureRecognizer(pan)

        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: RuneIOSView<State>, _) in
                view.syncAppearance()
            }
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var canBecomeFirstResponder: Bool { true }

    public var hasText: Bool {
        guard let path = runtime.focusedPath,
              let index = runtime.nodeByPath[path],
              let lens = runtime.flatNodes[index].el.handlers.editLens else { return runtime.hasImeTarget }
        return !lens.get(runtime.state).text.isEmpty
    }
    public var isSecureTextEntry = false

    /// Views embedded without a RuneIOSViewController still draw in response to input.
    private func invalidateFrame() {
        if let requestFrame { requestFrame() } else { renderTick() }
    }

    public func insertText(_ text: String) {
        let now = nowSeconds()
        runtime.hostInput(.keyPress) {
            for scalar in text {
                let key: Key = (scalar == "\n" || scalar == "\r") ? .enter : (scalar == "\t" ? .tab : .text(String(scalar)))
                _ = runtime.keyDown(KeyEvent(key: key), at: now)
            }
        }
        invalidateFrame()
    }

    public func deleteBackward() {
        _ = runtime.hostInput(.keyPress) { runtime.keyDown(KeyEvent(key: .backspace), at: nowSeconds()) }
        invalidateFrame()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let scale = Float(max(1.0, traitCollection.displayScale))
        let size = Vec2(Float(bounds.width), Float(bounds.height))
        if size.x > 0 && size.y > 0 {
            runtime.stepViewport(size, pixelScale: scale)
            cpuContent?.frame = bounds
            contentScaleFactor = CGFloat(scale)
            #if canImport(Metal) && canImport(QuartzCore)
            if let metalLayer = self.layer as? CAMetalLayer {
                metalLayer.contentsScale = CGFloat(scale)
                metalLayer.drawableSize = CGSize(
                    width: CGFloat(size.x * scale),
                    height: CGFloat(size.y * scale)
                )
            }
            #endif
            invalidateFrame()
        }
    }

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        invalidateFrame()
    }

    public func syncAppearance() {
        guard respectSystemAppearance else { return }
        runtime.systemDark = (traitCollection.userInterfaceStyle == .dark)
        invalidateFrame()
    }

    public func renderTick() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        _ = MainQueueDispatcher.shared.drain()
        let t = nowSeconds()
        beforeFrame?(t)
        let dt = Float(max(0, t - (previousFrameTime ?? t)))
        let start = CACurrentMediaTime()
        let commits = runtime.viewCommitCount
        var updateEnd: Double
        var primitives: Int
        var glyphs: Int
        var draws = 1
        _ = runtime.surfaceMeter?.redraw(paced: true)

        #if canImport(Metal) && canImport(QuartzCore)
        if let gpu = metalRenderer, let metalLayer = layer as? CAMetalLayer {
            let format: MTLPixelFormat = runtime.srgbBlend ? .bgra8Unorm : .bgra8Unorm_srgb
            if metalLayer.pixelFormat != format { metalLayer.pixelFormat = format }
            guard let drawable = metalLayer.nextDrawable(), let commands = gpu.commandQueue.makeCommandBuffer() else {
                reports?.skipped()
                _ = runtime.surfaceMeter?.skipped()
                frameFinished?(true)
                return
            }
            let frame = gpu.frame(runtime, at: t)
            updateEnd = CACurrentMediaTime()
            primitives = frame.instances.count
            glyphs = reports == nil ? 0 : frame.instances.reduce(0) { $0 + ($1.params.y == KIND_GLYPH ? 1 : 0) }
            if let compositor {
                draws = gpu.encodeCompositor(compositor, frame: frame, into: drawable.texture,
                                             commandBuffer: commands, runtime: runtime, dt: dt,
                                             updateMilliseconds: (updateEnd - start) * 1000)
            } else {
                gpu.encodeUI(frame: frame, into: drawable.texture, commandBuffer: commands)
            }
            gpu.renderEngine.gpuLoss.attach(to: commands)
            commands.present(drawable)
            commands.commit()
            GpuEvents.presented()
        } else {
            let scene = runtime.frame(at: t)
            updateEnd = CACurrentMediaTime()
            guard let surfaces = try? NativeSurfaceReference.capture(runtime.surfaces, srgbBlend: scene.srgbBlend),
                  let frame = try? RuneRef.render(scene, surfaces: surfaces), let image = makeCGImage(from: frame) else {
                reports?.skipped()
                _ = runtime.surfaceMeter?.skipped()
                frameFinished?(false)
                return
            }
            (cpuContent ?? layer).contents = image
            primitives = scene.primitives.count
            glyphs = reports == nil ? 0 : scene.primitives.reduce(0) { $0 + ($1.kind == .glyph ? 1 : 0) }
        }
        #else
        return
        #endif

        previousFrameTime = t
        // Scrolling and animated layout can move an accessible control without a new view commit.
        accessibilityCommit = nil
        let wantsKeyboard = runtime.hasImeTarget || runtime.hasSecureFocus
        if isSecureTextEntry != runtime.hasSecureFocus {
            isSecureTextEntry = runtime.hasSecureFocus
            if isFirstResponder { reloadInputViews() }
        }
        if editing != wantsKeyboard {
            editing = wantsKeyboard
            if editing { becomeFirstResponder() } else { resignFirstResponder() }
        }
        let announcement = runtime.a11yAnnouncement
        if announcement.count != announcementCount {
            announcementCount = announcement.count
            UIAccessibility.post(notification: .announcement, argument: announcement.text)
        }
        if !didSignalReady {
            didSignalReady = true
            ReadySignal.ready()
            firstFrame?()
        }
        let active = runtime.isAnimating || compositor?.isAnimating == true
        if !active && !atRest { runtime.rest(at: t) }
        atRest = !active
        if let reports {
            let end = CACurrentMediaTime()
            reports.record(FrameEncoded(
                outcome: .drawn, frameMs: (end - start) * 1000, updateMs: (updateEnd - start) * 1000,
                encodeMs: (end - updateEnd) * 1000, committed: commits != runtime.viewCommitCount,
                primitives: primitives, glyphs: glyphs, animating: runtime.isAnimating,
                compositorAnimating: compositor?.isAnimating ?? false, drawCount: draws,
                compositorSummary: compositor?.summary(), at: t
            ))
            _ = runtime.updateIf(at: t) { state, tx in reports.flush(state: &state, tx: &tx, at: t) }
            reports.inspect(runtime)
        }
        if let meter = runtime.surfaceMeter {
            meter.setPacing(active ? .paced : .idle)
            _ = meter.presented()
            receiveStats?(meter.currentStats())
        }
        frameFinished?(active || runtime.isStale)
    }

    public override var accessibilityElements: [Any]? {
        get {
            if accessibilityCommit != runtime.viewCommitCount {
                accessibilityCommit = runtime.viewCommitCount
                super.accessibilityElements = UIKitAccessibilityMapper.updateElements(
                    from: runtime.accessibilitySnapshot(), container: self, cache: &accessibleElements
                ) { [weak self] id, action in
                    Task { @MainActor in
                        guard let self else { return }
                        if self.runtime.accessibilityAction(id, action, at: self.nowSeconds()) { self.invalidateFrame() }
                    }
                }
            }
            return super.accessibilityElements
        }
        set { super.accessibilityElements = newValue }
    }

    private func makeCGImage(from frame: Frame) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        let data = Data(frame.rgba)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    fileprivate func nowSeconds() -> Double {
        (ProcessInfo.processInfo.systemUptime - startTime) * timeScale
    }

    private func point(for touch: UITouch) -> Vec2 {
        let p = touch.location(in: self)
        return Vec2(Float(p.x), Float(p.y))
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeContact == nil, let touch = touches.min(by: { $0.timestamp < $1.timestamp }) else { return }
        deliver(touch, phase: .started, event: event)
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliverActive(touches, phase: .moved, event: event)
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliverActive(touches, phase: .ended, event: event)
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliverActive(touches, phase: .cancelled, event: event)
    }

    public override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { cancelActiveContact() }
        super.willMove(toWindow: newWindow)
    }

    private func deliverActive(_ touches: Set<UITouch>, phase: TouchPhase, event: UIEvent?) {
        guard let activeContact, let touch = touches.first(where: { Self.contactID($0) == activeContact.id }) else { return }
        deliver(touch, phase: phase, event: event)
    }

    private static func contactID(_ touch: UITouch) -> UInt64 {
        UInt64(UInt(bitPattern: ObjectIdentifier(touch)))
    }

    private func deliver(_ touch: UITouch, phase: TouchPhase, event: UIEvent?) {
        var button: PointerButton?
        if touch.type == .indirectPointer {
            button = .primary
            #if !os(tvOS)
            if let mask = event?.buttonMask {
                if mask.contains(.secondary) { button = .secondary }
                else if mask.contains(.button(3)) { button = .middle }
            }
            #endif
        }
        let eventTime = (touch.timestamp - startTime) * timeScale
        deliverContact(id: Self.contactID(touch), phase: phase, at: point(for: touch), button: button,
                       eventTimestamp: touch.timestamp, time: eventTime)
        invalidateFrame()
    }

    /// Delivers the first contact until its matching release. Indirect pointer buttons use mouse capture.
    internal func deliverContact(id: UInt64, phase: TouchPhase, at point: Vec2, button: PointerButton? = nil,
                                 eventTimestamp: Double?, time: Double) {
        if phase == .started {
            guard activeContact == nil else { return }
            activeContact = (id, button)
        }
        guard let contact = activeContact, contact.id == id else { return }
        if phase == .ended || phase == .cancelled { activeContact = nil }
        runtime.hostInput(.pointer, eventTimestamp: eventTimestamp) {
            if let button = contact.button {
                switch phase {
                case .started:
                    runtime.pointerMove(to: point, at: time)
                    runtime.buttonDown(at: point, button: button, at: time)
                case .moved: runtime.pointerMove(to: point, at: time)
                case .ended: runtime.buttonUp(at: point, button: button, at: time)
                case .cancelled: runtime.cancelPointer(at: time)
                }
            } else {
                runtime.touch(id: id, phase: phase, at: point, time: time)
            }
        }
    }

    fileprivate func cancelActiveContact() {
        guard let contact = activeContact else { return }
        deliverContact(id: contact.id, phase: .cancelled, at: .zero, eventTimestamp: nil, time: nowSeconds())
    }

    #if !os(tvOS)
    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard !runtime.touching() else { return }
        let p = recognizer.location(in: self)
        let pos = Vec2(Float(p.x), Float(p.y))
        runtime.hostInput(.pointer) {
            switch recognizer.state {
            case .began, .changed:
                runtime.pointerMove(to: pos, mods: .none, at: nowSeconds())
            case .ended, .cancelled:
                runtime.pointerExit(at: nowSeconds())
            default:
                break
            }
        }
        invalidateFrame()
    }

    #endif

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let phase: GesturePhase
        switch recognizer.state {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        default: return
        }
        let delta = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        let p = recognizer.location(in: self)
        runtime.hostInput(.wheel) {
            runtime.wheelEvent(WheelEvent(dx: Float(delta.x), dy: Float(delta.y), phase: phase,
                                          x: Float(p.x), y: Float(p.y)), now: nowSeconds())
        }
        invalidateFrame()
    }

    private func unhandledPresses(_ presses: Set<UIPress>, began: Bool, event: UIPressesEvent?) -> Set<UIPress> {
        var unhandled = presses
        let now = nowSeconds()
        for press in presses {
            let flags = press.key?.modifierFlags ?? []
            let mods = Mods(
                shift: flags.contains(.shift),
                ctrl: flags.contains(.control),
                alt: flags.contains(.alternate),
                cmd: flags.contains(.command),
                logo: false
            )
            guard let key = press.key.flatMap(Self.mapUIKey) ?? Self.remoteKey(press.type) else { continue }
            let input = KeyEvent(key: key, mods: mods)
            let handled = runtime.hostInput(began ? .keyPress : .keyRelease, eventTimestamp: event?.timestamp) {
                runtime.dispatchModifiers(mods, at: now)
                return began ? runtime.keyDown(input, at: now) : runtime.keyUp(input, at: now)
            }
            if handled { unhandled.remove(press) }
        }
        if !presses.isEmpty { invalidateFrame() }
        return unhandled
    }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = unhandledPresses(presses, began: true, event: event)
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = unhandledPresses(presses, began: false, event: event)
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }

    private static func remoteKey(_ type: UIPress.PressType) -> Key? {
        switch type {
        case .upArrow: return .arrowUp
        case .downArrow: return .arrowDown
        case .leftArrow: return .arrowLeft
        case .rightArrow: return .arrowRight
        case .select: return .enter
        case .menu: return .escape
        default: return nil
        }
    }

    private static func mapUIKey(_ uiKey: UIKey) -> Key? {
        switch uiKey.keyCode {
        case .keyboardReturnOrEnter, .keypadEnter: return .enter
        case .keyboardTab: return .tab
        case .keyboardEscape: return .escape
        case .keyboardDeleteOrBackspace: return .backspace
        case .keyboardDeleteForward: return .delete
        case .keyboardSpacebar: return .space
        case .keyboardLeftArrow: return .arrowLeft
        case .keyboardRightArrow: return .arrowRight
        case .keyboardUpArrow: return .arrowUp
        case .keyboardDownArrow: return .arrowDown
        case .keyboardHome: return .home
        case .keyboardEnd: return .end
        case .keyboardPageUp: return .pageUp
        case .keyboardPageDown: return .pageDown
        default:
            if uiKey.modifierFlags.contains(.command), uiKey.charactersIgnoringModifiers.count == 1,
               let letter = uiKey.charactersIgnoringModifiers.lowercased().first {
                return .command(letter)
            }
            return uiKey.characters.isEmpty ? nil : .text(uiKey.characters)
        }
    }
}

/// UIKit `UIViewController` driving a `RuneIOSView` via `CADisplayLink`.
@MainActor
public final class RuneIOSViewController<State>: UIViewController {
    public let runeView: RuneIOSView<State>
    private var displayLink: CADisplayLink?

    public init(
        runtime: Runtime<State>,
        timeScale: Double = 1.0,
        respectSystemAppearance: Bool = true,
        backend: GpuBackend = .auto
    ) throws {
        self.runeView = try RuneIOSView(
            frame: .zero,
            runtime: runtime,
            timeScale: timeScale,
            respectSystemAppearance: respectSystemAppearance,
            backend: backend
        )
        super.init(nibName: nil, bundle: nil)
        self.title = runtime.windowTitle
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func loadView() {
        self.view = runeView
    }

    private var scheduledWake: Timer?
    private var appShared: AppShared<State>?
    private var onWindow: ((WindowHandle) -> Void)?
    private var windowHandle: WindowHandle?
    private var observingScene: UIScene?

    fileprivate func configure(_ app: App<State>) {
        appShared = app.sharedHandle.shared
        onWindow = app.onWindowHook
        runeView.compositor = app.compositorValue
        if app.onFrameEncodedHook != nil || app.onFrameDrawnHook != nil || app.onFrameInspectHook != nil {
            runeView.reports = FrameReports(onFrameEncoded: app.onFrameEncodedHook,
                                           onFrameDrawn: app.onFrameDrawnHook, onInspectDrawn: app.onFrameInspectHook)
        }
        if let receiver = app.devStatsReceiver {
            runeView.runtime.surfaceMeter = SurfaceMeter(name: app.title)
            runeView.receiveStats = receiver
        }
        runeView.firstFrame = { [weak self] in
            guard let handle = self?.windowHandle else { return }
            handle.setReady(true)
            app.onReadyHook?(handle)
        }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if windowHandle == nil {
            let handle = WindowHandle(
                title: title ?? "Rune",
                onClose: { [weak self] in Task { @MainActor in self?.requestClose() } },
                onFocus: { [weak self] in Task { @MainActor in self?.view.window?.makeKey() } },
                onSetTitle: { [weak self] title in Task { @MainActor in self?.title = title } }
            )
            windowHandle = handle
            onWindow?(handle)
        }
        runeView.requestFrame = { [weak self] in self?.wake() }
        runeView.frameFinished = { [weak self] active in self?.scheduleNextFrame(active: active) }
        runeView.beforeFrame = { [weak self] now in self?.applyAppRequests(at: now) }
        runeView.runtime.waker.setCallback { [weak self] in
            Task { @MainActor in self?.wake() }
        }
        if let scene = view.window?.windowScene {
            observingScene = scene
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(sceneActivated), name: UIScene.didActivateNotification, object: scene)
            center.addObserver(self, selector: #selector(sceneDeactivated), name: UIScene.willDeactivateNotification, object: scene)
            center.addObserver(self, selector: #selector(sceneHidden), name: UIScene.didEnterBackgroundNotification, object: scene)
        }
        updateVisibility(observingScene?.activationState != .background)
        startDisplayLink()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        runeView.cancelActiveContact()
        runeView.runtime.dispatchFocus(false, at: runeView.nowSeconds())
        updateVisibility(false)
        if let scene = observingScene {
            let center = NotificationCenter.default
            for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
                center.removeObserver(self, name: name, object: scene)
            }
            observingScene = nil
        }
        scheduledWake?.invalidate()
        scheduledWake = nil
        displayLink?.invalidate()
        displayLink = nil
    }

    private func requestClose() {
        guard runeView.runtime.dispatchClose(at: runeView.nowSeconds()) else { return }
        if let navigationController, navigationController.viewControllers.first !== self {
            navigationController.popViewController(animated: true)
        } else if presentingViewController != nil {
            dismiss(animated: true)
        } else if let session = view.window?.windowScene?.session, UIApplication.shared.supportsMultipleScenes {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        }
    }

    private func applyAppRequests(at now: Double) {
        let requests = appShared?.applyStateUpdates(to: runeView.runtime, at: now)
        if requests?.window == .close || runeView.runtime.closeWindowRequested {
            runeView.runtime.clearShellRequests()
            requestClose()
        } else if requests?.activation == .focus {
            view.window?.makeKey()
        }
    }

    private func updateVisibility(_ visible: Bool) {
        runeView.runtime.setLiveVisible(visible, at: runeView.nowSeconds())
        appShared?.setVisible(visible)
    }

    @objc private func sceneActivated() {
        updateVisibility(true)
        runeView.runtime.dispatchFocus(true, at: runeView.nowSeconds())
        wake()
    }

    @objc private func sceneDeactivated() {
        runeView.cancelActiveContact()
        runeView.runtime.dispatchFocus(false, at: runeView.nowSeconds())
        displayLink?.isPaused = true
        scheduledWake?.invalidate()
        scheduledWake = nil
    }

    @objc private func sceneHidden() {
        updateVisibility(false)
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(onDisplayLink(_:)))
        if let scene = observingScene { link.isPaused = scene.activationState != .foregroundActive }
        link.add(to: .main, forMode: .common)
        displayLink = link
        runeView.runtime.dispatchFocus(view.window?.isKeyWindow == true, at: runeView.nowSeconds())
    }

    private func wake() {
        if let scene = observingScene, scene.activationState != .foregroundActive { return }
        scheduledWake?.invalidate()
        scheduledWake = nil
        displayLink?.isPaused = false
    }

    private func scheduleNextFrame(active: Bool) {
        guard let displayLink else { return }
        scheduledWake?.invalidate()
        scheduledWake = nil
        displayLink.isPaused = !active
        guard !active, runeView.timeScale > 0 else { return }
        let now = runeView.nowSeconds()
        let runtime = runeView.runtime
        guard let due = runtime.nextWakeDeadline(after: runtime.currentTime) else { return }
        let delay = max(0, (due - now) / runeView.timeScale)
        let timer = Timer(timeInterval: delay, target: self, selector: #selector(deadlineReached), userInfo: nil, repeats: false)
        scheduledWake = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func deadlineReached() { wake() }

    @objc private func onDisplayLink(_ sender: CADisplayLink) {
        runeView.renderTick()
    }
}
#endif
