import Foundation
import Testing
@testable import Rune

@Suite("Interaction & PerfWarn Wave E Parity", .serialized)
struct InteractionPerfParityWaveETests {
    private static func resetAll() {
        PerfWarn.resetForTesting()
        InteractionTracker.resetForTesting()
    }

    // MARK: - perf_warn/runq.rs (5/5)

    @Test("runq.rs: blockedMs computes blocked time without run-queue wait")
    func runqBlockedMsWithoutWait() {
        let blocked = PerfRunQ.blockedMs(wallMs: 20.0, cpuMs: 1.0, waitMs: nil, loaded: false)
        #expect(blocked == 20.0)
    }

    @Test("runq.rs: blockedMs subtracts run-queue wait time")
    func runqBlockedMsSubtractsWait() {
        let blocked = PerfRunQ.blockedMs(wallMs: 25.0, cpuMs: 1.0, waitMs: 10.0, loaded: true)
        #expect(blocked == 15.0)
        let swallowed = PerfRunQ.blockedMs(wallMs: 25.0, cpuMs: 1.0, waitMs: 20.0, loaded: true)
        #expect(swallowed == nil)
    }

    @Test("runq.rs: blockedMs returns nil when machine loaded without schedstat wait")
    func runqBlockedMsNilWhenLoadedWithoutWait() {
        let blocked = PerfRunQ.blockedMs(wallMs: 30.0, cpuMs: 0.5, waitMs: nil, loaded: true)
        #expect(blocked == nil)
    }

    @Test("runq.rs: blockedMs returns nil when callback is CPU-heavy")
    func runqBlockedMsNilWhenCpuHeavy() {
        let blocked = PerfRunQ.blockedMs(wallMs: 25.0, cpuMs: 20.0, waitMs: nil, loaded: false)
        #expect(blocked == nil)
    }

    @Test("runq.rs: blockedMs returns nil at or below 8 ms stall threshold")
    func runqBlockedMsNilBelowStallThreshold() {
        let exact = PerfRunQ.blockedMs(wallMs: 8.0, cpuMs: 0.0, waitMs: nil, loaded: false)
        let under = PerfRunQ.blockedMs(wallMs: 7.9, cpuMs: 0.0, waitMs: nil, loaded: false)
        #expect(exact == nil)
        #expect(under == nil)
    }

    // MARK: - perf_warn/tests.rs (Runtime + Stall + Launch + Override)

    @Test("perf_warn/tests.rs: Runtime virtualize(1000) warns once; small virtualize and virtualRows are silent")
    func runtimeVirtualizeAndVirtualRowsWarnings() {
        Self.resetAll()
        defer { Self.resetAll() }

        let overbuiltRt = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            col()
                .key("list-scroll")
                .scrollY()
                .h(100)
                .child(
                    col()
                        .key("overbuilt-rows")
                        .virtualize(20)
                        .children((0..<1000).map { i in text("row-\(i)").key("r\(i)").h(20) })
                )
        }
        _ = overbuiltRt.frame(at: 0.0)
        _ = overbuiltRt.frame(at: 0.016)
        let log1 = PerfWarn.takeTestLog()
        #expect(log1.count == 1)
        #expect(log1[0].contains("overbuilt-rows"))
        #expect(log1[0].contains("virtual_rows"))
        #expect(log1[0].contains("built 1000 rows"))

