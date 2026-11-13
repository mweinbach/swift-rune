import Foundation
import Testing
@testable import RuneKit
@testable import Rune
@testable import RuneMotion

@Suite("RuneKit Inputs & Containers Parity Tests")
struct InputsAndContainersTests {
    // MARK: - Helpers

    private func click(_ rt: Runtime<some Sendable>, at point: Vec2, t: inout Double) {
        rt.pointerDown(at: point, at: t)
        t += 0.016
        rt.pointerUp(at: point, at: t)
        t += 0.016
        _ = rt.frame(at: t)
    }

    private func center(of rect: [Float]) -> Vec2 {
        Vec2(rect[0] + rect[2] * 0.5, rect[1] + rect[3] * 0.5)
    }

    private func findByPathSuffix(_ rt: Runtime<some Sendable>, _ suffix: String) -> ElementInfo? {
        rt.elements().first(where: { !$0.exiting && $0.path.hasSuffix(suffix) })
    }

    private func projectAccessibility<S>(_ root: El<S>, viewport: Vec2 = Vec2(640, 800)) -> AccessibilityNode? {
        func buildInput(_ el: El<S>) -> LayoutInputNode {
            LayoutInputNode(style: el.layout, children: el.children.map(buildInput))
        }
        let layout = LayoutEngine.compute(root: buildInput(root), viewport: viewport)
        return AccessibilityTreeBuilder.project(element: root, layout: layout)
    }

    private func flattenA11y(_ node: AccessibilityNode) -> [AccessibilityNode] {
        [node] + node.children.flatMap(flattenA11y)
    }

    // MARK: - text_area_grow.rs

    @MainActor
    @Test("TextArea autoGrow fits lines between minRows and maxRows, springs, scrolls, and submits on Enter")
    func autoGrowFitsLinesSpringsAndScrolls() {
        struct S {
            var draft = TextEdit("", multiline: true)
            var sent = 0
        }

        let kit = Kit.neutral(dark: true)
        let rt = Runtime<S>(state: S(), viewport: Vec2(400, 400), pixelScale: 2.0, systemDark: true) { _, _ in
            col().sizeFull().p(20.0).child(
                TextArea(key: "composer", \.draft)
                    .autoGrow(1, 4)
                    .width(nil)
                    .onSubmit { s, _, _ in s.sent += 1 }
                    .build(kit)
            )
        }

        var t = 0.0
        _ = rt.frame(at: t)
        let composer = rt.element(byKey: "composer")!
        let input0 = rt.element(byKey: "composer-input")!
        click(rt, at: center(of: input0.rect), t: &t)
        #expect(rt.focusedKey == "composer-input")

        let line: Float = 17.5
        let one = composer.rect[3]
        #expect(abs(one - (line + 16.0)) < 0.5)

        // Shift+Enter adds a line and grows toward 2 rows.
        _ = rt.keyDown(KeyEvent(key: .enter, mods: Mods(shift: true)), at: t)
        _ = rt.keyDown(KeyEvent(key: .text("second")), at: t)
        t += 0.016
        _ = rt.frame(at: t)
        let twoMid = rt.element(byKey: "composer")!
        #expect(abs((twoMid.target[3]) - (2.0 * line + 16.0)) < 0.5)
        for _ in 0..<60 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let twoSettled = rt.element(byKey: "composer")!
        #expect(abs(twoSettled.rect[3] - (2.0 * line + 16.0)) < 0.5)

        // Past 4 rows it caps height at 4 rows + 16pt padding while input grows taller inside scroll viewport.
        for n in 3...7 {
            _ = rt.keyDown(KeyEvent(key: .enter, mods: Mods(shift: true)), at: t)
            _ = rt.keyDown(KeyEvent(key: .text("line \(n)")), at: t)
            t += 0.016
            _ = rt.frame(at: t)
        }
        for _ in 0..<60 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let capped = rt.element(byKey: "composer")!
        #expect(abs(capped.rect[3] - (4.0 * line + 16.0)) < 0.5)
        let inner = rt.element(byKey: "composer-input")!
        #expect(inner.target[3] > 6.5 * line)

        // Plain Enter submits, and Cmd+A + Backspace shrinks back to 1 row.
        _ = rt.keyDown(KeyEvent(key: .enter), at: t)
        #expect(rt.state.sent == 1)

        _ = rt.keyDown(KeyEvent(key: .command("a"), mods: Mods(cmd: true)), at: t)
        _ = rt.keyDown(KeyEvent(key: .backspace), at: t)
        for _ in 0..<60 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        #expect(abs(rt.element(byKey: "composer")!.rect[3] - one) < 0.5)
    }

