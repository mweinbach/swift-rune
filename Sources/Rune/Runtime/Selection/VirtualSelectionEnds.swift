import Foundation

/// Identity of a selection endpoint inside a virtual list: its list, the row's key and index, the
/// element path within the row, and the text offset (`crates/rune/src/runtime/virtual/selection.rs`
/// `VirtualEnd`).
public struct VirtualEnd: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var listPath: String
    public var rowKey: String
    public var rowIndex: Int
    public var relPath: String
    public var offset: Int

    public init(listPath: String, rowKey: String, rowIndex: Int, relPath: String, offset: Int) {
        self.listPath = listPath
        self.rowKey = rowKey
        self.rowIndex = rowIndex
        self.relPath = relPath
        self.offset = offset
    }

    /// The end's element path, as the mounted tree names it (`VirtualEnd::full_path`).
    public func fullPath() -> String {
        relPath.isEmpty ? "\(listPath)/@\(rowKey)" : "\(listPath)/@\(rowKey)/\(relPath)"
    }

    public var description: String { "(\(listPath), \(rowKey), \(rowIndex), \(relPath), \(offset))" }
}

/// A resolved selection end: a mounted text, or a text of a virtual row that isn't mounted
/// (`virtual/selection.rs` `EndRef`), with what the runtime reads off it.
internal struct SelectionEndRef: Equatable {
    var path: String
    var text: String
    var mountedIdx: Int?
    var listIdx: Int?
    var rowIndex: Int
    var orderInRow: Int
    var groupPath: String?
}

/// A selectable text of a virtual row built on demand (`pins.rs` `OffscreenText`).
internal struct OffscreenSelectable {
    var path: String
    var relPath: String
    var text: String
    var group: String?
    var orderInRow: Int
}

internal extension Runtime {
    // MARK: - Nodes (`group_of`, `member`, `allowed`, `subtree_exiting`)

    /// The nearest selection group at or above mounted node `idx`, by path.
    func selectionGroupPath(atOrAbove idx: Int) -> String? {
        var cur: Int? = idx
        while let i = cur, i < flatNodes.count {
            let n = flatNodes[i]
            if !n.effectiveInert && n.el.isSelectionGroup { return n.path }
            cur = n.parentIndex
        }
        return nil
    }

    /// The selection group holding mounted text `idx` (`Runtime::group_of`), by path.
    func selectionGroupPath(ofMounted idx: Int) -> String? {
        guard idx < flatNodes.count, let p = flatNodes[idx].parentIndex else { return nil }
        return selectionGroupPath(atOrAbove: p)
    }

    /// Node `idx` or an ancestor is leaving (`Runtime::subtree_exiting`).
    func selectionSubtreeExiting(_ idx: Int) -> Bool {
        var cur: Int? = idx
        while let i = cur, flatNodes.indices.contains(i) {
            if case .exiting = scene.phase(flatNodes[i].nodeId) { return true }
            cur = flatNodes[i].parentIndex
        }
        return false
    }

    /// Not inert, and inside the open modal if there is one (`Runtime::allowed`).
    func selectionAllowed(_ idx: Int) -> Bool {
        guard idx < flatNodes.count else { return false }
        let n = flatNodes[idx]
        return !n.effectiveInert && (activeModalPath == nil || modalMemberPaths.contains(n.path))
    }

    /// A selectable text that's not leaving and is allowed (`is_selectable && !subtree_exiting && allowed`).
    func selectableLive(_ idx: Int) -> Bool {
        idx < flatNodes.count && selectableNodeText(flatNodes[idx]) != nil && !selectionSubtreeExiting(idx) && selectionAllowed(idx)
    }

    /// Text `j` belongs to group `g` and can be selected (`Runtime::member`).
    func selectionMember(_ j: Int, group g: String) -> Bool {
        selectableLive(j) && selectionGroupPath(ofMounted: j) == g
    }

    // MARK: - Virtual rows

