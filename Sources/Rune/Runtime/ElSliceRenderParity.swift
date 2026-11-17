import Foundation
import RuneMotion
import RuneRef
#if canImport(simd)
import simd
#endif

/// Test-only hook invoked mid-frame right after `commitTree(...)` finishes and before scene sampling/painting.
public enum RuntimeMidFrameHook {
    @TaskLocal public static var current: (@Sendable () -> Void)? = nil
}

internal enum ElSliceRenderConstants {
    static let staticScaleSettle: Double = 0.1
    static let loopJitter: Double = 1.0 / 30.0
}

internal struct ElNodeCacheEntry {
    var signature: UInt64
    var rasterScale: Float
    var scale: Float
    var since: Double
    var envScale: Float
    var isLivePhase: Bool
    var relBounds: SIMD4<Float>
    var commitGen: UInt64
    var paintHash: UInt64

    @inline(__always)
    static func stepScaleSettle(
        seenScale: inout Float,
        since: inout Double,
        to newScale: Float,
        now: Double,
        reset: Bool,
        poll: Bool
    ) -> Bool {
        let changed = !reset && abs(newScale - seenScale) > 1e-4
        if reset {
            seenScale = newScale
            since = -.infinity
        } else if changed {
            seenScale = newScale
            since = now
        }
        return poll && (now - since < ElSliceRenderConstants.staticScaleSettle)
    }
}

internal struct ElScaleSettle {
    var stillScale: Float
    var scale: Float
    var since: Double
    var moving: Bool
    var wasAnimated: Bool = false
    var lastAnimNow: Double
}

internal struct ElLoopCatchUpClock {
    private var lastClock: (host: Double, animEnd: Double)? = nil
    private var owed: Double = 0.0
    private(set) var lead: Double = 0.0

    mutating func reset() {
        lastClock = nil
        owed = 0.0
        lead = 0.0
    }

    mutating func keepLoopsOnClock(
        hostNow: Double,
        animNow: Double,
        leadDt: Double,
        timeScale: Float,
        scene: Scene,
        tracks: inout [NodeId: LoopTrack]
    ) {
        let clampedScale = Double(max(0.0, timeScale.isFinite ? timeScale : 1.0))
        let leadScaled = max(0.0, leadDt) * clampedScale
        lead = leadScaled
        let animEnd = animNow + leadScaled
        if let prev = lastClock {
            let wallDelta = (hostNow - prev.host) * clampedScale
            let animDelta = animEnd - prev.animEnd
            owed = max(-ElSliceRenderConstants.loopJitter, owed + wallDelta - animDelta)
            if owed > ElSliceRenderConstants.loopJitter {
                let advance = owed
                owed = 0.0
                for id in tracks.keys {
                    let nodeScale = Double(max(0.0, scene.store.nodeTimeScale(id)))
                    tracks[id]?.advance(by: advance * nodeScale)
                }
            }
        }
        lastClock = (host: hostNow, animEnd: animEnd)
    }

    mutating func catchLoopsUp(
        hostNow: Double,
        animNow: Double,
        timeScale: Float,
        scene: Scene,
        tracks: inout [NodeId: LoopTrack]
    ) {
        keepLoopsOnClock(
            hostNow: hostNow,
            animNow: animNow,
            leadDt: 0.0,
            timeScale: timeScale,
            scene: scene,
            tracks: &tracks
        )
    }

    func loopStart(id: NodeId, scene: Scene) -> Double {
        // `scene.commit(..., at: scaledCommitAt)` has already stepped `scene.store` to the
        // commit's animation clock; adding `lead` again would double-count the frame delta.
        scene.store.nodeTime(id)
    }

    mutating func loopsStepped(hostNow: Double, animEnd: Double) {
        lead = 0.0
        lastClock = (host: hostNow, animEnd: animEnd)
    }
}

internal struct ElSliceRenderState {
    var groupFadeIds: Set<NodeId> = []
    var scaleSettles: [NodeId: ElScaleSettle] = [:]
    var nodeCaches: [NodeId: ElNodeCacheEntry] = [:]
    var cacheScaleFramePending: Bool = false
    var pressRestingHitByPath: [String: (rect: MotionRect, clip: MotionRect, turn: Float)] = [:]
    var loopCatchUp = ElLoopCatchUpClock()
    var loopOffsetSyncedIds: Set<NodeId> = []
}

