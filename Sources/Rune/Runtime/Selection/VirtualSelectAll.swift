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
    // MARK: - Select All (`select_all.rs`, `selection_collect.rs::virtual_span_under`)

    /// Group `g`'s selectable texts, in tree order (`Runtime::group_texts`).
    func selectionGroupTexts(_ g: Int) -> [Int] {
        guard g < flatNodes.count else { return [] }
        let gPath = flatNodes[g].path
        let prefix = gPath + "/"
        var out: [Int] = []
        var j = g + 1
        while j < flatNodes.count, flatNodes[j].path.hasPrefix(prefix) {
            if selectionMember(j, group: gPath) { out.append(j) }
            j += 1
        }
        return out
    }

    /// The selection group of text `i`, or the text itself when it's in none (`Runtime::select_unit`).
    private func selectUnit(_ i: Int) -> Int {
        selectionGroupPath(ofMounted: i).flatMap { nodeByPath[$0] } ?? i
    }

    /// Where Cmd+A goes: the selection's group, else the last picked while it's mounted, else the
    /// only one in the window (`Runtime::select_all_target`).
    func selectAllTarget() -> Int? {
        if let h = selectionHolderEnd() {
            if let i = h.mountedIdx { return selectUnit(i) }
            return h.groupPath.flatMap(liveNode)
        }
        if let p = selectionState.coordinator.pick.lastGroupPath, let u = liveNode(p) {
            let n = flatNodes[u]
            let picked = (!n.effectiveInert && n.el.isSelectionGroup) ? !selectionGroupTexts(u).isEmpty : selectableLive(u)
            if picked { return u }
        }
        var first: Int? = nil
        for i in flatNodes.indices where selectableLive(i) {
            let u = selectUnit(i)
            if let f = first, f != u { return nil }
            first = u
        }
        return first
    }

    /// Cmd+A when nothing else took it: selects all of `selectAllTarget`, or of the group holding
    /// a selection whose row isn't mounted (`Runtime::select_all_key`).
    func selectAllKey() -> Bool {
        if let h = selectionHolderEnd(), h.mountedIdx == nil {
            guard let gp = h.groupPath else {
                selectSpanEnds(first: h, last: h)
                return true
            }
            if liveNode(gp) == nil {
                guard let listIdx = h.listIdx, listIdx < flatNodes.count,
                      let src = virtualSelectionSources[flatNodes[listIdx].path] else { return false }
                let members = offscreenRowSelectables(listPath: flatNodes[listIdx].path, src: src, row: h.rowIndex)
                    .filter { $0.group == gp }
                guard let first = members.first, let last = members.last else { return false }
                let end = { (t: OffscreenSelectable) in
                    SelectionEndRef(path: t.path, text: t.text, mountedIdx: nil, listIdx: listIdx, rowIndex: h.rowIndex, orderInRow: t.orderInRow, groupPath: t.group)
                }
                selectSpanEnds(first: end(first), last: end(last))
                return true
            }
        }
        guard let u = selectAllTarget(), u < flatNodes.count else { return false }
        let isGroup = !flatNodes[u].effectiveInert && flatNodes[u].el.isSelectionGroup
        if isGroup, let span = virtualSpanUnder(groupPath: flatNodes[u].path) {
            selectSpanEnds(first: span.first, last: span.last)
            return true
        }
        if isGroup {
            let texts = selectionGroupTexts(u)
            guard let f = texts.first.flatMap(mountedSelectionEnd), let l = texts.last.flatMap(mountedSelectionEnd) else { return false }
            selectSpanEnds(first: f, last: l)
        } else {
            guard let e = mountedSelectionEnd(u) else { return false }
            selectSpanEnds(first: e, last: e)
        }
        return true
    }

    /// The first and last selectable text of selection group `gp` when it holds a virtual list,
    /// building unmounted rows at either end (`Runtime::virtual_span_under`).
    func virtualSpanUnder(groupPath gp: String) -> (first: SelectionEndRef, last: SelectionEndRef)? {
        guard let root = liveNode(gp) else { return nil }
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
        func member(_ j: Int) -> String? { selectionMember(j, group: gp) ? flatNodes[j].path : nil }
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
        var first: String? = nil
        for k in root..<ln where inside(k) {
            if let m = member(k) { first = m; break }
        }
        if first == nil {
            for r in 0..<src.keys.count {
                if let nodes = rowNodes(r) {
                    if let m = nodes.lazy.compactMap(member).first { first = m; break }
                } else if let t = offscreenRowSelectables(listPath: listPath, src: src, row: r).first(where: { $0.group == gp }) {
                    first = t.path
                    break
                }
            }
        }
        guard let first else { return nil }

        // 2. The last selectable text under the group.
        var last: String? = nil
        var after = listEnd + 1
        while after < flatNodes.count, inside(after) {
            if let m = member(after) { last = m }
            after += 1
        }
        if last == nil {
            for r in (0..<src.keys.count).reversed() {
                if let nodes = rowNodes(r) {
                    if let m = nodes.reversed().lazy.compactMap(member).first { last = m; break }
                } else if let t = offscreenRowSelectables(listPath: listPath, src: src, row: r).last(where: { $0.group == gp }) {
                    last = t.path
                    break
                }
            }
        }
        guard let f = resolveSelectionEnd(path: first, end: nil),
              let l = resolveSelectionEnd(path: last ?? first, end: nil) else { return nil }
        return (f, l)
    }

    /// Selects from the start of `first` to the end of `last`, mounted or not
    /// (`Runtime::select_span_ends`), then seals it (`phase::Event::Select`).
    func selectSpanEnds(first: SelectionEndRef, last: SelectionEndRef) {
        let hasFar = first != last
        let end = hasFar ? last.text.utf8.count : first.text.utf8.count
        let origin = hasFar ? (0, 0) : (0, end)
        let far: SelectionFar? = hasFar
            ? SelectionFar(path: last.path, content: last.text, end: virtualEnd(forPath: last.path, offset: end))
            : nil
        selectionState.isDraggingSelection = false
        selectionState.coordinator.phase.place(ActiveSelection(
            path: first.path,
            content: first.text,
            anchor: 0,
            focus: end,
            origin: origin,
            far: far,
            anchorEnd: virtualEnd(forPath: first.path, offset: 0)
        ))
        sealBetween()
    }
}
