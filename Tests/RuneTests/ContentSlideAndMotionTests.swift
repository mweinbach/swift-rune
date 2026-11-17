import Testing
import Foundation
@testable import Rune
import RuneMotion

@Suite("ContentSlide, NoMotion, DrawOn & RevealChain Parity Tests (#832)")
struct ContentSlideAndMotionTests {

    // MARK: - content_slide_tests.rs (3 tests)

    private func growthTrack(h: Float, target: Float) -> GrowTrack {
        GrowTrack(h: h, v: 0, target: target)
    }

    @Test("content_slide: a_slide_shrinks_with_the_growth_left_to_open")
    func slideShrinksWithGrowthLeftToOpen() {
        let phase = SlidePhase.following(dy: -20.0, v: 0.0, at: 0.0)
        let next = phase.step(growth: growthTrack(h: 50.0, target: 100.0), spring: Growth.spring, steps: 12)
        guard case .following(let dy, let v, let at) = next else {
            Issue.record("Expected .following phase, got \(next)")
            return
        }
        #expect(dy == -10.0 && at == 50.0, "half the growth left, half the slide")
        #expect(abs(v - (10.0 / (12.0 * Growth.substep))) < 1e-3, "speed measured for spring handoff: \(v)")
        let same = next.step(growth: growthTrack(h: 75.0, target: 100.0), spring: Growth.spring, steps: 0)
        #expect(same == .following(dy: -5.0, v: v, at: 75.0))
    }

    @Test("content_slide: a_growth_that_stops_opening_toward_it_hands_its_speed_to_a_spring")
    func growthStopsOpeningHandsSpeedToSpring() {
        let phase = SlidePhase.following(dy: -10.0, v: 300.0, at: 50.0)
        let next = phase.step(growth: growthTrack(h: 50.0, target: 20.0), spring: Growth.spring, steps: 1)
        guard case .settling(let dy, let v) = next else {
            Issue.record("Expected .settling phase, got \(next)")
            return
        }
        let (wantDy, wantV) = Growth.spring.sample(from: -10.0, velocity: 300.0, target: 0.0, at: Growth.substep)
        #expect(dy == wantDy && v == wantV)
        if case .settling = next.step(growth: growthTrack(h: 0.0, target: 100.0), spring: Growth.spring, steps: 1) {
            // Re-opening growth never pulls a settling slide back into .following.
        } else {
            Issue.record("Expected settling phase to remain .settling")
        }
    }

    @Test("content_slide: a_slide_ends_at_its_layout_and_a_spring_once_it_also_stops")
    func slideEndsAtLayoutAndSpringOnceStopped() {
        #expect(!SlidePhase.following(dy: 0.001, v: 900.0, at: 10.0).live)
        #expect(SlidePhase.settling(dy: 0.001, v: 900.0).live)
        #expect(!SlidePhase.settling(dy: 0.001, v: 0.1).live)
        var phase = SlidePhase.settling(dy: -40.0, v: 0.0)
        var frames = 0
        while phase.live {
            phase = phase.step(growth: growthTrack(h: 0.0, target: 0.0), spring: Growth.spring, steps: 2)
            frames += 1
            #expect(frames < 240, "springs home within 2s: \(phase)")
        }
    }

    // MARK: - no_motion.rs (2 tests)

    @Test("no_motion: a_none_transition_lands_in_the_frame_while_the_rest_animates")
    func noneTransitionLandsInFrameWhileRestAnimates() {
        struct PillState {
            var shown: Bool
            var transition: Transition
        }
        func pillView(_ s: PillState, _ cx: inout Cx<PillState>) -> El<PillState> {
            var c: El<PillState> = col().size(200, 200)
            if s.shown {
                c = c.child(el().key("pill").size(100, 40).transition(s.transition))
            }
            return c.child(el().key("row").size(100, 40).animateLayout())
        }

        let short = Spring(duration: 0.001, bounce: 0.0)
        for reduced in [false, true] {
            let rt = Runtime<PillState>(
                state: PillState(shown: false, transition: .none),
                viewport: Vec2(200, 200),
                pixelScale: 1.0,
                systemDark: true,
                reducedMotion: reduced,
                view: pillView
            )
            _ = rt.frame(at: 0.0)
            rt.update(at: 0.0) { s, _ in s.shown = true }
            _ = rt.frame(at: 0.0)
            let pill = rt.element(byKey: "pill")!
            #expect(pill.opacity == 1.0, "whole in the frame it mounts (reducedMotion: \(reduced))")
            if !reduced {
                let row = rt.element(byKey: "row")!
                #expect(row.rect[1] < row.target[1] - 1.0, "the row it pushes still springs: \(row.rect)")
            }
            rt.update(at: 0.0) { s, _ in s.shown = false }
            _ = rt.frame(at: 0.0)
            #expect(rt.element(byKey: "pill").map { $0.opacity == 0.0 } ?? true, "gone in the frame it is removed")
            _ = rt.frame(at: 0.0)
            #expect(rt.element(byKey: "pill") == nil, "unmounted by the next frame")
        }

        let rtReduced = Runtime<PillState>(
            state: PillState(shown: true, transition: Transition.identity.springs(SpringPair(enter: short, exit: short))),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            systemDark: true,
            reducedMotion: true,
            view: pillView
        )
        _ = rtReduced.frame(at: 0.0)
        rtReduced.update(at: 0.0) { s, _ in s.shown = false }
        _ = rtReduced.frame(at: 0.0)
        _ = rtReduced.frame(at: 0.0)
        #expect(rtReduced.element(byKey: "pill") != nil)
    }

