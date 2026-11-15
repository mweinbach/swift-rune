import Foundation
import RuneMotion

private let runeHoverProp = Prop<Float>.custom(0x484F, .opacity, name: "hover")
private let runePressProp = Prop<Float>.custom(0x5052, .opacity, name: "press")

extension Runtime {
    // MARK: - Clipboard & Paste Delivery (`Runtime::use_clipboard`, `Tx::request_paste`, `El::on_paste`)

    /// Attaches an explicit `Clipboard` (typically `Clipboard(kind: .memory)` for tests) to this runtime.
    public func useClipboard(_ clipboard: Clipboard) {
        boundClipboard = clipboard
    }

    internal func writeCopyToBoundClipboard(text: String?, rich: RichClipboardPayload?) {
        guard let boundClipboard else { return }
        if let rich {
            boundClipboard.writeRich(rich)
        } else if let text {
            boundClipboard.writeText(text)
        }
    }

    // MARK: - Key Release & Step Controls (`El::on_key_up`, `El::on_step`, `El::on_step_limit`)

    /// Dispatches logical key release to press-time/current focused element + ancestors,
    /// or deepest-first within the active scope when unfocused/at-rest (`Runtime::route_key_up`).
    @discardableResult
    public func keyUp(_ ev: KeyEvent, at now: Double = 0) -> Bool {
        keyUp(ev, fromPhysicalRelease: false, at: now)
    }

