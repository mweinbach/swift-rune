import Foundation
import Testing
import Rune
@testable import RuneMermaid

@Suite("Mermaid Parity Tests", .serialized)
struct MermaidParityTests {
    private let light = MermaidTheme.neutral(dark: false)
    private let dark = MermaidTheme.neutral(dark: true)

    private func scene(_ src: String, paint: MermaidTheme = .neutral(dark: true), hover: (MermaidHover, Color)? = nil) -> MermaidScene? {
        guard let parsed = MermaidParser.parse(src) else { return nil }
        return renderScene(parsed, theme: paint, hover: hover)?.withTitle(parsed.title)
    }

    // MARK: - P0/P1 Core Rendering & Titles

    @Test("front-matter titles work across all 17 diagram families")
    func frontMatterTitlesAcrossFamilies() {
        let samples: [String] = [
            "---\ntitle: Flow Title\n---\nflowchart TD\nA --> B",
            "---\ntitle: Seq Title\n---\nsequenceDiagram\nA->>B: hi",
            "---\ntitle: State Title\n---\nstateDiagram-v2\nIdle --> Busy",
            "---\ntitle: Class Title\n---\nclassDiagram\nA <|-- B",
            "---\ntitle: ER Title\n---\nerDiagram\nCUSTOMER ||--o{ ORDER : places",
            "---\ntitle: Gantt Title\n---\ngantt\nTask :2024-01-01, 2d",
            "---\ntitle: Pie Title\n---\npie\n\"A\" : 10\n\"B\" : 20",
            "---\ntitle: Mindmap Title\n---\nmindmap\n  root\n    child",
            "---\ntitle: Timeline Title\n---\ntimeline\n2024 : Launch",
            "---\ntitle: Journey Title\n---\njourney\nsection Day\nTea: 5: Me",
            "---\ntitle: Git Title\n---\ngitGraph\ncommit id: \"init\"",
            "---\ntitle: Quadrant Title\n---\nquadrantChart\nPoint A: [0.5, 0.5]",
            "---\ntitle: XY Title\n---\nxychart-beta\nx-axis [a, b]\nbar [1, 2]",
            "---\ntitle: Sankey Title\n---\nsankey-beta\nA,B,10",
            "---\ntitle: Block Title\n---\nblock-beta\nA B",
            "---\ntitle: Req Title\n---\nrequirementDiagram\nrequirement r {\nid: 1\n}",
            "---\ntitle: C4 Title\n---\nC4Context\nPerson(u, \"User\")",
        ]
        for src in samples {
            let parsed = MermaidParser.parse(src)
            #expect(parsed != nil, "Expected parse success for:\n\(src)")
            #expect(parsed?.title != nil, "Expected front-matter title on:\n\(src)")
            if let parsed {
                let s = renderScene(parsed, theme: dark)?.withTitle(parsed.title)
                #expect(s != nil, "Expected scene for:\n\(src)")
                #expect(s?.title == parsed.title)
                let drawing: MermaidDrawing<Int>? = renderMermaidDrawing(src, theme: dark)
                #expect(drawing != nil)
            }
        }
    }

    @Test("hover defaults to edges unless Hover.off is requested and edges enter with .draw")
    func hoverDefaultsAndEdgeTransition() {
        #expect(resolvedHover(nil, theme: dark) != nil)
        #expect(resolvedHover((.off, .white), theme: dark) == nil)
        let src = "flowchart TD\nA --> B"
        let s = scene(src, paint: dark, hover: resolvedHover(nil, theme: dark))!
        #expect(!s.hovers.isEmpty)
        let sOff = scene(src, paint: dark, hover: resolvedHover((.off, .white), theme: dark))!
        #expect(sOff.hovers.isEmpty)
        #expect(PartKind.edge.enter == .draw)
    }

    @Test("streaming renderers use streaming=true and renderMermaid handles Hover.off")
    func streamingRenderersAndHoverOff() {
        let src = "flowchart TD\nA[Start] --> B[End]"
        let elOff: El<Int>? = renderMermaid(src, theme: dark, hover: (.off, .white))
        #expect(elOff != nil)
        let elStream: El<Int>? = renderMermaidStreaming(src, theme: dark)
        let elStreamed: El<Int>? = renderMermaidStreamed(src, theme: dark)
        #expect(elStream != nil)
        #expect(elStreamed != nil)
    }

    // MARK: - State Notes, Regions & Parsing Parity

    @Test("state notes sit beside their state on a dotted line")
    func stateNotesSitBesideTheirState() throws {
        guard case let .state(s)? = MermaidParser.parse(
            "stateDiagram-v2\n  Idle --> Busy\n  note right of Idle : waits here\n  note left of Busy\n    does the work\n    then stops\n  end note"
        ) else {
            Issue.record("Expected state diagram")
            return
        }
        let notes = s.nodes.filter { $0.kind == .note }.map(\.label)
        #expect(notes == ["waits here", "does the work\nthen stops"])
        let dotted = s.edges.filter { $0.line == .dotted }.map { (s.nodes[$0.from].id, s.nodes[$0.to].id) }
        #expect(dotted.count == 2)
        #expect(dotted[0].0 == "Idle")
        #expect(dotted[1].1 == "Busy")
        #expect(s.edges.filter { $0.line == .dotted }.allSatisfy { $0.end == .none })
        let sc = renderScene(.state(s), theme: light)
        #expect(sc != nil)
        #expect(sc?.labels.contains { $0.text == "waits here" } == true)
        #expect(sc?.labels.contains { $0.text.contains("does the work") } == true)

        guard case let .state(open)? = MermaidParser.parse("stateDiagram-v2\nnote right of A\n  never closed") else {
            Issue.record("Expected unclosed note state diagram")
            return
        }
        #expect(open.nodes.filter { $0.kind == .note }.count == 1)
    }

    @Test("state concurrent regions split a composite cleanly")
    func stateConcurrentRegionsSplitComposite() {
        guard case let .state(s)? = MermaidParser.parse("""
            stateDiagram-v2
              [*] --> Active
              state Active {
                [*] --> NumOff
                NumOff --> NumOn
                --
                [*] --> CapsOff
                CapsOff --> CapsOn
                --
                [*] --> ScrollOff
              }
              Active --> Done
            """) else {
            Issue.record("Expected state diagram")
            return
        }
        let regions = s.clusters.indices.filter { s.clusters[$0].isRegion }
        #expect(regions.count == 3)
        #expect(regions.allSatisfy { s.clusters[$0].parent == 0 })
        func regionOf(_ id: String) -> Int? { s.nodes.first { $0.id == id }?.cluster }
        #expect(regionOf("NumOn") == regions[0])
        #expect(regionOf("CapsOn") == regions[1])
        #expect(regionOf("ScrollOff") == regions[2])
        #expect(regionOf("Done") == nil)
        #expect(!s.nodes.contains { $0.id == "Active" })

        let drawn = s.edges.filter { $0.line == .solid && s.nodes[$0.to].id == "Done" }
            .map { (s.nodes[$0.from].id, s.nodes[$0.to].id) }
        #expect(drawn.count == 1 && drawn[0] == ("NumOn", "Done"))
        let held = s.edges.filter { $0.line == .invisible && s.nodes[$0.to].id == "Done" }
            .map { (s.nodes[$0.from].id, s.nodes[$0.to].id) }
        #expect(held.count == 2)
        #expect(held[0] == ("CapsOn", "Done") && held[1] == ("ScrollOff", "Done"))
        let invisibleStarts = s.edges.filter {
            $0.line == .invisible && s.nodes[$0.from].kind == .start && s.nodes[$0.from].cluster == nil
        }
        #expect(invisibleStarts.count == 2)
        #expect(renderScene(.state(s), theme: dark) != nil)

        guard case let .state(back)? = MermaidParser.parse(
            "stateDiagram-v2\n  [*] --> Busy\n  state Busy {\n    [*] --> A\n    --\n    [*] --> B\n  }\n  Busy --> Check\n  Check --> Busy : retry"
        ) else {
            Issue.record("Expected retry state diagram")
            return
        }
        #expect(back.edges.filter { $0.line == .invisible }.count == 2)
    }

