import Foundation
import RuneMotion

/// Runtime-owned state for `El.selectable` text selection, drag tracking, pending `Tx` actions,
/// and `onSelectionChange` release coalescing (`Sources/Rune/Runtime/Selection/*`).
internal struct RuntimeSelectionState {
    var coordinator = SelectionCoordinator()
    var isDraggingSelection: Bool = false
    var dragStartPos: Vec2 = .zero
    var suppressedClickOnRelease: Bool = false
    var isDispatchingSelectionChanges: Bool = false
    var lastDispatchedDragging: Bool = false
    var pendingSelectTextRequest: (key: String, range: Range<Int>)? = nil
    var pendingSelectAllKey: String? = nil
}

/// Optional ink override + local selection line rects returned to `buildRefScene` glyph emission.
internal struct SelectablePaintInk {
    var ink: Color
    var rects: [SIMD4<Float>]

    func color(for glyph: PositionedGlyph) -> Color? {
        let cx = glyph.rect.x + glyph.rect.z * 0.5
        let cy = glyph.rect.y + glyph.rect.w * 0.5
        for r in rects {
            if cx >= r.x - 0.5 && cx <= r.x + r.z + 0.5 && cy >= r.y - 0.5 && cy <= r.y + r.w + 0.5 {
                return ink
            }
        }
        return nil
    }
}

private struct SelectableBandBox {
    var idx: Int
    var rect: MotionRect
}

private struct SelectableBand {
    var top: Float
    var bottom: Float
    var range: Range<Int>
}

public extension Runtime {
    /// Current `TextSelection` snapshot across mounted `El.selectable` elements (`Runtime::selection`).
    func currentTextSelection() -> TextSelection? {
        guard selectionState.coordinator.phase.selection != nil else { return nil }
        return selectionState.coordinator.currentSelection(in: selectableSnapshots())
    }

    /// Plain joined text of the active `El.selectable` selection without `El.selectionCopy`
    /// overrides (`Runtime::selected_text`).
    func selectedText() -> String? {
        guard let text = currentTextSelection()?.text, !text.isEmpty else { return nil }
        return text
    }

    /// Clipboard string produced by copying the active `El.selectable` selection, honoring the
    /// nearest `El.selectionCopy` handler spanning the selection (`Runtime::copy_text`).
    func copySelectionText() -> String? {
        let snaps = selectableSnapshots()
        guard let sel = selectionState.coordinator.currentSelection(in: snaps),
              let firstSel = sel.texts.first,
              let lastSel = sel.texts.last else {
            return nil
        }
        guard let firstIdx = nodeByPath[firstSel.path],
              let lastIdx = nodeByPath[lastSel.path] else {
            return sel.text.isEmpty ? nil : sel.text
        }
        let isDescendant: (Int, Int) -> Bool = { nodeIdx, ancestorIdx in
            var cur: Int? = nodeIdx
            while let i = cur {
                if i == ancestorIdx { return true }
                cur = self.flatNodes[i].parentIndex
            }
            return false
        }
        var providerIdx: Int? = nil
        var walk: Int? = firstIdx
        while let p = walk {
            if !flatNodes[p].effectiveInert && flatNodes[p].el.hasSelectionCopyHandler && isDescendant(lastIdx, p) {
                providerIdx = p
                break
            }
            walk = flatNodes[p].parentIndex
        }
        if let p = providerIdx {
            let pNode = flatNodes[p]
            let group = SelectAllResolver.groupPath(
                forNodeAt: snaps.firstIndex(where: { $0.path == firstSel.path }) ?? 0,
                in: snaps
            )
            var rangeByPath: [String: Range<Int>] = [:]
            for item in sel.texts {
                rangeByPath[item.path] = item.range
            }
            var pieces: [SelectedText] = []
            for j in p..<flatNodes.count {
                if !isDescendant(j, p) { break }
                let jNode = flatNodes[j]
                guard let fullText = selectableNodeText(jNode), !fullText.isEmpty else { continue }
                if let g = group {
                    guard let sIdx = snaps.firstIndex(where: { $0.path == jNode.path }),
                          SelectAllResolver.groupPath(forNodeAt: sIdx, in: snaps) == g else {
                        continue
                    }
                } else if j != firstIdx {
                    continue
                }
                let relPath: String
                if j == p {
                    relPath = ""
                } else if jNode.path.hasPrefix(pNode.path + "/") {
                    relPath = String(jNode.path.dropFirst(pNode.path.count + 1))
                } else {
                    relPath = jNode.path
                }
                let byteRange = rangeByPath[jNode.path] ?? 0..<0
                let len = fullText.utf8.count
                let slice: String
                if byteRange.isEmpty {
                    slice = ""
                } else {
                    let utf8 = Array(fullText.utf8)
                    let lo = SelectionMath.floorCharBoundary(in: fullText, offset: byteRange.lowerBound)
                    let hi = max(lo, SelectionMath.floorCharBoundary(in: fullText, offset: byteRange.upperBound))
                    slice = String(decoding: utf8[lo..<hi], as: UTF8.self)
                }
                pieces.append(SelectedText(
                    path: relPath,
                    key: jNode.key,
                    range: byteRange,
                    len: len,
                    whole: !byteRange.isEmpty && byteRange.lowerBound == 0 && byteRange.upperBound == len,
                    text: slice,
                    content: fullText
                ))
            }
            let providerSel = TextSelection(texts: pieces, text: sel.text, backward: sel.backward)
            if let custom = pNode.el.invokeSelectionCopy(providerSel) {
                return custom
            }
        }
        return sel.text.isEmpty ? nil : sel.text
    }
}

