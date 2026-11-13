import Foundation
import Rune

public enum LogLevel: String, Sendable, Equatable {
    case info
    case warn
    case error
}

public struct LogLine: Sendable, Equatable {
    public var level: LogLevel
    public var message: String

    public init(level: LogLevel, message: String) {
        self.level = level
        self.message = message
    }
}

public struct ReloadReport: Sendable, Equatable {
    public var compileDuration: Duration
    public var swapDuration: Duration

    public init(compileDuration: Duration = .zero, swapDuration: Duration = .zero) {
        self.compileDuration = compileDuration
        self.swapDuration = swapDuration
    }
}

public struct ScriptMetrics: Sendable, Equatable {
    public var vmCalls: UInt64 = 0
    public var vmTime: Duration = .zero
    public var renders: UInt64 = 0
    public var rows: UInt64 = 0
    public var reloads: UInt64 = 0
    public var lastReload: ReloadReport? = nil
}

/// Host bindings exposed to a `ScriptOptions.setup` callback.
public final class LuauHost: @unchecked Sendable {
    public let vm: LuauVM
    private let shared: SharedScriptState
    private let signals: SignalRegistry
    private let prelude: LuauTable

    internal init(vm: LuauVM, shared: SharedScriptState, signals: SignalRegistry, prelude: LuauTable) {
        self.vm = vm
        self.shared = shared
        self.signals = signals
        self.prelude = prelude
    }

    public func registerModule(_ name: String, value: LuauValue) {
        vm.registeredModules[name] = value
    }

    public func global(_ name: String, value: LuauValue) {
        vm.globals.rawSet(name, value: value)
    }

    public func signal(_ name: String) throws -> LuauValue {
        let ctor = prelude.rawGet("signal")
        let sig = try vm.call(value: ctor).first ?? .nil
        signals.map[name] = sig
        return sig
    }

    public func scriptSignal() -> LuauValue {
        prelude.rawGet("scriptSignal")
    }

    public func asyncFunction(
        _ name: String,
        start: @escaping @Sendable ([LuauValue], Completer) throws -> Void
    ) throws -> LuauValue {
        let submit = LuauNativeFunction(name: "\(name)_submit") { _, _, args in
            let completer = self.shared.makeJob()
            let id = completer.id
            try start(args, completer)
            return .values([.number(Double(id))])
        }
        let asyncWrapper = prelude.rawGet("async")
        return try vm.call(value: asyncWrapper, args: [.nativeFunction(submit), .string(name)]).first ?? .nil
    }
}

internal final class SignalRegistry: @unchecked Sendable {
    var map: [String: LuauValue] = [:]
}

/// Configuration for hosting a `Script`.
public struct ScriptOptions: @unchecked Sendable {
    public typealias AroundWriteHook = @Sendable (_ state: inout Any, _ tx: UnsafeMutablePointer<Tx>?, _ body: (UnsafeMutablePointer<Tx>?) -> Void) -> Void
    public typealias AroundReadHook = @Sendable (_ state: Any, _ body: () -> Void) -> Void

    public var palette: Palette = defaultPalette()
    public var shadows: Shadows? = nil
    public var setup: (@Sendable (LuauHost) throws -> Void)? = nil
    public var start: (@Sendable (LuauVM, LuauTable, UInt64) throws -> Void)? = nil
    public var around: AroundWriteHook? = nil
    public var aroundRead: AroundReadHook? = nil
    public var nodes: [HostNode] = []
    public var timeLimit: Duration = .milliseconds(250)
    public var instructionLimit: Int? = nil
    public var memoryLimit: Int = 64 << 20
    public var onLog: (@Sendable (LogLevel, String) -> Void)? = nil
    public var baseTextStyle: TextStyle = TextStyle(size: 13, weight: 400)
    public var weights: [Float] = [400, 500, 600, 700]

    public init() {}

