import Foundation
import Testing
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