internal struct PreCommitGroupSnapshot {
    let presentIds: Set<NodeId>
    let exitingIds: Set<NodeId>
}

internal extension Runtime {
    // MARK: - Group Opacity (`group_opacity.rs`)

    func capturePreCommitGroupSnapshot() -> PreCommitGroupSnapshot {
        var presentIds = Set<NodeId>(minimumCapacity: flatNodes.count)
        var exitingIds = Set<NodeId>(minimumCapacity: exitingSnapshots.count)
        for node in flatNodes where scene.contains(node.nodeId) {
            presentIds.insert(node.nodeId)
            if case .exiting = scene.phase(node.nodeId) {
                exitingIds.insert(node.nodeId)
            }
        }
        for id in exitingSnapshots.keys where scene.contains(id) {
            presentIds.insert(id)
            if case .exiting = scene.phase(id) {
                exitingIds.insert(id)
            }
        }
        return PreCommitGroupSnapshot(presentIds: presentIds, exitingIds: exitingIds)
    }

    func setGroupRestAfterCommit(
        nodes: [FlatNode],
        preState: PreCommitGroupSnapshot,
        cut: Bool,
        ancestorInstants: [Bool]
    ) {
        var liveIds = Set<NodeId>(minimumCapacity: nodes.count)
        for (i, node) in nodes.enumerated() {
            let nid = node.nodeId
            liveIds.insert(nid)
            let wasPresent = preState.presentIds.contains(nid)
            let wasExiting = preState.exitingIds.contains(nid)
            let ancestorInstant = i < ancestorInstants.count ? ancestorInstants[i] : false
            let motion: Anim<Float> = node.el.opacityMotionAnim
                ?? node.el.styleSpring.map { Anim<Float>(curve: Curve.from($0)) }
                ?? Anim<Float>(curve: Curve.from(MotionTokens.DEFAULT))
            let isInstantMotion = (motion.curve == .instant)
            let restQuiet = cut || !wasPresent || wasExiting || reducedMotion || ancestorInstant || node.el.hasInstantChanges || isInstantMotion

            if let (restOp, _) = node.el.groupOpacity {
                let to = restOp.clamped(to: 0...1)
                let had = scene.store.has(nid, Props.GROUP_REST)
                elSliceRenderState.groupFadeIds.remove(nid)
                if !had {
                    if restQuiet {
                        scene.set(nid, Props.GROUP_REST, to)
                    } else {
                        scene.set(nid, Props.GROUP_REST, 1.0)
                        scene.animate(nid, Props.GROUP_REST, to: to, anim: motion)
                    }
                } else {
                    let curTarget = scene.store.target(nid, Props.GROUP_REST) ?? scene.get(nid, Props.GROUP_REST) ?? to
                    if abs(curTarget - to) > 1e-5 {
                        if restQuiet {
                            scene.set(nid, Props.GROUP_REST, to)
                        } else {
                            scene.animate(nid, Props.GROUP_REST, to: to, anim: motion)
                        }
                    } else if restQuiet {
                        scene.set(nid, Props.GROUP_REST, to)
                    }
                }
            } else if scene.store.has(nid, Props.GROUP_REST) {
                let cur = scene.get(nid, Props.GROUP_REST) ?? 1.0
                if restQuiet || (abs(cur - 1.0) <= 1e-4 && !scene.store.isAnimating(nid, Props.GROUP_REST)) {
                    scene.store.remove(nid, Props.GROUP_REST)
                    elSliceRenderState.groupFadeIds.remove(nid)
                } else {
                    let curTarget = scene.store.target(nid, Props.GROUP_REST) ?? cur
                    if abs(curTarget - 1.0) > 1e-5 || !scene.store.isAnimating(nid, Props.GROUP_REST) {
                        scene.animate(nid, Props.GROUP_REST, to: 1.0, anim: motion)
                    }
                    elSliceRenderState.groupFadeIds.insert(nid)
                }
            }
        }
        elSliceRenderState.groupFadeIds = elSliceRenderState.groupFadeIds.filter {
            scene.contains($0) && (liveIds.contains($0) || exitingSnapshots[$0] != nil)
        }
    }

