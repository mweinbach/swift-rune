#if canImport(Metal) && canImport(QuartzCore)
import Foundation
import Metal
import RuneRef
import Testing
@testable import Rune

@Suite("Metal reference scene texture limits")
struct MetalReferenceLimitsTests {
    @Test func rejectsOversizedAtlasesBeforeUploadingAndCanRenderAgain() throws {
        let renderer = try MetalRenderer()
        let maximum = MetalTextureLimits.max2D(on: renderer.device)
        let invalidWidth = maximum + 1
        let image = RGBA8Atlas(width: invalidWidth, height: 1, texels: [])
        let invalid = RefScene(width: 1, height: 1, images: image)
        let error = MetalTextureSizeError.dimensions(resource: "image atlas", width: invalidWidth, height: 1, maximum: maximum)
        #expect(throws: error) { try renderer.renderOffscreen(invalid) }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 1, height: 1, mipmapped: false
        )
        descriptor.usage = .renderTarget
        let target = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let commands = try #require(renderer.commandQueue.makeCommandBuffer())
        #expect(throws: error) { try renderer.encode(scene: invalid, into: target, commandBuffer: commands) }
        let validWidth = min(maximum, 16_384)
        var boundary = RGBA8Atlas(width: validWidth, height: 1)
        boundary.texels.replaceSubrange((boundary.texels.count - 4)..., with: [0, 255, 0, 255])
        let clip = SIMD4<Float>(0, 0, 1, 1)
        let uv = SIMD4<Float>(Float(validWidth - 1) / Float(validWidth), 0, 1, 1)
        let good = RefScene(width: 1, height: 1, images: boundary, primitives: [.image(rect: clip, uv: uv, clip: clip)])
        #expect(try renderer.renderOffscreen(good).rgba == [0, 255, 0, 255])
    }

    @Test func rejectsInvalidRenderTargetGlyphAtlasAndIncompleteImage() throws {
        let renderer = try MetalRenderer()
        let maximum = MetalTextureLimits.max2D(on: renderer.device)
        let hugeTarget = RefScene(width: Int.max, height: 2)
        #expect(throws: MetalTextureSizeError.dimensions(resource: "render target", width: Int.max, height: 2, maximum: maximum)) {
            try renderer.renderOffscreen(hugeTarget)
        }
        let glyphs = R8Atlas(width: 1, height: maximum + 1, texels: [])
        #expect(throws: MetalTextureSizeError.dimensions(resource: "glyph atlas", width: 1, height: maximum + 1, maximum: maximum)) {
            try renderer.renderOffscreen(RefScene(width: 1, height: 1, glyphs: glyphs))
        }
        let image = RGBA8Atlas(width: 3, height: 1, texels: [42])
        #expect(throws: RefSceneError.invalidImageAtlasSize(expected: 12, actual: 1)) {
            try renderer.renderOffscreen(RefScene(width: 1, height: 1, images: image))
        }
    }

    @Test func validatesSparsePageDimensionsBeforeChoosingFallbackTextures() throws {
        let renderer = try MetalRenderer()
        let maximum = MetalTextureLimits.max2D(on: renderer.device)
        let width = maximum + 1
        let glyphs = [R8Atlas(), R8Atlas(width: width, height: 1, texels: [])]
        #expect(throws: MetalTextureSizeError.dimensions(resource: "glyph atlas page 1", width: width, height: 1, maximum: maximum)) {
            try renderer.renderOffscreen(RefScene(width: 1, height: 1, glyphPages: glyphs))
        }
        let images = [RGBA8Atlas(), RGBA8Atlas(width: width, height: 1, texels: [])]
        #expect(throws: MetalTextureSizeError.dimensions(resource: "image atlas page 1", width: width, height: 1, maximum: maximum)) {
            try renderer.renderOffscreen(RefScene(width: 1, height: 1, imagePages: images))
        }
    }

    @Test func aSurfacePlaneOverTheDeviceLimitReturnsAnErrorAndPreservesLaterDraws() throws {
        let renderer = try MetalRenderer()
        let maximum = MetalTextureLimits.max2D(on: renderer.device)
        let width = maximum + 1
        let bytes = try ByteFrame(width: UInt32(width), height: 1, format: .rgba, color: .srgb,
                                  planes: [Data(count: width * 4)])
        let surface = NativeSurface()
        surface.replaceFrame(NativeSurfaceVideoFrame(id: 1, size: (bytes.width, bytes.height),
                                                      format: bytes.format, color: bytes.color, orient: .up, source: .bytes(bytes)))
        let draw = SurfaceDraw(surface: surface, fit: .stretch, beforeInstance: 0, rect: SIMD4(0, 0, 1, 1), clip: SIMD4(0, 0, 1, 1))
        let scene = RefScene(width: 1, height: 1, srgbBlend: true)
        let error = MetalTextureSizeError.dimensions(resource: "surface plane", width: width, height: 1, maximum: maximum)
        #expect(throws: error) { try renderer.renderOffscreen(scene, surfaces: [draw]) }
        #expect(surface.lastError == error.description)
        #if canImport(CoreVideo) && canImport(IOSurface)
        let importer = try CVPixelBufferImporter(device: renderer.device)
        let pixelBuffer = try CoreVideoPixelBuffer.fromBytes(bytes)
        let planeError = MetalTextureSizeError.dimensions(resource: "CoreVideo plane", width: width, height: 1, maximum: maximum)
        #expect(throws: planeError) {
            try importer.import(pixelBuffer, format: .bgra, size: pixelBuffer.size)
        }
        #expect(importer.livePlanes == 0)
        #endif
        try surface.pushBytes(ByteFrame(width: 1, height: 1, format: .rgba, color: .srgb, planes: [Data([255, 0, 0, 255])]), frameId: 2)
        #expect(try renderer.renderOffscreen(scene, surfaces: [draw]).rgba == [255, 0, 0, 255])
        #expect(surface.lastError == nil)
    }
}
#endif
