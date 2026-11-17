import Foundation

/// An aggregated allocation call site tracked by `AllocTracker`.
///
/// Mirrors upstream `procwatch::alloc::sites::AllocSite`.
public struct AllocSite: Sendable, Equatable, Hashable, Codable {
    public let hash: UInt64
    public let frames: [UInt64]
    public var liveBytes: Int64
    public var liveBlocks: Int64
    public var sampledBytes: UInt64

    public init(
        hash: UInt64,
        frames: [UInt64],
        liveBytes: Int64 = 0,
        liveBlocks: Int64 = 0,
        sampledBytes: UInt64 = 0
    ) {
        self.hash = hash
        self.frames = frames
        self.liveBytes = liveBytes
        self.liveBlocks = liveBlocks
        self.sampledBytes = sampledBytes
    }
}

/// A custom memory section contributed beside allocation sites (`procwatch::alloc::sites::contribute`).
public struct AllocSiteSection: Sendable, Equatable, Codable {
    public let name: String
    public let report: String

    public init(name: String, report: String) {
        self.name = name
        self.report = report
    }
}

/// Point-in-time snapshot of live allocation sites sorted by descending live bytes.
public struct AllocSiteSnapshot: Sendable, Equatable, Codable {
    public let intervalBytes: Int
    public let droppedCount: UInt64
    public let totalLiveBytes: Int64
    public let totalLiveBlocks: Int64
    public let topSites: [AllocSite]
    public let sections: [AllocSiteSection]

    public init(
        intervalBytes: Int,
        droppedCount: UInt64,
        totalLiveBytes: Int64,
        totalLiveBlocks: Int64,
        topSites: [AllocSite],
        sections: [AllocSiteSection] = []
    ) {
        self.intervalBytes = intervalBytes
        self.droppedCount = droppedCount
        self.totalLiveBytes = totalLiveBytes
        self.totalLiveBlocks = totalLiveBlocks
        self.topSites = topSites
        self.sections = sections
    }

    /// Formats a human-readable top-sites summary.
    public func formattedReport() -> String {
        var lines: [String] = [
            String(
                format: "AllocSiteSnapshot(interval: %d B, live: %lld B across %lld blocks, dropped: %llu)",
                intervalBytes,
                totalLiveBytes,
                totalLiveBlocks,
                droppedCount
            )
        ]
        for (index, site) in topSites.enumerated() {
            let framesText = site.frames.map { String(format: "0x%llx", $0) }.joined(separator: " <- ")
            lines.append(
                String(
                    format: "#%d hash=0x%016llx live=%lld B (%lld blocks) sampled=%llu B [%@]",
                    index + 1,
                    site.hash,
                    site.liveBytes,
                    site.liveBlocks,
                    site.sampledBytes,
                    framesText
                )
            )
        }
        for section in sections where !section.report.isEmpty {
            lines.append("section \(section.name)")
            lines.append(section.report)
        }
        return lines.joined(separator: "\n")
    }
}

/// Thread-safe allocation site tracker using byte-interval sampling and live pointer accounting.
///
/// Mirrors upstream `procwatch::alloc::sites` (`AllocTracker`, `SiteTable`, `PtrMap`).
public final class AllocTracker: @unchecked Sendable {
    public static let shared = AllocTracker()
    public static let defaultInterval: Int = 32 << 10
    public static let defaultMaxSites: Int = 1 << 13
    public static let defaultMaxFrames: Int = 28

    /// Registers a named memory section reporter included in every snapshot dump (`procwatch::alloc::sites::contribute`).
    public static func contribute(_ name: String, report: @escaping @Sendable () -> String) {
        shared.contribute(name, report: report)
    }

    private struct LiveRecord {
        let siteHash: UInt64
        let size: Int64
    }

    private let lock = NSLock()
    private let intervalBytes: Int
    private let maxSites: Int
    private let maxFrames: Int

    private var sites: [UInt64: AllocSite] = [:]
    private var livePointers: [UInt64: LiveRecord] = [:]
    private var contributedSections: [(name: String, report: @Sendable () -> String)] = []
    private var countdownBytes: Int
    private var droppedCount: UInt64 = 0
    private var totalLiveBytes: Int64 = 0
    private var totalLiveBlocks: Int64 = 0

    public init(
        intervalBytes: Int = AllocTracker.defaultInterval,
        maxSites: Int = AllocTracker.defaultMaxSites,
        maxFrames: Int = AllocTracker.defaultMaxFrames
    ) {
        let clampedInterval = max(1, intervalBytes)
        self.intervalBytes = clampedInterval
        self.maxSites = max(1, maxSites)
        self.maxFrames = max(1, maxFrames)
        self.countdownBytes = clampedInterval
    }