    public func palette(_ p: @escaping Palette) -> ScriptOptions {
        var copy = self; copy.palette = p; return copy
    }
    public func shadows(_ s: @escaping Shadows) -> ScriptOptions {
        var copy = self; copy.shadows = s; return copy
    }
    public func setup(_ f: @escaping @Sendable (LuauHost) throws -> Void) -> ScriptOptions {
        var copy = self; copy.setup = f; return copy
    }
    public func start(_ f: @escaping @Sendable (LuauVM, LuauTable, UInt64) throws -> Void) -> ScriptOptions {
        var copy = self; copy.start = f; return copy
    }
    public func around(_ f: @escaping AroundWriteHook) -> ScriptOptions {
        var copy = self; copy.around = f; return copy
    }
    public func aroundRead(_ f: @escaping AroundReadHook) -> ScriptOptions {
        var copy = self; copy.aroundRead = f; return copy
    }
    public func node(_ n: HostNode) -> ScriptOptions {
        var copy = self; copy.nodes.append(n); return copy
    }
    public func timeLimit(_ limit: Duration) -> ScriptOptions {
        var copy = self; copy.timeLimit = limit; return copy
    }
    public func instructionLimit(_ limit: Int?) -> ScriptOptions {
        var copy = self; copy.instructionLimit = limit; return copy
    }
    public func memoryLimit(_ bytes: Int) -> ScriptOptions {
        var copy = self; copy.memoryLimit = bytes; return copy
    }
    public func onLog(_ f: @escaping @Sendable (LogLevel, String) -> Void) -> ScriptOptions {
        var copy = self; copy.onLog = f; return copy
    }
    public func text(_ base: TextStyle, weights: [Float] = [400, 500, 600, 700]) -> ScriptOptions {
        var copy = self; copy.baseTextStyle = base; copy.weights = weights; return copy
    }
}

/// A hosted Luau script: one sandboxed VM driving Rune `El<State>` trees, tasks, signals, and hot reload.
public final class Script: @unchecked Sendable {
    private static let nextIDLock = NSLock()
    nonisolated(unsafe) private static var nextVMID: UInt64 = 1

    private static func allocVMID() -> UInt64 {
        nextIDLock.lock()
        defer { nextIDLock.unlock() }
        let id = nextVMID
        nextVMID += 1
        return id
    }

    public let name: String
    public let prefix: String
    public let options: ScriptOptions

    private var vm: LuauVM?
    private var vmID: UInt64 = 0
    private var moduleTable: LuauTable?
    private var sched: LuauTaskScheduler?
    private var signals = SignalRegistry()
    private var fireFn: LuauValue = .nil
    private var currentSources: Sources
    private var failedError: ScriptError?
    public private(set) var version: UInt64 = 1
    private var salt: UInt64 = 1
    private var clock: Double = 0.0
    private var nextDeadline: Double = .infinity
    private var _metrics = ScriptMetrics()
    private var logLines: [LogLine] = []
    private let shared = SharedScriptState()
    private var prewarmedBase: (vm: LuauVM, vmID: UInt64, sched: LuauTaskScheduler, signals: SignalRegistry, fireFn: LuauValue)?
    private var warnedMessages: Set<String> = []
    private var virtualListStates: [String: VirtualListState] = [:]
    private var rowKeyCaches: [String: (ver: UInt64, map: [Int: String])] = [:]
    private var visibleRowRanges: [String: (Int, Int)] = [:]
    private var trackedScrollKeysBySurface: [String: [String]] = [:]
    private var pendingPressMods: Mods = Mods()
    private var watcher: LuauFolderWatcher?

    public init(name: String, sources: Sources, options: ScriptOptions = ScriptOptions()) {
        self.name = name
        self.prefix = "luau:\(name):"
        self.options = options
        self.currentSources = sources

        do {
            let compiled = try sources.compile()
            _ = try swap(compiled: compiled)
        } catch let err as ScriptError {
            fail(err)
        } catch {
            fail(ScriptError(kind: .runtime, message: error.localizedDescription))
        }
    }

    public func setWaker(_ waker: Waker) {
        shared.setWaker(waker)
    }

    public var error: ScriptError? { failedError }
    public var log: [LogLine] { logLines }
    public var metrics: ScriptMetrics { _metrics }
    public var sources: Sources { currentSources }
    public var vmId: UInt64? { vm == nil ? nil : vmID }
    public var module: LuauTable? { moduleTable }
    public func memoPrefix() -> String { prefix }
    public func memory() -> Int { vm?.estimatedMemoryBytes() ?? 0 }

