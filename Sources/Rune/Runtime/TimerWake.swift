import Foundation

/// Phase of a resting timer wake and the frame it asked the host for
/// (`crates/rune/src/runtime/motion/timer_wake.rs`).
public enum TimerWakeState: Sendable, Equatable {
    /// No timer wake has polled at rest yet, or a visible frame cleared the wake.
    case idle
    /// A timer poll asked the host for a frame at `at`, and the host has not served it yet.
    case asked(at: Double)
    /// The frame asked at `polledAt` ran, so timers must count from `polledAt` rather than polling again.
    case taken(polledAt: Double)
}

/// Coordinates resting background timer wakes with display-link / vsync frame delivery so a timer
/// poll never causes a duplicate poll on the very frame it requested, and timers stay paced from
/// the poll instant (`crates/rune/src/runtime/motion/timer_wake.rs`).
public struct TimerWake: Sendable, Equatable {
    public private(set) var state: TimerWakeState = .idle

    public init() {}

    /// Consumes a waiting timer wake on a visible frame.
    ///
    /// - Returns: `nil` when no timer wake asked for this frame (`idle`), `true` when the wake's
    ///   poll stands in for the frame's own poll (transitioning `.asked(at)` -> `.taken(polledAt)`),
    ///   or `false` if already taken.
    public mutating func takeFrame() -> Bool? {
        switch state {
        case .idle:
            return nil
        case .asked(let t):
            state = .taken(polledAt: t)
            return true
        case .taken:
            return false
        }
    }

    /// Returns whether the previous resting wake was already asked, or `nil` at idle.
    public func restingWake() -> Bool? {
        switch state {
        case .idle:
            return nil
        case .asked:
            return true
        case .taken:
            return false
        }
    }

    /// Records the outcome of a host resting-wake poll at `now`: when `asked` is `true`, a frame
    /// has been requested (`.asked(at: now)`); when `false`, the host declined or hid the window (`.idle`).
    public mutating func restingWakeFrame(_ asked: Bool, at now: Double) {
        if asked {
            state = .asked(at: now)
        } else {
            state = .idle
        }
    }

    /// Handles a timer poll while the window/drawable is hidden or covered (`poll_hidden`):
    /// if a frame was asked earlier, consumes it into `.taken(polledAt:)` and returns `true`;
    /// otherwise stays `.idle` and returns `false` so callers poll immediately.
    @discardableResult
    public mutating func pollHidden() -> Bool {
        switch state {
        case .idle:
            return false
        case .asked(let t):
            state = .taken(polledAt: t)
            return true
        case .taken:
            return false
        }
    }

    /// Cancels a pending timer-requested frame (e.g. window hidden before vsync fires), returning to `.idle`.
    public mutating func cancelTimerFrame() {
        if case .asked = state {
            state = .idle
        }
    }

    /// Marks the runtime back at rest so subsequent frames poll normally (`idle`).
    public mutating func resetToIdle() {
        state = .idle
    }

    /// True when the wake state is quiescent (`.idle` or already `.taken`).
    public var rests: Bool {
        switch state {
        case .idle, .taken:
            return true
        case .asked:
            return false
        }
    }

    /// Timestamp when the active timer wake polled (`t` for `.asked(at: t)` or `.taken(polledAt: t)`).
    public var polledAt: Double? {
        switch state {
        case .idle:
            return nil
        case .asked(let t), .taken(let t):
            return t
        }
    }
}

/// Deterministic scheduler + runtime wake driver modeling `crates/rune/src/runtime/timer_wake_tests.rs`.
public final class TimerWakeScheduler {
    public private(set) var clock: Double
    public private(set) var timerWake = TimerWake()
    public private(set) var pollCount: Int = 0
    private var scheduledDeadlines: [Double] = []
    private var onPoll: ((Double, inout [Double]) -> Bool)

    public init(clock: Double = 0.0, onPoll: @escaping (Double, inout [Double]) -> Bool) {
        self.clock = clock
        self.onPoll = onPoll
    }

    public func scheduleWakes(from base: Double, delays: [Double]) {
        for d in delays where d.isFinite && d >= 0 {
            scheduledDeadlines.append(base + d)
        }
        scheduledDeadlines.sort()
    }

    public func wakeDeadline() -> Double? {
        scheduledDeadlines.first
    }

    public func advance(by dt: Double) {
        clock += max(0, dt)
    }

    public func polledAt() -> Double? {
        timerWake.polledAt
    }

    /// Models a host timer wake callback (`host_wake`). Calls `onPoll` at `clock` and asks the host
    /// `shouldPresent(changed)` whether a visible frame was requested.
    @discardableResult
    public func hostWake(shouldPresent: (Bool) -> Bool) -> Bool {
        let now = wakeDeadline() ?? clock
        if now > clock {
            clock = now
        }
        scheduledDeadlines.removeAll { $0 <= clock + 1e-12 }
        pollCount += 1
        var newDelays: [Double] = []
        let changed = onPoll(clock, &newDelays)
        scheduleWakes(from: clock, delays: newDelays)
        let asked = shouldPresent(changed)
        timerWake.restingWakeFrame(asked, at: clock)
        return asked
    }

    /// Models a visible frame firing at `clock + dt` (`rt.frame(dt)`).
    public func frame(dt: Double) {
        clock += max(0, dt)
        let tookWake = timerWake.takeFrame() == true
        let baseTime = timerWake.polledAt ?? clock
        if !tookWake {
            pollCount += 1
            var newDelays: [Double] = []
            _ = onPoll(clock, &newDelays)
            scheduleWakes(from: clock, delays: newDelays)
            timerWake.resetToIdle()
        } else {
            // Re-anchor any timers scheduled on this frame to `polledAt`, then settle back to idle.
            scheduledDeadlines = scheduledDeadlines.map { max(baseTime, $0) }
            timerWake.resetToIdle()
        }
        scheduledDeadlines.removeAll { $0 <= clock - 1e-12 }
    }

    /// Models `rt.hidden_wake()`: the frame requested by a resting wake runs while hidden/covered.
    @discardableResult
    public func hiddenWake() -> Bool {
        let covered = timerWake.pollHidden()
        let dueNow = scheduledDeadlines.filter { $0 <= clock + 1e-12 }
        if !dueNow.isEmpty {
            scheduledDeadlines.removeAll { $0 <= clock + 1e-12 }
            pollCount += 1
            var newDelays: [Double] = []
            _ = onPoll(clock, &newDelays)
            scheduleWakes(from: clock, delays: newDelays)
        }
        return covered
    }

    public func cancelTimerFrame() {
        timerWake.cancelTimerFrame()
    }
}
