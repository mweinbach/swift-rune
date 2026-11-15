import Foundation
import Testing
import Rune
import RuneMermaid
@testable import RuneKit

/// `rune_kit::mermaid::prepare` (upstream 8c1be052 #1025).
@Suite("KitMermaid prepare")
struct KitMermaidPrepareTests {
    private let src = "---\ntitle: Pipeline\n---\nflowchart LR\n  A[Fetch] -->|ok| B[Build]\n"

    @Test("prepare lays out with the diagram paint at maxWidth and the card's hover")
    func prepareUsesDiagramPaint() throws {
        let style = MarkdownStyle.neutral(dark: false)
        let model: KitMermaid.DrawingModel = try #require(KitMermaid.prepare(src, style: style, maxWidth: 1024))
        #expect(model.labels().first?.key == "title")
        #expect(model.labels().first?.text == "Pipeline")
        #expect(model.labels().contains { $0.text == "Fetch" })
        #expect(model.labels().contains { $0.text == "ok" })

        // The same as preparing the diagram paint's style with max width overridden.
        var full = style.mermaidTheme()
        full.maxWidth = 1024
        #expect(full.font == style.diagram.font)
        let direct = try #require(prepareDrawing(src, style: full, hover: .edges, color: style.diagram.hover))
        #expect(model.sameLayout(direct))

        let narrow = try #require(KitMermaid.prepare(src, style: style, maxWidth: 200))
        #expect(!model.sameLayout(narrow))
        #expect(KitMermaid.prepare("kanban\n  Todo", style: style, maxWidth: 1024) == nil)
    }

    @Test("hover follows the paint: transparent is off, else edges or neighbours")
    func hoverFromPaint() {
        var paint = MarkdownStyle.neutral(dark: true).diagram
        paint.hover = Color(r: 1, g: 1, b: 1, a: 0)
        paint.hoverNeighbours = true
        #expect(KitMermaid.hover(paint) == .off)
        paint.hover = Color(r: 1, g: 1, b: 1, a: 0.9)
        #expect(KitMermaid.hover(paint) == .neighbours)
        paint.hoverNeighbours = false
        #expect(KitMermaid.hover(paint) == .edges)
    }
}
