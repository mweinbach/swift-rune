import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite("El & Runtime Increment 3 Parity Tests")
struct ElInc3ParityTests {

    @Test("matched: flight after earlier commit in same frame starts where element was last seen")
    func matchedFlightAfterEarlierCommitStartsWhereSeen() {
        struct S {
            var expanded = false
            var yShift: Float = 0
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(400, 300),
            pixelScale: 2.0,
            systemDark: true
        ) { (s: S, _) -> El<S> in
            if !s.expanded {
                return col()
                    .size(400, 300)
                    .pt(s.yShift).pl(20)
                    .child(
                        el()
                            .key("tile")
                            .matched("shared-card")
                            .size(80, 80)
                            .bg(Color(r: 0.2, g: 0.5, b: 0.9, a: 1))
                    )
            } else {
                return col()
                    .size(400, 300)
                    .pt(10).pl(40)
                    .child(
                        el()
                            .key("hero")
                            .matched("shared-card")
                            .size(300, 200)
                            .bg(Color(r: 0.2, g: 0.5, b: 0.9, a: 1))
                    )
            }
        }

        // Initial frame sees tile at top = 0.
        rt.frame(at: 0.0)
        // Scroll / shift and render so tile is seen at y = 120.
        rt.update(at: 0.1) { s, _ in s.yShift = 120 }
        rt.frame(at: 0.1)
        let seenRect = rt.element(byKey: "tile")!.rect
        #expect(abs(seenRect[1] - 120.0) < 1.0)

        // Commit 1 at t = 0.2 shifts layout in Scene WITHOUT rendering a frame yet.
        rt.update(at: 0.2) { s, _ in s.yShift = 20 }
        // Force commitTree before swapping by running keyDown on no-op key.
        _ = rt.keyDown(KeyEvent(key: .text("x")), at: 0.2)
        // Commit 2 in the same frame swaps to "hero" (`expanded = true`).
        rt.update(at: 0.2) { s, _ in s.expanded = true }
        rt.frame(at: 0.2 + 1.0 / 120.0)
        let flightStart = rt.element(byKey: "hero")!.rect
        #expect(abs(flightStart[1] - seenRect[1]) < 15.0, "expected start near seenRect \(seenRect), got \(flightStart)")

        // Advance halfway through flight so hero widens well past 100px before reversing.
        var midHero = flightStart
        for step in 1...10 {
            rt.frame(at: 0.2 + Double(step) * 0.01)
            midHero = rt.element(byKey: "hero")!.rect
        }
        #expect(midHero[2] > 120.0, "expected hero to expand mid-flight, got \(midHero)")

        // Reverse home mid-flight: detail -> tile starts near mid-flight hero rect.
        rt.update(at: 0.35) { s, _ in s.expanded = false }
        rt.frame(at: 0.35 + 1.0 / 120.0)
        let reverseStart = rt.element(byKey: "tile")!.rect
        #expect(reverseStart[2] > 120.0, "reverse flight should start near midHero width \(midHero), got \(reverseStart)")
    }

