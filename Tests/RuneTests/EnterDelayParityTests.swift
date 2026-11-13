import Testing
@testable import Rune
@testable import RuneMotion

@Suite("crates/rune/tests/enter_delay.rs parity")
struct EnterDelayParityTests {
    private static let rise: Float = 12.0
    private static let hz: Double = 120.0

    private struct S {
        var rows: Int = 0
        var delay: Float = 0.0
        var ownScale: Float = 0.0
        var windowScale: Float = 0.0
    }

    private func makeApp(_ s: S) -> Runtime<S> {
        let rt = Runtime<S>(state: s, viewport: Vec2(200, 200)) { state, cx in
            if state.windowScale > 0.0 {
                cx.timeScale(state.windowScale)
            }
            let stagger = Stagger(gap: state.delay).start(state.delay)
            let rows: [El<S>] = (0..<state.rows).map { i in
                var row: El<S> = el()
                    .key("row\(i)")
                    .w(100)
                    .h(20)
                    .bg(.black)
                    .transition(Transition.offset(x: 0, y: Self.rise).combined(with: .opacity))
                    .enterDelay(stagger.delay(index: i, count: state.rows))
                if state.ownScale > 0.0 {
                    row = row.timeScale(state.ownScale)
                }
                return row
            }
            return col().wFull().hFull().children(rows)
        }
        _ = rt.frame(at: 0.0)
        return rt
    }

    private func rowProgress(_ rt: Runtime<S>, _ i: Int) -> (offset: Float, opacity: Float)? {
        guard let e = rt.element(byKey: "row\(i)") else { return nil }
        return (1.0 - (e.rect[1] - e.target[1]) / Self.rise, e.opacity)
    }

    @Test("waits_whole_then_moves_offset_and_opacity_in_lockstep")
    func waitsWholeThenMovesOffsetAndOpacityInLockstep() {
        let rt = makeApp(S(delay: 0.2))
        rt.update(at: 0.0) { s, _ in s.rows = 1 }
        var t = 0.0
        var moved = false
        while t < 1.5 {
            t += 1.0 / Self.hz
            _ = rt.frame(at: t)
            guard let (offset, opacity) = rowProgress(rt, 0) else {
                Issue.record("Missing row0 at t=\(t)")
                return
            }
            if t < 0.2 - 1e-6 {
                #expect(offset == 0.0 && opacity == 0.0, "t=\(t): waits at the insertion effect")
            } else {
                #expect(abs(offset - opacity) < 0.02, "t=\(t): offset \(offset) and opacity \(opacity)")
                if opacity > 0.5 { moved = true }
            }
        }
        #expect(moved)
        let final = rowProgress(rt, 0)
        #expect(final?.offset == 1.0 && final?.opacity == 1.0)
    }

    @Test("waiting_sleeps_until_the_start")
    func waitingSleepsUntilTheStart() {
        let rt = makeApp(S(delay: 0.5))
        rt.update(at: 0.0) { s, _ in s.rows = 1 }
        let t1 = 1.0 / Self.hz
        _ = rt.frame(at: t1)
        #expect(!rt.isAnimating, "waiting sleeps instead of spinning")
        #expect(rt.animSources == 0)
        #expect(rt.scene.store.waitingUntil() != nil, "waiting schedules a wake instead of moving")
        let t2 = t1 + 1.0 / Self.hz
        _ = rt.frame(at: t2)
        #expect(!rt.isAnimating, "waiting draws nothing new")
        #expect(rt.animSources == 0)
        #expect(rt.scene.store.touched().isEmpty, "waiting draws nothing new")
        guard let wake = rt.nextWakeDeadline(after: t2) else {
            Issue.record("Expected wake deadline for enterDelay start")
            return
        }
        #expect(abs(wake - 0.5) < 1.5 / Self.hz, "wakes when it starts: \(wake)")
        let tWake = wake
        _ = rt.frame(at: tWake)
        #expect(rowProgress(rt, 0)?.opacity == 0.0)
        _ = rt.frame(at: tWake + 0.1)
        #expect(rt.isAnimating, "the entrance runs")
        #expect((rt.animSources & AnimSource.tracks) != 0)
        #expect((rowProgress(rt, 0)?.opacity ?? 0.0) > 0.0)
    }

