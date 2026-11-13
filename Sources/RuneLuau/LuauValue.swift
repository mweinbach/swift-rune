import Foundation

/// A runtime Luau value.
public enum LuauValue: @unchecked Sendable {
    case `nil`
    case bool(Bool)
    case number(Double)
    case string(String)
    case byteString([UInt8])
    case table(LuauTable)
    case closure(LuauClosure)
    case nativeFunction(LuauNativeFunction)
    case thread(LuauThread)
    case userdata(LuauUserdata)
    case vector(SIMD3<Double>)

    public var isNil: Bool {
        if case .nil = self { return true }
        return false
    }

    public var isTruthy: Bool {
        switch self {
        case .nil: return false
        case .bool(let b): return b
        default: return true
        }
    }

    public var typeName: String {
        switch self {
        case .nil: return "nil"
        case .bool: return "boolean"
        case .number: return "number"
        case .string, .byteString: return "string"
        case .table: return "table"
        case .closure, .nativeFunction: return "function"
        case .thread: return "thread"
        case .userdata(let u):
            if u.payload is LuauBufferBox { return "buffer" }
            return "userdata"
        case .vector: return "vector"
        }
    }

    /// Luau `typeof(v)`: checks `mt.__type` on tables/userdata.
    public var typeofName: String {
        switch self {
        case .table(let t):
            if let mt = t.metatable, case .string(let s) = mt.rawGet(.string("__type")) {
                return s
            }
            return "table"
        case .userdata(let u):
            if u.payload is LuauBufferBox { return "buffer" }
            if let mt = u.metatable, case .string(let s) = mt.rawGet(.string("__type")) {
                return s
            }
            return u.typeTag ?? "userdata"
        default:
            return typeName
        }
    }

    public var asNumber: Double? {
        if case .number(let d) = self { return d }
        return nil
    }

    public var asInt: Int? {
        guard case .number(let d) = self, d.isFinite, d.rounded(.towardZero) == d else { return nil }
        return Int(exactly: d)
    }

    public var asString: String? {
        switch self {
        case .string(let s): return s
        case .byteString(let b): return String(decoding: b, as: UTF8.self)
        default: return nil
        }
    }

    /// Raw bytes of a Luau string (UTF-8 for `.string`, raw bytes for `.byteString`).
    public var stringBytes: [UInt8]? {
        switch self {
        case .string(let s): return Array(s.utf8)
        case .byteString(let b): return b
        default: return nil
        }
    }

    /// Canonicalizes arbitrary raw bytes into `.string` if valid UTF-8, or `.byteString` otherwise.
    public static func fromBytes(_ bytes: [UInt8]) -> LuauValue {
        if let str = String(bytes: bytes, encoding: .utf8) {
            return .string(str)
        }
        return .byteString(bytes)
    }

    public var asBool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var asTable: LuauTable? {
        if case .table(let t) = self { return t }
        return nil
    }

    /// Coerce string/number to number like Lua `tonumber`.
    public var coercedNumber: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
                return Double(UInt64(trimmed.dropFirst(2), radix: 16) ?? 0)
            }
            return Double(trimmed)
        default: return nil
        }
    }

    public var displayString: String {
        switch self {
        case .nil: return "nil"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return LuauValue.formatNumber(n)
        case .string(let s): return s
        case .byteString(let b): return String(decoding: b, as: UTF8.self)
        case .table(let t): return "table: \(ObjectIdentifier(t).hashValue)"
        case .closure(let c): return "function: \(ObjectIdentifier(c).hashValue)"
        case .nativeFunction(let f): return "function: \(f.name)"
        case .thread(let th): return "thread: \(ObjectIdentifier(th).hashValue)"
        case .userdata(let u): return "userdata: \(ObjectIdentifier(u).hashValue)"
        case .vector(let v): return "\(LuauValue.formatNumber(v.x)), \(LuauValue.formatNumber(v.y)), \(LuauValue.formatNumber(v.z))"
        }
    }

    public static func formatNumber(_ n: Double) -> String {
        if n.isNaN { return "nan" }
        if n.isInfinite { return n > 0 ? "inf" : "-inf" }
        if n == 0 { return "0" }
        if n.truncatingRemainder(dividingBy: 1.0) == 0.0 && abs(n) < 1e15 {
            return String(Int64(n))
        }
        // Match %.14g-style clean formatting
        let formatted = String(format: "%.14g", n)
        return formatted
    }
}

