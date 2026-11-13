import Foundation

// MARK: - App Window / Activation Request Coalescing (app.rs)

/// Window visibility / lifecycle command queued via `AppHandle` (`rune::app::WindowRequest`).
public enum AppWindowRequest: Equatable, Sendable {
    case none
    case open
    case show
    case hide
    case close
}

/// Window focus / minimization / app activation queued via `AppHandle` (`rune::app::Activation`).
public enum AppActivation: Equatable, Sendable {
    case none
    case focus
    case activate
    case minimize
}

/// Result of draining coalesced requests from `AppShared`.
public struct AppDrainedRequests<State> {
    public var window: AppWindowRequest = .none
    public var position: Vec2? = nil
    public var place: PlaceRequest? = nil
    public var activation: AppActivation = .none
    public var quit: Bool = false
    public var relaunch: Bool = false
    public var dockIcon: AppIcon? = nil
    public var updates: [(_ state: inout State, _ tx: inout Tx) -> Void] = []
    public var updateIfs: [(_ state: inout State, _ tx: inout Tx) -> Bool] = []

    public var isEmpty: Bool {
        window == .none
            && position == nil
            && place == nil
            && activation == .none
            && !quit
            && !relaunch
            && dockIcon == nil
            && updates.isEmpty
            && updateIfs.isEmpty
    }
}

/// Thread-safe shared command queue backing `AppHandle` (`rune::app::Shared<S>`).
public final class AppShared<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var waker: Waker
    private var visibleFlag: Bool
    private var errorMessage: String?
    private var pending = AppDrainedRequests<State>()

    public init(waker: Waker = Waker(), isVisible: Bool = false) {
        self.waker = waker
        self.visibleFlag = isVisible
    }

    public func setWaker(_ newWaker: Waker) {
        lock.lock()
        waker = newWaker
        let shouldWake = !pending.isEmpty
        lock.unlock()
        if shouldWake {
            newWaker.wake()
        }
    }

    /// Installs the event loop waker and wakes immediately (`Shared::connect`).
    public func connect(_ newWaker: Waker) {
        lock.lock()
        waker = newWaker
        lock.unlock()
        newWaker.wake()
    }

    public var isVisible: Bool {
        lock.lock()
        defer { lock.unlock() }
        return visibleFlag
    }

    public func setVisible(_ visible: Bool) {
        lock.lock()
        visibleFlag = visible
        lock.unlock()
    }

    public var windowError: String? {
        lock.lock()
        defer { lock.unlock() }
        return errorMessage
    }

    public func setWindowError(_ error: String?) {
        lock.lock()
        errorMessage = error
        lock.unlock()
    }

    public func wake() {
        lock.lock()
        let w = waker
        lock.unlock()
        w.wake()
    }

    public func requestOpen() {
        mutateAndWake { req in
            req.window = .open
            if req.activation == .minimize {
                req.activation = .none
            }
        }
    }

    public func requestShow() {
        mutateAndWake { req in
            if req.window != .open {
                req.window = .show
            }
        }
    }

    public func requestHide() {
        mutateAndWake { req in
            req.window = .hide
            if req.activation == .minimize {
                req.activation = .none
            }
        }
    }

    public func requestFocus() {
        mutateAndWake { req in
            switch req.activation {
            case .none, .minimize:
                req.activation = .focus
            case .focus, .activate:
                break
            }
        }
    }

    public func requestActivate() {
        mutateAndWake { req in
            req.activation = .activate
        }
    }

    public func requestPosition(_ point: Vec2) {
        mutateAndWake { req in
            req.position = point
            req.place = nil
        }
    }

    public func requestPlace(_ place: PlaceRequest) {
        mutateAndWake { req in
            req.place = place
            req.position = nil
        }
    }

    public func requestClose() {
        mutateAndWake { req in
            req.window = .close
            if req.activation == .minimize {
                req.activation = .none
            }
        }
    }

    public func requestMinimize() {
        mutateAndWake { req in
            req.activation = .minimize
        }
    }

    public func requestQuit() {
        mutateAndWake { req in
            req.quit = true
        }
    }

    public func requestRelaunch() {
        mutateAndWake { req in
            req.relaunch = true
            req.quit = true
        }
    }

    public func requestDockIcon(_ icon: AppIcon) {
        mutateAndWake { req in
            req.dockIcon = icon
        }
    }

    public func enqueueUpdate(_ update: @escaping (_ state: inout State, _ tx: inout Tx) -> Void) {
        mutateAndWake { req in
            req.updates.append(update)
        }
    }

    public func enqueueUpdateIf(_ updateIf: @escaping (_ state: inout State, _ tx: inout Tx) -> Bool) {
        mutateAndWake { req in
            req.updateIfs.append(updateIf)
        }
    }

    /// Takes all coalesced requests atomically without holding the lock across user callbacks (`Shared::take`).
    public func take() -> AppDrainedRequests<State> {
        drain()
    }

    /// Atomically takes and clears any pending `place` request (`Shared::take_place`).
    public func takePlace() -> PlaceRequest? {
        lock.lock()
        defer { lock.unlock() }
        let out = pending.place
        pending.place = nil
        return out
    }

    /// Takes all coalesced requests atomically without holding the lock across user callbacks.
    public func drain() -> AppDrainedRequests<State> {
        lock.lock()
        let out = pending
        pending = AppDrainedRequests<State>()
        lock.unlock()
        return out
    }

    /// Executes queued state updates FIRST without holding the lock, then drains the coalesced
    /// window/activation/quit requests so any `open()`/`close()`/`quit()` issued inside an
    /// `update` returns in the very same drain (`Shared::drain` in `app.rs:910-915`).
    @discardableResult
    public func applyStateUpdates(to runtime: Runtime<State>, at now: Double) -> AppDrainedRequests<State> {
        lock.lock()
        let updates = pending.updates
        let updateIfs = pending.updateIfs
        pending.updates.removeAll(keepingCapacity: true)
        pending.updateIfs.removeAll(keepingCapacity: true)
        lock.unlock()

        for fn in updates {
            runtime.update(at: now, fn)
        }
        for fn in updateIfs {
            runtime.updateIf(at: now, fn)
        }

        lock.lock()
        var out = pending
        out.updates = updates
        out.updateIfs = updateIfs
        pending.window = .none
        pending.position = nil
        pending.place = nil
        pending.activation = .none
        pending.quit = false
        pending.relaunch = false
        pending.dockIcon = nil
        lock.unlock()
        return out
    }

    private func mutateAndWake(_ body: (inout AppDrainedRequests<State>) -> Void) {
        lock.lock()
        body(&pending)
        let w = waker
        lock.unlock()
        w.wake()
    }
}

