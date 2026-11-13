import Foundation
import Testing
@testable import Rune
@testable import RuneMotion
@testable import RuneRef

#if canImport(Metal)
import Metal
#endif

private final class AtomicCounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int = 0

    func inc() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Suite("Shell Cross-Audit Parity Tests (#554/#556)", .serialized)
struct ShellAuditParityTests {

    // MARK: - 1. srgb_blend_runtime.rs (6/6)

    @Test("srgb_blend_runtime: hover tints follow runtime blend mode, live switch redraws, and last tx wins")
    func hoverTintsAndLiveSwitchParity() {
        let red = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let tint = Color.white.alpha(0.5)

        func makeRuntime(srgb: Bool) -> Runtime<Int> {
            let rt = Runtime<Int>(
                state: 0,
                viewport: Vec2(40, 40),
                pixelScale: 1.0,
                systemDark: true
            ) { _, _ in
                el()
                    .size(40, 40)
                    .bg(.black)
                    .child(
                        el()
                            .key("box")
                            .size(20, 20)
                            .bg(red)
                            .hover(tint)
                            .onClick { _ in }
                    )
            }
            rt.setSrgbBlend(srgb, at: 0.0)
            _ = rt.frame(at: 0.0)
            rt.pointerMove(to: Vec2(10, 10), at: 1.0 / 60.0)
            return rt
        }

        func tintedFill(_ scene: RefScene) -> SIMD4<Float>? {
            scene.primitives.first(where: {
                $0.kind == .roundedRect && abs($0.rect.z - 20.0) < 0.01 && abs($0.rect.w - 20.0) < 0.01
            })?.fill
        }

        func expectApprox4(_ a: SIMD4<Float>?, _ b: SIMD4<Float>, tol: Float = 1e-4) {
            guard let a else {
                Issue.record("Missing 20x20 box primitive")
                return
            }
            #expect(abs(a.x - b.x) < tol)
            #expect(abs(a.y - b.y) < tol)
            #expect(abs(a.z - b.z) < tol)
            #expect(abs(a.w - b.w) < tol)
        }

        // 1. hover_tints_follow_the_runtime_blend_mode
        let srgbRt = makeRuntime(srgb: true)
        for step in 2...60 { _ = srgbRt.frame(at: Double(step) / 60.0) }
        let srgbScene = srgbRt.frame(at: 1.0)
        #expect(srgbRt.srgbBlend == true)
        expectApprox4(tintedFill(srgbScene), Color.over(tint.premulSRGB(1.0), red.premulSRGB(1.0)), tol: 2e-3)

        let linearRt = makeRuntime(srgb: false)
        for step in 2...60 { _ = linearRt.frame(at: Double(step) / 60.0) }
        let linearScene = linearRt.frame(at: 1.0)
        expectApprox4(tintedFill(linearScene), Color.over(tint.premul(1.0), red.premul(1.0)), tol: 2e-3)

        // 2. switching_blend_mode_redraws
        _ = linearRt.frame(at: 1.0)
        let commitsBefore = linearRt.viewCommitCount
        linearRt.setSrgbBlend(true, at: 1.0 + 1.0 / 60.0)
        _ = linearRt.frame(at: 1.0 + 1.0 / 60.0)
        #expect(linearRt.viewCommitCount > commitsBefore)
        for step in 2...60 { _ = linearRt.frame(at: 1.0 + Double(step) / 60.0) }
        let afterSwitch = linearRt.frame(at: 2.0)
        expectApprox4(tintedFill(afterSwitch), Color.over(tint.premulSRGB(1.0), red.premulSRGB(1.0)), tol: 2e-3)

        let commitsAfter = linearRt.viewCommitCount
        linearRt.setSrgbBlend(true, at: 2.0 + 1.0 / 60.0)
        _ = linearRt.frame(at: 2.0 + 1.0 / 60.0)
        #expect(linearRt.viewCommitCount == commitsAfter)

        // 3. a_handler_switches_blend_mode_live
        let handlerRt = makeRuntime(srgb: false)
        for step in 2...60 { _ = handlerRt.frame(at: Double(step) / 60.0) }
        handlerRt.update(at: 1.1) { _, tx in tx.setSrgbBlend(true) }
        #expect(handlerRt.srgbBlend == true)
        for step in 1...60 { _ = handlerRt.frame(at: 1.1 + Double(step) / 60.0) }
        let switchedScene = handlerRt.frame(at: 2.1)
        expectApprox4(tintedFill(switchedScene), Color.over(tint.premulSRGB(1.0), red.premulSRGB(1.0)), tol: 2e-3)

        handlerRt.update(at: 2.2) { _, tx in
            tx.setSrgbBlend(true)
            tx.setSrgbBlend(false)
        }
        #expect(handlerRt.srgbBlend == false)
    }

    @Test("srgb_blend_runtime: Metal offscreen renders gamma vs linear pixels, keeps glyph atlas across switch, and HeadlessRunner follows live switch")
    func srgbBlendMetalOffscreenHeadlessAndAtlas() throws {
        let red = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let tint = Color.white.alpha(0.5)

        #if canImport(Metal)
        let renderer = try MetalRenderer()

        func hoveredFrame(srgb: Bool) -> Frame {
            let rt = Runtime<Int>(
                state: 0,
                viewport: Vec2(40, 40),
                pixelScale: 1.0,
                systemDark: true
            ) { _, _ in
                el()
                    .size(40, 40)
                    .bg(.black)
                    .child(el().size(20, 20).bg(red).hover(tint).onClick { _ in })
            }
            rt.setSrgbBlend(srgb, at: 0.0)
            _ = rt.frame(at: 0.0)
            rt.pointerMove(to: Vec2(10, 10), at: 1.0 / 60.0)
            for step in 2...60 { _ = rt.frame(at: Double(step) / 60.0) }
            let scene = rt.frame(at: 1.0)
            return try! renderer.renderOffscreen(scene)
        }

        func pixel(_ f: Frame, x: Int, y: Int) -> [UInt8] {
            let i = (y * f.width + x) * 4
            return [f.rgba[i], f.rgba[i + 1], f.rgba[i + 2], f.rgba[i + 3]]
        }

        func expectPixelNear(_ got: [UInt8], _ want: [UInt8], tol: Int = 2) {
            for (g, w) in zip(got, want) {
                #expect(abs(Int(g) - Int(w)) <= tol)
            }
        }

        // 4. a_self_drawn_runtime_renders_gamma_blended_pixels
        expectPixelNear(pixel(hoveredFrame(srgb: true), x: 10, y: 10), [255, 128, 128, 255])
        expectPixelNear(pixel(hoveredFrame(srgb: false), x: 10, y: 10), [255, 188, 188, 255])

        // 5. switching_format_keeps_the_glyph_atlas_and_extra_pipelines
        let atlasRt = Runtime<Int>(
            state: 0,
            viewport: Vec2(80, 40),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            el().size(80, 40).bg(red).child(text("hello"))
        }
        atlasRt.setSrgbBlend(false, at: 0.0)
        let firstScene = atlasRt.frame(at: 0.0)
        let initialGen = atlasRt.textSystem.glyphAtlas.generation
        _ = try renderer.renderOffscreen(firstScene)

        atlasRt.setSrgbBlend(true, at: 1.0 / 60.0)
        let secondScene = atlasRt.frame(at: 1.0 / 60.0)
        #expect(atlasRt.textSystem.glyphAtlas.generation == initialGen)
        let secondOut = try renderer.renderOffscreen(secondScene)
        #expect(secondOut.width == 80 && secondOut.height == 40)
        #endif

        // 6. a_headless_run_follows_a_live_switch
        final class BlendWatcher: Compositor, @unchecked Sendable {
            typealias State = Int
            var seen: [Bool] = []
            func render(frame: CompositorFrame<Int>) {
                seen.append(frame.srgbBlend)
                frame.drawUI()
            }
        }
        let watcher = BlendWatcher()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rune-srgb-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scriptURL = dir.appendingPathComponent("script.json")
        try #"[{"t": 0.1, "type": "click", "x": 20, "y": 20}]"#.write(to: scriptURL, atomically: true, encoding: .utf8)

        let app = App<Int>("srgb-live", size: Vec2(40, 40), init: { 0 }) { _, _ in
            el()
                .size(40, 40)
                .bg(red)
                .child(el().size(40, 40).bg(tint))
                .onClickPress { _, _, tx in tx.setSrgbBlend(true) }
        }
        .srgbBlend(false)
        .compositor(watcher)
        let args = ToolingArgs.parse(["--scale", "1", "--script", scriptURL.path, "--at", "0.5"])
        let out = try HeadlessRunner.run(app, args: args)
        let pxIdx = (20 * out.finalFrame.width + 20) * 4
        #expect(out.finalFrame.rgba[pxIdx] == 255)
        #expect(abs(Int(out.finalFrame.rgba[pxIdx + 1]) - 128) <= 2)
        // Note: HeadlessRunner invokes Compositor.render only on the final frame unless --frames/--strip is active.
        #expect(watcher.seen == [true])
    }

