import Testing
import Foundation
@testable import Rune
import RuneRef

@Suite("Slice 4 Focus, ModalFocus, Physical Input, and OnKey Wave 3 Parity")
@MainActor
struct Slice4FocusAndInputWave3Tests {

    private func focusedKey<S>(in rt: Runtime<S>) -> String? {
        rt.elements().first(where: { $0.focused })?.key
    }

    private func centerOf<S>(key: String, in rt: Runtime<S>) -> Vec2 {
        let r = rt.element(byKey: key)!.rect
        return Vec2(r[0] + r[2] * 0.5, r[1] + r[3] * 0.5)
    }

    private func clickKey<S>(_ key: String, in rt: Runtime<S>, at t: Double) {
        let pt = centerOf(key: key, in: rt)
        rt.pointerMove(to: pt, at: t)
        rt.pointerDown(at: pt, at: t)
        rt.pointerUp(at: pt, at: t)
        _ = rt.frame(at: t)
    }

    private func pressKey<S>(_ rt: Runtime<S>, _ key: Key, mods: Mods = .none, isRepeat: Bool = false, at t: Double) {
        _ = rt.keyDown(KeyEvent(key: key, mods: mods), isRepeat: isRepeat, at: t)
        _ = rt.frame(at: t)
    }

    // MARK: - 1. Focus transfer, IME handover, virtual inputs, scrim return (`focus.rs:695-964`)

    @Test("focus.rs:695,724: same-frame state focus routes key to new field; hidden hides IME; finishComposition keeps text & focus")
    func stateFocusRoutesSameFrameKeyAndWindowBlurKeepsText() {
        struct Form {
            var first = TextEdit("")
            var next = TextEdit("")
            var firstFocused = false
            var nextFocused = false
            var open = false
            var hidden = false
        }
        let rt = Runtime(state: Form(), viewport: Vec2(200, 120), pixelScale: 1.0) { (s: Form, _: inout Cx<Form>) -> El<Form> in
            var c: El<Form> = col().size(200, 120)
                .child(textInput(key: "first", \Form.first).font(TextStyle(size: 14)).size(200, 40).focused(s.firstFocused))
            if s.open {
                c = c.child(
                    textInput(key: "next", \Form.next).font(TextStyle(size: 14)).size(200, 40)
                        .focused(s.nextFocused)
                        .opacity(s.hidden ? 0.0 : 1.0)
                )
            }
            return c
        }
        rt.update(at: 0.0) { s, _ in s.firstFocused = true }
        _ = rt.frame(at: 0.0)

        rt.update(at: 0.01) { s, _ in
            s.open = true
            s.firstFocused = false
            s.nextFocused = true
        }
        _ = rt.keyDown(KeyEvent(key: .text("x")), at: 0.01)
        _ = rt.frame(at: 0.01)
        #expect(focusedKey(in: rt) == "next")
        #expect(rt.state.next.text == "x", "the first key must not route to old frame's focus")
        #expect(rt.state.first.text == "")
        #expect(rt.imeArea != nil)

        rt.update(at: 0.02) { s, _ in s.hidden = true }
        _ = rt.frame(at: 0.02)
        #expect(rt.imeArea == nil, "opacity 0 hidden inputs must not expose IME area")

        // Window blur (`finishComposition`) commits pending preedit while keeping focus.
        struct EditFocus {
            var edit = TextEdit("committed")
            var focused = false
        }
        let editRt = Runtime(state: EditFocus(), viewport: Vec2(200, 40), pixelScale: 1.0) { (s: EditFocus, _: inout Cx<EditFocus>) -> El<EditFocus> in
            textInput(key: "field", \EditFocus.edit).font(TextStyle(size: 14)).size(200, 40).focused(s.focused)
        }
        editRt.update(at: 0.0) { s, _ in s.focused = true }
        _ = editRt.frame(at: 0.0)
        _ = editRt.dispatchImeEvent(.preedit("pending", cursorUTF8: nil, clauses: []), at: 0.01)
        _ = editRt.frame(at: 0.01)
        _ = editRt.consumeImeReset()
        editRt.finishComposition(at: 0.02)
        _ = editRt.frame(at: 0.02)
        #expect(editRt.state.edit.preedit == nil && editRt.focusedKey == "field")
        #expect(editRt.state.edit.text == "committedpending")
    }

    @Test("focus.rs:739,769: unrealized virtual input keeps focus; input handover commits preedit and keys bubble")
    func unrealizedVirtualInputAndInputHandoverParity() {
        struct VirtS {
            var edits: [TextEdit] = (0..<100).map { _ in TextEdit("") }
        }
        let vRt = Runtime(state: VirtS(), viewport: Vec2(200, 240), pixelScale: 1.0) { s, _ in
            col().key("root").size(200, 240)
                .child(el().key("other").size(80, 30).focusable().onClick { _ in })
                .child(
                    col().key("vp").size(200, 200).scroll(ScrollSpec(stickBottom: false))
                        .child(
                            col().key("rows").wFull().virtualRows(
                                count: s.edits.count,
                                estimatedRowHeight: 40,
                                key: { _, i in "row-\(i)" },
                                build: { _, i in
                                    textInput(key: "row-\(i)", \VirtS.edits[i]).font(TextStyle(size: 14)).size(200, 40)
                                }
                            )
                        )
                )
        }
        vRt.update(at: 0.0) { _, tx in tx.focus("row-0") }
        _ = vRt.frame(at: 0.0)
        vRt.wheel(WheelEvent(dy: -2000), at: Vec2(100, 100), now: 0.01)
        _ = vRt.frame(at: 0.01)
        #expect(vRt.element(byKey: "row-0") == nil, "row-0 culled offscreen")
        #expect(vRt.focusedKey == "row-0", "culled virtual input preserves focus")
        clickKey("other", in: vRt, at: 0.02)
        vRt.wheel(WheelEvent(dy: 2000), at: Vec2(100, 100), now: 0.03)
        _ = vRt.frame(at: 0.03)
        #expect(focusedKey(in: vRt) == "other", "returning row does not steal focus back")

        // Handover preedit commit + unhandled key bubbling + outside pointer-down blur.
        struct Handover {
            var first = TextEdit("hello")
            var search = TextEdit("")
            var open = false
            var appKeys = 0
        }
        let hRt = Runtime(state: Handover(), viewport: Vec2(300, 300), pixelScale: 1.0) { (s: Handover, _: inout Cx<Handover>) -> El<Handover> in
            var c: El<Handover> = col().size(300, 300)
                .child(textInput(key: "first", \Handover.first).font(TextStyle(size: 14)).size(200, 40))
                .child(el().key("open").size(80, 30).focusable().onClick { st, tx in st.open = true; tx.focus("search") })
            if s.open {
                c = c.child(textInput(key: "search", \Handover.search).font(TextStyle(size: 14)).size(200, 40))
            }
            return c
        }
        hRt.globalOnKey = { s, _, _ in s.appKeys += 1; return true }
        hRt.update(at: 0.0) { _, tx in tx.focus("first") }
        _ = hRt.frame(at: 0.0)
        _ = hRt.dispatchImeEvent(.preedit("pending", cursorUTF8: nil, clauses: []), at: 0.01)
        _ = hRt.frame(at: 0.01)
        hRt.update(at: 0.02) { s, tx in
            s.open = true
            tx.focus("search")
        }
        _ = hRt.frame(at: 0.02)
        #expect(focusedKey(in: hRt) == "search")
        #expect(hRt.state.first.text == "hellopending", "handover commits prior field's preedit")
        #expect(hRt.state.first.preedit == nil)

        pressKey(hRt, .text("q"), at: 0.03)
        #expect(hRt.state.search.text == "q")
        #expect(hRt.state.appKeys == 0)
        pressKey(hRt, .f(5), at: 0.04)
        #expect(hRt.state.appKeys == 1, "unhandled F5 bubbles out of text field to app onKey")
        _ = hRt.dispatchImeEvent(.preedit("tail", cursorUTF8: nil, clauses: []), at: 0.05)
        hRt.pointerDown(at: Vec2(290, 290), at: 0.06)
        hRt.pointerUp(at: Vec2(290, 290), at: 0.06)
        _ = hRt.frame(at: 0.06)
        #expect(focusedKey(in: hRt) == nil)
        #expect(hRt.state.search.text == "qtail")
    }

