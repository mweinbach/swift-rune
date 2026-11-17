import Foundation
import Rune

/// Outcome of handling a key event in `TreeModel` (`rune_kit::tree::TreeKey`).
public enum TreeKey: Sendable, Equatable, Hashable {
    /// Not a tree key; propagates to the parent/window.
    case ignored
    /// Moved cursor, selection, or toggled a folder.
    case handled
    /// Enter or Space on a leaf node: the app should open this id.
    case open(String)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.ignored, .ignored), (.handled, .handled): return true
        case let (.open(a), .open(b)): return a.utf8.elementsEqual(b.utf8)
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .ignored: hasher.combine(0)
        case .handled: hasher.combine(1)
        case .open(let id):
            hasher.combine(2)
            hasher.combine(KitSourceKey(id))
        }
    }
}

/// A visible row's state as `Tree` draws it (`rune_kit::tree::TreeRow`).
public struct TreeRow: Sendable, Equatable {
    public var id: String
    /// 0 at the top level.
    public var depth: UInt32
    /// `true`/`false` for a row with visible children, `nil` for a leaf.
    public var expanded: Bool?
    public var selected: Bool
    /// Whether the keyboard cursor is on this row.
    public var cursor: Bool
    /// Whether an active filter matched this node directly.
    public var matched: Bool
    internal var multi: Bool

    public init(
        id: String,
        depth: UInt32,
        expanded: Bool? = nil,
        selected: Bool = false,
        cursor: Bool = false,
        matched: Bool = false,
        multi: Bool = false
    ) {
        self.id = id
        self.depth = depth
        self.expanded = expanded
        self.selected = selected
        self.cursor = cursor
        self.matched = matched
        self.multi = multi
    }

    public func expanded(_ open: Bool?) -> TreeRow {
        var copy = self
        copy.expanded = open
        return copy
    }

    public func selected(_ on: Bool) -> TreeRow {
        var copy = self
        copy.selected = on
        return copy
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id.utf8.elementsEqual(rhs.id.utf8) && lhs.depth == rhs.depth &&
            lhs.expanded == rhs.expanded && lhs.selected == rhs.selected && lhs.cursor == rhs.cursor &&
            lhs.matched == rhs.matched && lhs.multi == rhs.multi
    }
}

/// Virtualised outline model owning nodes, open/closed folders, selection, filter, and keyboard cursor
/// (`rune_kit::tree::TreeModel`).
public struct TreeModel<T: Sendable>: Sendable {
    private struct Node: Sendable {
        var id: String
        var data: T
        var parent: Int?
        var children: [Int]
        var depth: UInt32
        var open: Bool
    }

    private enum Shown: Sendable, Equatable {
        case hidden
        case path
        case match
    }

    private struct Filter: Sendable {
        var shown: [Shown]
        /// Folders the user explicitly closed while filtering (all others show open).
        var closed: [Bool]
    }

    private struct Visible: Sendable {
        let version = UUID()
        var rows: [Int] = []
        var rowOf: [Int] = []
    }

    private final class CacheBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: Visible?

        func getOrBuild(_ build: () -> Visible) -> Visible {
            lock.lock()
            defer { lock.unlock() }
            if let cached { return cached }
            let built = build()
            cached = built
            return built
        }

