import Testing
@testable import Rune
import RuneMotion

@Suite("Landing width anchor")
struct LandingHoldParityTests {
    @Test("A width change holds the child whose subtree was visible before reflow",
          arguments: [false, true], [false, true])
    func visibleChildStaysPut(native: Bool, nested: Bool) throws {
        let runtime = Runtime<Bool>(state: false, viewport: Vec2(280, 90), pixelScale: 1) { narrow, _ in
            let hidden: El<Bool> = el().key("offscreen").size(20, 16)
                .absolute(x: 0, y: -200).bg(.white)
            let visible: El<Bool> = el().key("visible").size(20, 16).bg(.white)
            let anchor = nested
                ? col().key("anchor").size(20, 16).alignSelf(.end).offset(0, 200)
                    .child(visible.absolute(x: 0, y: -200))
                : visible.alignSelf(.end)
            return col().size(280, 90).clip().itemsStart().child(
                col().key("column").size(narrow ? 140 : 260, 80).holdLandingWidth()
                    .animateLayout(Spring(duration: 0.6, bounce: 0))
                    .child(hidden).child(anchor)
            )
        }
        func draw(_ time: Double) {
            if native { _ = runtime.renderFrame(at: time) }
            else { _ = runtime.frame(at: time) }
        }
        draw(0)
        let before = try #require(runtime.element(byKey: "visible"))
        #expect(before.visible[2] == 20)
        let hidden = try #require(runtime.element(byKey: "offscreen"))
        #expect(hidden.visible[3] == 0)
        if nested {
            let anchor = try #require(runtime.element(byKey: "anchor"))
            #expect(anchor.visible[3] == 0)
        }

        runtime.update(at: 0.05) { narrow, _ in narrow = true }
        draw(0.05)
        let held = try #require(runtime.element(byKey: "visible"))
        #expect(abs(held.rect[0] - before.rect[0]) < 1)
        draw(2)
        let settled = try #require(runtime.element(byKey: "visible"))
        #expect(abs(settled.rect[0] - (before.rect[0] - 120)) < 1)
    }
}
