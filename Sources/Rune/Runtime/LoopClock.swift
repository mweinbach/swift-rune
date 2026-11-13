import Foundation
import RuneMotion

/// Keeps periodic loop tracks aligned with both frame clock deltas and hierarchical `timeScale`
/// adjustments (`crates/rune/src/runtime/motion/loop_clock.rs`).
///
/// Upstream keeps periodic loops paced on the scaled clock: when `timeScale` changes (`scale != prevScale`)
/// or time advances under a non-unit scale (`scale != 1`), shifting `LoopTrack` timestamps by the
/// returned delta preserves phase smoothly without jumps.
public struct LoopClock: Sendable, Equatable {
    public private(set) var scale: Float
    public private(set) var clock: Double
    private var lastAppNow: Double?

    public init(scale: Float = 1.0, at now: Double = 0.0) {
        self.scale = Self.sanitizeScale(scale)
        self.clock = now
        self.lastAppNow = nil
    }

    private static func sanitizeScale(_ raw: Float) -> Float {
        guard raw.isFinite else { return 1.0 }
        return max(0.0, raw)
    }

    /// Advances the loop clock to `appNow` under `scale`, returning the `shift` delta (`appDelta - scaledDelta`)
    /// to pass to `LoopTrack.shift(by:)`.
    @discardableResult
    public mutating func step(to appNow: Double, scale newScale: Float) -> Double {
        let clampedScale = Self.sanitizeScale(newScale)
        guard let prevApp = lastAppNow else {
            lastAppNow = appNow
            clock = appNow
            scale = clampedScale
            return 0.0
        }
        let appDelta = max(0.0, appNow - prevApp)
        let scaledDelta = appDelta * Double(scale)
        clock += scaledDelta
        lastAppNow = appNow
        scale = clampedScale
        return appDelta - scaledDelta
    }

    /// Applies `step(to:scale:)` across a collection of active `LoopTrack`s in place.
    @discardableResult
    public mutating func syncTracks<K: Hashable>(
        _ tracks: inout [K: LoopTrack],
        to appNow: Double,
        scale newScale: Float
    ) -> Double {
        let shift = step(to: appNow, scale: newScale)
        if abs(shift) > 1e-12 {
            for key in Array(tracks.keys) {
                tracks[key]?.shift(by: shift)
            }
        }
        return shift
    }

    /// Resets the clock baseline (for initial cuts or settled commits).
    public mutating func reset(to appNow: Double, scale newScale: Float = 1.0) {
        self.scale = Self.sanitizeScale(newScale)
        self.clock = appNow
        self.lastAppNow = appNow
    }

    /// Earliest app-clock wake timestamp for delayed `LoopTrack`s (`pendingStart(at:)`), scaled by `timeScale`
    /// so delayed loops sleep until their actual scaled start instant (`tests/loop_sleep.rs`).
    public static func nextPendingStart<S: Sequence>(
        tracks: S,
        at now: Double,
        reducedMotion: Bool,
        timeScale: Float = 1.0
    ) -> Double? where S.Element == LoopTrack {
        guard !reducedMotion else { return nil }
        let s = Double(sanitizeScale(timeScale))
        guard s > 0 else { return nil }
        var earliest: Double? = nil
        for track in tracks {
            if let startAt = track.pendingStart(at: now) {
                let wakeAt = now + max(0.0, (startAt - now) / s)
                earliest = earliest.map { min($0, wakeAt) } ?? wakeAt
            }
        }
        return earliest
    }
}
