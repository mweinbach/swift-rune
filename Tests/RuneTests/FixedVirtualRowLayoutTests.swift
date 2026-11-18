import Testing
@testable import Rune
import RuneMotion

@Suite("Fixed virtual row layout")
struct FixedVirtualRowLayoutTests {
    @Test("Fixed rows keep individual layout, text, selection and scroll extents across a changing window")
    func restoresSurvivingRows() {
        func make(_ ordinarySolve: Bool) -> Runtime<Int> {
            Runtime(state: 0, viewport: Vec2(240, 120), pixelScale: 1.25) { _, _ in
                let list: El<Int> = col().wFull().minW(240).borderLayout(ordinarySolve).key("rows")
                    .virtualRows(count: 600, estimatedRowHeight: 20, key: { _, i in "row-\(i)" }) { state, i in
                        let height = Float(18 + i % 4)
                        let label = i % 13 == 1 ? "A long line wrapping at a fixed width" : "text \(i) \(state)"
                        var content: El<Int> = col().wFull().h(height).key("content").child(
                            text(label).w(90).h(16).wrapText().selectable().key("label")
                        ).child(el().size(4, 1)).child(el().size(6, 1))
                        if i % 11 == 0 {
                            content = content.child(el().size(280, 2).absolute(x: 7, y: 1).key("overflow"))
                        }
                        var shell = col().wFull().role(.listItem).label("item \(i)").selectionGroup().child(content)
                        if !i.isMultiple(of: 7) { shell = shell.h(height) }
                        if i % 19 == 3 { shell.layout.pinTop = 3 }
                        return shell
                    }
                return col().sizeFull().scrollXY().key("scroll").child(list)
            }
        }

        let reused = make(false)
        // With zero border thickness the border-box reservation has the same geometry.
        let ordinary = make(true)
        var usedFewerSlots = false
        for frame in 0...28 {
            let now = Double(frame) / 60
            func advance(_ runtime: Runtime<Int>) -> RenderFrame {
                if frame == 0 {
                    _ = runtime.renderFrame(at: now)
                    runtime.pointerDown(at: Vec2(2, 8), at: now)
                    runtime.pointerMove(to: Vec2(60, 8), at: now)
                }
                if frame == 2 { runtime.pointerUp(at: Vec2(60, 8), at: now) }
                if frame == 9 { runtime.setViewport(Vec2(230, 140), pixelScale: 1.5) }
                if frame == 12 { runtime.setViewport(Vec2(240, 120), pixelScale: 1.25) }
                if frame == 16 { runtime.update(at: now) { value, tx in value += 1; tx.instant() } }
                if frame > 0 {
                    let dy: Float = frame == 18 ? -2_000 : frame.isMultiple(of: 4) ? 40 : -65
                    runtime.wheel(WheelEvent(dx: frame.isMultiple(of: 5) ? -4 : 0, dy: dy), at: Vec2(100, 50), now: now)
                }
                return runtime.renderFrame(at: now)
            }
            let scene = advance(reused), control = advance(ordinary)
            #expect(reused.elements() == ordinary.elements())
            #expect(reused.accessibilitySnapshot() == ordinary.accessibilitySnapshot())
            #expect(reused.nodeTextLayouts.keys == ordinary.nodeTextLayouts.keys)
            #expect(reused.selectedText() == ordinary.selectedText())
            if frame == 0 { #expect(reused.selectedText()?.isEmpty == false) }
            #expect(reused.scrollOffset(forKey: "scroll") == ordinary.scrollOffset(forKey: "scroll"))
            #expect(scene.instances == control.instances)
            if reused.retainedLayout.storageStats.liveNodes < ordinary.retainedLayout.storageStats.liveNodes {
                usedFewerSlots = true
            }
        }
        #expect(usedFewerSlots)
    }

    @Test("An intrinsic flex ancestor keeps its real row and sibling contributions")
    func intrinsicFlexAncestor() {
        func make(_ ordinary: Bool) -> Runtime<Int> {
            Runtime(state: 0, viewport: Vec2(240, 120), pixelScale: 1) { _, _ in
                col().sizeFull().scrollXY().key("scroll").child(
                    row().wFull().itemsStart().child(
                        col().wFull().minW(100).shrink(1).borderLayout(ordinary).key("rows")
                            .virtualRows(count: 300, estimatedRowHeight: 20, key: { _, i in "r-\(i)" }) { _, i in
                                col().wFull().h(20).child(text("row \(i)").w(i.isMultiple(of: 11) ? 330 : 90))
                            }
                    ).child(el().w(80).h(30).key("sibling"))
                )
            }
        }
        let tested = make(false), control = make(true)
        for i in 0...8 {
            let now = Double(i) / 60
            for runtime in [tested, control] {
                if i > 0 { runtime.wheel(WheelEvent(dx: -4, dy: -80), at: Vec2(70, 25), now: now) }
                _ = runtime.renderFrame(at: now)
            }
            #expect(tested.elements() == control.elements())
            #expect(tested.retainedLayout.storageStats.liveNodes == control.retainedLayout.storageStats.liveNodes)
        }
    }

    @Test("A fractional placeholder retries ordinary layout before releasing live and exiting text")
    func fractionalPositionRetriesTextCollection() throws {
        func make(_ ordinary: Bool) -> Runtime<Int> {
            Runtime(state: 0, viewport: Vec2(240, 120), pixelScale: 1.25) { _, _ in
                col().sizeFull().scrollXY().key("scroll").child(
                    col().wFull().minW(240).borderLayout(ordinary).key("rows")
                        .virtualRows(count: 900, estimatedRowHeight: 20, key: { _, i in "row-\(i)" }) { _, i in
                            col().wFull().h(i.isMultiple(of: 8) ? 20.5 : 20)
                                .child(text("label \(i)").w(80).h(16))
                                .child(el().size(6, 2))
                        }
                )
            }
        }
        let tested = make(false), control = make(true)
        for i in 0...12 {
            let t = Double(i) / 60
            for runtime in [tested, control] {
                if i != 0 {
                    runtime.wheel(WheelEvent(dx: 0, dy: -80), at: Vec2(80, 40), now: t)
                }
                _ = runtime.renderFrame(at: t)
            }
        }
        let old = tested.nodeTextLayouts
        #if DEBUG
        let previousRetries = tested.fixedVirtualLayoutRetries
        #endif
        func nextWindow(_ runtime: Runtime<Int>) throws -> Runtime<Int>.MeasurePassResult {
            let now = 13.0 / 60.0
            runtime.wheel(WheelEvent(dx: 0, dy: -80), at: Vec2(80, 40), now: now)
            return try #require(runtime.tryVirtualRemountPass(at: now, cut: false, commitKind: .instant,
                commitMotion: nil, commitColorSpring: nil, commitCut: false,
                prevMountedIds: runtime.nodeIndexById.keys))
        }
        // Inspect at the commit boundary. The following scene frame retires offscreen exits.
        let actual = try nextWindow(tested), expected = try nextWindow(control)
        #if DEBUG
        #expect(tested.fixedVirtualLayoutRetries > previousRetries)
        #endif
        #expect(actual.textLayouts.mapValues { $0.box.shapeKey } == expected.textLayouts.mapValues { $0.box.shapeKey })
        #expect(tested.exitingTextLayouts.mapValues { $0.box.shapeKey } == control.exitingTextLayouts.mapValues { $0.box.shapeKey })
        let departed = Set(old.keys).subtracting(actual.textLayouts.keys)
        #expect(!departed.isEmpty)
        for id in departed { #expect(tested.exitingTextLayouts[id]?.box.shapeKey == old[id]?.box.shapeKey) }
    }
}
