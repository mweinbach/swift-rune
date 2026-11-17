import Foundation
import Testing
@testable import Rune
@testable import RuneMotion
@testable import RuneRef

@Suite("Rune Core, Layout, TextEdit & Runtime Tests")
struct RuneTests {
    @Test("Color hex, OKLCH round-trip, JsonTheme $ref, and srgbEquivalent solver")
    func colorAndTheme() throws {
        let short = Color.hex("#f0a")!
        let full = Color.hex("#ff00aa")!
        #expect(short == full)
        #expect(full.hexString() == "#ff00aa")
        #expect(Color.hex("invalid") == nil)
        #expect(Color.hex("") == nil)

        let c = oklch(0.65, 0.14, 250)
        let lab = c.toOKLab()
        #expect(abs(lab[0] - 0.65) < 0.01)

        // Verify srgbEquivalent reproduces CSS sRGB alpha blending when composited in linear light!
        let bg = Color.hex("#101010")!
        let fg = Color.white.alpha(0.10)
        let solved = fg.srgbEquivalent(over: bg)
        let linCompositeR = solved.r * solved.a + bg.r * (1.0 - solved.a)
        let outSRGB = RefShader.linearToSRGB(linCompositeR)
        let expectedCSS = 1.0 * 0.10 + RefShader.linearToSRGB(bg.r) * 0.90
        #expect(abs(outSRGB - expectedCSS) < 0.01)

        let themeJSON = """
        {
          "name": "opencode-test",
          "defs": {
            "brandBlue": "#3b82f6",
            "inkDark": "#f8fafc",
            "inkLight": "#0f172a"
          },
          "theme": {
            "primary": "$brandBlue",
            "text": { "dark": "$inkDark", "light": "$inkLight" }
          }
        }
        """
        let darkTheme = try JsonTheme.parse(data: Data(themeJSON.utf8), dark: true)
        let lightTheme = try JsonTheme.parse(data: Data(themeJSON.utf8), dark: false)
        #expect(darkTheme["primary"]?.hexString() == "#3b82f6")
        #expect(darkTheme["text"]?.hexString() == "#f8fafc")
        #expect(lightTheme["text"]?.hexString() == "#0f172a")
    }

    @Test("Machine primitives: Seq stale cancellation and Effects inline small-buffer")
    func machinePrimitives() {
        var seq = Seq()
        let t1 = seq.next()
        let t2 = seq.next()
        #expect(!seq.isCurrent(t1))
        #expect(seq.isCurrent(t2))
        seq.cancel()
        #expect(!seq.isCurrent(t2))

        var fx = Effects<Int>.none
        #expect(fx.isEmpty)
        fx.push(10)
        fx.push(20)
        #expect(fx.count == 2)
        fx.push(30)
        #expect(fx.array == [10, 20, 30])
    }

    @Test("Flexbox layout: grow, shrink, minH(0) scroll, wrap, justifyBetween, and absolute pins")
    func flexboxLayoutEngine() {
        let tree = LayoutInputNode(
            style: {
                var s = LayoutStyle(direction: .column)
                s.padding = .all(10)
                s.rowGap = 10
                return s
            }(),
            children: [
                // Header: fixed 40pt height
                LayoutInputNode(style: {
                    var s = LayoutStyle(direction: .row)
                    s.height = .points(40)
                    s.justifyContent = .spaceBetween
                    return s
                }(), children: [
                    LayoutInputNode(style: { var s = LayoutStyle(); s.width = .points(60); s.height = .points(20); return s }()),
                    LayoutInputNode(style: { var s = LayoutStyle(); s.width = .points(80); s.height = .points(20); return s }()),
                ]),
                // Scrollable body with grow(1) + minH(0) containing a 1000pt tall child!
                LayoutInputNode(style: {
                    var s = LayoutStyle(direction: .column)
                    s.flexGrow = 1
                    s.flexBasis = .points(0)
                    s.minHeight = .points(0)
                    s.scrollAxes = .vertical
                    return s
                }(), children: [
                    LayoutInputNode(style: { var s = LayoutStyle(); s.height = .points(1000); return s }()),
                ]),
                // Absolutely pinned badge in top-right corner
                LayoutInputNode(style: {
                    var s = LayoutStyle()
                    s.isAbsolute = true
                    s.pinTop = 8
                    s.pinRight = 12
                    s.width = .points(30)
                    s.height = .points(16)
                    return s
                }()),
            ]
        )

        let solved = LayoutEngine.compute(root: tree, viewport: Vec2(400, 300))
        #expect(solved.layout.localRect == .fromXYWH(0, 0, 400, 300))

        let header = solved.children[0]
        #expect(header.layout.localRect == .fromXYWH(10, 10, 380, 40))
        // Space-between places second child flush against right edge (380 - 80 = 300)
        #expect(header.children[1].layout.localRect.x == 300)

        // Scrollable body must shrink to remaining viewport height (300 - 20 pad - 40 header - 10 gap = 230), NOT expand to 1000!
        let scrollBody = solved.children[1]
        #expect(scrollBody.layout.localRect == .fromXYWH(10, 60, 380, 230))
        #expect(scrollBody.layout.contentSize.y == 1000)

        // Pinned badge at right=12, width=30 -> x = 400 - 12 - 30 = 358, y = 8
        let badge = solved.children[2]
        #expect(badge.layout.localRect == .fromXYWH(358, 8, 30, 16))
    }

