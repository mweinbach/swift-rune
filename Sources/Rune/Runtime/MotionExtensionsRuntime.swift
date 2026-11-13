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

    /// Synchronizes periodic / finite `LoopSpec`s against scaled animation time so hierarchical
    /// `cx.timeScale` changes pace loops smoothly alongside `Scene` motion.
    func syncMotionLoops(specs: [(id: NodeId, spec: LoopSpec)], at appNow: Double, cut: Bool) {
        let scaledNow = cxSettings.scaledTime(at: appNow)
        if cut {
            loopClock.reset(to: scaledNow, scale: cxSettings.viewTimeScale)
            loopRuntime.sync(specs: specs, at: scaledNow, reducedMotion: reducedMotion, cut: true)
            loopRuntime.settleAll(at: scaledNow)
            return
        }
        _ = loopClock.step(to: appNow, scale: cxSettings.viewTimeScale)
        loopRuntime.sync(specs: specs, at: scaledNow, reducedMotion: reducedMotion, cut: false)
    }

    /// Samples a node's active loop track with both scaled animation time and unscaled wall time
    /// (wall-clock `Cycle`s retain their cadence even when animation time is scaled/paused).
    func sampleLoopPresentation(id: NodeId, nodeSize: Vec2, animNow: Double, wallNow: Double) -> LoopSampleResult? {
        loopRuntime.sample(id: id, nodeSize: nodeSize, at: animNow, wall: wallNow, reducedMotion: reducedMotion)
    }

    /// True when any non-sleeping loop needs frame advances (`isAnimating`).
    func hasActiveMotionLoops(at animNow: Double) -> Bool {
        loopRuntime.hasActiveLoops(at: animNow, reducedMotion: reducedMotion)
    }

    /// Earliest wall-clock deadline needed by any active `Cycle` frame interval OR delayed `LoopTrack`
    /// (`LoopClock.nextPendingStart`) scaled back onto app wall time.
    func nextLoopWakeDeadline(after now: Double) -> Double? {
        var best: Double? = nil
        if let loopInterval = loopRuntime.nextFrameInterval(reducedMotion: reducedMotion) {
            best = now + loopInterval
        }
        let scaledNow = cxSettings.scaledTime(at: now)
        if let pendingScaled = LoopClock.nextPendingStart(
            tracks: loopRuntime.tracks.values,
            at: scaledNow,
            reducedMotion: reducedMotion,
            timeScale: cxSettings.viewTimeScale
        ) {
            let wallWake = now + max(0.0, pendingScaled - scaledNow)
            best = best.map { min($0, wallWake) } ?? wallWake
        }
        return best
    }
}
