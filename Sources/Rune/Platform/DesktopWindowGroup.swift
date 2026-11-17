#if os(Linux) || os(Windows)
import Foundation
#if os(Linux)
import CRuneLinux
#else
import CRuneWin32
#endif

struct DesktopWindowError: LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
    init(_ description: String) { self.description = description }
}

@MainActor
protocol DesktopWindowSession: AnyObject {
    associatedtype State
    var window: OpaquePointer { get }
    var runtime: Runtime<State> { get }
    var shared: AppShared<State> { get }
    var running: Bool { get }
    var firstFrame: Bool { get }
    var requestedApplicationQuit: Bool { get set }
    var failure: (any Error)? { get }
    func start()
    func finish()
    func applyHandle(_ request: WindowHandleRequest)
    func applyReopenRequests()
    #if os(Linux)
    func turn(redraw: Bool) throws -> Int32
    func handleNativeEvent(_ event: RuneLinuxEvent)
    #else
    var closesWindowGroup: (() -> Bool)? { get set }
    var startupWorkOwed: Bool { get }
    func endRedrawTurn() -> Bool
    func performStartupTurn()
    func runSessionQuitHook()
    func cancelSessionQuit()
    func endSession()
    #endif
}

@MainActor
private protocol DesktopWindowFactory {
    func openDesktopWindow(parsed: ToolingArgs) throws -> (any DesktopWindowSession, [AnyObject])
}

// Desktop shells and single-instance handoffs use the same process inbox.
private final class DesktopURLGlue: IncomingURLGlue {
    func handledElsewhere() -> Bool { false }
    func install() -> Bool { true }
    func remove() {}
}

extension DesktopWindowSession {
    fileprivate func titleRequest() -> @Sendable (String) -> Void {
        let shared = self.shared
        return { title in
            shared.enqueueUpdateIf { _, tx in
                tx.setTitle(title)
                return false
            }
        }
    }

    func requestApplicationQuit(relaunch: Bool) {
        requestedApplicationQuit = true
        QuitLifecycle.send(.start(ending: false, after: relaunch ? .relaunch : .exit))
    }

    fileprivate func countSurfaceTurn(woke: Bool, waited: Bool) {
        runtime.surfaceMeter?.turn(woke: woke, waited: waited)
    }

    fileprivate var textIdleOwed: Bool { !firstFrame && runtime.textIdleOwed }

    fileprivate func prepareIdleText() {
        _ = runtime.textIdleTurn()
    }

    fileprivate func runReopenHook(visible: Bool) -> Bool {
        runtime.dispatchReopen(hasVisibleWindows: visible)
    }

    fileprivate func reopenCandidate(reopenable: Bool, minimized: Bool, main: Bool) -> DesktopReopenCandidate {
        DesktopReopenCandidate(reopenable: reopenable && running, visible: shared.isVisible && !minimized,
                               minimized: minimized, hiddenAt: shared.reopenHiddenAt, main: main)
    }

    fileprivate func listenForURLs() -> IncomingURLInbox.Listening? {
        guard let hook = runtime.onOpenUrl else { return nil }
        let shared = self.shared
        nonisolated(unsafe) let callback = hook
        let enqueue: IncomingURLInbox.ListenerSink = { url in
            shared.enqueueUpdate { [weak shared] state, tx in
                callback(&state, url, &tx)
                if InstanceLaunches.shared.launchesWaiting && shared?.isVisible == true { InstanceLaunches.shared.served() }
            }
        }
        return IncomingURLInbox.shared.listen(glue: DesktopURLGlue(), sink: enqueue)
    }
}

