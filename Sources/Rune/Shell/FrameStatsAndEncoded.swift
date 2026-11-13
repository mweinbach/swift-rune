import Foundation
import RuneMotion

// MARK: - Frame Outcome, Encoded & Reports (frame/encoded.rs)

/// Whether a frame actually encoded GPU/CPU draw work, had nothing dirty, or was skipped.
public enum FrameOutcome: String, Sendable, Equatable, Codable {
    case drawn
    case unchanged
    case skipped
}

/// Telemetry reported after encoding or presenting a frame (`rune::FrameEncoded`).
public struct FrameEncoded: Sendable, Equatable, Codable {
    public var at: Double
    public var outcome: FrameOutcome
    public var window: String?
    public var seq: UInt64
    public var presentsAt: Double?
    public var started: Double?
    public var refreshHz: Double?
    public var frameMs: Double
    public var updateMs: Double
    public var encodeMs: Double
    public var committed: Bool
    public var primitives: Int
    public var glyphs: Int
    public var animating: Bool
    public var compositorAnimating: Bool
    public var drawCount: Int
    public var compositorSummary: String?

    public init(
        outcome: FrameOutcome = .drawn,
        frameMs: Double = 0.0,
        updateMs: Double = 0.0,
        encodeMs: Double = 0.0,
        committed: Bool = false,
        primitives: Int = 0,
        glyphs: Int = 0,
        animating: Bool = false,
        compositorAnimating: Bool = false,
        drawCount: Int = 0,
        compositorSummary: String? = nil,
        at: Double = 0.0,
        window: String? = nil,
        seq: UInt64 = 0,
        presentsAt: Double? = nil,
        started: Double? = nil,
        refreshHz: Double? = nil
    ) {
        self.at = at
        self.outcome = outcome
        self.window = window
        self.seq = seq
        self.presentsAt = presentsAt
        self.started = started
        self.refreshHz = refreshHz
        self.frameMs = frameMs
        self.updateMs = updateMs
        self.encodeMs = encodeMs
        self.committed = committed
        self.primitives = primitives
        self.glyphs = glyphs
        self.animating = animating
        self.compositorAnimating = compositorAnimating
        self.drawCount = drawCount
        self.compositorSummary = compositorSummary
    }
}

/// Manages `onFrameEncoded` and `onFrameDrawn` reporting across frames (`frame::FrameReports`).
public final class FrameReports<State> {
    public var onFrameEncoded: ((FrameEncoded) -> Void)?
    public var onFrameDrawn: ((inout State, FrameEncoded, inout Tx) -> Void)?
    public var onInspectDrawn: ((Runtime<State>) -> Void)?
    /// Minimum interval between `onFrameDrawn` state updates (upstream throttles state callbacks so
    /// high-refresh loops aren't self-invalidated at 120Hz). Set to `0` for immediate delivery.
    public var drawnInterval: Double
    public var windowKey: String?
    public private(set) var droppedCount: Int = 0
    public private(set) var reportCount: UInt64 = 0
    public private(set) var refreshHz: Double?

    private var pendingDrawn: FrameEncoded?
    private var lastDrawnAt: Double = -.infinity

    public init(
        onFrameEncoded: ((FrameEncoded) -> Void)? = nil,
        onFrameDrawn: ((inout State, FrameEncoded, inout Tx) -> Void)? = nil,
        onInspectDrawn: ((Runtime<State>) -> Void)? = nil,
        drawnInterval: Double = 0.1,
        windowKey: String? = nil
    ) {
        self.onFrameEncoded = onFrameEncoded
        self.onFrameDrawn = onFrameDrawn
        self.onInspectDrawn = onInspectDrawn
        self.drawnInterval = max(0.0, drawnInterval)
        self.windowKey = windowKey
    }

    /// Attaches an unthrottled runtime inspection hook (`FrameReports::inspecting`).
    public func inspecting(_ drawn: ((Runtime<State>) -> Void)?) -> FrameReports<State> {
        self.onInspectDrawn = drawn
        return self
    }

    /// Whether anyone reads the reports, so a host asks only for what they need (`FrameReports::wanted`).
    public var wanted: Bool { onFrameEncoded != nil }

    /// Captures a timestamp only when an `onFrameEncoded` hook is present (`FrameReports::stamp`).
    public func stamp() -> Double? {
        onFrameEncoded != nil ? ProcessInfo.processInfo.systemUptime : nil
    }

    /// Sets the display refresh carried on subsequent reports until changed (`FrameReports::set_refresh`).
    public func setRefresh(_ hz: Double?) {
        guard onFrameEncoded != nil else { return }
        refreshHz = hz.flatMap { ($0.isFinite && $0 > 0.0) ? $0 : nil }
    }

    /// Records a `.drawn` frame encoded at `at` (from `stamp()`), starting at `started` (`FrameReports::drawn`).
    public func drawn(at: Double?, presentsAt: Double? = nil, started: Double, updateMs: Double) {
        guard let at, onFrameEncoded != nil else { return }
        let clampedUpdate = max(0.0, updateMs)
        let encodeMs = max(0.0, max(0.0, at - started) * 1000.0 - clampedUpdate)
        record(
            FrameEncoded(
                outcome: .drawn,
                frameMs: clampedUpdate + encodeMs,
                updateMs: clampedUpdate,
                encodeMs: encodeMs,
                at: at,
                window: windowKey,
                seq: reportCount,
                presentsAt: presentsAt,
                started: started,
                refreshHz: refreshHz
            )
        )
    }

    /// Records an `.unchanged` frame (`FrameReports::unchanged`).
    public func unchanged(presentsAt: Double? = nil) {
        guard onFrameEncoded != nil else { return }
        record(
            FrameEncoded(
                outcome: .unchanged,
                at: ProcessInfo.processInfo.systemUptime,
                window: windowKey,
                seq: reportCount,
                presentsAt: presentsAt,
                refreshHz: refreshHz
            )
        )
    }

