import Foundation
import RuneMotion
import RuneRef

#if os(macOS)
import AppKit
import Metal
import QuartzCore

// MARK: - Shared NSEvent -> Rune Input Bridge

enum RuneNSEventBridge {
    static func mods(for event: NSEvent) -> Mods {
        let f = event.modifierFlags
        return Mods(
            shift: f.contains(.shift),
            ctrl: f.contains(.control),
            alt: f.contains(.option),
            cmd: f.contains(.command),
            logo: f.contains(.command)
        )
    }

    @MainActor
    static func localPoint(in view: NSView, from event: NSEvent) -> Vec2 {
        let p = view.convert(event.locationInWindow, from: nil)
        return Vec2(Float(p.x), Float(p.y))
    }

    static func pointerButton(from event: NSEvent) -> PointerButton {
        switch event.buttonNumber {
        case 0: return .primary
        case 1: return .secondary
        default: return .middle
        }
    }

    static func makeKeyEvent(from event: NSEvent, includeModifierKeys: Bool = false) -> KeyEvent? {
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
            } else if includeModifierKeys {
                key = .text("")
            } else {
                return nil
            }
        }
        return KeyEvent(key: key, mods: m)
    }
}

// MARK: - Hit Region Filtering (`platform/macos/pointer.rs`)

public struct RuneOverlayHitTester: Sendable {
    public var input: OverlayInput
    public var interactive: Bool
    public var regions: [MotionRect]

    public init(input: OverlayInput = .legacy, interactive: Bool = false, regions: [MotionRect] = []) {
        self.input = input
        self.interactive = interactive
        self.regions = regions
    }

    public var resolvedInput: OverlayInput {
        input.resolved(interactive: interactive)
    }

    public func shouldIntercept(at point: Vec2) -> Bool {
        switch resolvedInput {
        case .none, .legacy:
            return resolvedInput == .all
        case .all:
            return true
        case .regions:
            return regions.contains { rect in
                point.x >= rect.x &&
                    point.y >= rect.y &&
                    point.x < rect.x + rect.width &&
                    point.y < rect.y + rect.height
            }
        }
    }
}

// MARK: - Overlay NSPanel (`RuneOverlayPanel`)

/// Floating overlay `NSPanel` with configurable key focus and occlusion override (`platform/macos.rs`).
public final class RuneOverlayPanel: NSPanel {
    public var allowsKeyFocus: Bool = false
    public var drawsOccludedOverride: Bool = false

    override public var canBecomeKey: Bool {
        allowsKeyFocus
    }

    override public var canBecomeMain: Bool {
        false
    }

    override public func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override public var occlusionState: NSWindow.OcclusionState {
        if drawsOccludedOverride {
            return .visible
        }
        return super.occlusionState
    }
}

// MARK: - Metal Content View (`RuneOverlayMetalView`)

@MainActor
public final class RuneOverlayMetalView<State>: NSView {
    private let metalLayer = CAMetalLayer()
    private var renderer: MetalRenderer?
    private let startTime = CACurrentMediaTime()
    private var trackingAreaRef: NSTrackingArea?
    private var frameCounter: UInt64 = 0

    public var hitTester = RuneOverlayHitTester()
    public var includeModifierKeys: Bool = false

    var onEvaluateFrame: ((_ nowSeconds: Double, _ settle: Bool) -> (scene: RefScene, regions: [MotionRect], isAnimating: Bool, srgbBlend: Bool))?
    var onPointerMove: ((_ point: Vec2, _ mods: Mods, _ nowSeconds: Double) -> Void)?
    var onPointerExit: ((_ nowSeconds: Double) -> Void)?
    var onPointerDown: ((_ point: Vec2, _ button: PointerButton, _ mods: Mods, _ nowSeconds: Double) -> Void)?
    var onPointerUp: ((_ point: Vec2, _ button: PointerButton, _ mods: Mods, _ nowSeconds: Double) -> Void)?
    var onWheel: ((_ event: WheelEvent, _ point: Vec2, _ nowSeconds: Double) -> Void)?
    var onKeyDown: ((_ event: KeyEvent, _ nowSeconds: Double) -> Bool)?
    var onAppearanceChanged: ((_ isDark: Bool) -> Void)?
    var onNeedsResyncGeometry: ((_ width: Float, _ height: Float, _ scale: Float) -> Void)?
    var onFailure: ((_ message: String) -> Void)?
    weak var pointerState: OverlayPointerState?
    var onRegionsUpdated: (([MotionRect]) -> Void)?
    var onSyncPassthrough: (() -> Void)?