    func landGroupFadesAfterFrame() {
        guard !elSliceRenderState.groupFadeIds.isEmpty else { return }
        for id in Array(elSliceRenderState.groupFadeIds) {
            if !scene.contains(id) {
                elSliceRenderState.groupFadeIds.remove(id)
            } else if !scene.store.isAnimating(id, Props.GROUP_REST) {
                scene.store.remove(id, Props.GROUP_REST)
                elSliceRenderState.groupFadeIds.remove(id)
            }
        }
    }

    func resolveGroupOpacityFactor(
        nodeId: NodeId,
        el: El<State>,
        nodePath: String,
        inheritedGroupFrac: Float
    ) -> Float {
        let restTarget: Float
        let hoveredTarget: Float
        if let (restOp, hovOp) = el.groupOpacity {
            restTarget = restOp
            hoveredTarget = hovOp
        } else if elSliceRenderState.groupFadeIds.contains(nodeId) {
            restTarget = 1.0
            hoveredTarget = 1.0
        } else {
            return 1.0
        }
        let rest = (scene.get(nodeId, Props.GROUP_REST) ?? restTarget).clamped(to: 0...1)
        let focused = isNodeKeyboardFocusWithin(nodePath)
        let hovered = (focused ? 1.0 : inheritedGroupFrac).clamped(to: 0...1)
        return (rest + (hoveredTarget - rest) * hovered).clamped(to: 0...1)
    }

    func isNodeKeyboardFocusWithin(_ path: String) -> Bool {
        guard focusVisible, let fp = focusedPath else { return false }
        return fp == path || fp.hasPrefix(path + "/")
    }

    /// Inspection helper: true when `Props.GROUP_REST` exists on `id` in `scene.store`.
    func hasGroupRestTrack(_ id: NodeId) -> Bool {
        scene.store.has(id, Props.GROUP_REST)
    }

    /// Inspection helper: true while `id` is finishing a dropped `groupOpacity` fade back to `1.0`.
    func isGroupFading(_ id: NodeId) -> Bool {
        elSliceRenderState.groupFadeIds.contains(id)
    }

    // MARK: - Picture Scale, ScaleSettle, PressScale & Exiting Live Subscriptions (`picture_scale.rs`)

    func resolveScaleSettle(
        nodeId: NodeId,
        scale sc: Float,
        isAnimated: Bool,
        animNow: Double
    ) -> (motion: PaintScaleMotion, raster: Float, moving: Bool) {
        let clampedScale = max(0.0625, sc.isFinite ? sc : 1.0)
        if reducedMotion || cxSettings.hostReducedMotion {
            let entry = ElScaleSettle(
                stillScale: clampedScale,
                scale: clampedScale,
                since: animNow,
                moving: false,
                lastAnimNow: animNow
            )
            elSliceRenderState.scaleSettles[nodeId] = entry
            return (.still, clampedScale, false)
        }
        if var entry = elSliceRenderState.scaleSettles[nodeId] {
            if abs(entry.lastAnimNow - animNow) <= 1e-9 {
                let effectiveMoving = entry.moving || isAnimated
                if effectiveMoving && !entry.moving {
                    entry.moving = true
                    entry.scale = clampedScale
                    entry.since = animNow
                    elSliceRenderState.scaleSettles[nodeId] = entry
                }
                let motion: PaintScaleMotion = effectiveMoving ? .moving : .still
                let raster = effectiveMoving ? entry.stillScale : clampedScale
                return (motion, raster, effectiveMoving)
            }
            if isAnimated {
                entry.moving = true
                entry.wasAnimated = true
                entry.scale = clampedScale
                entry.since = animNow
            } else if abs(clampedScale - entry.stillScale) > 1e-4 {
                if entry.wasAnimated {
                    entry.stillScale = clampedScale
                    entry.scale = clampedScale
                    entry.moving = false
                    entry.wasAnimated = false
                } else if abs(clampedScale - entry.scale) > 1e-4 {
                    entry.scale = clampedScale
                    entry.since = animNow
                    entry.moving = true
                    entry.wasAnimated = false
                } else if animNow - entry.since >= ElSliceRenderConstants.staticScaleSettle {
                    entry.stillScale = clampedScale
                    entry.moving = false
                } else {
                    entry.moving = true
                }
            } else {
                entry.scale = clampedScale
                entry.moving = false
                entry.wasAnimated = false
            }
            entry.lastAnimNow = animNow
            elSliceRenderState.scaleSettles[nodeId] = entry
            let motion: PaintScaleMotion = entry.moving ? .moving : .still
            let raster = entry.moving ? entry.stillScale : clampedScale
            return (motion, raster, entry.moving)
        } else {
            let entry = ElScaleSettle(
                stillScale: clampedScale,
                scale: clampedScale,
                since: animNow,
                moving: isAnimated,
                wasAnimated: isAnimated,
                lastAnimNow: animNow
            )
            elSliceRenderState.scaleSettles[nodeId] = entry
            let motion: PaintScaleMotion = isAnimated ? .moving : .still
            return (motion, clampedScale, isAnimated)
        }
    }

