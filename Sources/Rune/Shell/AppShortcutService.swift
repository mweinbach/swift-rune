import Foundation

// MARK: - Attachment State Machine (shortcuts/service/machine.rs)

/// Attachment state for an `App`'s shortcut routing (`machine.rs::Attachment`).
internal enum ShortcutAttachmentState<Job> {
    case detached
    case attached(owner: ObjectIdentifier, wake: Waker, host: UInt64, jobs: [Job])
    case closed

    var host: UInt64? {
        if case .attached(_, _, let host, _) = self {
            return host
        }
        return nil
    }
}

internal enum ShortcutAttachEvent<Job> {
    case attach(owner: ObjectIdentifier, wake: Waker, host: UInt64)
    case call(from: ObjectIdentifier, shared: Bool)
    case post(Job)
    case drain(host: UInt64)
    case close
}

internal enum ShortcutAttachEffect<Job> {
    case refuse
    case run(wake: Waker)
    case wait
    case wake(Waker)
    case jobs([Job])
    case release([Job])
}

/// Pure step function for `ShortcutAttachmentState` (`machine.rs::step_attachment`).
internal func stepShortcutAttachment<Job>(
    _ state: inout ShortcutAttachmentState<Job>,
    event: ShortcutAttachEvent<Job>
) -> [ShortcutAttachEffect<Job>] {
    switch event {
    case let .attach(owner, wake, host):
        // Callers already waiting stay queued for the new host, which only its own wake
        // brings to them: the old host's wake now drains nothing.
        let jobs: [Job]
        if case .attached(_, _, _, let existing) = state {
            jobs = existing
        } else {
            jobs = []
        }
        state = .attached(owner: owner, wake: wake, host: host, jobs: jobs)
        return jobs.isEmpty ? [] : [.wake(wake)]

    case let .call(from, shared):
        switch state {
        case .attached(let owner, let wake, _, _) where shared || owner == from:
            return [.run(wake: wake)]
        case .attached:
            return [.wait]
        case .detached, .closed:
            return [.refuse]
        }

    case .post(let job):
        switch state {
        case .attached(let owner, let wake, let host, var jobs):
            jobs.append(job)
            state = .attached(owner: owner, wake: wake, host: host, jobs: jobs)
            return [.wake(wake)]
        case .detached, .closed:
            return []
        }

    case .drain(let asking):
        switch state {
        case .attached(let owner, let wake, let host, let jobs) where host == asking && !jobs.isEmpty:
            state = .attached(owner: owner, wake: wake, host: host, jobs: [])
            return [.jobs(jobs)]
        default:
            return []
        }

    case .close:
        let prev = state
        state = .closed
        if case .attached(_, _, _, let jobs) = prev {
            return [.release(jobs)]
        }
        return []
    }
}

// MARK: - Thread Identity, Hooks & Host Wake (shortcuts/service.rs)

internal func currentShortcutThreadID() -> ObjectIdentifier {
    final class ThreadToken: NSObject {}
    let key = "rune.shortcut.threadToken"
    let dict = Thread.current.threadDictionary
    if let existing = dict[key] as? ThreadToken {
        return ObjectIdentifier(existing)
    }
    let token = ThreadToken()
    dict[key] = token
    return ObjectIdentifier(token)
}

internal enum ShortcutTestHooks {
    private static let beforeWakeKey = "rune.shortcut.beforeWake"
    private static let beforeDequeueKey = "rune.shortcut.beforeDequeue"

    private final class HookBox: NSObject {
        let fn: () -> Void
        init(_ fn: @escaping () -> Void) { self.fn = fn }
    }

    static func setBeforeWake(_ hook: (() -> Void)?) {
        let dict = Thread.current.threadDictionary
        if let hook {
            dict[beforeWakeKey] = HookBox(hook)
        } else {
            dict.removeObject(forKey: beforeWakeKey)
        }
    }

