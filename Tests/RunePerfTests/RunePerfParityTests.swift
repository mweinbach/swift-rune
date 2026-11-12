import Foundation
import Testing
@testable import RunePerf

@Suite("RunePerf Parity Tests")
struct RunePerfParityTests {
    @Test func incidentDetectorDetectsAndRateLimits() {
        let detector = IncidentDetector()
        let stall = FrameSample(
            window: 1,
            seq: 1,
            outcome: .drawn,
            updateMs: 200.0,
            renderMs: 60.0,
            allocatedBytes: 0,
            timestampMs: 10_000
        )
        let first = detector.detectFrame(sample: stall, recent: [], windowId: 1)
        #expect(first != nil)
        #expect(first?.kind == .stall)
        #expect(detector.admit(nowMs: 10_000, incident: first!))

        // Within 2s global cooldown & 60s per-key cooldown, same severity is suppressed
        #expect(!detector.admit(nowMs: 10_500, incident: first!))

        // >1.25x severity escalation bypasses 60s same-key cooldown (after 2s global cooldown)
        let worse = Incident(
            kind: .stall,
            window: 1,
            severity: first!.severity * 1.5,
            timestampMs: 12_500,
            message: "severe stall"
        )
        #expect(detector.admit(nowMs: 12_500, incident: worse))
    }

    @Test func incidentStoreWritesReadsRotatesAndPrunes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeperf-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("incidents.jsonl")
        let store = PerfIncidentStore(directory: dir, fileName: "incidents.jsonl", maxLogBytes: 400, maxAgeMs: 1_000)

        for i in 0..<10 {
            try store.append(
                Incident(
                    kind: .longFrames,
                    window: UInt64(i),
                    severity: Double(20 + i),
                    timestampMs: UInt64(10_000 + i * 100),
                    message: "frame \(i) exceeded budget with extra padding text"
                )
            )
        }

        let rotatedURL = URL(fileURLWithPath: fileURL.path + ".1")
        #expect(FileManager.default.fileExists(atPath: rotatedURL.path))

        let all = try store.readAll()
        #expect(!all.isEmpty)

        // Prune items older than nowMs - 1_000
        try store.prune(nowMs: 20_000)
        let afterPrune = try store.readAll()
        #expect(afterPrune.isEmpty)

        try store.append(
            Incident(kind: .memoryGrowth, window: 0, severity: 5.0, timestampMs: 20_000, message: "rss")
        )
        let stats = try store.summaryStats()
        #expect(stats.totalCount == 1)
        #expect(stats.byKind[.memoryGrowth] == 1)
    }

    @Test func allocTrackerSamplesFreesAndBuildsTopSitesSnapshot() {
        let tracker = AllocTracker(intervalBytes: 1024, maxSites: 64, maxFrames: 8)
        let framesA: [UInt64] = [0x1000, 0x2000]
        let framesB: [UInt64] = [0x3000, 0x4000]

        // Sub-interval allocation does not sample until threshold crosses
        #expect(!tracker.recordAllocation(pointer: 0xA1, size: 512, frames: framesA))
        #expect(tracker.recordAllocation(pointer: 0xA2, size: 600, frames: framesA))
        #expect(tracker.recordAllocation(pointer: 0xB1, size: 2048, frames: framesB))

        let snap1 = tracker.snapshot(top: 10)
        #expect(snap1.totalLiveBlocks == 2)
        #expect(snap1.totalLiveBytes == 2648)
        #expect(snap1.topSites.count == 2)
        #expect(snap1.topSites[0].frames == framesB)
        #expect(!snap1.formattedReport().isEmpty)

        #expect(tracker.recordFree(pointer: 0xB1))
        #expect(!tracker.recordFree(pointer: 0xDEAD))
        let snap2 = tracker.snapshot(top: 10)
        #expect(snap2.totalLiveBlocks == 1)
        #expect(snap2.totalLiveBytes == 600)

        tracker.reset()
        #expect(tracker.snapshot().totalLiveBlocks == 0)
    }
}
