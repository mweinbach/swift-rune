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

    /// Synchronizes periodic / finite `LoopSpec`s with `LoopClock` so frame advances and
    /// `cx.timeScale` changes preserve periodic phase without jumps (`loop_clock.rs`).
    func syncMotionLoops(specs: [(id: NodeId, spec: LoopSpec)], at appNow: Double, cut: Bool) {
        if cut {
            loopClock.reset(to: appNow, scale: cxSettings.viewTimeScale)
            loopRuntime.sync(specs: specs, at: appNow, reducedMotion: reducedMotion, cut: true)
            loopRuntime.settleAll(at: appNow)
            return
        }
        _ = loopClock.syncTracks(&loopRuntime.tracks, to: appNow, scale: cxSettings.viewTimeScale)
        loopRuntime.sync(specs: specs, at: appNow, reducedMotion: reducedMotion, cut: false)
    }

    /// Advances `LoopClock` on frame ticks (including clean frames without layout commits) so
    /// active `LoopTrack` timestamps shift cleanly when `cx.timeScale != 1.0`.
    func syncMotionLoopClock(to appNow: Double) {
        _ = loopClock.syncTracks(&loopRuntime.tracks, to: appNow, scale: cxSettings.viewTimeScale)
    }

    /// Samples a node's active loop track (periodic tracks kept on scaled `LoopClock`; `Cycle` uses
    /// unscaled wall-clock time so it retains its cadence even when animation time is paused).
    func sampleLoopPresentation(id: NodeId, nodeSize: Vec2, wallNow: Double) -> LoopSampleResult? {
        loopRuntime.sample(id: id, nodeSize: nodeSize, at: wallNow, wall: wallNow, reducedMotion: reducedMotion)
    }

    /// True when any non-sleeping loop needs frame advances (`isAnimating`).
    func hasActiveMotionLoops(at appNow: Double) -> Bool {
        loopRuntime.hasActiveLoops(at: appNow, reducedMotion: reducedMotion)
    }

    /// Earliest wall-clock deadline needed by any active `Cycle` frame interval OR delayed `LoopTrack`
    /// (`LoopClock.nextPendingStart`).
    func nextLoopWakeDeadline(after now: Double) -> Double? {
        var best: Double? = nil
        if let loopInterval = loopRuntime.nextFrameInterval(reducedMotion: reducedMotion) {
            best = now + loopInterval
        }
        if let pendingWake = LoopClock.nextPendingStart(
            tracks: loopRuntime.tracks.values,
            at: now,
            reducedMotion: reducedMotion,
            timeScale: cxSettings.viewTimeScale
        ) {
            best = best.map { min($0, pendingWake) } ?? pendingWake
        }
        return best
    }
}
