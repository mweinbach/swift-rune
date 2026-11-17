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
}