    @Test("focus.rs:826,925,940: click hides ring until navigation; sized leaf return ignores siblings; scrim survives pointer-down blur but not tx.blur")
    func ringVisibilityAndFocusReturnScopesParity() {
        struct Radio {
            var selected = 0
        }
        let rRt = Runtime(state: Radio(), viewport: Vec2(200, 120), pixelScale: 1.0) { _, _ in
            row().size(200, 120).child(
                col().key("rg").role(.radiogroup).focusGroup().children(
                    (0..<3).map { i in
                        el().key("radio\(i)").size(40, 20).focusable().role(.radio)
                            .onClick { s, _ in s.selected = i }
                    }
                )
            )
        }
        _ = rRt.frame(at: 0.0)
        clickKey("radio0", in: rRt, at: 0.01)
        #expect(focusedKey(in: rRt) == "radio0")
        for k: Key in [.space, .escape, .text("x")] {
            pressKey(rRt, k, at: 0.02)
            #expect(!rRt.elements().contains(where: { $0.focusVisible }), "\(k) must not reveal ring after click")
        }
        pressKey(rRt, .arrowRight, at: 0.03)
        #expect(focusedKey(in: rRt) == "radio1")
        #expect(rRt.elements().contains(where: { $0.focused && $0.focusVisible }))

        // Sized focusReturn leaf must not steal sibling focus.
        let sRt = Runtime(state: true, viewport: Vec2(200, 120), pixelScale: 1.0) { (open: Bool, _: inout Cx<Bool>) -> El<Bool> in
            var c: El<Bool> = col().size(200, 120)
                .child(el().key("opener").size(60, 20).focusable())
                .child(el().key("sibling").size(60, 20).focusable())
            if open {
                c = c.child(el().key("marker").size(10, 10).focusReturn("opener"))
            }
            return c
        }
        _ = sRt.frame(at: 0.0)
        clickKey("sibling", in: sRt, at: 0.01)
        sRt.update(at: 0.02) { open, _ in open = false }
        _ = sRt.frame(at: 0.02)
        #expect(focusedKey(in: sRt) == "sibling")

        // Scrim return survives pointerDown blur, but explicit tx.blur() disarms it.
        struct Scrim {
            var open = true
            var field = TextEdit("text")
            var fieldFocused = true
        }
        for explicitBlur in [false, true] {
            let rt = Runtime(state: Scrim(), viewport: Vec2(300, 200), pixelScale: 1.0) { (s: Scrim, _: inout Cx<Scrim>) -> El<Scrim> in
                var c: El<Scrim> = col().size(300, 200)
                    .child(el().key("opener").size(80, 30).focusable())
                if s.open {
                    c = c.child(
                        col().key("popup").focusReturn("opener").child(
                            textInput(key: "field", \Scrim.field).font(TextStyle(size: 14)).size(100, 30).focused(s.fieldFocused)
                        )
                    )
                }
                return c.child(el().key("scrim").size(100, 30).onClick { st, _ in st.open = false }.focusable(false))
            }
            _ = rt.frame(at: 0.0)
            #expect(focusedKey(in: rt) == "field")
            let scrimPt = centerOf(key: "scrim", in: rt)
            rt.pointerDown(at: scrimPt, at: 0.01)
            rt.update(at: 0.01) { st, _ in st.fieldFocused = false }
            _ = rt.frame(at: 0.01)
            #expect(focusedKey(in: rt) == nil)
            if explicitBlur {
                rt.update(at: 0.02) { _, tx in tx.blur() }
                _ = rt.frame(at: 0.02)
            }
            rt.pointerUp(at: scrimPt, at: 0.03)
            _ = rt.frame(at: 0.03)
            #expect(!rt.state.open)
            if explicitBlur {
                #expect(focusedKey(in: rt) == nil)
            } else {
                #expect(focusedKey(in: rt) == "opener")
            }
        }
    }

    // MARK: - 2. Menu arrows, hidden highlight, TypeSelect, search focusFollows, combobox (`focus.rs:1007-1085,1489`)

