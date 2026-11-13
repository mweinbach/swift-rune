import Foundation
import Testing
@testable import Rune
@testable import RuneCoretextCompare
@testable import RuneLayerFilterOverlay
@testable import RuneOccludedTimer
@testable import RunePinchBench

@Suite("Phase 3 Pinch Bench, CoreText Compare, and Overlay-Lab Examples Tests")
struct Phase3PinchAndCoretextTests {
    @Test("pinch_bench: live_only skips commits during magnify while updating camera/toolbar live values")
    func pinchBenchLiveOnlyVsRebuild() throws {
        let liveRt = Runtime<PinchCanvasState>(
            state: PinchCanvasState(live: true, cards: 40),
            viewport: RunePinchBenchApp.size,
            pixelScale: 2.0,
            systemDark: true,
            view: RunePinchBenchApp.view
        )
        _ = liveRt.renderFrame(at: 0.0)
        let liveCommits0 = liveRt.viewCommitCount
        let handled = liveRt.magnify(MagnifyEvent(delta: 0.1, x: 400, y: 300), at: Vec2(400, 300), now: 0.01)
        #expect(handled)
        _ = liveRt.renderFrame(at: 0.01)
        #expect(liveRt.viewCommitCount == liveCommits0)
        #expect(liveRt.state.zoom > 1.0)
        #expect(liveRt.state.camZoom.get() > 1.0)
        #expect(liveRt.state.liveOnlyEvents >= 1)

        let rebuildRt = Runtime<PinchCanvasState>(
            state: PinchCanvasState(live: false, cards: 40),
            viewport: RunePinchBenchApp.size,
            pixelScale: 2.0,
            systemDark: true,
            view: RunePinchBenchApp.view
        )
        _ = rebuildRt.renderFrame(at: 0.0)
        let rebuildCommits0 = rebuildRt.viewCommitCount
        #expect(rebuildRt.magnify(MagnifyEvent(delta: 0.1, x: 400, y: 300), at: Vec2(400, 300), now: 0.01))
        _ = rebuildRt.renderFrame(at: 0.01)
        #expect(rebuildRt.viewCommitCount > rebuildCommits0)

        let report = try RunePinchBenchApp.runReport(samples: 1, cards: 40, frames: 4)
        #if canImport(Metal)
        #expect(report.lines.count == 16)
        #expect(report.output.contains("mode=live cards=40 metric=commits median=0.0000"))
        #expect(report.output.contains("mode=rebuild cards=40 metric=commits median="))
        #endif
    }

    @Test("coretext_compare: CLI parsing, live CoreText comparison table, PNG heatmap output, and export")
    func coretextCompareCLIAndExecution() throws {
        let parsed = try RuneCoretextCompareApp.parseCLI([
            "--set", "mono", "--smoothing", "off", "--blend", "linear", "--against", "unsmoothed", "--out", "/tmp/ct-out"
        ])
        #expect(parsed.set == .mono)
        #expect(parsed.smoothing == .off)
        #expect(parsed.srgbBlend == false)
        #expect(parsed.reference == .unsmoothed)
        #expect(parsed.outDir == "/tmp/ct-out")

        let shotParsed = try RuneCoretextCompareApp.parseCLI(["shot", "/tmp/shot.png", "--pair", "dark"])
        #expect(shotParsed.command == .shot("/tmp/shot.png", pairName: "dark"))

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ct-compare-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let outOpts = RuneCoretextCompareApp.CLIOptions(
            command: .compare,
            set: .mono,
            smoothing: .off,
            srgbBlend: true,
            reference: .unsmoothed,
            outDir: tmp.appendingPathComponent("out").path
        )
        let table = try RuneCoretextCompareApp.execute(outOpts, useLiveReferenceOnMacOS: true)
        #expect(table.contains("SF Mono: Rune off (sRGB blending) vs CoreText with smoothing off"))
        #expect(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("out/rune-light-1.0x.png").path))
        #expect(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("out/heat-light-2.0x.png").path))

        let exportDir = tmp.appendingPathComponent("export")
        let exported = try RuneCoretextCompareApp.runExport(to: exportDir)
        #expect(exported.contains("cases-1.0x.json"))
        #expect(exported.contains("cases-2.0x.json"))

        let headlessOut = try HeadlessRunner.run(
            RuneCoretextCompareApp.makeSummaryApp(reportText: "ok"),
            args: ToolingArgs()
        )
        #expect(String(decoding: headlessOut.treeJSON, as: UTF8.self).contains("coretext-compare"))
    }

    @Test("occluded-timer: repeating 100ms wakeAfter, arm/pollArmed, and overlay options")
    func occludedTimerSpecsAndPolling() throws {
        let counter = OccludedTimerCounter()
        var state = OccludedTimerState(updatesMode: false, counter: counter)
        var tx = Tx()
        #expect(RuneOccludedTimerApp.poll(&state, at: 0.0, &tx))
        #expect(counter.fired == 1)
        #expect(abs((tx.wakeAfterSeconds ?? 0.0) - 0.1) < 1e-4)
        #expect(!RuneOccludedTimerApp.poll(&state, at: 0.05, &tx))
        #expect(RuneOccludedTimerApp.poll(&state, at: 0.1, &tx))
        #expect(counter.fired == 2)

        var armedState = OccludedTimerState(updatesMode: true, counter: counter)
        let t0 = Date(timeIntervalSinceReferenceDate: 100.0)
        var armTx = Tx()
        RuneOccludedTimerApp.arm(&armedState, &armTx, now: t0)
        #expect(!RuneOccludedTimerApp.pollArmed(&armedState, now: t0.addingTimeInterval(0.05)))
        #expect(RuneOccludedTimerApp.pollArmed(&armedState, now: t0.addingTimeInterval(0.15)))
        #expect(counter.fired == 3)
        #expect(counter.worstMs >= 150)

        let spec = RuneOccludedTimerApp.makeOverlaySpec(
            environment: [
                "OCCLUDED_TIMER_REGIONS": "1",
                "OCCLUDED_TIMER_BOTTOM": "1",
                "OCCLUDED_TIMER_PREWARM": "1",
            ]
        )
        #expect(spec.options.input == .regions)
        #expect(spec.spec.edge == .bottom)
        #expect(spec.options.prewarm)
        #expect(spec.poll != nil)

        let headless = try HeadlessRunner.run(
            RuneOccludedTimerApp.makeApp(arguments: ["--headless"]),
            args: ToolingArgs()
        )
        #expect(String(decoding: headless.treeJSON, as: UTF8.self).contains("\"pill\""))
    }

    @Test("layer-filter-overlay: unmasked/clipped capsules, dissolve + blur + clipRounded, and overlay spec")
    func layerFilterOverlaySpecAndTree() throws {
        let spec = RuneLayerFilterOverlayApp.makeOverlaySpec()
        #expect(spec.spec.name == "Layer filter capsule proof")
        #expect(spec.options.level == .aboveOverlays)
        #expect(spec.options.input == .none)
        #expect(!spec.options.excludeFromCapture)
        #expect(spec.options.prewarm)

        let out = try HeadlessRunner.run(
            RuneLayerFilterOverlayApp.makeApp(arguments: ["--headless"]),
            args: ToolingArgs()
        )
        let tree = String(decoding: out.treeJSON, as: UTF8.self)
        #expect(tree.contains("Unmasked"))
        #expect(tree.contains("Clipped"))
        #expect(tree.contains("Leaving"))
        #expect(tree.contains("\"capsule-clipped\""))
    }
}
