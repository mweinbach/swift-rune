import Foundation

/// Outcome of resuming or running a `LuauThread`.
public enum LuauExecutionResult: @unchecked Sendable {
    case returned([LuauValue])
    case yielded([LuauValue])
}

/// Pure Swift Luau Bytecode Virtual Machine.
public final class LuauVM: @unchecked Sendable {
    public let globals: LuauTable
    public let mainThread: LuauThread
    public var currentThread: LuauThread
    public let watchdog: LuauWatchdog

    /// Registered built-in / host modules (`require("@name")`).
    public var registeredModules: [String: LuauValue] = [:]
    /// Cached `require` results by resolved key.
    public var moduleCache: [String: LuauValue] = [:]
    /// Arbitrary host app data attached to the VM.
    public var appData: [ObjectIdentifier: Any] = [:]
    /// Optional custom `print` / `warn` sinks.
    public var onPrint: ((String) -> Void)?
    public var onWarn: ((String) -> Void)?
    /// Sandbox flag (globals frozen).
    public var isSandboxed: Bool = false
    /// Per-VM isolated env inheriting `globals` when sandboxed.
    public var sandboxEnv: LuauTable?
    /// Optional memory budget in bytes (`nil` = unlimited).
    public var memoryLimitBytes: Int?

    private var pendingAllocationBytes: Int = 0
    private var markStack: [Int] = []

    public init() {
        self.globals = LuauTable()
        self.mainThread = LuauThread(isMainThread: true)
        self.mainThread.status = .running
        self.currentThread = self.mainThread
        self.watchdog = LuauWatchdog()
        LuauStdlib.install(into: self)
    }

    public func setAppData<T>(_ value: T) {
        appData[ObjectIdentifier(T.self)] = value
    }

    public func getAppData<T>(_ type: T.Type) -> T? {
        appData[ObjectIdentifier(type)] as? T
    }

    /// Compiles source code into a `LuauProto` without executing it.
    internal func compile(source: String, name: String = "chunk") throws -> LuauProto {
        let lexer = LuauLexer(source: source, name: name)
        let tokens = try lexer.tokenize()
        let parser = LuauParser(tokens: tokens, sourceName: name)
        let stmts = try parser.parseChunk()
        let compiler = LuauCompiler(sourceName: name)
        return try compiler.compile(stmts: stmts)
    }

    /// Loads source code into a `LuauClosure` bound to `env ?? defaultEnv`.
    public func load(source: String, name: String = "chunk", env: LuauTable? = nil) throws -> LuauClosure {
        let proto = try compile(source: source, name: name)
        return LuauClosure(proto: proto, upvalues: [], env: env ?? defaultEnv)
    }

    /// Convenience: compiles and executes a chunk on the main thread.
    @discardableResult
    public func eval(_ source: String, name: String = "chunk", args: [LuauValue] = []) throws -> [LuauValue] {
        let closure = try load(source: source, name: name)
        return try call(closure: closure, args: args)
    }

    /// Calls a `LuauValue` (closure, nativeFunction, or table with `__call`) synchronously.
    @discardableResult
    public func call(value: LuauValue, args: [LuauValue] = []) throws -> [LuauValue] {
        switch value {
        case .closure(let c):
            return try call(closure: c, args: args)
        case .nativeFunction(let f):
            let res = try f.callback(self, currentThread, args)
            switch res {
            case .values(let v): return v
            case .yield:
                throw LuauRuntimeError(value: .string("attempt to yield across a C-call boundary"))
            }
        case .table(let t):
            if let mm = getMetamethod(of: .table(t), name: "__call") {
                return try call(value: mm, args: [.table(t)] + args)
            }
            throw LuauRuntimeError(value: .string("attempt to call a table value"))
        default:
            throw LuauRuntimeError(value: .string("attempt to call a \(value.typeName) value"))
        }
    }

    /// Calls a `LuauClosure` synchronously on `currentThread`.
    @discardableResult
    public func call(closure: LuauClosure, args: [LuauValue] = []) throws -> [LuauValue] {
        let thread = currentThread
        let targetFrameDepth = thread.frames.count
        let savedStackCount = thread.stack.count
        let savedMarkCount = markStack.count
        pushFrame(thread: thread, closure: closure, args: args, expectedResults: -1)
        do {
            let result = try runLoop(thread: thread, stopAtFrameDepth: targetFrameDepth)
            switch result {
            case .returned(let values):
                if thread.stack.count > savedStackCount {
                    thread.stack.removeLast(thread.stack.count - savedStackCount)
                }
                return values
            case .yielded:
                throw LuauRuntimeError(value: .string("attempt to yield across a C-call boundary"))
            }
        } catch {
            thread.closeUpvalues(fromStackIndex: savedStackCount)
            if markStack.count > savedMarkCount {
                markStack.removeLast(markStack.count - savedMarkCount)
            }
            if thread.frames.count > targetFrameDepth {
                thread.frames.removeLast(thread.frames.count - targetFrameDepth)
            }
            if thread.stack.count > savedStackCount {
                thread.stack.removeLast(thread.stack.count - savedStackCount)
            }
            throw error
        }
    }

