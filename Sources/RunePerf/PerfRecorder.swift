import Foundation
#if os(WASI)
import WASILibc
#endif

/// Cross-platform state lock backed by `NSLock`.
final class PortableLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(initialState: State) {
        self.state = initialState
    }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

/// Frame presentation outcome.
public enum FrameOutcome: String, Sendable, Equatable, Codable {
    case drawn
    case unchanged
    case skipped
}

/// Fixed-size per-frame performance measurement.
public struct FrameSample: Sendable, Equatable, Codable {
    public var window: UInt64
    public var seq: UInt64
    public var outcome: FrameOutcome
    public var updateMs: Double?
    public var renderMs: Double?
    public var inputToFrameMs: Double?
    public var gpuMs: Double?
    public var allocatedBytes: UInt64?
    public var source: UInt64?
    public var timestampMs: UInt64

    public init(
        window: UInt64,
        seq: UInt64,
        outcome: FrameOutcome,
        updateMs: Double? = nil,
        renderMs: Double? = nil,
        inputToFrameMs: Double? = nil,
        gpuMs: Double? = nil,
        allocatedBytes: UInt64? = nil,
        source: UInt64? = nil,
        timestampMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000.0)
    ) {
        self.window = window
        self.seq = seq
        self.outcome = outcome
        self.updateMs = Self.sanitize(updateMs)
        self.renderMs = Self.sanitize(renderMs)
        self.inputToFrameMs = Self.sanitize(inputToFrameMs)
        self.gpuMs = Self.sanitize(gpuMs)
        self.allocatedBytes = allocatedBytes
        self.source = source
        self.timestampMs = timestampMs
    }

    /// Total CPU work (`updateMs + renderMs`) when both are available.
    public var workMs: Double? {
        guard let updateMs, let renderMs else { return nil }
        let sum = updateMs + renderMs
        return sum.isFinite ? sum : nil
    }

    /// Whether this frame exceeded 60Hz budget (~16.67ms) or 8 MiB allocation threshold.
    public var isAnomaly: Bool {
        if let work = workMs, work >= (1000.0 / 60.0) {
            return true
        }
        if let bytes = allocatedBytes, bytes >= (8 << 20) {
            return true
        }
        return false
    }

    private static func sanitize(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

/// Percentile summary over a set of numeric samples.
public struct PercentileStats: Sendable, Equatable, Codable {
    public var p50: Double
    public var p95: Double
    public var p99: Double
    public var min: Double
    public var max: Double
    public var mean: Double
    public var count: Int

    public init(
        p50: Double,
        p95: Double,
        p99: Double,
        min: Double,
        max: Double,
        mean: Double,
        count: Int
    ) {
        self.p50 = p50
        self.p95 = p95
        self.p99 = p99
        self.min = min
        self.max = max
        self.mean = mean
        self.count = count
    }

    public static func compute(from values: [Double]) -> PercentileStats? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let n = sorted.count
        func percentile(_ q: Double) -> Double {
            let index = Swift.max(0, Swift.min(n - 1, Int(ceil(Double(n) * q)) - 1))
            return sorted[index]
        }
        let sum = sorted.reduce(0.0, +)
        return PercentileStats(
            p50: percentile(0.50),
            p95: percentile(0.95),
            p99: percentile(0.99),
            min: sorted[0],
            max: sorted[n - 1],
            mean: sum / Double(n),
            count: n
        )
    }
}

/// Token representing an in-progress scoped timing span.
public struct PerfSpanToken: Sendable, Equatable {
    public let name: String
    public let category: String
    public let startNanos: UInt64
    public let tid: UInt64
    public let args: [String: String]

    public init(
        name: String,
        category: String,
        startNanos: UInt64,
        tid: UInt64,
        args: [String: String]
    ) {
        self.name = name
        self.category = category
        self.startNanos = startNanos
        self.tid = tid
        self.args = args
    }
}

/// Completed scoped timing span.
public struct CompletedSpan: Sendable, Equatable, Codable {
    public var name: String
    public var category: String
    public var startUs: UInt64
    public var durationUs: UInt64
    public var tid: UInt64
    public var args: [String: String]

    public init(
        name: String,
        category: String,
        startUs: UInt64,
        durationUs: UInt64,
        tid: UInt64,
        args: [String: String] = [:]
    ) {
        self.name = name
        self.category = category
        self.startUs = startUs
        self.durationUs = durationUs
        self.tid = tid
        self.args = args
    }
}

