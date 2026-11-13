import Foundation
import RuneMotion

/// Host window action emitted when a primary press lands on a bare `.windowDrag()` region (`rune::TitlebarAction`).
public enum TitlebarAction: Equatable, Sendable {
    case drag
    case doubleClick
}

internal struct RuntimeGrowthClosingRow: Sendable {
    var segment: String
    var nodeId: NodeId
    var track: GrowTrack
    var spring: Spring
    var edge: StreamEdge
    var originalLocalRect: MotionRect
}

internal struct KitGrowthStackState: Sendable {
    var order: [String] = []
    var closing: [String: RuntimeGrowthClosingRow] = [:]
    var spacerPaths: [NodeId: String] = [:]
    var isNewStack: Bool = true
}

internal struct KitRuntimeHooksState {
    var titlebar = TitlebarMachine()
    var doubleClickInterval: Double = 0.5
    var hoverDelays = KitHoverDelayList()
    var hoverDelayCallbacks: [String: (inout Any, Bool, inout Tx) -> Void] = [:]
    var hoverHoldAfterActionUntilMove: Bool = false
    var windowFocused: Bool = true
    var windowFocusReportedState: Bool? = nil
    var pendingWindowFocusTransitions: [(focused: Bool, at: Double)] = []
    var frameGrowthStepDt: Double = 0
    var typeSelectBuffer: String = ""
    var typeSelectLastTime: Double = -10.0
    var isDispatchingByKeys: Bool = false
    var isDispatchingFocusLost: Bool = false
    var pressRepeat = PressRepeatMachine()
    var pressRepeatPayload: PressRepeatPayload? = nil
    var requestedDragRepeatDelay: Double? = nil
    var pendingTxFocusVisible: Bool? = nil
    var isKeyRepeat: Bool = false
    var unseenPresence = KitUnseenPresenceState()
    var growthStacks: [String: KitGrowthStackState] = [:]
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

    /// Animates opacity transitions for this element using an explicit `Anim<Float>` curve (delay + velocity rule).
    public func animateOpacity(_ anim: Anim<Float>) -> Self {
        var copy = self
        copy.runtimeExtras["rune.kit.opacityAnim"] = anim
        return copy
    }

    internal var kitOpacityAnim: Anim<Float>? {
        runtimeExtras["rune.kit.opacityAnim"] as? Anim<Float>
    }
}

extension Runtime {

    /// Returns and clears any pending OS titlebar drag/zoom action requested by the last press (`Runtime::take_titlebar_action`).
    public func takeTitlebarAction() -> TitlebarAction? {
        defer { kitHooks.titlebar.action = nil }
        return kitHooks.titlebar.action
    }

    /// Notifies the runtime of OS window activation/blur (`Runtime::window_focus`).
    public func windowFocus(_ focused: Bool, at now: Double? = nil) {
        let t = now ?? currentTime
        let transitionChanged = kitHooks.windowFocusReportedState != focused
        kitHooks.windowFocusReportedState = focused
        if windowFocused != focused {
            dispatchFocus(focused, at: t)
            return
        }
        guard transitionChanged else { return }
        if flatNodes.isEmpty {
            kitHooks.pendingWindowFocusTransitions.append((focused, t))
        } else {
            _ = dispatchKitWindowFocusHandlers(focused, at: t)
        }
    }

    internal func flushPendingKitWindowFocus(at now: Double) {
        guard !kitHooks.pendingWindowFocusTransitions.isEmpty else { return }
        let queued = kitHooks.pendingWindowFocusTransitions
        kitHooks.pendingWindowFocusTransitions.removeAll()
        for entry in queued {
            _ = dispatchKitWindowFocusHandlers(entry.focused, at: entry.at)
        }
    }

