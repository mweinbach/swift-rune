import Foundation
import Rune

/// Which way a table column sorts (`rune_kit::table::SortDir`).
public enum SortDir: String, Sendable, Hashable {
    case ascending
    case descending

    public func flip() -> SortDir {
        self == .ascending ? .descending : .ascending
    }

    /// Applies the sort direction to an ascending comparison result.
    public func apply(_ ordering: ComparisonResult) -> ComparisonResult {
        switch (self, ordering) {
        case (.ascending, _): return ordering
        case (.descending, .orderedAscending): return .orderedDescending
        case (.descending, .orderedDescending): return .orderedAscending
        case (.descending, .orderedSame): return .orderedSame
        }
    }

    /// Compares two `Comparable` values in this sort direction.
    public func compare<V: Comparable>(_ a: V, _ b: V) -> Bool {
        switch self {
        case .ascending: return a < b
        case .descending: return a > b
        }
    }
}

/// Column sizing rule (`rune_kit::table::Width`).
public enum TableColumnWidth: Sendable, Equatable {
    case fixed(Float)
    case flex(Float)
}

/// A column descriptor for `TableView` (`rune_kit::table::TableColumn`).
public struct TableCol: Sendable {
    public let id: String
    fileprivate let sourceKey: KitSourceKey
    public let title: String
    public var width: TableColumnWidth
    public var min: Float
    public var max: Float
    public var align: Align
    public var sortable: Bool
    public var resizable: Bool

    public init(_ id: String, _ title: String) {
        self.id = id
        self.sourceKey = KitSourceKey(id)
        self.title = title
        self.width = .flex(1.0)
        self.min = 48.0
        self.max = .infinity
        self.align = .start
        self.sortable = false
        self.resizable = true
    }

    public func width(_ w: Float) -> TableCol {
        var copy = self
        copy.width = .fixed(Swift.max(0.0, w))
        return copy
    }

    public func flex(_ weight: Float) -> TableCol {
        var copy = self
        copy.width = .flex(Swift.max(0.0, weight))
        return copy
    }

    public func min(_ w: Float) -> TableCol {
        var copy = self
        copy.min = Swift.max(0.0, w)
        return copy
    }

    public func max(_ w: Float) -> TableCol {
        var copy = self
        copy.max = Swift.max(0.0, w)
        return copy
    }

    public func align(_ a: Align) -> TableCol {
        var copy = self
        copy.align = a
        return copy
    }

    public func sortable(_ on: Bool = true) -> TableCol {
        var copy = self
        copy.sortable = on
        return copy
    }

    public func resizable(_ on: Bool) -> TableCol {
        var copy = self
        copy.resizable = on
        return copy
    }

    public func clamp(_ w: Float) -> Float {
        let hi = Swift.max(min, max)
        return Swift.min(Swift.max(w, min), hi)
    }
}

/// A table cell's content (`rune_kit::table::Cell`).
public struct TableCell<State> {
    public enum Content {
        case text(String)
        case element(El<State>)
    }

    public var content: Content
    public var color: Color?
    public var isMono: Bool = false
    public var isMuted: Bool = false

    private init(_ content: Content) {
        self.content = content
    }

    public static func text(_ t: String) -> TableCell<State> {
        TableCell(.text(t))
    }

    public static func el(_ e: El<State>) -> TableCell<State> {
        TableCell(.element(e))
    }

    public func mono(_ on: Bool = true) -> TableCell<State> {
        var copy = self
        copy.isMono = on
        return copy
    }

    public func muted(_ on: Bool = true) -> TableCell<State> {
        var copy = self
        copy.isMuted = on
        return copy
    }

    public func color(_ c: Color) -> TableCell<State> {
        var copy = self
        copy.color = c
        return copy
    }
}

/// Active column-resize drag metadata.
public struct ColumnDrag: Sendable, Equatable {
    public var restore: Float?
    public var from: Float

    public init(restore: Float?, from: Float) {
        self.restore = restore
        self.from = from
    }
}

enum TableKeyOutcome {
    case ignored
    case handled
    case moved
    case open(Int)
}

