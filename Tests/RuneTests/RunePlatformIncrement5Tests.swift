import Foundation
import Testing
@testable import Rune

@Suite("Platform Increment 5 Parity — RUNE_CONTRAST, copy_html, Windowless, Host Wiring")
struct RunePlatformIncrement5Tests {

    @Test("SystemContrast.fromEnvironment parses RUNE_CONTRAST presets and Runtime passes contrast to Cx")
    func systemContrastEnvAndCx() {
        #expect(SystemContrast.preset(named: "aquatic") != nil)
        #expect(SystemContrast.preset(named: "desert") != nil)
        #expect(SystemContrast.preset(named: "dusk") != nil)
        #expect(SystemContrast.preset(named: "night-sky") != nil)
        #expect(SystemContrast.preset(named: "unknown") == nil)

        let envContrast = SystemContrast.fromEnvironment(["RUNE_CONTRAST": "dusk"])
        #expect(envContrast == SystemContrast.preset(named: "dusk"))
        #expect(SystemContrast.fromEnvironment([:]) == nil)

        struct State {
            var seenContrast: SystemContrast?
        }

        let rt = Runtime<State>(
            state: State(),
            viewport: Vec2(120, 80),
            view: { _, cx in
                let _ = cx.systemContrast()
                return el().w(100).h(40)
            }
        )
        #expect(rt.systemContrast() == nil)

        let aquatic = SystemContrast.preset(named: "aquatic")!
        rt.setSystemContrast(aquatic)
        #expect(rt.systemContrast() == aquatic)

        var seen: SystemContrast?
        let rtObserve = Runtime<State>(
            state: State(),
            viewport: Vec2(120, 80),
            view: { _, cx in
                seen = cx.systemContrast()
                return el().w(100).h(40)
            }
        )
        rtObserve.setSystemContrast(aquatic)
        _ = rtObserve.frame(at: 0.0)
        #expect(seen == aquatic)
    }

    @Test("ClipboardHTMLBuilder formats headings, nested lists, tables, pre/code, inline marks, links, and escapes HTML")
    func clipboardHTMLBuilderFormatsBlocksAndInlines() {
        #expect(ClipboardHTMLBuilder.render([]) == nil)

        let slices: [SelectionHTMLSlice] = [
            SelectionHTMLSlice(
                headingLevel: 2,
                text: "Title & <More>"
            ),
            SelectionHTMLSlice(
                role: .listItem,
                groupId: "list-1",
                rowId: "item-1",
                text: "Bold & italic link",
                spans: [
                    TextSpan("Bold", weight: 700),
                    TextSpan(" & "),
                    TextSpan("italic", italic: true),
                    TextSpan(" "),
                    TextSpan("link", monospace: true),
                ],
                links: [(utf8Range: 14..<18, url: "https://example.com?a=1&b=2")]
            ),
            SelectionHTMLSlice(
                role: .listItem,
                isOrderedListItem: true,
                groupId: "list-2",
                rowId: "item-2",
                text: "Ordered"
            ),
            SelectionHTMLSlice(
                groupId: "tbl-1",
                rowId: "r-1",
                isHeaderCell: true,
                text: "Col A"
            ),
            SelectionHTMLSlice(
                blockTag: "cell",
                groupId: "tbl-1",
                rowId: "r-2",
                text: "Val 1"
            ),
            SelectionHTMLSlice(
                isMonospaceBlock: true,
                text: "let x = 1 < 2"
            ),
            SelectionHTMLSlice(
                blockTag: "p",
                text: "Struck",
                strikes: [0..<6]
            ),
        ]

        let html = ClipboardHTMLBuilder.render(slices)
        #expect(html != nil)
        let rendered = html ?? ""
        #expect(rendered.contains("<h2>Title &amp; &lt;More&gt;</h2>"))
        #expect(rendered.contains("<ul><li><strong>Bold</strong> &amp; <em>italic</em> <a href=\"https://example.com?a=1&amp;b=2\"><code>link</code></a></li></ul>"))
        #expect(rendered.contains("<ol><li>Ordered</li></ol>"))
        #expect(rendered.contains("<table><tr><th>Col A</th></tr><tr><td>Val 1</td></tr></table>"))
        #expect(rendered.contains("<pre><code>let x = 1 &lt; 2</code></pre>"))
        #expect(rendered.contains("<p><s>Struck</s></p>"))
    }

    @Test("Tx.copyHTML and Runtime.paste sync richClipboard")
    func txCopyHTMLAndPasteSyncRichClipboard() {
        struct State {
            var count = 0
        }
        let rt = Runtime<State>(
            state: State(),
            viewport: Vec2(100, 60),
            view: { _, _ in el().w(80).h(40) }
        )
        rt.update(at: 0.1) { _, tx in
            tx.copyHTML("Hello", html: "<p><strong>Hello</strong></p>")
        }
        #expect(rt.clipboard.text == "Hello")
        #expect(rt.clipboard.html == "<p><strong>Hello</strong></p>")
        #expect(rt.richClipboard.content.text == "Hello")
        #expect(rt.richClipboard.content.html == "<p><strong>Hello</strong></p>")

        rt.paste(ClipboardContent("World", html: "<em>World</em>"), at: 0.2)
        #expect(rt.clipboard.text == "World")
        #expect(rt.richClipboard.content.html == "<em>World</em>")
    }

    @Test("Windowless App does not route through HeadlessRunner unless CLI requests headless mode")
    func windowlessRoutingFollowsHeadlessFlagsOnly() {
        let normal = ToolingArgs.parse([])
        #expect(normal.isHeadlessRequested == false)

        let snap = ToolingArgs.parse(["--snap", "/tmp/out.png"])
        #expect(snap.isHeadlessRequested == true)

        let app = App(title: "MenuBarOnly", state: 0) { _, _ in
            el().w(100).h(50)
        }.windowless()
        #expect(app.isWindowless == true)
    }
}
