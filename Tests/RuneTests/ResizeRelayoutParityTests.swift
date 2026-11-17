import Testing
import Foundation
@testable import Rune
import RuneMotion

@Suite("Resize-Only Relayout Parity (relayout.rs + relayout/live.rs)")
struct ResizeRelayoutParityTests {
    // MARK: - Helpers

    private func layoutSignature<S>(_ rt: Runtime<S>) -> [(String, [Float], Int)] {
        rt.flatNodes.map { node in
            let r: [Float] = [
                node.targetRect.left,
                node.targetRect.top,
                node.targetRect.width,
                node.targetRect.height,
            ]
            let lines: Int = {
                guard node.el.plainText != nil || node.el.richSpans != nil else { return 0 }
                return rt.textSystem.shape(
                    text: node.el.plainText ?? "",
                    spans: node.el.richSpans,
                    pills: node.el.pillChips,
                    style: node.el.textStyle,
                    maxWidth: node.targetRect.width + 0.5,
                    pixelScale: rt.pixelScale,
                    emitGlyphs: false
                ).lineCount
            }()
            return (node.path, r, lines)
        }
    }

    private func assertLayoutsMatch<S>(_ a: Runtime<S>, _ b: Runtime<S>, label: String) {
        let la = layoutSignature(a)
        let lb = layoutSignature(b)
        #expect(la.count == lb.count, "\(label): node count mismatch \(la.count) vs \(lb.count)")
        for (pa, pb) in zip(la, lb) {
            #expect(pa.0 == pb.0, "\(label): path mismatch \(pa.0) vs \(pb.0)")
            #expect(pa.2 == pb.2, "\(label) @ \(pa.0): line count mismatch \(pa.2) vs \(pb.2)")
            for i in 0..<4 {
                #expect(abs(pa.1[i] - pb.1[i]) < 0.05, "\(label) @ \(pa.0)[\(i)]: \(pa.1[i]) vs \(pb.1[i])")
            }
        }
    }

    private func resize<S>(_ rt: Runtime<S>, width: Float, height: Float = 600.0, scale: Float = 2.0, t: inout Double) -> Int {
        let before = rt.viewCallCount
        rt.setViewport(Vec2(width, height), pixelScale: scale)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        return rt.viewCallCount - before
    }

    private func fullResize<S>(_ rt: Runtime<S>, width: Float, height: Float = 600.0, scale: Float = 2.0, t: inout Double) -> Int {
        let before = rt.viewCallCount
        rt.invalidate(at: t)
        rt.setViewport(Vec2(width, height), pixelScale: scale)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        return rt.viewCallCount - before
    }

    private func shown<S>(_ rt: Runtime<S>) -> [(String, [Int])] {
        rt.elements()
            .filter {
                $0.visible[2] > 0.0
                    && $0.visible[3] > 0.0
                    && !$0.path.contains("-spacer")
                    && !(rt.virtualLists[$0.path] != nil && $0.fill.a == 0.0)
            }
            .sorted { $0.path < $1.path }
            .map { e in (e.path, e.rect.map { Int(($0 * 100.0).rounded()) }) }
    }

    private func assertShownMatch(_ a: [(String, [Int])], _ b: [(String, [Int])], _ label: String) {
        #expect(a.count == b.count, "\(label): shown count \(a.count) vs \(b.count)")
        for (pa, pb) in zip(a, b) {
            #expect(pa.0 == pb.0, "\(label): shown path \(pa.0) vs \(pb.0)")
            #expect(pa.1 == pb.1, "\(label) @ \(pa.0): shown rect \(pa.1) vs \(pb.1)")
        }
    }

    private func makeParagraphRuntime(_ n: Int) -> (Runtime<Int>, () -> Int) {
        final class Counter: @unchecked Sendable { var memoBuilds = 0 }
        let counter = Counter()
        let para = "Paragraph text long enough to wrap over several lines as the window narrows."
        let rt = Runtime<Int>(
            state: n,
            viewport: Vec2(700.0, 600.0),
            pixelScale: 2.0,
            systemDark: true
        ) { count, _ in
            var root: El<Int> = col().wFull()
            for i in 0..<(3 + count) {
                root = root.child(
                    text("\(i). \(para)").wFull().wrap(.wrap).key("t\(i)")
                )
            }
            let tail: El<Int> = memo("tail", UInt64(0)) {
                counter.memoBuilds += 1
                return text("tail").key("tail")
            }
            return root.child(tail)
        }
        return (rt, { counter.memoBuilds })
    }

