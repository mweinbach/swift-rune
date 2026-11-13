import Foundation

/// Token tags yielded by `task.wait`, `Signal:Wait`, and host async calls.
internal final class TaskYieldTokenBox: @unchecked Sendable {
    enum Kind { case wait, park, job }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
}

internal enum TaskYieldToken {
    static let waitToken = LuauUserdata(payload: TaskYieldTokenBox(.wait), typeTag: "TaskWaitToken")
    static let parkToken = LuauUserdata(payload: TaskYieldTokenBox(.park), typeTag: "TaskParkToken")
    static let jobToken = LuauUserdata(payload: TaskYieldTokenBox(.job), typeTag: "TaskJobToken")
}

internal final class LuauTaskScheduler: @unchecked Sendable {
    private struct ParkedTask {
        let thread: LuauThread
        let since: Double
        let args: [LuauValue]?
    }

    private struct TimerEntry {
        let at: Double
        let seq: UInt64
    }

    var clock: Double
    private var readAt: ContinuousClock.Instant
    private var timers: [TimerEntry] = []
    private var parked: [UInt64: ParkedTask] = [:]
    private var byThread: [ObjectIdentifier: UInt64] = [:]
    private var defers: [(LuauThread, [LuauValue])] = []
    private var jobs: [UInt64: LuauThread] = [:]
    private var nextSeq: UInt64 = 0
    private var changed: Bool = false
    var errors: [ScriptError] = []
    let shared: SharedScriptState

    init(shared: SharedScriptState, clock: Double = 0.0) {
        self.shared = shared
        self.clock = clock
        self.readAt = .now
    }

    func setClock(_ clock: Double) {
        self.clock = clock
        self.readAt = .now
    }

    var now: Double {
        let elapsed = readAt.duration(to: .now)
        let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return clock + secs
    }

    func park(thread: LuauThread, at: Double, args: [LuauValue]?) {
        nextSeq += 1
        let seq = nextSeq
        let since = now
        byThread[ObjectIdentifier(thread)] = seq
        parked[seq] = ParkedTask(thread: thread, since: since, args: args)
        let entry = TimerEntry(at: at, seq: seq)
        // Maintain ascending (at, seq) order matching BinaryHeap<Reverse<Due>>.
        let idx = timers.firstIndex { $0.at > at || ($0.at == at && $0.seq > seq) } ?? timers.count
        timers.insert(entry, at: idx)
        changed = true
    }

    func forget(thread: LuauThread) {
        let tid = ObjectIdentifier(thread)
        if let seq = byThread.removeValue(forKey: tid) {
            parked.removeValue(forKey: seq)
        }
        defers.removeAll { $0.0 === thread }
        jobs = jobs.filter { $0.value !== thread }
    }

    func nextDeadline() -> Double? {
        var best: Double? = nil
        timers.removeAll { parked[$0.seq] == nil }
        for t in timers {
            if best == nil || t.at < best! {
                best = t.at
            }
        }
        return best
    }

    var hasDefers: Bool { !defers.isEmpty }

    func takeChanged() -> Bool {
        let c = changed
        changed = false
        return c
    }

    func waitFor(_ deadline: Double?) -> Double? {
        deadline.map { max(0.0, $0 - now) }
    }

    // MARK: - Installation & Execution

    private static func threadOf(_ val: LuauValue, in vm: LuauVM, name: String) throws -> LuauThread {
        switch val {
        case .closure(let cl):
            return vm.createThread(closure: cl)
        case .thread(let th):
            return th
        default:
            throw LuauRuntimeError(value: .string("\(name) needs a function or a thread, got \(val.typeName)"))
        }
    }