    /// Creates a new coroutine thread from a closure.
    public func createThread(closure: LuauClosure) -> LuauThread {
        let t = LuauThread(isMainThread: false)
        t.status = .suspended
        pushFrame(thread: t, closure: closure, args: [], expectedResults: -1, initializeParamsLater: true)
        return t
    }

    /// Resumes a coroutine thread.
    public func resume(thread: LuauThread, args: [LuauValue] = []) throws -> LuauExecutionResult {
        guard thread.status == .suspended else {
            throw LuauRuntimeError(value: .string("cannot resume \(thread.status.rawValue) coroutine"))
        }
        let prevThread = currentThread
        let prevStatus = prevThread.status
        if prevThread !== thread {
            prevThread.status = .normal
        }
        thread.status = .running
        currentThread = thread
        defer {
            currentThread = prevThread
            if prevThread !== thread {
                prevThread.status = prevStatus
            }
        }

        if let frame = thread.frames.last, frame.pc == 0 && thread.frames.count == 1 && thread.yieldedValues.isEmpty && thread.stack.count == frame.closure.proto.numLocals {
            // Initial resume: bind args to params and varargs
            bindInitialArgs(thread: thread, frame: frame, args: args)
        } else {
            // Resuming from a yield: push resume args onto the stack according to yieldExpectedResults
            let expected = thread.yieldExpectedResults
            if expected == -1 {
                thread.stack.append(contentsOf: args)
            } else {
                for i in 0..<expected {
                    thread.stack.append(i < args.count ? args[i] : .nil)
                }
            }
        }
        thread.yieldedValues = []

        do {
            let res = try runLoop(thread: thread, stopAtFrameDepth: 0)
            switch res {
            case .returned(let vals):
                thread.status = .dead
                return .returned(vals)
            case .yielded(let vals):
                thread.status = .suspended
                return .yielded(vals)
            }
        } catch {
            thread.status = .dead
            throw error
        }
    }

    private func pushFrame(thread: LuauThread, closure: LuauClosure, args: [LuauValue], expectedResults: Int, initializeParamsLater: Bool = false) {
        let base = thread.stack.count
        let proto = closure.proto
        for _ in 0..<proto.numLocals {
            thread.stack.append(.nil)
        }
        var varargs: [LuauValue] = []
        if !initializeParamsLater {
            for i in 0..<proto.paramsCount {
                if i < args.count {
                    thread.stack[base + i] = args[i]
                }
            }
            if proto.isVariadic && args.count > proto.paramsCount {
                varargs = Array(args[proto.paramsCount...])
            }
        }
        let frame = LuauCallFrame(closure: closure, base: base, varargs: varargs, expectedResults: expectedResults)
        thread.frames.append(frame)
    }

    private func bindInitialArgs(thread: LuauThread, frame: LuauCallFrame, args: [LuauValue]) {
        let proto = frame.closure.proto
        for i in 0..<proto.paramsCount {
            if i < args.count {
                thread.stack[frame.base + i] = args[i]
            }
        }
        if proto.isVariadic && args.count > proto.paramsCount {
            let varargs = Array(args[proto.paramsCount...])
            let newFrame = LuauCallFrame(closure: frame.closure, base: frame.base, varargs: varargs, expectedResults: frame.expectedResults)
            thread.frames[thread.frames.count - 1] = newFrame
        }
    }

    // MARK: - Main Bytecode Loop

