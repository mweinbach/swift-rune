#if os(Linux)
import Testing
@testable import Rune

@Suite("Linux context menus")
@MainActor
struct LinuxContextMenuTests {
    private struct Document {
        var picks: [String?] = []
        var bodyClicks = 0
    }

    private func documentWindow() -> Window<Document> {
        Window(Document()) {
            el().wFull().hFull().children([
                el().key("trigger").role(.button).label("Trigger").focusable()
                    .absolute(x: 50, y: 96).size(112, 32)
                    .onSecondaryClick { _, press, tx in
                        let share = PopupMenu().item("mail", "Mail").item("chat", "Chat")
                        let actions = PopupMenu().item("copy", "Copy")
                            .item("paste", "Paste", enabled: false).separator().submenu("Share", share)
                        tx.popupMenu(actions, at: press) { (s: inout Document, pick, _) in s.picks.append(pick) }
                    },
                el().key("document-action").absolute(x: 350, y: 260).size(96, 40)
                    .onClick { s in s.bodyClicks += 1 },
            ])
        }
    }

    private final class Window<State> {
        let menu: LinuxContextMenu<State>
        let runtime: Runtime<State>
        private(set) var time = 0.0

        init(_ state: State, content: @escaping () -> El<State>) {
            let menu = LinuxContextMenu<State>()
            self.menu = menu
            runtime = Runtime(state: state, viewport: Vec2(480, 320)) { _, cx in
                menu.view(content: content(), in: &cx, fitsContentHeight: false)
            }
            menu.runtime = runtime
            settle()
        }

        func settle() {
            // A key anchor can wait for layout. Opening then mounts the popup on the next frame.
            for _ in 0..<2 {
                time += 0.01
                menu.refresh(at: time)
                _ = runtime.frame(at: time)
            }
        }

        func click(_ point: Vec2, button: PointerButton = .primary) {
            time += 0.01
            runtime.pointerDown(at: point, button: button, at: time)
            time += 0.01
            runtime.pointerUp(at: point, button: button, at: time)
            settle()
        }

        func node(_ role: ElementRole, _ label: String) throws -> AccessibilityNode {
            func match(_ node: AccessibilityNode) -> AccessibilityNode? {
                if node.role == role && node.label == label { return node }
                return node.children.lazy.compactMap(match).first
            }
            return try #require(match(runtime.accessibilitySnapshot()))
        }

        func key(_ key: Key) {
            #expect(menu.navigate(KeyEvent(key: key)))
            settle()
        }
    }

    @Test func secondaryPressShowsNestedPointerMenuAndOutsidePressDismissesWithoutClickThrough() throws {
        let window = documentWindow()
        let trigger = try #require(window.runtime.find("trigger"))
        window.click(trigger, button: .secondary)
        let panel = try window.node(.menu, "Context menu")
        #expect(panel.frame.left <= trigger.x && trigger.x <= panel.frame.right)
        #expect(panel.frame.top <= trigger.y && trigger.y <= panel.frame.bottom)

        let disabled = try window.node(.menuItem, "Paste")
        #expect(disabled.isDisabled)
        window.click(disabled.frame.center)
        #expect(window.menu.isOpen)
        #expect(window.runtime.state.picks.isEmpty)

        let share = try window.node(.menuItem, "Share")
        window.click(share.frame.center)
        let chat = try window.node(.menuItem, "Chat")
        window.click(chat.frame.center)
        #expect(window.runtime.state.picks == ["chat"])
        #expect(!window.runtime.hasPopup)

        window.click(trigger, button: .secondary)
        let background = try #require(window.runtime.find("document-action"))
        window.click(background)
        #expect(window.runtime.state.picks == ["chat", nil])
        #expect(window.runtime.state.bodyClicks == 0)
        window.click(background)
        #expect(window.runtime.state.bodyClicks == 1)
    }

    @Test func keyAnchorKeepsSelectionAndKeyboardTraversesOnlyEnabledRows() throws {
        let window = documentWindow()
        let picker = PopupMenu()
            .item("one", "One").item("two", "Two", checked: true)
            .submenu("Unavailable", PopupMenu().item("blocked", "Blocked"), enabled: false)
            .separator().submenu("Formats", PopupMenu().item("empty", "Empty", enabled: false).item("pdf", "PDF"))
            .selected("two")
        window.runtime.update { _, tx in tx.focus("trigger") }
        window.settle()
        let trigger = try window.node(.button, "Trigger")
        window.runtime.update { _, tx in
            tx.popupMenu(picker, at: "trigger") { (s: inout Document, pick, _) in s.picks.append(pick) }
        }
        window.settle()
        let selected = try window.node(.menuItemCheckbox, "Two")
        #expect(selected.toggled == .trueState)
        #expect(selected.isFocused)
        #expect(selected.frame.bottom >= trigger.frame.top && selected.frame.top <= trigger.frame.bottom)
        let panel = try window.node(.menu, "Context menu")
        #expect(panel.frame.width >= trigger.frame.width)
        window.key(.arrowDown)
        #expect(try window.node(.menuItem, "Formats").isFocused)
        window.key(.arrowRight)
        #expect(try window.node(.menuItem, "PDF").isFocused)
        window.key(.enter)
        #expect(window.runtime.state.picks == ["pdf"])
        #expect(window.runtime.focusedKey == "trigger")
    }

