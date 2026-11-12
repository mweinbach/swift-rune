import Foundation

internal final class LuauCompiler {
    private struct LocalVar {
        let name: String
        let slot: Int
        let scopeDepth: Int
    }

    private struct LoopContext {
        let scopeDepth: Int
        let localCountAtStart: Int
        var breakJumps: [Int] = []
        var continueJumps: [Int] = []
    }

    private final class FuncState {
        let parent: FuncState?
        let name: String
        let sourceName: String
        let paramsCount: Int
        let isVariadic: Bool
        var locals: [LocalVar] = []
        var maxLocals: Int = 0
        var scopeDepth: Int = 0
        var constants: [LuauValue] = []
        var constMap: [LuauHashKey: Int] = [:]
        var upvalues: [LuauUpvalueDesc] = []
        var upvalueNames: [String] = []
        var protos: [LuauProto] = []
        var code: [LuauInstruction] = []
        var loops: [LoopContext] = []

        init(parent: FuncState?, name: String, sourceName: String, paramsCount: Int, isVariadic: Bool) {
            self.parent = parent
            self.name = name
            self.sourceName = sourceName
            self.paramsCount = paramsCount
            self.isVariadic = isVariadic
        }

        func addConstant(_ val: LuauValue) -> Int {
            if let hk = LuauHashKey(val), let existing = constMap[hk] {
                return existing
            }
            let idx = constants.count
            constants.append(val)
            if let hk = LuauHashKey(val) {
                constMap[hk] = idx
            }
            return idx
        }

        func emit(_ op: LuauOpCode, line: Int) -> Int {
            let idx = code.count
            code.append(LuauInstruction(op: op, line: line))
            return idx
        }

        func patchJump(_ instrIndex: Int, target: Int) {
            let offset = target - (instrIndex + 1)
            let line = code[instrIndex].line
            switch code[instrIndex].op {
            case .jump:
                code[instrIndex] = LuauInstruction(op: .jump(offset), line: line)
            case .jumpIfFalse:
                code[instrIndex] = LuauInstruction(op: .jumpIfFalse(offset), line: line)
            case .jumpIfTruePop:
                code[instrIndex] = LuauInstruction(op: .jumpIfTruePop(offset), line: line)
            case .andJump:
                code[instrIndex] = LuauInstruction(op: .andJump(offset), line: line)
            case .orJump:
                code[instrIndex] = LuauInstruction(op: .orJump(offset), line: line)
            case .numericForPrep(let slot, _):
                code[instrIndex] = LuauInstruction(op: .numericForPrep(varSlot: slot, jumpOffset: offset), line: line)
            case .numericForLoop(let slot, _):
                code[instrIndex] = LuauInstruction(op: .numericForLoop(varSlot: slot, jumpOffset: offset), line: line)
            case .genericForCall(let slot, let count, _):
                code[instrIndex] = LuauInstruction(op: .genericForCall(baseSlot: slot, varCount: count, jumpOffset: offset), line: line)
            default:
                break
            }
        }

        func declareLocal(_ name: String) -> Int {
            let slot = locals.count
            locals.append(LocalVar(name: name, slot: slot, scopeDepth: scopeDepth))
            if locals.count > maxLocals {
                maxLocals = locals.count
            }
            return slot
        }

        func resolveLocal(_ name: String) -> Int? {
            for i in stride(from: locals.count - 1, through: 0, by: -1) {
                if locals[i].name == name {
                    return locals[i].slot
                }
            }
            return nil
        }

        func resolveUpvalue(_ name: String) -> Int? {
            guard let parent else { return nil }
            if let localSlot = parent.resolveLocal(name) {
                return addUpvalue(name: name, desc: .local(localSlot))
            }
            if let parentUv = parent.resolveUpvalue(name) {
                return addUpvalue(name: name, desc: .upvalue(parentUv))
            }
            return nil
        }

