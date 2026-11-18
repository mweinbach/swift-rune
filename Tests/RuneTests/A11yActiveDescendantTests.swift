import Testing
@testable import Rune

@Suite
struct A11yActiveDescendantTests {
    @Test func aReentrantEditKeepsNativeFocusOnTheCapturedActiveDescendant() {
        struct Form { var selected = "old" }
        final class Callback { var update: (() -> Void)? }
        let callback = Callback()
        let runtime = Runtime(state: Form(), viewport: Vec2(220, 120)) { form, _ in
            col().children([
                textInput(key: "entry", editAccess(get: { _ in
                    let update = callback.update
                    callback.update = nil
                    update?()
                    return TextEdit("draft")
                }, set: { _, _ in })),
                col().key("files").role(.tree).focusable().activeDescendant(form.selected)
                    .child(el().key("old").role(.treeItem).label("Old"))
                    .child(el().key("new").role(.treeItem).label("New")),
            ])
        }
        _ = runtime.renderFrame(at: 0)
        runtime.update(at: 0.1) { _, tx in tx.focus("files") }
        _ = runtime.renderFrame(at: 0.1)
        let before = runtime.nativeAccessibilitySnapshot()
        callback.update = {
            runtime.update(at: 1) { form, _ in form.selected = "new" }
            _ = runtime.renderFrame(at: 1)
        }
        let during = runtime.nativeAccessibilitySnapshot()
        let after = runtime.nativeAccessibilitySnapshot()
        func focused(_ node: AccessibilityNode) -> [String] {
            (node.isFocused ? [node.id] : []) + node.children.flatMap(focused)
        }
        #expect(focused(before) == ["old"])
        #expect(during == before)
        #expect(focused(after) == ["new"])
    }

    @Test func nativeFocusFollowsTheExactMountedRowWhileKeyboardFocusStaysOnTheComposite() {
        let composed = "pkg/\u{e9}"
        let decomposed = "pkg/e\u{301}"
        let runtime = Runtime<String>(state: composed, viewport: Vec2(300, 200)) { selected, _ in
            col().sizeFull().children([
                col().key("outside").children([
                    el().key(decomposed).role(.treeItem).label("Other tree"),
                    el().key("suggestion").role(.option).label("Popup"),
                ]),
                col().key("files").role(.tree).focusable().label("Files").activeDescendant(selected).children([
                    el().key(composed, byteExact: true).role(.treeItem).label("First file"),
                    el().key(decomposed, byteExact: true).role(.treeItem).label("Second file"),
                ]),
            ])
        }
        func focusedNames(_ node: AccessibilityNode) -> [String] {
            (node.isFocused ? [node.label ?? node.id] : []) + node.children.flatMap(focusedNames)
        }
        _ = runtime.frame(at: 0)
        #expect(runtime.accessibilityAction("files", .focus, at: 0))
        _ = runtime.frame(at: 0)
        for (index, selection) in [composed, decomposed, "suggestion", "missing", ""].enumerated() {
            let now = Double(index + 1) / 10
            runtime.update(at: now) { state, _ in state = selection }
            _ = runtime.frame(at: now)
            let expected = ["First file", "Second file", "Popup", "Files", "Files"][index]
            #expect(focusedNames(runtime.nativeAccessibilitySnapshot()) == [expected])
            #expect(focusedNames(runtime.accessibilitySnapshot()) == ["Files"])
            #expect(runtime.focusedKey == "files")
        }
    }
}