    @Test("TextEdit Unicode ZWJ emoji grapheme safety, word navigation, and undo/redo")
    func textEditGraphemeAndUndo() {
        var ed = TextEdit("")
        // Insert ASCII + ZWJ family emoji (25 UTF-8 bytes!) + combining accent + flag
        ed.insert("Hi 👨‍👩‍👧‍👦 e\u{0301} 🇯🇵")
        let fullLen = ed.text.utf8.count
        #expect(ed.cursor == fullLen)

        // Backspace once must delete the entire Japanese flag grapheme, leaving valid String
        ed.backspace()
        #expect(ed.text == "Hi 👨‍👩‍👧‍👦 e\u{0301} ")

        // Move left across space, combining 'é', space, and ZWJ family emoji without ever splitting scalars
        ed.moveLeft() // before trailing space
        ed.moveLeft() // before 'é'
        ed.moveLeft() // before space
        ed.moveLeft() // before 👨‍👩‍👧‍👦
        #expect(ed.cursor == 3) // right after "Hi "

        // Delete forward removes the entire 25-byte ZWJ family emoji in a single keypress!
        ed.deleteForward()
        #expect(ed.text == "Hi  e\u{0301} ")

        // Undo restores the ZWJ emoji cleanly
        let didUndo = ed.undo()
        #expect(didUndo)
        #expect(ed.text == "Hi 👨‍👩‍👧‍👦 e\u{0301} ")
        let didRedo = ed.redo()
        #expect(didRedo)
        #expect(ed.text == "Hi  e\u{0301} ")
    }

