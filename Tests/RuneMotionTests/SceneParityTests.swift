import Foundation
import Testing
@testable import RuneMotion

@Suite("Scene & Presence Parity")
struct SceneParityTests {
    private static let hz: Double = 120.0

    private func spec(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> NodeSpec {
        NodeSpec(MotionRect.fromXYWH(x, y, w, h))
    }

    private func find(_ out: [Presented], _ id: NodeId) -> Presented? {
        out.first { $0.node == id }
    }

    private func runScene(
        _ s: inout Scene,
        from: Double,
        until: Double,
        id: NodeId
    ) -> ([(Double, Presented)], Double?) {
        var seen: [(Double, Presented)] = []
        var exitedAt: Double? = nil
        var t = from
        while t <= until + 1e-9 {
            let out = s.frameAt(t)
            if let p = find(out.changed, id) {
                seen.append((t, p))
            }
            if out.exited.contains(id) && exitedAt == nil {
                exitedAt = t
            }
            t += 1.0 / Self.hz
        }
        return (seen, exitedAt)
    }

    // MARK: - scene/props.rs

    @Test("isRestingAt tracks presence, frame, and active animations")
    func isRestingAtTracksPresenceFrameAndActiveAnimations() {
        var s = Scene()
        let id = NodeId(1)
        let r0 = MotionRect.fromXYWH(0, 0, 40, 20)
        let r1 = MotionRect.fromXYWH(10, 0, 40, 20)
        #expect(!s.isRestingAt(id, r0))

        s.insert(id, NodeSpec(r0), .initial)
        #expect(s.isRestingAt(id, r0))
        #expect(!s.isRestingAt(id, r1))

        s.setFrame(id, r1, MotionTokens.SMOOTH)
        #expect(!s.isRestingAt(id, r0))
        #expect(!s.isRestingAt(id, r1))
        _ = s.frameAt(5.0)
        #expect(s.isRestingAt(id, r1))

        s.animate(id, Props.OPACITY, to: 0.5, spring: MotionTokens.SMOOTH)
        #expect(!s.isRestingAt(id, r1))
        _ = s.frameAt(10.0)
        #expect(s.isRestingAt(id, r1))

        s.remove(id)
        #expect(!s.isRestingAt(id, r1))
    }

    @Test("Exact child geometry includes its parent's static or tracked offset before presentation")
    func exactChildGeometryIncludesParentOffsetBeforePresentation() {
        var scene = Scene()
        let parent = NodeSpec(id: NodeId(1), rect: .fromXYWH(10, 20, 100, 80), offset: Vec2(15, -8))
        let child = NodeSpec(id: NodeId(2), parent: parent.id, rect: .fromXYWH(30, 50, 24, 18), offset: Vec2(6, -4))
        scene.commit([parent, child], at: 0, initialCut: true)
        let initial = MotionRect.fromXYWH(45, 42, 24, 18)
        #expect(scene.currentRect(child.id) == initial)
        #expect(scene.unoffsetWorldRect(for: child.id) == initial)
        _ = scene.frame(at: 0)
        #expect(scene.world(child.id) == initial)
        #expect(scene.presented(child.id)?.rect == initial.translated(child.offset))
        #expect(scene.samplingError().maxDevicePxError == 0)

        scene.set(parent.id, Props.OFFSET, Vec2(-2, 9))
        let moved = MotionRect.fromXYWH(28, 59, 24, 18)
        #expect(scene.currentRect(child.id) == moved)
        #expect(scene.unoffsetWorldRect(for: child.id) == moved)
        #expect(scene.presented(child.id)?.rect == initial.translated(child.offset))
        _ = scene.frame(at: 0)
        #expect(scene.presented(child.id)?.rect == moved.translated(child.offset))
        #expect(scene.samplingError().maxDevicePxError == 0)
    }

    // MARK: - tests/siblings.rs

    @Test("Sibling order matches reference after removal and slot reuse")
    func siblingOrderMatchesReferenceAfterRemovalAndSlotReuse() {
        for nested in [false, true] {
            var s = Scene()
            let parent = NodeId(1000)
            if nested {
                s.insert(parent, NodeSpec(.zero), .initial)
            }
            var expected: [NodeId] = []
            var seed: UInt32 = 1
            for step in UInt64(0)..<300 {
                seed = seed &* 1664525 &+ 1013904223
                if !expected.isEmpty && seed % 3 != 0 {
                    let idx = Int(seed) % expected.count
                    s.unmount(expected.remove(at: idx))
                } else {
                    let id = NodeId(step)
                    let base = NodeSpec(MotionRect.fromXYWH(0, 0, 10, 10))
                    s.insert(id, nested ? base.parent(parent) : base, .initial)
                    expected.append(id)
                }
                for id in expected {
                    s.set(id, Props.OPACITY, step % 2 == 0 ? 0.8 : 1.0)
                }
                let out = s.frameAt(Double(step) / 120.0)
                let actual = out.changed.filter { $0.node != parent }.map(\.node)
                #expect(actual == expected)
            }
        }
    }

    // MARK: - tests/scene.rs

    @Test("Pixel scale re-snaps settled nodes without retargeting")
    func pixelScaleResnapsSettledNodesWithoutRetargeting() {
        func make(scale: Float) -> Scene {
            var s = Scene()
            s.setPixelScale(scale)
            s.insert(NodeId(1), spec(0.123, 0.137, 30.123, 20.137), .initial)
            _ = s.frameAt(0.0)
            return s
        }
        var scene = make(scale: 1.0)
        for scale: Float in [2.0, 1.5, 1.0] {
            scene.setPixelScale(scale)
            #expect(scene.frameAt(0.0).changed.count == 1)
            let fresh = make(scale: scale)
            #expect(scene.presented(NodeId(1))?.rect == fresh.presented(NodeId(1))?.rect)
            scene.setPixelScale(scale)
            #expect(scene.frameAt(0.0).changed.isEmpty)
        }
    }

    @Test("Instant frame lands an unchanged target mid-flight")
    func instantFrameLandsAnUnchangedTargetMidFlight() {
        var s = Scene()
        let id = NodeId(1)
        s.insert(id, spec(0, 0, 100, 40), .initial)
        _ = s.frameAt(0.0)
        let target = MotionRect.fromXYWH(30, 60, 200, 120)
        s.setFrame(id, target, Spring(duration: 0.32, bounce: 0.0))
        #expect(s.frameAt(0.05).animating)
        s.setFrame(id, target, LayoutAnim.instant)
        #expect(!s.frameAt(0.05).animating)
        #expect(s.presented(id)?.rect == target)
    }

    @Test("First mount does not animate")
    func firstMountDoesNotAnimate() {
        var s = Scene()
        s.insert(NodeId(1), spec(0, 0, 100, 40).transition(.blurReplace()), .initial)
        let out = s.frameAt(0.0)
        let p = find(out.changed, NodeId(1))!
        #expect(p.opacity == 1.0 && p.blur == 0.0 && p.transform.sx == 1.0)
        #expect(!out.animating)
        #expect(p.phase == .present)
    }

    @Test("blurReplace enters and exits and never unmounts visible")
    func blurReplaceEntersAndExitsAndNeverUnmountsVisible() {
        var s = Scene()
        let id = NodeId(2)
        s.insert(id, spec(0, 0, 200, 60).transition(.blurReplace()), .animated)
        let (enter, _) = runScene(&s, from: 0.0, until: 1.0, id: id)
        let first = enter[0].1
        #expect(first.opacity < 1e-3 && abs(first.blur - 1.5) < 1e-3 && abs(first.transform.sx - 0.96) < 1e-4)
        let last = enter.last!.1
        #expect(last.opacity == 1.0 && last.blur == 0.0 && last.transform.sx == 1.0)
        #expect(s.phase(id) == .present)
        let enterTime = enter.last!.0

        s.setTime(2.0)
        s.remove(id)
        let (exit, exitedAt) = runScene(&s, from: 2.0, until: 3.0, id: id)
        let exitEnd = exitedAt!
        let finalFrame = exit.last { $0.0 <= exitEnd }!.1
        #expect(finalFrame.opacity < 1.0 / 255.0)
        for (_, p) in exit {
            #expect(p.blur <= 1.5 + 1e-3 && p.transform.sx >= 0.9)
            #expect(!p.inFlow)
        }
        #expect(!s.contains(id))
        #expect(exitEnd - 2.0 < enterTime)
    }

    @Test("An exit unmounts once it fades out of sight")
    func exitUnmountsOnceFadedOut() {
        for transition in [Transition.opacity, Transition.push(from: .bottom), Transition.scale(0.9)] {
            var s = Scene()
            let id = NodeId(4)
            s.insert(id, spec(0, 0, 120, 40).transition(transition), .initial)
            _ = s.frameAt(0.0)
            s.remove(id)
            let (exit, exitedAt) = runScene(&s, from: 0.0, until: 1.0, id: id)
            let end = exitedAt!
            let unseen = exit.first { $0.1.opacity < 1.0 / 255.0 }!.0
            #expect(end == unseen)
        }
    }

    private func sameLook(_ a: Presented, _ b: Presented) {
        #expect(abs(a.opacity - b.opacity) < 2e-3)
        #expect(abs(a.blur - b.blur) < 2e-3)
        #expect(abs(a.transform.sx - b.transform.sx) < 2e-3)
        #expect(abs(a.rect.x - b.rect.x) < 2e-3 && abs(a.rect.y - b.rect.y) < 2e-3)
    }

    @Test("A key that returns mid-exit revives without a jump")
    func reviveMidExitAndRemoveMidEnter() {
        for transition in [Transition.blurReplace(), Transition.push(from: .bottom), Transition.scale(0.9)] {
            var s = Scene()
            let id = NodeId(3)
            let sp = spec(0, 0, 120, 40).transition(transition)
            s.insert(id, sp, .initial)
            _ = s.frameAt(0.0)
            s.remove(id)
            let (_, gone1) = runScene(&s, from: 0.0, until: 0.1, id: id)
            #expect(gone1 == nil)
            let t = 0.1 + 1.0 / Self.hz
            let before = find(s.frameAt(t).changed, id)!
            s.insert(id, sp, .animated)
            let after = find(s.frameAt(t).changed, id)!
            sameLook(before, after)
            #expect(after.phase == .entering)
            let (seen, gone2) = runScene(&s, from: t, until: t + 1.5, id: id)
            #expect(gone2 == nil)
            let rest = seen.last!.1
            #expect(rest.opacity == 1.0 && rest.blur == 0.0 && rest.transform.sx == 1.0)
            #expect(rest.rect == MotionRect.fromXYWH(0, 0, 120, 40))

            // Reverse: removed mid-entrance
            var s2 = Scene()
            s2.insert(NodeId(9), spec(0, 0, 10, 10), .initial)
            _ = s2.frameAt(0.0)
            s2.insert(id, sp, .animated)
            _ = runScene(&s2, from: 0.0, until: 0.08, id: id)
            let t2 = 0.08 + 1.0 / Self.hz
            let before2 = find(s2.frameAt(t2).changed, id)!
            s2.remove(id)
            let after2 = find(s2.frameAt(t2).changed, id)!
            sameLook(before2, after2)
            let (seen2, gone3) = runScene(&s2, from: t2, until: t2 + 1.0, id: id)
            #expect(gone3 != nil)
            #expect(seen2.last!.1.opacity < 1.0 / 255.0)
        }
    }

    @Test("A key that returns mid-exit on an initial mount lands at rest")
    func reviveOnInitialMountLandsAtRest() {
        for transition in [Transition.opacity, Transition.blurReplace(), Transition.push(from: .bottom)] {
            var s = Scene()
            let id = NodeId(5)
            let sp = spec(0, 0, 120, 40).transition(transition)
            s.insert(id, sp, .initial)
            _ = s.frameAt(0.0)
            s.remove(id)
            let (seen, gone) = runScene(&s, from: 0.0, until: 0.2, id: id)
            #expect(gone == nil && seen.last!.1.opacity < 0.2)
            let t = 0.2 + 1.0 / Self.hz
            let moved = MotionRect.fromXYWH(10, 30, 140, 40)
            s.insert(id, NodeSpec(moved).transition(transition), .initial)
            let out = s.frameAt(t)
            #expect(!out.animating)
            let p = find(out.changed, id)!
            #expect(p.opacity == 1.0 && p.blur == 0.0 && p.transform.sx == 1.0 && p.phase == .present)
            #expect(p.rect == moved)
            let (seen2, _) = runScene(&s, from: t, until: t + 1.0, id: id)
            #expect(seen2.allSatisfy { $0.1.opacity == 1.0 && $0.1.rect == moved })
        }
    }

    @Test("an_initial_mount_revive_lands_motion_toward_the_same_frame_and_screen_travel")
    func initialMountReviveLandsMotionTowardSameFrameAndScreenTravel() {
        for screen in [false, true] {
            var s = Scene()
            let id = NodeId(6)
            let target = MotionRect.fromXYWH(60, 80, 120, 40)
            s.insert(id, spec(0, 0, 120, 40).transition(.opacity), .initial)
            _ = s.frameAt(0.0)
            let slow = LayoutAnim(Spring(duration: 1.0, bounce: 0.0))
            s.setFrame(id, target, screen ? slow.screen() : slow)
            _ = s.frameAt(0.05)
            s.remove(id)
            let (seen, gone) = runScene(&s, from: 0.05, until: 0.15, id: id)
            #expect(gone == nil && seen.last!.1.rect != target)
            let t = 0.15 + 1.0 / Self.hz
            s.insert(id, NodeSpec(target).transition(.opacity), .initial)
            let out = s.frameAt(t)
            #expect(!out.animating)
            let p = find(out.changed, id)!
            #expect((p.opacity, p.rect, p.phase) == (1.0, target, .present))
            let (seen2, _) = runScene(&s, from: t, until: t + 1.0, id: id)
            #expect(seen2.allSatisfy { $0.1.opacity == 1.0 && $0.1.rect == target })
        }
    }

    @Test("Child mounted after parent visibly arrives enters on its own")
    func childMountedAfterParentVisiblyArrivesEntersOnItsOwn() {
        var s = Scene()
        let (p, c) = (NodeId(42), NodeId(43))
        s.insert(NodeId(1), spec(0, 0, 1, 1), .initial)
        _ = s.frameAt(0.0)
        s.insert(p, spec(0, 0, 100, 100), .animated)
        var t = 0.0
        while true {
            t += 1.0 / Self.hz
            let out = s.frameAt(t)
            if let pp = find(out.changed, p), pp.opacity >= 1.0 - 1.0 / 255.0 { break }
            #expect(t < 2.0)
        }
        #expect(s.phase(p) == .entering)
        s.setTime(t + 1.0 / Self.hz)
        s.insert(c, spec(10, 10, 20, 20).parent(p), .animated)
        let cp = find(s.frame().changed, c)!
        #expect(cp.phase == .entering)
        #expect(cp.opacity < 0.5)
    }

    @Test("Stationary edges never move and width leads")
    func stationaryEdgesAndWidthLeads() {
        var s = Scene()
        let id = NodeId(4)
        s.insert(id, spec(0, 0, 100, 50), .initial)
        _ = s.frameAt(0.0)
        s.setFrame(id, MotionRect.fromXYWH(0, 20, 300, 30), LayoutAnim(MotionTokens.REFLOW).widthLeads())
        let (seen, _) = runScene(&s, from: 0.0, until: 1.5, id: id)
        #expect(seen.count > 30)
        var xAhead = 0
        for (_, p) in seen {
            #expect(p.rect.left == 0.0)
            #expect(p.rect.bottom == 50.0)
            let xp = (p.rect.right - 100.0) / 200.0
            let yp = p.rect.top / 20.0
            if xp > yp + 1e-3 { xAhead += 1 }
        }
        #expect(xAhead > 10)
        #expect(seen.last!.1.rect == MotionRect.fromXYWH(0, 20, 300, 30))
    }

    private func maxPathDeviation(_ pts: [(Float, Float)], start: (Float, Float), end: (Float, Float)) -> Float {
        let dx = end.0 - start.0
        let dy = end.1 - start.1
        let len = sqrtf(dx * dx + dy * dy)
        return pts.map { (x, y) in abs((x - start.0) * dy - (y - start.1) * dx) / len }.max() ?? 0
    }

    @Test("Screen travel takes one straight path")
    func screenTravelTakesOneStraightPath() {
        func childPath(screen: Bool) -> ([(Float, Float)], (Float, Float), Scene) {
            var s = Scene()
            let (p, c) = (NodeId(10), NodeId(11))
            s.insert(p, spec(0, 0, 400, 400), .initial)
            s.insert(c, spec(10, 10, 50, 50).parent(p), .initial)
            _ = s.frameAt(0.0)
            s.setFrame(p, MotionRect.fromXYWH(200, 100, 400, 400), MotionTokens.GLIDE)
            let child = LayoutAnim(MotionTokens.DRIFT)
            s.setFrame(c, MotionRect.fromXYWH(100, 200, 50, 50), screen ? child.screen() : child)
            let (seen, _) = runScene(&s, from: 0.0, until: 3.0, id: c)
            let pts = seen.map { ($0.1.rect.x, $0.1.rect.y) }
            return (pts, pts.last!, s)
        }

        var (pts, last, s) = childPath(screen: true)
        #expect(last == (300.0, 300.0))
        let dev = maxPathDeviation(pts, start: (10, 10), end: (300, 300))
        #expect(dev < 0.05)
        for i in 1..<pts.count {
            #expect(pts[i].0 >= pts[i - 1].0 - 1e-3 && pts[i].1 >= pts[i - 1].1 - 1e-3)
        }
        s.setFrame(NodeId(10), MotionRect.fromXYWH(0, 0, 400, 400), .instant)
        let out = s.frameAt(3.1)
        #expect(find(out.changed, NodeId(11))?.rect.origin == Vec2(100, 200))

        let (ptsParent, _, _) = childPath(screen: false)
        let devParent = maxPathDeviation(ptsParent, start: (10, 10), end: (300, 300))
        #expect(devParent > 2.0)
    }

    @Test("Matched geometry morphs one surface")
    func matchedGeometryMorphsOneSurface() {
        var s = Scene()
        let (chip, panel) = (NodeId(20), NodeId(21))
        let red = MotionColor(r: 1.0, g: 0.23, b: 0.19, a: 1.0)
        let white = MotionColor(r: 1, g: 1, b: 1, a: 1)
        s.insert(chip, spec(10, 10, 80, 30).radius(15).fill(red), .initial)
        let before = find(s.frameAt(0.0).changed, chip)!
        s.setTime(1.0 / Self.hz)
        s.insert(panel, spec(0, 100, 300, 200).radius(12).fill(white), .initial)
        s.matchGeometry(chip, panel, LayoutAnim(MotionTokens.MORPH).widthLeads())
        let out = s.frameAt(1.0 / Self.hz)
        #expect(out.exited.contains(chip))
        let first = find(out.changed, panel)!
        #expect(first.rect == before.rect)
        #expect(first.corners == .all(15.0))
        #expect(abs((first.fill?.r ?? 0) - red.r) < 2e-3 && first.opacity == 1.0)
        let (seen, _) = runScene(&s, from: 2.0 / Self.hz, until: 2.0, id: panel)
        let last = seen.last!.1
        #expect(last.rect == MotionRect.fromXYWH(0, 100, 300, 200))
        #expect(last.corners == .all(12.0))
    }

    @Test("Reduced motion swaps travel for a short fade")
    func reducedMotionSwapsTravelForShortFade() {
        var s = Scene()
        s.setReducedMotion(true)
        let id = NodeId(30)
        s.insert(NodeId(31), spec(0, 0, 10, 10), .initial)
        _ = s.frameAt(0.0)
        s.insert(id, spec(0, 0, 100, 40).transition(Transition.blurReplace().combined(with: Transition.push(from: .top))), .animated)
        let first = find(s.frameAt(0.0).changed, id)!
        #expect((first.blur, first.transform.sx, first.rect.y) == (0.0, 1.0, 0.0))
        #expect(first.opacity < 1e-3)
        let mid = find(s.frameAt(0.09).changed, id)!
        #expect(mid.opacity > 0.3 && mid.opacity < 0.7)
        #expect(find(s.frameAt(0.18).changed, id)!.opacity == 1.0)
        s.setFrame(id, MotionRect.fromXYWH(50, 50, 100, 40), MotionTokens.GLIDE)
        #expect(find(s.frameAt(0.2).changed, id)!.rect.origin == Vec2(50, 50))
    }

    @Test("Children ride entering parent and late children enter independently")
    func childrenRideParentAndLateEnterAlone() {
        var s = Scene()
        let (p, c) = (NodeId(40), NodeId(41))
        s.insert(NodeId(1), spec(0, 0, 1, 1), .initial)
        _ = s.frameAt(0.0)
        s.insert(p, spec(0, 0, 100, 100).transition(Transition.move(edge: .leading)), .animated)
        s.insert(c, spec(10, 10, 20, 20).parent(p), .animated)
        let out = s.frameAt(0.0)
        let pp = find(out.changed, p)!
        let cp = find(out.changed, c)!
        #expect(cp.phase == .present)
        #expect(cp.rect.x == pp.rect.x + 10.0)
        s.setTime(1.0)
        s.remove(p)
        let (_, gone) = runScene(&s, from: 1.0, until: 2.0, id: p)
        #expect(gone != nil && !s.contains(c))

        // Late child
        var s2 = Scene()
        let (p2, c2) = (NodeId(44), NodeId(45))
        s2.insert(NodeId(1), spec(0, 0, 1, 1), .initial)
        _ = s2.frameAt(0.0)
        s2.insert(p2, spec(0, 0, 100, 100), .animated)
        var t = 0.0
        while t < 2.0 {
            t += 1.0 / Self.hz
            let o = s2.frameAt(t)
            if find(o.changed, p2).map({ $0.opacity >= 0.9 }) == true { break }
        }
        s2.setTime(t + 1.0 / Self.hz)
        s2.insert(c2, spec(10, 10, 20, 20).parent(p2), .animated)
        let cp2 = find(s2.frame().changed, c2)!
        #expect(cp2.phase == .entering && cp2.opacity < 0.5)
    }

    @Test("An entrance that changes nothing lands at once")
    func identityEntranceLandsAtOnce() {
        var s = Scene()
        s.insert(NodeId(1), spec(0, 0, 1, 1), .initial)
        _ = s.frameAt(0.0)
        let id = NodeId(46)
        let pair = SpringPair(enter: Spring(duration: 0.3, bounce: 0), exit: Spring(duration: 0.3, bounce: 0))
        s.insert(id, spec(0, 0, 100, 40).transition(Transition.identity.springs(pair)), .animated)
        s.setTime(1.0 / Self.hz)
        let out = s.frame()
        #expect(!out.animating)
        #expect(s.phase(id) == .present)
    }

    @Test("Flags mark intent and trace writes motion-lint JSONL")
    func flagsAndTraceMotionLintJSONL() {
        var s = Scene()
        let header = TraceHeader(launch: "test", width: 400, height: 300, hz: 120, scale: 2)
        let trace = MotionTrace.inMemory(header: header)
        s.setTrace(trace)
        s.insert(NodeId(1), spec(0, 0, 10, 10), .initial)
        _ = s.frameAt(0.0)
        s.insert(NodeId(2), spec(0, 20, 100, 40).transition(.blurReplace()), .animated)
        _ = runScene(&s, from: 0.0, until: 0.6, id: NodeId(2))
        s.remove(NodeId(2))
        _ = runScene(&s, from: 0.6, until: 1.4, id: NodeId(2))
        _ = s.takeTrace()
        let text = trace.contents()
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines[0].hasPrefix("{\"type\":\"header\",\"launch\":\"test\""))
        #expect(lines.contains { $0.contains("\"e\":[[2,") })
        #expect(lines.contains { $0.contains("\"ai\":[[2,") })
        #expect(lines.contains { $0.contains("\"g\":[2]") })
        #expect(lines.allSatisfy { $0.hasPrefix("{") && $0.hasSuffix("}") })
    }

