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
                .shadow(y: 2, blur: 6, color: .black)
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

    @Test("The probe captures inherited opacity, shadow geometry and streaming image revisions")
    func geometryAndImageSignature() throws {
        let pixels = Pixels()
        let rt = Runtime<Int>(state: 0, viewport: Vec2(160, 80), pixelScale: 1) { _, _ in
            el().size(160, 80).child(
                el().key("image").size(24, 24).pixels(pixels).bg(.white)
                    .shadow(Shadow(x: -3, y: 1, blur: 4, spread: -2, color: .white)).dim(0.5)
            ).layerOpacity(0.5)
        }
        _ = rt.renderFrame(at: 0)
        let node = try #require(rt.element(byKey: "image"))
        let key = MotionGateRecording.PaintKey(path: node.path, exiting: false)
        let paint = try #require(rt.paints()[key])
        #expect(paint.colors[MotionGatePaint.cFill].a == 0.25)
        #expect(paint.colors[MotionGatePaint.cShadow].a == 0.25)
        #expect(paint.sizes[MotionGatePaint.sShadow] == 9)
        #expect(paint.image?.0 == pixels.id)
        pixels.set(width: 1, height: 1, rgba: [255, 0, 0, 255])
        _ = rt.renderFrame(at: 1.0 / 60)
        #expect(rt.paints()[key]?.image?.1 == pixels.generation)
        #expect(paint.image?.1 != pixels.generation)
    }

    @Test("Only text and icons report ink, including an unstyled glyph's actual color")
    func defaultTextInkAndContainer() throws {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(140, 100), systemDark: true) { _, _ in
            col().size(140, 100)
                .child(text("probe").key("plain"))
                .child(icon(SVGIcon(viewBox: 10, paths: ["M0 0 H10 V10 H0 Z"])).key("icon"))
                .child(el().key("box").size(20, 20).color(.white))
        }
        let frame = rt.renderFrame(at: 0)
        let glyph = try #require(frame.instances.first { $0.params.y == KIND_GLYPH })
        let textPath = try #require(rt.element(byKey: "plain")?.path)
        let boxPath = try #require(rt.element(byKey: "box")?.path)
        let iconPath = try #require(rt.element(byKey: "icon")?.path)
        let paints = rt.paints()
        let ink = try #require(paints[.init(path: textPath, exiting: false)]?.colors[MotionGatePaint.cText])
        #expect(ink == .white)
        #expect(paints[.init(path: iconPath, exiting: false)]?.colors[MotionGatePaint.cText] == ink)
        #expect(abs(glyph.fill.x - ink.r) < 0.0001 && glyph.fill.w == ink.a)
        #expect(paints[.init(path: boxPath, exiting: false)]?.colors[MotionGatePaint.cText] == .transparent)
    }
}
