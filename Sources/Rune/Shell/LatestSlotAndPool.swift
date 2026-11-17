import Foundation

/// Monotonically increasing attempt tag for `LatestSlot` (`rune::machine::Attempt`).
internal struct LatestAttempt: Equatable, Hashable, Sendable {
    let rawValue: UInt64
}

/// Sequence generator issuing unique `LatestAttempt` values (`rune::machine::Seq`).
internal struct LatestSeq: Sendable {
    private var counter: UInt64 = 0

    mutating func next() -> LatestAttempt {
        counter &+= 1
        return LatestAttempt(rawValue: counter)
    }
}

/// State machine tracking debounced, running, and settled requests (`rune::latest::Slot<T>`).
internal struct LatestSlot<T: Sendable>: @unchecked Sendable {
    struct Job: @unchecked Sendable {
        let attempt: LatestAttempt
        let due: Double
        let work: @Sendable () throws -> T?
    }

    enum Request {
        case settled(T?)
        case waiting(Job)
        case running(LatestAttempt)
    }

    var seq = LatestSeq()
    var request: Request = .settled(nil)
    var driven: Bool = false
    var key: AnyHashable?
    var waker: (@Sendable () -> Void)?

    init(waker: (@Sendable () -> Void)? = nil) {
        self.waker = waker
    }

    /// Whether `attempt` is the newest request and still running, so its answer may land.
    func runs(_ attempt: LatestAttempt) -> Bool {
        if case .running(let active) = request {
            return active == attempt
        }
        return false
    }

    var isPending: Bool {
        switch request {
        case .waiting, .running: return true
        case .settled: return false
        }
    }

    var settledValue: T?? {
        if case .settled(let value) = request {
            return .some(value)
        }
        return nil
    }

    /// Supersedes every earlier request, waiting until `due` and dropping any untaken answer.
    mutating func wait(due: Double, work: @escaping @Sendable () throws -> T?) {
        let attempt = seq.next()
        request = .waiting(Job(attempt: attempt, due: due, work: work))
    }

    /// Drops the newest request, running or not, and any untaken answer.
    mutating func cancel() {
        request = .settled(nil)
        key = nil
    }

    /// Transitions the waiting request into `.running` and returns its job.
    mutating func start() -> Job? {
        guard case .waiting(let job) = request else {
            return nil
        }
        request = .running(job.attempt)
        return job
    }

    /// Applies `outcome` for `attempt` if still current; returns `waker` only when a non-nil answer landed.
    @discardableResult
    mutating func land(
        _ attempt: LatestAttempt,
        _ outcome: Result<T?, Error>
    ) -> (@Sendable () -> Void)? {
        guard runs(attempt) else {
            return nil
        }
        let answer: T? = (try? outcome.get()) ?? nil
        let landed = (answer != nil)
        request = .settled(answer)
        return landed ? waker : nil
    }
}

/// Work item driven by `LatestPool` (`rune::latest::pool::Drive`).
internal protocol LatestDrive: AnyObject, Sendable {
    func drive()
}

/// Shared slot-driving wrapper shared between `Latest<T>` and `LatestPool` (`rune::latest::Inner<T>`).
internal final class LatestInner<T: Sendable>: LatestDrive, @unchecked Sendable {
    let cond = NSCondition()
    var slot: LatestSlot<T>

    init(waker: (@Sendable () -> Void)?) {
        self.slot = LatestSlot<T>(waker: waker)
    }

    func drive() {
        cond.lock()
        let started: LatestSlot<T>.Job
        while true {
            guard case .waiting(let job) = slot.request else {
                slot.driven = false
                cond.unlock()
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            if job.due <= now {
                slot.driven = false
                guard let jobToRun = slot.start() else {
                    cond.unlock()
                    return
                }
                started = jobToRun
                break
            }
            #if os(WASI)
            cond.unlock()
            WASIEventLoop.schedule(after: job.due - now) { self.drive() }
            return
            #else
            _ = cond.wait(until: Date().addingTimeInterval(job.due - now))
            #endif
        }
        cond.unlock()

        let outcome: Result<T?, Error>
        do {
            outcome = .success(try started.work())
        } catch {
            outcome = .failure(error)
        }

        cond.lock()
        let wake = slot.land(started.attempt, outcome)
        cond.unlock()
        wake?()
    }
}

/// Bounded worker thread pool for `Latest<T>` requests (`rune::latest::pool::Pool`).
internal final class LatestPool: @unchecked Sendable {
    static let maxDefaultThreads = 4
    static let defaultIdleExit: TimeInterval = 10.0

    static let shared = LatestPool(
        maxThreads: maxDefaultThreads,
        idleExit: defaultIdleExit
    )

    private let cond = NSCondition()
    private var queue = QueueDeque<any LatestDrive>()
    private var liveThreads: Int = 0
    private var idleThreads: Int = 0
    private var startedThreads: Int = 0
    private let maxThreads: Int
    private let idleExit: TimeInterval

    init(maxThreads: Int, idleExit: TimeInterval) {
        self.maxThreads = max(1, maxThreads)
        self.idleExit = max(0.001, idleExit)
    }

    func submit(_ task: any LatestDrive) {
        #if os(WASI)
        WASIEventLoop.schedule { task.drive() }
        #else
        cond.lock()
        queue.pushBack(task)
        cond.signal()
        if queue.count <= idleThreads || liveThreads >= maxThreads {
            cond.unlock()
            return
        }
        liveThreads += 1
        startedThreads += 1
        cond.unlock()

        let thread = Thread { [self] in
            self.work()
        }
        thread.name = "rune-latest"
        thread.start()
        #endif
    }

    private func work() {
        cond.lock()
        while true {
            if let task = queue.popFront() {
                cond.unlock()
                task.drive()
                cond.lock()
                continue
            }
            idleThreads += 1
            let deadline = Date().addingTimeInterval(idleExit)
            let signaled = cond.wait(until: deadline)
            idleThreads -= 1
            if (!signaled || Date() >= deadline) && queue.isEmpty {
                liveThreads -= 1
                cond.unlock()
                return
            }
        }
    }

    /// Returns `(liveThreads, startedThreads)` for pool tests.
    func threads() -> (live: Int, started: Int) {
        cond.lock()
        defer { cond.unlock() }
        return (liveThreads, startedThreads)
    }
}
