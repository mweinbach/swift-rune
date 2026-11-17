import Foundation
import Testing
@testable import Rune
import RuneMotion

@Suite("Window Lifecycle Parity (covered, life, reveal, wake, backoff)")
struct WindowLifecycleParityTests {

    // MARK: - window/covered_tests.rs (3 tests)

    @Test("window/covered_tests.rs:23 - covered window builds nothing across 100 updates and timers until it uncovers")
    func coveredWindowBuildsNothingUntilUncovered() {
        struct State: Equatable {
            var messages = 0
            var read = 0
            var polls = 0
        }
        final class Builds: @unchecked Sendable { var count = 0 }
        let builds = Builds()
        let rt = Runtime(
            state: State(),
            viewport: Vec2(200, 50),
            view: { s, _ in
                builds.count += 1
                return El<State>().size(200, 50).child(text("\(s.messages) \(s.read)").key("n"))
            }
        )
        rt.poll = { s, _, _ in
            s.polls += 1
            let unread = s.read < s.messages
            s.read = s.messages
            return unread
        }

        var t = 0.0
        _ = rt.frame(at: t)
        #expect(rt.elements().first(where: { $0.key == "n" })?.text == "0 0")

        rt.setLiveVisible(false)
        let buildsBefore = builds.count
        let commitsBefore = rt.viewCommitCount
        let pollsBefore = rt.state.polls
        for _ in 1...100 {
            rt.update(at: t) { s, tx in
                s.messages += 1
                tx.wakeAfter(0.010)
            }
            _ = rt.hiddenWake(at: t)
            t += 0.020
            _ = rt.hiddenWake(at: t)
        }
        #expect(rt.state.messages == 100 && rt.state.read == 100)
        #expect(rt.state.polls - pollsBefore == 200)
        #expect(rt.nextWakeDeadline == nil)
        #expect(builds.count - buildsBefore == 0)
        #expect(rt.viewCommitCount - commitsBefore == 0)
        #expect(rt.isStale)

        rt.setLiveVisible(true)
        rt.settleAll()
        _ = rt.frame(at: t + 1.0 / 120.0)
        #expect(builds.count - buildsBefore == 1)
        #expect(rt.elements().first(where: { $0.key == "n" })?.text == "100 100")
    }

    @Test("window/covered_tests.rs:38 - covered window still hears queued input on hiddenWake")
    func coveredWindowStillHearsQueuedInput() {
        struct State: Equatable {
            var dropped: [String] = []
        }
        let rt = Runtime(
            state: State(),
            viewport: Vec2(200, 100),
            view: { _, _ in
                El<State>().size(200, 100)
                    .onDropFiles { s, urls, _ in
                        s.dropped.append(contentsOf: urls.map(\.lastPathComponent))
                    }
            }
        )
        _ = rt.frame(at: 0.0)
        rt.setLiveVisible(false)
        _ = rt.dropFiles([URL(fileURLWithPath: "/tmp/doc.txt")], at: Vec2(50, 50), at: 0.01)
        let built = rt.hiddenWake(at: 0.02)
        #expect(built == true)
        #expect(rt.state.dropped == ["doc.txt"])
    }

    @Test("window/covered_tests.rs:70 - covered window settles motion when it uncovers")
    func coveredWindowLandsMotionWhenUncovered() {
        struct State: Equatable {
            var expanded = false
        }
        let rt = Runtime(
            state: State(),
            viewport: Vec2(200, 100),
            view: { s, _ in
                El<State>().size(200, 100).child(
                    El<State>().key("bar")
                        .w(s.expanded ? 180 : 40)
                        .h(20)
                        .animate(.default)
                )
            }
        )
        _ = rt.frame(at: 0.0)
        rt.setLiveVisible(false)
        rt.update(at: 0.01) { s, _ in s.expanded = true }
        _ = rt.hiddenWake(at: 0.02)

        rt.setLiveVisible(true)
        rt.settleAll()
        _ = rt.frame(at: 0.03)
        let barWidth = rt.elements().first(where: { $0.key == "bar" })?.rect[2]
        #expect(barWidth == 180)
    }