/// Thread-safe handle to a running `App` (`rune::AppHandle<S>`).
public final class AppHandle<State>: @unchecked Sendable {
    public let shared: AppShared<State>

    public init(shared: AppShared<State> = AppShared<State>()) {
        self.shared = shared
    }

    public func wake() { shared.wake() }
    public func open() { shared.requestOpen() }
    public func show() { shared.requestShow() }
    public func hide() { shared.requestHide() }
    public func focus() { shared.requestFocus() }
    public func setPosition(_ point: Vec2) { shared.requestPosition(point) }
    public func place(_ request: PlaceRequest) { shared.requestPlace(request) }
    public func activate() { shared.requestActivate() }
    public func close() { shared.requestClose() }
    public func minimize() { shared.requestMinimize() }
    public func quit() { shared.requestQuit() }
    public func relaunch() { shared.requestRelaunch() }
    public func setDockIcon(_ icon: AppIcon) { shared.requestDockIcon(icon) }

    public var isVisible: Bool { shared.isVisible }
    public var windowError: String? { shared.windowError }

    public func update(_ body: @escaping (_ state: inout State, _ tx: inout Tx) -> Void) {
        shared.enqueueUpdate(body)
    }

    public func updateIf(_ body: @escaping (_ state: inout State, _ tx: inout Tx) -> Bool) {
        shared.enqueueUpdateIf(body)
    }
}

// MARK: - Multi-Window Specs (window/spec.rs)

/// Strongly-typed window specification (`rune::WindowSpec<S>`).
/// Named `AppWindowSpec` to coexist cleanly with `DesktopIntegration.WindowSpec`.
public struct AppWindowSpec<State> {
    public var key: String
    public var appSpec: AppSpec<State>
    public var options: WindowOptions
    public var macosWindow: MacWindowOptions
    public var chrome: Chrome
    public var titlebar: Titlebar?
    public var openAs: OpenAs
    public var openInactive: Bool
    public var inactive: Bool {
        get { openInactive }
        set { openInactive = newValue }
    }
    public var keepRunning: Bool
    public var onCreated: ((WindowHandle) -> Void)?
    public var onReady: ((WindowHandle) -> Void)?
    public var onQuit: ((inout State, inout Tx) -> Void)?
    public var onReopen: ((inout State, Bool, inout Tx) -> Bool)?
    public var onOpenUrl: ((inout State, String, inout Tx) -> Void)?
    public var childWindows: [AnyWindowSpec]
    public var args: [String]?
    private let runAction: (@MainActor ([String]?) throws -> Void)?

