import Testing
@testable import Rune
import RuneMotion

@Suite("Flattened memo subtrees")
struct MemoFlatSpanTests {
    private struct Model {
        var tick = 0
        var prefix = false
        var inert = false
        var version = 0
        var taps = 0
    }

    private func make(_ reuse: Bool) -> Runtime<Model> {
        Runtime(state: Model(), viewport: Vec2(200, 90), pixelScale: 1, systemDark: true) { state, _ in
            func content() -> El<Model> {
                var stack: El<Model> = col().key("panel").clip(true)
                for i in 0..<10 {
                    let amount = state.version + 1
                    stack = stack.child(row().key("row-\(i)").size(120, 18).clip(true)
                        .child(text("row \(i)").key("label").size(36, 16))
                        .child(el().key("button").size(30, 16).onClick { $0.taps += amount }))
                }
                return stack
            }
            let panel = reuse ? memo("panel", deps: state.version) { content() } : content()
            var scrolled: El<Model> = col().key("list").scrollY().size(130, 65)
            if state.prefix { scrolled = scrolled.child(el().key("prefix").h(13)) }
            scrolled = scrolled.child(panel.inert(state.inert))
            return col().child(scrolled).child(el().key("banner").size(10, 9).bg(state.tick.isMultiple(of: 2) ? .white : .black))
        }
    }

    @Test("A retained subtree keeps current clip bounds, indices, handler values and pressed targets")
    func comparesToFreshDuringScrollAndUpdates() {
        let retained = make(true), fresh = make(false)
        var replayed = 0
        for step in 0..<12 {
            let t = Double(step + 1) / 60
            for rt in [retained, fresh] {
                rt.update(at: t) { s, tx in
                    s.tick += 1
                    if step == 4 { s.prefix = true }
                    if step == 5 { tx.scrollTo("list", offset: Vec2(0, 35), animated: false) }
                    if step == 7 { s.version += 1 }
                    if step == 9 { s.inert = true }
                }
                _ = rt.frame(at: t)
            }
            #expect(retained.elements() == fresh.elements())
            replayed = max(replayed, retained.replayedFlatMemoNodes)
            if step == 6 || step == 8 || step == 10 {
                for rt in [retained, fresh] {
                    rt.pointerDown(at: Vec2(46, 26), at: t)
                    rt.pointerUp(at: Vec2(46, 26), at: t)
                }
                #expect(retained.state.taps == fresh.state.taps)
            }
        }
        #expect(replayed == 30)
        #expect(retained.state.taps == 3)
    }

    @Test("Reordered memo descendants retain observer identities and honor the current modal")
    func observerRolesFollowMovedRows() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(160, 80), pixelScale: 1) { tick, _ in
            let left = memo("left-panel", deps: 0) { () -> El<Int> in
                row().child(el().key("watch-layout").size(12, 9).onLayout { _, _ in })
            }
            let replaced = tick >= 7
            let right = memo("right-panel", deps: replaced) { () -> El<Int> in
                let child: El<Int> = el().key("watch-selection").size(12, 9)
                return row().child(replaced
                    ? child.onLayout { _, _ in }
                    : child.onVisible { _, _, _ in }.onSelectionChange { _, _, _ in })
            }
            var body: El<Int> = col()
            if tick < 4 { body = body.child(left).child(right) }
            else { body = body.child(right).child(left) }
            if tick == 5 { body = body.child(el().key("modal").size(12, 9).modal()) }
            return body
        }
        for tick in 0..<9 {
            let time = Double(tick + 1) / 60
            rt.update(at: time) { state, _ in state = tick }
            _ = rt.frame(at: time)
            func keys(_ indices: [Int]) -> [String] { indices.compactMap { rt.flatNodes[$0].key } }
            let visible = tick < 7 ? ["watch-selection"] : []
            let layout = tick < 7 ? ["watch-layout"] : ["watch-selection", "watch-layout"]
            #expect(keys(rt.layoutObservers.laidOut) == layout)
            #expect(keys(rt.layoutObservers.visible) == visible)
            #expect(keys(rt.layoutObservers.selectionChanges) == (tick == 5 ? [] : visible))
            if (4...6).contains(tick) { #expect(rt.replayedFlatMemoNodes == 2) }
        }
    }

    @Test("Changing a memo root to screen travel reparents its descendants in the motion scene")
    func changedRootSceneIdentity() {
        func runtime(_ cached: Bool) -> Runtime<Int> {
            Runtime(state: 0, viewport: Vec2(160, 80), pixelScale: 1, systemDark: true) { tick, _ in
                func body() -> El<Int> { row().key("panel").child(el().key("child").size(12, 9)) }
                var panel = cached ? memo("panel", deps: 0) { body() } : body()
                if tick >= 4 { panel = panel.animateLayout(LayoutAnim(spring: MotionTokens.DEFAULT, travel: .screen)) }
                return row().child(el().w(19)).child(panel)
            }
        }
        let retained = runtime(true), fresh = runtime(false)
        for step in 0..<7 {
            let t = Double(step + 1) / 60
            for rt in [retained, fresh] {
                rt.update(at: t) { s, _ in s = step }
                _ = rt.frame(at: t)
            }
            #expect(retained.elements() == fresh.elements())
            if step == 3 { #expect(retained.replayedFlatMemoNodes == 1) }
            if step == 4 { #expect(retained.replayedFlatMemoNodes == 0) }
        }
    }

    @Test("A replayed sticky gutter places overlays against its child after scrolling")
    func stickyDescendantAnchor() throws {
        func runtime(retained: Bool) -> Runtime<Int> {
            Runtime(state: 0, viewport: Vec2(240, 120), pixelScale: 1, systemDark: true) { _, _ in
                func content() -> El<Int> {
                    row().key("content").size(800, 40).shrink(0)
                        .child(row().key("gutter").size(90, 40).stickyLeft(8)
                            .child(el().key("trigger").size(30, 18)))
                }
                let contentRow = retained ? memo("content", deps: 0) { content() } : content()
                return col().size(240, 120)
                    .child(col().key("scroll").size(240, 60).scrollX().child(contentRow))
                    .child(el().key("popup").size(40, 20).anchored("trigger", side: .bottom, align: .start, gap: 2))
            }
        }
        let retained = runtime(retained: true), fresh = runtime(retained: false)
        for (step, offset) in [0, 0, 80, 80, 210, 210].enumerated() {
            let now = Double(step + 1) / 30
            for rt in [retained, fresh] {
                rt.update(at: now) { state, tx in
                    state += 1
                    tx.scrollToInstant("scroll", x: Float(offset), y: 0)
                }
                _ = rt.renderFrame(at: now)
            }
            #expect(retained.elements() == fresh.elements())
            if step == 3 || step == 5 {
                #expect(retained.replayedFlatMemoNodes == 2)
                let gutter = try #require(retained.element(byKey: "gutter"))
                let popup = try #require(retained.element(byKey: "popup")?.committedLayoutTarget)
                #expect(gutter.stuck == Float(offset) + 8)
                #expect(popup.x == 8)
            }
        }
    }
}