    @Test("no_motion: closing_at_once_returns_focus_to_the_opener")
    func closingAtOnceReturnsFocusToOpener() {
        struct Form {
            var open = false
            var field = TextEdit("")
            var fieldFocused = false
            var modal: Bool
            var none: Bool
            var instant: Bool
        }
        func formView(_ s: Form, _ cx: inout Cx<Form>) -> El<Form> {
            let opener: El<Form> = el().key("opener").size(30, 30).focusable(true).role(.button)
                .onClick { state, _ in
                    state.open = true
                    state.fieldFocused = true
                }
            var popup: El<Form> = col().key("popup").pin(top: 0, left: 100).size(150, 100)
                .child(
                    textInput(key: "field", \Form.field)
                        .font(TextStyle(size: 14, weight: 400))
                        .size(120, 30)
                        .focused(s.fieldFocused)
                )
            if s.modal {
                popup = popup.modal(clickOutside: true) { state in state.open = false }
            } else {
                popup = popup.focusReturn("opener")
            }
            if s.none {
                popup = popup.transition(.none)
            }
            var root: El<Form> = col().key("root").size(300, 300).child(opener)
            if s.open {
                root = root.child(popup)
            }
            return root
        }

        func focusedKey(in rt: Runtime<Form>) -> String? {
            rt.elements().first(where: { $0.focused })?.key
        }

        for modal in [false, true] {
            for (none, instant) in [(false, true), (true, false), (true, true)] {
                let rt = Runtime<Form>(
                    state: Form(modal: modal, none: none, instant: instant),
                    viewport: Vec2(300, 300),
                    pixelScale: 1.0,
                    systemDark: true,
                    view: formView
                )
                _ = rt.frame(at: 0.0)
                let opener = rt.element(byKey: "opener")!
                let pt = Vec2(opener.rect[0] + opener.rect[2] * 0.5, opener.rect[1] + opener.rect[3] * 0.5)
                rt.pointerDown(at: pt, at: 0.0)
                rt.pointerUp(at: pt, at: 0.0)
                _ = rt.frame(at: 0.0)
                #expect(focusedKey(in: rt) == "field")
                // Handler leaves field's own focus flag set: it unmounts without an explicit blur.
                rt.update(at: 0.0) { s, tx in
                    if s.instant { tx.instant() }
                    s.open = false
                }
                _ = rt.frame(at: 0.0)
                _ = rt.frame(at: 1.0 / 60.0)
                #expect(rt.element(byKey: "popup") == nil)
                #expect(focusedKey(in: rt) == "opener", "modal \(modal), none \(none), instant \(instant)")
            }
        }
    }

    // MARK: - draw_on.rs (2 tests)

