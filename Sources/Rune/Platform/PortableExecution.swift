import Foundation
#if os(WASI)
import CRuneDesktopText
import WASILibc

/// WASI Preview 1 clock IDs. The page supplies Date time and performance time
/// through the same ABI as a standalone WASI host.
package enum RuneWASIClock: UInt32 {
    case realtime = 0
    case monotonic = 1

    package var nanoseconds: UInt64 {
        var ticks: UInt64 = 0
        guard __wasi_clock_time_get(rawValue, 1, &ticks) == 0 else { return 0 }
        return ticks
    }
}
#endif

/// Execution-local state and monotonic time used by the input and frame pipelines.
@usableFromInline
internal enum RuneExecutionContext {
    /// The Windows Foundation uptime advances with the system timer tick; use the
    /// same high-resolution monotonic clock as input events and frame diagnostics.
    @usableFromInline static var hostUptime: Double {
        #if os(Windows) || os(WASI)
        Double(uptimeNanoseconds) / 1_000_000_000
        #else
        ProcessInfo.processInfo.systemUptime
        #endif
    }

    #if os(WASI)
    // The Preview 1 reactor receives all events on one WebAssembly instance thread.
    nonisolated(unsafe) static let locals = NSMutableDictionary()

    @usableFromInline static var uptimeNanoseconds: UInt64 {
        RuneWASIClock.monotonic.nanoseconds
    }
    #else
    static var locals: NSMutableDictionary { Thread.current.threadDictionary }
    @usableFromInline static var uptimeNanoseconds: UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
    #endif
}

package enum RuneStandardIO {
    package static func error(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    package static func output(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}

package enum RuneExecutableSearch {
    /// Finds a native program on PATH without starting a shell.
    package static func find(_ program: String, searchPath: String? = nil) -> String? {
        let env = ProcessInfo.processInfo.environment
        #if os(Windows)
        let path = searchPath ?? env.first { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }?.value ?? ""
        let directories = path.split(separator: ";").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        let name = program.lowercased().hasSuffix(".exe") ? program : program + ".exe"
        #else
        let directories = (searchPath ?? env["PATH"] ?? "").split(separator: ":").map(String.init)
        let name = program
        #endif
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

#if os(WASI)
/// Work queued for a later turn of a single-threaded browser reactor.
internal enum WASIEventLoop {
    private struct Scheduled {
        let deadline: Double
        let run: @Sendable () -> Void
    }

    nonisolated(unsafe) private static var pending: [Scheduled] = []

    nonisolated(unsafe) private static var appWake = false

    static func wakeApp() {
        appWake = true
        rune_browser_host_wake(0)
    }

    static func wake(after delay: Double) { rune_browser_host_wake(delay) }

    static func nextDelay() -> Double {
        if appWake || BrowserImageCodec.canStart { return 0 }
        let now = ProcessInfo.processInfo.systemUptime
        let deadline = pending.lazy.map(\.deadline).min() ?? .infinity
        return min(max(0, deadline - now), WASIBrowserExecutor.shared.nextDelay())
    }

    static func schedule(after delay: Double = 0, _ run: @escaping @Sendable () -> Void) {
        pending.append(Scheduled(deadline: ProcessInfo.processInfo.systemUptime + delay, run: run))
        wake(after: delay)
    }

    static func reset() { pending.removeAll(); appWake = false }

    @MainActor static func poll() {
        WASIBrowserExecutor.shared.run()
        defer {
            if appWake {
                appWake = false
                RuneWebReactor.session?.requestPaint()
            }
        }
        guard !pending.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let due = pending.filter { $0.deadline <= now }
        pending.removeAll { $0.deadline <= now }
        for item in due { item.run() }
    }
}
#endif
