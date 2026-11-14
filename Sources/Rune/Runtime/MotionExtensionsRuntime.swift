import Foundation
import RuneMotion

/// Runtime hooks bridging `El.childExit`, `El.rideTrailing`, and `LoopClock` / `El.loopOpacity` /
/// `El.loopRotation` / `El.loopSlide` / `El.cycle` / `Stagger.cascade` into `Runtime`
/// (`Sources/Rune/El/ChildExit.swift`, `RideTrailing.swift`, `MotionLoopExtensions.swift`,
/// `Sources/Rune/Runtime/LoopClock.swift`).
internal extension Runtime {
    /// Captures exiting direct-child `ChildExit` overrides before `flatNodes` is replaced by a commit.
    func collectChildExitOverrides(
        prevNodes: [FlatNode],
        newById: [NodeId: FlatNode],
        cut: Bool
    ) -> [(childId: NodeId, parentEl: El<State>)] {
        guard !cut else { return [] }
        var out: [(childId: NodeId, parentEl: El<State>)] = []
        for prevNode in prevNodes {
            guard newById[prevNode.nodeId] == nil else { continue }
            guard let prevParentIdx = prevNode.parentIndex, prevParentIdx < prevNodes.count else { continue }
            let parentId = prevNodes[prevParentIdx].nodeId
            guard let liveParent = newById[parentId],
                  !liveParent.el.hasInstantChanges,
                  liveParent.el.childExitTransition != nil else {
                continue
            }
            out.append((prevNode.nodeId, liveParent.el))
        }
        return out
    }

    /// Applies queued `ChildExit` transition overrides right before `scene.commit` removes omitted nodes.
    func applyChildExitHooks(
        _ overrides: [(childId: NodeId, parentEl: El<State>)],
        matchedStarts: [NodeId: MatchedFlightStart],
        to scene: inout Scene
    ) {
        guard !overrides.isEmpty else { return }
        let matchedRemoved = Set(matchedStarts.values.compactMap(\.fromId))
        for (childId, parentEl) in overrides where !matchedRemoved.contains(childId) {
            ChildExitHook.apply(parentEl: parentEl, childId: childId, to: &scene)
        }
    }

    /// Synchronizes `El.rideTrailing()` flags onto `Scene` before and after `scene.commit`.
    func syncRideTrailingFlags(_ nodes: [FlatNode], on scene: inout Scene) {
        for node in nodes {
            scene.setRideTrailing(node.nodeId, node.el.isRideTrailing)
        }
    }

    /// Syncs `el.looping` specs after `scene.commit` using `LoopClock`'s per-node animation lead time.
    /// `cut` (`settleAll`) only finishes finite sequences; periodic loops preserve phase across commits and settles.
    func syncMotionLoops(specs: [(id: NodeId, spec: LoopSpec)], at _: Double, cut: Bool) {
        loopRuntime.sync(
            specs: specs,
            startFor: { elSliceRenderState.loopCatchUp.loopStart(id: $0, scene: scene) },
            sceneContains: { scene.contains($0) },
            reducedMotion: reducedMotion,
            cut: cut
        )
    }

    /// Catches running periodic loop tracks up to wall-clock time when animation frames stall or sleep (`loop_clock.rs`).
    func syncMotionLoopClock(to appNow: Double, animNow: Double) {
        elSliceRenderState.loopCatchUp.catchLoopsUp(
            hostNow: appNow,
            animNow: animNow,
            timeScale: cxSettings.viewTimeScale,
            scene: scene,
            tracks: &loopRuntime.tracks
        )
    }

    /// Samples a node's active loop track (periodic/sequence tracks use `at`; `Cycle` uses unscaled
    /// wall-clock `wallNow` so it retains its cadence even when animation time is paused).
    func sampleLoopPresentation(id: NodeId, nodeSize: Vec2, at now: Double, wallNow: Double) -> LoopSampleResult? {
        loopRuntime.sample(id: id, nodeSize: nodeSize, at: now, wall: wallNow, reducedMotion: reducedMotion)
    }
    func sampleLoopPresentation(id: NodeId, nodeSize: Vec2, wallNow: Double) -> LoopSampleResult? {
        loopRuntime.sample(
            id: id,
            nodeSize: nodeSize,
            at: scene.store.nodeTime(id),
            wall: wallNow,
            reducedMotion: reducedMotion
        )
    }

    /// True when any non-sleeping loop needs frame advances (`isAnimating`).
    func hasActiveMotionLoops(at appNow: Double) -> Bool {
        _ = appNow
        if reducedMotion || !liveVisible {
            return false
        }
        return activePaintedLoopsAnimating
    }

    /// Earliest wall-clock deadline needed by any active painted `Cycle` frame interval OR delayed `LoopTrack`.
    func nextLoopWakeDeadline(after now: Double) -> Double? {
        _ = now
        if reducedMotion || !liveVisible {
            return nil
        }
        return activePaintedLoopWake
    }
}