    @Test("draw_on: a_draw_transition_traces_a_shape_on_and_reduce_motion_draws_it_whole")
    func drawTransitionTracesShapeOnAndReduceMotionDrawsWhole() {
        struct LineState {
            var shown: Bool
            var transition: Transition
        }
        func lineView(_ s: LineState, _ cx: inout Cx<LineState>) -> El<LineState> {
            let pts: [Vec2] = (0...10).map { Vec2(Float($0) * 10.0, 20.0) }
            let shape = Shape.new().stroke(pts, width: 2.0, color: .white)
            var root: El<LineState> = col().size(200, 100)
            if s.shown {
                root = root.child(canvas(shape).key("line").size(120, 40).transition(s.transition))
            }
            return root
        }

        let rt = Runtime<LineState>(
            state: LineState(shown: false, transition: .draw),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true,
            view: lineView
        )
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.0) { s, _ in s.shown = true }
        let first = rt.frame(at: 0.0)
        var seen: [Int] = [first.primitives.filter { $0.kind == .segment }.count]
        for i in 1...90 {
            let scene = rt.frame(at: Double(i) / 120.0)
            seen.append(scene.primitives.filter { $0.kind == .segment }.count)
        }
        #expect(seen[0] < 3, "starts undrawn: \(seen)")
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 }, "draws on, never back: \(seen)")
        #expect(seen.contains { $0 > 3 && $0 < 10 }, "passes through partly drawn: \(seen)")
        #expect(seen.last == 10, "ends whole: \(seen)")

        let rtReduced = Runtime<LineState>(
            state: LineState(shown: false, transition: .draw),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true,
            reducedMotion: true,
            view: lineView
        )
        _ = rtReduced.frame(at: 0.0)
        rtReduced.update(at: 0.0) { s, _ in s.shown = true }
        let reducedScene = rtReduced.frame(at: 0.0)
        #expect(reducedScene.primitives.filter { $0.kind == .segment }.count == 10)
    }

    @Test("draw_on: a_live_trim_cuts_a_shape_every_frame_without_rebuilding")
    func liveTrimCutsShapeEveryFrameWithoutRebuilding() {
        struct TrimState {
            var trim: Tween<Vec2>
        }
        let tween = Tween<Vec2>.linear(from: Vec2(0.0, 1.0), to: Vec2(1.0, 1.0), duration: 1.0)
        let rt = Runtime<TrimState>(
            state: TrimState(trim: tween),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            let pts: [Vec2] = (0...10).map { Vec2(Float($0) * 10.0, 20.0) }
            let shape = Shape.new().stroke(pts, width: 2.0, color: .white)
            return col().size(200, 100).child(
                canvas(shape).key("line").size(120, 40).liveTrim(s.trim.binding)
            )
        }

        let s0 = rt.frame(at: 0.0)
        #expect(s0.primitives.filter { $0.kind == .segment }.count == 10, "starts whole")
        let commits = rt.commitCount
        var seen: [Int] = []
        var t = 0.0
        for _ in 0..<10 {
            t += 0.1 - 1e-4
            let sc = rt.frame(at: t)
            #expect(rt.isAnimating, "keeps drawing while tween runs")
            seen.append(sc.primitives.filter { $0.kind == .segment }.count)
        }
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 >= $1 }, "only shortens: \(seen)")
        #expect(seen.contains(5), "half gone at half time: \(seen)")
        t += 0.01
        let sEnd = rt.frame(at: t)
        #expect(sEnd.primitives.filter { $0.kind == .segment }.count == 0, "gone at the end")
        t += 0.1
        _ = rt.frame(at: t)
        #expect(!rt.isAnimating, "settles")
        #expect(rt.commitCount == commits, "no view rebuild")

        rt.update(at: t) { s, _ in
            s.trim = Tween<Vec2>.linear(from: Vec2(0.25, 0.5), to: Vec2(0.25, 0.5), duration: 0.0)
        }
        let sFixed = rt.frame(at: t)
        #expect(sFixed.primitives.filter { $0.kind == .segment }.count == 3, "fixed span keeps its stretch across segment cuts")
    }

    // MARK: - reveal_chain.rs (4 tests)

    private func makeRevealChainRuntime() -> Runtime<[String]> {
        let rt = Runtime<[String]>(
            state: [""],
            viewport: Vec2(600, 800),
            pixelScale: 2.0,
            systemDark: true
        ) { paras, _ in
            var c: El<[String]> = col().wFull()
            for (i, p) in paras.enumerated() {
                c = c.child(text(p).wrap(.wrap).wFull().reveal(wordFade: 0.3).key("p\(i)"))
            }
            return c
        }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 1.0 / 60.0)
        return rt
    }

    private func revealWords(_ n: Int) -> String {
        (0..<n).map { "word\($0)" }.joined(separator: " ")
    }

    private func revealTimes(_ rt: Runtime<[String]>, key: String) -> (Double, Double)? {
        guard let node = rt.flatNodes.first(where: { $0.key == key }),
              let phase = rt.wordRevealStore.phases[node.nodeId],
              let fade = phase.fade,
              let first = fade.words.first?.startTime,
              let last = fade.words.last?.startTime else {
            return nil
        }
        return (first, last)
    }

    @Test("reveal_chain: one_chunk_over_three_paragraphs_fades_them_in_order")
    func oneChunkOverThreeParagraphsFadesInOrder() {
        let rt = makeRevealChainRuntime()
        let t = rt.currentTime + 1.0 / 60.0
        rt.update(at: t) { paras, _ in
            paras = [revealWords(12), revealWords(12), revealWords(12)]
        }
        _ = rt.frame(at: t)
        let a = revealTimes(rt, key: "p0")!
        let b = revealTimes(rt, key: "p1")!
        let c = revealTimes(rt, key: "p2")!
        #expect(b.0 > a.1 && c.0 > b.1, "each paragraph starts after the one above ends: \(a) \(b) \(c)")
    }

    @Test("reveal_chain: a_new_paragraph_waits_for_the_last_ones_tail")
    func newParagraphWaitsForLastTail() {
        let rt = makeRevealChainRuntime()
        var t = rt.currentTime + 1.0 / 60.0
        rt.update(at: t) { paras, _ in paras = [revealWords(30)] }
        _ = rt.frame(at: t)
        let a = revealTimes(rt, key: "p0")!
        t += 1.0 / 60.0
        rt.update(at: t) { paras, _ in paras.append(revealWords(4)) }
        _ = rt.frame(at: t)
        let b = revealTimes(rt, key: "p1")!
        #expect(b.0 > a.1, "the next paragraph starts after the last word above: \(a) then \(b)")
    }

    @Test("reveal_chain: once_everything_has_shown_a_new_paragraph_starts_at_once")
    func onceEverythingShownNewParagraphStartsAtOnce() {
        let rt = makeRevealChainRuntime()
        var t = rt.currentTime + 1.0 / 60.0
        rt.update(at: t) { paras, _ in paras = [revealWords(8)] }
        _ = rt.frame(at: t)
        for _ in 0..<120 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        t += 1.0 / 60.0
        rt.update(at: t) { paras, _ in paras.append(revealWords(4)) }
        _ = rt.frame(at: t)
        let (first, _) = revealTimes(rt, key: "p1")!
        #expect(abs(first - t) < 0.02, "no wait once nothing is fading: starts \(first), now \(t)")
    }

    @Test("reveal_chain: texts_behind_a_long_run_fade_together")
    func textsBehindLongRunFadeTogether() {
        let rt = makeRevealChainRuntime()
        let t = rt.currentTime + 1.0 / 60.0
        rt.update(at: t) { paras, _ in
            paras = [revealWords(120), revealWords(120), revealWords(120)]
        }
        _ = rt.frame(at: t)
        let a = revealTimes(rt, key: "p0")!
        let b = revealTimes(rt, key: "p1")!
        let c = revealTimes(rt, key: "p2")!
        #expect(a.1 - a.0 > 0.3, "first paragraph outlasts one fade: \(a)")
        #expect(b.0 < a.1 && c.0 < a.1, "the rest do not wait behind a long run: \(a) \(b) \(c)")
    }

    // MARK: - fold_glide.rs / fold_hold.rs (10 tests)

    private struct FoldHeldState {
        var open: Bool
        var afterHeight: Float
    }

    private func makeFoldSectionEl(_ open: Bool, afterHeight: Float = 100.0, includeTail: Bool = false) -> El<Bool> {
        var group: El<Bool> = col().key("group").wFull()
            .child(el().key("hdr").wFull().h(28).stickyTop(0))
        if open {
            var stepsCol: El<Bool> = col().key("steps").wFull()
            for k in 0..<40 {
                stepsCol = stepsCol.child(el().key("step-\(k)").wFull().h(28))
            }
            group = group.child(stepsCol)
        }
        var stack: El<Bool> = col().key("stack").wFull().growth(GrowthSpec())
            .child(el().key("before").wFull().h(200))
            .child(col().key("turn").wFull().foldGlide(Spring(duration: 0.18, bounce: 0.0)).child(group))
            .child(el().key("after").wFull().h(afterHeight))
        if includeTail {
            stack = stack.child(el().key("tail").wFull().h(100))
        }
        return col().key("scroll").size(300, 200).scroll(ScrollSpec(stickBottom: true)).child(stack)
    }

    private func makeFoldHeldEl(_ s: FoldHeldState) -> El<FoldHeldState> {
        var group: El<FoldHeldState> = col().key("group").wFull()
            .child(el().key("hdr").wFull().h(28).stickyTop(0))
        if s.open {
            var stepsCol: El<FoldHeldState> = col().key("steps").wFull()
            for k in 0..<40 {
                stepsCol = stepsCol.child(el().key("step-\(k)").wFull().h(28))
            }
            group = group.child(stepsCol)
        }
        let stack: El<FoldHeldState> = col().key("stack").wFull().growth(GrowthSpec())
            .child(el().key("before").wFull().h(200))
            .child(col().key("turn").wFull().foldGlide(Spring(duration: 0.18, bounce: 0.0)).child(group))
            .child(el().key("after").wFull().h(s.afterHeight))
        return col().key("scroll").size(300, 200).scroll(ScrollSpec(stickBottom: true)).child(stack)
    }

    private func shutFromStuckFrames(after: Float, offset: Float) -> [[String: Float]] {
        let rt = Runtime<FoldHeldState>(
            state: FoldHeldState(open: true, afterHeight: after),
            viewport: Vec2(300, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            makeFoldHeldEl(s)
        }
        var t = 0.0
        _ = rt.frame(at: t)
        rt.update(at: t) { _, tx in tx.scrollToInstant("scroll", x: 0, y: offset) }
        for _ in 0..<4 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        let hdr = rt.elements().first { $0.key == "hdr" && !$0.exiting }!
        let stuck = rt.stuckShiftsByPath[hdr.path]?.y ?? 0
        #expect(hdr.rect[1] == 0 && stuck > 400, "hdr stuck at top: rect=\(hdr.rect) stuck=\(stuck)")

        rt.update(at: t) { s, tx in
            s.open = false
            tx.keepOnScreen("hdr")
        }
        var frames: [[String: Float]] = []
        for _ in 0..<90 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            var row: [String: Float] = [:]
            for e in rt.elements() {
                guard let k = e.key else { continue }
                let shows = e.rect[1] < 200 && (e.rect[1] + e.rect[3]) > 28
                if k == "hdr" || k == "before" || k == "after" || (k.hasPrefix("step-") && shows) {
                    row[k] = e.rect[1]
                }
            }
            frames.append(row)
        }
        #expect(!rt.isAnimating && rt.scrollRequestsState.keeps.isEmpty, "settled after shut")
        return frames
    }

    private func biggestShownStep(_ frames: [[String: Float]], topBound: Float = -28, bottomBound: Float = 200) -> (Float, Int, String) {
        var most: (Float, Int, String) = (0, 0, "")
        for f in 1..<frames.count {
            let prev = frames[f - 1]
            let cur = frames[f]
            for (k, y1) in cur {
                guard let y0 = prev[k] else { continue }
                let seen0 = y0 > topBound && y0 < bottomBound
                let seen1 = y1 > topBound && y1 < bottomBound
                if (seen0 || seen1) && abs(y1 - y0) > most.0 {
                    most = (abs(y1 - y0), f, k)
                }
            }
        }
        return most
    }

    @Test("fold_glide: keep_on_screen_holds_a_stuck_header_while_its_fold_shuts")
    func keepOnScreenHoldsAStuckHeaderWhileItsFoldShuts() {
        let rt = Runtime<Bool>(state: true, viewport: Vec2(300, 200), pixelScale: 1.0, systemDark: true) { open, _ in
            makeFoldSectionEl(open, afterHeight: 100, includeTail: true)
        }
        var t = 0.0
        _ = rt.frame(at: t)
        rt.update(at: t) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 700) }
        for _ in 0..<4 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        let find: (String) -> ElementInfo = { k in
            rt.elements().first { $0.key == k && !$0.exiting }!
        }
        let hdrStuck = rt.stuckShiftsByPath[find("hdr").path]?.y ?? 0
        #expect(find("hdr").rect[1] == 0 && hdrStuck > 400, "header stuck: \(hdrStuck)")

        rt.update(at: t) { open, tx in
            open = false
            tx.keepOnScreen("hdr")
        }
        var after: [Float] = []
        for f in 0..<120 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            let hdr = find("hdr").rect[1]
            #expect(abs(hdr) < 0.5, "frame \(f): header moved to \(hdr)")
            let a = find("after").rect[1]
            #expect(a >= 28.0 - 0.5, "frame \(f): row below rose to \(a) over header")
            after.append(a)
        }
        let shown = Array(after.drop(while: { $0 >= 200.0 }))
        #expect(zip(shown, shown.dropFirst()).allSatisfy { $0.1 <= $0.0 + 0.5 }, "row below only rises once shown: \(after)")
        #expect(after[36] < 28.5, "reaches header on fold spring: \(after)")
        #expect(after.last == 28.0 && rt.scrollRequestsState.keeps.isEmpty && !rt.isAnimating, "\(after)")
    }

    @Test("fold_glide: a_fold_feathers_its_edge_shutting_too")
    func aFoldFeathersItsEdgeShuttingToo() {
        let rt = Runtime<Bool>(state: true, viewport: Vec2(400, 900), pixelScale: 2.0, systemDark: true) { open, _ in
            let row: El<Bool> = el().key("group").h(open ? 600 : 40).wFull()
                .foldGlide(Spring(duration: 0.18, bounce: 0.0))
                .foldFeather(16.0)
            return col().key("root").child(
                col().key("stack").growth(GrowthSpec())
                    .child(el().key("above").h(100).wFull())
                    .child(row)
            )
        }
        var t = 0.0
        _ = rt.frame(at: t)
        rt.update(at: t) { open, _ in open = false }
        var masks: [Float] = []
        for _ in 0..<60 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            let node = rt.flatNodes.first { $0.key == "group" }!
            let maskH = abs(node.el.clipFade?.w ?? 0)
            masks.append(maskH)
        }
        let peak = masks.max() ?? 0
        #expect(abs(peak - 16.0) < 1e-3, "shutting moving edge feathers \(peak) pt deep: \(masks)")
        #expect((masks.last ?? 1) == 0, "and nothing is feathered once it lands: \(masks)")
    }

    @Test("fold_glide: a_fold_shut_from_its_stuck_header_at_the_end_slides_up_under_it")
    func aFoldShutFromItsStuckHeaderAtTheEndSlidesUpUnderIt() {
        let frames = shutFromStuckFrames(after: 100, offset: 1100)
        let (most, at, _) = biggestShownStep(frames)
        #expect(most < 24.0, "nothing shown moves \(most) pt in frame \(at)")
        let after = frames.compactMap { $0["after"] }
        #expect(zip(after, after.dropFirst()).allSatisfy { $0.1 <= $0.0 + 0.01 }, "row below only rises")
        for f in 1..<frames.count {
            for (k, y1) in frames[f] where k.hasPrefix("step-") {
                if let y0 = frames[f - 1][k] {
                    #expect(y1 <= y0 + 0.01, "\(k) moves down \(y0) -> \(y1)")
                }
            }
        }
        let last = frames.last!
        #expect(abs((last["hdr"] ?? -1) - 72.0) < 0.01)
        #expect(abs((last["after"] ?? -1) - 100.0) < 0.01)
        #expect(abs((last["before"] ?? 0) - (-128.0)) < 0.01)
        #expect((frames[40]["hdr"] ?? 0) > 71.0, "lands on fold's own spring: \(frames[40])")
    }

    @Test("fold_glide: a_fold_shut_from_its_stuck_header_mid_timeline_still_glides")
    func aFoldShutFromItsStuckHeaderMidTimelineStillGlides() {
        let frames = shutFromStuckFrames(after: 300, offset: 1100)
        let (most, at, _) = biggestShownStep(frames)
        #expect(most < 24.0, "nothing shown moves \(most) pt in frame \(at)")
        #expect(frames.allSatisfy { abs($0["hdr"] ?? 1) < 0.01 }, "header holds")
        let after = frames.compactMap { $0["after"] }
        #expect(after[2] > 100.0 && after[12] < 100.0 && after[40] < 28.5, "glides rather than landing at once")
        #expect(frames[4].keys.contains(where: { $0.hasPrefix("step-") }), "steps still show as it shuts")
        #expect(abs((after.last ?? 0) - 28.0) < 0.01)
    }

    @Test("fold_glide: a_long_fold_shut_from_its_stuck_header_at_the_end_is_one_motion")
    func aLongFoldShutFromItsStuckHeaderAtTheEndIsOneMotion() {
        for short: Float in [130, 80, 40, 20, 8] {
            let rt = Runtime<FoldHeldState>(
                state: FoldHeldState(open: true, afterHeight: 100),
                viewport: Vec2(300, 200),
                pixelScale: 1.0,
                systemDark: true
            ) { s, _ in
                makeFoldHeldEl(s)
            }
            var t = 0.0
            _ = rt.frame(at: t)
            let maxExt = rt.scrollMaxExtents.values.first?.y ?? 0
            let offset = maxExt - short
            rt.update(at: t) { _, tx in tx.scrollToInstant("scroll", x: 0, y: offset) }
            for _ in 0..<4 {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
            }
            rt.update(at: t) { s, tx in
                s.open = false
                tx.keepOnScreen("hdr")
            }
            var frames: [(turnH: Float, els: [String: (y: Float, seen: Float, h: Float)])] = []
            for _ in 0..<120 {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
                let els = rt.elements()
                let turnH = els.first { $0.key == "turn" && !$0.exiting }!.rect[3]
                var map: [String: (y: Float, seen: Float, h: Float)] = [:]
                for e in els {
                    guard let k = e.key else { continue }
                    if k == "hdr" || k == "after" || k.hasPrefix("step-") {
                        map[k] = (e.rect[1], e.visible[3], e.rect[3])
                    }
                }
                frames.append((turnH, map))
            }
            #expect(!rt.isAnimating, "\(offset): settles")
            for f in 2..<frames.count {
                let spring = abs(frames[f].turnH - frames[f - 1].turnH)
                for (k, cur) in frames[f].els {
                    guard let prev1 = frames[f - 1].els[k], let prev2 = frames[f - 2].els[k] else { continue }
                    if cur.seen < 0.5 && prev1.seen < 0.5 { continue }
                    let v0 = prev1.y - prev2.y
                    let v = cur.y - prev1.y
                    #expect(abs(v) <= spring + 0.5, "\(offset): \(k) moves \(v) in frame \(f), fold \(spring)")
                    if cur.seen > 0.5 && abs(v0) > 2.0 {
                        let dir: Float = v0 >= 0 ? 1 : -1
                        #expect(v * dir >= 0.5 * abs(v0), "\(offset): \(k) jumped \(v0) -> \(v) in frame \(f)")
                    }
                }
            }
            let last = frames.last!.els
            for (k, endVal) in last where k.hasPrefix("step-") {
                var travelled: Float = 0
                for f in 1..<frames.count {
                    guard let p0 = frames[f - 1].els[k], let p1 = frames[f].els[k] else { continue }
                    if p0.seen >= p0.h - 0.5 { travelled += abs(p1.y - p0.y) }
                    #expect(!(travelled >= 40.0 && p0.seen > p0.h * 0.5 && p1.seen < 0.5 && abs(p1.y - endVal.y) < 0.5),
                            "\(offset): \(k) travelled \(travelled) in view then dropped in frame \(f)")
                }
            }
        }
    }

    @Test("fold_glide: a_fold_reopened_as_it_shuts_from_its_stuck_header_never_jumps")
    func aFoldReopenedAsItShutsFromItsStuckHeaderNeverJumps() {
        for (after, label) in [(Float(100), "at the end"), (Float(300), "mid-timeline")] {
            for at in [0, 1, 3, 8, 16, 30] {
                let rt = Runtime<FoldHeldState>(
                    state: FoldHeldState(open: true, afterHeight: after),
                    viewport: Vec2(300, 200),
                    pixelScale: 1.0,
                    systemDark: true
                ) { s, _ in
                    makeFoldHeldEl(s)
                }
                var t = 0.0
                _ = rt.frame(at: t)
                rt.update(at: t) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 1100) }
                for _ in 0..<4 {
                    t += 1.0 / 120.0
                    _ = rt.frame(at: t)
                }
                rt.update(at: t) { s, tx in
                    s.open = false
                    tx.keepOnScreen("hdr")
                }
                var frames: [[String: Float]] = []
                for f in 0..<(at + 120) {
                    if f == at {
                        rt.update(at: t) { s, tx in
                            s.open = true
                            tx.keepOnScreen("turn")
                        }
                    }
                    t += 1.0 / 120.0
                    _ = rt.frame(at: t)
                    let els = rt.elements()
                    let hdr = els.first { $0.key == "hdr" && !$0.exiting }!.rect[1]
                    for e in els where !e.exiting && (e.key?.hasPrefix("step-") ?? false) && e.visible[3] > 0.5 {
                        #expect(e.visible[1] >= hdr - 0.5, "\(label) at=\(at) f=\(f): \(e.key ?? "") shows at \(e.visible[1]) above hdr \(hdr)")
                    }
                    var row: [String: Float] = [:]
                    for e in els where !e.exiting {
                        guard let k = e.key else { continue }
                        if k == "hdr" || k == "before" || k == "after" || k.hasPrefix("step-") {
                            row[k] = e.rect[1]
                        }
                    }
                    frames.append(row)
                }
                #expect(!rt.isAnimating, "\(label) \(at): settles")
                let turn = rt.elements().first { $0.key == "turn" && !$0.exiting }!
                #expect(abs(turn.rect[3] - (28.0 + 40.0 * 28.0)) < 0.01, "ends fully open")
                let (most, f, key) = biggestShownStep(frames, topBound: -26, bottomBound: 198)
                #expect(most < 24.0, "\(label) reopened \(at) frames in: \(key) moves \(most) in frame \(f)")
                let last = frames.last!
                #expect(last["step-0"] != nil && (last["after"] ?? 0) > 0)
            }
        }
    }

    @Test("fold_glide: a_fold_shut_from_its_stuck_header_makes_no_jump_that_shows")
    func aFoldShutFromItsStuckHeaderMakesNoJumpThatShows() {
        for (after, tap) in [(Float(100), true), (Float(300), true), (Float(100), false), (Float(300), false)] {
            let rt = Runtime<FoldHeldState>(
                state: FoldHeldState(open: true, afterHeight: after),
                viewport: Vec2(300, 200),
                pixelScale: 1.0,
                systemDark: true
            ) { s, _ in
                makeFoldHeldEl(s)
            }
            let run = MotionGateRun(rt, hz: 120.0)
            run.rt.update(at: run.rt.currentTime) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 1100) }
            run.idle(0.1)
            run.step()
            if tap {
                run.actUpdate("shut") { s, tx in
                    s.open = false
                    tx.keepOnScreen("hdr")
                }
            } else {
                run.rt.update(at: run.rt.currentTime) { s, tx in
                    s.open = false
                    tx.keepOnScreen("hdr")
                }
                run.step()
            }
            run.play(0.75)
            let jumps = run.finish().filter { ["jump", "jerk", "offset-jump"].contains($0.kind) }
            #expect(jumps.isEmpty, "after \(after), tap \(tap): \(jumps)")
        }
    }

    @Test("fold_glide: a_fold_glide_row_that_leaves_shuts_at_once")
    func aFoldGlideRowThatLeavesShutsAtOnce() {
        func afterRemoval(fold: Bool, n: Int) -> [Float] {
            struct S { var present = true }
            let rt = Runtime<S>(state: S(), viewport: Vec2(400, 600), pixelScale: 2.0, systemDark: true) { s, _ in
                var stack: El<S> = col().key("stack").growth(GrowthSpec())
                    .child(el().key("above").h(100).wFull())
                if s.present {
                    var row: El<S> = el().key("group").h(40).wFull()
                    if fold { row = row.foldGlide(Spring(duration: 0.3, bounce: 0)) }
                    stack = stack.child(row)
                }
                stack = stack.child(el().key("below").h(100).wFull())
                return col().key("root").child(stack)
            }
            var t = 0.0
            _ = rt.frame(at: t)
            rt.update(at: t) { s, _ in s.present = false }
            return (0..<n).map { _ in
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
                return rt.elements().first { $0.key == "below" }!.rect[1]
            }
        }
        let fold = afterRemoval(fold: true, n: 12)
        #expect(fold[1] < 140.0 - 0.5, "fold starts shutting within two frames: \(fold)")
        #expect(zip(fold, fold.dropFirst()).allSatisfy { $0.1 <= $0.0 }, "shuts monotonically: \(fold)")
        let plain = afterRemoval(fold: false, n: 12)
        #expect(plain.allSatisfy { abs($0 - 140.0) < 1e-3 }, "plain row holds space while fading: \(plain)")
    }

    @Test("fold_glide: fold_rows_that_open_and_leave_together_step_monotonically")
    func foldRowsOpenTopToBottomAndLeaveBottomToTop() {
        func runBlock(opening: Bool, frames: Int) -> [([Float], Float)] {
            let rt = Runtime<Bool>(state: !opening, viewport: Vec2(400, 600), pixelScale: 2.0, systemDark: true) { present, _ in
                var stack: El<Bool> = col().key("stack").growth(GrowthSpec())
                    .child(el().key("above").h(100).wFull())
                if present {
                    for i in 0..<3 {
                        stack = stack.child(el().key("r\(i)").h(20).wFull().foldGlide(Spring(duration: 0.3, bounce: 0)))
                    }
                }
                stack = stack.child(el().key("below").h(100).wFull())
                return col().key("root").child(stack)
            }
            var t = 0.0
            _ = rt.frame(at: t)
            rt.update(at: t) { s, _ in s = opening }
            return (0..<frames).map { _ in
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
                let els = rt.elements()
                let h: (String) -> Float = { k in els.first { $0.key == k }?.rect[3] ?? 0 }
                let belowY = els.first { $0.key == "below" && !$0.exiting }!.rect[1]
                return ([h("r0"), h("r1"), h("r2")], belowY)
            }
        }

        let openFrames = runBlock(opening: true, frames: 90)
        for (k, (hs, _)) in openFrames.enumerated() {
            let part = hs.filter { $0 > 0.01 && $0 < 19.99 }.count
            #expect(part <= 1, "open frame \(k): one row at edge: \(hs)")
            #expect(zip(hs, hs.dropFirst()).allSatisfy { $0.1 <= 0.01 || $0.0 >= 19.99 }, "open frame \(k): \(hs)")
        }
        #expect(zip(openFrames, openFrames.dropFirst()).allSatisfy { $0.1.1 >= $0.0.1 })
        #expect(openFrames[8].0[0] > 19.99 && openFrames[8].0[2] < 0.01)
        #expect(openFrames.last!.0 == [20, 20, 20] && abs(openFrames.last!.1 - 160) < 0.01)

        let leaveFrames = runBlock(opening: false, frames: 90)
        for (k, (hs, _)) in leaveFrames.enumerated() {
            let part = hs.filter { $0 > 0.01 && $0 < 19.99 }.count
            #expect(part <= 1, "leave frame \(k): one row at edge: \(hs)")
        }
        #expect(zip(leaveFrames, leaveFrames.dropFirst()).allSatisfy { $0.1.1 <= $0.0.1 })
        #expect(leaveFrames[1].1 < 160.0)
        #expect(abs(leaveFrames.last!.1 - 100.0) < 1e-3)
    }
}
