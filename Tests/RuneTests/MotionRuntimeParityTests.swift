import Testing
import Foundation
@testable import Rune
import RuneMotion
import RuneRef

@Suite("Motion Runtime Parity Tests (#832: loop_sleep, unseen_entrances, reveal_phase, springs)")
struct MotionRuntimeParityTests {

    // MARK: - loop_sleep.rs (remaining 5/6 tests)

    @Test("loop_sleep: cycles_share_deadlines_and_sleep_when_hidden_by_hover_groups")
    func cyclesShareDeadlinesAndSleepWhenHiddenByHoverGroups() throws {
        struct S { var hidden = false }
        let rt = Runtime<S>(state: S(), viewport: Vec2(100, 100), pixelScale: 1.0, systemDark: true) { s, _ in
            el().size(100, 100).hoverGroup().child(
                el().key("cycle").size(20, 20)
                    .groupOpacity(s.hidden ? 0.0 : 1.0, 1.0)
                    .cycle(period: 1.0, phase: 0.0, stops: [(0.0, 0.0), (0.5, 1.0), (1.0, 0.0)], still: 0.4, fps: 30.0)
            )
        }
        var t = 0.0
        _ = rt.frame(at: t)
        #expect(!rt.isAnimating, "cycles must sleep rather than request continuous frames")
        let d0 = try #require(rt.nextWakeDeadline(after: t))
        #expect(abs(d0 - (t + 1.0 / 30.0)) < 1e-6)

        let commits = rt.commitCount
        t += 0.5
        _ = rt.frame(at: t)
        #expect(rt.commitCount == commits)
        let d1 = try #require(rt.nextWakeDeadline(after: t))
        #expect(abs((d1 - t) - 1.0 / 30.0) < 1e-6)

        rt.update(at: t) { s, tx in
            tx.instant()
            s.hidden = true
        }
        _ = rt.frame(at: t)
        #expect(rt.nextWakeDeadline(after: t) == nil, "group-opacity zero must not wake")

        rt.update(at: t) { s, tx in
            tx.instant()
            s.hidden = false
        }
        _ = rt.frame(at: t)
        #expect(rt.nextWakeDeadline(after: t) != nil)

        rt.setLiveVisible(false, at: t)
        _ = rt.frame(at: t)
        #expect(rt.nextWakeDeadline(after: t) == nil)

        rt.setLiveVisible(true, at: t)
        _ = rt.frame(at: t)
        #expect(rt.nextWakeDeadline(after: t) != nil)

        rt.reducedMotion = true
        _ = rt.frame(at: t)
        #expect(rt.nextWakeDeadline(after: t) == nil)
    }

    @Test("loop_sleep: loops_sleep_below_one_8_bit_step_of_opacity")
    func loopsSleepBelowOne8BitStepOfOpacity() {
        for (rest, wakes) in [(Float(0.003), false), (Float(0.005), true)] {
            let rt = Runtime<Float>(state: rest, viewport: Vec2(100, 100), pixelScale: 1.0, systemDark: true) { r, _ in
                el().size(100, 100).hoverGroup().child(
                    el().key("cycle").size(20, 20)
                        .groupOpacity(r, 1.0)
                        .cycle(period: 1.0, phase: 0.0, stops: [(0.0, 0.0), (0.5, 1.0), (1.0, 0.0)], still: 0.4, fps: 30.0)
                )
            }
            _ = rt.frame(at: 0.0)
            #expect((rt.nextWakeDeadline(after: 0.0) != nil) == wakes, "rest opacity \(rest)")
        }
    }

    @Test("loop_sleep: loops_sleep_offscreen_hidden_reduced_and_after_exit")
    func loopsSleepOffscreenHiddenReducedAndAfterExit() {
        struct LoopState {
            var y: Float
            var shown: Bool
            var reduced: Bool
        }
        for (y, shown, reduced, active) in [
            (Float(0.0), true, false, true),
            (Float(200.0), true, false, false),
            (Float(0.0), false, false, false),
            (Float(0.0), true, true, false),
        ] {
            let rt = Runtime<LoopState>(
                state: LoopState(y: y, shown: shown, reduced: reduced),
                viewport: Vec2(100, 100),
                pixelScale: 2.0,
                systemDark: true
            ) { s, cx in
                cx.reducedMotion(s.reduced)
                var root: El<LoopState> = col().key("root").size(100, 100).clipSoft(0.0)
                if s.shown {
                    root = root.child(
                        el().key("loop").pin(top: s.y, left: 0).size(20, 20).bg(.white)
                            .looping(.opacity(period: 1.0, delay: 0.0, low: 0.4, high: 1.0))
                            .transition(.opacity)
                    )
                }
                return root
            }
            var t = 0.0
            _ = rt.frame(at: t)
            #expect(rt.isAnimating == active, "case (\(y), \(shown), \(reduced)) initial active=\(active)")

            var requested = 0
            for _ in 0..<1200 {
                if rt.isAnimating {
                    requested += 1
                    t += 1.0 / 120.0
                    _ = rt.frame(at: t)
                }
            }
            #expect(requested == (active ? 1200 : 0))

            if active {
                rt.update(at: t) { s, _ in s.shown = false }
                _ = rt.frame(at: t)
                #expect(rt.elements().contains { $0.key == "loop" && $0.opacity > 0.0 })
                for _ in 0..<240 {
                    t += 1.0 / 120.0
                    _ = rt.frame(at: t)
                }
                #expect(!rt.isAnimating)
                #expect(!rt.elements().contains { $0.key == "loop" })
            }
        }
    }

