import Foundation

/// Copying and reading a selection that reaches virtual rows that aren't mounted: their rows built
/// on demand, bounded by `VirtualCopyLimits` (`crates/rune/src/runtime/virtual/selection_collect.rs`
/// `copy_virtual_text` / `collect_virtual_selection`).
internal extension Runtime {
    /// Which way the selection runs: focus before anchor (`toolbar.rs` `Runtime::selection_backward`).
    func virtualSelectionBackward() -> Bool {
        guard let h = selectionHolderEnd(), let f = focusHolderEnd(h) else { return false }
        if f != h { return selectionTreeOrder(of: f) < selectionTreeOrder(of: h) }
        guard let sel = selectionState.coordinator.phase.selection else { return false }
        return sel.focus < sel.anchor
    }

    /// `path` relative to `base`'s: empty for `base` itself, else the rest past `base/`, else whole.
    private func pathRelative(_ path: String, to base: String?) -> String {
        guard let base else { return path }
        if path == base { return "" }
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }

    /// A piece of a text as copying takes it: `range` of `content`, its uncopied spans left out
    /// (`selectable.rs` `selected_piece`, `virtual/selection.rs` `offscreen_piece`).
    private func selectionPiece(path: String, key: String?, content: String, uncopied: [Range<Int>], range: Range<Int>, base: String?) -> SelectedText {
        let len = content.utf8.count
        let full = uncopied.isEmpty ? (0, len) : SelectionMath.trimUncopied(uncopied, range: (0, len))
        let whole = !range.isEmpty && len > 0 && range.lowerBound <= full.0 && range.upperBound >= full.1
        return SelectedText(
            path: pathRelative(path, to: base),
            key: key,
            range: range,
            len: len,
            whole: whole,
            text: CopyJoin.copySlice(in: content, range: range, uncopied: uncopied),
            content: content
        )
    }

    /// Mounted text `j` as a piece with `range` selected (`Runtime::selected_piece`).
    private func mountedPiece(_ j: Int, _ range: Range<Int>, base: String?) -> SelectedText {
        let n = flatNodes[j]
        return selectionPiece(path: n.path, key: n.key, content: selectableNodeText(n) ?? "", uncopied: n.el.uncopiedRanges, range: range, base: base)
    }

    /// Offscreen text `t` as a piece with `range` selected (`offscreen_piece`).
    private func offscreenPiece(_ t: OffscreenSelectable, _ range: Range<Int>, base: String?) -> SelectedText {
        selectionPiece(path: t.path, key: t.key, content: t.text, uncopied: t.uncopied, range: range, base: base)
    }

    /// Node `j` is `a` or lies under it.
    private func atOrUnder(_ j: Int, _ a: Int) -> Bool {
        var cur: Int? = j
        while let c = cur, c < flatNodes.count {
            if c == a { return true }
            cur = flatNodes[c].parentIndex
        }
        return false
    }

    /// Where mounted text `j` was drawn, as copying reads it to tell cells side by side.
    private func copyBox(_ j: Int) -> MotionRect {
        presentedRectByPath[flatNodes[j].path] ?? flatNodes[j].targetRect
    }

    /// What copying a selection that reaches unmounted virtual rows puts on the clipboard: the
    /// nearest `El.selectionCopy` around both ends says, else the text as collected
    /// (`Runtime::copy_virtual_text`).
    func copyVirtualText() -> String? {
        guard let h = selectionHolderEnd(), let f = focusHolderEnd(h) else { return nil }
        // An offscreen end counts as its live list.
        guard let n0 = h.mountedIdx ?? h.listIdx, let n1 = f.mountedIdx ?? f.listIdx,
              n0 < flatNodes.count, n1 < flatNodes.count else { return nil }
        var provider: Int? = nil
        var cur: Int? = n0
        while let p = cur {
            let n = flatNodes[p]
            if !n.effectiveInert, n.el.hasSelectionCopyHandler, atOrUnder(n1, p) { provider = p; break }
            cur = n.parentIndex
        }
        if let p = provider {
            guard let sel = collectVirtualSelection(base: p) else { return nil }
            return flatNodes[p].el.invokeSelectionCopy(sel) ?? sel.text
        }
        return collectVirtualSelection(base: nil)?.text
    }

