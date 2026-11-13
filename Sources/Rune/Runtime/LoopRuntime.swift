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
    struct Entry {
        var spec: LoopSpec
        var track: LoopTrack
    }

    private var entries: [NodeId: Entry] = [:]

    mutating func sync(specs: [(id: NodeId, spec: LoopSpec)], at now: Double, reducedMotion: Bool, cut: Bool) {
        _ = reducedMotion
        var seen = Set<NodeId>(minimumCapacity: specs.count)
        for (id, spec) in specs {
            seen.insert(id)
            if var existing = entries[id] {
                if existing.spec != spec {
                    existing.track.retime(spec: spec, at: now)
                    existing.spec = spec
                    entries[id] = existing
                }
                continue
            }
            var track = LoopTrack(spec: spec, now: now)
            if cut {
                track.finish()
            }
            entries[id] = Entry(spec: spec, track: track)
        }
        entries = entries.filter { seen.contains($0.key) }
    }

    mutating func settleAll(at now: Double) {
        _ = now
        for id in entries.keys {
            entries[id]?.track.finish()
        }
    }

    func sample(id: NodeId, nodeSize: Vec2, at now: Double, reducedMotion: Bool) -> LoopSampleResult? {
        guard let entry = entries[id] else { return nil }
        let val = entry.track.sampleAt(now: now, wall: now, reduced: reducedMotion)
        var res = LoopSampleResult()
        switch entry.spec.kind {
        case .rotation:
            res.rotation = val
        case .opacity, .opacityCycle, .sequence:
            res.opacity = val
        case .slide, .slideEased:
            if let frac = entry.track.offset(at: now, reduced: reducedMotion) {
                res.offset = Vec2(frac.x * nodeSize.x, frac.y * nodeSize.y)
            }
        }
        return res
    }

    func hasActiveLoops(at now: Double, reducedMotion: Bool) -> Bool {
        if reducedMotion {
            return false
        }
        for entry in entries.values {
            if entry.track.isActive(at: now) {
                return true
            }
        }
        return false
    }

    func nextFrameInterval(reducedMotion: Bool) -> Double? {
        var best: Double? = nil
        for entry in entries.values {
            if reducedMotion { continue }
            if let interval = entry.track.frameInterval() {
                best = best.map { min($0, interval) } ?? interval
            } else if case .sequence = entry.spec.kind {
                let step = 1.0 / 60.0
                best = best.map { min($0, step) } ?? step
            }
        }
        return best
    }
}
