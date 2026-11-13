import Foundation
import RuneMotion

// MARK: - Per-Runtime Parity Gate & Tracking State

internal final class FxSliceMotionSlot: @unchecked Sendable {
    weak var runtimeRef: AnyObject?
    var liveVisible: Bool = true
    var pressInside: Bool = false
    var previousScaleById: [NodeId: Vec2] = [:]
    var dynamicScaleIds: Set<NodeId> = []
    var groupRestWasPresent: Set<NodeId> = []
    var sleepingLoopIds: Set<NodeId> = []
    var rawNonLoopAnimating: Bool = false

    init(runtime: AnyObject) {
        self.runtimeRef = runtime
    }
}

internal final class FxSliceMotionSideTable: @unchecked Sendable {
    static let shared = FxSliceMotionSideTable()
    private let lock = NSLock()
    private var slots: [ObjectIdentifier: FxSliceMotionSlot] = [:]

    func slot(for runtime: AnyObject) -> FxSliceMotionSlot {
        let key = ObjectIdentifier(runtime)
        lock.lock()
        defer { lock.unlock() }
        if slots.count > 64 {
            slots = slots.filter { $0.value.runtimeRef != nil }
        }
        if let existing = slots[key], existing.runtimeRef === runtime {
            return existing
        }
        let created = FxSliceMotionSlot(runtime: runtime)
        slots[key] = created
        return created
    }
}

internal extension Runtime {
    var isWindowVisibleForLoops: Bool {
        get { liveVisible }
        set { FxSliceMotionSideTable.shared.slot(for: self).liveVisible = newValue }
    }

    /// Spring used by `.pressScale(...)` so held press & release bounce smoothly (`picture_scale.rs:219-267`).
    static var pressScaleSpring: Spring {
        Spring(duration: 0.18, bounce: 0.22)
    }

    /// Resting hit box used by `.pressScale(...)` so holding near an edge stays pressed even while shrunk.
    func pressScaleContains(node: FlatNode, at pos: Vec2) -> Bool {
        let restBox = intersectRects(node.clipRect, node.targetRect)
        return halfOpenContains(restBox, pos)
    }

    func updatePressInsideState(at pos: Vec2) -> Bool {
        let slot = FxSliceMotionSideTable.shared.slot(for: self)
        guard let pPath = pressedPath,
              let idx = nodeByPath[pPath],
              idx < flatNodes.count else {
            let changed = slot.pressInside
            slot.pressInside = false
            return changed
        }
        let node = flatNodes[idx]
        guard node.el.pressScaleFactor != nil else {
            guard node.el.pressBg != nil else { return false }
            let changed = !slot.pressInside
            slot.pressInside = true
            return changed
        }
        let insideNow = pressScaleContains(node: node, at: pos)
        let changed = insideNow != slot.pressInside
        slot.pressInside = insideNow
        return changed
    }

    func isPressVisuallyActive(for node: FlatNode) -> Bool {
        guard pressedPath == node.path, !node.effectiveInert else { return false }
        if node.el.pressScaleFactor != nil {
            return pressScaleContains(node: node, at: pointerPosition)
        }
        return true
    }

    func cancelPressedSubtreeIfScrolling(containerPath: String, at now: Double) {
        guard let p = pressedPath else { return }
        if p == containerPath || p.hasPrefix(containerPath + "/") {
            pressedPath = nil
            pressedKey = nil
            FxSliceMotionSideTable.shared.slot(for: self).pressInside = false
            dirtyCommit(at: now)
        }
    }

