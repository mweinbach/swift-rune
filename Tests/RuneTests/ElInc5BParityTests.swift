import Testing
import Foundation
@testable import Rune
import RuneMotion

@Suite("El Increment 5B Deep Runtime Parity")
struct ElInc5BParityTests {
    private static let blue = Color(r: 0, g: 0, b: 1, a: 1)

    // MARK: - 1. live_colors_tests.rs: Smoothed Live Border

    @Test("live_colors: smoothed liveBorder springs smoothly and lands on target without view rebuilds")
    func smoothedLiveBorderSpringsAndLands() {
        struct S {
            var edge = Live<Color>(.white)
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 200)) { s, _ in
            el().size(200, 200).child(
                el().key("card")
                    .size(80, 40)
                    .bg(.black)
                    .border(1, .black)
                    .liveBorder(s.edge.smooth(Spring(duration: 0.25, bounce: 0)))
            )
        }
        _ = rt.frame(at: 0)
        let commitsBefore = rt.viewCommitCount

        rt.state.edge.set(Self.blue)
        let midScene = rt.frame(at: 0.03)
        #expect(rt.viewCommitCount == commitsBefore)
        #expect(rt.isAnimating)
        let midBorder = midScene.primitives.first(where: { $0.kind == .roundedRect && $0.rect[2] == 80 })?.border
        if let midBorder {
            #expect(midBorder.x > 0 && midBorder.x < 1)
            #expect(midBorder.z > 0.5)
        }