    /// Records a `.skipped` frame (`FrameReports::skipped`).
    public func skipped() {
        guard onFrameEncoded != nil else { return }
        record(
            FrameEncoded(
                outcome: .skipped,
                at: ProcessInfo.processInfo.systemUptime,
                window: windowKey,
                seq: reportCount,
                refreshHz: refreshHz
            )
        )
    }

    /// Invokes `App::on_frame_drawn` unthrottled runtime inspector after a `Drawn` frame (`FrameReports::inspect`).
    public func inspect(_ runtime: Runtime<State>) {
        onInspectDrawn?(runtime)
    }

    /// Emits `onFrameEncoded` immediately (when set) and queues a drawn report if `outcome == .drawn`.
    public func record(_ encoded: FrameEncoded) {
        var entry = encoded
        if entry.seq == 0 {
            entry.seq = reportCount
        }
        if entry.window == nil {
            entry.window = windowKey
        }
        if entry.refreshHz == nil {
            entry.refreshHz = refreshHz
        }
        reportCount &+= 1
        onFrameEncoded?(entry)
        guard onFrameDrawn != nil, entry.outcome == .drawn else { return }
        if pendingDrawn != nil {
            droppedCount += 1
        }
        pendingDrawn = entry
    }

    /// Flushes a queued `onFrameDrawn` callback if `drawnInterval` has elapsed (or `force` is true).
    /// Returns `true` if a callback ran.
    @discardableResult
    public func flush(
        state: inout State,
        tx: inout Tx,
        at now: Double,
        force: Bool = false
    ) -> Bool {
        guard let hook = onFrameDrawn, let report = pendingDrawn else { return false }
        if !force, (now - lastDrawnAt) < drawnInterval {
            return false
        }
        pendingDrawn = nil
        lastDrawnAt = now
        hook(&state, report, &tx)
        return true
    }

    public func hasPendingDrawn(at now: Double) -> Bool {
        guard pendingDrawn != nil, onFrameDrawn != nil else { return false }
        return (now - lastDrawnAt) >= drawnInterval
    }
}

// MARK: - Surface Stats & Meter (frame/surface_stats.rs)

/// Cumulative frame/surface counters (`rune::frame::surface_stats::SurfaceCounts`).
public struct SurfaceCounts: Sendable, Equatable, Codable {
    public var redraws: UInt64
    public var unpaced: UInt64
    public var presents: UInt64
    public var skipped: UInt64
    public var occluded: UInt64
    public var timeouts: UInt64
    public var outdated: UInt64
    public var turns: UInt64
    public var wakes: UInt64

    public init(
        redraws: UInt64 = 0,
        unpaced: UInt64 = 0,
        presents: UInt64 = 0,
        skipped: UInt64 = 0,
        occluded: UInt64 = 0,
        timeouts: UInt64 = 0,
        outdated: UInt64 = 0,
        turns: UInt64 = 0,
        wakes: UInt64 = 0
    ) {
        self.redraws = redraws
        self.unpaced = unpaced
        self.presents = presents
        self.skipped = skipped
        self.occluded = occluded
        self.timeouts = timeouts
        self.outdated = outdated
        self.turns = turns
        self.wakes = wakes
    }

    public static func - (lhs: SurfaceCounts, rhs: SurfaceCounts) -> SurfaceCounts {
        SurfaceCounts(
            redraws: lhs.redraws &- rhs.redraws,
            unpaced: lhs.unpaced &- rhs.unpaced,
            presents: lhs.presents &- rhs.presents,
            skipped: lhs.skipped &- rhs.skipped,
            occluded: lhs.occluded &- rhs.occluded,
            timeouts: lhs.timeouts &- rhs.timeouts,
            outdated: lhs.outdated &- rhs.outdated,
            turns: lhs.turns &- rhs.turns,
            wakes: lhs.wakes &- rhs.wakes
        )
    }

    public var failedCount: UInt64 {
        occluded &+ timeouts &+ outdated
    }

    public func scaledPerSecond(elapsed: Double) -> SurfaceCounts {
        guard elapsed > 0 else { return SurfaceCounts() }
        func scale(_ v: UInt64) -> UInt64 {
            UInt64((Double(v) / elapsed).rounded())
        }
        return SurfaceCounts(
            redraws: scale(redraws),
            unpaced: scale(unpaced),
            presents: scale(presents),
            skipped: scale(skipped),
            occluded: scale(occluded),
            timeouts: scale(timeouts),
            outdated: scale(outdated),
            turns: scale(turns),
            wakes: scale(wakes)
        )
    }
}

/// Active surface pacing state (`rune::frame::surface_stats::Pacing`).
public enum Pacing: Sendable, Equatable, Codable {
    case idle
    case paced
    case unpaced
    case failed(Int32)

    public var label: String {
        switch self {
        case .idle: return "idle"
        case .paced: return "display link"
        case .unpaced: return "unpaced"
        case .failed(let code): return "display link failed (\(code))"
        }
    }
}

/// Reason a surface presentation missed its target.
public enum SurfaceMissed: Sendable, Equatable {
    case occluded
    case timeout
    case outdated
    case unconfigured
}

/// Snapshot published to `App.devStats` (`rune::SurfaceStats`).
public struct SurfaceStats: Sendable, Equatable, Codable {
    public var name: String
    public var totals: SurfaceCounts
    public var rates: SurfaceCounts
    public var pacing: Pacing
    public var spinWarning: String?

    public init(
        name: String = "",
        totals: SurfaceCounts = SurfaceCounts(),
        rates: SurfaceCounts = SurfaceCounts(),
        pacing: Pacing = .idle,
        spinWarning: String? = nil
    ) {
        self.name = name
        self.totals = totals
        self.rates = rates
        self.pacing = pacing
        self.spinWarning = spinWarning
    }

    public func summary() -> String {
        var parts = [
            "\(name)",
            "\(rates.redraws) redraws/s (\(rates.unpaced) unpaced)",
            "\(rates.presents) presents/s",
        ]
        if rates.failedCount > 0 {
            parts.append("\(rates.failedCount) failed acquires/s (occluded \(rates.occluded), timeouts \(rates.timeouts), outdated \(rates.outdated))")
        }
        parts.append(pacing.label)
        return parts.joined(separator: ", ")
    }
}

