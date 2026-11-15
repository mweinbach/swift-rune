import Foundation
import Testing
import Rune
@testable import RuneMermaid

/// `rune_mermaid::drawing` (upstream 8c1be052 #1025): a prepared layout exposes its drawn
/// labels and can be redrawn with per-label text highlights.
@Suite("Mermaid DrawingModel")
struct MermaidDrawingModelTests {
    private let titled = """
    ---
    title: Checkout flow
    ---
    flowchart TD
      %% a source comment the drawing never shows
      A[Start] -->|go| B[Stop]
      B --> C[Done]
    """

    private func walk<State>(_ el: El<State>, _ visit: (El<State>) -> Void) {
        visit(el)
        for c in el.children { walk(c, visit) }
    }

    @Test("labels yield the title first, then each drawn label in drawing order")
    func labelsOrder() throws {
        let theme = MermaidTheme.neutral(dark: false)
        let model = try #require(prepareMermaidDrawing(titled, theme: theme))
        let labels = model.labels()
        let scene = model.shared.scene

        #expect(labels.first?.key == "title")
        #expect(labels.first?.text == "Checkout flow")
        #expect(labels.count == scene.labels.count + 1)
        let rest = Array(labels.dropFirst())
        for (i, (lk, l)) in zip(scene.labelKeys, scene.labels).enumerated() {
            #expect(rest[i].key == lk.key)
            #expect(rest[i].text == l.text)
        }
        let texts = rest.map(\.text)
        for shown in ["Start", "go", "Stop", "Done"] {
            #expect(texts.contains(shown), "missing \(shown)")
        }
        // Node IDs and source comments aren't drawn text.
        for hidden in ["A", "B", "C", "a source comment the drawing never shows"] {
            #expect(!texts.contains(hidden), "unexpected \(hidden)")
        }
        // Keys are unique: hover duplicates of a label are not listed again.
        #expect(Set(labels.map(\.key)).count == labels.count)

        // Without a title, the first entry is a label.
        let untitled = try #require(prepareMermaidDrawing("flowchart LR\n  A[One] --> B[Two]\n", theme: theme))
        #expect(untitled.labels().first?.key != "title")
        #expect(untitled.labels().map(\.text) == untitled.shared.scene.labels.map(\.text))
    }

    @Test("sameLayout compares the shared scene by identity")
    func sameLayout() throws {
        let theme = MermaidTheme.neutral(dark: true)
        let a = try #require(prepareMermaidDrawing(titled, theme: theme))
        let copy = a
        #expect(a.sameLayout(copy))
        // A rebuild with nothing new is a cache hit: the same layout.
        let again = try #require(prepareMermaidDrawing(titled, theme: theme))
        #expect(a.sameLayout(again))
        // Upstream's argument shape builds the same scene for the same hover.
        let shaped = try #require(prepareDrawing(titled, style: theme, hover: .edges, color: theme.text.alpha(0.9)))
        #expect(a.sameLayout(shaped))
        // A different source or width is a different layout.
        let other = try #require(prepareMermaidDrawing(titled + "\n  C --> D[More]", theme: theme))
        #expect(!a.sameLayout(other))
        var narrow = theme
        narrow.maxWidth = 240
        let squeezed = try #require(prepareMermaidDrawing(titled, theme: narrow))
        #expect(!a.sameLayout(squeezed))
        #expect(prepareMermaidDrawing("kanban\n  Todo", theme: theme) == nil)
    }

    @Test("draw applies marks to the title, each label and its hover copy")
    func highlightsReachLabels() throws {
        let theme = MermaidTheme.neutral(dark: false)
        let lit = Color(r: 0.9, g: 0.2, b: 0.5, a: 1.0)
        let model = try #require(prepareMermaidDrawing(titled, theme: theme, hover: (.edges, lit)))
        let goKey = try #require(model.labels().first { $0.text == "go" }?.key)
        let yellow = Color(r: 1, g: 0.9, b: 0.2, a: 1)
        var asked: [String] = []
        let d: MermaidDrawing<Int> = model.draw { key in
            asked.append(key)
            switch key {
            case "title": return [TextHighlight(0..<8, bg: yellow)]
            case goKey: return [TextHighlight(0..<2, bg: yellow, key: "hit")]
            default: return []
            }
        }
        // Every listed key is asked for.
        for l in model.labels() {
            #expect(asked.contains(l.key), "never asked for \(l.key)")
        }

        var title: [El<Int>] = []
        var go: [El<Int>] = []
        var start: [El<Int>] = []
        walk(d.el) { e in
            if e.keyId == "title" { title.append(e) }
            if e.plainText == "go" { go.append(e) }
            if e.plainText == "Start" { start.append(e) }
        }
        #expect(title.count == 1)
        #expect(title.first?.textHighlights == [TextHighlight(0..<8, bg: yellow)])
        // The label and the hover copy that lights it carry the same marks.
        #expect(go.count >= 2)
        for e in go {
            #expect(e.textHighlights == [TextHighlight(0..<2, bg: yellow, key: "hit")])
        }
        #expect(go.contains { $0.keyId == goKey })
        #expect(go.contains { $0.textColor == lit })
        #expect(!start.isEmpty)
        for e in start {
            #expect((e.textHighlights ?? []).isEmpty)
        }

        // Drawn without marks, the layout matches renderMermaidDrawing's.
        let plain: MermaidDrawing<Int> = try #require(renderMermaidDrawing(titled, theme: theme, hover: (.edges, lit)))
        #expect(d.size == plain.size)
        #expect(d.surface == plain.surface && d.surfaceBorder == plain.surfaceBorder)
        var unmarked = 0
        walk(plain.el) { e in if e.textHighlights != nil { unmarked += 1 } }
        #expect(unmarked == 0)
    }
}
