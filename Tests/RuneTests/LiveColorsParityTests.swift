import Testing
@testable import Rune
import RuneMotion

@Suite("Rune Live Colors Parity Tests (runtime/live_colors_tests.rs)")
struct LiveColorsParityTests {
    private final class ViewCounter: @unchecked Sendable {
        var count: Int = 0
    }

    private struct State {
        var ink: Live<Color>
        var edge: Live<Color>
        var glow: Live<Color>
        var top: Live<Color>
        var bottom: Live<Color>
        var smooth: Bool
        var views: ViewCounter
    }

    private static let red = Color(r: 1, g: 0, b: 0, a: 1)
    private static let green = Color(r: 0, g: 1, b: 0, a: 1)
    private static let blue = Color(r: 0, g: 0, b: 1, a: 1)

    private static func makeRuntime(smooth: Bool) -> Runtime<State> {
        let s = State(
            ink: Live(Color.white),
            edge: Live(Color.white),
            glow: Live(Color.white),
            top: Live(Color.white),
            bottom: Live(Color.white),
            smooth: smooth,
            views: ViewCounter()
        )
        let rt = Runtime<State>(
            state: s,
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { st, _ in
            st.views.count += 1
            var card: El<State> = el()
                .key("card")
                .size(80, 40)
                .bg(.black)
                .border(1, .black)
                .shadow(2, 6, .black)
                .gradient(.black, .black)
            if st.smooth {
                card = card.liveBorder(st.edge.smooth(Spring(duration: 0.25, bounce: 0.0)))
            } else {
                card = card.liveBorder(st.edge.binding)
            }
            return el().size(200, 200).child(
                card
                    .liveShadow(st.glow.binding)
                    .liveGradient(st.top.binding, st.bottom.binding)
                    .child(text("hi").key("ink").color(.black).liveTextColor(st.ink.binding))
            )
        }
        _ = rt.frame(at: 0.0)
        return rt
    }

    private static func paint(for key: String, in rt: Runtime<State>) throws -> MotionGatePaint {
        let node = try #require(rt.flatNodes.first { $0.key == key })
        return try #require(rt.paints()[MotionGateRecording.PaintKey(path: node.path, exiting: false)])
    }

    @Test("text_border_shadow_and_gradient_colours_change_without_a_view_rerun")
    func textBorderShadowAndGradientColoursChangeWithoutViewRerun() throws {
        let rt = Self.makeRuntime(smooth: false)
        let card0 = try Self.paint(for: "card", in: rt)
        #expect(card0.colors[MotionGatePaint.cBorder] == .white, "the binding wins over the authored colour")
        #expect(try Self.paint(for: "ink", in: rt).colors[MotionGatePaint.cText] == .white)

        let viewsBefore = rt.state.views.count
        let commitsBefore = rt.viewCommitCount
        rt.state.ink.set(Self.red)
        rt.state.edge.set(Self.green)
        rt.state.glow.set(Self.blue)
        rt.state.top.set(Self.red)
        rt.state.bottom.set(Self.green)
        #expect(rt.livePending)

        var t = 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(rt.state.views.count == viewsBefore)
        #expect(rt.viewCommitCount == commitsBefore)

        let card1 = try Self.paint(for: "card", in: rt)
        #expect(card1.colors[MotionGatePaint.cBorder] == Self.green)
        #expect(card1.colors[MotionGatePaint.cShadow] == Self.blue)
        #expect(card1.colors[MotionGatePaint.cGradient] == Self.red)
        #expect(card1.gradientEnd == Self.green)
        #expect(try Self.paint(for: "ink", in: rt).colors[MotionGatePaint.cText] == Self.red)

        rt.invalidate()
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let card2 = try Self.paint(for: "card", in: rt)
        #expect(card2.colors[MotionGatePaint.cBorder] == Self.green, "a rebuild keeps what the binding last set")
        #expect(card2.colors[MotionGatePaint.cShadow] == Self.blue)
        #expect(card2.colors[MotionGatePaint.cGradient] == Self.red)
        #expect(card2.gradientEnd == Self.green)
        #expect(try Self.paint(for: "ink", in: rt).colors[MotionGatePaint.cText] == Self.red)
    }

    @Test("a_smoothed_border_colour_springs_then_lands_exactly")
    func smoothedBorderColourSpringsThenLandsExactly() throws {
        let rt = Self.makeRuntime(smooth: true)
        rt.state.edge.set(Self.blue)
        var t = 0.03
        _ = rt.frame(at: t)
        let mid = try Self.paint(for: "card", in: rt).colors[MotionGatePaint.cBorder]
        #expect(mid.r > 0.0 && mid.r < 1.0 && mid.b == 1.0, "moving: \(mid)")
        for _ in 0..<240 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        #expect(try Self.paint(for: "card", in: rt).colors[MotionGatePaint.cBorder] == Self.blue)
        #expect(!rt.isAnimating)
    }
}