/// Thread-safe numeric counter.
public final class PerfCounter: @unchecked Sendable {
    public let name: String
    private let lock = PortableLock(initialState: Int64(0))

    public init(name: String, initialValue: Int64 = 0) {
        self.name = name
        lock.withLock { $0 = initialValue }
    }

    public var value: Int64 {
        lock.withLock { $0 }
    }

    @discardableResult
    public func increment(by delta: Int64 = 1) -> Int64 {
        lock.withLock {
            $0 += delta
            return $0
        }
    }

    public func set(_ newValue: Int64) {
        lock.withLock { $0 = newValue }
    }
}

/// Bounded performance recorder for frame histograms, scoped spans, and counters.
public final class PerfRecorder: @unchecked Sendable {
    public static let defaultCapacity = 600
    public static let defaultWindowMs: UInt64 = 60_000
    public static let anomalyLogsPerSecondLimit: Int = 10

    private struct State {
        var recentFrames: [FrameSample] = []
        var totalFrames: UInt64 = 0
        var anomalyCount: UInt64 = 0
        var logSuppressedCount: UInt64 = 0
        var logSecond: UInt64 = 0
        var loggedInSecond: Int = 0
        var lifetimeMaxWorkMs: Double?
        var lifetimeMaxAllocatedBytes: UInt64?
        var spans: [CompletedSpan] = []
        var counters: [String: Int64] = [:]
        var baseTimeNanos: UInt64
    }

    public let capacity: Int
    public let windowMs: UInt64
    public let maxSpans: Int
    private let lock: PortableLock<State>

    public init(
        capacity: Int = PerfRecorder.defaultCapacity,
        windowMs: UInt64 = PerfRecorder.defaultWindowMs,
        maxSpans: Int = 4096
    ) {
        self.capacity = max(1, capacity)
        self.windowMs = windowMs
        self.maxSpans = max(1, maxSpans)
        self.lock = PortableLock(
            initialState: State(baseTimeNanos: Self.uptimeNanoseconds)
        )
    }

    /// Records a frame sample into the bounded histogram window.
    public func recordFrame(_ frame: FrameSample) {
        _ = accept(frame)
    }

    /// Accepts a frame sample and returns `true` if it should be logged (anomaly within 10/s rate limit).
    /// Matches upstream `rune_perf::stats::Stats::accept`.
    @discardableResult
    public func accept(_ frame: FrameSample) -> Bool {
        lock.withLock { state in
            state.totalFrames += 1
            if let work = frame.workMs {
                state.lifetimeMaxWorkMs = state.lifetimeMaxWorkMs.map { max($0, work) } ?? work
            }
            if let alloc = frame.allocatedBytes {
                state.lifetimeMaxAllocatedBytes = state.lifetimeMaxAllocatedBytes.map { max($0, alloc) } ?? alloc
            }

            if state.recentFrames.count >= capacity {
                state.recentFrames.removeFirst(state.recentFrames.count - capacity + 1)
            }
            state.recentFrames.append(frame)

            let cutoff = frame.timestampMs > windowMs ? frame.timestampMs - windowMs : 0
            state.recentFrames.removeAll { $0.timestampMs < cutoff }

            guard frame.isAnomaly else { return false }
            state.anomalyCount += 1
            let second = frame.timestampMs / 1_000
            if state.logSecond != second {
                state.logSecond = second
                state.loggedInSecond = 0
            }
            if state.loggedInSecond >= Self.anomalyLogsPerSecondLimit {
                state.logSuppressedCount += 1
                return false
            }
            state.loggedInSecond += 1
            return true
        }
    }

    /// Prunes recent samples older than `windowMs` before `nowMs`.
    public func prune(nowMs: UInt64) {
        lock.withLock { state in
            let cutoff = nowMs > windowMs ? nowMs - windowMs : 0
            state.recentFrames.removeAll { $0.timestampMs < cutoff }
        }
    }

    /// Begins a scoped span and returns a token to pass to `endSpan(_:)`.
    public func beginSpan(
        _ name: String,
        category: String = "default",
        args: [String: String] = [:]
    ) -> PerfSpanToken {
        PerfSpanToken(
            name: name,
            category: category,
            startNanos: Self.uptimeNanoseconds,
            tid: Self.currentThreadID(),
            args: args
        )
    }

