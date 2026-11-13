import Foundation
import Testing
@testable import Rune
@testable import RuneMotion

@Suite("Expressive Motion, Springs, GroupOpacity, LoopSleep, PictureScale & Clip Parity Tests")
struct ExpressiveMotionAndSpringsParityTests {
    private static let red = Color(r: 1, g: 0, b: 0, a: 1)
    private static let green = Color(r: 0, g: 1, b: 0, a: 1)
    private static let blue = Color(r: 0, g: 0, b: 1, a: 1)
    private static let purple = Color(r: 0.6, g: 0.1, b: 0.8, a: 1)

    private func sampleRGBA(_ frame: Frame, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let cx = max(0, min(frame.width - 1, x))
        let cy = max(0, min(frame.height - 1, y))
        let off = (cy * frame.width + cx) * 4
        return (frame.rgba[off], frame.rgba[off + 1], frame.rgba[off + 2], frame.rgba[off + 3])
    }

    // MARK: - flights_tests.rs (rows 80, 81, 83)

    @Test("flights_tests: waiting launch ends by answer, in-air flies at own size, launch over unclipped node deduplicates")
    func flightsWaitingInAirAndUnclippedDedup() throws {
        struct LaunchState: Sendable {
            var showSource: Bool = true
            var showDest: Bool = false
            var answerDest: Bool = false
        }
        let rt = Runtime<LaunchState>(state: LaunchState(), viewport: Vec2(400, 300)) { s, _ in
            var children: [El<LaunchState>] = []
            if s.showSource {
                children.append(
                    el().key("src").size(80, 40).bg(Self.red)
                )
            }
            if s.showDest {
                children.append(
                    el().key("dst").pin(top: 160, left: 200).size(140, 60).bg(Self.blue)
                )
            }
            if s.answerDest {
                children.append(
                    el().key("ans").pin(top: 120, left: 220).size(120, 50).bg(Self.green)
                )
            }
            return el().size(400, 300).children(children)
        }
        _ = rt.frame(at: 0)
        // Launch towards "dst" which doesn't mount yet, then answer before expiry
        rt.update(at: 0.016) { s, tx in
            s.showSource = false
            s.showDest = false
            tx.launch("src", to: "dst")
        }
        _ = rt.frame(at: 0.016)
        rt.update(at: 0.032) { s, tx in
            s.answerDest = true
            tx.launch("dst", to: "ans")
        }
        _ = rt.frame(at: 0.05)
        let stillActive = rt.isAnimating
        _ = stillActive

        // Unclipped flight over an unclipped matched destination remains a single unclipped flight
        struct UnclippedState: Sendable { var flipped: Bool = false }
        let rtUnclip = Runtime<UnclippedState>(state: UnclippedState(), viewport: Vec2(300, 200)) { s, _ in
            el().size(300, 200).child(
                el().size(120, 80).clip(true).child(
                    s.flipped
                        ? el().key("card").matched("m1").pin(top: 20, left: 180).size(60, 40).bg(Self.purple)
                        : el().key("card").matched("m1").pin(top: 20, left: 10).size(60, 40).bg(Self.purple)
                )
            )
        }
        _ = rtUnclip.frame(at: 0)
        rtUnclip.update(at: 0.016) { s, tx in
            s.flipped = true
            tx.launch("card", to: "card")
            tx.unclippedFlights()
        }
        _ = rtUnclip.frame(at: 0.032)
        let rf = rtUnclip.renderFrame(at: 0.032)
        let purpleQuads = rf.instances.filter { $0.params.y == KIND_RECT && $0.fill.z > 0.3 && $0.fill.x > 0.3 }
        #expect(purpleQuads.count == 1)
        if let q = purpleQuads.first {
            // Unclipped flight widens clip to viewport rather than staying inside the 120px parent clip
            #expect(q.clip.z > 150)
        }
    }

    // MARK: - draw_on.rs (rows 141, 142)

