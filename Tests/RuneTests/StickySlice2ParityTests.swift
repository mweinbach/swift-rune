import Testing
import Foundation
import RuneMotion
@testable import Rune

@Suite("Sticky Slice 2 Parity Tests")
struct StickySlice2ParityTests {
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

    @Test("A gutter inherits the visible horizontal band across a vertical viewport")
    func nestedStickyGutterUsesItsAxisViewports() throws {
        let rt = Runtime<Void>(state: (), viewport: Vec2(200, 100), pixelScale: 1) { _, _ in
            let section: El<Void> = row().size(600, 32).shrink(0)
                .child(el().size(54, 24).shrink(0))
                .child(el().key("gutter").size(34, 24).shrink(0).stickyLeft(4))
            let inner: El<Void> = row().key("inner").size(220, 40).shrink(0).scrollX().child(section)
            let vertical: El<Void> = col().size(260, 80).shrink(0).scrollY().child(inner)
            return row().key("outer").size(200, 100).scrollX().child(
                row().size(760, 80).shrink(0)
                    .child(el().size(42, 32).shrink(0))
                    .child(vertical)
            )
        }

        _ = rt.renderFrame(at: 0)
        let initial = try #require(rt.element(byKey: "gutter"))
        #expect(initial.rect[0] == 96 && initial.stuck == 0)

        // The inner viewport starts at -18 and the outer viewport starts at 0.
        // The gutter stops four points inside the outer viewport.
        rt.update(at: 0.01) { _, tx in
            tx.scrollToInstant("outer", x: 60, y: 0)
            tx.scrollToInstant("inner", x: 96, y: 0)
        }
        _ = rt.renderFrame(at: 0.02)
        let pinned = try #require(rt.element(byKey: "gutter"))
        #expect(pinned.rect[0] == 4 && pinned.stuck == 64)

        rt.update(at: 0.03) { _, tx in tx.scrollToInstant("inner", x: 0, y: 0) }
        _ = rt.renderFrame(at: 0.04)
        let released = try #require(rt.element(byKey: "gutter"))
        #expect(released.rect[0] == 36 && released.stuck == 0)
    }

    @Test("tests/sticky.rs: stickyTop, stickyBottom, section boundary push-out, hit above siblings & drawnLayout")
    func stickyTopBottomPushOutAndHit() {
        final class Hits: @unchecked Sendable {
            var list: [String] = []
            var drawnY: Float = -1
        }
        let log = Hits()
        struct State {}
        let shadow = Shadow(x: 0, y: 1, blur: 0, color: Color(r: 0, g: 0, b: 0, a: 0.75))
        let rt = Runtime<State>(state: State(), viewport: Vec2(300, 200), pixelScale: 1.0) { _, _ in
            return col().wFull().hFull().child(
                col()
                    .key("scroll")
                    .w(300)
                    .h(200)
                    .scrollY(stickBottom: false)
                    .child(
                        col()
                            .wFull()
                            .child(el().key("lead").wFull().h(12))
                            .child(
                                col()
                                    .key("sec-0")
                                    .wFull()
                                    .pb(10)
                                    .child(
                                        col()
                                            .key("hdr-0")
                                            .wFull()
                                            .h(30)
                                            .bg(Color(r: 0.24, g: 0.24, b: 0.26, a: 1))
                                            .stickyTop(8)
                                            .stuckShadow(shadow)
                                            .onDrawnLayout { _, r in log.drawnY = r[1] }
                                            .onClick { _, _ in log.list.append("hdr-0") }
                                            .child(
                                                el()
                                                    .key("hdr-0-btn")
                                                    .w(60)
                                                    .h(20)
                                                    .onClick { _, _ in log.list.append("hdr-0-btn") }
                                            )
                                    )
                                    .child(
                                        el()
                                            .key("row-0")
                                            .wFull()
                                            .h(220)
                                            .onClick { _, _ in log.list.append("row-0") }
                                    )
                            )
                            .child(
                                col()
                                    .key("sec-1")
                                    .wFull()
                                    .child(
                                        el()
                                            .key("hdr-1")
                                            .wFull()
                                            .h(30)
                                            .bg(Color(r: 0.28, g: 0.28, b: 0.30, a: 1))
                                            .stickyTop(8)
                                    )
                                    .child(el().key("row-1").wFull().h(240))
                                    .child(
                                        el()
                                            .key("ftr-1")
                                            .wFull()
                                            .h(24)
                                            .bg(Color(r: 0.28, g: 0.28, b: 0.30, a: 1))
                                            .stickyBottom(6)
                                    )
                            )
                            .child(el().key("tail").wFull().h(300))
                    )
            )
        }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 0.01)
        let hdr0Start = rt.element(byKey: "hdr-0")!
        #expect(hdr0Start.rect[1] == 12)
        #expect(hdr0Start.stuck == 0)

