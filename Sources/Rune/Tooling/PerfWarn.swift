import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Commit Budget (tooling/perf_warn/budget.rs)

/// Opt-in commit duration budget logger (`RUNE_COMMIT_BUDGET_MS=N`).
public enum CommitBudget {
    public static func configuredBudgetMs() -> Double? {
        guard let raw = ProcessInfo.processInfo.environment["RUNE_COMMIT_BUDGET_MS"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let ms = Double(raw), ms > 0 else {
            return nil
        }
        return ms
    }

    /// Formats one over-budget commit line (`perf_warn/budget.rs::report`).
    public static func report(
        totalMs: Double,
        budgetMs: Double,
        phases: [Double],
        why: UInt16,
        leftOut: UInt32
    ) -> String {
        let view = phases.count > 0 ? phases[0] : 0
        let layout = phases.count > 2 ? phases[2] : 0
        let text = phases.count > 3 ? phases[3] : 0
        let apply = phases.count > 5 ? phases[5] : 0
        let parts: [(String, Double)] = [
            ("the view", view),
            ("layout", max(0, layout - text)),
            ("text", text),
            ("apply", apply),
        ]
        let top = parts.max(by: { $0.1 < $1.1 }).flatMap { $0.1 > 0 ? $0 : nil }
        let whyNames = CommitWhy.names(why)

        var line = String(format: "rune: commit took %.1f ms, over RUNE_COMMIT_BUDGET_MS=", totalMs)
            + rustDisplay(budgetMs)
            + String(format: ": view %.1f, layout %.1f (text %.1f), apply %.1f ms", view, layout, text, apply)
        if let top {
            let pct = totalMs > 0 ? (100.0 * top.1 / totalMs) : 0
            line += String(format: "; most in %@ (%.0f%%)", top.0, pct)
        }
        if !whyNames.isEmpty {
            line += "; committed for \(whyNames.joined(separator: ", "))"
        }
        if leftOut > 0 {
            line += " (\(leftOut) more over budget since the last line)"
        }
        return line
    }
}

// MARK: - Commit Meter (tooling/perf_warn/commits.rs)

/// Detects scroll-frame over-committing, instant-scroll misuse, and hover-on-many-rows state churn.
public final class CommitMeter {
    public static let commitsThreshold: UInt32 = 6
    public static let shareDivisor: UInt32 = 4
    public static let instantFramesThreshold: UInt32 = 8
    public static let hoverRowsThreshold: Int = 8

    public enum Cause: Equatable, Sendable {
        case poll
        case handler(String)
        case read
    }

    private struct Source {
        let site: String
        let cause: Cause
        let subject: String?
        let fileLine: String?
    }

    private var sources: [Source] = []
    private var frames: UInt32 = 0
    private var counts: [String: UInt32] = [:]
    private var instantStreak: UInt32 = 0
    private var hoverRows: [String: [String]] = [:]

    public init() {}

    public func poll() {
        sources.append(Source(site: "poll", cause: .poll, subject: nil, fileLine: nil))
    }

    public func handler(name: String, path: String? = nil, at siteKey: String? = nil) {
        let site: String
        if let siteKey {
            site = "\(name) \(siteKey)"
        } else if let path {
            site = PerfWarn.handlerSite(name: name, path: path)
        } else {
            site = name
        }
        if let siteKey, let path, (name == "on_hover" || name == "on_hover_change") {
            recordHoverRow(name: name, at: siteKey, path: path)
        }
        sources.append(Source(site: site, cause: .handler(name), subject: path, fileLine: siteKey))
    }

    public func read(key: String, at siteKey: String? = nil) {
        sources.append(Source(site: "read \(key)", cause: .read, subject: key, fileLine: siteKey))
    }

    private func recordHoverRow(name: String, at siteKey: String, path: String) {
        var rows = hoverRows[siteKey] ?? []
        if rows.count >= Self.hoverRowsThreshold || rows.contains(path) { return }
        rows.append(path)
        hoverRows[siteKey] = rows
        guard rows.count >= Self.hoverRowsThreshold else { return }
        let example = rows[0]
        PerfWarn.warnOnce(site: "hover rows \(siteKey)") {
            "`\(name)` set at \(siteKey) committed the view for \(Self.hoverRowsThreshold) elements (as \"\(example)\"): each one the pointer crosses runs the whole view; \(Self.handlerFix(name))"
        }
    }

