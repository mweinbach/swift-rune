import Foundation
import Testing
import Rune
@testable import RuneMermaid

@Suite("Flowchart Tests")
struct FlowchartTests {
    private func flow(_ src: String) -> FlowchartDiagram {
        guard case let .flowchart(f)? = MermaidParser.parse(src) else {
            Issue.record("Not a flowchart: \(src)")
            fatalError("Not a flowchart")
        }
        return f
    }

    private func edges(_ f: FlowchartDiagram) -> [(String, String)] {
        f.edges.map { (f.nodes[$0.from].id, f.nodes[$0.to].id) }
    }

    @Test("directions, shapes, and labels")
    func directionsShapesAndLabels() {
        let f = flow("""
        flowchart LR
          A[Start] --> B(Round)
          B --> C([Stadium]) --> D[[Sub]]
          D --> E[(Database)] & F((Circle))
          F --> G>Flag] --> H{Decide?} --> I{{Hex}}
          I --> J[/Lean/] --> K[/Trap\\]
          K --> L[\\Back\\] --> M[\\Top/] --> N(((Stop)))
        """)
        #expect(f.dir == .right)
        let shapes = f.nodes.map { ($0.id, $0.label, $0.shape) }
        let expected: [(String, String, NodeShape)] = [
            ("A", "Start", .rect),
            ("B", "Round", .round),
            ("C", "Stadium", .stadium),
            ("D", "Sub", .subroutine),
            ("E", "Database", .cylinder),
            ("F", "Circle", .circle),
            ("G", "Flag", .asymmetric),
            ("H", "Decide?", .diamond),
            ("I", "Hex", .hexagon),
            ("J", "Lean", .leanRight),
            ("K", "Trap", .trapBottom),
            ("L", "Back", .leanLeft),
            ("M", "Top", .trapTop),
            ("N", "Stop", .doubleCircle),
        ]
        #expect(shapes.count == expected.count)
        for (got, want) in zip(shapes, expected) {
            #expect(got == want)
        }
        let e = edges(f)
        #expect(e[3].0 == "D" && e[3].1 == "E")
        #expect(e[4].0 == "D" && e[4].1 == "F")
    }

    @Test("v11 @shapes, subgraph endpoints, and link styles")
    func v11AtShapesSubgraphEndpointsAndLinkStyles() {
        let f = flow("""
        flowchart TD
          App[Viewer] --> core
          subgraph core [Rune Core]
            El[El tree] --> Store@{ shape: cyl, label: "AnimationStore" }
          end
          core --> GPU@{ shape: hex, label: "wgpu" }
          linkStyle 0 stroke:#22c55e,stroke-width:2px
        """)
        #expect(f.nodes.count == 4)
        let e = edges(f)
        #expect(e.count == 3)
        #expect(e[0] == ("App", "El"))
        #expect(e[1] == ("El", "Store"))
        #expect(e[2] == ("Store", "GPU"))
        let store = f.nodes.first { $0.id == "Store" }!
        #expect(store.shape == .cylinder)
        #expect(store.label == "AnimationStore")
        #expect(f.edges[0].style.stroke != nil)
        #expect(f.edges[0].style.width == 2.0)
    }