    internal func dispatchKitWindowFocusHandlers(_ focused: Bool, at now: Double) -> (ran: Bool, allLiveOnly: Bool) {
        if flatNodes.isEmpty {
            kitHooks.pendingWindowFocusTransitions.append((focused, now))
            return (false, true)
        }
        var ranHandler = false
        var allLiveOnly = true
        for node in flatNodes where !node.effectiveInert {
            let handlers = node.el.kitWindowFocusHandlers
            guard !handlers.isEmpty else { continue }
            for handler in handlers {
                var tx = makeTx(at: now)
                var boxedState: Any = state
                handler(&boxedState, focused, &tx)
                if let typed = boxedState as? State {
                    state = typed
                }
                ranHandler = true
                allLiveOnly = allLiveOnly && tx.liveOnlyRequested
                applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
            }
        }
        return (ranHandler, allLiveOnly)
    }

    internal func cancelKitHoverAndRepeatOnPress() {
        kitHooks.hoverHoldAfterActionUntilMove = true
        for path in kitHooks.hoverDelays.paths {
            _ = kitHooks.hoverDelays.step(path, .pressed)
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

    @discardableResult
    private func stepKitHoverDelay(path: String, event: KitHoverDelayEvent, at now: Double) -> Bool {
        var didMarkDirty = false
        let effects = kitHooks.hoverDelays.step(path, event)
        for effect in effects {
            if case .report(let inside) = effect {
                if let idx = nodeByPath[path], let onHover = flatNodes[idx].el.handlers.onHover {
                    var tx = makeTx(at: now)
                    onHover(&state, inside, &tx)
                    if !tx.liveOnlyRequested { didMarkDirty = true }
                    applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
                } else if let boxedCb = kitHooks.hoverDelayCallbacks[path] {
                    var tx = makeTx(at: now)
                    var boxed: Any = state
                    boxedCb(&boxed, inside, &tx)
                    if let typed = boxed as? State { state = typed }
                    if !tx.liveOnlyRequested { didMarkDirty = true }
                    applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
                }
            }
        }
        if !kitHooks.hoverDelays.paths.contains(path) {
            kitHooks.hoverDelayCallbacks.removeValue(forKey: path)
        }
        return didMarkDirty
    }

    internal func settleKitHoverDelays(at pos: Vec2, now: Double) {
        let mayEnter = pressedPath == nil && activeDrag == nil && !kitHooks.hoverHoldAfterActionUntilMove
        var activeSpecByPath: [String: (enter: Double, leave: Double)] = [:]
        for node in flatNodes {
            guard let spec = node.el.kitHoverDelaysSpec, let onHover = node.el.handlers.onHover else { continue }
            activeSpecByPath[node.path] = spec
            kitHooks.hoverDelayCallbacks[node.path] = { boxed, inside, tx in
                guard var typed = boxed as? State else { return }
                onHover(&typed, inside, &tx)
                boxed = typed
            }
        }
        var paths = Set(kitHooks.hoverDelays.paths)
        paths.formUnion(activeSpecByPath.keys)
        for path in paths.sorted() {
            let event: KitHoverDelayEvent
            if let spec = activeSpecByPath[path], let idx = nodeByPath[path] {
                let inside = isPointerInsideHoverDelayNode(flatNodes[idx], at: pos)
                event = .settle(
                    inside: inside,
                    mayEnter: mayEnter,
                    enterDelay: spec.enter,
                    leaveDelay: spec.leave,
                    now: now
                )
            } else {
                event = .ended
            }
            _ = stepKitHoverDelay(path: path, event: event, at: now)
        }
    }

    internal func stepKitHoverDelaysOnFrame(at now: Double) {
        guard kitHooks.hoverDelays.waiting else { return }
        let clockNow = now + 1e-6
        for path in kitHooks.hoverDelays.paths {
            _ = stepKitHoverDelay(path: path, event: .due(now: clockNow), at: now)
        }
    }

    @discardableResult
    internal func endKitHoverDelays(at now: Double) -> Bool {
        var didMarkDirty = false
        for path in kitHooks.hoverDelays.paths {
            if stepKitHoverDelay(path: path, event: .ended, at: now) {
                didMarkDirty = true
            }
        }
        return didMarkDirty
    }

    internal func armKitDragRepeatIfRequested(path: String, windowPos: Vec2, mods: Mods, button: PointerButton, now: Double) {
        guard let delay = kitHooks.requestedDragRepeatDelay else {
            return
        }
        kitHooks.requestedDragRepeatDelay = nil
        guard pressedPath == path || activeDrag?.path == path else { return }
        kitHooks.pressRepeatPayload = PressRepeatPayload(
            path: path,
            windowPos: windowPos,
            mods: mods,
            button: button
        )
        _ = kitHooks.pressRepeat.step(.arm(path: path, due: now + delay))
    }

    internal func endKitPressRepeat() {
        _ = kitHooks.pressRepeat.step(.end)
        kitHooks.pressRepeatPayload = nil
        kitHooks.requestedDragRepeatDelay = nil
    }

    internal func stepKitDragRepeatOnFrame(at now: Double) {
        guard let attempt = kitHooks.pressRepeat.attempt, activeDrag != nil else {
            if activeDrag == nil { endKitPressRepeat() }
            return
        }
        let effects = kitHooks.pressRepeat.step(.due(attempt: attempt, now: now))
        for effect in effects {
            guard case .fire(let path) = effect,
                  let drag = activeDrag,
                  drag.path == path,
                  let rep = kitHooks.pressRepeatPayload,
                  rep.path == path,
                  let idx = nodeByPath[drag.path],
                  let onDrag = flatNodes[idx].el.handlers.onDrag else {
                continue
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
            let prevRepeat = slice2State.dragRepeatFiringNow
            let prevMods = slice2State.currentMods
            let prevTime = slice2State.currentInputTime
            slice2State.dragRepeatFiringNow = true
            slice2State.currentMods = rep.mods
            slice2State.currentInputTime = now
            defer {
                slice2State.dragRepeatFiringNow = prevRepeat
                slice2State.currentMods = prevMods
                slice2State.currentInputTime = prevTime
            }
            var tx = makeTx(at: now, button: drag.button)
            tx.runtimeActions["dragRepeat"] = true
            onDrag(&state, d, &tx)
            if !tx.askedMotion { tx.instant() }
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
            armKitDragRepeatIfRequested(path: drag.path, windowPos: rep.windowPos, mods: rep.mods, button: drag.button, now: now)
        }
    }

    internal func kitNextWakeDeadline(after now: Double) -> Double? {
        var best = kitHooks.hoverDelays.nextWakeDeadline(after: now)
        if let repDue = kitHooks.pressRepeat.nextWakeDeadline(after: now) {
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

    /// Dispatches Menu / Shift+F10 to the focused element's or ancestor's `onSecondaryClick` at its bottom-left (`secondary.rs:122`).
    internal func dispatchContextMenuKey(
        _ ev: KeyEvent,
        at now: Double,
        drawnRectByPath: [String: MotionRect],
        presentedRectByPath: [String: MotionRect]
    ) -> Bool {
        let m = ev.mods
        let plain = !m.cmd && !m.ctrl && !m.alt && !m.logo
        let menuKey: Bool = switch ev.key {
        case .contextMenu: plain
        case .f(10): plain && m.shift
        default: false
        }
        guard menuKey,
              let fp = focusedPath,
              let fIdx = nodeByPath[fp],
              fIdx < flatNodes.count,
              !flatNodes[fIdx].effectiveInert else {
            return false
        }
        let fNode = flatNodes[fIdx]
        let box = drawnRectByPath[fNode.path] ?? presentedRectByPath[fNode.path] ?? fNode.targetRect
        let pt = Vec2(box.left, box.bottom)
        var walkIdx: Int? = fIdx
        while let curIdx = walkIdx {
            let cur = flatNodes[curIdx]
            if cur.effectiveInert { return false }
            if let onSecondary = cur.el.handlers.onSecondaryClick {
                let nr = presentedRectByPath[cur.path] ?? cur.targetRect
                let press = PointerPress(
                    window: pt,
                    local: Vec2(pt.x - nr.x, pt.y - nr.y),
                    elementSize: Vec2(nr.width, nr.height),
                    button: .secondary,
                    mods: m,
                    clicks: 1
                )
                var tx = makeTx(at: now, button: .secondary)
                onSecondary(&state, press, &tx)
                applyTx(tx, at: now)
                return true
            }
            if cur.el.isModal { return false }
            walkIdx = cur.parentIndex
        }
        return false
    }
}