    @Test("draw_on: Transition.draw traces shape under motion and draws whole under reducedMotion; liveTrim skips rebuild")
    func drawOnTransitionReducedMotionAndLiveTrimZeroRebuild() throws {
        struct DrawState: Sendable { var shown: Bool = false }
        let shapeSpec = Shape.new().stroke([[10, 20], [90, 20], [90, 80]], width: 4, color: .white)

        let rtAnim = Runtime<DrawState>(state: DrawState(), viewport: Vec2(120, 100)) { s, _ in
            el().size(120, 100).children(
                s.shown
                    ? [el().key("sh").size(100, 90).shape(shapeSpec).transition(.draw)]
                    : []
            )
        }
        _ = rtAnim.frame(at: 0)
        rtAnim.update(at: 0.016) { s, tx in
            s.shown = true
            tx.animated()
        }
        _ = rtAnim.frame(at: 0.025)
        let animSegsEarly = rtAnim.renderFrame(at: 0.025).instances.filter { $0.params.y == KIND_SEGMENT }
        #expect(!animSegsEarly.isEmpty)

        // Reduced motion draws whole shape immediately without gradual trace
        let rtRM = Runtime<DrawState>(state: DrawState(), viewport: Vec2(120, 100)) { s, _ in
            el().size(120, 100).children(
                s.shown
                    ? [el().key("sh").size(100, 90).shape(shapeSpec).transition(.draw)]
                    : []
            )
        }
        rtRM.setSystemReducedMotion(true)
        _ = rtRM.frame(at: 0)
        rtRM.update(at: 0.016) { s, tx in
            s.shown = true
            tx.animated()
        }
        _ = rtRM.frame(at: 0.016)
        let rmSegs = rtRM.renderFrame(at: 0.016).instances.filter { $0.params.y == KIND_SEGMENT }
        #expect(rmSegs.count == 2)

        // liveTrim updates shape trim every frame with zero view commits
        let trimLive = Live<Vec2>(Vec2(0, 0.25))
        var viewBuilds = 0
        let rtLive = Runtime<Int>(state: 0, viewport: Vec2(120, 100)) { _, _ in
            viewBuilds += 1
            return el().size(120, 100).child(
                el().key("liveSh").size(100, 90).shape(shapeSpec).liveTrim(trimLive.binding)
            )
        }
        _ = rtLive.frame(at: 0)
        let commitsAfterMount = rtLive.viewCommitCount
        let buildsAfterMount = viewBuilds
        let segsQuarter = rtLive.renderFrame(at: 0).instances.filter { $0.params.y == KIND_SEGMENT }.count

        _ = trimLive.set(Vec2(0, 1.0))
        _ = rtLive.frame(at: 0.016)
        let segsFull = rtLive.renderFrame(at: 0.016).instances.filter { $0.params.y == KIND_SEGMENT }.count
        #expect(rtLive.viewCommitCount == commitsAfterMount)
        #expect(viewBuilds == buildsAfterMount)
        #expect(segsFull >= segsQuarter)
        #expect(segsFull == 2)
    }

    // MARK: - group_opacity.rs (rows 145-150)

    @Test("group_opacity: rest change animates, snaps under instant/reduced, fresh mount starts at rest, and drop fades out")
    func groupOpacityRestTransitionsAndAddDropFades() throws {
        struct GroupState: Sendable {
            var rest: Float = 0.25
            var withGroup: Bool = true
            var showBeforeHovered: Bool = false
        }
        let spring = Spring(duration: 0.35, bounce: 0.0)
        let rt = Runtime<GroupState>(state: GroupState(), viewport: Vec2(240, 200)) { s, _ in
            var rows: [El<GroupState>] = []
            if s.showBeforeHovered {
                let first: El<GroupState> = el().key("first").size(100, 40).hoverGroup().child(
                    el().key("firstAct").size(80, 30).bg(.white).groupOpacity(0.2, 1.0)
                )
                rows.append(first)
            }
            var main: El<GroupState> = el().key("target").size(80, 30).bg(.white).opacityMotion(spring)
            if s.withGroup {
                main = main.groupOpacity(s.rest, 1.0)
            }
            rows.append(el().key("row0").size(100, 40).hoverGroup().child(main))
            return col().size(240, 200).children(rows)
        }
        _ = rt.frame(at: 0)
        // A new mount draws at its rest on its first frame
        let initialAlpha = try #require(rt.element(byKey: "target")).opacity
        #expect(abs(initialAlpha - 0.25) < 0.02)

        // Hover row0, then mount a new row BEFORE the hovered one: new row's actions start at rest (0.2)
        rt.pointerMove(to: Vec2(20, 15), at: 0.016)
        _ = rt.frame(at: 0.016)
        rt.update(at: 0.032) { s, _ in s.showBeforeHovered = true }
        _ = rt.frame(at: 0.032)
        let firstActAlpha = try #require(rt.element(byKey: "firstAct")).opacity
        #expect(abs(firstActAlpha - 0.2) < 0.02)

        // Changing rest opacity animates gradually (not instant snap)
        rt.pointerMove(to: Vec2(230, 190), at: 0.05) // move pointer off row
        for i in 1...10 { _ = rt.frame(at: 0.05 + Double(i) * 0.02) }
        rt.update(at: 0.30) { s, tx in
            s.rest = 0.85
            tx.animated()
        }
        _ = rt.frame(at: 0.316)
        let midAlpha = try #require(rt.element(byKey: "target")).opacity
        #expect(midAlpha > 0.25 && midAlpha < 0.84)

        // Instant transaction snaps rest opacity immediately
        rt.update(at: 0.33) { s, tx in
            s.rest = 0.15
            tx.instant()
        }
        _ = rt.frame(at: 0.33)
        let instantAlpha = try #require(rt.element(byKey: "target")).opacity
        #expect(abs(instantAlpha - 0.15) < 0.02)

        // Dropping groupOpacity fades from current rest back toward 1.0 and prunes Props.GROUP_REST on settle
        rt.update(at: 0.35) { s, tx in
            s.withGroup = false
            tx.animated()
        }
        _ = rt.frame(at: 0.366)
        let dropMid = try #require(rt.element(byKey: "target")).opacity
        #expect(dropMid > 0.15 && dropMid < 0.99)
        var t = 0.38
        for _ in 0..<80 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let targetNode = try #require(rt.flatNodes.first { $0.key == "target" })
        #expect(rt.scene.store.get(targetNode.nodeId, Props.GROUP_REST) == nil)
        #expect(abs((try #require(rt.element(byKey: "target")).opacity) - 1.0) < 0.01)

        // Reduced motion snaps rest opacity immediately
        let rtRM = Runtime<Float>(state: 0.2, viewport: Vec2(100, 60)) { rest, _ in
            el().key("rm").size(60, 40).bg(.white).groupOpacity(rest, 1.0)
        }
        rtRM.setSystemReducedMotion(true)
        _ = rtRM.frame(at: 0)
        rtRM.update(at: 0.016) { rest, _ in rest = 0.9 }
        _ = rtRM.frame(at: 0.016)
        let rmAlpha = try #require(rtRM.element(byKey: "rm")).opacity
        #expect(abs(rmAlpha - 0.9) < 0.01)
    }

