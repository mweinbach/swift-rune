import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif canImport(WinSDK)
import WinSDK
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Per-thread CPU usage snapshot.
public struct ProcessThreadInfo: Sendable, Equatable, Codable {
    public var id: UInt64
    public var name: String
    public var cpuSeconds: Double

    public init(id: UInt64, name: String, cpuSeconds: Double) {
        self.id = id
        self.name = name
        self.cpuSeconds = cpuSeconds
    }
}

/// Lightweight process memory, CPU, and file descriptor usage.
public struct ProcessUsage: Sendable, Equatable, Codable {
    public var residentBytes: UInt64
    public var virtualBytes: UInt64
    public var footprintBytes: UInt64?
    public var footprintPeakBytes: UInt64?
    public var cpuUserSeconds: Double
    public var cpuSystemSeconds: Double
    public var totalCpuSeconds: Double
    public var openFDs: UInt32?

    public init(
        residentBytes: UInt64 = 0,
        virtualBytes: UInt64 = 0,
        footprintBytes: UInt64? = nil,
        footprintPeakBytes: UInt64? = nil,
        cpuUserSeconds: Double = 0,
        cpuSystemSeconds: Double = 0,
        totalCpuSeconds: Double = 0,
        openFDs: UInt32? = nil
    ) {
        self.residentBytes = residentBytes
        self.virtualBytes = virtualBytes
        self.footprintBytes = footprintBytes
        self.footprintPeakBytes = footprintPeakBytes
        self.cpuUserSeconds = cpuUserSeconds
        self.cpuSystemSeconds = cpuSystemSeconds
        self.totalCpuSeconds = totalCpuSeconds
        self.openFDs = openFDs
    }
}

/// Counted heap statistics matching upstream `procwatch::alloc::Heap`.
public struct ProcessHeapStats: Sendable, Equatable, Codable {
    public var liveBytes: Int64
    public var peakBytes: Int64
    public var allocations: UInt64
    public var largestBytes: Int
    public var bigLiveBytes: Int64
    public var bigBlocks: Int64
    public var tags: [String: Int64]

    public init(
        liveBytes: Int64 = 0,
        peakBytes: Int64 = 0,
        allocations: UInt64 = 0,
        largestBytes: Int = 0,
        bigLiveBytes: Int64 = 0,
        bigBlocks: Int64 = 0,
        tags: [String: Int64] = [:]
    ) {
        self.liveBytes = liveBytes
        self.peakBytes = peakBytes
        self.allocations = allocations
        self.largestBytes = largestBytes
        self.bigLiveBytes = bigLiveBytes
        self.bigBlocks = bigBlocks
        self.tags = tags
    }

    /// Tags sorted descending by net bytes (`tags` in `procwatch::alloc::Heap`).
    public var sortedTags: [(name: String, bytes: Int64)] {
        tags.map { ($0.key, $0.value) }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0 < $1.0
        }
    }
}

/// Thread-safe allocation counter matching `procwatch::alloc` semantics
/// (`BIG = 64 MiB`, `TAGS = 16`, per-thread allocation counts/bytes, and `Heap` stats).
public final class ProcessCountingAllocator: @unchecked Sendable {
    public static let shared = ProcessCountingAllocator()
    public static let bigBlockThreshold: Int = 64 << 20
    public static let maxTags: Int = 16

    private struct State {
        var installed: Bool = false
        var liveBytes: Int64 = 0
        var peakBytes: Int64 = 0
        var allocations: UInt64 = 0
        var largestBytes: Int = 0
        var bigLiveBytes: Int64 = 0
        var bigBlocks: Int64 = 0
        var tagOrder: [String] = ["untagged"]
        var tagNetBytes: [String: Int64] = ["untagged": 0]
        var threadTag: [UInt64: String] = [:]
        var threadAllocs: [UInt64: UInt64] = [:]
        var threadAllocatedBytes: [UInt64: UInt64] = [:]
        var threadAllocatedBaseline: [UInt64: UInt64] = [:]
    }

    private let lock = PortableLock(initialState: State())

    public init() {}

    public func tagThread(_ name: String) {
        let tid = Self.currentThreadID()
        lock.withLock { state in
            if state.tagOrder.contains(name) {
                state.threadTag[tid] = name
            } else if state.tagOrder.count < Self.maxTags {
                state.tagOrder.append(name)
                state.tagNetBytes[name] = 0
                state.threadTag[tid] = name
            } else {
                state.threadTag[tid] = "untagged"
            }
        }
    }