    @Test("state parsing rejects empty sources and skips invalid statements")
    func stateRejectsAndSkips() {
        for src in ["stateDiagram-v2", "stateDiagram\n}", "stateDiagram-v2\n-->\n--"] {
            #expect(MermaidParser.parse(src) == nil)
        }
        guard case let .state(open)? = MermaidParser.parse("stateDiagram-v2\nstate Open {\n  A --> B") else {
            Issue.record("Expected open composite")
            return
        }
        #expect((open.nodes.count, open.edges.count, open.clusters.count) == (2, 1, 1))

        guard case let .state(badDir)? = MermaidParser.parse("stateDiagram-v2\ndirection diagonal\nA --> B") else {
            Issue.record("Expected bad direction skipped")
            return
        }
        #expect(badDir.dir == .down && badDir.edges.count == 1)

        guard case let .state(unnamed)? = MermaidParser.parse("stateDiagram-v2\nstate \"no id\" {\n  A --> B\n}\nC --> A") else {
            Issue.record("Expected unnamed composite")
            return
        }
        #expect(unnamed.clusters[0].label == "no id")
        #expect(unnamed.nodes.filter { $0.cluster == nil }.count == 1)

        guard case let .state(skipped)? = MermaidParser.parse(
            "stateDiagram-v2\nstate Outer {\n  state Bad<<x {\n    A --> B\n  }\n  C --> D\n}\nE --> F"
        ) else {
            Issue.record("Expected skipped block")
            return
        }
        func cluster(_ id: String) -> Int?? { skipped.nodes.first { $0.id == id }.map(\.cluster) }
        #expect(cluster("A") == nil)
        #expect(cluster("C") == .some(0))
        #expect(cluster("E") == .some(nil))

        assertPrefixesNeverCrash(
            "stateDiagram-v2\n  [*] --> Idle\n  Idle --> Busy : prompt\n  Busy --> Idle : done\n  Idle --> [*]",
            dark: false
        )
    }

    // MARK: - Flowchart Parity

    @Test("flowchart rejects unreadable sources, handles unclosed shapes, punctuation, and lenient skip")
    func flowchartParityCases() {
        for src in ["graph TD", "graph TD\nend", "graph TD\n-->", "graph LR\n  this is not valid", "graph TD\n%% just a comment", "notADiagram\nA --> B"] {
            #expect(MermaidParser.parse(src) == nil)
        }

        func flow(_ src: String) -> FlowchartDiagram {
            guard case let .flowchart(f)? = MermaidParser.parse(src) else {
                fatalError("Not a flowchart: \(src)")
            }
            return f
        }

        #expect(flow("graph TD\nA[\\back slash]").nodes[0].label == "\\back slash")
        #expect(flow("graph TD\nA(open round").nodes[0].label == "open round")
        #expect(flow("graph TD\nA[unclosed --> B").nodes[0].label == "unclosed --> B")
        #expect(flow("flowchart TD\n  A{\"quote never closes} --> B").nodes[0].label == "\"quote never closes} --> B")
        #expect(flow("graph TD\nA@{ shape: not_a_shape } --> B").nodes[0].shape == .rect)
        #expect(flow("graph TD\nA@{ unclosed --> B").nodes[0].label == "A")

        let punct = "flowchart LR\n  a[setting.some_name] --> b[run_* + /go]\n  c[(store -> row)] --> d[Item.Worker]\n  d --> e[/api/v2/item]"
        let pf = flow(punct)
        #expect(pf.nodes.map(\.shape) == [.rect, .rect, .cylinder, .rect, .rect])
        #expect(pf.nodes.map(\.label) == ["setting.some_name", "run_* + /go", "store -> row", "Item.Worker", "/api/v2/item"])
        #expect(scene(punct, paint: light) != nil)

        for (src, want) in [
            ("graph XY\nA-->B", [("A", "B")]),
            ("graph TD\nA -- --> B\nC --> D", [("C", "D")]),
            ("graph TD\nA -->|unclosed B\nC --> D", [("C", "D")]),
            ("graph TD\nA - B\nC --> D", [("C", "D")]),
            ("graph TD\nsubgraph open\n  A --> B", [("A", "B")]),
            ("graph TD\nend\nA --> B\nend", [("A", "B")]),
            ("graph TD\nA --> \nC --> D", [("C", "D")]),
        ] {
            let f = flow(src)
            let got = f.edges.map { (f.nodes[$0.from].id, f.nodes[$0.to].id) }
            #expect(got.count == want.count && zip(got, want).allSatisfy(==), "Mismatch for \(src)")
        }
    }

    @Test("boundary points sit on the outline")
    func boundaryPointsSitOnOutline() {
        let c = Vec2.zero
        #expect(ShapeRenderer.boundary(shape: .rect, center: c, size: Vec2(100, 40), toward: Vec2(0, 100)) == Vec2(0, 20))
        #expect(ShapeRenderer.boundary(shape: .rect, center: c, size: Vec2(100, 40), toward: Vec2(100, 0)) == Vec2(50, 0))
        let d = ShapeRenderer.boundary(shape: .diamond, center: c, size: Vec2(100, 40), toward: Vec2(100, 40))
        #expect(abs(abs(d.x) / 50.0 + abs(d.y) / 20.0 - 1.0) < 1e-4)
        let e = ShapeRenderer.boundary(shape: .circle, center: c, size: Vec2(40, 40), toward: Vec2(30, 40))
        #expect(abs(CanvasMath.dist(c, e) - 20.0) < 1e-4)
    }

    // MARK: - Core Bounds, Guards & Scaling

    @Test("long chords fall back, bounded dense/nested charts finish fast, and dashes cap on huge/non-finite")
    func coreGuardsAndScale() {
        let chain = (0..<129).map { "N\($0) --> N\($0 + 1)" }.joined(separator: "\n")
        let chords = (0..<140).map { "N\($0 % 10) --> N\(120 + $0 % 10)" }.joined(separator: "\n")
        #expect(scene("graph TD\n\(chain)\n\(chords)") == nil)
        let shortChords = (0..<4).map { "N\($0) --> N\(30 + $0)" }.joined(separator: "\n")
        let chain40 = (0..<40).map { "N\($0) --> N\($0 + 1)" }.joined(separator: "\n")
        #expect(scene("graph TD\n\(chain40)\n\(shortChords)") != nil)

        var denseLines = ["graph LR"]
        for i in 0..<130 {
            denseLines.append("N\(i) --> N\((i * 7 + 1) % 130) & N\((i * 13 + 5) % 130)")
        }
        let dense = denseLines.joined(separator: "\n")
        #expect(MermaidParser.parse(dense) != nil)
        #expect(scene(dense) == nil)

        var big = "graph TD\nsubgraph left\n"
        for i in 0..<59 {
            big += "N\(i) --> N\(i + 1)\n"
            if i == 30 { big += "end\nsubgraph right\n" }
        }
        big += "end\n"
        for k in 0..<40 {
            big += "N\(k % 20) --> N\(k % 20 + 37)\n"
        }
        #expect(scene(big) != nil)

        #expect(scene("sequenceDiagram\n" + String(repeating: "create ", count: 10_000) + "participant A\nA->>B: hi") != nil)
        #expect(scene("sequenceDiagram\nA->>B: hi\ncreate actor C as Carol\nB->>C: hello") != nil)

        for end in [Float(1e9), Float.infinity, Float.nan] {
            var c = Canvas()
            c.dashed([.zero, Vec2(end, 0)], width: 1.0, color: .black, on: 4.0, off: 3.0)
            #expect(c.ops.count <= 20_000)
        }
    }

    @Test("lines shrink proportionally with the drawing")
    func linesShrinkWithDrawing() {
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
        var narrow = dark
        narrow.maxWidth = 420.0
        narrow = narrow.minScale(0.0)
        var roomy = narrow
        roomy.maxWidth = 4000.0
        let small = scene(wideSeq, paint: narrow)!
        let full = scene(wideSeq, paint: roomy)!
        #expect(small.scale < 0.5)
        #expect(small.pieces.count == full.pieces.count)
        for (a, b) in zip(small.pieces, full.pieces) {
            #expect(a.key == b.key)
            #expect(abs(a.size.x - b.size.x) < 0.01 && abs(a.size.y - b.size.y) < 0.01)
        }
    }