/// Tracks surface redraw cadence, rolled 1-second rates, and spin warnings (`frame::surface_stats::SurfaceMeter`).
public final class SurfaceMeter: @unchecked Sendable {
    public static let spinRateThreshold: UInt64 = 400
    public static let spinSecondsThreshold: UInt32 = 2

    private enum SpinState {
        case calm
        case hot(seconds: UInt32)
        case warned
    }

    private let lock = NSLock()
    private let name: String
    private let useWallClock: Bool
    private var totals = SurfaceCounts()
    private var base = SurfaceCounts()
    private var rates = SurfaceCounts()
    private var started: Double
    private var pacing: Pacing = .idle
    private var waited: Bool = false
    private var spin: SpinState = .calm
    private var spinWarning: String?

    public init(name: String, now: Double? = nil) {
        self.name = name
        self.useWallClock = (now == nil)
        self.started = now ?? ProcessInfo.processInfo.systemUptime
    }

    public func currentStats() -> SurfaceStats {
        lock.lock()
        defer { lock.unlock() }
        return SurfaceStats(
            name: name,
            totals: totals,
            rates: rates,
            pacing: pacing,
            spinWarning: spinWarning
        )
    }

    public func totalsSnapshot() -> SurfaceCounts {
        lock.lock()
        defer { lock.unlock() }
        return totals
    }

    @discardableResult
    public func redraw(paced: Bool, now: Double? = nil) -> String? {
        lock.lock()
        defer { lock.unlock() }
        totals.redraws += 1
        if !paced && !waited {
            totals.unpaced += 1
        }
        waited = false
        return autoTickLocked(now: now)
    }

    public func noteWaited() {
        lock.lock()
        defer { lock.unlock() }
        waited = true
    }

    @discardableResult
    public func presented(now: Double? = nil) -> String? {
        lock.lock()
        defer { lock.unlock() }
        totals.presents += 1
        return autoTickLocked(now: now)
    }

    @discardableResult
    public func skipped(now: Double? = nil) -> String? {
        lock.lock()
        defer { lock.unlock() }
        totals.skipped += 1
        return autoTickLocked(now: now)
    }

    @discardableResult
    public func failed(_ missed: SurfaceMissed, now: Double? = nil) -> String? {
        lock.lock()
        defer { lock.unlock() }
        switch missed {
        case .occluded: totals.occluded += 1
        case .timeout: totals.timeouts += 1
        case .outdated, .unconfigured: totals.outdated += 1
        }
        return autoTickLocked(now: now)
    }

    @discardableResult
    public func turn(woke: Bool, waited: Bool, now: Double? = nil) -> String? {
        lock.lock()
        defer { lock.unlock() }
        totals.turns += 1
        if woke { totals.wakes += 1 }
        self.waited = self.waited || waited
        return autoTickLocked(now: now)
    }

    public func setPacing(_ pacing: Pacing) {
        lock.lock()
        defer { lock.unlock() }
        self.pacing = pacing
    }

    @discardableResult
    public func tick(now: Double = ProcessInfo.processInfo.systemUptime) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return rollIfNeededLocked(now: now)
    }

    private func autoTickLocked(now: Double?) -> String? {
        if let explicit = now {
            return rollIfNeededLocked(now: explicit)
        }
        if useWallClock {
            return rollIfNeededLocked(now: ProcessInfo.processInfo.systemUptime)
        }
        return nil
    }

    private func rollIfNeededLocked(now: Double) -> String? {
        let elapsed = max(0.0, now - started)
        guard elapsed >= 1.0 else { return nil }
        let delta = totals - base
        rates = delta.scaledPerSecond(elapsed: elapsed)
        base = totals
        started = now

        let spinning = rates.failedCount > Self.spinRateThreshold || rates.unpaced > Self.spinRateThreshold
        switch spin {
        case .warned:
            return nil
        case .calm:
            if spinning {
                spin = .hot(seconds: 1)
            }
            return nil
        case .hot(let prev):
            let next = spinning ? prev + 1 : 0
            if next >= Self.spinSecondsThreshold {
                spin = .warned
                let stats = SurfaceStats(name: name, totals: totals, rates: rates, pacing: pacing, spinWarning: nil)
                let msg = "rune: surface has spun for \(next) s, a bug in Rune: \(stats.summary())"
                spinWarning = msg
                return msg
            }
            spin = next == 0 ? .calm : .hot(seconds: next)
            return nil
        }
    }
}

// MARK: - Frame Clock (frame/clock.rs)

/// How much a frame step advances already-running motion (`catchUp`) vs newly started motion (`dt`).
public struct FrameClockStep: Sendable, Equatable {
    public var catchUp: Double
    public var dt: Double

    public var total: Double { catchUp + dt }

    public init(catchUp: Double, dt: Double) {
        self.catchUp = catchUp
        self.dt = dt
    }

    public static func split(gap: Double, running: Bool) -> FrameClockStep {
        let clamped = max(0.0, min(gap, FrameClock.maxGap))
        if !running {
            return FrameClockStep(catchUp: 0.0, dt: FrameClock.resumeStep)
        }
        let step = min(clamped, FrameClock.resumeStep)
        return FrameClockStep(catchUp: max(0.0, clamped - step), dt: step)
    }
}

/// Cadence-preserving frame clock separating running motion catch-up from fresh motion startup
/// (`rune::frame::clock::FrameClock`).
public final class FrameClock {
    public static let resumeStep: Double = 1.0 / 120.0
    public static let maxGap: Double = 0.25

    private enum Phase {
        case idle(last: Double)
        case stepped(last: Double, startedAt: Double, hadRunning: Bool)
        case presented(last: Double)
    }

    private var phase: Phase
    public private(set) var lastStep: FrameClockStep = FrameClockStep(catchUp: 0.0, dt: 0.0)

    public init(start: Double = 0.0) {
        self.phase = .idle(last: start)
    }

    public var lastTarget: Double {
        switch phase {
        case .idle(let last), .stepped(let last, _, _), .presented(let last):
            return last
        }
    }

