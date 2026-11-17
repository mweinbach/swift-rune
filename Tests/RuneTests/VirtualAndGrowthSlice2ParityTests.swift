import Foundation
import Testing
import RuneMotion
@testable import Rune

@Suite("Virtual, Growth, Fold, Matched & Bottom Slack Slice 2 Parity Tests")
struct VirtualAndGrowthSlice2ParityTests {
    private func settle<State>(_ rt: Runtime<State>, start: Double = 0.0, dt: Double = 1.0 / 120.0, maxSteps: Int = 360) -> Double {
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

    @Test("The mounted virtual window shares its spacer's snap origin at fractional scale")
    func virtualWindowSnapOrigin() throws {
        let rt = Runtime(state: (), viewport: Vec2(160, 150), pixelScale: 1.875) { _, _ in
            col().key("scroll").size(160, 150).scrollY(stickBottom: true).child(
                col().key("list").wFull().growth().virtualRows(count: 100, estimatedRowHeight: 30.3,
                    key: { _, i in "row-\(i)" }, build: { _, _ in el().wFull().h(30.3) })
            )
        }
        _ = rt.frame(at: 0)
        let list = try #require(rt.flatNodes.first { $0.key == "list" })
        let spacer = try #require(rt.flatNodes.first { $0.parentIndex == list.index && $0.key == "__v_top_spacer" })
        let row = try #require(rt.flatNodes.first { $0.parentIndex == list.index && $0.key?.hasPrefix("row-") == true })
        #expect(spacer.localRect.height > 0)
        #expect(abs(list.virtualWindowSnapOriginY - spacer.localRect.height) < 1 / 64)
        #expect(abs(row.localRect.y - list.virtualWindowSnapOriginY) < 1 / 64)
        #expect(rt.growthSnapOffsetY(for: list) == 0)
        #expect(rt.growthSnapOffsetY(for: row) == 0)
    }

    // MARK: - 1. src/runtime/row_reorder_tests.rs

    @Test("row_reorder_tests.rs: reorder slides when unpinned, at bottom, snaps on instant, focus follows reordered row")
    func rowReorderBehavior() throws {
        struct State {
            var order: [Int] = Array(0..<30)
            var instantReorder: Bool = false
        }
        let rt = Runtime<State>(state: State(), viewport: Vec2(300, 200), pixelScale: 1.0) { s, _ in
            col()
                .key("scroll")
                .size(300, 200)
                .scrollY(stickBottom: true)
                .child(
                    col()
                        .key("list")
                        .wFull()
                        .growth(GrowthSpec.default)
                        .virtualRows(
                            count: s.order.count,
                            estimatedRowHeight: 30,
                            key: { st, i in "row-\(st.order[i])" },
                            build: { st, i in
                                let id = st.order[i]
                                return row()
                                    .wFull()
                                    .h(30)
                                    .focusable(true)
                                    .child(text("item \(id)").wFull().h(30))
                            }
                        )
                )
        }

        // Start pinned at bottom -> scroll unpinned into middle and test slide
        var t = 0.0
        _ = rt.frame(at: t)
        #expect(rt.scrollAtBottom(forKey: "scroll") == true)

        rt.update(at: 0.01) { _, tx in
            tx.scrollToInstant("scroll", x: 0, y: 120)
        }
        t = settle(rt, start: 0.01)
        #expect(rt.scrollAtBottom(forKey: "scroll") == false)

        // Focus row-8 before moving it
        rt.update(at: t) { _, tx in tx.focus("row-8") }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(rt.element(byKey: "row-8")?.focused == true)
        let r8Before = rt.element(byKey: "row-8")!.rect[1]

        // Swap row-8 forward by 2 slots -> animated slide from old position toward new position
        rt.update(at: t) { s, _ in
            let idx = s.order.firstIndex(of: 8)!
            s.order.swapAt(idx, idx + 2)
        }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let r8Mid = rt.element(byKey: "row-8")!
        #expect(r8Mid.focused == true, "focus should follow reordered row by key")
        let slidingRow = try #require(rt.flatNodes.first { $0.key == "row-8" })
        #expect(rt.growthSnapOffsetY(for: slidingRow) == 0)
        #expect(abs(r8Mid.rect[1] - (r8Before + 60)) > 1.0, "unpinned reorder should slide rather than snap instantaneously")

        t = settle(rt, start: t)
        let r8Settled = rt.element(byKey: "row-8")!.rect[1]
        #expect(abs(r8Settled - (r8Before + 60)) < 0.5)

        // Instant commit snaps without slides
        rt.update(at: t) { s, tx in
            tx.instant()
            let idx = s.order.firstIndex(of: 8)!
            s.order.swapAt(idx, idx - 2)
        }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let r8Instant = rt.element(byKey: "row-8")!.rect[1]
        #expect(abs(r8Instant - r8Before) < 0.5, "tx.instant() must snap reordered row immediately")

        // Pinned at bottom: reordering visible tail rows also slides cleanly while staying at bottom
        rt.update(at: t) { _, tx in tx.scrollToBottomInstant("scroll") }
        t = settle(rt, start: t)
        #expect(rt.scrollAtBottom(forKey: "scroll") == true)
        let r28Before = rt.element(byKey: "row-28")!.rect[1]
        rt.update(at: t) { s, _ in
            s.order.swapAt(28, 26)
        }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let r28Mid = rt.element(byKey: "row-28")!.rect[1]
        #expect(abs(r28Mid - (r28Before - 60)) > 1.0)
        t = settle(rt, start: t)
        #expect(abs(rt.element(byKey: "row-28")!.rect[1] - (r28Before - 60)) < 0.5)
        #expect(rt.scrollAtBottom(forKey: "scroll") == true)
    }

    // MARK: - 2. src/runtime/virtual/fill_resume_tests.rs

    @Test("virtual/fill_resume_tests.rs: jump/thin rows chunked fill resumes via wakeDeadline within bounded steps")
    func virtualFillResumesViaWakeDeadline() {
        struct State {
            var count = 120
        }
        let rt = Runtime<State>(state: State(), viewport: Vec2(240, 200), pixelScale: 1.0) { s, _ in
            col().key("scroll").size(240, 200).scrollY(stickBottom: false).child(
                col().key("list").wFull().virtualRows(
                    count: s.count,
                    estimatedRowHeight: 100, // much taller than actual 18pt rows so initial chunk under-fills viewport
                    key: { _, i in "r-\(i)" },
                    build: { _, i in
                        row().wFull().h(18).child(text("row \(i)").wFull().h(18))
                    }
                )
            )
        }

        // Jump into middle where estimate (100) >> actual (18), so one chunk won't fill the 200pt viewport
        var t = 0.0
        _ = rt.frame(at: t)
        rt.update(at: 0.01) { _, tx in
            tx.scrollToInstant("scroll", x: 0, y: 4000)
        }
        _ = rt.frame(at: 0.02)

        // Drive fill frames and wakeDeadlines until fill catches up and settles (must terminate within bounded steps)
        t = 0.02
        var steps = 0
        var sawWakeDeadline = false
        while steps < 60 {
            if rt.isAnimating {
                t += 1.0 / 120.0
            } else if let next = rt.nextWakeDeadline(after: t) {
                sawWakeDeadline = true
                t = max(t + 1.0 / 240.0, next)
            } else {
                break
            }
            _ = rt.frame(at: t)
            steps += 1
        }
        #expect(steps < 60, "virtual fill resume must converge without stalling")
        _ = sawWakeDeadline

        let vp = rt.element(byKey: "scroll")!
        let mounted = rt.elements().filter { $0.key?.hasPrefix("r-") == true }
        #expect(mounted.count >= 10, "thin 18pt rows in 200pt viewport should finish filling visible range: got \(mounted.count)")
        let maxBottom = mounted.map { $0.rect[1] + $0.rect[3] }.max() ?? 0
        #expect(maxBottom >= vp.rect[1] + vp.rect[3] - 1.0)
    }

    // MARK: - 3. src/runtime/virtual_selection_tests.rs

    @Test("virtual_selection_tests.rs: drag across mounted & unmounted virtual rows copies full unmounted range & autoscrolls")
    func virtualSelectionAndCopyAcrossUnmountedRows() {
        struct State {
            var count = 50
            var rows = (0..<50).map { "line-\($0)" }
            var tailNote = "tail"
        }
        let rt = Runtime<State>(state: State(), viewport: Vec2(300, 120), pixelScale: 1.0) { s, _ in
            col()
                .key("doc")
                .size(300, 120)
                .selectionGroup()
                .child(
                    col().key("scroll").size(300, 120).scrollY(stickBottom: false).child(
                        col().key("list").wFull().virtualRows(
                            count: s.count,
                            estimatedRowHeight: 24,
                            key: { _, i in "msg-\(i)" },
                            build: { st, i in
                                row().wFull().h(24).child(text(st.rows[i]).key("t-\(i)").wFull().h(24).selectable())
                            }
                        )
                    )
                )
        }

        var t = 0.0
        _ = rt.frame(at: t)
        #expect(rt.element(byKey: "t-0") != nil)
        #expect(rt.element(byKey: "t-40") == nil, "row 40 must initially be unmounted")

        // Start selection drag at start of row 0 and drag within 1pt of bottom edge to autoscroll downward
        rt.pointerMove(to: Vec2(0, 12), at: 0.01)
        rt.pointerDown(at: Vec2(0, 12), at: 0.01)
        rt.pointerMove(to: Vec2(80, 119.5), at: 0.02)
        t = 0.02
        for _ in 0..<80 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            if rt.scrollOffset(forKey: "scroll").y > 400 {
                break
            }
        }
        #expect(rt.scrollOffset(forKey: "scroll").y > 50, "dragging near bottom edge must autoscroll virtual list")

        // Scroll further down while holding pointer so earlier rows unmounted, then release on a mounted lower row
        rt.wheelXY(150, 60, dx: 0, dy: -700, at: t + 0.01)
        t += 0.02
        _ = rt.frame(at: t)
        rt.pointerMove(to: Vec2(80, 90), at: t + 0.01)
        rt.pointerUp(at: Vec2(80, 90), at: t + 0.02)
        _ = rt.frame(at: t + 0.03)

        // Focus pin preservation test: focusing an element on virtual list or copying includes unmounted start
        rt.clipboard = ClipboardContent("")
        _ = rt.keyDown(KeyEvent(key: .command("c"), mods: Mods(cmd: true)), at: t + 0.04)
        let copied = rt.clipboard.text
        #expect(copied.contains("line-0"), "copied text across virtual scroll must include unmounted anchor row 0, got: \(copied)")
        #expect(copied.split(separator: "\n").count >= 10, "copied selection must span unmounted middle rows, got \(copied.split(separator: "\n").count) lines")
    }