final class TableScrollSync: @unchecked Sendable {
    var cxScrollY: Float = 0.0
    var pendingTarget: Bool = false
}

/// Column IDs keep their authored bytes. The dictionary projection supports existing Swift callers.
private struct TableColumnWidths: Sendable {
    var values: [KitSourceKey: Float] = [:]

    var dictionary: [String: Float] {
        get {
            var result: [String: Float] = [:]
            for (id, width) in values {
                if let i = result.index(forKey: id.source) {
                    guard id.source.utf8.lexicographicallyPrecedes(result.keys[i].utf8) else { continue }
                    result.remove(at: i)
                }
                result[id.source] = width
            }
            return result
        }
        set { values = Dictionary(uniqueKeysWithValues: newValue.map { (KitSourceKey($0.key), $0.value) }) }
        _modify {
            var visible = dictionary
            // Keep unrepresentable spellings when an older client edits one dictionary entry.
            for id in visible.keys { values.removeValue(forKey: KitSourceKey(id)) }
            defer {
                if !values.isEmpty { values = values.filter { visible[$0.key.source] != nil } }
                for (id, width) in visible { values[KitSourceKey(id)] = width }
            }
            yield &visible
        }
    }
}

/// Persistent interaction state for `TableView` (`rune_kit::table::TableState`).
public struct TableState: Sendable {
    public var key: String = "table"
    public var multi: Bool = false
    public private(set) var sortColumn: String?
    public private(set) var sortDir: SortDir = .ascending
    private var explicitWidths = TableColumnWidths()
    private var measuredWidths = TableColumnWidths()
    /// Swift dictionary projection. Use `columnWidth` and `setColumnWidth` for byte-exact column IDs.
    public var widths: [String: Float] {
        get { explicitWidths.dictionary }
        set { explicitWidths.dictionary = newValue }
        _modify { yield &explicitWidths.dictionary }
    }
    /// Most recently measured widths, with one entry per Swift dictionary key.
    public var laidOut: [String: Float] {
        get { measuredWidths.dictionary }
        set { measuredWidths.dictionary = newValue }
        _modify { yield &measuredWidths.dictionary }
    }
    public var resize: Grip<ColumnDrag> = .idle
    /// The Swift Set projection contains one representative of equivalent spellings.
    public private(set) var selected: Set<String> = []
    private var selectionVariants: [String: Set<KitSourceKey>] = [:]
    private var variantCount: Int = 0
    public private(set) var cursor: String?
    public private(set) var anchor: String?
    private var cursorHint: Int = 0
    private var anchorHint: Int = 0
    public var viewport: Float = 0.0
    public var rowHeight: Float = 28.0
    public var trackedScrollY: Float = 0.0
    fileprivate let scrollSync = TableScrollSync()

    public init(key: String = "table", multi: Bool = false) {
        self.key = key
        self.multi = multi
    }

    public func key(_ k: String) -> TableState {
        var copy = self
        copy.key = k
        return copy
    }

    public func multiSelect(_ on: Bool) -> TableState {
        var copy = self
        copy.multi = on
        return copy
    }

    public var sort: (String, SortDir)? {
        sortColumn.map { ($0, sortDir) }
    }

    public mutating func setSort(_ column: String, _ dir: SortDir) {
        sortColumn = column
        sortDir = dir
    }

    public mutating func clearSort() {
        sortColumn = nil
    }

    public func nextSort(_ column: String) -> SortDir {
        isSortColumn(column) ? sortDir.flip() : .ascending
    }

    fileprivate func isSortColumn(_ column: String) -> Bool {
        guard let sortColumn else { return false }
        return KitSourceKey.equalBytes(sortColumn, column)
    }

    public func columnWidth(_ column: String) -> Float? {
        columnWidth(KitSourceKey(column))
    }

    fileprivate func columnWidth(_ column: KitSourceKey) -> Float? { explicitWidths.values[column] }

    public mutating func setColumnWidth(_ column: String, _ w: Float) {
        explicitWidths.values[KitSourceKey(column)] = w
    }

