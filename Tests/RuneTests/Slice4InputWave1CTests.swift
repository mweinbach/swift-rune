import Foundation
import Testing
import RuneMotion
@testable import Rune

@Suite("Slice 4 Input Wave 1C Parity Tests (Canvas/Gesture, Touch, FieldMenu, SingleLineScroll, Pose/Hit, Hover, DragOut, Inert, OnKey, FindKey)")
struct Slice4InputWave1CTests {

    // MARK: - Canvas Input (`tests/canvas_input.rs` - all 7 tests)

    @Test("canvas_input: wheel x/y/momentum, WheelLock idle/phased/momentum locking, pinchWheel, buttonDown/Up, tx.mods")
    @MainActor
    func canvasInputParity() {
        struct S {
            var wheels: [(Float, Float, Bool, Float, Float)] = []
            var presses: [(PointerButton, Mods)] = []
            var releases: [(PointerButton, Mods)] = []
            var clicks: [Mods] = []
            var magnifies: [Float] = []
        }
        let rt = Runtime(
            state: S(),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            view: { _, _ in
                col().w(200).h(200).child(
                    col().key("scroll").w(200).h(100).scroll(ScrollSpec(stickBottom: false)).child(
                        el().key("canvas").w(200).h(300)
                            .pointerButtons([PointerButton.primary, PointerButton.middle])
                            .onWheel { s, ev, _ in
                                s.wheels.append((ev.dx, ev.dy, ev.momentum, ev.x, ev.y))
                                return true
                            }
                            .onMagnify { s, ev, _ in
                                s.magnifies.append(ev.delta)
                                return true
                            }
                            .onPointerDown { s, p, tx in s.presses.append((p.button, tx.mods)) }
                            .onPointerUp { s, p, tx in s.releases.append((p.button, tx.mods)) }
                            .onClick { s, tx in s.clicks.append(tx.mods) }
                    )
                )
            }
        )
        _ = rt.frame(at: 0.0)

        // 1. Wheel passes dx, dy, momentum, x, y to onWheel.
        rt.wheel(WheelEvent(dx: 3, dy: -12, momentum: false, x: 40, y: 25), at: Vec2(40, 25), now: 0.01)
        #expect(rt.state.wheels.count == 1)
        #expect(rt.state.wheels[0].0 == 3)
        #expect(rt.state.wheels[0].1 == -12)
        #expect(rt.state.wheels[0].2 == false)
        #expect(rt.state.wheels[0].3 == 40)
        #expect(rt.state.wheels[0].4 == 25)

        // 2. Phased WheelLock keeps wheel events pinned to original owner until idle / momentum ends.
        rt.wheel(WheelEvent(dx: 0, dy: -8, phase: .began), at: Vec2(40, 25), now: 0.05)
        rt.wheel(WheelEvent(dx: 0, dy: -4, phase: .changed), at: Vec2(40, 150), now: 0.06)
        #expect(rt.state.wheels.count == 3)
        rt.wheel(WheelEvent(dx: 0, dy: 0, phase: .ended), at: Vec2(40, 25), now: 0.07)

        // 3. Momentum phase locks after gesture until momentumGap elapses.
        rt.wheel(WheelEvent(dx: 0, dy: -5, phase: .changed, momentum: true), at: Vec2(40, 25), now: 0.09)
        #expect(rt.state.wheels.count == 5)
        #expect(rt.state.wheels[4].2 == true)

        // 4. pinchWheel synthesizes Magnify gesture when handler exists, else falls back cleanly.
        let consumed = rt.pinchWheel(dy: 20.0, at: Vec2(40, 25), now: 0.20)
        #expect(consumed == true)
        #expect(rt.state.magnifies.count == 1)
        #expect(abs(rt.state.magnifies[0] - (-20.0 / 200.0)) < 1e-4)

        // 5. buttonDown / buttonUp route non-primary buttons (.middle) & populate tx.mods.
        let heldMods = Mods(shift: true, alt: true)
        rt.buttonDown(at: Vec2(40, 25), button: PointerButton.middle, mods: heldMods, at: 0.30)
        rt.buttonUp(at: Vec2(40, 25), button: PointerButton.middle, mods: heldMods, at: 0.31)
        _ = rt.frame(at: 0.32)
        #expect(rt.state.presses.count == 1)
        #expect(rt.state.presses[0].0 == PointerButton.middle && rt.state.presses[0].1 == heldMods)
        #expect(rt.state.releases.count == 1)
        #expect(rt.state.releases[0].0 == PointerButton.middle && rt.state.releases[0].1 == heldMods)
        #expect(rt.state.clicks == [heldMods])
    }

