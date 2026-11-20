import Foundation

// MARK: - Event Markers, Drag Lifecycle & Secondary Capture (`event_log.rs`, `secondary.rs`, `pointer.rs`, `drag_out_host.rs`)

internal enum RuntimeEventLog {
    static let capacity = 512

    static func push(_ events: inout [String], _ event: String) {
        if events.count >= capacity {
            events.removeFirst(capacity / 2)
        }
        events.append(event)
    }
}

extension Runtime {
    /// Indicates an active trace stream reading input markers (`Runtime::trace_channels`).
    public var traceChannelsActive: Bool {
        get { inputMachines.traceChannelsActive }
        set { inputMachines.traceChannelsActive = newValue }
    }

    internal func logInputEvent(_ event: @autoclosure () -> String) {
        logEvent(event())
    }

    // MARK: - Runtime Inspection & Pointer Utilities

    /// Whether an element currently owns keyboard focus (`Runtime::has_focus`).
    public func hasFocus() -> Bool {
        focusedPath != nil
    }

    /// Whether a primary or secondary press is currently held (`Runtime::pressing`).
    public func pressing() -> Bool {
        pressedPath != nil || inputMachines.secondaryCapture.isHeld
    }

    /// Current pointer coordinates in logical window points, or `nil` when outside (`Runtime::pointer`).
    public func pointer() -> Vec2? {
        guard pointerPosition.x > -9000, pointerPosition.y > -9000 else { return nil }
        return pointerPosition
    }

    /// Whether a file drag is currently hovering over the window (`Runtime::dragging_files`).
    public func draggingFiles() -> Bool {
        draggedFiles != nil
    }

    /// Delivers a repeated logical key event (`Runtime::repeat_key`).
    @discardableResult
    public func repeatKey(_ ev: KeyEvent, at now: Double) -> Bool {
        keyDown(ev, isRepeat: true, at: now)
    }

    /// Enables or disables host outbound OS drag support (`Runtime::set_os_drag`).
    public func setOsDrag(_ supported: Bool) {
        inputMachines.osDragSupported = supported
    }

    public var osDragSupported: Bool {
        inputMachines.osDragSupported
    }

    /// Sink used by the platform host to enqueue completed OS drag outcomes.
    public func dragEndSink() -> DragEndSink {
        inputMachines.dragEndSink
    }

    /// Queue a completed OS drag outcome from the platform host to drain on the next `frame`.
    public func queueDragEnd(path: String? = nil, _ outcome: DragOutcome) {
        inputMachines.dragEndSink.push(path: path, outcome)
    }

    /// Whether an outbound OS drag completion is pending (`Runtime::drag_ends_pending`).
    public var dragEndsPending: Bool {
        !inputMachines.dragEndSink.isEmpty
    }

    // MARK: - Pointer Leave, Window Move, Cancel & Lost Release

    /// Leaves the window without discarding an active capture (`Runtime::pointer_leave`).
    public func pointerLeave(at now: Double = 0.0) {
        let inputMark = beginInputDispatch(at: now)
        defer { endInputDispatch(inputMark) }
        if pressing() {
            wheelLost()
            inputMachines.pressedLeft = true
        } else {
            pointerExit(at: now)
        }
    }

    internal func leaveAfterRelease(at now: Double) {
        guard inputMachines.pressedLeft else { return }
        inputMachines.pressedLeft = false
        if !pressing() {
            pointerExit(at: now)
        }
    }