    /// Runs due tasks, timers, host async completions, and folder-watch reloads.
    @discardableResult
    public func poll(now: Double, tx: inout Tx) -> Bool {
        clock = now
        var reloaded = false
        if let watcher {
            let (saving, ready) = watcher.takeReady()
            if let ready {
                switch ready {
                case .success(let (newSources, compiled, compileDur)):
                    do {
                        var report = try swap(compiled: compiled)
                        report.compileDuration = compileDur
                        currentSources = newSources
                        noteReload(report)
                        reloaded = true
                    } catch let err as ScriptError {
                        appendLog(.error, err.message)
                    } catch {
                        appendLog(.error, error.localizedDescription)
                    }
                case .failure(let err):
                    appendLog(.error, err.message)
                }
            } else if saving {
                prewarm()
            }
        }

        let arrived = shared.takeDirty()
        if !arrived && now < nextDeadline {
            return reloaded
        }
        guard let vm, let sched else { return reloaded }
        let resumed = runTimed {
            sched.poll(vm: vm, now: now)
        }
        let changed = sched.takeChanged()
        settle(tx: &tx, bumpVersion: resumed > 0 || changed)
        return reloaded || resumed > 0
    }

    /// Renders the `render` surface of the script, memoized on `version`.
    public func view<State>(_ cx: Cx<State>) -> El<State> {
        surface(cx, name: "render")
    }

    /// Renders a named surface `name(view)` from the script's exported table.
    public func surface<State>(_ cx: Cx<State>, name: String) -> El<State> {
        let dark = cx.systemDark
        let id = "\(prefix)\(name)"
        let tracked = trackedScrollKeysBySurface[name] ?? []
        var scrollHasher = Hasher()
        scrollHasher.combine(cx.viewport.x.bitPattern)
        scrollHasher.combine(cx.viewport.y.bitPattern)
        for k in tracked {
            let off = cx.scrollOffset(of: k)
            scrollHasher.combine(k)
            scrollHasher.combine(off.x.bitPattern)
            scrollHasher.combine(off.y.bitPattern)
        }
        let scrollDep = UInt64(bitPattern: Int64(scrollHasher.finalize()))
        let deps = mix(mix(version, salt), scrollDep)
        let viewport = cx.viewport
        return Rune.memo(id, deps: deps) {
            aroundRead(state: ()) {
                renderUncached(
                    name: name,
                    dark: dark,
                    viewport: viewport,
                    scrollLookup: { cx.scrollOffset(of: $0) },
                    State.self
                ).key(id)
            }
        }
    }

    /// Renders surface `name` immediately without memoization.
    public func renderUncached<State>(
        name: String,
        dark: Bool,
        viewport: Vec2 = .zero,
        scrollLookup: ((String) -> Vec2)? = nil,
        _ type: State.Type = State.self
    ) -> El<State> {
        let card: (String) -> El<State> = { [weak self] msg in
            let palette = self?.options.palette ?? defaultPalette()
            return LuauCard.errorCard(message: msg, palette: palette, dark: dark) { [weak self] _, _ in
                guard let self else { return }
                do {
                    _ = try self.reload(self.currentSources)
                } catch let err as ScriptError {
                    self.fail(err)
                } catch {
                    self.fail(ScriptError(kind: .runtime, message: error.localizedDescription))
                }
            }
        }
        if let failedError {
            return card(failedError.message)
        }
        guard let vm, let moduleTable else {
            return card("the script isn't running")
        }
        let renderFnVal = moduleTable.rawGet(name)
        guard !renderFnVal.isNil else {
            return card("init.luau exports no \(name) function")
        }

        let env = UIRenderEnv(
            script: self,
            vmID: vmID,
            salt: salt,
            version: version,
            dark: dark,
            viewport: viewport,
            scrollLookup: scrollLookup,
            palette: options.palette,
            shadows: options.shadows,
            baseTextStyle: options.baseTextStyle,
            weights: options.weights,
            prefix: prefix
        )

        do {
            let el: El<State> = try LuauUIBridge.withSession(vm: vm, stateType: State.self, env: env) { viewTable in
                try runTimed {
                    let res = try vm.call(value: renderFnVal, args: [.table(viewTable)]).first ?? .nil
                    return try LuauUIBridge.unwrapEl(res, State.self)
                }
            }
            trackedScrollKeysBySurface[name] = env.trackedScrollKeys
            _metrics.renders += 1
            if env.memoFailed {
                salt &+= 1
            }
            noteSchedule()
            return el
        } catch let err as LuauRuntimeError {
            let se = err.toScriptError()
            appendLog(.error, se.message)
            salt &+= 1
            noteSchedule()
            return card(se.message)
        } catch let err as ScriptError {
            appendLog(.error, err.message)
            salt &+= 1
            noteSchedule()
            return card(err.message)
        } catch {
            appendLog(.error, error.localizedDescription)
            salt &+= 1
            noteSchedule()
            return card(error.localizedDescription)
        }
    }

