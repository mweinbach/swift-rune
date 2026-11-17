import Testing
@testable import Rune
@testable import RuneKit

@Suite struct MarkdownBidiRenderTests {
    private func rendered(_ source: String, tentative: MarkdownDirection? = nil) -> El<Int> {
        Markdown(source).dirTentative(tentative).render(.neutral(dark: true))
    }

    private func words(_ element: El<Int>) -> [String] {
        let text = element.richSpans?.map(\.text).joined() ?? ""
        let bytes = Array(text.utf8)
        return element.isolatesSpec.map { String(decoding: bytes[$0.range], as: UTF8.self) }
    }

    @Test func technicalUnitsUseDisplayedUTF8AndLeaveLabelsAsProse() throws {
        let source = "(/src/main.rs) --amend +12 renderView() `git status` [https://a.test](https://a.test) שלום [קישור](https://b.test)."
        let node = try #require(rendered(source).children.first)
        #expect(node.explicitDir == .rtl)
        #expect(node.isolatesSpec.map(\.range) == [0..<14, 15..<22, 23..<26, 27..<39, 40..<68, 69..<83])
        #expect(words(node) == ["(/src/main.rs)", "--amend", "+12", "renderView()", MarkdownInline.openPad + "git status" + MarkdownInline.closePad, "https://a.test"])
        #expect(node.isolatesSpec.allSatisfy { $0.dir == .ltr })
        #expect(node.textStyle.align == .leading)
        let mutable = MarkdownParser.parseAST("English")
        guard case .para(var inline) = mutable.first else { Issue.record("Expected paragraph"); return }
        inline.text = "/tmp/a.rs العربية"
        #expect(MarkdownBidi.inlineDirection(inline) == .rtl)
        inline.links = [MarkdownLinkSpan(start: 0, end: inline.text.utf8.count, url: inline.text)]
        #expect(MarkdownBidi.inlineDirection(inline) == nil)
    }

    @Test func neutralBlocksFollowThePrecedingProseAndTentativeDirection() {
        let tree = rendered("123\n\nمرحبا\n\n+45\n\nEnglish\n\n`code`", tentative: .ltr)
        #expect(tree.explicitDir == .rtl)
        #expect(tree.children.map(\.explicitDir) == [.ltr, .rtl, .rtl, .ltr, .ltr])
        #expect(rendered("١٢٣ +45", tentative: .rtl).explicitDir == .rtl)
        #expect(MarkdownBidi.blocksDirection([.image(src: "x", alt: "English", title: "")]) == nil)
        let fences = rendered("مرحبا\n\n```swift\nlet n = 1\n```\n\n```diff\n+ חדש\n```")
        #expect(fences.children.map(\.explicitDir) == [.rtl, .ltr, .ltr])
    }

    @Test func explicitIsolatesAndNeutralScalarsStayIntact() {
        let isolated = "\u{2068}مرحبا\u{2069}"
        #expect(MarkdownBidi.isolateEmbeddedRuns("A " + isolated + " Z", base: .ltr) == "A " + isolated + " Z")
        #expect(MarkdownBidi.isolateEmbeddedRuns("A\u{301} ־ X", base: .ltr) == "A\u{301} \u{2067}־ \u{2069}X")
        #expect(MarkdownBidi.isolateEmbeddedRuns("123\u{feff}", base: .rtl) == "123\u{feff}")
    }

    @Test func nestedListsQuotesAndCellsUseTheirOwnProseDirection() throws {
        let tree = rendered("- /tmp/a.rs שלום\n- English\n\n> +42 العربية\n\n| שם | Value |\n|---|---|\n| `foo()` | مرحبا |")
        #expect(tree.explicitDir == .rtl)
        #expect(tree.children.map(\.explicitDir) == [.rtl, .rtl, .rtl])
        func textNodes(_ node: El<Int>) -> [El<Int>] {
            (node.richSpans == nil ? [] : [node]) + node.children.flatMap(textNodes)
        }
        let nodes = textNodes(tree)
        func node(_ value: String) -> El<Int>? { nodes.first { $0.richSpans?.map(\.text).joined() == value } }
        #expect(node("English")?.explicitDir == .ltr)
        #expect(node("Value")?.explicitDir == .ltr)
        #expect(node("שם")?.explicitDir == .rtl)
        #expect(node("مرحبا")?.explicitDir == .rtl)
        let token = try #require(node(MarkdownInline.openPad + "foo()"))
        #expect(token.explicitDir == nil)
        #expect(words(token) == [MarkdownInline.openPad + "foo()"])
    }

    @MainActor @Test func runtimeMirrorsListMarkersAndQuoteRuleAndShapesIsolates() throws {
        let source = "- `foo`\n- שלום --flag\n- English\n\n> [https://example.com](url) שלום"
        let runtime = Runtime(state: 0, viewport: Vec2(400, 400)) { _, _ in
            Markdown(source).render(.neutral(dark: false))
        }
        _ = runtime.frame(at: 0)
        let elements = runtime.elements()
        let markers = elements.filter { $0.text == "•" }
        #expect(markers.count == 3)
        #expect(markers.allSatisfy { $0.target[0] == 368 && $0.target[2] == 32 })
        #expect(elements.contains { $0.text == "שלום \u{2066}--flag\u{2069}" })
        let rule = try #require(elements.first { $0.path.hasSuffix("@b1/0") })
        #expect(rule.target[0] == 398 && rule.target[2] == 2)
        let quote = try #require(elements.first { $0.text == "\u{2066}https://example.com\u{2069} שלום" })
        #expect(quote.target[0] == 0 && quote.target[2] == 386)
    }
}