    @Test("matched: cover vs matchedCrop child scaling and lifted paint order")
    func matchedCoverVsCropAndLiftedPaintOrder() {
        struct S {
            var detail = false
            var crop = false
        }
        func makeRuntime(crop: Bool) -> Runtime<S> {
            Runtime<S>(
                state: S(detail: false, crop: crop),
                viewport: Vec2(400, 300),
                pixelScale: 2.0,
                systemDark: true
            ) { (s: S, _) -> El<S> in
                if !s.detail {
                    var card: El<S> = el()
                        .key("tile-0")
                        .matched("card")
                        .clip()
                        .size(100, 100)
                        .child(
                            el()
                                .key("inner")
                                .size(50, 50)
                                .bg(Color(r: 1, g: 0, b: 0, a: 1))
                        )
                    if s.crop { card = card.matchedCrop() }
                    return row()
                        .size(400, 300)
                        .child(card)
                        .child(
                            el()
                                .key("sibling")
                                .size(100, 100)
                                .bg(Color(r: 0, g: 1, b: 0, a: 1))
                        )
                } else {
                    var card: El<S> = el()
                        .key("hero")
                        .matched("card")
                        .clip()
                        .size(300, 150)
                        .child(
                            el()
                                .key("inner")
                                .size(150, 75)
                                .bg(Color(r: 1, g: 0, b: 0, a: 1))
                        )
                    if s.crop { card = card.matchedCrop() }
                    return col()
                        .size(400, 300)
                        .child(card)
                }
            }
        }

        // Cover mode scales child proportionally (150 * k ~ 100..115 on initial flight frame vs unscaled 150).
        let coverRt = makeRuntime(crop: false)
        coverRt.frame(at: 0.0)
        coverRt.update(at: 0.05) { s, _ in s.detail = true }
        coverRt.frame(at: 0.06)
        let coverInner = coverRt.element(byKey: "inner")!.rect
        #expect(coverInner[2] < 120.0, "cover child should scale down with flying parent, got \(coverInner)")

        // Crop mode keeps destination child size (150x75) centered without scaling.
        let cropRt = makeRuntime(crop: true)
        cropRt.frame(at: 0.0)
        cropRt.update(at: 0.05) { s, _ in s.detail = true }
        cropRt.frame(at: 0.06)
        let cropInner = cropRt.element(byKey: "inner")!.rect
        #expect(abs(cropInner[2] - 150.0) < 2.0, "matchedCrop child should keep unscaled width 150, got \(cropInner)")

        // Flying back into slot 0 lifts tile-0 after sibling in element order.
        for i in 1...4 {
            coverRt.frame(at: 0.06 + Double(i) * 0.05)
        }
        coverRt.update(at: 0.3) { s, _ in s.detail = false }
        coverRt.frame(at: 0.31)
        let elems = coverRt.elements()
        let tileIdx = elems.firstIndex { $0.key == "tile-0" }!
        let sibIdx = elems.firstIndex { $0.key == "sibling" }!
        #expect(tileIdx > sibIdx, "flying tile-0 should paint after sibling (tileIdx=\(tileIdx), sibIdx=\(sibIdx))")
    }

