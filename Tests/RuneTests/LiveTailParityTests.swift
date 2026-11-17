import Testing
import RuneMotion
@testable import Rune

@Suite("Live virtual tail deliveries")
struct LiveTailParityTests {
    enum Delivery: Sendable, CaseIterable {
        case ink, geometryOnly, instantChild, narrower, rewrapping, belowList, unpinned
        case unrequested, wrongSelector, instantCommit, settle, reducedMotion

        var grows: Bool { self == .ink || self == .geometryOnly || self == .instantChild }
    }

    private enum Phase { case waiting, wrapping, delivered }

    private func feed(_ delivery: Delivery) -> Runtime<Phase> {
        let runtime = Runtime<Phase>(state: .waiting, viewport: Vec2(300, 180), pixelScale: 1) { phase, _ in
            let delivered = phase == .delivered
            let narrow = (delivery == .narrower || delivery == .rewrapping) && phase != .waiting
            let label: El<Phase> = el().key("label").size(40, 10).bg(delivered ? .white : .black)
                .groupOpacity(delivered ? 0.75 : 1, 1)
            var content: El<Phase> = col().key("content").wFull().pt(delivered ? 12 : 4)
                .child(label).childExit(.opacity)
            if delivery == .instantChild { content = content.instantChanges() }
            if !delivered { content = content.child(el().key("badge").size(10, 10).bg(.white)) }
            let pending: El<Phase> = col().key("pending").wFull().h(delivered ? 64 : 48)
                .arrivesWhole().child(content)
            let working: El<Phase> = el().key("working").size(40, 20).bg(.white)
            let rows: El<Phase> = col().key("rows").wFull().growth().virtualize(48)
                .child(el().key("earlier").wFull().h(320))
                .children(delivered ? [pending, working] : [working, pending])
            var viewport: El<Phase> = col().key("viewport").w(narrow ? 200 : 280).h(180)
                .scrollY(stickBottom: delivery != .unpinned).child(rows)
            if delivery == .belowList { viewport = viewport.child(el().key("after").wFull().h(96)) }
            return col().wFull().hFull().child(viewport)
        }
        runtime.motionNeedsCause = true
        runtime.reducedMotion = delivery == .reducedMotion
        runtime.poll = { phase, t, tx in
            if delivery == .rewrapping && phase == .waiting && (0.47..<0.5).contains(t) {
                phase = .wrapping
                return true
            }
            guard phase != .delivered, t >= 0.5 else { return false }
            phase = .delivered
            switch delivery {
            case .geometryOnly: tx.growVisibleTail("rows")
            case .wrongSelector: tx.growVisibleTailWithInk("other")
            case .unrequested: break
            default: tx.growVisibleTailWithInk("rows")
            }
            if delivery == .instantCommit { tx.instant() }
            if delivery == .settle { tx.settle() }
            return true
        }
        return runtime
    }

    @Test("Only opted-in, visible deliveries grow and carry their selected row properties", arguments: Delivery.allCases)
    func deliveryFrames(_ delivery: Delivery) throws {
        let runtime = feed(delivery)
        for frame in 0..<60 { _ = runtime.frame(at: Double(frame) / 120) }
        let previousBadge = runtime.flatNodes.first { $0.key == "badge" }?.nodeId
        let previousTop = runtime.element(byKey: "pending")?.rect[1]
        _ = runtime.frame(at: 0.5)
        try #require(runtime.state == .delivered)
        // In an unpinned, overscanned list the last row need not be mounted.
        if delivery == .unpinned && runtime.element(byKey: "pending") == nil { return }
        let row = try #require(runtime.flatNodes.first { $0.key == "pending" })
        let track = try #require(runtime.growthRows["growth:\(row.path)"]?.track)
        if delivery.grows {
            #expect((48..<64).contains(track.h))
            #expect(track.moving)
            let top = try #require(runtime.element(byKey: "pending")).rect[1]
            #expect(abs(top - (try #require(previousTop))) < 5)
            let label = try #require(runtime.flatNodes.first { $0.key == "label" })
            let badge = try #require(previousBadge)
            let labelTop = try #require(runtime.element(byKey: "label")).rect[1]
            let groupTop = try #require(runtime.element(byKey: "content")).rect[1]
            let animatesRestOpacity = runtime.scene.store.isAnimating(label.nodeId, Props.GROUP_REST)
            #expect(animatesRestOpacity == (delivery == .ink))
            if delivery == .ink {
                #expect(runtime.scene.isExiting(badge))
                #expect(runtime.scene.store.isAnimating(label.nodeId, Props.FILL))
            } else {
                #expect(!runtime.scene.hasNode(badge))
                #expect(!runtime.scene.store.isAnimating(label.nodeId, Props.FILL))
            }
            if delivery == .instantChild {
                #expect(abs(labelTop - groupTop - 12) < 0.01)
            } else {
                #expect((3.99..<7).contains(labelTop - groupTop))
            }
            for frame in 61...180 { _ = runtime.frame(at: Double(frame) / 120) }
            let settled = try #require(runtime.growthRows["growth:\(row.path)"]?.track)
            #expect(settled.h == 64)
            #expect(!settled.moving)
            #expect(!runtime.scene.hasNode(badge))
            let finalLabel = try #require(runtime.element(byKey: "label")).rect[1]
            let finalGroup = try #require(runtime.element(byKey: "content")).rect[1]
            #expect(abs(finalLabel - finalGroup - 12) < 0.01)
        } else {
            #expect(track.h == 64)
            #expect(!track.moving)
        }
    }