        private func addUpvalue(name: String, desc: LuauUpvalueDesc) -> Int {
            if let existing = upvalueNames.firstIndex(of: name) {
                return existing
            }
            let idx = upvalues.count
            upvalues.append(desc)
            upvalueNames.append(name)
            return idx
        }

        func beginScope() {
            scopeDepth += 1
        }

        func endScope(line: Int) {
            let targetDepth = scopeDepth - 1
            var firstRemovedSlot: Int? = nil
            while let last = locals.last, last.scopeDepth > targetDepth {
                firstRemovedSlot = last.slot
                locals.removeLast()
            }
            if let slot = firstRemovedSlot {
                _ = emit(.closeUpvalues(fromSlot: slot), line: line)
            }
            scopeDepth = targetDepth
        }

        func buildProto() -> LuauProto {
            LuauProto(
                name: name,
                sourceName: sourceName,
                paramsCount: paramsCount,
                isVariadic: isVariadic,
                numLocals: maxLocals,
                constants: constants,
                upvalues: upvalues,
                protos: protos,
                code: code
            )
        }
    }

    private let sourceName: String

    init(sourceName: String = "chunk") {
        self.sourceName = sourceName
    }

    func compile(stmts: [LuauStmt]) throws -> LuauProto {
        let fs = FuncState(parent: nil, name: "<main>", sourceName: sourceName, paramsCount: 0, isVariadic: true)
        try compileBlock(stmts, in: fs)
        _ = fs.emit(.return(count: 0), line: 1)
        return fs.buildProto()
    }

    private func compileBlock(_ stmts: [LuauStmt], in fs: FuncState) throws {
        for stmt in stmts {
            try compileStmt(stmt, in: fs)
        }
    }

