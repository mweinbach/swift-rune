import Foundation
import RuneMotion

/// Fold hold and restore helpers matching `runtime/motion/fold_hold.rs`.
extension Runtime {
    /// Header string + clipped height above viewport top when a fold shuts near the top edge.
    internal func foldHiddenAbove(
        rowIndex j: Int,
        toHeight to: Float,
        in nodes: [FlatNode]
    ) -> (above: Float, headerKey: String)? {
        guard j < nodes.count else { return nil }
        let row = nodes[j]
        guard let scrollIdx = row.enclosingVScrollIndex, scrollIdx < nodes.count else { return nil }
        let vp = nodes[scrollIdx]
        guard let drawnRow = drawnRectByPath[row.path] ?? presentedRectByPath[row.path],
              let drawnVp = drawnRectByPath[vp.path] ?? presentedRectByPath[vp.path] else {
            return nil
        }
        let scale = max(1e-4, presentedScaleByPath[vp.path]?.y ?? 1.0)
        let rowH = row.targetRect.height
        let topAbove = max(0.0, (drawnVp.y - drawnRow.y) / scale)
        guard topAbove > 0.5, rowH > to + 0.5 else { return nil }
        return (above: topAbove, headerKey: row.key ?? row.path)
    }

    /// Steps scroll offset and max extent back by `cut` when folds drop hidden points above the viewport (`scroll_by_cut`).
    internal func scrollByCut(enclosingScrollPath: String?, cut: Float) {
        guard cut > 0.01, let sPath = enclosingScrollPath else { return }
        let cur = scrollOffsets[sPath] ?? .zero
        let nextY = max(0.0, cur.y - cut)
        let maxExt = scrollMaxExtents[sPath] ?? .zero
        scrollMaxExtents[sPath] = Vec2(maxExt.x, max(0.0, maxExt.y - cut))
        scrollOffsets[sPath] = Vec2(cur.x, nextY)
        let nid = NodeId.hash("scroll:\(sPath)")
        if scrollStore.has(nid, Props.SCROLL) {
            scrollStore.snap(nid, Props.SCROLL, to: Vec2(cur.x, nextY))
        }
    }

    /// Lowers a held fold row by `d` points when adjacent folds give way (`give_way`).
    internal func lowerFoldHold(rowKey: String, delta d: Float) {
        guard abs(d) > 1e-4, var entry = growthRows[rowKey] else { return }
        if let g = entry.track.give {
            let next = max(0.0, g - d)
            entry.track.give = next > 0.5 ? next : nil
            growthRows[rowKey] = entry
        }
        if let header = foldHeaders[rowKey] {
            for idx in scrollRequestsState.keeps.indices where scrollRequestsState.keeps[idx].hold?.path == header {
                let sPath = scrollRequestsState.keeps[idx].viewport
                let scale = presentedScaleByPath[sPath]?.y ?? 1.0
                scrollRequestsState.keeps[idx].was += d * scale
            }
        }
    }

    /// Restores scroll offset above a shutting/landing fold when contents remain lifted above it (`restore_above`).
    internal func restoreScrollAboveFold(
        enclosingScrollPath: String?,
        restored: Float
    ) {
        guard restored > 0.01, let sPath = enclosingScrollPath else { return }
        if let sIdx = nodeByPath[sPath], flatNodes[sIdx].el.layout.stickBottom,
           wasPinnedToBottom.contains(sPath) {
            return
        }
        let maxY = scrollMaxExtents[sPath]?.y ?? .infinity
        let cur = scrollOffsets[sPath] ?? .zero
        let nextY = min(maxY, max(0.0, cur.y + restored))
        let next = Vec2(cur.x, nextY)
        scrollOffsets[sPath] = next
        let nid = NodeId.hash("scroll:\(sPath)")
        if scrollStore.has(nid, Props.SCROLL) {
            scrollStore.snap(nid, Props.SCROLL, to: next)
        }
    }
}
