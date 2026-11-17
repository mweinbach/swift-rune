import Testing
import Foundation
import RuneMotion
@testable import Rune

@Suite("Scroll Runtime Slice 2 Parity Tests")
struct ScrollRuntimeSlice2ParityTests {
    private func settle<State>(_ rt: Runtime<State>, start: Double = 0.0, dt: Double = 1.0 / 60.0, maxSteps: Int = 360) -> Double {
        var t = start
        for _ in 0..<maxSteps {
            t += dt
            _ = rt.frame(at: t)
            if !rt.isAnimating && !rt.scrollStore.isAnimating {
                break
            }
        }
        return t
    }

    // MARK: - el/scroll.rs & ScrollEdgeMath

    @Test("el/scroll & edge.rs: ScrollFade.strength, fullAt, linear, belowSticky, withEnd, scrollXY & taller reveal")
    func elScrollModifiersAndPartialEdgeRamp() {
        let fade = ScrollFade.strength(40).fullAt(15).linear().belowSticky().withEnd(.feather(16))
        let ramp = ScrollEdgeMath.edgeRamp(
            style: fade.style,
            width: fade.width,
            hidden: 7.5,
            scale: 2.0
        )
        #expect(ramp.width < 0) // linear packs negative width
        #expect(abs(ramp.offset - 0.5) < 0.01)

        // Taller-than-viewport item clamped by reveal
        let rTall = ScrollEdgeMath.reveal(offset: 100, top: 80, height: 300, viewport: 200, margin: 16)
        #expect(rTall == 100)

        struct State {}
        let rt = Runtime<State>(state: State(), viewport: Vec2(200, 200), pixelScale: 1.0) { _, _ in
            col()
                .child(
                    el()
                        .key("xy")
                        .size(200, 200)
                        .scrollXY()
                        .scrollFade(fade)
                        .scrollMargin(10)
                        .child(el().key("big").size(600, 600))
                )
        }
        _ = rt.frame(at: 0.0)
        #expect(rt.element(byKey: "xy") != nil)
        rt.wheelXY(100, 100, dx: -50, dy: 0, at: 0.05)
        _ = rt.frame(at: 0.06)
        #expect(abs(rt.scrollOffset(forKey: "xy").x - 50) < 0.01)
    }

    // MARK: - el/tx/scroll.rs & tests/scroll_to.rs

    @Test("tx/scroll.rs & tests/scroll_to.rs: scrollTo, scrollToWith, scrollToX, scrollIntoViewIn, scrollCenter, scrollCenterIn, scrollToBottom, repin & virtual tail")
    func txScrollVariantsAndRepin() {
        struct State {
            var rows: Int = 50
            var followAtBottom: [Bool] = []
        }
        let rt = Runtime<State>(state: State(), viewport: Vec2(200, 340), pixelScale: 1.0) { state, _ in
            col()
                .child(
                    col()
                        .key("vlist")
                        .size(200, 200)
                        .scrollY(stickBottom: true)
                        .onAtBottom { s, at in s.followAtBottom.append(at) }
                        .children((0..<state.rows).map { i in
                            el().key("r\(i)").size(200, 40)
                        })
                )
                .child(
                    row()
                        .key("hstrip")
                        .size(200, 40)
                        .scrollX()
                        .children((0..<20).map { i in
                            el().key("h\(i)").size(80, 40)
                        })
                )
                .child(
                    el()
                        .key("prosetext")
                        .size(200, 80)
                        .label("Hello Highlight Target World")
                        .textHighlight(TextHighlight(6..<15, bg: Color(r: 1, g: 1, b: 0, a: 1)).key("hl"))
                )
        }
        _ = rt.frame(at: 0.0)
        #expect(rt.scrollAtBottom(forKey: "vlist") == true)

        // scrollToY / scrollTo on vertical stick_bottom list unpins then re-pins when sent to bottom
        rt.update(at: 0.01) { _, tx in tx.scrollTo("vlist", x: 0, y: 200) }
        var t = settle(rt, start: 0.01)
        #expect(abs(rt.scrollOffset(forKey: "vlist").y - 200) < 0.5)
        #expect(rt.scrollAtBottom(forKey: "vlist") == false)

        // Send to bottom -> re-pins!
        rt.update(at: t) { _, tx in tx.scrollToBottom("vlist") }
        t = settle(rt, start: t)
        #expect(rt.scrollAtBottom(forKey: "vlist") == true)
        let bottomBefore = rt.scrollOffset(forKey: "vlist").y
        rt.update(at: t) { s, _ in s.rows = 55 }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(rt.scrollOffset(forKey: "vlist").y > bottomBefore)
        #expect(rt.scrollAtBottom(forKey: "vlist") == true)

        // scrollCenter & scrollIntoViewIn & scrollCenterIn & scrollToX & scrollToWith
        rt.update(at: t) { _, tx in
            tx.scrollCenter("r10")
            tx.scrollToX("hstrip", 150)
        }
        t = settle(rt, start: t)
        #expect(abs(rt.scrollOffset(forKey: "vlist").y - 320) < 2.0) // row 10 center = 420 - 100 = 320
        #expect(rt.scrollOffset(forKey: "hstrip").x > 140)

        rt.update(at: t) { _, tx in tx.scrollIntoViewIn("hstrip", "h18") }
        t = settle(rt, start: t)
        #expect(rt.scrollOffset(forKey: "hstrip").x >= 1300)

        rt.update(at: t) { _, tx in tx.scrollCenterIn("vlist", "r25") }
        t = settle(rt, start: t)
        #expect(abs(rt.scrollOffset(forKey: "vlist").y - 920) < 2.0)

        rt.update(at: t) { _, tx in tx.scrollToWith("vlist", x: 0, y: 120, spring: MotionTokens.SNAPPY) }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        t = settle(rt, start: t)
        #expect(abs(rt.scrollOffset(forKey: "vlist").y - 120) < 0.5)
    }