extension LuauValue: Equatable {
    public static func == (lhs: LuauValue, rhs: LuauValue) -> Bool {
        switch (lhs, rhs) {
        case (.nil, .nil): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.byteString(let a), .byteString(let b)): return a == b
        case (.string(let a), .byteString(let b)): return Array(a.utf8) == b
        case (.byteString(let a), .string(let b)): return a == Array(b.utf8)
        case (.table(let a), .table(let b)): return a === b
        case (.closure(let a), .closure(let b)): return a === b
        case (.nativeFunction(let a), .nativeFunction(let b)): return a === b
        case (.thread(let a), .thread(let b)): return a === b
        case (.userdata(let a), .userdata(let b)): return a === b
        case (.vector(let a), .vector(let b)): return a == b
        default: return false
        }
    }
}

/// Hashable key wrapper for Luau table hash parts.
public enum LuauHashKey: Hashable, @unchecked Sendable {
    case bool(Bool)
    case number(UInt64) // bitPattern of normalized Double (-0.0 -> +0.0)
    case string(String)
    case byteString([UInt8])
    case table(ObjectIdentifier)
    case closure(ObjectIdentifier)
    case nativeFunction(ObjectIdentifier)
    case thread(ObjectIdentifier)
    case userdata(ObjectIdentifier)
    case vector(SIMD3<Double>)

    public init?(_ value: LuauValue) {
        switch value {
        case .nil: return nil
        case .bool(let b): self = .bool(b)
        case .number(let d):
            if d.isNaN { return nil }
            let norm = d == 0.0 ? 0.0 : d
            self = .number(norm.bitPattern)
        case .string(let s): self = .string(s)
        case .byteString(let b):
            if let s = String(bytes: b, encoding: .utf8) {
                self = .string(s)
            } else {
                self = .byteString(b)
            }
        case .table(let t): self = .table(ObjectIdentifier(t))
        case .closure(let c): self = .closure(ObjectIdentifier(c))
        case .nativeFunction(let f): self = .nativeFunction(ObjectIdentifier(f))
        case .thread(let th): self = .thread(ObjectIdentifier(th))
        case .userdata(let u): self = .userdata(ObjectIdentifier(u))
        case .vector(let v): self = .vector(v)
        }
    }

    public func toValue(reverseLookup: [ObjectIdentifier: AnyObject]? = nil) -> LuauValue {
        switch self {
        case .bool(let b): return .bool(b)
        case .number(let bits): return .number(Double(bitPattern: bits))
        case .string(let s): return .string(s)
        case .byteString(let b): return .byteString(b)
        case .vector(let v): return .vector(v)
        default: return .nil
        }
    }
}

/// A Luau table (array + hash map + metatable + freeze flag).
public final class LuauTable: @unchecked Sendable {
    public var array: [LuauValue]
    public var hash: [LuauHashKey: LuauValue]
    /// Preserves actual LuauValue keys for non-primitive keys (tables/userdata/functions/threads) during iteration.
    public var keyObjects: [LuauHashKey: LuauValue]
    /// Insertion order of hash keys for deterministic `next` / `pairs` iteration.
    public var hashOrder: [LuauHashKey]
    public var metatable: LuauTable?
    public var isFrozen: Bool = false

    public init(arrayCapacity: Int = 0, hashCapacity: Int = 0) {
        self.array = []
        if arrayCapacity > 0 {
            self.array.reserveCapacity(arrayCapacity)
        }
        self.hash = Dictionary(minimumCapacity: hashCapacity)
        self.keyObjects = [:]
        self.hashOrder = []
    }

    public func rawGet(_ key: LuauValue) -> LuauValue {
        if case .number(let d) = key, d.isFinite, d >= 1.0, d.rounded(.towardZero) == d {
            let idx = Int(d) - 1
            if idx >= 0 && idx < array.count {
                return array[idx]
            }
        }
        guard let hk = LuauHashKey(key) else { return .nil }
        return hash[hk] ?? .nil
    }

    public func rawGet(_ key: String) -> LuauValue {
        hash[.string(key)] ?? .nil
    }

    public func rawGet(_ index: Int) -> LuauValue {
        let idx = index - 1
        if idx >= 0 && idx < array.count {
            return array[idx]
        }
        return hash[.number(Double(index).bitPattern)] ?? .nil
    }

