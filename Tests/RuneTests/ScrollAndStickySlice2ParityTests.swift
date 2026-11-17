import Testing
import Foundation
@testable import Rune
import RuneMotion

@Suite("Scroll & Sticky Slice 2 Parity Tests (#1075)")
struct ScrollAndStickySlice2ParityTests {

    private func reqEl<S>(_ rt: Runtime<S>, _ key: String, file: String = #filePath, line: Int = #line) throws -> ElementInfo {
        let found = rt.elements().first { $0.key == key && !$0.exiting }
        return try #require(found, "Missing element '\(key)'", sourceLocation: SourceLocation(fileID: file, filePath: file, line: line, column: 1))
    }

    private func scrollPath<S>(in rt: Runtime<S>, forKey key: String) -> String? {
        rt.element(byKey: key)?.path
    }

    // MARK: - scroll_carried.rs (Zoom::Around, Within, Turned)

    @Test("scroll_carried: what_a_scroll_carries_is_measured_in_the_window_through_a_zoom")
    func whatAScrollCarriesIsMeasuredInWindowThroughZoom() throws {
        enum Zoom: CaseIterable {
            case around
            case within
            case turned
        }

        for z in Zoom.allCases {
            let rt = Runtime<Zoom>(state: z, viewport: Vec2(600, 600), pixelScale: 1.0, systemDark: true) { zoom, _ in
                var rows: El<Zoom> = col().key("rows").wFull()
                for i in 0..<30 {
                    rows = rows.child(el().key("row\(i)").wFull().h(40))
                }
                let inner: El<Zoom> = zoom == .within
                    ? col().key("zoom").wFull().scale(1.6).child(rows)
                    : rows
                let list: El<Zoom> = col().key("scroll").size(300, 200).scroll(stickBottom: false).child(inner)
                switch zoom {
                case .within:
                    return col().child(list)
                case .around:
                    return col().key("zoom").scale(1.6).child(list)
                case .turned:
                    return col().key("zoom").scale(1.6).rotate(0.3).child(list)
                }
            }
            var t = 0.0
            _ = rt.frame(at: t)
            let startEl = try reqEl(rt, "row3")
            let startX = startEl.rect[0] + startEl.carriedScrolled[0]
            let startY = startEl.rect[1] + startEl.carriedScrolled[1]

            rt.update(at: t) { _, tx in
                tx.scrollTo("scroll", x: 0, y: 300)
            }
            var carried: Float = 0
            var maximumDrift: Float = 0
            for _ in 0..<90 {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
                let e = try reqEl(rt, "row3")
                let x = e.rect[0] + e.carriedScrolled[0]
                let y = e.rect[1] + e.carriedScrolled[1]
                maximumDrift = max(maximumDrift, abs(x - startX), abs(y - startY))
                carried = max(carried, hypotf(e.carriedScrolled[0], e.carriedScrolled[1]))
            }
            #expect(maximumDrift <= 1.0, "\(z): row moved independently of the scroll by \(maximumDrift)pt")
            let expected: Float = (z == .within) ? 300.0 : 480.0
            #expect(abs(carried - expected) < 1.0, "\(z): 300pt scroll should carry \(expected)pt on screen, got \(carried)")
        }
    }

    // MARK: - stick_fit.rs

