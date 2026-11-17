import Foundation
import Testing
@testable import Rune
#if os(Windows)
import WinSDK
#endif

@Suite("InteractionTiming & PerfWarn Parity", .serialized, PerfWarningScope())
struct InteractionAndPerfWarnTests {

    // MARK: - Interaction Names & Interning (interaction/tests.rs)

    @Test("InteractionNames: normalizes hex/numeric IDs, unkeyed segments, prose, non-ASCII, and length cap")
    func namesNormalizationAndInterning() {
        #expect(InteractionNames.normalize(path: "#0/sidebar/row-x1208", keep: 4) == "sidebar/row-x*")
        #expect(InteractionNames.normalize(path: "#0/#2/list/item-3f9a2c41d7e0/open", keep: 4) == "list/item-*/open")
        #expect(InteractionNames.normalize(path: "#0/a/b/c/d/e", keep: 4) == "b/c/d/e")
        #expect(InteractionNames.normalize(path: "#0/notes/Buy milk tomorrow", keep: 4) == "notes/~")
        #expect(InteractionNames.normalize(path: "#0/k-palette", keep: 4) == "k-palette")
        #expect(InteractionNames.normalize(path: "#0/a\u{00E9}b", keep: 4) == "a_b")
        #expect(InteractionNames.normalize(path: "#0/" + String(repeating: "x", count: 50), keep: 4).count == 32)

        let names = InteractionNames()
        let a = names.control(path: "#0/list/row-1/open")
        let b = names.control(path: "#0/list/row-22/open")
        #expect(a.hash == b.hash)
        #expect(a.text == "list/row-*/open")
        #expect(a.text == b.text)

        let route = names.route(page: "#0/settings", modal: "#0/settings/confirm-7")
        #expect(route.text == "settings+modal:confirm-*")
        #expect(names.route(page: nil, modal: nil).text == "root")
    }

    // MARK: - Interaction Gate & Rollup

    @Test("InteractionGate: requires RUNE_PERF=1 or loopback OTLP endpoint outside headless mode")
    func interactionGateParity() {
        #expect(InteractionGate.wanted(perfEnv: "1", otelEnv: nil, headless: true))
        #expect(!InteractionGate.wanted(perfEnv: "0", otelEnv: "http://127.0.0.1:27686", headless: false))
        #expect(InteractionGate.wanted(perfEnv: nil, otelEnv: "http://127.0.0.1:27686", headless: false))
        #expect(InteractionGate.wanted(perfEnv: nil, otelEnv: "http://localhost:4318/", headless: false))
        #expect(!InteractionGate.wanted(perfEnv: nil, otelEnv: "http://127.0.0.1:27686", headless: true))
        #expect(!InteractionGate.wanted(perfEnv: nil, otelEnv: "https://otel.example.com:4318", headless: false))
        #expect(!InteractionGate.wanted(perfEnv: nil, otelEnv: nil, headless: false))

        let ipv6 = InteractionGate.loopback("[::1]:4318")
        #expect(ipv6?.host == "::1" && ipv6?.port == 4318)
        let def = InteractionGate.endpoint(otelEnv: nil)
        #expect("\(def.host):\(def.port)" == InteractionGate.defaultEndpoint)
    }

    #if os(macOS) || os(Linux) || os(Windows)
    @Test func interactionGateReadsEnvironmentChanges() async {
        await #expect(processExitsWith: .success) {
            func set(_ name: String, _ value: String) {
                #if os(Windows)
                let changed = name.withCString(encodedAs: UTF16.self) { key in
                    value.withCString(encodedAs: UTF16.self) { SetEnvironmentVariableW(key, $0) }
                }
                precondition(changed)
                #else
                precondition(setenv(name, value, 1) == 0)
                #endif
            }
            set("RUNE_PERF", "0")
            set("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
            precondition(!InteractionGate.isEnabled())
            set("RUNE_PERF", " 1 ")
            precondition(InteractionGate.isEnabled(headless: true))
            set("RUNE_PERF", "")
            precondition(InteractionGate.isEnabled())
            precondition(!InteractionGate.isEnabled(headless: true))
            set("OTEL_EXPORTER_OTLP_ENDPOINT", "https://example.invalid:4318")
            precondition(!InteractionGate.isEnabled())

            let tracker = InteractionTracker()
            let name = tracker.names.fixed("control")
            _ = tracker.frameBegins(queued: true, nowNs: 1)
            tracker.noted(note: InteractionNote(route: name, control: name, action: "press", rank: 1),
                          arrivedNs: 1, startedNs: 1, handlerMs: 0)
            InteractionGate.forceOnForTesting = true
            recordFramePhase(.paint, wallMs: 3, cpuMs: 1)
            set("RUNE_PERF", "1")
            InteractionGate.forceOnForTesting = false
            recordFramePhase(.paint, wallMs: 5, cpuMs: 2)
            InteractionGate.forceOnForTesting = nil
            recordFramePhase(.paint, wallMs: 7, cpuMs: 3)
            _ = tracker.built(shaped: 0, nodes: 0, nowNs: 2)
            let finished = tracker.finish(submittedNs: 3)
            precondition(finished?.phases[InteractionPhase.paint.rawValue] == 10)
            precondition(takeFramePhases()[FramePhase.paint.rawValue] == 15)
        }
    }
    #endif

