import Foundation
import RuneMotion

internal enum SelectionEdgeScrollState: Equatable {
    case idle
    case running(attempt: EdgeScrollAttempt, scrollPath: String, last: Double, fromOffset: Double?, due: Double)
    /// This frame stepped `scrollPath`, whose extent was `max`; the next step is attempt `next`,
    /// or none when this one reached the end (`edge_scroll.rs::State::Laying`).
    case laying(next: EdgeScrollAttempt?, scrollPath: String, last: Double, fromOffset: Double?, max: Double)
    /// Held at an edge with nothing left to scroll that way (or whose last step moved nothing),
    /// when its extent was `max`; waits without a wake for that extent to change (`State::AtEnd`).
    case atEnd(scrollPath: String, max: Double)

    /// Stepping, or about to step (not idle, nor resting at an end).
    var isRunning: Bool {
        switch self {
        case .running, .laying: return true
        case .idle, .atEnd: return false
        }
    }

    var attempt: EdgeScrollAttempt? {
        switch self {
        case .idle, .atEnd: return nil
        case .running(let attempt, _, _, _, _): return attempt
        case .laying(let next, _, _, _, _): return next
        }
    }

    var scrollPath: String? {
        switch self {
        case .idle: return nil
        case .running(_, let p, _, _, _), .laying(_, let p, _, _, _), .atEnd(let p, _): return p
        }
    }

    mutating func stop() {
        self = .idle
    }
}

/// Runtime-owned state for `El.selectable` text selection, drag tracking, pending `Tx` actions,
/// per-path click runs, edge auto-scroll, and `onSelectionChange` release coalescing
/// (`Sources/Rune/Runtime/Selection/*`).
internal struct RuntimeSelectionState {
    var coordinator = SelectionCoordinator()
    var isDraggingSelection: Bool = false
    var dragStartPos: Vec2 = .zero
    var suppressedClickOnRelease: Bool = false
    var isDispatchingSelectionChanges: Bool = false
    var lastDispatchedDragging: Bool = false
    var pendingSelectTextRequest: (key: String, range: Range<Int>)? = nil
    var pendingSelectAllKey: String? = nil
    var lastClickPath: String? = nil
    var lastClickTime: Double = -10.0
    var lastClickPos: Vec2 = Vec2(-10000, -10000)
    var clickCount: Int = 0
    var edgeScrollSeq = EdgeScrollSeq()
    var edgeScroll: SelectionEdgeScrollState = .idle
    var lastCommittedMarkedTexts: [SelectionMark] = []
    var pendingFollowCaret: Bool = false
    /// Hashes of mounted rows strictly between the selection's anchor and focus in a virtual
    /// list (`phase.rs::TextSel::mounted_between`). A new selection clears it in place and keeps
    /// its buckets; with nothing selected it's empty.
    var mountedBetween: [String: UInt64] = [:]

    mutating func clearClicks() {
        lastClickPath = nil
        clickCount = 0
    }

    mutating func notePrimaryPress(path: String, at pos: Vec2, now: Double) -> Int {
        let dt = now - lastClickTime
        let dist = hypotf(pos.x - lastClickPos.x, pos.y - lastClickPos.y)
        if path == lastClickPath && dt <= 0.35 && dist <= 4.0 {
            clickCount += 1
        } else {
            clickCount = 1
        }
        lastClickPath = path
        lastClickTime = now
        lastClickPos = pos
        return min(3, max(1, clickCount))
    }
}

/// Optional ink override + local selection line rects returned to `buildRefScene` glyph emission.
internal struct SelectablePaintInk {
    var ink: Color
    var rects: [SIMD4<Float>]

    func color(for glyph: PositionedGlyph) -> Color? {
        let cx = glyph.rect.x + glyph.rect.z * 0.5
        let cy = glyph.rect.y + glyph.rect.w * 0.5
        for r in rects {
            if cx >= r.x - 0.5 && cx <= r.x + r.z + 0.5 && cy >= r.y - 0.5 && cy <= r.y + r.w + 0.5 {
                return ink
            }
        }
        return nil
    }
}

private struct SelectableBandBox {
    var idx: Int
    var rect: MotionRect
}

private struct SelectableBand {
    var top: Float
    var bottom: Float
    var range: Range<Int>
}

public extension Runtime {
    /// Current `TextSelection` snapshot across mounted `El.selectable` elements (`Runtime::selection`).
    func currentTextSelection() -> TextSelection? {
        guard selectionState.coordinator.phase.selection != nil else { return nil }
        return selectionState.coordinator.currentSelection(in: selectableSnapshotsWithVirtuals())
    }

    /// Plain joined text of the active `El.selectable` selection without `El.selectionCopy`
    /// overrides (`Runtime::selected_text`).
    func selectedText() -> String? {
        guard let text = currentTextSelection()?.text, !text.isEmpty else { return nil }
        return text
    }

    /// Clipboard string produced by copying the active `El.selectable` selection, honoring the
    /// nearest `El.selectionCopy` handler spanning the selection (`Runtime::copy_text`).
    func copySelectionText() -> String? {
        let snaps = selectableSnapshotsWithVirtuals()
        guard let sel = selectionState.coordinator.currentSelection(in: snaps),
              let firstSel = sel.texts.first,
              let lastSel = sel.texts.last else {
            return nil
        }
        let anchorListIndex: (String) -> Int? = { path in
            if let idx = self.nodeByPath[path] { return idx }
            for listPath in self.virtualSelectionSources.keys where path.hasPrefix(listPath + "/") {
                if let idx = self.nodeByPath[listPath] { return idx }
            }
            return nil
        }
        guard let firstIdx = anchorListIndex(firstSel.path),
              let lastIdx = anchorListIndex(lastSel.path) else {
            return sel.text.isEmpty ? nil : sel.text
        }
        let isDescendant: (Int, Int) -> Bool = { nodeIdx, ancestorIdx in
            var cur: Int? = nodeIdx
            while let i = cur {
                if i == ancestorIdx { return true }
                cur = self.flatNodes[i].parentIndex
            }
            return false
        }
        var providerIdx: Int? = nil
        var walk: Int? = firstIdx
        while let p = walk {
            if !flatNodes[p].effectiveInert && flatNodes[p].el.hasSelectionCopyHandler && isDescendant(lastIdx, p) {
                providerIdx = p
                break
            }
            walk = flatNodes[p].parentIndex
        }
        if let p = providerIdx {
            let pNode = flatNodes[p]
            let group = SelectAllResolver.groupPath(
                forNodeAt: snaps.firstIndex(where: { $0.path == firstSel.path }) ?? 0,
                in: snaps
            )
            var rangeByPath: [String: Range<Int>] = [:]
            for item in sel.texts {
                rangeByPath[item.path] = item.range
            }
            var pieces: [SelectedText] = []
            for j in p..<flatNodes.count {
                if !isDescendant(j, p) { break }
                let jNode = flatNodes[j]
                guard let fullText = selectableNodeText(jNode), !fullText.isEmpty else { continue }
                if let g = group {
                    guard let sIdx = snaps.firstIndex(where: { $0.path == jNode.path }),
                          SelectAllResolver.groupPath(forNodeAt: sIdx, in: snaps) == g else {
                        continue
                    }
                } else if j != firstIdx {
                    continue
                }
                let relPath: String
                if j == p {
                    relPath = ""
                } else if jNode.path.hasPrefix(pNode.path + "/") {
                    relPath = String(jNode.path.dropFirst(pNode.path.count + 1))
                } else {
                    relPath = jNode.path
                }
                let byteRange = rangeByPath[jNode.path] ?? 0..<0
                let len = fullText.utf8.count
                let uncopied = jNode.el.uncopiedRanges
                let slice: String = byteRange.isEmpty
                    ? ""
                    : CopyJoin.copySlice(in: fullText, range: byteRange, uncopied: uncopied)
                let trimmed = SelectionMath.trimUncopied(uncopied, range: (0, len))
                let whole = !byteRange.isEmpty
                    && len > 0
                    && byteRange.lowerBound <= trimmed.0
                    && byteRange.upperBound >= trimmed.1
                pieces.append(SelectedText(
                    path: relPath,
                    key: jNode.key,
                    range: byteRange,
                    len: len,
                    whole: whole,
                    text: slice,
                    content: fullText
                ))
            }
            let providerSel = TextSelection(texts: pieces, text: sel.text, backward: sel.backward)
            if let custom = pNode.el.invokeSelectionCopy(providerSel) {
                return custom
            }
        }
        return sel.text.isEmpty ? nil : sel.text
    }

