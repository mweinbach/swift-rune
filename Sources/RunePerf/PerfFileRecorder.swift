import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Bounded nonblocking URL channel matching `std::sync::mpsc::sync_channel::<PathBuf>` for
/// `PerfConfig.incidents(channel:)`.
public final class PerfIncidentChannel: @unchecked Sendable {
    public let capacity: Int
    private let lock = NSLock()
    private var buffer: [URL] = []
    private let available = DispatchSemaphore(value: 0)

    public init(capacity: Int = 16) {
        self.capacity = max(1, capacity)
    }

    @discardableResult
    public func trySend(_ url: URL) -> Bool {
        lock.lock()
        guard buffer.count < capacity else {
            lock.unlock()
            return false
        }
        buffer.append(url)
        lock.unlock()
        available.signal()
        return true
    }

    public func tryReceive() -> URL? {
        guard available.wait(timeout: .now()) == .success else { return nil }
        lock.lock()
        let out = buffer.isEmpty ? nil : buffer.removeFirst()
        lock.unlock()
        return out
    }

    public func receive(timeout: TimeInterval) -> URL? {
        let deadline: DispatchTime = .now() + .nanoseconds(Int(max(0, timeout) * 1_000_000_000))
        guard available.wait(timeout: deadline) == .success else { return nil }
        lock.lock()
        let out = buffer.isEmpty ? nil : buffer.removeFirst()
        lock.unlock()
        return out
    }
}

/// Configuration for `PerfFileRecorder` (`crates/rune-perf/src/lib.rs::Config`).
/// One process/launch per directory; separate directories should be used for dev and captures.
public struct PerfConfig: Sendable {
    public var directory: URL
    public var app: String
    public var build: String
    public var incidentHandler: (@Sendable (URL) -> Void)?
    /// Optional bounded channel matching `sync_channel` (`Config::incidents`).
    public var incidentChannel: PerfIncidentChannel?
    /// Bounded notification queue capacity when using `incidentHandler` (`nil` = unbounded / direct).
    public var incidentQueueCapacity: Int?

    public init(
        directory: URL,
        app: String,
        build: String = "",
        incidentQueueCapacity: Int? = nil,
        incidentHandler: (@Sendable (URL) -> Void)? = nil,
        incidentChannel: PerfIncidentChannel? = nil
    ) {
        self.directory = directory
        self.app = app
        self.build = build
        self.incidentQueueCapacity = incidentQueueCapacity
        self.incidentHandler = incidentHandler
        self.incidentChannel = incidentChannel
    }

    public func build(_ build: String) -> PerfConfig {
        var copy = self
        copy.build = build
        return copy
    }

    public func incidents(capacity: Int = 16, handler: @escaping @Sendable (URL) -> Void) -> PerfConfig {
        var copy = self
        copy.incidentQueueCapacity = max(1, capacity)
        copy.incidentHandler = handler
        return copy
    }

    public func incidents(channel: PerfIncidentChannel) -> PerfConfig {
        var copy = self
        copy.incidentChannel = channel
        return copy
    }
}

public enum PerfRecorderError: Error, Sendable, Equatable, CustomStringConvertible {
    case identityTooLong
    case io(String)

    public var description: String {
        switch self {
        case .identityTooLong:
            return "app/build identity too long"
        case .io(let message):
            return message
        }
    }
}

/// Bounded local diagnostics writer (`crates/rune-perf/src/recorder.rs` & `store.rs`).
///
/// Owns one background writer thread: `record(_:)` is nonblocking with a 256-sample queue.
/// Calling `shutdown()` drains queued samples and joins the writer off the UI thread; `deinit`
/// cancels lock waits without blocking.
public final class PerfFileRecorder: @unchecked Sendable {
    public static let queueCapacity = 256
    public static let logBytesLimit: UInt64 = 4 << 20
    public static let incidentBytesLimit = 256 << 10
    public static let quietFlushSeconds: TimeInterval = 2.0
    public static let checkEverySeconds: TimeInterval = 2.0
    public static let memoryLogIntervalMs: UInt64 = 30_000
    public static let maxBufferedMemoryLines = 20
    public static let incidentSlots = 16

