import Foundation
import Testing
#if os(macOS)
import AppKit
#endif
@testable import RuneKit
@testable import Rune
@testable import RuneHighlights
@testable import RuneMermaid

@Suite("RuneKit Syntax & Mermaid Integration Tests")
struct SyntaxAndMermaidTests {
    @Test("Syntax.known and Syntax.builtin highlight supported languages and leave unknown/plain empty")
    func builtinLanguagesAndPlainFallback() {
        let samples: [(String, String)] = [
            ("rust", "fn main() { let x = 1; }"),
            ("TS", "const x: number = 1;"),
            ("tsx", "export const A = () => <div />;"),
            ("py", "def f(x): return x + 1"),
            ("Go", "func main() { x := 1 }"),
            ("json", "{\"a\": 1}"),
            ("swift", "let x = 1"),
            ("bash", "echo $HOME"),
            ("sql", "SELECT 1;"),
            ("html", "<div class=\"a\">hi</div>"),
            ("css", "body { color: red; }"),
            ("yml", "key: value"),
            ("diff", "+added\n-removed"),
        ]
        for (lang, code) in samples {
            #expect(Syntax.known(lang), "Expected \(lang) to be known")
            #expect(!Syntax.builtin(language: lang, code: code).isEmpty, "Expected highlights for \(lang)")
        }

        for unknown in [nil, "", "plain", "text", "brainfuck"] as [String?] {
            if let u = unknown {
                #expect(!Syntax.known(u))
            }
            #expect(Syntax.builtin(language: unknown, code: "let x = 1").isEmpty)
        }
    }

    @Test("Syntax.kind maps HighlightToken capture names and parent fallbacks")
    func tokenKindMapping() {
        #expect(Syntax.kind(for: HighlightToken(.keyword)) == .keyword)
        #expect(Syntax.kind(for: HighlightToken(.keywordControl)) == .keyword)
        #expect(Syntax.kind(for: HighlightToken(.keywordOperator)) == .operator)
        #expect(Syntax.kind(for: HighlightToken(.stringEscape)) == .number)
        #expect(Syntax.kind(for: HighlightToken(.diffPlus)) == .inserted)
        #expect(Syntax.kind(for: HighlightToken(.diffMinus)) == .deleted)
        #expect(Syntax.kind(for: HighlightToken(.textLiteral)) == .string)
    }

    @Test("Syntax.langForPath resolves filenames, two-part extensions, and single extensions")
    func pathLanguageResolution() {
        #expect(Syntax.langForPath("Makefile") == "makefile")
        #expect(Syntax.langForPath("src/CMakeLists.txt") == "cmake")
        #expect(Syntax.langForPath("app.component.ts") == "angular-ts")
        #expect(Syntax.langForPath("Sources/App/Main.swift") == "swift")
        #expect(Syntax.langForPath("crates/core/lib.rs") == "rust")
        #expect(Syntax.langForPath("README.md") == "markdown")
        #expect(Syntax.langForPath("notes.unknownext") == nil)
        #expect(Syntax.langForPath("file.m") == nil)
    }

    @Test("SyntaxHighlighter caches by key/language/code and tidies invalid custom ranges")
    func highlighterCacheAndTidy() {
        final class Counter: @unchecked Sendable {
            var count = 0
        }
        let counter = Counter()
        let custom = SyntaxHighlighter(id: "test-counter") { _, code in
            counter.count += 1
            return [
                SyntaxHighlight(range: 6..<9, paint: .kind(.number)),
                SyntaxHighlight(range: 0..<3, paint: .kind(.keyword)),
                SyntaxHighlight(range: 2..<5, paint: .kind(.string)), // overlaps 0..<3 -> dropped
                SyntaxHighlight(range: 4..<4, paint: .kind(.type)),   // empty -> dropped
                SyntaxHighlight(range: 9..<40, paint: .kind(.comment)), // out of bounds -> dropped
                SyntaxHighlight(range: 11..<12, paint: .kind(.comment)), // mid-UTF8 of "é" -> dropped
                SyntaxHighlight(range: 13..<15, paint: .kind(.type)),
            ]
        }

        let source = "let x = 1 é ok"
        let first = custom.highlight(language: "x", code: source)
        let second = custom.highlight(language: "x", code: source)
        #expect(counter.count == 1)
        #expect(first == second)
        #expect(first.map(\.range) == [0..<3, 6..<9, 13..<15])

        _ = custom.key("dark").highlight(language: "x", code: source)
        #expect(counter.count == 2)
    }

