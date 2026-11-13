import Foundation
import Testing
@testable import Rune
@testable import RuneWww

/// Ports all 10 unit tests from upstream `www/app/src/{tests.rs,pipeline.rs,wordmark.rs}`
/// plus `RuneWwwApp.app().webAppConfig` and `--html` export verification.
@Suite("RuneWww Parity Tests (www/app)")
struct RuneWwwTests {
    private func page(width: Float) -> Runtime<WwwState> {
        let rt = Runtime(
            state: WwwState(notFound: false),
            viewport: Vec2(width, 900.0),
            pixelScale: 2.0,
            systemDark: true,
            view: { state, cx in RuneWwwApp.view(state, &cx) }
        )
        for _ in 0..<3 {
            _ = rt.frame(at: 0.0)
        }
        return rt
    }

    private func elementPaths(_ rt: Runtime<WwwState>) -> [String] {
        rt.elements().filter { !$0.exiting }.map(\.path)
    }

    // MARK: - tests.rs (4 tests)

    @Test("every_snippet_still_cuts")
    func everySnippetStillCuts() {
        for snippet in [WwwCode.helloView, WwwCode.helloTest, WwwCode.retarget] {
            let cut = snippet.cut()
            #expect(cut != nil, "\(snippet.file): a marker stopped matching")
            guard let cut else { continue }
            let lineCount = cut.code.split(separator: "\n", omittingEmptySubsequences: false).count
            #expect(cut.start <= cut.end && lineCount > 3)
            let opens = cut.code.filter { $0 == "{" }.count
            let closes = cut.code.filter { $0 == "}" }.count
            #expect(opens == closes, "\(snippet.file): braces balance")
        }
    }

    @Test("every_breakpoint_builds_the_same_tree")
    func everyBreakpointBuildsTheSameTree() {
        let narrow = elementPaths(page(width: 360.0))
        #expect(narrow.count > 100)
        let narrowSet = Set(narrow)
        for w: Float in [400.0, 560.0, 760.0, 860.0, 1000.0, 1400.0] {
            let wide = elementPaths(page(width: w))
            let wideSet = Set(wide)
            let only = wide.filter { !narrowSet.contains($0) } + narrow.filter { !wideSet.contains($0) }
            #expect(only.isEmpty, "at \(w): \(only)")
        }
    }

    @Test("the_breakpoint_follows_the_window")
    func theBreakpointFollowsTheWindow() {
        let rt = page(width: 1200.0)
        let wide = rt.element(byKey: "hero-text")!.rect
        rt.setViewport(Vec2(390.0, 900.0), pixelScale: 2.0)
        for _ in 0..<3 {
            _ = rt.frame(at: 0.0)
        }
        let narrow = rt.element(byKey: "hero-text")!.rect
        #expect(wide[2] < 1200.0 - 520.0, "the card sits beside the text: \(wide)")
        #expect(abs(narrow[2] - (390.0 - 32.0)) < 1.0, "and under it on a phone: \(narrow)")
    }

    @Test("the_cargo_line_names_the_repo_and_a_rev")
    func theCargoLineNamesTheRepoAndARev() {
        let line = WwwSections.cargoLine()
        #expect(line.hasPrefix("rune = { git = \"https://github.com/anomalyco/rune\", rev = \""))
    }

    // MARK: - pipeline.rs (2 tests)

    @Test("the_light_runs_once_and_cools")
    func theLightRunsOnceAndCools() {
        var p = WwwPipeline.Pipeline()
        p.setVisible(true, now: 1.0, reduced: false)
        let t0 = p.tick(1.0)
        #expect(t0)
        let t1 = p.tick(1.0 + WwwPipeline.travel * 0.5)
        #expect(t1)
        let mid = p.light()
        #expect(mid.heat[0] > 0.0 && mid.heat[6] == 0.0)
        let t2 = p.tick(1.0 + WwwPipeline.travel + 0.1)
        #expect(t2)
        let t3 = p.tick(1.0 + WwwPipeline.travel + 6.0)
        #expect(!t3, "it stops asking for frames once cool")
        #expect(p.light() == WwwPipeline.Light.dark)
        p.setVisible(false, now: 9.0, reduced: false)
        p.setVisible(true, now: 10.0, reduced: false)
        let t4 = p.tick(10.0)
        #expect(!t4, "it plays on the first view only")
    }

