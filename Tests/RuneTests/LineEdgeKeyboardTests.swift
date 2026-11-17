import Testing
@testable import Rune

@Suite("Keyboard navigation to line and document edges")
struct LineEdgeKeyboardTests {
    @Test @MainActor func focusedWrappedFieldUsesItsDrawnLineEdges() {
        struct State { var edit = TextEdit("one two three four five six seven eight\nlast", multiline: true) }
        var initial = State()
        initial.edit.setCursor(utf8Offset: 0)
        let runtime = Runtime(state: initial, viewport: Vec2(88, 180), pixelScale: 2) { _, _ in
            textInput(key: "field", \State.edit).font(TextStyle(size: 16).lh(22))
                .size(88, 180).focused(true).placeholder("A long placeholder that wraps")
        }
        _ = runtime.frame(at: 0)
        let apple = KeyPlatform.current.isMac
        let lineEnd = apple ? Key.arrowRight : .end
        let lineStart = apple ? Key.arrowLeft : .home
        let lineMods = apple ? Mods(cmd: true, logo: true) : .none
        #expect(runtime.keyDown(KeyEvent(key: lineEnd, mods: lineMods), at: 0.01))
        let firstEnd = runtime.state.edit.cursor
        let lastParagraph = initial.edit.text.utf8.count - "last".utf8.count
        #expect(firstEnd > 0 && firstEnd < lastParagraph - 1)
        #expect(runtime.state.edit.caretAffinity == .upstream)

        var extending = lineMods
        extending.shift = true
        #expect(runtime.keyDown(KeyEvent(key: lineStart, mods: extending), at: 0.02))
        #expect(runtime.state.edit.cursor == 0 && runtime.state.edit.anchor == firstEnd)

        let documentMods = apple ? Mods.none : Mods(ctrl: true, cmd: true)
        #expect(runtime.keyDown(KeyEvent(key: .end, mods: documentMods), at: 0.03))
        #expect(runtime.state.edit.cursor == initial.edit.text.utf8.count)
        #expect(runtime.keyDown(KeyEvent(key: .home), at: 0.04))
        #expect(runtime.state.edit.cursor == (apple ? 0 : lastParagraph))
        #expect(runtime.keyDown(KeyEvent(key: .home, mods: documentMods), at: 0.05))
        #expect(runtime.state.edit.cursor == 0)

        runtime.update(at: 0.06) { state, _ in state.edit = TextEdit("", multiline: true) }
        _ = runtime.frame(at: 0.07)
        #expect(runtime.keyDown(KeyEvent(key: lineEnd, mods: extending), at: 0.08))
        #expect(runtime.state.edit.cursor == 0 && runtime.state.edit.anchor == 0)
    }

    @Test func noLayoutUsesHardLinesAndHiddenMultilineKeepsItsMask() {
        var edit = TextEdit("first\r\nlast", multiline: true)
        edit.setCursor(utf8Offset: 1)
        #expect(edit.handleKey(KeyEvent(key: .arrowRight, mods: Mods(cmd: true))) == .navigation)
        #expect(edit.cursor == 5)
        edit.setCursor(utf8Offset: 9)
        #expect(edit.handleKey(KeyEvent(key: .arrowLeft, mods: Mods(cmd: true))) == .navigation)
        #expect(edit.cursor == 7)

        edit.isSecure = true
        #expect(edit.handleKey(KeyEvent(key: .home, mods: Mods(shift: true))) == .navigation)
        #expect(edit.cursor == edit.text.utf8.count && edit.anchor == 0)
        #expect(edit.handleKey(KeyEvent(key: .end)) == .navigation)
        #expect(edit.cursor == edit.text.utf8.count && edit.anchor == edit.cursor)
    }
}
