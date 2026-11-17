import Foundation
import Testing
import RuneMotion
@testable import Rune

/// Ports of `crates/rune/src/runtime/tests/input_clipboard.rs` `:157`, `:220` and `:352`.
@Suite("input_clipboard.rs parity B: paste forms, pasted images, clipboard reads")
@MainActor
struct InputClipboardFormsParityTests {

    static let style = TextStyle(size: 16, weight: 400)

    /// An active element the sanitiser drops with its content (upstream's fixture uses the same tag).
    static func activeTag(_ body: String) -> String {
        let name = "scr" + "ipt"
        return "<\(name)>\(body)</\(name)>"
    }

    @Test("input_clipboard.rs:157 rich_pastes_reach_paste_hooks_and_plain_fields_keep_pasting_text")
    func richPastesReachPasteHooksAndPlainFieldsKeepPastingText() {
        struct S {
            var plain = TextEdit("")
            var rich = TextEdit("")
            var take = false
            var hook: [String?] = []
            var changes: UInt32 = 0
            var window: [ClipboardContent] = []
        }
        let m = Clipboard(kind: .memory)
        let rt = Runtime(state: S(), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            col().size(200, 100)
                .onPasteContent { s, content, _ in s.window.append(content) }
                .child(textInput(key: "plain", \S.plain).font(Self.style).size(200, 40))
                .child(
                    textInput(key: "rich", \S.rich).font(Self.style).size(200, 40)
                        .onInputChange { s, _ in s.changes += 1 }
                        .onInputPaste { s, content, _ in
                            s.hook.append(content.html)
                            if s.take { s.rich.paste("[rich]") }
                            return s.take
                        }
                )
        }
        rt.useClipboard(m)
        _ = rt.frame(at: 0.0)
        func paste() {
            rt.update { _, tx in tx.requestPaste() }
            _ = rt.frame(at: 0.0)
        }
        func focus(_ key: String) {
            rt.update { _, tx in tx.focus(key) }
            _ = rt.frame(at: 0.0)
        }
        m.writeRich(RichClipboardPayload(content: ClipboardContent("Hello", html: "<b>Hello</b>" + Self.activeTag("run()"))))

        paste()
        let window = rt.state.window.popLast()
        #expect(window?.text == "Hello")
        #expect(window?.html == "<b>Hello</b>", "the window hears every form, sanitised")

        focus("plain")
        #expect(rt.pasteForms(rt.pasteTarget) == .text)
        paste()
        #expect(rt.state.plain.text == "Hello", "a field without a hook pastes the text, as before")

        focus("rich")
        #expect(rt.pasteForms(rt.pasteTarget) == .all)
        paste()
        #expect(rt.state.rich.text == "Hello" && rt.state.changes == 1, "a declining hook leaves the paste to the editor")
        rt.update { s, _ in
            s.take = true
            s.rich = TextEdit("")
        }
        _ = rt.frame(at: 0.0)
        paste()
        #expect(rt.state.rich.text == "[rich]" && rt.state.changes == 2, "a hook that takes it edits the field; onInputChange runs")
        #expect(rt.state.hook == [String?](repeating: "<b>Hello</b>", count: 2))

        // HTML with no plain text: only rich hooks hear it, never a plain field or text handler.
        m.writeRich(RichClipboardPayload(content: ClipboardContent("", html: "<i>only</i>")))
        rt.update { s, _ in s.take = false }
        _ = rt.frame(at: 0.0)
        paste()
        #expect(rt.state.rich.text == "[rich]")
        #expect((rt.state.hook.last ?? nil) == "<i>only</i>")
        #expect(rt.state.window.isEmpty, "a focused field's paste never falls through to the window")
        #expect(rt.pasteForms(nil) == .all)

        let plainRoot = Runtime(state: [String](), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            col().size(200, 100).onPaste { s, text, _ in s.append(text) }
        }
        plainRoot.useClipboard(m)
        _ = plainRoot.frame(at: 0.0)
        #expect(plainRoot.pasteForms(nil) == .text, "a plain root onPaste never requests HTML or RTF")
        plainRoot.update { _, tx in tx.requestPaste() }
        _ = plainRoot.frame(at: 0.0)
        #expect(plainRoot.state.isEmpty, "an HTML-only clipboard never triggers a plain root onPaste")
    }