    /// Clamps the clock ahead to at least `at` when a display-link target runs ahead.
    public func hold(at target: Double) {
        switch phase {
        case .idle(let last):
            phase = .idle(last: max(last, target))
        case .stepped(let last, let startedAt, let hadRunning):
            phase = .stepped(last: max(last, target), startedAt: startedAt, hadRunning: hadRunning)
        case .presented(let last):
            phase = .presented(last: max(last, target))
        }
    }

    /// Computes the `(catchUp, dt)` step for a frame at `at` given whether motion is `running`.
    public func frameStep(at target: Double, running: Bool) -> FrameClockStep {
        let prev = lastTarget
        let gap = max(0.0, target - prev)
        let step = FrameClockStep.split(gap: gap, running: running)
        lastStep = step
        phase = .stepped(last: max(prev, target), startedAt: max(prev, target), hadRunning: running)
        return step
    }

    /// Notes when the last stepped frame actually finished presenting (`done`), delaying overrun on
    /// newly started animations while keeping already-running animations on wall time.
    @discardableResult
    public func presented(done: Double) -> Double {
        switch phase {
        case .stepped(let last, _, _):
            let late = min(Self.maxGap, max(0.0, done - last))
            phase = .presented(last: last)
            return late
        case .idle(let last), .presented(let last):
            phase = .presented(last: last)
            return 0.0
        }
    }
}

// MARK: - Opt-in Headless Frame Phase Profiling (`crates/rune/src/frame/profile.rs`)

/// Number of timed frame phases (`rune::frame::profile::PHASES`).
public let FRAME_PHASES: Int = 6

/// Named frame phase slots in `takeFramePhases()`.
public enum FramePhase: Int, CaseIterable, Sendable {
    case view = 0
    case commit = 1
    case layout = 2
    case text = 3
    case paint = 4
    case apply = 5
}

private enum FramePhaseStorage {
    private static let key = "rune.frameProfile.phases"

    static func record(_ phase: FramePhase, wallMs: Double, cpuMs: Double) {
        var row = (Thread.current.threadDictionary[key] as? [Double])
            ?? Array(repeating: 0.0, count: 2 * FRAME_PHASES)
        row[phase.rawValue] += wallMs
        row[phase.rawValue + FRAME_PHASES] += cpuMs
        Thread.current.threadDictionary[key] = row
        if InteractionGate.isOn {
            InteractionTracker.recordActiveThreadPhase(phase.rawValue, ms: wallMs)
        }
    }

    static func take() -> [Double] {
        let current = (Thread.current.threadDictionary[key] as? [Double])
            ?? Array(repeating: 0.0, count: 2 * FRAME_PHASES)
        Thread.current.threadDictionary[key] = Array(repeating: 0.0, count: 2 * FRAME_PHASES)
        return current
    }
}

/// CPU time consumed by the calling thread in milliseconds (`rune::thread_cpu_ms`).
public func threadCpuMs() -> Double {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000.0
    #elseif os(Linux)
    var ts = timespec()
    guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) == 0 else { return 0.0 }
    return Double(ts.tv_sec) * 1000.0 + Double(ts.tv_nsec) / 1_000_000.0
    #else
    return 0.0
    #endif
}

/// Returns and clears the current thread's `[wall(6), cpu(6)]` phase timings (`rune::take_frame_phases`).
public func takeFramePhases() -> [Double] {
    FramePhaseStorage.take()
}

/// Accumulates wall + CPU duration into a `FramePhase` slot on the current thread.
public func recordFramePhase(_ phase: FramePhase, wallMs: Double, cpuMs: Double = 0.0) {
    FramePhaseStorage.record(phase, wallMs: wallMs, cpuMs: cpuMs)
}

/// Measures wall + thread CPU time of `body` and accumulates it into `phase`.
@inline(__always)
public func measureFramePhase<T>(_ phase: FramePhase, _ body: () throws -> T) rethrows -> T {
    let wallStart = DispatchTime.now().uptimeNanoseconds
    let cpuStart = threadCpuMs()
    defer {
        let wallEnd = DispatchTime.now().uptimeNanoseconds
        let wallMs = Double(wallEnd &- wallStart) / 1_000_000.0
        let cpuMs = max(0.0, threadCpuMs() - cpuStart)
        FramePhaseStorage.record(phase, wallMs: wallMs, cpuMs: cpuMs)
    }
    return try body()
}

// MARK: - Window / Shell / Options Types (window/spec.rs, window/titlebar.rs, lib.rs)

/// Glyph rasterization smoothing preference (`rune::FontSmoothing`).
public enum FontSmoothing: String, Sendable, Equatable, Codable {
    case on
    case off
    case directWrite
    case windfoil
    case windfoilChromium
    case slug
    case hintedGpu
    case hinted
    case windfoilRgb
    case clearType
    case systemDefault

    /// Resolved effective setting (`true` on macOS by default, `false` elsewhere).
    public var isEnabled: Bool {
        switch self {
        case .on, .windfoil: return true
        case .off, .directWrite, .windfoilChromium, .slug, .hintedGpu, .hinted, .windfoilRgb, .clearType: return false
        case .systemDefault:
            #if os(macOS)
            return true
            #else
            return false
            #endif
        }
    }
}

/// GPU backend selection (`rune::GpuBackend`).
public enum GpuBackend: String, Sendable, Equatable, Codable {
    case auto
    case metal
    case vulkan
    case dx12
    case gl
    case webGpu
    case software
}

/// Window frame chrome style & geometry (`rune::Chrome`).
public struct Chrome: Sendable, Equatable, Codable {
    public static let trafficLightSize: Float = 14.0
    public static let trafficPitch: Float = 23.0

    public var fullSizeContent: Bool
    public var trafficLightsX: Float?
    public var trafficLightsY: Float?
    public var dragRegions: Bool
    public var borderless: Bool