    @Test("Scale floor stays above 0.9 unless allowSmallScale is opted in")
    func scaleFloorGuardrails() {
        func startScale(_ t: Transition) -> Float {
            var s = Scene()
            s.insert(NodeId(9), spec(0, 0, 16, 16).transition(t), .animated)
            return find(s.frameAt(0.0).changed, NodeId(9))!.transform.sx
        }
        #expect(abs(startScale(.scale(0.6)) - 0.9) < 1e-4)
        #expect(abs(startScale(Transition.scale(0.6).allowSmallScale()) - 0.6) < 1e-4)
        #expect(abs(startScale(Transition.scale(0.0).allowSmallScale()) - Transition.smallScaleFloor) < 1e-4)
        #expect(abs(startScale(Transition.scale(0.6).allowSmallScale().combined(with: .opacity)) - 0.6) < 1e-4)

        var s = Scene()
        let id = NodeId(10)
        s.insert(id, spec(0, 0, 16, 16).transition(Transition.scale(0.6).allowSmallScale()), .initial)
        _ = s.frameAt(0.0)
        s.remove(id)
        let (exitSeen, exitedAt) = runScene(&s, from: 0.0, until: 1.0, id: id)
        let exited = exitedAt!
        let last = exitSeen.last { $0.0 <= exited }!.1
        #expect(last.transform.sx < 0.65 && last.opacity < 1.0 / 255.0)
    }

