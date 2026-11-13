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
    public var outcome: FrameOutcome
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
        compositorSummary: String? = nil
    ) {
        self.outcome = outcome
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

/// Manages `onFrameEncoded` and coalesced `onFrameDrawn` reporting across frames (`frame::FrameReports`).
public final class FrameReports<State> {
    public var onFrameEncoded: ((FrameEncoded) -> Void)?
    public var onFrameDrawn: ((inout State, FrameEncoded, inout Tx) -> Void)?
    /// Minimum interval between `onFrameDrawn` state updates (upstream throttles state callbacks so
    /// high-refresh loops aren't self-invalidated at 120Hz). Set to `0` for immediate delivery.
    public var drawnInterval: Double
    public private(set) var droppedCount: Int = 0

    private var pendingDrawn: FrameEncoded?
    private var lastDrawnAt: Double = -.infinity

    public init(
        onFrameEncoded: ((FrameEncoded) -> Void)? = nil,
        onFrameDrawn: ((inout State, FrameEncoded, inout Tx) -> Void)? = nil,
        drawnInterval: Double = 0.1
    ) {
        self.onFrameEncoded = onFrameEncoded
        self.onFrameDrawn = onFrameDrawn
        self.drawnInterval = max(0.0, drawnInterval)
    }

    /// Emits `onFrameEncoded` immediately (when set) and queues a drawn report if `outcome == .drawn`.
    public func record(_ encoded: FrameEncoded) {
        onFrameEncoded?(encoded)
        guard onFrameDrawn != nil, encoded.outcome == .drawn else { return }
        if pendingDrawn != nil {
            droppedCount += 1
        }
        pendingDrawn = encoded
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
            let late = max(0.0, done - last)
            phase = .presented(last: last)
            return late
        case .idle(let last), .presented(let last):
            phase = .presented(last: last)
            return 0.0
        }
    }
}

// MARK: - Window / Shell / Options Types (window/spec.rs, window/titlebar.rs, lib.rs)

/// Glyph rasterization smoothing preference (`rune::FontSmoothing`).
public enum FontSmoothing: String, Sendable, Equatable, Codable {
    case on
    case off
    case systemDefault