    /// Semantic `text/html` representation of the active `El.selectable` selection
    /// (`Runtime::copy_html` / `copy_html.rs`). Returns `nil` when empty or spanning unmounted rows.
    func copySelectionHTML() -> String? {
        let snaps = selectableSnapshots()
        guard let sel = selectionState.coordinator.currentSelection(in: snaps),
              !sel.texts.isEmpty else {
            return nil
        }
        var selectedRanges: [CopyHTMLBuilder.SelectedRange] = []
        selectedRanges.reserveCapacity(sel.texts.count)
        for item in sel.texts {
            guard let nodeIdx = nodeByPath[item.path],
                  nodeIdx < flatNodes.count else {
                return nil
            }
            if !item.range.isEmpty {
                selectedRanges.append(CopyHTMLBuilder.SelectedRange(nodeIndex: nodeIdx, range: item.range))
            }
        }
        guard !selectedRanges.isEmpty else { return nil }

        let htmlNodes: [CopyHTMLBuilder.NodeSnapshot] = flatNodes.enumerated().map { idx, node in
            var spans: [CopyHTMLBuilder.SpanRun] = []
            if let richSpans = node.el.richSpans, !richSpans.isEmpty {
                var byteCursor = 0
                for sp in richSpans {
                    let nextCursor = byteCursor + sp.text.utf8.count
                    spans.append(CopyHTMLBuilder.SpanRun(
                        byteRange: byteCursor..<nextCursor,
                        weight: sp.weight,
                        italic: sp.italic,
                        monospace: sp.monospace,
                        strikethrough: sp.strikethrough
                    ))
                    byteCursor = nextCursor
                }
            }
            let links = node.el.textLinks.map { CopyHTMLBuilder.LinkRun(byteRange: $0.byteRange, id: $0.id) }
            return CopyHTMLBuilder.NodeSnapshot(
                parentIndex: node.parentIndex,
                roleRaw: node.el.role.rawValue,
                a11yLevel: node.el.a11yLevel,
                a11yHidden: node.el.isA11yHidden,
                rect: laidOutRect(forIndex: idx, in: flatNodes),
                text: selectableNodeText(node),
                baseWeight: node.el.textStyle.weight,
                baseItalic: node.el.textStyle.italic,
                baseMonospace: node.el.textStyle.family == .monospace,
                spans: spans,
                links: links,
                uncopied: node.el.uncopiedRanges
            )
        }
        return CopyHTMLBuilder.build(nodes: htmlNodes, ranges: selectedRanges)
    }
}

private struct VirtualSelectionInjection {
    var listIdx: Int
    var subtreeEnd: Int
    var before: [SelectableNodeSnapshot]
    var after: [SelectableNodeSnapshot]
}

private enum VirtualEndpointPos {
    case beforeList
    case row(Int)
    case afterList
}

internal extension Runtime {
    func selectableNodeText(_ node: FlatNode) -> String? {
        guard !node.effectiveInert,
              !node.el.isSecure,
              node.el.handlers.editLens == nil,
              node.el.isSelectable else {
            return nil
        }
        if let live = node.el.liveText?.get() { return live }
        if let plain = node.el.plainText { return plain }
        if let spans = node.el.richSpans { return spans.map(\.text).joined() }
        return nil
    }

    func selectableSnapshots() -> [SelectableNodeSnapshot] {
        var out: [SelectableNodeSnapshot] = []
        out.reserveCapacity(flatNodes.count)
        for node in flatNodes {
            let text = selectableNodeText(node) ?? ""
            let isSel = !node.effectiveInert && !node.el.isSecure && node.el.handlers.editLens == nil && node.el.isSelectable
            let copyBreaks = node.el.copyBreaksPair
            out.append(SelectableNodeSnapshot(
                path: node.path,
                key: node.key,
                parentPath: node.parentIndex.map { flatNodes[$0].path },
                isSelectable: isSel,
                isSelectionGroup: !node.effectiveInert && node.el.isSelectionGroup,
                isFocusedTextInput: node.path == focusedPath && node.el.handlers.editLens != nil,
                text: text,
                rect: presentedRectByPath[node.path] ?? node.targetRect,
                uncopied: node.el.uncopiedRanges,
                copyBreakBefore: copyBreaks.before,
                copyBreakAfter: copyBreaks.after,
                copyPrefix: node.el.copyPrefixString
            ))
        }
        return out
    }

    func offscreenRowElement(source src: VirtualSelectionSource, at rowIndex: Int) -> El<State>? {
        guard rowIndex >= 0 && rowIndex < src.keys.count else { return nil }
        let rowKey = src.keys[rowIndex]
        if src.isIndexed {
            guard let rowSource = src.source else { return nil }
            let scratch = MemoCache()
            var built = MemoScope.enterVirtualRow(
                cache: scratch,
                envHash: lastViewMemoEnvHash,
                geometry: [:],
                pass: 1
            ) {
                rowSource.build(state, rowIndex)
            }
            built = built.key(rowKey)
            return built
        }
        guard rowIndex < src.storedChildren.count else { return nil }
        var row = src.storedChildren[rowIndex]
        if row.keyId == nil {
            row = row.key(rowKey)
        }
        return row
    }

    func collectOffscreenRowSnapshots(
        source src: VirtualSelectionSource,
        rowIndex: Int,
        rowSegment: String,
        parentInert: Bool,
        baseY: Float,
        into out: inout [SelectableNodeSnapshot]
    ) {
        guard let rowEl = offscreenRowElement(source: src, at: rowIndex) else { return }
        var cursorY = baseY
        var cellX: Float = 0
        collectOffscreenSnapshotsWalk(
            el: rowEl,
            path: "\(src.listPath)/\(rowSegment)",
            parentPath: src.listPath,
            parentInert: parentInert,
            inRowContainer: src.scrollAxes.contains(.horizontal),
            cursorY: &cursorY,
            nextCellX: &cellX,
            into: &out
        )
    }

    private func collectOffscreenSnapshotsWalk(
        el: El<State>,
        path: String,
        parentPath: String?,
        parentInert: Bool,
        inRowContainer: Bool,
        cursorY: inout Float,
        nextCellX: inout Float,
        into out: inout [SelectableNodeSnapshot]
    ) {
        let inert = parentInert || el.isInert
        let isSel = !inert && !el.isSecure && el.handlers.editLens == nil && el.isSelectable
        let text: String
        if isSel {
            text = el.liveText?.get() ?? el.plainText ?? el.richSpans?.map(\.text).joined() ?? ""
        } else {
            text = ""
        }
        let rect = MotionRect.fromXYWH(inRowContainer ? nextCellX : 0, cursorY, 80, 10)
        if isSel && !text.isEmpty {
            if inRowContainer {
                nextCellX += 100
            } else {
                cursorY += 12
            }
        }
        let copyBreaks = el.copyBreaksPair
        out.append(SelectableNodeSnapshot(
            path: path,
            key: el.keyId,
            parentPath: parentPath,
            isSelectable: isSel,
            isSelectionGroup: !inert && el.isSelectionGroup,
            isFocusedTextInput: false,
            text: text,
            rect: rect,
            uncopied: el.uncopiedRanges,
            copyBreakBefore: copyBreaks.before,
            copyBreakAfter: copyBreaks.after,
            copyPrefix: el.copyPrefixString
        ))
        let childInRow = el.layout.direction == .row || el.layout.direction == .rowReverse
        var childX: Float = 0
        var childSeen: [String: Int] = [:]
        for idx in el.children.indices {
            let (seg, _) = layoutPathSegment(
                keyId: el.children[idx].keyId,
                siblingIndex: idx,
                siblingKeysSeen: &childSeen
            )
            if childInRow {
                collectOffscreenSnapshotsWalk(
                    el: el.children[idx],
                    path: "\(path)/\(seg)",
                    parentPath: path,
                    parentInert: inert,
                    inRowContainer: true,
                    cursorY: &cursorY,
                    nextCellX: &childX,
                    into: &out
                )
            } else {
                collectOffscreenSnapshotsWalk(
                    el: el.children[idx],
                    path: "\(path)/\(seg)",
                    parentPath: path,
                    parentInert: inert,
                    inRowContainer: false,
                    cursorY: &cursorY,
                    nextCellX: &nextCellX,
                    into: &out
                )
            }
        }
        if childInRow && childX > 0 {
            cursorY += 12
        }
    }

