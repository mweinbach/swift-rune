#if canImport(Metal) && canImport(QuartzCore)
import Metal
import RuneRef
import Testing
@testable import Rune

struct MetalTextureLimitTests {
    @Test func invalidProductionTextureFailsBeforeEncodingAndNextDrawSucceeds() throws {
        let renderer = try MetalRenderer()
        let limit = MetalTextureLimits.max2D(on: renderer.device)
        let legal = RenderFrame(width: 2, height: 2, clearColor: SIMD4(1, 0, 0, 1))
        var badImage = legal
        badImage.images = RGBA8Atlas(width: limit + 1, height: 1, texels: [])
        let dimension = MetalTextureSizeError.dimensions(resource: "Image atlas", width: limit + 1, height: 1, maximum: limit)
        #expect(throws: dimension) { try renderer.renderOffscreen(badImage) }
        #expect(throws: dimension) { try renderer.prepare(frame: badImage, viewport: (2, 2)).get() }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 2, height: 2, mipmapped: false)
        desc.usage = .renderTarget
        let target = try #require(renderer.device.makeTexture(descriptor: desc))
        let commands = try #require(renderer.commandQueue.makeCommandBuffer())
        #expect(throws: dimension) { try renderer.drawRange(frame: badImage, into: target, commandBuffer: commands).get() }

        var badPage = legal
        badPage.imagePages = [RGBA8Atlas(), RGBA8Atlas(width: 1, height: limit + 1, texels: [])]
        #expect(throws: MetalTextureSizeError.dimensions(resource: "Image atlas page 1", width: 1, height: limit + 1, maximum: limit)) {
            try renderer.renderOffscreen(badPage)
        }
        var short = legal
        short.images = RGBA8Atlas(width: 2, height: 1, texels: [255, 0, 0, 255])
        #expect(throws: MetalTextureSizeError.byteCount(resource: "Image atlas", expected: 8, actual: 4)) {
            try renderer.renderOffscreen(short)
        }
        let valid = try renderer.renderOffscreen(legal)
        #expect(valid.pixel(x: 1, y: 1) == SIMD4<UInt8>(255, 0, 0, 255))
    }

    @Test func targetAndGlyphLimitsApplyBeforeAllocation() throws {
        let renderer = try MetalRenderer()
        let limit = MetalTextureLimits.max2D(on: renderer.device)
        let target = RenderFrame(width: limit + 1, height: 1)
        #expect(throws: MetalTextureSizeError.dimensions(resource: "Frame", width: limit + 1, height: 1, maximum: limit)) {
            try renderer.renderOffscreen(target)
        }
        var frame = RenderFrame(width: 4, height: 4)
        #expect(throws: MetalTextureSizeError.dimensions(resource: "Viewport", width: Int.max, height: 1, maximum: limit)) {
            try renderer.prepare(frame: frame, viewport: (Int.max, 1)).get()
        }
        frame.glyphs = R8Atlas(width: 1, height: limit + 1, texels: [])
        #expect(throws: MetalTextureSizeError.dimensions(resource: "Glyph atlas", width: 1, height: limit + 1, maximum: limit)) {
            try renderer.renderOffscreen(frame)
        }
        // A one-row atlas at the device's advertised maximum is representable and uploads successfully.
        frame.glyphs = R8Atlas(width: limit, height: 1)
        _ = try renderer.renderOffscreen(frame)
    }
}
#endif
