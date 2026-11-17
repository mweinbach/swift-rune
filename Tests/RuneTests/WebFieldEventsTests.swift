import Foundation
import Testing
@testable import Rune

@Suite @MainActor
struct WebFieldEventsTests {
    private struct Form {
        var edit: TextEdit
        var rejected = false
        var changeCount = 0
    }

    private func host(_ edit: TextEdit, secure: Bool = false, locked: Bool = false) -> WebAppHost<Form> {
        let app = AppSpec<Form>(title: "Browser editor", size: Vec2(160, 45), state: Form(edit: edit)) { _, _ in
            textInput(key: "draft", \.edit).w(150).h(40).secure(secure).singleLine().withoutEditAccess(locked)
                .onInputChange { state, _, _ in
                    state.changeCount += 1
                    return state.rejected
                }
        }
        let host = WebAppHost(spec: app)
        _ = host.runtime.frame(at: 0)
        _ = host.runtime.accessibilityAction("draft", .press, at: 0.1)
        host.syncField(activate: true)
        return host
    }

    @Test func keyboardShortcutMountsAndActivatesTheFieldDuringTheDOMEvent() throws {
        struct State {
            var open = false
            var draft = TextEdit("prompt")
        }
        var app = AppSpec<State>(title: "Prompt", size: Vec2(200, 50), state: State()) { state, _ in
            state.open ? textInput(key: "prompt", \.draft).label("Search messages").size(180, 40) : el()
        }
        app.onKey = { state, event, tx in
            guard event.key == .command("k") else { return false }
            state.open = true
            tx.focusWhenShown("prompt", ring: true)
            return true
        }
        let host = WebAppHost(spec: app)
        let browser = WebBrowserSession(host)
        _ = try browser.frame(at: 0)
        let shortcut = Data(#"{"kind":"key","key":"k","code":"KeyK","cmd":true}"#.utf8)
        #expect(browser.send(shortcut, at: 0.1))
        let data = try #require(browser.takeField())
        let update = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let field = try #require(update["field"] as? [String: Any])
        #expect(update["activate"] as? Bool == true)
        #expect(field["text"] as? String == "prompt")
        #expect(field["label"] as? String == "Search messages")
    }

    @Test func changedScalarsGoThroughUndoAndChangeCallbacks() throws {
        var edit = TextEdit("a🦀c").rich()
        edit.setSelectionRaw(anchor: 5, cursor: 6)
        edit.setMark(.bold)
        let host = host(edit)
        let mirror = try #require(host.fieldMirror)
        #expect(host.handleFieldEdit(key: mirror.key, base: 0, expected: "a🦀c", text: "aéc", anchor: 2, focus: 2, at: 1))
        #expect(host.runtime.state.edit.text == "aéc")
        #expect(host.runtime.state.edit.cursor == 3)
        #expect(host.runtime.state.edit.richMarks == [RichMarkRange(3..<4, .bold)])
        #expect(host.runtime.state.changeCount == 1)
        #expect(!host.handleFieldEdit(key: mirror.key, base: 0, expected: "a🦀c", text: "axc", anchor: 2, focus: 2, at: 1))
        #expect(host.runtime.state.changeCount == 1)
        let undone = host.runtime.state.edit.undo()
        #expect(undone && host.runtime.state.edit.text == "a🦀c")
    }

    @Test func selectionStaysInTheMirroredWindowAndRespectsScalarBoundaries() throws {
        let prefix = String(repeating: "x", count: 4000)
        var edit = TextEdit(prefix + "a🦀z")
        edit.setSelectionRaw(anchor: edit.text.utf8.count, cursor: edit.text.utf8.count)
        let host = host(edit)
        let mirror = try #require(host.fieldMirror)
        #expect(mirror.base > 0)
        let end = mirror.text.utf16.count
        #expect(host.handleFieldSelection(key: mirror.key, base: mirror.base, expected: mirror.text, anchor: end - 1, focus: end - 3, at: 1))
        #expect(host.runtime.state.edit.anchor == prefix.utf8.count + 5)
        #expect(host.runtime.state.edit.cursor == prefix.utf8.count + 1)
        let moved = try #require(host.fieldMirror)
        let middle = moved.text.utf16.count - 2
        for invalid in [middle, -1, Int.max] {
            #expect(!host.handleFieldSelection(key: moved.key, base: moved.base, expected: moved.text, anchor: invalid, focus: 0, at: 2))
        }
        #expect(!host.handleFieldSelection(key: moved.key, base: moved.base + 1, expected: moved.text, anchor: 0, focus: 0, at: 2))
        #expect(!host.handleFieldSelection(key: "other", base: moved.base, expected: moved.text, anchor: 0, focus: 0, at: 2))
        #expect(host.runtime.state.changeCount == 0)
    }

    @Test func rejectedAndExternallyChangedDraftsKeepTheirModelValue() throws {
        let host = host(TextEdit("old"))
        let mirror = try #require(host.fieldMirror)
        host.runtime.state.rejected = true
        #expect(!host.handleFieldEdit(key: mirror.key, base: 0, expected: "old", text: "new", anchor: 3, focus: 3, at: 1))
        #expect(host.runtime.state.edit.text == "old")
        #expect(host.runtime.state.changeCount == 1)
        host.runtime.state.edit.replaceText("newer")
        #expect(!host.handleFieldEdit(key: mirror.key, base: 0, expected: "old", text: "stale", anchor: 5, focus: 5, at: 2))
        #expect(host.runtime.state.changeCount == 1)
        #expect(host.fieldMirror?.text == "newer")
    }

    @Test func secureAndLockedEditorsDoNotExposeAWindow() throws {
        let secret = host(TextEdit(""), secure: true)
        let mirror = try #require(secret.fieldMirror)
        #expect(mirror.secure && mirror.text.isEmpty)
        #expect(secret.handleSecureFieldInsert(key: mirror.key, text: "🦀", at: 1))
        #expect(secret.runtime.state.edit.text == "🦀")
        #expect(secret.fieldMirror?.text == "")
        #expect(!secret.handleFieldEdit(key: mirror.key, base: 0, expected: "", text: "visible", anchor: 7, focus: 7, at: 2))
        let locked = host(TextEdit("private"), locked: true)
        #expect(locked.fieldMirror == nil)
        #expect(!locked.handleFieldEdit(key: "draft", base: 0, expected: "private", text: "changed", anchor: 0, focus: 0, at: 2))
        #expect(!locked.handleSecureFieldInsert(key: "draft", text: "changed", at: 2))
        #expect(locked.runtime.state.edit.text == "private")
    }
}