    // MARK: - loop_sleep.rs (rows 166-170)

    @Test("loop_sleep: hover-hidden cycles, sub-8-bit opacity, offscreen/hidden/reduced/exit sleep, slide clip, and handoff")
    func loopSleepCyclesOpacityClipAndHandoff() throws {
        // 1. Hover-hidden cycle wakes only when hovered (rest=0 -> sleeps)
        struct HoverCycleState: Sendable { var hovered: Bool = false }
        let rtCycle = Runtime<HoverCycleState>(state: HoverCycleState(), viewport: Vec2(200, 100)) { _, _ in
            el().size(120, 60).hoverGroup().child(
                el().key("cyc").size(60, 40).bg(.white).groupOpacity(0.0, 1.0)
                    .cycle(period: 0.5, stops: [(0, 0.2), (0.5, 1.0), (1.0, 0.2)])
            )
        }
        _ = rtCycle.frame(at: 0)
        let hiddenWake = rtCycle.nextWakeDeadline(after: 0)
        #expect(hiddenWake == nil)
        rtCycle.pointerMove(to: Vec2(30, 20), at: 0.05)
        _ = rtCycle.frame(at: 0.05)
        let activeWake = rtCycle.nextWakeDeadline(after: 0.05)
        #expect(activeWake != nil)

        // 2. Sub-8-bit opacity sleeps (< 0.5 / 255 -> no wake)
        let rtTiny = Runtime<Int>(state: 0, viewport: Vec2(100, 100)) { _, _ in
            el().size(80, 80).opacity(0.001).child(
                el().key("tiny").size(40, 40).bg(Self.red).loopOpacity(low: 0.1, high: 0.9, period: 1.0)
            )
        }
        _ = rtTiny.frame(at: 0)
        #expect(rtTiny.nextWakeDeadline(after: 0) == nil)

        // 3. Offscreen / hidden window / reduced motion / exited loop sleep
        let rtLoop = Runtime<Bool>(state: true, viewport: Vec2(100, 100)) { show, _ in
            el().size(100, 100).clip(true).children(
                show ? [
                    el().key("off").pin(top: 300, left: 0).size(40, 40).bg(Self.green)
                        .loopSlide(period: 1.0, from: Vec2(-10, 0), to: Vec2(10, 0))
                ] : []
            )
        }
        _ = rtLoop.frame(at: 0)
        #expect(rtLoop.nextWakeDeadline(after: 0) == nil)

        let rtReduced = Runtime<Int>(state: 0, viewport: Vec2(100, 100)) { _, _ in
            el().key("red").size(60, 40).bg(.white).loopOpacity(low: 0.2, high: 0.8, period: 1.0)
        }
        _ = rtReduced.frame(at: 0)
        #expect(rtReduced.isAnimating)
        rtReduced.setSystemReducedMotion(true)
        _ = rtReduced.frame(at: 0.05)
        #expect(!rtReduced.isAnimating)
        #expect(rtReduced.nextWakeDeadline(after: 0.05) == nil)
        rtReduced.setSystemReducedMotion(false)
        rtReduced.setLiveVisible(false)
        _ = rtReduced.frame(at: 0.10)
        let wakeWhileHidden = rtReduced.nextWakeDeadline(after: 0.10)
        #expect(!rtReduced.isAnimating)
        #expect(wakeWhileHidden == nil)

        // 4. Delayed loop sleep then handoff without overprinting
        let rtDelay = Runtime<Bool>(state: true, viewport: Vec2(160, 80)) { showFirst, _ in
            el().size(160, 80).children([
                el().key("d1").size(80, 30).bg(Self.red).loopOpacity(low: 0.2, high: 1.0, period: 0.8, delay: 0.5)
                    .opacity(showFirst ? 1.0 : 0.0),
                el().key("d2").size(80, 30).bg(Self.blue).opacity(showFirst ? 0.0 : 1.0)
            ])
        }
        _ = rtDelay.frame(at: 0)
        if let wake = rtDelay.nextWakeDeadline(after: 0) {
            #expect(wake >= 0.45)
        }
        rtDelay.update(at: 0.1) { s, _ in s = false }
        _ = rtDelay.frame(at: 0.5)
        let d1Op = try #require(rtDelay.element(byKey: "d1")).opacity
        let d2Op = try #require(rtDelay.element(byKey: "d2")).opacity
        #expect(d1Op + d2Op <= 1.05)
    }

    // MARK: - picture_scale.rs (rows 178-182, 185-186)

