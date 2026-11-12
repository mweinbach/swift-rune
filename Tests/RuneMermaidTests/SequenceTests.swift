import Foundation
import Testing
import Rune
@testable import RuneMermaid

@Suite("Sequence Diagram Tests")
struct SequenceTests {
    private func seq(_ src: String) -> SequenceDiagram {
        guard case let .sequence(s)? = MermaidParser.parse(src) else {
            Issue.record("Not a sequence diagram: \(src)")
            fatalError("Not a sequence diagram")
        }
        return s
    }

    @Test("participants, messages, and activation")
    func participantsMessagesAndActivation() {
        let s = seq("""
        sequenceDiagram
          autonumber
          actor U as User
          participant A as API server
          U->>+A: GET /items
          A-->>-U: 200 OK
          A->B: plain
          B-->A: dotted
          A-xB: lost
          B--)A: async
          A<<->>B: both
          A->>A: think
        """)
        #expect(s.autonumber)
        let names = s.participants.map { ($0.id, $0.label, $0.kind) }
        #expect(names.count == 3)
        #expect(names[0] == ("U", "User", .actor))
        #expect(names[1] == ("A", "API server", .box))
        #expect(names[2] == ("B", "B", .box))

        let msgs: [SequenceMessage] = s.events.compactMap {
            if case let .message(m) = $0 { return m }
            return nil
        }
        #expect((msgs[0].from, msgs[0].to, msgs[0].text, msgs[0].activate) == (0, 1, "GET /items", true))
        #expect((msgs[1].dotted, msgs[1].tip, msgs[1].deactivate) == (true, .filled, true))
        #expect((msgs[2].dotted, msgs[2].tip) == (false, .none))
        #expect((msgs[3].dotted, msgs[3].tip) == (true, .none))
        #expect(msgs[4].tip == .cross)
        #expect((msgs[5].dotted, msgs[5].tip) == (true, .open))
        #expect(msgs[6].both)
        #expect((msgs[7].from, msgs[7].to) == (1, 1))
    }

    @Test("notes, frames, boxes, and explicit activation")
    func notesFramesBoxesAndActivation() {
        let s = seq("""
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
        """)
        #expect(s.title == "Frame commit")
        #expect(s.boxes.count == 2)
        #expect(s.boxes[0].title == "Desk")
        #expect(s.boxes[0].color != nil)
        #expect(s.participants[0].group == 0)
        #expect(s.participants[1].group == 1)
        #expect(s.participants[0].id == "web-app")
        #expect(SequenceDrawer.draw(s, paint: .neutral(dark: true)) != nil)
    }

    @Test("v11 participant types draw their own heads")
    func participantTypesDrawOwnHeads() {
        let src = """
        sequenceDiagram
          participant W@{ "type": "boundary" }
          participant C@{ "type" : "control" }
          participant E@{ "type": "entity" }
          participant D@{ "type": "database" }
          participant L@{ "type": "collections" }
          participant Q@{ "type": "queue" }
          participant P@{ "type": "mystery" }
          W->>C: a
          C->>E: b
          E->>D: c
          D->>L: d
          L->>Q: e
          Q->>P: f
        """
        let s = seq(src)
        #expect(s.participants.map(\.kind) == [.boundary, .control, .entity, .database, .collections, .queue, .box])
        #expect(SequenceDrawer.draw(s, paint: .neutral(dark: false)) != nil)
    }

    @Test("create, destroy, and numbering")
    func createDestroyAndNumbering() {
        let s = seq("""
        sequenceDiagram
          autonumber 10 5
          A->>B: hello
          create participant C
          B->>C: make
          destroy C
          C-->>B: bye
          autonumber off
          A->>B: quiet
        """)
        #expect(s.events.contains { if case let .number(n) = $0, let (start, step) = n { return start == 10 && step == 5 } else { return false } })
        #expect(s.events.contains { if case let .number(n) = $0 { return n == nil } else { return false } })
        #expect(s.events.contains { if case .create(2) = $0 { return true } else { return false } })
        #expect(s.events.contains { if case .destroy(2) = $0 { return true } else { return false } })

        let paint = MermaidTheme.neutral(dark: false)
        let scene = SequenceDrawer.draw(s, paint: paint)!
        let plain = renderScene(MermaidParser.parse("sequenceDiagram\n  A->>B: hello\n  B->>C: make\n  C-->>B: bye\n  A->>B: quiet")!, theme: paint)!
        #expect(scene.size.y > plain.size.y)
    }

    @Test("long messages widen their gap")
    func longMessagesWidenGap() {
        let paint = MermaidTheme.neutral(dark: false)
        let narrow = renderScene(MermaidParser.parse("sequenceDiagram\nA->>B: hi")!, theme: paint)!
        let wide = renderScene(MermaidParser.parse("sequenceDiagram\nA->>B: a much longer message that needs room")!, theme: paint)!
        #expect(wide.size.x > narrow.size.x + 100.0)
    }

    @Test("nesting past the bound rejects")
    func nestingPastBoundRejects() {
        let deep = String(repeating: "loop x\n", count: MermaidLimits.maxDepth + 1)
        #expect(MermaidParser.parse("sequenceDiagram\n\(deep)A->>B: hi") == nil)
    }

    @Test("every prefix draws or falls back without crashing")
    func prefixesNeverCrash() {
        assertPrefixesNeverCrash(
            "sequenceDiagram\n  autonumber\n  actor U as User\n  U->>+A: hi\n  loop retry\n    A->>B: call\n    B--xA: fail\n  end\n  Note left of U: waits\n  A-->>-U: done",
            dark: true
        )
    }
}