    static func install(into vm: LuauVM, sched: LuauTaskScheduler) throws -> LuauTable {
        vm.setAppData(sched)
        let taskTable = LuauTable()

        taskTable.rawSet("spawn", value: .nativeFunction(LuauNativeFunction(name: "task.spawn") { vm, _, args in
            guard let target = args.first else {
                throw LuauRuntimeError(value: .string("task.spawn needs a function or a thread, got nil"))
            }
            let th = try threadOf(target, in: vm, name: "task.spawn")
            sched.forget(thread: th)
            if th.status == .suspended {
                sched.run(vm: vm, thread: th, args: Array(args.dropFirst()))
            }
            return .values([.thread(th)])
        }))

        taskTable.rawSet("defer", value: .nativeFunction(LuauNativeFunction(name: "task.defer") { vm, _, args in
            guard let target = args.first else {
                throw LuauRuntimeError(value: .string("task.defer needs a function or thread"))
            }
            let th = try threadOf(target, in: vm, name: "task.defer")
            sched.defers.append((th, Array(args.dropFirst())))
            return .values([.thread(th)])
        }))

        taskTable.rawSet("delay", value: .nativeFunction(LuauNativeFunction(name: "task.delay") { vm, _, args in
            guard args.count >= 2 else {
                throw LuauRuntimeError(value: .string("task.delay needs seconds and a function"))
            }
            let secs = max(0.0, args[0].coercedNumber ?? 0.0)
            let th = try threadOf(args[1], in: vm, name: "task.delay")
            sched.park(thread: th, at: sched.now + secs, args: Array(args.dropFirst(2)))
            return .values([.thread(th)])
        }))

        let forgetFn = LuauNativeFunction(name: "task.forget") { _, _, args in
            if case .thread(let th) = args.first {
                sched.forget(thread: th)
            }
            return .values([])
        }

        // Run embedded prelude.luau
        let preludeClosure = try vm.load(source: preludeLuauSource, name: "=rune-luau")
        let preludeResults = try vm.call(closure: preludeClosure, args: [
            .table(taskTable),
            .userdata(TaskYieldToken.waitToken),
            .userdata(TaskYieldToken.parkToken),
            .userdata(TaskYieldToken.jobToken),
            .nativeFunction(forgetFn),
        ])
        guard case .table(let preludeTable) = preludeResults.first else {
            throw ScriptError(kind: .runtime, message: "prelude.luau did not return a table")
        }

        vm.globals.rawSet("task", value: .table(taskTable))
        let signalModule = LuauTable()
        signalModule.rawSet("new", value: preludeTable.rawGet("scriptSignal"))
        vm.registeredModules["@rune/signal"] = .table(signalModule)

        return preludeTable
    }

    func run(vm: LuauVM, thread: LuauThread, args: [LuauValue]) {
        do {
            let res = try vm.resume(thread: thread, args: args)
            if case .yielded(let out) = res, thread.status == .suspended {
                parkFromYield(thread: thread, out: out)
            }
        } catch let err as LuauRuntimeError {
            errors.append(err.toScriptError())
        } catch let err as ScriptError {
            errors.append(err)
        } catch {
            errors.append(ScriptError(kind: .runtime, message: error.localizedDescription))
        }
    }

    private func parkFromYield(thread: LuauThread, out: [LuauValue]) {
        let tokenKind: TaskYieldTokenBox.Kind? = {
            guard case .userdata(let ud) = out.first,
                  let box = ud.payload as? TaskYieldTokenBox else {
                return nil
            }
            return box.kind
        }()
        let arg = out.count > 1 ? out[1].coercedNumber : nil

        if tokenKind == .park {
            return
        }
        if tokenKind == .job {
            let id = UInt64(max(0.0, arg ?? 0.0))
            jobs[id] = thread
            return
        }
        // `task.wait(seconds)` or a bare `coroutine.yield()` in a task resumes next frame.
        let wait = (tokenKind == .wait) ? max(0.0, arg ?? 0.0) : 0.0
        park(thread: thread, at: now + wait, args: nil)
    }

    func poll(vm: LuauVM, now: Double) -> Int {
        setClock(now)
        let completions = shared.takeCompletions()
        var doneJobs: [(LuauThread, LuauData)] = []
        for (id, data) in completions {
            if let th = jobs.removeValue(forKey: id) {
                doneJobs.append((th, data))
            }
        }

        // `timers` is sorted by ascending (at, seq).
        var due: [ParkedTask] = []
        var remaining: [TimerEntry] = []
        remaining.reserveCapacity(timers.count)
        for entry in timers {
            if entry.at <= now {
                if let p = parked.removeValue(forKey: entry.seq) {
                    byThread.removeValue(forKey: ObjectIdentifier(p.thread))
                    due.append(p)
                }
            } else {
                remaining.append(entry)
            }
        }
        timers = remaining

        var resumed = doneJobs.count + due.count
        for (th, data) in doneJobs {
            run(vm: vm, thread: th, args: [data.toLuau()])
        }
        for p in due {
            if let args = p.args {
                run(vm: vm, thread: p.thread, args: args)
            } else {
                run(vm: vm, thread: p.thread, args: [.number(max(0.0, now - p.since))])
            }
        }
        resumed += drainDefers(vm: vm)
        return resumed
    }

