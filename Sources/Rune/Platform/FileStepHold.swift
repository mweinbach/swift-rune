import Foundation

// MARK: - File steps on a stale tree (`runtime/input/drop.rs`'s `hold_files` / `release_files`)
//
// Upstream queues every file step (`Action::Files`) for the next frame. Before running the
// queue, `frame_step` calls `hold_files(queue, ran || self.dirty)`: a step that hit-tests (a
// hover, a move or a drop) reaching a tree changed since its last build waits for this frame's
// build, once, so it lands on what is mounted and laid out now; the file steps after it wait
// too, to keep their order. After the frame's commit `release_files` puts them first in the next
// frame's queue, marked as having waited, so they aren't held a second time.
//
// Swift dispatches a host's file step when it arrives. "Changed since its last build" is a
// commit pending for a poll or a state change outside input (`CommitWhy` `POLL`/`DIRTY`, see
// `fileStepTreeStale`); a covered window's steps already wait in
// `pendingHiddenDrops` for the build that uncovers it. A held step joins them: the frame replays
// them once its commit has built the new tree (`flushHiddenDropSteps` after the main commit, or
// at the start of the next frame when nothing is pending), through the `perform…` paths, which
// don't hold again (`waited`). While any step waits, every later file step, a leave included,
// waits behind it, as upstream partitions all of the queue's file steps together.

extension Runtime {
    /// Whether the tree a file step would hit-test changed since its last build (`hold_files`'s
    /// `stale`: `ran || self.dirty`). Upstream decides that once a frame, before the queued
    /// actions run: `ran` is the frame's poll, `dirty` a state change outside the queue
    /// (`Runtime::update`, a setting, a covered window's unbuilt change). The queued input before
    /// the step runs in the same pass, hit-testing the same tree, so it doesn't count. Here that
    /// is a commit pending for `POLL` or `DIRTY`; input that already ran (`INPUT`) is what
    /// upstream's queue would have run alongside the step.
    internal var fileStepTreeStale: Bool {
        needsCommit && commitWhyPending & (CommitWhy.poll | CommitWhy.dirty) != 0
    }

    /// Whether a file step arriving now waits for the frame's build (`hold_files`): any step
    /// while earlier ones wait, keeping their order; else one that aims (`aims`: a hover, a move
    /// or a drop, not a leave) at a stale tree.
    internal func holdsFileStep(aims: Bool) -> Bool {
        if !pendingHiddenDrops.isEmpty { return true }
        return aims && fileStepTreeStale
    }

    /// File steps wait for the next build (`files_held`): covered, or held on a stale tree.
    internal var fileStepsHeld: Bool { !pendingHiddenDrops.isEmpty }
}
