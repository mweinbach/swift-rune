import Foundation
import RuneMotion

// MARK: - Virtual List Bookkeeping & Bounds (`crates/rune/src/el/virtual_list.rs`)

/// The most an element can be tall before layout (`virtual_list.rs::height_bound`).
public func virtualHeightBound(_ style: LayoutStyle, available: Float) -> Float {
    var h: Float
    if case .points(let pt) = style.height {
        h = pt
    } else {
        h = available
    }
    if case .points(let maxH) = style.maxHeight {
        h = min(h, maxH)
    }
    if case .points(let minH) = style.minHeight {
        h = max(h, minH)
    }
    return h
}

/// A column flex container's vertical gap in points; zero for non-column containers (`virtual_list.rs::gap_y`).
public func virtualGapY(_ style: LayoutStyle) -> Float {
    let isColumn = style.displayMode == .flex
        && !style.wrap
        && (style.direction == .column || style.direction == .columnReverse)
    guard isColumn else { return 0 }
    return max(0, style.rowGap)
}

/// The most each child of an element whose bound is `bound` can be tall (`virtual_list.rs::ChildBounds`).
public struct VirtualChildBounds: Sendable, Equatable {
    /// The parent's bound: an absolute child's insets are from its padding box.
    public let outer: Float
    public let inner: Float
    public let fixed: Float
    public let column: Bool

    public init(outer: Float, inner: Float, fixed: Float, column: Bool) {
        self.outer = outer
        self.inner = inner
        self.fixed = fixed
        self.column = column
    }

    public static func compute<State>(
        style: LayoutStyle,
        scrolls: Bool,
        bound: Float,
        children: [El<State>]
    ) -> VirtualChildBounds {
        if scrolls {
            return VirtualChildBounds(outer: .infinity, inner: .infinity, fixed: 0, column: false)
        }
        let inner = bound - style.padding.top - style.padding.bottom
        let column = style.displayMode == .flex
            && !style.wrap
            && (style.direction == .column || style.direction == .columnReverse)
        if !column || children.count < 2 {
            return VirtualChildBounds(outer: bound, inner: inner, fixed: 0, column: false)
        }
        let inFlowCount = children.filter { inFlow($0.layout) }.count
        let gaps = max(0, style.rowGap) * Float(max(0, inFlowCount - 1))
        let fixedSum = children.reduce(Float(0)) { $0 + fixedHeight($1.layout) }
        return VirtualChildBounds(outer: bound, inner: inner - gaps, fixed: fixedSum, column: column)
    }

    public func of<State>(_ child: El<State>) -> Float {
        let style = child.layout
        let bound: Float
        if style.isAbsolute {
            if let top = style.pinTop, let bottom = style.pinBottom {
                bound = outer - top - bottom
            } else {
                bound = .infinity
            }
        } else if column && Self.inFlow(style) {
            bound = inner - (fixed - Self.fixedHeight(style))
        } else {
            bound = inner
        }
        return max(0, bound)
    }

    private static func inFlow(_ style: LayoutStyle) -> Bool {
        !style.displayNone && !style.isAbsolute
    }

    private static func fixedHeight(_ style: LayoutStyle) -> Float {
        guard inFlow(style) else { return 0 }
        let minH: Float
        if case .points(let v) = style.minHeight { minH = v } else { minH = 0 }
        if style.flexShrink > 0 { return minH }
        let h: Float
        if case .points(let v) = style.height { h = v } else { h = 0 }
        let clampedMax: Float
        if case .points(let m) = style.maxHeight { clampedMax = min(h, m) } else { clampedMax = h }
        return max(clampedMax, minH)
    }
}

/// Virtual row bookkeeping (`crates/rune/src/el/virtual_list.rs::VirtualList`).
/// Only geometry outside the mounted window is estimated.
public struct VirtualListBookkeeping: Sendable {
    public static let overscan: Float = 2.0
    public static let indexedEdge: Float = 1.75
    public static let indexedBudget: Float = 0.5

    private struct Row: Sendable {
        var index: Int
        var height: Float?
    }

    public struct Anchor: Sendable, Equatable {
        public var key: String
        public var top: Float

        public init(key: String, top: Float) {
            self.key = key
            self.top = top
        }
    }

    public private(set) var keys: [String] = []
    private var rows: [String: Row] = [:]
    private var born: [UInt64] = []
    private var keysFresh: Bool = false
    private var held: Bool = false
    public var entering: Set<String> = []
    private var rowHeights: [Float] = []
    private var sumsCache: [Float] = [0]
    public private(set) var range: Range<Int> = 0..<0
    public private(set) var before: Float = 0
    public private(set) var after: Float = 0
    public private(set) var estimate: Float = 0
    public var indexed: Bool = false
    public var shown: Set<String> = []
    public var drawn: [String] = []
    public var focusedRow: String? = nil
    public var selectedRow: String? = nil
    public var revealSelected: String? = nil
    public var scrollPath: String = ""
    public var viewport: Float = 0
    public var top: Float = 0
    public var padTop: Float = 0
    public var padBottom: Float = 0
    public private(set) var gap: Float = 0
    public var anchor: Anchor? = nil
    public var keysVersion: UInt64? = nil
    public var reportedVisible: Range<Int>? = nil

    public init() {}

    public func height(forKey key: String) -> Float {
        rows[key]?.height ?? estimate
    }

    public func has(_ key: String) -> Bool {
        rows[key] != nil
    }

    public func indexOf(_ key: String) -> Int? {
        rows[key]?.index
    }

    public mutating func mountsQuietly(index i: Int, commit: UInt64) -> Bool {
        let quiet = born[i] < commit && !(keysFresh && !shown.contains(keys[i]))
        if !quiet {
            entering.insert(keys[i])
        }
        return quiet
    }

    public func replacedView() -> Bool {
        keysFresh && !held
    }

    public mutating func frameBegins() {
        keysFresh = false
    }

    public func sameKeys(_ candidateKeys: [String?]) -> Bool {
        candidateKeys.count == keys.count && zip(candidateKeys, keys).allSatisfy { $0 == $1 }
    }

    @discardableResult
    public mutating func setKeys(
        _ newKeys: [String],
        commit: UInt64,
        offset: Float?
    ) -> Anchor? {
        var newRows: [String: Row] = [:]
        newRows.reserveCapacity(newKeys.count)
        var newBorn: [UInt64] = []
        newBorn.reserveCapacity(newKeys.count)
        var newHeights: [Float] = []
        newHeights.reserveCapacity(newKeys.count)

        var resolvedKeys: [String] = []
        resolvedKeys.reserveCapacity(newKeys.count)
        var counts: [String: Int] = [:]
        for (index, rawKey) in newKeys.enumerated() {
            var key = rawKey
            if newRows[key] != nil {
                var suffix = counts[rawKey, default: 1]
                var candidate = "\(rawKey)#dup\(suffix)"
                while newRows[candidate] != nil {
                    suffix += 1
                    candidate = "\(rawKey)#dup\(suffix)"
                }
                counts[rawKey] = suffix + 1
                key = candidate
            } else {
                counts[rawKey] = 1
            }
            resolvedKeys.append(key)
            let old = rows[key]
            let h = old?.height
            newBorn.append(old.map { born[$0.index] } ?? commit)
            newHeights.append(h ?? estimate)
            newRows[key] = Row(index: index, height: h)
        }

        let computedAnchor: Anchor?
        if let off = offset,
           let candidate = firstVisible(offset: off, keep: { newRows[$0] != nil }),
           candidate.top < off + viewport {
            computedAnchor = candidate
        } else {
            computedAnchor = nil
        }

        if resolvedKeys != keys {
            keysFresh = true
            if offset != nil {
                held = computedAnchor != nil
            } else {
                held = keys.contains { newRows[$0] != nil }
            }
        }

        rows = newRows
        born = newBorn
        keys = resolvedKeys
        rowHeights = newHeights
        rebuildSums()
        reportedVisible = nil
        return computedAnchor
    }

    public mutating func setEstimate(_ newEstimate: Float) {
        if newEstimate != estimate {
            estimate = newEstimate
            rowHeights = keys.map { rows[$0]?.height ?? newEstimate }
            rebuildSums()
        }
    }

    public mutating func setGap(_ newGap: Float) {
        if newGap != gap {
            gap = newGap
            rebuildSums()
        }
    }

    public mutating func setHeight(key: String, height newHeight: Float) {
        guard var row = rows[key] else { return }
        row.height = newHeight
        rows[key] = row
        let i = row.index
        if rowHeights[i] != newHeight {
            rowHeights[i] = newHeight
            rebuildSums()
        }
    }

    private mutating func rebuildSums() {
        sumsCache.removeAll(keepingCapacity: true)
        sumsCache.reserveCapacity(rowHeights.count + 1)
        sumsCache.append(0)
        var y: Float = 0
        for h in rowHeights {
            y += h + gap
            sumsCache.append(y)
        }
    }

    public func prefix(_ end: Int) -> Float {
        if end == 0 || end < keys.count {
            return sumsCache[end]
        }
        return sumsCache[end] - gap
    }

    /// The bottom of the first `end` rows (without the gap after row `end - 1`).
    public func rowEnd(_ end: Int) -> Float {
        end == 0 ? 0 : sumsCache[end] - gap
    }

    /// The first row still visible at `offset`, among those `keep` accepts, and its top.
    public func firstVisible(offset: Float, keep: (String) -> Bool) -> Anchor? {
        let first = partitionPoint(sumsCache.dropFirst()) { padTop + $0 - gap <= offset }
        for i in first..<keys.count where keep(keys[i]) {
            return Anchor(key: keys[i], top: padTop + sumsCache[i])
        }
        return nil
    }

    /// The furthest the rows can scroll: their extent less the viewport.
    public func maxOffset() -> Float {
        max(0, padTop + prefix(keys.count) + padBottom - viewport)
    }

    /// The row index range intersecting the scroll viewport (`offset ..< offset + viewport`).
    public func visibleRange(offset: Float, pinned: Bool) -> Range<Int> {
        guard !keys.isEmpty else { return 0..<0 }
        let clampedOffset = pinned ? maxOffset() : min(max(0, offset), maxOffset())
        let start = partitionPoint(sumsCache.dropFirst()) { padTop + $0 - gap <= clampedOffset }
        let end = max(start, partitionPoint(sumsCache[..<keys.count]) { padTop + $0 < clampedOffset + viewport })
        return start..<end
    }

    /// Picks the rows to mount for `offset`, clamped to the rows' extent.
    public mutating func select(offset: Float, pinned: Bool, budget: Set<String>?) {
        let clampedOffset = pinned ? maxOffset() : min(offset, maxOffset())
        let (osStart, osEnd) = overscan(offset: clampedOffset)
        var start: Int
        var end: Int

        if let shown = budget, !pinned {
            let first = max(osStart, partitionPoint(sumsCache.dropFirst()) { padTop + $0 - gap <= clampedOffset })
            let last = max(first, partitionPoint(sumsCache[..<keys.count]) { padTop + $0 < clampedOffset + viewport })
            let budgetPts = viewport * Self.indexedBudget
            var spent: Float = 0
            var from = first
            while from > osStart {
                let i = from - 1
                if !shown.contains(keys[i]) {
                    if spent >= budgetPts { break }
                    spent += rowHeights[i] + gap
                }
                from = i
            }
            spent = 0
            var to = min(last, osEnd)
            while to < osEnd {
                if !shown.contains(keys[to]) {
                    if spent >= budgetPts { break }
                    spent += rowHeights[to] + gap
                }
                to += 1
            }
            start = from
            end = max(from, to)
        } else {
            start = osStart
            end = osEnd
        }

        var lo = start
        var hi = end
        for key in drawn {
            guard let i = indexOf(key) else { continue }
            if i < start && prefix(start) - prefix(i) <= viewport * Self.overscan {
                lo = min(lo, i)
            }
            if i >= end && rowEnd(i + 1) - rowEnd(end) <= viewport * Self.overscan {
                hi = max(hi, i + 1)
            }
        }
        start = lo
        end = hi

        anchor = pinned ? nil : anchorAt(offset: clampedOffset)
        if pinned {
            start = min(start, max(0, end - 32))
        }
        end = max(start, end)
        place(start..<end)
    }