    // MARK: - text_input_press.rs

    @MainActor
    @Test("Copy button without handler keeps focus and caret position")
    func copyButtonWithoutHandlerKeepsPress() {
        struct S {
            var edit: TextEdit
        }

        var initial = TextEdit("text")
        initial.setCursor(utf8Offset: 1)

        let kit = Kit.neutral(dark: true)
        let rt = Runtime<S>(state: S(edit: initial), viewport: Vec2(400, 100), pixelScale: 1.0, systemDark: true) { _, _ in
            TextInput(key: "ti", \.edit)
                .copyButton()
                .build(kit)
        }

        var t = 0.0
        _ = rt.frame(at: t)
        click(rt, at: center(of: rt.element(byKey: "ti-input")!.rect), t: &t)
        rt.state.edit.setCursor(utf8Offset: 1)
        _ = rt.frame(at: t)

        let actionBtn = rt.element(byKey: "ti-action")!
        click(rt, at: center(of: actionBtn.rect), t: &t)
        #expect(rt.focusedKey == "ti-input")
        #expect(rt.state.edit.selectedUTF8Range == 1..<1)
    }

    @MainActor
    @Test("Pressing any part of TextInput, TextField, or TextArea focuses without blurring or dragging window")
    func pressingAnyPartFocusesWithoutBlurringOrDragging() {
        struct S {
            var input = TextEdit("hunter2")
            var field = TextEdit("vault")
            var area = TextEdit("notes", multiline: true)
            var actions = 0
            var revealed = false
            var copied = 0
        }

        let kit = Kit.neutral(dark: true)
        let rt = Runtime<S>(state: S(), viewport: Vec2(480, 400), pixelScale: 2.0, systemDark: true) { _, _ in
            let accessories: El<S> = row()
                .key("accessories")
                .gap(6.0)
                .px(4.0)
                .centerY()
                .child(text("pw").key("hint"))
                .child(
                    kit.iconButton(key: "reveal", svg: kit.glyph.check, label: "Reveal", size: .sm, variant: .ghost) { s, _ in
                        s.revealed.toggle()
                    }
                )

            return col()
                .sizeFull()
                .p(16.0)
                .gap(16.0)
                .child(
                    row().key("titlebar").wFull().h(48.0).windowDrag().centerY().px(12.0).child(
                        TextInput(key: "ti", \.input)
                            .placeholder("Search")
                            .leadingIcon(kit.glyph.search)
                            .trailing(accessories)
                            .clearButton()
                            .onAction { s, _ in s.actions += 1 }
                            .build(kit)
                    )
                )
                .child(
                    TextField(key: "tf", "Label", \.field)
                        .copyable()
                        .onAction { s, _ in s.copied += 1 }
                        .build(kit)
                )
                .child(
                    TextArea(key: "ta", \.area)
                        .build(kit)
                )
        }

        var t = 0.0
        _ = rt.frame(at: t)

        let ti = rt.element(byKey: "ti")!
        let lead = findByPathSuffix(rt, "leading") ?? rt.elements().first(where: { $0.key == "leading" })!
        let hint = rt.element(byKey: "hint")!
        let reveal = rt.element(byKey: "reveal")!
        let clear = rt.element(byKey: "ti-action")!

        // 1. Clicking leading icon focuses field, places caret at start, and is NOT a bare titlebar drag region.
        let leadCenter = center(of: lead.rect)
        #expect(!rt.isBareTitlebarDragRegion(at: leadCenter))
        click(rt, at: leadCenter, t: &t)
        #expect(rt.focusedKey == "ti-input")
        #expect(rt.state.input.selectedUTF8Range == 0..<0)

        // 2. Clicking trailing non-button accessory or top padding moves caret to end without blurring.
        click(rt, at: Vec2(hint.rect[0] + hint.rect[2] * 0.5, ti.rect[1] + 2.0), t: &t)
        #expect(rt.focusedKey == "ti-input")
        #expect(rt.state.input.selectedUTF8Range == 7..<7)

        // Clicking bottom-left padding moves caret back to start.
        click(rt, at: Vec2(ti.rect[0] + 3.0, ti.rect[1] + ti.rect[3] - 2.0), t: &t)
        #expect(rt.focusedKey == "ti-input")
        #expect(rt.state.input.selectedUTF8Range == 0..<0)

        // 3. Trailing buttons still handle their own press.
        click(rt, at: center(of: reveal.rect), t: &t)
        #expect(rt.state.revealed)
        click(rt, at: center(of: clear.rect), t: &t)
        #expect(rt.state.actions == 1)

        // 4. TextField padding and copy button.
        let wrapper = rt.element(byKey: "tf-wrapper")!
        let copyBtn = rt.element(byKey: "tf-copy")!
        click(rt, at: Vec2(wrapper.rect[0] + wrapper.rect[2] - 30.0, wrapper.rect[1] + 2.0), t: &t)
        #expect(rt.focusedKey == "tf-input")
        #expect(rt.state.field.selectedUTF8Range == 5..<5)
        click(rt, at: Vec2(wrapper.rect[0] + 3.0, wrapper.rect[1] + wrapper.rect[3] - 2.0), t: &t)
        #expect(rt.focusedKey == "tf-input")
        #expect(rt.state.field.selectedUTF8Range == 0..<0)
        click(rt, at: center(of: copyBtn.rect), t: &t)
        #expect(rt.state.copied == 1)

        // 5. TextArea padding focuses at end/start.
        let ta = rt.element(byKey: "ta")!
        click(rt, at: Vec2(ta.rect[0] + ta.rect[2] - 4.0, ta.rect[1] + ta.rect[3] - 4.0), t: &t)
        #expect(rt.focusedKey == "ta-input")
        #expect(rt.state.area.selectedUTF8Range == 5..<5)
        click(rt, at: Vec2(ta.rect[0] + 2.0, ta.rect[1] + 4.0), t: &t)
        #expect(rt.focusedKey == "ta-input")
        #expect(rt.state.area.selectedUTF8Range == 0..<0)
    }