    // MARK: - Layered & Drawing Geometry

    @Test("interleaved subgraphs keep one order and clusters contain members")
    func layeredSubgraphsAndClusters() {
        let sp = LayeredLayout.Spacing(node: 30.0, rank: 40.0, cluster: 10.0)
        let edges = [
            (2, 3), (3, 6), (8, 9), (9, 10), (9, 6), (6, 7), (5, 7), (4, 7), (10, 11), (6, 11),
            (10, 12), (10, 13), (12, 14), (13, 14), (14, 15), (14, 16), (15, 17), (16, 17),
            (6, 17), (5, 17), (17, 18), (18, 19),
        ]
        let g = LayeredLayout.Graph(
            sizes: Array(repeating: Vec2(60, 30), count: 24),
            edges: edges.map { LayeredLayout.Edge(from: $0.0, to: $0.1, label: nil, minlen: 1) },
            nodeCluster: (0..<24).map { v in
                switch v {
                case 0...1: 0
                case 2...7: 1
                case 8...11: 2
                case 12...19: 3
                default: 4
                }
            },
            clusters: Array(repeating: LayeredLayout.Cluster(parent: nil, lead: Vec2(0, 16), minSpan: .zero), count: 5)
        )
        let p = LayeredLayout.layout(g, spacing: sp)!
        for a in 0..<5 {
            for b in (a + 1)..<5 {
                let x = p.clusters[a], y = p.clusters[b]
                let apart = x.2 <= y.0 || y.2 <= x.0 || x.3 <= y.1 || y.3 <= x.1
                #expect(apart, "Subgraphs \(a) and \(b) overlap")
            }
        }

        let g2 = LayeredLayout.Graph(
            sizes: Array(repeating: Vec2(60, 30), count: 4),
            edges: [(0, 1), (0, 2), (0, 3)].map { LayeredLayout.Edge(from: $0.0, to: $0.1, label: nil, minlen: 1) },
            nodeCluster: [nil, 0, nil, 0],
            clusters: [LayeredLayout.Cluster(parent: nil, lead: Vec2(0, 16), minSpan: .zero)]
        )
        let p2 = LayeredLayout.layout(g2, spacing: sp)!
        let b = p2.clusters[0]
        for v in [1, 3] {
            let c = p2.centers[v]
            #expect(c.x - 30.0 >= b.0 && c.x + 30.0 <= b.2 && c.y - 15.0 >= b.1 + 16.0)
        }
        let c2 = p2.centers[2]
        #expect(c2.x + 30.0 <= b.0 || c2.x - 30.0 >= b.2)
    }

    @Test("subgraph titles, subgraph borders, exit slopes, balanced labels, direction fit, and label straightness")
    func layeredDrawGeometry() {
        let chat = "flowchart LR\n  subgraph Thing[\"The chat (task): has a history\"]\n    H1[your point] --> H2[result 1] --> H3[your reply] --> H4[result 2]\n  end\n  H4 -->|\"newest turn is a question\"| N[Needs you]\n  H4 -->|\"newest turn is a result you haven't read\"| R[Ready]\n  Note[(Note: lasts, has versions)] -.linked.- Thing"

        func draw(_ src: String, dark isDark: Bool, width: Float) -> Canvas {
            var p = MermaidTheme.neutral(dark: isDark)
            p.maxWidth = width
            guard case let .flowchart(f)? = MermaidParser.parse(src) else { fatalError() }
            return FlowchartParser.drawCanvas(f, paint: p, hover: (.edges, p.text))!
        }

        func rect(_ l: CanvasLabel) -> (Float, Float, Float, Float) {
            (l.at.x, l.at.y, l.at.x + l.size.x, l.at.y + l.size.y)
        }

        func hits(_ a: Vec2, _ b: Vec2, _ r: (Float, Float, Float, Float)) -> Bool {
            (0...16).contains { k in
                let p = CanvasMath.lerp(a, b, Float(k) / 16.0)
                return p.x > r.0 && p.x < r.2 && p.y > r.1 && p.y < r.3
            }
        }

        for isDark in [false, true] {
            for width: Float in [680, 420, 2000] {
                let c = draw(chat, dark: isDark, width: width)
                let titleLabel = c.labels.first { $0.text == "The chat (task): has a history" }!
                let titleRect = rect(titleLabel)
                for op in c.ops {
                    if case let .stroke(pts, closed, _, _, _) = op, !closed {
                        for i in 0..<max(0, pts.count - 1) {
                            #expect(!hits(pts[i], pts[i + 1], titleRect))
                        }
                    }
                }
            }
        }

        // Edge to subgraph stops on its border
        let borderCanvas = draw(chat, dark: false, width: 2000)
        if case let .fill(pts, _)? = borderCanvas.ops.first {
            let b = pts.reduce((Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)) {
                (min($0.0, $1.x), min($0.1, $1.y), max($0.2, $1.x), max($0.3, $1.y))
            }
            let dashes: [[Vec2]] = borderCanvas.ops.compactMap {
                if case let .stroke(p, _, _, roundCap, _) = $0, !roundCap { return p }
                return nil
            }
            #expect(!dashes.isEmpty)
            for d in dashes {
                #expect(!d.contains { $0.x > b.0 + 0.5 && $0.x < b.2 - 0.5 && $0.y > b.1 + 0.5 && $0.y < b.3 - 0.5 })
            }
        } else {
            Issue.record("Expected first fill op to be cluster box")
        }

        // Subgraph title gap above nodes (TD vs LR)
        func titleGap(_ dir: String) -> Float {
            let c = draw("flowchart \(dir)\n  subgraph S[A title]\n    A[One] --> B[Two]\n  end", dark: false, width: 4000)
            let t = rect(c.labels.first { $0.text == "A title" }!)
            let top = c.regions.flatMap { $0 }.map(\.y).min()!
            return top - t.3
        }
        let down = titleGap("TD"), right = titleGap("LR")
        #expect(abs(down - right) < 0.5)
        #expect(abs(down - 14.0) < 0.5)

        // Fits card keeps direction
        func clusterBounds(_ c: Canvas) -> (Float, Float, Float, Float) {
            guard case let .fill(pts, _)? = c.ops.first else { fatalError() }
            return pts.reduce((Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)) {
                (min($0.0, $1.x), min($0.1, $1.y), max($0.2, $1.x), max($0.3, $1.y))
            }
        }
        let wideBox = clusterBounds(draw(chat, dark: false, width: 2000))
        let narrowBox = clusterBounds(draw(chat, dark: false, width: 300))
        #expect(!(wideBox.3 - wideBox.1 > wideBox.2 - wideBox.0))
        #expect(narrowBox.3 - narrowBox.1 > narrowBox.2 - narrowBox.0)

        // Balanced wrapped labels
        let balanced = measureBalanced("newest turn is a result you haven't read", font: light.font)
        let oneLineH = measureBalanced("newest", font: light.font).size.y
        #expect(balanced.wrap && balanced.size.y < oneLineH * 2.5)
        #expect(balanced.size.x < 160.0)

        // edges_leave_a_subgraph_steeply (layered_draw_tests.rs:192)
        for width: Float in [680.0, 2000.0] {
            let c = draw(chat, dark: false, width: width)
            guard case let .fill(pts, _)? = c.ops.first else {
                Issue.record("Expected cluster fill")
                continue
            }
            let b = pts.reduce((Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)) {
                (min($0.0, $1.x), min($0.1, $1.y), max($0.2, $1.x), max($0.3, $1.y))
            }
            let turned = (b.3 - b.1) > (b.2 - b.0)
            var crossings = 0
            for op in c.ops {
                if case let .stroke(linePts, closed, _, _, _) = op, !closed {
                    for i in 0..<max(0, linePts.count - 1) {
                        let a = linePts[i], z = linePts[i + 1]
                        let aAlong = turned ? a.y : a.x
                        let zAlong = turned ? z.y : z.x
                        let aAcross = turned ? a.x : a.y
                        let edge = turned ? b.3 : b.2
                        let loAcross = turned ? b.0 : b.1
                        let hiAcross = turned ? b.2 : b.3
                        if (aAlong - edge) * (zAlong - edge) < 0.0 && aAcross > loAcross && aAcross < hiAcross {
                            crossings += 1
                            let slope = abs((turned ? z.x : z.y) - aAcross) / abs(zAlong - aAlong)
                            #expect(slope < 0.6, "Slope \(slope) >= 0.6 at width \(width)")
                        }
                    }
                }
            }
            #expect(crossings == 2, "Expected 2 exits at width \(width)")
        }

        // an_edge_runs_straight_through_its_label (layered_draw_tests.rs:237)
        for width: Float in [420.0, 680.0, 2000.0] {
            let c = draw(chat, dark: false, width: width)
            let openLines: [[Vec2]] = c.ops.compactMap {
                if case let .stroke(pts, closed, _, _, _) = $0, !closed, pts.count >= 2 { return pts }
                return nil
            }
            for text in ["newest turn is a question", "newest turn is a result you haven't read"] {
                let l = c.labels.first { $0.text == text }!
                let r = rect(l)
                let off: (Vec2) -> Float = { p in max(r.0 - p.x, max(p.x - r.2, max(r.1 - p.y, p.y - r.3))) }
                let ends = openLines.flatMap { [$0.first!, $0.last!] }.filter { off($0) > -0.5 && off($0) < 10.0 }
                #expect(ends.count == 2, "Expected 2 ends around \(text) at width \(width)")
                if ends.count == 2 {
                    let a = ends[0], b = ends[1]
                    #expect(abs(a.x - b.x) < 1.0 || abs(a.y - b.y) < 1.0, "Line jogged through \(text)")
                }
            }
        }
    }

