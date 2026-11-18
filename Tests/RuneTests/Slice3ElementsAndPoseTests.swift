import Testing
@testable import Rune
import RuneMotion

@Suite("Slice 3 Elements, Pose & MotionElement Parity")
struct Slice3ElementsAndPoseTests {
    private struct ScrollMotionState {
        var words: Bool = false
    }

    private func paint<S>(_ rt: Runtime<S>, native: Bool, at time: Double) {
        if native { _ = rt.renderFrame(at: time) }
        else { _ = rt.frame(at: time) }
    }

    @Test("Inspection boxes retain array value semantics after a caller edits a snapshot")
    func publicGeometryArrays() {
        let rt = Runtime(state: (), viewport: Vec2(100, 80)) { _, _ -> El<Void> in
            col().child(el().key("box").size(30, 20))
        }
        for native in [false, true] {
            paint(rt, native: native, at: native ? 1 : 0)
            guard let snapshot = rt.element(byKey: "box") else {
                Issue.record("Missing painted box")
                return
            }
            #expect(snapshot.rect == [0, 0, 30, 20])
            var edited = snapshot
            edited.rect = []
            edited.visible.append(42)
            edited.target = [1, 2]
            #expect(edited.rect.isEmpty && edited.target == [1, 2])
            #expect(edited.visible == snapshot.visible + [42])
            #expect(snapshot == rt.element(byKey: "box"))
            edited.rect = snapshot.rect
            edited.target = snapshot.target
            edited.visible = snapshot.visible
            #expect(edited == snapshot)
        }
    }

    @Test("A forward anchor cycle shares every member's motion flags")
    func cycleSharesAncestorMotionOnce() {
        let rt = Runtime(state: false, viewport: Vec2(100, 100)) { _, _ -> El<Bool> in el() }
        var infos = ["child", "a", "b"].map(ElementInfo.stub)
        func pose(_ name: String, anchor: String) -> RawPoseNodeData {
            RawPoseNodeData(nodeId: NodeId.hash(name), anchorKey: anchor, rotation: 0, scale: 1, shadows: [],
                           ownMoving: name == "a", ownScrolling: name == "b", ownGrowingRow: name == "a",
                           ownLiveIntent: name == "b" ? 32 : 0, ownMotionLive: name == "b",
                           instantHoverGroupRule: false, loopPhase: nil, virtualExtent: false, revealing: false)
        }
        let raw = [infos[0].path: pose("child", anchor: "b"), infos[1].path: pose("a", anchor: "b"),
                   infos[2].path: pose("b", anchor: "a")]
        rt.finalizeElementTreeSnapshots(infos: &infos, rawPoseByPath: raw, landingHolds: [])
        for info in infos {
            #expect(info.moving && info.scrolling && info.inGrowingRow)
            #expect(info.liveIntent == 32)
        }
    }

    private func makeTestIcon() -> SVGIcon {
        SVGIcon(viewBox: 24, body: "<circle cx=\"12\" cy=\"12\" r=\"8\"/>")
    }

    private func agree(_ rt: Runtime<ScrollMotionState>, _ out: inout [MotionElement]) {
        rt.motionElements(&out)
        let els = rt.elements()
        #expect(out.count == els.count)
        for (m, e) in zip(out, els) {
            let ep = rt.elementPath(m.id)
            #expect(ep?.path == e.path)
            #expect(ep?.key == e.key)
            #expect(m.rect == e.rect)
            #expect(m.visible == e.visible)
            #expect(m.opacity == e.opacity)
            #expect(m.scale == e.scale)
            #expect((m.parent.map { els[$0].path }) == (e.parentIndex.map { els[$0].path }))
            let flags: [(UInt16, Bool)] = [
                (MotionElement.EXITING, e.exiting),
                (MotionElement.SCROLLING, e.scrolling),
                (MotionElement.GROWING, e.inGrowingRow || e.revealing),
                (MotionElement.LIVE, e.liveIntent != 0),
                (MotionElement.VIRTUAL, e.virtualExtent),
                (MotionElement.TEXT, e.role == .text),
                (MotionElement.LOOP, e.loopPhase != nil),
                (MotionElement.PAINTS, e.fill.a > 0.01 || !(e.text ?? "").isEmpty),
            ]
            for (flag, want) in flags {
                #expect(m.isFlag(flag) == want, "mismatch for \(e.path) flag \(flag)")
            }
            #expect((m.textHash != 0) == !(e.text ?? "").isEmpty)
        }
    }

