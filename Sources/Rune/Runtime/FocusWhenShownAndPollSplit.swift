import Foundation

// Upstream commits ported here:
// - 412aa963 (#1000) + 73b7dec2 (#1006): `Tx::focus_when_shown` / `FocusAsk::WhenShown` and the
//   runtime's `focus_owed` (`el/tx.rs`, `runtime/input/focus.rs::sync_requested_focus`,
//   `runtime/frame.rs`).
// - 2e23d0fa (#995): `Runtime::covered_wake` (`runtime/frame.rs`) and `window::covered_step`.
// - 56e0306d (#970): a poll's change commits apart from same-frame input (`Tx::polled_change`,
//   `CommitWhy::POLL`, `Queued::input`, `runtime/frame.rs`, `runtime/motion/timer_wake.rs`).
//
// How #970 maps onto Swift's input model. Upstream queues every input for the next frame and
// runs it there after the frame's poll; a resting poll (`poll_alone`) runs between frames. Swift
// runs a host input's handlers when the host delivers it. So:
// - A resting poll's change (`polledChange`, set in `pollAlone`) is still uncommitted when input
//   arrives: the input commits it first, on its own (`commitPolledChangeApart`), before its own
//   handlers run, as upstream's `split` does before the first input or routed action.
// - The frame's own poll runs after input that arrived since the last frame already changed the
//   model. With `motionNeedsCause`, that input's tree commits first, animated, and the poll's
//   change commits after it unprompted, at once (`commitInputApartFromFramePoll`,
//   `framePollChanged`): the same two trees with the same motion, in the order Swift's dispatch
//   allows. Input the frame itself runs after its poll (pastes, sent keys, hover delays,
//   playground stage keys) splits as upstream does.
// - `Queued::input` (INPUT vs DIRTY): every input entry point (presses, keys, IME, pointer move
//   and leave, wheel, paste, file drop, gestures; `beginInputDispatch`) counts as the commit's
//   input cause only when it changed the model (`if r { why |= INPUT }`): a handler's change
//   (`applyTx`), a state change asking for a commit (`dirtyCommit(external:)`), or a press moving
//   focus (`noteHandlerChange`). `on_selection_change` callbacks and `Tx.readClipboard` replies
//   are DIRTY however they're reached (`inputObserverDepth`, `ActionQueue::push`'s non-input
//   actions). Layout and visibility observers and the stationary pointer's re-hit after layout
//   run in the frame, outside every input entry point, so they stay DIRTY, as
//   `ActionQueue::push` and `observe_since` keep them.
// - `focus_owed` vs the split: upstream drops an owed `Tx.focusWhenShown` for each key, press or
//   field focus in the frame's queue, the split commits the poll's tree (making an unresolved ask
//   owed) before the first input action, after that action's own drop. So an ask the split made
//   owed survives the presses of the input that split, and is dropped by a press or key that runs
//   after another input action did. `focusOwedFromSplit` holds until the next frame or until an
//   input entry point that upstream queues as an action ran (a key, a release, a press that moved
//   focus or changed the model).

extension Tx {
    /// `Tx.focus` for an element that may not be shown yet: content still loading, a card that
    /// comes in with the next build, a window that isn't drawing (`Tx::focus_when_shown`). The
    /// request waits, through any number of commits, until an element with the key shows, and
    /// focuses it then, however long its loading or motion takes, whatever focus did meanwhile
    /// (a closing palette leaving it on the prompt). It's dropped when the user presses a key or
    /// a pointer button, or when another focus is asked for.
    public mutating func focusWhenShown(_ key: String, ring: Bool) {
        requestedFocusKey = key
        requestedFocusVisible = ring
        focusAskedByReturn = false
        focusAskedWhenShown = true
    }
}

extension Runtime {
    // MARK: - Tx.focusWhenShown

    /// Whether a `Tx.focusWhenShown` is still waiting for its element (`Runtime::focus_owed`).
    public var focusWhenShownPending: Bool { focusOwed != nil || pendingFocusWhenShown != nil }

    /// The user's own key or press takes over from a `Tx.focusWhenShown` still waiting
    /// (`frame.rs`: `Action::Key { stage: false }`, a pressed physical key, `Action::Press`,
    /// `Action::Focus`). Upstream drops it before that action's poll split commits an ask not yet
    /// resolved; `keepingSplit` keeps one the split made owed when no input action has run since
    /// (`focusOwedFromSplit`).
    internal func dropOwedFocus(keepingSplit: Bool = false) {
        if keepingSplit && focusOwedFromSplit { return }
        focusOwed = nil
    }

