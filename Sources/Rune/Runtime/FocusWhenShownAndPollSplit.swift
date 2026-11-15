import Foundation

// Upstream commits ported here:
// - 412aa963 (#1000) + 73b7dec2 (#1006): `Tx::focus_when_shown` / `FocusAsk::WhenShown` and the
//   runtime's `focus_owed` (`el/tx.rs`, `runtime/input/focus.rs::sync_requested_focus`,
//   `runtime/frame.rs`).
// - 2e23d0fa (#995): `Runtime::covered_wake` (`runtime/frame.rs`) and `window::covered_step`.
// - 56e0306d (#970): a resting poll's change commits apart from same-frame input
//   (`Tx::polled_change`, `runtime/frame.rs`, `runtime/motion/timer_wake.rs`).

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
        blurFocusRequested = false
    }
}

extension Runtime {
    // MARK: - Tx.focusWhenShown

    /// Whether a `Tx.focusWhenShown` is still waiting for its element (`Runtime::focus_owed`).
    public var focusWhenShownPending: Bool { focusOwed != nil || pendingFocusWhenShown != nil }

    /// The user's own key or press takes over from a `Tx.focusWhenShown` still waiting
    /// (`frame.rs`: `Action::Key { stage: false }`, a pressed physical key, `Action::Press`,
    /// `Action::Focus`).
    internal func dropOwedFocus() {
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
        guard let anchor = flatNodes.indices.first(where: { flatNodes[$0].key == key && focusAskShown($0) }) else {
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

    /// A frame that builds what changed without drawing or advancing motion
    /// (`Runtime::hidden_timer_frame`, `frame(0.0)`).
    internal func hiddenTimerFrame(at now: Double? = nil) {
        _ = frame(at: now ?? nowClock())
    }

    /// `hiddenWake` for a shown window that can't draw (covered, minimised, on a locked or
    /// sleeping display) (`Runtime::covered_wake`). While an assistive client reads its tree,
    /// what changed is built at once, without drawing or motion, so the tree it reads and focus
    /// asked of what the change shows (a permission's card) are current whatever the window's
    /// motion does. Returns what `hiddenWake` does.
    @discardableResult
    public func coveredWake(at now: Double? = nil) -> Bool {
        let stale = hiddenWake(at: now)
        if assistiveTechnology && needsCommit { hiddenTimerFrame(at: now) }
        return stale
    }

    // MARK: - Poll change committed apart from same-frame input (#970)

    /// A host input event is being dispatched: it counts as the frame's input cause, and a
    /// resting poll's change waiting to commit commits first, on its own.
    internal func noteInput(at now: Double) {
        frameHadInputSinceLastFrame = true
        commitPolledChangeApart(at: now)
    }

    /// Both a resting poll and an input handler see ordinary `inout State`; after the handler's
    /// mutation a single view can't tell which introduced a row. So when motion needs a cause
    /// and a resting poll's change hasn't committed, its tree commits now, before the input's
    /// handlers run: at once when nothing asked for motion (`unprompted`), its scroll requests
    /// resolved against it (`finish_scroll_requests(tx, false)`: the caret follow waits for the
    /// handler's commit), and its motion policy spent, so the handler's own change keeps its
    /// animation (`frame.rs` `split`).
    internal func commitPolledChangeApart(at now: Double) {
        guard motionNeedsCause, polledChange, needsCommit else { return }
        polledChange = false
        if !pendingAskedMotion { pendingUnprompted = true }
        let follow = pendingCaretFollow
        pendingCaretFollow = false
        flushPendingCommitIfNeeded(at: now)
        pendingCaretFollow = pendingCaretFollow || follow
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