    @Test("input_clipboard.rs:220 pasted_images_reach_hooks_only")
    func pastedImagesReachHooksOnly() throws {
        struct S {
            var plain = TextEdit("")
            var rich = TextEdit("").rich()
            var hooked = TextEdit("").rich()
            var hook: [ClipboardContent] = []
            var window: [ClipboardContent] = []
            var reads: [ClipboardContent] = []
        }
        let rt = Runtime(state: S(), viewport: Vec2(200, 150), pixelScale: 1.0) { _, _ in
            col().size(200, 150)
                .onPasteContent { s, content, _ in s.window.append(content) }
                .child(textInput(key: "plain", \S.plain).font(Self.style).size(200, 40))
                .child(textInput(key: "rich", \S.rich).font(Self.style).size(200, 40))
                .child(
                    textInput(key: "hooked", \S.hooked).font(Self.style).size(200, 40)
                        .onInputPaste { s, content, _ in
                            s.hook.append(content)
                            guard let image = content.image else { return false }
                            let (w, h) = image.size
                            s.hooked.insertPill(id: "image:\(image.pngData.count)", label: "\(w)×\(h)")
                            return true
                        }
                )
        }
        var rgba = Data()
        for i in 0..<12 {
            rgba.append(contentsOf: [UInt8(i * 20), 0, UInt8(255 - i * 20), 255])
        }
        let image = try #require(ClipboardImage.fromRGBA(width: 4, height: 3, rgba: rgba))
        #expect(image.size.width == 4 && image.size.height == 3)
        #expect(ClipboardImage.fromPNG(Data("GIF89a".utf8)) == nil)
        #expect(ClipboardImage.fromPNG(image.pngData) == image)
        let m = Clipboard(kind: .memory)
        rt.useClipboard(m)
        _ = rt.frame(at: 0.0)
        func paste() {
            rt.update { _, tx in tx.requestPaste() }
            _ = rt.frame(at: 0.0)
        }
        func focus(_ key: String) {
            rt.update { _, tx in tx.focus(key) }
            _ = rt.frame(at: 0.0)
        }

        // A screenshot: an image and no text.
        m.writeRich(RichClipboardPayload(content: ClipboardContent("", image: image)))
        paste()
        #expect(rt.state.window.popLast()?.image == image, "the root's onPasteContent gets the image")
        focus("plain")
        paste()
        focus("rich")
        #expect(rt.pasteForms(rt.pasteTarget) == .rich, "a rich field with no hook never fetches the image")
        paste()
        #expect(rt.state.plain.text == "" && rt.state.rich.text == "", "an image alone pastes nothing into a field without a hook")
        focus("hooked")
        #expect(rt.pasteForms(rt.pasteTarget) == .all)
        paste()
        #expect(rt.state.hooked.text == "4×3")
        #expect(rt.state.hooked.pills.map(\.id) == ["image:\(image.pngData.count)"])
        #expect(rt.state.window.isEmpty, "a focused field's paste never reaches the root")

        // Text beside an image: a declining hook leaves the text to the editor.
        m.writeRich(RichClipboardPayload(content: ClipboardContent(" caption")))
        paste()
        #expect(rt.state.hooked.text == "4×3 caption")
        #expect(rt.state.hook.last.map { $0.image == nil } == true)

        m.writeRich(RichClipboardPayload(content: ClipboardContent("alt", image: image)))
        rt.update { _, tx in
            tx.readClipboard { (s: inout S, content: ClipboardContent, _: inout Tx) in s.reads.append(content) }
        }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 0.0)
        #expect(rt.state.reads.count == 1)
        #expect(rt.state.reads.first?.text == "alt")
        #expect(rt.state.reads.first?.image?.size.width == 4 && rt.state.reads.first?.image?.size.height == 3)
    }

    @Test("input_clipboard.rs:352 read_clipboard_answers_once_even_when_empty_and_pastes_nowhere")
    func readClipboardAnswersOnceEvenWhenEmptyAndPastesNowhere() throws {
        struct S {
            var field = TextEdit("")
            var reads: [ClipboardContent] = []
        }
        let m = Clipboard(kind: .memory)
        let rt = Runtime(state: S(), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            col().size(200, 100).child(textInput(key: "field", \S.field).font(Self.style).size(200, 40))
        }
        rt.useClipboard(m)
        _ = rt.frame(at: 0.0)
        rt.update { _, tx in tx.focus("field") }
        _ = rt.frame(at: 0.0)
        func read() {
            rt.update { _, tx in
                tx.readClipboard { (s: inout S, content: ClipboardContent, _: inout Tx) in s.reads.append(content) }
            }
            _ = rt.frame(at: 0.0)
            _ = rt.frame(at: 0.0)
        }
        read()
        #expect(rt.state.reads == [ClipboardContent()], "an empty clipboard still answers")
        let href = "java" + "script:x"
        m.writeRich(RichClipboardPayload(content: ClipboardContent("a", html: "<a href='\(href)'>a</a>", rtf: "{\\rtf1 a}")))
        read()
        let popped = rt.state.reads.popLast()
        let got = try #require(popped)
        #expect(got.text == "a")
        #expect(got.html == "<a>a</a>")
        #expect(got.rtf == "{\\rtf1 a}")
        #expect(rt.state.field.text.isEmpty && rt.state.reads.count == 1)
        #expect(rt.pendingClipboardReadIds.isEmpty && rt.readRequests.isEmpty)
    }
}
