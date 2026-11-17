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
    public static func copySlice(in text: String, range: Range<Int>, uncopied: [Range<Int>], source: TextCaseMapping? = nil) -> String {
        validCopySlice(in: text, range: range, uncopied: uncopied, source: source) ?? ""
    }

    /// A malformed excluded byte edge invalidates the piece, so joining text must also skip its line break.
    internal static func validCopySlice(in text: String, range: Range<Int>, uncopied: [Range<Int>], source: TextCaseMapping?) -> String? {
        let len = text.utf8.count
        let a = max(0, min(len, SelectionMath.floorCharBoundary(in: text, offset: range.lowerBound)))
        let b = max(a, min(len, SelectionMath.floorCharBoundary(in: text, offset: range.upperBound)))
        guard a < b else { return "" }
        let bytes = (source?.authored ?? text).utf8
        func slice(_ lo: Int, _ hi: Int) -> String.UTF8View.SubSequence {
            let start = source?.sourceOffset(forDisplayedUTF8Offset: lo) ?? lo
            let end = source?.sourceOffset(forDisplayedUTF8Offset: hi, up: true) ?? hi
            let from = bytes.index(bytes.startIndex, offsetBy: start)
            return bytes[from..<bytes.index(from, offsetBy: end - start)]
        }
        if uncopied.isEmpty {
            return String(decoding: slice(a, b), as: UTF8.self)
        }
        func isCutBoundary(_ offset: Int) -> Bool {
            source != nil || SelectionMath.floorCharBoundary(in: text, offset: offset) == offset
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
                    guard isCutBoundary(cursor), isCutBoundary(hi) else { return nil }
                    outBytes.append(contentsOf: slice(cursor, hi))
                }
            }
            cursor = max(cursor, min(u.upperBound, b))
        }
        if cursor < b {
            guard isCutBoundary(cursor) else { return nil }
            outBytes.append(contentsOf: slice(cursor, b))
        }
        return String(decoding: outBytes, as: UTF8.self)
    }

    /// Joins `(rect, text)` pieces in tree order with `\t` for side-by-side items and `\n` otherwise.
    public static func join(_ pieces: [(rect: MotionRect, text: String)]) -> String {
        join(pieces.filter { !$0.text.isEmpty }.map { Entry(rect: $0.rect, pieceText: $0.text) })
    }

    /// Joins `Entry` pieces in tree order honoring `beside` tabs, `copyBreaks`, and `copyPrefix`,
    /// stopping once `cap` UTF-8 bytes are taken: a piece's lead that would pass it goes, and the
    /// piece that passes it is cut on a character boundary
    /// (`crates/rune/src/runtime/selection/copy_join.rs` `CopyJoin::push` / `finish`).
    public static func join(_ entries: [Entry], cap: Int = .max) -> String {
        var out = Builder()
        var prev: MotionRect? = nil
        for entry in entries {
            let isBeside = prev.map { beside($0, entry.rect) } ?? false
            prev = entry.rect
            let capped = out.push(
                entry.pieceText,
                fromStart: entry.fromStart,
                copyBreakBefore: entry.copyBreakBefore,
                copyBreakAfter: entry.copyBreakAfter,
                copyPrefix: entry.copyPrefix,
                beside: isBeside,
                cap: cap
            )
            if capped { break }
        }
        return out.finish()
    }

    /// `range` takes a text from its first copied byte (`copy_join.rs` `from_start`).
    public static func fromStart(range: Range<Int>, len: Int, uncopied: [Range<Int>]) -> Bool {
        let first = uncopied.isEmpty ? 0 : SelectionMath.trimUncopied(uncopied, range: (0, len)).0
        return !range.isEmpty && range.lowerBound <= first
    }

    /// Copied text, built a selected piece at a time (`copy_join.rs` `CopyJoin`).
    public struct Builder: Sendable {
        /// The text so far (`CopyJoin::text`).
        public private(set) var text = ""
        /// `text`'s length in UTF-8 bytes.
        public private(set) var byteCount = 0
        /// The newlines the last piece wants after it.
        private var after: UInt8 = 0
        private var pieces = 0
        /// The first piece's prefix, in bytes: a copy of one text alone goes without it.
        private var firstPrefix = 0

        public init() {}

        /// Adds `piece`, what the selected bytes of a text copy as (`CopyJoin::push`). `beside`: it
        /// sits beside the last piece, as a table row's next cell does; else as many newlines as
        /// the last piece's `copyBreakAfter` and this one's `copyBreakBefore` ask for (at least
        /// one, counting those already at the end). `fromStart`: the piece takes the text from its
        /// first copied byte, so its `copyPrefix` goes before it. `true` when `cap` bytes cut it
        /// short: a lead that would pass `cap` goes, and the piece that passes it is cut on a
        /// character boundary.
        @discardableResult
        public mutating func push(
            _ piece: String,
            fromStart: Bool,
            copyBreakBefore: UInt8,
            copyBreakAfter: UInt8,
            copyPrefix: String?,
            beside: Bool,
            cap: Int
        ) -> Bool {
            var lead = ""
            if pieces > 0 {
                if beside {
                    lead.append("\t")
                } else {
                    let want = Int(max(after, copyBreakBefore, 1))
                    var have = 0
                    for b in text.utf8.reversed() {
                        guard b == UInt8(ascii: "\n") else { break }
                        have += 1
                    }
                    if want > have { lead.append(String(repeating: "\n", count: want - have)) }
                }
            }
            let prefix = fromStart ? (copyPrefix ?? "") : ""
            if pieces == 0 { firstPrefix = prefix.utf8.count }
            lead.append(prefix)
            pieces += 1
            after = copyBreakAfter
            let leadBytes = lead.utf8.count
            if byteCount + leadBytes > cap { return true }
            text.append(lead)
            byteCount += leadBytes
            let pieceBytes = piece.utf8.count
            if byteCount + pieceBytes <= cap {
                text.append(piece)
                byteCount += pieceBytes
                return false
            }
            let take = SelectionMath.floorCharBoundary(in: piece, offset: max(0, cap - byteCount))
            text.append(String(decoding: piece.utf8.prefix(take), as: UTF8.self))
            byteCount += take
            return true
        }

        /// The copied text: a single text goes without its prefix (`CopyJoin::finish`).
        public func finish() -> String {
            guard pieces == 1, firstPrefix > 0, byteCount >= firstPrefix else { return text }
            return String(decoding: text.utf8.dropFirst(firstPrefix), as: UTF8.self)
        }
    }
}

