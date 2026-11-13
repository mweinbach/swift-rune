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
        installBuffer(into: g, vm: vm)
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
            case .byteString(let b): return .values([.number(Double(b.count))])
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
            guard let bytes = args.first?.stringBytes else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'loadstring' (string expected)"))
            }
            let src = String(decoding: bytes, as: UTF8.self)
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

        g.rawSet("gcinfo", value: .nativeFunction(LuauNativeFunction(name: "gcinfo") { vm, _, _ in
            return .values([.number(Double(vm.estimatedMemoryBytes()) / 1024.0)])
        }))

        g.rawSet("collectgarbage", value: .nativeFunction(LuauNativeFunction(name: "collectgarbage") { vm, _, args in
            let opt = (args.first?.isNil == false ? args.first?.asString : nil) ?? "collect"
            switch opt {
            case "count":
                return .values([.number(Double(vm.estimatedMemoryBytes()) / 1024.0)])
            case "isrunning":
                return .values([.bool(true)])
            case "collect", "stop", "restart", "step", "setpause", "setstepmul":
                return .values([.number(0)])
            default:
                throw LuauRuntimeError(value: .string("invalid option '\(opt)' to 'collectgarbage'"))
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

        m.rawSet("lerp", value: .nativeFunction(LuauNativeFunction(name: "math.lerp") { _, _, args in
            let a = args.count > 0 ? (args[0].coercedNumber ?? 0) : 0
            let b = args.count > 1 ? (args[1].coercedNumber ?? 0) : 0
            let t = args.count > 2 ? (args[2].coercedNumber ?? 0) : 0
            return .values([.number(a + (b - a) * t)])
        }))

        m.rawSet("map", value: .nativeFunction(LuauNativeFunction(name: "math.map") { _, _, args in
            let x = args.count > 0 ? (args[0].coercedNumber ?? 0) : 0
            let inMin = args.count > 1 ? (args[1].coercedNumber ?? 0) : 0
            let inMax = args.count > 2 ? (args[2].coercedNumber ?? 1) : 1
            let outMin = args.count > 3 ? (args[3].coercedNumber ?? 0) : 0
            let outMax = args.count > 4 ? (args[4].coercedNumber ?? 1) : 1
            return .values([.number(outMin + (x - inMin) * (outMax - outMin) / (inMax - inMin))])
        }))

        m.rawSet("isnan", value: .nativeFunction(LuauNativeFunction(name: "math.isnan") { _, _, args in
            .values([.bool(args.first?.coercedNumber?.isNaN ?? false)])
        }))

        m.rawSet("isinf", value: .nativeFunction(LuauNativeFunction(name: "math.isinf") { _, _, args in
            .values([.bool(args.first?.coercedNumber?.isInfinite ?? false)])
        }))

        m.rawSet("isfinite", value: .nativeFunction(LuauNativeFunction(name: "math.isfinite") { _, _, args in
            .values([.bool(args.first?.coercedNumber?.isFinite ?? false)])
        }))

        g.rawSet("math", value: .table(m))
    }

    // MARK: - string

    private static func installString(into g: LuauTable, vm: LuauVM) {
        let s = LuauTable()

        s.rawSet("len", value: .nativeFunction(LuauNativeFunction(name: "string.len") { _, _, args in
            guard let bytes = args.first?.stringBytes else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'len' (string expected)"))
            }
            return .values([.number(Double(bytes.count))])
        }))

        s.rawSet("lower", value: .nativeFunction(LuauNativeFunction(name: "string.lower") { _, _, args in
            guard let bytes = args.first?.stringBytes else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'lower' (string expected)"))
            }
            let out = bytes.map { ($0 >= 65 && $0 <= 90) ? ($0 + 32) : $0 }
            return .values([LuauValue.fromBytes(out)])
        }))

        s.rawSet("upper", value: .nativeFunction(LuauNativeFunction(name: "string.upper") { _, _, args in
            guard let bytes = args.first?.stringBytes else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'upper' (string expected)"))
            }
            let out = bytes.map { ($0 >= 97 && $0 <= 122) ? ($0 - 32) : $0 }
            return .values([LuauValue.fromBytes(out)])
        }))

        s.rawSet("reverse", value: .nativeFunction(LuauNativeFunction(name: "string.reverse") { _, _, args in
            guard let bytes = args.first?.stringBytes else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'reverse' (string expected)"))
            }
            return .values([LuauValue.fromBytes(Array(bytes.reversed()))])
        }))

        s.rawSet("rep", value: .nativeFunction(LuauNativeFunction(name: "string.rep") { vm, _, args in
            guard let bytes = args.first?.stringBytes, let n = args.dropFirst().first?.asInt else {
                throw LuauRuntimeError(value: .string("bad arguments to 'rep'"))
            }
            let sepBytes = (args.count > 2 ? args[2].stringBytes : nil) ?? []
            if n <= 0 { return .values([.string("")]) }
            let estimated = n.multipliedReportingOverflow(by: max(1, bytes.count + sepBytes.count))
            try vm.noteAllocation(estimated.overflow ? Int.max : estimated.partialValue)
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count * n + sepBytes.count * max(0, n - 1))
            for idx in 0..<n {
                if idx > 0 && !sepBytes.isEmpty { out.append(contentsOf: sepBytes) }
                out.append(contentsOf: bytes)
            }
            return .values([LuauValue.fromBytes(out)])
        }))

        s.rawSet("sub", value: .nativeFunction(LuauNativeFunction(name: "string.sub") { _, _, args in
            guard let bytes = args.first?.stringBytes, let iArg = args.dropFirst().first?.asInt else {
                throw LuauRuntimeError(value: .string("bad arguments to 'sub'"))
            }
            let len = bytes.count
            let jArg = args.count > 2 ? (args[2].asInt ?? len) : len
            let start = max(1, iArg < 0 ? len + iArg + 1 : iArg)
            let end = min(len, jArg < 0 ? len + jArg + 1 : jArg)
            if start > end || start > len || end < 1 {
                return .values([.string("")])
            }
            return .values([LuauValue.fromBytes(Array(bytes[(start - 1)..<end]))])
        }))

        s.rawSet("byte", value: .nativeFunction(LuauNativeFunction(name: "string.byte") { _, _, args in
            guard let bytes = args.first?.stringBytes else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'byte'"))
            }
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
            bytes.reserveCapacity(args.count)
            for a in args {
                guard let n = a.asInt, n >= 0 && n <= 255 else {
                    throw LuauRuntimeError(value: .string("bad argument to 'char' (value out of range)"))
                }
                bytes.append(UInt8(n))
            }
            return .values([LuauValue.fromBytes(bytes)])
        }))

        s.rawSet("split", value: .nativeFunction(LuauNativeFunction(name: "string.split") { _, _, args in
            guard let sBytes = args.first?.stringBytes else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'split' (string expected)"))
            }
            let sepBytes = (args.count > 1 ? args[1].stringBytes : nil) ?? Array(",".utf8)
            let result = LuauTable()
            if sepBytes.isEmpty {
                for (i, b) in sBytes.enumerated() {
                    result.rawSet(i + 1, value: LuauValue.fromBytes([b]))
                }
            } else {
                var idx = 1
                var cursor = 0
                while cursor <= sBytes.count - sepBytes.count {
                    if sBytes[cursor..<(cursor + sepBytes.count)].elementsEqual(sepBytes) {
                        result.rawSet(idx, value: LuauValue.fromBytes(Array(sBytes[cursor..<cursor])))
                        idx += 1
                        cursor += sepBytes.count
                        continue
                    }
                    var nextMatch: Int?
                    var scan = cursor + 1
                    while scan <= sBytes.count - sepBytes.count {
                        if sBytes[scan..<(scan + sepBytes.count)].elementsEqual(sepBytes) {
                            nextMatch = scan
                            break
                        }
                        scan += 1
                    }
                    if let m = nextMatch {
                        result.rawSet(idx, value: LuauValue.fromBytes(Array(sBytes[cursor..<m])))
                        idx += 1
                        cursor = m + sepBytes.count
                    } else {
                        break
                    }
                }
                result.rawSet(idx, value: LuauValue.fromBytes(Array(sBytes[cursor...])))
            }
            return .values([.table(result)])
        }))

        s.rawSet("find", value: .nativeFunction(LuauNativeFunction(name: "string.find") { _, _, args in
            guard let sBytes = args.first?.stringBytes,
                  let pBytes = args.dropFirst().first?.stringBytes else {
                throw LuauRuntimeError(value: .string("bad arguments to 'string.find'"))
            }
            let len = sBytes.count
            let initArg = args.count > 2 ? (args[2].asInt ?? 1) : 1
            let start = max(0, (initArg < 0 ? len + initArg + 1 : initArg) - 1)
            let plain = args.count > 3 ? args[3].isTruthy : false
            guard let m = LuauPatternEngine.find(inBytes: sBytes, patternBytes: pBytes, initPos: start, plain: plain) else {
                return .values([.nil])
            }
            var out: [LuauValue] = [.number(Double(m.start + 1)), .number(Double(m.end))]
            for (idx, span) in m.captureSpans.enumerated() {
                switch span {
                case .position(let pos): out.append(.number(Double(pos + 1)))
                case .span: out.append(LuauValue.fromBytes(m.captureBytes[idx]))
                }
            }
            return .values(out)
        }))

        s.rawSet("match", value: .nativeFunction(LuauNativeFunction(name: "string.match") { _, _, args in
            guard let sBytes = args.first?.stringBytes,
                  let pBytes = args.dropFirst().first?.stringBytes else {
                throw LuauRuntimeError(value: .string("bad arguments to 'string.match'"))
            }
            let len = sBytes.count
            let initArg = args.count > 2 ? (args[2].asInt ?? 1) : 1
            let start = max(0, (initArg < 0 ? len + initArg + 1 : initArg) - 1)
            guard let m = LuauPatternEngine.find(inBytes: sBytes, patternBytes: pBytes, initPos: start, plain: false) else {
                return .values([.nil])
            }
            if m.captureSpans.isEmpty {
                return .values([LuauValue.fromBytes(Array(sBytes[m.start..<m.end]))])
            }
            return .values(m.captureSpans.enumerated().map { idx, span in
                switch span {
                case .position(let pos): return .number(Double(pos + 1))
                case .span: return LuauValue.fromBytes(m.captureBytes[idx])
                }
            })
        }))

        s.rawSet("gmatch", value: .nativeFunction(LuauNativeFunction(name: "string.gmatch") { _, _, args in
            guard let sBytes = args.first?.stringBytes,
                  let pBytes = args.dropFirst().first?.stringBytes else {
                throw LuauRuntimeError(value: .string("bad arguments to 'string.gmatch'"))
            }
            final class Cursor: @unchecked Sendable { var pos = 0 }
            let cursor = Cursor()
            let iter = LuauNativeFunction(name: "gmatch_iter") { _, _, _ in
                guard cursor.pos <= sBytes.count,
                      let m = LuauPatternEngine.find(inBytes: sBytes, patternBytes: pBytes, initPos: cursor.pos, plain: false) else {
                    return .values([.nil])
                }
                cursor.pos = m.end == cursor.pos ? cursor.pos + 1 : m.end
                if m.captureSpans.isEmpty {
                    return .values([LuauValue.fromBytes(Array(sBytes[m.start..<m.end]))])
                }
                return .values(m.captureSpans.enumerated().map { idx, span in
                    switch span {
                    case .position(let pos): return .number(Double(pos + 1))
                    case .span: return LuauValue.fromBytes(m.captureBytes[idx])
                    }
                })
            }
            return .values([.nativeFunction(iter)])
        }))

        s.rawSet("gsub", value: .nativeFunction(LuauNativeFunction(name: "string.gsub") { vm, _, args in
            guard args.count >= 3,
                  let bytes = args[0].stringBytes,
                  let pBytes = args[1].stringBytes else {
                throw LuauRuntimeError(value: .string("bad arguments to 'string.gsub'"))
            }
            let repl = args[2]
            let maxN = args.count > 3 ? (args[3].asInt ?? Int.max) : Int.max
            var outBytes: [UInt8] = []
            var pos = 0
            var count = 0
            let anchored = pBytes.first == UInt8(ascii: "^")

            while count < maxN && pos <= bytes.count {
                guard let m = LuauPatternEngine.find(inBytes: bytes, patternBytes: pBytes, initPos: pos, plain: false) else {
                    break
                }
                if m.start > pos {
                    outBytes.append(contentsOf: bytes[pos..<m.start])
                }
                let fullMatchBytes = Array(bytes[m.start..<m.end])
                let repBytes: [UInt8]?
                switch repl {
                case .string, .byteString:
                    let tBytes = repl.stringBytes ?? []
                    var built: [UInt8] = []
                    var ti = 0
                    while ti < tBytes.count {
                        if tBytes[ti] == UInt8(ascii: "%") && ti + 1 < tBytes.count {
                            let ch = tBytes[ti + 1]
                            if ch == UInt8(ascii: "%") {
                                built.append(UInt8(ascii: "%"))
                            } else if ch == UInt8(ascii: "0") {
                                built.append(contentsOf: fullMatchBytes)
                            } else if ch >= UInt8(ascii: "1") && ch <= UInt8(ascii: "9") {
                                let d = Int(ch - UInt8(ascii: "0"))
                                if d - 1 < m.captureBytes.count {
                                    built.append(contentsOf: m.captureBytes[d - 1])
                                }
                            } else {
                                built.append(ch)
                            }
                            ti += 2
                            continue
                        }
                        built.append(tBytes[ti])
                        ti += 1
                    }
                    repBytes = built
                case .number(let n):
                    repBytes = Array(LuauValue.formatNumber(n).utf8)
                case .table(let t):
                    let keyVal: LuauValue = if m.captureSpans.isEmpty {
                        LuauValue.fromBytes(fullMatchBytes)
                    } else if case .position(let p) = m.captureSpans[0] {
                        .number(Double(p + 1))
                    } else {
                        LuauValue.fromBytes(m.captureBytes[0])
                    }
                    let val = t.rawGet(keyVal)
                    repBytes = val.isTruthy ? (val.stringBytes ?? Array(val.displayString.utf8)) : nil
                case .closure, .nativeFunction:
                    let callArgs: [LuauValue] = if m.captureSpans.isEmpty {
                        [LuauValue.fromBytes(fullMatchBytes)]
                    } else {
                        m.captureSpans.enumerated().map { idx, span in
                            switch span {
                            case .position(let pos): return .number(Double(pos + 1))
                            case .span: return LuauValue.fromBytes(m.captureBytes[idx])
                            }
                        }
                    }
                    let res = try vm.call(value: repl, args: callArgs).first ?? .nil
                    repBytes = res.isTruthy ? (res.stringBytes ?? Array(res.displayString.utf8)) : nil
                default:
                    throw LuauRuntimeError(value: .string("bad argument #3 to 'gsub'"))
                }
                outBytes.append(contentsOf: repBytes ?? fullMatchBytes)
                count += 1
                if m.end == pos {
                    if pos < bytes.count {
                        outBytes.append(bytes[pos])
                    }
                    pos += 1
                } else {
                    pos = m.end
                }
                if anchored { break }
            }
            if pos < bytes.count {
                outBytes.append(contentsOf: bytes[pos...])
            }
            return .values([LuauValue.fromBytes(outBytes), .number(Double(count))])
        }))

        s.rawSet("format", value: .nativeFunction(LuauNativeFunction(name: "string.format") { vm, _, args in
            guard let fmtBytes = args.first?.stringBytes else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'format' (string expected)"))
            }
            let out = try formatStringBytes(fmtBytes, args: Array(args.dropFirst()), vm: vm)
            return .values([LuauValue.fromBytes(out)])
        }))

        s.rawSet("pack", value: .nativeFunction(LuauNativeFunction(name: "string.pack") { _, _, args in
            guard let fmt = args.first?.asString else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'pack' (string expected)"))
            }
            let packed = try packBinary(fmt: fmt, args: Array(args.dropFirst()))
            return .values([LuauValue.fromBytes(packed)])
        }))

        s.rawSet("unpack", value: .nativeFunction(LuauNativeFunction(name: "string.unpack") { _, _, args in
            guard let fmt = args.first?.asString,
                  let bytes = args.dropFirst().first?.stringBytes else {
                throw LuauRuntimeError(value: .string("bad arguments to 'string.unpack'"))
            }
            let posArg = args.count > 2 ? (args[2].asInt ?? 1) : 1
            let startIdx = (posArg < 0 ? bytes.count + posArg + 1 : posArg) - 1
            guard startIdx >= 0 && startIdx <= bytes.count else {
                throw LuauRuntimeError(value: .string("bad argument #3 to 'unpack' (initial position out of string)"))
            }
            let (values, nextIdx) = try unpackBinary(fmt: fmt, bytes: bytes, initPos: startIdx)
            return .values(values + [.number(Double(nextIdx + 1))])
        }))

        s.rawSet("packsize", value: .nativeFunction(LuauNativeFunction(name: "string.packsize") { _, _, args in
            guard let fmt = args.first?.asString else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'packsize' (string expected)"))
            }
            let size = try packSizeBinary(fmt: fmt)
            return .values([.number(Double(size))])
        }))

        g.rawSet("string", value: .table(s))
        let smt = LuauTable()
        smt.rawSet("__index", value: .table(s))
        vm.setAppData(StringMetatableBox(smt))
    }

    private static func formatStringBytes(_ fmtBytes: [UInt8], args: [LuauValue], vm: LuauVM) throws -> [UInt8] {
        var out: [UInt8] = []
        var argIdx = 0
        var i = 0
        while i < fmtBytes.count {
            if fmtBytes[i] != UInt8(ascii: "%") {
                out.append(fmtBytes[i])
                i += 1
                continue
            }
            i += 1
            if i < fmtBytes.count && fmtBytes[i] == UInt8(ascii: "%") {
                out.append(UInt8(ascii: "%"))
                i += 1
                continue
            }
            var spec = "%"
            while i < fmtBytes.count && [UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: " "), UInt8(ascii: "#"), UInt8(ascii: "0")].contains(fmtBytes[i]) {
                spec.append(Character(UnicodeScalar(fmtBytes[i])))
                i += 1
            }
            while i < fmtBytes.count && fmtBytes[i] >= UInt8(ascii: "0") && fmtBytes[i] <= UInt8(ascii: "9") {
                spec.append(Character(UnicodeScalar(fmtBytes[i])))
                i += 1
            }
            if i < fmtBytes.count && fmtBytes[i] == UInt8(ascii: ".") {
                spec.append(".")
                i += 1
                while i < fmtBytes.count && fmtBytes[i] >= UInt8(ascii: "0") && fmtBytes[i] <= UInt8(ascii: "9") {
                    spec.append(Character(UnicodeScalar(fmtBytes[i])))
                    i += 1
                }
            }
            guard i < fmtBytes.count else { break }
            let conv = Character(UnicodeScalar(fmtBytes[i]))
            i += 1
            guard argIdx < args.count else {
                throw LuauRuntimeError(value: .string("bad argument #\(argIdx + 2) to 'format' (no value)"))
            }
            let val = args[argIdx]
            argIdx += 1

            switch conv {
            case "d", "i":
                guard let n = val.coercedNumber else { throw LuauRuntimeError(value: .string("number expected")) }
                out.append(contentsOf: String(format: spec + "lld", Int64(n)).utf8)
            case "u", "x", "X", "o":
                guard let n = val.coercedNumber else { throw LuauRuntimeError(value: .string("number expected")) }
                out.append(contentsOf: String(format: spec + "ll" + String(conv), UInt64(bitPattern: Int64(n))).utf8)
            case "f", "e", "E", "g", "G":
                guard let n = val.coercedNumber else { throw LuauRuntimeError(value: .string("number expected")) }
                out.append(contentsOf: String(format: spec + String(conv), n).utf8)
            case "c":
                guard let n = val.coercedNumber else { throw LuauRuntimeError(value: .string("number expected")) }
                out.append(UInt8(truncatingIfNeeded: Int64(n)))
            case "s":
                if vm.getMetamethod(of: val, name: "__tostring") == nil, let rawBytes = val.stringBytes {
                    if spec == "%" {
                        out.append(contentsOf: rawBytes)
                    } else {
                        let s = String(decoding: rawBytes, as: UTF8.self)
                        out.append(contentsOf: (s as NSString).utf8String.map { String(format: spec + "s", $0) }?.utf8 ?? s.utf8)
                    }
                } else {
                    let str = try vm.valueToString(val)
                    out.append(contentsOf: str.utf8)
                }
            case "q":
                let rawBytes = val.stringBytes ?? Array(val.displayString.utf8)
                out.append(UInt8(ascii: "\""))
                for b in rawBytes {
                    switch b {
                    case UInt8(ascii: "\\"): out.append(contentsOf: "\\\\".utf8)
                    case UInt8(ascii: "\""): out.append(contentsOf: "\\\"".utf8)
                    case UInt8(ascii: "\n"): out.append(contentsOf: "\\n".utf8)
                    case UInt8(ascii: "\r"): out.append(contentsOf: "\\r".utf8)
                    case 0..<32, 127: out.append(contentsOf: "\\\(b)".utf8)
                    default: out.append(b)
                    }
                }
                out.append(UInt8(ascii: "\""))
            default:
                out.append(contentsOf: String(conv).utf8)
            }
        }
        return out
    }

    private enum PackEndian { case little, big, native }

    private enum PackOp {
        case padding(Int)
        case fixedString(Int)
        case cString
        case lengthString(Int)
        case signedInt(Int)
        case unsignedInt(Int)
        case float32
        case float64
        case alignOnly(Int)
    }

    private static func parsePackFormat(_ fmt: String) throws -> [(PackOp, PackEndian, Int)] {
        let chars = Array(fmt)
        var i = 0
        var endian: PackEndian = .little
        var maxAlign = 1
        var ops: [(PackOp, PackEndian, Int)] = []

        func readNum(defaultVal: Int? = nil) throws -> Int {
            var n = 0
            var any = false
            while i < chars.count && chars[i].isNumber {
                any = true
                n = n * 10 + Int(String(chars[i]))!
                i += 1
            }
            if !any {
                if let d = defaultVal { return d }
                throw LuauRuntimeError(value: .string("invalid format option in pack format"))
            }
            return n
        }

        func parseSingleOp() throws -> (PackOp, Int) {
            guard i < chars.count else {
                throw LuauRuntimeError(value: .string("invalid format option 'X'"))
            }
            let ch = chars[i]
            i += 1
            switch ch {
            case "b": return (.signedInt(1), 1)
            case "B": return (.unsignedInt(1), 1)
            case "h": return (.signedInt(2), 2)
            case "H": return (.unsignedInt(2), 2)
            case "l", "j": return (.signedInt(8), 8)
            case "L", "J", "T": return (.unsignedInt(8), 8)
            case "i":
                let sz = try readNum(defaultVal: 4)
                guard sz >= 1 && sz <= 16 else { throw LuauRuntimeError(value: .string("integral size (\(sz)) out of limits [1,16]")) }
                return (.signedInt(sz), sz)
            case "I":
                let sz = try readNum(defaultVal: 4)
                guard sz >= 1 && sz <= 16 else { throw LuauRuntimeError(value: .string("integral size (\(sz)) out of limits [1,16]")) }
                return (.unsignedInt(sz), sz)
            case "f": return (.float32, 4)
            case "d", "n": return (.float64, 8)
            case "c":
                let sz = try readNum()
                return (.fixedString(sz), 1)
            case "z": return (.cString, 1)
            case "s":
                let sz = try readNum(defaultVal: 8)
                guard sz >= 1 && sz <= 16 else { throw LuauRuntimeError(value: .string("integral size (\(sz)) out of limits [1,16]")) }
                return (.lengthString(sz), sz)
            case "x": return (.padding(1), 1)
            default:
                throw LuauRuntimeError(value: .string("invalid format option '\(ch)'"))
            }
        }

        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case " ": i += 1
            case "<": endian = .little; i += 1
            case ">": endian = .big; i += 1
            case "=": endian = .native; i += 1
            case "!":
                i += 1
                let a = try readNum(defaultVal: 8)
                guard a >= 1 && a <= 16 && (a & (a - 1)) == 0 else {
                    throw LuauRuntimeError(value: .string("alignment must be a power of 2 in [1, 16]"))
                }
                maxAlign = a
            case "X":
                i += 1
                let (_, naturalAlign) = try parseSingleOp()
                let align = min(naturalAlign, maxAlign)
                ops.append((.alignOnly(align), endian, align))
            default:
                let (op, naturalAlign) = try parseSingleOp()
                let align = min(naturalAlign, maxAlign)
                ops.append((op, endian, align))
            }
        }
        return ops
    }

    private static func isLittleEndian(_ e: PackEndian) -> Bool {
        switch e {
        case .little: return true
        case .big: return false
        case .native: return Int(littleEndian: 1) == 1
        }
    }

    private static func packIntBytes(_ value: Int64, size: Int, signed: Bool, little: Bool) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        if signed {
            if size < 8 {
                let bits = size * 8
                let minVal = -(Int64(1) << (bits - 1))
                let maxVal = (Int64(1) << (bits - 1)) - 1
                if value < minVal || value > maxVal {
                    throw LuauRuntimeError(value: .string("integer overflow in 'string.pack'"))
                }
            }
            var u = UInt64(bitPattern: value)
            let fill: UInt8 = value < 0 ? 0xFF : 0x00
            for idx in 0..<size {
                let byte = idx < 8 ? UInt8(u & 0xFF) : fill
                if idx < 8 { u >>= 8 }
                bytes[little ? idx : (size - 1 - idx)] = byte
            }
        } else {
            if value < 0 {
                throw LuauRuntimeError(value: .string("unsigned overflow in 'string.pack'"))
            }
            var u = UInt64(value)
            if size < 8 {
                let maxVal = (UInt64(1) << (size * 8)) - 1
                if u > maxVal {
                    throw LuauRuntimeError(value: .string("integer overflow in 'string.pack'"))
                }
            }
            for idx in 0..<size {
                let byte = idx < 8 ? UInt8(u & 0xFF) : 0
                if idx < 8 { u >>= 8 }
                bytes[little ? idx : (size - 1 - idx)] = byte
            }
        }
        return bytes
    }

    private static func unpackIntBytes(_ slice: ArraySlice<UInt8>, signed: Bool, little: Bool) -> Double {
        let size = slice.count
        var u: UInt64 = 0
        for i in 0..<min(size, 8) {
            let b = little ? slice[slice.startIndex + i] : slice[slice.endIndex - 1 - i]
            u |= UInt64(b) << (i * 8)
        }
        if signed {
            let msb = little ? slice[slice.endIndex - 1] : slice[slice.startIndex]
            if (msb & 0x80) != 0 {
                if size < 8 {
                    u |= ~((UInt64(1) << (size * 8)) - 1)
                }
                return Double(Int64(bitPattern: u))
            }
            return Double(Int64(bitPattern: u))
        }
        return Double(u)
    }

    private static func packBinary(fmt: String, args: [LuauValue]) throws -> [UInt8] {
        let ops = try parsePackFormat(fmt)
        var out: [UInt8] = []
        var argIdx = 0

        func alignOut(_ align: Int) {
            guard align > 1 else { return }
            let rem = out.count % align
            if rem != 0 {
                out.append(contentsOf: repeatElement(0, count: align - rem))
            }
        }

        for (op, endian, align) in ops {
            alignOut(align)
            let little = isLittleEndian(endian)
            switch op {
            case .padding(let n):
                out.append(contentsOf: repeatElement(0, count: n))
            case .alignOnly:
                break
            case .signedInt(let size):
                guard argIdx < args.count, let n = args[argIdx].coercedNumber else {
                    throw LuauRuntimeError(value: .string("bad argument to 'pack' (number expected)"))
                }
                argIdx += 1
                out.append(contentsOf: try packIntBytes(Int64(n), size: size, signed: true, little: little))
            case .unsignedInt(let size):
                guard argIdx < args.count, let n = args[argIdx].coercedNumber else {
                    throw LuauRuntimeError(value: .string("bad argument to 'pack' (number expected)"))
                }
                argIdx += 1
                if n < 0 {
                    throw LuauRuntimeError(value: .string("unsigned overflow in 'string.pack'"))
                }
                out.append(contentsOf: try packIntBytes(Int64(UInt64(n)), size: size, signed: false, little: little))
            case .float32:
                guard argIdx < args.count, let n = args[argIdx].coercedNumber else {
                    throw LuauRuntimeError(value: .string("bad argument to 'pack' (number expected)"))
                }
                argIdx += 1
                var bits = Float(n).bitPattern
                bits = little ? bits.littleEndian : bits.bigEndian
                withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
            case .float64:
                guard argIdx < args.count, let n = args[argIdx].coercedNumber else {
                    throw LuauRuntimeError(value: .string("bad argument to 'pack' (number expected)"))
                }
                argIdx += 1
                var bits = n.bitPattern
                bits = little ? bits.littleEndian : bits.bigEndian
                withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
            case .fixedString(let n):
                guard argIdx < args.count, let bytes = args[argIdx].stringBytes else {
                    throw LuauRuntimeError(value: .string("bad argument to 'pack' (string expected)"))
                }
                argIdx += 1
                guard bytes.count <= n else {
                    throw LuauRuntimeError(value: .string("string longer than given size"))
                }
                out.append(contentsOf: bytes)
                if bytes.count < n {
                    out.append(contentsOf: repeatElement(0, count: n - bytes.count))
                }
            case .cString:
                guard argIdx < args.count, let bytes = args[argIdx].stringBytes else {
                    throw LuauRuntimeError(value: .string("bad argument to 'pack' (string expected)"))
                }
                argIdx += 1
                if bytes.contains(0) {
                    throw LuauRuntimeError(value: .string("string contains zeros"))
                }
                out.append(contentsOf: bytes)
                out.append(0)
            case .lengthString(let size):
                guard argIdx < args.count, let bytes = args[argIdx].stringBytes else {
                    throw LuauRuntimeError(value: .string("bad argument to 'pack' (string expected)"))
                }
                argIdx += 1
                out.append(contentsOf: try packIntBytes(Int64(bytes.count), size: size, signed: false, little: little))
                out.append(contentsOf: bytes)
            }
        }
        return out
    }

    private static func unpackBinary(fmt: String, bytes: [UInt8], initPos: Int) throws -> ([LuauValue], Int) {
        let ops = try parsePackFormat(fmt)
        var pos = initPos
        var results: [LuauValue] = []

        func alignPos(_ align: Int) {
            guard align > 1 else { return }
            let rem = pos % align
            if rem != 0 {
                pos += align - rem
            }
        }

        for (op, endian, align) in ops {
            alignPos(align)
            let little = isLittleEndian(endian)
            switch op {
            case .padding(let n):
                guard pos + n <= bytes.count else { throw LuauRuntimeError(value: .string("data string too short")) }
                pos += n
            case .alignOnly:
                break
            case .signedInt(let size):
                guard pos + size <= bytes.count else { throw LuauRuntimeError(value: .string("data string too short")) }
                results.append(.number(unpackIntBytes(bytes[pos..<(pos + size)], signed: true, little: little)))
                pos += size
            case .unsignedInt(let size):
                guard pos + size <= bytes.count else { throw LuauRuntimeError(value: .string("data string too short")) }
                results.append(.number(unpackIntBytes(bytes[pos..<(pos + size)], signed: false, little: little)))
                pos += size
            case .float32:
                guard pos + 4 <= bytes.count else { throw LuauRuntimeError(value: .string("data string too short")) }
                let raw = bytes[pos..<(pos + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                let bits = little ? UInt32(littleEndian: raw) : UInt32(bigEndian: raw)
                results.append(.number(Double(Float(bitPattern: bits))))
                pos += 4
            case .float64:
                guard pos + 8 <= bytes.count else { throw LuauRuntimeError(value: .string("data string too short")) }
                let raw = bytes[pos..<(pos + 8)].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                let bits = little ? UInt64(littleEndian: raw) : UInt64(bigEndian: raw)
                results.append(.number(Double(bitPattern: bits)))
                pos += 8
            case .fixedString(let n):
                guard pos + n <= bytes.count else { throw LuauRuntimeError(value: .string("data string too short")) }
                results.append(LuauValue.fromBytes(Array(bytes[pos..<(pos + n)])))
                pos += n
            case .cString:
                guard let nulIdx = bytes[pos...].firstIndex(of: 0) else {
                    throw LuauRuntimeError(value: .string("unfinished string for format 'z'"))
                }
                results.append(LuauValue.fromBytes(Array(bytes[pos..<nulIdx])))
                pos = nulIdx + 1
            case .lengthString(let size):
                guard pos + size <= bytes.count else { throw LuauRuntimeError(value: .string("data string too short")) }
                let len = Int(unpackIntBytes(bytes[pos..<(pos + size)], signed: false, little: little))
                pos += size
                guard len >= 0 && pos + len <= bytes.count else { throw LuauRuntimeError(value: .string("data string too short")) }
                results.append(LuauValue.fromBytes(Array(bytes[pos..<(pos + len)])))
                pos += len
            }
        }
        return (results, pos)
    }

    private static func packSizeBinary(fmt: String) throws -> Int {
        let ops = try parsePackFormat(fmt)
        var size = 0
        for (op, _, align) in ops {
            if align > 1 {
                let rem = size % align
                if rem != 0 { size += align - rem }
            }
            switch op {
            case .padding(let n), .fixedString(let n): size += n
            case .alignOnly: break
            case .signedInt(let n), .unsignedInt(let n): size += n
            case .float32: size += 4
            case .float64: size += 8
            case .cString, .lengthString:
                throw LuauRuntimeError(value: .string("variable-length format"))
            }
        }
        return size
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
            let sepBytes = (args.count > 1 ? args[1].stringBytes : nil) ?? []
            let i = args.count > 2 ? (args[2].asInt ?? 1) : 1
            let j = args.count > 3 ? (args[3].asInt ?? tbl.rawLength) : tbl.rawLength
            if i > j { return .values([.string("")]) }
            var out: [UInt8] = []
            for idx in i...j {
                if idx > i && !sepBytes.isEmpty { out.append(contentsOf: sepBytes) }
                let v = tbl.rawGet(idx)
                if let vb = v.stringBytes {
                    out.append(contentsOf: vb)
                } else if case .number(let n) = v {
                    out.append(contentsOf: LuauValue.formatNumber(n).utf8)
                } else {
                    throw LuauRuntimeError(value: .string("invalid value (\(v.typeName)) at index \(idx) in table for 'concat'"))
                }
            }
            return .values([LuauValue.fromBytes(out)])
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
                    if case .number(let na) = a, case .number(let nb) = b {
                        return na < nb
                    } else if let ba = a.stringBytes, let bb = b.stringBytes {
                        return ba.lexicographicallyPrecedes(bb)
                    } else {
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
        b.rawSet("byteswap", value: .nativeFunction(LuauNativeFunction(name: "bit32.byteswap") { _, _, args in
            let n = u32(args.first ?? .nil)
            return .values([.number(Double(n.byteSwapped))])
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
            guard let bytes = args.first?.stringBytes else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'utf8.len'"))
            }
            let len = bytes.count
            let iArg = args.count > 1 ? (args[1].asInt ?? 1) : 1
            let jArg = args.count > 2 ? (args[2].asInt ?? -1) : -1
            let start = max(1, iArg < 0 ? len + iArg + 1 : iArg)
            let end = min(len, jArg < 0 ? len + jArg + 1 : jArg)
            if start > end { return .values([.number(0)]) }
            var idx = start - 1
            var count = 0
            while idx < end {
                if let (_, nextIdx) = decodeUTF8Scalar(bytes, at: idx, limit: end) {
                    count += 1
                    idx = nextIdx
                } else {
                    return .values([.nil, .number(Double(idx + 1))])
                }
            }
            return .values([.number(Double(count))])
        }))
        u.rawSet("offset", value: .nativeFunction(LuauNativeFunction(name: "utf8.offset") { _, _, args in
            guard let bytes = args.first?.stringBytes, let n = args.count > 1 ? args[1].asInt : nil else {
                throw LuauRuntimeError(value: .string("bad arguments to 'utf8.offset'"))
            }
            var pos = args.count > 2 ? (args[2].asInt ?? (n >= 0 ? 1 : bytes.count + 1)) : (n >= 0 ? 1 : bytes.count + 1)
            if pos < 0 { pos = bytes.count + 1 + pos }
            var idx = pos - 1
            guard idx >= 0, idx <= bytes.count else { return .values([.nil]) }
            if n == 0 {
                while idx > 0 && (bytes[idx] & 0xC0) == 0x80 { idx -= 1 }
                return .values([.number(Double(idx + 1))])
            }
            if n > 0 {
                if idx < bytes.count && (bytes[idx] & 0xC0) == 0x80 {
                    throw LuauRuntimeError(value: .string("initial position is a continuation byte"))
                }
                var rem = n - 1
                while rem > 0 {
                    guard idx < bytes.count else { return .values([.nil]) }
                    idx += 1
                    while idx < bytes.count && (bytes[idx] & 0xC0) == 0x80 { idx += 1 }
                    rem -= 1
                }
                return .values([.number(Double(idx + 1))])
            } else {
                if idx < bytes.count && (bytes[idx] & 0xC0) == 0x80 {
                    throw LuauRuntimeError(value: .string("initial position is a continuation byte"))
                }
                var rem = -n
                while rem > 0 {
                    if idx == 0 { return .values([.nil]) }
                    idx -= 1
                    while idx > 0 && (bytes[idx] & 0xC0) == 0x80 { idx -= 1 }
                    rem -= 1
                }
                return .values([.number(Double(idx + 1))])
            }
        }))
        u.rawSet("codepoint", value: .nativeFunction(LuauNativeFunction(name: "utf8.codepoint") { _, _, args in
            guard let bytes = args.first?.stringBytes else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'utf8.codepoint'"))
            }
            let len = bytes.count
            let iArg = args.count > 1 ? (args[1].asInt ?? 1) : 1
            let jArg = args.count > 2 ? (args[2].asInt ?? iArg) : iArg
            let start = max(1, iArg < 0 ? len + iArg + 1 : iArg)
            let end = min(len, jArg < 0 ? len + jArg + 1 : jArg)
            if start > end { return .values([]) }
            var idx = start - 1
            var out: [LuauValue] = []
            while idx < end {
                guard let (cp, nextIdx) = decodeUTF8Scalar(bytes, at: idx, limit: bytes.count) else {
                    throw LuauRuntimeError(value: .string("invalid UTF-8 code"))
                }
                out.append(.number(Double(cp)))
                idx = nextIdx
            }
            return .values(out)
        }))
        u.rawSet("codes", value: .nativeFunction(LuauNativeFunction(name: "utf8.codes") { _, _, args in
            guard let bytes = args.first?.stringBytes else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'utf8.codes'"))
            }
            final class Cursor: @unchecked Sendable { var idx = 0 }
            let cur = Cursor()
            let iter = LuauNativeFunction(name: "utf8_codes_iter") { _, _, _ in
                if cur.idx >= bytes.count { return .values([.nil]) }
                let pos = cur.idx + 1
                guard let (cp, nextIdx) = decodeUTF8Scalar(bytes, at: cur.idx, limit: bytes.count) else {
                    throw LuauRuntimeError(value: .string("invalid UTF-8 code"))
                }
                cur.idx = nextIdx
                return .values([.number(Double(pos)), .number(Double(cp))])
            }
            return .values([.nativeFunction(iter)])
        }))
        g.rawSet("utf8", value: .table(u))
    }

    private static func decodeUTF8Scalar(_ bytes: [UInt8], at idx: Int, limit: Int) -> (UInt32, Int)? {
        guard idx < limit else { return nil }
        let b0 = bytes[idx]
        if b0 < 0x80 {
            return (UInt32(b0), idx + 1)
        } else if (b0 & 0xE0) == 0xC0 {
            guard idx + 1 < limit else { return nil }
            let b1 = bytes[idx + 1]
            guard (b1 & 0xC0) == 0x80 else { return nil }
            let cp = (UInt32(b0 & 0x1F) << 6) | UInt32(b1 & 0x3F)
            guard cp >= 0x80 else { return nil }
            return (cp, idx + 2)
        } else if (b0 & 0xF0) == 0xE0 {
            guard idx + 2 < limit else { return nil }
            let b1 = bytes[idx + 1], b2 = bytes[idx + 2]
            guard (b1 & 0xC0) == 0x80 && (b2 & 0xC0) == 0x80 else { return nil }
            let cp = (UInt32(b0 & 0x0F) << 12) | (UInt32(b1 & 0x3F) << 6) | UInt32(b2 & 0x3F)
            guard cp >= 0x800 && !(cp >= 0xD800 && cp <= 0xDFFF) else { return nil }
            return (cp, idx + 3)
        } else if (b0 & 0xF8) == 0xF0 {
            guard idx + 3 < limit else { return nil }
            let b1 = bytes[idx + 1], b2 = bytes[idx + 2], b3 = bytes[idx + 3]
            guard (b1 & 0xC0) == 0x80 && (b2 & 0xC0) == 0x80 && (b3 & 0xC0) == 0x80 else { return nil }
            let cp = (UInt32(b0 & 0x07) << 18) | (UInt32(b1 & 0x3F) << 12) | (UInt32(b2 & 0x3F) << 6) | UInt32(b3 & 0x3F)
            guard cp >= 0x10000 && cp <= 0x10FFFF else { return nil }
            return (cp, idx + 4)
        }
        return nil
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
        o.rawSet("time", value: .nativeFunction(LuauNativeFunction(name: "os.time") { _, _, args in
            if case .table(let tbl) = args.first {
                guard let year = tbl.rawGet("year").asInt,
                      let month = tbl.rawGet("month").asInt,
                      let day = tbl.rawGet("day").asInt else {
                    throw LuauRuntimeError(value: .string("field missing in date table"))
                }
                var t = tm()
                t.tm_year = Int32(year - 1900)
                t.tm_mon = Int32(month - 1)
                t.tm_mday = Int32(day)
                t.tm_hour = Int32(tbl.rawGet("hour").asInt ?? 12)
                t.tm_min = Int32(tbl.rawGet("min").asInt ?? 0)
                t.tm_sec = Int32(tbl.rawGet("sec").asInt ?? 0)
                let dstVal = tbl.rawGet("isdst")
                if dstVal.isNil {
                    t.tm_isdst = -1
                } else {
                    t.tm_isdst = dstVal.isTruthy ? 1 : 0
                }
                let res = mktime(&t)
                if res == -1 { return .values([.nil]) }
                return .values([.number(Double(res))])
            }
            return .values([.number(floor(Date().timeIntervalSince1970))])
        }))
        o.rawSet("date", value: .nativeFunction(LuauNativeFunction(name: "os.date") { _, _, args in
            let fmt = (args.first?.isNil == false ? args.first?.asString : nil) ?? "%c"
            var rawTime: time_t
            if args.count > 1 && !args[1].isNil {
                guard let num = args[1].coercedNumber else {
                    throw LuauRuntimeError(value: .string("bad argument #2 to 'date' (number expected)"))
                }
                rawTime = time_t(Int64(num))
            } else {
                rawTime = time_t(Int64(floor(Date().timeIntervalSince1970)))
            }
            let utc = fmt.hasPrefix("!")
            let spec = utc ? String(fmt.dropFirst()) : fmt
            var t = tm()
            if utc {
                gmtime_r(&rawTime, &t)
            } else {
                localtime_r(&rawTime, &t)
            }
            if spec == "*t" {
                let tbl = LuauTable()
                tbl.rawSet("year", value: .number(Double(Int(t.tm_year) + 1900)))
                tbl.rawSet("month", value: .number(Double(Int(t.tm_mon) + 1)))
                tbl.rawSet("day", value: .number(Double(Int(t.tm_mday))))
                tbl.rawSet("hour", value: .number(Double(Int(t.tm_hour))))
                tbl.rawSet("min", value: .number(Double(Int(t.tm_min))))
                tbl.rawSet("sec", value: .number(Double(Int(t.tm_sec))))
                tbl.rawSet("wday", value: .number(Double(Int(t.tm_wday) + 1)))
                tbl.rawSet("yday", value: .number(Double(Int(t.tm_yday) + 1)))
                tbl.rawSet("isdst", value: .bool(t.tm_isdst > 0))
                return .values([.table(tbl)])
            }
            let validOpts = Set("aAbBcCdDeFgGhHIjmMnprRStTuUVwWxXyYzZ%")
            var si = spec.startIndex
            while si < spec.endIndex {
                if spec[si] == "%" {
                    let next = spec.index(after: si)
                    guard next < spec.endIndex, validOpts.contains(spec[next]) else {
                        let bad = next < spec.endIndex ? String(spec[next]) : ""
                        throw LuauRuntimeError(value: .string("invalid conversion specifier '%\(bad)'"))
                    }
                    si = spec.index(after: next)
                } else {
                    si = spec.index(after: si)
                }
            }
            if spec.isEmpty { return .values([.string("")]) }
            var buf = [CChar](repeating: 0, count: 512)
            let written = spec.withCString { cFmt in
                strftime(&buf, buf.count, cFmt, &t)
            }
            if written == 0 {
                // Distinguish empty output from buffer too small by trying larger buffer
                var bigBuf = [CChar](repeating: 0, count: 4096)
                let bigWritten = spec.withCString { cFmt in
                    strftime(&bigBuf, bigBuf.count, cFmt, &t)
                }
                if bigWritten == 0 {
                    return .values([.string("")])
                }
                let bytes = bigBuf[0..<bigWritten].map { UInt8(bitPattern: $0) }
                return .values([LuauValue.fromBytes(bytes)])
            }
            let bytes = buf[0..<written].map { UInt8(bitPattern: $0) }
            return .values([LuauValue.fromBytes(bytes)])
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
        final class SelfRef: @unchecked Sendable { var fn: LuauNativeFunction? }
        let infoRef = SelfRef()
        let infoFn = LuauNativeFunction(name: "debug.info") { _, currentThread, args in
            var targetThread = currentThread
            var idx = 0
            if case .thread(let th) = args.first {
                targetThread = th
                idx = 1
            }
            guard idx + 1 < args.count else {
                throw LuauRuntimeError(value: .string("bad arguments to 'debug.info'"))
            }
            let target = args[idx]
            guard let what = args[idx + 1].asString else {
                throw LuauRuntimeError(value: .string("bad argument to 'debug.info' (string expected)"))
            }

            let source: String
            let line: Int
            let name: String
            let nparams: Int
            let isvararg: Bool
            let funcVal: LuauValue

            if let level = target.asInt {
                if level < 0 {
                    throw LuauRuntimeError(value: .string("bad argument to 'debug.info' (level can't be negative)"))
                }
                if level == 0 {
                    source = "[C]"
                    line = -1
                    name = "info"
                    nparams = 0
                    isvararg = true
                    funcVal = infoRef.fn.map { .nativeFunction($0) } ?? .nil
                } else {
                    let frameIdx = targetThread.frames.count - level
                    if frameIdx < 0 || frameIdx >= targetThread.frames.count {
                        return .values([])
                    }
                    let frame = targetThread.frames[frameIdx]
                    let pc = max(0, frame.pc - 1)
                    line = pc < frame.closure.proto.code.count ? frame.closure.proto.code[pc].line : 0
                    source = frame.closure.proto.sourceName
                    name = frame.closure.proto.name
                    nparams = frame.closure.proto.paramsCount
                    isvararg = frame.closure.proto.isVariadic
                    funcVal = .closure(frame.closure)
                }
            } else if case .closure(let cl) = target {
                source = cl.proto.sourceName
                line = cl.proto.code.first?.line ?? 0
                name = cl.proto.name
                nparams = cl.proto.paramsCount
                isvararg = cl.proto.isVariadic
                funcVal = .closure(cl)
            } else if case .nativeFunction(let nf) = target {
                source = "[C]"
                line = -1
                name = nf.name
                nparams = 0
                isvararg = true
                funcVal = .nativeFunction(nf)
            } else {
                throw LuauRuntimeError(value: .string("bad argument to 'debug.info' (function or level expected)"))
            }

            var out: [LuauValue] = []
            for ch in what {
                switch ch {
                case "s": out.append(.string(source))
                case "l": out.append(.number(Double(line)))
                case "n": out.append(.string(name))
                case "a":
                    out.append(.number(Double(nparams)))
                    out.append(.bool(isvararg))
                case "f": out.append(funcVal)
                default:
                    throw LuauRuntimeError(value: .string("invalid option '\(ch)' to 'debug.info'"))
                }
            }
            return .values(out)
        }
        infoRef.fn = infoFn
        d.rawSet("info", value: .nativeFunction(infoFn))
        g.rawSet("debug", value: .table(d))
    }

    // MARK: - vector

    private static func reqVec(_ args: [LuauValue], _ idx: Int, _ fn: String) throws -> SIMD3<Double> {
        guard idx < args.count, case .vector(let vec) = args[idx] else {
            throw LuauRuntimeError(value: .string("bad argument #\(idx + 1) to 'vector.\(fn)' (vector expected)"))
        }
        return vec
    }

    private static func installVector(into g: LuauTable) {
        let v = LuauTable()
        v.rawSet("create", value: .nativeFunction(LuauNativeFunction(name: "vector.create") { _, _, args in
            let x = args.count > 0 ? (args[0].coercedNumber ?? 0) : 0
            let y = args.count > 1 ? (args[1].coercedNumber ?? 0) : 0
            let z = args.count > 2 ? (args[2].coercedNumber ?? 0) : 0
            return .values([.vector(SIMD3<Double>(x, y, z))])
        }))
        v.rawSet("magnitude", value: .nativeFunction(LuauNativeFunction(name: "vector.magnitude") { _, _, args in
            let a = try reqVec(args, 0, "magnitude")
            return .values([.number((a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())])
        }))
        v.rawSet("normalize", value: .nativeFunction(LuauNativeFunction(name: "vector.normalize") { _, _, args in
            let a = try reqVec(args, 0, "normalize")
            let mag = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            return .values([.vector(a / mag)])
        }))
        v.rawSet("cross", value: .nativeFunction(LuauNativeFunction(name: "vector.cross") { _, _, args in
            let a = try reqVec(args, 0, "cross")
            let b = try reqVec(args, 1, "cross")
            return .values([.vector(SIMD3<Double>(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x))])
        }))
        v.rawSet("dot", value: .nativeFunction(LuauNativeFunction(name: "vector.dot") { _, _, args in
            let a = try reqVec(args, 0, "dot")
            let b = try reqVec(args, 1, "dot")
            return .values([.number(a.x * b.x + a.y * b.y + a.z * b.z)])
        }))
        v.rawSet("angle", value: .nativeFunction(LuauNativeFunction(name: "vector.angle") { _, _, args in
            let a = try reqVec(args, 0, "angle")
            let b = try reqVec(args, 1, "angle")
            let c = SIMD3<Double>(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
            let cMag = (c.x * c.x + c.y * c.y + c.z * c.z).squareRoot()
            let dot = a.x * b.x + a.y * b.y + a.z * b.z
            var ang = atan2(cMag, dot)
            if args.count > 2 && !args[2].isNil {
                let axis = try reqVec(args, 2, "angle")
                if c.x * axis.x + c.y * axis.y + c.z * axis.z < 0 {
                    ang = -ang
                }
            }
            return .values([.number(ang)])
        }))
        v.rawSet("floor", value: .nativeFunction(LuauNativeFunction(name: "vector.floor") { _, _, args in
            let a = try reqVec(args, 0, "floor")
            return .values([.vector(SIMD3<Double>(Foundation.floor(a.x), Foundation.floor(a.y), Foundation.floor(a.z)))])
        }))
        v.rawSet("ceil", value: .nativeFunction(LuauNativeFunction(name: "vector.ceil") { _, _, args in
            let a = try reqVec(args, 0, "ceil")
            return .values([.vector(SIMD3<Double>(Foundation.ceil(a.x), Foundation.ceil(a.y), Foundation.ceil(a.z)))])
        }))
        v.rawSet("abs", value: .nativeFunction(LuauNativeFunction(name: "vector.abs") { _, _, args in
            let a = try reqVec(args, 0, "abs")
            return .values([.vector(SIMD3<Double>(Swift.abs(a.x), Swift.abs(a.y), Swift.abs(a.z)))])
        }))
        v.rawSet("sign", value: .nativeFunction(LuauNativeFunction(name: "vector.sign") { _, _, args in
            let a = try reqVec(args, 0, "sign")
            func sgn(_ x: Double) -> Double { x > 0 ? 1 : (x < 0 ? -1 : 0) }
            return .values([.vector(SIMD3<Double>(sgn(a.x), sgn(a.y), sgn(a.z)))])
        }))
        v.rawSet("clamp", value: .nativeFunction(LuauNativeFunction(name: "vector.clamp") { _, _, args in
            let a = try reqVec(args, 0, "clamp")
            let lo = try reqVec(args, 1, "clamp")
            let hi = try reqVec(args, 2, "clamp")
            guard lo.x <= hi.x && lo.y <= hi.y && lo.z <= hi.z else {
                throw LuauRuntimeError(value: .string("bad argument #3 to 'vector.clamp' (max must be >= min)"))
            }
            return .values([.vector(SIMD3<Double>(
                Swift.min(Swift.max(a.x, lo.x), hi.x),
                Swift.min(Swift.max(a.y, lo.y), hi.y),
                Swift.min(Swift.max(a.z, lo.z), hi.z)
            ))])
        }))
        v.rawSet("min", value: .nativeFunction(LuauNativeFunction(name: "vector.min") { _, _, args in
            var best = try reqVec(args, 0, "min")
            for i in 1..<args.count {
                let next = try reqVec(args, i, "min")
                best = SIMD3<Double>(Swift.min(best.x, next.x), Swift.min(best.y, next.y), Swift.min(best.z, next.z))
            }
            return .values([.vector(best)])
        }))
        v.rawSet("max", value: .nativeFunction(LuauNativeFunction(name: "vector.max") { _, _, args in
            var best = try reqVec(args, 0, "max")
            for i in 1..<args.count {
                let next = try reqVec(args, i, "max")
                best = SIMD3<Double>(Swift.max(best.x, next.x), Swift.max(best.y, next.y), Swift.max(best.z, next.z))
            }
            return .values([.vector(best)])
        }))
        v.rawSet("lerp", value: .nativeFunction(LuauNativeFunction(name: "vector.lerp") { _, _, args in
            let a = try reqVec(args, 0, "lerp")
            let b = try reqVec(args, 1, "lerp")
            guard let t = args.count > 2 ? args[2].coercedNumber : nil else {
                throw LuauRuntimeError(value: .string("bad argument #3 to 'vector.lerp' (number expected)"))
            }
            return .values([.vector(a + (b - a) * t)])
        }))
        v.rawSet("zero", value: .vector(.zero))
        v.rawSet("one", value: .vector(SIMD3<Double>(1, 1, 1)))
        g.rawSet("vector", value: .table(v))
    }

    // MARK: - buffer

    private static func reqBuffer(_ args: [LuauValue], _ idx: Int, _ fn: String) throws -> LuauBufferBox {
        guard idx < args.count,
              case .userdata(let u) = args[idx],
              let box = u.payload as? LuauBufferBox else {
            throw LuauRuntimeError(value: .string("bad argument #\(idx + 1) to 'buffer.\(fn)' (buffer expected)"))
        }
        return box
    }

    private static func reqOffset(_ args: [LuauValue], _ idx: Int, _ fn: String) throws -> Int {
        guard idx < args.count, let off = args[idx].asInt else {
            throw LuauRuntimeError(value: .string("bad argument #\(idx + 1) to 'buffer.\(fn)' (number expected)"))
        }
        return off
    }

    private static func checkRange(_ buf: LuauBufferBox, _ offset: Int, _ size: Int) throws {
        guard offset >= 0, size >= 0, offset + size <= buf.bytes.count else {
            throw LuauRuntimeError(value: .string("buffer access out of bounds"))
        }
    }

    private static func readLE<T: FixedWidthInteger>(_ buf: LuauBufferBox, offset: Int, as type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        try checkRange(buf, offset, size)
        var val: T = 0
        for i in 0..<size {
            val |= T(buf.bytes[offset + i]) << (i * 8)
        }
        return val
    }

    private static func writeLE<T: FixedWidthInteger>(_ buf: LuauBufferBox, offset: Int, value: T) throws {
        let size = MemoryLayout<T>.size
        try checkRange(buf, offset, size)
        for i in 0..<size {
            buf.bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8))
        }
    }

    private static func installBuffer(into g: LuauTable, vm: LuauVM) {
        let b = LuauTable()

        b.rawSet("create", value: .nativeFunction(LuauNativeFunction(name: "buffer.create") { vm, _, args in
            guard let size = args.first?.asInt, size >= 0 else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'buffer.create' (size out of range)"))
            }
            try vm.noteAllocation(size + 64)
            return .values([.userdata(LuauUserdata(payload: LuauBufferBox([UInt8](repeating: 0, count: size))))])
        }))

        b.rawSet("fromstring", value: .nativeFunction(LuauNativeFunction(name: "buffer.fromstring") { vm, _, args in
            guard let bytes = args.first?.stringBytes else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'buffer.fromstring' (string expected)"))
            }
            try vm.noteAllocation(bytes.count + 64)
            return .values([.userdata(LuauUserdata(payload: LuauBufferBox(bytes)))])
        }))

        b.rawSet("tostring", value: .nativeFunction(LuauNativeFunction(name: "buffer.tostring") { _, _, args in
            let buf = try reqBuffer(args, 0, "tostring")
            return .values([LuauValue.fromBytes(buf.bytes)])
        }))

        b.rawSet("len", value: .nativeFunction(LuauNativeFunction(name: "buffer.len") { _, _, args in
            let buf = try reqBuffer(args, 0, "len")
            return .values([.number(Double(buf.bytes.count))])
        }))

        b.rawSet("readi8", value: .nativeFunction(LuauNativeFunction(name: "buffer.readi8") { _, _, args in
            let buf = try reqBuffer(args, 0, "readi8")
            let off = try reqOffset(args, 1, "readi8")
            try checkRange(buf, off, 1)
            return .values([.number(Double(Int8(bitPattern: buf.bytes[off])))])
        }))
        b.rawSet("readu8", value: .nativeFunction(LuauNativeFunction(name: "buffer.readu8") { _, _, args in
            let buf = try reqBuffer(args, 0, "readu8")
            let off = try reqOffset(args, 1, "readu8")
            try checkRange(buf, off, 1)
            return .values([.number(Double(buf.bytes[off]))])
        }))
        b.rawSet("readi16", value: .nativeFunction(LuauNativeFunction(name: "buffer.readi16") { _, _, args in
            let buf = try reqBuffer(args, 0, "readi16")
            let off = try reqOffset(args, 1, "readi16")
            let raw = try readLE(buf, offset: off, as: UInt16.self)
            return .values([.number(Double(Int16(bitPattern: raw)))])
        }))
        b.rawSet("readu16", value: .nativeFunction(LuauNativeFunction(name: "buffer.readu16") { _, _, args in
            let buf = try reqBuffer(args, 0, "readu16")
            let off = try reqOffset(args, 1, "readu16")
            let raw = try readLE(buf, offset: off, as: UInt16.self)
            return .values([.number(Double(raw))])
        }))
        b.rawSet("readi32", value: .nativeFunction(LuauNativeFunction(name: "buffer.readi32") { _, _, args in
            let buf = try reqBuffer(args, 0, "readi32")
            let off = try reqOffset(args, 1, "readi32")
            let raw = try readLE(buf, offset: off, as: UInt32.self)
            return .values([.number(Double(Int32(bitPattern: raw)))])
        }))
        b.rawSet("readu32", value: .nativeFunction(LuauNativeFunction(name: "buffer.readu32") { _, _, args in
            let buf = try reqBuffer(args, 0, "readu32")
            let off = try reqOffset(args, 1, "readu32")
            let raw = try readLE(buf, offset: off, as: UInt32.self)
            return .values([.number(Double(raw))])
        }))
        b.rawSet("readf32", value: .nativeFunction(LuauNativeFunction(name: "buffer.readf32") { _, _, args in
            let buf = try reqBuffer(args, 0, "readf32")
            let off = try reqOffset(args, 1, "readf32")
            let raw = try readLE(buf, offset: off, as: UInt32.self)
            return .values([.number(Double(Float(bitPattern: raw)))])
        }))
        b.rawSet("readf64", value: .nativeFunction(LuauNativeFunction(name: "buffer.readf64") { _, _, args in
            let buf = try reqBuffer(args, 0, "readf64")
            let off = try reqOffset(args, 1, "readf64")
            let raw = try readLE(buf, offset: off, as: UInt64.self)
            return .values([.number(Double(bitPattern: raw))])
        }))

        b.rawSet("writei8", value: .nativeFunction(LuauNativeFunction(name: "buffer.writei8") { _, _, args in
            let buf = try reqBuffer(args, 0, "writei8")
            let off = try reqOffset(args, 1, "writei8")
            guard args.count > 2, let val = args[2].coercedNumber else { throw LuauRuntimeError(value: .string("number expected")) }
            try checkRange(buf, off, 1)
            buf.bytes[off] = UInt8(truncatingIfNeeded: Int64(val))
            return .values([])
        }))
        b.rawSet("writeu8", value: .nativeFunction(LuauNativeFunction(name: "buffer.writeu8") { _, _, args in
            let buf = try reqBuffer(args, 0, "writeu8")
            let off = try reqOffset(args, 1, "writeu8")
            guard args.count > 2, let val = args[2].coercedNumber else { throw LuauRuntimeError(value: .string("number expected")) }
            try checkRange(buf, off, 1)
            buf.bytes[off] = UInt8(truncatingIfNeeded: Int64(val))
            return .values([])
        }))
        b.rawSet("writei16", value: .nativeFunction(LuauNativeFunction(name: "buffer.writei16") { _, _, args in
            let buf = try reqBuffer(args, 0, "writei16")
            let off = try reqOffset(args, 1, "writei16")
            guard args.count > 2, let val = args[2].coercedNumber else { throw LuauRuntimeError(value: .string("number expected")) }
            try writeLE(buf, offset: off, value: UInt16(truncatingIfNeeded: Int64(val)))
            return .values([])
        }))
        b.rawSet("writeu16", value: .nativeFunction(LuauNativeFunction(name: "buffer.writeu16") { _, _, args in
            let buf = try reqBuffer(args, 0, "writeu16")
            let off = try reqOffset(args, 1, "writeu16")
            guard args.count > 2, let val = args[2].coercedNumber else { throw LuauRuntimeError(value: .string("number expected")) }
            try writeLE(buf, offset: off, value: UInt16(truncatingIfNeeded: Int64(val)))
            return .values([])
        }))
        b.rawSet("writei32", value: .nativeFunction(LuauNativeFunction(name: "buffer.writei32") { _, _, args in
            let buf = try reqBuffer(args, 0, "writei32")
            let off = try reqOffset(args, 1, "writei32")
            guard args.count > 2, let val = args[2].coercedNumber else { throw LuauRuntimeError(value: .string("number expected")) }
            try writeLE(buf, offset: off, value: UInt32(truncatingIfNeeded: Int64(val)))
            return .values([])
        }))
        b.rawSet("writeu32", value: .nativeFunction(LuauNativeFunction(name: "buffer.writeu32") { _, _, args in
            let buf = try reqBuffer(args, 0, "writeu32")
            let off = try reqOffset(args, 1, "writeu32")
            guard args.count > 2, let val = args[2].coercedNumber else { throw LuauRuntimeError(value: .string("number expected")) }
            try writeLE(buf, offset: off, value: UInt32(truncatingIfNeeded: UInt64(max(0, Int64(val)))))
            return .values([])
        }))
        b.rawSet("writef32", value: .nativeFunction(LuauNativeFunction(name: "buffer.writef32") { _, _, args in
            let buf = try reqBuffer(args, 0, "writef32")
            let off = try reqOffset(args, 1, "writef32")
            guard args.count > 2, let val = args[2].coercedNumber else { throw LuauRuntimeError(value: .string("number expected")) }
            try writeLE(buf, offset: off, value: Float(val).bitPattern)
            return .values([])
        }))
        b.rawSet("writef64", value: .nativeFunction(LuauNativeFunction(name: "buffer.writef64") { _, _, args in
            let buf = try reqBuffer(args, 0, "writef64")
            let off = try reqOffset(args, 1, "writef64")
            guard args.count > 2, let val = args[2].coercedNumber else { throw LuauRuntimeError(value: .string("number expected")) }
            try writeLE(buf, offset: off, value: val.bitPattern)
            return .values([])
        }))

        b.rawSet("readstring", value: .nativeFunction(LuauNativeFunction(name: "buffer.readstring") { _, _, args in
            let buf = try reqBuffer(args, 0, "readstring")
            let off = try reqOffset(args, 1, "readstring")
            let count = try reqOffset(args, 2, "readstring")
            try checkRange(buf, off, count)
            return .values([LuauValue.fromBytes(Array(buf.bytes[off..<(off + count)]))])
        }))

        b.rawSet("writestring", value: .nativeFunction(LuauNativeFunction(name: "buffer.writestring") { _, _, args in
            let buf = try reqBuffer(args, 0, "writestring")
            let off = try reqOffset(args, 1, "writestring")
            guard args.count > 2, let strBytes = args[2].stringBytes else {
                throw LuauRuntimeError(value: .string("bad argument #3 to 'buffer.writestring' (string expected)"))
            }
            let count = args.count > 3 ? (args[3].asInt ?? strBytes.count) : strBytes.count
            guard count >= 0 && count <= strBytes.count else {
                throw LuauRuntimeError(value: .string("bad argument #4 to 'buffer.writestring' (count out of bounds)"))
            }
            try checkRange(buf, off, count)
            for i in 0..<count {
                buf.bytes[off + i] = strBytes[i]
            }
            return .values([])
        }))

        b.rawSet("copy", value: .nativeFunction(LuauNativeFunction(name: "buffer.copy") { _, _, args in
            let target = try reqBuffer(args, 0, "copy")
            let targetOff = try reqOffset(args, 1, "copy")
            let source = try reqBuffer(args, 2, "copy")
            let sourceOff = args.count > 3 ? (args[3].asInt ?? 0) : 0
            guard sourceOff >= 0 && sourceOff <= source.bytes.count else {
                throw LuauRuntimeError(value: .string("buffer access out of bounds"))
            }
            let count = args.count > 4 ? (args[4].asInt ?? (source.bytes.count - sourceOff)) : (source.bytes.count - sourceOff)
            try checkRange(source, sourceOff, count)
            try checkRange(target, targetOff, count)
            let snapshot = Array(source.bytes[sourceOff..<(sourceOff + count)])
            for i in 0..<count {
                target.bytes[targetOff + i] = snapshot[i]
            }
            return .values([])
        }))

        b.rawSet("fill", value: .nativeFunction(LuauNativeFunction(name: "buffer.fill") { _, _, args in
            let buf = try reqBuffer(args, 0, "fill")
            let off = try reqOffset(args, 1, "fill")
            guard args.count > 2, let valNum = args[2].coercedNumber else {
                throw LuauRuntimeError(value: .string("number expected"))
            }
            guard off >= 0 && off <= buf.bytes.count else {
                throw LuauRuntimeError(value: .string("buffer access out of bounds"))
            }
            let count = args.count > 3 ? (args[3].asInt ?? (buf.bytes.count - off)) : (buf.bytes.count - off)
            try checkRange(buf, off, count)
            let byteVal = UInt8(truncatingIfNeeded: Int64(valNum))
            for i in 0..<count {
                buf.bytes[off + i] = byteVal
            }
            return .values([])
        }))

        b.rawSet("readbits", value: .nativeFunction(LuauNativeFunction(name: "buffer.readbits") { _, _, args in
            let buf = try reqBuffer(args, 0, "readbits")
            let bitOff = try reqOffset(args, 1, "readbits")
            let bitCount = try reqOffset(args, 2, "readbits")
            guard bitOff >= 0, bitCount >= 0, bitCount <= 32, bitOff + bitCount <= buf.bytes.count * 8 else {
                throw LuauRuntimeError(value: .string("buffer access out of bounds"))
            }
            var result: UInt32 = 0
            for i in 0..<bitCount {
                let bitIdx = bitOff + i
                let byteVal = buf.bytes[bitIdx / 8]
                let bit = UInt32((byteVal >> (bitIdx % 8)) & 1)
                result |= (bit << i)
            }
            return .values([.number(Double(result))])
        }))

        b.rawSet("writebits", value: .nativeFunction(LuauNativeFunction(name: "buffer.writebits") { _, _, args in
            let buf = try reqBuffer(args, 0, "writebits")
            let bitOff = try reqOffset(args, 1, "writebits")
            let bitCount = try reqOffset(args, 2, "writebits")
            guard args.count > 3, let valNum = args[3].coercedNumber else {
                throw LuauRuntimeError(value: .string("number expected"))
            }
            guard bitOff >= 0, bitCount >= 0, bitCount <= 32, bitOff + bitCount <= buf.bytes.count * 8 else {
                throw LuauRuntimeError(value: .string("buffer access out of bounds"))
            }
            let val = UInt32(truncatingIfNeeded: Int64(valNum))
            for i in 0..<bitCount {
                let bitIdx = bitOff + i
                let bytePos = bitIdx / 8
                let bitInByte = UInt8(bitIdx % 8)
                if ((val >> i) & 1) != 0 {
                    buf.bytes[bytePos] |= (1 << bitInByte)
                } else {
                    buf.bytes[bytePos] &= ~(1 << bitInByte)
                }
            }
            return .values([])
        }))

        g.rawSet("buffer", value: .table(b))
    }
}