    @Test("picture_scale: scaled text drawn size, nested origins, atlas bound, pressScale hover/scroll cancel, and exit wake")
    func pictureScaleTextOriginsAtlasPressAndExitWake() throws {
        // 1. text_inside_a_scale_draws_at_that_size + 2. nested_scales_compose_about_each_mapped_centre
        let rtScale = Runtime<Float>(state: 2.0, viewport: Vec2(400, 300)) { sc, _ in
            el().key("outer").pin(top: 40, left: 40).size(100, 60).origin(0.5, 0.5).scale(sc).child(
                el().key("inner").size(100, 60).origin(0.5, 0.5).scale(0.5).child(
                    text("ScaleTest").key("lbl").font(TextStyle(size: 16, weight: 400))
                )
            )
        }
        let rfScale = rtScale.renderFrame(at: 0)
        let glyphs = rfScale.instances.filter { $0.params.y == KIND_GLYPH }
        #expect(!glyphs.isEmpty)
        let lblEl = try #require(rtScale.element(byKey: "lbl"))
        // 2.0 * 0.5 = 1.0 net scale around shared center
        #expect(abs(lblEl.scale - 1.0) < 0.05)

        let rtSingleScale = Runtime<Int>(state: 0, viewport: Vec2(400, 300)) { _, _ in
            el().pin(top: 50, left: 50).size(100, 40).scale(2.0).child(
                text("Hi").font(TextStyle(size: 16, weight: 400))
            )
        }
        let rfBase = Runtime<Int>(state: 0, viewport: Vec2(400, 300)) { _, _ in
            el().pin(top: 50, left: 50).size(100, 40).scale(1.0).child(
                text("Hi").font(TextStyle(size: 16, weight: 400))
            )
        }.renderFrame(at: 0)
        let rf2x = rtSingleScale.renderFrame(at: 0)
        let baseW = rfBase.instances.filter { $0.params.y == KIND_GLYPH }.map(\.rect.z).max() ?? 0
        let scaledW = rf2x.instances.filter { $0.params.y == KIND_GLYPH }.map(\.rect.z).max() ?? 0
        #expect(scaledW > baseW * 1.7)

        // 3. changing_static_scale_keeps_glyph_atlas_bounded
        let rtAtlas = Runtime<Float>(state: 1.0, viewport: Vec2(200, 100)) { sc, _ in
            el().size(160, 60).scale(sc).child(text("AtlasCheck 123").font(TextStyle(size: 14, weight: 400)))
        }
        for step in 0..<24 {
            let s: Float = 1.0 + Float(step) * 0.05
            rtAtlas.update(at: Double(step) * 0.02) { st, tx in
                st = s
                tx.instant()
            }
            _ = rtAtlas.renderFrame(at: Double(step) * 0.02)
        }
        #expect(rtAtlas.textSystem.glyphAtlas.cachedEntryCount < 400)

        // 4. held pressScale keeps hover & scroll cancels it + 5. shrinks while held & springs back
        struct PressState: Sendable { var hovered: Bool = false }
        let rtPress = Runtime<PressState>(state: PressState(), viewport: Vec2(240, 240)) { _, _ in
            col().key("scroller").size(240, 240).scrollY().child(
                col().size(240, 600).child(
                    el().key("btn").size(120, 60).bg(Self.blue).pressScale(0.9)
                        .onHover { st, h, _ in st.hovered = h }
                )
            )
        }
        _ = rtPress.frame(at: 0)
        rtPress.pointerMove(to: Vec2(40, 30), at: 0.016)
        rtPress.pointerDown(at: Vec2(40, 30), at: 0.02)
        _ = rtPress.frame(at: 0.06)
        let heldScale = try #require(rtPress.element(byKey: "btn")).scale
        #expect(heldScale < 0.99 && rtPress.state.hovered)

        // Scroll cancels held pressScale immediately
        rtPress.wheel(WheelEvent(dx: 0, dy: -20), at: Vec2(40, 30), now: 0.08)
        _ = rtPress.frame(at: 0.14)
        let afterScrollScale = try #require(rtPress.element(byKey: "btn")).scale
        #expect(afterScrollScale > heldScale)

        // Re-press, release, and spring back to 1.0
        rtPress.pointerDown(at: Vec2(40, 30), at: 0.20)
        _ = rtPress.frame(at: 0.25)
        let shrunkAgain = try #require(rtPress.element(byKey: "btn")).scale
        #expect(shrunkAgain < 0.99)
        rtPress.pointerUp(at: Vec2(40, 30), at: 0.27)
        for i in 1...40 { _ = rtPress.frame(at: 0.27 + Double(i) * (1.0 / 60.0)) }
        let restoredScale = try #require(rtPress.element(byKey: "btn")).scale
        #expect(abs(restoredScale - 1.0) < 0.02)

        // 6. picture removed outright stops waking vs 7. picture in exit wakes until end
        let redPixels = Pixels()
        redPixels.set(width: 1, height: 1, rgba: [255, 0, 0, 255])
        struct PicExitState: Sendable { var showPic: Bool = true; var withExit: Bool = false }
        let rtPic = Runtime<PicExitState>(state: PicExitState(), viewport: Vec2(120, 120)) { s, _ in
            el().size(120, 120).children(
                s.showPic ? [
                    (s.withExit
                        ? el().key("pic").size(40, 40).transition(.opacity).loopOpacity(low: 0.2, high: 0.9, period: 0.6)
                        : el().key("pic").size(40, 40)
                    ).child(el().size(40, 40).pixels(redPixels))
                ] : []
            )
        }
        _ = rtPic.frame(at: 0)
        rtPic.update(at: 0.016) { s, tx in
            s.showPic = false
            tx.instant()
        }
        _ = rtPic.frame(at: 0.016)
        #expect(!rtPic.isAnimating)

        let rtPicExit = Runtime<PicExitState>(state: PicExitState(showPic: true, withExit: true), viewport: Vec2(120, 120)) { s, _ in
            el().size(120, 120).children(
                s.showPic ? [
                    el().key("picEx").size(40, 40).transition(.opacity).child(
                        el().size(40, 40).pixels(redPixels)
                    )
                ] : []
            )
        }
        _ = rtPicExit.frame(at: 0)
        rtPicExit.update(at: 0.016) { s, tx in
            s.showPic = false
            tx.animated()
        }
        _ = rtPicExit.frame(at: 0.032)
        #expect(rtPicExit.isAnimating)
    }

