import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Android)
import Android
#elseif os(Windows)
import CRuneWin32
#endif

/// Controls automatic phase timing on the current rendering thread.
/// Set `RUNE_FRAME_PROFILE=1` to capture from process start. The trace CLI enables it too.
public enum FrameProfiling {
    private static let manualOn: UInt = 1
    private static let manualOff: UInt = 2
    private static let manualMask = manualOn | manualOff
    static let budget: UInt = 4
    static let interaction: UInt = 8

    private static let configured: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["RUNE_FRAME_PROFILE"] == "1" || env["RUNE_FRAME_LOG"] != nil { return true }
        #if os(WASI)
        return false
        #else
        return CommandLine.arguments.contains { ["--trace", "--trace-all", "--verbose"].contains($0) }
        #endif
    }()

    #if os(WASI)
    // A WASI Preview 1 instance receives all events on the same thread.
    nonisolated(unsafe) private static var flags: UInt = 0
    #elseif os(Windows)
    private static var flags: UInt {
        get { UInt(rune_win_frame_profile_flags()) }
        set { rune_win_set_frame_profile_flags(UInt32(newValue)) }
    }
    #else
    private static let key: pthread_key_t? = {
        var key = pthread_key_t()
        return pthread_key_create(&key, nil) == 0 ? key : nil
    }()
    private static var flags: UInt {
        get {
            if let key { return UInt(bitPattern: pthread_getspecific(key)) }
            return RuneExecutionContext.locals["rune.frameProfile.flags"] as? UInt ?? 0
        }
        set {
            if let key { pthread_setspecific(key, UnsafeRawPointer(bitPattern: newValue)) }
            else { RuneExecutionContext.locals["rune.frameProfile.flags"] = newValue }
        }
    }
    #endif

    private static func enabled(for flags: UInt) -> Bool {
        flags & manualOn != 0 || (flags & manualOff == 0 && configured)
    }

    /// Enable or disable automatic phase timing for this thread's subsequent frames.
    public static var isEnabled: Bool {
        get { enabled(for: flags) }
        set { flags = (flags & ~manualMask) | (newValue ? manualOn : manualOff) }
    }

    /// Measure a synchronous workload, restoring the thread's previous setting on return.
    public static func withRecording<T>(_ enabled: Bool = true, _ body: () throws -> T) rethrows -> T {
        let previous = flags & manualMask
        isEnabled = enabled
        defer { flags = (flags & ~manualMask) | previous }
        return try body()
    }

    static func armOnFirstRead() {
        let saved = flags
        if saved & manualMask == 0 { flags = saved | manualOn }
    }

    static func observe(_ flag: UInt, _ on: Bool) {
        flags = on ? flags | flag : flags & ~flag
    }

    enum Mode { case off, wallOnly, full }
    @inline(__always) static var automaticMode: Mode {
        let saved = flags
        if enabled(for: saved) { return .full }
        return saved & (budget | interaction) == 0 ? .off : .wallOnly
    }
}