    func virtualRowIndex(forPath targetPath: String, in src: VirtualSelectionSource) -> (rowIndex: Int, rowSegment: String)? {
        guard targetPath.hasPrefix(src.listPath + "/") else { return nil }
        let rest = targetPath.dropFirst(src.listPath.count + 1)
        let firstSeg = String(rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard !firstSeg.isEmpty else { return nil }
        if firstSeg.hasPrefix("@") {
            let withoutAt = String(firstSeg.dropFirst())
            let rawKey: String
            let dupOrdinal: Int
            if let dupRange = withoutAt.range(of: "#dup", options: .backwards),
               let parsed = Int(withoutAt[dupRange.upperBound...]) {
                rawKey = String(withoutAt[..<dupRange.lowerBound])
                dupOrdinal = parsed
            } else {
                rawKey = withoutAt
                dupOrdinal = 0
            }
            var seen = 0
            for (idx, k) in src.keys.enumerated() where k == rawKey {
                if seen == dupOrdinal {
                    return (idx, firstSeg)
                }
                seen += 1
            }
        } else if let idx = Int(firstSeg), idx >= 0, idx < src.keys.count {
            return (idx, firstSeg)
        }
        return nil
    }

    struct VirtualTreeOrder: Comparable, Equatable {
        let slot: Int
        let row: Int
        let sub: Int

        static func < (lhs: VirtualTreeOrder, rhs: VirtualTreeOrder) -> Bool {
            if lhs.slot != rhs.slot { return lhs.slot < rhs.slot }
            if lhs.row != rhs.row { return lhs.row < rhs.row }
            return lhs.sub < rhs.sub
        }
    }

    struct ResolvedVirtualEndpointInfo {
        let snapshot: SelectableNodeSnapshot
        let listIdx: Int
        let rowIndex: Int
        let orderInRow: Int
        let rowGroupPath: String?
    }

    func resolveVirtualEndpointInfo(forPath targetPath: String) -> ResolvedVirtualEndpointInfo? {
        for (listPath, src) in virtualSelectionSources {
            guard let listIdx = nodeByPath[listPath],
                  listIdx < flatNodes.count,
                  !flatNodes[listIdx].effectiveInert,
                  let (rowIdx, rowSeg) = virtualRowIndex(forPath: targetPath, in: src) else {
                continue
            }
            var rowSnaps: [SelectableNodeSnapshot] = []
            collectOffscreenRowSnapshots(
                source: src,
                rowIndex: rowIdx,
                rowSegment: rowSeg,
                parentInert: flatNodes[listIdx].effectiveInert,
                baseY: 0,
                into: &rowSnaps
            )
            if let hitOffset = rowSnaps.firstIndex(where: {
                $0.isSelectable && !($0.text.isEmpty) && ($0.path == targetPath || SelectionMath.sameKeyedPath($0.path, targetPath))
            }) {
                let hit = rowSnaps[hitOffset]
                var rowGroupPath: String?
                var pPath = hit.parentPath
                while let p = pPath, let parentSnap = rowSnaps.first(where: { $0.path == p }) {
                    if parentSnap.isSelectionGroup {
                        rowGroupPath = parentSnap.path
                        break
                    }
                    pPath = parentSnap.parentPath
                }
                return ResolvedVirtualEndpointInfo(
                    snapshot: hit,
                    listIdx: listIdx,
                    rowIndex: rowIdx,
                    orderInRow: hitOffset,
                    rowGroupPath: rowGroupPath
                )
            }
        }
        return nil
    }

    private func resolveVirtualEndpoint(forPath targetPath: String) -> SelectableNodeSnapshot? {
        resolveVirtualEndpointInfo(forPath: targetPath)?.snapshot
    }

    func selectionTreeOrder(mountedIdx: Int) -> VirtualTreeOrder {
        var cur = mountedIdx
        while cur < flatNodes.count, let p = flatNodes[cur].parentIndex {
            let pPath = flatNodes[p].path
            if let src = virtualSelectionSources[pPath] {
                let rowIdx = virtualRowIndex(forPath: flatNodes[cur].path, in: src)?.rowIndex ?? 0
                return VirtualTreeOrder(slot: p * 2 + 1, row: rowIdx, sub: mountedIdx)
            }
            cur = p
        }
        return VirtualTreeOrder(slot: mountedIdx * 2, row: 0, sub: 0)
    }

    private func resolvedSelectionScrollAnchorIdx(forPath path: String) -> Int? {
        if let idx = resolvedNodeIndex(forPath: path) {
            return idx
        }
        return resolveVirtualEndpointInfo(forPath: path)?.listIdx
    }

    func hasUnmountedVirtualSelectionPin(
        listPath: String,
        keys: [String],
        mounted: Range<Int>
    ) -> Bool {
        guard let activeSel = selectionState.coordinator.phase.selection else { return false }
        let src = VirtualSelectionSource(
            listPath: listPath,
            keys: keys,
            mounted: mounted,
            isIndexed: true,
            source: nil,
            storedChildren: [],
            scrollAxes: []
        )
        // The rows the selection's ends are in, by their row identity when pinned
        // (`sync_selection_pins` -> `PinsEvent::Select { anchor, focus }`), else by path.
        func pinnedRow(path: String, end: VirtualEnd?) -> Int? {
            if let end, end.listPath == listPath { return keys.firstIndex(of: end.rowKey) }
            return virtualRowIndex(forPath: path, in: src)?.rowIndex
        }
        if let r = pinnedRow(path: activeSel.path, end: activeSel.anchorEnd), !mounted.contains(r) {
            return true
        }
        if let far = activeSel.far, let r = pinnedRow(path: far.path, end: far.end), !mounted.contains(r) {
            return true
        }
        return false
    }

    /// `endsOnly` builds only the unmounted rows holding the selection's ends, not those between
    /// them: enough to place the selection's ranges in mounted texts (painting), without
    /// building every row a long selection spans each frame.
    func selectableSnapshotsWithVirtuals(endsOnly: Bool = false) -> [SelectableNodeSnapshot] {
        let base = selectableSnapshots()
        guard let activeSel = selectionState.coordinator.phase.selection,
              !virtualSelectionSources.isEmpty else {
            return base
        }

        let maxOffscreenRows = 10_000
        let maxOffscreenBytes = 4 * 1024 * 1024
        var totalRows = 0
        var totalBytes = 0
        var injections: [VirtualSelectionInjection] = []

        for (listPath, src) in virtualSelectionSources {
            guard !src.keys.isEmpty,
                  let listIdx = nodeByPath[listPath],
                  listIdx < flatNodes.count,
                  !flatNodes[listIdx].effectiveInert else {
                continue
            }
            var subtreeEnd = listIdx
            let prefix = listPath + "/"
            while subtreeEnd + 1 < flatNodes.count && flatNodes[subtreeEnd + 1].path.hasPrefix(prefix) {
                subtreeEnd += 1
            }

            func endpointPos(for path: String) -> VirtualEndpointPos? {
                if let r = virtualRowIndex(forPath: path, in: src) {
                    return .row(r.rowIndex)
                }
                if let idx = resolvedNodeIndex(forPath: path) {
                    if idx < listIdx { return .beforeList }
                    if idx > subtreeEnd { return .afterList }
                }
                return nil
            }

            guard let aPos = endpointPos(for: activeSel.path) else { continue }
            let fPos: VirtualEndpointPos
            if let far = activeSel.far {
                guard let resolved = endpointPos(for: far.path) else { continue }
                fPos = resolved
            } else {
                fPos = aPos
            }

            let mapPos: (VirtualEndpointPos) -> Int = { pos in
                switch pos {
                case .beforeList: return -1
                case .row(let r): return r
                case .afterList: return src.keys.count
                }
            }
            let p0 = mapPos(aPos)
            let p1 = mapPos(fPos)
            let rawLo = min(p0, p1)
            let rawHi = max(p0, p1)
            if rawHi < 0 || rawLo >= src.keys.count { continue }
            let lo = max(0, rawLo)
            let hi = min(src.keys.count - 1, rawHi)

            let mountedLo = src.mounted.lowerBound
            let mountedHi = src.mounted.upperBound
            let beforeRange = lo < mountedLo ? lo..<min(mountedLo, hi + 1) : 0..<0
            let afterRange = hi >= mountedHi ? max(mountedHi, lo)..<(hi + 1) : 0..<0
            if beforeRange.isEmpty && afterRange.isEmpty { continue }

            var mountedMinTop: Float = flatNodes[listIdx].targetRect.top
            var mountedMaxBottom: Float = flatNodes[listIdx].targetRect.bottom
            if listIdx + 1 <= subtreeEnd {
                mountedMinTop = flatNodes[(listIdx + 1)...subtreeEnd].map(\.targetRect.top).min() ?? mountedMinTop
                mountedMaxBottom = flatNodes[(listIdx + 1)...subtreeEnd].map(\.targetRect.bottom).max() ?? mountedMaxBottom
            }

            var beforeSnaps: [SelectableNodeSnapshot] = []
            for r in beforeRange where !endsOnly || r == p0 || r == p1 {
                guard totalRows < maxOffscreenRows && totalBytes < maxOffscreenBytes else { break }
                let rowSeg = "@\(src.keys[r])"
                let baseY = mountedMinTop - Float(mountedLo - r) * 100.0 - 10_000.0
                let countBefore = beforeSnaps.count
                collectOffscreenRowSnapshots(
                    source: src,
                    rowIndex: r,
                    rowSegment: rowSeg,
                    parentInert: flatNodes[listIdx].effectiveInert,
                    baseY: baseY,
                    into: &beforeSnaps
                )
                totalRows += 1
                for s in beforeSnaps[countBefore...] { totalBytes += s.text.utf8.count }
            }

            var afterSnaps: [SelectableNodeSnapshot] = []
            for r in afterRange where !endsOnly || r == p0 || r == p1 {
                guard totalRows < maxOffscreenRows && totalBytes < maxOffscreenBytes else { break }
                let rowSeg = "@\(src.keys[r])"
                let baseY = mountedMaxBottom + Float(r - mountedHi + 1) * 100.0 + 10_000.0
                let countBefore = afterSnaps.count
                collectOffscreenRowSnapshots(
                    source: src,
                    rowIndex: r,
                    rowSegment: rowSeg,
                    parentInert: flatNodes[listIdx].effectiveInert,
                    baseY: baseY,
                    into: &afterSnaps
                )
                totalRows += 1
                for s in afterSnaps[countBefore...] { totalBytes += s.text.utf8.count }
            }

            if !beforeSnaps.isEmpty || !afterSnaps.isEmpty {
                injections.append(VirtualSelectionInjection(listIdx: listIdx, subtreeEnd: subtreeEnd, before: beforeSnaps, after: afterSnaps))
            }
        }

        guard !injections.isEmpty else { return base }
        let beforeByIdx = Dictionary(grouping: injections, by: \.listIdx)
        let afterByIdx = Dictionary(grouping: injections, by: \.subtreeEnd)
        var out: [SelectableNodeSnapshot] = []
        out.reserveCapacity(base.count + 32)
        for (idx, snap) in base.enumerated() {
            out.append(snap)
            if let ins = beforeByIdx[idx] {
                for item in ins { out.append(contentsOf: item.before) }
            }
            if let ins = afterByIdx[idx] {
                for item in ins { out.append(contentsOf: item.after) }
            }
        }
        return out
    }

    func preservesTextSelectionInChain(_ node: FlatNode?) -> Bool {
        var cur = node
        while let n = cur {
            if n.el.preservesTextSelection { return true }
            cur = n.parentIndex.map { flatNodes[$0] }
        }
        return false
    }

    func selectableHitOffset(node: FlatNode, windowPos: Vec2, preferLayoutRects: Bool = false) -> Int {
        let displayText = selectableNodeText(node) ?? ""
        guard !displayText.isEmpty else { return 0 }
        let rect = preferLayoutRects ? node.targetRect : (presentedRectByPath[node.path] ?? node.targetRect)
        let sc = preferLayoutRects ? Vec2(1, 1) : (presentedScaleByPath[node.path] ?? Vec2(1, 1))
        let innerW = max(0, rect.width - (node.el.layout.padding.left + node.el.layout.padding.right) * sc.x)
        let resolvedText = ElDisplayResolver.resolveText(el: node.el, rawText: displayText, isSecure: false)
        // A text wraps at its layout width, `w * scale + FIT_SLACK` device px, as it laid out and
        // paints (`relayout::lay_out_text`, #948).
        let layoutInnerW = max(0, node.targetRect.width - node.el.layout.padding.left - node.el.layout.padding.right)
        let wrapWidth = TextBoxGeometry.wrapWidth(layoutInnerW, scale: pixelScale)!
        let shaped = resolvedText.shape(
            using: textSystem,
            maxWidth: wrapWidth,
            pixelScale: pixelScale,
            emitGlyphs: false,
            bypassCache: node.el.isSecure
        )
        let unturned = hitGeometryByPath[node.path]?.turn?.unturn(windowPos) ?? windowPos
        let localX = (unturned.x - (rect.x + node.el.layout.padding.left * sc.x)) / max(1e-4, sc.x)
        let localY = (unturned.y - (rect.y + node.el.layout.padding.top * sc.y)) / max(1e-4, sc.y)
        let drawnRaw = textSystem.hitTestUTF8Offset(in: shaped, localX: localX, localY: localY, pixelScale: pixelScale)
        let raw = shaped.elided?.contentOffset(forDrawn: drawnRaw) ?? drawnRaw
        return SelectionMath.floorCharBoundary(in: displayText, offset: raw)
    }

    private func isTopSelectableInputTarget(_ node: FlatNode) -> Bool {
        if node.el.isSelectable { return true }
        if let geom = hitGeometryByPath[node.path], geom.hasVisualBlocker || geom.isInteractiveBlocker {
            return true
        }
        let h = node.el.handlers
        return node.el.background.a > 0.001
            || node.el.gradient != nil
            || (node.el.borderWidth > 0 && node.el.borderColor.a > 0.001)
            || node.el.imagePayload != nil
            || node.el.backdropBlur >= 0.5
            || !node.el.shapes.isEmpty
            || h.onClick != nil || h.onClickPress != nil || h.onDoubleClick != nil
            || h.onPointerDown != nil || h.onDrag != nil || h.dragOut != nil
            || node.el.attachedDragOutItem != nil || h.editLens != nil
            || h.onSecondaryClick != nil || nodeTakesFocus(node.el)
            || node.el.explicitHit || node.el.isModal
    }

    private func selectableHitNode(at pos: Vec2) -> FlatNode? {
        guard let topHit = hitTest(at: pos, predicate: { self.isTopSelectableInputTarget($0) }),
              let content = selectableNodeText(topHit.node),
              !content.isEmpty else {
            return nil
        }
        return topHit.node
    }

    func handleSelectablePointerDown(
        at pos: Vec2,
        button: PointerButton,
        mods: Mods,
        hitInteractiveNode: FlatNode?,
        at now: Double
    ) {
        guard button == .primary else { return }
        if preservesTextSelectionInChain(hitInteractiveNode) {
            return
        }
        if hitInteractiveNode?.el.handlers.editLens != nil {
            selectionState.clearClicks()
            selectionState.edgeScroll.stop()
            if selectionState.coordinator.phase.selection != nil {
                selectionState.coordinator.phase.clear()
                syncSelectionPins()
                selectionState.isDraggingSelection = false
                if cxSettings.selectionRectsReadByView {
                    dirtyCommit(at: now, external: false)
                }
                dispatchSelectionChanges(at: now)
            }
            return
        }
        let sHitNode = selectableHitNode(at: pos)
        let qualifies: Bool = {
            guard let sHitNode else { return false }
            guard let interactive = hitInteractiveNode else { return true }
            return sHitNode.path == interactive.path || sHitNode.path.hasPrefix(interactive.path + "/")
        }()
        guard qualifies, let sNode = sHitNode, let content = selectableNodeText(sNode), !content.isEmpty else {
            selectionState.clearClicks()
            selectionState.edgeScroll.stop()
            if selectionState.coordinator.phase.selection != nil {
                selectionState.coordinator.phase.clear()
                syncSelectionPins()
                selectionState.isDraggingSelection = false
                selectionState.suppressedClickOnRelease = false
                if cxSettings.selectionRectsReadByView {
                    dirtyCommit(at: now, external: false)
                }
                dispatchSelectionChanges(at: now)
            }
            return
        }

        let offset = selectableHitOffset(node: sNode, windowPos: pos)
        let clicks = selectionState.notePrimaryPress(path: sNode.path, at: pos, now: now)
        let snaps = selectableSnapshots()
        let sSnapIdx = snaps.firstIndex(where: { $0.path == sNode.path })
        let sGroup = sSnapIdx.flatMap { SelectAllResolver.groupPath(forNodeAt: $0, in: snaps) }
        selectionState.coordinator.pick.noteClick(groupPath: sGroup ?? sNode.path)
        let interactiveTakesDrag: Bool = {
            guard let h = hitInteractiveNode?.el.handlers else { return false }
            return h.onDrag != nil || h.dragOut != nil || hitInteractiveNode?.el.attachedDragOutItem != nil
        }()

        // `selection_down`: Shift extends the selection whose holder is this text or shares its
        // group, the holder found by its row identity (so an anchor row scrolled out still counts).
        if mods.shift, clicks == 1,
           let sIdx = nodeByPath[sNode.path], let iEnd = mountedSelectionEnd(sIdx),
           let h = selectionHolderEnd(),
           h.mountedIdx == sIdx || (h.groupPath != nil && h.groupPath == iEnd.groupPath),
           var updated = selectionState.coordinator.phase.selection {
            // `phase::step` `Event::Extend`: the anchor and what its text read stay; the origin
            // collapses onto the anchor and the focus moves here, in this text or (`far`) another.
            updated.originStart = updated.anchor
            updated.originEnd = updated.anchor
            updated.focus = offset
            updated.far = h.mountedIdx == sIdx ? nil : SelectionFar(path: sNode.path, content: content)
            if interactiveTakesDrag {
                selectionState.coordinator.phase.place(updated)
                selectionState.isDraggingSelection = false
            } else {
                selectionState.coordinator.phase.startDrag(selection: updated, unit: .character)
                selectionState.isDraggingSelection = true
                selectionState.dragStartPos = pos
            }
            sealBetween()
            selectionState.suppressedClickOnRelease = false
            if cxSettings.selectionRectsReadByView {
                dirtyCommit(at: now, external: false)
            }
            dispatchSelectionChanges(at: now)
            return
        }

        let unit = SelectionUnit.forClickCount(clicks)
        let origin = SelectionMath.unitRange(in: content, at: offset, unit: unit, uncopied: sNode.el.uncopiedRanges)
        let initialSel = ActiveSelection(
            path: sNode.path,
            content: content,
            anchor: origin.0,
            focus: origin.1,
            origin: origin
        )
        if interactiveTakesDrag {
            // Inside an onDrag/dragOut container, clicks place word/paragraph selection while drags move the row.
            selectionState.coordinator.phase.place(initialSel)
            selectionState.isDraggingSelection = false
        } else {
            selectionState.coordinator.phase.startDrag(selection: initialSel, unit: unit)
            selectionState.isDraggingSelection = true
            selectionState.dragStartPos = pos
        }
        sealBetween()
        selectionState.suppressedClickOnRelease = false
        if cxSettings.selectionRectsReadByView {
            dirtyCommit(at: now, external: false)
        }
        dispatchSelectionChanges(at: now)
    }

    func handleSelectableSecondaryClick(at pos: Vec2, at now: Double) {
        guard let sNode = selectableHitNode(at: pos),
              let content = selectableNodeText(sNode),
              !content.isEmpty else {
            return
        }
        #if os(macOS)
        let offset = selectableHitOffset(node: sNode, windowPos: pos)
        let activeRange = currentTextSelection()?.texts.first(where: { $0.path == sNode.path })?.range
        let outsideCurrent = activeRange.map { offset < $0.lowerBound || offset >= $0.upperBound } ?? true
        if outsideCurrent {
            let word = SelectionMath.unitRange(in: content, at: offset, unit: .word, uncopied: sNode.el.uncopiedRanges)
            selectionState.clearClicks()
            selectionState.isDraggingSelection = false
            selectionState.edgeScroll.stop()
            selectionState.coordinator.phase.place(ActiveSelection(
                path: sNode.path,
                content: content,
                anchor: word.0,
                focus: word.1,
                origin: word
            ))
            sealBetween()
            let snaps = selectableSnapshots()
            if let sIdx = snaps.firstIndex(where: { $0.path == sNode.path }) {
                let sUnit = SelectAllResolver.groupPath(forNodeAt: sIdx, in: snaps) ?? sNode.path
                selectionState.coordinator.pick.noteClick(groupPath: sUnit)
            }
            dirtyCommit(at: now, external: false)
            dispatchSelectionChanges(at: now)
        }
        #endif

        let copied = copySelectionText()
        let copiedHTML = copySelectionHTML()
        let menu = PopupMenu().item(
            "copy",
            "Copy",
            enabled: copied != nil,
            keyEquivalent: "mod+c"
        )
        enqueuePopupRequest(ErasedPopupRequest(
            menu: menu,
            anchor: .point(pos.x, pos.y),
            onPick: { _, picked, tx in
                if picked == "copy", let copied {
                    let cb = ClipboardContent(copied, html: copiedHTML)
                    tx.runtimeActions["richClipboardWrite"] = RichClipboardPayload(content: cb)
                }
            }
        ))
        popupNeedsLayout = true
        dirtyCommit(at: now)
    }

    func handleSelectablePointerMove(to pos: Vec2, mods: Mods, at now: Double, preferLayoutRects: Bool = false) -> Bool {
        _ = mods
        guard !hasActivePointerDrag else {
            selectionState.edgeScroll.stop()
            return false
        }
        guard selectionState.isDraggingSelection,
              case .dragging(var sel, let unit) = selectionState.coordinator.phase else {
            selectionState.edgeScroll.stop()
            return false
        }
        // `selection_drag`: the selection's own text, resolved by its row identity first.
        guard let h = selectionHolderEnd() else {
            selectionState.isDraggingSelection = false
            selectionState.edgeScroll.stop()
            clearTextSelectionPhase()
            if cxSettings.selectionRectsReadByView {
                dirtyCommit(at: now, external: false)
            }
            return false
        }
        let snaps = selectableSnapshots()
        let anchorMountedIdx = h.mountedIdx
        let edgeScrollIdx = h.mountedIdx ?? h.listIdx ?? 0
        let anchorGroup = h.groupPath.flatMap { nodeByPath[$0] != nil ? $0 : nil }
        let anchorOrder = selectionTreeOrder(of: h)
        updateSelectableEdgeScrollOnMove(pos: pos, anchorIdx: edgeScrollIdx, at: now)

        let resolvedTarget: (idx: Int, offset: Int)?
        if let gPath = anchorGroup {
            resolvedTarget = groupPointTarget(
                groupPath: gPath,
                anchorOrder: anchorOrder,
                snaps: snaps,
                at: pos,
                preferLayoutRects: preferLayoutRects
            )
        } else if let idx = anchorMountedIdx {
            resolvedTarget = (idx, selectableHitOffset(node: flatNodes[idx], windowPos: pos, preferLayoutRects: preferLayoutRects))
        } else {
            return true
        }
        guard let (targetIdx, rawOffset) = resolvedTarget,
              let targetContent = selectableNodeText(flatNodes[targetIdx]) else {
            return true
        }

        let targetUnit = SelectionMath.unitRange(
            in: targetContent,
            at: rawOffset,
            unit: unit,
            uncopied: flatNodes[targetIdx].el.uncopiedRanges
        )
        let reachesAnchor = anchorMountedIdx == targetIdx
        let ends: (anchor: Int, focus: Int)
        if reachesAnchor {
            ends = SelectionMath.extendSelection(origin: sel.origin, at: targetUnit)
        } else if selectionTreeOrder(mountedIdx: targetIdx) > anchorOrder {
            ends = (sel.originStart, targetUnit.1)
        } else {
            ends = (sel.originEnd, targetUnit.0)
        }
        // `phase::step` `Event::Drag`: nothing moved, nothing changes; the same far text keeps
        // what it read and re-pins; another seals the texts between.
        let targetPath = flatNodes[targetIdx].path
        let sameFar = reachesAnchor ? sel.far == nil : sel.far?.path == targetPath
        if (sel.anchor, sel.focus) != (ends.anchor, ends.focus) || !sameFar {
            sel.anchor = ends.anchor
            sel.focus = ends.focus
            if reachesAnchor {
                sel.far = nil
            } else if !sameFar {
                sel.far = SelectionFar(path: targetPath, content: targetContent)
            }
            selectionState.coordinator.phase.startDrag(selection: sel, unit: unit)
            if sameFar {
                syncSelectionPins()
            } else {
                sealBetween()
            }
        }
        if hypot(pos.x - selectionState.dragStartPos.x, pos.y - selectionState.dragStartPos.y) > 4.0,
           selectedText() != nil {
            selectionState.suppressedClickOnRelease = true
        }
        if cxSettings.selectionRectsReadByView {
            dirtyCommit(at: now, external: false)
        }
        dispatchSelectionChanges(at: now)
        return true
    }

    func handleSelectablePointerUp(at pos: Vec2, button: PointerButton, at now: Double) -> Bool {
        selectionState.edgeScroll.stop()
        guard button == .primary, selectionState.isDraggingSelection else {
            return false
        }
        // A release moves the pointer where it lets go first, extending the selection there
        // (`pointer.rs::release` -> `move_pointer` -> `selection_drag`).
        _ = handleSelectablePointerMove(to: pos, mods: .none, at: now)
        selectionState.edgeScroll.stop()
        guard selectionState.isDraggingSelection else { return false }
        selectionState.isDraggingSelection = false
        let suppressClick = selectionState.suppressedClickOnRelease && selectedText() != nil
        selectionState.suppressedClickOnRelease = false
        selectionState.coordinator.phase.endDrag()
        if cxSettings.selectionRectsReadByView {
            dirtyCommit(at: now, external: false)
        }
        dispatchSelectionChanges(at: now)
        return suppressClick
    }

    func handleSelectableKeyDown(_ ev: KeyEvent, at now: Double) -> Bool {
        if let fPath = focusedPath, focusedInputElement(at: fPath)?.handlers.editLens != nil {
            return false
        }
        let plain = ev.mods.primaryCommand && !ev.mods.shift && !ev.mods.alt && !(ev.mods.ctrl && ev.mods.cmd)
        guard plain else { return false }

        let isC = ev.key == .command("c") || ev.key == .text("c") || ev.key == .text("C")
        let isA = ev.key == .command("a") || ev.key == .text("a") || ev.key == .text("A")
        // A selection whose text went away goes before either key (`selection_key`).
        if selectionState.coordinator.phase.selection != nil, selectionHolderEnd() == nil {
            clearTextSelectionPhase()
            if isC { return false }
        }
        if isC {
            guard selectionState.coordinator.phase.selection != nil, let copied = copySelectionText() else { return false }
            recordCopy(ClipboardContent(copied, html: copySelectionHTML()))
            return true
        }
        if isA {
            guard selectAllKey() else { return false }
            dirtyCommit(at: now, external: false)
            dispatchSelectionChanges(at: now)
            return true
        }
        return false
    }

    func applySelectionTx(_ tx: Tx, at now: Double) {
        if tx.clearTextSelectionRequested {
            selectionState.pendingSelectTextRequest = nil
            selectionState.pendingSelectAllKey = nil
            selectionState.coordinator.phase.clear()
            syncSelectionPins()
            dirtyCommit(at: now)
            return
        }
        if let key = tx.pendingSelectAllTextKey {
            selectionState.pendingSelectTextRequest = nil
            let snaps = selectableSnapshots()
            if snaps.isEmpty || selectionState.coordinator.selectAllText(key: key, in: snaps) == nil {
                selectionState.pendingSelectAllKey = key
            } else {
                selectionState.pendingSelectAllKey = nil
                sealBetween()
            }
            dirtyCommit(at: now)
        } else if let req = tx.pendingSelectTextRequest {
            selectionState.pendingSelectAllKey = nil
            let snaps = selectableSnapshots()
            if snaps.isEmpty || selectionState.coordinator.selectText(key: req.key, range: req.range, in: snaps) == nil {
                selectionState.pendingSelectTextRequest = req
            } else {
                selectionState.pendingSelectTextRequest = nil
                sealBetween()
            }
            dirtyCommit(at: now)
        }
    }

    func finalizeSelectionAfterCommit(at now: Double) {
        lazy var snaps = selectableSnapshotsWithVirtuals()
        let keepPending = needsCommit || !scrollGlidingPaths.isEmpty || !scrollRequestsState.isEmpty
        if let pendingAll = selectionState.pendingSelectAllKey {
            if selectionState.coordinator.selectAllText(key: pendingAll, in: snaps) != nil {
                selectionState.pendingSelectAllKey = nil
                sealBetween()
            } else if !keepPending {
                selectionState.pendingSelectAllKey = nil
            }
        } else if let pendingReq = selectionState.pendingSelectTextRequest {
            if selectionState.coordinator.selectText(key: pendingReq.key, range: pendingReq.range, in: snaps) != nil {
                selectionState.pendingSelectTextRequest = nil
                sealBetween()
            } else if !keepPending {
                selectionState.pendingSelectTextRequest = nil
            }
        }
        reconcileSelectionPhaseAgainstTree()
        dispatchSelectionChanges(at: now)
    }

    func computeActiveSelectionRangesByPath() -> [String: Range<Int>] {
        guard selectionState.coordinator.phase.selection != nil,
              let sel = selectionState.coordinator.currentSelection(in: selectableSnapshotsWithVirtuals(endsOnly: true)) else {
            return [:]
        }
        var map: [String: Range<Int>] = [:]
        map.reserveCapacity(sel.texts.count)
        for item in sel.texts where !item.range.isEmpty {
            map[item.path] = item.range
        }
        return map
    }

    func emitSelectableHighlightIfNeeded(
        snap: FlatNode,
        el: El<State>,
        isExiting: Bool,
        activeSelectionRanges: [String: Range<Int>],
        textOriginX: Float,
        textOriginY: Float,
        scaleVec: Vec2,
        pxScale: Float,
        localAlpha: Float,
        shaped: ShapedText,
        devClip: SIMD4<Float>,
        useLayer: Bool,
        effRotate: Float,
        into primitives: inout [Primitive]
    ) -> SelectablePaintInk? {
        guard !isExiting,
              !el.isSecure,
              el.handlers.editLens == nil else {
            return nil
        }

        let style = resolvedSelectionStyle(for: snap)
        let picked = style?.pick(active: windowFocused)
        let fallbackHl = windowFocused
            ? (el.selectionColor ?? Tok.accent(0, dark: systemDark).alpha(0.28))
            : (el.selectionColor ?? Tok.accent(0, dark: systemDark).alpha(0.28)).scaleAlpha(0.55)
        let rot = useLayer ? 0 : effRotate

        // Custom marked ranges declared via `Cx.markTexts` paint square per-line boxes (`text_marks.rs`).
        if !selectionState.lastCommittedMarkedTexts.isEmpty,
           let content = selectableNodeText(snap),
           !content.isEmpty {
            let markColor = (el.selectionColor ?? Tok.accent(0, dark: systemDark).alpha(0.28))
                .scaleAlpha(localAlpha)
                .simd4(srgb: srgbBlend)
            let utf8 = Array(content.utf8)
            for mark in selectionState.lastCommittedMarkedTexts where mark.path == snap.path && !mark.range.isEmpty {
                let lo = mark.range.lowerBound
                let hi = mark.range.upperBound
                guard lo >= 0, hi <= utf8.count, lo < hi,
                      SelectionMath.floorCharBoundary(in: content, offset: lo) == lo,
                      SelectionMath.floorCharBoundary(in: content, offset: hi) == hi else { continue }
                let sub = String(decoding: utf8[lo..<hi], as: UTF8.self)
                guard sub == mark.text else { continue }
                var lineStart = lo
                for line in sub.split(separator: "\n", omittingEmptySubsequences: false) {
                    let trimmedLen = line.hasSuffix("\r") ? line.utf8.count - 1 : line.utf8.count
                    let lineEnd = lineStart + trimmedLen
                    if lineStart < lineEnd {
                        let markRects = textSystem.selectionRects(
                            in: shaped,
                            utf8Range: lineStart..<lineEnd,
                            pixelScale: pxScale
                        )
                        for r in markRects {
                            primitives.append(.roundedRect(
                                // Its edges on the device grid wherever the text's origin falls (`text_marks::pixel_rect`, #935).
                                rect: TextBoxGeometry.pixelRect(
                                    origin: SIMD2<Float>(textOriginX, textOriginY),
                                    box: r,
                                    k: SIMD2<Float>(scaleVec.x, scaleVec.y),
                                    pxScale: pxScale
                                ),
                                radii: .zero,
                                fill: markColor,
                                clip: devClip,
                                turn: rot
                            ))
                        }
                    }
                    lineStart += line.utf8.count + 1
                }
            }
        }

        guard el.isSelectable,
              let range = activeSelectionRanges[snap.path],
              !range.isEmpty else {
            return nil
        }
        let drawnRange = shaped.elided?.selectionRange(range) ?? range
        let lineRects = textSystem.selectionRects(in: shaped, utf8Range: drawnRange, pixelScale: pxScale)
        guard !lineRects.isEmpty else { return nil }
        let hlColor = (picked?.highlight ?? fallbackHl).scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
        let radiusPx = 2.0 * pxScale * scaleVec.x
        let reachPx = 40.0 * pxScale * scaleVec.x
        for r in lineRects {
            SelectionRunExtender.appendHighlight(
                into: &primitives,
                // Its edges on the device grid wherever the text's origin falls (`text_marks::pixel_rect`, #935).
                rect: TextBoxGeometry.pixelRect(
                    origin: SIMD2<Float>(textOriginX, textOriginY),
                    box: r,
                    k: SIMD2<Float>(scaleVec.x, scaleVec.y),
                    pxScale: pxScale
                ),
                fill: hlColor,
                radius: radiusPx,
                clip: devClip,
                fade: .zero,
                turn: rot,
                reach: reachPx
            )
        }
        if let ink = picked?.ink {
            return SelectablePaintInk(ink: ink, rects: lineRects)
        }
        return nil
    }

    func laidOutRect(forIndex idx: Int, in nodes: [FlatNode]) -> MotionRect {
        guard idx >= 0 && idx < nodes.count else { return .zero }
        var totalScroll = Vec2.zero
        var cur = nodes[idx].parentIndex
        var portalBroken = nodes[idx].el.anchor != nil
        while let pIdx = cur, pIdx < nodes.count {
            if !portalBroken, !nodes[pIdx].el.layout.scrollAxes.isEmpty {
                let off = scrollOffsets[nodes[pIdx].path] ?? .zero
                totalScroll.x += off.x
                totalScroll.y += off.y
            }
            if nodes[pIdx].el.anchor != nil {
                portalBroken = true
            }
            cur = nodes[pIdx].parentIndex
        }
        return nodes[idx].unscrolledRect.offsetBy(Vec2(-totalScroll.x, -totalScroll.y))
    }

    /// Selection highlight boxes `[x, y, w, h]` in post-scroll window points across mounted texts
    /// (`Runtime::selection_boxes` / `rects.rs:42-81`).
    func computeSelectionBoxes(in candidateNodes: [FlatNode]? = nil) -> [[Float]] {
        let ranges = computeActiveSelectionRangesByPath()
        guard !ranges.isEmpty else { return [] }
        let nodes = candidateNodes ?? flatNodes
        let snaps = selectableSnapshots()
        guard let sel = selectionState.coordinator.currentSelection(in: snaps) else { return [] }

        var boxes: [[Float]] = []
        for item in sel.texts where !item.range.isEmpty {
            let matchIdx = nodes.firstIndex { $0.path == item.path }
                ?? nodes.firstIndex { SelectionMath.sameKeyedPath($0.path, item.path) }
            guard let j = matchIdx, j < nodes.count else { continue }
            let node = nodes[j]
            let el = node.el
            guard !node.effectiveInert, !el.isSecure, el.handlers.editLens == nil else { continue }
            let text = el.liveText?.get() ?? el.plainText ?? el.richSpans?.map(\.text).joined() ?? ""
            guard !text.isEmpty else { continue }
            let len = text.utf8.count
            let lo = max(0, min(len, item.range.lowerBound))
            let hi = max(lo, min(len, item.range.upperBound))
            guard lo < hi else { continue }

            let rect = laidOutRect(forIndex: j, in: nodes)
            let pad = el.layout.padding
            let innerW = max(0, rect.width - pad.left - pad.right)
            let shaped = textSystem.shape(
                text: text,
                spans: el.richSpans,
                pills: el.pillChips,
                style: el.textStyle,
                maxWidth: innerW + 0.5,
                pixelScale: pixelScale,
                emitGlyphs: false
            )
            let originX = rect.left + pad.left
            let originY = rect.top + pad.top
            for r in textSystem.selectionRects(in: shaped, utf8Range: lo..<hi, pixelScale: pixelScale) {
                boxes.append([originX + r.x, originY + r.y, r.z, r.w])
            }
        }
        return boxes
    }

    func resolvedNodeIndex(forPath path: String) -> Int? {
        if let idx = nodeByPath[path], idx < flatNodes.count, selectableNodeText(flatNodes[idx]) != nil {
            return idx
        }
        // Paths with the same keyed identity end in the same segment (the same unkeyed tail, or
        // the same last key), so only those need the full comparison.
        let last = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
        func endsInLast(_ p: String) -> Bool {
            guard p.hasSuffix(last) else { return false }
            let head = p.utf8.dropLast(last.utf8.count)
            return head.isEmpty || head.last == UInt8(ascii: "/")
        }
        return flatNodes.firstIndex {
            endsInLast($0.path) && selectableNodeText($0) != nil && SelectionMath.sameKeyedPath($0.path, path)
        }
    }

    private func reconcileSelectionPhaseAgainstTree() {
        pruneTextSelection()
    }

    func dispatchSelectionChanges(at now: Double) {
        guard !selectionState.isDispatchingSelectionChanges else { return }
        selectionState.isDispatchingSelectionChanges = true
        defer { selectionState.isDispatchingSelectionChanges = false }

        let watchers: [(path: String, el: El<State>)] = flatNodes.compactMap { n in
            guard !n.effectiveInert, n.el.hasSelectionChangeHandler else { return nil }
            return (n.path, n.el)
        }
        let wasDragging = selectionState.lastDispatchedDragging
        let isDragging = selectionState.coordinator.phase.isDragging
        selectionState.lastDispatchedDragging = isDragging
        // Nobody listens and nobody heard a selection: nothing to tell.
        if watchers.isEmpty && selectionState.coordinator.heardByPath.isEmpty { return }
        let snaps = selectableSnapshotsWithVirtuals()

        var changes = selectionState.coordinator.collectSelectionChanges(elements: watchers, nodes: snaps)
        if wasDragging && !isDragging, let active = selectionState.coordinator.currentSelection(in: snaps) {
            let selectedPaths = Set(active.texts.map(\.path))
            let alreadyFired = Set(changes.map(\.path))
            for (path, _) in watchers where !alreadyFired.contains(path) {
                if selectedPaths.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) {
                    changes.append((path, SelectionChange(selection: active, was: true, isDragging: false)))
                }
            }
        }
        guard !changes.isEmpty else { return }
        for (path, change) in changes {
            guard let idx = nodeByPath[path], idx < flatNodes.count else { continue }
            var tx = makeTx(at: now)
            if flatNodes[idx].el.invokeSelectionChange(state: &state, change: change, tx: &tx) {
                applyTx(tx, at: now)
                dirtyCommit(at: now)
            }
        }
    }

