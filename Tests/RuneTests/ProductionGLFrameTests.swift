#if (os(macOS) || os(Linux) || os(Windows)) && canImport(CRuneOffscreenGL)
import RuneRef
import Testing
@testable import Rune

@MainActor
@Suite("Production GL paint stream")
struct ProductionGLFrameTests {
    private let clip = SIMD4<Float>(0, 0, 64, 40)

    private func fixture(byteBlend: Bool) -> RenderFrame {
        let inset = SIMD4<Float>(2, 1, 44, 35)
        var card = RenderInstance(
            rect: SIMD4(0.25, 0.5, 48, 38), radii: SIMD4(-5, -3, -8, -1),
            fill: SIMD4(0.64, 0.10, 0.02, 0.8), border: SIMD4(0.1, 0.35, 0.5, 0.5),
            params: SIMD4(2, KIND_RECT, 0.5, 0.8), uv: SIMD4(1, 3, 4, 2),
            clip: inset, fade: packFade(width: SIMD4(10, -4, 0, 5), origin: clip, clip: inset)
        )
        card.roundClipCorners(SIMD4(3, 1, 6, 2))
        let radial = RenderInstance(
            rect: SIMD4(15, 10, 25, 23), radii: SIMD4(repeating: 1),
            fill: SIMD4(0.05, 0.48, 0.43, 0.67), border: SIMD4(0.53, 0.50, 0.02, 0.65),
            params: SIMD4(0.1, KIND_RADIAL, 0.7, 0.88), uv: SIMD4(10, 9, 11, 8), clip: clip
        )
        let glyph = RenderInstance(
            rect: SIMD4(45, 4, 14, 14), fill: SIMD4(0.48, 0.24, 0.72, 0.8),
            params: SIMD4(0.2, KIND_GLYPH, 0, 1.1), uv: SIMD4(0, 0, 2, 2), clip: clip
        )
        let image = RenderInstance(
            rect: SIMD4(43, 24, 15, 10), radii: SIMD4(repeating: 2),
            fill: SIMD4(1, 1, 1, 0.85), params: SIMD4(1, KIND_IMAGE, 0, 0),
            uv: SIMD4(0, 0, 2, 1), clip: clip
        )
        let shadow = RenderInstance(
            rect: SIMD4(3, 5, 40, 32), radii: SIMD4(repeating: 4), fill: SIMD4(0.05, 0.02, 0.10, 0.16),
            params: SIMD4(0, KIND_SHADOW, 2, 0), clip: clip
        )
        let segment = RenderInstance(
            rect: SIMD4(41, 17, 20, 5), radii: SIMD4(42.2, 18.3, 60.2, 20.7), fill: SIMD4(0.4, 0.1, 0.6, 0.7),
            params: SIMD4(0.55, KIND_SEGMENT, 1, 0), clip: clip
        )
        let triangle = RenderInstance(
            rect: SIMD4(55, 11, 7, 6), radii: SIMD4(55.1, 12.2, 61.6, 11.5), fill: SIMD4(0.3, 0.2, 0.5, 0.6),
            params: SIMD4(7, KIND_TRIANGLE, 0, 0), uv: SIMD4(58, 17.3, 0, 0), clip: clip
        )
        let dash = RenderInstance(
            rect: SIMD4(1, 28, 27, 10), radii: SIMD4(4, 2, 3, 1), fill: SIMD4(0.2, 0.6, 0.1, 0.8),
            border: SIMD4(0.1, 0.1, 0.4, 0.5), params: SIMD4(1.5, KIND_DASHED, 0.5, 0),
            uv: SIMD4(4, 2, 0.5, 0), clip: clip
        )
        return RenderFrame(
            width: 64, height: 40, srgbBlend: byteBlend, clearColor: SIMD4(0.08, 0.16, 0.21, 1),
            glyphs: R8Atlas(width: 2, height: 2, texels: [255, 22, 94, 193]),
            imagePages: [
                RGBA8Atlas(width: 1, height: 1, texels: [255, 0, 128, 255]),
                RGBA8Atlas(width: 2, height: 1, texels: [125, 196, 46, 255, 234, 74, 135, 185])
            ], instances: [shadow, card, radial, glyph, image, segment, triangle, dash]
        )
    }