    /// Renders a Luau callback function `(view, ...args) -> El` as a memoized surface.
    public func renderFn<State>(
        _ id: String,
        version fnVersion: UInt64,
        dark: Bool,
        state: State? = nil,
        fn: LuauValue,
        args: [LuauValue] = [],
        viewport: Vec2 = .zero,
        scrollLookup: ((String) -> Vec2)? = nil
    ) -> El<State> {
        let surfaceID = "\(prefix)fn:\(id)"
        let tracked = trackedScrollKeysBySurface[surfaceID] ?? []
        var scrollHasher = Hasher()
        scrollHasher.combine(viewport.x.bitPattern)
        scrollHasher.combine(viewport.y.bitPattern)
        for k in tracked {
            let off = scrollLookup?(k) ?? .zero
            scrollHasher.combine(k)
            scrollHasher.combine(off.x.bitPattern)
            scrollHasher.combine(off.y.bitPattern)
        }
        let scrollDep = UInt64(bitPattern: Int64(scrollHasher.finalize()))
        let deps = mix(mix(mix(version, salt), fnVersion), scrollDep)
        let card: (String) -> El<State> = { [weak self] msg in
            let palette = self?.options.palette ?? defaultPalette()
            return LuauCard.errorCard(message: msg, palette: palette, dark: dark) { [weak self] _, _ in
                guard let self else { return }
                do {
                    _ = try self.reload(self.currentSources)
                } catch let err as ScriptError {
                    self.fail(err)
                } catch {
                    self.fail(ScriptError(kind: .runtime, message: error.localizedDescription))
                }
            }
        }
        return Rune.memo(surfaceID, deps: deps) {
            aroundRead(state: state as Any) {
                if let failedError {
                    return card(failedError.message)
                }
                guard let vm else {
                    return card("the script isn't running")
                }
                let env = UIRenderEnv(
                    script: self,
                    vmID: vmID,
                    salt: salt,
                    version: version,
                    dark: dark,
                    viewport: viewport,
                    scrollLookup: scrollLookup,
                    palette: options.palette,
                    shadows: options.shadows,
                    baseTextStyle: options.baseTextStyle,
                    weights: options.weights,
                    prefix: "\(surfaceID):"
                )
                do {
                    let el: El<State> = try LuauUIBridge.withSession(vm: vm, stateType: State.self, env: env) { viewTable in
                        try runTimed {
                            let res = try vm.call(value: fn, args: [.table(viewTable)] + args).first ?? .nil
                            return try LuauUIBridge.unwrapEl(res, State.self)
                        }
                    }
                    trackedScrollKeysBySurface[surfaceID] = env.trackedScrollKeys
                    _metrics.renders += 1
                    if env.memoFailed {
                        salt &+= 1
                    }
                    noteSchedule()
                    return el.key(surfaceID)
                } catch let err as LuauRuntimeError {
                    let se = err.toScriptError()
                    appendLog(.error, se.message)
                    salt &+= 1
                    noteSchedule()
                    return card(se.message)
                } catch let err as ScriptError {
                    appendLog(.error, err.message)
                    salt &+= 1
                    noteSchedule()
                    return card(err.message)
                } catch {
                    appendLog(.error, error.localizedDescription)
                    salt &+= 1
                    noteSchedule()
                    return card(error.localizedDescription)
                }
            }
        }
    }