internal extension Runtime {
    func makeTx() -> Tx {
        var tx = Tx()
        if let sel = currentTextSelection() {
            tx.setCurrentTextSelection(sel)
        }
        return tx
    }

    func selectableNodeText(_ node: FlatNode) -> String? {
        guard !node.effectiveInert,
              !node.el.isSecure,
              node.el.handlers.editLens == nil,
              node.el.isSelectable else {
            return nil
        }
        if let live = node.el.liveText?.get() { return live }
        if let plain = node.el.plainText { return plain }
        if let spans = node.el.richSpans { return spans.map(\.text).joined() }
        return nil
    }

    func selectableSnapshots() -> [SelectableNodeSnapshot] {
        var out: [SelectableNodeSnapshot] = []
        out.reserveCapacity(flatNodes.count)
        for node in flatNodes {
            let text = selectableNodeText(node) ?? ""
            let isSel = !node.effectiveInert && !node.el.isSecure && node.el.handlers.editLens == nil && node.el.isSelectable
            out.append(SelectableNodeSnapshot(
                path: node.path,
                key: node.key,
                parentPath: node.parentIndex.map { flatNodes[$0].path },
                isSelectable: isSel,
                isSelectionGroup: !node.effectiveInert && node.el.isSelectionGroup,
                isFocusedTextInput: node.path == focusedPath && node.el.handlers.editLens != nil,
                text: text,
                rect: presentedRectByPath[node.path] ?? node.targetRect
            ))
        }
        return out
    }

    func preservesTextSelectionInChain(_ node: FlatNode?) -> Bool {
        var cur = node
        while let n = cur {
            if n.el.preservesTextSelection { return true }
            cur = n.parentIndex.map { flatNodes[$0] }
        }
        return false
    }

