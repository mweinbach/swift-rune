import Foundation
import Testing
import Rune
@testable import RuneMermaid

@Suite("RuneMermaid Core Tests")
struct RuneMermaidCoreTests {
    @Test("clean turns markup into plain text")
    func cleanTurnsMarkupIntoText() {
        #expect(clean("a<br>b<br/>c<BR />d\\ne") == "a\nb\nc\nd\ne")
        #expect(clean("#quot;hi#quot; &amp; &lt;3 &apos;ok&apos;") == "\"hi\" & <3 'ok'")
        #expect(clean("`**md**`") == "**md**")
        #expect(clean("# not an entity & also not") == "# not an entity & also not")
        #expect(cleanQuoted(" \"capuchin ≈ Cappuccino\" ") == "capuchin ≈ Cappuccino")
    }

    @Test("unsupported diagram types and garbage are rejected")
    func unsupportedDiagramTypes() {
        for src in ["", "kanban\n  Todo", "pie title Pets", "gantt\ntitle x", "erDiagram", "hello", "%% only a comment"] {
            #expect(!canRenderMermaid(src), "Should not render: \(src)")
        }

        let parsed = MermaidParser.parse("---\ntitle: Hi\n---\ngraph TD\nA-->B")
        #expect(parsed != nil)
        #expect(parsed?.title == "Hi")

        #expect(supportedMermaid("%%{\n  init: {'theme': 'dark'}\n}%%\nflowchart LR\nA-->B"))
        #expect(supportedMermaid("stateDiagram-v2\n[*] --> Idle\nIdle --> [*]"))
        #expect(supportedMermaid("classDiagram\nA <|-- B"))
        #expect(canRenderMermaid("flowchart TD\n  A[Runtime&lt;S&gt;] --> B[a; b]; B --> C"))
    }

    @Test("node stroke width reads mermaid px")
    func nodeStrokeWidthReadsMermaidPx() {
        #expect(parseStyleProps("stroke:#333,stroke-width:2px").width == 2.0)
        #expect(parseStyleProps("stroke-width:4").width == 4.0)
        #expect(parseStyleProps("stroke-width:wide").width == nil)
    }

    @Test("node style keeps contrast in dark and light themes")
    func nodeStyleKeepsContrast() {
        let pastel = parseStyleProps("fill:#dcf5dc,stroke:#333")
        for dark in [true, false] {
            let style = MermaidTheme.neutral(dark: dark)
            let (fill, _, text) = pastel.resolve(against: style)
            let diff = abs(fill.toOKLab()[0] - text.toOKLab()[0])
            #expect(diff > 0.45)
        }
        #expect(parseColorSpec("rgb(30, 60, 90)") != nil)
        #expect(parseColorSpec("lightgreen") != nil)
    }

    @Test("dashes cover the line in on-off runs")
    func dashesCoverTheLine() {
        var c = Canvas()
        c.dashed([Vec2(0, 0), Vec2(10, 0), Vec2(10, 10)], width: 1.0, color: .white, on: 3.0, off: 1.0)
        let dashes: [[Vec2]] = c.ops.compactMap { op in
            if case let .stroke(points, _, _, _, _) = op { return points }
            return nil
        }
        #expect(dashes.count == 5)
        #expect(dashes[0].first == Vec2(0, 0))
        let corner = dashes[2]
        #expect(corner.count == 3)
        #expect(CanvasMath.dist(corner[0], Vec2(8, 0)) < 1e-4)
        #expect(CanvasMath.dist(corner[1], Vec2(10, 0)) < 1e-4)
        #expect(CanvasMath.dist(corner[2], Vec2(10, 1)) < 1e-4)
    }

    @Test("smooth passes through its points")
    func smoothPassesThroughPoints() {
        let pts = [Vec2(0, 0), Vec2(20, 40), Vec2(0, 80)]
        let curve = CanvasMath.smooth(pts)
        #expect(curve.first == pts[0])
        #expect(curve.last == pts[2])
        #expect(curve.contains { CanvasMath.dist($0, pts[1]) < 0.01 })
    }

    private func testScene(_ src: String, paint: MermaidTheme = .neutral(dark: true), hover: (MermaidHover, Color)? = nil) -> MermaidScene? {
        guard let parsed = MermaidParser.parse(src) else { return nil }
        return renderScene(parsed, theme: paint, hover: hover)?.withTitle(parsed.title)
    }

