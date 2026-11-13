import Foundation
import RuneMotion

// MARK: - Shared-Element Flight & Matched Geometry (`rune::flight`)

/// Key-path selector matching (`"body"` or `"msg-42/body"`).
public enum FlightSelector {
    /// Returns true if `selector` matches a node at `path` with optional `key`.
    public static func selects(_ selector: String, path: String, key: String?) -> Bool {
        guard let key else { return false }
        if selector == key { return true }
        let suffix = "/" + key
        let atSuffix = "/@" + key
        guard selector.hasSuffix(suffix) else { return false }
        let above: Substring
        if path.hasSuffix(atSuffix) {
            above = path.dropLast(atSuffix.count)
        } else if path.hasSuffix(suffix) {
            above = path.dropLast(suffix.count)
        } else {
            return false
        }
        let scope = selector.dropLast(suffix.count)
        let scopeParts = scope.split(separator: "/").reversed()
        let pathKeyed = above.split(separator: "/").compactMap { seg -> Substring? in
            if seg.hasPrefix("@") { return seg.dropFirst() }
            if seg.hasPrefix("#") || seg.allSatisfy(\.isNumber) { return nil }
            return seg
        }.reversed()
        var pathIter = pathKeyed.makeIterator()
        for seg in scopeParts {
            guard pathIter.next() == seg else { return false }
        }
        return true
    }
}

/// Active cross-container text or element flight interpolating between `source` and `destination`.
public struct TextFlightState: Sendable, Equatable {
    public static func == (lhs: TextFlightState, rhs: TextFlightState) -> Bool {
        lhs.sourceKey == rhs.sourceKey &&
        lhs.targetKey == rhs.targetKey &&
        lhs.source == rhs.source &&
        lhs.destination == rhs.destination &&
        lhs.presented == rhs.presented &&
        lhs.born == rhs.born &&
        lhs.unclipped == rhs.unclipped
    }
    public var sourceKey: String
    public var targetKey: String
    public var source: MotionRect
    public var destination: MotionRect
    public var presented: MotionRect
    public var born: Double
    public var unclipped: Bool
    private var progressAnim: Animated<Float>

    public init(
        sourceKey: String,
        targetKey: String,
        source: MotionRect,
        born: Double,
        unclipped: Bool = false,
        spring: Spring? = nil
    ) {
        self.sourceKey = sourceKey
        self.targetKey = targetKey
        self.source = source
        self.destination = source
        self.presented = source
        self.born = born
        self.unclipped = unclipped
        var anim = Animated<Float>(0, propClass: .opacity)
        anim.animateTo(1, anim: .spring(spring ?? GrowthCaps.growthSpring), at: born)
        self.progressAnim = anim
    }

    public func progress(at now: Double, reducedMotion: Bool) -> Float {
        if reducedMotion {
            return Float(min(1.0, max(0.0, (now - born) / 0.15)))
        }
        return min(1.0, max(0.0, progressAnim.sample(at: now)))
    }

    /// Updates `destination` and interpolates `presented`; returns `true` when settled.
    @discardableResult
    public mutating func measure(target: MotionRect, now: Double, reducedMotion: Bool) -> Bool {
        self.destination = target
        let p = reducedMotion ? 1.0 : progress(at: now, reducedMotion: false)
        let from = source
        presented = MotionRect.fromXYWH(
            from.x + (target.x - from.x) * p,
            from.y + (target.y - from.y) * p,
            from.width + (target.width - from.width) * p,
            from.height + (target.height - from.height) * p
        )
        if reducedMotion {
            return progress(at: now, reducedMotion: true) >= 1.0
        }
        return progressAnim.isSettled(at: now)
    }

    public func alphas(target: MotionRect, now: Double, reducedMotion: Bool) -> (source: Float, target: Float) {
        let p = progress(at: now, reducedMotion: reducedMotion)
        if reducedMotion {
            return (1.0 - p, p)
        }
        let rewrap = abs(target.height - source.height) > 2.0
        let outEnd: Float = rewrap ? 0.25 : 0.4
        let inEnd: Float = rewrap ? 0.4 : 0.5
        let sAlpha = min(1.0, max(0.0, 1.0 - p / outEnd))
        let tAlpha: Float
        if rewrap {
            tAlpha = min(1.0, max(0.0, (p - 0.1) / (inEnd - 0.1)))
        } else {
            tAlpha = min(1.0, max(0.0, p / inEnd))
        }
        return (sAlpha, tAlpha)
    }
}

