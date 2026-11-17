import Foundation
import Testing
@testable import Rune

/// `runtime/commit/watch.rs`: why each of a frame's commits ran (`commit_for` → `commit_why`,
/// interaction timing, `perf_warn::Watch::cause`) and `RUNE_COMMIT_BUDGET_MS` timing each commit
/// (`perf_warn/budget.rs`'s `Commit::start` / `Commit::end(cause)`).
@Suite(.serialized, PerfWarningScope())
struct CommitWatchTests {
    private struct S {
        var n = 0
        var laid: [Float] = []
        var wide = false
    }

    private func makeApp() -> Runtime<S> {
        Runtime<S>(state: S(), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            el().size(200, 200)
                .child(el().key("box").w(s.wide ? 120 : 60).h(40).onClick { st in st.n += 1 })
                .child(text("\(s.n)").key("count"))
        }
    }

    private func settled(_ rt: Runtime<S>) {
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 1.0 / 60.0)
        rt.commitWhy = 0
    }

    @Test("commit_for: a viewport change commits for `relayout`")
    func viewportChangeCommitsForRelayout() {
        let rt = makeApp()
        settled(rt)
        rt.viewport = Vec2(300, 200)
        _ = rt.frame(at: 2.0 / 60.0)
        #expect(rt.commitWhy & CommitWhy.relayout != 0, "\(CommitWhy.names(rt.commitWhy))")
        #expect(rt.commitWhy & CommitWhy.input == 0)
    }

    @Test("frame.rs:370 - settle_all sets settle and dirty: the frame commits for both")
    func settleAllCommitsForSettleAndDirty() {
        let rt = makeApp()
        settled(rt)
        rt.settleAll()
        _ = rt.frame(at: 2.0 / 60.0)
        let want = CommitWhy.settle | CommitWhy.dirty
        #expect(rt.commitWhy & want == want, "\(CommitWhy.names(rt.commitWhy))")
        #expect(rt.commitWhy & CommitWhy.input == 0)
    }

    @Test("commit_for: a host's settling update commits for `settle` and `dirty`")
    func settlingUpdateCommitsForSettle() {
        let rt = makeApp()
        settled(rt)
        rt.markNeedsCommit(settle: true)
        _ = rt.frame(at: 2.0 / 60.0)
        let want = CommitWhy.settle | CommitWhy.dirty
        #expect(rt.commitWhy & want == want, "\(CommitWhy.names(rt.commitWhy))")
    }

    @Test("commit_for: a system setting marks the state dirty")
    func systemSettingCommitsForDirty() {
        let rt = makeApp()
        settled(rt)
        rt.systemDark.toggle()
        _ = rt.frame(at: 2.0 / 60.0)
        #expect(rt.commitWhy & CommitWhy.dirty != 0, "\(CommitWhy.names(rt.commitWhy))")
    }

    @Test("apply.rs: an instant commit after the first records `instant`")
    func instantCommitRecordsInstant() {
        let rt = makeApp()
        settled(rt)
        rt.update(at: 2.0 / 60.0) { s, tx in
            s.wide = true
            tx.instant()
        }
        _ = rt.frame(at: 2.0 / 60.0)
        #expect(rt.commitWhy & CommitWhy.instant != 0, "\(CommitWhy.names(rt.commitWhy))")
        rt.commitWhy = 0
        rt.update(at: 3.0 / 60.0) { s, _ in s.wide = false }
        _ = rt.frame(at: 3.0 / 60.0)
        #expect(rt.commitWhy & CommitWhy.instant == 0, "an animated commit isn't instant")
        #expect(rt.commitWhy != 0)
    }

    @Test("commit_for: a key routed past a pending commit commits for `route` first")
    func keyRoutedPastPendingCommitCommitsForRoute() {
        let rt = makeApp()
        settled(rt)
        rt.markNeedsCommit()
        let commits = rt.commitCount
        _ = rt.keyDown(KeyEvent(key: .arrowRight), at: 2.0 / 60.0)
        #expect(rt.commitCount == commits + 1, "the key sees the committed tree")
        #expect(rt.commitWhy & CommitWhy.route != 0, "\(CommitWhy.names(rt.commitWhy))")
        #expect(rt.commitWhy & CommitWhy.dirty != 0)
    }

    @Test("frame.rs:559 - IME and paste route past a pending commit too")
    func otherRoutedEventsCommitForRoute() {
        let routes: [(String, (Runtime<S>, Double) -> Void)] = [
            ("ime", { rt, t in _ = rt.ime(.commit("x"), at: t) }),
            ("paste", { rt, t in rt.paste(ClipboardContent("x"), at: t) }),
        ]
        for (name, route) in routes {
            let rt = makeApp()
            settled(rt)
            rt.markNeedsCommit()
            let commits = rt.commitCount
            route(rt, 2.0 / 60.0)
            #expect(rt.commitCount >= commits + 1, "\(name): the event sees the committed tree")
            #expect(rt.commitWhy & CommitWhy.route != 0, "\(name): \(CommitWhy.names(rt.commitWhy))")
        }
    }

    @Test("frame.rs:563 - the route commit waits for a handler, a poll or dirty state; a relayout alone waits for the frame")
    func routeCommitNeedsRanOrDirty() {
        let rt = makeApp()
        settled(rt)
        rt.viewport = Vec2(300, 200)
        let commits = rt.commitCount
        _ = rt.keyDown(KeyEvent(key: .arrowRight), at: 2.0 / 60.0)
        #expect(rt.commitCount == commits, "a pending relayout doesn't commit before the key")
        #expect(rt.commitWhy == 0)
        _ = rt.frame(at: 2.0 / 60.0)
        #expect(rt.commitCount > commits)
        #expect(rt.commitWhy & CommitWhy.relayout != 0, "\(CommitWhy.names(rt.commitWhy))")
        #expect(rt.commitWhy & CommitWhy.route == 0)
    }

    @Test("drop.rs:139 - a file step doesn't commit before it routes")
    func fileStepsDontTakeRouteCommit() {
        let urls = [URL(fileURLWithPath: "/tmp/a.txt")]
        let steps: [(String, (Runtime<S>, Double) -> Void)] = [
            ("drag", { rt, t in rt.dragFiles(urls, at: Vec2(10, 10), at: t) }),
            ("drop", { rt, t in _ = rt.dropFiles(urls, at: Vec2(10, 10), at: t) }),
            ("leave", { rt, t in rt.dragFilesLeave(at: t) }),
        ]
        for (name, step) in steps {
            let rt = makeApp()
            settled(rt)
            rt.markNeedsCommit()
            let commits = rt.commitCount
            step(rt, 2.0 / 60.0)
            #expect(rt.commitCount == commits, "\(name)")
            #expect(rt.commitWhy & CommitWhy.route == 0, "\(name): \(CommitWhy.names(rt.commitWhy))")
        }
    }

    /// Runs `body` with every commit's cause recorded; each `commit_for` has at least one bit
    /// (frame.rs:638-660 commits only for `other || ran_layout || read_moved`).
    private func causes(_ body: () -> Void) -> [UInt16] {
        let hook = CommitBudget.TestHook(budgetMs: 60_000)
        CommitBudget.$testHook.withValue(hook) { body() }
        #expect(hook.lines.isEmpty)
        return hook.causes
    }

    @Test("titlebar.rs:225 - set_caption commits for `dirty`")
    func setCaptionCommitsForDirty() {
        let rt = makeApp()
        settled(rt)
        let got = causes {
            rt.setCaption(TitlebarCaption(height: 28.0))
            _ = rt.frame(at: 2.0 / 60.0)
        }
        #expect(!got.isEmpty)
        #expect(got.allSatisfy { $0 != 0 }, "\(got.map(CommitWhy.names))")
        #expect(got.contains { $0 & CommitWhy.dirty != 0 }, "\(got.map(CommitWhy.names))")
    }

    private struct Feed {
        var atBottom: [Bool] = []
        var far: [Bool] = []
    }

    @Test("action.rs:87-90 - at-bottom and far-from-bottom handlers aren't input: they commit for `dirty`")
    func scrollEdgeHandlersCommitForDirty() {
        let rt = Runtime<Feed>(state: Feed(), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            col().key("scroll").size(200, 100).scrollY(stickBottom: false)
                .onAtBottom { s, at in s.atBottom.append(at) }
                .onFarFromBottom(50) { s, far in s.far.append(far) }
                .children((0..<20).map { i in el().key("item-\(i)").size(200, 30) })
        }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 1.0 / 60.0)
        rt.commitWhy = 0
        let got = causes {
            rt.update(at: 2.0 / 60.0) { _, tx in tx.scrollToBottomInstant("scroll") }
            for i in 2..<8 { _ = rt.frame(at: Double(i) / 60.0) }
            rt.update(at: 8.0 / 60.0) { _, tx in tx.scrollTo("scroll", x: 0, y: 0) }
            for i in 8..<40 { _ = rt.frame(at: Double(i) / 60.0) }
        }
        #expect(rt.state.atBottom.last == false, "\(rt.state.atBottom)")
        #expect(rt.state.far.contains(false) && rt.state.far.last == true, "\(rt.state.far)")
        #expect(!got.isEmpty)
        #expect(got.allSatisfy { $0 != 0 }, "\(got.map(CommitWhy.names))")
        #expect(got.contains { $0 & CommitWhy.dirty != 0 }, "\(got.map(CommitWhy.names))")
        #expect(got.allSatisfy { $0 & CommitWhy.input == 0 }, "nothing here is input: \(got.map(CommitWhy.names))")
    }

    @Test("a scroll read commits without a dirty cause when scroll-end handlers return false")
    func scrollEndReportsCanDeclineDirtyDuringRead() {
        let rt = Runtime<Feed>(state: Feed(), viewport: Vec2(200, 100), pixelScale: 1.0) { _, cx in
            _ = cx.scrollOffset(of: "scroll")
            return col().key("scroll").size(200, 100).scrollY(stickBottom: false)
                .onAtBottomIf { s, at in s.atBottom.append(at); return false }
                .onFarFromBottomIf(50) { s, far in s.far.append(far); return false }
                .child(el().size(200, 400).shrink(0))
        }
        _ = rt.frame(at: 0)
        _ = rt.frame(at: 1.0 / 60.0)
        let got = causes {
            rt.wheel(WheelEvent(dx: 0, dy: -400), at: Vec2(50, 50), now: 0.03)
            _ = rt.frame(at: 0.04)
            _ = rt.frame(at: 0.05)
        }
        #expect(rt.state.atBottom == [false, true])
        #expect(rt.state.far == [true, false])
        #expect(got.contains { $0 & CommitWhy.read != 0 })
        #expect(got.allSatisfy { $0 & CommitWhy.dirty == 0 }, "\(got.map(CommitWhy.names))")
    }

    private struct Fields {
        var a = TextEdit("")
        var b = TextEdit("")
    }

    @Test("frame.rs:559 - finishing a preedit on a focus move commits for `input`; a caret the view reads commits for a cause")
    func preeditFinishAndCaretReadCommitForACause() {
        let rt = Runtime<Fields>(state: Fields(), viewport: Vec2(200, 120), pixelScale: 1.0) { _, cx in
            let caretX = cx.caret("a").map { $0[0] } ?? 0
            return col()
                .child(textInput(key: "a", \Fields.a).w(180).h(40))
                .child(textInput(key: "b", \Fields.b).w(180).h(40))
                .child(el().key("marker").w(max(1, caretX)).h(4))
        }
        _ = rt.frame(at: 0.0)
        rt.pointerDown(at: Vec2(20, 20), at: 0.016)
        rt.pointerUp(at: Vec2(20, 20), at: 0.020)
        _ = rt.frame(at: 0.032)
        rt.commitWhy = 0
        let got = causes {
            _ = rt.ime(.commit("hello"), at: 0.048)
            _ = rt.frame(at: 0.064)
            _ = rt.frame(at: 0.080)
            _ = rt.ime(.preedit(ImePreedit(text: "か", cursorUTF8: 0..<3)), at: 0.096)
            _ = rt.frame(at: 0.112)
            rt.pointerDown(at: Vec2(20, 60), at: 0.128)
            rt.pointerUp(at: Vec2(20, 60), at: 0.130)
            _ = rt.frame(at: 0.144)
            _ = rt.frame(at: 0.160)
        }
        #expect(rt.state.a.text == "helloか", "\(rt.state.a.text)")
        #expect(!got.isEmpty)
        #expect(got.allSatisfy { $0 != 0 }, "\(got.map(CommitWhy.names))")
        #expect(got.contains { $0 & CommitWhy.input != 0 }, "\(got.map(CommitWhy.names))")
    }

    @Test("frame.rs:638 - the frame commits of the cause tests above all name a cause")
    func everyFrameCommitNamesACause() {
        let rt = makeApp()
        settled(rt)
        let got = causes {
            rt.viewport = Vec2(300, 200)
            _ = rt.frame(at: 2.0 / 60.0)
            rt.settleAll()
            _ = rt.frame(at: 3.0 / 60.0)
            rt.systemDark.toggle()
            _ = rt.frame(at: 4.0 / 60.0)
            rt.update(at: 5.0 / 60.0) { s, tx in s.wide = true; tx.instant() }
            _ = rt.frame(at: 5.0 / 60.0)
            let c = rt.find("box")!
            rt.pointerDown(at: c, at: 6.0 / 60.0)
            rt.pointerUp(at: c, at: 6.0 / 60.0)
            _ = rt.frame(at: 6.0 / 60.0)
            rt.poll = { st, _, _ in st.n += 1; return true }
            _ = rt.frame(at: 7.0 / 60.0)
            rt.poll = nil
            rt.markNeedsCommit()
            _ = rt.keyDown(KeyEvent(key: .arrowRight), at: 8.0 / 60.0)
            for i in 8..<14 { _ = rt.frame(at: Double(i) / 60.0) }
        }
        #expect(got.count >= 7, "\(got.map(CommitWhy.names))")
        #expect(got.allSatisfy { $0 != 0 }, "\(got.map(CommitWhy.names))")
    }

    @Test("watch.rs: a commit outside commit_for isn't counted by interaction timing and names no budget cause")
    func commitOutsideWatchIsUncounted() {
        let rt = makeApp()
        settled(rt)
        let hook = CommitBudget.TestHook(budgetMs: 0.000_001)
        CommitBudget.$testHook.withValue(hook) {
            rt.markNeedsCommit()
            rt.commitOutsideWatch(at: 2.0 / 60.0, cut: false)
        }
        #expect(hook.lines.count == 1)
        #expect(!(hook.lines.first ?? "").contains("committed for"), "\(hook.lines)")
        #expect(rt.commitWhy & CommitWhy.dirty != 0, "the frame log keeps what the commit answered")
        #expect(rt.commitWhyPending == 0)
    }

    @Test("commit_for: an on_layout handler's change commits for `layout`")
    func layoutHandlerCommitsForLayout() {
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            el().size(200, 200)
                .child(el().key("box").w(s.wide ? 120 : 60).h(40).onLayout { st, r in st.laid = r })
                .child(text("\(s.laid.count > 2 ? s.laid[2] : 0)"))
        }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 1.0 / 60.0)
        _ = rt.frame(at: 2.0 / 60.0)
        rt.commitWhy = 0
        rt.update(at: 3.0 / 60.0) { s, tx in
            s.wide = true
            tx.instant()
        }
        var why: UInt16 = 0
        for i in 3..<8 {
            _ = rt.frame(at: Double(i) / 60.0)
            why |= rt.commitWhy
            rt.commitWhy = 0
        }
        #expect(why & CommitWhy.layout != 0, "\(CommitWhy.names(why))")
        #expect(rt.state.laid.count > 2 && rt.state.laid[2] == 120)
    }

    @Test("commit_for: a commit without a cause records nothing")
    func idleFrameRecordsNothing() {
        let rt = makeApp()
        settled(rt)
        let commits = rt.commitCount
        _ = rt.frame(at: 2.0 / 60.0)
        _ = rt.frame(at: 3.0 / 60.0)
        #expect(rt.commitCount == commits)
        #expect(rt.commitWhy == 0)
    }

    // MARK: - interaction/tests.rs:125 (`a_slow_click_names_its_page_and_control`)

    @Test("interaction/tests.rs:125 - a slow click's report counts its commits and their `input` cause")
    func slowClickReportCarriesInputCause() {
        PerfWarn.resetForTesting()
        InteractionTracker.resetForTesting()
        defer {
            InteractionGate.forceOnForTesting = false
            PerfWarn.resetForTesting()
            InteractionTracker.resetForTesting()
        }
        InteractionGate.forceOnForTesting = true
        let rt = makeApp()
        _ = rt.frame(at: 0.0)
        rt.interactionPresented(slowMs: 5000.0, overloaded: false)
        let c = rt.find("box")!
        rt.pointerDown(at: c, at: 0.016)
        rt.pointerUp(at: c, at: 0.020)
        _ = rt.frame(at: 0.032)
        rt.interactionPresented(submittedNs: DispatchTime.now().uptimeNanoseconds + 50_000_000, slowMs: 5.0, overloaded: false)
        #expect(rt.state.n == 1)
        #expect(InteractionTracker.testSlowReports.count == 1)
        guard let s = InteractionTracker.testSlowReports.first else { return }
        #expect(s.action == "on_press")
        #expect(s.commits >= 1 && s.why & CommitWhy.input != 0, "\(CommitWhy.names(s.why))")
    }

    // MARK: - perf_warn/budget.rs (`RUNE_COMMIT_BUDGET_MS`)

    @Test("budget.rs: a commit over budget prints one line naming its cause, then one a second")
    func overBudgetCommitPrintsRateLimitedLine() {
        let rt = makeApp()
        settled(rt)
        let hook = CommitBudget.TestHook(budgetMs: 0.000_001)
        CommitBudget.$testHook.withValue(hook) {
            #expect(CommitBudget.isOn)
            rt.poll = { st, _, _ in st.n += 1; return true }
            _ = rt.frame(at: 2.0 / 60.0)
            #expect(hook.lines.count == 1)
            let first = hook.lines.first ?? ""
            #expect(first.hasPrefix("rune: commit took "), "\(first)")
            #expect(first.contains(", over RUNE_COMMIT_BUDGET_MS=0.000001: view "), "\(first)")
            #expect(first.contains("; committed for poll"), "\(first)")
            #expect(!first.contains("more over budget"), "\(first)")

            // Within a second: left out, and counted.
            _ = rt.frame(at: 3.0 / 60.0)
            _ = rt.frame(at: 4.0 / 60.0)
            #expect(hook.lines.count == 1)

            hook.advanceClock(byMs: 1_100)
            _ = rt.frame(at: 5.0 / 60.0)
            #expect(hook.lines.count == 2)
            let second = hook.lines.last ?? ""
            #expect(second.hasSuffix(" (2 more over budget since the last line)"), "\(second)")
            rt.poll = nil
        }
        #expect(hook.lines.count == 2, "the budget is off outside the hook")
    }

    @Test("budget.rs: a commit within budget prints nothing; a commit outside a frame's checks names no cause")
    func withinBudgetPrintsNothing() {
        let rt = makeApp()
        settled(rt)
        let roomy = CommitBudget.TestHook(budgetMs: 60_000)
        CommitBudget.$testHook.withValue(roomy) {
            rt.update(at: 2.0 / 60.0) { s, _ in s.n += 1 }
            _ = rt.frame(at: 2.0 / 60.0)
        }
        #expect(roomy.lines.isEmpty)

        let tight = CommitBudget.TestHook(budgetMs: 0.000_001)
        CommitBudget.$testHook.withValue(tight) {
            let budget = CommitBudget.Commit.start()
            budget.end(why: 0)
        }
        #expect(tight.lines.count == 1)
        #expect(!(tight.lines.first ?? "").contains("committed for"), "\(tight.lines)")
    }

    @Test("budget.rs: the budget prints as Rust's f64 Display does (no exponent, no rounding, no `.0`)")
    func budgetPrintsAsRustDisplay() {
        let cases: [(Double, String)] = [
            (8.0, "8"), (8.5, "8.5"), (0.000_001, "0.000001"), (12.3456789, "12.3456789"),
            (0.1, "0.1"), (0.0001, "0.0001"), (1e20, "100000000000000000000"), (1.5e-7, "0.00000015"),
            (123_456_789.125, "123456789.125"), (16.7, "16.7"), (1.0 / 3.0, "0.3333333333333333"),
            (0.0, "0"), (-2.5, "-2.5"), (.infinity, "inf"),
        ]
        for (value, want) in cases {
            #expect(CommitBudget.rustDisplay(value) == want, "\(value)")
        }
        let line = CommitBudget.report(totalMs: 20.0, budgetMs: 12.3456789, phases: [0, 0, 0, 0, 0, 0], why: 0, leftOut: 0)
        #expect(line == "rune: commit took 20.0 ms, over RUNE_COMMIT_BUDGET_MS=12.3456789: view 0.0, layout 0.0 (text 0.0), apply 0.0 ms")
    }

    @Test("budget.rs: a commit inside another counts toward the outer one")
    func nestedCommitCountsTowardOuter() {
        let hook = CommitBudget.TestHook(budgetMs: 0.000_001)
        CommitBudget.$testHook.withValue(hook) {
            let outer = CommitBudget.Commit.start()
            CommitBudget.add(.view, ms: 2.0)
            let inner = CommitBudget.Commit.start()
            CommitBudget.add(.apply, ms: 1.0)
            inner.end(why: CommitWhy.layout)
            #expect(hook.lines.isEmpty, "only the outer commit reports")
            outer.end(why: CommitWhy.input)
        }
        #expect(hook.lines.count == 1)
        let line = hook.lines.first ?? ""
        #expect(line.contains("view 2.0, layout 0.0 (text 0.0), apply 1.0 ms"), "\(line)")
        #expect(line.contains("; committed for input"), "\(line)")
    }
}