    // MARK: - 4. src/runtime/tests/fold_glide.rs

    @Test("tests/fold_glide.rs: foldGlide uses own spring, reopen mid-shut restores smoothly, window edge bounds fold")
    func foldGlideOwnSpringReopenAndWindowBound() {
        struct State {
            var open = true
        }
        let fastFold = Spring(duration: 0.14, bounce: 0)
        let slowList = Spring(duration: 0.60, bounce: 0)
        let rt = Runtime<State>(state: State(), viewport: Vec2(240, 260), pixelScale: 1.0) { s, _ in
            col().key("root").size(240, 260).child(
                col().key("list").wFull().growth(GrowthSpec(spring: slowList))
                    .child(el().key("hdr").wFull().h(40))
                    .child(
                        col().key("fold").wFull()
                            .h(s.open ? 140 : 0)
                            .foldGlide(fastFold)
                            .foldFeather(8)
                            .child(el().key("foldBody").wFull().h(140).bg(Color(r: 0.2, g: 0.4, b: 0.8, a: 1)))
                    )
                    .child(el().key("after").wFull().h(40))
            )
        }

        _ = rt.frame(at: 0.0)
        #expect(abs(rt.element(byKey: "after")!.rect[1] - 180) < 0.5)

        // Close fold -> after 0.16s (past fastFold 0.14s, well before slowList 0.60s) fold has nearly shut
        rt.update(at: 0.01) { s, _ in s.open = false }
        var t = 0.01
        for _ in 0..<8 { // ~0.067s: mid-shut
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        let midShutH = rt.element(byKey: "fold")!.rect[3]
        #expect(midShutH > 10 && midShutH < 130, "fold should be mid-shut at \(t): \(midShutH)")

        // Reopen mid-shut -> velocity-continuous turnaround without collapsing to 0, rises back to 140
        rt.update(at: t) { s, _ in s.open = true }
        let reopenStart = t
        var prevH = midShutH
        var maxSampleH = midShutH
        for step in 0..<18 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            let curH = rt.element(byKey: "fold")!.rect[3]
            #expect(curH > 10.0, "reopening fold mid-shut must not collapse to zero at step \(step): \(curH)")
            if step >= 4 {
                #expect(curH >= prevH - 0.5, "after momentum turnaround, reopened fold rises smoothly: \(prevH) -> \(curH)")
            }
            maxSampleH = max(maxSampleH, curH)
            prevH = curH
        }
        #expect(maxSampleH > midShutH + 20.0, "reopened fold must rise substantially within 0.15s: \(midShutH) -> \(maxSampleH)")
        #expect(t - reopenStart < 0.2)
        t = settle(rt, start: t)
        #expect(abs(rt.element(byKey: "fold")!.rect[3] - 140) < 0.5)
        #expect(abs(rt.element(byKey: "after")!.rect[1] - 180) < 0.5)

        // Close again and let fastFold finish faster than 0.60s slowList would take
        rt.update(at: t) { s, _ in s.open = false }
        let closeStart = t
        for _ in 0..<24 { // 0.20s
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        let afterFast = rt.element(byKey: "fold")!.rect[3]
        #expect(afterFast < 5.0, "foldGlide(0.14s) must drive close speed faster than slowList(0.60s), got \(afterFast) at +\(t - closeStart)s")
    }

    // MARK: - 5. src/runtime/tests/matched_scroll.rs

    @Test("tests/matched_scroll.rs: closing overlay flies matched badge back to scrolled list cell")
    func matchedFlightsHomeIntoScrolledList() {
        struct State {
            var open = true
        }
        let rt = Runtime<State>(state: State(), viewport: Vec2(300, 240), pixelScale: 1.0) { s, _ in
            el().key("root").size(300, 240).child(
                col().key("scroll").size(300, 240).scrollY(stickBottom: false).children(
                    (0..<10).map { i in
                        row().key("row-\(i)").wFull().h(60).child(
                            s.open && i == 6
                                ? el().key("slot-\(i)").size(40, 40)
                                : el().key("badge-\(i)").size(40, 40).matched("hero-\(i)", spring: MotionTokens.SMOOTH)
                        )
                    }
                )
            )
            .child(
                s.open
                    ? el().key("overlay").absolute(x: 180, y: 20).size(90, 90)
                        .matched("hero-6", spring: MotionTokens.SMOOTH)
                    : el()
            )
        }

        _ = rt.frame(at: 0.0)
        // Scroll the list so row-6 moves up from y=360 to y=120 while overlay is open at (180, 20)
        rt.update(at: 0.01) { _, tx in
            tx.scrollToInstant("scroll", x: 0, y: 240)
        }
        _ = rt.frame(at: 0.02)
        let r6 = rt.element(byKey: "row-6")!
        #expect(abs(r6.rect[1] - 120) < 0.5)

        // Close overlay -> badge-6 must fly from (180, 20) toward row-6's scrolled position (0, 120)
        rt.update(at: 0.03) { s, _ in s.open = false }
        _ = rt.frame(at: 0.04)
        let mid = rt.element(byKey: "badge-6")!
        #expect(mid.rect[0] > 40, "matched badge-6 should fly from overlay x=180 toward x=0, got \(mid.rect[0])")
        #expect(mid.rect[1] < 110, "matched badge-6 should fly from overlay y=20 toward y=120, got \(mid.rect[1])")

        let t = settle(rt, start: 0.04)
        let end = rt.element(byKey: "badge-6")!
        #expect(abs(end.rect[0] - 0) < 0.5 && abs(end.rect[1] - 120) < 0.5)
        #expect(t > 0.04)
    }

    // MARK: - 6. src/runtime/tests/scroll_growth.rs

    @Test("tests/scroll_growth.rs: growth.default arrivesWhole & streaming climb with stickBottom and wheel unpin")
    func scrollGrowthStreamingAndWheelUnpin() {
        struct State {
            var count = 3
            var tailHeight: Float = 24
        }
        let rt = Runtime<State>(state: State(), viewport: Vec2(280, 200), pixelScale: 1.0) { s, _ in
            col().key("scroll").size(280, 200).scrollY(stickBottom: true).child(
                col().key("list").wFull().growth(GrowthSpec.default)
                    .children((0..<s.count).map { i in
                        if i == s.count - 1 {
                            return el().key("m-\(i)").wFull().h(s.tailHeight).streaming()
                        } else {
                            return el().key("m-\(i)").wFull().h(60).arrivesWhole()
                        }
                    })
            )
        }

        _ = rt.frame(at: 0.0)
        #expect(rt.scrollAtBottom(forKey: "scroll") == true)

        // Appending grows height and keeps viewport pinned at bottom
        rt.update(at: 0.02) { s, _ in s.count = 8 }
        var t = 0.02
        for _ in 0..<10 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            #expect(rt.scrollAtBottom(forKey: "scroll") == true)
        }
        t = settle(rt, start: t)

        // Streaming tail row climbs smoothly while pinned at bottom
        let prevBottom = rt.element(byKey: "m-7")!.rect[1] + rt.element(byKey: "m-7")!.rect[3]
        rt.update(at: t) { s, _ in s.tailHeight = 80 }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let curBottom = rt.element(byKey: "m-7")!.rect[1] + rt.element(byKey: "m-7")!.rect[3]
        #expect(abs(curBottom - prevBottom) < 0.5, "stickBottom keeps streaming tail bottom docked at viewport bottom")

        // Wheel up unpins stickBottom
        rt.wheelXY(140, 100, dx: 0, dy: 60, at: t + 0.01)
        _ = rt.frame(at: t + 0.02)
        #expect(rt.scrollAtBottom(forKey: "scroll") == false)
    }