    @MainActor
    @Test("TextInput textStyle and height scale the box, vertically center slots, and match caret height")
    func launcherStyleScalesBoxAndCaret() {
        struct Launcher {
            var plain = TextEdit("hi")
            var big = TextEdit("hi")
            var launcher = TextEdit("hi")
            var largeCompact = TextEdit("hi")
            var tight = TextEdit("hi")
        }

        let kit = Kit.neutral(dark: true)
        let style24 = TextStyle(size: 17.0, weight: 400.0).lh(24.0)
        let rt = Runtime<Launcher>(state: Launcher(), viewport: Vec2(400, 300), pixelScale: 1.0, systemDark: true) { _, _ in
            col()
                .child(TextInput(key: "plain", \.plain).build(kit))
                .child(TextInput(key: "big", \.big).placeholder("Search").textStyle(style24).build(kit))
                .child(
                    TextInput(key: "launcher", \.launcher)
                        .placeholder("Type a command")
                        .leadingIcon(kit.glyph.search)
                        .clearButton()
                        .textStyle(style24)
                        .height(56.0)
                        .build(kit)
                )
                .child(
                    TextInput(key: "large-compact", \.largeCompact)
                        .large()
                        .textStyle(TextStyle(size: 13.0, weight: 500.0).lh(16.0))
                        .build(kit)
                )
                .child(TextInput(key: "tight", \.tight).textStyle(style24).height(10.0).build(kit))
        }

        var t = 0.0
        _ = rt.frame(at: t)
        let h: (String) -> Float = { rt.element(byKey: $0)!.rect[3] }
        #expect(h("plain") == 28.0)
        #expect(h("big") == 36.0)
        #expect(h("launcher") == 56.0)
        #expect(h("large-compact") == 32.0)
        #expect(h("tight") == 24.0)

        let boxRect = rt.element(byKey: "launcher")!.rect
        let inputRect = rt.element(byKey: "launcher-input")!.rect
        let actionRect = rt.element(byKey: "launcher-action")!.rect
        let boxCY = boxRect[1] + boxRect[3] * 0.5
        #expect(abs((inputRect[1] + inputRect[3] * 0.5) - boxCY) < 0.5)
        #expect(abs((actionRect[1] + actionRect[3] * 0.5) - boxCY) < 0.5)

        click(rt, at: Vec2(boxRect[0] + 40.0, boxCY), t: &t)
        #expect(rt.focusedKey == "launcher-input")
        let caret = rt.element(byKey: "launcher-input")!.caret!
        #expect(abs(caret[3] - 24.0) < 0.5)
        #expect(abs((caret[1] + caret[3] * 0.5) - boxCY) < 1.0)
    }