    // MARK: - Route, Shapes, Ink, Hover, Parts Parity

    @Test("parallel edges, fan-out, back-edges, and subgraph edge stops route cleanly")
    func routingParityCases() {
        let p1 = scene("flowchart TD\nA[Node] --> B[Target]\nA --> B")!
        let p2 = scene("flowchart TD\nA[Start] --> C[Hub]\nB[Other] --> C\nX[Far] --> C\nC --> D[Out]\nC --> E[More]")!
        let p3 = scene("flowchart TD\nA[Start] --> B[Step] --> A")!
        let p4 = scene("flowchart LR\nsubgraph S[Box]\nA --> B\nend\nX --> S")!
        #expect(!p1.ops.isEmpty && p2.pieces.count >= 5 && !p3.ops.isEmpty && !p4.ops.isEmpty)

        // arrows_point_into_the_node_they_reach (route_tests.rs:50)
        guard case let .flowchart(arrowF)? = MermaidParser.parse("flowchart TD\n  A[Audio] --> B[Parakeet]") else {
            Issue.record("Expected flowchart")
            return
        }
        let arrowC = FlowchartParser.drawCanvas(arrowF, paint: dark, hover: (.edges, dark.text))!
        let tip = arrowC.ops.compactMap { op -> Vec2? in
            if case let .fill(pts, col) = op, col == dark.line, pts.count == 3 { return pts[0] }
            return nil
        }.first
        let bTop = arrowC.regions[1].map(\.y).min()!
        #expect(tip != nil && abs((tip?.y ?? 0) - bTop) < 0.5)
    }

    @Test("triangle ray exit and cylinder rims behave per shape spec")
    func shapesTriangleAndCylinder() {
        let triSize = Vec2(100, 60)
        let up = ShapeRenderer.boundary(shape: .triangle, center: .zero, size: triSize, toward: Vec2(0, -100))
        #expect(abs(up.y + 30.0) < 1e-3)
        let slant = ShapeRenderer.boundary(shape: .triangle, center: .zero, size: triSize, toward: Vec2(100, -60))
        #expect(slant.x < 50.0 && slant.x > 0.0 && slant.y > -30.0)

        let label = measureText("Note: lasts, has versions", font: light.font)
        let cylSize = ShapeRenderer.nodeSize(.cylinder, labelSize: label.size)
        let ry = ShapeRenderer.rim(cylSize.x)
        #expect(abs(ry - cylSize.x / 2.0 / (2.5 + cylSize.x / 50.0)) < 1e-3)
        var c = Canvas()
        ShapeRenderer.draw(into: &c, shape: .cylinder, label: label, center: .zero, size: cylSize, colors: (light.nodeFill, light.nodeBorder, light.text), paint: light)
        let top = -cylSize.y * 0.5, bottom = cylSize.y * 0.5
        let l = c.labels[0]
        #expect(l.at.y >= top + 2.0 * ry)
        #expect(l.at.y + l.size.y <= bottom - ry)
    }

    @Test("ink flattening resolves fills beneath and lights hover traces opaquely")
    func inkFlatteningAndHoverTraces() {
        let surface = Color(r: 0.02, g: 0.02, b: 0.02, a: 1.0)
        let tint = Color.white.alpha(0.1)
        let ink = Color.white.alpha(0.5)
        var c = Canvas()
        c.fill([Vec2(0, 0), Vec2(100, 0), Vec2(100, 100), Vec2(0, 100)], color: tint)
        c.stroke([Vec2(10, 50), Vec2(90, 50)], closed: false, width: 1.0, color: ink)
        c.stroke([Vec2(110, 50), Vec2(190, 50)], closed: false, width: 1.0, color: ink)
        c.fill([Vec2(150, 40), Vec2(160, 50), Vec2(150, 60)], color: ink)
        var traces: [HoverTrace] = []
        InkFlattener.flatten(ops: &c.ops, traces: &traces, surface: surface)
        func color(_ op: CanvasOp) -> Color {
            switch op {
            case let .fill(_, col), let .stroke(_, _, _, _, col): col
            }
        }
        #expect(color(c.ops[0]) == tint)
        #expect(color(c.ops[1]) == InkFlattener.over(ink, InkFlattener.over(tint, surface)))
        #expect(color(c.ops[2]) == InkFlattener.over(ink, surface))

        guard case let .flowchart(f)? = MermaidParser.parse("flowchart LR\nR1[Retry] -->|fails| R2[Wait]\nR2 -->|ok| On[Done]") else {
            fatalError()
        }
        var fc = FlowchartParser.drawCanvas(f, paint: dark, hover: (.edges, dark.text.alpha(0.9)))!
        InkFlattener.flatten(ops: &fc.ops, traces: &fc.traces, surface: dark.surface)
        let alphas: [Float] = fc.traces.flatMap(\.ops).compactMap {
            if case let .stroke(_, _, _, _, col) = $0 { return col.a }
            return nil
        }
        #expect(alphas.count >= 2 && alphas.allSatisfy { $0 == 1.0 })

        // a_line_is_no_brighter_at_its_joints_under_its_head_or_round_a_corner (ink_tests.rs:53)
        func insideCount(_ pts: [Vec2], _ p: Vec2) -> Int {
            var odd = false
            var j = pts.count - 1
            for i in 0..<pts.count {
                let a = pts[i], c = pts[j]
                if (a.y > p.y) != (c.y > p.y) && p.x < (c.x - a.x) * (p.y - a.y) / (c.y - a.y) + a.x {
                    odd.toggle()
                }
                j = i
            }
            return odd ? 1 : 0
        }
        func covers(_ a: Vec2, _ b: Vec2, width: Float, roundCap: Bool, p: Vec2) -> Bool {
            let len = max(CanvasMath.dist(a, b), 1e-6)
            let d = Vec2((b.x - a.x) / len, (b.y - a.y) / len)
            let t = (p.x - a.x) * d.x + (p.y - a.y) * d.y
            let n = abs((p.x - a.x) * -d.y + (p.y - a.y) * d.x)
            if roundCap {
                return CanvasMath.dist(p, CanvasMath.lerp(a, b, min(max(t / len, 0.0), 1.0))) <= width / 2.0
            }
            return t >= 0.0 && t <= len && n <= width / 2.0
        }
        func painted(_ ops: [CanvasOp], surface: Color, p: Vec2) -> Color {
            ops.reduce(surface) { under, op in
                switch op {
                case let .fill(pts, col):
                    let count = insideCount(pts, p)
                    return (0..<count).reduce(under) { u, _ in InkFlattener.over(col, u) }
                case let .stroke(pts, closed, width, roundCap, col):
                    var segs: [(Vec2, Vec2)] = (0..<max(0, pts.count - 1)).map { (pts[$0], pts[$0 + 1]) }
                    if closed && pts.count > 2 {
                        segs.append((pts.last!, pts.first!))
                    }
                    return segs.filter { covers($0.0, $0.1, width: width, roundCap: roundCap, p: p) }
                        .reduce(under) { u, _ in InkFlattener.over(col, u) }
                }
            }
        }
        let flowSrc = "flowchart LR\n  R1[Retry at once] -->|fails| R2[Back off 1 s]\n  R2 -->|fails| Off[Offline]\n  R1 -->|ok| On[Online]"
        let flowOps = scene(flowSrc, paint: dark)!.ops
        var checked = 0
        for op in flowOps {
            guard case let .stroke(pts, closed, _, _, _) = op, pts.count >= 2 else { continue }
            let segs = (0..<(pts.count - 1)).map { (pts[$0], pts[$0 + 1]) }
            let longest = segs.max { CanvasMath.dist($0.0, $0.1) < CanvasMath.dist($1.0, $1.1) }!
            let body = painted(flowOps, surface: dark.surface, p: CanvasMath.lerp(longest.0, longest.1, 0.5))
            for p in pts.dropFirst(closed ? 0 : 1) {
                let lift = painted(flowOps, surface: dark.surface, p: p).luminance - body.luminance
                #expect(lift < 0.002, "Brighter by \(lift) at \(p)")
                checked += 1
            }
        }
        #expect(checked > 40)
    }