extension TypedHostedWindowEntry: DesktopWindowFactory {
    @MainActor
    fileprivate func openDesktopWindow(parsed: ToolingArgs) throws -> (any DesktopWindowSession, [AnyObject]) {
        let source = spec.appSpec
        let args = spec.resolveArgs { parsed }
        var app = spec.desktopBuilder ?? App(windowSpec: source, shared: spec.appShared)
        app.title = source.title
        app.makeState = source.makeState
        app.view = source.view
        app.size = source.size
        app.minSize = source.minSize
        app.dark = source.dark
        app.srgbBlendEnabled = source.srgbBlend
        app.scenes = source.scenes
        app.sceneOrder = source.sceneOrder
        app.fontData = source.fonts
        app.fontFamilies = source.families
        app.setupHook = source.setup
        app.pollHook = source.poll
        app.onKeyHook = source.onKey
        app.windowOptionsValue = spec.options
        app.chromeStyle = spec.chrome
        app.customTitlebar = spec.titlebar
        app.openAs = spec.openAs
        app.isOpenInactive = spec.openInactive
        app.keepsRunning = spec.keepRunning || secondary
        app.isWindowless = spec.windowless
        app.isFitContentHeight = spec.fitContentHeight
        if let created = spec.onCreated {
            let window = app.onWindowHook
            app.onWindowHook = { handle in
                created(handle)
                window?(handle)
            }
        }
        app.onReadyHook = spec.onReady
        app.onQuitHook = spec.onQuit
        app.onReopenHook = spec.onReopen
        app.onOpenUrlHook = spec.onOpenUrl
        app.onFrameEncodedHook = spec.onFrameEncoded
        app.onFrameInspectHook = spec.onFrameDrawn
        app.menuItems = spec.menuItems
        let shared = app.sharedHandle.shared
        AppMenuBridge.attach(app.menuItems, to: shared)
        do {
            #if os(Linux)
            let session = try LinuxWindowSession(app: app, parsed: args, handle: handle)
            #else
            let session = try Win32App.openSession(app: app, parsed: args, handle: handle)
            #endif
            session.runtime.onAppFileDrop = source.onFileDrop
            session.runtime.onFileDrop = source.onFileDropPhase
            return (session, app.createAttachedOverlays())
        } catch {
            AppMenuBridge.markRunning(shared, running: false)
            throw error
        }
    }
}

/// Handles may send requests from any thread. Only the event loop touches a native window.
private final class WindowRequests: @unchecked Sendable {
    private let lock = NSLock()
    private let wake: @Sendable () -> Void
    enum Event {
        case window(Int, WindowHandleRequest)
        case reopen
    }
    private var pending: [Event] = []
    private var ended = false
    init(wake: @escaping @Sendable () -> Void) { self.wake = wake }
    func send(_ id: Int, _ request: WindowHandleRequest) {
        lock.withLock { pending.append(.window(id, request)) }
        wake()
    }
    func reopen() -> Bool {
        let accepts = lock.withLock {
            guard !ended else { return false }
            pending.append(.reopen)
            return true
        }
        if accepts { wake() }
        return accepts
    }
    func close() { lock.withLock { ended = true } }
    func drain() -> [Event] {
        lock.withLock {
            let out = pending
            pending.removeAll(keepingCapacity: true)
            return out
        }
    }
}

#if os(Windows)
/// A window procedure can service worker requests while a native menu owns the event loop.
private final class WindowsGroupWake: @unchecked Sendable {
    private let lock = NSLock()
    private var native: OpaquePointer?
    @MainActor var drain: (@MainActor () -> Void)?
    @MainActor var onSession: (@MainActor (RuneWinSessionEvent) -> Void)?
    @MainActor private var pendingSession: [RuneWinSessionEvent] = []
    @MainActor private var deliveringSession = false

    @MainActor func drainSession() {
        guard !deliveringSession, let onSession else { return }
        deliveringSession = true
        defer { deliveringSession = false }
        while !pendingSession.isEmpty { onSession(pendingSession.removeFirst()) }
    }

