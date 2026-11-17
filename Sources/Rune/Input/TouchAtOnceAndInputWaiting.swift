import Foundation

// MARK: - `El::touch_drags_at_once` (`el/handlers.rs`, `runtime/input/touch.rs`, #938)

extension El {
    /// A finger on this `El.onDrag` element drags it from where it lands: no 8-point slop,
    /// no long press (a finger held still keeps dragging, as a game's paddle wants), and never a
    /// pan of the page under it. A mouse is unchanged (`El::touch_drags_at_once`).
    public func touchDragsAtOnce() -> Self {
        var copy = self
        copy.handlers.touchAtOnce = true
        return copy
    }
}

extension Runtime {
    /// Whether the held press is on an `El.touchDragsAtOnce` element (`Runtime::press_drags_at_once`).
    internal func pressDragsAtOnce() -> Bool {
        guard let path = pressedPath, let idx = nodeByPath[path], idx < flatNodes.count else { return false }
        let handlers = flatNodes[idx].el.handlers
        return handlers.touchAtOnce && handlers.onDrag != nil
    }
}

// MARK: - `Tx::input_waiting` (`el/tx/keys.rs`, `runtime/input/action.rs`, #945)

extension Tx {
    /// In `poll`: whether the user's input (a key, a press, the pointer, the wheel, text) is
    /// waiting for this frame, which runs after `poll`. Work that can wait a frame (a
    /// background start, a cache warm-up) waits, so the input's frame comes without it. False
    /// everywhere else (`Tx::input_waiting`).
    ///
    /// The port runs an input's handlers as the host dispatches it, so the input waiting here is
    /// what a host dispatched through `Runtime.hostInput` since the last frame that left handler
    /// work (see `hostInput`), plus the sent keys and clipboard replies its handlers queued for this frame.
    public func inputWaiting() -> Bool { isInputWaiting }
}

/// The arrival times of the user's input waiting for the next frame, which runs after its
/// `poll` (`ActionQueue`'s `Queued::at`). `dispatched` is the latest input a host dispatched
/// (`Runtime.hostInput`) since the last frame that left handler work: the port's counterpart of
/// the queued `Key`/`Press`/`PointerMove`/`Hover`/`Wheel`/`Gesture`/`Ime` actions, whose
/// handlers already ran but whose frame has not. `sentKeys` holds one stamp per queued sent key:
/// the input being dispatched when it was queued, `nil` for what timers, updates and polls
/// queue; each runs under its own stamp. Queued clipboard replies (`Action::Paste`,
/// `Action::ClipboardRead`) carry their stamps in `ClipboardRoutingState.replies`.
internal struct QueuedInputArrivals {
    var dispatched: Double?
    var sentKeys: [Double?] = []

    /// Whether any of them came from the user's input: they carry its arrival time
    /// (`ActionQueue::has_input`).
    var hasInput: Bool {
        dispatched != nil || sentKeys.contains { $0 != nil }
    }
}

/// The platform input events a host stamps with their arrival (`input::time::Kind`), split where
/// they queue handler work differently.
public enum HostInputKind: Sendable, Equatable {
    /// A key press, typed text or an input method event: always handler work (upstream queues
    /// its `Key`/`Physical`/`Ime` action unconditionally).
    case keyPress
    /// A key release or a modifier change: handler work only when a handler hears it
    /// (`key_up`, `physical_observation`).
    case keyRelease
    /// The pointer moved, pressed, lifted or left.
    case pointer
    case wheel
    case magnify
    case rotate
    case smartMagnify
}

extension Runtime {
    /// Dispatches the platform input event `body` delivers inside a scope holding when it
    /// arrived: `eventTimestamp` is the event's own stamp in seconds since boot
    /// (`NSEvent.timestamp`, `UIEvent.timestamp`), else now. `InputTime.lastInput` becomes now,
    /// the moment it was dispatched (`input::time::arrived`, which `window.rs` wraps around every
    /// window input event).
    ///
    /// When the input left handler work for the next frame, the next poll sees it waiting: the
    /// port's counterpart of the stamped actions upstream queues. A key press always does; any
    /// other input does when a handler ran for it (an `on_pointer_move`, a press, an `on_wheel`
    /// chain, a gesture handler), when it moved the hover to an element that takes primary input
    /// (`primaryTargetPath`), or when it moved focus.
    /// A move over nothing that handles it, or a wheel that only scrolls, leaves nothing waiting.
    @discardableResult
    public func hostInput<R>(_ kind: HostInputKind, eventTimestamp: Double? = nil, _ body: () throws -> R) rethrows -> R {
        let arrival = InputTime.arrival(ofEventStamped: eventTimestamp)
        InputTime.noteDispatched()
        let (handlersBefore, hoveredBefore, focusedBefore) = (inputHandlerRuns, primaryTargetPath(), focusedPath)
        defer {
            let hovered = primaryTargetPath()
            let queued = kind == .keyPress
                || inputHandlerRuns != handlersBefore
                || (hovered != nil && hovered != hoveredBefore)
                || focusedPath != focusedBefore
            if queued { queuedInputArrivals.dispatched = arrival }
        }
        return try InputTime.withArrival(arrival, body)
    }

    /// What upstream's hover holds under the pointer (`hit.rs::primary_target`): the topmost
    /// element there that takes primary input (`top_target`), or for plain selectable text the
    /// nearest ancestor that handles a press or takes focus. A move that changes it to an element
    /// queues `Action::Hover` (`hover.rs::apply_hovered`); a hover colour alone is no target, so
    /// moving onto one queues nothing.
    internal func primaryTargetPath() -> String? {
        let pos = pointerPosition
        guard pos.x > -9000, pos.y > -9000 else { return nil }
        guard let top = hitTest(at: pos, predicate: { self.takesPrimaryInput($0) })?.node else { return nil }
        if !top.el.isSelectable || hasPrimaryHandler(top) || !top.el.textLinks.isEmpty { return top.path }
        var parent = top.parentIndex
        while let p = parent, p < flatNodes.count {
            let node = flatNodes[p]
            if node.effectiveInert || node.el.isModal { break }
            if hasPrimaryHandler(node) || node.el.focusable { return node.path }
            parent = node.parentIndex
        }
        return top.path
    }

    /// `Handlers::has_primary`: a press, double press, hover, drag or drag-out handler.
    private func hasPrimaryHandler(_ node: FlatNode) -> Bool {
        let h = node.el.handlers
        return h.onClick != nil || h.onClickPress != nil || h.onDoubleClick != nil || h.onHover != nil
            || h.onDrag != nil || h.dragOut != nil || node.el.attachedDragOutItem != nil
    }

    /// `top_target`'s test: an element that takes primary input, selectable text included.
    private func takesPrimaryInput(_ node: FlatNode) -> Bool {
        let el = node.el
        return hasPrimaryHandler(node) || el.handlers.editLens != nil || el.role == .textInput
            || (el.role == .button && (el.hoverBg != nil || el.pressBg != nil || el.pressColor != nil))
            || el.isWindowDrag || el.focusable || el.isModal || el.isSelectable || !el.textLinks.isEmpty
    }

    /// Whether any queued action came from the user's input, carrying its arrival time: the
    /// poll's `Tx.inputWaiting` (`frame.rs`: `one.input_waiting = self.queue.has_input()`).
    internal var queuedInputWaiting: Bool {
        queuedInputArrivals.hasInput || clipboardRouting.replies.contains { $0.at != nil }
    }

    /// The frame has run past its poll: the input dispatched before it is no longer waiting.
    internal func frameTookDispatchedInput() {
        queuedInputArrivals.dispatched = nil
    }
}