/// Cross-container matched-geometry flight registry keyed by `flightId`.
public final class MatchedFlightRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var previousRects: [String: MotionRect] = [:]
    private var activeFlights: [String: TextFlightState] = [:]

    public init() {}

    /// Records the previous frame's layout rect for `flightId`.
    public func recordPrevious(flightId: String, rect: MotionRect) {
        lock.lock()
        defer { lock.unlock() }
        previousRects[flightId] = rect
    }

    /// Starts or advances a matched-geometry flight for `flightId` toward `targetRect`.
    public func stepFlight(
        flightId: String,
        targetRect: MotionRect,
        now: Double,
        reducedMotion: Bool,
        unclipped: Bool = false
    ) -> MotionRect {
        lock.lock()
        defer { lock.unlock() }

        if var flight = activeFlights[flightId] {
            let settled = flight.measure(target: targetRect, now: now, reducedMotion: reducedMotion)
            if settled {
                activeFlights.removeValue(forKey: flightId)
                previousRects[flightId] = targetRect
                return targetRect
            }
            activeFlights[flightId] = flight
            return flight.presented
        }

        if let prev = previousRects[flightId],
           abs(prev.x - targetRect.x) > 0.5 ||
           abs(prev.y - targetRect.y) > 0.5 ||
           abs(prev.width - targetRect.width) > 0.5 ||
           abs(prev.height - targetRect.height) > 0.5 {
            var flight = TextFlightState(
                sourceKey: flightId,
                targetKey: flightId,
                source: prev,
                born: now,
                unclipped: unclipped
            )
            _ = flight.measure(target: targetRect, now: now, reducedMotion: reducedMotion)
            activeFlights[flightId] = flight
            previousRects[flightId] = targetRect
            return flight.presented
        }

        previousRects[flightId] = targetRect
        return targetRect
    }

    public var hasActiveFlights: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !activeFlights.isEmpty
    }
}

// MARK: - Motion Gate (`rune::motion_gate`)

/// Tracks active springs/flights and guards against infinite animation loops.
public final class MotionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount: Int = 0
    private var lastFrameTime: Double = 0
    private var consecutiveAnimatedFrames: Int = 0
    public let maxContinuousFrames: Int

    public init(maxContinuousFrames: Int = 10_000) {
        self.maxContinuousFrames = maxContinuousFrames
    }

    public func beginFrame(now: Double, activeAnimations: Int) {
        lock.lock()
        defer { lock.unlock() }
        activeCount = activeAnimations
        if activeAnimations > 0 {
            consecutiveAnimatedFrames += 1
        } else {
            consecutiveAnimatedFrames = 0
        }
        lastFrameTime = now
    }

    public var isAnimating: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeCount > 0 && consecutiveAnimatedFrames <= maxContinuousFrames
    }

    public var didTripLoopGuard: Bool {
        lock.lock()
        defer { lock.unlock() }
        return consecutiveAnimatedFrames > maxContinuousFrames
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        activeCount = 0
        consecutiveAnimatedFrames = 0
    }
}

// MARK: - Subtree Memoization (`rune::memo`)

/// Cache storing memoized `El<State>` subtrees keyed by `id` and `Equatable` dependency snapshots.
public final class MemoCache: @unchecked Sendable {
    public static let shared = MemoCache()

    private struct Entry {
        var deps: Any
        var equals: (Any) -> Bool
        var srgbBlend: Bool
        var envHash: UInt64
        var reads: [MemoRead]
        var nestedIds: [String]
        var passBuilt: UInt64
        var element: Any
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var generation: UInt64 = 0
    private var passCounter: UInt64 = 1
    private var viewReads: [MemoRead] = []
    private var viewReadsPass: UInt64 = 0
    private var buildCount: UInt64 = 0

    /// Number of entries currently retained in the cache (`MemoCache::len`).
    public var len: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Cumulative number of cache-miss subtree builds (`MemoCache::builds`).
    public var builds: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return buildCount
    }

    public init() {}

