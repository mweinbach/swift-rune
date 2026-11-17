import Testing
import Foundation
#if canImport(simd)
import simd
#endif
@testable import Rune
@testable import RuneMotion

@Suite("Layout Read, Drawn Layout, Drawn Rect & Visible Parity")
struct LayoutReadParityTests {

    // MARK: - Helpers

    private func findInfo<S>(_ rt: Runtime<S>, key: String) -> ElementInfo? {
        rt.element(byKey: key)
    }

    private func stepFrames<S>(_ rt: Runtime<S>, count: Int, t: inout Double, dt: Double = 1.0 / 120.0) {
        for _ in 0..<count {
            t += dt
            _ = rt.frame(at: t)
        }
    }

    private func near4(_ a: [Float], _ b: [Float], tol: Float = 0.05) -> Bool {
        guard a.count == 4, b.count == 4 else { return false }
        return zip(a, b).allSatisfy { abs($0 - $1) <= tol }
    }

    enum PaintPath: CaseIterable { case reference, native, freshRaster }

    @Test(arguments: PaintPath.allCases, [false, true])
    func drawnLayoutUsesComposedPaintRotation(paintPath: PaintPath, raisedChild: Bool) {
        struct Sample {
            var row: [Float] = []
            var child: [Float] = []
        }
        let quarter = Float.pi / 2
        let cases: [(origin: Float, childTurn: Float, row: [Float], child: [Float])] = [
            (0.5, 0, [80, -80, 40, 200], [80, -80, 40, 200]),
            (0.5, quarter, [80, -80, 40, 200], [0, 0, 200, 40]),
            (0, 0, [-40, 0, 40, 200], [-40, 0, 40, 200]),
        ]
        for sample in cases {
            let runtime = Runtime(state: Sample(), viewport: Vec2(400, 400), pixelScale: 1) { _, _ in
                col().wFull().hFull().itemsStart().child(
                    col().size(200, 40).origin(sample.origin, sample.origin).rotate(quarter)
                        .onDrawnLayout { state, bounds in state.row = bounds }
                        .child(el().size(200, 40).raise(raisedChild).rotate(sample.childTurn)
                            .onDrawnLayout { state, bounds in state.child = bounds })
                )
            }
            for index in 0..<4 {
                let time = Double(index) / 60
                switch paintPath {
                case .reference: _ = runtime.frame(at: time)
                case .native: _ = runtime.renderFrame(at: time)
                case .freshRaster: _ = runtime.checkRestingRaster(at: time)
                }
            }
            #expect(near4(runtime.state.row, sample.row))
            #expect(near4(runtime.state.child, sample.child))
        }
    }

    @Test(arguments: [false, true])
    func drawnLayoutChangingItsParentsRotationSettles(gpuFrame: Bool) {
        struct Model {
            var turned = false
            var reports = 0
        }
        let runtime = Runtime(state: Model(), viewport: Vec2(400, 400), pixelScale: 1) { state, _ in
            col().wFull().hFull().itemsStart().child(
                col().size(200, 40).rotate(state.turned ? .pi / 2 : 0)
                    .child(el().size(200, 40).onDrawnLayout { state, _ in
                        state.turned.toggle()
                        state.reports += 1
                    })
            )
        }
        runtime.reducedMotion = true
        for index in 0..<45 {
            let time = Double(index) / 60
            if gpuFrame { _ = runtime.renderFrame(at: time) }
            else { _ = runtime.frame(at: time) }
        }
        #expect(runtime.state.reports == 4)
        #expect(!runtime.hasPendingActions && !runtime.hasPendingCommit)
    }

    // MARK: - Unit tests from crates/rune/src/runtime/layout_read.rs:633-702

    @Test("reads_of_one_key_count_once_per_function_and_once_for_the_whole_rect")
    func readDeduplicationAndSubsumption() {
        let collector = LayoutReadCollector()
        for _ in 0..<3 {
            collector.noteRead(key: "a", same: LayoutSame.size)
        }
        #expect(collector.reads.count == 1)
        if case .token(let tok, _) = collector.reads[0].same?.kind {
            #expect(tok == AnyHashable(LayoutSame.sizeToken))
        } else {
            Issue.record("Expected static token for LayoutSame.size")
        }

        let top: Float = 3.0
        collector.noteRead(key: "a", same: LayoutSame.make { r in r[1] < top })
        if case .shared? = collector.reads.last?.same?.kind {
            // expected
        } else {
            Issue.record("Expected shared closure predicate")
        }

        collector.noteRead(key: "b", same: LayoutSame.size)
        collector.noteRead(key: "a", same: nil)
        collector.noteRead(key: "a", same: LayoutSame.size)

        let kept = collector.reads.map { ($0.key, $0.same != nil) }
        #expect(kept.count == 4)
        #expect(kept[0].0 == "a" && kept[0].1 == true)
        #expect(kept[1].0 == "a" && kept[1].1 == true)
        #expect(kept[2].0 == "b" && kept[2].1 == true)
        #expect(kept[3].0 == "a" && kept[3].1 == false)
    }

    @Test("a_screen_rect_is_the_laid_out_rect_plus_the_window_origin")
    func screenRectAddsWindowOrigin() {
        struct S {
            var local: [[Float]] = []
            var screen: [[Float]] = []
        }
        let rt = Runtime(state: S(), viewport: Vec2(300, 200), pixelScale: 2.0) { (_: S, _: inout Cx<S>) -> El<S> in
            col().wFull().hFull().p(10)
                .child(
                    el().key("card").w(100).h(40)
                        .onLayout { s, r in s.local.append(r) }
                        .onScreenLayout { s, r in s.screen.append(r) }
                )
        }
        #expect(!rt.setWindowOrigin(Vec2(400, 250)), "nothing laid out yet")
        var t = 0.0
        _ = rt.frame(at: t)
        stepFrames(rt, count: 4, t: &t)
        #expect(rt.state.local == [[10, 10, 100, 40]])
        #expect(rt.state.screen == [[410, 260, 100, 40]])
    }

    @Test("moving_the_window_reports_screen_rects_without_a_relayout")
    func movingWindowReportsScreenRectsWithoutRelayout() {
        struct S {
            var local: [[Float]] = []
            var screen: [[Float]] = []
        }
        let rt = Runtime(state: S(), viewport: Vec2(300, 200), pixelScale: 2.0) { (_: S, _: inout Cx<S>) -> El<S> in
            col().wFull().hFull().p(10)
                .child(
                    el().key("card").w(100).h(40)
                        .onLayout { s, r in s.local.append(r) }
                        .onScreenLayout { s, r in s.screen.append(r) }
                )
        }
        _ = rt.setWindowOrigin(Vec2(400, 250))
        var t = 0.0
        _ = rt.frame(at: t)
        stepFrames(rt, count: 4, t: &t)
        let commits = rt.viewCommitCount

        // Window move queues screen report; onLayout stays silent
        #expect(rt.setWindowOrigin(Vec2(1700, -80)))
        stepFrames(rt, count: 2, t: &t)
        #expect(rt.state.screen.last == [1710, -70, 100, 40])
        #expect(rt.state.local.count == 1)

        // Sub-0.5pt drift waits, then accumulates
        #expect(!rt.setWindowOrigin(Vec2(1700.3, -80)))
        #expect(rt.setWindowOrigin(Vec2(1700.6, -80)))
        stepFrames(rt, count: 2, t: &t)
        #expect(rt.state.screen.count == 3)
        #expect(abs(rt.state.screen[2][0] - 1710.6) < 1e-3)

        // Coalesces rapid moves between frames to the latest origin
        _ = rt.setWindowOrigin(Vec2(1800, 0))
        _ = rt.setWindowOrigin(Vec2(1900, 0))
        stepFrames(rt, count: 2, t: &t)
        #expect(rt.state.screen.count == 4)
        #expect(rt.state.screen[3] == [1910, 10, 100, 40])
        #expect(rt.viewCommitCount > commits)

        let screenCount = rt.state.screen.count
        let settledCommits = rt.viewCommitCount
        stepFrames(rt, count: 10, t: &t)
        #expect(rt.state.screen.count == screenCount)
        #expect(rt.viewCommitCount == settledCommits)
    }

