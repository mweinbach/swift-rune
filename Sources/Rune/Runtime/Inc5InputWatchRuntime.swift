import Foundation
import RuneMotion

private let runeHoverProp = Prop<Float>.custom(0x484F, .opacity, name: "hover")
private let runePressProp = Prop<Float>.custom(0x5052, .opacity, name: "press")

private let hoverTrackPrefix = NodeId.hash("hover:")
private let pressTrackPrefix = NodeId.hash("press:")

/// Hash the same decimal suffix as string interpolation without allocating a string per sample.
private func interactionTrackID(prefix: NodeId, owner: NodeId) -> NodeId {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { digits in
        var start = digits.count
        var remaining = owner.rawValue
        repeat {
            let (quotient, digit) = remaining.quotientAndRemainder(dividingBy: 10)
            start -= 1
            digits[start] = 48 + UInt8(digit)
            remaining = quotient
        } while remaining != 0
        var hash = prefix.rawValue
        for index in start..<digits.count {
            hash = (hash ^ UInt64(digits[index])) &* 0x100000001b3
        }
        return NodeId(hash)
    }
}

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
    internal func keyUp(_ ev: KeyEvent, fromPhysicalRelease: Bool, at now: Double = 0, why: UInt16 = CommitWhy.input) -> Bool {
        let inputMark = beginInputDispatch(at: now, routed: true)
        defer { endInputDispatch(inputMark, queuedAction: true) }
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
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: taken, why: why)
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

    private func dispatchGestureChain(at windowPos: Vec2, body: (FlatNode, Vec2) -> (handled: Bool, tx: Tx)?) -> Bool {
        pointerPosition = windowPos
        guard let startIdx = gestureStartIndex(at: windowPos) else { return false }
        var walkIdx: Int? = startIdx
        while let cur = walkIdx, cur < flatNodes.count {
            let node = flatNodes[cur]
            if !hoverAllowed(cur) || subtreeExiting(cur) { break }
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
        let inputMark = beginInputDispatch(at: now)
        defer { endInputDispatch(inputMark) }
        return dispatchGestureChain(at: windowPos) { node, local in
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
        let inputMark = beginInputDispatch(at: now)
        defer { endInputDispatch(inputMark) }
        return dispatchGestureChain(at: windowPos) { node, local in
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
        let inputMark = beginInputDispatch(at: now)
        defer { endInputDispatch(inputMark) }
        return dispatchGestureChain(at: windowPos) { node, local in
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
            let dw = min(boxPtW, max(1, imageWidth * k))
            let dh = min(boxPtH, max(1, imageHeight * k))
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
        interactionTrackID(prefix: hoverTrackPrefix, owner: nid)
    }

    internal static var pressProp: Prop<Float> { runePressProp }

    internal static func pressTrackId(_ nid: NodeId) -> NodeId {
        interactionTrackID(prefix: pressTrackPrefix, owner: nid)
    }

    /// Retargets every press track (the press half of `hover.rs::update_interaction`): a node
    /// that tracks press (`Visual::tracks_press`: a press fill or a press color) goes to 1 while
    /// its element holds a press with the pointer inside (or a middle/secondary button's tint
    /// over it) and is allowed (not inert, not behind a modal), else to 0. The track is readied
    /// from rest (`paint/tracks.rs::ready_from_rest`), goes down on `INSTANT` and comes back up
    /// on `SNAPPY`; a cut lands it. Under Reduce Motion the store fades this opacity track on
    /// `REDUCED_FADE` instead of springing it (upstream `store.rs::animate_raw`).
    internal func syncPressColorTracks(at now: Double, cut: Bool) {
        let snapImmediately = cut
        for i in layoutObservers.pressColors {
            let node = flatNodes[i]
            let nid = node.nodeId
            let trackId = Self.pressTrackId(nid)
            let pressed = isNodePressedVisually(
                node,
                restingContains: pressRestingContains(path: node.path, at: pointerPosition)
            )
            let target: Float = pressed ? 1.0 : 0.0
            lastPressTargetById[nid] = target
            // `ready_from_rest(P_PRESS, 0.0, pressed)`.
            if !liveStore.has(trackId, Self.pressProp) {
                if target == 0.0 { continue }
                liveStore.snap(trackId, Self.pressProp, to: 0.0)
            }
            // Retargeting to the target it has is a no-op in the store; skip touching the track.
            guard liveStore.target(trackId, Self.pressProp) != target else { continue }
            if snapImmediately {
                liveStore.snap(trackId, Self.pressProp, to: target)
            } else {
                let spring = pressed ? MotionTokens.INSTANT : MotionTokens.SNAPPY
                liveStore.set(trackId, Self.pressProp, to: target, anim: Anim<Float>(curve: .spring(spring)), at: now)
            }
        }
        lastPressTargetById = lastPressTargetById.filter { nodeIndexById[$0.key] != nil || exitingSnapshots[$0.key] != nil }
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
        for i in layoutObservers.hoverGroups {
            let node = flatNodes[i]
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

    internal func publishHoverOrder() {
        guard !hoverOrderMatchesPaint else { return }
        func capture(into ids: inout [NodeId]) {
            ids.removeAll(keepingCapacity: true)
            ids.reserveCapacity(flatNodes.count)
            // Read each ID in place. Mapping a key path copies the generic FlatNode.
            flatNodes.withUnsafeBufferPointer { nodes in
                for i in nodes.indices { ids.append(nodes[i].nodeId) }
            }
        }
        capture(into: &builtHoverIds)
        hoverOrderMatchesPaint = true
    }

    internal func rebuildHoverCurves(for nodes: [FlatNode]) {
        inheritedHoverCurvesByPath.removeAll(keepingCapacity: true)
        anchorHoverWithinByKey.removeAll(keepingCapacity: true)
        hoverCurvesById.removeAll(keepingCapacity: true)
        guard layoutObservers.hasHoverCurves else { return }

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
        if scene.store.active().contains(where: { _, prop in
            prop == Props.FRAME.id || prop == Props.OFFSET.id || prop == Props.TRAVEL.id
        }) {
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
        let mounted = flatNodes
        let nodes = mounted.span
        guard !nodes[idx].effectiveInert else { return nil }
        if case .exiting = scene.phase(nodes[idx].nodeId) { return nil }
        var p = nodes[idx].parentIndex
        while let pi = p, flatNodes.indices.contains(pi) {
            if case .exiting = scene.phase(nodes[pi].nodeId) { return nil }
            p = nodes[pi].parentIndex
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
        // A hold is possible only when layout carries a hovered node or one of its ancestors.
        guard hoverMayHold(), layoutMoving() else { return false }
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
        let mounted = flatNodes
        let nodes = mounted.span
        for idx in layoutObservers.hoverTracks {
            let id = nodes[idx].nodeId
            if case .exiting = scene.phase(id) { continue }
            let flip = hoverFlip(nodes[idx], at: idx, ctx)
            let target: Float = flip.on ? 1.0 : 0.0
            if target != hoverTarget(id) && (flip.on || flip.allowed) && layoutCarries(nodeIndex: idx) {
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

    @discardableResult
    internal func refreshHoverAndSyncTracks(
        at now: Double,
        wallNow: Double? = nil,
        cut: Bool,
        dispatchPolicy: HoverDispatchPolicy = .always
    ) -> Bool {
        let wasHeld = hoverHold.held
        if cut {
            hoverHold = HoverHold()
            hoverWithinPaths.removeAll()
            hoverDelays.clear()
            return syncHoverTracks(at: now, cut: true, held: false)
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

        return syncHoverTracks(at: now, cut: false, held: shouldHold)
    }

    /// Retargets the hover tracks (the hover half of `hover.rs::update_interaction`). `held` is
    /// the hold `refreshHoverAndSyncTracks` just decided: while layout holds hover, a track whose
    /// target would change waits, except a leave from an element turned inert, which lands now.
    /// An element that drew nothing (a held hover whose row a glide carried out of view) lands
    /// its change rather than fading where nobody sees. A target that doesn't change moves only
    /// under explicit curves (`hoverMotion` / `hoverMotionWithin`), which may carry a velocity or
    /// token; the default curves keep the trajectory the store already has and dirty nothing.
    @discardableResult
    internal func syncHoverTracks(
        at now: Double,
        cut: Bool,
        held: Bool = false
    ) -> Bool {
        // Hit tests read the last build's drawn rects by node. When a commit moved the nodes
        // (or nothing has been built yet), they belong to other elements until the build
        // re-evaluates from fresh geometry (`update_interaction`'s `built_ids` check).
        if !cut && !hoverOrderMatchesPaint { return false }
        let ctx = hoverFlipContext()
        var unseen: [Bool]? = nil
        var retargeted = false
        let mounted = flatNodes
        let nodes = mounted.span
        for i in layoutObservers.hoverTracks {
            let nid = nodes[i].nodeId
            if case .exiting = scene.phase(nid) { continue }
            let trackId = Self.hoverTrackId(nid)
            let flip = hoverFlip(nodes[i], at: i, ctx)
            let isLit = flip.on
            let target: Float = isLit ? 1.0 : 0.0
            // A leave from an element turned inert lands whatever the hold (`Flip::now`).
            let forceNow = !isLit && !flip.allowed
            let current = hoverTarget(nid)
            let changed = current != target
            // A cut lands every track where it belongs; nothing holds through it.
            if cut {
                if readyHoverFromRest(nid, to: target) {
                    liveStore.snap(trackId, Self.hoverProp, to: target)
                    retargeted = retargeted || changed
                }
                lastHoverTargetById[nid] = target
                continue
            }
            // Under Reduce Motion the store turns any curve but an instant one on this opacity
            // track into `REDUCED_FADE` (`AnimationStore.reducedMotion`, upstream
            // `store.rs::animate_raw` + `PropClass::reduce`), so nothing here snaps for it; and
            // the hold applies whatever the motion setting (`hover.rs:384-385`).
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
                retargeted = true
                if kitHooks.unseenPresence.drewNothing(at: i, nodes: flatNodes, cached: &unseen) {
                    liveStore.snap(trackId, Self.hoverProp, to: target)
                } else {
                    liveStore.set(trackId, Self.hoverProp, to: target, anim: anim, at: now)
                }
            }
            lastHoverTargetById[nid] = target
        }
        // Hover tracks live in a separate store from the scene. Retire them with their
        // owner so a returning virtual row starts at rest, including during a scroll hold.
        for nid in lastHoverTargetById.keys where nodeIndexById[nid] == nil && exitingSnapshots[nid] == nil {
            liveStore.remove(Self.hoverTrackId(nid), Self.hoverProp)
            lastHoverTargetById.removeValue(forKey: nid)
        }
        syncPressScale(at: now, cut: cut)
        return retargeted
    }

    internal struct GroupHoverContext {
        let ptrPos: Vec2
        let hoveredPath: String?
        let focusVisible: Bool
        let focusedPath: String?
        let topmostPtrPath: String?
        let alonePath: String?
        let sharedHoverKeys: Set<String>
        let hitGeometryByPath: FrameGeometry<HitGeometry>
        let presentedRectByPath: FrameGeometry<MotionRect>
        let presentedRectById: [NodeId: MotionRect]

        static func isPtrInside(
            _ node: borrowing FlatNode,
            ptrPos: Vec2,
            topmostPtrPath: String?,
            hitGeometryByPath: FrameGeometry<HitGeometry>,
            presentedRectByPath: FrameGeometry<MotionRect>,
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
        let hasAny = !hoverWithinPaths.isEmpty || !hoverDelays.isEmpty || !layoutObservers.hoverChanges.isEmpty
        guard hasAny else { return nil }

        var inside: [String] = []
        var entering: [Int] = []
        if pointerPosition.x > -9000 && pointerPosition.y > -9000 {
            // Hover-change observers follow their own drawn bounds, including overlapping siblings.
            var hits: [(index: Int, order: Int)] = []
            let mounted = flatNodes
            let nodes = mounted.span
            for index in layoutObservers.hoverChanges where hoverAllowed(nodes[index]) {
                if let geometry = hitGeometryByPath[nodes[index].path] {
                    if !geometry.isExiting, geometry.opacity > 0.001, geometry.contains(pointerPosition) {
                        hits.append((index, geometry.paintOrder))
                    }
                } else if paintOrderPaths.isEmpty, nodes[index].el.opacity > 0.001, !hoverIsExiting(index),
                          hoverNodeContains(nodes[index]) {
                    hits.append((index, index))
                }
            }
            if hits.count > 1 { hits.sort { $0.order < $1.order } }
            for hit in hits {
                let path = nodes[hit.index].path
                if !hoverWithinPaths.contains(path) { entering.append(hit.index) }
                inside.append(path)
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

    internal func effectiveHoverDelay(for el: El<State>) -> (enter: Float, leave: Float) {
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
                inputMachines.hoverDelayReports &+= 1
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
        let inputMark = beginInputDispatch(at: now)
        defer { endInputDispatch(inputMark) }
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
        prevByPath: [String: Int],
        newByPath: [String: Int],
        cut: Bool,
        at now: Double
    ) {
        if cut {
            hoverWithinPaths.removeAll()
            hoverDelays.clear()
            return
        }
        guard !hoverWithinPaths.isEmpty || !hoverDelays.isEmpty else { return }
        // Paint order and timer start order can differ from the previous tree's callback order.
        var missing: Set<Int> = []
        for path in hoverWithinPaths where newByPath[path] == nil {
            if let index = prevByPath[path] { missing.insert(index) }
        }
        for path in hoverDelays.paths where newByPath[path] == nil {
            if let index = prevByPath[path] { missing.insert(index) }
        }
        for i in missing.sorted() {
            let old = prevNodes[i]
            let inside = hoverWithinPaths.firstIndex(of: old.path).map { idx -> Bool in
                hoverWithinPaths.remove(at: idx)
                return true
            } ?? false
            let shown = hoverDelays.forget(old.path)
            let d = effectiveHoverDelay(for: old.el)
            let heard = (d.enter == 0 && d.leave == 0) ? inside : shown
            if heard, let cb = old.el.handlers.onHoverChange {
                // No pointer event asked for this leave (`hover.rs`: `observe_since`): its change is
                // DIRTY even when a commit flushed inside an input entry point prunes it (#970).
                asInputObserver {
                    dispatchHoverChange(path: old.path, inside: false, handler: cb, at: now)
                }
            }
        }
    }
}