    public mutating func hold(offset: Float, pinned: Bool) {
        let clampedOffset = pinned ? maxOffset() : min(offset, maxOffset())
        anchor = pinned ? nil : anchorAt(offset: clampedOffset)
        let len = keys.count
        place(min(range.lowerBound, len)..<min(range.upperBound, len))
    }

    public mutating func setMountedRange(_ newRange: Range<Int>) {
        place(newRange)
    }

    private mutating func place(_ newRange: Range<Int>) {
        let total = prefix(keys.count)
        let start = newRange.lowerBound
        let end = max(start, newRange.upperBound)
        range = start..<end
        before = prefix(start)
        after = start < end ? (total - rowEnd(end)) : (total - before)
    }

    private func anchorAt(offset: Float) -> Anchor? {
        let vis = visibleRange(offset: offset, pinned: false)
        for i in vis {
            if rows[keys[i]]?.height != nil {
                return Anchor(key: keys[i], top: padTop + sumsCache[i])
            }
        }
        return firstVisible(offset: offset) { _ in true }
    }

    private func overscan(offset: Float) -> (Int, Int) {
        let lo = offset - viewport * Self.overscan
        let hi = offset + viewport * (1.0 + Self.overscan)
        let start = partitionPoint(sumsCache.dropFirst()) { padTop + $0 - gap <= lo }
        let end = partitionPoint(sumsCache[..<keys.count]) { padTop + $0 < hi }
        return (start, end)
    }

    public func spare(offset: Float, pinned: Bool) -> Float {
        if pinned || keys.isEmpty { return 0 }
        let (start, end) = overscan(offset: min(offset, maxOffset()))
        let above = prefix(min(start, range.upperBound)) - prefix(min(range.lowerBound, start))
        let below = rowEnd(range.upperBound) - rowEnd(min(max(end, range.lowerBound), range.upperBound))
        return max(0, above) + max(0, below)
    }

    public func anchorDelta() -> Float {
        guard let anchor, let i = indexOf(anchor.key) else { return 0 }
        return padTop + prefix(i) - anchor.top
    }

    public func needsWindow(offset: Float, pinned: Bool) -> Bool {
        if keys.isEmpty { return false }
        if pinned { return range.upperBound != keys.count }
        let edge = viewport * (indexed ? Self.indexedEdge : 0.5)
        let winTop = padTop + before
        let winBottom = padTop + rowEnd(range.upperBound)
        return (range.lowerBound > 0 && offset < winTop + edge)
            || (range.upperBound < keys.count && offset + viewport > winBottom - edge)
    }

    public func unfilled(offset: Float, pinned: Bool) -> Int {
        if keys.isEmpty { return 0 }
        if pinned { return max(0, keys.count - range.upperBound) }
        let (start, end) = overscan(offset: min(offset, maxOffset()))
        return max(0, range.lowerBound - start) + max(0, end - range.upperBound)
    }

    private func partitionPoint(_ slice: ArraySlice<Float>, where predicate: (Float) -> Bool) -> Int {
        var lo = 0
        var hi = slice.count
        let base = slice.startIndex
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if predicate(slice[base + mid]) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}

// MARK: - Virtual Pins & Offscreen Selection State (`crates/rune/src/runtime/virtual/pins.rs`)

/// One selectable text inside an offscreen virtual row (`pins.rs::OffscreenText`).
public struct VirtualOffscreenText: Sendable, Equatable {
    public var listPath: String
    public var rowKey: String
    public var rowIndex: Int
    public var orderInRow: Int
    public var relPath: String
    public var path: String
    public var key: String?
    public var groupPath: String?
    public var content: String
    public var uncopied: [Range<Int>]
    public var copyBreakBefore: UInt8
    public var copyBreakAfter: UInt8
    public var copyPrefix: String?
    /// True when this text and the previous selectable text in the same row share a horizontal
    /// (`FlexDirection.row` / `.rowReverse`) lowest common ancestor (table cells).
    public var tabBefore: Bool

    public init(
        listPath: String,
        rowKey: String,
        rowIndex: Int,
        orderInRow: Int,
        relPath: String,
        path: String,
        key: String?,
        groupPath: String?,
        content: String,
        uncopied: [Range<Int>] = [],
        copyBreakBefore: UInt8 = 1,
        copyBreakAfter: UInt8 = 1,
        copyPrefix: String? = nil,
        tabBefore: Bool = false
    ) {
        self.listPath = listPath
        self.rowKey = rowKey
        self.rowIndex = rowIndex
        self.orderInRow = orderInRow
        self.relPath = relPath
        self.path = path
        self.key = key
        self.groupPath = groupPath
        self.content = content
        self.uncopied = uncopied
        self.copyBreakBefore = copyBreakBefore
        self.copyBreakAfter = copyBreakAfter
        self.copyPrefix = copyPrefix
        self.tabBefore = tabBefore
    }
}

/// A `selectionCopy` provider captured alongside offscreen row texts (`pins.rs`).
public struct VirtualSelectionCopyProvider: @unchecked Sendable {
    public let path: String
    public let copy: (TextSelection) -> String?

    public init(path: String, copy: @escaping (TextSelection) -> String?) {
        self.path = path
        self.copy = copy
    }
}

/// What the last commit collected offscreen rows under (`pins.rs::Scope`).
public struct VirtualSelectionScope: Sendable, Equatable {
    public var groupPath: String?
    public var inert: Bool

    public init(groupPath: String? = nil, inert: Bool = false) {
        self.groupPath = groupPath
        self.inert = inert
    }
}

/// What a virtual list keeps for text selection (`crates/rune/src/runtime/virtual/pins.rs::Pins`).
/// One state, so the pinned rows, their texts and the row source are cleared and filled together.
public struct VirtualPins: Sendable {
    /// Type-erased row builder used when `Source` is `.rebuild` (`El::virtualRows`).
    public struct RebuildSource: @unchecked Sendable {
        public typealias CollectFn = (
            _ index: Int,
            _ listPath: String,
            _ rowKey: String,
            _ groupPath: String?,
            _ inert: Bool
        ) -> (texts: [VirtualOffscreenText], providers: [VirtualSelectionCopyProvider], hasVirtual: Bool)

        private let collectFn: CollectFn

        public init(_ collectFn: @escaping CollectFn) {
            self.collectFn = collectFn
        }

        public static func fromElBuilder<State>(_ build: @escaping (Int) -> El<State>) -> RebuildSource {
            RebuildSource { index, listPath, rowKey, groupPath, inert in
                let row = build(index).key(rowKey)
                var texts: [VirtualOffscreenText] = []
                var providers: [VirtualSelectionCopyProvider] = []
                VirtualSelectionCollector.collectVirtualRowSelection(
                    rowEl: row,
                    listPath: listPath,
                    rowKey: rowKey,
                    rowIndex: index,
                    listGroup: groupPath,
                    listInert: inert,
                    texts: &texts,
                    copyProviders: &providers
                )
                return (texts, providers, VirtualSelectionCollector.elContainsVirtual(row))
            }
        }

        internal static func fromRowSource<State>(
            state: State,
            rowSource: VirtualRowSource<State>
        ) -> RebuildSource {
            fromElBuilder { rowSource.build(state, $0) }
        }

        public static let empty = RebuildSource { _, _, _, _, _ in ([], [], false) }

        public func buildRowSelection(
            index: Int,
            listPath: String,
            rowKey: String,
            groupPath: String?,
            inert: Bool
        ) -> (texts: [VirtualOffscreenText], providers: [VirtualSelectionCopyProvider], hasVirtual: Bool) {
            collectFn(index, listPath, rowKey, groupPath, inert)
        }
    }

    /// Where an offscreen row comes from (`pins.rs::Source`).
    public enum Source: Sendable {
        /// `El::virtualRows`: a row is built when selection needs it.
        case rebuild(RebuildSource)
        /// Rows the view built; the ones outside the window are kept by index.
        case stored

        public var rebuild: RebuildSource? {
            if case .rebuild(let src) = self { return src }
            return nil
        }
    }

    /// What changes what a list keeps (`pins.rs::PinsEvent`).
    public enum Event: Sendable {
        /// No text is selected: drop the rows and their texts. The source stays.
        case clear
        /// The selection's anchor and focus rows in this list (each `nil` when not in this list).
        case select(anchor: String?, focus: String?)
        /// A selection request pinned `key` and built the texts for it.
        case pin(key: String, texts: [VirtualOffscreenText], providers: [VirtualSelectionCopyProvider])
    }

    public struct PinnedState: Sendable {
        /// The selection's anchor and focus rows, anchor first, deduplicated.
        public var rows: [String] = []
        /// Selectable texts of `rows` that were offscreen when the commit built them.
        public var texts: [VirtualOffscreenText] = []
        /// `selectionCopy` providers found beside `texts`.
        public var providers: [VirtualSelectionCopyProvider] = []
        public var source: Source = .stored

        public init(
            rows: [String] = [],
            texts: [VirtualOffscreenText] = [],
            providers: [VirtualSelectionCopyProvider] = [],
            source: Source = .stored
        ) {
            self.rows = rows
            self.texts = texts
            self.providers = providers
            self.source = source
        }
    }

    /// `nil` means `Pins::None` (the list has not committed yet); non-nil is `Pins::Pinned`.
    public private(set) var state: PinnedState? = nil

    public init() {}

    public var isNone: Bool { state == nil }
    public var rows: [String] { state?.rows ?? [] }
    public var texts: [VirtualOffscreenText] { state?.texts ?? [] }
    public var providers: [VirtualSelectionCopyProvider] { state?.providers ?? [] }
    public var source: Source? { state?.source }
    public var textsCapacity: Int { state?.texts.capacity ?? 0 }
    public var providersCapacity: Int { state?.providers.capacity ?? 0 }

    /// Whether row `key`'s texts are already kept.
    public func hasTextRow(_ key: String) -> Bool {
        texts.contains { $0.rowKey == key }
    }

    /// Clears the kept texts and providers in place at the start of a commit, preserving buffer
    /// capacity (`pins.rs::clear_texts`).
    public mutating func clearTexts() {
        guard state != nil else { return }
        state!.texts.removeAll(keepingCapacity: true)
        state!.providers.removeAll(keepingCapacity: true)
    }

    /// Borrows the kept text and provider buffers in place when the list has committed
    /// (`pins.rs::text_buffers`), returning `nil` for `Pins::None`.
    public mutating func withTextBuffers<R>(
        _ body: (inout [VirtualOffscreenText], inout [VirtualSelectionCopyProvider]) throws -> R
    ) rethrows -> R? {
        guard var s = state else { return nil }
        state = nil
        defer { state = s }
        return try body(&s.texts, &s.providers)
    }

    /// Installs the commit's row source, keeping the kept rows, texts and providers (`pins.rs::set_source`).
    public mutating func setSource(_ source: Source) {
        if state == nil {
            state = PinnedState(source: source)
        } else {
            state!.source = source
        }
    }

