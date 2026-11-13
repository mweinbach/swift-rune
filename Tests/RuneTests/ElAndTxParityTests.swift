import Testing
import Foundation
@testable import Rune
import RuneMotion

@Suite("El and Tx Increment 5B Parity")
struct ElAndTxParityTests {
    private static let red = Color(r: 1, g: 0, b: 0, a: 1)
    private static let green = Color(r: 0, g: 1, b: 0, a: 1)
    private static let blue = Color(r: 0, g: 0, b: 1, a: 1)

    // MARK: - TerminalGrid (`grid_tests.rs`)

    private struct GridState {
        var rows: [TerminalGridRow]
    }

    private static func makeGridRows() -> [TerminalGridRow] {
        let style = TextStyle(size: 13, weight: 400)
        let r0 = TerminalGridRow(
            text: "ab",
            spans: [TextSpan("ab", color: .white)],
            style: style
        )
        .fill(start: 0, end: 1, color: Self.blue)
        .cell(column: 1, width: 1, text: "b", style: style, color: Self.green)
        let r1 = TerminalGridRow(
            text: "cd",
            spans: [TextSpan("cd", color: .white)],
            style: style
        )
        return [r0, r1]
    }

    @Test("TerminalGrid renders fills, glyphs, pinned cells, and overlayShape across row replacement")
    func terminalGridPaintStabilityAndRowReplacement() {
        let rt = Runtime<GridState>(
            state: GridState(rows: Self.makeGridRows()),
            viewport: Vec2(160, 80)
        ) { s, _ in
            col().size(160, 80).itemsStart().child(
                terminalGrid(columns: 10, cellWidth: 8, cellHeight: 18, rows: s.rows)
                    .key("term")
                    .color(.white)
            )
        }
        let scene0 = rt.frame(at: 0)
        let rf0 = rt.renderFrame(at: 0)
        let elem0 = rt.elements().first(where: { $0.key == "term" })
        #expect(elem0?.rect[2] == 80)
        #expect(elem0?.rect[3] == 36)
        #expect(!scene0.primitives.isEmpty)
        #expect(!rf0.instances.isEmpty)

        // Replace rows and add overlayShape; size and primitive stream stay deterministic
        rt.update(at: 0.1) { s, _ in
            var row0 = Self.makeGridRows()[0]
            let shape = Shape().fill(
                [Vec2(0, 0), Vec2(8, 0), Vec2(8, 18), Vec2(0, 18)],
                color: Self.red
            )
            row0 = row0.shape(shape)
            s.rows = [row0]
        }
        let scene1 = rt.frame(at: 0.1)
        let elem1 = rt.elements().first(where: { $0.key == "term" })
        #expect(elem1?.rect[3] == 18)
        #expect(!scene1.primitives.isEmpty)
    }

    // MARK: - Live Colors & FocusFill

    private struct LiveColorState {
        var ink = Live<Color>(.white)
        var edge = Live<Color>(.white)
        var glow = Live<Color>(.white)
        var top = Live<Color>(.white)
        var bottom = Live<Color>(.white)
    }

    @Test("liveTextColor, liveBorder, liveShadow, and liveGradient update primitives without view rebuilds")
    func liveColorsUpdateWithoutViewRerun() {
        let rt = Runtime<LiveColorState>(state: LiveColorState(), viewport: Vec2(200, 120)) { s, _ in
            el().key("card")
                .size(100, 60)
                .bg(.black)
                .border(1, .black)
                .shadow(Shadow(x: 0, y: 2, blur: 4, color: .black))
                .linearGradient(top: .black, bottom: .black)
                .liveBorder(Binding(live: s.edge))
                .liveShadow(Binding(live: s.glow))
                .liveGradient(Binding(live: s.top), Binding(live: s.bottom))
                .child(
                    text("hi")
                        .key("ink")
                        .color(.black)
                        .liveTextColor(Binding(live: s.ink))
                )
        }
        _ = rt.frame(at: 0)
        let initialCommits = rt.viewCommitCount
        let inkBefore = rt.elements().first(where: { $0.key == "ink" })?.textColor
        #expect(inkBefore != nil)
        if let inkBefore {
            #expect(abs(inkBefore.r - 1) < 1e-4 && abs(inkBefore.g - 1) < 1e-4 && abs(inkBefore.b - 1) < 1e-4 && abs(inkBefore.a - 1) < 1e-4)
        }

        rt.state.ink.set(Self.red)
        rt.state.edge.set(Self.green)
        rt.state.glow.set(Self.blue)
        rt.state.top.set(Self.red)
        rt.state.bottom.set(Self.green)

        let scene = rt.frame(at: 1.0 / 60.0)
        #expect(rt.viewCommitCount == initialCommits)
        let inkAfter = rt.elements().first(where: { $0.key == "ink" })?.textColor
        #expect(inkAfter != nil)
        if let inkAfter {
            #expect(abs(inkAfter.r - Self.red.r) < 1e-4 && abs(inkAfter.g - Self.red.g) < 1e-4 && abs(inkAfter.b - Self.red.b) < 1e-4 && abs(inkAfter.a - Self.red.a) < 1e-4)
        }
        #expect(!scene.primitives.isEmpty)
    }