    @Test("focus.rs:1007,1030,1041,1057,1075,1489: menu wrap, hidden highlight, type-select, search & focusFollows")
    func menuNavigationTypeSelectSearchAndFocusFollows() {
        struct MenuS {
            var open = false
            var checked: Int? = nil
            var picks: [Int] = []
            var follows = false
            var search = false
            var opens = 0
            var query = TextEdit("")
        }
        let items = ["Alpha", "Beta", "Bravo", "Charlie"]
        func makeMenuRt(_ initial: MenuS) -> Runtime<MenuS> {
            Runtime(state: initial, viewport: Vec2(300, 300), pixelScale: 1.0) { (s: MenuS, _: inout Cx<MenuS>) -> El<MenuS> in
                var root: El<MenuS> = col().key("root").size(300, 300)
                    .child(
                        el().key("popup").size(80, 24).focusable().role(.combobox)
                            .onClick { st, _ in st.opens += 1; st.open = true }
                    )
                    .child(el().key("plain").size(80, 24).focusable())
                if s.open {
                    var menuCol: El<MenuS> = col().key("menu").role(.menu).focusGroup()
                    if s.follows { menuCol = menuCol.focusFollows() }
                    menuCol = menuCol.children(items.enumerated().map { idx, title in
                        el().key(title).label(title).size(80, 20).focusable()
                            .focusSelected(s.checked == idx)
                            .focusHighlight(Color.white)
                            .onClick { st, _ in
                                st.picks.append(idx)
                                if !st.follows { st.open = false }
                            }
                    })
                    var surface = col().key("surface").pin(top: 100, left: 100).size(120, 120)
                        .modal(clickOutside: true) { (st: inout MenuS) in st.open = false }
                        .focusReturn("popup")
                    if s.search {
                        surface = surface.child(
                            textInput(key: "field", \MenuS.query).font(TextStyle(size: 14)).size(100, 24).autofocus()
                        )
                    }
                    surface = surface.child(menuCol)
                    root = root.child(surface)
                }
                return root
            }
        }

        // 1. Pointer-opened menu hides highlight until arrow/hover/type-select; Escape restores without ring (`focus.rs:1007,1489`).
        let rt1 = makeMenuRt(MenuS())
        _ = rt1.frame(at: 0.0)
        clickKey("popup", in: rt1, at: 0.01)
        #expect(rt1.state.open && focusedKey(in: rt1) == "Alpha")
        #expect(rt1.highlightedElementKey() == nil, "pointer-opened menu starts with hidden highlight")
        for heldKey: Key in [.enter, .space] {
            pressKey(rt1, heldKey, at: 0.02)
            pressKey(rt1, heldKey, isRepeat: true, at: 0.03)
            #expect(rt1.highlightedElementKey() == nil, "Return/Space on hidden highlight does not reveal")
        }
        #expect(rt1.state.open && rt1.state.picks.isEmpty)

        pressKey(rt1, .arrowDown, at: 0.04)
        #expect(rt1.highlightedElementKey() == "Alpha")
        pressKey(rt1, .arrowDown, at: 0.05); #expect(focusedKey(in: rt1) == "Beta")
        pressKey(rt1, .arrowRight, at: 0.06); #expect(focusedKey(in: rt1) == "Beta", "Left/Right ignored in menu")
        pressKey(rt1, .arrowLeft, at: 0.07); #expect(focusedKey(in: rt1) == "Beta")
        pressKey(rt1, .end, at: 0.08); #expect(focusedKey(in: rt1) == "Charlie")
        pressKey(rt1, .arrowDown, at: 0.09); #expect(focusedKey(in: rt1) == "Alpha", "wraps forward")
        pressKey(rt1, .arrowUp, at: 0.10); #expect(focusedKey(in: rt1) == "Charlie", "wraps backward")
        pressKey(rt1, .home, at: 0.11); #expect(focusedKey(in: rt1) == "Alpha")
        #expect(rt1.state.picks.isEmpty)
        pressKey(rt1, .escape, at: 0.12)
        #expect(!rt1.state.open && focusedKey(in: rt1) == "popup")
        #expect(!rt1.elements().contains(where: { $0.focusVisible }), "pointer menu closes without restoring focus ring")

        // 2. Hidden highlight opens on checked item, or end on ArrowUp (`focus.rs:1030`).
        let rtChecked = makeMenuRt(MenuS(checked: 2))
        _ = rtChecked.frame(at: 0.0)
        clickKey("popup", in: rtChecked, at: 0.01)
        #expect(focusedKey(in: rtChecked) == "Bravo")
        pressKey(rtChecked, .arrowUp, at: 0.02)
        #expect(focusedKey(in: rtChecked) == "Bravo", "reveals checked item")

        let rtEnd = makeMenuRt(MenuS())
        _ = rtEnd.frame(at: 0.0)
        clickKey("popup", in: rtEnd, at: 0.01)
        pressKey(rtEnd, .arrowUp, at: 0.02)
        #expect(focusedKey(in: rtEnd) == "Charlie", "ArrowUp into unchecked hidden menu enters at last item")

        // 3. TypeSelect prefix & 1s reset & single-char cycle (`focus.rs:1041`).
        let rtType = makeMenuRt(MenuS(open: true))
        _ = rtType.frame(at: 0.0)
        pressKey(rtType, .text("b"), at: 0.10); #expect(focusedKey(in: rtType) == "Beta")
        pressKey(rtType, .text("r"), at: 0.20); #expect(focusedKey(in: rtType) == "Bravo")
        pressKey(rtType, .text("c"), at: 1.40); #expect(focusedKey(in: rtType) == "Charlie", "pause resets prefix")
        pressKey(rtType, .text("b"), at: 2.60); #expect(focusedKey(in: rtType) == "Beta")
        pressKey(rtType, .text("b"), at: 2.70); #expect(focusedKey(in: rtType) == "Bravo")
        pressKey(rtType, .text("b"), at: 2.80); #expect(focusedKey(in: rtType) == "Beta")
        pressKey(rtType, .enter, at: 2.90)
        #expect(rtType.state.picks == [1] && !rtType.state.open)

        // 4. Shared pointer/keyboard highlight + searchable menu keeps field focused (`focus.rs:1057`).
        let rtHover = makeMenuRt(MenuS(open: true))
        _ = rtHover.frame(at: 0.0)
        let bravoPt = centerOf(key: "Bravo", in: rtHover)
        rtHover.pointerMove(to: bravoPt, at: 0.01)
        _ = rtHover.frame(at: 0.01)
        #expect(rtHover.highlightedElementKey() == "Bravo")
        #expect(!rtHover.elements().contains(where: { $0.focusVisible }))
        pressKey(rtHover, .arrowDown, at: 0.02)
        #expect(rtHover.highlightedElementKey() == "Charlie")
        rtHover.pointerMove(to: Vec2(5, 290), at: 0.03)
        _ = rtHover.frame(at: 0.03)
        #expect(rtHover.highlightedElementKey() == "Charlie", "leaving rows preserves keyboard highlight")

        // Leaving rows after pointer hover clears pointer highlight before any key press,
        // and subsequent ArrowDown reveals the row without leaking a previous hover.
        let rtHoverExit = makeMenuRt(MenuS(open: true))
        _ = rtHoverExit.frame(at: 0.0)
        let bravoExitPt = centerOf(key: "Bravo", in: rtHoverExit)
        rtHoverExit.pointerMove(to: bravoExitPt, at: 0.01)
        _ = rtHoverExit.frame(at: 0.01)
        #expect(rtHoverExit.highlightedElementKey() == "Bravo")
        rtHoverExit.pointerMove(to: Vec2(5, 290), at: 0.02)
        _ = rtHoverExit.frame(at: 0.02)
        #expect(rtHoverExit.highlightedElementKey() == nil, "leaving rows clears pointer-activated highlight")
        rtHoverExit.pointerMove(to: bravoExitPt, at: 0.03)
        _ = rtHoverExit.frame(at: 0.03)
        #expect(rtHoverExit.highlightedElementKey() == "Bravo")
        rtHoverExit.pointerExit(at: 0.04)
        _ = rtHoverExit.frame(at: 0.04)
        #expect(rtHoverExit.highlightedElementKey() == nil, "pointerExit clears pointer-activated highlight")
        pressKey(rtHoverExit, .arrowDown, at: 0.05)
        #expect(rtHoverExit.highlightedElementKey() == "Bravo")
        rtHoverExit.pointerMove(to: Vec2(5, 290), at: 0.06)
        _ = rtHoverExit.frame(at: 0.06)
        #expect(rtHoverExit.highlightedElementKey() == "Bravo", "leaving rows preserves subsequent keyboard highlight")

        let rtSearch = makeMenuRt(MenuS(open: true, follows: true, search: true))
        _ = rtSearch.frame(at: 0.0)
        #expect(focusedKey(in: rtSearch) == "field")
        let betaPt = centerOf(key: "Beta", in: rtSearch)
        rtSearch.pointerMove(to: betaPt, at: 0.01)
        _ = rtSearch.frame(at: 0.01)
        #expect(focusedKey(in: rtSearch) == "field", "hovering results never steals search focus")
        pressKey(rtSearch, .arrowDown, at: 0.02)
        #expect(focusedKey(in: rtSearch) == "field" && rtSearch.highlightedElementKey() != nil)

        // 5. Combobox opens on ArrowDown once + focusFollows activates reached items (`focus.rs:1075`).
        let rtFollows = makeMenuRt(MenuS(follows: true))
        _ = rtFollows.frame(at: 0.0)
        pressKey(rtFollows, .tab, at: 0.01)
        #expect(focusedKey(in: rtFollows) == "popup")
        pressKey(rtFollows, .arrowDown, at: 0.02)
        #expect(rtFollows.state.open && focusedKey(in: rtFollows) == "Alpha")
        pressKey(rtFollows, .arrowDown, isRepeat: true, at: 0.03)
        pressKey(rtFollows, .arrowDown, isRepeat: true, at: 0.04)
        #expect(rtFollows.state.picks == [1, 2], "follows invokes press as focus moves")
        #expect(rtFollows.state.opens == 1)
    }