    static func takeBeforeWake() -> (() -> Void)? {
        let dict = Thread.current.threadDictionary
        guard let box = dict[beforeWakeKey] as? HookBox else { return nil }
        dict.removeObject(forKey: beforeWakeKey)
        return box.fn
    }

    static func setBeforeDequeue(_ hook: (() -> Void)?) {
        let dict = Thread.current.threadDictionary
        if let hook {
            dict[beforeDequeueKey] = HookBox(hook)
        } else {
            dict.removeObject(forKey: beforeDequeueKey)
        }
    }

    static func takeBeforeDequeue() -> (() -> Void)? {
        let dict = Thread.current.threadDictionary
        guard let box = dict[beforeDequeueKey] as? HookBox else { return nil }
        dict.removeObject(forKey: beforeDequeueKey)
        return box.fn
    }
}

/// A host's wake, which stops for good as the host closes (`service.rs::HostWake`).
/// Lock is held only to clone the waker, never through the wake invocation.
internal final class ShortcutHostWake: @unchecked Sendable {
    private let lock = NSLock()
    private var waker: Waker?

    private init(_ wake: Waker) {
        self.waker = wake
    }

    static func make(_ wake: Waker) -> (waker: Waker, closer: ShortcutHostWake) {
        let host = ShortcutHostWake(wake)
        let wrapped = Waker {
            host.wake()
        }
        return (wrapped, host)
    }

    func wake() {
        if let pause = ShortcutTestHooks.takeBeforeWake() {
            pause()
        }
        lock.lock()
        let w = waker
        lock.unlock()
        w?.wake()
    }

    func close() {
        lock.lock()
        let taken = waker
        waker = nil
        lock.unlock()
        _ = taken
    }
}

internal typealias ShortcutSink = @Sendable (UInt32, String?) -> Void
internal typealias ShortcutConnectFn = @Sendable (_ wayland: Bool, _ sink: @escaping ShortcutSink) -> Result<any ShortcutBackendDriver, ShortcutError>

// MARK: - Native macOS Driver Bridge

#if os(macOS)
internal final class MacOSGlobalHotKeyDriver: ShortcutBackendDriver {
    private var backend: MacOSGlobalHotKeyBackend?
    private let sink: ShortcutSink
    private var idStrings: [UInt32: String] = [:]

    init(sink: @escaping ShortcutSink) throws {
        self.sink = sink
        if Thread.isMainThread {
            self.backend = try MainActor.assumeIsolated {
                try MacOSGlobalHotKeyBackend()
            }
        } else {
            throw ShortcutError.rejectedByOS("Global hotkeys require main thread")
        }
    }

    func register(id: UInt32, shortcut: ParsedShortcut) -> Result<Void, ShortcutError> {
        guard Thread.isMainThread, let backend else {
            return .failure(.rejectedByOS("Global hotkeys require main thread"))
        }
        guard let chord = try? Chord.parse(shortcut.description, platform: .mac) else {
            return .failure(.invalidAccelerator(shortcut.description))
        }
        let idStr = "hub-\(id)"
        let sink = self.sink
        let res = MainActor.assumeIsolated {
            backend.register(id: idStr, chord: chord) {
                sink(id, nil)
            }
        }
        if case .success = res {
            idStrings[id] = idStr
        }
        return res
    }

    func unregister(id: UInt32) -> Result<Void, ShortcutError> {
        guard Thread.isMainThread, let backend else {
            return .failure(.rejectedByOS("Global hotkeys require main thread"))
        }
        guard let idStr = idStrings.removeValue(forKey: id) else {
            return .failure(.unknownId("\(id)"))
        }
        return MainActor.assumeIsolated {
            _ = backend.unregister(id: idStr)
            return .success(())
        }
    }
}
#endif

internal func defaultShortcutConnect(wayland: Bool, sink: @escaping ShortcutSink) -> Result<any ShortcutBackendDriver, ShortcutError> {
    _ = wayland
    #if os(macOS)
    do {
        return .success(try MacOSGlobalHotKeyDriver(sink: sink))
    } catch let err as ShortcutError {
        return .failure(err)
    } catch {
        return .failure(.rejectedByOS("\(error)"))
    }
    #else
    _ = sink
    return .failure(.unsupported)
    #endif
}

