import Foundation
import Testing
@testable import Rune

@Suite @MainActor
struct WebClipboardTests {
    private struct Form {
        var edit: TextEdit
        var observed: String?
    }

    private func form(_ edit: TextEdit, secure: Bool = false) -> WebAppHost<Form> {
        let spec = AppSpec<Form>(title: "Clipboard", size: Vec2(200, 50), state: Form(edit: edit)) { _, _ in
            textInput(key: "entry", \.edit).w(150).h(45).secure(secure)
        }
        let host = WebAppHost(spec: spec)
        _ = host.runtime.frame(at: 0)
        _ = host.runtime.accessibilityAction("entry", .press, at: 0.01)
        host.syncField(activate: true)
        return host
    }

    private func requests(_ bytes: Data?) throws -> [[String: Any]] {
        let data = try #require(bytes)
        let json = try JSONSerialization.jsonObject(with: data)
        return try #require(json as? [[String: Any]])
    }

    @Test func cutOnlyMutatesAfterTheBrowserAcceptsTheCopy() throws {
        let host = form(TextEdit("Rune 🦦"))
        host.runtime.state.edit.selectAll()
        let clipboard = WebClipboardSession(host)
        #expect(!clipboard.finishCut(at: 0.02))
        #expect(clipboard.copySelection(forCut: true))
        _ = clipboard.takeRequests()
        clipboard.cancelCut()
        #expect(!clipboard.finishCut(at: 0.03))
        #expect(clipboard.copySelection(forCut: true))
        let copy = try #require(try requests(clipboard.takeRequests()).first)
        #expect(copy["operation"] as? String == "selection")
        #expect((copy["content"] as? [String: Any])?["text"] as? String == "Rune 🦦")
        #expect(host.runtime.state.edit.text == "Rune 🦦")
        #expect(clipboard.finishCut(at: 1))
        #expect(host.runtime.state.edit.text.isEmpty)
        #expect(clipboard.takeRequests() == nil)
    }

    @Test func secureCopyAndCutDoNotReleaseOrDeleteSelectedText() throws {
        let host = form(TextEdit("private"), secure: true)
        host.runtime.state.edit.selectAll()
        let clipboard = WebClipboardSession(host)
        #expect(!clipboard.copySelection(forCut: false))
        #expect(!clipboard.copySelection(forCut: true))
        #expect(!clipboard.finishCut(at: 1))
        #expect(clipboard.takeRequests() == nil)
        #expect(host.runtime.state.edit.text == "private")
        #expect(clipboard.paste(WebClipboardContent(ClipboardContent("replacement")), at: 2))
        #expect(host.runtime.state.edit.text == "replacement")
        #expect(host.fieldMirror?.text == "")
    }

    @Test func asyncPasteChecksItsOriginalFieldAndRefusedReadsAnswerOnce() throws {
        let host = form(TextEdit("before"))
        let clipboard = WebClipboardSession(host)
        let rt = host.runtime
        rt.clipboard = ClipboardContent("stale")
        var tx = Tx()
        tx.requestPaste()
        tx.readClipboard { (state: inout Form, content, _) in state.observed = content.text }
        rt.latchClipboardRequests(tx)
        let ops = try requests(clipboard.takeRequests())
        #expect(ops.count == 2)
        let paste = try #require(ops[0]["id"] as? String)
        let read = try #require(ops[1]["id"] as? String)
        rt.focusedPath = nil
        #expect(clipboard.finishRead(paste, value: WebClipboardContent(ClipboardContent("wrong target"))))
        #expect(clipboard.finishRead(read, value: nil))
        #expect(!clipboard.finishRead(read, value: WebClipboardContent(ClipboardContent("duplicate"))))
        _ = rt.frame(at: 2)
        #expect(rt.state.edit.text == "before")
        #expect(rt.state.observed == "")
    }
}
