import Foundation
import RuneMotion

private let runeHoverProp = Prop<Float>.custom(0x484F, .opacity, name: "hover")

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
                    var edit = editLens.get(state)
                    if fEl.isSecure {
                        edit.isSecure = true
                    }
                    if edit.isRichEnabled && !edit.isSecure, let html = content.html, !html.isEmpty {
                        edit.pasteHTML(html, plain: content.text)
                    } else if !content.text.isEmpty {
                        edit.paste(content.text)
                    }
                    editLens.set(&state, edit)
                    var tx = makeTx(at: now)
                    if fEl.layoutAnim == nil {
                        tx.instant()
                    }
                    if let onChange = fEl.handlers.onTextChange {
                        onChange(&state, edit.text, &tx)
                    }
                    applyTx(tx, at: now)
                    dirtyCommit(at: now)
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
        let pressedFocus = pressedKeyFocusPath
        pressedKeyFocusPath = nil

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

        for idx in chain {
            guard idx < flatNodes.count, let onUp = flatNodes[idx].el.handlers.onKeyUp else { continue }
            var tx = makeTx(at: now)
            let taken = onUp(&state, ev, &tx)
            _ = Tx.took(taken, &tx)
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: taken)
            if taken { return true }
        }
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

    // MARK: - Post-Frame Layout & Visibility Watches (`onDrawnLayout`, `drawnRectInto`, `onVisible`)

    private static func rectMoved(_ a: MotionRect?, _ b: MotionRect) -> Bool {
        guard let a else { return true }
        return abs(a.x - b.x) > 0.5 ||
            abs(a.y - b.y) > 0.5 ||
            abs(a.width - b.width) > 0.5 ||
            abs(a.height - b.height) > 0.5
    }

    internal func updatePostFrameLayoutWatches(at now: Double) {
        let viewportArea = max(1.0, viewport.x * viewport.y)
        let vpRect = MotionRect(left: 0, top: 0, right: viewport.x, bottom: viewport.y)
        var nextDrawn: [UInt64: (drawn: MotionRect, laid: MotionRect)] = [:]
        var nextVisible: [UInt64: Bool] = [:]

        var exitingFlags = [Bool](repeating: false, count: flatNodes.count)
        var springingFlags = [Bool](repeating: false, count: flatNodes.count)
        for i in flatNodes.indices {
            let n = flatNodes[i]
            let pExiting = n.parentIndex.map { exitingFlags[$0] } ?? false
            let pSpring = n.parentIndex.map { springingFlags[$0] } ?? false
            let nodeExiting: Bool
            if case .exiting = scene.phase(n.nodeId) {
                nodeExiting = true
            } else {
                nodeExiting = false
            }
            exitingFlags[i] = pExiting || nodeExiting
            springingFlags[i] = pSpring || scene.store.isAnimating(n.nodeId, Props.FRAME) || scene.store.isAnimating(n.nodeId, Props.RECT)
        }

        for (i, node) in flatNodes.enumerated() {
            let nid = node.nodeId.rawValue
            let exiting = exitingFlags[i]
            let rect = presentedRectByPath[node.path] ?? node.targetRect
            if !exiting, let liveRect = node.el.drawnRectLive,
               let lanes = rect.encodeLiveLanes() {
                _ = liveRect.source.publish(lanes, snap: true)
            }
            if !exiting, let onDrawn = node.el.handlers.onDrawnLayout {
                if springingFlags[i] {
                    if let old = drawnLayoutCache[nid] {
                        nextDrawn[nid] = old
                    }
                } else {
                    let prev = drawnLayoutCache[nid]
                    if Self.rectMoved(prev?.drawn, rect) {
                        nextDrawn[nid] = (drawn: rect, laid: node.targetRect)
                        var tx = makeTx(at: now)
                        onDrawn(&state, [rect.x, rect.y, rect.width, rect.height], &tx)
                        applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
                    } else if let prev {
                        nextDrawn[nid] = prev
                    } else {
                        nextDrawn[nid] = (drawn: rect, laid: node.targetRect)
                    }
                }
            }
            if !exiting, let onVis = node.el.handlers.onVisible {
                let clip = intersectRects(vpRect, node.clipRect)
                let inter = intersectRects(rect, clip)
                let elArea = max(0, rect.width) * max(0, rect.height)
                let interArea = max(0, inter.width) * max(0, inter.height)
                let nowVisible = elArea > 0 && (interArea >= elArea * 0.5 || interArea >= viewportArea * 0.5)
                nextVisible[nid] = nowVisible
                let wasVisible = visibleWatchState[nid] ?? false
                if nowVisible != wasVisible {
                    var tx = makeTx(at: now)
                    onVis(&state, nowVisible, &tx)
                    applyTx(tx, at: now)
                }
            }
        }

        drawnLayoutCache = nextDrawn
        visibleWatchState = nextVisible
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
        return node.el.hoverBg != nil || node.el.pressBg != nil ||
               node.el.isHoverGroup || node.el.isHoverAlone ||
               (!node.el.hasKitHoverDelays && h.onHover != nil) || h.onClick != nil || h.onClickPress != nil ||
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

    internal func refreshHoverAndSyncTracks(at now: Double, cut: Bool) {
        if cut {
            hoverHoldState = .free
            syncHoverTracks(at: now, cut: true, held: false)
            return
        }
        if hoverHoldState == .released && !layoutMoving() {
            hoverHoldState = .free
        }
        let ptrInWindow = pointerPosition.x > -9000 && pointerPosition.y > -9000
        let candidateHit = ptrInWindow ? hitTest(at: pointerPosition, predicate: Self.hoverHitPredicate) : nil
        let candidatePath = candidateHit?.node.path
        let candidateIndex = candidateHit?.node.index

        let groupHovered = makeGroupHoverPredicate()
        let shouldHold = decideHoverHold(
            candidatePath: candidatePath,
            candidateIndex: candidateIndex,
            groupHovered: groupHovered
        )
        if hoverHoldState != .released {
            hoverHoldState = shouldHold ? .held : .free
        }

        if shouldHold {
            hoveredLink = nil
            if let cur = hoveredPath, hoverLive(cur) == nil {
                hoveredPath = nil
                hoveredKey = nil
                if let oldIdx = nodeByPath[cur], !flatNodes[oldIdx].el.hasKitHoverDelays,
                   let cb = flatNodes[oldIdx].el.handlers.onHover {
                    isDispatchingHover = true
                    var tx = makeTx(at: currentTime)
                    cb(&state, false, &tx)
                    applyTx(tx, at: currentTime)
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
                let oldPath = hoveredPath
                hoveredPath = candidatePath
                hoveredKey = candidateHit?.node.key
                isDispatchingHover = true
                if let old = oldPath, let oldIdx = nodeByPath[old],
                   !flatNodes[oldIdx].el.hasKitHoverDelays,
                   let cb = flatNodes[oldIdx].el.handlers.onHover {
                    var tx = makeTx(at: currentTime)
                    cb(&state, false, &tx)
                    applyTx(tx, at: currentTime)
                }
                if let np = candidatePath, let newIdx = nodeByPath[np],
                   !flatNodes[newIdx].el.hasKitHoverDelays,
                   let cb = flatNodes[newIdx].el.handlers.onHover {
                    var tx = makeTx(at: currentTime)
                    cb(&state, true, &tx)
                    applyTx(tx, at: currentTime)
                }
                isDispatchingHover = false
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
            if focusVisible, let fp = focusedPath, (fp == node.path || fp.hasPrefix(node.path + "/")) {
                return true
            }
            return false
        }
    }
}
