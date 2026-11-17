import Testing
@testable import Rune

@Suite("Mounted text field line modes")
@MainActor
struct BoundTextEditLineModeTests {
    private struct Form {
        var edit: TextEdit
        var singleLine: Bool?
        var pasteSawMultipleLines: Bool?
    }

    private func runtime(_ value: TextEdit, singleLine: Bool? = nil) -> Runtime<Form> {
        let runtime = Runtime(state: Form(edit: value, singleLine: singleLine), viewport: Vec2(300, 180)) { state, _ in
            var field = textInput(key: "editor", \Form.edit).w(260).h(120)
            if let choice = state.singleLine { field = field.singleLine(choice) }
            return field.onInputPaste { state, _, _ in
                state.pasteSawMultipleLines = state.edit.multiline
                return false
            }
        }
        _ = runtime.frame(at: 0)
        runtime.update { _, tx in tx.focus("editor") }
        _ = runtime.frame(at: 0.01)
        return runtime
    }

    @Test func defaultFieldPreservesTheLoadedDocumentAndSubsequentParagraphs() throws {
        let runtime = runtime(TextEdit("first\nsecond"))
        #expect(runtime.state.edit.text == "first\nsecond")
        #expect(runtime.state.edit.blocks.count == 2)
        runtime.paste("\nthird")
        _ = runtime.frame(at: 0.02)
        #expect(runtime.state.edit.text == "first\nsecond\nthird")
        #expect(runtime.state.pasteSawMultipleLines == true)
        #expect(runtime.dispatchImeEvent(.commit("\nfourth"), at: 0.03))
        #expect(runtime.state.edit.text == "first\nsecond\nthird\nfourth")
    }

    @Test func aFieldOverrideAppliesBeforeThePasteHookAndCanChangeWhileFocused() {
        let runtime = runtime(TextEdit("title", multiline: true), singleLine: true)
        runtime.paste("\none")
        _ = runtime.frame(at: 0.02)
        #expect(runtime.state.pasteSawMultipleLines == false)
        #expect(runtime.state.edit.text == "titleone")
        runtime.update { state, _ in state.singleLine = false }
        _ = runtime.frame(at: 0.03)
        runtime.paste("\ntwo")
        _ = runtime.frame(at: 0.04)
        #expect(runtime.state.pasteSawMultipleLines == true)
        #expect(runtime.state.edit.text == "titleone\ntwo")
    }

    @Test func theDefaultFieldRespectsAnExplicitSingleLineModel() {
        let runtime = runtime(TextEdit("title", multiline: false))
        #expect(runtime.accessibilityAction("editor", .setValue, value: .text("one\ntwo"), at: 0.02))
        _ = runtime.frame(at: 0.03)
        #expect(!runtime.state.edit.text.contains("\n"))
        #expect(runtime.state.edit.multiline == false)
    }
}
