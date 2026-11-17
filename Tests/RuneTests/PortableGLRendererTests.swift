#if (os(macOS) || os(Linux) || os(Windows)) && canImport(CRuneOffscreenGL)
import CRuneOffscreenGL
import RuneRef
import Testing
@testable import Rune

@MainActor
func withTestGLTarget(
    _ body: (PortableGLRenderer, (Int, Int, () throws -> Void) throws -> Frame) throws -> Void
) throws {
    let context = try OffscreenGLContext()
    defer { context.close() }
    let renderer = try PortableGLRenderer(resolve: OffscreenGLContext.resolve, isGLES: OffscreenGLContext.isGLES)
    defer { renderer.close() }
    try body(renderer, context.withFramebuffer)
}

@MainActor
func withTestGLRenderer(
    _ body: (PortableGLRenderer, (RefScene) throws -> Frame) throws -> Void
) throws {
    let context = try OffscreenGLContext()
    defer { context.close() }
    let renderer = try PortableGLRenderer(resolve: OffscreenGLContext.resolve, isGLES: OffscreenGLContext.isGLES)
    defer { renderer.close() }
    try body(renderer) { scene in
        try context.withFramebuffer(width: scene.width, height: scene.height) {
            try renderer.draw(scene)
        }
    }
}

@MainActor
@Suite("OpenGL scene readback")
struct PortableGLRendererTests {
    private let bounds = SIMD4<Float>(0, 0, 64, 44)

    @Test("Closing a nested context restores the caller's framebuffer")
    func restoresCurrentContext() throws {
        try withTestGLTarget { renderer, capture in
            let clear = RefScene(width: 7, height: 3, srgbBlend: true, clearColor: SIMD4(0.2, 0.4, 0.6, 1))
            let frame = try capture(7, 3) {
                let inner = try OffscreenGLContext()
                inner.close()
                // Deliberately draw without rebinding the outer context or framebuffer.
                try renderer.draw(clear)
            }
            try assertMatches(clear, rendered: frame, tolerance: 0)
        }
    }

    private func scene(srgbBlend: Bool) -> RefScene {
        var card = Primitive.roundedRect(
            rect: SIMD4(8, 6, 32, 22), radii: SIMD4(-5, 4, 2, 0),
            fill: SIMD4(0.2, 0.6, 0.1, 0.7), borderColor: SIMD4(0.1, 0.2, 0.7, 0.9),
            borderSides: SIMD4(2, 0, 3, 1), clip: bounds, turn: 0.23)
        card.fade = SIMD4(1, 0, 0.06, 0.25)
        card.fadeOrigin = SIMD2(9, 7)
        return RefScene(
            width: 64, height: 44, srgbBlend: srgbBlend, clearColor: SIMD4(0.06, 0.11, 0.18, 1),
            glyphs: R8Atlas(width: 3, height: 2, texels: [0, 255, 55, 240, 32, 150]),
            images: RGBA8Atlas(width: 2, height: 2, texels: [
                35, 150, 34, 255, 150, 220, 70, 190, 240, 70, 50, 200, 66, 20, 180, 92
            ]),
            primitives: [
                .dropShadow(rect: SIMD4(8, 6, 32, 22), radii: SIMD4(repeating: 4),
                            color: SIMD4(0.5, 0.3, 0.2, 0.7), blur: 3, offset: SIMD2(2, 1), clip: bounds),
                card,
                .insetShadow(rect: SIMD4(8, 6, 32, 22), radii: SIMD4(repeating: 4),
                             color: SIMD4(0.4, 0, 0.5, 0.7), blur: 3, offset: SIMD2(3, 2), clip: bounds),
                .linearGradient(rect: SIMD4(17, 18, 31, 17), topColor: SIMD4(0.7, 0.1, 0.2, 0.8),
                                bottomColor: SIMD4(0.1, 0.4, 0.2, 0.6), angleRadians: 0.7, clip: bounds),
                .glyph(rect: SIMD4(2, 3, 14, 12), uv: SIMD4(0, 0, 1, 1),
                       color: SIMD4(1, 1, 1, 0.9), gamma: 1.2, clip: bounds),
                .image(rect: SIMD4(43, 6, 16, 12), radii: SIMD4(repeating: 2),
                       uv: SIMD4(0, 0, 1, 1), clip: bounds),
                .radialGradient(rect: SIMD4(41, 20, 16, 19), innerColor: SIMD4(0.9, 0.2, 0.8, 0.8),
                                outerColor: SIMD4(0.1, 0.1, 0.1, 0.4), clip: bounds),
                .dashedRing(rect: SIMD4(42, 18, 18, 22), radii: SIMD4(repeating: 4),
                            color: SIMD4(1, 0.9, 0.6, 0.85), borderWidth: 2,
                            dashLength: 4, gapLength: 3, phase: 0.8, clip: bounds),
                .segment(from: SIMD2(4, 36), to: SIMD2(34, 29), width: 1.2,
                         color: SIMD4(0.7, 0.2, 0.1, 0.8), clip: bounds),
                .triangle(v0: SIMD2(15, 40), v1: SIMD2(24, 31), v2: SIMD2(34, 41),
                          color: SIMD4(0.2, 0.6, 0.7, 0.8), clip: bounds)
            ])
    }