    public func frameEnds(scrolling: Bool, committed: Bool, instantKey: String? = nil) {
        let frameSources = sources
        sources.removeAll(keepingCapacity: true)

        if let key = instantKey, committed {
            instantStreak += 1
            if instantStreak == Self.instantFramesThreshold {
                PerfWarn.warnOnce(site: "instant scroll \(key)") {
                    "an instant scroll (`Tx::scroll_to_instant`, `scroll_to_y`, `scroll_key_to`) moved \"\(key)\" on \(Self.instantFramesThreshold) frames in a row, each with a commit: an app stepping its own glide this way runs the view every frame; glide with `Tx::scroll_to_with(key, x, y, spring)`, which runs on Rune's clock with no commits"
                }
            }
        } else {
            instantStreak = 0
        }

        if !scrolling {
            frames = 0
            counts.removeAll(keepingCapacity: true)
            return
        }
        frames += 1
        guard committed else { return }

        var seen = Set<String>()
        for s in frameSources {
            guard seen.insert(s.site).inserted else { continue }
            let nextCount = (counts[s.site] ?? 0) + 1
            counts[s.site] = nextCount
            if nextCount >= Self.commitsThreshold && nextCount * Self.shareDivisor >= frames {
                let capturedFrames = frames
                PerfWarn.warnOnce(site: "scroll commit \(s.site)") {
                    Self.scrollCommitMessage(source: s, count: nextCount, frames: capturedFrames)
                }
            }
        }
    }

    private static func scrollCommitMessage(source s: Source, count: UInt32, frames: UInt32) -> String {
        let atSuffix = s.fileLine.map { " (set at \($0))" } ?? ""
        let subject = s.subject ?? ""
        let who: String
        let fix: String
        switch s.cause {
        case .poll:
            who = "`poll` returned true and"
            fix = "return true only when visible state changed; to act on where a scroll stops, wait until it has been still a moment (`Tx::wake_after`), and follow it frame by frame with `El::on_scroll_offset` and live values"
        case .read:
            let atPart = s.fileLine.map { " at \($0)" } ?? ""
            let stripped = LayoutReadConstants.stripWindowPrefix(subject)
            if stripped.scrolled {
                who = "the view's `Cx::window_layout` read of \"\(stripped.key)\"\(atPart) moved and"
                fix = "read `Cx::layout_size` or `Cx::layout` (unscrolled) unless the view needs where the element is in the window, and then only through `window_layout_with` and what it computes"
            } else {
                who = "the view's layout read of \"\(subject)\"\(atPart) moved and"
                fix = "read only what the view needs (`Cx::layout_size`, `Cx::layout_with`), or follow it with `El::on_layout_tx` and a live value"
            }
        case .handler(let name):
            who = "`\(name)` on \"\(subject)\"\(atSuffix)"
            fix = handlerFix(name)
        }
        return "\(who) committed the view on \(count) of \(frames) frames of a scroll: \(fix)"
    }

    private static func handlerFix(_ name: String) -> String {
        switch name {
        case "on_hover", "on_hover_change":
            return "paint hover with `El::hover`, `hover_group` and `group_*` styles (`hover_alone` for a target inside a lit row) instead of state, or say `Tx::live_only` when the handler only sets live values"
        case "on_layout_tx", "on_drawn_layout_tx", "on_pointer_move_local", "on_wheel":
            return "when the handler only moves live values or bookkeeping, say `Tx::live_only` (`on_layout` and `on_drawn_layout` take one in their `_tx` forms)"
        case "on_visible_rows":
            return "return true only when the visible range changed what the view shows"
        default:
            return "say `Tx::live_only` when the handler changes nothing the view reads"
        }
    }
}

// MARK: - Idle Meter (tooling/perf_warn/idle.rs)

/// Detects idle redraw streaks and `poll` returning `true` without changing rendered pixels/instances.
public final class IdleMeter {
    public static let pollFramesThreshold: UInt32 = 30
    public static let idleFramesThreshold: UInt32 = 120
    public static let idleSecondsThreshold: Double = 2.0

    public struct DrawnSnapshot: Sendable {
        public var instances: [UInt8]
        public var surfaceKey: UInt64
        public var opaque: Bool

        public init(instances: [UInt8], surfaceKey: UInt64, opaque: Bool = false) {
            self.instances = instances
            self.surfaceKey = surfaceKey
            self.opaque = opaque
        }
    }

    internal enum WokeReason: Equatable {
        case live(polled: Bool)
        case timer
        case timerLive
        case timerPoll

        var label: String {
            switch self {
            case .timerPoll: return "a `wake_after` loop whose `poll` returns true"
            case .timer: return "a `wake_after` loop"
            case .timerLive: return "a `wake_after` loop and a live value"
            case .live: return "a live value"
            }
        }
    }