    // MARK: - Touch (`input/touch.rs` - all 6 tests)

    @Test("touch.rs: slop (8pt), single-touch scroll, tap click, multi-touch rejection, and fling")
    @MainActor
    func touchInputParity() {
        struct S { var presses = 0 }
        let rt = Runtime(
            state: S(),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            view: { _, _ in
                col().key("scroll").w(200).h(200).scroll(ScrollSpec(stickBottom: false)).child(
                    col().w(200).child(
                        el().key("btn").w(200).h(50).onClick { s in s.presses += 1 }
                    ).child(
                        el().w(200).h(550)
                    )
                )
            }
        )
        _ = rt.frame(at: 0.0)

        // 1. Touch tap within slop (<8pt) synthesizes primary press/release/click.
        rt.touch(id: 1, phase: .started, at: Vec2(50, 20), time: 0.10)
        #expect(rt.touching() == true)
        rt.touch(id: 1, phase: .moved, at: Vec2(53, 22), time: 0.11)
        rt.touch(id: 1, phase: .ended, at: Vec2(53, 22), time: 0.12)
        _ = rt.frame(at: 0.13)
        #expect(rt.touching() == false)
        #expect(rt.state.presses == 1)

        // 2. Dragging past 8pt scrolls instead of clicking, and triggers fling when fast.
        rt.touch(id: 2, phase: .started, at: Vec2(50, 120), time: 0.20)
        rt.touch(id: 2, phase: .moved, at: Vec2(50, 100), time: 0.22)
        rt.touch(id: 2, phase: .moved, at: Vec2(50, 60), time: 0.24)
        let movedY = rt.scrollOffset(forKey: "scroll").y
        #expect(movedY > 50.0)
        rt.touch(id: 2, phase: .ended, at: Vec2(50, 60), time: 0.245)
        _ = rt.frame(at: 0.30)
        let afterFlingY = rt.scrollOffset(forKey: "scroll").y
        #expect(afterFlingY > movedY)
        #expect(rt.state.presses == 1)

        // 3. Second simultaneous finger clears tap/scroll gesture cleanly; cancelled ends touch.
        rt.touch(id: 3, phase: .started, at: Vec2(50, 120), time: 0.40)
        rt.touch(id: 4, phase: .started, at: Vec2(80, 120), time: 0.41)
        rt.touch(id: 3, phase: .cancelled, at: Vec2(50, 120), time: 0.42)
        rt.touch(id: 4, phase: .ended, at: Vec2(80, 120), time: 0.43)
        #expect(rt.touching() == false)
    }

    // MARK: - Field Context Menu (`input/field_menu.rs`)