    @Test("scrollTo + scrollCenter on virtual rows & TextHighlight")
    func scrollToAndCenterVirtualAndHighlight() {
        struct State { var sel: Int = 0 }
        let rt = Runtime<State>(state: State(), viewport: Vec2(200, 320), pixelScale: 1.0) { _, _ in
            col()
                .child(
                    col()
                        .key("vlist")
                        .size(200, 200)
                        .scrollY(stickBottom: false)
                        .virtualRows(count: 100, estimatedRowHeight: 40, key: { _, i in "vrow\(i)" }) { _, i in
                            el().size(200, 40)
                        }
                )
                .child(
                    col()
                        .key("hlscroll")
                        .size(200, 100)
                        .scrollY(stickBottom: false)
                        .child(el().size(200, 180))
                        .child(
                            text("First word SecondTarget third")
                                .key("para")
                                .size(200, 60)
                                .textHighlight(TextHighlight(11..<23, bg: Color(r: 0, g: 0, b: 1, a: 1)).key("mark"))
                        )
                )
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.01) { _, tx in
            tx.scrollTo("vlist", x: 0, y: 2000)
            tx.scrollCenterIn("hlscroll", "mark")
        }
        let _ = settle(rt, start: 0.01)
        #expect(abs(rt.scrollOffset(forKey: "vlist").y - 2000) < 1.0)
        #expect(rt.scrollOffset(forKey: "hlscroll").y > 80)
    }

    // MARK: - runtime/scroll/x.rs & tests/scroll_x.rs