    @Test("Frozen ancestor holds screen travel without frames and trailing child rests with parent")
    func frozenAncestorAndTrailingChild() {
        var s = Scene()
        let (p, c) = (NodeId(10), NodeId(11))
        s.insert(p, spec(0, 0, 400, 400), .initial)
        s.insert(c, spec(10, 10, 50, 50).parent(p), .initial)
        _ = s.frameAt(0.0)
        s.setFrame(p, MotionRect.fromXYWH(200, 100, 400, 400), MotionTokens.GLIDE)
        s.setFrame(c, MotionRect.fromXYWH(100, 200, 50, 50), LayoutAnim(MotionTokens.DRIFT).screen())
        _ = s.frameAt(0.05)
        s.setTimeScale(p, 0.0)
        var t = 0.05
        while t < 3.0 {
            t += 1.0 / Self.hz
            _ = s.frameAt(t)
        }
        #expect(!s.frameAt(t).animating)
        s.setTimeScale(p, 1.0)
        let (seen, _) = runScene(&s, from: t, until: t + 3.0, id: c)
        #expect(!s.frameAt(t + 3.1).animating)
        #expect(seen.last!.1.rect.origin == Vec2(300, 300))

        // Trailing child
        var s2 = Scene()
        let (tp, tc) = (NodeId(1), NodeId(2))
        s2.insert(tp, spec(0, 0, 40, 20), .initial)
        s2.insert(tc, spec(30, 4, 6, 6).parent(tp), .initial)
        s2.setRideTrailing(tc, true)
        _ = s2.frameAt(0.0)
        s2.setFrame(tp, MotionRect.fromXYWH(0, 0, 70, 20), Spring(duration: 0.3, bounce: 0))
        _ = s2.frameAt(0.05)
        let shown = s2.presented(tc)!
        #expect(shown.rect.x > 30.0 && shown.rect.x < 60.0)
        #expect(s2.rest(tc) == MotionRect.fromXYWH(60, 4, 6, 6))
    }