    func selectableHitOffset(node: FlatNode, windowPos: Vec2) -> Int {
        let displayText = selectableNodeText(node) ?? ""
        guard !displayText.isEmpty else { return 0 }
        let rect = presentedRectByPath[node.path] ?? node.targetRect
        let sc = presentedScaleByPath[node.path] ?? Vec2(1, 1)
        let innerW = max(0, rect.width - (node.el.layout.padding.left + node.el.layout.padding.right) * sc.x)
        let wrapWidth = (innerW / max(1e-4, sc.x)) + 0.5
        let shaped = textSystem.shape(
            text: displayText,
            spans: node.el.richSpans,
            style: node.el.textStyle,
            maxWidth: wrapWidth,
            pixelScale: pixelScale,
            emitGlyphs: false
        )
        let unturned = hitGeometryByPath[node.path]?.turn?.unturn(windowPos) ?? windowPos
        let localX = (unturned.x - (rect.x + node.el.layout.padding.left * sc.x)) / max(1e-4, sc.x)
        let localY = (unturned.y - (rect.y + node.el.layout.padding.top * sc.y)) / max(1e-4, sc.y)
        let raw = textSystem.hitTestUTF8Offset(in: shaped, localX: localX, localY: localY, pixelScale: pixelScale)
        return SelectionMath.floorCharBoundary(in: displayText, offset: raw)
    }

    func handleSelectablePointerDown(
        at pos: Vec2,
        button: PointerButton,
        mods: Mods,
        hitInteractiveNode: FlatNode?,
        at now: Double
    ) {
        guard button == .primary else { return }
        if preservesTextSelectionInChain(hitInteractiveNode) {
            return
        }
        if hitInteractiveNode?.el.handlers.editLens != nil {
            if selectionState.coordinator.phase.selection != nil {
                selectionState.coordinator.phase.clear()
                selectionState.isDraggingSelection = false
                dirtyCommit(at: now)
                dispatchSelectionChanges(at: now)
            }
            return
        }
        let sHit = hitTest(at: pos) { node in
            guard let text = self.selectableNodeText(node), !text.isEmpty else { return false }
            return true
        }
        let qualifies: Bool = {
            guard let sHit else { return false }
            guard let interactive = hitInteractiveNode else { return true }
            return sHit.node.path == interactive.path || sHit.node.path.hasPrefix(interactive.path + "/")
        }()
        guard qualifies, let sNode = sHit?.node, let content = selectableNodeText(sNode), !content.isEmpty else {
            if selectionState.coordinator.phase.selection != nil {
                selectionState.coordinator.phase.clear()
                selectionState.isDraggingSelection = false
                selectionState.suppressedClickOnRelease = false
                dirtyCommit(at: now)
                dispatchSelectionChanges(at: now)
            }
            return
        }

        let offset = selectableHitOffset(node: sNode, windowPos: pos)
        let clicks = min(3, max(1, clickCount))
        let snaps = selectableSnapshots()
        let sSnapIdx = snaps.firstIndex(where: { $0.path == sNode.path })
        let sGroup = sSnapIdx.flatMap { SelectAllResolver.groupPath(forNodeAt: $0, in: snaps) }
        if let sGroup {
            selectionState.coordinator.pick.noteClick(groupPath: sGroup)
        }

        if mods.shift, clicks == 1, let existing = selectionState.coordinator.phase.selection {
            let anchorSnapIdx = snaps.firstIndex(where: { $0.path == existing.path })
            let anchorGroup = anchorSnapIdx.flatMap { SelectAllResolver.groupPath(forNodeAt: $0, in: snaps) }
            if existing.path == sNode.path {
                let updated = ActiveSelection(
                    path: existing.path,
                    content: content,
                    anchor: existing.anchor,
                    focus: offset,
                    origin: (existing.anchor, existing.anchor),
                    far: nil
                )
                selectionState.coordinator.phase.startDrag(selection: updated, unit: .character)
                selectionState.isDraggingSelection = true
                selectionState.dragStartPos = pos
                selectionState.suppressedClickOnRelease = false
                dirtyCommit(at: now)
                dispatchSelectionChanges(at: now)
                return
            } else if let sGroup, let anchorGroup, sGroup == anchorGroup {
                let updated = ActiveSelection(
                    path: existing.path,
                    content: existing.content,
                    anchor: existing.anchor,
                    focus: offset,
                    origin: existing.origin,
                    far: SelectionFar(path: sNode.path, content: content)
                )
                selectionState.coordinator.phase.startDrag(selection: updated, unit: .character)
                selectionState.isDraggingSelection = true
                selectionState.dragStartPos = pos
                selectionState.suppressedClickOnRelease = false
                dirtyCommit(at: now)
                dispatchSelectionChanges(at: now)
                return
            }
        }

        let unit = SelectionUnit.forClickCount(clicks)
        let origin = SelectionMath.unitRange(in: content, at: offset, unit: unit)
        selectionState.coordinator.phase.startDrag(
            selection: ActiveSelection(
                path: sNode.path,
                content: content,
                anchor: origin.0,
                focus: origin.1,
                origin: origin
            ),
            unit: unit
        )
        selectionState.isDraggingSelection = true
        selectionState.dragStartPos = pos
        selectionState.suppressedClickOnRelease = false
        dirtyCommit(at: now)
        dispatchSelectionChanges(at: now)
    }