    // MARK: - 7. src/runtime/scroll/bottom.rs (followEdge, ScrollSlack, scrollPage, PageUp/PageDown)

    @Test("scroll/bottom.rs: followEdge tracks dock resize, ScrollSlack holds shrink until 0.12s, PageUp/PageDown & virtual scrollPage")
    func bottomFollowEdgeSlackAndPaging() {
        struct State {
            var composerH: Float = 80
            var rows: Int = 100
            var drawnListRect: [Float] = [0, 0, 0, 0]
        }
        let rt = Runtime<State>(state: State(), viewport: Vec2(300, 300), pixelScale: 1.0) { s, _ in
            col().key("frame").size(300, 300).child(
                col().key("scroll").wFull().grow().scrollY(stickBottom: true).child(
                    col().key("list").wFull().growth(GrowthSpec.default)
                        .onDrawnLayout { st, r in st.drawnListRect = r }
                        .virtualRows(
                            count: s.rows,
                            estimatedRowHeight: 30,
                            key: { _, i in "row-\(i)" },
                            build: { _, i in
                                el().wFull().h(30).child(text("msg \(i)").wFull().h(30))
                            }
                        )
                )
            )
            .child(el().key("composer").wFull().h(s.composerH))
        }

        // Start pinned at bottom; shrink composer -> ScrollSlack absorbs shrink without moving rows up
        var t = 0.0
        _ = rt.frame(at: t)
        #expect(rt.scrollAtBottom(forKey: "scroll") == true)
        let rowBefore = rt.element(byKey: "row-99")!.rect[1]

        rt.update(at: 0.02) { s, _ in s.composerH = 40 }
        t = 0.02
        _ = rt.frame(at: t + 1.0 / 120.0)
        // Right after composer shrinks from 80 -> 40, slack holds rows steady at rowBefore instead of dipping
        let rowHolding = rt.element(byKey: "row-99")!.rect[1]
        #expect(abs(rowHolding - rowBefore) < 0.5, "slack holds row-99 steady on composer shrink: \(rowBefore) vs \(rowHolding)")

        // During slack, viewport reports moving=true
        #expect(rt.element(byKey: "scroll")?.moving == true)

        // After > 0.12s without new growth, slack closes smoothly down to new bottom
        t += 0.25
        _ = rt.frame(at: t)
        t = settle(rt, start: t)
        let rowAfterClose = rt.element(byKey: "row-99")!.rect[1]
        #expect(abs(rowAfterClose - (rowBefore + 40)) < 0.5, "row-99 must move down 40pt after slack closes: \(rowBefore) -> \(rowAfterClose)")
        #expect(rt.scrollAtBottom(forKey: "scroll") == true)

        // With followEdge the final row stays on the moving dock throughout its resize.
        rt.update(at: t) { s, tx in
            s.composerH = 80
        }
        t = settle(rt, start: t)
        let rowDocked80 = rt.element(byKey: "row-99")!.rect[1]
        rt.update(at: t) { s, tx in
            s.composerH = 40
            tx.followEdge()
        }
        var largestGap: Float = 0
        for _ in 0..<90 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            let row = rt.element(byKey: "row-99")!.rect
            let dock = rt.element(byKey: "composer")!.rect
            largestGap = max(largestGap, abs(row[1] + row[3] - dock[1]))
        }
        #expect(largestGap < 0.5, "the last row stays on the presented dock each frame")
        #expect(abs(rt.element(byKey: "row-99")!.rect[1] - (rowDocked80 + 40)) < 0.5)