    @Test("SyntaxTheme produces distinct colors and accurate TextSpans, and Kit.codeBlock renders")
    func syntaxThemeAndCodeBlock() {
        for dark in [false, true] {
            let theme = SyntaxTheme.neutral(dark: dark)
            #expect(theme.color(for: .keyword) != theme.color(for: .string))
            #expect(theme.color(for: .inserted) != theme.color(for: .deleted))
        }

        let kit = Kit.neutral(dark: true)
        let code = "func greet() -> Int {\n    return 42\n}"
        let highlights = Syntax.highlight(language: "swift", code: code)
        let spans = SyntaxTheme.fromKit(kit).spans(for: code, highlights: highlights)
        #expect(!spans.isEmpty)
        #expect(spans.map(\.text).joined() == code)

        let rt = Runtime<Int>(state: 0, viewport: Vec2(500, 300)) { _, _ in
            kit.codeBlock(key: "cb", code: code, language: "swift", showLineNumbers: true, lineSelection: LineSelection(line: 2))
        }
        let scene = rt.frame(at: 0)
        #expect(!scene.primitives.isEmpty)
    }

    @Test("KitMermaid renders supported diagrams and falls back to code block when invalid")
    func mermaidIntegrationAndFallback() {
        let src = """
        flowchart TD
            A[Start] --> B[Done]
        """
        #expect(KitMermaid.supported(src))
        #expect(KitMermaid.canRender(src))
        #expect(KitMermaid.kindLabel(src) == "Flowchart")

        let kit = Kit.neutral(dark: true)
        let diagram: El<Int>? = kit.mermaid(src)
        #expect(diagram != nil)

        let drawing: MermaidDrawing<Int>? = kit.mermaidDrawing(src, maxWidth: 600)
        #expect(drawing != nil)

        let invalid = "not a mermaid diagram"
        #expect(!KitMermaid.supported(invalid))
        let fallbackEl: El<Int> = kit.mermaidOrCode(source: invalid)
        let rt = Runtime<Int>(state: 0, viewport: Vec2(500, 300)) { _, _ in fallbackEl }
        #expect(!rt.frame(at: 0).primitives.isEmpty)
    }

    @MainActor
    @Test("Mermaid cards, frameless drawings and Markdown expose the diagram kind and source")
    func mermaidFigureAccessibility() throws {
        let kit = Kit.neutral(dark: true)
        let body = "flowchart LR\n  A[Start] --> B[Done]\n%% note\u{200B}"
        let source = "\u{2009}\n\(body)\n\t "
        let fence = "```mermaid\n\(source)\n```"
        let card: El<Int> = try #require(kit.mermaid(source))
        let drawing: MermaidDrawing<Int> = try #require(kit.mermaidDrawing(source))
        let diagrams: [El<Int>] = [
            card, drawing.el, kit.mermaidOrCode(source: source), kit.markdown(fence),
            kit.markdown(fence, searchQuery: nil, streaming: true),
            kit.markdown("```mermaid\n\(body)\nC[Incomplete", searchQuery: nil, streaming: true),
        ]

        func figures(in node: AccessibilityNode) -> [AccessibilityNode] {
            (node.role == .figure ? [node] : []) + node.children.flatMap(figures)
        }
        for diagram in diagrams {
            let runtime = Runtime<Int>(state: 0, viewport: Vec2(600, 400)) { _, _ in diagram }
            _ = runtime.frame(at: 0)
            let nodes = figures(in: runtime.accessibilitySnapshot())
            #expect(nodes.count == 1)
            let figure = try #require(nodes.first)
            #expect(figure.label == "Flowchart")
            #expect(figure.help == body)
            #if os(macOS)
            let native = AppKitAccessibilityMapper.buildElement(from: figure)
            #expect(native.accessibilityRole() == .group)
            #expect(native.accessibilityLabel() == "Flowchart")
            #expect(native.accessibilityHelp() == body)
            #endif
        }

        let fallback = Runtime<Int>(state: 0, viewport: Vec2(600, 400)) { _, _ in
            kit.mermaidOrCode(source: "unsupported")
        }
        _ = fallback.frame(at: 0)
        #expect(figures(in: fallback.accessibilitySnapshot()).isEmpty)
        #expect(KitMermaid.kindLabel("  %%skip\nstateDiagram-v2-v2-beta-beta") == "State diagram")
    }

