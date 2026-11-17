import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
import CRuneWin32
#endif

#if os(macOS)
import AppKit
import ObjectiveC.runtime
#endif

/// Result of terminating/exiting the process cleanly or fast (`rune::quit`).
public enum QuitLifecycle {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state: QuitState = .running
    nonisolated(unsafe) private static var fastExitHookFn: (@Sendable () -> Void)?
    nonisolated(unsafe) private static var orderly: Bool = false
    nonisolated(unsafe) private static var quitGeneration: UInt64 = 0
    nonisolated(unsafe) private static var quitHooks: [ObjectIdentifier: @Sendable () -> Void] = [:]

    /// Registers a `last` closure to run before fast exit (`rune::fast_exit`).
    /// Calling `fastExit` after it is already set is a no-op; does not imply `orderlyExit`.
    public static func fastExit(_ last: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if fastExitHookFn == nil {
            fastExitHookFn = last
        }
    }

    /// Requests orderly teardown instead of fast process exit (`rune::orderly_exit`).
    public static func orderlyExit() {
        lock.lock()
        orderly = true
        lock.unlock()
    }

    /// Returns the fast-exit final hook if fast exit is active, or `nil` when `orderlyExit()` was called.
    public static func activeFastExitHook() -> (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard !orderly else { return nil }
        return fastExitHookFn ?? {}
    }

    /// True once a quit has started and has not been cancelled (`rune::quitting`).
    public static var isQuitting: Bool {
        currentState != .running
    }

    public static var currentState: QuitState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    #if os(Windows) || os(Linux)
    internal static func beginWindowGroup() {
        lock.withLock {
            if state == .done { state = .running }
        }
    }
    #endif

    /// Resets quit lifecycle state for isolated unit tests.
    internal static func resetForTesting() {
        lock.lock()
        state = .running
        fastExitHookFn = nil
        orderly = false
        quitGeneration &+= 1
        quitHooks.removeAll()
        lock.unlock()
    }

    @discardableResult
    public static func send(_ event: QuitEvent) -> [QuitEffect] {
        lock.lock()
        let prev = state
        let (next, effects) = QuitMachine.step(prev, event: event)
        let startedQuit = (prev == .running) && {
            if case .quitting = next { return true }
            return false
        }()
        state = next
        #if !os(WASI)
        if startedQuit { quitGeneration &+= 1 }
        let generation = quitGeneration
        #endif
        lock.unlock()

        if startedQuit {
            QuitMarks.record("quit.start")
            #if !os(WASI)
            startWatchThread(generation: generation)
            #endif
        }
        return effects
    }

    /// Registers a per-window `on_quit` hook keyed by host/window identity.
    public static func registerQuitHook(key: AnyObject, _ hook: @escaping @Sendable () -> Void) {
        let id = ObjectIdentifier(key)
        lock.lock()
        quitHooks[id] = hook
        lock.unlock()
    }

    public static func unregisterQuitHook(key: AnyObject) {
        let id = ObjectIdentifier(key)
        lock.lock()
        quitHooks.removeValue(forKey: id)
        lock.unlock()
    }

    /// Runs every registered `on_quit` hook once and advances `QuitMachine` with `.hooksRan`.
    public static func runQuitHooksIfOwed() {
        lock.lock()
        let hooks = Array(quitHooks.values)
        lock.unlock()
        for hook in hooks {
            hook()
        }
        _ = send(.hooksRan)
    }

