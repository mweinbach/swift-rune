import Testing
@testable import Rune

@Suite("r375 onHoverChange and HoverDelays Parity")
struct HoverDelayParityTests {
    private let enterDelay: Float = 0.5
    private let leaveDelay: Float = 0.25

    private func settle(_ state: inout DelayedHoverPhase?, inside: Bool, now: Double) -> [HoverDelayEffect] {
        stepHoverDelayState(
            &state,
            event: .settle(inside: inside, mayEnter: true, enterDelay: enterDelay, leaveDelay: leaveDelay, now: now)
        )
    }

    private func due(_ state: inout DelayedHoverPhase?, now: Double) -> [HoverDelayEffect] {
        stepHoverDelayState(&state, event: .due(now: now))
    }

    @Test("1. enter waits out delay then reports")
    func enterWaitsThenReports() {
        var s: DelayedHoverPhase? = nil
        #expect(settle(&s, inside: true, now: 1.0) == [.wakeAt(1.5)])
        #expect(settle(&s, inside: true, now: 1.2).isEmpty)
        #expect(due(&s, now: 1.4).isEmpty)
        #expect(due(&s, now: 1.5) == [.report(true)])
        #expect(s == .shown)
    }

    @Test("2. leaving before enter is due reports nothing and stale wake is ignored")
    func leavingBeforeEnterCancels() {
        var s: DelayedHoverPhase? = nil
        _ = settle(&s, inside: true, now: 1.0)
        #expect(settle(&s, inside: false, now: 1.1).isEmpty)
        #expect(s == nil)
        #expect(settle(&s, inside: true, now: 1.3) == [.wakeAt(1.8)])
        #expect(due(&s, now: 1.5).isEmpty)
        #expect(s == .enterDue(due: 1.8))
    }

    @Test("3. shown hover leaves after exit delay unless pointer returns")
    func shownHoverLeavesAfterExitDelay() {
        var s: DelayedHoverPhase? = .shown
        #expect(settle(&s, inside: false, now: 2.0) == [.wakeAt(2.25)])
        #expect(settle(&s, inside: true, now: 2.1).isEmpty)
        #expect(s == .shown)
        #expect(due(&s, now: 2.25).isEmpty)
        _ = settle(&s, inside: false, now: 3.0)
        #expect(due(&s, now: 3.25) == [.report(false)])
        #expect(s == nil)
    }

    @Test("4. zero delays report at once")
    func zeroDelaysReportAtOnce() {
        var s: DelayedHoverPhase? = nil
        let effects = stepHoverDelayState(
            &s,
            event: .settle(inside: true, mayEnter: true, enterDelay: 0, leaveDelay: 0, now: 0)
        )
        #expect(effects == [.report(true)])
        #expect(s == .shown)
    }