    public func recordAlloc(size: Int) {
        guard size >= 0 else { return }
        let tid = Self.currentThreadID()
        lock.withLock { state in
            state.installed = true
            state.allocations &+= 1
            state.threadAllocs[tid, default: 0] &+= 1
            state.threadAllocatedBytes[tid, default: 0] &+= UInt64(size)
            Self.grow(&state, size: size, tid: tid)
        }
    }

    public func recordDealloc(size: Int) {
        guard size >= 0 else { return }
        let tid = Self.currentThreadID()
        lock.withLock { state in
            Self.shrink(&state, size: size, tid: tid)
        }
    }

    public func recordRealloc(oldSize: Int, newSize: Int) {
        guard oldSize >= 0, newSize >= 0 else { return }
        let tid = Self.currentThreadID()
        lock.withLock { state in
            state.installed = true
            state.allocations &+= 1
            state.threadAllocs[tid, default: 0] &+= 1
            state.threadAllocatedBytes[tid, default: 0] &+= UInt64(newSize)
            Self.shrink(&state, size: oldSize, tid: tid)
            Self.grow(&state, size: newSize, tid: tid)
        }
    }

    public func threadAllocations() -> UInt64 {
        let tid = Self.currentThreadID()
        return lock.withLock { $0.threadAllocs[tid] ?? 0 }
    }

    public func threadAllocatedBytes() -> UInt64? {
        let tid = Self.currentThreadID()
        return lock.withLock { state in
            guard state.installed else { return nil }
            return state.threadAllocatedBytes[tid] ?? 0
        }
    }

    /// Bytes this thread asked the allocator for since its previous call (`rune_perf::take_allocated_bytes`).
    /// Returns `nil` when the counting allocator is not installed (`!installed`), and on a thread's first call
    /// (which sets the thread's baseline).
    public func takeAllocatedBytes() -> UInt64? {
        let tid = Self.currentThreadID()
        return lock.withLock { state in
            guard state.installed else { return nil }
            let now = state.threadAllocatedBytes[tid] ?? 0
            let last = state.threadAllocatedBaseline[tid]
            state.threadAllocatedBaseline[tid] = now
            guard let last else { return nil }
            return now &- last
        }
    }

    public func heap() -> ProcessHeapStats? {
        lock.withLock { state in
            guard state.installed else { return nil }
            return ProcessHeapStats(
                liveBytes: state.liveBytes,
                peakBytes: state.peakBytes,
                allocations: state.allocations,
                largestBytes: state.largestBytes,
                bigLiveBytes: state.bigLiveBytes,
                bigBlocks: state.bigBlocks,
                tags: state.tagNetBytes
            )
        }
    }

    public func reset() {
        lock.withLock { $0 = State() }
    }

    private static func grow(_ state: inout State, size: Int, tid: UInt64) {
        let s64 = Int64(size)
        state.liveBytes += s64
        if state.liveBytes > state.peakBytes {
            state.peakBytes = state.liveBytes
        }
        if size > state.largestBytes {
            state.largestBytes = size
        }
        if size >= bigBlockThreshold {
            state.bigLiveBytes += s64
            state.bigBlocks += 1
        }
        let tag = state.threadTag[tid] ?? "untagged"
        state.tagNetBytes[tag, default: 0] += s64
    }

    private static func shrink(_ state: inout State, size: Int, tid: UInt64) {
        let s64 = Int64(size)
        state.liveBytes -= s64
        if size >= bigBlockThreshold {
            state.bigLiveBytes -= s64
            state.bigBlocks -= 1
        }
        let tag = state.threadTag[tid] ?? "untagged"
        state.tagNetBytes[tag, default: 0] -= s64
    }

    private static func currentThreadID() -> UInt64 {
        #if canImport(Darwin)
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        return tid
        #elseif os(Windows)
        return UInt64(GetCurrentThreadId())
        #else
        return Thread.isMainThread ? 1 : UInt64(bitPattern: Int64(ObjectIdentifier(Thread.current).hashValue))
        #endif
    }
}