    @Test func secondaryClickSelectAllRestoresTheClickedEditor() throws {
        struct Editor {
            var first = TextEdit("keep")
            var second = TextEdit("café notes")
        }
        let window = Window(Editor()) {
            col().children([
                textInput(key: "first", \Editor.first).size(260, 40),
                textInput(key: "second", \Editor.second).size(260, 40),
            ])
        }
        window.runtime.update { _, tx in tx.focus("first") }
        window.settle()
        #expect(window.runtime.focusedKey == "first")
        let point = try #require(window.runtime.find("second"))
        window.click(point, button: .secondary)
        let select = try window.node(.menuItem, RuneLabels.shared.label(for: .selectAll))
        window.click(select.frame.center)
        #expect(!window.menu.isOpen)
        #expect(window.runtime.focusedKey == "second")
        #expect(window.runtime.state.second.selectedUTF8Range == 0..<"café notes".utf8.count)
        #expect(window.runtime.keyDown(KeyEvent(key: .text("!")), at: window.time))
        #expect(window.runtime.state.second.text == "!")
        #expect(window.runtime.state.first.text == "keep")
    }

    @Test func staleRowsCannotAnswerTheNextPopupAndClosingAWindowDismissesTheQueue() throws {
        let window = documentWindow()
        let choices = PopupMenu().item("pick", "Pick")
        window.runtime.update { _, tx in
            for prefix in ["first", "second", "third"] {
                tx.popupMenu(choices, at: Vec2(20, 20)) { (s: inout Document, pick, _) in
                    s.picks.append("\(prefix) \(pick ?? "cancelled")")
                }
            }
        }
        window.settle()
        let original = window.menu.generation
        window.key(.escape)
        #expect(window.runtime.state.picks == ["first cancelled"])
        #expect(window.menu.isOpen)
        #expect(window.menu.generation != original)

        window.menu.activate(level: 0, row: 0, generation: original)
        window.settle()
        #expect(window.runtime.state.picks == ["first cancelled"])
        window.menu.cancelAll(at: window.time)
        window.settle()
        #expect(window.runtime.state.picks == ["first cancelled", "second cancelled", "third cancelled"])
        #expect(!window.menu.isOpen)
        #expect(!window.runtime.hasPopup)
    }

    @Test func changingSubmenusInvalidatesAnActivationFromThePreviousBranch() throws {
        let window = documentWindow()
        let choices = PopupMenu()
            .submenu("Send", PopupMenu().item("mail", "Mail"))
            .submenu("Export", PopupMenu().item("pdf", "PDF").item("png", "PNG"))
        window.runtime.update { _, tx in
            tx.popupMenu(choices, at: Vec2(20, 20)) { (s: inout Document, pick, _) in s.picks.append(pick) }
        }
        window.settle()
        window.key(.home)
        window.key(.arrowRight)
        let previous = try #require(window.menu.levels.last?.token)
        #expect(try window.node(.menuItem, "Mail").isFocused)
        window.key(.arrowLeft)
        window.key(.arrowDown)
        window.key(.arrowRight)
        #expect(try window.node(.menuItem, "PDF").isFocused)

        let current = try #require(window.menu.levels.last?.token)
        window.menu.hover(level: 1, row: 1, generation: current)
        window.settle()
        #expect(try window.node(.menuItem, "PDF").isFocused)
        window.menu.pointerMoved()
        window.menu.hover(level: 1, row: 1, generation: previous)
        window.settle()
        #expect(try window.node(.menuItem, "PDF").isFocused)

        // A delayed press for row 0 of Send must not pick row 0 of Export.
        window.menu.activate(level: 1, row: 0, generation: previous)
        window.settle()
        #expect(window.runtime.state.picks.isEmpty)
        let png = try window.node(.menuItem, "PNG")
        window.runtime.pointerMove(to: png.frame.center, at: window.time)
        window.settle()
        #expect(try window.node(.menuItem, "PNG").isFocused)
        window.key(.enter)
        #expect(window.runtime.state.picks == ["png"])
    }
}

extension LinuxContextMenuTests {
    @Test func preservesAuthoredRootGeometryAndIntrinsicHeightThroughoutPopup() throws {
        let viewport = Vec2(260, 400)
        let body: El<Int> = col().key("root").child(el().key("field").size(90, 127))
        for fitsHeight in [false, true] {
            for root in [body.m(13), body.absolute(x: 17, y: 28).size(117, 165)] {
                let popup = LinuxContextMenu<Int>()
                let direct = Runtime(state: 0, viewport: viewport, pixelScale: 1.5) { _, _ in root }
                let hosted = Runtime(state: 0, viewport: viewport, pixelScale: 1.5) { _, cx in
                    popup.view(content: root, in: &cx, fitsContentHeight: fitsHeight)
                }
                popup.runtime = hosted
                hosted.fitHeight = fitsHeight
                direct.fitHeight = fitsHeight
                _ = direct.frame(at: 0)
                _ = hosted.frame(at: 0)
                let path = try #require(hosted.element(byKey: "field")?.path)
                let rootRect = try #require(direct.element(byKey: "root")?.rect)
                let fieldRect = try #require(direct.element(byKey: "field")?.rect)
                let intrinsic = direct.contentHeight()
                func checkGeometry() {
                    #expect(hosted.element(byKey: "root")?.rect == rootRect)
                    #expect(hosted.element(byKey: "field")?.rect == fieldRect)
                    #expect(hosted.element(byKey: "field")?.path == path)
                    #expect(hosted.contentHeight() == intrinsic)
                }
                checkGeometry()
                hosted.update(at: 0.01) { _, tx in
                    tx.popupMenu(PopupMenu().item("copy", "Copy"), at: "field") { (_: inout Int, _, _) in }
                }
                _ = hosted.frame(at: 0.02)
                popup.refresh(at: 0.03)
                _ = hosted.frame(at: 0.03)
                #expect(popup.isOpen)
                checkGeometry()
                popup.dismiss(generation: popup.generation)
                popup.refresh(at: 0.04)
                _ = hosted.frame(at: 0.04)
                #expect(!popup.isOpen)
                checkGeometry()
            }
        }
    }
}
#endif