/// Stateful coordinator for `El.selectable`, `El.selectionGroup`, `Tx.selectText`, `Cmd+A`
/// `SelectAll`, copy formatting (`El.selectionCopy` + `CopyJoin`), and `El.onSelectionChange`
/// coalescing (`crates/rune/src/runtime/selection/selectable.rs`).
public final class SelectionCoordinator {
    public internal(set) var phase: SelectionPhase = .empty {
        didSet {
            if case .empty = phase { cachedSnapshot = nil }
        }
    }
    public internal(set) var pick = SelectAllPick()
    internal private(set) var heardByPath: [String: TextSelection] = [:]

    private struct SnapshotBasis: Equatable {
        let commit: Int
        let path: String?
        let anchor: Int
        let focus: Int
        let farPath: String?
        let dragging: Bool
        let focusedPath: String?
    }

    private var cachedSnapshot: (basis: SnapshotBasis, selection: TextSelection?)?
    private var lastWatcherBasis: SnapshotBasis?

    private func snapshotBasis(commit: Int, focusedPath: String?) -> SnapshotBasis {
        let active = phase.selection
        return SnapshotBasis(commit: commit, path: active?.path, anchor: active?.anchor ?? 0,
                             focus: active?.focus ?? 0, farPath: active?.far?.path,
                             dragging: phase.isDragging, focusedPath: focusedPath)
    }

    internal func needsWatcherCheck(commit: Int, focusedPath: String?) -> Bool {
        let basis = snapshotBasis(commit: commit, focusedPath: focusedPath)
        guard lastWatcherBasis != basis else { return false }
        lastWatcherBasis = basis
        return true
    }