    func pruneScaleSettles() {
        if !elSliceRenderState.scaleSettles.isEmpty {
            elSliceRenderState.scaleSettles = elSliceRenderState.scaleSettles.filter {
                scene.contains($0.key) || nodeById[$0.key] != nil || exitingSnapshots[$0.key] != nil
            }
        }
        if !elSliceRenderState.nodeCaches.isEmpty {
            elSliceRenderState.nodeCaches = elSliceRenderState.nodeCaches.filter {
                scene.contains($0.key) || nodeById[$0.key] != nil || exitingSnapshots[$0.key] != nil
            }
        }
    }

    var hasMovingScaleSettle: Bool {
        elSliceRenderState.scaleSettles.values.contains(where: \.moving) || elSliceRenderState.cacheScaleFramePending
    }

    func recordPressRestingHit(path: String, rect: MotionRect, clip: MotionRect, turn: Float) {
        elSliceRenderState.pressRestingHitByPath[path] = (rect: rect, clip: clip, turn: turn)
    }

    func clearPressRestingHits() {
        elSliceRenderState.pressRestingHitByPath.removeAll(keepingCapacity: true)
    }

    func pressRestingContains(path: String, at pos: Vec2) -> Bool {
        guard pos.x > -9000, pos.y > -9000 else { return false }
        if let hit = elSliceRenderState.pressRestingHitByPath[path] {
            let p: Vec2
            if abs(hit.turn) > 1e-6 {
                let cx = hit.rect.left + hit.rect.width * 0.5
                let cy = hit.rect.top + hit.rect.height * 0.5
                let dx = pos.x - cx
                let dy = pos.y - cy
                let c = cosf(-hit.turn)
                let s = sinf(-hit.turn)
                p = Vec2(cx + dx * c - dy * s, cy + dx * s + dy * c)
            } else {
                p = pos
            }
            let r = intersectRects(hit.clip, hit.rect)
            return p.x >= r.left && p.x < r.right && p.y >= r.top && p.y < r.bottom
        }
        if let geom = hitGeometryByPath[path] {
            return geom.contains(pos)
        }
        if let idx = nodeByPath[path], flatNodes.indices.contains(idx) {
            let node = flatNodes[idx]
            let r = intersectRects(node.clipRect, node.targetRect)
            return pos.x >= r.left && pos.x < r.right && pos.y >= r.top && pos.y < r.bottom
        }
        return false
    }

    func syncPressScale(at now: Double, cut: Bool) {
        if now > scene.now {
            scene.setTime(now)
        }
        let reduce = reducedMotion || cxSettings.hostReducedMotion
        syncPressColorTracks(at: now, cut: cut)
        for node in flatNodes {
            let nid = node.nodeId
            guard scene.contains(nid) else { continue }
            guard let k = node.el.pressScaleFactor else {
                if scene.store.has(nid, Props.PRESS_SCALE) {
                    scene.store.remove(nid, Props.PRESS_SCALE)
                }
                continue
            }
            let isDown = !cut && !reduce && isNodePressedVisually(node, restingContains: pressRestingContains(path: node.path, at: pointerPosition))
            let target: Float = isDown ? k : 1.0
            if cut || reduce {
                if scene.store.has(nid, Props.PRESS_SCALE) {
                    scene.set(nid, Props.PRESS_SCALE, 1.0)
                }
                continue
            }
            if !scene.store.has(nid, Props.PRESS_SCALE) {
                if abs(target - 1.0) > 1e-5 {
                    scene.set(nid, Props.PRESS_SCALE, 1.0)
                    scene.animate(nid, Props.PRESS_SCALE, to: target, spring: MotionTokens.INSTANT)
                }
            } else {
                let curTarget = scene.store.target(nid, Props.PRESS_SCALE)
                if curTarget == nil || abs(curTarget! - target) > 1e-5 {
                    let sp = isDown ? MotionTokens.INSTANT : MotionTokens.POP
                    scene.animate(nid, Props.PRESS_SCALE, to: target, spring: sp)
                }
            }
        }
    }