    @MainActor
    @Test("Plain TextInput draws no box, dims when disabled, centers 56pt slots, and keeps focus on clear")
    func plainFieldDrawsNoBoxAndFocusesOnPress() {
        struct P {
            var boxed = TextEdit("a")
            var plain = TextEdit("")
            var invalid = TextEdit("err")
            var disabled = TextEdit("off")
            var actions = 0
        }

        let kit = Kit.neutral(dark: true)
        let style24 = TextStyle(size: 17.0, weight: 400.0).lh(24.0)
        let rt = Runtime<P>(state: P(), viewport: Vec2(400, 260), pixelScale: 1.0, systemDark: true) { _, _ in
            col().gap(8.0)
                .child(TextInput(key: "boxed", \.boxed).leadingIcon(kit.glyph.search).build(kit))
                .child(
                    TextInput(key: "plain", \.plain)
                        .plain()
                        .placeholder("Type a command")
                        .leadingIcon(kit.glyph.search)
                        .leadingIconSize(18.0)
                        .textStyle(style24)
                        .height(56.0)
                        .width(nil)
                        .clearButton()
                        .onAction { s, _ in s.actions += 1 }
                        .build(kit)
                )
                .child(
                    TextInput(key: "invalid", \.invalid)
                        .plain()
                        .placeholder("Bad")
                        .invalid(true)
                        .state(.hover)
                        .build(kit)
                )
                .child(
                    TextInput(key: "disabled", \.disabled)
                        .plain()
                        .leadingIcon(kit.glyph.search)
                        .clearButton()
                        .disabled(true)
                        .onAction { s, _ in s.actions += 10 }
                        .build(kit)
                )
        }

        var t = 0.0
        _ = rt.frame(at: t)
        let plain = rt.element(byKey: "plain")!
        let boxed = rt.element(byKey: "boxed")!
        #expect(plain.role == .textInput)
        #expect(plain.fill.a == 0.0)
        #expect(boxed.fill.a > 0.0)
        #expect(rt.element(byKey: "plain-input")?.label == "Type a command")
        #expect(rt.element(byKey: "invalid-input")?.textColor == kit.c.danger.fg)
        #expect(abs((rt.element(byKey: "disabled")?.opacity ?? 1.0) - 0.5) < 0.01)

        let b = plain.rect
        let bCY = b[1] + b[3] * 0.5
        let clearRect = rt.element(byKey: "plain-action")!.rect
        #expect(abs((clearRect[0] + clearRect[2]) - (b[0] + b[2])) < 0.5)
        #expect(abs((clearRect[1] + clearRect[3] * 0.5) - bCY) < 0.5)

        // Clicking padding focuses plain input and types cleanly; clear button runs onAction without blurring.
        click(rt, at: Vec2(b[0] + 1.0, b[1] + b[3] - 1.0), t: &t)
        #expect(rt.focusedKey == "plain-input")
        _ = rt.keyDown(KeyEvent(key: .text("hi")), at: t)
        t += 0.016
        _ = rt.frame(at: t)
        #expect(rt.state.plain.text == "hi")

        click(rt, at: Vec2(clearRect[0] + 2.0, clearRect[1] + 2.0), t: &t)
        #expect(rt.state.actions == 1)
        #expect(rt.focusedKey == "plain-input")
    }

    @MainActor
    @Test("TextInput leadingIconSize scales icon container width and shifts input x")
    func leadingIconSizeScalesIconAndShiftsText() {
        struct P {
            var a = TextEdit("x")
            var b = TextEdit("x")
        }

        let kit = Kit.neutral(dark: true)
        let rt = Runtime<P>(state: P(), viewport: Vec2(400, 200), pixelScale: 1.0, systemDark: true) { _, _ in
            col()
                .child(TextInput(key: "a", \.a).leadingIcon(kit.glyph.search).height(56.0).build(kit))
                .child(TextInput(key: "b", \.b).leadingIcon(kit.glyph.search).leadingIconSize(24.0).height(56.0).build(kit))
        }
        _ = rt.frame(at: 0.0)
        let ia = rt.element(byKey: "a-input")!.rect
        let ib = rt.element(byKey: "b-input")!.rect
        #expect(abs((ib[0] - ia[0]) - 8.0) < 0.5)
    }