    private func assertMatches(_ scene: RefScene, rendered: Frame, tolerance: Int = 2) throws {
        let expected = try RuneRef.render(scene)
        let diff = RuneRef.compare(scene: scene, expected: expected, actual: rendered, channelTolerance: tolerance)
        #expect(diff.passed, "\(diff)")
    }

    @Test("A production window loads reference shaders only for a reference scene")
    func compileReferenceOnFirstUse() throws {
        let context = try OffscreenGLContext()
        defer { context.close() }
        var requested = [String]()
        var failReference = true
        let renderer = try PortableGLRenderer(
            resolve: OffscreenGLContext.resolve, isGLES: OffscreenGLContext.isGLES
        ) { name in
            requested.append(name)
            if name == "rune.frag", failReference { return "invalid GLSL" }
            return try PortableGLRenderer.bundledShader(name)
        }
        defer { renderer.close() }
        let frame = RenderFrame(width: 4, height: 3, srgbBlend: true, clearColor: SIMD4(1, 0, 0, 1))
        let production = try context.withFramebuffer(width: 4, height: 3) { try renderer.draw(frame) }
        #expect(Array(production.rgba.prefix(4)) == [255, 0, 0, 255])
        #expect(!requested.contains("rune.vert") && !requested.contains("rune.frag"))
        let reference = RefScene(width: 4, height: 3, srgbBlend: true, clearColor: SIMD4(0, 1, 0, 1))
        #expect(throws: PortableGLRenderer.RenderError.self) {
            _ = try context.withFramebuffer(width: 4, height: 3) { try renderer.draw(reference) }
        }
        failReference = false
        let recovered = try context.withFramebuffer(width: 4, height: 3) { try renderer.draw(reference) }
        #expect(Array(recovered.rgba.prefix(4)) == [0, 255, 0, 255])
        let loaded = requested
        _ = try context.withFramebuffer(width: 4, height: 3) { try renderer.draw(frame) }
        _ = try context.withFramebuffer(width: 4, height: 3) { try renderer.draw(reference) }
        #expect(requested == loaded)
    }

    @Test("Primitive batches, atlas changes, blend modes and drawable resize")
    func primitivesAndResize() throws {
        try withTestGLRenderer { _, render in
            let linear = scene(srgbBlend: false)
            try assertMatches(linear, rendered: render(linear))
            var gamma = scene(srgbBlend: true)
            gamma.glyphs.texels.reverse()
            gamma.images.texels.reverse()
            try assertMatches(gamma, rendered: render(gamma))
            for blend in [true, false] {
                var translucent = scene(srgbBlend: blend)
                translucent.clearColor = SIMD4(0.05, 0.4, 0.18, 0.45)
                // Filtered R8 coverage can round by one unit. Resolving to straight RGB
                // over this translucent clear amplifies that difference in the final byte.
                try assertMatches(translucent, rendered: render(translucent), tolerance: 3)
            }
            let clear = RefScene(width: 29, height: 13, clearColor: SIMD4(0.34, 0.16, 0.05, 1))
            try assertMatches(clear, rendered: render(clear))
            try assertMatches(linear, rendered: render(linear))
        }
    }

    @Test("Nested layers and a backdrop read the correct intermediate target")
    func groupsAndBackdrop() throws {
        var scene = scene(srgbBlend: true)
        let groupRect = SIMD4<Float>(8, 8, 46, 28)
        let innerRect = SIMD4<Float>(15, 10, 26, 20)
        let backdrop = Primitive(rect: innerRect, radii: SIMD4(repeating: 2),
                                 params: SIMD4(3, Float(PrimitiveKind.backdropBlur.rawValue), 0, 0), clip: bounds)
        scene.primitives = [
            .linearGradient(rect: bounds, topColor: SIMD4(0.4, 0.1, 0.9, 1),
                            bottomColor: SIMD4(0.2, 0.8, 0.1, 1), clip: bounds),
            .layerBegin(rect: groupRect, radii: SIMD4(repeating: 3), opacity: 0.78, clip: groupRect),
            .roundedRect(rect: groupRect, fill: SIMD4(0.6, 0.2, 0.1, 0.9), clip: bounds),
            .layerBegin(rect: innerRect, opacity: 0.6, additive: true, blurRadius: 2, clip: innerRect,
                        fade: SIMD4(1, 0, 0.07, 0.4), fadeOrigin: SIMD2(16, 10), turn: 0.16),
            .roundedRect(rect: SIMD4(20, 12, 10, 12), fill: SIMD4(0.1, 0.6, 0.8, 0.8), clip: bounds),
            .layerEnd(clip: bounds), backdrop, .layerEnd(clip: bounds),
            .effectSlot(rect: bounds, clip: bounds), backdrop,
            .roundedRect(rect: SIMD4(34, 23, 7, 5), fill: SIMD4(0.2, 0.25, 0.75, 0.5), clip: bounds)
        ]
        try withTestGLRenderer { _, render in try assertMatches(scene, rendered: render(scene)) }
    }
}
#endif