    public init(
        app: App<State>,
        options: WindowOptions? = nil,
        macosWindow: MacWindowOptions? = nil,
        openInactive: Bool? = nil,
        onCreated: ((WindowHandle) -> Void)? = nil
    ) {
        self.key = app.title
        self.appSpec = app.intoSpec()
        self.options = options ?? app.windowOptionsValue
        self.macosWindow = macosWindow ?? app.macosWindowValue
        self.chrome = app.chromeStyle
        self.titlebar = app.customTitlebar
        self.openAs = app.openAs
        self.openInactive = openInactive ?? app.isOpenInactive
        self.keepRunning = app.keepsRunning
        self.onCreated = onCreated
        self.onReady = app.onReadyHook
        self.onQuit = app.onQuitHook
        self.onReopen = app.onReopenHook
        self.onOpenUrl = app.onOpenUrlHook
        self.childWindows = []
        self.args = app.runOptions.arguments
        nonisolated(unsafe) let localApp = app
        self.runAction = { arguments in
            try localApp.run(arguments: arguments)
        }
    }

    public init(key: String, app: AppSpec<State>) {
        self.key = key
        self.appSpec = app
        self.options = .default
        self.macosWindow = MacWindowOptions()
        self.chrome = .default
        self.titlebar = nil
        self.openAs = .normal
        self.openInactive = false
        self.keepRunning = false
        self.onCreated = nil
        self.onReady = nil
        self.onQuit = nil
        self.onReopen = nil
        self.onOpenUrl = nil
        self.childWindows = []
        self.args = nil
        self.runAction = nil
    }

    public static func fromApp(_ app: App<State>) -> AppWindowSpec<State> {
        AppWindowSpec(app: app)
    }

    public func args(_ arguments: [String]) -> AppWindowSpec<State> {
        var copy = self
        copy.args = arguments
        return copy
    }

    /// Resolves this window's CLI args: explicit per-window args never inspect `inherited`.
    public func resolveArgs(inherited: () -> ToolingArgs = { ToolingArgs() }) -> ToolingArgs {
        RuneMultiWindow.windowArgs(explicit: args, inherited: inherited)
    }

    public func options(_ options: WindowOptions) -> AppWindowSpec<State> {
        var copy = self
        copy.options = options
        copy.macosWindow = MacWindowOptions()
        return copy
    }

    public func configuredOptions(_ options: ConfiguredWindowOptions) -> AppWindowSpec<State> {
        var copy = self
        copy.options = options.options
        copy.macosWindow = options.native
        return copy
    }

    public func chrome(_ chrome: Chrome) -> AppWindowSpec<State> {
        var copy = self
        copy.chrome = chrome
        return copy
    }

    public func titlebar(_ titlebar: Titlebar) -> AppWindowSpec<State> {
        var copy = self
        copy.titlebar = titlebar
        return copy
    }

    public func openInactive(_ on: Bool = true) -> AppWindowSpec<State> {
        var copy = self
        copy.openInactive = on
        return copy
    }

    public func inactive(_ on: Bool = true) -> AppWindowSpec<State> {
        openInactive(on)
    }

    public func maximized(_ on: Bool) -> AppWindowSpec<State> {
        var copy = self
        copy.openAs = copy.openAs.maximized(on)
        return copy
    }

    public func fullScreen(_ on: Bool) -> AppWindowSpec<State> {
        var copy = self
        copy.openAs = copy.openAs.fullScreen(on)
        return copy
    }

    public func keepRunning(_ on: Bool = true) -> AppWindowSpec<State> {
        var copy = self
        copy.keepRunning = on
        return copy
    }

    public func onCreated(_ body: @escaping (WindowHandle) -> Void) -> AppWindowSpec<State> {
        var copy = self
        copy.onCreated = body
        return copy
    }

    public func onReady(_ body: @escaping (WindowHandle) -> Void) -> AppWindowSpec<State> {
        var copy = self
        copy.onReady = body
        return copy
    }

    public func onQuit(_ body: @escaping (inout State, inout Tx) -> Void) -> AppWindowSpec<State> {
        var copy = self
        copy.onQuit = body
        return copy
    }

    public func onReopen(_ body: @escaping (inout State, Bool, inout Tx) -> Bool) -> AppWindowSpec<State> {
        var copy = self
        copy.onReopen = body
        return copy
    }

    public func onOpenUrl(_ body: @escaping (inout State, String, inout Tx) -> Void) -> AppWindowSpec<State> {
        var copy = self
        copy.onOpenUrl = body
        return copy
    }