    public mutating func resetColumnWidth(_ column: String) {
        explicitWidths.values.removeValue(forKey: KitSourceKey(column))
    }

    /// Set projection of the selection. `exactSelectedIDs` retains every authored spelling.
    public var selectedIDs: Set<String> { selected }
    /// Every selected ID in unspecified order, including distinct UTF-8 spellings.
    public var exactSelectedIDs: [String] {
        var ids = Array(selected)
        ids.reserveCapacity(selectedCount)
        for variants in selectionVariants.values {
            ids.append(contentsOf: variants.map(\.source))
        }
        return ids
    }
    public var selectedCount: Int { selected.count + variantCount }

    fileprivate mutating func recordColumnWidth(_ width: Float, for id: KitSourceKey) -> Float? {
        measuredWidths.values.updateValue(width, forKey: id)
    }

    fileprivate func measuredColumnWidth(_ id: KitSourceKey) -> Float? { measuredWidths.values[id] }

    public func isSelected(_ id: String) -> Bool {
        guard let i = selected.firstIndex(of: id) else { return false }
        if KitSourceKey.equalBytes(selected[i], id) { return true }
        return selectionVariants[id]?.contains(KitSourceKey(id)) == true
    }

    public mutating func select(_ id: String) {
        selected = [id]
        selectionVariants.removeAll()
        variantCount = 0
        cursor = id
        anchor = id
    }

    public mutating func clearSelection() {
        selected.removeAll(keepingCapacity: true)
        selectionVariants.removeAll(keepingCapacity: true)
        variantCount = 0
    }

    private mutating func addSelection(_ id: String) {
        let (inserted, representative) = selected.insert(id)
        guard !inserted, !KitSourceKey.equalBytes(representative, id) else { return }
        if selectionVariants[id, default: []].insert(KitSourceKey(id)).inserted { variantCount += 1 }
    }

    private mutating func selectRows(_ rows: ClosedRange<Int>, idAt: (Int) -> String) {
        clearSelection()
        selected.reserveCapacity(rows.count)
        for row in rows { addSelection(idAt(row)) }
    }

    private mutating func toggleSelection(_ id: String) {
        guard let i = selected.firstIndex(of: id) else {
            selected.insert(id)
            return
        }
        if KitSourceKey.equalBytes(selected[i], id) {
            selected.remove(at: i)
            if let replacement = selectionVariants[id]?.popFirst() {
                selected.insert(replacement.source)
                variantCount -= 1
            }
        } else {
            let key = KitSourceKey(id)
            if selectionVariants[id]?.remove(key) != nil {
                variantCount -= 1
            } else {
                selectionVariants[id, default: []].insert(key)
                variantCount += 1
            }
        }
        if selectionVariants[id]?.isEmpty == true { selectionVariants[id] = nil }
    }

    /// Selects the row and asks this table's virtual list to reveal its stable ID.
    public mutating func reveal(_ id: String, rowIndex: Int? = nil, tx: inout Tx) {
        select(id)
        if let rowIndex {
            cursorHint = rowIndex
            anchorHint = rowIndex
            trackReveal(rowIndex)
        }
        tx.scrollIntoViewIn(key, id)
    }

    public mutating func reveal(_ id: String, len: Int, idAt: (Int) -> String, tx: inout Tx) {
        reveal(id, rowIndex: findAt(id, hint: cursorHint, len: len, idAt: idAt), tx: &tx)
    }

    private func findAt(_ id: String, hint: Int, len: Int, idAt: (Int) -> String) -> Int? {
        if hint >= 0 && hint < len && KitSourceKey.equalBytes(idAt(hint), id) {
            return hint
        }
        return (0..<len).first { KitSourceKey.equalBytes(idAt($0), id) }
    }

    private mutating func cursorRow(len: Int, idAt: (Int) -> String) -> Int? {
        guard let c = cursor else { return nil }
        guard let found = findAt(c, hint: cursorHint, len: len, idAt: idAt) else { return nil }
        cursorHint = found
        return found
    }

