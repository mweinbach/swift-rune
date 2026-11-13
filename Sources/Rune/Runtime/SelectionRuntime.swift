import Foundation
import RuneMotion

internal enum SelectionEdgeScrollState {
    case idle
    case running(scrollPath: String, last: Double, fromOffset: Double?, due: Double)
    case laying(scrollPath: String, last: Double, fromOffset: Double?, more: Bool)

    var isRunning: Bool {
        if case .idle = self { return false }
        return true
    }

    var scrollPath: String? {
        switch self {
        case .idle: return nil
        case .running(let p, _, _, _), .laying(let p, _, _, _): return p
        }
    }

    mutating func stop() {
        self = .idle
    }
}

/// Runtime-owned state for `El.selectable` text selection, drag tracking, pending `Tx` actions,
/// per-path click runs, edge auto-scroll, and `onSelectionChange` release coalescing
/// (`Sources/Rune/Runtime/Selection/*`).
internal struct RuntimeSelectionState {
    var coordinator = SelectionCoordinator()
    var isDraggingSelection: Bool = false
    var dragStartPos: Vec2 = .zero
    var suppressedClickOnRelease: Bool = false
    var isDispatchingSelectionChanges: Bool = false
    var lastDispatchedDragging: Bool = false
    var pendingSelectTextRequest: (key: String, range: Range<Int>)? = nil
    var pendingSelectAllKey: String? = nil
    var lastClickPath: String? = nil
    var lastClickTime: Double = -10.0
    var lastClickPos: Vec2 = Vec2(-10000, -10000)
    var clickCount: Int = 0
    var edgeScroll: SelectionEdgeScrollState = .idle

    mutating func clearClicks() {
        lastClickPath = nil
        clickCount = 0
    }

