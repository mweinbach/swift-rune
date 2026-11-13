import Foundation
import Testing
import Rune
@testable import RuneMermaid

@Suite("State, Class, and ER Diagram Tests")
struct StateClassERTests {
    // MARK: - State Diagram

    private func state(_ src: String) -> StateDiagram {
        guard case let .state(s)? = MermaidParser.parse(src) else {
            Issue.record("Not a state diagram: \(src)")
            fatalError("Not a state diagram")
        }
        return s
    }

    @Test("state transitions, pseudostates, descriptions, and composites")
    func stateTransitionsPseudostatesComposites() {
        let s = state("""
        stateDiagram-v2
          direction LR
          [*] --> Queued
          state "In flight" as Working {
            Queued --> Applying : turn starts
            Applying --> Check
            state Check <<choice>>
            Check --> Applied : commit landed
            Check --> Unapplied : stalled
          }
          Applied : Card moves to Review
          Applied --> [*]
        """)
        #expect(s.dir == .right)
        #expect(s.clusters.count == 1)
        #expect(s.clusters[0].label == "In flight")
        #expect(s.nodes.contains { $0.kind == .start })
        #expect(s.nodes.contains { $0.kind == .end })
        #expect(s.nodes.contains { $0.id == "Check" && $0.kind == .choice })
        #expect(s.nodes.first { $0.id == "Applied" }?.descriptions == ["Card moves to Review"])
        #expect(StateDrawer.draw(s, paint: .neutral(dark: true)) != nil)
    }

    @Test("state fork, join, choice, and concurrent regions")
    func stateForkJoinConcurrentRegions() {
        let s = state("""
        stateDiagram-v2
          state f <<fork>>
          state j <<join>>
          state c <<choice>>
          [*] --> f
          f --> A
          f --> B
          A --> j
          B --> j
          j --> c
          c --> [*]
        """)
        func kind(_ id: String) -> StateKind? { s.nodes.first { $0.id == id }?.kind }
        #expect(kind("f") == .fork)
        #expect(kind("j") == .join)
        #expect(kind("c") == .choice)
        #expect(StateDrawer.draw(s, paint: .neutral(dark: false)) != nil)

        let concurrent = state("""
        stateDiagram-v2
          [*] --> Active
          state Active {
            [*] --> NumOff
            NumOff --> NumOn
            --
            [*] --> CapsOff
            CapsOff --> CapsOn
          }
          Active --> Done
        """)
        let regions = concurrent.clusters.filter(\.isRegion)
        #expect(regions.count == 2)
        #expect(StateDrawer.draw(concurrent, paint: .neutral(dark: true)) != nil)
    }

    @Test("state diagram prefix fuzzing")
    func statePrefixesNeverCrash() {
        assertPrefixesNeverCrash(
            "stateDiagram-v2\n  [*] --> Idle\n  Idle --> Busy : prompt\n  Busy --> Idle : done\n  Idle --> [*]",
            dark: false
        )
    }

    // MARK: - Class Diagram

    private func cls(_ src: String) -> ClassDiagram {
        guard case let .classDiagram(c)? = MermaidParser.parse(src) else {
            Issue.record("Not a class diagram: \(src)")
            fatalError("Not a class diagram")
        }
        return c
    }

    @Test("classes, members, stereotypes, namespaces, and relations")
    func classesMembersNamespacesRelations() {
        let c = cls("""
        classDiagram
          direction LR
          namespace core {
            class Runtime~S~ {
              <<struct>>
              +S state
              +Scene motion
              +frame(dt: f64)
              +update(f)
            }
            class El {
              +key(k)
              +child(el)
            }
          }
          Runtime "1" *-- "*" El : builds
          Widget <|.. Button : implements
          style Runtime fill:#dcf5dc
        """)
        #expect(c.dir == .right)
        #expect(c.namespaces.count == 1)
        #expect(c.namespaces[0].title == "core")
        let rt = c.classes.first { $0.id == "Runtime" }!
        #expect(rt.label == "Runtime<S>")
        #expect(rt.stereo == "struct")
        #expect(rt.fields.count == 2)
        #expect(rt.methods.count == 2)
        #expect(rt.style.fill != nil)
        #expect(c.edges.count == 2)
        #expect(c.edges[0].start == .diamondFilled)
        #expect(c.edges[1].start == .openTriangle)
        #expect(ClassDrawer.draw(c, paint: .neutral(dark: true)) != nil)
    }