    @discardableResult
    public func advancePass() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        passCounter &+= 1
        return passCounter
    }

    /// Returns the pass number that the next `advancePass()` / `MemoScope.enter` will receive (`memo::next_pass`).
    public func nextPass() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return passCounter &+ 1
    }

    /// Current pass counter without advancing.
    public var currentPass: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return passCounter
    }

    /// Marks cached entries so the next build re-verifies against a new pass (`memo::as_next_build`).
    @discardableResult
    public func asNextBuild() -> UInt64 {
        advancePass()
    }

    /// Evicts entries not touched or built since `minPass` (`memo::keep_since`).
    public func keepSince(_ minPass: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { $0.value.passBuilt >= minPass }
    }

    /// Removes specific scoped cache entries by key.
    public func removeEntries(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        lock.lock()
        for id in ids {
            entries.removeValue(forKey: id)
        }
        lock.unlock()
    }

    public func getOrBuild<State, Deps: Equatable>(
        id: String,
        deps: Deps,
        file: String = #fileID,
        line: UInt = #line,
        column: UInt = #column,
        build: () -> El<State>
    ) -> (element: El<State>, hit: Bool) {
        getOrBuildMemo(
            rawId: id,
            deps: deps,
            ignoreDuplicateGuard: false,
            callerLocation: "\(file):\(line):\(column)",
            build: build
        )
    }

    func getOrBuildMemo<State, Deps: Equatable>(
        rawId: String,
        deps: Deps,
        ignoreDuplicateGuard: Bool = false,
        callerLocation: String? = nil,
        build: () -> El<State>
    ) -> (element: El<State>, hit: Bool) {
        let srgb = Theme.blendsSrgb()
        let scope = MemoScope.current
        let scopedId = scope?.scopedId(for: rawId) ?? rawId
        let env = scope?.envHash ?? MemoScope.activeEnvHash
        let curGeometry = scope?.geometry ?? [:]

        // Same-pass duplicate memo IDs bypass caching (`memo.rs:1067`).
        if !ignoreDuplicateGuard, let scope, !scope.isVerificationDryRun {
            if !scope.seenScopedIds.insert(scopedId).inserted {
                var built = build()
                if !rawId.hasPrefix("cached:") && built.keyId == nil {
                    built = built.key(rawId)
                    if let callerLocation { built.keyLocation = callerLocation }
                }
                return (built, false)
            }
        }

        lock.lock()
        if var existing = entries[scopedId],
           existing.srgbBlend == srgb,
           existing.envHash == env,
           existing.equals(deps),
           existing.reads.allSatisfy({ $0.matches(curGeometry) }),
           let cached = existing.element as? El<State> {
            let dryRun = scope?.isVerificationDryRun ?? false
            let recordedReads = existing.reads
            var touchedNested: Set<String> = []
            if !dryRun {
                let pass = scope?.pass ?? passCounter
                existing.passBuilt = pass
                entries[scopedId] = existing
                touchedNested = markNestedTouchedLocked(existing.nestedIds, pass: pass)
            }
            lock.unlock()
            if !dryRun {
                for r in recordedReads { scope?.record(r) }
                scope?.recordNested(scopedId)
                scope?.allTouchedScopedIds.insert(scopedId)
                scope?.allTouchedScopedIds.formUnion(touchedNested)
            }
            return (cached, true)
        }
        lock.unlock()

        let savedTracked = TrackedRecorder.pause()
        scope?.prefixStack.append(rawId)
        scope?.readFrames.append([])
        scope?.nestedFrames.append([])
        var built = build()
        if !rawId.hasPrefix("cached:") && built.keyId == nil {
            built = built.key(rawId)
            if let callerLocation { built.keyLocation = callerLocation }
        }
        TrackedRecorder.resume(savedTracked)
        let capturedReads = scope?.readFrames.popLast() ?? []
        let capturedNested = scope?.nestedFrames.popLast() ?? []
        _ = scope?.prefixStack.popLast()

        let pass = scope?.pass ?? passCounter
        lock.lock()
        buildCount &+= 1
        entries[scopedId] = Entry(
            deps: deps,
            equals: { other in (other as? Deps) == deps },
            srgbBlend: srgb,
            envHash: env,
            reads: capturedReads,
            nestedIds: capturedNested,
            passBuilt: pass,
            element: built
        )
        lock.unlock()
        for r in capturedReads { scope?.record(r) }
        scope?.recordNested(scopedId)
        scope?.allTouchedScopedIds.insert(scopedId)
        return (built, false)
    }

    func getOrBuildRegion<State, Inputs: Equatable>(
        rawId: String,
        inputs: Inputs,
        build: () -> El<State>
    ) -> (element: El<State>, hit: Bool) {
        let srgb = Theme.blendsSrgb()
        let scope = MemoScope.current
        let scopedId = "region:\(scope?.scopedId(for: rawId) ?? rawId)"
        let env = scope?.envHash ?? MemoScope.activeEnvHash
        let curGeometry = scope?.geometry ?? [:]

        // Same-pass duplicate region IDs bypass caching (`memo.rs:638,663-664`).
        if let scope, !scope.isVerificationDryRun {
            if !scope.seenScopedIds.insert(scopedId).inserted {
                var built = build()
                if !rawId.hasPrefix("cached:") && built.keyId == nil { built = built.key(rawId) }
                return (built, false)
            }
        }

        lock.lock()
        if var existing = entries[scopedId],
           existing.srgbBlend == srgb,
           existing.envHash == env,
           existing.equals(inputs),
           existing.reads.allSatisfy({ $0.matches(curGeometry) }),
           let cached = existing.element as? El<State> {
            let dryRun = scope?.isVerificationDryRun ?? false
            let recordedReads = existing.reads
            var touchedNested: Set<String> = []
            if !dryRun {
                let pass = scope?.pass ?? passCounter
                existing.passBuilt = pass
                entries[scopedId] = existing
                touchedNested = markNestedTouchedLocked(existing.nestedIds, pass: pass)
            }
            lock.unlock()
            if !dryRun {
                for r in recordedReads { scope?.record(r) }
                scope?.recordNested(scopedId)
                scope?.allTouchedScopedIds.insert(scopedId)
                scope?.allTouchedScopedIds.formUnion(touchedNested)
                let savedTracked = TrackedRecorder.pause()
                let prevDry = scope?.isVerificationDryRun ?? false
                scope?.isVerificationDryRun = true
                scope?.prefixStack.append("region:\(rawId)")
                scope?.readFrames.append([])
                scope?.nestedFrames.append([])
                MemoRegionWarningsStore.recordIfMismatch(id: rawId, reused: cached, rebuild: build)
                _ = scope?.nestedFrames.popLast()
                _ = scope?.readFrames.popLast()
                _ = scope?.prefixStack.popLast()
                scope?.isVerificationDryRun = prevDry
                TrackedRecorder.resume(savedTracked)
            }
            return (cached, true)
        }
        lock.unlock()

        TrackedRecorder.pushEmpty()
        scope?.prefixStack.append("region:\(rawId)")
        scope?.readFrames.append([])
        scope?.nestedFrames.append([])

        var built = build()
        if !rawId.hasPrefix("cached:") && built.keyId == nil { built = built.key(rawId) }

        let trackedDeps = TrackedRecorder.pop()
        var capturedReads = scope?.readFrames.popLast() ?? []
        let capturedNested = scope?.nestedFrames.popLast() ?? []
        _ = scope?.prefixStack.popLast()

        for (cellId, ver) in trackedDeps {
            capturedReads.append(.tracked(cellId: cellId, version: ver))
        }

        let pass = scope?.pass ?? passCounter
        lock.lock()
        buildCount &+= 1
        entries[scopedId] = Entry(
            deps: inputs,
            equals: { other in (other as? Inputs) == inputs },
            srgbBlend: srgb,
            envHash: env,
            reads: capturedReads,
            nestedIds: capturedNested,
            passBuilt: pass,
            element: built
        )
        lock.unlock()
        for r in capturedReads { scope?.record(r) }
        scope?.recordNested(scopedId)
        scope?.allTouchedScopedIds.insert(scopedId)
        return (built, false)
    }

    @discardableResult
    private func markNestedTouchedLocked(_ nestedIds: [String], pass: UInt64) -> Set<String> {
        var queue = nestedIds
        var visited: Set<String> = []
        while let nid = queue.popLast() {
            guard visited.insert(nid).inserted, var child = entries[nid] else { continue }
            child.passBuilt = pass
            entries[nid] = child
            queue.append(contentsOf: child.nestedIds)
        }
        return visited
    }

    /// Returns `true` if any cached entry from the most recent pass read layout/caret geometry that differs in `geometry`.
    func setViewReads(_ reads: [MemoRead], pass: UInt64) {
        lock.lock()
        viewReads = reads
        viewReadsPass = pass
        lock.unlock()
    }

    public func hasInvalidatedReads(against geometry: [String: MemoElementGeometry]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if viewReadsPass == passCounter {
            for r in viewReads where !r.matches(geometry) {
                return true
            }
        }
        for (_, entry) in entries where entry.passBuilt == passCounter {
            for r in entry.reads where !r.matches(geometry) {
                return true
            }
        }
        return false
    }

    /// Drops all cached subtrees (e.g. on hot reload or theme change).
    public func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        viewReads.removeAll()
        generation &+= 1
    }

    /// Alias matching `memo::MemoCache::clear`.
    public func clear() {
        invalidateAll()
    }

    public func invalidate(id: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: id)
    }

    /// Removes all cached entries where the full key or any `/`-delimited segment starts with `prefix` (including `region:` segments).
    public func evictPrefix(_ prefix: String) {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { key, _ in
            let matchesWhole = key.hasPrefix(prefix) || key.hasPrefix("region:\(prefix)")
            let matchesSegment = key.split(separator: "/").contains { seg in
                if seg.hasPrefix(prefix) { return true }
                if seg.hasPrefix("region:") {
                    return seg.dropFirst(7).hasPrefix(prefix)
                }
                return false
            }
            return !(matchesWhole || matchesSegment)
        }
        generation &+= 1
    }

    public func invalidateByPrefix(_ prefix: String) {
        evictPrefix(prefix)
    }

    public var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// Returns cached region element if all previously read `Tracked` cell versions still match.
    func getRegionIfValid<State>(id: String) -> El<State>? {
        let srgb = Theme.blendsSrgb()
        lock.lock()
        defer { lock.unlock() }
        guard let existing = entries["region:\(id)"],
              existing.srgbBlend == srgb,
              let cached = existing.element as? El<State> else {
            return nil
        }
        for r in existing.reads {
            if case .tracked(let cellId, let recordedVer) = r,
               TrackedIDGenerator.version(for: cellId) != recordedVer {
                return nil
            }
        }
        return cached
    }
}

