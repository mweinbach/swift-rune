import Foundation

public extension Runtime {
    /// The text holding the selection's anchor and the range selected in it (`Runtime::text_selection`):
    /// the whole selection when it lies in that text, else the part of it from the anchor to the
    /// text's end (or start) toward the focus. A collapsed selection is an empty range at the caret.
    func textSelection() -> (path: String, range: Range<Int>)? {
        guard let h = selectionHolderEnd(), let sel = selectionState.coordinator.phase.selection else { return nil }
        let range: Range<Int>
        if sel.far == nil {
            range = min(sel.anchor, sel.focus)..<max(sel.anchor, sel.focus)
        } else {
            guard let f = focusHolderEnd(h) else { return nil }
            if f == h {
                range = min(sel.anchor, sel.focus)..<max(sel.anchor, sel.focus)
            } else {
                let len = h.text.utf8.count
                let (a, b) = selectionTreeOrder(of: h) < selectionTreeOrder(of: f)
                    ? (min(sel.anchor, len), len)
                    : (0, min(sel.anchor, len))
                range = a < b ? a..<b : sel.anchor..<sel.anchor
            }
        }
        return (sel.path, range)
    }
}

internal extension Runtime {
    // MARK: - Select All over virtual rows (`select_all.rs`, `selection_collect.rs::virtual_span_under`)

    /// The selectable texts of unmounted row `r`, built on demand, with their selection groups.
    private func offscreenRowTexts(listPath: String, src: VirtualSelectionSource, row r: Int) -> [(path: String, text: String, group: String?)] {
        guard let listIdx = nodeByPath[listPath], listIdx < flatNodes.count else { return [] }
        var rowSnaps: [SelectableNodeSnapshot] = []
        collectOffscreenRowSnapshots(
            source: src,
            rowIndex: r,
            rowSegment: "@\(src.keys[r])",
            parentInert: flatNodes[listIdx].effectiveInert,
            baseY: 0,
            into: &rowSnaps
        )
        let listGroup = selectionGroupPath(atOrAbove: listIdx)
        var byPath: [String: Int] = [:]
        for (k, s) in rowSnaps.enumerated() { byPath[s.path] = k }
        return rowSnaps.compactMap { snap in
            guard snap.isSelectable, !snap.text.isEmpty else { return nil }
            var group = listGroup
            var p = snap.parentPath
            while let pp = p, let k = byPath[pp] {
                if rowSnaps[k].isSelectionGroup { group = rowSnaps[k].path; break }
                p = rowSnaps[k].parentPath
            }
            return (snap.path, snap.text, group)
        }
    }

    /// The first and last selectable text of selection group `gp` when it holds a virtual list,
    /// building unmounted rows at either end (`Runtime::virtual_span_under`).
    func virtualSpanUnder(groupPath gp: String) -> (first: (path: String, text: String), last: (path: String, text: String))? {
        guard let root = nodeByPath[gp], root < flatNodes.count else { return nil }
        let prefix = gp + "/"
        func inside(_ j: Int) -> Bool { flatNodes[j].path == gp || flatNodes[j].path.hasPrefix(prefix) }
        var found: Int? = nil
        var j = root
        while j < flatNodes.count, inside(j) {
            if let src = virtualSelectionSources[flatNodes[j].path], !src.keys.isEmpty { found = j; break }
            j += 1
        }
        guard let ln = found, let src = virtualSelectionSources[flatNodes[ln].path] else { return nil }
        let listPath = flatNodes[ln].path
        func member(_ j: Int) -> (path: String, text: String)? {
            guard let text = selectableNodeText(flatNodes[j]), !text.isEmpty,
                  selectionGroupPath(ofMounted: j) == gp else { return nil }
            return (flatNodes[j].path, text)
        }
        let listPrefix = listPath + "/"
        var listEnd = ln
        while listEnd + 1 < flatNodes.count, flatNodes[listEnd + 1].path.hasPrefix(listPrefix) { listEnd += 1 }
        func rowNodes(_ r: Int) -> [Int]? {
            let rowPath = "\(listPath)/@\(src.keys[r])"
            guard let rowIdx = nodeByPath[rowPath], rowIdx <= listEnd else { return nil }
            var out: [Int] = []
            var k = rowIdx
            while k <= listEnd, k == rowIdx || flatNodes[k].path.hasPrefix(rowPath + "/") {
                out.append(k)
                k += 1
            }
            return out
        }

        // 1. The first selectable text under the group.
        var first: (path: String, text: String)? = nil
        for k in root..<ln where inside(k) {
            if let m = member(k) { first = m; break }
        }
        if first == nil {
            for r in 0..<src.keys.count {
                if let nodes = rowNodes(r) {
                    if let m = nodes.lazy.compactMap(member).first { first = m; break }
                } else if let t = offscreenRowTexts(listPath: listPath, src: src, row: r).first(where: { $0.group == gp }) {
                    first = (t.path, t.text)
                    break
                }
            }
        }
        guard let first else { return nil }

        // 2. The last selectable text under the group.
        var last: (path: String, text: String)? = nil
        var after = listEnd + 1
        while after < flatNodes.count, inside(after) {
            if let m = member(after) { last = m }
            after += 1
        }
        if last == nil {
            for r in (0..<src.keys.count).reversed() {
                if let nodes = rowNodes(r) {
                    if let m = nodes.reversed().lazy.compactMap(member).first { last = m; break }
                } else if let t = offscreenRowTexts(listPath: listPath, src: src, row: r).last(where: { $0.group == gp }) {
                    last = (t.path, t.text)
                    break
                }
            }
        }
        return (first, last ?? first)
    }

    /// Selects from the start of `first` to the end of `last`, mounted or not
    /// (`Runtime::select_span_ends`), and seals it.
    func selectSpanEnds(first: (path: String, text: String), last: (path: String, text: String)) {
        let far: SelectionFar? = first.path == last.path ? nil : SelectionFar(path: last.path, content: last.text)
        let end = far?.content.utf8.count ?? first.text.utf8.count
        let origin = far != nil ? (0, 0) : (0, end)
        selectionState.coordinator.phase.place(ActiveSelection(
            path: first.path,
            content: first.text,
            anchor: 0,
            focus: end,
            origin: origin,
            far: far
        ))
        if far != nil {
            let all = selectableSnapshotsWithVirtuals()
            if let a = all.firstIndex(where: { $0.path == first.path }),
               let f = all.firstIndex(where: { $0.path == last.path }),
               var sel = selectionState.coordinator.phase.selection {
                sel.betweenHash = SelectionMath.computeBetweenHash(in: all, anchorIdx: a, farIdx: f)
                selectionState.coordinator.phase.place(sel)
            }
        }
        sealBetween()
    }
}
