import RuneMotion
import Testing
@testable import Rune

@Suite struct VisibleContainerPaintTests {
    struct State { var filled = false; var hovered = false }

    func runtime(project: Bool) -> Runtime<State> {
        Runtime(state: State(), viewport: Vec2(120, 84), pixelScale: 1.5) { state, _ in
            let ink: El<State> = el().key("ink").pin(top: -6, left: 1.25).size(16, 14)
                .bg(.white).hit().mark(77).label("badge")
            let label: El<State> = text("flow").key("label").pin(top: 11, left: 4).groupOpacity(0.2, 1)
            var row: El<State> = el().key("wrapper").pin(top: 28.5, left: 10.25).size(85, 22)
                .onHoverChange { s, inside, _ in s.hovered = inside }.mark(17).children([ink, label])
            if !project { row.runtimeExtras["test.fullPaintHeader"] = true }
            if state.filled { row = row.bg(.srgb(0.8, 0.1, 0.2)) }
            let group: El<State> = el().key("parent").size(120, 260).hoverGroup().child(row)
            return col().sizeFull().scrollY().key("scroll").child(group)
        }
    }

    @Test func visibleWrapperPreservesOverflowHitsHoverAndPaintAcrossStyleChanges() throws {
        let projected = runtime(project: true), full = runtime(project: false)
        let runtimes = [projected, full]
        let points = [Vec2(14, 25), Vec2(35, 41), Vec2(110, 74)]
        for i in 0..<10 {
            let now = Double(i) / 60
            for rt in runtimes {
                if i == 2 { rt.pointerMove(to: points[0], at: now) }
                if i == 3 { rt.pointerMove(to: points[1], at: now) }
                if i == 4 { rt.pointerMove(to: points[2], at: now) }
                if i == 5 { rt.update(at: now) { s, tx in s.filled = true; tx.instant() } }
                if i == 6 { rt.update(at: now) { s, tx in s.filled = false; tx.instant() } }
                if i == 7 { rt.update(at: now) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 12.5) } }
            }
            let a = projected.renderFrame(at: now), b = full.renderFrame(at: now)
            #expect(a.instances == b.instances)
            #expect(a.marks == b.marks)
            #expect(projected.elements() == full.elements())
            #expect(projected.accessibilitySnapshot() == full.accessibilitySnapshot())
            #expect(projected.state.hovered == full.state.hovered)
            for point in points { #expect(projected.hitTestElement(at: point) == full.hitTestElement(at: point)) }
            if i == 3 { #expect(projected.state.hovered) }
            if i == 4 { #expect(!projected.state.hovered) }
            let row = try #require(projected.flatNodes.first { $0.key == "wrapper" })
            #expect(row.paintTraits.contains(.layoutContainer) == !projected.state.filled)
            if i == 0 {
                #expect(a.marks.contains(77))
                #expect(projected.hitTestElement(at: points[0])?.key == "ink")
            }
        }
    }
}