    private func makeScrolledTranscript(sticky: Bool) -> Runtime<Bool> {
        let rt = Runtime<Bool>(
            state: sticky,
            viewport: Vec2(700.0, 600.0),
            pixelScale: 2.0,
            systemDark: true
        ) { isSticky, _ in
            let rows: El<Bool> = col().key("rows").wFull().px(8.0).growth(.default)
                .virtualRows(300, 40.0, key: { (_: Bool, i: Int) in "m\(i)" }) { (_: Bool, i: Int) in
                    let prose = String(repeating: "Words that wrap over more lines as the window narrows. ", count: 1 + (i % 4))
                    return text("\(i). \(prose)").wFull().wrap(.wrap)
                }
            return col().wFull().hFull().child(
                col().key("scroll").wFull().grow(1.0).minH(0.0).scroll(stickBottom: isSticky).child(rows)
            )
        }
        var t = 0.0
        _ = rt.frame(at: t)
        for _ in 0..<8 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        if !sticky {
            t += 1.0 / 120.0
            rt.wheel(WheelEvent(dx: 0, dy: -3000.0), at: Vec2(300.0, 300.0), now: t)
            for _ in 0..<30 {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
            }
        }
        return rt
    }

    // MARK: - Tests

    @Test("a_resize_alone_lays_the_tree_out_again_without_the_view_as_a_full_commit_would")
    func resizeAloneLaysTreeOutAgainWithoutViewAsFullCommitWould() {
        let (rt, _) = makeParagraphRuntime(0)
        let (full, _) = makeParagraphRuntime(0)
        var t = 0.0
        var tf = 0.0
        _ = rt.frame(at: t)
        _ = full.frame(at: tf)
        for w: Float in [600.0, 420.0, 300.0, 520.0] {
            #expect(resize(rt, width: w, t: &t) == 0, "at \(w)")
            #expect(fullResize(full, width: w, t: &tf) == 1)
            assertLayoutsMatch(rt, full, label: "at \(w)")
            if w == 300.0 {
                let t0Lines: Int = {
                    guard let node = rt.flatNodes.first(where: { $0.key == "t0" }) else { return 0 }
                    return rt.textSystem.shape(
                        text: node.el.plainText ?? "",
                        spans: node.el.richSpans,
                        pills: node.el.pillChips,
                        style: node.el.textStyle,
                        maxWidth: node.targetRect.width + 0.5,
                        pixelScale: rt.pixelScale,
                        emitGlyphs: false
                    ).lineCount
                }()
                #expect(t0Lines > 1, "the narrow window wrapped the text")
            }
        }
    }

