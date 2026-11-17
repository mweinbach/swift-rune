import Foundation
import RuneMotion

// MARK: - Snapshot Across Retries (`rune::memo::snapshot`)

/// Deprecated no-op handle kept for source compatibility; `MemoSnapshot` scopes strictly per commit (`memo::snapshot`).
public final class MemoSnapshotHistory: @unchecked Sendable {
    public init() {}
}

struct SnapshotKey: Hashable, @unchecked Sendable {
    let name: String
    let typeId: ObjectIdentifier
}

final class MemoSnapshotSession: @unchecked Sendable {
    var seenInCommit: [SnapshotKey: Any] = [:]

    func value<T>(key: String, current: T) -> T {
        let sk = SnapshotKey(name: key, typeId: ObjectIdentifier(T.self))
        if let frozen = seenInCommit[sk] as? T {
            return frozen
        }
        seenInCommit[sk] = current
        return current
    }
}

/// Scoped snapshot state across settle retries within a single commit (`rune::memo::snapshot`).
public enum MemoSnapshot {
    @TaskLocal static var currentSession: MemoSnapshotSession?

    /// Runs `body` inside a fresh per-commit snapshot scope; freezes the first value seen per key for this commit only.
    public static func enter<R>(
        history: MemoSnapshotHistory? = nil,
        _ body: () throws -> R
    ) rethrows -> R {
        _ = history
        let session = MemoSnapshotSession()
        return try $currentSession.withValue(session, operation: body)
    }

    /// Freezes the first value seen for `key` within the active commit scope (`memo::snapshot`).
    public static func snapshot<T>(_ key: String, _ value: T) -> T {
        guard let session = currentSession else { return value }
        return session.value(key: key, current: value)
    }
}

/// Free function matching `rune::memo::snapshot`.
public func snapshot<T>(_ key: String, _ value: T) -> T {
    MemoSnapshot.snapshot(key, value)
}

// MARK: - Memo Scope & Geometry Reads (`rune::memo`)

/// Cached layout & caret geometry exposed to `Cx.layout`, `Cx.layoutSize`, `Cx.windowLayout`, and `Cx.caret`.
public struct MemoElementGeometry: Sendable, Equatable {
    public var rect: MotionRect
    public var windowRect: MotionRect
    public var caretRect: MotionRect?
    public var selectionBoxes: [[Float]]?

    public init(
        rect: MotionRect,
        windowRect: MotionRect? = nil,
        caretRect: MotionRect? = nil,
        selectionBoxes: [[Float]]? = nil
    ) {
        self.rect = rect
        self.windowRect = windowRect ?? rect
        self.caretRect = caretRect
        self.selectionBoxes = selectionBoxes
    }
}

/// Dynamic dependency recorded inside a `memo` or `region` build (`rune::memo::Read`).
public enum MemoRead: Sendable, Equatable {
    case layout(key: String, rect: MotionRect?)
    case layoutWith(key: String, tag: UInt64, matchesRect: @Sendable (MotionRect?) -> Bool)
    case windowLayout(key: String, rect: MotionRect?)
    case windowLayoutWith(key: String, tag: UInt64, matchesRect: @Sendable (MotionRect?) -> Bool)
    case layoutSize(key: String, size: Vec2?)
    case caret(key: String, rect: MotionRect?)
    case selectionRects(boxes: [[Float]])
    case tracked(cellId: UInt32, version: UInt64)

    public static func == (lhs: MemoRead, rhs: MemoRead) -> Bool {
        switch (lhs, rhs) {
        case let (.layout(k1, r1), .layout(k2, r2)): return k1 == k2 && r1 == r2
        case let (.layoutWith(k1, t1, _), .layoutWith(k2, t2, _)): return k1 == k2 && t1 == t2
        case let (.windowLayout(k1, r1), .windowLayout(k2, r2)): return k1 == k2 && r1 == r2
        case let (.windowLayoutWith(k1, t1, _), .windowLayoutWith(k2, t2, _)): return k1 == k2 && t1 == t2
        case let (.layoutSize(k1, s1), .layoutSize(k2, s2)): return k1 == k2 && s1 == s2
        case let (.caret(k1, r1), .caret(k2, r2)): return k1 == k2 && r1 == r2
        case let (.selectionRects(b1), .selectionRects(b2)): return b1 == b2
        case let (.tracked(c1, v1), .tracked(c2, v2)): return c1 == c2 && v1 == v2
        default: return false
        }
    }

