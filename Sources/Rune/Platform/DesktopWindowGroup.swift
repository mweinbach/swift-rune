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
    var requestedApplicationQuit: Bool { get }
    var failure: (any Error)? { get }
    func start()
    func finish()
    func applyHandle(_ request: WindowHandleRequest)
    #if os(Linux)
    func turn(redraw: Bool) throws -> Int32
    func handleNativeEvent(_ event: RuneLinuxEvent)
    #endif
}

@MainActor
private protocol DesktopWindowFactory {
    func openDesktopWindow(parsed: ToolingArgs) throws -> any DesktopWindowSession
}

// Desktop shells start the application with URL arguments. A running Linux instance
// can also receive forwarded arguments through the same process inbox.
private final class DesktopURLGlue: IncomingURLGlue {
    func handledElsewhere() -> Bool { false }
    func install() -> Bool { true }
    func remove() {}
}

extension DesktopWindowSession {
    fileprivate func listenForURLs(launch: [String]) -> IncomingURLInbox.Listening? {
        guard let hook = runtime.onOpenUrl else { return nil }
        let shared = self.shared
        nonisolated(unsafe) let callback = hook
        let enqueue: IncomingURLInbox.ListenerSink = { url in
            shared.enqueueUpdate { state, tx in callback(&state, url, &tx) }
        }
        for url in launch { enqueue(url) }
        return IncomingURLInbox.shared.listen(glue: DesktopURLGlue(), sink: enqueue)
    }
}

extension TypedHostedWindowEntry: DesktopWindowFactory {
    @MainActor
    fileprivate func openDesktopWindow(parsed: ToolingArgs) throws -> any DesktopWindowSession {
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
        app.openAs = spec.openAs
        app.isOpenInactive = spec.openInactive
        app.keepsRunning = spec.keepRunning || secondary
        app.isWindowless = spec.windowless
        app.isFitContentHeight = spec.fitContentHeight
        app.onWindowHook = spec.onCreated ?? app.onWindowHook
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
            return session
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
    private var pending: [(Int, WindowHandleRequest)] = []
    init(wake: @escaping @Sendable () -> Void) { self.wake = wake }
    func send(_ id: Int, _ request: WindowHandleRequest) {
        lock.withLock { pending.append((id, request)) }
        wake()
    }
    func drain() -> [(Int, WindowHandleRequest)] {
        lock.withLock {
            let out = pending
            pending.removeAll(keepingCapacity: true)
            return out
        }
    }
}

/// All windows in the application, including windows opened by a callback, share one native event queue.
@MainActor
enum DesktopWindowGroup {
    @MainActor private struct Slot {
        let key: String
        let secondary: Bool
        let session: any DesktopWindowSession
        let handle: WindowHandle
        let access: DesktopWindowAccess
        var urls: IncomingURLInbox.Listening?
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

        #if os(Linux)
        let wakeType = rune_linux_group_begin()
        guard wakeType != 0 else { throw DesktopWindowError(String(cString: rune_linux_error())) }
        defer { rune_linux_group_end() }
        let wake: @Sendable () -> Void = { rune_linux_wake(0, wakeType) }
        var redraw = Set<UInt32>()
        var nativeSlots: [UInt32: Int] = [:]
        #else
        let threadID = rune_win_thread()
        let wake: @Sendable () -> Void = { rune_win_wake_thread(threadID) }
        #endif

        let requests = WindowRequests(wake: wake)
        var slots = [Int: Slot]()
        var nextSlot = 0
        RuneMultiWindow.setOpenWake(wake)
        ReadySignal.runStarts()
        defer {
            ReadySignal.clear()
            RuneMultiWindow.setOpenWake(nil)
            for slot in slots.values {
                slot.access.drain(closing: true)
                slot.urls?.cancel()
                slot.handle.unbind()
                slot.session.finish()
            }
        }

