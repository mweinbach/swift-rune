import Foundation
import Testing
import RuneMotion
@testable import Rune

/// Clipboard routing ports beyond the `input_clipboard.rs` rows: files and images round-trip
/// (`input_clipboard.rs:285`), own pill copies (`edit/rich_tests.rs:908`), a cleared clipboard
/// (`clipboard.rs` `Board::clear`, `Purpose::reply`), a paste command on an empty clipboard
/// (`physical.rs:163-167`) and `Tx::copy_secret` (`clipboard/tx.rs:40`).
@Suite("input_clipboard.rs parity C: files, own pills, cleared clipboard, paste command, concealed copy")
@MainActor
struct InputClipboardRoutingParityTests {

    static let style = TextStyle(size: 16, weight: 400)
    static let cmdV = KeyEvent(key: .command("v"), mods: Mods(cmd: true))

    @Test("input_clipboard.rs:285 copied_images_and_files_round_trip_and_reach_only_hooks")
    func copiedImagesAndFilesRoundTripAndReachOnlyHooks() throws {
        struct S {
            var field = TextEdit("")
            var rich = TextEdit("").rich()
            var reads: [ClipboardContent] = []
        }
        var rgba = Data()
        for i in 0..<4 { rgba.append(contentsOf: [UInt8(i * 60), 0, 0, 255]) }
        let image = try #require(ClipboardImage.fromRGBA(width: 2, height: 2, rgba: rgba))
        let files = [URL(fileURLWithPath: "/fixtures/a.txt"), URL(fileURLWithPath: "/fixtures/b c.png")]
        let onlyFiles = ClipboardContent(files: files)
        #expect(onlyFiles.isRich && !onlyFiles.isEmpty && !onlyFiles.hasPlain)
        #expect(onlyFiles.files == files)
        #expect(onlyFiles != ClipboardContent(), "files take part in equality")
        #expect(!String(describing: onlyFiles).contains("fixtures"))

        let m = Clipboard(kind: .memory)
        let rt = Runtime(state: S(), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            col().size(200, 100)
                .child(textInput(key: "field", \S.field).font(Self.style).size(200, 40))
                .child(textInput(key: "rich", \S.rich).font(Self.style).size(200, 40))
        }
        rt.useClipboard(m)
        _ = rt.frame(at: 0.0)
        let copied = ClipboardContent("two files", image: image, files: files)
        rt.update { _, tx in tx.copyRich(RichClipboardPayload(content: copied)) }
        #expect(m.readRich(sanitizeUntrustedHTML: false).content == copied, "the memory clipboard keeps every form")
        rt.update { _, tx in
            tx.readClipboard { (s: inout S, content: ClipboardContent, _: inout Tx) in s.reads.append(content) }
        }
        _ = rt.frame(at: 0.0)
        #expect(rt.state.reads.last == copied, "a read gets the image and files back")

        rt.update { _, tx in tx.copyRich(RichClipboardPayload(content: onlyFiles)) }
        for key in ["field", "rich"] {
            rt.update { _, tx in tx.focus(key) }
            _ = rt.frame(at: 0.0)
            rt.update { _, tx in tx.requestPaste() }
            _ = rt.frame(at: 0.0)
        }
        #expect(rt.state.field.text == "" && rt.state.rich.text == "", "files alone paste nothing into a field without a hook")
    }

    @Test("edit/rich_tests.rs:908 a_pill_copied_from_one_rich_field_pastes_whole_into_another")
    func aPillCopiedFromOneRichFieldPastesWholeIntoAnother() throws {
        struct App {
            var a: TextEdit
            var b = TextEdit("").rich()
            var hooked = TextEdit("").rich()
        }
        var a = TextEdit("a  b").rich()
        a.setCursor(utf8Offset: 2)
        a.insertPill(id: "agent:x", label: "@x-agent")
        a.selectAll()
        let m = Clipboard(kind: .memory)
        let st = TextStyle(size: 14, weight: 400)
        let rt = Runtime(state: App(a: a), viewport: Vec2(320, 360), pixelScale: 1.0) { _, _ in
            col().size(320, 360)
                .child(textInput(key: "a", \App.a).font(st).size(300, 100))
                .child(textInput(key: "b", \App.b).font(st).size(300, 100))
                .child(
                    textInput(key: "hooked", \App.hooked).font(st).size(300, 100)
                        .onInputPaste { s, content, _ in
                            guard let html = content.html else { return false }
                            s.hooked.pasteHTMLWithPills(html, plain: content.text)
                            return true
                        }
                )
        }
        rt.useClipboard(m)
        _ = rt.frame(at: 0.0)
        rt.update { _, tx in tx.focus("a") }
        _ = rt.frame(at: 0.0)
        rt.update { s, _ in s.a.selectAll() }
        _ = rt.frame(at: 0.0)
        _ = rt.keyDown(KeyEvent(key: .command("c"), mods: Mods(cmd: true)), at: 0.0)
        _ = rt.frame(at: 0.0)
        let copied = m.readRich(sanitizeUntrustedHTML: false).content
        #expect(copied.text == "a @x-agent b")
        #expect(copied.html?.contains("<span data-pill=\"agent:x\">@x-agent</span>") == true, "\(copied.html ?? "nil")")

        func pasteInto(_ key: String) {
            rt.update { _, tx in tx.focus(key) }
            _ = rt.frame(at: 0.0)
            rt.update { _, tx in tx.requestPaste() }
            _ = rt.frame(at: 0.0)
        }
        func pills(_ e: TextEdit) -> [String] { e.pills.map { "\($0.range.lowerBound)..<\($0.range.upperBound) \($0.id)" } }
        pasteInto("b")
        #expect(pills(rt.state.b) == ["2..<10 agent:x"], "its own copy pastes the pill back")

        // The same HTML from outside pastes plain labels, even with identical plain text, unless a hook keeps them.
        m.writeRich(RichClipboardPayload(content: ClipboardContent("a @x-agent b", html: "a <span data-pill=\"agent:x\">@x-agent</span> b")))
        rt.update { s, _ in s.b.selectAll() }
        pasteInto("b")
        #expect(rt.state.b.text == "a @x-agent b" && rt.state.b.pills.isEmpty)
        m.writeRich(RichClipboardPayload(content: ClipboardContent("x @x-agent", html: "x <span data-pill=\"agent:x\">@x-agent</span>")))
        rt.update { s, _ in s.b.selectAll() }
        pasteInto("b")
        #expect(rt.state.b.text == "x @x-agent" && rt.state.b.pills.isEmpty)
        pasteInto("hooked")
        #expect(pills(rt.state.hooked) == ["2..<10 agent:x"])
    }

