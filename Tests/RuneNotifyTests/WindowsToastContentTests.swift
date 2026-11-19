import Foundation
import Testing
@testable import RuneNotify

struct WindowsToastContentTests {
    @Test func actionsAndProtocolLinksRetainUnicodeAndEscapeXML() throws {
        let identity = "n/🦦"
        let note = Notification(id: identity, title: "Title <1>\u{1}", subtitle: "Hint", body: "🍎 & ⬆")
            .info("q", "A+B & <")
            .action(id: "go", label: "Open")
            .reply(id: "r&", placeholder: "it's okay", label: "Send")
        let text = WindowsToastContent.xml(note, scheme: "rune-test", background: false)
        #expect(text.contains("Title &lt;1&gt;</text><text>Hint</text><text>🍎 &amp; ⬆"))
        #expect(text.contains("activationType=\"protocol\" launch=\"rune-test://notification/n%2F%F0%9F%A6%A6?q=A%2BB%20%26%20%3C\""))
        let input = try #require(text.range(of: "<input id=\"r&amp;\""))
        let button = try #require(text.range(of: "<action content=\"Open\""))
        #expect(input.lowerBound < button.lowerBound)
        #expect(text.contains("hint-inputId=\"r&amp;\""))
        #expect(text.contains("placeHolderContent=\"it&apos;s okay\""))
        #expect(text.contains("<audio silent=\"true\"/>"))
        let click = try #require(WindowsToastContent.click(
            arguments: "rune.id=n%2F%F0%9F%A6%A6&q=A%2BB%20%26%20%3C&rune.action=r%26",
            inputs: [("r&", "réponse ✓")]))
        #expect(click.id == identity)
        #expect(click.action == "r&")
        #expect(click.input(for: "r&") == "réponse ✓")
        #expect(click.get("q") == "A+B & <")
        let link = try #require(WindowsToastContent.click(
            url: "RUNE-TEST://notification/n%2F%F0%9F%A6%A6?q=A%2BB%20%26%20%3C", scheme: "rune-test"))
        #expect(link.id == identity)
        #expect(link.get("q") == "A+B & <")
    }

    @Test func windowsTagUsesUTF16LengthAndFiveActionsMaximum() {
        let fits = String(repeating: "🦦", count: 32)
        #expect(WindowsToastContent.tag(for: fits) == fits)
        let longID = String(repeating: "🦦", count: 33)
        #expect(WindowsToastContent.tag(for: longID).utf16.count <= 64)
        #expect(WindowsToastContent.tag(for: longID) != WindowsToastContent.tag(for: longID + "!"))
        var note = Notification(id: "a", title: "Test").sound(.default)
        for i in 0..<7 { note = note.action(id: String(i), label: "Action \(i)") }
        let xml = WindowsToastContent.xml(note, scheme: nil, background: true)
        #expect(xml.components(separatedBy: "<action ").count == 6)
        #expect(xml.contains("activationType=\"background\""))
        #expect(!xml.contains("Action 5"))
        #expect(!xml.contains("<audio"))
    }

    @Test func windowsTagMatchesRustDefaultHasherExactVectors() {
        // Exact 64-character BMP IDs pass through unchanged.
        let exact64 = String(repeating: "a", count: 64)
        #expect(WindowsToastContent.tag(for: exact64) == exact64)

        // Exact reference vectors from Rust `std::collections::hash_map::DefaultHasher::new()`
        // (`SipHash-1-3` with keys `(0, 0)` on UTF-8 bytes + `0xff`).
        let expected: [(String, String)] = [
            (String(repeating: "a", count: 65), "91fe5ed54711ec84"),
            (String(repeating: "0123456789abcdef", count: 4) + "!", "52128d186e8e402a"),
            // Leading-zero zero-padding check (`00...`).
            (String(repeating: "a", count: 65) + "145", "002524d45a09c35a"),
            // All 8 SipHash block-remainder lengths (65..=72 bytes + 1 delimiter byte).
            (String(repeating: "x", count: 65), "f423d293b26a33e1"),
            (String(repeating: "x", count: 66), "d5fe8f27ca11e5f5"),
            (String(repeating: "x", count: 67), "f7a0285271f1a2a9"),
            (String(repeating: "x", count: 68), "16c428e774bdf13b"),
            (String(repeating: "x", count: 69), "80652189dc4317bc"),
            (String(repeating: "x", count: 70), "8dee0515f3ccadd8"),
            (String(repeating: "x", count: 71), "7b4f3c1d56ef9489"),
            (String(repeating: "x", count: 72), "a572bc586c1ed8e2"),
            // Realistic long notification ID and multi-byte UTF-8 CJK ID.
            ("session/ses_0123456789abcdef0123456789abcdef/turn/0123456789abcdef/extra", "64c62b40ccf0f493"),
            (String(repeating: "通知-", count: 25), "956238f600d1ecc7"),
            // Non-BMP emoji (>64 UTF-16 code units at 33 scalars; >64 scalars at 65 scalars).
            (String(repeating: "🦦", count: 33), "df09866af88251c6"),
            (String(repeating: "🦦", count: 65), "ea898bf1e1e44892"),
            // Length >= 256 bytes verifies `(len & 0xff)` final-block length byte wrapping.
            (String(repeating: "z", count: 255), "f2a36d968c6fd24a"),
            (String(repeating: "z", count: 256), "71718371b07926d5"),
            (String(repeating: "z", count: 260), "647041df16b356ba"),
            (String(repeating: "z", count: 512), "edc984eea1917951"),
            // Empty and embedded-NUL IDs are safely hashed with the exact same SipHash-1-3 algorithm.
            ("", "30406ea523c53def"),
            ("with\0nul", "964789aebd9b2921"),
        ]
        for (input, rustHex) in expected {
            #expect(WindowsToastContent.tag(for: input) == rustHex)
        }
    }
}
