import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import RunePerf

@Suite("RunePerf & Procwatch Upstream Parity Tests")
struct RunePerfUpstreamTests {
    private static let workerTimeout: TimeInterval = 60

    @Test func optionalCountersStayUnavailableAndInvalidTimingsRejected() throws {
        let recorder = PerfRecorder()
        let empty = FrameSample(window: 0, seq: 0, outcome: .skipped, timestampMs: 0)
        recorder.recordFrame(empty)

        #expect(recorder.workMsStats == nil)
        #expect(recorder.allocatedBytesStats == nil)
        #expect(recorder.gpuMsStats == nil)
        #expect(recorder.inputToFrameMsStats == nil)
        #expect(recorder.lifetimeMaxAllocatedBytes == nil)

        // Verify written perf.json keeps optional metrics unavailable (JSON null) when nil.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeperf-opt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writer = PerfStoreWriter(
            config: PerfConfig(directory: dir, app: "opt-fixture"),
            startNanos: DispatchTime.now().uptimeNanoseconds,
            health: PerfFileRecorder.SharedHealth()
        )
        writer.accept(empty)
        writer.writeSnapshot()
        let snapData = try Data(contentsOf: dir.appendingPathComponent("perf.json"))
        let snap = try #require(try JSONSerialization.jsonObject(with: snapData) as? [String: Any])
        let frames = try #require(snap["frames"] as? [String: Any])
        for key in ["work_ms", "ui_allocated_bytes", "gpu_ms", "input_to_frame_ms", "lifetime_max_work_ms", "lifetime_max_ui_allocated_bytes"] {
            #expect(frames[key] == nil || frames[key] is NSNull)
        }
        let caps = try #require(snap["capabilities"] as? [String: Any])
        #expect((caps["ui_allocations"] as? Bool) == false)
        #expect((caps["input_to_frame"] as? Bool) == false)
        #expect((caps["gpu_timestamps"] as? Bool) == false)

