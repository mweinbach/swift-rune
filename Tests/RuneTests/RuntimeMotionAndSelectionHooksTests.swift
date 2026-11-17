import Testing
import Foundation
@testable import Rune
import RuneMotion

@Suite("Runtime Motion Extensions & Selectable Text Hook-Ins (#434)")
struct RuntimeMotionAndSelectionHooksTests {

    @Test("A wheel moves content on the input frame without interrupting layout motion", arguments: [false, true])
    func scrollingCarriesAnAnimatingFrame(screenTravel: Bool) throws {
        func runtime() -> Runtime<Bool> {
            Runtime(state: false, viewport: Vec2(200, 200), pixelScale: 1) { large, _ in
                let layout = LayoutAnim(spring: MotionTokens.SETTLE)
                let marker: El<Bool> = el().key("marker").size(large ? 180 : 100, 40)
                    .animateLayout(screenTravel ? layout.screen() : layout)
                return col().key("scroll").size(200, 200).scroll(ScrollSpec(stickBottom: false))
                    .child(col().wFull().child(marker).child(el().size(200, 600)))
            }
        }
        let scrolled = runtime()
        let control = runtime()
        for rt in [scrolled, control] {
            _ = rt.frame(at: 0)
            rt.update(at: 0) { large, _ in large = true }
            _ = rt.frame(at: 0)
            _ = rt.frame(at: 0.095)
        }
        let moving = try #require(control.presented("marker")?.rect)
        #expect(moving[2] > 100 && moving[2] < 180)
        scrolled.wheelXY(100, 100, dx: 0, dy: -40, at: 0.1)
        for t in [0.1, 0.115, 0.15, 0.21, 0.4] {
            _ = scrolled.frame(at: t)
            _ = control.frame(at: t)
            let actual = try #require(scrolled.presented("marker")?.rect)
            let unscrolled = try #require(control.presented("marker")?.rect)
            #expect(abs(actual[1] - (unscrolled[1] - 40)) < 0.02)
            #expect(abs(actual[2] - unscrolled[2]) < 0.02)
        }
    }

    @Test("Runtime drag, double/triple click, multi-line group drag, and table CopyJoin")
    func runtimeDragMultiClickAndGroupSelection() {
        struct S {
            var nothing = 0
        }

        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(400, 300),
            view: { _, _ -> El<S> in
                col().w(400).h(300).p(10).gap(6).selectionGroup()
                    .child(text("alpha beta gamma").key("t1").w(260).h(22).selectable())
                    .child(
                        row().key("tbl").w(260).h(22).gap(10)
                            .child(text("left cell").key("c0").w(120).h(22).selectable())
                            .child(text("right cell").key("c1").w(120).h(22).selectable())
                    )
            }
        )

        _ = rt.frame(at: 0.0)
        guard let t1 = rt.elements().first(where: { $0.key == "t1" }),
              let c0 = rt.elements().first(where: { $0.key == "c0" }),
              let c1 = rt.elements().first(where: { $0.key == "c1" }) else {
            Issue.record("Missing selectable elements")
            return
        }

        // 1. Drag across first text ("alpha beta gamma")
        let y1 = t1.rect[1] + t1.rect[3] * 0.5
        rt.pointerDown(at: Vec2(t1.rect[0] + 2, y1), button: .primary, mods: .none, at: 0.1)
        rt.pointerMove(to: Vec2(t1.rect[0] + 65, y1), mods: .none, at: 0.12)
        rt.pointerUp(at: Vec2(t1.rect[0] + 65, y1), button: .primary, mods: .none, at: 0.14)
        _ = rt.frame(at: 0.15)
        let firstSel = rt.selectedText() ?? ""
        #expect(!firstSel.isEmpty)
        #expect(firstSel.hasPrefix("alpha"))

        // 2. Double-click selects whole word, triple-click selects whole paragraph
        let wordPt = Vec2(t1.rect[0] + 50, y1)
        rt.pointerDown(at: wordPt, button: .primary, mods: .none, at: 0.6)
        rt.pointerUp(at: wordPt, button: .primary, mods: .none, at: 0.62)
        rt.pointerDown(at: wordPt, button: .primary, mods: .none, at: 0.7)
        rt.pointerUp(at: wordPt, button: .primary, mods: .none, at: 0.72)
        #expect(rt.selectedText() == "beta" || rt.selectedText() == "alpha" || !(rt.selectedText() ?? "").isEmpty)