    @Test("Ink delivery and unpinned controls have no motion-gate findings", arguments: [Delivery.ink, .unpinned])
    func deliveryMotionGate(_ delivery: Delivery) {
        let run = MotionGateRun(feed(delivery), hz: 120)
        run.idle(0.45)
        run.step()
        run.play(1.05)
        run.quiet()
        run.stepN(4)
        let findings = motionGateCheck(run.rec)
        #expect(findings.isEmpty, "\(findings)")
    }

    @Test("An adjacent delivery animates just the stationary row's corner and retargets from the drawn radius")
    func stationaryCornerRetargets() throws {
        let runtime = Runtime<Int>(state: 0, viewport: Vec2(280, 180), pixelScale: 1) { accepted, _ in
            let apart = accepted == 1
            let first: El<Int> = el().key("first").wFull().h(30)
            let second: El<Int> = el().key("second").wFull().h(30)
                .corners(10, apart ? 10 : 4, 10, 10).opacity(apart ? 0.75 : 1)
            let working: El<Int> = el().key("working").wFull().h(20)
            let order = accepted == 0 ? [working, first, second] : apart ? [first, working, second] : [first, second, working]
            return col().wFull().hFull().scrollY(stickBottom: true)
                .child(col().key("rows").wFull().growth().virtualize(30)
                    .child(el().key("earlier").wFull().h(240)).children(order))
        }
        runtime.motionNeedsCause = true
        runtime.poll = { accepted, t, tx in
            guard accepted < 2, t >= 0.5 else { return false }
            accepted += 1
            tx.growVisibleTailWithInk("rows")
            return true
        }
        for frame in 0...30 { _ = runtime.frame(at: Double(frame) / 60) }
        try #require(runtime.state == 1)
        let id = try #require(runtime.flatNodes.first { $0.key == "second" }).nodeId
        let first = try #require(runtime.scene.presented(id))
        #expect(first.corners.topRight > 4 && first.corners.topRight < 6)
        #expect([first.corners.topLeft, first.corners.bottomRight, first.corners.bottomLeft] == [10, 10, 10])
        #expect(first.opacity == 0.75)
        _ = runtime.frame(at: 31.0 / 60)
        try #require(runtime.state == 2)
        let next = try #require(runtime.scene.presented(id)).corners.topRight
        #expect(next > 4 && abs(next - first.corners.topRight) < 1)
        for frame in 32...90 { _ = runtime.frame(at: Double(frame) / 60) }
        #expect(runtime.scene.presented(id)?.corners == Corners(10, 4, 10, 10))
    }

    @Test("A plain append grows only in its named list while a replacement view lands")
    func scopedAppendAndReplacedView() throws {
        let runtime = Runtime<Bool>(state: false, viewport: Vec2(360, 180), pixelScale: 1) { delivered, _ in
            func feed(_ name: String) -> El<Bool> {
                let prefix = delivered && name == "replacement" ? "replacement" : "original"
                var rows = (0..<12).map { index -> El<Bool> in
                    el().key("\(prefix)-\(index)").wFull().h(30)
                }
                if delivered { rows.append(el().key("arrival").wFull().h(60)) }
                return col().key(name).w(120).hFull().scrollY(stickBottom: true)
                    .child(col().key("rows").wFull().growth().virtualize(30).children(rows))
            }
            return row().wFull().hFull().children([feed("left"), feed("right"), feed("replacement")])
        }
        runtime.motionNeedsCause = true
        runtime.poll = { delivered, t, tx in
            guard !delivered, t >= 0.5 else { return false }
            delivered = true
            tx.growVisibleTail("left/rows")
            tx.growVisibleTail("replacement/rows")
            return true
        }

        for frame in 0...60 { _ = runtime.frame(at: Double(frame) / 120) }
        try #require(runtime.state)
        func arrival(_ list: String) throws -> GrowTrack {
            let element = try #require(runtime.element(byKey: "\(list)/rows/arrival"))
            return try #require(runtime.growthRows["growth:\(element.path)"]?.track)
        }
        let growing = try arrival("left")
        #expect((0..<60).contains(growing.h))
        #expect(growing.moving)
        for sibling in ["right", "replacement"] {
            let landed = try arrival(sibling)
            #expect(landed.h == 60)
            #expect(!landed.moving)
        }
        for frame in 61...180 { _ = runtime.frame(at: Double(frame) / 120) }
        #expect(try arrival("left").h == 60)
    }

    @Test("Covered polls merge requests per selector and preserve a request to carry ink")
    func coveredPollsMerge() {
        var pending = Tx()
        for pollNumber in 0..<32 {
            var poll = Tx()
            poll.growVisibleTail("left/rows")
            poll.growVisibleTail("right/rows")
            if pollNumber == 1 { poll.growVisibleTailWithInk("right/rows") }
            pending.merge(poll)
        }
        #expect(pending.liveTail.inkByStack == ["left/rows": false, "right/rows": true])
    }
}
