#if canImport(Metal) && canImport(QuartzCore)
import Metal
import RuneRef
import Testing
@testable import Rune

@Suite("Metal command buffer staging")
struct MetalStagingBufferTests {
    private func rectangle(_ bounds: SIMD4<Float>, _ color: SIMD4<Float>) -> RenderInstance {
        RenderInstance(rect: bounds, fill: color, params: SIMD4(0, KIND_RECT, 0.5, 1))
    }

    private func target(_ renderer: MetalRenderer, _ frame: RenderFrame) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: frame.width, height: frame.height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try #require(renderer.device.makeTexture(descriptor: descriptor))
    }

    private func commit(_ commands: MTLCommandBuffer) throws {
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
    }

    private func bgra(_ texture: MTLTexture, atX x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return bytes
    }

    private func encodeBoth(
        _ first: RenderFrame, _ second: RenderFrame, shareCommandBuffer: Bool
    ) throws -> (MTLTexture, MTLTexture) {
        let renderer = try MetalRenderer()
        let firstTarget = try target(renderer, first)
        let secondTarget = try target(renderer, second)
        let firstCommands = try #require(renderer.commandQueue.makeCommandBuffer())
        let secondCommands = try shareCommandBuffer ? firstCommands : #require(renderer.commandQueue.makeCommandBuffer())

        renderer.drawRange(frame: first, into: firstTarget, commandBuffer: firstCommands)
        renderer.prepare(frame: second, viewport: (second.width, second.height))
        renderer.drawRange(frame: second, into: secondTarget, commandBuffer: secondCommands)
        if !shareCommandBuffer { try commit(secondCommands) }
        try commit(firstCommands)
        return (firstTarget, secondTarget)
    }

    @Test("Frames retain their own geometry and color until GPU execution", arguments: [false, true])
    func delayedDraws(shareCommandBuffer: Bool) throws {
        let first = RenderFrame(
            width: 32, height: 16, instances: [rectangle(SIMD4(1, 1, 12, 12), SIMD4(1, 0, 0, 1))]
        )
        let second = RenderFrame(
            width: 32, height: 16, instances: [rectangle(SIMD4(17, 1, 12, 12), SIMD4(0, 1, 0, 1))]
        )
        let (firstTarget, secondTarget) = try encodeBoth(first, second, shareCommandBuffer: shareCommandBuffer)
        #expect(bgra(firstTarget, atX: 6, y: 6) == [0, 0, 255, 255])
        #expect(bgra(firstTarget, atX: 22, y: 6) == [0, 0, 0, 255])
        #expect(bgra(secondTarget, atX: 6, y: 6) == [0, 0, 0, 255])
        #expect(bgra(secondTarget, atX: 22, y: 6) == [0, 255, 0, 255])
    }

    @Test("Changing the glyph atlas generation preserves a pending frame's mask", arguments: [false, true])
    func pendingGlyphAtlas(shareCommandBuffer: Bool) throws {
        let glyph = RenderInstance(rect: SIMD4(0, 0, 4, 4), fill: SIMD4(repeating: 1),
                                   params: SIMD4(0, KIND_GLYPH, 0, 1))
        func frame(generation: UInt64, left: UInt8, right: UInt8) -> RenderFrame {
            let row = [left, left, right, right]
            return RenderFrame(width: 4, height: 4, glyphs: R8Atlas(width: 4, height: 4, texels: row + row + row + row),
                               glyphGeneration: generation, instances: [glyph])
        }
        let first = frame(generation: 1, left: 255, right: 0)
        let second = frame(generation: 2, left: 0, right: 255)
        let (firstTarget, secondTarget) = try encodeBoth(first, second, shareCommandBuffer: shareCommandBuffer)
        #expect(bgra(firstTarget, atX: 0, y: 2) == [255, 255, 255, 255])
        #expect(bgra(firstTarget, atX: 3, y: 2) == [0, 0, 0, 255])
        #expect(bgra(secondTarget, atX: 0, y: 2) == [0, 0, 0, 255])
        #expect(bgra(secondTarget, atX: 3, y: 2) == [255, 255, 255, 255])
    }

    @Test("An empty one-texel atlas clears coverage from an earlier glyph", arguments: [false, true])
    func emptyGlyphAtlas(omitTexel: Bool) throws {
        let glyph = RenderInstance(rect: SIMD4(0, 0, 1, 1), fill: SIMD4(repeating: 1),
                                   params: SIMD4(0, KIND_GLYPH, 0, 1))
        let first = RenderFrame(width: 1, height: 1, glyphs: R8Atlas(texels: [255]),
                                glyphGeneration: 1, instances: [glyph])
        let second = RenderFrame(width: 1, height: 1, glyphs: R8Atlas(texels: omitTexel ? [] : [0]),
                                 glyphGeneration: 2, instances: [glyph])
        let (firstTarget, secondTarget) = try encodeBoth(first, second, shareCommandBuffer: false)
        #expect(bgra(firstTarget, atX: 0, y: 0) == [255, 255, 255, 255])
        #expect(bgra(secondTarget, atX: 0, y: 0) == [0, 0, 0, 255])
    }

    @Test("Root and nested backdrop passes retain their own projections")
    func backdropProjections() throws {
        let renderer = try MetalRenderer()
        let white = SIMD4<Float>(repeating: 1)
        func blur(_ bounds: SIMD4<Float>) -> RenderInstance {
            RenderInstance(rect: bounds, fill: white, params: SIMD4(3, KIND_BACKDROP_BLUR, 0, 1))
        }
        let left = [rectangle(SIMD4(2, 2, 18, 24), white), blur(SIMD4(4, 4, 32, 20))]
        let bounds = SIMD4<Float>(80, 3, 30, 26)
        let right: [RenderInstance] = [
            .beginLayer(bounds: bounds, clip: NO_CLIP, spec: LayerSpec(opacity: 0.8)),
            rectangle(SIMD4(81, 4, 14, 24), white), blur(bounds), .endLayer()
        ]
        func render(_ instances: [RenderInstance]) throws -> Frame {
            try renderer.renderOffscreen(RenderFrame(width: 128, height: 32, instances: instances))
        }
        let leftOnly = try render(left)
        let rightOnly = try render(right)
        let together = try render(left + right)

        // Both blur edges must contain an intermediate color when drawn on their own.
        #expect((1..<255).contains(leftOnly.pixel(x: 20, y: 14).x))
        #expect((1..<200).contains(rightOnly.pixel(x: 95, y: 14).x))
        var differingPixels = 0
        for y in 0..<together.height {
            for x in 0..<together.width {
                let expected = x < 64 ? leftOnly : rightOnly
                if together.pixel(x: x, y: y) != expected.pixel(x: x, y: y) {
                    differingPixels += 1
                }
            }
        }
        #expect(differingPixels == 0)
    }
}
#endif