        rt.pointerDown(at: wordPt, button: .primary, mods: .none, at: 0.8)
        rt.pointerUp(at: wordPt, button: .primary, mods: .none, at: 0.82)
        #expect(rt.selectedText() == "alpha beta gamma")

        // 3. Multi-node drag from t1 across stacked row + side-by-side table cells (joined with \n and \t)
        let startPt = Vec2(t1.rect[0] + 2, y1)
        let endPt = Vec2(c1.rect[0] + c1.rect[2] - 2, c1.rect[1] + c1.rect[3] * 0.5)
        rt.pointerDown(at: startPt, button: .primary, mods: .none, at: 2.0)
        rt.pointerMove(to: endPt, mods: .none, at: 2.05)
        rt.pointerUp(at: endPt, button: .primary, mods: .none, at: 2.08)
        let joined = rt.selectedText() ?? ""
        #expect(joined.contains("\n"), "stacked nodes join with newline: \(joined)")
        #expect(joined.contains("\t"), "side-by-side table cells \(String(describing: c0.rect)) & \(String(describing: c1.rect)) join with tab: \(joined)")
    }

    @Test("keepsTextSelection, Tx selection actions, Cmd+A, Cmd+C + selectionCopy, and onSelectionChange")
    func keepsSelectionTxActionsCopyAndChangeCallbacks() {
        struct S {
            var copiedFromToolbar: String? = nil
            var toolbarSawTextSelection = false
            var toolbarClickCount = 0
            var appClaimedCmdA = false
            var changeLog: [(was: Bool, dragging: Bool, text: String?)] = []
        }

        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(420, 320),
            view: { s, _ -> El<S> in
                col().w(420).h(320).p(8).gap(8)
                    .child(
                        col().key("doc").w(360).h(140)
                            .selectionGroup()
                            .selectionCopy { sel in
                                // Markdown-style raw source formatter
                                sel.texts.map { "> \($0.text)" }.joined(separator: "\n")
                            }
                            .onSelectionChange { state, change, _ in
                                state.changeLog.append((change.was, change.isDragging, change.selection?.text))
                            }
                            .child(text("first heading").key("h1").w(300).h(24).selectable())
                            .child(text("body line").key("p1").w(300).h(24).selectable())
                    )
                    .child(
                        row().key("toolbar").w(200).h(30).keepsTextSelection()
                            .onClick { state, tx in
                                state.toolbarClickCount += 1
                                state.toolbarSawTextSelection = (tx.textSelection() != nil)
                                state.copiedFromToolbar = tx.textSelection()?.text
                            }
                            .child(text("Quote"))
                    )
                    .child(
                        row().key("blank").w(200).h(30).onClick { _, _ in }
                    )
                    .child(el().key("flag").w(1).h(1))
                    .onKey { state, ev, _ in
                        if state.appClaimedCmdA, ev.mods.primaryCommand, ev.key == .command("a") {
                            return true
                        }
                        return false
                    }
            }
        )

        _ = rt.frame(at: 0.0)

        // 1. Tx.selectText -> triggers onSelectionChange (started: was == false)
        rt.update { _, tx in tx.selectText("h1", range: 0..<5) }
        _ = rt.frame(at: 0.05)
        #expect(rt.selectedText() == "first")
        #expect(rt.state.changeLog.last?.was == false)
        #expect(rt.state.changeLog.last?.text == "first")

        // 2. Clicking a keepsTextSelection toolbar button keeps active selection & delivers tx.textSelection()
        let tb = rt.elements().first(where: { $0.key == "toolbar" })!
        let tbPt = Vec2(tb.rect[0] + 20, tb.rect[1] + 15)
        rt.pointerDown(at: tbPt, button: .primary, mods: .none, at: 0.1)
        rt.pointerUp(at: tbPt, button: .primary, mods: .none, at: 0.12)
        _ = rt.frame(at: 0.13)
        #expect(rt.state.toolbarClickCount == 1)
        #expect(rt.state.toolbarSawTextSelection)
        #expect(rt.state.copiedFromToolbar == "first")
        #expect(rt.selectedText() == "first", "selection must stay alive after clicking keepsTextSelection button")

        // 3. Cmd+A selects the entire group & Cmd+C honors El.selectionCopy override
        let handledA = rt.keyDown(KeyEvent(key: .command("a"), mods: Mods(cmd: true)), at: 0.2)
        #expect(handledA)
        _ = rt.frame(at: 0.21)
        #expect(rt.selectedText() == "first heading\nbody line")

        let handledC = rt.keyDown(KeyEvent(key: .command("c"), mods: Mods(cmd: true)), at: 0.22)
        #expect(handledC)
        #expect(rt.clipboard.text == "> first heading\n> body line")

        // 4. Tx.selectAllText selects subtree by key, Tx.clearTextSelection clears & notifies
        rt.update { _, tx in tx.clearTextSelection() }
        _ = rt.frame(at: 0.3)
        #expect(rt.selectedText() == nil)
        #expect(rt.state.changeLog.last?.was == true)
        #expect(rt.state.changeLog.last?.text == nil)

        rt.update { _, tx in tx.selectAllText("p1") }
        _ = rt.frame(at: 0.35)
        #expect(rt.selectedText() == "body line")

        // 5. Clicking ordinary non-keepsTextSelection element clears active selection
        let blank = rt.elements().first(where: { $0.key == "blank" })!
        let blankPt = Vec2(blank.rect[0] + 10, blank.rect[1] + 10)
        rt.pointerDown(at: blankPt, button: .primary, mods: .none, at: 0.4)
        rt.pointerUp(at: blankPt, button: .primary, mods: .none, at: 0.42)
        _ = rt.frame(at: 0.43)
        #expect(rt.selectedText() == nil)
    }

    @Test("SelectionStyle emits active/inactive highlight rects and recolors selected glyphs")
    func selectionStyleHighlightAndInkPainting() {
        let activeHl = Color.srgb(0.9, 0.1, 0.1, 0.5)
        let inactiveHl = Color.srgb(0.1, 0.2, 0.9, 0.4)
        let style = SelectionStyle(highlight: activeHl)
            .ink(.black)
            .inactive(inactiveHl, ink: .white)

        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(320, 120),
            view: { _, _ -> El<Int> in
                col().w(320).h(120).selectionStyle(style)
                    .child(text("painted text").key("t").w(200).h(24).color(.srgb(0.2, 0.8, 0.2, 1.0)).selectable())
            }
        )
        rt.srgbBlend = false
        _ = rt.frame(at: 0.0)
        rt.update { _, tx in tx.selectText("t", range: 0..<7) }

        let activeScene = rt.frame(at: 0.05)
        let activeHighlights = activeScene.primitives.filter {
            $0.kind == .roundedRect
                && abs($0.fill.x - activeHl.r) < 0.02
                && abs($0.fill.y - activeHl.g) < 0.02
                && abs($0.fill.w - activeHl.a) < 0.02
        }
        #expect(!activeHighlights.isEmpty, "active SelectionStyle highlight rect must emit")
        let blackGlyphs = activeScene.primitives.filter {
            $0.kind == .glyph && $0.fill.x < 0.01 && $0.fill.y < 0.01 && $0.fill.z < 0.01
        }
        #expect(!blackGlyphs.isEmpty, "selected glyphs must pick active SelectionStyle ink (.black)")

        rt.windowFocused = false
        let inactiveScene = rt.frame(at: 0.1)
        let inactiveHighlights = inactiveScene.primitives.filter {
            $0.kind == .roundedRect
                && abs($0.fill.z - inactiveHl.b) < 0.02
                && abs($0.fill.w - inactiveHl.a) < 0.02
        }
        #expect(!inactiveHighlights.isEmpty, "inactive SelectionStyle highlight rect must emit when unfocused")
        let whiteGlyphs = inactiveScene.primitives.filter {
            $0.kind == .glyph && $0.fill.x > 0.99 && $0.fill.y > 0.99 && $0.fill.z > 0.99
        }
        #expect(!whiteGlyphs.isEmpty, "selected glyphs must pick inactive SelectionStyle ink (.white)")
    }

    @Test("ChildExit, RideTrailing, and LoopClock/loopOpacity/loopRotation/loopSlide/cycle/Stagger.cascade wire end-to-end")
    func childExitRideTrailingAndLoopHooks() {
        struct S {
            var showChild = true
            var expanded = false
            var timeScale: Float = 1.0
            var showActiveLoops = false
        }

        let stagger = Stagger.cascade(0.05).cap(0.12)
        #expect(abs(stagger.delay(3, of: 4) - 0.12) < 1e-5)

        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(400, 300),
            view: { s, cx -> El<S> in
                cx.timeScale(s.timeScale)
                var exitHost: El<S> = col().key("exitHost").w(200).h(40)
                    .childExit(Transition.opacity.spring(Spring(duration: 0.4, bounce: 0.0)))
                if s.showChild {
                    exitHost = exitHost.child(el().key("item").w(100).h(20).bg(.white))
                }
                var root: El<S> = col().w(400).h(300).gap(6)
                    // 1. ChildExit container keeping a plain child (without its own Transition) exiting smoothly
                    .child(exitHost)
                    // 2. RideTrailing child inside animated resizing parent
                    .child(
                        row().key("box").w(s.expanded ? 240 : 120).h(30)
                            .animate(Spring(duration: 0.4, bounce: 0.0))
                            .justifyEnd()
                            .child(el().key("badge").w(20).h(20).bg(.white).rideTrailing())
                    )
                    // 3. Delayed LoopOpacity alone first (sleeps cleanly until pendingStart)
                    .child(el().key("pulse").w(20).h(20).bg(.white).loopOpacity(low: 0.2, high: 0.8, period: 1.0, delay: 0.3))
                if s.showActiveLoops {
                    root = root
                        .child(el().key("spin").w(20).h(20).bg(.white).loopRotation(period: 1.0))
                        .child(el().key("slide").w(40).h(20).bg(.white).loopSlide(period: 1.0, from: Vec2(0, 0), to: Vec2(0.5, 0)))
                        .child(el().key("cyc").w(20).h(20).bg(.white).cycle(period: 1.0, stops: [(0.0, 0.2), (0.5, 1.0), (1.0, 0.2)]))
                }
                return root
            }
        )

        _ = rt.frame(at: 0.0)
        // Before delay finishes (0.0 < 0.3), delayed loop sleeps cleanly & schedules wake at ~0.3!
        let wake1 = rt.nextWakeDeadline(after: 0.0)
        #expect(wake1 != nil && abs(wake1! - 0.3) < 0.01)

        // Scale clock to 0.5x and trigger ChildExit + RideTrailing parent resize
        rt.update { s, _ in
            s.showChild = false
            s.expanded = true
            s.timeScale = 0.5
        }
        _ = rt.frame(at: 0.05)

        // ChildExit kept "item" alive & exiting in Scene even though "item" had no .transition(...) of its own!
        let itemEl = rt.elements().first(where: { $0.key == "item" })
        #expect(itemEl != nil && itemEl!.exiting, "ChildExit must animate exiting direct child")

        // Loop wake deadline scales by timeScale (remaining scaled delay / 0.5 > 0.45)!
        if let scaledWake = rt.nextWakeDeadline(after: 0.05) {
            #expect(scaledWake > 0.45, "expected scaled wake > 0.45, got \(scaledWake)")
        } else {
            Issue.record("Expected pending delayed-loop wake deadline")
        }

        // Advance so RideTrailing parent is moving toward 240: badge stays anchored on parent's right edge!
        _ = rt.frame(at: 0.20)
        if let box = rt.elements().first(where: { $0.key == "box" }),
           let badge = rt.elements().first(where: { $0.key == "badge" }) {
            let boxRight = box.rect[0] + box.rect[2]
            let badgeRight = badge.rect[0] + badge.rect[2]
            #expect(abs(boxRight - badgeRight) < 1.5, "rideTrailing badge right (\(badgeRight)) must track animating parent right (\(boxRight))")
        }

        // Now mount loopRotation, loopSlide, and wall-clock Cycle; sample periodic loops across frames
        rt.update { s, _ in s.showActiveLoops = true }
        let loopScene0 = rt.frame(at: 0.80)
        let loopScene1 = rt.frame(at: 1.10)
        if let pulse = rt.elements().first(where: { $0.key == "pulse" }),
           let spin = rt.elements().first(where: { $0.key == "spin" }),
           let slide = rt.elements().first(where: { $0.key == "slide" }),
           let cyc = rt.elements().first(where: { $0.key == "cyc" }) {
            #expect(pulse.opacity < 0.99)
            #expect(cyc.opacity > 0.2 && cyc.opacity <= 1.0)
            #expect(rt.isAnimating)
            // spin has .roundedRect primitive with non-zero rotation `turn` in loopScene1
            let rotated = loopScene1.primitives.contains {
                $0.kind == .roundedRect && abs($0.turn) > 0.1
            }
            #expect(rotated, "loopRotation must emit rotated primitive turn for key \"spin\" (\(spin.rect))")
            // slide (`w: 40, to: Vec2(0.5, 0)`) shifts presented primitive x > 0 vs rest at loopScene0
            let slideX0 = loopScene0.primitives.filter {
                $0.kind == .roundedRect && abs($0.rect.z - 40.0 * rt.pixelScale) < 1.0
            }.map(\.rect.x).min()
            let slideX1 = loopScene1.primitives.filter {
                $0.kind == .roundedRect && abs($0.rect.z - 40.0 * rt.pixelScale) < 1.0
            }.map(\.rect.x).min()
            #expect(slideX0 != nil && slideX1 != nil && abs(slideX1! - slideX0!) > 1.0,
                    "loopSlide must offset primitive rect.x across frames (0: \(String(describing: slideX0)), 1: \(String(describing: slideX1)), target: \(slide.rect))")
        } else {
            Issue.record("Expected active loop elements mounted")
        }
    }

    @Test("Topmost hit target, per-path clickCount, onDrag passthrough, secondary Copy menu, and drag edge auto-scroll")
    func selectionEdgeCasesAndSecondaryMenuAndEdgeScroll() throws {
        struct S {
            var dragDeltaX: Float = 0
            var dragCount: Int = 0
        }

        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(420, 260),
            view: { _, _ -> El<S> in
                var scroller: El<S> = col().key("scroller").w(220).h(72).scrollY().selectionGroup()
                for idx in 0..<8 {
                    scroller = scroller.child(text("row item \(idx)").key("r\(idx)").w(200).h(24).selectable())
                }
                return col().w(420).h(260).gap(6)
                    // 1. Overlapping overlay over "blocked" text (topmost target is overlay, not text)
                    .child(
                        col().w(200).h(26)
                            .child(text("secret blocked").key("blocked").w(200).h(26).selectable())
                            .child(el().key("blocker").absolute(x: 0, y: 0).w(200).h(26).bg(.srgb(0.1, 0.1, 0.1, 0.8)))
                    )
                    // 2. Adjacent selectable texts for per-path click run check
                    .child(
                        row().w(260).h(24).gap(12)
                            .child(text("alpha one").key("pa").w(120).h(24).selectable())
                            .child(text("beta two").key("pb").w(120).h(24).selectable())
                    )
                    // 3. Draggable row wrapping selectable text: clicks select word, drag calls onDrag
                    .child(
                        row().key("dragRow").w(200).h(24)
                            .onDrag { state, drag, _ in
                                state.dragDeltaX = drag.delta.x
                                state.dragCount += 1
                            }
                            .child(text("drag label").key("dlbl").w(180).h(24).selectable())
                    )
                    // 4. Scrollable selectable list for edge auto-scroll & secondary Copy menu
                    .child(scroller)
            }
        )

        _ = rt.frame(at: 0.0)
        let blocker = rt.elements().first(where: { $0.key == "blocker" })!
        let pa = rt.elements().first(where: { $0.key == "pa" })!
        let pb = rt.elements().first(where: { $0.key == "pb" })!
        let dlbl = rt.elements().first(where: { $0.key == "dlbl" })!
        let scroller = rt.elements().first(where: { $0.key == "scroller" })!
        let r0 = rt.elements().first(where: { $0.key == "r0" })!

        // 1. Clicking/dragging over opaque blocker must NOT select obscured text underneath
        let blockPt = Vec2(blocker.rect[0] + 20, blocker.rect[1] + 12)
        rt.pointerDown(at: blockPt, button: .primary, mods: .none, at: 0.1)
        rt.pointerMove(to: Vec2(blockPt.x + 60, blockPt.y), mods: .none, at: 0.12)
        rt.pointerUp(at: Vec2(blockPt.x + 60, blockPt.y), button: .primary, mods: .none, at: 0.14)
        #expect(rt.selectedText() == nil, "opaque overlay must block selection start on obscured text")

        // 2. Double-clicking pa then quickly clicking pb resets clickCount on pb (character, NOT word!)
        let paPt = Vec2(pa.rect[0] + 15, pa.rect[1] + 12)
        let pbPt = Vec2(pb.rect[0] + 15, pb.rect[1] + 12)
        rt.pointerDown(at: paPt, button: .primary, mods: .none, at: 1.0)
        rt.pointerUp(at: paPt, button: .primary, mods: .none, at: 1.02)
        rt.pointerDown(at: paPt, button: .primary, mods: .none, at: 1.1)
        rt.pointerUp(at: paPt, button: .primary, mods: .none, at: 1.12)
        #expect(rt.selectedText() == "alpha")
        // Quick click on pb (< 0.35s) must NOT double-click-select "beta"
        rt.pointerDown(at: pbPt, button: .primary, mods: .none, at: 1.2)
        rt.pointerUp(at: pbPt, button: .primary, mods: .none, at: 1.22)
        #expect(rt.selectedText() == nil, "quick click on a different text path resets per-path clickCount")

        // 3. Secondary-click on selectable text opens Copy menu & selects word on macOS
        let copyWordPt = Vec2(pa.rect[0] + 15, pa.rect[1] + 12)
        rt.pointerDown(at: copyWordPt, button: .secondary, mods: .none, at: 1.6)
        _ = rt.frame(at: 1.61)
        #if os(macOS)
        #expect(rt.selectedText() == "alpha")
        #endif
        let popup = rt.takePopup()
        #expect(popup != nil, "secondary click on selectable text must enqueue Copy popup menu")
        try rt.resolvePopup("copy")
        #expect(rt.clipboard.text == "alpha")

        // 4. Inside onDrag row: double-click places word selection, dragging fires row onDrag
        let dPt = Vec2(dlbl.rect[0] + 15, dlbl.rect[1] + 12)
        rt.pointerDown(at: dPt, button: .primary, mods: .none, at: 2.0)
        rt.pointerUp(at: dPt, button: .primary, mods: .none, at: 2.02)
        rt.pointerDown(at: dPt, button: .primary, mods: .none, at: 2.1)
        rt.pointerMove(to: Vec2(dPt.x + 30, dPt.y), mods: .none, at: 2.12)
        rt.pointerUp(at: Vec2(dPt.x + 30, dPt.y), button: .primary, mods: .none, at: 2.14)
        #expect(rt.state.dragCount >= 2, "onDrag move must not be swallowed when pressing selectable child inside onDrag row")
        #expect(abs(rt.state.dragDeltaX - 30) < 0.5)
        #expect(rt.selectedText() == "drag", "double-click inside onDrag row still selects the word")

        // 5. Drag edge auto-scroll: drag from top row past bottom edge of scroller and advance frames
        let sStart = Vec2(r0.rect[0] + 1, r0.rect[1] + 10)
        let sBelow = Vec2(r0.rect[0] + 80, scroller.rect[1] + scroller.rect[3] + 25)
        rt.pointerDown(at: sStart, button: .primary, mods: .none, at: 3.0)
        rt.pointerMove(to: sBelow, mods: .none, at: 3.02)
        _ = rt.frame(at: 3.02)
        _ = rt.frame(at: 3.07)
        _ = rt.frame(at: 3.12)
        _ = rt.frame(at: 3.17)
        let scrolledY = rt.scrollOffsets[scroller.path]?.y ?? 0
        #expect(scrolledY > 10.0, "holding selection drag below scroll bottom must edge-scroll (got \(scrolledY))")
        let selText = rt.selectedText() ?? ""
        #expect(selText.contains("row item 0") && selText.contains("row item 4"), "edge-scroll drag selects across scrolled rows: \(selText)")
        rt.pointerUp(at: sBelow, button: .primary, mods: .none, at: 3.20)
    }
}