    func handleSelectablePointerMove(to pos: Vec2, mods: Mods, at now: Double) -> Bool {
        _ = mods
        guard selectionState.isDraggingSelection,
              case .dragging(var sel, let unit) = selectionState.coordinator.phase else {
            return false
        }
        guard let anchorIdx = resolvedNodeIndex(forPath: sel.path) else {
            selectionState.isDraggingSelection = false
            selectionState.coordinator.phase.clear()
            dirtyCommit(at: now)
            return false
        }
        sel.path = flatNodes[anchorIdx].path
        let snaps = selectableSnapshots()
        let anchorGroup = SelectAllResolver.groupPath(forNodeAt: anchorIdx, in: snaps)

        let resolvedTarget: (idx: Int, offset: Int)?
        if let gPath = anchorGroup {
            resolvedTarget = groupPointTarget(groupPath: gPath, anchorIdx: anchorIdx, snaps: snaps, at: pos)
        } else {
            resolvedTarget = (anchorIdx, selectableHitOffset(node: flatNodes[anchorIdx], windowPos: pos))
        }
        guard let (targetIdx, rawOffset) = resolvedTarget,
              let targetContent = selectableNodeText(flatNodes[targetIdx]) else {
            return true
        }

        let targetUnit = SelectionMath.unitRange(in: targetContent, at: rawOffset, unit: unit)
        if targetIdx == anchorIdx {
            let ext = SelectionMath.extendSelection(origin: sel.origin, at: targetUnit)
            sel.anchor = ext.anchor
            sel.focus = ext.focus
            sel.far = nil
        } else {
            if targetIdx > anchorIdx {
                sel.anchor = sel.originStart
                sel.focus = targetUnit.1
            } else {
                sel.anchor = sel.originEnd
                sel.focus = targetUnit.0
            }
            sel.far = SelectionFar(path: flatNodes[targetIdx].path, content: targetContent)
        }
        selectionState.coordinator.phase.startDrag(selection: sel, unit: unit)
        if hypot(pos.x - selectionState.dragStartPos.x, pos.y - selectionState.dragStartPos.y) > 4.0,
           selectedText() != nil {
            selectionState.suppressedClickOnRelease = true
        }
        dirtyCommit(at: now)
        dispatchSelectionChanges(at: now)
        return true
    }

    func handleSelectablePointerUp(at pos: Vec2, button: PointerButton, at now: Double) -> Bool {
        _ = pos
        guard button == .primary, selectionState.isDraggingSelection else {
            return false
        }
        selectionState.isDraggingSelection = false
        let suppressClick = selectionState.suppressedClickOnRelease && selectedText() != nil
        selectionState.suppressedClickOnRelease = false
        selectionState.coordinator.phase.endDrag()
        dirtyCommit(at: now)
        dispatchSelectionChanges(at: now)
        return suppressClick
    }