    public func matches(_ geometry: [String: MemoElementGeometry]) -> Bool {
        switch self {
        case .layout(let key, let prev):
            return Self.rectsMatch(prev, geometry[key]?.rect, tolerance: 0.5)
        case .layoutWith(let key, _, let matchesRect):
            return matchesRect(geometry[key]?.rect)
        case .windowLayout(let key, let prev):
            return Self.rectsMatch(prev, geometry[key]?.windowRect, tolerance: 0.5)
        case .windowLayoutWith(let key, _, let matchesRect):
            return matchesRect(geometry[key]?.windowRect)
        case .layoutSize(let key, let prev):
            return prev == geometry[key]?.rect.size
        case .caret(let key, let prev):
            return prev == geometry[key]?.caretRect
        case .selectionRects(let boxes):
            let next = geometry[MemoScope.selectionRectsKey]?.selectionBoxes ?? []
            return !SelectionRectsMath.boxesMoved(boxes, next)
        case .tracked(let cellId, let recordedVer):
            return MemoTrackedBridge.version(for: cellId) == recordedVer
        }
    }

    private static func rectsMatch(_ a: MotionRect?, _ b: MotionRect?, tolerance: Float) -> Bool {
        switch (a, b) {
        case (.none, .none):
            return true
        case (.some(let ra), .some(let rb)):
            return abs(ra.left - rb.left) <= tolerance
                && abs(ra.top - rb.top) <= tolerance
                && abs(ra.right - rb.right) <= tolerance
                && abs(ra.bottom - rb.bottom) <= tolerance
        default:
            return false
        }
    }

    internal func sameTarget(as other: MemoRead) -> Bool {
        switch (self, other) {
        case let (.layout(k1, _), .layout(k2, _)): return k1 == k2
        case let (.layoutWith(k1, _, _), .layoutWith(k2, _, _)): return k1 == k2
        case let (.windowLayout(k1, _), .windowLayout(k2, _)): return k1 == k2
        case let (.windowLayoutWith(k1, _, _), .windowLayoutWith(k2, _, _)): return k1 == k2
        case let (.layoutSize(k1, _), .layoutSize(k2, _)): return k1 == k2
        case let (.caret(k1, _), .caret(k2, _)): return k1 == k2
        case (.selectionRects, .selectionRects): return true
        case let (.tracked(c1, _), .tracked(c2, _)): return c1 == c2
        default: return false
        }
    }
}

enum MemoTrackedBridge {
    nonisolated(unsafe) static var versionProvider: ((UInt32) -> UInt64)?
    nonisolated(unsafe) static var activeStackCount: (() -> Int)?

    static func version(for cellId: UInt32) -> UInt64 {
        versionProvider?(cellId) ?? 0
    }
}