    internal enum StreakState: Equatable {
        case watching
        case counting(from: Double, frames: UInt32, woke: WokeReason)
    }

    internal struct IdleReading {
        var clock: Double
        var quiet: Bool
        var animating: Bool
        var same: Bool?
        var timer: Bool
        var live: Bool
        var polled: Bool
    }

    private struct Start {
        let quiet: Bool
        let timer: Bool
        let live: Bool
    }

    private var currentStart: Start?
    private var polledFlag = false
    private var lastQuiet: (instances: [UInt8], key: UInt64)?
    private var pollStreak: UInt32 = 0
    private var idleStreak: StreakState = .watching

    public init() {}

    @discardableResult
    public func polled(_ changed: Bool) -> Bool {
        if changed { polledFlag = true }
        return changed
    }

    public func begins(quiet: Bool, timer: Bool, live: Bool) {
        currentStart = Start(quiet: quiet, timer: timer, live: live)
    }

    public func ends(clock: Double, animating: Bool, drawn: DrawnSnapshot, windowName: String? = nil) {
        guard let start = currentStart else { return }
        currentStart = nil
        let wasPolled = polledFlag
        polledFlag = false

        let quiet = start.quiet && !drawn.opaque
        let sameDraw: Bool? = quiet ? lastQuiet.map { $0.key == drawn.surfaceKey && $0.instances == drawn.instances } : nil
        if quiet {
            lastQuiet = (drawn.instances, drawn.surfaceKey)
        } else {
            lastQuiet = nil
        }
        let same = sameDraw.map { $0 && !animating }
        let siteSuffix = windowName.map { " \"\($0)\"" } ?? ""

        if wasPolled && same == true {
            pollStreak += 1
        } else {
            pollStreak = 0
        }
        if pollStreak == Self.pollFramesThreshold {
            PerfWarn.warnOnce(site: "idle-poll\(siteSuffix)") {
                let win = siteSuffix.isEmpty ? "" : " of window\(siteSuffix)"
                return "`poll`\(win) returned true but nothing changed (\(Self.pollFramesThreshold) frames in a row); return true only when visible state changed"
            }
        }

        if let (woke, secs) = stepIdle(
            clock: clock,
            quiet: quiet,
            animating: animating,
            same: same,
            timer: start.timer,
            live: start.live,
            polled: wasPolled
        ) {
            PerfWarn.warnOnce(site: "idle-draw\(siteSuffix)") {
                String(
                    format: "idle window%@ still drawing: check `wake_after` loops (%u frames in %.1f s with no input, motion or visible change, woken by %@)",
                    siteSuffix, Self.idleFramesThreshold, secs, woke.label
                )
            }
        }
    }

    private func stepIdle(
        clock: Double,
        quiet: Bool,
        animating: Bool,
        same: Bool?,
        timer: Bool,
        live: Bool,
        polled: Bool
    ) -> (WokeReason, Double)? {
        Self.stepIdleReading(
            &idleStreak,
            reading: IdleReading(
                clock: clock,
                quiet: quiet,
                animating: animating,
                same: same,
                timer: timer,
                live: live,
                polled: polled
            )
        )
    }

    internal static func stepIdleReading(_ streak: inout StreakState, reading r: IdleReading) -> (WokeReason, Double)? {
        if !r.quiet || r.animating || r.same == false {
            streak = .watching
            return nil
        }
        guard r.same != nil, (r.timer || r.live) else { return nil }

        let from: Double
        let prevFrames: UInt32
        let prevWoke: WokeReason?
        if case let .counting(f, cnt, w) = streak, !(r.clock - f > Self.idleSecondsThreshold) {
            from = f
            prevFrames = cnt
            prevWoke = w
        } else {
            from = r.clock
            prevFrames = 0
            prevWoke = nil
        }

        let hadTimer: Bool
        let hadLive: Bool
        let hadPolled: Bool
        switch prevWoke {
        case .timer:
            (hadTimer, hadLive, hadPolled) = (true, false, false)
        case .timerLive:
            (hadTimer, hadLive, hadPolled) = (true, true, false)
        case .timerPoll:
            (hadTimer, hadLive, hadPolled) = (true, false, true)
        case .live(let p):
            (hadTimer, hadLive, hadPolled) = (false, true, p)
        case nil:
            (hadTimer, hadLive, hadPolled) = (false, false, false)
        }

        let isTimer = r.timer || hadTimer
        let isLive = r.live || hadLive
        let isPolled = r.polled || hadPolled
        let nextWoke: WokeReason
        switch (isTimer, isLive, isPolled) {
        case (true, _, true): nextWoke = .timerPoll
        case (true, false, false): nextWoke = .timer
        case (true, true, false): nextWoke = .timerLive
        case (false, _, _): nextWoke = .live(polled: isPolled)
        }

        let nextFrames = prevFrames + 1
        streak = .counting(from: from, frames: nextFrames, woke: nextWoke)
        if nextFrames == Self.idleFramesThreshold {
            return (nextWoke, r.clock - from)
        }
        return nil
    }
}

// MARK: - RunQ & Stall Check (tooling/perf_warn/runq.rs)

public enum PerfRunQ {
    public static let stallMs: Double = 8.0
    public static let stallCPURatio: Double = 4.0

