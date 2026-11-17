import Testing
@testable import Rune

@Suite("Desktop editor word shortcuts")
struct DesktopWordKeyTests {
    @Test func nativeWordKeysMoveSelectDeleteAndUndo() {
        let apple = KeyPlatform.current == .mac
        let modifiers = apple ? [Mods(alt: true)] : [Mods(ctrl: true), Mods(ctrl: true, cmd: true)]
        for mods in modifiers {
            var edit = TextEdit("one café three")
            edit.setCursor(utf8Offset: 0)
            #expect(edit.handleKey(KeyEvent(key: .arrowRight, mods: mods)) == .navigation)
            #expect(edit.cursor == (apple ? 3 : 4))

            var extend = mods
            extend.shift = true
            #expect(edit.handleKey(KeyEvent(key: .arrowRight, mods: extend)) == .navigation)
            #expect(edit.selectedUTF8Range == (apple ? 3..<9 : 4..<10))
            #expect(edit.handleKey(KeyEvent(key: .backspace, mods: mods)) == .modified)
            #expect(edit.text == "one three")
            let restored = edit.undo()
            #expect(restored)
            #expect(edit.text == "one café three")

            edit.setCursor(utf8Offset: edit.text.utf8.count)
            #expect(edit.handleKey(KeyEvent(key: .arrowLeft, mods: mods)) == .navigation)
            #expect(edit.cursor == 10)
            #expect(edit.handleKey(KeyEvent(key: .backspace, mods: mods)) == .modified)
            #expect(edit.text == "one three")

            edit = TextEdit("one café three")
            edit.setCursor(utf8Offset: 4)
            #expect(edit.handleKey(KeyEvent(key: .delete, mods: mods)) == .modified)
            #expect(edit.text == (apple ? "one  three" : "one three"))
        }
    }

    @Test func commandWithoutPhysicalControlMovesToLineStart() {
        var edit = TextEdit("before\none café three\nafter", multiline: true)
        edit.setCursor(utf8Offset: 16)
        let command = Mods(cmd: true, logo: KeyPlatform.current == .mac)
        #expect(edit.handleKey(KeyEvent(key: .arrowLeft, mods: command)) == .navigation)
        #expect(edit.cursor == 7)
    }

    @Test @MainActor func focusedFieldReceivesNativeWordShortcuts() {
        struct State { var field = TextEdit("one café three") }
        let runtime = Runtime(state: State(), viewport: .init(240, 44)) { _, _ in
            textInput(key: "field", \State.field).size(240, 44)
        }
        _ = runtime.frame(at: 0)
        runtime.update { state, tx in
            tx.focus("field")
            state.field.setCursor(utf8Offset: 0)
        }
        _ = runtime.frame(at: 0.1)
        let apple = KeyPlatform.current == .mac
        let mods = Mods(shift: true, ctrl: !apple, alt: apple)
        #expect(runtime.keyDown(KeyEvent(key: .arrowRight, mods: mods), at: 0.2))
        #expect(runtime.state.field.selectedText == (apple ? "one" : "one "))
        #expect(runtime.keyDown(KeyEvent(key: .backspace), at: 0.3))
        #expect(runtime.state.field.text == (apple ? " café three" : "café three"))
    }
}