    final class SharedHealth: @unchecked Sendable {
        let lock = NSLock()
        var dropped: UInt64 = 0
        var errors: UInt64 = 0
        var stop: Bool = false

        func incrementDropped() {
            lock.lock()
            dropped += 1
            lock.unlock()
        }

        func incrementErrors() -> UInt64 {
            lock.lock()
            errors += 1
            let v = errors
            lock.unlock()
            return v
        }

        func setStop() {
            lock.lock()
            stop = true
            lock.unlock()
        }

        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stop
        }

        var droppedCount: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return dropped
        }

        var errorCount: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return errors
        }
    }

    fileprivate final class BoundedSampleQueue: @unchecked Sendable {
        private let condition = NSCondition()
        private var buffer: [FrameSample] = []
        private var closed = false
        private let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
            self.buffer.reserveCapacity(capacity)
        }

        func trySend(_ sample: FrameSample) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            guard !closed, buffer.count < capacity else { return false }
            buffer.append(sample)
            condition.signal()
            return true
        }

        func close() {
            condition.lock()
            closed = true
            condition.broadcast()
            condition.unlock()
        }

        enum RecvResult {
            case sample(FrameSample)
            case timeout
            case disconnected
        }

        func receive(deadline: Date?) -> RecvResult {
            condition.lock()
            defer { condition.unlock() }
            while buffer.isEmpty {
                if closed {
                    return .disconnected
                }
                if let deadline {
                    if !condition.wait(until: deadline) && buffer.isEmpty {
                        return closed ? .disconnected : .timeout
                    }
                } else {
                    condition.wait()
                }
            }
            return .sample(buffer.removeFirst())
        }
    }

    private let startNanos: UInt64
    private let queue: BoundedSampleQueue
    private let health: SharedHealth
    private let doneSemaphore: DispatchSemaphore?
    private let stateLock = NSLock()
    private var shutDown = false

    private init(
        startNanos: UInt64,
        queue: BoundedSampleQueue,
        health: SharedHealth,
        doneSemaphore: DispatchSemaphore?
    ) {
        self.startNanos = startNanos
        self.queue = queue
        self.health = health
        self.doneSemaphore = doneSemaphore
    }

    deinit {
        health.setStop()
        queue.close()
    }

    /// Starts the bounded background writer for `config`.
    public static func start(config: PerfConfig) throws -> PerfFileRecorder {
        if config.app.utf8.count > 128 || config.build.utf8.count > 256 {
            throw PerfRecorderError.identityTooLong
        }
        let startNanos = DispatchTime.now().uptimeNanoseconds
        let queue = BoundedSampleQueue(capacity: queueCapacity)
        let health = SharedHealth()
        let doneSemaphore = DispatchSemaphore(value: 0)

        let thread = Thread {
            defer { doneSemaphore.signal() }
            Self.runStore(config: config, queue: queue, startNanos: startNanos, health: health)
        }
        thread.name = "rune-perf"
        thread.start()

        return PerfFileRecorder(
            startNanos: startNanos,
            queue: queue,
            health: health,
            doneSemaphore: doneSemaphore
        )
    }

    /// Nonblocking bounded send (`recorder.rs::record`). Returns `false` when full or stopped.
    @discardableResult
    public func record(_ frame: FrameSample) -> Bool {
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = nowNanos >= startNanos ? (nowNanos - startNanos) / 1_000_000 : 0
        var stamped = frame
        stamped.timestampMs = elapsedMs
        if queue.trySend(stamped) {
            return true
        }
        health.incrementDropped()
        return false
    }

    public var droppedSamples: UInt64 {
        health.droppedCount
    }

    public var writeErrors: UInt64 {
        health.errorCount
    }

    /// Cancels lock waits, drains queued frames if active, and waits for the writer thread.
    public func shutdown() {
        stateLock.lock()
        let already = shutDown
        shutDown = true
        stateLock.unlock()
        guard !already else { return }

        health.setStop()
        queue.close()
        doneSemaphore?.wait()
    }

    // MARK: - Store Driver & Lock Acquisition

    private static func runStore(
        config: PerfConfig,
        queue: BoundedSampleQueue,
        startNanos: UInt64,
        health: SharedHealth
    ) {
        do {
            try FileManager.default.createDirectory(at: config.directory, withIntermediateDirectories: true)
            let lockURL = config.directory.appendingPathComponent(".perf.lock")
            let fd = openFileLock(at: lockURL)
            guard fd >= 0 else {
                _ = health.incrementErrors()
                return
            }
            defer { close(fd) }

            guard acquireLock(fd: fd, health: health) else { return }

            let writer = PerfStoreWriter(config: config, startNanos: startNanos, health: health)
            var lastChecked: Date?
            while true {
                switch queue.receive(deadline: writer.flushDue) {
                case .sample(let sample):
                    writer.accept(sample)
                    let now = Date()
                    if lastChecked == nil || now.timeIntervalSince(lastChecked!) >= checkEverySeconds {
                        writer.check()
                        lastChecked = now
                    }
                case .timeout:
                    writer.flush()
                case .disconnected:
                    writer.check()
                    writer.flush()
                    if writer.wroteAnything {
                        writer.writeSnapshot()
                    }
                    return
                }
            }
        } catch {
            _ = health.incrementErrors()
        }
    }

    private static func openFileLock(at url: URL) -> Int32 {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        return url.path.withCString { cPath in
            open(cPath, O_CREAT | O_RDWR, 0o644)
        }
        #else
        return -1
        #endif
    }

    private static func acquireLock(fd: Int32, health: SharedHealth) -> Bool {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return true
            }
            let err = errno
            if health.isStopped {
                return false
            }
            if err == EINTR {
                continue
            }
            if err == EWOULDBLOCK || err == EAGAIN {
                Thread.sleep(forTimeInterval: 0.1)
                if health.isStopped {
                    return false
                }
                continue
            }
            _ = health.incrementErrors()
            return false
        }
        #else
        return !health.isStopped
        #endif
    }
}