    /// Synchronizes `Props.GROUP_REST` tracks so rest changes, adding `groupOpacity` on a live node,
    /// and dropping `groupOpacity` fade smoothly unless snapped (`group_opacity.rs`).
    func syncGroupRestTracks(
        nodes: [FlatNode],
        prevMountedIds: Set<NodeId>,
        isInstantCommit: Bool,
        cut: Bool,
        at scaledNow: Double
    ) {
        let slot = FxSliceMotionSideTable.shared.slot(for: self)
        for node in nodes {
            let nid = node.nodeId
            let el = node.el
            let isFreshMount = !prevMountedIds.contains(nid)
            let snapNow = cut || reducedMotion || el.hasInstantChanges || isInstantCommit
            let motionAnim: Anim<Float> = {
                if let explicit = el.opacityMotionAnim { return explicit }
                if let sp = el.styleSpring { return Anim(curve: .spring(sp)) }
                return Anim(curve: .spring(MotionTokens.SETTLE))
            }()
            let isInstantAnim: Bool = {
                if case .instant = motionAnim.curve { return true }
                return motionAnim.curve.logicalDuration <= 0.0001 && motionAnim.delay <= 0
            }()

            if let (restOp, _) = el.groupOpacity {
                let hadGroupRest = slot.groupRestWasPresent.contains(nid)
                slot.groupRestWasPresent.insert(nid)
                if snapNow || isInstantAnim {
                    scene.store.snap(nid, Props.GROUP_REST, to: restOp)
                } else if isFreshMount {
                    scene.store.snap(nid, Props.GROUP_REST, to: restOp)
                } else if !hadGroupRest {
                    if scene.store.get(nid, Props.GROUP_REST) == nil {
                        scene.store.snap(nid, Props.GROUP_REST, to: 1.0)
                    }
                    scene.store.set(nid, Props.GROUP_REST, to: restOp, anim: motionAnim, at: scaledNow)
                } else {
                    if scene.store.get(nid, Props.GROUP_REST) == nil {
                        scene.store.snap(nid, Props.GROUP_REST, to: restOp)
                    }
                    scene.store.set(nid, Props.GROUP_REST, to: restOp, anim: motionAnim, at: scaledNow)
                }
            } else if slot.groupRestWasPresent.remove(nid) != nil || scene.store.get(nid, Props.GROUP_REST) != nil {
                if snapNow || isInstantAnim {
                    scene.store.remove(nid, Props.GROUP_REST)
                } else {
                    scene.store.set(nid, Props.GROUP_REST, to: 1.0, anim: motionAnim, at: scaledNow)
                }
            }
        }
        let liveIds = Set(nodes.map(\.nodeId))
        slot.groupRestWasPresent = slot.groupRestWasPresent.intersection(liveIds)
    }

    /// Computes effective `groupOpacity` multiplier incorporating any active `Props.GROUP_REST` fade-back.
    func resolvedGroupRestFactor(id: NodeId, el: El<State>, inheritedGroupFrac: Float) -> Float {
        if let (restOp, hovOp) = el.groupOpacity {
            let effRest = scene.store.get(id, Props.GROUP_REST) ?? restOp
            return effRest + (hovOp - effRest) * inheritedGroupFrac
        }
        if let fadingRest = scene.store.get(id, Props.GROUP_REST) {
            return fadingRest + (1.0 - fadingRest) * inheritedGroupFrac
        }
        return 1.0
    }

    /// Removes `Props.GROUP_REST` tracks that have finished fading back to `1.0` after `groupOpacity` was dropped.
    func pruneSettledGroupRestTracks() {
        for node in flatNodes where node.el.groupOpacity == nil {
            let nid = node.nodeId
            guard let v = scene.store.get(nid, Props.GROUP_REST) else { continue }
            if !scene.store.isMoving(nid, Props.GROUP_REST) && abs(v - 1.0) <= 1e-4 {
                scene.store.remove(nid, Props.GROUP_REST)
            }
        }
    }

    /// Computes effective scaled-text rasterization scale (`basePixelScale * scale` when settled at a
    /// non-unit scale; `basePixelScale` while dynamically scaling so `GlyphAtlas` stays bounded).
    func observeTextScale(nodeId: NodeId, scaleVec: Vec2) {
        FxSliceMotionSideTable.shared.slot(for: self).previousScaleById[nodeId] = scaleVec
    }