    /// Returns true if the 1-minute system load average meets or exceeds logical core count.
    public static func overloaded() -> Bool {
        #if os(macOS) || os(Linux)
        var load: Double = 0
        let got = getloadavg(&load, 1)
        let cores = max(1, ProcessInfo.processInfo.processorCount)
        return got == 1 && load >= Double(cores)
        #else
        return false
        #endif
    }

    /// Returns per-thread run-queue wait time (ms) where the OS exposes it; `nil` on Darwin.
    public static func waitMs() -> Double? {
        #if os(Linux)
        if let raw = try? String(contentsOfFile: "/proc/thread-self/schedstat", encoding: .utf8) {
            let parts = raw.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, let waitNs = UInt64(parts[1]) {
                return Double(waitNs) / 1_000_000.0
            }
        }
        #endif
        return nil
    }

    /// Computes blocked wall ms if the callback blocked rather than computed or waited in the run queue.
    public static func blockedMs(wallMs: Double, cpuMs: Double, waitMs: Double?, loaded: Bool) -> Double? {
        if waitMs == nil && loaded { return nil }
        let clampedWait = max(0.0, min(wallMs, waitMs ?? 0.0))
        let blocked = wallMs - clampedWait
        return (blocked > stallMs && blocked > stallCPURatio * cpuMs) ? blocked : nil
    }
}

// MARK: - Launch Report (tooling/perf_warn/launch.rs)

public enum PerfLaunch {
    public static let appThresholdMs: Double = 100.0

    public static func report(setupMs: Double, initMs: Double, viewMs: Double, totalMs: Double) -> String? {
        guard setupMs + initMs + viewMs > appThresholdMs else { return nil }
        let runeMs = max(0.0, totalMs - setupMs - initMs - viewMs)
        let parts: [(Double, String)] = [
            (setupMs, "setup in `main` before `run`"),
            (initMs, "`init`"),
            (viewMs, "the first `view`"),
        ]
        let slowest = parts.max(by: { $0.0 < $1.0 })?.1 ?? ""
        return String(
            format: "first frame took %.0f ms (setup %.0f ms, init %.0f ms, first view %.0f ms, window and GPU %.0f ms); the slowest is %@: start slow work from `on_ready`",
            totalMs, setupMs, initMs, viewMs, runeMs, slowest
        )
    }
}

// MARK: - PerfWarn Top-Level & Per-Window Watch (tooling/perf_warn.rs)

public enum PerfWarn {
    public static let overbuildRows: Int = 200
    public static let overbuildRatio: Int = 4

    internal final class WarningLog: @unchecked Sendable {
        fileprivate let lock = NSLock()
        fileprivate var warnedSites: Set<String> = []
        fileprivate var lines: [String] = []
        fileprivate var enabledOverride: Bool?
    }

    private static let processLog = WarningLog()
    @TaskLocal internal static var testLog: WarningLog?
    private static var log: WarningLog { testLog ?? processLog }

    internal static var testEnabledOverride: Bool? {
        get {
            let log = self.log
            return log.lock.withLock { log.enabledOverride }
        }
        set {
            let log = self.log
            log.lock.withLock { log.enabledOverride = newValue }
        }
    }

    public static var isEnabled: Bool {
        if let override = testEnabledOverride {
            return override
        }
        return ProcessInfo.processInfo.environment["RUNE_PERF_WARN"] != "0"
    }

    /// Returns the calling thread's user + system CPU time in milliseconds, when available.
    public static func threadCpuMs() -> Double? {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
        return Rune.threadCpuMs()
        #else
        return nil
        #endif
    }

    /// Times one app callback on the main thread and emits a single warning per site if blocked
    /// on wall time rather than computing (`perf_warn::Stall`).
    public struct Stall {
        private let wallStartNs: UInt64?
        private let cpuStartMs: Double?
        private let waitStartMs: Double?

