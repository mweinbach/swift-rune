import Foundation

// MARK: - Overlay pointer observation (`runtime/input/pointer.rs` `Runtime::observe_pointer`)

extension Runtime {
    /// Whether node `i` (drawn geometry, else its resting layout rect) holds window point `p`
    /// (`hit.rs` `Runtime::node_contains`). The off-window sentinel holds nothing.
    private func observedNodeContains(_ i: Int, _ p: Vec2) -> Bool {
        guard p.x > -9000, p.y > -9000, flatNodes.indices.contains(i) else { return false }
        let n = flatNodes[i]
        if let geom = hitGeometryByPath[n.path] {
            return geom.contains(p)
        }
        return halfOpenContains(presentedRectByPath[n.path] ?? n.targetRect, p)
    }

    /// Node `i` draws a hover fill or tracks the press (`vis.hover().a > 0 || vis.tracks_press()
    /// || press_scale.is_some()`), so the pointer crossing its edge changes pixels.
    private func observedNodeShowsPointer(_ i: Int) -> Bool {
        let el = flatNodes[i].el
        if let hover = el.hoverBg, hover.a > 0 { return true }
        // `tracks_press`: a visible press fill or a press text colour.
        if let press = el.pressBg, press.a > 0 { return true }
        return el.pressColor != nil || el.pressScaleFactor != nil
    }

    /// Element `node` drags out through the OS (`drag_out_host.rs` `Runtime::drags_out`).
    private func observedDragsOut(_ node: FlatNode) -> Bool {
        inputMachines.osDragSupported && (node.el.handlers.dragOut != nil || node.el.attachedDragOutItem != nil)
    }

    /// Element `node`'s `onDrag` hears a press of `button` (`gesture.rs` `Runtime::drags_with`):
    /// it has `onDrag`, doesn't drag out, and takes the button (`takes_button`).
    private func observedDragsWith(_ node: FlatNode, _ button: PointerButton) -> Bool {
        node.el.handlers.onDrag != nil && !observedDragsOut(node)
            && (button == .primary || node.el.handlers.pointerButtons?.contains(button) == true)
    }

    /// The held press's move queues an action (`pointer.rs` `move_pointer` after the press check):
    /// a text field drag-selection queues `Action::Focus` on every move (`input_drag`), and a press
    /// on an element that drags with its button queues `Action::Drag`.
    private func observedHeldPressQueuesMove() -> Bool {
        guard let drag = activeDrag, let idx = nodeByPath[drag.path], flatNodes.indices.contains(idx) else { return false }
        let node = flatNodes[idx]
        if drag.isTextSelectionDrag {
            // `input_drag`: the field is still live and still a field.
            return node.el.handlers.editLens != nil
        }
        return observedDragsWith(node, drag.button)
    }

    /// Overlay observation: moves the pointer to `pos` like `pointerMove` and returns whether the
    /// move needs a frame (`Runtime::observe_pointer`). A duplicate observation, or a move that
    /// leaves hover pixels, help, queued handlers and the press capture unchanged, returns `false`
    /// so idle monitor/winit pointer events don't present unchanged frames.
    ///
    /// Rune answers "did `pointer_move` queue anything" (`queue.len() != queued`). It queues an
    /// action for a pointer-move handler, a newly hovered element, a hover focus change, an
    /// `onHoverChange` enter/leave, a held drag's or text field drag-selection's move, and a drag-out
    /// the move starts; the Swift runtime runs those handlers synchronously, so the same events are
    /// detected around the move.
    @discardableResult
    public func observePointer(at pos: Vec2, mods: Mods = .none, at now: Double) -> Bool {
        let was = pointerPosition
        if was == pos { return false }
        let visualChanged = flatNodes.indices.contains { i in
            observedNodeShowsPointer(i) && observedNodeContains(i, was) != observedNodeContains(i, pos)
        }
        // Reaching or leaving a help element starts or ends its tooltip's wait.
        let helpChanged = helpTargetChanges(at: pos)
        // `Action::PointerMove` for every hit move handler.
        let moveQueued = !hitTestAll(at: pos, predicate: { $0.el.handlers.onPointerMove != nil }).isEmpty
        // `Action::Focus` (field drag-selection) or `Action::Drag` (`has_drag && drag_move`).
        let heldQueued = observedHeldPressQueuesMove()
        let hoveredBefore = hoveredPath
        let withinBefore = hoverWithinPaths
        let focusBefore = (focusedPath, hoveredHighlightActive)
        let captureInside = pressedPath != nil && pressedPointerInside
        let dragOutsBefore = inputMachines.nextDragOutId

        pointerMove(to: pos, mods: mods, at: now)

        // `Action::DragStart`: the move carried an armed drag-out past its threshold (`start_drag_out`).
        let dragOutQueued = inputMachines.nextDragOutId != dragOutsBefore
        // `Action::Hover` when what's hovered changes to an element.
        let hoverQueued = hoveredPath != hoveredBefore && hoveredPath != nil
        // `Action::HoverChange` for elements entered or left.
        let withinQueued = Set(withinBefore) != Set(hoverWithinPaths)
        // `Action::HoverFocus` when a highlight row takes or gives up hover focus.
        let focusQueued = focusBefore.0 != focusedPath || focusBefore.1 != hoveredHighlightActive
        let queued = moveQueued || heldQueued || dragOutQueued || hoverQueued || withinQueued || focusQueued
        let captureChanged = (pressedPath != nil && pressedPointerInside) != captureInside
        return visualChanged || helpChanged || queued || captureChanged
    }

    /// An overlay host saw the pointer at window point `pos` (`overlay/input.rs`
    /// `Overlay::observe_pointer`). Inside the canvas, or while a button holds the pointer, it is
    /// observed (`observePointer`); outside, a pointer the runtime still has leaves. Returns whether
    /// the overlay needs a frame (its `dirty` flag). The host starts a drag-out the move asked for
    /// after the frame it then draws (`takeDragOutStart`).
    @discardableResult
    public func overlayObservePointer(at pos: Vec2, mods: Mods = .none, at now: Double) -> Bool {
        if pointerCaptured || (pos.x >= 0 && pos.y >= 0 && pos.x < viewport.x && pos.y < viewport.y) {
            return observePointer(at: pos, mods: mods, at: now)
        }
        if pointerPosition.x > -9000, pointerPosition.y > -9000 {
            pointerLeave(at: now)
            return true
        }
        return false
    }
}

// MARK: - Shift+click on a text field (`selection/click.rs` `Runtime::input_down`)

extension Runtime {
    /// A press on text field `node` with Shift held (`mods`, or the modifiers last reported through
    /// `physicalInput`) extends the selection from its anchor: it ends any run of presses and
    /// counts as a single click, so Shift+click right after a click never selects a word
    /// (`input_click.presses.clear(); 1`). `nil` when the press counts clicks as usual.
    internal func shiftClickCount(node: FlatNode, mods: Mods) -> UInt32? {
        guard node.el.handlers.editLens != nil, mods.shift || inputMachines.currentMods.shift else { return nil }
        inputMachines.pressClicks.clear()
        return 1
    }
}
