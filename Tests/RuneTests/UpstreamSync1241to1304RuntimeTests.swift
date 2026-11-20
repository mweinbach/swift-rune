import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite(.serialized)
struct UpstreamSync1241to1304RuntimeTests {

    // MARK: - Helpers

    private func findElement<S>(_ rt: Runtime<S>, key: String) -> ElementInfo? {
        rt.elements().first(where: { $0.key == key })
    }

    private func assertSheetExiting<S>(_ rt: Runtime<S>) throws {
        let sheet = try #require(findElement(rt, key: "sheet"), "sheet stays mounted while its exit plays")
        #expect(sheet.exiting, "sheet is exiting, not unmounted in the settle frame")
        #expect(sheet.opacity > 0.0 && sheet.opacity < 1.0, "sheet is mid-fade: \(sheet.opacity)")
    }

    private func assertSheetGone<S>(_ rt: Runtime<S>) {
        for _ in 0..<120 {
            _ = rt.frameStep(dt: 1.0 / 60.0)
        }
        #expect(findElement(rt, key: "sheet") == nil, "sheet is gone once the exit settles")
    }

    // MARK: - #1241 (c853811c): Settle lands before the frame's input so exits still play

    @Test("c853811c: settleAll with Escape key still plays exit animation of closed sheet")
    func settleWithKeyInputStillExitsRemovedElement() throws {
        struct Sheet { var shown = true }
        let rt = Runtime<Sheet>(state: Sheet(), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            var root: El<Sheet> = col()
                .size(200, 200)
                .focusable(true)
                .onKey { st, ev, _ in
                    if ev.key == .escape && st.shown {
                        st.shown = false
                        return true
                    }
                    return false
                }
            if s.shown {
                root = root.child(
                    el().key("sheet").size(80, 40).bg(.white).transition(.opacity)
                )
            }
            return root
        }
        rt.setFullKeyboardAccess(true)
        _ = rt.frameStep(dt: 0.0)
        _ = rt.keyDown(KeyEvent(key: .tab), at: rt.currentTime)
        _ = rt.frameStep(dt: 1.0 / 60.0)

        // Host catch-up settle and the key that closes the sheet land on one frame.
        rt.settleAll()
        _ = rt.keyDown(KeyEvent(key: .escape), at: rt.currentTime)
        #expect(rt.frameStep(dt: 1.0 / 60.0), "the sheet's exit still animates")
        try assertSheetExiting(rt)
        assertSheetGone(rt)
    }

    @Test("c853811c: unhandled key on a settle frame still reports settled")
    func unhandledKeyOnSettleFrameStillReportsSettled() {
        struct Sheet { var shown = true }
        let rt = Runtime<Sheet>(state: Sheet(), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            var root: El<Sheet> = col()
                .size(200, 200)
                .focusable(true)
                .onKey { st, ev, _ in
                    if ev.key == .escape && st.shown {
                        st.shown = false
                        return true
                    }
                    return false
                }
            if s.shown {
                root = root.child(
                    el().key("sheet").size(80, 40).bg(.white).transition(.opacity)
                )
            }
            return root
        }
        rt.setFullKeyboardAccess(true)
        _ = rt.frameStep(dt: 0.0)
        _ = rt.keyDown(KeyEvent(key: .tab), at: rt.currentTime)
        _ = rt.frameStep(dt: 1.0 / 60.0)

        rt.settleAll()
        _ = rt.keyDown(KeyEvent(key: .enter), at: rt.currentTime)
        _ = rt.frameStep(dt: 1.0 / 60.0)
        #expect(rt.settled, "the frame painted the settled tree and reports settled")
        #expect(findElement(rt, key: "sheet") != nil, "the unhandled key changed nothing")
    }

    @Test("c853811c: settleAll with pointer press still exits the sheet that press closes")
    func settleWithPointerPressStillExitsClosedSheet() throws {
        struct Dialog { var shown = true }
        let rt = Runtime<Dialog>(state: Dialog(), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            var root: El<Dialog> = col().size(200, 200)
            if s.shown {
                root = root.child(
                    col()
                        .key("sheet")
                        .size(160, 120)
                        .bg(.white)
                        .transition(.opacity)
                        .child(
                            row()
                                .key("close")
                                .size(80, 24)
                                .onClick { st in st.shown = false }
                        )
                )
            }
            return root
        }
        _ = rt.frameStep(dt: 0.0)
        let close = try #require(findElement(rt, key: "close")).rect
        let pt = Vec2(close[0] + close[2] * 0.5, close[1] + close[3] * 0.5)

        rt.settleAll()
        rt.pointerDown(at: pt, at: rt.currentTime)
        rt.pointerUp(at: pt, at: rt.currentTime)
        #expect(rt.frameStep(dt: 1.0 / 60.0), "the sheet's exit still animates")
        try assertSheetExiting(rt)
        assertSheetGone(rt)
    }

