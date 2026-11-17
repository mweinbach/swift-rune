import Foundation
import Testing
@testable import Rune
#if os(macOS)
import AppKit
#endif

@Suite("Screen reader field ranges and control names")
@MainActor
struct A11yReaderParityTests {
    @Test func disclosureRequestsPressOnlyWhenTheRequestedStateDiffers() throws {
        struct State {
            var open = false
            var touchTaps: [Bool] = []
            var buttons: [PointerButton] = []
        }
        let rt = Runtime(state: State(), viewport: Vec2(120, 80), systemDark: false) { state, _ in
            el().key("more").size(100, 60).role(.button).expanded(state.open)
                .onClickPress { state, press, tx in
                    state.open.toggle()
                    state.touchTaps.append(tx.touchTap())
                    state.buttons.append(press.button)
                }
        }
        rt.frame(at: 0)
        let path = try #require(rt.accessibilitySnapshot().runtimePath)
        let point = Vec2(20, 20)
        rt.touch(id: 1, phase: .started, at: point, time: 0.1)
        #expect(!rt.accessibilityAction(path, .collapse, at: 0.2))
        #expect(rt.accessibilityAction(path, .expand, at: 0.3))
        rt.frame(at: 0.3)
        #expect(rt.state.open)
        #expect(!rt.accessibilityAction(path, .expand, at: 0.4))
        #expect(rt.accessibilityAction(path, .collapse, at: 0.5))
        rt.frame(at: 0.5)
        #expect(!rt.accessibilityAction(path, .collapse, at: 0.6))
        rt.touch(id: 1, phase: .cancelled, at: point, time: 0.7)
        #expect(!rt.state.open)
        #expect(rt.state.buttons == [.primary, .primary])
        #expect(rt.state.touchTaps == [false, false])
    }

    @Test func readerActivatesAnOffscreenButtonByIdentity() throws {
        struct State { var events: [String] = [] }
        let rt = Runtime(state: State(), viewport: Vec2(200, 80), systemDark: false) { _, _ in
            col().sizeFull().scrollY().children([
                row().h(200).shrink(0),
                el().key("action").h(30).shrink(0)
                    .onPointerDown { state, _, _ in state.events.append("pointer down") }
                    .onClick { $0.events.append("activate") }
                    .onClickPress { state, press, _ in
                        if press.button == .primary { state.events.append("primary") }
                    }
            ])
        }
        rt.frame(at: 0)
        let button = try #require(rt.flatNodes.first { $0.key == "action" })
        #expect(button.targetRect.y >= 80)
        #expect(rt.accessibilityAction(button.path, .press, at: 0.1))
        #expect(rt.state.events == ["activate", "primary"])
        #expect((rt.accessibilitySnapshot().scrollY ?? 0) == 0)
    }

    @Test func keyedRootDescendantsRetainTextUnderTheirRuntimeIdentity() throws {
        struct Form { var draft = TextEdit("A🦀e\u{301}") }
        let rt = Runtime(state: Form(), viewport: Vec2(300, 120), systemDark: false) { _, _ in
            col().key("document").child(col().key("section").child(textInput(key: "draft", \Form.draft)))
        }
        rt.frame(at: 0)
        let field = try #require(rt.flatNodes.first { $0.key == "draft" })
        #expect(try #require(rt.nodeTextLayouts[field.nodeId]).box.authText == rt.state.draft.text)
    }

    @Test func readerRevealsAnOffscreenDescendantWithoutFocusingIt() throws {
        let rt = Runtime(state: 0, viewport: Vec2(300, 120), systemDark: false) { _, _ in
            col().key("scroll").sizeFull().scrollY().children([
                row().h(380).shrink(0),
                text("Last row").key("last").h(30).shrink(0)
            ])
        }
        rt.frame(at: 0)
        let tree = rt.accessibilitySnapshot()
        let row = try #require(tree.children.first { $0.id == "last" })
        #expect(!tree.actions.contains(.scrollIntoView))
        #expect(row.actions.contains(.scrollIntoView))
        #expect(row.frame.top >= rt.viewport.y)

        #if os(macOS)
        let action = NSAccessibility.Action(rawValue: "AXScrollToVisible")
        let runtime = MacOSUnsafeSendableBox(rt)
        let element = AppKitAccessibilityMapper.buildElement(from: row, onAction: { id, action in
            MainActor.assumeIsolated { _ = runtime.value.accessibilityAction(id, action, at: 0.1) }
        })
        #expect(element.accessibilityActionNames().contains(action))
        element.accessibilityPerformAction(action)
        #else
        #expect(rt.accessibilityAction(try #require(row.runtimePath), .scrollIntoView, at: 0.1))
        #endif
        rt.frame(at: 0.2)
        let scrolled = rt.accessibilitySnapshot()
        #expect((scrolled.scrollY ?? 0) > 0)
        #expect(try #require(scrolled.children.first { $0.id == "last" }).frame.top < rt.viewport.y)
        #expect(rt.focusedKey == nil)
    }

