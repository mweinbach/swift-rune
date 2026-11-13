import Foundation

/// Plain, owned data that crosses a VM boundary (worker threads, host signals, hot-reload state, `query`).
public enum LuauData: Sendable, Equatable {
    case `nil`
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case list([LuauData])
    case map([String: LuauData])

    private static let maxDepth = 64
    private static let maxSafeInteger: Double = 9_007_199_254_740_991.0

    public var asDouble: Double? {
        switch self {
        case .number(let n): return n
        case .integer(let i): return Double(i)
        default: return nil
        }
    }

    public var asInt64: Int64? {
        if case .integer(let i) = self { return i }
        return nil
    }

    public var asString: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var asBool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public subscript(_ key: String) -> LuauData {
        if case .map(let m) = self {
            return m[key] ?? .nil
        }
        return .nil
    }

    public func get(_ key: String) -> LuauData {
        self[key]
    }

    /// Decodes into a `Decodable` Swift struct/value via JSONSerialization, preserving integer vs float fidelity.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        let jsonObject = toJSONObject()
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func toJSONObject() -> Any {
        switch self {
        case .nil: return NSNull()
        case .bool(let b): return b
        case .integer(let i): return NSNumber(value: i)
        case .number(let n): return n.isFinite ? NSNumber(value: n) : NSNull()
        case .string(let s): return s
        case .list(let items): return items.map { $0.toJSONObject() }
        case .map(let fields):
            var dict: [String: Any] = [:]
            dict.reserveCapacity(fields.count)
            for (k, v) in fields {
                dict[k] = v.toJSONObject()
            }
            return dict
        }
    }

    public static func fromJSONObject(_ obj: Any) -> LuauData {
        if obj is NSNull { return .nil }
        if let num = obj as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return .bool(num.boolValue)
            }
            let d = num.doubleValue
            if d.isFinite, d.truncatingRemainder(dividingBy: 1.0) == 0.0, abs(d) <= maxSafeInteger {
                return .integer(Int64(d))
            }
            return .number(d)
        }
        if let s = obj as? String { return .string(s) }
        if let arr = obj as? [Any] { return .list(arr.map { fromJSONObject($0) }) }
        if let dict = obj as? [String: Any] {
            var map: [String: LuauData] = [:]
            for (k, v) in dict {
                map[k] = fromJSONObject(v)
            }
            return .map(map)
        }
        return .nil
    }

    public static func fromLuau(_ value: LuauValue, depth: Int = 0) -> LuauData {
        switch value {
        case .bool(let b): return .bool(b)
        case .number(let n):
            if n.isFinite, n.truncatingRemainder(dividingBy: 1.0) == 0.0, abs(n) <= maxSafeInteger {
                return .integer(Int64(n))
            }
            return .number(n)
        case .string(let s): return .string(s)
        case .table(let t) where depth < maxDepth:
            let len = t.rawLength
            if len > 0 {
                let items = (1...len).map { fromLuau(t.rawGet($0), depth: depth + 1) }
                return .list(items)
            }
            var map: [String: LuauData] = [:]
            for hk in t.hashOrder {
                guard let v = t.hash[hk], !v.isNil else { continue }
                let keyStr: String? = switch hk {
                case .string(let s): s
                case .number(let bits): LuauValue.formatNumber(Double(bitPattern: bits))
                default: nil
                }
                if let keyStr {
                    map[keyStr] = fromLuau(v, depth: depth + 1)
                }
            }
            return .map(map)
        default:
            return .nil
        }
    }

    public func toLuau(depth: Int = 0) -> LuauValue {
        switch self {
        case .nil: return .nil
        case .bool(let b): return .bool(b)
        case .integer(let i): return .number(Double(i))
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .list(let items):
            guard depth < Self.maxDepth else { return .nil }
            let tbl = LuauTable(arrayCapacity: items.count)
            tbl.array = items.map { $0.toLuau(depth: depth + 1) }
            return .table(tbl)
        case .map(let fields):
            guard depth < Self.maxDepth else { return .nil }
            let tbl = LuauTable(hashCapacity: fields.count)
            for k in fields.keys.sorted() {
                if let v = fields[k] {
                    tbl.rawSet(k, value: v.toLuau(depth: depth + 1))
                }
            }
            return .table(tbl)
        }
    }
}

extension LuauData: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension LuauData: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .integer(value) }
}
extension LuauData: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}
extension LuauData: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension LuauData: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: LuauData...) { self = .list(elements) }
}
extension LuauData: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, LuauData)...) {
        var m: [String: LuauData] = [:]
        for (k, v) in elements { m[k] = v }
        self = .map(m)
    }
}