    // MARK: - 2. App, FrameClock, FrameReports, SurfaceStats & Effects

    @Test("App defaults usesStandardMenus false, standardMenus setter, and windowless implies keepsRunning")
    func appDefaultsMenusAndWindowless() {
        let app = App<Int>("test", size: Vec2(100, 100), init: { 0 }) { _, _ in el() }
        #expect(app.usesStandardMenus == false)
        #expect(app.keepsRunning == false)
        #expect(app.standardMenus(true).usesStandardMenus == true)
        let wl = app.windowless(true)
        #expect(wl.isWindowless == true)
        #expect(wl.keepsRunning == true)
        #expect(app.windowless(false).keepsRunning == false)
    }

    @Test("updates commit on the next frame with tx.instant(), quit outranks closeWindow, and unchanging wakeAfter survives frame")
    func appRuntimeRequestsAndUnchangingTimer() {
        struct S { var width: Float = 10 }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            row().child(el().key("box").size(s.width, 10))
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.0) { s, tx in
            s.width = 40
            tx.instant()
        }
        #expect(!rt.closeWindowRequested && !rt.quitRequested)
        _ = rt.frame(at: 1.0 / 120.0)
        #expect(rt.element(byKey: "box")?.rect[2] == 40.0)

        rt.update(at: 0.1) { _, tx in tx.closeWindow() }
        rt.update(at: 0.1) { _, tx in tx.quit() }
        rt.update(at: 0.1) { _, tx in tx.closeWindow() }
        #expect(rt.quitRequested == true)

        func runTimer(changed: Bool) -> Double? {
            let timerRt = Runtime<Int>(state: 0, viewport: Vec2(100, 100), pixelScale: 1.0) { n, _ in
                row().child(el().key("box").size(10 + Float(n), 10))
            }
            _ = timerRt.frame(at: 0.0)
            _ = timerRt.updateIf(at: 1.0) { _, tx in
                tx.wakeAfter(0.0)
                return changed
            }
            timerRt.update(at: 1.0) { n, _ in n += 1 }
            _ = timerRt.frame(at: 1.0)
            return timerRt.nextWakeDeadline(after: 1.0)
        }

