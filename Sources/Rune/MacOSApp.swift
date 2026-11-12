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
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        var state = spec.makeState()
        if let sceneName = parsed.sceneName, let apply = spec.scenes[sceneName] {
            var tx = Tx()
            apply(&state, &tx)
        }

        let vp = parsed.viewportOverride ?? spec.size
        let respectSystemAppearance = (parsed.darkOverride == nil && spec.dark == nil)
        let sysDark: Bool
        if let d = parsed.darkOverride ?? spec.dark {
            sysDark = d
        } else {
            let name = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            sysDark = (name == .darkAqua)
        }

        let waker = Waker()
        let runtime = Runtime<State>(
            state: state,
            viewport: vp,
            pixelScale: Float(NSScreen.main?.backingScaleFactor ?? 2.0),
            systemDark: sysDark,
            reducedMotion: parsed.reducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            waker: waker,
            onKey: spec.onKey,
            view: spec.view
        )
        runtime.windowTitle = spec.title

        let renderer = try MetalRenderer()
        let hostView = RuneMetalHostView(
            frame: NSRect(x: 0, y: 0, width: CGFloat(vp.x), height: CGFloat(vp.y)),
            runtime: runtime,
            renderer: renderer,
            timeScale: parsed.timeScale,
            respectSystemAppearance: respectSystemAppearance
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: CGFloat(vp.x), height: CGFloat(vp.y)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let delegate = RuneAppDelegate(
            onFocusChange: { focused in
                runtime.windowFocused = focused
                hostView.requestRender()
            },
            onClose: {
                hostView.stopTimer()
            }
        )
        app.delegate = delegate
        window.delegate = delegate
        window.title = spec.title
        if let minSz = spec.minSize {
            window.contentMinSize = NSSize(width: CGFloat(minSz.x), height: CGFloat(minSz.y))
        }
        window.contentView = hostView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(hostView)

        waker.setCallback { [weak hostView] in
            DispatchQueue.main.async {
                hostView?.requestRender()
            }
        }

        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
private final class RuneAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let onFocusChange: (Bool) -> Void
    private let onClose: () -> Void

    init(onFocusChange: @escaping (Bool) -> Void, onClose: @escaping () -> Void) {
        self.onFocusChange = onFocusChange
        self.onClose = onClose
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
    private var animTimer: Timer?
    private var trackingAreaRef: NSTrackingArea?

    init(frame: NSRect, runtime: Runtime<State>, renderer: MetalRenderer, timeScale: Double, respectSystemAppearance: Bool) {
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

    private func renderTick() {
        guard bounds.width > 0 && bounds.height > 0 else { return }
        let t = nowSeconds()
        let refScene = runtime.frame(at: t)
        if let title = runtime.windowTitle, window?.title != title {
            window?.title = title
        }
        if runtime.quitRequested {
            NSApplication.shared.terminate(nil)
            return
        }
        if let drawable = metalLayer.nextDrawable() {
            renderer.render(scene: refScene, to: drawable)
        }
        if runtime.isAnimating {
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
