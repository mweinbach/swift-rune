import Testing
@testable import Rune
import RuneMotion

@Suite struct DragScreenPointTests {
    private struct Sample {
        let drag: Drag
        let repeated: Bool

        var pixels: [Int32]? { drag.screenPoint().map { [$0.0, $0.1] } }
    }

    private func runtime(zoom: Float = 1) -> Runtime<[Sample]> {
        let runtime = Runtime<[Sample]>(state: [], viewport: Vec2(300, 200), pixelScale: 2) { _, cx in
            cx.zoom(zoom)
            return el().size(200, 120).onDrag { samples, drag, tx in
                samples.append(Sample(drag: drag, repeated: tx.dragRepeat()))
                if drag.phase != .up { tx.dragRepeatAfter(0.25) }
            }
        }
        _ = runtime.frame(at: 0)
        return runtime
    }

    @Test func dragSamplesUseTheCurrentContentOriginAndRoundedDevicePixels() {
        let rt = runtime(zoom: 1.5)
        #expect(rt.inputScale() == 3)
        rt.setWindowPixels((-200, 50))
        rt.pointerDown(at: rt.inputPoint(fromWindow: Vec2(15.75, 30.75)), at: 1)
        #expect(rt.state.last?.drag.phase == .down)
        #expect(rt.state.last?.drag.windowPoint() == [10.5, 20.5])
        #expect(rt.state.last?.pixels == [-168, 112])

        rt.pointerMove(to: rt.inputPoint(fromWindow: Vec2(3.75, 9.75)), at: 1.1)
        #expect(rt.state.last?.drag.phase == .move)
        #expect(rt.state.last?.pixels == [-192, 70])
        rt.setWindowPixels((100, -80))
        _ = rt.frame(at: 1.4)
        #expect(rt.state.last?.repeated == true)
        #expect(rt.state.last?.pixels == [108, -60])

        rt.pointerUp(at: rt.inputPoint(fromWindow: Vec2(-2.25, 3)), at: 1.5)
        #expect(rt.state.last?.drag.phase == .up)
        #expect(rt.state.last?.pixels == [95, -74])
    }

    @Test func captureLossUsesItsFinalPointAndAbsentDesktopOriginsStayAbsent() {
        let rt = runtime()
        rt.setWindowOrigin(Vec2(400, 800))
        rt.pointerDown(at: Vec2(10, 14), at: 1)
        #expect(rt.state.last?.drag.phase == .down)
        #expect(rt.state.last?.pixels == nil)
        rt.setWindowPixels((100, 200))
        rt.pointerReleaseLost(at: Vec2(12, 15.25), at: 1.1)
        #expect(rt.state.last?.drag.phase == .up)
        #expect(rt.state.last?.drag.cancelled() == true)
        #expect(rt.state.last?.pixels == [124, 231])
        rt.setWindowPixels(nil)
        rt.pointerDown(at: Vec2(15, 20), at: 2)
        #expect(rt.state.last?.drag.phase == .down)
        #expect(rt.state.last?.pixels == nil)
    }
}
