import Foundation
import Testing
@testable import Rune
@testable import RuneWindowResize

@Suite("Phase 3 WindowResize Example", .serialized)
struct Phase3WindowResizeTests {
    #if os(macOS) || os(Linux) || os(Windows)
    private final class TestBundleMarker: NSObject {}

    @Test("window_resize: realtime headless frames grow and shrink automatically")
    func autoResizeHeadless() async throws {
        let frames = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: frames) }
        let bundle = Bundle(for: TestBundleMarker.self).bundleURL
        let products = bundle.pathExtension == "xctest" ? bundle.deletingLastPathComponent() : bundle
        #if os(Windows)
        let binary = "rune-window-resize.exe"
        #else
        let binary = "rune-window-resize"
        #endif
        let process = Process()
        process.executableURL = products.appendingPathComponent(binary)
        process.arguments = ["--realtime", "--duration", "4", "--fps", "6", "--scale", "0.5", "--frames", frames.path]
        var environment = ProcessInfo.processInfo.environment
        environment["RUNE_RESIZE_AUTO"] = "1"
        environment.removeValue(forKey: "RUNE_RESIZE_FIT")
        process.environment = environment
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
        try #require(status == 0)
        let images = try FileManager.default.contentsOfDirectory(at: frames, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let heights = try images.map { try Frame.fromPNG(data: Data(contentsOf: $0)).height }
        let tall = try #require(heights.firstIndex(of: 300))
        #expect(heights[tall...].contains(200))
    }
    #endif

    @Test("window_resize: Tx.resizeWindow toggles height between 400 and 600")
    func resizeWindowTogglesHeight() throws {
        let app = RuneWindowResizeApp.makeApp(fit: false)
        let out0 = try HeadlessRunner.run(app, args: ToolingArgs.parse([]))
        let json0 = try #require(try JSONSerialization.jsonObject(with: out0.treeJSON) as? [String: Any])
        #expect((json0["viewport"] as? [Double]) == [480.0, 400.0])

        let scriptGrow = #"[{"t": 0.05, "key": "toggle", "action": "click"}]"#
        let out1 = try HeadlessRunner.run(app, args: ToolingArgs.parse(["--script", scriptGrow, "--at", "0.8"]))
        let json1 = try #require(try JSONSerialization.jsonObject(with: out1.treeJSON) as? [String: Any])
        #expect((json1["viewport"] as? [Double]) == [480.0, 600.0])

        let scriptShrink = #"[{"t": 0.05, "key": "toggle", "action": "click"}, {"t": 0.85, "key": "toggle", "action": "click"}]"#
        let out2 = try HeadlessRunner.run(app, args: ToolingArgs.parse(["--script", scriptShrink, "--at", "1.6"]))
        let json2 = try #require(try JSONSerialization.jsonObject(with: out2.treeJSON) as? [String: Any])
        #expect((json2["viewport"] as? [Double]) == [480.0, 400.0])
    }

    @Test("window_resize: fitContentHeight follows toggled body height")
    func fitContentHeightTogglesHeight() throws {
        let app = RuneWindowResizeApp.makeApp(fit: true)
        let out0 = try HeadlessRunner.run(app, args: ToolingArgs.parse([]))
        let json0 = try #require(try JSONSerialization.jsonObject(with: out0.treeJSON) as? [String: Any])
        #expect((json0["viewport"] as? [Double]) == [480.0, 400.0])

        let scriptGrow = #"[{"t": 0.05, "key": "toggle", "action": "click"}]"#
        let out1 = try HeadlessRunner.run(app, args: ToolingArgs.parse(["--script", scriptGrow, "--at", "0.8"]))
        let json1 = try #require(try JSONSerialization.jsonObject(with: out1.treeJSON) as? [String: Any])
        #expect((json1["viewport"] as? [Double]) == [480.0, 600.0])
    }
}