    private func safeParentNode(of node: FlatNode) -> FlatNode? {
        if let p = node.parentIndex, flatNodes.indices.contains(p),
           node.path.hasPrefix(flatNodes[p].path + "/") {
            return flatNodes[p]
        }
        if let slash = node.path.lastIndex(of: "/"),
           let pIdx = nodeByPath[String(node.path[..<slash])],
           flatNodes.indices.contains(pIdx) {
            return flatNodes[pIdx]
        }
        return nil
    }

    private func resolvedSelectionStyle(for node: FlatNode) -> SelectionStyle? {
        var cur: FlatNode? = node
        while let n = cur {
            if let style = n.el.resolvedSelectionStyle {
                return style
            }
            cur = safeParentNode(of: n)
        }
        return nil
    }

    private func groupPointTarget(
        groupPath: String,
        anchorOrder: VirtualTreeOrder,
        snaps: [SelectableNodeSnapshot],
        at pos: Vec2,
        preferLayoutRects: Bool = false
    ) -> (idx: Int, offset: Int)? {
        var boxes: [SelectableBandBox] = []
        for (idx, snap) in snaps.enumerated() where snap.isSelectable && !snap.text.isEmpty {
            guard SelectAllResolver.groupPath(forNodeAt: idx, in: snaps) == groupPath else { continue }
            let rawRect = preferLayoutRects
                ? flatNodes[idx].targetRect
                : (presentedRectByPath[snap.path] ?? flatNodes[idx].targetRect)
            let shown = intersectRects(flatNodes[idx].clipRect, rawRect)
            if shown.width > 0 && shown.height > 0 {
                boxes.append(SelectableBandBox(idx: idx, rect: shown))
            }
        }
        guard !boxes.isEmpty else { return nil }
        boxes.sort { $0.rect.top < $1.rect.top }

        var bands: [SelectableBand] = []
        for (k, entry) in boxes.enumerated() {
            if let last = bands.last, entry.rect.top < last.bottom {
                bands[bands.count - 1].bottom = max(last.bottom, entry.rect.bottom)
                bands[bands.count - 1].range = last.range.lowerBound..<(k + 1)
            } else {
                bands.append(SelectableBand(top: entry.rect.top, bottom: entry.rect.bottom, range: k..<(k + 1)))
            }
        }

        func distX(_ rect: MotionRect, _ x: Float) -> Float {
            max(0, max(rect.left - x, x - rect.right))
        }

        if let band = bands.first(where: { pos.y >= $0.top && pos.y < $0.bottom }) {
            let best = boxes[band.range].min { distX($0.rect, pos.x) < distX($1.rect, pos.x) }!
            return (best.idx, selectableHitOffset(node: flatNodes[best.idx], windowPos: pos, preferLayoutRects: preferLayoutRects))
        }
        let above = bands.last(where: { $0.bottom <= pos.y })
        let below = bands.first(where: { $0.top > pos.y })
        if let below {
            let minBelowIdx = boxes[below.range].map(\.idx).min()!
            if above == nil || selectionTreeOrder(mountedIdx: minBelowIdx) <= anchorOrder {
                return (minBelowIdx, 0)
            }
        }
        if let above {
            let maxAboveIdx = boxes[above.range].map(\.idx).max()!
            let len = (selectableNodeText(flatNodes[maxAboveIdx]) ?? "").utf8.count
            return (maxAboveIdx, len)
        }
        return nil
    }

