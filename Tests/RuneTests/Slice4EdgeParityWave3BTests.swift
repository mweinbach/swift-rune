#if os(macOS)
import AppKit
#endif
import Foundation
import Testing
@testable import Rune

@Suite("Slice 4 Remaining Edge Parity Wave 3B")
@MainActor
struct Slice4EdgeParityWave3BTests {

    @Test("pointer_hit.rs:60,111: idle overlay pointer stays quiet; deleting focused row skips stale edit accessor")
    func overlayIdleAndDeletingFocusedRowParity() {
        // 1. Idle pointer inside .hit() overlay does not re-fire hover or queue pending input.
        var enters = 0
        let ovRt = Runtime(state: 0, viewport: Vec2(100, 100), pixelScale: 1.0) { _, _ in
            el().child(
                el().key("chip").size(40, 20).hit().onHover { n, inside, _ in if inside { n += 1; enters += 1 } }
            )
        }
        _ = ovRt.frame(at: 0.0)
        ovRt.pointerMove(to: Vec2(5, 5), at: 0.01)
        _ = ovRt.frame(at: 0.01)
        #expect(ovRt.state == 1 && enters == 1)
        ovRt.pointerMove(to: Vec2(6, 5), at: 0.02)
        _ = ovRt.frame(at: 0.02)
        ovRt.pointerMove(to: Vec2(90, 90), at: 0.03)
        _ = ovRt.frame(at: 0.03)
        ovRt.pointerMove(to: Vec2(200, 90), at: 0.04)
        _ = ovRt.frame(at: 0.04)
        #expect(ovRt.state == 1 && enters == 1)
        #expect(!ovRt.hasPendingInput)

        // 2. Deleting a focused row does not invoke a stale subscript accessor on commit/key cleanup.
        struct SafeRows {
            var rows: [TextEdit] = [TextEdit("hello")]
        }
        let delRt = Runtime(state: SafeRows(), viewport: Vec2(200, 100), pixelScale: 1.0) { s, _ in
            var c: El<SafeRows> = col().size(200, 100)
            for i in s.rows.indices {
                c = c.child(
                    textInput(key: "row-\(i)", \SafeRows.rows[i])
                        .font(TextStyle(size: 14))
                        .size(120, 30)
                )
            }
            return c.child(
                el().key("delete").size(40, 40).focusable().onClick { st, _ in st.rows.removeAll() }
            )
        }
        delRt.update(at: 0.0) { _, tx in tx.focus("row-0") }
        _ = delRt.frame(at: 0.0)
        #expect(delRt.focusedKey == "row-0")
        let del = delRt.element(byKey: "delete")!.rect
        let pt = Vec2(del[0] + del[2] * 0.5, del[1] + del[3] * 0.5)
        delRt.pointerDown(at: pt, at: 0.01)
        delRt.pointerUp(at: pt, at: 0.01)
        _ = delRt.frame(at: 0.01)
        #expect(delRt.state.rows.isEmpty)
        #expect(!delRt.hasFocus() || delRt.focusedKey == "delete")
        #expect(delRt.focusedKey != "row-0")
    }

    @Test("A focused scroll view takes arrows by a line and Space by a page")
    func focusedScrollerKeys() {
        let rt = Runtime(state: false, viewport: Vec2(200, 200), pixelScale: 1.0) { pressable, _ in
            let rows: [El<Bool>] = (0..<20).map { el().key("r\($0)").size(200, 40) }
            var scroll: El<Bool> = col().key("scroll").size(200, 200)
                .scroll(ScrollSpec(stickBottom: false)).focusable()
                .child(col().key("list").wFull().children(rows))
            if pressable { scroll = scroll.onClick { state in state = false } }
            return col().size(200, 200).child(scroll)
        }
        _ = rt.frame(at: 0)
        rt.pointerDown(at: Vec2(100, 100), at: 0.01)
        rt.pointerUp(at: Vec2(100, 100), at: 0.02)
        _ = rt.frame(at: 0.05)
        #expect(rt.focusedKey == "scroll")

        func press(_ key: Key, mods: Mods = .none, repeat held: Bool = false, at time: Double) -> Bool {
            let handled = rt.keyDown(KeyEvent(key: key, mods: mods), isRepeat: held, at: time)
            _ = rt.frame(at: time)
            return handled
        }
        func top() -> Float? { rt.presented("r0")?.rect[1] }
        #expect(press(.arrowDown, at: 0.1))
        #expect(top() == -40)
        #expect(!press(.arrowDown, mods: Mods(shift: true), at: 0.15))
        #expect(!press(.space, mods: Mods(alt: true), at: 0.16))
        #expect(top() == -40)
        #expect(press(.text(" "), at: 0.2))
        #expect(top() == -220)
        #expect(press(.space, mods: Mods(shift: true), at: 0.3))
        #expect(top() == -40)
        #expect(press(.arrowUp, at: 0.4))
        #expect(top() == 0)
        #expect(press(.pageDown, at: 0.5))
        #expect(top() == -180)
        #expect(press(.space, repeat: true, at: 0.6))
        #expect(top() == -360)

        rt.update(at: 0.7) { state, _ in state = true }
        _ = rt.frame(at: 0.7)
        #expect(press(.space, at: 0.8))
        #expect(!rt.state)
        #expect(top() == -360)
    }