    public init(frame: NSRect, srgbBlend: Bool = true) {
        super.init(frame: frame)
        self.wantsLayer = true
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        do {
            let r = try MetalRenderer()
            self.renderer = r
            metalLayer.device = r.device
        } catch {
            self.renderer = nil
            self.layer = metalLayer
            onFailure?("overlay MetalRenderer init failed: \(error.localizedDescription)")
            return
        }
        self.layer = metalLayer
        _ = srgbBlend
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public var hasRenderer: Bool { renderer != nil }

    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { true }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        guard hitTester.shouldIntercept(at: Vec2(Float(local.x), Float(local.y))) else {
            return nil
        }
        return super.hitTest(point)
    }

    override public func updateTrackingAreas() {
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

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncDrawableGeometry()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableGeometry()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let name = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        onAppearanceChanged?(name == .darkAqua)
    }

    public func syncDrawableGeometry() {
        let scale = Float(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        let w = Float(max(1, bounds.width))
        let h = Float(max(1, bounds.height))
        metalLayer.contentsScale = CGFloat(scale)
        metalLayer.drawableSize = CGSize(width: CGFloat(w * scale), height: CGFloat(h * scale))
        onNeedsResyncGeometry?(w, h, scale)
    }

    public func nowSeconds() -> Double {
        CACurrentMediaTime() - startTime
    }

    @discardableResult
    public func renderFrame(settle: Bool = false, visible: Bool = true, drawing: Bool = true) -> OverlaySurfaceSnapshot {
        let scale = Float(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        let w = Float(max(1, bounds.width))
        let h = Float(max(1, bounds.height))
        metalLayer.contentsScale = CGFloat(scale)
        let pxW = max(1, Int((w * scale).rounded()))
        let pxH = max(1, Int((h * scale).rounded()))
        if Int(metalLayer.drawableSize.width) != pxW || Int(metalLayer.drawableSize.height) != pxH {
            metalLayer.drawableSize = CGSize(width: pxW, height: pxH)
        }

        guard let eval = onEvaluateFrame else {
            return OverlaySurfaceSnapshot(
                frameCount: frameCounter,
                pixelWidth: pxW,
                pixelHeight: pxH,
                backingScale: scale,
                srgbBlend: true,
                isVisible: visible,
                isDrawing: drawing,
                isAnimating: false
            )
        }

        let result = eval(nowSeconds(), settle)
        hitTester.regions = result.regions
        pointerState?.regions = result.regions
        onRegionsUpdated?(result.regions)

        if let renderer, bounds.width > 0, bounds.height > 0, let drawable = metalLayer.nextDrawable() {
            renderer.render(scene: result.scene, to: drawable)
        }
        frameCounter &+= 1
        return OverlaySurfaceSnapshot(
            frameCount: frameCounter,
            pixelWidth: pxW,
            pixelHeight: pxH,
            backingScale: scale,
            srgbBlend: result.srgbBlend,
            isVisible: visible,
            isDrawing: drawing,
            isAnimating: result.isAnimating
        )
    }

    public func releaseGpuResources() {
        renderer = nil
        metalLayer.device = nil
        metalLayer.sublayers = nil
    }

    override public func mouseMoved(with event: NSEvent) {
        let now = nowSeconds()
        let m = RuneNSEventBridge.mods(for: event)
        if let lost = pointerState?.takeLostBeforePosition() {
            onPointerUp?(lost, .primary, m, now)
        }
        onPointerMove?(RuneNSEventBridge.localPoint(in: self, from: event), m, now)
    }

    override public func mouseExited(with event: NSEvent) {
        onPointerExit?(nowSeconds())
    }

    override public func mouseDragged(with event: NSEvent) {
        let now = nowSeconds()
        let m = RuneNSEventBridge.mods(for: event)
        if let lost = pointerState?.takeLostBeforePosition() {
            onPointerUp?(lost, .primary, m, now)
        }
        onPointerMove?(RuneNSEventBridge.localPoint(in: self, from: event), m, now)
    }

    override public func rightMouseDragged(with event: NSEvent) {
        onPointerMove?(RuneNSEventBridge.localPoint(in: self, from: event), RuneNSEventBridge.mods(for: event), nowSeconds())
    }

    override public func otherMouseDragged(with event: NSEvent) {
        onPointerMove?(RuneNSEventBridge.localPoint(in: self, from: event), RuneNSEventBridge.mods(for: event), nowSeconds())
    }

    override public func mouseDown(with event: NSEvent) {
        let now = nowSeconds()
        let m = RuneNSEventBridge.mods(for: event)
        let local = RuneNSEventBridge.localPoint(in: self, from: event)
        let edge = pointerState?.takeEdge(down: true)
        if let lost = edge?.lostRelease {
            onPointerUp?(lost, .primary, m, now)
        }
        onPointerDown?(edge?.point ?? local, .primary, m, now)
        onSyncPassthrough?()
    }

    override public func mouseUp(with event: NSEvent) {
        let now = nowSeconds()
        let m = RuneNSEventBridge.mods(for: event)
        let local = RuneNSEventBridge.localPoint(in: self, from: event)
        let edge = pointerState?.takeEdge(down: false)
        if let lost = edge?.lostRelease {
            onPointerUp?(lost, .primary, m, now)
        }
        onPointerUp?(edge?.point ?? local, .primary, m, now)
        pointerState?.released()
        onSyncPassthrough?()
    }

    override public func rightMouseDown(with event: NSEvent) {
        onPointerDown?(
            RuneNSEventBridge.localPoint(in: self, from: event),
            .secondary,
            RuneNSEventBridge.mods(for: event),
            nowSeconds()
        )
    }

    override public func rightMouseUp(with event: NSEvent) {
        onPointerUp?(
            RuneNSEventBridge.localPoint(in: self, from: event),
            .secondary,
            RuneNSEventBridge.mods(for: event),
            nowSeconds()
        )
    }

    override public func otherMouseDown(with event: NSEvent) {
        onPointerDown?(
            RuneNSEventBridge.localPoint(in: self, from: event),
            .middle,
            RuneNSEventBridge.mods(for: event),
            nowSeconds()
        )
    }

    override public func otherMouseUp(with event: NSEvent) {
        onPointerUp?(
            RuneNSEventBridge.localPoint(in: self, from: event),
            .middle,
            RuneNSEventBridge.mods(for: event),
            nowSeconds()
        )
    }

    override public func scrollWheel(with event: NSEvent) {
        let mult: Float = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
        let wev = WheelEvent(
            dx: Float(event.scrollingDeltaX) * mult,
            dy: Float(event.scrollingDeltaY) * mult,
            precise: event.hasPreciseScrollingDeltas,
            mods: RuneNSEventBridge.mods(for: event)
        )
        onWheel?(wev, RuneNSEventBridge.localPoint(in: self, from: event), nowSeconds())
    }

    override public func keyDown(with event: NSEvent) {
        if let kev = RuneNSEventBridge.makeKeyEvent(from: event, includeModifierKeys: includeModifierKeys),
           onKeyDown?(kev, nowSeconds()) == true {
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - macOS Overlay Host Controller (`platform/macos.rs`, `platform/macos/presentation.rs`)

@MainActor
public final class RuneOverlayMacOSHost<State> {
    public private(set) var panel: RuneOverlayPanel?
    public private(set) var metalView: RuneOverlayMetalView<State>?
    public private(set) var presence: MacOSPanelPresence
    public private(set) var lastDisplayId: UInt32?
    public private(set) var capabilities: OverlayCapabilities
    public private(set) var surfaceDescription: String?
    public let pointerState = OverlayPointerState()

    private var frameTimer: Timer?
    private var holdDeadlineTimer: Timer?
    private nonisolated(unsafe) var globalMouseMonitor: Any?
    private nonisolated(unsafe) var localMouseMonitor: Any?

    public var resolvedPlacementSize: Vec2
    public var overlayPlacement: OverlayGeometry.Placement
    public var options: OverlayOptions
    public var releaseWhenHidden: Bool
    public var onCreated: ((OverlayCreated) -> Void)?
    public var onFailure: ((String) -> Void)?
    public var onSurfaceSnapshot: ((OverlaySurfaceSnapshot) -> Void)?
    public var onFadeCompleted: ((_ visible: Bool, _ ordered: Bool) -> Void)?
    public var onPanelStateChanged: ((_ windowNumber: UInt32?, _ capabilities: OverlayCapabilities) -> Void)?
    public var configureView: ((RuneOverlayMetalView<State>) -> Void)?
    public var shouldKeepDrawing: (() -> Bool)?

    public init(
        size: Vec2,
        placement: OverlayGeometry.Placement,
        options: OverlayOptions,
        releaseWhenHidden: Bool
    ) {
        self.resolvedPlacementSize = size
        self.overlayPlacement = placement
        self.options = options
        self.releaseWhenHidden = releaseWhenHidden
        self.presence = MacOSPanelPresence(requested: options.excludeFromCapture)
        self.capabilities = OverlayCapabilities(
            captureExclusion: options.excludeFromCapture ? .requested : .supported,
            nonactivatingKeys: .supported,
            globalPointer: .supported
        )
    }

    deinit {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    public var windowNumber: UInt32? {
        guard let panel else { return nil }
        let n = panel.windowNumber
        return n > 0 ? UInt32(n) : nil
    }

    public func ensurePanel() -> (RuneOverlayPanel, RuneOverlayMetalView<State>)? {
        if let panel, let metalView {
            return (panel, metalView)
        }
        let targetFrame = computeScreenRect() ?? NSRect(
            x: 0,
            y: 0,
            width: CGFloat(max(1, resolvedPlacementSize.x)),
            height: CGFloat(max(1, resolvedPlacementSize.y))
        )
        let styleMask: NSWindow.StyleMask = options.keyPolicy == .activating
            ? [.borderless]
            : [.nonactivatingPanel, .borderless]
        let p = RuneOverlayPanel(
            contentRect: targetFrame,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        p.allowsKeyFocus = (options.keyPolicy == .activating)
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = (options.keyPolicy == .nonActivating)
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        p.level = NSWindow.Level(rawValue: resolvedMacOSLevel())
        p.isReleasedWhenClosed = false
        p.sharingType = presence.isExcluded ? .none : .readOnly

        let view = RuneOverlayMetalView<State>(
            frame: NSRect(origin: .zero, size: targetFrame.size),
            srgbBlend: options.srgbBlend
        )
        view.includeModifierKeys = options.modifierKeys
        view.hitTester.input = options.input
        view.hitTester.interactive = options.interactive
        view.pointerState = pointerState
        pointerState.input = options.input
        pointerState.interactive = options.interactive
        pointerState.followPointer = options.followPointer
        view.onRegionsUpdated = { [weak self] _ in
            self?.syncMousePassthrough()
        }
        view.onSyncPassthrough = { [weak self] in
            self?.syncMousePassthrough()
            self?.installMouseMonitorsIfNeeded()
        }
        view.onFailure = { [weak self] msg in
            self?.onFailure?(msg)
        }
        configureView?(view)

        p.contentView = view
        p.setFrame(targetFrame, display: false)
        view.syncDrawableGeometry()

        self.panel = p
        self.metalView = view
        let deviceName = MTLCreateSystemDefaultDevice()?.name ?? "Metal"
        self.surfaceDescription = "macOS NSPanel Metal (\(deviceName))"
        capabilities = OverlayCapabilities(
            captureExclusion: presence.requested ? .requested : .supported,
            nonactivatingKeys: .supported,
            globalPointer: .supported
        )
        onCreated?(OverlayCreated(windowNumber: windowNumber, capabilities: capabilities))
        onPanelStateChanged?(windowNumber, capabilities)
        syncMousePassthrough()
        return (p, view)
    }

    public func prewarm() {
        guard ensurePanel() != nil else { return }
        placePanel()
        carryOut(presence.step(.prewarmBegins))
        if let view = metalView {
            let snap = view.renderFrame(settle: true, visible: false, drawing: true)
            onSurfaceSnapshot?(snap)
        }
        carryOut(presence.step(.prewarmEnds))
    }

    public func show(fadeSeconds: Double, settleBeforeReveal: Bool) {
        let wasFadingOut = !presence.isVisible && presence.isOrdered
        guard ensurePanel() != nil else { return }
        placePanel()
        if !wasFadingOut, let view = metalView {
            let snap = view.renderFrame(settle: settleBeforeReveal, visible: true, drawing: true)
            onSurfaceSnapshot?(snap)
        }
        carryOut(presence.step(.show(fadeSeconds: fadeSeconds)))
        syncMousePassthrough()
        installMouseMonitorsIfNeeded()
        scheduleFrameLoopIfNeeded()
    }

    public func hide(fadeSeconds: Double) {
        removeMouseMonitors()
        if panel == nil {
            _ = presence.step(.hide(fadeSeconds: fadeSeconds))
            stopFrameLoop()
            return
        }
        carryOut(presence.step(.hide(fadeSeconds: fadeSeconds)))
        if !presence.isOrdered {
            stopFrameLoop()
            if releaseWhenHidden {
                releasePanel()
            }
        }
    }

    public func releasePanel() {
        stopFrameLoop()
        removeMouseMonitors()
        pointerState.stopped()
        metalView?.releaseGpuResources()
        panel?.allowsKeyFocus = (options.keyPolicy == .activating)
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        metalView = nil
        onPanelStateChanged?(nil, capabilities)
    }

    public func requestKeys() {
        guard options.keyPolicy != .none, let panel else { return }
        panel.allowsKeyFocus = true
        panel.makeKey()
    }

    public func setCaptureExclusion(_ exclude: Bool) {
        carryOut(presence.step(.request(exclude: exclude)))
        capabilities.captureExclusion = exclude ? .requested : .supported
        onPanelStateChanged?(windowNumber, capabilities)
    }

    public func setMacosLevel(_ level: Int) {
        options.macosLevel = level
        panel?.level = NSWindow.Level(rawValue: resolvedMacOSLevel())
    }

    public func updatePlacement(_ placement: OverlayGeometry.Placement, options: OverlayOptions) {
        self.overlayPlacement = placement
        self.resolvedPlacementSize = placement.size
        self.options = options
        if let panel {
            panel.allowsKeyFocus = (options.keyPolicy == .activating)
        }
        pointerState.input = options.input
        pointerState.interactive = options.interactive
        pointerState.followPointer = options.followPointer
        if let view = metalView {
            view.includeModifierKeys = options.modifierKeys
            view.hitTester.input = options.input
            view.hitTester.interactive = options.interactive
        }
        panel?.level = NSWindow.Level(rawValue: resolvedMacOSLevel())
        placePanel()
        syncMousePassthrough()
        if presence.isVisible {
            installMouseMonitorsIfNeeded()
        }
    }

    public func placePanel() {
        guard let panel, let rect = computeScreenRect() else { return }
        if panel.frame != rect {
            panel.setFrame(rect, display: true)
            metalView?.setFrameSize(rect.size)
        }
    }

    public func syncMousePassthrough() {
        guard let panel, let view = metalView else { return }
        switch view.hitTester.resolvedInput {
        case .none, .legacy:
            panel.ignoresMouseEvents = true
        case .all:
            panel.ignoresMouseEvents = !presence.isVisible
        case .regions:
            guard presence.isVisible else {
                panel.ignoresMouseEvents = true
                return
            }
            let mouse = NSEvent.mouseLocation
            let frame = panel.frame
            let localX = Float(mouse.x - frame.origin.x)
            let localY = Float(frame.origin.y + frame.size.height - mouse.y)
            let inside = frame.contains(mouse)
            let hit = (inside || pointerState.isCaptured) && pointerState.hit(Vec2(localX, localY))
            panel.ignoresMouseEvents = !hit
        }
    }

    private func resolvedMacOSLevel() -> Int {
        if let explicit = options.macosLevel {
            return explicit + options.levelOffset
        }
        return options.level.macosWindowLevel + options.levelOffset
    }

    private func computeScreenRect() -> NSRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let mouse = NSEvent.mouseLocation
        let target: NSScreen? = {
            switch options.display {
            case .primary:
                return screens.first
            case .index(let idx):
                return screens.indices.contains(idx) ? screens[idx] : screens.first
            case .named(let name):
                return screens.first(where: { $0.localizedName == name }) ?? screens.first
            case .underPointer:
                return screens.first(where: { Self.containsAppKitPoint($0.frame, point: mouse) })
                    ?? screens.first(where: { lastDisplayId == Self.screenId($0) })
                    ?? screens.first
            case let .id(displayId):
                if case let .macOS(native) = displayId.native {
                    return screens.first(where: { Self.screenId($0) == native }) ?? screens.first
                }
                return screens.first
            case let .native(native):
                if case let .macOS(id) = native {
                    return screens.first(where: { Self.screenId($0) == id }) ?? screens.first
                }
                return screens.first
            }
        }()

        guard let screen = target else { return nil }
        lastDisplayId = Self.screenId(screen)
        let frame = screen.frame
        let local = OverlayGeometry.localRect(
            at: overlayPlacement,
            placement: options.placement,
            area: Vec2(Float(frame.size.width), Float(frame.size.height))
        )
        let appKit = OverlayGeometry.appKitFrame(
            localRect: local,
            screenOrigin: (Double(frame.origin.x), Double(frame.origin.y)),
            screenSize: (Double(frame.size.width), Double(frame.size.height))
        )
        return NSRect(x: appKit.x, y: appKit.y, width: appKit.width, height: appKit.height)
    }

    private static func screenId(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private static func containsAppKitPoint(_ rect: NSRect, point: NSPoint) -> Bool {
        point.x >= rect.origin.x &&
            point.x < rect.origin.x + rect.size.width &&
            point.y > rect.origin.y &&
            point.y <= rect.origin.y + rect.size.height
    }

    private func carryOut(_ effects: [MacOSPanelPresence.Effect]) {
        guard let panel else { return }
        for effect in effects {
            switch effect {
            case let .setSharing(exclude):
                panel.sharingType = exclude ? .none : .readOnly
            case .rejoinSpaces:
                rejoinSpaces(panel)
            case let .orderIn(clearAlpha):
                if !panel.isVisible {
                    if clearAlpha { panel.alphaValue = 0 }
                    panel.orderFrontRegardless()
                }
            case .orderOut:
                panel.orderOut(nil)
                panel.allowsKeyFocus = (options.keyPolicy == .activating)
                pointerState.stopped()
            case let .setAlpha(alpha):
                panel.alphaValue = CGFloat(alpha)
            case .ignoreMouse:
                panel.ignoresMouseEvents = true
            case let .drawOccluded(on):
                presence = presence.withDrawsOccluded(on)
                panel.drawsOccludedOverride = on
            case let .fade(alpha, overSeconds, fence):
                runFade(panel: panel, alpha: alpha, overSeconds: overSeconds, fence: fence)
            case .resignKey:
                panel.resignKey()
            }
        }
    }

    private func rejoinSpaces(_ panel: RuneOverlayPanel) {
        let behavior = panel.collectionBehavior
        guard behavior.contains(.canJoinAllSpaces) else { return }
        if panel.isVisible {
            if panel.isOnActiveSpace { return }
            panel.orderOut(nil)
        }
        panel.collectionBehavior = []
        panel.collectionBehavior = behavior
    }

    private func runFade(
        panel: RuneOverlayPanel,
        alpha: Double,
        overSeconds: Double?,
        fence: FenceAttempt?
    ) {
        guard let duration = overSeconds, duration > 0, let fence else {
            panel.alphaValue = CGFloat(alpha)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            panel.animator().alphaValue = CGFloat(alpha)
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let followUp = self.presence.step(.fadeEnded(fence: fence))
                self.carryOut(followUp)
                self.onFadeCompleted?(self.presence.isVisible, self.presence.isOrdered)
                if !self.presence.isOrdered {
                    self.panel?.allowsKeyFocus = (self.options.keyPolicy == .activating)
                    self.pointerState.stopped()
                    self.stopFrameLoop()
                    if self.releaseWhenHidden {
                        self.releasePanel()
                    }
                }
            }
        })
    }

    private func installMouseMonitorsIfNeeded() {
        let needsRegionsMonitor = pointerState.resolvedInput == .regions || pointerState.isCaptured
        let needsFollow = options.followPointer && options.display == .underPointer
        guard needsRegionsMonitor || needsFollow else {
            removeMouseMonitors()
            return
        }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseDown,
            .leftMouseUp,
        ]
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                let eventType = event.type
                let isTargetWindow = event.window === self?.panel
                let locationInWindow = event.locationInWindow
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if isTargetWindow && (eventType == .leftMouseDown || eventType == .leftMouseUp),
                       let panel = self.panel {
                        let local = Vec2(
                            Float(locationInWindow.x),
                            Float(panel.frame.size.height - locationInWindow.y)
                        )
                        self.pointerState.recordClick(down: eventType == .leftMouseDown, at: local)
                    }
                    self.handlePointerSample()
                }
                return event
            }
        }
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handlePointerSample()
                }
            }
        }
    }

    private func removeMouseMonitors() {
        holdDeadlineTimer?.invalidate()
        holdDeadlineTimer = nil
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
    }

    private func handlePointerSample() {
        if options.followPointer && options.display == .underPointer {
            placePanel()
        }
        if let panel, let view = metalView, presence.isVisible {
            let mouse = NSEvent.mouseLocation
            let frame = panel.frame
            let local = Vec2(
                Float(mouse.x - frame.origin.x),
                Float(frame.origin.y + frame.size.height - mouse.y)
            )
            let inside = Self.containsAppKitPoint(frame, point: mouse)
            let now = CACurrentMediaTime()
            _ = pointerState.read(
                buttons: UInt(NSEvent.pressedMouseButtons),
                now: now,
                at: local,
                inside: inside
            )
            if let lost = pointerState.takeLostBeforePosition() {
                view.onPointerUp?(lost, .primary, .none, view.nowSeconds())
            }
            if let due = pointerState.deadline {
                scheduleHoldDeadlineTimer(until: due)
            } else {
                holdDeadlineTimer?.invalidate()
                holdDeadlineTimer = nil
            }
        }
        syncMousePassthrough()
        installMouseMonitorsIfNeeded()
    }

    private func scheduleHoldDeadlineTimer(until due: Double) {
        holdDeadlineTimer?.invalidate()
        let delay = max(0.005, due - CACurrentMediaTime())
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePointerSample()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdDeadlineTimer = timer
    }

    private func scheduleFrameLoopIfNeeded() {
        guard frameTimer == nil, presence.isOrdered else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let view = self.metalView else { return }
                guard self.presence.isOrdered else {
                    self.stopFrameLoop()
                    return
                }
                self.handlePointerSample()
                if self.shouldKeepDrawing?() == true || view.hitTester.resolvedInput == .regions || self.pointerState.isCaptured {
                    let snap = view.renderFrame(
                        settle: false,
                        visible: self.presence.isVisible,
                        drawing: self.presence.isOrdered
                    )
                    self.onSurfaceSnapshot?(snap)
                    self.syncMousePassthrough()
                    if !snap.isAnimating && self.shouldKeepDrawing?() == false && !self.pointerState.isCaptured {
                        self.stopFrameLoop()
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func stopFrameLoop() {
        holdDeadlineTimer?.invalidate()
        holdDeadlineTimer = nil
        frameTimer?.invalidate()
        frameTimer = nil
    }
}
#endif