    @Test("a_window_move_with_no_screen_handler_asks_for_no_frame")
    func windowMoveWithNoScreenHandlerReturnsFalse() {
        struct S {
            var local: [[Float]] = []
        }
        let rt = Runtime(state: S(), viewport: Vec2(300, 200), pixelScale: 2.0) { (_: S, _: inout Cx<S>) -> El<S> in
            el().key("card").w(100).h(40).onLayout { s, r in s.local.append(r) }
        }
        var t = 0.0
        _ = rt.frame(at: t)
        stepFrames(rt, count: 2, t: &t)
        #expect(!rt.setWindowOrigin(Vec2(50, 50)))
        #expect(rt.state.local.count == 1)
    }

    // MARK: - crates/rune/tests/layout_read.rs parity

    @Test("a_view_places_from_another_elements_rect_in_the_same_commit")
    func bannerBadgePlacesInSameCommit() {
        final class Counter { var views = 0 }
        struct S {
            var banner = false
            var rects: [[Float]] = []
        }
        let counter = Counter()
        let rt = Runtime(state: S(), viewport: Vec2(300, 400), pixelScale: 2.0) { (s: S, cx: inout Cx<S>) -> El<S> in
            counter.views += 1
            #expect(cx.layout("no-such-key") == nil)
            var root: El<S> = col().wFull().hFull().p(10)
                .child(
                    el().key("banner").wFull().h(s.banner ? 55 : 20)
                        .onLayout { st, r in st.rects.append(r) }
                )
                .child(col().key("timeline").wFull().grow(1).shrink())
            if let r = cx.layout("banner") {
                root = root.child(el().key("badge").absolute(x: r[0] + r[2] - 30, y: r[1] + r[3]).size(30, 10))
            }
            return root
        }

        var t = 0.0
        _ = rt.frame(at: t)
        #expect(near4(findInfo(rt, key: "badge")!.target, [260, 30, 30, 10]))

        rt.update(at: t) { s, _ in s.banner = true }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(near4(findInfo(rt, key: "badge")!.target, [260, 65, 30, 10]))

        let viewsBefore = counter.views
        stepFrames(rt, count: 60, t: &t)
        #expect(counter.views == viewsBefore + 1, "one re-run for onLayout state change")
        #expect(rt.state.rects == [[10, 10, 280, 20], [10, 10, 280, 55]])

        let commits = rt.viewCommitCount
        stepFrames(rt, count: 10, t: &t)
        #expect(rt.viewCommitCount == commits)
    }

    @Test("scrolling_moves_a_read_rect_and_re_runs_its_reader")
    func scrollingMovesWindowLayoutReader() {
        final class Counter { var views = 0 }
        struct S {}
        let counter = Counter()
        let rt = Runtime(state: S(), viewport: Vec2(300, 400), pixelScale: 2.0) { (_: S, cx: inout Cx<S>) -> El<S> in
            counter.views += 1
            var sc: El<S> = col().key("scroll").wFull().h(300).scroll(stickBottom: false)
            var inner: El<S> = col().wFull()
            for i in 0..<40 {
                inner = inner.child(el().key("r\(i)").wFull().h(30).shrink(0))
            }
            sc = sc.child(inner)
            var root: El<S> = col().wFull().hFull().child(sc)
            if let r = cx.windowLayout("r10") {
                root = root.child(el().key("marker").absolute(x: 0, y: r[1]).size(10, 10))
            }
            return root
        }

        var t = 0.0
        _ = rt.frame(at: t)
        #expect(findInfo(rt, key: "marker")!.target[1] == 300)

        t += 1.0 / 120.0
        rt.wheel(WheelEvent(dx: 0, dy: -120), at: Vec2(100, 100), now: t)
        stepFrames(rt, count: 60, t: &t)

        let rowY = findInfo(rt, key: "r10")!.rect[1]
        #expect(rowY < 250)
        #expect(abs(findInfo(rt, key: "marker")!.target[1] - rowY) < 0.01)

        let viewsSettled = counter.views
        stepFrames(rt, count: 10, t: &t)
        #expect(counter.views == viewsSettled)
    }

    @Test("a_view_reading_its_own_size_settles_and_flip_flop_stops")
    func selfReadingSettlesAndOscillationStops() {
        final class Counter { var views = 0 }
        struct S {}

        // 1. Converges across responsive breakpoint
        let c1 = Counter()
        let rt1 = Runtime(state: S(), viewport: Vec2(600, 400), pixelScale: 2.0) { (_: S, cx: inout Cx<S>) -> El<S> in
            c1.views += 1
            let wide = cx.layout("card").map { $0[2] >= 400 } ?? false
            let body: El<S> = (wide ? row() : col()).key("body").gap(10)
                .child(el().key("a").w(150).h(40))
                .child(el().key("b").w(150).h(40))
            return col().wFull().p(10).child(col().key("card").wFull().child(body))
        }
        var t = 0.0
        _ = rt1.frame(at: t)
        #expect(findInfo(rt1, key: "b")!.target[1] == findInfo(rt1, key: "a")!.target[1])

        rt1.viewport = Vec2(300, 400)
        rt1.markNeedsCommit()
        stepFrames(rt1, count: 2, t: &t)
        #expect(findInfo(rt1, key: "b")!.target[1] > findInfo(rt1, key: "a")!.target[1])

        stepFrames(rt1, count: 20, t: &t)
        let views1 = c1.views
        let commits1 = rt1.viewCommitCount
        stepFrames(rt1, count: 20, t: &t)
        #expect(c1.views == views1)
        #expect(rt1.viewCommitCount == commits1)

        // 2. Flip-flop without a fixed point stops within PASSES=2 (<= 4 view runs per commit, 0 extra commits)
        let c2 = Counter()
        let rt2 = Runtime(state: S(), viewport: Vec2(600, 400), pixelScale: 2.0) { (_: S, cx: inout Cx<S>) -> El<S> in
            c2.views += 1
            let wide = cx.layout("chip").map { $0[2] > 100 } ?? false
            let label = wide ? "short" : "a much longer label than that"
            return col().wFull().itemsStart().child(row().key("chip").child(text(label)))
        }
        var t2 = 0.0
        _ = rt2.frame(at: t2)
        #expect(c2.views <= 4)
        stepFrames(rt2, count: 30, t: &t2)
        let v2 = c2.views
        let com2 = rt2.viewCommitCount
        stepFrames(rt2, count: 30, t: &t2)
        #expect(c2.views == v2)
        #expect(rt2.viewCommitCount == com2)
    }

    @Test("on_layout_feedback_settles")
    func onLayoutFeedbackSettles() {
        struct S {
            var growBy: Float
            var width: Float
            var rects: [[Float]] = []
        }

        // Fixed point: reports once and stops
        let rtFixed = Runtime(state: S(growBy: 0, width: 50), viewport: Vec2(600, 400), pixelScale: 2.0) { (s: S, _: inout Cx<S>) -> El<S> in
            col().wFull().itemsStart().child(
                el().key("bar").w(max(10, s.width)).h(10).onLayout { st, r in
                    st.rects.append(r)
                    st.width = r[2] + st.growBy
                }
            )
        }
        var t0 = 0.0
        _ = rtFixed.frame(at: t0)
        stepFrames(rtFixed, count: 30, t: &t0)
        #expect(rtFixed.state.rects.count == 1)

        // Runaway feedback stops after circuit breaker echoes and reopens on external update
        let rtRunaway = Runtime(state: S(growBy: 10, width: 50), viewport: Vec2(600, 400), pixelScale: 2.0) { (s: S, _: inout Cx<S>) -> El<S> in
            col().wFull().itemsStart().child(
                el().key("bar").w(max(10, s.width)).h(10).onLayout { st, r in
                    st.rects.append(r)
                    st.width = r[2] + st.growBy
                }
            )
        }
        var t1 = 0.0
        _ = rtRunaway.frame(at: t1)
        stepFrames(rtRunaway, count: 60, t: &t1)
        let reports = rtRunaway.state.rects.count
        #expect((2...6).contains(reports), "got \(reports) reports: \(rtRunaway.state.rects)")
        let commits = rtRunaway.viewCommitCount
        stepFrames(rtRunaway, count: 40, t: &t1)
        #expect(rtRunaway.state.rects.count == reports)
        #expect(rtRunaway.viewCommitCount == commits)

        // Pure invalidation alone does not replay missed echoes; external state change reopens feedback
        rtRunaway.markNeedsCommit()
        stepFrames(rtRunaway, count: 10, t: &t1)
        #expect(rtRunaway.state.rects.count == reports)

        rtRunaway.update(at: t1) { s, _ in s.width = 200 }
        stepFrames(rtRunaway, count: 60, t: &t1)
        #expect(rtRunaway.state.rects[reports] == [0, 0, 200, 10])
        #expect(rtRunaway.state.rects.count > reports + 1)
    }

