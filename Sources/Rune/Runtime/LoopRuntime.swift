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

    mutating func sync(
        specs: [(id: NodeId, spec: LoopSpec)],
        startFor: (NodeId) -> Double,
        sceneContains: (NodeId) -> Bool,
        reducedMotion: Bool,
        cut: Bool
    ) {
        _ = reducedMotion
        entries = entries.filter { sceneContains($0.key) }
        tracks = tracks.filter { sceneContains($0.key) }
        var seen = Set<NodeId>(minimumCapacity: specs.count)
        for (id, spec) in specs {
            seen.insert(id)
            let nodeStart = startFor(id)
            if let existingSpec = entries[id], var existingTrack = tracks[id] {
                if existingSpec != spec {
                    existingTrack.retime(spec: spec, at: nodeStart)
                    entries[id] = spec
                }
                existingTrack.setEnabled(true, at: nodeStart)
                if cut {
                    existingTrack.finish()
                }
                tracks[id] = existingTrack
                continue
            }
            var track = LoopTrack(spec: spec, now: nodeStart)
            if cut {
                track.finish()
            }
            entries[id] = spec
            tracks[id] = track
        }
        for id in Array(tracks.keys) where !seen.contains(id) {
            if sceneContains(id) {
                let nodeStart = startFor(id)
                tracks[id]?.setEnabled(false, at: nodeStart)
                if cut {
                    tracks[id]?.finish()
                }
            } else {
                tracks.removeValue(forKey: id)
                entries.removeValue(forKey: id)
            }
        }
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

    func phaseValue(id: NodeId, at now: Double, reducedMotion: Bool) -> Float? {
        guard let spec = entries[id], let track = tracks[id] else { return nil }
        if reducedMotion {
            if case .sequence = spec.kind {
                return Float(track.phase(at: now))
            }
            return 0.0
        }
        return Float(track.phase(at: now))
    }

    func hasActiveLoops(
        nodeTime: (NodeId) -> Double,
        wall: Double,
        reducedMotion: Bool,
        excluding sleepingIds: Set<NodeId> = []
    ) -> Bool {
        if reducedMotion {
            return false
        }
        for (id, track) in tracks where !sleepingIds.contains(id) {
            if case .opacityCycle = entries[id]?.kind {
                return true
            }
            if track.isActive(at: nodeTime(id)) {
                return true
            }
        }
        _ = wall
        return false
    }

    func isSlideActive(id: NodeId, nodeTime: Double, reducedMotion: Bool) -> Bool {
        guard !reducedMotion, let spec = entries[id], let track = tracks[id] else { return false }
        switch spec.kind {
        case .slide, .slideEased:
            return track.isActive(at: nodeTime)
        case .opacity, .opacityCycle, .rotation, .sequence:
            return false
        }
    }

    func nextFrameInterval(
        reducedMotion: Bool,
        excluding sleepingIds: Set<NodeId> = []
    ) -> Double? {
        var best: Double? = nil
        for (id, track) in tracks where !sleepingIds.contains(id) {
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
