import Foundation
import Testing
@testable import Rune
@testable import RuneCachePanZoom
@testable import RuneGpuSprings
@testable import RuneInteractionCost
@testable import RuneLuauBench
@testable import RuneMotion
@testable import RuneMotionBench
@testable import RunePopupMenu
@testable import RuneRewindCost
@testable import RuneTaffyAdapterBench
@testable import RuneTextGpu
@testable import RuneTreeSwap
@testable import RuneUploadBench
@testable import RuneZoomSweep

@Suite("Content crate-level examples parity", .serialized)
@MainActor
struct ContentExamplesParityTests {
    @Test("rune-popup-menu renders picker, context menu items, and headless menu-pick script")
    func popupMenuRendersAndPicks() throws {
        let initial = try HeadlessRunner.run(RunePopupMenuApp.makeApp(), args: ToolingArgs())
        let initialTree = String(decoding: initial.treeJSON, as: UTF8.self)
        #expect(initialTree.contains("\"theme\""))
        #expect(initialTree.contains("\"canvas\""))
        #expect(initialTree.contains("System"))
        #expect(initialTree.contains("Last: -"))

        // Context menu schema matches upstream Copy/Paste(disabled)/separator/Share(Mail, Messages).
        let menu = RunePopupMenuApp.contextMenu()
        #expect(menu.entries.count == 4)
        let copyItem = menu.findItem(id: "copy")
        #expect(copyItem?.title == "Copy")
        #expect(copyItem?.symbolName == "doc.on.doc")
        #expect(copyItem?.keyEquivalent == "mod+c")
        #expect(menu.findItem(id: "paste")?.enabled == false)
        #expect(menu.findItem(id: "mail")?.title == "Mail")
        #expect(menu.findItem(id: "messages")?.title == "Messages")

        // Drive picker click + headless --script menu-pick -> dark theme.
        let rt = RunePopupMenuApp.makeApp().makeRuntime()
        rt.frame(at: 0.0)
        let themeRect = try #require(rt.element(byKey: "theme")?.rect)
        let themeCenter = Vec2(themeRect[0] + themeRect[2] * 0.5, themeRect[1] + themeRect[3] * 0.5)
        rt.pointerMove(to: themeCenter, at: 0.01)
        rt.pointerDown(at: themeCenter, at: 0.01)
        rt.pointerUp(at: themeCenter, at: 0.02)
        rt.frame(at: 0.02)

        let show = try #require(rt.takePopup()).get()
        #expect(show.menu.selectedId == "system")
        try rt.resolvePopup("dark")
        rt.frame(at: 0.03)
        #expect(rt.state.theme == "dark")

        // Also test --script click + menu-pick end-to-end via HeadlessRunner.
        let script = """
        [
          {"type":"click","key":"theme"},
          {"type":"menu-pick","id":"dark"}
        ]
        """
        let scripted = try HeadlessRunner.run(
            RunePopupMenuApp.makeApp(),
            args: ToolingArgs.parse(["--script", script])
        )
        let scriptedTree = String(decoding: scripted.treeJSON, as: UTF8.self)
        #expect(scriptedTree.contains("\"Dark\""))
    }

    @Test("rune-motion-bench reports active AnimationStore, Scene reflow, and standalone sample metrics")
    func motionBenchSmoke() {
        let report = RuneMotionBenchApp.runReport(
            trackCounts: [120],
            sceneCounts: [60],
            frames: 10,
            runs: 2,
            sampleIters: 2_000
        )
        #expect(report.rows.count == 7)
        #expect(report.rows.allSatisfy { $0.nsPerItem > 0 && $0.nsPerItem.isFinite })
        #expect(report.sampleNsPerCall > 0 && report.sampleNsPerCall.isFinite)
        #expect(report.text.contains("scalar springs, underdamped (bounce .3)"))
        #expect(report.text.contains("scene: layout reflow"))
        #expect(report.text.contains("Spring::sample (closed form, standalone)"))
    }

    @Test("rune-interaction-cost reports press, wheel, and idle metrics")
    func interactionCostSmoke() {
        let report = RuneInteractionCostApp.runReport(samples: 2, frames: 12, rows: 30)
        #expect(report.lines.count == 9)
        #expect(report.lines.allSatisfy { $0.median >= 0 && $0.median.isFinite && $0.count == 2 })
        #expect(report.output.contains("scenario=press metric=p50_ms"))
        #expect(report.output.contains("scenario=wheel metric=mean_ms"))
        #expect(report.output.contains("scenario=idle metric=allocations"))
    }

    @Test("rune-rewind-cost measures rewind overhead and minute stream footprint")
    func rewindCostSmoke() {
        let report = RuneRewindCostApp.runReport(samples: 1, frames: 8, minuteFrames: 20, rows: 24)
        #expect(report.minuteFrames == 20)
        #expect(report.minuteBytes > 0)
        #expect(report.output.contains("scenario=stream rewind=off metric=p50_ms"))
        #expect(report.output.contains("scenario=fold rewind=on metric=p99_ms"))
        #expect(report.output.contains("scenario=minute rewind=on metric=bytes median=\(report.minuteBytes) frames=20"))
    }

