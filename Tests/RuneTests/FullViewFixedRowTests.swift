import Testing
@testable import Rune
import RuneMotion

@Suite("Fixed row geometry across view rebuilds")
struct FullViewFixedRowTests {
    private enum Change { case none, horizontal, rtl, fractional, live, duplicate, secure, growth, width }
    private struct Model {
        var token = 0
        var active = false
        var change: Change = .none
        var response: Int?
        var edit = TextEdit("secret")
    }
    private final class Context { var token = 0 }

    // With zero borders both modes have the same geometry. Border-box reservation
    // makes the control ineligible for compressed layout.
    private func make(_ ordinary: Bool) -> Runtime<Model> {
        let live = LiveText("fresh")
        return Runtime(state: Model(), viewport: Vec2(240, 120), pixelScale: 1.25) { model, _ in
            let rows = col().key("rows").wFull().minW(240).borderLayout(ordinary)
                .virtualRows(count: 700, estimatedRowHeight: 20, key: { _, i in "r-\(i)" },
                             buildContent: { (state: Model, i) in
                    let active = state.active, token = state.token
                    let duplicate = state.change == .duplicate
                    let height: Float = state.change == .fractional ? 20.5 : 20
                    return memoizedVirtualRow("r-\(i)", deps: [Int(height * 2), duplicate ? 1 : 0],
                        variant: active, variantsShareLayout: true,
                        makeContext: { let context = Context(); context.token = token; return context },
                        updateContext: { $0.token = token }) { context in
                            var label: El<Model> = text("line \(i)").size(72, height).key("label-\(i)")
                            if active { label = label.selectable() }
                            var content = row().wFull().h(height).label(active ? "active" : "inactive")
                                .role(.listItem).child(label)
                                .child(el().size(60, height).key("tap-\(i)").onClick { state in
                                    state.response = active ? context.token : -context.token
                                }).child(el().size(1, 1))
                            if duplicate {
                                content = content.child(el().key("dup").size(1, 1)).child(el().key("dup").size(1, 1))
                            }
                            return content
                        }
                })
            var frame: El<Model> = col().key("frame").wFull()
            switch model.change {
            case .horizontal: frame = row().key("frame").wFull()
            case .rtl: frame = frame.dir(.rtl)
            case .width: frame = frame.w(232)
            default: break
            }
            var root = col().sizeFull().scrollXY().key("scroll").child(frame.child(rows))
            switch model.change {
            case .live: root = root.child(liveText(live).size(40, 20).key("fresh-live"))
            case .secure: root = root.child(textInput(key: "private", \Model.edit).secure().size(80, 20))
            case .growth: root = root.child(col().growth().size(20, 20).key("growing"))
            default: break
            }
            return root
        }
    }

    @Test("Alternating layout-equivalent views publish current elements, selection and callbacks")
    func alternating() throws {
        let tested = make(false), control = make(true)
        let changes: [Change] = [.none, .none, .none, .none, .horizontal, .none, .rtl, .none,
            .fractional, .none, .none, .none, .none, .none, .live, .none, .none, .duplicate,
            .none, .secure, .none, .growth, .none, .width, .none]
        var admitted = 0
        for (step, change) in changes.enumerated() {
            let time = Double(step) / 30
            let calls = tested.viewCallCount
            for runtime in [tested, control] {
                if step == 8 { runtime.setViewport(Vec2(240, 135), pixelScale: 1.5) }
                runtime.update(at: time) { model, tx in
                    model.active = !step.isMultiple(of: 2)
                    model.token = step + 11
                    model.change = change
                    tx.instant()
                }
            }
            let actual = tested.renderFrame(at: time), expected = control.renderFrame(at: time)
            #expect(tested.viewCallCount > calls)
            #expect(tested.elements() == control.elements())
            #expect(tested.accessibilitySnapshot() == control.accessibilitySnapshot())
            #expect(actual.instances == expected.instances)
            #expect(tested.nodeTextLayouts.mapValues { $0.box.shapeKey } == control.nodeTextLayouts.mapValues { $0.box.shapeKey })
            let compressed = tested.retainedLayout.storageStats.liveNodes < control.retainedLayout.storageStats.liveNodes
            if compressed { admitted += 1 }
            if change != .none { #expect(!compressed) }
            let label = try #require(tested.flatNodes.first { $0.key == "label-0" })
            #expect(label.el.isSelectable == tested.state.active)
            let rect = try #require(tested.element(byKey: "tap-0")).rect
            let point = Vec2(rect[0] + 3, rect[1] + 3)
            for runtime in [tested, control] {
                runtime.pointerDown(at: point, at: time + 0.002)
                runtime.pointerUp(at: point, at: time + 0.003)
            }
            #expect(tested.state.response == control.state.response)
            #expect(tested.state.response == (tested.state.active ? step + 11 : -(step + 11)))
        }
        #expect(admitted > 2)
    }

    @Test("Row geometry dependencies are reevaluated across variant and width changes")
    func geometryReads() {
        final class Reads { var calls = [0, 0] }
        struct State { var width: Float = 12; var active = false }
        func make(_ ordinary: Bool, _ reads: Reads) -> Runtime<State> {
            Runtime(state: State(), viewport: Vec2(180, 100), pixelScale: 1.5) { state, cx in
                let geometry = cx
                let rows: El<State> = col().wFull().minW(180).key("rows").borderLayout(ordinary)
                    .virtualRows(count: 300, estimatedRowHeight: 20, key: { _, i in "row-\(i)" },
                                 buildContent: { model, i in
                        memoizedVirtualRow("row-\(i)", deps: 0, variant: model.active, variantsShareLayout: true,
                            makeContext: { Context() }, updateContext: { _ in }) { _ in
                                let width = geometry.layoutWith("reference") { rect in
                                    reads.calls[model.active ? 1 : 0] += 1
                                    return rect[2]
                                } ?? model.width
                                return row().wFull().h(20).child(el().size(width, 10).key("sized-\(i)"))
                            }
                    })
                return col().sizeFull().scrollY().child(el().key("reference").size(state.width, 1)).child(rows)
            }
        }

        let a = Reads(), b = Reads(), tested = make(false, a), control = make(true, b)
        let widths: [Float] = [12, 12, 12, 12, 24, 15, 23, 23, 15, 15]
        for (step, width) in widths.enumerated() {
            let time = Double(step) / 30
            for runtime in [tested, control] {
                runtime.update(at: time) { state, tx in
                    state.active = !step.isMultiple(of: 2)
                    state.width = width
                    tx.instant()
                }
                _ = runtime.renderFrame(at: time)
            }
            #expect(tested.elements() == control.elements())
            if step > 0 {
                #expect(tested.retainedLayout.storageStats.liveNodes == control.retainedLayout.storageStats.liveNodes)
            }
            // Invalidated dependency sets stop at their first change, in hash order.
            if step < 4 { #expect(a.calls == b.calls) }
            #expect(tested.element(byKey: "sized-0")?.rect[2] == width)
        }
    }
}