    private func compileStmt(_ stmt: LuauStmt, in fs: FuncState) throws {
        switch stmt {
        case .typeAlias:
            break

        case .block(let body, let line):
            fs.beginScope()
            try compileBlock(body, in: fs)
            fs.endScope(line: line)

        case .localDecl(let names, let values, let line):
            let slots = names.map { fs.declareLocal($0) }
            try compileExprList(values, expectedCount: names.count, in: fs, line: line)
            for slot in slots.reversed() {
                _ = fs.emit(.setLocal(slot), line: line)
            }

        case .localFunction(let name, let params, let isVariadic, let body, let line):
            let slot = fs.declareLocal(name)
            let proto = try compileFunction(name: name, params: params, isVariadic: isVariadic, body: body, parent: fs, line: line)
            let pIdx = fs.protos.count
            fs.protos.append(proto)
            _ = fs.emit(.closure(protoIndex: pIdx), line: line)
            _ = fs.emit(.setLocal(slot), line: line)

        case .functionDecl(let path, let method, let params, let isVariadic, let body, let line):
            var effectiveParams = params
            if method != nil {
                effectiveParams.insert("self", at: 0)
            }
            let funcName = (path + (method.map { [$0] } ?? [])).joined(separator: ".")
            let proto = try compileFunction(name: funcName, params: effectiveParams, isVariadic: isVariadic, body: body, parent: fs, line: line)
            let pIdx = fs.protos.count
            fs.protos.append(proto)

            if path.count == 1 && method == nil {
                _ = fs.emit(.closure(protoIndex: pIdx), line: line)
                try emitSetVariable(path[0], in: fs, line: line)
            } else {
                try emitGetVariable(path[0], in: fs, line: line)
                for seg in path.dropFirst().dropLast(method == nil ? 1 : 0) {
                    let k = fs.addConstant(.string(seg))
                    _ = fs.emit(.getField(k), line: line)
                }
                let fieldName = method ?? path.last!
                _ = fs.emit(.closure(protoIndex: pIdx), line: line)
                let k = fs.addConstant(.string(fieldName))
                _ = fs.emit(.setField(k), line: line)
            }

        case .assign(let targets, let values, let line):
            // Evaluate lvalue base expressions first (left to right), then values
            enum CompiledTarget {
                case local(Int)
                case upvalue(Int)
                case global(Int)
                case indexed
            }
            var compiledTargets: [CompiledTarget] = []
            for t in targets {
                switch t {
                case .variable(let name, _):
                    if let slot = fs.resolveLocal(name) {
                        compiledTargets.append(.local(slot))
                    } else if let uv = fs.resolveUpvalue(name) {
                        compiledTargets.append(.upvalue(uv))
                    } else {
                        let k = fs.addConstant(.string(name))
                        compiledTargets.append(.global(k))
                    }
                case .index(let tbl, let key, let tline):
                    try compileExpr(tbl, expectedResults: 1, in: fs)
                    try compileExpr(key, expectedResults: 1, in: fs)
                    _ = tline
                    compiledTargets.append(.indexed)
                case .member(let tbl, let name, let tline):
                    try compileExpr(tbl, expectedResults: 1, in: fs)
                    let k = fs.addConstant(.string(name))
                    _ = fs.emit(.loadConst(k), line: tline)
                    compiledTargets.append(.indexed)
                }
            }
            try compileExprList(values, expectedCount: targets.count, in: fs, line: line)
            for ct in compiledTargets.reversed() {
                switch ct {
                case .local(let slot): _ = fs.emit(.setLocal(slot), line: line)
                case .upvalue(let uv): _ = fs.emit(.setUpvalue(uv), line: line)
                case .global(let k): _ = fs.emit(.setGlobal(k), line: line)
                case .indexed: _ = fs.emit(.setTable, line: line)
                }
            }

        case .compoundAssign(let target, let op, let value, let line):
            let binOp: LuauBinaryOp = switch op {
            case .add: .add
            case .sub: .sub
            case .mul: .mul
            case .div: .div
            case .idiv: .idiv
            case .mod: .mod
            case .pow: .pow
            case .concat: .concat
            }
            switch target {
            case .variable(let name, _):
                try emitGetVariable(name, in: fs, line: line)
                try compileExpr(value, expectedResults: 1, in: fs)
                emitBinaryOp(binOp, in: fs, line: line)
                try emitSetVariable(name, in: fs, line: line)
            case .member(let tbl, let field, _):
                // Evaluate table once into a temp local slot
                fs.beginScope()
                let tSlot = fs.declareLocal("$cmp_t")
                try compileExpr(tbl, expectedResults: 1, in: fs)
                _ = fs.emit(.setLocal(tSlot), line: line)
                let k = fs.addConstant(.string(field))
                _ = fs.emit(.getLocal(tSlot), line: line)
                _ = fs.emit(.getField(k), line: line)
                try compileExpr(value, expectedResults: 1, in: fs)
                emitBinaryOp(binOp, in: fs, line: line)
                let vSlot = fs.declareLocal("$cmp_v")
                _ = fs.emit(.setLocal(vSlot), line: line)
                _ = fs.emit(.getLocal(tSlot), line: line)
                _ = fs.emit(.getLocal(vSlot), line: line)
                _ = fs.emit(.setField(k), line: line)
                fs.endScope(line: line)
            case .index(let tbl, let key, _):
                fs.beginScope()
                let tSlot = fs.declareLocal("$cmp_t")
                let kSlot = fs.declareLocal("$cmp_k")
                try compileExpr(tbl, expectedResults: 1, in: fs)
                _ = fs.emit(.setLocal(tSlot), line: line)
                try compileExpr(key, expectedResults: 1, in: fs)
                _ = fs.emit(.setLocal(kSlot), line: line)
                _ = fs.emit(.getLocal(tSlot), line: line)
                _ = fs.emit(.getLocal(kSlot), line: line)
                _ = fs.emit(.getTable, line: line)
                try compileExpr(value, expectedResults: 1, in: fs)
                emitBinaryOp(binOp, in: fs, line: line)
                let vSlot = fs.declareLocal("$cmp_v")
                _ = fs.emit(.setLocal(vSlot), line: line)
                _ = fs.emit(.getLocal(tSlot), line: line)
                _ = fs.emit(.getLocal(kSlot), line: line)
                _ = fs.emit(.getLocal(vSlot), line: line)
                _ = fs.emit(.setTable, line: line)
                fs.endScope(line: line)
            }

        case .call(let expr, _):
            try compileExpr(expr, expectedResults: 0, in: fs)

        case .ifStmt(let branches, let elseBody, let line):
            var endJumps: [Int] = []
            for branch in branches {
                try compileExpr(branch.cond, expectedResults: 1, in: fs)
                let jumpFalse = fs.emit(.jumpIfFalse(0), line: line)
                fs.beginScope()
                try compileBlock(branch.body, in: fs)
                fs.endScope(line: line)
                endJumps.append(fs.emit(.jump(0), line: line))
                fs.patchJump(jumpFalse, target: fs.code.count)
            }
            if let elseBody {
                fs.beginScope()
                try compileBlock(elseBody, in: fs)
                fs.endScope(line: line)
            }
            let endPos = fs.code.count
            for j in endJumps {
                fs.patchJump(j, target: endPos)
            }

        case .whileStmt(let cond, let body, let line):
            let loopStart = fs.code.count
            try compileExpr(cond, expectedResults: 1, in: fs)
            let exitJump = fs.emit(.jumpIfFalse(0), line: line)
            fs.loops.append(LoopContext(scopeDepth: fs.scopeDepth, localCountAtStart: fs.locals.count))
            fs.beginScope()
            try compileBlock(body, in: fs)
            fs.endScope(line: line)
            let ctx = fs.loops.removeLast()
            for cj in ctx.continueJumps {
                fs.patchJump(cj, target: loopStart)
            }
            let backJump = fs.emit(.jump(0), line: line)
            fs.patchJump(backJump, target: loopStart)
            let afterLoop = fs.code.count
            fs.patchJump(exitJump, target: afterLoop)
            for bj in ctx.breakJumps {
                fs.patchJump(bj, target: afterLoop)
            }

        case .repeatStmt(let body, let cond, let line):
            let loopStart = fs.code.count
            fs.loops.append(LoopContext(scopeDepth: fs.scopeDepth, localCountAtStart: fs.locals.count))
            fs.beginScope()
            try compileBlock(body, in: fs)
            let continueTarget = fs.code.count
            try compileExpr(cond, expectedResults: 1, in: fs)
            fs.endScope(line: line)
            let ctx = fs.loops.removeLast()
            for cj in ctx.continueJumps {
                fs.patchJump(cj, target: continueTarget)
            }
            let backJump = fs.emit(.jumpIfFalse(0), line: line)
            fs.patchJump(backJump, target: loopStart)
            let afterLoop = fs.code.count
            for bj in ctx.breakJumps {
                fs.patchJump(bj, target: afterLoop)
            }

        case .numericFor(let varName, let start, let limit, let step, let body, let line):
            fs.beginScope()
            let baseSlot = fs.declareLocal("$for_idx")
            _ = fs.declareLocal("$for_limit")
            _ = fs.declareLocal("$for_step")
            let userSlot = fs.declareLocal(varName)

            try compileExpr(start, expectedResults: 1, in: fs)
            _ = fs.emit(.setLocal(baseSlot), line: line)
            try compileExpr(limit, expectedResults: 1, in: fs)
            _ = fs.emit(.setLocal(baseSlot + 1), line: line)
            if let step {
                try compileExpr(step, expectedResults: 1, in: fs)
            } else {
                let one = fs.addConstant(.number(1))
                _ = fs.emit(.loadConst(one), line: line)
            }
            _ = fs.emit(.setLocal(baseSlot + 2), line: line)

            let prepJump = fs.emit(.numericForPrep(varSlot: baseSlot, jumpOffset: 0), line: line)
            let bodyStart = fs.code.count
            fs.loops.append(LoopContext(scopeDepth: fs.scopeDepth, localCountAtStart: fs.locals.count))
            fs.beginScope()
            _ = fs.emit(.getLocal(baseSlot), line: line)
            _ = fs.emit(.setLocal(userSlot), line: line)
            try compileBlock(body, in: fs)
            fs.endScope(line: line)
            let ctx = fs.loops.removeLast()
            let stepPos = fs.code.count
            for cj in ctx.continueJumps {
                fs.patchJump(cj, target: stepPos)
            }
            // Close upvalues captured on the user loop variable before next iteration
            _ = fs.emit(.closeUpvalues(fromSlot: userSlot), line: line)
            let loopJump = fs.emit(.numericForLoop(varSlot: baseSlot, jumpOffset: 0), line: line)
            fs.patchJump(loopJump, target: bodyStart)
            fs.patchJump(prepJump, target: fs.code.count)
            let afterLoop = fs.code.count
            for bj in ctx.breakJumps {
                fs.patchJump(bj, target: afterLoop)
            }
            fs.endScope(line: line)

        case .genericFor(let names, let iterators, let body, let line):
            fs.beginScope()
            let baseSlot = fs.declareLocal("$gen_fn")
            _ = fs.declareLocal("$gen_state")
            _ = fs.declareLocal("$gen_ctrl")
            var varSlots: [Int] = []
            for n in names {
                varSlots.append(fs.declareLocal(n))
            }
            try compileExprList(iterators, expectedCount: 3, in: fs, line: line)
            _ = fs.emit(.setLocal(baseSlot + 2), line: line)
            _ = fs.emit(.setLocal(baseSlot + 1), line: line)
            _ = fs.emit(.setLocal(baseSlot), line: line)
            _ = fs.emit(.genericForPrep(baseSlot: baseSlot), line: line)

            let callPos = fs.code.count
            let loopCall = fs.emit(.genericForCall(baseSlot: baseSlot, varCount: names.count, jumpOffset: 0), line: line)
            fs.loops.append(LoopContext(scopeDepth: fs.scopeDepth, localCountAtStart: fs.locals.count))
            fs.beginScope()
            try compileBlock(body, in: fs)
            fs.endScope(line: line)
            let ctx = fs.loops.removeLast()
            let continueTarget = fs.code.count
            for cj in ctx.continueJumps {
                fs.patchJump(cj, target: continueTarget)
            }
            _ = fs.emit(.closeUpvalues(fromSlot: baseSlot + 3), line: line)
            let back = fs.emit(.jump(0), line: line)
            fs.patchJump(back, target: callPos)

            let afterLoop = fs.code.count
            fs.patchJump(loopCall, target: afterLoop)
            for bj in ctx.breakJumps {
                fs.patchJump(bj, target: afterLoop)
            }
            fs.endScope(line: line)

        case .returnStmt(let exprs, let line):
            if exprs.isEmpty {
                _ = fs.emit(.return(count: 0), line: line)
            } else if let last = exprs.last, isMultiReturnExpr(last) {
                _ = fs.emit(.pushMark, line: line)
                for e in exprs.dropLast() {
                    try compileExpr(e, expectedResults: 1, in: fs)
                }
                try compileExpr(last, expectedResults: -1, in: fs)
                _ = fs.emit(.popMarkAndReturn, line: line)
            } else {
                for e in exprs {
                    try compileExpr(e, expectedResults: 1, in: fs)
                }
                _ = fs.emit(.return(count: exprs.count), line: line)
            }

        case .breakStmt(let line):
            guard !fs.loops.isEmpty else {
                throw ScriptError(kind: .syntax, message: "\(sourceName):\(line): no loop to break")
            }
            let idx = fs.loops.count - 1
            if fs.loops[idx].localCountAtStart < fs.locals.count {
                _ = fs.emit(.closeUpvalues(fromSlot: fs.loops[idx].localCountAtStart), line: line)
            }
            let j = fs.emit(.jump(0), line: line)
            fs.loops[idx].breakJumps.append(j)

        case .continueStmt(let line):
            guard !fs.loops.isEmpty else {
                throw ScriptError(kind: .syntax, message: "\(sourceName):\(line): no loop to continue")
            }
            let idx = fs.loops.count - 1
            if fs.loops[idx].localCountAtStart < fs.locals.count {
                _ = fs.emit(.closeUpvalues(fromSlot: fs.loops[idx].localCountAtStart), line: line)
            }
            let j = fs.emit(.jump(0), line: line)
            fs.loops[idx].continueJumps.append(j)
        }
    }

