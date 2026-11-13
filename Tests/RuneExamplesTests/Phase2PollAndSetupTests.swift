import Foundation
import Testing
@testable import Rune
@testable import RuneGlassCard
@testable import RuneLiveValues
@testable import RuneLuauPanel
@testable import RunePlayground
@testable import RuneShapes

@Suite("Phase 2 AppSpec/App poll, setup, playground & multi-window rewires", .serialized)
struct Phase2PollAndSetupTests {
    @Test("shapes: poll advances time and memo caches curves without invented step button")
    func shapesPollAndMemo() throws {
        let spec = RuneShapesApp.makeSpec()
        let out0 = try HeadlessRunner.run(spec, args: ToolingArgs.parse(["--at", "0.0"]))
        let json0 = try #require(try JSONSerialization.jsonObject(with: out0.treeJSON) as? [String: Any])
        let elems0 = try #require(json0["elements"] as? [[String: Any]])
        #expect(elems0.contains(where: { ($0["key"] as? String) == "curves" }))
        #expect(!elems0.contains(where: { ($0["key"] as? String) == "step-btn" }))

        let outMid = try HeadlessRunner.run(spec, args: ToolingArgs.parse(["--at", "0.5"]))
        let outScene = try HeadlessRunner.run(spec, args: ToolingArgs.parse(["--scene", "t15", "--at", "0.5"]))
        #expect(outMid.finalFrame.rgba != out0.finalFrame.rgba)
        #expect(outScene.finalFrame.rgba != outMid.finalFrame.rgba)
    }

    @Test("live-values: headless poll samples Live levels & cursors cleanly across --at times")
    func liveValuesHeadlessPoll() throws {
        let spec = RuneLiveValuesApp.makeSpec(arguments: [], windowed: false)
        let out0 = try HeadlessRunner.run(spec, args: ToolingArgs.parse(["--at", "0.0"]))
        let outLater = try HeadlessRunner.run(spec, args: ToolingArgs.parse(["--at", "0.5"]))
        let jsonLater = try #require(try JSONSerialization.jsonObject(with: outLater.treeJSON) as? [String: Any])
        let elems = try #require(jsonLater["elements"] as? [[String: Any]])
        #expect(elems.contains(where: { ($0["key"] as? String) == "speaker-0" }))
        #expect(elems.contains(where: { ($0["key"] as? String) == "cursor-0" }))
        #expect(outLater.treeJSON != out0.treeJSON)

        let rebuildSpec = RuneLiveValuesApp.makeSpec(arguments: ["--rebuild"], windowed: false)
        #expect(rebuildSpec.makeState().rebuild == true)
    }

    @Test("playground: PlaygroundHost binds scenes, stories, variants, triggers, and viewport presets")
    func playgroundHostStoriesVariantsAndScenes() throws {
        let app = RunePlaygroundApp.makeApp()
        let host = try #require(app.playgroundHost)
        #expect(host.groupOrder == ["Controls"])
        #expect(host.startFolded == true)
        #expect(host.presets.map(\.name) == ["Compact", "Wide"])

        // Story + variant via `--playground` / `--variant`
        let manyLong = try HeadlessRunner.run(
            app,
            args: ToolingArgs.parse(["--playground", "Lists/Many devices", "--variant", "Long names"])
        )
        let manyText = String(data: manyLong.treeJSON, encoding: .utf8) ?? ""
        #expect(manyText.contains("Studio desk in the back office"))

        let uploadHalf = try HeadlessRunner.run(
            RunePlaygroundApp.makeApp(),
            args: ToolingArgs.parse(["--playground", "Progress/Upload", "--variant", "Half done"])
        )
        let uploadText = String(data: uploadHalf.treeJSON, encoding: .utf8) ?? ""
        #expect(uploadText.contains("Uploading backup · 48%"))

        // Bound AppSpec scene inside PlaygroundHost
        let syncPaused = try HeadlessRunner.run(
            RunePlaygroundApp.makeApp(),
            args: ToolingArgs.parse(["--playground", "Sections/Sync paused"])
        )
        let syncText = String(data: syncPaused.treeJSON, encoding: .utf8) ?? ""
        #expect(syncText.contains("Changes stay on this device until sync is back on."))

        // Trigger "r" replay anchored at t > 2.0s pauses at +0.6s and resumes at +1.2s
        let uploadStory = try #require(host.stories.first(where: { $0.path == "Progress/Upload" }))
        let replayTrigger = try #require(uploadStory.triggers.first(where: { $0.key == "r" }))
        let spec = app.intoSpec()
        let poll = try #require(spec.poll)
        var state = spec.makeState()
        var tx = Tx()
        replayTrigger.action(&state, &tx)
        #expect(state.uploadReplayPending == true)
        _ = poll(&state, 2.5, &tx)
        #expect(state.uploadReplayStart == 2.5)
        #expect(state.uploadRunning == true)
        #expect(state.uploadPausedByReplay == false)
        _ = poll(&state, 3.1, &tx)
        #expect(state.uploadPausedByReplay == true)
        #expect(state.uploadRunning == false)
        #expect(state.uploadResumedByReplay == false)
        _ = poll(&state, 3.7, &tx)
        #expect(state.uploadResumedByReplay == true)
        #expect(state.uploadRunning == true)
        let beforeAdvance = state.uploadProgress
        _ = poll(&state, 3.85, &tx)
        #expect(state.uploadProgress == beforeAdvance + 4)
    }