    public static let standard = Chrome(fullSizeContent: false, trafficLights: nil, dragRegions: false, borderless: false)
    public static let borderless = Chrome(fullSizeContent: false, trafficLights: nil, dragRegions: false, borderless: true)
    public static let titlebarIntegrated = Chrome(fullSizeContent: true, trafficLights: nil, dragRegions: true, borderless: false)
    public static let `default` = Chrome(fullSizeContent: true, trafficLights: nil, dragRegions: false, borderless: false)

    public var trafficLights: (Float, Float)? {
        get {
            guard let x = trafficLightsX, let y = trafficLightsY else { return nil }
            return (x, y)
        }
        set {
            trafficLightsX = newValue?.0
            trafficLightsY = newValue?.1
        }
    }

    public init(
        fullSizeContent: Bool = true,
        trafficLights: (Float, Float)? = nil,
        dragRegions: Bool = false,
        borderless: Bool = false
    ) {
        self.fullSizeContent = fullSizeContent
        self.trafficLightsX = trafficLights?.0
        self.trafficLightsY = trafficLights?.1
        self.dragRegions = dragRegions
        self.borderless = borderless
    }

    /// Headless macOS 26 traffic-light rects `[x, y, w, h]` in points.
    public func trafficLightRects() -> [[Float]]? {
        if !fullSizeContent && trafficLights == nil {
            return nil
        }
        let (x, y) = trafficLights ?? (7.0, 6.0)
        return (0..<3).map { i in
            [x + Float(i) * Self.trafficPitch, y, Self.trafficLightSize, Self.trafficLightSize]
        }
    }

    /// Trailing edge of the zoom button in headless runs.
    public func titlebarInset() -> Float {
        guard let rects = trafficLightRects(), rects.count >= 3 else { return 0.0 }
        return rects[2][0] + rects[2][2]
    }

    /// Whether drag regions govern dragging on macOS (`window::uses_drag_regions`).
    public static func usesDragRegions(chrome: Chrome, borderless: Bool, isPanel: Bool) -> Bool {
        chrome.dragRegions && (borderless || chrome.fullSizeContent) && !isPanel
    }
}

/// Integrated custom titlebar geometry (`rune::Titlebar`).
public struct Titlebar: Sendable, Equatable, Codable {
    public static let captionButtonWidth: Float = 46.0

    public var height: Float
    public var insetLeading: Float
    public var insetTrailing: Float
    public var showsTitle: Bool
    public var trafficLightsX: Float?
    public var trafficLightsY: Float?

    public var trafficLightsOrigin: (Float, Float)? {
        get {
            guard let x = trafficLightsX, let y = trafficLightsY else { return nil }
            return (x, y)
        }
        set {
            trafficLightsX = newValue?.0
            trafficLightsY = newValue?.1
        }
    }

    public init(
        height: Float = 38.0,
        insetLeading: Float = 72.0,
        insetTrailing: Float = 0.0,
        showsTitle: Bool = false
    ) {
        self.height = max(0.0, height)
        self.insetLeading = max(0.0, insetLeading)
        self.insetTrailing = max(0.0, insetTrailing)
        self.showsTitle = showsTitle
        self.trafficLightsX = nil
        self.trafficLightsY = nil
    }

    public init(height: Float, trafficLights: (Float, Float)?) {
        self.height = max(0.0, height)
        self.insetLeading = 72.0
        self.insetTrailing = 0.0
        self.showsTitle = false
        self.trafficLightsX = trafficLights?.0
        self.trafficLightsY = trafficLights?.1
    }

    public func trafficLights(_ x: Float, _ y: Float) -> Titlebar {
        Titlebar(height: height, trafficLights: (x, y))
    }

    /// macOS chrome derived from this titlebar over base `chrome`.
    public func macChrome(_ chrome: Chrome) -> Chrome {
        let y = max(0.0, (height - Chrome.trafficLightSize) / 2.0).rounded()
        let lights = trafficLightsOrigin ?? chrome.trafficLights ?? (16.0, y)
        return Chrome(fullSizeContent: true, trafficLights: lights, dragRegions: true)
    }
}

/// Window chrome insets reported in `Cx` (`rune::ChromeInsets`).
public struct ChromeInsets: Sendable, Equatable, Codable {
    public var leading: Float
    public var trailing: Float
    public var top: Float

    public var height: Float {
        get { top }
        set { top = max(0.0, newValue) }
    }

    public init(leading: Float = 0.0, trailing: Float = 0.0, top: Float = 0.0) {
        self.leading = max(0.0, leading)
        self.trailing = max(0.0, trailing)
        self.top = max(0.0, top)
    }

    public init(leading: Float = 0.0, trailing: Float = 0.0, height: Float) {
        self.leading = max(0.0, leading)
        self.trailing = max(0.0, trailing)
        self.top = max(0.0, height)
    }

    public static let zero = ChromeInsets()

    public func zoomed(_ k: Float) -> ChromeInsets {
        ChromeInsets(leading: leading / k, trailing: trailing / k, height: top / k)
    }

    public func bits() -> [UInt32] {
        [leading.bitPattern, trailing.bitPattern, top.bitPattern]
    }
}

/// Preferred target display (`rune::window::Display` & `rune::overlay::Display`).
public enum DisplayTarget: Sendable, Equatable, Codable {
    case primary
    case index(Int)
    case named(String)
    case underPointer
    case id(RuneDisplayId)
    case native(NativeDisplayId)
}

/// Runtime launch options (`rune::RunOptions`).
public struct RunOptions: Sendable, Equatable {
    public var display: DisplayTarget?
    public var arguments: [String]?
    /// macOS: no Dock icon/default menu and no activation at launch. Ignored elsewhere.
    public var accessory: Bool

    public init(display: DisplayTarget? = nil, arguments: [String]? = nil, accessory: Bool = false) {
        self.display = display
        self.arguments = arguments
        self.accessory = accessory
    }
}

/// Initial window presentation mode (`rune::windows::OpenAs`).
public struct OpenAs: Sendable, Equatable, Codable {
    public var isMaximized: Bool
    public var isFullScreen: Bool

