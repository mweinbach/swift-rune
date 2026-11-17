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
}
