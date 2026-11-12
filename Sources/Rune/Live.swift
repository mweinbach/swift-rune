import Foundation
import RuneMotion
#if canImport(simd)
import simd
#endif

/// Values publishable through `Live<T>` directly to presentation properties without view rebuilds.
public protocol LiveValue: Sendable, Equatable {
    func encodeLiveLanes() -> MotionLanes?
    static func decodeLiveLanes(_ lanes: MotionLanes) -> Self
}

extension Float: LiveValue {
    public func encodeLiveLanes() -> MotionLanes? {
        guard !isNaN else { return nil }
        let clamped = self == 0 ? 0 : self.clamped(to: -Float.greatestFiniteMagnitude...Float.greatestFiniteMagnitude)
        return MotionLanes(clamped)
    }

    public static func decodeLiveLanes(_ lanes: MotionLanes) -> Float {
        lanes.l0
    }
}

extension Vec2: LiveValue {
    public func encodeLiveLanes() -> MotionLanes? {
        guard let lx = x.encodeLiveLanes(), let ly = y.encodeLiveLanes() else { return nil }
        return MotionLanes(lx.l0, ly.l0)
    }

    public static func decodeLiveLanes(_ lanes: MotionLanes) -> Vec2 {
        Vec2(lanes.l0, lanes.l1)
    }
}

extension Color: LiveValue {
    public func encodeLiveLanes() -> MotionLanes? {
        guard !r.isNaN && !g.isNaN && !b.isNaN && !a.isNaN else { return nil }
        return MotionLanes(r, g, b, a)
    }

    public static func decodeLiveLanes(_ lanes: MotionLanes) -> Color {
        Color(r: lanes.l0, g: lanes.l1, b: lanes.l2, a: lanes.l3)
    }
}

extension MotionRect: LiveValue {
    public func encodeLiveLanes() -> MotionLanes? {
        guard !left.isNaN && !top.isNaN && !right.isNaN && !bottom.isNaN else { return nil }
        return toLanes()
    }

    public static func decodeLiveLanes(_ lanes: MotionLanes) -> MotionRect {
        fromLanes(lanes)
    }
}

enum LiveOperation: Sendable, Equatable {
    case set(MotionLanes)
    case snap(MotionLanes)
    case pulse(active: MotionLanes, rest: MotionLanes, holdSeconds: Double)
}

final class LiveSource: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sequence: UInt64 = 0
    private(set) var lanes: MotionLanes
    private(set) var lastOp: LiveOperation
    private var wakers: [WeakWaker] = []
    let linearSpec: LinearTweenSpec?

    struct WeakWaker {
        weak var ref: Waker?
    }

    struct LinearTweenSpec: Sendable {
        let from: MotionLanes
        let duration: Double
    }

    init(initial: MotionLanes, linearSpec: LinearTweenSpec? = nil) {
        self.lanes = initial
        self.lastOp = .snap(initial)
        self.linearSpec = linearSpec
    }

    func readSnapshot() -> (seq: UInt64, lanes: MotionLanes, op: LiveOperation) {
        lock.lock()
        defer { lock.unlock() }
        return (sequence, lanes, lastOp)
    }

    func publish(_ newLanes: MotionLanes, snap: Bool) -> Bool {
        var toWake: [Waker] = []
        lock.lock()
        let sameKind: Bool
        switch (lastOp, snap) {
        case (.set, false), (.snap, true):
            sameKind = true
        default:
            sameKind = false
        }
        if sameKind && lanes == newLanes {
            lock.unlock()
            return false
        }
        lanes = newLanes
        sequence &+= 1
        lastOp = snap ? .snap(newLanes) : .set(newLanes)
        wakers.removeAll { $0.ref == nil }
        toWake = wakers.compactMap(\.ref)
        lock.unlock()
        for w in toWake { w.wake() }
        return true
    }

    func publishPulse(active: MotionLanes, rest: MotionLanes, holdSeconds: Double) -> Bool {
        var toWake: [Waker] = []
        lock.lock()
        lanes = rest
        sequence &+= 1
        lastOp = .pulse(active: active, rest: rest, holdSeconds: holdSeconds)
        wakers.removeAll { $0.ref == nil }
        toWake = wakers.compactMap(\.ref)
        lock.unlock()
        for w in toWake { w.wake() }
        return true
    }

    func subscribe(_ waker: Waker) {
        lock.lock()
        wakers.removeAll { $0.ref == nil }
        if !wakers.contains(where: { $0.ref === waker }) {
            wakers.append(WeakWaker(ref: waker))
        }
        lock.unlock()
    }
}