    #if !os(WASI)
    private static func startWatchThread(generation: UInt64) {
        let startedAt = Date()
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 3.0)
                lock.lock()
                let done = generation != quitGeneration || state == .done || state == .running
                lock.unlock()
                if done { break }
                let ms = Int(max(0.0, Date().timeIntervalSince(startedAt) * 1000.0))
                RuneStandardIO.error("rune: still quitting \(ms) ms after the quit started: \(QuitMarks.summary())\n")
            }
        }
    }

    /// Forces process exit if still alive after `seconds` (`rune::exit_deadline`).
    public static func exitDeadline(seconds: Double) {
        let delay = max(0.0, seconds)
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: delay)
            let ms = Int(delay * 1000.0)
            RuneStandardIO.error("rune: the quit didn't end within \(ms) ms of the app's last step, so the process ends itself: \(QuitMarks.summary())\n")
            QuitMarks.record("quit.deadline")
            endProcess()
        }
    }

    /// Fast exit path once hooks have run and the loop is ending (`quit::end_fast`).
    public static func endFast(_ last: @Sendable () -> Void) -> Never {
        #if os(Windows)
        rune_win_destroy_quit_windows()
        #endif
        ReadySignal.clear()
        #if os(Windows)
        WindowsSystemTray.removeAll()
        #endif
        let effects = send(.exited)
        if effects.contains(.relaunch) {
            RelaunchController.spawn()
        }
        #if os(Windows)
        InstanceLaunches.shared.ended()
        #endif
        QuitMarks.record("quit.last")
        last()
        endProcess()
    }

    /// Orderly teardown finalization at loop exit (`Exited` + `Relaunch` if requested).
    public static func finishOrderlyExit() {
        ReadySignal.clear()
        let effects = send(.exited)
        if effects.contains(.relaunch) {
            RelaunchController.spawn()
        }
    }

    public static func endProcess() -> Never {
        QuitMarks.record("quit.end")
        #if os(Windows)
        TerminateProcess(GetCurrentProcess(), 0)
        exit(0)
        #elseif canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        _exit(0)
        #else
        exit(0)
        #endif
    }
    #endif
}

/// Lightweight phase mark tracker for quit diagnostics (`quit.start`, `quit.last`, `quit.end`, `quit.deadline`).
public enum QuitMarks {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastMark: (name: String, at: Date)?

    public static func record(_ name: String) {
        lock.lock()
        lastMark = (name, Date())
        lock.unlock()
    }

    public static func summary() -> String {
        lock.lock()
        let current = lastMark
        lock.unlock()
        guard let current else { return "no step" }
        let ms = Int(max(0.0, Date().timeIntervalSince(current.at) * 1000.0))
        return "last step \(current.name), \(ms) ms ago"
    }
}

/// Spawns a fresh instance on relaunch and waits for the prior PID (`quit/relaunch.rs`).
public enum RelaunchController {
    public static let afterEnvVar = "RUNE_RELAUNCH_AFTER"
    public static let handedEnvVar = "RUNE_INSTANCE_HANDED"
    public static let maxWaitSeconds: Double = 10.0

    #if !os(WASI)
    private static let waitedForPrevious: Void = {
        guard
            let raw = ProcessInfo.processInfo.environment[afterEnvVar],
            let pid = UInt32(raw),
            pid > 0,
            pid != UInt32(max(0, ProcessInfo.processInfo.processIdentifier))
        else { return }
        wait(pid: pid)
    }()
    #endif

    /// Blocks up to 10s if launched with `RUNE_RELAUNCH_AFTER=<pid>`.
    public static func waitForPrevious() {
        #if !os(WASI)
        _ = waitedForPrevious
        #endif
    }

    public static func spawn(arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
        #if !os(WASI)
        do {
            try start(arguments: arguments, waitVar: afterEnvVar)
        } catch {
            RuneStandardIO.error("rune: couldn't start the app again: \(error)\n")
        }
        #endif
    }

    #if os(macOS) || os(Linux) || os(Windows)
    internal static var handedFrom: UInt32? {
        guard let raw = ProcessInfo.processInfo.environment[handedEnvVar], let pid = UInt32(raw), pid > 0,
              pid != UInt32(bitPattern: ProcessInfo.processInfo.processIdentifier) else { return nil }
        return pid
    }
    #endif

