import Testing
@testable import Rune

@Suite("Default and related control names")
@MainActor
struct A11yControlNameTests {
    private func projections(_ view: El<Int>) throws -> [AccessibilityNode] {
        let viewport = Vec2(450, 600)
        let rt = Runtime(state: 0, viewport: viewport, systemDark: true) { _, _ in view }
        rt.frame(at: 0)
        func layoutInput(_ element: El<Int>) -> LayoutInputNode {
            LayoutInputNode(style: element.layout, children: element.children.map(layoutInput))
        }
        let layout = LayoutEngine.compute(root: layoutInput(view), viewport: viewport)
        return [
            rt.accessibilitySnapshot(),
            try #require(AccessibilityTreeBuilder.project(element: view, layout: layout)),
            AccessibilityTreeBuilder.project(elements: rt.elements(), focusedPath: nil, viewport: viewport),
        ]
    }

    @Test func allProjectionsSpeakEachNamedControlOnce() throws {
        let view: El<Int> = col().children([
            text("Choose file").key("title"),
            row().key("related").role(.button).label(" \n").labelledBy("title")
                .child(text("Choose file")),
            row().key("default").role(.button).defaultButton()
                .child(col().key("inner").children([text("Save"), text("changes")])),
            row().key("plain").role(.button).child(text("Continue")),
        ])
        for tree in try projections(view) {
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

    @Test func leafControlsSuppressOnlyRepeatedContent() throws {
        let roles: [ElementRole] = [.checkbox, .radio, .switchControl, .tab, .menuItem, .menuItemCheckbox, .menuItemRadio, .option]
        let view: El<Int> = col().children(roles.map { role in
            row().key(role.rawValue).role(role).label("Daily summary")
                .child(col().child(text("Daily summary")))
                .child(text("Requires permission").key("hint"))
                .child(text("Daily summary").key("action").focusable())
        })
        for tree in try projections(view) {
            for role in roles {
                let node = try #require(tree.children.first { $0.id == role.rawValue })
                #expect(node.label == "Daily summary")
                #expect(node.children.map(\.id) == ["hint", "action"])
            }
        }
    }

    @Test func contentNamedLeafControlsOwnTheirTextAndReaderNamedControlsKeepIt() throws {
        let runeNamed: [ElementRole] = [.switchControl, .tab, .option, .menuItemCheckbox, .menuItemRadio]
        let readerNamed: [ElementRole] = [.checkbox, .radio, .menuItem, .link]
        let view: El<Int> = col().children((runeNamed + readerNamed).map { role in
            row().key(role.rawValue).role(role).child(text("Settings"))
        })
        for tree in try projections(view) {
            for role in runeNamed {
                let node = try #require(tree.children.first { $0.id == role.rawValue })
                #expect(node.label == "Settings")
                #expect(node.children.isEmpty)
            }
            for role in readerNamed {
                let node = try #require(tree.children.first { $0.id == role.rawValue })
                #expect(node.label == nil)
                #expect(node.children.count == 1)
                #expect(AccessibilityDump.dictionary(from: node)["name"] as? String == "Settings")
            }
        }
    }
}