    @Test("5. press or blur keeps enter from starting but not shown hover from staying")
    func pressOrBlurPreventsEnterNotShown() {
        var s: DelayedHoverPhase? = nil
        #expect(stepHoverDelayState(
            &s,
            event: .settle(inside: true, mayEnter: false, enterDelay: enterDelay, leaveDelay: leaveDelay, now: 0)
        ).isEmpty)
        #expect(s == nil)

        var shown: DelayedHoverPhase? = .shown
        #expect(stepHoverDelayState(
            &shown,
            event: .settle(inside: true, mayEnter: false, enterDelay: enterDelay, leaveDelay: leaveDelay, now: 0)
        ).isEmpty)
        #expect(shown == .shown)
    }

    @Test("6. press stops enter wait but not leave wait")
    func pressStopsEnterNotLeave() {
        var entering: DelayedHoverPhase? = .enterDue(due: 1.0)
        stepHoverDelayState(&entering, event: .pressed)
        #expect(entering == nil)

        var leaving: DelayedHoverPhase? = .leaveDue(due: 1.0)
        stepHoverDelayState(&leaving, event: .pressed)
        #expect(leaving == .leaveDue(due: 1.0))
    }

    @Test("7. ending reports leave only when hover had heard enter")
    func endingReportsOnlyIfShown() {
        let cases: [(DelayedHoverPhase?, Bool)] = [
            (.shown, true),
            (.leaveDue(due: 1.0), true),
            (.enterDue(due: 1.0), false),
            (nil, false),
        ]
        for (from, heard) in cases {
            var s = from
            let effects = stepHoverDelayState(&s, event: .ended)
            #expect(effects == (heard ? [.report(false)] : []))
            #expect(s == nil)
        }
    }

    @Test("8. list reports waits in start order and forget reports prior enter")
    func listPreservesStartOrderAndForget() {
        var list = HoverDelays()
        _ = list.step("a", event: .settle(inside: true, mayEnter: true, enterDelay: 0, leaveDelay: 0, now: 0))
        _ = list.step("b", event: .settle(inside: true, mayEnter: true, enterDelay: enterDelay, leaveDelay: leaveDelay, now: 0))
        // `a` starts leave after `b` started enter.
        _ = list.step("a", event: .settle(inside: false, mayEnter: true, enterDelay: 0.5, leaveDelay: 0.5, now: 0))
        #expect(list.paths == ["b", "a"])
        #expect(list.waiting)
        let forgotA = list.forget("a")
        let forgotB = list.forget("b")
        #expect(forgotA)
        #expect(!forgotB)
        #expect(list.isEmpty && !list.waiting)
    }

    @Test("Overlapping hover observers enter and leave in paint order", arguments: [false, true])
    @MainActor
    func overlappingObservers(renderFrame: Bool) {
        let rt = Runtime<[String]>(state: [], viewport: Vec2(100, 100)) { _, _ in
            func observer(_ name: String) -> El<[String]> {
                el().key(name).size(40, 40).pin(top: 0, left: 0).bg(.white)
                    .onHoverChange { state, inside, tx in
                        state.append(name + (inside ? " in" : " out"))
                        tx.liveOnly()
                    }
            }
            return col().size(100, 100).child(observer("raised").raise()).child(observer("back"))
        }
        func frame(_ t: Double) {
            if renderFrame { _ = rt.renderFrame(at: t) } else { _ = rt.frame(at: t) }
        }
        frame(0)
        rt.pointerMove(to: Vec2(10, 10), at: 0.01)
        frame(0.02)
        rt.pointerMove(to: Vec2(80, 80), at: 0.03)
        frame(0.04)
        #expect(rt.state == ["back in", "raised in", "back out", "raised out"])
    }

    @Test("Pruning through a memo geometry settle uses the last delivered focus and hover tree", arguments: [false, true])
    @MainActor
    func prunedObserversAndFocusAcrossSettle(native: Bool) {
        struct Model {
            var open = true
            var log: [String] = []
        }
        let rt = Runtime(state: Model(), viewport: Vec2(100, 100)) { state, _ in
            func observer(_ name: String) -> El<Model> {
                el().key(name).size(40, 40).pin(top: 0, left: 0).bg(.white)
                    .onHoverChange { state, inside, tx in
                        state.log.append(name + (inside ? " in" : " out"))
                        tx.liveOnly()
                    }
            }
            let read: El<Model> = memo("read", deps: 0) {
                _ = layoutRect("sizer")
                return el().size(1, 1)
            }
            var root: El<Model> = col().size(100, 100).child(el().key("sizer").size(state.open ? 10 : 20, 10))
            if state.open {
                root = root.child(observer("raised").raise().focusable().autofocus()).child(observer("back"))
            }
            return root.child(el().key("next").size(20, 10).focusable()).child(read)
        }
        func frame(_ t: Double) {
            if native { _ = rt.renderFrame(at: t) } else { _ = rt.frame(at: t) }
        }
        frame(0)
        #expect(rt.focusedKey == "raised")
        rt.pointerMove(to: Vec2(5, 5), at: 0.01)
        frame(0.02)
        #expect(rt.state.log == ["back in", "raised in"])
        let priorCommits = rt.viewCommitCount
        rt.update(at: 0.03) { state, _ in state.open = false }
        frame(0.04)
        #expect(rt.viewCommitCount >= priorCommits + 2)
        #expect(rt.state.log == ["back in", "raised in", "raised out", "back out"])
        #expect(rt.focusedKey == "next")
    }

    @Test("Runtime: onHoverChange descendants, chainHoverChangeAny, delayed hover wakes, pruning & blur")
    func runtimeOnHoverChangeAndDelays() {
        struct S {
            var log: [Bool] = []
            var chained: [Bool] = []
            var delayedLog: [Bool] = []
            var showDelayed = true
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 200)) { s, _ in
            var root = col().w(300).h(200)
                .child(
                    col().key("panel").size(120, 80)
                        .onHoverChange { st, inside, _ in st.log.append(inside) }
                        .chainHoverChangeAny { inside, tx in
                            // keep liveOnly test implicit by recording via callback below or verify order
                            _ = tx
                            _ = inside
                        }
                        .child(El<S>().key("btn").size(60, 40).onClick { _, _ in })
                )
            if s.showDelayed {
                root = root.child(
                    el().key("peek").size(80, 60)
                        .onHoverChange { st, inside, _ in st.delayedLog.append(inside) }
                        .hoverDelays(0.2, 0.1)
                )
            }
            return root
        }
        _ = rt.frame(at: 0.0)

        // Move inside panel then onto child button: moving onto child must NOT fire leave!
        rt.pointerMove(to: Vec2(90, 20), at: 0.01)
        #expect(rt.state.log == [true])
        rt.pointerMove(to: Vec2(20, 20), at: 0.02)
        #expect(rt.state.log == [true])
        rt.pointerMove(to: Vec2(200, 20), at: 0.03)
        #expect(rt.state.log == [true, false])

        // Verify delayed element: enter wait sets wake deadline, fires after 0.2s, leave waits 0.1s
        rt.pointerMove(to: Vec2(20, 100), at: 1.0)
        #expect(rt.state.delayedLog.isEmpty)
        let dueEnter = rt.nextWakeDeadline(after: 1.0)
        #expect(dueEnter != nil && abs((dueEnter ?? 0) - 1.2) < 1e-4)
        _ = rt.frame(at: 1.15)
        #expect(rt.state.delayedLog.isEmpty)
        _ = rt.frame(at: 1.2)
        #expect(rt.state.delayedLog == [true])

        // Moving out starts 0.1s exit delay
        rt.pointerMove(to: Vec2(250, 100), at: 2.0)
        #expect(rt.state.delayedLog == [true])
        let dueLeave = rt.nextWakeDeadline(after: 2.0)
        #expect(dueLeave != nil && abs((dueLeave ?? 0) - 2.1) < 1e-4)
        _ = rt.frame(at: 2.1)
        #expect(rt.state.delayedLog == [true, false])

        // Shown hover + blur ends immediately; next move restarts wait even if unfocused
        rt.pointerMove(to: Vec2(20, 100), at: 3.0)
        _ = rt.frame(at: 3.2)
        #expect(rt.state.delayedLog == [true, false, true])
        rt.dispatchFocus(false, at: 3.3)
        #expect(rt.state.delayedLog == [true, false, true, false])

        // Move while unfocused starts a new enter wait; pruning after shown reports leave
        rt.pointerMove(to: Vec2(21, 100), at: 4.0)
        _ = rt.frame(at: 4.2)
        #expect(rt.state.delayedLog == [true, false, true, false, true])
        rt.update(at: 4.3) { s, _ in s.showDelayed = false }
        _ = rt.frame(at: 4.31)
        #expect(rt.state.delayedLog == [true, false, true, false, true, false])

        // chainHoverChangeAny preserves liveOnlyRequested only when both request liveOnly
        struct ChainState { var a: [Bool] = []; var b = 0 }
        let rtChain = Runtime<ChainState>(state: ChainState(), viewport: Vec2(100, 100)) { _, _ in
            el().key("c").size(50, 50)
                .onHoverChange { s, inside, tx in s.a.append(inside); tx.liveOnly() }
                .chainHoverChangeAny { inside, tx in if inside { tx.liveOnly() } }
        }
        _ = rtChain.frame(at: 0.0)
        rtChain.pointerMove(to: Vec2(10, 10), at: 0.1)
        #expect(rtChain.state.a == [true])
        #expect(rtChain.viewCommitCount == 1)
    }
}