    // MARK: - 3. onKey tx.focused, default button, slider, Shift modifiers, lists, PageKeys, held repeats (`focus.rs:1110-1538`)

    @Test("focus.rs:1110,1136,1179: onKey tx.focused & app-first, default focus ring, Return vs Space & defaultButton")
    func onKeyFocusedDefaultRingAndReturnDefaultButtonParity() {
        struct KeysS {
            var seen: [String?] = []
            var pane = 0
            var field = TextEdit("")
            var named = TextEdit("")
            var log: [String] = []
            var sheet = false
        }
        let rt = Runtime(state: KeysS(), viewport: Vec2(300, 300), pixelScale: 1.0) { _, _ in
            col().size(200, 200)
                .child(el().key("switch").size(40, 20).focusable().role(.button))
                .child(el().size(30, 30).focusable())
        }
        rt.globalOnKey = { s, ev, tx in
            s.seen.append(tx.focused())
            if ev.key == .arrowDown && tx.focused() == nil { s.pane += 1; return true }
            return false
        }
        _ = rt.frame(at: 0.0)
        pressKey(rt, .arrowDown, at: 0.01)
        #expect(rt.state.pane == 1)
        pressKey(rt, .tab, at: 0.02)
        #expect(focusedKey(in: rt) == "switch")
        pressKey(rt, .arrowDown, at: 0.03)
        #expect(rt.state.pane == 1)
        pressKey(rt, .tab, at: 0.04)
        pressKey(rt, .arrowDown, at: 0.05)
        #expect(rt.state.seen == [nil, nil, "switch", "#2"])

        // Default focus ring appears on keyboard focus only and skips noFocusRing / textInput / menu item (`focus.rs:1136`).
        let ringRt = Runtime(state: TextEdit(""), viewport: Vec2(200, 300), pixelScale: 1.0) { (_: TextEdit, _: inout Cx<TextEdit>) -> El<TextEdit> in
            col().p(20).gap(10).itemsStart()
                .child(el().key("plain").size(40, 20).rounded(6).bg(Color.white).focusable())
                .child(el().key("off").size(40, 20).rounded(6).bg(Color.white).focusable().noFocusRing())
                .child(textInput(key: "field", \.self).font(TextStyle(size: 14)).size(80, 20))
                .child(col().key("menu").role(.menu).focusGroup().child(el().key("item").size(40, 20).focusable().focusHighlight(Color.white)))
        }
        ringRt.setTabVisitsControls(true)
        var ringScene = ringRt.frame(at: 0.0)
        func ringPrimitives() -> [Primitive] {
            ringScene.primitives.filter { p in
                p.kind == .roundedRect && p.fill.w == 0 && p.params.x > 0
            }
        }
        #expect(ringPrimitives().isEmpty)
        clickKey("plain", in: ringRt, at: 0.01)
        ringScene = ringRt.frame(at: 0.01)
        #expect(focusedKey(in: ringRt) == "plain" && ringPrimitives().isEmpty)
        for _ in 0..<4 {
            _ = ringRt.keyDown(KeyEvent(key: .tab), at: 0.02)
            ringScene = ringRt.frame(at: 0.02)
            if focusedKey(in: ringRt) == "plain" { break }
        }
        #expect(ringPrimitives().count == 1)
        _ = ringRt.keyDown(KeyEvent(key: .tab), at: 0.03); ringScene = ringRt.frame(at: 0.03)
        #expect(focusedKey(in: ringRt) == "off" && ringPrimitives().isEmpty)
        _ = ringRt.keyDown(KeyEvent(key: .tab), at: 0.04); ringScene = ringRt.frame(at: 0.04)
        #expect(focusedKey(in: ringRt) == "field" && ringPrimitives().isEmpty)
        _ = ringRt.keyDown(KeyEvent(key: .tab), at: 0.05); ringScene = ringRt.frame(at: 0.05)
        #expect(focusedKey(in: ringRt) == "item" && ringPrimitives().isEmpty)

        // Return presses default button once; Space presses focused button; Shift+Return hits onKey (`focus.rs:1179`).
        let retRt = Runtime(state: KeysS(), viewport: Vec2(300, 300), pixelScale: 1.0) { (s: KeysS, _: inout Cx<KeysS>) -> El<KeysS> in
            var c: El<KeysS> = col().size(300, 300)
                .child(textInput(key: "field", \KeysS.field).font(TextStyle(size: 14)).size(100, 20))
                .child(textInput(key: "named", \KeysS.named).font(TextStyle(size: 14)).size(100, 20).onSubmit { st, _, _ in st.log.append("submit") })
                .child(col().key("list").role(.listbox).focusGroup().child(el().key("row").size(80, 20).focusable().onClick { st, _ in st.log.append("row") }))
                .child(el().key("later").size(60, 20).focusable().onClick { st, _ in st.log.append("later") })
                .child(el().key("continue").size(60, 20).focusable().defaultButton().onClick { st, _ in st.log.append("continue") })
                .child(el().key("hidden").size(60, 20).focusable().defaultButton().opacity(0).onClick { st, _ in st.log.append("hidden") })
            if s.sheet {
                c = c.child(
                    col().key("sheet").pin(top: 0, left: 150).size(100, 100)
                        .modal(clickOutside: true) { (st: inout KeysS) in st.sheet = false }
                        .child(el().key("cancel").size(40, 20).focusable().onClick { st, _ in st.sheet = false })
                        .child(el().key("done").size(40, 20).focusable().defaultButton().onClick { st, _ in st.log.append("done"); st.sheet = false })
                )
            }
            return c
        }
        retRt.setTabVisitsControls(true)
        retRt.globalOnKey = { s, ev, _ in if ev.key == .enter { s.log.append("on_key") }; return false }
        _ = retRt.frame(at: 0.0)
        pressKey(retRt, .enter, at: 0.01)
        pressKey(retRt, .enter, isRepeat: true, at: 0.02)
        #expect(retRt.state.log == ["continue"])
        retRt.state.log.removeAll()
        for _ in 0..<10 { pressKey(retRt, .tab, at: 0.03); if focusedKey(in: retRt) == "later" { break } }
        pressKey(retRt, .enter, at: 0.04)
        pressKey(retRt, .space, at: 0.05)
        #expect(retRt.state.log == ["continue", "later"])
        retRt.state.log.removeAll()
        pressKey(retRt, .enter, mods: Mods(shift: true), at: 0.06)
        #expect(retRt.state.log == ["on_key"])
        retRt.state.log.removeAll()
        retRt.update(at: 0.07) { s, _ in s.sheet = true }
        _ = retRt.frame(at: 0.07)
        pressKey(retRt, .enter, at: 0.08)
        #expect(retRt.state.log == ["done"] && !retRt.state.sheet)
    }