private func nativeSystemShortcutOwner(_ shortcut: ParsedShortcut) -> String? {
    #if os(macOS)
    guard Thread.isMainThread,
          let chord = try? Chord.parse(shortcut.description, platform: .mac) else {
        return nil
    }
    return MainActor.assumeIsolated {
        MacOSGlobalHotKeyBackend.systemOwner(for: chord)
    }
    #else
    _ = shortcut
    return nil
    #endif
}

// MARK: - Service Engine & Thread-Local Storage

internal typealias ShortcutEngineJob = @Sendable (ShortcutServiceEngine) -> Void

internal final class ShortcutServiceEngine {
    let title: String
    let wayland: Bool
    let sink: ShortcutSink
    let connect: ShortcutConnectFn
    let claims: ShortcutProcessClaims
    var bindings: ShortcutBindingsState<any ShortcutBackendDriver>

    init(
        title: String,
        wayland: Bool,
        sink: @escaping ShortcutSink,
        connect: @escaping ShortcutConnectFn = defaultShortcutConnect,
        bindings: ShortcutBindingsState<any ShortcutBackendDriver>,
        claims: ShortcutProcessClaims = .shared
    ) {
        self.title = title
        self.wayland = wayland
        self.sink = sink
        self.connect = connect
        self.bindings = bindings
        self.claims = claims
    }

    deinit {
        release()
    }

    private var engineID: ObjectIdentifier { ObjectIdentifier(self) }

    func register(id: UInt32, shortcut: ParsedShortcut) -> Result<Void, ShortcutError> {
        let alreadyClaimed: Bool
        if case .virtual = bindings {
            alreadyClaimed = false
        } else {
            alreadyClaimed = claims.isClaimed(shortcut)
        }
        return apply(.register(id: id, shortcut: shortcut, claimed: alreadyClaimed))
    }

    func unregister(id: UInt32) -> Result<Void, ShortcutError> {
        apply(.unregister(id))
    }

    func owner(of shortcut: ParsedShortcut) -> String? {
        if bindings.find(shortcut) != nil {
            return title
        }
        if case .virtual = bindings {
            return nil
        }
        return claims.owner(of: shortcut) ?? nativeSystemShortcutOwner(shortcut)
    }

    func release() {
        _ = apply(.release)
    }

    private func apply(_ event: ShortcutBindEvent<any ShortcutBackendDriver>) -> Result<Void, ShortcutError> {
        var answer: Result<Void, ShortcutError> = .success(())
        for effect in stepShortcutBindings(&bindings, event: event) {
            switch effect {
            case .refuse(let err):
                if case .alreadyInUse(owner: nil) = err,
                   case .register(_, let sc, _) = event {
                    answer = .failure(.alreadyInUse(owner: owner(of: sc)))
                } else {
                    answer = .failure(err)
                }
            case let .connect(id, shortcut):
                switch connect(wayland, sink) {
                case .success(let driver):
                    answer = apply(.opened(native: driver, id: id, shortcut: shortcut))
                case .failure(let err):
                    answer = .failure(err)
                }
            case let .bind(id, shortcut):
                guard case .connected(let driver, _) = bindings else {
                    answer = .failure(.rejectedByOS("not connected"))
                    continue
                }
                switch driver.register(id: id, shortcut: shortcut) {
                case .success:
                    answer = apply(.bound(id: id, shortcut: shortcut))
                case .failure(let err):
                    answer = apply(.rejected(err))
                }
            case .unbind(let id):
                guard case .connected(let driver, _) = bindings else {
                    answer = .failure(.unknownId("\(id)"))
                    continue
                }
                switch driver.unregister(id: id) {
                case .success:
                    answer = apply(.unbound(id))
                case .failure(let err):
                    answer = .failure(err)
                }
            case let .claim(id, shortcut):
                claims.claim(shortcut: shortcut, engineID: engineID, regID: id, owner: title)
            case .disclaim(let id):
                claims.disclaim(engineID: engineID, regID: id)
            case .disclaimAll:
                claims.disclaimAll(engineID: engineID)
            case .disconnect:
                // Driver drops as `bindings` transitioned to `.disconnected` / `effect` goes out of scope.
                break
            }
        }
        return answer
    }
}