    private func runLoop(thread: LuauThread, stopAtFrameDepth: Int) throws -> LuauExecutionResult {
        while thread.frames.count > stopAtFrameDepth {
            try watchdog.tick()

            let frame = thread.frames[thread.frames.count - 1]
            let proto = frame.closure.proto
            if frame.pc >= proto.code.count {
                // Implicit return 0
                let retVals: [LuauValue] = []
                if try handleReturn(thread: thread, frame: frame, values: retVals, stopAtFrameDepth: stopAtFrameDepth) {
                    return .returned(retVals)
                }
                continue
            }

            let instr = proto.code[frame.pc]
            frame.pc += 1

            do {
                switch instr.op {
                case .loadNil:
                    thread.stack.append(.nil)

                case .loadBool(let b):
                    thread.stack.append(.bool(b))

                case .loadConst(let k):
                    thread.stack.append(proto.constants[k])

                case .loadVararg(let expected):
                    if expected == -1 {
                        thread.stack.append(contentsOf: frame.varargs)
                    } else {
                        for i in 0..<expected {
                            thread.stack.append(i < frame.varargs.count ? frame.varargs[i] : .nil)
                        }
                    }

                case .getLocal(let slot):
                    thread.stack.append(thread.stack[frame.base + slot])

                case .setLocal(let slot):
                    thread.stack[frame.base + slot] = thread.stack.removeLast()

                case .getUpvalue(let idx):
                    thread.stack.append(frame.closure.upvalues[idx].get())

                case .setUpvalue(let idx):
                    frame.closure.upvalues[idx].set(thread.stack.removeLast())

                case .getGlobal(let k):
                    guard case .string(let name) = proto.constants[k] else { break }
                    let val = try tableGet(.table(frame.closure.env), key: .string(name))
                    thread.stack.append(val)

                case .setGlobal(let k):
                    guard case .string(let name) = proto.constants[k] else { break }
                    let val = thread.stack.removeLast()
                    try tableSet(.table(frame.closure.env), key: .string(name), value: val)

                case .newTable(let aHint, let hHint):
                    try noteAllocation(64 + aHint * 16 + hHint * 32)
                    thread.stack.append(.table(LuauTable(arrayCapacity: aHint, hashCapacity: hHint)))

                case .getTable:
                    let key = thread.stack.removeLast()
                    let tbl = thread.stack.removeLast()
                    let val = try tableGet(tbl, key: key)
                    thread.stack.append(val)

                case .setTable:
                    let val = thread.stack.removeLast()
                    let key = thread.stack.removeLast()
                    let tbl = thread.stack.removeLast()
                    try tableSet(tbl, key: key, value: val)
                    try noteAllocation(48)

                case .initTableField:
                    let val = thread.stack.removeLast()
                    let key = thread.stack.removeLast()
                    guard let tblVal = thread.stack.last, case .table(let tbl) = tblVal else {
                        throw LuauRuntimeError(value: .string("internal error: initTableField on non-table"))
                    }
                    try tbl.rawSet(key, value: val)
                    try noteAllocation(48)

                case .getField(let k):
                    let tbl = thread.stack.removeLast()
                    let val = try tableGet(tbl, key: proto.constants[k])
                    thread.stack.append(val)

                case .setField(let k):
                    let val = thread.stack.removeLast()
                    let tbl = thread.stack.removeLast()
                    try tableSet(tbl, key: proto.constants[k], value: val)
                    try noteAllocation(48)

                case .setList(let startIndex, let count):
                    let startPos = thread.stack.count - count
                    let tblVal = thread.stack[startPos - 1]
                    guard case .table(let tbl) = tblVal else {
                        throw LuauRuntimeError(value: .string("internal error: setList on non-table"))
                    }
                    try noteAllocation(count * 16)
                    for i in 0..<count {
                        try tbl.rawSet(.number(Double(startIndex + i)), value: thread.stack[startPos + i])
                    }
                    thread.stack.removeLast(count)

                case .setListMulti(let startIndex, _):
                    let mark = markStack.removeLast()
                    let count = thread.stack.count - mark
                    guard case .table(let tbl) = thread.stack[mark - 1] else {
                        throw LuauRuntimeError(value: .string("internal error: setListMulti on non-table"))
                    }
                    try noteAllocation(count * 16)
                    for i in 0..<count {
                        try tbl.rawSet(.number(Double(startIndex + i)), value: thread.stack[mark + i])
                    }
                    thread.stack.removeLast(count)

                case .selfMethod(let k):
                    let obj = thread.stack.removeLast()
                    let method = try tableGet(obj, key: proto.constants[k])
                    thread.stack.append(method)
                    thread.stack.append(obj)

                case .add:
                    let b = thread.stack.removeLast()
                    let a = thread.stack.removeLast()
                    thread.stack.append(try evalBinary(.add, a, b))
                case .sub:
                    let b = thread.stack.removeLast()
                    let a = thread.stack.removeLast()
                    thread.stack.append(try evalBinary(.sub, a, b))
                case .mul:
                    let b = thread.stack.removeLast()
                    let a = thread.stack.removeLast()
                    thread.stack.append(try evalBinary(.mul, a, b))
                case .div:
                    let b = thread.stack.removeLast()
                    let a = thread.stack.removeLast()
                    thread.stack.append(try evalBinary(.div, a, b))
                case .idiv:
                    let b = thread.stack.removeLast()
                    let a = thread.stack.removeLast()
                    thread.stack.append(try evalBinary(.idiv, a, b))
                case .mod:
                    let b = thread.stack.removeLast()
                    let a = thread.stack.removeLast()
                    thread.stack.append(try evalBinary(.mod, a, b))
                case .pow:
                    let b = thread.stack.removeLast()
                    let a = thread.stack.removeLast()
                    thread.stack.append(try evalBinary(.pow, a, b))
                case .concat:
                    let b = thread.stack.removeLast()
                    let a = thread.stack.removeLast()
                    thread.stack.append(try evalConcat(a, b))

                case .neg:
                    let a = thread.stack.removeLast()
                    thread.stack.append(try evalNeg(a))
                case .not:
                    let a = thread.stack.removeLast()
                    thread.stack.append(.bool(!a.isTruthy))
                case .len:
                    let a = thread.stack.removeLast()
                    thread.stack.append(try evalLen(a))

                case .eq:
                    let b = thread.stack.removeLast()
                    let a = thread.stack.removeLast()
                    thread.stack.append(.bool(try evalEq(a, b)))
                case .neq:
                    let b = thread.stack.removeLast()
                    let a = thread.stack.removeLast()
                    thread.stack.append(.bool(!(try evalEq(a, b))))
                case .lt:
                    let b = thread.stack.removeLast()
                    let a = thread.stack.removeLast()
                    thread.stack.append(.bool(try evalLt(a, b)))
                case .le:
                    let b = thread.stack.removeLast()
                    let a = thread.stack.removeLast()
                    thread.stack.append(.bool(try evalLe(a, b)))
                case .gt:
                    let b = thread.stack.removeLast()
                    let a = thread.stack.removeLast()
                    thread.stack.append(.bool(try evalLt(b, a)))
                case .ge:
                    let b = thread.stack.removeLast()
                    let a = thread.stack.removeLast()
                    thread.stack.append(.bool(try evalLe(b, a)))

                case .jump(let offset):
                    frame.pc += offset

                case .jumpIfFalse(let offset):
                    let cond = thread.stack.removeLast()
                    if !cond.isTruthy {
                        frame.pc += offset
                    }

                case .jumpIfTruePop(let offset):
                    let cond = thread.stack.removeLast()
                    if cond.isTruthy {
                        frame.pc += offset
                    }

                case .andJump(let offset):
                    if let top = thread.stack.last, !top.isTruthy {
                        frame.pc += offset
                    } else {
                        _ = thread.stack.popLast()
                    }

                case .orJump(let offset):
                    if let top = thread.stack.last, top.isTruthy {
                        frame.pc += offset
                    } else {
                        _ = thread.stack.popLast()
                    }

                case .closure(let protoIdx):
                    let childProto = proto.protos[protoIdx]
                    var uvs: [LuauUpvalue] = []
                    for desc in childProto.upvalues {
                        switch desc {
                        case .local(let slot):
                            let absIdx = frame.base + slot
                            if let existing = frame.openUpvalues[absIdx] {
                                uvs.append(existing)
                            } else {
                                let uv = LuauUpvalue(thread: thread, stackIndex: absIdx)
                                frame.openUpvalues[absIdx] = uv
                                uvs.append(uv)
                            }
                        case .upvalue(let uvIdx):
                            uvs.append(frame.closure.upvalues[uvIdx])
                        }
                    }
                    let cl = LuauClosure(proto: childProto, upvalues: uvs, env: frame.closure.env)
                    thread.stack.append(.closure(cl))

                case .closeUpvalues(let fromSlot):
                    let absIdx = frame.base + fromSlot
                    thread.closeUpvalues(fromStackIndex: absIdx)

                case .pushMark:
                    markStack.append(thread.stack.count)

                case .call(let argCount, let expectedResults):
                    let argsStart = thread.stack.count - argCount
                    let args = Array(thread.stack[argsStart...])
                    let callee = thread.stack[argsStart - 1]
                    thread.stack.removeLast(argCount + 1)
                    if let yielded = try invokeInLoop(thread: thread, callee: callee, args: args, expectedResults: expectedResults) {
                        return yielded
                    }

                case .callMulti(_, let expectedResults):
                    let mark = markStack.removeLast()
                    let args = Array(thread.stack[mark...])
                    let callee = thread.stack[mark - 1]
                    thread.stack.removeLast((thread.stack.count - mark) + 1)
                    if let yielded = try invokeInLoop(thread: thread, callee: callee, args: args, expectedResults: expectedResults) {
                        return yielded
                    }

                case .return(let count):
                    let retStart = thread.stack.count - count
                    let retVals = Array(thread.stack[retStart...])
                    thread.stack.removeLast(count)
                    if try handleReturn(thread: thread, frame: frame, values: retVals, stopAtFrameDepth: stopAtFrameDepth) {
                        return .returned(retVals)
                    }

                case .popMarkAndReturn:
                    let mark = markStack.removeLast()
                    let retVals = Array(thread.stack[mark...])
                    thread.stack.removeLast(thread.stack.count - mark)
                    if try handleReturn(thread: thread, frame: frame, values: retVals, stopAtFrameDepth: stopAtFrameDepth) {
                        return .returned(retVals)
                    }

                case .numericForPrep(let varSlot, let jumpOffset):
                    let b = frame.base + varSlot
                    guard let start = thread.stack[b].coercedNumber,
                          let limit = thread.stack[b + 1].coercedNumber,
                          let step = thread.stack[b + 2].coercedNumber else {
                        throw LuauRuntimeError(value: .string("invalid 'for' limit/step (number expected)"))
                    }
                    thread.stack[b] = .number(start)
                    thread.stack[b + 1] = .number(limit)
                    thread.stack[b + 2] = .number(step)
                    let ok = step >= 0 ? (start <= limit) : (start >= limit)
                    if !ok {
                        frame.pc += jumpOffset
                    }

                case .numericForLoop(let varSlot, let jumpOffset):
                    let b = frame.base + varSlot
                    guard case .number(let cur) = thread.stack[b],
                          case .number(let limit) = thread.stack[b + 1],
                          case .number(let step) = thread.stack[b + 2] else {
                        break
                    }
                    let next = cur + step
                    let ok = step >= 0 ? (next <= limit) : (next >= limit)
                    if ok {
                        thread.stack[b] = .number(next)
                        frame.pc += jumpOffset
                    }

                case .genericForPrep(let baseSlot):
                    let b = frame.base + baseSlot
                    let fnVal = thread.stack[b]
                    if case .table(let t) = fnVal {
                        if let iterMM = getMetamethod(of: fnVal, name: "__iter") {
                            let res = try call(value: iterMM, args: [fnVal])
                            thread.stack[b] = res.count > 0 ? res[0] : .nil
                            thread.stack[b + 1] = res.count > 1 ? res[1] : .nil
                            thread.stack[b + 2] = res.count > 2 ? res[2] : .nil
                        } else {
                            // Generalized iteration over table
                            thread.stack[b] = .nativeFunction(LuauStdlib.nextFunction)
                            thread.stack[b + 1] = .table(t)
                            thread.stack[b + 2] = .nil
                        }
                    }

                case .genericForCall(let baseSlot, let varCount, let jumpOffset):
                    let b = frame.base + baseSlot
                    let fn = thread.stack[b]
                    let state = thread.stack[b + 1]
                    let ctrl = thread.stack[b + 2]
                    let res = try call(value: fn, args: [state, ctrl])
                    if res.isEmpty || res[0].isNil {
                        frame.pc += jumpOffset
                    } else {
                        thread.stack[b + 2] = res[0]
                        for i in 0..<varCount {
                            thread.stack[b + 3 + i] = i < res.count ? res[i] : .nil
                        }
                    }

                case .interp(let totalParts):
                    let start = thread.stack.count - totalParts
                    var out = ""
                    for i in 0..<totalParts {
                        out += try valueToString(thread.stack[start + i])
                    }
                    try noteAllocation(32 + out.utf8.count)
                    thread.stack.removeLast(totalParts)
                    thread.stack.append(.string(out))
                }
            } catch let err as LuauRuntimeError {
                let loc = "\(proto.sourceName):\(instr.line)"
                let tb = err.traceback.isEmpty ? "stack traceback:\n\t\(loc): in function '\(proto.name)'" : "\(err.traceback)\n\t\(loc): in function '\(proto.name)'"
                throw LuauRuntimeError(value: err.value, traceback: tb, isTimeout: err.isTimeout, isMemory: err.isMemory)
            }
        }
        return .returned([])
    }