        var launchLinks = SingleInstance.launchLinks(from: parsed.extraArgs)
        func open(_ spec: AnyWindowSpec) throws {
            guard !spec.key.isEmpty else { throw MultiWindowError.emptyOrDuplicateKey(spec.key) }
            guard !slots.values.contains(where: { $0.key == spec.key }) else { return }
            guard let factory = spec.nativeHostEntry as? any DesktopWindowFactory else {
                throw DesktopWindowError("Window \(spec.key) has no AppWindowSpec to host")
            }
            RuneMultiWindow.trackDesktopHandle(spec.handle)
            let session = try factory.openDesktopWindow(parsed: parsed)
            let id = nextSlot
            nextSlot += 1
            let access = DesktopWindowAccess(window: session.window, wake: wake)
            let slot = Slot(key: spec.key, secondary: spec.secondary, session: session, handle: spec.handle, access: access)
            slots[id] = slot
            if spec.nativeHostEntry?.options.clickThrough == true { try access.setClickThrough(true).get() }
            spec.handle.bind(slot: id, dispatch: { slot, request in
                if case .setClickThrough(let enabled) = request {
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
            session.start()
            if !slot.secondary, let listener = session.listenForURLs(launch: launchLinks) {
                slots[id]?.urls = listener
                launchLinks.removeAll()
            }
        }
        for spec in initial { try open(spec) }
        launchLinks.removeAll()
        IncomingURLInbox.shared.settle(glue: DesktopURLGlue())

        while true {
            for pending in RuneMultiWindow.takeOpened() {
                let batch = RuneMultiWindow.flatten([pending])
                try RuneMultiWindow.validate(batch)
                for spec in batch { try open(spec) }
            }
            for (id, request) in requests.drain() { slots[id]?.session.applyHandle(request) }
            for slot in slots.values { slot.access.drain() }
            #if os(Linux)
            var wait: Int32 = -1
            for slot in slots.values {
                let next = try slot.session.turn(redraw: redraw.remove(slot.id) != nil)
                if next >= 0 { wait = wait < 0 ? next : min(wait, next) }
            }
            #endif
            var primaryClosed = false
            for (id, slot) in slots {
                if let failure = slot.session.failure { throw failure }
                if slot.session.requestedApplicationQuit { return }
                if !slot.session.running {
                    primaryClosed = primaryClosed || !slot.secondary
                    #if os(Linux)
                    nativeSlots.removeValue(forKey: slot.id)
                    redraw.remove(slot.id)
                    #endif
                    RuneMultiWindow.releaseDesktopHandle(slot.handle)
                    slot.access.drain(closing: true)
                    slot.urls?.cancel()
                    slot.handle.unbind()
                    slot.session.finish()
                    slots.removeValue(forKey: id)
                }
            }
            if !options.accessory && (slots.isEmpty || primaryClosed && !slots.values.contains(where: { !$0.secondary })) {
                return
            }
            #if os(Linux)
            // Bound each batch so sustained pointer motion cannot starve animation or another window.
            for _ in 0..<64 {
                var event = RuneLinuxEvent()
                let result = rune_linux_next_event(wait, &event)
                guard result >= 0 else { throw DesktopWindowError(String(cString: rune_linux_error())) }
                if result == 0 { break }
                defer { rune_linux_free(event.text) }
                if event.kind == RuneLinuxQuit { return }
                if let id = nativeSlots[event.windowID], let slot = slots[id] {
                    slot.session.handleNativeEvent(event)
                    redraw.insert(event.windowID)
                }
                wait = 0
            }
            #else
            let result = rune_win_pump()
            if result < 0 { throw DesktopWindowError("GetMessageW failed") }
            if result == 0 { return }
            #endif
        }
    }
}

#if os(Linux)
extension LinuxWindowSession: DesktopWindowSession {
    var shared: AppShared<State> { app.sharedHandle.shared }
    var failure: (any Error)? { nil }
    func handleNativeEvent(_ event: RuneLinuxEvent) { handleEvent(event, at: now()) }
    func applyHandle(_ request: WindowHandleRequest) {
        switch request {
        case .close: requestClose(at: now())
        case .minimize: rune_linux_minimize(window)
        case .open, .focus: rune_linux_focus(window)
        case .show: rune_linux_show(window)
        case .hide: rune_linux_hide(window)
        case let .setPosition(x, y): rune_linux_set_position(window, x, y)
        case let .resize(w, h, _): rune_linux_set_size(window, nativeDimension(w), nativeDimension(h))
        case .center: rune_linux_center(window)
        case .setTitle(let value):
            runtime.windowTitle = value
            rune_linux_set_title(window, value)
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