    /// Applies `event`, keeping the rows, their texts and the source one state (`pins.rs::sync`).
    public mutating func sync(_ event: Event) {
        switch event {
        case .clear:
            guard state != nil else { return }
            state!.rows.removeAll(keepingCapacity: true)
            state!.texts.removeAll(keepingCapacity: true)
            state!.providers.removeAll(keepingCapacity: true)

        case .select(let anchor, let focus):
            if state == nil {
                state = PinnedState(source: .stored)
            }
            state!.rows.removeAll(keepingCapacity: true)
            if let anchor {
                state!.rows.append(anchor)
            }
            if let focus, !state!.rows.contains(focus) {
                state!.rows.append(focus)
            }
            // Keep copy providers across a selection change; only a commit and clear drop them.
            let pinnedRows = state!.rows
            state!.texts.removeAll { text in
                !pinnedRows.contains(text.rowKey)
            }

        case .pin(let key, let newTexts, let newProviders):
            if state == nil {
                state = PinnedState(source: .stored)
            }
            if !state!.rows.contains(key) {
                state!.rows.append(key)
            }
            state!.texts.append(contentsOf: newTexts)
            state!.providers.append(contentsOf: newProviders)
        }
    }
}

/// Offscreen selection state retained on a virtual list (`pins.rs::PinnedSelection`).
public struct VirtualPinnedSelection: Sendable {
    public var pins: VirtualPins = VirtualPins()
    public var scope: VirtualSelectionScope = VirtualSelectionScope()
    public var storedBuilders: [Int: VirtualPins.RebuildSource] = [:]

    public init(
        pins: VirtualPins = VirtualPins(),
        scope: VirtualSelectionScope = VirtualSelectionScope(),
        storedBuilders: [Int: VirtualPins.RebuildSource] = [:]
    ) {
        self.pins = pins
        self.scope = scope
        self.storedBuilders = storedBuilders
    }
}

// MARK: - Virtual Row Reorder (`crates/rune/src/runtime/virtual/row_reorder.rs`)

/// One growth stack's rows that the last commit reordered (`row_reorder.rs::Reorder`).
public struct VirtualRowReorder: Sendable, Equatable {
    /// How far each moved row's top jumped: where it was drawn, less where it now lays out.
    public private(set) var jumps: [NodeId: Float] = [:]

    public init(jumps: [NodeId: Float] = [:]) {
        self.jumps = jumps
    }

    /// Measures a commit taking the stack from `old` to `new` presented order, given each row's
    /// presented height (`nil` for a row with none) and the gap between rows. A commit that
    /// lands its changes (`animates == false`) moves nothing.
    public mutating func measure(
        animates: Bool,
        old: [NodeId],
        new: [NodeId],
        gap: Float,
        height: (NodeId) -> Float?
    ) {
        jumps.removeAll(keepingCapacity: true)
        guard animates, old != new else { return }

        var oldAt: [NodeId: Int] = [:]
        oldAt.reserveCapacity(old.count)
        for (k, id) in old.enumerated() where height(id) != nil {
            oldAt[id] = k
        }

        var kept: [(id: NodeId, oldIndex: Int)] = []
        kept.reserveCapacity(min(oldAt.count, new.count))
        for id in new {
            if let k = oldAt[id] {
                kept.append((id, k))
            }
        }

        var strictlyIncreasing = true
        if kept.count >= 2 {
            for idx in 0..<(kept.count - 1) {
                if !(kept[idx].oldIndex < kept[idx + 1].oldIndex) {
                    strictlyIncreasing = false
                    break
                }
            }
        }
        if strictlyIncreasing { return }

        let before = kept.sorted { $0.oldIndex < $1.oldIndex }
        var top: Float = 0
        var was: [NodeId: Float] = [:]
        was.reserveCapacity(before.count)
        for entry in before {
            was[entry.id] = top
            top += (height(entry.id) ?? 0) + gap
        }

        top = 0
        for entry in kept {
            let jump = (was[entry.id] ?? 0) - top
            if abs(jump) > 1.0 / 64.0 {
                jumps[entry.id] = jump
            }
            top += (height(entry.id) ?? 0) + gap
        }
    }

    public func jump(for id: NodeId) -> Float {
        jumps[id] ?? 0
    }
}

// MARK: - Virtual Selection Anchors & Bounded Text Collector (`selection.rs`, `selection_collect.rs`)

/// A resolved selection endpoint: either a mounted node index or an offscreen text in a virtual list
/// (`selection.rs::EndRef`).
public enum VirtualEndRef: Sendable, Equatable, Hashable {
    case mounted(Int)
    case offscreen(listPath: String, textIndex: Int)
}

/// Auxiliary virtual-selection anchor & between-hash state paired with `ActiveSelection`
/// (`selection.rs::Selection` fields `anchor_end`, `far.end`, `between`, and `mounted_between`).
public struct VirtualSelectionAnchorState: Sendable, Equatable {
    public var anchorEnd: VirtualEnd?
    public var focusEnd: VirtualEnd?
    public var betweenHash: UInt64
    public var mountedBetween: [String: UInt64]

    public init(
        anchorEnd: VirtualEnd? = nil,
        focusEnd: VirtualEnd? = nil,
        betweenHash: UInt64 = 0,
        mountedBetween: [String: UInt64] = [:]
    ) {
        self.anchorEnd = anchorEnd
        self.focusEnd = focusEnd
        self.betweenHash = betweenHash
        self.mountedBetween = mountedBetween
    }
}

/// Selection state for a single mounted virtual list, pairing `VirtualListBookkeeping` with
/// `VirtualPinnedSelection`.
public struct VirtualListSelectionHost: Sendable {
    public var listPath: String
    public var bookkeeping: VirtualListBookkeeping
    public var selection: VirtualPinnedSelection

    public init(
        listPath: String,
        bookkeeping: VirtualListBookkeeping = VirtualListBookkeeping(),
        selection: VirtualPinnedSelection = VirtualPinnedSelection()
    ) {
        self.listPath = listPath
        self.bookkeeping = bookkeeping
        self.selection = selection
    }
}

/// Remount plan input for one virtual list (`commit/remount.rs`).
public struct VirtualRemountPlanInput: Sendable {
    public var listPath: String
    public var newRange: Range<Int>
    public var mountedKeys: Set<String>
    public var focusedRowKey: String?

    public init(
        listPath: String,
        newRange: Range<Int>,
        mountedKeys: Set<String>,
        focusedRowKey: String? = nil
    ) {
        self.listPath = listPath
        self.newRange = newRange
        self.mountedKeys = mountedKeys
        self.focusedRowKey = focusedRowKey
    }
}

/// Bounded incremental text joiner matching `crates/rune/src/runtime/selection/copy_join.rs`
/// with UTF-8 byte cap enforcement for `selection_collect.rs`.
public struct BoundedCopyJoin: Sendable {
    private var outBytes: [UInt8] = []
    private var after: UInt8 = 0
    private var pieces: Int = 0
    private var firstPrefixCount: Int = 0

    public init() {}

    public var currentByteCount: Int { outBytes.count }

    /// Adds `piece`, what bytes `range` of `content` copy as. Returns `true` when `cap` bytes
    /// cut it short.
    public mutating func push(
        content: String,
        uncopied: [Range<Int>],
        copyBreakBefore: UInt8,
        copyBreakAfter: UInt8,
        copyPrefix: String?,
        range: Range<Int>,
        piece: String,
        beside: Bool,
        cap: Int
    ) -> Bool {
        var leadBytes: [UInt8] = []
        if pieces > 0 {
            if beside {
                leadBytes.append(UInt8(ascii: "\t"))
            } else {
                let want = Int(max(max(after, copyBreakBefore), 1))
                var have = 0
                for b in outBytes.reversed() {
                    if b == UInt8(ascii: "\n") {
                        have += 1
                    } else {
                        break
                    }
                }
                if want > have {
                    leadBytes.append(contentsOf: repeatElement(UInt8(ascii: "\n"), count: want - have))
                }
            }
        }
        let prefixStr: String
        if let copyPrefix, Self.fromStart(content: content, uncopied: uncopied, range: range) {
            prefixStr = copyPrefix
        } else {
            prefixStr = ""
        }
        let prefixBytes = Array(prefixStr.utf8)
        if pieces == 0 {
            firstPrefixCount = prefixBytes.count
        }
        leadBytes.append(contentsOf: prefixBytes)
        pieces += 1
        after = copyBreakAfter

        if outBytes.count + leadBytes.count > cap {
            return true
        }
        outBytes.append(contentsOf: leadBytes)

        let pieceBytes = Array(piece.utf8)
        if outBytes.count + pieceBytes.count <= cap {
            outBytes.append(contentsOf: pieceBytes)
            return false
        }
        let remaining = max(0, cap - outBytes.count)
        let take = SelectionMath.floorCharBoundary(in: piece, offset: remaining)
        if take > 0 {
            outBytes.append(contentsOf: pieceBytes[..<take])
        }
        return true
    }

    public func finish() -> String {
        if pieces == 1 && firstPrefixCount > 0 && outBytes.count >= firstPrefixCount {
            return String(decoding: outBytes[firstPrefixCount...], as: UTF8.self)
        }
        return String(decoding: outBytes, as: UTF8.self)
    }

    private static func fromStart(content: String, uncopied: [Range<Int>], range: Range<Int>) -> Bool {
        let len = content.utf8.count
        let first = uncopied.isEmpty ? 0 : SelectionMath.trimUncopied(uncopied, range: (0, len)).0
        return !range.isEmpty && range.lowerBound <= first
    }
}

/// Virtual-row text selection collector, anchor resolver, and bounded copy engine
/// (`crates/rune/src/runtime/virtual/{selection,selection_collect}.rs`).
public enum VirtualSelectionCollector {

    public static func virtualNodePath(_ parent: String, key: String?, index: Int) -> String {
        let seg = key ?? "#\(index)"
        return parent.isEmpty ? seg : "\(parent)/\(seg)"
    }

    public static func elContainsVirtual<State>(_ root: El<State>) -> Bool {
        var stack: [El<State>] = [root]
        while let cur = stack.popLast() {
            if cur.virtualEstimate != nil || cur.virtualRowsSource != nil {
                return true
            }
            if !cur.children.isEmpty {
                stack.append(contentsOf: cur.children)
            }
        }
        return false
    }

    /// Collects selectable texts and `selectionCopy` providers from an offscreen row `rowEl`
    /// (`selection.rs::collect_virtual_row_selection`).
    public static func collectVirtualRowSelection<State>(
        rowEl: El<State>,
        listPath: String,
        rowKey: String,
        rowIndex: Int,
        listGroup: String?,
        listInert: Bool,
        texts: inout [VirtualOffscreenText],
        copyProviders: inout [VirtualSelectionCopyProvider]
    ) {
        var orderInRow = 0
        let rowPath = "\(listPath)/\(rowKey)"
        walkRowEl(
            el: rowEl,
            listPath: listPath,
            rowKey: rowKey,
            rowIndex: rowIndex,
            path: rowPath,
            relPath: "",
            parentGroup: listGroup,
            parentInert: listInert,
            orderInRow: &orderInRow,
            texts: &texts,
            copyProviders: &copyProviders
        )
    }

    /// Collects one built row's selectable texts into `pins` (`selection.rs::collect_row_into_pins`).
    public static func collectRowIntoPins<State>(
        pins: inout VirtualPins,
        rowEl: El<State>,
        listPath: String,
        rowKey: String,
        rowIndex: Int,
        listGroup: String?,
        listInert: Bool
    ) {
        pins.withTextBuffers { texts, providers in
            collectVirtualRowSelection(
                rowEl: rowEl,
                listPath: listPath,
                rowKey: rowKey,
                rowIndex: rowIndex,
                listGroup: listGroup,
                listInert: listInert,
                texts: &texts,
                copyProviders: &providers
            )
        }
    }