    // MARK: - Drag Edge Auto-Scroll (`crates/rune/src/runtime/selection/edge_scroll.rs`)

    private struct SelectionEdgeInfo {
        var scrollPath: String
        var speed: Float
        var room: Double
        var offset: Double
        var max: Double

        var moves: Bool {
            abs(speed) > 0.0 && room > 0.0
        }
    }

    private static func restEdgeScroll(_ edge: SelectionEdgeInfo?, scroll: String?) -> SelectionEdgeScrollState {
        guard let e = edge, abs(e.speed) > 0.0, scroll == nil || scroll == e.scrollPath else {
            return .idle
        }
        return .atEnd(scrollPath: e.scrollPath, max: e.max)
    }

    var hasActiveSelectableEdgeScroll: Bool {
        selectionState.edgeScroll.isRunning
    }

    func nextSelectableEdgeScrollWakeDeadline(after now: Double) -> Double? {
        switch selectionState.edgeScroll {
        case .running(_, _, _, _, let due):
            return max(now, due)
        case .laying(let next, _, _, _, _):
            return next != nil ? now : nil
        case .idle, .atEnd:
            return nil
        }
    }

    private func selectableEdgeAt(windowY: Float, anchorIdx: Int) -> SelectionEdgeInfo? {
        guard selectionState.isDraggingSelection, selectionState.coordinator.phase.isDragging else {
            return nil
        }
        var cur: Int? = anchorIdx
        var scrollNode: FlatNode? = nil
        while let idx = cur, idx < flatNodes.count {
            let candidate = flatNodes[idx]
            if candidate.el.layout.scrollAxes.contains(.vertical) {
                scrollNode = candidate
                break
            }
            cur = candidate.parentIndex
        }
        guard let sNode = scrollNode else { return nil }
        let sPath = sNode.path
        let maxY = Double(scrollMaxExtents[sPath]?.y ?? 0)
        let offset = Double(scrollOffsets[sPath]?.y ?? 0)
        let rawRect = presentedRectByPath[sPath] ?? sNode.targetRect
        let windowRect = MotionRect.fromXYWH(0, 0, viewport.x, viewport.y)
        let visible = intersectRects(intersectRects(sNode.clipRect, rawRect), windowRect)
        let atEdge: Float = 1.0
        guard visible.bottom - visible.top > 2.0 * atEdge else { return nil }

        let speedValue: Float
        let room: Double
        if windowY >= visible.bottom - atEdge {
            let past = max(Float(8.0), windowY - (visible.bottom - atEdge))
            speedValue = min(4000.0, 10.0 * past)
            room = max(0.0, maxY - offset)
        } else if windowY <= visible.top + atEdge {
            let past = max(Float(8.0), (visible.top + atEdge) - windowY)
            speedValue = -min(4000.0, 10.0 * past)
            room = max(0.0, offset)
        } else {
            return nil
        }
        guard abs(speedValue) > 0.0 else { return nil }
        return SelectionEdgeInfo(scrollPath: sPath, speed: speedValue, room: room, offset: offset, max: maxY)
    }

