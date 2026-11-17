import Foundation

/// Top-level convenience namespace for `RunePerf`.
public enum RunePerf {
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