private final class ThreadLocalEnginesBox: NSObject {
    var entries: [UInt64: (generation: UInt64, engine: ShortcutServiceEngine)] = [:]
}

private enum ThreadLocalEngines {
    private static let key = "rune.shortcut.engines"

    static func table() -> ThreadLocalEnginesBox {
        let dict = Thread.current.threadDictionary
        if let existing = dict[key] as? ThreadLocalEnginesBox {
            return existing
        }
        let created = ThreadLocalEnginesBox()
        dict[key] = created
        return created
    }
}

// MARK: - Receiving Thread-Local Scope

internal enum ShortcutReceiving {
    private static let key = "rune.shortcut.receivingGeneration"

    private final class GenBox: NSObject {
        let generation: UInt64
        init(_ generation: UInt64) { self.generation = generation }
    }

    static var current: UInt64? {
        (Thread.current.threadDictionary[key] as? GenBox)?.generation
    }

    static func replace(with next: UInt64?) -> UInt64? {
        let dict = Thread.current.threadDictionary
        let prev = (dict[key] as? GenBox)?.generation
        if let next {
            dict[key] = GenBox(next)
        } else {
            dict.removeObject(forKey: key)
        }
        return prev
    }
}

/// Restores the prior receiving generation when dropped (`service.rs::Receiving`).
internal final class ShortcutReceivingScope {
    private let previous: UInt64?
    private var ended = false

    init(_ previous: UInt64?) {
        self.previous = previous
    }

    func end() {
        guard !ended else { return }
        ended = true
        _ = ShortcutReceiving.replace(with: previous)
    }

    deinit {
        end()
    }
}

// MARK: - Counters, Control, Hub, Delivery, Guard

private final class ShortcutGlobalCounters: @unchecked Sendable {
    let lock = NSLock()
    var nextOwner: UInt64 = 1
    var nextId: UInt32 = 1
    var nextGeneration: UInt64 = 1

    func takeOwner() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let v = nextOwner
        nextOwner &+= 1
        return v
    }

    func takeId() -> Result<UInt32, ShortcutError> {
        lock.lock()
        defer { lock.unlock() }
        guard nextId < UInt32.max else {
            return .failure(.rejectedByOS("shortcut id space exhausted"))
        }
        let v = nextId
        nextId += 1
        return .success(v)
    }

    func takeGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let v = nextGeneration
        nextGeneration &+= 1
        return v
    }
}

private let shortcutGlobalCounters = ShortcutGlobalCounters()

internal final class ShortcutStamp: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func load() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func store(_ next: UInt64) {
        lock.lock()
        value = next
        lock.unlock()
    }
}

internal final class ShortcutLiveToken: @unchecked Sendable {}

internal final class ShortcutControl: @unchecked Sendable {
    let key: UInt64 = shortcutGlobalCounters.takeOwner()
    let lock = NSLock()
    var attachment: ShortcutAttachmentState<ShortcutEngineJob> = .detached
    var hosts: UInt64 = 0
    var currentGeneration: UInt64 = 0

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentGeneration == generation
    }

    func call<T: Sendable>(
        _ body: @escaping @Sendable (ShortcutServiceEngine) -> Result<T, ShortcutError>
    ) -> Result<T, ShortcutError> {
        callStamped(nil, body)
    }

    func callStamped<T: Sendable>(
        _ stamp: ShortcutStamp?,
        _ body: @escaping @Sendable (ShortcutServiceEngine) -> Result<T, ShortcutError>
    ) -> Result<T, ShortcutError> {
        lock.lock()
        let call = ShortcutAttachEvent<ShortcutEngineJob>.call(from: currentShortcutThreadID(), shared: false)
        let effect = stepShortcutAttachment(&attachment, event: call).first
        if let stamp {
            stamp.store(hosts)
        }
        switch effect {
        case .run(let wake):
            lock.unlock()
            guard let entry = ThreadLocalEngines.table().entries[key] else {
                return .failure(.notRunning)
            }
            let result = body(entry.engine)
            wake.wake()
            return result

        case .wait:
            let box = ShortcutReplyBox<T>()
            let wakes = postShortcutJob(&attachment, box: box, body: body)
            lock.unlock()
            for wake in wakes {
                wake.wake()
            }
            return box.wait()

        default:
            lock.unlock()
            return .failure(.notRunning)
        }
    }
}