    /// Completes a scoped span and records it.
    @discardableResult
    public func endSpan(_ token: PerfSpanToken) -> CompletedSpan {
        let endNanos = Self.uptimeNanoseconds
        let durationUs = endNanos >= token.startNanos ? (endNanos - token.startNanos) / 1_000 : 0
        let span = lock.withLock { state -> CompletedSpan in
            let startUs = token.startNanos >= state.baseTimeNanos
                ? (token.startNanos - state.baseTimeNanos) / 1_000
                : 0
            let completed = CompletedSpan(
                name: token.name,
                category: token.category,
                startUs: startUs,
                durationUs: durationUs,
                tid: token.tid,
                args: token.args
            )
            if state.spans.count >= maxSpans {
                state.spans.removeFirst(state.spans.count - maxSpans + 1)
            }
            state.spans.append(completed)
            return completed
        }
        return span
    }

    /// Measures a synchronous block as a scoped span.
    public func measure<T>(
        _ name: String,
        category: String = "default",
        args: [String: String] = [:],
        _ body: () throws -> T
    ) rethrows -> T {
        let token = beginSpan(name, category: category, args: args)
        defer { _ = endSpan(token) }
        return try body()
    }

    /// Increments a named counter.
    @discardableResult
    public func incrementCounter(_ name: String, by delta: Int64 = 1) -> Int64 {
        lock.withLock { state in
            let updated = (state.counters[name] ?? 0) + delta
            state.counters[name] = updated
            return updated
        }
    }

    /// Sets a named counter value.
    public func setCounter(_ name: String, value: Int64) {
        lock.withLock { $0.counters[name] = value }
    }

    public var totalFrames: UInt64 {
        lock.withLock { $0.totalFrames }
    }

    public var anomalyCount: UInt64 {
        lock.withLock { $0.anomalyCount }
    }

    public var logSuppressedCount: UInt64 {
        lock.withLock { $0.logSuppressedCount }
    }

    public var lifetimeMaxWorkMs: Double? {
        lock.withLock { $0.lifetimeMaxWorkMs }
    }

    public var lifetimeMaxAllocatedBytes: UInt64? {
        lock.withLock { $0.lifetimeMaxAllocatedBytes }
    }

    public var recentFrames: [FrameSample] {
        lock.withLock { $0.recentFrames }
    }

    public var recentAnomalies: [FrameSample] {
        lock.withLock { state in
            Array(state.recentFrames.reversed().filter(\.isAnomaly).prefix(20))
        }
    }

    public var timedCount: Int {
        lock.withLock { state in
            state.recentFrames.filter { $0.workMs != nil }.count
        }
    }

    public var completedSpans: [CompletedSpan] {
        lock.withLock { $0.spans }
    }

    public var counters: [String: Int64] {
        lock.withLock { $0.counters }
    }

    public var workMsStats: PercentileStats? {
        let values = lock.withLock { $0.recentFrames.compactMap(\.workMs) }
        return PercentileStats.compute(from: values)
    }

    public var renderMsStats: PercentileStats? {
        let values = lock.withLock { $0.recentFrames.compactMap(\.renderMs) }
        return PercentileStats.compute(from: values)
    }

    public var updateMsStats: PercentileStats? {
        let values = lock.withLock { $0.recentFrames.compactMap(\.updateMs) }
        return PercentileStats.compute(from: values)
    }

    public var inputToFrameMsStats: PercentileStats? {
        let values = lock.withLock { $0.recentFrames.compactMap(\.inputToFrameMs) }
        return PercentileStats.compute(from: values)
    }

    public var gpuMsStats: PercentileStats? {
        let values = lock.withLock { $0.recentFrames.compactMap(\.gpuMs) }
        return PercentileStats.compute(from: values)
    }

    public var allocatedBytesStats: PercentileStats? {
        let values = lock.withLock { state in
            state.recentFrames.compactMap { $0.allocatedBytes.map(Double.init) }
        }
        return PercentileStats.compute(from: values)
    }

    public var spanDurationMsStats: PercentileStats? {
        let values = lock.withLock { $0.spans.map { Double($0.durationUs) / 1000.0 } }
        return PercentileStats.compute(from: values)
    }

    private static var uptimeNanoseconds: UInt64 {
        #if os(WASI)
        // WASI Preview 1 clock 1 is the host's monotonic clock.
        var ticks: UInt64 = 0
        guard __wasi_clock_time_get(1, 1, &ticks) == 0 else { return 0 }
        return ticks
        #else
        return DispatchTime.now().uptimeNanoseconds
        #endif
    }

    private static func currentThreadID() -> UInt64 {
        #if canImport(Darwin)
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        return tid
        #elseif os(WASI)
        return 1
        #else
        return Thread.isMainThread ? 1 : 2
        #endif
    }
}