    @Test("luau-panel: headless scene rendering and poll/setWaker work with RuneLuau")
    func luauPanelWakerAndScenePoll() throws {
        let spec = RuneLuauPanelApp.makeSpec()
        let outPanel = try HeadlessRunner.run(spec, args: ToolingArgs.parse(["--scene", "panel"]))
        let panelText = String(data: outPanel.treeJSON, encoding: .utf8) ?? ""
        #expect(!panelText.isEmpty)

        let outPanel20 = try HeadlessRunner.run(RuneLuauPanelApp.makeSpec(), args: ToolingArgs.parse(["--scene", "panel20"]))
        let panel20Text = String(data: outPanel20.treeJSON, encoding: .utf8) ?? ""
        #expect(!panel20Text.isEmpty)

        let poll = try #require(spec.poll)
        var state = spec.makeState()
        var tx = Tx()
        _ = poll(&state, 0.1, &tx)
    }

    @Test("glass-card: multi-window pattern (LoopSpec) and transparent card (SystemMaterial) render headlessly")
    func glassCardMultiWindowAndMaterial() throws {
        let windows = RuneGlassCardApp.makeWindows(arguments: ["rune-glass-card", "--window", "card", "--scene", "docked"])
        #expect(windows.map(\.key) == ["pattern", "card"])

        let cardOut = try RuneMultiWindow.runHeadless(
            windows,
            args: ToolingArgs.parse(["--window", "card", "--scene", "docked"])
        )
        let cardJson = try #require(try JSONSerialization.jsonObject(with: cardOut.treeJSON) as? [String: Any])
        let cardElems = try #require(cardJson["elements"] as? [[String: Any]])
        #expect(cardElems.contains(where: { ($0["key"] as? String) == "card" }))
        #expect(cardElems.contains(where: { ($0["text"] as? String) == "Docked" }))
        #expect(cardElems.contains(where: { ($0["text"] as? String) == "Fly" }))
        #expect(!cardElems.contains(where: { ($0["key"] as? String) == "measure-btn" }))

        let patternOut = try RuneMultiWindow.runHeadless(
            RuneGlassCardApp.makeWindows(arguments: ["rune-glass-card", "--window", "pattern"]),
            args: ToolingArgs.parse(["--window", "pattern"])
        )
        let patternJson = try #require(try JSONSerialization.jsonObject(with: patternOut.treeJSON) as? [String: Any])
        let patternElems = try #require(patternJson["elements"] as? [[String: Any]])
        #expect(patternElems.contains(where: { ($0["key"] as? String) == "pattern" }))
        #expect(patternElems.contains(where: { ($0["text"] as? String) == "RUNE 120 Hz" }))
    }
}