private func postShortcutJob<T: Sendable>(
    _ state: inout ShortcutAttachmentState<ShortcutEngineJob>,
    box: ShortcutReplyBox<T>,
    body: @escaping @Sendable (ShortcutServiceEngine) -> Result<T, ShortcutError>
) -> [Waker] {
    let sender = ShortcutSenderToken(box)
    let posted = stepShortcutAttachment(&state, event: .post { engine in
        let value = body(engine)
        sender.deliver(value)
    })
    return posted.compactMap { eff in
        if case .wake(let wake) = eff {
            return wake
        }
        return nil
    }
}

private final class ShortcutSenderToken<T>: @unchecked Sendable {
    private let box: ShortcutReplyBox<T>
    init(_ box: ShortcutReplyBox<T>) { self.box = box }
    func deliver(_ value: Result<T, ShortcutError>) {
        box.deliver(value)
    }
    deinit {
        box.deliver(.failure(.notRunning))
    }
}

private final class ShortcutReplyBox<T>: @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<T, ShortcutError> = .failure(.notRunning)
    private var resolved = false

    func deliver(_ value: Result<T, ShortcutError>) {
        lock.lock()
        let shouldSignal = !resolved
        if shouldSignal {
            result = value
            resolved = true
        }
        lock.unlock()
        if shouldSignal {
            sem.signal()
        }
    }

    func wait() -> Result<T, ShortcutError> {
        sem.wait()
        lock.lock()
        let out = result
        lock.unlock()
        return out
    }

    deinit {
        deliver(.failure(.notRunning))
    }
}

internal final class ShortcutHandlersBox<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt32: (stamp: ShortcutStamp, handler: @Sendable (inout State, inout Tx) -> Void)] = [:]

    func insert(
        id: UInt32,
        stamp: ShortcutStamp,
        handler: @escaping @Sendable (inout State, inout Tx) -> Void
    ) {
        lock.lock()
        storage[id] = (stamp, handler)
        lock.unlock()
    }

    func remove(id: UInt32) {
        lock.lock()
        storage.removeValue(forKey: id)
        lock.unlock()
    }

    func handler(for id: UInt32) -> (@Sendable (inout State, inout Tx) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return storage[id]?.handler
    }

    func retainAfter(ended: UInt64) {
        lock.lock()
        storage = storage.filter { $0.value.stamp.load() > ended }
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    var isEmpty: Bool { count == 0 }
}

/// Per-`AppShared` shortcut service hub (`service.rs::Hub<S>`).
public final class ShortcutHub<State>: @unchecked Sendable {
    internal let control = ShortcutControl()
    internal let handlers = ShortcutHandlersBox<State>()
    private let lock = NSLock()
    private var pendingEntries: [(Result<ParsedShortcut, ShortcutError>, @Sendable (inout State, inout Tx) -> Void)] = []
    private var errorsList: [ShortcutError] = []
    private var titleValue: String = ""
    private var unmodifiedAllowed: Bool = false

    public init() {}

    public func named(_ title: String) {
        lock.lock()
        if titleValue.isEmpty {
            titleValue = title
        }
        lock.unlock()
    }

    public func currentTitle() -> String {
        lock.lock()
        defer { lock.unlock() }
        return titleValue
    }