    /// Computes FNV-1a 64-bit hash for a call-stack frame list.
    public static func hashFrames(_ frames: [UInt64]) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for addr in frames {
            h ^= addr
            h &*= 0x100000001b3
        }
        return h == 0 ? 1 : h
    }

    /// Records an allocation for `pointer` of `size` bytes.
    ///
    /// When `frames` is `nil`, samples share an unattributed site on WASI. Native hosts capture the call stack.
    /// Sampling is triggered whenever accumulated allocated bytes cross `intervalBytes` (or immediately for
    /// allocations >= `intervalBytes`).
    @discardableResult
    public func recordAllocation(pointer: UInt64, size: Int, frames: [UInt64]? = nil) -> Bool {
        guard pointer != 0, size > 0 else { return false }

        lock.lock()
        defer { lock.unlock() }

        countdownBytes -= size
        if countdownBytes > 0 {
            return false
        }
        while countdownBytes <= 0 {
            countdownBytes += intervalBytes
        }

        let capturedFrames: [UInt64]
        if let frames {
            capturedFrames = Array(frames.prefix(maxFrames))
        } else {
            #if os(WASI)
            capturedFrames = []
            #else
            capturedFrames = Array(
                Thread.callStackReturnAddresses.dropFirst(1).prefix(maxFrames).map { $0.uint64Value }
            )
            #endif
        }

        let hash = Self.hashFrames(capturedFrames)

        // If the same pointer is re-recorded before free, retire the previous live record first.
        if let previous = livePointers.removeValue(forKey: pointer) {
            totalLiveBytes -= previous.size
            totalLiveBlocks -= 1
            if var prevSite = sites[previous.siteHash] {
                prevSite.liveBytes -= previous.size
                prevSite.liveBlocks -= 1
                sites[previous.siteHash] = prevSite
            }
        }

        if sites[hash] == nil, sites.count >= maxSites {
            droppedCount += 1
            return false
        }

        var site = sites[hash] ?? AllocSite(hash: hash, frames: capturedFrames)
        let size64 = Int64(size)
        site.liveBytes += size64
        site.liveBlocks += 1
        site.sampledBytes += UInt64(size)
        sites[hash] = site

        livePointers[pointer] = LiveRecord(siteHash: hash, size: size64)
        totalLiveBytes += size64
        totalLiveBlocks += 1
        return true
    }

    /// Records a deallocation for `pointer`, decrementing live bytes and block count if tracked.
    @discardableResult
    public func recordFree(pointer: UInt64) -> Bool {
        guard pointer != 0 else { return false }

        lock.lock()
        defer { lock.unlock() }

        guard let record = livePointers.removeValue(forKey: pointer) else {
            return false
        }
        totalLiveBytes -= record.size
        totalLiveBlocks -= 1

        if var site = sites[record.siteHash] {
            site.liveBytes -= record.size
            site.liveBlocks -= 1
            sites[record.siteHash] = site
        }
        return true
    }

    /// Registers a named memory section reporter included in snapshot dumps (`procwatch::alloc::sites::contribute`).
    public func contribute(_ name: String, report: @escaping @Sendable () -> String) {
        lock.lock()
        contributedSections.append((name: name, report: report))
        lock.unlock()
    }

    /// Returns a snapshot of the top `limit` allocation sites sorted by descending live bytes (then sampled bytes).
    public func snapshot(top limit: Int = 32) -> AllocSiteSnapshot {
        lock.lock()
        let activeSites = sites.values
            .filter { $0.liveBytes > 0 || $0.liveBlocks > 0 || $0.sampledBytes > 0 }
            .sorted { lhs, rhs in
                if lhs.liveBytes != rhs.liveBytes {
                    return lhs.liveBytes > rhs.liveBytes
                }
                if lhs.sampledBytes != rhs.sampledBytes {
                    return lhs.sampledBytes > rhs.sampledBytes
                }
                return lhs.hash < rhs.hash
            }
        let limited = Array(activeSites.prefix(max(0, limit)))
        let reporters = contributedSections
        let bytes = totalLiveBytes
        let blocks = totalLiveBlocks
        let dropped = droppedCount
        lock.unlock()

        let resolvedSections = reporters.map { entry in
            AllocSiteSection(name: entry.name, report: entry.report())
        }
        return AllocSiteSnapshot(
            intervalBytes: intervalBytes,
            droppedCount: dropped,
            totalLiveBytes: bytes,
            totalLiveBlocks: blocks,
            topSites: limited,
            sections: resolvedSections
        )
    }

    /// Clears all tracked sites, live pointers, contributed sections, and counters.
    public func reset() {
        lock.lock()
        sites.removeAll()
        livePointers.removeAll()
        contributedSections.removeAll()
        countdownBytes = intervalBytes
        droppedCount = 0
        totalLiveBytes = 0
        totalLiveBlocks = 0
        lock.unlock()
    }
}