    func cancelPressedOnScrollIfNeeded(scrollNodeIndex: Int, at now: Double) {
        guard let pp = pressedPath, let pIdx = nodeByPath[pp], flatNodes.indices.contains(pIdx) else { return }
        // Upstream `scroll_cancels_press`: a drag keeps its capture.
        guard flatNodes[pIdx].el.handlers.onDrag == nil else { return }
        var cur: Int? = pIdx
        var insideScroll = false
        while let i = cur, flatNodes.indices.contains(i) {
            if i == scrollNodeIndex {
                insideScroll = true
                break
            }
            cur = flatNodes[i].parentIndex
        }
        guard insideScroll else { return }
        pressedPath = nil
        pressedKey = nil
        syncPressScale(at: cxSettings.scaledTime(at: now), cut: false)
    }

    func pressScaleValue(for id: NodeId) -> Float {
        scene.get(id, Props.PRESS_SCALE) ?? 1.0
    }

    func rebuildLiveSubscriptionsIncludingExiting() {
        // Sources return their existing active subscription for this wake. Keep it installed
        // until replacements are present, so a concurrent publication can always notify.
        var newSubscriptions: [LiveSubscription] = []
        var seenTokens = Set<ObjectIdentifier>()
        var bindings = Set<LiveKey>()
        var tweens = Set<UInt64>()
        var sampled = false

        func subscribeNode(_ node: FlatNode, exiting: Bool) {
            if node.el.liveText != nil || (!exiting && !node.el.liveBindings.isEmpty) { sampled = true }
            if let lt = node.el.liveText {
                let oid = ObjectIdentifier(lt)
                if seenTokens.insert(oid).inserted {
                    newSubscriptions.append(lt.subscribe(liveLane.waker))
                }
            }
            for b in node.el.liveBindings {
                bindings.insert(LiveKey(path: node.path, target: b.target))
                if b.source.linearSpec != nil { tweens.insert(b.source.id) }
                if exiting { continue }
                let oid = ObjectIdentifier(b.source)
                if seenTokens.insert(oid).inserted {
                    newSubscriptions.append(b.source.subscribe(liveLane.waker))
                }
            }
            if let px = node.el.pixelsPayload {
                let oid = ObjectIdentifier(px)
                if seenTokens.insert(oid).inserted {
                    newSubscriptions.append(px.subscribe(liveLane.waker))
                }
            }
        }

        for node in flatNodes {
            subscribeNode(node, exiting: false)
        }
        for (nid, snap) in exitingSnapshots where nodeById[nid] == nil && scene.contains(nid) {
            subscribeNode(snap, exiting: true)
        }
        let retained = Set(newSubscriptions.map(ObjectIdentifier.init))
        for old in liveSubscriptions where !retained.contains(ObjectIdentifier(old)) { old.isActive = false }
        liveSubscriptions = newSubscriptions
        pruneLiveBindingTracks(keeping: bindings, tweens: tweens)
        liveLane.subscribed(sampled)
        if liveSubscriptions.isEmpty { _ = liveLane.take() }
    }

    // MARK: - Shimmer / LoopClock / `frameSplit` / `wakeDeadline` (`shimmer.rs`)

    func syncLoopOffsetsToScene(animNow _: Double) {
        for (id, track) in loopRuntime.tracks {
            let nodeTime = scene.store.nodeTime(id)
            if let frac = track.offset(at: nodeTime, reduced: reducedMotion) {
                let node = nodeById[id] ?? exitingSnapshots[id]
                let size = node?.targetRect.size ?? .zero
                let baseOffset = node?.el.offset ?? .zero
                let off = Vec2(baseOffset.x + frac.x * size.x, baseOffset.y + frac.y * size.y)
                scene.set(id, Props.OFFSET, off)
                elSliceRenderState.loopOffsetSyncedIds.insert(id)
            } else if elSliceRenderState.loopOffsetSyncedIds.remove(id) != nil {
                if scene.contains(id) {
                    let baseOffset = (nodeById[id] ?? exitingSnapshots[id])?.el.offset ?? .zero
                    scene.set(id, Props.OFFSET, baseOffset)
                }
            }
        }
        for id in Array(elSliceRenderState.loopOffsetSyncedIds) where loopRuntime.tracks[id] == nil {
            elSliceRenderState.loopOffsetSyncedIds.remove(id)
            if scene.contains(id) {
                let baseOffset = (nodeById[id] ?? exitingSnapshots[id])?.el.offset ?? .zero
                scene.set(id, Props.OFFSET, baseOffset)
            }
        }
    }

