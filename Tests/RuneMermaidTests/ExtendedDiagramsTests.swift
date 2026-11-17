import Testing
@testable import RuneMermaid
import Rune

@Suite("Extended Mermaid Diagrams Tests")
struct ExtendedDiagramsTests {
    private let light = MermaidTheme.neutral(dark: false)
    private let dark = MermaidTheme.neutral(dark: true)

    @Test("mayDrawMermaid recognizes diagram headers and supportedMermaid requires a parsed diagram")
    func supportedAndMayDrawAllFamilies() {
        let headers = [
            "flowchart TD",
            "graph LR",
            "sequenceDiagram",
            "stateDiagram-v2",
            "classDiagram",
            "erDiagram",
            "gantt",
            "pie",
            "mindmap",
            "timeline",
            "journey",
            "gitGraph",
            "quadrantChart",
            "xychart-beta",
            "sankey-beta",
            "block-beta",
            "requirementDiagram",
            "C4Context",
            "C4Container",
            "C4Component",
            "C4Dynamic",
            "C4Deployment",
        ]
        for h in headers {
            #expect(mayDrawMermaid(h), "Expected mayDrawMermaid(\(h)) == true")
        }
        #expect(!supportedMermaid("gantt"))
        #expect(supportedMermaid("graph TD\nA-->B"))
        #expect(mayDrawMermaid("%% comment\n"))
        #expect(!supportedMermaid("kanban\n  todo"))
        #expect(!mayDrawMermaid("kanban\n  todo"))
    }

    @Test("pie chart parses showData, title, slices, and renders")
    func pieChart() {
        let src = """
        pie showData
            title Pets adopted by volunteers
            "Dogs" : 386
            "Cats" : 85
            "Rats" : 15
        """
        let p = PieParser.parse(header: "showData", body: [
            "title Pets adopted by volunteers",
            "\"Dogs\" : 386",
            "\"Cats\" : 85",
            "\"Rats\" : 15",
        ])
        #expect(p != nil)
        #expect(p?.title == "Pets adopted by volunteers")
        #expect(p?.showData == true)
        #expect(p?.slices.count == 3)
        #expect(PieParser.formatNumber(386.0) == "386")
        #expect(PieParser.formatNumber(85.5) == "85.5")
        #expect(PieParser.formatNumber(1.0 / 3.0) == "0.33")
        #expect(PieParser.formatNumber(12.50) == "12.5")
        #expect(canRenderMermaid(src))
        #expect(renderMermaid(src, theme: light) as El<Int>? != nil)
        #expect(renderMermaidDrawing(src, theme: dark) as MermaidDrawing<Int>? != nil)

        if let pieScene = renderScene(MermaidParser.parse("pie showData\n\"Dogs\" : 70\n\"Cats\" : 26\n\"Fish\" : 4")!, theme: light) {
            let texts = pieScene.labels.map(\.text)
            for t in ["70%", "26%", "Dogs", "Cats", "Fish", "70", "4"] {
                #expect(texts.contains(t), "Missing pie label \(t)")
            }
            #expect(!texts.contains("4%"))
        } else {
            Issue.record("Expected pie percentages scene")
        }
        let budget = "pie\n" + (0...MermaidLimits.maxItems).map { "\"s\($0)\" : 1" }.joined(separator: "\n")
        #expect(MermaidParser.parse(budget) == nil)
    }

    @Test("date calendar arithmetic, dayjs parsing, spans, and d3 formatting")
    func dateArithmetic() {
        #expect(MermaidDate.daysFromCivil(1970, 1, 1) == 0)
        #expect(MermaidDate.daysFromCivil(2024, 1, 1) == 19723)

        let t = MermaidDate.parse("2024-03-15", format: "YYYY-MM-DD")
        #expect(t != nil)
        if let t {
            #expect(MermaidDate.format(t, fmt: "%Y-%m-%d") == "2024-03-15")
            #expect(MermaidDate.format(t, fmt: "%b %e") == "Mar 15")
            if let sp = MermaidDate.parseSpan("3d") {
                #expect(sp == .ms(3.0 * MermaidDate.day))
                #expect(MermaidDate.format(sp.after(t), fmt: "%Y-%m-%d") == "2024-03-18")
            } else {
                Issue.record("Expected 3d span to parse")
            }
            #expect(MermaidDate.parseSpan("1.5h") == .ms(1.5 * MermaidDate.hour))
            #expect(MermaidDate.parseSpan("2w") == .ms(14.0 * MermaidDate.day))
            #expect(MermaidDate.parseSpan("3x") == nil)
            let jan31 = Double(MermaidDate.daysFromCivil(2024, 1, 31)) * MermaidDate.day
            #expect(MermaidDate.Span.months(1.0).after(jan31) == Double(MermaidDate.daysFromCivil(2024, 2, 29)) * MermaidDate.day)
            if let mo = MermaidDate.parseSpan("1M") {
                #expect(MermaidDate.format(mo.after(t), fmt: "%Y-%m-%d") == "2024-04-15")
            } else {
                Issue.record("Expected 1M span to parse")
            }
        }
        let step = MermaidDate.Step.parse("1week")
        #expect(step == .weeks(1))
        if let lo = MermaidDate.parse("2024-01-01", format: "YYYY-MM-DD"),
           let hi = MermaidDate.parse("2024-01-31", format: "YYYY-MM-DD") {
            let ticks = step?.ticks(lo: lo, hi: hi, max: 20) ?? []
            #expect(ticks.count >= 4)
        }
    }