    @Test("clipboard.rs Board::clear: a cleared clipboard pastes nothing and keeps the selection; a read still answers")
    func aClearedClipboardPastesNothing() {
        struct S {
            var field = TextEdit("keep me")
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
        rt.update { s, _ in s.field.selectAll() }
        _ = rt.frame(at: 0.0)
        m.writeText("gone")
        m.clear()
        let before = rt.events.filter { $0 == "paste field" }.count
        rt.update { _, tx in tx.requestPaste() }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 0.0)
        #expect(rt.state.field.text == "keep me" && rt.state.field.selectedText == "keep me")
        #expect(rt.events.filter { $0 == "paste field" }.count == before)
        #expect(rt.keyDown(Self.cmdV, at: 0.0), "an empty clipboard still consumes the paste command")
        _ = rt.frame(at: 0.0)
        #expect(rt.state.field.text == "keep me" && rt.state.field.selectedText == "keep me")
        rt.update { _, tx in
            tx.readClipboard { (s: inout S, content: ClipboardContent, _: inout Tx) in s.reads.append(content) }
        }
        _ = rt.frame(at: 0.0)
        #expect(rt.state.reads == [ClipboardContent()])
    }

    @Test("physical.rs:163-167: a paste command is consumed by a window paste handler even on an empty clipboard")
    func pasteCommandIsConsumedByAWindowHandler() {
        let m = Clipboard(kind: .memory)
        let rt = Runtime(state: [String](), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            col().size(200, 100).onPaste { s, text, _ in s.append(text) }
        }
        rt.useClipboard(m)
        _ = rt.frame(at: 0.0)
        #expect(rt.acceptsPaste)
        #expect(rt.keyDown(Self.cmdV, at: 0.0))
        #expect(rt.state.isEmpty)
        m.writeText("hello")
        #expect(rt.keyDown(Self.cmdV, at: 0.0))
        #expect(rt.state == ["hello"])

        let none = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in col().size(200, 100) }
        none.useClipboard(m)
        _ = none.frame(at: 0.0)
        #expect(!none.acceptsPaste)
        #expect(!none.keyDown(Self.cmdV, at: 0.0), "nothing accepts the paste: the command routes on")
    }

    @Test("clipboard/tx.rs:40 Tx::copy_secret writes a concealed item the hold can clear")
    func copySecretWritesAConcealedItem() {
        struct S { var hold: SecretClipboardHold? = nil }
        let m = Clipboard(kind: .memory)
        let rt = Runtime(state: S(), viewport: Vec2(100, 100), pixelScale: 1.0) { _, _ in col().size(100, 100) }
        rt.useClipboard(m)
        _ = rt.frame(at: 0.0)
        rt.update { s, tx in
            tx.copyText("replaced")
            s.hold = tx.copySecret("p4ss", clearAfter: .seconds(30))
        }
        let written = m.readRich(sanitizeUntrustedHTML: false)
        #expect(written.content.text == "p4ss" && written.isConcealed, "the later concealed copy replaces the plain one")
        #expect(rt.copyRequest == nil && rt.pendingConcealedCopy == nil)
        #expect(rt.state.hold?.holds == true)
        #expect(rt.state.hold?.clearNow() == true)
        #expect(rt.state.hold?.state == .cleared)
        #expect(m.readRich(sanitizeUntrustedHTML: false).isEmpty)

        rt.update { s, tx in s.hold = tx.copySecret("again", clearAfter: .seconds(30)) }
        m.writeText("someone else")
        _ = rt.frame(at: 0.0)
        #expect(rt.state.hold?.state == .replaced, "another write takes the clipboard over")
    }
}
