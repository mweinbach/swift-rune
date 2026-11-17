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
        let controller = try makeViewController(spec, parsed: parsed)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            window.rootViewController = controller
            window.makeKeyAndVisible()
        }
    }

    @MainActor
    public static func makeViewController<State>(
        _ spec: AppSpec<State>,
        parsed: ToolingArgs = ToolingArgs.parse([])
    ) throws -> RuneIOSViewController<State> {
        HeadlessRunner.registerFonts(spec.fonts)
        var state = spec.makeState()
        var initTx = Tx()
        if let sceneName = parsed.sceneName, let apply = spec.scenes[sceneName] {
            apply(&state, &initTx)
        }
        let screenScale = Float(UIScreen.main.scale)
        let bounds = UIScreen.main.bounds.size
        let vp = parsed.viewportOverride ?? Vec2(Float(bounds.width), Float(bounds.height))
        let isDark = parsed.darkOverride ?? spec.dark ?? (UITraitCollection.current.userInterfaceStyle == .dark)

        let waker = Waker()
        spec.setup?(waker)
        let runtime = Runtime<State>(
            state: state,
            viewport: vp,
            pixelScale: max(1.0, screenScale),
            systemDark: isDark,
            reducedMotion: parsed.reducedMotion || UIAccessibility.isReduceMotionEnabled,
            waker: waker,
            onKey: spec.onKey,
            view: spec.view
        )
        runtime.windowTitle = spec.title
        runtime.srgbBlend = spec.srgbBlend
        runtime.poll = spec.poll
        runtime.onAppFileDrop = spec.onFileDrop
        runtime.onFileDrop = spec.onFileDropPhase
        runtime.readSystemContrastSettings()
        runtime.applyTx(initTx, at: 0.0, markDirtyIfNotLiveOnly: false)

        return try RuneIOSViewController(
            runtime: runtime,
            timeScale: parsed.timeScale,
            respectSystemAppearance: (parsed.darkOverride == nil && spec.dark == nil)
        )
    }
}

/// UIKit view hosting a `Rune` runtime via `CAMetalLayer` (`MetalRenderer`) with `RuneRef` fallback.
@MainActor
public final class RuneIOSView<State>: UIView, UIKeyInput {
    public let runtime: Runtime<State>
    private let timeScale: Double
    private let respectSystemAppearance: Bool
    private let startTime: TimeInterval
    private var activeContact: (id: UInt64, button: PointerButton?)?
    private var didSignalReady = false

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
        respectSystemAppearance: Bool = true
    ) throws {
        self.runtime = runtime
        self.timeScale = timeScale
        self.respectSystemAppearance = respectSystemAppearance
        self.startTime = ProcessInfo.processInfo.systemUptime
        #if canImport(Metal)
        self.metalRenderer = try? MetalRenderer()
        #endif
        super.init(frame: frame)
        self.isMultipleTouchEnabled = true
        self.contentScaleFactor = CGFloat(runtime.pixelScale)

        #if canImport(Metal) && canImport(QuartzCore)
        if let metalLayer = self.layer as? CAMetalLayer, let gpu = metalRenderer {
            metalLayer.device = gpu.device
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = true
            metalLayer.contentsScale = CGFloat(runtime.pixelScale)
        }
        #endif

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)

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

    public var hasText: Bool { true }

    public func insertText(_ text: String) {
        let now = nowSeconds()
        runtime.hostInput(.keyPress) {
            for scalar in text {
                let key: Key = (scalar == "\n" || scalar == "\r") ? .enter : (scalar == "\t" ? .tab : .text(String(scalar)))
                _ = runtime.keyDown(KeyEvent(key: key), at: now)
            }
        }
        renderTick()
    }

    public func deleteBackward() {
        _ = runtime.hostInput(.keyPress) { runtime.keyDown(KeyEvent(key: .backspace), at: nowSeconds()) }
        renderTick()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let scale = Float(max(1.0, window?.screen.scale ?? UIScreen.main.scale))
        let size = Vec2(Float(bounds.width), Float(bounds.height))
        if size.x > 0 && size.y > 0 {
            runtime.viewport = size
            runtime.pixelScale = scale
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
        }
    }

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        renderTick()
    }

    public func syncAppearance() {
        guard respectSystemAppearance else { return }
        runtime.systemDark = (traitCollection.userInterfaceStyle == .dark)
        renderTick()
    }

    public func renderTick() {
        let scene = runtime.frame(at: nowSeconds())
        #if canImport(Metal) && canImport(QuartzCore)
        if let metalLayer = self.layer as? CAMetalLayer,
           let gpu = metalRenderer,
           let drawable = metalLayer.nextDrawable() {
            gpu.render(scene: scene, to: drawable)
            if !didSignalReady {
                didSignalReady = true
                ReadySignal.ready()
            }
            return
        }
        #endif

        if let frame = try? RuneRef.render(scene),
           let cgImage = makeCGImage(from: frame) {
            layer.contents = cgImage
        }
        if !didSignalReady {
            didSignalReady = true
            ReadySignal.ready()
        }
    }

    private func makeCGImage(from frame: Frame) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
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

    private func nowSeconds() -> Double {
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
        renderTick()
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
        renderTick()
    }

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
        renderTick()
    }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        let now = nowSeconds()
        for press in presses {
            guard let uiKey = press.key else { continue }
            let mods = Mods(
                shift: uiKey.modifierFlags.contains(.shift),
                ctrl: uiKey.modifierFlags.contains(.control),
                alt: uiKey.modifierFlags.contains(.alternate),
                cmd: uiKey.modifierFlags.contains(.command),
                logo: false
            )
            if let mapped = Self.mapUIKey(uiKey) {
                if runtime.hostInput(.keyPress, eventTimestamp: event?.timestamp, { runtime.keyDown(KeyEvent(key: mapped, mods: mods), at: now) }) {
                    handled = true
                }
            }
        }
        if handled {
            renderTick()
        } else {
            super.pressesBegan(presses, with: event)
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
            if !uiKey.charactersIgnoringModifiers.isEmpty {
                return .text(uiKey.charactersIgnoringModifiers)
            }
            return nil
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
        respectSystemAppearance: Bool = true
    ) throws {
        self.runeView = try RuneIOSView(
            frame: .zero,
            runtime: runtime,
            timeScale: timeScale,
            respectSystemAppearance: respectSystemAppearance
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

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startDisplayLink()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        runeView.cancelActiveContact()
        displayLink?.invalidate()
        displayLink = nil
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(onDisplayLink(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func onDisplayLink(_ sender: CADisplayLink) {
        _ = MainQueueDispatcher.shared.drain()
        runeView.renderTick()
    }
}
#endif
