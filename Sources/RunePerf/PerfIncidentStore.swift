import Foundation

/// Categories of performance incidents detected by `IncidentDetector` (`crates/rune-perf/src/incident.rs`).
public enum IncidentKind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case longFrames = "long-frames"
    case stall = "frame-stall"
    case memoryGrowth = "memory-growth"
    case fdGrowth = "fd-growth"
}

/// A detected performance incident record.
public struct Incident: Sendable, Equatable, Codable {
    public var schema: Int
    public var kind: IncidentKind
    public var window: UInt64
    public var source: UInt64?
    public var severity: Double
    public var timestampMs: UInt64
    public var message: String
    public var evidence: [String: String]

    public init(
        schema: Int = 1,
        kind: IncidentKind,
        window: UInt64 = 0,
        source: UInt64? = nil,
        severity: Double,
        timestampMs: UInt64,
        message: String = "",
        evidence: [String: String] = [:]
    ) {
        self.schema = schema
        self.kind = kind
        self.window = window
        self.source = source
        self.severity = severity
        self.timestampMs = timestampMs
        self.message = message
        self.evidence = evidence
    }
}

/// Summary statistics for a `PerfIncidentStore`.
public struct IncidentStoreStats: Sendable, Equatable, Codable {
    public var totalCount: Int
    public var byKind: [IncidentKind: Int]
    public var oldestTimestampMs: UInt64?
    public var newestTimestampMs: UInt64?
    public var fileSizeBytes: UInt64

    public init(
        totalCount: Int = 0,
        byKind: [IncidentKind: Int] = [:],
        oldestTimestampMs: UInt64? = nil,
        newestTimestampMs: UInt64? = nil,
        fileSizeBytes: UInt64 = 0
    ) {
        self.totalCount = totalCount
        self.byKind = byKind
        self.oldestTimestampMs = oldestTimestampMs
        self.newestTimestampMs = newestTimestampMs
        self.fileSizeBytes = fileSizeBytes
    }
}

/// Warning-only incident detector with rate-limiting and deduplication (`crates/rune-perf/src/incident.rs`).
public final class IncidentDetector: @unchecked Sendable {
    public static let globalCooldownMs: UInt64 = 2_000
    public static let sameKeyCooldownMs: UInt64 = 60_000
    public static let severityEscalationFactor: Double = 1.25
    public static let defaultSlowFrameMs: Double = 16.7
    public static let defaultStallMs: Double = 250.0

    private struct SentRecord {
        var kind: IncidentKind
        var window: UInt64
        var source: UInt64?
        var atMs: UInt64
        var severity: Double
    }

    private struct MinuteFloor {
        var minute: UInt64
        var memory: UInt64?
        var fds: UInt64?
    }

    private let lock = NSLock()
    private var sent: [SentRecord] = []
    private var floors: [MinuteFloor] = []
    private var lastSentMs: UInt64?
    public private(set) var suppressedCount: UInt64 = 0

    public init() {}

    /// Evaluate a frame sample against recent samples for stall or sustained long-frame incidents.
    public func detectFrame(
        sample: FrameSample,
        recent: [FrameSample],
        windowId: UInt64 = 0,
        sourceId: UInt64? = nil,
        slowThresholdMs: Double = IncidentDetector.defaultSlowFrameMs,
        stallThresholdMs: Double = IncidentDetector.defaultStallMs
    ) -> Incident? {
        let work = (sample.updateMs ?? 0) + (sample.renderMs ?? 0)
        let kind: IncidentKind
        if work >= stallThresholdMs {
            kind = .stall
        } else if work >= slowThresholdMs {
            let slowCount = recent.reversed()
                .prefix(while: { sample.timestampMs >= $0.timestampMs && sample.timestampMs - $0.timestampMs <= 1_000 })
                .filter { (($0.updateMs ?? 0) + ($0.renderMs ?? 0)) >= slowThresholdMs }
                .prefix(3)
                .count
            guard slowCount >= 3 else { return nil }
            kind = .longFrames
        } else {
            return nil
        }

        return Incident(
            kind: kind,
            window: windowId,
            source: sourceId,
            severity: work,
            timestampMs: sample.timestampMs,
            message: "\(kind.rawValue): \(String(format: "%.2f", work)) ms",
            evidence: [
                "work_ms": String(format: "%.3f", work),
                "confidence": "measured work; cause unknown",
            ]
        )
    }