    // MARK: - tests/motion_elements.rs

    @Test("motion_elements_match_elements_through_a_scroll", arguments: [false, true])
    func motionElementsMatchElementsThroughAScroll(native: Bool) {
        let rt = Runtime<ScrollMotionState>(
            state: ScrollMotionState(words: false),
            viewport: Vec2(600, 900),
            pixelScale: 2.0,
            systemDark: true
        ) { s, _ -> El<ScrollMotionState> in
            var rows: El<ScrollMotionState> = col().wFull()
            for i in 0..<30 {
                rows = rows.child(
                    el().key("row\(i)").wFull().h(40).child(text("row \(i)"))
                )
            }
            let tail: El<ScrollMotionState> = s.words
                ? text("a much longer line of words").key("words")
                : el().key("words").size(10, 10).bg(Color.black)
            return col().wFull().hFull()
                .child(col().key("scroll").w(300).h(400).scroll(ScrollSpec(stickBottom: false)).child(rows))
                .child(tail)
        }
        var out: [MotionElement] = []
        var t = 0.0
        paint(rt, native: native, at: t)
        agree(rt, &out)
        rt.wheel(WheelEvent(dy: -120), at: Vec2(100, 200), now: t)
        var scrolled = false
        for _ in 0..<30 {
            t += 1.0 / 60.0
            paint(rt, native: native, at: t)
            agree(rt, &out)
            scrolled = scrolled || out.contains { $0.isFlag(MotionElement.SCROLLING) }
        }
        #expect(scrolled, "the rows were marked scrolling while the wheel moved them")

        func row(_ key: String) -> MotionElement {
            out.first { rt.elementPath($0.id)?.key == key }!
        }
        let before = row("words")
        rt.update(at: t) { s, _ in s.words = true }
        for _ in 0..<30 {
            t += 1.0 / 60.0
            paint(rt, native: native, at: t)
            agree(rt, &out)
        }
        let after = row("words")
        #expect(before.textHash != after.textHash)
        #expect(out.filter { $0.isFlag(MotionElement.TEXT) }.allSatisfy { $0.textHash != 0 })
    }

