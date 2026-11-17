import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite("El & Runtime Increment 5A Unblockers Tests")
struct ElInc5AUnblockersTests {

    // MARK: - 1. @kitw #387: A11y Roles, Modal/Hidden Omission, Snapshot, JSON & Actions

    @Test("a11y: toolbar, splitter, status, list, menuItemCheckbox roles & mappers")
    func a11yRolesMappersAndSnapshot() {
        #if os(macOS)
        #expect(AppKitAccessibilityMapper.nsRole(for: .toolbar).rawValue == "AXToolbar")
        #expect(AppKitAccessibilityMapper.nsRole(for: .splitter).rawValue == "AXSplitter")
        #expect(AppKitAccessibilityMapper.nsRole(for: .status).rawValue == "AXGroup")
        #expect(AppKitAccessibilityMapper.nsRole(for: .list).rawValue == "AXList")
        #expect(AppKitAccessibilityMapper.nsRole(for: .menuItemCheckbox).rawValue == "AXMenuItem")
        #endif

        #if canImport(UIKit)
        #expect(UIKitAccessibilityMapper.traits(for: .toolbar) == [.none])
        #expect(UIKitAccessibilityMapper.traits(for: .splitter) == [.adjustable])
        #expect(UIKitAccessibilityMapper.traits(for: .status) == [.staticText, .updatesFrequently])
        #expect(UIKitAccessibilityMapper.traits(for: .list) == [.none])
        #expect(UIKitAccessibilityMapper.traits(for: .menuItemCheckbox) == [.button])
        #endif

        struct S {
            var modalOpen = false
            var clicks = 0
            var stepValue = 0
            var pw = TextEdit("secret123")
        }

        let rt = Runtime<S>(state: S()) { s, _ in
            var children: [El<S>] = [
                text("Hidden").key("hidden").a11yHidden(),
                row().role(.toolbar).key("tb").child(
                    row().child(text("Tap")).role(.button).focusable(true).key("bgBtn").onClick { st, _ in st.clicks += 1 }
                ),
                textInput(key: "pwInput", \S.pw).secure(true),
                el().key("div").role(.splitter),
                row().key("stat").role(.status).child(text("Ready")),
                col().key("lst").role(.list).child(text("Row")),
                row().key("mic").role(.menuItemCheckbox).checked(true).child(text("Check")),
                el().key("stepper").w(40).h(24).onStep { st, d, _ in st.stepValue += d }
            ]
            if s.modalOpen {
                children.append(
                    col().key("dlg").modal().child(
                        row().child(text("Confirm")).role(.button).focusable(true).key("modalBtn").onClick { st, _ in st.clicks += 10 }
                    )
                )
            }
            return col().children(children)
        }
        _ = rt.frame(at: 0)

        let snap = rt.accessibilitySnapshot()
        let json = rt.accessibilityJSON(pretty: true)
        #expect(!json.contains("\"hidden\""))
        #expect(json.contains("\"toolbar\""))
        #expect(json.contains("\"splitter\""))
        #expect(json.contains("\"status\""))
        #expect(json.contains("\"list\""))
        #expect(json.contains("\"menu-item-check-box\""))
        #expect(!json.contains("secret123"))
        #if canImport(UIKit)
        #expect(UIKitAccessibilityMapper.traits(for: .toolbar) == [])
        #expect(UIKitAccessibilityMapper.traits(for: .list) == [])
        #expect(UIKitAccessibilityMapper.traits(for: .textInput) == [])
        #expect(UIKitAccessibilityMapper.traits(for: .splitter) == .adjustable)
        #expect(UIKitAccessibilityMapper.traits(for: .slider) == .adjustable)
        #expect(UIKitAccessibilityMapper.traits(for: .status) == [.staticText, .updatesFrequently])
        #expect(UIKitAccessibilityMapper.traits(for: .progress) == [.staticText, .updatesFrequently])
        #endif

        func findNode(_ n: AccessibilityNode, id: String) -> AccessibilityNode? {
            if n.id == id { return n }
            for c in n.children {
                if let m = findNode(c, id: id) { return m }
            }
            return nil
        }

        let pw = findNode(snap, id: "pwInput")
        #expect(pw?.isSecure == true)
        #expect(pw?.value == nil)

        #expect(rt.accessibilityAction("bgBtn", .press, at: 0.1))
        #expect(rt.state.clicks == 1)
        #expect(rt.accessibilityAction("stepper", .increment, at: 0.2))
        #expect(rt.state.stepValue == 1)

        // With modal open, inert background nodes are omitted from accessibilitySnapshot().
        rt.update(at: 0.25) { s, _ in s.modalOpen = true }
        _ = rt.frame(at: 0.3)
        let modalSnap = rt.accessibilitySnapshot()
        #expect(findNode(modalSnap, id: "bgBtn") == nil)
        #expect(findNode(modalSnap, id: "modalBtn") != nil)
        #expect(rt.accessibilityAction("bgBtn", .press, at: 0.4) == false)
        #expect(rt.accessibilityAction("modalBtn", .press, at: 0.4))
        #expect(rt.state.clicks == 11)
    }

    // MARK: - 2. @kitc #403: hoverMotionWithin inheritance & hoverMotion override