    /// Convenience `renderFn` using `Cx<State>` for viewport, dark mode, and live scroll lookup.
    public func renderFn<State>(
        _ cx: Cx<State>,
        id: String,
        version fnVersion: UInt64 = 0,
        fn: LuauValue,
        args: [LuauValue] = []
    ) -> El<State> {
        renderFn(
            id,
            version: fnVersion,
            dark: cx.systemDark,
            state: nil as State?,
            fn: fn,
            args: args,
            viewport: cx.viewport,
            scrollLookup: { cx.scrollOffset(of: $0) }
        )
    }

    /// Spawns a Luau function or thread on the task scheduler (without an active `Tx`).
    public func spawnFn(_ fn: LuauValue, args: [LuauValue] = []) throws {
        var dummy = Tx()
        try spawnFn(fn, args: args, tx: &dummy)
    }

    /// Spawns a Luau function or thread on the task scheduler and settles against `tx`.
    public func spawnFn(_ fn: LuauValue, args: [LuauValue] = [], tx: inout Tx) throws {
        guard let vm, let sched else {
            throw failedError ?? ScriptError(kind: .missing, message: "not running")
        }
        try enterThrowing(tx: &tx) {
            if case .closure(let cl) = fn {
                let thread = vm.createThread(closure: cl)
                sched.run(vm: vm, thread: thread, args: args)
            } else {
                _ = try vm.call(value: fn, args: args)
            }
        }
    }

    /// Evaluates a Luau function synchronously and returns its raw `LuauValue` results.
    /// Does not bump the script's version.
    @discardableResult
    public func evalFn(_ fn: LuauValue, args: [LuauValue] = []) throws -> [LuauValue] {
        guard let vm else {
            throw failedError ?? ScriptError(kind: .missing, message: "not running")
        }
        do {
            let out = try runTimed(on: vm) {
                try vm.call(value: fn, args: args)
            }
            noteSchedule()
            return out
        } catch let err as LuauRuntimeError {
            let se = err.toScriptError()
            appendLog(.error, se.message)
            noteSchedule()
            throw se
        } catch let err as ScriptError {
            appendLog(.error, err.message)
            noteSchedule()
            throw err
        }
    }

    /// Builds a fresh base VM ahead of the next reload.
    public func prewarm() {
        guard prewarmedBase == nil else { return }
        prewarmedBase = try? buildBaseVM()
    }

    /// Swaps in pre-compiled sources with an externally measured compile duration.
    @discardableResult
    public func reloadCompiled(
        _ sources: Sources,
        compiled: CompiledSources,
        compileDuration: Duration
    ) throws -> ReloadReport {
        do {
            var report = try swap(compiled: compiled)
            report.compileDuration = compileDuration
            currentSources = sources
            noteReload(report)
            return report
        } catch let err as ScriptError {
            appendLog(.error, err.message)
            throw err
        } catch {
            let se = ScriptError(kind: .runtime, message: error.localizedDescription)
            appendLog(.error, se.message)
            throw se
        }
    }

    /// Recompiles and swaps the VM, carrying `saveHotState()` into `loadHotState(state)`.
    @discardableResult
    public func reload(_ sources: Sources) throws -> ReloadReport {
        let compileStart = ContinuousClock.now
        let compiled: CompiledSources
        do {
            compiled = try sources.compile()
        } catch let err as ScriptError {
            appendLog(.error, err.message)
            throw err
        } catch {
            let se = ScriptError(kind: .runtime, message: error.localizedDescription)
            appendLog(.error, se.message)
            throw se
        }
        let compileDur = compileStart.duration(to: .now)
        return try reloadCompiled(sources, compiled: compiled, compileDuration: compileDur)
    }

    /// Watches `directory` for `.luau` file changes and reloads automatically on the next `poll`.
    public func watch(_ directory: URL) throws {
        let w = LuauFolderWatcher()
        try w.start(directory: directory, entryPath: currentSources.entryPath, shared: shared)
        self.watcher = w
    }

    /// Fires a host signal created with `LuauHost.signal(name)`.
    @discardableResult
    public func fire(_ name: String, args: [LuauData] = []) -> Bool {
        guard let vm, let sig = signals.map[name], !fireFn.isNil else { return false }
        let luauArgs = [sig] + args.map { $0.toLuau() }
        do {
            try enterThrowing {
                _ = try vm.call(value: fireFn, args: luauArgs)
            }
            return true
        } catch {
            return false
        }
    }