    public func allowUnmodified() {
        setAllowUnmodified(true)
    }

    internal func setAllowUnmodified(_ allow: Bool) {
        lock.lock()
        unmodifiedAllowed = allow
        lock.unlock()
    }

    internal var hasPendingEntries: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pendingEntries.isEmpty
    }

    public var isUnmodifiedAllowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return unmodifiedAllowed
    }

    internal func enqueuePending(
        _ shortcut: Result<ParsedShortcut, ShortcutError>,
        handler: @escaping @Sendable (inout State, inout Tx) -> Void
    ) {
        lock.lock()
        pendingEntries.append((shortcut, handler))
        lock.unlock()
    }

    internal func takePending() -> [(Result<ParsedShortcut, ShortcutError>, @Sendable (inout State, inout Tx) -> Void)] {
        lock.lock()
        let out = pendingEntries
        pendingEntries.removeAll()
        lock.unlock()
        return out
    }

    internal func recordError(_ error: ShortcutError) {
        lock.lock()
        errorsList.append(error)
        lock.unlock()
    }

    public func takeErrors() -> [ShortcutError] {
        lock.lock()
        let out = errorsList
        errorsList.removeAll()
        lock.unlock()
        return out
    }

    public func register(
        _ shortcut: ParsedShortcut,
        handler: @escaping @Sendable (inout State, inout Tx) -> Void
    ) -> Result<UInt32, ShortcutError> {
        if !isUnmodifiedAllowed {
            do {
                try shortcut.requireModifier()
            } catch let err as ShortcutError {
                return .failure(err)
            } catch {
                return .failure(.invalidAccelerator("\(error)"))
            }
        }
        let id: UInt32
        switch shortcutGlobalCounters.takeId() {
        case .success(let v): id = v
        case .failure(let err): return .failure(err)
        }
        let stamp = ShortcutStamp()
        handlers.insert(id: id, stamp: stamp, handler: handler)
        let res = control.callStamped(stamp) { engine in
            engine.register(id: id, shortcut: shortcut)
        }
        if case .failure(let err) = res {
            handlers.remove(id: id)
            return .failure(err)
        }
        return .success(id)
    }

    public func unregister(_ id: UInt32) -> Result<Void, ShortcutError> {
        let handlers = self.handlers
        return control.call { engine in
            let res = engine.unregister(id: id)
            if case .success = res {
                handlers.remove(id: id)
            }
            return res
        }
    }

    public func owner(of shortcut: ParsedShortcut) -> String? {
        let res = control.call { engine in
            .success(engine.owner(of: shortcut))
        }
        if case .success(let name) = res {
            return name
        }
        return nil
    }

    public func fire(_ shortcut: ParsedShortcut) -> Result<Void, ShortcutError> {
        let res: Result<(UInt32, ShortcutSink), ShortcutError> = control.call { engine in
            guard let id = engine.bindings.find(shortcut) else {
                return .failure(.unknownId("\(shortcut)"))
            }
            return .success((id, engine.sink))
        }
        switch res {
        case .success(let (id, sink)):
            sink(id, nil)
            return .success(())
        case .failure(let err):
            return .failure(err)
        }
    }
}

// MARK: - Delivery & Activation Routing

private final class ShortcutDelivery<State>: @unchecked Sendable {
    weak var shared: AppShared<State>?
    let generation: UInt64
    let wake: Waker
    weak var live: ShortcutLiveToken?
    private let pressedLock = NSLock()
    private var pressed: [(id: UInt32, token: String?)] = []

    init(shared: AppShared<State>, generation: UInt64, wake: Waker, live: ShortcutLiveToken) {
        self.shared = shared
        self.generation = generation
        self.wake = wake
        self.live = live
    }

    func push(id: UInt32, token: String?) {
        pressedLock.lock()
        pressed.append((id, token))
        pressedLock.unlock()
    }

    func popFront() -> (id: UInt32, token: String?)? {
        pressedLock.lock()
        defer { pressedLock.unlock() }
        guard !pressed.isEmpty else { return nil }
        return pressed.removeFirst()
    }
}