    /// The virtual list nearest above `path` (`virtual_end_of`'s walk up to the list).
    func nearestVirtualList(forPath path: String) -> (listPath: String, src: VirtualSelectionSource)? {
        var best: (String, VirtualSelectionSource)? = nil
        for (listPath, src) in virtualSelectionSources where path.hasPrefix(listPath + "/") {
            if best.map({ listPath.count > $0.0.count }) ?? true { best = (listPath, src) }
        }
        return best
    }

    /// The list at `listPath` is live and not inert (`Runtime::virtual_list_allowed`).
    func virtualListAllowed(_ listPath: String) -> Int? {
        guard let listIdx = nodeByPath[listPath], listIdx < flatNodes.count, !flatNodes[listIdx].effectiveInert else { return nil }
        return listIdx
    }

    /// The selectable texts of row `r` of list `listPath`, built on demand, with their groups and
    /// order in the row (`collect_virtual_row_selection`).
    func offscreenRowSelectables(listPath: String, src: VirtualSelectionSource, row r: Int, segment: String? = nil) -> [OffscreenSelectable] {
        guard r >= 0, r < src.keys.count, let listIdx = nodeByPath[listPath], listIdx < flatNodes.count else { return [] }
        let seg = segment ?? "@\(src.keys[r])"
        var rowSnaps: [SelectableNodeSnapshot] = []
        collectOffscreenRowSnapshots(
            source: src,
            rowIndex: r,
            rowSegment: seg,
            parentInert: flatNodes[listIdx].effectiveInert,
            baseY: 0,
            into: &rowSnaps
        )
        let rowPath = "\(listPath)/\(seg)"
        let listGroup = selectionGroupPath(atOrAbove: listIdx)
        var byPath: [String: Int] = [:]
        for (k, s) in rowSnaps.enumerated() { byPath[s.path] = k }
        var out: [OffscreenSelectable] = []
        for (k, snap) in rowSnaps.enumerated() where snap.isSelectable && !snap.text.isEmpty {
            var group = listGroup
            var p = snap.parentPath
            while let pp = p, let i = byPath[pp] {
                if rowSnaps[i].isSelectionGroup { group = rowSnaps[i].path; break }
                p = rowSnaps[i].parentPath
            }
            let rel = snap.path == rowPath ? "" : String(snap.path.dropFirst(rowPath.count + 1))
            out.append(OffscreenSelectable(path: snap.path, relPath: rel, text: snap.text, group: group, orderInRow: k))
        }
        return out
    }

    // MARK: - Ends (`resolve_end`, `resolve_virtual_end`, `tree_order`, `virtual_end_of`)

    func mountedSelectionEnd(_ idx: Int) -> SelectionEndRef? {
        guard idx < flatNodes.count, let text = selectableNodeText(flatNodes[idx]) else { return nil }
        return SelectionEndRef(
            path: flatNodes[idx].path,
            text: text,
            mountedIdx: idx,
            listIdx: nil,
            rowIndex: 0,
            orderInRow: 0,
            groupPath: selectionGroupPath(ofMounted: idx)
        )
    }

    private func offscreenSelectionEnd(_ t: OffscreenSelectable, listIdx: Int, row: Int) -> SelectionEndRef {
        SelectionEndRef(path: t.path, text: t.text, mountedIdx: nil, listIdx: listIdx, rowIndex: row, orderInRow: t.orderInRow, groupPath: t.group)
    }

    /// Resolves an end by its row identity: the live text when its row is mounted, else its text
    /// in the row built on demand (`Runtime::resolve_virtual_end`).
    func resolveVirtualEnd(_ end: VirtualEnd) -> SelectionEndRef? {
        guard let src = virtualSelectionSources[end.listPath], let listIdx = virtualListAllowed(end.listPath),
              let r = src.keys.firstIndex(of: end.rowKey) else { return nil }
        let seg = "@\(end.rowKey)"
        if nodeByPath["\(end.listPath)/\(seg)"] != nil {
            return nodeByPath[end.fullPath()].flatMap(mountedSelectionEnd)
        }
        return offscreenRowSelectables(listPath: end.listPath, src: src, row: r, segment: seg)
            .first { $0.relPath == end.relPath }
            .map { offscreenSelectionEnd($0, listIdx: listIdx, row: r) }
    }