    @discardableResult
    func frameSplitImpl(catchUp: Double, dt: Double) -> Bool {
        let clampedCatchUp = max(0.0, catchUp)
        let clampedDt = max(0.0, dt)
        let t0 = currentTime
        let catchUpEnd = t0 + clampedCatchUp
        let target = catchUpEnd + clampedDt

        if clampedCatchUp > 0.0 {
            var stepClock = t0
            while let wake = nextWakeDeadline(after: stepClock), wake <= catchUpEnd + 1e-9 {
                let w = min(catchUpEnd, max(stepClock, wake))
                let animW = cxSettings.advanceClock(to: w)
                if !fitWindowState.frameHolds() {
                    lastScaledAnimNow = animW
                }
                currentTime = w
                _ = advanceGrowthRows(at: w)
                scrollStore.sample(at: lastScaledAnimNow)
                liveStore.sample(at: lastScaledAnimNow)
                scene.setTime(lastScaledAnimNow)
                elSliceRenderState.loopCatchUp.catchLoopsUp(
                    hostNow: w,
                    animNow: lastScaledAnimNow,
                    timeScale: cxSettings.viewTimeScale,
                    scene: scene,
                    tracks: &loopRuntime.tracks
                )
                let pollRan = runPoll(at: w)
                if pollRan && needsCommit {
                    commitTree(at: w, cut: forceInitialSettle, resizeSnap: userResizeNeedsCut)
                    forceInitialSettle = false
                    userResizeNeedsCut = false
                    needsCommit = false
                    hasExternalDirtyCommit = false
                    popupNeedsLayout = false
                }
                stepClock = w
                if w >= catchUpEnd - 1e-9 { break }
            }

            if stepClock < catchUpEnd - 1e-9 {
                let animC = cxSettings.advanceClock(to: catchUpEnd)
                if !fitWindowState.frameHolds() {
                    lastScaledAnimNow = animC
                }
                currentTime = catchUpEnd
                _ = advanceGrowthRows(at: catchUpEnd)
                scrollStore.sample(at: lastScaledAnimNow)
                liveStore.sample(at: lastScaledAnimNow)
                scene.setTime(lastScaledAnimNow)
                elSliceRenderState.loopCatchUp.catchLoopsUp(
                    hostNow: catchUpEnd,
                    animNow: lastScaledAnimNow,
                    timeScale: cxSettings.viewTimeScale,
                    scene: scene,
                    tracks: &loopRuntime.tracks
                )
            }
            _ = runPoll(at: catchUpEnd)
        }

        _ = frame(at: target)
        return isAnimating || needsCommit || frameHadCommitted
    }
}

public extension Runtime {
    /// Earliest future wall-clock wake deadline (`Runtime::wake_deadline`), or `nil` when idle.
    func wakeDeadline() -> Double? {
        nextWakeDeadline(after: currentTime)
    }

    /// Two-phase frame step separating wall-clock catch-up (`catchUp`) from active frame delta (`dt`)
    /// (`Runtime::frame_split`), running due timers/polls at wake deadlines before committing the frame.
    @discardableResult
    func frameSplit(catchUp: Double, dt: Double) -> Bool {
        frameSplitImpl(catchUp: catchUp, dt: dt)
    }
}

public extension El {
    /// Curve overload for `El.opacityMotion(_:)` forwarding to `ElCloseoutBuilders`.
    func opacityMotion(_ curve: Curve) -> Self {
        opacityMotion(Anim(curve: curve))
    }

    /// Curve overload for `El.scaleMotion(_:)` forwarding to `ElCloseoutBuilders`.
    func scaleMotion(_ curve: Curve) -> Self {
        scaleMotion(Anim<Vec2>(curve: curve))
    }
}
