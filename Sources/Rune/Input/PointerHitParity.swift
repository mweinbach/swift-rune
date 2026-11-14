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
        return nodeHasPressVisuals(flatNodes[i])
    }

    /// Overlay observation: moves the pointer to `pos` like `pointerMove` and returns whether the
    /// move needs a frame (`Runtime::observe_pointer`). A duplicate observation, or a move that
    /// leaves hover pixels, help, queued handlers and the press capture unchanged, returns `false`
    /// so idle monitor/winit pointer events don't present unchanged frames.
    ///
    /// Rune queues an action for a pointer-move handler, a newly hovered element, a hover focus
    /// change, an `onHoverChange` enter/leave and a held drag's move; the Swift runtime runs those
    /// handlers synchronously, so the same events are detected around the move.
    @discardableResult
    public func observePointer(at pos: Vec2, at now: Double = 0.0) -> Bool {
        let was = pointerPosition
        if was == pos { return false }
        let visualChanged = flatNodes.indices.contains { i in
            observedNodeShowsPointer(i) && observedNodeContains(i, was) != observedNodeContains(i, pos)
        }
        // Reaching or leaving a help element starts or ends its tooltip's wait.
        let helpChanged = helpTargetChanges(at: pos)
        // `Action::PointerMove` for every hit move handler.
        let moveQueued = !hitTestAll(at: pos, predicate: { $0.el.handlers.onPointerMove != nil }).isEmpty
        // `Action::Drag` for a held press that drags (`has_drag && drag_move`).
        let dragQueued = activeDrag.map { drag in
            !drag.isTextSelectionDrag && (nodeByPath[drag.path].map { flatNodes[$0].el.handlers.onDrag != nil } ?? false)
        } ?? false
        let hoveredBefore = hoveredPath
        let withinBefore = hoverWithinPaths
        let focusBefore = (focusedPath, hoveredHighlightActive)
        let captureInside = pressedPath != nil && pressedPointerInside

        pointerMove(to: pos, at: now)

        // `Action::Hover` when what's hovered changes to an element.
        let hoverQueued = hoveredPath != hoveredBefore && hoveredPath != nil
        // `Action::HoverChange` for elements entered or left.
        let withinQueued = Set(withinBefore) != Set(hoverWithinPaths)
        // `Action::HoverFocus` when a highlight row takes or gives up hover focus.
        let focusQueued = focusBefore.0 != focusedPath || focusBefore.1 != hoveredHighlightActive
        let queued = moveQueued || dragQueued || hoverQueued || withinQueued || focusQueued
        let captureChanged = (pressedPath != nil && pressedPointerInside) != captureInside
        return visualChanged || helpChanged || queued || captureChanged
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