    public static let normal = OpenAs(isMaximized: false, isFullScreen: false)
    public static let maximized = OpenAs(isMaximized: true, isFullScreen: false)
    public static func fullScreen(maximized: Bool = false) -> OpenAs {
        OpenAs(isMaximized: maximized, isFullScreen: true)
    }

    public var maximizes: Bool { isMaximized }
    public var fullScreens: Bool { isFullScreen }

    public init(isMaximized: Bool = false, isFullScreen: Bool = false) {
        self.isMaximized = isMaximized
        self.isFullScreen = isFullScreen
    }

    public func maximized(_ on: Bool) -> OpenAs {
        OpenAs(isMaximized: on, isFullScreen: isFullScreen)
    }

    public func fullScreen(_ on: Bool) -> OpenAs {
        OpenAs(isMaximized: isMaximized, isFullScreen: on)
    }
}

/// Cross-platform window configuration (`rune::WindowOptions`).
public struct WindowOptions: Sendable, Equatable {
    public static let defaultMinSize = Vec2(420, 400)
    public static let `default` = WindowOptions()

    public var minSize: Vec2?
    public var maxSize: Vec2?
    public var resizable: Bool
    public var closable: Bool
    public var minimizable: Bool
    public var transparent: Bool
    public var hasShadow: Bool
    public var alwaysOnTop: Bool
    public var borderless: Bool
    public var clickThrough: Bool
    public var visible: Bool
    public var position: (Int32, Int32)?
    public var physicalSize: (UInt32, UInt32)?

    public init(
        minSize: Vec2? = nil,
        maxSize: Vec2? = nil,
        resizable: Bool = true,
        closable: Bool = true,
        minimizable: Bool = true,
        transparent: Bool = false,
        hasShadow: Bool = true,
        alwaysOnTop: Bool = false,
        borderless: Bool = false,
        clickThrough: Bool = false,
        visible: Bool = true,
        position: (Int32, Int32)? = nil,
        physicalSize: (UInt32, UInt32)? = nil
    ) {
        self.minSize = minSize
        self.maxSize = maxSize
        self.resizable = resizable
        self.closable = closable
        self.minimizable = minimizable
        self.transparent = transparent
        self.hasShadow = hasShadow
        self.alwaysOnTop = alwaysOnTop
        self.borderless = borderless
        self.clickThrough = clickThrough
        self.visible = visible
        self.position = position
        self.physicalSize = physicalSize
    }

    public static func == (lhs: WindowOptions, rhs: WindowOptions) -> Bool {
        lhs.minSize == rhs.minSize &&
            lhs.maxSize == rhs.maxSize &&
            lhs.resizable == rhs.resizable &&
            lhs.closable == rhs.closable &&
            lhs.minimizable == rhs.minimizable &&
            lhs.transparent == rhs.transparent &&
            lhs.hasShadow == rhs.hasShadow &&
            lhs.alwaysOnTop == rhs.alwaysOnTop &&
            lhs.borderless == rhs.borderless &&
            lhs.clickThrough == rhs.clickThrough &&
            lhs.visible == rhs.visible &&
            lhs.position?.0 == rhs.position?.0 &&
            lhs.position?.1 == rhs.position?.1 &&
            lhs.physicalSize?.0 == rhs.physicalSize?.0 &&
            lhs.physicalSize?.1 == rhs.physicalSize?.1
    }

    /// A hidden, retained launcher (`WindowOptions::launcher_panel`).
    public static func launcherPanel() -> ConfiguredWindowOptions {
        var native = MacWindowOptions().nonactivatingPanel(true)
        native.launcher = true
        let opts = WindowOptions(
            minSize: Vec2(0.0, 0.0),
            resizable: false,
            transparent: true,
            borderless: true,
            visible: false
        )
        return opts.macos(native)
    }

    /// Attach AppKit-specific window properties.
    public func macos(_ native: MacWindowOptions) -> ConfiguredWindowOptions {
        ConfiguredWindowOptions(options: self, native: native)
    }

    /// One transparent, borderless, topmost, click-through overlay covering `display`.
    public static func overlay(display: DisplayInfo) -> WindowOptions {
        WindowOptions(
            minSize: Vec2(0.0, 0.0),
            maxSize: nil,
            resizable: true,
            transparent: true,
            alwaysOnTop: true,
            borderless: true,
            clickThrough: true,
            visible: true,
            position: display.position,
            physicalSize: display.size
        )
    }

    /// The window's minimum and maximum content sizes, with `appMin` as fallback minimum.
    public func sizeLimits(appMin: (Float, Float)?) -> ((Float, Float), (Float, Float)?) {
        let minVec = minSize ?? appMin.map { Vec2($0.0, $0.1) } ?? Self.defaultMinSize
        var minVal = (minVec.x, minVec.y)
        let maxTuple = maxSize.map { ($0.x, $0.y) }
        if let maxVal = maxTuple {
            minVal = (min(minVal.0, maxVal.0), min(minVal.1, maxVal.1))
        }
        return (minVal, maxTuple)
    }

    /// The minimum a window that fits its content height opens with: content sets height.
    public func fitMinSize(appMin: (Float, Float)?) -> (Float, Float)? {
        if appMin == nil && minSize == nil {
            return (Self.defaultMinSize.x, 0.0)
        }
        return appMin
    }

    /// Computes resolved window attributes (`WindowOptions::attributes`).
    public func attributes(
        title: String,
        size: (Float, Float),
        appMin: (Float, Float)?,
        visible: Bool
    ) -> WindowAttributesSnapshot {
        let (minLim, maxTuple) = sizeLimits(appMin: appMin)
        return WindowAttributesSnapshot(
            title: title,
            innerSize: size,
            minInnerSize: minLim,
            maxInnerSize: maxTuple,
            position: position,
            physicalSize: physicalSize,
            resizable: resizable,
            maximizeButtonEnabled: resizable,
            transparent: transparent,
            decorations: !borderless,
            visible: visible,
            alwaysOnTop: alwaysOnTop
        )
    }
}

