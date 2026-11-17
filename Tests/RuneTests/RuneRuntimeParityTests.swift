import Foundation
import Testing
@testable import Rune
@testable import RuneMotion
@testable import RuneRef

@Suite("Rune Runtime, MetalRenderer, Live & Tooling Parity Tests")
struct RuneRuntimeParityTests {
    @Test("MetalRenderer offscreen GPU output matches RuneRef CPU output")
    func metalVsRefEquivalence() throws {
        let renderer = try MetalRenderer()
        let w = 160
        let h = 120
        let fullClip = SIMD4<Float>(0, 0, Float(w), Float(h))

        let prims: [Primitive] = [
            // Rounded rect with border
            .roundedRect(
                rect: SIMD4<Float>(10, 10, 60, 40),
                radii: SIMD4<Float>(repeating: 8),
                fill: Color.hex("#3b82f6")!.simd4(srgb: false),
                borderColor: Color.white.alpha(0.6).simd4(srgb: false),
                borderWidth: 2,
                clip: fullClip
            ),
            // Linear gradient
            .linearGradient(
                rect: SIMD4<Float>(80, 10, 60, 40),
                radii: SIMD4<Float>(repeating: 6),
                topColor: Color.hex("#f43f5e")!.simd4(srgb: false),
                bottomColor: Color.hex("#f59e0b")!.simd4(srgb: false),
                angleRadians: .pi * 0.5,
                clip: fullClip
            ),
            // Dashed ring
            .dashedRing(
                rect: SIMD4<Float>(10, 62, 48, 48),
                radii: SIMD4<Float>(repeating: 24),
                color: Color.hex("#10b981")!.simd4(srgb: false),
                borderWidth: 3,
                dashLength: 8,
                gapLength: 4,
                clip: fullClip
            ),
            // Segment & triangle
            .segment(
                from: SIMD2<Float>(70, 70),
                to: SIMD2<Float>(110, 105),
                width: 4,
                color: Color.white.simd4(srgb: false),
                roundCap: true,
                clip: fullClip
            ),
            .triangle(
                v0: SIMD2<Float>(120, 65),
                v1: SIMD2<Float>(150, 105),
                v2: SIMD2<Float>(115, 105),
                aaMask: 0b111,
                color: Color.hex("#a855f7")!.simd4(srgb: false),
                clip: fullClip
            ),
        ]

        let scene = RefScene(
            width: w,
            height: h,
            srgbBlend: false,
            clearColor: Color.hex("#0f172a")!.simd4(srgb: false),
            glyphs: R8Atlas(width: 4, height: 4),
            images: RGBA8Atlas(width: 4, height: 4),
            primitives: prims
        )

        let cpu = try RuneRef.render(scene)
        let gpu = try renderer.renderOffscreen(scene)
        #expect(cpu.width == gpu.width && cpu.height == gpu.height)

        var maxDiff = 0
        for (a, b) in zip(cpu.rgba, gpu.rgba) {
            maxDiff = max(maxDiff, abs(Int(a) - Int(b)))
        }
        // Allow <= 3/255 rounding tolerance between Metal GPU linear-sRGB and CPU float math
        #expect(maxDiff <= 3)
    }