    @Test("focus.rs:1230,1269,1301: slider stepping/limits, Shift-modified keys past Tab, IME composition Return/Escape")
    func sliderShiftKeysAndCompositionConfirmCancel() {
        struct SlideS {
            var value = 50
            var steps: [Int] = []
            var page = false
            var app: [Key] = []
        }
        let slRt = Runtime(state: SlideS(), viewport: Vec2(200, 200), pixelScale: 1.0) { (s: SlideS, _: inout Cx<SlideS>) -> El<SlideS> in
            var slider: El<SlideS> = el().key("volume").size(100, 20).onStep { st, d, _ in
                st.steps.append(d)
                st.value = max(0, min(100, st.value + d))
            }
            if !s.page {
                slider = slider.onStepLimit { st, maxEnd, _ in st.value = maxEnd ? 100 : 0 }
            }
            return col().size(200, 200).child(
                row().role(.toolbar).focusGroup()
                    .child(el().key("before").size(40, 20).focusable())
                    .child(slider)
            )
        }
        slRt.globalOnKey = { s, ev, _ in s.app.append(ev.key); return false }
        slRt.setTabVisitsControls(true)
        _ = slRt.frame(at: 0.0)
        #expect(slRt.element(byKey: "volume")?.role == .slider)
        pressKey(slRt, .tab, at: 0.01)
        pressKey(slRt, .arrowRight, at: 0.02)
        #expect(focusedKey(in: slRt) == "volume" && slRt.state.steps.isEmpty)
        for k: Key in [.arrowLeft, .arrowDown, .arrowRight, .arrowUp, .pageDown, .pageUp] {
            pressKey(slRt, k, at: 0.03)
        }
        #expect(slRt.state.steps == [-1, -1, 1, 1, -10, 10])
        slRt.state.steps.removeAll()
        pressKey(slRt, .arrowRight, at: 0.04)
        pressKey(slRt, .arrowRight, isRepeat: true, at: 0.05)
        pressKey(slRt, .arrowRight, isRepeat: true, at: 0.06)
        #expect(slRt.state.steps == [1, 1, 1] && slRt.state.value == 53)
        pressKey(slRt, .end, at: 0.07); #expect(slRt.state.value == 100)
        pressKey(slRt, .home, at: 0.08); #expect(slRt.state.value == 0)
        slRt.update(at: 0.09) { s, _ in s.page = true; s.value = 50; s.app.removeAll(); s.steps.removeAll() }
        _ = slRt.frame(at: 0.09)
        pressKey(slRt, .home, at: 0.10)
        pressKey(slRt, .arrowRight, mods: Mods(shift: true), at: 0.11)
        #expect(slRt.state.value == 50 && slRt.state.steps.isEmpty)
        #expect(slRt.state.app == [.home, .arrowRight])

        // Shift+Space/Return/Down reach app and press nothing; capital still type-selects; Shift+Tab reverses (`focus.rs:1269`).
        struct ShiftS { var log: [String] = []; var app: [Key] = [] }
        let shRt = Runtime(state: ShiftS(), viewport: Vec2(200, 200), pixelScale: 1.0) { (_: ShiftS, _: inout Cx<ShiftS>) -> El<ShiftS> in
            col().size(200, 200)
                .child(el().key("go").size(60, 20).focusable().onClick { s, _ in s.log.append("go") })
                .child(
                    col().key("list").role(.listbox).focusGroup()
                        .child(el().key("apple").label("apple").size(60, 20).focusable().onClick { s, _ in s.log.append("apple") })
                        .child(el().key("banana").label("banana").size(60, 20).focusable().onClick { s, _ in s.log.append("banana") })
                )
        }
        shRt.globalOnKey = { s, ev, _ in s.app.append(ev.key); return false }
        shRt.setTabVisitsControls(true)
        _ = shRt.frame(at: 0.0)
        pressKey(shRt, .tab, at: 0.01); #expect(focusedKey(in: shRt) == "go")
        pressKey(shRt, .text(" "), mods: Mods(shift: true), at: 0.02)
        pressKey(shRt, .tab, at: 0.03); #expect(focusedKey(in: shRt) == "apple")
        pressKey(shRt, .enter, mods: Mods(shift: true), at: 0.04)
        pressKey(shRt, .arrowDown, mods: Mods(shift: true), at: 0.05)
        #expect(focusedKey(in: shRt) == "apple" && shRt.state.log.isEmpty)
        #expect(shRt.state.app == [.tab, .text(" "), .enter, .arrowDown])
        pressKey(shRt, .text("B"), mods: Mods(shift: true), at: 0.06)
        #expect(focusedKey(in: shRt) == "banana")
        pressKey(shRt, .tab, mods: Mods(shift: true), at: 0.07)
        #expect(focusedKey(in: shRt) == "go")

        // IME composition: Return/Escape do not submit, blur, or press defaultButton (`focus.rs:1301`).
        struct CompS { var field = TextEdit(""); var log: [String] = [] }
        let cRt = Runtime(state: CompS(), viewport: Vec2(200, 120), pixelScale: 1.0) { (_: CompS, _: inout Cx<CompS>) -> El<CompS> in
            col().size(200, 120)
                .child(textInput(key: "named", \CompS.field).font(TextStyle(size: 14)).size(100, 24).onSubmit { s, _, _ in s.log.append("submit") })
                .child(el().key("def").size(60, 20).focusable().defaultButton().onClick { s, _ in s.log.append("def") })
        }
        _ = cRt.frame(at: 0.0)
        clickKey("named", in: cRt, at: 0.01)
        _ = cRt.dispatchImeEvent(.preedit("kan", cursorUTF8: nil, clauses: []), at: 0.02)
        pressKey(cRt, .enter, at: 0.03)
        pressKey(cRt, .escape, at: 0.04)
        #expect(cRt.state.log.isEmpty && focusedKey(in: cRt) == "named")
    }