/// Memoizes a declarative `El<State>` subtree by `deps` (`rune::memo`).
public func memo<State, Deps: Equatable>(
    _ id: String,
    deps: Deps,
    cache: MemoCache? = nil,
    file: String = #fileID,
    line: UInt = #line,
    column: UInt = #column,
    build: () -> El<State>
) -> El<State> {
    let target = cache ?? MemoScope.activeCache ?? .shared
    return target.getOrBuildMemo(
        rawId: id,
        deps: deps,
        callerLocation: "\(file):\(line):\(column)",
        build: build
    ).element
}

/// Unlabelled `memo` convenience matching upstream `rune::memo("id", deps) { ... }`.
public func memo<State, Deps: Equatable>(
    _ id: String,
    _ deps: Deps,
    cache: MemoCache? = nil,
    file: String = #fileID,
    line: UInt = #line,
    column: UInt = #column,
    build: () -> El<State>
) -> El<State> {
    memo(id, deps: deps, cache: cache, file: file, line: line, column: column, build: build)
}

/// Memoizes a declarative `El<State>` subtree by an explicit `UInt64` version hash (`rune::memo_with_hash`).
public func memoWithHash<State>(
    _ id: String,
    _ versionHash: UInt64,
    cache: MemoCache? = nil,
    file: String = #fileID,
    line: UInt = #line,
    column: UInt = #column,
    build: () -> El<State>
) -> El<State> {
    memo(id, deps: versionHash, cache: cache, file: file, line: line, column: column, build: build)
}

