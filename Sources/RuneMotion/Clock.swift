import Foundation

/// Animation clock supporting real display timestamps, slow-motion scaling, pause/resume,
/// and deterministic fixed-rate manual stepping for tests and headless scripts.
public struct Clock: Sendable {
    private enum Mode: Sendable {
        case display(anchorReal: Double, anchorAnim: Double)
        case manual(hz: Double)
    }

    private var mode: Mode
    private var currentAnimTime: Double
    public private(set) var scale: Double
    public private(set) var isPaused: Bool
    public private(set) var frameCount: UInt64 = 0
    private var pausedRealTime: Double?

    /// Creates a real-time display clock anchored at `now` seconds.
    public static func display(now: Double = 0.0) -> Clock {
        Clock(
            mode: .display(anchorReal: now, anchorAnim: 0.0),
            currentAnimTime: 0.0,
            scale: 1.0,
            isPaused: false,
            frameCount: 0,
            pausedRealTime: nil
        )
    }

    /// Creates a deterministic manual clock stepping at `1 / hz` seconds per `step()`.
    public static func manual(hz: Double = 60.0) -> Clock {
        Clock(
            mode: .manual(hz: max(1.0, hz)),
            currentAnimTime: 0.0,
            scale: 1.0,
            isPaused: false,
            frameCount: 0,
            pausedRealTime: nil
        )
    }

    /// Current animation time in seconds.
    public var now: Double { currentAnimTime }

    /// The manual frame interval `1 / hz`, or `nil` in display mode.
    public var frameInterval: Double? {
        if case let .manual(hz) = mode { return 1.0 / hz }
        return nil
    }

    /// Animation time for a host timestamp without advancing `now` or `frameCount`.
    public func timeAt(realNow: Double) -> Double {
        switch mode {
        case let .display(anchorReal, anchorAnim):
            if isPaused { return currentAnimTime }
            let elapsed = max(0.0, realNow - anchorReal)
            return anchorAnim + elapsed * scale
        case .manual:
            return currentAnimTime
        }
    }

    /// Jumps animation time directly to `t` (for scrubbing or deterministic tests).
    public mutating func seek(to t: Double) {
        currentAnimTime = t
        if case .display = mode {
            // Re-anchor on next sample
            mode = .display(anchorReal: pausedRealTime ?? 0.0, anchorAnim: t)
        }
    }

    /// Samples the display clock at host timestamp `realNow` (seconds), updating `now`.
    @discardableResult
    public mutating func sample(realNow: Double) -> Double {
        frameCount &+= 1
        switch mode {
        case let .display(anchorReal, anchorAnim):
            if isPaused {
                return currentAnimTime
            }
            let elapsed = max(0.0, realNow - anchorReal)
            currentAnimTime = anchorAnim + elapsed * scale
            return currentAnimTime
        case .manual:
            return currentAnimTime
        }
    }

    /// Advances a manual clock by one frame (`scale / hz`) and returns the new timestamp.
    @discardableResult
    public mutating func step() -> Double {
        frameCount &+= 1
        if isPaused { return currentAnimTime }
        if case let .manual(hz) = mode {
            currentAnimTime += scale / hz
        } else {
            currentAnimTime += scale / 60.0
        }
        return currentAnimTime
    }

    /// Advances animation time directly by `dt * scale` seconds.
    @discardableResult
    public mutating func advance(by dt: Double) -> Double {
        if isPaused || dt <= 0 { return currentAnimTime }
        currentAnimTime += dt * scale
        if case let .display(anchorReal, _) = mode {
            mode = .display(anchorReal: anchorReal + dt, anchorAnim: currentAnimTime)
        }
        return currentAnimTime
    }

    /// Changes slow-motion scale (`0.1` = 10x slower, `1.0` = real-time) without jumping running tracks.
    public mutating func setScale(_ newScale: Double, realNow: Double? = nil) {
        let clamped = max(0.0, newScale)
        if case .display = mode, let r = realNow {
            _ = sample(realNow: r)
            mode = .display(anchorReal: r, anchorAnim: currentAnimTime)
        }
        scale = clamped
    }

    public mutating func pause(realNow: Double? = nil) {
        guard !isPaused else { return }
        if let r = realNow {
            _ = sample(realNow: r)
            pausedRealTime = r
        }
        isPaused = true
    }

    public mutating func resume(realNow: Double? = nil) {
        guard isPaused else { return }
        isPaused = false
        if case .display = mode, let r = realNow {
            mode = .display(anchorReal: r, anchorAnim: currentAnimTime)
        }
        pausedRealTime = nil
    }
}