    public func rawSet(_ key: LuauValue, value: LuauValue) throws {
        if isFrozen {
            throw LuauRuntimeError(value: .string("attempt to modify a readonly table"))
        }
        if case .number(let d) = key, d.isNaN {
            throw LuauRuntimeError(value: .string("table index is NaN"))
        }
        if case .nil = key {
            throw LuauRuntimeError(value: .string("table index is nil"))
        }

        if case .number(let d) = key, d.isFinite, d >= 1.0, d.rounded(.towardZero) == d {
            let idx = Int(d) - 1
            if idx < array.count {
                array[idx] = value
                if idx == array.count - 1 && value.isNil {
                    while let last = array.last, last.isNil {
                        array.removeLast()
                    }
                }
                return
            } else if idx == array.count && !value.isNil {
                array.append(value)
                // Pull consecutive integer keys from hash into array if present
                var nextIdx = array.count + 1
                while let hk = LuauHashKey(.number(Double(nextIdx))), let v = hash.removeValue(forKey: hk) {
                    keyObjects.removeValue(forKey: hk)
                    hashOrder.removeAll { $0 == hk }
                    array.append(v)
                    nextIdx += 1
                }
                return
            }
        }

        guard let hk = LuauHashKey(key) else { return }
        if value.isNil {
            if hash.removeValue(forKey: hk) != nil {
                keyObjects.removeValue(forKey: hk)
                hashOrder.removeAll { $0 == hk }
            }
        } else {
            if hash[hk] == nil {
                hashOrder.append(hk)
            }
            hash[hk] = value
            switch key {
            case .table, .closure, .nativeFunction, .thread, .userdata:
                keyObjects[hk] = key
            default:
                break
            }
        }
    }

    public func rawSet(_ key: String, value: LuauValue) {
        let hk = LuauHashKey.string(key)
        if value.isNil {
            if hash.removeValue(forKey: hk) != nil {
                hashOrder.removeAll { $0 == hk }
            }
        } else {
            if hash[hk] == nil {
                hashOrder.append(hk)
            }
            hash[hk] = value
        }
    }

    public func rawSet(_ index: Int, value: LuauValue) {
        try? rawSet(.number(Double(index)), value: value)
    }

    /// Standard Lua `#t` length.
    public var rawLength: Int {
        // Count contiguous non-nil prefix, or binary search if sparse
        var n = array.count
        while n > 0 && array[n - 1].isNil {
            n -= 1
        }
        return n
    }

    public func next(after key: LuauValue) -> (LuauValue, LuauValue)? {
        if key.isNil {
            for (i, v) in array.enumerated() where !v.isNil {
                return (.number(Double(i + 1)), v)
            }
            for hk in hashOrder {
                if let v = hash[hk], !v.isNil {
                    return (keyObjects[hk] ?? hk.toValue(), v)
                }
            }
            return nil
        }

        if case .number(let d) = key, d.isFinite, d >= 1.0, d.rounded(.towardZero) == d {
            let idx = Int(d) - 1
            if idx >= 0 && idx < array.count {
                var nextIdx = idx + 1
                while nextIdx < array.count {
                    if !array[nextIdx].isNil {
                        return (.number(Double(nextIdx + 1)), array[nextIdx])
                    }
                    nextIdx += 1
                }
                for hk in hashOrder {
                    if let v = hash[hk], !v.isNil {
                        return (keyObjects[hk] ?? hk.toValue(), v)
                    }
                }
                return nil
            }
        }

        guard let hk = LuauHashKey(key), let pos = hashOrder.firstIndex(of: hk) else {
            return nil
        }
        var nextPos = pos + 1
        while nextPos < hashOrder.count {
            let nhk = hashOrder[nextPos]
            if let v = hash[nhk], !v.isNil {
                return (keyObjects[nhk] ?? nhk.toValue(), v)
            }
            nextPos += 1
        }
        return nil
    }

    public func clone() -> LuauTable {
        let copy = LuauTable(arrayCapacity: array.count, hashCapacity: hash.count)
        copy.array = array
        copy.hash = hash
        copy.keyObjects = keyObjects
        copy.hashOrder = hashOrder
        copy.metatable = metatable
        copy.isFrozen = false
        return copy
    }
}

