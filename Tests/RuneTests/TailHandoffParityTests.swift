import Testing
import RuneMotion
@testable import Rune

@Suite("Virtual tail row and panel handoff")
struct TailHandoffParityTests {
    private struct Feed {
        var delivered = false
        var resizedRoom: Float?
    }

    private func runtime(shareRoom: Bool = true, shrinkKeptRow: Bool = false) -> Runtime<Feed> {
        let runtime = Runtime<Feed>(state: Feed(), viewport: Vec2(300, 180), pixelScale: 1) { feed, _ in
            var rows: El<Feed> = col().key("rows").wFull().growth(.default).virtualize(48)
                .child(el().key("earlier").wFull().h(320))
            if feed.delivered {
                rows = rows.child(el().key("arrival").wFull().h(64).arrivesWhole())
            }
            let workingHeight: Float = shrinkKeptRow && !feed.delivered ? 40 : 20
            rows = rows.child(el().key("working").size(40, workingHeight).arrivesWhole())
            return col().wFull().hFull()
                .child(col().key("viewport").wFull().grow(1).minH(0).scrollY(stickBottom: true).child(rows))
                .child(el().key("room").wFull().h(feed.resizedRoom ?? (feed.delivered ? 0 : 40)))
        }
        runtime.motionNeedsCause = true
        runtime.poll = { feed, t, tx in
            guard !feed.delivered, t >= 0.5 else { return false }
            feed.delivered = true
            if shareRoom {
                tx.growVisibleTailFrom("rows", row: "arrival", panel: "room")
            } else {
                tx.growVisibleTail("rows")
            }
            return true
        }
        return runtime
    }

    @Test("The shrinking room and the viewport share the incoming row's actual progress")
    func deliveredRowTakesRoomFromPanel() throws {
        let rt = runtime()
        for i in 0..<60 { _ = rt.frame(at: Double(i) / 120) }
        #expect(try #require(rt.element(byKey: "room")).rect[3] == 40)
        for i in 60...180 {
            _ = rt.frame(at: Double(i) / 120)
            let arrival = try #require(rt.flatNodes.first { $0.key == "arrival" })
            let row = try #require(rt.growthRows["growth:\(arrival.path)"])
            let room = try #require(rt.element(byKey: "room")).rect
            let viewport = try #require(rt.element(byKey: "viewport")).rect
            let working = try #require(rt.element(byKey: "working")).rect
            if i == 60 {
                #expect(room[3] > 0 && room[3] < 40)
            }
            #expect(abs(room[3] - 40 * (1 - row.track.h / 64)) < 1.0 / 64.0)
            #expect(abs(viewport[1] + viewport[3] - room[1]) < 1.0 / 64.0)
            #expect(abs(working[1] + working[3] - room[1]) < 1.0 / 64.0)
            #expect(abs(room[1] + room[3] - 180) < 1.0 / 64.0)
        }
        #expect(try #require(rt.element(byKey: "room")).rect[3] == 0)
        #expect(rt.scrollAtBottom(forKey: "viewport") == true)
    }

    @Test("A delivered row and its panel pass the 120 Hz motion gate")
    func roomHandoffMotionGate() {
        let run = MotionGateRun(runtime(), hz: 120)
        run.idle(0.45)
        run.step()
        run.play(1.05)
        run.quiet()
        run.stepN(4)
        let findings = motionGateCheck(run.rec)
        #expect(findings.isEmpty)
    }

    @Test("A retained whole row relinquishes its footer at the incoming row's rate")
    func retainedWholeRowUsesIncomingProgress() throws {
        let rt = runtime(shrinkKeptRow: true)
        for i in 0..<60 { _ = rt.frame(at: Double(i) / 120) }
        for i in 60...150 {
            _ = rt.frame(at: Double(i) / 120)
            let arrival = try #require(rt.flatNodes.first { $0.key == "arrival" })
            let kept = try #require(rt.flatNodes.first { $0.key == "working" })
            let incoming = try #require(rt.growthRows["growth:\(arrival.path)"]?.track)
            let follower = try #require(rt.growthRows["growth:\(kept.path)"]?.track)
            let left = max(0, min(1, 1 - incoming.h / 64))
            #expect(abs(follower.h - (20 + 20 * left)) < 1.0 / 128.0)
            #expect(abs(follower.v + 20 * incoming.v / 64) < 1.0 / 128.0)
        }
    }

    @Test("A resize during the handoff owns the panel's newly measured geometry")
    func newPanelGeometryWins() throws {
        let rt = runtime()
        for i in 0...60 { _ = rt.frame(at: Double(i) / 120) }
        rt.update(at: 0.51) { feed, _ in feed.resizedRoom = 28 }
        _ = rt.frame(at: 0.52)
        let room = try #require(rt.element(byKey: "room")).rect
        #expect(room[3] == 28)
        #expect(room[1] == 152)
    }

    @Test("A changed viewport without a panel handoff lands the incoming row")
    func changedViewportLandsWithoutRoom() throws {
        let rt = runtime(shareRoom: false)
        for i in 0...60 { _ = rt.frame(at: Double(i) / 120) }
        let row = try #require(rt.flatNodes.first { $0.key == "arrival" })
        #expect(rt.growthRows["growth:\(row.path)"]?.track.h == 64)
        #expect(try #require(rt.element(byKey: "room")).rect[3] == 0)
    }
}