    private func invokeInLoop(thread: LuauThread, callee: LuauValue, args: [LuauValue], expectedResults: Int) throws -> LuauExecutionResult? {
        switch callee {
        case .closure(let c):
            pushFrame(thread: thread, closure: c, args: args, expectedResults: expectedResults)
            return nil
        case .nativeFunction(let nf):
            let res = try nf.callback(self, thread, args)
            switch res {
            case .values(let vals):
                pushAdjustedResults(thread: thread, values: vals, expected: expectedResults)
                return nil
            case .yield(let yvals):
                if thread.isMainThread {
                    throw LuauRuntimeError(value: .string("attempt to yield from outside a coroutine"))
                }
                thread.yieldExpectedResults = expectedResults
                thread.yieldedValues = yvals
                return .yielded(yvals)
            }
        case .table:
            if let mm = getMetamethod(of: callee, name: "__call") {
                return try invokeInLoop(thread: thread, callee: mm, args: [callee] + args, expectedResults: expectedResults)
            }
            throw LuauRuntimeError(value: .string("attempt to call a table value"))
        default:
            throw LuauRuntimeError(value: .string("attempt to call a \(callee.typeName) value"))
        }
    }

    private func handleReturn(thread: LuauThread, frame: LuauCallFrame, values: [LuauValue], stopAtFrameDepth: Int) throws -> Bool {
        thread.closeUpvalues(fromStackIndex: frame.base)
        if thread.stack.count > frame.base {
            thread.stack.removeLast(thread.stack.count - frame.base)
        }
        thread.frames.removeLast()
        if thread.frames.count == stopAtFrameDepth {
            return true
        }
        pushAdjustedResults(thread: thread, values: values, expected: frame.expectedResults)
        return false
    }