    /// `sync_requested_focus`'s `asked = focus_request.take().or(owed)` for `FocusAsk::WhenShown`:
    /// a `Tx.focusWhenShown` asked since the last commit, else one still owed. Another focus ask
    /// (`otherAsk`) drops both. Resolved against the tree just committed: the first shown element
    /// with the key, or its first shown focusable descendant. When nothing with the key shows,
    /// the ask is owed again for the next commit (`if asked.is_none() && waits`).
    internal func takeFocusWhenShown(otherAsk: Bool) -> (index: Int, ring: Bool)? {
        let owed = focusOwed
        focusOwed = nil
        let asked = pendingFocusWhenShown
        pendingFocusWhenShown = nil
        guard !otherAsk, let ask = asked ?? owed else { return nil }
        if let index = focusWhenShownTarget(ask.key) {
            return (index, ask.ring)
        }
        focusOwed = ask
        return nil
    }

    /// `sync_requested_focus`'s `shown`: not inert, not transparent itself or through an ancestor,
    /// and laid out with a size.
    internal func focusAskShown(_ idx: Int) -> Bool {
        guard flatNodes.indices.contains(idx) else { return false }
        let n = flatNodes[idx]
        guard !n.effectiveInert, n.el.opacity > 0.0, n.targetRect.width > 0.0, n.targetRect.height > 0.0 else {
            return false
        }
        var walk = n.parentIndex
        while let p = walk, flatNodes.indices.contains(p) {
            if flatNodes[p].el.opacity <= 0.0 { return false }
            walk = flatNodes[p].parentIndex
        }
        return true
    }

    /// `Tx::focus`'s target (`sync_requested_focus`): the first shown element keyed `key`, or the
    /// first shown focusable element inside it.
    internal func focusWhenShownTarget(_ key: String) -> Int? {
        guard let anchor = flatNodes.indices.first(where: { matchesAuthoredKey(flatNodes[$0].key, key) && focusAskShown($0) }) else {
            return nil
        }
        let root = flatNodes[anchor].path
        var j = anchor
        while j < flatNodes.count {
            let path = flatNodes[j].path
            guard path == root || path.hasPrefix(root + "/") else { break }
            if focusAskShown(j) && canFocusIndex(j) { return j }
            j += 1
        }
        return nil
    }

    // MARK: - Covered windows (#995)

    /// A frame that builds what changed without advancing time or motion
    /// (`Runtime::hidden_timer_frame`, `frame(0.0)`): a zero step (`frameStep(dt: 0)`).
    internal func hiddenTimerFrame() {
        // Upstream's frame commits for `needs_commit()`, pending frame work included; Swift's
        // commit is what resolves pending scroll requests, flights and launches.
        if hasPendingHiddenWork { needsCommit = true }
        _ = frameStep(dt: 0.0)
    }

    /// `hiddenWake` for a shown window that can't draw (covered, minimised, on a locked or
    /// sleeping display) (`Runtime::covered_wake`). While an assistive client reads its tree,
    /// what changed is built at once, without drawing or motion, so the tree it reads and focus
    /// asked of what the change shows (a permission's card) are current whatever the window's
    /// motion does. Returns what `hiddenWake` does.
    @discardableResult
    public func coveredWake(at now: Double? = nil) -> Bool {
        let stale = hiddenWake(at: now)
        // `needs_commit()`: `dirty || pending.frame_work() || patch_pending()`, pending scroll
        // requests, text flights and launches included (`hasPendingHiddenWork`).
        if assistiveTechnology && hasPendingHiddenWork { hiddenTimerFrame() }
        return stale
    }

    // MARK: - Poll change committed apart from same-frame input (#970)

    /// A host input event arrives (presses, keys, IME): it marks the frame as not quiet for the
    /// idle meter, and starts an input entry point (`beginInputDispatch`). Returns the enclosing
    /// dispatch's state, for `endInputDispatch`.
    internal func noteInput(at now: Double, routed: Bool = false) -> Bool {
        frameHadInputSinceLastFrame = true
        return beginInputDispatch(at: now, routed: routed)
    }

    /// An input entry point starts: a poll's change waiting to commit commits first (`split` on
    /// `input || routed`). Returns the enclosing dispatch's change flag, for `endInputDispatch`.
    internal func beginInputDispatch(at now: Double, routed: Bool = false) -> Bool {
        dispatchPendingPaintHover(at: now)
        commitPolledChangeApart(at: now, routed: routed)
        let outer = inputDispatchChanged
        inputDispatchChanged = false
        inputDispatchDepth += 1
        return outer
    }

