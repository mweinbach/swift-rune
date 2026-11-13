import Foundation
import Testing
@testable import RuneKit
@testable import Rune

@Suite("RuneKit Markdown Parity Tests")
struct MarkdownParityTests {
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