    /// Resolves an end by its virtual row identity first, else the live text at `path`, else the
    /// text at `path` in an unmounted row (`Runtime::resolve_end`).
    func resolveSelectionEnd(path: String, end: VirtualEnd?) -> SelectionEndRef? {
        if let end, let r = resolveVirtualEnd(end) { return r }
        if let idx = nodeByPath[path], let m = mountedSelectionEnd(idx) { return m }
        guard let (listPath, src) = nearestVirtualList(forPath: path), let listIdx = virtualListAllowed(listPath),
              let (r, seg) = virtualRowIndex(forPath: path, in: src),
              nodeByPath["\(listPath)/\(seg)"] == nil else { return nil }
        return offscreenRowSelectables(listPath: listPath, src: src, row: r, segment: seg)
            .first { $0.path == path }
            .map { offscreenSelectionEnd($0, listIdx: listIdx, row: r) }
    }

    /// Canonical pre-order key of an end (`Runtime::tree_order`).
    func selectionTreeOrder(of end: SelectionEndRef) -> VirtualTreeOrder {
        if let idx = end.mountedIdx { return selectionTreeOrder(mountedIdx: idx) }
        return VirtualTreeOrder(slot: (end.listIdx ?? 0) * 2 + 1, row: end.rowIndex, sub: end.orderInRow)
    }

    /// Virtual-list row identity of the text at `path`, in the virtual list nearest above it
    /// (`Runtime::virtual_end_of`).
    func virtualEnd(forPath path: String, offset: Int) -> VirtualEnd? {
        guard let (listPath, src) = nearestVirtualList(forPath: path), virtualListAllowed(listPath) != nil,
              let (rowIdx, rowSeg) = virtualRowIndex(forPath: path, in: src) else { return nil }
        let rowPath = "\(listPath)/\(rowSeg)"
        let rel = path == rowPath ? "" : String(path.dropFirst(rowPath.count + 1))
        return VirtualEnd(listPath: listPath, rowKey: src.keys[rowIdx], rowIndex: rowIdx, relPath: rel, offset: offset)
    }

    /// The text holding the selection's anchor while it still reads what the selection
    /// selected (`Runtime::selection_holder_end`).
    func selectionHolderEnd() -> SelectionEndRef? {
        guard let sel = selectionState.coordinator.phase.selection,
              let h = resolveSelectionEnd(path: sel.path, end: sel.anchorEnd) else { return nil }
        let upto: Int
        if let far = sel.far {
            if let f = resolveSelectionEnd(path: far.path, end: far.end), selectionTreeOrder(of: f) > selectionTreeOrder(of: h) {
                upto = sel.content.utf8.count
            } else {
                upto = max(sel.anchor, sel.originEnd)
            }
        } else {
            upto = max(sel.anchor, sel.focus, sel.originEnd)
        }
        return SelectionMath.kept(then: sel.content, now: h.text, upto: upto) ? h : nil
    }

    /// The text holding the selection's focus, given its holder (`Runtime::focus_holder_end`).
    func focusHolderEnd(_ holder: SelectionEndRef) -> SelectionEndRef? {
        guard let sel = selectionState.coordinator.phase.selection else { return nil }
        guard let far = sel.far else { return holder }
        guard let f = resolveSelectionEnd(path: far.path, end: far.end) else { return nil }
        let upto = selectionTreeOrder(of: f) > selectionTreeOrder(of: holder) ? sel.focus : far.content.utf8.count
        let sameGroup = holder.groupPath != nil && f.groupPath == holder.groupPath
        return (sameGroup && SelectionMath.kept(then: far.content, now: f.text, upto: upto)) ? f : nil
    }

    // MARK: - Pins and the texts between (`sync_selection_pins`, `between_hash_ends`, `seal_between`)

    /// Writes `sel` back into the phase, keeping it placed or dragging.
    func replaceActiveSelection(_ sel: ActiveSelection) {
        switch selectionState.coordinator.phase {
        case .empty: break
        case .placed: selectionState.coordinator.phase = .placed(sel)
        case .dragging(_, let unit): selectionState.coordinator.phase = .dragging(sel, unit: unit)
        }
    }

