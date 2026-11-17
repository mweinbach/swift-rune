#if os(macOS) || os(Linux) || os(Windows)
import Foundation
import Testing
@testable import Rune

@Suite("Native window trace")
struct NativeWindowTraceTests {
    #if os(Windows)
    @Test func frameClockResolvesIntervalsWithinAWindowsTimerTick() {
        let deadline = ContinuousClock.now + .milliseconds(100)
        var previous = RuneExecutionContext.hostUptime
        var shortest = Double.infinity
        repeat {
            let current = RuneExecutionContext.hostUptime
            if current > previous { shortest = min(shortest, current - previous) }
            previous = current
        } while shortest >= 0.001 && ContinuousClock.now < deadline
        #expect(shortest < 0.001)
    }
    #endif

    @Test func resumingAnIdleWindowDoesNotCountTheIdleGapAsADisplayInterval() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let trace = try #require(try NativeWindowTrace(args: ToolingArgs.parse(["--native", "--trace", path.path]),
                                                       recordsDrawables: true))
        let runtime = Runtime<Bool>(state: false, viewport: Vec2(20, 10), pixelScale: 1,
                                    view: { _, _ in El<Bool>().key("probe") })
        trace.begin(runtime, now: 10, refreshHz: 60)
        _ = runtime.frame(at: 0)
        // First frame rests. An event wakes the second frame, which requests the third.
        for (i, time) in [10.01, 15.01, 15.02].enumerated() {
            let id = UInt64(i + 1)
            trace.submitted(runtime, at: time, started: time - 0.001, target: nil,
                            sequence: id, continuous: i == 1)
            trace.presents?.presented(id, hostTime: time + 0.02)
        }
        try trace.finish()
        let records = try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(records.count == 4)
        #expect(records[2]["present_ms"] as? Double == 5030)
        #expect(records[2]["present_dt_ms"] == nil)
        #expect(records[3]["present_dt_ms"] as? Double == 10)
    }

    @Test func streamsWhileOpenAndStopsAtTheRequestedSubmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("window.jsonl")
        let args = ToolingArgs.parse(["--native", "--trace", path.path, "--frames", "2"])
        let trace = try #require(try NativeWindowTrace(args: args, recordsDrawables: false))
        let runtime = Runtime<Bool>(state: false, viewport: Vec2(20, 10), pixelScale: 1,
                                    view: { _, _ in El<Bool>().key("probe") })
        trace.begin(runtime, now: 10, refreshHz: 120)
        _ = runtime.frame(at: 0)
        trace.submitted(runtime, at: 10.01, started: 10, target: nil, sequence: nil, continuous: true)
        // Both the header and the first frame must be accessible before another draw or teardown.
        var text = try String(contentsOf: path, encoding: .utf8)
        for _ in 0..<1_500 {
            if text.split(separator: "\n").count >= 2 { break }
            try await Task.sleep(for: .milliseconds(2))
            text = try String(contentsOf: path, encoding: .utf8)
        }
        #expect(text.split(separator: "\n").count == 2)
        #expect(!trace.reachedLimit && trace.keepsDrawing)
        trace.submitted(runtime, at: 10.02, started: 10.015, target: nil, sequence: nil, continuous: true)
        #expect(trace.reachedLimit)
        trace.submitted(runtime, at: 10.03, started: 10.025, target: nil, sequence: nil, continuous: true)
        try trace.finish()
        try trace.finish()
        let records = try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(records.count == 3)
        #expect(records[0]["clock"] as? String == "wall")
        #expect(records[0]["timestamp"] as? String == "cpu-submit")
        #expect(records[0]["hz"] as? Int == 120)
        #expect(records[2]["t"] as? Double == 20)
        #expect(records[2]["present_ms"] == nil)
        #expect(!trace.keepsDrawing)
    }
}
#endif