    @Test("only_a_window_read_re_runs_its_view_while_the_element_scrolls")
    func scrollReRunsOnlyWindowLayoutReaders() {
        enum Mode { case size, rect, window }
        final class Counter { var views = 0 }
        struct S { var mode: Mode; var tall = false }

        func scrollRuns(_ mode: Mode) -> (views: Int, commits: Int) {
            let counter = Counter()
            let rt = Runtime(state: S(mode: mode), viewport: Vec2(300, 400), pixelScale: 2.0) { (s: S, cx: inout Cx<S>) -> El<S> in
                counter.views += 1
                var inner: El<S> = col().wFull()
                for i in 0..<40 {
                    let h: Float = (i == 10 && s.tall) ? 50 : 30
                    inner = inner.child(el().key("r\(i)").wFull().h(h).shrink(0))
                }
                let sz: [Float]? = switch s.mode {
                case .size: cx.layoutSize("r10")
                case .rect: cx.layout("r10").map { [$0[2], $0[3]] }
                case .window: cx.windowLayout("r10").map { [$0[2], $0[3]] }
                }
                var root: El<S> = col().wFull().hFull()
                    .child(col().key("scroll").wFull().h(300).scroll(stickBottom: false).child(inner))
                if let sz {
                    root = root.child(el().key("echo").w(sz[0]).h(sz[1]))
                }
                return root
            }
            var t = 0.0
            _ = rt.frame(at: t)
            stepFrames(rt, count: 10, t: &t)
            let v0 = counter.views
            let c0 = rt.viewCommitCount
            let before = findInfo(rt, key: "r10")!.rect[1]
            for _ in 0..<60 {
                t += 1.0 / 120.0
                rt.wheel(WheelEvent(dx: 0, dy: -3), at: Vec2(100, 100), now: t)
                _ = rt.frame(at: t)
            }
            let after = findInfo(rt, key: "r10")!.rect[1]
            #expect(after < before - 50)
            return (counter.views - v0, rt.viewCommitCount - c0)
        }

        let sizeRes = scrollRuns(.size)
        let rectRes = scrollRuns(.rect)
        let winRes = scrollRuns(.window)
        #expect(sizeRes == (0, 0))
        #expect(rectRes == (0, 0))
        #expect(winRes.views >= 50 && winRes.commits >= 50)
    }

    @Test("a_size_read_re_runs_only_on_resize_and_settles_first_frame")
    func sizeReadResizeAndSettle() {
        final class Counter { var views = 0 }
        struct S { var tall = false; var top: Float = 0 }
        let counter = Counter()
        let rt = Runtime(state: S(), viewport: Vec2(300, 400), pixelScale: 2.0) { (s: S, cx: inout Cx<S>) -> El<S> in
            counter.views += 1
            let sz = cx.layoutSize("third")
            var root: El<S> = col().wFull().hFull().itemsStart()
                .child(el().key("gap").w(10).h(s.top))
                .child(el().key("third").wFull().h(s.tall ? 50 : (100.0 / 3.0)))
            if let sz {
                root = root.child(el().key("echo").w(sz[0]).h(sz[1]))
            }
            return root
        }

        var t = 0.0
        _ = rt.frame(at: t)
        #expect(near4(Array(findInfo(rt, key: "echo")!.target[2...3]) + [0, 0], [300, 100.0 / 3.0, 0, 0], tol: 0.5))

        rt.update(at: t) { s, _ in s.tall = true }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(abs(findInfo(rt, key: "echo")!.target[3] - 50) < 0.1)

        // Viewport resize changes third's width
        rt.viewport = Vec2(420, 400)
        rt.markNeedsCommit()
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(abs(findInfo(rt, key: "echo")!.target[2] - 420) < 0.1)

        // Moving vertically without changing size does not trigger extra size re-runs
        for top: Float in [33.4, 50.0, 31.0, 64.1] {
            let vBefore = counter.views
            rt.update(at: t) { s, _ in s.top = top }
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            #expect(counter.views - vBefore == 1)
        }
    }

    @Test("layoutWith_only_re_runs_when_derived_value_flips")
    func layoutWithDerivedValueFlip() {
        final class Log { var seen: [Bool?] = [] }
        struct S {}
        let log = Log()
        let rt = Runtime(state: S(), viewport: Vec2(300, 400), pixelScale: 2.0) { (_: S, cx: inout Cx<S>) -> El<S> in
            let past = cx.windowLayoutWith("r1") { r in r[1] < 0 }
            log.seen.append(past)
            var inner: El<S> = col().wFull()
            for i in 0..<40 {
                inner = inner.child(el().key("r\(i)").wFull().h(30).shrink(0))
            }
            let header: El<S> = el().key(past == true ? "solid" : "clear").wFull().h(20)
            return col().wFull().hFull()
                .child(col().key("scroll").wFull().h(300).scroll(stickBottom: false).child(inner))
                .child(header)
        }

        var t = 0.0
        _ = rt.frame(at: t)
        stepFrames(rt, count: 10, t: &t)
        #expect(log.seen.last == false)
        #expect(findInfo(rt, key: "clear") != nil)

        log.seen.removeAll()
        let commitsBefore = rt.viewCommitCount
        var flippedAt: Int? = nil
        for f in 0..<20 {
            t += 1.0 / 120.0
            rt.wheel(WheelEvent(dx: 0, dy: -3), at: Vec2(100, 100), now: t)
            _ = rt.frame(at: t)
            let r1y = findInfo(rt, key: "r1")!.rect[1]
            if flippedAt == nil && r1y < 0 { flippedAt = f }
            #expect(log.seen.count == (flippedAt != nil ? 1 : 0))
        }
        #expect(log.seen == [true])
        #expect(findInfo(rt, key: "solid") != nil)
        #expect(rt.viewCommitCount - commitsBefore == 1)

        for _ in 0..<25 {
            t += 1.0 / 120.0
            rt.wheel(WheelEvent(dx: 0, dy: 3), at: Vec2(100, 100), now: t)
            _ = rt.frame(at: t)
        }
        #expect(log.seen == [true, false])
        #expect(findInfo(rt, key: "clear") != nil)
        #expect(rt.viewCommitCount - commitsBefore == 2)
    }

    @Test("whole_rect_and_size_read_of_same_key_and_gate_and_drift")
    func wholeRectPlusSizeAndGateAndDrift() {
        struct S { var width: Float = 100 }
        let rt1 = Runtime(state: S(), viewport: Vec2(300, 200), pixelScale: 2.0) { (s: S, cx: inout Cx<S>) -> El<S> in
            _ = cx.layout("bar")
            let w = cx.layoutSize("bar").map { $0[0] } ?? 0
            return col().wFull().itemsStart()
                .child(el().key("bar").w(s.width).h(10))
                .child(el().key("echo").w(w).h(10))
        }
        var t = 0.0
        _ = rt1.frame(at: t)
        rt1.update(at: t) { s, _ in s.width = 100.4 }
        t += 1.0 / 120.0
        _ = rt1.frame(at: t)
        #expect(abs(findInfo(rt1, key: "echo")!.target[2] - 100.4) < 1e-3)

        // Key unread on pass 0 keeps rect for pass 1
        final class Counter { var views = 0 }
        let c = Counter()
        let rt2 = Runtime(state: S(width: 100), viewport: Vec2(300, 200), pixelScale: 2.0) { (s: S, cx: inout Cx<S>) -> El<S> in
            c.views += 1
            let ready = cx.layout("a").map { abs($0[2] - s.width) < 0.01 } ?? false
            let b = ready ? cx.layout("b") : nil
            return col().wFull().itemsStart()
                .child(el().key("a").w(s.width).h(10))
                .child(el().key("b").w(50).h(10))
                .child(el().key("echo").w(b?[2] ?? 0).h(5))
        }
        var t2 = 0.0
        _ = rt2.frame(at: t2)
        stepFrames(rt2, count: 10, t: &t2)
        let viewsBefore = c.views
        rt2.update(at: t2) { s, _ in s.width = 200 }
        t2 += 1.0 / 120.0
        _ = rt2.frame(at: t2)
        #expect(findInfo(rt2, key: "echo")!.target[2] == 50)
        #expect(c.views - viewsBefore == 2)
    }