enum MemoRegionWarningsStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var warnings: [String] = []

    static func recordIfMismatch<State>(id: String, reused: El<State>, rebuild: () -> El<State>) {
        #if DEBUG
        var fresh = rebuild()
        if !id.hasPrefix("cached:") && fresh.keyId == nil {
            fresh = fresh.key(id)
        }
        var a: [String] = []
        var b: [String] = []
        describeTree(reused, parent: "", into: &a)
        describeTree(fresh, parent: "", into: &b)
        let n = Swift.max(a.count, b.count)
        for i in 0..<n {
            let lhs = i < a.count ? a[i] : nil
            let rhs = i < b.count ? b[i] : nil
            if lhs != rhs {
                let prefix = "rune: region \"\(id)\" "
                lock.lock()
                if !warnings.contains(where: { $0.hasPrefix(prefix) }) {
                    let msg = "\(prefix)was reused, but building it again gives something else at element \(i): reused \(lhs.map { "\"\($0)\"" } ?? "(none)"), built \(rhs.map { "\"\($0)\"" } ?? "(none)"). It reads state that isn't Tracked."
                    warnings.append(msg)
                }
                lock.unlock()
                if let scope = MemoScope.current,
                   !scope.regionWarnings.contains(where: { $0.hasPrefix(prefix) }) {
                    let msg = "\(prefix)was reused, but building it again gives something else at element \(i): reused \(lhs.map { "\"\($0)\"" } ?? "(none)"), built \(rhs.map { "\"\($0)\"" } ?? "(none)"). It reads state that isn't Tracked."
                    scope.regionWarnings.append(msg)
                }
                break
            }
        }
        #endif
    }

    static func all() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return warnings
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        warnings.removeAll()
    }

    private static func describeTree<State>(_ el: El<State>, parent: String, into out: inout [String]) {
        let keySeg = el.keyId ?? "#"
        let path = "\(parent)/\(keySeg)"
        let txtColorHex = el.textColor?.hex() ?? "default"
        let txtDesc = el.plainText.map { "\"\($0)\"(\(txtColorHex),\(el.textStyle.size)/\(el.textStyle.weight))" } ?? "none"
        let roleDesc = el.role.rawValue
        out.append("\(path) \(roleDesc) bg=\(el.background.hex()) op=\(el.opacity) size=(\(el.layout.width),\(el.layout.height)) txt=\(txtDesc)")
        for child in el.children {
            describeTree(child, parent: path, into: &out)
        }
    }
}

final class MemoBuildScope: @unchecked Sendable {
    let cache: MemoCache
    let envHash: UInt64
    let geometry: [String: MemoElementGeometry]
    let pass: UInt64
    var prefixStack: [String] = []
    var seenScopedIds: Set<String> = []
    var cachedSlotIndex: [UInt64: Int] = [:]
    var readFrames: [[MemoRead]] = []
    var topLevelReads: [MemoRead] = []
    var nestedFrames: [[String]] = []
    var allTouchedScopedIds: Set<String> = []
    var regionWarnings: [String] = []
    var isVerificationDryRun: Bool = false

    init(cache: MemoCache, envHash: UInt64, geometry: [String: MemoElementGeometry], pass: UInt64) {
        self.cache = cache
        self.envHash = envHash
        self.geometry = geometry
        self.pass = pass
    }

    func scopedId(for id: String) -> String {
        if prefixStack.isEmpty { return id }
        return (prefixStack + [id]).joined(separator: "/")
    }

    func record(_ read: MemoRead) {
        if readFrames.isEmpty {
            topLevelReads.append(read)
        } else {
            readFrames[readFrames.count - 1].append(read)
        }
    }

    func recordNested(_ childId: String) {
        guard !nestedFrames.isEmpty else { return }
        nestedFrames[nestedFrames.count - 1].append(childId)
    }
}

/// Active build scope and environment hashing for `memo`, `region`, and `Cx` layout reads.
public enum MemoScope {
    @TaskLocal static var current: MemoBuildScope?
    private static let lastWarningsLock = NSLock()
    nonisolated(unsafe) private static var lastWarnings: [String] = []

    static var activeCache: MemoCache? { current?.cache }
    public static var activeCacheObject: AnyObject? { current?.cache }
    static var activeEnvHash: UInt64 { current?.envHash ?? currentEnvironmentHash() }
    static var isInsideMemo: Bool { !(current?.readFrames.isEmpty ?? true) }

    public static func environmentHash(
        systemDark: Bool,
        pixelScale: Float,
        reducedMotion: Bool,
        srgbBlend: Bool,
        accent: Color? = nil,
        focusColor: Color? = nil,
        chromeInsets: [Float] = [0, 0, 0, 0],
        scrollerOverlay: Bool = true,
        hoverNone: Bool = false,
        touchControls: Bool = false
    ) -> UInt64 {
        var h = Hasher()
        h.combine(systemDark)
        h.combine(pixelScale.bitPattern)
        h.combine(reducedMotion)
        h.combine(srgbBlend)
        h.combine(accent)
        h.combine(focusColor)
        for v in chromeInsets { h.combine(v.bitPattern) }
        h.combine(scrollerOverlay)
        h.combine(hoverNone)
        h.combine(touchControls)
        return UInt64(bitPattern: Int64(h.finalize()))
    }

