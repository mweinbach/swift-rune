import Foundation

/// Top-level convenience namespace for `RunePerf`.
public enum RunePerf {
    public static func sampleUsage() -> ProcessUsage {
        ProcessSampler.sampleUsage()
    }

    public static func snapshot(pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> ProcessSnapshot {
        ProcessSampler.snapshot(pid: pid)
    }
}