/// Thread-safe, latest-wins observable property source (`rune::Live<T>`).
///
/// Bound elements read `Live<T>` directly at frame presentation time without running the app's
/// `view(state, cx)` function or re-running layout!
public struct Live<T: LiveValue>: Sendable {
    let source: LiveSource

    public init(_ initial: T) {
        let encoded = initial.encodeLiveLanes() ?? .zero
        self.source = LiveSource(initial: encoded)
    }

    init(source: LiveSource) {
        self.source = source
    }

    public func get() -> T {
        T.decodeLiveLanes(source.readSnapshot().lanes)
    }

    /// Publishes `value`, waking bound windows only if the value actually changed.
    @discardableResult
    public func set(_ value: T) -> Bool {
        guard let encoded = value.encodeLiveLanes() else { return false }
        return source.publish(encoded, snap: false)
    }

    /// Publishes `value` and snaps any `.smooth(...)` spring immediately to rest.
    @discardableResult
    public func snap(_ value: T) -> Bool {
        guard let encoded = value.encodeLiveLanes() else { return false }
        return source.publish(encoded, snap: true)
    }

    /// Pulses smoothed bindings to `active`, holds for `holdSeconds`, then settles to `rest`.
    @discardableResult
    public func pulse(active: T, rest: T, holdSeconds: Double = 0.12) -> Bool {
        guard let act = active.encodeLiveLanes(), let rst = rest.encodeLiveLanes() else { return false }
        return source.publishPulse(active: act, rest: rst, holdSeconds: max(0, holdSeconds))
    }

    /// Smooths changes with an interruptible `RuneMotion` spring while keeping `get()` exact.
    public func smooth(_ spring: Spring) -> Binding<T> {
        Binding(live: self, spring: spring, restSpring: nil)
    }

    public var binding: Binding<T> {
        Binding(live: self, spring: nil, restSpring: nil)
    }
}

/// Property binding carrying a `Live<T>` source and optional smoothing spring(s).
public struct Binding<T: LiveValue>: Sendable {
    public let live: Live<T>
    public var spring: Spring?
    public var restSpring: Spring?

    public init(live: Live<T>, spring: Spring? = nil, restSpring: Spring? = nil) {
        self.live = live
        self.spring = spring
        self.restSpring = restSpring
    }

    public func rest(_ leaveSpring: Spring) -> Binding<T> {
        var copy = self
        copy.restSpring = leaveSpring
        return copy
    }
}

/// Render-time linear tween bound like `Live<T>` (`rune::Tween<T>`).
public struct Tween<T: LiveValue>: Sendable {
    public let live: Live<T>

    public static func linear(from: T, to: T, duration: Double) -> Tween<T> {
        let a = from.encodeLiveLanes() ?? .zero
        let b = to.encodeLiveLanes() ?? .zero
        let src = LiveSource(
            initial: b,
            linearSpec: LiveSource.LinearTweenSpec(from: a, duration: max(0, duration))
        )
        return Tween(live: Live(source: src))
    }

    public var binding: Binding<T> {
        Binding(live: live, spring: nil, restSpring: nil)
    }
}

/// Latest-wins text handle for fixed-layout labels (`rune::LiveText`).
public final class LiveText: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    private(set) var sequence: UInt64 = 0
    private var wakers: [LiveSource.WeakWaker] = []

    public init(_ initial: String) {
        self.value = initial
    }

    public func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    public func set(_ newText: String) -> Bool {
        var toWake: [Waker] = []
        lock.lock()
        if value == newText {
            lock.unlock()
            return false
        }
        value = newText
        sequence &+= 1
        wakers.removeAll { $0.ref == nil }
        toWake = wakers.compactMap(\.ref)
        lock.unlock()
        for w in toWake { w.wake() }
        return true
    }

    func subscribe(_ waker: Waker) {
        lock.lock()
        wakers.removeAll { $0.ref == nil }
        if !wakers.contains(where: { $0.ref === waker }) {
            wakers.append(LiveSource.WeakWaker(ref: waker))
        }
        lock.unlock()
    }
}