    @Test("hover: hoverMotionWithin end-to-end curves, override, anchored inheritance & groupOpacity")
    func hoverMotionWithinInheritance() {
        let enterCurve = Anim<Float>(curve: .tween(duration: 0.2, easing: .linear))
        let exitCurve = Anim<Float>(curve: .tween(duration: 0.4, easing: .linear))
        let instantCurve = Anim<Float>.instant

        let rt = Runtime<Int>(state: 0, viewport: Vec2(400, 300)) { _, _ in
            col().w(400).h(300).children([
                col().key("scope").w(240).h(120).hoverMotionWithin(enterCurve, exitCurve).children([
                    row().key("child").role(.button).w(200).h(30)
                        .bg(Color(r: 0, g: 0, b: 0, a: 1))
                        .hover(Color(r: 1, g: 0, b: 0, a: 1)),
                    row().key("override").role(.button).w(200).h(30)
                        .bg(Color(r: 0, g: 0, b: 0, a: 1))
                        .hover(Color(r: 0, g: 1, b: 0, a: 1))
                        .hoverMotion(instantCurve, exitCurve),
                    col().key("group").w(200).h(40).hoverGroup().children([
                        el().key("anchorBtn").w(100).h(20),
                        el().key("groupDot").w(10).h(10).bg(Color.white).groupOpacity(0.0, 1.0)
                    ])
                ]),
                el().key("overlay").anchored("anchorBtn", side: .bottom).w(80).h(24)
                    .bg(Color(r: 0, g: 0, b: 0, a: 1))
                    .hover(Color(r: 0, g: 0, b: 1, a: 1))
            ])
        }
        _ = rt.frame(at: 0)

        // Inherited linear enter curve on child (0.2s -> ~0.5 at 0.1s)
        rt.pointerMove(to: Vec2(20, 15), at: 0.1)
        _ = rt.frame(at: 0.1)
        #expect((rt.element(byKey: "child")?.hover ?? 0) < 0.1)
        _ = rt.frame(at: 0.2)
        let midEnter = rt.element(byKey: "child")?.hover ?? 0
        #expect(midEnter > 0.35 && midEnter < 0.65)
        let midFill = rt.element(byKey: "child")?.fill ?? .black
        let expectedRed = rt.srgbBlend ? RefShader.srgbToLinear(midEnter) : midEnter
        #expect(abs(midFill.r - expectedRed) < 0.05)

        _ = rt.frame(at: 0.35)
        #expect((rt.element(byKey: "child")?.hover ?? 0) > 0.99)

        // Inherited linear exit curve (0.4s -> ~0.5 after 0.2s leave)
        rt.pointerMove(to: Vec2(-50, -50), at: 0.4)
        _ = rt.frame(at: 0.4)
        _ = rt.frame(at: 0.6)
        let midExit = rt.element(byKey: "child")?.hover ?? 0
        #expect(midExit > 0.35 && midExit < 0.65)

        // Instant hoverMotion override snaps immediately on enter
        rt.pointerMove(to: Vec2(20, 45), at: 1.0)
        _ = rt.frame(at: 1.0)
        #expect(abs((rt.element(byKey: "override")?.hover ?? 0) - 1.0) < 0.01)

        // hoverGroup drives child groupOpacity along inherited enterCurve
        rt.pointerMove(to: Vec2(20, 70), at: 1.5)
        _ = rt.frame(at: 1.5)
        _ = rt.frame(at: 1.6)
        let midGroupOp = rt.element(byKey: "groupDot")?.opacity ?? 0
        #expect(midGroupOp > 0.35 && midGroupOp < 0.65)

        // Anchored overlay inherits anchorBtn's ancestor hoverMotionWithin curve
        let ovRect = rt.element(byKey: "overlay")?.rect ?? []
        #expect(ovRect.count == 4)
        rt.pointerMove(to: Vec2(ovRect[0] + 10, ovRect[1] + 10), at: 2.0)
        _ = rt.frame(at: 2.0)
        _ = rt.frame(at: 2.1)
        let ovMid = rt.element(byKey: "overlay")?.hover ?? 0
        #expect(ovMid > 0.35 && ovMid < 0.65)
    }

    // MARK: - 3. @content #439: dissolve, pixels / pixelsFit, onVisible, onStep / onStepLimit

    @Test("dissolve: intermediate child opacity activates .plusLighter layer blend")
    func dissolveEmitsPlusLighterLayer() {
        struct S { var op: Float = 0.5 }
        let rt = Runtime<S>(state: S()) { s, _ in
            el().key("host").w(100).h(100).dissolve().child(
                el().key("fadeChild").w(80).h(80).bg(Color(r: 1, g: 0, b: 0, a: 1)).opacity(s.op)
            )
        }
        let rf = rt.renderFrame(at: 0)
        let plusLighterLayers = rf.instances.filter { $0.params.y == KIND_LAYER && $0.params.x == 1.0 }
        #expect(plusLighterLayers.count == 1)

        rt.update(at: 0.05) { s, tx in
            s.op = 1.0
            tx.instant()
        }
        let rfOpaque = rt.renderFrame(at: 0.1)
        let plusAfterOpaque = rfOpaque.instances.filter { $0.params.y == KIND_LAYER && $0.params.x == 1.0 }
        #expect(plusAfterOpaque.isEmpty)
    }

    @Test("pixels: El.pixels and pixelsFit emit fitted/cropped image geometry")
    func pixelsAndPixelsFitGeometry() {
        let pix = Pixels()
        pix.set(width: 4, height: 2, rgba: [UInt8](repeating: 255, count: 4 * 2 * 4))

        let rtFit = Runtime<Int>(state: 0) { _, _ in
            pixels(pix, fit: .fit).w(100).h(100)
        }
        let rfFit = rtFit.renderFrame(at: 0)
        let imgFit = rfFit.instances.first { $0.params.y == KIND_IMAGE }
        #expect(imgFit != nil)
        // 4x2 inside 100x100 @ pixelScale=2 -> 200x100 centered vertically (y=50, h=100)
        #expect(abs((imgFit?.rect.z ?? 0) - 200) < 1.0)
        #expect(abs((imgFit?.rect.w ?? 0) - 100) < 1.0)
        #expect(abs((imgFit?.rect.y ?? 0) - 50) < 1.0)

        let rtFill = Runtime<Int>(state: 0) { _, _ in
            el().w(100).h(100).pixelsFit(pix, .fill)
        }
        let rfFill = rtFill.renderFrame(at: 0)
        let imgFill = rfFill.instances.first { $0.params.y == KIND_IMAGE }
        #expect(imgFill != nil)
        #expect(abs((imgFill?.rect.z ?? 0) - 200) < 1.0)
        #expect(abs((imgFill?.rect.w ?? 0) - 200) < 1.0)
        #expect((imgFill?.uv.z ?? 0) > 0 && (imgFill?.uv.z ?? 0) < (imgFit?.uv.z ?? 0))

        let crop = Runtime<Int>.fittedPixelsGeometry(
            box: SIMD4<Float>(0, 0, 100, 100),
            uv: SIMD4<Float>(0, 0, 1, 1),
            imageWidth: 4,
            imageHeight: 2,
            fit: .fill
        )
        #expect(abs(crop.uv.x - 0.25) < 1e-4)
        #expect(abs(crop.uv.z - 0.75) < 1e-4)
    }

    @Test("onVisible: tracks viewport entry and exit")
    func onVisibleTracksVisibility() {
        struct S {
            var y: Float = 0
            var log: [Bool] = []
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(400, 300)) { s, _ in
            col().w(400).h(300).child(
                el().key("card").w(100).h(100).mt(s.y).onVisible { st, vis, _ in
                    st.log.append(vis)
                }
            )
        }
        _ = rt.frame(at: 0)
        #expect(rt.state.log == [true])

        rt.update(at: 0.05) { s, tx in
            tx.instant()
            s.y = 400
        }
        _ = rt.frame(at: 0.1)
        #expect(rt.state.log == [true, false])
    }

    @Test("onStep & onStepLimit: step keys and focusGroup preemption")
    func onStepAndLimitPreemptFocusGroup() {
        struct S {
            var value = 10
            var lastLimit: Bool? = nil
        }
        let rt = Runtime<S>(state: S()) { _, _ in
            row().focusGroup().children([
                el().key("slider").w(80).h(24)
                    .onStep { st, delta, _ in st.value += delta }
                    .onStepLimit { st, toMax, _ in st.lastLimit = toMax },
                row().child(text("Other")).role(.button).focusable(true).key("other")
            ])
        }
        _ = rt.frame(at: 0)
        rt.update(at: 0.05) { _, tx in tx.focus("slider") }
        _ = rt.frame(at: 0.06)
        #expect(rt.focusedKey == "slider")

        #expect(rt.keyDown(KeyEvent(key: .arrowRight), at: 0.1))
        #expect(rt.state.value == 11)
        #expect(rt.focusedKey == "slider")

        #expect(rt.keyDown(KeyEvent(key: .arrowDown), at: 0.2))
        #expect(rt.state.value == 10)
        #expect(rt.keyDown(KeyEvent(key: .pageUp), at: 0.3))
        #expect(rt.state.value == 20)
        #expect(rt.keyDown(KeyEvent(key: .pageDown), at: 0.4))
        #expect(rt.state.value == 10)

        #expect(rt.keyDown(KeyEvent(key: .home), at: 0.5))
        #expect(rt.state.lastLimit == false)
        #expect(rt.keyDown(KeyEvent(key: .end), at: 0.6))
        #expect(rt.state.lastLimit == true)
    }