private func makeShortcutSink<State>(delivery: ShortcutDelivery<State>) -> ShortcutSink {
    return { id, token in
        guard delivery.live != nil, let shared = delivery.shared else { return }
        delivery.push(id: id, token: token)
        shared.queueUpdateIfWithoutWake(makeShortcutDeliverUpdate(delivery: delivery))
        delivery.wake.wake()
    }
}

private func makeShortcutDeliverUpdate<State>(
    delivery: ShortcutDelivery<State>
) -> @Sendable (_ state: inout State, _ tx: inout Tx) -> Bool {
    return { state, tx in
        func discard() -> Bool {
            _ = delivery.popFront()
            return false
        }
        guard let shared = delivery.shared else {
            return discard()
        }
        guard shared.shortcuts.control.isCurrent(delivery.generation) else {
            return discard()
        }
        guard ShortcutReceiving.current == delivery.generation else {
            guard delivery.live != nil else {
                return discard()
            }
            shared.queueUpdateIfWithoutWake(makeShortcutDeliverUpdate(delivery: delivery))
            delivery.wake.wake()
            return false
        }
        guard let (id, token) = delivery.popFront() else {
            return false
        }
        guard let handler = shared.shortcuts.handlers.handler(for: id) else {
            return false
        }
        tx.shortcutActivationToken = token
        handler(&state, &tx)
        tx.shortcutActivationToken = nil
        return true
    }
}

// MARK: - Guard, Attaching & Closing

internal struct ShortcutClosing {
    var ended: UInt64
    var current: Bool
}

internal final class ShortcutAttaching {
    let control: ShortcutControl
    let generation: UInt64
    let wake: Waker
    let closesWake: ShortcutHostWake
    let live: ShortcutLiveToken

    fileprivate init(
        control: ShortcutControl,
        generation: UInt64,
        wake: Waker,
        closesWake: ShortcutHostWake,
        live: ShortcutLiveToken
    ) {
        self.control = control
        self.generation = generation
        self.wake = wake
        self.closesWake = closesWake
        self.live = live
    }

    func route<State>(shared: AppShared<State>) -> ShortcutGuard {
        control.lock.lock()
        control.hosts &+= 1
        control.currentGeneration = generation
        let routed = stepShortcutAttachment(
            &control.attachment,
            event: .attach(owner: currentShortcutThreadID(), wake: wake, host: generation)
        )
        control.lock.unlock()

        for eff in routed {
            if case .wake(let w) = eff {
                w.wake()
            }
        }

        let handlers = shared.shortcuts.handlers
        let cleanup: (UInt64) -> Void = { ended in
            handlers.retainAfter(ended: ended)
        }
        let guardObj = ShortcutGuard(
            control: control,
            generation: generation,
            cleanup: cleanup,
            live: live,
            closesWake: closesWake
        )
        for (shortcutResult, handler) in shared.shortcuts.takePending() {
            let outcome: Result<Void, ShortcutError>
            switch shortcutResult {
            case .success(let sc):
                outcome = shared.shortcuts.register(sc, handler: handler).map { _ in () }
            case .failure(let err):
                outcome = .failure(err)
            }
            if case .failure(let error) = outcome {
                if let data = "rune: \(error)\n".data(using: .utf8) {
                    FileHandle.standardError.write(data)
                }
                shared.shortcuts.recordError(error)
            }
        }
        return guardObj
    }
}

/// Host-owned shortcut service guard (`service.rs::Guard`).
/// Closing or dropping releases the engine, routing, and host handlers.
public final class ShortcutGuard {
    private let control: ShortcutControl
    internal let generation: UInt64
    internal var cleanup: ((UInt64) -> Void)?
    private var live: ShortcutLiveToken?
    private weak var closesWake: ShortcutHostWake?
    private var didClose = false

