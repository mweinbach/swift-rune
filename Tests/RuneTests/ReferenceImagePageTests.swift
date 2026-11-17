import RuneRef
import Testing
@testable import Rune

@Suite("Reference image pages")
struct ReferenceImagePageTests {
    private let clip = SIMD4<Float>(0, 0, 24, 8)

    private func scene() -> RefScene {
        let colors = RGBA8Atlas(width: 2, height: 1, texels: [192, 0, 0, 255, 0, 0, 192, 255])
        let other = RGBA8Atlas(width: 1, height: 1, texels: [0, 128, 0, 255])
        return RefScene(width: 24, height: 8, srgbBlend: true, imagePages: [colors, other, RGBA8Atlas(texels: [])],
                        primitives: [
                            .image(rect: clip, uv: SIMD4(0, 0, 0.5, 1), clip: clip),
                            .layerBegin(rect: clip, clip: clip),
                            .image(rect: SIMD4(6, 0, 18, 8), uv: SIMD4(0, 0, 1, 1), clip: clip, page: 1),
                            .image(rect: SIMD4(12, 0, 6, 8), uv: SIMD4(0.5, 0, 1, 1), clip: clip),
                            .image(rect: clip, uv: SIMD4(0, 0, 1, 1), clip: clip, page: 2),
                            .layerEnd(clip: clip)
                        ])
    }

    private func glyphScene() -> RefScene {
        let glyphBounds = SIMD4<Float>(0, 0, 1, 1)
        let solid = R8Atlas(width: 1, height: 1, texels: [255])
        let half = R8Atlas(width: 2, height: 1, texels: [128, 128])
        return RefScene(width: 24, height: 8, srgbBlend: true,
                        glyphPages: [solid, half], primitives: [
                            .glyph(rect: clip, uv: glyphBounds, color: SIMD4(0, 0, 1, 1), clip: clip),
                            .layerBegin(rect: clip, clip: clip),
                            .glyph(rect: SIMD4(6, 0, 18, 8), uv: glyphBounds, color: SIMD4(1, 0, 0, 1), clip: clip, page: 1),
                            .glyph(rect: SIMD4(12, 0, 6, 8), uv: glyphBounds, color: SIMD4(0, 1, 0, 1), clip: clip, page: 7),
                            .layerEnd(clip: clip)
                        ])
    }

    @Test func glyphPagesUseLocalUVAndMissingPagesUseTheBaseMask() throws {
        var scene = glyphScene()
        let frame = try RuneRef.render(scene)
        #expect(frame.pixel(x: 3, y: 3) == SIMD4(0, 0, 255, 255))
        #expect(frame.pixel(x: 8, y: 3) == SIMD4(128, 0, 127, 255))
        #expect(frame.pixel(x: 14, y: 3) == SIMD4(0, 255, 0, 255))
        scene.glyphPages.removeLast()
        #expect(try RuneRef.render(scene).pixel(x: 8, y: 3) == SIMD4(255, 0, 0, 255))
    }

    @Test func overlappingImagePagesPreservePainterOrder() throws {
        var scene = scene()
        let original = scene
        let frame = try RuneRef.render(scene)
        #expect(frame.pixel(x: 3, y: 3) == SIMD4(192, 0, 0, 255))
        #expect(frame.pixel(x: 8, y: 3) == SIMD4(0, 128, 0, 255))
        #expect(frame.pixel(x: 14, y: 3) == SIMD4(0, 0, 192, 255))
        #expect(frame.pixel(x: 20, y: 3) == SIMD4(0, 128, 0, 255))
        scene.imagePages[1].texels = [187, 106, 0, 255]
        #expect(try RuneRef.render(scene).pixel(x: 8, y: 3) == SIMD4(187, 106, 0, 255))
        #expect(try RuneRef.render(original) == frame)
        scene.imagePages.removeLast(2)
        #expect(try RuneRef.render(scene).pixel(x: 8, y: 3) == SIMD4(192, 0, 0, 255))
        scene.primitives[2].params.x = 0.5
        #expect(throws: RefSceneError.invalidImagePage(index: 2)) { try scene.validate() }
    }

    @MainActor @Test func aRuntimeFrameUsesTheSameLocalTexelsAcrossDifferentGlyphShelfSizes() throws {
        let red = RGBA8Atlas(width: 1, height: 1, texels: [200, 0, 0, 255])
        let green = RGBA8Atlas(width: 1_025, height: 1, texels: Array(repeating: [UInt8(0), 180, 0, 255], count: 1_025).flatMap { $0 })
        func frame(shelf: Int) -> RefScene {
            let system = TextSystem(glyphAtlas: GlyphAtlas(width: shelf, height: shelf))
            let runtime = Runtime(state: (), viewport: Vec2(270, 66), pixelScale: 1, textSystem: system) { _, _ in
                col().size(270, 66).bg(.black)
                    .child(text("ABCDEFGHIJKLMNOPQRSTUVWXYZ").size(20).color(.white).wrap(.wrap))
                    .child(image(red).absolute(x: 0, y: 58).size(8, 6))
                    .child(image(green).absolute(x: 16, y: 58).size(8, 6))
            }
            return runtime.frame(at: 0)
        }
        let small = frame(shelf: 64), large = frame(shelf: 512)
        try small.validate()
        #expect(small.glyphPages.count > 1)
        #expect(small.primitives.contains { $0.kind == .glyph && $0.glyphPage > 0 })
        #expect(small.primitives.contains { $0.kind == .image && $0.imagePage > 0 })
        let rendered = try RuneRef.render(small)
        #expect(rendered == (try RuneRef.render(large)))
        #expect(rendered.pixel(x: 3, y: 60) == SIMD4(200, 0, 0, 255))
        #expect(rendered.pixel(x: 19, y: 60) == SIMD4(0, 180, 0, 255))
    }

    #if canImport(Metal)
    @Test func referenceMetalSamplesTheSelectedImagePage() throws {
        let renderer: MetalRenderer
        do { renderer = try MetalRenderer() } catch MetalRenderer.RendererError.metalUnavailable { return }
        try compareGPU { try renderer.renderOffscreen($0) }
    }
    #endif

    #if (os(macOS) || os(Linux) || os(Windows)) && canImport(CRuneOffscreenGL)
    @MainActor @Test func referenceGLSamplesTheSelectedImagePage() throws {
        try withTestGLRenderer { _, render in try compareGPU(render) }
    }
    #endif

    private func compareGPU(_ draw: (RefScene) throws -> Frame) throws {
        var scene = scene()
        var masks = glyphScene()
        for i in 0..<3 {
            if i == 1 { masks.glyphPages[1].texels = [73, 73] }
            if i == 2 { masks.glyphPages.removeLast() }
            let expected = try RuneRef.render(masks)
            #expect(RuneRef.compare(scene: masks, expected: expected, actual: try draw(masks), channelTolerance: 2).passed)
        }
        // Change the texture transfer function with identical page storage, then mutate only the second page.
        for i in 0..<5 {
            scene.srgbBlend = i.isMultiple(of: 2)
            if i == 2 { scene.imagePages[1].texels = [187, 106, 0, 255] }
            if i == 4 { scene.imagePages.removeLast(2) }
            let expected = try RuneRef.render(scene)
            let comparison = RuneRef.compare(scene: scene, expected: expected, actual: try draw(scene), channelTolerance: 2)
            #expect(comparison.passed, "\(comparison)")
        }
    }
}