    @MainActor init() throws {
        native = rune_win_group_wake_create(Unmanaged.passUnretained(self).toOpaque()) { context in
            guard let context else { return }
            let wake = Unmanaged<WindowsGroupWake>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { wake.drain?() }
        }
        guard let native else { throw DesktopWindowError("Windows could not create the event-loop wake window") }
        rune_win_group_observe_session(native) { context, event, idle in
            guard let context else { return }
            let wake = Unmanaged<WindowsGroupWake>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if event != RuneWinSessionCancelled, QuitLifecycle.currentState == .running {
                    QuitLifecycle.send(.start(ending: event == RuneWinSessionEnding, after: .exit))
                }
                wake.pendingSession.append(event)
                if idle != 0 { wake.drainSession() }
            }
        }
    }

    func post() {
        lock.withLock {
            if let native { rune_win_group_wake_post(native) }
        }
    }

    @MainActor func close() {
        let target = lock.withLock {
            let target = native
            native = nil
            return target
        }
        drain = nil
        onSession = nil
        rune_win_group_wake_destroy(target)
    }
}
#endif

/// All windows in the application, including windows opened by a callback, share one native event queue.
@MainActor
enum DesktopWindowGroup {
    @MainActor private struct Slot {
        let key: String
        let secondary: Bool
        let reopenable: Bool
        let session: any DesktopWindowSession
        let handle: WindowHandle
        let overlays: [AnyObject]
        let access: DesktopWindowAccess
        var urls: IncomingURLInbox.Listening?

        var reopenCandidate: DesktopReopenCandidate {
            let minimized = access.placement()?.minimized == true
            return session.reopenCandidate(reopenable: reopenable, minimized: minimized, main: !secondary)
        }
        #if os(Linux)
        var id: UInt32 { rune_linux_id(session.window) }
        #endif
    }

