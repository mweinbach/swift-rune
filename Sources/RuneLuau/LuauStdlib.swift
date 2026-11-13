import Foundation

internal enum LuauStdlib {
    static let nextFunction = LuauNativeFunction(name: "next") { _, _, args in
        guard case .table(let t) = args.first else {
            throw LuauRuntimeError(value: .string("bad argument #1 to 'next' (table expected)"))
        }
        let key = args.count > 1 ? args[1] : .nil
        if let (nk, nv) = t.next(after: key) {
            return .values([nk, nv])
        }
        return .values([.nil])
    }

    static let ipairsIterFunction = LuauNativeFunction(name: "ipairs_iter") { _, _, args in
        guard case .table(let t) = args.first else {
            throw LuauRuntimeError(value: .string("bad argument #1 to 'ipairs' (table expected)"))
        }
        let prev = Int(args.count > 1 ? (args[1].asNumber ?? 0) : 0)
        let nextIdx = prev + 1
        let val = t.rawGet(nextIdx)
        if val.isNil {
            return .values([.nil])
        }
        return .values([.number(Double(nextIdx)), val])
    }

    static func install(into vm: LuauVM) {
        let g = vm.globals
        g.rawSet("_G", value: .table(g))
        g.rawSet("_VERSION", value: .string("Luau"))

        installGlobals(into: g, vm: vm)
        installMath(into: g)
        installString(into: g, vm: vm)
        installTable(into: g, vm: vm)
        installBit32(into: g)
        installUtf8(into: g)
        installOS(into: g)
        installCoroutine(into: g)
        installDebug(into: g)
        installVector(into: g)
    }

    // MARK: - Globals

