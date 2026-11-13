import Foundation
import Testing
import Rune
@testable import RuneOneSnap

@Suite("Phase 3 OneSnap example", .serialized)
@MainActor
struct Phase3OneSnapTests {

    @Test("rune-one-snap: zooms stage from (0,0) origin and swaps Path disc <-> Icon disc on badge click")
    func stageZoomAndBadgeSwap() throws {
        let rt = Runtime<OneSnapState>(
            state: OneSnapState(),
            viewport: Vec2(360, 240),
            pixelScale: 2.0,
            systemDark: true,
            view: oneSnapView
        )
        rt.frame(at: 0.0)
        #expect(rt.element(byKey: "hud") != nil)
        #expect(rt.element(byKey: "title")?.text == "Path disc")
        let hudRect0 = try #require(rt.element(byKey: "hud")?.rect)
        let anchorRect0 = try #require(rt.element(byKey: "anchor")?.rect)
        #expect(hudRect0[1] > anchorRect0[1])

        let badgeRect = try #require(rt.element(byKey: "badge")?.rect)
        let badgeCenter = Vec2(badgeRect[0] + badgeRect[2] * 0.5, badgeRect[1] + badgeRect[3] * 0.5)
        rt.pointerMove(to: badgeCenter, at: 0.01)
        rt.pointerDown(at: badgeCenter, at: 0.02)
        rt.pointerUp(at: badgeCenter, at: 0.03)
        rt.frame(at: 0.04)

        #expect(rt.state.swapped == true)
        #expect(rt.element(byKey: "title")?.text == "Icon disc")

        let stageRect = try #require(rt.element(byKey: "stage")?.rect)
        // Click lower-right corner of stage (away from badge/hud)
        let stageTap = Vec2(stageRect[0] + stageRect[2] - 12.0, stageRect[1] + stageRect[3] - 12.0)
        rt.pointerMove(to: stageTap, at: 0.05)
        rt.pointerDown(at: stageTap, at: 0.06)
        rt.pointerUp(at: stageTap, at: 0.07)
        rt.frame(at: 0.30)

        #expect(rt.state.zoomed == true)
    }
}