    // MARK: - 4. @examples #428 / #459: DrawnLayout, Gestures, PointerButtons, KeyUp & Clipboard Paste

    @Test("layout watches: onDrawnLayout, onDrawnLayoutTx, drawnRectInto")
    func drawnLayoutAndLiveRect() {
        struct S {
            var x: Float = 10
            var reported: [[Float]] = []
            var txReported: [[Float]] = []
        }
        let rectLive = Live(MotionRect.zero)
        let rt = Runtime<S>(state: S()) { s, _ in
            col().children([
                el().key("box").w(40).h(20).ml(s.x)
                    .onDrawnLayout { st, r in st.reported.append(r) }
                    .drawnRectInto(rectLive),
                el().key("txBox").w(30).h(15).ml(s.x)
                    .onDrawnLayoutTx { st, r, tx in
                        st.txReported.append(r)
                        tx.liveOnly()
                    }
            ])
        }
        _ = rt.frame(at: 0)
        #expect(rt.state.reported.count == 1)
        #expect(abs(rt.state.reported[0][0] - 10) < 1e-3)
        #expect(abs(rectLive.get().x - 10) < 1e-3)
        #expect(rt.state.txReported.count == 1)

        // No move -> does not re-fire
        _ = rt.frame(at: 0.1)
        #expect(rt.state.reported.count == 1)

        // Move -> fires again and updates Live<MotionRect>
        rt.update(at: 0.15) { s, tx in
            tx.instant()
            s.x = 55
        }
        _ = rt.frame(at: 0.2)
        #expect(rt.state.reported.count == 2)
        #expect(abs((rt.state.reported.last?[0] ?? 0) - 55) < 1e-3)
        #expect(abs(rectLive.get().x - 55) < 1e-3)
    }

    @Test("gestures: onMagnify, onRotate, onSmartMagnify hit-testing & bubbling")
    func trackpadGesturesHitTestAndBubble() {
        struct S {
            var magLog: [String] = []
            var rotLog: [String] = []
            var smartLog: [String] = []
        }
        let rt = Runtime<S>(state: S()) { _, _ in
            col().key("outer").w(200).h(200)
                .onMagnify { st, _, _ in st.magLog.append("outer"); return true }
                .onRotate { st, ev, _ in st.rotLog.append("outer:\(Int(ev.degrees))"); return true }
                .child(
                    el().key("inner").w(100).h(100)
                        .onMagnify { st, ev, _ in
                            st.magLog.append("inner:\(Int(ev.delta * 100))@\(Int(ev.x))")
                            return true
                        }
                        .onRotate { st, ev, _ in
                            st.rotLog.append("inner:\(Int(ev.degrees))")
                            return false
                        }
                        .onSmartMagnify { st, lx, ly, _ in
                            st.smartLog.append("\(Int(lx)),\(Int(ly))")
                            return true
                        }
                )
        }
        _ = rt.frame(at: 0)

        #expect(rt.magnify(MagnifyEvent(delta: 0.25), at: Vec2(40, 50), now: 0.1))
        #expect(rt.state.magLog == ["inner:25@40"])

        #expect(rt.rotate(RotateEvent(degrees: 45), at: Vec2(40, 50), now: 0.2))
        #expect(rt.state.rotLog == ["inner:45", "outer:45"])

        #expect(rt.smartMagnify(at: Vec2(33, 44), now: 0.3))
        #expect(rt.state.smartLog == ["33,44"])
    }

    @Test("pointerButtons & tx.button: middle-click press, click & drag")
    func pointerButtonsMiddleClickAndDrag() {
        struct S {
            var downBtns: [PointerButton] = []
            var clickBtns: [PointerButton] = []
            var dragBtns: [PointerButton] = []
            var ignoredClicks = 0
        }
        let rt = Runtime<S>(state: S()) { _, _ in
            row().children([
                el().key("pan").w(100).h(100)
                    .pointerButtons([PointerButton.middle, .primary])
                    .onPointerDown { st, _, tx in st.downBtns.append(tx.button) }
                    .onDrag { st, _, tx in st.dragBtns.append(tx.button) }
                    .onClick { st, tx in st.clickBtns.append(tx.button) },
                el().key("primaryOnly").w(100).h(100)
                    .onClick { st, _ in st.ignoredClicks += 1 }
            ])
        }
        _ = rt.frame(at: 0)

        // Middle click on primaryOnly is ignored
        rt.pointerDown(at: Vec2(150, 50), button: PointerButton.middle, mods: .none, at: 0.1)
        rt.pointerUp(at: Vec2(150, 50), button: PointerButton.middle, mods: .none, at: 0.12)
        #expect(rt.state.ignoredClicks == 0)

        // Middle click + small drag on pan delivers tx.button == .middle
        rt.pointerDown(at: Vec2(40, 50), button: PointerButton.middle, mods: .none, at: 0.2)
        rt.pointerMove(to: Vec2(41, 50), at: 0.21)
        rt.pointerUp(at: Vec2(41, 50), button: PointerButton.middle, mods: .none, at: 0.22)
        #expect(rt.state.downBtns == [PointerButton.middle])
        #expect(rt.state.dragBtns == [PointerButton.middle, PointerButton.middle, PointerButton.middle])
        #expect(rt.state.clickBtns == [PointerButton.middle])
    }

    @Test("onKeyUp: dispatches logical key release from focused element outward")
    func onKeyUpDispatchAndBubbling() {
        struct S { var log: [String] = [] }
        let rt = Runtime<S>(state: S()) { _, _ in
            col().key("root").onKeyUp { st, ev, _ in
                st.log.append("root:\(ev.key)")
                return true
            }.child(
                row().child(text("KeyTarget")).role(.button).focusable(true).key("target")
                    .onKeyUp { st, ev, _ in
                        st.log.append("target:\(ev.key)")
                        return ev.key == .space
                    }
            )
        }
        _ = rt.frame(at: 0)
        rt.update(at: 0.05) { _, tx in tx.focus("target") }
        _ = rt.frame(at: 0.06)
        #expect(rt.focusedKey == "target")

        #expect(rt.keyUp(KeyEvent(key: .space), at: 0.1))
        #expect(rt.state.log == ["target:space"])

        #expect(rt.keyUp(KeyEvent(key: .enter), at: 0.2))
        #expect(rt.state.log == ["target:space", "target:enter", "root:enter"])
    }