    @Test("focus.rs:1351,1380,1400,1456,1503,1515 & FocusMachine: list clamp, scroll reveal, focusFollows, PageUp/Down, held modals")
    func listClampScrollFollowsPageKeysAndHeldModals() {
        // 1. Clamped list ends + PageDown/PageUp in scrolling listbox + focusFollows app selection.
        struct ListS { var selected = 0 }
        let lRt = Runtime(state: ListS(), viewport: Vec2(200, 100), pixelScale: 1.0) { s, _ in
            col().size(200, 100).child(
                col().key("scroll").wFull().h(100).scroll(ScrollSpec(stickBottom: false)).child(
                    col().key("list").role(.listbox).focusGroup().focusFollows().children(
                        (0..<20).map { i in
                            el().key("item\(i)").wFull().h(20).focusable().role(.option)
                                .focusSelected(s.selected == i)
                                .onClick { st, _ in st.selected = i }
                        }
                    )
                )
            )
        }
        _ = lRt.frame(at: 0.0)
        lRt.update(at: 0.01) { _, tx in tx.focus("item0") }
        _ = lRt.frame(at: 0.01)
        pressKey(lRt, .pageDown, at: 0.02)
        for step in 1...30 { _ = lRt.frame(at: 0.02 + Double(step) / 60.0) }
        #expect(focusedKey(in: lRt) == "item4")
        pressKey(lRt, .pageDown, at: 0.60)
        for step in 1...30 { _ = lRt.frame(at: 0.60 + Double(step) / 60.0) }
        #expect(focusedKey(in: lRt) == "item8")
        pressKey(lRt, .pageUp, at: 1.20)
        for step in 1...30 { _ = lRt.frame(at: 1.20 + Double(step) / 60.0) }
        #expect(focusedKey(in: lRt) == "item4")
        pressKey(lRt, .end, at: 1.80)
        #expect(focusedKey(in: lRt) == "item19")
        #expect(lRt.scrollOffset(forKey: "scroll").y > 100, "End reveals item19 into view")

        // App update moves focusSelected when focusFollows is active (`focus.rs:1400`).
        lRt.update(at: 1.90) { s, _ in s.selected = 2 }
        _ = lRt.frame(at: 1.90)
        #expect(focusedKey(in: lRt) == "item2")

        // .list clamps ends (`focus.rs:1380`).
        let clRt = Runtime(state: (), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            col().role(.list).focusGroup().children((0..<3).map { i in el().key("r\(i)").size(80, 20).focusable() })
        }
        _ = clRt.frame(at: 0.0)
        pressKey(clRt, .tab, at: 0.01); #expect(focusedKey(in: clRt) == "r0")
        pressKey(clRt, .arrowUp, at: 0.02); #expect(focusedKey(in: clRt) == "r0")
        pressKey(clRt, .end, at: 0.03); #expect(focusedKey(in: clRt) == "r2")
        pressKey(clRt, .arrowDown, at: 0.04); #expect(focusedKey(in: clRt) == "r2")

        // Stacked modals + held Escape + held Space (`focus.rs:1456,1503`).
        struct HeldM { var modals: UInt8 = 2; var app = 0; var presses = 0 }
        let mRt = Runtime(state: HeldM(), viewport: Vec2(300, 300), pixelScale: 1.0) { (s: HeldM, _: inout Cx<HeldM>) -> El<HeldM> in
            var c: El<HeldM> = col().size(300, 300)
                .child(el().key("btn").size(60, 20).focusable().onClick { st, _ in st.presses += 1 })
            if s.modals >= 1 {
                c = c.child(
                    col().key("one").modal(clickOutside: true) { (st: inout HeldM) in st.modals -= 1 }
                        .child(el().key("in-one").size(60, 20).focusable())
                )
            }
            if s.modals >= 2 {
                c = c.child(
                    col().key("two").modal(clickOutside: true) { (st: inout HeldM) in st.modals -= 1 }
                        .child(el().key("in-two").size(60, 20).focusable())
                )
            }
            return c
        }
        mRt.globalOnKey = { s, _, _ in s.app += 1; return false }
        _ = mRt.frame(at: 0.0)
        #expect(focusedKey(in: mRt) == "in-two")
        pressKey(mRt, .escape, at: 0.01)
        pressKey(mRt, .escape, isRepeat: true, at: 0.02)
        pressKey(mRt, .escape, isRepeat: true, at: 0.03)
        #expect(mRt.state.modals == 1 && focusedKey(in: mRt) == "in-one")
        pressKey(mRt, .escape, at: 0.04)
        pressKey(mRt, .escape, isRepeat: true, at: 0.05)
        #expect(mRt.state.modals == 0 && focusedKey(in: mRt) == nil && mRt.state.app == 0)

        pressKey(mRt, .tab, at: 0.06); #expect(focusedKey(in: mRt) == "btn")
        pressKey(mRt, .space, at: 0.07)
        pressKey(mRt, .space, isRepeat: true, at: 0.08)
        #expect(mRt.state.presses == 1, "Space repeats fire once per press")

        // FocusMachine unit checks (`focus_machine.rs`, `modal_focus.rs`).
        #expect(FocusMachine.listKind(for: .menu) == .wrapMenu)
        #expect(FocusMachine.listKind(for: .list) == .clampedList)
        #expect(FocusMachine.listKind(for: .button) == nil)
        var fm = FocusMachine()
        #expect(fm.typeSelect.push("A", at: 1.0).query == "a")
        #expect(fm.typeSelect.push("p", at: 1.2).query == "ap")
        #expect(fm.typeSelect.push("x", at: 2.5).query == "x")
        _ = fm
    }