    private func compileFunction(name: String, params: [String], isVariadic: Bool, body: [LuauStmt], parent: FuncState, line: Int) throws -> LuauProto {
        let child = FuncState(parent: parent, name: name, sourceName: sourceName, paramsCount: params.count, isVariadic: isVariadic)
        for p in params {
            _ = child.declareLocal(p)
        }
        try compileBlock(body, in: child)
        _ = child.emit(.return(count: 0), line: line)
        return child.buildProto()
    }

    private func compileExprList(_ exprs: [LuauExpr], expectedCount: Int, in fs: FuncState, line: Int) throws {
        if exprs.isEmpty {
            for _ in 0..<expectedCount {
                _ = fs.emit(.loadNil, line: line)
            }
            return
        }
        if exprs.count < expectedCount, let last = exprs.last, isMultiReturnExpr(last) {
            for e in exprs.dropLast() {
                try compileExpr(e, expectedResults: 1, in: fs)
            }
            let needed = expectedCount - (exprs.count - 1)
            try compileExpr(last, expectedResults: needed, in: fs)
        } else if exprs.count <= expectedCount {
            for e in exprs {
                try compileExpr(e, expectedResults: 1, in: fs)
            }
            for _ in exprs.count..<expectedCount {
                _ = fs.emit(.loadNil, line: line)
            }
        } else {
            for (i, e) in exprs.enumerated() {
                try compileExpr(e, expectedResults: i < expectedCount ? 1 : 0, in: fs)
            }
        }
    }