    /// Updates the selection's `anchorEnd` and far `end` (`Runtime::sync_selection_pins`). With
    /// nothing selected nothing lies between its ends.
    func syncSelectionPins() {
        guard var sel = selectionState.coordinator.phase.selection else {
            selectionState.mountedBetween.removeAll(keepingCapacity: true)
            return
        }
        guard let h = selectionHolderEnd() else { return }
        let focusEnd: VirtualEnd? = sel.far == nil
            ? nil
            : focusHolderEnd(h).flatMap { virtualEnd(forPath: $0.path, offset: sel.focus) }
        sel.anchorEnd = virtualEnd(forPath: h.path, offset: sel.anchor)
        if sel.far != nil { sel.far?.end = focusEnd }
        if sel != selectionState.coordinator.phase.selection { replaceActiveSelection(sel) }
    }

    /// The virtual list `h` and `f` span rows of, with the first and last row of the span
    /// (`Runtime::is_cross_row_virtual`).
    func crossRowVirtualSpan(_ h: SelectionEndRef, _ f: SelectionEndRef) -> (listPath: String, r0: Int, r1: Int)? {
        let (first, last) = selectionTreeOrder(of: h) <= selectionTreeOrder(of: f) ? (h, f) : (f, h)
        let va = virtualEnd(forPath: first.path, offset: 0)
        let vb = virtualEnd(forPath: last.path, offset: 0)
        switch (va, vb) {
        case let (.some(a), .some(b)):
            guard a.listPath == b.listPath, a.rowIndex != b.rowIndex else { return nil }
            return (a.listPath, min(a.rowIndex, b.rowIndex), max(a.rowIndex, b.rowIndex))
        case let (.some(a), nil):
            guard let src = virtualSelectionSources[a.listPath], !src.keys.isEmpty else { return nil }
            return (a.listPath, a.rowIndex, src.keys.count - 1)
        case let (nil, .some(b)):
            return (b.listPath, 0, b.rowIndex)
        case (nil, nil):
            let (firstOrd, lastOrd) = (selectionTreeOrder(of: first), selectionTreeOrder(of: last))
            for (lp, src) in virtualSelectionSources where !src.keys.isEmpty {
                guard let ln = nodeByPath[lp] else { continue }
                let listOrd = VirtualTreeOrder(slot: ln * 2 + 1, row: 0, sub: 0)
                if firstOrd < listOrd && lastOrd > listOrd { return (lp, 0, src.keys.count - 1) }
            }
            return nil
        }
    }

    private static var hashBasis: UInt64 { 14_695_981_039_346_656_037 }

    private static func mix(_ hash: inout UInt64, _ s: String) {
        let prime: UInt64 = 1_099_511_628_211
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        hash ^= 0xFF
        hash &*= prime
    }

    /// A hash of mounted row `rowKey`'s texts in group `groupPath`, their paths and content
    /// (`Runtime::mounted_row_hash`).
    func mountedRowHash(listPath: String, rowKey: String, groupPath: String) -> UInt64? {
        let rowPath = "\(listPath)/@\(rowKey)"
        guard let rowIdx = nodeByPath[rowPath], rowIdx < flatNodes.count else { return nil }
        var hash = Self.hashBasis
        let prefix = rowPath + "/"
        var j = rowIdx
        while j < flatNodes.count, j == rowIdx || flatNodes[j].path.hasPrefix(prefix) {
            if selectionMember(j, group: groupPath), let text = selectableNodeText(flatNodes[j]) {
                Self.mix(&hash, flatNodes[j].path)
                Self.mix(&hash, text)
            }
            j += 1
        }
        return hash
    }