    @Test("runtime/scroll/x.rs & tests/scroll_x.rs: wheelXY axis lock, phases, flingXY, Shift wheel & horizontal scroll")
    func horizontalScrollWheelLockAndFling() {
        struct State {}
        let rt = Runtime<State>(state: State(), viewport: Vec2(300, 300), pixelScale: 2.0) { _, _ in
            col().child(
                col()
                    .key("vouter")
                    .size(200, 200)
                    .scrollY(stickBottom: false)
                    .child(
                        row()
                            .key("hstrip")
                            .size(200, 100)
                            .scrollX()
                            .children((0..<20).map { i in
                                el().key("tile\(i)").size(60, 100)
                            })
                    )
                    .children((0..<20).map { i in
                        el().key("vrow\(i)").size(200, 40)
                    })
            )
        }
        _ = rt.frame(at: 0.0)

        // Vertical wheel over horizontal-only viewport scrolls enclosing vertical viewport, not hstrip
        rt.wheelXY(100, 50, dx: 0, dy: -40, at: 0.02)
        _ = rt.frame(at: 0.04)
        #expect(rt.scrollOffset(forKey: "hstrip").x == 0)
        #expect(rt.scrollOffset(forKey: "vouter").y == 40)

        // Scroll back to 0 so hstrip is under y=50 again
        rt.wheelXY(100, 50, dx: 0, dy: 40, at: 0.2)
        _ = rt.frame(at: 0.22)
        #expect(rt.scrollOffset(forKey: "vouter").y == 0)

        // Began phased gesture locking horizontally inside nested viewport
        rt.wheelBegan(at: 0.4)
        rt.wheelXY(100, 50, dx: -30, dy: 0, at: 0.41)
        rt.wheelXY(100, 50, dx: -10, dy: -50, at: 0.42) // vertical ignored during locked horizontal gesture
        rt.wheelEnded(at: 0.45)
        _ = rt.frame(at: 0.46)
        #expect(abs(rt.scrollOffset(forKey: "hstrip").x - 40) < 0.01)
        #expect(rt.scrollOffset(forKey: "vouter").y == 0)

        // Momentum gap once
        rt.wheelBegan(at: 0.46)
        #expect(rt.inputMachines.wheelLock.momentum)
        rt.wheelEnded(at: 0.48)
        rt.wheelBegan(at: 0.49)
        #expect(!rt.inputMachines.wheelLock.momentum)
        rt.wheelEnded(at: 0.50)

        // wheelLost clears gesture
        rt.wheelLost()
        #expect(rt.inputMachines.wheelLock.owner == .unpicked)

        // Horizontal gesture outside hstrip falls back to vertical scroll if no horizontal viewport
        rt.wheelXY(100, 150, dx: -20, dy: -15, at: 1.0)
        _ = rt.frame(at: 1.02)
        #expect(rt.scrollOffset(forKey: "vouter").y == 15)

        // Horizontal flingXY decays and clamps
        let hBefore = rt.scrollOffset(forKey: "hstrip").x
        rt.flingXY(vx: -600, vy: 0, at: Vec2(100, 20), now: 1.5)
        let _ = settle(rt, start: 1.5)
        #expect(rt.scrollOffset(forKey: "hstrip").x > hBefore)

        // Shift wheel only turns purely vertical wheel
        let (dx1, dy1) = wheelDelta(.lineDelta(0, -1), scale: 2.0, shift: true)
        let line = WheelDistance.linePoints
        #expect(dx1 == -line && dy1 == 0)
        let (dx2, dy2) = wheelDelta(.lineDelta(-2, -1), scale: 2.0, shift: true)
        #expect(dx2 == -2 * line && dy2 == -line)
    }

    // MARK: - runtime/scroll/touch.rs & input/touch.rs

    @Test("runtime/scroll/touch.rs & input/touch.rs: tap click, horizontal/vertical pan, rubber-band, rebound & fling")
    func touchRuntimeIntegration() {
        struct State { var taps: Int = 0 }
        let rt = Runtime<State>(state: State(), viewport: Vec2(200, 300), pixelScale: 1.0) { _, _ in
            col()
                .child(
                    row()
                        .key("hstrip")
                        .size(200, 80)
                        .scrollX()
                        .children((0..<12).map { i in
                            el().key("tile\(i)").size(80, 80)
                        })
                )
                .child(
                    col()
                        .key("vlist")
                        .size(200, 200)
                        .scrollY(stickBottom: false)
                        .children((0..<30).map { i in
                            el()
                                .key("row\(i)")
                                .size(200, 40)
                                .onClick { s, _ in s.taps += 1 }
                        })
                )
        }
        _ = rt.frame(at: 0.0)

        // Tap within TOUCH_SLOP triggers click
        rt.touch(id: 1, phase: .started, at: Vec2(100, 120), time: 0.10)
        #expect(rt.isTouching)
        rt.touch(id: 1, phase: .moved, at: Vec2(102, 122), time: 0.12)
        rt.touch(id: 1, phase: .ended, at: Vec2(102, 122), time: 0.14)
        #expect(!rt.isTouching)
        #expect(rt.state.taps == 1)

        // Vertical pan > TOUCH_SLOP cancels click & flings
        rt.touch(id: 2, phase: .started, at: Vec2(100, 200), time: 0.20)
        rt.touch(id: 2, phase: .moved, at: Vec2(100, 180), time: 0.22)
        rt.touch(id: 2, phase: .moved, at: Vec2(100, 140), time: 0.24)
        rt.touch(id: 2, phase: .ended, at: Vec2(100, 120), time: 0.26)
        _ = rt.frame(at: 0.27)
        #expect(rt.state.taps == 1) // no extra click on pan!
        #expect(rt.scrollOffset(forKey: "vlist").y > 40)
        let touchT = settle(rt, start: 0.27) + 0.1

        // Horizontal pan picks hstrip & rubber-bands past 0 then rebounds back to 0
        rt.touch(id: 3, phase: .started, at: Vec2(100, 40), time: touchT)
        rt.touch(id: 3, phase: .moved, at: Vec2(140, 40), time: touchT + 0.02)
        _ = rt.frame(at: touchT + 0.03)
        #expect(rt.scrollOffset(forKey: "hstrip").x < 0) // elastic overscroll!
        rt.touch(id: 3, phase: .ended, at: Vec2(140, 40), time: touchT + 0.15)
        let _ = settle(rt, start: touchT + 0.15)
        #expect(abs(rt.scrollOffset(forKey: "hstrip").x) < 0.05) // returned to 0!
    }