    private func pushAdjustedResults(thread: LuauThread, values: [LuauValue], expected: Int) {
        if expected == -1 {
            thread.stack.append(contentsOf: values)
        } else {
            for i in 0..<expected {
                thread.stack.append(i < values.count ? values[i] : .nil)
            }
        }
    }

    // MARK: - Metamethods & Operations

    public func getMetatable(of value: LuauValue) -> LuauTable? {
        switch value {
        case .table(let t): return t.metatable
        case .userdata(let u): return u.metatable
        case .string, .byteString: return getAppData(StringMetatableBox.self)?.table
        default: return nil
        }
    }

    public func getMetamethod(of value: LuauValue, name: String) -> LuauValue? {
        guard let mt = getMetatable(of: value) else { return nil }
        let mm = mt.rawGet(name)
        return mm.isNil ? nil : mm
    }

    public func tableGet(_ target: LuauValue, key: LuauValue) throws -> LuauValue {
        var current = target
        for _ in 0..<100 {
            if case .table(let t) = current {
                let raw = t.rawGet(key)
                if !raw.isNil { return raw }
            }
            if case .vector(let v) = current, case .string(let k) = key {
                switch k {
                case "x", "X": return .number(Double(v.x))
                case "y", "Y": return .number(Double(v.y))
                case "z", "Z": return .number(Double(v.z))
                default: break
                }
            }
            guard let mm = getMetamethod(of: current, name: "__index") else {
                if case .table = current { return .nil }
                throw LuauRuntimeError(value: .string("attempt to index \(current.typeName) with '\(key.displayString)'"))
            }
            if case .closure = mm {
                return try call(value: mm, args: [current, key]).first ?? .nil
            }
            if case .nativeFunction = mm {
                return try call(value: mm, args: [current, key]).first ?? .nil
            }
            current = mm
        }
        throw LuauRuntimeError(value: .string("'__index' chain too long; possible loop"))
    }