    private func updateSelectableEdgeScrollOnMove(pos: Vec2, anchorIdx: Int, at now: Double) {
        let edge = selectableEdgeAt(windowY: pos.y, anchorIdx: anchorIdx)
        guard let e = edge, e.moves else {
            selectionState.edgeScroll = Self.restEdgeScroll(edge, scroll: nil)
            return
        }
        if case .running(_, let existingPath, _, _, _) = selectionState.edgeScroll, existingPath == e.scrollPath {
            return
        }
        let attempt = selectionState.edgeScrollSeq.next()
        selectionState.edgeScroll = .running(attempt: attempt, scrollPath: e.scrollPath, last: now, fromOffset: nil, due: now)
    }

    @discardableResult
    func stepSelectableEdgeScroll(at now: Double) -> Bool {
        guard case .running(let armedAttempt, let scrollPath, let last, let fromOffset, let due) = selectionState.edgeScroll,
              selectionState.edgeScroll.attempt == armedAttempt,
              now >= due else {
            return false
        }
        guard case .dragging(let sel, _) = selectionState.coordinator.phase,
              let anchorIdx = resolvedSelectionScrollAnchorIdx(forPath: sel.path),
              let edge = selectableEdgeAt(windowY: pointerPosition.y, anchorIdx: anchorIdx),
              edge.moves,
              edge.scrollPath == scrollPath else {
            let fallback: SelectionEdgeInfo? = {
                if case .dragging(let sel, _) = selectionState.coordinator.phase,
                   let anchorIdx = resolvedSelectionScrollAnchorIdx(forPath: sel.path) {
                    return selectableEdgeAt(windowY: pointerPosition.y, anchorIdx: anchorIdx)
                }
                return nil
            }()
            selectionState.edgeScroll = Self.restEdgeScroll(fallback, scroll: scrollPath)
            return false
        }
        if let prevOffset = fromOffset, abs(edge.offset - prevOffset) <= 1e-9 {
            selectionState.edgeScroll = .atEnd(scrollPath: scrollPath, max: edge.max)
            return false
        }
        let dt = min(max(0.0, now - last), 0.05)
        guard dt > 1e-9 else {
            selectionState.edgeScroll = .running(
                attempt: armedAttempt,
                scrollPath: scrollPath,
                last: last,
                fromOffset: fromOffset,
                due: now + (1.0 / 60.0)
            )
            return false
        }
        var by = Double(edge.speed) * dt
        let reachedEnd: Bool
        if edge.room - abs(by) <= 1e-3 {
            by = edge.speed >= 0 ? edge.room : -edge.room
            reachedEnd = true
        } else {
            reachedEnd = false
        }
        let maxY = Double(scrollMaxExtents[scrollPath]?.y ?? 0)
        let curOffset = scrollOffsets[scrollPath] ?? .zero
        let nextY = Float((Double(curOffset.y) + by).clamped(to: 0.0...maxY))
        if abs(nextY - curOffset.y) <= 1e-6 {
            selectionState.edgeScroll = .atEnd(scrollPath: scrollPath, max: edge.max)
            return false
        }
        let updated = Vec2(curOffset.x, nextY)
        scrollOffsets[scrollPath] = updated
        if by < 0 || nextY < Float(maxY) - 0.5 {
            wasPinnedToBottom.remove(scrollPath)
        }
        scrollStore.snap(NodeId.hash("scroll:" + scrollPath), Props.SCROLL, to: updated)
        let nextAttempt = reachedEnd ? nil : selectionState.edgeScrollSeq.next()
        scrollGlidingPaths.remove(scrollPath)
        directScrolledPaths.insert(scrollPath)
        scrollRequestsState.stepCancel()
        pendingCommitKind = pendingCommitKind.instant()
        selectionState.edgeScroll = .laying(
            next: nextAttempt,
            scrollPath: scrollPath,
            last: now,
            fromOffset: abs(by) > 0 ? edge.offset : nil,
            max: edge.max
        )
        dirtyCommit(at: now, external: false)
        return true
    }

