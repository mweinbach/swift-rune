import Foundation
import Testing
import Rune
@testable import RuneMermaid

@Suite("Layout, Routing, Shapes, Ink, Hover, and Parts Tests")
struct LayoutAndRenderTests {
    // MARK: - Layered Layout

    private func makeGraph(n: Int, edges: [(Int, Int)]) -> LayeredLayout.Graph {
        LayeredLayout.Graph(
            sizes: Array(repeating: Vec2(60, 30), count: n),
            edges: edges.map { LayeredLayout.Edge(from: $0.0, to: $0.1, label: nil, minlen: 1) },
            nodeCluster: Array(repeating: nil, count: n),
            clusters: []
        )
    }

    private let sp = LayeredLayout.Spacing(node: 30.0, rank: 40.0, cluster: 10.0)

    @Test("chain goes down in a straight line")
    func chainGoesDown() {
        let p = LayeredLayout.layout(makeGraph(n: 3, edges: [(0, 1), (1, 2)]), spacing: sp)!
        #expect(p.centers[0].y < p.centers[1].y && p.centers[1].y < p.centers[2].y)
        #expect(abs(p.centers[0].x - p.centers[2].x) < 0.5)
        #expect(p.centers[1].y - p.centers[0].y == 30.0 + 40.0)
    }

    @Test("fork spreads children without overlap and centers parent")
    func forkSpreadsChildren() {
        let p = LayeredLayout.layout(makeGraph(n: 3, edges: [(0, 1), (0, 2)]), spacing: sp)!
        let a = p.centers[1]
        let b = p.centers[2]
        #expect(a.y == b.y)
        #expect(abs(a.x - b.x) >= 90.0 - 0.01)
        #expect(abs(p.centers[0].x - (a.x + b.x) * 0.5) < 1.0)
    }

