import Foundation
import Testing
import Rune
import RuneKit
@testable import RuneKitDiff

@Suite("Phase 3 Diff example", .serialized)
@MainActor
struct Phase3DiffTests {

    @Test("rune-kit-diff: renders 5 PR files, annotation thread, and switches to split mode")
    func multiFilePRAndSplitToggle() throws {
        let rt = Runtime<ReviewState>(
            state: initialReviewState(),
            viewport: Vec2(900, 620),
            pixelScale: 2.0,
            systemDark: true,
            view: reviewView
        )
        rt.frame(at: 0.0)
        let treeData = try JSONSerialization.data(withJSONObject: rt.treeJSON())
        let tree0 = String(decoding: treeData, as: UTF8.self)
        #expect(tree0.contains("Add jitter to retry backoff"))
        #expect(tree0.contains("5 files"))
        #expect(tree0.contains("backoff.rs"))
        #expect(tree0.contains("retry-curve.png"))
        #expect(tree0.contains("Jitter keeps a crowd"))
        #expect(rt.state.diff.mode == .unified)

        let splitRect = try #require(rt.element(byKey: "modes-1")?.rect)
        let center = Vec2(splitRect[0] + splitRect[2] * 0.5, splitRect[1] + splitRect[3] * 0.5)
        rt.pointerMove(to: center, at: 0.01)
        rt.pointerDown(at: center, at: 0.02)
        rt.pointerUp(at: center, at: 0.03)
        rt.frame(at: 0.04)

        #expect(rt.state.diff.mode == .split)
    }

    @Test("rune-kit-diff: scenes split, folded, long, line-info, added, and scrolled render via HeadlessRunner")
    func diffScenesAndHorizontalScroll() throws {
        let spec = makeApp().intoSpec()
        for (sceneName, needle) in [
            ("split", "backoff.rs"),
            ("folded", "attempts: 5"),
            ("long", "jitter: 0.2"),
            ("line-info", "jitter: 0.2"),
            ("added", "retry.md"),
        ] {
            var args = ToolingArgs()
            args.sceneName = sceneName
            args.darkOverride = true
            let out = try HeadlessRunner.run(spec, args: args)
            let tree = String(decoding: out.treeJSON, as: UTF8.self)
            #expect(tree.contains(needle), "Missing \(needle) in scene \(sceneName)")
        }

        var scrollArgs = ToolingArgs()
        scrollArgs.sceneName = "scrolled"
        scrollArgs.darkOverride = true
        scrollArgs.scriptArg = """
        [
          {"t": 0.05, "type": "scroll", "key": "diff-body", "dx": -420, "dur": 0.2},
          {"t": 0.35, "type": "mark", "name": "end"}
        ]
        """
        let scrolledOut = try HeadlessRunner.run(spec, args: scrollArgs)
        let scrolledTree = String(decoding: scrolledOut.treeJSON, as: UTF8.self)
        #expect(scrolledTree.contains("describe"))
        #expect(scrolledOut.finalFrame.width == 1800)
        #expect(scrolledOut.finalFrame.height == 1240)
    }
}
