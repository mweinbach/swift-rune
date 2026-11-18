import Foundation
import RuneMotion
#if canImport(simd)
import simd
#endif

/// Constants and helpers matching `crates/rune/src/runtime/layout_read.rs` & `key_index.rs`.
enum LayoutReadConstants {
    /// Extra measurements one commit may take while a layout read moves.
    static let passes: Int = 2
    /// Commits in a row that layout feedback alone may cause before going quiet.
    static let echoes: Int = 4
    /// An edge must move by more than this (points) to count as moved for whole-rect reads.
    static let movedThreshold: Float = 0.5
    /// Key prefix for post-scroll window-coordinate reads (`Cx.windowLayout`).
    static let windowPrefix: String = "\u{1}window:"
    /// Lookup count threshold above which a key index is built.
    static let scanReads: Int = 8

    @inline(__always)
    static func windowKey(_ key: String) -> String {
        windowPrefix + key
    }

    @inline(__always)
    static func stripWindowPrefix(_ key: String) -> (key: String, scrolled: Bool) {
        if key.hasPrefix(windowPrefix) {
            return (String(key.dropFirst(windowPrefix.count)), true)
        }
        return (key, false)
    }

    @inline(__always)
    static func rectArray(_ rect: MotionRect) -> [Float] {
        [rect.left, rect.top, rect.width, rect.height]
    }

    @inline(__always)
    static func rectSize(_ rect: [Float]) -> [Float] {
        [rect[2], rect[3]]
    }

    static func rectsMoved(_ a: [Float]?, _ b: [Float]?) -> Bool {
        switch (a, b) {
        case let (a?, b?):
            guard a.count == 4, b.count == 4 else { return a != b }
            for i in 0..<4 {
                if abs(a[i] - b[i]) > movedThreshold {
                    return true
                }
            }
            return false
        case (nil, nil):
            return false
        default:
            return true
        }
    }
}

/// Circuit breaker for feedback loops caused by `Cx.layout*` / `onLayout` / `onDrawnLayout`.
enum LayoutFeedback: Equatable, Sendable {
    case open(run: Int)
    case quiet

    static let initial = LayoutFeedback.open(run: 0)

    enum Event: Sendable {
        case commit(feedback: Bool, other: Bool)
        case reopened
    }

    var isOpen: Bool {
        if case .open = self { return true }
        return false
    }

    mutating func step(_ event: Event) {
        switch (self, event) {
        case (_, .reopened):
            self = .open(run: 0)
        case (_, .commit(_, true)):
            self = .open(run: 0)
        case (.open(let run), .commit(true, false)):
            let next = run + 1
            self = next < LayoutReadConstants.echoes ? .open(run: next) : .quiet
        default:
            break
        }
    }
}

final class LayoutPredicateBox {
    let holds: ([Float], [Float]) -> Bool

    init(_ holds: @escaping ([Float], [Float]) -> Bool) {
        self.holds = holds
    }
}

/// Predicate checking whether a `layoutWith` transform gives two rects the same value.
struct LayoutSame: @unchecked Sendable {
    enum Kind: @unchecked Sendable {
        case token(AnyHashable, ([Float], [Float]) -> Bool)
        case shared(LayoutPredicateBox)
    }

    let kind: Kind

    static let sizeToken: String = "Rune.LayoutSame.size"
    static let size = LayoutSame.make(token: AnyHashable(sizeToken)) { LayoutReadConstants.rectSize($0) }

    static func make<T: Equatable>(token: AnyHashable? = nil, _ transform: @escaping ([Float]) -> T) -> LayoutSame {
        let eq: ([Float], [Float]) -> Bool = { a, b in transform(a) == transform(b) }
        if let token {
            return LayoutSame(kind: .token(token, eq))
        }
        return LayoutSame(kind: .shared(LayoutPredicateBox(eq)))
    }

    func holds(_ a: [Float], _ b: [Float]) -> Bool {
        switch kind {
        case let .token(_, fn): return fn(a, b)
        case let .shared(predicate): return predicate.holds(a, b)
        }
    }

