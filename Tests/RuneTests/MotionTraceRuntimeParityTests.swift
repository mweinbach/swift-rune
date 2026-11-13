import Foundation
import Testing
@testable import Rune
import RuneMotion

@Suite("Rune Motion Trace Runtime Parity Tests (tests/motion_trace.rs)")
struct MotionTraceRuntimeParityTests {
    private static func parseJSONLines(_ text: String) throws -> [[String: Any]] {
        try text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                let data = Data(line.utf8)
                let obj = try JSONSerialization.jsonObject(with: data)
                return try #require(obj as? [String: Any])
            }
    }

    @Test("trace_names_channels_and_events_match_motion_lint")
    func traceNamesChannelsAndEventsMatchMotionLint() throws {
        let header = TraceHeader(launch: "pill", width: 200.0, height: 80.0, hz: 120.0, scale: 2.0)
        let buffer = SharedBuffer()
        let trace = MotionTrace.inMemory(header: header, buffer: buffer)
        var scene = Scene()
        // Attaching to an already settled scene must describe its nodes too.
        scene.insert(NodeId(40), NodeSpec(MotionRect.fromXYWH(0.0, 0.0, 100.0, 40.0)), .initial)
        scene.insert(NodeId(90), NodeSpec(MotionRect.fromXYWH(10.0, 0.0, 20.0, 20.0)), .initial)
        _ = scene.frameAt(0.0)
        scene.setTrace(trace.class("gpui").host("pill"))
        scene.traceName(NodeId(40), "chip:\"Area\"")
        scene.traceChannel("shell.width", kind: .position, value: 100.12345)
        scene.traceChannel("phase:recording", kind: .phase, value: 1.0)
        scene.traceEvent("lab:\"Start\\n\"")
        _ = scene.frameAt(0.01)
        _ = scene.frameAt(0.02)
        scene.traceName(NodeId(40), "chip:Region")
        scene.traceChannel("shell.width", kind: .position, value: 120.0)
        trace.removeChannel("phase:recording")
        _ = scene.frameAt(0.03)
        scene.traceName(NodeId(40), nil)
        scene.traceChannel("phase:recording", kind: .phase, value: 1.0)
        scene.traceChannel("shell.width", kind: .position, value: Float.nan)
        _ = scene.frameAt(0.04)
        scene.takeTrace()?.flush()

        let lines = try Self.parseJSONLines(buffer.contents())
        #expect(lines.count >= 5)

        let line1Models = try #require(lines[1]["m"] as? [[String: Any]])
        let named = try #require(line1Models.first { ($0["nm"] as? String) == "chip:\"Area\"" })
        let id = try #require(named["id"] as? Int)
        #expect((named["host"] as? String) == "pill")
        #expect((named["cls"] as? String) == "gpui")
        #expect(line1Models.contains { ($0["nm"] as? String) == "90" })

        let line1CM = try #require(lines[1]["cm"] as? [[String: Any]])
        #expect(line1CM.count == 2)
        #expect((line1CM[0]["id"] as? Int) == 1)
        #expect((line1CM[0]["name"] as? String) == "shell.width")
        #expect((line1CM[0]["kind"] as? String) == "position")
        #expect((line1CM[1]["id"] as? Int) == 2)
        #expect((line1CM[1]["name"] as? String) == "phase:recording")
        #expect((line1CM[1]["kind"] as? String) == "phase")

        let line1C = try #require(lines[1]["c"] as? [[Any]])
        #expect(line1C.count == 2)
        #expect((line1C[0][0] as? Int) == 1)
        #expect(abs((line1C[0][1] as? Double ?? 0) - 100.1235) < 1e-4)
        #expect((line1C[1][0] as? Int) == 2)
        #expect((line1C[1][1] as? Double) == 1.0)

        let line1EV = try #require(lines[1]["ev"] as? [String])
        #expect(line1EV == ["lab:\"Start\\n\""])

        for field in ["m", "cm", "c", "ev"] {
            #expect(lines[2][field] == nil, "duplicate \(field)")
        }

        let line3Models = try #require(lines[3]["m"] as? [[String: Any]])
        #expect((line3Models[0]["id"] as? Int) == id)
        #expect((line3Models[0]["nm"] as? String) == "chip:Region")
        let line3C = try #require(lines[3]["c"] as? [[Any]])
        #expect((line3C[0][0] as? Int) == 1)
        #expect((line3C[0][1] as? Double) == 120.0)
        let line3CG = try #require(lines[3]["cg"] as? [Int])
        #expect(line3CG == [2])

        let line4Models = try #require(lines[4]["m"] as? [[String: Any]])
        #expect((line4Models[0]["nm"] as? String) == "40")
        let line4C = try #require(lines[4]["c"] as? [[Any]])
        #expect((line4C[0][0] as? Int) == 2)
        #expect((line4C[0][1] as? Double) == 1.0)
    }

    @Test("runtime_forwards_trace_lifecycle_channels_and_events")
    func runtimeForwardsTraceLifecycleChannelsAndEvents() throws {
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(200, 80),
            pixelScale: 2.0,
            systemDark: true
        ) { _, _ in
            el().key("pill").w(100).h(40)
        }
        #expect(!rt.tracing)
        _ = rt.frame(at: 0.0)

        let header = TraceHeader(launch: "rt-pill", width: 200, height: 80, hz: 120, scale: 2.0)
        let buffer = SharedBuffer()
        rt.setTrace(MotionTrace.inMemory(header: header, buffer: buffer))
        #expect(rt.tracing)

        rt.traceChannel("shell.width", kind: .position, value: 100.0)
        rt.traceEvent("commit:start")
        _ = rt.frame(at: 0.01)

        let detached = rt.takeTrace()
        #expect(detached != nil)
        #expect(!rt.tracing)
        detached?.flush()

        let lines = try Self.parseJSONLines(buffer.contents())
        #expect(lines.count >= 2)
        let cm = try #require(lines[1]["cm"] as? [[String: Any]])
        let firstChannelName = cm.first?["name"] as? String
        #expect(firstChannelName == "shell.width")
        let ev = try #require(lines[1]["ev"] as? [String])
        #expect(ev == ["commit:start"])
    }
}