/// Rotating append-only JSONL log writer (`crates/rune-perf/src/store.rs::Log`).
final class PerfRotatingLog {
    let directory: URL
    let fileName: String
    let limitBytes: UInt64
    private var handle: FileHandle?
    private var currentSize: UInt64 = 0

    init(directory: URL, fileName: String = "perf.log", limitBytes: UInt64 = PerfFileRecorder.logBytesLimit) {
        self.directory = directory
        self.fileName = fileName
        self.limitBytes = limitBytes
    }

    deinit {
        try? handle?.close()
    }

    func resetHandleForTest() {
        try? handle?.close()
        handle = nil
        currentSize = 0
    }

    func append(jsonObject: [String: Any]) throws {
        var line = try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
        line.append(0x0A)
        if UInt64(line.count) > limitBytes {
            throw PerfRecorderError.io("performance record exceeds log limit")
        }
        let logURL = directory.appendingPathComponent(fileName)
        let rotatedURL = directory.appendingPathComponent("\(fileName).1")

        if handle == nil {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let h = try FileHandle(forUpdating: logURL)
            let attrs = try FileManager.default.attributesOfItem(atPath: logURL.path)
            currentSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            try h.seekToEnd()
            handle = h
        }

        if currentSize + UInt64(line.count) > limitBytes {
            try? handle?.close()
            handle = nil
            if FileManager.default.fileExists(atPath: rotatedURL.path) {
                try FileManager.default.removeItem(at: rotatedURL)
            }
            if FileManager.default.fileExists(atPath: logURL.path) {
                try FileManager.default.moveItem(at: logURL, to: rotatedURL)
            }
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let h = try FileHandle(forUpdating: logURL)
            currentSize = 0
            handle = h
        }

        guard let h = handle else { return }
        do {
            try h.write(contentsOf: line)
            currentSize += UInt64(line.count)
        } catch {
            try? handle?.close()
            handle = nil
            throw error
        }
    }
}

