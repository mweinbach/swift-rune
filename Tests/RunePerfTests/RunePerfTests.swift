import Foundation
import Testing
@testable import RunePerf
#if canImport(Darwin)
import Darwin
#endif

@Suite("RunePerf Tests")
struct RunePerfTests {
    @Test func darwinProcessSamplerReportsNonZeroMemoryAndThreads() {
        let usage = RunePerf.sampleUsage()
        #expect(usage.residentBytes > 0)
        #expect(usage.virtualBytes > 0)
        if let footprint = usage.footprintBytes {
            #expect(footprint > 0)
            if let peak = usage.footprintPeakBytes {
                #expect(peak >= footprint)
            }
        }
        if let fds = usage.openFDs {
            #expect(fds >= 3)
            let dir = FileManager.default.temporaryDirectory
            var opened: [FileHandle] = []
            for i in 0..<8 {
                let p = dir.appendingPathComponent("runeperf-fd-\(UUID().uuidString)-\(i).tmp")
                FileManager.default.createFile(atPath: p.path, contents: Data())
                if let h = FileHandle(forReadingAtPath: p.path) { opened.append(h) }
                try? FileManager.default.removeItem(at: p)
            }
            let afterFds = RunePerf.sampleUsage().openFDs ?? 0
            #expect(afterFds >= fds + 4)
            opened.forEach { try? $0.close() }
        }

        let snapshot = RunePerf.snapshot()
        #expect(snapshot.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(snapshot.usage.residentBytes > 0)
        #expect(!snapshot.threads.isEmpty)
        #expect(snapshot.exitedThreadCpuSeconds >= 0)

        #if os(macOS)
        // A thread that burns >=0.3s of thread CPU time and exits is reflected in exitedThreadCpuSeconds.
        let before = ProcessSampler.snapshot()
        var thread: pthread_t?
        let rc = pthread_create(&thread, nil, { _ in
            func threadCpuSeconds() -> Double {
                var ts = timespec(tv_sec: 0, tv_nsec: 0)
                clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
                return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000.0
            }
            let deadline = Date().addingTimeInterval(10.0)
            var acc: UInt64 = 0
            while threadCpuSeconds() < 0.3 && Date() < deadline {
                for _ in 0..<10_000 {
                    acc &+= 1
                    acc ^= acc << 13
                }
            }
            withUnsafePointer(to: acc) { _ = $0 }
            return nil
        }, nil)
        #expect(rc == 0)
        if let thread {
            #expect(pthread_join(thread, nil) == 0)
        }
        let after = ProcessSampler.snapshot()
        #expect(after.exitedThreadCpuSeconds - before.exitedThreadCpuSeconds > 0.2)
        #endif
    }

    @Test func memoryGaugeAndLeaseTrackAndReleaseBytes() {
        let registry = GaugeRegistry()
        let gauge = MemoryGauge(name: "video.frames", registry: registry)
        #expect(gauge.bytes == 0)

        var lease: MemoryLease? = gauge.track(4096)
        #expect(gauge.bytes == 4096)
        #expect(registry.allValues()["video.frames"] == 4096)
        #expect(registry.sortedValues().count == 1)

        gauge.add(1024)
        #expect(gauge.bytes == 5120)
        gauge.subtract(512)
        #expect(gauge.bytes == 4608)

        lease?.release()
        lease?.release() // idempotent
        lease = nil
        #expect(gauge.bytes == 512)

        gauge.add(1)
        gauge.subtract(1)
        #expect(registry.sortedValues().filter { $0.name == "video.frames" }.count == 1)

        gauge.set(256)
        #expect(gauge.bytes == 256)
        let second = MemoryGauge(name: "audio.pcm", registry: registry)
        second.set(1024)
        let sorted = registry.sortedValues()
        #expect(sorted.map(\.name) == ["audio.pcm", "video.frames"])
    }