    public func window<Child>(_ spec: AppWindowSpec<Child>) -> (AppWindowSpec<State>, WindowHandle) {
        let handle = WindowHandle(key: spec.key)
        var copy = self
        var child = spec
        child.key = spec.key
        child.keepRunning = true
        copy.childWindows.append(AnyWindowSpec.secondary(child, handle: handle))
        return (copy, handle)
    }

    public func boxed() -> AnyWindowSpec {
        if let runAction {
            return AnyWindowSpec(self, handle: WindowHandle(key: key), secondary: false, runner: runAction)
        }
        return AnyWindowSpec(self, handle: nil, secondary: false)
    }
}

/// Type-erased window specification returned by `App.window(_:)` or `AppWindowSpec.boxed()` (`rune::AnyWindowSpec`).
public struct AnyWindowSpec {
    public var key: String
    public var title: String
    public var size: Vec2
    public var dark: Bool?
    public let handle: WindowHandle
    public let secondary: Bool
    private var childWindows: [AnyWindowSpec]
    private let entry: HostedWindowEntry?
    private let runner: @MainActor ([String]?) throws -> Void

    public init(
        title: String,
        size: Vec2 = Vec2(800, 600),
        dark: Bool? = nil,
        runner: @escaping @MainActor ([String]?) throws -> Void
    ) {
        self.key = title
        self.title = title
        self.size = size
        self.dark = dark
        self.handle = WindowHandle(key: title)
        self.secondary = false
        self.childWindows = []
        self.entry = nil
        self.runner = runner
    }

    public init<State>(
        _ spec: AppWindowSpec<State>,
        handle: WindowHandle? = nil,
        secondary: Bool = false,
        runner: (@MainActor ([String]?) throws -> Void)? = nil
    ) {
        let h = handle ?? WindowHandle(key: spec.key)
        let entry = TypedHostedWindowEntry(spec: spec, handle: h, secondary: secondary)
        self.key = spec.key
        self.title = spec.appSpec.title
        self.size = spec.appSpec.size
        self.dark = spec.appSpec.dark
        self.handle = h
        self.secondary = secondary
        self.childWindows = spec.childWindows
        self.entry = entry
        nonisolated(unsafe) let capturedEntry = entry
        self.runner = runner ?? { arguments in
            let parsed = arguments.map { ToolingArgs.parse($0) } ?? ToolingArgs.parse()
            _ = try capturedEntry.runHeadless(args: parsed)
        }
    }

    public static func secondary<State>(
        _ spec: AppWindowSpec<State>,
        handle: WindowHandle
    ) -> AnyWindowSpec {
        AnyWindowSpec(spec, handle: handle, secondary: true)
    }

    public func makeHostEntry() -> HostedWindowEntry {
        guard let entry else {
            preconditionFailure("AnyWindowSpec created without an AppWindowSpec has no HostedWindowEntry")
        }
        return entry
    }

    public mutating func takeChildWindows() -> [AnyWindowSpec] {
        let children = childWindows
        childWindows.removeAll()
        return children
    }

    @MainActor
    public func run(arguments: [String]? = nil) throws {
        try runner(arguments)
    }
}

// MARK: - Declarative App Builder (app.rs)

/// Full declarative application builder matching `rune::App<S>` (`crates/rune/src/app.rs`).
/// Preserves full compatibility with `AppSpec<State>` while exposing `AppHandle`, lifecycle hooks,
/// `poll(t)` / `setup(Waker)`, window options, compositor attachment, and `srgbBlend = true` default.
public struct App<State> {
    public var title: String
    public var size: Vec2
    public var minSize: Vec2?
    public var dark: Bool?
    public var makeState: () -> State
    public var view: (State, inout Cx<State>) -> El<State>
    public var scenes: [String: (inout State, inout Tx) -> Void] = [:]

    public var srgbBlendEnabled: Bool = true
    public var fontSmoothingMode: FontSmoothing = .systemDefault
    public var chromeStyle: Chrome = .standard
    public var customTitlebar: Titlebar? = nil
    public var windowOptionsValue: WindowOptions = WindowOptions()
    public var macosWindowValue: MacWindowOptions = MacWindowOptions()
    public var isFitContentHeight: Bool = false
    public var isFloatOnOpen: Bool = false
    public var isOpenInactive: Bool = false
    public var openAs: OpenAs = .normal
    public var sendsModifierKeys: Bool = false
    public var tabVisitsControlsEnabled: Bool = false
    public var runOptions: RunOptions = RunOptions()
    public var isWindowless: Bool = false
    public var keepsRunning: Bool = false
    public var releasesGpuWhenClosed: Bool = false
    public var gpuBackendPreference: GpuBackend = .auto
    public var isAccessory: Bool = false
    public var usesStandardMenus: Bool = true

