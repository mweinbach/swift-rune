import Foundation

#if os(macOS)
import AppKit
#endif

// MARK: - LocalTime (`crates/rune/src/time/local.rs`)

/// Wall-clock date and time components for an epoch millisecond timestamp (`rune::time::LocalTime`).
public struct LocalTime: Sendable, Equatable, Hashable {
    public let year: Int32
    /// 1...12
    public let month: UInt32
    /// 1...31
    public let day: UInt32
    /// 0...23
    public let hour: UInt32
    /// 0...59
    public let minute: UInt32
    /// 0...59
    public let second: UInt32
    /// Seconds east of UTC, daylight saving included.
    public let offset: Int32

    public init(
        year: Int32,
        month: UInt32,
        day: UInt32,
        hour: UInt32,
        minute: UInt32,
        second: UInt32,
        offset: Int32
    ) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.offset = offset
    }

    /// Converts `epochMs` (milliseconds since 1970-01-01 UTC) in the OS time zone, including DST for that instant.
    public static func at(epochMs: Int64) -> LocalTime {
        let secs = floorDiv(epochMs, 1000)
        return atOffset(epochMs: epochMs, offset: osOffsetSeconds(atUnixSeconds: secs) ?? 0)
    }

    /// Converts `epochMs` using an explicit UTC offset in seconds (`LocalTime::at_offset`).
    public static func atOffset(epochMs: Int64, offset: Int32) -> LocalTime {
        let secs = floorDiv(epochMs, 1000) + Int64(offset)
        let days = floorDiv(secs, 86_400)
        let sod = floorMod(secs, 86_400)
        // Howard Hinnant's `civil_from_days` algorithm (matches `time/local.rs:39-56`)
        let z = days + 719_468
        let era = floorDiv(z, 146_097)
        let doe = floorMod(z, 146_097)
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = Int32(era * 400 + yoe + (month <= 2 ? 1 : 0))
        return LocalTime(
            year: year,
            month: UInt32(month),
            day: UInt32(doy - (153 * mp + 2) / 5 + 1),
            hour: UInt32(sod / 3600),
            minute: UInt32((sod % 3600) / 60),
            second: UInt32(sod % 60),
            offset: offset
        )
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        let r = a % b
        return (r != 0 && ((r < 0) != (b < 0))) ? (q - 1) : q
    }

    private static func floorMod(_ a: Int64, _ b: Int64) -> Int64 {
        let r = a % b
        return r < 0 ? r + abs(b) : r
    }

    private static func osOffsetSeconds(atUnixSeconds secs: Int64) -> Int32? {
        #if os(macOS) || os(iOS) || os(Linux)
        var t = time_t(clamping: secs)
        if Int64(t) != secs { return nil }
        var localTm = tm()
        guard localtime_r(&t, &localTm) != nil else { return nil }
        return Int32(localTm.tm_gmtoff)
        #else
        return Int32(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(secs))))
        #endif
    }
}

// MARK: - JumpList Setting (`crates/rune/src/jump_list.rs`)

#if os(macOS)
@MainActor
protocol RuneDockJumpReceiver: AnyObject {
    func openDockArgument(_ argument: String)
}
#endif

final class JumpListStore: @unchecked Sendable {
    static let shared = JumpListStore()
    private let lock = NSLock()
    private var lastSubmitted: JumpList?

    var current: JumpList? {
        lock.lock()
        defer { lock.unlock() }
        return lastSubmitted
    }

    @discardableResult
    func submit(_ list: JumpList, headless: Bool, enqueue: (JumpList) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !headless, list != lastSubmitted else { return false }
        lastSubmitted = list
        enqueue(list)
        return true
    }

    #if os(macOS)
    @MainActor
    static func installDockMenuIfReady() {
        guard let list = shared.current, NSApplication.shared.delegate != nil else { return }
        RuneNativeMenuHost.shared.setJumpMenu(list) { argument in
            if let receiver = NSApplication.shared.delegate as? RuneDockJumpReceiver {
                receiver.openDockArgument(argument)
            } else {
                IncomingURLInbox.shared.receive(argument)
            }
        }
    }
    #endif
}

/// Replaces the app's jump list (`rune::jump_list::set_jump_list`).
/// On Windows, set the process's AppUserModelID first if the app uses an explicit identity.
/// Rune submits the Windows list from a background thread. Dock menu selections on macOS call the app's
/// `onOpenUrl` hook with the item's argument. Equal lists and headless runs skip publication.
public func setJumpList(_ list: JumpList) {
    let changed = JumpListStore.shared.submit(list, headless: ToolingProcessArgs.isHeadless()) { list in
        #if os(Windows)
        WindowsJumpListWorker.shared.submit(list)
        #endif
    }
    #if os(macOS)
    guard changed else { return }
    if Thread.isMainThread {
        MainActor.assumeIsolated { JumpListStore.installDockMenuIfReady() }
    } else {
        Task { @MainActor in JumpListStore.installDockMenuIfReady() }
    }
    #else
    _ = changed
    #endif
}

// MARK: - SceneClock (`crates/rune/src/lib.rs`)

/// The logical clock a scene or init/setup hook builds its state against (`rune::SceneClock`).
public struct SceneClock: Sendable, Equatable {
    public var now: Double
    public var dt: Double

    public init(now: Double = 0.0, dt: Double = 0.0) {
        self.now = now
        self.dt = dt
    }
}

private enum SceneClockStorage {
    private static let key = "rune.sceneClock.threadLocal"

    static func current() -> SceneClock {
        (RuneExecutionContext.locals[key] as? SceneClock) ?? SceneClock()
    }

    static func with<T>(_ clock: SceneClock, _ body: () throws -> T) rethrows -> T {
        let prev = RuneExecutionContext.locals[key]
        RuneExecutionContext.locals[key] = clock
        defer {
            if let prev {
                RuneExecutionContext.locals[key] = prev
            } else {
                RuneExecutionContext.locals.removeObject(forKey: key)
            }
        }
        return try body()
    }
}

/// Readable from scene functions, `init`/`makeState`, and `AppSpec.setup` / `App.setup`; zero anywhere else (`rune::scene_clock`).
public func sceneClock() -> SceneClock {
    SceneClockStorage.current()
}

/// Executes `body` with `clock` installed as the current `sceneClock()`.
public func withSceneClock<T>(_ clock: SceneClock, _ body: () throws -> T) rethrows -> T {
    try SceneClockStorage.with(clock, body)
}
