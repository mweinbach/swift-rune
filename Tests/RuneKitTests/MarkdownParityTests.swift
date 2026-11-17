import Foundation
import Testing
@testable import RuneKit
@testable import Rune

@Suite("RuneKit Markdown Parity Tests")
struct MarkdownParityTests {
    @Test("Raw HTML blocks interrupt and end with the same boundaries as pulldown-cmark")
    func rawHTMLBlockBoundaries() {
        let hidden = [
            "<pre>\n# not a heading\n\n</pre> hidden too\n",
            "<script>inline</script>\n",
            "<!-- hidden\n\n--> hidden too\n",
            "<?a\n?> hidden too\n",
            "<!partial\n> hidden too\n",
            "<![CDATA[\n]]> hidden too\n",
            "<DIV class=\nbody\n</DIV>\n\n",
        ]
        let expected = [MarkdownDocBlock.para(MarkdownInline(text: "Intro")), .para(MarkdownInline(text: "Tail"))]
        for block in hidden {
            let source = "Intro\n" + block + "Tail"
            for doc in [MarkdownParser.parseDocument(source), Markdown(source).streaming().document()] {
                #expect(doc.blocks == expected, "\(block)")
                #expect(doc.blockStarts == [0, source.utf8.count - 4])
            }
        }
        let tail = MarkdownDocBlock.para(MarkdownInline(text: "Tail"))
        #expect(MarkdownParser.parseAST("<custom-x a='>'/>\nhidden\n\nTail") == [tail])
        #expect(MarkdownParser.parseAST("Intro\n<custom-x>\nbody\n\nTail") == [.para(MarkdownInline(text: "Intro  body")), tail])
        #expect(MarkdownParser.parseAST("> <div>\nTail") == [.quote([]), tail])
        #expect(MarkdownParser.parseAST("- <div>\nTail") == [.list(start: nil, items: [[]]), tail])
        #expect(MarkdownParser.parseAST("# <i></i>").isEmpty)
        #expect(MarkdownParser.parseAST("<i></i>\nTail") == [tail])
        #expect(MarkdownParser.parseAST("> # T\n> <x>\nTail") == [.quote([.heading(level: 1, MarkdownInline(text: "T"))]), tail])
        let quoted = MarkdownParser.parseAST("> ```\n> <div>\n> ```\n> word\ncontinued")
        #expect(quoted == [.quote([.code("<div>"), .para(MarkdownInline(text: "word continued"))])])

        #expect(Markdown("Intro\n\n<div>\n**open").streaming().document().blocks == [expected[0]])
    }

    @Test("Inline raw tags preserve disjoint UTF-8 source ranges and explicit autolinks")
    func rawHTMLInlineSourceAndLinks() throws {
        let source = "A <i data='>'>é</i> zz <ftp://a/b> <a@host>"
        for doc in [MarkdownParser.parseDocument(source), Markdown(source).streaming().document()] {
            let block = try #require(doc.blocks.first)
            guard case let .para(inline) = block, case let .inline(map) = doc.maps.first else {
                Issue.record("Expected a mapped paragraph")
                return
            }
            #expect(inline.text == "A é zz ftp://a/b a@host")
            #expect(inline.links == [
                MarkdownLinkSpan(start: 8, end: 17, url: "ftp://a/b"),
                MarkdownLinkSpan(start: 18, end: 24, url: "a@host"),
            ])
            #expect(map.segments.map(\.src) == [0..<2, 14..<16, 20..<24, 25..<34, 35..<36, 37..<43])
            #expect(map.segments.map(\.out) == [0..<2, 2..<4, 4..<8, 8..<17, 17..<18, 18..<24])
        }
        #expect(Markdown("x <!--a--> y <?t?> z <![CDATA[**q**]]> u <!D x> v").plainText() == "x  y  z  u  v")
        #expect(Markdown("x \\<i> and `<b>`").plainText() == "x <i> and <b>")
        #expect(Markdown("pre <x a==bad> post").plainText() == "pre <x a==bad> post")
    }

    @Test("MarkdownStream stabilizes unclosed fences and inline code spans")
    func markdownStreamStabilization() {
        var stream = MarkdownStream()
        stream.append("# Stream\n\n```swift\nlet a = 1")
        let stabilized = stream.stabilizedSource
        #expect(stabilized.hasSuffix("\n```"))
        let blocks = stream.parseBlocks()
        #expect(blocks.count == 2)
        if case let .codeBlock(lang, code) = blocks[1] {
            #expect(lang == "swift")
            #expect(code == "let a = 1")
        } else {
            Issue.record("Expected stabilized codeBlock")
        }

        let inlineUnclosed = MarkdownStream.stabilize("Hello `world")
        #expect(inlineUnclosed == "Hello `world`")
    }

    @Test("MarkdownAutolink scans URLs, angle-bracketed links, and emails")
    func autolinkScanning() {
        let sample = "Visit https://example.com/docs, <https://rune.dev>, or email dev@example.com."
        let matches = MarkdownAutolink.scan(sample)
        #expect(matches.count == 3)
        #expect(matches[0].url == "https://example.com/docs")
        #expect(matches[1].url == "https://rune.dev")
        #expect(matches[2].url == "mailto:dev@example.com")
        #expect(matches[2].isEmail)
    }

    @Test("MarkdownParser parses task lists and footnote definitions")
    func taskListsAndFootnotes() {
        let md = """
        - [ ] Unchecked item
        - [x] Checked item

        See details[^1].

        [^1]: Footnote explanation here.
        """
        let blocks = MarkdownParser.parse(md)
        #expect(blocks.count == 3)

        if case .taskList(let tasks) = blocks[0] {
            #expect(tasks.count == 2)
            #expect(tasks[0] == MarkdownTaskItem(checked: false, text: "Unchecked item"))
            #expect(tasks[1] == MarkdownTaskItem(checked: true, text: "Checked item"))
        } else {
            Issue.record("Expected taskList at block 0")
        }

        if case let .footnoteDefinition(id, body) = blocks[2] {
            #expect(id == "1")
            #expect(body == "Footnote explanation here.")
        } else {
            Issue.record("Expected footnoteDefinition at block 2")
        }
    }

    @Test("MarkdownBidi detects RTL vs LTR paragraph direction")
    func bidiDirectionDetection() {
        #expect(MarkdownBidi.direction(of: "Hello world") == .ltr)
        #expect(MarkdownBidi.direction(of: "مرحبا بالعالم") == .rtl)
        #expect(MarkdownBidi.direction(of: "שלום עולם") == .rtl)
        #expect(MarkdownBidi.direction(of: "12345") == .ltr)
    }

    @Test("Search match highlighting and automatic mermaid block rendering in Kit.markdown")
    @MainActor
    func searchHighlightingAndMermaidInMarkdown() {
        let kit = Kit.neutral(dark: true)
        let spans = MarkdownParser.inlineSpans(
            "Find the needle in this needle haystack",
            kit: kit,
            searchQuery: "needle",
            activeMatch: 1
        )
        let highlighted = spans.filter { $0.background != nil }
        #expect(highlighted.count == 2)
        #expect(highlighted[0].background != highlighted[1].background)

        let mdWithMermaid = """
        # Diagram

        ```mermaid
        flowchart LR
            A --> B
        ```

        - [x] Rendered
        """
        let rt = Runtime<Int>(state: 0, viewport: Vec2(600, 600)) { _, _ in
            kit.markdown(mdWithMermaid, key: "md-mermaid", searchQuery: "Diagram", streaming: true)
        }
        let scene = rt.frame(at: 0)
        #expect(!scene.primitives.isEmpty)
    }
}
