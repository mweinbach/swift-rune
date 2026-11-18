import RuneMotion
import Testing
@testable import Rune

@Suite("Returning virtual row inputs")
struct ReturningVariantScopeTests {
    final class Actions: @unchecked Sendable {
        var latest: Int
        init(_ latest: Int) { self.latest = latest }
    }
    final class Visits {
        var counts: [Int: Int] = [:]
    }
    struct Model {
        var active = false
        var epoch = 0
        var capture = 0
        var tapped = ""
    }
    @Test("Returning to a visited variant uses the current callbacks and preserves mounted outputs")
    func returning() throws {
        func build(_ share: Bool, _ visits: Visits) -> Runtime<Model> {
            Runtime(state: Model(), viewport: Vec2(250, 120), pixelScale: 1) { model, _ in
                let capture = model.capture
                let rows: El<Model> = col().key("rows").wFull().virtualRows(count: 600, estimatedRowHeight: 20,
                    key: { _, i in "r-\(i)" }, buildContent: { state, i in
                        let active = state.active, epoch = state.epoch
                        return memoizedVirtualRow("r-\(i)", deps: epoch, variant: active, variantsShareLayout: share,
                            makeContext: {
                                visits.counts[i, default: 0] += 1
                                return Actions(capture)
                            }, updateContext: { $0.latest = capture }) { actions in
                                var label: El<Model> = text("line \(i)-\(epoch)").key("text-\(i)").w(100).h(20)
                                if active { label = label.selectable() }
                                return row().wFull().h(20).label(active ? "after" : "before")
                                    .bg(epoch.isMultiple(of: 2) ? .black : .white)
                                    .child(label)
                                    .child(el().key("action-\(i)").size(120, 20).focusable()
                                        .onClick { $0.tapped = "\(i)-\(active)-\(epoch)-\(actions.latest)" })
                        }
                    })
                return col().key("scroll").wFull().hFull().scrollY().child(rows)
            }
        }
        let left = Visits(), right = Visits()
        let shared = build(true, left), independent = build(false, right)
        var extra = 0
        var now = 0.0
        var countBeforeEviction = 0
        for step in 0..<23 {
            let visible = step < 14 || step >= 18
            if step == 14 { countBeforeEviction = left.counts[1] ?? 0 }
            let active = step.isMultiple(of: 2)
            for rt in [shared, independent] {
                if step == 8 { rt.setViewport(Vec2(430, 156), pixelScale: 1.5) }
                if step == 11 { rt.setViewport(Vec2(270, 100), pixelScale: 2) }
                rt.update(at: now) { state, tx in
                    state.active = active
                    state.capture = step
                    if step == 6 || step == 20 { state.epoch += 1 }
                    if step == 14 { tx.scrollTo("scroll", offset: Vec2(0, 6000), animated: false) }
                    if step == 18 { tx.scrollTo("scroll", offset: .zero, animated: false) }
                    if step == 3 { tx.focus("action-1", focusVisible: true) }
                    tx.instant()
                }
            }
            let a = shared.renderFrame(at: now), b = independent.renderFrame(at: now)
            #expect(a.instances.map(\.rect) == b.instances.map(\.rect))
            #expect(a.instances.map(\.fill) == b.instances.map(\.fill))
            #expect(shared.lastCommittedSpecs == independent.lastCommittedSpecs)
            #expect(shared.elements() == independent.elements())
            #expect(shared.accessibilitySnapshot() == independent.accessibilitySnapshot())
            extra += shared.replayedVirtualFlatRoots - independent.replayedVirtualFlatRoots
            if visible, let button = shared.element(byKey: "action-1"), button.visible[3] > 0 {
                let p = Vec2(button.rect[0] + 10, button.rect[1] + 10)
                for rt in [shared, independent] {
                    rt.pointerDown(at: p, at: now)
                    rt.pointerUp(at: p, at: now + 0.001)
                    #expect(rt.state.tapped == "1-\(active)-\(rt.state.epoch)-\(step)")
                }
            }
            if step == 16 { #expect(shared.element(byKey: "action-1") == nil) }
            now += 1.0 / 30
        }
        #expect((left.counts[1] ?? 0) > countBeforeEviction)
        #expect(left.counts == right.counts)
        #expect(extra > 0)
    }
}