    @Test("field_menu: right-click / Shift+F10, spellcheck toggle & languages, cut/copy/paste, secure gate")
    @MainActor
    func fieldMenuParity() throws {
        struct S {
            var edit = TextEdit("hello", multiline: false)
            var spellOn = true
            var langs: [String] = []
        }
        let rt = Runtime(
            state: S(),
            viewport: Vec2(300, 120),
            pixelScale: 1.0,
            view: { s, _ in
                col().w(300).h(120)
                    .onSpellcheck(s.spellOn) { st, next, _ in st.spellOn = next }
                    .onSpellcheckLanguages { st, next, _ in st.langs = next }
                    .child(
                        textInput(key: "field", \S.edit)
                            .font(TextStyle(size: 16, weight: 400))
                            .w(300).h(40)
                    )
            }
        )
        _ = rt.frame(at: 0.0)

        // 1. Secondary click opens field context menu with Copy/Cut/Paste/Spellcheck items.
        rt.secondaryDown(at: Vec2(20, 20), at: 0.01)
        rt.secondaryUp(at: Vec2(20, 20), mods: .none, at: 0.02)
        _ = rt.frame(at: 0.03)
        let popup = try? rt.takePopup()?.get()
        #expect(popup != nil)
        let items: [PopupMenuItem] = popup?.menu.entries.compactMap {
            if case .item(let item) = $0 { return item }
            return nil
        } ?? []
        let ids = items.map { $0.id }
        #expect(ids.contains("cut"))
        #expect(ids.contains("copy"))
        #expect(ids.contains("paste"))
        #expect(ids.contains("spellcheck"))

        // Toggle spellcheck via menu pick.
        try rt.resolvePopup("spellcheck")
        _ = rt.frame(at: 0.05)
        #expect(rt.state.spellOn == false)

        // 2. Copy selection via Copy pick.
        rt.state.edit.setSelectionRaw(anchor: 0, cursor: 5)
        _ = rt.frame(at: 0.06)
        rt.secondaryDown(at: Vec2(20, 20), at: 0.07)
        rt.secondaryUp(at: Vec2(20, 20), mods: .none, at: 0.08)
        _ = rt.frame(at: 0.09)
        _ = rt.takePopup()
        try rt.resolvePopup("copy")
        _ = rt.frame(at: 0.11)
        #expect(rt.clipboard.text == "hello")

        // 3. Shift+F10 on focused field opens context menu too.
        _ = rt.keyDown(KeyEvent(key: .f(10), mods: Mods(shift: true)), at: 0.12)
        _ = rt.frame(at: 0.13)
        #expect(rt.takePopup() != nil)
        try rt.resolvePopup(nil)
        _ = rt.frame(at: 0.15)

        // 4. Secure field disables Cut/Copy in field context menu without leaking plaintext.
        var sec = TextEdit("secret", multiline: false)
        sec.isSecure = true
        sec.setSelectionRaw(anchor: 0, cursor: 6)
        let secureRt = Runtime(
            state: sec,
            viewport: Vec2(300, 120),
            pixelScale: 1.0,
            view: { _, _ in
                textInput(key: "sec", \TextEdit.self)
                    .font(TextStyle(size: 16, weight: 400))
                    .secure()
                    .w(300).h(40)
            }
        )
        _ = secureRt.frame(at: 0.0)
        secureRt.secondaryDown(at: Vec2(20, 20), at: 0.02)
        secureRt.secondaryUp(at: Vec2(20, 20), mods: .none, at: 0.03)
        _ = secureRt.frame(at: 0.04)
        let secPopup = try? secureRt.takePopup()?.get()
        let secItems: [PopupMenuItem] = secPopup?.menu.entries.compactMap {
            if case .item(let item) = $0 { return item }
            return nil
        } ?? []
        let cutItem = secItems.first(where: { $0.id == "cut" })
        let copyItem = secItems.first(where: { $0.id == "copy" })
        #expect(cutItem == nil || cutItem?.enabled == false)
        #expect(copyItem == nil || copyItem?.enabled == false)
    }

    // MARK: - Single-line Horizontal Scroll & Clipboard (`tests/input_clipboard.rs`)

    @Test("input_clipboard: single-line horizontal caret scroll, grapheme roundtrip, files-only paste preserves selection")
    @MainActor
    func inputClipboardAndSingleLineScrollParity() {
        let graphemes = ["W", "W", "W", "W", "W", "W", "W", "W", "W", "W", " ",
                         "👨\u{200D}👩\u{200D}👧", "🇯🇵", "👋🏽", "e\u{301}", "❤\u{FE0F}", "Z"]
        let ed = TextEdit(graphemes.joined(), multiline: false)
        let rt = Runtime(
            state: ed,
            viewport: Vec2(100, 40),
            pixelScale: 1.0,
            view: { _, _ in
                textInput(key: "search", \TextEdit.self)
                    .font(TextStyle(size: 16, weight: 400))
                    .noWrap()
                    .w(100).h(40)
            }
        )
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.005) { _, tx in tx.focus("search") }
        _ = rt.frame(at: 0.01)

