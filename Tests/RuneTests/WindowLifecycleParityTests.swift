import Foundation
import Testing
@testable import Rune
import RuneMotion

@Suite("Window Lifecycle Parity (covered, life, reveal, wake, backoff)")
struct WindowLifecycleParityTests {

    // MARK: - window/covered_tests.rs (3 tests)

    @Test("window/covered_tests.rs:1 - covered window builds nothing until it uncovers")
    func coveredWindowBuildsNothingUntilUncovered() {
        struct State: Equatable {
            var count = 0
            var polls = 0
        }
        final class Builds: @unchecked Sendable { var count = 0 }
        let builds = Builds()
        let rt = Runtime(
            state: State(),
            viewport: Vec2(200, 100),
            view: { s, _ in
                builds.count += 1
                return El<State>().size(200, 100).child(text("\(s.count)"))
            }
        )
        rt.poll = { s, _, _ in
            s.polls += 1
            s.count += 1
            return true
        }

        _ = rt.frame(at: 0.0)
        #expect(builds.count == 1)

        rt.setLiveVisible(false)
        rt.update(at: 0.01) { s, _ in s.count += 1 }
        let invalidated = rt.hiddenWake(at: 0.02)
        #expect(invalidated == true)
        #expect(builds.count == 1)
        #expect(rt.state.polls >= 1)

        rt.setLiveVisible(true)
        _ = rt.frame(at: 0.03)
        #expect(builds.count == 2)
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
}