/// Full process telemetry snapshot including threads and custom memory gauges.
public struct ProcessSnapshot: Sendable, Equatable, Codable {
    public var pid: Int32
    public var timestampMs: UInt64
    public var usage: ProcessUsage
    public var threads: [ProcessThreadInfo]
    public var heap: ProcessHeapStats?
    public var gauges: [String: Int64]

    public init(
        pid: Int32,
        timestampMs: UInt64,
        usage: ProcessUsage,
        threads: [ProcessThreadInfo] = [],
        heap: ProcessHeapStats? = nil,
        gauges: [String: Int64] = [:]
    ) {
        self.pid = pid
        self.timestampMs = timestampMs
        self.usage = usage
        self.threads = threads
        self.heap = heap
        self.gauges = gauges
    }

    /// CPU seconds spent by threads that have since exited.
    public var exitedThreadCpuSeconds: Double {
        let liveSum = threads.reduce(0.0) { $0 + $1.cpuSeconds }
        return max(0.0, usage.totalCpuSeconds - liveSum)
    }

    /// Footprint minus counted heap and all tracked `MemoryGauge`s; `nil` without `heap` or footprint
    /// (`procwatch::Snapshot::unaccounted`).
    public var unaccountedFootprintBytes: Int64? {
        guard let heap, let footprint = usage.footprintBytes else { return nil }
        let gaugeSum = gauges.values.reduce(0, +)
        return Int64(clamping: footprint) - max(0, heap.liveBytes) - gaugeSum
    }

    /// Upstream alias for `unaccountedFootprintBytes`.
    public var unaccountedBytes: Int64? {
        unaccountedFootprintBytes
    }

    /// Sorted gauges descending by byte count (`procwatch::gauges()`).
    public var sortedGauges: [(name: String, bytes: Int64)] {
        gauges.map { ($0.key, $0.value) }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0 < $1.0
        }
    }

    /// Serializes the snapshot to upstream `procwatch::Snapshot::to_json` format.
    public func toJSON() -> String {
        func clean(_ name: String) -> String {
            String(name.unicodeScalars.filter { scalar in
                scalar.value >= 0x20 && scalar != "\"" && scalar != "\\" && scalar.value != 0x7F
            })
        }
        func appendMap(_ out: inout String, _ entries: [(name: String, bytes: Int64)]) {
            out.append("{")
            for (i, entry) in entries.enumerated() {
                if i > 0 { out.append(",") }
                out.append("\"\(clean(entry.name))\":\(entry.bytes)")
            }
            out.append("}")
        }

        let footprint = usage.footprintBytes ?? 0
        let footprintPeak = usage.footprintPeakBytes ?? 0
        var s = String(
            format: "{\"pid\":%d,\"footprint\":%llu,\"footprint_peak\":%llu,\"resident\":%llu,\"cpu_s\":%.3f,\"exited_cpu_s\":%.3f,\"fds\":%u,\"threads\":[",
            pid,
            footprint,
            footprintPeak,
            usage.residentBytes,
            usage.totalCpuSeconds,
            exitedThreadCpuSeconds,
            usage.openFDs ?? 0
        )
        for (i, t) in threads.enumerated() {
            if i > 0 { s.append(",") }
            s.append(String(format: "{\"name\":\"%@\",\"cpu_s\":%.3f}", clean(t.name), t.cpuSeconds))
        }
        s.append("]")
        if let h = heap {
            s.append(
                String(
                    format: ",\"heap\":{\"live\":%lld,\"peak\":%lld,\"allocations\":%llu,\"largest\":%d,\"big_live\":%lld,\"big_blocks\":%lld,\"tags\":",
                    h.liveBytes,
                    h.peakBytes,
                    h.allocations,
                    h.largestBytes,
                    h.bigLiveBytes,
                    h.bigBlocks
                )
            )
            appendMap(&s, h.sortedTags)
            s.append("}")
        }
        s.append(",\"gauges\":")
        appendMap(&s, sortedGauges)
        if let bytes = unaccountedBytes {
            s.append(",\"unaccounted\":\(bytes)")
        }
        s.append("}")
        return s
    }
}

