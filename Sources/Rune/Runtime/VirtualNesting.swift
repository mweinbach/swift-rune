import Foundation

// MARK: - Nested virtual lists (`#956`) & landing unmounted virtual rows (`#972`)
//
// Upstream: `crates/rune/src/el/virtual_list.rs` (`VirtualList::{nested, tail, at, locate}`),
// `runtime/commit/measure.rs` (`top`/`tail` from the laid-out list, the `nested` test),
// `runtime/scroll/offset.rs` (`anchor_offset`'s virtual-row fallback and the landing re-commits).

/// An anchored jump (`Tx.scrollKeyTo`) the runtime places again once the virtual rows it lands
/// on have mounted (`scroll_to_offsets`' landing loop).
internal struct ScrollKeyLanding: Equatable, Sendable {
    /// Landing re-commits a jump takes at most (`for _ in 0..3` in `scroll_to_offsets`).
    static let maxRounds: Int = 3

    var request: ScrollOffsetRequest
    /// How many landing re-commits have placed it again so far.
    var round: Int
}

/// The anchored jumps of the last commit, and those queued to be placed again by the next.
internal struct ScrollKeyLandings: Equatable, Sendable {
    /// Jumps the commit in progress landed (`anchors` in `scroll_to_offsets`).
    var landed: [ScrollKeyLanding] = []
    /// Jumps the next commit places again from its layout.
    var pending: [ScrollKeyLanding] = []

    /// Whether a landing re-commit is due.
    var awaiting: Bool { !pending.isEmpty }

    /// Takes the jumps queued for this commit, ahead of the commit's own requests.
    mutating func take(_ requests: [ScrollOffsetRequest]) -> [ScrollKeyLanding] {
        let again = pending
        pending.removeAll(keepingCapacity: true)
        landed.removeAll(keepingCapacity: true)
        return again + requests.map { ScrollKeyLanding(request: $0, round: 0) }
    }

    /// Notes an anchored jump the commit landed.
    mutating func land(_ landing: ScrollKeyLanding) {
        landed.append(landing)
    }

    /// After the commit: while the jumps moved a virtual window (`virtual_window_changed`), each
    /// is placed again by the next commit, up to `maxRounds` times. Returns whether one is queued.
    mutating func finish(windowsMoved: Bool) -> Bool {
        defer { landed.removeAll(keepingCapacity: true) }
        guard windowsMoved else { return false }
        pending = landed.compactMap { l in
            l.round < ScrollKeyLanding.maxRounds ? ScrollKeyLanding(request: l.request, round: l.round + 1) : nil
        }
        return !pending.isEmpty
    }
}

extension Runtime {
    /// A list in a row of another list windows against that list's viewport too: another list's
    /// path is a strict ancestor of `path`, under the same scroll path (`measure.rs`, `nested`).
    static func virtualListIsNested<Paths: Sequence>(path: String, scrollPath: String, lists: Paths) -> Bool
        where Paths.Element == String {
        lists.contains { p in p.hasPrefix(scrollPath) && path.hasPrefix(p + "/") }
    }

    /// Records where the laid-out list `listIdx` starts in the content of its viewport `scrollIdx`
    /// (`VirtualList::top`) and, for a nested list, what the viewport's content holds under it, for
    /// its window while the viewport holds its end (`VirtualList::tail`) (`measure.rs`).
    static func measureVirtualPlacement(
        _ v: inout RuntimeVirtualListState,
        listIdx: Int,
        scrollIdx: Int,
        nodes: [FlatNode]
    ) {
        let list = nodes[listIdx].unscrolledRect
        let scroll = nodes[scrollIdx].unscrolledRect
        v.top = max(0, list.top - scroll.top)
        if v.nested {
            var bottom: Float = 0
            for n in nodes where n.parentIndex == scrollIdx {
                bottom = max(bottom, n.unscrolledRect.top + n.unscrolledRect.height)
            }
            v.tail = max(0, bottom - list.top - list.height)
        }
    }

    /// `anchor_offset`'s fallback for a virtual row not mounted yet: it stands where its list's
    /// estimates put it, `top + pad_top + prefix(index)` in its viewport's content. Returns the
    /// viewport and the offset that puts the row's top `at` points below the viewport's top,
    /// before clamping. The jump there mounts it, and it's placed again from its laid-out top
    /// once it has (`ScrollKeyLandings`).
    internal func virtualRowAnchorOffset(key: String, at: Float) -> (viewport: Int, offset: Float)? {
        for node in flatNodes {
            guard let list = virtualLists[node.path],
                  let index = list.lastKeys.firstIndex(of: key),
                  let v = nodeByPath[list.scrollPath] else { continue }
            let est = max(1, node.el.virtualEstimate ?? 40)
            return (v, max(0, list.top + list.padTop + list.prefix(index, estimated: est) - at))
        }
        return nil
    }

    /// After a commit: while the anchored jumps it landed moved a virtual window, the next commit
    /// (at once, so the rows the jump mounts show without fading in) places them again.
    internal func finishScrollKeyLandings(anyVirtualList: Bool) {
        guard !scrollKeyLandings.landed.isEmpty else { return }
        let moved = anyVirtualList && anyVirtualListNeedsWindow()
        if scrollKeyLandings.finish(windowsMoved: moved) {
            // A jump is at once, and so are the rows it mounts: none fades in where it lands.
            pendingCommitKind = pendingCommitKind.instant()
            needsCommit = true
            // The jump moved a virtual window (`virtual_window_changed`, frame.rs:672): `VIRTUAL`.
            commitWhyPending |= CommitWhy.virtual
        }
    }
}
