import Foundation

extension AnimationStore {
    /// What a track is doing at this frame's time: the single source of truth shared by
    /// `tick()`, `running`, and `waitingUntil()`.
    internal enum Mode: Equatable {
        case moving
        case due
        case waiting(due: Double)
        case settled
        case frozen

        var holds: Bool {
            switch self {
            case .waiting, .settled, .frozen: return true
            case .moving, .due: return false
            }
        }
    }

    @inline(__always)
    internal func mode(_ t: Int) -> Mode {
        if frozen(t) { return .frozen }
        let trackNow = timeOf(t)
        let due = tNextDue[t]
        if tSettleAt[t] > trackNow { return .moving }
        if due > trackNow {
            return due.isFinite ? .waiting(due: due) : .settled
        }
        return .due
    }

    internal mutating func resample(_ t: Int) {
        tHeld[t] = false
    }

    /// Tracks sampled (or `set`) in the last `tick()`: what changed on screen.
    public func touched() -> [(NodeId, PropId)] {
        touchedTracks().map { ($0.1, $0.2) }
    }

    /// Tracks animating now (ticked yet or not): what is scheduled to move.
    public func active() -> [(NodeId, PropId)] {
        activeIndices.map { t in
            let m = tMeta[Int(t)]
            return (m.node, m.prop)
        }
    }

    /// When all running tracks are only holding for delayed starts, returns the store timestamp
    /// when the earliest one wakes; returns `nil` if anything is moving or nothing is waiting.
    public func waitingUntil() -> Double? {
        var first = Double.infinity
        for t in activeIndices {
            let ti = Int(t)
            switch mode(ti) {
            case .waiting(let due):
                let trackNow = timeOf(ti)
                let k = Double(clockScale(tClock[ti]))
                first = min(first, now + max(0.0, due - trackNow) / k)
            case .due:
                first = min(first, now)
            case .frozen:
                break
            case .moving, .settled:
                return nil
            }
        }
        return first.isFinite ? first : nil
    }

    /// Live tracks sampled (or `set`) in the last `tick()`, with generational track IDs.
    public func touchedTracks() -> [(TrackId, NodeId, PropId)] {
        var out: [(TrackId, NodeId, PropId)] = []
        out.reserveCapacity(touchedBuffer.count)
        for id in touchedBuffer where contains(id) {
            let m = tMeta[id.indexInt]
            out.append((id, m.node, m.prop))
        }
        return out
    }
}