    @Test("every v11 shape name reads and draws")
    func everyV11ShapeNameReadsAndDraws() {
        let names: [(String, NodeShape)] = [
            ("rect", .rect), ("event", .round), ("pill", .stadium), ("subproc", .subroutine),
            ("db", .cylinder), ("circ", .circle), ("dbl-circ", .doubleCircle), ("odd", .asymmetric),
            ("question", .diamond), ("prepare", .hexagon), ("in-out", .leanRight), ("out-in", .leanLeft),
            ("priority", .trapBottom), ("manual", .trapTop), ("start", .smallCircle), ("junction", .filledCircle),
            ("stop", .framedCircle), ("summary", .crossedCircle), ("bang", .bang), ("cloud", .cloud),
            ("card", .card), ("collate", .hourglass), ("com-link", .bolt), ("comment", .braceLeft),
            ("brace-r", .braceRight), ("braces", .braces), ("delay", .delay), ("das", .hCylinder),
            ("disk", .linedCylinder), ("display", .curvedTrapezoid), ("div-proc", .dividedRect),
            ("document", .document), ("lin-doc", .linedDocument), ("docs", .documents),
            ("tag-doc", .taggedDocument), ("extract", .triangle), ("manual-file", .flippedTriangle),
            ("join", .fork), ("internal-storage", .windowPane), ("shaded-process", .linedRect),
            ("loop-limit", .notchedPentagon), ("manual-input", .slopedRect), ("processes", .stackedRect),
            ("paper-tape", .flag), ("stored-data", .bowRect), ("tag-rect", .taggedRect), ("text", .text),
        ]
        var src = "flowchart TD\n"
        for (i, (name, _)) in names.enumerated() {
            src += "  n\(i)@{ shape: \(name), label: \"Step \(i)\" }\n"
            if i > 0 { src += "  n\(i - 1) --> n\(i)\n" }
        }
        let f = flow(src)
        #expect(f.nodes.map(\.shape) == names.map(\.1))
        #expect(f.nodes.allSatisfy { $0.label.hasPrefix("Step ") })
        #expect(FlowchartParser.draw(f, paint: .neutral(dark: false), hover: nil) != nil)
    }

    @Test("icons and images draw as their frame")
    func iconsAndImages() {
        let f = flow("""
        flowchart TD
          A@{ icon: "fa:user", form: "circle", label: "User" }
          B@{ img: "https://example.com/a.png", label: "Pic" }
          A --> B
        """)
        #expect(f.nodes.map { ($0.label, $0.shape) }.elementsEqual([("User", .circle), ("Pic", .rect)], by: ==))
    }

    @Test("named edges and their settings add no nodes")
    func namedEdges() {
        let f = flow("flowchart LR\n  A e1@--> B\n  B e2@-.-> C\n  e1@{ animate: true }\n  e2@{ animation: fast }")
        #expect(edges(f).count == 2)
        #expect(f.edges[1].line == .dotted)
        #expect(f.nodes.count == 3)
    }

    @Test("link styles, heads, lengths, and labels")
    func linkStylesHeadsLengthsLabels() {
        let f = flow("""
        graph TD
        A --> B
        A --- C
        A -.-> D
        A ==> E
        A -- yes --> F
        A -->|no| G
        A <--> H
        A --o I
        A --x J
        A ---> K
        A -. maybe .-> L
        A == sure ==> M
        A ~~~ N
        A-->O;O-->P
        """)
        func edge(to id: String) -> LayeredEdge {
            f.edges.first { f.nodes[$0.to].id == id }!
        }
        #expect((edge(to: "B").line, edge(to: "B").end, edge(to: "B").minlen) == (.solid, .arrow, 1))
        #expect((edge(to: "C").line, edge(to: "C").end) == (.solid, .none))
        #expect((edge(to: "D").line, edge(to: "D").end) == (.dotted, .arrow))
        #expect((edge(to: "E").line, edge(to: "E").end) == (.thick, .arrow))
        #expect(edge(to: "F").label == "yes")
        #expect(edge(to: "G").label == "no")
        #expect((edge(to: "H").start, edge(to: "H").end) == (.arrow, .arrow))
        #expect(edge(to: "I").end == .circle)
        #expect(edge(to: "J").end == .cross)
        #expect(edge(to: "K").minlen == 2)
        #expect((edge(to: "L").line, edge(to: "L").label) == (.dotted, "maybe"))
        #expect((edge(to: "M").line, edge(to: "M").label) == (.thick, "sure"))
        #expect(edge(to: "N").line == .invisible)
        #expect(edge(to: "P").from == f.nodes.firstIndex { $0.id == "O" })
    }