    private static func walkRowEl<State>(
        el: El<State>,
        listPath: String,
        rowKey: String,
        rowIndex: Int,
        path: String,
        relPath: String,
        parentGroup: String?,
        parentInert: Bool,
        orderInRow: inout Int,
        texts: inout [VirtualOffscreenText],
        copyProviders: inout [VirtualSelectionCopyProvider]
    ) {
        let inert = parentInert || el.isInert
        let group = el.isSelectionGroup ? path : parentGroup
        if !inert && el.hasSelectionCopyHandler {
            copyProviders.append(VirtualSelectionCopyProvider(path: path) { sel in
                el.invokeSelectionCopy(sel)
            })
        }
        let isRow = el.layout.displayMode == .flex
            && (el.layout.direction == .row || el.layout.direction == .rowReverse)
        var hadChildText = false

        if !inert,
           el.handlers.editLens == nil,
           !el.isSecure,
           el.isSelectable,
           let content = (el.liveText?.get() ?? el.plainText ?? el.richSpans?.map(\.text).joined()) {
            let breaks = el.copyBreaksPair
            texts.append(VirtualOffscreenText(
                listPath: listPath,
                rowKey: rowKey,
                rowIndex: rowIndex,
                orderInRow: orderInRow,
                relPath: relPath,
                path: path,
                key: el.keyId,
                groupPath: group,
                content: content,
                uncopied: el.uncopiedRanges,
                copyBreakBefore: breaks.before,
                copyBreakAfter: breaks.after,
                copyPrefix: el.copyPrefixString,
                tabBefore: false
            ))
            orderInRow += 1
            hadChildText = true
        }

        for (i, child) in el.children.enumerated() {
            let childPath = virtualNodePath(path, key: child.keyId, index: i)
            let childRel = virtualNodePath(relPath, key: child.keyId, index: i)
            let beforeLen = texts.count
            walkRowEl(
                el: child,
                listPath: listPath,
                rowKey: rowKey,
                rowIndex: rowIndex,
                path: childPath,
                relPath: childRel,
                parentGroup: group,
                parentInert: inert,
                orderInRow: &orderInRow,
                texts: &texts,
                copyProviders: &copyProviders
            )
            if texts.count > beforeLen {
                if hadChildText {
                    texts[beforeLen].tabBefore = isRow
                }
                hadChildText = true
            }
        }
    }

    /// Converts an `VirtualOffscreenText` slice into a `SelectedText` (`selection.rs::offscreen_piece`).
    public static func offscreenPiece(
        _ t: VirtualOffscreenText,
        range: Range<Int>,
        base: String? = nil
    ) -> SelectedText {
        let path: String
        if let b = base {
            if b == t.path {
                path = ""
            } else if t.path.hasPrefix(b + "/") {
                path = String(t.path.dropFirst(b.count + 1))
            } else {
                path = t.path
            }
        } else {
            path = t.path
        }

        let utf8 = Array(t.content.utf8)
        let len = utf8.count
        let (fullA, fullB): (Int, Int) = t.uncopied.isEmpty
            ? (0, len)
            : SelectionMath.trimUncopied(t.uncopied, range: (0, len))
        let whole = !range.isEmpty && len > 0 && range.lowerBound <= fullA && range.upperBound >= fullB
        let text = CopyJoin.copySlice(in: t.content, range: range, uncopied: t.uncopied)
        let contentSlice: String
        if range.lowerBound >= 0, range.upperBound <= len, range.lowerBound < range.upperBound {
            contentSlice = String(bytes: utf8[range], encoding: .utf8) ?? ""
        } else {
            contentSlice = ""
        }
        return SelectedText(
            path: path,
            key: t.key,
            range: range,
            len: len,
            whole: whole,
            text: text,
            content: contentSlice
        )
    }

    /// Runs `remount_virtuals`'s planning + fallback pin-collection phase (`commit/remount.rs:202-321`).
    /// Clears every list's texts in place first, then builds focused, pinned, and entering rows in
    /// tree order until an entering row holds a nested virtual list (returning `true` on fallback).
    public static func remountVirtualPins(
        plans: [VirtualRemountPlanInput],
        lists: inout [String: VirtualListSelectionHost]
    ) -> Bool {
        struct Prepared {
            var path: String
            var focusedIdx: Int?
            var pinnedIndices: [Int]
            var enteringIndices: [Int]
            var listGroup: String?
            var inert: Bool
            var rebuild: VirtualPins.RebuildSource
        }

        var prepared: [Prepared] = []
        prepared.reserveCapacity(plans.count)

        for plan in plans {
            guard var list = lists[plan.listPath] else { continue }
            list.selection.pins.clearTexts()
            let rebuild = list.selection.pins.source?.rebuild ?? .empty
            let focusedIdx = plan.focusedRowKey
                .flatMap { list.bookkeeping.indexOf($0) }
                .flatMap { !plan.newRange.contains($0) ? $0 : nil }
            let pinnedIndices = list.selection.pins.rows.compactMap { key -> Int? in
                guard let idx = list.bookkeeping.indexOf(key), !plan.newRange.contains(idx) else {
                    return nil
                }
                return idx
            }
            let enteringIndices = plan.newRange.filter { idx in
                idx < list.bookkeeping.keys.count && !plan.mountedKeys.contains(list.bookkeeping.keys[idx])
            }
            let scope = list.selection.scope
            lists[plan.listPath] = list
            prepared.append(Prepared(
                path: plan.listPath,
                focusedIdx: focusedIdx,
                pinnedIndices: pinnedIndices,
                enteringIndices: enteringIndices,
                listGroup: scope.groupPath,
                inert: scope.inert,
                rebuild: rebuild
            ))
        }

        for p in prepared {
            guard var list = lists[p.path] else { continue }
            if let fi = p.focusedIdx, fi < list.bookkeeping.keys.count {
                let key = list.bookkeeping.keys[fi]
                let built = p.rebuild.buildRowSelection(
                    index: fi,
                    listPath: p.path,
                    rowKey: key,
                    groupPath: p.listGroup,
                    inert: p.inert
                )
                if p.pinnedIndices.contains(fi) {
                    list.selection.pins.withTextBuffers { texts, providers in
                        texts.append(contentsOf: built.texts)
                        providers.append(contentsOf: built.providers)
                    }
                }
            }
            for pi in p.pinnedIndices where pi != p.focusedIdx && pi < list.bookkeeping.keys.count {
                let key = list.bookkeeping.keys[pi]
                let built = p.rebuild.buildRowSelection(
                    index: pi,
                    listPath: p.path,
                    rowKey: key,
                    groupPath: p.listGroup,
                    inert: p.inert
                )
                list.selection.pins.withTextBuffers { texts, providers in
                    texts.append(contentsOf: built.texts)
                    providers.append(contentsOf: built.providers)
                }
            }
            lists[p.path] = list

            for ei in p.enteringIndices where ei < list.bookkeeping.keys.count {
                let key = list.bookkeeping.keys[ei]
                let built = p.rebuild.buildRowSelection(
                    index: ei,
                    listPath: p.path,
                    rowKey: key,
                    groupPath: p.listGroup,
                    inert: p.inert
                )
                if built.hasVirtual {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Selection End & Group Resolution (`selection.rs`)

    private struct TreeIndex {
        let byPath: [String: Int]
        let parentIndices: [Int?]

        init(nodes: [SelectableNodeSnapshot]) {
            var map: [String: Int] = [:]
            map.reserveCapacity(nodes.count)
            for (idx, n) in nodes.enumerated() {
                map[n.path] = idx
            }
            self.byPath = map
            self.parentIndices = nodes.map { $0.parentPath.flatMap { map[$0] } }
        }
    }

    public static func virtualListAllowed(
        listPath: String,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost]
    ) -> Bool {
        nodes.contains { $0.path == listPath } && !(lists[listPath]?.selection.scope.inert ?? false)
    }

    public static func endPath(
        _ end: VirtualEndRef,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost]
    ) -> String {
        switch end {
        case .mounted(let i):
            return nodes[i].path
        case .offscreen(let listPath, let ti):
            return lists[listPath]?.selection.pins.texts[ti].path ?? ""
        }
    }

    public static func endContent(
        _ end: VirtualEndRef,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost]
    ) -> String {
        switch end {
        case .mounted(let i):
            return nodes[i].text
        case .offscreen(let listPath, let ti):
            return lists[listPath]?.selection.pins.texts[ti].content ?? ""
        }
    }

    public static func endGroupPath(
        _ end: VirtualEndRef,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost]
    ) -> String? {
        switch end {
        case .mounted(let i):
            return SelectAllResolver.groupPath(forNodeAt: i, in: nodes)
        case .offscreen(let listPath, let ti):
            return lists[listPath]?.selection.pins.texts[ti].groupPath
        }
    }

    public static func endSameGroup(
        _ a: VirtualEndRef,
        _ b: VirtualEndRef,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost]
    ) -> Bool {
        guard let ga = endGroupPath(a, nodes: nodes, lists: lists) else { return false }
        return endGroupPath(b, nodes: nodes, lists: lists) == ga
    }