    @Test func recorderTracksFrameHistogramsPercentilesAndAnomalies() {
        let recorder = PerfRecorder(capacity: 100, windowMs: 60_000)
        let baseMs: UInt64 = 1_000_000

        for i in 0..<20 {
            let updateMs = Double(i + 1) * 0.5 // 0.5 .. 10.0
            let renderMs = 2.0
            recorder.recordFrame(
                FrameSample(
                    window: 1,
                    seq: UInt64(i),
                    outcome: .drawn,
                    updateMs: updateMs,
                    renderMs: renderMs,
                    allocatedBytes: 1024,
                    timestampMs: baseMs + UInt64(i * 16)
                )
            )
        }
        // One slow anomaly frame (> 16.67ms)
        recorder.recordFrame(
            FrameSample(
                window: 1,
                seq: 20,
                outcome: .drawn,
                updateMs: 12.0,
                renderMs: 8.0,
                allocatedBytes: 9 << 20,
                timestampMs: baseMs + 400
            )
        )

        #expect(recorder.totalFrames == 21)
        #expect(recorder.anomalyCount == 1)

        let stats = recorder.workMsStats
        #expect(stats != nil)
        #expect(stats?.count == 21)
        #expect(stats?.max == 20.0)
        #expect(stats?.min == 2.5)
        if let p50 = stats?.p50, let p95 = stats?.p95 {
            #expect(p50 <= p95)
        }
    }

    @Test func scopedSpansCountersAndChromeTraceExport() throws {
        let recorder = PerfRecorder()
        let counter = PerfCounter(name: "drawCalls")
        counter.increment(by: 3)
        #expect(counter.value == 3)

        recorder.incrementCounter("frames_drawn", by: 2)
        let result = recorder.measure("layout", category: "ui", args: ["pass": "1"]) {
            var sum = 0
            for i in 0..<100 { sum += i }
            return sum
        }
        #expect(result == 4950)
        #expect(recorder.completedSpans.count == 1)
        #expect(recorder.completedSpans[0].name == "layout")

        recorder.recordFrame(
            FrameSample(window: 1, seq: 1, outcome: .drawn, updateMs: 1.5, renderMs: 2.5, timestampMs: 5000)
        )

        let jsonString = try ChromeTraceExporter.exportJSON(from: recorder, pid: 1234, prettyPrinted: true)
        let data = Data(jsonString.utf8)
        let decoded = try JSONDecoder().decode(ChromeTraceDocument.self, from: data)
        #expect(decoded.displayTimeUnit == "ms")
        #expect(decoded.traceEvents.contains { $0.name == "layout" && $0.ph == .complete && $0.cat == "ui" })
        #expect(decoded.traceEvents.contains { $0.name == "frames_drawn" && $0.ph == .counter })
        #expect(decoded.traceEvents.contains { $0.name == "frame" && $0.ph == .complete })
    }

    @Test func perfBudgetDetectsViolationsAndThrows() {
        let stats = PercentileStats(p50: 4.0, p95: 12.0, p99: 18.0, min: 1.0, max: 25.0, mean: 6.0, count: 100)
        let usage = ProcessUsage(residentBytes: 200 << 20, footprintBytes: 150 << 20)
        let frames = [FrameSample(window: 1, seq: 1, outcome: .drawn, allocatedBytes: 2 << 20)]

        let passingBudget = PerfBudget(
            maxP50Ms: 8.0,
            maxP95Ms: 16.6,
            maxP99Ms: 20.0,
            maxMaxMs: 30.0,
            maxResidentBytes: 512 << 20,
            maxFootprintBytes: 256 << 20,
            maxAllocatedBytesPerFrame: 4 << 20
        )
        #expect(passingBudget.evaluate(stats: stats, usage: usage, frames: frames).isEmpty)

        let failingBudget = PerfBudget(maxP95Ms: 10.0, maxFootprintBytes: 100 << 20)
        let violations = failingBudget.evaluate(stats: stats, usage: usage, frames: frames)
        #expect(violations.count == 2)
        #expect(throws: PerfBudgetError.self) {
            try failingBudget.assertWithinBudget(stats: stats, usage: usage, frames: frames)
        }
    }
}