    /// A hash of the texts strictly between the ends `h` and `f` in their group, their paths and
    /// content; across virtual rows, the keys of the rows the selection spans and the mounted
    /// texts of the group outside the list (`Runtime::between_hash_ends`).
    func betweenHashEnds(_ h: SelectionEndRef, _ f: SelectionEndRef) -> UInt64 {
        var hash = Self.hashBasis
        guard let g = h.groupPath, h != f else { return hash }
        let (first, last) = selectionTreeOrder(of: h) < selectionTreeOrder(of: f) ? (h, f) : (f, h)
        if let (listPath, r0, r1) = crossRowVirtualSpan(first, last) {
            if let gi = nodeByPath[g], nodeByPath[listPath] != nil {
                let (firstOrd, lastOrd) = (selectionTreeOrder(of: first), selectionTreeOrder(of: last))
                let listPrefix = listPath + "/"
                var j = gi + 1
                while j < flatNodes.count {
                    let p = flatNodes[j].path
                    if p != listPath && !p.hasPrefix(listPrefix) && selectionMember(j, group: g) {
                        let ord = selectionTreeOrder(mountedIdx: j)
                        if ord > firstOrd && ord < lastOrd, let text = selectableNodeText(flatNodes[j]) {
                            Self.mix(&hash, p)
                            Self.mix(&hash, text)
                        }
                    }
                    j += 1
                }
            }
            if let src = virtualSelectionSources[listPath], r1 < src.keys.count {
                for key in src.keys[r0...r1] { Self.mix(&hash, key) }
            }
            return hash
        }
        switch (first.mountedIdx, last.mountedIdx) {
        case let (.some(i0), .some(i1)):
            if let g0 = selectionGroupPath(ofMounted: i0), i1 > i0 + 1 {
                for j in (i0 + 1)..<i1 where selectionMember(j, group: g0) {
                    if let text = selectableNodeText(flatNodes[j]) {
                        Self.mix(&hash, flatNodes[j].path)
                        Self.mix(&hash, text)
                    }
                }
            }
        case (nil, nil):
            guard let l0 = first.listIdx, l0 == last.listIdx, l0 < flatNodes.count else { break }
            let listPath = flatNodes[l0].path
            guard let src = virtualSelectionSources[listPath] else { break }
            for t in offscreenRowSelectables(listPath: listPath, src: src, row: first.rowIndex)
            where t.orderInRow > first.orderInRow && t.orderInRow < last.orderInRow && t.group == g {
                Self.mix(&hash, t.path)
                Self.mix(&hash, t.text)
            }
        default:
            break
        }
        return hash
    }

    /// The mounted rows strictly between the ends `h` and `f` of a selection across virtual rows.
    private func mountedRowsBetween(_ h: SelectionEndRef, _ f: SelectionEndRef) -> (listPath: String, groupPath: String, keys: [String])? {
        guard let groupPath = h.groupPath, let (listPath, r0, r1) = crossRowVirtualSpan(h, f),
              let src = virtualSelectionSources[listPath] else { return nil }
        let range = virtualLists[listPath]?.lastMountedRange ?? src.mounted
        guard r1 > r0 + 1 else { return (listPath, groupPath, []) }
        let keys = ((r0 + 1)..<r1).filter { range.contains($0) && $0 < src.keys.count }.map { src.keys[$0] }
        return (listPath, groupPath, keys)
    }

    /// Remembers the unit of the text holding the selection (`Runtime::remember_pick`).
    func rememberPick() {
        guard let h = selectionHolderEnd() else { return }
        selectionState.coordinator.pick.noteClick(groupPath: h.groupPath ?? h.path)
    }

    /// The selection changed shape: re-pin its ends, hash the texts between them and the mounted
    /// rows between them (the map cleared in place, keeping its buckets), and remember where it
    /// is (`Runtime::seal_between`).
    func sealBetween() {
        syncSelectionPins()
        selectionState.mountedBetween.removeAll(keepingCapacity: true)
        guard let h = selectionHolderEnd(), let f = focusHolderEnd(h) else {
            if var sel = selectionState.coordinator.phase.selection, sel.betweenHash != 0 {
                sel.betweenHash = 0
                replaceActiveSelection(sel)
            }
            rememberPick()
            return
        }
        let between = betweenHashEnds(h, f)
        if var sel = selectionState.coordinator.phase.selection, sel.betweenHash != between {
            sel.betweenHash = between
            replaceActiveSelection(sel)
        }
        if let (listPath, groupPath, keys) = mountedRowsBetween(h, f) {
            for key in keys {
                if let hash = mountedRowHash(listPath: listPath, rowKey: key, groupPath: groupPath) {
                    selectionState.mountedBetween[key] = hash
                }
            }
        }
        rememberPick()
    }