    @Test("c853811c: settleAll lands running motion while same-frame Escape still exits sheet")
    func settleLandsRunningMotionAndInputStillExits() throws {
        struct Moving {
            var x: Float = 0
            var shown = true
        }
        let rt = Runtime<Moving>(state: Moving(), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            var root: El<Moving> = col()
                .size(200, 200)
                .focusable(true)
                .onKey { st, ev, _ in
                    if ev.key == .escape && st.shown {
                        st.shown = false
                        return true
                    }
                    return false
                }
                .child(el().key("box").absolute(x: s.x, y: 0).size(10, 10).bg(.white))
            if s.shown {
                root = root.child(
                    el().key("sheet").size(80, 40).bg(.white).transition(.opacity)
                )
            }
            return root
        }
        rt.setFullKeyboardAccess(true)
        _ = rt.frameStep(dt: 0.0)
        _ = rt.keyDown(KeyEvent(key: .tab), at: rt.currentTime)
        _ = rt.frameStep(dt: 1.0 / 60.0)

        rt.update(at: rt.currentTime) { s, tx in
            s.x = 80.0
            tx.motion(Spring(duration: 0.3, bounce: 0.0))
        }
        _ = rt.frameStep(dt: 1.0 / 120.0)
        _ = rt.frameStep(dt: 0.05)
        let mid = try #require(findElement(rt, key: "box")).rect[0]
        #expect(mid > 0.0 && mid < 80.0 && rt.isAnimating, "spring is in flight: \(mid)")

        rt.settleAll()
        _ = rt.keyDown(KeyEvent(key: .escape), at: rt.currentTime)
        _ = rt.frameStep(dt: 1.0 / 60.0)
        let landed = try #require(findElement(rt, key: "box")).rect[0]
        #expect(abs(landed - 80.0) < 0.01, "the settle lands the spring in its frame: \(landed)")
        try assertSheetExiting(rt)
        assertSheetGone(rt)
    }

    // MARK: - #1293 (ace154ad): El.onPillSecondary for text_input pill context menus

    private struct PillFieldState {
        var edit: TextEdit
        var intercept: Bool = true
        var secondaryHits: [(id: String, x: Float, y: Float)] = []

        init(intercept: Bool = true) {
            var e = TextEdit("hi ", multiline: true).rich()
            e.insertPill(id: "session:42", label: "@session")
            e.insert(" world")
            self.edit = e
            self.intercept = intercept
        }
    }

    private func makePillRuntime(intercept: Bool = true, singleLine: Bool = false) -> Runtime<PillFieldState> {
        let rt = Runtime<PillFieldState>(
            state: PillFieldState(intercept: intercept),
            viewport: Vec2(320, 120),
            pixelScale: 1.0
        ) { _, _ in
            var field: El<PillFieldState> = textInput(key: "composer", \PillFieldState.edit)
                .size(280, 40)
                .p(8)
                .font(TextStyle(size: 14))
                .pillColors(Color.srgb(0.2, 0.3, 0.6, 1.0), .white)
                .onPillSecondary { s, id, press, _ in
                    s.secondaryHits.append((id, press.window.x, press.window.y))
                    return s.intercept
                }
            if singleLine {
                field = field.singleLine(true)
            }
            return col().size(320, 120).child(field)
        }
        _ = rt.frame(at: 0.0)
        return rt
    }