    @Test("stick_fit: rows_stay_put_across_the_fit_overflow_boundary", arguments: [false, true])
    func rowsStayPutAcrossFitOverflowBoundary(nativeRenderer: Bool) throws {
        struct S {
            var banner: Bool
            var rows: Int
            var end: Bool
            var virtualized: Bool
            var pad: Float
        }

        func run(_ initial: S, change: (inout S) -> Void) throws -> [(Float, Float)] {
            let rt = Runtime<S>(state: initial, viewport: Vec2(300, 400), pixelScale: 2.0, systemDark: true) { s, _ in
                var stack: El<S> = col().key("stack").wFull().pb(s.pad).growth(.default)
                if s.end {
                    stack = stack.grow(1.0).justifyEnd()
                }
                if s.virtualized {
                    stack = stack.virtualize(50)
                }
                for i in 0..<s.rows {
                    stack = stack.child(el().key("r\(i)").wFull().h(50))
                }
                return col().wFull().hFull()
                    .child(el().key("banner").wFull().h(s.banner ? 55 : 0))
                    .child(
                        col().key("scroll").wFull().grow(1).shrink().minH(0).scroll(stickBottom: true).child(stack)
                    )
            }
            func draw(at t: Double) {
                if nativeRenderer {
                    _ = rt.renderFrame(at: t)
                } else {
                    _ = rt.frame(at: t)
                }
            }
            var t = 0.0
            draw(at: t)
            for _ in 0..<60 {
                t += 1.0 / 120.0
                draw(at: t)
            }
            func sample() throws -> (Float, Float) {
                let first = try reqEl(rt, "r0")
                let last = try reqEl(rt, "r\(rt.state.rows - 1)")
                return (first.rect[1] + first.rect[3], last.rect[1] + last.rect[3])
            }
            var out: [(Float, Float)] = [try sample()]
            rt.update(at: t) { s, _ in change(&s) }
            for _ in 0..<120 {
                t += 1.0 / 120.0
                draw(at: t)
                out.append(try sample())
            }
            return out
        }

        for (virtualized, pad) in [(false, Float(0)), (true, Float(0)), (false, Float(12)), (true, Float(12))] {
            for (what, banner, change) in [
                ("closes", true, { (s: inout S) in s.banner = false }),
                ("opens", false, { (s: inout S) in s.banner = true }),
            ] {
                let endFrames = try run(S(banner: banner, rows: 7, end: true, virtualized: virtualized, pad: pad), change: change)
                let worst = endFrames.reduce(Float(0)) { max($0, abs($1.1 - (400 - pad))) }
                #expect(worst < 0.6, "end virtual=\(virtualized) pad=\(pad) \(what): last row left bottom by \(worst)")

                let topFrames = try run(S(banner: banner, rows: 7, end: false, virtualized: virtualized, pad: pad), change: change)
                var maxStep: Float = 0
                for i in 1..<topFrames.count {
                    maxStep = max(maxStep, abs(topFrames[i].1 - topFrames[i - 1].1))
                }
                #expect(maxStep < 4.0, "top virtual=\(virtualized) pad=\(pad) \(what): jumped \(maxStep)")
                let last = topFrames.last!.1
                let rest: Float = banner ? 350.0 : (400.0 - pad)
                #expect(abs(last - rest) < 0.05, "top virtual=\(virtualized) pad=\(pad) \(what): landed at \(last) != \(rest)")
            }
        }
    }

