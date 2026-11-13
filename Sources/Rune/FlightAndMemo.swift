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
        guard selector.hasSuffix(suffix), path.hasSuffix(suffix) else { return false }
        let scope = selector.dropLast(suffix.count)
        let above = path.dropLast(suffix.count)
        let scopeParts = scope.split(separator: "/").reversed()
        let pathKeyed = above.split(separator: "/").filter { !$0.hasPrefix("#") }.reversed()
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
        unclipped: Bool = false
    ) {
        self.sourceKey = sourceKey
        self.targetKey = targetKey
        self.source = source
        self.destination = source
        self.presented = source
        self.born = born
        self.unclipped = unclipped
        var anim = Animated<Float>(0, propClass: .opacity)
        anim.animateTo(1, anim: .spring(GrowthCaps.growthSpring), at: born)
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
        var element: Any
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var generation: UInt64 = 0

    public init() {}

    public func getOrBuild<State, Deps: Equatable>(
        id: String,
        deps: Deps,
        build: () -> El<State>
    ) -> (element: El<State>, hit: Bool) {
        let srgb = Theme.blendsSrgb()
        lock.lock()
        if let existing = entries[id],
           existing.srgbBlend == srgb,
           existing.equals(deps),
           let cached = existing.element as? El<State> {
            lock.unlock()
            return (cached, true)
        }
        lock.unlock()

        let built = build()
        lock.lock()
        entries[id] = Entry(
            deps: deps,
            equals: { other in (other as? Deps) == deps },
            srgbBlend: srgb,
            element: built
        )
        lock.unlock()
        return (built, false)
    }

    /// Drops all cached subtrees (e.g. on hot reload or theme change).
    public func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        generation &+= 1
    }

    public func invalidate(id: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: id)
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
              let deps = existing.deps as? [UInt32: UInt64],
              let cached = existing.element as? El<State> else {
            return nil
        }
        for (cellId, recordedVer) in deps {
            if TrackedIDGenerator.version(for: cellId) != recordedVer {
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
    cache: MemoCache = .shared,
    build: () -> El<State>
) -> El<State> {
    cache.getOrBuild(id: id, deps: deps, build: build).element
}

// MARK: - Tracked State & Region Memoization (`rune::tracked`)

private enum TrackedRecorder {
    static let lock = NSLock()
    nonisolated(unsafe) static var stack: [[UInt32: UInt64]] = []
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

            TrackedRecorder.lock.lock()
            if !TrackedRecorder.stack.isEmpty {
                TrackedRecorder.stack[TrackedRecorder.stack.count - 1][id] = ver
            }
            TrackedRecorder.lock.unlock()
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
    cache: MemoCache = .shared,
    build: () -> El<State>
) -> El<State> {
    if let cached: El<State> = cache.getRegionIfValid(id: id) {
        return cached
    }

    TrackedRecorder.lock.lock()
    TrackedRecorder.stack.append([:])
    TrackedRecorder.lock.unlock()

    let built = build()

    TrackedRecorder.lock.lock()
    let deps = TrackedRecorder.stack.popLast() ?? [:]
    TrackedRecorder.lock.unlock()

    return memo("region:\(id)", deps: deps, cache: cache) { built }
}

// MARK: - Latest-Wins Background Requests (`rune::latest`)

/// A latest-wins background request with optional debounce and stale-answer rejection (`rune::Latest<T>`).
public final class Latest<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pendingWorkItem: DispatchWorkItem?
    private var latestResult: T?
    private var lastKey: AnyHashable?
    private var waker: (@Sendable () -> Void)?
    public var debounceSeconds: TimeInterval

    private let queue = DispatchQueue(label: "com.rune.latest", qos: .userInitiated, attributes: .concurrent)

    public init(debounceSeconds: TimeInterval = 0) {
        self.debounceSeconds = max(0, debounceSeconds)
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
        lock.lock()
        lastKey = nil
        pendingWorkItem?.cancel()
        generation &+= 1
        let token = generation
        let delay = debounceSeconds
        let currentWaker = waker

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isCurrent(token) else { return }
            let result = work(input)
            self.commitResult(result, for: token, waker: currentWaker)
        }
        pendingWorkItem = item
        lock.unlock()

        if delay > 0 {
            queue.asyncAfter(deadline: .now() + delay, execute: item)
        } else {
            queue.async(execute: item)
        }
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
        pendingWorkItem?.cancel()
        generation &+= 1
        let token = generation
        let delay = debounceSeconds
        let currentWaker = waker

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isCurrent(token) else { return }
            let result = work(key)
            self.commitResult(result, for: token, waker: currentWaker)
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

    private func commitResult(_ result: T, for token: UInt64, waker: (@Sendable () -> Void)?) {
        lock.lock()
        let accepted = (generation == token)
        if accepted {
            latestResult = result
        }
        lock.unlock()
        if accepted {
            waker?()
        }
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