    @Test("time_scales_stretch_the_delay")
    func timeScalesStretchTheDelay() {
        for (ownScale, windowScale) in [(Float(0.5), Float(0.0)), (Float(0.0), Float(0.5))] {
            let rt = makeApp(S(delay: 0.2, ownScale: ownScale, windowScale: windowScale))
            rt.update(at: 0.0) { s, _ in s.rows = 1 }
            _ = rt.frame(at: 0.38)
            #expect(rowProgress(rt, 0)?.opacity == 0.0, "\(ownScale) \(windowScale): still waits at 0.38 s")
            _ = rt.frame(at: 0.48)
            #expect((rowProgress(rt, 0)?.opacity ?? 0.0) > 0.0, "\(ownScale) \(windowScale): enters after 0.4 s")
        }
    }

    @Test("removed_while_waiting_doesnt_flash")
    func removedWhileWaitingDoesntFlash() {
        let rt = makeApp(S(delay: 0.3))
        rt.update(at: 0.0) { s, _ in s.rows = 1 }
        _ = rt.frame(at: 0.1)
        rt.update(at: 0.1) { s, _ in s.rows = 0 }
        var t = 0.1
        var removed = false
        for _ in 0..<120 {
            t += 1.0 / Self.hz
            _ = rt.frame(at: t)
            guard let (_, opacity) = rowProgress(rt, 0) else {
                removed = true
                break
            }
            #expect(opacity == 0.0, "no flash")
        }
        #expect(removed, "never left")
    }

    @Test("unseen_entrances_ignore_the_delay")
    func unseenEntrancesIgnoreTheDelay() {
        // The first frame.
        let rtFirst = makeApp(S(rows: 1, delay: 0.3))
        let first = rowProgress(rtFirst, 0)
        #expect(first?.offset == 1.0 && first?.opacity == 1.0)

        // An instant commit.
        let rtInstant = makeApp(S(delay: 0.3))
        rtInstant.update(at: 0.0) { s, tx in
            s.rows = 1
            tx.instant()
        }
        _ = rtInstant.frame(at: 1.0 / Self.hz)
        let inst = rowProgress(rtInstant, 0)
        #expect(inst?.offset == 1.0 && inst?.opacity == 1.0)

        // A settle while it waits.
        let rtSettle = makeApp(S(delay: 0.3))
        rtSettle.update(at: 0.0) { s, _ in s.rows = 1 }
        _ = rtSettle.frame(at: 0.1)
        rtSettle.settleAll()
        _ = rtSettle.frame(at: 0.1 + 1.0 / Self.hz)
        #expect(!rtSettle.isAnimating)
        let settled = rowProgress(rtSettle, 0)
        #expect(settled?.offset == 1.0 && settled?.opacity == 1.0)
    }

    @Test("reduce_motion_keeps_the_delay_and_only_fades")
    func reduceMotionKeepsTheDelayAndOnlyFades() {
        let rt = makeApp(S(delay: 0.3))
        rt.reducedMotion = true
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.0) { s, _ in s.rows = 1 }
        var t = 0.0
        var shown: Double? = nil
        while t < 1.0 {
            t += 1.0 / Self.hz
            _ = rt.frame(at: t)
            guard let (offset, opacity) = rowProgress(rt, 0) else {
                Issue.record("Missing row0 at t=\(t)")
                return
            }
            #expect(offset == 1.0, "t=\(t): nothing travels")
            if t < 0.3 - 1e-6 {
                #expect(opacity == 0.0, "t=\(t): the fade waits")
            }
            if opacity >= 1.0 && shown == nil {
                shown = t
            }
        }
        guard let shownAt = shown else {
            Issue.record("Expected opacity to reach 1.0 before 1.0s")
            return
        }
        #expect(shownAt > 0.3 && shownAt < 0.6, "the short fade, after the delay: \(shownAt)")
    }

    @Test("a_staggered_list_of_five_enters_in_order")
    func aStaggeredListOfFiveEntersInOrder() {
        let rt = makeApp(S(delay: 0.05))
        rt.update(at: 0.0) { s, _ in s.rows = 5 }
        var starts = [Double?](repeating: nil, count: 5)
        var t = 0.0
        while t < 1.5 {
            t += 1.0 / Self.hz
            _ = rt.frame(at: t)
            for i in 0..<5 {
                guard let (offset, opacity) = rowProgress(rt, i) else {
                    Issue.record("Missing row\(i) at t=\(t)")
                    return
                }
                #expect(abs(offset - opacity) < 0.02, "row \(i) t=\(t): offset \(offset), opacity \(opacity)")
                if opacity > 0.0 && starts[i] == nil {
                    starts[i] = t
                }
            }
        }
        let resolved = starts.compactMap { $0 }
        #expect(resolved.count == 5)
        for i in 0..<4 {
            #expect(abs((resolved[i + 1] - resolved[i]) - 0.05) < 1.5 / Self.hz, "row \(i + 1) starts 50 ms after row \(i): \(resolved)")
        }
    }
}