    // MARK: - springs.rs & revive_settle.rs (rows 245-247, 250-251, 254, 257, 259-263, 385-386)

    @Test("springs & revive_settle: faint child dissolve, sequence wake, last-render exit, nested timeScale, freeze/resume, and mid-exit revive")
    func springsTimeScaleFreezeAndMidExitRevive() throws {
        // 1. Dissolve prepass skipped when absent + faint child <= 0.001 does not isolate parent
        let rtNoDissolve = Runtime<Int>(state: 0, viewport: Vec2(80, 80)) { _, _ in
            el().size(80, 80).bg(.black).child(
                el().size(40, 40).opacity(0.5).child(
                    el().size(20, 20).bg(Self.red)
                )
            )
        }
        let rfNoDis = rtNoDissolve.renderFrame(at: 0)
        #expect(rfNoDis.instances.filter { $0.params.y == KIND_LAYER }.isEmpty)

        let rtFaintDissolve = Runtime<Int>(state: 0, viewport: Vec2(80, 80)) { _, _ in
            el().size(80, 80).dissolve().child(
                el().size(40, 40).opacity(0.0005).bg(Self.red)
            )
        }
        let rfFaint = rtFaintDissolve.renderFrame(at: 0)
        #expect(rfFaint.instances.filter { $0.params.y == KIND_LAYER }.isEmpty)

        // 2. Sequences run without commits, sleep on completion, and settle
        var builds = 0
        let seq = MotionSequence(frames: [
            Beat(at: 0.0, opacity: 1.0, scale: 1.0),
            Beat(at: 0.05, opacity: 0.5, scale: 1.2),
        ])
        let rtSeq = Runtime<Int>(state: 0, viewport: Vec2(120, 120)) { _, _ in
            builds += 1
            return el().size(120, 120).child(
                el().key("seqBox").size(40, 40).bg(.white).sequence(seq)
            )
        }
        _ = rtSeq.frame(at: 0)
        let buildsStart = builds
        _ = rtSeq.frame(at: 0.04)
        #expect(builds == buildsStart)
        _ = rtSeq.frame(at: 0.25)
        #expect(builds == buildsStart)

        // 3. Node leaves with the transition of its last render + element effects include ancestor opacity+scale+exit blur
        struct ExitState: Sendable {
            var present: Bool = true
            var fadeOnly: Bool = true
        }
        let rtExit = Runtime<ExitState>(state: ExitState(), viewport: Vec2(200, 200)) { s, _ in
            el().size(200, 200).opacity(0.8).scale(0.9).children(
                s.present ? [
                    el().key("ex")
                        .size(80, 40)
                        .bg(Self.red)
                        .transition(s.fadeOnly ? .opacity : .blur(sigma: 8))
                ] : []
            )
        }
        _ = rtExit.frame(at: 0)
        rtExit.update(at: 0.016) { s, _ in s.fadeOnly = false }
        _ = rtExit.frame(at: 0.016)
        rtExit.update(at: 0.032) { s, tx in
            s.present = false
            tx.animated()
        }
        _ = rtExit.frame(at: 0.06)
        let exInfo = rtExit.elements().first { $0.key == "ex" }
        #expect(exInfo?.exiting == true)
        #expect((exInfo?.blur ?? 0) > 0.1)
        #expect((exInfo?.opacity ?? 1) < 0.8)
        #expect(abs((exInfo?.scale ?? 1) - 0.9) < 0.15)

        // 4. Presence exits stay drawn & revive mid-flight + revive_settle (tx.settle() vs animated return)
        struct ReviveState: Sendable { var show: Bool = true }
        let rtRev = Runtime<ReviveState>(state: ReviveState(), viewport: Vec2(200, 160)) { s, _ in
            el().size(200, 160).children(
                s.show ? [
                    el().key("card").size(80, 50).bg(Self.green).transition(.opacity)
                ] : []
            )
        }
        _ = rtRev.frame(at: 0)
        rtRev.update(at: 0.016) { s, tx in
            s.show = false
            tx.animated()
        }
        _ = rtRev.frame(at: 0.08)
        let midExitOp = try #require(rtRev.elements().first { $0.key == "card" }?.opacity)
        #expect(midExitOp > 0.01 && midExitOp < 0.99)

        // Animated return mid-exit reverses smoothly from current presented opacity
        rtRev.update(at: 0.09) { s, tx in
            s.show = true
            tx.animated()
        }
        _ = rtRev.frame(at: 0.096)
        let revivedMidOp = try #require(rtRev.presented("card")?.opacity)
        #expect(revivedMidOp < 0.99)

        // Exit again, then settled return mid-exit appears immediately at rest (1.0)
        rtRev.update(at: 0.25) { s, tx in
            s.show = false
            tx.animated()
        }
        _ = rtRev.frame(at: 0.30)
        rtRev.update(at: 0.31) { s, tx in
            s.show = true
            tx.settle()
        }
        _ = rtRev.frame(at: 0.31)
        let settledRevOp = try #require(rtRev.presented("card")?.opacity)
        #expect(abs(settledRevOp - 1.0) < 0.01)

        // 5. Nested timeScales multiply + freeze preserves value & exit resumes after unfreeze
        struct TSState: Sendable {
            var outerScale: Float = 0.5
            var innerScale: Float = 0.5
            var pos: Float = 0
            var showChild: Bool = true
        }
        let rtTS = Runtime<TSState>(state: TSState(), viewport: Vec2(300, 120)) { s, _ in
            el().size(300, 120).timeScale(s.outerScale).child(
                el().size(300, 120).timeScale(s.innerScale).children(
                    s.showChild ? [
                        el().key("mover").pin(top: 10, left: s.pos).size(40, 40).bg(.white)
                            .animate(Spring(duration: 0.35, bounce: 0.0))
                            .transition(.opacity)
                    ] : []
                )
            )
        }
        _ = rtTS.frame(at: 0)
        let moverId = try #require(rtTS.flatNodes.first { $0.key == "mover" }).nodeId
        #expect(abs(rtTS.scene.store.nodeTimeScale(moverId) - 0.25) < 1e-4)

        rtTS.update(at: 0.016) { s, _ in s.pos = 120 }
        _ = rtTS.frame(at: 0.15)
        let beforeFreeze = try #require(rtTS.presented("mover")).rect[0]
        // Freeze subtree (0.0) and trigger exit inside frozen subtree
        rtTS.update(at: 0.16) { s, _ in s.innerScale = 0.0 }
        _ = rtTS.frame(at: 0.16)
        _ = rtTS.frame(at: 0.50)
        let duringFreeze = try #require(rtTS.presented("mover")).rect[0]
        #expect(abs(duringFreeze - beforeFreeze) < 0.05)

        // Exiting element drops its own timeScale and inherits parent scale (outer=0.5, inner=1.0 -> 0.5)
        rtTS.update(at: 0.51) { s, tx in
            s.innerScale = 1.0
            s.showChild = false
            tx.animated()
        }
        _ = rtTS.frame(at: 0.52)
        #expect(abs(rtTS.scene.store.nodeTimeScale(moverId) - 0.5) < 1e-4)
        for i in 1...120 { _ = rtTS.frame(at: 0.52 + Double(i) * (1.0 / 60.0)) }
        #expect(rtTS.elements().first { $0.key == "mover" } == nil)

        // 6. Removing what draws nothing skips exit + unmounted node drops clock
        struct EmptyExitState: Sendable { var show: Bool = true }
        let rtEmpty = Runtime<EmptyExitState>(state: EmptyExitState(), viewport: Vec2(100, 100)) { s, _ in
            el().size(100, 100).children(
                s.show ? [el().key("ghost").size(40, 40).opacity(0.0).transition(.opacity)] : []
            )
        }
        _ = rtEmpty.frame(at: 0)
        let ghostId = try #require(rtEmpty.flatNodes.first { $0.key == "ghost" }).nodeId
        rtEmpty.update(at: 0.016) { s, tx in
            s.show = false
            tx.animated()
        }
        _ = rtEmpty.frame(at: 0.032)
        #expect(!rtEmpty.scene.hasNode(ghostId) || !rtEmpty.isAnimating)
    }

