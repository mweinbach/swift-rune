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
}
