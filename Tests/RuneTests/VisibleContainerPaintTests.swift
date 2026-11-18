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
            #expect(row.paintTraits.contains(.plainBox))
            if i == 0 {
                #expect(a.marks.contains(77))
                #expect(projected.hitTestElement(at: points[0])?.key == "ink")
            }
        }
    }

    @Test func restingSolidBoxesMatchMaterialPaintThroughRoundedClipsAndStickyScroll() {
        func make(_ project: Bool) -> Runtime<Void> {
            Runtime(state: (), viewport: Vec2(100, 64), pixelScale: 1.5) { _, _ in
                func sample(_ box: El<Void>) -> El<Void> {
                    var box = box
                    if !project { box.runtimeExtras["test.fullPaintHeader"] = true }
                    return box
                }
                let child = sample(el().key("child").pin(top: -4.5, left: 2.25).size(19.5, 12)
                    .bg(.srgb(1, 0.5, 1, 0.6)).rounded(3).mark(19).hit())
                let sticky = sample(el().key("sticky").size(38.5, 22.5).stickyLeft(0)
                    .bg(.srgb(0.1, 0.4, 0.8)).rounded(4).mark(25).child(child))
                let clear = sample(el().key("clear").size(12, 18).hit())
                let line = sample(row().key("line").size(220, 28).bg(.black)
                    .hover(.srgb(0.2, 0.8, 1)).hoverGroup().children([sticky, clear]))
                let content = col().size(220, 160).pt(8.5).child(line)
                return col().sizeFull().key("scroll").scrollXY().clipRounded(tl: 9, tr: 4, br: 12, bl: 6).child(content)
            }
        }
        for srgb in [false, true] {
            let projected = make(true), full = make(false)
            let hosts = [projected, full]
            for host in hosts { host.setSrgbBlend(srgb) }
            let points = [Vec2(4, 13), Vec2(15, 14), Vec2(48, 20), Vec2(95, 60)]
            for i in 0..<6 {
                let t = Double(i) / 60
                for host in hosts {
                    if i == 1 { host.pointerMove(to: points[1], at: t) }
                    if i == 2 { host.update(at: t) { _, tx in tx.scrollToInstant("scroll", x: 25.5, y: 3.25) } }
                    if i == 3 { host.pointerMove(to: points[3], at: t) }
                    if i == 4 { host.update(at: t) { _, tx in tx.scrollToInstant("scroll", x: 4.25, y: 43) } }
                    if i == 5 { host.update(at: t) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 0) } }
                }
                let a = projected.renderFrame(at: t), b = full.renderFrame(at: t)
                #expect(a.instances == b.instances)
                #expect(a.marks == b.marks)
                #expect(projected.elements() == full.elements())
                #expect(projected.accessibilitySnapshot() == full.accessibilitySnapshot())
                for p in points { #expect(projected.hitTestElement(at: p) == full.hitTestElement(at: p)) }
                if i == 0 {
                    #expect(a.marks.contains(19) && a.marks.contains(25))
                }
            }
        }
    }
}