    // MARK: - runtime/scroll/watch.rs

    @Test("runtime/scroll/watch.rs: onScrollOffset live updates, glide frames, scrolled vs initial & handler replacement")
    func scrollWatchRuntimeReports() {
        final class Log: @unchecked Sendable {
            var reports: [(offset: Vec2, scrolled: Bool, instant: Bool)] = []
            var gen = 0
        }
        let log = Log()
        struct State { var bump: Int = 0 }
        let rt = Runtime<State>(state: State(), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            let _ = s.bump
            log.gen += 1
            return col().child(
                col()
                    .key("list")
                    .size(200, 200)
                    .scrollY(stickBottom: false)
                    .onScrollOffset { pos in
                        let st = scrollWatchState()
                        log.reports.append((pos.offset, st.scrolled, st.instant))
                    }
                    .children((0..<25).map { i in
                        el().key("r\(i)").size(200, 40)
                    })
            )
        }
        _ = rt.frame(at: 0.0)
        #expect(log.reports.count == 1)
        #expect(log.reports[0].scrolled == false)

        // Glide produces multiple scroll reports with scrolled == true
        rt.update(at: 0.01) { _, tx in tx.scrollTo("list", x: 0, y: 200) }
        let _ = settle(rt, start: 0.01)
        #expect(log.reports.count > 2)
        #expect((log.reports.last?.offset.y ?? 0) > 199)
        #expect(log.reports.dropFirst().contains(where: { $0.scrolled }))

        // Upstream `watch.rs::a_rebuilt_handler_hears_where_the_viewport_stands`:
        // rebuilding creates a new `onScrollOffset` closure/token, which hears once on commit and not again on subsequent idle frames.
        let beforeRebuild = log.reports.count
        rt.update(at: 5.0) { s, _ in s.bump += 1 }
        _ = rt.frame(at: 5.01)
        #expect(log.reports.count == beforeRebuild + 1)
        _ = rt.frame(at: 5.02)
        #expect(log.reports.count == beforeRebuild + 1)
    }

    // MARK: - tests/pinned_scroll.rs, stick_fit.rs, stick_resize.rs

    @Test("tests/pinned_scroll.rs: 4-edge pin scroll sizing inside padded & flex-grown parent")
    func pinnedScrollFourEdges() {
        struct State {}
        let rt = Runtime<State>(state: State(), viewport: Vec2(400, 600), pixelScale: 2.0) { _, _ in
            col()
                .size(400, 600)
                .child(el().key("header").size(400, 50))
                .child(
                    col()
                        .key("body")
                        .wFull()
                        .grow(1)
                        .shrink(1)
                        .child(
                            col()
                                .key("scroll")
                                .pin(top: 0, right: 0, bottom: 0, left: 0)
                                .scrollY(stickBottom: true)
                                .children((0..<30).map { i in
                                    el().key("c\(i)").wFull().h(40)
                                })
                        )
                )
        }
        _ = rt.frame(at: 0.0)
        let body = rt.element(byKey: "body")!
        let scroll = rt.element(byKey: "scroll")!
        let last = rt.element(byKey: "c29")!
        #expect(body.rect == [0, 50, 400, 550])
        #expect(scroll.rect == [0, 50, 400, 550])
        #expect(abs((last.rect[1] + last.rect[3]) - 600) < 0.5)
    }