        let dChanged = runTimer(changed: true)
        let dUnchanged = runTimer(changed: false)
        #expect(dChanged != nil)
        #expect(dUnchanged == dChanged)
    }

    @Test("FrameClock splits running vs new motion, preserves hold target, and clamps presented(done:) by maxGap")
    func frameClockSplittingHoldAndPresentedMaxGap() {
        let clock = FrameClock(start: 0.0)
        let fresh = FrameClockStep(catchUp: 0.0, dt: FrameClock.resumeStep)

        #expect(clock.frameStep(at: 0.005, running: false) == fresh)
        #expect(clock.frameStep(at: 2.005, running: false) == fresh)

        let late = clock.frameStep(at: 2.054, running: true)
        #expect(abs(late.total - 0.049) < 1e-9)
        #expect(late.dt == FrameClock.resumeStep)

        let short = clock.frameStep(at: 2.058, running: true)
        #expect(abs(short.dt - 0.004) < 1e-9)
        #expect(short.catchUp == 0.0)

        let suspended = clock.frameStep(at: 5.058, running: true)
        #expect(abs(suspended.total - FrameClock.maxGap) < 1e-9)
        #expect(suspended.dt == FrameClock.resumeStep)

        clock.hold(at: 6.000)
        #expect(clock.frameStep(at: 6.000, running: true) == FrameClockStep(catchUp: 0.0, dt: 0.0))

        clock.hold(at: 6.010)
        clock.hold(at: 6.002)
        let next = clock.frameStep(at: 6.018, running: true)
        #expect(abs(next.total - 0.008) < 1e-9)

        // presented(done:) clamps late overrun to FrameClock.maxGap while keeping Phase::Presented { last } (clock.rs:130)
        _ = clock.frameStep(at: 7.000, running: true)
        let clampedLate = clock.presented(done: 9.000)
        #expect(abs(clampedLate - FrameClock.maxGap) < 1e-9)
        let afterOverrun = clock.frameStep(at: 7.266, running: true)
        #expect(abs(afterOverrun.total - FrameClock.maxGap) < 1e-9)
    }

    @Test("FrameReports numbers frames, separates update/encode, handles refreshHz and nil hooks")
    func frameReportsParity() {
        var encodedLog: [FrameEncoded] = []
        var drawnCount = 0
        let reports = FrameReports<Int>(
            onFrameEncoded: { encodedLog.append($0) },
            onFrameDrawn: { _, _, _ in drawnCount += 1 }
        )

        reports.record(FrameEncoded(
            outcome: .drawn,
            frameMs: 5.0,
            updateMs: 2.0,
            encodeMs: 3.0,
            at: 10.005,
            window: "main",
            seq: 0,
            presentsAt: 10.008,
            started: 10.0,
            refreshHz: 120.0
        ))
        reports.record(FrameEncoded(outcome: .unchanged, at: 10.010, window: "main", presentsAt: 10.008, refreshHz: 120.0))
        reports.record(FrameEncoded(outcome: .skipped, at: 10.012, window: "main", presentsAt: nil, refreshHz: nil))

        #expect(encodedLog.map(\.seq) == [0, 1, 2])
        #expect(encodedLog.map(\.outcome) == [.drawn, .unchanged, .skipped])
        #expect(encodedLog.map(\.window) == ["main", "main", "main"])
        #expect(encodedLog[0].updateMs == 2.0 && encodedLog[0].encodeMs == 3.0)
        #expect(encodedLog[0].started == 10.0)
        #expect(encodedLog[1].refreshHz == 120.0)
        #expect(encodedLog[2].presentsAt == nil)

        var state = 0
        var tx = Tx()
        #expect(reports.flush(state: &state, tx: &tx, at: 10.2, force: false) == true)
        #expect(drawnCount == 1)

        // encoded_tests.rs:87 - WindowSpec inherits App's onFrameEncoded until it sets its own.
        var appHooks = 0
        var winHooks = 0
        let baseApp = App<Int>(state: 0) { _, _ in el() }.onFrameEncoded { _ in appHooks += 1 }
        let inherited = AppWindowSpec.fromApp(baseApp, key: "inherited")
        let overridden = inherited.onFrameEncoded { _ in winHooks += 1 }
        inherited.onFrameEncoded?(FrameEncoded(outcome: .drawn, at: 0.0, window: "inherited"))
        overridden.onFrameEncoded?(FrameEncoded(outcome: .drawn, at: 0.0, window: "overridden"))
        #expect(appHooks == 1 && winHooks == 1)

        // encoded_tests.rs:103 - Inspector hook reads the Runtime that presented the frame.
        var inspectedText: String?
        let rt = Runtime<Int>(state: 42, viewport: Vec2(100, 100), pixelScale: 1.0) { s, _ in
            text("\(s)").key("val")
        }
        _ = rt.frame(at: 0.0)
        let inspectReports = FrameReports<Int>(onInspectDrawn: { runtime in
            inspectedText = runtime.element(byKey: "val")?.text
        })
        inspectReports.inspect(rt)
        #expect(inspectedText == "42")
    }

    @Test("SurfaceMeter rates roll per second, go stale, publish totals immediately, and distinguish unpaced")
    func surfaceMeterRatesTotalsAndUnpacedParity() {
        let meter = SurfaceMeter(name: "main", now: 0.0)
        for _ in 0..<120 {
            _ = meter.redraw(paced: true, now: 0.5)
            _ = meter.presented(now: 0.5)
        }
        for _ in 0..<3 {
            _ = meter.failed(.timeout, now: 0.5)
        }
        _ = meter.skipped(now: 0.5)
        _ = meter.turn(woke: false, waited: false, now: 0.5)
        _ = meter.turn(woke: true, waited: false, now: 0.5)
        meter.setPacing(.paced)
        #expect(meter.currentStats().rates == SurfaceCounts())

        #expect(meter.tick(now: 1.0) == nil)
        let s1 = meter.currentStats()
        #expect(s1.name == "main")
        #expect((s1.rates.redraws, s1.rates.unpaced, s1.rates.presents) == (120, 0, 120))
        #expect((s1.rates.timeouts, s1.rates.failedCount, s1.rates.skipped) == (3, 3, 1))
        #expect((s1.rates.turns, s1.rates.wakes) == (2, 1))
        #expect(s1.pacing == .paced)
        #expect(s1.totals.presents == 120)

        for _ in 0..<60 {
            _ = meter.redraw(paced: false, now: nil)
            _ = meter.presented(now: nil)
        }
        _ = meter.tick(now: 3.0)
        let s3 = meter.currentStats()
        #expect((s3.rates.redraws, s3.rates.unpaced, s3.rates.presents) == (30, 30, 30))
        #expect((s3.totals.redraws, s3.totals.presents) == (180, 180))

        let fresh = s3.aged(at: 4.0)
        #expect(fresh.rates.presents == 30)
        let stale = s3.aged(at: 5.5)
        #expect(stale.rates == SurfaceCounts())
        #expect(stale.totals.presents == 180)

        // Only redraws that waited for nothing count as unpaced
        let uMeter = SurfaceMeter(name: "u", now: 0.0)
        _ = uMeter.redraw(paced: true, now: 0.1)
        #expect(uMeter.totalsSnapshot().unpaced == 0)
        uMeter.noteWaited()
        _ = uMeter.redraw(paced: false, now: 0.1)
        #expect(uMeter.totalsSnapshot().unpaced == 0)
        _ = uMeter.turn(woke: true, waited: true, now: 0.1)
        _ = uMeter.redraw(paced: false, now: 0.1)
        #expect(uMeter.totalsSnapshot().unpaced == 0)
        _ = uMeter.turn(woke: true, waited: false, now: 0.1)
        _ = uMeter.redraw(paced: false, now: 0.1)
        #expect(uMeter.totalsSnapshot().unpaced == 1)
    }

    @Test("Effects emptied isEmpty parity (machine_tests)")
    func effectsEmptyAfterDrain() {
        var effects = Effects<Int>.two(1, 2)
        effects.push(3)
        #expect(effects.array == [1, 2, 3])
        effects = .none
        #expect(effects.isEmpty)
        effects.push(4)
        #expect(!effects.isEmpty && effects.array == [4])
    }

    // MARK: - 3. Memo, Cx, layoutWith, cached, virtualRows, TextInput & MeasureScope

    @Test("Memo: exact layout/caret matching, layoutWith/windowLayoutWith tracking, Cx.absorb dedup, duplicate guard, cached siblings, throw cleanup, and virtualRows")
    func memoAndCxAuditParity() {
        // 1. Cx.absorb deduplicates layoutReads
        let absorbCache = MemoCache()
        MemoScope.enter(
            cache: absorbCache,
            envHash: 1,
            geometry: [
                "a": MemoElementGeometry(rect: MotionRect.fromXYWH(0, 0, 10, 10)),
                "b": MemoElementGeometry(rect: MotionRect.fromXYWH(0, 0, 20, 20)),
            ]
        ) {
            var parentCx = Cx<Int>(viewport: Vec2(100, 100), pixelScale: 1.0, systemDark: true)
            _ = parentCx.layoutWith("a") { $0[2] }
            let childCx: Cx<String> = parentCx.retype()
            _ = childCx.layoutWith("a") { $0[2] }
            _ = childCx.layoutWith("b") { $0[2] }
            parentCx.absorb(childCx)
            #expect(parentCx.envState.reads.layoutReads.count == 2)
        }

        // 2. cx.layoutWith, cx.windowLayoutWith, and whole-rect 0.5pt tolerance (`memo.rs:1244, 1267`)
        struct Probe { var width: Float = 100; var y: Float = 0; var ticks: Int = 0 }
        var layoutWithBuilds = 0
        var winWithBuilds = 0
        var winWholeBuilds = 0
        let probeRt = Runtime<Probe>(state: Probe(), viewport: Vec2(300, 300), pixelScale: 1.0) { s, cx in
            col().size(300, 300)
                .child(el().key("gap").size(10, s.y))
                .child(el().key("probe").size(s.width, 10))
                .child(memo("lw", 0) { () -> El<Probe> in
                    layoutWithBuilds += 1
                    let w: Float = cx.layoutWith("probe") { $0[2] } ?? -1
                    return text("lw:\(w)").key("lw-label")
                })
                .child(memo("wlw", 0) { () -> El<Probe> in
                    winWithBuilds += 1
                    let y: Float = cx.windowLayoutWith("probe") { $0[1] } ?? -1
                    return text("wlw:\(y)").key("wlw-label")
                })
                .child(memo("r3", 0) { () -> El<Probe> in
                    winWholeBuilds += 1
                    let y: Float = cx.windowLayout("probe")?[1] ?? -1
                    return text("r3:\(y)").key("r3-label")
                })
                .child(text("tick:\(s.ticks)").key("tick"))
        }
        _ = probeRt.frame(at: 0.0)
        _ = probeRt.frame(at: 0.01) // settle read pass
        let lwStable = layoutWithBuilds
        let wlwStable = winWithBuilds
        let wholeStable = winWholeBuilds
        for _ in 0..<3 {
            probeRt.update(at: 0.02) { s, _ in s.ticks += 1 }
            _ = probeRt.frame(at: 0.02)
        }
        #expect(layoutWithBuilds == lwStable)
        #expect(winWithBuilds == wlwStable)
        #expect(winWholeBuilds == wholeStable)

        // Sub-0.5pt move: projection (`windowLayoutWith`) uses exact == and rebuilds,
        // while whole-rect (`windowLayout`) keeps its 0.5pt tolerance until delta >= 0.5pt.
        probeRt.update(at: 0.03) { s, _ in s.y = 0.3 }
        _ = probeRt.frame(at: 0.03)
        #expect(winWithBuilds > wlwStable)
        #expect(winWholeBuilds == wholeStable)

        probeRt.update(at: 0.035) { s, _ in s.y = 0.6 }
        _ = probeRt.frame(at: 0.035)
        #expect(winWholeBuilds > wholeStable)

        probeRt.update(at: 0.04) { s, _ in s.width = 150 }
        _ = probeRt.frame(at: 0.04)
        #expect(layoutWithBuilds > lwStable)
        #expect(probeRt.element(byKey: "lw-label")?.text == "lw:150.0")

        // 3. Duplicate memo & region on the same pass both build
        let dupCache = MemoCache()
        var dupMemoBuilds = 0
        var dupRegionBuilds = 0
        MemoScope.enter(cache: dupCache, envHash: 1) {
            let m1: El<Int> = memo("dup", 0, cache: dupCache) { dupMemoBuilds += 1; return el().key("m1") }
            let m2: El<Int> = memo("dup", 0, cache: dupCache) { dupMemoBuilds += 1; return el().key("m2") }
            let r1: El<Int> = region("dupR", cache: dupCache) { dupRegionBuilds += 1; return el().key("r1") }
            let r2: El<Int> = region("dupR", cache: dupCache) { dupRegionBuilds += 1; return el().key("r2") }
            #expect(m1.keyId == "m1" && m2.keyId == "m2")
            #expect(r1.keyId == "r1" && r2.keyId == "r2")
        }
        #expect(dupMemoBuilds == 2)
        #expect(dupRegionBuilds == 2)

        // 4. Throwing inside memo restores scope so subsequent runtime frames cache normally
        struct Boom: Error {}
        let throwCache = MemoCache()
        do {
            try MemoScope.enter(cache: throwCache, envHash: 1) {
                let _: El<Int> = try {
                    throw Boom()
                }()
            }
            Issue.record("Expected Boom")
        } catch {}
        #expect(MemoScope.current == nil)

        // 5. cached_unkeyed_siblings_keep_index_paths_and_leave_no_key_warnings
        var cachedBuilds = 0
        let cachedRt = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0) { _, _ in
            col().wFull()
                .child(cached(memoDigest("same")) { cachedBuilds += 1; return text("one") })
                .child(cached(memoDigest("same")) { cachedBuilds += 1; return text("one") })
                .child(cached(memoDigest("other")) { cachedBuilds += 1; return text("two") }.key("named"))
        }
        _ = cachedRt.frame(at: 0.0)
        #expect(cachedBuilds == 3)
        #expect(cachedRt.keyWarnings.isEmpty)
        let paths = cachedRt.elements().map(\.path)
        #expect(paths == ["/0", "/0/0", "/0/1", "/0/@named"])
        cachedRt.update(at: 0.01) { t, _ in t += 1 }
        _ = cachedRt.frame(at: 0.02)
        #expect(cachedBuilds == 3)
        #expect(cachedRt.keyWarnings.isEmpty)

        // 6. virtual_rows_scroll_out_and_back_in_without_building + offscreen focused field
        struct RowsState {
            var listState = VirtualListState()
            var edits: [TextEdit] = (0..<100).map { _ in TextEdit("") }
            var tick: Int = 0
        }
        var rowBuilds = 0
        let vRt = Runtime<RowsState>(
            state: RowsState(),
            viewport: Vec2(200, 200),
            pixelScale: 1.0
        ) { s, cx in
            let scrollY = cx.scrollOffset(of: "vscroll").y
            return col().size(200, 200).scroll()
                .key("vscroll")
                .child(
                    virtualRows(
                        key: "rows",
                        state: s.listState,
                        count: 100,
                        estimatedHeight: 40,
                        scrollY: scrollY,
                        viewportHeight: 200
                    ) { i in
                        memo("vrow-\(i)", s.edits[i]) {
                            rowBuilds += 1
                            return col().key("vrow-\(i)").size(200, 40)
                                .child(textInput(key: "field-\(i)", \RowsState.edits[i]).size(200, 40))
                        }
                    }
                )
        }
        _ = vRt.frame(at: 0.0)
        vRt.pointerDown(at: Vec2(20, 20), at: 0.005)
        vRt.pointerUp(at: Vec2(20, 20), at: 0.006)
        _ = vRt.frame(at: 0.01)
        let initialRowBuilds = rowBuilds
        #expect(initialRowBuilds < 30)
        // Scroll down past row-0
        vRt.wheel(WheelEvent(dx: 0, dy: -2000), at: Vec2(100, 100), now: 0.02)
        _ = vRt.frame(at: 0.04)
        #expect(vRt.element(byKey: "field-0") == nil)

        // Scroll back up to row-0: row 0 was only built once when mounted and stabilizes when scrolled back
        vRt.wheel(WheelEvent(dx: 0, dy: 2000), at: Vec2(100, 100), now: 0.1)
        _ = vRt.frame(at: 0.12)
        #expect(vRt.element(byKey: "field-0") != nil)
        let afterScrollBackBuilds = rowBuilds
        vRt.update(at: 0.14) { s, _ in s.tick += 1 }
        _ = vRt.frame(at: 0.16)
        #expect(rowBuilds == afterScrollBackBuilds)

        // 7. Memoized TextEdit caret movement + IME composition (`memo.rs:1159`)
        struct ImeState { var edit = TextEdit("ab") }
        let imeRt = Runtime<ImeState>(state: ImeState(), viewport: Vec2(200, 100), pixelScale: 1.0) { s, _ in
            col().size(200, 100).child(
                memo("field", s.edit) {
                    textInput(key: "field", \ImeState.edit).size(200, 40)
                }
            )
        }
        _ = imeRt.frame(at: 0.0)
        imeRt.pointerDown(at: Vec2(20, 20), at: 0.005)
        imeRt.pointerUp(at: Vec2(20, 20), at: 0.006)
        _ = imeRt.frame(at: 0.01)
        _ = imeRt.keyDown(KeyEvent(key: .arrowLeft), at: 1.0 / 60.0)
        _ = imeRt.frame(at: 1.0 / 60.0)
        _ = imeRt.dispatchImeEvent(.preedit("X", cursorUTF8: nil, clauses: []), at: 2.0 / 60.0)
        _ = imeRt.frame(at: 2.0 / 60.0)
        #expect(imeRt.state.edit.preedit?.text == "X")
        _ = imeRt.dispatchImeEvent(.commit("X"), at: 3.0 / 60.0)
        _ = imeRt.frame(at: 3.0 / 60.0)
        #expect(imeRt.state.edit.text == "aXb")

        var selEdit1 = TextEdit("ab")
        let selEdit0 = selEdit1
        selEdit1.selectAll()
        #expect(selEdit0 != selEdit1)

        // 8. cx.caret read inside reused memo keeps following caret (`memo.rs:1285`)
        struct CaretState { var edit = TextEdit("") }
        let caretRt = Runtime<CaretState>(state: CaretState(), viewport: Vec2(300, 300), pixelScale: 1.0) { _, cx in
            col().size(300, 300)
                .child(textInput(key: "field", \CaretState.edit).size(300, 40))
                .child(memo("label", 0) { () -> El<CaretState> in
                    let x: Float = cx.caret("field")?[0] ?? -1
                    return text("caret \(x)").key("label")
                })
        }
        _ = caretRt.frame(at: 0.0)
        caretRt.pointerDown(at: Vec2(20, 20), at: 0.005)
        caretRt.pointerUp(at: Vec2(20, 20), at: 0.006)
        _ = caretRt.frame(at: 1.0 / 60.0)
        _ = caretRt.frame(at: 1.0 / 60.0)
        let caretStart = caretRt.element(byKey: "label")?.text
        #expect(caretStart != nil && caretStart != "caret -1.0")
        for step in 1...3 {
            let t = Double(step + 1) * (1.0 / 60.0)
            _ = caretRt.keyDown(KeyEvent(key: .text("w")), at: t)
            _ = caretRt.frame(at: t)
            _ = caretRt.frame(at: t)
        }
        #expect(caretRt.element(byKey: "label")?.text != caretStart)

        // 9. memo records caller file/line location (`memo.rs:1312`)
        let expectedLine = #line + 1
        let locBuilt: El<Int> = memo("id", 0) { el() }
        #expect(locBuilt.keyLocation.hasPrefix("\(#fileID):\(expectedLine):"))
    }

    @Test("withFontFamilies nests, bumps fontEpoch, and affects TextSystem.measure")
    func withFontFamiliesMeasuresAndRestores() {
        let ts = TextSystem()
        let style = TextStyle(size: 14, weight: 400).mono()
        let sample = "let mono = 42; // iiiiiiiiii"
        _ = FontFamiliesRegistry.setFamilies(sans: "Helvetica", mono: "Helvetica")
        defer { _ = FontFamiliesRegistry.setFamilies(sans: "", mono: "") }

        let baseEpoch = fontEpoch()
        let baseWidth = ts.shape(text: sample, style: style, maxWidth: nil, pixelScale: 1.0, emitGlyphs: false).size.x

        withFontFamilies(sans: "Helvetica", mono: "Courier New") {
            let outerEpoch = fontEpoch()
            let courierWidth = ts.shape(text: sample, style: style, maxWidth: nil, pixelScale: 1.0, emitGlyphs: false).size.x
            #expect(outerEpoch != baseEpoch)
            #expect(courierWidth != baseWidth)

            withFontFamilies(sans: "Helvetica", mono: "Helvetica") {
                #expect(ts.shape(text: sample, style: style, maxWidth: nil, pixelScale: 1.0, emitGlyphs: false).size.x == baseWidth)
                #expect(fontEpoch() != outerEpoch)
            }
            #expect(ts.shape(text: sample, style: style, maxWidth: nil, pixelScale: 1.0, emitGlyphs: false).size.x == courierWidth)
        }
        #expect(ts.shape(text: sample, style: style, maxWidth: nil, pixelScale: 1.0, emitGlyphs: false).size.x == baseWidth)
    }

    // MARK: - 4. Live, LiveWake, Tween & liveOnly drag

    @Test("Live<Color>: concurrent producers never tear lanes, LiveWake coalesces/visibility, and non-finite sanitization")
    func liveConcurrencyWakeAndSanitization() {
        // 1. concurrent_producers_never_tear_color_lanes
        let sharedColor = Live<Color>(.white)
        let group = DispatchGroup()
        for writer in 0..<4 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for i in 0..<5_000 {
                    let n = Float(i * 4 + writer)
                    sharedColor.set(Color(r: n, g: n, b: n, a: n))
                }
                group.leave()
            }
        }
        for _ in 0..<10_000 {
            let c = sharedColor.get()
            #expect(c.r == c.g && c.g == c.b && c.b == c.a)
        }
        group.wait()

        // 2. subscriptions_coalesce_and_respect_visibility_and_lifetime
        let live = Live<Float>(0.0)
        let wakeCounter = AtomicCounterBox()
        var wake: LiveWake? = LiveWake { wakeCounter.inc() }
        let sub = live.subscribe(wake!)
        #expect(sub === live.subscribe(wake!))
        #expect(live.set(0.0) == false)
        for n in 1..<100 {
            _ = live.set(Float(n))
        }
        #expect(wakeCounter.value == 1)
        #expect(wake!.takeVisible() == true)
        wake!.visible(false)
        #expect(live.set(100.0) == true)
        #expect(wakeCounter.value == 1)
        wake!.visible(true)
        #expect(wakeCounter.value == 2)
        #expect(wake!.takeVisible() == true)
        sub.isActive = false
        _ = live.set(101.0)
        #expect(wake!.isVisiblePending == false)
        sub.isActive = true
        weak var weakWake: LiveWake?
        weakWake = wake
        wake = nil
        #expect(weakWake == nil)
        _ = live.set(102.0)
        #expect(wakeCounter.value == 2)

        // LiveText.subscribe(LiveWake) parity
        let lt = LiveText("init")
        let ltCounter = AtomicCounterBox()
        let ltWake = LiveWake { ltCounter.inc() }
        let ltSub = lt.subscribe(ltWake)
        #expect(ltSub === lt.subscribe(ltWake))
        _ = lt.set("next")
        #expect(ltCounter.value == 1)

        // 3. Color & MotionRect non-finite sanitization
        let lColor = Live<Color>(Color(r: 1, g: 0, b: 0, a: 1))
        #expect(lColor.set(Color(r: .nan, g: 0, b: 0, a: 1)) == false)
        #expect(lColor.set(Color(r: .infinity, g: -.infinity, b: -0.0, a: 1)) == true)
        let cOut = lColor.get()
        #expect(cOut.r == Float.greatestFiniteMagnitude)
        #expect(cOut.g == -Float.greatestFiniteMagnitude)
        #expect(cOut.b.bitPattern == Float(0.0).bitPattern)

        let lRect = Live<MotionRect>(.zero)
        #expect(lRect.set(MotionRect.fromXYWH(.nan, 0, 10, 10)) == false)
        #expect(lRect.set(MotionRect.fromXYWH(-0.0, 0, .infinity, 10)) == true)
        let rOut = lRect.get()
        #expect(rOut.x.bitPattern == Float(0.0).bitPattern)
        #expect(rOut.width == Float.greatestFiniteMagnitude)
    }

    @Test("Live: liveRect restore, Tween remount resumes start, and liveOnly drag keeps capture without view commits")
    func liveRectTweenRemountAndLiveOnlyDrag() {
        // 1. liveRect unbinding restores layout
        struct RectState { var box = Live<MotionRect>(.fromXYWH(10, 20, 80, 40)); var bound = true }
        let rectRt = Runtime<RectState>(state: RectState(), viewport: Vec2(300, 300), pixelScale: 1.0) { s, _ in
            let box: El<RectState> = el().key("box").size(40, 20).bg(.white)
            let child: El<RectState> = s.bound ? box.liveRect(s.box.binding) : box
            return el().size(300, 300)
                .child(child)
                .child(el().key("sibling").size(20, 20))
        }
        _ = rectRt.frame(at: 0.0)
        #expect(rectRt.element(byKey: "box")?.rect == [10, 20, 80, 40])
        rectRt.state.box.set(.fromXYWH(20, 30, 60, 50))
        _ = rectRt.frame(at: 0.01)
        #expect(rectRt.element(byKey: "box")?.rect == [20, 30, 60, 50])
        rectRt.update(at: 0.02) { s, tx in s.bound = false; tx.settle() }
        _ = rectRt.frame(at: 0.02)
        #expect(rectRt.element(byKey: "box")?.rect == [0, 0, 40, 20])

        // 2. Tween remount keeps start & independent runtimes isolate clocks
        struct TweenState { var tween = Tween<Float>.linear(from: 1.0, to: 0.0, duration: 10.0); var shown = true }
        func tweenView(_ s: TweenState, _ cx: inout Cx<TweenState>) -> El<TweenState> {
            _ = cx
            let root: El<TweenState> = el().size(100, 100)
            return s.shown ? root.child(el().key("countdown").size(20, 20).liveOpacity(s.tween.binding)) : root
        }
        let sharedTween = Tween<Float>.linear(from: 1.0, to: 0.0, duration: 10.0)
        let rt1 = Runtime<TweenState>(state: TweenState(tween: sharedTween, shown: true), viewport: Vec2(100, 100), pixelScale: 1.0, view: tweenView)
        _ = rt1.frame(at: 0.0)
        _ = rt1.frame(at: 2.0)
        rt1.update(at: 2.0) { s, tx in s.shown = false; tx.settle() }
        _ = rt1.frame(at: 2.0)
        #expect(rt1.element(byKey: "countdown") == nil)
        rt1.update(at: 5.0) { s, tx in s.shown = true; tx.settle() }
        _ = rt1.frame(at: 5.0)
        #expect(abs((rt1.element(byKey: "countdown")?.opacity ?? -1) - 0.5) < 0.01)

        let rt2 = Runtime<TweenState>(state: TweenState(tween: sharedTween, shown: true), viewport: Vec2(100, 100), pixelScale: 1.0, view: tweenView)
        _ = rt2.frame(at: 0.0)
        #expect(abs((rt2.element(byKey: "countdown")?.opacity ?? -1) - 1.0) < 0.001)

        // 3. live_only_drag_keeps_capture_outside_the_moving_element
        struct DragState { var pan = Live<Vec2>(.zero); var deltas: [Vec2] = [] }
        let dragRt = Runtime<DragState>(state: DragState(), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            el().child(
                el().key("drag").size(40, 40).liveOffset(s.pan.binding)
                    .onDrag { st, d, tx in
                        st.deltas.append(d.delta)
                        st.pan.set(d.delta)
                        tx.liveOnly()
                    }
            )
        }
        _ = dragRt.frame(at: 0.0)
        dragRt.pointerDown(at: Vec2(20, 20), at: 0.01)
        _ = dragRt.frame(at: 0.01)
        let commitsAfterDown = dragRt.viewCommitCount
        dragRt.pointerMove(to: Vec2(300, 300), at: 0.02)
        _ = dragRt.frame(at: 0.02)
        #expect(dragRt.pressedPath != nil)
        #expect(dragRt.viewCommitCount == commitsAfterDown)
        dragRt.pointerUp(at: Vec2(350, 350), at: 0.03)
        _ = dragRt.frame(at: 0.03)
        #expect(dragRt.pressedPath == nil)
        #expect(dragRt.state.deltas.count >= 2)
    }

    // MARK: - 5. Growth (7 missing growth.rs tests)

    @Test("GrowTrack: 30/120fps parity, monotone/capped, whole glide, reach jerk, easing, fold handoff, retarget velocity")
    func growthRemainingSevenParity() {
        func runTrack(fps: Float, dist: Float) -> [(Float, Float)] {
            var t = GrowTrack.settled(0)
            t.retarget(dist)
            var acc: Float = 0
            var out: [(Float, Float)] = []
            let dt: Float = 1.0 / fps
            for k in 1...Int(2.0 * fps) {
                acc += dt
                while acc >= Growth.substep - 1e-6 {
                    t.step(spring: Growth.spring, edge: .feather, carryingTail: false)
                    acc -= Growth.substep
                }
                out.append((Float(k) * dt, t.h))
            }
            return out
        }

        // 1. same_curve_at_30_60_120_fps
        let a30 = runTrack(fps: 30, dist: 457)
        let c120 = runTrack(fps: 120, dist: 457)
        for (time, h) in a30 {
            let match = c120.first { abs($0.0 - time) < 1e-3 }!
            #expect(abs(h - match.1) < 0.5)
        }

        // 2. monotone_and_capped
        let mono = runTrack(fps: 120, dist: 900)
        var prevH: Float = 0
        for (_, h) in mono {
            #expect(h >= prevH - 1e-4)
            #expect(h - prevH <= Growth.Caps.maxLong / 120.0 + 0.01)
            prevH = h
        }
        #expect(abs((mono.last?.1 ?? 0) - 900.0) < 0.5)

        // 3. a_whole_row_glides_on_the_spring_alone
        var whole = GrowTrack.settled(0)
        whole.whole = true
        whole.retarget(900)
        var wholePrev: Float = 0
        var wholeSpeeds: [Float] = []
        for _ in 0..<180 {
            for _ in 0..<2 { whole.step(spring: Growth.spring, edge: .feather, carryingTail: true) }
            #expect(whole.h >= wholePrev - 1e-4 && whole.h <= 900)
            wholeSpeeds.append(whole.h - wholePrev)
            wholePrev = whole.h
        }
        let in06s = wholeSpeeds.prefix(Int(0.6 * 120)).reduce(0, +)
        #expect(in06s > 0.98 * 900)
        #expect(!whole.moving)

        // 4. a_far_whole_glide_opens_no_harder_than_its_reach
        func maxJerk(dist: Float) -> Float {
            var t = GrowTrack.settled(0)
            t.whole = true
            t.retarget(dist)
            var p: Float = 0
            var step: Float = 0
            var most: Float = 0
            for _ in 0..<360 {
                t.step(spring: Growth.spring, edge: .feather, carryingTail: false)
                t.step(spring: Growth.spring, edge: .feather, carryingTail: false)
                most = max(most, abs((t.h - p) - step))
                step = t.h - p
                p = t.h
            }
            #expect(!t.moving)
            return most
        }
        let omega = 2.0 * Float.pi / Growth.spring.duration
        let reachMost = Growth.wholeReach * omega * omega / (120.0 * 120.0)
        #expect(maxJerk(dist: Growth.wholeReach / 2.0) < 0.6 * reachMost)
        for d: Float in [Growth.wholeReach, 900, 3600] {
            #expect(maxJerk(dist: d) <= reachMost)
        }

        // 5. eases_into_target (`growth.rs:667`)
        for streaming in [false, true] {
            var t = GrowTrack.settled(0)
            t.streaming = streaming
            t.retarget(300)
            var speeds: [Float] = []
            var p: Float = 0
            for _ in 0..<120 {
                for _ in 0..<4 {
                    t.step(spring: Growth.spring, edge: .feather, carryingTail: false)
                }
                speeds.append(t.h - p)
                p = t.h
            }
            for (w0, w1) in zip(speeds, speeds.dropFirst()) {
                #expect(!(w0 >= 0.5 && w1 <= 0.15 * w0), "stop-dead frame at \(w0) -> \(w1)")
            }
        }

        // 6. a_glide_handed_to_a_whole_row_mid_way_carries_on
        var handed = GrowTrack.settled(40)
        handed.whole = true
        handed.setKind(streaming: false, whole: true, glide: (FoldGlide(spring: Spring(duration: 0.35, bounce: 0)), 200))
        handed.retarget(640)
        for _ in 0..<10 { handed.step(spring: Growth.spring, edge: .feather, carryingTail: false) }
        handed.setKind(streaming: false, whole: true, glide: nil)
        var handPrev = handed.h
        while handed.moving {
            handed.step(spring: Growth.spring, edge: .feather, carryingTail: false)
            #expect(handed.h - handPrev < 20.0)
            handPrev = handed.h
        }
        #expect(abs(handed.h - 640.0) < 0.01)

        // 7. retarget_keeps_velocity
        var ret = GrowTrack.settled(0)
        ret.retarget(100)
        for _ in 0..<24 { ret.step(spring: Growth.spring, edge: .feather, carryingTail: false) }
        let (h0, v0) = (ret.h, ret.v)
        ret.retarget(200)
        ret.step(spring: Growth.spring, edge: .feather, carryingTail: false)
        #expect(abs(ret.v - v0) < abs(v0) * 0.5 + 60.0)
        #expect(ret.h > h0)
    }

    // MARK: - 6. Flight, fly_text_scoped & launch_ancestor_spring

    @Test("TextFlightState moving destination, 30Hz vs 120Hz determinism, reducedMotion fades, and selectors")
    func flightUnitParity() {
        func makeFlight() -> TextFlightState {
            TextFlightState(
                sourceKey: "source",
                targetKey: "target",
                source: MotionRect.fromXYWH(40, 400, 500, 40),
                born: 0.0
            )
        }

        // 1. moving_destination_uses_shared_progress_without_restarting_it
        var f = makeFlight()
        _ = f.measure(target: MotionRect.fromXYWH(120, 260, 400, 22), now: 0.0, reducedMotion: false)
        let p = f.progress(at: 0.08, reducedMotion: false)
        _ = f.measure(target: MotionRect.fromXYWH(120, 220, 400, 22), now: 0.08, reducedMotion: false)
        #expect(f.progress(at: 0.08, reducedMotion: false) == p)
        #expect(abs(f.presented.y - (400.0 + (220.0 - 400.0) * p)) < 1e-4)
        #expect(f.measure(target: MotionRect.fromXYWH(120, 220, 400, 22), now: 2.0, reducedMotion: false) == true)

        // 2. flight_is_time_based_and_reduced_motion_only_fades
        let target = MotionRect.fromXYWH(120, 260, 400, 22)
        var slow = makeFlight()
        var fast = makeFlight()
        _ = slow.measure(target: target, now: 0.0, reducedMotion: false)
        _ = fast.measure(target: target, now: 0.0, reducedMotion: false)
        for i in 1...30 {
            _ = slow.measure(target: target, now: Double(i) / 30.0, reducedMotion: false)
            for j in (i * 4 - 3)...(i * 4) {
                _ = fast.measure(target: target, now: Double(j) / 120.0, reducedMotion: false)
            }
            #expect(slow.presented == fast.presented)
        }
        var rm = makeFlight()
        #expect(rm.measure(target: target, now: 0.075, reducedMotion: true) == false)
        #expect(rm.presented == target)
        let alphas = rm.alphas(target: target, now: 0.075, reducedMotion: true)
        #expect(abs(alphas.source - 0.5) < 1e-4 && abs(alphas.target - 0.5) < 1e-4)
        #expect(rm.measure(target: target, now: 0.15, reducedMotion: true) == true)

        // 3. selectors_match_a_key_or_its_keyed_ancestors
        let path = "#0/scroll/#0/msg-42/#1/body"
        #expect(FlightSelector.selects("body", path: path, key: "body"))
        #expect(FlightSelector.selects("msg-42/body", path: path, key: "body"))
        #expect(FlightSelector.selects("scroll/msg-42/body", path: path, key: "body"))
        #expect(!FlightSelector.selects("msg-41/body", path: path, key: "body"))
        #expect(!FlightSelector.selects("scroll/body", path: path, key: "body"))
        #expect(!FlightSelector.selects("msg-42", path: path, key: "body"))
        #expect(!FlightSelector.selects("body", path: "#0/#1", key: nil))
        #expect(!FlightSelector.selects("x/msg-42/body", path: path, key: "body"))
    }

    @Test("fly_text_scoped: scoped destination lands on its own row and missing destination skips cleanly")
    func flyTextScopedParity() {
        struct S {
            var draft: TextEdit
            var sent: [String]
            var destination: String
        }

        for (destination, shouldLand, expectedRow) in [
            ("msg-2/body", true, 2),
            ("msg-0/body", true, 0),
            ("msg-9/body", false, -1),
        ] {
            let rt = Runtime<S>(
                state: S(draft: TextEdit("third"), sent: ["first", "second"], destination: destination),
                viewport: Vec2(400, 300),
                pixelScale: 2.0,
                systemDark: true
            ) { s, _ in
                var rows: El<S> = col().wFull()
                for (i, m) in s.sent.enumerated() {
                    rows = rows.child(
                        col().key("msg-\(i)").wFull().py(8)
                            .child(col().child(text(m).key("body")))
                    )
                }
                return col().size(400, 300)
                    .child(col().key("scroll").wFull().grow(1).shrink(1).scroll(stickBottom: true).child(rows))
                    .child(
                        textInput(key: "composer", \S.draft)
                            .wFull()
                            .h(60)
                            .onSubmit { st, _, tx in
                                st.sent.append(st.draft.text)
                                st.draft.clear()
                                tx.flyText("composer", to: st.destination)
                            }
                    )
            }
            _ = rt.frame(at: 0.0)
            rt.pointerDown(at: Vec2(20, 270), at: 0.004)
            rt.pointerUp(at: Vec2(20, 270), at: 0.005)
            _ = rt.frame(at: 0.006)
            _ = rt.keyDown(KeyEvent(key: .enter), at: 1.0 / 120.0)
            _ = rt.frame(at: 1.0 / 120.0)
            _ = rt.frame(at: 2.0 / 120.0)

            let targetLeaf = destination.split(separator: "/").last.map(String.init) ?? destination
            let flightPath = "flight-source/\(targetLeaf)"
            let overlay = rt.elements().first(where: { $0.path == flightPath })
            if !shouldLand {
                #expect(overlay == nil)
                continue
            }
            #expect(overlay != nil)
            let bodies = rt.elements().filter { $0.key == "body" }
            #expect(bodies.count == 3)
            let target = overlay!.target
            let bodyTarget = bodies[expectedRow].target
            #expect(abs(target[0] - bodyTarget[0]) < 1.0 && abs(target[1] - bodyTarget[1]) < 1.0)
            for tStep in 3...125 {
                _ = rt.frame(at: Double(tStep) / 120.0)
            }
            #expect(rt.elements().first(where: { $0.path == flightPath }) == nil)
        }
    }

    @Test("launch_ancestor_spring: launched row rides springing bottom panel without jumping")
    func launchAncestorSpringParity() {
        struct S {
            var draft = TextEdit("")
            var rows = 0
        }

        func secondSend(after frames: Int) -> [(Float, Float)] {
            let rt = Runtime<S>(state: S(), viewport: Vec2(400, 300), pixelScale: 2.0) { s, _ in
                var list: El<S> = col().key("list").wFull()
                for i in 0..<s.rows {
                    list = list.child(el().key("row-\(i)").wFull().h(32))
                }
                return col().size(400, 300)
                    .child(el().grow(1))
                    .child(col().key("panel").wFull().pt(6).animateLayout(MotionTokens.SETTLE).child(list))
                    .child(
                        textInput(key: "composer", \S.draft)
                            .wFull()
                            .h(60)
                            .onSubmit { st, _, tx in
                                st.draft.clear()
                                tx.launch("composer", to: "row-\(st.rows)")
                                st.rows += 1
                            }
                    )
            }

            func y(_ key: String) -> Float { rt.element(byKey: key)!.rect[1] }
            func send(at t: Double) {
                rt.update(at: t) { s, _ in s.draft = TextEdit("next") }
                rt.pointerDown(at: Vec2(20, 270), at: t)
                rt.pointerUp(at: Vec2(20, 270), at: t)
                _ = rt.keyDown(KeyEvent(key: .enter), at: t)
            }

            var t = 0.0
            _ = rt.frame(at: t)
            send(at: t)
            for _ in 0..<frames {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
            }
            var out: [(Float, Float)] = [(y("row-0"), y("list"))]
            send(at: t)
            for _ in 0..<120 {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
                out.append((y("row-0"), y("list")))
            }
            return out
        }

        for after in [20, 90] {
            let frames = secondSend(after: after)
            let ys = frames.map(\.0)
            var worstStep: Float = 0
            for i in 1..<ys.count {
                let d = ys[i] - ys[i - 1]
                if abs(d) > abs(worstStep) { worstStep = d }
            }
            #expect(abs(worstStep) < 4.0)
            let last = frames.last!
            #expect(abs(last.0 - last.1) < 0.01)
        }

        let settled = secondSend(after: 90)
        for (rowY, listY) in settled {
            #expect(abs(rowY - listY) < 0.25)
        }
    }

    @Test("MotionGate carried scrolled does not double/N-count across nested non-scroll wrappers")
    func motionGateCarriedScrolledSingleCountsNestedWrappers() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 120)) { _, _ in
            el().key("outer-scroll").scrollY().w(200).h(120).child(
                el().key("wrap-1").w(200).child(
                    col().key("wrap-2").w(200).children([
                        el().key("inner-scroll").scrollY().w(200).h(80).child(
                            el().key("wrap-3").w(200).child(
                                el().key("leaf").w(200).h(300)
                            )
                        ),
                        el().key("spacer").w(200).h(100),
                    ])
                )
            )
        }
        let run = MotionGateRun(rt)
        // First scroll outer-scroll from the spacer area (below inner-scroll) by 20pt, then inner-scroll by 40pt.
        rt.wheel(WheelEvent(dx: 0, dy: -20), at: Vec2(100, 100), now: run.dt)
        rt.wheel(WheelEvent(dx: 0, dy: -40), at: Vec2(100, 30), now: run.dt)
        run.step()

        let innerSnap = run.rec.tracks.first { $0.path.contains("@inner-scroll") && !$0.path.contains("@leaf") }?.frames.last?.1
        let leafSnap = run.rec.tracks.first { $0.path.contains("@leaf") }?.frames.last?.1
        #expect(innerSnap != nil)
        #expect(leafSnap != nil)
        if let innerS = innerSnap?.scrolled, innerS.count >= 2 {
            #expect(abs(innerS[1] - 20.0) < 0.5, "Expected inner-scroll carried scroll 20.0, got \(innerS[1])")
        }
        if let leafS = leafSnap?.scrolled, leafS.count >= 2 {
            #expect(abs(leafS[0]) < 1e-4)
            #expect(abs(leafS[1] - 60.0) < 0.5, "Expected single-counted carried scroll 60.0, got \(leafS[1])")
        }
    }
}