    @Test("class diagram lenient block skipping and prefix fuzzing")
    func classLenientAndPrefixes() {
        for bad in ["classDiagram", "classDiagram\n}", "classDiagram\njust garbage words here"] {
            #expect(MermaidParser.parse(bad) == nil, "Expected nil for \(bad)")
        }
        let open = cls("classDiagram\nclass Open {\n  +x")
        #expect(open.classes[0].fields == ["+x"])
        let skipped = cls("classDiagram\njust garbage words here\nclass Bad<<x {\n  +y\n}\nA --> B")
        #expect(skipped.classes.map(\.id) == ["A", "B"])
        #expect(skipped.edges.count == 1)

        let c = cls("classDiagram\nnamespace outer {\n  namespace inner {\n    class Hidden {\n      +x\n    }\n  }\n  class Kept\n}")
        #expect(c.classes.map(\.id) == ["Kept"])
        #expect(c.classes[0].namespace == 0)

        assertPrefixesNeverCrash(
            "classDiagram\n  class A {\n    +i32 x\n    +run()\n  }\n  A --> B : calls",
            dark: false
        )
    }

    // MARK: - ER Diagram

    private func er(_ src: String) -> ErDiagram {
        guard case let .er(d)? = MermaidParser.parse(src) else {
            Issue.record("Not an ER diagram: \(src)")
            fatalError("Not an ER diagram")
        }
        return d
    }

    @Test("entities, attributes, and crow's feet")
    func entitiesAttributesAndCrowsFeet() {
        let d = er("""
        erDiagram
          CUSTOMER ||--o{ ORDER : places
          ORDER ||--|{ LINE-ITEM : contains
          CUSTOMER }|..|{ DELIVERY-ADDRESS : uses
          PERSON |o--o| SEAT : "sits in"
          CUSTOMER {
            string name
            string custNumber PK "the key"
            list~string~ tags
            int orderId FK, UK
          }
          p["A person"] { string first }
        """)
        #expect(d.dir == .down)
        #expect(d.edges[0].start == .onlyOne && d.edges[0].line == .solid && d.edges[0].end == .zeroOrMore)
        #expect(d.edges[1].start == .onlyOne && d.edges[1].line == .solid && d.edges[1].end == .oneOrMore)
        #expect(d.edges[2].start == .oneOrMore && d.edges[2].line == .dotted && d.edges[2].end == .oneOrMore)
        #expect(d.edges[3].start == .zeroOrOne && d.edges[3].line == .solid && d.edges[3].end == .zeroOrOne)
        #expect(d.edges[3].label == "sits in")

        let c = d.entities.first { $0.id == "CUSTOMER" }!
        #expect(c.attrs.count == 4)
        #expect(c.attrs[1] == ErAttr(ty: "string", name: "custNumber", keys: "PK", comment: "the key"))
        #expect(c.attrs[2].ty == "list<string>")
        #expect(c.attrs[3].keys == "FK, UK")
        let p = d.entities.first { $0.id == "p" }!
        #expect(p.label == "A person" && p.attrs.count == 1)
    }

    @Test("worded cardinalities, direction, and table drawing")
    func wordedCardinalitiesAndDraw() {
        let d = er("""
        erDiagram
          direction LR
          CAR 1 to zero or more NAMED-DRIVER : allows
          PERSON many(0) optionally to 1+ "Club House" : joins
        """)
        #expect(d.dir == .right)
        #expect(d.edges[0].start == .onlyOne && d.edges[0].line == .solid && d.edges[0].end == .zeroOrMore)
        #expect(d.edges[1].start == .zeroOrMore && d.edges[1].line == .dotted && d.edges[1].end == .oneOrMore)

        let paint = MermaidTheme.neutral(dark: false)
        let scene = renderScene(MermaidParser.parse("erDiagram\nCUSTOMER ||--o{ ORDER : places\nCUSTOMER {\n string name PK\n}")!, theme: paint)!
        let texts = scene.labels.map(\.text)
        for t in ["CUSTOMER", "ORDER", "places", "string", "name", "PK"] {
            #expect(texts.contains(t), "Missing label \(t)")
        }
    }

    @Test("ER bad lines and blocks are skipped")
    func erBadLinesAndBlocksSkipped() {
        let d = er("""
        erDiagram
         A ||--o{ B : ok
         this is not a relation
         C ??--?? D : nope
         E bad name {
           string x
         }
         B {
           string fine
           not-an-attribute
         }
        """)
        #expect(d.entities.map(\.id) == ["A", "B"])
        #expect(d.entities[1].attrs.count == 1)
        #expect(MermaidParser.parse("erDiagram\n  nothing here at all") == nil)
    }
}