    /// Calls exported function `name` in a new task.
    public func call(_ name: String, args: [LuauData] = []) throws {
        guard let vm, let sched, let moduleTable else {
            throw failedError ?? ScriptError(kind: .missing, message: "not running")
        }
        let fn = moduleTable.rawGet(name)
        let isCallable: Bool = switch fn {
        case .closure, .nativeFunction: true
        case .table: vm.getMetamethod(of: fn, name: "__call") != nil
        default: false
        }
        guard isCallable else {
            throw ScriptError(kind: .missing, message: "no function \(name)")
        }
        try enterThrowing {
            let luauArgs = args.map { $0.toLuau() }
            if case .closure(let cl) = fn {
                let thread = vm.createThread(closure: cl)
                sched.run(vm: vm, thread: thread, args: luauArgs)
            } else {
                _ = try vm.call(value: fn, args: luauArgs)
            }
        }
    }

    /// Calls exported function `name` synchronously and returns its `LuauData` result.
    public func query(_ name: String, args: [LuauData] = []) throws -> LuauData {
        guard let vm, let moduleTable else {
            throw failedError ?? ScriptError(kind: .missing, message: "not running")
        }
        let fn = moduleTable.rawGet(name)
        guard !fn.isNil else {
            throw ScriptError(kind: .missing, message: "no function \(name)")
        }
        return try enterThrowing {
            let res = try vm.call(value: fn, args: args.map { $0.toLuau() }).first ?? .nil
            return LuauData.fromLuau(res)
        }
    }

    /// Runs `body` with direct access to the underlying `LuauVM`.
    public func withVM<R>(_ body: (LuauVM) throws -> R) rethrows -> R? {
        guard let vm else { return nil }
        return try body(vm)
    }

    // MARK: - Internal Lifecycle

    internal func warnOnce(_ message: String) {
        if warnedMessages.insert(message).inserted {
            appendLog(.warn, message)
        }
    }

    internal func logError(_ message: String) {
        appendLog(.error, message)
    }

    internal func incrementRowsMetric() {
        _metrics.rows += 1
    }

    internal func virtualListState(forKey key: String) -> VirtualListState {
        if let existing = virtualListStates[key] { return existing }
        let s = VirtualListState()
        virtualListStates[key] = s
        return s
    }

    internal func cachedRowKey(for listKey: String, version: UInt64, index: Int) -> String? {
        guard let entry = rowKeyCaches[listKey], entry.ver == version else { return nil }
        return entry.map[index]
    }

    internal func storeRowKey(_ key: String, for listKey: String, version: UInt64, index: Int) {
        if var entry = rowKeyCaches[listKey], entry.ver == version {
            entry.map[index] = key
            rowKeyCaches[listKey] = entry
        } else {
            rowKeyCaches[listKey] = (ver: version, map: [index: key])
        }
    }

    internal func recordVisibleRowsChange(for listKey: String, first: Int, last: Int) -> Bool {
        if let prev = visibleRowRanges[listKey], prev == (first, last) {
            return false
        }
        visibleRowRanges[listKey] = (first, last)
        return true
    }

    internal func stashPressMods(_ mods: Mods) {
        pendingPressMods = mods
    }

    internal func consumePressMods() -> Mods {
        let m = pendingPressMods
        pendingPressMods = Mods()
        return m
    }

    internal func pressEventMods(_ mods: Mods) -> (shift: Bool, alt: Bool, mod: Bool) {
        #if os(macOS)
        return (mods.shift, mods.alt, mods.cmd)
        #else
        return (mods.shift, mods.alt, mods.ctrl)
        #endif
    }

    internal func aroundWrite<State>(state: inout State, tx: inout Tx, _ body: (inout Tx) -> Void) {
        guard let hook = options.around else {
            body(&tx)
            return
        }
        var boxed: Any = state
        withUnsafeMutablePointer(to: &tx) { txPtr in
            hook(&boxed, txPtr) { innerTxPtr in
                var localTx = innerTxPtr?.pointee ?? txPtr.pointee
                body(&localTx)
                if let innerTxPtr {
                    innerTxPtr.pointee = localTx
                } else {
                    txPtr.pointee = localTx
                }
            }
        }
        if let updated = boxed as? State {
            state = updated
        }
    }