    @Test("Standalone and fenced Mermaid diagrams share the Markdown paint and hover regions")
    func mermaidStyleAndHover() throws {
        let source = "flowchart LR\n  A[Fetch data] --> B[Build the artifacts] --> C[Publish the results]"
        let surface = Color(r: 0.3, g: 0.2, b: 0.1, a: 1)
        let border = Color(r: 0.5, g: 0.6, b: 0.7, a: 1)
        let paint = MarkdownStyle.neutral(dark: false)
            .diagramSurface(fill: surface, border: border, subgraph: .white)
        for enabled in [false, true] {
            let style = paint.diagramHover(enabled ? .white : .transparent, neighbours: true)
            let card: El<Int> = try #require(KitMermaid.render(source, style: style))
            let wide: KitMermaid.Drawing<Int> = try #require(KitMermaid.drawing(source, style: style, maxWidth: 900))
            let narrow: KitMermaid.Drawing<Int> = try #require(KitMermaid.drawing(source, style: style, maxWidth: 120))
            #expect(card.role == .figure && wide.el.role == .figure)
            #expect(card.background == surface && card.borderColor == border)
            #expect(wide.surface == surface && wide.surfaceBorder == border)
            #expect(narrow.size != wide.size)

            let fence = "```mermaid\n\(source)\n"
            let diagrams: [El<Int>] = [
                card, wide.el, Markdown(fence + "```").render(style),
                Markdown(fence + "```").streaming().render(style), Markdown(fence).streaming().render(style),
            ]
            for diagram in diagrams {
                let runtime = Runtime<Int>(state: 0, viewport: Vec2(640, 480)) { _, _ in diagram }
                _ = runtime.frame(at: 0)
                #expect(runtime.elements().contains { $0.key?.hasPrefix("hover:") == true } == enabled)
            }
        }
        let unsupported: KitMermaid.Drawing<Int>? = KitMermaid.drawing("unknown", style: paint, maxWidth: 600)
        #expect(unsupported == nil)
        #expect(KitMermaid.mayDraw("%% waiting") && !KitMermaid.mayDraw("unknown"))
        #expect(KitMermaid.mayDraw("gantt") && !KitMermaid.supported("gantt"))
        #expect(MarkdownFind.find("```mermaid\ngantt\n```", "gantt").count == 1)
        #expect(MarkdownFind.find("```mermaid\n\(source)\n```", "flowchart").isEmpty)
    }

    @Test("src/syntax.rs #49 & #53: distinct highlighters keep separate caches, and spans match SyntaxTheme colors & weights")
    func distinctHighlightersAndSpansColorParity() {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            var count = 0
            func inc() {
                lock.lock()
                count += 1
                lock.unlock()
            }
        }
        let callsA = Counter()
        let callsB = Counter()
        let hlA = SyntaxHighlighter { _, _ in
            callsA.inc()
            return [SyntaxHighlight(range: 0..<3, paint: .kind(.keyword))]
        }
        let hlB = SyntaxHighlighter { _, _ in
            callsB.inc()
            return [SyntaxHighlight(range: 4..<5, paint: .kind(.string))]
        }
        // Distinct highlighters on identical ("js", "let x = 1") do not cross-hit cache
        #expect(hlA.highlight(language: "js", code: "let x = 1") == [SyntaxHighlight(range: 0..<3, paint: .kind(.keyword))])
        #expect(hlB.highlight(language: "js", code: "let x = 1") == [SyntaxHighlight(range: 4..<5, paint: .kind(.string))])
        #expect(hlA.highlight(language: "js", code: "let x = 1") == [SyntaxHighlight(range: 0..<3, paint: .kind(.keyword))])
        #expect(hlB.highlight(language: "js", code: "let x = 1") == [SyntaxHighlight(range: 4..<5, paint: .kind(.string))])
        #expect(callsA.count == 1)
        #expect(callsB.count == 1)

        // #53: spans_colour_and_offset exact TextSpan colors, explicit .color, and weight/italic
        let theme = SyntaxTheme.neutral(dark: true)
        let weighted = theme.withWeight(.keyword, 700)
        let explicitColor = Color(r: 0.12, g: 0.85, b: 0.34, a: 1.0)
        let defaultFG = theme.color(for: .variable)
        let spans = theme.spans(
            for: "let x = 1",
            highlights: [
                SyntaxHighlight(range: 0..<3, paint: .kind(.keyword)),
                SyntaxHighlight(range: 4..<5, paint: .color(explicitColor)),
                SyntaxHighlight(range: 8..<9, paint: .kind(.number)),
            ],
            defaultColor: defaultFG
        )
        #expect(spans.count == 5)
        #expect(spans[0].text == "let" && spans[0].color == theme.color(for: .keyword) && spans[0].weight == nil && !spans[0].italic)
        #expect(spans[1].text == " " && spans[1].color == defaultFG && spans[1].weight == nil && !spans[1].italic)
        #expect(spans[2].text == "x" && spans[2].color == explicitColor && spans[2].weight == nil && !spans[2].italic)
        #expect(spans[3].text == " = " && spans[3].color == defaultFG && spans[3].weight == nil && !spans[3].italic)
        #expect(spans[4].text == "1" && spans[4].color == theme.color(for: .number) && spans[4].weight == nil && !spans[4].italic)

        let weightedSpans = weighted.spans(
            for: "let x = 1",
            highlights: [SyntaxHighlight(range: 0..<3, paint: .kind(.keyword)), SyntaxHighlight(range: 4..<5, paint: .color(explicitColor))],
            defaultColor: defaultFG
        )
        #expect(weightedSpans[0].weight == 700 && !weightedSpans[0].italic)
        #expect(weightedSpans[2].weight == nil && !weightedSpans[2].italic)
    }
}
