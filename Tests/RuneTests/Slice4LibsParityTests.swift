import Testing
@testable import Rune

@Suite("Slice 4 Libs Parity Tests (on_key_tests & input_clipboard)")
struct Slice4LibsParityTests {

    @Test("on_key_tests.rs:67: keyed control takes its keys before focus navigation innermost-first")
    func keyedControlTakesKeysBeforeFocusNavigationInnermostFirst() throws {
        struct KeysState {
            var log: [String] = []
            var field = TextEdit("", multiline: false)
            var outerDown = false
        }

        let rt = Runtime(state: KeysState(), viewport: Vec2(300, 200), pixelScale: 1.0) { _, _ in
            let rows: El<KeysState> = col()
                .key("rows")
                .role(.listbox)
                .focusGroup()
                .children((0..<3).map { i in
                    row()
                        .key("row\(i)")
                        .size(100, 20)
                        .focusable(true)
                        .onClick { s in s.log.append("press \(i)") }
                })

            let list: El<KeysState> = col()
                .key("list")
                .role(.tree)
                .focusable(true)
                .size(120, 80)
                .onKey { s, ev, _ in
                    switch ev.key {
                    case .arrowDown:
                        s.log.append("list Down")
                        return true
                    case .arrowUp:
                        s.log.append("list Up")
                        return true
                    default:
                        return false
                    }
                }
                .child(rows)

            let outer: El<KeysState> = col()
                .key("outer")
                .onKey { s, ev, _ in
                    switch ev.key {
                    case .arrowDown where s.outerDown:
                        s.log.append("outer Down")
                        return true
                    case .arrowLeft:
                        s.log.append("outer Left")
                        return true
                    default:
                        return false
                    }
                }
                .child(list)
                .child(textInput(key: "field", \KeysState.field).size(200, 30))

            return col()
                .size(300, 200)
                .child(el().key("pad").size(300, 10))
                .child(outer)
        }

        rt.cxSettings.fullKeyboardAccess = false
        _ = rt.frame(at: 0.0)

        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.01)
        _ = rt.frame(at: 0.01)
        #expect(rt.focusedKey == "list", "Tab reaches a control that owns its keys, without Full Keyboard Access")

        rt.state.outerDown = true
        _ = rt.keyDown(KeyEvent(key: .arrowDown), at: 0.02)
        _ = rt.frame(at: 0.02)
        _ = rt.keyDown(KeyEvent(key: .arrowLeft), at: 0.03)
        _ = rt.frame(at: 0.03)

        #expect(rt.state.log == ["list Down", "outer Left"])
        #expect(rt.focusedKey == "list", "focus navigation never saw the arrow")
    }

    @Test("input_clipboard.rs:380: clipboard requests follow handler order and are consumed once")
    func clipboardRequestsFollowHandlerOrderAndAreConsumedOnce() throws {
        var initialEdit = TextEdit("héllo 👋", multiline: false)
        initialEdit.selectAll()

        let rt = Runtime(state: initialEdit, viewport: Vec2(300, 200), pixelScale: 2.0) { _, _ in
            col()
                .child(
                    el()
                        .key("copy")
                        .size(40, 28)
                        .preserveFocusOnPress()
                        .onClick { _, tx in tx.copyText("response") }
                )
                .child(textInput(key: "input", \TextEdit.self).size(200, 30))
        }

        _ = rt.frame(at: 0.0)
        rt.update(at: 0.005) { _, tx in
            tx.focus("input")
        }
        _ = rt.frame(at: 0.01)
        #expect(rt.focusedKey == "input")

        let copyRect = try #require(rt.element(byKey: "copy")).rect
        let copyCenter = Vec2(copyRect[0] + copyRect[2] * 0.5, copyRect[1] + copyRect[3] * 0.5)
        let copyKey = KeyEvent(key: .command("c"), mods: Mods(cmd: true))

        // Order 1: press ("response") then Cmd+C ("héllo 👋") -> Cmd+C wins; consumed once.
        rt.pointerDown(at: copyCenter, at: 0.02)
        rt.pointerUp(at: copyCenter, at: 0.021)
        _ = rt.keyDown(copyKey, at: 0.022)
        _ = rt.frame(at: 1.0 / 120.0 + 0.022)
        #expect(rt.focusedKey == "input")
        #expect(rt.takeCopyRequest() == "héllo 👋")
        #expect(rt.copyRequest == nil)
        _ = rt.frame(at: 2.0 / 120.0 + 0.022)
        #expect(rt.copyRequest == nil)
        #expect(rt.takeCopyRequest() == nil)

        // Order 2: Cmd+C ("héllo 👋") then press ("response") -> button tx.copyText wins; consumed once.
        _ = rt.keyDown(copyKey, at: 0.05)
        rt.pointerDown(at: copyCenter, at: 0.051)
        rt.pointerUp(at: copyCenter, at: 0.052)
        _ = rt.frame(at: 1.0 / 120.0 + 0.052)
        #expect(rt.takeCopyRequest() == "response")
        #expect(rt.copyRequest == nil)
        _ = rt.frame(at: 2.0 / 120.0 + 0.052)
        #expect(rt.copyRequest == nil)

        // Paste never populates `copyRequest`.
        rt.update(at: 0.08) { _, tx in
            tx.requestPaste()
        }
        _ = rt.frame(at: 0.09)
        #expect(rt.copyRequest == nil)
    }
}
