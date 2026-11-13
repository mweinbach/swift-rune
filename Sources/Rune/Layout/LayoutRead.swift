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

private final class LayoutPredicateBox {}

/// Predicate checking whether a `layoutWith` transform gives two rects the same value.
struct LayoutSame: @unchecked Sendable {
    enum Kind: @unchecked Sendable {
        case token(AnyHashable, ([Float], [Float]) -> Bool)
        case shared(ObjectIdentifier, ([Float], [Float]) -> Bool)
    }

    let kind: Kind

    static let sizeToken: String = "Rune.LayoutSame.size"
    static let size = LayoutSame.make(token: AnyHashable(sizeToken)) { LayoutReadConstants.rectSize($0) }

    static func make<T: Equatable>(token: AnyHashable? = nil, _ transform: @escaping ([Float]) -> T) -> LayoutSame {
        let eq: ([Float], [Float]) -> Bool = { a, b in transform(a) == transform(b) }
        if let token {
            return LayoutSame(kind: .token(token, eq))
        }
        return LayoutSame(kind: .shared(ObjectIdentifier(LayoutPredicateBox()), eq))
    }

    func holds(_ a: [Float], _ b: [Float]) -> Bool {
        switch kind {
        case let .token(_, fn), let .shared(_, fn):
            return fn(a, b)
        }
    }

    func isSame(_ other: LayoutSame) -> Bool {
        switch (kind, other.kind) {
        case let (.token(a, _), .token(b, _)):
            return a == b
        case let (.shared(a, _), .shared(b, _)):
            return a == b
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
    private var byLeafKey: [String: [Int]] = [:]
    private var byHighlightKey: [String: [Int]] = [:]
    private var builtStamp: UInt64 = 0
    private var seenStamp: UInt64 = 0
    private var isBuilt: Bool = false

    mutating func invalidate() {
        isBuilt = false
        seenStamp = 0
    }

    mutating func prepare<N>(
        nodes: [N],
        stamp: UInt64,
        lookups: Int,
        keyOf: (N) -> String?,
        highlightKeysOf: ((N) -> [String])? = nil
    ) {
        if (!isBuilt || builtStamp != stamp) && (lookups > LayoutReadConstants.scanReads || (seenStamp == stamp && stamp != 0)) {
            build(nodes: nodes, keyOf: keyOf, highlightKeysOf: highlightKeysOf)
            builtStamp = stamp
            isBuilt = true
        }
        seenStamp = stamp
    }

    func indexIfValid(stamp: UInt64) -> LayoutKeyIndex? {
        (isBuilt && builtStamp == stamp) ? self : nil
    }

    mutating func build<N>(
        nodes: [N],
        keyOf: (N) -> String?,
        highlightKeysOf: ((N) -> [String])? = nil
    ) {
        byLeafKey.removeAll(keepingCapacity: true)
        byHighlightKey.removeAll(keepingCapacity: true)
        for (i, node) in nodes.enumerated() {
            if let k = keyOf(node) {
                byLeafKey[k, default: []].append(i)
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

    static func selects<N>(
        selector: String,
        nodeIndex: Int,
        nodes: [N],
        keyOf: (N) -> String?,
        parentOf: (N) -> Int?
    ) -> Bool {
        guard let nodeKey = keyOf(nodes[nodeIndex]) else { return false }
        if !selector.contains("/") {
            return selector == nodeKey
        }
        let parts = selector.split(separator: "/", omittingEmptySubsequences: false)
        guard let leaf = parts.last, nodeKey == leaf else { return false }
        var curParent = parentOf(nodes[nodeIndex])
        for seg in parts.dropLast().reversed() {
            while let p = curParent, keyOf(nodes[p]) == nil {
                curParent = parentOf(nodes[p])
            }
            guard let p = curParent, let pKey = keyOf(nodes[p]), pKey == seg else {
                return false
            }
            curParent = parentOf(nodes[p])
        }
        return true
    }

    /// Mirrors `crate::flight::selects_under(selector, path, highlightKey)`: checks whether `selector`
    /// selects a highlight keyed `highlightKey` on `nodes[nodeIndex]` under its keyed ancestors.
    static func selectsUnder<N>(
        selector: String,
        nodeIndex: Int,
        nodes: [N],
        keyOf: (N) -> String?,
        parentOf: (N) -> Int?,
        highlightKey: String
    ) -> Bool {
        if !selector.contains("/") {
            return selector == highlightKey
        }
        let parts = selector.split(separator: "/", omittingEmptySubsequences: false)
        guard let leaf = parts.last, leaf == highlightKey else { return false }
        var cur: Int? = nodeIndex
        for seg in parts.dropLast().reversed() {
            while let p = cur, keyOf(nodes[p]) == nil {
                cur = parentOf(nodes[p])
            }
            guard let p = cur, let pKey = keyOf(nodes[p]), pKey == seg else {
                return false
            }
            cur = parentOf(nodes[p])
        }
        return true
    }

    static func markedCandidates<N>(
        selector: String,
        index: LayoutKeyIndex?,
        nodes: [N]
    ) -> [Int]? {
        guard let index else { return nil }
        let leaf: String
        if let slash = selector.lastIndex(of: "/") {
            leaf = String(selector[selector.index(after: slash)...])
        } else {
            leaf = selector
        }
        return (index.byHighlightKey[leaf] ?? []).filter { $0 < nodes.count }
    }

    static func firstMatch<N>(
        selector: String,
        index: LayoutKeyIndex?,
        nodes: [N],
        keyOf: (N) -> String?,
        parentOf: (N) -> Int?
    ) -> Int? {
        guard !selector.isEmpty else { return nil }
        let leaf: String
        if let slash = selector.lastIndex(of: "/") {
            leaf = String(selector[selector.index(after: slash)...])
        } else {
            leaf = selector
        }
        if let index, let candidates = index.byLeafKey[leaf] {
            for i in candidates where i < nodes.count {
                if selects(selector: selector, nodeIndex: i, nodes: nodes, keyOf: keyOf, parentOf: parentOf) {
                    return i
                }
            }
            return nil
        }
        for i in nodes.indices {
            if keyOf(nodes[i]) == leaf && selects(selector: selector, nodeIndex: i, nodes: nodes, keyOf: keyOf, parentOf: parentOf) {
                return i
            }
        }
        return nil
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