    @Test("feedback_circuit_breaker_reopens_on_first_scroll_frame")
    func scrollReopensAfterFeedbackQuiet() {
        struct S { var growBy: Float = 10; var width: Float = 50 }
        let rt = Runtime(state: S(), viewport: Vec2(600, 400), pixelScale: 2.0) { (s: S, cx: inout Cx<S>) -> El<S> in
            var inner: El<S> = col().wFull()
            for i in 0..<40 {
                inner = inner.child(el().key("r\(i)").wFull().h(30).shrink(0))
            }
            var root: El<S> = col().wFull().hFull().itemsStart()
                .child(col().key("scroll").wFull().h(300).scroll(stickBottom: false).child(inner))
                .child(el().key("bar").w(max(10, s.width)).h(10).onLayout { st, r in st.width = r[2] + st.growBy })
            if let r = cx.windowLayout("r10") {
                root = root.child(el().key("marker").absolute(x: 0, y: r[1]).size(10, 10))
            }
            return root
        }
        var t = 0.0
        _ = rt.frame(at: t)
        stepFrames(rt, count: 60, t: &t)
        let commits = rt.viewCommitCount
        stepFrames(rt, count: 10, t: &t)
        #expect(rt.viewCommitCount == commits)

        t += 1.0 / 120.0
        rt.wheel(WheelEvent(dx: 0, dy: -30), at: Vec2(100, 100), now: t)
        _ = rt.frame(at: t)
        #expect(abs(findInfo(rt, key: "marker")!.target[1] - findInfo(rt, key: "r10")!.rect[1]) < 0.01)
    }

    @Test("re_run_element_focus_preservation_and_animated_scrollTo_0_commits")
    func focusOnRerunAndAnimatedScrollToCommits() {
        // 1. Focus moves to editor placed on pass 1 and stays on newer field on remount
        struct EdState {
            var step = 0
            var first = TextEdit()
            var second = TextEdit()
        }
        let rt = Runtime(state: EdState(), viewport: Vec2(300, 200), pixelScale: 2.0) { (s: EdState, cx: inout Cx<EdState>) -> El<EdState> in
            var root: El<EdState> = col().wFull().hFull()
                .child(el().key("anchor").size(100, 20))
                .child(el().key("second").w(100).h(20).focusable().autofocus())
            if s.step == 0 {
                root = root.child(el().key("early").child(el().key("first").w(100).h(20).focusable().autofocus()))
            } else if s.step == 2, cx.layout("anchor") != nil {
                root = root.child(el().key("late").child(el().key("first").w(100).h(20).focusable().autofocus()))
            }
            return root
        }
        var t = 0.0
        _ = rt.frame(at: t)
        rt.update(at: t) { s, tx in
            s.step = 1
            tx.focus("second")
        }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        rt.update(at: t) { s, _ in s.step = 2 }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(rt.focusedKey == "second")

        // 2. Animated scroll_to + wheel triggers 0 commits when only Cx.layout("r10") is read
        final class Counter { var views = 0 }
        let counter = Counter()
        struct ScrollSt { var tall = false; var readText = "" }
        let rtS = Runtime(state: ScrollSt(), viewport: Vec2(300, 400), pixelScale: 2.0) { (s: ScrollSt, cx: inout Cx<ScrollSt>) -> El<ScrollSt> in
            counter.views += 1
            var inner: El<ScrollSt> = col().wFull()
            for i in 0..<40 {
                inner = inner.child(el().key("r\(i)").wFull().h((i == 10 && s.tall) ? 50 : 30).shrink(0))
            }
            let r = cx.layout("r10")
            return col().wFull().hFull()
                .child(col().key("scroll").wFull().h(300).scroll(stickBottom: false).child(inner))
                .child(text("\(r ?? [])").key("label"))
        }
        var ts = 0.0
        _ = rtS.frame(at: ts)
        stepFrames(rtS, count: 10, t: &ts)
        let commits0 = rtS.viewCommitCount
        let views0 = counter.views

        rtS.updateIf(at: ts) { _, tx in
            tx.scrollTo("scroll", offset: Vec2(0, 200), animated: true)
            return false
        }
        stepFrames(rtS, count: 60, t: &ts)
        #expect(abs(findInfo(rtS, key: "r10")!.rect[1] - 100) < 0.5)
        for _ in 0..<40 {
            ts += 1.0 / 120.0
            rtS.wheel(WheelEvent(dx: 0, dy: -3), at: Vec2(100, 100), now: ts)
            _ = rtS.frame(at: ts)
        }
        #expect(findInfo(rtS, key: "r10")!.rect[1] < 0)
        #expect(rtS.viewCommitCount == commits0)
        #expect(counter.views == views0)

        rtS.update(at: ts) { s, _ in s.tall = true }
        ts += 1.0 / 120.0
        _ = rtS.frame(at: ts)
        #expect(counter.views > views0)
    }

    // MARK: - crates/rune/tests/layout_reads.rs parity (>8 reads index & path selectors)

    @Test("layout_reads_index_threshold_and_scoped_selectors")
    func layoutKeyIndexAndScopedSelectors() {
        struct S {}
        let rt = Runtime(state: S(), viewport: Vec2(400, 400), pixelScale: 2.0) { (_: S, cx: inout Cx<S>) -> El<S> in
            var root: El<S> = col().wFull().hFull()
                .child(
                    col().key("a").child(
                        col().child(el().key("row").size(60, 20))
                    )
                )
                .child(
                    col().key("b").child(
                        col().child(el().key("row").size(120, 20))
                    )
                )
            for i in 0..<12 {
                root = root.child(el().key("item\(i)").size(Float(20 + i), 10))
            }
            let wa = cx.layout("a/row")?[2] ?? 0
            let wb = cx.layout("b/row")?[2] ?? 0
            var total = wa + wb
            for i in 0..<12 {
                total += cx.layout("item\(i)")?[2] ?? 0
            }
            return root.child(el().key("sum").w(total).h(10))
        }
        _ = rt.frame(at: 0)
        // Expected widths: 60 + 120 + sum(20..31 = 12 * 25.5 = 306) = 486
        #expect(findInfo(rt, key: "sum")!.target[2] == 486)
    }

    // MARK: - crates/rune/tests/drawn_layout.rs parity

    @Test("drawn_layout_waits_for_springs_ignores_color_and_tracks_live_and_scaled_drag")
    func drawnLayoutAndScaledDragParity() {
        struct S {
            var wide = false
            var hover = false
            var pan = Live(Vec2.zero)
            var drawn: [[Float]] = []
            var drags: [Vec2] = []
        }

        let rt = Runtime(state: S(), viewport: Vec2(400, 300), pixelScale: 1.0) { (s: S, _: inout Cx<S>) -> El<S> in
            let sp = Spring(duration: 0.25, bounce: 0)
            let w: Float = s.wide ? 200 : 100
            let bg: Color = s.hover ? .white : .black
            return col().wFull().hFull().itemsStart()
                .child(
                    col().key("parent").w(w).h(60).animate(sp)
                        .child(
                            el().key("node").w(100).h(40)
                                .scale(0.5)
                                .bg(bg)
                                .animate(sp)
                                .liveOffset(s.pan.binding)
                                .onHover { st, h, _ in st.hover = h }
                                .onDrag { st, d, _ in st.drags.append(d.local) }
                                .onDrawnLayoutTx { st, r, tx in
                                    st.drawn.append(r)
                                    tx.liveOnly()
                                }
                        )
                )
        }

        var t = 0.0
        _ = rt.frame(at: t)
        stepFrames(rt, count: 4, t: &t)
        #expect(rt.state.drawn.count == 1)

        // Color hover spring must NOT clear or re-fire onDrawnLayout
        rt.pointerMove(to: Vec2(50, 20), at: t)
        stepFrames(rt, count: 30, t: &t)
        #expect(rt.state.drawn.count == 1)

        // Ancestor layout spring gates onDrawnLayout until settled
        rt.update(at: t) { s, _ in s.wide = true }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        rt.state.pan.snap(Vec2(20, 0))
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        while (rt.isAnimating || rt.hasPendingActions || rt.hasPendingCommit) && t < 3.0 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        #expect(rt.state.drawn.count == 2)
        #expect(abs(rt.state.drawn[1][0] - rt.state.drawn[0][0] - 20) < 0.5)

        // Scaled drag on 0.5x node
        let r = findInfo(rt, key: "node")!.rect
        rt.state.drags.removeAll()
        rt.pointerDown(at: Vec2(r[0] + 2, r[1] + 4), at: t)
        t += 1.0 / 60.0
        rt.pointerMove(to: Vec2(r[0] + 8, r[1] + 8), at: t)
        rt.pointerUp(at: Vec2(r[0] + 8, r[1] + 8), at: t)
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(rt.state.drags.count >= 2)
        #expect(abs(rt.state.drags.first!.x - 4) < 0.1 && abs(rt.state.drags.first!.y - 8) < 0.1)
        #expect(abs(rt.state.drags.last!.x - 16) < 0.1 && abs(rt.state.drags.last!.y - 16) < 0.1)
    }