    public func tableSet(_ target: LuauValue, key: LuauValue, value: LuauValue) throws {
        var current = target
        for _ in 0..<100 {
            if case .table(let t) = current {
                if t.isFrozen {
                    throw LuauRuntimeError(value: .string("attempt to modify a readonly table"))
                }
                if !t.rawGet(key).isNil {
                    try t.rawSet(key, value: value)
                    return
                }
                if let mm = getMetamethod(of: current, name: "__newindex") {
                    if case .closure = mm {
                        _ = try call(value: mm, args: [current, key, value])
                        return
                    }
                    if case .nativeFunction = mm {
                        _ = try call(value: mm, args: [current, key, value])
                        return
                    }
                    current = mm
                    continue
                }
                try t.rawSet(key, value: value)
                return
            } else if let mm = getMetamethod(of: current, name: "__newindex") {
                if case .closure = mm {
                    _ = try call(value: mm, args: [current, key, value])
                    return
                }
                if case .nativeFunction = mm {
                    _ = try call(value: mm, args: [current, key, value])
                    return
                }
                current = mm
                continue
            }
            throw LuauRuntimeError(value: .string("attempt to index \(current.typeName) with '\(key.displayString)'"))
        }
        throw LuauRuntimeError(value: .string("'__newindex' chain too long; possible loop"))
    }

    public func valueToString(_ val: LuauValue) throws -> String {
        if let mm = getMetamethod(of: val, name: "__tostring") {
            let res = try call(value: mm, args: [val]).first ?? .nil
            if case .string(let s) = res { return s }
            return res.displayString
        }
        return val.displayString
    }

    private func evalBinary(_ op: LuauBinaryOp, _ a: LuauValue, _ b: LuauValue) throws -> LuauValue {
        if let na = a.coercedNumber, let nb = b.coercedNumber {
            let res: Double = switch op {
            case .add: na + nb
            case .sub: na - nb
            case .mul: na * nb
            case .div: na / nb
            case .idiv: floor(na / nb)
            case .mod: na - floor(na / nb) * nb
            case .pow: pow(na, nb)
            default: 0
            }
            return .number(res)
        }
        if case .vector(let va) = a, case .vector(let vb) = b {
            switch op {
            case .add: return .vector(va + vb)
            case .sub: return .vector(va - vb)
            case .mul: return .vector(va * vb)
            case .div: return .vector(va / vb)
            case .idiv: return .vector(SIMD3<Double>(floor(va.x / vb.x), floor(va.y / vb.y), floor(va.z / vb.z)))
            default: break
            }
        }
        if case .vector(let v) = a, let s = b.coercedNumber {
            switch op {
            case .mul: return .vector(v * s)
            case .div: return .vector(v / s)
            case .idiv: return .vector(SIMD3<Double>(floor(v.x / s), floor(v.y / s), floor(v.z / s)))
            default: break
            }
        }
        if let s = a.coercedNumber, case .vector(let v) = b {
            switch op {
            case .mul: return .vector(s * v)
            case .div: return .vector(SIMD3<Double>(s / v.x, s / v.y, s / v.z))
            case .idiv: return .vector(SIMD3<Double>(floor(s / v.x), floor(s / v.y), floor(s / v.z)))
            default: break
            }
        }
        let mmName: String = switch op {
        case .add: "__add"
        case .sub: "__sub"
        case .mul: "__mul"
        case .div: "__div"
        case .idiv: "__idiv"
        case .mod: "__mod"
        case .pow: "__pow"
        default: ""
        }
        if let mm = getMetamethod(of: a, name: mmName) ?? getMetamethod(of: b, name: mmName) {
            return try call(value: mm, args: [a, b]).first ?? .nil
        }
        throw LuauRuntimeError(value: .string("attempt to perform arithmetic on \(a.typeName) and \(b.typeName)"))
    }

