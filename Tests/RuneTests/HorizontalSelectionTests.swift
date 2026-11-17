import Testing
@testable import Rune

@Suite("Horizontal selection collapse")
struct HorizontalSelectionTests {
    #if canImport(CoreText) || os(Linux) || os(Windows)
    @Test(arguments: [false, true])
    @MainActor func mixedDirectionFieldCollapsesToTheDisplayedEndpoint(revealedPassword: Bool) {
        struct State {
            var edit = TextEdit("AאבB")
        }
        var state = State()
        state.edit.setSelectionRaw(anchor: 1, cursor: 3)
        let runtime = Runtime(state: state, viewport: Vec2(180, 40), pixelScale: 2) { _, _ in
            textInput(key: "field", \State.edit).secure(revealedPassword).revealed(revealedPassword)
                .size(180, 40).focused(true)
        }
        _ = runtime.frame(at: 0)
        #expect(runtime.keyDown(KeyEvent(key: .arrowLeft, mods: Mods(shift: true)), at: 0.05))
        #expect(runtime.state.edit.cursor == 5 && runtime.state.edit.anchor == 1)
        #expect(runtime.keyDown(KeyEvent(key: .arrowLeft), at: 0.1))
        #expect(runtime.state.edit.cursor == 5 && runtime.state.edit.anchor == 5)

        runtime.update { state, _ in state.edit.setSelectionRaw(anchor: 5, cursor: 1) }
        _ = runtime.frame(at: 0.2)
        #expect(runtime.keyDown(KeyEvent(key: .arrowRight), at: 0.3))
        #expect(runtime.state.edit.cursor == 1 && runtime.state.edit.anchor == 1)
        #expect(runtime.state.edit.caretAffinity == .downstream)
    }
    #endif

    @Test func selectionAcrossParagraphsUsesTheFocusedParagraphDirection() {
        var edit = TextEdit("AB\nאב", multiline: true)
        let system = TextSystem()
        var style = TextStyle()
        style.byParagraphStart = .ltr
        let layout = system.shape(text: edit.text, style: style, maxWidth: nil, pixelScale: 2, emitGlyphs: false)
        for (anchor, focus, key, expected) in [(1, 5, Key.arrowLeft, 5), (1, 5, .arrowRight, 1),
                                              (5, 1, .arrowLeft, 1), (5, 1, .arrowRight, 5)] {
            edit.setSelectionRaw(anchor: anchor, cursor: focus)
            #expect(edit.handleKey(KeyEvent(key: key), layout: layout, textSystem: system, pixelScale: 2) == .navigation)
            #expect(edit.cursor == expected && edit.anchor == expected)
        }
    }

    @Test func concealedFieldsAndUnshapedTextUseLogicalEndpoints() {
        var edit = TextEdit("אבג")
        let system = TextSystem()
        let layout = system.shape(text: edit.text, style: TextStyle(), maxWidth: nil, pixelScale: 2, emitGlyphs: false)
        for secure in [false, true] {
            edit.isSecure = secure
            for (key, expected) in [(Key.arrowLeft, 2), (.arrowRight, 6)] {
                edit.setSelectionRaw(anchor: 6, cursor: 2)
                #expect(edit.handleKey(KeyEvent(key: key), layout: secure ? layout : nil,
                                       textSystem: system, pixelScale: 2) == .navigation)
                #expect(edit.anchor == expected && edit.cursor == expected)
            }
        }
    }
}
