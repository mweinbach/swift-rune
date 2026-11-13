import Foundation
import Testing
import Rune
@testable import RuneMermaid

/// Full parity closure for all 60 discrepancies identified in audit #552,
/// ensuring 100% 1:1 assertion coverage across all upstream rune-mermaid tests.
@Suite("Mermaid Full Parity Audit Tests", .serialized)
struct MermaidFullParityAuditTests {
    private let light = MermaidTheme.neutral(dark: false)
    private let dark = MermaidTheme.neutral(dark: true)

    private func scene(_ src: String, paint: MermaidTheme = .neutral(dark: true), hover: (MermaidHover, Color)? = nil) -> MermaidScene? {
        guard let parsed = MermaidParser.parse(src) else { return nil }
        return renderScene(parsed, theme: paint, hover: hover)?.withTitle(parsed.title)
    }

    private func day(_ y: Int64, _ m: Int, _ d: Int) -> Double {
        Double(MermaidDate.daysFromCivil(y, m, d)) * MermaidDate.day
    }

    private func segDist(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Float {
        let ab = b - a
        let lenSq = ab.x * ab.x + ab.y * ab.y
        if lenSq < 1e-6 { return CanvasMath.dist(p, a) }
        let t = min(max(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lenSq, 0.0), 1.0)
        return CanvasMath.dist(p, Vec2(a.x + ab.x * t, a.y + ab.y * t))
    }

    private func sharpestTurn(_ pts: [Vec2]) -> Float {
        var dirs: [Float] = []
        for i in 0..<max(0, pts.count - 1) {
            if CanvasMath.dist(pts[i], pts[i + 1]) > 1e-3 {
                dirs.append(atan2f(pts[i + 1].y - pts[i].y, pts[i + 1].x - pts[i].x))
            }
        }
        var best: Float = 0.0
        for i in 0..<max(0, dirs.count - 1) {
            var a = abs((dirs[i + 1] - dirs[i]) * 180.0 / .pi)
            if a > 180.0 { a = 360.0 - a }
            best = max(best, a)
        }
        return best
    }

    private func insidePoly(_ poly: [Vec2], _ p: Vec2) -> Bool {
        var odd = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                odd.toggle()
            }
            j = i
        }
        return odd
    }

    // MARK: - Block, C4, Chart (5c.#1, #3, #7)

    @Test("5c.#1 block AST rows, spans, groups, arrows, unclosed fallback, and bounds")
    func blockAstAndBounds() throws {
        guard case let .block(d) = MermaidParser.parse(
            "block-beta\n  columns 3\n  a[\"Front end\"] b:2\n  space c((DB))\n  block:back:2\n    columns 2\n    d e\n  end\n  f<[\"go\"]>(right)\n  a --> b\n  b -- \"calls\" --> c\n  style a fill:#f96\n  classDef hot stroke:#f00\n  class c hot\n  g[unclosed"
        ) else {
            Issue.record("expected block diagram")
            return
        }
        func find(_ id: String) -> BlockDiagram.Block { d.blocks.first { $0.id == id }! }
        #expect(d.blocks[0].kind == .group(columns: 3, children: [1, 2, 3, 4, 5, 8, 9]))
        #expect(find("a").label == "Front end")
        #expect(find("b").span == 2)
        #expect(d.blocks[3].kind == .space)
        #expect(find("c").shape == .circle)
        #expect(find("back").kind == .group(columns: 2, children: [6, 7]))
        #expect(find("f").kind == .arrow(.right))
        #expect(find("g").label == "unclosed")
        #expect(d.edges.count == 2)
        #expect(d.edges[1].label == "calls")
        #expect(find("a").style.fill != nil && find("c").style.stroke != nil)
        #expect(MermaidParser.parse("block-beta\n  columns 2") == nil)
        let deep = "block-beta\n" + String(repeating: "block\n", count: MermaidLimits.maxDepth + 1) + "x\n"
        #expect(MermaidParser.parse(deep) == nil)
        let budget = "block-beta\n" + (0..<MermaidLimits.maxItems).map { "b\($0)" }.joined(separator: " ")
        #expect(MermaidParser.parse(budget) == nil)
    }

    @Test("5c.#3 C4 AST boundaries, elements, stores, stereotypes, and edges")
    func c4AstAndUnknownAliasSkip() {
        let src = """
        C4Context
            title System Context diagram for Internet Banking System
            Enterprise_Boundary(b0, "BankBoundary0") {
              Person(customerA, "Banking Customer A", "A customer of the bank, with personal bank accounts.")
              System(SystemAA, "Internet Banking System", "Allows customers to view information.", $tags="v1.0")
              Boundary(b1, "BankBoundary", "boundary") {
                SystemDb_Ext(SystemE, "Mainframe Banking System", "Stores all of the core banking information.")
              }
            }
            ContainerQueue(q, "Events", "Kafka", "Domain events")
            Person_Ext(other, "Visitor")
            Rel(customerA, SystemAA, "Uses")
            BiRel(SystemAA, SystemE, "Uses", "XML/HTTPS")
            Rel_Back(q, SystemAA, "Feeds")
            Rel_U(other, customerA, "Asks")
            Rel(customerA, nobody, "Lost")
            UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="1")
        """
        guard case let .c4(d) = MermaidParser.parse(src) else {
            Issue.record("expected c4 diagram")
            return
        }
        #expect(d.title == "System Context diagram for Internet Banking System")
        #expect(d.elements.map(\.label) == [
            "Banking Customer A",
            "Internet Banking System",
            "Mainframe Banking System",
            "Events",
            "Visitor",
        ])
        #expect(d.boundaries.count == 2)
        #expect(d.boundaries[0].title == "BankBoundary0\n[Enterprise]")
        #expect(d.boundaries[1].parent == 0)
        #expect(d.elements[0].boundary == 0)
        #expect(d.elements[2].boundary == 1)
        #expect(d.elements[3].boundary == nil)
        #expect(d.elements[2].store == .db && d.elements[2].external == true)
        #expect(d.elements[3].techn == "Kafka" && d.elements[3].descr == "Domain events")
        #expect(C4Parser.stereotype(d.elements[2]) == "«external_system_db»")
        #expect(d.edges.count == 4)
        #expect(d.edges[1].label == "Uses\n[XML/HTTPS]")
        #expect(d.edges[1].start == .arrow && d.edges[1].end == .arrow)
        #expect(d.edges[2].from == 3 && d.edges[2].start == .arrow && d.edges[2].end == .none)
        #expect(d.edges[3].from == 0 && d.edges[3].to == 4 && d.edges[3].start == .arrow)
        #expect(MermaidParser.parse("C4Context\n    title Empty") == nil)
    }

    @Test("5c.#7 chart axis labels never overlap")
    func chartAxisLabelsNeverOverlap() {
        var c = Canvas()
        let font = MermaidChart.small(dark)
        let ticks: [(Float, Measured)] = [
            (0.0, measureText("2024-01-01", font: font)),
            (40.0, measureText("2024-01-02", font: font)),
            (80.0, measureText("2024-01-03", font: font)),
            (200.0, measureText("2024-01-04", font: font)),
        ]
        MermaidChart.axisX(
            &c,
            ticks: ticks,
            xRange: (0.0, 200.0),
            yRange: (0.0, 100.0),
            font: font,
            paint: dark
        )
        #expect(c.labels.count < 4)
        for l in c.labels {
            #expect(l.at.x >= 0.0 && l.at.x + l.size.x <= 200.01)
        }
        for i in 0..<max(0, c.labels.count - 1) {
            #expect(c.labels[i + 1].at.x >= c.labels[i].at.x + c.labels[i].size.x)
        }
    }

    // MARK: - Date (5c.#13, #14, #16, #17)

    @Test("5c.#13, #14, #16, #17 date calendar, parsing, formatting, and ticks parity")
    func dateFullParity() {
        // 5c.#13 calendar_round_trips_over_centuries
        #expect(MermaidDate.daysFromCivil(1970, 1, 1) == 0)
        #expect(MermaidDate.daysFromCivil(2000, 3, 1) == 11_017)
        for d in [-800_000, -1, 0, 59, 11_016, 19_723, 2_000_000] as [Int64] {
            let (y, m, dayVal) = MermaidDate.civilFromDays(d)
            #expect(MermaidDate.daysFromCivil(y, m, dayVal) == d)
        }
        #expect(MermaidDate.fields(day(2024, 1, 7)).wd == 0)

        // 5c.#14 reads_dayjs_dates
        #expect(MermaidDate.parse("2024-01-05", format: "YYYY-MM-DD") == day(2024, 1, 5))
        #expect(MermaidDate.parse("05/01/2024", format: "DD/MM/YYYY") == day(2024, 1, 5))
        #expect(MermaidDate.parse("2024-01-05 14:30", format: "YYYY-MM-DD HH:mm") == day(2024, 1, 5) + 14.0 * MermaidDate.hour + 30.0 * MermaidDate.min)
        #expect(MermaidDate.parse("Jan 5 2024 3:15 pm", format: "MMM D YYYY h:mm a") == day(2024, 1, 5) + 15.0 * MermaidDate.hour + 15.0 * MermaidDate.min)
        #expect(MermaidDate.parse("2024-01-05", format: "DD.MM.YY") == day(2024, 1, 5))
        #expect(MermaidDate.parse("1704412800", format: "X") == day(2024, 1, 5))

        // 5c.#16 formats_d3_dates
        let ts = day(2024, 3, 7) + 15.0 * MermaidDate.hour + 4.0 * MermaidDate.min
        #expect(MermaidDate.format(ts, fmt: "%Y-%m-%d %H:%M") == "2024-03-07 15:04")
        #expect(MermaidDate.format(ts, fmt: "%b %d") == "Mar 07")
        #expect(MermaidDate.format(ts, fmt: "%a %e %I:%M %p") == "Thu  7 03:04 PM")
        #expect(MermaidDate.format(ts, fmt: "100%% %B") == "100% March")

        // 5c.#17 calendar_ticks_step_on_sundays_and_months
        let w = MermaidDate.Step.weeks(1).ticks(lo: day(2024, 1, 3), hi: day(2024, 1, 22), max: 10)
        #expect(w.first == day(2024, 1, 7))
        #expect(MermaidDate.fields(w[0]).wd == 0)
        let m = MermaidDate.Step.months(1).ticks(lo: day(2024, 1, 15), hi: day(2024, 4, 2), max: 10)
        #expect(m == [day(2024, 2, 1), day(2024, 3, 1), day(2024, 4, 1)])
        #expect(MermaidDate.Step.days(1).ticks(lo: day(2024, 1, 1), hi: day(2024, 2, 1), max: 5).count == 5)
    }

    // MARK: - ER & Flowchart (5c.#18, #19, #21, #26, #32, #33)

    @Test("5c.#18, #19, #21 ER endpoints and MAX_ITEMS bound")
    func erFullAuditParity() {
        guard case let .er(d1) = MermaidParser.parse("""
        erDiagram
          CUSTOMER ||--o{ ORDER : places
          ORDER ||--|{ LINE-ITEM : contains
          CUSTOMER }|..|{ DELIVERY-ADDRESS : uses
          PERSON |o--o| SEAT : "sits in"
        """) else {
            Issue.record("expected ER")
            return
        }
        func ends(_ d: ErDiagram, _ i: Int) -> (String, EdgeHead, EdgeLine, EdgeHead, String) {
            let e = d.edges[i]
            return (d.entities[e.from].id, e.start, e.line, e.end, d.entities[e.to].id)
        }
        #expect(ends(d1, 0) == ("CUSTOMER", .onlyOne, .solid, .zeroOrMore, "ORDER"))
        #expect(ends(d1, 1) == ("ORDER", .onlyOne, .solid, .oneOrMore, "LINE-ITEM"))
        #expect(ends(d1, 2) == ("CUSTOMER", .oneOrMore, .dotted, .oneOrMore, "DELIVERY-ADDRESS"))
        #expect(ends(d1, 3) == ("PERSON", .zeroOrOne, .solid, .zeroOrOne, "SEAT"))

        guard case let .er(d2) = MermaidParser.parse("""
        erDiagram
          direction LR
          CAR 1 to zero or more NAMED-DRIVER : allows
          PERSON many(0) optionally to 1+ "Club House" : joins
        """) else {
            Issue.record("expected ER worded")
            return
        }
        #expect(ends(d2, 0) == ("CAR", .onlyOne, .solid, .zeroOrMore, "NAMED-DRIVER"))
        #expect(ends(d2, 1) == ("PERSON", .zeroOrMore, .dotted, .oneOrMore, "Club House"))

        let budget = "erDiagram\n" + (0..<MermaidLimits.maxItems).map { "E\($0) ||--o{ F\($0) : r" }.joined(separator: "\n")
        #expect(MermaidParser.parse(budget) == nil)
    }

    @Test("5c.#26, #32, #33 flowchart exact node labels and edge pairs")
    func flowchartEdgeAndLabelAuditParity() {
        func edgesOf(_ f: FlowchartDiagram) -> [(String, String)] {
            f.edges.map { (f.nodes[$0.from].id, f.nodes[$0.to].id) }
        }
        // 5c.#26 named_edges_and_their_settings_add_no_nodes
        guard case let .flowchart(f1) = MermaidParser.parse("flowchart LR\n  A e1@--> B\n  B e2@-.-> C\n  e1@{ animate: true }\n  e2@{ animation: fast }") else {
            Issue.record("expected flowchart")
            return
        }
        let e1 = edgesOf(f1)
        #expect(e1.count == 2 && e1[0] == ("A", "B") && e1[1] == ("B", "C"))
        #expect(f1.edges[1].line == .dotted)
        #expect(f1.nodes.count == 3)

        // 5c.#32 an_unclosed_shape_is_a_rectangle_with_its_text_as_written
        let src2 = "flowchart LR\n  A[List + count] --> B[/items split view]\n  B --> C[Details]\n  C --> D[Pause / Resume / Delete]"
        guard case let .flowchart(f2) = MermaidParser.parse(src2) else {
            Issue.record("expected flowchart 2")
            return
        }
        #expect(f2.nodes.map(\.id) == ["A", "B", "C", "D"])
        #expect(f2.nodes.map(\.label) == ["List + count", "/items split view", "Details", "Pause / Resume / Delete"])
        #expect(f2.nodes.allSatisfy { $0.shape == .rect })
        let e2 = edgesOf(f2)
        #expect(e2.count == 3 && e2[0] == ("A", "B") && e2[1] == ("B", "C") && e2[2] == ("C", "D"))

        // 5c.#33 punctuation_in_labels_is_plain_text
        let src3 = "flowchart LR\n  a[setting.some_name] --> b[run_* + /go]\n  c[(store -> row)] --> d[Item.Worker]\n  d --> e[/api/v2/item]"
        guard case let .flowchart(f3) = MermaidParser.parse(src3) else {
            Issue.record("expected flowchart 3")
            return
        }
        let e3 = edgesOf(f3)
        #expect(e3.count == 3 && e3[0] == ("a", "b") && e3[1] == ("c", "d") && e3[2] == ("d", "e"))
    }

    // MARK: - Gantt & Git (5c.#38, #42, #43, #44, #45)

    @Test("5c.#38, #42 gantt AST, labels, late milestone fit, and bounds")
    func ganttFullAuditParity() {
        guard case let .gantt(g) = MermaidParser.parse("""
        gantt
         title Release
         dateFormat YYYY-MM-DD
         axisFormat %b %d
         section Build
         Design :done, des, 2024-01-01, 2024-01-05
         Code :active, code, after des, 5d
         Test :crit, 3d
         section Ship
         Review :rev, after code test2, 2d
         Launch :milestone, after des, until rev
         Freeze :vert, 2024-01-08, 0d
        """) else {
            Issue.record("expected gantt")
            return
        }
        func task(_ name: String) -> GanttTask { g.tasks.first { $0.name == name }! }
        #expect(g.title == "Release")
        #expect(g.sections == ["Build", "Ship"])
        #expect(g.axis == "%b %d")
        let des = task("Design")
        #expect((des.start, des.end, des.tags.done, des.section) == (day(2024, 1, 1), day(2024, 1, 5), true, 0))
        let code = task("Code")
        #expect((code.start, code.end, code.tags.active) == (day(2024, 1, 5), day(2024, 1, 10), true))
        let test = task("Test")
        #expect((test.start, test.end, test.tags.crit) == (day(2024, 1, 10), day(2024, 1, 13), true))
        let rev = task("Review")
        #expect(rev.start == day(2024, 1, 10) && rev.section == 1)
        let launch = task("Launch")
        #expect((launch.start, launch.end, launch.tags.milestone) == (day(2024, 1, 5), day(2024, 1, 10), true))
        #expect(task("Freeze").tags.vert)

        // 5c.#42 draws_bars_labels_and_an_axis
        let s = scene("gantt\ntitle Plan\nsection Work\nShort :2024-01-01, 1d\nA much longer task name :2024-01-02, 20d", paint: dark)!
        #expect(s.title == "Plan")
        let texts = s.labels.map(\.text)
        #expect(texts.contains("Work") && texts.contains("Short") && texts.contains("A much longer task name"))
        #expect(texts.contains { $0.hasPrefix("2024-01-") })
        let late = scene("gantt\nA :a, 2024-01-01, 20d\nA long milestone name at the very end :milestone, after a, 0d", paint: dark)!
        #expect(late.size.x <= Canvas.room(for: dark) + 2.01)
        let budget = "gantt\n" + (0...MermaidLimits.maxItems).map { "T\($0) :2024-01-01, 1d" }.joined(separator: "\n")
        #expect(MermaidParser.parse(budget) == nil)
    }

    @Test("5c.#43, #44, #45 gitGraph full AST, flows, labels, and bounds")
    func gitGraphFullAuditParity() {
        guard case let .git(g) = MermaidParser.parse("""
        gitGraph
            commit id: "Alpha"
            commit tag: "v1.0" type: HIGHLIGHT
            branch develop order: 2
            checkout develop
            commit id:"Beta" type: REVERSE
            commit
            switch main
            merge develop id: "M" tag: "v2"
            branch "feature/x"
            commit id: "F"
            cherry-pick id: "Beta"
            checkout nowhere
            merge main
            merge feature/x
            bogus line
        """) else {
            Issue.record("expected gitGraph")
            return
        }
        #expect(g.flow == .right)
        #expect(g.branches.map(\.name) == ["main", "develop", "feature/x"])
        #expect(g.branches[1].order == 2.0)
        #expect(g.commits.count == 7)
        #expect(g.commits[0].id == "Alpha" && g.commits[0].kind == .normal && g.commits[0].branch == 0 && g.commits[0].parents == [])
        #expect(g.commits[1].id == nil && g.commits[1].kind == .highlight && g.commits[1].branch == 0 && g.commits[1].parents == [0])
        #expect(g.commits[2].id == "Beta" && g.commits[2].kind == .reverse && g.commits[2].branch == 1 && g.commits[2].parents == [1])
        #expect(g.commits[3].id == nil && g.commits[3].kind == .normal && g.commits[3].branch == 1 && g.commits[3].parents == [2])
        #expect(g.commits[4].id == "M" && g.commits[4].kind == .merge && g.commits[4].branch == 0 && g.commits[4].parents == [1, 3])
        #expect(g.commits[5].id == "F" && g.commits[5].kind == .normal && g.commits[5].branch == 2 && g.commits[5].parents == [4])
        #expect(g.commits[6].id == nil && g.commits[6].kind == .cherryPick && g.commits[6].branch == 2 && g.commits[6].parents == [5])
        #expect(g.commits[1].tag == "v1.0")
        #expect(g.commits[4].tag == "v2")
        #expect(g.commits[6].picked == 2)

        // 5c.#44 flows_and_bounds
        guard case let .git(tb) = MermaidParser.parse("gitGraph TB:\ncommit"),
              case let .git(bt) = MermaidParser.parse("gitGraph BT:\ncommit") else {
            Issue.record("expected TB/BT gitGraph")
            return
        }
        #expect(tb.flow == .down && bt.flow == .up)
        #expect(MermaidParser.parse("gitGraph\nbranch x") == nil)
        #expect(MermaidParser.parse("gitGraph\n" + String(repeating: "commit\n", count: MermaidLimits.maxItems + 1)) == nil)

        // 5c.#45 draws_lanes_ids_and_tags
        for src in [
            "gitGraph\ncommit id: \"A\" tag: \"v1\"\nbranch dev\ncommit id: \"B\"\ncheckout main\nmerge dev",
            "gitGraph TB:\ncommit id: \"A\"\nbranch dev\ncommit id: \"B\" tag: \"t\"",
        ] {
            let s = scene(src, paint: light)!
            let texts = s.labels.map(\.text)
            for t in ["main", "dev", "A", "B"] {
                #expect(texts.contains(t), "\(t) in \(texts)")
            }
        }
    }

    // MARK: - Hover (5c.#46, #47, #49, #51, #53, #54)

    @Test("5c.#46, #47, #49, #51, #53 hover spots, slop, isolation, lineHits, and keys")
    func hoverStaticFullAuditParity() {
        let lit = Color(r: 0.9, g: 0.2, b: 0.5, a: 1.0)
        func litScene(_ src: String) -> MermaidScene { scene(src, paint: light, hover: (.edges, lit))! }
        func labelIdx(_ s: MermaidScene, _ text: String) -> Int { s.labels.firstIndex { $0.text == text }! }
        func spots(_ s: MermaidScene, _ prefix: String) -> [HoverSpot] { s.hovers.filter { $0.key.hasPrefix(prefix) } }

        // 5c.#46 a_node_lights_its_edges_labels
        let sf = litScene("flowchart TD\n  A -->|go| B")
        let go = labelIdx(sf, "go")
        for nodeKey in ["hover:n:A", "hover:n:B"] {
            let spot = spots(sf, nodeKey).first!
            #expect(spot.labels == [go])
        }
        let st = litScene("stateDiagram-v2\n  Idle --> Busy : start")
        let start = labelIdx(st, "start")
        #expect(spots(st, "hover:n:").allSatisfy { $0.labels == [start] })

        // 5c.#47 an_edge_lights_itself_and_its_label_and_nodes_win
        let st2 = litScene("stateDiagram-v2\n  Idle --> Busy : start\n  Busy --> Done")
        let start2 = labelIdx(st2, "start")
        let first = spots(st2, "hover:e:Idle>Busy.")
        #expect(first.count >= 2 && first.allSatisfy { $0.labels == [start2] })
        let nodeRects = spots(st2, "hover:n:").map(\.rect)
        let overlap: ((Float, Float, Float, Float), (Float, Float, Float, Float)) -> Bool = { a, b in
            a.0 < b.0 + b.2 && b.0 < a.0 + a.2 && a.1 < b.1 + b.3 && b.1 < a.1 + a.3
        }
        for h in spots(st2, "hover:e:") {
            #expect(h.rect.2 >= 4.0 && h.rect.3 >= 4.0)
            #expect(!nodeRects.contains { overlap($0, h.rect) })
            #expect(h.rect.0.isFinite && h.rect.1.isFinite && h.rect.2.isFinite && h.rect.3.isFinite)
        }
        let thin = first.map { min($0.rect.2, $0.rect.3) }.min() ?? 0.0
        #expect(thin >= 2.0 * HoverConstants.edgeSlop - 0.5)
        let second = spots(st2, "hover:e:Busy>Done.")
        #expect(!second.isEmpty && second.allSatisfy { $0.labels.isEmpty })

        // 5c.#49 one_edges_hover_leaves_other_edges_unlit
        let iso = litScene("flowchart LR\n  A -->|go| B\n  C -->|stay| D")
        let isoGo = labelIdx(iso, "go")
        let isoStay = labelIdx(iso, "stay")
        for key in ["hover:n:A", "hover:n:B", "hover:e:A>B."] {
            for h in spots(iso, key) {
                #expect(h.labels == [isoGo] && !h.labels.contains(isoStay))
            }
        }
        #expect(!iso.hovers.contains { $0.labels.contains(isoGo) && $0.labels.contains(isoStay) })

        // 5c.#51 line_hits_cover_a_bend_and_stay_bounded
        let lBend = HoverGeometry.lineHits(line: [Vec2(0, 0), Vec2(0, 100), Vec2(100, 100)], slop: HoverConstants.edgeSlop)
        #expect(lBend.count == 2)
        let diag = HoverGeometry.lineHits(line: [Vec2(0, 0), Vec2(300, 300)], slop: HoverConstants.edgeSlop)
        #expect(diag.count > 1 && diag.count <= HoverConstants.edgeHits)
        let wiggle = (0..<400).map { i in Vec2(Float(i) * 3.0, i % 2 == 0 ? 0.0 : 30.0) }
        #expect(HoverGeometry.lineHits(line: wiggle, slop: HoverConstants.edgeSlop).count <= 16)
        let cutKeep = HoverGeometry.cutAway([(0.0, 0.0, 16.0, 100.0)], nodes: [(-10.0, 80.0, 40.0, 40.0)])
        #expect(cutKeep.count == 1 && cutKeep[0] == (0.0, 0.0, 16.0, 80.0))
        #expect(HoverGeometry.cutAway([(0.0, 0.0, 16.0, 16.0)], nodes: [(-10.0, -10.0, 40.0, 40.0)]).isEmpty)

        // 5c.#53 hover_groups_are_keyed_by_the_piece_they_light
        let ks = litScene("flowchart TD\n  A -->|go| B\n  B --> C\n")
        let pieceKeys = Set(ks.pieces.map(\.key))
        for h in ks.hovers {
            #expect(h.key.hasPrefix("hover:"))
            let stripped = String(h.key.dropFirst("hover:".count))
            let piece: String
            if stripped.hasPrefix("e:"), let dot = stripped.lastIndex(of: ".") {
                piece = String(stripped[..<dot])
            } else {
                piece = stripped
            }
            #expect(pieceKeys.contains(piece))
            if piece.hasPrefix("e:"), let idx = h.labels.first {
                #expect(ks.labelKeys[idx].key == "\(piece).t0")
            }
        }
        #expect(ks.hovers.contains { $0.key == "hover:e:A>B.t" })
    }

    @Test("5c.#54 still pointer keeps what it hovers or lets go as a streaming diagram moves")
    func hoverStillPointerDuringStreamingGrowth() {
        let lit = Color(r: 0.9, g: 0.2, b: 0.5, a: 1.0)
        let src = "graph TD\n  X -->|in| S\n  S --> W\n  W -->|out| Y\n"
        let grown = src + "  subgraph S\n    D\n  end\n"

        func litLabels(_ rt: Runtime<String>) -> [[String]] {
            let all = rt.elements()
            return all.filter { $0.hover > 0.0 && $0.key != nil }.map { g in
                let inside = g.path + "/"
                return all.filter { $0.path.hasPrefix(inside) }.compactMap(\.text).sorted()
            }
        }

        func rect(_ rt: Runtime<String>, _ key: String) -> [Float]? {
            rt.elements().first { $0.key == key && !$0.exiting }?.rect
        }

        for (overKey, before) in [("hover:e:W>Y.t", ["out"]), ("hover:n:S", ["in"])] {
            let rt = Runtime<String>(state: src, viewport: Vec2(600, 600)) { s, _ in
                let child: El<String>? = renderMermaidStreaming(s, theme: MermaidTheme.neutral(dark: false), hover: (.edges, lit))
                return col().wFull().children(child.map { [$0] } ?? [])
            }
            _ = rt.frame(at: 0.0)
            let at = rect(rt, overKey)!
            let y0 = rect(rt, "n:Y")!
            rt.pointerMove(to: Vec2(at[0] + at[2] / 2.0, at[1] + at[3] / 2.0), at: 1.0 / 60.0)
            _ = rt.frame(at: 1.0 / 60.0)
            let now = litLabels(rt)
            #expect(!now.isEmpty && now.allSatisfy { $0 == before })
            rt.update { s, _ in s = grown }
            for step in 2...240 {
                _ = rt.frame(at: Double(step) / 60.0)
                if !rt.elements().contains(where: { $0.moving }) { break }
                for l in litLabels(rt) {
                    #expect(l == before)
                }
            }
            let y2 = rect(rt, "n:Y")!
            #expect(abs(y2[1] - y0[1]) > 8.0)
        }
    }

    // MARK: - Ink, Journey, Layered Draw, Mindmap (5c.#56, #57, #59, #60, #65, #80, #81)

    @Test("5c.#56, #57 opaque ink over surface across all 9 samples and arrowhead color match")
    func inkFullAuditParity() {
        let sources = [
            "flowchart TD\n  A --> B",
            "flowchart TD\n  subgraph S [Box]\n    A --> B\n  end\n  B -.-> C\n  C ==> A",
            "sequenceDiagram\n  participant A\n  participant B\n  A->>B: hi\n  B-->>A: back\n  A-)B: async\n  Note over A,B: note",
            "stateDiagram-v2\n  [*] --> Idle\n  Idle --> Busy : go\n  Busy --> [*]",
            "classDiagram\n  Animal <|-- Duck\n  Animal *-- Leg\n  Animal o-- Tail\n  class Animal {\n    +int age\n    +eat()\n  }",
            "erDiagram\n  CUSTOMER ||--o{ ORDER : places\n  ORDER ||--|{ LINE : contains",
            "journey\n  title Day\n  section Work\n    Code: 5: Me\n    Meet: 2: Me, You",
            "timeline\n  2024 : one\n  2025 : two : three",
            "gitGraph\n  commit\n  branch dev\n  commit\n  checkout main\n  merge dev",
        ]
        for isDark in [true, false] {
            let paint = MermaidTheme.neutral(dark: isDark)
            #expect(paint.surface.a == 1.0)
            for src in sources {
                let s = scene(src, paint: paint)!
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

        // 5c.#57 ops[3] arrowhead color matches ops[2] line color
        let surface = Color(r: 0.02, g: 0.02, b: 0.02, a: 1.0)
        let tint = Color.white.alpha(0.1)
        let ink = Color.white.alpha(0.5)
        var c = Canvas()
        c.fill([Vec2(0, 0), Vec2(100, 0), Vec2(100, 100), Vec2(0, 100)], color: tint)
        c.stroke([Vec2(10, 50), Vec2(90, 50)], closed: false, width: 1.0, color: ink)
        c.stroke([Vec2(110, 50), Vec2(190, 50)], closed: false, width: 1.0, color: ink)
        c.fill([Vec2(150, 40), Vec2(160, 50), Vec2(150, 60)], color: ink)
        InkFlattener.flatten(ops: &c.ops, traces: &c.traces, surface: surface)
        let colors: [Color] = c.ops.map {
            switch $0 {
            case let .fill(_, col), let .stroke(_, _, _, _, col): return col
            }
        }
        #expect(colors[0] == tint)
        #expect(colors[1] == InkFlattener.over(ink, InkFlattener.over(tint, surface)))
        #expect(colors[2] == InkFlattener.over(ink, surface))
        #expect(colors[3] == colors[2])
    }

    @Test("5c.#59, #60 journey AST, skips, labels, mood OKLab, and bounds")
    func journeyFullAuditParity() {
        guard case let .journey(j) = MermaidParser.parse("""
        journey
            title My working day
            section Go to work
              Make tea: 5: Me
              Go upstairs: 3: Me
              Do work: 1: Me, Cat
            section Go home
              Go downstairs: 9: Cat
              No score here
              Bad: lots: Me
              Sit down: 0
        """) else {
            Issue.record("expected journey")
            return
        }
        #expect(j.title == "My working day")
        #expect(j.sections == ["Go to work", "Go home"])
        #expect(j.actors == ["Me", "Cat"])
        #expect(j.tasks == [
            JourneyTask(name: "Make tea", score: 5.0, actors: [0], section: 0),
            JourneyTask(name: "Go upstairs", score: 3.0, actors: [0], section: 0),
            JourneyTask(name: "Do work", score: 1.0, actors: [0, 1], section: 0),
            JourneyTask(name: "Go downstairs", score: 5.0, actors: [1], section: 1),
            JourneyTask(name: "Sit down", score: 1.0, actors: [], section: 1),
        ])
        #expect(MermaidParser.parse("journey\ntitle Empty\nsection A") == nil)
        let budget = "journey\n" + (0...MermaidLimits.maxItems).map { "t\($0): 3: Me" }.joined(separator: "\n")
        #expect(MermaidParser.parse(budget) == nil)

        let s = scene("journey\nsection Day\nGood: 5: Me\nBad: 1: Me", paint: light)!
        let texts = s.labels.map(\.text)
        for t in ["Day", "Good", "Bad", "Me"] {
            #expect(texts.contains(t))
        }
        #expect(JourneyParser.mood(5.0, paint: light).toOKLab()[0] > 0.5)
        #expect(JourneyParser.mood(1.0, paint: light).toOKLab()[0] > 0.5)
    }

    @Test("5c.#65 dashed edge to subgraph terminates on cluster border")
    func edgeToSubgraphStopsOnBorderAudit() {
        let chat = """
        flowchart TD
          subgraph cluster[Chat]
            A[Msg]
            B[Reply]
          end
          Out[User] -.-> cluster
        """
        guard case let .flowchart(f) = MermaidParser.parse(chat),
              let c = FlowchartParser.drawCanvas(f, paint: light, hover: nil) else {
            Issue.record("expected flowchart canvas")
            return
        }
        let clusterBoxes: [(Float, Float, Float, Float)] = c.ops.compactMap {
            guard case let .fill(pts, _) = $0, pts.count > 8 else { return nil }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            return (xs.min()!, ys.min()!, xs.max()!, ys.max()!)
        }
        let b = clusterBoxes.first!
        let dashes: [[Vec2]] = c.ops.compactMap {
            guard case let .stroke(pts, _, _, roundCap, _) = $0, !roundCap else { return nil }
            return pts
        }
        #expect(!dashes.isEmpty)
        var minDist = Float.greatestFiniteMagnitude
        for p in dashes.flatMap({ $0 }) {
            let dx = max(b.0 - p.x, p.x - b.2, 0.0)
            let dy = max(b.1 - p.y, p.y - b.3, 0.0)
            minDist = min(minDist, max(dx, dy))
        }
        #expect(minDist < 1.5)
    }

    @Test("5c.#80, #81 mindmap AST indentation, shapes, skips, depth/item bounds")
    func mindmapFullAuditParity() {
        guard case let .mindmap(m) = MermaidParser.parse(
            "mindmap\n  root((mindmap))\n    Origins\n      Long history\n      ::icon(fa fa-book)\n      Popularisation\n        British author\n    Research\n      a[On effectiveness<br/>and features]\n      b))Bang((\n      c)Cloud(\n      d{{Hex}}\n      e(Rounded):::urgent\n    Tools\n      f[unclosed"
        ) else {
            Issue.record("expected mindmap")
            return
        }
        func texts(_ i: Int) -> [String] { m.nodes[i].children.map { m.nodes[$0].text } }
        #expect(m.nodes[0].text == "mindmap" && m.nodes[0].look == .circle)
        #expect(texts(0) == ["Origins", "Research", "Tools"])
        #expect(texts(1) == ["Long history", "Popularisation"])
        let research = m.nodes[0].children[1]
        #expect(texts(research) == ["On effectiveness\nand features", "Bang", "Cloud", "Hex", "Rounded"])
        #expect(m.nodes[research].children.map { m.nodes[$0].look } == [.square, .bang, .cloud, .hexagon, .rounded])
        let tools = m.nodes[0].children[2]
        let fNode = m.nodes[m.nodes[tools].children[0]]
        #expect(fNode.text == "f[unclosed" && fNode.look == .plain)

        // 5c.#81 one_root_and_bounds
        guard case let .mindmap(m2) = MermaidParser.parse("mindmap\n    Root\n  Shallower\n  Sibling\n    Child") else {
            Issue.record("expected mindmap 2")
            return
        }
        #expect(m2.nodes[0].children.map { m2.nodes[$0].text } == ["Shallower", "Sibling"])
        #expect(m2.nodes[2].children.map { m2.nodes[$0].text } == ["Child"])
        #expect(MermaidParser.parse("mindmap") == nil)
        let deep = (0...(MermaidLimits.maxDepth + 1)).map { d in String(repeating: "  ", count: d) + "n\(d)\n" }.joined()
        #expect(MermaidParser.parse("mindmap\n" + deep) == nil)
        let wide = "mindmap\nroot\n" + (0..<MermaidLimits.maxItems).map { "  n\($0)" }.joined(separator: "\n")
        #expect(MermaidParser.parse(wide) == nil)
    }

    // MARK: - Parts & Streaming Runtime (5c.#83, #84, #85, #86)

    @Test("5c.#83, #84 parts exact keys across flowchart, subgraph, sequence, and state")
    func partsKeysExactParity() {
        func keys(_ src: String) -> [String] {
            let s = scene(src, paint: dark, hover: (.edges, dark.text))!
            return s.pieces.map(\.key) + s.labelKeys.map(\.key)
        }
        let a = keys("graph TD\n  A[Start] --> B{Ok?}\n")
        for want in ["n:A", "n:B", "e:A>B", "n:A.t0", "n:B.t0"] { #expect(a.contains(want)) }
        let b = keys("graph TD\n  A[Start] --> B{Ok?}\n  B -->|yes| C[Done]\n  B --> C\n")
        #expect(a.allSatisfy { b.contains($0) })
        for want in ["n:C", "e:B>C", "e:B>C~1", "e:B>C.t0"] { #expect(b.contains(want)) }
        let c = keys("graph TD\n  subgraph core [Core]\n    A --> B\n  end\n  B --> C\n")
        for want in ["g:core", "g:core.t0", "n:A", "n:B", "n:C", "e:A>B", "e:B>C"] { #expect(c.contains(want)) }

        let sa = keys("sequenceDiagram\n  participant A\n  participant B\n  A->>B: hi\n")
        for want in ["n:p0", "n:p1", "n:p0.end", "g:life0", "e:m0", "e:m0.t0"] { #expect(sa.contains(want)) }
        let sb = keys("sequenceDiagram\n  participant A\n  participant B\n  A->>B: hi\n  B-->>A: hello\n  Note over A,B: done\n")
        #expect(sa.allSatisfy { sb.contains($0) })
        for want in ["e:m1", "n:note2"] { #expect(sb.contains(want)) }

        let st = keys("stateDiagram-v2\n  [*] --> Idle\n  Idle --> Busy : go\n")
        for want in ["n:Idle", "n:Busy", "e:Idle>Busy", "e:Idle>Busy.t0"] { #expect(st.contains(want)) }
    }

    @Test("5c.#85, #86 Runtime mount vs streaming enter/settle symmetry")
    func runtimeFinishedAndStreamingParity() {
        let one = "graph TD\n  A[Start] --> B[Check]\n"
        let two = "graph TD\n  A[Start] --> B[Check]\n  B --> C[Done]\n"
        let paint = dark

        func makeRt(src: String, streaming: Bool) -> Runtime<String> {
            Runtime<String>(state: src, viewport: Vec2(600, 600)) { s, _ in
                let el: El<String>? = streaming
                    ? renderMermaidStreaming(s, theme: paint, hover: (.edges, paint.text))
                    : renderMermaid(s, theme: paint, hover: (.edges, paint.text))
                return col().wFull().children(el.map { [$0] } ?? [])
            }
        }

        // 5c.#85 a_finished_diagram_shows_whole_the_frame_it_mounts
        let rtMounted = makeRt(src: "", streaming: false)
        _ = rtMounted.frame(at: 0.0)
        rtMounted.update { s, _ in s = two }
        _ = rtMounted.frame(at: 0.0)
        #expect(rtMounted.element(byKey: "n:C") != nil && rtMounted.element(byKey: "e:B>C") != nil)
        let shown = rtMounted.elements().filter { e in
            let okKey = e.key.map { !$0.hasPrefix("hover:") && $0 != "lit" } ?? true
            return okKey && !e.path.contains("/@hover:") && !e.path.contains("/hover:")
        }
        #expect(shown.allSatisfy { $0.opacity == 1.0 && $0.scale == 1.0 })

        let rtRebuild = makeRt(src: one, streaming: false)
        _ = rtRebuild.frame(at: 0.0)
        rtRebuild.update { s, _ in s = two }
        _ = rtRebuild.frame(at: 0.0)
        #expect(rtRebuild.element(byKey: "n:C")?.opacity == 1.0)

        // 5c.#86 a_streaming_diagram_brings_new_nodes_in_and_glides_the_rest
        let rtStream = makeRt(src: one, streaming: true)
        _ = rtStream.frame(at: 0.0)
        for step in 1...90 {
            _ = rtStream.frame(at: Double(step) / 60.0)
        }
        let aPathBefore = rtStream.element(byKey: "n:A")!.path
        rtStream.update { s, _ in s = two }
        _ = rtStream.frame(at: 91.0 / 60.0)
        let cMid = rtStream.element(byKey: "n:C")!
        #expect(cMid.opacity < 0.5 && cMid.scale < 1.0)
        #expect(rtStream.element(byKey: "n:A")?.opacity == 1.0)
        for step in 92...181 {
            _ = rtStream.frame(at: Double(step) / 60.0)
        }
        let cDone = rtStream.element(byKey: "n:C")!
        let aDone = rtStream.element(byKey: "n:A")!
        #expect((cDone.opacity, cDone.scale) == (1.0, 1.0))
        #expect(aDone.path == aPathBefore)
    }

    // MARK: - Pie, Quadrant, Requirement (5c.#88, #89, #91, #93, #94)

    @Test("5c.#88, #89 pie inline title, floats, bad-line skips, and 1/3 precision")
    func pieFullAuditParity() {
        let p = PieParser.parse(header: "showData title Pets adopted", body: [
            "\"Dogs\" : 386",
            "\"Cats\" : 85.5",
            "Rats : 15",
            "\"Bad\" : -3",
            "\"Zero\" : 0",
            "not a slice",
            "\"x\" : lots",
        ])!
        #expect(p.title == "Pets adopted")
        #expect(p.showData == true)
        #expect(p.slices.map(\.0) == ["Dogs", "Cats", "Rats"])
        #expect(p.slices.map(\.1) == [386.0, 85.5, 15.0])

        let p2 = PieParser.parse(header: "", body: ["title Key: value", "\"A: one\" : 1"])!
        #expect(p2.title == "Key: value")
        #expect(p2.slices[0].0 == "A: one")
        #expect(p2.showData == false)
        #expect(MermaidParser.parse("pie title Empty") == nil)

        #expect(PieParser.formatNumber(386.0) == "386")
        #expect(PieParser.formatNumber(85.5) == "85.5")
        #expect(PieParser.formatNumber(1.0 / 3.0) == "0.33")
    }

    @Test("5c.#91 quadrant full AST, classes, colors, skips, and bounds")
    func quadrantFullAuditParity() {
        guard case let .quadrant(q) = MermaidParser.parse("""
        quadrantChart
            title Reach and engagement
            x-axis Low Reach --> High Reach
            y-axis Engagement
            quadrant-1 We should expand
            quadrant-4 May be improved
            quadrant-9 Nope
            Campaign A: [0.3, 0.6]
            Campaign B: [0.45, 0.23] radius: 12, color: #ff3300, stroke-color: #10f0f0, stroke-width: 5px
            Point C:::hot: [1.4, -0.2]
            Broken: [x, 1]
            classDef hot color: #109060, radius : 10
        """) else {
            Issue.record("expected quadrant")
            return
        }
        #expect(q.title == "Reach and engagement")
        #expect(q.x == ["Low Reach", "High Reach"])
        #expect(q.y == ["Engagement", ""])
        #expect(q.names[0] == "We should expand")
        #expect(q.names[3] == "May be improved")
        #expect(q.names[1] == "")
        #expect(q.points.map(\.name) == ["Campaign A", "Campaign B", "Point C"])
        #expect(q.points[1].look.radius == 12.0 && q.points[1].look.strokeWidth == 5.0)
        #expect(q.points[1].look.color != nil && q.points[1].look.stroke != nil)
        #expect(q.points[2].at == Vec2(1.0, 0.0) && q.points[2].look.radius == 10.0)
        #expect(MermaidParser.parse("quadrantChart\n    title Only a title") == nil)
        let budget = "quadrantChart\n" + (0...MermaidLimits.maxItems).map { "p\($0): [0.5, 0.5]" }.joined(separator: "\n")
        #expect(MermaidParser.parse(budget) == nil)
    }

    @Test("5c.#93, #94 requirement AST, formatted fields, rels, and drawn labels")
    func requirementFullAuditParity() {
        guard case let .requirement(d) = MermaidParser.parse("""
        requirementDiagram
            direction LR
            requirement test_req {
            id: 1
            text: the test text.
            risk: high
            verifymethod: test
            }
            functionalRequirement "Fast start":::hot {
            id: 1.1
            risk: LOW }
            element test_entity {
            type: simulation
            docref: reqs/test_entity
            }
            test_entity - satisfies -> test_req
            test_req - contains -> "Fast start"
            test_req <- copies - other
            a - likes -> b
            classDef hot fill:#f96
        """) else {
            Issue.record("expected requirement")
            return
        }
        #expect(d.dir == .right)
        #expect(d.nodes.map(\.name) == ["test_req", "Fast start", "test_entity", "other"])
        #expect(d.nodes[0].fields == ["ID: 1", "Text: the test text.", "Risk: High", "Verification: Test"])
        #expect(d.nodes[1].kind == "Functional Requirement" && d.nodes[1].fields == ["ID: 1.1", "Risk: Low"])
        #expect(d.nodes[2].fields == ["Type: simulation", "Doc Ref: reqs/test_entity"])
        #expect(d.nodes[3].kind == "")
        #expect(d.nodes[1].style.fill != nil)
        #expect(d.edges.count == 3)
        #expect(d.edges[0].from == 2 && d.edges[0].to == 0 && d.edges[0].label == "«satisfies»")
        #expect(d.edges[1].start == .contains && d.edges[1].line == .solid)
        #expect(d.edges[2].from == 3 && d.edges[2].to == 0 && d.edges[2].end == .arrow)
        #expect(MermaidParser.parse("requirementDiagram\n    direction TB") == nil)

        let s = scene("requirementDiagram\nrequirement r {\nid: 7\n}\nelement e {\ntype: code\n}\ne - verifies -> r", paint: light)!
        let texts = s.labels.map(\.text)
        for want in ["«Requirement»", "r", "ID: 7", "«Element»", "Type: code", "«verifies»"] {
            #expect(texts.contains(want))
        }
    }

    // MARK: - Route, Sankey, Sequence, Shape (5c.#96, #98, #100, #101, #102, #105, #109, #116)

    @Test("5c.#96, #98, #100 route kinks, long-edge clearance, and arrowhead boundary contact")
    func routeFullAuditParity() {
        // 5c.#96 flowchart_edges_draw_without_kinks
        let kinkSrc = "flowchart TD\n  A[Audio] --> B[Parakeet writes text<br/>'went to the capuchin']\n  B --> C{Any word that looks<br/>or sounds like a term?}\n  C -- no --> F[Paste as is]\n  C -- \"capuchin ≈ Cappuccino\" --> D[Score the same audio twice:<br/>as 'capuchin' and as 'Cappuccino']\n  D --> E{Cappuccino score + boost<br/>≥ capuchin score?}\n  E -- yes --> G[Write Cappuccino]\n  E -- no --> F"
        guard case let .flowchart(f1) = MermaidParser.parse(kinkSrc),
              let c1 = FlowchartParser.drawCanvas(f1, paint: dark, hover: (.edges, dark.text)) else {
            Issue.record("expected kink canvas")
            return
        }
        let lines: [[Vec2]] = c1.ops.compactMap {
            guard case let .stroke(pts, false, _, _, col) = $0, col == dark.line else { return nil }
            return pts
        }
        #expect(lines.count == 11)
        #expect(lines.allSatisfy { sharpestTurn($0) < 12.0 })
        #expect(c1.traces.count == 7)
        #expect(scene(kinkSrc, paint: dark) != nil)

        // 5c.#98 long_edges_stay_clear_of_the_nodes_they_pass
        let longSrc = "flowchart TD\n  A[Audio] --> B[Parakeet writes text]\n  B --> C{Any word that looks<br/>or sounds like a term?}\n  C -- no --> F[Paste as is]\n  C -- \"capuchin ≈ Cappuccino\" --> D[Score the same audio twice:<br/>as 'capuchin' and as 'Cappuccino']\n  D --> E{Cappuccino score + boost<br/>≥ capuchin score?}\n  E -- yes --> G[Write Cappuccino]\n  E -- no --> F"
        guard case let .flowchart(f2) = MermaidParser.parse(longSrc),
              let c2 = FlowchartParser.drawCanvas(f2, paint: dark, hover: (.edges, dark.text)) else {
            Issue.record("expected long canvas")
            return
        }
        let polyD = c2.regions[4], polyE = c2.regions[5]
        let longLines: [[Vec2]] = c2.ops.compactMap {
            guard case let .stroke(pts, false, _, _, col) = $0, col == dark.line else { return nil }
            return pts
        }
        for line in longLines[2..<4] {
            for i in 0..<(line.count - 1) {
                for k in 0...8 {
                    let p = CanvasMath.lerp(line[i], line[i + 1], Float(k) / 8.0)
                    #expect(!insidePoly(polyD, p) && !insidePoly(polyE, p))
                }
            }
        }

        // 5c.#100 every_direction_draws_smooth_edges_that_reach_their_nodes (seg_dist < 1.0)
        for dir in ["TD", "BT", "LR", "RL"] {
            let src = "flowchart \(dir)\n  A[Start] --> B[Left]\n  A --> C[Right]\n  B --> D[End]\n  C -- label --> D\n  A --> D"
            guard case let .flowchart(fd) = MermaidParser.parse(src),
                  let cd = FlowchartParser.drawCanvas(fd, paint: dark, hover: (.edges, dark.text)) else {
                Issue.record("expected \(dir) canvas")
                return
            }
            let tips: [Vec2] = cd.ops.compactMap {
                guard case let .fill(pts, col) = $0, col == dark.line, pts.count == 3 else { return nil }
                return pts[0]
            }
            #expect(tips.count == 5)
            for tip in tips {
                let touching = cd.regions.contains { r in
                    (0..<r.count).contains { k in segDist(tip, r[k], r[(k + 1) % r.count]) < 1.0 }
                }
                #expect(touching, "\(dir) arrow tip should touch node region")
            }
        }
    }

    @Test("5c.#101, #102 sankey CSV quotes, skips, columns bound, and MAX_ITEMS")
    func sankeyFullAuditParity() {
        guard case let .sankey(s) = MermaidParser.parse(
            "sankey-beta\n\nAgricultural 'waste',Bio-conversion,124.729\n\"Bio, conversion\",Liquid,0.597\n\"Say \"\"hi\"\"\",Losses,26.862\nbad row\nA,A,3\nA,B,-1\nA,B,x"
        ) else {
            Issue.record("expected sankey")
            return
        }
        #expect(s.nodes == ["Agricultural 'waste'", "Bio-conversion", "Bio, conversion", "Liquid", "Say \"hi\"", "Losses"])
        #expect(s.links.count == 3)
        #expect(s.links[2] == (4, 5, 26.862))
        #expect(MermaidParser.parse("sankey-beta\nnot,a number,here") == nil)
        let budget = "sankey-beta\n" + (0..<MermaidLimits.maxItems).map { "a\($0),b\($0),1" }.joined(separator: "\n")
        #expect(MermaidParser.parse(budget) == nil)

        guard case let .sankey(cyc) = MermaidParser.parse("sankey-beta\nA,B,5\nB,C,3\nA,D,2\nC,B,1") else {
            Issue.record("expected sankey cycle")
            return
        }
        let cols = SankeyParser.columns(cyc)
        #expect(cols[0] == 0 && cols[3] == cols.max() && cols.allSatisfy { $0 < cyc.nodes.count })
    }

    @Test("5c.#105, #109 sequence exact events and invalid autonumber skip")
    func sequenceEventsAndAutonumberParity() {
        guard case let .sequence(s) = MermaidParser.parse("""
        sequenceDiagram
          title Frame commit
          box rgb(30, 60, 90) Desk
            participant web-app
          end
          box Storage
            participant db
          end
          Note right of web-app: thinks
          note over web-app,db: shared<br>two lines
          loop Every minute
            web-app->>db: ping
          end
          alt ok
            activate db
            db-->>web-app: rows
            deactivate db
          else error
            db-->>web-app: 500
          end
          rect rgb(40, 80, 60)
            opt maybe
              web-app->db: x
            end
          end
        """) else {
            Issue.record("expected sequence")
            return
        }
        #expect(s.title == "Frame commit")
        #expect(s.boxes.count == 2 && s.boxes[0].title == "Desk" && s.boxes[0].color != nil)
        #expect(s.participants[0].group == 0 && s.participants[1].group == 1 && s.participants[0].id == "web-app")
        #expect({ if case .note(.right(0), "thinks") = s.events[0] { return true }; return false }())
        #expect({ if case .note(.over(0, 1), "shared\ntwo lines") = s.events[1] { return true }; return false }())
        #expect({ if case let .open(k, l, _) = s.events[2], k == "loop", l == "Every minute" { return true }; return false }())
        #expect(s.events.contains { if case .elseBranch("error") = $0 { return true }; return false })
        #expect(s.events.contains { if case .activate(1) = $0 { return true }; return false })
        #expect(s.events.contains { if case let .open(k, _, f) = $0, k == nil, f != nil { return true }; return false })
        #expect(s.events.filter { if case .end = $0 { return true }; return false }.count == 4)

        // 5c.#109
        #expect(MermaidParser.parse("sequenceDiagram\n  autonumber many\n  A->>B: hi") != nil)
    }

    @Test("5c.#116 cylinder rim bounds")
    func cylinderRimBoundsParity() {
        let label = measureText("Note: lasts, has versions", font: light.font)
        let size = ShapeRenderer.nodeSize(.cylinder, labelSize: label.size)
        let ry = ShapeRenderer.rim(size.x)
        #expect(abs(ry - size.x / 2.0 / (2.5 + size.x / 50.0)) < 1e-3)
        var c = Canvas()
        ShapeRenderer.draw(
            into: &c,
            shape: .cylinder,
            label: label,
            center: .zero,
            size: size,
            colors: (light.nodeFill, light.nodeBorder, light.text),
            paint: light
        )
        let top = -size.y / 2.0
        let body = ShapeRenderer.outline(shape: .cylinder, center: .zero, size: size)
        let rims: [[Vec2]] = c.ops.dropFirst(1).compactMap { op in
            let pts: [Vec2]
            switch op {
            case let .fill(p, _), let .stroke(p, _, _, _, _): pts = p
            }
            return pts == body ? nil : pts
        }
        #expect(!rims.isEmpty)
        for rim in rims {
            #expect(rim.allSatisfy { $0.y >= top - 0.01 && $0.y <= top + 2.0 * ry + 0.01 })
        }
    }

    // MARK: - Steady Streaming (5c.#124, #126, #127)

    @Test("5c.#124, #126, #127 steady stream monotonicity, batch equivalence, and subgraph promotion")
    func steadyStreamFullAuditParity() {
        let retries = """
        flowchart LR
          A[Read] --> B[Parse]
          B --> C[Check]
          C -->|bad| A
          C -->|good| D[Done]
        """
        let deploy = """
        flowchart LR
          A[Push] --> B[Build]
          subgraph prod[Prod]
            B --> C[Serve]
          end
        """
        let connection = """
        sequenceDiagram
          participant App
          participant DB
          App->>DB: query
          DB-->>App: rows
        """

        func centres(_ s: MermaidScene) -> [String: Vec2] {
            var map: [String: Vec2] = [:]
            for (l, lk) in zip(s.labels, s.labelKeys) {
                map[lk.key] = Vec2(l.at.x + l.size.x / 2.0, l.at.y + l.size.y / 2.0)
            }
            return map
        }

        func stream(_ src: String) -> [MermaidScene] {
            MermaidScenes.clearCache()
            let lines = src.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var out: [MermaidScene] = []
            var acc = ""
            for line in lines {
                acc += line + "\n"
                if let built = MermaidScenes.growing(acc, theme: dark, hover: nil) {
                    out.append(built)
                }
            }
            return out
        }

        func worstReversal(_ scenes: [MermaidScene]) -> Float {
            var maxRev: Float = 0.0
            for i in 0..<max(0, scenes.count - 2) {
                let c0 = centres(scenes[i]), c1 = centres(scenes[i + 1]), c2 = centres(scenes[i + 2])
                for (k, p1) in c1 {
                    guard let p0 = c0[k], let p2 = c2[k] else { continue }
                    let dx1 = p1.x - p0.x, dx2 = p2.x - p1.x
                    let dy1 = p1.y - p0.y, dy2 = p2.y - p1.y
                    if dx1 * dx2 < -0.5 { maxRev = max(maxRev, min(abs(dx1), abs(dx2))) }
                    if dy1 * dy2 < -0.5 { maxRev = max(maxRev, min(abs(dy1), abs(dy2))) }
                }
            }
            return maxRev
        }

        // 5c.#124 a_streaming_diagram_only_grows
        for src in [retries, deploy, connection] {
            let scenes = stream(src)
            #expect(!scenes.isEmpty)
            for i in 0..<max(0, scenes.count - 1) {
                #expect(scenes[i + 1].size.x >= scenes[i].size.x - 0.01)
                #expect(scenes[i + 1].size.y >= scenes[i].size.y - 0.01)
            }
            #expect(worstReversal(scenes) <= 1.0)
        }

        // 5c.#126 a_growing_build_is_the_same_however_many_lines_arrived_at_once
        let byLine = stream(retries).last!
        MermaidScenes.clearCache()
        let atOnce = MermaidScenes.growing(retries, theme: dark, hover: nil)!
        #expect(centres(byLine) == centres(atOnce))
        #expect(byLine.size == atOnce.size)

        // 5c.#127 nodes_keep_their_places_by_name_when_one_before_them_becomes_a_subgraph
        let promoteScenes = stream("graph TD\n  X -->|in| S\n  S --> W\n  W -->|out| Y\n  subgraph S\n    D\n  end\n")
        #expect(!promoteScenes.isEmpty)
        #expect(worstReversal(promoteScenes) <= 1.0)
    }

    // MARK: - Core & Hostile Limits (5c.#130, #135, #137, #139, #140)

    @Test("5c.#130 directive end preserves line indents")
    func directiveEndPreservesIndentsAudit() {
        for directive in ["%%{init: {}}%%", "%%{\ninit: {}\n}%%"] {
            let src = "\(directive) mindmap\n  root\n    child"
            let (cleaned, _) = MermaidParser.stripFrontMatterAndDirectives(src)
            let pairs: [(Int, String)] = cleaned
                .split(separator: "\n", omittingEmptySubsequences: false)
                .compactMap { raw in
                    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty || t.hasPrefix("%%") { return nil }
                    return (raw.prefix(while: { $0.isWhitespace }).count, t)
                }
            #expect(pairs.count == 3)
            #expect(pairs[0] == (0, "mindmap"))
            #expect(pairs[1] == (2, "root"))
            #expect(pairs[2] == (4, "child"))
            #expect(mayDrawMermaid(src))
        }
    }

    @Test("5c.#135, #137, #139, #140 hostile bounds and cyclic nested subgraphs")
    func hostileBoundsAuditParity() {
        // 5c.#135 5000 sequential empty subgraphs reject
        let manyEmpty = "graph TD\nA\n" + String(repeating: "subgraph s\nend\n", count: 5000)
        #expect(MermaidParser.parse(manyEmpty) == nil)
        #expect(scene(manyEmpty, paint: dark) == nil)

        // 5c.#137 10,000-dot dotted link draws at max length
        let dots = "graph TD\nA -\(String(repeating: ".", count: 10_000))-> B"
        #expect(MermaidParser.parse(dots) != nil)
        #expect(scene(dots, paint: dark) != nil)

        // 5c.#139 8-deep nested subgraphs with cycle draws
        var nested = "graph TD\n"
        for d in 0..<8 {
            nested += "subgraph s\(d)\nA\(d) --> B\(d) --> C\(d)\n"
        }
        nested += String(repeating: "end\n", count: 8)
        nested += "A0 --> C7\nC7 --> A0"
        #expect(MermaidParser.parse(nested) != nil)
        #expect(scene(nested, paint: dark) != nil)

        // 5c.#140 repeated create (100_000x + malformed create lines)
        let rep = "sequenceDiagram\n\(String(repeating: "create ", count: 100_000))participant A\nA->>B: hi"
        #expect(scene(rep, paint: dark) != nil)
        #expect(scene("sequenceDiagram\ncreate loop x\nA->>B: hi\nend", paint: dark) != nil)
        #expect(scene("sequenceDiagram\ncreate participant A\nA->>B: hi", paint: dark) != nil)
    }

    // MARK: - Timeline & XYChart (5c.#145, #147, #148, #149)

    @Test("5c.#145 timeline AST, continuation, TD flag, and bounds")
    func timelineFullAuditParity() {
        guard case let .timeline(t) = MermaidParser.parse("""
        timeline
            title History of Social Media
            2002 : LinkedIn
            2004 : Facebook : Google
                 : MySpace
            section Later
            2010 : Instagram
            2012
            accTitle: skipped
        """) else {
            Issue.record("expected timeline")
            return
        }
        #expect(t.title == "History of Social Media")
        #expect(t.sections == ["Later"])
        #expect(t.periods.count == 4)
        #expect(t.periods[0].time == "2002" && t.periods[0].events == ["LinkedIn"] && t.periods[0].section == nil)
        #expect(t.periods[1].time == "2004" && t.periods[1].events == ["Facebook", "Google", "MySpace"] && t.periods[1].section == nil)
        #expect(t.periods[2].time == "2010" && t.periods[2].events == ["Instagram"] && t.periods[2].section == 0)
        #expect(t.periods[3].time == "2012" && t.periods[3].events == [] && t.periods[3].section == 0)
        #expect(!t.down)
        guard case let .timeline(td) = MermaidParser.parse("timeline TD\n2020 : a") else {
            Issue.record("expected timeline TD")
            return
        }
        #expect(td.down)
        #expect(MermaidParser.parse("timeline\n    title Nothing") == nil)
        let budget = "timeline\n" + (0...MermaidLimits.maxItems).map { "\($0) : e" }.joined(separator: "\n")
        #expect(MermaidParser.parse(budget) == nil)
    }

    @Test("5c.#147, #148, #149 xychart AST, inverted axis range, scale ticks, and layout axes")
    func xyChartFullAuditParity() {
        guard case let .xyChart(x) = MermaidParser.parse("""
        xychart-beta
            title "Sales Revenue"
            x-axis [jan, feb, "mar, apr", may]
            y-axis "Revenue (in $)" 4000 --> 11000
            bar [5000, 6000, 7500, 8200]
            line "Trend" [5000, 6000.5, -7500, 8200]
            line [1, two, 3]
            bar oops
        """) else {
            Issue.record("expected xychart")
            return
        }
        #expect(x.title == "Sales Revenue")
        #expect(!x.horizontal)
        #expect(x.bands == ["jan", "feb", "mar, apr", "may"])
        #expect(x.yTitle == "Revenue (in $)")
        #expect(x.yRange?.0 == 4000.0 && x.yRange?.1 == 11000.0)
        #expect(x.series.count == 2)
        #expect(x.series[1].kind == .line && x.series[1].name == "Trend" && x.series[1].values[2] == -7500.0)

        guard case let .xyChart(h) = MermaidParser.parse("xychart-beta horizontal\n    x-axis \"Score\" 10 --> 0\n    y-axis Votes\n    bar [3, 5]") else {
            Issue.record("expected horizontal xychart")
            return
        }
        #expect(h.horizontal)
        #expect(h.xTitle == "Score" && h.xRange?.0 == 0.0 && h.xRange?.1 == 10.0)
        #expect(h.yTitle == "Votes" && h.yRange == nil)
        #expect(MermaidParser.parse("xychart-beta\n    title Nothing\n    x-axis [a, b]") == nil)
        let budget = "xychart-beta\n    bar [\(Array(repeating: "1", count: MermaidLimits.maxItems + 1).joined(separator: ", "))]"
        #expect(MermaidParser.parse(budget) == nil)

        // 5c.#148 the_value_axis_rounds_out_and_takes_in_zero
        let (r1, t1) = XYChartParser.scale(range: nil, series: [XYChartSeries(kind: .bar, name: "", values: [3.0, 47.0])])
        #expect(r1 == (0.0, 50.0) && t1 == [0.0, 10.0, 20.0, 30.0, 40.0, 50.0])
        let (r2, t2) = XYChartParser.scale(range: nil, series: [XYChartSeries(kind: .bar, name: "", values: [-12.0, 30.0])])
        #expect(r2.0 <= -12.0 && r2.1 >= 30.0 && t2.contains(0.0))
        let (_, t3) = XYChartParser.scale(range: (4000.0, 11000.0), series: [XYChartSeries(kind: .bar, name: "", values: [5000.0])])
        #expect(t3.first == 4000.0)

        // 5c.#149 bars_rise_with_their_values_upright_and_on_their_side
        for (src, horiz) in [
            ("xychart-beta\nx-axis [low, high]\nbar [1, 9]", false),
            ("xychart-beta horizontal\nx-axis [low, high]\nbar [1, 9]", true),
        ] {
            let s = scene(src, paint: light)!
            let lowAt = s.labels.first { $0.text == "low" }!.at
            let highAt = s.labels.first { $0.text == "high" }!.at
            if horiz {
                #expect(lowAt.y < highAt.y)
            } else {
                #expect(lowAt.x < highAt.x)
            }
        }
    }
}