// MARK: - Tracked State & Region Memoization (`rune::tracked`)

private enum TrackedRecorder {
    private static let threadKey = "rune.trackedRecorderStack"

    private final class Box: @unchecked Sendable {
        var stack: [[UInt32: UInt64]] = []
    }

    private static var box: Box {
        let dict = Thread.current.threadDictionary
        if let existing = dict[threadKey] as? Box {
            return existing
        }
        let created = Box()
        dict[threadKey] = created
        return created
    }

    static var stack: [[UInt32: UInt64]] {
        box.stack
    }

    static func pushEmpty() {
        box.stack.append([:])
    }

    static func pop() -> [UInt32: UInt64] {
        box.stack.popLast() ?? [:]
    }

    static func record(id: UInt32, version: UInt64) {
        let b = box
        guard !b.stack.isEmpty else { return }
        b.stack[b.stack.count - 1][id] = version
    }

    static func pause() -> [[UInt32: UInt64]] {
        let b = box
        let saved = b.stack
        b.stack = []
        return saved
    }

    static func resume(_ saved: [[UInt32: UInt64]]) {
        box.stack = saved
    }
}

private enum TrackedIDGenerator {
    static let lock = NSLock()
    nonisolated(unsafe) static var nextRawId: UInt32 = 1
    nonisolated(unsafe) static var versions: [UInt32: UInt64] = [:]

