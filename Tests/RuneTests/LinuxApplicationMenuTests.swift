#if os(Linux)
import Testing
@testable import Rune

@Suite("Linux application menu")
@MainActor
struct LinuxApplicationMenuTests {
    private typealias Menu = LinuxApplicationMenu<[String]>
    private typealias Item = NativeMenuItem<[String]>

    private struct Window {
        let shared: AppShared<[String]>
        let menu: Menu
        let runtime: Runtime<[String]>

        init(items: [Item], fitsContentHeight: Bool = false) {
            let shared = AppShared<[String]>()
            let menu = Menu(shared: shared, title: "Editor", fitsContentHeight: fitsContentHeight)
            let runtime = Runtime(state: [String](), viewport: Vec2(480, 300), pixelScale: 1) { _, cx in
                let document: El<[String]> = el().key("document").wFull().h(44).focusable()
                    .child(el().size(32, 24).role(.button).label("Print").onClick { _ in })
                return menu.view(content: document, in: &cx)
            }
            self.shared = shared
            self.menu = menu
            self.runtime = runtime
            menu.runtime = runtime
            runtime.fitHeight = fitsContentHeight
            AppMenuBridge.attach(items, to: shared)
            turn(at: 0)
        }

        func turn(at time: Double) {
            menu.applyFocus(at: time)
            _ = shared.applyStateUpdates(to: runtime, at: time)
            menu.refresh()
            runtime.frame(at: time)
        }

        func node(role: ElementRole, label: String) throws -> AccessibilityNode {
            func match(_ node: AccessibilityNode) -> AccessibilityNode? {
                if node.role == role && node.label == label { return node }
                for child in node.children {
                    if let found = match(child) { return found }
                }
                return nil
            }
            return try #require(match(runtime.accessibilitySnapshot()))
        }
    }

    @Test func keyboardMovesAcrossEnabledRowsAndReturnsFocusToTheDocument() throws {
        let app = Window(items: [
            Item(id: "open", title: "Open") { state, _ in state.append("open") },
            .separator(),
            Item(id: "locked", title: "Locked", enabled: false) { state, _ in state.append("locked") },
            Item(id: "guides", title: "Guides", keyEquivalent: "mod+g", checked: true) { state, _ in state.append("guides") },
            Item(id: "inspect", title: "Inspect", location: .named("Tools")) { state, _ in state.append("inspect") },
        ])
        let bar = try app.node(role: .menuBar, label: "Application menu")
        #expect(bar.children.compactMap(\.label) == ["Editor", "Tools"])
        app.runtime.update(at: 0.01) { _, tx in tx.focus("document") }
        app.turn(at: 0.02)
        #expect(app.runtime.focusedKey == "document")

        #expect(app.menu.navigate(KeyEvent(key: .f(10))))
        app.turn(at: 0.03)
        #expect(app.runtime.focusedKey == Menu.itemKey("open"))
        let popup = try app.node(role: .menu, label: "Editor")
        #expect(popup.frame.top >= bar.frame.bottom)
        let locked = try app.node(role: .menuItem, label: "Locked")
        #expect(locked.isDisabled)
        #expect(!app.runtime.accessibilityAction(locked.id, .press, at: 0.04))

        #expect(app.menu.navigate(KeyEvent(key: .arrowDown)))
        app.turn(at: 0.05)
        let guides = try app.node(role: .menuItemCheckbox, label: "Guides")
        #expect(guides.isFocused)
        #expect(guides.toggled == .trueState)
        #expect(guides.keyboardShortcut == "Ctrl+G")

        #expect(app.menu.navigate(KeyEvent(key: .arrowRight)))
        app.turn(at: 0.06)
        let inspect = try app.node(role: .menuItem, label: "Inspect")
        #expect(inspect.isFocused)
        #expect(app.menu.navigate(KeyEvent(key: .escape)))
        app.turn(at: 0.07)
        #expect(app.runtime.focusedKey == "document")
        #expect(app.runtime.state.isEmpty)

        let printButton = try app.node(role: .button, label: "Print")
        let printPath = try #require(printButton.runtimePath)
        #expect(app.runtime.accessibilityAction(printPath, .focus, at: 0.08))
        #expect(app.runtime.focusedKey == nil)
        #expect(app.runtime.focusedPath == printPath)
        #expect(app.menu.navigate(KeyEvent(key: .f(10))))
        app.turn(at: 0.09)
        #expect(app.menu.navigate(KeyEvent(key: .escape)))
        app.turn(at: 0.10)
        #expect(app.runtime.focusedPath == printPath)
    }