    private func evalConcat(_ a: LuauValue, _ b: LuauValue) throws -> LuauValue {
        func concatBytes(_ v: LuauValue) -> [UInt8]? {
            if let bytes = v.stringBytes { return bytes }
            if case .number(let n) = v { return Array(LuauValue.formatNumber(n).utf8) }
            return nil
        }
        if let ba = concatBytes(a), let bb = concatBytes(b) {
            try noteAllocation(32 + ba.count + bb.count)
            return LuauValue.fromBytes(ba + bb)
        }
        if let mm = getMetamethod(of: a, name: "__concat") ?? getMetamethod(of: b, name: "__concat") {
            return try call(value: mm, args: [a, b]).first ?? .nil
        }
        throw LuauRuntimeError(value: .string("attempt to concatenate \(a.typeName) with \(b.typeName)"))
    }

    private func evalNeg(_ a: LuauValue) throws -> LuauValue {
        if let n = a.coercedNumber { return .number(-n) }
        if case .vector(let v) = a { return .vector(-v) }
        if let mm = getMetamethod(of: a, name: "__unm") {
            return try call(value: mm, args: [a]).first ?? .nil
        }
        throw LuauRuntimeError(value: .string("attempt to perform arithmetic on a \(a.typeName) value"))
    }

    private func evalLen(_ a: LuauValue) throws -> LuauValue {
        if let mm = getMetamethod(of: a, name: "__len") {
            return try call(value: mm, args: [a]).first ?? .nil
        }
        switch a {
        case .string(let s): return .number(Double(s.utf8.count))
        case .byteString(let b): return .number(Double(b.count))
        case .table(let t): return .number(Double(t.rawLength))
        default:
            throw LuauRuntimeError(value: .string("attempt to get length of a \(a.typeName) value"))
        }
    }

    private func evalEq(_ a: LuauValue, _ b: LuauValue) throws -> Bool {
        if a == b { return true }
        if case .table = a, case .table = b {
            if let mma = getMetamethod(of: a, name: "__eq"), let mmb = getMetamethod(of: b, name: "__eq"), mma == mmb {
                return (try call(value: mma, args: [a, b]).first ?? .nil).isTruthy
            }
        }
        if case .userdata = a, case .userdata = b {
            if let mma = getMetamethod(of: a, name: "__eq"), let mmb = getMetamethod(of: b, name: "__eq"), mma == mmb {
                return (try call(value: mma, args: [a, b]).first ?? .nil).isTruthy
            }
        }
        return false
    }

    private func evalLt(_ a: LuauValue, _ b: LuauValue) throws -> Bool {
        if case .number(let na) = a, case .number(let nb) = b { return na < nb }
        if let ba = a.stringBytes, let bb = b.stringBytes {
            return ba.lexicographicallyPrecedes(bb)
        }
        if let mm = getMetamethod(of: a, name: "__lt") ?? getMetamethod(of: b, name: "__lt") {
            return (try call(value: mm, args: [a, b]).first ?? .nil).isTruthy
        }
        throw LuauRuntimeError(value: .string("attempt to compare \(a.typeName) with \(b.typeName)"))
    }

    private func evalLe(_ a: LuauValue, _ b: LuauValue) throws -> Bool {
        if case .number(let na) = a, case .number(let nb) = b { return na <= nb }
        if let ba = a.stringBytes, let bb = b.stringBytes {
            return !bb.lexicographicallyPrecedes(ba)
        }
        if let mm = getMetamethod(of: a, name: "__le") ?? getMetamethod(of: b, name: "__le") {
            return (try call(value: mm, args: [a, b]).first ?? .nil).isTruthy
        }
        if let mm = getMetamethod(of: a, name: "__lt") ?? getMetamethod(of: b, name: "__lt") {
            return !(try call(value: mm, args: [b, a]).first ?? .nil).isTruthy
        }
        throw LuauRuntimeError(value: .string("attempt to compare \(a.typeName) with \(b.typeName)"))
    }

    // MARK: - Sandbox & Memory Accounting

    /// Freezes globals and stdlib tables and establishes an isolated writable env inheriting `_G`.
    public func sandbox() {
        if !isSandboxed {
            var visited = Set<ObjectIdentifier>()
            freezeTableGraph(globals, visited: &visited)
            if let stringMt = getAppData(StringMetatableBox.self)?.table {
                freezeTableGraph(stringMt, visited: &visited)
            }
            if case .table(let sigMod)? = registeredModules["@rune/signal"] {
                freezeTableGraph(sigMod, visited: &visited)
            }
            let env = LuauTable()
            let mt = LuauTable()
            mt.rawSet("__index", value: .table(globals))
            mt.rawSet("__metatable", value: .string("The metatable is locked"))
            env.metatable = mt
            sandboxEnv = env
            isSandboxed = true
        }
    }

    public var defaultEnv: LuauTable {
        sandboxEnv ?? globals
    }