    @discardableResult
    internal func keyUp(_ ev: KeyEvent, fromPhysicalRelease: Bool, at now: Double = 0) -> Bool {
        if !fromPhysicalRelease && inputMachines.keyReleases.eat(composing: isAnyImeComposing) {
            return false
        }
        let routedPressFocus = inputMachines.keyReleases.route()
        let pressedFocus = routedPressFocus ?? pressedKeyFocusPath
        if inputMachines.keyReleases.held == nil {
            pressedKeyFocusPath = nil
        }

        let activeModalIdx = activeModalPath.flatMap { nodeByPath[$0] }
        let allowedNode: (Int) -> Bool = { i in
            let n = self.flatNodes[i]
            if n.effectiveInert { return false }
            if activeModalIdx != nil && !self.modalMemberPaths.contains(n.path) { return false }
            return true
        }
        let pressedIdx = pressedFocus.flatMap { nodeByPath[$0] }.flatMap { allowedNode($0) ? $0 : nil }
        let focusedIdx = focusedPath.flatMap { nodeByPath[$0] }.flatMap { allowedNode($0) ? $0 : nil }

        var chain: [Int] = []
        for start in [pressedIdx, focusedIdx].compactMap({ $0 }) {
            var walkIdx: Int? = start
            while let cur = walkIdx, cur < flatNodes.count {
                if !allowedNode(cur) { break }
                if !chain.contains(cur) { chain.append(cur) }
                if flatNodes[cur].el.isModal { break }
                walkIdx = flatNodes[cur].parentIndex
            }
        }
        let atRest = chain.isEmpty || (activeModalIdx != nil && focusedIdx == activeModalIdx && (pressedIdx == nil || pressedIdx == focusedIdx))
        if atRest {
            for i in flatNodes.indices.reversed() where !chain.contains(i) && allowedNode(i) && flatNodes[i].el.handlers.onKeyUp != nil {
                chain.append(i)
            }
        } else if let pIdx = pressedIdx, let fIdx = focusedIdx, pIdx != fIdx {
            var sharedRank: [Int: Int] = [:]
            var walkIdx: Int? = fIdx
            var rank = 1
            while let cur = walkIdx, cur < flatNodes.count {
                sharedRank[cur] = rank
                rank += 1
                if flatNodes[cur].el.isModal { break }
                walkIdx = flatNodes[cur].parentIndex
            }
            chain.sort { (sharedRank[$0] ?? 0) < (sharedRank[$1] ?? 0) }
        }

        let physKey = inputMachines.activePhysicalKey
        for idx in chain {
            guard idx < flatNodes.count, let onUp = flatNodes[idx].el.handlers.onKeyUp else { continue }
            var tx = makeTx(at: now, physicalKey: physKey)
            let taken = onUp(&state, ev, &tx)
            _ = Tx.took(taken, &tx)
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: taken)
            if taken {
                let sec = hasSecureFocus || chain.contains(where: {
                    flatNodes[$0].el.isSecure || (flatNodes[$0].el.handlers.editLens?.get(state).isSecure == true)
                })
                recordEvent(sec ? "key-up [redacted]" : "key-up \(ev.key)")
                return true
            }
        }
        let sec = hasSecureFocus || chain.contains(where: {
            flatNodes[$0].el.isSecure || (flatNodes[$0].el.handlers.editLens?.get(state).isSecure == true)
        })
        recordEvent(sec ? "key-up [redacted]" : "key-up \(ev.key)")
        return false
    }

    internal func handleFocusedStepKey(_ ev: KeyEvent, node: FlatNode, at now: Double) -> Bool {
        guard ev.mods == .none else { return false }
        if let onStep = node.el.handlers.onStep {
            let delta: Int?
            switch ev.key {
            case .arrowLeft, .arrowDown: delta = -1
            case .arrowRight, .arrowUp: delta = 1
            case .pageDown: delta = -10
            case .pageUp: delta = 10
            default: delta = nil
            }
            if let delta {
                focusVisible = true
                var tx = makeTx(at: now)
                onStep(&state, delta, &tx)
                applyTx(tx, at: now)
                return true
            }
        }
        if let onLimit = node.el.handlers.onStepLimit {
            switch ev.key {
            case .home:
                focusVisible = true
                var tx = makeTx(at: now)
                onLimit(&state, false, &tx)
                applyTx(tx, at: now)
                return true
            case .end:
                focusVisible = true
                var tx = makeTx(at: now)
                onLimit(&state, true, &tx)
                applyTx(tx, at: now)
                return true
            default:
                break
            }
        }
        return false
    }

    // MARK: - Trackpad Gestures (`El::on_magnify`, `El::on_rotate`, `El::on_smart_magnify`)

    private func nodeContainsWindowPoint(_ idx: Int, _ windowPos: Vec2) -> Bool {
        let node = flatNodes[idx]
        if let geom = hitGeometryByPath[node.path] {
            if geom.isExiting || geom.opacity <= 0.001 { return false }
            return geom.contains(windowPos)
        }
        if node.el.opacity <= 0.001 { return false }
        let r = presentedRectByPath[node.path] ?? node.targetRect
        return halfOpenContains(intersectRects(node.clipRect, r), windowPos)
    }

    private func gestureStartIndex(at windowPos: Vec2) -> Int? {
        let hitIdx = hitTest(at: windowPos, predicate: { _ in true }).flatMap { nodeByPath[$0.node.path] }
        let scrollIdx = flatNodes.indices.reversed().first { i in
            let n = flatNodes[i]
            guard !n.el.layout.scrollAxes.isEmpty, !n.effectiveInert else { return false }
            if activeModalPath != nil && !modalMemberPaths.contains(n.path) { return false }
            return nodeContainsWindowPoint(i, windowPos)
        }
        if let h = hitIdx, let s = scrollIdx {
            var p = flatNodes[s].parentIndex
            while let cur = p {
                if cur == h { return s }
                p = flatNodes[cur].parentIndex
            }
            return h
        }
        return hitIdx ?? scrollIdx
    }

    private func dispatchGestureChain(at windowPos: Vec2, body: (FlatNode, Vec2) -> (handled: Bool, tx: Tx)?) -> Bool {
        pointerPosition = windowPos
        guard let startIdx = gestureStartIndex(at: windowPos) else { return false }
        var walkIdx: Int? = startIdx
        while let cur = walkIdx, cur < flatNodes.count {
            let node = flatNodes[cur]
            if node.effectiveInert { break }
            let local: Vec2
            if let geom = hitGeometryByPath[node.path], let lp = geom.unturnedLocalPoint(for: windowPos) {
                let scale = max(1e-4, node.inheritedScale)
                local = Vec2((lp.x - geom.rect.x) / scale, (lp.y - geom.rect.y) / scale)
            } else {
                let rect = presentedRectByPath[node.path] ?? node.targetRect
                let scale = max(1e-4, node.inheritedScale)
                local = Vec2((windowPos.x - rect.x) / scale, (windowPos.y - rect.y) / scale)
            }
            if let result = body(node, local) {
                var tx = result.tx
                let taken = Tx.took(result.handled, &tx)
                applyTx(tx, at: tx.clock, markDirtyIfNotLiveOnly: taken)
                if taken { return true }
            }
            if node.el.isModal { break }
            walkIdx = node.parentIndex
        }
        return false
    }

    /// Routes a pinch magnification gesture at `windowPos` from innermost element outward (`Runtime::magnify_event`).
    @discardableResult
    public func magnify(_ ev: MagnifyEvent, at windowPos: Vec2, now: Double = 0) -> Bool {
        dispatchGestureChain(at: windowPos) { node, local in
            guard let handler = node.el.handlers.onMagnify else { return nil }
            var localEv = ev
            localEv.x = local.x
            localEv.y = local.y
            var tx = makeTx(at: now)
            let handled = handler(&state, localEv, &tx)
            return (handled, tx)
        }
    }

    /// Routes a two-finger rotation gesture at `windowPos` from innermost element outward (`Runtime::rotate_event`).
    @discardableResult
    public func rotate(_ ev: RotateEvent, at windowPos: Vec2, now: Double = 0) -> Bool {
        dispatchGestureChain(at: windowPos) { node, local in
            guard let handler = node.el.handlers.onRotate else { return nil }
            var localEv = ev
            localEv.x = local.x
            localEv.y = local.y
            var tx = makeTx(at: now)
            let handled = handler(&state, localEv, &tx)
            return (handled, tx)
        }
    }

    /// Routes a smart-magnify tap at `windowPos` from innermost element outward (`Runtime::smart_magnify`).
    @discardableResult
    public func smartMagnify(at windowPos: Vec2, now: Double = 0) -> Bool {
        dispatchGestureChain(at: windowPos) { node, local in
            guard let handler = node.el.handlers.onSmartMagnify else { return nil }
            var tx = makeTx(at: now)
            let handled = handler(&state, local.x, local.y, &tx)
            return (handled, tx)
        }
    }

    internal static func fittedPixelsGeometry(
        box: SIMD4<Float>,
        uv: SIMD4<Float>,
        imageWidth: Float,
        imageHeight: Float,
        fit: SurfaceFit?,
        place: SurfacePlace = .centered,
        pixelScale: Float = 1.0
    ) -> (rect: SIMD4<Float>, uv: SIMD4<Float>) {
        guard let fit,
              box.z > 0.5, box.w > 0.5,
              imageWidth > 0, imageHeight > 0 else {
            return (box, uv)
        }
        let scale = max(0.5, pixelScale)
        let boxPtW = box.z / scale
        let boxPtH = box.w / scale
        let (kx, ky) = place.share
        func window(_ span: Float, _ share: Float) -> (Float, Float) {
            if share == 0.5 { return ((1.0 - span) * 0.5, (1.0 + span) * 0.5) }
            let a = (1.0 - span) * share
            return (a, a + span)
        }
        let mapUV: (Float, Float, Float, Float) -> SIMD4<Float> = { x0, y0, x1, y1 in
            let uSpan = uv.z - uv.x
            let vSpan = uv.w - uv.y
            return SIMD4<Float>(
                uv.x + x0 * uSpan,
                uv.y + y0 * vSpan,
                uv.x + x1 * uSpan,
                uv.y + y1 * vSpan
            )
        }

        if place.unscaled {
            let dw = min(imageWidth, box.z)
            let dh = min(imageHeight, box.w)
            let sx = dw / imageWidth
            let sy = dh / imageHeight
            let (x0, x1) = window(sx, kx)
            let (y0, y1) = window(sy, ky)
            let rect = SIMD4<Float>(
                box.x + (box.z - dw) * kx,
                box.y + (box.w - dh) * ky,
                dw,
                dh
            )
            return (rect, mapUV(x0, y0, x1, y1))
        }

        let imgAspect = imageWidth / imageHeight
        let boxAspect = box.z / box.w
        switch fit {
        case .fit:
            let k = min(boxPtW / imageWidth, boxPtH / imageHeight)
            let dw = (imageWidth * k).clamped(to: 1...boxPtW)
            let dh = (imageHeight * k).clamped(to: 1...boxPtH)
            let drawRect = SIMD4<Float>(
                box.x + (boxPtW - dw) * kx * scale,
                box.y + (boxPtH - dh) * ky * scale,
                dw * scale,
                dh * scale
            )
            return (drawRect, uv)
        case .fill:
            let k = max(boxPtW / imageWidth, boxPtH / imageHeight)
            let sx = boxPtW / (imageWidth * k)
            let sy = boxPtH / (imageHeight * k)
            let (x0, x1) = window(sx, kx)
            let (y0, y1) = window(sy, ky)
            return (box, mapUV(x0, y0, x1, y1))
        case .stretch:
            let _ = imgAspect == boxAspect
            return (box, uv)
        }
    }

    // MARK: - Hover Curves Inheritance & Live Hover Tracks (`El::hover_motion`, `El::hover_motion_within`)

    internal static var hoverProp: Prop<Float> { runeHoverProp }

    internal static func hoverTrackId(_ nid: NodeId) -> NodeId {
        NodeId.hash("hover:\(nid.rawValue)")
    }

    internal static var pressProp: Prop<Float> { runePressProp }

    internal static func pressTrackId(_ nid: NodeId) -> NodeId {
        NodeId.hash("press:\(nid.rawValue)")
    }

    internal func syncPressColorTracks(at now: Double, cut: Bool) {
        let snapImmediately = cut || cxSettings.hostReducedMotion
        for node in flatNodes {
            let el = node.el
            // `Visual::tracks_press`: a press fill or a press color.
            guard el.pressColor != nil || (el.pressBg?.a ?? 0) > 0 else { continue }
            let nid = node.nodeId
            let trackId = Self.pressTrackId(nid)
            let isDown = isNodePressedVisually(
                node,
                restingContains: pressRestingContains(path: node.path, at: pointerPosition)
            )
            let target: Float = isDown ? 1.0 : 0.0
            if el.pressColor == nil {
                // A press fill's track (`hover.rs::update_interaction`): ready from rest, then
                // down at once and back on a snappy spring.
                defer { lastPressTargetById[nid] = target }
                if !liveStore.has(trackId, Self.pressProp) {
                    if target == 0.0 { continue }
                    liveStore.snap(trackId, Self.pressProp, to: 0.0)
                }
                guard liveStore.target(trackId, Self.pressProp) != target else { continue }
                if snapImmediately {
                    liveStore.snap(trackId, Self.pressProp, to: target)
                } else {
                    let spring = isDown ? MotionTokens.INSTANT : MotionTokens.SNAPPY
                    liveStore.set(trackId, Self.pressProp, to: target, anim: Anim<Float>(curve: .spring(spring)), at: now)
                }
                continue
            }
            let prevTarget = lastPressTargetById[nid]
            let anim = el.styleSpring.map { Anim<Float>(curve: .spring($0)) } ?? .instant
            if snapImmediately || (el.styleSpring == nil) {
                liveStore.snap(trackId, Self.pressProp, to: target)
                lastPressTargetById[nid] = target
                continue
            }
            if prevTarget == nil {
                liveStore.snap(trackId, Self.pressProp, to: 0.0)
                if target > 0.5 {
                    liveStore.set(trackId, Self.pressProp, to: 1.0, anim: anim, at: now)
                    lastPressTargetById[nid] = 1.0
                } else {
                    lastPressTargetById[nid] = 0.0
                }
            } else if prevTarget != target {
                if liveStore.get(trackId, Self.pressProp) == nil {
                    liveStore.snap(trackId, Self.pressProp, to: prevTarget!)
                }
                liveStore.set(trackId, Self.pressProp, to: target, anim: anim, at: now)
                lastPressTargetById[nid] = target
            }
        }
        lastPressTargetById = lastPressTargetById.filter { nodeById[$0.key] != nil || exitingSnapshots[$0.key] != nil }
    }

    internal func makeGroupHoverPredicate(
        presentedRectById: [NodeId: MotionRect] = [:]
    ) -> GroupHoverContext {
        let ptrPos = pointerPosition
        let topmostPtrPath: String? = (ptrPos.x > -9000 && ptrPos.y > -9000 && !hitGeometryByPath.isEmpty)
            ? hitTest(at: ptrPos, predicate: { _ in true })?.node.path
            : nil
        var alonePath: String? = nil
        var sharedHoverKeys: Set<String> = []
        for node in flatNodes {
            if node.effectiveInert { continue }
            let inside = GroupHoverContext.isPtrInside(
                node,
                ptrPos: ptrPos,
                topmostPtrPath: topmostPtrPath,
                hitGeometryByPath: hitGeometryByPath,
                presentedRectByPath: presentedRectByPath,
                presentedRectById: presentedRectById
            )
            if node.el.isHoverAlone && inside {
                if alonePath == nil || node.path.count > alonePath!.count {
                    alonePath = node.path
                }
            }
            if let k = node.el.hoverGroupShare {
                let focusIn = focusVisible && (focusedPath == node.path || (focusedPath?.hasPrefix(node.path + "/") ?? false))
                if inside || focusIn {
                    sharedHoverKeys.insert(k)
                }
            }
        }
        return GroupHoverContext(
            ptrPos: ptrPos,
            hoveredPath: hoveredPath,
            focusVisible: focusVisible,
            focusedPath: focusedPath,
            topmostPtrPath: topmostPtrPath,
            alonePath: alonePath,
            sharedHoverKeys: sharedHoverKeys,
            hitGeometryByPath: hitGeometryByPath,
            presentedRectByPath: presentedRectByPath,
            presentedRectById: presentedRectById
        )
    }

    internal func rebuildHoverCurves(for nodes: [FlatNode]) {
        inheritedHoverCurvesByPath.removeAll(keepingCapacity: true)
        anchorHoverWithinByKey.removeAll(keepingCapacity: true)
        hoverCurvesById.removeAll(keepingCapacity: true)

        var byKey: [String: Int] = [:]
        for (i, n) in nodes.enumerated() {
            if let k = n.key { byKey[k] = i }
        }
        var resolvedWithin = [(enter: Anim<Float>, exit: Anim<Float>)?](repeating: nil, count: nodes.count)
        var state = [UInt8](repeating: 0, count: nodes.count) // 0=unvisited, 1=visiting, 2=done

        func within(at idx: Int) -> (enter: Anim<Float>, exit: Anim<Float>)? {
            if state[idx] == 2 { return resolvedWithin[idx] }
            if state[idx] == 1 { return nil }
            state[idx] = 1
            let n = nodes[idx]
            let inherited: (enter: Anim<Float>, exit: Anim<Float>)?
            if let anchor = n.el.anchor, let anchorIdx = byKey[anchor.key] {
                inherited = within(at: anchorIdx)
            } else if let pIdx = n.parentIndex {
                inherited = within(at: pIdx)
            } else {
                inherited = nil
            }
            let eff = n.el.hoverWithinSpec ?? inherited
            resolvedWithin[idx] = eff
            state[idx] = 2
            return eff
        }

        for i in 0..<nodes.count {
            let n = nodes[i]
            let effWithin = within(at: i)
            if let effWithin {
                inheritedHoverCurvesByPath[n.path] = effWithin
                if let k = n.key {
                    anchorHoverWithinByKey[k] = effWithin
                }
            }
            if let effective = n.el.hoverMotionSpec ?? effWithin {
                hoverCurvesById[n.nodeId] = effective
            }
        }
    }

    internal static func hoverHitPredicate(_ node: FlatNode) -> Bool {
        let h = node.el.handlers
        return node.el.hoverBg != nil || node.el.pressBg != nil || node.el.pressColor != nil ||
               node.el.isHoverGroup || node.el.isHoverAlone ||
               (!node.el.hasKitHoverDelays && h.onHover != nil) || h.onClick != nil || h.onClickPress != nil ||
               h.onMiddlePress != nil ||
               h.onDrag != nil || h.editLens != nil || node.el.a11yHelp != nil ||
               (!node.el.textLinks.isEmpty && !node.el.isSecure && h.editLens == nil)
    }

    internal func layoutMoving() -> Bool {
        let layoutProps: Set<PropId> = [Props.FRAME.id, Props.OFFSET.id, Props.TRAVEL.id]
        if scene.store.active().contains(where: { layoutProps.contains($0.1) }) {
            return true
        }
        if !launchedFlightIds.isEmpty || !activeTextFlights.isEmpty {
            return true
        }
        if growthRows.values.contains(where: { $0.track.moving }) {
            return true
        }
        return anyScrollCarries(at: currentTime)
    }

    internal func layoutCarries(nodeIndex: Int) -> Bool {
        var cur: Int? = nodeIndex
        while let k = cur, flatNodes.indices.contains(k) {
            let n = flatNodes[k]
            let nid = n.nodeId
            if scene.store.isAnimating(nid, Props.FRAME) ||
               scene.store.isAnimating(nid, Props.OFFSET) ||
               scene.store.isAnimating(nid, Props.TRAVEL) ||
               launchedFlightIds.contains(nid) ||
               growthRows["growth:\(n.path)"]?.track.moving == true ||
               growthRows["fold:\(n.path)"]?.track.moving == true ||
               ((n.el.growthSpec != nil || n.el.foldGlideSpec != nil) &&
                growthRows.contains(where: { ($0.key.hasPrefix("growth:\(n.path)/") || $0.key.hasPrefix("fold:\(n.path)/")) && $0.value.track.moving })) ||
               scrollCarries(path: n.path, at: currentTime) {
                return true
            }
            cur = n.parentIndex
        }
        return false
    }

    internal func hoverLive(_ path: String) -> Int? {
        guard let idx = nodeByPath[path], flatNodes.indices.contains(idx) else { return nil }
        let node = flatNodes[idx]
        guard !node.effectiveInert else { return nil }
        if case .exiting = scene.phase(node.nodeId) { return nil }
        var p = node.parentIndex
        while let pi = p, flatNodes.indices.contains(pi) {
            if case .exiting = scene.phase(flatNodes[pi].nodeId) { return nil }
            p = flatNodes[pi].parentIndex
        }
        return idx
    }

    internal func hoverMayHold() -> Bool {
        pointerPosition.x > -9000 &&
        pointerPosition.y > -9000 &&
        pressedPath == nil &&
        !hoverHold.released
    }

    /// The pointer moved or pressed, or a hand scrolled: hover follows the pointer through the
    /// layout moving now, until it settles (`hover.rs::release_hover_hold`).
    internal func releaseHoverHold() {
        let moving = !hoverHold.released && layoutMoving()
        hoverHold.release(moving: moving)
    }

    internal func decideHoverHold(
        candidatePath: String?,
        candidateIndex: Int?,
        within: (inside: [String], entering: [Int])? = nil
    ) -> Bool {
        guard hoverMayHold() else { return false }
        if candidatePath != hoveredPath {
            if let cIdx = candidateIndex, layoutCarries(nodeIndex: cIdx) {
                return true
            }
            if let old = hoveredPath, let oldIdx = hoverLive(old), layoutCarries(nodeIndex: oldIdx) {
                return true
            }
        }
        if let within {
            if within.entering.contains(where: { layoutCarries(nodeIndex: $0) }) {
                return true
            }
            if hoverWithinPaths.contains(where: { path in
                !within.inside.contains(path) && (hoverLive(path).map { layoutCarries(nodeIndex: $0) } ?? false)
            }) {
                return true
            }
        }
        // The hover tracks that would change (`hover_flip`): one carried by moving layout holds,
        // except a leave from an element turned inert (`Flip::now`).
        let ctx = hoverFlipContext()
        for idx in flatNodes.indices where hasHoverTrack(idx) && !hoverIsExiting(idx) {
            let on = hoverFlipOn(idx, ctx)
            let target: Float = on ? 1.0 : 0.0
            let now = !on && !hoverAllowed(idx)
            if target != hoverTarget(flatNodes[idx].nodeId) && !now && layoutCarries(nodeIndex: idx) {
                return true
            }
        }
        return false
    }

    internal enum HoverDispatchPolicy {
        case always
        case onHoldRelease
        case never
    }

    internal func refreshHoverAndSyncTracks(
        at now: Double,
        wallNow: Double? = nil,
        cut: Bool,
        dispatchPolicy: HoverDispatchPolicy = .always
    ) {
        let wasHeld = hoverHold.held
        if cut {
            hoverHold = HoverHold()
            hoverWithinPaths.removeAll()
            hoverDelays.clear()
            syncHoverTracks(at: now, cut: true, held: false)
            return
        }
        if hoverHold.released && !layoutMoving() {
            hoverHold.settled()
        }
        let ptrInWindow = pointerPosition.x > -9000 && pointerPosition.y > -9000
        let candidateHit: (node: FlatNode, rect: MotionRect)?
        if !ptrInWindow {
            candidateHit = nil
        } else if let pp = pressedPath {
            if pressRestingContains(path: pp, at: pointerPosition),
               let pIdx = nodeByPath[pp],
               flatNodes.indices.contains(pIdx),
               !flatNodes[pIdx].effectiveInert {
                let pNode = flatNodes[pIdx]
                candidateHit = (pNode, presentedRectByPath[pp] ?? pNode.targetRect)
            } else {
                candidateHit = nil
            }
        } else {
            candidateHit = hitTest(at: pointerPosition, predicate: Self.hoverHitPredicate)
        }
        let candidatePath = candidateHit?.node.path
        let candidateIndex = candidateHit?.node.index
        let within = computeHoverWithin()

        let shouldHold = decideHoverHold(
            candidatePath: candidatePath,
            candidateIndex: candidateIndex,
            within: within
        )
        hoverHold.setHeld(shouldHold)

        if let within {
            applyHoverWithin(within.inside, held: shouldHold, at: wallNow ?? currentTime)
        }

        let dispatchHover: Bool = switch dispatchPolicy {
        case .always: true
        case .onHoldRelease: wasHeld
        case .never: false
        }

        if shouldHold {
            hoveredLink = nil
            if let cur = hoveredPath, hoverLive(cur) == nil {
                hoveredPath = nil
                hoveredKey = nil
                if dispatchHover {
                    isDispatchingHover = true
                    dispatchHoverCallbacks(to: nil, at: currentTime)
                    isDispatchingHover = false
                }
            }
        } else if ptrInWindow {
            let newHoveredLink: TextLinkTarget? = {
                guard let hitNode = candidateHit?.node,
                      hasActiveTextLinks(hitNode.el),
                      let linkIdx = linkIndex(atPath: hitNode.path, at: pointerPosition) else {
                    return nil
                }
                return TextLinkTarget(path: hitNode.path, key: hitNode.key, linkIndex: linkIdx)
            }()
            if newHoveredLink != hoveredLink {
                hoveredLink = newHoveredLink
            }
            if candidatePath != hoveredPath {
                hoveredPath = candidatePath
                hoveredKey = candidateHit?.node.key
                if dispatchHover {
                    isDispatchingHover = true
                    dispatchHoverCallbacks(to: candidatePath, at: currentTime)
                    isDispatchingHover = false
                }
            }
        }

        syncHoverTracks(at: now, cut: false, held: shouldHold)
    }

    /// Retargets the hover tracks (the hover half of `hover.rs::update_interaction`). `held` is
    /// the hold `refreshHoverAndSyncTracks` just decided: while layout holds hover, a track whose
    /// target would change waits, except a leave from an element turned inert, which lands now.
    /// An element that drew nothing (a held hover whose row a glide carried out of view) lands
    /// its change rather than fading where nobody sees. A target that doesn't change moves only
    /// under explicit curves (`hoverMotion` / `hoverMotionWithin`), which may carry a velocity or
    /// token; the default curves keep the trajectory the store already has and dirty nothing.
    internal func syncHoverTracks(
        at now: Double,
        cut: Bool,
        held: Bool = false
    ) {
        // Hit tests read the last build's drawn rects by node. When a commit moved the nodes
        // (or nothing has been built yet), they belong to other elements until the build
        // re-evaluates from fresh geometry (`update_interaction`'s `built_ids` check).
        if !cut && !flatNodes.lazy.map(\.nodeId).elementsEqual(builtHoverIds) { return }
        let ctx = hoverFlipContext()
        var unseen: [Bool]? = nil
        for (i, node) in flatNodes.enumerated() {
            guard hasHoverTrack(i), !hoverIsExiting(i) else { continue }
            let nid = node.nodeId
            let trackId = Self.hoverTrackId(nid)
            let isLit = hoverFlipOn(i, ctx)
            let target: Float = isLit ? 1.0 : 0.0
            // A leave from an element turned inert lands whatever the hold (`Flip::now`).
            let forceNow = !isLit && !hoverAllowed(i)
            let current = hoverTarget(nid)
            let changed = current != target
            let snapImmediately = cut || cxSettings.hostReducedMotion
            if snapImmediately {
                if readyHoverFromRest(nid, to: target) {
                    liveStore.snap(trackId, Self.hoverProp, to: target)
                }
                lastHoverTargetById[nid] = target
                continue
            }
            let curves = hoverCurvesById[nid]
            if !changed {
                // Default hover animations inherit velocity and have no completion token. An
                // unchanged target preserves its trajectory in the store already; avoid dirtying
                // the track for that no-op. Custom animations may carry an explicit velocity,
                // decay or token and must still reach the store.
                if let curves {
                    if !liveStore.has(trackId, Self.hoverProp) {
                        liveStore.snap(trackId, Self.hoverProp, to: 0.0)
                    }
                    liveStore.set(trackId, Self.hoverProp, to: target, anim: isLit ? curves.enter : curves.exit, at: now)
                }
                lastHoverTargetById[nid] = current
                continue
            }
            if held && !forceNow {
                lastHoverTargetById[nid] = current
                continue
            }
            // Like a native sidebar or menu: the highlight lands with the pointer and fades
            // briefly as it leaves.
            let anim: Anim<Float> = curves.map { isLit ? $0.enter : $0.exit }
                ?? (isLit ? .instant : Anim<Float>(curve: .tween(duration: 0.1, easing: .easeOut)))
            if readyHoverFromRest(nid, to: target) {
                let drewNothing = unseen ?? kitHooks.unseenPresence.drewNothing(nodes: flatNodes)
                unseen = drewNothing
                if drewNothing.indices.contains(i) && drewNothing[i] {
                    liveStore.snap(trackId, Self.hoverProp, to: target)
                } else {
                    liveStore.set(trackId, Self.hoverProp, to: target, anim: anim, at: now)
                }
            }
            lastHoverTargetById[nid] = target
        }
        lastHoverTargetById = lastHoverTargetById.filter { nodeById[$0.key] != nil || exitingSnapshots[$0.key] != nil }
        syncPressScale(at: now, cut: cut)
    }

    internal struct GroupHoverContext {
        let ptrPos: Vec2
        let hoveredPath: String?
        let focusVisible: Bool
        let focusedPath: String?
        let topmostPtrPath: String?
        let alonePath: String?
        let sharedHoverKeys: Set<String>
        let hitGeometryByPath: [String: HitGeometry]
        let presentedRectByPath: [String: MotionRect]
        let presentedRectById: [NodeId: MotionRect]

        static func isPtrInside(
            _ node: FlatNode,
            ptrPos: Vec2,
            topmostPtrPath: String?,
            hitGeometryByPath: [String: HitGeometry],
            presentedRectByPath: [String: MotionRect],
            presentedRectById: [NodeId: MotionRect]
        ) -> Bool {
            guard ptrPos.x > -9000, ptrPos.y > -9000 else { return false }
            let insideGeom: Bool
            if let geom = hitGeometryByPath[node.path] {
                insideGeom = geom.contains(ptrPos)
            } else {
                let r = presentedRectById[node.nodeId] ?? presentedRectByPath[node.path] ?? node.targetRect
                insideGeom = halfOpenContains(intersectRects(node.clipRect, r), ptrPos)
            }
            guard insideGeom else { return false }
            if let top = topmostPtrPath, !(top == node.path || top.hasPrefix(node.path + "/")) {
                return false
            }
            return true
        }

        func callAsFunction(_ node: FlatNode) -> Bool {
            guard !node.effectiveInert else { return false }
            if let alonePath, alonePath != node.path, alonePath.hasPrefix(node.path + "/") {
                return false
            }
            if hoveredPath == node.path || (hoveredPath?.hasPrefix(node.path + "/") ?? false) {
                return true
            }
            if Self.isPtrInside(
                node,
                ptrPos: ptrPos,
                topmostPtrPath: topmostPtrPath,
                hitGeometryByPath: hitGeometryByPath,
                presentedRectByPath: presentedRectByPath,
                presentedRectById: presentedRectById
            ) {
                return true
            }
            if let share = node.el.hoverGroupShare, sharedHoverKeys.contains(share) {
                return true
            }
            // Every hover group lights while keyboard focus is on it or inside it (upstream
            // 4e215eac #726: `hover_group_focus` is now `hover_group`).
            if node.el.isHoverGroup || node.el.hoverGroupShare != nil,
               focusVisible,
               let fp = focusedPath,
               (fp == node.path || fp.hasPrefix(node.path + "/")) {
                return true
            }
            return false
        }
    }
}

