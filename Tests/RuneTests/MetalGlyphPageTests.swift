#if canImport(Metal) && canImport(QuartzCore)
import Metal
import Testing
@testable import Rune

@Suite("Metal glyph mask pages")
struct MetalGlyphPageTests {
    private func glyph(_ page: Int, _ x: Int) -> RenderInstance {
        RenderInstance(rect: SIMD4(Float(x), 0, 3, 3), fill: .one,
                       params: SIMD4(0, KIND_GLYPH, Float(page), 1),
                       uv: SIMD4(0, 0, 1, 1), clip: NO_CLIP)
    }

    @Test func masksBindIndependentlyAndPartialEditsDoNotOverwriteOlderCommands() throws {
        let renderer = try MetalRenderer()
        let dark = R8Atlas(width: 3, height: 2, texels: Array(repeating: 0, count: 6))
        let light = R8Atlas(width: 3, height: 2, texels: Array(repeating: 255, count: 6))
        var first = RenderFrame(width: 9, height: 3, glyphs: dark, glyphPages: [dark, light],
                                instances: [glyph(1, 0), glyph(0, 3), glyph(1, 6)])
        first.glyphPageRevisions = [10, 20]
        let rendered = try renderer.renderOffscreen(first)
        #expect(rendered.pixel(x: 1, y: 1).x == 255 && rendered.pixel(x: 4, y: 1).x == 0)
        #expect(try renderer.renderOffscreen(first.flattenedGlyphPages()) == rendered)
        // Return to a paged upload, then edit exactly one secondary mask texel.
        _ = try renderer.renderOffscreen(first)
        let start = renderer.uploader.glyphUploadBytes
        var next = first
        next.glyphPages[1].texels[0] = 0
        next.glyphPageRevisions = [10, 21]
        next.glyphPagePatches = [nil, .init(fromRevision: 20, edges: SIMD4(0, 0, 1, 1))]
        let darkened = try renderer.renderOffscreen(next)
        #expect(darkened.pixel(x: 1, y: 1).x == 0 && darkened.pixel(x: 7, y: 1).x == 0)
        #expect(renderer.uploader.glyphUploadBytes == start + 1)
        #expect(try renderer.renderOffscreen(next) == darkened)
        #expect(renderer.uploader.glyphUploadBytes == start + 1)

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 9, height: 3, mipmapped: false)
        desc.usage = .renderTarget
        desc.storageMode = .shared
        let target = try #require(renderer.device.makeTexture(descriptor: desc))
        let cmd = try #require(renderer.commandQueue.makeCommandBuffer())
        _ = renderer.drawRange(frame: next, into: target, commandBuffer: cmd)
        let old = renderer.uploader.glyphTextures
        try renderer.prepare(frame: first, viewport: (9, 3)).get()
        #expect(renderer.uploader.glyphTextures[0] === old[0])
        #expect(renderer.uploader.glyphTextures[1] !== old[1])
        cmd.commit()
        cmd.waitUntilCompleted()
        if let error = cmd.error { throw error }
        var pixel = [UInt8](repeating: 0, count: 4)
        target.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(1, 1, 1, 1), mipmapLevel: 0)
        #expect(pixel == [0, 0, 0, 255])
        #expect(try renderer.renderOffscreen(first) == rendered)
    }

    @Test func glyphShelfPublishesOnlyTheChangedPageAndKeepsItsPreviousSnapshot() throws {
        let atlas = GlyphAtlas(width: 16, height: 16)
        let base = try #require(atlas.placeMask(width: 14, height: 14, bitmap: Array(repeating: 77, count: 196)))
        let next = try #require(atlas.placeMask(width: 3, height: 3, bitmap: Array(repeating: 95, count: 9)))
        #expect(base.page == 0 && next.page == 1)
        let first = atlas.framePages()
        let held = first.bases[1].texels
        let additional = try #require(atlas.placeMask(width: 3, height: 3, bitmap: Array(repeating: 140, count: 9)))
        let changed = atlas.framePages()
        #expect(additional.page == 1)
        #expect(changed.revisions[0] == first.revisions[0])
        #expect(changed.revisions[1] != first.revisions[1])
        let patch = try #require(changed.patches[1])
        let x = additional.pixelOrigin.x, y = additional.pixelOrigin.y
        #expect(patch.fromRevision == first.revisions[1] && patch.edges == SIMD4(x - 1, y - 1, x + 4, y + 4))
        #expect(held[y * 16 + x] == 0 && changed.bases[1].texels[y * 16 + x] == 140)
        let repeatFrame = atlas.framePages()
        let sharedTable = changed.bases.withUnsafeBufferPointer { lhs in
            repeatFrame.bases.withUnsafeBufferPointer { $0.baseAddress == lhs.baseAddress }
        }
        #expect(sharedTable)
        let primaryEpoch = atlas.pageSignature(usedPages: 1).epoch
        let overflowEpoch = atlas.pageSignature(usedPages: 2).epoch
        atlas.evictPage(1)
        #expect(atlas.pageSignature(usedPages: 1).epoch == primaryEpoch)
        #expect(atlas.pageSignature(usedPages: 2).epoch > overflowEpoch)
        #expect(atlas.pageSignature(usedPages: 3).epoch == atlas.pageSignature(usedPages: 2).epoch)
    }

    @Test func flattenedGlyphsKeepFilteredEdgesAndSparsePages() throws {
        let renderer = try MetalRenderer()
        let primary = R8Atlas(width: 3, height: 1, texels: [64, 128, 128])
        let narrow = R8Atlas(width: 1, height: 1, texels: [255])
        let vacant = R8Atlas(width: 2, height: 2, texels: [])
        let frame = RenderFrame(width: 12, height: 3, glyphs: primary, glyphPages: [primary, narrow, vacant],
                                instances: [glyph(1, 0), glyph(2, 3), glyph(9, 6), glyph(0, 9)])
        let paged = try renderer.renderOffscreen(frame)
        let legacy = try renderer.renderOffscreen(frame.flattenedGlyphPages())
        #expect(legacy == paged)
        #expect(legacy.pixel(x: 2, y: 2).x == 255 && legacy.pixel(x: 5, y: 1).x == 0)
        #expect(legacy.pixel(x: 7, y: 1) == legacy.pixel(x: 10, y: 1))
    }

    @Test func validPagesCanExceedTheCombinedTextureHeight() throws {
        let renderer = try MetalRenderer()
        let limit = MetalTextureLimits.max2D(on: renderer.device)
        let light = R8Atlas(width: 1, height: limit, texels: Array(repeating: 255, count: limit))
        let dark = R8Atlas(width: 1, height: limit)
        let frame = RenderFrame(width: 6, height: 3, glyphs: dark, glyphPages: [dark, light],
                                instances: [glyph(1, 0), glyph(0, 3)])
        let actual = try renderer.renderOffscreen(frame)
        #expect(actual.pixel(x: 1, y: 1).x == 255 && actual.pixel(x: 4, y: 1).x == 0)
        #expect(throws: RefSceneError.self) { _ = try frame.flattenedGlyphPages() }
    }
}
#endif