    // MARK: - window/life_tests.rs (3 tests)

    @Test("window/life_tests.rs - transitions keep show/hide/cover/finish invariants")
    func windowLifeTransitions() {
        var life = WindowLife.unopened
        var stampCounter: UInt64 = 10
        let nextStamp: () -> UInt64 = {
            stampCounter += 1
            return stampCounter
        }

        #expect(!life.isShown && !life.isUncovered && !life.isCovered && !life.isFinished)
        #expect(life.cover(.system, on: true) == false)
        #expect(life == .unopened)

        #expect(life.show() == true)
        #expect(life.isShown && life.isUncovered && !life.isCovered)
        #expect(life.cover(.surface, on: true) == false)
        #expect(life.isCovered && !life.isUncovered)
        #expect(life.cover(.system, on: false) == true)
        #expect(life.isUncovered && !life.isCovered)

        life.hide(nextStamp)
        #expect(life == .hidden(at: 11))
        #expect(life.hiddenAt == 11)
        life.hide(nextStamp)
        #expect(life.hiddenAt == 11)

        #expect(life.show() == true)
        life.finish()
        #expect(life.isFinished)
        #expect(life.show() == false)
        #expect(life.isFinished)
    }

    @Test("window/life_tests.rs - closes respects keepRunning and existence")
    func windowLifeClosesPolicy() {
        #expect(WindowLife.shown(sight: .seen).closes(keepRunning: true, exists: false))
        #expect(WindowLife.hidden(at: 1).closes(keepRunning: false, exists: true))
        #expect(!WindowLife.hidden(at: 1).closes(keepRunning: true, exists: true))
        #expect(WindowLife.unopened.closes(keepRunning: false, exists: true))
        #expect(!WindowLife.unopened.closes(keepRunning: false, exists: false))
        #expect(!WindowLife.unopened.closes(keepRunning: true, exists: true))
        #expect(!WindowLife.finished.closes(keepRunning: false, exists: true))
    }

    @Test("window/life_tests.rs - WindowSight combines and supersedes surface occlusion guess")
    func windowSightCombination() {
        var s = WindowSight.seen
        s = s.step(.surface, on: true)
        #expect(s.isCovered)
        s = s.step(.system, on: false)
        #expect(s == .seen)
        s = s.step(.windows, on: true).step(.surface, on: true).step(.windows, on: false)
        #expect(s == .seen)
        s = s.step(.system, on: true).step(.windows, on: true).step(.system, on: false)
        #expect(s.isCovered)
    }

    // MARK: - window/reveal_tests.rs (7 tests)