/// A mutable upvalue cell shared by closures.
public final class LuauUpvalue: @unchecked Sendable {
    public var value: LuauValue
    /// When open, points to `(thread, stackIndex)`; when closed, `location` is nil and `value` holds the captured value.
    public var stackIndex: Int?
    public weak var thread: LuauThread?

    public init(thread: LuauThread, stackIndex: Int) {
        self.thread = thread
        self.stackIndex = stackIndex
        self.value = .nil
    }

    public init(closed value: LuauValue) {
        self.value = value
        self.stackIndex = nil
        self.thread = nil
    }

    public func get() -> LuauValue {
        if let idx = stackIndex, let thread, idx < thread.stack.count {
            return thread.stack[idx]
        }
        return value
    }

    public func set(_ newValue: LuauValue) {
        if let idx = stackIndex, let thread, idx < thread.stack.count {
            thread.stack[idx] = newValue
        } else {
            value = newValue
        }
    }

    public func close() {
        if let idx = stackIndex, let thread, idx < thread.stack.count {
            value = thread.stack[idx]
        }
        stackIndex = nil
        thread = nil
    }
}

/// A compiled Luau closure.
public final class LuauClosure: @unchecked Sendable {
    internal let proto: LuauProto
    public let upvalues: [LuauUpvalue]
    public let env: LuauTable

    internal init(proto: LuauProto, upvalues: [LuauUpvalue], env: LuauTable) {
        self.proto = proto
        self.upvalues = upvalues
        self.env = env
    }
}

/// Signature for Swift-backed native functions callable from Luau.
public typealias LuauNativeCallback = @Sendable (LuauVM, LuauThread, [LuauValue]) throws -> LuauCallResult

public enum LuauCallResult: @unchecked Sendable {
    case values([LuauValue])
    case yield([LuauValue])
}

/// A native Swift function exposed to Luau.
public final class LuauNativeFunction: @unchecked Sendable {
    public let name: String
    public let callback: LuauNativeCallback

    public init(name: String, callback: @escaping LuauNativeCallback) {
        self.name = name
        self.callback = callback
    }
}

/// Mutable byte buffer backing Luau `buffer` values.
internal final class LuauBufferBox: @unchecked Sendable {
    var bytes: [UInt8]
    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }
}

/// Opaque userdata box (used by `newproxy` and host objects).
public final class LuauUserdata: @unchecked Sendable {
    public var payload: Any?
    public var metatable: LuauTable?
    public var typeTag: String?

    public init(payload: Any? = nil, metatable: LuauTable? = nil, typeTag: String? = nil) {
        self.payload = payload
        self.metatable = metatable
        self.typeTag = typeTag
    }
}

/// Coroutine status matching Luau `coroutine.status`.
public enum LuauThreadStatus: String, Sendable {
    case suspended
    case running
    case normal
    case dead
}

/// A call frame inside a `LuauThread`.
public final class LuauCallFrame: @unchecked Sendable {
    public let closure: LuauClosure
    public var pc: Int = 0
    public let base: Int
    public let varargs: [LuauValue]
    public let expectedResults: Int // -1 means multi-return (all)
    public var openUpvalues: [Int: LuauUpvalue] = [:]
    /// Protected call handler frame (`pcall`/`xpcall`).
    public var protectedErrorHandler: LuauValue? = nil
    public var isProtected: Bool = false

    public init(closure: LuauClosure, base: Int, varargs: [LuauValue] = [], expectedResults: Int = -1) {
        self.closure = closure
        self.base = base
        self.varargs = varargs
        self.expectedResults = expectedResults
    }
}

/// A Luau coroutine / execution thread.
public final class LuauThread: @unchecked Sendable {
    public var stack: [LuauValue] = []
    public var frames: [LuauCallFrame] = []
    public var status: LuauThreadStatus = .suspended
    public var pendingResumeArgs: [LuauValue] = []
    public var yieldedValues: [LuauValue] = []
    public var yieldExpectedResults: Int = 0
    public var isMainThread: Bool

    public init(isMainThread: Bool = false) {
        self.isMainThread = isMainThread
    }

    public func closeUpvalues(fromStackIndex minIndex: Int) {
        for frame in frames {
            for (idx, uv) in frame.openUpvalues where idx >= minIndex {
                uv.close()
                frame.openUpvalues.removeValue(forKey: idx)
            }
        }
    }
}