    private func extendSelectableAfterEdgeStep(at now: Double) -> Bool {
        let before = selectionState.coordinator.phase.selection.map {
            ($0.anchor, $0.focus, $0.far?.path)
        }
        let prevNeedsCommit = needsCommit
        _ = handleSelectablePointerMove(to: pointerPosition, mods: .none, at: now, preferLayoutRects: true)
        let after = selectionState.coordinator.phase.selection.map {
            ($0.anchor, $0.focus, $0.far?.path)
        }
        let changed: Bool
        switch (before, after) {
        case (nil, nil): changed = false
        case let (.some(b), .some(a)): changed = b.0 != a.0 || b.1 != a.1 || b.2 != a.2
        default: changed = true
        }
        if !changed {
            needsCommit = prevNeedsCommit
        }
        return changed
    }

    @discardableResult
    private func edgeScrollExtent(at now: Double) -> Bool {
        guard case .atEnd(let scrollPath, let max) = selectionState.edgeScroll else {
            return false
        }
        let curMax = Double(scrollMaxExtents[scrollPath]?.y ?? 0)
        if curMax == max {
            return false
        }
        guard case .dragging(let sel, _) = selectionState.coordinator.phase,
              let anchorIdx = resolvedSelectionScrollAnchorIdx(forPath: sel.path) else {
            selectionState.edgeScroll = .idle
            return false
        }
        let edge = selectableEdgeAt(windowY: pointerPosition.y, anchorIdx: anchorIdx)
        // Shrunk under a resting drag: end the wait so later arrivals move nothing (`7cca3272`).
        if let e = edge, e.scrollPath == scrollPath, e.max < max {
            selectionState.edgeScroll = .idle
            return false
        }
        // Grown with room left to scroll: resume stepping at `now` (`2aa1b6df`).
        if let e = edge, e.moves, e.scrollPath == scrollPath {
            selectionState.edgeScroll = .running(
                attempt: selectionState.edgeScrollSeq.next(),
                scrollPath: scrollPath,
                last: now,
                fromOffset: nil,
                due: now
            )
            return false
        }
        // Grown while already at the new end (stuck to bottom): extend selection over newly arrived rows (`9d57825b`).
        if let e = edge, e.scrollPath == scrollPath, abs(e.speed) > 0.0, e.max > max {
            selectionState.edgeScroll = .atEnd(scrollPath: scrollPath, max: e.max)
            return extendSelectableAfterEdgeStep(at: now)
        }
        selectionState.edgeScroll = Self.restEdgeScroll(edge, scroll: scrollPath)
        return false
    }

