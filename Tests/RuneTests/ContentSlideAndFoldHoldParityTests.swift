import Foundation
import Testing
@testable import Rune
import RuneMotion

@Suite("Rune ContentSlide, FoldHold & LandingHold Parity Tests")
struct ContentSlideAndFoldHoldParityTests {
    private static func growth(_ h: Float, _ target: Float) -> GrowTrack {
        var g = GrowTrack.settled(h)
        g.target = target
        return g
    }

    @Test("content_slide::a_slide_shrinks_with_the_growth_left_to_open")
    func slideShrinksWithGrowthLeftToOpen() {
        let phase = SlidePhase.following(dy: -20.0, v: 0.0, at: 0.0)
        let next = phase.step(growth: Self.growth(50.0, 100.0), spring: Growth.spring, substeps: 12)
        guard case let .following(dy, v, at) = next else {
            Issue.record("expected following phase, got \(next)")
            return
        }
        #expect(abs(dy - -10.0) < 1e-4 && abs(at - 50.0) < 1e-4)
        #expect(abs(v - 10.0 / (12.0 * Growth.substep)) < 1e-3)
        let same = next.step(growth: Self.growth(75.0, 100.0), spring: Growth.spring, substeps: 0)
        #expect(same == .following(dy: -5.0, v: v, at: 75.0))
    }

    @Test("content_slide::a_growth_that_stops_opening_toward_it_hands_its_speed_to_a_spring")
    func growthStoppingHandsSpeedToSpring() {
        let phase = SlidePhase.following(dy: -10.0, v: 300.0, at: 50.0)
        let next = phase.step(growth: Self.growth(50.0, 20.0), spring: Growth.spring, substeps: 1)
        guard case let .settling(dy, v) = next else {
            Issue.record("expected settling phase, got \(next)")
            return
        }
        let (wantDy, wantV) = Growth.spring.sample(from: -10.0, velocity: 300.0, target: 0.0, at: Growth.substep)
        #expect(abs(dy - wantDy) < 1e-4 && abs(v - wantV) < 1e-4)
        let again = next.step(growth: Self.growth(0.0, 100.0), spring: Growth.spring, substeps: 1)
        if case .settling = again {} else {
            Issue.record("expected settling phase to persist, got \(again)")
        }
    }

    @Test("content_slide::a_slide_ends_at_its_layout_and_a_spring_once_it_also_stops")
    func slideEndsAtLayout() {
        #expect(!SlidePhase.following(dy: 0.001, v: 900.0, at: 10.0).isLive)
        #expect(SlidePhase.settling(dy: 0.001, v: 900.0).isLive)
        #expect(!SlidePhase.settling(dy: 0.001, v: 0.1).isLive)
        var phase = SlidePhase.settling(dy: -40.0, v: 0.0)
        var frames = 0
        while phase.isLive {
            phase = phase.step(growth: Self.growth(0.0, 0.0), spring: Growth.spring, substeps: 2)
            frames += 1
            #expect(frames < 240, "springs home within 2s: \(phase)")
        }
    }

    @Test("landing_hold & fold_hold helpers track animated width changes and fold give/restore")
    func landingHoldAndFoldHold() throws {
        struct PanelDoc { var wide = false }
        let rt = Runtime<PanelDoc>(
            state: PanelDoc(wide: false),
            viewport: Vec2(400, 300),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col().w(s.wide ? 320 : 180).h(120).key("card").holdLandingWidth().child(
                text("Inner held subtree").key("inner").wFull()
            )
        }
        _ = rt.frame(at: 0.0)
        let cardNode = try #require(rt.flatNodes.first { $0.key == "card" })
        let innerNode = try #require(rt.flatNodes.first { $0.key == "inner" })
        #expect(!rt.landingHolds.holds(cardNode.nodeId))
        #expect(!rt.landingHolds.holds(innerNode.nodeId))

        rt.update(at: 0.05) { s, _ in s.wide = true }
        _ = rt.frame(at: 0.05)
        #expect(rt.landingHolds.holds(cardNode.nodeId), "animated width change records landing hold")
        #expect(rt.landingHolds.holds(innerNode.nodeId), "landing hold covers full subtree")
        var heldMotion: [MotionElement] = []
        rt.motionElements(&heldMotion)
        let innerEl = heldMotion.first { $0.id == innerNode.nodeId }
        #expect(innerEl != nil && (innerEl!.flags & MotionElement.LIVE) != 0, "subtree inherits MotionElement.LIVE")

        rt.update(at: 0.10) { s, tx in
            s.wide = false
            tx.instant()
        }
        _ = rt.frame(at: 0.10)
        #expect(!rt.landingHolds.holds(cardNode.nodeId), "instant width cut clears landing hold")
        #expect(!rt.landingHolds.holds(innerNode.nodeId))
    }
}