    @Test("loop_sleep: slides_sweep_through_their_clip_and_sleep_when_hidden_or_reduced")
    func slidesSweepThroughTheirClipAndSleepWhenHiddenOrReduced() throws {
        struct SlideState {
            var shown: Bool
            var reduced: Bool
            var easing: Easing?
        }
        func makeView(_ s: SlideState, _ cx: inout Cx<SlideState>) -> El<SlideState> {
            cx.reducedMotion(s.reduced)
            var track: El<SlideState> = row().key("track").size(100, 8).clipSoft(0.0)
            if s.shown {
                track = track.child(
                    el().key("bar").wFrac(0.25).hFull().bg(.white)
                        .loopSlide(period: 1.0, from: Vec2(-1.0, 0.0), to: Vec2(4.0, 0.0), easing: s.easing)
                )
            }
            return col().size(100, 100).child(track)
        }
        func barX(_ rt: Runtime<SlideState>) -> Float? {
            rt.element(byKey: "bar")?.rect[0]
        }

        for easing in [Optional<Easing>.none, .linear] {
            let rt = Runtime<SlideState>(
                state: SlideState(shown: true, reduced: false, easing: easing),
                viewport: Vec2(100, 100),
                pixelScale: 2.0,
                systemDark: true,
                view: makeView
            )
            var t = 0.0
            _ = rt.frame(at: t)
            #expect(rt.isAnimating, "a slide starting outside its clip must still run")
            #expect(barX(rt) == -25.0)
            var xs: [Float] = []
            for _ in 0..<128 {
                t += 1.0 / 128.0
                _ = rt.frame(at: t)
                #expect(rt.isAnimating)
                xs.append(try #require(barX(rt)))
            }
            #expect(abs(xs[63] - 37.5) < 0.01, "halfway through period is midpoint: \(xs[63])")
            #expect(zip(xs.dropLast(2), xs.dropFirst().dropLast()).allSatisfy { $0 <= $1 })
            if easing == .linear {
                let step: Float = 125.0 / 128.0
                #expect(zip(xs.dropLast(2), xs.dropFirst().dropLast()).allSatisfy { abs(($1 - $0) - step) < 0.05 })
            }
            #expect(xs[127] == -25.0, "the sweep wraps")

            rt.update(at: t) { s, _ in s.shown = false }
            for _ in 0..<240 {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
            }
            #expect(!rt.isAnimating)

            let rtReduced = Runtime<SlideState>(
                state: SlideState(shown: true, reduced: true, easing: easing),
                viewport: Vec2(100, 100),
                pixelScale: 2.0,
                systemDark: true,
                view: makeView
            )
            _ = rtReduced.frame(at: 0.0)
            #expect(!rtReduced.isAnimating)
            #expect(barX(rtReduced) == 37.5, "reduced motion holds the midpoint")

            let rtHidden = Runtime<SlideState>(
                state: SlideState(shown: true, reduced: false, easing: easing),
                viewport: Vec2(100, 100),
                pixelScale: 2.0,
                systemDark: true,
                view: makeView
            )
            _ = rtHidden.frame(at: 0.0)
            rtHidden.setLiveVisible(false, at: 0.0)
            _ = rtHidden.frame(at: 1.0 / 120.0)
            #expect(!rtHidden.isAnimating)
        }
    }

    @Test("loop_sleep: delayed_opacity_handoff_never_overprints_the_outgoing_label")
    func delayedOpacityHandoffNeverOverprintsOutgoingLabel() {
        struct Handoff {
            var busy: Bool
            var reduced: Bool
        }
        for reduced in [false, true] {
            let rt = Runtime<Handoff>(
                state: Handoff(busy: false, reduced: reduced),
                viewport: Vec2(100, 100),
                pixelScale: 2.0,
                systemDark: true
            ) { s, cx in
                cx.reducedMotion(s.reduced)
                func fade(_ show: Bool) -> Anim<Float> {
                    Anim(curve: .easeInOut(0.18), delay: show ? 0.18 : 0.0)
                }
                return col()
                    .child(el().key("copy").size(28, 28).opacity(s.busy ? 0.0 : 1.0).opacityMotion(fade(!s.busy)))
                    .child(el().key("working").size(28, 28).opacity(s.busy ? 1.0 : 0.0).opacityMotion(fade(s.busy)))
            }
            var t = 0.0
            _ = rt.frame(at: t)
            for busy in [true, false] {
                rt.update(at: t) { s, _ in s.busy = busy }
                for _ in 0..<60 {
                    t += 1.0 / 120.0
                    _ = rt.frame(at: t)
                    let aCopy = rt.element(byKey: "copy")!.opacity
                    let aWork = rt.element(byKey: "working")!.opacity
                    #expect(min(aCopy, aWork) < 0.001, "overprint at t=\(t) (reduced=\(reduced)): copy=\(aCopy) working=\(aWork)")
                }
                #expect(!rt.isAnimating)
            }
        }
    }

    // MARK: - unseen_entrances.rs (2 tests)

    @Test("unseen_entrances: colours_out_of_sight_land_at_once")
    func coloursOutOfSightLandAtOnce() throws {
        let rt = Runtime<UInt32>(state: 0, viewport: Vec2(300, 300), pixelScale: 2.0, systemDark: true) { n, _ in
            let fill: Color = (n % 2 == 1) ? .white : .transparent
            let rows: [El<UInt32>] = (0..<40).map { i in
                col().key("r\(i)").wFull().h(40).bg(fill)
            }
            return col().wFull().hFull().child(
                col().key("scroll").wFull().h(100).scroll(stickBottom: false).child(col().children(rows))
            )
        }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 1.0 / 120.0)
        rt.update(at: 1.0 / 120.0) { n, _ in n = 1 }
        _ = rt.frame(at: 2.0 / 120.0)
        func isFading(_ key: String) -> Bool {
            let id = rt.flatNodes.first(where: { $0.key == key })!.nodeId
            return rt.scene.store.isAnimating(id, Props.FILL)
        }
        #expect(isFading("r0"), "a row in sight fades its fill")
        #expect(!isFading("r30"), "a row out of sight lands it")
    }