    static func currentEnvironmentHash() -> UInt64 {
        environmentHash(
            systemDark: true,
            pixelScale: 2.0,
            reducedMotion: false,
            srgbBlend: Theme.blendsSrgb()
        )
    }

    final class TouchedIdsBox {
        var ids: Set<String> = []
        var reads: [MemoRead] = []
        var trackedReads = TrackedReads()
    }

    /// Runs `body` inside an active `MemoScope` backed by `cache`.
    public static func enter<R>(
        cache: MemoCache,
        envHash: UInt64,
        geometry: [String: MemoElementGeometry] = [:],
        _ body: () throws -> R
    ) rethrows -> R {
        let pass = cache.advancePass()
        let scope = MemoBuildScope(cache: cache, envHash: envHash, geometry: geometry, pass: pass)
        defer {
            cache.setViewReads(scope.topLevelReads, pass: pass)
            lastWarningsLock.lock()
            lastWarnings = scope.regionWarnings
            lastWarningsLock.unlock()
        }
        return try $current.withValue(scope, operation: body)
    }

    static func enterCollectingTouched<R>(
        cache: MemoCache,
        envHash: UInt64,
        geometry: [String: MemoElementGeometry] = [:],
        touchedIdsOut: TouchedIdsBox,
        _ body: () throws -> R
    ) rethrows -> R {
        let pass = cache.advancePass()
        let scope = MemoBuildScope(cache: cache, envHash: envHash, geometry: geometry, pass: pass)
        defer {
            cache.setViewReads(scope.topLevelReads, pass: pass)
            lastWarningsLock.lock()
            lastWarnings = scope.regionWarnings
            lastWarningsLock.unlock()
            touchedIdsOut.ids = scope.allTouchedScopedIds
        }
        return try $current.withValue(scope, operation: body)
    }

    /// Runs `body` inside an active `MemoScope` backed by `cache` reusing `pass` without advancing `passCounter`.
    static func enterVirtualRow<R>(
        cache: MemoCache,
        envHash: UInt64,
        geometry: [String: MemoElementGeometry] = [:],
        pass: UInt64,
        touchedIdsOut: TouchedIdsBox? = nil,
        _ body: () throws -> R
    ) rethrows -> R {
        let scope = MemoBuildScope(cache: cache, envHash: envHash, geometry: geometry, pass: pass)
        let (out, tracked): (R, TrackedReads) = try $current.withValue(scope) {
            try trackedReads(body)
        }
        if let touchedIdsOut {
            touchedIdsOut.ids = scope.allTouchedScopedIds
            touchedIdsOut.reads = scope.topLevelReads
            touchedIdsOut.trackedReads = tracked
        }
        return out
    }

    static func recordedWarnings() -> [String] {
        lastWarningsLock.lock()
        defer { lastWarningsLock.unlock() }
        return lastWarnings
    }

    static func readLayout(_ key: String) -> [Float]? {
        let rect = current?.geometry[key]?.rect
        current?.record(.layout(key: key, rect: rect))
        return rect.map { [$0.left, $0.top, $0.width, $0.height] }
    }

    static func readWindowLayout(_ key: String) -> [Float]? {
        let rect = current?.geometry[key]?.windowRect
        current?.record(.windowLayout(key: key, rect: rect))
        return rect.map { [$0.left, $0.top, $0.width, $0.height] }
    }

    static func peekLayoutRect(_ key: String, window: Bool) -> [Float]? {
        let rect = window ? current?.geometry[key]?.windowRect : current?.geometry[key]?.rect
        return rect.map { [$0.left, $0.top, $0.width, $0.height] }
    }

    static func recordLayoutRead(_ read: MemoRead) {
        current?.record(read)
    }