    @Test("GL uses the production instance/clip ABI and samples image pages and glyphs")
    func renderProduction() throws {
        #expect(MemoryLayout<RenderInstance>.stride == 128)
        #expect(MemoryLayout<RenderInstance>.offset(of: \.fade) == 112)
        try withTestGLTarget { renderer, capture in
            for byteBlend in [true, false] {
                let frame = fixture(byteBlend: byteBlend)
                let image = try capture(frame.width, frame.height) { try renderer.draw(frame) }
                let background = image.pixel(x: 63, y: 39)
                #expect(image.pixel(x: 0, y: 0) == background)
                #expect(image.pixel(x: 9, y: 8).x > background.x)
                #expect(image.pixel(x: 48, y: 26).y > background.y)
                #expect(image.pixel(x: 50, y: 9).z > background.z)
                #if canImport(Metal)
                let metal = try MetalRenderer().renderOffscreen(frame)
                expectImagesClose(image, metal)
                #endif
            }
        }
    }

    #if canImport(Metal)
    @Test("Straight readback recovers a translucent production clear in both blend spaces")
    func translucentClear() throws {
        try withTestGLTarget { renderer, capture in
            for byteBlend in [true, false] {
                var frame = fixture(byteBlend: byteBlend)
                frame.clearColor = SIMD4(0.12, 0.22, 0.07, 0.6)
                let image = try capture(frame.width, frame.height) { try renderer.draw(frame) }
                let metal = try MetalRenderer().renderOffscreen(frame)
                let background = image.pixel(x: 63, y: 39)
                #expect(background.w == 153)
                expectImagesClose(image, metal)
            }
        }
    }

    @Test("A runtime-built card paints the same text and controls on GL and Metal")
    func runtimeCard() throws {
        let runtime = Runtime<Bool>(state: false, viewport: Vec2(94, 51), pixelScale: 1.0) { on, _ in
            col().sizeFull().center().gap(3)
                .bg(Color(r: 0.1, g: 0.12, b: 0.14))
                .child(text(on ? "Lights on" : "Lights off").size(13))
                .child(el().key("switch").pill().size(29, 12).bg(Color(r: 0.4, g: 0.1, b: 0.2)))
        }
        try withTestGLTarget { renderer, capture in
            let frame = runtime.renderFrame(at: 0)
            #expect(frame.instances.contains { $0.params.y == KIND_GLYPH })
            let image = try capture(frame.width, frame.height) { try renderer.draw(frame) }
            expectImagesClose(image, try MetalRenderer().renderOffscreen(frame))
        }
    }

    private func expectImagesClose(_ actual: Frame, _ expected: Frame) {
        let errors = zip(actual.rgba, expected.rgba).map { abs(Int($0) - Int($1)) }
        #expect((errors.max() ?? 0) <= 3, "Largest channel difference was \(errors.max() ?? 0)")
    }
    #endif

    @Test("Effect-slot data survives preparation as opaque bits")
    func preservesEffectBits() throws {
        let payload = SIMD4<Float>(Float(bitPattern: 0x7fc0_1234), -0.0, .infinity, 1.0)
        let slot = RenderInstance(rect: clip, params: SIMD4(0, KIND_EFFECT, 0, 0), uv: payload)
        let frame = RenderFrame(width: 64, height: 40, instances: [slot])
        try frame.validateForGL()
        let result = try #require(frame.instances.first)
        #expect((0..<4).allSatisfy { result.uv[$0].bitPattern == payload[$0].bitPattern })
    }

    @Test("An unclosed group is rejected before a new frame reaches GL")
    func rejectsInvalidFrame() throws {
        var invalid = fixture(byteBlend: false)
        invalid.instances.append(.beginLayer(bounds: clip, clip: clip))
        #expect(throws: RefSceneError.unclosedLayers(remaining: 1)) {
            try invalid.validateForGL()
        }
    }
}
#endif