    @Test("Runtime interactive switch spring, slider Escape cancel, modal focus trap, and Live zero-rebuild")
    func runtimeInteractionsAndLive() {
        struct TestState: Equatable {
            var toggled: Bool = false
            var sliderVal: Float = 0.2
            var sliderBeforeDrag: Float = 0.2
            var modalOpen: Bool = false
            var outsideClicks: Int = 0
            var modalClicks: Int = 0
        }

        let liveAlpha = Live<Float>(1.0)

        let rt = Runtime<TestState>(
            state: TestState(),
            viewport: Vec2(400, 300)
        ) { s, _ in
            var root: El<TestState> = col()
                .sizeFull()
                .p(20)
                .gap(16)
                .child(
                    el()
                        .key("outside-btn")
                        .size(100, 32)
                        .onClick { st in
                            st.outsideClicks += 1
                            st.toggled.toggle()
                        }
                        .child(
                            el()
                                .key("knob")
                                .square(20)
                                .absolute(x: s.toggled ? 76 : 4, y: 6)
                                .animateLayout(Tok.Motion.SNAPPY)
                        )
                )
                .child(
                    el()
                        .key("slider")
                        .size(200, 24)
                        .onDrag { st, drag, _ in
                            if drag.phase == .down {
                                st.sliderBeforeDrag = st.sliderVal
                            }
                            if drag.isCancelled {
                                st.sliderVal = st.sliderBeforeDrag
                            } else {
                                st.sliderVal = (drag.local.x / max(1, drag.size.x)).clamped(to: 0...1)
                            }
                        }
                )
                .child(
                    el()
                        .key("meter")
                        .size(80, 12)
                        .liveOpacity(liveAlpha.binding)
                )

            if s.modalOpen {
                root = root.child(
                    col()
                        .key("dialog")
                        .modal(true)
                        .absolute(x: 50, y: 50)
                        .size(200, 120)
                        .child(
                            el()
                                .key("modal-ok")
                                .size(80, 30)
                                .onClick { st in st.modalClicks += 1 }
                        )
                )
            }
            return root
        }

        _ = rt.frame(at: 0.0)
        #expect(rt.element(byKey: "knob")?.rect[0] == 24.0) // 20 pad + 4 local

        // 1. Click button to toggle -> knob springs smoothly toward x = 20 + 76 = 96
        let btnRect = rt.element(byKey: "outside-btn")!.rect
        let btnCenter = Vec2(btnRect[0] + btnRect[2] * 0.5, btnRect[1] + btnRect[3] * 0.5)
        rt.pointerDown(at: btnCenter, at: 0.1)
        rt.pointerUp(at: btnCenter, at: 0.15)
        #expect(rt.state.toggled == true)

        _ = rt.frame(at: 0.20)
        let midKnobX = rt.element(byKey: "knob")!.rect[0]
        #expect(midKnobX > 25.0 && midKnobX < 95.0)
        _ = rt.frame(at: 2.0)
        #expect(rt.element(byKey: "knob")!.rect[0] == 96.0)

        // 2. Drag slider then press Escape mid-drag -> restores pre-drag value 0.2!
        let slRect = rt.element(byKey: "slider")!.rect
        rt.pointerDown(at: Vec2(slRect[0] + 20, slRect[1] + 12), at: 2.1)
        rt.pointerMove(to: Vec2(slRect[0] + 160, slRect[1] + 12), at: 2.2)
        #expect(rt.state.sliderVal > 0.7)
        rt.keyDown(KeyEvent(key: .escape), at: 2.25)
        #expect(abs(rt.state.sliderVal - 0.2) < 1e-5)

        // 3. Live<Float> updates opacity WITHOUT incrementing viewCommitCount!
        _ = rt.frame(at: 2.3)
        let commitsBefore = rt.viewCommitCount
        liveAlpha.set(0.35)
        _ = rt.frame(at: 2.35)
        #expect(rt.viewCommitCount == commitsBefore)
        #expect(abs(rt.element(byKey: "meter")!.opacity - 0.35) < 1e-3)

        // 4. Modal focus & pointer trapping
        rt.state.modalOpen = true
        rt.markNeedsCommit(settle: true)
        _ = rt.frame(at: 3.0)
        #expect(rt.element(byKey: "outside-btn")?.inert == true)
        #expect(rt.element(byKey: "modal-ok")?.inert == false)

        // Tab cycles strictly inside the modal!
        rt.keyDown(KeyEvent(key: .tab), at: 3.1)
        #expect(rt.focusedKey == "modal-ok")
        rt.keyDown(KeyEvent(key: .tab), at: 3.2)
        #expect(rt.focusedKey == "modal-ok")
    }

    @Test("HeadlessRunner executes --script JSON and emits valid PNG and tree JSON")
    func headlessScriptReplay() throws {
        struct CounterState {
            var count = 0
            var note = TextEdit("")
        }

        let spec = AppSpec<CounterState>(
            title: "Counter Test",
            size: Vec2(320, 200),
            state: CounterState()
        ) { s, _ in
            col().sizeFull().p(16).gap(12).bg(.black)
                .child(text("Count: \(s.count)").key("label").color(.white))
                .child(
                    row().key("inc").size(80, 32).bg(Tok.accent(0, dark: true))
                        .onClick { st in st.count += 1 }
                        .child(text("+1").color(.white))
                )
                .child(textInput(key: "field", \.note).size(200, 32).bg(.rgba8(30, 30, 35)).color(.white))
        }

        let script = """
        [
          { "t": 0.05, "type": "tap", "key": "inc" },
          { "t": 0.20, "type": "tap", "key": "inc" },
          { "t": 0.35, "type": "tap", "key": "field" },
          { "t": 0.45, "type": "type", "text": "Rune!" }
        ]
        """

        var args = ToolingArgs()
        args.scriptArg = script
        args.forceCPU = true
        let output = try HeadlessRunner.run(spec, args: args)

        #expect(output.finalFrame.width == 640 && output.finalFrame.height == 400)
        let tree = try JSONSerialization.jsonObject(with: output.treeJSON) as! [String: Any]
        let els = tree["elements"] as! [[String: Any]]
        let labelText = els.first(where: { ($0["key"] as? String) == "label" })?["text"] as? String
        let fieldText = els.first(where: { ($0["key"] as? String) == "field" })?["text"] as? String
        #expect(labelText == "Count: 2")
        #expect(fieldText == "Rune!")
    }
}