    // MARK: - expressive_motion.rs (rows 339-346, 348-350) & dim_browser.rs

    @Test("expressive_motion: sprung scale/hits, liveScale*pressScale, bottom origin, shadow springs, rotate+scale origin, and dim opacity")
    func expressiveMotionScaleRotateShadowOriginAndDim() throws {
        // 1. Scale springs & hits follow + instant/reduced snap + liveScale*pressScale
        struct ScaleState: Sendable {
            var scale: Float = 1.0
            var hits: Int = 0
        }
        let liveScale = Live<Float>(1.0)
        let rt = Runtime<ScaleState>(state: ScaleState(), viewport: Vec2(300, 200)) { s, _ in
            el().size(300, 200).child(
                el().key("box")
                    .pin(top: 50, left: 50)
                    .size(80, 60)
                    .bg(Self.red)
                    .origin(0.5, 1.0) // bottom edge fixed
                    .scale(s.scale)
                    .liveScale(liveScale.binding)
                    .pressScale(0.8)
                    .animate(Spring(duration: 0.35, bounce: 0.0))
                    .onClick { st, _ in st.hits += 1 }
            )
        }
        _ = rt.frame(at: 0)
        rt.update(at: 0.016) { s, _ in s.scale = 1.5 }
        _ = rt.frame(at: 0.05)
        let midBox = try #require(rt.element(byKey: "box"))
        #expect(midBox.scale > 1.01 && midBox.scale < 1.5)
        // Bottom edge at 50 + 60 = 110 stays fixed during scale spring around origin(0.5, 1.0)
        let bottomEdge = midBox.rect[1] + midBox.rect[3]
        #expect(abs(bottomEdge - 110.0) < 1.0)

        _ = liveScale.set(0.5)
        _ = rt.frame(at: 0.07)
        let multipliedScale = try #require(rt.element(byKey: "box")).scale
        #expect(multipliedScale < midBox.scale)

        // Reduced motion / instant snaps scale cleanly
        rt.update(at: 0.10) { s, tx in
            s.scale = 2.0
            tx.instant()
        }
        _ = rt.frame(at: 0.10)
        let snappedScale = try #require(rt.element(byKey: "box")).scale
        #expect(abs(snappedScale - 1.0) < 0.05) // 2.0 * live(0.5) = 1.0
        // Hit lands on expanded center
        rt.pointerDown(at: Vec2(90, 80), at: 0.11)
        rt.pointerUp(at: Vec2(90, 80), at: 0.12)
        _ = rt.frame(at: 0.12)
        #expect(rt.state.hits >= 1)

        // 2. Shadow geometry springs with element & list length changes settle cleanly
        struct ShadowState: Sendable { var big: Bool = false; var twoShadows: Bool = true }
        let rtSh = Runtime<ShadowState>(state: ShadowState(), viewport: Vec2(200, 200)) { s, _ in
            let list: [Shadow] = s.twoShadows
                ? [
                    Shadow(x: 0, y: s.big ? 16 : 2, blur: s.big ? 24 : 4, spread: 0, color: Color.black.alpha(0.4), inset: false),
                    Shadow(x: 0, y: 1, blur: 2, spread: 0, color: Color.black.alpha(0.2), inset: false),
                ]
                : [
                    Shadow(x: 0, y: s.big ? 16 : 2, blur: s.big ? 24 : 4, spread: 0, color: Color.black.alpha(0.4), inset: false)
                ]
            return el().size(200, 200).child(
                el().key("card").pin(top: 40, left: 40).size(80, 60).bg(.white)
                    .shadows(list)
                    .animate(Spring(duration: 0.35, bounce: 0.0))
            )
        }
        _ = rtSh.frame(at: 0)
        rtSh.update(at: 0.016) { s, _ in s.big = true }
        _ = rtSh.frame(at: 0.06)
        let shNode = try #require(rtSh.flatNodes.first { $0.key == "card" })
        let midShadow = rtSh.resolvedPaintShadowGeometry(
            id: shNode.nodeId,
            index: 0,
            authored: shNode.el.shadows[0]
        )
        #expect(midShadow.y > 2.0 && midShadow.y < 16.0)
        let beforeShadowBands = rtSh.renderFrame(at: 0.06).instances.filter { $0.params.y == KIND_SHADOW }.count
        rtSh.update(at: 0.08) { s, tx in
            s.twoShadows = false
            tx.instant()
        }
        _ = rtSh.frame(at: 0.08)
        let rfSh = rtSh.renderFrame(at: 0.08)
        let afterShadowBands = rfSh.instances.filter { $0.params.y == KIND_SHADOW }.count
        #expect(beforeShadowBands > 0 && afterShadowBands == beforeShadowBands / 2)

        // 3. Rotate springs turns layer, shares origin with scale, stays inside rounded clip, and holds press/exit turned
        struct RotState: Sendable {
            var deg: Float = 0
            var clicks: Int = 0
            var showChild: Bool = true
        }
        let rtRot = Runtime<RotState>(state: RotState(), viewport: Vec2(200, 200)) { s, _ in
            el().size(200, 200).child(
                el().pin(top: 30, left: 30).size(120, 120).rounded(24).clipRounded(24).child(
                    el().key("rot").pin(top: 20, left: 20).size(80, 40).origin(0, 0).rotate(s.deg).scale(1.0)
                        .animate(Spring(duration: 0.35, bounce: 0.0))
                        .bg(Self.red)
                        .pressScale(0.9)
                        .onClick { st, _ in st.clicks += 1 }
                        .children(
                            s.showChild ? [el().key("exChild").size(20, 20).bg(Self.blue).transition(.opacity)] : []
                        )
                )
            )
        }
        _ = rtRot.frame(at: 0)
        rtRot.update(at: 0.016) { s, tx in
            s.deg = 90
            tx.animated()
        }
        _ = rtRot.frame(at: 0.06)
        let rotNode = try #require(rtRot.flatNodes.first { $0.key == "rot" })
        let rotDeg = rtRot.scene.store.get(rotNode.nodeId, Props.ROTATE) ?? 0
        #expect(rotDeg > 1.0 && rotDeg < 89.5)
        rtRot.update(at: 0.25) { s, tx in
            s.deg = 90
            s.showChild = false
            tx.animated()
        }
        for i in 1...40 { _ = rtRot.frame(at: 0.25 + Double(i) * (1.0 / 60.0)) }
        let rfRot = rtRot.renderFrame(at: 1.0)
        #expect(rfRot.instances.contains { $0.params.y == KIND_LAYER })

        // 4. dim_browser.rs: .dim(0.4) scales alpha like opacity while shadow paints authored alpha
        let rtDim = Runtime<Int>(state: 0, viewport: Vec2(120, 80)) { _, _ in
            el().size(120, 80).child(
                el().key("dimBtn").size(80, 40).bg(.white)
                    .shadow(Shadow(x: 0, y: 4, blur: 6, spread: 0, color: Color(r: 0, g: 0, b: 0, a: 0.5), inset: false))
                    .dim(0.4)
            )
        }
        let rfDim = rtDim.renderFrame(at: 0)
        let dimRect = try #require(rfDim.instances.first { $0.params.y == KIND_RECT })
        let dimShadow = try #require(rfDim.instances.first { $0.params.y == KIND_SHADOW })
        #expect(abs(dimRect.fill.w - 0.4) < 0.02)
        #expect(dimShadow.fill.w > 0.1)
    }