    @Test("unseen_entrances: what_mounts_out_of_sight_enters_at_once")
    func whatMountsOutOfSightEntersAtOnce() {
        let rt = Runtime<UInt32>(state: 0, viewport: Vec2(300, 300), pixelScale: 2.0, systemDark: true) { n, _ in
            let rows: [El<UInt32>] = (0..<40).map { i in
                let digit: El<UInt32> = el().key("d\(i)-\(n)").size(10, 10).bg(.white).transition(.opacity)
                return col().key("r\(i)").wFull().h(40).child(digit)
            }
            return col().wFull().hFull().child(
                col().key("scroll").wFull().h(100).scroll(stickBottom: false).child(col().children(rows))
            )
        }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 1.0 / 120.0)
        rt.update(at: 1.0 / 120.0) { n, _ in n = 1 }
        _ = rt.frame(at: 2.0 / 120.0)
        func opacity(_ key: String) -> Float? { rt.element(byKey: key)?.opacity }
        #expect(opacity("d0-1").map { $0 < 1.0 } == true, "a digit in sight fades in: \(String(describing: opacity("d0-1")))")
        #expect(opacity("d30-1") == 1.0, "a digit out of sight lands at once")
        #expect(opacity("d30-0") == nil, "and the one it replaced goes at once")
    }

    // MARK: - reveal_phase.rs (core runtime parity tests)

    @Test("reveal_phase: a_returning_child_keeps_its_words_after_an_instant_parent_unmount")
    func returningChildKeepsWordsAfterInstantParentUnmount() throws {
        struct S { var parent = false }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 200), pixelScale: 1.0, systemDark: true) { s, _ in
            let kids: [El<S>] = s.parent ? [
                col().key("p").child(text("a b c").key("t").wFull().wrap(.wrap).reveal(wordFade: 0.3))
            ] : []
            return col().key("root").w(300).children(kids)
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.0) { s, _ in s.parent = true }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 0.5)
        let id = try #require(rt.flatNodes.first(where: { $0.path == "root/p/t" || $0.key == "t" })?.nodeId)
        #expect(rt.wordRevealStore.phases[id]?.caughtUp(endBytes: 5) == true, "the first words have shown")

        rt.update(at: 0.5) { s, tx in
            s.parent = false
            tx.instant()
        }
        _ = rt.frame(at: 0.5)
        #expect(rt.wordRevealStore.phases[id] != nil, "the unmounted child keeps its reveal state")

        rt.update(at: 0.5) { s, _ in s.parent = true }
        _ = rt.frame(at: 0.5)
        let back = try #require(rt.flatNodes.first(where: { $0.key == "t" })?.nodeId)
        #expect(back == id, "the same key returns under the same id")
        #expect(rt.wordRevealStore.phases[id]?.caughtUp(endBytes: 5) == true, "it comes back showing its words, not replaying them")
    }

    @Test("reveal_phase: an_instant_commit_clears_a_fade")
    func instantCommitClearsFade() throws {
        struct S { var longer = false }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 200), pixelScale: 1.0, systemDark: true) { s, _ in
            col().key("root").w(300).child(
                text(s.longer ? "a b c" : "a").key("t").wFull().wrap(.wrap).reveal(wordFade: 0.3)
            )
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.0) { s, _ in s.longer = true }
        _ = rt.frame(at: 0.0)
        let id = try #require(rt.flatNodes.first(where: { $0.key == "t" })?.nodeId)
        #expect(rt.wordRevealStore.phases[id]?.isFading == true, "the new words fade")

        rt.update(at: 0.0) { _, tx in tx.instant() }
        _ = rt.frame(at: 0.0)
        #expect(rt.wordRevealStore.phases[id]?.caughtUp(endBytes: 5) == true, "the instant commit shows them at once")
    }

    @Test("reveal_phase: a_cut_through_a_character_shows_whole")
    func cutThroughCharacterShowsWhole() throws {
        struct S { var content = "" }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true) { s, _ in
            col().key("root").w(200).child(text(s.content).key("t").wFull().wrap(.wrap).reveal(wordFade: 0.3))
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.0) { s, _ in s.content = "aaa bbbb" }
        _ = rt.frame(at: 0.0)
        let id = try #require(rt.flatNodes.first(where: { $0.key == "t" })?.nodeId)
        #expect(rt.wordRevealStore.phases[id]?.isFading == true, "the first chunk fades")

        // Byte 8 falls inside UTF-8 multi-byte "é" (bytes 7 and 8).
        rt.update(at: 0.0) { s, _ in s.content = "aaaaaaaé" }
        _ = rt.frame(at: 0.0)
        #expect(
            rt.wordRevealStore.phases[id]?.caughtUp(endBytes: "aaaaaaaé".utf8.count) == true,
            "a moved UTF-8 character boundary shows whole"
        )
    }

    @Test("reveal_phase: reduced_motion_fades_every_word_together")
    func reducedMotionFadesEveryWordTogether() throws {
        struct S {
            var content = "a b"
            var reduced = false
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 200), pixelScale: 1.0, systemDark: true) { s, cx in
            cx.reducedMotion(s.reduced)
            return col().key("root").w(300).child(text(s.content).key("t").wFull().wrap(.wrap).reveal(wordFade: 0.3))
        }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 1.0 / 60.0)
        rt.update(at: 0.05) { s, _ in s.reduced = true }
        _ = rt.frame(at: 0.05)
        rt.update(at: 0.05) { s, _ in s.content = "a b c d e f" }
        _ = rt.frame(at: 0.05)
        let id = try #require(rt.flatNodes.first(where: { $0.key == "t" })?.nodeId)
        let times = rt.wordRevealStore.phases[id]?.fade?.words.map(\.startTime) ?? []
        #expect(times.count > 1, "the chunk's words fade: \(times)")
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 == $1 }, "no stagger under reduced motion: \(times)")
    }

    @Test("reveal_phase: a_paused_clock_freezes_the_fade_and_its_resume_shifts_the_words")
    func pausedClockFreezesFadeAndResumeShiftsWords() throws {
        struct S {
            var content = "a b"
            var paused = false
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 200), pixelScale: 1.0, systemDark: true) { s, _ in
            col().key("root").w(300).timeScale(s.paused ? 0.0 : 1.0).child(text(s.content).key("t").wFull().wrap(.wrap).reveal(wordFade: 0.3))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        t = 0.05
        rt.update(at: t) { s, _ in s.content = "a b c d" }
        _ = rt.frame(at: t)
        let id = try #require(rt.flatNodes.first(where: { $0.key == "t" })?.nodeId)
        let before = rt.wordRevealStore.phases[id]?.fade?.words.map(\.startTime) ?? []
        #expect(!before.isEmpty)

        rt.update(at: t) { s, _ in s.paused = true }
        t += 0.2
        _ = rt.frame(at: t)
        let during = rt.wordRevealStore.phases[id]?.fade?.words.map(\.startTime) ?? []
        #expect(before == during, "a frozen clock doesn't fade")

        rt.update(at: t) { s, _ in s.paused = false }
        _ = rt.frame(at: t)
        let resumed = rt.scene.store.nodeTime(id)
        let shifted = rt.wordRevealStore.phases[id]?.fade?.words.map(\.startTime) ?? []
        #expect(shifted.count == before.count)
        #expect(zip(shifted, before).allSatisfy { $0 - $1 >= 0.2 - 1e-6 }, "every word moved with resumed clock: \(shifted) from \(before) nodeNow=\(resumed)")
    }

    // MARK: - springs.rs (missing/partial runtime parity tests)

    @Test("springs: a_child_too_faint_to_paint_does_not_isolate_its_dissolve_parent")
    func childTooFaintToPaintDoesNotIsolateDissolveParent() {
        struct S { var opacity: Float = 0.0005 }
        let rt = Runtime<S>(state: S(), viewport: Vec2(64, 32), pixelScale: 1.0, systemDark: true) { s, _ in
            el().size(64, 32).dissolve().child(el().size(32, 32).opacity(s.opacity).bg(.white))
        }
        let rf0 = rt.renderFrame(at: 0.0)
        #expect(!rf0.instances.contains { $0.params.y == KIND_LAYER && $0.params.x == 1.0 })

        rt.update(at: 0.0) { s, _ in s.opacity = 0.5 }
        var rf1 = rf0
        for i in 1...60 {
            rf1 = rt.renderFrame(at: Double(i) / 60.0)
        }
        #expect(rf1.instances.contains { $0.params.y == KIND_LAYER && $0.params.x == 1.0 })
    }

    @Test("springs: sequences_run_without_commits_then_sleep_and_settle")
    func sequencesRunWithoutCommitsThenSleepAndSettle() throws {
        let beats: [Beat] = [
            Beat(at: 0.0).opacity(0.0).scale(0.8),
            Beat(at: 0.3).easing(.linear),
            Beat(at: 0.6).opacity(0.5).scale(1.1).easing(.linear),
            Beat(at: 0.9).easing(.linear),
        ]
        func make() -> Runtime<Int> {
            Runtime<Int>(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { _, _ in
                el().key("root").size(200, 100).child(
                    el().key("beat").size(80, 40).sequence(MotionSequence(frames: beats, delay: 0.2))
                )
            }
        }
        func pose(_ rt: Runtime<Int>) throws -> ElementInfo {
            try #require(rt.element(byKey: "beat"))
        }

        let rt = make()
        _ = rt.frame(at: 0.0)
        #expect(!rt.isAnimating)
        #expect(rt.nextWakeDeadline(after: 0.0) == 0.2)
        let commits = rt.commitCount
        _ = rt.frame(at: 0.35)
        #expect(rt.isAnimating)
        let pMid = try pose(rt)
        #expect(abs(pMid.opacity - 0.5) < 1e-4)
        #expect(abs(pMid.scale - 0.9) < 1e-4)
        #expect(rt.commitCount == commits)

        rt.invalidate()
        _ = rt.frame(at: 0.35)
        let pRecommit = try pose(rt)
        #expect(abs(pRecommit.opacity - 0.5) < 1e-4, "unrelated commits must not restart the sequence")

        _ = rt.frame(at: 1.35)
        #expect(!rt.isAnimating)
        #expect(rt.nextWakeDeadline(after: 1.35) == nil)
        let pEnd = try pose(rt)
        #expect(pEnd.opacity == 1.0)
        #expect(pEnd.scale == 1.0)

        let settled = make()
        _ = settled.frame(at: 0.0)
        settled.settleAll()
        _ = settled.frame(at: 0.0)
        #expect(!settled.isAnimating)
        #expect(try pose(settled).opacity == 1.0)
        #expect(settled.nextWakeDeadline(after: 0.0) == nil)

        let reduced = make()
        reduced.reducedMotion = true
        _ = reduced.frame(at: 0.0)
        #expect(!reduced.isAnimating)
        #expect(try pose(reduced).scale == 1.0)
        #expect(try pose(reduced).opacity == 1.0)
        #expect(reduced.nextWakeDeadline(after: 0.0) == nil)
    }

    @Test("springs: motion_curve_moves_layout_on_a_tween")
    func motionCurveMovesLayoutOnTween() {
        func cardHeight(_ rt: Runtime<Float>) -> Float {
            rt.element(byKey: "card")!.rect[3]
        }
        func run(_ configure: (inout Tx) -> Void) -> [Float] {
            let rt = Runtime<Float>(state: 100.0, viewport: Vec2(200, 300), pixelScale: 1.0, systemDark: true) { h, _ in
                col().size(200, 300).child(el().key("card").w(100).h(h))
            }
            var t = 0.0
            _ = rt.frame(at: t)
            rt.update(at: t) { x, tx in
                x = 200.0
                configure(&tx)
            }
            _ = rt.frame(at: t)
            var hs: [Float] = []
            for _ in 0..<60 {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
                hs.append(cardHeight(rt))
            }
            return hs
        }
        let linear = run { $0.motionCurve(Curve.linear(0.4)) }
        #expect(abs(linear[23] - 150.0) < 3.0, "halfway through linear 0.4s tween: \(linear[23])")
        #expect(abs(linear[47] - 200.0) < 0.05, "lands on time: \(linear[47])")
        let spring = run { $0.motion(Spring(duration: 0.4, bounce: 0.0)) }
        #expect(abs(spring[23] - linear[23]) > 3.0, "a spring is not the tween")
        #expect(run { $0.motionCurve(Anim<Float>(curve: .spring(Spring(duration: 0.4, bounce: 0.0)))) } == spring)
        #expect(run { $0.motionCurve(Curve.linear(0.4)); $0.motion(Spring(duration: 0.4, bounce: 0.0)) } == spring)
    }

    @Test("springs: layout_motion_does_not_replace_explicit_transition_exit")
    func layoutMotionDoesNotReplaceExplicitTransitionExit() {
        struct S { var shown: Bool; var duration: Float }
        func make(_ duration: Float) -> Runtime<S> {
            Runtime<S>(state: S(shown: true, duration: duration), viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { s, _ in
                let kids: [El<S>] = s.shown ? [
                    el().key("pill").size(100, 40)
                        .animateLayout(Spring(duration: s.duration, bounce: 0.0))
                        .transition(Transition.scale(0.96).springs(SpringPair(
                            enter: Spring(duration: 0.3, bounce: 0.0),
                            exit: Spring(duration: 0.8, bounce: 0.0)
                        )))
                ] : []
                return col().size(200, 100).children(kids)
            }
        }
        let fast = make(0.05)
        let slow = make(0.6)
        for rt in [fast, slow] {
            _ = rt.frame(at: 0.0)
            rt.update(at: 0.0) { s, _ in s.shown = false }
            _ = rt.frame(at: 0.0)
            _ = rt.frame(at: 0.1)
        }
        let fOp = fast.element(byKey: "pill")!.opacity
        let sOp = slow.element(byKey: "pill")!.opacity
        #expect(fOp > 0.5, "the explicit slow exit must survive fast layout tuning")
        #expect(abs(fOp - sOp) < 1e-5)
    }

    @Test("springs: a_node_leaves_with_the_transition_of_its_last_render")
    func nodeLeavesWithTransitionOfLastRender() {
        struct S { var shown: Bool; var way: Float }
        func make(_ shown: Bool) -> Runtime<S> {
            Runtime<S>(state: S(shown: shown, way: -1.0), viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { s, _ in
                let kids: [El<S>] = s.shown ? [
                    el().key("page").size(100, 40).transition(.offset(x: 40.0 * s.way, y: 0))
                ] : []
                return col().size(200, 100).children(kids)
            }
        }
        func xPos(_ rt: Runtime<S>) -> Float { rt.element(byKey: "page")!.rect[0] }

        let kept = make(false)
        let turned = make(false)
        for rt in [kept, turned] {
            _ = rt.frame(at: 0.0)
            rt.update(at: 0.0) { s, _ in s.shown = true }
            _ = rt.frame(at: 0.0)
            _ = rt.frame(at: 0.05)
        }
        turned.update(at: 0.05) { s, _ in s.way = 1.0 }
        _ = kept.frame(at: 0.10)
        _ = turned.frame(at: 0.10)
        #expect(xPos(turned) < 0.0, "still entering from left: \(xPos(turned))")
        #expect(abs(xPos(kept) - xPos(turned)) < 1e-3, "running entrance unaffected")

        let rt = make(true)
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 2.0)
        #expect(xPos(rt) == 0.0)
        rt.update(at: 2.0) { s, _ in s.way = 1.0 }
        _ = rt.frame(at: 2.0)
        rt.update(at: 2.0) { s, _ in s.shown = false }
        _ = rt.frame(at: 2.0)
        _ = rt.frame(at: 2.1)
        #expect(xPos(rt) > 1.0, "leaves the way of its last render: \(xPos(rt))")
    }

    @Test("springs: element_effects_include_ancestor_opacity_scale_and_exit_blur")
    func elementEffectsIncludeAncestorOpacityScaleAndExitBlur() throws {
        struct S { var show = true }
        let parentScale = Live<Float>(0.8)
        let childScale = Live<Float>(0.5)
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 100), pixelScale: 2.0, systemDark: true) { s, _ in
            let kids: [El<S>] = s.show ? [
                el().key("parent").size(100, 60).opacity(0.5).liveScale(parentScale.binding).transition(.blur(sigma: 4.0))
                    .child(el().key("child").size(20, 20).opacity(0.5).liveScale(childScale.binding))
            ] : []
            return col().size(200, 100).children(kids)
        }
        _ = rt.frame(at: 0.0)
        let child0 = try #require(rt.element(byKey: "child"))
        #expect(abs(child0.opacity - 0.25) < 1e-5)
        #expect(abs(child0.scale - 0.4) < 1e-5)
        #expect(child0.blur == 0.0)

        rt.update(at: 0.0) { s, _ in s.show = false }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 0.05)
        let parent = try #require(rt.element(byKey: "parent"))
        let child = try #require(rt.element(byKey: "child"))
        #expect(parent.blur > 0.0)
        #expect(child.blur == parent.blur)
        #expect(abs(child.opacity - parent.opacity * 0.5) < 1e-5)
    }

    @Test("springs: exiting_elements_are_flagged_and_gone_from_key_lookups")
    func exitingElementsFlaggedAndGoneFromKeyLookups() throws {
        struct S { var show = true }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { s, _ in
            let kids: [El<S>] = s.show ? [
                el().key("card").size(100, 60).transition(.blur(sigma: 4.0))
                    .child(el().key("label").size(20, 20))
            ] : []
            return col().size(200, 100).children(kids)
        }
        _ = rt.frame(at: 0.0)
        #expect(rt.find("card") != nil && rt.find("label") != nil)
        #expect(rt.elements().allSatisfy { !$0.exiting })

        rt.update(at: 0.0) { s, _ in s.show = false }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 0.05)
        for key in ["card", "label"] {
            let e = try #require(rt.element(byKey: key), "\(key) still drawn while it exits")
            #expect(e.exiting && e.inert, "\(key) is exiting & inert")
            #expect(rt.find(key) == nil, "\(key) is gone from lookups")
        }
    }

    @Test("springs: a_duplicate_matched_id_matches_the_last_one_and_warns")
    func duplicateMatchedIdMatchesLastOneAndWarns() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(100, 100), pixelScale: 1.0, systemDark: true) { _, _ in
            col()
                .child(el().key("a").matched("tile").size(10, 10))
                .child(el().key("b").matched("tile").size(10, 10))
        }
        _ = rt.frame(at: 0.0)
        #expect(rt.keyWarnings.contains { $0.contains("tile") || $0.contains("matched") }, "warnings: \(rt.keyWarnings)")
    }

    @Test("springs: presence_exits_stay_drawn_and_revive_mid_flight")
    func presenceExitsStayDrawnAndReviveMidFlight() throws {
        struct S { var show = true }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 100), pixelScale: 2.0, systemDark: true) { s, _ in
            let kids: [El<S>] = s.show ? [
                el().key("badge").size(80, 30).bg(.white).transition(.blurReplace())
            ] : []
            return col().key("root").size(200, 100).children(kids)
        }
        _ = rt.frame(at: 0.0)
        #expect(!rt.isAnimating, "first mount never animates")
        #expect(rt.elements().count == 2)

        var t = 1.0 / 60.0
        rt.update(at: t) { s, _ in s.show = false }
        _ = rt.frame(at: t)
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(rt.isAnimating)
        let badge = try #require(rt.element(byKey: "badge"))
        #expect(badge.opacity > 0.0 && badge.opacity < 1.0)

        let before = badge.opacity
        t += 1.0 / 60.0
        rt.update(at: t) { s, _ in s.show = true }
        _ = rt.frame(at: t)
        let after = try #require(rt.element(byKey: "badge")).opacity
        #expect(abs(after - before) < 0.15, "\(before) -> \(after)")

        t += 1.0 / 60.0
        rt.update(at: t) { s, _ in s.show = false }
        for _ in 0..<120 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        #expect(!rt.isAnimating)
        #expect(rt.element(byKey: "badge") == nil)
    }

    // MARK: - timeScale subtree tests (springs.rs:291-442)

    private struct Lab {
        var outside: Float = 1.0
        var inside: Float = 1.0
        var badge: Bool = true
        var outer: Float
        var inner: Float

        func runtime() -> Runtime<Lab> {
            let rt = Runtime<Lab>(state: self, viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true) { s, _ in
                func dot(_ key: String, _ o: Float) -> El<Lab> {
                    el().key(key).size(20, 20).bg(.white).opacity(o).opacityMotion(MotionTokens.SETTLE)
                }
                var innerCol: El<Lab> = col().key("inner").timeScale(s.inner).child(dot("inside", s.inside))
                if s.badge {
                    innerCol = innerCol.child(el().key("badge").size(20, 20).bg(.white).transition(.opacity))
                }
                return col().key("root").size(200, 200)
                    .child(dot("outside", s.outside))
                    .child(col().key("outer").timeScale(s.outer).child(innerCol))
            }
            _ = rt.frame(at: 0.0)
            #expect(!rt.isAnimating)
            return rt
        }
    }

    @Test("springs: nested_time_scales_multiply")
    func nestedTimeScalesMultiply() throws {
        let rt = Lab(outer: 0.5, inner: 0.5).runtime()
        var t = 0.0
        rt.update(at: t) { s, _ in
            s.outside = 0.0
            s.inside = 0.0
        }
        for _ in 0..<5 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let reference = try #require(rt.element(byKey: "outside")?.opacity)
        #expect(reference > 0.05 && reference < 0.95, "mid-flight: \(reference)")
        for _ in 0..<15 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let inside = try #require(rt.element(byKey: "inside")?.opacity)
        #expect(abs(inside - reference) < 1e-3, "\(inside) at 4t vs \(reference) at t")
    }

    @Test("springs: a_frozen_subtree_with_pending_motion_requests_no_frames")
    func frozenSubtreeWithPendingMotionRequestsNoFrames() throws {
        let rt = Lab(outer: 1.0, inner: 0.0).runtime()
        var t = 0.0
        rt.update(at: t) { s, _ in s.inside = 0.0 }
        for _ in 0..<5 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            #expect(!rt.isAnimating, "a frozen fade asks for no frames")
        }
        #expect(rt.scene.store.activeLen > 0, "the fade is still pending")
        #expect(rt.nextWakeDeadline(after: t) == nil)
        #expect(rt.element(byKey: "inside")?.opacity == 1.0)

        rt.update(at: t) { s, _ in s.inner = 1.0 }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(rt.isAnimating, "resuming runs it")
        let inside = try #require(rt.element(byKey: "inside")?.opacity)
        #expect(inside < 1.0)
    }

    @Test("springs: resuming_a_frozen_subtree_continues_from_the_same_value")
    func resumingFrozenSubtreeContinuesFromSameValue() throws {
        let rt = Lab(outer: 1.0, inner: 1.0).runtime()
        var t = 0.0
        rt.update(at: t) { s, _ in
            s.outside = 0.0
            s.inside = 0.0
        }
        for _ in 0..<5 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let held = try #require(rt.element(byKey: "inside")?.opacity)
        #expect(held < 1.0)

        rt.update(at: t) { s, _ in s.inner = 0.0 }
        for _ in 0..<5 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let reference = try #require(rt.element(byKey: "outside")?.opacity)
        for _ in 0..<5 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        #expect(rt.element(byKey: "inside")?.opacity == held, "no drift while frozen")

        rt.update(at: t) { s, _ in s.inner = 1.0 }
        _ = rt.frame(at: t)
        #expect(rt.element(byKey: "inside")?.opacity == held, "resumes from held value")

        for _ in 0..<5 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let inside = try #require(rt.element(byKey: "inside")?.opacity)
        #expect(abs(inside - reference) < 1e-3, "continues on the same curve: \(inside) vs \(reference)")
    }

    @Test("springs: an_exit_in_a_frozen_subtree_finishes_after_resuming")
    func exitInFrozenSubtreeFinishesAfterResuming() throws {
        let rt = Lab(outer: 1.0, inner: 0.0).runtime()
        var t = 0.0
        rt.update(at: t) { s, _ in s.badge = false }
        for _ in 0..<120 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        #expect(!rt.isAnimating)
        let badge = try #require(rt.element(byKey: "badge"), "still exiting")
        #expect(badge.exiting && badge.opacity == 1.0, "held at start of exit: \(badge.opacity)")

        rt.update(at: t) { s, _ in s.inner = 1.0 }
        for _ in 0..<3 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let afterResume = try #require(rt.element(byKey: "badge")?.opacity)
        #expect(afterResume < 1.0, "the exit runs")

        for _ in 0..<120 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        #expect(!rt.isAnimating)
        #expect(rt.element(byKey: "badge") == nil, "and is removed")
    }

    @Test("springs: a_node_unmounted_at_once_in_a_scaled_subtree_drops_its_clock")
    func nodeUnmountedAtOnceInScaledSubtreeDropsClock() throws {
        let rt = Lab(outer: 1.0, inner: 0.5).runtime()
        let badge = try #require(rt.flatNodes.first(where: { $0.key == "badge" })?.nodeId)
        #expect(rt.scene.store.nodeTimeScale(badge) == 0.5)

        rt.update(at: 0.0) { s, _ in s.badge = false }
        rt.settleAll()
        _ = rt.frame(at: 1.0 / 60.0)
        #expect(rt.element(byKey: "badge") == nil)
        #expect(rt.scene.store.nodeTimeScale(badge) == 1.0, "its clock went with it")
    }

    @Test("springs: an_exiting_element_drops_its_own_time_scale")
    func exitingElementDropsOwnTimeScale() throws {
        let rt = Runtime<Bool>(state: true, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { show, _ in
            let kids: [El<Bool>] = show ? [
                el().key("card").size(80, 30).bg(.white).timeScale(0.0).transition(.opacity)
            ] : []
            return col().key("root").size(200, 100).children(kids)
        }
        _ = rt.frame(at: 0.0)
        #expect(!rt.isAnimating)

        var t = 0.0
        rt.update(at: t) { s, _ in s = false }
        for _ in 0..<3 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let card = try #require(rt.element(byKey: "card"))
        #expect(card.exiting && card.opacity < 1.0, "its exit runs: \(card.opacity)")

        for _ in 0..<120 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        #expect(rt.element(byKey: "card") == nil, "and it leaves")
    }

    @Test("springs: removing_what_draws_nothing_skips_its_exit")
    func removingWhatDrawsNothingSkipsExit() {
        struct S {
            var shown = true
            var glowOpacity: Float = 1.0
            var parentHidden = false
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true) { s, _ in
            let dotKids: [El<S>] = s.shown ? [el().key("dot").size(10, 10).bg(.white).transition(.opacity)] : []
            let glowKids: [El<S>] = s.shown ? [el().key("glow").size(50, 50).bg(.white).opacity(s.glowOpacity).transition(.opacity)] : []
            return col().key("root").size(200, 200)
                .child(
                    col().key("group").size(100, 100)
                        .opacity(s.parentHidden ? 0.0 : 1.0)
                        .opacityMotion(Anim<Float>.instant)
                        .children(dotKids)
                )
                .children(glowKids)
        }
        func exists(_ key: String) -> Bool { rt.element(byKey: key) != nil }

        var t = 0.0
        _ = rt.frame(at: t)
        for _ in 0..<60 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }

        // Visible: both fade out.
        rt.update(at: t) { s, _ in s.shown = false }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(exists("dot") && exists("glow"), "visible elements fade out")
        for _ in 0..<60 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }

        // Already opacity 0 or under hidden parent: gone in the frame.
        rt.update(at: t) { s, _ in
            s.shown = true
            s.glowOpacity = 0.0
            s.parentHidden = true
        }
        for _ in 0..<60 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        rt.update(at: t) { s, _ in s.shown = false }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(!exists("glow"), "glow at opacity 0 has no exit")
        #expect(!exists("dot"), "dot under hidden parent has no exit")
        #expect(!rt.isAnimating)

        // Parent hides at once in same commit: dot's exit stops when it draws nothing.
        rt.update(at: t) { s, _ in
            s.shown = true
            s.glowOpacity = 1.0
            s.parentHidden = false
        }
        for _ in 0..<60 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        rt.update(at: t) { s, _ in
            s.shown = false
            s.glowOpacity = 1.0
            s.parentHidden = true
        }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(!exists("dot"), "dot under a parent that hid at once is gone")
    }
}