    @Test("gantt chart parses sections, tags, dependencies, excludes, and renders")
    func ganttChart() {
        let src = """
        gantt
            title A Gantt Diagram
            dateFormat YYYY-MM-DD
            axisFormat %m/%d
            excludes weekends
            section Section
            A task           :done, a1, 2024-01-01, 5d
            Another task     :active, crit, after a1, 3d
            Release          :milestone, m1, after a1, 0d
            Deadline         :vert, 2024-01-10, 0d
        """
        #expect(canRenderMermaid(src))
        let scene = MermaidScenes.built(src, theme: light, hover: nil).scene
        #expect(scene != nil)
        #expect(scene?.title == "A Gantt Diagram")
        #expect(renderMermaid(src, theme: light) as El<Int>? != nil)
        #expect(renderMermaidDrawing(src, theme: dark) as MermaidDrawing<Int>? != nil)

        func day(_ y: Int64, _ m: Int, _ d: Int) -> Double {
            Double(MermaidDate.daysFromCivil(y, m, d)) * MermaidDate.day
        }
        if case let .gantt(fwd)? = MermaidParser.parse("gantt\nB :b, after a, 1d\nA :a, 2024-03-01, 2d\nC :c, after d, 1d\nD :d, after c, 1d") {
            let bTask = fwd.tasks.first { $0.name == "B" }
            #expect(bTask?.start == day(2024, 3, 3))
            #expect(fwd.tasks.count == 2)
        } else {
            Issue.record("Expected gantt forward links")
        }

        if case let .gantt(exc)? = MermaidParser.parse("gantt\nexcludes weekends, 2024-01-09\nA :2024-01-05, 3d\nB :2024-01-05, 2024-01-08") {
            #expect(exc.tasks.first { $0.name == "A" }?.end == day(2024, 1, 11))
            #expect(exc.tasks.first { $0.name == "B" }?.end == day(2024, 1, 8))
            #expect(exc.excludes.weekdays[0] && exc.excludes.weekdays[6])
        } else {
            Issue.record("Expected gantt excludes")
        }
        if case let .gantt(fri)? = MermaidParser.parse("gantt\nweekend friday\nexcludes weekends\nA :2024-01-04, 2d") {
            #expect(fri.tasks.first { $0.name == "A" }?.end == day(2024, 1, 8))
        } else {
            Issue.record("Expected gantt weekend friday")
        }

        if case let .gantt(inc)? = MermaidParser.parse("gantt\ndateFormat DD/MM/YYYY\ninclusiveEndDates\nnot a task\nA :01/02/2024, 03/02/2024\nB :what, ever\nC :after nobody, 1d") {
            #expect(inc.tasks.count == 1)
            #expect(inc.tasks[0].end == day(2024, 2, 4))
        } else {
            Issue.record("Expected gantt inclusiveEndDates")
        }
        #expect(MermaidParser.parse("gantt\ntitle Nothing\nsection Empty") == nil)

        if let planScene = renderScene(MermaidParser.parse("gantt\ntitle Plan\nsection Work\nShort :2024-01-01, 1d\nA much longer task name :2024-01-02, 20d")!, theme: dark) {
            let texts = planScene.labels.map(\.text)
            #expect(texts.contains("Work") && texts.contains("Short") && texts.contains("A much longer task name"))
        } else {
            Issue.record("Expected gantt plan scene")
        }
    }