        // Scrolling wheel UP while slack active clears slack without a downward jump
        rt.update(at: t) { s, _ in s.composerH = 80 }
        t = settle(rt, start: t)
        rt.update(at: t) { s, _ in s.composerH = 40 }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let yBeforeWheel = rt.element(byKey: "row-99")!.rect[1]
        rt.wheelXY(150, 100, dx: 0, dy: 40, at: t + 0.005)
        t += 0.01
        _ = rt.frame(at: t)
        #expect(rt.scrollAtBottom(forKey: "scroll") == false)
        #expect(rt.element(byKey: "row-99")!.rect[1] > yBeforeWheel, "wheel up through slack must move content down without snapping up")

        // Instant resize / tx.instant lands any slack
        rt.update(at: t) { _, tx in tx.scrollToBottomInstant("scroll") }
        _ = rt.frame(at: t + 0.01)
        rt.update(at: t + 0.02) { s, _ in s.composerH = 80 }
        _ = rt.frame(at: t + 0.03)
        rt.setViewport(Vec2(300, 320), pixelScale: 1.0)
        _ = rt.frame(at: t + 0.04)
        #expect(rt.element(byKey: "scroll")?.moving == false, "viewport resize must land scroll slack")

        // scrollPage on unmounted virtual row key snaps cleanly and advances page on enclosing scroll viewport
        rt.update(at: t + 0.05) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 0) }
        _ = rt.frame(at: t + 0.06)
        #expect(rt.element(byKey: "row-95") == nil)
        rt.update(at: t + 0.07) { _, tx in tx.scrollPage("row-95", 1) }
        t = settle(rt, start: t + 0.07)
        #expect(rt.scrollOffset(forKey: "scroll").y > 150, "scrollPage via unmounted virtual row selector must scroll enclosing viewport forward")

        // PageUp / PageDown keys scroll the focused/active viewport when unhandled
        rt.pointerMove(to: Vec2(150, 100), at: t + 0.01)
        rt.pointerDown(at: Vec2(150, 100), at: t + 0.01)
        rt.pointerUp(at: Vec2(150, 100), at: t + 0.02)
        let beforePgUp = rt.scrollOffset(forKey: "scroll").y
        #expect(beforePgUp > 100)
        _ = rt.keyDown(KeyEvent(key: .pageUp), at: t + 0.03)
        t = settle(rt, start: t + 0.03)
        #expect(rt.scrollOffset(forKey: "scroll").y < beforePgUp)
    }

    // MARK: - el/virtual_rows.rs & runtime/virtual_store_tests.rs

    @Test("virtual_rows.rs: window build, shrink count, heights persist, culled unmount, version skip, visibleRows no-commit & memo")
    func virtualRowsLifecycleVersionVisibleMemoAndCull() {
        final class Counters: @unchecked Sendable {
            var viewRuns = 0
            var keyCalls = 0
            var rowBuilds: [Int] = []
            var memoBuilds = 0
        }
        let c = Counters()
        struct State {
            var count = 500
            var version = 0
            var keyPrefix = "a"
            var tick = 0
            var useMemo = false
            var commitOnVisible = false
            var lastVisible: Range<Int> = 0..<0
        }
        let rt = Runtime<State>(state: State(), viewport: Vec2(300, 200), pixelScale: 1.0) { s, _ in
            c.viewRuns += 1
            return col().size(300, 200).child(
                col().key("scroll").size(300, 200).scrollY(stickBottom: false).child(
                    col().key("rows").wFull().growth(.default)
                        .virtualRows(count: s.count, estimatedRowHeight: 20, key: { st, i in
                            c.keyCalls += 1
                            return "\(st.keyPrefix)\(i)"
                        }, build: { st, i in
                            c.rowBuilds.append(i)
                            if st.useMemo {
                                return memo("vrow-\(st.keyPrefix)-\(i)", st.keyPrefix) {
                                    c.memoBuilds += 1
                                    return col().h(20).child(text("row \(i)").h(20))
                                }
                            }
                            let h: Float = (i == 5) ? 35 : 20
                            return col().h(h).child(col().key("cell").child(text("row \(i) t\(st.tick)").key("txt").h(h)))
                        })
                        .virtualRowsVersion(s.version)
                        .onVisibleRows { st, range in
                            st.lastVisible = range
                            return st.commitOnVisible
                        }
                )
            )
        }
        var t = 0.0
        _ = rt.frame(at: t)
        t = settle(rt, start: t)

        // Only viewport + overscan rows build, never all 500!
        let initialBuilt = Set(c.rowBuilds)
        #expect(!initialBuilt.isEmpty && initialBuilt.count < 60)
        #expect(rt.element(byKey: "txt") != nil)
        #expect(rt.virtualLists.first(where: { $0.key.hasSuffix("/@rows") })?.value.measuredByKey["a5"] == 35)

        // version skips scanning all 500 keys when version & count unchanged
        c.keyCalls = 0
        rt.update(at: t + 0.01) { s, _ in s.tick += 1 }
        _ = rt.frame(at: t + 0.02)
        #expect(c.keyCalls < 120, "same version must not scan all 500 keys: \(c.keyCalls)")

        // Scroll slightly within overscan: onVisibleRows fires with commitOnVisible == false -> skips view commit!
        let runsBeforeScroll = c.viewRuns
        rt.wheelXY(150, 100, dx: 0, dy: -40, at: t + 0.03)
        _ = rt.frame(at: t + 0.04)
        #expect(rt.state.lastVisible.lowerBound >= 1)
        #expect(c.viewRuns == runsBeforeScroll, "returning false from onVisibleRows skips view commit")

        // commitOnVisible == true commits when visible range changes
        rt.update(at: t + 0.05) { s, _ in s.commitOnVisible = true }
        _ = rt.frame(at: t + 0.06)
        let runsAfterOptIn = c.viewRuns
        rt.wheelXY(150, 100, dx: 0, dy: -40, at: t + 0.07)
        _ = rt.frame(at: t + 0.08)
        #expect(c.viewRuns > runsAfterOptIn, "returning true from onVisibleRows triggers commit")

        // Scroll far away: measured height for a5 persists, and culled row 0 subtree unmounts immediately
        rt.wheelXY(150, 100, dx: 0, dy: -2000, at: t + 0.10)
        t = settle(rt, start: t + 0.11)
        #expect(rt.virtualLists.first(where: { $0.key.hasSuffix("/@rows") })?.value.measuredByKey["a5"] == 35)
        #expect(!rt.flatNodes.contains(where: { $0.path.contains("/a0/") }))

        // Version bump + count change refresh keys
        rt.update(at: t + 0.01) { s, tx in
            s.keyPrefix = "b"
            s.version += 1
            tx.scrollToInstant("scroll", x: 0, y: 0)
        }
        _ = rt.frame(at: t + 0.02)
        #expect(rt.element(byKey: "b0") != nil && rt.element(byKey: "a0") == nil)

        // Shrinking count below scroll offset shows remaining rows immediately
        rt.update(at: t + 0.03) { s, tx in tx.scrollToInstant("scroll", x: 0, y: 4000) }
        _ = rt.frame(at: t + 0.04)
        rt.update(at: t + 0.05) { s, _ in s.count = 6 }
        _ = rt.frame(at: t + 0.06)
        #expect(rt.element(byKey: "b5") != nil && rt.element(byKey: "b6") == nil)

        // Memoized rows build once across unrelated ticks and only new appended row builds
        rt.update(at: t + 0.07) { s, tx in
            s.useMemo = true
            s.count = 20
            tx.scrollToInstant("scroll", x: 0, y: 0)
        }
        _ = rt.frame(at: t + 0.08)
        let memoAfterFirst = c.memoBuilds
        rt.update(at: t + 0.09) { s, _ in s.tick += 1 }
        _ = rt.frame(at: t + 0.10)
        #expect(c.memoBuilds == memoAfterFirst, "ticks reuse memoized rows in window")
    }

    @Test("el/virtual_rows.rs & virtual_store_tests.rs: prepend at top/padding, virtualize parity & offscreen drop")
    func virtualPrependAtTopVirtualizeAndDrop() {
        final class HeldToken {}
        weak var weakToken: HeldToken?
        var token: HeldToken? = HeldToken()
        weakToken = token

        struct State {
            var ids: [Int] = Array(100..<160)
            var useVirtualize = true
            var topPad: Float = 8
        }
        let rt = Runtime<State>(state: State(), viewport: Vec2(300, 200), pixelScale: 1.0) { s, _ in
            let captured = token
            let stack: El<State>
            if s.useVirtualize {
                stack = col().key("stack").wFull().pt(s.topPad).virtualize(40).children(
                    s.ids.map { id in
                        let row: El<State> = el().key("m\(id)").wFull().h(40)
                        if id == 150, let held = captured {
                            return row.onClick { _, _ in _ = held }
                        }
                        return row
                    }
                )
            } else {
                stack = col().key("stack").wFull().pt(s.topPad).virtualRows(count: s.ids.count, estimatedRowHeight: 40, key: { st, i in
                    "m\(st.ids[i])"
                }, build: { st, i in
                    el().wFull().h(40)
                })
            }
            return col().size(300, 200).child(
                col().key("scroll").size(300, 200).scrollY(stickBottom: false).scrollAnchor(true).child(stack)
            )
        }
        _ = rt.frame(at: 0.0)
        token = nil
        let beforeTopY = rt.element(byKey: "m100")!.rect[1]
        #expect(beforeTopY == 8)

        // Prepend 30 rows while at top (scroll offset 0) with top padding showing: anchor keeps m100 steady or non-negative
        rt.update(at: 0.02) { s, _ in
            s.ids = Array(70..<100) + s.ids
        }
        _ = rt.frame(at: 0.04)
        let afterTopY = rt.element(byKey: "m100")!.rect[1]
        #expect(abs(afterTopY - beforeTopY) < 0.5)

        // Switching to .virtualRows replaces stored/offscreen rows and releases the held closure token
        rt.update(at: 0.06) { s, _ in
            s.useVirtualize = false
        }
        _ = rt.frame(at: 0.08)
        #expect(weakToken == nil, "replaced offscreen .virtualize row closures must drop")
    }

    @Test("virtual_rows.rs: aspectFit rows, duplicate key warnings/rename, first-showing overscan/reveal & scrolled-out typing")
    func virtualRowsAspectFitDuplicatesRevealAndOffscreenTyping() throws {
        // 1. rows_measure_an_aspect_fit_element_at_its_fitted_size
        let fitRt = Runtime<Int>(state: 20, viewport: Vec2(300, 500), pixelScale: 1.0) { s, _ in
            col().sizeFull().child(
                col().key("scroll").wFull().grow(1).scrollY(stickBottom: false).child(
                    col().key("rows").wFull().growth(.default).virtualRows(count: s, estimatedRowHeight: 50, key: { _, i in "r\(i)" }, build: { _, _ in
                        col().wFull().child(el().key("pic").maxH(80).aspectFit(2.0))
                    })
                )
            )
        }
        var t = 0.0
        _ = fitRt.frame(at: t)
        t = settle(fitRt, start: t)
        for i in 0..<5 {
            let p = fitRt.elements().first(where: { $0.path.hasSuffix("/@rows/@r\(i)/@pic") })
            #expect(p != nil)
            if let rect = p?.rect {
                #expect(abs(rect[1] - Float(i) * 80) < 0.5)
                #expect(abs(rect[2] - 160) < 0.5 && abs(rect[3] - 80) < 0.5)
            }
        }
        #expect(abs((fitRt.virtualLists.values.first?.measuredByKey["r3"] ?? 0) - 80) < 0.5)

        // 2. duplicate_row_keys_are_renamed_instead_of_panicking + tooling_records_duplicate_keys_inside_a_row
        let dupRt = Runtime<Int>(state: 4, viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            col().key("scroll").size(200, 200).scrollY(stickBottom: false).child(
                col().key("rows").wFull().growth(.default).virtualRows(count: s, estimatedRowHeight: 40, key: { _, _ in "dup" }, build: { _, i in
                    col().h(20).child(el().key("a").h(10)).child(el().key(i == 1 ? "a" : "b").h(10))
                })
            )
        }
        _ = dupRt.frame(at: 0.0)
        let dupKeys = dupRt.elements().compactMap(\.key).filter { $0.hasPrefix("dup") }
        #expect(dupKeys == ["dup", "dup#dup1", "dup#dup2", "dup#dup3"])
        #expect(dupRt.elements().contains(where: { $0.key == "a#dup1" }))
        #expect(!dupRt.keyWarnings.isEmpty)

        // 3. a_first_showing_reveals_its_last_row_taller_than_estimated + overscan fill
        struct GridState {
            var show = false
            var count = 20
        }
        let gridRt = Runtime<GridState>(state: GridState(), viewport: Vec2(300, 500), pixelScale: 1.0) { s, _ in
            let body: El<GridState> = s.show
                ? col().key("scroll").wFull().grow(1).minH(0).scrollY(stickBottom: false).child(
                    col().key("rows").wFull().growth(.default).virtualRows(count: s.count, estimatedRowHeight: 50, key: { _, i in "g\(i)" }, build: { _, i in
                        el().wFull().h(74.4)
                    })
                )
                : text("root").key("root")
            return col().sizeFull().children([el().key("header").wFull().h(100), body, el().key("footer").wFull().h(50)])
        }
        _ = gridRt.frame(at: 0.0)
        gridRt.update(at: 0.02) { s, tx in
            s.show = true
            tx.scrollIntoView("g19")
            tx.instant()
        }
        _ = gridRt.frame(at: 0.04)
        let vpRect = try #require(gridRt.element(byKey: "scroll")).rect
        let g19El = gridRt.element(byKey: "g19")
        let g19 = try #require(g19El).rect
        #expect(g19[1] >= vpRect[1] - 0.5 && g19[1] + g19[3] <= vpRect[1] + vpRect[3] + 0.5)

        // 4. a_focused_field_in_a_row_scrolled_out_keeps_typing
        struct EditRows {
            var edits: [TextEdit] = (0..<100).map { _ in TextEdit("") }
        }
        let editRt = Runtime<EditRows>(state: EditRows(), viewport: Vec2(200, 200), pixelScale: 1.0) { _, _ in
            col().key("viewport").size(200, 200).scrollY(stickBottom: false).child(
                col().key("rows").wFull().growth(.default).virtualRows(count: 100, estimatedRowHeight: 40, key: { _, i in "row/\(i)" }, build: { _, i in
                    col().size(200, 40).child(textInput(key: "field", \EditRows.edits[i]).size(200, 40))
                })
            )
        }
        _ = editRt.frame(at: 0.0)
        editRt.pointerDown(at: Vec2(50, 16), at: 0.01)
        editRt.pointerUp(at: Vec2(50, 16), at: 0.015)
        _ = editRt.frame(at: 0.018)
        editRt.wheelXY(100, 100, dx: 0, dy: -2000, at: 0.02)
        _ = editRt.frame(at: 0.04)
        #expect(editRt.element(byKey: "row/0") == nil, "focused row scrolled out")
        #expect(editRt.element(byKey: "field")?.focused == false)
        _ = editRt.keyDown(KeyEvent(key: .text("offscreen")), at: 0.06)
        _ = editRt.frame(at: 0.08)
        #expect(editRt.state.edits[0].text == "offscreen")
    }

    @Test("virtual_rows.rs: retry pass keeps prior commit memos and mounts full overscan")
    func virtualRowsRetryPassKeepsLastCommit() {
        final class Built: @unchecked Sendable {
            var indices: [Int] = []
        }
        let built = Built()
        let rt = Runtime<[Float]>(state: Array(repeating: 50, count: 1000), viewport: Vec2(300, 500), pixelScale: 1.0) { rows, _ in
            col().sizeFull().child(
                col().key("scroll").size(300, 500).scrollY(stickBottom: false).child(
                    col().key("rows").wFull().growth(.default).virtualRows(count: rows.count, estimatedRowHeight: 50, key: { _, i in "r\(i)" }, build: { s, i in
                        let h = s[i]
                        return memo("retry-\(i)", h) {
                            built.indices.append(i)
                            return el().wFull().h(h)
                        }
                    })
                )
            )
        }
        var t = 0.0
        _ = rt.frame(at: t)
        rt.wheelXY(150, 250, dx: 0, dy: -10_000, at: 0.01)
        t = settle(rt, start: 0.01, maxSteps: 240)
        let beforeCollapse = rt.virtualLists.values.first?.lastMountedRange ?? 0..<0
        #expect(beforeCollapse == 180..<230)

        rt.wheelXY(150, 250, dx: 0, dy: -100, at: t + 0.01)
        _ = rt.frame(at: t + 0.01 + 1.0 / 120.0)
        #expect(rt.virtualLists.values.first?.lastMountedRange == 180..<230)

        built.indices.removeAll()
        rt.update(at: t + 0.03) { rows, _ in
            for i in 182..<232 { rows[i] = 1 }
        }
        _ = rt.frame(at: t + 0.04)
        let afterRetry = rt.virtualLists.values.first?.lastMountedRange ?? 0..<0
        #expect(afterRetry.lowerBound == 162, "retry expands upward and isn't capped by per-frame budget")
        #expect(!built.indices.contains(180) && !built.indices.contains(181), "prior commit memos stay unbuilt: \(built.indices)")
        #expect(built.indices.count < 120)
        #expect(rt.element(byKey: "r180") != nil && rt.element(byKey: "r181") != nil)
    }

    @Test("virtual_rows.rs: first-showing maxH/short-retry estimates, far-below reveal & 5k O(window) throughput")
    func virtualRowsFirstShowingEstimatesRevealAndScale() throws {
        func assertCovered<S>(_ rt: Runtime<S>, _ label: String) {
            guard let vp = rt.elements().first(where: { $0.path.hasSuffix("/@scroll") })?.rect else {
                Issue.record("\(label): missing @scroll viewport")
                return
            }
            let rows = rt.elements()
                .filter { $0.key?.hasPrefix("g") == true }
                .map { ($0.rect[1], $0.rect[1] + $0.rect[3]) }
                .sorted { $0.0 < $1.0 }
            #expect(!rows.isEmpty, "\(label): expected visible rows")
            var y = vp[1]
            for (top, bottom) in rows {
                #expect(top <= y + 0.5, "\(label): blank from \(y) to \(top)")
                y = max(y, bottom)
            }
            #expect(y >= vp[1] + vp[3] - 0.5, "\(label): blank below \(y) in \(vp)")
        }

        final class Counters: @unchecked Sendable {
            var passes = 0
        }

        // 1. a_first_showing_estimated_short_still_fills_its_viewport
        let c1 = Counters()
        let shortRt = Runtime<Bool>(state: false, viewport: Vec2(300, 500), pixelScale: 1.0) { show, _ in
            let body: El<Bool> = show
                ? col().key("scroll").wFull().grow(1).minH(0).scrollY(stickBottom: false).child(
                    col().key("rows").wFull().growth(.default).virtualRows(count: 20, estimatedRowHeight: 74.4, key: { _, i in "g\(i)" }, build: { _, i in
                        if i == 0 { c1.passes += 1 }
                        return el().wFull().h(74.4)
                    })
                )
                : text("root").key("root")
            return col().sizeFull().children([el().key("header").wFull().h(360).mb(-340), body, el().key("footer").wFull().h(50)])
        }
        _ = shortRt.frame(at: 0.0)
        shortRt.update(at: 0.02) { s, _ in s = true }
        c1.passes = 0
        _ = shortRt.frame(at: 0.02 + 1.0 / 120.0)
        assertCovered(shortRt, "short estimate")
        let shortVp = try #require(shortRt.elements().first(where: { $0.path.hasSuffix("/@scroll") })?.rect)
        #expect(abs(shortVp[3] - 430) < 0.5)
        #expect((shortRt.virtualLists.values.first?.lastMountedRange.upperBound ?? 99) < 20)
        #expect(c1.passes <= 2)

        // 2. a_first_showing_in_a_window_that_fits_its_content_estimates_from_max_h
        let c2 = Counters()
        let fitWinRt = Runtime<Bool>(state: false, viewport: Vec2(300, 500), pixelScale: 1.0) { show, _ in
            let results: El<Bool>? = show
                ? col().key("scroll").wFull().maxH(350).scrollY(stickBottom: false).child(
                    col().key("rows").wFull().growth(.default).virtualRows(count: 20, estimatedRowHeight: 74.4, key: { _, i in "g\(i)" }, build: { _, i in
                        if i == 0 { c2.passes += 1 }
                        return el().wFull().h(74.4)
                    })
                )
                : nil
            var children: [El<Bool>] = [el().key("search").wFull().h(56)]
            if let r = results { children.append(r) }
            return col().wFull().children(children)
        }
        fitWinRt.fitHeight = true
        let contentH = fitWinRt.contentHeight()
        fitWinRt.setViewport(Vec2(300, contentH), pixelScale: 1.0)
        _ = fitWinRt.frame(at: 0.0)
        #expect(abs(fitWinRt.viewport.y - 56) < 0.5)
        fitWinRt.update(at: 0.02) { s, _ in s = true }
        c2.passes = 0
        _ = fitWinRt.frame(at: 0.02 + 1.0 / 120.0)
        #expect(c2.passes == 1, "measured once from scroll maxH")
        #expect(fitWinRt.virtualLists.values.first?.lastMountedRange == 0..<8)

        // 3. a_first_showing_in_an_absolute_popover_estimates_from_its_own_max_h
        let c3 = Counters()
        let popRt = Runtime<Bool>(state: false, viewport: Vec2(300, 500), pixelScale: 1.0) { show, _ in
            let popover: El<Bool>? = show
                ? col().key("scroll").absolute(x: 0, y: 32).wFull().maxH(300).scrollY(stickBottom: false).child(
                    col().key("rows").wFull().growth(.default).virtualRows(count: 20, estimatedRowHeight: 74.4, key: { _, i in "g\(i)" }, build: { _, i in
                        if i == 0 { c3.passes += 1 }
                        return el().wFull().h(74.4)
                    })
                )
                : nil
            let header: El<Bool> = el().key("header").wFull().h(32)
            return col().sizeFull().child(popover.map { header.child($0) } ?? header)
        }
        _ = popRt.frame(at: 0.0)
        popRt.update(at: 0.02) { s, _ in s = true }
        c3.passes = 0
        _ = popRt.frame(at: 0.02 + 1.0 / 120.0)
        #expect(c3.passes == 1, "measured once from popover maxH")
        #expect(popRt.virtualLists.values.first?.lastMountedRange == 0..<8)

        // 4. a_first_showing_reveals_a_row_below_its_first_window
        let belowRt = Runtime<Bool>(state: false, viewport: Vec2(300, 500), pixelScale: 1.0) { show, _ in
            let body: El<Bool> = show
                ? col().key("scroll").wFull().grow(1).minH(0).scrollY(stickBottom: false).child(
                    col().key("rows").wFull().growth(.default).virtualRows(count: 20, estimatedRowHeight: 74.4, key: { _, i in "g\(i)" }, build: { _, _ in
                        el().wFull().h(74.4)
                    })
                )
                : text("root").key("root")
            return col().sizeFull().children([el().key("header").wFull().h(100), body, el().key("footer").wFull().h(50)])
        }
        _ = belowRt.frame(at: 0.0)
        belowRt.update(at: 0.02) { show, tx in
            show = true
            tx.scrollIntoView("g16")
            tx.instant()
        }
        _ = belowRt.frame(at: 0.02 + 1.0 / 120.0)
        assertCovered(belowRt, "far-below reveal")
        let belowVp = try #require(belowRt.elements().first(where: { $0.path.hasSuffix("/@scroll") })?.rect)
        let g16Rect = try #require(belowRt.element(byKey: "g16")).rect
        #expect(g16Rect[1] >= belowVp[1] - 0.5 && g16Rect[1] + g16Rect[3] <= belowVp[1] + belowVp[3] + 0.5)

        // 5. virtual_rows_time (5k-row O(window) tick + scroll bound)
        struct PerfState {
            var tick = 0
            var count = 5000
        }
        final class PerfCounts: @unchecked Sendable {
            var builds = 0
        }
        let pc = PerfCounts()
        let perfRt = Runtime<PerfState>(state: PerfState(), viewport: Vec2(300, 500), pixelScale: 1.0) { s, _ in
            col().sizeFull().child(
                col().key("scroll").size(300, 500).scrollY(stickBottom: false).child(
                    col().key("rows").wFull().growth(.default).virtualRows(count: s.count, estimatedRowHeight: 72, key: { _, i in "m\(i)" }, build: { st, i in
                        memo("m-\(i)", st.tick >= 0 ? 1 : 0) {
                            pc.builds += 1
                            return col().wFull().h(72).child(text("msg \(i)").h(72))
                        }
                    })
                )
            )
        }
        var pt = 0.0
        _ = perfRt.frame(at: pt)
        #expect(pc.builds < 40)
        for _ in 0..<10 {
            pt += 1.0 / 120.0
            perfRt.update(at: pt) { s, _ in s.tick += 1 }
            _ = perfRt.frame(at: pt)
        }
        pc.builds = 0
        for _ in 0..<20 {
            pt += 1.0 / 120.0
            perfRt.update(at: pt) { s, _ in s.tick += 1 }
            _ = perfRt.frame(at: pt)
        }
        #expect(pc.builds == 0, "memoized 5k rows skip rebuild on parent ticks")
        for _ in 0..<20 {
            pt += 1.0 / 120.0
            perfRt.wheelXY(150, 250, dx: 0, dy: -600, at: pt)
            _ = perfRt.frame(at: pt)
        }
        #expect(pc.builds > 0 && pc.builds < 250, "scrolling 5k rows builds O(window), got \(pc.builds)")
    }
}