    /// Evaluate process usage across 5 completed minute floors for monotonic memory or FD growth.
    public func detectProcess(nowMs: UInt64, usage: ProcessUsage) -> [Incident] {
        lock.lock()
        defer { lock.unlock() }

        let minute = nowMs / 60_000
        let footprint = usage.footprintBytes.flatMap { $0 > 0 ? $0 : nil }
        let fds = usage.openFDs.map { UInt64($0) }

        if let last = floors.last, minute > last.minute + 1 {
            floors.removeAll()
        }

        if let lastIdx = floors.indices.last, floors[lastIdx].minute == minute {
            if let curMem = floors[lastIdx].memory, let newMem = footprint {
                floors[lastIdx].memory = min(curMem, newMem)
            } else {
                floors[lastIdx].memory = nil
            }
            if let curFd = floors[lastIdx].fds, let newFd = fds {
                floors[lastIdx].fds = min(curFd, newFd)
            } else {
                floors[lastIdx].fds = nil
            }
        } else {
            if floors.count == 6 {
                floors.removeFirst()
            }
            floors.append(MinuteFloor(minute: minute, memory: footprint, fds: fds))
        }

        guard floors.count >= 6 else { return [] }

        var out: [Incident] = []
        let completed = floors.prefix(5)

        let memValues = completed.compactMap(\.memory)
        if memValues.count == 5,
           zip(memValues, memValues.dropFirst()).allSatisfy({ $0.1 > $0.0 }) {
            let delta = memValues[4] - memValues[0]
            if delta >= (64 << 20) && Double(delta) >= Double(memValues[0]) * 0.2 {
                out.append(Incident(
                    kind: .memoryGrowth,
                    window: 0,
                    source: nil,
                    severity: Double(memValues[4]),
                    timestampMs: nowMs,
                    message: "memory-growth: +\(delta) bytes over 5m",
                    evidence: [
                        "growth_bytes": "\(delta)",
                        "confidence": "suspected growth, not a proven leak",
                    ]
                ))
            }
        }

        let fdValues = completed.compactMap(\.fds)
        if fdValues.count == 5,
           zip(fdValues, fdValues.dropFirst()).allSatisfy({ $0.1 > $0.0 }) {
            let delta = fdValues[4] - fdValues[0]
            if delta >= 32 && Double(delta) >= Double(fdValues[0]) * 0.2 {
                out.append(Incident(
                    kind: .fdGrowth,
                    window: 0,
                    source: nil,
                    severity: Double(fdValues[4]),
                    timestampMs: nowMs,
                    message: "fd-growth: +\(delta) fds over 5m",
                    evidence: [
                        "growth_fds": "\(delta)",
                        "confidence": "suspected growth, not a proven leak",
                    ]
                ))
            }
        }

        return out
    }

    /// Rate-limiting and deduplication admission check.
    /// Rejects if within 2s of any sent incident, or within 60s of the same `(kind, window, source)`
    /// unless severity escalated by at least 1.25x.
    public func admit(nowMs: UInt64, incident: Incident) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let old = sent.first {
            $0.kind == incident.kind && $0.window == incident.window && $0.source == incident.source
        }
        if let last = lastSentMs, nowMs >= last && (nowMs - last) < Self.globalCooldownMs {
            suppressedCount += 1
            return false
        }
        if let old {
            let withinCooldown = nowMs >= old.atMs && (nowMs - old.atMs) < Self.sameKeyCooldownMs
            let notEscalated = incident.severity < old.severity * Self.severityEscalationFactor
            if withinCooldown && notEscalated {
                suppressedCount += 1
                return false
            }
        }

        sent.removeAll {
            $0.kind == incident.kind && $0.window == incident.window && $0.source == incident.source
        }
        if sent.count == 64 {
            sent.removeFirst()
        }
        sent.append(SentRecord(
            kind: incident.kind,
            window: incident.window,
            source: incident.source,
            atMs: nowMs,
            severity: incident.severity
        ))
        lastSentMs = nowMs
        return true
    }
}