    internal func aroundWriteOptional(state: inout Any, tx: UnsafeMutablePointer<Tx>?, _ body: (UnsafeMutablePointer<Tx>?) -> Void) {
        guard let hook = options.around else {
            body(tx)
            return
        }
        hook(&state, tx, body)
    }

    internal func aroundRead<R>(state: Any, _ body: () -> R) -> R {
        guard let hook = options.aroundRead else {
            return body()
        }
        var result: R!
        hook(state) {
            result = body()
        }
        return result
    }

    internal func callHandlerIfCurrent(vmID: UInt64, fn: LuauValue, arg: LuauValue) throws {
        guard self.vmID == vmID, let vm, let sched else { return }
        if case .closure(let cl) = fn {
            let thread = vm.createThread(closure: cl)
            sched.run(vm: vm, thread: thread, args: [arg])
        } else {
            _ = try vm.call(value: fn, args: [arg])
        }
    }

    private func buildBaseVM() throws -> (vm: LuauVM, vmID: UInt64, sched: LuauTaskScheduler, signals: SignalRegistry, fireFn: LuauValue) {
        let newVM = LuauVM()
        let newID = Self.allocVMID()
        let newSched = LuauTaskScheduler(shared: shared, clock: clock)
        let newSignals = SignalRegistry()

        newVM.memoryLimitBytes = options.memoryLimit
        newVM.onPrint = { [weak self] line in self?.appendLog(.info, line) }
        newVM.onWarn = { [weak self] line in self?.appendLog(.warn, line) }

        let prelude = try LuauTaskScheduler.install(into: newVM, sched: newSched)
        LuauUIBridge.installStatic(into: newVM, hostNodes: options.nodes)

        let host = LuauHost(vm: newVM, shared: shared, signals: newSignals, prelude: prelude)
        if let setupFn = options.setup {
            try setupFn(host)
        }
        let fireVal = prelude.rawGet("fire")
        return (newVM, newID, newSched, newSignals, fireVal)
    }

    private func swap(compiled: CompiledSources) throws -> ReloadReport {
        let swapStart = ContinuousClock.now
        var savedHotState: LuauData? = nil
        if let oldVM = vm, let oldMod = moduleTable {
            let saveFn = oldMod.rawGet("saveHotState")
            if !saveFn.isNil {
                do {
                    savedHotState = try runTimed {
                        let res = try oldVM.call(value: saveFn).first ?? .nil
                        return LuauData.fromLuau(res)
                    }
                } catch let err as LuauRuntimeError {
                    appendLog(.warn, "saveHotState: \(err.toScriptError().message)")
                } catch {
                    appendLog(.warn, "saveHotState: \(error.localizedDescription)")
                }
            }
        }

        let base = try prewarmedBase ?? buildBaseVM()
        prewarmedBase = nil
        let newVM = base.vm
        let newID = base.vmID
        let newSched = base.sched
        let newSignals = base.signals

        LuauRequire.install(into: newVM, compiled: compiled)
        newVM.sandbox()

        // Run entry module
        let entryVal = try runTimed(on: newVM) {
            try LuauRequire.runEntry(vm: newVM, compiled: compiled)
        }

        let modTable: LuauTable
        switch entryVal {
        case .table(let t):
            modTable = t
        case .closure, .nativeFunction:
            modTable = LuauTable()
            modTable.rawSet("render", value: entryVal)
        default:
            throw ScriptError(
                kind: .missing,
                message: "the entry module must return a table of functions or a render function, not a \(entryVal.typeName)"
            )
        }

        if let startFn = options.start {
            try runTimed(on: newVM) {
                try startFn(newVM, modTable, newID)
            }
        }

        if let saved = savedHotState {
            let loadFn = modTable.rawGet("loadHotState")
            if !loadFn.isNil {
                try runTimed(on: newVM) {
                    _ = try newVM.call(value: loadFn, args: [saved.toLuau()])
                }
            }
        }

        self.vm = newVM
        self.vmID = newID
        self.moduleTable = modTable
        self.sched = newSched
        self.signals = newSignals
        self.fireFn = base.fireFn
        self.failedError = nil
        self.warnedMessages.removeAll()
        self.salt &+= 1
        var dummyTx = Tx()
        settle(tx: &dummyTx, bumpVersion: true)

        return ReloadReport(compileDuration: .zero, swapDuration: swapStart.duration(to: .now))
    }

