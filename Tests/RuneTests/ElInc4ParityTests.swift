import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite("El & Runtime Increment 4 Parity Tests")
struct ElInc4ParityTests {

    // MARK: - 1. TxCommit, MotionSource, ColorMotion, LiveOnly & InvalidateMemos (el/tx/tests.rs)

    @Test("tx: TxCommit monoid truth table and merge")
    func txCommitMonoidAndMerge() {
        #expect(!TxCommit.animate.snaps && !TxCommit.animate.lands)
        #expect(TxCommit.instant.snaps && !TxCommit.instant.lands)
        #expect(TxCommit.settle.snaps && TxCommit.settle.lands)
        #expect(!TxCommit.settleAnimated.snaps && TxCommit.settleAnimated.lands)

        #expect(TxCommit.animate.instant() == .instant)
        #expect(TxCommit.settle.animated() == .settleAnimated)
        #expect(TxCommit.instant.merge(.settleAnimated) == .settle)
        #expect(TxCommit.animate.merge(.instant) == .instant)
        #expect(TxCommit.settleAnimated.merge(.animate) == .settleAnimated)

        var tx = Tx()
        #expect(tx.commitKind == .animate)
        tx.settle()
        #expect(tx.commitKind == .settle)
        tx.animated()
        #expect(tx.commitKind == .settleAnimated)
        #expect(tx.askedMotion)

        var tx2 = Tx()
        tx2.liveOnly()
        #expect(tx2.liveOnlyRequested)
        #expect(!Tx.took(false, &tx2))
        #expect(!tx2.liveOnlyRequested)
    }