    @Test("drawn_layout_self_chase_and_static_scale_fall_quiet")
    func drawnLayoutSelfChaseStops() {
        struct S {
            var chaseScale = false
            var shift: Float = 0
            var scale: Float = 1.0
            var drawn: [[Float]] = []
        }
        func makeRt(scaleMode: Bool) -> Runtime<S> {
            Runtime(state: S(chaseScale: scaleMode), viewport: Vec2(400, 200), pixelScale: 2.0) { (s: S, _: inout Cx<S>) -> El<S> in
                col().wFull().hFull().itemsStart().child(
                    el().key("node").w(100).h(40)
                        .offset(s.shift, 0)
                        .scale(s.scale)
                        .onDrawnLayout { st, r in
                            st.drawn.append(r)
                            if st.chaseScale {
                                st.scale = st.scale > 1.0 ? 1.0 : 1.1
                            } else {
                                st.shift += 5
                            }
                        }
                )
            }
        }

        for scaleMode in [false, true] {
            let rt = makeRt(scaleMode: scaleMode)
            if scaleMode {
                rt.reducedMotion = true
            }
            var t = 0.0
            _ = rt.frame(at: t)
            var frames = 0
            while (rt.isAnimating || rt.hasPendingActions || rt.hasPendingCommit || frames < 12) && frames < 200 {
                t += 1.0 / 60.0
                _ = rt.frame(at: t)
                frames += 1
            }
            #expect(frames < 200)
            #expect(rt.state.drawn.count <= 8)
        }
    }

