#if os(WASI)
@_spi(ExperimentalCustomExecutors) @_spi(ExperimentalScheduling) import _Concurrency

/// Swift's cooperative WASI executors normally own the thread until work and timers finish.
/// The browser instead lends its single reactor thread for a bounded turn on each frame.
final class WASIBrowserExecutor: MainExecutor, TaskExecutor, SchedulingExecutor, ExecutorFactory, @unchecked Sendable {
    static let shared = WASIBrowserExecutor()
    static var mainExecutor: any MainExecutor { shared }
    static var defaultExecutor: any TaskExecutor { shared }

    private init() {}

    private var mounted = false
    private var running = false
    private var stopped = false
    private var ready: [UInt8: ArraySlice<UnownedJob>] = [:]

    private struct Timer {
        let job: UnownedJob
        let isDue: () -> Bool
    }
    private var timers: [Timer] = []
    private var nextTimer = 0

    func install() {
        if Task.defaultExecutor !== self || MainActor.executor !== self {
            guard Task.defaultExecutor === PlatformExecutorFactory.defaultExecutor,
                  MainActor.executor === PlatformExecutorFactory.mainExecutor else { return }
            _createExecutors(factory: Self.self)
        }
        mounted = true
    }

    /// Jobs and timers belong to this WASM instance. Keep them paused across unmount so a
    /// continuation resumed between mounts can still run when the host attaches again.
    func uninstall() {
        mounted = false
        stopped = true
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let priority = job.priority.rawValue
        ready[priority, default: []].append(UnownedJob(job))
    }

    func enqueue<C: _Concurrency.Clock>(_ job: consuming ExecutorJob, at instant: C.Instant, tolerance: C.Duration?, clock: C) {
        timers.append(Timer(job: UnownedJob(job), isDue: { clock.now >= instant }))
    }

    func run() { runUntil { false } }

    func runUntil(_ condition: () -> Bool) {
        guard mounted, !running, !ready.isEmpty || !timers.isEmpty else { return }
        running = true
        stopped = false
        defer { running = false }
        let timerDeadline = ContinuousClock.now + .milliseconds(1)
        let deadline = timerDeadline + .milliseconds(1)
        // Rotate the timer cursor so far-future deadlines cannot starve later timers.
        var remaining = min(64, timers.count)
        while remaining > 0 && ContinuousClock.now < timerDeadline {
            if nextTimer >= timers.count { nextTimer = 0 }
            if timers[nextTimer].isDue() {
                let job = timers[nextTimer].job
                timers.swapAt(nextTimer, timers.count - 1)
                timers.removeLast()
                enqueue(ExecutorJob(job))
            } else { nextTimer += 1 }
            remaining -= 1
        }
        for _ in 0..<64 {
            guard !stopped, !condition(), ContinuousClock.now < deadline,
                  let priority = ready.keys.max(), let job = ready[priority]?.popFirst() else { break }
            if ready[priority]?.isEmpty == true { ready.removeValue(forKey: priority) }
            job.runSynchronously(isolatedTo: asUnownedSerialExecutor(), taskExecutor: asUnownedTaskExecutor())
        }
    }

    func stop() { stopped = true }
    func isIsolatingCurrentContext() -> Bool? { true }
}
#endif
