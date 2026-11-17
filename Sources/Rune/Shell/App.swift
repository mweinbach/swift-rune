import Foundation

// MARK: - App Window / Activation Request Coalescing (app.rs)

private final class WindowRequestOrderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue: UInt64 = 1

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let value = nextValue
        nextValue &+= 1
        return value
    }
}

private let windowRequestOrderCounter = WindowRequestOrderCounter()

/// Monotonic modification-order tag used to compare UI-thread `Tx.minimize()` calls
/// against mutex-published `AppHandle` restore/cancel calls (`app::requests::window_request_order`).
internal func windowRequestOrder() -> UInt64 {
    windowRequestOrderCounter.next()
}

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
    internal var lastCancelOrder: UInt64 = 0
    public var window: AppWindowRequest = .none
    public var openToken: String? = nil
    public var position: Vec2? = nil
    public var place: PlaceRequest? = nil
    public var activation: AppActivation = .none
    public var quit: Bool = false
    public var relaunch: Bool = false
    public var dockIcon: AppIcon? = nil
    public var updates: [(_ state: inout State, _ tx: inout Tx) -> Void] = []
    public var updateIfs: [(_ state: inout State, _ tx: inout Tx) -> Bool] = []
    internal var orderedUpdates: [(_ state: inout State, _ tx: inout Tx) -> Bool] = []

    /// Records the cancel order and strips a pending `.minimize` (`Requests::cancel_minimize`).
    internal mutating func cancelMinimize() {
        lastCancelOrder = windowRequestOrder()
        if activation == .minimize {
            activation = .none
        }
    }

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
    #if os(Windows) || os(Linux)
    private var lastHiddenAt: UInt64?
    internal var reopenHiddenAt: UInt64? { lock.withLock { lastHiddenAt } }
    #endif
    private var errorMessage: String?
    private var pending = AppDrainedRequests<State>()
    public let shortcuts = ShortcutHub<State>()
    internal let menuState = AppMenuState<State>()

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
        #if os(Windows) || os(Linux)
        if visibleFlag && !visible { lastHiddenAt = DesktopReopen.stamp() }
        #endif
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
            req.cancelMinimize()
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
            req.cancelMinimize()
        }
    }

    public func requestFocus() {
        mutateAndWake { req in
            req.cancelMinimize()
            switch req.activation {
            case .none, .minimize:
                req.activation = .focus
            case .focus, .activate:
                break
            }
        }
    }

    public func requestActivate(_ token: String? = nil) {
        mutateAndWake { req in
            req.cancelMinimize()
            if let token, !token.isEmpty {
                req.window = .open
                req.openToken = token
            }
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
            req.cancelMinimize()
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
            req.orderedUpdates.append { s, tx in
                update(&s, &tx)
                return true
            }
        }
    }

    public func enqueueUpdateIf(_ updateIf: @escaping (_ state: inout State, _ tx: inout Tx) -> Bool) {
        mutateAndWake { req in
            req.updateIfs.append(updateIf)
            req.orderedUpdates.append(updateIf)
        }
    }

    /// Queues an `update` without waking the loop (`Shared::queue_update`).
    internal func queueUpdateWithoutWake(_ update: @escaping (_ state: inout State, _ tx: inout Tx) -> Void) {
        lock.lock()
        pending.updates.append(update)
        pending.orderedUpdates.append { s, tx in
            update(&s, &tx)
            return true
        }
        lock.unlock()
    }

    /// Queues a conditional `updateIf` without waking the loop (`Shared::queue_update`).
    internal func queueUpdateIfWithoutWake(_ updateIf: @escaping (_ state: inout State, _ tx: inout Tx) -> Bool) {
        lock.lock()
        pending.updateIfs.append(updateIf)
        pending.orderedUpdates.append(updateIf)
        lock.unlock()
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
    /// `update` returns in the very same drain (`Shared::drain` + `Shared::drain_window` in `app/requests.rs`).
    @discardableResult
    public func applyStateUpdates(
        to runtime: Runtime<State>,
        at now: Double,
        afterUpdate: ((Bool) -> Void)? = nil
    ) -> AppDrainedRequests<State> {
        lock.lock()
        let updates = pending.updates
        let updateIfs = pending.updateIfs
        let orderedUpdates = pending.orderedUpdates
        pending.updates.removeAll(keepingCapacity: true)
        pending.updateIfs.removeAll(keepingCapacity: true)
        pending.orderedUpdates.removeAll(keepingCapacity: true)
        lock.unlock()

        var batchMinimizeOrder: UInt64 = 0
        for fn in orderedUpdates {
            let (changed, minOrder) = runtime.updateIfOrdered(at: now, fn)
            if let minOrder, minOrder > batchMinimizeOrder {
                batchMinimizeOrder = minOrder
            }
            afterUpdate?(changed)
        }

        lock.lock()
        var out = pending
        out.updates = updates
        out.updateIfs = updateIfs
        out.orderedUpdates = orderedUpdates
        pending.lastCancelOrder = 0
        pending.window = .none
        pending.openToken = nil
        pending.position = nil
        pending.place = nil
        pending.activation = .none
        pending.quit = false
        pending.relaunch = false
        pending.dockIcon = nil
        lock.unlock()

        if batchMinimizeOrder > out.lastCancelOrder {
            _ = runtime.minimizeStep(.asked)
        }
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
    public func place(_ display: DisplayTarget, placement: OverlayPlacement) {
        shared.requestPlace(PlaceRequest(display: display, placement: placement))
    }
    public func activate() { shared.requestActivate() }
    public func activate(_ token: String) { shared.requestActivate(token) }
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

    /// Registers a global shortcut while the app is running (`AppHandle::register_shortcut`).
    @discardableResult
    public func registerShortcut(
        _ shortcut: ParsedShortcut,
        _ handler: @escaping @Sendable (_ state: inout State, _ tx: inout Tx) -> Void
    ) -> Result<UInt32, ShortcutError> {
        shared.shortcuts.register(shortcut, handler: handler)
    }

    /// Unregisters a previously registered global shortcut (`AppHandle::unregister_shortcut`).
    @discardableResult
    public func unregisterShortcut(_ id: UInt32) -> Result<Void, ShortcutError> {
        shared.shortcuts.unregister(id)
    }

    /// Returns the name of the owner holding `shortcut` in this process or OS (`AppHandle::shortcut_owner`).
    public func shortcutOwner(_ shortcut: ParsedShortcut) -> String? {
        shared.shortcuts.owner(of: shortcut)
    }

    /// Takes errors recorded while registering startup `App.globalShortcut` declarations (`AppHandle::take_shortcut_errors`).
    public func takeShortcutErrors() -> [ShortcutError] {
        shared.shortcuts.takeErrors()
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
    public var onFrameEncoded: ((FrameEncoded) -> Void)?
    public var onFrameDrawn: ((Runtime<State>) -> Void)?
    public var windowless: Bool
    public var fitContentHeight: Bool
    public var menuItems: [NativeMenuItem<State>]
    public var appShared: AppShared<State>?
    public var childWindows: [AnyWindowSpec]
    public var args: [String]?
    internal var configureRuntime: ((AnyObject) -> Void)?
    #if os(macOS)
    internal var compositor: AnyCompositor<State>?
    internal var frameDrawnUpdate: ((inout State, FrameEncoded, inout Tx) -> Void)?
    #endif
    private let runAction: (@MainActor ([String]?) throws -> Void)?
    #if os(Windows) || os(Linux) || os(macOS)
    internal let desktopBuilder: App<State>?
    #endif

    public init(
        app: App<State>,
        key: String? = nil,
        options: WindowOptions? = nil,
        macosWindow: MacWindowOptions? = nil,
        openInactive: Bool? = nil,
        onCreated: ((WindowHandle) -> Void)? = nil
    ) {
        self.key = key ?? app.title
        #if os(Windows) || os(Linux) || os(macOS)
        self.desktopBuilder = app
        #endif
        self.appSpec = app.intoSpec()
        var resolvedOptions = options ?? app.windowOptionsValue
        if app.isWindowless && options == nil {
            resolvedOptions.visible = false
        }
        self.options = resolvedOptions
        self.macosWindow = macosWindow ?? app.macosWindowValue
        self.chrome = app.chromeStyle
        self.titlebar = app.customTitlebar
        self.openAs = app.openAs
        self.openInactive = openInactive ?? app.isOpenInactive
        self.keepRunning = app.keepsRunning || app.isWindowless
        self.onCreated = onCreated
        self.onReady = app.onReadyHook
        self.onQuit = app.onQuitHook
        self.onReopen = app.onReopenHook
        self.onOpenUrl = app.onOpenUrlHook
        self.onFrameEncoded = app.onFrameEncodedHook
        self.onFrameDrawn = app.onFrameInspectHook
        #if os(macOS)
        self.compositor = app.compositorValue
        self.frameDrawnUpdate = app.onFrameDrawnHook
        #endif
        self.windowless = app.isWindowless
        self.fitContentHeight = app.isFitContentHeight
        self.menuItems = app.menuItems
        self.appShared = app.sharedHandle.shared
        self.childWindows = app.childWindows
        self.args = app.runOptions.arguments
        let capturedApp = app
        self.configureRuntime = { rtObj in
            guard let rt = rtObj as? Runtime<State> else { return }
            AppRuntimeConfigurer.configure(app: capturedApp, into: rt)
        }
        nonisolated(unsafe) let localApp = app
        self.runAction = { arguments in
            try localApp.run(arguments: arguments)
        }
    }

    public init(key: String, app: AppSpec<State>) {
        self.key = key
        #if os(Windows) || os(Linux) || os(macOS)
        self.desktopBuilder = nil
        #endif
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
        self.onFrameEncoded = nil
        self.onFrameDrawn = nil
        self.windowless = false
        self.fitContentHeight = false
        self.menuItems = []
        self.appShared = AppShared<State>()
        self.childWindows = []
        self.args = nil
        self.configureRuntime = nil
        self.runAction = nil
    }

    public var appHandle: AppHandle<State> {
        AppHandle(shared: appShared ?? AppShared<State>())
    }

    public static func fromApp(_ app: App<State>, key: String? = nil) -> AppWindowSpec<State> {
        AppWindowSpec(app: app, key: key)
    }

    public static func fromApp(_ key: String, _ app: App<State>) -> AppWindowSpec<State> {
        var copy = AppWindowSpec(app: app)
        copy.key = key
        return copy
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

    public func onFrameEncoded(_ body: @escaping (FrameEncoded) -> Void) -> AppWindowSpec<State> {
        var copy = self
        copy.onFrameEncoded = body
        return copy
    }

    public func onFrameDrawn(_ body: @escaping (Runtime<State>) -> Void) -> AppWindowSpec<State> {
        var copy = self
        copy.onFrameDrawn = body
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
    internal let nativeHostEntry: NativeHostedWindowEntry?
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
        self.nativeHostEntry = nil
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
        self.nativeHostEntry = entry
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
        requireNativeHostEntry()
    }

    internal func requireNativeHostEntry() -> NativeHostedWindowEntry {
        guard let nativeHostEntry else {
            preconditionFailure("AnyWindowSpec created without an AppWindowSpec has no HostedWindowEntry")
        }
        return nativeHostEntry
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
    public var sceneOrder: [String] = []

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
    public var usesStandardMenus: Bool = false

    public var fontData: [Data] = []
    public var fontFamilies: [String] = []
    public var menuItems: [NativeMenuItem<State>] = []
    private enum AttachedOverlay {
        case spec(OverlaySpec<State>, (OverlayHandle<State>) -> Void)
        case configured(() -> AnyObject)
    }
    private var attachedOverlays: [AttachedOverlay] = []
    public var overlayReceivers: [(OverlaySpec<State>, (OverlayHandle<State>) -> Void)] {
        get { attachedOverlays.compactMap { if case let .spec(spec, receive) = $0 { (spec, receive) } else { nil } } }
        set {
            var incoming = newValue[...]
            attachedOverlays = attachedOverlays.compactMap { attachment in
                guard case .spec = attachment else { return attachment }
                return incoming.popFirst().map { .spec($0.0, $0.1) }
            }
            attachedOverlays.append(contentsOf: incoming.map { .spec($0.0, $0.1) })
        }
    }
    public var windowFactory: ((String) -> AnyWindowSpec?)? = nil
    public var childWindows: [AnyWindowSpec] = []
    public var compositorValue: AnyCompositor<State>? = nil
    public var playgroundHost: PlaygroundHost<State>? = nil

    public var setupHook: ((Waker) -> Void)? = nil
    public var pollHook: ((inout State, Double, inout Tx) -> Bool)? = nil
    public var onKeyHook: ((inout State, KeyEvent, inout Tx) -> Bool)? = nil
    public var onFocusHook: ((inout State, Bool, inout Tx) -> Void)? = nil
    public var onModifiersHook: ((inout State, Mods, inout Tx) -> Void)? = nil
    public var onVisibilityHook: ((inout State, Bool, inout Tx) -> Void)? = nil
    public var onRestHook: ((inout State, inout Tx) -> Bool)? = nil
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
    public var onFrameInspectHook: ((Runtime<State>) -> Void)? = nil
    public var devStatsReceiver: ((SurfaceStats) -> Void)? = nil
    public var globalShortcuts: [AppGlobalShortcutEntry<State>] = []
    public var allowUnmodifiedShortcutsEnabled: Bool = false
    public var webCanvasID: String?
    public var usesFullViewport = false
    public var isWebDocument: Bool = false
    public var fontURLStrings: [String] = []
    public var lateFontURLStrings: [String] = []

    public let sharedHandle: AppHandle<State>

    #if os(Windows) || os(Linux)
    /// A spec created directly from an AppSpec already owns a handle which can have queued work.
    internal init(windowSpec spec: AppSpec<State>, shared: AppShared<State>?) {
        title = spec.title
        size = spec.size
        minSize = spec.minSize
        dark = spec.dark
        makeState = spec.makeState
        view = spec.view
        sharedHandle = AppHandle(shared: shared ?? AppShared())
    }
    #endif

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
        self.sharedHandle.shared.shortcuts.named(title)
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
        self.sharedHandle.shared.shortcuts.named(title)
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
        if on {
            copy.keepsRunning = true
        }
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
        copy.attachedOverlays.append(.spec(spec, receiver))
        return copy
    }

    public func overlay<Child>(_ spec: OverlaySpec<Child>, receiver: @escaping (OverlayHandle<Child>) -> Void) -> Self {
        overlay(ConfiguredOverlay(spec: spec), receiver: receiver)
    }

    public func overlay<Child>(_ spec: ConfiguredOverlay<Child>, receiver: @escaping (OverlayHandle<Child>) -> Void) -> Self {
        var copy = self
        copy.attachedOverlays.append(.configured {
            let handle = OverlayHandle(configured: spec)
            receiver(handle)
            return handle
        })
        return copy
    }

    func createAttachedOverlays() -> [AnyObject] {
        attachedOverlays.map {
            switch $0 {
            case let .spec(spec, receive):
                let handle = OverlayHandle(spec: spec)
                receive(handle)
                return handle
            case let .configured(create): return create()
            }
        }
    }

    public func window(_ factory: @escaping (String) -> AnyWindowSpec?) -> App<State> {
        var copy = self
        copy.windowFactory = factory
        return copy
    }

    /// Attaches a secondary typed-state window to this `App`, returning its `AppHandle` and `WindowHandle`
    /// so callers can update its state or request opening before running (`App::window`).
    public mutating func window<Child>(_ spec: AppWindowSpec<Child>) -> (AppHandle<Child>, WindowHandle) {
        let handle = WindowHandle(key: spec.key)
        var child = spec
        child.key = spec.key
        child.keepRunning = true
        let shared = child.appShared ?? AppShared<Child>()
        child.appShared = shared
        childWindows.append(AnyWindowSpec.secondary(child, handle: handle))
        return (AppHandle(shared: shared), handle)
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

    /// Runs when a window rests after drawing stops or it becomes hidden/minimized/occluded (`App::on_rest`).
    public func onRest(_ hook: @escaping (inout State, inout Tx) -> Bool) -> App<State> {
        var copy = self
        copy.onRestHook = hook
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

    /// Unthrottled post-draw inspector reading the presented `Runtime` (`App::on_frame_drawn`).
    public func onFrameDrawn(_ hook: @escaping (Runtime<State>) -> Void) -> App<State> {
        var copy = self
        copy.onFrameInspectHook = hook
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
        if !copy.sceneOrder.contains(name) {
            copy.sceneOrder.append(name)
        }
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
        spec.sceneOrder = sceneOrder
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
        runtime.onRest = onRestHook
        runtime.onIme = onImeHook
        runtime.onClose = onCloseHook
        runtime.onQuit = onQuitHook
        runtime.turnScope = turnScopeHook
        runtime.onReopen = onReopenHook
        runtime.onOpenUrl = onOpenUrlHook
        runtime.tabVisitsControls = tabVisitsControlsEnabled
        AppRuntimeConfigurer.configureShortcuts(
            runtime: runtime,
            entries: globalShortcuts,
            allowUnmodified: allowUnmodifiedShortcutsEnabled,
            sharedHandle: sharedHandle
        )
        runtime.setModifierKeys(sendsModifierKeys)
        runtime.applyTx(initTx, at: 0.0, markDirtyIfNotLiveOnly: false)
        sharedHandle.shared.setWaker(waker)
        withSceneClock(SceneClock(now: 0.0, dt: 0.0)) {
            setupHook?(waker)
        }
        return runtime
    }

    /// Creates a headless `Runtime<State>` matching upstream `App::headless_runtime`,
    /// attaching `playgroundHost` if enabled without reading command-line flags.
    /// `processEnvironment`: where the capture presets are read (`RUNE_CONTRAST`,
    /// `RUNE_INCREASE_CONTRAST`), the process's own by default.
    public func headlessRuntime(
        size viewportSize: Vec2? = nil,
        env: Env = Env(),
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Runtime<State> {
        HeadlessRunner.registerFonts(fontData)
        let runtime = makeRuntime(
            viewport: viewportSize ?? size,
            pixelScale: env.scale,
            systemDark: dark ?? env.systemDark,
            reducedMotion: false,
            waker: Waker()
        )
        // `tooling::runtime_for` (which `App::headless_runtime` builds through): the capture
        // presets, never the machine's own settings, so runs stay reproducible (#981).
        runtime.applyCapturePresets(processEnvironment)
        #if os(Windows)
        runtime.setHeadlessWindowsTitlebar(customTitlebar, borderless: windowOptionsValue.borderless || chromeStyle.borderless)
        #else
        let resolvedChrome = customTitlebar?.macChrome(chromeStyle) ?? chromeStyle
        if resolvedChrome.fullSizeContent && !(windowOptionsValue.borderless || chromeStyle.borderless) {
            runtime.cxSettings.titlebarInset = resolvedChrome.titlebarInset()
        } else {
            runtime.cxSettings.titlebarInset = 0.0
        }
        #endif
        if let pg = playgroundHost {
            runtime.playgroundHost = pg
            _ = try? PlaygroundAttach.attach(
                runtime: runtime,
                host: pg,
                scenes: scenes,
                sceneOrder: sceneOrder,
                makeState: makeState,
                windowed: false,
                forceAttach: true
            )
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

    /// Runs until the app quits, printing startup errors to stderr and exiting `1` on native targets (`App::run` / `tooling::started`).
    @MainActor
    public func runOrExit(arguments: [String]? = nil) {
        RuneStartup.started {
            try tryRun(arguments: arguments)
        }
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
        minimizeOrder = windowRequestOrder()
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

    internal var motionSpringRequest: Spring? {
        motionSource?.spring ?? (runtimeActions["motionSpring"] as? Spring)
    }

    internal var isCloseWindowRequested: Bool {
        (runtimeActions["closeWindow"] as? Bool) == true
    }

    internal var isMinimizeRequested: Bool {
        minimizeOrder != nil
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

    internal var wakeAfterSecondsList: [Double] {
        if let list = runtimeActions["wakeAfterList"] as? [Double] {
            return list
        }
        if let single = runtimeActions["wakeAfter"] as? Double {
            return [single]
        }
        return []
    }

    internal var isForceCommitRequested: Bool {
        (runtimeActions["forceCommit"] as? Bool) == true
    }
}