    @Test("a_resize_reuses_the_last_commits_node_buffer")
    func resizeReusesLastCommitsNodeBuffer() {
        let (rt, _) = makeParagraphRuntime(0)
        var t = 0.0
        _ = rt.frame(at: t)
        // The first commit let go of an empty buffer.
        rt.invalidate(at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        for w in [Float(600.0), Float(420.0), Float(300.0)] {
            let spare = rt.spareFlatNodes.withUnsafeBufferPointer { $0.baseAddress }
            let last = rt.flatNodes.withUnsafeBufferPointer { $0.baseAddress }
            #expect(rt.spareFlatNodes.capacity >= rt.flatNodes.count)
            #expect(resize(rt, width: w, t: &t) == 0, "at \(w)")
            #expect(rt.flatNodes.withUnsafeBufferPointer { $0.baseAddress } == spare, "at \(w)")
            #expect(rt.spareFlatNodes.withUnsafeBufferPointer { $0.baseAddress } == last, "at \(w)")
        }
    }

    @Test("a_resize_keeps_the_memos_the_view_built")
    func resizeKeepsMemosTheViewBuilt() {
        let (rt, memoBuilds) = makeParagraphRuntime(0)
        var t = 0.0
        _ = rt.frame(at: t)
        #expect(resize(rt, width: 600.0, t: &t) == 0)
        let memos = memoBuilds()
        rt.invalidate(at: t)
        #expect(resize(rt, width: 500.0, t: &t) == 1)
        #expect(memoBuilds() == memos, "the memo built before the resize is still cached")
    }

    @Test("a_resize_with_a_state_change_runs_the_view")
    func resizeWithStateChangeRunsView() {
        let (rt, _) = makeParagraphRuntime(0)
        var t = 0.0
        _ = rt.frame(at: t)
        rt.update(at: t) { n, _ in n = 1 }
        #expect(resize(rt, width: 600.0, t: &t) == 1)
        #expect(rt.element(byKey: "t3")?.text?.hasPrefix("3.") == true)
    }

    @Test("a_new_scale_runs_the_view")
    func newScaleRunsView() {
        let (rt, _) = makeParagraphRuntime(0)
        var t = 0.0
        _ = rt.frame(at: t)
        #expect(resize(rt, width: 700.0, scale: 1.0, t: &t) == 1)
        #expect(resize(rt, width: 600.0, scale: 1.0, t: &t) == 0, "and the next resize at that scale doesn't")
    }

    @Test("a_new_blend_mode_runs_the_view")
    func newBlendModeRunsView() {
        let (rt, _) = makeParagraphRuntime(0)
        var t = 0.0
        _ = rt.frame(at: t)
        rt.setSrgbBlend(!rt.srgbBlend, at: t)
        #expect(resize(rt, width: 600.0, t: &t) == 1)
        #expect(resize(rt, width: 500.0, t: &t) == 0, "and the next resize in that mode doesn't")
    }

    @Test("a_resize_during_an_exit_runs_the_view_and_the_exit_carries_on")
    func resizeDuringExitRunsViewAndExitCarriesOn() {
        let rt = Runtime<Int>(
            state: 1,
            viewport: Vec2(700.0, 600.0),
            pixelScale: 2.0,
            systemDark: true
        ) { count, _ in
            var root: El<Int> = col().wFull()
            for i in 0..<(3 + count) {
                root = root.child(
                    text("\(i). Exiting row").wFull().key("t\(i)").transition(.opacity)
                )
            }
            return root
        }
        var t = 0.0
        _ = rt.frame(at: t)
        rt.update(at: t) { n, _ in n = 0 }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(rt.element(byKey: "t3")?.exiting == true)
        #expect(resize(rt, width: 600.0, t: &t) == 1)
        #expect(rt.element(byKey: "t3")?.exiting == true)
    }

    @Test("a_resize_lays_a_virtual_lists_mounted_rows_out_again_without_the_view")
    func resizeLaysVirtualListsMountedRowsOutAgainWithoutView() {
        for sticky in [false, true] {
            let rt = makeScrolledTranscript(sticky: sticky)
            let full = makeScrolledTranscript(sticky: sticky)
            #expect(shown(rt).count == shown(full).count)
            let rangeBefore = rt.virtualLists["/0/@scroll/@rows"]?.lastMountedRange
            var t = 1.0
            var tf = 1.0
            var fast = 0
            for k in 1...40 {
                let w = 700.0 - 5.0 * Float(k)
                if resize(rt, width: w, t: &t) == 0 { fast += 1 }
                #expect(fullResize(full, width: w, t: &tf) == 1)
                let sa = shown(rt)
                let sb = shown(full)
                assertShownMatch(sa, sb, "at \(w), sticky \(sticky)")
            }
            #expect(fast >= 30, "\(fast) of 40 steps skipped the view (sticky \(sticky))")
            if let r0 = rangeBefore, let r1 = rt.virtualLists["/0/@scroll/@rows"]?.lastMountedRange {
                #expect(r1.lowerBound >= max(0, r0.lowerBound - 4))
            }
        }
    }

    @Test("a_narrowing_window_lets_go_of_rows_the_overscan_no_longer_holds")
    func narrowingWindowLetsGoOfRowsOverscanNoLongerHolds() {
        let rt = makeScrolledTranscript(sticky: false)
        var t = 1.0
        var ran = 0
        for k in 1...80 {
            let w = 700.0 - 5.0 * Float(k)
            ran += resize(rt, width: w, t: &t)
        }
        #expect(ran >= 1 && ran < 25, "the view ran \(ran) times in 80 steps")
    }

    @Test("a_resize_that_moves_a_virtual_window_runs_the_view")
    func resizeThatMovesVirtualWindowRunsView() {
        let rt = makeScrolledTranscript(sticky: false)
        let full = makeScrolledTranscript(sticky: false)
        let before = rt.virtualLists["/0/@scroll/@rows"]?.lastMountedRange
        var t = 1.0
        var tf = 1.0
        #expect(resize(rt, width: 700.0, height: 1800.0, t: &t) == 1)
        #expect(fullResize(full, width: 700.0, height: 1800.0, t: &tf) == 1)
        #expect(rt.virtualLists["/0/@scroll/@rows"]?.lastMountedRange != before, "the window moved")
        assertShownMatch(shown(rt), shown(full), "virtual window moved")
    }

    @Test("text_leaving_at_a_breakpoint_keeps_its_layout")
    func textLeavingAtBreakpointKeepsItsLayout() {
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(700.0, 600.0),
            pixelScale: 2.0,
            systemDark: true
        ) { _, cx in
            let narrow = cx.layoutWith("root") { $0[2] < 500.0 } ?? false
            var root: El<Int> = col().key("root").wFull().hFull()
            if !narrow {
                root = root.child(
                    text("Only while wide, long enough to wrap when it has to").key("wide").wFull().wrap(.wrap).transition(.opacity)
                )
            }
            return root.child(text("always").key("always"))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(rt.element(byKey: "wide") != nil)
        _ = resize(rt, width: 400.0, t: &t)
        #expect(rt.element(byKey: "wide")?.exiting == true)
        #expect(rt.element(byKey: "wide")?.text?.isEmpty == false)
    }

    @Test("a_layout_read_the_resize_moves_runs_the_view")
    func layoutReadResizeMovesRunsView() {
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(700.0, 600.0),
            pixelScale: 2.0,
            systemDark: true
        ) { _, cx in
            let w = cx.layoutSize("bar").map { Int($0[0].rounded()) } ?? -1
            return col().wFull()
                .child(el().key("bar").wFull().h(10.0))
                .child(text("\(w)").key("label"))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(rt.element(byKey: "label")?.text == "700")
        #expect(resize(rt, width: 600.0, t: &t) >= 1)
        #expect(rt.element(byKey: "label")?.text == "600")
    }

    @Test("a_layout_read_the_resize_leaves_alone_keeps_the_view")
    func layoutReadResizeLeavesAloneKeepsView() {
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(700.0, 600.0),
            pixelScale: 2.0,
            systemDark: true
        ) { _, cx in
            let w = cx.layoutSize("side").map { Int($0[0].rounded()) } ?? -1
            return row().wFull()
                .child(el().key("side").w(120.0).h(10.0))
                .child(text("\(w)").key("label").wFull().wrap(.wrap))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(rt.element(byKey: "label")?.text == "120")
        #expect(resize(rt, width: 600.0, t: &t) == 0)
        #expect(rt.element(byKey: "label")?.text == "120")
    }

    @Test("a_resize_in_the_frame_a_scroll_moves_a_layout_read_runs_the_view")
    func resizeInFrameScrollMovesLayoutReadRunsView() {
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(700.0, 600.0),
            pixelScale: 2.0,
            systemDark: true
        ) { _, cx in
            let y = cx.windowLayout("r5").map { Int($0[1].rounded()) } ?? -1
            var rows: El<Int> = col().wFull()
            for k in 0..<50 {
                rows = rows.child(el().key("r\(k)").size(100.0, 20.0))
            }
            return col().wFull()
                .child(col().key("scroll").wFull().h(200.0).scroll(stickBottom: false).child(rows))
                .child(text("\(y)").key("label"))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(rt.element(byKey: "label")?.text == "100")
        rt.wheel(WheelEvent(dx: 0, dy: -50.0), at: Vec2(100.0, 100.0), now: t)
        #expect(resize(rt, width: 600.0, t: &t) >= 1)
        #expect(rt.element(byKey: "label")?.text == "50")
    }

    @Test("crossing_a_breakpoint_runs_the_view_and_resizing_within_one_does_not")
    func crossingBreakpointRunsViewAndResizingWithinOneDoesNot() {
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(700.0, 600.0),
            pixelScale: 2.0,
            systemDark: true
        ) { _, cx in
            let narrow = cx.layoutWith("root") { $0[2] < 500.0 } ?? false
            let a: El<Int> = el().key("a").h(50.0).grow(1.0)
            let b: El<Int> = el().key("b").h(50.0).grow(1.0)
            let body: El<Int> = narrow ? col().wFull().child(a).child(b) : row().wFull().child(a).child(b)
            return col().key("root").wFull().hFull().child(body)
        }
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        func stacked() -> Bool {
            let ay = rt.element(byKey: "a")!.target[1]
            let by = rt.element(byKey: "b")!.target[1]
            return by > ay
        }
        #expect(!stacked())
        #expect(resize(rt, width: 600.0, t: &t) == 0, "still wide")
        #expect(resize(rt, width: 400.0, t: &t) >= 1, "crossed the breakpoint")
        #expect(stacked())
        #expect(resize(rt, width: 450.0, t: &t) == 0, "still narrow")
        #expect(stacked())
        #expect(resize(rt, width: 650.0, t: &t) >= 1)
        #expect(!stacked())
    }

