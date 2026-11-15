import Foundation
import Testing
import RuneMotion
@testable import Rune

/// Ports of `crates/rune/src/runtime/tests/input_clipboard.rs` `:70` and `:130`.
@Suite("input_clipboard.rs parity A: single-line caret scroll, paste routing")
@MainActor
struct InputClipboardParityTests {

    static let style = TextStyle(size: 16, weight: 400)

    @Test("input_clipboard.rs:70 single_line_input_scrolls_to_the_caret_instead_of_wrapping")
    func singleLineInputScrollsToTheCaretInsteadOfWrapping() throws {
        let text = "a very long search query that keeps going past the edge"
        let rt = Runtime(state: TextEdit(text), viewport: Vec2(100, 24), pixelScale: 2.0) { _, _ in
            textInput(key: "search", \TextEdit.self).font(Self.style).singleLine().size(100, 24)
        }
        _ = rt.frame(at: 0.0)
        rt.update { _, tx in tx.focus("search") }
        _ = rt.frame(at: 0.0)

        let node = try #require(rt.flatNodes.first(where: { $0.key == "search" }))
        let path = node.path
        let pad = node.el.layout.padding
        let innerW = max(0, node.targetRect.width - pad.left - pad.right)
        let resolved = ElDisplayResolver.resolveInput(el: node.el, edit: rt.state, innerWidth: innerW)
        let shaped = rt.textSystem.shape(
            text: resolved.renderedString,
            spans: resolved.spans,
            pills: resolved.pills,
            style: resolved.style,
            maxWidth: resolved.maxWidthForShape,
            pixelScale: rt.pixelScale,
            emitGlyphs: false
        )
        #expect(shaped.lineCount == 1)
        let scroll = try #require(rt.inputScroll[path])
        #expect(scroll > 100.0, "the end of the text is in view: \(scroll)")
        let caretX = try #require(rt.imeArea)[0]
        #expect((0.0...100.0).contains(caretX), "caret \(caretX) stays inside the field")

        // A click lands on the scrolled text, not on the hidden start (`Action::Focus(path, 1, 12)`).
        let rect = node.targetRect
        let click = Vec2(rect.x + pad.left + 1.0, rect.y + pad.top + 12.0)
        rt.pointerDown(at: click, at: 0.0)
        rt.pointerUp(at: click, at: 0.0)
        _ = rt.frame(at: 0.0)
        #expect(rt.state.cursor > 10, "clicked index \(rt.state.cursor)")

        rt.update { _, tx in tx.blur() }
        _ = rt.frame(at: 0.0)
        #expect(rt.focusedPath == nil)
        #expect(rt.inputScroll[path] == nil, "unfocused fields rest at their start")
    }

    @Test("input_clipboard.rs:130 clipboard_paste_routes_to_window_or_field_and_discards_late_reads")
    func clipboardPasteRoutesToWindowOrFieldAndDiscardsLateReads() {
        struct S {
            var field = TextEdit("")
            var pasted = ""
        }
        let rt = Runtime(state: S(), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            col().size(200, 100)
                .onPaste { s, text, _ in s.pasted = text }
                .child(textInput(key: "field", \S.field).font(Self.style).size(200, 40))
        }
        _ = rt.frame(at: 0.0)
        #expect(rt.acceptsPaste)
        rt.paste("window fixture")
        _ = rt.frame(at: 0.0)
        #expect(rt.state.pasted == "window fixture")
        #expect(rt.events.contains("paste window"))
        #expect(!(rt.copyRequest ?? "").contains("window fixture"))

        rt.update { _, tx in tx.focus("field") }
        _ = rt.frame(at: 0.0)
        rt.pasteResult(target: nil, ClipboardContent("late window reply"))
        _ = rt.frame(at: 0.0)
        #expect(rt.state.field.text.isEmpty)
        #expect(rt.state.pasted == "window fixture")

        let target = rt.pasteTarget
        rt.pasteResult(target: target, ClipboardContent("field fixture"))
        _ = rt.frame(at: 0.0)
        #expect(rt.state.field.text == "field fixture")
        #expect(rt.events.contains("paste field"))
    }
}
