import Foundation
import RuneMotion

/// Host window action emitted when a primary press lands on a bare `.windowDrag()` region (`rune::TitlebarAction`).
public enum TitlebarAction: Equatable, Sendable {
    case drag
    case doubleClick
}

internal struct KitHoverDelayEntry {
    enum Phase {
        case enterDue(Double)
        case shown
        case leaveDue(Double)
    }

    var phase: Phase
}

internal struct KitDragRepeatEntry {
    var path: String
    var windowPos: Vec2
    var mods: Mods
    var button: PointerButton
    var due: Double
}

internal struct KitRuntimeHooksState {
    var pendingTitlebarAction: TitlebarAction? = nil
    var lastBareTitlebarPress: (at: Double, point: Vec2)? = nil
    var hoverDelays: [String: KitHoverDelayEntry] = [:]
    var hoverHoldAfterActionUntilMove: Bool = false
    var windowFocused: Bool = true
    var isDispatchingByKeys: Bool = false
    var isDispatchingFocusLost: Bool = false
    var dragRepeat: KitDragRepeatEntry? = nil
    var requestedDragRepeatDelay: Double? = nil
    var pendingTxFocusVisible: Bool? = nil
}

extension Tx {
    /// Moves keyboard focus to `.key(targetKey)` with an explicit focus-ring visibility flag (`Tx::focus(key, ring)`).
    public mutating func focus(_ targetKey: String, focusVisible: Bool) {
        requestedFocusKey = targetKey
        requestedFocusVisible = focusVisible
        focusAskedByReturn = false
        blurFocusRequested = false
    }

    /// Whether keyboard focus was showing its focus ring when this event arrived (`Tx::focus_visible()`).
    public var isFocusVisible: Bool {
        (runtimeActions["focusVisible"] as? Bool) ?? true
    }

    /// Whether this event originated from keyboard input (`Tx::by_keys()`).
    public var byKeys: Bool {
        (runtimeActions["byKeys"] as? Bool) ?? false
    }

    /// Schedules a repeat delivery to the active drag handler after `delay` seconds (`Tx::drag_repeat_after`).
    public mutating func dragRepeatAfter(_ delay: Double) {
        let clamped = max(0.0, delay)
        runtimeActions["dragRepeatAfter"] = clamped
    }

    /// True when the current drag callback was invoked by a scheduled hold repeat (`Tx::drag_repeat`).
    public var isDragRepeat: Bool {
        (runtimeActions["dragRepeat"] as? Bool) ?? false
    }
}

fileprivate let kitHoverDelaysKey = "kitHoverDelays"
fileprivate let kitWindowFocusHandlersKey = "kitWindowFocusHandlers"

extension El {
    /// Delays enter/leave hover reporting for `onHover` (`El::hover_delays`).
    public func hoverDelays(_ enter: Double, _ leave: Double) -> Self {
        var copy = self
        copy.runtimeExtras[kitHoverDelaysKey] = (max(0.0, enter), max(0.0, leave))
        return copy
    }

    /// Invoked when the window gains (`true`) or loses (`false`) OS focus (`El::on_window_focus`).
    public func onWindowFocus(_ handler: @escaping (inout State, Bool, inout Tx) -> Void) -> Self {
        var copy = self
        var existing = (copy.runtimeExtras[kitWindowFocusHandlersKey] as? [(inout Any, Bool, inout Tx) -> Void]) ?? []
        let wrapped: (inout Any, Bool, inout Tx) -> Void = { stateAny, focused, tx in
            guard var typed = stateAny as? State else { return }
            handler(&typed, focused, &tx)
            stateAny = typed
        }
        existing.append(wrapped)
        copy.runtimeExtras[kitWindowFocusHandlersKey] = existing
        return copy
    }

    internal var kitHoverDelaysSpec: (enter: Double, leave: Double)? {
        runtimeExtras[kitHoverDelaysKey] as? (Double, Double)
    }

    internal var hasKitHoverDelays: Bool {
        kitHoverDelaysSpec != nil
    }