    @Test("InteractionRollup: histogram quantiles land within bucket accuracy")
    func rollupQuantilesParity() {
        let names = InteractionNames()
        let route = names.fixed("root")
        let control = names.fixed("save")
        let rollup = InteractionRollup()
        for i in 1...100 {
            rollup.add(route: route, control: control, action: "on_press", ms: Double(i), slow: i > 98, contended: false)
        }
        let rolls = rollup.takeAll()
        #expect(rolls.count == 1)
        let r = rolls[0]
        #expect(r.count == 100 && r.slow == 2 && r.maxMs == 100.0)
        #expect(abs(r.quantile(0.5) - 50.0) / 50.0 < 0.16)
        #expect(abs(r.quantile(0.98) - 98.0) / 98.0 < 0.16)
        #expect(rollup.isEmpty)
    }

    // MARK: - Interaction Cause, Stacks & OTLP Export (sampler_tests.rs + tests.rs)

    @Test("InteractionStacks & InteractionCause: hottest app frame attribution and all 9 blame cases")
    func stacksAndCauseClassification() {
        func sampled(_ id: UInt, waiting: Bool, cpuUs: UInt64, atMs: UInt64) -> InteractionSampledStack {
            InteractionSampledStack(
                raw: InteractionRawStack(pcs: [id], waiting: waiting, cpuUs: cpuUs),
                atNs: atMs * 1_000_000
            )
        }

        let s = InteractionStacks.from(samples: [
            sampled(0, waiting: true, cpuUs: 0, atMs: 0),
            sampled(1, waiting: false, cpuUs: 1000, atMs: 4),
            sampled(0, waiting: true, cpuUs: 1000, atMs: 8),
            sampled(0, waiting: true, cpuUs: 2000, atMs: 12),
        ])!
        #expect(s.taken == 4 && s.waiting == 3)
        let resolved = s.names { raw in
            if raw.pcs[0] == 0 {
                return [
                    InteractionStackFrame(name: "__semwait_signal (libsystem_kernel)", isApp: false),
                    InteractionStackFrame(name: "std::thread::sleep", isApp: false),
                    InteractionStackFrame(name: "app::save", isApp: true),
                    InteractionStackFrame(name: "app::main", isApp: true),
                ]
            } else {
                return [
                    InteractionStackFrame(name: "taffy::compute", isApp: true),
                    InteractionStackFrame(name: "app::view", isApp: true),
                ]
            }
        }
        #expect(resolved.hot.count == 2)
        #expect(resolved.hot[0].name == "app::save" && resolved.hot[0].count == 3)
        #expect(resolved.hot[1].name == "taffy::compute" && resolved.hot[1].count == 1)
        #expect(resolved.stack.first == "__semwait_signal (libsystem_kernel)")
        #expect(abs((s.cpuShare ?? 0) - 2.0 / 12.0) < 1e-9)
        #expect(InteractionStacks.from(samples: []) == nil)
        #expect(InteractionStacks.from(samples: [sampled(1, waiting: false, cpuUs: 0, atMs: 0)])?.cpuShare == nil)

        // All 9 InteractionCause.classify cases from sampler_tests.rs
        let slow = 16.7
        let waitingStacks = InteractionStacks(taken: 7, waiting: 6, cpuShare: nil, raw: [])
        let readyStacks = InteractionStacks(taken: 7, waiting: 0, cpuShare: nil, raw: [])
        let cpuStacks = InteractionStacks(taken: 7, waiting: 1, cpuShare: 0.9, raw: [])
        #expect(InteractionCause.classify(workMs: 10.0, slowMs: slow, cpuMs: 9.0, stacks: nil, overloaded: false) == .queued)
        #expect(InteractionCause.classify(workMs: 40.0, slowMs: slow, cpuMs: 36.0, stacks: nil, overloaded: true) == .cpu)
        #expect(InteractionCause.classify(workMs: 40.0, slowMs: slow, cpuMs: 1.0, stacks: waitingStacks, overloaded: true) == .blocked)
        #expect(InteractionCause.classify(workMs: 40.0, slowMs: slow, cpuMs: 1.0, stacks: nil, overloaded: false) == .blocked)
        #expect(InteractionCause.classify(workMs: 40.0, slowMs: slow, cpuMs: 1.0, stacks: nil, overloaded: true) == .schedulerWait)
        #expect(InteractionCause.classify(workMs: 40.0, slowMs: slow, cpuMs: 4.0, stacks: readyStacks, overloaded: false) == .schedulerWait)
        #expect(InteractionCause.classify(workMs: 40.0, slowMs: slow, cpuMs: nil, stacks: cpuStacks, overloaded: false) == .cpu)
        #expect(InteractionCause.classify(workMs: 40.0, slowMs: slow, cpuMs: nil, stacks: nil, overloaded: false) == .cpu)
        #expect(InteractionCause.classify(workMs: 40.0, slowMs: slow, cpuMs: nil, stacks: nil, overloaded: true) == .schedulerWait)
    }