    @Test("subgraphs nest and claim nodes")
    func subgraphsNestAndClaimNodes() {
        let f = flow("""
        graph TB
          c1-->a2
          subgraph one [The first]
            a1-->a2
            subgraph inner
              x1
            end
          end
          subgraph "two"
            b1-->b2
          end
          classDef hot fill:#f00
          class a1 hot
          style b1 fill:#0f0
          click b2 callback
          a1:::hot --> b1
        """)
        #expect(f.subgraphs.map(\.title) == ["The first", "inner", "two"])
        #expect(f.subgraphs[1].parent == 0)
        func cluster(_ id: String) -> Int? { f.nodes.first { $0.id == id }?.cluster }
        #expect(cluster("c1") == nil)
        #expect(cluster("a2") == 0)
        #expect(cluster("x1") == 1)
        #expect(cluster("b2") == 2)
        #expect(f.nodes.first { $0.id == "a1" }?.style.fill != nil)
        #expect(f.nodes.first { $0.id == "b1" }?.style.fill != nil)
    }

    @Test("unclosed shapes and punctuation in labels")
    func unclosedShapesAndPunctuation() {
        let f = flow("flowchart LR\n  A[List + count] --> B[/items split view]\n  B --> C[Details]\n  C --> D[Pause / Resume / Delete]")
        #expect(f.nodes.map(\.shape) == [.rect, .rect, .rect, .rect])
        #expect(f.nodes[1].label == "/items split view")
        #expect(FlowchartParser.draw(f, paint: .neutral(dark: true), hover: nil) != nil)
    }

    @Test("bounds reject deep or wide flowcharts")
    func boundsReject() {
        let deep = (0...MermaidLimits.maxDepth).map { "subgraph s\($0)\nA\($0)" }.joined(separator: "\n")
        #expect(MermaidParser.parse("graph TD\n\(deep)") == nil)
        let wide = (0..<MermaidLimits.maxItems).map { "N\($0) --> M\($0)" }.joined(separator: "\n")
        #expect(MermaidParser.parse("graph TD\n\(wide)") == nil)
    }

    @Test("quoted edge labels, nested brackets, styles, and dashed ids")
    func quotedEdgeLabelsAndDashedIds() {
        let f = flow("""
        flowchart LR
         A[Audio] --> B[Parakeet writes text<br/>'went to the capuchin']
         B --> C{Any word that looks<br/>or sounds like a term?}
         C -- no --> F[Paste as is]
         C -- "capuchin ≈ Cappuccino" --> D[Score the same audio twice:<br/>as 'capuchin' and as 'Cappuccino']
         D --> E(Call fn(x)) --> G[items[0]]
         G -->|"a | b"| F
         style D fill:#dcf5dc
        """)
        let toD = f.edges.first { f.nodes[$0.to].id == "D" }
        #expect(toD?.label == "capuchin ≈ Cappuccino")
        let toF = f.edges.last { f.nodes[$0.to].id == "F" }
        #expect(toF?.label == "a | b")
        #expect(f.nodes.first { $0.id == "E" }?.label == "Call fn(x)")
        #expect(f.nodes.first { $0.id == "G" }?.label == "items[0]")
        #expect(f.nodes.first { $0.id == "D" }?.style.fill != nil)

        let dashed = flow("graph TD\n  web-server[\"Web (edge) server\"] --> db[(\"Postgres<br/>primary\")]")
        #expect(dashed.nodes[0].id == "web-server")
        #expect(dashed.nodes[0].label == "Web (edge) server")
        #expect(dashed.nodes[1].label == "Postgres\nprimary")
    }

    @Test("every prefix parses or falls back without crashing")
    func prefixesNeverCrash() {
        assertPrefixesNeverCrash(
            "flowchart TD\n  A[Start] -->|go| B{Ok?}\n  B -- yes --> C([Done])\n  B -.->|no| A\n  subgraph s [Group]\n    C --> D[(Store)]\n  end",
            dark: false
        )
    }
}