// MARK: - `onHoverChange` & `HoverDelays` (`r375`)

extension Runtime {
    private static func hoverWithinHolds(outer: String, inner: String) -> Bool {
        inner == outer || inner.hasPrefix(outer + "/")
    }

    internal func computeHoverWithin() -> (inside: [String], entering: [Int])? {
        let hasAny = !hoverWithinPaths.isEmpty || !hoverDelays.isEmpty
            || flatNodes.contains { $0.el.handlers.onHoverChange != nil }
        guard hasAny else { return nil }

        var inside: [String] = []
        var entering: [Int] = []
        if pointerPosition.x > -9000 && pointerPosition.y > -9000 {
            let hits = hitTestAll(at: pointerPosition) { $0.el.handlers.onHoverChange != nil }
            for h in hits {
                let path = h.node.path
                if !inside.contains(path) {
                    if !hoverWithinPaths.contains(path) {
                        entering.append(h.node.index)
                    }
                    inside.append(path)
                }
            }
        }
        // A held press stays inside what holds it until it releases (`hover.rs:132-140`).
        if let captured = pressedPath {
            for path in hoverWithinPaths where !inside.contains(path) {
                if Self.hoverWithinHolds(outer: path, inner: captured),
                   hoverLive(path) != nil {
                    inside.append(path)
                }
            }
        }
        return (inside, entering)
    }