    func handleSelectableKeyDown(_ ev: KeyEvent, at now: Double) -> Bool {
        if let fPath = focusedPath, let fIdx = nodeByPath[fPath], flatNodes[fIdx].el.handlers.editLens != nil {
            return false
        }
        let plain = ev.mods.primaryCommand && !ev.mods.shift && !ev.mods.alt && !(ev.mods.ctrl && ev.mods.cmd)
        guard plain else { return false }

        let isC = ev.key == .command("c") || ev.key == .text("c") || ev.key == .text("C")
        let isA = ev.key == .command("a") || ev.key == .text("a") || ev.key == .text("A")
        if isC {
            guard let copied = copySelectionText() else { return false }
            clipboard = ClipboardContent(copied)
            richClipboard = RichClipboardPayload(content: clipboard)
            return true
        }
        if isA {
            let outcome = selectionState.coordinator.handleSelectAll(
                in: selectableSnapshots(),
                appHandledCmdA: false
            )
            if case .selectGroup = outcome {
                dirtyCommit(at: now)
                dispatchSelectionChanges(at: now)
                return true
            }
            return false
        }
        return false
    }

    func applySelectionTx(_ tx: Tx, at now: Double) {
        if tx.clearTextSelectionRequested {
            selectionState.pendingSelectTextRequest = nil
            selectionState.pendingSelectAllKey = nil
            selectionState.coordinator.phase.clear()
            dirtyCommit(at: now)
            return
        }
        if let key = tx.pendingSelectAllTextKey {
            selectionState.pendingSelectTextRequest = nil
            let snaps = selectableSnapshots()
            if snaps.isEmpty || selectionState.coordinator.selectAllText(key: key, in: snaps) == nil {
                selectionState.pendingSelectAllKey = key
            } else {
                selectionState.pendingSelectAllKey = nil
            }
            dirtyCommit(at: now)
        } else if let req = tx.pendingSelectTextRequest {
            selectionState.pendingSelectAllKey = nil
            let snaps = selectableSnapshots()
            if snaps.isEmpty || selectionState.coordinator.selectText(key: req.key, range: req.range, in: snaps) == nil {
                selectionState.pendingSelectTextRequest = req
            } else {
                selectionState.pendingSelectTextRequest = nil
            }
            dirtyCommit(at: now)
        }
    }

    func finalizeSelectionAfterCommit(at now: Double) {
        let snaps = selectableSnapshots()
        if let pendingAll = selectionState.pendingSelectAllKey {
            selectionState.pendingSelectAllKey = nil
            _ = selectionState.coordinator.selectAllText(key: pendingAll, in: snaps)
        } else if let pendingReq = selectionState.pendingSelectTextRequest {
            selectionState.pendingSelectTextRequest = nil
            _ = selectionState.coordinator.selectText(key: pendingReq.key, range: pendingReq.range, in: snaps)
        }
        reconcileSelectionPhaseAgainstTree()
        dispatchSelectionChanges(at: now)
    }

    func computeActiveSelectionRangesByPath() -> [String: Range<Int>] {
        guard let sel = currentTextSelection() else { return [:] }
        var map: [String: Range<Int>] = [:]
        map.reserveCapacity(sel.texts.count)
        for item in sel.texts where !item.range.isEmpty {
            map[item.path] = item.range
        }
        return map
    }