    internal var kitWindowFocusHandlers: [(inout Any, Bool, inout Tx) -> Void] {
        (runtimeExtras[kitWindowFocusHandlersKey] as? [(inout Any, Bool, inout Tx) -> Void]) ?? []
    }
}

fileprivate let kitTitlebarDoubleClickInterval: Double = 0.5
fileprivate let kitTitlebarDoubleClickSlop: Float = 4.0

extension Runtime {

    /// Returns and clears any pending OS titlebar drag/zoom action requested by the last press (`Runtime::take_titlebar_action`).
    public func takeTitlebarAction() -> TitlebarAction? {
        defer { kitHooks.pendingTitlebarAction = nil }
        return kitHooks.pendingTitlebarAction
    }

    /// Notifies the runtime of OS window activation/blur (`Runtime::window_focus`).
    public func windowFocus(_ focused: Bool, at now: Double? = nil) {
        let t = now ?? currentTime
        kitHooks.windowFocused = focused
        if !focused {
            finishComposition(at: t)
            kitHooks.dragRepeat = nil
            kitHooks.hoverHoldAfterActionUntilMove = true
            endKitHoverDelays(at: t)
        }
        var ranHandler = false
        var allLiveOnly = true
        for node in flatNodes {
            let handlers = node.el.kitWindowFocusHandlers
            guard !handlers.isEmpty else { continue }
            for handler in handlers {
                var tx = makeTx(at: t)
                var boxedState: Any = state
                handler(&boxedState, focused, &tx)
                if let typed = boxedState as? State {
                    state = typed
                }
                ranHandler = true
                allLiveOnly = allLiveOnly && tx.liveOnlyRequested
                applyTx(tx, at: t, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
            }
        }
        if !focused && (!ranHandler || !allLiveOnly) {
            dirtyCommit(at: t)
        }
    }

    internal func recordBareTitlebarPressIfNeeded(at pos: Vec2, button: PointerButton, now: Double) {
        guard button == .primary, isBareTitlebarDragRegion(at: pos) else {
            kitHooks.lastBareTitlebarPress = nil
            return
        }
        if let prev = kitHooks.lastBareTitlebarPress,
           (now - prev.at) <= kitTitlebarDoubleClickInterval,
           hypot(pos.x - prev.point.x, pos.y - prev.point.y) <= kitTitlebarDoubleClickSlop {
            kitHooks.pendingTitlebarAction = .doubleClick
            kitHooks.lastBareTitlebarPress = nil
        } else {
            kitHooks.pendingTitlebarAction = .drag
            kitHooks.lastBareTitlebarPress = (at: now, point: pos)
        }
    }

    internal func cancelKitHoverAndRepeatOnPress() {
        kitHooks.hoverHoldAfterActionUntilMove = true
        let paths = Array(kitHooks.hoverDelays.keys)
        for path in paths {
            if let entry = kitHooks.hoverDelays[path], case .enterDue = entry.phase {
                kitHooks.hoverDelays.removeValue(forKey: path)
            }
        }
    }

    internal func resetKitHoverHoldOnPointerMove() {
        kitHooks.hoverHoldAfterActionUntilMove = false
    }

    internal func hoverVisualNeedsCommit(oldPath: String?, newPath: String?) -> Bool {
        func nodeHasHoverVisual(_ path: String?) -> Bool {
            guard let path, let idx = nodeByPath[path] else { return false }
            let el = flatNodes[idx].el
            return el.hoverBg != nil
                || el.hoverMotionSpec != nil
                || el.hoverWithinSpec != nil
                || el.isHoverGroup
                || el.isHoverAlone
                || el.hoverGroupShare != nil
                || el.groupOpacity != nil
                || el.groupColor != nil
                || el.a11yHelp != nil
                || el.attachedCursor != nil
        }
        return nodeHasHoverVisual(oldPath) || nodeHasHoverVisual(newPath)
    }

    internal func nodeHasPressVisuals(_ node: FlatNode) -> Bool {
        node.el.pressBg != nil || node.el.pressScaleFactor != nil
    }

    private func isPointerInsideHoverDelayNode(_ node: FlatNode, at pos: Vec2) -> Bool {
        guard !node.effectiveInert, !node.el.a11yDisabled else { return false }
        if activeModalPath != nil && !modalMemberPaths.contains(node.path) {
            return false
        }
        if let geom = hitGeometryByPath[node.path] {
            return geom.contains(pos)
        }
        let rect = presentedRectByPath[node.path] ?? node.targetRect
        return rect.width > 0 && rect.height > 0
            && pos.x >= rect.x && pos.x < rect.x + rect.width
            && pos.y >= rect.y && pos.y < rect.y + rect.height
    }

    internal func settleKitHoverDelays(at pos: Vec2, now: Double) {
        let mayEnter = activeDrag == nil && !kitHooks.hoverHoldAfterActionUntilMove && kitHooks.windowFocused
        var activeDelayPaths: Set<String> = []
        for node in flatNodes {
            guard let spec = node.el.kitHoverDelaysSpec, node.el.handlers.onHover != nil else { continue }
            activeDelayPaths.insert(node.path)
            let inside = isPointerInsideHoverDelayNode(node, at: pos)
            let current = kitHooks.hoverDelays[node.path]
            let shown: Bool = {
                guard let phase = current?.phase else { return false }
                switch phase {
                case .shown, .leaveDue: return true
                case .enterDue: return false
                }
            }()
            let want = inside && (shown || mayEnter)
            if want == shown {
                if shown {
                    kitHooks.hoverDelays[node.path] = KitHoverDelayEntry(phase: .shown)
                } else {
                    kitHooks.hoverDelays.removeValue(forKey: node.path)
                }
                continue
            }
            if let phase = current?.phase {
                switch phase {
                case .enterDue where want, .leaveDue where !want:
                    continue
                default:
                    break
                }
            }
            let delay = want ? spec.enter : spec.leave
            if delay <= 0 {
                if want {
                    kitHooks.hoverDelays[node.path] = KitHoverDelayEntry(phase: .shown)
                } else {
                    kitHooks.hoverDelays.removeValue(forKey: node.path)
                }
                dispatchKitHoverCallback(node: node, inside: want, at: now)
            } else {
                let due = now + delay
                kitHooks.hoverDelays[node.path] = KitHoverDelayEntry(
                    phase: want ? .enterDue(due) : .leaveDue(due)
                )
            }
        }
        // Any delayed node removed from the tree ends immediately.
        let trackedPaths = Array(kitHooks.hoverDelays.keys)
        for path in trackedPaths where !activeDelayPaths.contains(path) {
            kitHooks.hoverDelays.removeValue(forKey: path)
        }
    }

    internal func stepKitHoverDelaysOnFrame(at now: Double) {
        let trackedPaths = Array(kitHooks.hoverDelays.keys).sorted()
        for path in trackedPaths {
            guard let entry = kitHooks.hoverDelays[path] else { continue }
            switch entry.phase {
            case .enterDue(let due) where due <= now + 1e-9:
                kitHooks.hoverDelays[path] = KitHoverDelayEntry(phase: .shown)
                if let idx = nodeByPath[path] {
                    dispatchKitHoverCallback(node: flatNodes[idx], inside: true, at: now)
                }
            case .leaveDue(let due) where due <= now + 1e-9:
                kitHooks.hoverDelays.removeValue(forKey: path)
                if let idx = nodeByPath[path] {
                    dispatchKitHoverCallback(node: flatNodes[idx], inside: false, at: now)
                }
            default:
                break
            }
        }
    }

    internal func endKitHoverDelays(at now: Double) {
        let trackedPaths = Array(kitHooks.hoverDelays.keys).sorted()
        for path in trackedPaths {
            guard let entry = kitHooks.hoverDelays.removeValue(forKey: path) else { continue }
            let wasShown: Bool = switch entry.phase {
            case .shown, .leaveDue: true
            case .enterDue: false
            }
            if wasShown, let idx = nodeByPath[path] {
                dispatchKitHoverCallback(node: flatNodes[idx], inside: false, at: now)
            }
        }
    }

    private func dispatchKitHoverCallback(node: FlatNode, inside: Bool, at now: Double) {
        guard let onHover = node.el.handlers.onHover else { return }
        var tx = makeTx(at: now)
        onHover(&state, inside, &tx)
        applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
    }

    internal func armKitDragRepeatIfRequested(path: String, windowPos: Vec2, mods: Mods, button: PointerButton, now: Double) {
        guard let delay = kitHooks.requestedDragRepeatDelay else {
            return
        }
        kitHooks.requestedDragRepeatDelay = nil
        kitHooks.dragRepeat = KitDragRepeatEntry(
            path: path,
            windowPos: windowPos,
            mods: mods,
            button: button,
            due: now + delay
        )
    }

    internal func stepKitDragRepeatOnFrame(at now: Double) {
        guard let rep = kitHooks.dragRepeat, activeDrag != nil else {
            if activeDrag == nil { kitHooks.dragRepeat = nil }
            return
        }
        guard rep.due <= now + 1e-9 else { return }
        kitHooks.dragRepeat = nil
        guard let drag = activeDrag,
              drag.path == rep.path,
              let idx = nodeByPath[drag.path],
              let onDrag = flatNodes[idx].el.handlers.onDrag else {
            return
        }
        let sx = abs(drag.startScale.x) > 1e-6 ? drag.startScale.x : 1.0
        let sy = abs(drag.startScale.y) > 1e-6 ? drag.startScale.y : 1.0
        let d = Drag(
            window: rep.windowPos,
            local: Vec2((rep.windowPos.x - drag.startElementOrigin.x) / sx, (rep.windowPos.y - drag.startElementOrigin.y) / sy),
            delta: Vec2(rep.windowPos.x - drag.startWindow.x, rep.windowPos.y - drag.startWindow.y),
            startLocal: drag.startLocal,
            size: drag.elementSize,
            clicks: drag.clicks,
            mods: rep.mods
        )
        var tx = makeTx(at: now, button: drag.button)
        tx.runtimeActions["dragRepeat"] = true
        onDrag(&state, d, &tx)
        if !tx.askedMotion { tx.instant() }
        applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
        armKitDragRepeatIfRequested(path: drag.path, windowPos: rep.windowPos, mods: rep.mods, button: drag.button, now: now)
    }

    internal func kitNextWakeDeadline(after now: Double) -> Double? {
        var best: Double? = nil
        for entry in kitHooks.hoverDelays.values {
            let due: Double? = switch entry.phase {
            case .enterDue(let d), .leaveDue(let d): d
            case .shown: nil
            }
            if let due, due > now {
                best = best.map { min($0, due) } ?? due
            }
        }
        if let repDue = kitHooks.dragRepeat?.due, repDue > now {
            best = best.map { min($0, repDue) } ?? repDue
        }
        return best
    }

    /// Commits open composition and delivers `.focusLost` when focus leaves `prevNode`.
    internal func handleKitFocusTransition(prevNode: FlatNode?, newPath: String?, at now: Double) {
        guard let prevNode, prevNode.path != newPath else { return }
        if !kitHooks.isDispatchingFocusLost {
            kitHooks.isDispatchingFocusLost = true
            defer { kitHooks.isDispatchingFocusLost = false }

            if let editLens = prevNode.el.handlers.editLens {
                var edit = editLens.get(state)
                if edit.preedit != nil, edit.finishPreedit() {
                    editLens.set(&state, edit)
                    if let onChange = prevNode.el.handlers.onTextChange {
                        var tx = makeTx(at: now)
                        onChange(&state, edit.text, &tx)
                        applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
                    }
                    dirtyCommit(at: now)
                }
            }
            if let onPhys = prevNode.el.handlers.onPhysicalInput {
                var tx = makeTx(at: now)
                let handled = onPhys(&state, .focusLost, &tx)
                Tx.took(handled, &tx)
                if handled || !tx.liveOnlyRequested {
                    applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
                }
            }
        }
    }
}