    /// The whole selection when it reaches offscreen or unbuilt rows, its texts' paths relative to
    /// `base`'s (`Runtime::collect_virtual_selection`): the group's mounted texts before the list,
    /// then the rows between the ends (mounted rows from the tree, the others built on demand, a
    /// pinned row from what it keeps), then the group's mounted texts after the list. Building
    /// stops past `VirtualCopyLimits.maxRows` unbuilt rows or `VirtualCopyLimits.maxBytes` of
    /// text, and the text collected so far is cut on a character boundary at the byte bound.
    func collectVirtualSelection(base: Int?) -> TextSelection? {
        guard let h = selectionHolderEnd(), let f = focusHolderEnd(h),
              let sel = selectionState.coordinator.phase.selection else { return nil }
        let basePath = base.flatMap { $0 < flatNodes.count ? flatNodes[$0].path : nil }
        let backward = virtualSelectionBackward()

        if h == f {
            let (a, b) = (min(sel.anchor, sel.focus), max(sel.anchor, sel.focus))
            guard a < b, b <= h.text.utf8.count else { return nil }
            let piece: SelectedText
            if let i = h.mountedIdx {
                piece = mountedPiece(i, a..<b, base: basePath)
            } else {
                guard let t = offscreenText(of: h) else { return nil }
                piece = offscreenPiece(t, a..<b, base: basePath)
            }
            return TextSelection(texts: [piece], text: piece.text, backward: backward)
        }

        let ((firstEnd, firstByte), (lastEnd, lastByte)) = selectionTreeOrder(of: h) < selectionTreeOrder(of: f)
            ? ((h, sel.anchor), (f, sel.focus))
            : ((f, sel.focus), (h, sel.anchor))
        let (firstOrd, lastOrd) = (selectionTreeOrder(of: firstEnd), selectionTreeOrder(of: lastEnd))
        guard let gPath = h.groupPath else { return nil }
        let cap = VirtualCopyLimits.maxBytes

        // Both ends in the same offscreen row (e.g. a row with its own `selection_group`).
        if firstEnd.mountedIdx == nil, lastEnd.mountedIdx == nil, let l0 = firstEnd.listIdx, l0 == lastEnd.listIdx,
           firstEnd.rowIndex == lastEnd.rowIndex, l0 < flatNodes.count,
           let src = virtualSelectionSources[flatNodes[l0].path] {
            var texts: [SelectedText] = []
            var out = CopyJoin.Builder()
            for t in offscreenRowSelectables(listPath: src.listPath, src: src, row: firstEnd.rowIndex) where t.group == gPath {
                let ord = VirtualTreeOrder(slot: l0 * 2 + 1, row: firstEnd.rowIndex, sub: t.orderInRow)
                if ord < firstOrd || ord > lastOrd { continue }
                let len = t.text.utf8.count
                let a = ord == firstOrd ? min(firstByte, len) : 0
                let b = ord == lastOrd ? min(lastByte, len) : len
                if a >= b { continue }
                let piece = offscreenPiece(t, a..<b, base: basePath)
                let hitCap = out.push(
                    piece.text,
                    fromStart: CopyJoin.fromStart(range: a..<b, len: len, uncopied: t.uncopied),
                    copyBreakBefore: t.copyBreakBefore, copyBreakAfter: t.copyBreakAfter, copyPrefix: t.copyPrefix,
                    beside: t.tabBefore, cap: cap
                )
                texts.append(piece)
                if hitCap { break }
            }
            let text = out.finish()
            return text.isEmpty ? nil : TextSelection(texts: texts, text: text, backward: backward)
        }

        // General group selection spanning a virtual list.
        let endList = virtualEnd(forPath: firstEnd.path, offset: 0)?.listPath ?? virtualEnd(forPath: lastEnd.path, offset: 0)?.listPath
        var listPathFound = endList
        if listPathFound == nil, let gi = liveNode(gPath) {
            let gPrefix = gPath + "/"
            var j = gi
            while j < flatNodes.count, j == gi || flatNodes[j].path.hasPrefix(gPrefix) {
                if virtualSelectionSources[flatNodes[j].path] != nil { listPathFound = flatNodes[j].path; break }
                j += 1
            }
        }
        guard let listPath = listPathFound, let listNode = liveNode(listPath),
              let src = virtualSelectionSources[listPath], let g = liveNode(gPath) else { return nil }

        var texts: [SelectedText] = []
        var out = CopyJoin.Builder()
        var unbuiltRows = 0
        var prevMounted: Int? = nil
        var hitCap = false

        func appendMounted(_ j: Int) -> Bool {
            let ord = selectionTreeOrder(mountedIdx: j)
            if ord < firstOrd || ord > lastOrd { return false }
            guard let content = selectableNodeText(flatNodes[j]) else { return false }
            let len = content.utf8.count
            let a = firstEnd.mountedIdx == j ? min(firstByte, len) : 0
            let b = lastEnd.mountedIdx == j ? min(lastByte, len) : len
            if a >= b { return false }
            let piece = mountedPiece(j, a..<b, base: basePath)
            let el = flatNodes[j].el
            let breaks = el.copyBreaksPair
            let beside = prevMounted.map { CopyJoin.beside(copyBox($0), copyBox(j)) } ?? false
            let capped = out.push(
                piece.text,
                fromStart: CopyJoin.fromStart(range: a..<b, len: len, uncopied: el.uncopiedRanges),
                copyBreakBefore: breaks.before, copyBreakAfter: breaks.after, copyPrefix: el.copyPrefixString,
                beside: beside, cap: cap
            )
            texts.append(piece)
            prevMounted = j
            return capped
        }

        // 1. Mounted group members before `listNode`.
        let gPrefix = flatNodes[g].path + "/"
        func insideG(_ j: Int) -> Bool { flatNodes[j].path.hasPrefix(gPrefix) }
        if g + 1 < listNode {
            for j in (g + 1)..<listNode where insideG(j) && selectionMember(j, group: gPath) {
                if appendMounted(j) { hitCap = true; break }
            }
        }

        // 2. Rows of the virtual list in `rowStart...rowEnd`.
        if !hitCap && !src.keys.isEmpty {
            let count = src.keys.count
            let rowStart = virtualEnd(forPath: firstEnd.path, offset: 0).flatMap { $0.listPath == listPath ? $0.rowIndex : nil } ?? 0
            let rowEnd = virtualEnd(forPath: lastEnd.path, offset: 0).flatMap { $0.listPath == listPath ? min($0.rowIndex, count - 1) : nil } ?? (count - 1)

            let listPrefix = listPath + "/"
            var listEnd = listNode
            while listEnd + 1 < flatNodes.count, flatNodes[listEnd + 1].path.hasPrefix(listPrefix) { listEnd += 1 }
            let pinned = virtualSelectionPinnedRows(listPath)

            if rowStart <= rowEnd {
                rows: for r in rowStart...rowEnd {
                    if src.mounted.contains(r) {
                        let rowPath = "\(listPath)/@\(src.keys[r])"
                        guard let rowNode = nodeByPath[rowPath], rowNode > listNode, rowNode <= listEnd,
                              flatNodes[rowNode].path == rowPath, flatNodes[rowNode].parentIndex == listNode else { continue }
                        let rowPrefix = rowPath + "/"
                        var j = rowNode
                        while j <= listEnd, j == rowNode || flatNodes[j].path.hasPrefix(rowPrefix) {
                            if selectionMember(j, group: gPath), appendMounted(j) { hitCap = true; break rows }
                            j += 1
                        }
                    } else {
                        prevMounted = nil
                        // A pinned row is read from what it keeps; any other is built, within the bounds.
                        if !pinned.contains(src.keys[r]) {
                            if unbuiltRows >= VirtualCopyLimits.maxRows || out.byteCount >= cap { hitCap = true; break rows }
                            unbuiltRows += 1
                        }
                        var firstInRow = true
                        for t in offscreenRowSelectables(listPath: listPath, src: src, row: r) where t.group == gPath {
                            let ord = VirtualTreeOrder(slot: listNode * 2 + 1, row: r, sub: t.orderInRow)
                            if ord < firstOrd || ord > lastOrd { continue }
                            let len = t.text.utf8.count
                            let a = ord == firstOrd ? min(firstByte, len) : 0
                            let b = ord == lastOrd ? min(lastByte, len) : len
                            if a >= b { continue }
                            let piece = offscreenPiece(t, a..<b, base: basePath)
                            let capped = out.push(
                                piece.text,
                                fromStart: CopyJoin.fromStart(range: a..<b, len: len, uncopied: t.uncopied),
                                copyBreakBefore: t.copyBreakBefore, copyBreakAfter: t.copyBreakAfter, copyPrefix: t.copyPrefix,
                                beside: !firstInRow && t.tabBefore, cap: cap
                            )
                            texts.append(piece)
                            firstInRow = false
                            if capped { hitCap = true; break rows }
                        }
                    }
                }
            }

            // 3. Mounted group members after the virtual list's subtree.
            if !hitCap {
                var j = listEnd + 1
                while j < flatNodes.count, insideG(j) {
                    if selectionMember(j, group: gPath), appendMounted(j) { break }
                    j += 1
                }
            }
        }

        let text = out.finish()
        return text.isEmpty ? nil : TextSelection(texts: texts, text: text, backward: backward)
    }

    /// The offscreen text an unmounted end names, from its row built on demand.
    private func offscreenText(of end: SelectionEndRef) -> OffscreenSelectable? {
        guard end.mountedIdx == nil, let l = end.listIdx, l < flatNodes.count,
              let src = virtualSelectionSources[flatNodes[l].path] else { return nil }
        return offscreenRowSelectables(listPath: src.listPath, src: src, row: end.rowIndex)
            .first { $0.orderInRow == end.orderInRow && $0.path == end.path }
    }
}