    func isSame(_ other: LayoutSame) -> Bool {
        switch (kind, other.kind) {
        case let (.token(a, _), .token(b, _)):
            return a == b
        case let (.shared(a), .shared(b)):
            return a === b
        default:
            return false
        }
    }

    func moved(_ a: [Float]?, _ b: [Float]?) -> Bool {
        switch (a, b) {
        case let (a?, b?):
            return !holds(a, b)
        default:
            return (a == nil) != (b == nil)
        }
    }
}

/// One layout dependency recorded by a view during a `Cx.layout*` call.
struct LayoutReadEntry {
    var key: String
    var same: LayoutSame?

    func moved(_ a: [Float]?, _ b: [Float]?) -> Bool {
        if let same {
            return same.moved(a, b)
        }
        return LayoutReadConstants.rectsMoved(a, b)
    }
}

/// Records `Cx.layout*` dependencies during a single view invocation.
final class LayoutReadCollector {
    let rects: [String: [Float]?]
    var reads: [LayoutReadEntry] = []
    var viewportRead: Bool = false

    init(rects: [String: [Float]?] = [:]) {
        self.rects = rects
    }

    func seenRect(for key: String) -> [Float]? {
        rects[key] ?? nil
    }

    func noteRead(key: String, same: LayoutSame?) {
        let alreadyCounted = reads.contains { existing in
            guard existing.key == key else { return false }
            switch (existing.same, same) {
            case (nil, nil):
                return true
            case let (a?, b?):
                return a.isSame(b)
            default:
                return false
            }
        }
        if !alreadyCounted {
            reads.append(LayoutReadEntry(key: key, same: same))
        }
    }
}

/// Retained state of all layout reads from the last committed view.
struct LayoutSeenState {
    var rects: [String: [Float]?] = [:]
    var reads: [LayoutReadEntry] = []

    var isEmpty: Bool { reads.isEmpty }
}

/// Fast key/path lookup index mirroring `crates/rune/src/runtime/key_index.rs`.
struct LayoutKeyIndex {
    private var firstByLeafKey: [String: Int] = [:]
    private var laterByLeafKey: [String: [Int]] = [:]
    private var byHighlightKey: [String: [Int]] = [:]
    /// A prune or a replacement can provide different nodes in the same layout generation.
    private struct NodesID: Equatable {
        let stamp: UInt64
        let count: Int
        let address: UInt

        init<N>(_ nodes: [N], stamp: UInt64) {
            self.stamp = stamp
            count = nodes.count
            address = nodes.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        }
    }

    private var built: NodesID?
    private var seen: NodesID?
    private var singleLeaf: (id: NodesID, key: String, index: Int)?

    mutating func invalidate() {
        built = nil
        seen = nil
        singleLeaf = nil
    }

    mutating func prepare<N>(
        nodes: [N],
        stamp: UInt64,
        lookups: Int,
        selector: String? = nil,
        keyOf: (N) -> String?,
        highlightKeysOf: ((N) -> [String])? = nil
    ) {
        let id = NodesID(nodes, stamp: stamp)
        guard built != id else { return }
        built = nil
        if lookups == 1, let selector {
            let key = LayoutReadConstants.stripWindowPrefix(selector).key
            if let singleLeaf, singleLeaf.id == id, singleLeaf.key.utf8.elementsEqual(key.utf8) { return }
            if seen != id, !key.utf8.contains(0x2f),
               let position = nodes.firstIndex(where: { keyOf($0)?.utf8.elementsEqual(key.utf8) == true }) {
                singleLeaf = (id, key, position)
                seen = id
                return
            }
        }
        if lookups > LayoutReadConstants.scanReads || seen == id {
            build(nodes: nodes, keyOf: keyOf, highlightKeysOf: highlightKeysOf)
            built = id
        } else {
            singleLeaf = nil
        }
        seen = id
    }

    func indexIfValid<N>(nodes: [N], stamp: UInt64) -> LayoutKeyIndex? {
        let id = NodesID(nodes, stamp: stamp)
        return built == id || singleLeaf?.id == id ? self : nil
    }

