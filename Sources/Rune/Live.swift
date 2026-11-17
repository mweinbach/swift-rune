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
        guard let lr = r.encodeLiveLanes(),
              let lg = g.encodeLiveLanes(),
              let lb = b.encodeLiveLanes(),
              let la = a.encodeLiveLanes() else { return nil }
        return MotionLanes(lr.l0, lg.l0, lb.l0, la.l0)
    }

    public static func decodeLiveLanes(_ lanes: MotionLanes) -> Color {
        Color(r: lanes.l0, g: lanes.l1, b: lanes.l2, a: lanes.l3)
    }
}

extension MotionRect: LiveValue {
    public func encodeLiveLanes() -> MotionLanes? {
        guard let ll = left.encodeLiveLanes(),
              let lt = top.encodeLiveLanes(),
              let lr = right.encodeLiveLanes(),
              let lb = bottom.encodeLiveLanes() else { return nil }
        return MotionLanes(ll.l0, lt.l0, lr.l0, lb.l0)
    }

    public static func decodeLiveLanes(_ lanes: MotionLanes) -> MotionRect {
        fromLanes(lanes)
    }
}

/// Coalescing visibility-aware wake handle for `Live` subscriptions (`rune::live::Wake`).
public final class LiveWake: @unchecked Sendable {
    private static let pendingFlag: UInt8 = 1
    private static let hiddenFlag: UInt8 = 2
    private let lock = NSLock()
    private var flags: UInt8 = 0
    private var callback: @Sendable () -> Void

    public init(_ callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }

    public func visible(_ visible: Bool) {
        _ = visibleReturningWoke(visible)
    }

    @discardableResult
    internal func visibleReturningWoke(_ visible: Bool) -> Bool {
        lock.lock()
        let old = flags
        if visible {
            flags &= ~Self.hiddenFlag
        } else {
            flags |= Self.hiddenFlag
        }
        let wake = visible && old == (Self.hiddenFlag | Self.pendingFlag) ? callback : nil
        lock.unlock()
        wake?()
        return wake != nil
    }

    public func notify() {
        lock.lock()
        let old = flags
        flags |= Self.pendingFlag
        let wake = old == 0 ? callback : nil
        lock.unlock()
        wake?()
    }

    @discardableResult
    public func takeVisible() -> Bool {
        lock.lock()
        let had = (flags & Self.pendingFlag) != 0 && (flags & Self.hiddenFlag) == 0
        if had { flags &= ~Self.pendingFlag }
        lock.unlock()
        return had
    }

    /// Keep the subscribed handle installed while the host replaces its callback. A publisher
    /// that already captured this handle still reaches the current window.
    internal func replaceCallback(dirty: Bool, _ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        self.callback = callback
        if dirty { flags |= Self.pendingFlag }
        let pending = flags == Self.pendingFlag
        lock.unlock()
        if pending { callback() }
    }

    public var isVisiblePending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flags == Self.pendingFlag
    }
}

/// Subscription handle linking a `Live` source to a `LiveWake` (`rune::live::Subscription`).
public final class LiveSubscription: @unchecked Sendable {
    public let sourceId: UInt64
    private let lock = NSLock()
    private var activeFlag: Bool = true
    weak var wake: LiveWake?

    init(sourceId: UInt64, wake: LiveWake) {
        self.sourceId = sourceId
        self.wake = wake
    }

    public var isActive: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return activeFlag
        }
        set {
            lock.lock()
            activeFlag = newValue
            lock.unlock()
        }
    }
}

private enum LiveSourceIdCounter {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var nextId: UInt64 = 1

    static func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let out = nextId
        nextId &+= 1
        return out
    }
}

enum LiveOperation: Sendable, Equatable {
    case set(MotionLanes)
    case snap(MotionLanes)
    case pulse(active: MotionLanes, rest: MotionLanes, holdSeconds: Double)
}

final class LiveSource: @unchecked Sendable {
    let id: UInt64 = LiveSourceIdCounter.next()
    private let lock = NSLock()
    private(set) var sequence: UInt64 = 0
    private(set) var lanes: MotionLanes
    private(set) var lastOp: LiveOperation
    private var wakers: [WeakWaker] = []
    private var subscriptions: [LiveSubscription] = []
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
        self.lastOp = .set(initial)
        self.linearSpec = linearSpec
    }

    func readSnapshot() -> (seq: UInt64, lanes: MotionLanes, op: LiveOperation) {
        lock.lock()
        defer { lock.unlock() }
        return (sequence, lanes, lastOp)
    }

    func publish(_ newLanes: MotionLanes, snap: Bool) -> Bool {
        var toWake: [Waker] = []
        var wakesToNotify: [LiveWake] = []
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
        subscriptions.removeAll { $0.wake == nil }
        wakesToNotify = subscriptions.compactMap { sub in
            guard sub.isActive, let w = sub.wake else { return nil }
            return w
        }
        lock.unlock()
        for w in toWake { w.wake() }
        for w in wakesToNotify { w.notify() }
        return true
    }

    func publishPulse(active: MotionLanes, rest: MotionLanes, holdSeconds: Double) -> Bool {
        var toWake: [Waker] = []
        var wakesToNotify: [LiveWake] = []
        lock.lock()
        lanes = rest
        sequence &+= 1
        lastOp = .pulse(active: active, rest: rest, holdSeconds: holdSeconds)
        wakers.removeAll { $0.ref == nil }
        toWake = wakers.compactMap(\.ref)
        subscriptions.removeAll { $0.wake == nil }
        wakesToNotify = subscriptions.compactMap { sub in
            guard sub.isActive, let w = sub.wake else { return nil }
            return w
        }
        lock.unlock()
        for w in toWake { w.wake() }
        for w in wakesToNotify { w.notify() }
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

    func subscribe(_ wake: LiveWake) -> LiveSubscription {
        lock.lock()
        subscriptions.removeAll { !$0.isActive || $0.wake == nil }
        if let existing = subscriptions.first(where: { $0.wake === wake }) {
            lock.unlock()
            return existing
        }
        let sub = LiveSubscription(sourceId: id, wake: wake)
        subscriptions.append(sub)
        lock.unlock()
        return sub
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

    public func subscribe(_ wake: LiveWake) -> LiveSubscription {
        source.subscribe(wake)
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
    private let id: UInt64 = LiveSourceIdCounter.next()
    private let lock = NSLock()
    private var value: String
    private var wakers: [LiveSource.WeakWaker] = []
    private var subscriptions: [LiveSubscription] = []

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
        var wakesToNotify: [LiveWake] = []
        lock.lock()
        if value == newText {
            lock.unlock()
            return false
        }
        value = newText
        wakers.removeAll { $0.ref == nil }
        toWake = wakers.compactMap(\.ref)
        subscriptions.removeAll { $0.wake == nil }
        wakesToNotify = subscriptions.compactMap { sub in
            guard sub.isActive, let w = sub.wake else { return nil }
            return w
        }
        lock.unlock()
        for w in toWake { w.wake() }
        for w in wakesToNotify { w.notify() }
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

    public func subscribe(_ wake: LiveWake) -> LiveSubscription {
        lock.lock()
        subscriptions.removeAll { !$0.isActive || $0.wake == nil }
        if let existing = subscriptions.first(where: { $0.wake === wake }) {
            lock.unlock()
            return existing
        }
        let sub = LiveSubscription(sourceId: id, wake: wake)
        subscriptions.append(sub)
        lock.unlock()
        return sub
    }
}