    // MARK: - 4. Physical repeats, key codes, format chords, physicalThen, physical paste, hover & reducedMotion (`physical.rs:429-678`, `hover_tests.rs`, `on_key_tests.rs:138`)

    @Test("physical.rs:429-555: repeat flags, physicalKey codes, non-leaking onInputChange, disallowed format chord, escape vs held arrow")
    func physicalKeyCodesRepeatsFormatChordAndEscapeArrow() {
        struct PhysS {
            var edit = TextEdit("")
            var inputRepeats: [Bool] = []
            var appLog: [(Key, PhysicalKeyCode?, Bool)] = []
            var changeCodes: [PhysicalKeyCode?] = []
            var keyUps: [PhysicalKeyCode?] = []
        }
        let rt = Runtime(state: PhysS(), viewport: Vec2(300, 200), pixelScale: 1.0) { _, _ in
            col().size(300, 200)
                .onKeyUp { s, _, tx in s.keyUps.append(tx.physicalKey()); return true }
                .child(
                    textInput(key: "field", \PhysS.edit).font(TextStyle(size: 14)).size(200, 32)
                        .onInputChange { s, tx in s.changeCodes.append(tx.physicalKey()) }
                        .onInputKey { s, _, tx in s.inputRepeats.append(tx.keyRepeat()); return false }
                )
                .child(el().key("other").size(80, 30).focusable())
        }
        rt.globalOnKey = { s, ev, tx in s.appLog.append((ev.key, tx.physicalKey(), tx.keyRepeat())); return true }
        _ = rt.frame(at: 0.0)

        let enterMods = Mods.none
        _ = rt.physicalWithFallback(.key(key: .enter, mods: enterMods, pressed: true, repeat: false), fallbackKey: KeyEvent(key: .enter), at: 0.01)
        _ = rt.physicalWithFallback(.key(key: .enter, mods: enterMods, pressed: true, repeat: true), fallbackKey: KeyEvent(key: .enter), at: 0.02)
        _ = rt.frame(at: 0.02)
        #expect(rt.state.appLog.count == 2)
        #expect(rt.state.appLog[0].2 == false && rt.state.appLog[1].2 == true)

        clickKey("field", in: rt, at: 0.03)
        for rep in [false, true, true] {
            _ = rt.physicalWithFallback(.key(key: .keyX, mods: .none, pressed: true, repeat: rep), fallbackKey: KeyEvent(key: .text("x")), at: 0.04)
            _ = rt.frame(at: 0.04)
        }
        #expect(rt.state.inputRepeats == [false, true, true])
        #expect(rt.state.edit.text == "xxx")
        #expect(rt.state.changeCodes == [nil, nil, nil], "onInputChange never inherits physicalKey")

        // US/German ⌘⇧7 both report PhysicalKeyCode.digit7 on down, repeat, and keyUp.
        rt.state.appLog.removeAll()
        rt.state.keyUps.removeAll()
        let cmdShift = Mods(shift: true, cmd: true)
        for (ch, rep) in [(Character("/"), false), (Character("&"), true)] {
            _ = rt.physicalWithFallback(.key(key: .digit7, mods: cmdShift, pressed: true, repeat: rep), fallbackKey: KeyEvent(key: .command(ch), mods: cmdShift), at: 0.05)
            _ = rt.physicalWithFallback(.key(key: .digit7, mods: cmdShift, pressed: false, repeat: false), fallbackKey: KeyEvent(key: .command(ch), mods: cmdShift), at: 0.06)
            _ = rt.frame(at: 0.06)
        }
        #expect(rt.state.appLog.count == 2)
        #expect(rt.state.appLog[0].1 == .digit7 && rt.state.appLog[1].1 == .digit7)
        #expect(rt.state.keyUps == [.digit7, .digit7])

        // Held arrow repeats keep reaching app after Escape tap blurs field.
        rt.state.appLog.removeAll()
        _ = rt.physicalWithFallback(.key(key: .arrowDown, mods: .none, pressed: true, repeat: false), fallbackKey: KeyEvent(key: .arrowDown), at: 0.07)
        _ = rt.physicalWithFallback(.key(key: .escape, mods: .none, pressed: true, repeat: false), fallbackKey: KeyEvent(key: .escape), at: 0.08)
        _ = rt.physicalWithFallback(.key(key: .escape, mods: .none, pressed: false, repeat: false), fallbackKey: KeyEvent(key: .escape), at: 0.09)
        _ = rt.frame(at: 0.09)
        #expect(focusedKey(in: rt) == nil)
        let beforeArrows = rt.state.appLog.count
        _ = rt.physicalWithFallback(.key(key: .arrowDown, mods: .none, pressed: true, repeat: true), fallbackKey: KeyEvent(key: .arrowDown), at: 0.10)
        _ = rt.frame(at: 0.10)
        #expect(rt.state.appLog.count == beforeArrows + 1)

        // Format chord disallowed by rich text (`allowMarks([.bold])`) goes to app (`physical.rs:509`).
        struct RichP { var edit: TextEdit; var app: [Key] = [] }
        var richEdit = TextEdit("ab").rich(true).allowRichMarks([.bold])
        richEdit.selectAll()
        let richRt = Runtime(state: RichP(edit: richEdit), viewport: Vec2(300, 200), pixelScale: 1.0) { _, _ in
            col().size(300, 200).child(textInput(key: "field", \RichP.edit).font(TextStyle(size: 14)).size(200, 32))
        }
        richRt.globalOnKey = { s, ev, _ in s.app.append(ev.key); return true }
        _ = richRt.frame(at: 0.0)
        clickKey("field", in: richRt, at: 0.01)
        pressKey(richRt, .command("u"), mods: Mods(cmd: true), at: 0.02)
        pressKey(richRt, .command("b"), mods: Mods(cmd: true), at: 0.03)
        #expect(richRt.state.app == [.command("u")])
    }

