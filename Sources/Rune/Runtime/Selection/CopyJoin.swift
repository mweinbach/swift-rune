import Foundation
import RuneMotion

/// Joins multi-element selectable text ranges into clipboard text using newlines between stacked
/// elements and tabs between side-by-side cells (`crates/rune/src/runtime/selection/copy_join.rs` &
/// `selectable.rs:508-525`).
public enum CopyJoin {
    /// True when `current` lies visually beside `previous` on the same horizontal band (table cells).
    public static func beside(_ previous: MotionRect, _ current: MotionRect) -> Bool {
        current.top < previous.bottom - 0.5 && (current.left >= previous.right - 0.5 || current.right <= previous.left + 0.5)
    }

    /// Joins `(rect, text)` pieces in tree order with `\t` for side-by-side items and `\n` otherwise.
    public static func join(_ pieces: [(rect: MotionRect, text: String)]) -> String {
        var out = ""
        var prevRect: MotionRect? = nil
        for piece in pieces where !piece.text.isEmpty {
            if let prev = prevRect {
                out.append(beside(prev, piece.rect) ? "\t" : "\n")
            }
            out.append(piece.text)
            prevRect = piece.rect
        }
        return out
    }
}

/// Stateful coordinator for `El.selectable`, `El.selectionGroup`, `Tx.selectText`, `Cmd+A`
/// `SelectAll`, copy formatting (`El.selectionCopy` + `CopyJoin`), and `El.onSelectionChange`
/// coalescing (`crates/rune/src/runtime/selection/selectable.rs`).
public final class SelectionCoordinator {
    public private(set) var phase: SelectionPhase = .empty
    public private(set) var pick = SelectAllPick()
    private var heardByPath: [String: TextSelection] = [:]

    public init() {}

    /// Builds a `TextSelection` from resolved per-node UTF-8 byte ranges in tree order.
    public func buildSelection(
        ranges: [(node: SelectableNodeSnapshot, range: Range<Int>)],
        backward: Bool = false
    ) -> TextSelection? {
        let nonEmpty = ranges.filter { $0.range.lowerBound < $0.range.upperBound }
        guard !nonEmpty.isEmpty else { return nil }
        var selectedTexts: [SelectedText] = []
        var joinInputs: [(rect: MotionRect, text: String)] = []
        selectedTexts.reserveCapacity(nonEmpty.count)
        joinInputs.reserveCapacity(nonEmpty.count)
        for (node, rawRange) in nonEmpty {
            let utf8 = Array(node.text.utf8)
            let lo = max(0, min(rawRange.lowerBound, utf8.count))
            let hi = max(lo, min(rawRange.upperBound, utf8.count))
            guard lo < hi else { continue }
            let slice = String(decoding: utf8[lo..<hi], as: UTF8.self)
            let item = SelectedText(
                path: node.path,
                key: node.key,
                range: lo..<hi,
                len: utf8.count,
                whole: lo == 0 && hi == utf8.count && !utf8.isEmpty,
                text: slice,
                content: node.text
            )
            selectedTexts.append(item)
            joinInputs.append((node.rect, slice))
        }
        guard !selectedTexts.isEmpty else { return nil }
        return TextSelection(
            texts: selectedTexts,
            text: CopyJoin.join(joinInputs),
            backward: backward
        )
    }

    /// Programmatically applies `Tx.selectText(key:range:)` on `nodes`, returning the resulting `TextSelection`.
    @discardableResult
    public func selectText(
        key: String,
        range: Range<Int>,
        in nodes: [SelectableNodeSnapshot]
    ) -> TextSelection? {
        guard let node = nodes.first(where: { $0.isSelectable && ($0.key == key || $0.path == key) }) else {
            return nil
        }
        let len = node.text.utf8.count
        let a = max(0, min(range.lowerBound, len))
        let b = max(a, min(range.upperBound, len))
        guard a < b else {
            phase.clear()
            return nil
        }
        phase.place(ActiveSelection(
            path: node.path,
            content: node.text,
            anchor: a,
            focus: b,
            origin: (a, b)
        ))
        if let group = SelectAllResolver.groupPath(
            forNodeAt: nodes.firstIndex(of: node) ?? 0,
            in: nodes
        ) {
            pick.noteClick(groupPath: group)
        }
        return buildSelection(ranges: [(node, a..<b)], backward: false)
    }