    @Test("Static node keeps no tracks and unchanged commits stay clean")
    func staticNodeAndSettledClean() {
        let id = NodeId(1)
        let frame = MotionRect.fromXYWH(0, 0, 100, 40)
        var s = Scene()
        s.insert(id, NodeSpec(frame).opacity(0.5).radius(4.0), .initial)
        _ = s.frameAt(0.0)
        #expect(s.store.trackLen == 0)
        for k in 1..<3 {
            s.setFrame(id, frame, Spring(duration: 0.3, bounce: 0))
            s.animate(id, Props.OPACITY, to: 0.5, spring: Spring(duration: 0.3, bounce: 0))
            s.set(id, Props.CORNERS, .all(4.0))
            #expect(s.frameAt(Double(k) / Self.hz).changed.isEmpty)
        }
        #expect(s.store.trackLen == 0)

        s.animate(id, Props.OPACITY, to: 0.2, spring: Spring(duration: 0.2, bounce: 0))
        let mid = find(s.frameAt(0.05).changed, id)!.opacity
        #expect(mid < 1.0 && mid > 0.2)
        var t = 0.05
        while s.frameAt(t).animating { t += 1.0 / Self.hz }
        s.set(id, Props.OPACITY, 0.2)
        s.animate(id, Props.OPACITY, to: 0.2, spring: Spring(duration: 0.2, bounce: 0))
        #expect(s.frameAt(t + 1.0 / Self.hz).changed.isEmpty)
    }

