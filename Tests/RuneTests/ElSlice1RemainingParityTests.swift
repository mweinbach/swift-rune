import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite("El Slice 1 Remaining Builders & Tests Parity")
struct ElSlice1RemainingParityTests {

    // MARK: - 1. Core El Builders: effect, rule, PillStyle.bg, liveTrim, ElementInfo.stub, TerminalGrid

    @Test("src/el: effect free functions, rule, PillStyle.bg, and liveTrim wiring")
    func effectRulePillBgAndLiveTrim() {
        let trimLive = Live<Vec2>(Vec2(0.0, 0.5))
        let trimBinding = Binding(live: trimLive)
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(240, 200), pixelScale: 1.0) { _, _ in
            col()
                .size(240, 200)
                .child(effect(UInt32(42)).key("fx32").size(40, 20))
                .child(effect(UInt64(99)).key("fx64").size(40, 20))
                .child(rule(Float(3.0), Color.srgb(0.8, 0.2, 0.1)).key("sep"))
                .child(
                    rich("alpha pill omega", [])
                        .key("rich-pill")
                        .pill(6..<10, PillStyle.default.bg(Color.srgb(0.1, 0.4, 0.9)).fg(Color.white))
                )
                .child(
                    el()
                        .key("trimmed-shape")
                        .size(100, 20)
                        .shape(Shape().strokeWith([Vec2(0, 10), Vec2(100, 10)], closed: false, width: 4, cap: .round, color: Color.white))
                        .liveTrim(trimBinding)
                )
        }
        let rf = rt.renderFrame(at: 0.0)
        #expect(rf.marks.contains(42))
        #expect(rf.marks.contains(99))

        let sep = rt.element(byKey: "sep")!
        #expect(abs(sep.rect[2] - 240.0) < 0.5)
        #expect(abs(sep.rect[3] - 3.0) < 0.5)

