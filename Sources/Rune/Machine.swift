import Foundation

/// Explicit async/load lifecycle state (`rune::Attempt`).
public enum Attempt<Value, Err> {
    case idle
    case loading
    case ready(Value)
    case failed(Err)

    public var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var value: Value? {
        if case .ready(let v) = self { return v }
        return nil
    }

    public var error: Err? {
        if case .failed(let e) = self { return e }
        return nil
    }
}

extension Attempt: Sendable where Value: Sendable, Err: Sendable {}
extension Attempt: Equatable where Value: Equatable, Err: Equatable {}

/// Monotonic sequence counter for discarding stale async completions (`rune::Seq`).
public struct Seq: Sendable, Equatable, Hashable {
    public private(set) var current: UInt64 = 0

    public init() {}

    /// Advances the counter and returns the new token.
    public mutating func next() -> UInt64 {
        current &+= 1
        return current
    }

    /// True only if `token` matches the most recently issued request.
    public func isCurrent(_ token: UInt64) -> Bool {
        token != 0 && token == current
    }

    /// Invalidates any in-flight token without starting a new request.
    public mutating func cancel() {
        current &+= 1
    }
}

/// Small-buffer side-effect accumulator returned from pure state reducers (`rune::Effects<E>`).
/// Stores 0, 1, or 2 effects inline without heap allocation.
public struct Effects<E>: Sequence {
    fileprivate enum Storage {
        case zero
        case one(E)
        case two(E, E)
        case many([E])
    }

    private var storage: Storage = .zero

    public init() {}

    public static var none: Effects<E> { Effects() }

    public static func one(_ effect: E) -> Effects<E> {
        var out = Effects<E>()
        out.storage = .one(effect)
        return out
    }

    public static func two(_ first: E, _ second: E) -> Effects<E> {
        var out = Effects<E>()
        out.storage = .two(first, second)
        return out
    }

    public mutating func push(_ effect: E) {
        switch storage {
        case .zero:
            storage = .one(effect)
        case .one(let a):
            storage = .two(a, effect)
        case .two(let a, let b):
            storage = .many([a, b, effect])
        case .many(var arr):
            arr.append(effect)
            storage = .many(arr)
        }
    }

    public mutating func append<S: Sequence>(contentsOf other: S) where S.Element == E {
        for item in other {
            push(item)
        }
    }

    public var isEmpty: Bool {
        if case .zero = storage { return true }
        return false
    }

    public var count: Int {
        switch storage {
        case .zero: return 0
        case .one: return 1
        case .two: return 2
        case .many(let arr): return arr.count
        }
    }

    public var array: [E] {
        switch storage {
        case .zero: return []
        case .one(let a): return [a]
        case .two(let a, let b): return [a, b]
        case .many(let arr): return arr
        }
    }

    public func makeIterator() -> IndexingIterator<[E]> {
        array.makeIterator()
    }
}

extension Effects.Storage: Sendable where E: Sendable {}
extension Effects: Sendable where E: Sendable {}
extension Effects: Equatable where E: Equatable {
    public static func == (lhs: Effects<E>, rhs: Effects<E>) -> Bool {
        lhs.array == rhs.array
    }
}
extension Effects: Hashable where E: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(array)
    }
}

/// Thread-safe coalescing wake callback used by `Live` and background tasks to request a frame.
public final class Waker: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?

    public init(_ callback: (@Sendable () -> Void)? = nil) {
        self.callback = callback
    }

    public func setCallback(_ cb: @escaping @Sendable () -> Void) {
        lock.lock()
        callback = cb
        lock.unlock()
    }

    public func wake() {
        lock.lock()
        let cb = callback
        lock.unlock()
        cb?()
    }
}