    mutating func build<N>(
        nodes: [N],
        keyOf: (N) -> String?,
        highlightKeysOf: ((N) -> [String])? = nil
    ) {
        built = nil
        singleLeaf = nil
        firstByLeafKey.removeAll(keepingCapacity: true)
        laterByLeafKey.removeAll(keepingCapacity: true)
        byHighlightKey.removeAll(keepingCapacity: true)
        for (i, node) in nodes.enumerated() {
            if let k = keyOf(node) {
                if firstByLeafKey[k] == nil {
                    firstByLeafKey[k] = i
                } else {
                    laterByLeafKey[k, default: []].append(i)
                }
            }
            if let highlightKeysOf {
                let hKeys = highlightKeysOf(node)
                if !hKeys.isEmpty {
                    var seenForNode: Set<String> = []
                    for hk in hKeys where seenForNode.insert(hk).inserted {
                        byHighlightKey[hk, default: []].append(i)
                    }
                }
            }
        }
    }

    /// The selector itself and each suffix after a slash may be the complete key.
    /// A slash can belong to a key, an ancestor scope, or both in different branches.
    private static func forEachTail(of selector: String, _ visit: (String) -> Void) {
        visit(selector)
        let bytes = selector.utf8
        for slash in bytes.indices where bytes[slash] == 0x2f {
            let next = bytes.index(after: slash)
            visit(String(decoding: bytes[next...], as: UTF8.self))
        }
    }

    /// Rune compares the nearest keyed path components above a complete element or highlight
    /// key. A scoped selector may begin partway through an ancestor whose key contains slashes.
    private static func matches<N>(
        selector: String, key: String, ancestor: Int?, nodes: [N],
        keyOf: (N) -> String?, parentOf: (N) -> Int?
    ) -> Bool {
        if selector.utf8.elementsEqual(key.utf8) { return true }
        let bytes = selector.utf8
        guard bytes.count > key.utf8.count, bytes.suffix(key.utf8.count).elementsEqual(key.utf8) else {
            return false
        }
        let prefix = bytes.dropLast(key.utf8.count)
        guard prefix.last == 0x2f else { return false }
        var scope = prefix.dropLast().split(separator: 0x2f, omittingEmptySubsequences: false).reversed().makeIterator()
        var wanted = scope.next()
        var ancestor = ancestor
        while let i = ancestor {
            if let ancestorKey = keyOf(nodes[i]) {
                for part in ancestorKey.utf8.split(separator: 0x2f, omittingEmptySubsequences: false).reversed()
                    where part.first != 0x23 {
                    guard let component = wanted, component.elementsEqual(part) else { return false }
                    wanted = scope.next()
                    if wanted == nil { return true }
                }
            }
            ancestor = parentOf(nodes[i])
        }
        return false
    }

    static func selectsUnder<N>(
        selector: String,
        nodeIndex: Int,
        nodes: [N],
        keyOf: (N) -> String?,
        parentOf: (N) -> Int?,
        highlightKey: String
    ) -> Bool {
        matches(selector: selector, key: highlightKey, ancestor: nodeIndex, nodes: nodes, keyOf: keyOf, parentOf: parentOf)
    }

    static func markedCandidates<N>(
        selector: String,
        index: LayoutKeyIndex?,
        nodes: [N]
    ) -> [Int]? {
        guard let index, index.singleLeaf == nil else { return nil }
        if !selector.utf8.contains(0x2f) {
            let found = index.byHighlightKey[selector] ?? []
            return (found.last ?? -1) < nodes.count ? found : Array(found.prefix { $0 < nodes.count })
        }
        var found: [Int] = []
        forEachTail(of: selector) { key in
            if let candidates = index.byHighlightKey[key] { found.append(contentsOf: candidates) }
        }
        found.sort()
        var previous: Int?
        return found.filter { candidate in
            defer { previous = candidate }
            return candidate < nodes.count && candidate != previous
        }
    }