    /// Canonical pre-order key `(listOrNodeSlot, rowIndex, inRowOrder)` (`selection.rs::tree_order`).
    public static func treeOrder(
        _ end: VirtualEndRef,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost]
    ) -> (Int, Int, Int) {
        treeOrder(end, nodes: nodes, lists: lists, index: TreeIndex(nodes: nodes))
    }

    private static func treeOrder(
        _ end: VirtualEndRef,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost],
        index: TreeIndex
    ) -> (Int, Int, Int) {
        switch end {
        case .offscreen(let listPath, let ti):
            guard let t = lists[listPath]?.selection.pins.texts[ti] else { return (0, 0, 0) }
            let listNode = index.byPath[t.listPath] ?? 0
            let rowIndex = lists[t.listPath]?.bookkeeping.indexOf(t.rowKey) ?? t.rowIndex
            return (listNode * 2 + 1, rowIndex, t.orderInRow)
        case .mounted(let i):
            var cur = i
            while let p = index.parentIndices[cur] {
                if let v = lists[nodes[p].path] {
                    let rowKey = nodes[cur].key ?? rowKeyFromPath(nodes[cur].path, listPath: nodes[p].path)
                    let rowIndex = rowKey.flatMap { v.bookkeeping.indexOf($0) } ?? 0
                    return (p * 2 + 1, rowIndex, i)
                }
                cur = p
            }
            return (i * 2, 0, 0)
        }
    }

    private static func rowKeyFromPath(_ rowPath: String, listPath: String) -> String? {
        let prefix = listPath + "/"
        guard rowPath.hasPrefix(prefix) else { return nil }
        let seg = String(rowPath.dropFirst(prefix.count))
        if seg.contains("/") { return nil }
        return seg.hasPrefix("@") ? String(seg.dropFirst()) : seg
    }

    /// Virtual-list row identity of `end`, if `end` lies inside a virtual list (`selection.rs::virtual_end_of`).
    public static func virtualEndOf(
        _ end: VirtualEndRef,
        offset: Int,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost]
    ) -> VirtualEnd? {
        virtualEndOf(end, offset: offset, nodes: nodes, lists: lists, index: TreeIndex(nodes: nodes))
    }

    private static func virtualEndOf(
        _ end: VirtualEndRef,
        offset: Int,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost],
        index: TreeIndex
    ) -> VirtualEnd? {
        switch end {
        case .offscreen(let listPath, let ti):
            guard let t = lists[listPath]?.selection.pins.texts[ti] else { return nil }
            let rowIndex = lists[t.listPath]?.bookkeeping.indexOf(t.rowKey) ?? t.rowIndex
            return VirtualEnd(
                listPath: t.listPath,
                rowKey: t.rowKey,
                rowIndex: rowIndex,
                relPath: t.relPath,
                offset: offset
            )
        case .mounted(let i):
            var cur = i
            while let p = index.parentIndices[cur] {
                if let v = lists[nodes[p].path] {
                    guard let rowKey = nodes[cur].key ?? rowKeyFromPath(nodes[cur].path, listPath: nodes[p].path),
                          let rowIndex = v.bookkeeping.indexOf(rowKey) else {
                        return nil
                    }
                    let rowPath = nodes[cur].path
                    let relPath: String
                    if i == cur {
                        relPath = ""
                    } else if nodes[i].path.hasPrefix(rowPath + "/") {
                        relPath = String(nodes[i].path.dropFirst(rowPath.count + 1))
                    } else {
                        return nil
                    }
                    return VirtualEnd(
                        listPath: nodes[p].path,
                        rowKey: rowKey,
                        rowIndex: rowIndex,
                        relPath: relPath,
                        offset: offset
                    )
                }
                cur = p
            }
            return nil
        }
    }

    public static func resolveEnd(
        path: String,
        virtualEnd: VirtualEnd?,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost]
    ) -> VirtualEndRef? {
        let index = TreeIndex(nodes: nodes)
        if let end = virtualEnd,
           let r = resolveVirtualEnd(end, nodes: nodes, lists: lists, index: index) {
            return r
        }
        if let i = index.byPath[path], nodes[i].isSelectable {
            return .mounted(i)
        }
        for listPath in lists.keys.sorted() {
            guard virtualListAllowed(listPath: listPath, nodes: nodes, lists: lists),
                  let v = lists[listPath] else {
                continue
            }
            for (ti, t) in v.selection.pins.texts.enumerated() {
                if t.path == path,
                   let r = v.bookkeeping.indexOf(t.rowKey),
                   !v.bookkeeping.range.contains(r) {
                    return .offscreen(listPath: listPath, textIndex: ti)
                }
            }
        }
        return nil
    }

    private static func normalizedVirtualRelPath(_ rel: String) -> String {
        guard !rel.isEmpty else { return rel }
        return rel.split(separator: "/", omittingEmptySubsequences: false).map { seg in
            seg.hasPrefix("@") ? String(seg.dropFirst()) : String(seg)
        }.joined(separator: "/")
    }

    private static func resolveVirtualEnd(
        _ end: VirtualEnd,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost],
        index: TreeIndex
    ) -> VirtualEndRef? {
        guard virtualListAllowed(listPath: end.listPath, nodes: nodes, lists: lists),
              let v = lists[end.listPath],
              let rowIdx = v.bookkeeping.indexOf(end.rowKey) else {
            return nil
        }
        let wantRel = normalizedVirtualRelPath(end.relPath)
        if v.bookkeeping.range.contains(rowIdx) {
            let altRow = "\(end.listPath)/@\(end.rowKey)"
            let rawRow = "\(end.listPath)/\(end.rowKey)"
            for base in [altRow, rawRow] {
                let full = end.relPath.isEmpty ? base : "\(base)/\(end.relPath)"
                if let i = index.byPath[full], nodes[i].isSelectable {
                    return .mounted(i)
                }
            }
            for i in nodes.indices where nodes[i].isSelectable {
                let p = nodes[i].path
                if p == altRow || p.hasPrefix(altRow + "/") {
                    let tail = String(p.dropFirst(altRow.count))
                    let rel = tail.hasPrefix("/") ? String(tail.dropFirst()) : tail
                    if tail.isEmpty ? wantRel.isEmpty : normalizedVirtualRelPath(rel) == wantRel {
                        return .mounted(i)
                    }
                } else if p == rawRow || p.hasPrefix(rawRow + "/") {
                    let tail = String(p.dropFirst(rawRow.count))
                    let rel = tail.hasPrefix("/") ? String(tail.dropFirst()) : tail
                    if tail.isEmpty ? wantRel.isEmpty : normalizedVirtualRelPath(rel) == wantRel {
                        return .mounted(i)
                    }
                }
            }
            return nil
        }
        for (ti, t) in v.selection.pins.texts.enumerated() {
            if t.rowKey == end.rowKey && (t.relPath == end.relPath || normalizedVirtualRelPath(t.relPath) == wantRel) {
                return .offscreen(listPath: end.listPath, textIndex: ti)
            }
        }
        return nil
    }

    public static func selectionHolderEnd(
        phase: SelectionPhase,
        anchorState: VirtualSelectionAnchorState,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost]
    ) -> VirtualEndRef? {
        guard let sel = phase.selection,
              let h = resolveEnd(path: sel.path, virtualEnd: anchorState.anchorEnd, nodes: nodes, lists: lists) else {
            return nil
        }
        let index = TreeIndex(nodes: nodes)
        let upto: Int
        if let far = sel.far {
            if let f = resolveEnd(path: far.path, virtualEnd: anchorState.focusEnd, nodes: nodes, lists: lists),
               treeOrder(f, nodes: nodes, lists: lists, index: index)
                    > treeOrder(h, nodes: nodes, lists: lists, index: index) {
                upto = sel.content.utf8.count
            } else {
                upto = max(sel.anchor, sel.originEnd)
            }
        } else {
            upto = max(max(sel.anchor, sel.focus), sel.originEnd)
        }
        let now = endContent(h, nodes: nodes, lists: lists)
        return SelectionMath.kept(then: sel.content, now: now, upto: upto) ? h : nil
    }

    public static func focusHolderEnd(
        holder: VirtualEndRef,
        phase: SelectionPhase,
        anchorState: VirtualSelectionAnchorState,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost]
    ) -> VirtualEndRef? {
        guard let sel = phase.selection else { return nil }
        guard let far = sel.far else { return holder }
        guard let f = resolveEnd(path: far.path, virtualEnd: anchorState.focusEnd, nodes: nodes, lists: lists) else {
            return nil
        }
        let index = TreeIndex(nodes: nodes)
        let upto = treeOrder(f, nodes: nodes, lists: lists, index: index)
                > treeOrder(holder, nodes: nodes, lists: lists, index: index)
            ? sel.focus
            : far.content.utf8.count
        let now = endContent(f, nodes: nodes, lists: lists)
        guard endSameGroup(f, holder, nodes: nodes, lists: lists),
              SelectionMath.kept(then: far.content, now: now, upto: upto) else {
            return nil
        }
        return f
    }

    /// Updates `anchorEnd`, `focusEnd`, and each virtual list's pins (`selection.rs::sync_selection_pins`).
    public static func syncSelectionPins(
        phase: SelectionPhase,
        anchorState: inout VirtualSelectionAnchorState,
        nodes: [SelectableNodeSnapshot],
        lists: inout [String: VirtualListSelectionHost]
    ) {
        guard let sel = phase.selection else {
            anchorState.mountedBetween.removeAll(keepingCapacity: true)
            anchorState.anchorEnd = nil
            anchorState.focusEnd = nil
            for listPath in lists.keys {
                lists[listPath]?.selection.pins.sync(.clear)
            }
            return
        }
        let index = TreeIndex(nodes: nodes)
        if let h = selectionHolderEnd(phase: phase, anchorState: anchorState, nodes: nodes, lists: lists) {
            anchorState.anchorEnd = virtualEndOf(h, offset: sel.anchor, nodes: nodes, lists: lists, index: index)
            if sel.far != nil {
                anchorState.focusEnd = focusHolderEnd(
                    holder: h,
                    phase: phase,
                    anchorState: anchorState,
                    nodes: nodes,
                    lists: lists
                ).flatMap { virtualEndOf($0, offset: sel.focus, nodes: nodes, lists: lists, index: index) }
            } else {
                anchorState.focusEnd = nil
            }
        }
        let aEnd = anchorState.anchorEnd
        let fEnd = sel.far != nil ? anchorState.focusEnd : nil
        for listPath in lists.keys {
            let anchorKey = (aEnd?.listPath == listPath) ? aEnd?.rowKey : nil
            let focusKey = (fEnd?.listPath == listPath) ? fEnd?.rowKey : nil
            lists[listPath]?.selection.pins.sync(.select(anchor: anchorKey, focus: focusKey))
        }
    }

    public static func isCrossRowVirtual(
        _ h: VirtualEndRef,
        _ f: VirtualEndRef,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost]
    ) -> (listPath: String, startRow: Int, endRow: Int)? {
        let index = TreeIndex(nodes: nodes)
        let hOrd = treeOrder(h, nodes: nodes, lists: lists, index: index)
        let fOrd = treeOrder(f, nodes: nodes, lists: lists, index: index)
        let (first, last) = hOrd <= fOrd ? (h, f) : (f, h)
        let va = virtualEndOf(first, offset: 0, nodes: nodes, lists: lists, index: index)
        let vb = virtualEndOf(last, offset: 0, nodes: nodes, lists: lists, index: index)
        switch (va, vb) {
        case (.some(let a), .some(let b)):
            guard a.listPath == b.listPath, a.rowIndex != b.rowIndex else { return nil }
            return (a.listPath, min(a.rowIndex, b.rowIndex), max(a.rowIndex, b.rowIndex))
        case (.some(let a), .none):
            guard let v = lists[a.listPath], !v.bookkeeping.keys.isEmpty else { return nil }
            return (a.listPath, a.rowIndex, v.bookkeeping.keys.count - 1)
        case (.none, .some(let b)):
            return (b.listPath, 0, b.rowIndex)
        case (.none, .none):
            let firstOrd = treeOrder(first, nodes: nodes, lists: lists, index: index)
            let lastOrd = treeOrder(last, nodes: nodes, lists: lists, index: index)
            for listPath in lists.keys.sorted() {
                guard let v = lists[listPath],
                      !v.bookkeeping.keys.isEmpty,
                      let ln = index.byPath[listPath] else {
                    continue
                }
                let listOrd = (ln * 2 + 1, 0, 0)
                if firstOrd < listOrd && lastOrd > listOrd {
                    return (listPath, 0, v.bookkeeping.keys.count - 1)
                }
            }
            return nil
        }
    }

    private static func mountedRowHash(
        listPath: String,
        rowKey: String,
        groupPath: String,
        nodes: [SelectableNodeSnapshot],
        index: TreeIndex
    ) -> UInt64? {
        guard let listNode = index.byPath[listPath] else { return nil }
        let rowPath = "\(listPath)/\(rowKey)"
        let altRowPath = "\(listPath)/@\(rowKey)"
        guard let rowNode = ((listNode + 1)..<nodes.count).first(where: { j in
            index.parentIndices[j] == listNode
                && (nodes[j].path == rowPath || nodes[j].path == altRowPath || nodes[j].key == rowKey)
        }) else {
            return nil
        }
        var h: UInt64 = 0xcbf29ce484222325
        for j in rowNode..<nodes.count {
            if !isDescendantOrEqual(j, ancestor: rowNode, index: index) { break }
            if nodes[j].isSelectable
                && SelectAllResolver.groupPath(forNodeAt: j, in: nodes) == groupPath {
                fnvMix(&h, nodes[j].path)
                fnvMix(&h, nodes[j].text)
            }
        }
        return h
    }

    public static func betweenHashEnds(
        _ h: VirtualEndRef,
        _ f: VirtualEndRef,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost]
    ) -> UInt64 {
        var hasher: UInt64 = 0xcbf29ce484222325
        guard h != f, let gPath = endGroupPath(h, nodes: nodes, lists: lists) else {
            return hasher
        }
        let index = TreeIndex(nodes: nodes)
        let hOrd = treeOrder(h, nodes: nodes, lists: lists, index: index)
        let fOrd = treeOrder(f, nodes: nodes, lists: lists, index: index)
        let (first, last) = hOrd < fOrd ? (h, f) : (f, h)

        if let cross = isCrossRowVirtual(first, last, nodes: nodes, lists: lists) {
            if let g = index.byPath[gPath], let ln = index.byPath[cross.listPath] {
                let firstOrd = treeOrder(first, nodes: nodes, lists: lists, index: index)
                let lastOrd = treeOrder(last, nodes: nodes, lists: lists, index: index)
                for j in (g + 1)..<nodes.count {
                    guard !isDescendantOrEqual(j, ancestor: ln, index: index),
                          nodes[j].isSelectable,
                          SelectAllResolver.groupPath(forNodeAt: j, in: nodes) == gPath else {
                        continue
                    }
                    let ord = treeOrder(.mounted(j), nodes: nodes, lists: lists, index: index)
                    if ord > firstOrd && ord < lastOrd {
                        fnvMix(&hasher, nodes[j].path)
                        fnvMix(&hasher, nodes[j].text)
                    }
                }
            }
            if let v = lists[cross.listPath], cross.endRow < v.bookkeeping.keys.count {
                for r in cross.startRow...cross.endRow {
                    fnvMix(&hasher, v.bookkeeping.keys[r])
                }
            }
            return hasher
        }

        switch (first, last) {
        case (.mounted(let i0), .mounted(let i1)):
            if let gPath = SelectAllResolver.groupPath(forNodeAt: i0, in: nodes), i0 + 1 < i1 {
                for j in (i0 + 1)..<i1 where nodes[j].isSelectable {
                    if SelectAllResolver.groupPath(forNodeAt: j, in: nodes) == gPath {
                        fnvMix(&hasher, nodes[j].path)
                        fnvMix(&hasher, nodes[j].text)
                    }
                }
            }
        case (.offscreen(let lp0, let ti0), .offscreen(let lp1, let ti1)) where lp0 == lp1:
            if let texts = lists[lp0]?.selection.pins.texts {
                let rowKey = texts[ti0].rowKey
                let o0 = texts[ti0].orderInRow
                let o1 = texts[ti1].orderInRow
                for t in texts where t.rowKey == rowKey && t.orderInRow > o0 && t.orderInRow < o1 && t.groupPath == gPath {
                    fnvMix(&hasher, t.path)
                    fnvMix(&hasher, t.content)
                }
            }
        default:
            break
        }
        return hasher
    }

    public static func sealBetween(
        phase: SelectionPhase,
        anchorState: inout VirtualSelectionAnchorState,
        nodes: [SelectableNodeSnapshot],
        lists: inout [String: VirtualListSelectionHost]
    ) {
        syncSelectionPins(phase: phase, anchorState: &anchorState, nodes: nodes, lists: &lists)
        anchorState.mountedBetween.removeAll(keepingCapacity: true)
        guard let h = selectionHolderEnd(phase: phase, anchorState: anchorState, nodes: nodes, lists: lists),
              let f = focusHolderEnd(holder: h, phase: phase, anchorState: anchorState, nodes: nodes, lists: lists) else {
            anchorState.betweenHash = 0
            return
        }
        anchorState.betweenHash = betweenHashEnds(h, f, nodes: nodes, lists: lists)
        let index = TreeIndex(nodes: nodes)
        if let gPath = endGroupPath(h, nodes: nodes, lists: lists),
           let cross = isCrossRowVirtual(h, f, nodes: nodes, lists: lists),
           let v = lists[cross.listPath],
           cross.startRow + 1 < cross.endRow {
            for r in (cross.startRow + 1)..<cross.endRow where v.bookkeeping.range.contains(r) {
                if r < v.bookkeeping.keys.count {
                    let key = v.bookkeeping.keys[r]
                    if let hash = mountedRowHash(
                        listPath: cross.listPath,
                        rowKey: key,
                        groupPath: gPath,
                        nodes: nodes,
                        index: index
                    ) {
                        anchorState.mountedBetween[key] = hash
                    }
                }
            }
        }
    }

    public static func betweenMatches(
        _ h: VirtualEndRef,
        _ f: VirtualEndRef,
        phase: SelectionPhase,
        anchorState: inout VirtualSelectionAnchorState,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost]
    ) -> Bool {
        guard phase.selection?.far != nil else { return true }
        let sealed = anchorState.betweenHash
        if betweenHashEnds(h, f, nodes: nodes, lists: lists) != sealed {
            return false
        }
        let index = TreeIndex(nodes: nodes)
        if let gPath = endGroupPath(h, nodes: nodes, lists: lists),
           let cross = isCrossRowVirtual(h, f, nodes: nodes, lists: lists),
           let v = lists[cross.listPath],
           cross.startRow + 1 < cross.endRow {
            for r in (cross.startRow + 1)..<cross.endRow where v.bookkeeping.range.contains(r) {
                if r < v.bookkeeping.keys.count {
                    let key = v.bookkeeping.keys[r]
                    if let hash = mountedRowHash(
                        listPath: cross.listPath,
                        rowKey: key,
                        groupPath: gPath,
                        nodes: nodes,
                        index: index
                    ) {
                        if let prev = anchorState.mountedBetween[key] {
                            if prev != hash { return false }
                        } else {
                            anchorState.mountedBetween[key] = hash
                        }
                    }
                }
            }
        }
        return true
    }

    public static func hasNonemptySelection(
        phase: SelectionPhase,
        anchorState: VirtualSelectionAnchorState,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost]
    ) -> Bool {
        guard let h = selectionHolderEnd(phase: phase, anchorState: anchorState, nodes: nodes, lists: lists),
              let f = focusHolderEnd(holder: h, phase: phase, anchorState: anchorState, nodes: nodes, lists: lists) else {
            return false
        }
        if h == f {
            guard let sel = phase.selection else { return false }
            let a = min(sel.anchor, sel.focus)
            let b = max(sel.anchor, sel.focus)
            return a < b && b <= endContent(h, nodes: nodes, lists: lists).utf8.count
        }
        return true
    }

    public static func selectionSpansUnmounted(
        phase: SelectionPhase,
        anchorState: VirtualSelectionAnchorState,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost]
    ) -> Bool {
        guard let h = selectionHolderEnd(phase: phase, anchorState: anchorState, nodes: nodes, lists: lists),
              let f = focusHolderEnd(holder: h, phase: phase, anchorState: anchorState, nodes: nodes, lists: lists) else {
            return false
        }
        if case .offscreen = h { return true }
        if case .offscreen = f { return true }
        guard case .mounted(let i0) = h, case .mounted(let i1) = f else { return true }
        if i0 == i1 { return false }
        let index = TreeIndex(nodes: nodes)
        let firstOrd = treeOrder(.mounted(min(i0, i1)), nodes: nodes, lists: lists, index: index)
        let lastOrd = treeOrder(.mounted(max(i0, i1)), nodes: nodes, lists: lists, index: index)
        for (listPath, v) in lists {
            if v.bookkeeping.keys.isEmpty
                || (v.bookkeeping.range.lowerBound == 0 && v.bookkeeping.range.upperBound >= v.bookkeeping.keys.count) {
                continue
            }
            guard let ln = index.byPath[listPath] else { continue }
            let headUnmounted = v.bookkeeping.range.lowerBound > 0
                && (ln * 2 + 1, 0, Int.max) >= firstOrd
                && (ln * 2 + 1, 0, 0) <= lastOrd
            let lastR = v.bookkeeping.keys.count - 1
            let tailUnmounted = v.bookkeeping.range.upperBound < v.bookkeeping.keys.count
                && (ln * 2 + 1, lastR, Int.max) >= firstOrd
                && (ln * 2 + 1, lastR, 0) <= lastOrd
            if headUnmounted || tailUnmounted {
                return true
            }
        }
        return false
    }

    // MARK: - On-Demand Unbuilt Row Building & Bounded Copy (`selection_collect.rs`)

    public static func buildUnmountedRow(
        listPath: String,
        rowIndex r: Int,
        lists: [String: VirtualListSelectionHost],
        texts: inout [VirtualOffscreenText],
        providers: inout [VirtualSelectionCopyProvider]
    ) {
        guard let v = lists[listPath], r >= 0, r < v.bookkeeping.keys.count else { return }
        let rowKey = v.bookkeeping.keys[r]
        let groupPath = v.selection.scope.groupPath
        let inert = v.selection.scope.inert
        switch v.selection.pins.source {
        case .rebuild(let source):
            let built = source.buildRowSelection(
                index: r,
                listPath: listPath,
                rowKey: rowKey,
                groupPath: groupPath,
                inert: inert
            )
            texts.append(contentsOf: built.texts)
            providers.append(contentsOf: built.providers)
        case .stored:
            if let stored = v.selection.storedBuilders[r] {
                let built = stored.buildRowSelection(
                    index: r,
                    listPath: listPath,
                    rowKey: rowKey,
                    groupPath: groupPath,
                    inert: inert
                )
                texts.append(contentsOf: built.texts)
                providers.append(contentsOf: built.providers)
            }
        case .none:
            break
        }
    }

    /// Pins row `r` of `listPath` and ensures its offscreen texts are kept (`selection_collect.rs::pin_offscreen_row`).
    public static func pinOffscreenRow(
        listPath: String,
        rowIndex r: Int,
        lists: inout [String: VirtualListSelectionHost]
    ) {
        guard let v = lists[listPath],
              !v.bookkeeping.range.contains(r),
              r >= 0,
              r < v.bookkeeping.keys.count else {
            return
        }
        let rowKey = v.bookkeeping.keys[r]
        var newTexts: [VirtualOffscreenText] = []
        var newProviders: [VirtualSelectionCopyProvider] = []
        if !v.selection.pins.hasTextRow(rowKey) {
            buildUnmountedRow(
                listPath: listPath,
                rowIndex: r,
                lists: lists,
                texts: &newTexts,
                providers: &newProviders
            )
        }
        lists[listPath]?.selection.pins.sync(.pin(key: rowKey, texts: newTexts, providers: newProviders))
    }

    /// Copies the active selection, invoking the lowest common ancestor `selectionCopy` provider
    /// if present (`selection_collect.rs::copy_virtual_text`).
    public static func copyVirtualText(
        phase: SelectionPhase,
        anchorState: VirtualSelectionAnchorState,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost],
        copyProviders: [String: VirtualSelectionCopyProvider],
        backward: Bool = false
    ) -> String? {
        guard let h = selectionHolderEnd(phase: phase, anchorState: anchorState, nodes: nodes, lists: lists),
              let f = focusHolderEnd(holder: h, phase: phase, anchorState: anchorState, nodes: nodes, lists: lists) else {
            return nil
        }
        let index = TreeIndex(nodes: nodes)
        func nodeFor(_ end: VirtualEndRef) -> Int? {
            switch end {
            case .mounted(let i):
                return i
            case .offscreen(let lp, let ti):
                guard let t = lists[lp]?.selection.pins.texts[ti] else { return nil }
                return index.byPath[t.listPath]
            }
        }
        guard let n0 = nodeFor(h), let n1 = nodeFor(f) else { return nil }

        var walk: Int? = n0
        var provider: VirtualSelectionCopyProvider? = nil
        while let p = walk {
            if let cp = copyProviders[nodes[p].path],
               isDescendantOrEqual(n1, ancestor: p, index: index) {
                provider = cp
                break
            }
            walk = index.parentIndices[p]
        }
        if let provider {
            guard let sel = collectVirtualSelection(
                basePath: provider.path,
                phase: phase,
                anchorState: anchorState,
                nodes: nodes,
                lists: lists,
                backward: backward
            ) else {
                return nil
            }
            if let text = provider.copy(sel) {
                return text
            }
            return sel.text
        }
        return collectVirtualSelection(
            basePath: nil,
            phase: phase,
            anchorState: anchorState,
            nodes: nodes,
            lists: lists,
            backward: backward
        )?.text
    }

    /// Collects the full `TextSelection` across mounted and offscreen/unbuilt virtual rows,
    /// bounded by `VirtualCopyLimits.maxVirtualCopyRows` and `VirtualCopyLimits.maxVirtualCopyBytes`
    /// (`selection_collect.rs::collect_virtual_selection`).
    public static func collectVirtualSelection(
        basePath: String? = nil,
        phase: SelectionPhase,
        anchorState: VirtualSelectionAnchorState,
        nodes: [SelectableNodeSnapshot],
        lists: [String: VirtualListSelectionHost],
        backward: Bool = false
    ) -> TextSelection? {
        guard let h = selectionHolderEnd(phase: phase, anchorState: anchorState, nodes: nodes, lists: lists),
              let f = focusHolderEnd(holder: h, phase: phase, anchorState: anchorState, nodes: nodes, lists: lists),
              let sel = phase.selection else {
            return nil
        }
        let index = TreeIndex(nodes: nodes)

        if h == f {
            let a = min(sel.anchor, sel.focus)
            let b = max(sel.anchor, sel.focus)
            switch h {
            case .mounted(let i):
                let utf8Count = nodes[i].text.utf8.count
                guard a < b, b <= utf8Count else { return nil }
                let piece = mountedPiece(nodes[i], range: a..<b, base: basePath)
                return TextSelection(texts: [piece], text: piece.text, backward: backward)
            case .offscreen(let lp, let ti):
                guard let t = lists[lp]?.selection.pins.texts[ti] else { return nil }
                let utf8Count = t.content.utf8.count
                guard a < b, b <= utf8Count else { return nil }
                let piece = offscreenPiece(t, range: a..<b, base: basePath)
                return TextSelection(texts: [piece], text: piece.text, backward: backward)
            }
        }

        let hOrd = treeOrder(h, nodes: nodes, lists: lists, index: index)
        let fOrd = treeOrder(f, nodes: nodes, lists: lists, index: index)
        let ((firstEnd, firstByte), (lastEnd, lastByte)) = hOrd < fOrd
            ? ((h, sel.anchor), (f, sel.focus))
            : ((f, sel.focus), (h, sel.anchor))
        let firstOrd = treeOrder(firstEnd, nodes: nodes, lists: lists, index: index)
        let lastOrd = treeOrder(lastEnd, nodes: nodes, lists: lists, index: index)
        guard let gPath = endGroupPath(h, nodes: nodes, lists: lists) else { return nil }

        // Both ends in the same offscreen row.
        if case .offscreen(let lp0, let ti0) = firstEnd,
           case .offscreen(let lp1, let ti1) = lastEnd,
           lp0 == lp1,
           let kept = lists[lp0]?.selection.pins.texts {
            let rowKey = kept[ti0].rowKey
            if kept[ti1].rowKey == rowKey {
                var texts: [SelectedText] = []
                var join = BoundedCopyJoin()
                for (ti, t) in kept.enumerated() {
                    guard t.rowKey == rowKey, t.groupPath == gPath else { continue }
                    let endRef = VirtualEndRef.offscreen(listPath: lp0, textIndex: ti)
                    let ord = treeOrder(endRef, nodes: nodes, lists: lists, index: index)
                    if ord < firstOrd || ord > lastOrd { continue }
                    let len = t.content.utf8.count
                    let a = (endRef == firstEnd) ? min(firstByte, len) : 0
                    let b = (endRef == lastEnd) ? min(lastByte, len) : len
                    if a >= b { continue }
                    let piece = offscreenPiece(t, range: a..<b, base: basePath)
                    let hitCap = join.push(
                        content: t.content,
                        uncopied: t.uncopied,
                        copyBreakBefore: t.copyBreakBefore,
                        copyBreakAfter: t.copyBreakAfter,
                        copyPrefix: t.copyPrefix,
                        range: a..<b,
                        piece: piece.text,
                        beside: t.tabBefore,
                        cap: VirtualCopyLimits.maxVirtualCopyBytes
                    )
                    texts.append(piece)
                    if hitCap { break }
                }
                let text = join.finish()
                return text.isEmpty ? nil : TextSelection(texts: texts, text: text, backward: backward)
            }
        }

        // General group selection spanning a virtual list.
        guard let g = index.byPath[gPath] else { return nil }
        let resolvedListPath: String? = virtualEndOf(firstEnd, offset: 0, nodes: nodes, lists: lists, index: index)?.listPath
            ?? virtualEndOf(lastEnd, offset: 0, nodes: nodes, lists: lists, index: index)?.listPath
            ?? (g..<nodes.count).first(where: { j in
                isDescendantOrEqual(j, ancestor: g, index: index) && lists[nodes[j].path] != nil
            }).map { nodes[$0].path }
        guard let listPath = resolvedListPath,
              let listNode = index.byPath[listPath],
              let v = lists[listPath] else {
            return nil
        }

        var texts: [SelectedText] = []
        var join = BoundedCopyJoin()
        var unbuiltRows = 0
        var prevMounted: Int? = nil
        var hitCap = false

        func appendMounted(_ j: Int) -> Bool {
            let endRef = VirtualEndRef.mounted(j)
            let ord = treeOrder(endRef, nodes: nodes, lists: lists, index: index)
            if ord < firstOrd || ord > lastOrd { return false }
            let len = nodes[j].text.utf8.count
            let a = (endRef == firstEnd) ? min(firstByte, len) : 0
            let b = (endRef == lastEnd) ? min(lastByte, len) : len
            if a >= b { return false }
            let piece = mountedPiece(nodes[j], range: a..<b, base: basePath)
            let beside = prevMounted.map { CopyJoin.beside(nodes[$0].rect, nodes[j].rect) } ?? false
            let capped = join.push(
                content: nodes[j].text,
                uncopied: nodes[j].uncopied,
                copyBreakBefore: nodes[j].copyBreakBefore,
                copyBreakAfter: nodes[j].copyBreakAfter,
                copyPrefix: nodes[j].copyPrefix,
                range: a..<b,
                piece: piece.text,
                beside: beside,
                cap: VirtualCopyLimits.maxVirtualCopyBytes
            )
            texts.append(piece)
            prevMounted = j
            return capped
        }

        // 1. Mounted group members before `listNode`.
        if g + 1 < listNode {
            for j in (g + 1)..<listNode {
                guard isDescendant(j, ancestor: g, index: index),
                      nodes[j].isSelectable,
                      SelectAllResolver.groupPath(forNodeAt: j, in: nodes) == gPath else {
                    continue
                }
                if appendMounted(j) {
                    hitCap = true
                    break
                }
            }
        }

        // 2. Rows of the virtual list in `[rowStart...rowEnd]`.
        if !hitCap && !v.bookkeeping.keys.isEmpty {
            let startEnd = virtualEndOf(firstEnd, offset: 0, nodes: nodes, lists: lists, index: index)
            let rowStart = (startEnd?.listPath == listPath) ? (startEnd?.rowIndex ?? 0) : 0
            let endEnd = virtualEndOf(lastEnd, offset: 0, nodes: nodes, lists: lists, index: index)
            let rowEnd = (endEnd?.listPath == listPath)
                ? min(endEnd?.rowIndex ?? (v.bookkeeping.keys.count - 1), v.bookkeeping.keys.count - 1)
                : (v.bookkeeping.keys.count - 1)

            var listEnd = listNode
            for j in (listNode + 1)..<nodes.count {
                if !isDescendant(j, ancestor: listNode, index: index) { break }
                listEnd = j
            }

            if rowStart <= rowEnd {
                for r in rowStart...rowEnd {
                    if v.bookkeeping.range.contains(r) {
                        let rowKey = v.bookkeeping.keys[r]
                        let rowPath = "\(listPath)/\(rowKey)"
                        let altRowPath = "\(listPath)/@\(rowKey)"
                        guard let rowNode = ((listNode + 1)...listEnd).first(where: { j in
                            index.parentIndices[j] == listNode
                                && (nodes[j].path == rowPath || nodes[j].path == altRowPath || nodes[j].key == rowKey)
                        }) else {
                            continue
                        }
                        for j in rowNode...listEnd {
                            if !isDescendantOrEqual(j, ancestor: rowNode, index: index) { break }
                            guard nodes[j].isSelectable,
                                  SelectAllResolver.groupPath(forNodeAt: j, in: nodes) == gPath else {
                                continue
                            }
                            if appendMounted(j) {
                                hitCap = true
                                break
                            }
                        }
                        if hitCap { break }
                    } else {
                        prevMounted = nil
                        let rowKey = v.bookkeeping.keys[r]
                        let rowTexts: [VirtualOffscreenText]
                        if v.selection.pins.hasTextRow(rowKey) {
                            rowTexts = v.selection.pins.texts.filter { $0.rowKey == rowKey }
                        } else {
                            if unbuiltRows >= VirtualCopyLimits.maxVirtualCopyRows
                                || join.currentByteCount >= VirtualCopyLimits.maxVirtualCopyBytes {
                                hitCap = true
                                break
                            }
                            unbuiltRows += 1
                            var builtTexts: [VirtualOffscreenText] = []
                            var ignoredProviders: [VirtualSelectionCopyProvider] = []
                            buildUnmountedRow(
                                listPath: listPath,
                                rowIndex: r,
                                lists: lists,
                                texts: &builtTexts,
                                providers: &ignoredProviders
                            )
                            rowTexts = builtTexts
                        }
                        var firstInRow = true
                        for t in rowTexts {
                            guard t.groupPath == gPath else { continue }
                            let ord = (listNode * 2 + 1, r, t.orderInRow)
                            if ord < firstOrd || ord > lastOrd { continue }
                            let len = t.content.utf8.count
                            let a = (ord == firstOrd) ? min(firstByte, len) : 0
                            let b = (ord == lastOrd) ? min(lastByte, len) : len
                            if a >= b { continue }
                            let piece = offscreenPiece(t, range: a..<b, base: basePath)
                            let capped = join.push(
                                content: t.content,
                                uncopied: t.uncopied,
                                copyBreakBefore: t.copyBreakBefore,
                                copyBreakAfter: t.copyBreakAfter,
                                copyPrefix: t.copyPrefix,
                                range: a..<b,
                                piece: piece.text,
                                beside: !firstInRow && t.tabBefore,
                                cap: VirtualCopyLimits.maxVirtualCopyBytes
                            )
                            texts.append(piece)
                            firstInRow = false
                            if capped {
                                hitCap = true
                                break
                            }
                        }
                        if hitCap { break }
                    }
                }
            }

            // 3. Mounted group members after the virtual list's subtree.
            if !hitCap && listEnd + 1 < nodes.count {
                for j in (listEnd + 1)..<nodes.count {
                    if !isDescendant(j, ancestor: g, index: index) { break }
                    guard nodes[j].isSelectable,
                          SelectAllResolver.groupPath(forNodeAt: j, in: nodes) == gPath else {
                        continue
                    }
                    if appendMounted(j) { break }
                }
            }
        }

        let text = join.finish()
        return text.isEmpty ? nil : TextSelection(texts: texts, text: text, backward: backward)
    }

    /// Finds the first and last selectable texts inside mounted node `root`, including unbuilt rows
    /// of any virtual list under `root`, pinning offscreen end rows as needed (`selection_collect.rs::virtual_span_under`).
    public static func virtualSpanUnder(
        rootIndex root: Int,
        nodes: [SelectableNodeSnapshot],
        lists: inout [String: VirtualListSelectionHost]
    ) -> (VirtualEndRef, VirtualEndRef)? {
        let index = TreeIndex(nodes: nodes)
        var listPath: String? = nil
        for j in root..<nodes.count {
            if !isDescendantOrEqual(j, ancestor: root, index: index) { break }
            if let v = lists[nodes[j].path], !v.bookkeeping.keys.isEmpty {
                listPath = nodes[j].path
                break
            }
        }
        guard let listPath, let listNode = index.byPath[listPath] else { return nil }
        let gPath = nodes[root].isSelectionGroup
            ? nodes[root].path
            : SelectAllResolver.groupPath(forNodeAt: root, in: nodes)

        let firstBefore: VirtualEndRef? = (root..<listNode).first { j in
            isDescendantOrEqual(j, ancestor: root, index: index)
                && nodes[j].isSelectable
                && (gPath == nil || SelectAllResolver.groupPath(forNodeAt: j, in: nodes) == gPath)
        }.map { .mounted($0) }

        let firstEnd: VirtualEndRef
        if let e = firstBefore {
            firstEnd = e
        } else {
            let count = lists[listPath]?.bookkeeping.keys.count ?? 0
            var found: VirtualEndRef? = nil
            var pinTarget: (Int, String)? = nil
            for r in 0..<count {
                guard let v = lists[listPath] else { break }
                if v.bookkeeping.range.contains(r) {
                    let rk = v.bookkeeping.keys[r]
                    let rowPath = "\(listPath)/\(rk)"
                    let altRowPath = "\(listPath)/@\(rk)"
                    if let j = ((listNode + 1)..<nodes.count).first(where: { j in
                        guard isDescendantOrEqual(j, ancestor: root, index: index), nodes[j].isSelectable else {
                            return false
                        }
                        let inRow = nodes[j].path == rowPath
                            || nodes[j].path.hasPrefix(rowPath + "/")
                            || nodes[j].path == altRowPath
                            || nodes[j].path.hasPrefix(altRowPath + "/")
                        guard inRow else { return false }
                        return gPath == nil || SelectAllResolver.groupPath(forNodeAt: j, in: nodes) == gPath
                    }) {
                        found = .mounted(j)
                        break
                    }
                } else {
                    var builtTexts: [VirtualOffscreenText] = []
                    var ignored: [VirtualSelectionCopyProvider] = []
                    buildUnmountedRow(
                        listPath: listPath,
                        rowIndex: r,
                        lists: lists,
                        texts: &builtTexts,
                        providers: &ignored
                    )
                    if let t = builtTexts.first(where: { gPath == nil || $0.groupPath == gPath }) {
                        pinTarget = (r, t.path)
                        break
                    }
                }
            }
            if let (r, p) = pinTarget {
                pinOffscreenRow(listPath: listPath, rowIndex: r, lists: &lists)
                found = resolveEnd(path: p, virtualEnd: nil, nodes: nodes, lists: lists)
            }
            guard let resolvedFirst = found else { return nil }
            firstEnd = resolvedFirst
        }

        guard let gp = gPath ?? endGroupPath(firstEnd, nodes: nodes, lists: lists) else {
            return (firstEnd, firstEnd)
        }

        var listEnd = listNode
        for j in (listNode + 1)..<nodes.count {
            if !isDescendant(j, ancestor: listNode, index: index) { break }
            listEnd = j
        }
        var lastAfter: VirtualEndRef? = nil
        if listEnd + 1 < nodes.count {
            for j in (listEnd + 1)..<nodes.count {
                if !isDescendantOrEqual(j, ancestor: root, index: index) { break }
                if nodes[j].isSelectable && SelectAllResolver.groupPath(forNodeAt: j, in: nodes) == gp {
                    lastAfter = .mounted(j)
                }
            }
        }

        let lastEnd: VirtualEndRef
        if let e = lastAfter {
            lastEnd = e
        } else {
            let count = lists[listPath]?.bookkeeping.keys.count ?? 0
            var found: VirtualEndRef? = nil
            var pinTarget: (Int, String)? = nil
            for r in stride(from: count - 1, through: 0, by: -1) {
                guard let v = lists[listPath] else { break }
                if v.bookkeeping.range.contains(r) {
                    let rk = v.bookkeeping.keys[r]
                    let rowPath = "\(listPath)/\(rk)"
                    let altRowPath = "\(listPath)/@\(rk)"
                    if let j = ((listNode + 1)...listEnd).last(where: { j in
                        guard nodes[j].isSelectable else { return false }
                        let inRow = nodes[j].path == rowPath
                            || nodes[j].path.hasPrefix(rowPath + "/")
                            || nodes[j].path == altRowPath
                            || nodes[j].path.hasPrefix(altRowPath + "/")
                        return inRow && SelectAllResolver.groupPath(forNodeAt: j, in: nodes) == gp
                    }) {
                        found = .mounted(j)
                        break
                    }
                } else {
                    var builtTexts: [VirtualOffscreenText] = []
                    var ignored: [VirtualSelectionCopyProvider] = []
                    buildUnmountedRow(
                        listPath: listPath,
                        rowIndex: r,
                        lists: lists,
                        texts: &builtTexts,
                        providers: &ignored
                    )
                    if let t = builtTexts.last(where: { $0.groupPath == gp }) {
                        pinTarget = (r, t.path)
                        break
                    }
                }
            }
            if let (r, p) = pinTarget {
                pinOffscreenRow(listPath: listPath, rowIndex: r, lists: &lists)
                found = resolveEnd(path: p, virtualEnd: nil, nodes: nodes, lists: lists)
            }
            lastEnd = found ?? firstEnd
        }

        let firstPath = endPath(firstEnd, nodes: nodes, lists: lists)
        let lastPath = endPath(lastEnd, nodes: nodes, lists: lists)
        guard let rFirst = resolveEnd(path: firstPath, virtualEnd: nil, nodes: nodes, lists: lists),
              let rLast = resolveEnd(path: lastPath, virtualEnd: nil, nodes: nodes, lists: lists) else {
            return nil
        }
        return (rFirst, rLast)
    }

    /// Selects from the start of `first` to the end of `last` (`selection.rs::select_span_ends`).
    public static func selectSpanEnds(
        first: VirtualEndRef,
        last: VirtualEndRef,
        phase: inout SelectionPhase,
        anchorState: inout VirtualSelectionAnchorState,
        nodes: [SelectableNodeSnapshot],
        lists: inout [String: VirtualListSelectionHost]
    ) {
        let index = TreeIndex(nodes: nodes)
        let head = endPath(first, nodes: nodes, lists: lists)
        let content = endContent(first, nodes: nodes, lists: lists)
        let far: SelectionFar? = (first == last)
            ? nil
            : SelectionFar(
                path: endPath(last, nodes: nodes, lists: lists),
                content: endContent(last, nodes: nodes, lists: lists)
            )
        let end = far.map { $0.content.utf8.count } ?? content.utf8.count
        let origin = far != nil ? (0, 0) : (0, end)
        let aEnd = virtualEndOf(first, offset: 0, nodes: nodes, lists: lists, index: index)
        let fEnd = (first != last)
            ? virtualEndOf(last, offset: end, nodes: nodes, lists: lists, index: index)
            : nil
        phase.place(ActiveSelection(
            path: head,
            content: content,
            anchor: 0,
            focus: end,
            origin: origin,
            far: far
        ))
        anchorState.anchorEnd = aEnd
        anchorState.focusEnd = fEnd
        sealBetween(phase: phase, anchorState: &anchorState, nodes: nodes, lists: &lists)
    }

    /// Handles `selectText` / `selectAllText` when `selector` names an element in an unbuilt
    /// virtual row (`selection_collect.rs::select_unmounted_request`).
    @discardableResult
    public static func selectUnmountedRequest(
        selector: String,
        range: Range<Int>?,
        phase: inout SelectionPhase,
        anchorState: inout VirtualSelectionAnchorState,
        nodes: [SelectableNodeSnapshot],
        lists: inout [String: VirtualListSelectionHost]
    ) -> Bool {
        let allowedLists = lists.keys.sorted().filter {
            virtualListAllowed(listPath: $0, nodes: nodes, lists: lists)
        }
        for listPath in allowedLists {
            guard let v = lists[listPath] else { continue }
            let count = v.bookkeeping.keys.count
            let mounted = v.bookkeeping.range
            var candidateRows = (0..<count).filter { r in
                guard !mounted.contains(r) else { return false }
                let rk = v.bookkeeping.keys[r]
                return selector == rk
                    || selector.hasPrefix(rk + "/")
                    || selector.split(separator: "/").contains(Substring(rk))
            }
            if candidateRows.isEmpty {
                candidateRows = Array((0..<count).filter { !mounted.contains($0) }.prefix(VirtualCopyLimits.maxVirtualCopyRows))
            }

            for r in candidateRows {
                var texts: [VirtualOffscreenText] = []
                var ignored: [VirtualSelectionCopyProvider] = []
                buildUnmountedRow(
                    listPath: listPath,
                    rowIndex: r,
                    lists: lists,
                    texts: &texts,
                    providers: &ignored
                )
                if let byteRange = range {
                    if let t = texts.first(where: {
                        $0.path == selector || selectsElementSelector(selector, path: $0.path, key: $0.key)
                    }) {
                        let a = SelectionMath.floorCharBoundary(in: t.content, offset: byteRange.lowerBound)
                        let b = SelectionMath.floorCharBoundary(in: t.content, offset: max(byteRange.lowerBound, byteRange.upperBound))
                        pinOffscreenRow(listPath: listPath, rowIndex: r, lists: &lists)
                        guard let endRef = resolveEnd(path: t.path, virtualEnd: nil, nodes: nodes, lists: lists) else {
                            return false
                        }
                        phase.place(ActiveSelection(
                            path: t.path,
                            content: t.content,
                            anchor: a,
                            focus: b,
                            origin: (a, b)
                        ))
                        anchorState.anchorEnd = virtualEndOf(endRef, offset: a, nodes: nodes, lists: lists)
                        anchorState.focusEnd = nil
                        sealBetween(phase: phase, anchorState: &anchorState, nodes: nodes, lists: &lists)
                        return true
                    }
                } else {
                    guard let currentList = lists[listPath] else { continue }
                    let rk = currentList.bookkeeping.keys[r]
                    let rowPath = "\(listPath)/\(rk)"
                    let rowMatches = rowPath == selector || selectsElementSelector(selector, path: rowPath, key: rk)
                    let matching: [VirtualOffscreenText] = rowMatches
                        ? texts
                        : texts.filter { $0.path == selector || selectsElementSelector(selector, path: $0.path, key: $0.key) }
                    if let firstT = matching.first {
                        let lastT: VirtualOffscreenText
                        if let gp = firstT.groupPath {
                            lastT = matching.last(where: { $0.groupPath == gp }) ?? firstT
                        } else {
                            lastT = firstT
                        }
                        pinOffscreenRow(listPath: listPath, rowIndex: r, lists: &lists)
                        guard let e0 = resolveEnd(path: firstT.path, virtualEnd: nil, nodes: nodes, lists: lists),
                              let e1 = resolveEnd(path: lastT.path, virtualEnd: nil, nodes: nodes, lists: lists) else {
                            return false
                        }
                        selectSpanEnds(
                            first: e0,
                            last: e1,
                            phase: &phase,
                            anchorState: &anchorState,
                            nodes: nodes,
                            lists: &lists
                        )
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Internal Helpers

    private static func mountedPiece(
        _ node: SelectableNodeSnapshot,
        range: Range<Int>,
        base: String?
    ) -> SelectedText {
        let path: String
        if let b = base {
            if b == node.path {
                path = ""
            } else if node.path.hasPrefix(b + "/") {
                path = String(node.path.dropFirst(b.count + 1))
            } else {
                path = node.path
            }
        } else {
            path = node.path
        }
        let utf8 = Array(node.text.utf8)
        let len = utf8.count
        let (fullA, fullB): (Int, Int) = node.uncopied.isEmpty
            ? (0, len)
            : SelectionMath.trimUncopied(node.uncopied, range: (0, len))
        let whole = !range.isEmpty && len > 0 && range.lowerBound <= fullA && range.upperBound >= fullB
        let text = CopyJoin.copySlice(in: node.text, range: range, uncopied: node.uncopied)
        let contentSlice: String
        if range.lowerBound >= 0, range.upperBound <= len, range.lowerBound < range.upperBound {
            contentSlice = String(bytes: utf8[range], encoding: .utf8) ?? ""
        } else {
            contentSlice = ""
        }
        return SelectedText(
            path: path,
            key: node.key,
            range: range,
            len: len,
            whole: whole,
            text: text,
            content: contentSlice
        )
    }

    private static func isDescendant(_ j: Int, ancestor: Int, index: TreeIndex) -> Bool {
        var cur = index.parentIndices[j]
        while let p = cur {
            if p == ancestor { return true }
            cur = index.parentIndices[p]
        }
        return false
    }

    private static func isDescendantOrEqual(_ j: Int, ancestor: Int, index: TreeIndex) -> Bool {
        j == ancestor || isDescendant(j, ancestor: ancestor, index: index)
    }

    private static func fnvMix(_ hash: inout UInt64, _ string: String) {
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        hash ^= 0xff
        hash &*= 0x100000001b3
    }
}

// MARK: - Runtime Bridge Helpers (using `FlatNode` & `El`)

internal extension Runtime {
    /// Extracts `VirtualSelectionCopyProvider`s keyed by node path from live `flatNodes`.
    func virtualCopyProvidersByPath() -> [String: VirtualSelectionCopyProvider] {
        var out: [String: VirtualSelectionCopyProvider] = [:]
        for node in flatNodes where !node.effectiveInert && node.el.hasSelectionCopyHandler {
            let el = node.el
            out[node.path] = VirtualSelectionCopyProvider(path: node.path) { sel in
                el.invokeSelectionCopy(sel)
            }
        }
        return out
    }
}