    @Test("clipboard & paste: useClipboard, requestPaste, onInputPaste, onPasteContent")
    func clipboardRequestPasteAndOnInputPaste() {
        struct S {
            var edit = TextEdit("")
            var interceptedRich = false
            var rootPasted: [String] = []
        }
        let board = Clipboard(kind: .memory)
        let rt = Runtime<S>(state: S()) { _, _ in
            col().onPasteContent { st, content, _ in
                st.rootPasted.append(content.text)
            }.children([
                textInput(key: "editor", \S.edit)
                    .w(120).h(28)
                    .onInputPaste { st, content, _ in
                        if content.html != nil {
                            st.interceptedRich = true
                            return true
                        }
                        return false
                    },
                row().child(text("TriggerPaste")).role(.button).key("btn").w(120).h(28).onClick { _, tx in
                    tx.copyText("copied-text")
                    tx.requestPaste()
                }
            ])
        }
        rt.useClipboard(board)
        _ = rt.frame(at: 0)

        // Copy + requestPaste with unfocused root -> delivers to onPasteContent
        rt.pointerDown(at: Vec2(10, 40), button: .primary, mods: .none, at: 0.1)
        rt.pointerUp(at: Vec2(10, 40), button: .primary, mods: .none, at: 0.12)
        _ = rt.frame(at: 0.15)
        #expect(board.readRich(sanitizeUntrustedHTML: false).content.text == "copied-text")
        #expect(rt.state.rootPasted == ["copied-text"])

        // Focused TextInput with rich HTML paste -> onInputPaste intercepts
        rt.update(at: 0.16) { _, tx in tx.focus("editor") }
        _ = rt.frame(at: 0.17)
        #expect(rt.focusedKey == "editor")
        var rich = ClipboardContent("<b>hello</b>")
        rich.html = "<b>hello</b>"
        rich.text = "hello"
        board.writeRich(RichClipboardPayload(content: rich))
        #expect(rt.keyDown(KeyEvent(key: .text("v"), mods: RuneTestKey.primaryMods()), at: 0.2))
        #expect(rt.state.interceptedRich)
        #expect(rt.state.edit.text.isEmpty)

        // Plain paste falls through onInputPaste and inserts into TextEdit
        board.writeText("plain")
        #expect(rt.keyDown(KeyEvent(key: .text("v"), mods: RuneTestKey.primaryMods()), at: 0.3))
        #expect(rt.state.edit.text == "plain")
    }

    @Test("regression #490: instant scrollTo preserves child clipRect and cut commit preserves unmount transition")
    func regressionsKitw490() {
        let rtScroll = Runtime<Int>(state: 0, viewport: Vec2(200, 200)) { _, _ in
            col().key("outer").scrollY().clip().w(200).h(120).children([
                col().key("row0").w(200).h(40).bg(Color(r: 0, g: 0, b: 1, a: 1)),
                col().key("innerClip").clip().w(180).h(40).child(
                    col().key("child").w(180).h(80).bg(Color(r: 1, g: 0, b: 0, a: 1))
                ),
                col().key("spacer").w(200).h(300)
            ])
        }
        _ = rtScroll.frame(at: 0)
        let beforeClip = rtScroll.flatNodes.first { $0.key == "child" }?.clipRect ?? .zero
        #expect(beforeClip.height == 40)

        rtScroll.update(at: 0.05) { _, tx in
            tx.scrollTo("outer", offset: Vec2(0, 20), animated: false)
        }
        _ = rtScroll.frame(at: 0.06)
        let afterChild = rtScroll.flatNodes.first { $0.key == "child" }
        #expect(afterChild?.clipRect.height == 40)
        #expect(rtScroll.element(byKey: "child")?.visible[3] == 40)
        #expect(rtScroll.element(byKey: "innerClip")?.rect[3] == 40)

        // Unmount transition stays live across cut (frame(at: 0)) / tx.instant()
        let rtExit = Runtime<Bool>(state: true, viewport: Vec2(200, 200)) { open, _ in
            var root: El<Bool> = col().w(200).h(200)
            if open {
                root = root.child(
                    col().key("popup").w(80).h(40).bg(Color(r: 0, g: 0, b: 1, a: 1)).opacity(1)
                        .transition(.opacity)
                )
            }
            return root
        }
        _ = rtExit.frame(at: 0)
        rtExit.update(at: 0.1) { open, _ in open = false }
        let fExit = rtExit.frame(at: 0.15)
        #expect(!fExit.primitives.isEmpty)
    }

    @Test("regression #495: wheel scroll overrides scrollAnchor without resetting to zero")
    func regressionScrollAnchorWheelReset() {
        struct S {
            var count = 5
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 120)) { s, _ in
            col().key("feed").scrollY().scrollAnchor().w(200).h(120).children(
                (0..<s.count).map { i in
                    col().key("msg-\(i)").w(200).h(50)
                }
            )
        }
        _ = rt.frame(at: 0)
        rt.wheel(WheelEvent(dx: 0, dy: -60), at: Vec2(50, 50), now: 0.1)
        _ = rt.frame(at: 0.12)
        let afterWheel = rt.scrollOffset(forKey: "feed").y
        #expect(afterWheel > 0)