/// Persistent NDJSON/JSONL store for performance incidents with rotation and size/age pruning
/// (`crates/rune-perf/src/store.rs`).
public final class PerfIncidentStore: @unchecked Sendable {
    public let directory: URL
    public let logFileURL: URL
    public let rotatedLogFileURL: URL
    public let maxLogBytes: UInt64
    public let maxAgeMs: UInt64?
    public let maxEntries: Int?

    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        directory: URL,
        fileName: String = "perf-incidents.jsonl",
        maxLogBytes: UInt64 = 4 << 20,
        maxAgeMs: UInt64? = nil,
        maxEntries: Int? = nil
    ) {
        self.directory = directory
        self.logFileURL = directory.appendingPathComponent(fileName)
        self.rotatedLogFileURL = directory.appendingPathComponent("\(fileName).1")
        self.maxLogBytes = max(maxLogBytes, 256)
        self.maxAgeMs = maxAgeMs
        self.maxEntries = maxEntries

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
        self.decoder = JSONDecoder()
    }

    /// Append an incident as a single JSONL line, rotating to `.1` if `maxLogBytes` would be exceeded.
    public func append(_ incident: Incident) throws {
        lock.lock()
        defer { lock.unlock() }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var lineData = try encoder.encode(incident)
        lineData.append(0x0A) // '\n'

        let currentSize = fileSize(at: logFileURL)
        if currentSize > 0 && currentSize + UInt64(lineData.count) > maxLogBytes {
            if FileManager.default.fileExists(atPath: rotatedLogFileURL.path) {
                try FileManager.default.removeItem(at: rotatedLogFileURL)
            }
            try FileManager.default.moveItem(at: logFileURL, to: rotatedLogFileURL)
        }

        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logFileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: lineData)
    }

    /// Read all incidents currently stored in the active JSONL log.
    public func readAll() throws -> [Incident] {
        lock.lock()
        defer { lock.unlock() }
        return try readAllUnlocked()
    }

    /// Prune incidents older than `maxAgeMs` and/or beyond `maxEntries`. Returns the number of removed entries.
    @discardableResult
    public func prune(nowMs: UInt64) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        var items = try readAllUnlocked()
        let before = items.count

        if let maxAgeMs {
            items.removeAll { nowMs >= $0.timestampMs && (nowMs - $0.timestampMs) > maxAgeMs }
        }
        if let maxEntries, items.count > maxEntries {
            items = Array(items.suffix(max(maxEntries, 0)))
        }

        let removed = before - items.count
        if removed > 0 {
            try rewriteUnlocked(items)
        }
        return removed
    }

    /// Compute summary statistics over the active JSONL log.
    public func summaryStats() throws -> IncidentStoreStats {
        lock.lock()
        defer { lock.unlock() }

        let items = try readAllUnlocked()
        var byKind: [IncidentKind: Int] = [:]
        var oldest: UInt64?
        var newest: UInt64?
        for item in items {
            byKind[item.kind, default: 0] += 1
            oldest = oldest.map { min($0, item.timestampMs) } ?? item.timestampMs
            newest = newest.map { max($0, item.timestampMs) } ?? item.timestampMs
        }
        return IncidentStoreStats(
            totalCount: items.count,
            byKind: byKind,
            oldestTimestampMs: oldest,
            newestTimestampMs: newest,
            fileSizeBytes: fileSize(at: logFileURL)
        )
    }

    private func readAllUnlocked() throws -> [Incident] {
        guard FileManager.default.fileExists(atPath: logFileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: logFileURL)
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }
        var out: [Incident] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let lineData = line.data(using: .utf8),
               let item = try? decoder.decode(Incident.self, from: lineData) {
                out.append(item)
            }
        }
        return out
    }

    private func rewriteUnlocked(_ items: [Incident]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = Data()
        for item in items {
            var line = try encoder.encode(item)
            line.append(0x0A)
            data.append(line)
        }
        let tmp = directory.appendingPathComponent(".\(logFileURL.lastPathComponent).tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            try FileManager.default.removeItem(at: logFileURL)
        }
        try FileManager.default.moveItem(at: tmp, to: logFileURL)
    }

    private func fileSize(at url: URL) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let num = attrs[.size] as? NSNumber else {
            return 0
        }
        return num.uint64Value
    }
}