    @Test("element(byKey:) resolves hierarchical slash-separated key paths")
    func elementByKeyHierarchicalSlashPaths() {
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 120), pixelScale: 1.0) { _, _ -> El<S> in
            col()
                .key("queue")
                .child(
                    row().key("head").child(
                        el().key("skip").size(20, 20)
                    )
                )
                .child(
                    col().key("orb").child(
                        el().key("orb").size(12, 12)
                    )
                )
        }
        rt.frame(at: 0.0)
        #expect(rt.element(byKey: "queue/head/skip")?.rect[2] == 20)
        #expect(rt.element(byKey: "orb/orb")?.rect[2] == 12)
    }

    // MARK: - Increment 3b: Modal dismissal, focusReturn, role-aware focus, defaultButton, repeat guard

    private static func focusedKey<S>(in rt: Runtime<S>) -> String? {
        rt.elements().first(where: { $0.focused })?.key
    }

    // Upstream: crates/rune/src/runtime/input/focus.rs:839-860
    @Test("modal traps focus, restores nested modals, handles clickOutside, and blocks background")
    func modalTrapsRestoresNestedAndBlocksBackground() {
        struct S {
            var open = false
            var nested = false
            var selected = 0
            var picks = 0
            var secondaryPicks = 0
        }
        func btn(_ key: String) -> El<S> {
            el().key(key).size(30, 30).focusable().role(.button)
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 300), pixelScale: 2.0) { s, _ -> El<S> in
            var root: El<S> = col().key("root").size(300, 300)
                .onSecondaryClick { s, _, _ in s.secondaryPicks += 1 }
                .child(btn("opener").onClick { s, _ in s.open = true })
                .child(btn("early").tabIndex(1))
                .child(btn("skip").tabIndex(-1))
                .child(btn("disabled").focusable(false))
                .child(
                    col().key("radios").focusGroup()
                        .children((0..<3).map { i in
                            btn("radio\(i)")
                                .role(.radio)
                                .itemSelected(s.selected == i)
                                .focusable(i != 1)
                                .onClick { s, _ in s.selected = i; s.picks += 1 }
                        })
                )
            if s.open {
                root = root.child(
                    col().key("modal").pin(top: 0, left: 100).size(100, 120)
                        .modal(clickOutside: true) { s in s.open = false }
                        .child(btn("one").onClick { s, _ in s.nested = true })
                        .child(btn("two"))
                )
            }
            if s.open && s.nested {
                root = root.child(
                    col().key("nested").pin(top: 0, left: 200).size(90, 90)
                        .modal(clickOutside: false) { s in s.nested = false }
                        .child(btn("inner"))
                )
            }
            return root
        }

        rt.frame(at: 0.0)
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.0); rt.frame(at: 0.0)
        #expect(Self.focusedKey(in: rt) == "early", "tabIndex(1) comes first")
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.0); rt.frame(at: 0.0)
        #expect(Self.focusedKey(in: rt) == "opener")
        _ = rt.keyDown(KeyEvent(key: .space), at: 0.0); rt.frame(at: 0.0)
        #expect(Self.focusedKey(in: rt) == "one")

        let oneRect = rt.element(byKey: "one")!.rect
        let oneCenter = Vec2(oneRect[0] + oneRect[2] * 0.5, oneRect[1] + oneRect[3] * 0.5)
        rt.pointerDown(at: oneCenter, button: .secondary, at: 0.0)
        rt.pointerUp(at: oneCenter, button: .secondary, at: 0.0)
        rt.frame(at: 0.0)
        #expect(rt.state.secondaryPicks == 0, "secondary events must not bubble past modal")

        _ = rt.keyDown(KeyEvent(key: .tab, mods: Mods(shift: true)), at: 0.0); rt.frame(at: 0.0)
        #expect(Self.focusedKey(in: rt) == "two")
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.0); rt.frame(at: 0.0)
        #expect(Self.focusedKey(in: rt) == "one")
        _ = rt.keyDown(KeyEvent(key: .space), at: 0.0); rt.frame(at: 0.0)
        #expect(Self.focusedKey(in: rt) == "inner")

        // Click outside nested (clickOutside: false) must keep nested open and inner focused!
        let opRect = rt.element(byKey: "opener")!.rect
        let opCenter = Vec2(opRect[0] + opRect[2] * 0.5, opRect[1] + opRect[3] * 0.5)
        rt.pointerDown(at: opCenter, at: 0.0); rt.pointerUp(at: opCenter, at: 0.0)
        rt.frame(at: 0.0)
        #expect(rt.state.nested)
        #expect(Self.focusedKey(in: rt) == "inner")

        // Held Escape repeat must NOT cascade through stacked modals!
        #expect(rt.keyDown(KeyEvent(key: .escape), isRepeat: true, at: 0.0))
        #expect(rt.state.nested && rt.state.open)

        // Fresh Escape dismisses nested -> restores "one", then dismisses modal -> restores "opener".
        _ = rt.keyDown(KeyEvent(key: .escape), at: 0.0); rt.frame(at: 0.0)
        #expect(!rt.state.nested && rt.state.open)
        #expect(Self.focusedKey(in: rt) == "one")
        _ = rt.keyDown(KeyEvent(key: .escape), at: 0.0); rt.frame(at: 0.0)
        #expect(!rt.state.open)
        #expect(Self.focusedKey(in: rt) == "opener")

        // Reopen modal and click outside scrim at (5, 280) -> dismisses modal, restores opener, hides focus ring.
        _ = rt.keyDown(KeyEvent(key: .space), at: 0.0); rt.frame(at: 0.0)
        #expect(rt.state.open)
        rt.pointerDown(at: Vec2(5, 280), at: 0.0); rt.pointerUp(at: Vec2(5, 280), at: 0.0)
        rt.frame(at: 0.0)
        #expect(!rt.state.open)
        #expect(Self.focusedKey(in: rt) == "opener")
        #expect(!rt.elements().contains { $0.focusVisible })
    }

    // Upstream: crates/rune/src/runtime/input/focus.rs:863-888
    @Test("modal whose field opens focused returns focus to opener on close and Escape")
    func modalWhoseFieldOpensFocusedReturnsFocusToOpener() {
        struct Form {
            var open = false
            var field = TextEdit("")
            var fieldFocused = false
        }
        for useEscape in [false, true] {
            let rt = Runtime<Form>(state: Form(), viewport: Vec2(300, 300), pixelScale: 1.0) { s, _ -> El<Form> in
                var root: El<Form> = col().key("root").size(300, 300)
                    .child(
                        el().key("opener").size(40, 24).focusable().role(.button)
                            .onClick { (s: inout Form, _) in
                                s.open = true
                                s.fieldFocused = true
                            }
                    )
                if s.open {
                    root = root.child(
                        col().key("sheet").pin(top: 0, left: 100).size(150, 100)
                            .modal(clickOutside: true) { (s: inout Form) in
                                s.open = false
                                s.fieldFocused = false
                            }
                            .child(
                                textInput(key: "field", \Form.field)
                                    .font(TextStyle(size: 14))
                                    .size(120, 30)
                                    .focused(s.fieldFocused)
                            )
                    )
                }
                return root
            }
            rt.frame(at: 0.0)
            let r = rt.element(byKey: "opener")!.rect
            let pt = Vec2(r[0] + r[2] * 0.5, r[1] + r[3] * 0.5)
            rt.pointerDown(at: pt, at: 0.0); rt.pointerUp(at: pt, at: 0.0)
            rt.frame(at: 0.0)
            #expect(rt.state.open)
            #expect(Self.focusedKey(in: rt) == "field")

            if useEscape {
                _ = rt.keyDown(KeyEvent(key: .escape), at: 0.0)
                #expect(!rt.state.fieldFocused, "Escape blurs field before closing")
                rt.frame(at: 0.0)
            } else {
                rt.update(at: 0.0) { s, _ in
                    s.open = false
                    s.fieldFocused = false
                }
                rt.frame(at: 0.0)
            }
            #expect(!rt.state.open)
            #expect(Self.focusedKey(in: rt) == "opener")
        }
    }

    // Upstream: crates/rune/src/runtime/input/focus.rs:891-923
    @Test("closing a modal keeps an explicit focus request outside it")
    func closingModalKeepsFocusRequestOutsideIt() {
        struct Form {
            var open = false
            var field = TextEdit("")
            var fieldFocused = false
            var search = TextEdit("")
            var searchFocused = false
        }
        let rt = Runtime<Form>(state: Form(), viewport: Vec2(300, 300), pixelScale: 1.0) { s, _ -> El<Form> in
            var root: El<Form> = col().key("root").size(300, 300)
                .child(
                    el().key("opener").size(40, 24).focusable().role(.button)
                        .onClick { s, _ in s.open = true; s.fieldFocused = true }
                )
                .child(
                    textInput(key: "search", \Form.search)
                        .font(TextStyle(size: 14))
                        .size(120, 30)
                        .focused(s.searchFocused)
                )
            if s.open {
                root = root.child(
                    col().key("sheet").pin(top: 100, left: 100).size(150, 100)
                        .modal(clickOutside: true) { (s: inout Form) in
                            s.open = false
                            s.fieldFocused = false
                        }
                        .child(
                            textInput(key: "field", \Form.field)
                                .font(TextStyle(size: 14))
                                .size(120, 30)
                                .focused(s.fieldFocused)
                        )
                )
            }
            return root
        }
        rt.frame(at: 0.0)
        let r = rt.element(byKey: "opener")!.rect
        let pt = Vec2(r[0] + r[2] * 0.5, r[1] + r[3] * 0.5)
        rt.pointerDown(at: pt, at: 0.0); rt.pointerUp(at: pt, at: 0.0)
        rt.frame(at: 0.0)
        #expect(Self.focusedKey(in: rt) == "field")

        rt.update(at: 0.0) { s, _ in
            s.open = false
            s.fieldFocused = false
            s.searchFocused = true
        }
        rt.frame(at: 0.0)
        #expect(Self.focusedKey(in: rt) == "search")
    }

    // Upstream: crates/rune/src/runtime/input/focus.rs:1179-1230
    @Test("Return presses defaultButton while Space presses focused control and onTextSubmit wins")
    func returnPressesDefaultButtonAndSpaceFocusedButton() {
        struct S {
            var field = TextEdit("")
            var named = TextEdit("")
            var log: [String] = []
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 300), pixelScale: 1.0) { s, _ -> El<S> in
            col().size(300, 300)
                .child(
                    textInput(key: "field", \S.field)
                        .font(TextStyle(size: 14))
                        .size(100, 20)
                )
                .child(
                    textInput(key: "named", \S.named)
                        .font(TextStyle(size: 14))
                        .size(100, 20)
                        .onSubmit { s, _, _ in s.log.append("submit") }
                )
                .child(
                    col().key("list").role(.listbox).focusGroup()
                        .child(el().key("row").size(80, 20).focusable().role(.listItem).onClick { s, _ in s.log.append("row") })
                )
                .child(el().key("later").size(60, 20).focusable().role(.button).onClick { s, _ in s.log.append("later") })
                .child(el().key("continue").size(60, 20).focusable().role(.button).defaultButton().onClick { s, _ in s.log.append("continue") })
                .child(el().key("hidden").size(60, 20).focusable().role(.button).defaultButton().opacity(0).onClick { s, _ in s.log.append("hidden") })
        }
        rt.frame(at: 0.0)
        // Focus field (no onSubmit) -> Return hits defaultButton ("continue")
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.0); rt.frame(at: 0.0)
        #expect(Self.focusedKey(in: rt) == "field")
        _ = rt.keyDown(KeyEvent(key: .enter), at: 0.0); rt.frame(at: 0.0)
        // Focus named (has onSubmit) -> Return fires onSubmit
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.0); rt.frame(at: 0.0)
        #expect(Self.focusedKey(in: rt) == "named")
        _ = rt.keyDown(KeyEvent(key: .enter), at: 0.0); rt.frame(at: 0.0)
        // Focus list row -> Return activates row
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.0); rt.frame(at: 0.0)
        #expect(Self.focusedKey(in: rt) == "row")
        _ = rt.keyDown(KeyEvent(key: .enter), at: 0.0); rt.frame(at: 0.0)
        // Focus later button -> Return hits defaultButton ("continue"), Space hits "later"
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.0); rt.frame(at: 0.0)
        #expect(Self.focusedKey(in: rt) == "later")
        _ = rt.keyDown(KeyEvent(key: .enter), at: 0.0); rt.frame(at: 0.0)
        _ = rt.keyDown(KeyEvent(key: .space), at: 0.0); rt.frame(at: 0.0)
        #expect(rt.state.log == ["continue", "submit", "row", "continue", "later"])
    }

    @Test("focusGroup collapses to single tab stop and re-enters on itemSelected + focusReturn")
    func focusGroupSingleTabStopAndFocusReturn() {
        struct S {
            var open = false
            var selected = 1
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 240), pixelScale: 1.0) { s, _ -> El<S> in
            var root: El<S> = col().size(300, 240)
                .child(el().key("before").size(40, 20).focusable().role(.button).onClick { s, _ in s.open = true })
                .child(
                    col().key("list").focusGroup()
                        .children((0..<3).map { i in
                            el().key("item-\(i)").size(80, 20).focusable().role(.listItem)
                                .itemSelected(s.selected == i)
                        })
                )
                .child(el().key("after").size(40, 20).focusable().role(.button))
            if s.open {
                root = root.child(
                    el().key("popover").size(60, 40).focusReturn("before")
                        .anchored("before", side: .bottom)
                        .child(el().key("opt").size(50, 20).focusable().autofocus())
                )
            }
            return root
        }
        rt.frame(at: 0.0)
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.0); rt.frame(at: 0.0)
        #expect(Self.focusedKey(in: rt) == "before")
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.0); rt.frame(at: 0.0)
        #expect(Self.focusedKey(in: rt) == "item-1", "Tab enters focusGroup on itemSelected member")
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.0); rt.frame(at: 0.0)
        #expect(Self.focusedKey(in: rt) == "after", "Tab leaves focusGroup in a single stop")
        _ = rt.keyDown(KeyEvent(key: .tab, mods: Mods(shift: true)), at: 0.0); rt.frame(at: 0.0)
        #expect(Self.focusedKey(in: rt) == "item-1", "Shift+Tab re-enters focusGroup on itemSelected member")

        // Open anchored popover with autofocus + focusReturn("before"); closing returns focus to "before"
        rt.update(at: 0.0) { s, _ in s.open = true }
        // Blur current focus so autofocus inside popover applies cleanly
        rt.update(at: 0.0) { _, tx in tx.blur() }
        rt.frame(at: 0.0)
        #expect(Self.focusedKey(in: rt) == "opt")
        rt.update(at: 0.0) { s, _ in s.open = false }
        rt.frame(at: 0.0)
        #expect(Self.focusedKey(in: rt) == "before")
    }

    // MARK: - Increment 3c: Tooltips (`El.help`, `HelpLook`, `helpRow`/`helpKeys`/`helpSide`/`helpWhenTruncated`)

    // Upstream: crates/rune/src/runtime/input/help.rs:599-615
    @Test("native help regions skip modal background and occluded popover parts, and helpRectSubtract works")
    func nativeHelpRegionsAndSubtractParity() {
        #expect(
            helpRectSubtract(SIMD4<Float>(0, 0, 10, 10), SIMD4<Float>(20, 0, 30, 10))
                == [SIMD4<Float>(0, 0, 10, 10)]
        )
        #expect(
            helpRectSubtract(SIMD4<Float>(0, 0, 10, 10), SIMD4<Float>(-1, -1, 11, 11)).isEmpty
        )
        #expect(
            helpRectSubtract(SIMD4<Float>(0, 0, 10, 10), SIMD4<Float>(4, 4, 6, 6)).count == 4
        )

        struct S { var modal = false; var cover = false }
        func runNative(_ s: S) -> Runtime<S> {
            let rt = Runtime<S>(state: s, viewport: Vec2(300, 300), pixelScale: 2.0) { st, _ -> El<S> in
                var root: El<S> = el().wFull().hFull()
                    .child(el().key("copy").size(40, 20).pin(top: 20, left: 20).help("Copy"))
                    .child(el().key("low").size(40, 20).pin(top: 200, left: 20).help("Low"))
                if st.cover {
                    // Interactive popover drawn over the right half of "copy" (x: 40..140, y: 10..70)
                    root = root.child(
                        el().key("pop").size(100, 60).pin(top: 10, left: 40)
                            .onClick { _, _ in }
                    )
                }
                if st.modal {
                    root = root.child(
                        row().key("sheet").size(80, 40).pin(top: 200, left: 200)
                            .modal(clickOutside: false) { _ in }
                            .child(el().key("inside").size(30, 20).help("Inside"))
                    )
                }
                return root
            }
            rt.nativeHelp = true
            rt.frame(at: 0.0)
            return rt
        }

        #expect(runNative(S()).helpRegions().map(\.text) == ["Copy", "Low"])
        #expect(runNative(S(modal: true)).helpRegions().map(\.text) == ["Inside"])
        let copyParts = runNative(S(cover: true)).helpRegions().filter { $0.text == "Copy" }.map(\.rect)
        #expect(copyParts == [SIMD4<Float>(20, 20, 40, 40)], "only uncovered left half remains")
    }

    // Upstream: crates/rune/src/runtime/input/help.rs:617-628 + Tip state machine tests
    @Test("tooltip waits for helpDelay, wakes on hover, uses HelpLook skipDelay, and dismisses on input or cover")
    func tooltipHoverDelaySkipDelayAndDismissals() {
        struct S { var customLook = false; var cover = false; var modal = false }
        let rt = Runtime<S>(state: S(), viewport: Vec2(320, 240), pixelScale: 2.0) { st, cx -> El<S> in
            if st.customLook {
                cx.setHelpLook(
                    HelpLook.system(dark: true)
                        .delay(0.3)
                        .skipDelay(0.4)
                        .fade(enter: 0.1, exit: 0.1, scale: 0.92)
                )
            }
            var root: El<S> = col().size(320, 240)
                .child(el().key("first").pin(top: 20, left: 20).size(40, 20).help("First"))
                .child(el().key("second").pin(top: 20, left: 100).size(40, 20).help("Second"))
            if st.cover {
                root = root.child(el().key("pop").pin(top: 10, left: 40).size(60, 40).onClick { _, _ in })
            }
            if st.modal {
                root = root.child(
                    el().key("sheet").pin(top: 120, left: 120).size(80, 40)
                        .modal(clickOutside: false) { st in st.modal = false }
                )
            }
            return root
        }

        rt.frame(at: 0.0)
        #expect(!rt.helpTargetChanges(at: Vec2(200, 200)))
        #expect(rt.helpTargetChanges(at: Vec2(30, 30)))

        rt.pointerMove(to: Vec2(30, 30), at: 1.0 / 60.0)
        rt.frame(at: 1.0 / 60.0)
        #expect(rt.helpTooltip() == nil)
        let wake = rt.nextWakeDeadline(after: 1.0 / 60.0)
        #expect(wake != nil && abs(wake! - (1.0 / 60.0 + rt.helpDelay)) < 1e-4)

        rt.frame(at: 1.0 / 60.0 + rt.helpDelay)
        #expect(rt.helpTooltip()?.text == "First")
        let tipRect = rt.helpTooltip()!.rect
        #expect(tipRect.y >= 40.0, "default placement sits below element (y+h = 40)")

        // Key press hides tooltip until pointer leaves and returns
        _ = rt.keyDown(KeyEvent(key: .space), at: 1.0)
        rt.frame(at: 1.0)
        #expect(rt.helpTooltip() == nil)
        rt.frame(at: 2.0)
        #expect(rt.helpTooltip() == nil, "stays suppressed while still on element")

        // Moving away clears suppression; moving under interactive cover does not open it
        rt.pointerMove(to: Vec2(200, 200), at: 2.1)
        rt.frame(at: 2.1)
        rt.update(at: 2.2) { s, _ in s.customLook = true; s.cover = true }
        rt.frame(at: 2.2)
        rt.pointerMove(to: Vec2(50, 30), at: 2.3) // covered right half of "first"
        rt.frame(at: 2.3); rt.frame(at: 3.0)
        #expect(rt.helpTooltip() == nil, "interactive cover suppresses tooltip")

        // Move onto uncovered left side with custom look (delay 0.3, skipDelay 0.4), wait 0.3s, then hop to "second"
        rt.update(at: 3.1) { s, _ in s.cover = false }
        rt.pointerMove(to: Vec2(30, 30), at: 3.1)
        rt.frame(at: 3.1)
        rt.frame(at: 3.45)
        #expect(rt.helpTooltip()?.text == "First")

        // Move off briefly (to Warm), then onto "second" within 0.4s skipDelay -> opens immediately!
        rt.pointerMove(to: Vec2(200, 200), at: 3.5)
        rt.frame(at: 3.5)
        rt.pointerMove(to: Vec2(110, 30), at: 3.6)
        rt.frame(at: 3.6)
        #expect(rt.helpTooltip()?.text == "Second", "warm skipDelay opens next tooltip without waiting")

        // Modal opening suppresses the tooltip beneath it
        rt.update(at: 3.7) { s, _ in s.modal = true }
        rt.frame(at: 3.7)
        #expect(rt.helpTooltip() == nil)
    }

    @Test("helpRow, helpKeys, helpAbove/helpSide placement, and helpWhenTruncated")
    func tooltipRowsKeycapsSideAndTruncated() {
        struct S { var wideText = false }
        let rt = Runtime<S>(state: S(), viewport: Vec2(400, 300), pixelScale: 2.0) { st, _ -> El<S> in
            col().size(400, 300)
                .child(
                    el().key("above").pin(top: 120, left: 100).size(60, 24)
                        .help("Save").helpKeys(["Cmd", "S"])
                        .helpRow("Send").helpKeys(["Ctrl", "Enter"])
                        .helpAbove()
                )
                .child(
                    el().key("rightTip").pin(top: 120, left: 20).size(40, 24)
                        .help("Sideways").helpSide(.right)
                )
                .child(
                    text("Very long label that definitely overflows narrow box")
                        .key("trunc")
                        .pin(top: 220, left: 20)
                        .size(st.wideText ? 380 : 60, 20)
                        .ellipsis()
                        .helpWhenTruncated("Very long label that definitely overflows narrow box")
                )
        }
        rt.helpDelay = 0.0
        rt.frame(at: 0.0)

        // Multi-row + keycaps normalized text in ElementInfo + above placement
        #expect(rt.element(byKey: "above")?.help == "Save Cmd S\nSend Ctrl Enter")
        rt.pointerMove(to: Vec2(120, 130), at: 0.1)
        let scene = rt.frame(at: 0.1)
        let aboveTip = rt.helpTooltip()
        #expect(aboveTip?.text == "Save Cmd S\nSend Ctrl Enter")
        #expect(aboveTip!.rect.y + aboveTip!.rect.w <= 120.0, "helpAbove sits clear above element at y=120")
        #expect(scene.primitives.contains { Int($0.params.y.rounded()) == PrimitiveKind.glyph.rawValue })

        // Right-side placement sits to the right of element (x+w = 60)
        rt.pointerMove(to: Vec2(40, 130), at: 0.2)
        rt.frame(at: 0.2)
        let rightTip = rt.helpTooltip()
        #expect(rightTip?.text == "Sideways")
        #expect(rightTip!.rect.x >= 60.0)

        // helpWhenTruncated: active while narrow/truncated, absent when wide enough to fit!
        #expect(rt.element(byKey: "trunc")?.help == "Very long label that definitely overflows narrow box")
        rt.pointerMove(to: Vec2(40, 230), at: 0.3)
        rt.frame(at: 0.3)
        #expect(rt.helpTooltip()?.text == "Very long label that definitely overflows narrow box")

        rt.update(at: 0.4) { s, _ in s.wideText = true }
        rt.frame(at: 0.4)
        #expect(rt.element(byKey: "trunc")?.help == nil)
        #expect(rt.helpTooltip() == nil)
    }
}