    @Test func stationaryPointerLeavesKeyboardSelectionIntactUntilPointerMovesAgain() throws {
        let app = Window(items: [
            Item(id: "open", title: "Open") { state, _ in state.append("open") },
            Item(id: "save", title: "Save") { state, _ in state.append("save") },
        ])
        #expect(app.menu.navigate(KeyEvent(key: .f(10))))
        app.turn(at: 0.01)
        let openRow = try #require(app.runtime.find(Menu.itemKey("open")))
        app.menu.pointerMoved()
        app.runtime.pointerMove(to: openRow, at: 0.02)
        app.turn(at: 0.03)
        #expect(app.menu.navigate(KeyEvent(key: .end)))
        app.turn(at: 0.04)
        #expect(app.runtime.focusedKey == Menu.itemKey("save"))

        // Relayout can re-enter the hovered row without a new SDL motion event.
        app.menu.hover(item: 0)
        app.turn(at: 0.05)
        #expect(app.runtime.focusedKey == Menu.itemKey("save"))

        app.menu.pointerMoved()
        app.runtime.pointerMove(to: Vec2(openRow.x + 1, openRow.y), at: 0.06)
        app.turn(at: 0.07)
        #expect(app.runtime.focusedKey == Menu.itemKey("open"))
        app.runtime.pointerDown(at: openRow, at: 0.08)
        app.runtime.pointerUp(at: openRow, at: 0.09)
        app.turn(at: 0.10)
        #expect(app.runtime.state == ["open"])
    }

    @Test func replacementDuringPointerPressRejectsOldRowAndPublishesNewAccessibleAction() throws {
        let app = Window(items: [
            Item(id: "save", title: "Save") { state, _ in state.append("old") }
        ], fitsContentHeight: true)
        #expect(app.runtime.contentHeight() == 72)
        let trigger = try app.node(role: .menuItem, label: "Editor")
        #expect(app.runtime.accessibilityAction(trigger.id, .press, at: 0.01))
        app.turn(at: 0.02)
        let row = try #require(app.runtime.find(Menu.itemKey("save")))
        app.runtime.pointerDown(at: row, at: 0.03)
        try AppMenuBridge.setMenu([
            Item(id: "save", title: "Save As") { state, _ in state.append("new") }
        ], for: app.shared)
        // The host has received a replacement while the previous frame is still on screen.
        app.runtime.pointerUp(at: row, at: 0.04)
        app.turn(at: 0.05)
        #expect(app.runtime.state.isEmpty)

        if app.menu.activeSection == nil {
            #expect(app.runtime.accessibilityAction(trigger.id, .press, at: 0.06))
        }
        app.turn(at: 0.07)
        let replacement = try app.node(role: .menuItem, label: "Save As")
        #expect(app.runtime.accessibilityAction(replacement.id, .press, at: 0.08))
        app.turn(at: 0.09)
        #expect(app.runtime.state == ["new"])
        #expect(app.menu.activeSection == nil)

        #expect(app.runtime.accessibilityAction(trigger.id, .press, at: 0.10))
        app.turn(at: 0.11)
        let newRow = try #require(app.runtime.find(Menu.itemKey("save")))
        app.runtime.pointerDown(at: newRow, at: 0.12)
        app.runtime.pointerUp(at: newRow, at: 0.13)
        app.turn(at: 0.14)
        #expect(app.runtime.state == ["new", "new"])
    }
}
#endif
