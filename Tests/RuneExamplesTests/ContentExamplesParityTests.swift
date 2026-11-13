import Foundation
import Testing
@testable import Rune
@testable import RuneInteractionCost
@testable import RuneMotion
@testable import RuneMotionBench
@testable import RunePopupMenu
@testable import RuneRewindCost

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
}