    @discardableResult
    func drainDefers(vm: LuauVM) -> Int {
        var n = 0
        while !defers.isEmpty {
            let (th, args) = defers.removeFirst()
            if th.status == .suspended {
                run(vm: vm, thread: th, args: args)
            }
            n += 1
            if n >= 100_000 {
                defers.removeAll()
                errors.append(ScriptError(kind: .runtime, message: "task.defer: more than 100,000 deferred tasks in one batch"))
                break
            }
        }
        return n
    }
}

/// Embedded `prelude.luau` from upstream `crates/rune-luau/src/prelude.luau`.
internal let preludeLuauSource = #"""
--!strict
local task, WAIT, PARK, JOB, forget = ...

local yield = coroutine.yield
local isyieldable = coroutine.isyieldable
local running = coroutine.running
local close = coroutine.close
local spawn = task.spawn

local function needTask(name: string)
	if not isyieldable() then
		error(`{name} can only be called from a task (task.spawn, a handler or a connection), not while rendering`, 3)
	end
end

function task.wait(seconds: number?): number
	needTask("task.wait")
	return yield(WAIT, seconds or 0)
end

function task.cancel(thread: thread)
	forget(thread)
	if coroutine.status(thread) ~= "running" then
		close(thread)
	end
end

type State = { list: { any }, waiting: { thread }, version: number }
local states: { [any]: State } = setmetatable({}, { __mode = "k" }) :: any
type Conn = { fn: (...any) -> (), once: boolean, connected: boolean, signal: any }
local connections: { [any]: Conn } = setmetatable({}, { __mode = "k" }) :: any

local Connection = {}

function Connection.Disconnect(self)
	local c = connections[self]
	if not c.connected then
		return
	end
	c.connected = false
	local list = states[c.signal].list
	local i = table.find(list, self)
	if i then
		table.remove(list, i)
	end
end

local function connectionIndex(self, key)
	if key == "Connected" then
		return connections[self].connected
	end
	return Connection[key]
end

local function connect(self, fn, once: boolean)
	if type(fn) ~= "function" then
		error("Connect and Once need a function", 3)
	end
	local proxy = newproxy(true)
	local mt = getmetatable(proxy)
	mt.__index = connectionIndex
	mt.__type = "Connection"
	connections[proxy] = { fn = fn, once = once, connected = true, signal = self }
	table.insert(states[self].list, proxy)
	return proxy
end

local function fire(self, ...)
	local s = states[self]
	s.version += 1
	if #s.list > 0 then
		for _, proxy in table.clone(s.list) do
			local c = connections[proxy]
			if c.connected then
				if c.once then
					Connection.Disconnect(proxy)
				end
				spawn(c.fn, ...)
			end
		end
	end
	if #s.waiting > 0 then
		local waiting = s.waiting
		s.waiting = {}
		for _, thread in waiting do
			spawn(thread, ...)
		end
	end
end

local Signal = {}

function Signal.Connect(self, fn)
	return connect(self, fn, false)
end

function Signal.Once(self, fn)
	return connect(self, fn, true)
end

function Signal.Wait(self)
	needTask("Signal:Wait")
	table.insert(states[self].waiting, (running()))
	return yield(PARK)
end

local ScriptSignal = table.clone(Signal)

ScriptSignal.Fire = fire

function ScriptSignal.Version(self): number
	return states[self].version
end

local function new(methods, name: string)
	return function()
		local proxy = newproxy(true)
		local mt = getmetatable(proxy)
		mt.__index = methods
		mt.__type = name
		states[proxy] = { list = {}, waiting = {}, version = 0 }
		return proxy
	end
end

local function async(submit: (...any) -> number, name: string)
	return function(...)
		needTask(name)
		return yield(JOB, submit(...))
	end
end

return {
	signal = new(table.freeze(Signal), "Signal"),
	scriptSignal = new(table.freeze(ScriptSignal), "ScriptSignal"),
	fire = fire,
	async = async,
}
"""#