    static func makeLayoutWithRead<T: Equatable>(
        _ key: String,
        window: Bool,
        rect: [Float]?,
        _ transform: @escaping ([Float]) -> T
    ) -> (read: MemoRead, value: T?) {
        let initial = rect.map(transform)
        let tag = MemoReadTag.next()
        let box = UncheckedMotionPredicateBox { nextRect in
            let next = nextRect.map { transform([$0.left, $0.top, $0.width, $0.height]) }
            return next == initial
        }
        let read: MemoRead = window
            ? .windowLayoutWith(key: key, tag: tag) { box.matches($0) }
            : .layoutWith(key: key, tag: tag) { box.matches($0) }
        return (read, initial)
    }

    static func readLayoutWith<T: Equatable & Sendable>(
        _ key: String,
        _ transform: @escaping @Sendable ([Float]) -> T,
        into reads: inout [MemoRead]
    ) -> T? {
        let rect = current?.geometry[key]?.rect
        let initial = rect.map { transform([$0.left, $0.top, $0.width, $0.height]) }
        let tag = MemoReadTag.next()
        let entry: MemoRead = .layoutWith(key: key, tag: tag) { nextRect in
            let next = nextRect.map { transform([$0.left, $0.top, $0.width, $0.height]) }
            return next == initial
        }
        current?.record(entry)
        reads.append(entry)
        return initial
    }

    static func readLayoutWith<T: Equatable & Sendable>(
        _ key: String,
        _ transform: @escaping @Sendable ([Float]) -> T
    ) -> T? {
        var ignored: [MemoRead] = []
        return readLayoutWith(key, transform, into: &ignored)
    }

    static func readWindowLayoutWith<T: Equatable & Sendable>(
        _ key: String,
        _ transform: @escaping @Sendable ([Float]) -> T,
        into reads: inout [MemoRead]
    ) -> T? {
        let rect = current?.geometry[key]?.windowRect
        let initial = rect.map { transform([$0.left, $0.top, $0.width, $0.height]) }
        let tag = MemoReadTag.next()
        let entry: MemoRead = .windowLayoutWith(key: key, tag: tag) { nextRect in
            let next = nextRect.map { transform([$0.left, $0.top, $0.width, $0.height]) }
            return next == initial
        }
        current?.record(entry)
        reads.append(entry)
        return initial
    }

    static func readWindowLayoutWith<T: Equatable & Sendable>(
        _ key: String,
        _ transform: @escaping @Sendable ([Float]) -> T
    ) -> T? {
        var ignored: [MemoRead] = []
        return readWindowLayoutWith(key, transform, into: &ignored)
    }

    static func readLayoutSize(_ key: String) -> [Float]? {
        let size = current?.geometry[key]?.rect.size
        current?.record(.layoutSize(key: key, size: size))
        return size.map { [$0.x, $0.y] }
    }

    static func readCaret(_ key: String) -> [Float]? {
        let rect = current?.geometry[key]?.caretRect
        current?.record(.caret(key: key, rect: rect))
        return rect.map { [$0.left, $0.top, $0.width, $0.height] }
    }

    static let selectionRectsKey = "\u{1}selection"

    static func readSelectionRects(fallback: [[Float]]) -> [[Float]] {
        let boxes = current?.geometry[selectionRectsKey]?.selectionBoxes ?? fallback
        current?.record(.selectionRects(boxes: boxes))
        return boxes
    }
}

private final class UncheckedMotionPredicateBox: @unchecked Sendable {
    private let fn: (MotionRect?) -> Bool

    init(_ fn: @escaping (MotionRect?) -> Bool) {
        self.fn = fn
    }

    func matches(_ nextRect: MotionRect?) -> Bool {
        fn(nextRect)
    }
}

private enum MemoReadTag {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counter: UInt64 = 1

    static func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let out = counter
        counter &+= 1
        return out
    }
}

// MARK: - Free Layout Read Helpers & Cx Extensions

public func layoutRect(_ key: String) -> [Float]? {
    MemoScope.readLayout(key)
}

public func layoutWith<T: Equatable & Sendable>(
    _ key: String,
    _ transform: @escaping @Sendable ([Float]) -> T
) -> T? {
    MemoScope.readLayoutWith(key, transform)
}

public func layoutSize(_ key: String) -> [Float]? {
    MemoScope.readLayoutSize(key)
}