    static func run(_ initial: [AnyWindowSpec], options: RunOptions, parsed: ToolingArgs) throws {
        let initial = RuneMultiWindow.flatten(initial)
        try RuneMultiWindow.validate(initial)
        guard !initial.isEmpty else { return }
        MediaPlaybackGate.enable()
        if initial.count == 1, initial[0].nativeHostEntry == nil {
            try initial[0].run(arguments: options.arguments)
            return
        }

        RelaunchController.waitForPrevious()
        #if os(Linux)
        let wakeType = rune_linux_group_begin()
        guard wakeType != 0 else { throw DesktopWindowError(String(cString: rune_linux_error())) }
        defer { rune_linux_group_end() }
        LinuxOverlayPump.begin(wakeType)
        let wake: @Sendable () -> Void = { rune_linux_wake(0, wakeType) }
        var redraw = Set<UInt32>()
        var nativeSlots: [UInt32: Int] = [:]
        #else
        rune_win_menu_scheme(RuneWinMenuFollowSystem)
        let groupWake = try WindowsGroupWake()
        let wake: @Sendable () -> Void = { groupWake.post() }
        #endif

        InstanceLaunches.shared.started()
        QuitLifecycle.beginWindowGroup()
        IncomingURLInbox.shared.beginWindowGroup()
        IncomingURLInbox.shared.prepare(glue: DesktopURLGlue())
        IncomingURLInbox.shared.launched(SingleInstance.launchLinks(from: parsed.extraArgs))
        DesktopOverlayRegistry.shared.start(wake: wake)
        defer { DesktopOverlayRegistry.shared.finish() }
        let requests = WindowRequests(wake: wake)
        var slots = [Int: Slot]()
        var nextSlot = 0
        var delivering: ArraySlice<WindowRequests.Event> = []
        func reopenWindows() {
            let ordered = slots.sorted { $0.key < $1.key }.map(\.value)
            let visible = DesktopReopen.hasVisible(ordered.map(\.reopenCandidate))
            var handled = false
            for slot in ordered where slot.session.running {
                if slot.session.runReopenHook(visible: visible) { handled = true }
            }
            if handled {
                if visible && InstanceLaunches.shared.launchesWaiting { InstanceLaunches.shared.served() }
                return
            }
            for slot in ordered where slot.session.running { slot.session.applyReopenRequests() }
            // Apply window handle requests posted by the hooks before choosing a target.
            for event in requests.drain() {
                switch event {
                case let .window(id, request): slots[id]?.session.applyHandle(request)
                case .reopen: delivering.append(event)
                }
            }
            guard !ordered.contains(where: { $0.session.requestedApplicationQuit }) else { return }
            if let target = DesktopReopen.target(ordered.map(\.reopenCandidate)) {
                ordered[target].session.applyHandle(.open)
            }
            #if os(Windows)
            rune_win_instance_raise_front()
            #endif
        }
        func drainWindowRequests() {
            delivering.append(contentsOf: requests.drain())
            while let event = delivering.popFirst() {
                // A native window operation can reenter the wake procedure.
                switch event {
                case let .window(id, request): slots[id]?.session.applyHandle(request)
                case .reopen: reopenWindows()
                }
            }
            delivering = []
            let active = slots.values
            for slot in active { slot.access.drain() }
        }
        #if os(Windows)
        var sessionEnded = false
        groupWake.onSession = { event in
            if event == RuneWinSessionCancelled {
                guard case .quitting = QuitLifecycle.currentState else { return }
                QuitLifecycle.send(.cancel)
                for slot in slots.values { slot.session.cancelSessionQuit() }
                return
            }
            let effects = QuitLifecycle.send(.start(ending: event == RuneWinSessionEnding, after: .exit))
            if effects.contains(.runHooks) {
                for slot in slots.values { slot.session.runSessionQuitHook() }
                QuitMarks.record("quit.hooks")
                QuitLifecycle.send(.hooksRan)
            }
            if effects.contains(.closeAndExit) {
                sessionEnded = true
                for slot in slots.values { slot.session.endSession() }
                QuitLifecycle.send(.windowsClosed)
            }
        }
        groupWake.drain = drainWindowRequests
        #endif
        RuneMultiWindow.setOpenWake(wake)
        ReadySignal.runStarts()
        defer {
            requests.close()
            #if os(Windows)
            // Hooks and close callbacks already ran. Fast exit removes the windows before
            // the last hook, skipping teardown of each renderer and its device.
            if sessionEnded, let last = QuitLifecycle.activeFastExitHook() {
                // Release worker threads waiting for a window query before the GUI queue goes away.
                for slot in slots.values {
                    slot.access.drain(closing: true)
                    slot.handle.unbind()
                }
                QuitLifecycle.endFast(last)
            }
            #endif
            InstanceLaunches.shared.ended()
            #if os(Windows)
            groupWake.close()
            #endif
            ReadySignal.clear()
            RuneMultiWindow.setOpenWake(nil)
            for slot in slots.values {
                slot.access.drain(closing: true)
                slot.urls?.cancel()
                slot.handle.unbind()
                slot.session.finish()
            }
            if QuitLifecycle.isQuitting {
                QuitLifecycle.send(.hooksRan)
                QuitLifecycle.finishOrderlyExit()
            }
        }

        func open(_ spec: AnyWindowSpec, traced: Bool = false) throws {
            guard !spec.key.isEmpty else { throw MultiWindowError.emptyOrDuplicateKey(spec.key) }
            guard !slots.values.contains(where: { $0.key == spec.key }) else { return }
            guard let factory = spec.nativeHostEntry as? any DesktopWindowFactory else {
                throw DesktopWindowError("Window \(spec.key) has no AppWindowSpec to host")
            }
            RuneMultiWindow.trackDesktopHandle(spec.handle)
            var windowArgs = parsed
            if !traced {
                windowArgs.tracePath = nil
                windowArgs.frameCount = nil
            }
            let (session, overlays) = try factory.openDesktopWindow(parsed: windowArgs)
            let id = nextSlot
            nextSlot += 1
            let access = DesktopWindowAccess(window: session.window, wake: wake)
            let panel = spec.nativeHostEntry?.macosWindow
            let slot = Slot(key: spec.key, secondary: spec.secondary,
                            reopenable: panel?.nonactivatingPanel != true && panel?.launcher != true, session: session, handle: spec.handle, overlays: overlays, access: access)
            slots[id] = slot
            #if os(Windows)
            if !options.accessory && !slot.secondary {
                session.closesWindowGroup = {
                    !slots.contains { otherID, other in otherID != id && !other.secondary && other.session.running }
                }
            }
            #endif
            if spec.nativeHostEntry?.options.clickThrough == true { try access.setClickThrough(true).get() }
            let setTitle = session.titleRequest()
            spec.handle.bind(slot: id, dispatch: { slot, request in
                if case .setTitle(let title) = request {
                    // Use the same ordered queue as Tx.setTitle so a handle change from
                    // an event callback cannot overtake a later state update during the next turn.
                    setTitle(title)
                } else if case .setClickThrough(let enabled) = request {
                    // An unbound handle may already have queued a change to the initial hit-testing mode.
                    if case .failure(let error) = access.setClickThrough(enabled) {
                        FileHandle.standardError.write(Data("Rune click-through: \(error.localizedDescription)\n".utf8))
                    }
                } else {
                    requests.send(slot, request)
                }
            }, placementProvider: access.placement, clickThroughApplier: access.setClickThrough)
            #if os(Linux)
            redraw.insert(slot.id)
            nativeSlots[slot.id] = id
            #endif
            slots[id]?.urls = session.listenForURLs()
            session.start()
        }
        let traceKey = parsed.windowName ?? initial.first?.key
        for spec in initial { try open(spec, traced: spec.key == traceKey) }
        SingleInstance.onRelaunch { [weak requests] in requests?.reopen() ?? false }
        IncomingURLInbox.shared.settle(glue: DesktopURLGlue())

        var turnWoke = false
        var turnWaited = false
        while true {
            for slot in slots.values { slot.session.countSurfaceTurn(woke: turnWoke, waited: turnWaited) }
            #if os(Windows)
            groupWake.drainSession()
            if sessionEnded { return }
            #endif
            for pending in RuneMultiWindow.takeOpened() {
                let batch = RuneMultiWindow.flatten([pending])
                try RuneMultiWindow.validate(batch)
                for spec in batch { try open(spec) }
            }
            DesktopOverlayRegistry.shared.drain()
            drainWindowRequests()
            #if os(Linux)
            LinuxOverlayPump.pump()
            var wait: Int32 = -1
            for slot in slots.values {
                let next = try slot.session.turn(redraw: redraw.remove(slot.id) != nil)
                if next >= 0 { wait = wait < 0 ? next : min(wait, next) }
            }
            #endif
            var primaryClosed = false
            #if os(Windows)
            var forcedPaint = false
            #endif
            for (id, slot) in slots {
                #if os(Windows)
                if slot.session.endRedrawTurn() { forcedPaint = true }
                #endif
                if let failure = slot.session.failure { throw failure }
                if slot.session.requestedApplicationQuit { return }
                if !slot.session.running {
                    primaryClosed = primaryClosed || !slot.secondary
                    #if os(Linux)
                    nativeSlots.removeValue(forKey: slot.id)
                    redraw.remove(slot.id)
                    #endif
                    slots.removeValue(forKey: id)
                    RuneMultiWindow.releaseDesktopHandle(slot.handle)
                    slot.access.drain(closing: true)
                    slot.urls?.cancel()
                    slot.handle.unbind()
                    slot.session.finish()
                }
            }
            if !options.accessory && (slots.isEmpty || primaryClosed && !slots.values.contains(where: { !$0.secondary })) {
                return
            }
            if InstanceLaunches.shared.launchesWaiting,
               slots.values.contains(where: { let candidate = $0.reopenCandidate; return candidate.reopenable && candidate.visible }) {
                InstanceLaunches.shared.served()
            }
            let idleWindow = slots.values.first { $0.session.textIdleOwed }?.session
            #if os(Linux)
            // Bound each batch so sustained pointer motion cannot starve animation or another window.
            let mayPrepare = idleWindow != nil && wait != 0
            if mayPrepare { wait = 0 }
            for index in 0..<64 {
                var event = RuneLinuxEvent()
                let result = rune_linux_next_event(wait, &event)
                if index == 0 {
                    turnWoke = result == 0
                    turnWaited = result == 0 && wait > 0
                }
                guard result >= 0 else { throw DesktopWindowError(String(cString: rune_linux_error())) }
                if result == 0 {
                    // A native event may have queued a redraw or state update. Give it the next turn.
                    if index == 0 && mayPrepare { idleWindow?.prepareIdleText() }
                    break
                }
                defer { rune_linux_free(event.text) }
                if event.kind == RuneLinuxQuit { return }
                if let id = nativeSlots[event.windowID], let slot = slots[id] {
                    slot.session.handleNativeEvent(event)
                    redraw.insert(event.windowID)
                }
                wait = 0
            }
            #else
            let startupWindow = slots.values.first { $0.session.startupWorkOwed }?.session
            var painted: Int32 = 0
            let result = rune_win_pump_turn(startupWindow != nil || idleWindow != nil ? 1 : 0, &painted)
            turnWoke = result == RUNE_WIN_PUMP_IDLE || rune_win_turn_timer() != 0
            turnWaited = rune_win_turn_timer() != 0
            if result < 0 { throw DesktopWindowError("GetMessageW failed") }
            if result == 0 { return }
            // An input event gets its paint first. A continuously animating window can still
            // finish startup between presented frames when no keyboard or mouse input is waiting.
            if let startupWindow, startupWindow.running, !startupWindow.requestedApplicationQuit,
               rune_win_startup_may_run(painted != 0 || forcedPaint ? 1 : 0) != 0 {
                startupWindow.performStartupTurn()
            } else if startupWindow == nil, result == RUNE_WIN_PUMP_IDLE, let idleWindow, idleWindow.running {
                idleWindow.prepareIdleText()
            }
            #endif
        }
    }
}

