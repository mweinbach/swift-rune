import Foundation

// MARK: - Commit watch (runtime/commit/watch.rs)
//
// The runtime's side of `perf_warn`'s commit watch: why each of a frame's commits ran, for the
// frame log (`commitWhy`) and `RUNE_COMMIT_BUDGET_MS`, and what the commit warnings hear once a
// frame (`watch_frame` is `perfWatch.meter.frameEnds` at the end of `frameWithBlendScope`).
//
// Upstream's `frame_step` gathers a frame's `why` in a local as its poll and queued handlers run.
// The Swift runtime applies a handler's or poll's `Tx` as it arrives (`applyTx` → `dirtyCommit`),
// so the bits a cause asks for wait in `commitWhyPending` until the commit that answers them.
//
// Upstream runs `commit_for` for two commits: the route commit before a routed event and the
// frame's main commit. The Swift frame splits the main commit's `read` and `virtual` parts into
// their own commits (a moved layout read, a scroll that shifts a virtual window) and runs one
// main commit per due timer in a split frame's catch-up (upstream's headless `timer_step` runs a
// `frame_step` each); those go through `commitFor` too. A follow-up commit the main commit left
// pending goes through `commitFor` when something asked for it with a cause (upstream commits for
// it next frame), else it is `commitOutsideWatch`, as upstream's plain `commit` calls are.

extension Runtime {
    /// A commit for `why` (`CommitWhy` bits) (`commit_for`): records the cause for the frame log
    /// and interaction timing, and holds it as the commit watch's cause while the commit runs, so
    /// `RUNE_COMMIT_BUDGET_MS` names it.
    internal func commitFor(why: UInt16, at now: Double, cut: Bool, resizeSnap: Bool = false) {
        let why = why | commitWhyPending
        commitWhyPending = 0
        commitWhy |= why
        if InteractionGate.isOn {
            perfWatch.interaction.committed(why: why)
        }
        perfWatch.cause = why
        commitTree(at: now, cut: cut, resizeSnap: resizeSnap)
        perfWatch.cause = 0
    }

    /// A commit outside `commit_for` (upstream's plain `self.commit(tx)`): interaction timing
    /// doesn't count it and `RUNE_COMMIT_BUDGET_MS` names no cause for it. The Swift frame runs
    /// one when its main commit left another pending (upstream commits that next frame); what
    /// was asked for since stays in the frame log's `commitWhy`, since this commit answers it.
    internal func commitOutsideWatch(at now: Double, cut: Bool, resizeSnap: Bool = false) {
        commitWhy |= commitWhyPending
        commitWhyPending = 0
        perfWatch.cause = 0
        commitTree(at: now, cut: cut, resizeSnap: resizeSnap)
    }

    /// A commit the frame's main commit left pending. With causes asked for during the main
    /// commit (a scroll callback, a moved read), it is the commit upstream runs for them next
    /// frame, here in this one: `commitFor` them. Without, a plain commit.
    internal func commitFollowUp(at now: Double) {
        if commitWhyPending != 0 {
            commitFor(why: 0, at: now, cut: false)
        } else {
            commitOutsideWatch(at: now, cut: false)
        }
    }

    /// The cause of a frame's main commit (`frame.rs`'s `commit_for` after the queue drains):
    /// what poll, handlers and state changes left pending, a pending `Tx::settle`, layout
    /// handlers that asked for it and layout reads that moved. A virtual window's shift only
    /// counts when nothing else (dirty state, a relayout, a settle) would commit anyway.
    internal func frameCommitWhy(settle: Bool, layout: Bool, read: Bool) -> UInt16 {
        var why = commitWhyPending
        if settle { why |= CommitWhy.settle }
        if layout { why |= CommitWhy.layout }
        if read { why |= CommitWhy.read }
        if why & (CommitWhy.dirty | CommitWhy.relayout | CommitWhy.settle) != 0 {
            why &= ~CommitWhy.virtual
        }
        return why
    }

    /// A scroll that moved a viewport commits when a virtual list's window may shift, the view
    /// read a scroll offset, or scroll callbacks (`on_at_bottom`, `on_far_from_bottom`) watch it.
    /// Upstream queues those from the frame as actions that aren't input (`ActionQueue::push`,
    /// action.rs:87-90: `AtBottom` and `FarFromBottom` are `input: false`), so their handlers'
    /// changes commit for `DIRTY` (frame.rs: `why |= if input { INPUT } else { DIRTY }`).
    internal var scrollCommitWhy: UInt16 {
        (activeVirtualPaths.isEmpty ? 0 : CommitWhy.virtual)
            | (lastViewReadScroll ? CommitWhy.read : 0)
            | (hasScrollCallbacks() ? CommitWhy.dirty : 0)
    }
}