    @Test("Node without presence track still fades out on remove")
    func nodeWithoutPresenceTrackStillFadesOut() {
        let id = NodeId(1)
        var s = Scene()
        s.insert(id, spec(0, 0, 100, 40), .initial)
        _ = s.frameAt(0.0)
        s.remove(id)
        let o = find(s.frameAt(0.05).changed, id)!.opacity
        #expect(o > 0.0 && o < 1.0)
        var t = 0.05
        var gone = false
        while t < 3.0 && !gone {
            t += 1.0 / Self.hz
            gone = s.frameAt(t).exited.contains(id)
        }
        #expect(gone)
    }

    // MARK: - tests/enter_delay.rs

    @Test("Delayed insertion holds effect, waits idle, stretches on node clock, and handles remove/landWaiting")
    func delayedInsertionSemantics() {
        let sp = NodeSpec(MotionRect.fromXYWH(0, 0, 100, 40))
            .transition(Transition.offset(x: 0, y: 12).combined(with: .opacity))
        var s = Scene()
        s.setPixelScale(8.0)
        _ = s.frameAt(0.0)
        let id = NodeId(1)
        s.insertDelayed(id, sp, .animated, delay: 0.3)

        var t = 0.0
        while t <= 0.29 + 1e-9 {
            _ = s.frameAt(t)
            let p = s.presented(id)!
            #expect(p.rect.y == 12.0 && p.opacity == 0.0)
            t += 1.0 / Self.hz
        }
        _ = s.frameAt(0.1)
        #expect(abs((s.store.waitingUntil() ?? 0) - 0.3) < 1e-6)

        while t <= 1.5 + 1e-9 {
            _ = s.frameAt(t)
            let p = s.presented(id)!
            let offProg = 1.0 - p.rect.y / 12.0
            #expect(abs(offProg - p.opacity) < 2e-3)
            t += 1.0 / Self.hz
        }
        #expect(s.presented(id)?.phase == .present)
        #expect(s.store.waitingUntil() == nil)

        // Node clock stretches delay
        var sc = Scene()
        sc.setPixelScale(8.0)
        _ = sc.frameAt(0.0)
        sc.insertDelayed(id, sp, .animated, delay: 0.3)
        sc.setTimeScale(id, 0.5)
        _ = sc.frameAt(0.1)
        #expect(abs((sc.store.waitingUntil() ?? 0) - 0.6) < 1e-6)
        _ = sc.frameAt(0.59)
        #expect(sc.presented(id)?.opacity == 0.0)
        _ = sc.frameAt(0.7)
        #expect((sc.presented(id)?.opacity ?? 0) > 0.0)

        // Removed while waiting unseen unmounts immediately
        var sr = Scene()
        _ = sr.frameAt(0.0)
        sr.insertDelayed(id, sp, .animated, delay: 0.3)
        _ = sr.frameAt(0.1)
        sr.remove(id)
        #expect(sr.frameAt(0.11).exited.contains(id))
        #expect(!sr.frameAt(0.5).animating)

        // landWaiting settles held entrance immediately
        var sl = Scene()
        _ = sl.frameAt(0.0)
        sl.insertDelayed(id, sp, .animated, delay: 0.3)
        _ = sl.frameAt(0.1)
        sl.landWaiting(id)
        let lout = sl.frameAt(0.11)
        #expect(!lout.animating)
        let lp = sl.presented(id)!
        #expect((lp.rect.y, lp.opacity, lp.phase) == (0.0, 1.0, .present))

        // A visible insertion effect fades out from where it waited
        var sv = Scene()
        _ = sv.frameAt(0.0)
        let slideSpec = NodeSpec(MotionRect.fromXYWH(0, 0, 100, 40)).transition(Transition.offset(x: 0, y: 12))
        sv.insertDelayed(id, slideSpec, .animated, delay: 0.3)
        _ = sv.frameAt(0.1)
        #expect((sv.presented(id)!.rect.y, sv.presented(id)!.opacity) == (12.0, 1.0))
        sv.remove(id)
        var prevOp: Float = 1.0
        var vt = 0.1
        while vt <= 0.25 + 1e-9 {
            _ = sv.frameAt(vt)
            if let vp = sv.presented(id) {
                #expect(abs(vp.rect.y - 12.0) < 2.0 / 64.0)
                #expect(vp.opacity <= prevOp + 1e-6)
                prevOp = vp.opacity
            }
            vt += 1.0 / Self.hz
        }
        #expect(prevOp < 1.0)

        // Reduced motion keeps the delay and only fades
        var srm = Scene()
        _ = srm.frameAt(0.0)
        srm.setReducedMotion(true)
        srm.insertDelayed(id, sp, .animated, delay: 0.3)
        var firstShown: Double? = nil
        var rt = 0.0
        while rt <= 1.0 + 1e-9 {
            _ = srm.frameAt(rt)
            if let rp = srm.presented(id) {
                #expect(rp.rect.y == 0.0)
                if rt < 0.3 - 1e-9 {
                    #expect(rp.opacity == 0.0)
                }
                if firstShown == nil && rp.opacity >= 1.0 {
                    firstShown = rt
                }
            }
            rt += 1.0 / Self.hz
        }
        let shown = firstShown!
        #expect(shown > 0.3 && shown < 0.6)
    }

