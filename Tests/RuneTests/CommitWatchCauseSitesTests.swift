import Foundation
import Testing
@testable import Rune

/// `runtime/commit/watch.rs`'s causes at the commit sites where Swift dispatches input at once
/// rather than queueing it (`frame.rs`: `why |= if input { INPUT } else { DIRTY }`, with
/// `Queued::input` from `ActionQueue::push`, action.rs:83-92), the routed `FinishIme`
/// (frame.rs:573), and file steps on a stale tree (`drop.rs`'s `hold_files`, frame.rs:555).
@Suite(.serialized)
struct CommitWatchCauseSitesTests {
    /// Runs `body` with every outer commit's cause recorded (`commit_for`'s `watch.cause`).
    private func causes(_ body: () -> Void) -> [UInt16] {
        let hook = CommitBudget.TestHook(budgetMs: 60_000)
        CommitBudget.$testHook.withValue(hook) { body() }
        #expect(hook.lines.isEmpty)
        return hook.causes
    }

    // MARK: - FinishIme (frame.rs:573 routed; action.rs:89 not input)

    private struct Field {
        var edit = TextEdit("committed")
        var other = 0
    }

    @Test("focus.rs:787 + frame.rs:573 - a window blur's finished composition routes past a pending change and commits for `dirty`")
    func finishCompositionRoutesAndCommitsForDirty() {
        let rt = Runtime<Field>(state: Field(), viewport: Vec2(200, 80), pixelScale: 1.0) { s, _ in
            col().size(200, 80)
                .child(textInput(key: "field", \Field.edit).w(200).h(40))
                .child(text("\(s.other)").key("other"))
        }
        _ = rt.frame(at: 0.0)
        // Focus from the keyboard leaves the caret after the text, as the upstream test's field has it.
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.010)
        _ = rt.frame(at: 0.016)
        #expect(rt.focusedKey == "field")
        _ = rt.ime(.preedit(ImePreedit(text: "pending", cursorUTF8: 0..<7)), at: 0.020)
        _ = rt.frame(at: 0.032)
        rt.imeReset = false
        rt.update(at: 0.040) { s, _ in s.other += 1 }
        let commits = rt.commitCount
        rt.commitWhy = 0
        var routed: UInt16 = 0
        let got = causes {
            rt.finishComposition(at: 0.048)
            #expect(rt.commitCount == commits + 1, "the update commits before the composition finishes")
            routed = rt.commitWhy
            rt.commitWhy = 0
            _ = rt.frame(at: 0.064)
        }
        #expect(routed & CommitWhy.route != 0, "\(CommitWhy.names(routed))")
        #expect(routed & CommitWhy.dirty != 0, "\(CommitWhy.names(routed))")
        #expect(rt.state.edit.preedit == nil && rt.focusedKey == "field" && rt.imeReset)
        #expect(rt.state.edit.text == "committedpending", "\(rt.state.edit.text)")
        #expect(got.count >= 2, "\(got.map(CommitWhy.names))")
        #expect(got.allSatisfy { $0 != 0 }, "\(got.map(CommitWhy.names))")
        let finished = got.dropFirst()
        #expect(finished.contains { $0 & CommitWhy.dirty != 0 }, "\(got.map(CommitWhy.names))")
        #expect(finished.allSatisfy { $0 & CommitWhy.input == 0 }, "FinishIme isn't input: \(got.map(CommitWhy.names))")
    }

    private struct Two {
        var a = TextEdit("x")
        var b = TextEdit("")
        var showsB = false
    }

    @Test("native IME commits a dirty tree and routes typed text to the newly mounted field")
    func nativeImeRoutesToTheNewlyMountedField() {
        let rt = Runtime<Two>(state: Two(), viewport: Vec2(200, 120), pixelScale: 1.0) { state, _ in
            var root = col().child(textInput(key: "a", \Two.a).w(180).h(40))
            if state.showsB { root = root.child(textInput(key: "b", \Two.b).w(180).h(40)) }
            return root
        }
        _ = rt.frame(at: 0)
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.01)
        _ = rt.frame(at: 0.02)
        #expect(rt.focusedKey == "a")
        rt.update(at: 0.03) { state, tx in
            state.showsB = true
            tx.focusWhenShown("b", ring: false)
        }
        rt.commitWhy = 0
        #expect(rt.dispatchImeEvent(.commit("z"), at: 0.04))
        #expect(rt.commitWhy & CommitWhy.route != 0)
        #expect(rt.state.a.text == "x" && rt.state.b.text == "z")
    }

    @Test("a physical focus loss without an input timestamp commits a changed handler for dirty", arguments: [false, true])
    func physicalFocusLostIsAnObserver(windowBlur: Bool) {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(100, 80), pixelScale: 1) { _, _ in
            el().key("field").size(100, 80).focusable()
                .onPhysicalInput { state, event, _ in
                    guard event == .focusLost else { return false }
                    state += 1
                    return true
                }
        }
        _ = rt.frame(at: 0)
        rt.update(at: 0.01) { _, tx in tx.focus("field") }
        _ = rt.frame(at: 0.02)
        let got = causes {
            if windowBlur { rt.windowFocus(false, at: 0.03) }
            else { _ = rt.physicalWithFallback(.focusLost, fallbackKey: nil, at: 0.03) }
            _ = rt.frame(at: 0.04)
        }
        #expect(rt.state == 1)
        #expect(got.contains { $0 & CommitWhy.dirty != 0 })
        #expect(got.allSatisfy { $0 & CommitWhy.input == 0 })
    }

    @Test("a physical focus loss observes the window's finished composition")
    func blurFinishesImeBeforePhysicalFocusLost() {
        struct Field {
            var edit = TextEdit("")
            var observed: String?
            var sawOpenCompositionOnBlur = false
        }
        let rt = Runtime<Field>(state: Field(), viewport: Vec2(100, 80), pixelScale: 1) { _, _ in
            textInput(key: "field", \Field.edit).size(100, 80)
                .onWindowFocus { state, focused, _ in
                    if !focused { state.sawOpenCompositionOnBlur = state.edit.preedit != nil }
                }
                .onPhysicalInput { state, event, _ in
                    guard event == .focusLost else { return false }
                    state.observed = state.edit.preedit == nil ? state.edit.text : nil
                    return true
                }
        }
        _ = rt.frame(at: 0)
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.01)
        _ = rt.frame(at: 0.02)
        _ = rt.ime(.preedit(ImePreedit(text: "x", cursorUTF8: 0..<1)), at: 0.03)
        _ = rt.frame(at: 0.04)
        #expect(rt.state.edit.preedit != nil)
        let got = causes {
            rt.windowFocus(false, at: 0.05)
            _ = rt.frame(at: 0.06)
        }
        #expect(rt.state.sawOpenCompositionOnBlur)
        #expect(rt.state.observed == "x")
        #expect(got.contains { $0 & CommitWhy.dirty != 0 })
        #expect(got.allSatisfy { $0 & CommitWhy.input == 0 })
    }

    @Test("focus.rs:247-255 - a composition a commit's focus move finishes commits for `dirty`, not `input`")
    func commitFocusMoveFinishesCompositionForDirty() {
        let rt = Runtime<Two>(state: Two(), viewport: Vec2(200, 120), pixelScale: 1.0) { _, _ in
            col()
                .child(textInput(key: "a", \Two.a).w(180).h(40))
                .child(textInput(key: "b", \Two.b).w(180).h(40))
        }
        _ = rt.frame(at: 0.0)
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.010)
        _ = rt.frame(at: 0.016)
        #expect(rt.focusedKey == "a")
        _ = rt.ime(.preedit(ImePreedit(text: "yz", cursorUTF8: 0..<2)), at: 0.020)
        _ = rt.frame(at: 0.032)
        let got = causes {
            rt.update(at: 0.040) { _, tx in tx.focus("b") }
            for i in 0..<3 { _ = rt.frame(at: 0.048 + Double(i) * 0.016) }
        }
        #expect(rt.focusedKey == "b")
        #expect(rt.state.a.text == "xyz" && rt.state.a.preedit == nil, "\(rt.state.a.text)")
        #expect(!got.isEmpty && got.allSatisfy { $0 != 0 }, "\(got.map(CommitWhy.names))")
        #expect(got.allSatisfy { $0 & CommitWhy.input == 0 }, "no input moved the focus: \(got.map(CommitWhy.names))")
    }

    // MARK: - Input that runs handlers outside applyTx: links, field menu, file steps

    private struct Clicks {
        var links: [String] = []
        var dropped: [String] = []
        var hovered: [Bool] = []
        var edit = TextEdit("hello")
    }

    private func clicksApp() -> Runtime<Clicks> {
        Runtime<Clicks>(state: Clicks(), viewport: Vec2(300, 200), pixelScale: 1.0) { _, _ in
            col().size(300, 200)
                .child(text("Click link here").key("lnk").size(200, 24)
                    .link(TextLink(6..<10, id: "docs", label: "Docs"))
                    .onLink { (s: inout Clicks, id: String, _: inout Tx) in s.links.append(id) })
                .child(textInput(key: "field", \Clicks.edit).w(200).h(40))
                .child(el().key("zone").size(200, 80)
                    .onDropHover { s, over, _ in s.hovered.append(over) }
                    .onDropFiles { s, urls, _ in s.dropped += urls.map(\.lastPathComponent) })
        }
    }

    @Test("frame.rs:121 - a link's press and click, a field's menu and a file drop commit for `input`, not `dirty`")
    func inputSitesCommitForInput() throws {
        let rt = clicksApp()
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 1.0 / 60.0)
        let link = try #require(rt.linkBoxesByPath.values.flatMap { $0 }.first { $0.link.id == "docs" }).windowUnion
        let linkAt = Vec2(link.x + link.z * 0.5, link.y + link.w * 0.5)
        let field = try #require(rt.element(byKey: "field")).rect
        let fieldAt = Vec2(field[0] + 20, field[1] + 20)
        let zone = try #require(rt.element(byKey: "zone")).rect
        let zoneAt = Vec2(zone[0] + 20, zone[1] + 20)
        let file = [URL(fileURLWithPath: "/tmp/a.txt")]

        let sites: [(String, (Double) -> Void)] = [
            ("link", { t in
                rt.pointerDown(at: linkAt, at: t)
                rt.pointerUp(at: linkAt, at: t + 0.002)
            }),
            ("field menu", { t in
                rt.secondaryDown(at: fieldAt, at: t)
                rt.secondaryUp(at: fieldAt, mods: .none, at: t + 0.002)
            }),
            ("drag", { t in rt.dragFiles(file, at: zoneAt, at: t) }),
            ("drop", { t in _ = rt.dropFiles(file, at: zoneAt, at: t) }),
        ]
        var t = 2.0 / 60.0
        for (name, site) in sites {
            let got = causes {
                site(t)
                _ = rt.frame(at: t + 1.0 / 60.0)
            }
            t += 3.0 / 60.0
            _ = rt.frame(at: t - 1.0 / 60.0)
            _ = rt.takePopup()
            #expect(!got.isEmpty, "\(name) commits")
            #expect(got.allSatisfy { $0 != 0 }, "\(name): \(got.map(CommitWhy.names))")
            #expect(got.contains { $0 & CommitWhy.input != 0 }, "\(name): \(got.map(CommitWhy.names))")
            #expect(got.allSatisfy { $0 & CommitWhy.dirty == 0 }, "\(name) is input: \(got.map(CommitWhy.names))")
        }
        #expect(rt.state.links == ["docs"], "\(rt.state.links) \(link)")
        #expect(rt.state.hovered == [true, false])
        #expect(rt.state.dropped == ["a.txt"])
    }

    // MARK: - drop.rs:134-146 hold_files / release_files

    private struct Drops {
        var noInner = false
        var dropped: [String] = []
        var hover: [String] = []
    }

    /// An outer zone around an inner one at (10, 10, 100, 100); both take any file.
    private func dropsApp() -> Runtime<Drops> {
        Runtime<Drops>(state: Drops(), viewport: Vec2(300, 200), pixelScale: 1.0) { s, _ in
            El<Drops>().w(300).h(200).child(
                El<Drops>().key("outer").absolute(x: 0, y: 0).w(200).h(200)
                    .onDropHover { st, over, _ in st.hover.append("outer \(over)") }
                    .onDropFiles { st, urls, _ in st.dropped += urls.map { "outer \($0.lastPathComponent)" } }
                    .children(s.noInner ? [] : [
                        El<Drops>().key("inner").absolute(x: 10, y: 10).w(100).h(100)
                            .onDropHover { st, over, _ in st.hover.append("inner \(over)") }
                            .onDropFiles { st, urls, _ in st.dropped += urls.map { "inner \($0.lastPathComponent)" } },
                    ])
            )
        }
    }

    private let png = [URL(fileURLWithPath: "/tmp/a.png")]

    @Test("drop.rs:134 - a file step reaching a tree changed since its last build waits for the frame's build")
    func aStaleTreeHoldsAFileStepForTheBuild() {
        let rt = dropsApp()
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.01) { s, _ in s.noInner = true }
        rt.dragFiles(png, at: Vec2(50, 50), at: 0.02)
        #expect(rt.state.hover.isEmpty, "the inner zone is gone in state; the step waits")
        #expect(rt.hasPendingInput, "so the host draws a frame")
        #expect(rt.fileStepsHeld)
        _ = rt.frame(at: 0.03)
        #expect(rt.state.hover == ["outer true"], "\(rt.state.hover)")
        #expect(rt.dropHovered == "outer")
        #expect(!rt.fileStepsHeld)
    }

    @Test("drop.rs:139 - the steps after a held one wait behind it, and a step waits only once")
    func heldStepsKeepTheirOrderAndWaitOnce() {
        let rt = dropsApp()
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.01) { s, _ in s.noInner = true }
        rt.dragFiles(png, at: Vec2(50, 50), at: 0.02)
        rt.dragFilesLeave(at: 0.021)
        rt.dragFiles(png, at: Vec2(60, 60), at: 0.022)
        // Replayed once the frame has built, they run in order and none waits a second time.
        _ = rt.dropFiles(png, at: Vec2(60, 60), at: 0.023)
        #expect(rt.state.hover.isEmpty && rt.state.dropped.isEmpty)
        _ = rt.frame(at: 0.03)
        #expect(rt.state.hover == ["outer true", "outer false", "outer true", "outer false"], "\(rt.state.hover)")
        #expect(rt.state.dropped == ["outer a.png"], "\(rt.state.dropped)")
        #expect(!rt.isDraggingFiles)
    }

    @Test("drop.rs:141 - a tree built since its last change, or a lone leave, takes the step at once")
    func aFreshTreeTakesTheStepAtOnce() {
        let rt = dropsApp()
        _ = rt.frame(at: 0.0)
        rt.dragFiles(png, at: Vec2(50, 50), at: 0.01)
        #expect(rt.state.hover == ["inner true"])
        #expect(!rt.fileStepsHeld)
        _ = rt.frame(at: 0.02)
        rt.update(at: 0.03) { s, _ in s.dropped.append("note") }
        rt.dragFilesLeave(at: 0.04)
        #expect(rt.state.hover == ["inner true", "inner false"], "a leave aims at nothing: \(rt.state.hover)")
        #expect(!rt.fileStepsHeld)
    }
    // MARK: - Window focus (frame.rs:67-103 `window_focus`)

    private struct Plain { var n = 0 }

    private func plainApp() -> Runtime<Plain> {
        Runtime<Plain>(state: Plain(), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            col().size(200, 200)
                .child(el().key("box").size(60, 40).onClick { st in st.n += 1 })
                .child(text("\(s.n)").key("count"))
        }
    }

    @Test("frame.rs:77-92 - a focus change nothing shows or hears commits nothing and leaves no cause")
    func plainFocusChangeCommitsNothing() {
        let rt = plainApp()
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 1.0 / 60.0)
        rt.commitWhy = 0
        let commits = rt.commitCount
        let got = causes {
            rt.dispatchFocus(false, at: 2.0 / 60.0)
            #expect(rt.commitCount == commits, "the blur's FinishIme has nothing ran or dirty to route past")
            #expect(!rt.needsCommit && rt.commitWhyPending == 0, "\(CommitWhy.names(rt.commitWhyPending))")
            _ = rt.frame(at: 3.0 / 60.0)
            rt.dispatchFocus(true, at: 4.0 / 60.0)
            #expect(!rt.needsCommit && rt.commitWhyPending == 0, "\(CommitWhy.names(rt.commitWhyPending))")
            _ = rt.frame(at: 5.0 / 60.0)
        }
        #expect(got.isEmpty, "\(got.map(CommitWhy.names))")
        #expect(rt.commitCount == commits)
        #expect(rt.commitWhy == 0)

        // No stale cause turns a relayout into a route commit (frame.rs:563).
        rt.viewport = Vec2(300, 200)
        _ = rt.keyDown(KeyEvent(key: .arrowRight), at: 6.0 / 60.0)
        #expect(rt.commitCount == commits, "a pending relayout doesn't commit before the key")
        #expect(rt.commitWhy == 0, "\(CommitWhy.names(rt.commitWhy))")
        _ = rt.frame(at: 6.0 / 60.0)
        #expect(rt.commitWhy & CommitWhy.relayout != 0, "\(CommitWhy.names(rt.commitWhy))")
        #expect(rt.commitWhy & (CommitWhy.dirty | CommitWhy.route) == 0, "\(CommitWhy.names(rt.commitWhy))")
    }

    private struct Sel { var n = 0 }

    @Test("frame.rs:77-81 - a focus change commits for `dirty` when a selection takes its inactive pair")
    func focusChangeWithSelectionCommitsForDirty() {
        let rt = Runtime<Sel>(state: Sel(), viewport: Vec2(320, 120), pixelScale: 1.0) { _, _ in
            col().w(320).h(120)
                .child(text("painted text").key("t").w(200).h(24).selectable())
        }
        _ = rt.frame(at: 0.0)
        rt.update { _, tx in tx.selectText("t", range: 0..<7) }
        _ = rt.frame(at: 0.05)
        _ = rt.frame(at: 0.06)
        rt.commitWhy = 0
        let commits = rt.commitCount
        let got = causes {
            rt.dispatchFocus(false, at: 0.07)
            _ = rt.frame(at: 0.08)
        }
        #expect(rt.commitCount > commits, "the selection's inactive pair shows")
        #expect(!got.isEmpty && got.allSatisfy { $0 != 0 }, "\(got.map(CommitWhy.names))")
        #expect(got.contains { $0 & CommitWhy.dirty != 0 }, "\(got.map(CommitWhy.names))")
        #expect(got.allSatisfy { $0 & CommitWhy.input == 0 }, "\(got.map(CommitWhy.names))")
    }

    // MARK: - Virtual windows (frame.rs:672 `virtual_window_changed` -> `VIRTUAL`)

    @Test("a pending virtual window shift does not add a cause to an already dirty frame")
    func dirtyFrameConsumesPendingVirtualCause() {
        let rt = plainApp()
        _ = rt.frame(at: 0)
        rt.update(at: 0.01) { state, _ in state.n += 1 }
        rt.commitWhyPending |= CommitWhy.virtual
        let got = causes { _ = rt.frame(at: 0.02) }
        #expect(got.first == CommitWhy.dirty)
        #expect(rt.commitWhyPending == 0)
    }

    private struct V {}

    @Test("frame.rs:672,696 - a scrollKeyTo landing and a nested list placed anew commit for `virtual`")
    func virtualWindowMovesCommitForVirtual() {
        // A virtual list estimating 20pt rows that lay out at 30pt (VirtualNestingParityTests).
        let transcript = Runtime<V>(state: V(), viewport: Vec2(240, 300), pixelScale: 1.0) { _, _ in
            col().key("scroll").size(240, 300).scrollY(stickBottom: false).child(
                col().key("list").w(240).virtualRows(
                    count: 1000, estimatedRowHeight: 20, key: { _, i in "r\(i)" },
                    build: { _, _ in el().size(240, 30) }
                )
            )
        }
        _ = transcript.frame(at: 0)
        _ = transcript.frame(at: 1.0 / 60.0)
        let landed = causes {
            transcript.update(at: 0.02) { _, tx in tx.scrollKeyTo("r600", at: 12) }
            _ = transcript.frame(at: 0.03)
        }
        #expect(transcript.element(byKey: "r600") != nil)
        #expect(landed.count >= 2, "\(landed.map(CommitWhy.names))")
        #expect(landed.allSatisfy { $0 != 0 }, "\(landed.map(CommitWhy.names))")
        #expect(landed.dropFirst().contains { $0 & CommitWhy.virtual != 0 }, "\(landed.map(CommitWhy.names))")

        // A nested list whose section the viewport's end places (VirtualNestingParityTests).
        let timeline = Runtime<V>(state: V(), viewport: Vec2(240, 300), pixelScale: 1.0) { _, _ in
            col().key("scroll").size(240, 300).scrollY(stickBottom: true).child(
                col().key("outer").w(240).virtualRows(
                    count: 5, estimatedRowHeight: 100, key: { _, i in "o\(i)" },
                    build: { _, i in
                        guard i == 2 else { return el().size(240, 100) }
                        return col().w(240)
                            .child(el().key("header").size(240, 4000))
                            .child(col().key("inner").w(240).virtualRows(
                                count: 1000, estimatedRowHeight: 20, key: { _, j in "i\(j)" },
                                build: { _, _ in el().size(240, 20) }
                            ))
                    }
                )
            )
        }
        var t = 0.0
        let placed = causes {
            for _ in 0..<12 {
                _ = timeline.frame(at: t)
                t += 1.0 / 60.0
            }
        }
        #expect(timeline.element(byKey: "i999") != nil)
        #expect(placed.allSatisfy { $0 != 0 }, "\(placed.map(CommitWhy.names))")
        #expect(placed.contains { $0 & CommitWhy.virtual != 0 }, "\(placed.map(CommitWhy.names))")
    }

    private struct Section { var open = false }

    @Test("frame.rs:672 - a list placed somewhere new in its viewport asks the next commit for `virtual`")
    func listPlacedAnewAsksForVirtual() throws {
        let rt = Runtime<Section>(state: Section(open: true), viewport: Vec2(240, 300), pixelScale: 1.0) { s, _ in
            col().key("scroll").size(240, 300).scrollY(stickBottom: false).child(
                col().w(240)
                    .child(el().key("section").size(240, s.open ? 250 : 0))
                    .child(col().key("list").w(240).virtualRows(
                        count: 1000, estimatedRowHeight: 20, key: { _, i in "r\(i)" },
                        build: { _, _ in el().size(240, 20) }
                    ))
            )
        }
        _ = rt.frame(at: 0)
        _ = rt.frame(at: 1.0 / 60.0)
        let listPath = try #require(rt.activeVirtualPaths.first)
        // The last commit placed the list at the content's top (before the section opened above
        // it), and the viewport now stands where that window doesn't reach.
        rt.virtualLists[listPath]?.top = 0
        for path in rt.scrollOffsets.keys { rt.scrollOffsets[path] = Vec2(0, 9000) }
        rt.commitWhyPending = 0
        rt.needsCommit = false
        rt.recordVirtualMeasurementsAndCallbacks(expansion: Runtime<Section>.VirtualExpansionContext(), at: 0.05)
        #expect((rt.virtualLists[listPath]?.top ?? 0) > 200, "placed under the section")
        #expect(rt.needsCommit)
        #expect(rt.commitWhyPending & CommitWhy.virtual != 0, "\(CommitWhy.names(rt.commitWhyPending))")
    }

    @Test("frame.rs:672 - a scrollKeyTo landing that moved a window asks the next commit for `virtual`")
    func scrollKeyLandingAsksForVirtual() {
        let rt = Runtime<V>(state: V(), viewport: Vec2(240, 300), pixelScale: 1.0) { _, _ in
            col().key("scroll").size(240, 300).scrollY(stickBottom: false).child(
                col().key("list").w(240).virtualRows(
                    count: 1000, estimatedRowHeight: 20, key: { _, i in "r\(i)" },
                    build: { _, _ in el().size(240, 30) }
                )
            )
        }
        _ = rt.frame(at: 0)
        _ = rt.frame(at: 1.0 / 60.0)
        // The viewport stands far from the window the last commit built: a window must move.
        for path in rt.scrollOffsets.keys { rt.scrollOffsets[path] = Vec2(0, 9000) }
        #expect(rt.anyVirtualListNeedsWindow())
        let req = ScrollOffsetRequest(key: "r450", y: 0, anchor: true)
        let taken = rt.scrollKeyLandings.take([req])
        rt.scrollKeyLandings.land(taken[0])
        rt.commitWhyPending = 0
        rt.finishScrollKeyLandings(anyVirtualList: true)
        #expect(rt.needsCommit)
        #expect(rt.commitWhyPending & CommitWhy.virtual != 0, "\(CommitWhy.names(rt.commitWhyPending))")
    }

    // MARK: - Poll (frame.rs:530-533)

    @Test("frame.rs:530 - a poll that changed nothing but asked for a commit commits for `dirty`, not `poll`")
    func pollAskingACommitIsntPoll() {
        let rt = plainApp()
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 1.0 / 60.0)
        rt.poll = { _, _, tx in tx.commit(); return false }
        let got = causes { _ = rt.frame(at: 2.0 / 60.0) }
        rt.poll = nil
        #expect(!got.isEmpty && got.allSatisfy { $0 != 0 }, "\(got.map(CommitWhy.names))")
        #expect(got.allSatisfy { $0 & CommitWhy.poll == 0 }, "\(got.map(CommitWhy.names))")
        #expect(got.contains { $0 & CommitWhy.dirty != 0 }, "\(got.map(CommitWhy.names))")
        rt.poll = { st, _, _ in st.n += 1; return true }
        let changed = causes { _ = rt.frame(at: 3.0 / 60.0) }
        rt.poll = nil
        #expect(changed.contains { $0 & CommitWhy.poll != 0 }, "\(changed.map(CommitWhy.names))")
    }
}