        let invalid = FrameSample(
            window: 1,
            seq: 1,
            outcome: .drawn,
            updateMs: .nan,
            renderMs: -1.0,
            gpuMs: .infinity,
            timestampMs: 0
        )
        #expect(invalid.updateMs == nil)
        #expect(invalid.renderMs == nil)
        #expect(invalid.gpuMs == nil)
        #expect(FrameSample(window: 0, seq: 0, outcome: .drawn, updateMs: .greatestFiniteMagnitude, renderMs: .greatestFiniteMagnitude).workMs == nil)
        #expect(FrameSample(window: 1, seq: 1, outcome: .drawn, updateMs: 2.0, renderMs: 1.0).workMs == 3.0)
    }

    @Test func historyIsBoundedAndAnomaliesRateLimitLogs() {
        let recorder = PerfRecorder(capacity: 600, windowMs: 60_000)
        for n in 0..<10_000 {
            recorder.recordFrame(
                FrameSample(window: 0, seq: UInt64(n), outcome: .drawn, updateMs: Double(n), renderMs: 0.0, timestampMs: UInt64(n))
            )
        }
        #expect(recorder.recentFrames.count == 600)
        #expect(recorder.workMsStats?.p50 == 9699.0)
        #expect(recorder.workMsStats?.p95 == 9969.0)
        #expect(recorder.recentAnomalies.count == 20)

        recorder.prune(nowMs: 70_000)
        #expect(recorder.workMsStats == nil)
        #expect(recorder.lifetimeMaxWorkMs == 9999.0)

        // 10-anomalies/sec log rate limit while keeping counts
        let limited = PerfRecorder()
        for _ in 0..<10 {
            #expect(limited.accept(FrameSample(window: 0, seq: 1, outcome: .drawn, updateMs: 20.0, renderMs: 0.0, timestampMs: 0)))
        }
        #expect(!limited.accept(FrameSample(window: 0, seq: 11, outcome: .drawn, updateMs: 20.0, renderMs: 0.0, timestampMs: 999)))
        #expect(limited.accept(FrameSample(window: 0, seq: 12, outcome: .drawn, updateMs: 20.0, renderMs: 0.0, timestampMs: 1_000)))
        #expect(limited.anomalyCount == 12)
        #expect(limited.logSuppressedCount == 1)
    }

    @Test func longFramesRequireRepetitionSameWindowAndBothTimings() {
        let detector = IncidentDetector()
        let stats = PerfRecorder()

        // Different windows never combine
        for n in 0..<3 {
            let s = FrameSample(window: UInt64(n), seq: UInt64(n), outcome: .drawn, updateMs: 20.0, renderMs: 0.0, timestampMs: UInt64(n))
            stats.recordFrame(s)
            #expect(detector.detectFrame(sample: s, recent: stats.recentFrames, windowId: UInt64(n)) == nil)
        }

        // Same window 0 reaches 3 slow frames
        for n in 3..<5 {
            stats.recordFrame(FrameSample(window: 0, seq: UInt64(n), outcome: .drawn, updateMs: 20.0, renderMs: 0.0, timestampMs: UInt64(n)))
        }
        let thirdWindowZero = FrameSample(window: 0, seq: 5, outcome: .drawn, updateMs: 20.0, renderMs: 0.0, timestampMs: 5)
        stats.recordFrame(thirdWindowZero)
        let finding = detector.detectFrame(sample: thirdWindowZero, recent: stats.recentFrames, windowId: 0)
        #expect(finding?.kind == .longFrames)

        // Missing renderMs / updateMs -> nil (never invented 0)
        let missingRender = FrameSample(window: 0, seq: 6, outcome: .drawn, updateMs: 300.0, renderMs: nil, timestampMs: 5_000)
        #expect(detector.detectFrame(sample: missingRender, recent: stats.recentFrames, windowId: 0) == nil)
        let stall = FrameSample(window: 0, seq: 7, outcome: .drawn, updateMs: 250.0, renderMs: 0.0, timestampMs: 5_001)
        #expect(detector.detectFrame(sample: stall, recent: stats.recentFrames, windowId: 0)?.kind == .stall)
    }

    @Test func growthUsesCompletedFloorsAndRejectsPlateausSpikesGapsAndMissingReads() {
        for c in 0..<5 {
            let detector = IncidentDetector()
            var findings: [Incident] = []
            for minute in 0..<6 {
                let base: UInt64 = 100 << 20
                let value: UInt64
                switch c {
                case 0: value = base + UInt64(minute) * (20 << 20)
                case 1: value = base
                case 2: value = (minute == 2) ? base * 3 : base
                default: value = base + UInt64(minute) * (20 << 20)
                }
                let adjustedMin = (c == 3 && minute > 2) ? (minute + 2) : minute
                let atMs = UInt64(adjustedMin) * 60_000
                let footprint: UInt64? = (c == 4 && minute == 2) ? nil : value
                findings = detector.detectProcess(
                    nowMs: atMs,
                    usage: ProcessUsage(footprintBytes: footprint, openFDs: 100)
                )
            }
            #expect(findings.count == (c == 0 ? 1 : 0))
            if c == 0 {
                #expect(findings[0].kind == .memoryGrowth)
            }
        }

        let fdDetector = IncidentDetector()
        for n in 0..<5 {
            #expect(fdDetector.detectProcess(nowMs: UInt64(n) * 60_000, usage: ProcessUsage(openFDs: UInt32(100 + n * 10))).isEmpty)
        }
        let fdFindings = fdDetector.detectProcess(nowMs: 300_000, usage: ProcessUsage(openFDs: 150))
        #expect(fdFindings.first?.kind == .fdGrowth)
        if let fdFinding = fdFindings.first {
            let structured = PerfStoreWriter.structuredEvidence(for: fdFinding, frameSample: nil)
            #expect((structured["minute_floors"] as? [UInt64]) == [100, 110, 120, 130, 140])
            #expect((structured["growth"] as? UInt64) == 40)
            #expect((structured["confidence"] as? String) == "suspected growth, not a proven leak")
        }
    }

    @Test func fileWriterPublishesBoundedIncidentsSnapshotAndRotatesLogs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeperf-writer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let channel = PerfIncidentChannel(capacity: 1)
        let config = PerfConfig(directory: dir, app: "fixture").build("1.0").incidents(channel: channel)
        let health = PerfFileRecorder.SharedHealth()
        let writer = PerfStoreWriter(config: config, startNanos: DispatchTime.now().uptimeNanoseconds, health: health)
        for n in 0..<40 {
            let s = FrameSample(
                window: UInt64(n),
                seq: UInt64(n),
                outcome: .drawn,
                updateMs: 300.0,
                renderMs: 1.0,
                timestampMs: UInt64(n) * 2_000
            )
            writer.accept(s)
        }
        writer.flush()
        writer.writeSnapshot()

        #expect(writer.incidentsCount == 40)
        #expect(writer.hookDroppedCount == 39)
        let firstNotified = channel.tryReceive()
        #expect(firstNotified != nil)
        #expect(channel.tryReceive() == nil)

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let incidentFiles = files.filter { $0.lastPathComponent.hasPrefix("perf-incident-") }
        #expect(incidentFiles.count == 16)
        for f in files where f.pathExtension == "json" {
            let data = try Data(contentsOf: f)
            #expect(data.count <= PerfFileRecorder.incidentBytesLimit)
            _ = try JSONSerialization.jsonObject(with: data)
        }

        let snapData = try Data(contentsOf: dir.appendingPathComponent("perf.json"))
        let snap = try #require(try JSONSerialization.jsonObject(with: snapData) as? [String: Any])
        let frames = try #require(snap["frames"] as? [String: Any])
        #expect(abs(((snap["slow_ms"] as? NSNumber)?.doubleValue ?? 0) - (1000.0 / 60.0)) < 1e-12)
        #expect((frames["total"] as? NSNumber)?.intValue == 40)
        #expect((snap["version"] as? String) == "1.0")
        #expect(frames["ui_allocated_bytes"] is NSNull)
        #expect((snap["write_errors"] as? NSNumber)?.intValue == 0)

        let incident0Data = try Data(contentsOf: dir.appendingPathComponent("perf-incident-00.json"))
        let incident0 = try #require(try JSONSerialization.jsonObject(with: incident0Data) as? [String: Any])
        let evidence = try #require(incident0["evidence"] as? [String: Any])
        let evidenceFrame = try #require(evidence["frame"] as? [String: Any])
        #expect((evidenceFrame["work_ms"] as? NSNumber)?.doubleValue == 301.0)
        #expect(evidenceFrame.keys.contains("ui_allocated_bytes"))
        #expect(!evidenceFrame.keys.contains("allocated_bytes"))
        #expect((evidence["confidence"] as? String) == "measured work; cause unknown")
        #expect((evidence["next_measurement"] as? String) != nil)

        let logText = try String(contentsOf: dir.appendingPathComponent("perf.log"), encoding: .utf8)
        let firstLineData = try #require(logText.split(separator: "\n").first.map { Data($0.utf8) })
        let firstLine = try #require(try JSONSerialization.jsonObject(with: firstLineData) as? [String: Any])
        let logFrame = try #require(firstLine["frame"] as? [String: Any])
        #expect(logFrame.keys.contains("ui_allocated_bytes"))
        #expect(!logFrame.keys.contains("allocated_bytes"))

        // Draining the channel allows subsequent incident notifications to succeed (no lifetime cap).
        writer.accept(FrameSample(window: 99, seq: 99, outcome: .drawn, updateMs: 300.0, renderMs: 1.0, timestampMs: 200_000))
        writer.flush()
        #expect(channel.tryReceive() != nil)
        let updatedData = try Data(contentsOf: dir.appendingPathComponent("perf.json"))
        let updatedSnapshot = try #require(try JSONSerialization.jsonObject(with: updatedData) as? [String: Any])
        #expect((updatedSnapshot["incidents"] as? NSNumber)?.intValue == 41)

        // Also check bounded async handler overload releases slots after execution.
        let hookSem = DispatchSemaphore(value: 0)
        let handlerConfig = PerfConfig(directory: dir, app: "fixture").incidents(capacity: 1) { _ in
            hookSem.signal()
        }
        let handlerWriter = PerfStoreWriter(config: handlerConfig, startNanos: DispatchTime.now().uptimeNanoseconds, health: health)
        handlerWriter.accept(FrameSample(window: 100, seq: 100, outcome: .drawn, updateMs: 300.0, renderMs: 1.0, timestampMs: 1000))
        handlerWriter.flush()
        #expect(hookSem.wait(timeout: .now() + Self.workerTimeout) == .success)
        Thread.sleep(forTimeInterval: 0.02)
        handlerWriter.accept(FrameSample(window: 101, seq: 101, outcome: .drawn, updateMs: 300.0, renderMs: 1.0, timestampMs: 3000))
        handlerWriter.flush()
        #expect(hookSem.wait(timeout: .now() + Self.workerTimeout) == .success)

        // Log rotation parity (128-byte cap)
        let logDir = dir.appendingPathComponent("log-rot", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        do {
            let log = PerfRotatingLog(directory: logDir, fileName: "perf.log", limitBytes: 128)
            for n in 0..<50 {
                try log.append(jsonObject: ["seq": n])
            }
        }
        for name in ["perf.log", "perf.log.1"] {
            let text = try String(contentsOf: logDir.appendingPathComponent(name), encoding: .utf8)
            #expect(text.utf8.count <= 128)
            for line in text.split(separator: "\n") {
                _ = try JSONSerialization.jsonObject(with: Data(line.utf8))
            }
        }

        // Stale-size partial write recovery + absent-dir write error + atomic_json oversize error
        let staleSpaces = Data(repeating: 0x20, count: 125)
        try staleSpaces.write(to: logDir.appendingPathComponent("perf.log"))
        let reopenedLog = PerfRotatingLog(directory: logDir, fileName: "perf.log", limitBytes: 128)
        try reopenedLog.append(jsonObject: ["seq": 51])
        let curAttrs = try FileManager.default.attributesOfItem(atPath: logDir.appendingPathComponent("perf.log").path)
        let rotAttrs = try FileManager.default.attributesOfItem(atPath: logDir.appendingPathComponent("perf.log.1").path)
        #expect(((curAttrs[.size] as? NSNumber)?.intValue ?? 999) <= 128)
        #expect((rotAttrs[.size] as? NSNumber)?.intValue == 125)

        let absentHealth = PerfFileRecorder.SharedHealth()
        let absentConfig = PerfConfig(directory: dir.appendingPathComponent("absent", isDirectory: true), app: "fixture")
        let absentWriter = PerfStoreWriter(config: absentConfig, startNanos: DispatchTime.now().uptimeNanoseconds, health: absentHealth)
        absentWriter.writeSnapshot()
        #expect(absentHealth.errorCount >= 1)

        var threwOversize = false
        do {
            try PerfStoreWriter.writeAtomicJSON(directory: dir, name: "big.json", object: ["k": "oversize"], limit: 1)
        } catch {
            threwOversize = true
        }
        #expect(threwOversize)
    }

    private func withHeldStoreLock<T>(in directory: URL, _ body: () throws -> T) throws -> T {
        let fd = try PerfFileRecorder.openFileLock(at: directory.appendingPathComponent(".perf.lock"))
        defer { PerfFileRecorder.closeFileLock(fd) }
        try #require(try PerfFileRecorder.tryLock(fd))
        return try body()
    }

    @Test func replacementAcquiresAfterOldOwnerReleases() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeperf-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let channel = PerfIncidentChannel(capacity: 1)
        let config = PerfConfig(directory: dir, app: "replacement").incidents(channel: channel)
        let recorder = try withHeldStoreLock(in: dir) {
            let recorder = try PerfFileRecorder.start(config: config)
            #expect(recorder.record(FrameSample(window: 1, seq: 1, outcome: .drawn, updateMs: 300.0, renderMs: 1.0)))
            return recorder
        }

        let notifiedURL = channel.receive(timeout: Self.workerTimeout)
        #expect(notifiedURL != nil)
        if let url = notifiedURL {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        recorder.shutdown()

        let snapData = try Data(contentsOf: dir.appendingPathComponent("perf.json"))
        let snap = try #require(try JSONSerialization.jsonObject(with: snapData) as? [String: Any])
        let frames = try #require(snap["frames"] as? [String: Any])
        #expect((frames["total"] as? NSNumber)?.intValue == 1)
    }

    @Test func perfFileRecorderLockContentionCancellationAndStartShutdown() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeperf-rec-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = try PerfFileRecorder.start(config: PerfConfig(directory: dir, app: "test-app").build("2.0"))
        #expect(recorder.record(FrameSample(window: 1, seq: 1, outcome: .drawn, updateMs: 300.0, renderMs: 1.0)))
        recorder.shutdown()

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("perf.json").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("perf.log").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("perf-incident-00.json").path))

        // Lock contention test: held .perf.lock causes cancellation without touching owner files
        let contendedDir = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: contendedDir, withIntermediateDirectories: true)
        try withHeldStoreLock(in: contendedDir) {
            var blockedRecorder: PerfFileRecorder? = try PerfFileRecorder.start(config: PerfConfig(directory: contendedDir, app: "replacement"))
            for i in 0..<1_000 {
                _ = blockedRecorder?.record(FrameSample(window: 1, seq: UInt64(i), outcome: .skipped))
            }
            #expect(blockedRecorder?.droppedSamples == 744)
            // Drop without calling shutdown() so deinit cancels lock wait AND joins the writer thread before returning.
            blockedRecorder = nil
            #expect(!FileManager.default.fileExists(atPath: contendedDir.appendingPathComponent("perf.json").path))
        }

        // Drop without calling shutdown() on an unlocked recorder drains and writes perf.json on worker join.
        let dropDir = dir.appendingPathComponent("drop-joins", isDirectory: true)
        try FileManager.default.createDirectory(at: dropDir, withIntermediateDirectories: true)
        do {
            let dropRec = try PerfFileRecorder.start(config: PerfConfig(directory: dropDir, app: "drop-joins"))
            #expect(dropRec.record(FrameSample(window: 1, seq: 1, outcome: .drawn, updateMs: 300.0, renderMs: 1.0)))
        }
        #expect(FileManager.default.fileExists(atPath: dropDir.appendingPathComponent("perf.json").path))

        // Release .perf.lock after contention and verify the 256 queued samples drain/flush cleanly to disk.
        let drainDir = dir.appendingPathComponent("drain-after-lock", isDirectory: true)
        try FileManager.default.createDirectory(at: drainDir, withIntermediateDirectories: true)
        let drainChannel = PerfIncidentChannel(capacity: 4)
        let drainConfig = PerfConfig(directory: drainDir, app: "drain-app").incidents(channel: drainChannel)
        let drainRecorder = try withHeldStoreLock(in: drainDir) {
            let drainRecorder = try PerfFileRecorder.start(config: drainConfig)
            for i in 0..<1_000 {
                let updateMs = (i == 0) ? 300.0 : 20.0
                _ = drainRecorder.record(FrameSample(window: 1, seq: UInt64(i), outcome: .drawn, updateMs: updateMs, renderMs: 1.0))
            }
            #expect(drainRecorder.droppedSamples == 744)
            return drainRecorder
        }

        // Wait for the writer to acquire the lock and flush its queued incident + snapshot, then shut down.
        let incidentURL = drainChannel.receive(timeout: Self.workerTimeout)
        #expect(incidentURL != nil)
        drainRecorder.shutdown()

        let snapData = try Data(contentsOf: drainDir.appendingPathComponent("perf.json"))
        let snap = try #require(try JSONSerialization.jsonObject(with: snapData) as? [String: Any])
        let frames = try #require(snap["frames"] as? [String: Any])
        #expect((frames["total"] as? NSNumber)?.intValue == 256)
        #expect((frames["anomalies"] as? NSNumber)?.intValue == 256)
        #expect((frames["log_suppressed"] as? NSNumber)?.intValue == 246)
        #expect((snap["dropped_samples"] as? NSNumber)?.uint64Value == 744)
        let logText = try String(contentsOf: drainDir.appendingPathComponent("perf.log"), encoding: .utf8)
        let logLines = logText.split(separator: "\n")
        // Anomaly logging is rate-limited to 10/s (256 in the same second -> 10 frame lines + 1 memory line).
        #expect(logLines.count == 11)
        for line in logLines {
            let lineData = Data(line.utf8)
            _ = try JSONSerialization.jsonObject(with: lineData)
        }
    }

    @Test func procwatchJsonUnaccountedGaugesCapAndCountingAllocator() throws {
        let s = ProcessSnapshot(
            pid: 7,
            timestampMs: 0,
            usage: ProcessUsage(footprintBytes: 1_000),
            threads: [ProcessThreadInfo(id: 1, name: "a\"b\\c\n", cpuSeconds: 0.5)],
            heap: ProcessHeapStats(liveBytes: 300, tags: ["untagged": 300]),
            gauges: ["video.frames": 200, "gpu.textures": 100]
        )
        #expect(s.unaccountedBytes == 400)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(s.toJSON().utf8)) as? [String: Any])
        #expect((parsed["pid"] as? NSNumber)?.intValue == 7)
        let threads = try #require(parsed["threads"] as? [[String: Any]])
        #expect((threads[0]["name"] as? String) == "abc")
        let heap = try #require(parsed["heap"] as? [String: Any])
        let tags = try #require(heap["tags"] as? [String: Any])
        #expect((tags["untagged"] as? NSNumber)?.intValue == 300)
        #expect((parsed["unaccounted"] as? NSNumber)?.intValue == 400)

        let bare = ProcessSnapshot(pid: 7, timestampMs: 0, usage: ProcessUsage(footprintBytes: 1_000), gauges: s.gauges)
        #expect(bare.unaccountedBytes == nil)
        let bareParsed = try #require(try JSONSerialization.jsonObject(with: Data(bare.toJSON().utf8)) as? [String: Any])
        #expect(bareParsed["heap"] == nil && bareParsed["unaccounted"] == nil)

        // Gauge cap 64
        let reg = GaugeRegistry()
        for i in 0..<70 {
            let g = MemoryGauge(name: "g\(i)", registry: reg)
            g.set(Int64(i + 1))
        }
        #expect(reg.allValues().count == GaugeRegistry.maxGauges)

        // Counting allocator parity (including unknown-before-install, takeAllocatedBytes delta, big blocks, 8-thread isolation)
        let alloc = ProcessCountingAllocator()
        #expect(alloc.threadAllocatedBytes() == nil)
        #expect(alloc.takeAllocatedBytes() == nil)
        #expect(alloc.heap() == nil)

        alloc.tagThread("audio")
        alloc.recordAlloc(size: 128)
        alloc.recordRealloc(oldSize: 128, newSize: 256)
        alloc.recordDealloc(size: 256)
        #expect(alloc.threadAllocatedBytes() == 384)
        #expect(alloc.threadAllocations() == 2)
        #expect(alloc.heap()?.liveBytes == 0)
        #expect(alloc.heap()?.peakBytes == 256)
        #expect(alloc.heap()?.largestBytes == 256)

        // First takeAllocatedBytes call establishes baseline and returns nil; subsequent calls return per-thread delta.
        #expect(alloc.takeAllocatedBytes() == nil)
        alloc.recordAlloc(size: 4096)
        #expect(alloc.takeAllocatedBytes() == 4096)
        #expect(alloc.takeAllocatedBytes() == 0)
        // Other thread's 1 MiB allocation is excluded from main thread's takeAllocatedBytes().
        let otherGroup = DispatchGroup()
        otherGroup.enter()
        DispatchQueue.global().async {
            alloc.recordAlloc(size: 1 << 20)
            otherGroup.leave()
        }
        otherGroup.wait()
        #expect(alloc.takeAllocatedBytes() == 0)

        let bigSize = ProcessCountingAllocator.bigBlockThreshold
        alloc.recordAlloc(size: bigSize)
        #expect(alloc.heap()?.bigLiveBytes == Int64(bigSize))
        #expect(alloc.heap()?.bigBlocks == 1)
        #expect(alloc.heap()?.largestBytes == bigSize)
        alloc.recordDealloc(size: bigSize)
        #expect(alloc.heap()?.bigLiveBytes == 0)

        let isoAlloc = ProcessCountingAllocator()
        isoAlloc.recordAlloc(size: 1)
        _ = isoAlloc.takeAllocatedBytes()
        let group = DispatchGroup()
        let q = DispatchQueue(label: "runeperf.thread-iso", attributes: .concurrent)
        final class DeltaBox: @unchecked Sendable {
            let lock = NSLock()
            var values: [UInt64] = []
        }
        let deltaBox = DeltaBox()
        for _ in 0..<8 {
            group.enter()
            q.async {
                isoAlloc.recordAlloc(size: 0)
                let start = isoAlloc.threadAllocatedBytes() ?? 0
                for _ in 0..<10_000 {
                    isoAlloc.recordAlloc(size: 128)
                }
                let delta = (isoAlloc.threadAllocatedBytes() ?? 0) - start
                deltaBox.lock.lock()
                deltaBox.values.append(delta)
                deltaBox.lock.unlock()
                group.leave()
            }
        }
        group.wait()
        #expect(deltaBox.values.count == 8)
        for delta in deltaBox.values {
            #expect(delta == 1_280_000)
        }
        #expect(isoAlloc.takeAllocatedBytes() == 0)
        #expect((isoAlloc.heap()?.liveBytes ?? 0) >= Int64(8 * 10_000 * 128))

        // maxTags (> 16) overflow falls back to "untagged", plus ProcessHeapStats.sortedTags ordering.
        let tagAlloc = ProcessCountingAllocator()
        for i in 1..<ProcessCountingAllocator.maxTags {
            tagAlloc.tagThread("tag-\(i)")
            tagAlloc.recordAlloc(size: 100 + i)
        }
        tagAlloc.tagThread("overflow-17")
        tagAlloc.recordAlloc(size: 512)
        let tagHeap = try #require(tagAlloc.heap())
        #expect(tagHeap.tags.count == ProcessCountingAllocator.maxTags)
        #expect(tagHeap.tags["overflow-17"] == nil)
        #expect(tagHeap.tags["untagged"] == 512)

        let sortedStats = ProcessHeapStats(tags: ["beta": 200, "alpha": 200, "gamma": 900, "untagged": 50]).sortedTags
        #expect(sortedStats.map(\.name) == ["gamma", "alpha", "beta", "untagged"])
        #expect(sortedStats.map(\.bytes) == [900, 200, 200, 50])
    }

    @Test func procwatchWatcherWarningsReportGateLateSamplesAndExitedThreadBusiest() {
        var config = ProcwatchConfig.release("t")
        config.report = nil
        let watcher = ProcwatchWatcher(config: config)
        let snap = ProcessSnapshot(
            pid: 1,
            timestampMs: 0,
            usage: ProcessUsage(footprintBytes: 2 << 30, footprintPeakBytes: 2 << 30),
            threads: [ProcessThreadInfo(id: 1, name: "main", cpuSeconds: 1.0)],
            heap: ProcessHeapStats(liveBytes: 100 << 20),
            gauges: ["video.frames": 300 << 20]
        )
        let events = watcher.observe(now: 0, snapshot: snap)
        #expect(events.count == 1)
        #expect(events[0].kind == .footprint)
        #expect(events[0].line.contains("heap 100 MB live"))
        #expect(events[0].line.hasSuffix("; video.frames 300 MB; unaccounted 1.6 GB"))

        // Growth + CPU + footprint warnings
        let w2 = ProcwatchWatcher(config: config)
        var allEvents: [ProcwatchEvent] = []
        for i in 0...12 {
            let s = ProcessSnapshot(
                pid: 1,
                timestampMs: UInt64(i * 10_000),
                usage: ProcessUsage(
                    footprintBytes: UInt64(50 + 100 * i) << 20,
                    footprintPeakBytes: UInt64(50 + 100 * i) << 20,
                    totalCpuSeconds: Double(i) * 10.0
                ),
                threads: [ProcessThreadInfo(id: 1, name: "main", cpuSeconds: 1.0)]
            )
            allEvents.append(contentsOf: w2.observe(now: Double(i * 10), snapshot: s))
        }
        let joined = allEvents.map(\.line).joined(separator: "\n")
        #expect(joined.contains("footprint grew"))
        #expect(joined.contains("% CPU over 60s: exited threads 100%"))
        #expect(joined.contains("warning: footprint 1.0 GB") || joined.contains("warning: footprint 1.1 GB"))
        #expect(allEvents.filter { $0.kind == .growth }.count == 2)
        #expect(allEvents.allSatisfy { $0.isWarning })

        // Flat and idle: nothing (crates/procwatch/src/lib.rs:733-737).
        let idleWatcher = ProcwatchWatcher(config: config)
        for i in 0...12 {
            let idleSnap = ProcessSnapshot(
                pid: 1,
                timestampMs: UInt64(i * 10_000),
                usage: ProcessUsage(footprintBytes: 50 << 20, totalCpuSeconds: 1.0)
            )
            #expect(idleWatcher.observe(now: Double(i * 10), snapshot: idleSnap).isEmpty)
        }

        // Gate test
        var gate = ProcwatchGate()
        let g0 = gate.pass(now: 0, window: 60)
        let g1 = gate.pass(now: 59, window: 60)
        let g2 = gate.pass(now: 60, window: 60)
        let g3 = gate.pass(now: 61, window: 60)
        #expect(g0)
        #expect(!g1)
        #expect(g2)
        #expect(!g3)

        // Periodic report test
        var rCfg = ProcwatchConfig.release("t")
        rCfg.report = 30.0
        let rw = ProcwatchWatcher(config: rCfg)
        let reported = (0...9).filter { i in
            let s = ProcessSnapshot(pid: 1, timestampMs: 0, usage: ProcessUsage(footprintBytes: 50 << 20, totalCpuSeconds: 1.0))
            return rw.observe(now: Double(i * 10), snapshot: s).contains(where: { $0.kind == .report })
        }
        #expect(reported == [0, 3, 6, 9])

        // Late samples (10.01s) still fill 60s window
        let lw = ProcwatchWatcher(config: config)
        var lateEvents: [ProcwatchEvent] = []
        for i in 0...12 {
            let t = Double(i) * 10.01
            let s = ProcessSnapshot(pid: 1, timestampMs: 0, usage: ProcessUsage(footprintBytes: 50 << 20, totalCpuSeconds: t))
            lateEvents.append(contentsOf: lw.observe(now: t, snapshot: s))
        }
        #expect(lateEvents.filter { $0.kind == .cpu }.count == 2)

        // Exited thread CPU slice attribution
        let old = ProcessSnapshot(
            pid: 1,
            timestampMs: 0,
            usage: ProcessUsage(totalCpuSeconds: 101.0),
            threads: [
                ProcessThreadInfo(id: 1, name: "main", cpuSeconds: 1.0),
                ProcessThreadInfo(id: 2, name: "worker", cpuSeconds: 100.0),
            ]
        )
        let new = ProcessSnapshot(
            pid: 1,
            timestampMs: 60_000,
            usage: ProcessUsage(totalCpuSeconds: 161.0),
            threads: [ProcessThreadInfo(id: 1, name: "main", cpuSeconds: 55.0)]
        )
        #expect(ProcwatchWatcher.busiest(old: old, new: new, span: 60.0) == "main 90%, exited threads 10%")
    }

    @Test func procwatchMbFormattingAndLoopbackHttpServe() async throws {
        #expect(Procwatch.mb(512 << 20) == "512 MB")
        #expect(Procwatch.mb((1536 << 20)) == "1.5 GB")
        #expect(Procwatch.mb(12 << 30) == "12 GB")

        let port = try Procwatch.serve(port: 0)
        #expect(port > 0)
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/"))
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((obj["pid"] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier)
    }

    @Test func procwatchConfigDevLatestWatchAndWatchWith() throws {
        let dev = ProcwatchConfig.dev("dev-fixture")
        #expect(dev.every == 2.0)
        #expect(dev.report == 60.0)
        #expect(dev.warnFootprint == (512 << 20))
        #expect(dev.warnGrowth == (64 << 20))
        #expect(dev.growthWindow == 20.0)
        #expect(dev.warnCpuCores == 0.5)
        #expect(dev.cpuWindow == 20.0)
        #expect(dev.name == "dev-fixture")

        // Use a large sleep interval after the immediate first sample so the background thread stays quiet.
        let warnSem = DispatchSemaphore(value: 0)
        let seenEvent = PortableLock<ProcwatchEvent?>(initialState: nil)
        let warnCfg = ProcwatchConfig(
            every: 60.0,
            report: nil,
            warnFootprint: 1,
            warnGrowth: UInt64.max,
            growthWindow: 60.0,
            warnCpuCores: 1_000_000.0,
            cpuWindow: 60.0,
            name: "pw-watch-with"
        )
        Procwatch.watchWith(warnCfg) { event, snap in
            let shouldSignal = seenEvent.withLock { current -> Bool in
                guard current == nil else { return false }
                current = event
                return true
            }
            if shouldSignal {
                #expect(snap.pid == ProcessInfo.processInfo.processIdentifier)
                warnSem.signal()
            }
        }
        #expect(warnSem.wait(timeout: .now() + Self.workerTimeout) == .success)
        let event = try #require(seenEvent.withLock { $0 })
        #expect(event.kind == .footprint)
        #expect(event.isWarning)

        // Poll briefly for latestLock update which runs immediately after observe loop.
        var latestSnap = Procwatch.latest()
        let deadline = Date().addingTimeInterval(1.0)
        while latestSnap == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            latestSnap = Procwatch.latest()
        }
        #expect(latestSnap?.pid == ProcessInfo.processInfo.processIdentifier)

        // Exercise Procwatch.watch(_:) with silent thresholds and long sleep interval.
        let silentCfg = ProcwatchConfig(
            every: 60.0,
            report: nil,
            warnFootprint: UInt64.max,
            warnGrowth: UInt64.max,
            growthWindow: 60.0,
            warnCpuCores: 1_000_000.0,
            cpuWindow: 60.0,
            name: "pw-watch"
        )
        Procwatch.watch(silentCfg)
    }

    @Test func idleTidyStateMachineMatchesUpstreamContract() {
        #expect(PerfFileRecorder.idleSeconds == 10.0)
        #expect(PerfFileRecorder.idleMinGapSeconds == 180.0)
        #expect(RunePerf.idleDuration == .seconds(10))
        #expect(RunePerf.idleMinGap == .seconds(180))

        // Starts parked with no timer before work arrives.
        var tidy = PerfIdleTidy()
        #expect(tidy.wait(now: 0) == nil)
        #expect(tidy.takeDue(now: 1_000) == false)

        // Work without a hook never arms a timer.
        tidy = tidy.onWork(now: 5, hooked: false)
        #expect(tidy.wait(now: 5) == nil)
        #expect(tidy.takeDue(now: 1_000) == false)

        // Work with a hook arms due = now + 10s, sliding forward on subsequent work.
        tidy = tidy.onWork(now: 10, hooked: true)
        #expect(tidy.wait(now: 10) == 10)
        #expect(tidy.wait(now: 14) == 6)
        #expect(tidy.takeDue(now: 19.9) == false)
        tidy = tidy.onWork(now: 15, hooked: true)
        #expect(tidy.wait(now: 15) == 10)
        #expect(tidy.wait(now: 30) == 0)

        // Firing transitions back to parked with last = now; no repeating timer wakeups.
        let firedFirst = tidy.takeDue(now: 25)
        #expect(firedFirst)
        #expect(tidy.wait(now: 25) == nil)
        #expect(tidy.takeDue(now: 500) == false)

        // Next work respects IDLE_MIN_GAP (180s) after previous tidy (25 + 180 = 205).
        tidy = tidy.onWork(now: 30, hooked: true)
        #expect(tidy.wait(now: 30) == 175)
        #expect(tidy.takeDue(now: 40) == false)
        #expect(tidy.takeDue(now: 204.9) == false)

        // Late traffic near the end of minGap still waits a full IDLE (10s) of quiet.
        tidy = tidy.onWork(now: 200, hooked: true)
        #expect(tidy.wait(now: 200) == 10)
        #expect(tidy.takeDue(now: 205) == false)
        let firedSecond = tidy.takeDue(now: 210)
        #expect(firedSecond)
        #expect(tidy.wait(now: 210) == nil)
    }

    @Test func recorderOnIdleRunsOncePerIdleSpellEnforcesMinGapAndParksUntimed() throws {
        func waitUntil(timeout: TimeInterval = 5.0, _ predicate: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !predicate() && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            return predicate()
        }

        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeperf-idle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        // 1. Without an onIdle hook, fast samples never arm a timer.
        do {
            let dir = baseDir.appendingPathComponent("no-hook", isDirectory: true)
            let recorder = try PerfFileRecorder.start(config: PerfConfig(directory: dir, app: "no-hook"))
            defer { recorder.shutdown() }
            #expect(waitUntil { recorder.waitCounts.untimed >= 1 })
            #expect(recorder.record(FrameSample(window: 1, seq: 1, outcome: .drawn, updateMs: 1.0, renderMs: 1.0)))
            #expect(waitUntil { recorder.waitCounts.untimed >= 2 })
            #expect(recorder.waitCounts.timed == 0)
        }

        // 2. With an onIdle hook, no timer is armed and the hook never runs before work arrives.
        do {
            let dir = baseDir.appendingPathComponent("no-work", isDirectory: true)
            let calls = PortableLock(initialState: 0)
            var cfg = PerfConfig(directory: dir, app: "no-work").onIdle {
                calls.withLock { $0 += 1 }
            }
            cfg.idleDelaySeconds = 0.03
            cfg.idleMinGapSeconds = 0.15
            let recorder = try PerfFileRecorder.start(config: cfg)
            defer { recorder.shutdown() }
            #expect(waitUntil { recorder.waitCounts.untimed >= 1 })
            Thread.sleep(forTimeInterval: 0.10)
            #expect(calls.withLock { $0 } == 0)
            #expect(recorder.waitCounts.timed == 0)
        }

        // 3. Runs once per idle spell on the recorder thread, parks untimed, and enforces minGap.
        do {
            let dir = baseDir.appendingPathComponent("spells", isDirectory: true)
            final class IdleState: @unchecked Sendable {
                let lock = NSLock()
                var count = 0
                var threadNames: [String] = []
                var timestamps: [TimeInterval] = []
                let sem = DispatchSemaphore(value: 0)
            }
            let state = IdleState()
            var cfg = PerfConfig(directory: dir, app: "spells").onIdle {
                let name = Thread.current.name ?? ""
                let now = TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
                state.lock.lock()
                state.count += 1
                state.threadNames.append(name)
                state.timestamps.append(now)
                state.lock.unlock()
                state.sem.signal()
            }
            cfg.idleDelaySeconds = 0.05
            cfg.idleMinGapSeconds = 0.25
            cfg.quietFlushDelaySeconds = 0.02

            let recorder = try PerfFileRecorder.start(config: cfg)
            defer { recorder.shutdown() }
            #expect(waitUntil { recorder.waitCounts.untimed >= 1 })

            // Send an anomaly so flushDue (0.02s) must flush first, then idleDelay (0.05s) fires.
            let sentAt = TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
            #expect(recorder.record(FrameSample(window: 1, seq: 1, outcome: .drawn, updateMs: 25.0, renderMs: 5.0)))
            #expect(state.sem.wait(timeout: .now() + 5.0) == .success)

            // Perf log was already flushed before idle ran, and the thread returns to an untimed park.
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("perf.log").path))
            #expect(waitUntil { recorder.waitCounts.untimed >= 2 })
            let timedAfterFirstIdle = recorder.waitCounts.timed

            // Stay idle for >2x idleDelaySeconds: must NOT re-fire or schedule repeating timers.
            Thread.sleep(forTimeInterval: 0.12)
            state.lock.lock()
            let countWhileIdle = state.count
            let firstTime = state.timestamps[0]
            let firstThread = state.threadNames[0]
            state.lock.unlock()
            #expect(countWhileIdle == 1)
            #expect(firstThread == "rune-perf")
            #expect(firstTime - sentAt >= 0.04)
            #expect(recorder.waitCounts.timed == timedAfterFirstIdle)

            // New sample immediately after idle wait must wait for minGap (0.25s from firstTime).
            #expect(recorder.record(FrameSample(window: 1, seq: 2, outcome: .drawn, updateMs: 1.0, renderMs: 1.0)))
            #expect(state.sem.wait(timeout: .now() + 5.0) == .success)
            state.lock.lock()
            let countAfterSecond = state.count
            let secondTime = state.timestamps[1]
            state.lock.unlock()
            #expect(countAfterSecond == 2)
            #expect(secondTime - firstTime >= 0.22)
        }

        // 4. Shutdown while armed does not hang or invoke onIdle after disconnect.
        do {
            let dir = baseDir.appendingPathComponent("shutdown-armed", isDirectory: true)
            let calls = PortableLock(initialState: 0)
            var cfg = PerfConfig(directory: dir, app: "shutdown-armed").onIdle {
                calls.withLock { $0 += 1 }
            }
            cfg.idleDelaySeconds = 5.0
            cfg.idleMinGapSeconds = 10.0
            let recorder = try PerfFileRecorder.start(config: cfg)
            #expect(recorder.record(FrameSample(window: 1, seq: 1, outcome: .drawn, updateMs: 1.0, renderMs: 1.0)))
            #expect(waitUntil { recorder.waitCounts.timed >= 1 })
            recorder.shutdown()
            #expect(calls.withLock { $0 } == 0)
        }
    }
}