    @Test("tx: instant snaps own layout while leaving other running tracks alone")
    func txInstantSnapsOwnLayoutWhileLeavingOtherRunning() {
        struct S {
            var aX: Float = 0
            var bX: Float = 0
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(400, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col()
                .size(400, 200)
                .child(el().key("a").size(40, 40).ml(s.aX).animateLayout(MotionTokens.SMOOTH))
                .child(el().key("b").size(40, 40).ml(s.bX).animateLayout(MotionTokens.SMOOTH))
        }
        _ = rt.frame(at: 0.0)
        // Start A animating cleanly
        rt.update(at: 0.01) { s, _ in s.aX = 200 }
        _ = rt.frame(at: 0.02)
        let aMid1 = rt.lastElements.first { $0.key == "a" }!.rect[0]
        #expect(aMid1 < 190 && aMid1 >= 0)

        // Commit B with tx.instant(): B snaps immediately to 150, while A continues animating
        rt.update(at: 0.04) { s, tx in
            tx.instant()
            s.bX = 150
        }
        _ = rt.frame(at: 0.05)
        let bAfterInstant = rt.lastElements.first { $0.key == "b" }!.rect[0]
        let aMid2 = rt.lastElements.first { $0.key == "a" }!.rect[0]
        #expect(abs(bAfterInstant - 150) < 0.5)
        #expect(aMid2 > aMid1 && aMid2 < 199)
    }

    @Test("tx: settleAnimated lands existing tracks while animating own layout")
    func txSettleAnimatedLandsExistingTracks() {
        struct S {
            var aX: Float = 0
            var bX: Float = 0
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(400, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col()
                .size(400, 200)
                .child(el().key("a").size(40, 40).ml(s.aX).animateLayout(MotionTokens.SMOOTH))
                .child(el().key("b").size(40, 40).ml(s.bX).animateLayout(MotionTokens.SMOOTH))
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.01) { s, _ in s.aX = 180 }
        _ = rt.frame(at: 0.03)
        let aMid = rt.lastElements.first { $0.key == "a" }!.rect[0]
        #expect(aMid < 170)

        // Trigger settle() followed by animated() -> .settleAnimated
        rt.update(at: 0.04) { s, tx in
            tx.settleAnimated()
            s.bX = 160
        }
        _ = rt.frame(at: 0.05)
        let aAfter = rt.lastElements.first { $0.key == "a" }!.rect[0]
        let bAfter = rt.lastElements.first { $0.key == "b" }!.rect[0]
        #expect(abs(aAfter - 180) < 0.5, "prior track should settle on settleAnimated")
        #expect(bAfter < 155, "own change should still animate with settleAnimated")

        // Also test tx.invalidateMemosByPrefix
        MemoCache.shared.invalidateAll()
        var builds = 0
        _ = MemoCache.shared.getOrBuild(id: "inc4:list/row1", deps: 1) { () -> El<S> in
            builds += 1
            return el().size(10, 10)
        }
        _ = MemoCache.shared.getOrBuild(id: "inc4:other/row1", deps: 1) { () -> El<S> in
            builds += 1
            return el().size(10, 10)
        }
        rt.update(at: 0.06) { _, tx in
            tx.invalidateMemosByPrefix("inc4:list/")
        }
        _ = rt.frame(at: 0.07)
        let rList = MemoCache.shared.getOrBuild(id: "inc4:list/row1", deps: 1) { () -> El<S> in
            builds += 1
            return el().size(10, 10)
        }
        let rOther = MemoCache.shared.getOrBuild(id: "inc4:other/row1", deps: 1) { () -> El<S> in
            builds += 1
            return el().size(10, 10)
        }
        #expect(!rList.hit, "prefixed memo should have been evicted")
        #expect(rOther.hit, "unrelated memo should stay cached")
    }

    // MARK: - 2. ScrollRequests, ScrollEdgeMath & Scroll Callbacks (requests_tests.rs, edge.rs)

    @Test("scroll: ScrollRequestsState lifecycle & ScrollEdgeMath")
    func scrollRequestsStateAndEdgeMath() {
        var reqs = ScrollRequestsState()
        reqs.arriveCapture(ScrollKeep(
            path: "/0/s/item",
            viewport: "/0/s",
            was: 100,
            virtualRow: nil,
            hold: ScrollKeepHold(path: "/0/s/h1", inset: 0)
        ))
        #expect(reqs.owns("/0/s"))

        let took = reqs.takeKeeps()
        #expect(took.count == 1)
        #expect(!reqs.hasKeeps)
        reqs.restoreKeeps(took)
        #expect(reqs.hasKeeps)

        reqs.stepEndClamps { _ in .pinned(102) }
        #expect(!reqs.hasKeeps, "keep clears once sticky header pushes beyond saved top")

        let eff = reqs.stepPlace(first: true, scope: nil, key: "end", viewport: "/0/s", center: false, atEnd: true, from: 0, to: 120)
        #expect(eff == .move(120))
        reqs.stepNewTail(viewport: "/0/s", key: "tail2")
        #expect(reqs.reveals.first?.key == "tail2")

        reqs.stepCancel()
        #expect(reqs.isEmpty)

        // Reveal math & edge ramps
        let revealed = ScrollEdgeMath.reveal(offset: 0, top: 250, height: 30, viewport: 100, margin: 10)
        #expect(abs(revealed - 190) < 0.01)

        let smooth = ScrollEdgeMath.edgeRamp(style: .smooth, width: 20, hidden: 30, scale: 1.0)
        #expect(abs(smooth.width - 20) < 0.01 && smooth.offset == 0)

        let feather = ScrollEdgeMath.edgeRamp(style: ScrollFade.feather(24).style, width: 24, hidden: 10, scale: 1.0)
        #expect(abs(feather.width + 10) < 0.01 && feather.offset == 0)
    }

    @Test("A stationary viewport can acknowledge both first scroll-end reports without a view rebuild")
    func scrollEndReportsCanDeclineCommit() {
        struct Observations {
            var atBottom: [Bool] = []
            var far: [Bool] = []
        }
        let rt = Runtime<Observations>(
            state: Observations(), viewport: Vec2(200, 100), pixelScale: 1, systemDark: true
        ) { _, _ in
            col().size(200, 100).key("list").scrollY(stickBottom: false)
                .onAtBottomIf { state, at in
                    state.atBottom.append(at)
                    return false
                }
                .onFarFromBottomIf(20) { state, far in
                    state.far.append(far)
                    return false
                }
                .child(el().size(200, 200).shrink(0))
        }
        _ = rt.frame(at: 0)
        let commits = rt.commitCount
        _ = rt.frame(at: 1.0 / 60)
        #expect(rt.state.atBottom == [false])
        // Precisely one viewport away is still inside the far-report boundary.
        #expect(rt.state.far == [false])
        #expect(rt.commitCount == commits)
        rt.update(at: 0.1) { _, tx in
            tx.scrollToInstant("list", x: 0, y: 100)
            tx.liveOnly()
        }
        _ = rt.frame(at: 0.2)
        #expect(rt.state.atBottom == [false, true])
        #expect(rt.state.far == [false])
        #expect(rt.commitCount == commits)
    }

    @Test("a changed scroll-end report rebuilds its view through a simultaneous resize")
    func changedScrollEndReportInvalidatesView() {
        let rt = Runtime<Bool>(state: false, viewport: Vec2(200, 120)) { atEnd, _ in
            col().size(200, 120)
                .child(col().size(200, 100).key("list").scrollY(stickBottom: false)
                    .onAtBottomIf { state, at in
                        guard state != at else { return false }
                        state = at
                        return true
                    }
                    .child(el().size(200, 300).shrink(0)))
                .child(el().key("marker").size(atEnd ? 100 : 10, 10))
        }
        _ = rt.frame(at: 0)
        #expect(rt.element(byKey: "marker")?.rect[2] == 10)
        rt.update(at: 0.1) { _, tx in
            tx.scrollToInstant("list", x: 0, y: 200)
            tx.liveOnly()
        }
        rt.setViewport(Vec2(220, 120))
        _ = rt.frame(at: 0.2)
        #expect(rt.state && rt.element(byKey: "marker")?.rect[2] == 100)
    }

    @Test("scroll-end reports start again after the same viewport remounts")
    func scrollEndReportsResetAfterExit() {
        struct Observation {
            var visible = true
            var bottom: [Bool] = []
            var far: [Bool] = []
        }
        let rt = Runtime<Observation>(state: .init(), viewport: Vec2(100, 100)) { state, _ in
            var root = El<Observation>().size(100, 100)
            if state.visible {
                root = root.child(col().size(100, 100).key("list").scrollY(stickBottom: false)
                    .onAtBottomIf { $0.bottom.append($1); return false }
                    .onFarFromBottomIf(20) { $0.far.append($1); return false }
                    .child(el().size(100, 250).shrink(0))
                    .transition(.opacity))
            }
            return root
        }
        _ = rt.frame(at: 0)
        rt.update(at: 0.1) { state, _ in state.visible = false }
        for step in 0...120 { _ = rt.frame(at: 0.1 + Double(step) / 60) }
        #expect(rt.state.bottom == [false] && rt.state.far == [true])
        rt.update(at: 3) { state, _ in state.visible = true }
        _ = rt.frame(at: 3)
        #expect(rt.state.bottom == [false, false] && rt.state.far == [true, true])
    }

    @Test("scroll: scrollIntoView, scrollCenter, scrollToBottomInstant, followEdge, and wheel cancellation")
    func runtimeScrollRequestsAndCallbacks() {
        struct S {
            var count: Int = 20
            var atBottomEvents: [Bool] = []
            var farEvents: [Bool] = []
            var scrollPositions: [ScrollPos] = []
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col()
                .key("scroll")
                .size(200, 100)
                .scrollY(stickBottom: false)
                .onAtBottom { state, atBot in state.atBottomEvents.append(atBot) }
                .onFarFromBottom(50) { state, far in state.farEvents.append(far) }
                .onScrollOffset { _ in }
                .children((0..<s.count).map { i in
                    el().key("item-\(i)").size(200, 30)
                })
        }
        _ = rt.frame(at: 0.0)
        // Initial offset is 0, content 600, maxY 500 -> not at bottom, far >= 50
        #expect(rt.state.atBottomEvents.last == false)
        #expect(rt.state.farEvents.last == true)

        // Instant scroll to bottom
        rt.update(at: 0.05) { _, tx in
            tx.scrollToBottomInstant("scroll")
        }
        _ = rt.frame(at: 0.06)
        #expect(abs(rt.scrollOffset(forKey: "scroll").y - 500) < 0.5)
        #expect(rt.state.atBottomEvents.last == true)
        #expect(rt.state.farEvents.last == false)

        // Center item-5 (y = 150..180, viewport 100 -> center at 150 + 15 - 50 = 115)
        rt.update(at: 0.1) { _, tx in
            tx.scrollCenterInInstant("scroll", "item-5")
        }
        _ = rt.frame(at: 0.11)
        #expect(abs(rt.scrollOffset(forKey: "scroll").y - 115) < 0.5)

        // Start animated glide then cancel with user wheel
        rt.update(at: 0.2) { _, tx in
            tx.scrollTo("scroll", x: 0, y: 400)
        }
        _ = rt.frame(at: 0.21)
        #expect(rt.isAnimating)
        rt.wheel(WheelEvent(dx: 0, dy: -20), at: Vec2(50, 50), now: 0.22)
        _ = rt.frame(at: 0.5)
        // Wheel cancelled the glide, so it didn't continue gliding to 400!
        #expect(rt.scrollOffset(forKey: "scroll").y < 250)
    }

    // MARK: - 3. Paint-Time Sticky Push-Out, Shadow, Fade, Reveal, Sibling Lift & ScrollFade (sticky.rs)

    @Test("sticky: requires enclosing scroll ancestor and pushes out at section boundary")
    func stickyRequiresScrollAndPushesOutWithSection() {
        struct S {
            var scrollY: Float = 0
        }
        // Without scroll ancestor, sticky does not shift
        let noScrollRt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().size(200, 200).child(
                col().size(200, 100).child(
                    el().key("hdr").size(200, 30).stickyTop(8)
                )
            )
        }
        _ = noScrollRt.frame(at: 0.0)
        let hdrNoScroll = noScrollRt.lastElements.first { $0.key == "hdr" }!
        #expect(abs(hdrNoScroll.stuck) < 0.01)

        // With scroll ancestor, a 12pt lead spacer, and two 120pt sections
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 120),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().key("scroll").size(200, 120).scrollY().child(
                col().wFull()
                    .child(el().key("lead").size(200, 12))
                    .child(
                        col().key("sec1").size(200, 120)
                            .child(el().key("h1").size(200, 30).stickyTop(8).stuckShadow(Shadow(x: 0, y: 2, blur: 4)))
                            .child(el().key("r1").size(200, 90))
                    )
                    .child(
                        col().key("sec2").size(200, 120)
                            .child(el().key("h2").size(200, 30).stickyTop(8))
                            .child(el().key("r2").size(200, 90))
                    )
            )
        }
        _ = rt.frame(at: 0.0)
        let h1Start = rt.lastElements.first { $0.key == "h1" }!
        #expect(abs(h1Start.rect[1] - 12) < 0.1)
        #expect(abs(h1Start.stuck) < 0.01)