/// Internal writer implementing `crates/rune-perf/src/store.rs::Writer`.
final class PerfStoreWriter {
    private let config: PerfConfig
    private let startNanos: UInt64
    private let health: PerfFileRecorder.SharedHealth
    private let launch: String
    private let startedAtMs: UInt64
    private let stats = PerfRecorder(capacity: 600, windowMs: 60_000)
    private let detector = IncidentDetector()
    private let log: PerfRotatingLog

    private var memoryAtMs: UInt64 = 0
    private(set) var incidentsCount: UInt64 = 0
    private(set) var hookDroppedCount: UInt64 = 0
    private var lines: [[String: Any]] = []
    private var pendingIncidents: [(name: String, payload: [String: Any])] = []
    private(set) var flushDue: Date?
    private(set) var wroteAnything = false

    private final class HookGate: @unchecked Sendable {
        let lock = NSLock()
        var inFlightCount = 0

        func tryEnter(capacity: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard inFlightCount < capacity else { return false }
            inFlightCount += 1
            return true
        }

        func leave() {
            lock.lock()
            inFlightCount = max(0, inFlightCount - 1)
            lock.unlock()
        }
    }

    private let hookGate = HookGate()
    private let hookQueue = DispatchQueue(label: "rune.perf.incident-hook", qos: .utility)