    @MainActor
    @Test("Secure TextInput suppresses copy button, hides accessibility text when revealed, and masks when hidden")
    func secureTextInputAndAreaBehavior() {
        struct Form {
            var secret: TextEdit
            var area: TextEdit
            var revealed = true
            var submitted = 0
        }

        var sec = TextEdit("hunter2")
        sec.isSecure = true
        sec.isRevealed = true
        var secArea = TextEdit("line1\nline2\nline3\nline4\nline5", multiline: true)
        secArea.isSecure = true
        secArea.isRevealed = false

        let kit = Kit.neutral(dark: true)
        let rt = Runtime<Form>(state: Form(secret: sec, area: secArea), viewport: Vec2(360, 260), pixelScale: 1.0, systemDark: true) { s, _ in
            col().gap(8.0)
                .child(
                    TextInput(key: "secret", \.secret)
                        .secure()
                        .revealed(s.revealed)
                        .copyButton()
                        .build(kit)
                )
                .child(
                    TextArea(key: "area", \.area)
                        .secure()
                        .revealed(s.revealed)
                        .maxHeight(90.0)
                        .onSubmit { st, _, _ in st.submitted += 1 }
                        .build(kit)
                )
        }

        var t = 0.0
        _ = rt.frame(at: t)
        #expect(rt.element(byKey: "secret-action") == nil)
        #expect(rt.element(byKey: "secret-input")?.secure == true)
        #expect(rt.element(byKey: "secret-input")?.text == nil)

        let areaInput = rt.element(byKey: "area-input")!
        click(rt, at: center(of: areaInput.rect), t: &t)
        #expect(rt.focusedKey == "area-input")
        #expect(rt.elementIsSecure(areaInput.path))
        let areaRevealed = rt.element(byKey: "area")!.rect
        #expect(areaRevealed[3] <= 90.5)

        _ = rt.keyDown(KeyEvent(key: .enter), at: t)
        #expect(rt.state.submitted == 0)

        rt.state.revealed = false
        t += 0.016
        _ = rt.frame(at: t)
        let inpHidden = rt.element(byKey: "area-input")!
        #expect(inpHidden.text == nil)
    }

    // MARK: - Container & A11y Parity (Badge, Divider, Field, Card, Collapsible, Accordion, TextField)