    @Test("cycles and self-loops lay out")
    func cyclesAndSelfLoops() {
        let p = LayeredLayout.layout(makeGraph(n: 3, edges: [(0, 1), (1, 2), (2, 0), (1, 1)]), spacing: sp)!
        #expect(p.paths.count == 4)
        #expect(p.paths[2].first == p.centers[2])
        #expect(p.paths[2].last == p.centers[0])
        #expect(p.centers.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    @Test("sibling clusters never overlap across layers")
    func siblingClustersNeverOverlap() {
        var g = makeGraph(n: 7, edges: [(0, 1), (2, 3), (2, 4), (0, 2), (3, 5), (4, 5), (4, 6)])
        g.clusters = [
            LayeredLayout.Cluster(parent: nil, lead: Vec2(0, 16), minSpan: .zero),
            LayeredLayout.Cluster(parent: nil, lead: Vec2(0, 16), minSpan: .zero),
        ]
        g.nodeCluster = [0, 0, 1, 1, 1, nil, nil]
        let p = LayeredLayout.layout(g, spacing: sp)!
        let a = p.clusters[0]
        let b = p.clusters[1]
        let apart = a.2 <= b.0 || b.2 <= a.0 || a.3 <= b.1 || b.3 <= a.1
        #expect(apart)
        for v in [5, 6] {
            let c = p.centers[v]
            for bx in [a, b] {
                let inside = c.x > bx.0 && c.x < bx.2 && c.y > bx.1 && c.y < bx.3
                #expect(!inside)
            }
        }
    }

    @Test("isotonic keeps separation and hits free targets")
    func isotonicTest() {
        #expect(LayeredLayout.isotonic(want: [0.0, 100.0], weights: [1.0, 1.0], sep: [10.0]) == [0.0, 100.0])
        #expect(LayeredLayout.isotonic(want: [50.0, 50.0], weights: [1.0, 1.0], sep: [20.0]) == [40.0, 60.0])
    }

    // MARK: - Edge Routing

    private func sharpestTurn(_ pts: [Vec2]) -> Float {
        var dirs: [Float] = []
        for i in 0..<max(0, pts.count - 1) {
            if CanvasMath.dist(pts[i], pts[i + 1]) > 1e-3 {
                dirs.append(atan2f(pts[i + 1].y - pts[i].y, pts[i + 1].x - pts[i].x))
            }
        }
        var maxTurn: Float = 0.0
        for i in 0..<max(0, dirs.count - 1) {
            var a = abs((dirs[i + 1] - dirs[i]) * 180.0 / .pi)
            if a > 180.0 { a = 360.0 - a }
            maxTurn = max(maxTurn, a)
        }
        return maxTurn
    }

    @Test("curves leave and arrive along rank axis")
    func curvesLeaveAndArriveAlongRankAxis() {
        let pts = RouteMath.curve([Vec2(0, 0), Vec2(40, 100), Vec2(40, 200)])
        #expect(pts.first == Vec2(0, 0))
        #expect(pts.last == Vec2(40, 200))
        #expect(abs(pts[1].x - pts[0].x) < abs(pts[1].y - pts[0].y) * 0.05)
        #expect(sharpestTurn(pts) < 6.0)
        #expect(RouteMath.cubic(Vec2(5, 0), Vec2(5, 90)).count == 2)
    }

    @Test("every direction draws smooth edges that reach their nodes")
    func everyDirectionDrawsSmoothEdges() {
        let paint = MermaidTheme.neutral(dark: true)
        for dir in ["TD", "BT", "LR", "RL"] {
            let src = "flowchart \(dir)\n  A[Start] --> B[Left]\n  A --> C[Right]\n  B --> D[End]\n  C -- label --> D\n  A --> D"
            guard case let .flowchart(f)? = MermaidParser.parse(src) else {
                Issue.record("Failed to parse \(dir)")
                continue
            }
            let c = FlowchartParser.drawCanvas(f, paint: paint, hover: (.edges, paint.text))!
            var lines = 0
            for op in c.ops {
                if case let .stroke(points, closed, _, _, color) = op, !closed && color == paint.line {
                    lines += 1
                    #expect(sharpestTurn(points) < 12.0)
                }
            }
            #expect(lines >= 5)
            let tips: [Vec2] = c.ops.compactMap { op in
                if case let .fill(p, col) = op, col == paint.line && p.count == 3 { return p[0] }
                return nil
            }
            #expect(tips.count == 5)
        }
    }

    @Test("labels break the line instead of covering it")
    func labelsBreakLine() {
        let rect: (Float, Float, Float, Float) = (10.0, 40.0, 30.0, 60.0)
        let runs = ConnectorRenderer.outside(curve: [Vec2(20, 0), Vec2(20, 50), Vec2(20, 100)], rect: rect)
        #expect(runs.count == 2)
        #expect(abs((runs[0].last?.y ?? 0) - 40.0) < 0.1)
        #expect(abs((runs[1].first?.y ?? 0) - 60.0) < 0.1)
        #expect(ConnectorRenderer.outside(curve: [Vec2(0, 0), Vec2(0, 9)], rect: rect).count == 1)
    }

    // MARK: - Shapes

    private let allShapes: [NodeShape] = [
        .rect, .round, .stadium, .subroutine, .cylinder, .circle, .doubleCircle, .asymmetric,
        .diamond, .hexagon, .leanRight, .leanLeft, .trapBottom, .trapTop, .smallCircle,
        .filledCircle, .framedCircle, .crossedCircle, .bang, .cloud, .card, .hourglass,
        .bolt, .braceLeft, .braceRight, .braces, .delay, .hCylinder, .linedCylinder,
        .curvedTrapezoid, .dividedRect, .document, .linedDocument, .documents, .taggedDocument,
        .triangle, .flippedTriangle, .fork, .windowPane, .linedRect, .notchedPentagon,
        .slopedRect, .stackedRect, .flag, .bowRect, .taggedRect, .text, .note,
    ]

    private func insideBox(_ p: Vec2, center c: Vec2, size s: Vec2, slack: Float) -> Bool {
        abs(p.x - c.x) <= s.x * 0.5 + slack && abs(p.y - c.y) <= s.y * 0.5 + slack
    }

    @Test("every shape stays in its box and holds its label")
    func everyShapeStaysInBox() {
        let paint = MermaidTheme.neutral(dark: false)
        let label = measureText("Process step", font: paint.font)
        let c = Vec2(100, 80)
        for shape in allShapes {
            let size = ShapeRenderer.nodeSize(shape, labelSize: label.size)
            let poly = ShapeRenderer.outline(shape: shape, center: c, size: size)
            #expect(poly.count >= 3)
            #expect(poly.allSatisfy { insideBox($0, center: c, size: size, slack: 0.5) })
            var canvas = Canvas()
            ShapeRenderer.draw(into: &canvas, shape: shape, label: label, center: c, size: size, colors: (paint.nodeFill, paint.nodeBorder, paint.text), paint: paint)
            for op in canvas.ops {
                let pts: [Vec2] = switch op {
                case let .fill(p, _), let .stroke(p, _, _, _, _): p
                }
                #expect(pts.allSatisfy { insideBox($0, center: c, size: size, slack: 0.5) })
            }
            if shape.isUnlabelled {
                #expect(canvas.labels.isEmpty)
            } else {
                let l = canvas.labels[0]
                #expect(insideBox(l.at, center: c, size: size, slack: 0.5))
                #expect(insideBox(Vec2(l.at.x + l.size.x, l.at.y + l.size.y), center: c, size: size, slack: 0.5))
            }
        }
    }

    @Test("boundary points stay on or in the box")
    func boundaryPointsStayInBox() {
        let c = Vec2.zero
        for shape in allShapes {
            let size = ShapeRenderer.nodeSize(shape, labelSize: Vec2(80, 18))
            for toward in [Vec2(0, 200), Vec2(0, -200), Vec2(200, 0), Vec2(-150, 90)] {
                let b = ShapeRenderer.boundary(shape: shape, center: c, size: size, toward: toward)
                #expect(insideBox(b, center: c, size: size, slack: 0.5))
                #expect(abs(b.x) + abs(b.y) > 3.0)
            }
        }
    }

    // MARK: - Ink, Hover, Lenient, Parts

    @Test("every diagram draws opaque ink over an opaque surface")
    func everyDiagramDrawsOpaqueInk() {
        let sources = [
            "flowchart LR\n  R1[Retry at once] -->|fails| R2[Back off 1 s]\n  R2 -->|fails| Off[Offline]",
            "flowchart TD\n  subgraph S [Box]\n    A --> B\n  end\n  B -.-> C\n  C ==> A",
            "sequenceDiagram\n  participant A\n  participant B\n  A->>B: hi\n  B-->>A: back\n  Note over A,B: note",
            "stateDiagram-v2\n  [*] --> Idle\n  Idle --> Busy : go\n  Busy --> [*]",
            "classDiagram\n  Animal <|-- Duck\n  Animal *-- Leg\n  class Animal {\n    +int age\n    +eat()\n  }",
            "erDiagram\n  CUSTOMER ||--o{ ORDER : places\n  ORDER ||--|{ LINE : contains",
        ]
        for dark in [true, false] {
            let paint = MermaidTheme.neutral(dark: dark)
            #expect(paint.surface.a == 1.0)
            for src in sources {
                let parsed = MermaidParser.parse(src)!
                let s = renderScene(parsed, theme: paint)!
                for op in s.ops {
                    switch op {
                    case let .stroke(_, _, _, _, color):
                        #expect(color.a == 1.0)
                    case let .fill(points, color) where points.count == 3:
                        #expect(color.a == 1.0)
                    default:
                        break
                    }
                }
            }
        }
    }

    @Test("hover spots light edges and labels without overlapping nodes")
    func hoverSpotsLightEdgesAndLabels() {
        let paint = MermaidTheme.neutral(dark: false)
        let parsed = MermaidParser.parse("stateDiagram-v2\n  Idle --> Busy : start\n  Busy --> Done")!
        let s = renderScene(parsed, theme: paint, hover: (.edges, Color(r: 0.9, g: 0.2, b: 0.5, a: 1.0)))!
        let startIdx = s.labels.firstIndex { $0.text == "start" }!
        let first = s.hovers.filter { $0.key.hasPrefix("hover:e:Idle>Busy.") }
        #expect(first.count >= 2)
        #expect(first.allSatisfy { $0.labels == [startIdx] })
    }

    @Test("lenient reader undoes unreadable statements and their bodies")
    func lenientReaderTest() {
        struct Words: LenientParser {
            var items: [String] = []
            var limit: Int = 0
            func mark() -> Int { items.count }
            mutating func undo(_ mark: Int) {
                if items.count > mark { items.removeSubrange(mark...) }
            }
            mutating func readStatement(_ s: String) -> Bool {
                items.append(s)
                return !s.hasPrefix("!") && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "{" || $0 == "}" || $0 == " " }
            }
            func isOverLimit() -> Bool {
                limit > 0 && items.count > limit
            }
        }

        var reader = LenientReader()
        var parser = Words()
        for s in ["a", "!bad {", "inner {", "x", "}", "y", "}", "b", "!also bad", "c"] {
            #expect(reader.read(&parser, statement: s))
        }
        #expect(parser.items == ["a", "b", "c"])

        var bounded = Words(limit: 2)
        var r2 = LenientReader()
        var ok = true
        for s in ["a", "b", "!c", "d"] {
            ok = r2.read(&bounded, statement: s)
            if !ok { break }
        }
        #expect(!ok)
    }

    @Test("flowchart pieces are keyed by mermaid id across rebuilds")
    func flowchartPiecesKeyedById() {
        let paint = MermaidTheme.neutral(dark: true)
        func keys(_ src: String) -> [String] {
            let s = renderScene(MermaidParser.parse(src)!, theme: paint, hover: (.edges, paint.text))!
            return s.pieces.map(\.key) + s.labelKeys.map(\.key)
        }
        let a = keys("graph TD\n  A[Start] --> B{Ok?}\n")
        for want in ["n:A", "n:B", "e:A>B", "n:A.t0", "n:B.t0"] {
            #expect(a.contains(want))
        }
        let b = keys("graph TD\n  A[Start] --> B{Ok?}\n  B -->|yes| C[Done]\n  B --> C\n")
        for prev in a {
            #expect(b.contains(prev))
        }
        for want in ["n:C", "e:B>C", "e:B>C~1", "e:B>C.t0"] {
            #expect(b.contains(want))
        }
    }
}
