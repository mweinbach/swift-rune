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

    public init(rect: MotionRect, windowRect: MotionRect? = nil, caretRect: MotionRect? = nil) {
        self.rect = rect
        self.windowRect = windowRect ?? rect
        self.caretRect = caretRect
    }
}

/// Dynamic dependency recorded inside a `memo` or `region` build (`rune::memo::Read`).
public enum MemoRead: Sendable, Equatable {
    case layout(key: String, rect: MotionRect?)
    case windowLayout(key: String, rect: MotionRect?)
    case layoutSize(key: String, size: Vec2?)
    case caret(key: String, rect: MotionRect?)
    case tracked(cellId: UInt32, version: UInt64)

    public func matches(_ geometry: [String: MemoElementGeometry]) -> Bool {
        switch self {
        case .layout(let key, let prev):
            return Self.rectsMatch(prev, geometry[key]?.rect, tolerance: 0.5)
        case .windowLayout(let key, let prev):
            return Self.rectsMatch(prev, geometry[key]?.windowRect, tolerance: 0.5)
        case .layoutSize(let key, let prev):
            let cur = geometry[key]?.rect.size
            switch (prev, cur) {
            case (.none, .none): return true
            case (.some(let a), .some(let b)):
                return abs(a.x - b.x) <= 0.01 && abs(a.y - b.y) <= 0.01
            default: return false
            }
        case .caret(let key, let prev):
            return Self.rectsMatch(prev, geometry[key]?.caretRect, tolerance: 0.01)
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
        let fresh = rebuild()
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
    static var activeEnvHash: UInt64 { current?.envHash ?? currentEnvironmentHash() }

    public static func environmentHash(
        systemDark: Bool,
        pixelScale: Float,
        reducedMotion: Bool,
        srgbBlend: Bool,
        accent: Color? = nil,
        focusColor: Color? = nil,
        chromeInsets: [Float] = [0, 0, 0, 0]
    ) -> UInt64 {
        var h = Hasher()
        h.combine(systemDark)
        h.combine(pixelScale.bitPattern)
        h.combine(reducedMotion)
        h.combine(srgbBlend)
        h.combine(accent)
        h.combine(focusColor)
        for v in chromeInsets { h.combine(v.bitPattern) }
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
}

// MARK: - Free Layout Read Helpers & Cx Extensions

public func layoutRect(_ key: String) -> [Float]? {
    MemoScope.readLayout(key)
}

public func layoutSize(_ key: String) -> [Float]? {
    MemoScope.readLayoutSize(key)
}

public func windowLayout(_ key: String) -> [Float]? {
    MemoScope.readWindowLayout(key)
}

public func caretRect(_ key: String) -> [Float]? {
    MemoScope.readCaret(key)
}

extension Cx {
    /// Last committed `[x, y, width, height]` of `.key(key)` in window space, recording a layout read.
    public func layout(_ key: String) -> [Float]? {
        let rect = MemoScope.readLayout(key)
        envState.reads.layoutReads.append(.layout(key: key, rect: rect.map { MotionRect.fromXYWH($0[0], $0[1], $0[2], $0[3]) }))
        return rect
    }

    /// Last committed `[width, height]` of `.key(key)`, invalidating memos only on size changes.
    public func layoutSize(_ key: String) -> [Float]? {
        let size = MemoScope.readLayoutSize(key)
        envState.reads.layoutReads.append(.layoutSize(key: key, size: size.map { Vec2($0[0], $0[1]) }))
        return size
    }

    /// Last committed `[x, y, width, height]` of `.key(key)` in window coordinates (0.5 pt hysteresis).
    public func windowLayout(_ key: String) -> [Float]? {
        let rect = MemoScope.readWindowLayout(key)
        envState.reads.layoutReads.append(.windowLayout(key: key, rect: rect.map { MotionRect.fromXYWH($0[0], $0[1], $0[2], $0[3]) }))
        return rect
    }

    /// Last rendered `[x, y, width, height]` caret rect of text field `.key(key)`.
    public func caret(_ key: String) -> [Float]? {
        envState.reads.caretRead = true
        let scoped = MemoScope.readCaret(key)
        return caretRectForKey(envState.caret, key: key) ?? scoped
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

    /// Forces a view rebuild on the next `frame(at:)` (`Runtime::invalidate`).
    public func invalidate() {
        markNeedsCommit()
    }

    /// Updates dark/light mode (`Runtime::set_system_dark`).
    public func setSystemDark(_ dark: Bool) {
        systemDark = dark
    }
}