    @Test("stick_fit: a_new_row_in_a_bottom_aligned_list_pushes_the_others_up")
    func newRowInBottomAlignedListPushesOthersUp() throws {
        struct S { var rows = 5 }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 400), pixelScale: 2.0, systemDark: true) { s, _ in
            var stack: El<S> = col().key("stack").wFull().growth(.default).grow(1).justifyEnd()
            for i in 0..<s.rows {
                stack = stack.child(el().key("r\(i)").wFull().h(50))
            }
            return col().wFull().hFull()
                .child(el().key("banner").wFull().h(0))
                .child(col().key("scroll").wFull().grow(1).shrink().minH(0).scroll(stickBottom: true).child(stack))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        for _ in 0..<60 { t += 1.0 / 120.0; _ = rt.frame(at: t) }
        func sample() throws -> (Float, Float) {
            let r0 = try reqEl(rt, "r0")
            let rLast = try reqEl(rt, "r\(rt.state.rows - 1)")
            return (r0.rect[1] + r0.rect[3], rLast.rect[1] + rLast.rect[3])
        }
        var frames = [try sample()]
        rt.update(at: t) { s, _ in s.rows += 1 }
        for _ in 0..<120 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            frames.append(try sample())
        }
        let first = frames.map(\.0)
        var step: Float = 0
        for i in 1..<first.count { step = max(step, abs(first[i] - first[i - 1])) }
        #expect(step < 4.0)
        #expect(abs(first.last! - 150.0) < 0.05)
        #expect(frames.allSatisfy { abs($0.1 - 400.0) < 0.6 })
    }

    // MARK: - scroll/bottom.rs (3a, 3b, 3c)

    private struct BottomChatState {
        var rows: Int = 40
        var instant: Bool = false
        var sends: Bool = false
        var hasComposer: Bool = false
        var composer: TextEdit = TextEdit("")
    }

    private func makeBottomChat(_ state: BottomChatState) -> Runtime<BottomChatState> {
        let rt = Runtime<BottomChatState>(state: state, viewport: Vec2(200, 340), pixelScale: 2.0, systemDark: true) { s, _ in
            var stack: El<BottomChatState> = col().key("stack").wFull().growth(.default)
            for i in 0..<s.rows {
                let h: Float = 40.0 + Float(i % 3) * 10.0
                stack = stack.child(el().key("r\(i)").wFull().h(h))
            }
            let scroll = col().key("scroll").wFull().grow(1).shrink().scroll(stickBottom: true).child(stack)
            let root = col().key("pane").wFull().hFull()
                .child(scroll)
                .child(el().key("jump").wFull().h(40))
            guard s.hasComposer else { return root }
            let field = textInput(key: "composer", \BottomChatState.composer)
                .font(TextStyle(size: 14, weight: 400))
                .wFull()
                .focused(true)
            if s.sends {
                return root.child(
                    field.animateEditLayout().onSubmit { st, _, _ in
                        st.composer.clear()
                        st.rows += 1
                    }
                )
            }
            return root.child(
                col().key("composer-scroll").wFull().h(60).scroll(stickBottom: false).child(field)
            )
        }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 1.0 / 120.0)
        return rt
    }

    @Test("scroll/bottom: an_update_that_changes_nothing_still_scrolls")
    func anUpdateThatChangesNothingStillScrolls() throws {
        let rt = makeBottomChat(BottomChatState(rows: 40, instant: true))
        var t = 1.0 / 120.0
        for _ in 0..<5 {
            rt.wheel(WheelEvent(dx: 0, dy: 300), at: Vec2(100, 100), now: t)
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        for _ in 0..<60 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        let sPath = try #require(scrollPath(in: rt, forKey: "scroll"))
        let maxBefore = rt.scrollMaxExtents[sPath]?.y ?? 0
        #expect(rt.scrollOffset(forKey: "scroll").y < maxBefore - 1.0)

        let tookFrame = rt.updateIf(at: t) { _, tx in
            tx.scrollToBottomInstant("stack")
            return false
        }
        #expect(tookFrame, "a scroll request in updateIf must take a frame even when state did not change")
        #expect(rt.needsCommit)
        for _ in 0..<3 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        let maxAfter = rt.scrollMaxExtents[sPath]?.y ?? 0
        #expect(abs(rt.scrollOffset(forKey: "scroll").y - maxAfter) <= 1.0)
        #expect(rt.wasPinnedToBottom.contains(sPath))
    }

    @Test("scroll/bottom: page_keys_from_a_short_composer_page_the_message_list_beside_it")
    func pageKeysFromShortComposerPageMessageListBesideIt() throws {
        let edit = TextEdit("hello")
        let rt = makeBottomChat(BottomChatState(rows: 40, hasComposer: true, composer: edit))
        var t = 1.0 / 120.0
        let compPath = try #require(scrollPath(in: rt, forKey: "composer-scroll"))
        let listPath = try #require(scrollPath(in: rt, forKey: "scroll"))
        #expect((rt.scrollMaxExtents[compPath]?.y ?? -1) == 0.0, "draft fits its scroll area")
        let bottom = rt.scrollMaxExtents[listPath]?.y ?? 0
        let page = (rt.scrollViewportSizes[listPath]?.y ?? 0) * 0.9
        #expect(bottom > 3.0 * page)
        #expect(abs(rt.scrollOffset(forKey: "scroll").y - bottom) < 0.05)

        _ = rt.keyDown(KeyEvent(key: .pageUp), at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(abs(rt.scrollOffset(forKey: "scroll").y - (bottom - page)) < 0.05, "list pages, not composer")
        #expect(!rt.wasPinnedToBottom.contains(listPath))

        let compRect = try reqEl(rt, "composer").rect
        rt.pointerMove(to: Vec2(compRect[0] + compRect[2] * 0.5, compRect[1] + compRect[3] * 0.5), at: t)
        _ = rt.keyDown(KeyEvent(key: .pageUp), at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(abs(rt.scrollOffset(forKey: "scroll").y - (bottom - 2.0 * page)) < 0.05)

        for _ in 0..<2 {
            _ = rt.keyDown(KeyEvent(key: .pageDown), at: t)
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        #expect(abs(rt.scrollOffset(forKey: "scroll").y - bottom) < 0.05)
        #expect(rt.wasPinnedToBottom.contains(listPath), "back on end, list follows again")
        #expect(rt.element(byKey: "composer")?.focused == true)
        #expect(rt.state.composer.text == "hello")
    }

    @Test("scroll/bottom: rows_crossing_into_overflow_as_the_composer_shrinks_start_smoothly")
    func rowsCrossingIntoOverflowAsComposerShrinksStartSmoothly() throws {
        for lines in [2, 3] {
            let edit = TextEdit(Array(repeating: "line", count: lines).joined(separator: "\n"), multiline: true)
            let rt = makeBottomChat(BottomChatState(rows: 5, sends: true, hasComposer: true, composer: edit))
            var t = 1.0 / 120.0
            var ys = [try reqEl(rt, "r0").rect[1]]
            _ = rt.keyDown(KeyEvent(key: .enter), at: t)
            for _ in 0..<240 {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
                ys.append(try reqEl(rt, "r0").rect[1])
            }
            #expect(ys.last! < -5.0, "lines=\(lines): rows overflowed: \(ys.last!)")
            let steps = zip(ys.dropFirst(), ys).map(-)
            for (s1, s2) in zip(steps.dropFirst(), steps) {
                #expect(abs(s1 - s2) < 1.5, "lines=\(lines): r0 speed kick \(s1 - s2)pt")
            }
        }
    }

    // MARK: - row_reorder_tests.rs

    @Test("row_reorder: a_row_that_moves_and_grows_slides_without_a_step")
    func rowThatMovesAndGrowsSlidesWithoutStep() throws {
        struct RowItem { var key: String; var h: Float }
        let initial = [
            RowItem(key: "m0", h: 120),
            RowItem(key: "m1", h: 60),
            RowItem(key: "m2", h: 90),
            RowItem(key: "w", h: 77),
            RowItem(key: "a", h: 53),
            RowItem(key: "b", h: 53),
        ]
        let rt = Runtime<[RowItem]>(state: initial, viewport: Vec2(300, 300), pixelScale: 2.0, systemDark: true) { rows, _ in
            var stack: El<[RowItem]> = col().key("stack").wFull().p(12).gap(8).growth(.default)
            for r in rows {
                stack = stack.child(el().key(r.key).wFull().h(r.h).bg(.white))
            }
            return col().wFull().hFull().child(col().key("scroll").wFull().h(300).scroll(stickBottom: true).child(stack))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        for _ in 0..<240 { t += 1.0 / 120.0; _ = rt.frame(at: t) }
        #expect(!rt.isAnimating)
        let a0 = try reqEl(rt, "a").rect[1]
        let w0 = try reqEl(rt, "w").rect[1]
        let b0 = try reqEl(rt, "b").rect[1]

        rt.update(at: t) { rows, _ in
            rows[4].h = 77
            let moved = rows.remove(at: 4)
            rows.insert(moved, at: 3)
        }
        var frames: [[Float]] = []
        for _ in 0..<120 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            frames.append([try reqEl(rt, "a").rect[1], try reqEl(rt, "w").rect[1], try reqEl(rt, "b").rect[1]])
        }
        #expect(!rt.isAnimating)
        let end = frames[119]
        #expect(abs((end[1] - end[0]) - 85.0) < 0.01)

        func expectSlides(_ name: String, from: Float, to: Float, ys: [Float], step: Float) {
            var last = from
            for (f, y) in ys.enumerated() {
                #expect(abs(y - last) <= step, "\(name) jumps \(y - last) at frame \(f)")
                #expect((y - last) * (to - from) >= -0.01, "\(name) reversed at frame \(f)")
                last = y
            }
            #expect(abs(ys[0] - from) > 0.01, "\(name) moves on the commit frame")
            #expect(abs(ys.last! - to) < 0.01)
        }
        expectSlides("a", from: a0, to: end[0], ys: frames.map { $0[0] }, step: 8.0)
        expectSlides("w", from: w0, to: end[1], ys: frames.map { $0[1] }, step: 8.0)
        var lastB = b0
        for (f, y) in frames.map({ $0[2] }).enumerated() {
            #expect(abs(y - lastB) <= 8.0, "b jumps \(y - lastB) at frame \(f)")
            lastB = y
        }
    }

    // MARK: - scroll/sticky.rs

    @Test("scroll/sticky: a_missing_reveal_target_or_viewport_is_pruned_during_other_growth")
    func missingRevealTargetOrViewportIsPrunedDuringOtherGrowth() {
        struct S {
            var height: Float = 37
            var removed: Bool = false
            var hidden: Bool = false
        }
        for hidden in [false, true] {
            let rt = Runtime<S>(state: S(), viewport: Vec2(300, 200), pixelScale: 1.0, systemDark: true) { s, _ in
                if s.hidden { return el() }
                var stack: El<S> = col().key("stack").wFull().growth(.default)
                    .child(el().key("lead").wFull().h(400))
                    .child(el().key("grow").wFull().h(s.height))
                if !s.removed {
                    stack = stack.child(el().key("tail").wFull().h(35))
                }
                return col().key("scroll").size(300, 200).scroll(stickBottom: true).child(stack)
            }
            var t = 0.0
            _ = rt.frame(at: t)
            rt.update(at: t) { s, tx in
                s.height = 130
                tx.scrollIntoView("tail")
            }
            t += 1.0 / 120.0
            _ = rt.frame(at: t)

            rt.update(at: t) { s, _ in
                s.removed = true
                s.hidden = hidden
                s.height = 300
            }
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            #expect(rt.scrollRequestsState.reveals.isEmpty, "missing reveal targets must be pruned despite unrelated growth")
            for _ in 0..<240 {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
            }
            #expect(!rt.isAnimating)
        }
    }

    // MARK: - tests/scroll_growth.rs

    private func shrinkingList() -> (Runtime<Int>, Double) {
        let rt = Runtime<Int>(state: 20, viewport: Vec2(200, 300), pixelScale: 2) { count, _ in
            let rows = (0..<count).map { el().key("r\($0)").h(100).wFull() as El<Int> }
            let stack = col().key("stack").wFull().growth(.default).children(rows)
            return col().key("root").child(col().key("scroll").h(300).wFull().scroll(stickBottom: true).child(stack))
        }
        var now = 1.0 / 120.0
        rt.frame(at: 0)
        rt.frame(at: now)
        rt.wheel(WheelEvent(dy: 200), at: Vec2(100, 100), now: now)
        advance(rt, frames: 30, at: &now)
        #expect(abs(rt.scrollOffset(forKey: "scroll").y - 1500) < 0.05)
        return (rt, now)
    }

    private func advance<S>(_ rt: Runtime<S>, frames: Int, at now: inout Double) {
        for _ in 0..<frames {
            now += 1.0 / 120.0
            rt.frame(at: now)
        }
    }

    @Test("scroll_growth: a_shrink_glide_follows_the_end_as_it_moves")
    func shrinkGlideFollowsEndAsItMoves() throws {
        let (rt, start) = shrinkingList()
        var now = start
        let path = try #require(scrollPath(in: rt, forKey: "scroll"))
        let id = NodeId.hash("scroll:" + path)
        rt.update(at: now) { count, _ in count = 15 }
        advance(rt, frames: 8, at: &now)
        let before = try #require(rt.scrollStore.velocity(id, Props.SCROLL)?.y)
        #expect(abs(before) > 1)

        rt.update(at: now) { count, _ in count = 10 }
        advance(rt, frames: 1, at: &now)
        let after = try #require(rt.scrollStore.velocity(id, Props.SCROLL)?.y)
        #expect(rt.scrollStore.target(id, Props.SCROLL)?.y == 700)
        #expect(abs(after) >= abs(before) * 0.5, "the glide keeps its speed when retargeted")
        advance(rt, frames: 120, at: &now)
        #expect(abs(rt.scrollOffset(forKey: "scroll").y - 700) < 0.01)

        let (regrowing, regrowthStart) = shrinkingList()
        var time = regrowthStart
        regrowing.update(at: time) { count, _ in count = 15 }
        advance(regrowing, frames: 8, at: &time)
        regrowing.update(at: time) { count, _ in count = 20 }
        advance(regrowing, frames: 1, at: &time)
        let regrowthPath = try #require(scrollPath(in: regrowing, forKey: "scroll"))
        #expect(!regrowing.scrollGlidingPaths.contains(regrowthPath))
        let stopped = regrowing.scrollOffset(forKey: "scroll").y
        advance(regrowing, frames: 60, at: &time)
        #expect(regrowing.scrollOffset(forKey: "scroll").y == stopped)
    }

    @Test("scroll_growth: a_hand_scroll_mid_shrink_keeps_the_viewport")
    func handScrollMidShrinkKeepsTheViewport() throws {
        let (rt, start) = shrinkingList()
        var now = start
        let path = try #require(scrollPath(in: rt, forKey: "scroll"))
        rt.update(at: now) { count, _ in count = 15 }
        advance(rt, frames: 6, at: &now)
        try #require(rt.scrollGlidingPaths.contains(path))

        rt.wheel(WheelEvent(dy: 10), at: Vec2(100, 100), now: now)
        for _ in 0..<120 {
            advance(rt, frames: 1, at: &now)
            try #require(!rt.scrollGlidingPaths.contains(path), "the hand keeps the viewport as rows settle")
        }
    }

    @Test("scroll_growth: a_kept_row_holds_its_viewport_through_a_shrink")
    func keptRowHoldsItsViewportThroughShrink() throws {
        let (rt, start) = shrinkingList()
        var now = start
        let path = try #require(scrollPath(in: rt, forKey: "scroll"))
        let top = try reqEl(rt, "r15").rect[1]
        rt.update(at: now) { count, tx in
            count = 17
            tx.keepOnScreen("r15")
        }
        for _ in 0..<20 {
            advance(rt, frames: 1, at: &now)
            try #require(!rt.scrollGlidingPaths.contains(path))
            let position = try reqEl(rt, "r15").rect[1]
            #expect(abs(position - top) < 0.5)
        }
    }

    @Test("scroll_growth: rows_regrowing_under_a_shrink_glide_stay_near")
    func rowsRegrowingUnderShrinkGlideStayNear() throws {
        struct S { var count: Int = 20; var farEvents: [Bool] = [] }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 300), pixelScale: 2.0, systemDark: true) { s, _ in
            var stack: El<S> = col().key("stack").wFull().growth(.default)
            for i in 0..<s.count { stack = stack.child(el().key("r\(i)").h(100).wFull()) }
            let sc = col().key("scroll").h(300).wFull().scroll(stickBottom: true)
                .onFarFromBottom(300) { st, far in st.farEvents.append(far) }
                .child(stack)
            return col().key("root").child(sc)
        }
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 120.0; _ = rt.frame(at: t)
        rt.wheel(WheelEvent(dx: 0, dy: 600), at: Vec2(100, 100), now: t)
        for _ in 0..<30 { t += 1.0 / 120.0; _ = rt.frame(at: t) }
        #expect(rt.state.farEvents.last == true)
        rt.update(at: t) { s, _ in s.farEvents.removeAll(); s.count = 5 }

        let sPath = try #require(scrollPath(in: rt, forKey: "scroll"))
        var reached = false
        for f in 0..<120 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            #expect(rt.scrollGlidingPaths.contains(sPath), "frame \(f): glide must stay active until 850")
            if rt.scrollOffset(forKey: "scroll").y < 850.0 {
                reached = true
                break
            }
        }
        #expect(reached)
        rt.update(at: t) { s, _ in s.count = 12 }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(!rt.scrollGlidingPaths.contains(sPath))
        for _ in 0..<240 { t += 1.0 / 120.0; _ = rt.frame(at: t) }
        #expect(rt.state.farEvents == [false])
    }

    // MARK: - tests/scroll_spring.rs

    @Test("scroll_spring: without_a_spring_a_glide_runs_on_glide")
    func withoutSpringGlideRunsOnGlide() throws {
        let dt = 1.0 / 120.0
        func path(_ ask: (inout Tx) -> Void) -> [Float] {
            let rt = Runtime<Void>(state: (), viewport: Vec2(200, 300), pixelScale: 1.0, systemDark: true) { _, _ in
                var rows: El<Void> = col().key("rows").wFull()
                for k in 0..<400 { rows = rows.child(el().key("r\(k)").wFull().h(60)) }
                return col().size(200, 300).child(col().key("scroll").size(200, 300).scroll(stickBottom: false).child(rows))
            }
            var t = 0.0
            _ = rt.frame(at: t)
            rt.update(at: t) { _, tx in ask(&tx) }
            var offsets: [Float] = []
            for _ in 0..<120 {
                t += dt
                _ = rt.frame(at: t)
                offsets.append(rt.scrollOffset(forKey: "scroll").y)
            }
            return offsets
        }

        let glide = path { tx in tx.scrollTo("scroll", x: 0, y: 500) }
        let explicitGlide = path { tx in tx.scrollToWith("scroll", x: 0, y: 500, spring: MotionTokens.GLIDE) }
        #expect(glide == explicitGlide)

        var d: Float = -500
        var v: Float = 0
        for (f, y) in glide.prefix(30).enumerated() {
            (d, v) = MotionTokens.GLIDE.sample(from: d, velocity: v, target: 0, at: Float(dt))
            #expect(abs(y - (500 + d)) < 1e-3, "frame \(f): \(y) vs \(500 + d)")
        }
        #expect(glide.last == 500.0)
    }

    // MARK: - virtual/fill_resume_tests.rs

    @Test("virtual/fill_resume: a_wake_after_the_fill_completes_draws_nothing")
    func wakeAfterFillCompletesDrawsNothing() throws {
        final class Counter: @unchecked Sendable { var builds = 0 }
        struct Thinning {
            var counter = Counter()
            var short = false
            var gone = false
        }
        let rt = Runtime<Thinning>(state: Thinning(), viewport: Vec2(400, 200), pixelScale: 2.0, systemDark: true) { (s: Thinning, _) -> El<Thinning> in
            if s.gone { return el().key("empty").wFull().hFull() }
            let count = s.short ? 3 : 400
            let list: El<Thinning> = col().key("rows").wFull().growth(.default).virtualRows(
                count: count,
                estimatedRowHeight: 20,
                key: { (_: Thinning, i: Int) in "r\(i)" }
            ) { (st: Thinning, i: Int) -> El<Thinning> in
                let n = st.counter.builds
                st.counter.builds = n + 1
                let h: Float = n < 12 ? 20 : 4
                return el().key("r\(i)").wFull().h(h).bg(.white)
            }
            var otherRows: El<Thinning> = col().key("other-rows").wFull()
            for i in 0..<60 { otherRows = otherRows.child(el().key("o\(i)").wFull().h(20).bg(.white)) }
            let scroll: El<Thinning> = col().key("scroll").w(300).h(200).scroll(stickBottom: false).child(list)
            let other: El<Thinning> = col().key("other").w(80).h(200).scroll(stickBottom: false).child(otherRows)
            return row().wFull().hFull().child(scroll).child(other)
        }
        var t = 0.0
        _ = rt.frame(at: t)
        var drew = true
        var due: Double? = nil
        for _ in 0..<400 {
            if case .waiting = rt.virtualFill.phase {
                due = rt.nextWakeDeadline(after: t)
                break
            }
            if drew {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
                drew = rt.isAnimating || rt.needsCommit
            } else if let wake = rt.nextWakeDeadline(after: t) {
                t = max(t + 1.0 / 120.0, wake)
                _ = rt.frame(at: t)
                drew = rt.isAnimating || rt.needsCommit
            } else {
                Issue.record("fill stopped before bound: \(rt.virtualFill.phase)")
                break
            }
        }
        let waitDue = try #require(due, "fill should reach bound and arm a wake")

        rt.update(at: t) { s, _ in s.short = true }
        let dt = max(1.0 / 120.0, waitDue - t)
        t += dt
        _ = rt.frame(at: t)
        #expect(t >= waitDue - 1e-9)
        #expect(rt.virtualFill.phase == .idle)
        #expect((rt.animSources & AnimSource.virtualFill) == 0)
        #expect(rt.nextWakeDeadline(after: t) == nil)
    }

    // MARK: - tests/scroll_to.rs

    @Test("scroll_to: scroll_center_mounts_virtual_rows_and_centres_elements_and_text_highlights", arguments: [false, true])
    func scrollCenterMountsVirtualRowsAndCentresElementsAndTextHighlights(nativeFrame: Bool) throws {
        struct FindS { var hitRow = 40 }
        let rt = Runtime<FindS>(state: FindS(), viewport: Vec2(300, 300), pixelScale: 1.0, systemDark: true) { (_: FindS, _) -> El<FindS> in
            let rows: El<FindS> = col().key("rows").wFull().growth(.default).virtualRows(
                count: 80,
                estimatedRowHeight: 40,
                key: { (_: FindS, i: Int) in "r\(i)" }
            ) { (st: FindS, i: Int) -> El<FindS> in
                var body: El<FindS> = text("line a\nline b\nhit in row \(i)\nline d")
                    .font(TextStyle(size: 14, weight: 400, lineHeight: 20))
                if i == st.hitRow {
                    body = body.textHighlight(TextHighlight(14..<17, bg: .white, key: "active-hit"))
                }
                return col().wFull().py(10).child(body)
            }
            return col().wFull().hFull().child(
                col().key("list").wFull().h(200).scroll(stickBottom: false).child(rows)
            )
        }
        var t = 0.0
        func draw() {
            if nativeFrame {
                _ = rt.renderFrame(at: t)
            } else {
                _ = rt.frame(at: t)
            }
        }
        draw()

        rt.update(at: t) { _, tx in
            tx.scrollCenterIn("list", "r40/active-hit")
        }
        t += 1.0 / 60.0
        draw()
        var frames = 0
        while rt.isAnimating && frames < 600 {
            t += 1.0 / 60.0
            draw()
            frames += 1
        }
        #expect(!rt.isAnimating, "glide settled")
        #expect(frames > 4, "glided to match (\(frames) frames)")
        let mark1 = try reqEl(rt, "active-hit")
        let mid1 = mark1.rect[1] + mark1.rect[3] * 0.5
        #expect(abs(mid1 - 100.0) < 2.0, "highlight centred in 200pt viewport: \(mark1.rect)")

        rt.update(at: t) { s, tx in
            s.hitRow = 15
            tx.scrollCenterInInstant("list", "r15/active-hit")
        }
        t += 1.0 / 60.0
        draw()
        let mark2 = try reqEl(rt, "active-hit")
        let mid2 = mark2.rect[1] + mark2.rect[3] * 0.5
        #expect(abs(mid2 - 100.0) < 2.0, "instant centre in one frame: \(mark2.rect)")
        t += 1.0 / 60.0
        draw()
        let refined = try reqEl(rt, "active-hit")
        #expect(abs(refined.rect[1] + refined.rect[3] * 0.5 - 100) < 2.0)

        rt.update(at: t) { _, tx in
            tx.scrollKeyTo("active-hit", at: 24)
        }
        t += 1.0 / 60.0
        draw()
        let mark3 = try reqEl(rt, "active-hit")
        #expect(abs(mark3.rect[1] - 24.0) < 2.0, "scrollKeyTo placed TextHighlight at 24pt: \(mark3.rect)")
    }

    @Test("scroll_center aligns the top of a target taller than its viewport")
    func scrollCenterAlignsTallTargetToViewportTop() throws {
        let rt = Runtime<Void>(state: (), viewport: Vec2(200, 200), pixelScale: 1) { _, _ in
            col().key("list").size(200, 200).scroll(stickBottom: false).child(
                col().wFull()
                    .child(el().wFull().h(240))
                    .child(el().key("tall").wFull().h(300))
                    .child(el().wFull().h(240))
            )
        }
        _ = rt.frame(at: 0)
        rt.update(at: 0.01) { _, tx in tx.scrollCenterInInstant("list", "tall") }
        _ = rt.frame(at: 0.02)
        let target = try #require(rt.flatNodes.first { $0.key == "tall" })
        #expect(rt.lastCommittedSpecs[target.index].rect == target.targetRect)
        _ = rt.frame(at: 0.03)
        #expect(abs(rt.scrollOffset(forKey: "list").y - 240) < 1)
        #expect(abs(rt.element(byKey: "tall")?.rect[1] ?? .infinity) < 1)
    }

    // MARK: - tests/scroll_x.rs

    @Test("scroll_x: scroll_xy_scrolls_both_axes_one_gesture_at_a_time")
    func scrollXYScrollsBothAxesOneGestureAtATime() throws {
        let rt = Runtime<Void>(state: (), viewport: Vec2(300, 300), pixelScale: 1.0, systemDark: true) { _, _ in
            var grid: El<Void> = col()
            for r in 0..<6 {
                var rEl: El<Void> = row()
                for c in 0..<6 { rEl = rEl.child(el().key("cell\(r)-\(c)").size(100, 100)) }
                grid = grid.child(rEl)
            }
            return col().wFull().hFull().child(col().key("grid").wFull().h(200).scrollXY().child(grid))
        }
        var t = 0.0
        _ = rt.frame(at: t)

        rt.wheel(WheelEvent(dx: -40, dy: -10), at: Vec2(150, 100), now: t)
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        let c0a = try reqEl(rt, "cell0-0")
        #expect((c0a.rect[0], c0a.rect[1]) == (-40.0, 0.0))

        t += 0.15
        _ = rt.frame(at: t)
        rt.wheel(WheelEvent(dx: -10, dy: -60), at: Vec2(150, 100), now: t)
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        let c0b = try reqEl(rt, "cell0-0")
        #expect((c0b.rect[0], c0b.rect[1]) == (-40.0, -60.0))

        rt.update(at: t) { _, tx in tx.scrollIntoView("cell5-5") }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        let c5 = try reqEl(rt, "cell5-5")
        #expect((c5.rect[0], c5.rect[1]) == (200.0, 100.0))
    }

    @Test("scroll_x: a_touch_that_stops_momentum_starts_a_new_gesture")
    func touchThatStopsMomentumStartsNewGesture() throws {
        let rt = Runtime<Void>(state: (), viewport: Vec2(300, 300), pixelScale: 1.0, systemDark: true) { _, _ in
            var tiles: El<Void> = row()
            for i in 0..<10 { tiles = tiles.child(el().key("tile\(i)").size(100, 100).bg(.white)) }
            let strip = col().key("strip").wFull().h(100).scrollX().child(tiles)
            var pageRows: El<Void> = col().wFull().child(el().key("head").wFull().h(100)).child(strip)
            for i in 0..<20 { pageRows = pageRows.child(el().key("row\(i)").wFull().h(40)) }
            return col().wFull().hFull().child(col().key("page").wFull().h(300).scroll(stickBottom: false).child(pageRows))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        let tile0Start = try reqEl(rt, "tile0").rect[0]
        let headStart = try reqEl(rt, "head").rect[1]
        let stripY = try reqEl(rt, "tile0").rect[1] + 50.0

        rt.wheel(WheelEvent(dx: 0, dy: 0, phase: .began), at: Vec2(150, stripY), now: t)
        rt.wheel(WheelEvent(dx: -20, dy: 0, phase: .changed), at: Vec2(150, stripY), now: t)
        rt.wheel(WheelEvent(dx: 0, dy: 0, phase: .ended), at: Vec2(150, stripY), now: t)
        rt.wheel(WheelEvent(dx: 0, dy: 0, phase: .began), at: Vec2(150, stripY), now: t) // momentum
        rt.wheel(WheelEvent(dx: -10, dy: -2, phase: .changed), at: Vec2(150, stripY), now: t)
        rt.wheel(WheelEvent(dx: 0, dy: 0, phase: .ended), at: Vec2(150, stripY), now: t) // finger caught it
        rt.wheel(WheelEvent(dx: 0, dy: 0, phase: .began), at: Vec2(150, stripY), now: t)
        rt.wheel(WheelEvent(dx: -1, dy: -15, phase: .changed), at: Vec2(150, stripY), now: t)
        rt.wheel(WheelEvent(dx: 0, dy: 0, phase: .ended), at: Vec2(150, stripY), now: t)

        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        let tile0End = try reqEl(rt, "tile0").rect[0]
        let headEnd = try reqEl(rt, "head").rect[1]
        #expect((tile0End, headEnd) == (tile0Start - 30.0, headStart - 15.0))
    }

    // MARK: - tests/sticky.rs

    @Test("sticky: sticky_scroll_fade_preserves_an_intervening_explicit_clip")
    func stickyScrollFadePreservesInterveningExplicitClip() throws {
        let rt = Runtime<Void>(state: (), viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true) { _, _ in
            col().key("scroll").size(200, 200).scroll(stickBottom: false).scrollEdgeFade(16)
                .child(
                    col().wFull().clipFade(top: 8)
                        .child(el().key("header").wFull().h(24).bg(.white).stickyTop(0))
                        .child(el().wFull().h(600))
                )
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.0) { _, tx in
            tx.scrollToInstant("scroll", x: 0, y: 100)
        }
        let rf = rt.renderFrame(at: 0.0)
        let whiteFill = try #require(rf.instances.first {
            $0.fill.x > 0.999 && $0.fill.y > 0.999 && $0.fill.z > 0.999 && $0.fill.w == 1.0
        })
        #expect(abs(whiteFill.rect.y) < 0.01, "sticky header stays at the top of its viewport")
        #expect(unpackFade(whiteFill.fade).width.y == 8.0, "remove the scroll fade, not the explicit inner clip")
    }
}