    func emitSelectableHighlightIfNeeded(
        snap: FlatNode,
        el: El<State>,
        isExiting: Bool,
        activeSelectionRanges: [String: Range<Int>],
        textOriginX: Float,
        textOriginY: Float,
        scaleVec: Vec2,
        pxScale: Float,
        localAlpha: Float,
        shaped: ShapedText,
        devClip: SIMD4<Float>,
        useLayer: Bool,
        effRotate: Float,
        into primitives: inout [Primitive]
    ) -> SelectablePaintInk? {
        guard !isExiting,
              el.isSelectable,
              !el.isSecure,
              el.handlers.editLens == nil,
              let range = activeSelectionRanges[snap.path],
              !range.isEmpty else {
            return nil
        }
        let lineRects = textSystem.selectionRects(in: shaped, utf8Range: range, pixelScale: pxScale)
        guard !lineRects.isEmpty else { return nil }
        let style = resolvedSelectionStyle(for: snap)
        let picked = style?.pick(active: windowFocused)
        let fallbackHl = windowFocused
            ? (el.selectionColor ?? Tok.accent(0, dark: systemDark).alpha(0.28))
            : (el.selectionColor ?? Tok.accent(0, dark: systemDark).alpha(0.28)).scaleAlpha(0.55)
        let hlColor = (picked?.highlight ?? fallbackHl).scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
        let rot = useLayer ? 0 : effRotate
        for r in lineRects {
            primitives.append(.roundedRect(
                rect: SIMD4<Float>(
                    (textOriginX + r.x * scaleVec.x) * pxScale,
                    (textOriginY + r.y * scaleVec.y) * pxScale,
                    r.z * scaleVec.x * pxScale,
                    r.w * scaleVec.y * pxScale
                ),
                radii: SIMD4<Float>(repeating: 2.0 * pxScale),
                fill: hlColor,
                clip: devClip,
                turn: rot
            ))
        }
        if let ink = picked?.ink {
            return SelectablePaintInk(ink: ink, rects: lineRects)
        }
        return nil
    }

    private func resolvedNodeIndex(forPath path: String) -> Int? {
        if let idx = nodeByPath[path], idx < flatNodes.count, selectableNodeText(flatNodes[idx]) != nil {
            return idx
        }
        return flatNodes.firstIndex {
            selectableNodeText($0) != nil && SelectionMath.sameKeyedPath($0.path, path)
        }
    }

    private func reconcileSelectionPhaseAgainstTree() {
        guard let sel = selectionState.coordinator.phase.selection else { return }
        guard let anchorIdx = resolvedNodeIndex(forPath: sel.path),
              let anchorNow = selectableNodeText(flatNodes[anchorIdx]) else {
            selectionState.coordinator.phase.clear()
            selectionState.isDraggingSelection = false
            return
        }
        let anchorUpto = sel.far == nil ? min(sel.anchor, sel.focus) : min(sel.anchor, anchorNow.utf8.count)
        guard SelectionMath.kept(then: sel.content, now: anchorNow, upto: anchorUpto) else {
            selectionState.coordinator.phase.clear()
            selectionState.isDraggingSelection = false
            return
        }
        var updated = sel
        updated.path = flatNodes[anchorIdx].path
        if var far = sel.far {
            if let farIdx = resolvedNodeIndex(forPath: far.path),
               let farNow = selectableNodeText(flatNodes[farIdx]),
               SelectionMath.kept(then: far.content, now: farNow, upto: min(sel.focus, farNow.utf8.count)) {
                far.path = flatNodes[farIdx].path
                updated.far = far
            } else {
                selectionState.coordinator.phase.clear()
                selectionState.isDraggingSelection = false
                return
            }
        }
        if updated != sel {
            if case .dragging(_, let unit) = selectionState.coordinator.phase {
                selectionState.coordinator.phase.startDrag(selection: updated, unit: unit)
            } else {
                selectionState.coordinator.phase.place(updated)
            }
        }
    }