    @Test("Staggered list of five enters in order")
    func staggeredListEntersInOrder() {
        var s = Scene()
        s.setPixelScale(8.0)
        _ = s.frameAt(0.0)
        let sp = NodeSpec(MotionRect.fromXYWH(0, 0, 100, 40))
            .transition(Transition.offset(x: 0, y: 12).combined(with: .opacity))
        let stagger = Stagger(step: 0.05, maxDelay: 0.0)
        for i in 0..<5 {
            s.insertDelayed(NodeId(UInt64(i + 1)), sp, .animated, delay: stagger.delay(index: i, count: 5))
        }
        var starts: [Double?] = [nil, nil, nil, nil, nil]
        var t = 0.0
        while t < 1.5 {
            _ = s.frameAt(t)
            for i in 0..<5 {
                let p = s.presented(NodeId(UInt64(i + 1)))!
                let offProg = 1.0 - p.rect.y / 12.0
                #expect(abs(offProg - p.opacity) < 2e-3)
                if p.opacity > 0 && starts[i] == nil {
                    starts[i] = t
                }
            }
            t += 1.0 / Self.hz
        }
        let concrete = starts.compactMap { $0 }
        #expect(concrete.count == 5)
        for i in 0..<4 {
            #expect(abs((concrete[i + 1] - concrete[i]) - 0.05) < 1.5 / Self.hz)
        }
    }

    // MARK: - tests/phase_walk.rs

    @Test("Phase walk: child travelling first lands the frame after parent and matched geometry onto exit")
    func childTravellingFirstAndMatchedGeometryOntoExit() {
        let (p, c) = (NodeId(10), NodeId(11))
        let childFrame = MotionRect.fromXYWH(10, 10, 50, 50)
        var s = Scene()
        s.insert(p, NodeSpec(MotionRect.fromXYWH(0, 0, 400, 400)), .initial)
        s.insert(c, NodeSpec(childFrame).parent(p), .initial)
        _ = s.frameAt(0.0)
        let travel = LayoutAnim(Spring(duration: 0.3, bounce: 0))
        s.launch(c, from: MotionRect.fromXYWH(300, 300, 50, 50), anim: travel)
        s.launch(p, from: MotionRect.fromXYWH(100, 100, 400, 400), anim: travel)
        s.animate(p, Props.FRAME, to: MotionRect.fromXYWH(20, 20, 400, 400), spring: Spring(duration: 2.0, bounce: 0))
        var parentK: Int? = nil
        var childK: Int? = nil
        for k in 1..<600 {
            _ = s.frameAt(Double(k) / 120.0)
            if parentK == nil && s.isRestingAt(p, MotionRect.fromXYWH(0, 0, 400, 400)) { parentK = k }
            if childK == nil && s.isRestingAt(c, childFrame) { childK = k }
            if parentK != nil && childK != nil { break }
        }
        #expect(parentK != nil && childK != nil)
        #expect(childK! == parentK! + 1)

        // Matched geometry onto an exit keeps its exit-at-1 look
        let pair = SpringPair(enter: Spring(duration: 0.12, bounce: 0), exit: Spring(duration: 0.12, bounce: 0))
        let tr = Transition.push(from: .bottom).combined(with: .draw).springs(pair)
        func runMatch(_ exitFirst: Bool) -> Presented {
            let (from, to) = (NodeId(30), NodeId(1))
            let toSpec = NodeSpec(MotionRect.fromXYWH(40, 20, 100, 40)).transition(tr)
            var sc = Scene()
            sc.insert(from, NodeSpec(MotionRect.fromXYWH(0, 0, 20, 20)), .initial)
            sc.insert(to, toSpec, .animated)
            var t = 0.0
            for _ in 0..<4 { t += 1.0 / 120.0; _ = sc.frameAt(t) }
            if exitFirst {
                sc.remove(to)
                for _ in 0..<3 { t += 1.0 / 120.0; _ = sc.frameAt(t) }
            }
            sc.matchGeometry(from, to, LayoutAnim(pair))
            t += 1.0 / 120.0; _ = sc.frameAt(t)
            return sc.presented(to)!
        }
        let kept = runMatch(true)
        let plain = runMatch(false)
        #expect(kept.phase == .present && plain.phase == .present)
        #expect(abs(kept.rect.y - plain.rect.y) > kept.rect.height * 0.5)
    }