    /// Resolves `Cmd+A` on `nodes`, updating `phase` and `pick` when a group is selected.
    @discardableResult
    public func handleSelectAll(
        in nodes: [SelectableNodeSnapshot],
        appHandledCmdA: Bool = false
    ) -> SelectAllOutcome {
        let outcome = SelectAllResolver.resolve(nodes: nodes, pick: &pick, appHandledCmdA: appHandledCmdA)
        if case .selectGroup(_, let paths, _) = outcome,
           let firstPath = paths.first,
           let lastPath = paths.last,
           let first = nodes.first(where: { $0.path == firstPath }),
           let last = nodes.first(where: { $0.path == lastPath }) {
            let far: SelectionFar? = (first.path == last.path)
                ? nil
                : SelectionFar(path: last.path, content: last.text)
            phase.place(ActiveSelection(
                path: first.path,
                content: first.text,
                anchor: 0,
                focus: last.text.utf8.count,
                origin: (0, last.text.utf8.count),
                far: far
            ))
        }
        return outcome
    }

    /// Computes active `TextSelection` for the current `phase` against mounted `nodes`.
    public func currentSelection(in nodes: [SelectableNodeSnapshot]) -> TextSelection? {
        guard let sel = phase.selection else { return nil }
        guard let anchorIdx = nodes.firstIndex(where: { $0.path == sel.path && $0.isSelectable }) else {
            return nil
        }
        guard SelectionMath.kept(then: sel.content, now: nodes[anchorIdx].text, upto: min(sel.anchor, sel.focus)) else {
            return nil
        }
        if let far = sel.far,
           let focusIdx = nodes.firstIndex(where: { $0.path == far.path && $0.isSelectable }),
           anchorIdx != focusIdx {
            let forward = anchorIdx < focusIdx
            let (firstIdx, aOff, lastIdx, bOff) = forward
                ? (anchorIdx, sel.anchor, focusIdx, sel.focus)
                : (focusIdx, sel.focus, anchorIdx, sel.anchor)
            let gPath = SelectAllResolver.groupPath(forNodeAt: anchorIdx, in: nodes)
            var ranges: [(SelectableNodeSnapshot, Range<Int>)] = []
            for idx in firstIdx...lastIdx {
                let n = nodes[idx]
                guard n.isSelectable, SelectAllResolver.groupPath(forNodeAt: idx, in: nodes) == gPath else { continue }
                let len = n.text.utf8.count
                let lo = (idx == firstIdx) ? min(aOff, len) : 0
                let hi = (idx == lastIdx) ? min(bOff, len) : len
                if lo < hi {
                    ranges.append((n, lo..<hi))
                }
            }
            return buildSelection(ranges: ranges, backward: !forward)
        }
        let len = nodes[anchorIdx].text.utf8.count
        let a = min(sel.anchor, sel.focus).clamped(to: 0...len)
        let b = max(sel.anchor, sel.focus).clamped(to: 0...len)
        guard a < b else { return nil }
        return buildSelection(ranges: [(nodes[anchorIdx], a..<b)], backward: sel.focus < sel.anchor)
    }

    /// Evaluates which `onSelectionChange` watcher paths should fire for the current selection.
    public func collectSelectionChanges<State>(
        elements: [(path: String, el: El<State>)],
        nodes: [SelectableNodeSnapshot]
    ) -> [(path: String, change: SelectionChange)] {
        let active = currentSelection(in: nodes)
        let selectedPaths = Set(active?.texts.map(\.path) ?? [])
        var nextHeard: [String: TextSelection] = [:]
        var out: [(path: String, change: SelectionChange)] = []

        for (path, el) in elements where el.hasSelectionChangeHandler {
            let hitsSubtree = selectedPaths.contains(where: { $0 == path || $0.hasPrefix(path + "/") })
            let nowSel = hitsSubtree ? active : nil
            let prevSel = heardByPath.removeValue(forKey: path) ?? {
                if let oldKey = heardByPath.keys.first(where: { SelectionMath.sameKeyedPath($0, path) }) {
                    return heardByPath.removeValue(forKey: oldKey)
                }
                return nil
            }()
            if prevSel != nowSel {
                out.append((
                    path,
                    SelectionChange(selection: nowSel, was: prevSel != nil, isDragging: phase.isDragging)
                ))
            }
            if let nowSel {
                nextHeard[path] = nowSel
            }
        }
        heardByPath = nextHeard
        return out
    }
}
