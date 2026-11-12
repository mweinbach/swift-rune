import Foundation

extension AnimationStore {
    /// The tracks started or retargeted between the last two `tick()` calls: the motion the
    /// last frame showed the first pose of.
    public func started() -> [TrackId] {
        tickedStarts
    }

    /// Moves every track in `ids` `secs` later on its own clock so it continues sampling `secs`
    /// behind: newly started motion holds its first pose that much longer. Each live track
    /// moves once regardless of duplicates in `ids`.
    public mutating func delay(_ ids: inout [TrackId], by secs: Double) {
        guard secs > 0.0 else { return }
        ids.sort { $0.index < $1.index }
        var last = Self.none
        for id in ids {
            let t = id.indexInt
            guard t < tMeta.count else { continue }
            let m = tMeta[t]
            if id.index == last || !m.alive || m.generation != id.generation { continue }
            last = id.index
            rebase(t, delta: secs * Double(clockScale(tClock[t])))
        }
    }
}