    mutating func notePrimaryPress(path: String, at pos: Vec2, now: Double) -> Int {
        let dt = now - lastClickTime
        let dist = hypotf(pos.x - lastClickPos.x, pos.y - lastClickPos.y)
        if path == lastClickPath && dt <= 0.35 && dist <= 4.0 {
            clickCount += 1
        } else {
            clickCount = 1
        }
        lastClickPath = path
        lastClickTime = now
        lastClickPos = pos
        return min(3, max(1, clickCount))
    }
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
                let uncopied = jNode.el.uncopiedRanges
                let slice: String = byteRange.isEmpty
                    ? ""
                    : CopyJoin.copySlice(in: fullText, range: byteRange, uncopied: uncopied)
                let trimmed = SelectionMath.trimUncopied(uncopied, range: (0, len))
                let whole = !byteRange.isEmpty
                    && len > 0
                    && byteRange.lowerBound <= trimmed.0
                    && byteRange.upperBound >= trimmed.1
                pieces.append(SelectedText(
                    path: relPath,
                    key: jNode.key,
                    range: byteRange,
                    len: len,
                    whole: whole,
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
            let copyBreaks = node.el.copyBreaksPair
            out.append(SelectableNodeSnapshot(
                path: node.path,
                key: node.key,
                parentPath: node.parentIndex.map { flatNodes[$0].path },
                isSelectable: isSel,
                isSelectionGroup: !node.effectiveInert && node.el.isSelectionGroup,
                isFocusedTextInput: node.path == focusedPath && node.el.handlers.editLens != nil,
                text: text,
                rect: presentedRectByPath[node.path] ?? node.targetRect,
                uncopied: node.el.uncopiedRanges,
                copyBreakBefore: copyBreaks.before,
                copyBreakAfter: copyBreaks.after,
                copyPrefix: node.el.copyPrefixString
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
            pills: node.el.pillChips,
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

    private func isTopSelectableInputTarget(_ node: FlatNode) -> Bool {
        if node.el.isSelectable { return true }
        if let geom = hitGeometryByPath[node.path], geom.hasVisualBlocker || geom.isInteractiveBlocker {
            return true
        }
        let h = node.el.handlers
        return node.el.background.a > 0.001
            || node.el.gradient != nil
            || (node.el.borderWidth > 0 && node.el.borderColor.a > 0.001)
            || node.el.imagePayload != nil
            || node.el.backdropBlur >= 0.5
            || !node.el.shapes.isEmpty
            || h.onClick != nil || h.onClickPress != nil || h.onDoubleClick != nil
            || h.onPointerDown != nil || h.onDrag != nil || h.dragOut != nil
            || node.el.attachedDragOutItem != nil || h.editLens != nil
            || h.onSecondaryClick != nil || nodeTakesFocus(node.el)
            || node.el.explicitHit || node.el.isModal
    }

    private func selectableHitNode(at pos: Vec2) -> FlatNode? {
        guard let topHit = hitTest(at: pos, predicate: { self.isTopSelectableInputTarget($0) }),
              let content = selectableNodeText(topHit.node),
              !content.isEmpty else {
            return nil
        }
        return topHit.node
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
            selectionState.clearClicks()
            selectionState.edgeScroll.stop()
            if selectionState.coordinator.phase.selection != nil {
                selectionState.coordinator.phase.clear()
                selectionState.isDraggingSelection = false
                dirtyCommit(at: now)
                dispatchSelectionChanges(at: now)
            }
            return
        }
        let sHitNode = selectableHitNode(at: pos)
        let qualifies: Bool = {
            guard let sHitNode else { return false }
            guard let interactive = hitInteractiveNode else { return true }
            return sHitNode.path == interactive.path || sHitNode.path.hasPrefix(interactive.path + "/")
        }()
        guard qualifies, let sNode = sHitNode, let content = selectableNodeText(sNode), !content.isEmpty else {
            selectionState.clearClicks()
            selectionState.edgeScroll.stop()
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
        let clicks = selectionState.notePrimaryPress(path: sNode.path, at: pos, now: now)
        let snaps = selectableSnapshots()
        let sSnapIdx = snaps.firstIndex(where: { $0.path == sNode.path })
        let sGroup = sSnapIdx.flatMap { SelectAllResolver.groupPath(forNodeAt: $0, in: snaps) }
        if let sGroup {
            selectionState.coordinator.pick.noteClick(groupPath: sGroup)
        }
        let interactiveTakesDrag: Bool = {
            guard let h = hitInteractiveNode?.el.handlers else { return false }
            return h.onDrag != nil || h.dragOut != nil || hitInteractiveNode?.el.attachedDragOutItem != nil
        }()

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
                if interactiveTakesDrag {
                    selectionState.coordinator.phase.place(updated)
                    selectionState.isDraggingSelection = false
                } else {
                    selectionState.coordinator.phase.startDrag(selection: updated, unit: .character)
                    selectionState.isDraggingSelection = true
                    selectionState.dragStartPos = pos
                }
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
                if interactiveTakesDrag {
                    selectionState.coordinator.phase.place(updated)
                    selectionState.isDraggingSelection = false
                } else {
                    selectionState.coordinator.phase.startDrag(selection: updated, unit: .character)
                    selectionState.isDraggingSelection = true
                    selectionState.dragStartPos = pos
                }
                selectionState.suppressedClickOnRelease = false
                dirtyCommit(at: now)
                dispatchSelectionChanges(at: now)
                return
            }
        }

        let unit = SelectionUnit.forClickCount(clicks)
        let origin = SelectionMath.unitRange(in: content, at: offset, unit: unit, uncopied: sNode.el.uncopiedRanges)
        let initialSel = ActiveSelection(
            path: sNode.path,
            content: content,
            anchor: origin.0,
            focus: origin.1,
            origin: origin
        )
        if interactiveTakesDrag {
            // Inside an onDrag/dragOut container, clicks place word/paragraph selection while drags move the row.
            selectionState.coordinator.phase.place(initialSel)
            selectionState.isDraggingSelection = false
        } else {
            selectionState.coordinator.phase.startDrag(selection: initialSel, unit: unit)
            selectionState.isDraggingSelection = true
            selectionState.dragStartPos = pos
        }
        selectionState.suppressedClickOnRelease = false
        dirtyCommit(at: now)
        dispatchSelectionChanges(at: now)
    }

    func handleSelectableSecondaryClick(at pos: Vec2, at now: Double) {
        guard let sNode = selectableHitNode(at: pos),
              let content = selectableNodeText(sNode),
              !content.isEmpty else {
            return
        }
        #if os(macOS)
        let offset = selectableHitOffset(node: sNode, windowPos: pos)
        let activeRange = currentTextSelection()?.texts.first(where: { $0.path == sNode.path })?.range
        let outsideCurrent = activeRange.map { offset < $0.lowerBound || offset >= $0.upperBound } ?? true
        if outsideCurrent {
            let word = SelectionMath.unitRange(in: content, at: offset, unit: .word, uncopied: sNode.el.uncopiedRanges)
            selectionState.clearClicks()
            selectionState.isDraggingSelection = false
            selectionState.edgeScroll.stop()
            selectionState.coordinator.phase.place(ActiveSelection(
                path: sNode.path,
                content: content,
                anchor: word.0,
                focus: word.1,
                origin: word
            ))
            let snaps = selectableSnapshots()
            if let sIdx = snaps.firstIndex(where: { $0.path == sNode.path }),
               let sGroup = SelectAllResolver.groupPath(forNodeAt: sIdx, in: snaps) {
                selectionState.coordinator.pick.noteClick(groupPath: sGroup)
            }
            dirtyCommit(at: now)
            dispatchSelectionChanges(at: now)
        }
        #endif

        let copied = copySelectionText()
        let menu = PopupMenu().item(
            "copy",
            "Copy",
            enabled: copied != nil,
            keyEquivalent: "mod+c"
        )
        enqueuePopupRequest(ErasedPopupRequest(
            menu: menu,
            anchor: .point(pos.x, pos.y),
            onPick: { _, picked, tx in
                if picked == "copy", let copied {
                    tx.copyText(copied)
                }
            }
        ))
        popupNeedsLayout = true
        dirtyCommit(at: now)
    }

    func handleSelectablePointerMove(to pos: Vec2, mods: Mods, at now: Double) -> Bool {
        _ = mods
        guard !hasActivePointerDrag else {
            selectionState.edgeScroll.stop()
            return false
        }
        guard selectionState.isDraggingSelection,
              case .dragging(var sel, let unit) = selectionState.coordinator.phase else {
            selectionState.edgeScroll.stop()
            return false
        }
        guard let anchorIdx = resolvedNodeIndex(forPath: sel.path) else {
            selectionState.isDraggingSelection = false
            selectionState.edgeScroll.stop()
            selectionState.coordinator.phase.clear()
            dirtyCommit(at: now)
            return false
        }
        updateSelectableEdgeScrollOnMove(pos: pos, anchorIdx: anchorIdx, at: now)
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

        let targetUnit = SelectionMath.unitRange(
            in: targetContent,
            at: rawOffset,
            unit: unit,
            uncopied: flatNodes[targetIdx].el.uncopiedRanges
        )
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
        selectionState.edgeScroll.stop()
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
            var tx = makeTx(at: now)
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

    // MARK: - Drag Edge Auto-Scroll (`crates/rune/src/runtime/selection/edge_scroll.rs`)

    private struct SelectionEdgeInfo {
        var scrollPath: String
        var speed: Float
        var room: Double
        var offset: Double
    }

    var hasActiveSelectableEdgeScroll: Bool {
        selectionState.edgeScroll.isRunning
    }

    func nextSelectableEdgeScrollWakeDeadline(after now: Double) -> Double? {
        switch selectionState.edgeScroll {
        case .running(_, _, _, let due):
            return max(now, due)
        case .laying(_, _, _, let more):
            return more ? now : nil
        case .idle:
            return nil
        }
    }

    private func selectableEdgeAt(windowY: Float, anchorIdx: Int) -> SelectionEdgeInfo? {
        guard selectionState.isDraggingSelection, selectionState.coordinator.phase.isDragging else {
            return nil
        }
        var cur: Int? = anchorIdx
        var scrollNode: FlatNode? = nil
        while let idx = cur, idx < flatNodes.count {
            let candidate = flatNodes[idx]
            if candidate.el.layout.scrollAxes.contains(.vertical) {
                scrollNode = candidate
                break
            }
            cur = candidate.parentIndex
        }
        guard let sNode = scrollNode else { return nil }
        let sPath = sNode.path
        let maxY = Double(scrollMaxExtents[sPath]?.y ?? 0)
        guard maxY > 0 else { return nil }
        let offset = Double(scrollOffsets[sPath]?.y ?? 0)
        let rawRect = presentedRectByPath[sPath] ?? sNode.targetRect
        let windowRect = MotionRect.fromXYWH(0, 0, viewport.x, viewport.y)
        let visible = intersectRects(intersectRects(sNode.clipRect, rawRect), windowRect)
        let atEdge: Float = 1.0
        guard visible.bottom - visible.top > 2.0 * atEdge else { return nil }

        let speedValue: Float
        let room: Double
        if windowY >= visible.bottom - atEdge {
            let past = max(Float(8.0), windowY - (visible.bottom - atEdge))
            speedValue = min(4000.0, 10.0 * past)
            room = max(0.0, maxY - offset)
        } else if windowY <= visible.top + atEdge {
            let past = max(Float(8.0), (visible.top + atEdge) - windowY)
            speedValue = -min(4000.0, 10.0 * past)
            room = max(0.0, offset)
        } else {
            return nil
        }
        guard room > 0.0, abs(speedValue) > 0.0 else { return nil }
        return SelectionEdgeInfo(scrollPath: sPath, speed: speedValue, room: room, offset: offset)
    }

    private func updateSelectableEdgeScrollOnMove(pos: Vec2, anchorIdx: Int, at now: Double) {
        guard let edge = selectableEdgeAt(windowY: pos.y, anchorIdx: anchorIdx) else {
            selectionState.edgeScroll.stop()
            return
        }
        if case .running(let existingPath, _, _, _) = selectionState.edgeScroll, existingPath == edge.scrollPath {
            return
        }
        selectionState.edgeScroll = .running(scrollPath: edge.scrollPath, last: now, fromOffset: nil, due: now)
    }

    @discardableResult
    func stepSelectableEdgeScroll(at now: Double) -> Bool {
        guard case .running(let scrollPath, let last, let fromOffset, let due) = selectionState.edgeScroll,
              now >= due,
              case .dragging(let sel, _) = selectionState.coordinator.phase,
              let anchorIdx = resolvedNodeIndex(forPath: sel.path),
              let edge = selectableEdgeAt(windowY: pointerPosition.y, anchorIdx: anchorIdx),
              edge.scrollPath == scrollPath else {
            if case .running = selectionState.edgeScroll,
               case .dragging(let sel, _) = selectionState.coordinator.phase,
               let anchorIdx = resolvedNodeIndex(forPath: sel.path),
               selectableEdgeAt(windowY: pointerPosition.y, anchorIdx: anchorIdx) == nil {
                selectionState.edgeScroll.stop()
            }
            return false
        }
        if let prevOffset = fromOffset, abs(edge.offset - prevOffset) <= 1e-9 {
            selectionState.edgeScroll.stop()
            return false
        }
        let dt = min(max(0.0, now - last), 0.05)
        guard dt > 1e-9 else {
            selectionState.edgeScroll = .running(
                scrollPath: scrollPath,
                last: last,
                fromOffset: fromOffset,
                due: now + (1.0 / 60.0)
            )
            return false
        }
        var by = Double(edge.speed) * dt
        let reachedEnd: Bool
        if edge.room - abs(by) <= 1e-3 {
            by = edge.speed >= 0 ? edge.room : -edge.room
            reachedEnd = true
        } else {
            reachedEnd = false
        }
        let maxY = Double(scrollMaxExtents[scrollPath]?.y ?? 0)
        let curOffset = scrollOffsets[scrollPath] ?? .zero
        let nextY = Float((Double(curOffset.y) + by).clamped(to: 0.0...maxY))
        if abs(nextY - curOffset.y) <= 1e-6 {
            selectionState.edgeScroll.stop()
            return false
        }
        let updated = Vec2(curOffset.x, nextY)
        scrollOffsets[scrollPath] = updated
        if nextY < Float(maxY) - 0.5 {
            wasPinnedToBottom.remove(scrollPath)
        }
        scrollStore.snap(NodeId.hash("scroll:" + scrollPath), Props.SCROLL, to: updated)
        selectionState.edgeScroll = .laying(
            scrollPath: scrollPath,
            last: now,
            fromOffset: by != 0 ? edge.offset : nil,
            more: !reachedEnd
        )
        dirtyCommit(at: now)
        return true
    }

    func laidSelectableEdgeScroll(at now: Double) {
        guard case .laying(let scrollPath, let last, let fromOffset, let more) = selectionState.edgeScroll else {
            return
        }
        if more {
            selectionState.edgeScroll = .running(
                scrollPath: scrollPath,
                last: last,
                fromOffset: fromOffset,
                due: last + (1.0 / 60.0)
            )
        } else {
            selectionState.edgeScroll.stop()
        }
        _ = handleSelectablePointerMove(to: pointerPosition, mods: .none, at: now)
    }
}