    @Test("deep subgraphs fall back cleanly")
    func deepSubgraphsFallBack() {
        let s5000 = "graph TD\n" + String(repeating: "subgraph s\n", count: 5000) + "A\n" + String(repeating: "end\n", count: 5000)
        #expect(testScene(s5000) == nil)
        let s9 = "graph TD\n" + String(repeating: "subgraph s\n", count: 9) + "A\n" + String(repeating: "end\n", count: 9)
        #expect(testScene(s9) == nil)
        let s8 = "graph TD\n" + String(repeating: "subgraph s\n", count: 8) + "A\n" + String(repeating: "end\n", count: 8)
        #expect(testScene(s8) != nil)
    }

    @Test("huge cross product falls back before being built")
    func hugeCrossProductFallsBack() {
        func ids(_ prefix: String, _ n: Int) -> String {
            (1...n).map { "\(prefix)\($0)" }.joined(separator: " & ")
        }
        #expect(testScene("graph TD\n\(ids("A", 500)) --> \(ids("B", 500))") == nil)
        #expect(testScene("graph TD\n\(ids("A", 5000))") == nil)
        #expect(testScene("graph TD\n\(ids("A", 10)) --> \(ids("B", 10))") != nil)
    }

    @Test("huge dash count draws at longest link")
    func hugeDashCountDrawsAtLongestLink() {
        let longest = testScene("graph TD\nA \(String(repeating: "-", count: 10_000))> B")!
        let eight = testScene("graph TD\nA \(String(repeating: "-", count: 9))> B")!
        #expect(longest.size == eight.size)
    }

    @Test("minScale zero fits any width")
    func minScaleZeroFitsAnyWidth() {
        let wideSeq = """
        sequenceDiagram
          autonumber
          participant B as Browser on a laptop
          participant E as Edge cache in front
          participant A as Auth service cluster
          participant P as Payments API server
          participant W as Billing worker pool
          participant S as Search index shard
          participant L as Long-running audit log
          B->>E: a request arrives at the edge
          E->>A: is this session token still valid?
          A-->>E: yes, here is the account scope
          E->>P: forward the call with its scope
          P->>W: enqueue the invoice with the scope
          W->>S: index the invoice
          S-->>W: ok
          W->>L: record the change
          W-->>P: done
          P-->>E: the response
        """
        var narrow = MermaidTheme.neutral(dark: true)
        narrow.maxWidth = 420.0
        let room = narrow.maxWidth - CanvasConstants.cardPad * 2.0
        let floored = testScene(wideSeq, paint: narrow)!
        #expect(abs(floored.scale - 0.6) < 1e-4)
        #expect(floored.size.x > room)

        let fits = testScene(wideSeq, paint: narrow.minScale(0.0))!
        #expect(fits.size.x <= room + 2.01)
        #expect(fits.scale < 0.6)
        #expect(abs(fits.full.y * fits.scale - fits.size.y) < 0.01)

        var roomy = narrow.minScale(0.0)
        roomy.maxWidth = 4000.0
        #expect(testScene(wideSeq, paint: roomy)?.scale == 1.0)
    }

    @Test("drawing and renderMermaid produce valid Rune El trees")
    func drawingAndRenderMermaid() {
        var roomy = MermaidTheme.neutral(dark: true)
        roomy.maxWidth = 4000.0
        let src = "graph TD\nA[Start] --> B[End]"
        let full = testScene(src, paint: roomy)!
        let d: MermaidDrawing<Int> = renderMermaidDrawing(src, theme: roomy)!
        #expect(d.size == full.size)

        let titledSrc = "---\ntitle: Checkout\n---\n\(src)"
        let t: MermaidDrawing<Int> = renderMermaidDrawing(titledSrc, theme: roomy)!
        #expect(t.size.y > d.size.y + 15.0)
        #expect(t.size.x >= d.size.x)

        let el: El<Int>? = renderMermaid(titledSrc, theme: roomy, hover: (.edges, roomy.text))
        #expect(el != nil)
    }
}

func assertPrefixesNeverCrash(_ src: String, dark: Bool) {
    let paint = MermaidTheme.neutral(dark: dark)
    for idx in src.indices {
        let prefix = String(src[..<idx])
        if let parsed = MermaidParser.parse(prefix) {
            _ = renderScene(parsed, theme: paint)
        }
    }
    let finalParsed = MermaidParser.parse(src)
    #expect(finalParsed != nil)
    #expect(renderScene(finalParsed!, theme: paint) != nil)
}