    /// Finds a window point inside the `"session:42"` pill and a point on plain text `"world"` outside it.
    private func locatePillAndPlainPoints(_ rt: Runtime<PillFieldState>) throws -> (pill: Vec2, plain: Vec2) {
        let info = try #require(findElement(rt, key: "composer"))
        let r = info.rect
        let y = r[1] + 16
        var pillPt: Vec2? = nil
        var plainPt: Vec2? = nil
        let idx = try #require(rt.nodeByPath[info.path])
        var x = r[0] + 6
        while x < r[0] + r[2] - 6 {
            if let hit = rt.inputPillAt(idx, x: x, y: y) {
                if pillPt == nil && hit == "session:42" {
                    pillPt = Vec2(x + 4, y)
                }
            } else if pillPt != nil && plainPt == nil && x > pillPt!.x + 45 {
                plainPt = Vec2(x, y)
            }
            x += 4
        }
        return (try #require(pillPt, "found pill hit point"), try #require(plainPt, "found plain text hit point"))
    }

    @Test("ace154ad: onPillSecondary intercepts pill secondary click when returning true and claims 'app'")
    func onPillSecondaryInterceptsReturningTrue() throws {
        let rt = makePillRuntime(intercept: true)
        let pts = try locatePillAndPlainPoints(rt)

        // Secondary press via secondaryDown/secondaryUp (browser & macOS control-click path)
        rt.secondaryDown(at: pts.pill, at: 0.1)
        #expect(rt.secondaryClaim() == "app", "pill with onPillSecondary claims 'app' over 'field'")
        rt.secondaryUp(at: pts.pill, mods: .none, at: 0.12)
        #expect(rt.state.secondaryHits.count == 1)
        #expect(rt.state.secondaryHits[0].id == "session:42")
        #expect(rt.takePopup() == nil, "returning true consumes secondary press without opening standard field menu")

        // Also test direct pointerDown(button: .secondary) path
        rt.pointerDown(at: pts.pill, button: .secondary, at: 0.2)
        rt.pointerUp(at: pts.pill, button: .secondary, at: 0.22)
        #expect(rt.state.secondaryHits.count == 2)
        #expect(rt.state.secondaryHits[1].id == "session:42")
        #expect(rt.takePopup() == nil, "direct secondary pointerDown also intercepted when returning true")
    }

    @Test("ace154ad: onPillSecondary returning false falls through to standard field context menu")
    func onPillSecondaryReturningFalseFallsThrough() throws {
        let rt = makePillRuntime(intercept: false)
        let pts = try locatePillAndPlainPoints(rt)

        rt.secondaryDown(at: pts.pill, at: 0.1)
        #expect(rt.secondaryClaim() == "app")
        rt.secondaryUp(at: pts.pill, mods: .none, at: 0.12)
        #expect(rt.state.secondaryHits.count == 1)
        #expect(rt.state.secondaryHits[0].id == "session:42")
        #expect(rt.takePopup() != nil, "returning false falls through to standard field context menu")
        try rt.resolvePopup(nil)

        // Direct pointerDown(button: .secondary) path also falls through
        rt.pointerDown(at: pts.pill, button: .secondary, at: 0.2)
        rt.pointerUp(at: pts.pill, button: .secondary, at: 0.22)
        _ = rt.frame(at: 0.23)
        #expect(rt.state.secondaryHits.count == 2)
        #expect(rt.takePopup() != nil)
        try rt.resolvePopup(nil)
    }

    @Test("ace154ad: secondary click outside pill skips onPillSecondary, claims 'field', and opens field menu")
    func nonPillSecondaryUsesFieldMenu() throws {
        let rt = makePillRuntime(intercept: true)
        let pts = try locatePillAndPlainPoints(rt)

        rt.secondaryDown(at: pts.plain, at: 0.1)
        #expect(rt.secondaryClaim() == "field", "plain text inside field claims 'field'")
        rt.secondaryUp(at: pts.plain, mods: .none, at: 0.12)
        #expect(rt.state.secondaryHits.isEmpty, "non-pill click does not invoke onPillSecondary")
        #expect(rt.takePopup() != nil, "opens standard field menu")
    }

    @Test("ace154ad: inputPillAt returns nil while IME preedit is active or field is secure")
    func pillHitIgnoredDuringPreeditOrSecure() throws {
        let rt = makePillRuntime(intercept: true)
        let pts = try locatePillAndPlainPoints(rt)
        let info = try #require(findElement(rt, key: "composer"))
        let idx = try #require(rt.nodeByPath[info.path])

        // Active preedit suppresses pill hits
        rt.update(at: 0.1) { s, _ in
            s.edit.setPreedit("あ")
        }
        _ = rt.frame(at: 0.1)
        #expect(rt.inputPillAt(idx, x: pts.pill.x, y: pts.pill.y) == nil)

        // Clearing preedit restores pill hit, secure suppresses it
        rt.update(at: 0.2) { s, _ in
            s.edit.cancelPreedit()
            s.edit.isSecure = true
        }
        _ = rt.frame(at: 0.2)
        #expect(rt.inputPillAt(idx, x: pts.pill.x, y: pts.pill.y) == nil)
    }

    // MARK: - #1297 (055ff4db): Focus: focusVisibleWithinRing & FocusMachine.entry

    @Test("055ff4db: focusVisibleWithinRing shows only when keys put focus there, never on click, handover without ring, or window return")
    func focusVisibleWithinRingParity() throws {
        struct FieldApp {
            var edit = TextEdit("hello")
        }
        let ringColor = Color.srgb(0.15, 0.85, 0.35, 1.0)
        let rt = Runtime<FieldApp>(
            state: FieldApp(),
            viewport: Vec2(320, 180),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col()
                .size(320, 180)
                .p(12)
                .gap(12)
                .child(
                    el()
                        .key("before")
                        .size(80, 28)
                        .focusable(true)
                        .noFocusRing()
                )
                .child(
                    row()
                        .key("frame")
                        .size(220, 44)
                        .p(6)
                        .focusVisibleWithinRing(ringColor, width: 2.5, offset: 2.0)
                        .child(
                            textInput(key: "field", \FieldApp.edit)
                                .size(200, 32)
                                .noFocusRing()
                        )
                )
        }
        rt.setFullKeyboardAccess(true)
        let ring4 = ringColor.simd4(srgb: rt.srgbBlend)
        func hasVisibleWithinRing(in scene: RefScene) -> Bool {
            scene.primitives.contains { p in
                p.params.y == Float(PrimitiveKind.roundedRect.rawValue)
                    && p.params.x > 1.5
                    && abs(p.border.y - ring4.y) < 0.03
            }
        }
        func hasVisibleWithinRingInstance(in rf: RenderFrame) -> Bool {
            rf.instances.contains { inst in
                inst.params.y == KIND_RECT
                    && inst.params.x > 1.5
                    && abs(inst.border.y - ring4.y) < 0.03
            }
        }

        // 1. Initially unfocused -> hidden
        let s0 = rt.frame(at: 0.0)
        #expect(!rt.inputMachines.focusMachine.enteredByKeys)
        #expect(!hasVisibleWithinRing(in: s0))
        #expect(!hasVisibleWithinRingInstance(in: rt.renderFrame(at: 0.0)))

        // 2. Pointer click into field -> hidden, even after pressing Left arrow inside the field
        let fieldRect = try #require(findElement(rt, key: "field")).rect
        let fieldCenter = Vec2(fieldRect[0] + fieldRect[2] * 0.5, fieldRect[1] + fieldRect[3] * 0.5)
        rt.pointerDown(at: fieldCenter, at: 0.05)
        rt.pointerUp(at: fieldCenter, at: 0.06)
        let sClick = rt.frame(at: 0.07)
        #expect(rt.focusedKey == "field")
        #expect(!rt.inputMachines.focusMachine.enteredByKeys)
        #expect(!hasVisibleWithinRing(in: sClick))
        #expect(!hasVisibleWithinRingInstance(in: rt.renderFrame(at: 0.07)))

        _ = rt.keyDown(KeyEvent(key: .arrowLeft), at: 0.08)
        let sArrow = rt.frame(at: 0.09)
        #expect(!rt.inputMachines.focusMachine.enteredByKeys, "typing arrow in clicked field does not make it keyboard-entered")
        #expect(!hasVisibleWithinRing(in: sArrow))

        // 3. Shift+Tab to "before", then Tab into "field" -> ring SHOWS
        _ = rt.keyDown(KeyEvent(key: .tab, mods: Mods(shift: true)), at: 0.10)
        _ = rt.frame(at: 0.11)
        #expect(rt.focusedKey == "before")
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.12)
        let sTab = rt.frame(at: 0.13)
        #expect(rt.focusedKey == "field")
        #expect(rt.inputMachines.focusMachine.enteredByKeys)
        #expect(hasVisibleWithinRing(in: sTab), "Tab into field shows focusVisibleWithinRing")
        #expect(hasVisibleWithinRingInstance(in: rt.renderFrame(at: 0.13)))

        // 4. Window blur -> window refocus -> ring HIDES until keys move focus again
        rt.dispatchFocus(false, at: 0.14)
        _ = rt.frame(at: 0.15)
        rt.dispatchFocus(true, at: 0.16)
        let sReturned = rt.frame(at: 0.17)
        #expect(rt.focusedKey == "field", "focus stays on field")
        #expect(!rt.inputMachines.focusMachine.enteredByKeys, "WindowReturned clears enteredByKeys")
        #expect(!hasVisibleWithinRing(in: sReturned), "window returning to front hides focusVisibleWithinRing")
        #expect(!hasVisibleWithinRingInstance(in: rt.renderFrame(at: 0.17)))

        // 5. Tx.focus with ring: true -> ring SHOWS
        rt.update(at: 0.18) { _, tx in tx.focus("field", ring: true) }
        let sTxRing = rt.frame(at: 0.19)
        #expect(rt.inputMachines.focusMachine.enteredByKeys)
        #expect(hasVisibleWithinRing(in: sTxRing), "Tx.focus(ring: true) shows focusVisibleWithinRing")

        // 6. Tx.focus with ring: false (hand-over without ring) -> ring HIDES
        rt.update(at: 0.20) { _, tx in tx.focus("field", ring: false) }
        let sTxQuiet = rt.frame(at: 0.21)
        #expect(!rt.inputMachines.focusMachine.enteredByKeys)
        #expect(!hasVisibleWithinRing(in: sTxQuiet), "Tx.focus(ring: false) hides focusVisibleWithinRing")
    }