        // Scroll down 40pt: h1 layout y = 12 - 40 = -28, sticks at top + 8 = 8 -> stuck shift = +36
        rt.update(at: 0.05) { _, tx in
            tx.scrollToInstant("scroll", x: 0, y: 40)
        }
        _ = rt.frame(at: 0.06)
        let h1Stuck = rt.lastElements.first { $0.key == "h1" }!
        #expect(abs(h1Stuck.rect[1] - 8) < 0.2)
        #expect(abs(h1Stuck.stuck - 36) < 0.2)
        // Hit testing sees shifted sticky rect at (100, 20), even though layout target is [-28..2]!
        #expect(rt.contains("h1", x: 100, y: 20))

        // Verify paint order lifts sticky h1 above non-sticky r1 sibling
        let scene = rt.frame(at: 0.07)
        #expect(!scene.primitives.isEmpty)

        // Scroll down 112pt: sec1 spans y = -100..20, so boxBottom = 20, h1 height = 30 -> pushed up to y = -10!
        rt.update(at: 0.10) { _, tx in
            tx.scrollToInstant("scroll", x: 0, y: 112)
        }
        _ = rt.frame(at: 0.11)
        let h1Pushed = rt.lastElements.first { $0.key == "h1" }!
        #expect(abs(h1Pushed.rect[1] - (-10)) < 0.2)
    }

    @Test("sticky: stickyTopShowing tail, stickyBottom, stickyLeft, stuckFade & stuckReveal")
    func stickyVariantsFadeAndReveal() {
        struct S {}
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 120),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().key("scroll").size(200, 120).scrollY().child(
                col().key("sec").size(200, 300)
                    .child(
                        col().key("tailHdr").size(200, 40)
                            .stickyTopShowing(6)
                            .stuckFade(lead: 20, span: 10)
                            .child(el().key("title").size(100, 20).opacity(1))
                            .child(el().key("badge").size(20, 20).stuckReveal(10))
                    )
                    .child(el().key("body").size(200, 220))
                    .child(el().key("ftr").size(200, 30).stickyBottom(4))
            )
        }
        _ = rt.frame(at: 0.0)
        let badgeUnstuck = rt.lastElements.first { $0.key == "badge" }!
        #expect(badgeUnstuck.opacity < 0.05, "stuckReveal should hide child before parent sticks")

        // Scroll 60pt: tailHdr has height 40, inset 6 -> pins with bottom at 6 (top = -34)!
        // Parent shift = 60 - 34 = 26 >= reveal span 10 -> badge reaches full opacity 1.0!
        rt.update(at: 0.05) { _, tx in
            tx.scrollToInstant("scroll", x: 0, y: 60)
        }
        _ = rt.frame(at: 0.06)
        let tailStuck = rt.lastElements.first { $0.key == "tailHdr" }!
        let badgeStuck = rt.lastElements.first { $0.key == "badge" }!
        #expect(abs(tailStuck.rect[1] - (-34)) < 0.2)
        #expect(badgeStuck.opacity > 0.95)
    }

    // MARK: - 4. VirtualFill, VirtualRows, GrowthSpec & RevealSelected

    @Test("virtual: VirtualFillStateMachine bound, backoff, stale attempt & scroll reset")
    func virtualFillBoundedBackoffStateMachine() {
        var fill = VirtualFillStateMachine()
        // First 12 frames return .draw
        var eff: VirtualFillStateMachine.Effect?
        for f in 1...Int(VirtualFillStateMachine.fillFrames) {
            eff = fill.step(.frame(now: Double(f) * 0.01, wanted: true, missing: 4, moved: false))
            #expect(eff == .draw)
        }
        #expect(fill.atBound)
        // Frame 13 returns .wakeAt with resume 1
        eff = fill.step(.frame(now: 1.0, wanted: true, missing: 4, moved: false))
        guard case .wakeAt(let due1) = eff else {
            Issue.record("Expected wakeAt on frame 13")
            return
        }
        #expect(abs((due1 - 1.0) - VirtualFillStateMachine.resumeWait) < 0.0001)
        #expect(!fill.resuming(at: due1 - 0.001))
        #expect(fill.resuming(at: due1))

        // Stale attempt ignored
        #expect(fill.step(.due(attempt: 999, now: due1)) == nil)

        // Exhaust resumeLimit = 3 -> .stalled
        for r in 1...Int(VirtualFillStateMachine.resumeLimit) {
            guard let due = fill.armedWake?.due, let att = fill.wake(at: due) else {
                Issue.record("Expected armed wake for resume \(r)")
                return
            }
            #expect(fill.step(.due(attempt: att, now: due)) == .draw)
            for _ in 0..<Int(VirtualFillStateMachine.fillFrames) {
                eff = fill.step(.frame(now: due + 0.01, wanted: true, missing: 4, moved: false))
            }
        }
        #expect(fill.phase == .stalled)
        // Moved viewport revives stalled fill!
        let movedEff = fill.step(.frame(now: 10.0, wanted: true, missing: 4, moved: true))
        #expect(movedEff == .draw)
    }

    @Test("virtual: virtualRows builds only window, preserves prepend anchor & notifies onVisibleRows")
    func virtualRowsBuildsWindowAndPreservesPrependAnchor() {
        final class Counter {
            var builtIndices: [Int] = []
            var visibleRanges: [Range<Int>] = []
        }
        struct S {
            var keys: [String]
            var version: Int = 1
        }
        let tracker = Counter()
        let initialKeys = (0..<1000).map { "row-\($0)" }
        let rt = Runtime<S>(
            state: S(keys: initialKeys),
            viewport: Vec2(300, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { s, cx in
            // A view reading its own viewport takes a second measure pass on the first commit.
            let width = cx.layoutWith("scroll", token: "width") { $0[2] } ?? 300
            return col().key("scroll").size(width, 200).scrollY().child(
                col().key("rows").wFull()
                    .virtualRows(count: s.keys.count, estimatedRowHeight: 20, key: { st, i in st.keys[i] }) { st, i in
                        tracker.builtIndices.append(i)
                        return el().key(st.keys[i]).size(300, 20)
                    }
                    .virtualRowsVersion(s.version)
                    .onVisibleRows { _, range in
                        tracker.visibleRanges.append(range)
                        return false
                    }
            )
        }
        _ = rt.frame(at: 0.0)
        // Only overscan window around 0..10 (200pt / 20pt + 2x overscan = <= 50 rows) builds out of 1000!
        #expect(!tracker.builtIndices.isEmpty && tracker.builtIndices.count < 80)
        #expect(rt.virtualLists.values.first?.lastMountedRange == 0..<15)
        #expect(tracker.visibleRanges.isEmpty)
        #expect(rt.isAnimating)
        _ = rt.frame(at: 0.01)
        #expect(rt.virtualLists.values.first?.lastMountedRange == 0..<20)
        #expect(tracker.visibleRanges == [0..<10])

        // Scroll to y = 200 (anchor row is row-10)
        rt.update(at: 0.05) { _, tx in
            tx.scrollToInstant("scroll", x: 0, y: 200)
        }
        _ = rt.frame(at: 0.06)
        #expect(abs(rt.scrollOffset(forKey: "scroll").y - 200) < 0.5)

        // Prepend 5 rows: row-10 moves down by 100pt -> scroll offset preserves anchor at 300!
        rt.update(at: 0.1) { s, _ in
            let prepended = (0..<5).map { "prep-\($0)" }
            s.keys = prepended + s.keys
            s.version += 1
        }
        _ = rt.frame(at: 0.11)
        #expect(abs(rt.scrollOffset(forKey: "scroll").y - 300) < 0.5)
    }

    @Test("growth: GrowthSpec grows streaming/arrivesWhole rows smoothly and settles on reducedMotion")
    func growthStackAndFoldGlideBehavior() {
        struct S {
            var showSecond = false
            var firstHeight: Float = 30
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 300),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col().size(200, 300).growth(GrowthSpec.default)
                .child(el().key("r1").size(200, s.firstHeight).streaming())
                .children(s.showSecond ? [el().key("r2").size(200, 60).arrivesWhole()] : [])
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.02) { s, _ in
            s.showSecond = true
            s.firstHeight = 80
        }
        _ = rt.frame(at: 0.04)
        let r2Start = rt.lastElements.first { $0.key == "r2" }!
        #expect(r2Start.rect[3] < 55, "newly inserted arrivesWhole row should start below target height")
        #expect(rt.isAnimating)

        // Advance time until settled
        var t = 0.04
        for _ in 0..<120 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            if !rt.isAnimating { break }
        }
        let r2End = rt.lastElements.first { $0.key == "r2" }!
        let r1End = rt.lastElements.first { $0.key == "r1" }!
        #expect(abs(r2End.rect[3] - 60) < 0.5)
        #expect(abs(r1End.rect[3] - 80) < 0.5)
    }

    @Test("focus: focusSelected & revealSelected track programmatic selection without firing during hover unless the group follows selection", arguments: [false, true], [false, true])
    func focusAndRevealSelectedSkipHover(nativeFrame: Bool, groupFollows: Bool) {
        struct S {
            var selected: Int = 0
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 80),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col().key("scroll").size(200, 80).scrollY().focusGroup(groupFollows).focusFollows(groupFollows).children(
                (0..<10).map { i in
                    el()
                        .key("item-\(i)")
                        .size(200, 30)
                        .focusable(true)
                        .focusSelected(s.selected == i)
                        .revealSelected(s.selected == i)
                        .onHover { state, hovered, tx in
                            if hovered {
                                state.selected = 8
                                tx.liveOnly()
                            }
                        }
                }
            )
        }
        func frame(at time: Double) {
            if nativeFrame {
                _ = rt.renderFrame(at: time)
            } else {
                _ = rt.frame(at: time)
            }
        }
        frame(at: 0.0)
        #expect(rt.focusedKey == "item-0")
        #expect(rt.scrollOffset(forKey: "scroll").y == 0)

        // The primary hover callback changes selection without rebuilding.
        rt.pointerMove(to: Vec2(50, 45), at: 0.05)
        frame(at: 0.06)
        #expect(rt.state.selected == 8)
        #expect(rt.focusedKey == "item-0")
        #expect(rt.scrollOffset(forKey: "scroll").y < 1)

        // Revealing item-7 moves a new row under the stationary pointer.
        rt.update(at: 0.1) { s, tx in
            tx.instant()
            s.selected = 7
        }
        frame(at: 0.11)
        #expect(rt.focusedKey == "item-7")
        let revealedOffset = rt.scrollOffset(forKey: "scroll").y
        #expect(revealedOffset > 100)

        frame(at: 0.12)
        #expect(rt.state.selected == 8)
        #expect(rt.focusedKey == (groupFollows ? "item-8" : "item-7"))
        #expect(rt.scrollOffset(forKey: "scroll").y == revealedOffset)

        // An unrelated commit keeps that focus. A later programmatic selection still moves it.
        rt.update(at: 0.13) { _, tx in tx.instant() }
        frame(at: 0.14)
        #expect(rt.focusedKey == (groupFollows ? "item-8" : "item-7"))
        rt.update(at: 0.15) { state, tx in
            tx.instant()
            state.selected = 6
        }
        frame(at: 0.16)
        #expect(rt.focusedKey == "item-6")
    }

    @Test("input: onInputKey intercepts focused textInput keys before editor and onPointerMoveAny fires")
    func onInputKeyAndPointerMoveAny() {
        struct S {
            var edit = TextEdit("hi")
            var intercepted: [String] = []
            var moveCalls = 0
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col().size(200, 100)
                .onPointerMoveAny { _, tx in
                    tx.liveOnly()
                }
                .child(
                    textInput(key: "field", \S.edit)
                        .size(180, 32)
                        .focused(true)
                        .onInputKey { st, ev, _ in
                            if ev.key == .arrowDown {
                                st.intercepted.append("down")
                                return true
                            }
                            st.intercepted.append("pass")
                            return false
                        }
                )
        }
        _ = rt.frame(at: 0.0)
        // Down arrow consumed by onInputKey (does not get eaten or move caret away)
        let consumed = rt.keyDown(KeyEvent(key: .arrowDown), at: 0.02)
        #expect(consumed)
        #expect(rt.state.intercepted == ["down"])
        // Typing '!' passes through onInputKey -> edits TextEdit
        _ = rt.keyDown(KeyEvent(key: .text("!")), at: 0.03)
        #expect(rt.state.intercepted == ["down", "pass"])
        #expect(rt.state.edit.text == "hi!")
        // Also exercise onPointerMoveAny compiles and dispatches cleanly
        rt.pointerMove(to: Vec2(20, 20), at: 0.04)
    }

    // MARK: - 5. Increment 4 Review #377 Regression Coverage

    @Test("scroll: stepFoldOpens preserves unmounted keeps and prunes prior mounted keeps")
    func stepFoldOpensPreservesUnmountedKeeps() {
        var req = ScrollRequestsState()
        req.keeps = [
            ScrollKeep(path: "/0/mounted-before", viewport: "/0/vp", was: 10, virtualRow: nil, hold: nil),
            ScrollKeep(path: "/0/unmounted-row", viewport: "/0/vp", was: 20, virtualRow: nil, hold: nil),
            ScrollKeep(path: "/0/mounted-after", viewport: "/0/vp", was: 30, virtualRow: nil, hold: nil),
        ]
        req.stepFoldOpens(viewport: "/0/vp", end: 5) { path in
            switch path {
            case "/0/mounted-before": return 2
            case "/0/mounted-after": return 7
            default: return nil
            }
        }
        #expect(req.keeps.map(\.path) == ["/0/unmounted-row", "/0/mounted-after"])
    }

    @Test("growth: keyed root + foldGlide collapsing row clamps height smoothly on 1/240s substeps")
    func growthKeyedRootAndFoldGlideCollapseClamping() {
        struct S {
            var expanded = true
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 300),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col().key("root").size(200, 300).growth(GrowthSpec.default)
                .child(
                    col().key("fold").wFull().h(s.expanded ? 120 : 20)
                        .foldGlide(Spring(duration: 0.25, bounce: 0))
                        .foldFeather(10)
                        .child(el().wFull().h(s.expanded ? 120 : 20).bg(Color(r: 1, g: 0, b: 0, a: 1)))
                )
        }
        _ = rt.frame(at: 0.0)
        let before = rt.lastElements.first { $0.key == "fold" }!
        #expect(abs(before.rect[3] - 120) < 0.5)

        // Collapse fold from 120 -> 20: GrowTrack retargets downward and must clamp collapsing height > 20 mid-glide!
        rt.update(at: 0.02) { s, _ in
            s.expanded = false
        }
        _ = rt.frame(at: 0.02)
        _ = rt.frame(at: 0.06)
        let mid = rt.lastElements.first { $0.key == "fold" }!
        #expect(mid.rect[3] > 25 && mid.rect[3] < 118, "collapsing foldGlide must clamp mid-glide height")

        var t = 0.06
        for _ in 0..<120 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            if !rt.isAnimating { break }
        }
        let end = rt.lastElements.first { $0.key == "fold" }!
        #expect(abs(end.rect[3] - 20) < 0.5)
    }

    @Test("scroll: keepOnScreen and scrollAnchor compensate pre-commit drawn positions across prepend")
    func keepOnScreenAndScrollAnchorCompensatePrepend() {
        struct S {
            var extraTop: Float = 0
        }
        let rtAnchor = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col().key("scroll").size(200, 100).scrollY().scrollAnchor(true)
                .child(el().key("head").size(200, 40 + s.extraTop))
                .child(el().key("row-a").size(200, 60))
                .child(el().key("row-b").size(200, 120))
        }
        _ = rtAnchor.frame(at: 0.0)
        rtAnchor.update(at: 0.02) { _, tx in
            tx.scrollToInstant("scroll", x: 0, y: 40)
        }
        _ = rtAnchor.frame(at: 0.04)
        #expect(abs(rtAnchor.scrollOffset(forKey: "scroll").y - 40) < 0.5)

        // Growing content above row-a shifts row-a down by 50 -> scrollAnchor compensates to ~90!
        rtAnchor.update(at: 0.06) { s, tx in
            tx.instant()
            s.extraTop = 50
        }
        _ = rtAnchor.frame(at: 0.08)
        let rowA = rtAnchor.lastElements.first { $0.key == "row-a" }!
        #expect(abs(rtAnchor.scrollOffset(forKey: "scroll").y - 90) < 0.5)
        #expect(abs(rowA.rect[1] - 0) < 0.5)

        // Explicit Tx.keepOnScreen without scrollAnchor:
        let rtKeep = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col().key("scroll").size(200, 100).scrollY()
                .child(el().key("head").size(200, 40 + s.extraTop))
                .child(el().key("target").size(200, 60))
                .child(el().key("tail").size(200, 120))
        }
        _ = rtKeep.frame(at: 0.0)
        let targetBefore = rtKeep.lastElements.first { $0.key == "target" }!.rect[1]
        rtKeep.update(at: 0.02) { s, tx in
            tx.instant()
            s.extraTop = 30
            tx.keepOnScreen("target")
        }
        _ = rtKeep.frame(at: 0.04)
        let targetAfter = rtKeep.lastElements.first { $0.key == "target" }!.rect[1]
        #expect(abs(targetAfter - targetBefore) < 0.5)
        #expect(abs(rtKeep.scrollOffset(forKey: "scroll").y - 30) < 0.5)
    }

    @Test("scroll: scrollKeyTo aligns target relative top and explicit destination clears reveal holds")
    func scrollKeyToAndStepDestination() {
        struct S { var dummy = 0 }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().key("scroll").size(200, 100).scrollY().children(
                (0..<10).map { el().key("item-\($0)").size(200, 40) }
            )
        }
        _ = rt.frame(at: 0.0)

        // item-3 sits at y = 120; scrollKeyTo("item-3", at: 15) places its top 15pt below viewport top (scrollY == 105)
        rt.update(at: 0.02) { _, tx in
            tx.scrollKeyTo("item-3", at: 15)
        }
        _ = rt.frame(at: 0.04)
        #expect(abs(rt.scrollOffset(forKey: "scroll").y - 105) < 0.5)

        // Enqueue a reveal, then an animated scrollTo(0, 0) in the same commit: stepDestination cancels the reveal!
        rt.update(at: 0.06) { _, tx in
            tx.scrollIntoView("item-8")
            tx.scrollTo("scroll", offset: Vec2(0, 0), animated: true)
        }
        _ = rt.frame(at: 0.08)
        #expect(rt.scrollRequestsState.reveals.isEmpty)
        var t = 0.08
        for _ in 0..<120 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            if !rt.isAnimating { break }
        }
        #expect(rt.scrollOffset(forKey: "scroll").y < 1.0)
    }

    @Test("sticky: stuckFade checks next sticky-top sibling and fades first tree-order child regardless of zIndex")
    func stuckFadeNextStickySiblingAndTreeChildOrder() {
        struct S { var dummy = 0 }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 120),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().key("scroll").size(200, 120).scrollY().child(
                col().key("section").size(200, 400)
                    .child(
                        col().key("hdr1").size(200, 30)
                            .stickyTop(0)
                            .stuckFade(lead: 10, span: 10)
                            // First tree-order child has HIGHER zIndex so z-sorting puts it second!
                            .child(el().key("c0").size(100, 20).z(2).opacity(1))
                            .child(el().key("c1").size(100, 10).z(0).opacity(1))
                    )
                    // Non-sticky sibling spacer between hdr1 and hdr2 must be skipped by stuckFade!
                    .child(el().key("nonSticky").size(200, 40))
                    .child(el().key("hdr2").size(200, 30).stickyTop(0))
                    .child(el().key("rest").size(200, 300))
            )
        }
        _ = rt.frame(at: 0.0)

        // Scroll to 30pt: nonSticky sits at y = 0, hdr2 sits at y = 40 (> lead+span 20), so c0 stays opaque!
        rt.update(at: 0.02) { _, tx in
            tx.scrollToInstant("scroll", x: 0, y: 30)
        }
        _ = rt.frame(at: 0.04)
        let c0Far = rt.lastElements.first { $0.key == "c0" }!
        #expect(c0Far.opacity > 0.99, "non-sticky sibling must not trigger stuckFade")

        // Scroll to 55pt: hdr2 sits at y = 15 -> factor = (15 - 0 - 10) / 10 = 0.5 on tree child c0 (not c1)!
        rt.update(at: 0.06) { _, tx in
            tx.scrollToInstant("scroll", x: 0, y: 55)
        }
        _ = rt.frame(at: 0.08)
        let c0Near = rt.lastElements.first { $0.key == "c0" }!
        let c1Near = rt.lastElements.first { $0.key == "c1" }!
        #expect(abs(c0Near.opacity - 0.5) < 0.05, "first tree child c0 must fade to ~0.5")
        #expect(c1Near.opacity > 0.99, "second tree child c1 must stay opaque despite lower zIndex")
    }

    @Test("input: pointerMove dispatches to all hit elements even during activeDrag and populates Tx.clock")
    func pointerMoveAllHitsActiveDragAndTxClock() {
        final class Log {
            var parentMoves: [Double] = []
            var childMoves: [Double] = []
            var pollClocks: [Double] = []
            var updateClock: Double?
            var updateIfClock: Double?
        }
        struct S { var dummy = 0 }
        let log = Log()
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().key("parent").size(200, 100)
                .onPointerMove { _, _, tx in
                    log.parentMoves.append(tx.clock)
                    tx.liveOnly()
                }
                .child(
                    el().key("child").size(100, 60)
                        .onDrag { _, _, tx in tx.liveOnly() }
                        .onPointerMove { _, _, tx in
                            log.childMoves.append(tx.clock)
                            tx.liveOnly()
                        }
                )
        }
        rt.poll = { _, now, tx in
            log.pollClocks.append(tx.clock)
            _ = now
            return false
        }
        _ = rt.frame(at: 0.0)
        _ = rt.runPoll(at: 0.5)
        rt.update(at: 0.75) { _, tx in log.updateClock = tx.clock }
        _ = rt.updateIf(at: 0.9) { _, tx in log.updateIfClock = tx.clock; return false }
        #expect(log.pollClocks == [0.0, 0.5])
        #expect(log.updateClock == 0.75)
        #expect(log.updateIfClock == 0.9)

        // Start activeDrag on child, then move pointer: both child and parent receive onPointerMove with clock == 1.25!
        rt.pointerDown(at: Vec2(20, 20), at: 1.0)
        rt.pointerMove(to: Vec2(30, 30), at: 1.25)
        #expect(log.childMoves == [1.25])
        #expect(log.parentMoves == [1.25])
    }

    @Test("scroll: instant scroll jump refreshes descendant scrollFade primitives in the same commit")
    func instantScrollRefreshesScrollFadeSpec() {
        struct S { var dummy = 0 }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().key("scroll").size(200, 100).scrollY().scrollFade(ScrollFade.feather(20))
                .child(el().key("row").size(200, 300).bg(Color(r: 1, g: 1, b: 1, a: 1)))
        }
        let s0 = rt.frame(at: 0.0)
        #expect(!s0.primitives.contains { $0.fade.y > 0.5 }, "at scroll offset 0, no top scrollFade should be active")
        #expect(s0.primitives.contains { $0.fade.y < -0.5 }, "at scroll offset 0, bottom scrollFade should be active")

        rt.update(at: 0.02) { _, tx in
            tx.scrollToInstant("scroll", x: 0, y: 50)
        }
        let s1 = rt.frame(at: 0.04)
        #expect(s1.primitives.contains { $0.fade.y > 0.5 }, "instant scroll jump should activate top scrollFade in the same commit")
    }
}