    static func next() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextRawId
        nextRawId &+= 1
        versions[id] = 0
        return id
    }

    static func setVersion(_ v: UInt64, for id: UInt32) {
        lock.lock()
        versions[id] = v
        lock.unlock()
    }

    static func version(for id: UInt32) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return versions[id] ?? 0
    }
}

/// A value whose reads are recorded inside `region(_:)` blocks and whose writes bump a version (`rune::Tracked<T>`).
public final class Tracked<T>: @unchecked Sendable {
    public let id: UInt32
    private let lock = NSLock()
    private var storage: T
    private var _version: UInt64 = 0

    public init(_ value: T) {
        self.id = TrackedIDGenerator.next()
        self.storage = value
    }

    /// Reads the value and records the dependency if inside a `region` build.
    public var value: T {
        get {
            lock.lock()
            let v = storage
            let ver = _version
            lock.unlock()

            TrackedRecorder.record(id: id, version: ver)
            return v
        }
        set {
            lock.lock()
            storage = newValue
            _version &+= 1
            let v = _version
            lock.unlock()
            TrackedIDGenerator.setVersion(v, for: id)
        }
    }

    public func modify(_ body: (inout T) -> Void) {
        lock.lock()
        body(&storage)
        _version &+= 1
        let v = _version
        lock.unlock()
        TrackedIDGenerator.setVersion(v, for: id)
    }

    /// Reads without recording a dependency.
    public var untracked: T {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func touch() {
        lock.lock()
        _version &+= 1
        let v = _version
        lock.unlock()
        TrackedIDGenerator.setVersion(v, for: id)
    }

    public var version: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _version
    }
}

/// Builds and caches a region based on the `Tracked` values read during its build (`rune::region`).
public func region<State>(
    _ id: String,
    cache: MemoCache? = nil,
    build: () -> El<State>
) -> El<State> {
    regionWith(id, inputs: true, cache: cache, build: build)
}

/// Builds and caches a region keyed by both explicit `inputs` and any `Tracked` reads inside `build` (`rune::memo::region_with`).
public func regionWith<State, Inputs: Equatable>(
    _ id: String,
    inputs: Inputs,
    cache: MemoCache? = nil,
    build: () -> El<State>
) -> El<State> {
    MemoTrackedBridge.versionProvider = { TrackedIDGenerator.version(for: $0) }
    let target = cache ?? MemoScope.activeCache ?? .shared
    return target.getOrBuildRegion(rawId: id, inputs: inputs, build: build).element
}

// MARK: - Latest-Wins Background Requests (`rune::latest`)