    /// Creates a child isolated environment inheriting from the VM's default environment.
    public func makeIsolatedEnv() -> LuauTable {
        let env = LuauTable()
        let mt = LuauTable()
        mt.rawSet("__index", value: .table(defaultEnv))
        mt.rawSet("__metatable", value: .string("The metatable is locked"))
        env.metatable = mt
        return env
    }

    private func freezeTableGraph(_ table: LuauTable, visited: inout Set<ObjectIdentifier>) {
        let id = ObjectIdentifier(table)
        guard visited.insert(id).inserted else { return }
        table.isFrozen = true
        for v in table.array {
            if case .table(let sub) = v { freezeTableGraph(sub, visited: &visited) }
        }
        for v in table.hash.values {
            if case .table(let sub) = v { freezeTableGraph(sub, visited: &visited) }
        }
        if let mt = table.metatable {
            freezeTableGraph(mt, visited: &visited)
        }
    }

    /// Records an allocation delta and checks against `memoryLimitBytes` when threshold is reached.
    public func noteAllocation(_ bytes: Int) throws {
        guard bytes > 0 else { return }
        guard let limit = memoryLimitBytes else { return }
        if bytes >= 4096 {
            let live = estimatedMemoryBytes()
            if live.addingReportingOverflow(bytes).overflow || live + bytes > limit {
                throw LuauRuntimeError(value: .string("not enough memory"), isMemory: true)
            }
            pendingAllocationBytes = 0
            return
        }
        pendingAllocationBytes += bytes
        if pendingAllocationBytes >= max(4096, limit / 16) {
            pendingAllocationBytes = 0
            if estimatedMemoryBytes() > limit {
                throw LuauRuntimeError(value: .string("not enough memory"), isMemory: true)
            }
        }
    }

    /// Estimates live VM memory in bytes across reachable globals, env, modules, and active stacks.
    public func estimatedMemoryBytes() -> Int {
        var tables = Set<ObjectIdentifier>()
        var closures = Set<ObjectIdentifier>()
        var protos = Set<ObjectIdentifier>()
        var threads = Set<ObjectIdentifier>()
        var userdata = Set<ObjectIdentifier>()
        var total = 64 * 1024 // base VM overhead

        func measureValue(_ v: LuauValue) {
            switch v {
            case .string(let s):
                total += 32 + s.utf8.count
            case .byteString(let b):
                total += 32 + b.count
            case .table(let t):
                measureTable(t)
            case .closure(let c):
                measureClosure(c)
            case .userdata(let u):
                let id = ObjectIdentifier(u)
                if userdata.insert(id).inserted {
                    total += 64
                    if let buf = u.payload as? LuauBufferBox {
                        total += buf.bytes.count
                    }
                    if let mt = u.metatable { measureTable(mt) }
                }
            case .thread(let th):
                measureThread(th)
            default:
                break
            }
        }

        func measureProto(_ p: LuauProto) {
            let id = ObjectIdentifier(p)
            guard protos.insert(id).inserted else { return }
            total += 64 + p.code.count * 16 + p.constants.count * 24
            for c in p.constants {
                if case .string(let s) = c { total += 32 + s.utf8.count }
                else if case .byteString(let b) = c { total += 32 + b.count }
            }
            for child in p.protos { measureProto(child) }
        }

        func measureClosure(_ c: LuauClosure) {
            let id = ObjectIdentifier(c)
            guard closures.insert(id).inserted else { return }
            total += 64 + c.upvalues.count * 24
            measureProto(c.proto)
            measureTable(c.env)
            for uv in c.upvalues { measureValue(uv.get()) }
        }

        func measureTable(_ t: LuauTable) {
            let id = ObjectIdentifier(t)
            guard tables.insert(id).inserted else { return }
            total += 64 + max(t.array.capacity, t.array.count) * 16 + t.hash.count * 48
            for v in t.array { measureValue(v) }
            for (k, v) in t.hash {
                if case .string(let ks) = k { total += 32 + ks.utf8.count }
                else if case .byteString(let kb) = k { total += 32 + kb.count }
                measureValue(v)
            }
            if let mt = t.metatable { measureTable(mt) }
        }

        func measureThread(_ th: LuauThread) {
            let id = ObjectIdentifier(th)
            guard threads.insert(id).inserted else { return }
            total += 256 + th.stack.count * 16
            for v in th.stack { measureValue(v) }
            for f in th.frames {
                measureClosure(f.closure)
                for va in f.varargs { measureValue(va) }
            }
        }

        measureTable(globals)
        if let sandboxEnv { measureTable(sandboxEnv) }
        for v in registeredModules.values { measureValue(v) }
        for v in moduleCache.values { measureValue(v) }
        measureThread(mainThread)
        if currentThread !== mainThread { measureThread(currentThread) }
        return total
    }
}

internal final class StringMetatableBox: @unchecked Sendable {
    let table: LuauTable
    init(_ table: LuauTable) { self.table = table }
}
