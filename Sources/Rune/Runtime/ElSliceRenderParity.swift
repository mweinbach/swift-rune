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
    var groupRestIds: Set<NodeId> = []
    var groupFadeIds: Set<NodeId> = []
    var scaleSettles: [NodeId: ElScaleSettle] = [:]
    var nodeCaches: [NodeId: ElNodeCacheEntry] = [:]
    var cacheScaleFramePending: Bool = false
    var pressRestingHitByPath: [String: (rect: MotionRect, clip: MotionRect, turn: Float)] = [:]
    var loopCatchUp = ElLoopCatchUpClock()
    var loopOffsetSyncedIds: Set<NodeId> = []
}

internal struct PreCommitGroupSnapshot {
    struct Item {
        let index: Int
        let wasActive: Bool
    }

    var items: [Item] = []
}

internal extension Runtime {
    // MARK: - Group Opacity (`group_opacity.rs`)

    func capturePreCommitGroupSnapshot() -> PreCommitGroupSnapshot {
        var snapshot = PreCommitGroupSnapshot()
        snapshot.items.reserveCapacity(layoutObservers.groupOpacity.count)
        flatNodes.withUnsafeBufferPointer { nodes in
            func capture(_ i: Int) {
                let phase = scene.phase(nodes[i].nodeId)
                let wasActive = switch phase {
                case .entering, .present: true
                case .exiting, nil: false
                }
                snapshot.items.append(.init(index: i, wasActive: wasActive))
            }
            for i in layoutObservers.groupOpacity { capture(i) }
            // A dropped group may still need to animate its rest track back to one.
            for id in elSliceRenderState.groupRestIds {
                if let index = nodeIndexById[id], nodes[index].el.groupOpacity == nil { capture(index) }
            }
        }
        return snapshot
    }

    func setGroupRestAfterCommit(
        nodes: [FlatNode],
        preState: PreCommitGroupSnapshot,
        cut: Bool,
        snaps: Bool,
        specs: [NodeSpec],
        ancestorInstants: [Bool]
    ) {
        func reconcile(_ node: borrowing FlatNode, _ item: PreCommitGroupSnapshot.Item) {
            let i = item.index
            let nid = node.nodeId
            let ancestorInstant = i < ancestorInstants.count ? ancestorInstants[i] : false
            let motion: Anim<Float> = node.el.opacityMotionAnim
                ?? node.el.styleSpring.map { Anim<Float>(curve: Curve.from($0)) }
                ?? Anim<Float>(curve: Curve.from(MotionTokens.DEFAULT))
            let isInstantMotion = (motion.curve == .instant)
            let snapStyle = snaps && specs[i].styleSpring == nil
            let restQuiet = cut || snapStyle || !item.wasActive || reducedMotion || ancestorInstant || node.el.hasInstantChanges || isInstantMotion

            if let (restOp, _) = node.el.groupOpacity {
                elSliceRenderState.groupRestIds.insert(nid)
                let to = restOp.clamped(to: 0...1)
                elSliceRenderState.groupFadeIds.remove(nid)
                if restQuiet {
                    scene.set(nid, Props.GROUP_REST, to)
                } else if let target = scene.store.target(nid, Props.GROUP_REST) {
                    if abs(target - to) > 1e-5 {
                        scene.animate(nid, Props.GROUP_REST, to: to, anim: motion)
                    }
                } else {
                    scene.set(nid, Props.GROUP_REST, 1.0)
                    scene.animate(nid, Props.GROUP_REST, to: to, anim: motion)
                }
            } else if scene.store.has(nid, Props.GROUP_REST) {
                let cur = scene.get(nid, Props.GROUP_REST) ?? 1.0
                if restQuiet || (abs(cur - 1.0) <= 1e-4 && !scene.store.isAnimating(nid, Props.GROUP_REST)) {
                    scene.store.remove(nid, Props.GROUP_REST)
                    elSliceRenderState.groupRestIds.remove(nid)
                    elSliceRenderState.groupFadeIds.remove(nid)
                } else {
                    let curTarget = scene.store.target(nid, Props.GROUP_REST) ?? cur
                    if abs(curTarget - 1.0) > 1e-5 || !scene.store.isAnimating(nid, Props.GROUP_REST) {
                        scene.animate(nid, Props.GROUP_REST, to: 1.0, anim: motion)
                    }
                    elSliceRenderState.groupFadeIds.insert(nid)
                }
            } else {
                elSliceRenderState.groupRestIds.remove(nid)
            }
        }
        nodes.withUnsafeBufferPointer { buffer in
            for item in preState.items { reconcile(buffer[item.index], item) }
        }
        elSliceRenderState.groupFadeIds = elSliceRenderState.groupFadeIds.filter {
            scene.contains($0) && (nodeIndexById[$0] != nil || exitingSnapshots[$0] != nil)
        }
    }