    @Test("physical.rs:604-678 & on_key_tests:138 & hover_tests: modal repeat suppression, physicalThen, paste, reducedMotion, hover stability")
    func physicalModalRepeatSuppressionPhysicalThenPasteAndMotion() {
        // 1. Repeats never reach new modal focus's onPhysicalInput (`physical.rs:604,624`).
        struct Opener { var modal = false; var goRepeats = 0; var sink = 0 }
        func makeOpener() -> Runtime<Opener> {
            Runtime(state: Opener(), viewport: Vec2(300, 200), pixelScale: 1.0) { (s: Opener, _: inout Cx<Opener>) -> El<Opener> in
                var c: El<Opener> = col().size(300, 200)
                    .child(
                        el().key("go").size(40, 30).focusable().role(.button)
                            .onClick { st, _ in st.modal = true }
                            .onPhysicalInput { st, e, _ in
                                if case .key(_, _, _, true) = e { st.goRepeats += 1 }
                                return false
                            }
                    )
                if s.modal {
                    c = c.child(
                        col().key("modal").pin(top: 0, left: 100).size(100, 100)
                            .modal(clickOutside: true) { (st: inout Opener) in st.modal = false }
                            .child(
                                el().key("sink").size(40, 30).focusable()
                                    .onPhysicalInput { st, e, _ in
                                        if case .key(_, _, true, _) = e { st.sink += 1 }
                                        return true
                                    }
                            )
                    )
                }
                return c
            }
        }
        let op1 = makeOpener()
        _ = op1.frame(at: 0.0)
        pressKey(op1, .tab, at: 0.01)
        _ = op1.physicalWithFallback(.key(key: .space, mods: .none, pressed: true, repeat: false), fallbackKey: KeyEvent(key: .space), at: 0.02)
        _ = op1.frame(at: 0.02)
        #expect(focusedKey(in: op1) == "sink")
        _ = op1.physicalWithFallback(.key(key: .space, mods: .none, pressed: true, repeat: true), fallbackKey: KeyEvent(key: .space), at: 0.03)
        _ = op1.frame(at: 0.03)
        #expect(op1.state.sink == 0, "repeat of Space that opened modal must not reach sink")

        // Same-frame queued repeat (`physical.rs:624`).
        let op2 = makeOpener()
        _ = op2.frame(at: 0.0)
        pressKey(op2, .tab, at: 0.01)
        _ = op2.physicalWithFallback(.key(key: .space, mods: .none, pressed: true, repeat: false), fallbackKey: KeyEvent(key: .space), at: 0.02)
        _ = op2.physicalWithFallback(.key(key: .space, mods: .none, pressed: true, repeat: true), fallbackKey: KeyEvent(key: .space), at: 0.02)
        _ = op2.frame(at: 0.02)
        #expect(focusedKey(in: op2) == "sink" && op2.state.goRepeats == 0 && op2.state.sink == 0)

        // 2. physicalThen runs menu fallback only when unhandled; physical Cmd+V delivers to root onPaste (`physical.rs:638,663`).
        let board = Clipboard(kind: .memory)
        board.writeText("app")
        struct MenuPasteS { var pasted = ""; var app = 0 }
        let mpRt = Runtime(state: MenuPasteS(), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            el().size(200, 100).onPaste { s, text, _ in s.pasted = text }
        }
        mpRt.useClipboard(board)
        mpRt.globalOnKey = { s, ev, _ in s.app += 1; return ev.key == .command("]") }
        _ = mpRt.frame(at: 0.0)
        var ran = 0
        let cmd = Mods(cmd: true)
        _ = mpRt.physicalThen(.key(key: .bracketRight, mods: cmd, pressed: true, repeat: false), fallbackKey: KeyEvent(key: .command("]"), mods: cmd), unhandled: .menu { ran += 1 }, at: 0.01)
        #expect(ran == 0)
        _ = mpRt.physicalThen(.key(key: .bracketLeft, mods: cmd, pressed: true, repeat: false), fallbackKey: KeyEvent(key: .command("["), mods: cmd), unhandled: .menu { ran += 1 }, at: 0.02)
        #expect(ran == 1)
        _ = mpRt.physicalThen(.key(key: .keyV, mods: cmd, pressed: true, repeat: false), fallbackKey: KeyEvent(key: .command("v"), mods: cmd), unhandled: .menu { ran += 1 }, at: 0.03)
        _ = mpRt.frame(at: 0.03)
        #expect(mpRt.state.pasted == "app")

        // 3. iconRotation reduced motion jumps immediately vs smooth spring (`on_key_tests.rs:138`).
        let chev = SVGIcon(viewBox: 16, paths: ["M5 6.5L8 9.5L11 6.5"])
        for reduced in [false, true] {
            let iconRt = Runtime(state: false, viewport: Vec2(100, 100), pixelScale: 1.0) { open, _ in
                col().size(100, 100).child(
                    icon(chev, size: 16).key("chev").iconRotation(open ? 0 : -.pi / 2).animate(MotionTokens.DEFAULT)
                )
            }
            iconRt.setSystemReducedMotion(reduced)
            var scene = iconRt.frame(at: 0.0)
            func glyphAngle(in s: RefScene) -> Float {
                for p in s.primitives where p.kind == .glyph {
                    return p.turn
                }
                return 999
            }
            #expect(abs(glyphAngle(in: scene) - (-.pi / 2)) < 0.01)
            iconRt.update(at: 0.0) { open, _ in open = true }
            _ = iconRt.frame(at: 1.0 / 60.0)
            scene = iconRt.frame(at: 2.0 / 60.0)
            let mid = glyphAngle(in: scene)
            if reduced {
                #expect(abs(mid) < 0.001, "reduced motion lands immediately")
            } else {
                #expect(mid < -0.05 && mid > -.pi / 2 + 0.05, "chevron rotates mid-spring")
            }
        }

        // 4. hover_tests: unchanged default hover produces stable frame without churning; hoverGroup inherits cleanly.
        let hovRt = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            col().wFull().hFull().child(
                col().key("g").wFull().hoverGroup()
                    .child(el().key("r").w(100).h(30).hover(Color.white).onClick { _ in })
                    .child(el().key("act").size(10, 10).bg(Color.white).groupOpacity(0, 1))
            )
        }
        _ = hovRt.frame(at: 0.0)
        hovRt.pointerMove(to: Vec2(50, 15), at: 0.01)
        var settledA = hovRt.frame(at: 0.01).primitives
        for f in 1...5 { settledA = hovRt.frame(at: 0.01 + Double(f) / 60.0).primitives }
        let settledB = hovRt.frame(at: 2.0).primitives
        #expect(settledB.count == settledA.count)
    }
}