    /// Resolved effective setting (`true` on macOS by default, `false` elsewhere).
    public var isEnabled: Bool {
        switch self {
        case .on: return true
        case .off: return false
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

/// Window frame chrome style (`rune::Chrome`).
public enum Chrome: String, Sendable, Equatable, Codable {
    case standard
    case borderless
    case titlebarIntegrated
}

/// Integrated custom titlebar geometry (`rune::Titlebar`).
public struct Titlebar: Sendable, Equatable, Codable {
    public var height: Float
    public var insetLeading: Float
    public var insetTrailing: Float
    public var showsTitle: Bool

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
    }
}

/// Window chrome insets reported in `Cx` (`rune::ChromeInsets`).
public struct ChromeInsets: Sendable, Equatable, Codable {
    public var leading: Float
    public var trailing: Float
    public var top: Float

    public init(leading: Float = 0.0, trailing: Float = 0.0, top: Float = 0.0) {
        self.leading = max(0.0, leading)
        self.trailing = max(0.0, trailing)
        self.top = max(0.0, top)
    }

    public static let zero = ChromeInsets()
}

/// Preferred target display (`rune::window::Display`).
public enum DisplayTarget: Sendable, Equatable, Codable {
    case primary
    case index(Int)
    case named(String)
}

/// Runtime launch options (`rune::RunOptions`).
public struct RunOptions: Sendable, Equatable {
    public var display: DisplayTarget?
    public var arguments: [String]?

    public init(display: DisplayTarget? = nil, arguments: [String]? = nil) {
        self.display = display
        self.arguments = arguments
    }
}

/// Initial window presentation mode (`rune::windows::OpenAs`).
public struct OpenAs: Sendable, Equatable, Codable {
    public var isMaximized: Bool
    public var isFullScreen: Bool

    public static let normal = OpenAs(isMaximized: false, isFullScreen: false)

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

    public var minSize: Vec2?
    public var maxSize: Vec2?
    public var resizable: Bool
    public var closable: Bool
    public var minimizable: Bool
    public var transparent: Bool
    public var hasShadow: Bool
    public var alwaysOnTop: Bool

    public init(
        minSize: Vec2? = WindowOptions.defaultMinSize,
        maxSize: Vec2? = nil,
        resizable: Bool = true,
        closable: Bool = true,
        minimizable: Bool = true,
        transparent: Bool = false,
        hasShadow: Bool = true,
        alwaysOnTop: Bool = false
    ) {
        self.minSize = minSize
        self.maxSize = maxSize
        self.resizable = resizable
        self.closable = closable
        self.minimizable = minimizable
        self.transparent = transparent
        self.hasShadow = hasShadow
        self.alwaysOnTop = alwaysOnTop
    }
}

/// macOS-specific window styling options (`rune::MacWindowOptions`).
public struct MacWindowOptions: Sendable, Equatable, Codable {
    public var fullSizeContentView: Bool
    public var titlebarAppearsTransparent: Bool
    public var hidesTitle: Bool
    public var movableByWindowBackground: Bool
    public var floatingLevel: Bool

    public init(
        fullSizeContentView: Bool = false,
        titlebarAppearsTransparent: Bool = false,
        hidesTitle: Bool = false,
        movableByWindowBackground: Bool = false,
        floatingLevel: Bool = false
    ) {
        self.fullSizeContentView = fullSizeContentView
        self.titlebarAppearsTransparent = titlebarAppearsTransparent
        self.hidesTitle = hidesTitle
        self.movableByWindowBackground = movableByWindowBackground
        self.floatingLevel = floatingLevel
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
}

/// Request to position/size/activate a window via `AppHandle.place` (`rune::PlaceRequest`).
public struct PlaceRequest: Sendable, Equatable {
    public var position: Vec2?
    public var size: Vec2?
    public var display: DisplayTarget?
    public var activate: Bool

    public init(
        position: Vec2? = nil,
        size: Vec2? = nil,
        display: DisplayTarget? = nil,
        activate: Bool = true
    ) {
        self.position = position
        self.size = size
        self.display = display
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

/// Handle to a native window delivered to `onWindow` / `onReady` (`rune::WindowHandle`).
public final class WindowHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var visibleFlag: Bool
    private var titleStorage: String
    private var positionStorage: Vec2?
    private let closeImpl: @Sendable () -> Void
    private let minimizeImpl: @Sendable () -> Void
    private let focusImpl: @Sendable () -> Void
    private let showImpl: @Sendable () -> Void
    private let hideImpl: @Sendable () -> Void
    private let setTitleImpl: @Sendable (String) -> Void
    private let setPositionImpl: @Sendable (Vec2) -> Void
    private let placeImpl: @Sendable (PlaceRequest) -> Void

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
        self.titleStorage = title
        self.visibleFlag = isVisible
        self.positionStorage = position
        self.closeImpl = onClose
        self.minimizeImpl = onMinimize
        self.focusImpl = onFocus
        self.showImpl = onShow
        self.hideImpl = onHide
        self.setTitleImpl = onSetTitle
        self.setPositionImpl = onSetPosition
        self.placeImpl = onPlace
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

    public func close() {
        lock.lock()
        visibleFlag = false
        lock.unlock()
        closeImpl()
    }

    public func minimize() { minimizeImpl() }
    public func focus() { focusImpl() }

    public func show() {
        lock.lock()
        visibleFlag = true
        lock.unlock()
        showImpl()
    }

    public func hide() {
        lock.lock()
        visibleFlag = false
        lock.unlock()
        hideImpl()
    }

    public func setTitle(_ newTitle: String) {
        lock.lock()
        titleStorage = newTitle
        lock.unlock()
        setTitleImpl(newTitle)
    }

    public func setPosition(_ point: Vec2) {
        lock.lock()
        positionStorage = point
        lock.unlock()
        setPositionImpl(point)
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