#if os(Linux)
extension LinuxWindowSession: DesktopWindowSession {
    var shared: AppShared<State> { app.sharedHandle.shared }
    var failure: (any Error)? { nil }
    func handleNativeEvent(_ event: RuneLinuxEvent) {
        runtime.surfaceMeter?.noteWaited()
        handleEvent(event, at: now())
    }
    func applyHandle(_ request: WindowHandleRequest) {
        switch request {
        case .close: requestClose(at: now())
        case .minimize: runtime.minimizeStep(.asked)
        case .open, .focus: rune_linux_focus(window)
        case .show: rune_linux_show(window)
        case .hide: rune_linux_hide(window)
        case let .setPosition(x, y): rune_linux_set_position(window, x, y)
        case let .resize(w, h, animate): windowFrame.apply(WindowFrameRequest(size: (w, h), animate: animate), to: window)
        case .center: windowFrame.apply(WindowFrameRequest(center: true), to: window)
        case .setTitle(let value):
            runtime.windowTitle = value
            applyTitle()
        case .setAlwaysOnTop(let on): rune_linux_topmost(window, on)
        case .flash(let on): rune_linux_flash(window, on)
        case .setClickThrough(let on): _ = rune_linux_click_through(window, on ? 1 : 0)
        case .setTaskbar: break
        }
    }
}
#endif

internal func nativeDimension(_ points: Float) -> Int32 {
    guard points.isFinite else { return 1 }
    return Int32(clamping: Int64(max(1, min(Double(Int32.max), Double(points).rounded()))))
}
#endif