    @Test("055ff4db: focusRing and focusWithinRing clear focusWithinKeyboard")
    func focusRingAndWithinRingClearWithinKeyboard() {
        struct S {}
        let a = El<S>().focusVisibleWithinRing(.white).focusWithinRing(.white)
        #expect(!a.focusWithinKeyboard)
        let b = El<S>().focusVisibleWithinRing(.white).focusRing(.white)
        #expect(!b.focusWithinKeyboard)
        let c = El<S>().focusVisibleWithinRing(.white)
        #expect(c.focusWithinKeyboard)
    }

    // MARK: - #1298, #1302, #1304 (5a3636fa, dc8f7f72, 01096f25): Focus rescue

    @Test("5a3636fa: a focused control disabled while staying in the tree hands focus to its neighbour")
    func disabledFocusedControlRescuesToNeighbour() {
        struct S { var sending = false }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 120), pixelScale: 1.0) { s, _ in
            row()
                .key("bar")
                .size(300, 40)
                .child(el().key("attach").size(60, 30).focusable(true))
                .child(el().key("send").size(60, 30).focusable(true).disabled(s.sending))
                .child(el().key("cancel").size(60, 30).focusable(true))
        }
        rt.setFullKeyboardAccess(true)
        _ = rt.frame(at: 0.0)
        // Tab twice: attach -> send
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.01)
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.02)
        _ = rt.frame(at: 0.03)
        #expect(rt.focusedKey == "send")

        // Disable send while focused -> rescues to next sibling ("cancel")
        rt.update(at: 0.04) { s, _ in s.sending = true }
        _ = rt.frame(at: 0.05)
        #expect(rt.focusedKey == "cancel", "disabled Send hands focus to next neighbour instead of window")
        #expect(rt.focusVisible, "keyboard focus stays visible after rescue")
    }

    @Test("dc8f7f72: Tab stop rescue prefers Tab stops over negative tabIndex controls before falling back to any control")
    func tabStopRescuePrefersTabStopOverNonTabStop() {
        struct S { var disabled = false }
        let rt = Runtime<S>(state: S(), viewport: Vec2(360, 120), pixelScale: 1.0) { s, _ in
            row()
                .key("bar")
                .size(360, 40)
                .child(el().key("send").size(60, 30).focusable(true).disabled(s.disabled))
                .child(el().key("not-tab").size(60, 30).focusable(true).tabIndex(-1))
                .child(el().key("next-tab").size(60, 30).focusable(true))
        }
        rt.setFullKeyboardAccess(true)
        _ = rt.frame(at: 0.0)
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.01)
        _ = rt.frame(at: 0.02)
        #expect(rt.focusedKey == "send")

        rt.update(at: 0.03) { s, _ in s.disabled = true }
        _ = rt.frame(at: 0.04)
        #expect(rt.focusedKey == "next-tab", "Tab stop rescues to next Tab stop, skipping tabIndex(-1)")
    }

    @Test("dc8f7f72: fallbackInNew rescues a control disabled in place inside a kept region")
    func fallbackInNewRescuesDisabledControlInRegion() throws {
        struct S { var disabled = false }
        let rt = Runtime<S>(state: S(), viewport: Vec2(360, 120), pixelScale: 1.0) { s, _ in
            row()
                .key("bar")
                .size(360, 40)
                .child(el().key("first").size(60, 30).focusable(true))
                .child(el().key("send").size(60, 30).focusable(true).disabled(s.disabled))
                .child(el().key("not-tab").size(60, 30).focusable(true).tabIndex(-1))
                .child(el().key("after").size(60, 30).focusable(true))
        }
        rt.setFullKeyboardAccess(true)
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.01) { s, _ in s.disabled = true }
        _ = rt.frame(at: 0.02)

        let sendPath = try #require(findElement(rt, key: "send")).path
        let rescuedIdx = try #require(rt.fallbackInNew(gone: sendPath), "fallbackInNew rescues disabled control")
        #expect(rt.flatNodes[rescuedIdx].key == "after", "fallbackInNew picks next Tab stop after disabled control")
    }

    @Test("dc8f7f72: disabled control inside a memoized region hands focus on")
    func disabledControlInsideMemoizedRegionRescuesFocus() {
        struct S {
            var sending = false
            var other = 0
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(360, 120), pixelScale: 1.0) { s, _ in
            let bar: El<S> = memo("memo-bar", s.sending) {
                row()
                    .key("bar")
                    .size(360, 40)
                    .child(el().key("prev").size(60, 30).focusable(true))
                    .child(el().key("send").size(60, 30).focusable(true).disabled(s.sending))
                    .child(el().key("next").size(60, 30).focusable(true))
            }
            return col()
                .key("root")
                .size(360, 120)
                .child(bar)
        }
        rt.setFullKeyboardAccess(true)
        _ = rt.frame(at: 0.0)
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.01)
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.02)
        _ = rt.frame(at: 0.03)
        #expect(rt.focusedKey == "send")

        // Keep memo untouched once, then flip sending -> rebuilds disabled inside memoized region
        rt.update(at: 0.04) { s, _ in s.other += 1 }
        _ = rt.frame(at: 0.05)
        #expect(rt.focusedKey == "send")

        rt.update(at: 0.06) { s, _ in s.sending = true }
        _ = rt.frame(at: 0.07)
        #expect(rt.focusedKey == "next", "disabled control inside memoized region rescues focus to next sibling")
    }

    @Test("01096f25: closing a tab from its Close button rescues focus to the next tab (or previous tab), never the next tab's Close button")
    func rovingGroupCloseButtonRescuesToNeighbourTab() {
        struct Tabs {
            var ids = ["t1", "t2", "t3"]
        }
        let rt = Runtime<Tabs>(state: Tabs(), viewport: Vec2(400, 120), pixelScale: 1.0) { s, _ in
            var strip: El<Tabs> = row()
                .key("strip")
                .size(360, 40)
                .role(.tabList)
                .focusGroup(true)
            for id in s.ids {
                strip = strip.child(
                    row()
                        .key("tab-\(id)")
                        .size(100, 36)
                        .role(.tab)
                        .focusable(true)
                        .child(
                            el()
                                .key("close-\(id)")
                                .size(20, 20)
                                .role(.button)
                                .focusable(true)
                                .onClick { st in
                                    st.ids.removeAll { $0 == id }
                                }
                        )
                )
            }
            return col()
                .size(400, 120)
                .child(strip)
                .child(el().key("after-strip").size(80, 30).focusable(true))
        }
        rt.setFullKeyboardAccess(true)
        _ = rt.frame(at: 0.0)

        // Focus t1's Close button with keyboard (Tab: tab-t1 -> close-t1)
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.01)
        _ = rt.frame(at: 0.02)
        #expect(rt.focusedKey == "tab-t1")
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.03)
        _ = rt.frame(at: 0.04)
        #expect(rt.focusedKey == "close-t1")

        // Close t1 -> focus must land on tab-t2 (NOT close-t2!)
        rt.update(at: 0.05) { s, _ in s.ids.removeAll { $0 == "t1" } }
        _ = rt.frame(at: 0.06)
        #expect(rt.focusedKey == "tab-t2", "closing t1 from close-t1 rescues to next tab tab-t2, not close-t2")

        // Move to last tab (t3) and its Close button (close-t3)
        rt.update(at: 0.07) { _, tx in tx.focus("close-t3", ring: true) }
        _ = rt.frame(at: 0.08)
        #expect(rt.focusedKey == "close-t3")

        // Close t3 (the last tab!) -> focus must land on previous tab tab-t2 (NOT close-t2 or after-strip!)
        rt.update(at: 0.09) { s, _ in s.ids.removeAll { $0 == "t3" } }
        _ = rt.frame(at: 0.10)
        #expect(rt.focusedKey == "tab-t2", "closing last tab from close-t3 rescues to previous tab tab-t2")
    }

    // MARK: - #1300 (6119711e): Tooltips: helpOpen and HelpLook.onFocus

    @Test("6119711e: El.helpOpen keeps tooltip showing immediately regardless of pointer or press")
    func helpOpenShowsImmediatelyEvenAfterPressAndAway() throws {
        struct CopyState { var copied = false }
        let rt = Runtime<CopyState>(state: CopyState(), viewport: Vec2(240, 120), pixelScale: 1.0) { s, cx in
            cx.setHelpLook(HelpLook.system(dark: true).delay(0.6))
            return col()
                .size(240, 120)
                .p(20)
                .child(
                    el()
                        .key("copy")
                        .size(80, 32)
                        .bg(.white)
                        .focusable(true)
                        .help(s.copied ? "Copied" : "Copy")
                        .helpOpen(s.copied)
                        .onClick { st in st.copied = true }
                )
        }
        _ = rt.frame(at: 0.0)
        #expect(rt.helpTooltip() == nil)

        // Hover and wait for "Copy" to show, then click (which dismisses tooltips on press)
        let r = try #require(findElement(rt, key: "copy")).rect
        let pt = Vec2(r[0] + r[2] * 0.5, r[1] + r[3] * 0.5)
        rt.pointerMove(to: pt, at: 0.1)
        _ = rt.frame(at: 0.1)
        _ = rt.frame(at: 0.8)
        #expect(rt.helpTooltip()?.text == "Copy")

        rt.pointerDown(at: pt, at: 0.9)
        rt.pointerUp(at: pt, at: 0.91)
        _ = rt.frame(at: 0.92)
        #expect(rt.helpTooltip()?.text == "Copied", "helpOpen shows 'Copied' immediately even right after press")

        // Pointer leaves window completely -> still held open!
        rt.pointerExit(at: 0.95)
        _ = rt.frame(at: 0.96)
        #expect(rt.helpTooltip()?.text == "Copied", "helpOpen stays open even when pointer leaves viewport")

        // Clearing helpOpen closes it
        rt.update(at: 1.0) { s, _ in s.copied = false }
        _ = rt.frame(at: 1.01)
        #expect(rt.helpTooltip() == nil)
    }

    @Test("6119711e: with several elements setting helpOpen(true), the first drawn wins")
    func helpOpenFirstDrawnWins() {
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(280, 120), pixelScale: 1.0) { _, cx in
            cx.setHelpLook(HelpLook.system(dark: true).delay(0.6))
            return row()
                .size(280, 120)
                .p(16)
                .gap(16)
                .child(el().key("first").size(80, 32).bg(.white).help("First Held").helpOpen(true))
                .child(el().key("second").size(80, 32).bg(.white).help("Second Held").helpOpen(true))
        }
        _ = rt.frame(at: 0.0)
        #expect(rt.helpTooltip()?.text == "First Held", "first drawn helpOpen tooltip wins")
    }

    @Test("5a3636fa: a focused control that is only hidden (opacity 0) does not rescue to a neighbour")
    func hiddenFocusedControlDoesNotRescue() {
        struct S { var hidden = false }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 120), pixelScale: 1.0) { s, _ in
            row()
                .key("bar")
                .size(300, 40)
                .child(el().key("first").size(60, 30).focusable(true).opacity(s.hidden ? 0 : 1))
                .child(el().key("second").size(60, 30).focusable(true))
        }
        rt.setFullKeyboardAccess(true)
        _ = rt.frame(at: 0.0)
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.01)
        _ = rt.frame(at: 0.02)
        #expect(rt.focusedKey == "first")

        rt.update(at: 0.03) { s, _ in s.hidden = true }
        _ = rt.frame(at: 0.04)
        #expect(rt.focusedKey != "second", "merely hidden control does not hand focus to neighbour")
    }

    @Test("055ff4db: arrow navigation in a focusGroup sets enteredByKeys and lights focusVisibleWithinRing")
    func arrowInFocusGroupLightsFocusVisibleWithinRing() throws {
        struct S {}
        let ringColor = Color.srgb(0.15, 0.85, 0.35, 1.0)
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 120), pixelScale: 1.0) { _, _ in
            row()
                .key("group")
                .size(260, 44)
                .p(4)
                .role(.tabList)
                .focusGroup(true)
                .focusVisibleWithinRing(ringColor, width: 2.5, offset: 2.0)
                .child(el().key("a").size(80, 32).role(.tab).focusable(true).noFocusRing())
                .child(el().key("b").size(80, 32).role(.tab).focusable(true).noFocusRing())
        }
        rt.setFullKeyboardAccess(true)
        _ = rt.frame(at: 0.0)
        let aRect = try #require(findElement(rt, key: "a")).rect
        let aPt = Vec2(aRect[0] + aRect[2] * 0.5, aRect[1] + aRect[3] * 0.5)

        // Click tab 'a' -> not enteredByKeys
        rt.pointerDown(at: aPt, at: 0.01)
        rt.pointerUp(at: aPt, at: 0.02)
        _ = rt.frame(at: 0.03)
        #expect(rt.focusedKey == "a")
        #expect(!rt.inputMachines.focusMachine.enteredByKeys)

        // ArrowRight moves to tab 'b' -> enteredByKeys becomes true
        _ = rt.keyDown(KeyEvent(key: .arrowRight), at: 0.04)
        let sArrow = rt.frame(at: 0.05)
        let ring4 = ringColor.simd4(srgb: rt.srgbBlend)
        let hasRing = sArrow.primitives.contains { p in
            p.params.y == Float(PrimitiveKind.roundedRect.rawValue)
                && p.params.x > 1.5
                && abs(p.border.y - ring4.y) < 0.03
        }
        #expect(rt.focusedKey == "b")
        #expect(rt.inputMachines.focusMachine.enteredByKeys)
        #expect(hasRing, "arrow navigation inside focusGroup lights focusVisibleWithinRing")
    }

    @Test("6119711e: HelpLook.onFocus opens immediately on keyboard focus, not on click, and yields to pointer on another help element")
    func helpLookOnFocusBehavior() throws {
        struct S {
            var onFocus = true
            var clicks = 0
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(320, 140), pixelScale: 1.0) { s, cx in
            cx.setHelpLook(HelpLook.system(dark: true).delay(0.6).onFocus(s.onFocus))
            return row()
                .size(320, 140)
                .p(20)
                .gap(20)
                .child(
                    el()
                        .key("a")
                        .size(80, 32)
                        .bg(.white)
                        .focusable(true)
                        .help("First Tip")
                        .onClick { st in st.clicks += 1 }
                )
                .child(
                    el()
                        .key("b")
                        .size(80, 32)
                        .bg(.white)
                        .focusable(true)
                        .help("Second Tip")
                )
        }
        rt.setFullKeyboardAccess(true)
        #expect(!HelpLook.system(dark: true).onFocus, "onFocus defaults to false")

        // 1. With onFocus == false, Tab does not open tooltip
        rt.update(at: 0.0) { s, _ in s.onFocus = false }
        _ = rt.frame(at: 0.0)
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.01)
        _ = rt.frame(at: 0.02)
        #expect(rt.focusedKey == "a")
        #expect(rt.helpTooltip() == nil, "onFocus(false) keeps tooltip hidden on keyboard focus")

        // 2. Enable onFocus(true) -> keyboard-focused 'a' opens immediately with zero delay
        rt.update(at: 0.05) { s, _ in s.onFocus = true }
        _ = rt.frame(at: 0.06)
        #expect(rt.helpTooltip()?.text == "First Tip", "onFocus(true) opens focused help element immediately")

        // 3. Space press on 'a' suppresses tooltip while focus stays on 'a'
        _ = rt.keyDown(KeyEvent(key: .space), at: 0.10)
        _ = rt.frame(at: 0.11)
        #expect(rt.state.clicks == 1)
        #expect(rt.helpTooltip() == nil, "keyboard press suppresses tooltip while focus remains on trigger")

        // 4. Tab to 'b' -> 'b' opens immediately
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.15)
        _ = rt.frame(at: 0.16)
        #expect(rt.focusedKey == "b")
        #expect(rt.helpTooltip()?.text == "Second Tip")

        // 5. Pointer moves onto 'a' -> pointer wins over keyboard focus on 'b'
        let aRect = try #require(findElement(rt, key: "a")).rect
        let aCenter = Vec2(aRect[0] + aRect[2] * 0.5, aRect[1] + aRect[3] * 0.5)
        rt.pointerMove(to: aCenter, at: 0.20)
        _ = rt.frame(at: 0.21)
        #expect(rt.helpTooltip()?.text != "Second Tip", "pointer over another help element yields keyboard focus tip")
        _ = rt.frame(at: 0.90)
        #expect(rt.helpTooltip()?.text == "First Tip", "pointer-hovered element's tooltip shows after delay")

        // 6. Pointer clicks 'a' and leaves -> pointer focus does NOT open onFocus tooltip
        rt.pointerDown(at: aCenter, at: 1.0)
        rt.pointerUp(at: aCenter, at: 1.01)
        rt.pointerExit(at: 1.02)
        _ = rt.frame(at: 1.03)
        #expect(rt.focusedKey == "a")
        #expect(!rt.focusKeyboard)
        #expect(rt.helpTooltip() == nil, "pointer-focused element does not open onFocus tooltip")
    }
}