    func landGroupFadesAfterFrame() {
        guard !elSliceRenderState.groupFadeIds.isEmpty else { return }
        for id in Array(elSliceRenderState.groupFadeIds) {
            if !scene.contains(id) {
                elSliceRenderState.groupRestIds.remove(id)
                elSliceRenderState.groupFadeIds.remove(id)
            } else if !scene.store.isAnimating(id, Props.GROUP_REST) {
                scene.store.remove(id, Props.GROUP_REST)
                elSliceRenderState.groupRestIds.remove(id)
                elSliceRenderState.groupFadeIds.remove(id)
            }
        }
    }

    func resolveGroupOpacityFactor(
        nodeId: NodeId,
        group: (Float, Float)?,
        nodePath: String,
        inheritedGroupFrac: Float,
        sampledRest: @autoclosure () -> Float?
    ) -> Float {
        let restTarget: Float
        let hoveredTarget: Float
        if let (restOp, hovOp) = group {
            restTarget = restOp
            hoveredTarget = hovOp
        } else if elSliceRenderState.groupFadeIds.contains(nodeId) {
            restTarget = 1.0
            hoveredTarget = 1.0
        } else {
            return 1.0
        }
        let rest = (sampledRest() ?? restTarget).clamped(to: 0...1)
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

    /// A live zoom changes the raster bucket for the whole subtree. Only a node's own scale
    /// can promote the inherited motion to a spring, which samples its nearest still ancestor.
    func textScaleMotion(node: NodeId, local: Float, world: Float, inherited: PaintScaleMotion,
                         live: Bool, anchored: Bool, animating: Bool, at now: Double) -> PaintScaleMotion {
        let observed = resolveScaleSettle(nodeId: node, scale: anchored ? world : local,
                                         isAnimated: animating || (anchored && inherited == .moving), animNow: now,
                                         trackIdentity: anchored || live)
        guard observed.moving else { return inherited }
        return max(inherited, live || (anchored && inherited == .live) ? .live : .moving)
    }

    func resolveScaleSettle(
        nodeId: NodeId,
        scale sc: Float,
        isAnimated: Bool,
        animNow: Double,
        trackIdentity: Bool = false
    ) -> (motion: PaintScaleMotion, raster: Float, moving: Bool) {
        let prior = elSliceRenderState.scaleSettles[nodeId]
        // Identity-only nodes need no per-frame tracking. Anchors and live scale start observing
        // at identity so their text can retain its last crisp raster during a driven transition.
        if prior == nil, sc == 1, !isAnimated, !trackIdentity {
            return (.still, 1, false)
        }
        let snap = lastWasSettled || reducedMotion || cxSettings.hostReducedMotion
        if !snap, let prior, prior.lastAnimNow == animNow, prior.scale.bitPattern == sc.bitPattern,
           prior.wasAnimated == isAnimated {
            return (prior.moving ? .moving : .still, prior.stillScale, prior.moving)
        }
        let rasterScale = max(0.0625, sc.isFinite ? sc : 1)
        var entry = prior ?? ElScaleSettle(stillScale: rasterScale, scale: sc, since: -.infinity,
                                          moving: false, lastAnimNow: animNow)
        if snap || (!isAnimated && entry.wasAnimated) {
            entry.scale = sc
            entry.since = -.infinity
        } else if abs(sc - entry.scale) > 1e-5 {
            entry.scale = sc
            entry.since = animNow
        }
        entry.wasAnimated = !snap && isAnimated
        entry.moving = !snap && (isAnimated || animNow - entry.since < ElSliceRenderConstants.staticScaleSettle)
        entry.lastAnimNow = animNow
        if !entry.moving { entry.stillScale = rasterScale }
        elSliceRenderState.scaleSettles[nodeId] = entry
        return (entry.moving ? .moving : .still, entry.stillScale, entry.moving)
    }

    func pruneScaleSettles() {
        if !elSliceRenderState.scaleSettles.isEmpty {
            elSliceRenderState.scaleSettles = elSliceRenderState.scaleSettles.filter {
                scene.contains($0.key) || nodeIndexById[$0.key] != nil || exitingSnapshots[$0.key] != nil
            }
        }
        if !elSliceRenderState.nodeCaches.isEmpty {
            elSliceRenderState.nodeCaches = elSliceRenderState.nodeCaches.filter {
                scene.contains($0.key) || nodeIndexById[$0.key] != nil || exitingSnapshots[$0.key] != nil
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
        // A departing node keeps its presentation track until the scene retires it.
        // A live node that dropped the modifier must stop scaling immediately.
        for nid in pressScaleTrackOwners {
            if !scene.store.has(nid, Props.PRESS_SCALE) {
                pressScaleTrackOwners.remove(nid)
            } else if let i = nodeIndexById[nid], flatNodes[i].el.pressScaleFactor == nil, scene.contains(nid) {
                scene.store.remove(nid, Props.PRESS_SCALE)
                pressScaleTrackOwners.remove(nid)
            }
        }
        for i in layoutObservers.pressScales {
            let node = flatNodes[i]
            let nid = node.nodeId
            guard let k = node.el.pressScaleFactor, scene.contains(nid) else { continue }
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
                    pressScaleTrackOwners.insert(nid)
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
                if exiting { continue }
                if b.source.linearSpec != nil { attachLiveTween(b.source) }
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

        for index in layoutObservers.liveSources {
            subscribeNode(flatNodes[index], exiting: false)
        }
        for (nid, snap) in exitingSnapshots where nodeIndexById[nid] == nil && scene.contains(nid) {
            subscribeNode(snap, exiting: true)
        }
        let retained = Set(newSubscriptions.map(ObjectIdentifier.init))
        for old in liveSubscriptions where !retained.contains(ObjectIdentifier(old)) { old.isActive = false }
        liveSubscriptions = newSubscriptions
        pruneLiveBindingTracks(keeping: bindings)
        liveLane.subscribed(sampled)
        if liveSubscriptions.isEmpty { _ = liveLane.take() }
    }

    // MARK: - Shimmer / LoopClock / `frameSplit` / `wakeDeadline` (`shimmer.rs`)

    func syncLoopOffsetsToScene(animNow _: Double) {
        for (id, track) in loopRuntime.tracks {
            let nodeTime = scene.store.nodeTime(id)
            if let frac = track.offset(at: nodeTime, reduced: reducedMotion) {
                let node = mountedNode(id) ?? exitingSnapshots[id]
                let size = node?.targetRect.size ?? .zero
                let baseOffset = node?.el.offset ?? .zero
                let off = Vec2(baseOffset.x + frac.x * size.x, baseOffset.y + frac.y * size.y)
                scene.set(id, Props.OFFSET, off)
                elSliceRenderState.loopOffsetSyncedIds.insert(id)
            } else if elSliceRenderState.loopOffsetSyncedIds.remove(id) != nil {
                if scene.contains(id) {
                    let baseOffset = (mountedNode(id) ?? exitingSnapshots[id])?.el.offset ?? .zero
                    scene.set(id, Props.OFFSET, baseOffset)
                }
            }
        }
        for id in Array(elSliceRenderState.loopOffsetSyncedIds) where loopRuntime.tracks[id] == nil {
            elSliceRenderState.loopOffsetSyncedIds.remove(id)
            if scene.contains(id) {
                let baseOffset = (mountedNode(id) ?? exitingSnapshots[id])?.el.offset ?? .zero
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
            // Paint-owned deadlines are consumed by the final paint, never by a timer poll.
            while let wake = nextWakeDeadline(after: stepClock, includePaint: false), wake <= catchUpEnd + 1e-9 {
                let w = min(catchUpEnd, max(stepClock, wake))
                let animW = cxSettings.advanceClock(to: w)
                if !fitWindowState.frameHolds() {
                    lastScaledAnimNow = animW
                }
                currentTime = w
                _ = advanceGrowthRows(at: w, headers: foldHeaders)
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
                    commitFor(why: 0, at: w, cut: forceInitialSettle, resizeSnap: userResizeNeedsCut)
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
                _ = advanceGrowthRows(at: catchUpEnd, headers: foldHeaders)
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