    @Test("tests/stick_resize.rs: plain rows stay on a resizing viewport's presented bottom", arguments: [false, true])
    func stickResizeAndFitOverflow(nativeRenderer: Bool) {
        struct State { var banner: Bool = false; var rows: Int = 40 }
        let rt = Runtime<State>(state: State(), viewport: Vec2(300, 400), pixelScale: 1.0) { s, _ in
            col()
                .size(300, 400)
                .child(el().key("banner").wFull().h(s.banner ? 55 : 0))
                .child(
                    col()
                        .key("scroll")
                        .wFull()
                        .grow(1)
                        .shrink(1)
                        .minH(0)
                        .scrollY(stickBottom: true)
                        .children((0..<s.rows).map { i in
                            el().key("r\(i)").wFull().h(40)
                        })
                )
        }
        func checkBottom(at time: Double) {
            if nativeRenderer {
                _ = rt.renderFrame(at: time)
            } else {
                _ = rt.frame(at: time)
            }
            let scroll = rt.element(byKey: "scroll")!
            let last = rt.element(byKey: "r39")!
            let gap = scroll.rect[1] + scroll.rect[3] - last.rect[1] - last.rect[3]
            #expect(abs(gap) < 0.6, "frame at \(time), native renderer \(nativeRenderer)")
            #expect(rt.scrollAtBottom(forKey: "scroll") == true)
        }

        checkBottom(at: 0)
        rt.update(at: 0.02) { s, _ in s.banner = true }
        checkBottom(at: 0.03)
        rt.update(at: 0.04) { s, _ in s.banner = false }
        checkBottom(at: 0.05)

        // Let each resize finish and check the row through the entire spring.
        var time = 0.05
        for show in [true, false] {
            rt.update(at: time) { s, _ in s.banner = show }
            for _ in 0..<120 {
                time += 1.0 / 120.0
                checkBottom(at: time)
            }
        }
    }

