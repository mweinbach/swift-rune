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

    internal func flushPendingPasteRequests(at now: Double) {
        guard pendingPasteRequests > 0 else { return }
        let count = pendingPasteRequests
        pendingPasteRequests = 0
        for _ in 0..<count {
            let content: ClipboardContent
            if let board = boundClipboard {
                content = board.readRich(sanitizeUntrustedHTML: true).content
            } else if !richClipboard.content.text.isEmpty || richClipboard.content.html != nil || richClipboard.content.rtf != nil {
                content = richClipboard.content
            } else {
                content = clipboard
            }
            deliverPaste(content, at: now)
        }
    }

    @discardableResult
    internal func deliverPaste(_ content: ClipboardContent, at now: Double) -> Bool {
        clipboard = content
        richClipboard = RichClipboardPayload(content: content)

        if let fPath = focusedPath,
           let fEl = focusedInputElement(at: fPath) {
            if let editLens = fEl.handlers.editLens {
                var consumed = false
                if let onInputPaste = fEl.handlers.onInputPaste {
                    var tx = makeTx(at: now)
                    consumed = onInputPaste(&state, content, &tx)
                    applyTx(tx, at: now)
                }
                let hasHTML = content.html.map { !$0.isEmpty } ?? false
                if !consumed && (!content.text.isEmpty || hasHTML) {
                    let prevEdit = editLens.get(state)
                    var edit = prevEdit
                    let stateRevealed = edit.isRevealed
                    if fEl.isSecure {
                        edit.isSecure = true
                        if fEl.isRevealed { edit.isRevealed = true }
                    }
                    if edit.isRichEnabled && !edit.isSecure, let html = content.html, !html.isEmpty {
                        edit.pasteHTML(html, plain: content.text)
                    } else if !content.text.isEmpty {
                        edit.paste(content.text)
                    }
                    edit.isRevealed = stateRevealed
                    deliverInputEdit(el: fEl, previousEdit: prevEdit, newEdit: edit, editLens: editLens, at: now)
                }
                return true
            }
        }

        // Dispatch to active modal's or root's `onPasteContent` / `onPaste` handler when no editor is focused.
        let rootIdx: Int? = activeModalPath.flatMap { nodeByPath[$0] } ?? (flatNodes.isEmpty ? nil : 0)
        if let rIdx = rootIdx {
            let targetEl = flatNodes[rIdx].el
            if let onRich = targetEl.handlers.onPasteContent {
                var tx = makeTx(at: now)
                onRich(&state, content, &tx)
                applyTx(tx, at: now)
                return true
            }
            if !content.text.isEmpty, let onText = targetEl.handlers.onPaste {
                var tx = makeTx(at: now)
                onText(&state, content.text, &tx)
                applyTx(tx, at: now)
                return true
            }
        }
        return false
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
            guard el.pressColor != nil else { continue }
            let nid = node.nodeId
            let trackId = Self.pressTrackId(nid)
            let isDown = isNodePressedVisually(
                node,
                restingContains: pressRestingContains(path: node.path, at: pointerPosition)
            )
            let target: Float = isDown ? 1.0 : 0.0
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
        return !scrollGlidingPaths.isEmpty
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
               scrollGlidingPaths.contains(n.path) {
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
        hoverHoldState != .released
    }

    internal func releaseHoverHold() {
        if hoverHoldState != .released {
            hoverHoldState = layoutMoving() ? .released : .free
        }
    }

    internal func decideHoverHold(
        candidatePath: String?,
        candidateIndex: Int?,
        within: (inside: [String], entering: [Int])? = nil,
        groupHovered: GroupHoverContext
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
        for (idx, node) in flatNodes.enumerated() {
            let el = node.el
            guard el.hoverBg != nil || el.isHoverGroup || el.hoverGroupShare != nil else { continue }
            let isLit: Bool
            if node.effectiveInert {
                isLit = false
            } else if el.isHoverGroup || el.hoverGroupShare != nil {
                isLit = groupHovered(node)
            } else {
                isLit = candidatePath == node.path
            }
            let target: Float = isLit ? 1.0 : 0.0
            let prev = lastHoverTargetById[node.nodeId] ?? 0.0
            let forceNow = !isLit && node.effectiveInert
            if target != prev && !forceNow && layoutCarries(nodeIndex: idx) {
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
        let wasHeld = (hoverHoldState == .held)
        if cut {
            hoverHoldState = .free
            hoverWithinPaths.removeAll()
            hoverDelays.clear()
            syncHoverTracks(at: now, cut: true, held: false)
            return
        }
        if hoverHoldState == .released && !layoutMoving() {
            hoverHoldState = .free
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

        let groupHovered = makeGroupHoverPredicate()
        let shouldHold = decideHoverHold(
            candidatePath: candidatePath,
            candidateIndex: candidateIndex,
            within: within,
            groupHovered: groupHovered
        )
        if hoverHoldState != .released {
            hoverHoldState = shouldHold ? .held : .free
        }

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

        syncHoverTracks(at: now, cut: false, held: shouldHold, groupHovered: groupHovered)
    }

    internal func syncHoverTracks(
        at now: Double,
        cut: Bool,
        held: Bool = false,
        groupHovered existingGroupHovered: GroupHoverContext? = nil
    ) {
        let groupHovered = existingGroupHovered ?? makeGroupHoverPredicate()
        for node in flatNodes {
            let el = node.el
            guard el.hoverBg != nil || el.isHoverGroup || el.hoverGroupShare != nil else { continue }
            let nid = node.nodeId
            let trackId = Self.hoverTrackId(nid)
            let isLit: Bool
            if node.effectiveInert {
                isLit = false
            } else if el.isHoverGroup || el.hoverGroupShare != nil {
                isLit = groupHovered(node)
            } else {
                isLit = hoveredPath == node.path
            }
            let target: Float = isLit ? 1.0 : 0.0
            let forceNow = !isLit && node.effectiveInert
            let prevTarget = lastHoverTargetById[nid]
            let snapImmediately = cut || cxSettings.hostReducedMotion
            if snapImmediately {
                liveStore.snap(trackId, Self.hoverProp, to: target)
                lastHoverTargetById[nid] = target
                continue
            }
            if prevTarget == nil {
                liveStore.snap(trackId, Self.hoverProp, to: 0.0)
                if target > 0.5 && !(held && !forceNow) {
                    let anim = hoverCurvesById[nid]?.enter ?? .instant
                    liveStore.set(trackId, Self.hoverProp, to: 1.0, anim: anim, at: now)
                    lastHoverTargetById[nid] = target
                } else {
                    lastHoverTargetById[nid] = 0.0
                }
            } else if prevTarget != target {
                if held && !forceNow {
                    continue
                }
                let curves = hoverCurvesById[nid]
                let defaultAnim: Anim<Float> = target > 0.5 ? .instant : Anim<Float>(curve: .tween(duration: 0.1, easing: .easeOut))
                let anim = curves.map { target > 0.5 ? $0.enter : $0.exit } ?? defaultAnim
                if liveStore.get(trackId, Self.hoverProp) == nil {
                    liveStore.snap(trackId, Self.hoverProp, to: prevTarget!)
                }
                liveStore.set(trackId, Self.hoverProp, to: target, anim: anim, at: now)
                lastHoverTargetById[nid] = target
            }
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
            if (node.el.runtimeExtras[RenderExtrasKey.hoverGroupFocus] as? Bool) == true,
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