    @discardableResult
    func laidSelectableEdgeScroll(at now: Double) -> Bool {
        guard case .laying(let nextAttempt, let scrollPath, let last, let fromOffset, let max) = selectionState.edgeScroll else {
            return edgeScrollExtent(at: now)
        }
        if let attempt = nextAttempt {
            selectionState.edgeScroll = .running(
                attempt: attempt,
                scrollPath: scrollPath,
                last: last,
                fromOffset: fromOffset,
                due: last + (1.0 / 60.0)
            )
        } else {
            selectionState.edgeScroll = .atEnd(scrollPath: scrollPath, max: max)
        }
        let changed = extendSelectableAfterEdgeStep(at: now)
        // A step that reached the end, when this layout changed the extent it saw.
        return edgeScrollExtent(at: now) || changed
    }

    /// Scrolls the focused `TextEdit` field's nearest ancestor scroll viewport on each axis just far
    /// enough to reveal the caret line, respecting the viewport's `El.scrollMargin` (`caret.rs:58-90`).
    func followCaretIfNeeded() {
        guard let fp = focusedPath,
              let i = nodeByPath[fp],
              i < flatNodes.count,
              let editLens = flatNodes[i].el.handlers.editLens else {
            return
        }
        let node = flatNodes[i]
        let edit = editLens.get(state)
        let rect = laidOutRect(forIndex: i, in: flatNodes)
        let pad = node.el.layout.padding
        let innerW = max(0, rect.width - pad.left - pad.right)
        var style = node.el.textStyle
        if edit.multiline { style.wrap = .wrap }
        if let fDir = edit.forcedDir { style.direction = fDir }
        let shaped = textSystem.shape(
            text: edit.displayString,
            style: style,
            maxWidth: edit.multiline ? innerW : nil,
            pixelScale: pixelScale,
            emitGlyphs: false
        )
        let byteOff = displayCaretByteOffset(for: edit, showingPlaceholder: false)
        let cRect = textSystem.caretRect(in: shaped, utf8Offset: byteOff, pixelScale: pixelScale)
        let lineH = cRect.w > 0 ? cRect.w : (style.lineHeight ?? style.size * 1.25)
        let singleX: Float = edit.multiline
            ? 0
            : computeSingleLineScroll(
                path: node.path,
                edit: edit,
                shaped: shaped,
                isFocused: true,
                showingPlaceholder: false,
                innerWidthPt: innerW,
                pixelScale: pixelScale
            )
        let caretWin: [Float] = [
            rect.left + pad.left - singleX + cRect.x,
            rect.top + pad.top + cRect.y,
            max(1.5, cRect.z),
            lineH
        ]

        for horizontal in [false, true] {
            var cur = node.parentIndex
            var portalBroken = node.el.anchor != nil
            var viewportIdx: Int? = nil
            while let pIdx = cur, pIdx < flatNodes.count {
                if portalBroken { break }
                let candidate = flatNodes[pIdx]
                if candidate.el.layout.scrollAxes.contains(horizontal ? .horizontal : .vertical) {
                    viewportIdx = pIdx
                    break
                }
                if candidate.el.anchor != nil {
                    portalBroken = true
                }
                cur = candidate.parentIndex
            }
            guard let v = viewportIdx else { continue }
            let vNode = flatNodes[v]
            let vRect = laidOutRect(forIndex: v, in: flatNodes)
            let start = Double(horizontal ? vRect.left : vRect.top)
            let view = Double(horizontal ? vRect.width : vRect.height)
            let at = Double(horizontal ? caretWin[0] : caretWin[1]) - start
            let len = Double(horizontal ? caretWin[2] : caretWin[3])
            let margin = Double(vNode.el.scrollMarginPts)
            let delta = ScrollEdgeMath.reveal(offset: 0.0, top: at, height: len, viewport: view, margin: margin)
            if abs(delta) <= 1e-6 { continue }

            let vPath = vNode.path
            let maxExt = scrollMaxExtents[vPath] ?? .zero
            let old = scrollOffsets[vPath] ?? .zero
            let next: Vec2
            if horizontal {
                let x = Float((Double(old.x) + delta).clamped(to: 0.0...Double(maxExt.x)))
                next = Vec2(x, old.y)
            } else {
                let y = Float((Double(old.y) + delta).clamped(to: 0.0...Double(maxExt.y)))
                next = Vec2(old.x, y)
                if y < maxExt.y - 0.5 {
                    wasPinnedToBottom.remove(vPath)
                }
            }
            scrollOffsets[vPath] = next
            scrollStore.snap(NodeId.hash("scroll:" + vPath), Props.SCROLL, to: next)
        }
    }
}