/// Samples process memory, CPU, threads, and file descriptors across Apple, Linux, Android, and Windows.
public enum ProcessSampler {
    /// Samples lightweight memory, CPU, and FD usage for the current process.
    public static func sampleUsage() -> ProcessUsage {
        #if os(macOS)
        var residentBytes: UInt64 = 0
        var virtualBytes: UInt64 = 0
        var cpuUserSeconds: Double = 0
        var cpuSystemSeconds: Double = 0

        var machInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &machInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        if kr == KERN_SUCCESS {
            residentBytes = machInfo.resident_size
            virtualBytes = machInfo.virtual_size
            cpuUserSeconds = Double(machInfo.user_time.seconds)
                + Double(machInfo.user_time.microseconds) / 1_000_000.0
            cpuSystemSeconds = Double(machInfo.system_time.seconds)
                + Double(machInfo.system_time.microseconds) / 1_000_000.0
        }

        let pid = getpid()
        var footprintBytes: UInt64?
        var footprintPeakBytes: UInt64?
        var rusage = rusage_info_v4()
        let rusageResult = withUnsafeMutablePointer(to: &rusage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        if rusageResult == 0 {
            footprintBytes = rusage.ri_phys_footprint
            footprintPeakBytes = max(rusage.ri_phys_footprint, rusage.ri_lifetime_max_phys_footprint)
            if residentBytes == 0 {
                residentBytes = rusage.ri_resident_size
            }
            let tickScale = machTicksToSeconds()
            let rusageUser = Double(rusage.ri_user_time) * tickScale
            let rusageSystem = Double(rusage.ri_system_time) * tickScale
            if rusageUser + rusageSystem > cpuUserSeconds + cpuSystemSeconds {
                cpuUserSeconds = rusageUser
                cpuSystemSeconds = rusageSystem
            }
        }

        let openFDs = sampleOpenFDs(pid: pid)
        return ProcessUsage(
            residentBytes: residentBytes,
            virtualBytes: virtualBytes,
            footprintBytes: footprintBytes,
            footprintPeakBytes: footprintPeakBytes,
            cpuUserSeconds: cpuUserSeconds,
            cpuSystemSeconds: cpuSystemSeconds,
            totalCpuSeconds: cpuUserSeconds + cpuSystemSeconds,
            openFDs: openFDs
        )
        #elseif os(iOS) || os(tvOS) || os(visionOS)
        var residentBytes: UInt64 = 0
        var virtualBytes: UInt64 = 0
        var cpuUserSeconds: Double = 0
        var cpuSystemSeconds: Double = 0

        var machInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &machInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        if kr == KERN_SUCCESS {
            residentBytes = machInfo.resident_size
            virtualBytes = machInfo.virtual_size
            cpuUserSeconds = Double(machInfo.user_time.seconds)
                + Double(machInfo.user_time.microseconds) / 1_000_000.0
            cpuSystemSeconds = Double(machInfo.system_time.seconds)
                + Double(machInfo.system_time.microseconds) / 1_000_000.0
        }
        return ProcessUsage(
            residentBytes: residentBytes,
            virtualBytes: virtualBytes,
            footprintBytes: nil,
            footprintPeakBytes: nil,
            cpuUserSeconds: cpuUserSeconds,
            cpuSystemSeconds: cpuSystemSeconds,
            totalCpuSeconds: cpuUserSeconds + cpuSystemSeconds,
            openFDs: nil
        )
        #elseif os(Linux) || os(Android)
        return sampleLinuxProcUsage()
        #elseif os(Windows)
        return sampleWindowsUsage()
        #else
        return ProcessUsage()
        #endif
    }

    /// Captures a full snapshot of the current process (or another PID owned by this user).
    public static func snapshot(
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        gaugeRegistry: GaugeRegistry = .shared,
        allocator: ProcessCountingAllocator = .shared
    ) -> ProcessSnapshot {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000.0)
        #if os(macOS)
        let isSelf = (pid == getpid())
        let usage: ProcessUsage
        if isSelf {
            usage = sampleUsage()
        } else {
            var rusage = rusage_info_v4()
            let rusageResult = withUnsafeMutablePointer(to: &rusage) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
                }
            }
            if rusageResult == 0 {
                let tickScale = machTicksToSeconds()
                let user = Double(rusage.ri_user_time) * tickScale
                let sys = Double(rusage.ri_system_time) * tickScale
                usage = ProcessUsage(
                    residentBytes: rusage.ri_resident_size,
                    virtualBytes: 0,
                    footprintBytes: rusage.ri_phys_footprint,
                    footprintPeakBytes: rusage.ri_lifetime_max_phys_footprint,
                    cpuUserSeconds: user,
                    cpuSystemSeconds: sys,
                    totalCpuSeconds: user + sys,
                    openFDs: sampleOpenFDs(pid: pid)
                )
            } else {
                usage = ProcessUsage()
            }
        }
        let threads = sampleThreads(pid: pid)
        let gauges = isSelf ? gaugeRegistry.allValues() : [:]
        let heap = isSelf ? allocator.heap() : nil
        return ProcessSnapshot(
            pid: pid,
            timestampMs: nowMs,
            usage: usage,
            threads: threads,
            heap: heap,
            gauges: gauges
        )
        #elseif os(iOS) || os(tvOS) || os(visionOS)
        let isSelf = (pid == getpid())
        let usage = isSelf ? sampleUsage() : ProcessUsage()
        let gauges = isSelf ? gaugeRegistry.allValues() : [:]
        let heap = isSelf ? allocator.heap() : nil
        return ProcessSnapshot(
            pid: pid,
            timestampMs: nowMs,
            usage: usage,
            threads: [],
            heap: heap,
            gauges: gauges
        )
        #elseif os(Linux) || os(Android)
        let isSelf = (pid == getpid())
        let usage = isSelf ? sampleUsage() : ProcessUsage()
        let threads = isSelf ? sampleLinuxThreads() : []
        let gauges = isSelf ? gaugeRegistry.allValues() : [:]
        let heap = isSelf ? allocator.heap() : nil
        return ProcessSnapshot(
            pid: pid,
            timestampMs: nowMs,
            usage: usage,
            threads: threads,
            heap: heap,
            gauges: gauges
        )
        #elseif os(Windows)
        let processID = GetCurrentProcessId()
        let isSelf = UInt32(bitPattern: pid) == processID
        let usage = isSelf ? sampleUsage() : ProcessUsage()
        let gauges = isSelf ? gaugeRegistry.allValues() : [:]
        let heap = isSelf ? allocator.heap() : nil
        return ProcessSnapshot(
            pid: pid,
            timestampMs: nowMs,
            usage: usage,
            threads: isSelf ? sampleWindowsThreads(processID: processID) : [],
            heap: heap,
            gauges: gauges
        )
        #else
        return ProcessSnapshot(pid: pid, timestampMs: nowMs, usage: ProcessUsage())
        #endif
    }

    #if canImport(Darwin)
    /// Reads Darwin malloc zone live/peak/allocated stats via `malloc_zone_statistics`.
    public static func sampleMallocZoneStats() -> (blocksInUse: UInt, sizeInUse: UInt, maxSizeInUse: UInt, sizeAllocated: UInt) {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return (UInt(stats.blocks_in_use), UInt(stats.size_in_use), UInt(stats.max_size_in_use), UInt(stats.size_allocated))
    }
    #endif

    #if os(macOS)
    private static func machTicksToSeconds() -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return 1e-9 }
        return Double(info.numer) / Double(info.denom) / 1_000_000_000.0
    }

    private static func sampleOpenFDs(pid: Int32) -> UInt32? {
        let fdInfoSize = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        let capacity = Int(needed) / fdInfoSize + 4
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let actual = buffer.withUnsafeMutableBytes { raw -> Int32 in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard actual > 0 else { return nil }
        return UInt32(Int(actual) / fdInfoSize)
    }

    private static func sampleThreads(pid: Int32) -> [ProcessThreadInfo] {
        var threadIDs = [UInt64](repeating: 0, count: 512)
        let bytes = threadIDs.withUnsafeMutableBytes { raw -> Int32 in
            proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<UInt64>.stride
        var result: [ProcessThreadInfo] = []
        result.reserveCapacity(count)

        let infoSize = Int32(MemoryLayout<proc_threadinfo>.size)
        for tid in threadIDs.prefix(count) {
            var info = proc_threadinfo()
            let read = withUnsafeMutablePointer(to: &info) { ptr in
                proc_pidinfo(pid, PROC_PIDTHREADINFO, tid, ptr, infoSize)
            }
            guard read == infoSize else { continue }
            let name = withUnsafePointer(to: info.pth_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXTHREADNAMESIZE)) { cStr in
                    String(cString: cStr)
                }
            }
            let cpuSeconds = Double(info.pth_user_time + info.pth_system_time) / 1_000_000_000.0
            result.append(ProcessThreadInfo(id: tid, name: name, cpuSeconds: cpuSeconds))
        }
        return result
    }
    #elseif os(Linux) || os(Android)
    private static func sampleLinuxProcUsage() -> ProcessUsage {
        var residentBytes: UInt64 = 0
        var virtualBytes: UInt64 = 0
        let pageSize = UInt64(max(1, sysconf(Int32(_SC_PAGESIZE))))
        if let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) {
            let parts = statm.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 2, let vsizePages = UInt64(parts[0]), let rssPages = UInt64(parts[1]) {
                virtualBytes = vsizePages * pageSize
                residentBytes = rssPages * pageSize
            }
        }
        if residentBytes == 0, let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) {
            for line in status.split(separator: "\n") where line.hasPrefix("VmRSS:") {
                let digits = line.dropFirst(6).split(whereSeparator: { $0.isWhitespace })
                if let kb = digits.first.flatMap({ UInt64($0) }) {
                    residentBytes = kb * 1024
                }
                break
            }
        }
        var ru = rusage()
        var userSec = 0.0
        var sysSec = 0.0
        #if canImport(Glibc)
        let process = RUSAGE_SELF.rawValue
        #else
        let process = RUSAGE_SELF
        #endif
        if getrusage(process, &ru) == 0 {
            userSec = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1_000_000.0
            sysSec = Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1_000_000.0
        }
        let openFDs = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")).map { UInt32($0.count) }
        return ProcessUsage(
            residentBytes: residentBytes,
            virtualBytes: virtualBytes,
            footprintBytes: residentBytes > 0 ? residentBytes : nil,
            footprintPeakBytes: nil,
            cpuUserSeconds: userSec,
            cpuSystemSeconds: sysSec,
            totalCpuSeconds: userSec + sysSec,
            openFDs: openFDs
        )
    }

    private static func sampleLinuxThreads() -> [ProcessThreadInfo] {
        let ticksPerSecond = sysconf(Int32(_SC_CLK_TCK))
        guard ticksPerSecond > 0,
              let tids = try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/task") else { return [] }

        return tids.compactMap { directory in
            let url = URL(fileURLWithPath: "/proc/self/task/\(directory)/stat")
            guard let tid = UInt64(directory), let stat = try? Data(contentsOf: url),
                  let open = stat.firstIndex(of: UInt8(ascii: "(")),
                  let close = stat.lastIndex(of: UInt8(ascii: ")")), open < close else { return nil }

            // comm (field 2) can itself contain spaces and parentheses. The suffix starts at field 3.
            let fields = stat[(close + 1)...].split(separator: UInt8(ascii: " "), maxSplits: 13)
            guard fields.count >= 13,
                  let userTicks = UInt64(String(decoding: fields[11], as: UTF8.self)),
                  let kernelTicks = UInt64(String(decoding: fields[12], as: UTF8.self)) else { return nil }
            let name = String(decoding: stat[(open + 1)..<close], as: UTF8.self)
            let cpuSeconds = (Double(userTicks) + Double(kernelTicks)) / Double(ticksPerSecond)
            return ProcessThreadInfo(id: tid, name: name, cpuSeconds: cpuSeconds)
        }
    }
    #elseif os(Windows)
    private static func seconds(_ duration: FILETIME) -> Double {
        let ticks = UInt64(duration.dwHighDateTime) << 32 | UInt64(duration.dwLowDateTime)
        return Double(ticks) / 10_000_000
    }

    private static func sampleWindowsThreads(processID: DWORD) -> [ProcessThreadInfo] {
        guard let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPTHREAD), 0),
              snapshot != INVALID_HANDLE_VALUE else { return [] }
        defer { CloseHandle(snapshot) }

        var entry = THREADENTRY32()
        entry.dwSize = DWORD(MemoryLayout<THREADENTRY32>.size)
        guard Thread32First(snapshot, &entry) else { return [] }
        var result: [ProcessThreadInfo] = []
        repeat {
            guard entry.th32OwnerProcessID == processID,
                  let thread = OpenThread(DWORD(THREAD_QUERY_LIMITED_INFORMATION), false, entry.th32ThreadID) else { continue }
            defer { CloseHandle(thread) }
            // A thread ID may have been reused since the snapshot was taken.
            guard GetProcessIdOfThread(thread) == processID else { continue }
            var creation = FILETIME(), exit = FILETIME(), kernel = FILETIME(), user = FILETIME()
            guard GetThreadTimes(thread, &creation, &exit, &kernel, &user) else { continue }

            var name = ""
            var description: PWSTR?
            if GetThreadDescription(thread, &description) >= 0, let description {
                name = String(decodingCString: description, as: UTF16.self)
                LocalFree(description)
            }
            result.append(ProcessThreadInfo(id: UInt64(entry.th32ThreadID), name: name, cpuSeconds: seconds(kernel) + seconds(user)))
        } while Thread32Next(snapshot, &entry)
        return result
    }

    private static func sampleWindowsUsage() -> ProcessUsage {
        let process = GetCurrentProcess()
        var pmc = PROCESS_MEMORY_COUNTERS()
        pmc.cb = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS>.size)
        var residentBytes: UInt64 = 0
        var virtualBytes: UInt64 = 0
        if K32GetProcessMemoryInfo(process, &pmc, pmc.cb) {
            residentBytes = UInt64(pmc.WorkingSetSize)
            virtualBytes = UInt64(pmc.PagefileUsage)
        }
        var creation = FILETIME()
        var exit = FILETIME()
        var kernel = FILETIME()
        var user = FILETIME()
        var userSec = 0.0
        var sysSec = 0.0
        if GetProcessTimes(process, &creation, &exit, &kernel, &user) {
            sysSec = seconds(kernel)
            userSec = seconds(user)
        }
        return ProcessUsage(
            residentBytes: residentBytes,
            virtualBytes: virtualBytes,
            footprintBytes: residentBytes > 0 ? residentBytes : nil,
            footprintPeakBytes: nil,
            cpuUserSeconds: userSec,
            cpuSystemSeconds: sysSec,
            totalCpuSeconds: userSec + sysSec,
            openFDs: nil
        )
    }
    #endif
}

