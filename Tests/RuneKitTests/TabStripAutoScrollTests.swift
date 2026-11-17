import Testing
import Rune
import RuneKit

@Suite("Tab strip drag edge scrolling")
struct TabStripAutoScrollTests {
    struct State {
        var drag = TabDragState()
        var drops: [TabReorder] = []
    }

    @Test("A held drag scrolls both axes at the upstream cadence and drops the final slot once",
          arguments: [TabOrientation.horizontal, .vertical])
    func heldDrag(_ orientation: TabOrientation) throws {
        let vertical = orientation == .vertical
        let kit = Kit.neutral(dark: false)
        let runtime = Runtime(state: State(), viewport: Vec2(240, 156)) { state, _ in
            TabStrip<State>(key: "strip", orientation: orientation)
                .tabs((0..<24).map { StripTabItem(id: String($0), title: "Tab \($0)") })
                .active("0")
                .overflow(.shrinkThenScroll(minWidth: 48, maxWidth: 48))
                .availableWidth(240)
                .dragState(\.drag, current: state.drag)
                .onReorder { state, drop, _ in state.drops.append(drop) }
                .build(state, kit: kit)
        }
        func offset() -> Float {
            let at = runtime.scrollOffset(forKey: "strip-scroll")
            return vertical ? at.y : at.x
        }
        func dragOffset() -> Float? {
            guard case let .dragging(_, _, _, delta) = runtime.state.drag.phase else { return nil }
            return delta
        }

        runtime.frame(at: 0)
        runtime.update(at: 0.02) { _, tx in
            tx.scrollToInstant("strip-scroll", x: vertical ? 0 : 40, y: vertical ? 40 : 0)
        }
        runtime.frame(at: 0.02)
        #expect(abs(offset() - 40) < 0.001)

        let viewport = try #require(runtime.element(byKey: "strip-scroll")).rect
        let tab = try #require(runtime.element(byKey: "strip-tab-2")).rect
        let start = Vec2(tab[0] + tab[2] / 2, tab[1] + tab[3] / 2)
        let edge = vertical ? Vec2(start.x, viewport[1] + viewport[3]) : Vec2(viewport[0] + viewport[2], start.y)
        let travel = vertical ? edge.y - start.y : edge.x - start.x
        runtime.pointerDown(at: start, at: 0.03)
        runtime.pointerMove(to: vertical ? Vec2(start.x, start.y + 6) : Vec2(start.x + 6, start.y), at: 0.04)
        #expect(runtime.state.drag.isDragging)
        runtime.pointerMove(to: edge, at: 0.05)
        runtime.frame(at: 0.05)
        #expect(abs(offset() - 48) < 0.001)
        #expect(abs(try #require(dragOffset()) - (travel + 8)) < 0.001)
        let lifted = try #require(runtime.element(byKey: "strip-tab-2")).rect

        runtime.frame(at: 0.066)
        #expect(abs(offset() - 48) < 0.001)
        runtime.frame(at: 0.067)
        #expect(abs(offset() - 56) < 0.001)
        runtime.frame(at: 0.084)
        #expect(abs(offset() - 64) < 0.001)
        #expect(abs(try #require(dragOffset()) - (travel + 24)) < 0.001)
        let held = try #require(runtime.element(byKey: "strip-tab-2")).rect
        let axis = vertical ? 1 : 0
        #expect(abs(held[axis] - lifted[axis]) < 0.5)
        #expect(runtime.state.drops.isEmpty)

        // An already-armed repeat samples the latest pointer when it fires.
        let center = Vec2(viewport[0] + viewport[2] / 2, viewport[1] + viewport[3] / 2)
        runtime.pointerMove(to: center, at: 0.088)
        runtime.frame(at: 0.102)
        #expect(abs(offset() - 64) < 0.001)

        let outside = vertical ? Vec2(viewport[0] - 11, edge.y) : Vec2(edge.x, viewport[1] - 11)
        runtime.pointerMove(to: outside, at: 0.105)
        runtime.frame(at: 0.125)
        #expect(abs(offset() - 64) < 0.001)

        runtime.pointerMove(to: edge, at: 0.13)
        runtime.frame(at: 0.13)
        #expect(abs(offset() - 72) < 0.001)
        guard case let .dragging(_, from, to, _) = runtime.state.drag.phase else {
            Issue.record("Expected the lifted tab to have a drop target")
            return
        }
        #expect(to > from)
        runtime.pointerUp(at: edge, at: 0.132)
        runtime.frame(at: 0.155)
        #expect(runtime.state.drops == [TabReorder(from: from, to: to)])
        #expect(abs(offset() - 72) < 0.001)

        let nextTab = try #require(runtime.element(byKey: "strip-tab-4")).rect
        let nextStart = Vec2(nextTab[0] + nextTab[2] / 2, nextTab[1] + nextTab[3] / 2)
        let leading = vertical ? Vec2(nextStart.x, viewport[1]) : Vec2(viewport[0], nextStart.y)
        runtime.pointerDown(at: nextStart, at: 0.17)
        runtime.pointerMove(to: center, at: 0.18)
        runtime.pointerMove(to: leading, at: 0.19)
        runtime.frame(at: 0.19)
        #expect(abs(offset() - 64) < 0.001)
        runtime.windowFocus(false, at: 0.20)
        runtime.frame(at: 0.23)
        #expect(runtime.state.drops.count == 1)
        #expect(!runtime.state.drag.isDragging)
        #expect(abs(offset() - 64) < 0.001)
    }

    @Test("The activation band occupies 5% of the strip and the step clamps at either limit")
    func edgeDistance() {
        func step(_ at: Float, offset: Float = 30) -> Float {
            TabAutoScroll.step(pointerAlong: at, viewportStart: 50, viewportEnd: 150,
                               scrollOffset: offset, maxScroll: 60, dt: 1 / 60)
        }
        #expect(step(55) == 30)
        #expect(step(52.5) == 26)
        #expect(step(50) == 22)
        #expect(step(145) == 30)
        #expect(step(147.5) == 34)
        #expect(step(150) == 38)
        #expect(step(160) == 54)
        #expect(step(150, offset: 59) == 60)
        #expect(step(40, offset: 5) == 0)
        let farFromOrigin = TabAutoScroll.step(pointerAlong: 1_000_255, viewportStart: 1_000_000,
            viewportEnd: 1_000_256, scrollOffset: 0, maxScroll: 60, dt: 1 / 60)
        #expect(abs(farFromOrigin - 7.375) < 0.00001)
    }
}
