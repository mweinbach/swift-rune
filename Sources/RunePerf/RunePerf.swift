import Foundation

/// Top-level convenience namespace for `RunePerf`.
public enum RunePerf {
    /// How long the recorder waits with nothing to write before `PerfConfig.onIdle(_:)` runs (`IDLE`).
    public static let idleDuration: Duration = .seconds(10)

    /// Minimum gap between two `PerfConfig.onIdle(_:)` runs on the recorder thread (`IDLE_MIN_GAP`).
    public static let idleMinGap: Duration = .seconds(180)

    public static func sampleUsage() -> ProcessUsage {
        ProcessSampler.sampleUsage()
    }

    #if os(WASI)
    public static func snapshot(pid: Int32 = 0) -> ProcessSnapshot? {
        ProcessSampler.snapshot(pid: pid)
    }
    #else
    public static func snapshot(pid: Int32 = ProcessSampler.currentProcessID) -> ProcessSnapshot {
        ProcessSampler.snapshot(pid: pid)
    }
    #endif
}
