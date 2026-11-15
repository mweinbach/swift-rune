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

    /// The end's element path, as the mounted tree names it.
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

internal extension Runtime {
    // MARK: - Ends (`virtual/selection.rs` `resolve_end`, `tree_order`, `virtual_end_of`)

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

    /// Resolves the selectable text at `path`: mounted, or built from its unmounted virtual row.
    func resolveSelectionEnd(path: String) -> SelectionEndRef? {
        if let idx = resolvedNodeIndex(forPath: path), let text = selectableNodeText(flatNodes[idx]) {
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
        guard let info = resolveVirtualEndpointInfo(forPath: path) else { return nil }
        return SelectionEndRef(
            path: info.snapshot.path,
            text: info.snapshot.text,
            mountedIdx: nil,
            listIdx: info.listIdx,
            rowIndex: info.rowIndex,
            orderInRow: info.orderInRow,
            groupPath: info.rowGroupPath ?? selectionGroupPath(atOrAbove: info.listIdx)
        )
    }

    /// Canonical pre-order key of an end (`Runtime::tree_order`).
    func selectionTreeOrder(of end: SelectionEndRef) -> VirtualTreeOrder {
        if let idx = end.mountedIdx { return selectionTreeOrder(mountedIdx: idx) }
        return VirtualTreeOrder(slot: (end.listIdx ?? 0) * 2 + 1, row: end.rowIndex, sub: end.orderInRow)
    }

    /// Virtual-list row identity of the text at `path`, if it lies inside a virtual list
    /// (`Runtime::virtual_end_of`).
    func virtualEnd(forPath path: String, offset: Int) -> VirtualEnd? {
        for (listPath, src) in virtualSelectionSources {
            guard let listIdx = nodeByPath[listPath], listIdx < flatNodes.count, !flatNodes[listIdx].effectiveInert,
                  let (rowIdx, rowSeg) = virtualRowIndex(forPath: path, in: src) else {
                continue
            }
            let rowPath = "\(listPath)/\(rowSeg)"
            let rel = path == rowPath ? "" : String(path.dropFirst(rowPath.count + 1))
            return VirtualEnd(listPath: listPath, rowKey: src.keys[rowIdx], rowIndex: rowIdx, relPath: rel, offset: offset)
        }
        return nil
    }

    /// The text holding the selection's anchor while it still reads what the selection
    /// selected (`Runtime::selection_holder_end`).
    func selectionHolderEnd() -> SelectionEndRef? {
        guard let sel = selectionState.coordinator.phase.selection,
              let h = resolveSelectionEnd(path: sel.path) else { return nil }
        let upto: Int
        if let far = sel.far {
            if let f = resolveSelectionEnd(path: far.path), selectionTreeOrder(of: f) > selectionTreeOrder(of: h) {
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
        guard let f = resolveSelectionEnd(path: far.path) else { return nil }
        let upto = selectionTreeOrder(of: f) > selectionTreeOrder(of: holder) ? sel.focus : far.content.utf8.count
        let sameGroup = holder.groupPath != nil && f.groupPath == holder.groupPath
        return (sameGroup && SelectionMath.kept(then: far.content, now: f.text, upto: upto)) ? f : nil
    }

    // MARK: - Pins and the rows between (`sync_selection_pins`, `seal_between`, `between_matches`)

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
            for (lp, src) in virtualSelectionSources.sorted(by: { $0.key < $1.key }) where !src.keys.isEmpty {
                guard let ln = nodeByPath[lp] else { continue }
                let listOrd = VirtualTreeOrder(slot: ln * 2 + 1, row: 0, sub: 0)
                if firstOrd < listOrd && lastOrd > listOrd { return (lp, 0, src.keys.count - 1) }
            }
            return nil
        }
    }

    /// A hash of mounted row `rowKey`'s texts in group `groupPath`, their paths and content
    /// (`Runtime::mounted_row_hash`).
    func mountedRowHash(listPath: String, rowKey: String, groupPath: String) -> UInt64? {
        let rowPath = "\(listPath)/@\(rowKey)"
        guard let rowIdx = nodeByPath[rowPath], rowIdx < flatNodes.count else { return nil }
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211
        func mix(_ s: String) {
            for byte in s.utf8 {
                hash ^= UInt64(byte)
                hash &*= prime
            }
            hash ^= 0xFF
            hash &*= prime
        }
        let prefix = rowPath + "/"
        var j = rowIdx
        while j < flatNodes.count, j == rowIdx || flatNodes[j].path.hasPrefix(prefix) {
            if let text = selectableNodeText(flatNodes[j]), selectionGroupPath(ofMounted: j) == groupPath {
                mix(flatNodes[j].path)
                mix(text)
            }
            j += 1
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

    /// The selection changed shape: re-pin its ends and hash the mounted rows between them
    /// (`Runtime::seal_between`). The map is cleared in place, keeping its buckets.
    func sealBetween() {
        syncSelectionPins()
        selectionState.mountedBetween.removeAll(keepingCapacity: true)
        guard let h = selectionHolderEnd(), let f = focusHolderEnd(h),
              let (listPath, groupPath, keys) = mountedRowsBetween(h, f) else { return }
        for key in keys {
            if let hash = mountedRowHash(listPath: listPath, rowKey: key, groupPath: groupPath) {
                selectionState.mountedBetween[key] = hash
            }
        }
    }

    /// After a commit: whether every mounted row between the ends still reads what it read when
    /// it was hashed, hashing the rows mounted since (`Runtime::between_matches`).
    func mountedBetweenMatches() -> Bool {
        guard selectionState.coordinator.phase.selection?.far != nil,
              let h = selectionHolderEnd(), let f = focusHolderEnd(h),
              let (listPath, groupPath, keys) = mountedRowsBetween(h, f) else { return true }
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
}