/// macOS-specific window styling options (`rune::MacWindowOptions`).
public struct MacWindowOptions: Sendable, Equatable, Codable {
    public var fullSizeContentView: Bool
    public var titlebarAppearsTransparent: Bool
    public var hidesTitle: Bool
    public var movableByWindowBackground: Bool
    public var floatingLevel: Bool
    public var shadow: Bool?
    public var level: Int?
    public var collectionBehavior: UInt?
    public var excludeFromCapture: Bool?
    public var nonactivatingPanel: Bool
    public var launcher: Bool
    public var cornerRadius: Float?
    public var isCornerCurveCircular: Bool

    public init(
        fullSizeContentView: Bool = false,
        titlebarAppearsTransparent: Bool = false,
        hidesTitle: Bool = false,
        movableByWindowBackground: Bool = false,
        floatingLevel: Bool = false,
        shadow: Bool? = nil,
        level: Int? = nil,
        collectionBehavior: UInt? = nil,
        excludeFromCapture: Bool? = nil,
        nonactivatingPanel: Bool = false,
        launcher: Bool = false,
        cornerRadius: Float? = nil,
        isCornerCurveCircular: Bool = false
    ) {
        self.fullSizeContentView = fullSizeContentView
        self.titlebarAppearsTransparent = titlebarAppearsTransparent
        self.hidesTitle = hidesTitle
        self.movableByWindowBackground = movableByWindowBackground
        self.floatingLevel = floatingLevel
        self.shadow = shadow
        self.level = level
        self.collectionBehavior = collectionBehavior
        self.excludeFromCapture = excludeFromCapture
        self.nonactivatingPanel = nonactivatingPanel
        self.launcher = launcher
        self.cornerRadius = cornerRadius
        self.isCornerCurveCircular = isCornerCurveCircular
    }

    public func nonactivatingPanel(_ enabled: Bool) -> MacWindowOptions {
        var copy = self
        copy.nonactivatingPanel = enabled
        if !enabled {
            copy.launcher = false
        }
        return copy
    }

    public func shadow(_ enabled: Bool) -> MacWindowOptions {
        var copy = self
        copy.shadow = enabled
        return copy
    }

    public func level(_ level: Int) -> MacWindowOptions {
        var copy = self
        copy.level = level
        return copy
    }

    public func collectionBehavior(_ bits: UInt) -> MacWindowOptions {
        var copy = self
        copy.collectionBehavior = bits
        return copy
    }

    public func excludeFromCapture(_ exclude: Bool) -> MacWindowOptions {
        var copy = self
        copy.excludeFromCapture = exclude
        return copy
    }

    public func cornerRadius(_ radius: Float) -> MacWindowOptions {
        var copy = self
        copy.cornerRadius = max(0.0, radius)
        return copy
    }

    public func cornerCurveCircular() -> MacWindowOptions {
        var copy = self
        copy.isCornerCurveCircular = true
        return copy
    }
}

/// Combined window + macOS options (`rune::ConfiguredWindowOptions`).
public struct ConfiguredWindowOptions: Sendable, Equatable {
    public var options: WindowOptions
    public var native: MacWindowOptions

    public init(options: WindowOptions = WindowOptions(), native: MacWindowOptions = MacWindowOptions()) {
        self.options = options
        self.native = native
    }

    public func macos(_ amend: (MacWindowOptions) -> MacWindowOptions) -> ConfiguredWindowOptions {
        ConfiguredWindowOptions(options: options, native: amend(native))
    }
}

/// Request to position/size/activate a window via `AppHandle.place` (`rune::PlaceRequest`).
public struct PlaceRequest: Sendable, Equatable {
    public var position: Vec2?
    public var size: Vec2?
    public var display: DisplayTarget?
    public var placement: OverlayPlacement?
    public var activate: Bool

    public init(
        position: Vec2? = nil,
        size: Vec2? = nil,
        display: DisplayTarget? = nil,
        placement: OverlayPlacement? = nil,
        activate: Bool = true
    ) {
        self.position = position
        self.size = size
        self.display = display
        self.placement = placement
        self.activate = activate
    }
}

/// Input method event delivered to `App.onIme` (`rune::Ime`).
public enum Ime: Sendable, Equatable {
    case enabled
    case disabled
    case preedit(ImePreedit)
    case commit(String)
    case cancel
    case deleteSurrounding(beforeUTF8: Int, afterUTF8: Int)
}

/// Handle to a native window delivered to `onWindow` / `onReady` or queued pre-bind (`rune::WindowHandle`).
public final class WindowHandle: @unchecked Sendable {
    private enum Route {
        case unbound(queued: [WindowHandleRequest])
        case bound(slot: Int, dispatch: @Sendable (Int, WindowHandleRequest) -> Void)
    }

    public let key: String

    private let lock = NSLock()
    private var route: Route
    private var visibleFlag: Bool
    private var titleStorage: String
    private var positionStorage: Vec2?
    private var readyFlag = false
    private var numberStorage: UInt32 = 0
    private var statsStorage = WindowSurfaceStats()
    private var placementProvider: (() -> WindowPlacement?)?
    private var clickThroughApplier: ((Bool) -> Result<Void, Error>)?
    private let minimizeImpl: @Sendable () -> Void
    private let placeImpl: @Sendable (PlaceRequest) -> Void

    /// Creates an unbound handle for a named window (`WindowHandle::new(key)`).
    public init(key: String) {
        self.key = key
        self.route = .unbound(queued: [])
        self.titleStorage = key
        self.visibleFlag = true
        self.positionStorage = nil
        self.minimizeImpl = {}
        self.placeImpl = { _ in }
    }