    init(
        config: PerfConfig,
        startNanos: UInt64,
        health: PerfFileRecorder.SharedHealth
    ) {
        self.config = config
        self.startNanos = startNanos
        self.health = health
        let elapsedMs = Self.elapsedMs(since: startNanos)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000.0)
        self.startedAtMs = nowMs >= elapsedMs ? nowMs - elapsedMs : nowMs
        self.launch = "\(ProcessInfo.processInfo.processIdentifier)-\(self.startedAtMs)"
        self.log = PerfRotatingLog(directory: config.directory)
    }

    func accept(_ sample: FrameSample) {
        if stats.accept(sample) {
            lines.append([
                "kind": "frame",
                "launch": launch,
                "frame": Self.sampleDictionary(sample),
            ])
            flushDue = Date().addingTimeInterval(PerfFileRecorder.quietFlushSeconds)
        }
        let recent = stats.recentFrames
        if let incident = detector.detectFrame(
            sample: sample,
            recent: recent,
            windowId: sample.window,
            sourceId: sample.source
        ) {
            recordIncident(nowMs: sample.timestampMs, incident: incident, frameSample: sample)
        }
    }

    func check() {
        let now = Self.elapsedMs(since: startNanos)
        stats.prune(nowMs: now)
        let usage = ProcessSampler.sampleUsage()
        for incident in detector.detectProcess(nowMs: now, usage: usage) {
            recordIncident(nowMs: now, incident: incident, frameSample: nil)
        }
        if now >= memoryAtMs {
            let memCount = lines.filter { ($0["kind"] as? String) == "memory" }.count
            if memCount >= PerfFileRecorder.maxBufferedMemoryLines,
               let firstMem = lines.firstIndex(where: { ($0["kind"] as? String) == "memory" }) {
                lines.remove(at: firstMem)
            }
            lines.append([
                "kind": "memory",
                "at_ms": now,
                "launch": launch,
                "memory": Self.usageDictionary(usage),
            ])
            memoryAtMs = now + PerfFileRecorder.memoryLogIntervalMs
        }
    }

    func flush() {
        flushDue = nil
        let hasFindings = lines.contains { ($0["kind"] as? String) != "memory" } || !pendingIncidents.isEmpty
        guard hasFindings else { return }

        wroteAnything = true
        let batchLines = lines
        lines.removeAll()
        for line in batchLines {
            do {
                try log.append(jsonObject: line)
            } catch {
                _ = health.incrementErrors()
            }
        }

        let batchIncidents = pendingIncidents
        pendingIncidents.removeAll()
        for item in batchIncidents {
            do {
                try Self.writeAtomicJSON(
                    directory: config.directory,
                    name: item.name,
                    object: item.payload,
                    limit: PerfFileRecorder.incidentBytesLimit
                )
                notifyHook(url: config.directory.appendingPathComponent(item.name))
            } catch {
                _ = health.incrementErrors()
            }
        }

        if !batchIncidents.isEmpty {
            writeSnapshot()
        }
    }

    func writeSnapshot() {
        let now = Self.elapsedMs(since: startNanos)
        let usage = ProcessSampler.sampleUsage()
        let frames = statsDictionary()
        let uiAllocPresent = !(frames["ui_allocated_bytes"] is NSNull)
        let inputToFramePresent = !(frames["input_to_frame_ms"] is NSNull)
        let gpuPresent = !(frames["gpu_ms"] is NSNull)

        let payload: [String: Any] = [
            "schema": 1,
            "recorder_version": "0.1.0",
            "app": config.app,
            "version": config.build,
            "launch": launch,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "started_at_ms": startedAtMs,
            "updated_at_ms": UInt64(Date().timeIntervalSince1970 * 1000.0),
            "uptime_ms": now,
            "scope": "work_ms = update + compositor wall time; input_to_frame_ms ends at encoding, not presentation; allocation requests are not retained heap",
            "slow_ms": IncidentDetector.defaultSlowFrameMs,
            "large_bytes": 8 << 20,
            "memory": Self.usageDictionary(usage),
            "capabilities": [
                "process_memory": usage.residentBytes > 0,
                "file_descriptors": usage.openFDs != nil,
                "ui_allocations": uiAllocPresent,
                "input_to_frame": inputToFramePresent,
                "gpu_timestamps": gpuPresent,
                "presentation": false,
            ],
            "dropped_samples": health.droppedCount,
            "write_errors": health.errorCount,
            "incidents": incidentsCount,
            "incidents_suppressed": detector.suppressedCount,
            "incident_notifications_dropped": hookDroppedCount,
            "frames": frames,
        ]
        do {
            try Self.writeAtomicJSON(
                directory: config.directory,
                name: "perf.json",
                object: payload,
                limit: PerfFileRecorder.incidentBytesLimit
            )
        } catch {
            _ = health.incrementErrors()
        }
    }

    private func recordIncident(nowMs: UInt64, incident: Incident, frameSample: FrameSample?) {
        guard detector.admit(nowMs: nowMs, incident: incident) else { return }
        let slot = Int(incidentsCount % UInt64(PerfFileRecorder.incidentSlots))
        let name = String(format: "perf-incident-%02d.json", slot)
        incidentsCount += 1

        let before = pendingIncidents.count
        pendingIncidents.removeAll { $0.name == name }
        if pendingIncidents.count < before, (config.incidentHandler != nil || config.incidentChannel != nil) {
            hookDroppedCount += 1
        }

        let evidenceJSON = Self.structuredEvidence(for: incident, frameSample: frameSample)

        let payload: [String: Any] = [
            "schema": 1,
            "app": config.app,
            "build": config.build,
            "launch": launch,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "created_at_ms": UInt64(Date().timeIntervalSince1970 * 1000.0),
            "rule": incident.kind.rawValue,
            "window": incident.window,
            "source": incident.source as Any? ?? NSNull(),
            "evidence": evidenceJSON,
            "history": stats.recentFrames.map(Self.sampleDictionary),
            "dropped_samples": health.droppedCount,
        ]
        pendingIncidents.append((name: name, payload: payload))
        flushDue = Date().addingTimeInterval(PerfFileRecorder.quietFlushSeconds)
    }

    internal static func structuredEvidence(for incident: Incident, frameSample: FrameSample?) -> [String: Any] {
        switch incident.kind {
        case .longFrames, .stall:
            let frameObj: Any = frameSample.map(Self.sampleDictionary) ?? incident.evidence
            return [
                "frame": frameObj,
                "confidence": incident.evidence["confidence"] ?? "measured work; cause unknown",
                "next_measurement": incident.evidence["next_measurement"] ?? "capture update/compositor phases for this window and source",
            ]
        case .memoryGrowth, .fdGrowth:
            let floors: [UInt64] = (incident.evidence["minute_floors"] ?? "")
                .split(separator: ",")
                .compactMap { UInt64($0) }
            let growth = UInt64(incident.evidence["growth_bytes"] ?? incident.evidence["growth_fds"] ?? "") ?? 0
            return [
                "minute_floors": floors,
                "growth": growth,
                "confidence": incident.evidence["confidence"] ?? "suspected growth, not a proven leak",
                "next_measurement": incident.evidence["next_measurement"] ?? "repeat view open/close cycles; check whether footprint and descriptors plateau",
            ]
        }
    }

    private func notifyHook(url: URL) {
        if let channel = config.incidentChannel {
            if !channel.trySend(url) {
                hookDroppedCount += 1
            }
        }
        guard let handler = config.incidentHandler else { return }
        if let cap = config.incidentQueueCapacity {
            guard hookGate.tryEnter(capacity: cap) else {
                hookDroppedCount += 1
                return
            }
            let gate = hookGate
            hookQueue.async {
                defer { gate.leave() }
                handler(url)
            }
            return
        }
        handler(url)
    }

    private func statsDictionary() -> [String: Any] {
        func statJSON(_ s: PercentileStats?) -> Any {
            guard let s else { return NSNull() }
            return ["p50": s.p50, "p95": s.p95, "max": s.max, "count": s.count]
        }
        let recent = stats.recentFrames
        return [
            "total": stats.totalFrames,
            "anomalies": stats.anomalyCount,
            "log_suppressed": stats.logSuppressedCount,
            "lifetime_max_work_ms": stats.lifetimeMaxWorkMs as Any? ?? NSNull(),
            "lifetime_max_ui_allocated_bytes": stats.lifetimeMaxAllocatedBytes as Any? ?? NSNull(),
            "recent_count": recent.count,
            "timed_count": stats.timedCount,
            "window_ms": stats.windowMs,
            "capacity": stats.capacity,
            "work_ms": statJSON(stats.workMsStats),
            "ui_allocated_bytes": statJSON(stats.allocatedBytesStats),
            "input_to_frame_ms": statJSON(stats.inputToFrameMsStats),
            "gpu_ms": statJSON(stats.gpuMsStats),
            "latest": recent.last.map(Self.sampleDictionary) as Any? ?? NSNull(),
            "recent_anomalies": stats.recentAnomalies.map(Self.sampleDictionary),
        ]
    }

    static func writeAtomicJSON(directory: URL, name: String, object: [String: Any], limit: Int) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if data.count > limit {
            throw PerfRecorderError.io("performance record exceeds byte cap")
        }
        let tmp = directory.appendingPathComponent(".\(name).tmp")
        let dest = directory.appendingPathComponent(name)
        try data.write(to: tmp, options: [])
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
    }

    private static func sampleDictionary(_ s: FrameSample) -> [String: Any] {
        [
            "at_ms": s.timestampMs,
            "window": s.window,
            "seq": s.seq,
            "outcome": s.outcome.rawValue,
            "update_ms": s.updateMs as Any? ?? NSNull(),
            "render_ms": s.renderMs as Any? ?? NSNull(),
            "work_ms": s.workMs as Any? ?? NSNull(),
            "input_to_frame_ms": s.inputToFrameMs as Any? ?? NSNull(),
            "gpu_ms": s.gpuMs as Any? ?? NSNull(),
            "ui_allocated_bytes": s.allocatedBytes as Any? ?? NSNull(),
            "source": s.source as Any? ?? NSNull(),
        ]
    }

    private static func usageDictionary(_ u: ProcessUsage) -> [String: Any] {
        [
            "resident_bytes": u.residentBytes,
            "footprint_bytes": u.footprintBytes as Any? ?? NSNull(),
            "peak_footprint_bytes": u.footprintPeakBytes as Any? ?? NSNull(),
            "open_fds": u.openFDs as Any? ?? NSNull(),
        ]
    }

    private static func elapsedMs(since startNanos: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= startNanos ? (now - startNanos) / 1_000_000 : 0
    }
}