        private init(wallStartNs: UInt64?, cpuStartMs: Double?, waitStartMs: Double?) {
            self.wallStartNs = wallStartNs
            self.cpuStartMs = cpuStartMs
            self.waitStartMs = waitStartMs
        }

        public static func start() -> Stall {
            guard PerfWarn.isEnabled, let cpu = PerfWarn.threadCpuMs() else {
                return Stall(wallStartNs: nil, cpuStartMs: nil, waitStartMs: nil)
            }
            return Stall(
                wallStartNs: DispatchTime.now().uptimeNanoseconds,
                cpuStartMs: cpu,
                waitStartMs: PerfRunQ.waitMs()
            )
        }

        public func end(overloaded: Bool? = nil, _ what: () -> (site: String, name: String)) {
            guard let wallStartNs, let cpuStartMs else { return }
            let nowNs = DispatchTime.now().uptimeNanoseconds
            let wallMs = Double(nowNs >= wallStartNs ? nowNs - wallStartNs : 0) / 1_000_000.0
            guard wallMs > PerfRunQ.stallMs else { return }
            let cpuMs = max(0.0, (PerfWarn.threadCpuMs() ?? cpuStartMs) - cpuStartMs)
            let waitedMs = waitStartMs.flatMap { start in PerfRunQ.waitMs().map { max(0.0, $0 - start) } }
            let isLoaded = overloaded ?? (waitedMs == nil && PerfRunQ.overloaded())
            guard let blocked = PerfRunQ.blockedMs(wallMs: wallMs, cpuMs: cpuMs, waitMs: waitedMs, loaded: isLoaded) else {
                return
            }
            let (site, name) = what()
            PerfWarn.warnOnce(site: "stall \(site)") {
                let queuedPart = (waitedMs.flatMap { $0 >= 1.0 ? $0 : nil }).map { String(format: ", waited %.0f ms for a core", $0) } ?? ""
                return String(
                    format: "%@ blocked %.0f ms (CPU %.0f ms%@) on the main thread: move IO off it with `rune::Latest` or a thread",
                    name, blocked, cpuMs, queuedPart
                )
            }
        }

        public static func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            let stall = Stall.start()
            defer {
                stall.end {
                    let displayName = name.contains(" ") ? name : "`\(name)`"
                    return (site: name, name: displayName)
                }
            }
            return try body()
        }
    }

    public static func warnOnce(site: String, message: () -> String) {
        guard isEnabled else { return }
        let log = self.log
        let isNew = log.lock.withLock { log.warnedSites.insert(site).inserted }
        guard isNew else { return }
        let text = "rune: \(message()). (debug builds only; RUNE_PERF_WARN=0 silences)"
        log.lock.withLock { log.lines.append(text) }
    }

    /// Drains warnings emitted since the last call (and optionally resets deduplication for tests).
    public static func takeTestLog(resetSites: Bool = false) -> [String] {
        let log = self.log
        return log.lock.withLock {
            let out = log.lines
            log.lines.removeAll()
            if resetSites { log.warnedSites.removeAll() }
            return out
        }
    }

    public static func resetForTesting() {
        let log = self.log
        log.lock.withLock {
            log.warnedSites.removeAll()
            log.lines.removeAll()
            log.enabledOverride = nil
        }
    }

    public static func overbuilt(path: String, site: String? = nil, built: Int, mounted: Int) {
        guard built > overbuildRows, built > overbuildRatio * mounted else { return }
        let sitePart = site.map { " (.virtualize at \($0))" } ?? ""
        warnOnce(site: "overbuild \(path)") {
            "virtualized list \"\(path)\"\(sitePart) built \(built) rows to mount \(mounted): build only the mounted rows with `.virtual_rows(count, estimated_row_height, key, build)`"
        }
    }

    public static func memoKeyReplaced(id: String, existing: String, site: String) {
        guard existing != id else { return }
        warnOnce(site: "memo key \(site)") {
            "`memo(\"\(id)\", ..)` at \(site) replaced its root's key \"\(existing)\" with \"\(id)\": look it up by \"\(id)\", or key the memo with the id you want"
        }
    }

    public static func handlerSite(name: String, path: String) -> String {
        let stripped = String(path.filter { !($0.isASCII && $0.isNumber) })
        return "\(name) \(stripped)"
    }

    /// Per-window performance watch (`perf_warn::Watch`).
    public final class Watch {
        public var cause: UInt16 = 0
        public let meter = CommitMeter()
        public let idle = IdleMeter()
        public let interaction = InteractionTracker()

        public init() {}
    }
}