    /// After a commit: whether the texts between the ends still hash as sealed, and every
    /// mounted row between them still reads what it read when hashed, hashing the rows mounted
    /// since (`Runtime::between_matches`).
    func betweenMatches(_ h: SelectionEndRef, _ f: SelectionEndRef) -> Bool {
        guard let sel = selectionState.coordinator.phase.selection, sel.far != nil else { return true }
        if betweenHashEnds(h, f) != sel.betweenHash { return false }
        guard let (listPath, groupPath, keys) = mountedRowsBetween(h, f) else { return true }
        for key in keys {
            guard let hash = mountedRowHash(listPath: listPath, rowKey: key, groupPath: groupPath) else { continue }
            if let prev = selectionState.mountedBetween[key] {
                if prev != hash { return false }
            } else {
                selectionState.mountedBetween[key] = hash
            }
        }
        return true
    }

    // MARK: - Prune (`Runtime::prune_text_selection`)

    /// A unique live selectable text at `path`'s keyed identity when an unkeyed ancestor moved,
    /// still reading `content` up to `upto` (`Runtime::rebound`).
    func reboundSelectable(path: String, content: String, upto: Int) -> Int? {
        var hit: Int? = nil
        for i in flatNodes.indices where SelectionMath.sameKeyedPath(path, flatNodes[i].path) && selectableLive(i) {
            guard let text = selectableNodeText(flatNodes[i]), SelectionMath.kept(then: content, now: text, upto: upto) else { continue }
            if hit != nil { return nil }
            hit = i
        }
        return hit
    }

    /// Clears the selection (`Runtime::clear_text_selection`, its `SyncPins` effect included).
    func clearTextSelectionPhase() {
        selectionState.coordinator.phase.clear()
        selectionState.isDraggingSelection = false
        syncSelectionPins()
    }

    /// After a commit: drop a selection whose texts went away, stopped being selectable or
    /// changed what it selected, or whose texts between its ends changed; follow texts whose
    /// unkeyed ancestors moved (`Runtime::prune_text_selection`).
    func pruneTextSelection() {
        guard let sel0 = selectionState.coordinator.phase.selection else { return }
        var rebind = false
        if selectionHolderEnd() == nil, sel0.anchorEnd == nil {
            let upto = max(sel0.anchor, sel0.focus, sel0.originEnd)
            if let i = reboundSelectable(path: sel0.path, content: sel0.content, upto: upto) {
                var s = sel0
                s.path = flatNodes[i].path
                replaceActiveSelection(s)
                rebind = true
            }
        }
        if let h = selectionHolderEnd(), focusHolderEnd(h) == nil,
           let sel = selectionState.coordinator.phase.selection,
           let far = sel.far, far.end == nil,
           let j = reboundSelectable(path: far.path, content: far.content, upto: sel.focus) {
            var s = sel
            s.far?.path = flatNodes[j].path
            replaceActiveSelection(s)
            rebind = true
        }
        if rebind, let h = selectionHolderEnd(), let f = focusHolderEnd(h), var s = selectionState.coordinator.phase.selection {
            s.betweenHash = betweenHashEnds(h, f)
            replaceActiveSelection(s)
        }
        guard let h = selectionHolderEnd(), let f = focusHolderEnd(h) else {
            clearTextSelectionPhase()
            return
        }
        if !betweenMatches(h, f) {
            clearTextSelectionPhase()
            return
        }
        if var s = selectionState.coordinator.phase.selection {
            s.path = h.path
            s.content = h.text
            if f != h, s.far != nil {
                s.far?.path = f.path
                s.far?.content = f.text
            }
            if s != selectionState.coordinator.phase.selection { replaceActiveSelection(s) }
        }
        syncSelectionPins()
    }
}