    @Test("hover lineHits split diagonal lines, cutAway excludes nodes, and spots carry stable keys")
    func hoverGeometryAndKeys() {
        let diag = HoverGeometry.lineHits(line: [Vec2(0, 0), Vec2(100, 100)], slop: 6.0)
        #expect(diag.count > 4)
        let huge = HoverGeometry.lineHits(line: [Vec2(0, 0), Vec2(1e6, 1e6)], slop: 6.0)
        #expect(huge.count <= 200)

        let cut = HoverGeometry.cutAway([(0, 0, 100, 20)], nodes: [(0, -10, 60, 40)])
        #expect(cut.count == 1 && cut[0].0 >= 60.0)
        #expect(HoverGeometry.cutAway([(0, 0, 100, 20)], nodes: [(0, 0, 100, 20)]).isEmpty)

        let s = scene("flowchart TD\nA --> B\nB --> C", paint: light, hover: (.edges, light.text))!
        #expect(s.hovers.contains { $0.key.hasPrefix("hover:e:A>B.") })
        #expect(s.hovers.contains { $0.key == "hover:n:B" || $0.key.hasPrefix("hover:n:") })
    }

    @Test("parts include g: subgraph keys and stable sequence/state keys")
    func partsSubgraphSequenceAndStateKeys() {
        let flowScene = scene("flowchart TD\nsubgraph S [Box]\nA --> B\nend", paint: dark, hover: (.edges, dark.text))!
        #expect(flowScene.pieces.contains { $0.key.hasPrefix("g:") })

        let seqScene = scene("sequenceDiagram\nA->>B: hello\nB-->>A: world", paint: dark)!
        #expect(!seqScene.pieces.isEmpty && !seqScene.labelKeys.isEmpty)

        let stateScene = scene("stateDiagram-v2\nIdle --> Busy : go", paint: dark)!
        #expect(stateScene.pieces.contains { $0.key.hasPrefix("n:Idle") })
        #expect(stateScene.pieces.contains { $0.key.hasPrefix("e:Idle>Busy") })
    }

    // MARK: - Steady Streaming Layout Parity

    @Test("streaming holds direction/rank, final frame matches non-streamed, and node promotes cleanly to subgraph")
    func steadyStreamingParity() {
        let retries = [
            "flowchart LR",
            "  subgraph Left [\"Inputs\"]",
            "    A[One] --> B[Two]",
            "  end",
            "  B --> C[Center]",
            "  C --> D[Right]",
            "  C --> E[Bottom]",
            "  E --> F[Tail]",
        ]
        var cur = ""
        var prev: SteadyMemory? = nil
        var prevSize = Vec2.zero
        for line in retries {
            if !cur.isEmpty { cur += "\n" }
            cur += line
            let b = MermaidScenes.built(cur, theme: dark, hover: nil, prev: .some(prev))
            prev = b.memory
            if let s = b.scene {
                #expect(s.size.x >= prevSize.x - 0.5 && s.size.y >= prevSize.y - 0.5)
                prevSize = s.size
            }
        }
        let full = retries.joined(separator: "\n")
        let before = scene(full, paint: dark)!
        let streamedFinal = MermaidScenes.growing(full, theme: dark, hover: nil)
        let after = scene(full, paint: dark)!
        func centres(_ s: MermaidScene) -> [String: Vec2] {
            Dictionary(uniqueKeysWithValues: s.pieces.filter { $0.key.hasPrefix("n:") && !$0.key.contains(".") }.map {
                ($0.key, Vec2($0.at.x + $0.size.x / 2.0, $0.at.y + $0.size.y / 2.0))
            })
        }
        #expect(streamedFinal != nil)
        #expect(centres(before) == centres(after))
        #expect(before.size == after.size)

        // Node to subgraph promotion: "subgraph S" replacing node S should build cleanly while holding memory
        let beforeSub = "flowchart TD\nA --> S\nS --> B"
        let afterSub = "flowchart TD\nA --> S\nsubgraph S [Group]\n  S1 --> S2\nend\nS --> B"
        let m1 = MermaidScenes.built(beforeSub, theme: dark, hover: nil, prev: nil).memory
        let b2 = MermaidScenes.built(afterSub, theme: dark, hover: nil, prev: .some(m1))
        #expect(b2.scene != nil)
    }

    // MARK: - Chart, Date & 14 Extended Diagrams Parity

    @Test("chart ink contrast and axis label spacing")
    func chartParity() {
        for isDark in [false, true] {
            let paint = MermaidTheme.neutral(dark: isDark)
            for i in 0..<12 {
                for fill in [MermaidChart.solid(paint, hue: MermaidChart.hue(i)), MermaidChart.soft(paint, hue: MermaidChart.hue(i))] {
                    let diff = abs(MermaidChart.ink(fill).toOKLab()[0] - fill.toOKLab()[0])
                    #expect(diff > 0.35)
                }
            }
        }
        var c = Canvas()
        let ticks = [Float(0), 10, 60, 200].map { ($0, measureText("2024-01-01", font: light.font)) }
        MermaidChart.axisX(&c, ticks: ticks, xRange: (0, 200), yRange: (0, 100), font: light.font, paint: light)
        #expect(c.labels.count < 4)
        for l in c.labels {
            #expect(l.at.x >= 0.0 && l.at.x + l.size.x <= 200.01)
        }
    }

    @Test("date parsing rejects invalid dates, formats D3 escapes, and advances calendar ticks")
    func dateParity() {
        #expect(MermaidDate.parse("2024-02-30", format: "YYYY-MM-DD") == nil)
        #expect(MermaidDate.parse("soon", format: "YYYY-MM-DD") == nil)
        #expect(MermaidDate.parse("99999999999999999999", format: "X") == nil)
        let mar7 = Double(MermaidDate.daysFromCivil(2024, 3, 7)) * MermaidDate.day + 15.0 * MermaidDate.hour + 4.0 * MermaidDate.min
        #expect(MermaidDate.format(mar7, fmt: "%Y-%m-%d") == "2024-03-07")
        #expect(MermaidDate.format(mar7, fmt: "%b %-d") == "Mar 7")
        #expect(MermaidDate.format(mar7, fmt: "%B %j %%") == "March 067 %")
        #expect(MermaidDate.Step.parse("2week") == .weeks(2))
        #expect(MermaidDate.Step.parse("6hour") == .ms(6.0 * MermaidDate.hour))
    }