    func effectiveTextRasterScale(
        nodeId: NodeId,
        scaleVec: Vec2,
        isMoving: Bool,
        basePixelScale: Float
    ) -> Float {
        let slot = FxSliceMotionSideTable.shared.slot(for: self)
        let prev = slot.previousScaleById[nodeId]
        slot.previousScaleById[nodeId] = scaleVec
        let changed = prev.map { abs($0.x - scaleVec.x) > 1e-4 || abs($0.y - scaleVec.y) > 1e-4 } ?? false
        guard !changed && !isMoving else { return basePixelScale }
        let s = max(abs(scaleVec.x), abs(scaleVec.y))
        guard abs(s - 1.0) > 0.02 else { return basePixelScale }
        return max(0.5, min(8.0, basePixelScale * s))
    }

    /// Converts a `[left, top, right, bottom]` text fade edge into legacy `Primitive.fade` + `fadeOrigin` (`MetalRenderer.swift:746`).
    static func primitiveFadeParams(fadeLTRB: SIMD4<Float>, boundsPx: SIMD4<Float>) -> (fade: SIMD4<Float>, origin: SIMD2<Float>)? {
        if fadeLTRB.z > 0.001 {
            return (SIMD4<Float>(-1, 0, 1.0 / max(1, fadeLTRB.z), 0), SIMD2<Float>(boundsPx.z, boundsPx.y))
        }
        if fadeLTRB.x > 0.001 {
            return (SIMD4<Float>(1, 0, 1.0 / max(1, fadeLTRB.x), 0), SIMD2<Float>(boundsPx.x, boundsPx.y))
        }
        return nil
    }

    /// Propagates cumulative `El.timeScale` down to live nodes and clears exited elements' own `timeScale`.
    func syncNodeTimeScales(nodes: [FlatNode], on scene: inout Scene) {
        var effectiveScale = [Float](repeating: 1.0, count: nodes.count)
        var liveScaleById: [NodeId: Float] = [:]
        liveScaleById.reserveCapacity(nodes.count)
        for i in nodes.indices {
            let parentScale = nodes[i].parentIndex.map { effectiveScale[$0] } ?? 1.0
            let own = nodes[i].el.elTimeScale
            let combined = max(0.0, parentScale * own)
            effectiveScale[i] = combined
            let nid = nodes[i].nodeId
            liveScaleById[nid] = combined
            if combined != 1.0 || scene.store.nodeTimeScale(nid) != 1.0 {
                let before = scene.store.nodeTime(nid)
                scene.setTimeScale(nid, combined)
                let shift = scene.store.nodeTime(nid) - before
                if shift != 0 {
                    shiftTextReveal(for: nid, by: shift)
                }
            }
        }
        // Exiting nodes drop their own `timeScale` and inherit their surviving parent's scale (`springs.rs:389`).
        for (exId, exSnap) in exitingSnapshots where liveScaleById[exId] == nil && scene.hasNode(exId) {
            var walk = exSnap.parentIndex
            var parentScale: Float = 1.0
            while let pIdx = walk, pIdx < flatNodes.count {
                let pNode = flatNodes[pIdx]
                if let ls = liveScaleById[pNode.nodeId] {
                    parentScale = ls
                    break
                }
                walk = pNode.parentIndex
            }
            if scene.store.nodeTimeScale(exId) != parentScale {
                let before = scene.store.nodeTime(exId)
                scene.setTimeScale(exId, parentScale)
                let shift = scene.store.nodeTime(exId) - before
                if shift != 0 {
                    shiftTextReveal(for: exId, by: shift)
                }
            }
        }
    }

    /// Warns when multiple mounted elements share the same `matched` / `flightId` (`springs.rs:195`).
    func duplicateMatchedWarnings(in nodes: [FlatNode]) -> [String] {
        var seen: Set<String> = []
        var warned: Set<String> = []
        var warnings: [String] = []
        for n in nodes {
            guard let fid = n.el.flightId else { continue }
            if !seen.insert(fid).inserted && warned.insert(fid).inserted {
                warnings.append("duplicate matched id \"\(fid)\": matched ids must be unique")
            }
        }
        return warnings
    }
}