/// A latest-wins background request with optional debounce and stale-answer rejection (`rune::Latest<T>`).
public final class Latest<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pendingWorkItem: DispatchWorkItem?
    private var latestResult: T?
    private var lastKey: AnyHashable?
    private var pending: Bool = false
    private var waker: (@Sendable () -> Void)?
    public var debounceSeconds: TimeInterval

    private let queue = DispatchQueue(label: "com.rune.latest", qos: .userInitiated, attributes: .concurrent)

    public init(
        waker: (@Sendable () -> Void)? = nil,
        debounceSeconds: TimeInterval = 0
    ) {
        self.waker = waker
        self.debounceSeconds = max(0, debounceSeconds)
    }

    deinit {
        lock.lock()
        generation &+= 1
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        latestResult = nil
        lastKey = nil
        pending = false
        waker = nil
        lock.unlock()
    }

    /// Builder-style debounce configuration (`latest.rs: debounce`).
    @discardableResult
    public func debounce(_ seconds: TimeInterval) -> Self {
        lock.lock()
        debounceSeconds = max(0, seconds)
        lock.unlock()
        return self
    }

    /// Whether a request is waiting out debounce or actively running.
    public var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    public func setWaker(_ waker: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.waker = waker
    }

    /// Submits a background task; only the newest request's result is retained.
    public func request<Input: Sendable>(
        _ input: Input,
        work: @escaping @Sendable (Input) -> T
    ) {
        requestOpt(input) { value in
            work(value)
        }
    }

    /// Submits a background task that may settle with `nil` (superseding older answers without waking).
    public func requestOpt<Input: Sendable>(
        _ input: Input,
        work: @escaping @Sendable (Input) -> T?
    ) {
        lock.lock()
        lastKey = nil
        enqueueLocked(input, work: work)
    }

    /// Submits `work` only if `key` differs from the previous request's key.
    public func requestIfChanged<Key: Hashable & Sendable>(
        key: Key,
        work: @escaping @Sendable (Key) -> T
    ) {
        lock.lock()
        let wrapped = AnyHashable(key)
        if lastKey == wrapped {
            lock.unlock()
            return
        }
        lastKey = wrapped
        enqueueLocked(key) { value in
            work(value)
        }
    }

    private func enqueueLocked<Input: Sendable>(
        _ input: Input,
        work: @escaping @Sendable (Input) -> T?
    ) {
        pendingWorkItem?.cancel()
        generation &+= 1
        let token = generation
        latestResult = nil
        pending = true
        let delay = debounceSeconds

        let item = DispatchWorkItem { [weak self] in
            let current = self?.isCurrent(token) ?? false
            guard current else { return }
            let result = work(input)
            self?.commitResult(result, for: token)
        }
        pendingWorkItem = item
        lock.unlock()

        if delay > 0 {
            queue.asyncAfter(deadline: .now() + delay, execute: item)
        } else {
            queue.async(execute: item)
        }
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == token
    }

    private func commitResult(_ result: T?, for token: UInt64) {
        lock.lock()
        let accepted = (generation == token)
        var wake: (@Sendable () -> Void)? = nil
        if accepted {
            pending = false
            pendingWorkItem = nil
            if let value = result {
                latestResult = value
                wake = waker
            } else {
                latestResult = nil
            }
        }
        lock.unlock()
        wake?()
    }

    /// Takes the latest completed result once, returning `nil` if none is ready.
    public func take() -> T? {
        lock.lock()
        defer { lock.unlock() }
        let out = latestResult
        latestResult = nil
        return out
    }

    /// Cancels any in-flight or debounced request.
    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        latestResult = nil
        lastKey = nil
        pending = false
    }
}

// MARK: - Type-Erased Handler State Container (`rune::states`)

/// Holds primary app state and optional secondary stage state (`rune::States`).
public final class StatesContainer {
    private var primary: Any
    private var secondary: Any?

    public init(primary: Any, secondary: Any? = nil) {
        self.primary = primary
        self.secondary = secondary
    }

    public func read<S>(_ type: S.Type = S.self) -> S? {
        if let s = primary as? S { return s }
        return secondary as? S
    }

    public func mutate<S>(_ type: S.Type = S.self, _ body: (inout S) -> Void) -> Bool {
        if var s = primary as? S {
            body(&s)
            primary = s
            return true
        }
        if var s = secondary as? S {
            body(&s)
            secondary = s
            return true
        }
        return false
    }
}

// MARK: - Launch & Quit Marks (`rune::marks`)

/// Records process-level startup/shutdown milestones and pre-first-frame metrics (`rune::marks`).
public final class LaunchMarks: @unchecked Sendable {
    public static let shared = LaunchMarks()

    private let lock = NSLock()
    private var recordedMarks: [(name: String, date: Date)] = []
    private var recordedMetrics: [String: UInt64] = [:]
    private var recordedNotes: [String: String] = [:]
    private var totalsDone: Bool = false

    public init() {}

    public func mark(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        if !recordedMarks.contains(where: { $0.name == name }) {
            recordedMarks.append((name, Date()))
        }
    }

    public func marks() -> [(name: String, date: Date)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedMarks
    }

    public func addMetric(_ name: String, amount: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard !totalsDone else { return }
        recordedMetrics[name, default: 0] += amount
    }

