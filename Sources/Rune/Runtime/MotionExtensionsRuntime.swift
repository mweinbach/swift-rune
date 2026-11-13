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
        guard isWindowVisibleForLoops else { return }
        elSliceRenderState.loopCatchUp.catchLoopsUp(
            hostNow: appNow,
            animNow: animNow,
            timeScale: cxSettings.viewTimeScale,
            scene: scene,
            tracks: &loopRuntime.tracks
        )
    }

    /// Samples a node's active loop track (periodic tracks sample `scene.store.nodeTime(id)`; `Cycle` uses
    /// unscaled wall-clock time so it retains its cadence even when animation time is paused).
    func sampleLoopPresentation(id: NodeId, nodeSize: Vec2, wallNow: Double) -> LoopSampleResult? {
        loopRuntime.sample(
            id: id,
            nodeSize: nodeSize,
            at: scene.store.nodeTime(id),
            wall: wallNow,
            reducedMotion: reducedMotion
        )
    }

    /// Drops exit transitions on removed subtrees that draw nothing (`springs.rs:409`).
    func skipNonPaintingExits(
        prevNodes: [FlatNode],
        newById: [NodeId: FlatNode],
        matchedStarts: [NodeId: MatchedFlightStart],
        to scene: inout Scene
    ) {
        guard !prevNodes.isEmpty else { return }
        var effectiveAlpha = [Float](repeating: 1.0, count: prevNodes.count)
        for i in prevNodes.indices {
            let parentAlpha: Float = prevNodes[i].parentIndex.flatMap { $0 < i ? effectiveAlpha[$0] : nil } ?? 1.0
            let nodeAlpha = scene.get(prevNodes[i].nodeId, Props.OPACITY) ?? prevNodes[i].el.opacity
            effectiveAlpha[i] = parentAlpha * max(0.0, nodeAlpha)
        }
        let matchedRemoved = Set(matchedStarts.values.compactMap(\.fromId))
        for (i, node) in prevNodes.enumerated() where effectiveAlpha[i] <= 0.001 {
            guard newById[node.nodeId] == nil, !matchedRemoved.contains(node.nodeId) else { continue }
            scene.setTransition(node.nodeId, .none)
        }
    }

    /// Marks loops on hidden, offscreen-clipped, unpresented, or exiting nodes as sleeping so
    /// neither `isAnimating` nor `nextWakeDeadline` keeps ticking on them (`loop_sleep.rs`).
    func updateSleepingLoopIds(from motionElements: [MotionElement]) {
        var visibleLiveIds = Set<NodeId>()
        for me in motionElements {
            guard me.is(MotionElement.LOOP) || loopRuntime.tracks[me.id] != nil else { continue }
            let visibleOk = me.visible.count >= 4 && me.visible[2] > 0.01 && me.visible[3] > 0.01
            let alphaOk = me.opacity > (0.5 / 255.0)
            let notExiting = !me.is(MotionElement.EXITING)
            if visibleOk && alphaOk && notExiting {
                visibleLiveIds.insert(me.id)
            }
        }
        var sleeping = Set<NodeId>()
        for id in loopRuntime.tracks.keys where !visibleLiveIds.contains(id) {
            sleeping.insert(id)
        }
        FxSliceMotionSideTable.shared.slot(for: self).sleepingLoopIds = sleeping
    }

    /// True when any non-sleeping loop needs frame advances (`isAnimating`).
    func hasActiveMotionLoops(at appNow: Double) -> Bool {
        guard isWindowVisibleForLoops else { return false }
        let sleeping = FxSliceMotionSideTable.shared.slot(for: self).sleepingLoopIds
        return loopRuntime.hasActiveLoops(
            nodeTime: { scene.store.nodeTime($0) },
            wall: appNow,
            reducedMotion: reducedMotion,
            excluding: sleeping
        )
    }

    /// Earliest wall-clock deadline needed by any active `Cycle` frame interval OR delayed `LoopTrack`.
    func nextLoopWakeDeadline(after now: Double) -> Double? {
        guard isWindowVisibleForLoops else { return nil }
        let sleeping = FxSliceMotionSideTable.shared.slot(for: self).sleepingLoopIds
        var best: Double? = nil
        if let loopInterval = loopRuntime.nextFrameInterval(reducedMotion: reducedMotion, excluding: sleeping) {
            best = now + loopInterval
        }
        let viewScale = Double(max(0.0, cxSettings.viewTimeScale.isFinite ? cxSettings.viewTimeScale : 1.0))
        if !reducedMotion, viewScale > 0.0 {
            for (id, track) in loopRuntime.tracks where !sleeping.contains(id) {
                let nt = scene.store.nodeTime(id)
                let ns = Double(max(0.0, scene.store.nodeTimeScale(id)))
                let effectiveScale = viewScale * ns
                guard effectiveScale > 0.0, let startAt = track.pendingStart(at: nt) else { continue }
                let wakeAt = now + max(0.0, (startAt - nt) / effectiveScale)
                best = best.map { min($0, wakeAt) } ?? wakeAt
            }
        }
        return best
    }
}