    @Test("InteractionTracker & Exporter: slow click breaches signature, records phases, and emits OTLP spans")
    func trackerAndOtlpExport() throws {
        let tracker = InteractionTracker()
        let route = tracker.names.route(page: "#0/settings", modal: nil)
        let control = tracker.names.control(path: "#0/settings/save-42")
        let note = InteractionNote(route: route, control: control, action: "on_press", rank: 3)

        let base: UInt64 = 1_000_000_000
        _ = tracker.frameBegins(queued: true, nowNs: base, cpuMs: 1.0, slowMs: 16.7, overloaded: false)
        tracker.noted(note: note, arrivedNs: base, startedNs: base + 100_000, handlerMs: 26.0)
        tracker.committed(why: CommitWhy.input)
        tracker.addPhase(.commit, ms: 2.0)
        tracker.addPhase(.view, ms: 12.0)
        tracker.addPhase(.layout, ms: 4.0)
        tracker.addPhase(.paint, ms: 3.0)
        _ = tracker.built(shaped: 12, nodes: 42, nowNs: base + 30_000_000, cpuMs: 10.0, stacks: nil, slowMs: 16.7, overloaded: false)
        let finished = tracker.finish(submittedNs: base + 31_000_000, presentsAtNs: base + 35_000_000, slowMs: 16.7, overloaded: false)
        #expect(finished != nil)
        #expect(finished?.slow == true)
        #expect(finished?.cause == InteractionCause.blocked)
        #expect(tracker.isBreached(note))

        let report = SlowInteractionReport(
            route: route.text,
            control: control.text,
            action: "on_press",
            arrivedNs: base,
            frameStartNs: base,
            builtNs: base + 30_000_000,
            submittedNs: base + 31_000_000,
            presentNs: base + 35_000_000,
            handlerMs: 26.0,
            phases: finished!.phases,
            why: CommitWhy.input,
            commits: 1,
            shaped: 12,
            nodes: 42,
            reused: 10,
            rebuilt: [("settings", 32)],
            cpuMs: 9.0,
            cause: .blocked,
            stacks: nil
        )
        let spans = InteractionExporter.slowSpans(report)
        let names = spans.compactMap { $0["name"] as? String }
        #expect(names.first == "ui.interaction")
        #expect(names.contains("update"))
        #expect(names.contains("encode"))
        #expect(names.contains("present_wait"))
        let updateAttrs = spans.first(where: { ($0["name"] as? String) == "update" })?["attributes"] as? [[String: Any]] ?? []
        #expect(updateAttrs.contains { ($0["key"] as? String) == "rune.view_ms" })
        let body = try InteractionExporter.encodeOTLPBody(spans: spans)
        #expect(body.contains("resourceSpans"))
        #expect(body.contains("settings/save-*"))
    }

    // MARK: - InteractionWatchdog State Machine (watchdog_tests.rs)