    @Test("timeline parses horizontal and vertical TD layouts and continuation events")
    func timelineDiagram() {
        let src = """
        timeline
            title History of Social Media Platform
            section Early
            2002 : LinkedIn
            2004 : Facebook
                 : Google
            section Modern
            2006 : Twitter
        """
        #expect(canRenderMermaid(src))
        #expect(renderMermaid(src, theme: light) as El<Int>? != nil)

        let tdSrc = """
        timeline TD
            2020 : Alpha
            2021 : Beta
            2022 : Gamma
        """
        #expect(canRenderMermaid(tdSrc))
        #expect(renderMermaidDrawing(tdSrc, theme: dark) as MermaidDrawing<Int>? != nil)
    }

    @Test("user journey parses scores, actors, sections, and renders")
    func journeyDiagram() {
        let src = """
        journey
            title My working day
            section Go to work
            Make tea: 5: Me
            Go upstairs: 3: Me
            Do work: 1: Me, Cat
            section Go home
            Go downstairs: 5: Me
        """
        #expect(canRenderMermaid(src))
        let el: El<Int>? = renderMermaid(src, theme: light)
        #expect(el != nil)
        let drawing: MermaidDrawing<Int>? = renderMermaidDrawing(src, theme: dark)
        #expect(drawing != nil)
        #expect((drawing?.size.x ?? 0) > 0)
    }

    @Test("gitGraph supports branches, commits, tags, merge, cherry-pick, and LR/TB/BT")
    func gitGraphDiagram() {
        let src = """
        gitGraph
            commit id: "init" tag: "v0.1"
            branch develop order: 1
            checkout develop
            commit id: "feat" type: HIGHLIGHT
            commit type: REVERSE
            checkout main
            merge develop tag: "v0.2"
            branch hotfix
            cherry-pick id: "feat"
        """
        #expect(canRenderMermaid(src))
        #expect(renderMermaid(src, theme: light) as El<Int>? != nil)

        let tbSrc = """
        gitGraph TB:
            commit id: "a"
            branch feature
            commit id: "b"
            switch main
            merge feature
        """
        #expect(canRenderMermaid(tbSrc))
        #expect(renderMermaidDrawing(tbSrc, theme: dark) as MermaidDrawing<Int>? != nil)
    }

    @Test("mindmap parses indentation hierarchy and all node shapes")
    func mindmapDiagram() {
        let src = """
        mindmap
          root((mindmap))
            Origins
              Long history
              ::icon(fa fa-book)
              Popularisation
            Research
              On effectiveness<br/>and features
              On Automatic Creation
                Uses
                    Creative techniques
                    Strategic planning
            Tools[Pen and paper]
            Cloud)Cloud(
            Bang))Bang((
            Hex{{Hexagon}}
        """
        #expect(canRenderMermaid(src))
        let el: El<Int>? = renderMermaid(src, theme: light)
        #expect(el != nil)
        let drawing: MermaidDrawing<Int>? = renderMermaidDrawing(src, theme: dark)
        #expect(drawing != nil)

        if let mm = renderScene(MermaidParser.parse("mindmap\n  Centre\n    One\n    Two\n    Three\n    Four")!, theme: dark) {
            func midX(_ t: String) -> Float {
                let l = mm.labels.first { $0.text == t }!
                return l.at.x + l.size.x / 2.0
            }
            let centre = midX("Centre")
            #expect(midX("One") > centre && midX("Two") > centre)
            #expect(midX("Three") < centre && midX("Four") < centre)
        } else {
            Issue.record("Expected mindmap split scene")
        }
    }

    @Test("quadrantChart parses axes, quadrant labels, points, and classDef styles")
    func quadrantChart() {
        let src = """
        quadrantChart
            title Reach and engagement of campaigns
            x-axis Low Reach --> High Reach
            y-axis Low Engagement --> High Engagement
            quadrant-1 We should expand
            quadrant-2 Need to promote
            quadrant-3 Re-evaluate
            quadrant-4 May be improved
            classDef hot color: #ff5500, radius: 8
            Campaign A:::hot: [0.3, 0.6]
            Campaign B: [0.45, 0.23] radius: 6, stroke-color: #224488, stroke-width: 2px
        """
        #expect(canRenderMermaid(src))
        #expect(renderMermaid(src, theme: light) as El<Int>? != nil)
        #expect(renderMermaidDrawing(src, theme: dark) as MermaidDrawing<Int>? != nil)

        if let qScene = renderScene(MermaidParser.parse("quadrantChart\nquadrant-1 Q1\nquadrant-3 Q3\nHigh: [0.9, 0.9]\nLow: [0.1, 0.1]")!, theme: light) {
            func at(_ t: String) -> Vec2 { qScene.labels.first { $0.text == t }!.at }
            #expect(at("High").x > at("Low").x && at("High").y < at("Low").y)
            #expect(at("Q1").x > at("Q3").x && at("Q1").y < at("Q3").y)
        } else {
            Issue.record("Expected quadrant points scene")
        }
    }