    @Test("Isolated layer wraps subtree children and applies opacity once")
    func isolatedLayerSubtree() {
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 120), pixelScale: 1.0) { _, _ in
            var card: El<S> = col().key("card").size(100, 80).opacity(0.5).bg(.white)
                .child(el().key("inner").size(40, 40).bg(.black))
            card.isolatedLayer = true
            return card
        }
        let scene = rt.frame(at: 0.0)
        // Expected primitive order: layerBegin(card) -> roundedRect(card) -> roundedRect(inner) -> layerEnd(card)
        let kinds: [PrimitiveKind] = scene.primitives.map { PrimitiveKind(rawValue: Int($0.params.y))! }
        #expect(kinds == [.layerBegin, .roundedRect, .roundedRect, .layerEnd])
        // Inside the isolated layer, both card and inner should have localAlpha = 1.0 (layerBegin carries 0.5)
        #expect(abs(scene.primitives[0].params.x - 0.5) < 1e-4)
        #expect(abs(scene.primitives[1].fill.w - 1.0) < 1e-4)
        #expect(abs(scene.primitives[2].fill.w - 1.0) < 1e-4)
    }

    @Test("Scroll chaining, fling decay, pointerExit hover clear, and drag-suppress-click")
    func scrollChainFlingHoverAndDrag() {
        struct S {
            var hovered = false
            var clicks = 0
            var dragged = false
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 300), pixelScale: 1.0) { _, _ in
            col().key("outer").size(300, 300).scroll()
                .child(
                    col().key("inner").size(280, 120).shrink(0).scroll()
                        .child(el().key("inner-content").size(260, 240).shrink(0))
                )
                .child(
                    el().key("btn").size(100, 40).shrink(0)
                        .onHover { st, isHov, _ in st.hovered = isHov }
                        .onDrag { st, _, _ in st.dragged = true }
                        .onClick { st in st.clicks += 1 }
                )
                .child(el().key("spacer").size(280, 600).shrink(0))
        }
        _ = rt.frame(at: 0.0)

        // Hover over btn then pointerExit clears hover
        let btnRect = rt.element(byKey: "btn")!.rect
        let btnCenter = Vec2(btnRect[0] + 50, btnRect[1] + 20)
        rt.pointerMove(to: btnCenter, at: 0.1)
        #expect(rt.state.hovered == true)
        rt.pointerExit(at: 0.15)
        #expect(rt.state.hovered == false)

        // Dragging > 4pt on btn suppresses onClick
        rt.pointerDown(at: btnCenter, at: 0.2)
        rt.pointerMove(to: Vec2(btnCenter.x + 20, btnCenter.y), at: 0.25)
        rt.pointerUp(at: Vec2(btnCenter.x + 20, btnCenter.y), at: 0.3)
        #expect(rt.state.dragged == true)
        #expect(rt.state.clicks == 0)

        // Scroll inner to bottom, then extra scroll chains to outer!
        let innerRect = rt.element(byKey: "inner")!.rect
        let innerPt = Vec2(innerRect[0] + 20, innerRect[1] + 20)
        rt.wheel(WheelEvent(dx: 0, dy: -200), at: innerPt, now: 0.4)
        _ = rt.frame(at: 0.45)
        #expect(rt.element(byKey: "inner")!.scrolled[1] == 120)
        #expect(rt.element(byKey: "outer")!.scrolled[1] == 0)

        // Inner is at bottom (120); next wheel down chains to outer!
        rt.wheel(WheelEvent(dx: 0, dy: -50), at: innerPt, now: 0.5)
        _ = rt.frame(at: 0.55)
        #expect(rt.element(byKey: "outer")!.scrolled[1] == 50)

        // Fling outer: upstream pointer.rs:501-509 & motion/tracks.rs:180-186 pass -velocity so
        // negative vy scrolls deeper into content and positive vy moves content back down (reduces scroll offset).
        rt.fling(vx: 0, vy: -400, at: Vec2(250, 250), now: 0.6)
        _ = rt.frame(at: 0.7)
        let afterDown = rt.element(byKey: "outer")!.scrolled[1]
        #expect(afterDown > 50)
        rt.fling(vx: 0, vy: 800, at: Vec2(250, 250), now: 0.75)
        _ = rt.frame(at: 0.85)
        #expect(rt.element(byKey: "outer")!.scrolled[1] < afterDown)
        #expect(rt.element(byKey: "outer")!.scrolled[1] < 50)
    }

    @Test("Tweens start on first attachment and follow elapsed time at a reduced view time scale")
    func linearTweenUsesRuntimeClock() throws {
        let tween = Tween<Float>.linear(from: 1, to: 0, duration: 10)
        let rt = Runtime<Bool>(state: false, viewport: Vec2(100, 100)) { show, cx in
            cx.timeScale(0.25)
            let root = El<Bool>().size(100, 100)
            return show ? root.child(el().key("timer").size(20, 20).liveOpacity(tween.binding)) : root
        }
        _ = rt.frame(at: 0)
        _ = rt.frame(at: 8)
        rt.update(at: 10) { show, tx in show = true; tx.settle() }
        _ = rt.frame(at: 10)
        #expect(try #require(rt.element(byKey: "timer")).opacity == 1)
        _ = rt.frame(at: 12.5)
        #expect(try #require(rt.element(byKey: "timer")).opacity == 0.75)
    }

    @Test("Live pulse, Tween.linear, LiveText, ToolingArgs, and JsonTheme.num")
    func liveTweenToolingAndExports() throws {
        let tween = Tween<Float>.linear(from: 0.0, to: 1.0, duration: 1.0)
        let lt = LiveText("hello")
        let livePulse = Live<Float>(0.2)

        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            col().sizeFull()
                .child(el().key("tw").size(20, 20).liveOpacity(tween.binding))
                .child(el().key("pls").size(20, 20).liveOpacity(livePulse.smooth(Tok.Motion.SNAPPY)))
                .child(liveText(lt).key("lt"))
        }
        _ = rt.frame(at: 0.0)
        #expect(abs(rt.element(byKey: "tw")!.opacity - 0.0) < 1e-4)
        _ = rt.frame(at: 0.5)
        #expect(abs(rt.element(byKey: "tw")!.opacity - 0.5) < 1e-2)
        _ = rt.frame(at: 1.0)
        #expect(abs(rt.element(byKey: "tw")!.opacity - 1.0) < 1e-4)

        lt.set("world")
        _ = rt.frame(at: 1.1)
        #expect(rt.element(byKey: "lt")?.text == "world")

        livePulse.pulse(active: 1.0, rest: 0.2, holdSeconds: 0.1)
        _ = rt.frame(at: 1.15)
        _ = rt.frame(at: 1.20)
        #expect(rt.element(byKey: "pls")!.opacity > 0.25)

        let args = ToolingArgs.parse(["--theme", "light", "--at", "0.5", "--crop", "tw", "--every", "2", "--scale", "1"])
        #expect(args.darkOverride == false)
        #expect(args.atTime == 0.5)
        #expect(args.cropKey == "tw")
        #expect(args.stripEvery == 2)

        let jt = try JsonTheme.fromJSON(##"{"theme": {"accent": "#ff0000", "gap": 12}}"##, dark: true)
        #expect(jt["accent"]?.hexString() == "#ff0000")
        #expect(jt.num("gap") == 12)
        #expect(Tok.Typography.body.size == 13.0)
    }
}