    @Test("Badge variants, highContrast border, Divider orientations, and no-echo a11y")
    func badgeAndDividerParity() {
        struct S {}
        let kit = Kit.neutral(dark: true)
        let root: El<S> = col()
            .child(Badge("Beta").standard().build(kit).key("std"))
            .child(Badge("Hi").highContrast().build(kit).key("hc"))
            .child(Badge("New").variant(.accent).build(kit).key("acc"))
            .child(Badge("Sub").variant(.subtle).build(kit).key("sub"))
            .child(Divider.horizontal().build(kit).key("hdiv"))
            .child(row().h(20).child(Divider.vertical().build(kit).key("vdiv")))

        let a11y = projectAccessibility(root)!
        let all = flattenA11y(a11y)
        let stdNode = all.first(where: { $0.id == "std" || $0.label == "Beta" })!
        #expect(stdNode.label == "Beta")
        #expect(stdNode.children.isEmpty) // inner text is a11yHidden

        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 140), pixelScale: 1.0, systemDark: true) { _, _ in root }
        _ = rt.frame(at: 0.0)
        #expect(rt.element(byKey: "std")!.rect[3] == 18.0)
        #expect(rt.element(byKey: "hc")!.rect[3] == 16.0)
        #expect(rt.element(byKey: "acc")!.fill == kit.c.bgAccent)
        #expect(rt.element(byKey: "sub")!.fill == kit.c.layer03)
        #expect(rt.element(byKey: "hdiv")!.role == .separator && rt.element(byKey: "hdiv")!.rect[3] == 1.0)
        #expect(rt.element(byKey: "vdiv")!.role == .separator && rt.element(byKey: "vdiv")!.rect[2] == 1.0)
    }

    @Test("Field, Card, and TextField expose upstream roles, descriptions, and layout")
    func fieldCardAndTextFieldParity() {
        struct S {
            var token = TextEdit("tok")
            var name = TextEdit("Ada")
        }

        let kit = Kit.neutral(dark: true)
        let root: El<S> = col()
            .child(
                Field<S>()
                    .label("Token")
                    .info()
                    .prefix("From your account page")
                    .suffix("Kept in the keychain")
                    .control(TextInput(key: "tok", \.token).label("Token").build(kit))
                    .build(kit)
                    .key("token-field")
            )
            .child(
                Card<S>()
                    .accent(kit.c.danger.fg)
                    .title("Build failed", icon: kit.glyph.close)
                    .description("3 tests failed")
                    .action(kit.button(key: "retry", "Retry") { _, _ in })
                    .build(kit)
                    .key("card")
            )
            .child(
                TextField<S>(key: "tf", "Name", \.name)
                    .error("Name is taken")
                    .build(kit)
            )

        let a11y = projectAccessibility(root)!
        let all = flattenA11y(a11y)

        let tokenField = all.first(where: { $0.id == "token-field" })!
        #expect(tokenField.role == .group && tokenField.label == "Token")
        #expect(tokenField.children.count == 1) // label & asides are a11yHidden

        let cardNode = all.first(where: { $0.id == "card" })!
        #expect(cardNode.role == .group && cardNode.label == "Build failed")
        #expect(!all.contains(where: { $0.id == "rule" }))

        let rt = Runtime<S>(state: S(), viewport: Vec2(400, 400), pixelScale: 1.0, systemDark: true) { _, _ in root }
        _ = rt.frame(at: 0.0)
        #expect(rt.element(byKey: "token-field")?.a11yDescription == "From your account page. Kept in the keychain")
        #expect(rt.element(byKey: "rule")?.rect[2] == 2.0)
        #expect(rt.element(byKey: "tf-input")?.a11yDescription == "Name is taken")
    }

    @MainActor
    @Test("Collapsible and Accordion toggle expanded state on click and expose region/button roles")
    func collapsibleAndAccordionParity() {
        struct S {
            var open = false
            var colOpen = false
        }

        let kit = Kit.neutral(dark: true)
        let rt = Runtime<S>(state: S(), viewport: Vec2(400, 320), pixelScale: 1.0, systemDark: true) { s, _ in
            col().gap(8.0)
                .child(
                    Accordion<S>()
                        .item(
                            AccordionSection("General")
                                .expanded(s.open)
                                .onToggle { st, _ in st.open.toggle() }
                                .child(text("Name and icon").key("acc-body"))
                        )
                        .item(AccordionSection("Advanced").disabled(true))
                        .build(kit)
                        .key("acc")
                )
                .child(
                    Collapsible<S>("Details", isOpen: s.colOpen)
                        .ghost()
                        .onToggle { st, _ in st.colOpen.toggle() }
                        .child(text("More words").key("col-body"))
                        .build(kit)
                        .key("col")
                )
        }

        var t = 0.0
        _ = rt.frame(at: t)
        let accTrigger = rt.elements().first(where: { $0.path.contains("item0") && $0.key == "trigger" })!
        #expect(accTrigger.role == .button && accTrigger.label == "General")
        #expect(accTrigger.expanded == false)

        let advTrigger = rt.elements().first(where: { $0.path.contains("item1") && $0.key == "trigger" })!
        #expect(advTrigger.disabled)

        let colTrigger = rt.elements().first(where: { $0.path.contains("@col") && $0.key == "trigger" })!
        #expect(colTrigger.role == .button && colTrigger.expanded == false)
        #expect(rt.element(byKey: "acc-body") == nil)
        #expect(rt.element(byKey: "col-body") == nil)

        click(rt, at: center(of: accTrigger.rect), t: &t)
        #expect(rt.state.open)
        let contentEl = rt.elements().first(where: { $0.path.contains("item0") && $0.key == "content" })!
        #expect(contentEl.role == .region && contentEl.label == "General")
        #expect(rt.element(byKey: "acc-body") != nil)

        let colTriggerNow = rt.elements().first(where: { $0.path.contains("@col") && $0.key == "trigger" })!
        click(rt, at: center(of: colTriggerNow.rect), t: &t)
        #expect(rt.state.colOpen)
        #expect(rt.element(byKey: "col-body") != nil)
    }
}
