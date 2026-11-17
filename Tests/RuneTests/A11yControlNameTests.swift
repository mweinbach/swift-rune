import Testing
@testable import Rune

@Suite("Default and related control names")
@MainActor
struct A11yControlNameTests {
    @Test func allProjectionsSpeakEachNamedControlOnce() throws {
        let viewport = Vec2(450, 300)
        let view: El<Int> = col().children([
            text("Choose file").key("title"),
            row().key("related").role(.button).label(" \n").labelledBy("title")
                .child(text("Choose file")),
            row().key("default").role(.button).defaultButton()
                .child(col().key("inner").children([text("Save"), text("changes")])),
            row().key("plain").role(.button).child(text("Continue")),
        ])
        let rt = Runtime(state: 0, viewport: viewport, systemDark: true) { _, _ in view }
        rt.frame(at: 0)
        func layoutInput(_ element: El<Int>) -> LayoutInputNode {
            LayoutInputNode(style: element.layout, children: element.children.map(layoutInput))
        }
        let layout = LayoutEngine.compute(root: layoutInput(view), viewport: viewport)
        let direct = try #require(AccessibilityTreeBuilder.project(element: view, layout: layout))
        let listed = AccessibilityTreeBuilder.project(elements: rt.elements(), focusedPath: nil, viewport: viewport)
        for tree in [rt.accessibilitySnapshot(), direct, listed] {
            let related = try #require(tree.children.first { $0.id == "related" })
            #expect(related.label == "Choose file")
            #expect(related.children.isEmpty)
            let action = try #require(tree.children.first { $0.id == "default" })
            #expect(action.label == "Save changes")
            #expect(action.children.isEmpty)
            let plain = try #require(tree.children.first { $0.id == "plain" })
            #expect(plain.label == nil)
            #expect(plain.children.count == 1)
            #expect((plain.children.first?.value ?? plain.children.first?.label) == "Continue")
        }
    }
}
