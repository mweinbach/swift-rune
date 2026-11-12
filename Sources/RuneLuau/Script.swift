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
    public var palette: Palette = defaultPalette()
    public var shadows: Shadows? = nil
    public var setup: (@Sendable (LuauHost) throws -> Void)? = nil
    public var start: (@Sendable (LuauVM, LuauTable, UInt64) throws -> Void)? = nil
    public var nodes: [HostNode] = []
    public var timeLimit: Duration = .milliseconds(250)
    public var instructionLimit: Int? = nil
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
    public func node(_ n: HostNode) -> ScriptOptions {
        var copy = self; copy.nodes.append(n); return copy
    }
    public func timeLimit(_ limit: Duration) -> ScriptOptions {
        var copy = self; copy.timeLimit = limit; return copy
    }
    public func instructionLimit(_ limit: Int?) -> ScriptOptions {
        var copy = self; copy.instructionLimit = limit; return copy
    }
    public func onLog(_ f: @escaping @Sendable (LogLevel, String) -> Void) -> ScriptOptions {
        var copy = self; copy.onLog = f; return copy
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
    private var viewTable: LuauTable?
    private var sched: LuauTaskScheduler?
    private var signals = SignalRegistry()
    private var fireFn: LuauValue = .nil
    private var currentSources: Sources
    private var failedError: ScriptError?
    private var version: UInt64 = 1
    private var salt: UInt64 = 1
    private var clock: Double = 0.0
    private var nextDeadline: Double = .infinity
    private var _metrics = ScriptMetrics()
    private var logLines: [LogLine] = []
    private let shared = SharedScriptState()
    private var activeEnv: UIRenderEnv?
    private var virtualListStates: [String: VirtualListState] = [:]
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

    /// Runs due tasks, timers, host async completions, and folder-watch reloads.
    @discardableResult
    public func poll(now: Double, tx: inout Tx) -> Bool {
        clock = now
        var reloaded = false
        if let watcher {
            let (_, ready) = watcher.takeReady()
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
        settle(tx: &tx)
        if resumed == 0 {
            version &-= 1
        }
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
        let deps = mix(version, salt)
        return Rune.memo(id, deps: deps) {
            renderUncached(name: name, dark: dark, State.self).key(id)
        }
    }

    /// Renders surface `name` immediately without memoization.
    public func renderUncached<State>(name: String, dark: Bool, _ type: State.Type = State.self) -> El<State> {
        let card: (String) -> El<State> = { [weak self] msg in
            let palette = self?.options.palette ?? defaultPalette()
            return LuauCard.errorCard(message: msg, palette: palette, dark: dark) { [weak self] _, _ in
                guard let self else { return }
                _ = try? self.reload(self.currentSources)
            }
        }
        if let failedError {
            return card(failedError.message)
        }
        guard let vm, let moduleTable else {
            return card("the script isn't running")
        }
        let renderFn = moduleTable.rawGet(name)
        guard !renderFn.isNil else {
            return card("init.luau exports no \(name) function")
        }

        // Install UI bridge for this State type if not yet installed on this VM
        if viewTable == nil {
            let envGetter: @Sendable () -> UIRenderEnv? = { [weak self] in self?.activeEnv }
            let existingUI = vm.registeredModules["@rune/ui"]?.asTable
            LuauUIBridge.install(into: vm, stateType: State.self, table: existingUI, hostNodes: options.nodes, currentEnv: envGetter)
            viewTable = LuauUIBridge.makeViewTable(for: vm, stateType: State.self, currentEnv: envGetter)
        }

        let env = UIRenderEnv(
            script: self,
            vmID: vmID,
            salt: salt,
            version: version,
            dark: dark,
            palette: options.palette,
            shadows: options.shadows,
            baseTextStyle: options.baseTextStyle,
            weights: options.weights,
            prefix: prefix
        )
        activeEnv = env
        defer { activeEnv = nil }

        do {
            let el: El<State> = try runTimed {
                viewTable?.rawSet("dark", value: .bool(dark))
                let res = try vm.call(value: renderFn, args: [viewTable.map { .table($0) } ?? .nil]).first ?? .nil
                return try LuauUIBridge.unwrapEl(res, State.self)
            }
            _metrics.renders += 1
            if env.memoFailed {
                salt &+= 1
            }
            return el
        } catch let err as LuauRuntimeError {
            let se = err.toScriptError()
            appendLog(.error, se.message)
            salt &+= 1
            return card(se.message)
        } catch let err as ScriptError {
            appendLog(.error, err.message)
            salt &+= 1
            return card(err.message)
        } catch {
            appendLog(.error, error.localizedDescription)
            salt &+= 1
            return card(error.localizedDescription)
        }
    }

    /// Recompiles and swaps the VM, carrying `saveHotState()` into `loadHotState(state)`.
    @discardableResult
    public func reload(_ sources: Sources) throws -> ReloadReport {
        let compileStart = ContinuousClock.now
        let compiled = try sources.compile()
        let compileDur = compileStart.duration(to: .now)
        var report = try swap(compiled: compiled)
        report.compileDuration = compileDur
        currentSources = sources
        noteReload(report)
        return report
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
        enter {
            _ = try vm.call(value: fireFn, args: luauArgs)
        }
        return true
    }

    /// Calls exported function `name` in a new task.
    public func call(_ name: String, args: [LuauData] = []) throws {
        guard let vm, let sched, let moduleTable else {
            throw failedError ?? ScriptError(kind: .missing, message: "not running")
        }
        let fn = moduleTable.rawGet(name)
        guard case .closure(let cl) = fn else {
            throw ScriptError(kind: .missing, message: "no function \(name)")
        }
        try enterThrowing {
            let thread = vm.createThread(closure: cl)
            sched.run(vm: vm, thread: thread, args: args.map { $0.toLuau() })
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

    internal func virtualListState(forKey key: String) -> VirtualListState {
        if let existing = virtualListStates[key] { return existing }
        let s = VirtualListState()
        virtualListStates[key] = s
        return s
    }

    internal func handleCallback(fn: LuauValue, vmID: UInt64, event: LuauValue, tx: inout Tx) {
        guard self.vmID == vmID, let vm, let sched else { return }
        enter(tx: &tx) {
            if case .closure(let cl) = fn {
                let thread = vm.createThread(closure: cl)
                sched.run(vm: vm, thread: thread, args: [event])
            } else {
                _ = try vm.call(value: fn, args: [event])
            }
        }
    }

    private func swap(compiled: CompiledSources) throws -> ReloadReport {
        let swapStart = ContinuousClock.now
        var savedHotState: LuauData? = nil
        if let oldVM = vm, let oldMod = moduleTable {
            let saveFn = oldMod.rawGet("saveHotState")
            if !saveFn.isNil {
                savedHotState = try? runTimed {
                    let res = try oldVM.call(value: saveFn).first ?? .nil
                    return LuauData.fromLuau(res)
                }
            }
        }

        let newVM = LuauVM()
        let newID = Self.allocVMID()
        let newSched = LuauTaskScheduler(shared: shared, clock: clock)
        let newSignals = SignalRegistry()

        newVM.onPrint = { [weak self] line in self?.appendLog(.info, line) }
        newVM.onWarn = { [weak self] line in self?.appendLog(.warn, line) }

        let prelude = try LuauTaskScheduler.install(into: newVM, sched: newSched)
        LuauRequire.install(into: newVM, compiled: compiled)

        let host = LuauHost(vm: newVM, shared: shared, signals: newSignals, prelude: prelude)
        if let setupFn = options.setup {
            try setupFn(host)
        }

        // Register @rune/ui table before entry module runs so `local ui = require("@rune/ui")` captures it;
        // renderUncached<State> populates its typed El<State> constructors in-place.
        if newVM.registeredModules["@rune/ui"] == nil {
            newVM.registeredModules["@rune/ui"] = .table(LuauTable())
        }

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
        self.viewTable = nil
        self.sched = newSched
        self.signals = newSignals
        self.fireFn = prelude.rawGet("fire")
        self.failedError = nil
        self.salt &+= 1
        var dummyTx = Tx()
        settle(tx: &dummyTx)

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

    private func enter(tx: inout Tx, _ body: () throws -> Void) {
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
        settle(tx: &tx)
    }

    private func enter(_ body: () throws -> Void) {
        var tx = Tx()
        enter(tx: &tx, body)
    }

    private func enterThrowing<R>(_ body: () throws -> R) throws -> R {
        guard let vm, let sched else {
            throw failedError ?? ScriptError(kind: .missing, message: "not running")
        }
        do {
            let result = try runTimed {
                let r = try body()
                sched.drainDefers(vm: vm)
                return r
            }
            var tx = Tx()
            settle(tx: &tx)
            return result
        } catch let err as LuauRuntimeError {
            let se = err.toScriptError()
            appendLog(.error, se.message)
            var tx = Tx()
            settle(tx: &tx)
            throw se
        } catch let err as ScriptError {
            appendLog(.error, err.message)
            var tx = Tx()
            settle(tx: &tx)
            throw err
        }
    }

    private func settle(tx: inout Tx) {
        version &+= 1
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
    }

    private func mix(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var h = Hasher()
        h.combine(a)
        h.combine(b)
        return UInt64(bitPattern: Int64(h.finalize()))
    }
}
