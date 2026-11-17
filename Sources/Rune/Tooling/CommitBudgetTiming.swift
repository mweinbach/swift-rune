import Foundation

// MARK: - Commit Budget timing (tooling/perf_warn/budget.rs)
//
// `RUNE_COMMIT_BUDGET_MS=N`: a line on stderr when a commit takes longer than `N` ms, with where
// its time went (view, layout, text, apply) and what made the frame commit. Off unless set, in
// any build, so it can watch a release build; while off, each phase checks one cached flag. At
// most one line a second, counting the commits it left out.

extension CommitBudget {
    /// `value` as Rust's `f64` `Display` writes it (`format!("{value}")`): the shortest decimal
    /// that reads back to the same value, never in exponent form, and an integral value without
    /// a fraction (`8`, `0.000001`, `12.3456789`, `100000000000000000000`).
    static func rustDisplay(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        let sign = value.sign == .minus ? "-" : ""
        // Swift's description is the shortest round-trip digits, sometimes with an exponent.
        let shortest = "\(value.magnitude)"
        let parts = shortest.split(separator: "e", maxSplits: 1)
        let mantissa = parts[0]
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let point = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count
        var digits = Array(mantissa.filter { $0 != "." })
        var at = point + exponent
        // Leading zeros carry no value; the point moves with them.
        while digits.count > 1, digits.first == "0" {
            digits.removeFirst()
            at -= 1
        }
        var integral: String
        var fraction: String
        if at <= 0 {
            integral = "0"
            fraction = String(repeating: "0", count: -at) + String(digits)
        } else if at >= digits.count {
            integral = String(digits) + String(repeating: "0", count: at - digits.count)
            fraction = ""
        } else {
            integral = String(digits[..<at])
            fraction = String(digits[at...])
        }
        while fraction.last == "0" { fraction.removeLast() }
        if integral.isEmpty { integral = "0" }
        if fraction.allSatisfy({ $0 == "0" }) { fraction = "" }
        if integral == "0" && fraction.isEmpty { return sign + "0" }
        return sign + integral + (fraction.isEmpty ? "" : "." + fraction)
    }
}

extension CommitBudget {
    /// The budget in ms, when `RUNE_COMMIT_BUDGET_MS` sets one (`budget()`'s `OnceLock`).
    private static let cachedBudgetMs: Double? = configuredBudgetMs()

    /// Test seam: a budget, a clock offset and a line sink in place of the environment, the
    /// wall clock and stderr, for the task that binds it. The rate limit's state lives in it, so
    /// one test's lines don't hold back another's.
    final class TestHook: @unchecked Sendable {
        let budgetMs: Double
        private let lock = NSLock()
        private var _lines: [String] = []
        private var _clockOffsetNs: UInt64 = 0
        private var _printed: (atNs: UInt64, leftOut: UInt32)?
        private var _causes: [UInt16] = []

        init(budgetMs: Double) {
            self.budgetMs = budgetMs
        }

        /// Lines the budget printed, oldest first.
        var lines: [String] {
            lock.lock(); defer { lock.unlock() }
            return _lines
        }

        /// Moves the rate limit's clock ahead (the commit's own time stays on the real clock).
        func advanceClock(byMs ms: Double) {
            lock.lock(); defer { lock.unlock() }
            _clockOffsetNs &+= UInt64(max(0, ms) * 1_000_000)
        }

        fileprivate var clockOffsetNs: UInt64 {
            lock.lock(); defer { lock.unlock() }
            return _clockOffsetNs
        }

        fileprivate var printed: (atNs: UInt64, leftOut: UInt32)? {
            get { lock.lock(); defer { lock.unlock() }; return _printed }
            set { lock.lock(); defer { lock.unlock() }; _printed = newValue }
        }

        /// The cause (`CommitWhy` bits) of every outer commit timed while bound, oldest first.
        var causes: [UInt16] {
            lock.lock(); defer { lock.unlock() }
            return _causes
        }

        fileprivate func noteCause(_ why: UInt16) {
            lock.lock(); defer { lock.unlock() }
            _causes.append(why)
        }

        fileprivate func append(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            _lines.append(line)
        }
    }

    @TaskLocal static var testHook: TestHook?

    /// The budget in force: the test hook's, else the environment's.
    @inline(__always)
    static func currentBudgetMs() -> Double? {
        if let hook = testHook { return hook.budgetMs }
        return cachedBudgetMs
    }

    /// Whether commits are timed against a budget (`budget::on`).
    @inline(__always)
    static var isOn: Bool { currentBudgetMs() != nil }

    /// This thread's phase times, the commits underway on it (one inside another counts toward
    /// the outer one), and when the last line printed with the commits it left out since.
    private final class ThreadState {
        var times = [Double](repeating: 0, count: FRAME_PHASES)
        var depth: UInt32 = 0
        var printed: (atNs: UInt64, leftOut: UInt32)?
    }

    private static let threadKey = "rune.perfWarn.commitBudget"

    private static var threadState: ThreadState {
        let dict = RuneExecutionContext.locals
        if let state = dict[threadKey] as? ThreadState { return state }
        let state = ThreadState()
        dict[threadKey] = state
        return state
    }

    /// Phase `phase` took `ms` (`budget::add`).
    static func add(_ phase: FramePhase, ms: Double) {
        let state = threadState
        guard phase.rawValue < state.times.count else { return }
        state.times[phase.rawValue] += ms
    }

    /// Times one commit, from `Commit.start()` to `Commit.end(why:)` (`budget::Commit`).
    struct Commit {
        fileprivate let begun: (startNs: UInt64, outer: Bool)?

        @inline(__always)
        static func start() -> Commit {
            guard CommitBudget.isOn else { return Commit(begun: nil) }
            let state = CommitBudget.threadState
            let outer = state.depth == 0
            state.depth += 1
            if outer {
                FrameProfiling.observe(FrameProfiling.budget, true)
                state.times = [Double](repeating: 0, count: FRAME_PHASES)
            }
            return Commit(begun: (RuneExecutionContext.uptimeNanoseconds, outer))
        }

        /// The commit is done; `why` is what made the frame commit, as `CommitWhy` bits.
        @inline(__always)
        func end(why: UInt16) {
            guard let begun else { return }
            let state = CommitBudget.threadState
            state.depth = state.depth > 0 ? state.depth - 1 : 0
            if begun.outer { FrameProfiling.observe(FrameProfiling.budget, false) }
            guard begun.outer, let budget = CommitBudget.currentBudgetMs() else { return }
            let hook = CommitBudget.testHook
            hook?.noteCause(why)
            let realNow = RuneExecutionContext.uptimeNanoseconds
            let total = Double(realNow &- begun.startNs) / 1_000_000.0
            if total <= budget { return }
            let now = realNow &+ (hook?.clockOffsetNs ?? 0)
            let printed = hook.map { $0.printed } ?? state.printed
            let leftOut: UInt32
            switch printed {
            case let (at, n)? where Double(now &- at) / 1_000_000_000.0 < 1.0:
                let next = (atNs: at, leftOut: n + 1)
                if let hook { hook.printed = next } else { state.printed = next }
                return
            case let (_, n)?:
                leftOut = n
            case nil:
                leftOut = 0
            }
            let next = (atNs: now, leftOut: UInt32(0))
            if let hook { hook.printed = next } else { state.printed = next }
            let line = CommitBudget.report(totalMs: total, budgetMs: budget, phases: state.times, why: why, leftOut: leftOut)
            if let hook {
                hook.append(line)
            } else {
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
        }
    }
}