    @Test("a_glide_marks_the_content_it_carries_scrolling")
    func glideMarksTheContentItCarriesScrolling() {
        let rt = Runtime<ScrollMotionState>(
            state: ScrollMotionState(words: false),
            viewport: Vec2(600, 900),
            pixelScale: 2.0,
            systemDark: true
        ) { _, _ -> El<ScrollMotionState> in
            var rows: El<ScrollMotionState> = col().wFull()
            for i in 0..<30 {
                rows = rows.child(
                    el().key("row\(i)").wFull().h(40).child(text("row \(i)"))
                )
            }
            return col().wFull().hFull()
                .child(col().key("scroll").w(300).h(400).scroll(ScrollSpec(stickBottom: false)).child(rows))
        }
        var out: [MotionElement] = []
        var t = 0.0
        _ = rt.frame(at: t)
        rt.update(at: t) { _, tx in tx.scrollTo("scroll", x: 0, y: 400) }
        func yPos() -> Float {
            rt.element(byKey: "row3")!.rect[1]
        }
        var moved = 0
        var last = yPos()
        for f in 0..<180 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            agree(rt, &out)
            let nowY = yPos()
            if abs(nowY - last) > 0.01 {
                moved += 1
                let row = rt.element(byKey: "row3")!
                #expect(row.scrolling || abs(nowY - last) < 0.5, "frame \(f): moving row should report scrolling")
            }
            last = nowY
        }
        #expect(moved > 5)
        #expect(rt.elements().allSatisfy { !$0.scrolling })
    }

    @Test("secure_text_hashes_to_zero", arguments: [false, true])
    func secureTextHashesToZero(native: Bool) {
        struct Empty {}
        let rt = Runtime<Empty>(
            state: Empty(),
            viewport: Vec2(300, 200),
            pixelScale: 2.0,
            systemDark: true
        ) { _, _ -> El<Empty> in
            col()
                .child(text("hunter2").key("plain"))
                .child(text("hunter2").key("secret").secure(true))
        }
        paint(rt, native: native, at: 0)
        var out: [MotionElement] = []
        rt.motionElements(&out)
        func hash(_ k: String) -> UInt64 {
            out.first { rt.elementPath($0.id)?.key == k }!.textHash
        }
        #expect(hash("plain") != 0)
        #expect(hash("secret") == 0)
    }

    @Test("Native frame inspection preserves tree order, transformed bounds and logical opacity")
    func nativeInspectionMatchesReferenceAcrossPaintModes() throws {
        let glow = Live(Color.white)
        let rt = Runtime<Bool>(state: false, viewport: Vec2(200, 200), pixelScale: 1) { on, _ in
            col().key("root").size(160, 160).opacity(on ? 1 : 0.5)
                .child(el().key("lifted").size(70, 40).raise().rotate(0.3).origin(0, 1)
                    .shadow(y: 1, blur: 4, color: .black).liveShadow(glow.binding)
                    .child(el().key("inner").size(20, 10).opacity(0.5)))
                .child(el().key("tail").size(30, 10))
                .child(el().key("hidden").opacity(0).size(30, 15)
                    .child(el().key("hiddenChild").size(8, 8)))
        }
        _ = rt.frame(at: 0)
        #expect(rt.nativeInspection?.materialized == false)
        #expect(rt.presentedPose("lifted")?.shadows.first?.color == .white)
        #expect(rt.nativeInspection?.materialized == false)
        let reference = rt.motionElements()
        let pose = try #require(rt.presentedPose("lifted"))
        #expect(pose.shadows.first?.color == .white)
        _ = rt.renderFrame(at: 0)
        #expect(rt.nativeInspection?.materialized == false)
        #expect(rt.presented("inner")?.opacity == 0.25)
        #expect(rt.presented("hiddenChild")?.opacity == 0)
        #expect(rt.presentedPose("lifted") == pose)
        #expect(rt.nativeInspection?.materialized == false)
        let native = rt.motionElements()
        #expect(native.map(\.id) == reference.map(\.id))
        #expect(native.map(\.parent) == reference.map(\.parent))
        #expect(native.map(\.rect) == reference.map(\.rect))
        #expect(native.map(\.visible) == reference.map(\.visible))
        #expect(native.map(\.opacity) == reference.map(\.opacity))
        #expect(native.map(\.flags) == reference.map(\.flags))
        #expect(rt.presentedPose("lifted") == pose)
        rt.update(at: 0) { on, tx in
            on = true
            tx.instant()
        }
        _ = rt.renderFrame(at: 1)
        #expect(rt.presented("inner")?.opacity == 0.5)
        _ = rt.frame(at: 2)
        #expect(rt.presented("inner")?.opacity == 0.5)
    }

    // MARK: - tests/pose_hit.rs Pose & shadow/rotation/iconTurn/loop moving parity

    private func sh(_ y: Float, color: Color = Color.black.alpha(0.3)) -> Shadow {
        Shadow(x: 0, y: y, blur: 8, spread: 0, color: color, inset: false)
    }

    private func isMoving<S>(_ rt: Runtime<S>, _ key: String) -> Bool {
        rt.element(byKey: key)!.moving
    }

    private func settle<S>(_ rt: Runtime<S>, t: inout Double, native: Bool = false) {
        for _ in 0..<150 {
            t += 1.0 / 60.0
            paint(rt, native: native, at: t)
        }
    }

    @Test("a_shadow_only_step_reports_moving_until_it_lands")
    func shadowOnlyStepReportsMovingUntilItLands() {
        let rt = Runtime<Bool>(
            state: false,
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { on, _ -> El<Bool> in
            let card: El<Bool> = el()
                .key("a")
                .size(100, 40)
                .bg(Color.white)
                .motion(Spring(duration: 0.3, bounce: 0))
                .shadow(sh(on ? 12 : 2))
            return col().wFull().hFull().itemsStart().p(50).child(card)
        }
        var t = 0.0
        _ = rt.frame(at: t)
        #expect(!isMoving(rt, "a"))
        #expect(rt.presentedPose("a")?.shadows.first?.y == 2.0)
        #expect(rt.presented("a")?.opacity == 1.0)

        rt.update(at: t) { on, _ in on = true }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(isMoving(rt, "a"))
        let mid = rt.presentedPose("a")!
        #expect(mid.moving)
        let y = mid.shadows[0].y
        #expect(y > 2.0 && y < 12.0)

        settle(rt, t: &t)
        #expect(!isMoving(rt, "a"))
        let landed = rt.presentedPose("a")!
        #expect(!landed.moving)
        #expect(landed.shadows[0].y == 12.0)
    }

    @Test("a_rotation_only_step_reports_moving_until_it_lands")
    func rotationOnlyStepReportsMovingUntilItLands() {
        let rt = Runtime<Bool>(
            state: false,
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { on, _ -> El<Bool> in
            let box: El<Bool> = el()
                .key("a")
                .size(100, 40)
                .bg(Color.white)
                .motion(Spring(duration: 0.3, bounce: 0))
                .rotate(on ? 1.0 : 0.0)
            return col().wFull().hFull().itemsStart().p(50).child(box)
        }
        var t = 0.0
        _ = rt.frame(at: t)
        #expect(!isMoving(rt, "a"))

        rt.update(at: t) { on, _ in on = true }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(isMoving(rt, "a"))
        let r = rt.presentedPose("a")!.rotation
        #expect(r > 0.0 && r < 1.0)

        settle(rt, t: &t)
        #expect(!isMoving(rt, "a"))
        let landed = rt.presentedPose("a")!
        #expect(abs(landed.rotation - 1.0) < 1e-3)
        #expect(!landed.moving)
    }

    @Test("a_shadow_colour_only_step_settles")
    func shadowColourOnlyStepSettles() {
        let rt = Runtime<Bool>(
            state: false,
            viewport: Vec2(100, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { on, _ -> El<Bool> in
            el().key("a").size(40, 40).motion(Spring(duration: 0.3, bounce: 0))
                .shadow(sh(2, color: on ? Color.white : Color.black))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        rt.update(at: t) { on, _ in on = true }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(isMoving(rt, "a"))
        #expect(rt.presentedPose("a")!.shadows[0].color != Color.white)

        settle(rt, t: &t)
        #expect(!isMoving(rt, "a"))
        #expect(!rt.presentedPose("a")!.moving)
    }

    @Test("an_icon_turn_only_step_settles")
    func iconTurnOnlyStepSettles() {
        let dot = makeTestIcon()
        let rt = Runtime<Bool>(
            state: false,
            viewport: Vec2(100, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { on, _ -> El<Bool> in
            let ic: El<Bool> = icon(dot, size: 40)
            return ic.key("a").motion(Spring(duration: 0.3, bounce: 0)).iconRotation(on ? 1.0 : 0.0)
        }
        var t = 0.0
        _ = rt.frame(at: t)
        rt.update(at: t) { on, _ in on = true }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(isMoving(rt, "a"))
        #expect(rt.presentedPose("a")!.moving)

        settle(rt, t: &t)
        #expect(!isMoving(rt, "a"))
        #expect(!rt.presentedPose("a")!.moving)
    }

    @Test("pose_and_element_moving_agree_for_loops_and_an_anchors_shadow", arguments: [false, true])
    func poseAndElementMovingAgreeForLoopsAndAnchorsShadow(native: Bool) {
        let rt = Runtime<Bool>(
            state: false,
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { on, _ -> El<Bool> in
            let anchor: El<Bool> = el()
                .key("anchor")
                .size(40, 40)
                .motion(Spring(duration: 0.3, bounce: 0))
                .shadow(sh(on ? 12 : 2))
            return col().wFull().hFull()
                .child(anchor)
                .child(el().key("popup").size(20, 20).above("anchor", gutter: 0))
                .child(el().key("loop").size(20, 20).looping(LoopSpec.rotation(period: 1.0)))
        }
        var t = 0.0
        paint(rt, native: native, at: t)
        rt.update(at: t) { on, _ in on = true }
        t += 1.0 / 60.0
        paint(rt, native: native, at: t)
        #expect(isMoving(rt, "popup"))
        #expect(rt.presentedPose("popup")!.moving)

        settle(rt, t: &t, native: native)
        #expect(!isMoving(rt, "popup"))
        #expect(!rt.presentedPose("popup")!.moving)
        #expect(isMoving(rt, "loop"))
        #expect(rt.presentedPose("loop")!.moving)
    }

    @Test("shrunk_or_removed_shadow_prunes_tracks_and_inset_flip_snaps")
    func shadowPruneAndInsetFlipSnap() {
        enum ShadowMode {
            case smallDrop
            case largeDrop
            case none
            case insetLarge
        }
        let rt = Runtime<ShadowMode>(
            state: .smallDrop,
            viewport: Vec2(120, 120),
            pixelScale: 1.0,
            systemDark: true
        ) { mode, _ -> El<ShadowMode> in
            var box: El<ShadowMode> = el()
                .key("box")
                .size(40, 40)
                .motion(Spring(duration: 0.4, bounce: 0))
            switch mode {
            case .smallDrop:
                box = box.shadow(sh(2))
            case .largeDrop:
                box = box.shadow(sh(20))
            case .none:
                break
            case .insetLarge:
                var s = sh(24)
                s.inset = true
                box = box.shadow(s)
            }
            return box
        }

        var t = 0.0
        _ = rt.frame(at: t)
        // Start animating shadow y 2 -> 20
        rt.update(at: t) { mode, _ in mode = .largeDrop }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(rt.isAnimating)
        #expect(rt.presentedPose("box")!.shadows[0].y < 20)

        // Removing the shadow prunes liveStore props and clears animation immediately
        rt.update(at: t) { mode, _ in mode = .none }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(!rt.isAnimating)
        #expect(rt.presentedPose("box")!.shadows.isEmpty)

        // Re-adding a shadow snaps fresh to 20 (does not animate from stale 2..20 value)
        rt.update(at: t) { mode, _ in mode = .largeDrop }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(rt.presentedPose("box")!.shadows[0].y == 20)
        #expect(!rt.isAnimating)

        // Flipping Shadow.inset from drop shadow to inset snaps immediately instead of morphing 20 -> 24
        rt.update(at: t) { mode, _ in mode = .insetLarge }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(rt.presentedPose("box")!.shadows[0].inset == true)
        #expect(rt.presentedPose("box")!.shadows[0].y == 24)
        #expect(!rt.isAnimating)
    }

    @Test("virtual_element_flag_requires_no_rich_or_live_text", arguments: [false, true])
    func virtualFlagRequiresNoRichOrLiveText(native: Bool) {
        let live = LiveText("live")
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(200, 120),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ -> El<Int> in
            col().wFull().hFull().child(
                col().key("vr").wFull().h(80).virtualRows(
                    count: 1,
                    estimatedRowHeight: 30,
                    key: { _, i in "row-\(i)" },
                    build: { _, i in text("row \(i)").key("row-\(i)").size(180, 30) }
                )
            )
            .child(
                rich("hi", [RichSpan(0..<2).color(Color.white)])
                    .key("rich-vr")
                    .size(100, 20)
                    .virtualRows(
                        count: 1,
                        estimatedRowHeight: 20,
                        key: { _, i in "rich-\(i)" },
                        build: { _, _ in el().size(10, 10) }
                    )
            )
            .child(
                liveText(live)
                    .key("live-vr")
                    .size(100, 20)
                    .virtualRows(
                        count: 1,
                        estimatedRowHeight: 20,
                        key: { _, i in "live-\(i)" },
                        build: { _, _ in el().size(10, 10) }
                    )
            )
        }
        paint(rt, native: native, at: 0.0)
        var out: [MotionElement] = []
        rt.motionElements(&out)
        let vrEl = out.first { rt.elementPath($0.id)?.key == "vr" }!
        let richEl = out.first { rt.elementPath($0.id)?.key == "rich-vr" }!
        let liveEl = out.first { rt.elementPath($0.id)?.key == "live-vr" }!
        #expect(vrEl.isFlag(MotionElement.VIRTUAL))
        #expect(!richEl.isFlag(MotionElement.VIRTUAL))
        #expect(!liveEl.isFlag(MotionElement.VIRTUAL))
        #expect(rt.element(byKey: "vr")?.virtualExtent == true)
        #expect(rt.element(byKey: "rich-vr")?.virtualExtent == false)
        #expect(rt.element(byKey: "live-vr")?.virtualExtent == false)
    }
}