    /// Cancels all held pointer, drag, secondary, and file-drop captures (`Runtime::cancel_pointer`).
    public func cancelPointer(at now: Double = 0.0) {
        slice2State.autoscroll.cancel()
        _ = cancelActiveDrag(at: nil, time: now)
        armedDragOut = nil
        pendingDragOutStart = nil
        for i in inputMachines.untakenDragOuts.indices {
            inputMachines.untakenDragOuts[i].cancelledByHost = true
        }
        pressedPath = nil
        pressedKey = nil
        pressedLink = nil
        inputMachines.pressClicks.clear()
        // The run of presses on selectable text stays: `cancel_pointer` leaves
        // `selectable.presses` as it is (`pointer.rs::cancel_pointer`).
        inputMachines.firstDoubleClick = nil
        inputMachines.currentDoubleClickPair = nil
        inputMachines.secondaryCapture = .up
        inputMachines.pressedLeft = false
        pressedButton = .primary
        pressedPointerInside = false
        pressedTint = nil
        pointerExit(at: now)
        dragFilesLeave(at: now)
    }

    /// Shifts window-relative pointer & drag origin after the window moved `(dx, dy)` (`Runtime::window_moved`).
    public func windowMoved(dx: Float, dy: Float) {
        if pointerPosition.x > -9000, pointerPosition.y > -9000 {
            pointerPosition = Vec2(pointerPosition.x - dx, pointerPosition.y - dy)
        }
        if var drag = activeDrag {
            drag.startWindow = Vec2(drag.startWindow.x - dx, drag.startWindow.y - dy)
            activeDrag = drag
        }
        if let pt = inputMachines.pressedWindowPoint {
            inputMachines.pressedWindowPoint = Vec2(pt.x - dx, pt.y - dy)
        }
    }

    /// Ends a primary drag whose button-up was lost by the platform (`Runtime::pointer_release_lost`).
    public func pointerReleaseLost(at pos: Vec2, at now: Double = 0.0) {
        let movedPastSlop = (activeDrag?.movedBeyondSlop ?? false)
            || (inputMachines.pressedWindowPoint.map { !PressRun.withinSlop($0, pos) } ?? false)
        let left = inputMachines.pressedLeft
        if activeDrag != nil || selectionState.isDraggingSelection || selectionState.edgeScroll.isRunning {
            pointerPosition = pos
            if cancelActiveDrag(at: pos, time: now) {
                if movedPastSlop {
                    clickCount = 0
                    lastClickTime = -.infinity
                    inputMachines.pressClicks.clear()
                    selectionState.clearClicks()
                }
                if left {
                    inputMachines.pressedLeft = false
                    pointerExit(at: now)
                }
                return
            }
        }
        pointerUp(at: pos, button: .primary, mods: .none, at: now)
    }

    private func stopTextSelectionDrag(at now: Double) {
        selectionState.isDraggingSelection = false
        selectionState.edgeScroll.stop()
        selectionState.suppressedClickOnRelease = false
        // gap2/el (r365): a cancelled selection drag lets go where the selection stands
        // (`pointer.rs::drop_press` -> `select_step(Release)`), and its listeners hear it.
        selectionState.coordinator.phase.endDrag()
        dirtyCommit(at: now)
        dispatchSelectionChanges(at: now)
    }