    @Test("extended diagrams parse structural details, skip bad lines, and enforce bounds")
    func extendedDiagramsStructuralParity() {
        // Pie
        if case let .pie(p)? = MermaidParser.parse("pie\n  title Key: value\n  \"A: one\" : 1\n\"Zero\" : 0\n\"Bad\" : -1") {
            #expect(p.title == "Key: value" && p.slices.count == 1 && p.slices[0].0 == "A: one")
        } else { Issue.record("Expected pie") }
        #expect(MermaidParser.parse("pie title Empty") == nil)

        // Journey
        if case let .journey(j)? = MermaidParser.parse("journey\ntitle Day\nsection Work\nTea: 9: Me\nSit: 0") {
            #expect(j.tasks.count == 2 && j.tasks[0].score == 5.0 && j.tasks[1].score == 1.0)
        } else { Issue.record("Expected journey") }
        #expect(MermaidParser.parse("journey\ntitle Empty\nsection A") == nil)

        // Timeline
        let acrossTimeline = scene("timeline\n2001 : a\n2002 : b\n2003 : c", paint: light)!
        let acrossYs = ["2001", "2002", "2003"].map { t in acrossTimeline.labels.first { $0.text == t }!.at.y }
        #expect(abs(acrossYs[0] - acrossYs[1]) < 0.5 && abs(acrossYs[1] - acrossYs[2]) < 0.5)
        let manyTimeline = "timeline\n" + (2000..<2012).map { "\($0) : event" }.joined(separator: "\n")
        let downTimeline = scene(manyTimeline, paint: light)!
        func timelineY(_ t: String) -> Float { downTimeline.labels.first { $0.text == t }!.at.y }
        #expect(timelineY("2001") > timelineY("2000") && timelineY("2011") > timelineY("2010"))
        #expect(downTimeline.size.x <= Canvas.room(for: light) + 2.01)
        #expect(MermaidParser.parse("timeline\n  title Nothing") == nil)

        // Git
        if case let .git(g)? = MermaidParser.parse("gitGraph\n  commit id: \"A\"\n  branch dev order: 2\n  checkout dev\n  commit id: \"B\" type: REVERSE\n  checkout main\n  merge dev tag: \"v1\"\n  cherry-pick id: \"B\"") {
            #expect(g.branches.map(\.name) == ["main", "dev"])
            #expect(g.branches[1].order == 2.0)
            #expect(g.commits.last?.kind == .cherryPick)
        } else { Issue.record("Expected git") }
        #expect(MermaidParser.parse("gitGraph\nbranch x") == nil)

        // Mindmap
        if case let .mindmap(m)? = MermaidParser.parse("mindmap\n    Root\n  Shallower\n  Sibling\n    Child") {
            #expect(m.nodes[0].children == [1, 2] && m.nodes[2].children == [3])
        } else { Issue.record("Expected mindmap") }
        #expect(MermaidParser.parse("mindmap") == nil)

        // Quadrant
        if case let .quadrant(q)? = MermaidParser.parse("quadrantChart\n  Point C:::hot: [1.4, -0.2]\n  classDef hot radius: 10") {
            #expect(q.points[0].at == Vec2(1.0, 0.0))
            #expect(q.points[0].look.radius == 10.0)
        } else { Issue.record("Expected quadrant") }
        #expect(MermaidParser.parse("quadrantChart\n  title Only a title") == nil)

        // XYChart
        let (r1, _) = XYChartParser.scale(range: nil, series: [XYChartSeries(kind: .bar, name: "", values: [3, 47])])
        #expect(r1 == (0.0, 50.0))
        let (r2, t2) = XYChartParser.scale(range: nil, series: [XYChartSeries(kind: .bar, name: "", values: [-12, 30])])
        #expect(r2.0 <= -12.0 && r2.1 >= 30.0 && t2.contains(0.0))
        #expect(MermaidParser.parse("xychart-beta\n  title Nothing\n  x-axis [a, b]") == nil)

        // Sankey
        if case let .sankey(s)? = MermaidParser.parse("sankey-beta\nA,B,5\nB,C,3\nA,D,2\nC,B,1\nA,A,3\nA,B,-1") {
            #expect(s.links.count == 4)
            let cols = SankeyParser.columns(s)
            #expect(cols[0] == 0 && cols[3] == cols.max())
        } else { Issue.record("Expected sankey") }
        #expect(MermaidParser.parse("sankey-beta\nnot,a number,here") == nil)

        // Block
        let blockScene = scene("block-beta\ncolumns 2\nOne Two\nThree", paint: light)!
        func labelAt(_ t: String) -> Vec2 { blockScene.labels.first { $0.text == t }!.at }
        #expect(labelAt("One").x < labelAt("Two").x && abs(labelAt("One").y - labelAt("Two").y) < 1.0)
        #expect(labelAt("Three").y > labelAt("One").y + 10.0)
        let autoBlock = scene("block\nOne Two Three", paint: light)!
        let autoYs = autoBlock.labels.map(\.at.y)
        #expect(autoYs.allSatisfy { abs($0 - autoYs[0]) < 1.0 })
        #expect(MermaidParser.parse("block-beta\n  columns 2") == nil)

        // C4 & Requirement
        #expect(MermaidParser.parse("C4Context\n  title Empty") == nil)
        #expect(MermaidParser.parse("requirementDiagram\n  direction TB") == nil)
        if case let .requirement(req)? = MermaidParser.parse("requirementDiagram\n  requirement a {\n  id: 1\n  }\n  a <- copies - other") {
            #expect(req.edges.count == 1 && req.edges[0].from == 1 && req.edges[0].to == 0)
        } else { Issue.record("Expected requirement") }
    }

    // MARK: - El Parity Hooks (Hover Groups, ClipFade, EnterDelay, Origin, A11yHidden)

    private func collectEls<State>(_ root: El<State>) -> [El<State>] {
        var out = [root]
        for child in root.children {
            out.append(contentsOf: collectEls(child))
        }
        return out
    }