    private static func installGlobals(into g: LuauTable, vm: LuauVM) {
        g.rawSet("print", value: .nativeFunction(LuauNativeFunction(name: "print") { vm, _, args in
            let parts = try args.map { try vm.valueToString($0) }
            let line = parts.joined(separator: "\t")
            if let onPrint = vm.onPrint {
                onPrint(line)
            } else {
                Swift.print(line)
            }
            return .values([])
        }))

        g.rawSet("warn", value: .nativeFunction(LuauNativeFunction(name: "warn") { vm, _, args in
            let parts = try args.map { try vm.valueToString($0) }
            let line = parts.joined(separator: "\t")
            if let onWarn = vm.onWarn {
                onWarn(line)
            } else {
                Swift.print("[warn] \(line)")
            }
            return .values([])
        }))

        g.rawSet("error", value: .nativeFunction(LuauNativeFunction(name: "error") { _, _, args in
            let msg = args.first ?? .nil
            throw LuauRuntimeError(value: msg)
        }))

        g.rawSet("assert", value: .nativeFunction(LuauNativeFunction(name: "assert") { _, _, args in
            let cond = args.first ?? .nil
            if !cond.isTruthy {
                let msg = args.count > 1 ? args[1] : .string("assertion failed!")
                throw LuauRuntimeError(value: msg)
            }
            return .values(args)
        }))

        g.rawSet("type", value: .nativeFunction(LuauNativeFunction(name: "type") { _, _, args in
            let v = args.first ?? .nil
            return .values([.string(v.typeName)])
        }))

        g.rawSet("typeof", value: .nativeFunction(LuauNativeFunction(name: "typeof") { _, _, args in
            let v = args.first ?? .nil
            return .values([.string(v.typeofName)])
        }))

        g.rawSet("tostring", value: .nativeFunction(LuauNativeFunction(name: "tostring") { vm, _, args in
            let v = args.first ?? .nil
            return .values([.string(try vm.valueToString(v))])
        }))

        g.rawSet("tonumber", value: .nativeFunction(LuauNativeFunction(name: "tonumber") { _, _, args in
            guard let v = args.first else { return .values([.nil]) }
            let base = args.count > 1 ? args[1].asInt : nil
            if let base {
                guard base >= 2 && base <= 36, case .string(let s) = v else {
                    return .values([.nil])
                }
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if let val = Int64(trimmed, radix: base) {
                    return .values([.number(Double(val))])
                }
                return .values([.nil])
            }
            if let d = v.coercedNumber {
                return .values([.number(d)])
            }
            return .values([.nil])
        }))

        g.rawSet("select", value: .nativeFunction(LuauNativeFunction(name: "select") { _, _, args in
            guard let first = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'select'"))
            }
            if case .string("#") = first {
                return .values([.number(Double(max(0, args.count - 1)))])
            }
            guard let idx = first.asInt else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'select' (number expected)"))
            }
            let rest = Array(args.dropFirst())
            if idx == 0 {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'select' (index out of range)"))
            }
            let actual = idx > 0 ? (idx - 1) : (rest.count + idx)
            if actual < 0 || actual >= rest.count {
                return .values([])
            }
            return .values(Array(rest[actual...]))
        }))

        g.rawSet("next", value: .nativeFunction(nextFunction))

        g.rawSet("pairs", value: .nativeFunction(LuauNativeFunction(name: "pairs") { vm, _, args in
            guard let first = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'pairs' (table expected)"))
            }
            if let mm = vm.getMetamethod(of: first, name: "__pairs") {
                return .values(try vm.call(value: mm, args: [first]))
            }
            return .values([.nativeFunction(nextFunction), first, .nil])
        }))

        g.rawSet("ipairs", value: .nativeFunction(LuauNativeFunction(name: "ipairs") { vm, _, args in
            guard let first = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'ipairs' (table expected)"))
            }
            if let mm = vm.getMetamethod(of: first, name: "__ipairs") {
                return .values(try vm.call(value: mm, args: [first]))
            }
            return .values([.nativeFunction(ipairsIterFunction), first, .number(0)])
        }))

        g.rawSet("getmetatable", value: .nativeFunction(LuauNativeFunction(name: "getmetatable") { vm, _, args in
            guard let v = args.first, let mt = vm.getMetatable(of: v) else {
                return .values([.nil])
            }
            let prot = mt.rawGet("__metatable")
            if !prot.isNil { return .values([prot]) }
            return .values([.table(mt)])
        }))

        g.rawSet("setmetatable", value: .nativeFunction(LuauNativeFunction(name: "setmetatable") { _, _, args in
            guard case .table(let t) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'setmetatable' (table expected)"))
            }
            if t.isFrozen {
                throw LuauRuntimeError(value: .string("attempt to modify a readonly table"))
            }
            if let existing = t.metatable, !existing.rawGet("__metatable").isNil {
                throw LuauRuntimeError(value: .string("cannot change a protected metatable"))
            }
            let mtArg = args.count > 1 ? args[1] : .nil
            switch mtArg {
            case .nil:
                t.metatable = nil
            case .table(let mt):
                t.metatable = mt
            default:
                throw LuauRuntimeError(value: .string("bad argument #2 to 'setmetatable' (nil or table expected)"))
            }
            return .values([.table(t)])
        }))

        g.rawSet("rawget", value: .nativeFunction(LuauNativeFunction(name: "rawget") { _, _, args in
            guard case .table(let t) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'rawget' (table expected)"))
            }
            let key = args.count > 1 ? args[1] : .nil
            return .values([t.rawGet(key)])
        }))

        g.rawSet("rawset", value: .nativeFunction(LuauNativeFunction(name: "rawset") { _, _, args in
            guard case .table(let t) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'rawset' (table expected)"))
            }
            let key = args.count > 1 ? args[1] : .nil
            let val = args.count > 2 ? args[2] : .nil
            try t.rawSet(key, value: val)
            return .values([.table(t)])
        }))

        g.rawSet("rawequal", value: .nativeFunction(LuauNativeFunction(name: "rawequal") { _, _, args in
            let a = args.count > 0 ? args[0] : .nil
            let b = args.count > 1 ? args[1] : .nil
            return .values([.bool(a == b)])
        }))

        g.rawSet("rawlen", value: .nativeFunction(LuauNativeFunction(name: "rawlen") { _, _, args in
            guard let v = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'rawlen'"))
            }
            switch v {
            case .table(let t): return .values([.number(Double(t.rawLength))])
            case .string(let s): return .values([.number(Double(s.utf8.count))])
            default: throw LuauRuntimeError(value: .string("bad argument #1 to 'rawlen' (table or string expected)"))
            }
        }))

        g.rawSet("pcall", value: .nativeFunction(LuauNativeFunction(name: "pcall") { vm, _, args in
            guard let fn = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'pcall' (value expected)"))
            }
            do {
                let res = try vm.call(value: fn, args: Array(args.dropFirst()))
                return .values([.bool(true)] + res)
            } catch let err as LuauRuntimeError {
                if err.isTimeout { throw err }
                return .values([.bool(false), err.value])
            } catch {
                return .values([.bool(false), .string(error.localizedDescription)])
            }
        }))

        g.rawSet("xpcall", value: .nativeFunction(LuauNativeFunction(name: "xpcall") { vm, _, args in
            guard args.count >= 2 else {
                throw LuauRuntimeError(value: .string("bad argument #2 to 'xpcall' (function expected)"))
            }
            let fn = args[0]
            let errHandler = args[1]
            do {
                let res = try vm.call(value: fn, args: Array(args.dropFirst(2)))
                return .values([.bool(true)] + res)
            } catch let err as LuauRuntimeError {
                if err.isTimeout { throw err }
                let handled = (try? vm.call(value: errHandler, args: [err.value]).first) ?? err.value
                return .values([.bool(false), handled])
            }
        }))

        g.rawSet("unpack", value: .nativeFunction(LuauNativeFunction(name: "unpack") { _, _, args in
            guard case .table(let t) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'unpack' (table expected)"))
            }
            let i = args.count > 1 ? (args[1].asInt ?? 1) : 1
            let j = args.count > 2 ? (args[2].asInt ?? t.rawLength) : t.rawLength
            if i > j { return .values([]) }
            return .values((i...j).map { t.rawGet($0) })
        }))

        g.rawSet("newproxy", value: .nativeFunction(LuauNativeFunction(name: "newproxy") { _, _, args in
            let addMt = args.first?.isTruthy ?? false
            let mt = addMt ? LuauTable() : nil
            return .values([.userdata(LuauUserdata(payload: nil, metatable: mt))])
        }))

        g.rawSet("loadstring", value: .nativeFunction(LuauNativeFunction(name: "loadstring") { vm, _, args in
            guard case .string(let src) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'loadstring' (string expected)"))
            }
            let chunkName = (args.count > 1 ? args[1].asString : nil) ?? "loadstring"
            do {
                let cl = try vm.load(source: src, name: chunkName)
                return .values([.closure(cl)])
            } catch let err as ScriptError {
                return .values([.nil, .string(err.message)])
            } catch {
                return .values([.nil, .string(error.localizedDescription)])
            }
        }))
    }

    // MARK: - math

    private static func installMath(into g: LuauTable) {
        let m = LuauTable()
        m.rawSet("pi", value: .number(Double.pi))
        m.rawSet("huge", value: .number(Double.infinity))

        func num1(_ name: String, _ f: @escaping @Sendable (Double) -> Double) {
            m.rawSet(name, value: .nativeFunction(LuauNativeFunction(name: "math.\(name)") { _, _, args in
                guard let x = args.first?.coercedNumber else {
                    throw LuauRuntimeError(value: .string("bad argument #1 to '\(name)' (number expected)"))
                }
                return .values([.number(f(x))])
            }))
        }

        func num2(_ name: String, _ f: @escaping @Sendable (Double, Double) -> Double) {
            m.rawSet(name, value: .nativeFunction(LuauNativeFunction(name: "math.\(name)") { _, _, args in
                guard let a = args.first?.coercedNumber, let b = args.dropFirst().first?.coercedNumber else {
                    throw LuauRuntimeError(value: .string("bad arguments to '\(name)' (number expected)"))
                }
                return .values([.number(f(a, b))])
            }))
        }

        num1("abs", abs)
        num1("acos", acos)
        num1("asin", asin)
        num1("ceil", ceil)
        num1("cos", cos)
        num1("cosh", cosh)
        num1("deg") { $0 * 180.0 / Double.pi }
        num1("exp", exp)
        num1("floor", floor)
        num1("log10", log10)
        num1("rad") { $0 * Double.pi / 180.0 }
        num1("round") { $0.rounded() }
        num1("sign") { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) }
        num1("sin", sin)
        num1("sinh", sinh)
        num1("sqrt", sqrt)
        num1("tan", tan)
        num1("tanh", tanh)

        num2("atan2", atan2)
        num2("fmod", fmod)
        num2("pow", pow)
        num2("ldexp") { ldexp($0, Int32($1)) }

        m.rawSet("atan", value: .nativeFunction(LuauNativeFunction(name: "math.atan") { _, _, args in
            guard let y = args.first?.coercedNumber else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'atan'"))
            }
            if let x = args.dropFirst().first?.coercedNumber {
                return .values([.number(atan2(y, x))])
            }
            return .values([.number(atan(y))])
        }))

        m.rawSet("log", value: .nativeFunction(LuauNativeFunction(name: "math.log") { _, _, args in
            guard let x = args.first?.coercedNumber else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'log'"))
            }
            if let base = args.dropFirst().first?.coercedNumber {
                return .values([.number(log(x) / log(base))])
            }
            return .values([.number(log(x))])
        }))

        m.rawSet("clamp", value: .nativeFunction(LuauNativeFunction(name: "math.clamp") { _, _, args in
            guard args.count >= 3,
                  let x = args[0].coercedNumber,
                  let lo = args[1].coercedNumber,
                  let hi = args[2].coercedNumber else {
                throw LuauRuntimeError(value: .string("bad arguments to 'clamp'"))
            }
            return .values([.number(Swift.min(Swift.max(x, lo), hi))])
        }))

        m.rawSet("min", value: .nativeFunction(LuauNativeFunction(name: "math.min") { _, _, args in
            guard let first = args.first?.coercedNumber else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'min'"))
            }
            var best = first
            for a in args.dropFirst() {
                guard let v = a.coercedNumber else { throw LuauRuntimeError(value: .string("number expected")) }
                if v < best { best = v }
            }
            return .values([.number(best)])
        }))

        m.rawSet("max", value: .nativeFunction(LuauNativeFunction(name: "math.max") { _, _, args in
            guard let first = args.first?.coercedNumber else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'max'"))
            }
            var best = first
            for a in args.dropFirst() {
                guard let v = a.coercedNumber else { throw LuauRuntimeError(value: .string("number expected")) }
                if v > best { best = v }
            }
            return .values([.number(best)])
        }))

        m.rawSet("modf", value: .nativeFunction(LuauNativeFunction(name: "math.modf") { _, _, args in
            guard let x = args.first?.coercedNumber else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'modf'"))
            }
            let (i, f) = modf(x)
            return .values([.number(i), .number(f)])
        }))

        m.rawSet("frexp", value: .nativeFunction(LuauNativeFunction(name: "math.frexp") { _, _, args in
            guard let x = args.first?.coercedNumber else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'frexp'"))
            }
            let (m, e) = frexp(x)
            return .values([.number(m), .number(Double(e))])
        }))

        m.rawSet("random", value: .nativeFunction(LuauNativeFunction(name: "math.random") { _, _, args in
            if args.isEmpty {
                return .values([.number(Double.random(in: 0..<1))])
            } else if args.count == 1, let hi = args[0].asInt, hi >= 1 {
                return .values([.number(Double(Int.random(in: 1...hi)))])
            } else if args.count >= 2, let lo = args[0].asInt, let hi = args[1].asInt, lo <= hi {
                return .values([.number(Double(Int.random(in: lo...hi)))])
            }
            throw LuauRuntimeError(value: .string("bad arguments to 'math.random'"))
        }))

        m.rawSet("randomseed", value: .nativeFunction(LuauNativeFunction(name: "math.randomseed") { _, _, _ in
            return .values([])
        }))

        m.rawSet("noise", value: .nativeFunction(LuauNativeFunction(name: "math.noise") { _, _, args in
            let x = args.count > 0 ? (args[0].coercedNumber ?? 0) : 0
            let y = args.count > 1 ? (args[1].coercedNumber ?? 0) : 0
            let z = args.count > 2 ? (args[2].coercedNumber ?? 0) : 0
            // Deterministic smooth pseudo-noise
            let val = sin(x * 12.9898 + y * 78.233 + z * 37.719) * 43758.5453
            return .values([.number((val - floor(val)) * 2.0 - 1.0)])
        }))

        g.rawSet("math", value: .table(m))
    }

    // MARK: - string

    private static func installString(into g: LuauTable, vm: LuauVM) {
        let s = LuauTable()

        s.rawSet("len", value: .nativeFunction(LuauNativeFunction(name: "string.len") { _, _, args in
            guard case .string(let str) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'len' (string expected)"))
            }
            return .values([.number(Double(str.utf8.count))])
        }))

        s.rawSet("lower", value: .nativeFunction(LuauNativeFunction(name: "string.lower") { _, _, args in
            guard case .string(let str) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'lower' (string expected)"))
            }
            return .values([.string(str.lowercased())])
        }))

        s.rawSet("upper", value: .nativeFunction(LuauNativeFunction(name: "string.upper") { _, _, args in
            guard case .string(let str) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'upper' (string expected)"))
            }
            return .values([.string(str.uppercased())])
        }))

        s.rawSet("reverse", value: .nativeFunction(LuauNativeFunction(name: "string.reverse") { _, _, args in
            guard case .string(let str) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'reverse' (string expected)"))
            }
            return .values([.string(String(str.reversed()))])
        }))

        s.rawSet("rep", value: .nativeFunction(LuauNativeFunction(name: "string.rep") { vm, _, args in
            guard case .string(let str) = args.first, let n = args.dropFirst().first?.asInt else {
                throw LuauRuntimeError(value: .string("bad arguments to 'rep'"))
            }
            let sep = (args.count > 2 ? args[2].asString : nil) ?? ""
            if n <= 0 { return .values([.string("")]) }
            let estimated = n.multipliedReportingOverflow(by: max(1, str.utf8.count + sep.utf8.count))
            try vm.noteAllocation(estimated.overflow ? Int.max : estimated.partialValue)
            let out = Array(repeating: str, count: n).joined(separator: sep)
            return .values([.string(out)])
        }))

        s.rawSet("sub", value: .nativeFunction(LuauNativeFunction(name: "string.sub") { _, _, args in
            guard case .string(let str) = args.first, let iArg = args.dropFirst().first?.asInt else {
                throw LuauRuntimeError(value: .string("bad arguments to 'sub'"))
            }
            let bytes = Array(str.utf8)
            let len = bytes.count
            let jArg = args.count > 2 ? (args[2].asInt ?? len) : len
            let start = max(1, iArg < 0 ? len + iArg + 1 : iArg)
            let end = min(len, jArg < 0 ? len + jArg + 1 : jArg)
            if start > end || start > len || end < 1 {
                return .values([.string("")])
            }
            let sub = String(decoding: bytes[(start - 1)..<end], as: UTF8.self)
            return .values([.string(sub)])
        }))

        s.rawSet("byte", value: .nativeFunction(LuauNativeFunction(name: "string.byte") { _, _, args in
            guard case .string(let str) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'byte'"))
            }
            let bytes = Array(str.utf8)
            let len = bytes.count
            let iArg = args.count > 1 ? (args[1].asInt ?? 1) : 1
            let jArg = args.count > 2 ? (args[2].asInt ?? iArg) : iArg
            let start = max(1, iArg < 0 ? len + iArg + 1 : iArg)
            let end = min(len, jArg < 0 ? len + jArg + 1 : jArg)
            if start > end { return .values([]) }
            return .values((start...end).map { .number(Double(bytes[$0 - 1])) })
        }))

        s.rawSet("char", value: .nativeFunction(LuauNativeFunction(name: "string.char") { _, _, args in
            var bytes: [UInt8] = []
            for a in args {
                guard let n = a.asInt, n >= 0 && n <= 255 else {
                    throw LuauRuntimeError(value: .string("bad argument to 'char' (value out of range)"))
                }
                bytes.append(UInt8(n))
            }
            return .values([.string(String(decoding: bytes, as: UTF8.self))])
        }))

        s.rawSet("split", value: .nativeFunction(LuauNativeFunction(name: "string.split") { _, _, args in
            guard case .string(let str) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'split' (string expected)"))
            }
            let sep = (args.count > 1 ? args[1].asString : nil) ?? ","
            let result = LuauTable()
            if sep.isEmpty {
                for (i, ch) in str.enumerated() {
                    result.rawSet(i + 1, value: .string(String(ch)))
                }
            } else {
                let parts = str.components(separatedBy: sep)
                for (i, p) in parts.enumerated() {
                    result.rawSet(i + 1, value: .string(p))
                }
            }
            return .values([.table(result)])
        }))

        s.rawSet("find", value: .nativeFunction(LuauNativeFunction(name: "string.find") { _, _, args in
            guard case .string(let subj) = args.first,
                  let pat = args.dropFirst().first?.asString else {
                throw LuauRuntimeError(value: .string("bad arguments to 'string.find'"))
            }
            let len = subj.utf8.count
            let initArg = args.count > 2 ? (args[2].asInt ?? 1) : 1
            let start = max(0, (initArg < 0 ? len + initArg + 1 : initArg) - 1)
            let plain = args.count > 3 ? args[3].isTruthy : false
            guard let m = LuauPatternEngine.find(in: subj, pattern: pat, initPos: start, plain: plain) else {
                return .values([.nil])
            }
            var out: [LuauValue] = [.number(Double(m.start + 1)), .number(Double(m.end))]
            for cap in m.captures {
                out.append(.string(cap))
            }
            return .values(out)
        }))

        s.rawSet("match", value: .nativeFunction(LuauNativeFunction(name: "string.match") { _, _, args in
            guard case .string(let subj) = args.first,
                  let pat = args.dropFirst().first?.asString else {
                throw LuauRuntimeError(value: .string("bad arguments to 'string.match'"))
            }
            let len = subj.utf8.count
            let initArg = args.count > 2 ? (args[2].asInt ?? 1) : 1
            let start = max(0, (initArg < 0 ? len + initArg + 1 : initArg) - 1)
            guard let m = LuauPatternEngine.find(in: subj, pattern: pat, initPos: start, plain: false) else {
                return .values([.nil])
            }
            if m.captures.isEmpty {
                let bytes = Array(subj.utf8)
                return .values([.string(String(decoding: bytes[m.start..<m.end], as: UTF8.self))])
            }
            return .values(m.captures.map { .string($0) })
        }))

        s.rawSet("gmatch", value: .nativeFunction(LuauNativeFunction(name: "string.gmatch") { _, _, args in
            guard case .string(let subj) = args.first,
                  let pat = args.dropFirst().first?.asString else {
                throw LuauRuntimeError(value: .string("bad arguments to 'string.gmatch'"))
            }
            final class Cursor: @unchecked Sendable { var pos = 0 }
            let cursor = Cursor()
            let bytes = Array(subj.utf8)
            let iter = LuauNativeFunction(name: "gmatch_iter") { _, _, _ in
                guard cursor.pos <= bytes.count,
                      let m = LuauPatternEngine.find(in: subj, pattern: pat, initPos: cursor.pos, plain: false) else {
                    return .values([.nil])
                }
                cursor.pos = m.end == cursor.pos ? cursor.pos + 1 : m.end
                if m.captures.isEmpty {
                    return .values([.string(String(decoding: bytes[m.start..<m.end], as: UTF8.self))])
                }
                return .values(m.captures.map { .string($0) })
            }
            return .values([.nativeFunction(iter)])
        }))

        s.rawSet("gsub", value: .nativeFunction(LuauNativeFunction(name: "string.gsub") { vm, _, args in
            guard args.count >= 3,
                  case .string(let subj) = args[0],
                  case .string(let pat) = args[1] else {
                throw LuauRuntimeError(value: .string("bad arguments to 'string.gsub'"))
            }
            let repl = args[2]
            let maxN = args.count > 3 ? (args[3].asInt ?? Int.max) : Int.max
            let bytes = Array(subj.utf8)
            var outBytes: [UInt8] = []
            var pos = 0
            var count = 0

            while count < maxN && pos <= bytes.count {
                guard let m = LuauPatternEngine.find(in: subj, pattern: pat, initPos: pos, plain: false) else {
                    break
                }
                if m.start > pos {
                    outBytes.append(contentsOf: bytes[pos..<m.start])
                }
                let fullMatch = String(decoding: bytes[m.start..<m.end], as: UTF8.self)
                let repStr: String?
                switch repl {
                case .string(let template):
                    var built = ""
                    var ti = template.startIndex
                    while ti < template.endIndex {
                        if template[ti] == "%" {
                            let next = template.index(after: ti)
                            if next < template.endIndex {
                                let ch = template[next]
                                if ch == "%" {
                                    built.append("%")
                                } else if ch == "0" {
                                    built.append(fullMatch)
                                } else if let d = ch.wholeNumberValue, d >= 1 && d <= 9 {
                                    if d - 1 < m.captures.count {
                                        built.append(m.captures[d - 1])
                                    }
                                } else {
                                    built.append(ch)
                                }
                                ti = template.index(after: next)
                                continue
                            }
                        }
                        built.append(template[ti])
                        ti = template.index(after: ti)
                    }
                    repStr = built
                case .number(let n):
                    repStr = LuauValue.formatNumber(n)
                case .table(let t):
                    let key = m.captures.first ?? fullMatch
                    let val = t.rawGet(.string(key))
                    repStr = val.isTruthy ? val.displayString : nil
                case .closure, .nativeFunction:
                    let callArgs: [LuauValue] = m.captures.isEmpty ? [.string(fullMatch)] : m.captures.map { .string($0) }
                    let res = try vm.call(value: repl, args: callArgs).first ?? .nil
                    repStr = res.isTruthy ? res.displayString : nil
                default:
                    throw LuauRuntimeError(value: .string("bad argument #3 to 'gsub'"))
                }
                outBytes.append(contentsOf: (repStr ?? fullMatch).utf8)
                count += 1
                if m.end == pos {
                    if pos < bytes.count {
                        outBytes.append(bytes[pos])
                    }
                    pos += 1
                } else {
                    pos = m.end
                }
                if pat.hasPrefix("^") { break }
            }
            if pos < bytes.count {
                outBytes.append(contentsOf: bytes[pos...])
            }
            return .values([.string(String(decoding: outBytes, as: UTF8.self)), .number(Double(count))])
        }))

        s.rawSet("format", value: .nativeFunction(LuauNativeFunction(name: "string.format") { vm, _, args in
            guard case .string(let fmt) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'format' (string expected)"))
            }
            let out = try formatString(fmt, args: Array(args.dropFirst()), vm: vm)
            return .values([.string(out)])
        }))

        g.rawSet("string", value: .table(s))
        let smt = LuauTable()
        smt.rawSet("__index", value: .table(s))
        vm.setAppData(StringMetatableBox(smt))
    }

    private static func formatString(_ fmt: String, args: [LuauValue], vm: LuauVM) throws -> String {
        var out = ""
        var argIdx = 0
        let chars = Array(fmt)
        var i = 0
        while i < chars.count {
            if chars[i] != "%" {
                out.append(chars[i])
                i += 1
                continue
            }
            i += 1
            if i < chars.count && chars[i] == "%" {
                out.append("%")
                i += 1
                continue
            }
            var spec = "%"
            while i < chars.count && "-+ #0".contains(chars[i]) {
                spec.append(chars[i])
                i += 1
            }
            while i < chars.count && chars[i].isNumber {
                spec.append(chars[i])
                i += 1
            }
            if i < chars.count && chars[i] == "." {
                spec.append(".")
                i += 1
                while i < chars.count && chars[i].isNumber {
                    spec.append(chars[i])
                    i += 1
                }
            }
            guard i < chars.count else { break }
            let conv = chars[i]
            i += 1
            guard argIdx < args.count else {
                throw LuauRuntimeError(value: .string("bad argument #\(argIdx + 2) to 'format' (no value)"))
            }
            let val = args[argIdx]
            argIdx += 1

            switch conv {
            case "d", "i":
                guard let n = val.coercedNumber else { throw LuauRuntimeError(value: .string("number expected")) }
                out += String(format: spec + "lld", Int64(n))
            case "u", "x", "X", "o":
                guard let n = val.coercedNumber else { throw LuauRuntimeError(value: .string("number expected")) }
                out += String(format: spec + "ll" + String(conv), UInt64(bitPattern: Int64(n)))
            case "f", "e", "E", "g", "G":
                guard let n = val.coercedNumber else { throw LuauRuntimeError(value: .string("number expected")) }
                out += String(format: spec + String(conv), n)
            case "c":
                guard let n = val.coercedNumber else { throw LuauRuntimeError(value: .string("number expected")) }
                if let scalar = UnicodeScalar(UInt32(n) & 0xFF) {
                    out.unicodeScalars.append(scalar)
                }
            case "s":
                let str = try vm.valueToString(val)
                out += str
            case "q":
                let str = val.displayString
                let escaped = str
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "\\r")
                out += "\"\(escaped)\""
            default:
                out.append(conv)
            }
        }
        return out
    }

    // MARK: - table

    private static func installTable(into g: LuauTable, vm: LuauVM) {
        let t = LuauTable()

        t.rawSet("create", value: .nativeFunction(LuauNativeFunction(name: "table.create") { vm, _, args in
            let count = args.first?.asInt ?? 0
            let fill = args.count > 1 ? args[1] : .nil
            if count > 0 {
                let estimated = count.multipliedReportingOverflow(by: 32)
                try vm.noteAllocation(estimated.overflow ? Int.max : estimated.partialValue)
            }
            let tbl = LuauTable(arrayCapacity: max(0, count))
            if !fill.isNil && count > 0 {
                tbl.array = Array(repeating: fill, count: count)
            }
            return .values([.table(tbl)])
        }))

        t.rawSet("clone", value: .nativeFunction(LuauNativeFunction(name: "table.clone") { _, _, args in
            guard case .table(let tbl) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'clone' (table expected)"))
            }
            return .values([.table(tbl.clone())])
        }))

        t.rawSet("freeze", value: .nativeFunction(LuauNativeFunction(name: "table.freeze") { _, _, args in
            guard case .table(let tbl) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'freeze' (table expected)"))
            }
            tbl.isFrozen = true
            return .values([.table(tbl)])
        }))

        t.rawSet("isfrozen", value: .nativeFunction(LuauNativeFunction(name: "table.isfrozen") { _, _, args in
            guard case .table(let tbl) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'isfrozen' (table expected)"))
            }
            return .values([.bool(tbl.isFrozen)])
        }))

        t.rawSet("clear", value: .nativeFunction(LuauNativeFunction(name: "table.clear") { _, _, args in
            guard case .table(let tbl) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'clear' (table expected)"))
            }
            if tbl.isFrozen { throw LuauRuntimeError(value: .string("attempt to modify a readonly table")) }
            tbl.array.removeAll()
            tbl.hash.removeAll()
            tbl.keyObjects.removeAll()
            tbl.hashOrder.removeAll()
            return .values([])
        }))

        t.rawSet("insert", value: .nativeFunction(LuauNativeFunction(name: "table.insert") { _, _, args in
            guard case .table(let tbl) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'insert' (table expected)"))
            }
            if tbl.isFrozen { throw LuauRuntimeError(value: .string("attempt to modify a readonly table")) }
            if args.count == 2 {
                tbl.array.append(args[1])
            } else if args.count >= 3, let pos = args[1].asInt {
                let idx = max(0, min(pos - 1, tbl.array.count))
                tbl.array.insert(args[2], at: idx)
            } else {
                throw LuauRuntimeError(value: .string("bad arguments to 'table.insert'"))
            }
            return .values([])
        }))

        t.rawSet("remove", value: .nativeFunction(LuauNativeFunction(name: "table.remove") { _, _, args in
            guard case .table(let tbl) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'remove' (table expected)"))
            }
            if tbl.isFrozen { throw LuauRuntimeError(value: .string("attempt to modify a readonly table")) }
            let len = tbl.rawLength
            let pos = args.count > 1 ? (args[1].asInt ?? len) : len
            if pos < 1 || pos > len {
                return .values([.nil])
            }
            let removed = tbl.array.remove(at: pos - 1)
            return .values([removed])
        }))

        t.rawSet("find", value: .nativeFunction(LuauNativeFunction(name: "table.find") { _, _, args in
            guard case .table(let tbl) = args.first, args.count >= 2 else {
                throw LuauRuntimeError(value: .string("bad arguments to 'table.find'"))
            }
            let needle = args[1]
            let start = max(1, args.count > 2 ? (args[2].asInt ?? 1) : 1)
            if start <= tbl.array.count {
                for i in (start - 1)..<tbl.array.count {
                    if tbl.array[i] == needle {
                        return .values([.number(Double(i + 1))])
                    }
                }
            }
            return .values([.nil])
        }))

        t.rawSet("concat", value: .nativeFunction(LuauNativeFunction(name: "table.concat") { _, _, args in
            guard case .table(let tbl) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'concat' (table expected)"))
            }
            let sep = (args.count > 1 ? args[1].asString : nil) ?? ""
            let i = args.count > 2 ? (args[2].asInt ?? 1) : 1
            let j = args.count > 3 ? (args[3].asInt ?? tbl.rawLength) : tbl.rawLength
            if i > j { return .values([.string("")]) }
            var parts: [String] = []
            for idx in i...j {
                let v = tbl.rawGet(idx)
                switch v {
                case .string(let s): parts.append(s)
                case .number(let n): parts.append(LuauValue.formatNumber(n))
                default: throw LuauRuntimeError(value: .string("invalid value (\(v.typeName)) at index \(idx) in table for 'concat'"))
                }
            }
            return .values([.string(parts.joined(separator: sep))])
        }))

        t.rawSet("sort", value: .nativeFunction(LuauNativeFunction(name: "table.sort") { vm, _, args in
            guard case .table(let tbl) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'sort' (table expected)"))
            }
            if tbl.isFrozen { throw LuauRuntimeError(value: .string("attempt to modify a readonly table")) }
            let comp = args.count > 1 ? args[1] : .nil
            let len = tbl.rawLength
            if len <= 1 { return .values([]) }
            var slice = Array(tbl.array[0..<len])
            var sortError: LuauRuntimeError?
            slice.sort { a, b in
                if sortError != nil { return false }
                if !comp.isNil {
                    do {
                        return (try vm.call(value: comp, args: [a, b]).first ?? .nil).isTruthy
                    } catch let e as LuauRuntimeError {
                        sortError = e
                        return false
                    } catch {
                        return false
                    }
                } else {
                    switch (a, b) {
                    case (.number(let na), .number(let nb)): return na < nb
                    case (.string(let sa), .string(let sb)): return sa < sb
                    default:
                        sortError = LuauRuntimeError(value: .string("attempt to compare \(a.typeName) with \(b.typeName)"))
                        return false
                    }
                }
            }
            if let sortError { throw sortError }
            tbl.array.replaceSubrange(0..<len, with: slice)
            return .values([])
        }))

        t.rawSet("unpack", value: g.rawGet("unpack"))

        t.rawSet("pack", value: .nativeFunction(LuauNativeFunction(name: "table.pack") { _, _, args in
            let tbl = LuauTable(arrayCapacity: args.count)
            tbl.array = args
            tbl.rawSet("n", value: .number(Double(args.count)))
            return .values([.table(tbl)])
        }))

        t.rawSet("getn", value: .nativeFunction(LuauNativeFunction(name: "table.getn") { _, _, args in
            guard case .table(let tbl) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'getn' (table expected)"))
            }
            return .values([.number(Double(tbl.rawLength))])
        }))

        t.rawSet("maxn", value: .nativeFunction(LuauNativeFunction(name: "table.maxn") { _, _, args in
            guard case .table(let tbl) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'maxn' (table expected)"))
            }
            return .values([.number(Double(tbl.array.count))])
        }))

        t.rawSet("move", value: .nativeFunction(LuauNativeFunction(name: "table.move") { _, _, args in
            guard args.count >= 4,
                  case .table(let src) = args[0],
                  let f = args[1].asInt,
                  let e = args[2].asInt,
                  let tIdx = args[3].asInt else {
                throw LuauRuntimeError(value: .string("bad arguments to 'table.move'"))
            }
            let dst: LuauTable = (args.count > 4 ? args[4].asTable : nil) ?? src
            if dst.isFrozen { throw LuauRuntimeError(value: .string("attempt to modify a readonly table")) }
            if e >= f {
                let vals = (f...e).map { src.rawGet($0) }
                for (offset, v) in vals.enumerated() {
                    try dst.rawSet(.number(Double(tIdx + offset)), value: v)
                }
            }
            return .values([.table(dst)])
        }))

        g.rawSet("table", value: .table(t))
        _ = vm
    }

    // MARK: - bit32

    private static func installBit32(into g: LuauTable) {
        let b = LuauTable()
        @Sendable func u32(_ v: LuauValue) -> UInt32 {
            UInt32(truncatingIfNeeded: Int64(v.coercedNumber ?? 0))
        }
        b.rawSet("band", value: .nativeFunction(LuauNativeFunction(name: "bit32.band") { _, _, args in
            var acc: UInt32 = 0xFFFF_FFFF
            for a in args { acc &= u32(a) }
            return .values([.number(Double(acc))])
        }))
        b.rawSet("bor", value: .nativeFunction(LuauNativeFunction(name: "bit32.bor") { _, _, args in
            var acc: UInt32 = 0
            for a in args { acc |= u32(a) }
            return .values([.number(Double(acc))])
        }))
        b.rawSet("bxor", value: .nativeFunction(LuauNativeFunction(name: "bit32.bxor") { _, _, args in
            var acc: UInt32 = 0
            for a in args { acc ^= u32(a) }
            return .values([.number(Double(acc))])
        }))
        b.rawSet("bnot", value: .nativeFunction(LuauNativeFunction(name: "bit32.bnot") { _, _, args in
            return .values([.number(Double(~u32(args.first ?? .nil)))])
        }))
        b.rawSet("btest", value: .nativeFunction(LuauNativeFunction(name: "bit32.btest") { _, _, args in
            var acc: UInt32 = 0xFFFF_FFFF
            for a in args { acc &= u32(a) }
            return .values([.bool(acc != 0)])
        }))
        b.rawSet("lshift", value: .nativeFunction(LuauNativeFunction(name: "bit32.lshift") { _, _, args in
            let x = u32(args.first ?? .nil)
            let disp = args.count > 1 ? (args[1].asInt ?? 0) : 0
            let res: UInt32 = disp >= 0 ? (disp >= 32 ? 0 : x << disp) : (-disp >= 32 ? 0 : x >> (-disp))
            return .values([.number(Double(res))])
        }))
        b.rawSet("rshift", value: .nativeFunction(LuauNativeFunction(name: "bit32.rshift") { _, _, args in
            let x = u32(args.first ?? .nil)
            let disp = args.count > 1 ? (args[1].asInt ?? 0) : 0
            let res: UInt32 = disp >= 0 ? (disp >= 32 ? 0 : x >> disp) : (-disp >= 32 ? 0 : x << (-disp))
            return .values([.number(Double(res))])
        }))
        b.rawSet("arshift", value: .nativeFunction(LuauNativeFunction(name: "bit32.arshift") { _, _, args in
            let x = Int32(bitPattern: u32(args.first ?? .nil))
            let disp = args.count > 1 ? (args[1].asInt ?? 0) : 0
            let res: UInt32 = disp >= 0 ? UInt32(bitPattern: x >> min(disp, 31)) : UInt32(bitPattern: x << min(-disp, 31))
            return .values([.number(Double(res))])
        }))
        b.rawSet("lrotate", value: .nativeFunction(LuauNativeFunction(name: "bit32.lrotate") { _, _, args in
            let x = u32(args.first ?? .nil)
            let d = (args.count > 1 ? (args[1].asInt ?? 0) : 0) & 31
            return .values([.number(Double((x << d) | (x >> (32 - d))))])
        }))
        b.rawSet("rrotate", value: .nativeFunction(LuauNativeFunction(name: "bit32.rrotate") { _, _, args in
            let x = u32(args.first ?? .nil)
            let d = (args.count > 1 ? (args[1].asInt ?? 0) : 0) & 31
            return .values([.number(Double((x >> d) | (x << (32 - d))))])
        }))
        b.rawSet("countlz", value: .nativeFunction(LuauNativeFunction(name: "bit32.countlz") { _, _, args in
            return .values([.number(Double(u32(args.first ?? .nil).leadingZeroBitCount))])
        }))
        b.rawSet("countrz", value: .nativeFunction(LuauNativeFunction(name: "bit32.countrz") { _, _, args in
            return .values([.number(Double(u32(args.first ?? .nil).trailingZeroBitCount))])
        }))
        b.rawSet("extract", value: .nativeFunction(LuauNativeFunction(name: "bit32.extract") { _, _, args in
            let n = u32(args.first ?? .nil)
            let field = args.count > 1 ? (args[1].asInt ?? 0) : 0
            let width = args.count > 2 ? (args[2].asInt ?? 1) : 1
            let mask: UInt32 = width >= 32 ? 0xFFFF_FFFF : ((1 << width) - 1)
            return .values([.number(Double((n >> field) & mask))])
        }))
        b.rawSet("replace", value: .nativeFunction(LuauNativeFunction(name: "bit32.replace") { _, _, args in
            let n = u32(args.first ?? .nil)
            let v = u32(args.count > 1 ? args[1] : .nil)
            let field = args.count > 2 ? (args[2].asInt ?? 0) : 0
            let width = args.count > 3 ? (args[3].asInt ?? 1) : 1
            let mask: UInt32 = width >= 32 ? 0xFFFF_FFFF : ((1 << width) - 1)
            let res = (n & ~(mask << field)) | ((v & mask) << field)
            return .values([.number(Double(res))])
        }))
        g.rawSet("bit32", value: .table(b))
    }

    // MARK: - utf8

    private static func installUtf8(into g: LuauTable) {
        let u = LuauTable()
        u.rawSet("charpattern", value: .string("[\0-\u{7F}\u{C2}-\u{F4}][\u{80}-\u{BF}]*"))
        u.rawSet("char", value: .nativeFunction(LuauNativeFunction(name: "utf8.char") { _, _, args in
            var out = ""
            for a in args {
                guard let cp = a.asInt, let scalar = UnicodeScalar(cp) else {
                    throw LuauRuntimeError(value: .string("bad argument to 'utf8.char'"))
                }
                out.unicodeScalars.append(scalar)
            }
            return .values([.string(out)])
        }))
        u.rawSet("len", value: .nativeFunction(LuauNativeFunction(name: "utf8.len") { _, _, args in
            guard case .string(let s) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'utf8.len'"))
            }
            return .values([.number(Double(s.unicodeScalars.count))])
        }))
        u.rawSet("codepoint", value: .nativeFunction(LuauNativeFunction(name: "utf8.codepoint") { _, _, args in
            guard case .string(let s) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'utf8.codepoint'"))
            }
            let scalars = Array(s.unicodeScalars)
            if scalars.isEmpty { return .values([]) }
            return .values([.number(Double(scalars[0].value))])
        }))
        u.rawSet("codes", value: .nativeFunction(LuauNativeFunction(name: "utf8.codes") { _, _, args in
            guard case .string(let s) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'utf8.codes'"))
            }
            let scalars = Array(s.unicodeScalars)
            final class Cursor: @unchecked Sendable { var idx = 0; var bytePos = 1 }
            let cur = Cursor()
            let iter = LuauNativeFunction(name: "utf8_codes_iter") { _, _, _ in
                if cur.idx >= scalars.count { return .values([.nil]) }
                let sc = scalars[cur.idx]
                let pos = cur.bytePos
                cur.idx += 1
                cur.bytePos += sc.utf8.count
                return .values([.number(Double(pos)), .number(Double(sc.value))])
            }
            return .values([.nativeFunction(iter)])
        }))
        g.rawSet("utf8", value: .table(u))
    }

    // MARK: - os

    private static func installOS(into g: LuauTable) {
        let o = LuauTable()
        let start = ContinuousClock.now
        o.rawSet("clock", value: .nativeFunction(LuauNativeFunction(name: "os.clock") { _, _, _ in
            let elapsed = start.duration(to: .now)
            let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
            return .values([.number(secs)])
        }))
        o.rawSet("time", value: .nativeFunction(LuauNativeFunction(name: "os.time") { _, _, _ in
            return .values([.number(floor(Date().timeIntervalSince1970))])
        }))
        o.rawSet("difftime", value: .nativeFunction(LuauNativeFunction(name: "os.difftime") { _, _, args in
            let t2 = args.count > 0 ? (args[0].coercedNumber ?? 0) : 0
            let t1 = args.count > 1 ? (args[1].coercedNumber ?? 0) : 0
            return .values([.number(t2 - t1)])
        }))
        g.rawSet("os", value: .table(o))
    }

    // MARK: - coroutine

    private static func installCoroutine(into g: LuauTable) {
        let c = LuauTable()

        c.rawSet("create", value: .nativeFunction(LuauNativeFunction(name: "coroutine.create") { vm, _, args in
            guard case .closure(let cl) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'coroutine.create' (function expected)"))
            }
            return .values([.thread(vm.createThread(closure: cl))])
        }))

        c.rawSet("resume", value: .nativeFunction(LuauNativeFunction(name: "coroutine.resume") { vm, _, args in
            guard case .thread(let th) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'coroutine.resume' (thread expected)"))
            }
            do {
                let res = try vm.resume(thread: th, args: Array(args.dropFirst()))
                switch res {
                case .returned(let vals): return .values([.bool(true)] + vals)
                case .yielded(let vals): return .values([.bool(true)] + vals)
                }
            } catch let err as LuauRuntimeError {
                if err.isTimeout { throw err }
                return .values([.bool(false), err.value])
            }
        }))

        c.rawSet("yield", value: .nativeFunction(LuauNativeFunction(name: "coroutine.yield") { _, _, args in
            return .yield(args)
        }))

        c.rawSet("status", value: .nativeFunction(LuauNativeFunction(name: "coroutine.status") { _, _, args in
            guard case .thread(let th) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'coroutine.status' (thread expected)"))
            }
            return .values([.string(th.status.rawValue)])
        }))

        c.rawSet("running", value: .nativeFunction(LuauNativeFunction(name: "coroutine.running") { vm, thread, _ in
            return .values([.thread(thread), .bool(thread === vm.mainThread)])
        }))

        c.rawSet("isyieldable", value: .nativeFunction(LuauNativeFunction(name: "coroutine.isyieldable") { vm, thread, _ in
            return .values([.bool(thread !== vm.mainThread)])
        }))

        c.rawSet("close", value: .nativeFunction(LuauNativeFunction(name: "coroutine.close") { _, _, args in
            guard case .thread(let th) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'coroutine.close' (thread expected)"))
            }
            if th.status == .suspended {
                th.closeUpvalues(fromStackIndex: 0)
                th.frames.removeAll()
                th.stack.removeAll()
                th.status = .dead
            }
            return .values([.bool(true)])
        }))

        c.rawSet("wrap", value: .nativeFunction(LuauNativeFunction(name: "coroutine.wrap") { vm, _, args in
            guard case .closure(let cl) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'coroutine.wrap' (function expected)"))
            }
            let th = vm.createThread(closure: cl)
            let wrapper = LuauNativeFunction(name: "coroutine.wrap") { vm, _, callArgs in
                let res = try vm.resume(thread: th, args: callArgs)
                switch res {
                case .returned(let vals), .yielded(let vals):
                    return .values(vals)
                }
            }
            return .values([.nativeFunction(wrapper)])
        }))

        g.rawSet("coroutine", value: .table(c))
    }

    // MARK: - debug

    private static func installDebug(into g: LuauTable) {
        let d = LuauTable()
        d.rawSet("traceback", value: .nativeFunction(LuauNativeFunction(name: "debug.traceback") { _, thread, args in
            let msg = args.first?.displayString ?? ""
            var lines: [String] = []
            if !msg.isEmpty { lines.append(msg) }
            lines.append("stack traceback:")
            for frame in thread.frames.reversed() {
                let pc = max(0, frame.pc - 1)
                let line = pc < frame.closure.proto.code.count ? frame.closure.proto.code[pc].line : 0
                lines.append("\t\(frame.closure.proto.sourceName):\(line): in function '\(frame.closure.proto.name)'")
            }
            return .values([.string(lines.joined(separator: "\n"))])
        }))
        g.rawSet("debug", value: .table(d))
    }

    // MARK: - vector

    private static func installVector(into g: LuauTable) {
        let v = LuauTable()
        v.rawSet("create", value: .nativeFunction(LuauNativeFunction(name: "vector.create") { _, _, args in
            let x = args.count > 0 ? (args[0].coercedNumber ?? 0) : 0
            let y = args.count > 1 ? (args[1].coercedNumber ?? 0) : 0
            let z = args.count > 2 ? (args[2].coercedNumber ?? 0) : 0
            return .values([.vector(SIMD3<Double>(x, y, z))])
        }))
        v.rawSet("zero", value: .vector(.zero))
        v.rawSet("one", value: .vector(SIMD3<Double>(1, 1, 1)))
        g.rawSet("vector", value: .table(v))
    }
}
