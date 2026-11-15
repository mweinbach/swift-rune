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

    /// Input piece for `CopyJoin.join(_:)` carrying copy break counts and optional list/quote prefix.
    public struct Entry: Sendable, Equatable {
        public var rect: MotionRect
        public var pieceText: String
        public var fromStart: Bool
        public var copyBreakBefore: UInt8
        public var copyBreakAfter: UInt8
        public var copyPrefix: String?

        public init(
            rect: MotionRect,
            pieceText: String,
            fromStart: Bool = true,
            copyBreakBefore: UInt8 = 1,
            copyBreakAfter: UInt8 = 1,
            copyPrefix: String? = nil
        ) {
            self.rect = rect
            self.pieceText = pieceText
            self.fromStart = fromStart
            self.copyBreakBefore = copyBreakBefore
            self.copyBreakAfter = copyBreakAfter
            self.copyPrefix = copyPrefix
        }
    }

    /// Strips any `uncopied` UTF-8 byte spans overlapping `range` in `text`
    /// (`crates/rune/src/el/text_spec.rs:306-318`).
    public static func copySlice(in text: String, range: Range<Int>, uncopied: [Range<Int>]) -> String {
        let len = text.utf8.count
        let a = max(0, min(len, SelectionMath.floorCharBoundary(in: text, offset: range.lowerBound)))
        let b = max(a, min(len, SelectionMath.floorCharBoundary(in: text, offset: range.upperBound)))
        guard a < b else { return "" }
        let bytes = Array(text.utf8)
        if uncopied.isEmpty {
            return String(decoding: bytes[a..<b], as: UTF8.self)
        }
        var outBytes: [UInt8] = []
        outBytes.reserveCapacity(b - a)
        var cursor = a
        for u in uncopied {
            if u.upperBound <= cursor { continue }
            if u.lowerBound >= b { break }
            if u.lowerBound > cursor {
                let hi = min(u.lowerBound, b)
                if cursor < hi {
                    outBytes.append(contentsOf: bytes[cursor..<hi])
                }
            }
            cursor = max(cursor, min(u.upperBound, b))
        }
        if cursor < b {
            outBytes.append(contentsOf: bytes[cursor..<b])
        }
        return String(decoding: outBytes, as: UTF8.self)
    }

    /// Joins `(rect, text)` pieces in tree order with `\t` for side-by-side items and `\n` otherwise.
    public static func join(_ pieces: [(rect: MotionRect, text: String)]) -> String {
        join(pieces.filter { !$0.text.isEmpty }.map { Entry(rect: $0.rect, pieceText: $0.text) })
    }

    /// Joins `Entry` pieces in tree order honoring `beside` tabs, `copyBreaks`, and `copyPrefix`
    /// (`crates/rune/src/runtime/selection/copy_join.rs:13-73`).
    public static func join(_ entries: [Entry]) -> String {
        var out = ""
        var prev: (rect: MotionRect, copyBreakAfter: UInt8)? = nil
        var pieces = 0
        var firstPrefixCount = 0

        for entry in entries {
            if let prev {
                if beside(prev.rect, entry.rect) {
                    out.append("\t")
                } else {
                    let want = max(Int(prev.copyBreakAfter), Int(entry.copyBreakBefore), 1)
                    var trailing = 0
                    for b in out.utf8.reversed() {
                        if b == UInt8(ascii: "\n") {
                            trailing += 1
                        } else {
                            break
                        }
                    }
                    if want > trailing {
                        out.append(String(repeating: "\n", count: want - trailing))
                    }
                }
            }
            if entry.fromStart, let prefix = entry.copyPrefix {
                if pieces == 0 {
                    firstPrefixCount = prefix.utf8.count
                }
                out.append(prefix)
            }
            out.append(entry.pieceText)
            prev = (entry.rect, entry.copyBreakAfter)
            pieces += 1
        }

        if pieces == 1 && firstPrefixCount > 0 {
            let bytes = Array(out.utf8)
            if bytes.count >= firstPrefixCount {
                return String(decoding: bytes[firstPrefixCount...], as: UTF8.self)
            }
        }
        return out
    }
}