    /// Cancels an active pointer drag without firing press, emitting `DragPhase.up` with `isCancelled = true`
    /// and `onDragEnd(..., cancelled: true)` (`pointer.rs:122`).
    @discardableResult
    internal func cancelActiveDrag(at point: Vec2? = nil, time now: Double) -> Bool {
        guard let drag = activeDrag else {
            guard selectionState.isDraggingSelection || selectionState.edgeScroll.isRunning else {
                return false
            }
            primaryPointerHeld = false
            pressedPath = nil
            pressedKey = nil
            pressedLink = nil
            pressedButton = .primary
            pressedPointerInside = false
            inputMachines.pressedLeft = false
            inputMachines.currentDoubleClickPair = nil
            stopTextSelectionDrag(at: now)
            return true
        }
        activeDrag = nil
        // gap/platform (#963): a cancelled drag releases the held pointer buttons it was tracking.
        primaryPointerHeld = false
        if drag.button == .secondary {
            secondaryPointerHeld = false
        }
        endKitPressRepeat()
        armedDragOut = nil
        pressedPath = nil
        pressedKey = nil
        pressedLink = nil
        pressedButton = .primary
        pressedPointerInside = false
        inputMachines.pressedLeft = false
        inputMachines.currentDoubleClickPair = nil

        if drag.isTextSelectionDrag {
            stopTextSelectionDrag(at: now)
            return true
        }

        let pt = point ?? ((pointerPosition.x > -9000 && pointerPosition.y > -9000) ? pointerPosition : drag.startWindow)
        if let idx = nodeByPath[drag.path] {
            let node = flatNodes[idx]
            let sx = abs(drag.startScale.x) > 1e-6 ? drag.startScale.x : 1.0
            let sy = abs(drag.startScale.y) > 1e-6 ? drag.startScale.y : 1.0
            let local = Vec2((pt.x - drag.startElementOrigin.x) / sx, (pt.y - drag.startElementOrigin.y) / sy)
            let delta = Vec2(pt.x - drag.startWindow.x, pt.y - drag.startWindow.y)
            if node.el.handlers.onDragEnd == nil, let onDrag = node.el.handlers.onDrag {
                let d = Drag(
                    window: pt,
                    local: local,
                    delta: delta,
                    startLocal: drag.startLocal,
                    size: drag.elementSize,
                    clicks: drag.clicks,
                    mods: .none,
                    phase: .up,
                    isCancelled: true,
                    screen: screenPixels(at: pt)
                )
                var tx = makeTx(at: now, button: drag.button)
                onDrag(&state, d, &tx)
                applyTx(tx, at: now)
            }
            if let onEnd = node.el.handlers.onDragEnd {
                var tx = makeTx(at: now, button: drag.button)
                onEnd(&state, true, &tx)
                applyTx(tx, at: now)
            }
        }
        dirtyCommit(at: now)
        return true
    }

    // MARK: - Secondary Gesture (`secondary.rs`)

    private func secondaryLinkIndex(node: FlatNode, at pos: Vec2) -> Int? {
        guard node.el.handlers.onLinkSecondary != nil, hasActiveTextLinks(node.el) else { return nil }
        return linkIndex(atPath: node.path, at: pos)
    }

    internal func secondaryTarget(at pos: Vec2) -> (path: String, linkIndex: Int?)? {
        guard let topHit = hitTest(at: pos, predicate: { _ in true }) else { return nil }
        var curIdx: Int? = topHit.node.index
        var selectableFallback: String? = nil
        while let i = curIdx, i < flatNodes.count {
            let n = flatNodes[i]
            if n.effectiveInert { break }
            if let linkIdx = secondaryLinkIndex(node: n, at: pos) {
                return (n.path, linkIdx)
            }
            if n.el.handlers.onSecondaryClick != nil {
                return (n.path, nil)
            }
            if n.el.handlers.editLens != nil {
                return (n.path, nil)
            }
            if selectableFallback == nil, isSelectableNode(n) {
                selectableFallback = n.path
            }
            curIdx = n.parentIndex
        }
        return selectableFallback.map { ($0, nil) }
    }

    private func isSelectableNode(_ node: FlatNode) -> Bool {
        guard node.el.isSelectable else { return false }
        return !(selectableNodeText(node)?.isEmpty ?? true)
    }

    private func onMisspelledWord(path: String) -> Bool {
        guard let idx = nodeByPath[path],
              let editLens = flatNodes[idx].el.handlers.editLens,
              pointerPosition.x > -9000,
              pointerPosition.y > -9000 else {
            return false
        }
        let node = flatNodes[idx]
        var edit = editLens.get(state)
        let spellEnabled = edit.spellcheckEnabled || node.el.spellcheck
        guard spellEnabled, !node.el.isSecure, !edit.isSecure else { return false }
        edit.spellcheckEnabled = true
        let offset = textHitOffset(node: node, windowPos: pointerPosition, edit: edit)
        return edit.misspelledUTF8Ranges().contains { range in
            offset >= range.lowerBound && offset <= range.upperBound
        }
    }