    private func isMultiReturnExpr(_ expr: LuauExpr) -> Bool {
        switch expr {
        case .call, .methodCall, .vararg: return true
        default: return false
        }
    }

    private func compileExpr(_ expr: LuauExpr, expectedResults: Int, in fs: FuncState) throws {
        switch expr {
        case .nil(let line):
            if expectedResults > 0 {
                for _ in 0..<expectedResults { _ = fs.emit(.loadNil, line: line) }
            }
        case .bool(let b, let line):
            if expectedResults > 0 {
                _ = fs.emit(.loadBool(b), line: line)
                for _ in 1..<expectedResults { _ = fs.emit(.loadNil, line: line) }
            }
        case .number(let n, let line):
            if expectedResults > 0 {
                let k = fs.addConstant(.number(n))
                _ = fs.emit(.loadConst(k), line: line)
                for _ in 1..<expectedResults { _ = fs.emit(.loadNil, line: line) }
            }
        case .string(let s, let line):
            if expectedResults > 0 {
                let k = fs.addConstant(.string(s))
                _ = fs.emit(.loadConst(k), line: line)
                for _ in 1..<expectedResults { _ = fs.emit(.loadNil, line: line) }
            }
        case .vararg(let line):
            _ = fs.emit(.loadVararg(expected: expectedResults), line: line)

        case .variable(let name, let line):
            if expectedResults > 0 {
                try emitGetVariable(name, in: fs, line: line)
                for _ in 1..<expectedResults { _ = fs.emit(.loadNil, line: line) }
            }

        case .group(let inner, let line):
            try compileExpr(inner, expectedResults: expectedResults > 0 ? 1 : 0, in: fs)
            if expectedResults > 1 {
                for _ in 1..<expectedResults { _ = fs.emit(.loadNil, line: line) }
            }

        case .index(let tbl, let key, let line):
            try compileExpr(tbl, expectedResults: 1, in: fs)
            try compileExpr(key, expectedResults: 1, in: fs)
            _ = fs.emit(.getTable, line: line)
            if expectedResults == 0 {
                // Pop if unused? Actually we keep stack clean by adjusting, or use local.
                // Let's handle expectedResults == 0 cleanly if needed; in Lua index isn't a statement.
            } else if expectedResults > 1 {
                for _ in 1..<expectedResults { _ = fs.emit(.loadNil, line: line) }
            }

        case .member(let tbl, let name, let line):
            try compileExpr(tbl, expectedResults: 1, in: fs)
            let k = fs.addConstant(.string(name))
            _ = fs.emit(.getField(k), line: line)
            if expectedResults > 1 {
                for _ in 1..<expectedResults { _ = fs.emit(.loadNil, line: line) }
            }

        case .function(let params, let isVariadic, let body, let line):
            if expectedResults > 0 {
                let proto = try compileFunction(name: "<anon>", params: params, isVariadic: isVariadic, body: body, parent: fs, line: line)
                let pIdx = fs.protos.count
                fs.protos.append(proto)
                _ = fs.emit(.closure(protoIndex: pIdx), line: line)
                for _ in 1..<expectedResults { _ = fs.emit(.loadNil, line: line) }
            }

        case .unary(let op, let operand, let line):
            try compileExpr(operand, expectedResults: 1, in: fs)
            switch op {
            case .neg: _ = fs.emit(.neg, line: line)
            case .not: _ = fs.emit(.not, line: line)
            case .len: _ = fs.emit(.len, line: line)
            }

        case .binary(let op, let lhs, let rhs, let line):
            if op == .and {
                try compileExpr(lhs, expectedResults: 1, in: fs)
                let j = fs.emit(.andJump(0), line: line)
                try compileExpr(rhs, expectedResults: 1, in: fs)
                fs.patchJump(j, target: fs.code.count)
            } else if op == .or {
                try compileExpr(lhs, expectedResults: 1, in: fs)
                let j = fs.emit(.orJump(0), line: line)
                try compileExpr(rhs, expectedResults: 1, in: fs)
                fs.patchJump(j, target: fs.code.count)
            } else {
                try compileExpr(lhs, expectedResults: 1, in: fs)
                try compileExpr(rhs, expectedResults: 1, in: fs)
                emitBinaryOp(op, in: fs, line: line)
            }

        case .ifExpr(let branches, let elseValue, let line):
            var endJumps: [Int] = []
            for b in branches {
                try compileExpr(b.cond, expectedResults: 1, in: fs)
                let jf = fs.emit(.jumpIfFalse(0), line: line)
                try compileExpr(b.value, expectedResults: 1, in: fs)
                endJumps.append(fs.emit(.jump(0), line: line))
                fs.patchJump(jf, target: fs.code.count)
            }
            try compileExpr(elseValue, expectedResults: 1, in: fs)
            let endPos = fs.code.count
            for j in endJumps {
                fs.patchJump(j, target: endPos)
            }

        case .interpString(let parts, let exprs, let line):
            for (i, part) in parts.enumerated() {
                let k = fs.addConstant(.string(part))
                _ = fs.emit(.loadConst(k), line: line)
                if i < exprs.count {
                    try compileExpr(exprs[i], expectedResults: 1, in: fs)
                }
            }
            _ = fs.emit(.interp(partsCount: parts.count + exprs.count), line: line)

        case .table(let entries, let line):
            let arrayCount = entries.filter { $0.key == nil }.count
            let hashCount = entries.count - arrayCount
            _ = fs.emit(.newTable(arrayHint: arrayCount, hashHint: hashCount), line: line)
            var arrayIndex = 1
            var batchCount = 0
            for (i, entry) in entries.enumerated() {
                if let key = entry.key {
                    if batchCount > 0 {
                        _ = fs.emit(.setList(startIndex: arrayIndex, count: batchCount), line: line)
                        arrayIndex += batchCount
                        batchCount = 0
                    }
                    try compileExpr(key, expectedResults: 1, in: fs)
                    try compileExpr(entry.value, expectedResults: 1, in: fs)
                    _ = fs.emit(.initTableField, line: line)
                } else {
                    let isLast = (i == entries.count - 1)
                    if isLast && isMultiReturnExpr(entry.value) {
                        if batchCount > 0 {
                            _ = fs.emit(.setList(startIndex: arrayIndex, count: batchCount), line: line)
                            arrayIndex += batchCount
                            batchCount = 0
                        }
                        _ = fs.emit(.pushMark, line: line)
                        try compileExpr(entry.value, expectedResults: -1, in: fs)
                        _ = fs.emit(.setListMulti(startIndex: arrayIndex, stackBaseMark: 0), line: line)
                    } else {
                        try compileExpr(entry.value, expectedResults: 1, in: fs)
                        batchCount += 1
                        if batchCount == 50 || isLast {
                            _ = fs.emit(.setList(startIndex: arrayIndex, count: batchCount), line: line)
                            arrayIndex += batchCount
                            batchCount = 0
                        }
                    }
                }
            }

        case .call(let callee, let args, let line):
            try compileExpr(callee, expectedResults: 1, in: fs)
            if let last = args.last, isMultiReturnExpr(last) {
                _ = fs.emit(.pushMark, line: line)
                for a in args.dropLast() {
                    try compileExpr(a, expectedResults: 1, in: fs)
                }
                try compileExpr(last, expectedResults: -1, in: fs)
                _ = fs.emit(.callMulti(fixedArgsBefore: args.count - 1, expectedResults: expectedResults), line: line)
            } else {
                for a in args {
                    try compileExpr(a, expectedResults: 1, in: fs)
                }
                _ = fs.emit(.call(argCount: args.count, expectedResults: expectedResults), line: line)
            }

        case .methodCall(let receiver, let method, let args, let line):
            try compileExpr(receiver, expectedResults: 1, in: fs)
            let k = fs.addConstant(.string(method))
            _ = fs.emit(.selfMethod(k), line: line)
            if let last = args.last, isMultiReturnExpr(last) {
                _ = fs.emit(.pushMark, line: line)
                for a in args.dropLast() {
                    try compileExpr(a, expectedResults: 1, in: fs)
                }
                try compileExpr(last, expectedResults: -1, in: fs)
                _ = fs.emit(.callMulti(fixedArgsBefore: args.count, expectedResults: expectedResults), line: line)
            } else {
                for a in args {
                    try compileExpr(a, expectedResults: 1, in: fs)
                }
                _ = fs.emit(.call(argCount: args.count + 1, expectedResults: expectedResults), line: line)
            }
        }
    }

