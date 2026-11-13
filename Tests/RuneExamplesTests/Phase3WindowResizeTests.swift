import Foundation
import Testing
@testable import Rune
@testable import RuneWindowResize

@Suite("Phase 3 WindowResize Example", .serialized)
struct Phase3WindowResizeTests {
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