    @Test("Exhaustive presence walks match reference Dev model (all Presented fields)")
    func exhaustivePresenceSequencesMatchReference() {
        enum Step { case insert(Mount, Float), retransition, remove, reenter, enterNow, landWaiting, unmount, tick }
        let slow = SpringPair(enter: Spring(duration: 0.12, bounce: 0), exit: Spring(duration: 0.12, bounce: 0))
        let blurReveal: (SpringPair) -> Transition = { sp in
            Transition.blurReplace().combined(with: Transition.reveal(edge: .leading)).springs(sp)
        }
        let pushDraw: (SpringPair) -> Transition = { sp in
            Transition.push(from: .bottom).combined(with: .draw).springs(sp)
        }
        let slideTr: (SpringPair) -> Transition = { sp in
            Transition.move(edge: .leading).springs(sp)
        }
        let cornerScale: (SpringPair) -> Transition = { sp in
            let removal = Transition.scale(0.9, anchor: Vec2(0, 0)).combined(with: Transition.reveal(edge: .top))
            return Transition.asymmetric(insertion: Transition.move(edge: .leading), removal: removal).springs(sp)
        }

        let id = NodeId(1)
        let frame = MotionRect.fromXYWH(10, 20, 100, 40)

        func lanes(_ e: TransitionEffect) -> [Float] {
            let hidden: Float = e.reveal != nil ? 1.0 : 0.0
            return [
                e.zeroOpacity ?? 1.0,
                e.zeroScale.x,
                e.pointOffset.x,
                e.pointOffset.y,
                e.relativeOffset.x,
                e.relativeOffset.y,
                e.zeroBlur,
                hidden,
                e.draw,
            ]
        }
        let identityFx: [Float] = [1, 1, 0, 0, 0, 0, 0, 0, 1]

        func lerpFx(_ a: [Float], _ b: [Float], _ p: Float) -> [Float] {
            (0..<9).map { a[$0] * (1.0 - p) + b[$0] * p }
        }

        func runCfg(
            mountTr: Transition,
            retargetTr: Transition,
            springs: SpringPair,
            alphabet: [Step],
            maxDepth: Int
        ) {
            func runPath(_ steps: [Step]) {
                var sc = Scene()
                var ref = AnimationStore()
                ref.set(id, Props.PRESENCE, 1.0)
                var alive = false
                var pendingExit = false
                var phase = ScenePhase.present
                var gen: UInt32 = 0
                var fxA = identityFx
                var fxB = identityFx
                var anchor = Vec2(0.5, 0.5)
                var reveal: Reveal? = nil
                var tr = mountTr
                var t = 0.0

                func checkPresented(_ p: Presented, _ pres: Float) {
                    let look = lerpFx(fxA, fxB, pres)
                    let sx = frame.left + look[2] + look[4] * frame.width
                    let sy = frame.top + look[3] + look[5] * frame.height
                    #expect(abs(p.opacity - min(max(look[0], 0), 1)) <= 1e-6)
                    #expect(abs(p.transform.sx - look[1]) <= 1e-6)
                    #expect(abs(p.rect.left - sx) <= 2.0 / 64.0)
                    #expect(abs(p.rect.top - sy) <= 2.0 / 64.0)
                    let blur = max(look[6], 0) < 1.0 / 64.0 ? 0.0 : max(look[6], 0)
                    #expect(abs(p.blur - blur) <= 1e-6)
                    #expect(abs(p.draw - min(max(look[8], 0), 1)) <= 1e-6)
                    #expect(abs(p.anchor.x - (sx + anchor.x * frame.width)) <= 2.0 / 64.0)
                    #expect(abs(p.anchor.y - (sy + anchor.y * frame.height)) <= 2.0 / 64.0)
                    var inset: [Float] = [0, 0, 0, 0]
                    var feather: [Float] = [0, 0, 0, 0]
                    if let rv = reveal {
                        let hidden = min(max(look[7], 0), 1)
                        if hidden > 0 {
                            let (side, len): (Int, Float) = switch rv.edge {
                            case .leading: (0, frame.width)
                            case .top: (1, frame.height)
                            case .trailing: (2, frame.width)
                            case .bottom: (3, frame.height)
                            }
                            let opp = (side + 2) % 4
                            inset[opp] += hidden * len
                            feather[opp] = rv.feather * min(hidden * len / max(rv.feather, 1e-3), 1.0)
                        }
                    }
                    let gotIn = p.mask.insetEdges
                    let gotFe = p.mask.featherEdges
                    for k in 0..<4 {
                        #expect(abs(gotIn[k] - inset[k]) <= 1e-4)
                        #expect(abs(gotFe[k] - feather[k]) <= 1e-4)
                    }
                    let isExiting: Bool = { if case .exiting = phase { return true }; return false }()
                    #expect(p.inFlow == (!isExiting || !tr.popLayout))
                }

                for st in steps {
                    let pNow = sc.store.sample(id, Props.PRESENCE) ?? 1.0
                    switch st {
                    case let .insert(m, delay):
                        tr = mountTr
                        let sp = NodeSpec(frame).transition(tr)
                        if delay > 0 { sc.insertDelayed(id, sp, m, delay: delay) } else { sc.insert(id, sp, m) }
                        if alive {
                            if case .exiting = phase {
                                if m == .initial {
                                    gen &+= 1; phase = .present
                                    let ins = tr.insertion.kitRules(removal: false)
                                    fxA = lanes(ins); fxB = identityFx; anchor = ins.anchor; reveal = ins.reveal
                                    ref.set(id, Props.PRESENCE, 1.0)
                                } else {
                                    let old0 = fxA; let old1 = fxB
                                    if pNow <= 0.001 {
                                        fxA = lanes(tr.insertion.kitRules(removal: false))
                                    } else {
                                        let cur = lerpFx(old0, old1, pNow)
                                        let q = max(1.0 - pNow, 1e-3)
                                        var nextA = old0
                                        for k in 0..<8 { nextA[k] = (cur[k] - identityFx[k] * pNow) / q }
                                        fxA = nextA
                                    }
                                    fxB = identityFx
                                    gen &+= 1; phase = .entering
                                    ref.animate(id, Props.PRESENCE, to: 1.0, anim: Anim(spring: springs.enter))
                                }
                            }
                        } else {
                            alive = true; gen = 0
                            let ins = tr.insertion.kitRules(removal: false)
                            fxA = lanes(ins); fxB = identityFx; anchor = ins.anchor; reveal = ins.reveal
                            let animate = (m == .animated && !ins.showsNothing)
                            if animate {
                                phase = .entering
                                ref.set(id, Props.PRESENCE, 0.0)
                                ref.animate(id, Props.PRESENCE, to: 1.0, anim: Anim(spring: springs.enter, delay: delay))
                            } else {
                                phase = .present
                                ref.set(id, Props.PRESENCE, 1.0)
                            }
                        }
                    case .retransition:
                        sc.setTransition(id, retargetTr)
                        if case .exiting = phase {} else { tr = retargetTr }
                    case .remove:
                        sc.remove(id)
                        if alive, case .exiting = phase {} else if alive {
                            let unplayed = pNow < 1e-3
                            if unplayed && lerpFx(fxA, fxB, pNow)[0] < 1.0 / 512.0 {
                                alive = false; pendingExit = true
                            } else {
                                let rem = tr.removal.kitRules(removal: true)
                                let target = lanes(rem)
                                gen &+= 1; phase = .exiting(generation: gen)
                                let oldA = fxA; let oldB = fxB
                                if pNow >= 0.999 {
                                    fxA = target; fxB = identityFx
                                } else if unplayed {
                                    fxB = lerpFx(oldA, oldB, pNow); fxA = target
                                } else {
                                    let cur = lerpFx(oldA, oldB, pNow)
                                    fxA = target
                                    for k in 0..<8 { fxB[k] = target[k] + (cur[k] - target[k]) / max(pNow, 1e-3) }
                                }
                                if rem.zeroScale != Vec2(1, 1) { anchor = rem.anchor }
                                if rem.reveal != nil { reveal = rem.reveal }
                                if unplayed { ref.set(id, Props.PRESENCE, 1.0) }
                                ref.animate(id, Props.PRESENCE, to: 0.0, anim: Anim(spring: springs.exit))
                            }
                        }
                    case .reenter:
                        sc.reenter(id)
                        if alive && phase == .present {
                            gen &+= 1; phase = .entering
                            fxA = lanes(tr.insertion.kitRules(removal: false)); fxB = identityFx
                            ref.set(id, Props.PRESENCE, 0.0)
                            ref.animate(id, Props.PRESENCE, to: 1.0, anim: Anim(spring: springs.enter))
                        }
                    case .enterNow:
                        sc.enterNow(id)
                        if alive && phase == .entering {
                            let ins = tr.insertion.kitRules(removal: false)
                            gen &+= 1; phase = .present
                            fxA = lanes(ins); fxB = identityFx; anchor = ins.anchor; reveal = ins.reveal
                            ref.set(id, Props.PRESENCE, 1.0)
                        }
                    case .landWaiting:
                        sc.landWaiting(id)
                        if alive && phase == .entering && pNow < 1e-3 {
                            let ins = tr.insertion.kitRules(removal: false)
                            gen &+= 1; phase = .present
                            fxA = lanes(ins); fxB = identityFx; anchor = ins.anchor; reveal = ins.reveal
                            ref.set(id, Props.PRESENCE, 1.0)
                        }
                    case .unmount:
                        sc.unmount(id)
                        if alive { alive = false; pendingExit = true }
                    case .tick:
                        for _ in 0..<24 {
                            t += 1.0 / 120.0
                            sc.setTime(t)
                            let scP = sc.store.sample(id, Props.PRESENCE) ?? 1.0
                            let out = sc.frame()
                            ref.setTime(t)
                            let refP = ref.sample(id, Props.PRESENCE) ?? 1.0
                            ref.tick()
                            let wasAlive = alive
                            if wasAlive {
                                #expect(abs(scP - refP) <= 1e-5)
                            }
                            let refSettled = ref.events.contains(where: { if case let .settled(_, n, q) = $0 { return n == id && q == Props.PRESENCE.id }; return false })
                            var retired = false
                            if wasAlive && refSettled {
                                switch phase {
                                case .entering: phase = .present
                                case .exiting(let g) where g == gen:
                                    alive = false; retired = true
                                default: break
                                }
                            }
                            if alive, case .exiting = phase, lerpFx(fxA, fxB, refP)[0] < 1.0 / 255.0 {
                                alive = false; retired = true
                            }
                            let expectedExited = retired || pendingExit
                            pendingExit = false
                            #expect(out.exited.contains(id) == expectedExited, "exited mismatch after \(steps)")
                            if let pres = find(out.changed, id) {
                                let shownAt = sc.contains(id) ? (sc.store.sample(id, Props.PRESENCE) ?? 1.0) : scP
                                checkPresented(pres, shownAt)
                            }
                        }
                    }
                    #expect(sc.contains(id) == alive, "contains mismatch after \(steps)")
                    if alive { #expect(sc.phase(id) == phase, "phase mismatch after \(steps)") }
                }
            }

            var cur: [Step] = []
            func rec(_ depth: Int) {
                if !cur.isEmpty { runPath(cur) }
                if depth == 0 { return }
                for s in alphabet {
                    cur.append(s); rec(depth - 1); cur.removeLast()
                }
            }
            rec(maxDepth)
        }

        // walk_entrances_and_exits (depth 5)
        runCfg(
            mountTr: blurReveal(slow),
            retargetTr: pushDraw(slow),
            springs: slow,
            alphabet: [.insert(.animated, 0), .insert(.initial, 0), .retransition, .remove, .reenter, .tick],
            maxDepth: 5
        )
        // walk_held_entrances (depth 5)
        runCfg(
            mountTr: blurReveal(slow),
            retargetTr: pushDraw(slow),
            springs: slow,
            alphabet: [.insert(.animated, 0.05), .enterNow, .landWaiting, .remove, .unmount, .tick],
            maxDepth: 5
        )
        // walk_visible_entrances_that_never_played (depth 5)
        runCfg(
            mountTr: slideTr(slow),
            retargetTr: cornerScale(slow),
            springs: slow,
            alphabet: [.insert(.animated, 0), .insert(.initial, 0), .retransition, .remove, .reenter, .tick],
            maxDepth: 5
        )
        // walk_instant_presence (depth 5)
        runCfg(
            mountTr: blurReveal(.none),
            retargetTr: pushDraw(.none),
            springs: .none,
            alphabet: [.insert(.animated, 0), .retransition, .remove, .reenter, .enterNow, .tick],
            maxDepth: 5
        )
    }

    @Test("Exiting ancestor keeps omitted transitionless descendants mounted in place until exit settles")
    func exitingAncestorKeepsOmittedDescendantsMountedUntilSettled() {
        var scene = Scene()
        let rootId = NodeId(100)
        let popupId = NodeId(101)
        let rowId = NodeId(102)
        let rootSpec = NodeSpec(id: rootId, rect: .fromXYWH(0, 0, 400, 400))
        let popupSpec = NodeSpec(
            id: popupId,
            parent: rootId,
            rect: .fromXYWH(20, 40, 200, 120),
            opacity: 1,
            transition: Transition.opacity
        )
        let rowSpec = NodeSpec(
            id: rowId,
            parent: popupId,
            rect: .fromXYWH(24, 120, 192, 28),
            opacity: 1
        )
        scene.commit([rootSpec, popupSpec, rowSpec], at: 0.0, initialCut: true)
        _ = scene.frame(at: 0.0)

        // Omit both popup and its transitionless row child without cut
        scene.commit([rootSpec], at: 0.1)
        let mid = scene.frame(at: 0.15)
        let popupMid = mid.nodes.first { $0.id == popupId }
        let rowMid = mid.nodes.first { $0.id == rowId }
        #expect(popupMid != nil && popupMid?.isExiting == true)
        #expect(rowMid != nil)
        #expect(abs((rowMid?.rect.top ?? 0) - 120.0) < 0.01)

        // Once exit completes, both unmount together
        let end = scene.frame(at: 2.0)
        #expect(end.nodes.first { $0.id == popupId } == nil)
        #expect(end.nodes.first { $0.id == rowId } == nil)
    }

    @Test("snapMounts and snapOmittedNonExiting unmount omitted live nodes while keeping prior exits and unrelated animations")
    func instantCommitSnapsMountsAndUnmountsNonExitingOmitted() {
        var scene = Scene()
        let rootId = NodeId(200)
        let keepId = NodeId(201)
        let omitId = NodeId(202)
        let oldExitId = NodeId(203)
        let freshId = NodeId(204)

        let rootSpec = NodeSpec(id: rootId, rect: .fromXYWH(0, 0, 400, 400))
        let keep0 = NodeSpec(id: keepId, parent: rootId, rect: .fromXYWH(0, 0, 40, 40), layoutAnim: LayoutAnim(spring: MotionTokens.SMOOTH))
        let omitSpec = NodeSpec(id: omitId, parent: rootId, rect: .fromXYWH(0, 50, 40, 40), transition: Transition.opacity)
        let oldExitSpec = NodeSpec(id: oldExitId, parent: rootId, rect: .fromXYWH(0, 100, 40, 40), transition: Transition.opacity)

        scene.commit([rootSpec, keep0, omitSpec, oldExitSpec], at: 0.0, initialCut: true)
        _ = scene.frame(at: 0.0)

        // Frame 1: start animating keepId and start oldExitId exiting normally
        let keep1 = NodeSpec(id: keepId, parent: rootId, rect: .fromXYWH(200, 0, 40, 40), layoutAnim: LayoutAnim(spring: MotionTokens.SMOOTH))
        scene.commit([rootSpec, keep1, omitSpec], at: 0.05)
        _ = scene.frame(at: 0.06)
        #expect(scene.contains(oldExitId))

        // Frame 2 (instant): omit `omitSpec`, mount `freshSpec`, keep `keep1` animating
        let freshSpec = NodeSpec(id: freshId, parent: rootId, rect: .fromXYWH(0, 160, 40, 40), opacity: 1, transition: Transition.opacity)
        scene.commit([rootSpec, keep1, freshSpec], at: 0.07, initialCut: false, snapMounts: true, snapOmittedNonExiting: true)
        let f2 = scene.frame(at: 0.07)
        #expect(!scene.contains(omitId))
        #expect(scene.contains(oldExitId))
        let freshPresented = f2.nodes.first { $0.id == freshId }
        #expect(abs((freshPresented?.opacity ?? 0) - 1.0) < 0.001)
        let keepPresented = f2.nodes.first { $0.id == keepId }
        #expect((keepPresented?.rect.left ?? 200) < 190)
    }
}