    public func metrics() -> [(name: String, value: UInt64)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedMetrics.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    public func setNote(_ name: String, value: String) {
        lock.lock()
        defer { lock.unlock() }
        recordedNotes[name] = value
    }

    public func notes() -> [(name: String, value: String)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedNotes.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    public func finishTotals() {
        lock.lock()
        defer { lock.unlock() }
        totalsDone = true
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        recordedMarks.removeAll()
        recordedMetrics.removeAll()
        recordedNotes.removeAll()
        totalsDone = false
    }
}

// MARK: - Built-in UI Labels & Locale (`rune::labels`)

/// Built-in menu & field labels that Rune localizes via `RuneLabels` (`rune::Label`).
public enum RuneLabel: Sendable, Hashable {
    case cut
    case copy
    case paste
    case selectAll
    case undo
    case redo
    case learnSpelling
    case noGuesses
    case spellcheck
    case spellcheckLanguages
    case language(String)
    case menu(String)
    case minimize
    case close
    case about(String)
    case services
    case hide(String)
    case hideOthers
    case showAll
    case quit(String)

    public var englishDefault: String {
        switch self {
        case .cut: return "Cut"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .selectAll: return "Select All"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .learnSpelling: return "Learn Spelling"
        case .noGuesses: return "No Guesses Found"
        case .spellcheck: return "Spellcheck"
        case .spellcheckLanguages: return "Spellcheck Languages"
        case .language(let tag): return tag
        case .menu(let name): return name
        case .minimize: return "Minimize"
        case .close: return "Close"
        case .about(let app): return "About \(app)"
        case .services: return "Services"
        case .hide(let app): return "Hide \(app)"
        case .hideOthers: return "Hide Others"
        case .showAll: return "Show All"
        case .quit(let app): return "Quit \(app)"
        }
    }
}

/// Global label & locale registry (`rune::labels`).
public final class RuneLabels: @unchecked Sendable {
    public static let shared = RuneLabels()

    private let lock = NSLock()
    private var namer: (@Sendable (RuneLabel) -> String?)?
    private var currentLocale: String?
    private var rtl: Bool = false

    public init() {}

    public func setLabels(_ namer: (@Sendable (RuneLabel) -> String?)?) {
        lock.lock()
        defer { lock.unlock() }
        self.namer = namer
    }

    public func setLocale(_ tag: String?) {
        lock.lock()
        defer { lock.unlock() }
        self.currentLocale = tag
    }

    public func setDirection(isRTL: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.rtl = isRTL
    }

    public var isRTL: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rtl
    }

    public var locale: String? {
        lock.lock()
        defer { lock.unlock() }
        return currentLocale
    }

    public func label(for key: RuneLabel) -> String {
        lock.lock()
        let fn = namer
        lock.unlock()
        return fn?(key) ?? key.englishDefault
    }
}

// MARK: - Compositor Hook (`rune::compose`)

/// Unique identifier for a GPU device instance (`rune::compose::DeviceKey`).
public struct DeviceKey: Sendable, Hashable {
    public let rawValue: UInt64

    private static let lock = NSLock()
    nonisolated(unsafe) private static var nextValue: UInt64 = 1

    public static func next() -> DeviceKey {
        lock.lock()
        defer { lock.unlock() }
        let v = nextValue
        nextValue &+= 1
        return DeviceKey(rawValue: v)
    }
}

/// Frame metadata passed to a `RuneCompositor`.
public struct CompositorFrameInfo: Sendable {
    public var deviceKey: DeviceKey
    public var pixelSize: (width: Int, height: Int)
    public var dt: Double
    public var updateMilliseconds: Double
    public var srgbBlend: Bool

    public init(
        deviceKey: DeviceKey,
        pixelSize: (width: Int, height: Int),
        dt: Double,
        updateMilliseconds: Double,
        srgbBlend: Bool = false
    ) {
        self.deviceKey = deviceKey
        self.pixelSize = pixelSize
        self.dt = dt
        self.updateMilliseconds = updateMilliseconds
        self.srgbBlend = srgbBlend
    }
}

/// Custom compositor hook protocol (`rune::compose::Compositor`).
public protocol RuneCompositor: AnyObject {
    func render(frame: CompositorFrameInfo)
    var isAnimating: Bool { get }
    var drawsOwnContent: Bool { get }
    func summary() -> String?
}

public extension RuneCompositor {
    var isAnimating: Bool { false }
    var drawsOwnContent: Bool { true }
    func summary() -> String? { nil }
}