    private func dispatchSelectionChanges(at now: Double) {
        guard !selectionState.isDispatchingSelectionChanges else { return }
        selectionState.isDispatchingSelectionChanges = true
        defer { selectionState.isDispatchingSelectionChanges = false }

        let snaps = selectableSnapshots()
        let watchers: [(path: String, el: El<State>)] = flatNodes.compactMap { n in
            guard !n.effectiveInert, n.el.hasSelectionChangeHandler else { return nil }
            return (n.path, n.el)
        }
        let wasDragging = selectionState.lastDispatchedDragging
        let isDragging = selectionState.coordinator.phase.isDragging
        selectionState.lastDispatchedDragging = isDragging

        var changes = selectionState.coordinator.collectSelectionChanges(elements: watchers, nodes: snaps)
        if wasDragging && !isDragging, let active = selectionState.coordinator.currentSelection(in: snaps) {
            let selectedPaths = Set(active.texts.map(\.path))
            let alreadyFired = Set(changes.map(\.path))
            for (path, _) in watchers where !alreadyFired.contains(path) {
                if selectedPaths.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) {
                    changes.append((path, SelectionChange(selection: active, was: true, isDragging: false)))
                }
            }
        }
        guard !changes.isEmpty else { return }
        for (path, change) in changes {
            guard let idx = nodeByPath[path], idx < flatNodes.count else { continue }
            var tx = makeTx()
            if flatNodes[idx].el.invokeSelectionChange(state: &state, change: change, tx: &tx) {
                applyTx(tx, at: now)
            }
        }
    }

    private func resolvedSelectionStyle(for node: FlatNode) -> SelectionStyle? {
        var cur: FlatNode? = node
        while let n = cur {
            if let style = n.el.resolvedSelectionStyle {
                return style
            }
            cur = n.parentIndex.map { flatNodes[$0] }
        }
        return nil
    }

    private func groupPointTarget(
        groupPath: String,
        anchorIdx: Int,
        snaps: [SelectableNodeSnapshot],
        at pos: Vec2
    ) -> (idx: Int, offset: Int)? {
        var boxes: [SelectableBandBox] = []
        for (idx, snap) in snaps.enumerated() where snap.isSelectable && !snap.text.isEmpty {
            guard SelectAllResolver.groupPath(forNodeAt: idx, in: snaps) == groupPath else { continue }
            let rawRect = presentedRectByPath[snap.path] ?? flatNodes[idx].targetRect
            let shown = intersectRects(flatNodes[idx].clipRect, rawRect)
            if shown.width > 0 && shown.height > 0 {
                boxes.append(SelectableBandBox(idx: idx, rect: shown))
            }
        }
        guard !boxes.isEmpty else { return nil }
        boxes.sort { $0.rect.top < $1.rect.top }

        var bands: [SelectableBand] = []
        for (k, entry) in boxes.enumerated() {
            if let last = bands.last, entry.rect.top < last.bottom {
                bands[bands.count - 1].bottom = max(last.bottom, entry.rect.bottom)
                bands[bands.count - 1].range = last.range.lowerBound..<(k + 1)
            } else {
                bands.append(SelectableBand(top: entry.rect.top, bottom: entry.rect.bottom, range: k..<(k + 1)))
            }
        }

        func distX(_ rect: MotionRect, _ x: Float) -> Float {
            max(0, max(rect.left - x, x - rect.right))
        }

        if let band = bands.first(where: { pos.y >= $0.top && pos.y < $0.bottom }) {
            let best = boxes[band.range].min { distX($0.rect, pos.x) < distX($1.rect, pos.x) }!
            return (best.idx, selectableHitOffset(node: flatNodes[best.idx], windowPos: pos))
        }
        let above = bands.last(where: { $0.bottom <= pos.y })
        let below = bands.first(where: { $0.top > pos.y })
        if let below {
            let minBelowIdx = boxes[below.range].map(\.idx).min()!
            if above == nil || minBelowIdx <= anchorIdx {
                return (minBelowIdx, 0)
            }
        }
        if let above {
            let maxAboveIdx = boxes[above.range].map(\.idx).max()!
            let len = (selectableNodeText(flatNodes[maxAboveIdx]) ?? "").utf8.count
            return (maxAboveIdx, len)
        }
        return nil
    }
}