        var settledScene = midScene
        for step in 1...240 {
            settledScene = rt.frame(at: 0.03 + Double(step) / 120.0)
        }
        #expect(!rt.isAnimating)
        #expect(rt.viewCommitCount == commitsBefore)
        let endBorder = settledScene.primitives.first(where: { $0.kind == .roundedRect && $0.rect[2] == 80 })?.border
        if let endBorder {
            #expect(abs(endBorder.x) < 1e-3 && abs(endBorder.y) < 1e-3 && abs(endBorder.z - 1) < 1e-3)
        }
    }

    // MARK: - 2. visible_tests.rs: Viewport Visibility Thresholds

    @Test("visible: onVisible triggers once at 50% element or 50% viewport visibility and clears offscreen")
    func onVisibleReportsAtHalfThresholdOnScroll() {
        struct S {
            var log: [Bool] = []
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(400, 200)) { _, _ in
            col().key("scroll").size(400, 200).scrollY()
                .child(col().key("top").wFull().h(500))
                .child(col().key("demo").wFull().h(100).onVisible { st, on, _ in st.log.append(on) })
                .child(col().key("bottom").wFull().h(600))
        }
        _ = rt.frame(at: 0)
        _ = rt.frame(at: 0.01)
        #expect(rt.state.log.isEmpty)

        // Scroll to 330 -> top of demo at 170 in 200pt viewport -> 30 of 100 visible (< 50%)
        rt.update(at: 0.02) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 330) }
        _ = rt.frame(at: 0.03)
        #expect(rt.state.log.isEmpty)

        // Scroll to 360 -> 60 of 100 visible (>= 50%)
        rt.update(at: 0.04) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 360) }
        _ = rt.frame(at: 0.05)
        #expect(rt.state.log == [true])

        // Still on screen at 450 -> no duplicate report
        rt.update(at: 0.06) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 450) }
        _ = rt.frame(at: 0.07)
        #expect(rt.state.log == [true])

        // Scrolled completely off at 800 -> reports false
        rt.update(at: 0.08) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 800) }
        _ = rt.frame(at: 0.09)
        #expect(rt.state.log == [true, false])
    }

    @Test("visible: tall child covering >50% of viewport still triggers onVisible")
    func onVisibleTallChildCoveringHalfViewport() {
        struct S {
            var log: [Bool] = []
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(400, 200)) { _, _ in
            col().key("scroll").size(400, 200).scrollY()
                .child(col().key("top").wFull().h(300))
                .child(col().key("tall").wFull().h(1000).onVisible { st, on, _ in st.log.append(on) })
                .child(col().key("bottom").wFull().h(300))
        }
        _ = rt.frame(at: 0)
        #expect(rt.state.log.isEmpty)

        // Scroll to 250 -> tall starts at 50..200 (150pt visible >= 100pt = 50% of 200pt viewport)
        rt.update(at: 0.02) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 250) }
        _ = rt.frame(at: 0.03)
        #expect(rt.state.log == [true])
    }

    // MARK: - 3. press_moving.rs: Moving Button Under Still Pointer vs Moving Pointer

    private func runPressThenSlide(moveAfter: Vec2?) -> Int {
        struct S {
            var x: Float = 0
            var pressed = 0
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 100)) { s, _ in
            el().size(300, 100).child(
                el().key("button")
                    .size(40, 20)
                    .absolute(x: s.x, y: 0)
                    .onClick { st in st.pressed += 1 }
            )
        }
        _ = rt.frame(at: 0)
        rt.pointerMove(to: Vec2(20, 10), at: 0.01)
        rt.pointerDown(at: Vec2(20, 10), at: 0.02)
        rt.update(at: 0.03) { s, _ in s.x = 200 }
        _ = rt.frame(at: 0.04)
        let releaseAt = moveAfter ?? Vec2(20, 10)
        rt.pointerMove(to: releaseAt, at: 0.05)
        rt.pointerUp(at: releaseAt, at: 0.06)
        _ = rt.frame(at: 0.07)
        return rt.state.pressed
    }

    @Test("press_moving: button moving out from under still pointer still delivers press; moving pointer cancels")
    func pressMovingButtonAndMovingPointer() {
        #expect(runPressThenSlide(moveAfter: nil) == 1)
        #expect(runPressThenSlide(moveAfter: Vec2(25, 60)) == 0)
    }

    // MARK: - 4. element_info.rs: ElementInfo.stub Parity

    @Test("element_info: ElementInfo.stub matches plain keyed element metadata defaults")
    func elementInfoStubMatchesRealKeyedElement() {
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(100, 100)) { _, _ in
            el().key("send")
        }
        _ = rt.frame(at: 0)
        let real = rt.elements().first(where: { $0.key == "send" })
        #expect(real != nil)
        let stub = ElementInfo.stub("send")
        if let real {
            #expect(stub.key == real.key)
            #expect(stub.role == real.role)
            #expect(stub.opacity == real.opacity)
            #expect(stub.scale == real.scale)
            #expect(stub.blur == real.blur)
            #expect(stub.radius == real.radius)
            #expect(stub.fill == real.fill)
            #expect(stub.hover == real.hover)
            #expect(stub.press == real.press)
            #expect(stub.stuck == real.stuck)
            #expect(stub.itemSelected == real.itemSelected)
            #expect(stub.focusable == real.focusable)
        }
    }

    // MARK: - 5. virtual_list.rs: Gaps & Trailing Gap Removal

    @Test("virtual_list: gaps surround virtual window without a trailing gap and re-sum on gap changes")
    func virtualListGapsWithoutTrailingGap() {
        let vl = VirtualListState(defaultEstimate: 20, gap: 7, overscanPixels: 40, overscanCount: 1)
        let keys = (0..<100).map { "r\($0)" }
        vl.setKeys(keys, commit: 1, offset: nil, viewportHeight: 40)

        #expect(vl.totalHeight == 2693)
        #expect(vl.offsetForIndex(50)?.y == 1350)
        // Row 0 ends at 20, gap is 20..<27, so offset 21 reveals r1 at top 27.
        let fv = vl.firstVisible(offset: 21) { _ in true }
        #expect(fv?.key == "r1")
        #expect(fv?.top == 27)

        let win = vl.computeWindow(scrollY: 1350, viewportHeight: 40)
        let n = win.mountedRange.count
        let mountedContent = Float(n) * 20 + Float(max(0, n - 1)) * 7
        #expect(win.beforeHeight + mountedContent + win.afterHeight == 2693)
        #expect(win.beforeHeight == Float(win.mountedRange.lowerBound) * 27)

        vl.recordMeasuredHeight(35, forKey: "r0")
        #expect(vl.offsetForIndex(50)?.y == 1365)

        vl.gap = 3
        #expect(vl.totalHeight == 2312)

        vl.setKeys([], commit: 2, offset: nil, viewportHeight: 40)
        #expect(vl.totalHeight == 0)
    }

    // MARK: - 6. runtime/virtual/fill_resume_tests.rs: End-to-End Bounded Resume & Retirement

    private final class ThinningState {
        var builds = 0
        var short = false
        var gone = false
    }

    private func makeThinningRuntime() -> Runtime<ThinningState> {
        let viewport: Float = 200
        return Runtime<ThinningState>(state: ThinningState(), viewport: Vec2(400, viewport)) { s, _ -> El<ThinningState> in
            if s.gone {
                return el().key("empty").size(400, viewport)
            }
            let count = s.short ? 3 : 400
            let list: El<ThinningState> = col().key("scroll").size(300, viewport).scrollY().child(
                col().key("rows").wFull().growth(GrowthSpec.default).virtualRows(
                    count: count,
                    estimatedRowHeight: 20,
                    key: { _, i in "r\(i)" }
                ) { st, i in
                    st.builds += 1
                    let h: Float = st.builds <= 12 ? 20 : 4
                    return el().key("r\(i)").wFull().h(h).bg(.white)
                }
            )
            let other: El<ThinningState> = col().key("other").size(80, viewport).scrollY().child(
                col().key("other-rows").wFull().children(
                    (0..<60).map { i in el().key("o\(i)").wFull().h(20).bg(.white) }
                )
            )
            return row().size(400, viewport).child(list).child(other)
        }
    }

    private func driveUntilWait(_ rt: Runtime<ThinningState>) -> Double? {
        var now = 0.0
        for _ in 0..<400 {
            if case .waiting(_, let due, _, _) = rt.virtualFill.phase {
                return due
            }
            if let due = rt.nextWakeDeadline(after: now) {
                now = max(due, now + 1.0 / 120.0)
            } else {
                now += 1.0 / 120.0
            }
            _ = rt.frame(at: now)
        }
        return nil
    }

    @Test("virtual_fill: short idle list arms no wake; thinning list resumes past bound until visible filled")
    func virtualFillIdleAndThinningResume() {
        struct Short {}
        let shortRt = Runtime<Short>(state: Short(), viewport: Vec2(400, 200)) { _, _ in
            col().key("scroll").size(400, 200).scrollY().child(
                col().key("rows").wFull().virtualRows(
                    count: 5,
                    estimatedRowHeight: 20,
                    key: { _, i in "r\(i)" }
                ) { _, i in
                    el().key("r\(i)").wFull().h(20).bg(.white)
                }
            )
        }
        _ = shortRt.frame(at: 0)
        _ = shortRt.frame(at: 1.0 / 120.0)
        #expect(shortRt.nextWakeDeadline(after: 1.0 / 120.0) == nil)
        #expect(!shortRt.isAnimating)

        let rt = makeThinningRuntime()
        var now = 0.0
        var frames = 0
        while frames < 400 {
            frames += 1
            _ = rt.frame(at: now)
            if !rt.isAnimating {
                if let due = rt.nextWakeDeadline(after: now) {
                    now = max(due, now + 1.0 / 120.0)
                } else {
                    break
                }
            } else {
                now += 1.0 / 120.0
            }
        }
        #expect(frames > Int(VirtualFillStateMachine.fillFrames))
        #expect(rt.nextWakeDeadline(after: now) == nil)
    }

    @Test("virtual_fill: unmount/complete retires wait cleanly, replacement restarts, unrelated scroller keeps wait")
    func virtualFillRetireReplacementAndUnrelatedScroll() {
        // 1. Unmount while waiting -> wait retires, replacement starts filling
        let rt1 = makeThinningRuntime()
        let due1 = driveUntilWait(rt1)
        #expect(due1 != nil)
        if let due1 {
            rt1.update(at: due1 - 0.001) { s, _ in s.gone = true }
            _ = rt1.frame(at: due1)
            #expect(rt1.virtualFill.phase == .idle)
            #expect(rt1.nextWakeDeadline(after: due1) == nil)

            rt1.update(at: due1 + 1.0 / 120.0) { s, _ in s.gone = false }
            _ = rt1.frame(at: due1 + 2.0 / 120.0)
            #expect(rt1.virtualFill.isFilling)
        }

        // 2. Completing list (short = true) retires wait cleanly
        let rt2 = makeThinningRuntime()
        let due2 = driveUntilWait(rt2)
        #expect(due2 != nil)
        if let due2 {
            rt2.update(at: due2 - 0.001) { s, _ in s.short = true }
            _ = rt2.frame(at: due2)
            #expect(rt2.virtualFill.phase == .idle)
            #expect(rt2.nextWakeDeadline(after: due2) == nil)
        }

        // 3. Unrelated scroller keeps virtualFill in .waiting
        let rt3 = makeThinningRuntime()
        let due3 = driveUntilWait(rt3)
        #expect(due3 != nil)
        if let due3 {
            let tMid = max(0.01, due3 - 0.01)
            rt3.wheel(WheelEvent(dx: 0, dy: -60), at: Vec2(340, 100), now: tMid)
            _ = rt3.frame(at: tMid + 0.001)
            if case .waiting = rt3.virtualFill.phase {
                // Expected: unrelated scroller left virtualFill waiting
            } else {
                Issue.record("Expected virtualFill to remain in .waiting, got \(rt3.virtualFill.phase)")
            }
        }
    }

    // MARK: - 7. fold_glide.rs: Leaving Row & KeepOnScreen Under Stuck Header

    @Test("fold_glide: leaving foldGlide row collapses smoothly and keepOnScreen holds stuck header")
    func foldGlideLeavingAndKeepOnScreenStuckHeader() {
        struct S {
            var showFold = true
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 200)) { s, _ in
            col().key("scroll").size(300, 200).scrollY()
                .child(el().key("hdr").wFull().h(30).stickyTop().bg(.white))
                .child(
                    s.showFold
                        ? el().key("fold").wFull().h(120).foldGlide(Spring(duration: 0.25, bounce: 0)).bg(.white)
                        : el().key("after").wFull().h(20).bg(.white)
                )
        }
        _ = rt.frame(at: 0)
        rt.update(at: 0.02) { s, tx in
            s.showFold = false
            tx.keepOnScreen("hdr")
        }
        for step in 1...8 {
            _ = rt.frame(at: 0.02 + Double(step) * (1.0 / 60.0))
        }
        let hdr = rt.elements().first(where: { $0.key == "hdr" })
        #expect(hdr != nil)
        #expect((hdr?.rect[1] ?? -1) >= 0)
        for step in 9...40 {
            _ = rt.frame(at: 0.02 + Double(step) * (1.0 / 60.0))
        }
        #expect(rt.elements().first(where: { $0.key == "fold" }) == nil)
    }
}