    @Test("focusFill paints focus fill color when keyboard-focused")
    func focusFillPaintsOnKeyboardFocus() {
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(160, 80)) { _, _ in
            el().key("btn")
                .size(80, 32)
                .focusable()
                .focusFill(Self.blue)
        }
        let s0 = rt.frame(at: 0)
        let rectsBefore = s0.primitives.filter { $0.kind == .roundedRect }.count
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.05))
        let s1 = rt.frame(at: 0.05)
        let rectsAfter = s1.primitives.filter { $0.kind == .roundedRect }.count
        #expect(rt.focusedKey == "btn")
        #expect(rt.focusVisible)
        #expect(rectsAfter > rectsBefore)
    }

    // MARK: - Pointer Focus Policies, Background Press & Local Handlers

    private struct FocusPolicyState {
        var edit = TextEdit("hello")
        var bgClicks = 0
        var bgLocal: Vec2? = nil
        var secondaryLocal: Vec2? = nil
        var moveLocal: Vec2? = nil
        var dragDelta: Vec2? = nil
        var windowFocusLog: [Bool] = []
        var screenRects: [[Float]] = []
    }

    @Test("preserveFocusOnPress, pressFocusesBelow, and onBackgroundPress handle focus and callbacks")
    func focusPolicyAndBackgroundPress() {
        let rt = Runtime<FocusPolicyState>(state: FocusPolicyState(), viewport: Vec2(300, 220)) { _, _ in
            col().size(300, 220).children([
                el().key("bg")
                    .size(300, 60)
                    .role(.group)
                    .onBackgroundPress { st, press, _ in
                        st.bgClicks += 1
                        st.bgLocal = press.local
                    },
                textInput(key: "input", \FocusPolicyState.edit)
                    .size(200, 32),
                el().key("toolbarBtn")
                    .size(80, 32)
                    .focusable()
                    .preserveFocusOnPress(),
                el().key("scrollRegion")
                    .size(200, 60)
                    .focusable()
                    .scroll()
                    .child(el().size(200, 120))
                    .child(
                        el().key("overlay")
                            .absolute(x: 0, y: 0)
                            .size(200, 60)
                            .pressFocusesBelow()
                    ),
            ])
        }
        _ = rt.frame(at: 0)
        // onBackgroundPress preserves non-button role and is not focusable
        let bgInfo = rt.elements().first(where: { $0.key == "bg" })
        #expect(bgInfo?.role == ElementRole.group)
        #expect(bgInfo?.focusable == false)

        // Focus input
        rt.pointerDown(at: Vec2(20, 75), at: 0.05)
        rt.pointerUp(at: Vec2(20, 75), at: 0.06)
        #expect(rt.focusedKey == "input")

        // Press toolbarBtn with preserveFocusOnPress -> input stays focused
        rt.pointerDown(at: Vec2(20, 105), at: 0.1)
        rt.pointerUp(at: Vec2(20, 105), at: 0.11)
        #expect(rt.focusedKey == "input")

        // Press overlay with pressFocusesBelow -> focuses scrollRegion underneath
        rt.pointerDown(at: Vec2(20, 140), at: 0.2)
        rt.pointerUp(at: Vec2(20, 140), at: 0.21)
        #expect(rt.focusedKey == "scrollRegion")

        // Press onBackgroundPress surface -> fires handler and blurs focus
        rt.pointerDown(at: Vec2(35, 25), at: 0.3)
        rt.pointerUp(at: Vec2(35, 25), at: 0.31)
        #expect(rt.state.bgClicks == 1)
        #expect(rt.state.bgLocal == Vec2(35, 25))
        #expect(rt.focusedKey == nil)
    }

    @Test("onSecondaryPressLocal, onPointerMoveLocal, onDragAny, onWindowFocus, and onScreenLayout")
    func localPointerAndWindowCallbacks() {
        let rt = Runtime<FocusPolicyState>(state: FocusPolicyState(), viewport: Vec2(240, 160)) { _, _ in
            el().key("root")
                .size(240, 160)
                .onWindowFocus { st, focused, _ in st.windowFocusLog.append(focused) }
                .child(
                    el().key("target")
                        .ml(40)
                        .mt(20)
                        .size(100, 80)
                        .noWindowDrag()
                        .onSecondaryPressLocal { st, press, _ in st.secondaryLocal = press.local }
                        .onPointerMoveLocal { st, press, _ in st.moveLocal = press.local }
                        .onDrag { st, drag, _ in st.dragDelta = drag.delta }
                        .onScreenLayout { st, rect in st.screenRects.append(rect) }
                )
        }
        _ = rt.frame(at: 0)
        #expect(rt.state.screenRects == [[40, 20, 100, 80]])
        #expect(rt.noWindowDragRects.count == 1)

        rt.setWindowOrigin(Vec2(100, 50), at: 0.05)
        #expect(rt.state.screenRects.last == [140, 70, 100, 80])

        rt.pointerMove(to: Vec2(65, 45), at: 0.1)
        #expect(rt.state.moveLocal == Vec2(25, 25))

        rt.pointerDown(at: Vec2(65, 45), button: .secondary, at: 0.12)
        #expect(rt.state.secondaryLocal == Vec2(25, 25))

        rt.pointerDown(at: Vec2(50, 30), button: .primary, at: 0.2)
        rt.pointerMove(to: Vec2(70, 55), at: 0.25)
        rt.pointerUp(at: Vec2(70, 55), at: 0.3)
        #expect(rt.state.dragDelta == Vec2(20, 25))

        rt.dispatchFocus(false, at: 0.35)
        rt.dispatchFocus(true, at: 0.4)
        #expect(rt.state.windowFocusLog == [false, true])

        // Verify onDragAny signature compiles and sets handler
        let anyEl: El<FocusPolicyState> = el().onDragAny { _, tx in tx.instant() }
        #expect(anyEl.handlers.onDrag != nil)
    }

    // MARK: - IME Cursor, AutoGrow, Input Change, Spellcheck, Link, Trace

    @Test("imeCursor tracks rect when no textInput has focus and yields to focused textInput")
    func imeCursorAndFocusedTextInputPriority() {
        struct S { var edit = TextEdit("") }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 120)) { _, _ in
            col().size(200, 120).children([
                el().key("caret").ml(16).mt(12).size(2, 18).imeCursor(),
                textInput(key: "field", \S.edit).size(160, 32),
            ])
        }
        _ = rt.frame(at: 0)
        #expect(rt.imeCursorArea == [16, 12, 2, 18])

        // Focus field -> imeCursorArea yields
        rt.pointerDown(at: Vec2(40, 40), at: 0.05)
        rt.pointerUp(at: Vec2(40, 40), at: 0.06)
        _ = rt.frame(at: 0.06)
        #expect(rt.hasFocusedTextInput)
        #expect(rt.imeCursorArea == nil)
    }

    @Test("autoGrow wraps textInput in bounded min/max height scroll container with wrap")
    func autoGrowWrapsBoundedScroll() {
        struct S { var edit = TextEdit("") }
        let field: El<S> = textInput(key: "field", \S.edit)
            .lineHeight(20)
            .autoGrow(minLines: 2, maxLines: 4)
        #expect(field.keyId == "scroll")
        #expect(!field.layout.scrollAxes.isEmpty)
        #expect(field.layout.minHeight == .points(40))
        #expect(field.layout.maxHeight == .points(80))
        #expect(field.children.first?.textStyle.wrap == .wrap)
    }

    @Test("onInputChange observes/rejects edits and sees nil physicalKey")
    func onInputChangeAndPhysicalKey() {
        struct S {
            var edit = TextEdit("")
            var observed: [String] = []
            var seenPhysical: [PhysicalKeyCode?] = []
            var rejectDigits = false
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 80)) { _, _ in
            textInput(key: "field", \S.edit)
                .size(180, 32)
                .onInputChange { st, newText, tx in
                    st.observed.append(newText)
                    st.seenPhysical.append(tx.physicalKey())
                    return st.rejectDigits && newText.contains(where: \.isNumber)
                }
        }
        _ = rt.frame(at: 0)
        rt.pointerDown(at: Vec2(20, 16), at: 0.05)
        rt.pointerUp(at: Vec2(20, 16), at: 0.06)

        _ = rt.physicalInput(
            .key(key: .keyA, mods: .none, pressed: true, repeat: false),
            fallbackKey: KeyEvent(key: .text("a")),
            at: 0.1
        )
        #expect(rt.state.edit.text == "a")
        #expect(rt.state.observed == ["a"])
        #expect(rt.state.seenPhysical == [nil])

        rt.state.rejectDigits = true
        _ = rt.keyDown(KeyEvent(key: .text("7")), at: 0.15)
        #expect(rt.state.edit.text == "a")
        #expect(rt.state.observed == ["a", "a7"])
    }

    @Test("spellcheck, linkURL, traceName, and traceNamespace store metadata on El")
    func metadataModifiers() {
        struct S {
            var edit = TextEdit("")
            var spellFlag: Bool? = nil
            var langs: [String] = []
        }
        let inp: El<S> = textInput(key: "field", \S.edit)
            .spellcheck()
        #expect(inp.spellcheck)
        let inpHandlers: El<S> = inp
            .onSpellcheck(false) { s, enabled, _ in s.spellFlag = enabled }
            .onSpellcheckLanguages { s, ls, _ in s.langs = ls }
        #expect(!inpHandlers.spellcheck)
        #expect(inpHandlers.handlers.onSpellcheck != nil)
        #expect(inpHandlers.handlers.onSpellcheckLanguages != nil)

        let linkEl: El<S> = el()
            .linkURL("https://example.com")
            .traceName("hero")
            .traceNamespace("Card", "Panel")
        #expect(linkEl.linkURL == "https://example.com")
        #expect(linkEl.traceNameValue == "hero")
        #expect(linkEl.traceNamespaceValue?.className == "Card")
        #expect(linkEl.traceNamespaceValue?.host == "Panel")
    }

    // MARK: - VirtualListState Parity

    @Test("VirtualListState key replacement, quiet mounts, firstVisible, maxOffset, anchorDelta, and needsWindow")
    func virtualListStateHelpers() {
        let vl = VirtualListState(defaultEstimate: 30)
        vl.setKeys(["a", "b", "c", "d"], commit: 1, offset: 0, viewportHeight: 60)
        #expect(vl.replacedView())
        #expect(!vl.mountsQuietly(0, commit: 1))

        vl.frameBegins()
        #expect(!vl.replacedView())
        #expect(vl.mountsQuietly(0, commit: 2))
        vl.recordMeasuredHeight(40, forKey: "a")
        vl.recordMeasuredHeight(50, forKey: "b")
        vl.recordMeasuredHeight(30, forKey: "c")
        vl.recordMeasuredHeight(40, forKey: "d")

        let fv = vl.firstVisible(offset: 45) { $0 == "b" || $0 == "c" }
        #expect(fv?.key == "b")
        #expect(fv?.top == 40)
        #expect(vl.maxOffset(viewportHeight: 60) == 100)
        _ = vl.computeWindow(scrollY: 0, viewportHeight: 60)
        #expect(!vl.needsWindow(offset: 0, viewportHeight: 60))

        // Insert item above anchored row "b" and verify anchorDelta() compensates
        vl.setKeys(["z", "a", "b", "c", "d"], commit: 2, offset: 45, viewportHeight: 60)
        vl.recordMeasuredHeight(25, forKey: "z") // "z" measured at top
        vl.recordMeasuredHeight(40, forKey: "a")
        vl.recordMeasuredHeight(50, forKey: "b") // "b" moved from 40 to 65
        #expect(vl.anchorDelta() == 25)
    }

    // MARK: - Tx Parity (Keys, DragRepeat, Tracing, AssistiveTech, Shell Requests, ReturnFocus, Announce, OpenURL)

    private struct TxState {
        var keyReports: [(focusVisible: Bool, byKeys: Bool, keyRepeat: Bool, phys: PhysicalKeyCode?, base: Character?, at: Double?)] = []
        var sentReceived: [Key] = []
        var dragRepeatFlags: [Bool] = []
        var dragTicks = 0
    }

    @Test("Tx focusVisible, byKeys, keyRepeat, physicalKey, keyBase, inputTime, and sendKey")
    func txKeyContextAndSendKey() {
        let rt = Runtime<TxState>(state: TxState(), viewport: Vec2(200, 100)) { _, _ in
            el().key("box")
                .size(100, 40)
                .focusable()
                .onKey { st, ev, tx in
                    st.keyReports.append((
                        tx.focusVisible(),
                        tx.byKeys,
                        tx.keyRepeat(),
                        tx.physicalKey(),
                        tx.keyBase(),
                        tx.inputTime()
                    ))
                    if ev.key == .text("q") {
                        tx.sendKey(KeyEvent(key: .text("z")))
                        return true
                    }
                    st.sentReceived.append(ev.key)
                    return true
                }
        }
        _ = rt.frame(at: 0)
        #expect(rt.keyDown(KeyEvent(key: .tab), at: 0.05))
        #expect(rt.focusedKey == "box")

        _ = rt.physicalInput(
            .key(key: .keyQ, mods: Mods(alt: true), pressed: true, repeat: true),
            fallbackKey: KeyEvent(key: .text("q"), mods: Mods(alt: true)),
            baseChar: "q",
            at: 0.12
        )
        _ = rt.frame(at: 0.13)

        #expect(rt.state.keyReports.count == 2)
        let first = rt.state.keyReports[0]
        #expect(first.focusVisible == true)
        #expect(first.byKeys == true)
        #expect(first.keyRepeat == true)
        #expect(first.phys == .keyQ)
        #expect(first.base == "q")
        #expect(first.at == 0.12)
        #expect(rt.state.sentReceived == [.text("z")])
    }

    @Test("Tx dragRepeatAfter arms wake deadline and fires dragRepeat() ticks while held")
    func txDragRepeatAfterAndDragRepeat() {
        let rt = Runtime<TxState>(state: TxState(), viewport: Vec2(200, 100)) { _, _ in
            el().key("dragger")
                .size(100, 60)
                .onDrag { st, _, tx in
                    st.dragTicks += 1
                    st.dragRepeatFlags.append(tx.dragRepeat())
                    tx.dragRepeatAfter(0.25)
                }
        }
        _ = rt.frame(at: 0)
        rt.pointerDown(at: Vec2(20, 20), at: 1.0)
        #expect(rt.state.dragTicks == 1)
        #expect(rt.state.dragRepeatFlags == [false])
        #expect(rt.nextWakeDeadline(after: 1.0) == 1.25)

        _ = rt.frame(at: 1.26)
        #expect(rt.state.dragTicks == 2)
        #expect(rt.state.dragRepeatFlags == [false, true])

        rt.pointerUp(at: Vec2(20, 20), at: 1.3)
        #expect(rt.nextWakeDeadline(after: 1.3) == nil)
    }

    @Test("Tx returnFocus, tracing, traceEvent/Channel, assistiveTechnology, toggleMaximized/FullScreen, announce, openURL")
    func txMiscAndShellMethods() throws {
        let rt = Runtime<TxState>(state: TxState(), viewport: Vec2(200, 100)) { _, _ in
            row().size(200, 60).children([
                el().key("a").size(50, 40).focusable(),
                el().key("b").size(50, 40).focusable(),
            ])
        }
        _ = rt.frame(at: 0)
        rt.assistiveTechnology = true
        rt.isTracing = true

        rt.update(at: 0.1) { _, tx in
            #expect(tx.assistiveTechnology())
            #expect(tx.tracing)
            tx.traceEvent("mark")
            tx.traceChannel("fps", "level", 120.0)
            tx.announce("Saved", .assertive)
            tx.toggleMaximized()
            tx.toggleFullScreen()
            tx.returnFocus("b", visible: true)
            try? tx.openURL("https://example.com/a")
            try? tx.openURLSameTab("https://example.com/b")
        }
        _ = rt.frame(at: 0.15)

        #expect(rt.focusedKey == "b")
        #expect(rt.focusVisible)
        #expect(rt.traceEvents == ["mark"])
        #expect(rt.traceChannels?.count == 1)
        #expect(rt.traceChannels?["fps"]?.value == 120.0)
        #expect(rt.lastAnnouncement?.text == "Saved")
        #expect(rt.lastAnnouncement?.politeness == .assertive)
        #expect(rt.toggleMaximizedRequested)
        #expect(rt.toggleFullScreenRequested)
        #expect(rt.urlOpener.takeRequests().count == 2)

        rt.clearShellRequests()
        #expect(!rt.toggleMaximizedRequested)
        #expect(!rt.toggleFullScreenRequested)
    }
}