    private mutating func anchorRow(len: Int, idAt: (Int) -> String) -> Int? {
        guard let a = anchor else { return nil }
        guard let found = findAt(a, hint: anchorHint, len: len, idAt: idAt) else { return nil }
        anchorHint = found
        return found
    }

    mutating func click(row i: Int, len: Int, mods: Mods, idAt: (Int) -> String) {
        guard i >= 0 && i < len else { return }
        let id = idAt(i)
        if multi && mods.shift {
            extend(to: i, len: len, idAt: idAt)
            return
        }
        cursorHint = i
        anchorHint = i
        if multi && mods.primaryCommand {
            toggleSelection(id)
            cursor = id
            anchor = id
            return
        }
        select(id)
    }

    private mutating func extend(to i: Int, len: Int, idAt: (Int) -> String) {
        let aIdx: Int
        if let existing = anchorRow(len: len, idAt: idAt) {
            aIdx = existing
        } else {
            anchor = idAt(i)
            anchorHint = i
            aIdx = i
        }
        let lo = min(aIdx, i)
        let hi = max(aIdx, i)
        selectRows(lo...hi, idAt: idAt)
        cursor = idAt(i)
        cursorHint = i
    }

    private mutating func trackReveal(_ row: Int) {
        let rh = max(1.0, rowHeight)
        let vp = viewport > 0 ? viewport : 270.0
        if !scrollSync.pendingTarget {
            trackedScrollY = scrollSync.cxScrollY
        }
        let prevY = trackedScrollY
        let rowTop = Float(row) * rh
        let rowBot = rowTop + rh
        if rowTop < trackedScrollY {
            trackedScrollY = rowTop
        } else if rowBot > trackedScrollY + vp {
            trackedScrollY = max(0.0, rowBot - vp)
        }
        if abs(trackedScrollY - prevY) > 1e-4 {
            scrollSync.pendingTarget = true
        }
    }

    mutating func handleKey(_ ev: KeyEvent, len: Int, idAt: (Int) -> String, tx: inout Tx, keyRepeat: Bool = false) -> TableKeyOutcome {
        let m = ev.mods
        if len == 0 {
            return .ignored
        }
        if multi && m.primaryAlone && (m.primaryCommand || ev.key == .command("a")) && ev.isCommand("a") {
            selectRows(0...(len - 1), idAt: idAt)
            return .handled
        }
        if m.cmd || m.ctrl || m.alt || m.logo {
            return .ignored
        }

        let at = cursorRow(len: len, idAt: idAt)
        let page = max(1, Int(floor(viewport / max(1.0, rowHeight))) - 1)

        let target: Int
        switch ev.key {
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
            target = at.map { min(len - 1, $0 + page) } ?? (len - 1)
        case .enter:
            guard let r = at else { return .ignored }
            return keyRepeat ? .handled : .open(r)
        case .escape where multi && selectedCount > 1:
            if let r = at {
                cursorHint = r
                anchorHint = r
                select(idAt(r))
            } else {
                clearSelection()
            }
            return .handled
        default:
            return .ignored
        }

        let before = cursor
        let targetID = idAt(target)
        if m.shift && multi {
            extend(to: target, len: len, idAt: idAt)
        } else {
            cursorHint = target
            anchorHint = target
            select(targetID)
        }
        trackReveal(target)
        tx.scrollIntoViewIn(key, targetID)
        if let before, KitSourceKey.equalBytes(before, targetID) { return .handled }
        return .moved
    }

    /// Computes resolved column widths given the container width.
    public func resolvedColumnWidths(columns: [TableCol], totalWidth: Float) -> [Float] {
        var result = Array(repeating: Float(0), count: columns.count)
        var fixedSum: Float = 0
        var flexSum: Float = 0

        for (i, c) in columns.enumerated() {
            if let w = explicitWidths.values[c.sourceKey] {
                let cw = c.clamp(w)
                result[i] = cw
                fixedSum += cw
            } else {
                switch c.width {
                case .fixed(let w):
                    let cw = c.clamp(w)
                    result[i] = cw
                    fixedSum += cw
                case .flex(let weight):
                    flexSum += max(0, weight)
                }
            }
        }

        let remaining = max(0, totalWidth - fixedSum)
        if flexSum > 0 {
            for (i, c) in columns.enumerated() where explicitWidths.values[c.sourceKey] == nil {
                if case .flex(let weight) = c.width {
                    let share = remaining * (max(0, weight) / flexSum)
                    result[i] = c.clamp(share)
                }
            }
        }
        return result
    }
}