    public var fontData: [Data] = []
    public var fontFamilies: [String] = []
    public var menuItems: [NativeMenuItem<State>] = []
    public var overlayReceivers: [(OverlaySpec<State>, (OverlayHandle<State>) -> Void)] = []
    public var windowFactory: ((String) -> AnyWindowSpec?)? = nil
    public var compositorValue: AnyCompositor<State>? = nil
    public var playgroundHost: PlaygroundHost<State>? = nil

    public var setupHook: ((Waker) -> Void)? = nil
    public var pollHook: ((inout State, Double, inout Tx) -> Bool)? = nil
    public var onKeyHook: ((inout State, KeyEvent, inout Tx) -> Bool)? = nil
    public var onFocusHook: ((inout State, Bool, inout Tx) -> Void)? = nil
    public var onModifiersHook: ((inout State, Mods, inout Tx) -> Void)? = nil
    public var onVisibilityHook: ((inout State, Bool, inout Tx) -> Void)? = nil
    public var onImeHook: ((inout State, Ime, inout Tx) -> Bool)? = nil
    public var onCloseHook: ((inout State, inout Tx) -> Bool)? = nil
    public var onQuitHook: ((inout State, inout Tx) -> Void)? = nil
    public var turnScopeHook: ((inout State, (inout State) -> Void) -> Void)? = nil
    public var onReopenHook: ((inout State, Bool, inout Tx) -> Bool)? = nil
    public var onOpenUrlHook: ((inout State, String, inout Tx) -> Void)? = nil
    public var sameTabRouterHook: ((String) -> Bool)? = nil
    public var onWindowHook: ((WindowHandle) -> Void)? = nil
    public var onReadyHook: ((WindowHandle) -> Void)? = nil
    public var onFrameEncodedHook: ((FrameEncoded) -> Void)? = nil
    public var onFrameDrawnHook: ((inout State, FrameEncoded, inout Tx) -> Void)? = nil
    public var devStatsReceiver: ((SurfaceStats) -> Void)? = nil

    public let sharedHandle: AppHandle<State>

    public init(
        title: String = "Rune",
        size: Vec2 = Vec2(800, 600),
        minSize: Vec2? = nil,
        dark: Bool? = nil,
        state: @autoclosure @escaping () -> State,
        view: @escaping (State, inout Cx<State>) -> El<State>
    ) {
        self.title = title
        self.size = size
        self.minSize = minSize
        self.dark = dark
        self.makeState = state
        self.view = view
        self.sharedHandle = AppHandle<State>()
        if let minSize {
            self.windowOptionsValue.minSize = minSize
        }
    }

    public init(
        _ title: String = "Rune",
        size: Vec2 = Vec2(800, 600),
        init makeState: @escaping () -> State,
        view: @escaping (State, inout Cx<State>) -> El<State>
    ) {
        self.title = title
        self.size = size
        self.minSize = nil
        self.dark = nil
        self.makeState = makeState
        self.view = view
        self.sharedHandle = AppHandle<State>()
    }

    public func handle() -> AppHandle<State> {
        sharedHandle
    }

    // MARK: - Builder Modifiers

    public func srgbBlend(_ enabled: Bool) -> App<State> {
        var copy = self
        copy.srgbBlendEnabled = enabled
        return copy
    }

    public func fontSmoothing(_ mode: FontSmoothing) -> App<State> {
        var copy = self
        copy.fontSmoothingMode = mode
        return copy
    }

    public func chrome(_ chrome: Chrome) -> App<State> {
        var copy = self
        copy.chromeStyle = chrome
        return copy
    }

    public func titlebar(_ titlebar: Titlebar) -> App<State> {
        var copy = self
        copy.customTitlebar = titlebar
        return copy
    }

    public func windowOptions(_ options: WindowOptions) -> App<State> {
        var copy = self
        copy.windowOptionsValue = options
        if let minSize = options.minSize {
            copy.minSize = minSize
        }
        return copy
    }

    public func configuredOptions(_ options: ConfiguredWindowOptions) -> App<State> {
        var copy = self
        copy.windowOptionsValue = options.options
        copy.macosWindowValue = options.native
        if let minSize = options.options.minSize {
            copy.minSize = minSize
        }
        return copy
    }

    public func macosWindow(_ options: MacWindowOptions) -> App<State> {
        var copy = self
        copy.macosWindowValue = options
        return copy
    }

    public func fitContentHeight(_ on: Bool = true) -> App<State> {
        var copy = self
        copy.isFitContentHeight = on
        return copy
    }