    @Test("xychart-beta parses vertical and horizontal bar/line charts and auto-scales")
    func xyChart() {
        let src = """
        xychart-beta
            title "Sales Revenue"
            x-axis [jan, feb, mar, apr, may]
            y-axis "Revenue (in $)" 4000 --> 11000
            bar "Gross" [5000, 6000, 7500, 8200, 9500]
            line "Target" [5500, 6200, 7000, 8500, 9000]
        """
        #expect(canRenderMermaid(src))
        #expect(renderMermaid(src, theme: light) as El<Int>? != nil)

        let horizSrc = """
        xychart-beta horizontal
            x-axis [A, B, C]
            bar [10, 25, 15]
        """
        #expect(canRenderMermaid(horizSrc))
        #expect(renderMermaidDrawing(horizSrc, theme: dark) as MermaidDrawing<Int>? != nil)

        let sCurvePts = MermaidChart.sCurve(Vec2(0, 0), Vec2(100, 50), upright: false)
        #expect(sCurvePts.count == 21)
    }

    @Test("sankey-beta parses CSV rows with quotes, computes columns, and renders")
    func sankeyDiagram() {
        let src = #"""
        sankey-beta
        "Agricultural ""waste""",Bio-conversion,124.729
        Bio-conversion,Liquid,0.597
        Bio-conversion,Losses,26.862
        Bio-conversion,Solid,280.322
        """#
        #expect(canRenderMermaid(src))
        #expect(renderMermaid(src, theme: light) as El<Int>? != nil)
        #expect(renderMermaidDrawing(src, theme: dark) as MermaidDrawing<Int>? != nil)

        if let skScene = renderScene(MermaidParser.parse("sankey-beta\nSolar,Grid,10\nWind,Grid,20\nGrid,Homes,30")!, theme: dark) {
            func at(_ prefix: String) -> Vec2 { skScene.labels.first { $0.text.hasPrefix(prefix) }!.at }
            #expect(at("Solar").x < at("Grid").x && at("Grid").x < at("Homes").x)
            #expect(skScene.labels.contains { $0.text == "Grid 30" })
        } else {
            Issue.record("Expected sankey flow scene")
        }
    }

    @Test("block-beta parses columns, spans, nested blocks, space, block arrows, and edges")
    func blockDiagram() {
        let src = """
        block-beta
            columns 3
            a["Frontend"]:2 b(("API"))
            block:group1:2
                columns 2
                c d
            end
            space
            arr<["flow"]>(right) e[(DB)]
            a --> e
        """
        #expect(canRenderMermaid(src))
        #expect(renderMermaid(src, theme: light) as El<Int>? != nil)
        #expect(renderMermaidDrawing(src, theme: dark) as MermaidDrawing<Int>? != nil)
    }

    @Test("C4Context and C4Dynamic parse boundaries, elements, stores, and relations")
    func c4Diagrams() {
        let ctxSrc = """
        C4Context
            title System Context diagram
            Person(user, "Customer", "A user of the system")
            System_Boundary(b1, "System") {
                ContainerDb(db, "Database", "Postgres", "Stores data")
                ContainerQueue_Ext(q, "Queue", "SQS", "Async events")
            }
            Rel(user, db, "Reads/Writes", "HTTPS")
            BiRel(db, q, "Publishes")
        """
        #expect(canRenderMermaid(ctxSrc))
        #expect(renderMermaid(ctxSrc, theme: light) as El<Int>? != nil)

        let dynSrc = """
        C4Dynamic
            Container(spa, "SPA", "React")
            Container(api, "API", "Swift")
            RelIndex(1, spa, api, "Calls", "JSON")
        """
        #expect(canRenderMermaid(dynSrc))
        #expect(renderMermaidDrawing(dynSrc, theme: dark) as MermaidDrawing<Int>? != nil)

        if case let .c4(dyn)? = MermaidParser.parse("C4Dynamic\n    Container(a, \"App\")\n    ContainerDb(b, \"DB\")\n    RelIndex(1, a, b, \"Reads\")\n    Rel(b, a, \"Rows\")") {
            #expect(dyn.edges.compactMap(\.label) == ["1: Reads", "2: Rows"])
        } else {
            Issue.record("Expected C4Dynamic edges")
        }
        let deepC4 = "C4Deployment\n" + String(repeating: "Deployment_Node(n, \"N\") {\n", count: MermaidLimits.maxDepth + 1) + "Node(x, \"X\")"
        #expect(MermaidParser.parse(deepC4) == nil)

        if let c4CardScene = renderScene(
            MermaidParser.parse("C4Container\nSystem_Boundary(s, \"Shop\") {\nContainer(web, \"Web\", \"Rust\", \"Serves pages\")\n}\nPerson(u, \"User\")\nRel(u, web, \"Visits\", \"HTTPS\")")!,
            theme: dark
        ) {
            for t in ["«container»", "[Rust]", "Serves pages", "«person»", "Shop\n[System]", "Visits\n[HTTPS]"] {
                #expect(c4CardScene.labels.contains { $0.text == t }, "Missing C4 label \(t)")
            }
            let userY = c4CardScene.labels.first { $0.text == "User" }!.at.y
            let webY = c4CardScene.labels.first { $0.text == "Web" }!.at.y
            #expect(userY < webY)
        } else {
            Issue.record("Expected C4Container card scene")
        }
    }

    @Test("requirementDiagram parses requirements, elements, fields, and relations")
    func requirementDiagram() {
        let src = """
        requirementDiagram
            requirement test_req {
                id: 1
                text: the test text.
                risk: high
                verifymethod: test
            }
            functionalRequirement test_req2 {
                id: 1.1
                text: sub requirement
                risk: medium
                verifymethod: inspection
            }
            element test_entity {
                type: simulation
                docref: doc1
            }
            test_entity - satisfies -> test_req
            test_req2 <- contains - test_req
        """
        #expect(canRenderMermaid(src))
        #expect(renderMermaid(src, theme: light) as El<Int>? != nil)
        #expect(renderMermaidDrawing(src, theme: dark) as MermaidDrawing<Int>? != nil)
    }

    @Test("steady layout and scenes cache support streaming growth")
    func steadyAndScenesStreaming() {
        let line1 = "flowchart TD\n    A[Start] --> B[Middle]"
        let line2 = "flowchart TD\n    A[Start] --> B[Middle]\n    B --> C[End]"
        let el1: El<Int>? = renderMermaidStreaming(line1, theme: light)
        let el2: El<Int>? = renderMermaidStreaming(line2, theme: light)
        let finalEl: El<Int>? = renderMermaidStreamed(line2, theme: light)
        #expect(el1 != nil)
        #expect(el2 != nil)
        #expect(finalEl != nil)

        let b1 = MermaidScenes.growing(line1, theme: light, hover: nil)
        let b2 = MermaidScenes.growing(line2, theme: light, hover: nil)
        #expect(b1 != nil)
        #expect(b2 != nil)
        if let s1 = b1?.size, let s2 = b2?.size {
            #expect(s2.x >= s1.x - 0.01)
            #expect(s2.y >= s1.y - 0.01)
        }

        // a_streaming_diagram_glides_inside_a_growth_row (parts_tests.rs:94)
        let two = "flowchart TD\n  A[Start] --> B[End]\n"
        func makeGrowthRuntime() -> Runtime<String> {
            Runtime<String>(state: two, viewport: Vec2(600, 600)) { src, _ in
                let children: [El<String>] = renderMermaidStreaming(src, theme: MermaidTheme.neutral(dark: true), hover: (.edges, MermaidTheme.neutral(dark: true).text))
                    .map { [$0] } ?? []
                return col()
                    .key("stack")
                    .wFull()
                    .growth(GrowthSpec.default)
                    .child(col().key("row").wFull().children(children))
            }
        }
        let rtSettled = makeGrowthRuntime()
        _ = rtSettled.frame(at: 0.0)
        let beforeY = rtSettled.element(byKey: "n:B")!.rect[1]
        rtSettled.update { s, _ in s += "  Z[First] --> A\n" }
        for step in 1...90 {
            _ = rtSettled.frame(at: Double(step) / 60.0)
        }
        let afterY = rtSettled.element(byKey: "n:B")!.rect[1]
        #expect(abs(afterY - beforeY) > 10.0)

        let rtMid = makeGrowthRuntime()
        _ = rtMid.frame(at: 0.0)
        rtMid.update { s, _ in s += "  Z[First] --> A\n" }
        _ = rtMid.frame(at: 1.0 / 60.0)
        let midY = rtMid.element(byKey: "n:B")!.rect[1]
        #expect(abs(midY - beforeY) < abs(afterY - beforeY) - 1.0)
    }
}