/// Stateful coordinator for `El.selectable`, `El.selectionGroup`, `Tx.selectText`, `Cmd+A`
/// `SelectAll`, copy formatting (`El.selectionCopy` + `CopyJoin`), and `El.onSelectionChange`
/// coalescing (`crates/rune/src/runtime/selection/selectable.rs`).
public final class SelectionCoordinator {
    public internal(set) var phase: SelectionPhase = .empty
    public internal(set) var pick = SelectAllPick()
    internal private(set) var heardByPath: [String: TextSelection] = [:]

    /// Moves what the watcher at `old` heard to `new` (`sel_heard.by_path` re-keyed when the
    /// selection's text is rebound to a moved keyed path).
    internal func moveHeard(from old: String, to new: String) {
        if let v = heardByPath.removeValue(forKey: old) {
            heardByPath[new] = v
        }
    }

    public init() {}

    /// Builds a `TextSelection` from resolved per-node UTF-8 byte ranges in tree order.
    public func buildSelection(
        ranges: [(node: SelectableNodeSnapshot, range: Range<Int>)],
        backward: Bool = false
    ) -> TextSelection? {
        let nonEmpty = ranges.filter { $0.range.lowerBound < $0.range.upperBound }
        guard !nonEmpty.isEmpty else { return nil }
        var selectedTexts: [SelectedText] = []
        var joinEntries: [CopyJoin.Entry] = []
        selectedTexts.reserveCapacity(nonEmpty.count)
        joinEntries.reserveCapacity(nonEmpty.count)
        for (node, rawRange) in nonEmpty {
            let utf8 = Array(node.text.utf8)
            let lo = SelectionMath.floorCharBoundary(in: node.text, offset: rawRange.lowerBound)
            let hi = max(lo, SelectionMath.floorCharBoundary(in: node.text, offset: rawRange.upperBound))
            guard lo < hi else { continue }
            let slice = CopyJoin.copySlice(in: node.text, range: lo..<hi, uncopied: node.uncopied)
            let trimmed = SelectionMath.trimUncopied(node.uncopied, range: (0, utf8.count))
            let whole = !utf8.isEmpty && lo <= trimmed.0 && hi >= trimmed.1
            let fromStart = lo <= trimmed.0
            let item = SelectedText(
                path: node.path,
                key: node.key,
                range: lo..<hi,
                len: utf8.count,
                whole: whole,
                text: slice,
                content: node.text
            )
            selectedTexts.append(item)
            joinEntries.append(CopyJoin.Entry(
                rect: node.rect,
                pieceText: slice,
                fromStart: fromStart,
                copyBreakBefore: node.copyBreakBefore,
                copyBreakAfter: node.copyBreakAfter,
                copyPrefix: node.copyPrefix
            ))
        }
        guard !selectedTexts.isEmpty else { return nil }
        return TextSelection(
            texts: selectedTexts,
            text: CopyJoin.join(joinEntries),
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
        let a = SelectionMath.floorCharBoundary(in: node.text, offset: range.lowerBound)
        let b = max(a, SelectionMath.floorCharBoundary(in: node.text, offset: range.upperBound))
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

    /// Programmatically selects all non-empty selectable text nodes under `key` (matching either a
    /// single selectable text node, a container element, or a `selectionGroup`) (`Tx::select_all_text`).
    @discardableResult
    public func selectAllText(
        key: String,
        in nodes: [SelectableNodeSnapshot]
    ) -> TextSelection? {
        guard let targetIdx = nodes.firstIndex(where: { $0.key == key || $0.path == key }) else {
            return nil
        }
        let targetPath = nodes[targetIdx].path
        let byPath = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.path, $0.offset) })
        func isWithinTarget(_ idx: Int) -> Bool {
            var cur: Int? = idx
            while let i = cur {
                if nodes[i].path == targetPath { return true }
                cur = nodes[i].parentPath.flatMap { byPath[$0] }
            }
            return false
        }
        let selectedNodes = nodes.enumerated().compactMap { idx, node -> SelectableNodeSnapshot? in
            guard node.isSelectable, !node.text.isEmpty, isWithinTarget(idx) else { return nil }
            return node
        }
        guard let first = selectedNodes.first, let last = selectedNodes.last else {
            phase.clear()
            return nil
        }
        let far: SelectionFar? = (first.path == last.path)
            ? nil
            : SelectionFar(path: last.path, content: last.text)
        let firstNodesIdx = nodes.firstIndex(of: first) ?? 0
        let lastNodesIdx = nodes.firstIndex(of: last) ?? firstNodesIdx
        let betweenHash = far == nil
            ? 0
            : SelectionMath.computeBetweenHash(in: nodes, anchorIdx: firstNodesIdx, farIdx: lastNodesIdx)
        phase.place(ActiveSelection(
            path: first.path,
            content: first.text,
            anchor: 0,
            focus: last.text.utf8.count,
            origin: (0, last.text.utf8.count),
            far: far,
            betweenHash: betweenHash
        ))
        if let group = SelectAllResolver.groupPath(forNodeAt: firstNodesIdx, in: nodes) {
            pick.noteClick(groupPath: group)
        }
        let ranges = selectedNodes.map { ($0, 0..<$0.text.utf8.count) }
        return buildSelection(ranges: ranges, backward: false)
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
           let firstIdx = nodes.firstIndex(where: { $0.path == firstPath }),
           let lastIdx = nodes.firstIndex(where: { $0.path == lastPath }) {
            let first = nodes[firstIdx]
            let last = nodes[lastIdx]
            let far: SelectionFar? = (first.path == last.path)
                ? nil
                : SelectionFar(path: last.path, content: last.text)
            let betweenHash = far == nil
                ? 0
                : SelectionMath.computeBetweenHash(in: nodes, anchorIdx: firstIdx, farIdx: lastIdx)
            phase.place(ActiveSelection(
                path: first.path,
                content: first.text,
                anchor: 0,
                focus: last.text.utf8.count,
                origin: (0, last.text.utf8.count),
                far: far,
                betweenHash: betweenHash
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
                let lo = (idx == firstIdx) ? SelectionMath.floorCharBoundary(in: n.text, offset: aOff) : 0
                let hi = (idx == lastIdx) ? SelectionMath.floorCharBoundary(in: n.text, offset: bOff) : len
                if lo < hi {
                    ranges.append((n, lo..<hi))
                }
            }
            return buildSelection(ranges: ranges, backward: !forward)
        }
        let a = SelectionMath.floorCharBoundary(in: nodes[anchorIdx].text, offset: min(sel.anchor, sel.focus))
        let b = SelectionMath.floorCharBoundary(in: nodes[anchorIdx].text, offset: max(sel.anchor, sel.focus))
        guard a < b else { return nil }
        return buildSelection(ranges: [(nodes[anchorIdx], a..<b)], backward: sel.focus < sel.anchor)
    }

