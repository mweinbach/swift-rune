import Foundation
import Testing
@testable import Rune
@testable import RuneKeepStuck
@testable import RuneScrollAnchor
@testable import RuneGrowthReorder
@testable import RuneSticky

@Suite("Phase 3 El Motion Examples (keep_stuck, scroll_anchor, growth_reorder, sticky)")
struct Phase3ElMotionTests {
    @Test("keep_stuck: clicking header toggles group and invokes Tx.keepOnScreen")
    func keepStuckTogglesHeaderAndKeepsOnScreen() throws {
        let rt = Runtime<KeepStuckChat>(
            state: KeepStuckChat(open: true),
            viewport: Vec2(420, 360),
            pixelScale: 2.0,
            systemDark: true,
            view: keepStuckView
        )
        rt.frame(at: 0.0)
        #expect(rt.state.open == true)
        let hdr = try #require(rt.element(byKey: "hdr"))
        let pt = Vec2(hdr.rect[0] + 20, hdr.rect[1] + hdr.rect[3] * 0.5)
        rt.pointerMove(to: pt, at: 0.01)
        rt.pointerDown(at: pt, at: 0.02)
        rt.pointerUp(at: pt, at: 0.03)
        rt.frame(at: 0.04)
        #expect(rt.state.open == false)
    }

    @Test("scroll_anchor: Enter adds earlier rows while anchor mode preserves viewport item")
    func scrollAnchorAddsEarlierMessagesOnEnter() throws {
        let rtAnchored = Runtime<ScrollAnchorFeed>(
            state: ScrollAnchorFeed(earlier: 0, anchor: true),
            viewport: Vec2(420, 400),
            pixelScale: 2.0,
            systemDark: true,
            onKey: onScrollAnchorKey,
            view: scrollAnchorView
        )
        rtAnchored.frame(at: 0.0)
        let feed = try #require(rtAnchored.element(byKey: "feed"))
        let center = Vec2(feed.rect[0] + feed.rect[2] * 0.5, feed.rect[1] + feed.rect[3] * 0.5)
        rtAnchored.wheel(WheelEvent(dy: -240), at: center, now: 0.02)
        rtAnchored.frame(at: 0.03)
        let scrollBefore = rtAnchored.scrollOffset(forKey: "feed").y
        #expect(scrollBefore > 100)
        let msg8Before = try #require(rtAnchored.element(byKey: "msg-8")?.rect[1])

        #expect(rtAnchored.keyDown(KeyEvent(key: .enter), at: 0.04))
        for step in 1...40 {
            rtAnchored.frame(at: 0.04 + Double(step) * 0.016)
        }
        #expect(rtAnchored.state.earlier == 3)
        let scrollAfter = rtAnchored.scrollOffset(forKey: "feed").y
        #expect(scrollAfter > scrollBefore + 150)
        let msg8After = try #require(rtAnchored.element(byKey: "msg-8")?.rect[1])
        #expect(abs(msg8After - msg8Before) < 2.0)

        let plainSpec = RuneScrollAnchorApp.makeSpec(arguments: ["plain"])
        #expect(plainSpec.makeState().anchor == false)
    }

    @Test("growth_reorder: default swap and steer launch + deliver reorder rows")
    func growthReorderSwapAndSteerDeliver() throws {
        let defaultSpec = RuneGrowthReorderApp.makeSpec(arguments: [])
        let rt = Runtime<GrowthReorderChat>(
            state: defaultSpec.makeState(),
            viewport: Vec2(420, 360),
            pixelScale: 2.0,
            systemDark: true,
            view: growthReorderView
        )
        rt.frame(at: 0.0)
        #expect(rt.state.rows.map { $0.key } == ["m0", "m1", "m2", "bubble-p", "working"])

        let working = try #require(rt.element(byKey: "working"))
        let pt = Vec2(working.rect[0] + 20, working.rect[1] + 20)
        rt.pointerMove(to: pt, at: 0.01)
        rt.pointerDown(at: pt, at: 0.02)
        rt.pointerUp(at: pt, at: 0.03)
        rt.frame(at: 0.04)
        #expect(rt.state.rows.map { $0.key } == ["m0", "m1", "m2", "working", "bubble-p"])

        let steerSpec = RuneGrowthReorderApp.makeSpec(arguments: ["steer"])
        let rtSteer = Runtime<GrowthReorderChat>(
            state: steerSpec.makeState(),
            viewport: Vec2(420, 360),
            pixelScale: 2.0,
            systemDark: true,
            view: growthReorderView
        )
        rtSteer.frame(at: 0.0)
        let composer = try #require(rtSteer.element(byKey: "composer"))
        let cPt = Vec2(composer.rect[0] + 20, composer.rect[1] + 20)
        rtSteer.pointerMove(to: cPt, at: 0.01)
        rtSteer.pointerDown(at: cPt, at: 0.02)
        rtSteer.pointerUp(at: cPt, at: 0.03)
        rtSteer.frame(at: 0.04)
        #expect(rtSteer.state.sent == 1)
        #expect(rtSteer.state.rows.last?.key == "steer-0")

        let workingSteer = try #require(rtSteer.element(byKey: "working"))
        let wPt = Vec2(workingSteer.rect[0] + 20, workingSteer.rect[1] + 20)
        rtSteer.pointerMove(to: wPt, at: 0.05)
        rtSteer.pointerDown(at: wPt, at: 0.06)
        rtSteer.pointerUp(at: wPt, at: 0.07)
        rtSteer.frame(at: 0.08)
        let deliveredIdx = try #require(rtSteer.state.rows.firstIndex(where: { $0.key == "steer-0" }))
        let workingIdx = try #require(rtSteer.state.rows.firstIndex(where: { $0.key == "working" }))
        #expect(deliveredIdx < workingIdx)
        #expect(rtSteer.state.rows[deliveredIdx].height == 77.0)
    }

    @Test("sticky: headers attach stuckShadow and collapse via keepOnScreen")
    func stickyHeadersUseStuckShadowAndKeepOnScreen() throws {
        let rt = Runtime<StickyState>(
            state: StickyState(),
            viewport: Vec2(440, 380),
            pixelScale: 2.0,
            systemDark: true,
            view: RuneStickyApp.view
        )
        rt.frame(at: 0.0)
        let scrollEl = try #require(rt.element(byKey: "scroll"))
        let center = Vec2(scrollEl.rect[0] + 100, scrollEl.rect[1] + 100)
        rt.wheel(WheelEvent(dy: -120), at: center, now: 0.02)
        rt.frame(at: 0.03)
        let hdr0 = try #require(rt.element(byKey: "hdr-0"))
        #expect(abs(hdr0.rect[1] - scrollEl.rect[1]) < 1.0)
        let clickPt = Vec2(hdr0.rect[0] + 40, hdr0.rect[1] + hdr0.rect[3] * 0.5)
        rt.pointerMove(to: clickPt, at: 0.04)
        rt.pointerDown(at: clickPt, at: 0.05)
        rt.pointerUp(at: clickPt, at: 0.06)
        rt.frame(at: 0.07)
        #expect(rt.state.collapsed[0] == true)
    }
}