    /// Captures a secondary press at `pos` without firing primary handlers (`Runtime::secondary_down`).
    public func secondaryDown(at pos: Vec2, at now: Double = 0.0) {
        if slice2State.autoscroll.press(.secondary) { return }
        // A secondary press is input: a resting poll's change splits from it (#970).
        let inputMark = noteInput(at: now)
        defer { endInputDispatch(inputMark) }
        pointerPosition = pos
        releaseHoverHold()
        dismissHelp(at: now)
        if let target = secondaryTarget(at: pos) {
            inputMachines.secondaryCapture = .held(path: target.path, link: target.linkIndex, left: false)
        } else {
            inputMachines.secondaryCapture = .up
        }
    }

    /// Classifies the held secondary press target for browser hosts (`Runtime::secondary_claim`).
    public func secondaryClaim() -> String {
        guard case .held(let path, let link, _) = inputMachines.secondaryCapture,
              let idx = nodeByPath[path] else {
            return ""
        }
        let n = flatNodes[idx]
        if link != nil || n.el.handlers.onSecondaryClick != nil {
            return "app"
        }
        if n.el.handlers.editLens != nil {
            let onPill = n.el.handlers.onPillSecondary != nil
                && pointerPosition.x > -9000
                && pointerPosition.y > -9000
                && inputPillAt(idx, x: pointerPosition.x, y: pointerPosition.y) != nil
            return (onPill || onMisspelledWord(path: path)) ? "app" : "field"
        }
        return "text"
    }

    /// Abandons a captured secondary press so release opens nothing (`Runtime::secondary_abandon`).
    public func secondaryAbandon() {
        inputMachines.secondaryCapture = .up
    }

    /// Completes a captured secondary press at `pos` (`Runtime::secondary_up`).
    public func secondaryUp(at pos: Vec2, mods: Mods = .none, at now: Double = 0.0) {
        if slice2State.autoscroll.release(.secondary) { return }
        let inputMark = noteInput(at: now)
        // The release queued `Action::LinkSecondary`, `Action::SecondaryPress` or a field menu:
        // an input action whatever it changes (#970).
        var queuedPress = false
        defer { endInputDispatch(inputMark, queuedAction: queuedPress) }
        pointerPosition = pos
        let captured = inputMachines.secondaryCapture
        inputMachines.secondaryCapture = .up
        guard case .held(let path, let downLink, _) = captured else {
            leaveAfterRelease(at: now)
            return
        }
        defer { leaveAfterRelease(at: now) }
        guard let target = secondaryTarget(at: pos), target.path == path,
              let idx = nodeByPath[path] else {
            return
        }
        let node = flatNodes[idx]
        let upLink = target.linkIndex
        queuedPress = (upLink != nil && upLink == downLink) || (upLink == nil && downLink == nil)
        if let k = upLink, let d = downLink, k == d {
            if dispatchLinkDown(node: node, linkIdx: k, at: pos, button: .secondary, mods: mods, at: now) {
                _ = dispatchLinkUp(at: pos, button: .secondary, mods: mods, suppressed: false, at: now)
            }
            return
        }
        if upLink == nil && downLink == nil {
            if let onSec = node.el.handlers.onSecondaryClick {
                let rect = presentedRectByPath[path] ?? node.targetRect
                let unturned = hitGeometryByPath[path]?.turn?.unturn(pos) ?? pos
                let press = PointerPress(
                    window: pos,
                    local: Vec2(unturned.x - rect.x, unturned.y - rect.y),
                    elementSize: Vec2(rect.width, rect.height),
                    button: .secondary,
                    mods: mods,
                    clicks: 1
                )
                logInputEvent("secondary press \(path)")
                var tx = makeTx(at: now, button: .secondary)
                onSec(&state, press, &tx)
                applyTx(tx, at: now)
            } else if node.el.handlers.editLens != nil {
                let r = presentedRectByPath[path] ?? node.targetRect
                let unturned = hitGeometryByPath[path]?.turn?.unturn(pos) ?? pos
                let localText = Vec2(unturned.x - r.x, unturned.y - r.y)
                _ = openFieldMenu(path: path, at: pos, localTextPos: localText, at: now)
            } else if isSelectableNode(node) {
                handleSelectableSecondaryClick(at: pos, at: now)
            }
        }
    }