    private func runTimed<R>(_ body: () throws -> R) rethrows -> R {
        guard let vm else { return try body() }
        return try runTimed(on: vm, body)
    }

    private func runTimed<R>(on targetVM: LuauVM, _ body: () throws -> R) rethrows -> R {
        let armed = targetVM.watchdog.arm(timeLimit: options.timeLimit, instructionLimit: options.instructionLimit)
        defer { armed.disarm() }
        let start = ContinuousClock.now
        let out = try body()
        _metrics.vmCalls += 1
        _metrics.vmTime += start.duration(to: .now)
        return out
    }

    internal func enter(tx: inout Tx, _ body: () throws -> Void) {
        guard let vm, let sched else { return }
        do {
            try runTimed {
                try body()
                sched.drainDefers(vm: vm)
            }
        } catch let err as LuauRuntimeError {
            appendLog(.error, err.toScriptError().message)
        } catch let err as ScriptError {
            appendLog(.error, err.message)
        } catch {
            appendLog(.error, error.localizedDescription)
        }
        settle(tx: &tx, bumpVersion: true)
    }

    internal func enter(_ body: () throws -> Void) {
        var tx = Tx()
        enter(tx: &tx, body)
    }

    private func enterThrowing<R>(_ body: () throws -> R) throws -> R {
        var tx = Tx()
        return try enterThrowing(tx: &tx, body)
    }

    private func enterThrowing<R>(tx: inout Tx, _ body: () throws -> R) throws -> R {
        guard let vm, let sched else {
            throw failedError ?? ScriptError(kind: .missing, message: "not running")
        }
        do {
            let result = try runTimed {
                let r = try body()
                sched.drainDefers(vm: vm)
                return r
            }
            settle(tx: &tx, bumpVersion: true)
            return result
        } catch let err as LuauRuntimeError {
            let se = err.toScriptError()
            appendLog(.error, se.message)
            settle(tx: &tx, bumpVersion: true)
            throw se
        } catch let err as ScriptError {
            appendLog(.error, err.message)
            settle(tx: &tx, bumpVersion: true)
            throw err
        }
    }

    private func settle(tx: inout Tx, bumpVersion: Bool = true) {
        if bumpVersion {
            version &+= 1
        }
        noteSchedule(tx: &tx)
    }

    private func noteSchedule() {
        var tx = Tx()
        noteSchedule(tx: &tx)
    }

    private func noteSchedule(tx: inout Tx) {
        guard let sched else { return }
        for err in sched.errors {
            appendLog(.error, err.message)
        }
        sched.errors.removeAll()
        let deadline = sched.nextDeadline()
        nextDeadline = deadline ?? .infinity
        if sched.takeChanged(), deadline != nil {
            shared.wake()
        }
        _ = tx
    }

    private func fail(_ err: ScriptError) {
        appendLog(.error, err.message)
        failedError = err
        version &+= 1
    }

    private func appendLog(_ level: LogLevel, _ message: String) {
        options.onLog?(level, message)
        if logLines.count >= 256 {
            logLines.removeFirst()
        }
        logLines.append(LogLine(level: level, message: message))
    }

    private func noteReload(_ report: ReloadReport) {
        _metrics.reloads += 1
        _metrics.lastReload = report
        let compileMs = durationMs(report.compileDuration)
        let swapMs = durationMs(report.swapDuration)
        let totalMs = compileMs + swapMs
        appendLog(
            .info,
            String(format: "reloaded in %.2f ms: compile %.2f ms, swap %.2f ms", totalMs, compileMs, swapMs)
        )
    }

    private func durationMs(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000.0 + Double(d.components.attoseconds) * 1e-15
    }

    private func mix(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var h = Hasher()
        h.combine(a)
        h.combine(b)
        return UInt64(bitPattern: Int64(h.finalize()))
    }
}
