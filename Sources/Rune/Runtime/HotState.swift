import Foundation
import RuneMotion

// MARK: - Live-Edit Hot State Inspection (`src/runtime/hot_state.rs`)

extension Runtime {
    /// Returns active scrolled node paths paired with their current vertical scroll offset (`Runtime::hot_scrolls`).
    public func hotScrolls() -> [(path: String, offset: Double)] {
        var out: [(path: String, offset: Double)] = []
        for node in flatNodes {
            if let offset = scrollOffsets[node.path] {
                out.append((node.path, Double(offset.y)))
            }
        }
        return out
    }

    /// Returns paths, current frame edges, and velocities for nodes whose frame track is animating (`Runtime::hot_motion`).
    public func hotMotion() -> [(path: String, edges: [Float], velocity: [Float])] {
        let store = scene.store
        var out: [(path: String, edges: [Float], velocity: [Float])] = []
        for node in flatNodes {
            guard store.isAnimating(node.nodeId, Props.FRAME),
                  let rect = store.sample(node.nodeId, Props.FRAME),
                  let vel = store.sampleVelocity(node.nodeId, Props.FRAME) else {
                continue
            }
            out.append((
                node.path,
                [rect.left, rect.top, rect.right, rect.bottom],
                [vel.left, vel.top, vel.right, vel.bottom]
            ))
        }
        return out
    }
}