    private func emitGetVariable(_ name: String, in fs: FuncState, line: Int) throws {
        if let slot = fs.resolveLocal(name) {
            _ = fs.emit(.getLocal(slot), line: line)
        } else if let uv = fs.resolveUpvalue(name) {
            _ = fs.emit(.getUpvalue(uv), line: line)
        } else {
            let k = fs.addConstant(.string(name))
            _ = fs.emit(.getGlobal(k), line: line)
        }
    }

    private func emitSetVariable(_ name: String, in fs: FuncState, line: Int) throws {
        if let slot = fs.resolveLocal(name) {
            _ = fs.emit(.setLocal(slot), line: line)
        } else if let uv = fs.resolveUpvalue(name) {
            _ = fs.emit(.setUpvalue(uv), line: line)
        } else {
            let k = fs.addConstant(.string(name))
            _ = fs.emit(.setGlobal(k), line: line)
        }
    }

    private func emitBinaryOp(_ op: LuauBinaryOp, in fs: FuncState, line: Int) {
        let code: LuauOpCode = switch op {
        case .add: .add
        case .sub: .sub
        case .mul: .mul
        case .div: .div
        case .idiv: .idiv
        case .mod: .mod
        case .pow: .pow
        case .concat: .concat
        case .eq: .eq
        case .neq: .neq
        case .lt: .lt
        case .le: .le
        case .gt: .gt
        case .ge: .ge
        case .and, .or: .add // unreachable
        }
        _ = fs.emit(code, line: line)
    }
}