        let pillStyle = PillStyle.default.bg(Color.srgb(0.1, 0.4, 0.9)).fg(Color.white)
        #expect(pillStyle.background == Color.srgb(0.1, 0.4, 0.9))
        #expect(pillStyle.color == Color.white)
        let scene = rt.frame(at: 0.01)
        #expect(scene.primitives.contains(where: { prim in
            prim.fill.x < 0.15 && prim.fill.z > 0.7 && prim.radii.x > 0
        }))

        let commitsBefore = rt.commitCount
        #expect(trimLive.set(Vec2(0.1, 0.9)))
        _ = rt.frame(at: 0.02)
        #expect(rt.commitCount == commitsBefore, "liveTrim updates without forcing a tree commit")
    }

    @Test("el/element_info & el/grid: ElementInfo.stub and TerminalGridRow cells and fills")
    func elementInfoStubAndTerminalGrid() {
        let stub = ElementInfo.stub("row-1")
        #expect(stub.key == "row-1")
        #expect(stub.path == "/0/@row-1")

        let bg = Color.srgb(0.1, 0.2, 0.3)
        let fg = Color.srgb(0.9, 0.95, 1.0)
        let rowSpec = TerminalGridRow(text: "hi")
            .fill(start: 0, end: 5, color: bg)
            .cell(column: 1, width: 2, text: "hi", style: TextStyle(), color: fg)
        #expect(rowSpec.fills.count == 1)
        #expect(rowSpec.cells.count == 1)

        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 80), pixelScale: 1.0) { _, _ in
            terminalGrid(columns: 10, cellWidth: 8, cellHeight: 16, rows: [rowSpec]).key("term")
        }
        let scene = rt.frame(at: 0.0)
        #expect(rt.element(byKey: "term") != nil)
        #expect(!scene.primitives.isEmpty)
    }

    // MARK: - 2. el/handlers, el/isolates, el/layout, el/layout_watch

    @Test("el/handlers & el/layout: PointerEvent, Drag helpers, secondary/move/background/dragAny/windowFocus/hoverAny")
    func handlersAndLayoutPointerCallbacks() {
        struct S {
            var secondaryLocals: [Vec2] = []
            var moveLocals: [Vec2] = []
            var dragEvents: [Drag] = []
            var dragEnds: [Bool] = []
            var bgPresses = 0
            var focusEvents: [Bool] = []
        }
        final class AnyBox: @unchecked Sendable {
            var moveAny: [PointerEvent] = []
            var hoverAny: [Bool] = []
            var chainedHoverAny: [Bool] = []
        }
        let box = AnyBox()

        let directEvt = PointerEvent(x: 15, y: 25, windowX: 115, windowY: 125)
        let wp = directEvt.window()
        #expect(wp.window.x == 115 && wp.window.y == 125 && wp.local == Vec2(15, 25))

        let dragA = Drag(
            window: Vec2(30, 40),
            local: Vec2(10, 10),
            delta: Vec2(5, 0),
            startLocal: Vec2(5, 10),
            size: Vec2(80, 40),
            isCancelled: true,
            screen: (300, 400)
        )
        let dragB = dragA
        #expect(dragA == dragB)
        #expect(dragA.cancelled())
        #expect(dragA.windowPoint() == [30, 40])
        #expect(dragA.screenPoint()?.0 == 300 && dragA.screenPoint()?.1 == 400)

        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 200), pixelScale: 1.0) { _, _ in
            col()
                .size(300, 200)
                .onBackgroundPress { s in s.bgPresses += 1 }
                .onWindowFocus { s, focused, _ in s.focusEvents.append(focused) }
                .onPointerMoveAny { ev, _ in
                    box.moveAny.append(ev)
                }
                .child(
                    el()
                        .key("target")
                        .pin(top: 20, left: 30)
                        .size(80, 40)
                        .noWindowDrag()
                        .imeCursor()
                        .onSecondaryPressLocal { s, ev, _ in
                            s.secondaryLocals.append(Vec2(ev.x, ev.y))
                        }
                        .onPointerMoveLocal { s, ev, _ in
                            s.moveLocals.append(Vec2(ev.x, ev.y))
                        }
                        .onHoverChangeAny { entered, _ in
                            box.hoverAny.append(entered)
                        }
                        .chainHoverChangeAny { entered, _ in
                            box.chainedHoverAny.append(entered)
                        }
                        .onDragAny { d, _ in
                            _ = d.windowPoint()
                        }
                        .onDrag { s, d, _ in
                            s.dragEvents.append(d)
                        }
                        .onDragEnd { s, cancelled, _ in
                            s.dragEnds.append(cancelled)
                        }
                )
        }
        _ = rt.frame(at: 0.0)

        // Move into target at (50, 35) -> local (20, 15)
        rt.pointerMove(to: Vec2(50, 35), at: 0.01)
        _ = rt.frame(at: 0.02)
        #expect(rt.state.secondaryLocals.isEmpty)
        #expect(rt.state.moveLocals.last == Vec2(20, 15))
        #expect(box.moveAny.last?.windowX == 50)
        #expect(box.hoverAny == [true])
        #expect(box.chainedHoverAny == [true])

        // Secondary press
        rt.pointerDown(at: Vec2(50, 35), button: .secondary, at: 0.03)
        rt.pointerUp(at: Vec2(50, 35), button: .secondary, at: 0.04)
        #expect(rt.state.secondaryLocals == [Vec2(20, 15)])

        // Primary drag
        rt.pointerDown(at: Vec2(50, 35), at: 0.05)
        rt.pointerMove(to: Vec2(65, 35), at: 0.06)
        rt.pointerUp(at: Vec2(65, 35), at: 0.07)
        #expect(rt.state.dragEvents.contains(where: { $0.delta.x > 0 }))
        #expect(rt.state.dragEnds == [false])

        // Background press outside target
        rt.pointerDown(at: Vec2(250, 150), at: 0.08)
        rt.pointerUp(at: Vec2(250, 150), at: 0.09)
        #expect(rt.state.bgPresses == 1)

        // Window focus transitions
        rt.dispatchFocus(false, at: 0.10)
        rt.dispatchFocus(true, at: 0.11)
        #expect(rt.state.focusEvents == [false, true])
    }

    @Test("el/isolates: isolate wraps UTF-8 byte ranges and preserves span and link ranges")
    func isolatePreservesSpansAndLinks() {
        let rtl = "\u{0627}\u{0644}" // 4 UTF-8 bytes
        let input = "hi \(rtl) end"
        // "hi " is 0..<3, rtl is 3..<7, " end" is 7..<11, "end" is 8..<11
        let rtlStart = 3
        let rtlEnd = rtlStart + rtl.utf8.count
        let endStart = rtlEnd + 1
        let endRange = endStart..<(endStart + 3)
        let red = Color.srgb(1, 0, 0)

        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(240, 120), pixelScale: 1.0) { _, _ in
            col().size(240, 120)
                .child(text("a \(rtl) b").key("plain").isolate(2..<(2 + rtl.utf8.count), .rtl))
                .child(
                    rich(input, [RichSpan(0..<2).color(red)])
                        .key("rich-iso")
                        .link(TextLink(endRange, id: "go"))
                        .isolate(rtlStart..<rtlEnd, .rtl)
                )
        }
        _ = rt.frame(at: 0.0)
        let plainText = rt.element(byKey: "plain")?.text ?? ""
        #expect(plainText.contains("\u{2067}") && plainText.contains("\u{2069}"))
        let linkEl = rt.element(byKey: "go")
        #expect(linkEl?.text == "end")
    }

    @Test("el/layout & layout_watch: gaps, aspectRatio, pb/mr/mb/pr, justifyBetween, flexWrap, itemsStretch, selfStart/Center, equalColumns, wrapScrollArea, onLayoutTx, chainScrollOffset")
    func layoutBuildersAndWatchCoverage() {
        final class Log: @unchecked Sendable {
            var layoutRects: [[Float]] = []
            var scrollOffsets: [ScrollPos] = []
        }
        let log = Log()
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(240, 200), pixelScale: 1.0) { (_, _) -> El<S> in
            let innerScroll: El<S> = col()
                .key("list")
                .size(200, 60)
                .scrollY()
                .chainScrollOffset { log.scrollOffsets.append($0) }
                .child(el().key("item-top").size(180, 120).shrink(0))
            let (_, _, outerScroll, viewportScroll) = innerScroll.wrapScrollArea()

            return col()
                .size(240, 200)
                .gaps(row: 6, column: 4)
                .pb(4).pr(4).mb(2).mr(2)
                .child(
                    row()
                        .key("spread")
                        .size(200, 30)
                        .justifyBetween()
                        .itemsStretch()
                        .child(el().key("left").size(20, 10).selfStart())
                        .child(el().key("right").size(20, 10).selfCenter())
                )
                .child(
                    row()
                        .key("eq")
                        .size(180, 20)
                        .gaps(4, 6)
                        .equalColumns(3)
                        .child(el().key("c0").h(20))
                        .child(el().key("c1").h(20))
                        .child(el().key("c2").h(20))
                )
                .child(
                    row()
                        .key("wrap-row")
                        .w(90)
                        .flexWrap()
                        .child(el().size(50, 12))
                        .child(el().size(50, 12))
                )
                .child(
                    el()
                        .key("aspect")
                        .w(40)
                        .aspectRatio(2.0)
                        .onLayoutTx { _, rect, _ in log.layoutRects.append(rect) }
                )
                .child(outerScroll.child(viewportScroll))
        }
        _ = rt.frame(at: 0.0)

        let left = rt.element(byKey: "left")!
        let right = rt.element(byKey: "right")!
        #expect(right.rect[0] > left.rect[0] + 100)

        let c0 = rt.element(byKey: "c0")!
        let c1 = rt.element(byKey: "c1")!
        let c2 = rt.element(byKey: "c2")!
        #expect(abs(c0.rect[2] - c1.rect[2]) < 1.0 && abs(c1.rect[2] - c2.rect[2]) < 1.0)

        let wrapRow = rt.element(byKey: "wrap-row")!
        #expect(wrapRow.rect[3] >= 24.0)

        let aspect = rt.element(byKey: "aspect")!
        #expect(abs(aspect.rect[2] - 40.0) < 0.5 && abs(aspect.rect[3] - 20.0) < 0.5)
        #expect(!log.layoutRects.isEmpty)

        rt.update(at: 0.1) { _, tx in tx.scrollTo("list", x: 0, y: 30) }
        for i in 1...10 { _ = rt.frame(at: 0.1 + Double(i) / 60.0) }
        #expect(log.scrollOffsets.contains(where: { $0.offset.y > 0 }))
    }

    // MARK: - 3. Slice 1 Tests: batch_c:14, enter_delay:93,107, matched, offset_raise, opacity_motion, row_enter, text_case

    @Test("batch_c:14: liveText_shapes_only_changed_run_without_layout_and_coalesces_visible_wakes")
    func liveTextNoLayoutRebuildAndCoalescesVisibleWakes() {
        let lt = LiveText("initial")
        final class WakeCounter: @unchecked Sendable {
            var count = 0
        }
        let wakes = WakeCounter()
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(240, 120), pixelScale: 1.0) { _, _ in
            col().size(240, 120).child(liveText(lt).key("lt"))
        }
        rt.setLiveWaker { wakes.count += 1 }
        _ = rt.frame(at: 0.0)
        let baselineCommits = rt.commitCount

        // Coalesce multiple updates while visible before next frame
        wakes.count = 0
        #expect(lt.set("one"))
        #expect(lt.set("two"))
        #expect(lt.set("three"))
        #expect(wakes.count == 1, "consecutive liveText writes before frame coalesce to one wake")

        _ = rt.frame(at: 0.016)
        #expect(rt.commitCount == baselineCommits, "LiveText updates without re-committing tree")
        #expect(rt.element(byKey: "lt")?.text == "three")

        // Hidden window suppresses wakes until made visible again
        wakes.count = 0
        rt.setLiveVisible(false, at: 0.02)
        #expect(lt.set("four"))
        #expect(wakes.count == 0)
        rt.setLiveVisible(true, at: 0.03)
        #expect(wakes.count == 1)
    }

    @Test("enter_delay:93,107: removed_while_waiting_doesnt_flash & unseen_entrances_ignore_the_delay")
    func enterDelayRemovedWhileWaitingAndUnseenEntrances() {
        struct S { var show = false }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 120), pixelScale: 1.0) { (s, _) -> El<S> in
            var root: El<S> = col().size(200, 120)
            if s.show {
                root = root.child(
                    el().key("delayed")
                        .size(80, 40)
                        .bg(Color.white)
                        .enterDelay(0.5)
                        .transition(.opacity)
                )
            }
            return root
        }
        _ = rt.frame(at: 0.0)

        // Mount delayed element at t = 0.01, still waiting at t = 0.1 -> opacity == 0
        rt.update(at: 0.01) { s, _ in s.show = true }
        _ = rt.frame(at: 0.1)
        if let p = rt.presented("delayed") {
            #expect(p.opacity < 0.01)
        }

        // Remove while waiting before delay completes: must never flash visible!
        rt.update(at: 0.15) { s, _ in s.show = false }
        for step in 1...40 {
            _ = rt.frame(at: 0.15 + Double(step) * (1.0 / 60.0))
            if let p = rt.presented("delayed") {
                #expect(p.opacity < 0.01, "removed mid-delay must not flash")
            }
        }
        #expect(rt.presented("delayed") == nil)

        // Unseen entrance (first frame OR instant commit) ignores enterDelay
        struct S2 { var show = true }
        let firstFrameRt = Runtime<S2>(state: S2(), viewport: Vec2(200, 120), pixelScale: 1.0) { (s, _) -> El<S2> in
            s.show
                ? el().key("first").size(60, 30).enterDelay(0.5).transition(.opacity)
                : el().size(60, 30)
        }
        _ = firstFrameRt.frame(at: 0.0)
        #expect((firstFrameRt.presented("first")?.opacity ?? 0) > 0.99)
    }

    @Test("matched:88,111: children_scale_with_the_flight & unmatched_elements_are_untouched")
    func matchedChildrenScaleAndUnmatchedUntouched() {
        struct S { var zoomed = false }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 200), pixelScale: 1.0) { s, _ in
            let card: El<S> = el()
                .key(s.zoomed ? "hero" : "tile")
                .matched("card")
                .size(s.zoomed ? 160 : 40, s.zoomed ? 160 : 40)
                .motion(Spring(duration: 0.3, bounce: 0.0))
                .child(el().key("dot").size(s.zoomed ? 40 : 10, s.zoomed ? 40 : 10))
            return row().size(300, 200)
                .child(el().key("left").size(100, 200).child(s.zoomed ? el().size(1, 1) : card))
                .child(el().key("right").size(200, 200).child(s.zoomed ? card : el().size(1, 1)))
                .child(el().key("static").size(20, 20))
        }
        _ = rt.frame(at: 0.0)
        let staticStart = rt.presented("static")!

        rt.update(at: 0.01) { s, _ in s.zoomed = true }
        _ = rt.frame(at: 0.08)
        let cardNow = rt.presented("hero")!.rect
        let dotNow = rt.presented("dot")!.rect
        #expect(cardNow[2] > 45 && cardNow[2] < 155)
        #expect(abs(dotNow[2] - cardNow[2] / 4.0) < 1.5, "non-crop child scales proportionally with flight")

        let staticNow = rt.presented("static")!
        #expect(staticNow.rect == staticStart.rect && abs(staticNow.opacity - 1.0) < 1e-4)
    }

    @Test("matched:186,214,246,286: flight removed midway exits cleanly, fast flight waits/keeps opacity, reduced motion fades with parent, content flies without fade")
    func matchedRemainingFourTests() {
        // 1. a_flight_removed_mid_way_exits_without_a_pop
        struct RemovableS { var phase = 0 }
        let rmRt = Runtime<RemovableS>(state: RemovableS(), viewport: Vec2(300, 200), pixelScale: 1.0) { (s, _) -> El<RemovableS> in
            let tile: El<RemovableS> = el().key("tile").matched("card")
                .size(s.phase == 0 ? 40 : 160, s.phase == 0 ? 40 : 160)
                .bg(Color.white)
                .motion(Spring(duration: 0.3, bounce: 0.0))
                .child(el().key("dot").size(s.phase == 0 ? 10 : 40, s.phase == 0 ? 10 : 40))
            var left: El<RemovableS> = el().key("left").size(100, 200)
            if s.phase == 0 { left = left.child(tile) }
            var right: El<RemovableS> = el().key("right").size(200, 200)
            if s.phase == 1 { right = right.child(tile) }
            return s.phase == 2 ? row().size(300, 200).child(left) : row().size(300, 200).child(left).child(right)
        }
        _ = rmRt.frame(at: 0.0)
        rmRt.update(at: 0.01) { s, _ in s.phase = 1 }
        for i in 1...8 { _ = rmRt.frame(at: 0.01 + Double(i) / 120.0) }
        var last = rmRt.presented("tile")!
        #expect(last.rect[2] > 45 && last.rect[2] < 155)
        rmRt.update(at: 0.09) { s, _ in s.phase = 2 }
        var sawFade = false
        for i in 1...120 {
            _ = rmRt.frame(at: 0.09 + Double(i) / 120.0)
            guard let now = rmRt.presented("tile") else { break }
            #expect(now.opacity <= last.opacity + 1e-3)
            if now.opacity > 0.2 && now.opacity < 0.8 { sawFade = true }
            last = now
        }
        #expect(sawFade)
        #expect(rmRt.presented("tile") == nil)

        // 2 & 3. fast flight keeps full opacity while entering parent fades/scales + content flies at opacity 1.0
        struct FastS { var zoomed = false }
        let fastRt = Runtime<FastS>(state: FastS(), viewport: Vec2(300, 200), pixelScale: 1.0) { (s, _) -> El<FastS> in
            let tile: El<FastS> = el().key("tile").matched("tile")
                .size(s.zoomed ? 160 : 40, s.zoomed ? 160 : 40)
                .bg(Color.white)
                .motion(Spring(duration: 0.08, bounce: 0.0))
                .child(el().key("inner-label").size(20, 20).bg(Color.black))
            if s.zoomed {
                return row().size(300, 200)
                    .child(el().key("left").size(100, 200))
                    .child(el().key("right").size(200, 200).transition(.scale(0.9)).child(tile))
            } else {
                return row().size(300, 200).child(el().key("left").size(100, 200).child(tile))
            }
        }
        _ = fastRt.frame(at: 0.0)
        fastRt.update(at: 0.01) { s, _ in s.zoomed = true }
        var sawParentEnteringOnLand = false
        for i in 1...120 {
            _ = fastRt.frame(at: 0.01 + Double(i) / 120.0)
            let tileNow = fastRt.presented("tile")!
            let innerNow = fastRt.presented("inner-label")!
            #expect(tileNow.opacity > 0.99, "matched flight keeps full opacity")
            #expect(innerNow.opacity > 0.99, "flight's nested content flies without fading in")
            if abs(tileNow.rect[2] - 160.0) < 0.5 && !sawParentEnteringOnLand {
                let parentOpacity = fastRt.presented("right")?.opacity ?? 1.0
                if parentOpacity < 0.95 { sawParentEnteringOnLand = true }
            }
        }
        #expect(sawParentEnteringOnLand)

        // 4. reduced_motion_fades_the_old_one_with_the_parent_it_leaves_with
        let redRt = Runtime<FastS>(state: FastS(), viewport: Vec2(300, 200), pixelScale: 1.0) { s, _ in
            if s.zoomed {
                return row().size(300, 200)
                    .child(el().key("spacer").size(100, 200))
                    .child(el().key("right").size(200, 200).child(el().key("new").matched("tile").size(160, 160).bg(Color.white)))
            } else {
                return row().size(300, 200)
                    .child(
                        col().key("left").size(100, 200).transition(.opacity)
                            .child(el().key("old").matched("tile").size(40, 40).bg(Color.white))
                            .child(el().key("peer").size(40, 40).bg(Color.white))
                    )
            }
        }
        redRt.setSystemReducedMotion(true)
        _ = redRt.frame(at: 0.0)
        redRt.update(at: 0.01) { s, _ in s.zoomed = true }
        var sampledFade = false
        for i in 1...60 {
            _ = redRt.frame(at: 0.01 + Double(i) / 120.0)
            guard let oldP = redRt.presented("old"), let peerP = redRt.presented("peer") else { break }
            #expect(abs(oldP.opacity - peerP.opacity) < 0.02)
            if peerP.opacity > 0.2 && peerP.opacity < 0.8 { sampledFade = true }
        }
        #expect(sampledFade)
    }

    @Test("offset_raise:52,76,96,167,174,225,278: offset springs, raise paint+hit order, appear hover, reordered rows, 5k virtual reorder, drag vs animated, double click")
    func offsetRaiseAndVirtualReorderTests() {
        // 1. an_offset_springs_without_moving_siblings_and_hits_follow_it & a_raised_element_paints_and_takes_presses_above_later_siblings
        struct OffS {
            var shift: Float = 0
            var clicks: [String] = []
        }
        let offRt = Runtime<OffS>(state: OffS(), viewport: Vec2(240, 200), pixelScale: 1.0) { s, _ in
            col().size(240, 200)
                .child(
                    el().key("raised")
                        .size(80, 40)
                        .bg(Color.white)
                        .offset(0, s.shift)
                        .motion(Spring(duration: 0.3, bounce: 0.0))
                        .raise(true)
                        .onClick { st in st.clicks.append("raised") }
                )
                .child(
                    el().key("sibling")
                        .size(80, 40)
                        .bg(Color.black)
                        .onClick { st in st.clicks.append("sibling") }
                )
        }
        _ = offRt.frame(at: 0.0)
        offRt.update(at: 0.01) { s, _ in s.shift = 40 }
        _ = offRt.frame(at: 0.03)
        let midRect = offRt.presented("raised")!.rect
        #expect(midRect[1] > 1.0 && midRect[1] < 39.0)
        #expect(abs(offRt.presented("sibling")!.rect[1] - 40.0) < 0.1, "sibling layout untouched")

        for i in 1...60 { _ = offRt.frame(at: 0.03 + Double(i) / 60.0) }
        // Raised element overlaps sibling at y = 50 -> raised paints & hits above later sibling
        #expect(offRt.elementAt(40, 50)?.key == "raised")
        offRt.pointerDown(at: Vec2(40, 50), at: 2.0)
        offRt.pointerUp(at: Vec2(40, 50), at: 2.01)
        #expect(offRt.state.clicks == ["raised"])

        // 2. hover_change_hears_an_element_that_appears_under_a_still_pointer
        struct HoverS { var show = false; var hovers: [Bool] = [] }
        let hovRt = Runtime<HoverS>(state: HoverS(), viewport: Vec2(200, 120), pixelScale: 1.0) { (s, _) -> El<HoverS> in
            var root: El<HoverS> = col().size(200, 120)
            if s.show {
                root = root.child(el().key("late").size(100, 60).onHoverChange { st, entered, _ in st.hovers.append(entered) })
            }
            return root
        }
        _ = hovRt.frame(at: 0.0)
        hovRt.pointerMove(to: Vec2(40, 30), at: 0.01)
        _ = hovRt.frame(at: 0.02)
        hovRt.update(at: 0.03) { s, _ in s.show = true }
        _ = hovRt.frame(at: 0.04)
        #expect(hovRt.state.hovers == [true])

        // 3. a_reordered_row_that_drops_its_offset_slides_from_where_it_was_drawn & 5k virtual rows preserve drawn position
        struct ListS {
            var swapped = false
            var dropOffset: Float = 0
        }
        let listRt = Runtime<ListS>(state: ListS(), viewport: Vec2(200, 160), pixelScale: 1.0) { s, _ in
            let ids = s.swapped ? ["b", "a"] : ["a", "b"]
            return col().size(200, 160).children(ids.map { id in
                let offY: Float = (!s.swapped && id == "a") ? s.dropOffset : 0
                return el().key(id).size(200, 30).offset(0, offY).motion(Spring(duration: 0.3, bounce: 0.0))
            })
        }
        _ = listRt.frame(at: 0.0)
        listRt.update(at: 0.01) { s, _ in s.dropOffset = 20 }
        _ = listRt.frame(at: 0.5)
        let drawnBeforeDrop = listRt.presented("a")!.rect[1]
        #expect(drawnBeforeDrop > 15)
        listRt.update(at: 0.51) { s, _ in s.swapped = true }
        _ = listRt.frame(at: 0.52)
        let afterSwap = listRt.presented("a")!.rect[1]
        #expect(afterSwap < 29.0, "slides from drawn position rather than snapping immediately to y=30: \(afterSwap)")

        struct VirtS {
            var order = Array(0..<5000)
            var shift0: Float = 0
            var shift1: Float = 0
            var version: Int = 0
        }
        let virtRt = Runtime<VirtS>(state: VirtS(), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            col().key("v").size(200, 200).scrollY().child(
                col().key("rows").wFull().virtualRowsVersion(s.version).virtualRows(
                    count: s.order.count,
                    estimatedRowHeight: 30,
                    key: { st, i in "r\(st.order[i])" },
                    build: { st, i in
                        let id = st.order[i]
                        let offY: Float = id == 0 ? st.shift0 : (id == 1 ? st.shift1 : 0)
                        return el().key("r\(id)").size(200, 30).offset(0, offY).motion(Spring(duration: 0.3, bounce: 0.0))
                    }
                )
            )
        }
        _ = virtRt.frame(at: 0.0)
        virtRt.update(at: 0.01) { s, _ in s.shift0 = 85; s.shift1 = -40; s.version += 1 }
        _ = virtRt.frame(at: 0.02)
        _ = virtRt.frame(at: 0.03)
        let beforeR0 = virtRt.presented("r0")!.rect[1]
        #expect(beforeR0 > 1.0)
        virtRt.update(at: 0.03) { s, _ in
            s.order.remove(at: 0)
            s.order.insert(0, at: 1)
            s.shift0 = 0
            s.shift1 = 0
            s.version += 1
        }
        _ = virtRt.frame(at: 0.03)
        let r0Mid = virtRt.presented("r0")!.rect[1]
        #expect(abs(r0Mid - beforeR0) < 0.2, "mid-spring 5000-row virtual drop keeps drawn y: \(beforeR0) -> \(r0Mid)")
        for i in 1...120 { _ = virtRt.frame(at: 0.03 + Double(i) / 120.0) }
        #expect(abs(virtRt.presented("r0")!.rect[1] - 30.0) < 0.5)
        #expect(abs(virtRt.presented("r1")!.rect[1] - 0.0) < 0.5)

        // 4. a_drag_move_lands_at_once_unless_the_handler_animates_it & double click animates
        struct DragS { var animated = false; var shift: Float = 0; var wide = false }
        func runDragCase(animated: Bool) -> Float {
            let rt = Runtime<DragS>(state: DragS(animated: animated), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
                col().size(200, 200)
                    .child(
                        el().key("handle").size(100, 40)
                            .onDrag { st, d, tx in
                                if d.delta != .zero {
                                    if st.animated { tx.animated() }
                                    st.shift = 40
                                }
                            }
                            .onDoubleClick { st, _ in st.wide = true }
                    )
                    .child(
                        el().key("other")
                            .size(s.wide ? 150 : 100, 40)
                            .motion(Spring(duration: 0.3, bounce: 0.0))
                            .offset(0, s.shift)
                    )
            }
            _ = rt.frame(at: 0.0)
            rt.pointerMove(to: Vec2(50, 20), at: 0.01)
            rt.pointerDown(at: Vec2(50, 20), at: 0.02)
            rt.pointerMove(to: Vec2(50, 60), at: 0.03)
            _ = rt.frame(at: 0.04)
            _ = rt.frame(at: 0.05)
            rt.pointerUp(at: Vec2(50, 60), at: 0.06)
            return rt.element(byKey: "other")!.rect[1] - 40
        }
        #expect(abs(runDragCase(animated: false) - 40.0) < 0.01)
        let animY = runDragCase(animated: true)
        #expect(animY > 0 && animY < 40)

        let dblRt = Runtime<DragS>(state: DragS(), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            col().size(200, 200)
                .child(
                    el().key("handle").size(100, 40)
                        .onDrag { _, _, _ in }
                        .onDoubleClick { st, _ in st.wide = true }
                )
                .child(el().key("other").size(s.wide ? 160 : 100, 40).motion(Spring(duration: 0.3, bounce: 0.0)))
        }
        _ = dblRt.frame(at: 0.0)
        dblRt.pointerDown(at: Vec2(50, 20), at: 0.1)
        dblRt.pointerUp(at: Vec2(50, 20), at: 0.11)
        dblRt.pointerDown(at: Vec2(50, 20), at: 0.15)
        dblRt.pointerUp(at: Vec2(50, 20), at: 0.16)
        _ = dblRt.frame(at: 0.17)
        let midW = dblRt.presented("other")!.rect[2]
        #expect(midW > 100 && midW < 160)
    }

    @Test("opacity_motion:18,42: an_unrelated_commit_doesnt_restart_a_fade & a_hidden_element_stays_still_across_commits")
    func opacityMotionStabilityAcrossCommits() {
        struct S { var alpha: Float = 0; var noise = 0 }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 120), pixelScale: 1.0) { s, _ in
            col().size(200, 120)
                .child(el().key("box").size(60, 60).bg(Color.white).opacity(s.alpha).opacityMotion(Spring(duration: 0.4, bounce: 0.0)))
                .child(text("\(s.noise)").key("noise"))
        }
        _ = rt.frame(at: 0.0)
        #expect(abs((rt.presented("box")?.opacity ?? -1) - 0.0) < 0.01)

        // Hidden stays still across commits when alpha stays 0
        rt.update(at: 0.01) { s, _ in s.noise = 1 }
        _ = rt.frame(at: 0.02)
        #expect(abs((rt.presented("box")?.opacity ?? -1) - 0.0) < 0.01)

        // Start fade to 1.0, advance mid-fade, trigger unrelated commit and ensure opacity stays monotonic
        rt.update(at: 0.03) { s, _ in s.alpha = 1.0 }
        for i in 1...6 { _ = rt.frame(at: 0.03 + Double(i) / 60.0) }
        let beforeNoise = rt.presented("box")!.opacity
        #expect(beforeNoise > 0.05 && beforeNoise < 0.95)
        rt.update(at: 0.14) { s, _ in s.noise = 2 }
        _ = rt.frame(at: 0.156)
        let afterNoise = rt.presented("box")!.opacity
        #expect(afterNoise >= beforeNoise - 1e-4 && afterNoise > 0.05)
    }

    @Test("row_enter:78,118: late_children_of_a_shown_row_play_their_transition & rows_scrolled_into_a_nested_virtual_list_mount_settled")
    func rowEnterLateChildrenAndNestedVirtualList() {
        struct S { var showChip = false }
        let rt = Runtime<S>(state: S(), viewport: Vec2(260, 140), pixelScale: 1.0) { (s, _) -> El<S> in
            var r: El<S> = row().key("row").size(240, 40)
                .child(el().key("title").size(80, 30))
            if s.showChip {
                r = r.child(el().key("chip").size(40, 20).bg(Color.white).transition(.opacity))
            }
            return col().size(260, 140).child(r)
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.01) { s, _ in s.showChip = true }
        _ = rt.frame(at: 0.02)
        let chipAlpha = rt.presented("chip")?.opacity ?? 1.0
        #expect(chipAlpha < 0.9, "late child inside already-shown row plays its transition")

        struct VirtS {}
        let nestedRt = Runtime<VirtS>(state: VirtS(), viewport: Vec2(240, 100), pixelScale: 1.0) { _, _ in
            col().key("outer").size(240, 100).scrollY().child(
                col().key("inner").size(240, 100).virtualRows(
                    count: 40,
                    estimatedRowHeight: 30,
                    key: { _, i in "r\(i)" },
                    build: { _, i in
                        el().size(240, 30).transition(.opacity).child(text("row \(i)"))
                    }
                )
            )
        }
        _ = nestedRt.frame(at: 0.0)
        nestedRt.wheel(WheelEvent(dx: 0, dy: -200, precise: true), at: Vec2(100, 50), now: 0.02)
        _ = nestedRt.frame(at: 0.03)
        if let r10 = nestedRt.presented("r10") {
            #expect(r10.opacity > 0.99, "rows scrolled into nested virtual list mount settled")
        }
    }

    @Test("text_case:29,38: cased_text_draws_capitals_and_reports_its_authored_string & spans_and_links_keep_their_authored_byte_ranges")
    func textCaseAuthoredStringsAndLinks() {
        struct S { var edit = TextEdit("straße") }
        let style = TextStyle(size: 14, weight: 400, lineHeight: 20)
        let red = Color.hex("#ff0000")!
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 300), pixelScale: 2.0) { s, _ in
            col().size(300, 300).gap(10)
                .child(text("Straße").key("cased").font(style).textCase(.uppercase))
                .child(text("STRASSE").key("typed").font(style))
                .child(
                    rich("ß link", [RichSpan(3..<7).color(red)])
                        .key("rich")
                        .font(style)
                        .w(200)
                        .textCase(.uppercase)
                        .link(TextLink(3..<7, id: "go"))
                )
                .child(
                    rich("SS LINK", [])
                        .key("rich-typed")
                        .font(style)
                        .w(200)
                        .link(TextLink(3..<7, id: "go-typed"))
                )
                .child(
                    textInput(key: "field", \S.edit)
                        .font(style)
                        .w(200)
                        .textCase(.uppercase)
                )
        }
        _ = rt.frame(at: 0.0)

        let cased = rt.element(byKey: "cased")!
        let typed = rt.element(byKey: "typed")!
        #expect(cased.text == "Straße")
        #expect(abs(cased.rect[2] - typed.rect[2]) < 0.5)
        #expect(rt.element(byKey: "field")?.text == "straße")

        let link = rt.element(byKey: "go")!
        let typedLink = rt.element(byKey: "go-typed")!
        #expect(link.text == "link")
        #expect(abs(link.rect[0] - typedLink.rect[0]) < 0.5)
        #expect(abs(link.rect[2] - typedLink.rect[2]) < 0.5)
        #expect(rt.element(byKey: "rich")?.text == "ß link")
    }
}