    private func effectiveHoverDelay(for el: El<State>) -> (enter: Float, leave: Float) {
        if let spec = el.kitHoverDelaysSpec {
            return (Float(spec.enter), Float(spec.leave))
        }
        return el.handlers.hoverDelay
    }

    internal func applyHoverWithin(_ nextInside: [String], held: Bool, at now: Double) {
        var inside = nextInside
        if held {
            inside = hoverWithinPaths.filter { hoverLive($0) != nil }
        }
        let isDelayed: (String) -> Bool = { path in
            guard let idx = self.nodeByPath[path], self.flatNodes.indices.contains(idx) else { return false }
            let d = self.effectiveHoverDelay(for: self.flatNodes[idx].el)
            return d.enter > 0 || d.leave > 0
        }
        for path in hoverWithinPaths where !inside.contains(path) && !isDelayed(path) {
            if let idx = nodeByPath[path], flatNodes.indices.contains(idx),
               let cb = flatNodes[idx].el.handlers.onHoverChange {
                dispatchHoverChange(path: path, inside: false, handler: cb, at: now)
            }
        }
        for path in inside where !hoverWithinPaths.contains(path) && !isDelayed(path) {
            if let idx = nodeByPath[path], flatNodes.indices.contains(idx),
               let cb = flatNodes[idx].el.handlers.onHoverChange {
                dispatchHoverChange(path: path, inside: true, handler: cb, at: now)
            }
        }
        hoverWithinPaths = inside
        settleHoverDelays(at: now)
    }