    @Test("a_caret_read_the_resize_moves_runs_the_view")
    func caretReadResizeMovesRunsView() {
        struct CaretState {
            var edit = TextEdit("hello")
        }
        let rt = Runtime<CaretState>(
            state: CaretState(),
            viewport: Vec2(700.0, 600.0),
            pixelScale: 2.0,
            systemDark: true
        ) { _, cx in
            let x = cx.caret("field").map { Int($0[0].rounded()) } ?? -1
            return col().wFull().itemsCenter()
                .child(textInput(key: "field", \CaretState.edit).font(TextStyle(size: 14.0, weight: 400.0)).size(200.0, 40.0).focused(true))
                .child(text("\(x)").key("label"))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let before = rt.element(byKey: "label")?.text ?? ""
        #expect(before != "-1")
        #expect(resize(rt, width: 500.0, t: &t) >= 1)
        let after = rt.element(byKey: "label")?.text ?? ""
        #expect(after != before)
        if let c = rt.focusedCaretRect() {
            #expect(after == "\(Int(c.left.rounded()))")
        }
    }

    @Test("a_resize_refits_aspect_fit_elements_as_a_full_commit_would")
    func resizeRefitsAspectFitElementsAsFullCommitWould() {
        func build(_: Int, _: inout Cx<Int>) -> El<Int> {
            col().wFull().hFull().itemsCenter()
                .child(el().key("pic").aspectFit(2.0))
                .child(text("caption").key("cap"))
        }
        let rt = Runtime<Int>(state: 0, viewport: Vec2(700.0, 600.0), pixelScale: 2.0, systemDark: true, view: build)
        let full = Runtime<Int>(state: 0, viewport: Vec2(700.0, 600.0), pixelScale: 2.0, systemDark: true, view: build)
        var t = 0.0
        var tf = 0.0
        _ = rt.frame(at: t)
        _ = full.frame(at: tf)
        for w: Float in [600.0, 900.0, 300.0] {
            _ = resize(rt, width: w, t: &t)
            _ = fullResize(full, width: w, t: &tf)
            assertLayoutsMatch(rt, full, label: "at \(w)")
        }
    }

    @Test("a_resize_moves_nodes_keeps_inputs_and_restores_on_virtual_window_fallback")
    func resizeMovesNodesKeepsInputsAndRestoresOnVirtualWindowFallback() {
        struct ComposerApp {
            var edit = TextEdit("draft")
        }
        func build(_: ComposerApp, _: inout Cx<ComposerApp>) -> El<ComposerApp> {
            var side: El<ComposerApp> = col().key("side").w(180.0).hFull()
            for i in 0..<20 {
                side = side.child(row().key("s\(i)").wFull().h(24.0).child(text("Item \(i)")))
            }
            let list: El<ComposerApp> = col().key("rows").wFull().growth(.default)
                .virtualRows(200, 32.0, key: { (_: ComposerApp, i: Int) in "r\(i)" }) { (_: ComposerApp, i: Int) in
                    let prose = String(repeating: "wrapping row prose ", count: 1 + (i % 3))
                    return text("\(i): \(prose)").wFull().wrap(.wrap)
                }
            return row().wFull().hFull()
                .child(side)
                .child(
                    col().key("main").grow(1.0).hFull()
                        .child(textInput(key: "composer", \ComposerApp.edit).font(TextStyle(size: 14.0, weight: 400.0)).wFull().h(36.0).focused(true))
                        .child(col().key("scroll").wFull().grow(1.0).minH(0.0).scroll(stickBottom: false).child(list))
                )
        }

        let rt = Runtime<ComposerApp>(state: ComposerApp(), viewport: Vec2(800.0, 600.0), pixelScale: 2.0, systemDark: true, view: build)
        let full = Runtime<ComposerApp>(state: ComposerApp(), viewport: Vec2(800.0, 600.0), pixelScale: 2.0, systemDark: true, view: build)
        var t = 0.0
        _ = rt.frame(at: t)
        _ = full.frame(at: t)
        t += 1.0 / 120.0
        rt.wheel(WheelEvent(dx: 0, dy: -600.0), at: Vec2(400.0, 300.0), now: t)
        full.wheel(WheelEvent(dx: 0, dy: -600.0), at: Vec2(400.0, 300.0), now: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        _ = full.frame(at: t)

        var t2 = t
        for (w, h) in [(Float(760.0), Float(600.0)), (700.0, 600.0), (420.0, 1200.0), (780.0, 600.0)] {
            _ = resize(rt, width: w, height: h, t: &t)
            _ = fullResize(full, width: w, height: h, t: &t2)
            assertShownMatch(shown(rt), shown(full), "at \(w)x\(h)")
            #expect(rt.focusedPath == "/0/@main/@composer")
        }
    }

    @Test("a_commit_picks_its_kind_once_from_what_changed")
    func commitPicksItsKindOnceFromWhatChanged() {
        let rt = makeScrolledTranscript(sticky: false)
        let tx = Tx()
        var settle = Tx()
        settle.settleAnimated()
        rt.stateUnchangedSinceBuild = true
        rt.pendingResizeRelayout = false
        #expect(rt.nextCommitKind(tx: tx) == .remount)
        rt.pendingResizeRelayout = true
        #expect(rt.nextCommitKind(tx: tx) == .relayout, "a resize never remounts")
        for relayout in [true, false] {
            rt.pendingResizeRelayout = relayout
            #expect(rt.nextCommitKind(tx: settle) == .rebuild)
            rt.resizeReadMovedFlag = true
            #expect(rt.nextCommitKind(tx: tx) == .rebuild, "a read moved")
            rt.resizeReadMovedFlag = false
            rt.setViewport(rt.viewport, pixelScale: 1.0)
            #expect(rt.nextCommitKind(tx: tx) == .rebuild, "a new scale")
            rt.setViewport(rt.viewport, pixelScale: rt.cachedResizeBuild!.env.pixelScale)
            rt.stateUnchangedSinceBuild = false
            #expect(rt.nextCommitKind(tx: tx) == .rebuild, "the state changed")
            rt.stateUnchangedSinceBuild = true
        }
        let (plain, _) = makeParagraphRuntime(0)
        _ = plain.frame(at: 0.0)
        plain.stateUnchangedSinceBuild = true
        plain.pendingResizeRelayout = false
        #expect(plain.nextCommitKind(tx: tx) == .rebuild, "no virtual rows to remount")
    }

    @Test("indexed rows remount without rerunning the view with or without a declining scroll-end observer", arguments: [false, true])
    func decliningScrollEndObserverPreservesVirtualRemount(_ observes: Bool) {
        var views = 0
        var reports: [Bool] = []
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 100), pixelScale: 1) { _, _ in
            views += 1
            let rows: El<Int> = col().key("rows").wFull()
                .virtualRows(200, 24, key: { _, i in "row-\(i)" }) { _, _ in el().wFull().h(24) }
            let scroll = col().key("scroll").size(200, 100).scrollY(stickBottom: false).child(rows)
            if observes {
                return scroll.onAtBottomIf { _, at in
                    reports.append(at)
                    return false
                }
            }
            return scroll
        }
        _ = rt.frame(at: 0)
        _ = rt.frame(at: 0.02)
        let initialViews = views
        rt.wheel(WheelEvent(dx: 0, dy: -5000), at: Vec2(50, 50), now: 0.03)
        _ = rt.frame(at: 0.04)
        _ = rt.frame(at: 0.05)
        #expect((rt.virtualLists.values.first?.lastMountedRange.lowerBound ?? 0) > 0)
        #expect(views == initialViews)
        #expect(reports == (observes ? [false, true] : []))
    }