    @Test("rendered hover spots use hoverGroup, groupOpacity, instantChanges, lit shapes/labels, and hover(.off) omits them")
    func mermaidHoverSpotsRenderInElAndOffEmitsNone() {
        let src = "flowchart TD\nA -->|go| B"
        let litColor = Color(r: 1.0, g: 0.0, b: 0.0)
        let sOn = scene(src, paint: dark, hover: (.edges, litColor))!
        let elOn: El<Int> = sOn.el(paint: dark, streaming: false)
        let nodesOn = collectEls(elOn)
        let hoverEls = nodesOn.filter { $0.keyId?.starts(with: "hover:") == true }
        #expect(!hoverEls.isEmpty)
        for spot in hoverEls {
            #expect(spot.isHoverGroup)
            #expect(spot.isA11yHidden)
            #expect(spot.transition == Transition.none)
            let glow = spot.children.first
            #expect(glow != nil)
            if let glow {
                #expect(glow.origin == .zero)
                #expect(glow.scale == Vec2(sOn.scale, sOn.scale))
                #expect(glow.groupOpacity?.rest == 0.0)
                #expect(glow.groupOpacity?.hovered == 1.0)
                #expect(glow.hasInstantChanges)
                #expect(!glow.shapes.isEmpty)
            }
        }
        // Streaming mode attaches removal opacity exit transition to hover spots
        let elStreamOn: El<Int> = sOn.el(paint: dark, streaming: true)
        let streamHoverEls = collectEls(elStreamOn).filter { $0.keyId?.starts(with: "hover:") == true }
        #expect(!streamHoverEls.isEmpty)
        for spot in streamHoverEls {
            #expect(spot.transition?.insertion == .identity)
            #expect(spot.transition?.removal.zeroOpacity == 0)
        }
        // At least one hover glow includes the lit edge label "go" in litColor with key "t<idx>" and Transition.none
        let glowLabels = hoverEls.flatMap { $0.children }.flatMap { $0.children }
        #expect(glowLabels.contains {
            $0.plainText == "go" && $0.textColor == litColor && $0.keyId?.hasPrefix("t") == true && $0.transition == Transition.none
        })

        // a_label_lights_itself_and_its_edge (hover_tests.rs:65)
        let labelSpotScene = scene("flowchart LR\n  A -->|go on| B\n  B --> C", paint: light, hover: (.edges, litColor))!
        let goIdx = labelSpotScene.labels.firstIndex { $0.text == "go on" }!
        let goLabel = labelSpotScene.labels[goIdx]
        let goCenter = Vec2(goLabel.at.x + goLabel.size.x / 2.0, goLabel.at.y + goLabel.size.y / 2.0)
        let overGo = labelSpotScene.hovers.filter { h in
            let r = h.rect
            return goCenter.x >= r.0 && goCenter.x <= r.0 + r.2 && goCenter.y >= r.1 && goCenter.y <= r.1 + r.3
        }
        #expect(!overGo.isEmpty)
        #expect(overGo.allSatisfy { $0.key.hasPrefix("hover:e:A>B.") && $0.labels == [goIdx] })

        // hovering_an_edge_lights_it_instantly_and_leaving_drops_it (hover_tests.rs:101)
        let stateHoverScene = scene("stateDiagram-v2\n  Idle --> Busy : start", paint: light, hover: (.edges, litColor))!
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(400, 400)) { _, _ in
            col().wFull().child(stateHoverScene.el(paint: MermaidTheme.neutral(dark: false), streaming: false))
        }
        let isRedLit: (SIMD4<Float>) -> Bool = { $0.x > 0.9 && $0.y < 0.1 && $0.z < 0.1 }
        let restScene = rt.frame(at: 0)
        #expect(restScene.primitives.filter { isRedLit($0.fill) && $0.fill.w > 0.05 }.isEmpty)

        let labelSpot = rt.elements().first { $0.key == "hover:e:Idle>Busy.t" }
        #expect(labelSpot != nil)
        if let spot = labelSpot, spot.rect.count >= 4 {
            let r = spot.rect
            rt.pointerMove(to: Vec2(r[0] + r[2] / 2.0, r[1] + r[3] / 2.0), at: 1.0 / 60.0)
            let hoveredScene = rt.frame(at: 1.0 / 60.0)
            #expect(!hoveredScene.primitives.filter { isRedLit($0.fill) && $0.fill.w > 0.9 }.isEmpty)
            #expect(rt.element(byKey: "hover:e:Idle>Busy.t")?.hover == 1.0)
            #expect(rt.element(byKey: "hover:n:Idle")?.hover == 0.0)

            rt.pointerMove(to: Vec2(1.0, 399.0), at: 2.0 / 60.0)
            for step in 2...13 {
                _ = rt.frame(at: Double(step) / 60.0)
            }
            #expect(rt.element(byKey: "hover:e:Idle>Busy.t")?.hover == 0.0)
        }

        let sOff = scene(src, paint: dark, hover: nil)!
        let elOff: El<Int> = sOff.el(paint: dark, streaming: false)
        let hoverElsOff = collectEls(elOff).filter { $0.keyId?.starts(with: "hover:") == true }
        #expect(hoverElsOff.isEmpty)
    }

    @Test("card uses clipRounded(6) and adds horizontal clipFade only when diagram exceeds room")
    func mermaidWideDiagramClipFadeAndRoundedClip() {
        let narrow = scene("flowchart TD\nA --> B", paint: dark, hover: nil)!
        let narrowEl: El<Int> = narrow.el(paint: dark, streaming: false)
        #expect(narrowEl.clipRadius == 6.0)
        #expect(narrowEl.clipFade == nil)

        var wideSeq = "sequenceDiagram\n"
        for i in 0..<14 {
            wideSeq += "  participant P\(i) as Participant_\(i)\n"
        }
        wideSeq += "  P0->>P13: cross\n"
        let wide = scene(wideSeq, paint: dark, hover: nil)!
        #expect(wide.size.x > Canvas.room(for: dark) + 0.5)
        let wideEl: El<Int> = wide.el(paint: dark, streaming: false)
        #expect(wideEl.clipRadius == 6.0)
        #expect(wideEl.clipFade == SIMD4<Float>(CanvasConstants.cardPad, 0, CanvasConstants.cardPad, 0))
    }

    @Test("streaming edge labels carry origin(0,0) and enterDelay(0.12); pieces are a11yHidden")
    func mermaidStreamingLabelEnterDelayAndPieceA11yHidden() {
        let s = scene("flowchart TD\nA -->|edge label| B", paint: dark, hover: nil)!
        let streamEl: El<Int> = s.el(paint: dark, streaming: true)
        let streamNodes = collectEls(streamEl)

        let pieceNodes = streamNodes.filter {
            let k = $0.keyId ?? ""
            return k.hasPrefix("p:") || k.hasPrefix("n:") || k.hasPrefix("e:")
        }
        #expect(!pieceNodes.isEmpty)
        for p in pieceNodes where !p.shapes.isEmpty {
            #expect(p.isA11yHidden)
            #expect(p.role == .image)
        }

        let streamEdgeLabel = streamNodes.first { $0.plainText == "edge label" && $0.keyId == "e:A>B.t0" }
        #expect(streamEdgeLabel != nil)
        #expect(streamEdgeLabel?.origin == .zero)
        #expect(streamEdgeLabel?.scale == Vec2(s.scale, s.scale))
        #expect(abs((streamEdgeLabel?.enterDelay ?? 0) - 0.12) < 0.001)

        let staticEl: El<Int> = s.el(paint: dark, streaming: false)
        let staticEdgeLabel = collectEls(staticEl).first { $0.plainText == "edge label" && $0.keyId == "e:A>B.t0" }
        #expect(staticEdgeLabel?.origin == .zero)
        #expect(staticEdgeLabel?.enterDelay == 0)
    }

    @Test("scene cache key incorporates fontEpoch so font changes do not return stale cached scenes")
    func mermaidSceneCacheInvalidatesOnFontEpochChange() {
        let src = "flowchart TD\nEpochAlpha --> EpochBeta"
        let beforeEpoch = fontEpoch()
        let first = MermaidScenes.built(src, theme: dark, hover: (.edges, dark.text.alpha(0.9)), prev: nil).scene
        #expect(first != nil)

        var insideEpoch: UInt64 = 0
        var rebuilt: MermaidScene?
        withFontFamilies(sans: "Helvetica Neue", mono: "Menlo") {
            insideEpoch = fontEpoch()
            rebuilt = MermaidScenes.built(src, theme: dark, hover: (.edges, dark.text.alpha(0.9)), prev: nil).scene
        }
        #expect(insideEpoch != beforeEpoch)
        #expect(fontEpoch() > insideEpoch)
        #expect(rebuilt != nil)
        if let first, let rebuilt {
            #expect(first.size.x > 0 && rebuilt.size.x > 0)
        }
    }

    @Test("plan.mmd fixture subgraphs keep title bands and edges fan out and route around subgraphs")
    func planMmdFixtureSubgraphsAndEdgesRouteCleanly() {
        let plan = #"""
        flowchart LR
          classDef done fill:#1f3d2a,stroke:#3fb950,color:#e6edf3
          classDef doing fill:#3d3416,stroke:#d29922,color:#e6edf3
          classDef waiting fill:#162a3d,stroke:#58a6ff,color:#e6edf3
          classDef blocked fill:#21262d,stroke:#6e7681,color:#c9d1d9

          subgraph PREP["Prep, done"]
            t12["t12 tokens carry byte spans"]:::done
            t07["t07 grammar table in groups"]:::done
          end

          subgraph S2["Stage 2: first pass on the new parser (the pilot)"]
            t31["t31 cache sees grammar edits"]:::waiting
            t35["t35 baseline = pinned release, built from source"]:::doing
            t44["t44 lint_unused, the pass rewritten"]:::doing
            t11["t11 old-vs-new compare hook"]:::doing
            t36["t36 link the new parser into the old tool"]:::blocked
            t37["t37 PILOT: the pass runs in the new build"]:::blocked
          end

          subgraph IR["AST track: the new parser reads the old tool's syntax trees"]
            t84["t84 formatter stops using the old evaluator"]:::doing
            t33["t33 AST binary format + reader"]:::blocked
            t34["t34 generate both sides from the grammar table"]:::blocked
            t38["t38 AST verifier, rewritten"]:::blocked
          end

          subgraph S3["Stage 3: formatter on the new parser"]
            t39["t39 layout, spacing, names"]:::blocked
            t40["t40 comments, literals, source maps"]:::blocked
            t41["t41 functions and core forms"]:::blocked
            t42["t42 imports and exports"]:::blocked
            t43["t43 macros, attribute glue"]:::blocked
            t45["t45 byte-exact match with the old one, at most 2x slower"]:::blocked
            t46["t46 the tool formats itself identically"]:::blocked
            t47["t47 delete the old formatter"]:::blocked
          end

          t31 --> t35 --> t36
          t84 --> t33 --> t34
          t33 --> t36
          t36 --> t37
          t11 --> t37
          t44 --> t37

          t34 --> t38
          t36 --> t38
          t34 --> t39
          t34 --> t40
          t39 --> t41
          t40 --> t41
          t41 --> t42
          t41 --> t43
          t42 --> t45
          t43 --> t45
          t36 --> t45
          t11 --> t45
          t45 --> t46 --> t47

          subgraph KEY["Key"]
            k1["done"]:::done
            k2["building now"]:::doing
            k3["built, waiting to land"]:::waiting
            k4["not started"]:::blocked
          end
        """#

        func draw(_ src: String, width: Float) -> (FlowchartDiagram, Canvas) {
            var p = MermaidTheme.neutral(dark: true)
            p.maxWidth = width
            guard case let .flowchart(f)? = MermaidParser.parse(src) else { fatalError("parses") }
            return (f, FlowchartParser.drawCanvas(f, paint: p, hover: (.edges, p.text))!)
        }

        func bounds(_ pts: [Vec2]) -> (Float, Float, Float, Float) {
            pts.reduce((Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)) {
                (min($0.0, $1.x), min($0.1, $1.y), max($0.2, $1.x), max($0.3, $1.y))
            }
        }

        func rect(_ l: CanvasLabel) -> (Float, Float, Float, Float) {
            (l.at.x, l.at.y, l.at.x + l.size.x, l.at.y + l.size.y)
        }

        func hits(_ a: Vec2, _ b: Vec2, _ r: (Float, Float, Float, Float)) -> Bool {
            (0...16).contains { k in
                let p = CanvasMath.lerp(a, b, Float(k) / 16.0)
                return p.x > r.0 && p.x < r.2 && p.y > r.1 && p.y < r.3
            }
        }

        let titles = [
            "Prep, done",
            "Stage 2: first pass on the new parser (the pilot)",
            "AST track: the new parser reads the old tool's syntax trees",
            "Stage 3: formatter on the new parser",
            "Key",
        ]

        for dir in ["LR", "TD"] {
            let planDir = plan.replacingOccurrences(of: "flowchart LR", with: "flowchart \(dir)")
            for width: Float in [680, 4000] {
                let (_, c) = draw(planDir, width: width)
                let boxes: [(Float, Float, Float, Float)] = c.ops.compactMap {
                    if case let .fill(pts, _) = $0, pts.count > 8 { return bounds(pts) }
                    return nil
                }
                let lines: [[Vec2]] = c.ops.compactMap {
                    if case let .stroke(pts, closed, _, _, _) = $0, !closed { return pts }
                    return nil
                }

                // subgraph_titles_keep_a_band_of_their_own
                for title in titles {
                    let l = c.labels.first { $0.text == title }!
                    let r = rect(l)
                    #expect(!l.wrap)
                    let b = boxes
                        .filter { $0.0 <= r.0 && $0.2 >= r.2 && $0.1 <= r.1 && $0.3 >= r.3 }
                        .min { ($0.2 - $0.0) < ($1.2 - $1.0) }!
                    #expect(abs((b.0 + b.2) / 2.0 - (r.0 + r.2) / 2.0) < 0.5)
                    let band = (b.0, b.1, b.2, r.3)
                    for n in c.labels where !titles.contains(n.text) {
                        let o = rect(n)
                        #expect(o.0 >= band.2 || o.2 <= band.0 || o.1 >= band.3 || o.3 <= band.1)
                    }
                    for pts in lines {
                        for i in 0..<max(0, pts.count - 1) {
                            #expect(!hits(pts[i], pts[i + 1], r))
                        }
                    }
                }

                // edges_sharing_an_end_fan_out (plan.mmd + fan)
                let fan = "flowchart \(dir)\n  A[one source] --> C[where they meet]\n  B[another source] --> C\n  X[far] --> C\n  C --> D[next]\n  C --> E[and next]"
                for src in [planDir, fan] {
                    let (_, fc) = draw(src, width: width)
                    let fcLines: [[Vec2]] = fc.ops.compactMap {
                        if case let .stroke(pts, closed, _, _, _) = $0, !closed { return pts }
                        return nil
                    }
                    var p = MermaidTheme.neutral(dark: true)
                    p.maxWidth = width
                    let tips: [Vec2] = fc.ops.compactMap {
                        if case let .fill(pts, col) = $0, col == p.line, pts.count == 3 { return pts[0] }
                        return nil
                    }
                    let starts: [Vec2] = fcLines.compactMap(\.first)
                    for (pts, gap) in [(tips, Float(11.5)), (starts, Float(6.0))] {
                        for a in 0..<pts.count {
                            for b in (a + 1)..<pts.count {
                                #expect(CanvasMath.dist(pts[a], pts[b]) >= gap)
                            }
                        }
                    }
                }

                // edges_route_around_subgraphs_they_do_not_belong_to (plan.mmd + past)
                let past = "flowchart \(dir)\n  A[start] --> B[finish]\n  subgraph S[In between]\n    M1[one] --> M2[two] --> M3[three]\n  end\n  A --> M1\n  M3 --> B\n  A --> C[aside] --> B"
                for src in [planDir, past] {
                    let (df, dc) = draw(src, width: width)
                    let dcBoxes: [(Float, Float, Float, Float)] = dc.ops.compactMap {
                        if case let .fill(pts, _) = $0, pts.count > 8 { return bounds(pts) }
                        return nil
                    }
                    func within(_ v: Int, _ k: Int) -> Bool {
                        var cur = df.nodes[v].cluster
                        while let s = cur {
                            if s == k { return true }
                            cur = df.subgraphs[s].parent
                        }
                        return false
                    }
                    for k in 0..<df.subgraphs.count {
                        let members = (0..<df.nodes.count).filter { within($0, k) }.map { bounds(dc.regions[$0]) }
                        guard let b = dcBoxes
                            .filter({ box in members.allSatisfy { m in box.0 < m.0 - 4.0 && box.1 < m.1 - 4.0 && box.2 > m.2 + 4.0 && box.3 > m.3 + 4.0 } })
                            .min(by: { ($0.2 - $0.0) * ($0.3 - $0.1) < ($1.2 - $1.0) * ($1.3 - $1.1) })
                        else { continue }
                        let inner = (b.0 + 1.5, b.1 + 1.5, b.2 - 1.5, b.3 - 1.5)
                        for t in dc.traces {
                            if within(t.ends.0, k) || within(t.ends.1, k) { continue }
                            let into = t.line.first { pt in pt.x > inner.0 && pt.x < inner.2 && pt.y > inner.1 && pt.y < inner.3 }
                            #expect(into == nil)
                        }
                    }
                }
            }
        }
    }

    @Test("directive end keeps diagram header on the same line")
    func directiveEndKeepsDiagramOnSameLine() {
        for src in [
            "%%{init: {}}%% mindmap\n  root\n    child",
            "%%{\ninit: {}\n}%% mindmap\n  root\n    child",
        ] {
            #expect(mayDrawMermaid(src))
            let (cleaned, _) = MermaidParser.stripFrontMatterAndDirectives(src)
            let firstNonEmpty = cleaned
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && !$0.hasPrefix("%%") }
            #expect(firstNonEmpty == "mindmap")
            #expect(MermaidParser.parse(src) != nil)
        }
    }
}