    static func firstMatch<N>(
        selector: String,
        index: LayoutKeyIndex?,
        nodes: [N],
        keyOf: (N) -> String?,
        parentOf: (N) -> Int?
    ) -> Int? {
        func selects(_ i: Int) -> Bool {
            guard let key = keyOf(nodes[i]) else { return false }
            return matches(selector: selector, key: key, ancestor: parentOf(nodes[i]),
                           nodes: nodes, keyOf: keyOf, parentOf: parentOf)
        }
        if let cached = index?.singleLeaf, cached.key.utf8.elementsEqual(selector.utf8) {
            return cached.index
        }
        guard let index, index.singleLeaf == nil else {
            if !selector.utf8.contains(0x2f) {
                return nodes.firstIndex { node in
                    keyOf(node)?.utf8.elementsEqual(selector.utf8) == true
                }
            }
            return nodes.indices.first(where: selects)
        }
        var first: Int?
        forEachTail(of: selector) { key in
            guard let initial = index.firstByLeafKey[key], initial < (first ?? nodes.count) else { return }
            if selects(initial) {
                first = initial
                return
            }
            guard let later = index.laterByLeafKey[key] else { return }
            for i in later {
                if i >= (first ?? nodes.count) { break }
                if selects(i) {
                    first = i
                    break
                }
            }
        }
        return first
    }
}

// MARK: - Live<SIMD4<Float>> support for drawnRectInto

extension SIMD4: LiveValue where Scalar == Float {
    public func encodeLiveLanes() -> MotionLanes? {
        guard !x.isNaN && !y.isNaN && !z.isNaN && !w.isNaN else { return nil }
        return MotionLanes(x, y, z, w)
    }

    public static func decodeLiveLanes(_ lanes: MotionLanes) -> SIMD4<Float> {
        SIMD4<Float>(lanes.l0, lanes.l1, lanes.l2, lanes.l3)
    }
}

// MARK: - Cx Layout Reads

extension Cx {
    /// Laid-out rect `[x, y, w, h]` of `key` (or `"outer/inner"` key path) in unscrolled window
    /// points, or `nil` if unmounted. Scrolling never triggers re-evaluation of views reading this.
    public func layout(_ key: String) -> [Float]? {
        let memoRect = MemoScope.isInsideMemo ? MemoScope.readLayout(key) : nil
        layoutCollector.noteRead(key: key, same: nil)
        let rect = layoutCollector.seenRect(for: key) ?? memoRect
        envState.reads.layoutReads.append(.layout(key: key, rect: rect.map { MotionRect.fromXYWH($0[0], $0[1], $0[2], $0[3]) }))
        return rect
    }

    /// Reads `transform` of the element's laid-out rect, re-running the view only when the derived
    /// value changes. Pass `token` to deduplicate identical reads across multiple calls.
    public func layoutWith<T: Equatable>(
        _ key: String,
        token: AnyHashable? = nil,
        _ transform: @escaping ([Float]) -> T
    ) -> T? {
        let memoRect = MemoScope.isInsideMemo ? MemoScope.peekLayoutRect(key, window: false) : nil
        let rect = layoutCollector.seenRect(for: key) ?? memoRect
        let built = MemoScope.makeLayoutWithRead(key, window: false, rect: rect, transform)
        if MemoScope.isInsideMemo {
            MemoScope.recordLayoutRead(built.read)
        }
        layoutCollector.noteRead(key: key, same: LayoutSame.make(token: token, transform))
        envState.reads.layoutReads.append(built.read)
        return built.value
    }

    /// `[width, height]` of `Cx.layout(key)`, re-running only when size changes.
    public func layoutSize(_ key: String) -> [Float]? {
        let memoSize = MemoScope.isInsideMemo ? MemoScope.readLayoutSize(key) : nil
        let rect = layoutCollector.seenRect(for: key)
        let value = rect.map(LayoutReadConstants.rectSize) ?? memoSize
        layoutCollector.noteRead(key: key, same: LayoutSame.size)
        envState.reads.layoutReads.append(.layoutSize(key: key, size: value.map { Vec2($0[0], $0[1]) }))
        return value
    }