    public func floatOnOpen(_ on: Bool = true) -> App<State> {
        var copy = self
        copy.isFloatOnOpen = on
        return copy
    }

    public func openInactive(_ on: Bool = true) -> App<State> {
        var copy = self
        copy.isOpenInactive = on
        return copy
    }

    public func maximized(_ on: Bool) -> App<State> {
        var copy = self
        copy.openAs = copy.openAs.maximized(on)
        return copy
    }

    public func fullScreen(_ on: Bool) -> App<State> {
        var copy = self
        copy.openAs = copy.openAs.fullScreen(on)
        return copy
    }

    public func modifierKeys(_ on: Bool = true) -> App<State> {
        var copy = self
        copy.sendsModifierKeys = on
        return copy
    }

    public func tabVisitsControls(_ on: Bool) -> App<State> {
        var copy = self
        copy.tabVisitsControlsEnabled = on
        return copy
    }

    public func dark(_ dark: Bool?) -> App<State> {
        var copy = self
        copy.dark = dark
        return copy
    }

    public func size(_ width: Float, _ height: Float) -> App<State> {
        var copy = self
        copy.size = Vec2(width, height)
        return copy
    }

    public func minSize(_ width: Float, _ height: Float) -> App<State> {
        var copy = self
        let v = Vec2(width, height)
        copy.minSize = v
        copy.windowOptionsValue.minSize = v
        return copy
    }

    public func initState(_ make: @escaping () -> State) -> App<State> {
        var copy = self
        copy.makeState = make
        return copy
    }

    public func args(_ options: RunOptions) -> App<State> {
        var copy = self
        copy.runOptions = options
        return copy
    }

    public func args(_ arguments: [String]) -> App<State> {
        var copy = self
        copy.runOptions.arguments = arguments
        return copy
    }

    public func windowless(_ on: Bool = true) -> App<State> {
        var copy = self
        copy.isWindowless = on
        return copy
    }

    public func keepRunning(_ on: Bool = true) -> App<State> {
        var copy = self
        copy.keepsRunning = on
        return copy
    }

    public func releaseGpuWhenClosed(_ on: Bool = true) -> App<State> {
        var copy = self
        copy.releasesGpuWhenClosed = on
        return copy
    }

    public func gpuBackend(_ backend: GpuBackend) -> App<State> {
        var copy = self
        copy.gpuBackendPreference = backend
        return copy
    }

    public func accessory(_ on: Bool = true) -> App<State> {
        var copy = self
        copy.isAccessory = on
        return copy
    }

    public func standardMenus(_ on: Bool) -> App<State> {
        var copy = self
        copy.usesStandardMenus = on
        return copy
    }

    public func menuItem(_ item: NativeMenuItem<State>) -> App<State> {
        var copy = self
        copy.menuItems.append(item)
        return copy
    }

    public func overlay(
        _ spec: OverlaySpec<State>,
        receiver: @escaping (OverlayHandle<State>) -> Void
    ) -> App<State> {
        var copy = self
        copy.overlayReceivers.append((spec, receiver))
        return copy
    }

    public func window(_ factory: @escaping (String) -> AnyWindowSpec?) -> App<State> {
        var copy = self
        copy.windowFactory = factory
        return copy
    }

    public func setup(_ hook: @escaping (Waker) -> Void) -> App<State> {
        var copy = self
        copy.setupHook = hook
        return copy
    }

    public func poll(_ hook: @escaping (inout State, Double, inout Tx) -> Bool) -> App<State> {
        var copy = self
        copy.pollHook = hook
        return copy
    }

    public func onKey(_ hook: @escaping (inout State, KeyEvent, inout Tx) -> Bool) -> App<State> {
        var copy = self
        copy.onKeyHook = hook
        return copy
    }

    public func onFocus(_ hook: @escaping (inout State, Bool, inout Tx) -> Void) -> App<State> {
        var copy = self
        copy.onFocusHook = hook
        return copy
    }

    public func onModifiers(_ hook: @escaping (inout State, Mods, inout Tx) -> Void) -> App<State> {
        var copy = self
        copy.onModifiersHook = hook
        return copy
    }

    public func onVisibility(_ hook: @escaping (inout State, Bool, inout Tx) -> Void) -> App<State> {
        var copy = self
        copy.onVisibilityHook = hook
        return copy
    }

    public func onIme(_ hook: @escaping (inout State, Ime, inout Tx) -> Bool) -> App<State> {
        var copy = self
        copy.onImeHook = hook
        return copy
    }

    public func onClose(_ hook: @escaping (inout State, inout Tx) -> Bool) -> App<State> {
        var copy = self
        copy.onCloseHook = hook
        return copy
    }