        // Scroll past lead(12): hdr-0 sticks at inset 8
        rt.update(at: 0.02) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 100) }
        _ = rt.frame(at: 0.03)
        let hdr0Stuck = rt.element(byKey: "hdr-0")!
        #expect(abs(hdr0Stuck.rect[1] - 8) < 0.05)
        #expect(abs(hdr0Stuck.stuck - 96) < 0.5)
        #expect(abs(log.drawnY - 8) < 0.05)

        // Click on sticky header child hits hdr-0-btn above row-0!
        rt.pointerMove(to: Vec2(30, 18), at: 0.04)
        rt.pointerDown(at: Vec2(30, 18), at: 0.04)
        rt.pointerUp(at: Vec2(30, 18), at: 0.05)
        _ = rt.frame(at: 0.06)
        #expect(log.list == ["hdr-0-btn"])

        // Scroll near end of sec-0: hdr-0 pushes out at sec-0 content bottom (262 - offset)
        // At offset = 230, sec-0 content bottom is at 262 - 230 = 32, so hdr-0 pushed to y = 2.
        rt.update(at: 0.07) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 230) }
        _ = rt.frame(at: 0.08)
        let hdr0Pushed = rt.element(byKey: "hdr-0")!
        #expect(abs(hdr0Pushed.rect[1] - 2) < 0.5)

        // ftr-1 stickyBottom holds at 200 - 6 - 24 = 170 when sec-1 overlaps bottom
        let ftr1 = rt.element(byKey: "ftr-1")!
        #expect(abs(ftr1.rect[1] - 170) < 0.5)
        #expect(ftr1.stuck < 0)
    }

    @Test("tests/sticky_showing.rs: stickyTopShowing tail remains visible and follows grow/shrink")
    func stickyTopShowingTailBehavior() {
        struct S { var head: Float = 100 }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 300), pixelScale: 1.0) { (s: S, _) -> El<S> in
            let page: El<S> = col()
                .wFull()
                .child(el().key("head").wFull().h(s.head).stickyTopShowing(20))
                .child(el().key("body").wFull().h(1000))
            return col().wFull().hFull().child(
                col().key("scroll").w(300).h(200).scrollY(stickBottom: false).child(page)
            )
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.01) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 50) }
        _ = rt.frame(at: 0.02)
        #expect(rt.element(byKey: "head")!.rect[1] == -50)

        rt.update(at: 0.03) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 300) }
        _ = rt.frame(at: 0.04)
        #expect(rt.element(byKey: "head")!.rect[1] == -80) // bottom 20 visible at y=20

        rt.update(at: 0.05) { s, tx in s.head = 140; tx.instant() }
        _ = rt.frame(at: 0.06)
        #expect(rt.element(byKey: "head")!.rect[1] == -120)

        var t = 0.06
        rt.update(at: t) { s, _ in s.head = 60 }
        for _ in 0..<40 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            let r = rt.element(byKey: "head")!.rect
            #expect(abs((r[1] + r[3]) - 20) < 0.1)
        }
        #expect(abs(rt.element(byKey: "head")!.rect[1] - (-40)) < 0.05)
    }

    @Test("sticky.rs: stickyLeft, nested scrollers, anchored viewport clamping & tooltip follow drawn rect")
    func stickyLeftNestedAnchoredTooltipAndInert() {
        struct S {
            var pressed: Int = 0
            var off: Live<Vec2> = Live(.zero)
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 200), pixelScale: 1.0) { s, _ in
            col().size(300, 200)
                .child(
                    col().key("scroll").size(300, 200).scrollXY()
                        .child(
                            col().key("content").minW(1000)
                                .child(
                                    row().key("header").w(300).h(30).justifyEnd().itemsCenter()
                                        .bg(Color.white).stickyLeft(0).liveOffset(s.off.binding)
                                        .child(
                                            el().key("action").size(40, 20).focusable(true).help("Run action")
                                                .onClick { state, _ in state.pressed += 1 }
                                        )
                                )
                                .child(el().wFull().h(600))
                        )
                )
                .child(el().key("pop").size(50, 20).anchored("action", side: .bottom, align: .end, gap: 0))
        }
        _ = rt.frame(at: 0.0)
        rt.wheelXY(100, 100, dx: -250, dy: 0, at: 0.02)
        let _ = settle(rt, start: 0.03)
        let h = rt.element(byKey: "header")!
        #expect(abs(h.rect[0] - 0) < 0.05)
        #expect(abs(h.stuck - 250) < 0.5)

        let action = rt.element(byKey: "action")!
        #expect(action.rect == [260, 5, 40, 20])
        let pop = rt.element(byKey: "pop")!
        #expect(abs(pop.rect[0] - 242) < 0.5) // kept 8pt inside 300pt viewport!

        // Tooltip & click follow shifted sticky action
        rt.pointerMove(to: Vec2(280, 15), at: 0.2)
        _ = rt.frame(at: 0.2)
        _ = rt.frame(at: 1.0)
        #expect(rt.helpTooltip()?.text == "Run action")
        rt.pointerDown(at: Vec2(280, 15), at: 1.01)
        rt.pointerUp(at: Vec2(280, 15), at: 1.02)
        _ = rt.frame(at: 1.03)
        #expect(rt.state.pressed == 1)

        // Live offset translates from stuck position
        rt.state.off.set(Vec2(-12, 4))
        _ = rt.frame(at: 1.04)
        let hMoved = rt.element(byKey: "header")!
        #expect(abs(hMoved.rect[0] - (-12)) < 0.1)
        #expect(abs(hMoved.rect[1] - 4) < 0.1)
        #expect(abs(hMoved.stuck - 250) < 0.5)
    }

    @Test("tests/sticky.rs: stuckCover in scrollIntoView, z-order headers after rows & declarative fade exemption")
    func stickyRevealClearanceFadeExemptionAndZOrder() {
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 200), pixelScale: 1.0) { (_, _) -> El<S> in
            col().key("scroll").size(300, 200).scrollY(stickBottom: false).scrollFade(.strength(16))
                .child(
                    col().wFull()
                        .child(el().key("hdr").wFull().h(40).bg(Color(r: 1, g: 0, b: 0, a: 1)).stickyTop(0))
                        .child(el().key("r0").wFull().h(80).bg(Color(r: 0, g: 1, b: 0, a: 1)))
                        .child(el().key("r1").wFull().h(80).bg(Color(r: 0, g: 1, b: 0, a: 1)))
                        .child(el().key("r2").wFull().h(80).bg(Color(r: 0, g: 1, b: 0, a: 1)))
                        .child(el().key("r3").wFull().h(80).bg(Color(r: 0, g: 1, b: 0, a: 1)))
                )
        }
        let s0 = rt.frame(at: 0.0)
        // Fade exemption is declarative at shift == 0: header top fade width is 0!
        if let hdrPrim = s0.primitives.first(where: { $0.fill.x > 0.9 && $0.fill.y < 0.1 }) {
            // top edge dir = (0, 1) -> if exempted on top, fade should not carry top fade
            #expect(!(hdrPrim.fade.x == 0 && hdrPrim.fade.y == 1 && hdrPrim.fade.z > 0))
        }

        rt.update(at: 0.01) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 150) }
        let s1 = rt.frame(at: 0.02)
        #expect(rt.element(byKey: "hdr")!.rect[1] == 0)
        #expect(rt.element(byKey: "r1")!.rect[1] == -30)

        // Header primitive renders AFTER row primitives (z-order sticky above rows)
        if let hdrIdx = s1.primitives.firstIndex(where: { $0.fill.x > 0.9 && $0.fill.y < 0.1 }),
           let lastRowIdx = s1.primitives.lastIndex(where: { $0.fill.y > 0.9 && $0.fill.x < 0.1 }) {
            #expect(hdrIdx > lastRowIdx)
        }

        // scrollIntoView lands r1 clear of the 40pt stuck header!
        rt.update(at: 0.03) { _, tx in tx.scrollIntoView("r1") }
        let _ = settle(rt, start: 0.03)
        #expect(rt.element(byKey: "hdr")!.rect[1] == 0)
        #expect(abs(rt.element(byKey: "r1")!.rect[1] - 40) < 0.5)
    }

    @Test("sticky without vertical viewport is a no-op")
    func stickyWithoutVerticalViewportIsNoOp() {
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 200), pixelScale: 1.0) { _, _ in
            col().size(300, 200).scrollX().child(
                col().w(600)
                    .child(el().key("top").size(50, 30).stickyTop(20))
                    .child(el().key("bottom").size(50, 30).stickyBottom(20))
            )
        }
        _ = rt.frame(at: 0.0)
        rt.wheelXY(100, 100, dx: -50, dy: 0, at: 0.02)
        _ = rt.frame(at: 0.03)
        #expect(rt.element(byKey: "top")!.stuck == 0)
        #expect(rt.element(byKey: "bottom")!.stuck == 0)
    }

    @Test("tests/sticky.rs: inert sticky passes input & focus through, tooltip follows drawn rect")
    func inertStickyPassesInputFocusAndTooltips() {
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 200), pixelScale: 1.0) { _, _ in
            col().key("scroll").size(300, 200).scrollY(stickBottom: false).child(
                col().wFull()
                    .child(el().key("hdr").wFull().h(30).stickyTop(0).help("header").focusable(true))
                    .child(el().key("inert").absolute(x: 0, y: 0).size(300, 30).stickyTop(0).inert().focusable(true))
                    .child(el().wFull().h(600))
            )
        }
        _ = rt.frame(at: 0.0)
        rt.wheelXY(100, 100, dx: 0, dy: -100, at: 0.01)
        _ = rt.frame(at: 0.02)
        rt.cxSettings.fullKeyboardAccess = true
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.03)
        _ = rt.frame(at: 0.04)
        #expect(rt.element(byKey: "hdr")?.focused == true)
        #expect(rt.element(byKey: "inert")?.focused == false)
        rt.pointerMove(to: Vec2(100, 15), at: 0.05)
        _ = rt.frame(at: 0.06)
        _ = rt.frame(at: 0.70)
        #expect(rt.helpTooltip()?.text == "header")
        if let tip = rt.helpTooltip()?.rect {
            let hdrH = rt.element(byKey: "hdr")!.rect[3]
            #expect(abs(tip[1] - hdrH - 6.0) < 0.05)
        }
    }

    @Test("tests/sticky.rs: virtual_rows keep_on_screen keeps stuck header across collapse & expand")
    func virtualRowsKeepStuckHeaderAcrossCollapseAndExpand() {
        struct CollapseApp {
            var collapsed = [Bool](repeating: false, count: 8)
        }
        let rt = Runtime<CollapseApp>(state: CollapseApp(), viewport: Vec2(320, 200), pixelScale: 1.0) { _, _ in
            col().wFull().hFull().child(
                col().key("scroll").w(320).h(200).scrollY(stickBottom: false).child(
                    col().key("list").wFull().growth(GrowthSpec.default).virtualRows(
                        count: 8,
                        estimatedRowHeight: 160,
                        key: { _, i in "sec-\(i)" },
                        build: { (s: CollapseApp, i: Int) -> El<CollapseApp> in
                            let collapsed = s.collapsed[i]
                            let hdrKey = "hdr-\(i)"
                            var sec: El<CollapseApp> = col().wFull().child(
                                el().key(hdrKey)
                                    .wFull()
                                    .h(32)
                                    .bg(Color(r: 0.2, g: 0.2, b: 0.3, a: 1))
                                    .stickyTop(0)
                                    .onClick { (s: inout CollapseApp, tx: inout Tx) in
                                        s.collapsed[i].toggle()
                                        tx.keepOnScreen(hdrKey)
                                    }
                            )
                            if !collapsed {
                                sec = sec.child(el().key("body-\(i)").wFull().h(600))
                            }
                            return sec
                        }
                    )
                )
            )
        }
        var t = 0.0
        _ = rt.frame(at: t)
        rt.wheelXY(160, 100, dx: 0, dy: -1050, at: 0.01)
        for _ in 0..<8 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        let h1Initial = rt.element(byKey: "hdr-1")!
        #expect(abs(h1Initial.rect[1] - 0) < 0.5)
        #expect(abs(h1Initial.stuck - 418) < 1.0)

        // Click hdr-1 at y=16 to collapse sec-1 (632 -> 32)
        rt.pointerDown(at: Vec2(100, 16), at: t + 0.005)
        rt.pointerUp(at: Vec2(100, 16), at: t + 0.01)
        for step in 0..<10 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            let h1 = rt.element(byKey: "hdr-1")!
            #expect(abs(h1.rect[1]) < 0.5, "frame \(step): hdr-1 stayed at y=0 after collapse: \(h1.rect)")
        }
        t = settle(rt, start: t, dt: 1.0 / 120.0, maxSteps: 180)
        #expect(abs(rt.element(byKey: "hdr-2")!.rect[1] - 32.0) < 0.5)

        // Expand again
        rt.pointerDown(at: Vec2(100, 16), at: t + 0.005)
        rt.pointerUp(at: Vec2(100, 16), at: t + 0.01)
        for step in 0..<10 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            let h1 = rt.element(byKey: "hdr-1")!
            #expect(abs(h1.rect[1]) < 0.5, "frame \(step): hdr-1 stayed at y=0 after expand: \(h1.rect)")
        }
    }

    @Test("tests/keep_stuck.rs: shutting fold with keepOnScreen holds header (stuck, partial, unstuck; virtualized & direct)")
    func keepStuckMatrix() {
        let stepCount = 40
        let stepH: Float = 28
        let hdrH: Float = 28
        let groupTop: Float = 200

        struct Fold {
            var open = true
            var left = 0
            var stickyShut: Bool
            var dropSteps: Bool
            var virtualized: Bool
        }

        func buildGroup(_ s: Fold) -> El<Fold> {
            let shown = s.open ? stepCount : s.left
            var hdr: El<Fold> = el().key("hdr").wFull().h(hdrH)
            if shown > 0 || s.stickyShut {
                hdr = hdr.stickyTop(0)
            }
            var g: El<Fold> = col().key("group").wFull().child(hdr)
            let laid = s.dropSteps ? shown : stepCount
            if laid > 0 {
                let stepEls: [El<Fold>] = (0..<laid).map { k in
                    el().key("step-\(k)").wFull().h(stepH)
                }
                let steps: El<Fold> = col().key("steps").wFull().children(stepEls)
                let held: El<Fold> = col().key("steps-box").wFull()
                let box: El<Fold> = shown == laid ? held : held.h(Float(shown) * stepH)
                g = g.child(box.child(steps))
            }
            return g
        }

        func buildRow(_ s: Fold, _ i: Int) -> El<Fold> {
            switch i {
            case 0: return el().key("before").wFull().h(groupTop)
            case 1: return col().key("turn").wFull().child(buildGroup(s))
            case 2: return el().key("after").wFull().h(100)
            default: return el().key("tail").wFull().h(100)
            }
        }

        func checkScenario(into: Float, left: Int) {
            let at = max(-into, Float(0))
            let bottom = groupTop + hdrH + Float(left) * stepH
            let expectedAfter = max(bottom - groupTop - into, at + hdrH)

            for stickyShut in [false, true] {
                for dropSteps in [false, true] {
                    for virtualized in [false, true] {
                        let initFold = Fold(stickyShut: stickyShut, dropSteps: dropSteps, virtualized: virtualized)
                        let rt = Runtime<Fold>(state: initFold, viewport: Vec2(300, 200), pixelScale: 1.0) { s, _ in
                            var stack: El<Fold> = col().key("stack").wFull().growth(GrowthSpec.default)
                            if s.virtualized {
                                let keys = ["before", "turn", "after", "tail"]
                                stack = stack.virtualRows(count: 4, estimatedRowHeight: 100, key: { _, i in keys[i] }, build: buildRow)
                            } else {
                                for i in 0..<4 { stack = stack.child(buildRow(s, i)) }
                            }
                            return col().key("scroll").size(300, 200).scrollY(stickBottom: true).child(stack)
                        }
                        var t = 0.0
                        _ = rt.frame(at: t)
                        rt.update(at: 0.005) { _, tx in tx.scrollToInstant("scroll", x: 0, y: groupTop + into) }
                        for _ in 0..<4 { t += 1.0 / 120.0; _ = rt.frame(at: t) }
                        let hdrInit = rt.element(byKey: "hdr")!
                        #expect(abs(hdrInit.rect[1] - max(-into, 0)) < 0.5)
                        #expect(abs(hdrInit.stuck - max(into, 0)) < 0.5)

                        func sample() -> (hdr: Float, after: Float?, steps: [(Int, Float)]) {
                            let els = rt.elements().filter { !$0.exiting }
                            let hdr = els.first(where: { $0.key == "hdr" })?.rect[1] ?? .nan
                            let after = els.first(where: { $0.key == "after" })?.rect[1]
                            let to = after ?? Float.infinity
                            var steps: [(Int, Float)] = []
                            for k in 0..<stepCount {
                                if let e = els.first(where: { $0.key == "step-\(k)" }) {
                                    let visY = e.visible[1]
                                    let visH = e.visible[3]
                                    let showsAmt = max(0, min(visY + visH, min(to, 200)) - max(visY, hdr + hdrH))
                                    if showsAmt > 0.5 {
                                        steps.append((k, e.rect[1]))
                                    }
                                }
                            }
                            return (hdr, after, steps)
                        }

                        var frames = [sample()]
                        rt.update(at: t + 0.002) { s, tx in
                            s.open = false
                            s.left = left
                            tx.keepOnScreen("hdr")
                        }
                        for _ in 0..<240 {
                            t += 1.0 / 120.0
                            _ = rt.frame(at: t)
                            frames.append(sample())
                        }
                        for f in 0..<(frames.count - 1) {
                            let prev = frames[f]
                            let cur = frames[f + 1]
                            #expect(abs(cur.hdr - at) < 0.5, "stickyShut=\(stickyShut) drop=\(dropSteps) virt=\(virtualized) frame \(f): hdr moved \(prev.hdr) -> \(cur.hdr)")
                            for (k, y) in cur.steps {
                                let was = prev.steps.first(where: { $0.0 == k })?.1
                                #expect(was.map { abs(y - $0) < 0.5 } == true, "stickyShut=\(stickyShut) drop=\(dropSteps) virt=\(virtualized) frame \(f): step \(k) showed at \(y) (was \(String(describing: was)))")
                            }
                            if let a0 = prev.after, let a1 = cur.after {
                                #expect((a1 - a0) > -12.0 && (a1 - a0) < 0.5, "stickyShut=\(stickyShut) drop=\(dropSteps) virt=\(virtualized) frame \(f): after \(a0) -> \(a1)")
                            }
                        }
                        let last = frames.last!
                        #expect(abs(last.hdr - at) < 0.5)
                        if let la = last.after {
                            #expect(abs(la - expectedAfter) < 0.5)
                        }
                    }
                }
            }
        }

        checkScenario(into: 500, left: 0)
        checkScenario(into: 500, left: 20)
        checkScenario(into: -40, left: 0)
    }

    @Test("A clipped sticky gutter keeps its horizontal pin, overflow hit, and anchored popup", arguments: [false, true])
    func offscreenStickyGutterUnderRoundedViewport(rtl: Bool) throws {
        let rt = Runtime(state: false, viewport: Vec2(180, 120), pixelScale: 2) { _, _ -> El<Bool> in
            let button: El<Bool> = el().key("escape").size(15, 15).pin(top: -262.5, left: 3.25)
                .role(.button).label("Escaping button").bg(.white).hit()
            var gutter = el().key("gutter").size(38, 24).stickyLeft(6.5).mark(27).child(button)
            if rtl { gutter = gutter.pin(top: 0, left: 250) }
            let band = el().key("row").size(700, 24).pin(top: 300, left: 0).child(gutter)
            let inner = el().key("inner").size(180, 120).pin(top: 0, left: 0).scrollXY()
                .child(el().size(800, 490).child(band))
            let outer = el().key("outer").size(180, 120).scrollXY().child(el().size(360, 240).child(inner))
            let popup: El<Bool> = el().key("popup").size(9, 5).bg(.white).anchored("escape", side: .bottom, gap: 1)
            let root = el().size(180, 120).rounded(6).clip(true).children([outer, popup])
            return rtl ? root.dir(.rtl) : root
        }
        _ = rt.renderFrame(at: 0)
        rt.update(at: 0.1) { _, tx in
            tx.instant()
            tx.scrollToInstant("inner", x: 110, y: 0)
        }
        let frame = rt.renderFrame(at: 0.1)
        let gutter = try #require(rt.element(byKey: "gutter"))
        let button = try #require(rt.element(byKey: "escape"))
        let popup = try #require(rt.element(byKey: "popup"))
        #expect(gutter.stuck == (rtl ? 4.5 : 116.5))
        #expect(gutter.rect[0] == 6.5 && gutter.visible[3] == 0)
        #expect(button.visible == [rtl ? 26.25 : 9.75, 37.5, 15, 15])
        #expect(popup.rect[0] == (rtl ? 32.25 : 9.75) && popup.rect[1] == 53.5)
        #expect(rt.hitTestElement(at: Vec2(button.rect[0] + 3, 42))?.key == "escape")
        #expect(zip(frame.instances, frame.marks).contains { $0.rect.z == 30 && $1 == 27 })
    }
}