    @Test("drag_points_in_a_scrolled_list_are_from_where_the_row_is_drawn")
    func dragPointsInScrolledList() {
        struct S { var drags: [Vec2] = [] }
        let rt = Runtime(state: S(), viewport: Vec2(300, 300), pixelScale: 1.0) { (_: S, _: inout Cx<S>) -> El<S> in
            var inner: El<S> = col().wFull()
            for i in 0..<20 {
                inner = inner.child(
                    el().key("row\(i)").wFull().h(40).shrink(0)
                        .onDrag { s, d, _ in s.drags.append(d.local) }
                )
            }
            return col().wFull().hFull()
                .child(col().key("list").wFull().h(200).scroll(stickBottom: false).child(inner))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        rt.update(at: t) { _, tx in tx.scrollTo("list", offset: Vec2(0, 100), animated: false) }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        // Row 5 (laid out at y=200) is drawn at y=100
        rt.pointerDown(at: Vec2(10, 110), at: t)
        rt.pointerUp(at: Vec2(10, 110), at: t)
        _ = rt.frame(at: t)
        #expect(rt.state.drags.first == Vec2(10, 10))
    }

    // MARK: - crates/rune/tests/drawn_rect.rs parity

    @Test("a_drawn_rect_follows_a_scroll_and_a_glide_with_no_commit")
    func drawnRectIntoScrollAndGlideNoCommit() {
        struct S { var ring = Live(MotionRect.zero) }
        let rt = Runtime(state: S(), viewport: Vec2(400, 600), pixelScale: 2.0) { (s: S, _: inout Cx<S>) -> El<S> in
            var inner: El<S> = col().wFull()
            for i in 0..<30 {
                let row: El<S> = el().key("row\(i)").wFull().h(40).shrink(0).bg(.black)
                inner = inner.child(i == 3 ? row.drawnRectInto(s.ring) : row)
            }
            return col().wFull().hFull()
                .child(col().key("scroll").w(300).h(400).mt(50).scroll(stickBottom: false).child(inner))
                .child(el().key("ring").pin(top: 0, left: 0).liveRect(s.ring.binding).bg(.white))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(near4(rt.state.ring.get().xywh, [0, 170, 300, 40]))

        let commits = rt.viewCommitCount
        var last = findInfo(rt, key: "row3")!.rect
        var wheeled = 0
        for _ in 0..<30 {
            t += 1.0 / 120.0
            rt.wheel(WheelEvent(dx: 0, dy: -8), at: Vec2(150, 200), now: t)
            _ = rt.frame(at: t)
            let row = findInfo(rt, key: "row3")!.rect
            #expect(near4(rt.state.ring.get().xywh, row))
            #expect(near4(findInfo(rt, key: "ring")!.rect, last))
            if abs(row[1] - last[1]) > 0.01 { wheeled += 1 }
            last = row
        }
        #expect(wheeled > 20)
        #expect(findInfo(rt, key: "row3")!.rect[1] < 120)

        rt.updateIf(at: t) { _, tx in
            tx.scrollTo("scroll", offset: .zero, animated: true)
            return false
        }
        var glided = 0
        for _ in 0..<180 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            let row = findInfo(rt, key: "row3")!.rect
            #expect(near4(rt.state.ring.get().xywh, row))
            #expect(near4(findInfo(rt, key: "ring")!.rect, last))
            if abs(row[1] - last[1]) > 0.01 { glided += 1 }
            last = row
        }
        #expect(glided > 5)
        #expect(near4(rt.state.ring.get().xywh, [0, 170, 300, 40]))
        #expect(near4(findInfo(rt, key: "ring")!.rect, [0, 170, 300, 40]))
        #expect(rt.viewCommitCount == commits)
    }

    // MARK: - crates/rune/src/runtime/visible_tests.rs parity

    @Test("an_element_hears_when_the_page_scrolls_it_on_screen_and_off")
    func pageScrollOnVisible() {
        struct Seen { var log: [Bool] = [] }
        let rt = Runtime(state: Seen(), viewport: Vec2(400, 200), pixelScale: 2.0) { (_: Seen, _: inout Cx<Seen>) -> El<Seen> in
            col().wFull()
                .child(col().key("top").wFull().h(500).shrink(0))
                .child(
                    col().key("demo").wFull().h(100).shrink(0)
                        .onVisible { s, on, _ in s.log.append(on) }
                )
                .child(col().key("bottom").wFull().h(600).shrink(0))
        }
        rt.pageMode()
        _ = rt.frame(at: 0)
        _ = rt.frame(at: 0)
        #expect(rt.state.log.isEmpty)

        rt.setPageScroll(330)
        _ = rt.frame(at: 0)
        _ = rt.frame(at: 0)
        #expect(rt.state.log.isEmpty, "only 30 of 100pt visible")

        rt.setPageScroll(360)
        _ = rt.frame(at: 0)
        _ = rt.frame(at: 0)
        #expect(rt.state.log == [true], "60pt visible >= 50%")

        rt.setPageScroll(450)
        _ = rt.frame(at: 0)
        _ = rt.frame(at: 0)
        #expect(rt.state.log == [true], "still visible: no duplicate")

        rt.setPageScroll(800)
        _ = rt.frame(at: 0)
        _ = rt.frame(at: 0)
        #expect(rt.state.log == [true, false])
    }

    @Test("half_of_it_or_half_the_window_counts")
    func visibleThresholdMath() {
        let view: (Float, Float) = (400, 200)
        #expect(VisibleGeometry.onScreen([0, 150, 400, 100], view: view))
        #expect(!VisibleGeometry.onScreen([0, 151, 400, 100], view: view))
        #expect(VisibleGeometry.onScreen([0, -400, 400, 1000], view: view))
        #expect(!VisibleGeometry.onScreen([0, 200, 400, 100], view: view))
    }

    @Test("review_356_retype_zoom_screen_unrelated_drawn_linear_visible_and_scroll_echo")
    func review356ParityFixes() {
        // 1. Cx.retype preserves layoutCollector + onScreenLayout applies zoom + onVisible reopens feedback
        struct SubS {}
        struct MainS {
            var growBy: Float = 10
            var barW: Float = 50
            var screenRects: [[Float]] = []
            var visibleEvents = 0
        }
        let rt1 = Runtime<MainS>(state: MainS(), viewport: Vec2(400, 200), pixelScale: 1.0) { (s: MainS, cx: inout Cx<MainS>) -> El<MainS> in
            cx.zoom(1.5)
            let subCx: Cx<SubS> = cx.retype()
            let probeRect = subCx.layout("probe")
            let subEl: El<MainS> = el().key("sub-marker").size(probeRect?[2] ?? 0, 10)
            cx.absorb(subCx)
            return col().wFull().itemsStart()
                .child(el().key("probe").size(120, 20).shrink(0).onScreenLayout { st, r in st.screenRects.append(r) })
                .child(subEl.shrink(0))
                .child(el().key("bar").w(max(10, s.barW)).h(10).shrink(0).onLayout { st, r in st.barW = r[2] + st.growBy })
                .child(el().key("vis").w(100).h(100).shrink(0).onVisible { st, _, _ in st.visibleEvents += 1 })
                .child(el().w(10).h(300).shrink(0))
        }
        _ = rt1.setWindowOrigin(Vec2(10, 20))
        var t1 = 0.0
        _ = rt1.frame(at: t1)
        _ = rt1.frame(at: t1)
        #expect(abs((findInfo(rt1, key: "sub-marker")?.rect[2] ?? 0) - 120) < 0.01)
        #expect(near4(rt1.state.screenRects.last ?? [], [10, 20, 180, 30]))

        // Exhaust layoutFeedback with growBy loop, then trigger onVisible via page scroll -> reopens
        stepFrames(rt1, count: 20, t: &t1)
        let barWBeforeScroll = rt1.state.barW
        rt1.pageMode()
        rt1.setPageScroll(250)
        t1 += 0.01
        _ = rt1.frame(at: t1)
        _ = rt1.frame(at: t1)
        #expect(rt1.state.visibleEvents >= 2)
        #expect(rt1.state.barW > barWBeforeScroll)

        // 2. Unrelated static element onDrawnLayout still reports while another scroll container flings
        //    and after its own Tween.linear finishes
        struct DrawnS {
            var dy = Tween<Vec2>.linear(from: .zero, to: Vec2(0, 10), duration: 0.05)
            var x: Float = 0
            var drawnXs: [Float] = []
        }
        let rt2 = Runtime(state: DrawnS(), viewport: Vec2(400, 300), pixelScale: 1.0) { (s: DrawnS, _: inout Cx<DrawnS>) -> El<DrawnS> in
            var sc: El<DrawnS> = col().key("scroller").size(100, 100).scrollY()
            for i in 0..<20 { sc = sc.child(el().key("r\(i)").wFull().h(30).shrink(0)) }
            let box: El<DrawnS> = el().key("box").size(40, 40).offset(s.x, 0)
                .liveOffset(s.dy.binding)
                .onDrawnLayout { st, r in st.drawnXs.append(r[0]) }
            return col().wFull().hFull().itemsStart()
                .child(sc)
                .child(box)
        }
        var t2 = 0.0
        _ = rt2.frame(at: t2)
        _ = rt2.frame(at: t2)
        rt2.fling(vy: -400, at: Vec2(50, 50), now: t2)
        t2 += 0.1
        _ = rt2.frame(at: t2)
        _ = rt2.frame(at: t2)
        rt2.update { st, _ in st.x = 25 }
        t2 += 0.02
        _ = rt2.frame(at: t2)
        _ = rt2.frame(at: t2)
        #expect(abs((rt2.state.drawnXs.last ?? -1) - 25) < 0.01)

        // 3. Consecutive scroll-driven windowLayout commits keep feedback open beyond ECHOES=3
        struct ScrollEcoS { var ys: [Float] = [] }
        let rt3 = Runtime<ScrollEcoS>(state: ScrollEcoS(), viewport: Vec2(400, 300), pixelScale: 1.0) { (_: ScrollEcoS, cx: inout Cx<ScrollEcoS>) -> El<ScrollEcoS> in
            var sc: El<ScrollEcoS> = col().key("sc").size(200, 150).scrollY()
            for i in 0..<40 { sc = sc.child(el().key("row\(i)").wFull().h(30).shrink(0)) }
            var root: El<ScrollEcoS> = col().wFull().hFull().itemsStart().child(sc)
            if let r = cx.windowLayout("row10") {
                root = root.child(el().key("tag").absolute(x: 0, y: r[1]).size(10, 10))
            }
            return root
        }
        var t3 = 0.0
        _ = rt3.frame(at: t3)
        for _ in 0..<6 {
            t3 += 1.0 / 60.0
            rt3.wheel(WheelEvent(dx: 0, dy: -20), at: Vec2(100, 75), now: t3)
            _ = rt3.frame(at: t3)
        }
        #expect(abs(findInfo(rt3, key: "tag")!.target[1] - findInfo(rt3, key: "row10")!.rect[1]) < 0.01)
    }

    // MARK: - Missing Upstream Parity Tests (`layout_read.rs` & `layout_read_highlights.rs`)

    @Test("drift_below_the_threshold_adds_up_until_a_whole_rect_read_re_runs")
    func driftBelowThresholdAddsUp() {
        struct S {}
        let rt: Runtime<S> = Runtime(state: S(), viewport: Vec2(300, 400), pixelScale: 2.0) { (_: S, cx: inout Cx<S>) -> El<S> in
            var rows: El<S> = col().wFull()
            for i in 0..<40 {
                rows = rows.child(el().key("r\(i)").wFull().h(30).shrink(0))
            }
            var root: El<S> = col().wFull().hFull().itemsStart()
                .child(col().key("scroll").wFull().h(300).scroll(stickBottom: false).child(rows))
            if let r = cx.windowLayout("r10") {
                root = root.child(el().key("marker").absolute(x: r[0], y: r[1]).size(10, 10))
            }
            return root
        }
        var t = 0.0
        _ = rt.frame(at: t)
        for _ in 0..<100 {
            t += 1.0 / 120.0
            rt.wheel(WheelEvent(dx: 0, dy: -0.4), at: Vec2(100, 100), now: t)
            _ = rt.frame(at: t)
        }
        let rowY = findInfo(rt, key: "r10")!.rect[1]
        let markerY = findInfo(rt, key: "marker")!.target[1]
        #expect(rowY < 270.0)
        #expect(abs(markerY - rowY) <= 0.5)
    }

    @Test("a_field_that_appears_on_the_re_run_takes_the_focus_it_asks_for")
    func fieldAppearingOnRerunTakesFocus() {
        struct Editor {
            var editing = false
            var focusField = false
            var field = TextEdit()
        }
        let rt: Runtime<Editor> = Runtime(state: Editor(), viewport: Vec2(300, 200), pixelScale: 2.0) { (s: Editor, cx: inout Cx<Editor>) -> El<Editor> in
            var root: El<Editor> = col().wFull().hFull().p(10).child(el().key("node").size(120, 30))
            if s.editing, let r = cx.layout("node") {
                root = root.child(
                    textInput(key: "editor", \Editor.field)
                        .font(TextStyle(size: 14, weight: 400))
                        .focused(s.focusField)
                        .absolute(x: r[0], y: r[1])
                        .w(r[2])
                )
            }
            return root
        }
        var t = 0.0
        _ = rt.frame(at: t)
        rt.update(at: t) { st, _ in
            st.editing = true
            st.focusField = true
        }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let editor = findInfo(rt, key: "editor")
        #expect(editor != nil)
        #expect(editor!.target[0] == 10.0 && editor!.target[1] == 10.0)
        #expect(editor!.focused)
        _ = rt.keyDown(KeyEvent(key: .text("a")), at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(rt.state.field.text == "a")
    }

    @Test("a_memo_layout_read_inside_a_scrolled_viewport_commits_nothing_while_it_scrolls")
    func memoLayoutReadInScrolledViewportCommitsNothingWhileScrolling() {
        final class Counter: @unchecked Sendable { var count = 0 }
        struct Board {
            var tall = false
            let builds = Counter()
            let withBuilds = Counter()
        }
        let rt: Runtime<Board> = Runtime(state: Board(), viewport: Vec2(300, 400), pixelScale: 2.0) { (s: Board, cx: inout Cx<Board>) -> El<Board> in
            var rows: El<Board> = col().wFull()
            for i in 0..<40 {
                rows = rows.child(el().key("r\(i)").wFull().h(i == 10 && s.tall ? 50 : 30).shrink(0))
            }
            let memoLabel: El<Board> = memo("label", UInt64(0)) {
                s.builds.count += 1
                let r = Rune.layoutRect("r10")
                let txt = r.map { "[\($0[0]), \($0[1]), \($0[2]), \($0[3])]" } ?? "nil"
                return text(txt).key("label")
            }
            let memoWith: El<Board> = memo("cxWith", UInt64(0)) {
                s.withBuilds.count += 1
                let h = cx.layoutWith("r10") { Int($0[3].rounded()) } ?? -1
                return text("h=\(h)").key("cxWithLabel")
            }
            return col().wFull().hFull().itemsStart()
                .child(col().key("scroll").wFull().h(300).scroll(stickBottom: false).child(rows))
                .child(memoLabel)
                .child(memoWith)
        }
        var t = 0.0
        _ = rt.frame(at: t)
        stepFrames(rt, count: 10, t: &t)
        let labelText = { findInfo(rt, key: "label")?.text }
        let withText = { findInfo(rt, key: "cxWith")?.text }
        let r10Rect = { findInfo(rt, key: "r10")!.rect }
        #expect(labelText() == "[0.0, 300.0, 300.0, 30.0]")
        #expect(withText() == "h=30")
        let commits = rt.viewCommitCount
        let builds = rt.state.builds.count
        let withBuilds = rt.state.withBuilds.count

        // Programmatic scroll + wheel scroll should NOT commit or invalidate memo builds
        _ = rt.updateIf(at: t) { _, tx in
            tx.scrollToY("scroll", 200)
            return false
        }
        stepFrames(rt, count: 60, t: &t)
        #expect(abs(r10Rect()[1] - 100.0) < 0.5)
        for _ in 0..<60 {
            t += 1.0 / 120.0
            rt.wheel(WheelEvent(dx: 0, dy: -3.0), at: Vec2(100, 100), now: t)
            _ = rt.frame(at: t)
        }
        stepFrames(rt, count: 60, t: &t)
        #expect(r10Rect()[1] < 0.0)
        #expect(rt.viewCommitCount == commits)
        #expect(rt.state.builds.count == builds)
        #expect(rt.state.withBuilds.count == withBuilds)
        #expect(labelText() == "[0.0, 300.0, 300.0, 30.0]")
        #expect(withText() == "h=30")

        // Real size change rebuilds on the commit that made it
        rt.update(at: t) { st, _ in st.tall = true }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(labelText() == "[0.0, 300.0, 300.0, 50.0]")
        #expect(withText() == "h=50")
        #expect(rt.state.builds.count > builds)
        #expect(rt.state.withBuilds.count > withBuilds)
    }

    private func runScopedHighlightReadFollowsScrollsAndCommits(extraReads: Int) {
        final class Box: @unchecked Sendable {
            var seen: [Float]? = nil
            var seenRows: [[Float]?] = []
        }
        struct S {
            var hitRow: Int
            var extraReads: Int
            var box = Box()
        }
        let rt: Runtime<S> = Runtime(state: S(hitRow: 6, extraReads: extraReads), viewport: Vec2(300, 300), pixelScale: 1.0) { (s: S, cx: inout Cx<S>) -> El<S> in
            s.box.seen = cx.windowLayout("row\(s.hitRow)/mark")
            s.box.seenRows = (0..<s.extraReads).map { cx.windowLayout("row\($0)") }
            var rows: El<S> = col().wFull()
            for i in 0..<30 {
                let body: El<S> = text("row \(i) text with a mark in it")
                    .font(TextStyle(size: 14, weight: 400))
                    .lineHeight(20)
                    .textHighlight(TextHighlight(18..<22, bg: .white).key("mark"))
                rows = rows.child(col().key("row\(i)").wFull().h(40).shrink(0).py(10).child(body))
            }
            return col().wFull().hFull().child(
                col().key("list").wFull().h(200).scroll(stickBottom: false).child(rows)
            )
        }
        func settle(_ t: inout Double) {
            for _ in 0..<600 {
                t += 1.0 / 60.0
                _ = rt.frame(at: t)
                if !rt.isAnimating && !rt.hasPendingActions && !rt.hasPendingCommit { return }
            }
            Issue.record("never settled")
        }
        func markOf(row: Int) -> [Float] {
            let scope = "@row\(row)/"
            let e = rt.elements().first { $0.key == "mark" && $0.path.contains(scope) }
            #expect(e != nil, "mark in row \(row)")
            return e?.rect ?? [0, 0, 0, 0]
        }
        func check(_ when: String) {
            let seen = rt.state.box.seen
            #expect(seen != nil, "\(when): read saw nothing")
            if let seen {
                let mark = markOf(row: rt.state.hitRow)
                #expect(near4(seen, mark, tol: 0.75), "\(when): read \(seen) vs mark \(mark)")
            }
            for (i, sr) in rt.state.box.seenRows.enumerated() {
                #expect(sr != nil, "\(when): row\(i) saw nothing")
                if let sr {
                    let row = findInfo(rt, key: "row\(i)")!.rect
                    #expect(near4(sr, row, tol: 0.75), "\(when): row\(i) read \(sr) vs row \(row)")
                }
            }
        }

        var t = 0.0
        _ = rt.frame(at: t)
        settle(&t)
        check("first layout")

        for dy: Float in [-120.0, -160.0, 200.0] {
            let before = markOf(row: rt.state.hitRow)[1]
            t += 1.0 / 60.0
            rt.wheel(WheelEvent(dx: 0, dy: dy), at: Vec2(100, 100), now: t)
            settle(&t)
            #expect(markOf(row: rt.state.hitRow)[1] != before, "the wheel scrolled")
            check("wheeled \(dy)")
        }

        rt.update(at: t) { st, _ in st.hitRow = 2 }
        settle(&t)
        check("after commit")
        t += 1.0 / 60.0
        rt.wheel(WheelEvent(dx: 0, dy: 400.0), at: Vec2(100, 100), now: t)
        settle(&t)
        check("wheeled back after commit")
    }

    @Test("a_scoped_highlight_read_follows_scrolls_and_commits")
    func scopedHighlightReadFollowsScrollsAndCommits() {
        runScopedHighlightReadFollowsScrollsAndCommits(extraReads: 0)
    }

    @Test("many_reads_follow_scrolls_and_commits")
    func manyReadsFollowScrollsAndCommits() {
        runScopedHighlightReadFollowsScrollsAndCommits(extraReads: 12)
    }

    @Test("regression #695: scrollAnchor preserved after fast wheel and fling without commit")
    func scrollAnchorPreservedAfterFastWheelAndFlingWithoutCommit() {
        struct AnchorState {
            var extraTop: Float = 0
        }
        let rt = Runtime<AnchorState>(
            state: AnchorState(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col().key("scroll").size(200, 100).scrollY().scrollAnchor(true)
                .child(el().key("head").size(200, 40 + s.extraTop))
                .child(el().key("row-a").size(200, 60))
                .child(el().key("row-b").size(200, 200))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        let commitsBefore = rt.viewCommitCount

        // Wheel + fling past `head` (40pt) on a plain scroll container take the !scrollRequiresCommit fast path.
        t += 1.0 / 120.0
        rt.wheel(WheelEvent(dx: 0, dy: -55), at: Vec2(100, 50), now: t)
        _ = rt.frame(at: t)
        t += 1.0 / 120.0
        rt.fling(vx: 0, vy: -180, at: Vec2(100, 50), now: t)
        var coastFrames = 0
        while rt.scrollStore.isAnimating && coastFrames < 720 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            coastFrames += 1
        }
        #expect(!rt.scrollStore.isAnimating, "fling should finish coasting")
        #expect(rt.viewCommitCount == commitsBefore, "plain scroll fast path does not commit")
        let rowABefore = findInfo(rt, key: "row-a")!.rect[1]
        let offsetBefore = rt.scrollOffset(forKey: "scroll").y
        #expect(offsetBefore > 45.0)

        // Prepending content above row-a on the next commit must engage scrollAnchor compensation.
        t += 1.0 / 120.0
        rt.update(at: t) { s, tx in
            tx.instant()
            s.extraTop = 60
        }
        _ = rt.frame(at: t)
        let rowAAfter = findInfo(rt, key: "row-a")!.rect[1]
        let offsetAfter = rt.scrollOffset(forKey: "scroll").y
        #expect(abs(rowAAfter - rowABefore) < 0.5)
        #expect(abs((offsetAfter - offsetBefore) - 60.0) < 0.5)
    }

    @Test("virtual_row_reads_where_it_draws_with_rows_culled_above")
    func virtualRowReadsWhereItDrawsWithRowsCulledAbove() {
        let markColor = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        final class ReadBox: @unchecked Sendable {
            var r22: [Float]? = nil
        }
        let reads = ReadBox()
        let rt: Runtime<Int> = Runtime<Int>(
            state: 0,
            viewport: Vec2(240, 120),
            pixelScale: 1.0,
            systemDark: true
        ) { _, cx in
            reads.r22 = cx.windowLayout("row-22")
            let list: El<Int> = col().key("vlist").size(240, 120).scrollY()
                .virtualRows(40, 30, key: { (_: Int, i: Int) in "row-\(i)" }) { (_: Int, i: Int) in
                    var row: El<Int> = el().key("row-\(i)").size(240, 30)
                    if i == 22 { row = row.bg(markColor) }
                    return row
                }
            return col().size(240, 120).child(list)
        }
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 120.0
        rt.update(at: t) { _, tx in
            tx.scrollToInstant("vlist", x: 0, y: 600)
        }
        _ = rt.frame(at: t)
        stepFrames(rt, count: 4, t: &t)

        let layoutR22 = reads.r22
        let infoR22 = findInfo(rt, key: "row-22")
        #expect(layoutR22 != nil && infoR22 != nil)
        let scene = rt.frame(at: t)
        let rectKind = Float(PrimitiveKind.roundedRect.rawValue)
        let drawnR22 = scene.primitives.first { prim in
            prim.params.y == rectKind
                && prim.fill.x > 0.9 && prim.fill.y < 0.05 && prim.fill.z < 0.05
        }
        #expect(drawnR22 != nil)
        if let lr = layoutR22, let dr = drawnR22 {
            #expect(abs(lr[0] - dr.rect.x) < 0.5)
            #expect(abs(lr[1] - dr.rect.y) < 0.5)
            #expect(abs(lr[2] - dr.rect.z) < 0.5)
            #expect(abs(lr[3] - dr.rect.w) < 0.5)
        }
        // Row 0 is above overscan window [600 - 240, ...] when scrolled to y = 600
        #expect(findInfo(rt, key: "row-0") == nil)
    }

    @Test("headless_screen_layout: screenRect follows window origin on VirtualDesktop")
    func screenRectsFollowWindowOnVirtualDesktop() throws {
        let json = """
        {
          "displays": [
            { "id": 10, "frame": [0, 0, 1280, 800], "scale": 2.0 },
            { "id": 20, "frame": [1280, 0, 1440, 900], "scale": 1.0, "primary": true }
          ],
          "pointer": [1320, 40]
        }
        """
        let desktop = try VirtualDesktop.fromScript(jsonData: Data(json.utf8), scale: 1.0)
        struct ScreenState {
            var local: [Float]? = nil
            var screen: [Float]? = nil
        }
        let app = App<ScreenState>(
            title: "screen-rect",
            size: Vec2(300, 200),
            state: ScreenState(),
            view: { _, _ in
                col().size(300, 200).child(
                    el().key("box").absolute(x: 24, y: 18).size(40, 30)
                        .onLayout { st, r in st.local = r }
                        .onScreenLayout { st, r in st.screen = r }
                )
            }
        )
        let win = DesktopWindow<ScreenState>(key: "w", app: app, scale: 1.0)
        win.start(desktop: desktop)
        _ = win.runtime.frame(at: 0.0)
        _ = win.runtime.frame(at: 0.02)

        let origin0 = win.frame
        if let loc = win.runtime.state.local, let scr = win.runtime.state.screen {
            #expect(abs(scr[0] - (Float(origin0[0]) + loc[0])) < 0.5)
            #expect(abs(scr[1] - (Float(origin0[1]) + loc[1])) < 0.5)
        } else {
            Issue.record("Expected local and screen rects after initial frame")
        }

        // Move window onto display 0 (frame [0, 0, 1280, 800]) via AppHandle.place and verify screenLayout updates.
        app.sharedHandle.place(.index(0), placement: .rect(MotionRect(left: 120, top: 80, right: 420, bottom: 280)))
        _ = win.drain(desktop: desktop, t: 0.1)
        _ = win.runtime.frame(at: 0.12)
        _ = win.runtime.frame(at: 0.14)
        #expect(abs(win.frame[0] - 120.0) < 0.5 && abs(win.frame[1] - 80.0) < 0.5)
        if let loc = win.runtime.state.local, let scr = win.runtime.state.screen {
            #expect(abs(loc[0] - 24.0) < 0.5 && abs(loc[1] - 18.0) < 0.5)
            #expect(abs(scr[0] - 144.0) < 0.5 && abs(scr[1] - 98.0) < 0.5)
        } else {
            Issue.record("Expected updated screenRect after VirtualDesktop place")
        }
    }

    @Test("onScrollOffset and chainScrollOffset report ScrollPos")
    func onScrollOffsetAndChainScrollOffsetReportScrollPos() {
        final class ScrollLog: @unchecked Sendable {
            var direct: [ScrollPos] = []
            var chained: [ScrollPos] = []
        }
        let log = ScrollLog()
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().key("scroll").size(200, 100).scrollY()
                .onScrollOffset { log.direct.append($0) }
                .chainScrollOffset { log.chained.append($0) }
                .child(el().key("tall").size(200, 320))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 120.0
        rt.update(at: t) { _, tx in
            tx.scrollToInstant("scroll", x: 0, y: 85)
        }
        _ = rt.frame(at: t)
        stepFrames(rt, count: 4, t: &t)

        #expect(!log.direct.isEmpty && !log.chained.isEmpty)
        if let lastDirect = log.direct.last, let lastChained = log.chained.last {
            #expect(lastDirect == lastChained)
            #expect(abs(lastDirect.offset.y - 85.0) < 0.5)
            #expect(abs(lastDirect.max.y - 220.0) < 0.5)
            #expect(abs(lastDirect.viewport.y - 100.0) < 0.5)
            #expect(abs(lastDirect.drawn.y - 100.0) < 0.5)
        }
    }

    @Test("layout_diagnostics: collapsed scroll warns once and keeps layout")
    func collapsedScrollWarnsOnceAndKeepsLayout() {
        LayoutDiagnostics.resetWarnedSitesForTesting()
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().size(200, 0).child(
                col().key("collapsed-scroll").grow(1).basis(0).scrollY()
                    .child(el().size(200, 120))
            )
        }
        _ = rt.frame(at: 0.0)
        rt.invalidate(at: 0.1)
        _ = rt.frame(at: 0.1)

        #if DEBUG
        #expect(LayoutDiagnostics.hasWarned(matching: "collapsed-scroll"))
        #else
        #expect(!LayoutDiagnostics.hasWarned(matching: "collapsed-scroll"))
        #endif
        let collapsed = findInfo(rt, key: "collapsed-scroll")
        #expect(collapsed != nil)
        #expect(abs((collapsed?.rect[3] ?? -1) - 0.0) < 0.5)
    }
}