    public func onQuit(_ hook: @escaping (inout State, inout Tx) -> Void) -> App<State> {
        var copy = self
        copy.onQuitHook = hook
        return copy
    }

    public func turnScope(_ hook: @escaping (inout State, (inout State) -> Void) -> Void) -> App<State> {
        var copy = self
        copy.turnScopeHook = hook
        return copy
    }

    public func onReopen(_ hook: @escaping (inout State, Bool, inout Tx) -> Bool) -> App<State> {
        var copy = self
        copy.onReopenHook = hook
        return copy
    }

    public func onOpenUrl(_ hook: @escaping (inout State, String, inout Tx) -> Void) -> App<State> {
        var copy = self
        copy.onOpenUrlHook = hook
        return copy
    }

    /// Web SPA same-origin router hook; stored for API parity and no-op on native (`App::same_tab_router`).
    public func sameTabRouter(_ route: @escaping (String) -> Bool) -> App<State> {
        var copy = self
        copy.sameTabRouterHook = route
        return copy
    }

    public func onWindow(_ hook: @escaping (WindowHandle) -> Void) -> App<State> {
        var copy = self
        copy.onWindowHook = hook
        return copy
    }

    public func onReady(_ hook: @escaping (WindowHandle) -> Void) -> App<State> {
        var copy = self
        copy.onReadyHook = hook
        return copy
    }

    public func onFrameEncoded(_ hook: @escaping (FrameEncoded) -> Void) -> App<State> {
        var copy = self
        copy.onFrameEncodedHook = hook
        return copy
    }

    public func onFrameDrawn(_ hook: @escaping (inout State, FrameEncoded, inout Tx) -> Void) -> App<State> {
        var copy = self
        copy.onFrameDrawnHook = hook
        return copy
    }

    public func compositor<C: Compositor>(_ compositor: C) -> App<State> where C.State == State {
        var copy = self
        copy.compositorValue = AnyCompositor(compositor)
        return copy
    }

    public func compositor(_ legacy: RuneCompositor) -> App<State> {
        var copy = self
        copy.compositorValue = AnyCompositor<State>.wrapping(legacy)
        return copy
    }

    public func devStats(_ receiver: @escaping (SurfaceStats) -> Void) -> App<State> {
        var copy = self
        copy.devStatsReceiver = receiver
        return copy
    }

    public func playground(_ host: PlaygroundHost<State>) -> App<State> {
        var copy = self
        copy.playgroundHost = host
        return copy
    }

    public func scene(_ name: String, _ apply: @escaping (inout State, inout Tx) -> Void) -> App<State> {
        var copy = self
        copy.scenes[name] = apply
        return copy
    }

    public func font(_ data: Data) -> App<State> {
        var copy = self
        copy.fontData.append(data)
        return copy
    }

    public func fonts(_ fonts: [Data]) -> App<State> {
        var copy = self
        copy.fontData.append(contentsOf: fonts)
        return copy
    }

    public func family(_ name: String) -> App<State> {
        var copy = self
        copy.fontFamilies.append(name)
        return copy
    }

    public func families(_ names: [String]) -> App<State> {
        var copy = self
        copy.fontFamilies.append(contentsOf: names)
        return copy
    }

    // MARK: - Runtime / Spec Conversion & Execution

    /// Converts this `App` into an `AppSpec` carrying `setup`, `poll`, `fonts`, `families`,
    /// `onKey`, `scenes`, and shell defaults.
    public func intoSpec() -> AppSpec<State> {
        var spec = AppSpec<State>(
            title: title,
            size: size,
            minSize: minSize,
            dark: dark,
            state: makeState(),
            scenes: scenes,
            fonts: fontData,
            families: fontFamilies,
            setup: setupHook,
            poll: pollHook,
            onKey: onKeyHook,
            view: view
        )
        spec.srgbBlend = srgbBlendEnabled
        return spec
    }