    @Test func labelledControlRetainsIndependentChildren() {
        let rt = Runtime(state: 0, viewport: Vec2(320, 120), systemDark: true) { _, _ in
            row().key("control").role(.button).label("Open document").children([
                col().key("part").label("document").children([text("Open"), text("Recent changes")]),
                el().key("nested").role(.link).label("Open").onClick { $0 += 1 },
                text("Open").key("double").onDoubleClick { state, _ in state += 1 },
                text("document").key("focusable").focusable(true)
            ])
        }
        rt.frame(at: 0)
        let children = rt.accessibilitySnapshot().children
        #expect(children.map { $0.label } == ["Recent changes", "Open", "Open", "document"])
        #expect(children.last?.isFocusable == true)

        let plain = Runtime(state: 0, viewport: Vec2(320, 80), systemDark: true) { _, _ in
            row().role(.button).child(text("Save"))
        }
        plain.frame(at: 0)
        #expect(plain.accessibilitySnapshot().children.first?.value == "Save")
    }

    @Test func selectionReachesTheEditorWithoutChangingText() {
        struct Form { var draft = TextEdit("a🦀e\u{301}"); var changes = 0 }
        let rt = Runtime(state: Form(), viewport: Vec2(180, 60), systemDark: true) { _, _ in
            col().child(textInput(key: "draft", \Form.draft).a11yValue("override").onChange { state, _, _ in state.changes += 1 })
        }
        rt.frame(at: 0)
        #expect(rt.accessibilitySnapshot().children.first?.value == rt.state.draft.text)
        #expect(rt.accessibilitySelectText("draft", range: 1..<5, at: 0.1))
        #expect(rt.focusedKey == "draft")
        #expect(rt.state.draft.anchor == 1 && rt.state.draft.cursor == 5)
        #expect(rt.accessibilitySelectText("draft", range: 6..<8, at: 0.2))
        #expect(rt.state.draft.anchor == 6 && rt.state.draft.cursor == 8)
        #expect(rt.state.changes == 0)
        #expect(!rt.accessibilitySelectText("missing", range: 0..<1))
    }

    @Test func webContextCompletesLinesAndKeepsSelectionDirection() {
        let line = String(repeating: "🦀", count: 400)
        let prefix = String(repeating: "before\n", count: 1000)
        var edit = TextEdit(prefix + line + "\n" + String(repeating: "after\n", count: 1000), multiline: true)
        edit.setSelectionRaw(anchor: prefix.utf8.count + 880, cursor: prefix.utf8.count + 800)
        let context = WebFieldMirror(key: "field", edit: edit, secure: false)
        #expect(context.text.hasPrefix("before\n"))
        #expect(context.text.hasSuffix("after") || context.text.hasSuffix("\n"))
        let a = ImeUTF16Bridge.utf8Offset(in: context.text, fromUTF16Offset: context.anchor)
        let f = ImeUTF16Bridge.utf8Offset(in: context.text, fromUTF16Offset: context.focus)
        #expect(context.base + a == edit.anchor)
        #expect(context.base + f == edit.cursor)
        #expect(context.base > 0)
        #expect(context.text.utf8.count < 2_400)

        var long = TextEdit(String(repeating: "x", count: 20_000))
        long.setSelectionRaw(anchor: 10_000, cursor: 10_000)
        let cut = WebFieldMirror(key: "field", edit: long, secure: false)
        #expect(cut.text.count == 1024)
        #expect(cut.base == 9488)
        let hidden = WebFieldMirror(key: "field", edit: edit, secure: true)
        #expect(hidden.text.isEmpty && hidden.base == 0 && hidden.anchor == 0 && hidden.focus == 0)
    }

    @Test func webKeyboardActivatesFocusedField() throws {
        struct State { var edit = TextEdit("prompt") }
        let app = AppSpec<State>(title: "Input", size: Vec2(180, 60), state: State(),
                                 view: { _, _ in textInput(key: "prompt", \State.edit).w(120) })
        let host = WebAppHost(spec: app)
        var activated: WebFieldMirror?
        host.onFieldChange = { field, activate in if activate { activated = field } }
        _ = try host.renderFrame(at: 0)
        #expect(host.runtime.accessibilityAction("prompt", .press, at: 0.1))
        _ = host.handleKeyDown(code: "ArrowLeft", key: "ArrowLeft", at: 0.2)
        #expect(activated?.text == "prompt")
        #expect(activated?.wrap == "off")
    }