/// Thread-safe byte gauge for memory not visible to the allocator (e.g., GPU textures, pixel buffers).
public final class MemoryGauge: @unchecked Sendable {
    public let name: String
    private let lock = PortableLock(initialState: Int64(0))

    public init(name: String, registry: GaugeRegistry? = .shared) {
        self.name = name
        registry?.register(self)
    }

    public var bytes: Int64 {
        lock.withLock { $0 }
    }

    public func add(_ delta: Int64) {
        lock.withLock { $0 += delta }
    }

    public func subtract(_ delta: Int64) {
        lock.withLock { $0 -= delta }
    }

    public func set(_ value: Int64) {
        lock.withLock { $0 = value }
    }

    /// Adds `bytes` now and subtracts them when the returned `MemoryLease` is released or invalidated.
    public func track(_ bytes: Int64) -> MemoryLease {
        add(bytes)
        return MemoryLease(gauge: self, bytes: bytes)
    }
}

/// RAII lease that subtracts tracked bytes from a `MemoryGauge` on `deinit` or `release()`.
public final class MemoryLease: @unchecked Sendable {
    private let gauge: MemoryGauge
    public let bytes: Int64
    private let released = PortableLock(initialState: false)

    fileprivate init(gauge: MemoryGauge, bytes: Int64) {
        self.gauge = gauge
        self.bytes = bytes
    }

    public func release() {
        let shouldSubtract = released.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        if shouldSubtract {
            gauge.subtract(bytes)
        }
    }

    deinit {
        release()
    }
}

/// Registry of active `MemoryGauge` instances (up to `maxGauges = 64`, matching `procwatch::gauge::GAUGES`).
public final class GaugeRegistry: @unchecked Sendable {
    public static let maxGauges = 64
    public static let shared = GaugeRegistry()

    private let lock = PortableLock(initialState: [String: MemoryGauge]())

    public init() {}

    public func register(_ gauge: MemoryGauge) {
        lock.withLock { gauges in
            if gauges[gauge.name] != nil || gauges.count < Self.maxGauges {
                gauges[gauge.name] = gauge
            }
        }
    }

    public func allValues() -> [String: Int64] {
        lock.withLock { gauges in
            gauges.mapValues { $0.bytes }
        }
    }

    public func sortedValues() -> [(name: String, bytes: Int64)] {
        allValues()
            .map { (name: $0.key, bytes: $0.value) }
            .sorted { $0.bytes > $1.bytes }
    }
}