    /// Creates a closure-backed handle delivered to `App.onWindow` / `App.onReady`.
    public init(
        title: String = "Rune",
        isVisible: Bool = true,
        position: Vec2? = nil,
        onClose: @escaping @Sendable () -> Void = {},
        onMinimize: @escaping @Sendable () -> Void = {},
        onFocus: @escaping @Sendable () -> Void = {},
        onShow: @escaping @Sendable () -> Void = {},
        onHide: @escaping @Sendable () -> Void = {},
        onSetTitle: @escaping @Sendable (String) -> Void = { _ in },
        onSetPosition: @escaping @Sendable (Vec2) -> Void = { _ in },
        onPlace: @escaping @Sendable (PlaceRequest) -> Void = { _ in }
    ) {
        self.key = title
        self.titleStorage = title
        self.visibleFlag = isVisible
        self.positionStorage = position
        self.minimizeImpl = onMinimize
        self.placeImpl = onPlace
        self.route = .bound(slot: 0) { _, request in
            switch request {
            case .close:
                onClose()
            case .focus:
                onFocus()
            case .show:
                onShow()
            case .hide:
                onHide()
            case .setTitle(let newTitle):
                onSetTitle(newTitle)
            case .setPosition(let x, let y):
                onSetPosition(Vec2(Float(x), Float(y)))
            default:
                break
            }
        }
    }

    /// Routes queued and future requests to a live host slot.
    public func bind(
        slot: Int,
        dispatch: @escaping @Sendable (Int, WindowHandleRequest) -> Void,
        placementProvider: (() -> WindowPlacement?)? = nil,
        clickThroughApplier: ((Bool) -> Result<Void, Error>)? = nil
    ) {
        lock.lock()
        let pending: [WindowHandleRequest]
        if case .unbound(let queued) = route {
            pending = queued
        } else {
            pending = []
        }
        route = .bound(slot: slot, dispatch: dispatch)
        self.placementProvider = placementProvider
        self.clickThroughApplier = clickThroughApplier
        lock.unlock()

        for req in pending {
            dispatch(slot, req)
        }
    }

    /// Marks native teardown without discarding future queued requests (`WindowHandle::unbind`).
    public func unbind() {
        lock.lock()
        readyFlag = false
        numberStorage = 0
        placementProvider = nil
        clickThroughApplier = nil
        route = .unbound(queued: [])
        lock.unlock()
    }

    public func setReady(_ ready: Bool) {
        lock.lock()
        readyFlag = ready
        lock.unlock()
    }

    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readyFlag
    }

    public func setWindowNumber(_ number: UInt32) {
        lock.lock()
        numberStorage = number
        lock.unlock()
    }

    public var windowNumber: UInt32? {
        lock.lock()
        defer { lock.unlock() }
        return numberStorage != 0 ? numberStorage : nil
    }

    public func updateSurfaceStats(_ stats: WindowSurfaceStats) {
        lock.lock()
        statsStorage = stats
        lock.unlock()
    }

    public var surfaceStats: WindowSurfaceStats {
        lock.lock()
        defer { lock.unlock() }
        return statsStorage
    }

    /// A headless run takes pending unbound requests each turn (`WindowHandle::take_headless`).
    public func takeHeadless() -> [(slot: Int, request: WindowHandleRequest)] {
        lock.lock()
        defer { lock.unlock() }
        guard case .unbound(let queued) = route else {
            return []
        }
        route = .unbound(queued: [])
        return queued.map { (slot: 0, request: $0) }
    }

    public var headlessPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .unbound(let queued) = route else {
            return false
        }
        return !queued.isEmpty
    }

    public var title: String {
        lock.lock()
        defer { lock.unlock() }
        return titleStorage
    }

    public var isVisible: Bool {
        lock.lock()
        defer { lock.unlock() }
        return visibleFlag
    }

    public var position: Vec2? {
        lock.lock()
        defer { lock.unlock() }
        return positionStorage
    }

    private func send(_ request: WindowHandleRequest) {
        lock.lock()
        let activeDispatch: ((Int, WindowHandleRequest) -> Void)?
        let activeSlot: Int
        switch route {
        case .bound(let slot, let dispatch):
            activeDispatch = dispatch
            activeSlot = slot
        case .unbound(var queued):
            queued.append(request)
            route = .unbound(queued: queued)
            activeDispatch = nil
            activeSlot = 0
        }
        lock.unlock()

        activeDispatch?(activeSlot, request)
    }

    public func focus() { send(.focus) }
    public func open() { send(.open) }

    public func close() {
        lock.lock()
        visibleFlag = false
        lock.unlock()
        send(.close)
    }

    public func minimize() { minimizeImpl() }

    public func show() { setVisible(true) }
    public func hide() { setVisible(false) }

    public func setVisible(_ visible: Bool) {
        lock.lock()
        visibleFlag = visible
        lock.unlock()
        send(visible ? .show : .hide)
    }

    public func setPosition(_ point: Vec2) {
        lock.lock()
        positionStorage = point
        lock.unlock()
        send(.setPosition(x: Int32(point.x.rounded()), y: Int32(point.y.rounded())))
    }

    public func setPosition(_ position: (Int32, Int32)) {
        lock.lock()
        positionStorage = Vec2(Float(position.0), Float(position.1))
        lock.unlock()
        send(.setPosition(x: position.0, y: position.1))
    }

    public func setAlwaysOnTop(_ on: Bool) { send(.setAlwaysOnTop(on)) }
    public func resize(_ size: (Float, Float)) { send(.resize(width: size.0, height: size.1, animate: true)) }
    public func resizeInstant(_ size: (Float, Float)) { send(.resize(width: size.0, height: size.1, animate: false)) }
    public func center() { send(.center) }

    public func setTitle(_ newTitle: String) {
        lock.lock()
        titleStorage = newTitle
        lock.unlock()
        send(.setTitle(newTitle))
    }

    public func setTaskbar(_ state: TaskbarState) { send(.setTaskbar(state)) }
    public func flash(_ on: Bool) { send(.flash(on)) }

    public func setClickThrough(_ clickThrough: Bool) throws {
        lock.lock()
        let applier = clickThroughApplier
        lock.unlock()
        if let applier {
            try applier(clickThrough).get()
        } else {
            send(.setClickThrough(clickThrough))
        }
    }

    public func placement() -> WindowPlacement? {
        lock.lock()
        let provider = placementProvider
        lock.unlock()
        return provider?()
    }

    public func place(_ request: PlaceRequest) {
        lock.lock()
        if let pos = request.position {
            positionStorage = pos
        }
        visibleFlag = true
        lock.unlock()
        placeImpl(request)
    }
}
