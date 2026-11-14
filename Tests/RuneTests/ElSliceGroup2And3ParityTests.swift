import Testing
import Foundation
import RuneRef
@testable import Rune

@Suite("El Slice Group 2 & 3 Parity (id_pruning, remount, memo_reuse)")
struct ElSliceGroup2And3ParityTests {
    // MARK: - id_pruning.rs

    @Test("rows_that_left_leave_no_ids_or_growth_entries_behind")
    func rowsThatLeftLeaveNoIdsOrGrowthEntriesBehind() {
        func build(_ start: Int, _: inout Cx<Int>) -> El<Int> {
            var stack: El<Int> = col().key("stack").wFull().growth(.default)
            for i in start..<(start + 3) {
                stack = stack.child(
                    el().key("r\(i)").wFull().child(el().key("label").h(20.0))
                )
            }
            return col().key("root").size(200.0, 200.0).child(stack)
        }

        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(200.0, 200.0),
            pixelScale: 1.0,
            systemDark: true,
            view: build
        )
        var t = 0.0
        _ = rt.frame(at: t)
        let mountedCount = rt.flatNodes.count
        for _ in 0..<40 {
            rt.update(at: t) { n, _ in n += 3 }
            for _ in 0..<90 {
                t += 1.0 / 60.0
                _ = rt.frame(at: t)
            }
        }
        #expect(rt.growthRows.count <= 6, "\(rt.growthRows.count) growth rows kept for 3 active rows")
        #expect(rt.flatNodes.count <= mountedCount + 6, "\(rt.flatNodes.count) nodes kept for \(mountedCount) mounted nodes")
        #expect(rt.exitingSnapshots.count <= rt.flatNodes.count, "exited rows pruned cleanly")
        #expect(rt.find("r120") != nil, "current rows still draw")
    }

    @Test("a_path_keeps_its_scroll_state_across_unmount_and_remount")
    func pathKeepsItsScrollStateAcrossToggle() {
        func build(_ on: Bool, _: inout Cx<Bool>) -> El<Bool> {
            var list: El<Bool> = col()
            for i in 0..<20 {
                list = list.child(el().key("i\(i)").h(40.0))
            }
            let scroll: El<Bool> = col().key("scroll").size(100.0, 100.0).scroll(stickBottom: false).child(list)
            var root: El<Bool> = col().key("root").size(100.0, 100.0)
            if on { root = root.child(scroll) }
            return root
        }

        let rt = Runtime<Bool>(
            state: true,
            viewport: Vec2(100.0, 100.0),
            pixelScale: 1.0,
            systemDark: true,
            view: build
        )
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 60.0
        rt.wheel(WheelEvent(dx: 0, dy: -120.0), at: Vec2(50.0, 50.0), now: t)
        for _ in 0..<60 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let scrolledBefore = rt.scrollOffset(forKey: "scroll")
        let idBefore = rt.flatNodes.first(where: { $0.key == "scroll" })?.nodeId
        #expect(idBefore != nil)
        #expect(abs(scrolledBefore.y) > 1.0)

        rt.update(at: t) { on, tx in on = false; tx.instant() }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        rt.update(at: t) { on, tx in on = true; tx.instant() }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)

        let idAgain = rt.flatNodes.first(where: { $0.key == "scroll" })?.nodeId
        #expect(idBefore == idAgain, "a scroll view coming back keeps its node id")
    }

    @Test("pruning_left_rows_keeps_buffers_compact")
    func pruningLeftRowsKeepsFlatNodesCompact() {
        func build(_ start: Int, _: inout Cx<Int>) -> El<Int> {
            var stack: El<Int> = col().key("stack").wFull().growth(.default)
            for i in start..<(start + 3) {
                stack = stack.child(
                    el().key("r\(i)").wFull().child(el().key("label").h(20.0))
                )
            }
            return col().key("root").size(200.0, 200.0).child(stack)
        }

        let rt = Runtime<Int>(state: 0, viewport: Vec2(200.0, 200.0), pixelScale: 1.0, systemDark: true, view: build)
        var t = 0.0
        _ = rt.frame(at: t)
        var peakCapacity = 0
        for round in 0..<12 {
            rt.update(at: t) { n, _ in n += 3 }
            for _ in 0..<90 {
                t += 1.0 / 60.0
                _ = rt.frame(at: t)
            }
            if round >= 4 {
                peakCapacity = max(peakCapacity, rt.flatNodes.capacity)
                #expect(rt.flatNodes.count <= 16, "flatNodes stayed compact at \(rt.flatNodes.count)")
            }
        }
        #expect(peakCapacity <= 64, "flatNodes capacity \(peakCapacity) did not grow unbounded")
    }

    // MARK: - remount.rs

    private struct ShownRow: Equatable {
        var path: String
        var rect: [Int]
        var text: String?
    }

    private func shownElements<S>(_ rt: Runtime<S>) -> [ShownRow] {
        rt.elements()
            .filter { $0.visible[2] > 0.0 && $0.visible[3] > 0.0 && !(rt.virtualLists[$0.path] != nil && $0.fill.a == 0.0) }
            .map { ShownRow(path: $0.path, rect: $0.rect.map { Int(($0 * 100.0).rounded()) }, text: $0.text) }
            .sorted { $0.path < $1.path }
    }

    @Test("scrolling_virtual_rows_without_memo_skips_view_and_keeps_mounted_rows")
    func scrollingVirtualRowsSkipsViewAndKeepsMountedRows() {
        var viewCount = 0
        var sideCount = 0
        var builtRows: [Int] = []

        func build(_ tick: Int, _: inout Cx<Int>) -> El<Int> {
            viewCount += 1
            sideCount += 1
            var side: El<Int> = col().key("side").w(180.0).hFull().gap(4.0)
            for i in 0..<24 {
                side = side.child(text("Side \(i): \(tick)").key("s\(i)").h(18.0))
            }
            let list: El<Int> = col().key("rows").wFull().px(8.0).growth(.default).virtualRows(
                500,
                36.0,
                key: { _, i in "r\(i)" },
                build: { t, i in
                    builtRows.append(i)
                    return row().wFull().h(36.0).gap(6.0)
                        .child(text("Row \(i)").key("title").grow(1.0))
                        .child(text("v\(t)").key("ver"))
                }
            )
            let footer: El<Int> = text("Footer \(tick)").key("footer").h(28.0)
            return row().wFull().hFull()
                .child(side)
                .child(
                    col().key("main").grow(1.0).hFull()
                        .child(col().key("scroll").wFull().grow(1.0).minH(0.0).scroll(stickBottom: false).child(list))
                        .child(footer)
                )
        }

        let rt = Runtime<Int>(state: 0, viewport: Vec2(640.0, 420.0), pixelScale: 2.0, systemDark: true, view: build)
        let full = Runtime<Int>(state: 0, viewport: Vec2(640.0, 420.0), pixelScale: 2.0, systemDark: true, view: build)
        var t = 0.0
        _ = rt.frame(at: t)
        _ = full.frame(at: t)
        for _ in 0..<10 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            _ = full.frame(at: t)
        }

        viewCount = 0
        sideCount = 0
        builtRows.removeAll()
        var scrollCommits = 0
        var fullCommits = 0

        for step in 0..<40 {
            builtRows.removeAll()
            let v0 = viewCount
            let c0 = rt.stats.commits
            t += 1.0 / 120.0
            rt.wheel(WheelEvent(dx: 0, dy: -90.0), at: Vec2(400.0, 200.0), now: t)
            _ = rt.frame(at: t)
            #expect(viewCount - v0 == 0, "step \(step): scrolling must not re-run view (ran \(viewCount - v0) times)")
            if rt.stats.commits > c0 {
                scrollCommits += 1
                let mountedLen = rt.virtualLists["/0/@main/@scroll/@rows"]?.lastMountedRange.count ?? 0
                #expect(builtRows.count < mountedLen || builtRows.isEmpty, "step \(step): built \(builtRows.count) rows for a \(mountedLen)-row window")
            }

            let fc0 = full.stats.commits
            full.pixelScale = Float.nan
            full.pixelScale = 2.0
            full.wheel(WheelEvent(dx: 0, dy: -90.0), at: Vec2(400.0, 200.0), now: t)
            _ = full.frame(at: t)
            if full.stats.commits > fc0 {
                fullCommits += 1
            }
            #expect(shownElements(rt) == shownElements(full), "step \(step): visible elements diverged")
        }
        #expect(scrollCommits >= 10, "expected virtual window shifts, got \(scrollCommits)")
        #expect(fullCommits > 0, "expected reference runtime commits, got \(fullCommits)")
        #expect(sideCount == fullCommits, "only full reference ran sidebar")

        let vBeforeUpdate = viewCount
        rt.update(at: t) { val, _ in val = 7 }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(viewCount - vBeforeUpdate == 1)
        full.update(at: t) { val, _ in val = 7 }
        _ = full.frame(at: t)
        #expect(shownElements(rt) == shownElements(full))
    }

    @Test("virtual_remount_reruns_view_when_layout_read_of_culled_row_changes")
    func virtualRemountRerunsViewWhenLayoutReadOfCulledRowChanges() {
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(300.0, 240.0),
            pixelScale: 1.0,
            systemDark: true
        ) { _, cx in
            let r0Mounted = cx.layout("r0") != nil
            let list: El<Int> = col().key("rows").wFull().growth(.default).virtualRows(
                200,
                40.0,
                key: { _, i in "r\(i)" },
                build: { _, i in text("Row \(i)").h(40.0) }
            )
            return col().wFull().hFull()
                .child(text("r0=\(r0Mounted)").key("status").h(24.0))
                .child(col().key("scroll").wFull().grow(1.0).minH(0.0).scroll(stickBottom: false).child(list))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        while rt.isAnimating {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        let status: () -> String? = {
            rt.elements().first(where: { $0.key == "status" })?.text
        }
        #expect(status() == "r0=true")

        t += 1.0 / 120.0
        rt.wheel(WheelEvent(dx: 0, dy: -3000.0), at: Vec2(150.0, 120.0), now: t)
        _ = rt.frame(at: t)
        #expect(status() == "r0=false")
    }

    @Test("virtual_remount_preserves_text_selection_across_scrolled_out_rows")
    func virtualRemountPreservesTextSelectionAcrossScrolledOutRows() {
        var views = 0
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(300.0, 200.0),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            views += 1
            let list: El<Int> = col().key("rows").wFull().selectionGroup(true).growth(.default).virtualRows(
                200,
                32.0,
                key: { _, i in "r\(i)" },
                build: { _, i in text("Line \(i)").key("txt").selectable(true).h(32.0) }
            )
            return col().wFull().hFull()
                .child(col().key("scroll").wFull().grow(1.0).minH(0.0).scroll(stickBottom: false).child(list))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        while rt.isAnimating {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }

        t += 1.0 / 120.0
        rt.pointerDown(at: Vec2(0.0, 10.0), at: t)
        rt.pointerMove(to: Vec2(120.0, 50.0), at: t)
        _ = rt.frame(at: t)
        for _ in 0..<10 {
            let v0 = views
            t += 1.0 / 120.0
            rt.wheel(WheelEvent(dx: 0, dy: -300.0), at: Vec2(150.0, 100.0), now: t)
            rt.pointerMove(to: Vec2(120.0, 150.0), at: t)
            _ = rt.frame(at: t)
            #expect(views - v0 == 0)
        }
        t += 1.0 / 120.0
        rt.pointerUp(at: Vec2(120.0, 150.0), at: t)
        _ = rt.frame(at: t)
        #expect(rt.find("r0") == nil, "r0 scrolled out of mounted window")
        let copied = rt.selectedText() ?? ""
        #expect(copied.hasPrefix("Line 0\n"), "pinned row 0 stays in selection: \(copied)")
    }

    @Test("virtual_remount_keeps_view_and_mounted_row_memos_and_evicts_culled_ones")
    func virtualRemountKeepsViewAndMountedRowMemosAndEvictsCulledOnes() {
        struct S {
            var tick: Int = 0
            var clicked: Int? = nil
            var edit = TextEdit()
        }
        var headerBuilds = 0
        var rowMemoBuilds: [Int] = []

        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(320.0, 220.0),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            _ = s.tick
            let header: El<S> = memo("hdr", deps: 0) {
                headerBuilds += 1
                return text("Header").h(24.0)
            }
            let list: El<S> = col().key("rows").wFull().growth(.default).virtualRows(
                300,
                32.0,
                key: { _, i in "r\(i)" },
                build: { _, i in
                    memo("m\(i)", deps: 0) { () -> El<S> in
                        rowMemoBuilds.append(i)
                        let r: El<S> = row().wFull().h(32.0)
                        return r.onClick { st in st.clicked = i }
                            .child(text("Row \(i)").grow(1.0))
                            .child(textInput(key: "ed-\(i)", \S.edit).font(TextStyle(size: 13.0, weight: 400.0)).w(60.0))
                    }
                }
            )
            return col().wFull().hFull()
                .child(header)
                .child(col().key("scroll").wFull().grow(1.0).minH(0.0).scroll(stickBottom: false).child(list))
        }

        var t = 0.0
        _ = rt.frame(at: t)
        while rt.isAnimating {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        #expect(headerBuilds == 1)

        for _ in 0..<30 {
            t += 1.0 / 120.0
            rt.wheel(WheelEvent(dx: 0, dy: -240.0), at: Vec2(160.0, 120.0), now: t)
            _ = rt.frame(at: t)
        }
        while rt.isAnimating {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }

        let mounted: Range<Int> = rt.virtualLists["/0/@scroll/@rows"]?.lastMountedRange ?? (0..<0)
        #expect(mounted.lowerBound > 50, "scrolled past early rows: \(String(describing: mounted))")
        rowMemoBuilds.removeAll()

        rt.update(at: t) { s, _ in s.tick += 1 }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(headerBuilds == 1, "view-level memo survived partial commits")
        let rebuiltMounted = rowMemoBuilds.filter { mounted.contains($0) }
        #expect(rebuiltMounted.isEmpty, "mounted row memos survived partial commits, got \(rebuiltMounted)")
        #expect(rt.memo.len <= mounted.count + 2, "culled row memos evicted: memo len \(rt.memo.len), mounted \(String(describing: mounted))")

        let hitRow = rt.elements().compactMap { info -> (Int, ElementInfo)? in
            guard let key = info.key, key.hasPrefix("r"), let idx = Int(key.dropFirst()), info.visible[3] >= 20.0 else {
                return nil
            }
            return (idx, info)
        }.first
        #expect(hitRow != nil, "on-screen row should exist")
        if let (expectedIdx, visRow) = hitRow {
            let pt = Vec2(visRow.visible[0] + 10.0, visRow.visible[1] + 10.0)
            t += 1.0 / 120.0
            rt.pointerMove(to: pt, at: t)
            rt.pointerDown(at: pt, at: t)
            rt.pointerUp(at: pt, at: t)
            _ = rt.frame(at: t)
            #expect(rt.state.clicked == expectedIdx)
        }
    }

    // MARK: - memo_reuse_tests.rs

    private struct CardsState {
        var useMemo: Bool
        var bannerH: Float = 24.0
        var tick: Int = 0
        var cardVer: [Int] = [0, 0, 0, 0]
        var showCard: [Bool] = [true, true, true, true]
        var swapOrder: Bool = false
        var nestInRight: Bool = false
        var dimFirst: Bool = false
    }

    private func maybeMemo<S, D: Equatable>(_ useMemo: Bool, _ id: String, _ ver: D, _ build: () -> El<S>) -> El<S> {
        if useMemo {
            return memo(id, deps: ver, build: build)
        }
        return build().key(id)
    }

    private func cardBody(_ i: Int, _ ver: Int, _ useMemo: Bool) -> El<CardsState> {
        let title = "Card \(i) v\(ver)"
        let body = "Detailed body copy for card \(i) at version \(ver) with wrapping words."
        let badge: El<CardsState> = el().key("badge").size(10.0, 10.0).rounded(5.0)
            .bg(Color(r: 0.3, g: 0.7, b: 0.9, a: 1.0)).groupOpacity(0.6, 1.0)
        let titleEl: El<CardsState> = text(title).key("title").font(TextStyle(size: 14.0, weight: 600.0))
            .color(.white).grow(1.0).shrink().ellipsis()
        let pill = maybeMemo(useMemo, "nested-pill", ver) { () -> El<CardsState> in
            let overlay = ScrollBars.automatic.isOverlay(scrollerOverlay: false)
            let p: El<CardsState> = row()
            return p.p(overlay ? 4.0 : 6.0).rounded(4.0).bg(Color.white.alpha(0.08))
                .child(text("#\(ver)").key("v").font(TextStyle(size: 11.0, weight: 500.0)))
        }
        let head: El<CardsState> = row().key("head").wFull().gap(8.0).centerY()
            .child(badge)
            .child(titleEl)
            .child(pill)
        let desc: El<CardsState> = rich(body, [RichSpan(0..<8).weight(700.0).color(Color(r: 0.9, g: 0.8, b: 0.4, a: 1.0))])
            .key("desc")
            .wFull()
            .selectable(true)
        var card: El<CardsState> = col()
            .wFull()
            .p(10.0)
            .gap(6.0)
            .rounded(8.0)
            .bg(Color(r: 0.12, g: 0.14, b: 0.18, a: 1.0))
            .border(1.0, Color.white.alpha(0.15))
            .hover(Color.white.alpha(0.06))
            .press(Color.white.alpha(0.12))
            .pressScale(0.97)
            .hoverGroup()
            .focusable(true)
            .onClick { s in s.tick += i + 1 }
            .transition(.opacity)
            .child(head)
            .child(desc)
        if ver % 2 == 0 {
            card = card.child(
                text("Optional footer note").key("footer").font(TextStyle(size: 11.0, weight: 400.0)).color(Color.white.alpha(0.6)).transition(.opacity)
            )
        }
        return card
    }

    private func cardsView(_ s: CardsState, _ cx: inout Cx<CardsState>) -> El<CardsState> {
        let m = s.useMemo
        let indices = s.swapOrder ? [2, 1, 0, 3] : [0, 1, 2, 3]
        var leftKids: [El<CardsState>] = []
        var rightKids: [El<CardsState>] = []
        for i in indices where s.showCard[i] {
            let ver = s.cardVer[i]
            var c = maybeMemo(m, "card-\(i)", ver) { cardBody(i, ver, m) }
            if i == 0 && s.dimFirst {
                c = c.opacity(0.45)
            }
            if i == 1 && s.nestInRight {
                rightKids.append(c)
            } else {
                leftKids.append(c)
            }
        }
        if !s.nestInRight {
            rightKids.append(el().key("card-1").wFull().h(18.0).bg(Color.white.alpha(0.05)))
        }
        let accent = cx.accent()
        return col().wFull().hFull().p(12.0).gap(8.0).selectionGroup(true)
            .child(el().key("banner").wFull().h(s.bannerH).rounded(6.0).bg(accent))
            .child(text("tick \(s.tick)").key("tick").font(TextStyle(size: 12.0, weight: 400.0)))
            .child(
                row().key("columns").wFull().grow(1.0).minH(0.0).gap(12.0)
                    .child(col().key("left").grow(1.0).shrink().gap(8.0).children(leftKids))
                    .child(col().key("right").w(180.0).gap(8.0).children(rightKids))
            )
    }

    private struct ParityDivergence: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private func assertSameState<S>(_ memoRt: Runtime<S>, _ freshRt: Runtime<S>, _ memoScene: RefScene, _ freshScene: RefScene, _ step: String) throws {
        if memoRt.isAnimating != freshRt.isAnimating {
            throw ParityDivergence(message: "\(step): animating mismatch \(memoRt.isAnimating) != \(freshRt.isAnimating)")
        }
        if memoRt.flatNodes.count != freshRt.flatNodes.count {
            throw ParityDivergence(message: "\(step): node count \(memoRt.flatNodes.count) != \(freshRt.flatNodes.count)")
        }
        for (idx, (a, b)) in zip(memoRt.flatNodes, freshRt.flatNodes).enumerated() {
            if a.path != b.path || a.key != b.key || a.localRect != b.localRect || a.targetRect != b.targetRect || a.effectiveInert != b.effectiveInert {
                throw ParityDivergence(message: "\(step): node[\(idx)] path=\(a.path) vs \(b.path) key=\(String(describing: a.key)) vs \(String(describing: b.key)) local=\(a.localRect) vs \(b.localRect) target=\(a.targetRect) vs \(b.targetRect) inert=\(a.effectiveInert) vs \(b.effectiveInert)")
            }
        }
        let ea = memoRt.elements()
        let eb = freshRt.elements()
        if ea.count != eb.count {
            throw ParityDivergence(message: "\(step): ElementInfo count \(ea.count) != \(eb.count)")
        }
        for (idx, (a, b)) in zip(ea, eb).enumerated() {
            if a.path != b.path || a.key != b.key || a.exiting != b.exiting || a.focused != b.focused || a.focusVisible != b.focusVisible || a.inert != b.inert || a.text != b.text || a.selected != b.selected || a.caret != b.caret {
                throw ParityDivergence(message: "\(step): ElementInfo[\(idx)] state memo=(path:\(a.path), key:\(String(describing: a.key)), exiting:\(a.exiting), focused:\(a.focused), text:\(String(describing: a.text))) fresh=(path:\(b.path), key:\(String(describing: b.key)), exiting:\(b.exiting), focused:\(b.focused), text:\(String(describing: b.text)))")
            }
            if a.rect != b.rect || a.target != b.target || a.visible != b.visible || a.opacity.bitPattern != b.opacity.bitPattern || a.scale.bitPattern != b.scale.bitPattern || a.hover.bitPattern != b.hover.bitPattern || a.press.bitPattern != b.press.bitPattern || a.moving != b.moving {
                throw ParityDivergence(message: "\(step): ElementInfo[\(idx)] (\(a.path)) geom memo=(rect:\(a.rect), vis:\(a.visible), op:\(a.opacity), sc:\(a.scale), mov:\(a.moving)) fresh=(rect:\(b.rect), vis:\(b.visible), op:\(b.opacity), sc:\(b.scale), mov:\(b.moving))")
            }
        }
        if memoScene.primitives != freshScene.primitives {
            throw ParityDivergence(message: "\(step): primitive stream diverged (\(memoScene.primitives.count) vs \(freshScene.primitives.count))")
        }
    }

    private func stepBoth<S>(_ a: Runtime<S>, _ b: Runtime<S>, dt: Double, t: inout Double, _ label: String, _ f: (Runtime<S>, Double) -> Void) throws {
        t += dt
        f(a, t)
        f(b, t)
        let sa = a.frame(at: t)
        let sb = b.frame(at: t)
        try assertSameState(a, b, sa, sb, label)
    }

    @Test("steady_commits_moving_ancestors_rebase_exits_and_modifiers_match_fresh_build")
    func steadyCommitsMovingAncestorsRebaseExitsAndModifiersMatchFreshBuild() throws {
        let rtM = Runtime(state: CardsState(useMemo: true), viewport: Vec2(560.0, 520.0), pixelScale: 2.0, systemDark: true, view: cardsView)
        let rtF = Runtime(state: CardsState(useMemo: false), viewport: Vec2(560.0, 520.0), pixelScale: 2.0, systemDark: true, view: cardsView)
        var t = 0.0
        try stepBoth(rtM, rtF, dt: 0.0, t: &t, "initial") { _, _ in }
        let firstBuilds = rtM.memo.builds
        #expect(firstBuilds >= 4)

        for k in 0..<5 {
            try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "steady-\(k)") { rt, now in
                rt.update(at: now) { s, _ in s.tick += 1 }
            }
        }
        #expect(rtM.memo.builds == firstBuilds, "no memo rebuilt during steady ticks")

        try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "banner-grow") { rt, now in
            rt.update(at: now) { s, _ in s.bannerH = 68.0 }
        }
        for f in 0..<30 {
            try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "banner-spring-\(f)") { rt, now in
                if f == 5 { rt.update(at: now) { s, _ in s.tick += 1 } }
            }
        }

        try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "reorder-and-rebase") { rt, now in
            rt.update(at: now) { s, _ in
                s.swapOrder = true
                s.nestInRight = true
            }
        }
        for f in 0..<25 {
            try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "rebase-spring-\(f)") { _, _ in }
        }

        try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "root-modifier-on") { rt, now in
            rt.update(at: now) { s, _ in s.dimFirst = true }
        }
        for f in 0..<15 {
            try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "dim-spring-\(f)") { _, _ in }
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "root-modifier-off") { rt, now in
            rt.update(at: now) { s, _ in s.dimFirst = false }
        }

        try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "exits-begin") { rt, now in
            rt.update(at: now) { s, _ in
                s.cardVer[2] += 1
                s.showCard[1] = false
            }
        }
        for f in 0..<45 {
            try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "exits-step-\(f)") { rt, now in
                if f == 4 { rt.update(at: now) { s, _ in s.tick += 1 } }
            }
        }
        for k in 0..<3 {
            try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "after-prune-\(k)") { rt, now in
                rt.update(at: now) { s, _ in s.tick += 1 }
            }
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "remove-card-3") { rt, now in
            rt.update(at: now) { s, _ in s.showCard[3] = false }
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "mid-exit") { _, _ in }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "revive-card-3") { rt, now in
            rt.update(at: now) { s, _ in s.showCard[3] = true }
        }
        for f in 0..<20 {
            try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "revive-settle-\(f)") { _, _ in }
        }
    }

    @Test("hover_press_focus_selection_env_blend_and_hot_clear_match_fresh_build")
    func hoverPressFocusSelectionEnvBlendAndHotClearMatchFreshBuild() throws {
        let rtM = Runtime(state: CardsState(useMemo: true), viewport: Vec2(560.0, 520.0), pixelScale: 1.0, systemDark: true, view: cardsView)
        let rtF = Runtime(state: CardsState(useMemo: false), viewport: Vec2(560.0, 520.0), pixelScale: 1.0, systemDark: true, view: cardsView)
        var t = 0.0
        try stepBoth(rtM, rtF, dt: 0.0, t: &t, "init") { _, _ in }

        guard let cPos = rtM.find("card-0") else {
            Issue.record("card-0 not found")
            return
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "hover-enter") { rt, now in
            rt.pointerMove(to: cPos, at: now)
        }
        for f in 0..<8 {
            try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "hover-spring-\(f)") { rt, now in
                if f == 3 { rt.update(at: now) { s, _ in s.tick += 1 } }
            }
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "press-down") { rt, now in
            rt.pointerDown(at: cPos, at: now)
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "press-held-commit") { rt, now in
            rt.update(at: now) { s, _ in s.tick += 1 }
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "press-up") { rt, now in
            rt.pointerUp(at: cPos, at: now)
        }
        #expect(rtM.state.tick == rtF.state.tick)

        for tab in 0..<3 {
            try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "tab-\(tab)") { rt, now in
                _ = rt.keyDown(KeyEvent(key: .tab), at: now)
            }
        }

        try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "select-all") { rt, now in
            rt.update(at: now) { _, tx in tx.selectAllText("columns") }
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "selection-commit") { rt, now in
            rt.update(at: now) { s, _ in s.tick += 1 }
        }

        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "dark-false") { rt, _ in rt.systemDark = false }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "scale-2x") { rt, _ in rt.setViewport(Vec2(560.0, 520.0), pixelScale: 2.0) }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "srgb-on") { rt, now in rt.setSrgbBlend(true, at: now) }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "srgb-off") { rt, now in rt.setSrgbBlend(false, at: now) }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "accent") { rt, _ in
            let c = Color(r: 0.9, g: 0.3, b: 0.4, a: 1.0)
            rt.setSystemAccent(SystemAccent(lightAccent: c, darkAccent: c))
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "scroll-bars-always") { rt, _ in
            rt.setSystemScrollBars(.always)
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "scroll-bars-auto-pad") { rt, _ in
            rt.setSystemScrollBars(.automatic)
            rt.setSystemScrollerOverlay(true)
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "scroll-bars-auto-mouse") { rt, _ in
            rt.setSystemScrollerOverlay(false)
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "reduced-motion") { rt, _ in
            rt.setSystemReducedMotion(true)
        }

        let beforeHot = rtM.memo.builds
        rtM.memo.clear()
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "hot-clear-rebuild") { rt, now in
            rt.update(at: now) { s, _ in s.tick += 1 }
        }
        #expect(rtM.memo.builds > beforeHot, "hot clear rebuilds memos cleanly")
    }

    @Test("virtual_rows_inside_memos_layout_reads_live_values_and_duplicate_keys_match_fresh_build")
    func virtualRowsInsideMemosLayoutReadsLiveValuesAndDuplicateKeysMatchFreshBuild() throws {
        struct WorkspaceState {
            var useMemo: Bool
            var probeW: Float = 120.0
            var panelVer: Int = 0
            var rows: [(String, Int)] = (0..<80).map { ("Row item \($0)", 0) }
            var composer: TextEdit
            var liveOpacity: Live<Float>
            var liveLabel: LiveText
            var pixels: Pixels
            var dupKeys: Bool = false
        }

        func workspaceView(_ s: WorkspaceState, _ cx: inout Cx<WorkspaceState>) -> El<WorkspaceState> {
            let m = s.useMemo
            let probeSz = cx.layoutSize("probe") ?? [0, 0]
            let innerSz = cx.layoutSize("live-card") ?? [0, 0]

            let panel: El<WorkspaceState> = maybeMemo(m, "outer-panel", s.panelVer) { () -> El<WorkspaceState> in
                let list: El<WorkspaceState> = col().key("vrows").wFull().gap(4.0).growth(.default).virtualRows(
                    s.rows.count,
                    36.0,
                    key: { _, i in "vr-\(i)" },
                    build: { st, i in
                        let (lbl, ver) = st.rows[i]
                        return maybeMemo(st.useMemo, "vr-\(i)", ver) { () -> El<WorkspaceState> in
                            let r: El<WorkspaceState> = row().wFull().h(36.0).px(8.0).gap(6.0).centerY().bg(Color.white.alpha(0.05))
                            return r
                                .child(el().key("dot").size(6.0, 6.0).rounded(3.0).bg(.white))
                                .child(text(lbl).key("txt").font(TextStyle(size: 13.0, weight: 400.0)).grow(1.0).shrink().ellipsis())
                        }
                    }
                )
                return col().wFull().grow(1.0).minH(0.0).scroll(stickBottom: false).child(list)
            }

            let liveOp = s.liveOpacity
            let liveTxt = s.liveLabel
            let px = s.pixels
            let dup = s.dupKeys
            let liveCard: El<WorkspaceState> = maybeMemo(m, "live-card", dup) { () -> El<WorkspaceState> in
                let r: El<WorkspaceState> = row().wFull().h(30.0).gap(8.0).centerY()
                return r
                    .liveOpacity(Binding(live: liveOp))
                    .child(el().key("avatar").size(16.0, 16.0).pixels(px))
                    .child(liveText(liveTxt).key("clock").font(TextStyle(size: 12.0, weight: 400.0)))
                    .child(el().key("dup").size(8.0, 8.0))
                    .child(el().key(dup ? "dup" : "unique").size(8.0, 8.0))
            }

            let sizeReader: El<WorkspaceState> = maybeMemo(m, "size-reader", 0) { () -> El<WorkspaceState> in
                let w = layoutSize("probe")?[0] ?? -1.0
                return text(String(format: "probe=%.0f", w)).key("probe-txt").font(TextStyle(size: 12.0, weight: 400.0))
            }

            return col().wFull().hFull().p(8.0).gap(6.0)
                .child(el().key("probe").w(s.probeW).h(10.0).bg(Color.white.alpha(0.2)))
                .child(text("seen \(probeSz) \(innerSz)").key("summary").font(TextStyle(size: 11.0, weight: 400.0)))
                .child(sizeReader)
                .child(liveCard)
                .child(panel)
                .child(textInput(key: "composer", \WorkspaceState.composer).font(TextStyle(size: 13.0, weight: 400.0)).wFull().h(32.0).focused(true))
        }

        func makeState(_ useMemo: Bool) -> WorkspaceState {
            let comp = TextEdit("hello ")
            let px = Pixels()
            px.set(width: 4, height: 4, rgba: [UInt8](repeating: 200, count: 64))
            return WorkspaceState(
                useMemo: useMemo,
                composer: comp,
                liveOpacity: Live(0.85),
                liveLabel: LiveText("00:01"),
                pixels: px
            )
        }

        let rtM = Runtime(state: makeState(true), viewport: Vec2(420.0, 380.0), pixelScale: 2.0, systemDark: true, view: workspaceView)
        let rtF = Runtime(state: makeState(false), viewport: Vec2(420.0, 380.0), pixelScale: 2.0, systemDark: true, view: workspaceView)
        var t = 0.0
        try stepBoth(rtM, rtF, dt: 0.0, t: &t, "init") { _, _ in }
        for f in 0..<8 {
            try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "overscan-fill-\(f)") { _, _ in }
        }

        for ch in ["a", "b", "c"] {
            try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "type-\(ch)") { rt, now in
                _ = rt.dispatchIme(.commit(ch), at: now)
            }
        }

        for s in 0..<12 {
            try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "scroll-down-\(s)") { rt, now in
                rt.wheel(WheelEvent(dx: 0, dy: -140.0), at: Vec2(200.0, 220.0), now: now)
            }
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "bump-row") { rt, now in
            rt.update(at: now) { st, _ in
                for i in st.rows.indices {
                    st.rows[i].0 += "!"
                    st.rows[i].1 += 1
                }
            }
        }
        for s in 0..<12 {
            try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "scroll-up-\(s)") { rt, now in
                rt.wheel(WheelEvent(dx: 0, dy: 140.0), at: Vec2(200.0, 220.0), now: now)
            }
        }

        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "resize-probe") { rt, now in
            rt.update(at: now) { st, _ in st.probeW = 210.0 }
        }
        for f in 0..<15 {
            try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "probe-spring-\(f)") { _, _ in }
        }

        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "live-update") { rt, _ in
            rt.state.liveOpacity.set(0.5)
            rt.state.liveLabel.set("00:42")
            rt.state.pixels.set(width: 4, height: 4, rgba: [UInt8](repeating: 90, count: 64))
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "commit-after-live") { rt, now in
            _ = rt.dispatchIme(.commit("!"), at: now)
        }

        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "dup-keys") { rt, now in
            rt.update(at: now) { st, _ in st.dupKeys = true }
        }
        #expect(rtM.lastKeyDiagnostics == rtF.lastKeyDiagnostics, "duplicate-key warnings match")
    }

    @Test("self_prefix_rebase_box_into_box_box_and_back_matches_fresh_build")
    func selfPrefixRebaseBoxIntoBoxBoxAndBackMatchesFreshBuild() throws {
        struct RebaseState {
            var useMemo: Bool
            var wrapped: Bool
        }
        func view(_ s: RebaseState, _: inout Cx<RebaseState>) -> El<RebaseState> {
            let leaf: El<RebaseState> = maybeMemo(s.useMemo, "box", 0) { () -> El<RebaseState> in
                let c: El<RebaseState> = col()
                return c.w(80.0).h(30.0).bg(.white).child(text("inner").key("box"))
            }
            return col().size(200.0, 200.0).child(
                s.wrapped ? col().key("box").w(120.0).h(60.0).child(leaf) : leaf
            )
        }
        let rtM = Runtime(state: RebaseState(useMemo: true, wrapped: false), viewport: Vec2(200.0, 200.0), pixelScale: 1.0, systemDark: true, view: view)
        let rtF = Runtime(state: RebaseState(useMemo: false, wrapped: false), viewport: Vec2(200.0, 200.0), pixelScale: 1.0, systemDark: true, view: view)
        var t = 0.0
        try stepBoth(rtM, rtF, dt: 0.0, t: &t, "flat") { _, _ in }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "into-wrapper") { rt, now in
            rt.update(at: now) { s, _ in s.wrapped = true }
        }
        for f in 0..<20 {
            try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "wrap-settle-\(f)") { _, _ in }
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "out-of-wrapper") { rt, now in
            rt.update(at: now) { s, _ in s.wrapped = false }
        }
        for f in 0..<20 {
            try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "unwrap-settle-\(f)") { _, _ in }
        }
    }

    @Test("move_harness_matches_fresh_across_exits_focus_selection_scroll_theme_and_long_lists")
    func moveHarnessMatchesFreshAcrossExitsFocusSelectionScrollThemeAndLongLists() throws {
        struct MoveHarness {
            var useMemo: Bool
            var tick: Int = 0
            var themeVer: Int = 0
            var headerH: Float = 18.0
            var showModal: Bool = false
            var showBannerChip: Bool = true
            var showMidMemo: Bool = true
            var listVer: Int = 0
            var vrowsLen: Int = 320
            var editor: TextEdit
            var modalInput: TextEdit
        }

        func view(_ s: MoveHarness, _ cx: inout Cx<MoveHarness>) -> El<MoveHarness> {
            let m = s.useMemo
            let dark = cx.env().systemDark
            let hdrRect = cx.layout("dyn-hdr") ?? [0, 0, 0, 0]
            let caret = cx.caret("editor") ?? [0, 0, 0, 0]
            let cardBg = (dark && s.themeVer % 2 == 0)
                ? Color(r: 0.13, g: 0.15, b: 0.20, a: 1.0)
                : Color(r: 0.88, g: 0.89, b: 0.93, a: 1.0)
            let ink = (dark && s.themeVer % 2 == 0)
                ? Color.white
                : Color(r: 0.1, g: 0.12, b: 0.16, a: 1.0)

            func styledCard(_ idx: Int) -> El<MoveHarness> {
                maybeMemo(m, "styled-\(idx)", s.themeVer) { () -> El<MoveHarness> in
                    let c: El<MoveHarness> = col()
                    return c.wFull().p(8.0).gap(4.0).rounded(6.0)
                        .bg(cardBg)
                        .border(1.0, ink.alpha(0.2))
                        .shadow(Shadow(x: 0, y: 2.0, blur: 6.0, color: Color.black.alpha(0.25)))
                        .gradient(cardBg, cardBg.alpha(0.85))
                        .radialGradient(center: Vec2(0.5, 0.5), radius: .pixels(40.0), stops: [GradientStop(ink.alpha(0.08), at: 0.0), GradientStop(.transparent, at: 1.0)])
                        .hover(ink.alpha(0.06))
                        .press(ink.alpha(0.12))
                        .focusable(true)
                        .transition(.opacity)
                        .child(text("Styled memo \(idx)").key("h").font(TextStyle(size: 13.0, weight: 600.0)).color(ink))
                        .child(text("Selectable line inside moved memo \(idx) for drag & copy").key("p").font(TextStyle(size: 12.0, weight: 400.0)).color(ink).selectable(true))
                }
            }

            let longStaticList: El<MoveHarness> = maybeMemo(m, "long-list-memo", [s.listVer, s.themeVer]) { () -> El<MoveHarness> in
                var items: El<MoveHarness> = col().key("items").wFull().gap(2.0)
                for i in 0..<140 {
                    items = items.child(
                        row().key("li-\(i)").wFull().h(22.0).px(6.0).gap(6.0).centerY()
                            .bg(cardBg.alpha(0.5))
                            .focusable(i % 25 == 0)
                            .child(el().key("b").size(6.0, 6.0).rounded(3.0).bg(ink))
                            .child(text("Long memo item #\(i)").key("t").font(TextStyle(size: 12.0, weight: 400.0)).color(ink).selectable(true))
                    )
                }
                let outer: El<MoveHarness> = col()
                return outer.wFull().h(120.0).scroll(stickBottom: false).child(items)
            }

            let longVirtualMemo: El<MoveHarness> = maybeMemo(m, "long-vlist-memo", s.vrowsLen) { () -> El<MoveHarness> in
                let list: El<MoveHarness> = col().key("vstack").wFull().gap(4.0).growth(.default).virtualRows(
                    s.vrowsLen,
                    14.0,
                    key: { _, i in "mv-\(i)" },
                    build: { st, i in
                        maybeMemo(st.useMemo, "mv-\(i)", st.themeVer) { () -> El<MoveHarness> in
                            let c: El<MoveHarness> = col()
                            return c.wFull().h(64.0).p(6.0).bg(Color.white.alpha(0.04))
                                .child(text("Virtual row \(i)").key("vt").font(TextStyle(size: 12.0, weight: 500.0)))
                                .child(text("Second line keeping row taller than estimate").key("vs").font(TextStyle(size: 11.0, weight: 400.0)))
                        }
                    }
                )
                return col().wFull().grow(1.0).minH(0.0).scroll(stickBottom: true).child(list)
            }

            var body: El<MoveHarness> = col().wFull().hFull().p(10.0).gap(6.0)
                .selectionGroup(true)
                .childExit(.opacity)
                .child(el().key("dyn-hdr").wFull().h(s.headerH).bg(ink.alpha(0.1)))
                .child(text(String(format: "t=%d hdr=%.0f caret=%.1f", s.tick, hdrRect[3], caret[0])).key("readout").font(TextStyle(size: 11.0, weight: 400.0)))
                .child(styledCard(0))
            if s.showBannerChip {
                body = body.child(
                    row().key("leaving-chip").wFull().h(20.0).bg(ink.alpha(0.15)).transition(.opacity)
                        .child(text("Transient banner").key("lbl").font(TextStyle(size: 11.0, weight: 400.0)))
                )
            }
            if s.showMidMemo {
                body = body.child(styledCard(1))
            }
            body = body
                .child(longStaticList)
                .child(longVirtualMemo)
                .child(textInput(key: "editor", \MoveHarness.editor).font(TextStyle(size: 13.0, weight: 400.0)).wFull().h(30.0))
            if s.showModal {
                body = body.child(
                    col().key("popover").wFull().p(6.0).focusReturn("styled-0").transition(.opacity)
                        .child(textInput(key: "modal-field", \MoveHarness.modalInput).focused(true).font(TextStyle(size: 13.0, weight: 400.0)).wFull().h(28.0))
                )
            }
            return body
        }

        func makeState(_ useMemo: Bool) -> MoveHarness {
            let ed = TextEdit("seed ")
            return MoveHarness(useMemo: useMemo, editor: ed, modalInput: TextEdit("modal"))
        }

        let rtM = Runtime(state: makeState(true), viewport: Vec2(500.0, 620.0), pixelScale: 2.0, systemDark: true, view: view)
        let rtF = Runtime(state: makeState(false), viewport: Vec2(500.0, 620.0), pixelScale: 2.0, systemDark: true, view: view)
        var t = 0.0
        try stepBoth(rtM, rtF, dt: 0.0, t: &t, "init") { _, _ in }
        for f in 0..<8 {
            try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "init-fill-\(f)") { _, _ in }
        }
        #expect(rtM.contentHeight() == rtF.contentHeight())

        if let editorPos = rtM.find("editor") {
            try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "focus-editor") { rt, now in
                rt.pointerDown(at: editorPos, at: now)
                rt.pointerUp(at: editorPos, at: now)
            }
        }
        for ch in ["x", "y", "z"] {
            try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "caret-remeasure-\(ch)") { rt, now in
                _ = rt.dispatchIme(.commit(ch), at: now)
            }
        }

        try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "layout-read-remeasure") { rt, now in
            rt.update(at: now) { s, _ in s.headerH = 54.0 }
        }
        for f in 0..<10 {
            try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "hdr-spring-\(f)") { rt, now in
                if f == 4 {
                    rt.update(at: now) { s, tx in s.tick += 1; tx.settle() }
                }
            }
        }

        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "elements-leave") { rt, now in
            rt.update(at: now) { s, _ in
                s.showBannerChip = false
                s.showMidMemo = false
            }
        }
        for f in 0..<25 {
            try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "leaving-fade-\(f)") { rt, now in
                if f == 3 || f == 12 { rt.update(at: now) { s, _ in s.tick += 1 } }
            }
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "revive-mid-memo") { rt, now in
            rt.update(at: now) { s, _ in s.showMidMemo = true }
        }

        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "open-focused-modal") { rt, now in
            rt.update(at: now) { s, _ in
                s.showModal = true
            }
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "close-modal-focus-return") { rt, now in
            rt.update(at: now) { s, tx in
                s.showModal = false
                tx.instant()
            }
        }
        for tabIdx in 0..<4 {
            try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "focus-tab-\(tabIdx)") { rt, now in
                _ = rt.keyDown(KeyEvent(key: .tab), at: now)
            }
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "select-all-moved") { rt, now in
            rt.update(at: now) { _, tx in tx.selectAllText("") }
        }

        if let mPos = rtM.find("styled-0/p"), let mEnd = rtM.find("styled-1/p") {
            try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "drag-sel-down") { rt, now in rt.pointerDown(at: mPos, at: now) }
            try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "drag-sel-move") { rt, now in rt.pointerMove(to: mEnd, at: now) }
            try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "drag-sel-up") { rt, now in rt.pointerUp(at: mEnd, at: now) }
            try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "commit-with-selection") { rt, now in rt.update(at: now) { s, _ in s.tick += 1 } }
        }

        if let (lx, ly) = rtM.find("long-list-memo").map({ ($0.x, $0.y) }) {
            for s in 0..<8 {
                try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "scroll-long-static-\(s)") { rt, now in
                    rt.wheel(WheelEvent(dx: 0, dy: -120.0), at: Vec2(lx, ly), now: now)
                    if s % 2 == 1 { rt.update(at: now) { st, _ in st.tick += 1 } }
                }
            }
        }
        if let (vx, vy) = rtM.find("long-vlist-memo").map({ ($0.x, $0.y) }) {
            for s in 0..<10 {
                try stepBoth(rtM, rtF, dt: 1.0 / 120.0, t: &t, "scroll-long-virtual-\(s)") { rt, now in
                    rt.wheel(WheelEvent(dx: 0, dy: 220.0), at: Vec2(vx, vy), now: now)
                    if s % 3 == 0 { rt.update(at: now) { st, _ in st.tick += 1 } }
                }
            }
        }

        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "system-light") { rt, _ in rt.systemDark = false }
        for f in 0..<10 {
            try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "light-crossfade-\(f)") { rt, now in
                if f == 2 { rt.update(at: now) { s, _ in s.tick += 1 } }
            }
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "app-theme-bump") { rt, now in
            rt.update(at: now) { s, _ in s.themeVer += 1 }
        }
        for f in 0..<10 {
            try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "app-theme-fade-\(f)") { _, _ in }
        }
        try stepBoth(rtM, rtF, dt: 1.0 / 60.0, t: &t, "system-dark-again") { rt, _ in rt.systemDark = true }
    }
}