    @Test("InteractionWatchdog: waiting, sampling, hurry, frame replacement, idle rest & park")
    func watchdogStateMachineTransitions() {
        let ms: UInt64 = 1_000_000
        let afterUs = InteractionWatchdog.afterMs * 1000
        let hurryUs = InteractionWatchdog.hurryMs * 1000

        func running(_ seq: UInt64, start: UInt64, after: UInt32 = afterUs) -> InteractionWatchdog.RunningFrame {
            InteractionWatchdog.RunningFrame(seq: seq, startNs: start, afterUs: after)
        }

        // 1. Sampled once old enough (12ms) and then every 4ms
        var watch = InteractionWatchdog.WatchState.unarmed
        #expect(InteractionWatchdog.step(&watch, event: .look(frame: running(1, start: 100 * ms), nowNs: 103 * ms))
            == [.sleepNs(9 * ms)])
        #expect(watch == .waiting(seq: 1, dueNs: 112 * ms))
        #expect(InteractionWatchdog.step(&watch, event: .look(frame: running(1, start: 100 * ms), nowNs: 112 * ms))
            == [.sample(seq: 1, startNs: 100 * ms, atNs: 112 * ms)])
        _ = InteractionWatchdog.step(&watch, event: .taken(seq: 1, nowNs: 113 * ms))
        #expect(InteractionWatchdog.step(&watch, event: .look(frame: running(1, start: 100 * ms), nowNs: 114 * ms))
            == [.sleepNs(3 * ms)])
        #expect(InteractionWatchdog.step(&watch, event: .look(frame: running(1, start: 100 * ms), nowNs: 117 * ms))
            == [.sample(seq: 1, startNs: 100 * ms, atNs: 117 * ms)])

        // 2. Hurry brings waiting frame forward (4ms)
        var hurryWatch = InteractionWatchdog.WatchState.unarmed
        _ = InteractionWatchdog.step(&hurryWatch, event: .look(frame: running(1, start: 100 * ms), nowNs: 101 * ms))
        #expect(InteractionWatchdog.step(&hurryWatch, event: .look(frame: running(1, start: 100 * ms, after: hurryUs), nowNs: 104 * ms))
            == [.sample(seq: 1, startNs: 100 * ms, atNs: 104 * ms)])

        // 3. Idle transitions through quiet (8ms poll) -> rest (1s) -> park, then re-arms cleanly
        var idleWatch = InteractionWatchdog.WatchState.unarmed
        _ = InteractionWatchdog.step(&idleWatch, event: .look(frame: running(1, start: 100 * ms), nowNs: 120 * ms))
        _ = InteractionWatchdog.step(&idleWatch, event: .taken(seq: 1, nowNs: 121 * ms))
        #expect(InteractionWatchdog.step(&idleWatch, event: .look(frame: nil, nowNs: 122 * ms))
            == [.sleepNs(InteractionWatchdog.idlePollNs)])
        #expect(InteractionWatchdog.step(&idleWatch, event: .look(frame: nil, nowNs: 122 * ms + InteractionWatchdog.restNs - 1))
            == [.sleepNs(InteractionWatchdog.idlePollNs)])
        #expect(InteractionWatchdog.step(&idleWatch, event: .look(frame: nil, nowNs: 122 * ms + InteractionWatchdog.restNs))
            == [.park])
        #expect(InteractionWatchdog.step(&idleWatch, event: .look(frame: nil, nowNs: 5000 * ms)) == [.park])
        #expect(InteractionWatchdog.step(&idleWatch, event: .look(frame: running(9, start: 5000 * ms), nowNs: 5001 * ms))
            == [.sleepNs(11 * ms)])
    }

    // MARK: - PerfWarn (overbuilt, handlerSite, IdleMeter, CommitMeter, Budget, Launch)

    @Test("PerfWarn: overbuilt threshold, memoKeyReplaced, handlerSite grouping, CommitBudget & PerfLaunch")
    func perfWarnWarningsAndReports() {
        PerfWarn.resetForTesting()
        defer { PerfWarn.resetForTesting() }

        PerfWarn.overbuilt(path: "/root/short", site: nil, built: 150, mounted: 10)
        #expect(PerfWarn.takeTestLog().isEmpty)

        PerfWarn.overbuilt(path: "/root/overbuilt-rows", site: nil, built: 1000, mounted: 10)
        PerfWarn.overbuilt(path: "/root/overbuilt-rows", site: nil, built: 1000, mounted: 10)
        let overbuiltLog = PerfWarn.takeTestLog()
        #expect(overbuiltLog.count == 1)
        #expect(overbuiltLog[0].contains("overbuilt-rows") && overbuiltLog[0].contains("built 1000 rows"))

        PerfWarn.memoKeyReplaced(id: "outer", existing: "inner", site: "view.swift:12")
        let memoLog = PerfWarn.takeTestLog()
        #expect(memoLog.count == 1 && memoLog[0].contains("\"outer\"") && memoLog[0].contains("\"inner\""))

        #expect(PerfWarn.handlerSite(name: "on_press", path: "#0/list/r12")
            == PerfWarn.handlerSite(name: "on_press", path: "#0/list/r7"))
        #expect(PerfWarn.handlerSite(name: "on_press", path: "#0/list/r12")
            != PerfWarn.handlerSite(name: "on_hover", path: "#0/list/r12"))

        // CommitBudget & PerfLaunch exact report formatting
        let line = CommitBudget.report(
            totalMs: 14.2,
            budgetMs: 8.0,
            phases: [9.0, 14.0, 3.0, 1.0, 0.0, 1.5],
            why: CommitWhy.poll,
            leftOut: 3
        )
        #expect(line == "rune: commit took 14.2 ms, over RUNE_COMMIT_BUDGET_MS=8: view 9.0, layout 3.0 (text 1.0), apply 1.5 ms; most in the view (63%); committed for poll (3 more over budget since the last line)")

        #expect(PerfLaunch.report(setupMs: 5, initMs: 40, viewMs: 20, totalMs: 400) == nil)
        let launch = PerfLaunch.report(setupMs: 10, initMs: 180, viewMs: 12, totalMs: 260)
        #expect(launch == "first frame took 260 ms (setup 10 ms, init 180 ms, first view 12 ms, window and GPU 58 ms); the slowest is `init`: start slow work from `on_ready`")
    }

    @Test("IdleMeter & CommitMeter: detects 30-frame poll noop, 120-frame idle wake loops, and scroll commit streaks")
    func idleMeterAndCommitMeterParity() {
        PerfWarn.resetForTesting()
        defer { PerfWarn.resetForTesting() }

        let idle = IdleMeter()
        let snap = IdleMeter.DrawnSnapshot(instances: [1, 2, 3, 4], surfaceKey: 42)
        // Warmup + 30 polled frames with no pixel changes triggers poll noop warning on frame 31 (30 consecutive same==true)
        idle.begins(quiet: true, timer: false, live: false)
        idle.ends(clock: 0.0, animating: false, drawn: snap, windowName: "poll-noop")
        for i in 1...35 {
            _ = idle.polled(true)
            idle.begins(quiet: true, timer: false, live: false)
            idle.ends(clock: Double(i) / 60.0, animating: false, drawn: snap, windowName: "poll-noop")
        }
        let pollLogs = PerfWarn.takeTestLog(resetSites: true)
        #expect(pollLogs.count == 1)
        #expect(pollLogs[0].contains("returned true but nothing changed (30 frames in a row)"))

        // 120-frame timer wake loop emits warning naming wake_after loop
        let timerIdle = IdleMeter()
        timerIdle.begins(quiet: true, timer: true, live: false)
        timerIdle.ends(clock: 0.0, animating: false, drawn: snap, windowName: "idle-loop")
        for i in 1..<120 {
            timerIdle.begins(quiet: true, timer: true, live: false)
            timerIdle.ends(clock: Double(i) / 120.0, animating: false, drawn: snap, windowName: "idle-loop")
        }
        #expect(PerfWarn.takeTestLog().isEmpty)
        timerIdle.begins(quiet: true, timer: true, live: false)
        timerIdle.ends(clock: 1.0, animating: false, drawn: snap, windowName: "idle-loop")
        let timerLogs = PerfWarn.takeTestLog()
        #expect(timerLogs.count == 1 && timerLogs[0].contains("woken by a `wake_after` loop"))

        // CommitMeter warns once when poll commits on 6 of 8 scroll frames
        let meter = CommitMeter()
        for _ in 0..<8 {
            meter.poll()
            meter.frameEnds(scrolling: true, committed: true)
        }
        let commitLogs = PerfWarn.takeTestLog()
        #expect(commitLogs.count == 1 && commitLogs[0].contains("committed the view on 6 of 6 frames of a scroll"))
    }
}