    @Test("window/reveal_tests.rs - Reveal effects for missing, hidden, shown, minimized, and cached")
    func windowRevealEffects() {
        #expect(WindowReveal.show.effects(found: .missing) == [.readSystem, .create])
        #expect(WindowReveal.open.effects(found: .missing) == [.readSystem, .create])
        #expect(WindowReveal.cached.effects(found: .missing) == [])

        #expect(WindowReveal.show.effects(found: .hidden(minimized: false), isMacOS: true) == [
            .readSystem, .build, .place, .orderIn(focus: false), .settle, .shown(live: true), .cancelTimerFrame, .number, .redraw,
        ])
        #expect(WindowReveal.show.effects(found: .hidden(minimized: true), isMacOS: false) == [
            .readSystem, .build, .place, .orderIn(focus: false), .settle, .shown(live: false), .cancelTimerFrame, .number, .redraw,
        ])
        #expect(WindowReveal.open.effects(found: .hidden(minimized: true), isMacOS: false) == [
            .readSystem, .build, .place, .orderIn(focus: false), .unminimize, .settle, .shown(live: true), .cancelTimerFrame, .number, .focus, .redraw,
        ])
        #expect(WindowReveal.show.effects(found: .shown(covered: true, minimized: false), isMacOS: true) == [
            .readSystem, .place, .settle, .shown(live: true), .cancelTimerFrame, .number, .redraw,
        ])
        #expect(WindowReveal.open.effects(found: .shown(covered: false, minimized: false), isMacOS: true) == [
            .readSystem, .place, .shown(live: true), .cancelTimerFrame, .number, .focus, .redraw,
        ])
        #expect(WindowReveal.cached.effects(found: .hidden(minimized: false)) == [
            .orderIn(focus: true), .shown(live: true), .cancelTimerFrame, .number, .redrawIfMoving,
        ])
    }

    // MARK: - window/wake_tests.rs (6 tests)

    @Test("window/wake_tests.rs - WakeWork exhaustive truth table and lazy minimized probe")
    func wakeWorkTruthTable() {
        for window in [false, true] {
            for launcher in [false, true] {
                for visible in [false, true] {
                    for wasShown in [false, true] {
                        for changed in [false, true] {
                            for quiet in [false, true] {
                                for covered in [false, true] {
                                    for minimized in [false, true] {
                                        var probed = false
                                        let got = WakeWork.of(
                                            WakeFacts(
                                                window: window,
                                                launcher: launcher,
                                                visible: visible,
                                                wasShown: wasShown,
                                                changed: changed,
                                                quiet: quiet,
                                                covered: covered
                                            ),
                                            minimized: {
                                                probed = true
                                                return minimized
                                            }
                                        )
                                        if !window {
                                            #expect(got == .nothing && !probed)
                                        } else if launcher && !visible {
                                            #expect(got == (changed ? .hiddenFrame : .nothing) && !probed)
                                        } else if quiet {
                                            #expect(got == .nothing && !probed)
                                        } else {
                                            let asked = launcher ? (changed || (wasShown && visible)) : visible
                                            if !asked {
                                                #expect(got == .nothing && !probed)
                                            } else if !launcher && covered {
                                                #expect(got == .coveredFrame && !probed)
                                            } else {
                                                #expect(probed)
                                                #expect(got == (minimized ? .coveredFrame : .paint))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("window/wake_tests.rs - WindowMinimize state machine and HiddenPoll")
    func windowMinimizeAndHiddenPoll() {
        let rt = Runtime(state: 0, viewport: Vec2(100, 100)) { _, _ in El<Int>().size(100, 100) }
        #expect(!rt.minimizeState.latched && !rt.minimizeState.field)

        #expect(!rt.minimizeStep(.asked))
        #expect(rt.minimizeState == .asked && rt.minimizeState.field && rt.minimizeState.latched)

        // HiddenPoll holds minimize ask across show turn's shell, letting fresh asks inside shell run first.
        let poll = WindowHiddenPoll(shows: true)
        poll.enter(rt)
        #expect(rt.minimizeState == .held(field: false) && !rt.minimizeState.field && rt.minimizeState.latched)
        #expect(!rt.shellTakeMinimize())
        #expect(!rt.minimizeStep(.asked))
        #expect(rt.shellTakeMinimize() == true)
        #expect(rt.minimizeState == .held(field: false))

        poll.leave(rt)
        #expect(rt.minimizeState == .asked)
        #expect(rt.shellTakeMinimize() == true)
        #expect(rt.minimizeState == .none)

        // Lost clears queued minimize.
        _ = rt.minimizeStep(.asked)
        _ = rt.minimizeStep(.lost)
        #expect(rt.minimizeState == .none)

        // Double heldForShow without field transitions to .none.
        _ = rt.minimizeStep(.asked)
        _ = rt.minimizeStep(.heldForShow)
        _ = rt.minimizeStep(.heldForShow)
        #expect(rt.minimizeState == .none)
    }

    // MARK: - window/backoff_tests.rs (8 tests)

    @Test("window/backoff_tests.rs - occluded, timeout, outdated, hiddenMissed, and reset transitions")
    func backoffTransitionsParity() {
        let t0 = 10.0
        var b = WindowBackoff()
        #expect(b.deadline == nil && !b.waiting(now: t0))

        let fx1 = b.step(.missed(.occluded, paced: false, now: t0))
        #expect(fx1 == [.stopPacing])
        #expect(b.deadline == t0 + WindowPacingConstants.occludedRetry)
        #expect(b.waiting(now: t0) && !b.waiting(now: t0 + WindowPacingConstants.occludedRetry))

        _ = b.step(.missed(.occluded, paced: false, now: t0))
        #expect(b.deadline == t0 + WindowPacingConstants.occludedRetry * 2.0)

        // Paced timeout sleeps without stopPacing; unpaced waits ~1 frame.
        #expect(b.step(.missed(.timeout, paced: true, now: t0)).isEmpty)
        #expect(b.deadline == nil)
        #expect(b.step(.missed(.timeout, paced: false, now: t0)) == [.stopPacing])
        #expect(b.deadline == t0 + WindowPacingConstants.timeoutRetry)

        // Outdated waits occludedRetry without resetting occluded backoff; lapsed keeps backoff.
        _ = b.step(.missed(.outdated, paced: false, now: t0))
        #expect(b.deadline == t0 + WindowPacingConstants.occludedRetry)
        _ = b.step(.lapsed)
        #expect(b.deadline == nil)
        _ = b.step(.missed(.occluded, paced: false, now: t0))
        #expect(b.deadline == t0 + WindowPacingConstants.occludedRetry * 4.0)

        // HiddenMissed respects preparing flag, doubles hidden, and uncovered keeps hidden backoff.
        var h = WindowBackoff.seeded(
            occluded: WindowPacingConstants.occludedRetry * 4.0,
            hidden: WindowPacingConstants.timeoutRetry * 4.0
        )
        _ = h.step(.hiddenMissed(preparing: true, now: t0))
        #expect(h.deadline == nil)
        _ = h.step(.hiddenMissed(preparing: false, now: t0))
        #expect(h.deadline == t0 + WindowPacingConstants.timeoutRetry * 4.0)
        _ = h.step(.uncovered)
        #expect(h.deadline == nil)
        _ = h.step(.missed(.occluded, paced: false, now: t0))
        #expect(h.deadline == t0 + WindowPacingConstants.occludedRetry)
        _ = h.step(.hiddenMissed(preparing: false, now: t0))
        #expect(h.deadline == t0 + WindowPacingConstants.timeoutRetry * 8.0)

        // Presented resets both occluded and hidden.
        _ = h.step(.presented)
        #expect(h.deadline == nil)
        _ = h.step(.hiddenMissed(preparing: false, now: t0))
        #expect(h.deadline == t0 + WindowPacingConstants.timeoutRetry)
        _ = h.step(.missed(.occluded, paced: false, now: t0))
        #expect(h.deadline == t0 + WindowPacingConstants.occludedRetry)
    }

    @Test("window/backoff_tests.rs - seeded clamping and WindowTimerFrame stall/quiet bounds")
    func backoffSeedClampingAndTimerFrame() {
        var zeroSeed = WindowBackoff.seeded(occluded: 0, hidden: WindowPacingConstants.timeoutRetry)
        _ = zeroSeed.step(.missed(.occluded, paced: false, now: 1.0))
        #expect(zeroSeed.deadline == 1.0 + WindowPacingConstants.occludedRetry)

        var maxSeed = WindowBackoff.seeded(occluded: 60.0, hidden: WindowPacingConstants.timeoutRetry)
        _ = maxSeed.step(.missed(.occluded, paced: false, now: 1.0))
        #expect(maxSeed.deadline == 1.0 + WindowPacingConstants.occludedMax)

        var tf = WindowTimerFrame()
        #expect(!tf.isQuiet && !tf.stalled(now: 1.0))
        tf.askedQuiet(now: 1.0)
        #expect(tf.isQuiet && !tf.stalled(now: 1.1))
        #expect(tf.wait(due: 0.5, now: 1.0) == 1.0 + WindowPacingConstants.timerFrameStall)
        #expect(tf.stalled(now: 1.0 + WindowPacingConstants.timerFrameStall))

        tf.stalledAgain(now: 1.5)
        #expect(!tf.stalled(now: 1.6))
        tf.noLongerQuiet()
        #expect(tf.takeQuiet() == false)
        tf.drawn()
        #expect(tf.wait(due: 0.5, now: 1.0) == 0.5)
    }

    // MARK: - window/native_tests.rs (L28)

    @Test("window/native_tests.rs:3 - a new window presumes itself shown for two frames or until stopped")
    func aNewWindowPresumesItselfShownForTwoFramesOrUntilStopped() {
        var prime = WindowPrime.launching()
        #expect(prime.presumes)
        prime.spend()
        #expect(prime.presumes)
        prime.spend()
        #expect(prime == .steady)
        prime.spend()
        #expect(prime == .steady)

        var stopped = WindowPrime.launching()
        stopped.stop()
        #expect(!stopped.presumes)
    }

    // MARK: - window/win.rs WindowFirstFrame (L30)

    @Test("window/win.rs:134 - launcher first frame holds reveal and hide cancels late completion")
    func launcherFirstFrameHoldsRevealAndHideCancelsLateCompletion() {
        let now = 10.0
        var frame = WindowFirstFrame()
        frame.prepare(now: now)
        let r1 = frame.requestReveal(stale: false, visible: false, now: now)
        #expect(!r1)
        #expect(!frame.ready)
        let c1 = frame.complete()
        #expect(c1)
        #expect(frame.ready && frame.deadline == nil)
        let c2 = frame.complete()
        #expect(!c2)

        var canceled = WindowFirstFrame()
        canceled.prepare(now: now)
        let cr1 = canceled.requestReveal(stale: false, visible: false, now: now)
        #expect(!cr1)
        canceled.hide()
        let cc1 = canceled.complete()
        #expect(!cc1)
        #expect(canceled.ready)
        let cr2 = canceled.requestReveal(stale: false, visible: false, now: now)
        #expect(cr2)
        #expect(canceled.deadline == nil)
    }

    @Test("window/win.rs:154 - launcher stale reveal waits for an unsettled hidden frame")
    func launcherStaleRevealWaitsForUnsettledHiddenFrame() {
        let now = 10.0
        var frame = WindowFirstFrame.drawnNotified()
        let c0 = frame.complete()
        #expect(!c0)
        let r1 = frame.requestReveal(stale: false, visible: false, now: now)
        #expect(r1)
        #expect(!frame.pending && frame.settles)
        let r2 = frame.requestReveal(stale: true, visible: false, now: now)
        #expect(!r2)
        #expect(frame.deadline != nil && !frame.settles)
        frame.gpuDone()
        let pendingBefore = frame.pending
        let c1 = frame.complete()
        #expect(pendingBefore && c1)
        #expect(!frame.pending && frame.settles)
        let r3 = frame.requestReveal(stale: true, visible: false, now: now)
        #expect(!r3)
        frame.hide()
        #expect(frame.settles)
        #expect(frame.ready && frame.deadline == nil)
        let c2 = frame.complete()
        #expect(!frame.pending && !c2)

        let r4 = frame.requestReveal(stale: true, visible: false, now: now)
        #expect(!r4)
        let e1 = frame.expire()
        #expect(e1)
        #expect(frame.ready && !frame.pending && frame.deadline == nil)

        var first = WindowFirstFrame()
        first.prepare(now: now)
        let fr1 = first.requestReveal(stale: true, visible: false, now: now)
        #expect(!fr1)
        let fe1 = first.expire()
        #expect(!fe1 && !first.ready)
        first.gpuDone()
        let fp = first.pending
        let fc1 = first.complete()
        #expect(fp && fc1)
    }

    @Test("window/win.rs:183 - launcher refresh with no drawable retries and never reveals stale pixels")
    func launcherRefreshWithNoDrawableRetriesAndNeverRevealsStalePixels() {
        let now = 10.0
        var frame = WindowFirstFrame.drawnNotified()
        var backoff = WindowBackoff()
        func missed(_ frame: inout WindowFirstFrame, _ backoff: inout WindowBackoff) -> Double? {
            frame.missed()
            _ = backoff.step(.hiddenMissed(preparing: frame.deadline != nil, now: now))
            return backoff.deadline
        }
        #expect(missed(&frame, &backoff) == now + WindowPacingConstants.timeoutRetry)
        #expect(!frame.ready)
        #expect(missed(&frame, &backoff) == now + WindowPacingConstants.timeoutRetry * 2.0)
        for _ in 0..<10 {
            _ = missed(&frame, &backoff)
        }
        #expect(backoff.deadline == now + WindowPacingConstants.occludedMax)
        let r1 = frame.requestReveal(stale: false, visible: false, now: now)
        #expect(!r1)
        #expect(frame.deadline != nil)
        #expect(missed(&frame, &backoff) == nil)

        var shown = WindowFirstFrame.drawnNotified()
        let sr1 = shown.requestReveal(stale: true, visible: true, now: now)
        #expect(sr1)
        #expect(shown.deadline == nil && shown.ready)
    }

    @Test("window/win.rs:349 - on_ready runs for a window launched occluded or hidden")
    func onReadyRunsForWindowLaunchedOccludedOrHidden() {
        let now = 10.0
        var shown = WindowFirstFrame.opened(at: now)
        #expect(!shown.readyDue(at: now + 0.016))
        shown.gpuDone()
        let sp = shown.pending
        let sc = shown.complete()
        #expect(sp && !sc)
        let st1 = shown.takeReady()
        #expect(st1)
        let st2 = shown.takeReady()
        #expect(!st2 && shown.readyDeadline == nil)

        var covered = WindowFirstFrame.opened(at: now)
        covered.skipped(at: now + 0.030)
        let cdue = covered.readyDue(at: now + 0.030)
        let ct1 = covered.takeReady()
        #expect(cdue && ct1)
        #expect(!covered.ready && !covered.pending)
        covered.skipped(at: now + 0.060)
        #expect(covered.readyDeadline == nil)
        covered.gpuDone()
        let cp = covered.pending
        let cc = covered.complete()
        let ct2 = covered.takeReady()
        #expect(cp && !cc && !ct2)

        var hidden = WindowFirstFrame.opened(at: now)
        #expect(hidden.readyDeadline == now + WindowPacingConstants.readyFallback)
        #expect(!hidden.readyDue(at: now + WindowPacingConstants.readyFallback - 0.001))
        let hdue = hidden.readyDue(at: now + WindowPacingConstants.readyFallback)
        let ht = hidden.takeReady()
        #expect(hdue && ht)
    }

    // MARK: - window/wake_tests.rs:131 + window/backoff_tests.rs:254 (L29)

    @Test("window/wake_tests.rs:131 - a shell minimizes once exactly where dev did for every sequence")
    func aShellMinimizesOnceExactlyWhereDevDidForEverySequence() {
        enum Op: CaseIterable {
            case asked, pollEnter, taken, pollReturn, lost
        }
        struct DevMinimize {
            var latch = false
            var saved: Bool? = nil

            mutating func apply(_ op: Op) -> Bool {
                switch op {
                case .asked:
                    latch = true
                    return false
                case .pollEnter:
                    saved = latch
                    latch = false
                    return false
                case .taken:
                    let v = latch
                    latch = false
                    return v
                case .pollReturn:
                    let s = saved ?? false
                    saved = nil
                    latch = latch || s
                    return false
                case .lost:
                    latch = false
                    return false
                }
            }

            var latched: Bool { latch || (saved ?? false) }
            var field: Bool { latch }
        }

        func applyMinimize(_ state: inout WindowMinimize, _ op: Op) -> Bool {
            let event: MinimizeEvent = switch op {
            case .asked: .asked
            case .pollEnter: .heldForShow
            case .taken: .taken
            case .pollReturn: .returned
            case .lost: .lost
            }
            return WindowMinimize.step(&state, event: event).contains(.minimize)
        }

        func walk(seq: inout [Op], max: Int, cases: inout Int) {
            cases += 1
            var dev = DevMinimize()
            var state = WindowMinimize.none
            for op in seq {
                let actual = applyMinimize(&state, op)
                let expected = dev.apply(op)
                #expect(actual == expected)
                #expect(state.latched == dev.latched)
                #expect(state.field == dev.field)
            }
            guard seq.count < max else { return }
            for op in Op.allCases {
                let ok: Bool = switch op {
                case .pollEnter: dev.saved == nil
                case .pollReturn: dev.saved != nil
                default: true
                }
                if ok {
                    seq.append(op)
                    walk(seq: &seq, max: max, cases: &cases)
                    seq.removeLast()
                }
            }
        }

        var seq: [Op] = []
        var cases = 0
        walk(seq: &seq, max: 6, cases: &cases)
        #expect(cases == 5461)
    }

    @Test("window/backoff_tests.rs:254 - every order of events leaves the same deadline and waits")
    func everyOrderOfEventsLeavesSameDeadlineAndWaits() {
        enum Step {
            case occluded, timeout, pacedTimeout, outdated, unconfigured
            case hidden, hiddenPreparing, at, lapsed, uncovered, present
            case timerAsk, timerStallAgain, timerDrawn, quietCleared, takeQuiet
        }

        func refRetry(_ missed: WindowMissed, paced: Bool, now: Double, occludedWait: inout Double) -> Double? {
            switch missed {
            case .occluded:
                let clamped = min(max(occludedWait, WindowPacingConstants.occludedRetry), WindowPacingConstants.occludedMax)
                let at = now + clamped
                occludedWait = min(occludedWait * 2.0, WindowPacingConstants.occludedMax)
                return at
            case .timeout where paced:
                return nil
            case .timeout:
                return now + WindowPacingConstants.timeoutRetry
            case .outdated, .unconfigured:
                return now + WindowPacingConstants.occludedRetry
            }
        }

        struct Apart {
            var retry: Double? = nil
            var occluded: Double = WindowPacingConstants.occludedRetry
            var hidden: Double = WindowPacingConstants.timeoutRetry
            var quiet: Bool = false
            var owed: Double? = nil

            mutating func step(_ s: Step, now: Double) {
                switch s {
                case .occluded: retry = refRetry(.occluded, paced: false, now: now, occludedWait: &occluded)
                case .timeout: retry = refRetry(.timeout, paced: false, now: now, occludedWait: &occluded)
                case .pacedTimeout: retry = refRetry(.timeout, paced: true, now: now, occludedWait: &occluded)
                case .outdated: retry = refRetry(.outdated, paced: false, now: now, occludedWait: &occluded)
                case .unconfigured: retry = refRetry(.unconfigured, paced: false, now: now, occludedWait: &occluded)
                case .hidden:
                    retry = now + hidden
                    hidden = min(hidden * 2.0, WindowPacingConstants.occludedMax)
                case .hiddenPreparing:
                    retry = nil
                case .at:
                    retry = now + WindowPacingConstants.timerFrame
                case .lapsed:
                    retry = nil
                case .uncovered:
                    retry = nil
                    occluded = WindowPacingConstants.occludedRetry
                case .present:
                    retry = nil
                    occluded = WindowPacingConstants.occludedRetry
                    hidden = WindowPacingConstants.timeoutRetry
                case .timerAsk:
                    if owed == nil { owed = now }
                    quiet = true
                case .timerStallAgain:
                    owed = now
                case .timerDrawn:
                    owed = nil
                case .quietCleared, .takeQuiet:
                    quiet = false
                }
            }
        }

        func holdsUp(_ seq: [Step]) {
            let t0 = 100.0
            var backoff = WindowBackoff()
            var frame = WindowTimerFrame()
            var apart = Apart()
            for (k, s) in seq.enumerated() {
                let now = t0 + 0.011 * Double(k)
                switch s {
                case .occluded: _ = backoff.step(.missed(.occluded, paced: false, now: now))
                case .timeout: _ = backoff.step(.missed(.timeout, paced: false, now: now))
                case .pacedTimeout: _ = backoff.step(.missed(.timeout, paced: true, now: now))
                case .outdated: _ = backoff.step(.missed(.outdated, paced: false, now: now))
                case .unconfigured: _ = backoff.step(.missed(.unconfigured, paced: false, now: now))
                case .hidden: _ = backoff.step(.hiddenMissed(preparing: false, now: now))
                case .hiddenPreparing: _ = backoff.step(.hiddenMissed(preparing: true, now: now))
                case .at: _ = backoff.step(.at(now + WindowPacingConstants.timerFrame))
                case .lapsed: _ = backoff.step(.lapsed)
                case .uncovered: _ = backoff.step(.uncovered)
                case .present:
                    _ = backoff.step(.lapsed)
                    _ = backoff.step(.presented)
                case .timerAsk: frame.askedQuiet(now: now)
                case .timerStallAgain: frame.stalledAgain(now: now)
                case .timerDrawn: frame.drawn()
                case .quietCleared: frame.noLongerQuiet()
                case .takeQuiet: _ = frame.takeQuiet()
                }
                apart.step(s, now: now)
                #expect(backoff.deadline == apart.retry)
                #expect(backoff.waiting(now: now) == (apart.retry.map { $0 > now } ?? false))

                var missed = backoff
                _ = missed.step(.missed(.occluded, paced: false, now: now))
                var wait = apart.occluded
                #expect(missed.deadline == refRetry(.occluded, paced: false, now: now, occludedWait: &wait))

                var hidden = backoff
                _ = hidden.step(.hiddenMissed(preparing: false, now: now))
                #expect(hidden.deadline == now + apart.hidden)

                #expect(frame.isQuiet == apart.quiet)
                #expect(frame.stalled(now: now) == (apart.owed.map { now >= $0 + WindowPacingConstants.timerFrameStall } ?? false))
                #expect(frame.wait(due: now, now: now) == (apart.owed.map { $0 + WindowPacingConstants.timerFrameStall } ?? now))
            }
        }

        func everySequence(_ alphabet: [Step], max: Int) {
            var seq: [Step] = []
            func walk() {
                holdsUp(seq)
                guard seq.count < max else { return }
                for s in alphabet {
                    seq.append(s)
                    walk()
                    seq.removeLast()
                }
            }
            walk()
        }

        let all: [Step] = [
            .occluded, .timeout, .pacedTimeout, .outdated, .unconfigured,
            .hidden, .hiddenPreparing, .at, .lapsed, .uncovered, .present,
            .timerAsk, .timerStallAgain, .timerDrawn, .quietCleared, .takeQuiet,
        ]
        everySequence(all, max: 3)
        let common: [Step] = [
            .occluded, .unconfigured, .hidden, .present, .uncovered,
            .timerAsk, .timerStallAgain, .quietCleared, .takeQuiet,
        ]
        everySequence(common, max: 6)
    }
}