        PerfWarn.resetForTesting()
        let smallRt = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            col()
                .scrollY()
                .h(100)
                .child(
                    col()
                        .key("small-rows")
                        .virtualize(20)
                        .children((0..<100).map { i in text("row-\(i)").key("r\(i)").h(20) })
                )
        }
        _ = smallRt.frame(at: 0.0)
        #expect(PerfWarn.takeTestLog().isEmpty)

        let indexedRt = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            col()
                .scrollY()
                .h(100)
                .child(
                    col()
                        .key("indexed-rows")
                        .virtualRows(1000, 20, key: { _, i in "row-\(i)" }, build: { _, i in text("row-\(i)").h(20) })
                )
        }
        _ = indexedRt.frame(at: 0.0)
        #expect(PerfWarn.takeTestLog().isEmpty)
    }

    @Test("perf_warn/tests.rs: Stall warns when main thread blocks, deduplicates per site, ignores quick/CPU work")
    func stallDetectsBlockedWorkAndDeduplicates() {
        Self.resetAll()
        defer { Self.resetAll() }

        func blockedCall(site: String) {
            let stall = PerfWarn.Stall.start()
            Thread.sleep(forTimeInterval: 0.025)
            stall.end(overloaded: false) { (site: site, name: "`\(site)`") }
        }

        blockedCall(site: "io_read")
        blockedCall(site: "io_read")
        let log = PerfWarn.takeTestLog()
        #expect(log.count == 1)
        #expect(log[0].contains("io_read"))
        #expect(log[0].contains("blocked"))
        #expect(log[0].contains("on the main thread"))

        // Quick callback stays silent.
        let quick = PerfWarn.Stall.start()
        quick.end(overloaded: false) { (site: "quick_op", name: "`quick_op`") }
        #expect(PerfWarn.takeTestLog().isEmpty)

        // CPU-bound spin (~12 ms of real CPU without syscall overhead) stays silent.
        let busy = PerfWarn.Stall.start()
        let startCpu = PerfWarn.threadCpuMs() ?? 0
        var acc: UInt64 = 1
        while ((PerfWarn.threadCpuMs() ?? startCpu) - startCpu) < 12.0 {
            for _ in 0..<100_000 {
                acc = acc &* 6364136223846793005 &+ 1
            }
        }
        _ = acc
        busy.end { (site: "busy_compute", name: "`busy_compute`") }
        #expect(PerfWarn.takeTestLog().isEmpty)
    }

    @Test("perf_warn/tests.rs: Runtime poll returning true without visual change warns after 30 frames")
    func runtimeIdlePoll30FramesWarning() {
        Self.resetAll()
        defer { Self.resetAll() }

        let rt = Runtime(state: 0, viewport: Vec2(120, 80), pixelScale: 1.0) { s, _ in
            text("count \(s)").key("lbl")
        }
        rt.poll = { _, _, _ in true }
        for i in 0..<40 {
            _ = rt.frame(at: Double(i) * 0.016)
        }
        let log = PerfWarn.takeTestLog()
        #expect(log.count == 1)
        #expect(log[0].contains("`poll`"))
        #expect(log[0].contains("30 frames in a row"))

        // Changing view each frame keeps poll silent.
        PerfWarn.resetForTesting()
        let activeRt = Runtime(state: 0, viewport: Vec2(120, 80), pixelScale: 1.0) { s, _ in
            el().key("bar").w(Float(10 + (s % 40))).h(10).bg(Color(r: 1, g: 0, b: 0, a: 1))
        }
        activeRt.poll = { s, _, _ in
            s += 1
            return true
        }
        for i in 0..<40 {
            _ = activeRt.frame(at: Double(i) * 0.016)
        }
        #expect(PerfWarn.takeTestLog().isEmpty)
    }

    @Test("perf_warn/tests.rs: PerfLaunch report attribution and RUNE_PERF_WARN=0 override")
    func perfLaunchAndOverrideSilence() {
        Self.resetAll()
        defer { Self.resetAll() }

        #expect(PerfLaunch.report(setupMs: 20, initMs: 30, viewMs: 40, totalMs: 95) == nil)
        let slowView = PerfLaunch.report(setupMs: 10, initMs: 15, viewMs: 90, totalMs: 130)
        #expect(slowView?.contains("the first `view`") == true)
        let slowInit = PerfLaunch.report(setupMs: 10, initMs: 95, viewMs: 20, totalMs: 140)
        #expect(slowInit?.contains("`init`") == true)

        PerfWarn.testEnabledOverride = false
        let stall = PerfWarn.Stall.start()
        Thread.sleep(forTimeInterval: 0.020)
        stall.end(overloaded: false) { (site: "muted", name: "`muted`") }
        PerfWarn.overbuilt(path: "/root/list", site: nil, built: 500, mounted: 5)
        PerfWarn.memoKeyReplaced(id: "a", existing: "b", site: "f.swift:1")
        #expect(PerfWarn.takeTestLog().isEmpty)
    }

    // MARK: - perf_warn/commits_tests.rs (8/8)

    @Test("commits_tests.rs: scroll commit warns once for poll after 6 frames")
    func scrollCommitWarnsForPoll() {
        Self.resetAll()
        defer { Self.resetAll() }

        let meter = CommitMeter()
        for f in 0..<5 {
            meter.poll()
            meter.frameEnds(scrolling: true, committed: true)
            #expect(PerfWarn.takeTestLog().isEmpty, "frame \(f) should not warn yet")
        }
        meter.poll()
        meter.frameEnds(scrolling: true, committed: true)
        let log = PerfWarn.takeTestLog()
        #expect(log.count == 1)
        #expect(log[0].contains("`poll` returned true"))
        #expect(log[0].contains("6 of 6 frames"))
        #expect(log[0].contains("El::on_scroll_offset"))

        // Subsequent frames stay deduplicated.
        meter.poll()
        meter.frameEnds(scrolling: true, committed: true)
        #expect(PerfWarn.takeTestLog().isEmpty)
    }

    @Test("commits_tests.rs: scroll commit warns for on_layout_tx and suggests live_only")
    func scrollCommitWarnsForOnLayout() {
        Self.resetAll()
        defer { Self.resetAll() }

        let meter = CommitMeter()
        for _ in 0..<6 {
            meter.handler(name: "on_layout_tx", path: "/root/header", at: "list.swift:42")
            meter.frameEnds(scrolling: true, committed: true)
        }
        let log = PerfWarn.takeTestLog()
        #expect(log.count == 1)
        #expect(log[0].contains("`on_layout_tx`"))
        #expect(log[0].contains("Tx::live_only"))
    }

    @Test("commits_tests.rs: scroll commit distinguishes Cx::window_layout vs unscrolled Cx::layout")
    func scrollCommitWindowVsUnscrolledLayoutRead() {
        Self.resetAll()
        defer { Self.resetAll() }

        let meter = CommitMeter()
        let winKey = LayoutReadConstants.windowKey("card")
        for _ in 0..<6 {
            meter.read(key: winKey, at: "card.swift:10")
            meter.frameEnds(scrolling: true, committed: true)
        }
        let winLog = PerfWarn.takeTestLog()
        #expect(winLog.count == 1)
        #expect(winLog[0].contains("Cx::window_layout"))
        #expect(winLog[0].contains("\"card\""))
        #expect(winLog[0].contains("Cx::layout_size"))

        PerfWarn.resetForTesting()
        let unscrolled = CommitMeter()
        for _ in 0..<6 {
            unscrolled.read(key: "panel", at: "panel.swift:20")
            unscrolled.frameEnds(scrolling: true, committed: true)
        }
        let readLog = PerfWarn.takeTestLog()
        #expect(readLog.count == 1)
        #expect(readLog[0].contains("layout read of \"panel\""))
        #expect(readLog[0].contains("Cx::layout_with"))
    }

    @Test("commits_tests.rs: on_hover_change across 8 rows from one site warns hover rows")
    func scrollCommitAndHoverRows8Elements() {
        Self.resetAll()
        defer { Self.resetAll() }

        let meter = CommitMeter()
        for i in 0..<7 {
            meter.handler(name: "on_hover_change", path: "/list/row-\(i)", at: "row.swift:18")
            meter.frameEnds(scrolling: false, committed: true)
        }
        #expect(PerfWarn.takeTestLog().isEmpty)

        meter.handler(name: "on_hover_change", path: "/list/row-7", at: "row.swift:18")
        meter.frameEnds(scrolling: false, committed: true)
        let log = PerfWarn.takeTestLog()
        #expect(log.count == 1)
        #expect(log[0].contains("`on_hover_change`"))
        #expect(log[0].contains("8 elements"))
        #expect(log[0].contains("hover_group"))
    }

    @Test("commits_tests.rs: 8 consecutive committed instant scroll frames warn once")
    func instantScroll8CommittedFramesWarns() {
        Self.resetAll()
        defer { Self.resetAll() }

        let meter = CommitMeter()
        for _ in 0..<7 {
            meter.frameEnds(scrolling: true, committed: true, instantKey: "feed")
        }
        #expect(PerfWarn.takeTestLog().isEmpty)

        // An uncommitted frame or nil instantKey resets the streak.
        meter.frameEnds(scrolling: true, committed: false, instantKey: "feed")
        for _ in 0..<7 {
            meter.frameEnds(scrolling: true, committed: true, instantKey: "feed")
        }
        #expect(PerfWarn.takeTestLog().isEmpty)

        meter.frameEnds(scrolling: true, committed: true, instantKey: "feed")
        let log = PerfWarn.takeTestLog()
        #expect(log.count == 1)
        #expect(log[0].contains("instant scroll"))
        #expect(log[0].contains("\"feed\""))
        #expect(log[0].contains("scroll_to_with"))
    }

    @Test("commits_tests.rs: scroll interruption and low share (< 1/4) prevent false positive")
    func commitMeterShareAndScrollReset() {
        Self.resetAll()
        defer { Self.resetAll() }

        let meter = CommitMeter()
        // 5 commits then stop scrolling -> resets
        for _ in 0..<5 {
            meter.poll()
            meter.frameEnds(scrolling: true, committed: true)
        }
        meter.frameEnds(scrolling: false, committed: false)
        for _ in 0..<5 {
            meter.poll()
            meter.frameEnds(scrolling: true, committed: true)
        }
        #expect(PerfWarn.takeTestLog().isEmpty)

        // 20 frames with no commit dilute the 6th commit below 1/4 share.
        for _ in 0..<20 {
            meter.frameEnds(scrolling: true, committed: false)
        }
        meter.poll()
        meter.frameEnds(scrolling: true, committed: true)
        #expect(PerfWarn.takeTestLog().isEmpty)
    }

    @Test("commits_tests.rs: Runtime instant scroll on 8 committed frames triggers PerfWarn")
    func runtimeInstantScroll8CommittedFrames() {
        Self.resetAll()
        defer { Self.resetAll() }

        let rt = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0) { s, _ in
            col()
                .key("vp")
                .scrollY()
                .h(100)
                .child(el().h(800).w(200).bg(Color(r: Float(s % 2), g: 0.2, b: 0.2, a: 1)))
        }
        _ = rt.frame(at: 0.0)
        for i in 1...8 {
            rt.update(at: Double(i) * 0.016) { s, tx in
                s += 1
                tx.scrollToInstant("vp", x: 0, y: Float(i * 10))
            }
            _ = rt.frame(at: Double(i) * 0.016)
        }
        let log = PerfWarn.takeTestLog()
        #expect(log.count == 1)
        #expect(log[0].contains("instant scroll"))
        #expect(log[0].contains("8 frames in a row"))
    }

    // MARK: - perf_warn/idle_tests.rs (idle_readings_walk)

    @Test("idle_tests.rs: IdleMeter stepIdleReading handles quiet streaks, resets, >2s splits, and combined reasons")
    func idleReadingsWalk() {
        var streak = IdleMeter.StreakState.watching

        // Non-quiet / animating / changed output all reset or stay watching.
        #expect(IdleMeter.stepIdleReading(&streak, reading: .init(clock: 0.0, quiet: false, animating: false, same: true, timer: true, live: false, polled: false)) == nil)
        #expect(streak == .watching)
        #expect(IdleMeter.stepIdleReading(&streak, reading: .init(clock: 0.1, quiet: true, animating: true, same: true, timer: true, live: false, polled: false)) == nil)
        #expect(streak == .watching)
        #expect(IdleMeter.stepIdleReading(&streak, reading: .init(clock: 0.2, quiet: true, animating: false, same: false, timer: true, live: false, polled: false)) == nil)
        #expect(streak == .watching)

        // Unwoken or unknown `same == nil` leaves state unchanged.
        #expect(IdleMeter.stepIdleReading(&streak, reading: .init(clock: 0.3, quiet: true, animating: false, same: nil, timer: true, live: false, polled: false)) == nil)
        #expect(IdleMeter.stepIdleReading(&streak, reading: .init(clock: 0.4, quiet: true, animating: false, same: true, timer: false, live: false, polled: false)) == nil)
        #expect(streak == .watching)

        // 119 timer frames within 2s stay silent, upgrading with live & polled, then warn on frame 120.
        for i in 0..<119 {
            let live = (i == 50)
            let polled = (i == 60)
            let res = IdleMeter.stepIdleReading(
                &streak,
                reading: .init(clock: 1.0 + Double(i) * 0.01, quiet: true, animating: false, same: true, timer: true, live: live, polled: polled)
            )
            #expect(res == nil)
        }
        let fired = IdleMeter.stepIdleReading(
            &streak,
            reading: .init(clock: 2.2, quiet: true, animating: false, same: true, timer: true, live: false, polled: false)
        )
        #expect(fired?.0 == .timerPoll)
        #expect(abs((fired?.1 ?? 0) - 1.2) < 0.001)

        // Advancing > 2.0s from window start resets the count to 1.
        var split = IdleMeter.StreakState.watching
        _ = IdleMeter.stepIdleReading(&split, reading: .init(clock: 0.0, quiet: true, animating: false, same: true, timer: false, live: true, polled: false))
        _ = IdleMeter.stepIdleReading(&split, reading: .init(clock: 2.5, quiet: true, animating: false, same: true, timer: false, live: true, polled: false))
        #expect(split == .counting(from: 2.5, frames: 1, woke: .live(polled: false)))
    }

    // MARK: - interaction/frame_tests.rs (frame_phase_walk)

    @Test("frame_tests.rs: InteractionFrameMachine walk merges ranks, commits, untimed frames, and finish")
    func framePhaseWalk() {
        var state = InteractionFrameState.idle
        let names = InteractionNames()
        let lowNote = InteractionNote(route: names.fixed("home"), control: names.fixed("list"), action: "on_hover", rank: 1)
        let highNote = InteractionNote(route: names.fixed("home"), control: names.fixed("save"), action: "on_press", rank: 3)

        // Begin queued, then note arrives -> starts phase timers and keeps earlier arrival + higher rank.
        #expect(InteractionFrameMachine.step(&state, event: .begin(atNs: 100, queued: true, cpuMs: 1.5)).isEmpty)
        let fx1 = InteractionFrameMachine.step(&state, event: .note(note: lowNote, arrivedNs: 90, startedNs: 110, handlerMs: 0.5))
        #expect(fx1.count == 1)
        let fx2 = InteractionFrameMachine.step(&state, event: .note(note: highNote, arrivedNs: 80, startedNs: 120, handlerMs: 1.2))
        #expect(fx2.isEmpty)
        _ = InteractionFrameMachine.step(&state, event: .commit(0b10))
        _ = InteractionFrameMachine.step(&state, event: .commit(0b01))
        let fxBuild = InteractionFrameMachine.step(
            &state,
            event: .buildTimed(atNs: 200, phases: [1, 2, 3, 4, 5, 6], shaped: 12, cpuMs: 4.5, stacks: nil)
        )
        #expect(fxBuild.count == 1)
        let fxFinish = InteractionFrameMachine.step(&state, event: .finish)
        if case let .count(built)? = fxFinish.first {
            #expect(built.timed.arrivedNs == 80)
            #expect(built.timed.frameStartNs == 100)
            #expect(abs(built.timed.handlerMs - 1.7) < 0.0001)
            #expect(built.timed.note.action == "on_press")
            #expect(built.timed.why == 0b11)
            #expect(built.timed.commits == 2)
            #expect(built.cpuMs == 3.0)
        } else {
            Issue.record("expected .count effect from .finish")
        }

        // Untimed frame produces .checkFrame with accumulated commit mask.
        _ = InteractionFrameMachine.step(&state, event: .begin(atNs: 500, queued: false, cpuMs: nil))
        _ = InteractionFrameMachine.step(&state, event: .commit(0b100))
        let fxUntimed = InteractionFrameMachine.step(&state, event: .buildUntimed)
        if case let .checkFrame(startNs, why)? = fxUntimed.first {
            #expect(startNs == 500 && why == 0b100)
        } else {
            Issue.record("expected .checkFrame effect from .buildUntimed")
        }
    }

    // MARK: - interaction/tests.rs (Runtime wiring + Exporter)

    @Test("interaction/tests.rs: Runtime fast click updates rollup without emitting slow report")
    func runtimeFastClickRecordsRollupOnly() {
        Self.resetAll()
        defer { Self.resetAll() }
        InteractionGate.forceOnForTesting = true

        let rt = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0) { s, _ in
            el().key("save-btn").w(80).h(40).onClick { s, _ in s += 1 }
        }
        _ = rt.frame(at: 0.0)
        rt.pointerDown(at: Vec2(20, 20), at: 0.016)
        rt.pointerUp(at: Vec2(20, 20), at: 0.020)
        _ = rt.frame(at: 0.032)
        rt.interactionPresented(slowMs: 5000.0, overloaded: false)

        #expect(rt.state == 1)
        #expect(InteractionTracker.testSlowReports.isEmpty)
        let rollup = rt.interactionTracker.takeRollupIfDue(nowNs: DispatchTime.now().uptimeNanoseconds, force: true)
        #expect(rollup?.rolls.count == 1)
        #expect(rollup?.rolls.first?.action == "on_press")
        #expect(rollup?.rolls.first?.count == 1)
        #expect(rollup?.rolls.first?.slow == 0)
    }

    @Test("interaction/tests.rs: Runtime IME edit emits key_edit and captures phases when slow")
    func runtimeKeyEditAndSlowFrameThroughRuntime() {
        Self.resetAll()
        defer { Self.resetAll() }
        InteractionGate.forceOnForTesting = true

        struct State {
            var edit = TextEdit("hi")
        }
        let rt = Runtime(state: State(), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            textInput(key: "editor", \State.edit).w(180).h(40)
        }
        _ = rt.frame(at: 0.0)
        rt.pointerDown(at: Vec2(20, 20), at: 0.016)
        rt.pointerUp(at: Vec2(20, 20), at: 0.020)
        _ = rt.frame(at: 0.032)
        rt.interactionPresented(slowMs: 5000.0, overloaded: false)

        _ = rt.dispatchImeEvent(.commit("!"), at: 0.048)
        _ = rt.frame(at: 0.064)
        let nowNs = DispatchTime.now().uptimeNanoseconds
        rt.interactionPresented(submittedNs: nowNs + 50_000_000, slowMs: 5.0, overloaded: false)

        #expect(rt.state.edit.text == "hi!")
        #expect(InteractionTracker.testSlowReports.count == 1)
        let rep = InteractionTracker.testSlowReports[0]
        #expect(rep.action == "key_edit")
        #expect(rep.commits >= 1)
        #expect(rep.phases.reduce(0, +) > 0.0)

        // Disabled gate records nothing.
        InteractionTracker.resetForTesting()
        InteractionGate.forceOnForTesting = false
        _ = rt.dispatchImeEvent(.commit("?"), at: 0.080)
        _ = rt.frame(at: 0.096)
        rt.interactionPresented(submittedNs: DispatchTime.now().uptimeNanoseconds + 50_000_000, slowMs: 5.0)
        #expect(InteractionTracker.testSlowReports.isEmpty)
    }

    @Test("interaction/tests.rs: unpresented built frame finishes on next frameBegins")
    func unpresentedBuiltFrameFinishesOnNextBegin() {
        Self.resetAll()
        defer { Self.resetAll() }
        InteractionGate.forceOnForTesting = true

        let tracker = InteractionTracker()
        let names = tracker.names
        let note = InteractionNote(route: names.fixed("root"), control: names.fixed("ok"), action: "on_press", rank: 3)
        _ = tracker.frameBegins(queued: false, nowNs: 1_000_000)
        tracker.noted(note: note, arrivedNs: 1_000_000, startedNs: 1_000_000, handlerMs: 1.0)
        _ = tracker.built(shaped: 2, nodes: 5, nowNs: 25_000_000)

        // Next frame begins without calling finish() -> finishes previous built frame automatically.
        let finished = tracker.frameBegins(queued: false, nowNs: 30_000_000, slowMs: 16.0)
        #expect(finished?.slow == true)
        #expect(finished?.cause != nil)
    }

    @Test("interaction/tests.rs: untimed slow frame without input produces SlowFrameReport")
    func slowFrameWithoutInputProducesReport() {
        let tracker = InteractionTracker()
        _ = tracker.frameBegins(queued: false, nowNs: 10_000_000)
        tracker.committed(why: 0b101)
        let stacks = InteractionStacks(taken: 3, waiting: 0, cpuShare: 1.0, raw: [])
        let report = tracker.built(shaped: 1, nodes: 10, nowNs: 40_000_000, stacks: stacks, slowMs: 16.0)
        #expect(report != nil)
        #expect(report?.why == 0b101)
        #expect(report?.nodes == 10)
    }

    @Test("interaction/tests.rs: OTLP exporter encodes slow spans with all phases, rebuilt & stacks")
    func exporterEncodesSlowSpanAndRollup() throws {
        let report = SlowInteractionReport(
            route: "inbox",
            control: "send",
            action: "on_press",
            arrivedNs: 10_000_000,
            frameStartNs: 12_000_000,
            builtNs: 25_000_000,
            submittedNs: 26_000_000,
            presentNs: 40_000_000,
            handlerMs: 4.5,
            phases: [1.1, 2.2, 3.3, 4.4, 5.5, 0.6],
            why: 1,
            commits: 2,
            shaped: 7,
            nodes: 100,
            reused: 40,
            rebuilt: [("list", 60)],
            cpuMs: 11.0,
            cause: .cpu,
            stacks: InteractionStacks(
                taken: 2,
                waiting: 0,
                cpuShare: 0.9,
                raw: [InteractionRawStack(pcs: [0x1000], waiting: false, cpuUs: 1000)]
            )
        )
        let spans = InteractionExporter.slowSpans(
            report,
            resolver: { _ in [InteractionStackFrame(name: "MyApp.send", isApp: true)] }
        )
        let bodyStr = try InteractionExporter.encodeOTLPBody(serviceName: "rune-test", spans: spans)
        let jsonData = Data(bodyStr.utf8)
        let parsed = try JSONSerialization.jsonObject(with: jsonData)
        let obj = try #require(parsed as? [String: Any])
        let resourceSpans = try #require(obj["resourceSpans"] as? [[String: Any]])
        #expect(resourceSpans.count == 1)
        let scopeSpans = try #require(resourceSpans[0]["scopeSpans"] as? [[String: Any]])
        let outSpans = try #require(scopeSpans[0]["spans"] as? [[String: Any]])
        #expect(outSpans.count >= 3)
        #expect((outSpans[0]["name"] as? String) == "ui.interaction")
        let rootAttrs = try #require(outSpans[0]["attributes"] as? [[String: Any]])
        let updateSpan = outSpans.first { ($0["name"] as? String) == "update" }
        let updateAttrs = (updateSpan?["attributes"] as? [[String: Any]]) ?? []
        var keys = Set(rootAttrs.compactMap { $0["key"] as? String })
        for attr in updateAttrs {
            if let k = attr["key"] as? String { keys.insert(k) }
        }
        for attr in InteractionPhase.attributeNames {
            #expect(keys.contains(attr))
        }
        #expect(keys.contains("rune.cause"))
        #expect(keys.contains("rune.hot.0"))
        #expect(keys.contains("rune.rebuilt.0"))
    }

    // MARK: - interaction/sampler_tests.rs & stack.rs

    @Test("sampler_tests.rs: InteractionDemangle strips prefixes, Rust hashes, and classifies library frames")
    func demangleAndLibraryClassification() {
        #expect(InteractionDemangle.demangled("_my_c_helper") == "my_c_helper")
        #expect(InteractionDemangle.demangled("__Z3foov") == "__Z3foov")
        #expect(InteractionDemangle.demangled("myapp::render::h0123456789abcdef") == "myapp::render")

        #expect(InteractionDemangle.isLibrary("Rune.Runtime.frame(at: Double)"))
        #expect(InteractionDemangle.isLibrary("rune::runtime::commit"))
        #expect(InteractionDemangle.isLibrary("libsystem_kernel.dylib"))
        #expect(InteractionDemangle.isLibrary("Foundation.Data.init()"))
        #expect(!InteractionDemangle.isLibrary("MyApp.InboxView.renderRow()"))
    }

    @Test("sampler_tests.rs: InteractionStacks names the innermost app frame most samples were in")
    func stacksNameInnermostHotAppFrame() {
        let samples = [
            InteractionSampledStack(raw: InteractionRawStack(pcs: [10, 20, 30], waiting: false, cpuUs: 100), atNs: 0),
            InteractionSampledStack(raw: InteractionRawStack(pcs: [10, 20, 30], waiting: false, cpuUs: 200), atNs: 4_000_000),
            InteractionSampledStack(raw: InteractionRawStack(pcs: [10, 40, 30], waiting: false, cpuUs: 300), atNs: 8_000_000),
        ]
        let stacks = InteractionStacks.from(samples: samples)
        #expect(stacks != nil)
        let summary = stacks!.names { raw in
            raw.pcs.map { pc in
                switch pc {
                case 10: return InteractionStackFrame(name: "Rune.Runtime.frame", isApp: false)
                case 20: return InteractionStackFrame(name: "MyApp.slowSort", isApp: true)
                case 40: return InteractionStackFrame(name: "MyApp.fastHelper", isApp: true)
                default: return InteractionStackFrame(name: "MyApp.main", isApp: true)
                }
            }
        }
        #expect(summary.hot.first?.name == "MyApp.slowSort")
        #expect(summary.hot.first?.count == 2)
    }

    @Test("sampler_tests.rs: busy machine blames schedulerWait only when app was ready to run")
    func busyMachineBlamesSchedulerWaitOnlyWhenReady() {
        let ready = InteractionStacks(
            taken: 4,
            waiting: 0,
            cpuShare: 0.10,
            raw: [InteractionRawStack(pcs: [1], waiting: false, cpuUs: 100)]
        )
        #expect(InteractionCause.classify(workMs: 30, slowMs: 16, cpuMs: 2.0, stacks: ready, overloaded: true) == .schedulerWait)
        // Waiting in syscalls/locks (> half samples waiting) blames `.blocked` even on a busy machine.
        let waiting = InteractionStacks(
            taken: 4,
            waiting: 3,
            cpuShare: 0.10,
            raw: [InteractionRawStack(pcs: [1], waiting: true, cpuUs: 100)]
        )
        #expect(InteractionCause.classify(workMs: 30, slowMs: 16, cpuMs: 2.0, stacks: waiting, overloaded: true) == .blocked)
        // Single sample without CPU stats: overloaded blames schedulerWait, uncontended blames cpu.
        let single = InteractionStacks(
            taken: 1,
            waiting: 0,
            cpuShare: nil,
            raw: [InteractionRawStack(pcs: [1], waiting: false, cpuUs: 100)]
        )
        #expect(InteractionCause.classify(workMs: 30, slowMs: 16, cpuMs: nil, stacks: single, overloaded: true) == .schedulerWait)
        #expect(InteractionCause.classify(workMs: 30, slowMs: 16, cpuMs: nil, stacks: single, overloaded: false) == .cpu)
    }

    #if os(macOS) && arch(arm64)
    @Test("sampler_tests.rs: live Mach thread sampler captures target stack and respects still()")
    func liveMachThreadSamplerCapturesStack() {
        guard let target = InteractionThreadSamplerTarget.current() else {
            Issue.record("expected non-nil InteractionThreadSamplerTarget on macOS arm64")
            return
        }
        let allowSample = LockedFlag(true)
        let done = DispatchSemaphore(value: 0)
        let resultBox = LockedBox<InteractionRawStack?>(nil)
        let cancelBox = LockedBox<InteractionRawStack?>(nil)

        DispatchQueue.global(qos: .userInitiated).async {
            cancelBox.value = target.sample(still: { false })
            resultBox.value = target.sample(still: { allowSample.value })
            done.signal()
        }
        done.wait()
        allowSample.value = false

        #expect(cancelBox.value == nil)
        let sampled = resultBox.value
        #expect(sampled != nil)
        #expect((sampled?.pcs.count ?? 0) >= 2)
        if let sampled {
            let cache = InteractionSymbolCache()
            let frames = InteractionThreadSamplerTarget.resolveFrames(for: sampled, cache: cache)
            #expect(frames.count == sampled.pcs.count)
        }
    }
    #endif

    // MARK: - interaction/watchdog_tests.rs (SymbolCache & CaughtSamples & Walk)

    @Test("watchdog_tests.rs: InteractionSymbolCache adjusts non-top PCs to pc-1 and invalidates on image generation change")
    func symbolCachePcAdjustmentAndImageGenerationInvalidation() {
        let cache = InteractionSymbolCache()
        var gen: UInt64 = 1
        var lookupAddrs: [UInt] = []

        let raw = InteractionRawStack(pcs: [0x1000, 0x2000], waiting: false, cpuUs: 10, imagesGeneration: 1)
        let first = cache.frames(for: raw, generation: { gen }) { addr in
            lookupAddrs.append(addr)
            return InteractionStackFrame(name: "fn_\(String(addr, radix: 16))", isApp: true)
        }
        #expect(lookupAddrs == [0x1000, 0x1FFF])
        #expect(first.map(\.name) == ["fn_1000", "fn_1fff"])

        // Cached hit does not invoke lookup again.
        let second = cache.frames(for: raw, generation: { gen }) { addr in
            lookupAddrs.append(addr)
            return InteractionStackFrame(name: "unexpected", isApp: false)
        }
        #expect(second == first)
        #expect(lookupAddrs == [0x1000, 0x1FFF])

        // Mismatched raw imagesGeneration skips lookup and returns hex addresses.
        let stale = cache.frames(for: raw, generation: { 2 }) { addr in
            lookupAddrs.append(addr)
            return InteractionStackFrame(name: "unexpected", isApp: false)
        }
        #expect(stale.map(\.name) == ["0x1000", "0x2000"])
        #expect(stale.allSatisfy { !$0.isApp })

        // Generation changing mid-lookup returns hex addresses cleanly.
        gen = 3
        let rawGen3 = InteractionRawStack(pcs: [0x3000], waiting: false, cpuUs: 20, imagesGeneration: 3)
        let race = cache.frames(for: rawGen3, generation: { gen }) { addr in
            gen = 4
            return InteractionStackFrame(name: "stale_\(addr)", isApp: true)
        }
        #expect(race.map(\.name) == ["0x3000"])
    }

    @Test("watchdog_tests.rs: InteractionCaughtSamples caps at 64 and resets across frame sequences")
    func caughtSamplesCapAndSequenceReset() {
        let store = InteractionCaughtSamples()
        for i in 0..<80 {
            let sample = InteractionSampledStack(
                raw: InteractionRawStack(pcs: [UInt(0x100 + i)], waiting: false, cpuUs: UInt64(i * 100)),
                atNs: UInt64(i * 1_000_000)
            )
            store.push(seq: 1, sample: sample)
        }
        #expect(store.count == 64)
        let seq1 = store.take(for: 1)
        #expect(seq1.count == 64)
        #expect(seq1.first?.raw.pcs == [0x100])
        #expect(seq1.last?.raw.pcs == [0x13F])

        // Pushing a new sequence drops any old leftovers.
        store.push(seq: 2, sample: InteractionSampledStack(raw: InteractionRawStack(pcs: [0x900], waiting: false, cpuUs: 1), atNs: 10))
        store.push(seq: 3, sample: InteractionSampledStack(raw: InteractionRawStack(pcs: [0xA00], waiting: false, cpuUs: 2), atNs: 20))
        #expect(store.take(for: 2).isEmpty)
        let seq3 = store.take(for: 3)
        #expect(seq3.count == 1)
        #expect(seq3[0].raw.pcs == [0xA00])
    }

    @Test("watchdog_tests.rs: InteractionWatchdog hurry resets due time and preserves progress across short frame gaps")
    func watchdogHurryAndShortFrameRunWalk() {
        var watch = InteractionWatchdog.WatchState.unarmed
        let hurryUs = InteractionWatchdog.hurryMs * 1000
        let f1 = InteractionWatchdog.RunningFrame(seq: 10, startNs: 1_000_000, afterUs: hurryUs)
        let fx1 = InteractionWatchdog.step(&watch, event: .look(frame: f1, nowNs: 1_500_000))
        #expect(fx1 == [.sleepNs(UInt64(hurryUs) * 1000 - 500_000)])

        // After due time, watchdog emits .sample, and .taken increments progress.
        let sampleAt = 1_000_000 + UInt64(hurryUs) * 1000 + 100
        let fx2 = InteractionWatchdog.step(&watch, event: .look(frame: f1, nowNs: sampleAt))
        #expect(fx2 == [.sample(seq: 10, startNs: 1_000_000, atNs: sampleAt)])
        _ = InteractionWatchdog.step(&watch, event: .taken(seq: 10, nowNs: sampleAt))

        // Brief idle (frame == nil) moves to quiet keeping left progress; resuming same seq continues taken == 1.
        _ = InteractionWatchdog.step(&watch, event: .look(frame: nil, nowNs: sampleAt + 1_000_000))
        #expect(watch.progress(for: 10)?.taken == 1)
        let fx3 = InteractionWatchdog.step(&watch, event: .look(frame: f1, nowNs: sampleAt + 2_000_000))
        #expect(fx3.count == 1)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool

    init(_ value: Bool) { self._value = value }

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) { self._value = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