    private func dispatchHoverChange(
        path: String,
        inside: Bool,
        handler: (inout State, Bool, inout Tx) -> Void,
        at now: Double
    ) {
        isDispatchingHover = true
        var tx = makeTx(at: now)
        handler(&state, inside, &tx)
        applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
        isDispatchingHover = false
    }

    internal func stepHoverDelay(_ path: String, event: HoverDelayEvent, at now: Double) {
        let effects = hoverDelays.step(path, event: event)
        for effect in effects {
            switch effect {
            case let .report(inside):
                if let idx = nodeByPath[path], flatNodes.indices.contains(idx),
                   let cb = flatNodes[idx].el.handlers.onHoverChange {
                    dispatchHoverChange(path: path, inside: inside, handler: cb, at: now)
                }
            case .wakeAt:
                break // `nextWakeDeadline(after:)` reads `hoverDelays.nextDue()` directly.
            }
        }
    }

    internal func settleHoverDelays(at now: Double) {
        var paths = Set(hoverDelays.paths)
        for path in hoverWithinPaths {
            if let idx = nodeByPath[path], flatNodes.indices.contains(idx) {
                let d = effectiveHoverDelay(for: flatNodes[idx].el)
                if d.enter > 0 || d.leave > 0 {
                    paths.insert(path)
                }
            }
        }
        let mayEnter = (pressedPath == nil) && !hoverPaused
        for path in paths.sorted() {
            let event: HoverDelayEvent
            if let idx = nodeByPath[path], flatNodes.indices.contains(idx),
               flatNodes[idx].el.handlers.onHoverChange != nil,
               !flatNodes[idx].effectiveInert {
                let d = effectiveHoverDelay(for: flatNodes[idx].el)
                event = .settle(
                    inside: hoverWithinPaths.contains(path),
                    mayEnter: mayEnter,
                    enterDelay: d.enter,
                    leaveDelay: d.leave,
                    now: now
                )
            } else {
                event = .ended
            }
            stepHoverDelay(path, event: event, at: now)
        }
    }