    @Test("rune-luau-bench runs Luau perf gates and behavior checks cleanly", .disabled("Blocked on #464: RuneLuau UI.swift:1206 numeric key & LuauVM.swift:116 markStack unwind"))
    func luauBenchSmoke() {
        let report = RuneLuauBenchApp.run(scale: .smoke)
        #expect(report.idle.frames == 30)
        #expect(report.idle.framesAsked == 0)
        #expect(report.idle.vmCalls == 0)
        #expect(report.memoHit.vmCalls == 0)
        #expect(report.reload.stateKept)
        #expect(report.checks.count == 6)
        for c in report.checks {
            #expect(c.ok, "check \(c.name) failed: \(c.detail)")
        }
        let json = report.json()
        #expect(json.contains("\"checks\":"))
        #expect(report.formatted().contains("hot reload, compile + swap"))
    }

    @Test("rune-cache-pan-zoom benchmarks uncached vs cached Live pan/zoom layers")
    func cachePanZoomSmoke() throws {
        let report = try RuneCachePanZoomApp.runReport(samples: 1, cards: 10, frames: 6)
        #expect(report.lines.count == 32)
        #expect(report.output.contains("mode=uncached case=pan metric=cpu_ms"))
        #expect(report.output.contains("mode=cached case=pan_zoom metric=targets"))
        let cachedTargets = report.lines.first { $0.mode == "cached" && $0.testCase == "pan" && $0.metric == "targets" }
        #expect((cachedTargets?.median ?? 0) >= 0)
    }

    @Test("rune-upload-bench measures steady and scroll 2000-instance GPU upload frames")
    func uploadBenchSmoke() throws {
        let report = try RuneUploadBenchApp.runReport(frames: 8, warmup: 2, count: 400)
        #expect(report.results.count == 2)
        #expect(report.results.allSatisfy { $0.cpuUs > 0 && $0.frameUs >= $0.cpuUs * 0.5 })
        #expect(report.output.contains("scene=steady"))
        #expect(report.output.contains("scene=scroll"))
    }

    @Test("rune-taffy-adapter-bench compares LayoutStore vs TaffyTree and runs KitchenSink digest")
    func taffyAdapterBenchSmoke() {
        let isolated = RuneTaffyAdapterBenchApp.runIsolatedPairedBench(samples: 2, rows: 40)
        #expect(isolated.contains { $0.contains("STRUCTURAL_40_ROWS") })
        #expect(isolated.contains { $0.contains("ISOLATED metric=cold_build_solve_ms") })
        let runtime = RuneTaffyAdapterBenchApp.runRuntimeSuite(samples: 1, rowCount: 30, cellCount: 60)
        #expect(runtime.contains { $0.contains("RECT_DIGEST adapter=compact step=0") })
        #expect(runtime.contains { $0.contains("RECT_DIGEST adapter=compact step=1") })
        #expect(runtime.contains { $0.contains("RUNTIME adapter=compact metric=grid_to_list_swap_layout_ms") })
    }

    @Test("rune-gpu-springs passes differential, bench, and 8-primitive pixel parity checks")
    func gpuSpringsSmoke() throws {
        let report = try RuneGpuSpringsApp.runReport(diffIterations: 64, counts: [1, 32], runs: 2, frames: 8)
        #expect(report.diff.failures == 0)
        #expect(report.diff.samples == 64 * 4 * 5)
        #expect(report.bench.count == 2)
        for row in report.bench {
            #expect(row.maxPixelDelta <= 2, "pixel delta \(row.maxPixelDelta) for \(row.nodeCount) nodes")
            #expect(row.animatingDuringMotion)
            #expect(!row.animatingAfterSettle)
        }
        #expect(report.primitives.kindsChecked == 8)
        #expect(report.primitives.maxDelta <= 2)
    }

    @Test("rune-zoom-sweep sweeps liveScale and fontScale while preserving settled glyphs")
    func zoomSweepSmoke() throws {
        let report = try RuneZoomSweepApp.runReport(frames: 12, cards: 10)
        #expect(report.cases.count == 2)
        for c in report.cases {
            #expect(c.finalGlyphCount > 100)
            #expect(c.frameMedianMs >= 0 && c.frameMedianMs.isFinite)
        }
        #expect(report.output.contains("case=live_zoom_10s"))
        #expect(report.output.contains("case=font_sweep_10s"))
    }

    @Test("rune-text-gpu renders rest/zoom PNGs and measures still/scroll/zoom metrics")
    func textGpuSmoke() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rune-text-gpu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let snap = try RuneTextGpuApp.runSnap(directory: tmp, scale: 1.0, scales: [1.0, 1.3])
        #expect(snap.writtenFiles == 10)
        #expect(snap.totalGlyphs > 0)
        #expect(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("rest-light.png").path))
        #expect(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("zoom1-moving-dark.png").path))

        let perf = try RuneTextGpuApp.runPerf(scale: 1.5, frames: 6, warmup: 2)
        #expect(perf.glyphs > 0)
        #expect(perf.metrics.count == 3)
        #expect(perf.output.contains("case=still"))
        #expect(perf.output.contains("case=zoom"))
    }

    @Test("rune-tree-swap benchmarks list <-> grid replacement across first, quick, recent, and stale")
    func treeSwapSmoke() throws {
        let report = try RuneTreeSwapApp.runReport(samples: 1, cells: 40)
        #expect(report.results.count == 8)
        #expect(report.output.contains("dir=grid-list case=first"))
        #expect(report.output.contains("dir=list-grid case=stale"))
        for r in report.results {
            #expect(r.rowsBuilt > 0)
            #expect(r.rowsSettled > 0)
        }
    }
}
