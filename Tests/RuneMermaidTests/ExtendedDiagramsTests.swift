import Testing
@testable import RuneMermaid
import Rune

@Suite("Extended Mermaid Diagrams Tests")
struct ExtendedDiagramsTests {
    private let light = MermaidTheme.neutral(dark: false)
    private let dark = MermaidTheme.neutral(dark: true)

    @Test("supportedMermaid and mayDrawMermaid recognize all 17 diagram families")
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
            #expect(supportedMermaid(h), "Expected supportedMermaid(\(h)) == true")
            #expect(mayDrawMermaid(h), "Expected mayDrawMermaid(\(h)) == true")
        }
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
        #expect(PieParser.formatNumber(12.50) == "12.5")
        #expect(canRenderMermaid(src))
        #expect(renderMermaid(src, theme: light) as El<Int>? != nil)
        #expect(renderMermaidDrawing(src, theme: dark) as MermaidDrawing<Int>? != nil)
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
                #expect(MermaidDate.format(sp.after(t), fmt: "%Y-%m-%d") == "2024-03-18")
            } else {
                Issue.record("Expected 3d span to parse")
            }
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
    }
}