/// Visual metrics and colours for `TableView` (`rune_kit::table::TableStyle`).
public struct TableStyle: Sendable, Equatable {
    public var rowHeight: Float
    public var headerHeight: Float
    public var cellPad: Float
    public var font: TextStyle
    public var mono: TextStyle
    public var headerFont: TextStyle
    public var text: Color
    public var muted: Color
    public var headerText: Color
    public var rule: Color
    public var selected: Color
    public var stripe: Color

    public static func fromKit(_ k: Kit) -> TableStyle {
        let c = k.c
        return TableStyle(
            rowHeight: 28.0,
            headerHeight: 30.0,
            cellPad: 10.0,
            font: k.ty.textSmall,
            mono: k.ty.mono.features("'tnum' 1"),
            headerFont: k.ty.textSmallMedium,
            text: c.textBase,
            muted: c.textMuted,
            headerText: c.textMuted,
            rule: c.borderWeak,
            selected: k.alpha(c.textAccent, k.dark ? 0.24 : 0.2),
            stripe: k.alpha(c.textBase, k.dark ? 0.035 : 0.03)
        )
    }
}

/// Virtualised data table with sticky header, sortable/resizable columns, row selection,
/// and keyboard navigation (`rune_kit::table::Table`).
public struct TableView<State> {
    private let get: (State) -> TableState
    private let update: (inout State, (inout TableState) -> Void) -> Void
    private let len: (State) -> Int
    private let rowID: (State, Int) -> String
    private var columns: [TableCol] = []
    private var cellBuilder: ((State, Int, String) -> TableCell<State>)?
    private var onSortHandler: ((inout State, String, SortDir, inout Tx) -> Void)?
    private var onSelectHandler: ((inout State, String, inout Tx) -> Void)?
    private var onOpenHandler: ((inout State, String, inout Tx) -> Void)?
    private var isZebra: Bool = false
    private var styleOverride: TableStyle?
    private var a11yName: String?

    public init(
        _ keyPath: WritableKeyPath<State, TableState>,
        len: @escaping (State) -> Int,
        rowID: @escaping (State, Int) -> String
    ) {
        self.get = { $0[keyPath: keyPath] }
        self.update = { s, body in body(&s[keyPath: keyPath]) }
        self.len = len
        self.rowID = rowID
    }

    public init(
        get: @escaping (State) -> TableState,
        update: @escaping (inout State, (inout TableState) -> Void) -> Void,
        len: @escaping (State) -> Int,
        rowID: @escaping (State, Int) -> String
    ) {
        self.get = get
        self.update = update
        self.len = len
        self.rowID = rowID
    }

    public func column(_ c: TableCol) -> TableView<State> {
        var copy = self
        copy.columns.append(c)
        return copy
    }

    public func cell(_ f: @escaping (State, Int, String) -> TableCell<State>) -> TableView<State> {
        var copy = self
        copy.cellBuilder = f
        return copy
    }

    public func onSort(_ f: @escaping (inout State, String, SortDir, inout Tx) -> Void) -> TableView<State> {
        var copy = self
        copy.onSortHandler = f
        return copy
    }

    public func onSelect(_ f: @escaping (inout State, String, inout Tx) -> Void) -> TableView<State> {
        var copy = self
        copy.onSelectHandler = f
        return copy
    }

    public func onOpen(_ f: @escaping (inout State, String, inout Tx) -> Void) -> TableView<State> {
        var copy = self
        copy.onOpenHandler = f
        return copy
    }