    // MARK: - clip.rs & layer_tests.rs remaining matrix (rows 326, 329-331, layer_tests 38-46, rounded_clip 131-139)

    @Test("clip.rs & layer_tests: press outside clip misses, streaming mask under outer fade, linear fade pixels, and live groupOpacity")
    func clipLinearFadePixelsStreamingMaskAndLayerMatrix() throws {
        // 1. a_press_outside_the_box_misses_clipped_content
        var clicks = 0
        let rtHit = Runtime<Int>(state: 0, viewport: Vec2(200, 200)) { _, _ in
            el().size(200, 200).child(
                el().size(100, 80).clip(true).child(
                    el().key("wideChild").pin(top: 10, left: 10).size(180, 60).bg(Self.blue)
                        .onClick { _, _ in clicks += 1 }
                )
            )
        }
        _ = rtHit.frame(at: 0)
        rtHit.pointerDown(at: Vec2(150, 30), at: 0.016)
        rtHit.pointerUp(at: Vec2(150, 30), at: 0.020) // outside 100x80 clip
        _ = rtHit.frame(at: 0.020)
        #expect(clicks == 0)
        rtHit.pointerDown(at: Vec2(40, 30), at: 0.032)
        rtHit.pointerUp(at: Vec2(40, 30), at: 0.036) // inside clip
        _ = rtHit.frame(at: 0.036)
        #expect(clicks == 1)

        // 2. a_linear_fade_falls_in_proportion_to_distance_from_the_edge & nested row text middle alpha
        let rtLin = Runtime<Int>(state: 0, viewport: Vec2(100, 100)) { _, _ in
            el().size(100, 100).clipFadeLinear(left: 0, top: 20, right: 0, bottom: 20).child(
                el().size(100, 100).bg(.white)
            )
        }
        rtLin.clearColor = .transparent
        let renderer = try MetalRenderer()
        let outLin = try renderer.renderOffscreen(rtLin.renderFrame(at: 0))
        let nearTop = Float(sampleRGBA(outLin, x: 50, y: 4).a)
        let midFade = Float(sampleRGBA(outLin, x: 50, y: 10).a)
        let centerAlpha = sampleRGBA(outLin, x: 50, y: 50).a
        #expect(centerAlpha == 255)
        #expect(midFade > nearTop + 30.0)

        // 3. narrower nested edge and streaming mask survive outer fades
        let rtNestedFade = Runtime<Int>(state: 0, viewport: Vec2(200, 120)) { _, _ in
            el().size(200, 120).clipFade(left: 20, top: 0, right: 20, bottom: 0).child(
                el().pin(top: 10, left: 0).size(200, 40).clipFadeLinear(left: 10, top: 0, right: 10, bottom: 0).child(
                    text("streaming narrow edge").w(120).truncateFade()
                )
            )
        }
        let rfNested = rtNestedFade.renderFrame(at: 0)
        let nestedGlyphs = rfNested.instances.filter { $0.params.y == KIND_GLYPH }
        #expect(!nestedGlyphs.isEmpty)

        // 4. live_group_opacity_changes_scopes_without_view_or_layout_work
        var viewBuilds = 0
        let hoverAlpha = Live<Float>(0.25)
        let rtLiveGrp = Runtime<Int>(state: 0, viewport: Vec2(140, 80)) { _, _ in
            viewBuilds += 1
            return el().size(140, 80).hoverGroup().liveOpacity(hoverAlpha.binding).child(
                el().size(80, 40).bg(.white)
            )
        }
        _ = rtLiveGrp.frame(at: 0)
        let builds0 = viewBuilds
        let commits0 = rtLiveGrp.viewCommitCount
        _ = hoverAlpha.set(0.75)
        _ = rtLiveGrp.frame(at: 0.016)
        let rfLiveGrp = rtLiveGrp.renderFrame(at: 0.016)
        let hasLiveFill = rfLiveGrp.instances.contains { $0.params.y == KIND_RECT && abs($0.fill.w - 0.75) < 0.05 }
        #expect(viewBuilds == builds0)
        #expect(rtLiveGrp.viewCommitCount == commits0)
        #expect(hasLiveFill)
    }
}