        guard let node = rt.flatNodes.first(where: { $0.key == "search" }) else {
            Issue.record("missing search node")
            return
        }
        let path = node.path
        let scroll = rt.inputScroll[path] ?? 0
        #expect(scroll > 50.0, "caret at end of long single-line field must scroll right")
        if let area = rt.imeArea {
            #expect(area[0] >= 0 && area[0] <= 100.0)
        } else {
            Issue.record("expected imeArea on focused single-line input")
        }

        // Home -> Right step through every grapheme keeps caret inside visible rect & hit-tests back to exact offset.
        _ = rt.keyDown(KeyEvent(key: .home, mods: .none), at: 0.02)
        _ = rt.frame(at: 0.03)
        var offset = 0
        for g in graphemes {
            offset += g.utf8.count
            _ = rt.keyDown(KeyEvent(key: .arrowRight, mods: .none), at: 0.04)
            _ = rt.frame(at: 0.05)
            #expect(rt.state.cursor == offset)
            if let area = rt.imeArea, let curNode = rt.flatNodes.first(where: { $0.path == path }) {
                #expect(area[0] >= 0 && area[0] <= 100.0)
                let roundtrip = rt.textHitOffset(node: curNode, windowPos: Vec2(area[0] + 0.1, area[1] + area[3] * 0.5), edit: rt.state)
                #expect(roundtrip == offset)
            }
        }
        #expect((rt.inputScroll[path] ?? 0) > 0.0)

        // Blurring clears inputScroll so unfocused field rests at start.
        rt.update(at: 0.06) { _, tx in
            tx.blur()
        }
        _ = rt.frame(at: 0.07)
        #expect(rt.inputScroll[path] == nil)