    #if os(macOS)
    @Test func offMainChildrenQueryUsesNSViewSuperclass() async {
        let parent = NSView()
        let child = NSAccessibilityElement()
        parent.setAccessibilityChildren([child])
        let expected = parent.accessibilityChildren()?.count
        #expect(expected == 1)
        let view = MacOSUnsafeSendableBox(parent)
        let observed = await Task.detached {
            MacOSHostViewHelper.superclassAccessibilityChildren(of: view.value)?.count
        }.value
        #expect(observed == expected)
    }

    @Test func retainedNativeFieldReflectsChangesAndSecureTransition() throws {
        let host = MacOSAccessibilityHost()
        let view = NSView()
        var node = AccessibilityNode(id: "draft", role: .textInput, label: "Draft", value: "before",
                                     isFocused: true, textSelection: [0, 0, 0, 0], actions: [.setValue])
        host.update(tree: node, parentView: view, onSelectText: { _, _ in }, onAction: { _, _ in })
        let held = try #require(host.accessibilityFocusedUIElement() as? RuneAXTextField)
        node.value = "after 🦀"
        node.textSelection = [0, 6, 0, 10]
        node.actions = []
        node.label = nil
        host.update(tree: node, parentView: view, onAction: { _, _ in })
        #expect(host.accessibilityFocusedUIElement() as? RuneAXTextField === held)
        #expect(held.accessibilitySelectedText() == "🦀")
        #expect(held.accessibilityValue() as? String == "after 🦀")
        #expect(held.accessibilityLabel() == nil)
        #expect(!held.isAccessibilitySelectorAllowed(#selector(NSAccessibilityElement.setAccessibilitySelectedTextRange(_:))))

        node.isSecure = true
        node.value = "secret"
        host.update(tree: node, parentView: view, onAction: { _, _ in })
        #expect(!(host.accessibilityFocusedUIElement() is RuneAXTextField))
        #expect(held.accessibilityNumberOfCharacters() == 0)
        #expect(held.accessibilitySelectedText() == "")
    }

    @Test func longFieldAnswersNativeRangeQueriesAndSetsSelection() async throws {
        let prefix = String(repeating: "x", count: 70_000)
        let full = prefix + "\n🦀e\u{301}\n"
        let node = AccessibilityNode(id: "draft", role: .multilineTextInput, value: full,
                                     textSelection: [0, 70_005, 0, 70_001], actions: [.setValue])
        let (stream, send) = AsyncStream<Range<Int>>.makeStream()
        let element = AppKitAccessibilityMapper.buildElement(from: node, onSelectText: { _, range in send.yield(range) })
        #expect(element.isAccessibilitySelectorAllowed(#selector(NSAccessibilityElement.accessibilityString(for:))))
        #expect(element.isAccessibilitySelectorAllowed(#selector(NSAccessibilityElement.accessibilityRange(forLine:))))
        #expect(element.accessibilityNumberOfCharacters() == 70_006)
        #expect(element.accessibilitySelectedText() == "🦀")
        #expect(element.accessibilitySelectedTextRange() == NSRange(location: 70_001, length: 2))
        #expect(element.accessibilityRange(forLine: 1) == NSRange(location: 70_001, length: 5))
        #expect(element.accessibilityRange(forLine: 2) == NSRange(location: 70_006, length: 0))
        #expect(element.accessibilityRange(for: 70_001) == NSRange(location: 70_001, length: 2))
        #expect(element.accessibilityRange(for: 70_002) == NSRange(location: 70_003, length: 1))
        #expect(element.accessibilityLine(for: 70_002) == 1)
        #expect(element.accessibilityInsertionPointLineNumber() == 1)
        #expect(element.accessibilityString(for: NSRange(location: 70_003, length: 2)) == "e\u{301}")
        #expect(element.accessibilityAttributedString(for: NSRange(location: 70_001, length: 2))?.string == "🦀")
        #expect(element.accessibilityString(for: NSRange(location: Int.max - 1, length: Int.max)) == "")
        #expect(element.isAccessibilitySelectorAllowed(#selector(NSAccessibilityElement.setAccessibilitySelectedTextRange(_:))))
        element.setAccessibilitySelectedTextRange(NSRange(location: 70_001, length: 1))
        send.finish()
        var result = stream.makeAsyncIterator()
        #expect(await result.next() == 70_001..<70_005)
        // A nonsecure native field exposes the full value even without shaped text run children.
        #expect(element.accessibilityValue() as? String == full)

        var password = node
        password.isSecure = true
        let hidden = AppKitAccessibilityMapper.buildElement(from: password)
        #expect(!(hidden is RuneAXTextField))
        #expect(hidden.accessibilityValue() == nil)
    }
    #endif
}
