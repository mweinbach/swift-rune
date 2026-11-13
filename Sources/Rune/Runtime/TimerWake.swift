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

/// Event fed into `TimerWake.step(_:)` matching `TimerWakeEvent` in
/// `crates/rune/src/runtime/motion/timer_wake.rs`.
public enum TimerWakeEvent: Sendable, Equatable {
    /// A resting wake's poll ran `at` and asked for a frame.
    case asked(at: Double)
    /// A frame polls; `due` is true when a wake deadline came due since the timer's poll.
    case frame(due: Bool)
    /// The requested frame will not stand for its poll (window hid/showed or explicit wake cancel).
    case cancel
    /// A poll runs alone; no earlier poll stands for anything now.
    case pollAlone
}

/// Coordinates resting background timer wakes with display-link / vsync frame delivery so a timer
/// poll never causes a duplicate poll on the very frame it requested, and timers stay paced from
/// the poll instant (`crates/rune/src/runtime/motion/timer_wake.rs`).
public struct TimerWake: Sendable, Equatable {
    public private(set) var state: TimerWakeState = .idle

    public init() {}

    /// Advances state according to `event` and returns the associated poll timestamp:
    /// for `.frame(due: false)` from `.asked(at:)`, returns `at`; for `.cancel` from `.asked(at:)`,
    /// returns `at`; otherwise `nil` (`TimerWake::step`).
    @discardableResult
    public mutating func step(_ event: TimerWakeEvent) -> Double? {
        switch (state, event) {
        case (_, .asked(let at)):
            state = .asked(at: at)
            return nil
        case (_, .pollAlone):
            state = .idle
            return nil
        case (.asked(let at), .frame(due: false)):
            state = .taken(polledAt: at)
            return at
        case (_, .frame):
            state = .idle
            return nil
        case (.asked(let at), .cancel):
            state = .idle
            return at
        case (_, .cancel):
            return nil
        }
    }

    /// At a frame's poll: whether a timer's poll already stands for it (`TimerWake::frame_polled`).
    /// When `due` is `true`, resets to `.idle` and returns `false` so the frame polls again.
    @discardableResult
    public mutating func framePolled(due: Bool) -> Bool {
        step(.frame(due: due)) != nil
    }

    /// Returns whether the previous resting wake was already asked (`true`), already taken (`false`),
    /// or `.idle` (`nil`).
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
    /// has been requested (`.asked(at: now)`); when `false`, stays unchanged unless polling alone.
    public mutating func restingWakeFrame(_ asked: Bool, at now: Double) {
        if asked {
            _ = step(.asked(at: now))
        }
    }

    /// True when a resting wake poll is currently awaiting its frame (`.asked`).
    public var isAsked: Bool {
        if case .asked = state { return true }
        return false
    }

    /// Handles a timer poll while the window/drawable is hidden or covered (`poll_hidden`):
    /// if a frame was asked and `due` is `false`, cancels the frame request so callers schedule
    /// from the returned poll instant and returns `true`; otherwise steps `.pollAlone` and returns `false`.
    @discardableResult
    public mutating func pollHidden(due: Bool = false) -> Bool {
        if isAsked && !due {
            _ = cancelTimerFrame()
            return true
        }
        _ = step(.pollAlone)
        return false
    }

    /// Cancels a pending timer-requested frame (`cancel_timer_frame`), returning the `asked`
    /// poll timestamp whose `wake_after`s should be scheduled from `polled_at`, or `nil`.
    @discardableResult
    public mutating func cancelTimerFrame() -> Double? {
        step(.cancel)
    }

    /// Marks the runtime back at rest so subsequent frames poll normally (`idle`).
    public mutating func resetToIdle() {
        _ = step(.pollAlone)
    }

    /// True when the wake state is quiescent (`.idle` or already `.taken`).
    public var rests: Bool {
        !isAsked
    }

    /// Timestamp when the active timer wake was taken (`TimerWake::polled_at`), or while asked.
    public var takenPolledAt: Double? {
        if case .taken(let t) = state { return t }
        return nil
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
        _ = timerWake.step(.pollAlone)
        let now = wakeDeadline() ?? clock
        if now > clock {
            clock = now
        }
        scheduledDeadlines.removeAll { $0 <= clock + 1e-12 }
        pollCount += 1
        var newDelays: [Double] = []
        let changed = onPoll(clock, &newDelays)
        let asked = shouldPresent(changed)
        if asked {
            timerWake.restingWakeFrame(true, at: clock)
            pendingWakes = newDelays
        } else {
            scheduleWakes(from: clock, delays: newDelays)
        }
        return asked
    }

    private var pendingWakes: [Double] = []

    /// Models a visible frame firing at `clock + dt` (`rt.frame(dt)`).
    public func frame(dt: Double) {
        clock += max(0, dt)
        let due = scheduledDeadlines.contains { $0 <= clock + 1e-12 }
        let tookWake = timerWake.framePolled(due: due)
        let baseTime = timerWake.takenPolledAt ?? clock
        if !tookWake {
            if !pendingWakes.isEmpty {
                scheduleWakes(from: timerWake.takenPolledAt ?? clock, delays: pendingWakes)
                pendingWakes.removeAll()
            }
            scheduledDeadlines.removeAll { $0 <= clock + 1e-12 }
            pollCount += 1
            var newDelays: [Double] = []
            _ = onPoll(clock, &newDelays)
            scheduleWakes(from: clock, delays: newDelays)
        } else {
            // Re-anchor any timers held for this frame to `polledAt`.
            scheduleWakes(from: baseTime, delays: pendingWakes)
            pendingWakes.removeAll()
            scheduledDeadlines.removeAll { $0 <= clock - 1e-12 }
        }
    }

    /// Models `rt.poll_hidden()`: cancels any asked frame when no deadline is due so timers count
    /// from its `polledAt`, or otherwise runs `poll_alone`.
    @discardableResult
    public func hiddenWake() -> Bool {
        let due = scheduledDeadlines.contains { $0 <= clock + 1e-12 }
        if timerWake.isAsked && !due {
            if let polled = cancelTimerFrame() {
                scheduleWakes(from: polled, delays: pendingWakes)
                pendingWakes.removeAll()
            }
            return true
        }
        if let polled = cancelTimerFrame() {
            scheduleWakes(from: polled, delays: pendingWakes)
            pendingWakes.removeAll()
        }
        _ = timerWake.step(.pollAlone)
        scheduledDeadlines.removeAll { $0 <= clock + 1e-12 }
        pollCount += 1
        var newDelays: [Double] = []
        _ = onPoll(clock, &newDelays)
        scheduleWakes(from: clock, delays: newDelays)
        return false
    }

    @discardableResult
    public func cancelTimerFrame() -> Double? {
        timerWake.cancelTimerFrame()
    }
}