    public func zebra(_ on: Bool) -> TableView<State> {
        var copy = self
        copy.isZebra = on
        return copy
    }

    public func style(_ s: TableStyle) -> TableView<State> {
        var copy = self
        copy.styleOverride = s
        return copy
    }

    public func name(_ n: String) -> TableView<State> {
        var copy = self
        copy.a11yName = n
        return copy
    }

    public func build(_ s: State, cx: Cx<State>? = nil, kit k: Kit, width availableWidth: Float? = nil) -> El<State> {
        let style = styleOverride ?? TableStyle.fromKit(k)
        let st = get(s)
        let count = len(s)
        let tableKey = st.key
        let viewportKey = "\(tableKey)-viewport"

        let resolvedWidths = availableWidth.map { st.resolvedColumnWidths(columns: columns, totalWidth: $0) }
        let sizes: [TableColumnWidth] = columns.map { col in
            st.columnWidth(col.sourceKey).map { .fixed(col.clamp($0)) } ?? col.width
        }

        let header = buildHeader(
            kit: k,
            state: st,
            sizes: sizes,
            resolvedWidths: resolvedWidths,
            style: style
        )

        let upd = update
        let countFn = len
        let idFn = rowID
        let selHandler = onSelectHandler
        let openHandler = onOpenHandler
        let buildRow: (State, Int) -> El<State> = { s, i in
            let id = self.rowID(s, i)
            let st = self.get(s)
            let selected = st.isSelected(id)
            var r: El<State> = row()
                .key(id)
                .role(.row)
                .itemSelected(selected)
                .positionInSet(i + 1, size: count)
                .wFull()
                .h(style.rowHeight)
                .shrink(0.0)
                .itemsCenter()

            if selected {
                r = r.focusSelected().bg(style.selected)
            } else if self.isZebra && i % 2 == 1 {
                r = r.bg(style.stripe).hover(style.stripe.mix(with: style.selected, t: 0.5))
            } else {
                r = r.hover(style.stripe.mix(with: style.selected, t: 0.5))
            }

            if st.multi, let cursor = st.cursor, KitSourceKey.equalBytes(cursor, id) {
                r = r.outline(width: 1.0, offset: -1.0, color: k.c.borderFocus)
            }

            for (j, colDef) in self.columns.enumerated() {
                let cellContent = self.cellBuilder?(s, i, colDef.id) ?? .text("")
                let cellEl = self.buildCell(
                    colDef,
                    widthSpec: sizes[j],
                    cell: cellContent,
                    style: style
                ).key(colDef.id, byteExact: true)
                r = r.child(cellEl)
            }

            r = r.onClickPress { state, press, tx in
                tx.focus(tableKey)
                let n = countFn(state)
                guard i < n else { return }
                let id = idFn(state, i)
                let snapshot = state
                upd(&state) { st in
                    st.click(row: i, len: n, mods: press.mods) { idFn(snapshot, $0) }
                }
                selHandler?(&state, id, &tx)
            }
            .focusable(false)

            if let openHandler {
                r = r.onDoubleClick { state, tx in
                    guard i < countFn(state) else { return }
                    let id = idFn(state, i)
                    openHandler(&state, id, &tx)
                }
            }
            return r
        }

        let rowsCol: El<State> = col()
            .key("\(tableKey)-rows", byteExact: true)
            .wFull()
            .shrink(0)
            .growth(.default)
            .virtualRows(count: count, estimatedRowHeight: style.rowHeight, byteExactKeys: true, key: rowID, build: buildRow)

        let scrollSync = st.scrollSync
        let viewport: El<State> = col()
            .key(viewportKey, byteExact: true)
            .wFull()
            .grow(1.0)
            .minH(0.0)
            .scrollY()
            .onLayoutTx { state, rect, tx in
                upd(&state) { st in
                    if st.viewport == rect[3] && st.rowHeight == style.rowHeight { tx.liveOnly() }
                    st.viewport = rect[3]
                    st.rowHeight = style.rowHeight
                }
            }
            .chainScrollOffset { pos in
                scrollSync.cxScrollY = pos.offset.y
                scrollSync.pendingTarget = false
            }
            .child(rowsCol)

        var rootEl: El<State> = col()
            .key(tableKey, byteExact: true)
            .role(.grid)
            .focusable(true)
            .wFull()
            .clip(true)
            .child(header)
            .child(viewport)
            .onKey { state, ev, tx in
                let n = countFn(state)
                var movedID: String?
                var openRow: Int?
                var handled = false
                let snapshot = state
                upd(&state) { st in
                    let repeating = tx.keyRepeat()
                    let outcome = st.handleKey(ev, len: n, idAt: { idFn(snapshot, $0) }, tx: &tx, keyRepeat: repeating)
                    switch outcome {
                    case .ignored:
                        handled = false
                    case .handled:
                        handled = true
                    case .moved:
                        movedID = st.cursor
                        handled = true
                    case .open(let r):
                        openRow = r
                        handled = true
                    }
                }
                if let movedID {
                    selHandler?(&state, movedID, &tx)
                }
                if let openRow, openRow < countFn(state) {
                    let id = idFn(state, openRow)
                    openHandler?(&state, id, &tx)
                }
                return handled
            }

        if let a11yName {
            rootEl = rootEl.label(a11yName)
        }
        if let cur = st.cursor {
            rootEl = rootEl.activeDescendant(cur)
        }
        return rootEl
    }