        _ = rt.frame(at: 0.14)
        let afterNextFrame = rt.scrollOffset(forKey: "feed").y
        #expect(abs(afterNextFrame - afterWheel) < 0.01)
    }

    @Test("pixels: async Pixels.set updates aspect layout without animation, honors surfaceAnchor/Unscaled & white tint")
    func pixelsAsyncAspectPlacementAndWhiteTint() {
        let pix = Pixels()
        pix.set(width: 20, height: 10, rgba: [UInt8](repeating: 255, count: 20 * 10 * 4))

        let red = Color(r: 1, g: 0, b: 0, a: 1)
        let rt = Runtime<Int>(state: 0, viewport: Vec2(300, 450), pixelScale: 2.0) { _, _ in
            col().w(300).h(450).children([
                el().pixelsFit(pix, .fit).key("autoH").w(100).color(red),
                el().pixelsFit(pix, .fit).key("br").w(100).h(100).surfaceAnchor(.end, .end),
                el().pixelsFit(pix, .fit).key("unscaled").w(100).h(100).surfaceUnscaled()
            ])
        }
        _ = rt.frame(at: 0)
        #expect(abs((rt.element(byKey: "autoH")?.rect[3] ?? 0) - 50) < 0.5)

        // Mutate buffer aspect ratio asynchronously (20x40 -> 1:2) with layout width=100 -> height snaps to 200.
        pix.set(width: 20, height: 40, rgba: [UInt8](repeating: 255, count: 20 * 40 * 4))
        let fAsync = rt.frame(at: 0.05)
        let autoRect = rt.element(byKey: "autoH")?.rect ?? []
        let autoTarget = rt.element(byKey: "autoH")?.target ?? []
        #expect(abs((autoRect[3]) - 200) < 0.5)
        #expect(abs((autoTarget[3]) - 200) < 0.5)

        // Untinted white despite textColor(red) in both buildRefScene & renderFrame
        let imgPrims = fAsync.primitives.filter { $0.params.y == KIND_IMAGE }
        #expect(imgPrims.count == 3)
        #expect(abs(imgPrims[0].fill.x - 1.0) < 0.01)
        #expect(abs(imgPrims[0].fill.y - 1.0) < 0.01)
        #expect(abs(imgPrims[0].fill.z - 1.0) < 0.01)

        // Bottom-right surfaceAnchor inside br (box 100x100 @2x => 200px, fit 20x40 => 100px wide x 200px tall, aligned right -> x = 100px)
        let brPrim = imgPrims[1]
        #expect(abs(brPrim.rect.x - 100) < 1.0)

        // Unscaled draws 1 texel per device pixel (20px x 40px centered inside 100x100 @2x = 200x200px)
        let unscaledPrim = imgPrims[2]
        #expect(abs(unscaledPrim.rect.z - 20) < 1.0)
        #expect(abs(unscaledPrim.rect.w - 40) < 1.0)

        let rf = rt.renderFrame(at: 0.05)
        let rfImgs = rf.instances.filter { $0.params.y == KIND_IMAGE }
        #expect(rfImgs.count == 3)
        #expect(abs(rfImgs[1].rect.x - brPrim.rect.x) < 1.0)
        #expect(abs(rfImgs[2].rect.z - 20) < 1.0)
        #expect(abs(rfImgs[2].rect.w - 40) < 1.0)
    }

    @Test("dissolve: activates .plusLighter for liveOpacity, groupOpacity, and loopOpacity")
    func dissolveLiveGroupLoopOpacity() {
        let red = Color(r: 1, g: 0, b: 0, a: 1)
        let liveOp = Live<Float>(0.5)
        let rtLive = Runtime<Int>(state: 0) { _, _ in
            el().w(100).h(100).dissolve().child(
                el().w(80).h(80).bg(red).liveOpacity(liveOp.smooth(.snappy))
            )
        }
        let rfLive = rtLive.renderFrame(at: 0)
        #expect(rfLive.instances.contains { $0.params.y == KIND_LAYER && $0.params.x == 1.0 })

        let rtGroup = Runtime<Int>(state: 0) { _, _ in
            el().key("grp").w(100).h(100).hoverGroup().dissolve().child(
                el().w(80).h(80).bg(red).groupOpacity(0.4, 1.0)
            )
        }
        let rfGroupRest = rtGroup.renderFrame(at: 0)
        #expect(rfGroupRest.instances.contains { $0.params.y == KIND_LAYER && $0.params.x == 1.0 })

        let rtLoop = Runtime<Int>(state: 0) { _, _ in
            el().w(100).h(100).dissolve().child(
                el().w(80).h(80).bg(red).looping(.opacity(period: 1.0, low: 0.2, high: 0.8))
            )
        }
        let rfLoop = rtLoop.renderFrame(at: 0.25)
        #expect(rfLoop.instances.contains { $0.params.y == KIND_LAYER && $0.params.x == 1.0 })
    }

    @Test("layout & visible watches: waits for layout spring settle, 0.5pt threshold & skips exiting subtrees")
    func layoutAndVisibleWatchesSpringAndExitingGuards() {
        struct S {
            var x: Float = 0
            var mounted = true
            var drawnCount = 0
            var visCount = 0
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 300)) { s, _ in
            var root: El<S> = col().w(300).h(300)
            if s.mounted {
                root = root.child(
                    el().key("card").w(60).h(40).ml(s.x)
                        .animateLayout(Spring(duration: 0.12, bounce: 0))
                        .transition(.opacity)
                        .onDrawnLayout { st, _ in st.drawnCount += 1 }
                        .onVisible { st, _, _ in st.visCount += 1 }
                )
            }
            return root
        }
        _ = rt.frame(at: 0)
        #expect(rt.state.drawnCount == 1)
        #expect(rt.state.visCount == 1)

        // Sub-0.5pt move must not re-fire onDrawnLayout
        rt.update(at: 0.05) { s, tx in tx.instant(); s.x = 0.2 }
        _ = rt.frame(at: 0.06)
        #expect(rt.state.drawnCount == 1)

        // Springing move waits until layout spring settles
        rt.update(at: 0.1) { s, tx in tx.animated(); s.x = 80 }
        _ = rt.frame(at: 0.12)
        #expect(rt.state.drawnCount == 1)
        for step in 1...80 {
            _ = rt.frame(at: 0.12 + Double(step) * 0.016)
        }
        #expect(rt.state.drawnCount == 2)

        // Unmounting during exit transition does not fire onDrawnLayout or onVisible
        rt.update(at: 0.9) { s, tx in tx.animated(); s.mounted = false }
        _ = rt.frame(at: 0.95)
        #expect(rt.state.drawnCount == 2)
        #expect(rt.state.visCount == 1)
    }

    @Test("input: unfocused/modal keyUp, press-focus tracking, gesture scroll target, Cmd+V outside editLens, pointerButtons & a11y step")
    func inc5AInputAndA11yFixes() {
        struct S {
            var keyLog: [String] = []
            var stepVal = 0
            var magHits = 0
            var pasteLog: [String] = []
            var bgClicks = 0
            var midClicks = 0
            var midClickCounts: [Int] = []
            var dblClicks = 0
            var modalOpen = false
        }
        let board = Clipboard(kind: .memory)
        board.writeText("modal-paste")
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 300)) { s, _ in
            var root: El<S> = col().w(300).h(300)
                .onKeyUp { st, ev, _ in st.keyLog.append("bg:\(ev.key)"); return true }
                .children([
                    row().key("btnA").role(.button).focusable(true).w(80).h(30)
                        .onKeyUp { st, ev, _ in st.keyLog.append("A:\(ev.key)"); return false },
                    row().key("btnB").role(.button).focusable(true).w(80).h(30)
                        .onKeyUp { st, ev, _ in st.keyLog.append("B:\(ev.key)"); return false },
                    el().key("midBtn").w(80).h(30)
                        .pointerButtons([.middle, .secondary])
                        .onClickPress { st, p, tx in
                            if tx.button == .middle {
                                st.midClicks += 1
                                st.midClickCounts.append(p.clicks)
                            } else {
                                st.bgClicks += 1
                            }
                        }
                        .onDoubleClick { st, _ in st.dblClicks += 1 },
                    el().key("noHandlerMid").w(80).h(20).pointerButtons([.middle]),
                    col().key("scroll").scrollY().w(120).h(60)
                        .onMagnify { st, _, _ in st.magHits += 1; return true }
                        .child(el().w(120).h(120)),
                    el().key("stepper").role(.slider).w(100).h(20)
                        .onStep { st, d, _ in st.stepVal += d },
                    col().key("outerKeyUp").w(100).h(40)
                        .onKeyUp { st, ev, _ in st.keyLog.append("outer:\(ev.key)"); return true }
                        .child(
                            col().key("deep").w(100).h(40)
                                .onKeyUp { st, ev, _ in st.keyLog.append("deep:\(ev.key)"); return true }
                        )
                ])
            if s.modalOpen {
                root = root.child(
                    col().key("modal").modal().w(200).h(200)
                        .onPaste { st, text, _ in st.pasteLog.append(text) }
                        .onKeyUp { st, ev, _ in st.keyLog.append("modal:\(ev.key)"); return true }
                )
            }
            return root
        }
        rt.useClipboard(board)
        _ = rt.frame(at: 0)

        // 1. Unfocused keyUp walks deepest-first (`deep` consumes before `bg`)
        #expect(rt.keyUp(KeyEvent(key: .space), at: 0.05))
        #expect(rt.state.keyLog == ["deep:space"])

        // 2. Key pressed on btnA, focus shifts to btnB before keyUp -> A hears release too
        rt.state.keyLog.removeAll()
        rt.update(at: 0.06) { _, tx in tx.focus("btnA") }
        _ = rt.frame(at: 0.07)
        _ = rt.keyDown(KeyEvent(key: .enter), at: 0.08)
        rt.update(at: 0.09) { _, tx in tx.focus("btnB") }
        _ = rt.frame(at: 0.1)
        _ = rt.keyUp(KeyEvent(key: .enter), at: 0.11)
        #expect(rt.state.keyLog.contains("A:enter"))
        #expect(rt.state.keyLog.contains("B:enter"))

        // 3. Direct accessibilityAction(.increment/.decrement) works without focusing
        #expect(rt.accessibilityAction("stepper", .increment, at: 0.12))
        #expect(rt.state.stepVal == 1)

        // 4. Secondary click never triggers onClick; handlerless pointerButtons is non-hittable; non-primary stays clicks==1
        let midRect = rt.element(byKey: "midBtn")?.rect ?? []
        let midCenter = Vec2(midRect[0] + 10, midRect[1] + 10)
        rt.pointerDown(at: midCenter, button: .secondary, mods: .none, at: 0.2)
        rt.pointerUp(at: midCenter, button: .secondary, mods: .none, at: 0.21)
        #expect(rt.state.bgClicks == 0)
        #expect(rt.state.midClicks == 0)

        rt.pointerDown(at: midCenter, button: .middle, mods: .none, at: 0.3)
        rt.pointerUp(at: midCenter, button: .middle, mods: .none, at: 0.31)
        rt.pointerDown(at: midCenter, button: .middle, mods: .none, at: 0.35)
        rt.pointerUp(at: midCenter, button: .middle, mods: .none, at: 0.36)
        #expect(rt.state.midClickCounts == [1, 1])
        #expect(rt.state.dblClicks == 0)

        let noHandRect = rt.element(byKey: "noHandlerMid")?.rect ?? []
        rt.pointerDown(at: Vec2(noHandRect[0] + 10, noHandRect[1] + 10), button: .middle, mods: .none, at: 0.4)
        #expect(rt.pressedKey == nil)

        // 5. Gesture reaches scroll descendant
        let scRect = rt.element(byKey: "scroll")?.rect ?? []
        #expect(rt.magnify(MagnifyEvent(delta: 0.1), at: Vec2(scRect[0] + 10, scRect[1] + 10), now: 0.45))
        #expect(rt.state.magHits == 1)

        // 6. Modal confines unfocused keyUp & Cmd+V outside editLens reaches modal onPaste
        rt.state.keyLog.removeAll()
        rt.update(at: 0.5) { s, _ in s.modalOpen = true }
        _ = rt.frame(at: 0.51)
        #expect(rt.keyUp(KeyEvent(key: .space), at: 0.52))
        #expect(rt.state.keyLog == ["modal:space"])
        #expect(rt.keyDown(KeyEvent(key: .text("v"), mods: RuneTestKey.primaryMods()), at: 0.53))
        #expect(rt.state.pasteLog == ["modal-paste"])
    }

    @Test("hover: HoverHold keeps hovered row during moving layout and releases on pointerMove")
    func hoverHoldMovingLayout() {
        struct S { var expanded = false }
        let lit = Color(r: 0.2, g: 0.5, b: 0.9, a: 1.0)
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 300)) { s, _ in
            col().w(200).children([
                el().key("top").w(200).h(s.expanded ? 140 : 40)
                    .hover(lit)
                    .animate(MotionTokens.SETTLE).animateLayout(),
                el().key("bot").w(200).h(40)
                    .hover(lit)
                    .animate(MotionTokens.SETTLE).animateLayout(),
            ])
        }
        _ = rt.frame(at: 0.0)
        rt.pointerMove(to: Vec2(50, 60), at: 1.0 / 60.0)
        _ = rt.frame(at: 1.0 / 60.0)
        #expect(rt.hoveredKey == "bot")
        #expect((rt.element(byKey: "bot")?.hover ?? 0) > 0.9)
        #expect((rt.element(byKey: "top")?.hover ?? 1) == 0.0)

        rt.update(at: 2.0 / 60.0) { s, tx in
            s.expanded = true
            tx.animated()
        }
        var sawMoving = false
        for step in 2...12 {
            _ = rt.frame(at: Double(step) / 60.0)
            if rt.element(byKey: "bot")?.moving == true {
                sawMoving = true
                #expect(rt.hoveredKey == "bot")
                #expect((rt.element(byKey: "top")?.hover ?? 1) == 0.0)
            }
        }
        #expect(sawMoving)

        // Moving the pointer releases HoverHold immediately while layout is still animating
        rt.pointerMove(to: Vec2(50, 61), at: 13.0 / 60.0)
        _ = rt.frame(at: 13.0 / 60.0)
        #expect(rt.hoveredKey == "top")
        #expect((rt.element(byKey: "top")?.hover ?? 0) > 0.9)
    }

    @Test("live: liveOffset + liveScale on parent propagates descendant presented rects, onDrawnLayout & hit-testing")
    func liveOffsetScaleDescendantPropagation() {
        struct S {
            var clicks = 0
            var drawn: [[Float]] = []
        }
        let off = Live<Vec2>(Vec2(40, 20))
        let sc = Live<Float>(2.0)
        let rt = Runtime<S>(state: S(), viewport: Vec2(400, 400)) { _, _ in
            el().key("world").w(200).h(200).origin(0, 0)
                .liveOffset(off.binding)
                .liveScale(sc.binding)
                .child(
                    el().key("box").w(30).h(20).ml(10).mt(10)
                        .onClick { s, _ in s.clicks += 1 }
                        .onDrawnLayout { s, r in s.drawn.append(r) }
                )
        }
        _ = rt.frame(at: 0.0)
        let r0 = rt.element(byKey: "box")?.rect ?? []
        #expect(r0.count == 4)
        #expect(abs(r0[0] - 60) < 0.1 && abs(r0[1] - 40) < 0.1 && abs(r0[2] - 60) < 0.1 && abs(r0[3] - 40) < 0.1)
        #expect(rt.state.drawn.count == 1)
        if let d0 = rt.state.drawn.last, d0.count == 4 {
            #expect(abs(d0[0] - 60) < 0.1 && abs(d0[1] - 40) < 0.1 && abs(d0[2] - 60) < 0.1 && abs(d0[3] - 40) < 0.1)
        }

        // Point (110, 70) is inside zoomed [60..120, 40..80] and outside unzoomed/unscaled rects
        rt.pointerDown(at: Vec2(110, 70), at: 0.02)
        rt.pointerUp(at: Vec2(110, 70), at: 0.03)
        #expect(rt.state.clicks == 1)

        off.set(Vec2(100, 50))
        sc.set(1.5)
        _ = rt.frame(at: 0.05)
        let r1 = rt.element(byKey: "box")?.rect ?? []
        #expect(r1.count == 4)
        #expect(abs(r1[0] - 115) < 0.1 && abs(r1[1] - 65) < 0.1 && abs(r1[2] - 45) < 0.1 && abs(r1[3] - 30) < 0.1)
        #expect(rt.state.drawn.count == 2)
        if let d1 = rt.state.drawn.last, d1.count == 4 {
            #expect(abs(d1[0] - 115) < 0.1 && abs(d1[1] - 65) < 0.1 && abs(d1[2] - 45) < 0.1 && abs(d1[3] - 30) < 0.1)
        }

        // renderFrame(at:) must also propagate PresentedTransform and invoke onDrawnLayout
        off.set(Vec2(20, 10))
        sc.set(2.0)
        _ = rt.renderFrame(at: 0.08)
        let r2 = rt.element(byKey: "box")?.rect ?? []
        #expect(r2.count == 4)
        #expect(abs(r2[0] - 40) < 0.1 && abs(r2[1] - 30) < 0.1 && abs(r2[2] - 60) < 0.1 && abs(r2[3] - 40) < 0.1)
        #expect(abs((rt.element(byKey: "box")?.scale ?? 0) - 2.0) < 0.05)
        #expect(rt.state.drawn.count == 3)
        if let d2 = rt.state.drawn.last, d2.count == 4 {
            #expect(abs(d2[0] - 40) < 0.1 && abs(d2[1] - 30) < 0.1 && abs(d2[2] - 60) < 0.1 && abs(d2[3] - 40) < 0.1)
        }
    }

    @Test("review fixes: HTML-only paste skips plain onPaste, default hover fades 0.1s easeOut, exiting renderFrame hover=0")
    func review626FixesSmoke() {
        struct S {
            var pasteHits: [String] = []
            var richEdit = TextEdit("init", multiline: true).rich()
            var secEdit = TextEdit("", multiline: false)
            var showItem = true
        }
        let lit = Color(r: 0.2, g: 0.4, b: 0.8, a: 1.0)
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 300)) { s, _ in
            col().w(300).h(300)
                .onPaste { st, text, _ in st.pasteHits.append(text) }
                .children([
                    el().key("plain").w(100).h(40).hover(lit),
                    textInput(key: "rich", \S.richEdit).size(100, 40),
                    textInput(key: "sec", \S.secEdit).secure().size(100, 40),
                    s.showItem
                        ? el().key("exiter").w(100).h(40).hover(lit).transition(.opacity)
                        : el().key("spacer").w(100).h(40),
                ])
        }
        _ = rt.frame(at: 0.0)

        // 1. HTML-only clipboard does not fire plain onPaste
        #expect(!rt.deliverPaste(ClipboardContent("", html: "<b>hi</b>"), at: 0.01))
        #expect(rt.state.pasteHits.isEmpty)

        // 2. Focused rich edit receives HTML paste; focused secure edit ignores HTML & keeps plain text
        rt.update(at: 0.02) { _, tx in tx.focus("rich") }
        _ = rt.frame(at: 0.025)
        _ = rt.deliverPaste(ClipboardContent("bold", html: "<b>bold</b>"), at: 0.03)
        #expect(rt.state.richEdit.text.contains("bold"))
        rt.update(at: 0.04) { _, tx in tx.focus("sec") }
        _ = rt.frame(at: 0.045)
        _ = rt.deliverPaste(ClipboardContent("pw", html: "<b>pw</b>"), at: 0.05)
        #expect(rt.state.secEdit.text == "pw")
        #expect(rt.state.secEdit.isSecure)

        // 3. Default hover without hoverMotion is instant on enter and fades smoothly over 0.1s easeOut on exit
        rt.pointerMove(to: Vec2(20, 20), at: 0.06)
        _ = rt.frame(at: 0.06)
        #expect((rt.element(byKey: "plain")?.hover ?? 0) > 0.99)
        rt.pointerMove(to: Vec2(250, 250), at: 0.07)
        _ = rt.frame(at: 0.11) // 0.04s into 0.1s easeOut fade
        let midHover = rt.element(byKey: "plain")?.hover ?? -1
        #expect(midHover > 0.05 && midHover < 0.95)
        _ = rt.frame(at: 0.20)
        #expect((rt.element(byKey: "plain")?.hover ?? 1) < 0.001)

        // 4. Exiting snapshot inside renderFrame reports hover == 0
        rt.pointerMove(to: Vec2(20, 140), at: 0.21)
        _ = rt.renderFrame(at: 0.21)
        #expect((rt.element(byKey: "exiter")?.hover ?? 0) > 0.9)
        rt.update(at: 0.22) { s, tx in
            s.showItem = false
            tx.animated()
        }
        _ = rt.renderFrame(at: 0.25)
        let exEl = rt.element(byKey: "exiter")
        #expect(exEl?.exiting == true)
        #expect((exEl?.hover ?? -1) == 0.0)
    }

    @Test("tx.instant() unmounts omitted transition rows, snaps fresh transition rows, and keeps exiting ancestor descendants")
    func txInstantAndExitingAncestorDescendantsParity() {
        struct S {
            var showPopup = true
            var rows = ["a0", "a1", "a2"]
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(400, 400)) { s, _ in
            var root: El<S> = col().w(400).h(400)
            if s.showPopup {
                root = root.child(
                    col()
                        .key("popup")
                        .w(200)
                        .h(200)
                        .transition(.opacity)
                        .children(s.rows.map { r in
                            el().key("row-\(r)").w(200).h(30).transition(.opacity)
                        })
                )
            }
            return root
        }
        _ = rt.frame(at: 0.0)
        // tx.instant() removes a0/a2 immediately and mounts b0/b1 snapped at full opacity & final y
        rt.update(at: 0.1) { s, tx in
            s.rows = ["a1", "b0", "b1"]
            tx.instant()
        }
        _ = rt.frame(at: 0.11)
        #expect(rt.element(byKey: "row-a0") == nil)
        #expect(rt.element(byKey: "row-a2") == nil)
        #expect(rt.element(byKey: "row-b0")?.opacity == 1.0)
        #expect(abs((rt.element(byKey: "row-b1")?.rect[1] ?? -1) - 60.0) < 0.05)

        // Closing popup with transition keeps transitionless / child rows mounted while popup fades
        rt.update(at: 0.2) { s, _ in
            s.showPopup = false
        }
        _ = rt.frame(at: 0.22)
        #expect(rt.element(byKey: "popup")?.exiting == true)
        #expect(rt.element(byKey: "row-a1") != nil)
        #expect(rt.element(byKey: "row-b1") != nil)
    }

    @Test("scrollPage GLIDE lands within 30 frames at exact target and liveFill avoids OKLab 1e-6 rounding")
    func scrollGlideLandingAndLiveFillExactness() {
        let red = Color(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        let blue = Color(r: 0.0, g: 0.0, b: 1.0, a: 1.0)
        let liveColor = Live(red)
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 100)) { _, _ in
            col()
                .size(200, 100)
                .child(
                    el()
                        .key("swatch")
                        .size(20, 20)
                        .liveFill(liveColor.smooth(Spring(duration: 0.12, bounce: 0.0)))
                )
                .child(
                    col()
                        .key("scroll")
                        .wFull()
                        .h(100)
                        .scrollY()
                        .children((0..<20).map { i in el().key("r\(i)").wFull().h(20) })
                )
        }
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(rt.element(byKey: "swatch")?.fill == red)

        liveColor.set(blue)
        for _ in 0..<30 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        #expect(rt.element(byKey: "swatch")?.fill == blue)

        rt.update(at: t) { _, tx in
            tx.scrollPage("scroll", 1)
        }
        for _ in 0..<30 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        #expect(rt.scrollOffset(forKey: "scroll").y == 90.0)
    }

    @Test("#517/#619/pageScroll regressions: color crossfade, reducedMotion REDUCED_FADE, instant unmount, settle pass, pageScroll hover release")
    func inc5BPaintGateSettleAndPageScrollRegressions() {
        // 1. tx.colorMotion animates color cross-fade smoothly; reducedMotion cross-fades colors via REDUCED_FADE while snapping motion(.none)
        struct PaintState { var lit = false }
        let rtPaint = Runtime<PaintState>(state: PaintState(), viewport: Vec2(120, 80)) { s, _ in
            el().key("swatch").size(60, 40).bg(s.lit ? Color(r: 1, g: 0, b: 0, a: 1) : Color(r: 0, g: 0, b: 1, a: 1))
        }
        _ = rtPaint.frame(at: 0.0)
        rtPaint.update(at: 0.02) { s, tx in
            s.lit = true
            tx.colorMotion(MotionTokens.DEFAULT)
        }
        _ = rtPaint.frame(at: 0.04)
        #expect(rtPaint.isAnimating)
        let fMid = rtPaint.frame(at: 0.06)
        let bgMid = fMid.primitives.first { $0.rect.z > 0 && $0.fill.w > 0 }?.fill.x ?? -1
        #expect(bgMid > 0.05 && bgMid < 0.95)
        _ = rtPaint.frame(at: 1.0)
        #expect(!rtPaint.isAnimating)

        let rtReduced = Runtime<PaintState>(state: PaintState(), viewport: Vec2(120, 80)) { s, _ in
            el().key("swatch").size(60, 40)
                .rounded(s.lit ? 16 : 4)
                .bg(s.lit ? Color(r: 1, g: 0, b: 0, a: 1) : Color(r: 0, g: 0, b: 1, a: 1))
        }
        _ = rtReduced.frame(at: 0.0)
        rtReduced.setSystemReducedMotion(true)
        rtReduced.update(at: 0.02) { s, _ in s.lit = true }
        _ = rtReduced.frame(at: 0.03)
        let radRed = rtReduced.element(byKey: "swatch")?.radius ?? -1
        #expect(abs(radRed - 16.0) < 0.1)
        #expect(rtReduced.isAnimating) // REDUCED_FADE on bg color
        _ = rtReduced.frame(at: 0.25)
        #expect(!rtReduced.isAnimating)

        let rtReducedNone = Runtime<PaintState>(state: PaintState(), viewport: Vec2(120, 80)) { s, _ in
            el().key("swatch").size(60, 40)
                .motion(.none)
                .bg(s.lit ? Color(r: 1, g: 0, b: 0, a: 1) : Color(r: 0, g: 0, b: 1, a: 1))
        }
        _ = rtReducedNone.frame(at: 0.0)
        rtReducedNone.setSystemReducedMotion(true)
        rtReducedNone.update(at: 0.02) { s, _ in s.lit = true }
        _ = rtReducedNone.frame(at: 0.03)
        #expect(!rtReducedNone.isAnimating)

        // 2. #619 item 3: tx.instant() immediately unmounts transitioning node instead of keeping it exiting
        struct ExitState { var show = true }
        let rtExit = Runtime<ExitState>(state: ExitState(), viewport: Vec2(200, 100)) { s, _ in
            col().size(200, 100).child(
                s.show
                    ? el().key("panel").size(80, 40).bg(.white).transition(.opacity)
                    : el().key("placeholder").size(80, 40)
            )
        }
        _ = rtExit.frame(at: 0.0)
        rtExit.update(at: 0.1) { s, tx in
            s.show = false
            tx.instant()
        }
        _ = rtExit.frame(at: 0.12)
        #expect(rtExit.element(byKey: "panel") == nil)

        // 3. #619 item 2: tx.settle() unmounts exiting node and lands waiting motion
        let rtSettle = Runtime<ExitState>(state: ExitState(), viewport: Vec2(200, 100)) { s, _ in
            col().size(200, 100).child(
                s.show
                    ? el().key("panel").size(80, 40).bg(.white).transition(.opacity)
                    : el().key("placeholder").size(80, 40)
            )
        }
        _ = rtSettle.frame(at: 0.0)
        rtSettle.update(at: 0.1) { s, tx in
            s.show = false
            tx.animated()
        }
        _ = rtSettle.frame(at: 0.12)
        #expect(rtSettle.element(byKey: "panel")?.exiting == true)
        rtSettle.update(at: 0.15) { _, tx in tx.settle() }
        _ = rtSettle.frame(at: 0.16)
        #expect(rtSettle.element(byKey: "panel") == nil)

        // 4. pageScroll releases held hover while scroll is gliding
        let rtScroll = Runtime<Int>(state: 0, viewport: Vec2(200, 100)) { _, _ in
            col().key("list").size(200, 100).scrollY().children(
                (0..<10).map { i in el().key("row-\(i)").size(200, 40).hover(Color(r: 0.2, g: 0.4, b: 0.8, a: 1)) }
            )
        }
        _ = rtScroll.frame(at: 0.0)
        rtScroll.pointerMove(to: Vec2(20, 20), at: 0.05)
        _ = rtScroll.frame(at: 0.05)
        #expect((rtScroll.element(byKey: "row-0")?.hover ?? 0) > 0.9)
        rtScroll.fling(vy: -400, at: Vec2(20, 20), now: 0.06)
        _ = rtScroll.frame(at: 0.08)
        rtScroll.keyDown(KeyEvent(key: .pageDown), at: 0.1)
        _ = rtScroll.frame(at: 0.1)
        #expect(rtScroll.scrollOffset(forKey: "list").y > 0)
        _ = rtScroll.frame(at: 0.25)
        _ = rtScroll.frame(at: 0.40)
        #expect((rtScroll.element(byKey: "row-0")?.hover ?? 1) < 0.01)
    }
}