    fileprivate init(
        control: ShortcutControl,
        generation: UInt64,
        cleanup: @escaping (UInt64) -> Void,
        live: ShortcutLiveToken,
        closesWake: ShortcutHostWake
    ) {
        self.control = control
        self.generation = generation
        self.cleanup = cleanup
        self.live = live
        self.closesWake = closesWake
    }

    public static func attach<State>(
        shared: AppShared<State>,
        wake: Waker,
        headless: Bool,
        wayland: Bool = false
    ) -> ShortcutGuard {
        attachWith(shared: shared, wake: wake, headless: headless, wayland: wayland, connect: defaultShortcutConnect)
    }

    internal static func attachWith<State>(
        shared: AppShared<State>,
        wake: Waker,
        headless: Bool,
        wayland: Bool = false,
        connect: @escaping ShortcutConnectFn
    ) -> ShortcutGuard {
        install(shared: shared, wake: wake, headless: headless, wayland: wayland, connect: connect)
            .route(shared: shared)
    }

    internal static func install<State>(
        shared: AppShared<State>,
        wake: Waker,
        headless: Bool,
        wayland: Bool = false,
        connect: @escaping ShortcutConnectFn = defaultShortcutConnect
    ) -> ShortcutAttaching {
        let control = shared.shortcuts.control
        let title = shared.shortcuts.currentTitle()
        let bindings: ShortcutBindingsState<any ShortcutBackendDriver> = headless ? .virtual([:]) : .disconnected
        let live = ShortcutLiveToken()
        let (hostWake, closer) = ShortcutHostWake.make(wake)
        let generation = shortcutGlobalCounters.takeGeneration()
        let delivery = ShortcutDelivery(shared: shared, generation: generation, wake: hostWake, live: live)
        let engine = ShortcutServiceEngine(
            title: title,
            wayland: wayland,
            sink: makeShortcutSink(delivery: delivery),
            connect: connect,
            bindings: bindings
        )
        ThreadLocalEngines.table().entries[control.key] = (generation, engine)
        return ShortcutAttaching(
            control: control,
            generation: generation,
            wake: hostWake,
            closesWake: closer,
            live: live
        )
    }

    internal func receiving() -> ShortcutReceivingScope {
        let prev = ShortcutReceiving.replace(with: generation)
        return ShortcutReceivingScope(prev)
    }

    public func withReceiving<R>(_ body: () throws -> R) rethrows -> R {
        let scope = receiving()
        defer { scope.end() }
        return try body()
    }

    public func drain() {
        if let pause = ShortcutTestHooks.takeBeforeDequeue() {
            pause()
        }
        control.lock.lock()
        let effects = stepShortcutAttachment(&control.attachment, event: .drain(host: generation))
        control.lock.unlock()

        guard case .jobs(let jobs) = effects.first else { return }
        guard let installed = ThreadLocalEngines.table().entries[control.key],
              installed.generation == generation else {
            return
        }
        for job in jobs {
            job(installed.engine)
        }
    }

    internal func closeRouting() -> ShortcutClosing {
        closesWake?.close()
        live = nil
        control.lock.lock()
        let closed = stepShortcutAttachment(&control.attachment, event: .close)
        let ended = control.hosts
        let current = control.currentGeneration == generation
        control.lock.unlock()
        // Drop queued jobs outside lock.
        _ = closed
        return ShortcutClosing(ended: ended, current: current)
    }

    internal func releaseEngine(_ closing: inout ShortcutClosing) {
        _ = closing
        let table = ThreadLocalEngines.table()
        if let existing = table.entries[control.key], existing.generation == generation {
            table.entries.removeValue(forKey: control.key)
        }
    }

    internal func end(_ closing: ShortcutClosing) {
        guard closing.current else { return }
        if let fn = cleanup {
            cleanup = nil
            fn(closing.ended)
        }
    }

    public func close() {
        guard !didClose else { return }
        didClose = true
        closesWake?.close()
        live = nil
        var closing = closeRouting()
        releaseEngine(&closing)
        end(closing)
    }

    deinit {
        close()
    }
}