    /// Laid-out rect `[x, y, w, h]` of `key` in window points *after* ancestor scroll offsets.
    public func windowLayout(_ key: String) -> [Float]? {
        let memoRect = MemoScope.isInsideMemo ? MemoScope.readWindowLayout(key) : nil
        let winKey = LayoutReadConstants.windowKey(key)
        layoutCollector.noteRead(key: winKey, same: nil)
        let rect = layoutCollector.seenRect(for: winKey) ?? memoRect
        envState.reads.layoutReads.append(.windowLayout(key: key, rect: rect.map { MotionRect.fromXYWH($0[0], $0[1], $0[2], $0[3]) }))
        return rect
    }

    /// Post-scroll equivalent of `layoutWith`.
    public func windowLayoutWith<T: Equatable>(
        _ key: String,
        token: AnyHashable? = nil,
        _ transform: @escaping ([Float]) -> T
    ) -> T? {
        let winKey = LayoutReadConstants.windowKey(key)
        let memoRect = MemoScope.isInsideMemo ? MemoScope.peekLayoutRect(key, window: true) : nil
        let rect = layoutCollector.seenRect(for: winKey) ?? memoRect
        let built = MemoScope.makeLayoutWithRead(key, window: true, rect: rect, transform)
        if MemoScope.isInsideMemo {
            MemoScope.recordLayoutRead(built.read)
        }
        layoutCollector.noteRead(key: winKey, same: LayoutSame.make(token: token, transform))
        envState.reads.layoutReads.append(built.read)
        return built.value
    }
}

// MARK: - El Layout Callback Modifiers

extension El {
    /// Called with this element's post-scroll laid-out rect `[x, y, w, h]` in window points
    /// once after first layout and whenever it moves or resizes by more than 0.5 pt.
    public func onLayout(_ handler: @escaping (inout State, [Float]) -> Void) -> Self {
        onLayoutTx { s, rect, _ in handler(&s, rect) }
    }

    /// `onLayout` with access to `Tx` (e.g., call `tx.liveOnly()` to avoid view rebuilds).
    public func onLayoutTx(_ handler: @escaping (inout State, [Float], inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onLayout = handler
        return copy
    }

    /// `onLayout` in global screen points (`windowOrigin + rect.origin`). Also fires when
    /// `Runtime.setWindowOrigin(_:)` moves the window without a relayout.
    public func onScreenLayout(_ handler: @escaping (inout State, [Float]) -> Void) -> Self {
        var copy = self
        copy.handlers.onScreenLayout = { s, rect, _ in handler(&s, rect) }
        return copy
    }

    /// Called with this element's drawn rect `[x, y, w, h]` in window points once its own and
    /// ancestors' springs have settled, on initial draw and whenever it moves by more than 0.5 pt.
    public func onDrawnLayout(_ handler: @escaping (inout State, [Float]) -> Void) -> Self {
        onDrawnLayoutTx { s, rect, _ in handler(&s, rect) }
    }

    /// `onDrawnLayout` with access to `Tx` (`tx.liveOnly()` keeps live-only chases free of commits).
    public func onDrawnLayoutTx(_ handler: @escaping (inout State, [Float], inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onDrawnLayout = handler
        return copy
    }

    /// Writes each frame's drawn `MotionRect` directly into `rect` with no handler or commit.
    public func drawnRectInto(_ rect: Live<MotionRect>) -> Self {
        var copy = self
        copy.drawnRectLive = rect
        copy.handlers.drawnRectUpdate = { r in rect.set(r) }
        return copy
    }

    /// Writes each frame's drawn `[x, y, w, h]` (`SIMD4<Float>`) directly into `rect`.
    public func drawnRectInto(_ rect: Live<SIMD4<Float>>) -> Self {
        var copy = self
        copy.handlers.drawnRectUpdate = { r in
            rect.set(SIMD4<Float>(r.left, r.top, r.width, r.height))
        }
        return copy
    }
}
