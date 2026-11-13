import Foundation
import Testing
@testable import Rune
import RuneMotion

@Suite("Rune Shimmer Parity Tests (runtime/tests/shimmer.rs)")
struct ShimmerParityTests {
    private struct ShimmerState {
        var hovered = false
        var speed: Float = 1.0
    }

    private static func shimmerView(_ s: ShimmerState, _ cx: inout Cx<ShimmerState>) -> El<ShimmerState> {
        cx.timeScale(s.speed)
        let period = 1.2
        return col()
            .size(400, 60)
            .px(24)
            .py(16)
            .child(
                col()
                    .key("wrap")
                    .w(180)
                    .h(24)
                    .child(text("Thinking deeply…").key("dim").size(180, 24).color(.white.alpha(0.35)))
                    .child(
                        col()
                            .key("window")
                            .w(60)
                            .h(24)
                            .absolute(x: 0, y: 0)
                            .clip(true)
                            .loopSlide(period: period, from: Vec2(-1.0, 0), to: Vec2(3.0, 0))
                            .child(
                                text("Thinking deeply…")
                                    .key("bright")
                                    .size(180, 24)
                                    .color(.white)
                                    .loopSlide(period: period, from: Vec2(1.0 / 3.0, 0), to: Vec2(-1.0, 0))
                            )
                    )
            )
    }

    private static func shimmerXDelta(in rt: Runtime<ShimmerState>) -> Float {
        let elements = rt.elements()
        guard let dim = elements.first(where: { $0.key == "dim" }),
              let bright = elements.first(where: { $0.key == "bright" }) else {
            return .infinity
        }
        return abs(bright.rect[0] - dim.rect[0]) + abs(bright.rect[1] - dim.rect[1])
    }

    @Test("a_counter_sliding_shimmer_keeps_its_bright_copy_on_the_label")
    func counterSlidingShimmerKeepsBrightCopyOnLabel() {
        let rt = Runtime<ShimmerState>(
            state: ShimmerState(),
            viewport: Vec2(400, 60),
            pixelScale: 2.0,
            systemDark: true,
            view: Self.shimmerView
        )
        for i in 0..<24 {
            let t = Double(i) * (1.0 / 60.0)
            _ = rt.frame(at: t)
            let delta = Self.shimmerXDelta(in: rt)
            #expect(delta < 0.01, "bright copy must stay aligned over dim at t=\(t): delta=\(delta)")
        }
        // Also verify RenderFrame builds cleanly and emits glyphs while shimmering
        let rf = rt.renderFrame(at: 24.0 / 60.0)
        #expect(rf.instances.contains { $0.params.y == KIND_GLYPH })
    }

    @Test("a_shimmer_stopped_while_waiting_and_resumed_under_timescale_stays_in_step")
    func shimmerUnderTimeScaleAndPauseStaysInStep() {
        let rt = Runtime<ShimmerState>(
            state: ShimmerState(speed: 1.0),
            viewport: Vec2(400, 60),
            pixelScale: 2.0,
            systemDark: true,
            view: Self.shimmerView
        )
        var t = 0.0
        for _ in 0..<10 {
            _ = rt.frame(at: t)
            #expect(Self.shimmerXDelta(in: rt) < 0.01)
            t += 1.0 / 60.0
        }
        // Pause via timeScale 0.0, advance host time while sleeping, then resume at 0.5x
        rt.update(at: t) { s, _ in s.speed = 0.0 }
        t += 0.5
        _ = rt.frame(at: t)
        #expect(Self.shimmerXDelta(in: rt) < 0.01)

        rt.update(at: t) { s, _ in s.speed = 0.5 }
        for _ in 0..<20 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            #expect(Self.shimmerXDelta(in: rt) < 0.01)
        }
    }

    @Test("shimmer: stop-restart, hovering pointer with late frames, real window cadence, and sleeping host keep bright copy aligned")
    func shimmerStopRestartHoverLateAndSleepingHostParity() {
        let rt = Runtime<ShimmerState>(state: ShimmerState(hovered: false, speed: 1.0), view: Self.shimmerView)
        var t = 0.0
        _ = rt.frame(at: t)
        #expect(Self.shimmerXDelta(in: rt) < 0.01)

        // Stop shimmer via timeScale(0), advance time, then restart shimmer
        t += 0.15
        rt.update(at: t) { s, _ in s.speed = 0.0 }
        _ = rt.frame(at: t)
        t += 0.25
        rt.update(at: t) { s, _ in s.speed = 1.0 }
        _ = rt.frame(at: t)
        #expect(Self.shimmerXDelta(in: rt) < 0.01)

        // Move pointer into the shimmer region while late frames arrive
        for step in 1...12 {
            t += (step % 3 == 0) ? 0.085 : 0.016
            rt.pointerMove(to: Vec2(Float(18 + step * 3), 18), at: t)
            _ = rt.frame(at: t)
            #expect(Self.shimmerXDelta(in: rt) < 0.01)
        }

        // Simulate sleeping host gap without intermediate ticks, then resume rendering
        t += 1.25
        rt.update(at: t) { s, _ in s.hovered = true }
        _ = rt.frame(at: t)
        #expect(Self.shimmerXDelta(in: rt) < 0.01)
        #expect(rt.isAnimating)
    }
}