    /// Creates a configured `Runtime<State>` reflecting this `App`'s `srgbBlend`, `fontSmoothing`,
    /// `poll`, lifecycle callbacks, and `setupHook`.
    public func makeRuntime(
        viewport: Vec2? = nil,
        pixelScale: Float = 2.0,
        systemDark: Bool? = nil,
        reducedMotion: Bool = false,
        waker: Waker = Waker(),
        sceneName: String? = nil
    ) -> Runtime<State> {
        var initTx = Tx()
        let initial = withSceneClock(SceneClock(now: 0.0, dt: 0.0)) {
            var s = makeState()
            if let sceneName, let applyScene = scenes[sceneName] {
                applyScene(&s, &initTx)
            }
            return s
        }
        let runtime = Runtime<State>(
            state: initial,
            viewport: viewport ?? size,
            pixelScale: pixelScale,
            systemDark: systemDark ?? dark ?? true,
            reducedMotion: reducedMotion,
            waker: waker,
            onKey: onKeyHook,
            view: view
        )
        runtime.windowTitle = title
        runtime.srgbBlend = srgbBlendEnabled
        runtime.fontSmoothing = fontSmoothingMode
        runtime.poll = pollHook
        runtime.onFocus = onFocusHook
        runtime.onModifiers = onModifiersHook
        runtime.onVisibility = onVisibilityHook
        runtime.onIme = onImeHook
        runtime.onClose = onCloseHook
        runtime.onQuit = onQuitHook
        runtime.turnScope = turnScopeHook
        runtime.onReopen = onReopenHook
        runtime.onOpenUrl = onOpenUrlHook
        runtime.tabVisitsControls = tabVisitsControlsEnabled
        runtime.applyTx(initTx, at: 0.0, markDirtyIfNotLiveOnly: false)
        sharedHandle.shared.setWaker(waker)
        withSceneClock(SceneClock(now: 0.0, dt: 0.0)) {
            setupHook?(waker)
        }
        return runtime
    }

    @MainActor
    public func run(arguments: [String]? = nil) throws {
        try RuneApp.run(self, arguments: arguments ?? runOptions.arguments)
    }

    @MainActor
    public func tryRun(arguments: [String]? = nil) throws {
        try run(arguments: arguments)
    }
}

// MARK: - Tx Shell Extensions (el/tx.rs)

public extension Tx {
    /// Requests closing the active window (`Tx::close_window`).
    mutating func closeWindow() {
        runtimeActions["closeWindow"] = true
    }

    /// Requests minimizing the active window (`Tx::minimize`).
    mutating func minimize() {
        runtimeActions["minimizeWindow"] = true
    }

    /// Requests quitting and relaunching the app (`Tx::relaunch`).
    mutating func relaunch() {
        runtimeActions["relaunchApp"] = true
        runtimeActions["relaunchRequested"] = true
        quit()
    }

    /// Switches sRGB blending dynamically (`Tx::set_srgb_blend`).
    mutating func setSrgbBlend(_ enabled: Bool) {
        runtimeActions["srgbBlend"] = enabled
    }

    /// Switches glyph font smoothing dynamically (`Tx::set_font_smoothing`).
    mutating func setFontSmoothing(_ mode: FontSmoothing) {
        runtimeActions["fontSmoothing"] = mode
    }

    /// Marks the resulting commit as an instant snap without animating (`Tx::instant`).
    mutating func instant() {
        settle()
    }

    /// Requests a wake deadline `seconds` from now (`Tx::wake_after`).
    mutating func wakeAfter(_ seconds: Double) {
        let clamped = max(0.0, seconds)
        if let existing = runtimeActions["wakeAfter"] as? Double {
            runtimeActions["wakeAfter"] = min(existing, clamped)
        } else {
            runtimeActions["wakeAfter"] = clamped
        }
    }

    /// Sets the native window title (`Tx::set_window_title`).
    mutating func setWindowTitle(_ title: String) {
        windowTitle = title
    }

    /// Requests application quit (`Tx::quit`).
    mutating func requestQuit() {
        quit()
    }

    /// Forces a view rebuild even if no state closure reported mutation (`Tx::commit`).
    mutating func commit() {
        runtimeActions["forceCommit"] = true
    }

    /// Overrides the spring used by layout/flight animations created by this commit (`Tx::motion`).
    mutating func motion(_ spring: Spring) {
        runtimeActions["motionSpring"] = spring
    }

    internal var motionSpringRequest: Spring? {
        runtimeActions["motionSpring"] as? Spring
    }

    internal var isCloseWindowRequested: Bool {
        (runtimeActions["closeWindow"] as? Bool) == true
    }

    internal var isMinimizeRequested: Bool {
        (runtimeActions["minimizeWindow"] as? Bool) == true
    }

    internal var isRelaunchRequested: Bool {
        (runtimeActions["relaunchApp"] as? Bool) == true
    }

    internal var srgbBlendRequest: Bool? {
        runtimeActions["srgbBlend"] as? Bool
    }

    internal var fontSmoothingRequest: FontSmoothing? {
        runtimeActions["fontSmoothing"] as? FontSmoothing
    }

    internal var wakeAfterSeconds: Double? {
        runtimeActions["wakeAfter"] as? Double
    }

    internal var isForceCommitRequested: Bool {
        (runtimeActions["forceCommit"] as? Bool) == true
    }
}