    internal static func spawnHanded(arguments: [String]) {
        #if os(Windows) || os(Linux)
        do {
            try start(arguments: arguments, waitVar: handedEnvVar)
        } catch {
            RuneStandardIO.error("rune: could not restart for a pending launch: \(error)\n")
        }
        #endif
    }

    public static func isProcessAlive(_ pid: UInt32) -> Bool {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        guard let process = pid_t(exactly: pid), process > 0 else { return false }
        return kill(process, 0) == 0 || errno == EPERM
        #elseif os(Windows)
        return rune_win_instance_process_alive(pid) != 0
        #else
        return false
        #endif
    }

    #if !os(WASI)
    private static func wait(pid: UInt32) {
        #if os(Windows)
        guard let process = OpenProcess(DWORD(SYNCHRONIZE), false, pid) else { return }
        defer { CloseHandle(process) }
        _ = WaitForSingleObject(process, DWORD(maxWaitSeconds * 1000))
        #else
        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        while isProcessAlive(pid) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        #endif
    }
    #endif

    #if os(macOS)
    public static func bundleURL(forExecutable executableURL: URL) -> URL? {
        let macosDir = executableURL.deletingLastPathComponent()
        guard macosDir.lastPathComponent == "MacOS" else { return nil }
        let contentsDir = macosDir.deletingLastPathComponent()
        guard contentsDir.lastPathComponent == "Contents" else { return nil }
        let bundle = contentsDir.deletingLastPathComponent()
        return bundle.pathExtension == "app" ? bundle : nil
    }
    #endif

    #if !os(WASI) && !os(iOS) && !os(tvOS) && !os(visionOS)
    private static func start(arguments: [String], waitVar: String) throws {
        guard let exePath = Bundle.main.executablePath ?? CommandLine.arguments.first, !exePath.isEmpty else {
            return
        }
        let exeURL = URL(fileURLWithPath: exePath)
        let pidStr = String(ProcessInfo.processInfo.processIdentifier)

        #if os(macOS)
        if let bundle = bundleURL(forExecutable: exeURL) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            var procArgs = ["-n", bundle.path, "--env", "\(waitVar)=\(pidStr)"]
            if !arguments.isEmpty {
                procArgs.append("--args")
                procArgs.append(contentsOf: arguments)
            }
            proc.arguments = procArgs
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                throw NSError(domain: "RuneRelaunch", code: Int(proc.terminationStatus))
            }
            return
        }
        #endif

        let proc = Process()
        proc.executableURL = exeURL
        proc.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: afterEnvVar)
        env.removeValue(forKey: handedEnvVar)
        env[waitVar] = pidStr
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }
    #elseif os(iOS) || os(tvOS) || os(visionOS)
    private static func start(arguments: [String], waitVar: String) throws {}
    #endif
}

#if os(macOS)
/// Installs `applicationShouldTerminate:` on the current `NSApp.delegate` if not already handled (`quit/mac.rs`).
public enum MacOSQuitHook {
    @MainActor
    private static var hookedClassName: String?

    @MainActor
    public static func install() {
        let app = NSApplication.shared
        guard let delegate = app.delegate else { return }
        let cls: AnyClass = type(of: delegate)
        let clsName = NSStringFromClass(cls)
        if hookedClassName == clsName { return }
        let selector = #selector(NSApplicationDelegate.applicationShouldTerminate(_:))
        if (delegate as AnyObject).responds(to: selector) {
            hookedClassName = clsName
            return
        }
        let imp: @convention(block) (AnyObject, NSApplication) -> NSApplication.TerminateReply = { _, _ in
            _ = QuitLifecycle.send(.start(ending: false, after: .exit))
            return .terminateNow
        }
        let blockImp = imp_implementationWithBlock(imp)
        if class_addMethod(cls, selector, blockImp, "Q@:@") {
            hookedClassName = clsName
            // Refresh AppKit's optional-selector cache.
            app.delegate = delegate
        } else {
            RuneStandardIO.error("rune: could not add applicationShouldTerminate: to the app delegate\n")
        }
    }
}
#endif