    internal func fireHoverDelays(at now: Double) {
        guard hoverDelays.waiting else { return }
        let clockNow = now + 1e-6
        for path in hoverDelays.paths {
            stepHoverDelay(path, event: .due(now: clockNow), at: now)
        }
    }

    internal func pressHoverDelays() {
        for path in hoverDelays.paths {
            stepHoverDelay(path, event: .pressed, at: currentTime)
        }
    }

    internal func endHoverDelays(at now: Double) {
        for path in hoverDelays.paths {
            stepHoverDelay(path, event: .ended, at: now)
        }
    }

    /// Removes pruned elements from `hoverWithinPaths`/`hoverDelays` and fires a leave callback
    /// if the pruned element had already heard enter (`hover.rs:189-197`).
    internal func reconcilePrunedHoverWithin(
        prevNodes: [FlatNode],
        newByPath: [String: Int],
        cut: Bool,
        at now: Double
    ) {
        if cut {
            hoverWithinPaths.removeAll()
            hoverDelays.clear()
            return
        }
        for old in prevNodes where newByPath[old.path] == nil {
            let inside = hoverWithinPaths.firstIndex(of: old.path).map { idx -> Bool in
                hoverWithinPaths.remove(at: idx)
                return true
            } ?? false
            let shown = hoverDelays.forget(old.path)
            let d = effectiveHoverDelay(for: old.el)
            let heard = (d.enter == 0 && d.leave == 0) ? inside : shown
            if heard, let cb = old.el.handlers.onHoverChange {
                dispatchHoverChange(path: old.path, inside: false, handler: cb, at: now)
            }
        }
    }
}
