import Foundation
import Testing
@testable import Rune
#if canImport(Darwin)
import Darwin
#endif

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

    @Test("perf_warn/tests.rs: memo over a differently keyed root warns once per site")
    func aMemoOverADifferentlyKeyedRootWarnsOncePerSite() {
        Self.resetAll()
        PerfWarn.testEnabledOverride = true
        defer { Self.resetAll() }

        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            let same: El<Int> = memo("same", 0) { col().key("same") }
            let renamed: El<Int> = memo("outer", 0) { col().key("inner") }
            return col().child(same).child(renamed)
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 1.0 / 60.0) { n, _ in n += 1 }
        _ = rt.frame(at: 1.0 / 60.0)
        let log = PerfWarn.takeTestLog()
        #expect(log.count == 1, "expected 1 warning, got \(log)")
        #expect(log[0].contains("\"outer\"") && log[0].contains("\"inner\""), "log: \(log[0])")
        #expect(rt.element(byKey: "outer") != nil && rt.element(byKey: "inner") == nil)
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

    @Test("idle_tests.rs: exhaustive depth-5 IdleMeter walk + 120-frame wake label checks match Old oracle")
    func idleReadingsWalk() {
        struct OldIdle {
            var idleFrom: Double = 0.0
            var idleFrames: UInt32 = 0
            var woken: (Bool, Bool, Bool) = (false, false, false)

            var label: String {
                switch woken {
                case (true, _, true): return "a `wake_after` loop whose `poll` returns true"
                case (true, false, false): return "a `wake_after` loop"
                case (true, true, false): return "a `wake_after` loop and a live value"
                case (false, _, _): return "a live value"
                }
            }

            mutating func end(_ r: IdleMeter.IdleReading) -> (String, Double)? {
                if !r.quiet || r.animating || r.same == false {
                    idleFrames = 0
                    return nil
                }
                guard r.same != nil, (r.timer || r.live) else { return nil }
                if idleFrames == 0 || r.clock - idleFrom > 2.0 {
                    idleFrom = r.clock
                    idleFrames = 0
                    woken = (false, false, false)
                }
                idleFrames += 1
                woken.0 = woken.0 || r.timer
                woken.1 = woken.1 || r.live
                woken.2 = woken.2 || r.polled
                if idleFrames == 120 {
                    return (label, r.clock - idleFrom)
                }
                return nil
            }
        }

        func checkReading(
            _ streak: inout IdleMeter.StreakState,
            _ old: inout OldIdle,
            _ r: IdleMeter.IdleReading
        ) -> String? {
            let expected = old.end(r)
            let got = IdleMeter.stepIdleReading(&streak, reading: r).map { ($0.0.label, $0.1) }
            #expect(got?.0 == expected?.0 && got?.1 == expected?.1)
            switch streak {
            case .watching:
                #expect(old.idleFrames == 0)
            case let .counting(from, frames, woke):
                #expect(from == old.idleFrom && frames == old.idleFrames && woke.label == old.label)
            }
            return got?.0
        }

        let live = IdleMeter.IdleReading(
            clock: 0.0, quiet: true, animating: false, same: true, timer: false, live: true, polled: false
        )
        var events: [IdleMeter.IdleReading] = []
        var r1 = live; r1.live = false; r1.timer = true
        var r2 = live; r2.polled = true
        var r3 = live; r3.live = false; r3.timer = true; r3.polled = true
        var r4 = live; r4.live = false; r4.polled = true
        var r5 = live; r5.quiet = false
        var r6 = live; r6.animating = true
        var r7 = live; r7.same = nil
        var r8 = live; r8.same = false
        var r9 = live; r9.clock = 2.0
        var r10 = live; r10.clock = 2.01
        var r11 = live; r11.live = true; r11.timer = true
        events = [live, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11]

        let allLabels = [
            "a `wake_after` loop whose `poll` returns true",
            "a `wake_after` loop",
            "a `wake_after` loop and a live value",
            "a live value",
        ]

        func walk(
            _ s: IdleMeter.StreakState,
            _ old: OldIdle,
            _ events: [IdleMeter.IdleReading],
            _ depth: Int,
            _ seen: inout [Bool]
        ) {
            if depth == 0 { return }
            for r in events {
                var ns = s
                var nold = old
                if let label = checkReading(&ns, &nold, r),
                   let idx = allLabels.firstIndex(of: label) {
                    seen[idx] = true
                }
                walk(ns, nold, events, depth - 1, &seen)
            }
        }

        var seen = [false, false, false, false]
        var s = IdleMeter.StreakState.watching
        var old = OldIdle()
        walk(s, old, events, 5, &seen)

        for seed in [live, r1] {
            _ = checkReading(&s, &old, r5)
            for _ in 0..<118 {
                _ = checkReading(&s, &old, seed)
            }
            walk(s, old, events, 5, &seen)
        }

        let orderedLabels = [
            "a live value",
            "a `wake_after` loop",
            "a `wake_after` loop and a live value",
            "a `wake_after` loop whose `poll` returns true",
        ]
        let combos: [(Bool, Bool, Bool)] = [
            (false, true, false),
            (true, false, false),
            (true, true, false),
            (true, false, true),
        ]
        for (i, (timer, isLive, polled)) in combos.enumerated() {
            _ = checkReading(&s, &old, r5)
            let reading = IdleMeter.IdleReading(
                clock: 0.0, quiet: true, animating: false, same: true, timer: timer, live: isLive, polled: polled
            )
            for _ in 0..<119 {
                #expect(checkReading(&s, &old, reading) == nil)
            }
            #expect(checkReading(&s, &old, reading) == orderedLabels[i])
        }
        #expect(seen.allSatisfy { $0 }, "the walk reaches every wake label: \(seen)")
    }

    // MARK: - interaction/frame_tests.rs (frame_phase_walk)

    @Test("frame_tests.rs: exhaustive 8^5 frame phase walk matches Old tracker oracle")
    func framePhaseWalk() {
        Self.resetAll()
        defer { Self.resetAll() }

        struct OldTimed {
            var arrived: UInt64
            var frameStart: UInt64
            var handlerMs: Double
            var rank: UInt8
            var why: UInt16
            var commits: UInt32
            var built: (UInt64, [Double], UInt32)?
            var cpu: (Double?, Double?)
            var stacks: UInt32?
        }

        struct OldTracker {
            var frameStart: UInt64? = nil
            var began: (UInt64, Double?)? = nil
            var frameWhy: UInt16 = 0
            var timed: OldTimed? = nil
            var times: [Double] = [Double](repeating: 0, count: 6)
            var active: Bool = false

            mutating func begin(queued: Bool, now: UInt64, cpu: Double?) -> (OldTimed, UInt64, UInt64)? {
                let left = timed?.built?.0
                let finished = left.flatMap { finish(submitted: $0, presentsAt: nil) }
                frameStart = queued ? now : nil
                began = (now, queued ? cpu : nil)
                frameWhy = 0
                return finished
            }

            mutating func noted(rank: UInt8, at: UInt64?, started: UInt64, handlerMs: Double) {
                let fs: UInt64
                if let existing = frameStart {
                    fs = existing
                } else {
                    fs = started
                    frameStart = fs
                }
                let arrived = min(at ?? fs, fs)
                if var t = timed, t.built == nil {
                    t.arrived = min(t.arrived, arrived)
                    t.handlerMs += handlerMs
                    if rank > t.rank { t.rank = rank }
                    timed = t
                } else {
                    let c0 = began?.1
                    timed = OldTimed(
                        arrived: arrived,
                        frameStart: fs,
                        handlerMs: handlerMs,
                        rank: rank,
                        why: 0,
                        commits: 0,
                        built: nil,
                        cpu: (c0, nil),
                        stacks: nil
                    )
                    times = [Double](repeating: 0, count: 6)
                    active = true
                }
            }

            mutating func committed(why: UInt16) {
                frameWhy |= why
                if var t = timed, t.built == nil {
                    t.why |= why
                    t.commits += 1
                    timed = t
                }
            }

            mutating func build(
                shaped: UInt32,
                now: UInt64,
                cpu: Double?,
                stacks: UInt32?,
                slowMs: Double
            ) -> (UInt64, UInt64, UInt16, UInt32)? {
                let why = frameWhy
                frameStart = nil
                let prevBegan = began
                began = nil
                if var t = timed, t.built == nil {
                    let capturedTimes = times
                    times = [Double](repeating: 0, count: 6)
                    t.built = (now, capturedTimes, shaped)
                    if let c0 = t.cpu.0, let c1 = cpu {
                        t.cpu.1 = c1 - c0
                    } else {
                        t.cpu.1 = nil
                    }
                    t.stacks = stacks
                    timed = t
                    active = false
                    return nil
                }
                guard let start = prevBegan?.0, let s = stacks else { return nil }
                let work = Double(now >= start ? now - start : 0) / 1_000_000.0
                return work > slowMs ? (start, now, why, s) : nil
            }

            mutating func finish(submitted: UInt64, presentsAt: UInt64?) -> (OldTimed, UInt64, UInt64)? {
                guard let t = timed, let built = t.built else { return nil }
                timed = nil
                let sub = max(submitted, built.0)
                let present = presentsAt.map { max($0, sub) } ?? sub
                return (t, sub, present)
            }
        }

        func compare(_ got: InteractionTracker.Finished?, _ expected: (OldTimed, UInt64, UInt64)?) {
            #expect((got != nil) == (expected != nil))
            if let f = got, let (t, submitted, present) = expected {
                #expect(f.submittedNs == submitted && f.presentNs == present)
                #expect(f.builtNs == t.built?.0 && f.phases == t.built?.1 && f.shaped == t.built?.2)
                #expect(f.cpuMs == t.cpu.1 && f.stacks?.taken == t.stacks)
                let g = f.timed
                #expect(g.arrivedNs == t.arrived && g.frameStartNs == t.frameStart)
                #expect(abs(g.handlerMs - t.handlerMs) < 1e-12)
                #expect(g.note.rank == t.rank && g.why == t.why && g.commits == t.commits)
            }
        }

        let slowMs = 75.0
        let base: UInt64 = 1_000_000_000
        let ms: UInt64 = 1_000_000
        var slow = 0
        var quick = 0

        for startPath in 0..<32_768 {
            var path = startPath
            let tracker = InteractionTracker()
            var old = OldTracker()

            for stepIdx in 1...5 {
                let i = UInt64(stepIdx)
                let e = path % 8
                path /= 8
                let now = base + i * 30 * ms
                let cpu: Double? = (i % 3 != 0) ? Double(i) : nil
                switch e {
                case 0, 1:
                    let got = tracker.frameBegins(queued: e == 1, nowNs: now, cpuMs: cpu, slowMs: slowMs)
                    let exp = old.begin(queued: e == 1, now: now, cpu: cpu)
                    compare(got, exp)
                case 2, 3:
                    let rank = UInt8(e)
                    let at: UInt64? = (e == 3) ? base : nil
                    let handlerMs = Double(i) / 1000.0
                    old.noted(rank: rank, at: at, started: now, handlerMs: handlerMs)
                    let note = InteractionNote(
                        route: tracker.names.fixed("page"),
                        control: tracker.names.fixed("button"),
                        action: "press",
                        rank: rank
                    )
                    tracker.noted(note: note, arrivedNs: at, startedNs: now, handlerMs: handlerMs)
                case 4:
                    old.committed(why: UInt16(1 << i))
                    tracker.committed(why: UInt16(1 << i))
                case 5:
                    let taken: UInt32? = (i % 3 != 0) ? UInt32(i) : nil
                    let untimed: Bool
                    if case .open = tracker.currentFrameState { untimed = false } else { untimed = true }
                    let expected = old.build(shaped: UInt32(i), now: now, cpu: cpu, stacks: taken, slowMs: slowMs)
                    let stacks = taken.map { InteractionStacks(taken: $0, waiting: $0, cpuShare: nil, raw: []) }
                    let got = tracker.built(shaped: UInt32(i), nodes: 99, nowNs: now, cpuMs: cpu, stacks: stacks, slowMs: slowMs)
                    #expect(got?.startNs == expected?.0 && got?.builtNs == expected?.1 && got?.why == expected?.2 && got?.stacks.taken == expected?.3)
                    if untimed && expected != nil {
                        slow += 1
                    } else if untimed && expected == nil && taken != nil {
                        quick += 1
                    }
                case 6, 7:
                    let (sub, present): (UInt64, UInt64?) = (e == 6) ? (base, now) : (now, base)
                    let got = tracker.finish(submittedNs: sub, presentsAtNs: present, slowMs: slowMs)
                    let exp = old.finish(submitted: sub, presentsAt: present)
                    compare(got, exp)
                default:
                    Issue.record("unexpected event \(e)")
                }

                if old.active { old.times[InteractionPhase.paint.rawValue] += Double(i) }
                if tracker.isPhaseCollectionActive { tracker.addPhase(.paint, ms: Double(i)) }
                #expect(tracker.isPhaseCollectionActive == old.active)
                #expect(tracker.currentPhaseTimes == old.times)

                switch (tracker.currentFrameState, old.timed) {
                case (.idle, nil):
                    #expect(old.began == nil)
                case let (.begun(at, queued, c, why), nil):
                    #expect(old.began?.0 == at && old.began?.1 == c)
                    #expect((queued ? at : nil) == old.frameStart && why == old.frameWhy)
                case let (.open(timed, inputStart, c), .some(t)):
                    #expect(t.built == nil)
                    #expect(inputStart == old.frameStart && c == t.cpu.0)
                    #expect(timed.arrivedNs == t.arrived && timed.frameStartNs == t.frameStart)
                    #expect(timed.note.rank == t.rank && abs(timed.handlerMs - t.handlerMs) < 1e-12)
                    #expect(timed.why == t.why && timed.commits == t.commits)
                case let (.built(b), .some(t)):
                    #expect(b.atNs == t.built?.0 && b.phases == t.built?.1 && b.shaped == t.built?.2)
                    #expect(b.cpuMs == t.cpu.1 && b.stacks?.taken == t.stacks)
                default:
                    Issue.record("phase mismatch")
                }
            }
            tracker.clearPendingRollupForTesting()
            InteractionTracker.resetForTesting()
        }
        #expect(slow > 0 && quick > 0, "expected both slow (\(slow)) and quick (\(quick)) untimed frames")
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

    @Test("watchdog_tests.rs: replaced mid look, arm-stall filing, and number-before-start boundaries")
    func watchdogInterFrameBoundaryTests() {
        let ms: UInt64 = 1_000_000
        let afterUs = InteractionWatchdog.afterMs * 1000
        let a: UInt64 = 100 * ms
        let b: UInt64 = 1000 * ms
        func running(_ seq: UInt64, _ start: UInt64) -> InteractionWatchdog.RunningFrame {
            .init(seq: seq, startNs: start, afterUs: afterUs)
        }
        func look1(_ watch: inout InteractionWatchdog.WatchState, _ frame: InteractionWatchdog.RunningFrame?, _ now: UInt64) -> InteractionWatchdog.Effect? {
            let fx = InteractionWatchdog.step(&watch, event: .look(frame: frame, nowNs: now))
            #expect(fx.count == 1)
            return fx.first
        }
        func taken(_ watch: inout InteractionWatchdog.WatchState, _ seq: UInt64, _ now: UInt64) {
            #expect(InteractionWatchdog.step(&watch, event: .taken(seq: seq, nowNs: now)).isEmpty)
        }
        func refusedAt13Ms(_ watch: inout InteractionWatchdog.WatchState) {
            #expect(look1(&watch, running(2, a), b + 13 * ms) == .sample(seq: 2, startNs: a, atNs: b + 13 * ms))
            taken(&watch, 2, b + 13 * ms)
        }

        // :122 a_frame_replaced_mid_look_is_sampled_at_17_ms_of_a_20_ms_stall
        do {
            var watch = InteractionWatchdog.WatchState.sampling(.init(seq: 1, taken: 3, dueNs: 0))
            refusedAt13Ms(&watch)
            #expect(look1(&watch, running(2, b), b + 13 * ms) == .sleepNs(4 * ms))
            #expect(look1(&watch, running(2, b), b + 17 * ms) == .sample(seq: 2, startNs: b, atNs: b + 17 * ms))
        }

        // :130 a_sample_taken_while_the_ui_stalls_in_arm_is_filed_under_the_new_frame
        do {
            var watch = InteractionWatchdog.WatchState.sampling(.init(seq: 1, taken: 3, dueNs: 0))
            #expect(look1(&watch, running(2, a), b + 17 * ms) == .sample(seq: 2, startNs: a, atNs: b + 17 * ms))
            taken(&watch, 2, b + 17 * ms)
            #expect(look1(&watch, running(2, b + 19 * ms), b + 19 * ms) == .sleepNs(2 * ms))
            #expect(watch == .sampling(.init(seq: 2, taken: 1, dueNs: b + 21 * ms)))
        }

        // :141 a_number_read_before_its_start_lands_keeps_its_progress_through_a_quiet_look
        do {
            var watch = InteractionWatchdog.WatchState.sampling(.init(seq: 1, taken: 3, dueNs: 0))
            refusedAt13Ms(&watch)
            #expect(look1(&watch, nil, b + 13 * ms) == .sleepNs(InteractionWatchdog.idlePollNs))
            #expect(look1(&watch, running(2, b + 14 * ms), b + 21 * ms) == .sample(seq: 2, startNs: b + 14 * ms, atNs: b + 21 * ms))
        }
    }

    @Test("watchdog_tests.rs: exhaustive WatchState vs Dev walks (short, parked, in-flight, nearly full)")
    func watchdogReferenceModelWalks() {
        let ms: UInt64 = 1_000_000
        let restNs = InteractionWatchdog.restNs
        let afterUs = InteractionWatchdog.afterMs * 1000
        let hurryUs = InteractionWatchdog.hurryMs * 1000
        let most = InteractionWatchdog.maxSamples
        let oldStart: UInt64 = 1000
        let newStart: UInt64 = 20 * ms

        struct DevWatchdog {
            var seen: UInt64 = 0
            var taken: Int = 0
            var next: UInt64 = 0
            var quietSince: UInt64? = nil

            mutating func look(start: UInt64, seq: UInt64, afterUs: UInt32, now: UInt64) -> InteractionWatchdog.Effect {
                if start == 0 {
                    let quiet: UInt64
                    if let q = quietSince { quiet = q } else { quiet = now; quietSince = now }
                    return (now - quiet < InteractionWatchdog.restNs) ? .sleepNs(InteractionWatchdog.idlePollNs) : .park
                }
                quietSince = nil
                if seq != seen { seen = seq; taken = 0 }
                if taken == 0 { next = start + UInt64(afterUs) * 1000 }
                if now < next || taken >= InteractionWatchdog.maxSamples {
                    return .sleepNs(taken >= InteractionWatchdog.maxSamples ? InteractionWatchdog.idlePollNs : (next - now))
                }
                return .sample(seq: seq, startNs: start, atNs: now)
            }

            mutating func sampled(now: UInt64) {
                taken += 1
                next = now + InteractionWatchdog.sampleIntervalNs
            }
        }

        enum Letter: Equatable {
            case see(start: UInt64, seq: UInt64, afterUs: UInt32)
            case pass(UInt64)
            case finish
        }

        let none = Letter.see(start: 0, seq: 1, afterUs: afterUs)
        let see1 = Letter.see(start: oldStart, seq: 1, afterUs: afterUs)
        let alphabet: [Letter] = [
            none,
            see1,
            .see(start: oldStart, seq: 1, afterUs: hurryUs),
            .see(start: oldStart, seq: 2, afterUs: afterUs),
            .see(start: oldStart, seq: 2, afterUs: hurryUs),
            .see(start: newStart, seq: 1, afterUs: afterUs),
            .see(start: newStart, seq: 1, afterUs: hurryUs),
            .see(start: newStart, seq: 2, afterUs: afterUs),
            .see(start: newStart, seq: 2, afterUs: hurryUs),
            .pass(5 * ms),
            .pass(13 * ms),
            .pass(restNs + 100 * ms),
            .finish,
        ]

        struct Reached {
            var waiting = false
            var sampling = false
            var quiet = false
            var parked = false
            var full = false
            var sampled = false
            var resumed = false
        }

        struct World {
            var watch: InteractionWatchdog.WatchState = .unarmed
            var dev = DevWatchdog()
            var now: UInt64 = 1000
            var inFlight: UInt64? = nil
            var failed = false

            mutating func apply(_ letter: Letter, _ reached: inout Reached) {
                switch letter {
                case .pass(let ns):
                    now += ns
                case .finish:
                    guard let seq = inFlight else { failed = true; return }
                    inFlight = nil
                    _ = InteractionWatchdog.step(&watch, event: .taken(seq: seq, nowNs: now))
                    dev.sampled(now: now)
                case let .see(start, seq, au):
                    let frame: InteractionWatchdog.RunningFrame? = (start != 0)
                        ? .init(seq: seq, startNs: start, afterUs: au)
                        : nil
                    if frame != nil {
                        switch watch {
                        case .quiet, .parked:
                            if watch.progress(for: seq) != nil { reached.resumed = true }
                        default: break
                        }
                    }
                    let fx = InteractionWatchdog.step(&watch, event: .look(frame: frame, nowNs: now))
                    guard fx.count == 1, let effect = fx.first else { failed = true; return }
                    let expected = dev.look(start: start, seq: seq, afterUs: au, now: now)
                    if effect != expected { failed = true; return }
                    switch effect {
                    case let .sample(s, _, _):
                        if frame == nil { failed = true; return }
                        inFlight = s
                        reached.sampled = true
                    case .park:
                        if frame != nil { failed = true; return }
                    case .sleepNs(let wait):
                        if wait == 0 { failed = true; return }
                        if dev.taken >= InteractionWatchdog.maxSamples { reached.full = true }
                    }
                    if dev.taken > InteractionWatchdog.maxSamples { failed = true; return }
                    switch watch {
                    case .waiting:
                        reached.waiting = true
                    case .sampling:
                        reached.sampling = true
                    case .quiet:
                        if effect != .sleepNs(InteractionWatchdog.idlePollNs) { failed = true; return }
                        reached.quiet = true
                    case .parked:
                        if effect != .park { failed = true; return }
                        reached.parked = true
                    case .unarmed:
                        failed = true
                        return
                    }
                }
                let progress = watch.progress(for: dev.seen)
                if (progress?.taken ?? 0) != dev.taken { failed = true; return }
                if let p = progress, p.dueNs != dev.next { failed = true; return }
            }
        }

        func walk(_ world: World, _ depth: Int, _ reached: inout Reached) -> Bool {
            for letter in alphabet {
                switch letter {
                case .finish where world.inFlight == nil: continue
                case .see where world.inFlight != nil: continue
                default: break
                }
                var next = world
                next.apply(letter, &reached)
                if next.failed { return false }
                if depth > 1 {
                    if !walk(next, depth - 1, &reached) { return false }
                }
            }
            return true
        }

        func worldAfter(_ letters: [Letter]) -> World {
            var world = World()
            var dummy = Reached()
            for letter in letters { world.apply(letter, &dummy) }
            #expect(!world.failed)
            return world
        }

        // :303 every_short_sequence_of_reads_matches_the_old_loop (depth 7)
        do {
            var r = Reached()
            #expect(walk(World(), 7, &r))
            #expect(r.waiting && r.sampling && r.quiet && r.parked && r.sampled && r.resumed)
        }

        // :310 every_sequence_from_a_parked_watchdog_that_was_sampling_matches_the_old_loop (depth 6)
        do {
            let w = worldAfter([.pass(13 * ms), see1, .finish, none, .pass(restNs), none])
            if case .parked(let left) = w.watch { #expect(left != nil) } else { Issue.record("expected parked") }
            var r = Reached()
            #expect(walk(w, 6, &r))
            #expect(r.waiting && r.sampling && r.parked && r.resumed)
        }

        // :319 every_sequence_from_a_sample_in_flight_matches_the_old_loop (depth 6)
        do {
            let w = worldAfter([.pass(13 * ms), see1])
            #expect(w.inFlight != nil)
            var r = Reached()
            #expect(walk(w, 6, &r))
            #expect(r.waiting && r.sampling && r.quiet && r.resumed)
        }

        // :328 every_sequence_from_a_nearly_full_frame_matches_the_old_loop (depth 6)
        do {
            var letters: [Letter] = [.pass(13 * ms)]
            for _ in 0..<(most - 1) { letters.append(contentsOf: [see1, .finish, .pass(5 * ms)]) }
            let w = worldAfter(letters)
            if case .sampling(let p) = w.watch { #expect(p.taken == most - 1) } else { Issue.record("expected sampling") }
            var r = Reached()
            #expect(walk(w, 6, &r))
            #expect(r.full && r.sampling && r.quiet && r.resumed)
        }
    }

    @Test("watchdog_tests.rs: torn-read reordering between begin/disarm/hurry writes and look reads matches Dev")
    func watchdogTornReadOrderingWalk() {
        let ms: UInt64 = 1_000_000
        let afterUs = InteractionWatchdog.afterMs * 1000
        let hurryUs = InteractionWatchdog.hurryMs * 1000
        let most = InteractionWatchdog.maxSamples
        let oldStart: UInt64 = 1000
        let newStart: UInt64 = 20 * ms

        struct Memory {
            var seq: UInt64
            var start: UInt64
            var afterUs: UInt32
            mutating func apply(_ w: Write) {
                switch w {
                case .nextSeq: seq += 1
                case .afterUs(let us): afterUs = us
                case .start(let ns): start = ns
                case .hurry: afterUs = min(afterUs, InteractionWatchdog.hurryMs * 1000)
                }
            }
        }
        enum Write { case nextSeq, afterUs(UInt32), start(UInt64), hurry }

        final class Recorder: InteractionWatchdogFrames {
            var writes: [Write] = []
            func readStart() -> UInt64 { fatalError() }
            func readSeq() -> UInt64 { fatalError() }
            func readAfterUs() -> UInt32 { fatalError() }
            func nextSeq() { writes.append(.nextSeq) }
            func setAfterUs(_ us: UInt32) { writes.append(.afterUs(us)) }
            func setStart(_ ns: UInt64) { writes.append(.start(ns)) }
        }

        final class ScriptedFrames: InteractionWatchdogFrames {
            var memory: Memory
            let writes: [Write]
            let landedBy: [Int]
            var landed = 0
            var reads = 0

            init(memory: Memory, writes: [Write], landedBy: [Int]) {
                self.memory = memory
                self.writes = writes
                self.landedBy = landedBy
            }

            func readNext() -> Memory {
                let upto = landedBy[reads]
                for idx in landed..<upto { memory.apply(writes[idx]) }
                landed = upto
                reads += 1
                return memory
            }

            func readStart() -> UInt64 { readNext().start }
            func readSeq() -> UInt64 { readNext().seq }
            func readAfterUs() -> UInt32 { readNext().afterUs }
            func nextSeq() { fatalError() }
            func setAfterUs(_ us: UInt32) { fatalError() }
            func setStart(_ ns: UInt64) { fatalError() }
        }

        enum Program { case arm, disarm, hurry }
        func devReads(memory startMem: Memory, writes: [Write], landedBy: [Int]) -> (UInt64, UInt64, UInt32) {
            var memory = startMem
            var landed = 0
            func land(_ upto: Int) {
                for idx in landed..<upto { memory.apply(writes[idx]) }
                landed = upto
            }
            land(landedBy[0])
            let s = memory.start
            if s == 0 { return (0, 0, 0) }
            land(landedBy[1])
            let seq = memory.seq
            land(landedBy[2])
            return (s, seq, memory.afterUs)
        }

        struct Dev {
            var seen: UInt64
            var taken: Int
            var next: UInt64
            var quietSince: UInt64?
            mutating func look(start: UInt64, seq: UInt64, afterUs: UInt32, now: UInt64) -> InteractionWatchdog.Effect {
                if start == 0 {
                    let quiet: UInt64
                    if let q = quietSince { quiet = q } else { quiet = now; quietSince = now }
                    return (now - quiet < InteractionWatchdog.restNs) ? .sleepNs(InteractionWatchdog.idlePollNs) : .park
                }
                quietSince = nil
                if seq != seen { seen = seq; taken = 0 }
                if taken == 0 { next = start + UInt64(afterUs) * 1000 }
                if now < next || taken >= InteractionWatchdog.maxSamples {
                    return .sleepNs(taken >= InteractionWatchdog.maxSamples ? InteractionWatchdog.idlePollNs : (next - now))
                }
                return .sample(seq: seq, startNs: start, atNs: now)
            }
        }

        let recorder = Recorder()
        InteractionWatchdog.begin(frames: recorder, now: { newStart })
        let realArm = recorder.writes
        let refArm: [Write] = [.nextSeq, .afterUs(afterUs), .start(newStart)]
        #expect(realArm.count == refArm.count)

        let programs: [[Program]] = [
            [.arm],
            [.disarm, .arm],
            [.hurry, .arm],
            [.hurry, .disarm, .arm, .hurry],
            [.arm, .disarm],
            [.arm, .hurry],
        ]
        func writesOf(_ program: [Program], _ arm: [Write]) -> [Write] {
            program.flatMap { step in
                switch step {
                case .arm: return arm
                case .disarm: return [Write.start(0)]
                case .hurry: return [Write.hurry]
                }
            }
        }
        let memories = [
            Memory(seq: 1, start: oldStart, afterUs: afterUs),
            Memory(seq: 1, start: oldStart, afterUs: hurryUs),
            Memory(seq: 1, start: 0, afterUs: afterUs),
        ]
        let now = newStart + 13 * ms
        let seeds: [(InteractionWatchdog.WatchState, Dev)] = [
            (.unarmed, Dev(seen: 0, taken: 0, next: 0, quietSince: nil)),
            (.sampling(.init(seq: 1, taken: 3, dueNs: now - ms)), Dev(seen: 1, taken: 3, next: now - ms, quietSince: nil)),
            (.sampling(.init(seq: 1, taken: most, dueNs: 0)), Dev(seen: 1, taken: most, next: 0, quietSince: nil)),
            (.sampling(.init(seq: 2, taken: 3, dueNs: now + ms)), Dev(seen: 2, taken: 3, next: now + ms, quietSince: nil)),
        ]
        var mixed = false
        for memory in memories {
            for program in programs {
                let real = writesOf(program, realArm)
                let ref = writesOf(program, refArm)
                for first in 0...real.count {
                    for second in first...real.count {
                        for third in second...real.count {
                            let landed = [first, second, third]
                            let scripted = ScriptedFrames(memory: memory, writes: real, landedBy: landed)
                            let frame = InteractionWatchdog.look(frames: scripted)
                            let (start, seq, au) = devReads(memory: memory, writes: ref, landedBy: landed)
                            let expectedFrame: InteractionWatchdog.RunningFrame? = (start != 0)
                                ? .init(seq: seq, startNs: start, afterUs: au)
                                : nil
                            #expect(frame == expectedFrame)
                            if start == oldStart && seq == 2 { mixed = true }
                            for (var watch, var dev) in seeds {
                                let got = InteractionWatchdog.step(&watch, event: .look(frame: frame, nowNs: now)).first
                                let exp = dev.look(start: start, seq: seq, afterUs: au, now: now)
                                #expect(got == exp)
                            }
                        }
                    }
                }
            }
        }
        #expect(mixed, "expected at least one torn read pairing old start with seq 2")
    }

    @Test("watchdog_tests.rs: resume-boundary capture/collect, real thread sample, paused naming, image unloads, round-trip, and 1..=8 store walk")
    func watchdogStoreThreadAndSymbolParityTests() {
        @Sendable func rawSample(_ id: UInt64) -> InteractionRawStack {
            InteractionRawStack(pcs: [UInt(id)], waiting: false, cpuUs: id, imagesGeneration: 0)
        }
        @Sendable func ids(_ stacks: InteractionStacks) -> [UInt64] {
            stacks.raw.map(\.cpuUs)
        }
        @Sendable func captured(_ caught: InteractionCaughtSamples, _ taken: InteractionWatchdogTakenFlag, _ seq: UInt64, _ atNs: UInt64, _ sample: InteractionRawStack) {
            InteractionWatchdog.capture(samples: caught, taken: taken, seq: seq, atNs: atNs) { stopped in
                stopped(sample)
                return sample
            }
        }

        // :510 a_disarm_at_the_resume_boundary_finds_the_stack_of_its_frame
        do {
            let caught = InteractionCaughtSamples()
            let taken = InteractionWatchdogTakenFlag(false)
            var found: InteractionStacks? = nil
            InteractionWatchdog.capture(samples: caught, taken: taken, seq: 7, atNs: 1) { stopped in
                let s = rawSample(42)
                stopped(s)
                found = InteractionWatchdog.collected(samples: caught, taken: taken) { 7 }
                return s
            }
            #expect(found.map(ids) == [42])
            #expect(InteractionWatchdog.collected(samples: caught, taken: taken) { 9 } == nil)
        }

        // :527 a_real_thread_ending_its_frame_as_it_resumes_finds_the_stack
        #if os(macOS) && arch(arm64)
        do {
            final class LockFreeEndFlag: @unchecked Sendable {
                private let storage = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
                init() { storage.initialize(to: 0) }
                deinit { storage.deallocate() }
                @inline(never)
                func isSet() -> Bool {
                    sched_yield()
                    return storage.pointee != 0
                }
                @inline(never)
                func markEnded() {
                    storage.pointee = 1
                }
            }

            let caught = InteractionCaughtSamples()
            let taken = InteractionWatchdogTakenFlag(false)
            let endFlag = LockFreeEndFlag()
            let targetBox = LockedBox<InteractionThreadSamplerTarget?>(nil)
            let readySem = DispatchSemaphore(value: 0)
            let finishedSem = DispatchSemaphore(value: 0)
            let foundFromThread = LockedBox<[UInt64]?>(nil)

            let worker = Thread {
                targetBox.value = InteractionThreadSamplerTarget.current()
                readySem.signal()
                while !endFlag.isSet() {}
                foundFromThread.value = InteractionWatchdog.collected(samples: caught, taken: taken) { 7 }.map(ids)
                finishedSem.signal()
            }
            worker.start()
            readySem.wait()
            if let target = targetBox.value {
                InteractionWatchdog.capture(samples: caught, taken: taken, seq: 7, atNs: 1) { stopped in
                    target.sample(still: {
                        endFlag.markEnded()
                        return true
                    }, onStopped: stopped)
                }
            } else {
                endFlag.markEnded()
            }
            let waitRes = finishedSem.wait(timeout: .now() + .seconds(30))
            #expect(waitRes == .success)
            #expect(foundFromThread.value?.count == 1)
        }
        #endif

        // :551 a_disarm_finishes_while_naming_is_paused
        do {
            let caught = InteractionCaughtSamples()
            let taken = InteractionWatchdogTakenFlag(false)
            captured(caught, taken, 1, 1, rawSample(11))
            let earlier = InteractionWatchdog.collected(samples: caught, taken: taken) { 1 }
            #expect(earlier != nil)
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let done = DispatchSemaphore(value: 0)
            let namedBox = LockedBox<InteractionStacks.NamedSummary?>(nil)
            let finishedBox = LockedBox<[UInt64]?>(nil)

            DispatchQueue.global().async {
                namedBox.value = earlier?.names { sample in
                    entered.signal()
                    release.wait()
                    return [InteractionStackFrame(name: "app::\(sample.pcs.first ?? 0)", isApp: true)]
                }
            }
            entered.wait()
            DispatchQueue.global().async {
                captured(caught, taken, 3, 2, rawSample(33))
                finishedBox.value = InteractionWatchdog.collected(samples: caught, taken: taken) { 3 }.map(ids)
                done.signal()
            }
            let finished = done.wait(timeout: .now() + .seconds(30))
            release.signal()
            #expect(finished == .success)
            #expect(finishedBox.value == [33])
            // Allow naming closure to finish storing result
            Thread.sleep(forTimeInterval: 0.01)
            #expect(namedBox.value?.stack.first == "app::11")
        }

        // :589, :599, :609, :616 symbol unload checks
        do {
            let symbols = InteractionSymbolCache()
            var lookups = 0
            let f1 = symbols.frames(for: rawSample(0x40), generation: { 0 }) { _ in lookups += 1; return .init(name: "app::work", isApp: true) }
            #expect(f1.map(\.name) == ["app::work"])
            let f2 = symbols.frames(for: rawSample(0x40), generation: { 0 }) { _ in lookups += 1; return .init(name: "app::work", isApp: true) }
            #expect(f2.map(\.name) == ["app::work"] && lookups == 1)

            // :599 older generation -> bare 0x40, app == false, zero lookups
            let fUnloaded = InteractionSymbolCache().frames(for: rawSample(0x40), generation: { 1 }) { _ in
                Issue.record("unexpected lookup for older image generation")
                return .init(name: "bad", isApp: true)
            }
            #expect(fUnloaded.map(\.name) == ["0x40"] && fUnloaded[0].isApp == false)

            // :609 unload during lookup
            var gen: UInt64 = 0
            let fMidUnload = InteractionSymbolCache().frames(for: rawSample(0x40), generation: { gen }) { _ in
                gen = 1
                return .init(name: "app::replaced", isApp: true)
            }
            #expect(fMidUnload.map(\.name) == ["0x40"])

            // :616 unload forgets remembered names
            let reloadSym = InteractionSymbolCache()
            _ = reloadSym.frames(for: rawSample(0x40), generation: { 0 }) { _ in .init(name: "app::old", isApp: true) }
            let newer = InteractionRawStack(pcs: [0x40], waiting: false, cpuUs: 0x40, imagesGeneration: 1)
            let fNew = reloadSym.frames(for: newer, generation: { 1 }) { _ in .init(name: "app::new", isApp: true) }
            #expect(fNew.map(\.name) == ["app::new"])
        }

        // :626 cap + replace & :636 sample round trip through store
        do {
            let caught = InteractionCaughtSamples()
            let taken = InteractionWatchdogTakenFlag(false)
            let roundRaw = InteractionRawStack(pcs: [10, 20, 30], waiting: true, cpuUs: 5, imagesGeneration: 4)
            captured(caught, taken, 1, 77, roundRaw)
            let s1 = caught.collect(for: 1)
            #expect(s1?.raw.first?.pcs == [10, 20, 30] && s1?.raw.first?.waiting == true && s1?.raw.first?.cpuUs == 5 && s1?.raw.first?.imagesGeneration == 4)
            captured(caught, taken, 1, 90_077, rawSample(6))
            let s2 = caught.collect(for: 1)
            #expect(s2?.cpuShare == 1.0 / 90.0)
            #expect(taken.load())
        }

        // :671 every_short_run_of_frames_collects_what_the_old_store_did (length 1...8 -> 9,840 sequences)
        do {
            struct DevSamples {
                var samples: [(UInt64, UInt64)] = []
                var taken = false
                mutating func captured(_ seq: UInt64, _ id: UInt64) {
                    samples.append((seq, id))
                    taken = true
                }
                mutating func disarm(_ seq: UInt64) -> [UInt64]? {
                    guard taken else { return nil }
                    taken = false
                    let kept = samples.filter { $0.0 == seq }.map(\.1)
                    samples.removeAll()
                    return kept.isEmpty ? nil : kept
                }
            }
            enum Move { case arm, capture, disarm }
            let moves: [Move] = [.arm, .capture, .disarm]
            var keptAny = false
            var emptyAny = false
            for length in 1...8 {
                var count = 1
                for _ in 0..<length { count *= 3 }
                for num in 0..<count {
                    let caught = InteractionCaughtSamples()
                    let taken = InteractionWatchdogTakenFlag(false)
                    var dev = DevSamples()
                    var seq: UInt64 = 0
                    var running = false
                    var id: UInt64 = 0
                    var n = num
                    for _ in 0..<length {
                        let move = moves[n % 3]
                        n /= 3
                        switch move {
                        case .arm:
                            seq += 1
                            running = true
                        case .capture where running:
                            id += 1
                            captured(caught, taken, seq, id, rawSample(id))
                            dev.captured(seq, id)
                        case .capture:
                            break
                        case .disarm:
                            running = false
                            let got = InteractionWatchdog.collected(samples: caught, taken: taken) { seq }.map(ids)
                            if got != nil { keptAny = true }
                            if got == nil && id > 0 { emptyAny = true }
                            #expect(got == dev.disarm(seq))
                        }
                    }
                }
            }
            #expect(keptAny && emptyAny)
        }
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