    // MARK: - Live Bindings During Relayout (relayout/live.rs)

    private struct LiveBindings {
        var spring: Bool = false
        var offset = Live<Vec2>(Vec2(7.0, 11.0))
        var rect = Live<MotionRect>(MotionRect(left: 30.0, top: 40.0, right: 90.0, bottom: 110.0))
        var opacity = Live<Float>(0.7)
        var scale = Live<Float>(0.8)
        var blur = Live<Float>(2.0)
        var fill = Live<Color>(.white)
    }

    private func buildLiveView(_ s: LiveBindings, _: inout Cx<LiveBindings>) -> El<LiveBindings> {
        let offsetBinding = s.spring ? s.offset.smooth(Spring(duration: 0.4, bounce: 0.0)) : s.offset.binding
        return row().wFull().hFull().justifyEnd().child(
            col().key("bound").w(100.0).hFull()
                .liveOffset(offsetBinding)
                .liveOpacity(s.opacity.binding)
                .liveScale(s.scale.binding)
                .liveBlur(s.blur.binding)
                .liveFill(s.fill.binding)
                .child(el().key("thumb").absolute(x: 0.0, y: 0.0).liveRect(s.rect.binding).bg(.white))
        )
    }

    @Test("relayout_live: resizing_during_a_live_spring_keeps_its_progress_and_velocity")
    func resizingDuringLiveSpringKeepsProgressAndVelocity() {
        let rt = Runtime<LiveBindings>(
            state: LiveBindings(spring: true),
            viewport: Vec2(700.0, 600.0),
            pixelScale: 2.0,
            systemDark: true,
            view: buildLiveView
        )
        let reference = Runtime<LiveBindings>(
            state: LiveBindings(spring: true),
            viewport: Vec2(700.0, 600.0),
            pixelScale: 2.0,
            systemDark: true,
            view: buildLiveView
        )
        var t = 0.0
        var tr = 0.0
        _ = rt.frame(at: t)
        _ = reference.frame(at: tr)
        rt.state.offset.set(Vec2(90.0, 110.0))
        reference.state.offset.set(Vec2(90.0, 110.0))

        for i in 0..<90 {
            if i == 8 {
                rt.state.offset.set(Vec2(20.0, 30.0))
                reference.state.offset.set(Vec2(20.0, 30.0))
            }
            #expect(resize(rt, width: 700.0 - Float(i), t: &t) == 0)
            tr += 1.0 / 120.0
            _ = reference.frame(at: tr)
            let a = rt.element(byKey: "bound")!.rect
            let b = reference.element(byKey: "bound")!.rect
            // X aligns to trailing edge (which shifts by -i during resize), while Y offset progress must match identically.
            #expect(abs((a[0] + Float(i)) - b[0]) < 0.05, "frame \(i): X spring matches relative to resize")
            #expect(abs(a[1] - b[1]) < 0.05, "frame \(i): Y spring matches")
        }
    }