    #if os(macOS)
    @Test("The macOS host forwards held Space without activating a pressable scroller again")
    func nativeSpaceRepeatOnAPressableScroller() throws {
        let rt = Runtime(state: 0, viewport: Vec2(200, 200), pixelScale: 1) { _, _ in
            col().key("scroll").size(200, 200).scrollY().focusable()
                .onClick { count in count += 1 }
                .child(el().size(200, 800))
        }
        rt.update(at: 0) { _, tx in tx.focus("scroll") }
        _ = rt.frame(at: 0)
        #expect(rt.focusedKey == "scroll")
        let view = RuneMetalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), runtime: rt,
                                     renderer: try MetalRenderer(), timeScale: 1, respectSystemAppearance: false)
        for held in [false, true] {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: held, keyCode: 49
            ))
            #expect(view.dispatchNativeKeyEvent(event))
            #expect(rt.state == 1)
            #expect(rt.scrollOffset(forKey: "scroll").y == 0)
        }
    }
    #endif

    @Test("A key lands the vertical finger fling and leaves a horizontal glide alone")
    func keyboardScrollLandsOnlyTheVerticalLane() throws {
        let rt = Runtime(state: (), viewport: Vec2(200, 200), pixelScale: 1) { _, _ in
            col().key("scroll").size(200, 200).focusable().scrollXY()
                .child(el().key("content").size(800, 1200))
        }
        _ = rt.frame(at: 0)
        rt.touchDown(id: 1, at: Vec2(90, 160), time: 0.01)
        rt.touchMove(id: 1, at: Vec2(90, 100), time: 0.06)
        rt.touchUp(id: 1, at: Vec2(90, 100), time: 0.07)
        _ = rt.frame(at: 0.08)
        let path = try #require(rt.element(byKey: "scroll")?.path)
        #expect(rt.focusedKey == "scroll")
        #expect((rt.slice2State.scrollModes[path]?.coast() ?? 0) > 0)
        let before = rt.scrollOffset(forKey: "scroll").y
        #expect(rt.keyDown(KeyEvent(key: .arrowDown), at: 0.09))
        for i in 1...5 { _ = rt.frame(at: 0.09 + Double(i) / 60) }
        #expect(abs(rt.scrollOffset(forKey: "scroll").y - (before + 40)) < 0.01)
        #expect(rt.slice2State.touchScroll == nil)

        rt.update(at: 0.2) { _, tx in tx.scrollTo("scroll", x: 300, y: before + 40) }
        _ = rt.frame(at: 0.22)
        let start = rt.scrollOffset(forKey: "scroll").x
        #expect(start < 300)
        #expect(rt.keyDown(KeyEvent(key: .space), at: 0.23))
        _ = rt.frame(at: 0.25)
        #expect(rt.scrollOffset(forKey: "scroll").x > start)
        for i in 1...120 { _ = rt.frame(at: 0.25 + Double(i) / 60) }
        #expect(rt.scrollOffset(forKey: "scroll").x == 300)
        #expect(abs(rt.scrollOffset(forKey: "scroll").y - (before + 220)) < 0.01)
    }

    @Test("Page keys skip scroll views behind a modal and under an exiting ancestor")
    func keyboardScrollRespectsModalAndAncestorExit() throws {
        let rt = Runtime(state: true, viewport: Vec2(200, 200), pixelScale: 1) { modal, _ in
            var root: El<Bool> = col().key("root").size(200, 200)
                .child(col().key("wrapper").size(200, 200).child(
                    col().key("scroll").size(200, 200).scrollY()
                        .child(el().size(200, 800))))
            if modal { root = root.child(el().key("dialog").size(20, 20).modal()) }
            return root
        }
        _ = rt.frame(at: 0)
        #expect(rt.activeModalPath != nil)
        #expect(!rt.keyDown(KeyEvent(key: .pageDown), at: 0.1))
        #expect(rt.scrollOffset(forKey: "scroll").y == 0)

        rt.update(at: 0.2) { state, _ in state = false }
        _ = rt.frame(at: 0.2)
        let wrapper = try #require(rt.flatNodes.first { $0.key == "wrapper" })
        rt.scene.setTransition(wrapper.nodeId, .opacity)
        rt.scene.remove(wrapper.nodeId)
        #expect(rt.scene.isExiting(wrapper.nodeId))
        #expect(!rt.keyDown(KeyEvent(key: .pageDown), at: 0.3))
        #expect(rt.scrollOffset(forKey: "scroll").y == 0)
    }

    @Test("input_clipboard.rs:5,39,250: PageUp/Down scrolls focused input viewport & scrolled-out virtual list; image/files paste routing")
    func pageKeysInputScrollAndRichImageFilesClipboardParity() throws {
        // 1. PageDown/PageUp reaches focused single-line input onInputKey & pages scroll view by 90% viewport.
        struct PageS {
            var edit = TextEdit("hello")
            var keys: [Key] = []
        }
        let rt = Runtime(state: PageS(), viewport: Vec2(200, 200), pixelScale: 1.0) { _, _ in
            let field = textInput(key: "field", \PageS.edit)
                .font(TextStyle(size: 14))
                .size(200, 40)
                .onInputKey { st, ev, _ in
                    st.keys.append(ev.key)
                    return false
                }
            var list = col().key("list").wFull().child(field)
            for i in 0..<20 {
                list = list.child(el().key("r\(i)").size(200, 40))
            }
            return col().size(200, 200).child(
                col().key("scroll").size(200, 200).scroll(ScrollSpec(stickBottom: false)).child(list)
            )
        }
        rt.update(at: 0.0) { _, tx in tx.focus("field") }
        _ = rt.frame(at: 0.0)
        func top(_ key: String) -> Float? { rt.element(byKey: key)?.rect[1] }
        #expect(top("r0") == 40)
        _ = rt.keyDown(KeyEvent(key: .pageDown), at: 0.1); _ = rt.frame(at: 0.1)
        #expect(rt.state.keys == [.pageDown])
        #expect(abs((top("r0") ?? 999) - (40 - 180)) < 0.5)
        #expect(rt.state.edit.text == "hello")
        for t in [0.2, 0.3, 0.4] {
            _ = rt.keyDown(KeyEvent(key: .pageDown), at: t); _ = rt.frame(at: t)
        }
        #expect(abs((top("r0") ?? 999) - (40 - 640)) < 0.5, "clamped at bottom")
        _ = rt.keyDown(KeyEvent(key: .pageUp), at: 0.5); _ = rt.frame(at: 0.5)
        #expect(abs((top("r0") ?? 999) - (40 - 460)) < 0.5)

        // 2. PageDown keeps paging the virtual list of a focused field even after it scrolls out.
        struct TwoPane {
            var edit = TextEdit("hello")
        }
        let vpRt = Runtime(state: TwoPane(), viewport: Vec2(200, 200), pixelScale: 1.0) { _, _ in
            let field = textInput(key: "field", \TwoPane.edit).font(TextStyle(size: 14)).size(100, 40)
            let rows = col().key("rows").wFull().virtualRows(
                count: 100,
                estimatedRowHeight: 40,
                key: { (_: TwoPane, i: Int) in "r\(i)" },
                build: { (_: TwoPane, i: Int) -> El<TwoPane> in
                    if i == 0 {
                        return col().key("r0").size(100, 40).child(field)
                    }
                    return el().key("r\(i)").size(100, 40)
                }
            )
            var other: El<TwoPane> = col().key("other").wFull()
            for i in 0..<100 {
                other = other.child(el().key("o\(i)").size(100, 40))
            }
            return row().size(200, 200)
                .child(col().key("left").size(100, 200).scroll(ScrollSpec(stickBottom: false)).child(rows))
                .child(col().key("right").size(100, 200).scroll(ScrollSpec(stickBottom: false)).child(other))
        }
        vpRt.update(at: 0.0) { _, tx in tx.focus("field") }
        _ = vpRt.frame(at: 0.0)
        vpRt.pointerMove(to: Vec2(150, 100), at: 0.01)
        for step in 1...8 {
            _ = vpRt.keyDown(KeyEvent(key: .pageDown), at: Double(step) * 0.1)
            _ = vpRt.frame(at: Double(step) * 0.1)
        }
        #expect(vpRt.element(byKey: "field") == nil, "field's row scrolled out of the window")
        #expect(vpRt.focusedKey == "field")
        if let r40Y = vpRt.element(byKey: "r40")?.rect[1] {
            #expect(abs(r40Y - (40.0 * 40.0 - 8.0 * 180.0)) < 1.0)
        } else {
            Issue.record("expected r40 mounted after paging focused virtual list")
        }
        #expect(vpRt.element(byKey: "o0")?.rect[1] == 0)

        // 3. Copied image & files round-trip via RichClipboardPayload and HTML/text paste routing.
        var rgba = Data()
        for i in 0..<12 {
            rgba.append(UInt8(i * 20))
            rgba.append(0)
            rgba.append(UInt8(255 - i * 20))
            rgba.append(255)
        }
        let img = try #require(ClipboardImage.fromRGBA(width: 4, height: 3, rgba: rgba))
        let files = [URL(fileURLWithPath: "/fixtures/a.txt"), URL(fileURLWithPath: "/fixtures/b.png")]
        let memBoard = Clipboard(kind: .memory)
        let payload = RichClipboardPayload(text: "", html: "<b>cap</b>", image: img, files: files)
        memBoard.writeRich(payload)
        let readBack = memBoard.readRich(sanitizeUntrustedHTML: true)
        #expect(readBack.image == img)
        #expect(readBack.files == files)

        struct ImgPaste {
            var plain = TextEdit("")
            var hooked = TextEdit("").rich()
            var rootReceived: [String] = []
            var hookCount = 0
        }
        let imgRt = Runtime(state: ImgPaste(), viewport: Vec2(200, 120), pixelScale: 1.0) { _, _ in
            col().size(200, 120)
                .onPasteContent { st, content, _ in
                    if let h = content.html { st.rootReceived.append(h) }
                }
                .child(textInput(key: "plain", \ImgPaste.plain).font(TextStyle(size: 16)).size(200, 40))
                .child(
                    textInput(key: "hooked", \ImgPaste.hooked).font(TextStyle(size: 16)).size(200, 40)
                        .onInputPaste { st, content, _ in
                            st.hookCount += 1
                            guard content.html != nil else { return false }
                            st.hooked.insertPill(id: "img:\(img.pngData.count)", label: "\(img.width)x\(img.height)")
                            return true
                        }
                )
        }
        imgRt.useClipboard(memBoard)
        _ = imgRt.frame(at: 0.0)
        imgRt.update(at: 0.01) { _, tx in
            tx.copyRich(payload)
            tx.requestPaste()
        }
        _ = imgRt.frame(at: 0.01)
        #expect(imgRt.state.rootReceived == ["<b>cap</b>"])
        imgRt.update(at: 0.02) { _, tx in tx.focus("plain"); tx.requestPaste() }
        _ = imgRt.frame(at: 0.02)
        #expect(imgRt.state.plain.text.isEmpty)
        imgRt.update(at: 0.03) { _, tx in tx.focus("hooked"); tx.requestPaste() }
        _ = imgRt.frame(at: 0.03)
        #expect(imgRt.state.hooked.text == "4x3" && imgRt.state.hookCount == 1)
    }

    @Test("caret.rs:212-354: virtual growth stack scrollIntoView, scrolling away & back, and arrow follow-caret")
    func virtualGrowthStackCaretAlignmentParity() {
        struct Blocks {
            var list: [TextEdit] = (0..<120).map { TextEdit("row \($0)\nsecond line \($0)", multiline: true) }
        }
        let rt = Runtime(state: Blocks(), viewport: Vec2(320, 200), pixelScale: 1.0) { s, _ in
            col().key("vp").size(320, 200).scroll(ScrollSpec(stickBottom: false)).child(
                col().key("rows").wFull().growth(GrowthSpec()).virtualRows(
                    count: s.list.count,
                    estimatedRowHeight: 40,
                    key: { _, i in "b\(i)" },
                    build: { _, i in
                        textInput(key: "b\(i)", \Blocks.list[i])
                            .font(TextStyle(size: 14))
                            .size(300, 40)
                    }
                )
            )
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.01) { _, tx in
            tx.scrollIntoView("b90")
            tx.focus("b90")
        }
        for step in 1...60 {
            _ = rt.frame(at: 0.01 + Double(step) * (1.0 / 60.0))
        }
        #expect(rt.focusedKey == "b90")
        if let el90 = rt.element(byKey: "b90"), let caret = el90.caret {
            #expect(caret[1] >= el90.rect[1] - 1 && caret[1] + caret[3] <= el90.rect[1] + el90.rect[3] + 1)
        } else {
            Issue.record("expected mounted b90 with caret after scrollIntoView")
        }

        // Scroll far up so b90 unmounts, verify focus persists; then scroll back down and verify caret rect alignment.
        for s in 1...12 {
            let t = 1.1 + Double(s) * 0.02
            rt.wheel(WheelEvent(dy: 400), at: Vec2(100, 100), now: t)
            _ = rt.frame(at: t)
        }
        #expect(rt.focusedKey == "b90")
        for s in 1...15 {
            let t = 1.6 + Double(s) * 0.02
            rt.wheel(WheelEvent(dy: -400), at: Vec2(100, 100), now: t)
            _ = rt.frame(at: t)
            if let el = rt.element(byKey: "b90"), el.caret != nil, el.rect[1] < 195 { break }
        }
        if let back90 = rt.element(byKey: "b90"), let caret = back90.caret {
            #expect(caret[1] >= back90.rect[1] - 1 && caret[1] + caret[3] <= back90.rect[1] + back90.rect[3] + 1)
        } else {
            Issue.record("expected b90 remounted after scrolling back down")
        }

        // Arrow key inside focused multiline row updates drawn caret position cleanly (`row 90` <-> `second line 90`).
        _ = rt.keyDown(KeyEvent(key: .arrowUp), at: 2.1); _ = rt.frame(at: 2.1)
        let yBefore = rt.element(byKey: "b90")?.caret?[1] ?? 0
        _ = rt.keyDown(KeyEvent(key: .arrowDown), at: 2.15); _ = rt.frame(at: 2.15)
        let yAfter = rt.element(byKey: "b90")?.caret?[1] ?? 0
        #expect(yAfter > yBefore)
    }

    @Test("selection_api.rs:300-392: virtual select in one handler, non-looping onSelectionChange widen, keyed survival")
    func selectionApiVirtualAndSurvivalParity() {
        // 1. scrollIntoView + selectText in one update selects an initially culled virtual row.
        let vRt = Runtime(state: 0, viewport: Vec2(300, 80), pixelScale: 1.0) { _, _ in
            col().w(300).h(80).scroll(ScrollSpec(stickBottom: false)).child(
                col().key("list").wFull().virtualRows(count: 100, estimatedRowHeight: 24, key: { _, i in "r\(i)" }) { _, i in
                    row().key("r\(i)").wFull().h(24).child(
                        text("row \(i) content").key("t\(i)").font(TextStyle(size: 14, lineHeight: 20)).wFull().selectable(true)
                    )
                }
            )
        }
        _ = vRt.frame(at: 0.0)
        #expect(vRt.element(byKey: "t80") == nil)
        vRt.update(at: 0.01) { _, tx in
            tx.scrollIntoView("r80")
            tx.selectText("t80", range: 0..<6)
        }
        for step in 1...60 {
            _ = vRt.frame(at: 0.01 + Double(step) * (1.0 / 60.0))
        }
        #expect(vRt.selectedText() == "row 80")

        // 2. Widening via tx.selectAllText inside onSelectionChange does not re-trigger an infinite loop.
        struct LoopS { var calls: [String?] = [] }
        let lRt = Runtime(state: LoopS(), viewport: Vec2(300, 100), pixelScale: 1.0) { _, _ in
            col().key("doc").w(300).selectionGroup(true)
                .onSelectionChange { s, ch, tx in
                    s.calls.append(ch.selection?.text)
                    tx.selectAllText("doc")
                }
                .child(text("hello world").key("a").font(TextStyle(size: 14, lineHeight: 20)).wFull().selectable(true))
        }
        _ = lRt.frame(at: 0.0)
        lRt.update(at: 0.01) { _, tx in tx.selectText("a", range: 0..<5) }
        for f in 1...4 {
            _ = lRt.frame(at: 0.01 + Double(f) * 0.016)
        }
        #expect(lRt.state.calls == ["hello", "hello world"])
        #expect(lRt.selectedText() == "hello world")

        // 3. Keyed selection survives unkeyed ancestor sibling index shift without spurious cleared/started events.
        struct ShiftS {
            var banner = false
            var heard: [String?] = []
        }
        let sRt = Runtime(state: ShiftS(), viewport: Vec2(300, 120), pixelScale: 1.0) { s, _ in
            var c: El<ShiftS> = col().w(300).gap(8)
            if s.banner {
                c = c.child(row().wFull().child(text("banner").font(TextStyle(size: 14))))
            }
            return c.child(
                col().wFull().selectionGroup(true)
                    .onSelectionChange { st, ch, _ in st.heard.append(ch.selection?.text) }
                    .child(text("alpha beta").key("msg").font(TextStyle(size: 14, lineHeight: 20)).wFull().selectable(true))
            )
        }
        _ = sRt.frame(at: 0.0)
        sRt.update(at: 0.01) { _, tx in tx.selectText("msg", range: 0..<5) }
        _ = sRt.frame(at: 0.02)
        sRt.state.heard.removeAll()
        sRt.update(at: 0.03) { s, _ in s.banner = true }
        _ = sRt.frame(at: 0.04)
        _ = sRt.frame(at: 0.05)
        #expect(sRt.selectedText() == "alpha")
        #expect(sRt.state.heard.isEmpty)
    }

    @Test("pose_hit.rs:48 & layout_hover.rs:94 & selection_edge_walk.rs: rotation step moving, sliding hover, virtual edge walk")
    func rotationMovingSlidingHoverAndEdgeWalkParity() {
        // 1. Rotation-only step reports moving == true mid-spring until settled.
        let rotRt = Runtime(state: false, viewport: Vec2(200, 200), pixelScale: 1.0) { on, _ in
            col().wFull().hFull().itemsStart().p(50).child(
                el().key("a").size(100, 40).bg(Color.white).animate(MotionTokens.DEFAULT).rotate(on ? 1.0 : 0.0)
            )
        }
        _ = rotRt.frame(at: 0.0)
        #expect(rotRt.element(byKey: "a")?.moving == false)
        rotRt.update(at: 0.01) { on, _ in on = true }
        _ = rotRt.frame(at: 0.02)
        #expect(rotRt.element(byKey: "a")?.moving == true)
        for i in 2...120 {
            _ = rotRt.frame(at: Double(i) * (1.0 / 60.0))
        }
        #expect(rotRt.element(byKey: "a")?.moving == false)

        // 2. Rows sliding under a still pointer (with and without GrowthSpec) never flash hover on passing rows.
        for useGrowth in [false, true] {
            struct Slide {
                var open = false
                var enters: [Int] = []
                var changes: [(Int, Bool)] = []
                var withinChanges: [(Int, Bool)] = []
            }
            let sRt = Runtime(state: Slide(), viewport: Vec2(200, 400), pixelScale: 1.0) { s, _ in
                var list: El<Slide> = col().key("rows").wFull()
                if useGrowth { list = list.growth(GrowthSpec()) }
                for k in 0..<12 {
                    var r: El<Slide> = row().key("r\(k)").wFull().h(k == 0 && s.open ? 220 : 20)
                        .hoverGroup().hover(Color.white)
                        .onHover { st, inside, _ in
                            st.changes.append((k, inside))
                            if inside { st.enters.append(k) }
                        }
                        .onHoverChange { st, inside, _ in
                            st.withinChanges.append((k, inside))
                        }
                    if !useGrowth {
                        r = r.animate(MotionTokens.SETTLE).animateLayout()
                    }
                    list = list.child(r)
                }
                return col().size(200, 400).child(list)
            }
            _ = sRt.frame(at: 0.0)
            sRt.pointerMove(to: Vec2(100, 110), at: 1.0 / 120.0)
            _ = sRt.frame(at: 2.0 / 120.0)
            #expect(sRt.state.enters == [5])
            sRt.update(at: 3.0 / 120.0) { st, _ in st.open = true }
            for step in 4...180 {
                _ = sRt.frame(at: Double(step) * (1.0 / 120.0))
            }
            #expect(sRt.state.enters == [5, 0])
            #expect(sRt.state.changes.map { $0.0 } == [5, 5, 0])
            #expect(sRt.state.changes.map { $0.1 } == [true, false, true])
            #expect(sRt.state.withinChanges.map { $0.0 } == [5, 5, 0])
            #expect(sRt.state.withinChanges.map { $0.1 } == [true, false, true])
        }

        // 3. Virtual edge walk: drag below edge extends monotonically; Escape cancels drag keeping selection.
        let edgeRt = Runtime(state: 0, viewport: Vec2(200, 120), pixelScale: 1.0) { _, _ in
            col().w(200).h(120).scroll(ScrollSpec(stickBottom: false)).child(
                col().key("list").wFull().selectionGroup(true).virtualRows(count: 40, estimatedRowHeight: 40, key: { _, i in "r\(i)" }) { _, i in
                    text(String(format: "row %02d", i))
                        .key("r\(i)")
                        .font(TextStyle(size: 14, lineHeight: 20))
                        .wFull()
                        .h(40)
                        .selectable(true)
                }
            )
        }
        _ = edgeRt.frame(at: 0.0)
        edgeRt.pointerDown(at: Vec2(1, 10), at: 0.01)
        _ = edgeRt.frame(at: 0.02)
        edgeRt.pointerMove(to: Vec2(50, 125), at: 0.03)
        for step in 1...4 {
            _ = edgeRt.frame(at: 0.03 + Double(step) * (1.0 / 60.0))
        }
        let extended = edgeRt.selectedText() ?? ""
        #expect(extended.contains("row 00") && extended.count > 6)
        _ = edgeRt.keyDown(KeyEvent(key: .escape), at: 0.2)
        _ = edgeRt.frame(at: 0.2)
        #expect(edgeRt.selectedText() == extended)
    }

    @Test("selection_group:338, pointer_hit:382, pointer_drag:241-329, pose_hit:148,223,268, caret:184")
    @MainActor
    func remainingWave3BEdgeParityChecks() {
        // 1. Elided text (.ellipsis().selectable()) selects through ellipsis and copies whole text (`selection_group.rs:338`).
        let elidedRt = Runtime(state: 0, viewport: Vec2(240, 80), pixelScale: 1.0) { _, _ in
            col().p(10).w(240).h(80).selectionGroup(true).child(
                text("superlong hidden trailing suffix")
                    .key("elided")
                    .font(TextStyle(size: 14, lineHeight: 20))
                    .w(80)
                    .h(20)
                    .ellipsis()
                    .selectable(true)
            )
        }
        _ = elidedRt.frame(at: 0.0)
        elidedRt.pointerDown(at: Vec2(12, 20), at: 0.01)
        elidedRt.pointerMove(to: Vec2(95, 20), at: 0.02)
        elidedRt.pointerUp(at: Vec2(95, 20), at: 0.03)
        _ = elidedRt.frame(at: 0.04)
        #expect(elidedRt.selectedText() == "superlong hidden trailing suffix")

        // 2. Hover spans descendants and holds true through child press (`pointer_hit.rs:382`).
        struct HoverHoldState {
            var hoveredHistory: [Bool] = []
            var pressed = 0
        }
        let hoverRt = Runtime(state: HoverHoldState(), viewport: Vec2(200, 120), pixelScale: 1.0) { _, _ in
            col().key("card").w(120).h(80)
                .onHover { st, h, _ in st.hoveredHistory.append(h) }
                .child(el().key("btn").w(80).h(40).onClick { st in st.pressed += 1 })
        }
        _ = hoverRt.frame(at: 0.0)
        hoverRt.pointerMove(to: Vec2(40, 20), at: 0.01)
        _ = hoverRt.frame(at: 0.02)
        #expect(hoverRt.state.hoveredHistory == [true])
        hoverRt.pointerDown(at: Vec2(40, 20), at: 0.03)
        _ = hoverRt.frame(at: 0.04)
        hoverRt.pointerUp(at: Vec2(40, 20), at: 0.05)
        _ = hoverRt.frame(at: 0.06)
        #expect(hoverRt.state.pressed == 1)
        #expect(hoverRt.state.hoveredHistory == [true])

        // 3. Nil-offer dragOut tracks hover leave (`pointer_drag.rs:241`), start+end ordering (`296`), untaken FIFO (`329`) & cancelled press (`319`).
        struct DragOrderState {
            var hover = false
            var events: [String] = []
            var offer: Bool = false
        }
        let dragRt = Runtime(state: DragOrderState(), viewport: Vec2(240, 140), pixelScale: 1.0) { s, _ in
            let item1: El<DragOrderState> = el().key("d1").w(100).h(40)
                .onHover { st, h, _ in st.hover = h }
                .dragOut { st in st.offer ? DragItem().text("one") : nil }
                .onDragStart { st, _ in st.events.append("start1") }
                .onDragOutEnd { st, o, _ in st.events.append("end1:\(o)") }
            let item2: El<DragOrderState> = el().key("d2").w(100).h(40)
                .dragOut { _ in DragItem().text("two") }
                .onDragStart { st, _ in st.events.append("start2") }
                .onDragOutEnd { st, o, _ in st.events.append("end2:\(o)") }
            return col().children([item1, item2])
        }
        _ = dragRt.frame(at: 0.0)
        dragRt.pointerMove(to: Vec2(20, 20), at: 0.01)
        dragRt.pointerDown(at: Vec2(20, 20), at: 0.02)
        #expect(dragRt.state.hover == true)
        dragRt.pointerMove(to: Vec2(160, 20), at: 0.03)
        _ = dragRt.frame(at: 0.04)
        #expect(dragRt.state.hover == false)
        dragRt.pointerUp(at: Vec2(160, 20), at: 0.05)

        dragRt.state.offer = true
        dragRt.pointerMove(to: Vec2(20, 20), at: 0.10)
        dragRt.pointerDown(at: Vec2(20, 20), at: 0.11)
        dragRt.pointerMove(to: Vec2(60, 20), at: 0.12)
        dragRt.pointerMove(to: Vec2(20, 60), at: 0.13)
        dragRt.pointerDown(at: Vec2(20, 60), at: 0.14)
        dragRt.pointerMove(to: Vec2(60, 60), at: 0.15)
        _ = dragRt.frame(at: 0.16)
        _ = dragRt.frame(at: 0.165)
        #expect(dragRt.state.events == ["start1", "start2", "end1:cancelled", "end2:cancelled"])

        // 4. Turned parent clips child in layer coordinates & Pick().transparent skips exiting opacity-0 (`pose_hit.rs:148,223,268`).
        let poseRt = Runtime(state: true, viewport: Vec2(240, 240), pixelScale: 1.0) { showExiting, _ in
            col().w(240).h(240)
                .child(
                    el().key("turnedClip").w(60).h(60).clip().rotate(.pi / 4)
                        .child(el().key("child").w(100).h(60).scale(1.0).offset(0, 0))
                )
                .children(showExiting ? [el().key("vanishing").w(40).h(40).opacity(0).transition(.opacity)] : [])
        }
        _ = poseRt.frame(at: 0.0)
        if let clipCenter = poseRt.find("turnedClip") {
            #expect(poseRt.elementAt(clipCenter.x, clipCenter.y)?.key == "child")
            #expect(poseRt.elementAt(clipCenter.x + 55, clipCenter.y + 55)?.key != "child")
        } else {
            Issue.record("expected turnedClip")
        }
        #expect(poseRt.elementAtWith(10, 70, pick: Pick().transparent(true))?.key == "vanishing")
        poseRt.update(at: 0.02) { s, _ in s = false }
        _ = poseRt.frame(at: 0.04)
        #expect(poseRt.elementAtWith(10, 70, pick: Pick().transparent(true))?.key != "vanishing")

        // 5. Growth gap expands layout extent for subsequent rows (`caret.rs:184`).
        var latestScrollMaxY: Float = 0
        let gapRt = Runtime(state: false, viewport: Vec2(200, 100), pixelScale: 1.0) { grow, cx in
            latestScrollMaxY = cx.scrollMax(of: "sc").y
            return col().key("sc").w(200).h(100).scrollY().child(
                col().growth(GrowthSpec()).gap(10)
                    .child(el().key("r1").w(200).h(grow ? 90 : 30).streaming())
                    .child(el().key("r2").w(200).h(40).arrivesWhole())
            )
        }
        _ = gapRt.frame(at: 0.0)
        let beforeMax = latestScrollMaxY
        gapRt.update(at: 0.02) { s, _ in s = true }
        for step in 1...120 {
            _ = gapRt.frame(at: 0.02 + Double(step) * (1.0 / 60.0))
        }
        gapRt.invalidate(at: 2.5)
        _ = gapRt.frame(at: 2.5)
        #expect(latestScrollMaxY > beforeMax)
        let r2Y = gapRt.element(byKey: "r2")?.rect[1] ?? 0
        #expect(r2Y >= 99.0)
    }
}