public func windowLayout(_ key: String) -> [Float]? {
    MemoScope.readWindowLayout(key)
}

public func windowLayoutWith<T: Equatable & Sendable>(
    _ key: String,
    _ transform: @escaping @Sendable ([Float]) -> T
) -> T? {
    MemoScope.readWindowLayoutWith(key, transform)
}

public func caretRect(_ key: String) -> [Float]? {
    MemoScope.readCaret(key)
}

/// Active `El.selectable` line rects `[x, y, width, height]` inside a `memo` or view pass.
public func selectionRects() -> [[Float]] {
    MemoScope.readSelectionRects(fallback: [])
}

extension Cx {
    /// Last rendered `[x, y, width, height]` caret rect of text field `.key(key)`.
    public func caret(_ key: String) -> [Float]? {
        envState.reads.caretRead = true
        let scoped = MemoScope.readCaret(key)
        return caretRectForKey(envState.caret, key: key) ?? scoped
    }

    /// Line boxes `[x, y, width, height]` of the active `El.selectable` text selection in
    /// post-scroll window points (`Cx::selection_rects`). Triggers re-evaluation when boxes appear,
    /// disappear, or move by > 0.5 pt.
    public func selectionRects() -> [[Float]] {
        envState.reads.selectionRectsRead = true
        let boxes = MemoScope.isInsideMemo
            ? MemoScope.readSelectionRects(fallback: envState.selectionRects)
            : envState.selectionRects
        envState.reads.layoutReads.append(.selectionRects(boxes: boxes))
        return boxes
    }

    /// Registers `SelectionMark` slices saved via `SelectedText.mark()` so custom highlight boxes
    /// remain drawn after selection clears (`Cx::mark_texts`).
    public mutating func markTexts(_ marks: [SelectionMark]) {
        guard !marks.isEmpty else { return }
        envState.markedTexts.append(contentsOf: marks)
    }
}

// MARK: - Digest, Cached, RegionWith & Warnings

/// Computes a deterministic 64-bit digest for `cached(_:build:)` (`memo::digest`).
public func memoDigest(_ parts: AnyHashable...) -> UInt64 {
    var h = Hasher()
    for p in parts { h.combine(p) }
    return UInt64(bitPattern: Int64(h.finalize()))
}

/// Returns diagnostics recorded by `region` / `regionWith` during cached hits (`memo::region_warnings`).
public func regionWarnings() -> [String] {
    MemoRegionWarningsStore.all()
}

/// Clears accumulated `regionWarnings()` diagnostics.
public func clearRegionWarnings() {
    MemoRegionWarningsStore.clear()
}

/// Caches an `El<State>` subtree keyed by a 64-bit `digest`, preserving index paths across unkeyed siblings (`memo::cached`).
public func cached<State>(
    _ digest: UInt64,
    cache: MemoCache? = nil,
    build: () -> El<State>
) -> El<State> {
    let targetCache = cache ?? MemoScope.activeCache ?? .shared
    let slot: Int
    if let scope = MemoScope.current {
        let count = scope.cachedSlotIndex[digest, default: 0]
        scope.cachedSlotIndex[digest] = count + 1
        slot = count
    } else {
        slot = 0
    }
    return targetCache.getOrBuildMemo(
        rawId: "cached:\(String(digest, radix: 16)):\(slot)",
        deps: digest,
        ignoreDuplicateGuard: true,
        build: build
    ).element
}

extension Runtime {
    /// Evicts cached memo entries matching `prefix` and schedules a view commit (`memo::evict_prefix`).
    public func invalidateMemos(byPrefix prefix: String) {
        memo.evictPrefix(prefix)
        markNeedsCommit()
    }

    /// Marks the tree dirty at the current clock. The next frame advances any new layout tracks
    /// through its elapsed time, as in Rust’s `invalidate()` followed by `frame(dt)`.
    public func invalidate() {
        invalidate(at: currentTime)
    }

    /// Updates dark/light mode (`Runtime::set_system_dark`).
    public func setSystemDark(_ dark: Bool) {
        systemDark = dark
    }
}