    @Test("reduced_motion_fades_every_step_together")
    func reducedMotionFadesEveryStepTogether() {
        var p = WwwPipeline.Pipeline()
        p.setVisible(true, now: 0.0, reduced: true)
        let t0 = p.tick(0.4)
        #expect(t0)
        #expect(p.light().heat == [Float](repeating: 1.0, count: 7))
        #expect(p.light().comet == 0.0)
        let t1 = p.tick(1.0)
        #expect(!t1)
    }

    // MARK: - wordmark.rs (4 tests)

    @Test("idle_glints_wait_five_to_nine_seconds_and_stop_off_screen")
    func idleGlintsWaitFiveToNineSecondsAndStopOffScreen() {
        var g = WwwWordmark.Glints()
        g.mastheadVisible(true, reduced: false, now: 0.0)
        let first = g.tick(1.0)
        let at = first.next!
        #expect(!first.moving && (5.0...9.0).contains(at))
        let second = g.tick(at)
        #expect(second.changed && second.moving)
        if case .glint = g.glow(.masthead, now: at + 0.1, reduced: false) {
        } else {
            Issue.record("expected Glow.glint while running")
        }
        g.mastheadVisible(false, reduced: false, now: at + 0.2)
        let cooled = g.tick(at + WwwWordmark.glintSeconds + 1.0)
        #expect(cooled.next == nil)
        #expect(g.glow(.masthead, now: at + WwwWordmark.glintSeconds + 1.0, reduced: false) == .off)
    }

    @Test("reduced_motion_lights_on_hover_only")
    func reducedMotionLightsOnHoverOnly() {
        var g = WwwWordmark.Glints()
        g.mastheadVisible(true, reduced: true, now: 0.0)
        let initTick = g.tick(0.0)
        let idleTick = g.tick(initTick.next!)
        #expect(!idleTick.changed, "no idle light under reduced motion")
        g.masthead(20.0)
        #expect(g.glow(.masthead, now: 20.3, reduced: true) == .lit(1.0))
    }

    @Test("letters_fit_one_clear_pixel_apart")
    func lettersFitOneClearPixelApart() {
        let g = WwwWordmark.Glyphs()
        let starts = g.glyphs.map(\.x)
        #expect(starts[0] == 0)
        for i in 1..<starts.count {
            #expect(starts[i] > starts[i - 1])
        }
        #expect(g.carve.count == WwwWordmark.inkCells(WwwWordmark.runeRows).count)
        #expect(g.carve.allSatisfy { (0.0...1.0).contains($0.order) })
    }

    @Test("a_glint_warms_the_stave_first_and_cools_to_nothing")
    func aGlintWarmsTheStaveFirstAndCoolsToNothing() {
        #expect(WwwWordmark.heat(0.0, 0.03) > WwwWordmark.heat(0.9, 0.03))
        #expect(WwwWordmark.heat(0.5, WwwWordmark.glintSeconds) == 0.0)
    }

    // MARK: - webDocument / --html tooling verification

    @Test("webAppConfig and --html static export")
    func webAppConfigAndHtmlExport() throws {
        let app = RuneWwwApp.app()
        #expect(app.webAppConfig.webDocument == true)
        #expect(app.webAppConfig.fitContentHeight == true)
        #expect(app.webAppConfig.fontUrls == ["fonts/geist.ttf", "fonts/geist-mono.ttf"])

        let outPath = NSTemporaryDirectory() + "rune_www_test_\(UUID().uuidString).html"
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        _ = try HeadlessRunner.run(app, args: ToolingArgs.parse(["--html", outPath]))
        let html = try String(contentsOfFile: outPath, encoding: .utf8)
        #expect(html.contains("<html"))
        #expect(html.contains("A Rust UI framework"))
    }
}