    private func sized(_ e: El<State>, _ c: TableCol, _ w: TableColumnWidth) -> El<State> {
        var out: El<State> = switch w {
        case .fixed(let v):
            e.w(v)
        case .flex(let g):
            e.w(0.0).grow(g).shrink(1.0)
        }
        out = out.minW(c.min)
        if c.max.isFinite {
            out = out.maxW(c.max)
        }
        return out
    }

    private func justify(_ e: El<State>, _ align: Align) -> El<State> {
        switch align {
        case .start: e
        case .center: e.justifyCenter()
        case .end: e.justifyEnd()
        }
    }

    private func buildCell(
        _ c: TableCol,
        widthSpec: TableColumnWidth,
        cell: TableCell<State>,
        style: TableStyle
    ) -> El<State> {
        let inner: El<State>
        switch cell.content {
        case .text(let t):
            let color = cell.color ?? (cell.isMuted ? style.muted : style.text)
            let font = cell.isMono ? style.mono : style.font
            let textAlign: TextAlign = switch c.align {
            case .start: .leading
            case .center: .center
            case .end: .trailing
            }
            inner = text(t)
                .font(font.aligned(textAlign))
                .color(color)
                .truncate()
                .helpWhenTruncated(t)
        case .element(let e):
            inner = e
        }

        let base: El<State> = row()
            .role(.gridCell)
            .hFull()
            .px(style.cellPad)
            .itemsCenter()
            .clip(true)
        return justify(sized(base, c, widthSpec), c.align).child(inner)
    }