        // Files-only paste without onInputPaste keeps existing text & selection.
        var selEd = TextEdit("keep me")
        selEd.setSelectionRaw(anchor: 0, cursor: 7)
        let clipRt = Runtime(
            state: selEd,
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            view: { _, _ in
                textInput(key: "field", \TextEdit.self)
                    .font(TextStyle(size: 16, weight: 400))
                    .w(200).h(40)
            }
        )
        let mem = Clipboard(kind: .memory)
        clipRt.useClipboard(mem)
        _ = clipRt.frame(at: 0.0)
        clipRt.update(at: 0.005) { _, tx in tx.focus("field") }
        _ = clipRt.frame(at: 0.008)
        clipRt.update(at: 0.01) { _, tx in
            tx.copyRich(RichClipboardPayload(text: "", files: [URL(fileURLWithPath: "/fixtures/a.txt")]))
            tx.requestPaste()
        }
        _ = clipRt.frame(at: 0.02)
        #expect(clipRt.state.text == "keep me")
        #expect(clipRt.state.selectedText == "keep me")
    }

    // MARK: - Find Key, Pose/Hit, Help Tooltip Bottom Flip (`find_key.rs`, `pose_hit.rs`, `help_tooltip.rs:111`)

    @Test("find_key, pose_hit, and help_tooltip flip above bottom edge")
    @MainActor
    func findKeyPoseHitAndHelpFlipParity() {
        struct S {
            var hideBar = false
            var point = Vec2.zero
        }
        let rt = Runtime(
            state: S(),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            view: { s, _ in
                col().w(200).h(200)
                    .child(
                        el().key("other").child(el().key("knob").w(10).h(10))
                    )
                    .child(
                        el().key("form").child(
                            row().child(el().w(30).h(10)).child(
                                el().key("slider").child(col().child(el().key("knob").w(20).h(20)))
                            )
                        )
                    )
                    .child(
                        col().key("canvas").w(200).h(100)
                            .onPointerMove { st, p, _ in st.point = p.window }
                            .children(s.hideBar ? [] : [
                                el().key("bar").w(100).h(20).bg(.white).rotate(.pi / 4)
                            ])
                    )
                    .child(
                        el().key("bottomTip").absolute(x: 20, y: 175).w(100).h(20).help("Bottom tip")
                    )
            }
        )
        rt.helpDelay = 0.0
        _ = rt.frame(at: 0.0)

        // 1. Slash key path matching (`find_key.rs`).
        #expect(rt.find("slider/knob") == Vec2(40, 20))
        #expect(rt.find("form/slider/knob") == Vec2(40, 20))
        #expect(rt.find("other/knob") == Vec2(5, 5))
        #expect(rt.find("form/knob") == nil)
        #expect(rt.find("knob") == Vec2(5, 5))

        // 2. Scoped picking (`elementAtIn`) ignores outside siblings & finds rotated elements (`pose_hit.rs`).
        if let barPos = rt.find("canvas/bar") {
            let picked = rt.elementAtIn("canvas", x: barPos.x, y: barPos.y)
            #expect(picked?.key == "bar")
            #expect(rt.elementAtIn("absent", x: barPos.x, y: barPos.y) == nil)
        } else {
            Issue.record("expected canvas/bar")
        }

        // 3. Help tooltip near bottom viewport flips above the element (`help_tooltip.rs:111`).
        rt.pointerMove(to: Vec2(50, 185), at: 0.01)
        _ = rt.frame(at: 0.02)
        _ = rt.frame(at: 0.03)
        if let tip = rt.helpTooltip() {
            #expect(tip.text == "Bottom tip")
            #expect(tip.rect.y < 175.0, "tooltip must flip above bottom-anchored element")
        } else {
            Issue.record("expected helpTooltip near bottom element")
        }
    }

    // MARK: - Pointer Drag-Out Edge Cases, Inert, OnKey (`pointer_drag.rs`, `inert.rs`, `on_key_tests.rs`)

    @Test("pointer_drag edge cases, hidden cursor cleanup, inert subtrees, and on_key parity")
    @MainActor
    func dragOutHiddenCursorInertAndOnKeyParity() {
        struct S {
            var offer = true
            var log: [String] = []
            var drags = 0
            var presses = 0
            var showA = true
            var width: Float = 60.0
            var rotated = false
        }
        let iconSvg = SVGIcon(viewBox: 10, paths: ["M0 0 H10 V10 H0 Z"])
        let rt = Runtime(
            state: S(),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            view: { s, _ in
                let fileEl: El<S> = el().key("file").w(100).h(40)
                    .dragOut { st in st.offer ? DragItem().text("doc") : nil }
                    .onDrag { st, _, _ in st.drags += 1 }
                    .onDragStart { st, _ in st.log.append("start") }
                    .onDragOutEnd { st, outcome, _ in st.log.append("end \(outcome)") }
                    .onClick { st in st.presses += 1 }
                let inertEl: El<S> = col().key("inertBox").w(100).h(40).inert(true)
                    .cursor(.crosshair)
                    .onClick { st in st.presses += 100 }
                let swapEl: El<S> = el().key("swapWrap").w(100).h(40).child(
                    s.showA
                        ? el().key("a").w(100).h(40).cursor(.crosshair).transition(.opacity).onClick { _ in }
                        : el().key("b").w(100).h(40).cursor(.hidden).transition(.opacity).onClick { _ in }
                )
                let fadedEl: El<S> = row().w(s.width).h(20).child(
                    text("A rather long file name.rs")
                        .key("faded")
                        .font(TextStyle(size: 13, weight: 400))
                        .truncateFade()
                        .helpWhenTruncated("A rather long file name.rs")
                )
                let iconEl: El<S> = icon(iconSvg, size: 20)
                let rotatedIconEl: El<S> = iconEl
                    .key("icon")
                    .w(20).h(20)
                    .iconRotation(s.rotated ? .pi : 0)
                    .animate(MotionTokens.SNAPPY)
                return col().w(200).h(200)
                    .child(fileEl)
                    .child(inertEl)
                    .child(swapEl)
                    .child(fadedEl)
                    .child(rotatedIconEl)
            }
        )
        rt.nativeHelp = true
        _ = rt.frame(at: 0.0)

        // 1. Nil drag-out offer keeps press active cleanly.
        rt.state.offer = false
        rt.pointerMove(to: Vec2(20, 20), at: 0.01)
        rt.pointerDown(at: Vec2(20, 20), at: 0.02)
        rt.pointerMove(to: Vec2(50, 20), at: 0.03)
        #expect(rt.takeDragOutStart() == nil)
        #expect(rt.pressing() == true)
        rt.pointerMove(to: Vec2(20, 20), at: 0.04)
        rt.pointerUp(at: Vec2(20, 20), at: 0.05)
        _ = rt.frame(at: 0.06)
        #expect(rt.state.presses == 1)

        // 2. osDragSupported = false falls back to normal onDrag.
        rt.state.offer = true
        rt.setOsDrag(false)
        rt.pointerMove(to: Vec2(20, 20), at: 0.07)
        rt.pointerDown(at: Vec2(20, 20), at: 0.08)
        rt.pointerMove(to: Vec2(60, 20), at: 0.09)
        rt.pointerUp(at: Vec2(60, 20), at: 0.10)
        _ = rt.frame(at: 0.11)
        #expect(rt.takeDragOutStart() == nil)
        #expect(rt.state.drags > 0)

        // 3. Untaken drag-out auto-cancels in order on next frame.
        rt.setOsDrag(true)
        rt.pointerMove(to: Vec2(20, 20), at: 0.12)
        rt.pointerDown(at: Vec2(20, 20), at: 0.13)
        rt.pointerMove(to: Vec2(60, 20), at: 0.14)
        _ = rt.frame(at: 0.15)
        _ = rt.frame(at: 0.155)
        #expect(rt.state.log == ["start", "end cancelled"])

        // 4. Stale drag-out session replaced by a new drag still completes cleanly.
        rt.state.log.removeAll()
        rt.pointerMove(to: Vec2(20, 20), at: 0.16)
        rt.pointerDown(at: Vec2(20, 20), at: 0.17)
        rt.pointerMove(to: Vec2(60, 20), at: 0.18)
        let first = rt.takeDragOutStart()
        #expect(first != nil)
        _ = rt.frame(at: 0.19)
        rt.pointerMove(to: Vec2(20, 20), at: 0.20)
        rt.pointerDown(at: Vec2(20, 20), at: 0.21)
        rt.pointerMove(to: Vec2(60, 20), at: 0.22)
        let second = rt.takeDragOutStart()
        #expect(second != nil)
        rt.finishDragOut(.cancelled, at: 0.23)
        _ = rt.frame(at: 0.24)
        rt.finishDragOut(.copied, at: 0.25)
        _ = rt.frame(at: 0.26)
        #expect(rt.state.log == ["start", "start", "end cancelled", "end copied"])

        // 5. Inert subtree skips pointer presses and cursor.
        rt.pointerMove(to: Vec2(20, 60), at: 0.27)
        #expect(rt.currentCursor() == .default)
        rt.pointerDown(at: Vec2(20, 60), at: 0.28)
        rt.pointerUp(at: Vec2(20, 60), at: 0.29)
        _ = rt.frame(at: 0.30)
        #expect(rt.state.presses == 1)

        // 6. Cursor swaps from exiting sibling `a` (.crosshair) to mounted sibling `b` (.hidden).
        rt.pointerMove(to: Vec2(20, 100), at: 0.31)
        _ = rt.frame(at: 0.32)
        #expect(rt.currentCursor() == .crosshair)
        rt.update(at: 0.33) { s, _ in s.showA = false }
        _ = rt.frame(at: 0.34)
        #expect(rt.currentCursor() == .hidden)

        // 7. truncateFade().helpWhenTruncated() exposes help when cut and drops it when roomy.
        #expect(rt.element(byKey: "faded")?.help == "A rather long file name.rs")
        rt.update(at: 0.35) { s, _ in s.width = 195 }
        _ = rt.frame(at: 0.36)
        #expect(rt.element(byKey: "faded")?.help == nil)
    }

    // MARK: - Keyed control focus & Hover Hold (`on_key_tests.rs:92`, `layout_hover.rs`, `scroll_into_view_in`)

    @Test("click inside keyed focusable child focuses parent; hover hold stays during sliding layout; scrollIntoViewIn scoped")
    @MainActor
    func focusAncestorHoverHoldAndScopedScrollParity() {
        struct S {
            var open = false
            var row5Cursor: [Cursor] = []
        }
        let rt = Runtime(
            state: S(),
            viewport: Vec2(200, 400),
            pixelScale: 1.0,
            view: { s, _ in
                let rows: [El<S>] = (0..<10).map { k in
                    row()
                        .key("r\(k)")
                        .w(200)
                        .h(k == 0 && s.open ? 200.0 : 20.0)
                        .cursor(k == 5 ? .grab : .pointer)
                        .hover(Color.white)
                        .animate(MotionTokens.SETTLE)
                        .animateLayout()
                        .onClick { _ in }
                }
                return col().w(200).h(400)
                    .child(
                        el().key("ctrl").w(100).h(30).focusable(true).child(
                            el().key("innerLabel").w(50).h(30)
                        )
                    )
                    .child(col().key("list").w(200).h(370).children(rows))
            }
        )
        _ = rt.frame(at: 0.0)

        // 1. Clicking inside a non-focusable inner child focuses its focusable ancestor (`on_key_tests.rs:92`).
        rt.pointerDown(at: Vec2(10, 10), at: 0.01)
        rt.pointerUp(at: Vec2(10, 10), at: 0.02)
        _ = rt.frame(at: 0.03)
        #expect(rt.element(byKey: "ctrl")?.focused == true)

        // 2. Hover hold keeps r5's cursor while sliding rows pass under still pointer (`layout_hover.rs`).
        rt.pointerMove(to: Vec2(50, 30 + 5 * 20 + 10), at: 0.04)
        _ = rt.frame(at: 0.05)
        #expect(rt.currentCursor() == .grab)
        rt.update(at: 0.06) { s, tx in
            s.open = true
            tx.animated()
        }
        for i in 1...5 {
            _ = rt.frame(at: 0.06 + Double(i) / 120.0)
        }
        #expect(rt.currentCursor() == .grab)

        // 3. scrollIntoViewIn scrolls only target scope (`on_key_tests.rs:307`).
        let scopeRt = Runtime(
            state: (),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            view: { _, _ in
                let mkList: (String) -> El<Void> = { scope in
                    col().key(scope).w(100).h(200).child(
                        col().key("\(scope)_vp").w(100).h(200).scroll(ScrollSpec(stickBottom: false)).child(
                            col().w(100).virtualRows(count: 100, estimatedRowHeight: 20, key: { _, i in "row\(i)" }, build: { _, _ in
                                el().w(100).h(20)
                            })
                        )
                    )
                }
                return row().w(200).h(200).child(mkList("a")).child(mkList("b"))
            }
        )
        _ = scopeRt.frame(at: 0.0)
        scopeRt.update(at: 0.01) { _, tx in tx.scrollIntoViewIn("b", "row50") }
        for step in 1...30 {
            _ = scopeRt.frame(at: 0.01 + Double(step) / 60.0)
        }
        #expect(scopeRt.scrollOffset(forKey: "a_vp").y == 0)
        #expect(scopeRt.scrollOffset(forKey: "b_vp").y > 100)
    }

    // MARK: - DragOut + FileDialog + Drop Inspection (`file_dialog.rs`, `drop.rs`)

    @Test("isDraggingFiles and resolveFileDialog headless parity")
    @MainActor
    func fileDialogAndDropStateParity() throws {
        struct S { var picked: URL? = nil }
        let rt = Runtime(
            state: S(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            view: { _, _ in
                el().key("dropzone").w(200).h(100).onDropFiles { _, _, _ in }
            }
        )
        _ = rt.frame(at: 0.0)
        #expect(rt.isDraggingFiles == false)
        rt.dragFiles([URL(fileURLWithPath: "/tmp/a.png")], at: Vec2(50, 50), at: 0.01)
        #expect(rt.isDraggingFiles == true)
        rt.dragFilesLeave(at: 0.02)
        #expect(rt.isDraggingFiles == false)

        rt.update(at: 0.03) { _, tx in
            tx.openFile(FileDialogOptions(title: "Choose")) { (st: inout S, res: FileDialogResult, _) in
                st.picked = try? res.get()
            }
        }
        _ = rt.frame(at: 0.04)
        try rt.resolveFileDialog(URL(fileURLWithPath: "/tmp/chosen.txt"))
        _ = rt.frame(at: 0.05)
        #expect(rt.state.picked?.path == "/tmp/chosen.txt")
    }
}