    private static func sameSemanticSelection(_ a: TextSelection?, _ b: TextSelection?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            guard lhs.backward == rhs.backward,
                  lhs.text == rhs.text,
                  lhs.texts.count == rhs.texts.count else {
                return false
            }
            for (x, y) in zip(lhs.texts, rhs.texts) {
                guard x.range == y.range, x.text == y.text, x.whole == y.whole else {
                    return false
                }
                if let kx = x.key, let ky = y.key {
                    if kx != ky { return false }
                } else if x.path != y.path && !SelectionMath.sameKeyedPath(x.path, y.path) {
                    return false
                }
            }
            return true
        default:
            return false
        }
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
        var remaining = heardByPath
        var resolved: [(path: String, nowSel: TextSelection?, prevSel: TextSelection?)] = []

        for (path, el) in elements where el.hasSelectionChangeHandler {
            let hitsSubtree = selectedPaths.contains(where: { $0 == path || $0.hasPrefix(path + "/") })
            let nowSel = hitsSubtree ? active : nil
            let exactOrKeyed = remaining.removeValue(forKey: path) ?? {
                if let oldKey = remaining.keys.first(where: { SelectionMath.sameKeyedPath($0, path) }) {
                    return remaining.removeValue(forKey: oldKey)
                }
                return nil
            }()
            resolved.append((path, nowSel, exactOrKeyed))
        }

        for (path, nowSel, directPrev) in resolved {
            var prevSel = directPrev
            if prevSel == nil, let nowSel,
               let fallbackKey = remaining.keys.first(where: { Self.sameSemanticSelection(remaining[$0], nowSel) }) {
                prevSel = remaining.removeValue(forKey: fallbackKey)
            }
            if !Self.sameSemanticSelection(prevSel, nowSel) {
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
