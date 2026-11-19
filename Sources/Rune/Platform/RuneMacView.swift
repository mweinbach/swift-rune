import Foundation
import RuneMotion
import RuneRef

#if os(macOS)
import AppKit

/// Embeddable AppKit view hosting a full `Rune` runtime with Metal rendering,
/// mouse/trackpad/keyboard input, `NSTextInputClient` IME, VoiceOver accessibility,
/// drag-and-drop, native cursors, tooltips, and dynamic Light/Dark appearance.
///
/// Use `RuneMacView` or `MacOSApp.makeView(_:)` to embed Rune UI elements directly
/// inside an existing AppKit `NSWindow`, `NSViewController`, or SwiftUI view hierarchy
/// without taking over `NSApplication`.
@MainActor
public final class RuneMacView<State>: NSView {
    public let runtime: Runtime<State>
    private let hostView: RuneMetalHostView<State>
    private let preferredSize: Vec2
    private var keyObservers: [NSObjectProtocol] = []
    private var systemObserver: MacOSSystemObserver?

    /// Creates an embeddable AppKit view from an `AppSpec`.
    public convenience init(
        spec: AppSpec<State>,
        frame: NSRect = .zero,
        parsed: ToolingArgs = ToolingArgs.parse([])
    ) throws {
        var app = App<State>(
            title: spec.title,
            size: spec.size,
            minSize: spec.minSize,
            dark: spec.dark,
            state: spec.makeState(),
            view: spec.view
        )
        app.scenes = spec.scenes
        app.fontData = spec.fonts
        app.fontFamilies = spec.families
        app.setupHook = spec.setup
        app.pollHook = spec.poll
        app.onKeyHook = spec.onKey
        app.srgbBlendEnabled = spec.srgbBlend
        try self.init(app: app, frame: frame, parsed: parsed, onFileDrop: spec.onFileDrop, onFileDropPhase: spec.onFileDropPhase)
    }

    /// Creates an embeddable AppKit view from a configured `App`.
    public convenience init(
        app: App<State>,
        frame: NSRect = .zero,
        parsed: ToolingArgs = ToolingArgs.parse([])
    ) throws {
        try self.init(app: app, frame: frame, parsed: parsed, onFileDrop: nil, onFileDropPhase: nil)
    }