        func invalidate() {
            lock.lock()
            cached = nil
            lock.unlock()
        }
    }

    private enum TypeAhead: Sendable {
        case idle
        case typing(prefix: String, at: Double)

        mutating func step(_ text: String, now: Double) -> String {
            let paused: Bool = switch self {
            case .typing(_, let at): now - at > TreeModel.typePause
            case .idle: true
            }
            var prefix: String = switch self {
            case .typing(let prev, _) where !paused: prev
            default: ""
            }
            prefix.append(text.lowercased())
            self = .typing(prefix: prefix, at: now)
            return prefix
        }
    }

    /// Seconds of pause after which typing starts a new type-select prefix (AppKit default).
    private static var typePause: Double { 1.0 }

    private var nodes: [Node] = []
    private var index: [KitSourceKey: Int] = [:]
    private var roots: [Int] = []
    private var cursorIndex: Int?
    private var anchorIndex: Int?
    private var selectedIndices: Set<Int> = []
    private var multi: Bool = false
    private var activeFilter: Filter?
    private var cache = CacheBox()
    private var typeAhead: TypeAhead = .idle
    public var key: String = "tree"
    public var viewport: Float = 0.0
    public var rowHeight: Float = 24.0
    public var rtl: Bool = false

    public init(key: String = "tree", multiSelect: Bool = false) {
        self.key = key
        self.multi = multiSelect
    }

    public func key(_ key: String) -> TreeModel<T> {
        var copy = self
        copy.key = key
        return copy
    }

    public func multiSelect(_ on: Bool) -> TreeModel<T> {
        var copy = self
        copy.multi = on
        return copy
    }

    public mutating func setRightToLeft(_ rtl: Bool) {
        self.rtl = rtl
    }

    private mutating func dirty() {
        if isKnownUniquelyReferenced(&cache) {
            cache.invalidate()
        } else {
            cache = CacheBox()
        }
    }

    /// Inserts `id` under `parent` (`nil` for top level) after its siblings.
    /// Returns `false` if `id` already exists or `parent` is missing.
    @discardableResult
    public mutating func insert(parent: String?, id: String, data: T) -> Bool {
        let exactID = KitSourceKey(id)
        if index[exactID] != nil {
            return false
        }
        let parentIdx: Int?
        if let parent {
            guard let p = index[KitSourceKey(parent)] else { return false }
            parentIdx = p
        } else {
            parentIdx = nil
        }

        let i = nodes.count
        let depth = parentIdx.map { nodes[$0].depth + 1 } ?? 0
        if let p = parentIdx {
            nodes[p].children.append(i)
        } else {
            roots.append(i)
        }
        index[exactID] = i
        nodes.append(Node(id: id, data: data, parent: parentIdx, children: [], depth: depth, open: false))
        if activeFilter != nil {
            activeFilter?.shown.append(.hidden)
            activeFilter?.closed.append(false)
        }
        dirty()
        return true
    }

    /// Removes every node, selection, and filter while preserving configuration (`key`, `multi`, `viewport`, `rowHeight`).
    public mutating func clear() {
        let savedKey = key
        let savedMulti = multi
        let savedViewport = viewport
        let savedRowHeight = rowHeight
        self = TreeModel<T>(key: savedKey, multiSelect: savedMulti)
        self.viewport = savedViewport
        self.rowHeight = savedRowHeight
    }

    public var count: Int { nodes.count }
    public var isEmpty: Bool { nodes.isEmpty }

    public func contains(_ id: String) -> Bool {
        index[KitSourceKey(id)] != nil
    }

    public func get(_ id: String) -> T? {
        index[KitSourceKey(id)].map { nodes[$0].data }
    }

    public mutating func update(_ id: String, _ body: (inout T) -> Void) {
        guard let i = index[KitSourceKey(id)] else { return }
        body(&nodes[i].data)
    }

    public func parent(of id: String) -> String? {
        guard let i = index[KitSourceKey(id)], let p = nodes[i].parent else { return nil }
        return nodes[p].id
    }

    public func children(of id: String?) -> [String] {
        let list: [Int]
        if let id {
            guard let i = index[KitSourceKey(id)] else { return [] }
            list = nodes[i].children
        } else {
            list = roots
        }
        return list.map { nodes[$0].id }
    }

    public func hasChildren(_ id: String) -> Bool {
        guard let i = index[KitSourceKey(id)] else { return false }
        return !nodes[i].children.isEmpty
    }

    public func depth(of id: String) -> UInt32? {
        index[KitSourceKey(id)].map { nodes[$0].depth }
    }

    public func subtree(of id: String) -> [T] {
        guard let start = index[KitSourceKey(id)] else { return [] }
        var result: [T] = []
        var stack: [Int] = [start]
        while let i = stack.popLast() {
            result.append(nodes[i].data)
            stack.append(contentsOf: nodes[i].children.reversed())
        }
        return result
    }

    /// Sorts every node's children and the top-level roots using `cmp`.
    public mutating func sortBy(_ cmp: (T, T) -> ComparisonResult) {
        sortBy { a, b in
            cmp(a, b) == .orderedAscending
        }
    }

    /// Sorts every node's children and the top-level roots using a strict weak ordering predicate.
    public mutating func sortBy(_ areInIncreasingOrder: (T, T) -> Bool) {
        let snapshot = nodes
        for i in nodes.indices {
            nodes[i].children.sort { a, b in
                areInIncreasingOrder(snapshot[a].data, snapshot[b].data)
            }
        }
        roots.sort { a, b in
            areInIncreasingOrder(snapshot[a].data, snapshot[b].data)
        }
        dirty()
    }

    // MARK: - Open Folders

    public func isExpanded(_ id: String) -> Bool {
        guard let i = index[KitSourceKey(id)] else { return false }
        return isOpen(i)
    }

    private func isOpen(_ i: Int) -> Bool {
        if let filter = activeFilter {
            return !filter.closed[i]
        }
        return nodes[i].open
    }

    private mutating func setOpen(_ i: Int, _ open: Bool) {
        if activeFilter != nil {
            activeFilter?.closed[i] = !open
        } else {
            nodes[i].open = open
        }
        if !open {
            if let c = cursorIndex, isUnder(c, ancestor: i) {
                if !multi && selectedIndices.contains(c) {
                    selectOnly(i)
                } else {
                    cursorIndex = i
                }
            }
            if let a = anchorIndex, isUnder(a, ancestor: i) {
                anchorIndex = i
            }
        }
        dirty()
    }

    private func isUnder(_ node: Int, ancestor: Int) -> Bool {
        var cur = node
        while let p = nodes[cur].parent {
            if p == ancestor { return true }
            cur = p
        }
        return false
    }

    public mutating func setExpanded(_ id: String, _ open: Bool) {
        guard let i = index[KitSourceKey(id)] else { return }
        setOpen(i, open)
    }

    public mutating func toggle(_ id: String) {
        guard let i = index[KitSourceKey(id)] else { return }
        setOpen(i, !isOpen(i))
    }

    public mutating func expandAll() {
        for i in nodes.indices where !nodes[i].children.isEmpty {
            setOpen(i, true)
        }
    }

    public mutating func collapseAll() {
        for i in nodes.indices {
            setOpen(i, false)
        }
    }

    public mutating func expandTo(_ id: String) {
        guard let i = index[KitSourceKey(id)] else { return }
        if activeFilter != nil {
            if activeFilter?.shown[i] == .hidden {
                activeFilter?.shown[i] = .match
            }
            var p = nodes[i].parent
            while let j = p {
                if activeFilter?.shown[j] == .hidden {
                    activeFilter?.shown[j] = .path
                }
                p = nodes[j].parent
            }
            dirty()
        }
        var p = nodes[i].parent
        while let j = p {
            nodes[j].open = true
            setOpen(j, true)
            p = nodes[j].parent
        }
    }

    // MARK: - Selection

    /// Selected ids in tree order.
    public var selectedIDs: [String] {
        if selectedIndices.count <= 1 {
            return selectedIndices.map { nodes[$0].id }
        }
        var out: [String] = []
        out.reserveCapacity(selectedIndices.count)
        var stack: [Int] = Array(roots.reversed())
        while let i = stack.popLast() {
            if selectedIndices.contains(i) {
                out.append(nodes[i].id)
            }
            stack.append(contentsOf: nodes[i].children.reversed())
        }
        return out
    }

    public func isSelected(_ id: String) -> Bool {
        index[KitSourceKey(id)].map(selectedIndices.contains) ?? false
    }

    public var cursorID: String? {
        cursorIndex.map { nodes[$0].id }
    }

    /// Selected item IDs in tree pre-order (`TreeModel::selected`).
    public func selected() -> [String] { selectedIDs }

    /// Current keyboard cursor item ID (`TreeModel::cursor`).
    public func cursor() -> String? { cursorID }

    public mutating func clearSelection() {
        selectedIndices.removeAll()
    }

    public mutating func select(_ id: String) {
        guard let i = index[KitSourceKey(id)] else { return }
        selectOnly(i)
    }

    private mutating func selectOnly(_ i: Int) {
        selectedIndices = [i]
        cursorIndex = i
        anchorIndex = i
    }

    public mutating func setSelected(_ id: String, _ on: Bool) {
        guard let i = index[KitSourceKey(id)] else { return }
        if !multi {
            clearSelection()
        }
        if on { selectedIndices.insert(i) } else { selectedIndices.remove(i) }
        cursorIndex = i
        anchorIndex = i
    }

    public mutating func selectRange(to id: String) {
        guard let i = index[KitSourceKey(id)] else { return }
        if !multi {
            selectOnly(i)
            return
        }
        let anchor = anchorIndex ?? i
        let vis = visibleRows()
        let a = vis.rowOf[anchor]
        let b = vis.rowOf[i]
        if a == Int.max || b == Int.max {
            selectOnly(i)
            return
        }
        let lo = min(a, b)
        let hi = max(a, b)
        selectedIndices = Set(vis.rows[lo...hi])
        cursorIndex = i
    }

    /// Handles a row click with modifier keys. Returns `true` if it was a plain click.
    @discardableResult
    public mutating func click(_ id: String, mods: Mods = .none) -> Bool {
        guard let i = index[KitSourceKey(id)] else { return false }
        if multi && mods.shift {
            selectRange(to: id)
            return false
        }
        if multi && mods.primaryCommand {
            if !selectedIndices.insert(i).inserted { selectedIndices.remove(i) }
            cursorIndex = i
            anchorIndex = i
            return false
        }
        selectOnly(i)
        return true
    }

    /// Expands ancestors of `id`, selects it alone, and scrolls it into view.
    @discardableResult
    public mutating func reveal(_ id: String, tx: inout Tx) -> Bool {
        guard contains(id) else { return false }
        expandTo(id)
        select(id)
        tx.scrollIntoViewIn(key, id)
        return true
    }

    // MARK: - Filter

    public mutating func filter(_ keep: (T) -> Bool) {
        let n = nodes.count
        var shown = [Shown](repeating: .hidden, count: n)
        for i in 0..<n {
            if keep(nodes[i].data) {
                shown[i] = .match
                var p = nodes[i].parent
                while let j = p {
                    if shown[j] != .hidden { break }
                    shown[j] = .path
                    p = nodes[j].parent
                }
            }
        }
        activeFilter = Filter(shown: shown, closed: [Bool](repeating: false, count: n))
        dirty()
        let vis = visibleRows()
        let hideCursor = cursorIndex.map { vis.rowOf[$0] == Int.max } ?? false
        let hideAnchor = anchorIndex.map { vis.rowOf[$0] == Int.max } ?? false
        if hideCursor {
            cursorIndex = nil
        }
        if hideAnchor {
            anchorIndex = cursorIndex
        }
    }

    public mutating func clearFilter() {
        if activeFilter != nil {
            activeFilter = nil
            dirty()
        }
    }

    public var isFiltering: Bool { activeFilter != nil }

    public func isMatch(_ id: String) -> Bool {
        guard let i = index[KitSourceKey(id)] else { return false }
        return activeFilter.map { $0.shown[i] == .match } ?? true
    }

    // MARK: - Visible Rows

    private func visibleRows() -> Visible {
        cache.getOrBuild {
            var v = Visible(rows: [], rowOf: [Int](repeating: Int.max, count: nodes.count))
            var stack: [Int] = Array(roots.reversed())
            while let i = stack.popLast() {
                if !isShown(i) { continue }
                v.rowOf[i] = v.rows.count
                v.rows.append(i)
                if isOpen(i) {
                    stack.append(contentsOf: nodes[i].children.reversed())
                }
            }
            return v
        }
    }

    private func isShown(_ i: Int) -> Bool {
        activeFilter.map { $0.shown[i] != .hidden } ?? true
    }

    private func isOpenable(_ i: Int) -> Bool {
        nodes[i].children.contains { isShown($0) }
    }

    /// The row-key sequence only changes when the flattened visible index is rebuilt.
    internal var visibleOrderVersion: UUID { visibleRows().version }

    public var visibleCount: Int {
        visibleRows().rows.count
    }

    public func visibleID(at row: Int) -> String? {
        let rows = visibleRows().rows
        guard row >= 0 && row < rows.count else { return nil }
        return nodes[rows[row]].id
    }

    public func visibleRow(of id: String) -> Int? {
        guard let i = index[KitSourceKey(id)] else { return nil }
        let r = visibleRows().rowOf[i]
        return r == Int.max ? nil : r
    }

    public func row(at row: Int) -> (data: T, row: TreeRow)? {
        let rows = visibleRows().rows
        guard row >= 0 && row < rows.count else { return nil }
        let i = rows[row]
        let n = nodes[i]
        let state = TreeRow(
            id: n.id,
            depth: n.depth,
            expanded: isOpenable(i) ? isOpen(i) : nil,
            selected: selectedIndices.contains(i),
            cursor: cursorIndex == i,
            matched: activeFilter.map { $0.shown[i] == .match } ?? false,
            multi: multi
        )
        return (n.data, state)
    }

    // MARK: - Keyboard

    private mutating func moveTo(_ i: Int, extend: Bool) {
        if extend && multi {
            selectRange(to: nodes[i].id)
        } else {
            selectOnly(i)
        }
    }

    /// Handles a keyboard event using tree navigation rules.
    public mutating func handleKey(
        _ ev: KeyEvent,
        label: (T) -> String,
        tx: inout Tx,
        clock: Double? = nil,
        keyRepeat: Bool = false
    ) -> TreeKey {
        let m = ev.mods
        let selectAll = multi && m.primaryAlone && (ev.key == .command("a") || (m.primaryCommand && ev.isCommand("a")))
        if !selectAll && (m.cmd || m.ctrl || m.alt || m.logo) {
            return .ignored
        }
        let vis = visibleRows()
        let len = vis.rows.count
        if len == 0 {
            return .ignored
        }
        if selectAll {
            selectedIndices.formUnion(vis.rows)
            return .handled
        }
        let at: Int? = cursorIndex.flatMap { c in
            let r = vis.rowOf[c]
            return r == Int.max ? nil : r
        }
        let rh = max(1.0, rowHeight)
        let page = max(1, Int((viewport / rh).rounded(.down)) - 1)

        let logicalKey: Key = switch (ev.key, rtl) {
        case (.arrowLeft, true): .arrowRight
        case (.arrowRight, true): .arrowLeft
        default: ev.key
        }

        let target: Int?
        switch logicalKey {
        case .arrowUp:
            target = at.map { max(0, $0 - 1) } ?? (len - 1)
        case .arrowDown:
            target = at.map { min(len - 1, $0 + 1) } ?? 0
        case .home:
            target = 0
        case .end:
            target = len - 1
        case .pageUp:
            target = at.map { max(0, $0 - page) } ?? 0
        case .pageDown:
            target = at.map { min(len - 1, $0 + page) } ?? 0
        case .arrowRight where m.shift, .arrowLeft where m.shift:
            target = nil
        case .arrowRight:
            guard let r = at else { return go(row: 0, extend: false, tx: &tx) }
            let i = vis.rows[r]
            if !isOpenable(i) {
                return .handled
            }
            if !isOpen(i) {
                setOpen(i, true)
                return .handled
            }
            target = min(len - 1, r + 1)
        case .arrowLeft:
            guard let r = at else { return go(row: 0, extend: false, tx: &tx) }
            let i = vis.rows[r]
            if isOpenable(i) && isOpen(i) {
                setOpen(i, false)
                return .handled
            }
            if let p = nodes[i].parent {
                let pr = vis.rowOf[p]
                target = pr == Int.max ? nil : pr
                if target == nil { return .handled }
            } else {
                return .handled
            }
        case .enter, .space:
            return activate(at: at, keyRepeat: keyRepeat || tx.keyRepeat())
        case .text(let t) where t == " ":
            return activate(at: at, keyRepeat: keyRepeat || tx.keyRepeat())
        case .text(let t) where !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            let prefix = typeAhead.step(t, now: clock ?? tx.clock)
            if let r = typeSelect(prefix: prefix, label: label) {
                return go(row: r, extend: false, tx: &tx)
            }
            return .handled
        default:
            target = nil
        }

        if let target {
            return go(row: target, extend: m.shift, tx: &tx)
        }
        return .ignored
    }

    private mutating func activate(at: Int?, keyRepeat: Bool) -> TreeKey {
        guard let r = at else { return .ignored }
        if keyRepeat {
            return .handled
        }
        let i = visibleRows().rows[r]
        if isOpenable(i) {
            setOpen(i, !isOpen(i))
            return .handled
        }
        return .open(nodes[i].id)
    }

    private mutating func go(row: Int, extend: Bool, tx: inout Tx) -> TreeKey {
        let vis = visibleRows()
        let i = vis.rows[row]
        moveTo(i, extend: extend)
        tx.scrollIntoViewIn(key, nodes[i].id)
        return .handled
    }

    /// Returns the visible row index that type-select jumps to for `prefix`.
    public func typeSelect(prefix: String, label: (T) -> String) -> Int? {
        guard let first = prefix.unicodeScalars.first else { return nil }
        let cycle = prefix.unicodeScalars.allSatisfy { $0 == first }
        let needle = cycle ? String(first) : prefix
        let vis = visibleRows()
        let len = vis.rows.count
        guard len > 0 else { return nil }
        let at: Int? = cursorIndex.flatMap { c in
            let r = vis.rowOf[c]
            return r == Int.max ? nil : r
        }
        let start: Int = switch at {
        case .some(let r) where cycle: r + 1
        case .some(let r): r
        case .none: 0
        }
        for k in 0..<len {
            let r = (start + k) % len
            if label(nodes[vis.rows[r]].data).lowercased().utf8.starts(with: needle.utf8) {
                return r
            }
        }
        return nil
    }

    /// Convenience helper for testing type-ahead directly (mirrors `tree/tests.rs::typed`).
    internal mutating func stepTypeAhead(_ text: String, at now: Double, label: (T) -> String) -> Int? {
        let prefix = typeAhead.step(text, now: now)
        return typeSelect(prefix: prefix, label: label)
    }
}