    /// Handlers reading the same committed selection share the collected rows and UTF-8 text.
    internal func snapshot(
        commit: Int,
        focusedPath: String?,
        collect: () -> TextSelection?
    ) -> TextSelection? {
        guard phase.selection != nil else { return nil }
        let basis = snapshotBasis(commit: commit, focusedPath: focusedPath)
        if let snapshot = cachedSnapshot, snapshot.basis == basis {
            return snapshot.selection
        }
        let selection = collect()
        cachedSnapshot = (basis, selection)
        return selection
    }

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
            let len = node.text.utf8.count
            let lo = SelectionMath.floorCharBoundary(in: node.text, offset: rawRange.lowerBound)
            let hi = max(lo, SelectionMath.floorCharBoundary(in: node.text, offset: rawRange.upperBound))
            guard lo < hi else { continue }
            let copied = CopyJoin.validCopySlice(in: node.text, range: lo..<hi, uncopied: node.uncopied, source: node.source)
            let slice = copied ?? ""
            let trimmed = SelectionMath.trimUncopied(node.uncopied, range: (0, len))
            let whole = len > 0 && lo <= trimmed.0 && hi >= trimmed.1
            let fromStart = lo <= trimmed.0
            let item = SelectedText(
                path: node.path,
                key: node.key,
                range: lo..<hi,
                len: len,
                whole: whole,
                text: slice,
                content: node.source == nil && node.uncopied.isEmpty ? slice : CopyJoin.copySlice(in: node.text, range: lo..<hi, uncopied: [])
            )
            selectedTexts.append(item)
            guard let copied else { continue }
            joinEntries.append(CopyJoin.Entry(
                rect: node.rect,
                pieceText: copied,
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
        guard let current = currentRanges(in: nodes) else { return nil }
        return buildSelection(ranges: current.ranges, backward: current.backward)
    }

    /// Paint uses these ranges directly, without constructing clipboard text or copying the selected bytes.
    internal func currentRanges(in nodes: [SelectableNodeSnapshot]) -> (ranges: [(SelectableNodeSnapshot, Range<Int>)], backward: Bool)? {
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
            let groups = SelectAllResolver.groupPaths(in: nodes)
            let gPath = groups[anchorIdx]
            var ranges: [(SelectableNodeSnapshot, Range<Int>)] = []
            for idx in firstIdx...lastIdx {
                let n = nodes[idx]
                guard n.isSelectable, groups[idx] == gPath else { continue }
                let len = n.text.utf8.count
                let lo = (idx == firstIdx) ? SelectionMath.floorCharBoundary(in: n.text, offset: aOff) : 0
                let hi = (idx == lastIdx) ? SelectionMath.floorCharBoundary(in: n.text, offset: bOff) : len
                if lo < hi {
                    ranges.append((n, lo..<hi))
                }
            }
            return ranges.isEmpty ? nil : (ranges, !forward)
        }
        let a = SelectionMath.floorCharBoundary(in: nodes[anchorIdx].text, offset: min(sel.anchor, sel.focus))
        let b = SelectionMath.floorCharBoundary(in: nodes[anchorIdx].text, offset: max(sel.anchor, sel.focus))
        guard a < b else { return nil }
        return ([(nodes[anchorIdx], a..<b)], sel.focus < sel.anchor)
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
        return collectSelectionChanges(elements: elements, selectedPaths: selectedPaths,
                                       released: false, selection: { active })
    }

    internal func collectSelectionChanges<State>(
        elements: [(path: String, el: El<State>)],
        selectedPaths: Set<String>,
        released: Bool,
        selection: () -> TextSelection?
    ) -> [(path: String, change: SelectionChange)] {
        let affected = Set(elements.compactMap { path, el in
            el.hasSelectionChangeHandler && selectedPaths.contains(where: { $0 == path || $0.hasPrefix(path + "/") })
                ? path : nil
        })
        let active = affected.isEmpty ? nil : selection()
        var nextHeard: [String: TextSelection] = [:]
        var out: [(path: String, change: SelectionChange)] = []
        var remaining = heardByPath
        var resolved: [(path: String, nowSel: TextSelection?, prevSel: TextSelection?)] = []

        for (path, el) in elements where el.hasSelectionChangeHandler {
            let nowSel = affected.contains(path) ? active : nil
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
            if !Self.sameSemanticSelection(prevSel, nowSel) || (released && nowSel != nil) {
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