    /// Dispatches `ContextMenu` / `Shift+F10` on the focused link, field, or nearest `onSecondaryClick` ancestor
    /// (`secondary.rs:122`, `tests/context_menu_key.rs`).
    @discardableResult
    internal func contextMenuKey(_ ev: KeyEvent, at now: Double) -> Bool {
        let m = ev.mods
        let plain = !m.cmd && !m.ctrl && !m.alt && !m.logo
        let isMenuKey: Bool
        switch ev.key {
        case .contextMenu:
            isMenuKey = plain && !m.shift
        case .f(10):
            isMenuKey = plain && m.shift
        default:
            isMenuKey = false
        }
        guard isMenuKey,
              let fPath = focusedPath,
              let fIdx = nodeByPath[fPath],
              !flatNodes[fIdx].effectiveInert else {
            return false
        }
        let fNode = flatNodes[fIdx]

        // 1. Focused link menu at bottom-left of its first box
        if hasActiveTextLinks(fNode.el),
           let k = focusedLinkIndex,
           k >= 0, k < fNode.el.textLinks.count,
           let onSec = fNode.el.handlers.onLinkSecondary,
           let box = linkBoxesByPath[fNode.path]?.first(where: { $0.linkIndex == k }) {
            let r = box.windowRects.first ?? box.windowUnion
            let pt = Vec2(r.x, r.y + r.w)
            let nodeRect = presentedRectByPath[fNode.path] ?? fNode.targetRect
            let press = PointerPress(
                window: pt,
                local: Vec2(pt.x - nodeRect.x, pt.y - nodeRect.y),
                elementSize: Vec2(nodeRect.width, nodeRect.height),
                button: .secondary,
                mods: ev.mods,
                clicks: 1
            )
            logInputEvent("link secondary \(fNode.path) \(box.link.id)")
            var tx = makeTx(at: now, button: .secondary)
            onSec(&state, box.link.id, press, &tx)
            applyTx(tx, at: now)
            return true
        }

        // 2. Focused text field opens its own context menu when it has no custom onSecondaryClick
        let fRect = presentedRectByPath[fNode.path] ?? fNode.targetRect
        let anchorPt = Vec2(fRect.x, fRect.y + fRect.height)
        if fNode.el.handlers.editLens != nil && fNode.el.handlers.onSecondaryClick == nil {
            return openFieldMenu(path: fNode.path, at: anchorPt, localTextPos: nil, at: now)
        }

        // 3. Walk focused node and non-inert ancestors for onSecondaryClick
        var curIdx: Int? = fIdx
        while let idx = curIdx, idx < flatNodes.count {
            let n = flatNodes[idx]
            if n.effectiveInert { return false }
            if let onSec = n.el.handlers.onSecondaryClick {
                let r = presentedRectByPath[n.path] ?? n.targetRect
                let press = PointerPress(
                    window: anchorPt,
                    local: Vec2(anchorPt.x - r.x, anchorPt.y - r.y),
                    elementSize: Vec2(r.width, r.height),
                    button: .secondary,
                    mods: ev.mods,
                    clicks: 1
                )
                logInputEvent("secondary press \(n.path)")
                var tx = makeTx(at: now, button: .secondary)
                onSec(&state, press, &tx)
                applyTx(tx, at: now)
                return true
            }
            curIdx = n.parentIndex
        }
        return false
    }
}