    private init(
        app appBuilder: App<State>,
        frame: NSRect,
        parsed: ToolingArgs,
        onFileDrop: ((inout State, [URL], inout Tx) -> Void)?,
        onFileDropPhase: ((inout State, FileDropPhase, inout Tx) -> Void)?
    ) throws {
        HeadlessRunner.registerFonts(appBuilder.fontData)
        var initialState = appBuilder.makeState()
        var initTx = Tx()
        if let sceneName = parsed.sceneName, let applyScene = appBuilder.scenes[sceneName] {
            applyScene(&initialState, &initTx)
        }
        let targetSize = parsed.viewportOverride ?? appBuilder.size
        let initialFrame = frame.width > 0 && frame.height > 0
            ? frame
            : NSRect(x: 0, y: 0, width: CGFloat(targetSize.x), height: CGFloat(targetSize.y))
        let respectSystemAppearance = (parsed.darkOverride == nil && appBuilder.dark == nil)
        let sysDark: Bool = {
            if let d = parsed.darkOverride { return d }
            if let d = appBuilder.dark { return d }
            let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }()
        let waker = Waker()
        let scale = Float(NSScreen.main?.backingScaleFactor ?? 2.0)
        let rt = Runtime<State>(
            state: initialState,
            viewport: Vec2(Float(max(1, initialFrame.width)), Float(max(1, initialFrame.height))),
            pixelScale: scale,
            systemDark: sysDark,
            reducedMotion: parsed.reducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            waker: waker,
            onKey: appBuilder.onKeyHook,
            view: appBuilder.view
        )
        rt.windowTitle = appBuilder.title
        rt.recordEvents = false
        rt.urlOpener.headless = false
        rt.srgbBlend = appBuilder.srgbBlendEnabled
        rt.fontSmoothing = appBuilder.fontSmoothingMode
        rt.poll = appBuilder.pollHook
        rt.onFocus = appBuilder.onFocusHook
        rt.onModifiers = appBuilder.onModifiersHook
        rt.onVisibility = appBuilder.onVisibilityHook
        rt.onIme = appBuilder.onImeHook
        rt.onClose = appBuilder.onCloseHook
        rt.onQuit = appBuilder.onQuitHook
        rt.turnScope = appBuilder.turnScopeHook
        rt.onReopen = appBuilder.onReopenHook
        rt.onOpenUrl = appBuilder.onOpenUrlHook
        rt.onAppFileDrop = onFileDrop
        rt.onFileDrop = onFileDropPhase
        rt.tabVisitsControls = appBuilder.tabVisitsControlsEnabled
        rt.nativeHelp = true
        rt.fitHeight = appBuilder.isFitContentHeight
        rt.readSystemContrastSettings()
        rt.applyTx(initTx, at: 0.0, markDirtyIfNotLiveOnly: false)

        let renderer = try MetalRenderer()
        let reports: FrameReports<State>? = (appBuilder.onFrameEncodedHook != nil || appBuilder.onFrameDrawnHook != nil || appBuilder.onFrameInspectHook != nil)
            ? FrameReports<State>(
                onFrameEncoded: appBuilder.onFrameEncodedHook,
                onFrameDrawn: appBuilder.onFrameDrawnHook,
                onInspectDrawn: appBuilder.onFrameInspectHook
            )
            : nil
        let meter = SurfaceMeter(name: appBuilder.title)
        let host = RuneMetalHostView<State>(
            frame: NSRect(origin: .zero, size: initialFrame.size),
            runtime: rt,
            renderer: renderer,
            timeScale: parsed.timeScale,
            respectSystemAppearance: respectSystemAppearance,
            compositor: appBuilder.compositorValue,
            appShared: appBuilder.sharedHandle.shared,
            reports: reports,
            surfaceMeter: meter,
            devStatsReceiver: appBuilder.devStatsReceiver,
            chrome: appBuilder.chromeStyle,
            titlebar: appBuilder.customTitlebar
        )
        host.autoresizingMask = [.width, .height]

        self.runtime = rt
        self.hostView = host
        self.preferredSize = targetSize
        super.init(frame: initialFrame)

        addSubview(host)
        appBuilder.sharedHandle.shared.setWaker(waker)
        waker.setCallback { [weak host] in
            DispatchQueue.main.async {
                host?.requestRender()
            }
        }
        let forcedReducedMotion = parsed.reducedMotion
        self.systemObserver = MacOSSystemObserver { [weak rt, weak host] in
            guard let rt else { return }
            rt.readSystemAccessibilitySettings(forceReducedMotion: forcedReducedMotion)
            rt.markNeedsCommit()
            host?.requestRender()
        }
        appBuilder.setupHook?(waker)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        let center = NotificationCenter.default
        for token in keyObservers {
            center.removeObserver(token)
        }
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(preferredSize.x), height: CGFloat(preferredSize.y))
    }

    public override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(hostView) ?? false
    }

    public override func layout() {
        super.layout()
        if hostView.frame != bounds {
            hostView.frame = bounds
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        for token in keyObservers {
            center.removeObserver(token)
        }
        keyObservers.removeAll()
        guard let window else {
            hostView.stopTimer()
            runtime.dispatchFocus(false, at: hostView.currentElapsedTime())
            runtime.cancelPreparedText()
            return
        }
        let becomeKey = center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.runtime.dispatchFocus(true, at: self.hostView.currentElapsedTime())
                self.hostView.requestRender()
            }
        }
        let resignKey = center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.runtime.dispatchFocus(false, at: self.hostView.currentElapsedTime())
                self.hostView.requestRender()
            }
        }
        keyObservers = [becomeKey, resignKey]
        let winScale = Float(max(0.5, window.backingScaleFactor))
        if abs(runtime.windowScale() - winScale) > 1e-4 {
            runtime.setWindowViewport(runtime.windowViewport(), pixelScale: winScale)
        }
        runtime.dispatchFocus(window.isKeyWindow, at: hostView.currentElapsedTime())
        hostView.requestRender()
    }

    /// Mutates the view's Rune state and schedules a redraw.
    public func update(_ body: (inout State, inout Tx) -> Void) {
        runtime.update(body)
        hostView.requestRender()
    }

    /// Requests an immediate frame evaluation on the next display opportunity.
    public func requestRender() {
        hostView.requestRender()
    }
}

public extension MacOSApp {
    /// Creates an embeddable `RuneMacView` for hosting a Rune `AppSpec` inside any AppKit window or SwiftUI view.
    @MainActor
    static func makeView<State>(
        _ spec: AppSpec<State>,
        frame: NSRect = .zero,
        parsed: ToolingArgs = ToolingArgs.parse([])
    ) throws -> RuneMacView<State> {
        try RuneMacView(spec: spec, frame: frame, parsed: parsed)
    }

    /// Creates an embeddable `RuneMacView` for hosting a configured Rune `App` inside any AppKit window or SwiftUI view.
    @MainActor
    static func makeView<State>(
        _ app: App<State>,
        frame: NSRect = .zero,
        parsed: ToolingArgs = ToolingArgs.parse([])
    ) throws -> RuneMacView<State> {
        try RuneMacView(app: app, frame: frame, parsed: parsed)
    }
}
#endif