    @Test("relayout_live: a_layout_read_retry_restores_the_moved_live_nodes")
    func layoutReadRetryRestoresMovedLiveNodes() {
        let rt = Runtime<LiveBindings>(
            state: LiveBindings(),
            viewport: Vec2(700.0, 600.0),
            pixelScale: 2.0,
            systemDark: true
        ) { s, cx in
            _ = cx.layoutSize("window")
            return self.buildLiveView(s, &cx).key("window")
        }
        var t = 0.0
        _ = rt.frame(at: t)
        #expect(resize(rt, width: 500.0, t: &t) > 0, "changed layout reads still run the view")
        rt.state.offset.set(Vec2(30.0, 50.0))
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let bound = rt.element(byKey: "bound")!
        #expect(rt.liveStore.get(NodeId.hash("live:\(bound.path):offset"), Props.OFFSET) == Vec2(30.0, 50.0))
        #expect(abs((bound.rect[1] - 60.0) - 50.0) < 0.5)
        #expect(abs(bound.fill.r - 1.0) < 0.05)
    }

    @Test("relayout_live: resize_keeps_live_bindings_without_running_the_view")
    func resizeKeepsLiveBindingsWithoutRunningView() {
        let rt = Runtime<LiveBindings>(
            state: LiveBindings(),
            viewport: Vec2(700.0, 600.0),
            pixelScale: 2.0,
            systemDark: true,
            view: buildLiveView
        )
        let full = Runtime<LiveBindings>(
            state: LiveBindings(),
            viewport: Vec2(700.0, 600.0),
            pixelScale: 2.0,
            systemDark: true,
            view: buildLiveView
        )
        var t = 0.0
        var tf = 0.0
        _ = rt.frame(at: t)
        _ = full.frame(at: tf)

        for w: Float in [600.0, 420.0, 300.0, 520.0] {
            #expect(resize(rt, width: w, t: &t) == 0, "live bindings allow relayout at \(w)")
            full.update(at: tf) { _, tx in tx.instant() }
            #expect(fullResize(full, width: w, t: &tf) == 1)
            for key in ["bound", "thumb"] {
                let ea = rt.element(byKey: key)!
                let eb = full.element(byKey: key)!
                for i in 0..<4 {
                    #expect(abs(ea.rect[i] - eb.rect[i]) < 0.05, "drawn \(key)[\(i)]")
                }
            }
            for s in [rt.state, full.state] {
                s.offset.set(Vec2(w / 20.0, 15.0))
                s.rect.set(MotionRect(left: 10.0, top: w / 10.0, right: 18.0, bottom: w / 10.0 + 40.0))
                s.opacity.set(w / 1000.0)
                s.scale.set(w / 700.0)
                s.blur.set(w / 100.0)
                s.fill.set(.black)
            }
            let before = rt.viewCallCount
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            #expect(rt.viewCallCount == before, "live subscription wakes without running view")
            tf += 1.0 / 120.0
            _ = full.frame(at: tf)
            for key in ["bound", "thumb"] {
                let ea = rt.element(byKey: key)!
                let eb = full.element(byKey: key)!
                for i in 0..<4 {
                    #expect(abs(ea.rect[i] - eb.rect[i]) < 0.05, "post-live drawn \(key)[\(i)]")
                }
                #expect(abs(ea.opacity - eb.opacity) < 0.01)
                #expect(abs(ea.scale - eb.scale) < 0.01)
                #expect(abs(ea.blur - eb.blur) < 0.01)
                #expect(abs(ea.fill.r - eb.fill.r) < 0.02)
            }
        }
    }

    @Test("a_view_that_reads_cx_viewport_rebuilds_on_resize")
    func viewThatReadsCxViewportRebuildsOnResize() {
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(600.0, 400.0),
            pixelScale: 1.0
        ) { _, cx in
            let w = cx.viewport.x - 2.0
            return col().wFull().child(
                el().key("hdr").w(w).h(24.0)
            )
        }
        var t = 0.0
        _ = rt.frame(at: t)
        #expect(rt.element(byKey: "hdr")?.rect[2] == 598.0)

        let ran1 = resize(rt, width: 800.0, t: &t)
        #expect(ran1 == 1)
        #expect(rt.element(byKey: "hdr")?.rect[2] == 798.0)

        let ran2 = resize(rt, width: 450.0, t: &t)
        #expect(ran2 == 1)
        #expect(rt.element(byKey: "hdr")?.rect[2] == 448.0)
    }
}