    /// The input entry point ends: when it changed the model, the commit has an input cause
    /// (`if r { why |= CommitWhy::INPUT }`), whether or not a commit was already pending. Within a
    /// frame that's the frame's commit; between frames, the next frame's. `queuedAction`: upstream
    /// queues this input as an action whatever it changes (a key, a release); with a change, any
    /// input entry point did. Either way a later press or key in the frame comes after an input
    /// action, so it drops an ask the split made owed (`focusOwedFromSplit`).
    internal func endInputDispatch(_ outer: Bool, queuedAction: Bool = false) {
        inputDispatchDepth -= 1
        let changed = inputDispatchChanged
        inputDispatchChanged = outer || changed
        if inputDispatchDepth == 0 && (changed || queuedAction) { focusOwedFromSplit = false }
        guard changed else { return }
        if insideFramePollOrInput {
            frameCommittedFromInput = true
        } else {
            frameHadInputSinceLastFrame = true
            frameInputCauseSinceLastFrame = true
        }
    }

    /// The input changed the model (`r`): a handler's transaction (`applyTx`), a state change that
    /// asks for a commit (`dirtyCommit`), or a press that moved focus. Inside an input entry point
    /// that's the input's change, unless an observer callback that upstream counts as DIRTY made
    /// it (`on_selection_change`, `Tx.readClipboard`'s reply).
    internal func noteHandlerChange() {
        if inputDispatchDepth > 0 && inputObserverDepth == 0 { inputDispatchChanged = true }
    }

    /// Runs `body` as an observer: whatever it changes is DIRTY, never the enclosing input's
    /// (`ActionQueue::push`'s non-input actions).
    internal func asInputObserver<R>(_ body: () -> R) -> R {
        inputObserverDepth += 1
        defer { inputObserverDepth -= 1 }
        return body()
    }

    /// Both a poll and an input handler see ordinary `inout State`; after the handler's mutation a
    /// single view can't tell which introduced a row. So when motion needs a cause and a poll's
    /// change hasn't committed, its tree commits now, before the input's handlers run: at once
    /// when nothing asked for motion (`unprompted`), its scroll requests resolved against it
    /// (`finish_scroll_requests(tx, false)`: the caret follow waits for the handler's commit),
    /// and its motion policy spent (`commitTree` takes it), so the handler's own change keeps its
    /// animation (`frame.rs` `split`).
    internal func commitPolledChangeApart(at now: Double, routed: Bool) {
        guard motionNeedsCause, polledChange, needsCommit else { return }
        if !pendingAskedMotion { pendingUnprompted = true }
        let follow = pendingCaretFollow
        pendingCaretFollow = false
        let asked = pendingFocusWhenShown != nil
        flushPendingCommitIfNeeded(at: now, routed: routed)
        polledChange = false
        if asked && focusOwed != nil { focusOwedFromSplit = true }
        pendingCaretFollow = pendingCaretFollow || follow
    }

    /// Before the frame's own poll (or the playground's), with `motionNeedsCause`: input that
    /// arrived since the last frame already changed the model, so its tree commits first, with
    /// its motion, and the poll's change can commit on its own after it.
    internal func commitInputApartFromFramePoll(at now: Double, polls: Bool) {
        guard polls, motionNeedsCause, frameCommittedFromInput, needsCommit else { return }
        flushPendingCommitIfNeeded(at: now, routed: false)
    }

    /// The frame's poll changed the model (`why |= CommitWhy::POLL`). Input already handled has
    /// committed (`commitInputApartFromFramePoll`), so with `motionNeedsCause` the poll's change
    /// is unprompted and lands at once unless the poll asked for motion; input the frame runs
    /// after it splits from it (`commitPolledChangeApart`).
    internal func framePollChanged() {
        polledChange = true
        if motionNeedsCause && !pendingAskedMotion && frameCommittedFromInput { pendingUnprompted = true }
    }
}

/// What a shown window that can't draw runs for an update, a wake, a due timer or a redraw:
/// covered (an occlusion event, or a drawable refused as occluded), minimised, or waiting out a
/// missed frame (`window::covered_step`). `poll`, due timers and queued input run now, as for a
/// hidden window (`Runtime.hiddenWake`); the view and layout wait, dirty, for the frame that
/// uncovers it, unless an assistive client reads the window (`Runtime.coveredWake`).
public func coveredStep<State>(_ rt: Runtime<State>, at now: Double? = nil) {
    rt.coveredWake(at: now)
}
