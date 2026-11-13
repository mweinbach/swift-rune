import Foundation
import Testing
@testable import Rune
@testable import RuneCachePanZoom
@testable import RuneDockMenuProbe
@testable import RuneEmbedCost
@testable import RuneGpuSprings
@testable import RuneInteractionCost
@testable import RuneKit
@testable import RuneKitLayoutTextCost
@testable import RuneKitMarkdownResize
@testable import RuneKitScrollBench
@testable import RuneLiveResizeCheck
@testable import RuneLongNote
@testable import RuneLuauBench
@testable import RuneMaterialCheck
@testable import RuneMenuProbe
@testable import RuneMotion
@testable import RuneMotionBench
@testable import RuneOverlayHudCost
@testable import RunePacing
@testable import RunePacingOverlay
@testable import RunePopupMenu
@testable import RuneRewindCost
@testable import RuneScrollCommits
@testable import RuneShortcutProbe
@testable import RuneSpacesProbe
@testable import RuneTaffyAdapterBench
@testable import RuneTextGpu
@testable import RuneTreeSwap
@testable import RuneUploadBench
@testable import RuneWindowPanel
@testable import RuneWindowScrollCost
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

    @Test("rune-luau-bench passes all 6 Luau runtime behavior checks")
    func luauBenchChecksPass() {
        let checks = RuneLuauBenchApp.runChecks()
        #expect(checks.count == 6)
        for c in checks {
            #expect(c.ok, "check \(c.name) failed: \(c.detail)")
        }
    }

    @Test("rune-cache-pan-zoom benchmarks uncached vs cached Live pan/zoom layers")
    func cachePanZoomSmoke() throws {
        let report = try RuneCachePanZoomApp.runReport(samples: 1, cards: 10, frames: 6)
        #expect(report.lines.count == 32)
        #expect(report.output.contains("mode=uncached case=pan metric=cpu_ms"))
        #expect(report.output.contains("mode=cached case=pan_zoom metric=targets"))
        let uncachedTargets = try #require(report.lines.first { $0.mode == "uncached" && $0.testCase == "pan" && $0.metric == "targets" })
        let cachedTargets = try #require(report.lines.first { $0.mode == "cached" && $0.testCase == "pan" && $0.metric == "targets" })
        let cachedExtraPasses = try #require(report.lines.first { $0.mode == "cached" && $0.testCase == "pan" && $0.metric == "extra_passes" })
        let cachedCacheKB = try #require(report.lines.first { $0.mode == "cached" && $0.testCase == "pan" && $0.metric == "cache_kb" })
        #expect(uncachedTargets.median == 0)
        #expect(cachedTargets.median > 0)
        #expect(cachedExtraPasses.median >= 0)
        #expect(cachedCacheKB.median > 0)
        let uncachedInstances = try #require(report.lines.first { $0.mode == "uncached" && $0.testCase == "pan" && $0.metric == "instances" })
        let cachedInstances = try #require(report.lines.first { $0.mode == "cached" && $0.testCase == "pan" && $0.metric == "instances" })
        #expect(uncachedInstances.median > 0 && cachedInstances.median > 0)
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
        #expect(isolated.contains { $0.contains("STRUCTURAL_40_ROWS") && $0.contains("baseline_slot_B=") && $0.contains("reduction_pct=") })
        for metric in ["heap_live_500_rows_B", "heap_live_after_swap_12_rows_B", "cold_allocations_500_rows", "cold_build_solve_ms", "warm_solve_ms", "single_dirty_solve_ms"] {
            #expect(isolated.contains { $0.contains("ISOLATED metric=\(metric)") }, "Missing isolated metric \(metric)")
        }
        let runtime = RuneTaffyAdapterBenchApp.runRuntimeSuite(samples: 1, rowCount: 30, cellCount: 60, raw: true)
        let step0 = runtime.first { $0.contains("RECT_DIGEST adapter=compact step=0") }
        let step1 = runtime.first { $0.contains("RECT_DIGEST adapter=compact step=1") }
        #expect(step0 != nil && step1 != nil)
        #expect(step0 != step1)
        #expect(step0?.contains("sink_root:") == true)
        #expect(runtime.contains { $0.contains("RAW adapter=compact metric=grid_1800_layout_ms") })
        #expect(runtime.contains { $0.contains("RUNTIME adapter=compact metric=grid_to_list_swap_layout_ms") })
    }

    @Test("rune-gpu-springs passes differential, bench, and 8-primitive pixel parity checks")
    func gpuSpringsSmoke() throws {
        let report = try RuneGpuSpringsApp.runReport(diffIterations: 64, counts: [1, 32], runs: 2, frames: 8)
        #expect(report.diff.failures == 0)
        #expect(report.diff.samples == 64 * 4 * 5)
        #expect(report.diff.maxPositionError <= 0.01)
        #expect(report.diff.maxOpacityError <= 0.0001)
        #expect(report.bench.count == 2)
        for row in report.bench {
            #expect(row.maxPixelDelta <= 2, "pixel delta \(row.maxPixelDelta) for \(row.nodeCount) nodes")
            #expect(row.animatingDuringMotion)
            #expect(!row.animatingAfterSettle)
        }
        #expect(report.primitives.kindsChecked == 8)
        #expect(report.primitives.maxDelta <= 2)

        let verifyOnly = try RuneGpuSpringsApp.runReport(diffIterations: 64, counts: [], runs: 0, frames: 0, verifyOnly: true)
        #expect(verifyOnly.diff.failures == 0)
        #expect(verifyOnly.bench.isEmpty)
        #expect(verifyOnly.primitives.kindsChecked == 8)
    }

    @Test("rune-zoom-sweep sweeps liveScale and fontScale while preserving settled glyphs")
    func zoomSweepSmoke() throws {
        let report = try RuneZoomSweepApp.runReport(frames: 12, cards: 10)
        #expect(report.cases.count == 2)
        for c in report.cases {
            #expect(c.finalGlyphCount >= 1000)
            #expect(c.frameMedianMs >= 0 && c.frameMedianMs.isFinite)
            if c.name == "live_zoom_10s" {
                #expect(c.allCrispAtSettle)
            }
        }
        #expect(report.output.contains("case=live_zoom_10s"))
        #expect(report.output.contains("case=font_sweep_10s"))
        #expect(report.output.contains("metric=rasterized_10s"))
        #expect(report.output.contains("metric=sizes_10s"))
        #expect(report.output.contains("metric=resets_per_min"))
        #expect(report.output.contains("metric=atlas_pages"))
    }

    @Test("rune-text-gpu renders rest/zoom PNGs and measures still/scroll/zoom metrics")
    func textGpuSmoke() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rune-text-gpu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let snap = try RuneTextGpuApp.runSnap(directory: tmp, scale: 1.0, classic: true, gpuPrewarm: true, scales: [1.0, 1.3])
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
        let report = try RuneTreeSwapApp.runReport(samples: 1, cells: 10)
        #expect(report.results.count == 8)
        #expect(report.output.contains("dir=grid-list case=first"))
        #expect(report.output.contains("dir=list-grid case=stale"))
        for m in RuneTreeSwapApp.metrics {
            #expect(report.output.contains("metric=\(m)"), "Missing tree_swap metric \(m)")
        }
        for r in report.results {
            #expect(r.rowsBuilt > 0)
            #expect(r.rowsMounted > 0)
            #expect(r.rowsSettled > 0)
        }
        let filtered = try RuneTreeSwapApp.runReport(samples: 1, cells: 10, only: "grid-list/first")
        #expect(filtered.results.count == 1)
    }

    @Test("rune-long-note runs editing, IME commit, undo/paste, scroll, and caret tracking")
    func longNoteSmoke() throws {
        let report = try RuneLongNoteApp.runReport(sizes: [4], samples: 3, blocks: false)
        #expect(report.noteBytes >= 4096)
        #expect(report.noteLines > 20)
        #expect(report.undoDepth >= 99)
        #expect(report.scrollFrames > 1)
        #expect(report.caretHiddenCount >= 0)
        #expect(report.output.contains("MEMORY size=4k"))
        for caseName in [
            "type_start", "type_mid", "type_end",
            "enter_mid", "backspace_mid", "paste_2k", "undo",
            "scroll", "down", "cmd_down", "click",
        ] {
            #expect(report.output.contains("case=\(caseName)"))
        }
        #expect(report.output.contains("UNDO size=4k edits=100 undo_steps_kept=\(report.undoDepth)"))
        #expect(report.output.contains("CARET size=4k case=cmd_down at_end_in_view="))
        #expect(report.output.contains("metric=encode_ms"))
        #expect(report.output.contains("metric=paint_ms"))
    }

    @Test("rune-scroll-commits measures pure scroll commits with layout reads and video")
    func scrollCommitsSmoke() {
        let report = RuneScrollCommitsApp.runReport(samples: 1, frames: 5)
        #expect(report.results.count == 2)
        #expect(report.lines.count == 8)
        #expect(report.output.contains("scenario=layout metric=commits"))
        #expect(report.output.contains("scenario=video metric=commits"))
        #expect(report.output.contains("metric=allocations"))
        for r in report.results {
            #expect(r.frames == 5)
            #expect(r.cpuMeanMs >= 0 && r.cpuMeanMs.isFinite)
        }
    }

    @Test("rune-kit-layout-text-cost measures Markdown + Kit cold open, resize, and scroll")
    func kitLayoutTextCostSmoke() {
        let report = RuneKitLayoutTextCostApp.runReport(bytes: 3000, resizeSteps: 3, scrollFrames: 4)
        #expect(report.cases.count == 3)
        #expect(report.cases.allSatisfy { $0.instances > 0 && $0.glyphs > 0 && $0.wallMs >= 0 })
        #expect(report.output.contains("CASE name=open_cold"))

        let parity = RuneKitLayoutTextCostApp.runParity(
            repeatCount: 1,
            kb: 2,
            cases: ["stack", "md-resize", "tree", "vlist-resize-live", "memo-chat"],
            iterations: 2
        )
        #expect(parity.output.contains("WORDS note_tokens="))
        for c in ["stack", "md-resize", "tree", "vlist-resize-live", "memo-chat"] {
            #expect(parity.output.contains("CENSUS case=\(c)"))
            #expect(parity.output.contains("METRIC case=\(c) metric=cpu_ms"))
        }
        #expect(parity.output.contains("METRIC case=md-resize:commit metric=cpu_ms"))
        #expect(!parity.probeRecords.isEmpty)
    }

    @Test("rune-kit-markdown-resize measures open, live resize, scroll, highlights, and font switch")
    func kitMarkdownResizeSmoke() {
        let report = RuneKitMarkdownResizeApp.runReport(sizes: [4], step: 60, useMemo: false, highlightCount: 20, testFonts: true)
        #expect(report.metrics.count == 5)
        #expect(report.metrics.allSatisfy { $0.glyphs > 0 && $0.instances > 0 })
        #expect(report.output.contains("case=open"))

        let parityLines = RuneKitMarkdownResizeApp.runParity(
            sizes: [4],
            step: 150,
            only: ["open", "resize", "scroll", "marks", "fonts"],
            useMemo: true
        )
        let parityOutput = parityLines.joined(separator: "\n")
        #expect(parityOutput.contains("NOTE size=4k"))
        #expect(parityOutput.contains("MARKS requested="))
        for c in ["open", "resize", "scroll", "marks", "fonts"] {
            #expect(parityOutput.contains("case=\(c) metric=cpu_ms"))
            #expect(parityOutput.contains("case=\(c) metric=glyphs"))
        }
    }

    @Test("rune-kit-scroll-bench exercises list, markdown, sticky, growth, prose, and card workloads")
    func kitScrollBenchSmoke() {
        let report = RuneKitScrollBenchApp.runAll(rows: 20, frames: 4)
        #expect(report.results.count == 6)
        for r in report.results {
            #expect(r.frames == 4)
            #expect(r.instances > 0)
            #expect(r.medianCpuMs >= 0 && r.medianCpuMs.isFinite)
        }
        #expect(report.output.contains("WORKLOAD name=list"))

        let cardLines = RuneKitScrollBenchApp.runParityWorkload(
            "card",
            frames: 6,
            fps: 120.0,
            size: RuneKitScrollBenchApp.defaultSize
        ).joined(separator: "\n")
        #expect(cardLines.contains("METRIC cpu_ms_p50="))
        #expect(cardLines.contains("METRIC allocations_mean="))
        #expect(cardLines.contains("rune-scroll-profile"))

        let growthLines = RuneKitScrollBenchApp.runParityWorkload(
            "growth",
            frames: 6,
            fps: 120.0,
            size: RuneKitScrollBenchApp.defaultSize
        ).joined(separator: "\n")
        #expect(growthLines.contains("METRIC instances_p50="))
        #expect(growthLines.contains("METRIC view_rebuilds_p50="))
    }

    @Test("rune-embed-cost exercises LayerHost frame pacing and memory reporting")
    func embedCostSmoke() throws {
        let appSpec = RuneEmbedCostApp.spec()
        #expect(appSpec.size == Vec2(800, 600))
        let report = try RuneEmbedCostApp.runReport(warmup: 3, frames: 10, useLiveLayer: false)
        #expect(report.frames == 10)
        #expect(report.drew == 10)
        #expect(report.fps > 0 && report.fps.isFinite)
        #expect(report.output.contains("embed_cost:"))
        #expect(report.output.contains("frames=10"))
    }

    @Test("rune-window-scroll-cost measures scrollable list CPU cost and scroll offset")
    func windowScrollCostSmoke() {
        let report = RuneWindowScrollCostApp.runBench(rows: 80, frames: 8)
        #expect(report.frames == 8)
        #expect(report.instances > 0)
        #expect(report.scrollOffset > 0)
        #expect(report.usPerFrame >= 0 && report.usPerFrame.isFinite)
    }

    @Test("rune-overlay-hud-cost drives Compositor frame/UI draw and OverlaySpec lifecycle")
    func overlayHudCostSmoke() {
        let report = RuneOverlayHudCostApp.runHeadlessVerify(frames: 5, writes: 2)
        #expect(report.frames == 5)
        #expect(report.uiDraws == 5)
        #expect(report.overlayName == "HUD")
        #expect(report.overlayVisibleAfterShow)
        let hzOverlay = RuneOverlayHudCostApp.overlaySpec(showHz: true)
        #expect(hzOverlay.options.name == "HUD")
    }

    @Test("rune-pacing advances spring pill layout across frames cleanly")
    func pacingSmoke() {
        let report = RunePacingApp.runPacingReport()
        #expect(report.frames >= 3)
        #expect(report.animatingMidMotion)
        #expect(report.midX > report.startX)
        #expect(report.endX >= report.midX)
    }

    @Test("rune-pacing-overlay renders looping overlay pill and fades in/out")
    func pacingOverlaySmoke() {
        let report = RunePacingOverlayApp.runHeadlessVerify()
        #expect(report.visibleOnFadeIn)
        #expect(!report.visibleAfterFadeOut)
        #expect(report.overlayInstances > 0)
        let nativeOverlay = RunePacingOverlayApp.overlaySpec(nativePulse: true)
        #expect(!nativeOverlay.options.name.isEmpty)
    }

    @Test("rune-material-check attaches glass/popover materials and prewarmed overlay")
    func materialCheckSmoke() {
        let report = RuneMaterialCheckApp.runHeadlessVerify()
        #expect(report.mainMaterialCount >= 2)
        #expect(report.overlayPrewarmed)
        #expect(report.overlayVisible)
        #expect(report.overlayInstances > 0)
    }

    @Test("rune-live-resize-check keeps edge bars aligned across viewport widths")
    func liveResizeCheckSmoke() {
        let report = RuneLiveResizeCheckApp.runHeadlessVerify()
        #expect(report.compositorFrames == 4)
        #expect(report.barRights.count == 4)
        for (w, right) in zip(report.widths, report.barRights) {
            #expect(abs(right - w) <= 1.0)
        }
    }

    @Test("rune-spaces-probe configures capture-excluded prewarmed overlay and resize/hide")
    func spacesProbeSmoke() {
        let report = RuneSpacesProbeApp.runHeadlessVerify()
        #expect(report.excludedOption)
        #expect(report.prewarmOption)
        #expect(report.visibleDuringShow)
        #expect(report.sizeAfterResize == Vec2(340, 64))
        #expect(!report.visibleAfterHide)
        #expect(report.instances > 0)
    }

    @Test("rune-window-panel validates multi-window panel spec and Escape/blur dismissal")
    func windowPanelSmoke() throws {
        let report = try RuneWindowPanelApp.runHeadlessVerify()
        #expect(report.windowKeys == ["main", "panel"])
        #expect(report.panelEscaped)
        #expect(report.panelBlurred)
        #expect(report.mainFrames == 1)
    }

    @Test("rune-menu-probe validates NativeMenuBar items and dispatches actions")
    func menuProbeSmoke() throws {
        let report = try RuneMenuProbeApp.runHeadlessVerify()
        #expect(report.itemCount == 5)
        #expect(report.firstDispatchStatus == "triggered menu action #1")
        #expect(report.countAfterDispatch == 11)
        #expect(report.checkedAfterToggle)
        #expect(RuneMenuProbeApp.menuItems(disabled: true, checked: false).count == 5)
    }

    @Test("rune-dock-menu-probe configures accessory dock items, icon, and actions")
    func dockMenuProbeSmoke() throws {
        let report = try RuneDockMenuProbeApp.runHeadlessVerify()
        #expect(report.isAccessory)
        #expect(report.dockMenuItemCount == 2)
        #expect(report.dockClicksAfterDispatch == 1)
        #expect(report.validIcon)
        #expect(!RuneDockMenuProbeApp.defaultMenuItems().isEmpty)
        #expect(RuneDockMenuProbeApp.customMenuItems().count == 2)
    }

    @Test("rune-shortcut-probe registers, detects conflict, dispatches, and unregisters shortcuts")
    func shortcutProbeSmoke() {
        let report = RuneShortcutProbeApp.runHeadlessVerify()
        #expect(report.registeredPrimary)
        #expect(report.conflictRejected)
        #expect(report.dispatchHandledId == "probe.global")
        #expect(report.triggerCount == 1)
        #expect(report.unregisteredOK)
    }
}
