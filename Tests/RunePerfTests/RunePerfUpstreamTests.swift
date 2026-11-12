import Foundation
import Testing
@testable import RunePerf
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("RunePerf & Procwatch Upstream Parity Tests")
struct RunePerfUpstreamTests {
    @Test func optionalCountersStayUnavailableAndInvalidTimingsRejected() {
        let recorder = PerfRecorder()
        let empty = FrameSample(window: 0, seq: 0, outcome: .skipped, timestampMs: 0)
        recorder.recordFrame(empty)

        #expect(recorder.workMsStats == nil)
        #expect(recorder.allocatedBytesStats == nil)
        #expect(recorder.gpuMsStats == nil)
        #expect(recorder.inputToFrameMsStats == nil)
        #expect(recorder.lifetimeMaxAllocatedBytes == nil)

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
    }

    @Test func fileWriterPublishesBoundedIncidentsSnapshotAndRotatesLogs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runeperf-writer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        final class NotifyBox: @unchecked Sendable {
            let lock = NSLock()
            var urls: [URL] = []
            func append(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return urls.count }
        }
        let box = NotifyBox()
        let config = PerfConfig(directory: dir, app: "fixture").build("1.0").incidents(capacity: 1) { url in
            box.append(url)
        }
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
        #expect(box.count == 1)

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
        #expect((frames["total"] as? NSNumber)?.intValue == 40)
        #expect((snap["version"] as? String) == "1.0")
        #expect(frames["ui_allocated_bytes"] is NSNull)
        #expect((snap["write_errors"] as? NSNumber)?.intValue == 0)

        // Log rotation parity (128-byte cap)
        let logDir = dir.appendingPathComponent("log-rot", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let log = PerfRotatingLog(directory: logDir, fileName: "perf.log", limitBytes: 128)
        for n in 0..<50 {
            try log.append(jsonObject: ["seq": n])
        }
        for name in ["perf.log", "perf.log.1"] {
            let text = try String(contentsOf: logDir.appendingPathComponent(name), encoding: .utf8)
            #expect(text.utf8.count <= 128)
            for line in text.split(separator: "\n") {
                _ = try JSONSerialization.jsonObject(with: Data(line.utf8))
            }
        }
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
        let lockPath = contendedDir.appendingPathComponent(".perf.lock").path
        let lockFd = lockPath.withCString { open($0, O_CREAT | O_RDWR, 0o644) }
        #expect(lockFd >= 0)
        #expect(flock(lockFd, LOCK_EX | LOCK_NB) == 0)
        defer {
            flock(lockFd, LOCK_UN)
            close(lockFd)
        }

        let blockedRecorder = try PerfFileRecorder.start(config: PerfConfig(directory: contendedDir, app: "replacement"))
        for i in 0..<1_000 {
            _ = blockedRecorder.record(FrameSample(window: 1, seq: UInt64(i), outcome: .skipped))
        }
        #expect(blockedRecorder.droppedSamples >= 744)
        blockedRecorder.shutdown()
        #expect(!FileManager.default.fileExists(atPath: contendedDir.appendingPathComponent("perf.json").path))
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

        // Counting allocator parity
        let alloc = ProcessCountingAllocator()
        alloc.tagThread("audio")
        alloc.recordAlloc(size: 128)
        alloc.recordRealloc(oldSize: 128, newSize: 256)
        alloc.recordDealloc(size: 256)
        #expect(alloc.threadAllocatedBytes() == 384)
        #expect(alloc.threadAllocations() == 2)
        #expect(alloc.heap()?.liveBytes == 0)
        #expect(alloc.heap()?.peakBytes == 256)
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
        #expect(allEvents.filter { $0.kind == .growth }.count == 2)
        #expect(allEvents.allSatisfy { $0.isWarning })

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
}
