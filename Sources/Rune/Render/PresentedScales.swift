import RuneMotion

/// Paint captures its own index maps so readers can inspect the last frame after a remount.
/// A nil slot distinguishes an unvisited node from one painted at unit scale.
struct PresentedScales {
    private struct Sample {
        var scale: Vec2
        var motion: PaintScaleMotion
    }

    private var samples: [Sample?] = []
    private var byPath: [String: Int] = [:]
    private var byId: [NodeId: Int] = [:]
    private var scaleByPath: [String: Vec2] = [:]
    private var motionById: [NodeId: PaintScaleMotion] = [:]

    init(count: Int, byPath: [String: Int], byId: [NodeId: Int], hasExits: Bool) {
        // Exits can reuse live slots and share a path with their replacement. Keep paint-order
        // writes by path and by ID whenever the committed indices cannot describe the frame.
        if !hasExits && byPath.count == count && byId.count == count {
            self.byPath = byPath
            self.byId = byId
            samples = Array(repeating: nil, count: count)
        }
    }

    init(scaleByPath: [String: Vec2] = [:], motionById: [NodeId: PaintScaleMotion] = [:]) {
        self.scaleByPath = scaleByPath
        self.motionById = motionById
    }

    mutating func record(at index: Int, path: String, id: NodeId, scale: Vec2, motion: PaintScaleMotion) {
        if samples.isEmpty {
            scaleByPath[path] = scale
            motionById[id] = motion
        } else {
            samples[index] = Sample(scale: scale, motion: motion)
        }
    }

    subscript(path: String) -> Vec2? {
        if samples.isEmpty { return scaleByPath[path] }
        guard let index = byPath[path] else { return nil }
        return samples[index]?.scale
    }

    func motion(for id: NodeId) -> PaintScaleMotion? {
        if samples.isEmpty { return motionById[id] }
        guard let index = byId[id] else { return nil }
        return samples[index]?.motion
    }
}