    private func buildHeader(
        kit k: Kit,
        state: TableState,
        sizes: [TableColumnWidth],
        resolvedWidths: [Float]?,
        style: TableStyle
    ) -> El<State> {
        var h: El<State> = row()
            .key("header")
            .role(.row)
            .wFull()
            .h(style.headerHeight)
            .shrink(0.0)
            .child(
                el()
                    .key("rule")
                    .pin(right: 0.0, bottom: 0.0, left: 0.0)
                    .h(1.0)
                    .bg(style.rule)
                    .a11yHidden()
            )

        let last = max(0, columns.count - 1)
        for (j, colDef) in columns.enumerated() {
            let sortedDir = state.isSortColumn(colDef.id) ? state.sortDir : nil
            let titleText: El<State> = text(colDef.title)
                .key("title")
                .font(style.headerFont)
                .helpWhenTruncated(colDef.title)
                .color(sortedDir != nil ? style.text : style.headerText)
                .truncate()
                .a11yHidden()

            var inner: El<State> = row().key("inner").a11yHidden().gap(2.0).itemsCenter().minW(0.0).shrink(1.0).child(titleText)
            if let d = sortedDir {
                let glyph = d == .ascending ? k.glyph.chevronUp : k.glyph.chevronDown
                inner = inner.child(icon(glyph, size: 14.0).key("sort").color(style.text).a11yHidden())
            }

            var cell = justify(
                sized(
                    row()
                        .role(.columnHeader)
                        .label(colDef.title)
                        .hFull()
                        .px(style.cellPad)
                        .itemsCenter(),
                    colDef,
                    sizes[j]
                ),
                colDef.align
            )
            .key(colDef.id, byteExact: true)
            .onLayoutTx { s, rect, tx in
                update(&s) { st in
                    if st.recordColumnWidth(rect[2], for: colDef.sourceKey) == rect[2] { tx.liveOnly() }
                }
            }
            .child(inner)

            if let d = sortedDir { cell = cell.sorted(d == .ascending) }

            if colDef.sortable {
                let id = colDef.id
                let upd = update
                let sortCb = onSortHandler
                cell = cell
                    .cursor(.pointer)
                    .hover(k.c.hover)
                    .onClick { s, tx in
                        var chosenDir: SortDir = .ascending
                        upd(&s) { st in
                            chosenDir = st.nextSort(id)
                            st.setSort(id, chosenDir)
                        }
                        sortCb?(&s, id, chosenDir, &tx)
                    }
                    .focusable(false)
            }

            if colDef.resizable {
                cell = cell.child(
                    buildResizeHandle(
                        column: colDef,
                        defaultWidth: resolvedWidths?[j] ?? colDef.min,
                        rule: style.rule,
                        isLast: j == last
                    )
                )
            } else if j != last {
                cell = cell.child(
                    el()
                        .key("rule")
                        .pin(top: 8.0, right: 0.0, bottom: 8.0)
                        .w(1.0)
                        .bg(style.rule)
                        .a11yHidden()
                )
            }

            h = h.child(cell)
        }
        return h
    }

    private func buildResizeHandle(
        column c: TableCol,
        defaultWidth: Float,
        rule: Color,
        isLast: Bool
    ) -> El<State> {
        let upd = update
        let colId = c.id
        let line: El<State> = el()
            .key("line")
            .w(1.0)
            .hFull()
            .bg(isLast ? .transparent : rule)
            .a11yHidden()

        return row()
            .key("\(colId)-resize", byteExact: true)
            .role(.splitter)
            .cursor(.resizeColumn)
            .label("Resize \(c.title)")
            .pin(top: 6.0, right: -4.0, bottom: 6.0)
            .w(9.0)
            .justifyCenter()
            .onPointerDown { s, press, _ in
                upd(&s) { st in
                    let restore = st.columnWidth(c.sourceKey)
                    let from = restore ?? st.measuredColumnWidth(c.sourceKey) ?? defaultWidth
                    st.resize.press(ColumnDrag(restore: restore, from: from), at: press.window)
                }
            }
            .onDrag { s, drag, _ in
                upd(&s) { st in
                    if let active = st.resize.moved(to: drag.window) {
                        st.setColumnWidth(colId, c.clamp(active.from + drag.delta.x))
                    } else {
                        let restore = st.columnWidth(c.sourceKey)
                        let from = restore ?? st.measuredColumnWidth(c.sourceKey) ?? defaultWidth
                        let start = Vec2(x: drag.window.x - drag.delta.x, y: drag.window.y - drag.delta.y)
                        st.resize.press(ColumnDrag(restore: restore, from: from), at: start)
                        st.setColumnWidth(colId, c.clamp(from + drag.delta.x))
                    }
                }
            }
            .onDragEnd { s, cancelled, _ in
                upd(&s) { st in
                    let released = st.resize.release()
                    if cancelled {
                        if let restore = released?.restore {
                            st.setColumnWidth(colId, restore)
                        } else {
                            st.resetColumnWidth(colId)
                        }
                    }
                }
            }
            .onDoubleClick { s, _ in
                upd(&s) { st in
                    st.resetColumnWidth(colId)
                }
            }
            .focusable(false)
            .child(line)
    }
}
