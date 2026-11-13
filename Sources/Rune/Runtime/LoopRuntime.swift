import Foundation
import RuneMotion

/// Sampled presentation values from an active `LoopTrack`.
struct LoopSampleResult {
    var opacity: Float = 1.0
    var rotation: Float = 0.0
    var offset: Vec2 = .zero
}

/// Tracks active `LoopSpec` / `Cycle` / `MotionSequence` presentation tracks for mounted nodes.
struct LoopRuntime {
    private var entries: [NodeId: LoopSpec] = [:]
    var tracks: [NodeId: LoopTrack] = [:]

    mutating func sync(specs: [(id: NodeId, spec: LoopSpec)], at now: Double, reducedMotion: Bool, cut: Bool) {
        _ = reducedMotion
        var seen = Set<NodeId>(minimumCapacity: specs.count)
        for (id, spec) in specs {
            seen.insert(id)
            if let existingSpec = entries[id], var existingTrack = tracks[id] {
                if existingSpec != spec {
                    existingTrack.retime(spec: spec, at: now)
                    entries[id] = spec
                    tracks[id] = existingTrack
                }
                continue
            }
            var track = LoopTrack(spec: spec, now: now)
            if cut {
                track.finish()
            }
            entries[id] = spec
            tracks[id] = track
        }
        entries = entries.filter { seen.contains($0.key) }
        tracks = tracks.filter { seen.contains($0.key) }
    }

    mutating func settleAll(at now: Double) {
        _ = now
        for id in tracks.keys {
            tracks[id]?.finish()
        }
    }

    func sample(id: NodeId, nodeSize: Vec2, at now: Double, wall: Double? = nil, reducedMotion: Bool) -> LoopSampleResult? {
        guard let spec = entries[id], let track = tracks[id] else { return nil }
        let val = track.sampleAt(now: now, wall: wall ?? now, reduced: reducedMotion)
        var res = LoopSampleResult()
        switch spec.kind {
        case .rotation:
            res.rotation = val
        case .opacity, .opacityCycle, .sequence:
            res.opacity = val
        case .slide, .slideEased:
            if let frac = track.offset(at: now, reduced: reducedMotion) {
                res.offset = Vec2(frac.x * nodeSize.x, frac.y * nodeSize.y)
            }
        }
        return res
    }

    func hasActiveLoops(at now: Double, reducedMotion: Bool) -> Bool {
        if reducedMotion {
            return false
        }
        for (id, track) in tracks {
            if case .opacityCycle = entries[id]?.kind {
                return true
            }
            if track.isActive(at: now) {
                return true
            }
        }
        return false
    }

    func nextFrameInterval(reducedMotion: Bool) -> Double? {
        var best: Double? = nil
        for (id, track) in tracks {
            if reducedMotion { continue }
            if let interval = track.frameInterval() {
                best = best.map { min($0, interval) } ?? interval
            } else if case .sequence = entries[id]?.kind {
                let step = 1.0 / 60.0
                best = best.map { min($0, step) } ?? step
            }
        }
        return best
    }
}