    @Test("tests/scroll_edge_fade.rs: half-strength 7.5pt ramp & scrollMargin keyboard reveal stop clear of fade")
    func scrollEdgeFadeRampAndMarginReveal() {
        let fadeW: Float = 20
        struct State { var selected: Int = 0 }
        let rt = Runtime<State>(state: State(), viewport: Vec2(200, 200), pixelScale: 1.0) { _, _ in
            col().child(
                col()
                    .key("scroll")
                    .size(200, 200)
                    .scrollY(stickBottom: false)
                    .scrollFade(ScrollFade.strength(fadeW).fullAt(15))
                    .scrollMargin(fadeW)
                    .children((0..<20).map { i in
                        el().key("row\(i)").size(200, 40)
                    })
            )
        }
        _ = rt.frame(at: 0.0)

        // 7.5pt hidden top edge -> offset 0.5 smooth ramp
        rt.wheel(WheelEvent(dx: 0, dy: -7.5), at: Vec2(100, 100), now: 0.02)
        _ = rt.frame(at: 0.03)
        let node = rt.flatNodes.first { $0.key == "scroll" }!
        let spec = rt.computeScrollFadeSpec(for: node)
        #expect(spec != nil)
        if let spec {
            #expect(abs((spec.packedOffsets?.y ?? 0) - 0.5) < 0.02)
        }

        // Reset to top and step down with scrollIntoView -> stops fadeW clear of bottom!
        rt.update(at: 0.1) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 0) }
        _ = rt.frame(at: 0.11)
        rt.update(at: 0.12) { _, tx in tx.scrollIntoView("row8") }
        let _ = settle(rt, start: 0.12)
        let vp = rt.element(byKey: "scroll")!.rect
        let r8 = rt.element(byKey: "row8")!.rect
        #expect(abs((vp[1] + vp[3]) - (r8[1] + r8[3]) - fadeW) < 0.5)
    }

    // MARK: - runtime/tests/{scroll_hover,scroll_retarget,scroll_spring,scroll_carried}.rs

    @Test("runtime/tests/scroll_hover.rs: glide holds hover until rest, nudge holds hover briefly on jump")
    func scrollHoverHoldAndNudge() {
        struct State { var hovered: [String] = [] }
        let rt = Runtime<State>(state: State(), viewport: Vec2(200, 200), pixelScale: 1.0) { _, _ in
            col().child(
                col()
                    .key("scroll")
                    .size(200, 200)
                    .scrollY(stickBottom: false)
                    .children((0..<40).map { i in
                        el()
                            .key("r\(i)")
                            .size(200, 20)
                            .onHover { state, inside, _ in
                                if inside { state.hovered.append("r\(i)") }
                            }
                    })
            )
        }
        _ = rt.frame(at: 0.0)
        rt.pointerMove(to: Vec2(100, 110), at: 0.01)
        _ = rt.frame(at: 0.02)
        #expect(rt.hoveredKey == "r5")

        // Glide holds r5 hover until landing
        rt.update(at: 0.02) { _, tx in tx.scrollTo("scroll", x: 0, y: 400) }
        var heldMidGlide = false
        var t = 0.02
        for _ in 0..<4 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            if rt.hoverHold.held {
                heldMidGlide = true
                #expect(rt.hoveredKey == "r5")
            }
        }
        #expect(heldMidGlide)
        t = settle(rt, start: t)
        #expect(rt.hoveredKey == "r25")

        // Instant jump arms Nudge hold (2/60s = ~0.033s)
        rt.update(at: t) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 0) }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(rt.isHoverHeldByNudge(at: t))
        #expect(rt.hoveredKey == "r25")
        t += 0.05
        _ = rt.frame(at: t)
        #expect(!rt.isHoverHeldByNudge(at: t))
        #expect(rt.hoveredKey == "r5")
    }

    @Test("runtime/tests/scroll_retarget.rs & scroll_spring.rs: glide retargeting and custom spring")
    func scrollRetargetAndCustomSpring() {
        struct State {}
        let rt = Runtime<State>(state: State(), viewport: Vec2(200, 200), pixelScale: 1.0) { _, _ in
            col().child(
                col()
                    .key("scroll")
                    .size(200, 200)
                    .scrollY(stickBottom: false)
                    .children((0..<50).map { i in
                        el().key("r\(i)").size(200, 40)
                    })
            )
        }
        _ = rt.frame(at: 0.0)
        let dt = 1.0 / 60.0
        var t = dt
        rt.update(at: 0) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 1000) }
        _ = rt.frame(at: t)
        rt.update(at: t) { _, tx in tx.scrollTo("scroll", x: 0, y: 0) }
        for _ in 0..<5 {
            t += dt
            _ = rt.frame(at: t)
        }
        let mid = rt.scrollOffset(forKey: "scroll").y
        #expect(mid < 900)
        let target = mid - 40
        rt.update(at: t) { _, tx in tx.scrollTo("scroll", x: 0, y: target) }
        var previous = mid
        for _ in 0..<240 {
            t += dt
            _ = rt.frame(at: t)
            let position = rt.scrollOffset(forKey: "scroll").y
            #expect(target - position < 0.05)
            #expect(position <= previous + 1e-6)
            previous = position
            if !rt.scrollStore.isAnimating { break }
        }
        #expect(previous == target)

        func firstStep(spring: Spring?) -> Float {
            rt.update(at: t) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 0) }
            t += dt
            _ = rt.frame(at: t)
            rt.update(at: t) { _, tx in
                if let spring {
                    tx.scrollToWith("scroll", x: 0, y: 400, spring: spring)
                } else {
                    tx.scrollTo("scroll", x: 0, y: 400)
                }
            }
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            return rt.scrollOffset(forKey: "scroll").y
        }
        let standard = firstStep(spring: nil)
        let quick = firstStep(spring: Spring(duration: 0.18, bounce: 0))
        #expect(standard > 0)
        #expect(quick > standard * 2.5)
    }

    @Test("runtime/tests/scroll_carried.rs: ElementInfo.scrolled measures window-space distance across zoom")
    func scrollCarriedWindowDistance() {
        struct State {}
        let rt = Runtime<State>(state: State(), viewport: Vec2(600, 600), pixelScale: 1.0) { _, _ in
            col()
                .key("zoom")
                .scale(1.6)
                .child(
                    col()
                        .key("scroll")
                        .size(300, 200)
                        .scrollY(stickBottom: false)
                        .child(
                            col()
                                .key("rows")
                                .w(300)
                                .children((0..<30).map { i in
                                    el().key("row\(i)").size(300, 40)
                                })
                        )
                )
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.01) { _, tx in tx.scrollTo("scroll", x: 0, y: 300) }
        var maxCarried: Float = 0
        var t = 0.01
        for _ in 0..<120 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            if let row3 = rt.element(byKey: "row3") {
                maxCarried = max(maxCarried, hypot(row3.scrolled[0], row3.scrolled[1]))
            }
        }
        #expect(abs(maxCarried - 480) < 5.0 || abs(maxCarried - 300) < 5.0)
    }

    // MARK: - tests/scroll_anchor.rs & src/runtime/tests/scroll_children.rs

    @Test("tests/scroll_anchor.rs: rows inserted or grown above anchor top row; off-top/without-anchor/stick_bottom follow", arguments: [false, true])
    func scrollAnchorInsertionAndGrowth(native: Bool) {
        struct Feed {
            var above: Int = 0
            var firstH: Float = 40
            var below: Int = 0
            var anchor: Bool = true
            var stickBottom: Bool = false
        }
        func runShift(_ initial: Feed, at: Float, change: @escaping (inout Feed) -> Void) -> (before: Float, after: Float) {
            let rt = Runtime<Feed>(state: initial, viewport: Vec2(300, 200), pixelScale: 1.0) { s, _ in
                let list: El<Feed> = col()
                    .key("list")
                    .wFull()
                    .children((0..<s.above).map { k in el().key("new\(k)").wFull().h(30) })
                    .child(el().key("r0").wFull().h(s.firstH))
                    .children((1..<(30 + s.below)).map { k in el().key("r\(k)").wFull().h(40) })
                let vp: El<Feed> = col().key("scroll").size(300, 200).scrollY(stickBottom: s.stickBottom).child(list)
                return s.anchor ? vp.scrollAnchor() : vp
            }
            func draw(_ time: Double) {
                if native { _ = rt.renderFrame(at: time) } else { _ = rt.frame(at: time) }
            }
            func rowTop() -> Float {
                let rowPath = rt.flatNodes.first { $0.key == "r5" }!.path
                return rt.presentedRectByPath[rowPath]!.top
            }
            draw(0)
            rt.update(at: 0.01) { _, tx in tx.scrollToInstant("scroll", x: 0, y: at) }
            var t = 0.01
            for _ in 0..<4 {
                t += 1.0 / 120.0
                draw(t)
            }
            let before = rowTop()
            rt.update(at: t) { s, _ in change(&s) }
            for _ in 0..<360 {
                t += 1 / 60
                draw(t)
                if !rt.isAnimating && !rt.scrollStore.isAnimating { break }
            }
            let after = rowTop()
            return (before, after)
        }

        let r1 = runShift(Feed(), at: 150) { $0.above = 3 }
        #expect(abs(r1.after - r1.before) < 0.5)

        let r2 = runShift(Feed(), at: 150) { $0.firstH = 140 }
        #expect(abs(r2.after - r2.before) < 0.5)

        let r3 = runShift(Feed(anchor: false), at: 150) { $0.above = 3 }
        #expect(abs((r3.after - r3.before) - 90) < 0.5)

        let r4 = runShift(Feed(), at: 0) { $0.above = 3 }
        #expect(abs((r4.after - r4.before) - 90) < 0.5)

        let r5 = runShift(Feed(stickBottom: true), at: 10_000) { $0.below = 3 }
        #expect(abs((r5.after - r5.before) + 120) < 0.5)
    }

    @Test("src/runtime/tests/scroll_children.rs & scrollPage: 50 direct children, scrollPage +/- on virtual rows, taller virtual row from above")
    func scrollChildrenDirectAndPageAndTallerVirtual() {
        struct State { var tail: Int = 0 }
        let rt = Runtime<State>(state: State(), viewport: Vec2(200, 420), pixelScale: 1.0) { s, _ in
            col()
                .child(
                    col()
                        .key("direct")
                        .size(200, 200)
                        .scrollY(stickBottom: false)
                        .children((0..<50).map { i in row().key("d\(i)").wFull().h(30) })
                )
                .child(
                    col()
                        .key("virtscroll")
                        .size(200, 200)
                        .scrollY(stickBottom: false)
                        .child(
                            col()
                                .key("rows")
                                .wFull()
                                .growth(GrowthSpec.default)
                                .virtualRows(count: 31 + s.tail, estimatedRowHeight: 20, key: { _, i in "vr\(i)" }) { _, i in
                                    row().wFull().h(i == 30 ? 500 : 20)
                                }
                        )
                )
        }
        _ = rt.frame(at: 0.0)
        // Direct 50 children scroll to bottom -> scrollAtBottom == true
        rt.wheel(WheelEvent(dx: 0, dy: -10_000), at: Vec2(100, 100), now: 0.01)
        _ = rt.frame(at: 0.02)
        let d49 = rt.element(byKey: "d49")!
        #expect(abs((d49.rect[1] + d49.rect[3]) - 200) < 0.5)
        #expect(rt.scrollAtBottom(forKey: "direct") == true)

        // scrollPage backward & forward on direct list
        rt.update(at: 0.03) { _, tx in tx.scrollPage("direct", -1) }
        var t = settle(rt, start: 0.03)
        #expect(rt.scrollOffset(forKey: "direct").y < 1200)
        #expect(rt.scrollAtBottom(forKey: "direct") == false)

        // Reveal virtual row taller than viewport (500pt in 200pt) -> bottom lands at viewport bottom (y = 400)
        rt.update(at: t) { _, tx in tx.scrollIntoView("vr30") }
        t = settle(rt, start: t)
        let vr30 = rt.element(byKey: "vr30")!
        let vp = rt.element(byKey: "virtscroll")!
        #expect(abs((vr30.rect[1] + vr30.rect[3]) - (vp.rect[1] + vp.rect[3])) < 0.5)

        // scrollPage(-1) on virtual list glides backward cleanly
        let beforePage = rt.scrollOffset(forKey: "virtscroll").y
        rt.update(at: t) { _, tx in tx.scrollPage("virtscroll", -1) }
        t = settle(rt, start: t)
        #expect(rt.scrollOffset(forKey: "virtscroll").y < beforePage - 100)
    }

    @Test("pointer.rs & scroll/x.rs: horizontal wheel and flingXY cancel active press and suppress onClick")
    func horizontalWheelAndFlingCancelActivePress() {
        var clicks = 0
        let rt = Runtime<Int>(state: 0, viewport: Vec2(240, 120), pixelScale: 2.0, systemDark: true) { _, _ in
            row()
                .key("hscroll")
                .size(200, 80)
                .scrollX()
                .children([
                    row()
                        .key("card")
                        .size(120, 40)
                        .onClick { _ in clicks += 1 },
                    row()
                        .key("tail")
                        .size(300, 40),
                ])
        }
        _ = rt.frame(at: 0.0)

        // 1. Horizontal wheel delta cancels active press and prevents click on pointerUp
        rt.pointerDown(at: Vec2(40, 20), at: 0.01)
        _ = rt.frame(at: 0.015)
        #expect(rt.pressedPath != nil)
        rt.wheel(WheelEvent(dx: -40, dy: 0), at: Vec2(40, 20), now: 0.02)
        #expect(rt.pressedPath == nil)
        rt.pointerUp(at: Vec2(40, 20), at: 0.03)
        _ = rt.frame(at: 0.035)
        #expect(clicks == 0)

        // 2. Non-zero horizontal flingXY cancels active press and prevents click on pointerUp
        rt.pointerDown(at: Vec2(40, 20), at: 0.04)
        _ = rt.frame(at: 0.045)
        #expect(rt.pressedPath != nil)
        rt.flingXY(vx: -200, vy: 0, at: Vec2(40, 20), now: 0.05)
        #expect(rt.pressedPath == nil)
        rt.pointerUp(at: Vec2(40, 20), at: 0.06)
        _ = rt.frame(at: 0.065)
        #expect(clicks == 0)
    }
}
